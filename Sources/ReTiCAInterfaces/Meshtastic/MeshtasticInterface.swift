import Foundation
import ComposableArchitecture

/// Where a `MeshtasticInterface` is in its radio lifecycle.
public enum MeshtasticInterfaceStatus: Equatable, Sendable {
    /// Not started, or stopped by `.stop`.
    case stopped
    /// Started, waiting for the driver's `.connected` (first connect, or after a drop —
    /// reconnecting is MeshtasticKit's job; the interface only waits).
    case connecting
    /// The radio finished its handshake. `modemPreset` is the raw `Config.LoRaConfig.ModemPreset`.
    case online(myNodeNum: UInt32, modemPreset: Int?)
    /// The driver reported the adapter unavailable. A fresh `.start` leaves this state.
    case unavailable(BLEAdapterUnavailable)
}

/// The radio's diagnostics, publicly readable for the app (spec amendment, 2026-10-16): the
/// reassembler's five counters plus the sender's two. Exposed as `MeshtasticEndpoint.State.counters`.
public struct MeshtasticCounters: Equatable, Sendable {
    public var malformed: Int
    public var evicted: Int
    public var timedOut: Int
    public var oversize: Int
    public var completed: Int
    public var queueFull: Int
    public var sendFailed: Int

    public init(malformed: Int = 0, evicted: Int = 0, timedOut: Int = 0, oversize: Int = 0,
                completed: Int = 0, queueFull: Int = 0, sendFailed: Int = 0) {
        self.malformed = malformed
        self.evicted = evicted
        self.timedOut = timedOut
        self.oversize = oversize
        self.completed = completed
        self.queueFull = queueFull
        self.sendFailed = sendFailed
    }
}

/// Reticulum over ONE Meshtastic radio, in landandair/RNS_Over_Meshtastic's fragment format
/// (spec 2026-10-16 §5). Owns the driver lifecycle, inbound reassembly keyed by sending node, and
/// the paced sender: a FIFO of framed fragments, one per `fragmentDelay(preset)` on an injected
/// clock (the first immediately), with REQ answering from a cache of the last 16 packets. It never
/// emits REQ.
@Reducer
public struct MeshtasticInterface {
    /// landandair's queue cap (`process_outgoing`, Meshtastic_Interface.py:212).
    public static let queueCapacity = 256
    /// Packets whose fragments are retained to answer REQ frames.
    public static let requestCacheSize = 16

    public struct Counters: Equatable, Sendable {
        /// Packets dropped whole because their fragments did not fit the queue.
        public var queueFull = 0
        /// Fragments the driver reported as not sent (radio not connected, or the write failed).
        public var sendFailed = 0
        /// REQ frames that re-queued a cached fragment.
        public var requestsAnswered = 0
        public init() {}
    }

    struct QueuedFragment: Equatable, Sendable {
        var frame: Data
        /// A REQ answer: queued at the front and not counted against `queueCapacity`.
        var isRetransmit: Bool
    }

    struct SentPacket: Equatable, Sendable {
        var index: UInt8
        var fragments: [Data]
    }

    @ObservableState
    public struct State: Equatable {
        public let config: MeshtasticDriverConfig
        public let framing: MeshtasticFraming
        public internal(set) var status: MeshtasticInterfaceStatus = .stopped
        public internal(set) var counters = Counters()
        public internal(set) var reassembler = MeshtasticReassembler()
        var queue: [QueuedFragment] = []
        /// landandair's per-interface packet index: starts at 0 (Meshtastic_Interface.py:128) and
        /// wraps at 256 (`calc_index`, L419-420). Advanced only when a packet is actually queued.
        var nextIndex: UInt8 = 0
        /// Oldest first, at most `requestCacheSize`, at most one entry per index (the newest).
        var sentCache: [SentPacket] = []
        /// A fragment went out and its pacing delay has not yet elapsed.
        var pacing = false
        /// `.stop` launched `driver.stop()` and its `.driverStopped` has not arrived yet. The
        /// driver's start and stop run in separate effects, so a start launched now could be torn
        /// down by the stop still in flight; `.start` defers instead.
        var stopping = false
        /// A `.start` arrived while `stopping`: `.driverStopped` starts the driver.
        var restartPending = false

        public init(config: MeshtasticDriverConfig, framing: MeshtasticFraming = .landandair) {
            self.config = config
            self.framing = framing
        }

        public var isOnline: Bool {
            if case .online = status { return true }
            return false
        }

        public var modemPreset: Int? {
            if case let .online(_, preset) = status { return preset }
            return nil
        }

        public var queuedFragmentCount: Int { queue.count }

        /// Stopped with no `driver.stop()` still in flight: nothing of this interface runs, so a
        /// host may drop its state now (spec Contract 3). `.stopped` alone is not enough — a stop
        /// in flight would be cancelled by dropping the state and could race the next start.
        public var isIdle: Bool { status == .stopped && !stopping }

        /// Reassembler and sender counters in one public value (read by `MeshtasticEndpoint`).
        public var diagnostics: MeshtasticCounters {
            let r = reassembler.counters
            return MeshtasticCounters(malformed: r.malformed, evicted: r.evicted, timedOut: r.timedOut,
                                      oversize: r.oversize, completed: r.completed,
                                      queueFull: counters.queueFull, sendFailed: counters.sendFailed)
        }
    }

    public enum Action: Equatable {
        case start
        case stop
        /// One Reticulum packet (already IFAC-masked by the endpoint) to fragment and send.
        case send(Data)
        case driverEvent(MeshtasticDriverEvent)
        case fragmentSent(ok: Bool)
        case pacingElapsed
        /// `driver.stop()` returned: a deferred `.start` may now run.
        case driverStopped
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case online(myNodeNum: UInt32, modemPreset: Int?)
            /// The radio is no longer usable. Reported on a drop or unavailability of an ONLINE
            /// radio, and for every `.stop` — only once `driver.stop()` has returned, so "offline"
            /// means the stop finished (spec Contract 3, amended 2026-10-16). A `.stop` to an
            /// interface that is already idle reports it at once. On the deferred-restart arm a
            /// fresh start follows straight away, so offline is NOT "fully down" there: a consumer
            /// that needs "fully down, the slot may be dropped" checks `state.isIdle`.
            case offline(reason: String?)
            case packetReceived(Data)
            case adapterUnavailable(BLEAdapterUnavailable)
        }
    }

    @Dependency(\.meshtasticDriver) var driver
    @Dependency(\.meshtasticClock) var clock
    @Dependency(\.meshtasticDate) var date

    private enum CancelID: Hashable { case driver, pacing }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .start:
                switch state.status {
                case .stopped, .unavailable: break
                case .connecting, .online: return .none
                }
                state.status = .connecting
                if state.stopping {
                    state.restartPending = true
                    return .none
                }
                return startDriver(state)

            case .stop:
                guard state.status != .stopped else {
                    // A host that sends `.stop` waits for offline (Contract 3), so an already idle
                    // interface answers at once. With a `driver.stop()` still in flight, its
                    // `.driverStopped` answers for this stop too: offline must mean "fully down".
                    return state.stopping ? .none : .send(.delegate(.offline(reason: nil)))
                }
                state.status = .stopped
                if state.restartPending {
                    // The deferred start never reached the driver. The stop already in flight
                    // covers this one, and its `.driverStopped` reports offline.
                    state.restartPending = false
                    return .none
                }
                state.stopping = true
                clearTraffic(&state)
                return .merge(.cancel(id: CancelID.driver),
                              .cancel(id: CancelID.pacing),
                              .run { [driver] send in
                                  await driver.stop()
                                  await send(.driverStopped)
                              })

            case .driverStopped:
                state.stopping = false
                // Contract 3 (amended): the stop-initiated offline, now that `driver.stop()` has
                // returned. Also when a deferred `.start` runs next, and BEFORE it, so the host
                // deregisters the radio's interface before the restarted driver re-registers it.
                guard state.restartPending else { return .send(.delegate(.offline(reason: nil))) }
                state.restartPending = false
                return .concatenate(.send(.delegate(.offline(reason: nil))), startDriver(state))

            case let .driverEvent(.connected(myNodeNum, modemPreset)):
                guard state.status != .stopped else { return .none }
                state.status = .online(myNodeNum: myNodeNum, modemPreset: modemPreset)
                return .merge(.send(.delegate(.online(myNodeNum: myNodeNum, modemPreset: modemPreset))),
                              pump(&state))

            case let .driverEvent(.disconnected(reason)):
                guard state.status != .stopped else { return .none }
                let wasOnline = state.isOnline
                // A drop of a radio that never came online must not hide an `.unavailable` already
                // reported: `.connecting` would make a later `.start` a no-op.
                if case .unavailable = state.status { return .none }
                state.status = .connecting
                clearTraffic(&state)
                var effects: [Effect<Action>] = [.cancel(id: CancelID.pacing)]
                if wasOnline { effects.append(.send(.delegate(.offline(reason: reason)))) }
                return .merge(effects)

            case let .driverEvent(.unavailable(cause)):
                guard state.status != .stopped else { return .none }
                let wasOnline = state.isOnline
                state.status = .unavailable(cause)
                clearTraffic(&state)
                var effects: [Effect<Action>] = [.cancel(id: CancelID.pacing)]
                if wasOnline { effects.append(.send(.delegate(.offline(reason: nil)))) }
                effects.append(.send(.delegate(.adapterUnavailable(cause))))
                return .merge(effects)

            case let .driverEvent(.fragment(from, frame)):
                guard state.isOnline else { return .none }
                switch state.framing.codec.parse(frame) {
                case nil:
                    state.reassembler.recordMalformed()
                    return .none
                case let .data(index, pos, body):
                    guard let packet = state.reassembler.receive(from: from, index: index, pos: pos,
                                                                 body: body, now: date())
                    else { return .none }
                    return .send(.delegate(.packetReceived(packet)))
                case let .request(index, pos):
                    return answerRequest(&state, index: index, pos: pos)
                }

            case let .send(packet):
                guard state.isOnline else { return .none }
                let index = state.nextIndex
                let fragments = state.framing.codec.split(packet, index: index)
                guard !fragments.isEmpty else { return .none }
                let pending = state.queue.lazy.filter { !$0.isRetransmit }.count
                guard pending + fragments.count <= Self.queueCapacity else {
                    state.counters.queueFull += 1
                    return .none
                }
                state.queue.append(contentsOf: fragments.map { QueuedFragment(frame: $0, isRetransmit: false) })
                state.sentCache.removeAll { $0.index == index }
                state.sentCache.append(SentPacket(index: index, fragments: fragments))
                if state.sentCache.count > Self.requestCacheSize {
                    state.sentCache.removeFirst(state.sentCache.count - Self.requestCacheSize)
                }
                state.nextIndex &+= 1
                return pump(&state)

            case let .fragmentSent(ok):
                if !ok { state.counters.sendFailed += 1 }
                return .none

            case .pacingElapsed:
                state.pacing = false
                return pump(&state)

            case .delegate:
                return .none
            }
        }
    }

    private func startDriver(_ state: State) -> Effect<Action> {
        let config = state.config
        return .run { [driver] send in
            for await event in driver.start(config) {
                await send(.driverEvent(event))
            }
        }
        .cancellable(id: CancelID.driver, cancelInFlight: true)
    }

    /// Send the queue head now if the radio is online and no pacing window is open. landandair
    /// sleeps after EVERY send (L304); we do the same but never delay the first.
    private func pump(_ state: inout State) -> Effect<Action> {
        guard state.isOnline, !state.pacing, !state.queue.isEmpty else { return .none }
        let frame = state.queue.removeFirst().frame
        state.pacing = true
        let delay = MeshtasticModemPreset.fragmentDelay(state.modemPreset)
        return .run { [driver, clock] send in
            let ok = await driver.send(frame)
            await send(.fragmentSent(ok: ok))
            try await clock.sleep(for: delay)
            await send(.pacingElapsed)
        }
        .cancellable(id: CancelID.pacing, cancelInFlight: true)
    }

    /// A REQ for (index, |pos|) re-queues that cached fragment at the FRONT. Unknown index or
    /// out-of-range position: ignored. A fragment already queued is not queued again — any peer
    /// can broadcast REQs, so without that the front of the queue would grow without bound.
    ///
    /// Known v1 limit: answers ALWAYS go to the queue front (landandair-faithful, spec-mandated).
    /// A peer that REQs once per pacing window therefore keeps a retransmit at the head and can
    /// starve fresh traffic queued behind it.
    private func answerRequest(_ state: inout State, index: UInt8, pos: Int8) -> Effect<Action> {
        let slot = Int(pos.magnitude)   // never abs(): abs(Int8.min) traps
        guard let packet = state.sentCache.last(where: { $0.index == index }),
              (1...packet.fragments.count).contains(slot)
        else { return .none }
        let frame = packet.fragments[slot - 1]
        guard !state.queue.contains(where: { $0.frame == frame }) else { return .none }
        state.queue.insert(QueuedFragment(frame: frame, isRetransmit: true), at: 0)
        state.counters.requestsAnswered += 1
        return pump(&state)
    }

    /// A drop: forget queued fragments, partial packets and the pacing window. The REQ cache and
    /// the index survive — a peer may still ask for a fragment it missed before the drop.
    private func clearTraffic(_ state: inout State) {
        state.queue = []
        state.pacing = false
        state.reassembler.reset()
    }
}
