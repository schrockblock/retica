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
        /// Framed bytes waiting for the single writer, in the order their `.send`s were REDUCED.
        /// One queue for all connections: that keeps every connection's frames in order (and
        /// costs no fairness worth having, since `tcpListener.send` only enqueues on the socket).
        var outbox: [OutboundFrame]
        /// True while the one writer effect is draining a batch.
        var isWriting: Bool
        /// Tags each writer batch; bumped when the writer is reset (listener (re)started or
        /// stopped), so a `.writerFinished` from a superseded writer is ignored.
        var writerGeneration: UInt64

        public init(port: UInt16) {
            self.port = port
            self.status = .stopped
            self.deframers = [:]
            self.outbox = []
            self.isWriting = false
            self.writerGeneration = 0
        }
    }

    struct OutboundFrame: Equatable, Sendable {
        var conn: TCPConnID
        var framed: Data
    }

    public enum Status: Equatable { case stopped, listening }

    public enum Action: Equatable {
        case listen
        case stop
        case listenerEvent(TCPListenerEvent)
        case send(conn: TCPConnID, Data)
        /// The writer of `generation` finished the batch it took from `outbox`. Internal bookkeeping.
        case writerFinished(generation: UInt64)
        case delegate(Delegate)
        @CasePathable
        public enum Delegate: Equatable {
            case connectionAccepted(TCPConnID)
            case packetReceived(TCPConnID, Data)
            case connectionClosed(TCPConnID)
        }
    }

    @Dependency(\.tcpListener) var tcpListener

    private enum CancelID { case listener, writer }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { [tcpListener] state, action in
            // Same single-writer FIFO as `TCPClientInterface` — see its `.send` for why outbound
            // order must be fixed at reduce time rather than by one `.run` Task per frame — and
            // its CANCELLATION note for why a writer is reset (generation bump) rather than trusted
            // to report back, and why the writer checks for cancellation before EVERY frame (the
            // send itself ignores cancellation). Here the reset points are the listener starting
            // and stopping.
            func startWriter(_ state: inout State) -> Effect<Action> {
                guard !state.isWriting, !state.outbox.isEmpty else { return .none }
                let batch = state.outbox
                let generation = state.writerGeneration
                state.outbox = []
                state.isWriting = true
                return .run { send in
                    for item in batch {
                        guard !Task.isCancelled else { return }
                        await tcpListener.send(item.conn, item.framed)
                    }
                    await send(.writerFinished(generation: generation))
                }
                .cancellable(id: CancelID.writer, cancelInFlight: true)
            }
            func resetWriter(_ state: inout State) -> Effect<Action> {
                state.writerGeneration &+= 1
                state.isWriting = false
                return .concatenate(.cancel(id: CancelID.writer), startWriter(&state))
            }

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
                state.outbox = []   // every connection goes with the listener
                return .merge(
                    .cancel(id: CancelID.listener),
                    resetWriter(&state),
                    .run { _ in await tcpListener.stop() }
                )

            case .listenerEvent(.started):
                state.status = .listening
                return resetWriter(&state)

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
                guard var deframer = state.deframers[conn] else { return .none }
                let frames = deframer.ingest(bytes)
                state.deframers[conn] = deframer
                return .merge(frames.map { .send(.delegate(.packetReceived(conn, $0))) })

            case let .listenerEvent(.closed(conn, _)):
                state.deframers[conn] = nil
                return .send(.delegate(.connectionClosed(conn)))

            case let .send(conn, raw):
                state.outbox.append(OutboundFrame(conn: conn, framed: HDLC.frame(raw)))
                return startWriter(&state)

            case let .writerFinished(generation):
                guard generation == state.writerGeneration else { return .none }   // superseded
                state.isWriting = false
                return startWriter(&state)

            case .delegate:
                return .none
            }
        }
    }
}
