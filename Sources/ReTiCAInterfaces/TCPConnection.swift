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

/// TCP socket dependency. The live value wraps `NWConnection`; tests inject a mock so no
/// automated test touches a real socket.
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

    func start(host: String, port: UInt16, continuation: AsyncStream<TCPEvent>.Continuation) {
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
            Task { await self?.handleState(state) }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            continuation?.yield(.connected)
            receiveNext()
        case let .failed(error):
            continuation?.yield(.disconnected(reason: error.localizedDescription))
            continuation?.finish()
        case .cancelled:
            continuation?.finish()
        default:
            break
        }
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { await self?.handleReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty { continuation?.yield(.data(data)) }
        if let error {
            continuation?.yield(.disconnected(reason: error.localizedDescription)); continuation?.finish(); return
        }
        if isComplete {
            continuation?.yield(.disconnected(reason: nil)); continuation?.finish(); return
        }
        receiveNext()
    }

    func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        connection?.cancel()
        continuation?.finish()
        connection = nil
    }
}
#endif
