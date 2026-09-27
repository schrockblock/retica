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
        /// Framed bytes waiting for the single writer, in the order their `.send`s were REDUCED.
        /// See `.send` for why outbound order has to be fixed here rather than in the socket layer.
        var outbox: [Data]
        /// True while the one writer effect is draining a batch. At most one is ever in flight.
        var isWriting: Bool

        public init(host: String, port: UInt16, reconnectOnDrop: Bool = true) {
            self.host = host
            self.port = port
            self.status = .disconnected
            self.reconnectOnDrop = reconnectOnDrop
            self.deframer = HDLCDeframer()
            self.outbox = []
            self.isWriting = false
        }
    }

    public enum Status: Equatable { case disconnected, connecting, online }

    public enum Action: Equatable {
        case connect
        case disconnect
        case connectionEvent(TCPEvent)
        case send(Data)
        /// The writer finished the batch it took from `outbox`. Internal bookkeeping.
        case writerFinished
        case delegate(Delegate)
        public enum Delegate: Equatable { case packetReceived(Data) }
    }

    @Dependency(\.tcpConnection) var tcpConnection
    @Dependency(\.continuousClock) var clock

    private enum CancelID { case connection, reconnect }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { [tcpConnection, clock] state, action in
            // Start the single writer if it is idle and there is anything to write. It takes the
            // WHOLE outbox as one batch and awaits each `tcpConnection.send` before starting the
            // next, so frames reach the connection in exactly outbox order. Frames reduced while a
            // batch is in flight wait in `outbox` for the next batch (started by `.writerFinished`).
            //
            // Not cancellable, deliberately: a cancelled writer would never report
            // `.writerFinished`, leaving `isWriting` stuck and every later frame queued for ever.
            // The live `send` returns as soon as `NWConnection.send` has queued the bytes, so a
            // batch always finishes promptly; on a dropped connection its frames are discarded by
            // the connection layer exactly as a lone send's were.
            func startWriter(_ state: inout State) -> Effect<Action> {
                guard !state.isWriting, !state.outbox.isEmpty else { return .none }
                let batch = state.outbox
                state.outbox = []
                state.isWriting = true
                return .run { send in
                    for frame in batch { await tcpConnection.send(frame) }
                    await send(.writerFinished)
                }
            }

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
                // ORDERING. This used to be `.run { _ in await tcpConnection.send(framed) }` — one
                // unstructured Task PER FRAME. TCA starts each `.run` as its own `Task`
                // (ComposableArchitecture/Core.swift, `case .run` → `Task(name:priority:)`), the
                // nonisolated operation runs on the global concurrent executor, and independent
                // Tasks reach `NWConnectionActor.send` in no guaranteed order. So two frames
                // reduced A-then-B could hit the socket B-then-A. That is not hypothetical: on a
                // link initiator the LRRTT is transmitted in the proof branch and LINKIDENTIFY /
                // REQUEST follow in later `.send`s; reordered, the responder sees the request
                // while still in `.handshake`, and the request times out ~11 s later.
                //
                // The order is fixed HERE, synchronously, at reduce time — the only point at which
                // it is known. Any FIFO further down (an AsyncStream writer, a serial queue in the
                // actor) is fed through the same racing Tasks and cannot recover it.
                state.outbox.append(HDLC.frame(raw))
                return startWriter(&state)

            case .writerFinished:
                state.isWriting = false
                return startWriter(&state)

            case .delegate:
                return .none
            }
        }
    }
}
