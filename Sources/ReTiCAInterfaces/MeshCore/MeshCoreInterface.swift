import Foundation
import ComposableArchitecture

/// Where a `MeshCoreInterface` is in its radio lifecycle.
public enum MeshCoreInterfaceStatus: Equatable, Sendable {
    /// Not started, or stopped by `.stop`.
    case stopped
    /// Started, waiting for the driver's `.connected` (first connect, or after a drop —
    /// reconnecting is the live adapter's job; the interface only waits).
    case connecting
    /// The radio finished its handshake. `selfPrefix` is the first 4 bytes of `publicKey`.
    case online(selfPrefix: Data, publicKey: Data, params: MeshCoreLinkParams?)
    /// The driver reported the adapter unavailable. A fresh `.start` leaves this state.
    case unavailable(BLEAdapterUnavailable)
}

/// The radio's diagnostics, publicly readable for the app (spec Contract 3): the reassembler's
/// five counters, the receive rules' and sender's three, and the limiter's two.
public struct MeshCoreCounters: Equatable, Sendable {
    public var malformed: Int
    public var notAddressed: Int
    public var evicted: Int
    public var timedOut: Int
    public var oversize: Int
    public var completed: Int
    public var queueFull: Int
    public var sendFailed: Int
    public var announcesLimited: Int
    public var pathRequestsLimited: Int

    public init(malformed: Int = 0, notAddressed: Int = 0, evicted: Int = 0, timedOut: Int = 0,
                oversize: Int = 0, completed: Int = 0, queueFull: Int = 0, sendFailed: Int = 0,
                announcesLimited: Int = 0, pathRequestsLimited: Int = 0) {
        self.malformed = malformed
        self.notAddressed = notAddressed
        self.evicted = evicted
        self.timedOut = timedOut
        self.oversize = oversize
        self.completed = completed
        self.queueFull = queueFull
        self.sendFailed = sendFailed
        self.announcesLimited = announcesLimited
        self.pathRequestsLimited = pathRequestsLimited
    }
}

/// Reticulum over ONE MeshCore radio, in ScotMesh's Raw tunnel format (spec 2026-11-07 §5). Owns
/// the driver lifecycle, the §5.2 receive rules, inbound reassembly keyed `(src, packetID)`, the
/// §5.4 paced sender, §5.3 `BIND` replies, and slot removal. The limiter's state lives here but
/// this reducer never touches it: `TransportEndpoint` runs it on unmasked packets.
@Reducer
public struct MeshCoreInterface {
    /// The sender's FIFO cap, in datagrams (spec §5.4).
    public static let queueCapacity = 64
    /// At most one `BIND` per this many seconds, measured from enqueue (spec §5.3).
    static let bindInterval: TimeInterval = 60

    struct Counters: Equatable, Sendable {
        /// Datagrams addressed to a prefix that is neither ours nor broadcast.
        var notAddressed = 0
        /// Packets dropped whole because their datagrams did not fit the queue.
        var queueFull = 0
        /// Datagrams the driver reported as not sent.
        var sendFailed = 0
    }

    @ObservableState
    public struct State: Equatable {
        public internal(set) var config: MeshCoreDriverConfig
        public let framing: MeshCoreFraming
        public internal(set) var status: MeshCoreInterfaceStatus = .stopped
        public internal(set) var reassembler = MeshCoreReassembler()
        /// §5.5 limiter state. Mutated only by `TransportEndpoint`; survives `.disconnected`,
        /// `.stop` and reconnect, so a flapping BLE link can't refill the budgets.
        public var limiter = MeshCoreAnnounceLimiter()
        var counters = Counters()
        /// `.stop` launched `driver.stop()` and its `.driverStopped` has not arrived yet. The
        /// driver's start and stop run in separate effects, so a start launched now could be torn
        /// down by the stop still in flight; `.start` defers instead.
        var stopping = false
        /// A `.start` arrived while `stopping`: `.driverStopped` starts the driver.
        var restartPending = false
        /// `.driverStopped` queued the deferred start (`.restartDeferred`) behind its offline
        /// delegate. A `.stop` the host sends in answer to that offline is reduced first and
        /// clears this, so the queued start then does nothing — the stop wins.
        var restartQueued = false
        /// Bumped by every `.stop` that reaches the driver, at reduce time: a start effect built
        /// before it never calls `driver.start()` (see `DriverEpoch`).
        var epoch = DriverEpoch()
        /// `driver.removeChannel()` is running; its `.channelRemovalFinished` has not arrived.
        var removingChannel = false
        /// A `.stop` arrived during a removal. It runs once the removal finishes, so the driver
        /// sees `removeChannel` then `stop`, and offline comes after `.channelRemoved`.
        var stopHeld = false
        /// A `.start` arrived after a held stop. It runs right after that stop, once the removal
        /// finishes, so it reaches the driver after the stop (Contract 3). A later `.stop` clears it.
        var startHeld = false
        /// Framed datagrams waiting for the radio, oldest first. Excludes the one in flight.
        var queue: [Data] = []
        /// A datagram went out and its pacing delay has not yet elapsed.
        var pacing = false
        /// The next fragment/`BIND` packet ID. Drawn at the first `.connected`, then kept across
        /// reconnects and stop/start so a key isn't reused inside a peer's 30 s dedupe.
        var nextPacketID: UInt16?
        /// A `BIND_REQ` scheduled a reply whose random delay has not elapsed yet.
        var bindReplyPending = false
        /// When the last `BIND` was enqueued. Survives a drop, so reconnecting can't reset the
        /// 60 s limit.
        var lastBindSent: Date?

        public init(config: MeshCoreDriverConfig, framing: MeshCoreFraming = .scotMeshRaw) {
            self.config = config
            self.framing = framing
        }

        public var isOnline: Bool {
            if case .online = status { return true }
            return false
        }

        public var params: MeshCoreLinkParams? {
            if case let .online(_, _, params) = status { return params }
            return nil
        }

        /// Stopped with no `driver.stop()` still in flight: nothing of this interface runs, so a
        /// host may drop its state now (spec Contract 3). `.stopped` alone is not enough: a
        /// `driver.stop()` is still in flight, and what dropping the state does to it depends on
        /// WHO drops it. An `ifLet` cancels the child's effects only when its own parent reducer
        /// nils the state; a host outside that reducer leaves the stop running, and its
        /// `.driverStopped` then reaches an `ifLet` with no state (TCA's runtime warning). Either
        /// way the next slot's start could race the old stop. A held stop leaves the status
        /// unchanged until the removal finishes, so it is not idle either.
        public var isIdle: Bool { status == .stopped && !stopping }

        /// Datagrams waiting to be sent, not counting the one in flight.
        public var queuedDatagramCount: Int { queue.count }

        /// Every counter in one public value (read by `MeshCoreEndpoint`).
        public var diagnostics: MeshCoreCounters {
            let r = reassembler.counters
            let l = limiter.counters
            return MeshCoreCounters(malformed: r.malformed, notAddressed: counters.notAddressed,
                                    evicted: r.evicted, timedOut: r.timedOut, oversize: r.oversize,
                                    completed: r.completed, queueFull: counters.queueFull,
                                    sendFailed: counters.sendFailed,
                                    announcesLimited: l.announcesLimited,
                                    pathRequestsLimited: l.pathRequestsLimited)
        }
    }

    public enum Action: Equatable {
        case start
        case stop
        /// Clear the radio's channel slot holding our key (feature turned off). Answered by
        /// `.delegate(.channelRemoved)`.
        case removeChannel
        case driverEvent(MeshCoreDriverEvent)
        /// `driver.stop()` returned: a deferred `.start` may now run.
        case driverStopped
        /// The deferred start, sent from a task after the stop-initiated offline so a `.stop` the
        /// host reduces in that offline's burst wins (it clears `restartQueued`). Ignored unless
        /// `restartQueued`, so a copy routed to a replacement slot's state does nothing.
        case restartDeferred
        /// `driver.removeChannel()` returned.
        case channelRemovalFinished(Bool)
        /// An outbound Reticulum packet, already IFAC-masked. Dropped unless online.
        case send(Data)
        /// The app's Relay setting changed: the can-route bit of every packet framed from now on.
        /// Queued datagrams keep the bit they were framed with; the driver is not restarted.
        case setCanRoute(Bool)
        /// `driver.send` returned.
        case datagramSent(ok: Bool)
        case pacingElapsed
        /// A `BIND_REQ`'s random reply delay elapsed.
        case bindDelayElapsed
        case delegate(Delegate)

        public enum Delegate: Equatable, Sendable {
            case online(selfPrefix: Data, publicKey: Data, params: MeshCoreLinkParams?)
            /// The radio is no longer usable. Reported on a drop or unavailability of an ONLINE
            /// radio, and for every `.stop` — only once `driver.stop()` has returned, so "offline"
            /// means the stop finished (spec Contract 3). A `.stop` to an interface that is
            /// already idle reports it at once. On the deferred-restart arm a fresh start follows
            /// unless the host answers this offline with `.stop`, which wins; a consumer that
            /// needs "fully down, the slot may be dropped" checks `state.isIdle`.
            case offline(reason: String?)
            case packetReceived(Data)
            case adapterUnavailable(BLEAdapterUnavailable)
            /// The driver cleared slots holding retired keys; the app may forget them.
            case retiredChannelsCleared
            /// The answer to `.removeChannel`: whether the radio cleared our slot.
            case channelRemoved(Bool)
        }
    }

    @Dependency(\.meshCoreDriver) var driver
    @Dependency(\.meshCoreDate) var date
    @Dependency(\.meshCoreClock) var clock
    @Dependency(\.meshCoreRandom) var random

    private enum CancelID: Hashable { case driver, pacing, bindReply }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .start:
                if state.stopHeld {
                    // The host's stop is waiting for the removal: this start must follow it, not
                    // be lost to the still-online status or launch a driver the stop then ends.
                    state.startHeld = true
                    return .none
                }
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
                if state.removingChannel {
                    // Review Focus 5: the removal must finish first, so the driver sees
                    // `removeChannel` then `stop`, and offline comes after `.channelRemoved`.
                    state.stopHeld = true
                    // Stop, start, stop: the last word is stop.
                    state.startHeld = false
                    return .none
                }
                guard state.status != .stopped else {
                    // A host that sends `.stop` waits for offline (Contract 3), so an already idle
                    // interface answers at once. With a `driver.stop()` still in flight, its
                    // `.driverStopped` answers for this stop too: offline must mean "fully down".
                    return state.stopping ? .none : .send(.delegate(.offline(reason: nil)))
                }
                state.status = .stopped
                state.restartQueued = false
                if state.restartPending {
                    // The deferred start never reached the driver. The stop already in flight
                    // covers this one, and its `.driverStopped` reports offline.
                    state.restartPending = false
                    return .none
                }
                state.stopping = true
                // Here, not in the stop effect: a start effect built in this same burst has not
                // registered its cancel id yet, so the `.cancel(id: .driver)` below misses it.
                state.epoch.invalidate()
                clearTraffic(&state)
                return .merge(.cancel(id: CancelID.driver),
                              .cancel(id: CancelID.pacing),
                              .cancel(id: CancelID.bindReply),
                              .run { [driver] send in
                                  await driver.stop()
                                  await send(.driverStopped)
                              })

            case .driverStopped:
                state.stopping = false
                // Contract 3: the stop-initiated offline, now that `driver.stop()` has returned.
                // Also when a deferred `.start` runs next, and BEFORE it, so the host deregisters
                // the radio's interface before the restarted driver re-registers it. The deferred
                // start hops through a task: TCA delivers `.send` synchronously into the action
                // buffer and a `.run` registers its cancel id only when its task starts, so a
                // `.stop` the host sends in answer to this offline (reduced in the same burst)
                // could neither precede a direct `.send(.restartDeferred)` nor cancel a direct
                // `startDriver`. After the hop, that stop has cleared `restartQueued` and the
                // start does nothing.
                guard state.restartPending else { return .send(.delegate(.offline(reason: nil))) }
                state.restartPending = false
                state.restartQueued = true
                return .concatenate(.send(.delegate(.offline(reason: nil))),
                                    .run { send in await send(.restartDeferred) })

            case .restartDeferred:
                // Load-bearing even with the epoch: this start effect is built only now, after any
                // `.stop` that answered the offline, so the epoch it captures is already bumped.
                guard state.restartQueued else { return .none }
                state.restartQueued = false
                return startDriver(state)

            case .removeChannel:
                // A removal in flight answers for this request too.
                guard !state.removingChannel else { return .none }
                // Not connected: there is no way to reach the radio, so the slot stays.
                guard state.isOnline else { return .send(.delegate(.channelRemoved(false))) }
                state.removingChannel = true
                // Not cancellable: a `.stop` waits for it instead (Review Focus 5).
                return .run { [driver] send in
                    let ok = await driver.removeChannel()
                    await send(.channelRemovalFinished(ok))
                }

            case let .channelRemovalFinished(ok):
                state.removingChannel = false
                guard state.stopHeld else { return .send(.delegate(.channelRemoved(ok))) }
                state.stopHeld = false
                let restart = state.startHeld
                state.startHeld = false
                // The held start goes after the stop, so the stop's `restartPending` path defers
                // it until `driver.stop()` returns and offline has been reported.
                return .concatenate(.send(.delegate(.channelRemoved(ok))), .send(.stop),
                                    restart ? .send(.start) : .none)

            case let .driverEvent(.connected(selfPrefix, publicKey, params)):
                guard state.status != .stopped else { return .none }
                if state.nextPacketID == nil { state.nextPacketID = random.packetID() }
                state.status = .online(selfPrefix: selfPrefix, publicKey: publicKey, params: params)
                return .send(.delegate(.online(selfPrefix: selfPrefix, publicKey: publicKey, params: params)))

            case let .driverEvent(.disconnected(reason)):
                guard state.status != .stopped else { return .none }
                let wasOnline = state.isOnline
                state.status = .connecting
                clearTraffic(&state)
                var effects: [Effect<Action>] = [.cancel(id: CancelID.pacing), .cancel(id: CancelID.bindReply)]
                if wasOnline { effects.append(.send(.delegate(.offline(reason: reason)))) }
                return .merge(effects)

            case let .driverEvent(.unavailable(cause)):
                guard state.status != .stopped else { return .none }
                let wasOnline = state.isOnline
                state.status = .unavailable(cause)
                clearTraffic(&state)
                var effects: [Effect<Action>] = [.cancel(id: CancelID.pacing), .cancel(id: CancelID.bindReply)]
                if wasOnline { effects.append(.send(.delegate(.offline(reason: nil)))) }
                effects.append(.send(.delegate(.adapterUnavailable(cause))))
                return .merge(effects)

            case .driverEvent(.retiredChannelsCleared):
                // Any status but `.stopped`: the slot policy runs before `.connected`.
                guard state.status != .stopped else { return .none }
                return .send(.delegate(.retiredChannelsCleared))

            case let .driverEvent(.datagram(bytes)):
                return receive(&state, bytes)

            case let .send(packet):
                guard enqueue(&state, packet, type: .rnsFragment) else { return .none }
                return pump(&state)

            case let .setCanRoute(canRoute):
                // Review Focus 4: only packets framed from now on change.
                state.config.canRoute = canRoute
                return .none

            case let .datagramSent(ok):
                if !ok { state.counters.sendFailed += 1 }
                return .none

            case .pacingElapsed:
                state.pacing = false
                return pump(&state)

            case .bindDelayElapsed:
                // `.disconnected` and `.stop` cancel this timer, but `.cancellable` registers its
                // id only when the task starts, so a drop or stop in the request's burst misses
                // it. The guard makes such an escaped timer harmless: if a fresh request re-armed
                // `bindReplyPending`, the first timer to fire answers it and the other finds the
                // flag clear. At most one `BIND` per pending reply.
                guard state.bindReplyPending else { return .none }
                state.bindReplyPending = false
                // Rechecked here as well as at the request: the wall clock may have moved since.
                guard !isInsideBindWindow(state),
                      case let .online(_, publicKey, _) = state.status,
                      enqueue(&state, publicKey, type: .bind)
                else { return .none }
                state.lastBindSent = date()
                return pump(&state)

            case .delegate:
                return .none
            }
        }
    }

    private func startDriver(_ state: State) -> Effect<Action> {
        let config = state.config
        let epoch = state.epoch
        let generation = epoch.current
        return .run { [driver] send in
            // A `.stop` reduced since this effect was built (possibly in the same burst, before
            // this task registered its cancel id) wins: never reach the driver after it.
            guard let events = epoch.start(ifCurrent: generation, { driver.start(config) }) else { return }
            for await event in events {
                await send(.driverEvent(event))
            }
        }
        .cancellable(id: CancelID.driver, cancelInFlight: true)
    }

    /// The §5.2 receive rules, in order: parse, self-source drop, address check, type dispatch,
    /// reassembly.
    private func receive(_ state: inout State, _ bytes: Data) -> Effect<Action> {
        guard case let .online(selfPrefix, _, _) = state.status else { return .none }
        guard let datagram = state.framing.codec.parse(bytes) else {
            state.reassembler.recordMalformed()
            return .none
        }
        guard datagram.src != selfPrefix else { return .none }
        guard datagram.dst == ScotMeshRawCodec.broadcast || datagram.dst == selfPrefix else {
            state.counters.notAddressed += 1
            return .none
        }
        switch datagram.type {
        case .rnsFragment:
            guard let packet = state.reassembler.receive(
                src: datagram.src, packetID: datagram.packetID, index: datagram.fragmentIndex,
                total: datagram.fragmentTotal, body: datagram.body, now: date())
            else { return .none }
            return .send(.delegate(.packetReceived(packet)))
        case .bindRequest:
            return scheduleBind(&state)
        case .bind, .other:
            // We keep no peer table, so `BIND` is ignored; so are unknown types.
            return .none
        }
    }

    /// §5.3: answer a `BIND_REQ` after a random delay, coalesced, at most one `BIND` per 60 s
    /// counted from the last enqueue. A request inside the 60 s schedules nothing at all. The
    /// request body isn't validated: the 60 s limit bounds the reply whatever it says.
    private func scheduleBind(_ state: inout State) -> Effect<Action> {
        guard !state.bindReplyPending, !isInsideBindWindow(state) else { return .none }
        state.bindReplyPending = true
        let delay = random.bindDelay()
        return .run { [clock] send in
            try await clock.sleep(for: delay)
            await send(.bindDelayElapsed)
        }
        .cancellable(id: CancelID.bindReply)
    }

    /// Less than 60 s since the last `BIND` was enqueued. A negative elapsed time (the wall clock
    /// moved back) counts as expired, or replies would stay silenced until the clock caught up
    /// (Review Focus 1).
    private func isInsideBindWindow(_ state: State) -> Bool {
        guard let last = state.lastBindSent else { return false }
        let elapsed = date().timeIntervalSince(last)
        return elapsed >= 0 && elapsed < Self.bindInterval
    }

    /// Frames `body` from our prefix to broadcast with the next packet ID and the current
    /// can-route bit, and queues it whole. A packet that doesn't fit is dropped whole and counts
    /// `queueFull`. The ID advances only when the packet is queued. True if queued.
    private func enqueue(_ state: inout State, _ body: Data, type: MeshCoreFrameType) -> Bool {
        guard case let .online(selfPrefix, _, _) = state.status, let packetID = state.nextPacketID
        else { return false }
        let datagrams = state.framing.codec.split(body, type: type, src: selfPrefix,
                                                  dst: ScotMeshRawCodec.broadcast,
                                                  packetID: packetID, canRoute: state.config.canRoute)
        guard !datagrams.isEmpty else { return false }
        guard state.queue.count + datagrams.count <= Self.queueCapacity else {
            state.counters.queueFull += 1
            return false
        }
        state.queue.append(contentsOf: datagrams)
        state.nextPacketID = packetID &+ 1
        return true
    }

    /// Stop-and-wait (§5.4): send the queue head now if online and no pacing window is open, wait
    /// for the driver to return, then one fragment delay (two after a failure). The first datagram
    /// never waits. A failed datagram is dropped, not retried.
    private func pump(_ state: inout State) -> Effect<Action> {
        guard state.isOnline, !state.pacing, !state.queue.isEmpty else { return .none }
        let datagram = state.queue.removeFirst()
        state.pacing = true
        let delay = MeshCoreLinkPacing.fragmentDelay(state.params)
        return .run { [driver, clock] send in
            let ok = await driver.send(datagram)
            await send(.datagramSent(ok: ok))
            try await clock.sleep(for: ok ? delay : delay * 2)
            await send(.pacingElapsed)
        }
        .cancellable(id: CancelID.pacing, cancelInFlight: true)
    }

    /// A drop or stop: forget queued datagrams, the pacing window, a pending `BIND` reply and
    /// partial packets. The caller cancels the pacing and `BIND` timers. The limiter survives (see
    /// `State.limiter`), and so do the packet ID, `lastBindSent`, and the reassembler's counters
    /// and dedupe keys.
    private func clearTraffic(_ state: inout State) {
        state.queue = []
        state.pacing = false
        state.bindReplyPending = false
        state.reassembler.reset()
    }
}
