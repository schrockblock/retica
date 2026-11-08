import Foundation
import ComposableArchitecture

/// Where an `RNodeInterface` is in its radio lifecycle.
public enum RNodeInterfaceStatus: Equatable, Sendable {
    /// Not started, or stopped by `.stop`.
    case stopped
    /// Started, waiting for the driver's `.connected` (first connect, or after a drop —
    /// reconnecting is the live adapter's job; the interface only waits).
    case connecting
    /// The radio finished its handshake and reported itself and the params it echoed.
    case online(RNodeRadioReport)
    /// The driver reported the adapter unavailable. A fresh `.start` leaves this state.
    case unavailable(BLEAdapterUnavailable)
}

/// The radio's diagnostics, publicly readable for the app (spec Contract 3).
public struct RNodeCounters: Equatable, Sendable {
    /// Packets delivered to the host.
    public var received: Int
    /// Packets the driver accepted.
    public var sent: Int
    /// Outbound packets over `RNodeInterface.maxPacketSize`, dropped.
    public var oversize: Int
    /// Outbound packets dropped because the FIFO was full.
    public var queueFull: Int
    /// Packets the driver reported as not sent.
    public var sendFailed: Int
    /// `.hardwareError` events the radio reported.
    public var hardwareErrors: Int

    public init(received: Int = 0, sent: Int = 0, oversize: Int = 0, queueFull: Int = 0,
                sendFailed: Int = 0, hardwareErrors: Int = 0) {
        self.received = received
        self.sent = sent
        self.oversize = oversize
        self.queueFull = queueFull
        self.sendFailed = sendFailed
        self.hardwareErrors = hardwareErrors
    }
}

/// The radio's last reported signal and channel state, for Diagnostics (spec Contract 3).
/// Nothing in it reaches Transport.
public struct RNodeTelemetry: Equatable, Sendable {
    public var lastRSSI: Int?
    public var lastSNR: Double?
    public var channelLoad: RNodeChannelLoad?
    public var lastHardwareError: UInt8?

    public init(lastRSSI: Int? = nil, lastSNR: Double? = nil, channelLoad: RNodeChannelLoad? = nil,
                lastHardwareError: UInt8? = nil) {
        self.lastRSSI = lastRSSI
        self.lastSNR = lastSNR
        self.channelLoad = channelLoad
        self.lastHardwareError = lastHardwareError
    }
}

/// Reticulum over ONE RNode (spec 2026-11-08 §5.6–§5.8). Owns the driver lifecycle, the
/// whole-packet FIFO and stop-and-wait sender (§5.6), the radio's telemetry and the counters.
/// No codec: RNodeKit owns KISS, so the driver carries whole packets.
///
/// The stop semantics (`stopping`, `restartPending`, `restartQueued`, `epoch`, `.driverStopped`,
/// `.restartDeferred`, the idle-stop answer, `isIdle`) are a deliberate copy of
/// `MeshCoreInterface`'s, itself a copy of Meshtastic's, minus channel removal. Spec §3 forbids
/// refactoring shared code out of those interfaces in v1, so the three stay separate.
@Reducer
public struct RNodeInterface {
    /// The sender's FIFO cap, in whole packets (spec §5.6).
    public static let queueCapacity = 64
    /// The largest packet the radio carries, IFAC included (spec §5.6).
    public static let maxPacketSize = 508

    @ObservableState
    public struct State: Equatable {
        public let config: RNodeDriverConfig
        public internal(set) var status: RNodeInterfaceStatus = .stopped
        /// Survives `.disconnected` and `.stop`; a replaced slot starts empty.
        public internal(set) var telemetry = RNodeTelemetry()
        var counters = RNodeCounters()
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
        /// Whole packets waiting for the radio, oldest first. Excludes the one in flight.
        var queue: [Data] = []
        /// A driver `send` is out and its current-generation `.packetSent` hasn't arrived yet
        /// (stop-and-wait, §5.6). Cleared by `clearTraffic`.
        var sendInFlight = false
        /// The traffic generation a send result must match: the `epoch` value of
        /// `.packetSent(ok:epoch:)`. Bumped at reduce time by every `.stop` that reaches the
        /// driver, every `.driverEvent(.disconnected)` and every `.driverEvent(.unavailable)`
        /// (`clearTraffic`).
        ///
        /// Why not `epoch`: the sender's effect is cancelled by a drop or stop (the
        /// `.cancel(id: .sending)` inside each of those arms' `return`), but `.cancellable`
        /// registers its id only when the task starts (see `DriverEpoch`), so a send launched in
        /// the same burst escapes. After a stop, the send effect's own `DriverEpoch` check (taken
        /// before `driver.send`) ends it before it reaches the driver. A drop doesn't bump the
        /// epoch, so a send escaping one still reaches the driver and its `.packetSent` arrives
        /// after the reconnect. Read against `epoch`, it would look current: it would clear the
        /// in-flight flag while a new packet is in flight, launch a second concurrent
        /// `driver.send` (breaking §5.6's stop-and-wait), and count `sent` or `sendFailed` for a
        /// packet the drop already discarded. This generation moves on every drop and stop, so
        /// `.packetSent` is ignored unless its value equals it. (MeshCore's `TrafficToken` also
        /// carries the slot's identity; a replaced RNode slot is nil'd only once `isIdle`, after
        /// the stop cancelled its sender and bumped its epoch, so no result of the old slot can
        /// reach the new one.)
        var trafficGeneration = 0

        public init(config: RNodeDriverConfig) {
            self.config = config
        }

        public var isOnline: Bool {
            if case .online = status { return true }
            return false
        }

        /// What the radio reported at its last `.connected`, while online.
        public var report: RNodeRadioReport? {
            if case let .online(report) = status { return report }
            return nil
        }

        /// Stopped with no `driver.stop()` still in flight: nothing of this interface runs, so a
        /// host may drop its state now (spec Contract 3). `.stopped` alone is not enough: a
        /// `driver.stop()` is still in flight, and what dropping the state does to it depends on
        /// WHO drops it. An `ifLet` cancels the child's effects only when its own parent reducer
        /// nils the state; a host outside that reducer leaves the stop running, and its
        /// `.driverStopped` then reaches an `ifLet` with no state (TCA's runtime warning). Either
        /// way the next slot's start could race the old stop.
        public var isIdle: Bool { status == .stopped && !stopping }

        /// Every counter in one public value (read by `RNodeEndpoint`).
        public var diagnostics: RNodeCounters { counters }

        /// Packets waiting to be sent, not counting the one in flight.
        public var queuedPacketCount: Int { queue.count }
    }

    public enum Action: Equatable {
        case start
        case stop
        /// An outbound Reticulum packet, already IFAC-masked. Dropped unless online (uncounted),
        /// over `maxPacketSize` (`oversize`) or with the FIFO full (`queueFull`).
        case send(Data)
        case driverEvent(RNodeDriverEvent)
        /// `driver.send` returned. `epoch` is the `State.trafficGeneration` the send was launched
        /// in; the result is ignored unless it is still current (see `trafficGeneration`).
        case packetSent(ok: Bool, epoch: Int)
        /// `driver.stop()` returned: a deferred `.start` may now run.
        case driverStopped
        /// The deferred start, sent from a task after the stop-initiated offline so a `.stop` the
        /// host reduces in that offline's burst wins (it clears `restartQueued`). Ignored unless
        /// `restartQueued`, so a copy routed to a replacement slot's state does nothing.
        case restartDeferred
        case delegate(Delegate)

        public enum Delegate: Equatable, Sendable {
            /// The radio finished its handshake. Reported again on every `.connected`, so a
            /// reconnect with different reported params re-registers with them.
            case online(RNodeRadioReport)
            /// The radio is no longer usable. Reported on a drop or unavailability of an ONLINE
            /// radio, and for every `.stop` — only once `driver.stop()` has returned, so "offline"
            /// means the stop finished (spec Contract 3). A `.stop` to an interface that is
            /// already idle reports it at once. On the deferred-restart arm a fresh start follows
            /// unless the host answers this offline with `.stop`, which wins; a consumer that
            /// needs "fully down, the slot may be dropped" checks `state.isIdle`.
            case offline(reason: String?)
            case packetReceived(Data)
            case adapterUnavailable(BLEAdapterUnavailable)
        }
    }

    @Dependency(\.rnodeDriver) var driver

    private enum CancelID: Hashable { case driver, sending }

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
                              .cancel(id: CancelID.sending),
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

            case let .driverEvent(.connected(report)):
                guard state.status != .stopped else { return .none }
                // Every `.connected` reports online, even while already online: a radio that
                // reconnects with different echoed params must re-register with them.
                state.status = .online(report)
                return .send(.delegate(.online(report)))

            case let .driverEvent(.disconnected(reason)):
                guard state.status != .stopped else { return .none }
                let wasOnline = state.isOnline
                state.status = .connecting
                clearTraffic(&state)
                var effects: [Effect<Action>] = [.cancel(id: CancelID.sending)]
                if wasOnline { effects.append(.send(.delegate(.offline(reason: reason)))) }
                return .merge(effects)

            case let .driverEvent(.unavailable(cause)):
                guard state.status != .stopped else { return .none }
                let wasOnline = state.isOnline
                state.status = .unavailable(cause)
                // A drop like `.disconnected`: a restarted session must not send this one's queue,
                // nor wait behind its in-flight flag.
                clearTraffic(&state)
                var effects: [Effect<Action>] = [.cancel(id: CancelID.sending)]
                if wasOnline { effects.append(.send(.delegate(.offline(reason: nil)))) }
                effects.append(.send(.delegate(.adapterUnavailable(cause))))
                return .merge(effects)

            case let .driverEvent(.packet(packet, rssi, snr)):
                // §5.6: only an online radio delivers, and only a delivered packet's signal is
                // recorded. A packet without signal keeps the last values.
                guard state.isOnline else { return .none }
                state.counters.received += 1
                if let rssi { state.telemetry.lastRSSI = rssi }
                if let snr { state.telemetry.lastSNR = snr }
                return .send(.delegate(.packetReceived(packet)))

            case let .driverEvent(.channelLoad(load)):
                // Any status but `.stopped`: stats arrive mid-handshake too, and are real data.
                guard state.status != .stopped else { return .none }
                state.telemetry.channelLoad = load
                return .none

            case let .driverEvent(.hardwareError(code)):
                // Counted only. The status follows the driver's `.disconnected`, not the error
                // (Review Focus 4).
                guard state.status != .stopped else { return .none }
                state.counters.hardwareErrors += 1
                state.telemetry.lastHardwareError = code
                return .none

            case let .send(packet):
                guard state.isOnline else { return .none }
                guard packet.count <= Self.maxPacketSize else {
                    state.counters.oversize += 1
                    return .none
                }
                guard !state.sendInFlight else {
                    guard state.queue.count < Self.queueCapacity else {
                        state.counters.queueFull += 1
                        return .none
                    }
                    state.queue.append(packet)
                    return .none
                }
                return transmit(&state, packet)

            case let .packetSent(ok, epoch):
                // A result from before a drop or stop: its packet was already forgotten, and
                // another may be in flight now (see `State.trafficGeneration`).
                guard epoch == state.trafficGeneration else { return .none }
                state.sendInFlight = false
                if ok {
                    state.counters.sent += 1
                } else {
                    // Dropped, not retried.
                    state.counters.sendFailed += 1
                }
                guard state.isOnline, !state.queue.isEmpty else { return .none }
                return transmit(&state, state.queue.removeFirst())

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

    /// Stop-and-wait (§5.6): hand `packet` to the driver now and mark it in flight. The next
    /// packet goes out when this one's `.packetSent` arrives. No pacing: the radio's own airtime
    /// and the driver's return are the only wait.
    private func transmit(_ state: inout State, _ packet: Data) -> Effect<Action> {
        state.sendInFlight = true
        let traffic = state.trafficGeneration
        let epoch = state.epoch
        let generation = epoch.current
        return .run { [driver] send in
            // As in `startDriver`: a `.stop` reduced since this effect was built (in the same
            // burst, before this task registered its cancel id) wins. The send never reaches the
            // driver after it and reports nothing, so it can't outlive `isIdle`.
            guard epoch.current == generation else { return }
            let ok = await driver.send(packet)
            await send(.packetSent(ok: ok, epoch: traffic))
        }
        // No `cancelInFlight`: stop-and-wait launches one current send at a time, and a send that
        // escaped a drop is neutralised by the traffic generation, not by being cancelled here.
        .cancellable(id: CancelID.sending)
    }

    /// A drop or stop: forget queued packets and the in-flight send, and move the traffic
    /// generation, so a send result from before it is ignored (see `State.trafficGeneration`).
    /// The caller cancels the sender inside its `return`. Telemetry and counters survive.
    private func clearTraffic(_ state: inout State) {
        state.queue = []
        state.sendInFlight = false
        state.trafficGeneration += 1
    }
}
