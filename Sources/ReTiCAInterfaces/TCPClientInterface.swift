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
        /// Tags each writer batch. Bumped whenever the writer is reset (a fresh connection, an
        /// explicit disconnect), so a `.writerFinished` from a superseded writer is ignored.
        var writerGeneration: UInt64

        /// What this interface dials, as the `TCPConnectionPool` keys it. Stable for the life of a
        /// socket: the endpoint rebuilds a slot rather than re-pointing a live one.
        public var connectionKey: String { "\(host):\(port)" }

        public init(host: String, port: UInt16, reconnectOnDrop: Bool = true) {
            self.host = host
            self.port = port
            self.status = .disconnected
            self.reconnectOnDrop = reconnectOnDrop
            self.deframer = HDLCDeframer()
            self.outbox = []
            self.isWriting = false
            self.writerGeneration = 0
        }
    }

    public enum Status: Equatable { case disconnected, connecting, online }

    public enum Action: Equatable {
        case connect
        case disconnect
        case connectionEvent(TCPEvent)
        case send(Data)
        /// The writer of `generation` finished the batch it took from `outbox`. Internal bookkeeping.
        case writerFinished(generation: UInt64)
        case delegate(Delegate)
        public enum Delegate: Equatable { case packetReceived(Data) }
    }

    @Dependency(\.tcpConnectionPool) var connectionPool
    @Dependency(\.continuousClock) var clock

    private enum CancelID { case connection, reconnect, writer }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { [connectionPool, clock] state, action in
            // Each interface dials through its OWN socket (see `TCPConnectionPool`), resolved per
            // reduce from the current host:port. Resolving here rather than once at init keeps the
            // dependency context the store's, so a test's injected pool (or `\.tcpConnection`) wins.
            let tcpConnection = connectionPool.connection(state.connectionKey)
            // Start the single writer if it is idle and there is anything to write. It takes the
            // WHOLE outbox as one batch and awaits each `tcpConnection.send` before starting the
            // next, so frames reach the connection in exactly outbox order. Frames reduced while a
            // batch is in flight wait in `outbox` for the next batch (started by `.writerFinished`).
            //
            // CANCELLATION. A writer that is cancelled (or that simply never reports back) never
            // delivers its `.writerFinished`, which would leave `isWriting` true for ever and
            // silently queue every later frame — total TX loss. So the writer is not trusted to
            // report back: `resetWriter` (on a fresh connection and on an explicit disconnect)
            // cancels whatever writer is running, clears `isWriting`, and bumps
            // `writerGeneration`. Each batch carries its generation, and a `.writerFinished` from
            // a superseded generation is ignored, so a late report can never start a second
            // writer. `cancelInFlight` on the one shared cancel ID cancels any other writer when
            // one starts.
            //
            // Cancelling is not enough on its own: `tcpConnection.send` ignores cancellation (the
            // live `NWConnectionActor.send` just writes), so a cancelled writer would carry on
            // through its batch while the next generation's writer starts on the outbox — two
            // writers hopping the actor at once, frames interleaving. Hence the check before EACH
            // frame: a superseded writer stops after at most the one send it had already issued,
            // and the rest of its batch (meant for the superseded connection) is dropped.
            func startWriter(_ state: inout State) -> Effect<Action> {
                guard !state.isWriting, !state.outbox.isEmpty else { return .none }
                let batch = state.outbox
                let generation = state.writerGeneration
                state.outbox = []
                state.isWriting = true
                return .run { send in
                    for frame in batch {
                        guard !Task.isCancelled else { return }
                        await tcpConnection.send(frame)
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
                // Frames still queued were for the connection being closed; drop them with it.
                state.outbox = []
                return .merge(
                    .cancel(id: CancelID.connection),
                    // An explicit disconnect must also disarm a pending reconnect, or the interface
                    // silently re-dials 5s after the user asked it to stop.
                    .cancel(id: CancelID.reconnect),
                    resetWriter(&state),
                    .run { _ in await tcpConnection.close() }
                )

            case .connectionEvent(.connected):
                state.status = .online
                // A fresh connection starts from a known-good writer, whatever happened to the
                // last one; anything queued meanwhile is written now, in order.
                return resetWriter(&state)

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
