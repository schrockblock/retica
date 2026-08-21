import Foundation
import ComposableArchitecture
#if canImport(Network)
import Network
#endif

/// Events emitted by a TCP connection.
public enum TCPEvent: Sendable, Equatable {
    case connected
    case data(Data)
    case disconnected(reason: String?)
}

/// TCP socket dependency. The live value wraps `NWConnection`; tests inject a mock, with ONE
/// deliberate exception — `TCPConnectionReconnectTests` drives the live value over loopback,
/// because the stale-callback class of defect it pins lives in `NWConnectionActor`'s handling of
/// Network.framework callbacks, which is precisely the layer a mock replaces.
public struct TCPConnection: Sendable {
    public var open: @Sendable (_ host: String, _ port: UInt16) -> AsyncStream<TCPEvent>
    public var send: @Sendable (Data) async -> Void
    public var close: @Sendable () async -> Void

    public init(
        open: @escaping @Sendable (String, UInt16) -> AsyncStream<TCPEvent>,
        send: @escaping @Sendable (Data) async -> Void,
        close: @escaping @Sendable () async -> Void
    ) {
        self.open = open
        self.send = send
        self.close = close
    }
}

extension TCPConnection: DependencyKey {
    public static var liveValue: TCPConnection {
        #if canImport(Network)
        let actor = NWConnectionActor()
        return TCPConnection(
            open: { host, port in
                AsyncStream { continuation in
                    Task { await actor.start(host: host, port: port, continuation: continuation) }
                }
            },
            send: { await actor.send($0) },
            close: { await actor.close() }
        )
        #else
        return TCPConnection(open: { _, _ in .finished }, send: { _ in }, close: {})
        #endif
    }

    public static let testValue = TCPConnection(
        open: unimplemented("TCPConnection.open", placeholder: AsyncStream { $0.finish() }),
        send: unimplemented("TCPConnection.send"),
        close: unimplemented("TCPConnection.close")
    )
}

extension DependencyValues {
    public var tcpConnection: TCPConnection {
        get { self[TCPConnection.self] }
        set { self[TCPConnection.self] = newValue }
    }
}

#if canImport(Network)
/// Holds the current NWConnection so `send`/`close` act on it. One active connection per instance.
private actor NWConnectionActor {
    private var connection: NWConnection?
    private var continuation: AsyncStream<TCPEvent>.Continuation?

    /// Identifies which connection a callback belongs to.
    ///
    /// `liveValue` builds ONE of these actors and captures it in all three closures, so every
    /// reconnect reuses this instance. Network.framework delivers callbacks asynchronously and they
    /// hop onto the actor via `Task {}`, while `start` runs to completion without a suspension
    /// point — so the `cancel()` below cannot be observed until AFTER the new continuation is
    /// installed. Without this generation check the cancelled connection's `.cancelled` callback
    /// ran `continuation?.finish()` on whatever it found, which by then was the NEW stream: the new
    /// socket connected, `.ready` yielded into a finished continuation, every inbound byte was
    /// dropped, and the interface's `for await` loop had already exited so it never saw
    /// `.connected`. `send` kept working (it writes to the new connection), which is what made it
    /// look like a healthy client to the node while the app sat on "Disconnected" for ever.
    ///
    /// Pinned by `TCPConnectionReconnectTests`, which are real-socket tests precisely because a
    /// mocked `TCPConnection` replaces the layer this bug lives in.
    private var generation: UInt64 = 0

    func start(host: String, port: UInt16, continuation: AsyncStream<TCPEvent>.Continuation) {
        generation &+= 1
        let gen = generation
        // Tear down any prior connection/stream so a reused actor never leaks a continuation.
        self.continuation?.finish()
        self.connection?.cancel()
        self.continuation = continuation
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            continuation.yield(.disconnected(reason: "invalid port")); continuation.finish()
            self.continuation = nil
            return
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleState(state, generation: gen) }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    private func handleState(_ state: NWConnection.State, generation gen: UInt64) {
        // A callback from a superseded connection. Its stream was already finished by `start`;
        // acting on it here would corrupt the CURRENT connection's stream.
        guard gen == generation else { return }
        switch state {
        case .ready:
            continuation?.yield(.connected)
            receiveNext(generation: gen)
        case let .failed(error):
            continuation?.yield(.disconnected(reason: error.localizedDescription))
            continuation?.finish()
        case let .waiting(error):
            // `.waiting` means "cannot connect right now, will keep retrying internally" — it is
            // what NWConnection reports for connection-refused and no-route, NOT `.failed`. It was
            // previously swallowed by `default:`, so an unreachable node produced NO event at all:
            // the interface sat in `.connecting` for ever, the UI never updated, and because the
            // reconnect is armed only by `.disconnected` no retry was ever scheduled.
            //
            // Surfacing it as a drop hands retry to `TCPClientInterface`, which bounds it with
            // `reconnectDelay` — so this fail-fast has a rate limiter rather than becoming a spin.
            // Reference RNS bounds the same case with `INITIAL_CONNECT_TIMEOUT` (TCPInterface.py).
            continuation?.yield(.disconnected(reason: "waiting: \(error)"))
            continuation?.finish()
        case .cancelled:
            continuation?.finish()
        default:
            break
        }
    }

    private func receiveNext(generation gen: UInt64) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { await self?.handleReceive(data: data, isComplete: isComplete, error: error, generation: gen) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?, generation gen: UInt64) {
        // Same staleness rule as `handleState`: a receive completion for a superseded connection
        // must not yield into — or finish — the current connection's stream.
        guard gen == generation else { return }
        if let data, !data.isEmpty { continuation?.yield(.data(data)) }
        if let error {
            continuation?.yield(.disconnected(reason: error.localizedDescription)); continuation?.finish(); return
        }
        if isComplete {
            continuation?.yield(.disconnected(reason: nil)); continuation?.finish(); return
        }
        receiveNext(generation: gen)
    }

    func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        // Bump the generation so any callback still in flight for the connection being closed is
        // rejected rather than acting on a later connection's stream.
        generation &+= 1
        connection?.cancel()
        continuation?.finish()
        continuation = nil
        connection = nil
    }
}
#endif
