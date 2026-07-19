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

    private enum CancelID { case connection }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { [tcpConnection, clock] state, action in
            switch action {
            case .connect:
                state.status = .connecting
                let host = state.host
                let port = state.port
                return .run { send in
                    for await event in tcpConnection.open(host, port) {
                        await send(.connectionEvent(event))
                    }
                }
                .cancellable(id: CancelID.connection, cancelInFlight: true)

            case .disconnect:
                state.status = .disconnected
                return .merge(
                    .cancel(id: CancelID.connection),
                    .run { _ in await tcpConnection.close() }
                )

            case .connectionEvent(.connected):
                state.status = .online
                return .none

            case let .connectionEvent(.data(bytes)):
                let frames = state.deframer.ingest(bytes)
                return .merge(frames.map { .send(.delegate(.packetReceived($0))) })

            case .connectionEvent(.disconnected):
                state.status = .disconnected
                guard state.reconnectOnDrop else { return .none }
                return .run { send in
                    try await clock.sleep(for: TCPClientInterface.reconnectDelay)
                    await send(.connect)
                }

            case let .send(raw):
                let framed = HDLC.frame(raw)
                return .run { _ in await tcpConnection.send(framed) }

            case .delegate:
                return .none
            }
        }
    }
}
