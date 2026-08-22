import Foundation
import ComposableArchitecture
import ReTiCA

/// A Reticulum TCP SERVER interface: listens on a port, accepts N simultaneous connections, and
/// for each one deframes inbound bytes into packet frames and frames+sends outbound bytes. Framing
/// is HDLC — identical wire protocol to `TCPClientInterface`; the only structural difference is
/// that everything is keyed per accepted connection (`TCPConnID`), including one `HDLCDeframer`
/// each, so a partial frame on one connection never corrupts another's stream.
///
/// Packet parsing stays at the Transport layer (this interface stays byte-level). It mirrors
/// `TCPClientInterface` but with no reconnect: a server does not dial, so a closed connection is
/// simply dropped and its deframer removed.
@Reducer
public struct TCPServerInterface {
    @ObservableState
    public struct State: Equatable {
        public var port: UInt16
        public var status: Status
        /// One deframer per live connection. An accepted connection gets a fresh deframer; a
        /// closed one has its deframer removed, so buffered partial bytes never leak across
        /// connections or outlive the socket.
        var deframers: [TCPConnID: HDLCDeframer]

        public init(port: UInt16) {
            self.port = port
            self.status = .stopped
            self.deframers = [:]
        }
    }

    public enum Status: Equatable { case stopped, listening }

    public enum Action: Equatable {
        case listen
        case stop
        case listenerEvent(TCPListenerEvent)
        case send(conn: TCPConnID, Data)
        case delegate(Delegate)
        @CasePathable
        public enum Delegate: Equatable {
            case connectionAccepted(TCPConnID)
            case packetReceived(TCPConnID, Data)
            case connectionClosed(TCPConnID)
        }
    }

    @Dependency(\.tcpListener) var tcpListener

    private enum CancelID { case listener }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { [tcpListener] state, action in
            switch action {
            case .listen:
                state.status = .listening
                let port = state.port
                return .run { send in
                    for await event in tcpListener.listen(port) {
                        await send(.listenerEvent(event))
                    }
                }
                .cancellable(id: CancelID.listener, cancelInFlight: true)

            case .stop:
                state.status = .stopped
                state.deframers.removeAll()
                return .merge(
                    .cancel(id: CancelID.listener),
                    .run { _ in await tcpListener.stop() }
                )

            case .listenerEvent(.started):
                state.status = .listening
                return .none

            case .listenerEvent(.failed):
                state.status = .stopped
                state.deframers.removeAll()
                return .none

            case let .listenerEvent(.accepted(conn)):
                // Fresh, per-connection deframer.
                state.deframers[conn] = HDLCDeframer()
                return .send(.delegate(.connectionAccepted(conn)))

            case let .listenerEvent(.data(conn, bytes)):
                // Deframe against THIS connection's deframer. If the connection is unknown
                // (accepted event not yet seen — should not happen given ordering) drop.
                guard state.deframers[conn] != nil else { return .none }
                let frames = state.deframers[conn]!.ingest(bytes)
                return .merge(frames.map { .send(.delegate(.packetReceived(conn, $0))) })

            case let .listenerEvent(.closed(conn, _)):
                state.deframers[conn] = nil
                return .send(.delegate(.connectionClosed(conn)))

            case let .send(conn, raw):
                let framed = HDLC.frame(raw)
                return .run { _ in await tcpListener.send(conn, framed) }

            case .delegate:
                return .none
            }
        }
    }
}
