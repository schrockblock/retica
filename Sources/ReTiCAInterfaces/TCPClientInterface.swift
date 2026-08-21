import Foundation
import ComposableArchitecture
import ReTiCA

/// A Reticulum TCP client interface: connects out to a node, deframes inbound bytes into
/// packet frames, frames+sends outbound bytes, and reconnects on drop. Framing is HDLC;
/// packet parsing is left to the Transport layer (this interface stays byte-level).
@Reducer
public struct TCPClientInterface {
    /// Delay before an automatic reconnect after an unexpected drop.
    public static let reconnectDelay: Duration = .seconds(5)

    @ObservableState
    public struct State: Equatable {
        public var host: String
        public var port: UInt16
        public var status: Status
        public var reconnectOnDrop: Bool
        var deframer: HDLCDeframer

        public init(host: String, port: UInt16, reconnectOnDrop: Bool = true) {
            self.host = host
            self.port = port
            self.status = .disconnected
            self.reconnectOnDrop = reconnectOnDrop
            self.deframer = HDLCDeframer()
        }
    }

    public enum Status: Equatable { case disconnected, connecting, online }

    public enum Action: Equatable {
        case connect
        case disconnect
        case connectionEvent(TCPEvent)
        case send(Data)
        case delegate(Delegate)
        public enum Delegate: Equatable { case packetReceived(Data) }
    }

    @Dependency(\.tcpConnection) var tcpConnection
    @Dependency(\.continuousClock) var clock

    private enum CancelID { case connection, reconnect }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { [tcpConnection, clock] state, action in
            switch action {
            case .connect:
                state.status = .connecting
                let host = state.host
                let port = state.port
                return .merge(
                    // A dial supersedes any armed reconnect; otherwise the backoff fires on top of
                    // the connection it was scheduled to replace.
                    .cancel(id: CancelID.reconnect),
                    .run { send in
                        for await event in tcpConnection.open(host, port) {
                            await send(.connectionEvent(event))
                        }
                        // The stream can END without a terminal event — `.cancelled` finishes it
                        // silently. Without this the `for await` just exits: status stays
                        // `.connecting`, no `interfaceDisconnected` is emitted, and since the
                        // reconnect is armed ONLY by `.disconnected`, nothing ever retries. Every
                        // stream end is now observable, so the dead end cannot reopen.
                        // `Task.isCancelled` distinguishes a real end from `.disconnect`/supersede.
                        if !Task.isCancelled {
                            await send(.connectionEvent(.disconnected(reason: "connection stream ended")))
                        }
                    }
                    .cancellable(id: CancelID.connection, cancelInFlight: true)
                )

            case .disconnect:
                state.status = .disconnected
                return .merge(
                    .cancel(id: CancelID.connection),
                    // An explicit disconnect must also disarm a pending reconnect, or the interface
                    // silently re-dials 5s after the user asked it to stop.
                    .cancel(id: CancelID.reconnect),
                    .run { _ in await tcpConnection.close() }
                )

            case .connectionEvent(.connected):
                state.status = .online
                return .none

            case let .connectionEvent(.data(bytes)):
                let frames = state.deframer.ingest(bytes)
                return .merge(frames.map { .send(.delegate(.packetReceived($0))) })

            case .connectionEvent(.disconnected):
                // Only the FIRST drop arms a reconnect. A single failure can now surface more than
                // once (e.g. `.waiting` yields a drop and the stream then ends), and arming per
                // event would stack overlapping backoffs that each dial a connection.
                let alreadyDown = state.status == .disconnected
                state.status = .disconnected
                guard state.reconnectOnDrop, !alreadyDown else { return .none }
                return .run { send in
                    try await clock.sleep(for: TCPClientInterface.reconnectDelay)
                    await send(.connect)
                }
                .cancellable(id: CancelID.reconnect, cancelInFlight: true)

            case let .send(raw):
                let framed = HDLC.frame(raw)
                return .run { _ in await tcpConnection.send(framed) }

            case .delegate:
                return .none
            }
        }
    }
}
