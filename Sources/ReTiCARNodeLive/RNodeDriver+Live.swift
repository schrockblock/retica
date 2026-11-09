import Foundation
import ComposableArchitecture
import RNodeKit
import ReTiCAInterfaces

extension RNodeDriver {
    /// Contract 2's live value over ONE `RNodeSession`. `start` subscribes to the session's events,
    /// then connects to `config.radio` with `config.params` (retrieve-only: the session never
    /// scans), and the session writes those params at every handshake. A terminal end yields
    /// `.unavailable` and finishes the stream. `send` writes one whole packet on the link that is up
    /// when it is called, and answers false at once if none is, or as soon as that link ends.
    /// `stop` disconnects and always returns. Reconnecting is RNodeKit's. The session outlives
    /// every start/stop; its owner must `disconnect()` it before dropping it.
    public static func live(session: RNodeSession) -> RNodeDriver {
        let adapter = RNodeLiveAdapter(session: session)
        return RNodeDriver(start: { adapter.start($0) },
                           send: { await adapter.send($0) },
                           stop: { await adapter.stop() })
    }
}

/// The state behind `RNodeDriver.live(session:)`, shaped like `MeshtasticLiveAdapter`.
/// `RNodeInterface` may `start` again from `.unavailable` without a `stop()` in between, so
/// `pendingConnects` is a counter and `stop()` drains them all.
///
/// Sends bind to the link that is up when they are called (ledger carry 1). `send` also races the
/// kit's write against that link ending and answers false as soon as the adapter sees it end.
/// Today's FCB already fails a pending write on a power-off or a disconnect, so the race is
/// defence-in-depth against a future FCB that doesn't; no test can make it decisive, and the
/// in-flight power-off test pins only the outcome.
final class RNodeLiveAdapter: Sendable {
    let session: RNodeSession
    private let link = LockIsolated(Link())
    /// `connect(radio:config:)` calls launched by `start` that have not returned yet.
    private let pendingConnects = LockIsolated(0)

    /// The ledger's link generation is `owner` plus `waiters`: `endLink` fails and clears every
    /// waiter of the current link, so a send only ever waits on the link it started on.
    private struct Link {
        /// Bumped by every `start` and `stop`: a superseded pump never touches the link.
        var owner: UInt64 = 0
        /// `.connected` was reported for `owner` and nothing has ended that link since.
        var up = false
        var nextWaiter: UInt64 = 0
        /// Sends in flight on the current link, each failed when it ends.
        var waiters: [UInt64: @Sendable () -> Void] = [:]
    }

    init(session: RNodeSession) {
        self.session = session
    }

    func start(_ config: RNodeDriverConfig) -> AsyncStream<RNodeDriverEvent> {
        let owner = link.withValue { link -> UInt64 in
            link.owner &+= 1
            return link.owner
        }
        endLink(owner)
        // Subscribe BEFORE connecting: the hub registers a subscriber synchronously, so this
        // stream sees every event of the connect below (the current state is replayed first,
        // and the mapper drops it).
        let events = session.events()
        let session = self.session
        let pendingConnects = self.pendingConnects
        let radioConfig = RNodeRadioConfig(config.params)
        pendingConnects.withValue { $0 += 1 }
        // CoreBluetooth connects never time out: connect from a task (Contract 1).
        Task {
            await session.connect(radio: config.radio, config: radioConfig)
            pendingConnects.withValue { $0 -= 1 }
        }
        return AsyncStream { continuation in
            let pump = Task { await self.pump(events, owner: owner, continuation) }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    private func pump(_ events: AsyncStream<RNodeEvent>, owner: UInt64,
                      _ continuation: AsyncStream<RNodeDriverEvent>.Continuation) async {
        var mapper = RNodeEventMapper()
        for await event in events {
            switch mapper.map(event) {
            case .ignore:
                continue
            case let .emit(mapped):
                switch mapped {
                case .connected: linkUp(owner)
                case .disconnected, .unavailable: endLink(owner)
                case .packet, .channelLoad, .hardwareError: break
                }
                continuation.yield(mapped)
            case let .finish(mapped):
                endLink(owner)
                continuation.yield(mapped)
                continuation.finish()
                return
            }
        }
        endLink(owner)
        continuation.finish()
    }

    func send(_ packet: Data) async -> Bool {
        let outcome = SendOutcome()
        let token = link.withValue { link -> UInt64? in
            guard link.up else { return nil }
            link.nextWaiter &+= 1
            link.waiters[link.nextWaiter] = { outcome.resolve(false) }
            return link.nextWaiter
        }
        guard let token else { return false }
        let session = self.session
        // If the race answers first, this task runs on; FCB resolves every pending write when the
        // link ends, so it always finishes.
        Task {
            do {
                try await session.send(packet)
                outcome.resolve(true)
            } catch {
                outcome.resolve(false)
            }
        }
        let sent = await outcome.value()
        link.withValue { _ = $0.waiters.removeValue(forKey: token) }
        return sent
    }

    /// Always returns (Contract 3). A connect launched by `start` is an unstructured hop onto the
    /// session actor and may reach it AFTER this disconnect; it returns promptly once a later
    /// disconnect supersedes it, so disconnect again until none is outstanding.
    func stop() async {
        let owner = link.withValue { link -> UInt64 in
            link.owner &+= 1
            return link.owner
        }
        endLink(owner)
        await session.disconnect()
        while pendingConnects.value > 0 {
            try? await Task.sleep(for: .milliseconds(10))
            await session.disconnect()
        }
    }

    private func linkUp(_ owner: UInt64) {
        link.withValue { if $0.owner == owner { $0.up = true } }
    }

    /// Ends the current link for `owner` (unless superseded) and fails every send in flight on it.
    private func endLink(_ owner: UInt64) {
        let waiters = link.withValue { link -> [@Sendable () -> Void] in
            guard link.owner == owner else { return [] }
            link.up = false
            defer { link.waiters = [:] }
            return Array(link.waiters.values)
        }
        for fail in waiters { fail() }
    }
}

/// A one-shot answer for one send: the first `resolve` wins, whichever side calls it.
private final class SendOutcome: Sendable {
    private struct State {
        var value: Bool?
        var continuation: CheckedContinuation<Bool, Never>?
    }

    private let state = LockIsolated(State())

    func value() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let ready = state.withValue { s -> Bool? in
                if let value = s.value { return value }
                s.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func resolve(_ value: Bool) {
        let continuation = state.withValue { s -> CheckedContinuation<Bool, Never>? in
            guard s.value == nil else { return nil }
            s.value = value
            defer { s.continuation = nil }
            return s.continuation
        }
        continuation?.resume(returning: value)
    }
}

/// What the adapter should do with one kit event.
enum RNodeLiveStep: Equatable {
    case ignore
    case emit(RNodeDriverEvent)
    /// Yield the event, then finish the stream: the session has given up on this radio, and a
    /// following `.disconnected` must not flip the interface back to `.connecting`.
    case finish(RNodeDriverEvent)
}

/// Folds ONE subscription's events into driver events. The kit replays the session's current
/// connection state to every new subscriber, so after a terminal end the replay is a stale
/// `.disconnected("radio not found")`. `start`'s connect always emits `.connection(.connecting)`
/// first, so everything before this subscription's first `.connecting` is replay and is dropped.
///
/// The session reports `.configurationRejected` just before its terminal
/// `.disconnected(configurationRejectedReason)`; the mapper remembers the list and formats it
/// into the message when that end arrives.
struct RNodeEventMapper: Equatable {
    private var sawConnecting = false
    private var rejected: [RNodeParameterMismatch] = []

    init() {}

    /// Adapter ends that follow an `.adapterUnavailable` event, so they stay plain drops.
    private static let adapterEndReasons: Set<String> = ["unauthorized", "unsupported"]

    mutating func map(_ event: RNodeEvent) -> RNodeLiveStep {
        if !sawConnecting {
            if case .connection(.connecting) = event { sawConnecting = true }
            return .ignore
        }
        switch event {
        case let .configured(info):
            return .emit(.connected(Self.report(info)))
        case let .packet(packet, rssi, snr):
            return .emit(.packet(packet, rssi: rssi, snr: snr))
        case let .channelStats(stats):
            return .emit(.channelLoad(Self.load(stats)))
        case let .radioError(code):
            return .emit(.hardwareError(code))
        case let .configurationRejected(mismatches):
            rejected = mismatches
            return .ignore
        case .connection(.reconnecting), .connection(.disconnected(reason: nil)):
            return .emit(.disconnected(reason: nil))
        case let .connection(.disconnected(reason?)):
            if Self.adapterEndReasons.contains(reason) { return .ignore }
            return .finish(.unavailable(.other(message(forTerminalReason: reason))))
        case let .adapterUnavailable(cause):
            return .emit(.unavailable(Self.bleCause(cause)))
        case .connection(.connecting), .connection(.configuring), .connection(.connected):
            return .ignore
        }
    }

    /// nil for an empty reason, so the app shows its generic adapter message rather than a blank one.
    private func message(forTerminalReason reason: String) -> String? {
        switch reason {
        case RNodeSession.firmwareTooOldReason:        return RNodeLiveMessage.firmwareTooOld
        case RNodeSession.pairingRequiredReason:       return RNodeLiveMessage.pairingRequired
        case RNodeSession.pairingRemovedReason:        return RNodeLiveMessage.pairingRemoved
        case RNodeSession.configurationRejectedReason: return RNodeLiveMessage.configurationRejected(rejected)
        case "":                                       return nil
        default:                                       return reason
        }
    }

    static func report(_ info: RNodeRadioInfo) -> RNodeRadioReport {
        RNodeRadioReport(name: info.name, firmwareMajor: info.firmwareMajor, firmwareMinor: info.firmwareMinor,
                         platform: info.platform, mcu: info.mcu, params: RNodeLoRaParams(info.reported))
    }

    /// Every field but `currentRSSI`, which the interface doesn't show.
    static func load(_ stats: RNodeChannelStats) -> RNodeChannelLoad {
        RNodeChannelLoad(airtimeShort: stats.airtimeShort, airtimeLong: stats.airtimeLong,
                         channelLoadShort: stats.channelLoadShort, channelLoadLong: stats.channelLoadLong,
                         noiseFloor: stats.noiseFloor, interferenceRSSI: stats.interferenceRSSI)
    }

    static func bleCause(_ cause: RNodeAdapterUnavailable) -> BLEAdapterUnavailable {
        switch cause {
        case .poweredOff:        return .poweredOff
        case .unauthorized:      return .unauthorized
        case .unsupported:       return .unsupported
        case let .other(detail): return .other(detail)
        }
    }
}

extension RNodeRadioConfig {
    /// The kit's config for ReTiCA's parameters, field for field.
    init(_ params: RNodeLoRaParams) {
        self.init(frequencyHz: params.frequencyHz, bandwidthHz: params.bandwidthHz,
                  txPowerDBm: params.txPowerDBm, spreadingFactor: params.spreadingFactor,
                  codingRate: params.codingRate)
    }
}

extension RNodeLoRaParams {
    /// ReTiCA's parameters for the kit's echoes, field for field.
    init(_ config: RNodeRadioConfig) {
        self.init(frequencyHz: config.frequencyHz, bandwidthHz: config.bandwidthHz,
                  txPowerDBm: config.txPowerDBm, spreadingFactor: config.spreadingFactor,
                  codingRate: config.codingRate)
    }
}
