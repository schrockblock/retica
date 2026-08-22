import Foundation
import ComposableArchitecture
#if canImport(Network)
import Network
#endif

/// Stable identifier for one accepted connection on a `TCPListener`. Minted monotonically as
/// connections arrive; node-local, never crosses the wire. A struct (not a bare `UInt64`) so the
/// listener's event/send/close surface is self-documenting and cannot be confused with a port or
/// a length.
public struct TCPConnID: Hashable, Sendable {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
}

/// Events emitted by a listening TCP socket. Unlike `TCPEvent` (single connection), every event
/// carries the `TCPConnID` it belongs to, because a listener multiplexes N simultaneous
/// connections onto one stream.
public enum TCPListenerEvent: Sendable, Equatable {
    /// The listener bound its port and is accepting. Emitted once per successful `listen`.
    case started
    /// The listener could not bind (e.g. port in use, invalid port). Terminal — the stream ends.
    case failed(reason: String?)
    /// A new inbound connection was accepted and assigned `TCPConnID`.
    case accepted(TCPConnID)
    /// Bytes arrived on an accepted connection.
    case data(TCPConnID, Data)
    /// An accepted connection closed.
    case closed(TCPConnID, reason: String?)
}

/// Listening TCP-socket dependency. The live value wraps `NWListener` and accepts N connections,
/// each backed by its own `NWConnection` with its own receive loop. Tests inject a mock.
///
/// Shape differs from `TCPConnection` in exactly the way the plan calls out: there is no single
/// peer, so `send`/`close` are keyed by `TCPConnID`, and `listen` yields a multiplexed event
/// stream instead of `TCPConnection.open`'s single-peer stream.
public struct TCPListener: Sendable {
    /// Bind `port` and begin accepting. The returned stream carries `.started`/`.accepted`/
    /// `.data`/`.closed`/`.failed` for the lifetime of the listener.
    public var listen: @Sendable (_ port: UInt16) -> AsyncStream<TCPListenerEvent>
    /// Send raw bytes to one accepted connection. A no-op if the connection is gone.
    public var send: @Sendable (_ conn: TCPConnID, _ data: Data) async -> Void
    /// Close one accepted connection.
    public var close: @Sendable (_ conn: TCPConnID) async -> Void
    /// Stop the listener and drop every accepted connection.
    public var stop: @Sendable () async -> Void

    public init(
        listen: @escaping @Sendable (UInt16) -> AsyncStream<TCPListenerEvent>,
        send: @escaping @Sendable (TCPConnID, Data) async -> Void,
        close: @escaping @Sendable (TCPConnID) async -> Void,
        stop: @escaping @Sendable () async -> Void
    ) {
        self.listen = listen
        self.send = send
        self.close = close
        self.stop = stop
    }
}

extension TCPListener: DependencyKey {
    public static var liveValue: TCPListener {
        #if canImport(Network)
        let actor = NWListenerActor()
        return TCPListener(
            listen: { port in
                AsyncStream { continuation in
                    Task { await actor.start(port: port, continuation: continuation) }
                }
            },
            send: { conn, data in await actor.send(conn, data) },
            close: { conn in await actor.close(conn) },
            stop: { await actor.stop() }
        )
        #else
        return TCPListener(listen: { _ in .finished }, send: { _, _ in }, close: { _ in }, stop: {})
        #endif
    }

    public static let testValue = TCPListener(
        listen: unimplemented("TCPListener.listen", placeholder: AsyncStream { $0.finish() }),
        send: unimplemented("TCPListener.send"),
        close: unimplemented("TCPListener.close"),
        stop: unimplemented("TCPListener.stop")
    )
}

extension DependencyValues {
    public var tcpListener: TCPListener {
        get { self[TCPListener.self] }
        set { self[TCPListener.self] = newValue }
    }
}

#if canImport(Network)
/// Owns the `NWListener` and every accepted `NWConnection`, keyed by a monotonic `TCPConnID`.
///
/// Each accepted connection gets its OWN receive loop and its OWN generation-checked callbacks,
/// the same discipline `NWConnectionActor` applies for the client — a callback for a connection
/// that has since been closed must not yield into, or finish the stream on behalf of, a later
/// connection. Here the connection map itself provides the staleness check: `close`/`stop`
/// remove the entry, so a stale callback finds no connection and does nothing beyond a final
/// `.closed`. We additionally guard the listener continuation with a generation so a superseded
/// `NWListener` (from a second `start`) cannot yield into the current stream.
private actor NWListenerActor {
    private var listener: NWListener?
    private var continuation: AsyncStream<TCPListenerEvent>.Continuation?
    private var connections: [TCPConnID: NWConnection] = [:]
    private var nextID: UInt64 = 0
    /// Distinguishes the current listener session from a superseded one.
    private var generation: UInt64 = 0

    func start(port: UInt16, continuation: AsyncStream<TCPListenerEvent>.Continuation) {
        generation &+= 1
        let gen = generation
        // Tear down any prior listener/stream so a reused actor never leaks a continuation.
        self.continuation?.finish()
        self.listener?.cancel()
        for conn in connections.values { conn.cancel() }
        connections.removeAll()
        self.continuation = continuation

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            continuation.yield(.failed(reason: "invalid port")); continuation.finish()
            self.continuation = nil
            return
        }
        let l: NWListener
        do {
            l = try NWListener(using: .tcp, on: nwPort)
        } catch {
            continuation.yield(.failed(reason: error.localizedDescription)); continuation.finish()
            self.continuation = nil
            return
        }
        self.listener = l
        l.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleListenerState(state, generation: gen) }
        }
        l.newConnectionHandler = { [weak self] conn in
            Task { await self?.accept(conn, generation: gen) }
        }
        l.start(queue: .global(qos: .userInitiated))
    }

    private func handleListenerState(_ state: NWListener.State, generation gen: UInt64) {
        guard gen == generation else { return }
        switch state {
        case .ready:
            continuation?.yield(.started)
        case let .failed(error):
            continuation?.yield(.failed(reason: error.localizedDescription))
            continuation?.finish()
        default:
            break
        }
    }

    private func accept(_ conn: NWConnection, generation gen: UInt64) {
        guard gen == generation else { conn.cancel(); return }
        nextID &+= 1
        let id = TCPConnID(nextID)
        connections[id] = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleConnState(id, state, generation: gen) }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    private func handleConnState(_ id: TCPConnID, _ state: NWConnection.State, generation gen: UInt64) {
        guard gen == generation, connections[id] != nil else { return }
        switch state {
        case .ready:
            continuation?.yield(.accepted(id))
            receiveNext(id, generation: gen)
        case let .failed(error):
            dropAndReport(id, reason: error.localizedDescription)
        case .cancelled:
            // Cancellation is driven by `close`/`stop`, which already removed the entry and
            // reported the close; nothing to do here.
            break
        default:
            break
        }
    }

    private func receiveNext(_ id: TCPConnID, generation gen: UInt64) {
        connections[id]?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { await self?.handleReceive(id, data: data, isComplete: isComplete, error: error, generation: gen) }
        }
    }

    private func handleReceive(_ id: TCPConnID, data: Data?, isComplete: Bool, error: NWError?, generation gen: UInt64) {
        guard gen == generation, connections[id] != nil else { return }
        if let data, !data.isEmpty { continuation?.yield(.data(id, data)) }
        if let error { dropAndReport(id, reason: error.localizedDescription); return }
        if isComplete { dropAndReport(id, reason: nil); return }
        receiveNext(id, generation: gen)
    }

    /// Remove a connection and emit its `.closed` exactly once.
    private func dropAndReport(_ id: TCPConnID, reason: String?) {
        guard let conn = connections.removeValue(forKey: id) else { return }
        conn.cancel()
        continuation?.yield(.closed(id, reason: reason))
    }

    func send(_ id: TCPConnID, _ data: Data) {
        connections[id]?.send(content: data, completion: .contentProcessed { _ in })
    }

    func close(_ id: TCPConnID) {
        guard let conn = connections.removeValue(forKey: id) else { return }
        conn.cancel()
        continuation?.yield(.closed(id, reason: nil))
    }

    func stop() {
        generation &+= 1
        for conn in connections.values { conn.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        continuation?.finish()
        continuation = nil
    }
}
#endif
