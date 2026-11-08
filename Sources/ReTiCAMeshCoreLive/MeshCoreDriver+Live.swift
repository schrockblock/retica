import Foundation
import ComposableArchitecture
import MeshCoreKit
import ReTiCAInterfaces

/// What `.connected` doesn't carry but Diagnostics shows (plan Contract issue 3). The live
/// driver hands it to its `details` sink just before yielding `.connected`, and nil once the
/// radio is released or stopped.
public struct MeshCoreRadioDetails: Equatable, Sendable {
    public var name: String
    public var firmwareCode: UInt8
    public var channelSlot: UInt8

    public init(name: String, firmwareCode: UInt8, channelSlot: UInt8) {
        self.name = name
        self.firmwareCode = firmwareCode
        self.channelSlot = channelSlot
    }
}

extension MeshCoreDriver {
    /// Contract 2's live value over ONE `MeshCoreSession`. `start` subscribes, then connects to
    /// `config.radio` (retrieve-only: the session never scans). After every completed handshake
    /// it runs the channel slot policy and only then reports `.connected`. `send` writes one
    /// `CMD_SEND_CHANNEL_DATA` on our slot. `removeChannel` re-reads the radio and clears every
    /// slot holding our key. `stop` disconnects and always returns. The session outlives every
    /// start/stop; its owner must `disconnect()` it before dropping it.
    ///
    /// `details` receives the radio's name, firmware code and our slot before each `.connected`,
    /// and nil when the radio is released or stopped. `config.canRoute` is ignored here:
    /// `MeshCoreInterface` builds the header.
    public static func live(session: MeshCoreSession,
                            details: @escaping @Sendable (MeshCoreRadioDetails?) -> Void = { _ in }) -> MeshCoreDriver {
        let adapter = MeshCoreLiveAdapter(session: session, details: details)
        return MeshCoreDriver(start: { adapter.start($0) },
                              send: { await adapter.send($0) },
                              removeChannel: { await adapter.removeChannel() },
                              stop: { await adapter.stop() })
    }
}

/// The three slot policy failures (spec Contract 2). Each one disconnects the radio and stops
/// automatic restarts, so the app needs to recognise them by text.
public enum MeshCoreLiveMessage {
    public static let noFreeSlot = "No free channel slot on this radio"
    public static let firmwareTooOld = "This radio's firmware is too old; update to v1.15 or later"
    public static let channelSetupFailed = "Couldn't set up the channel on this radio"

    /// True for exactly the three policy messages.
    public static func isPolicyFailure(_ text: String) -> Bool {
        text == noFreeSlot || text == firmwareTooOld || text == channelSetupFailed
    }
}

/// What the adapter should do with one kit event.
enum MeshCoreLiveStep: Equatable {
    case ignore
    case emit(MeshCoreDriverEvent)
    /// A handshake completed: run the slot policy, then `slotReady` and emit `connected(_:)`.
    case configure(MeshCoreRadioInfo)
}

/// Folds ONE subscription's events into driver events. The kit replays the session's current
/// connection state to every new subscriber, so after a terminal end the replay is a stale
/// `.disconnected("radio not found")`. `start`'s connect always emits `.connection(.connecting)`
/// first, so everything before this subscription's first `.connecting` is replay and is dropped.
///
/// `.connected` is never taken from `.connection(.connected)`: it comes from the adapter after
/// `.configured` and the slot policy. Every `.frame` is ignored (Contract 1: map `.frame` OR the
/// typed cases, and this maps the typed ones).
struct MeshCoreEventMapper: Equatable {
    private let dataType: UInt16
    private var sawConnecting = false
    private var slot: UInt8?

    init(dataType: UInt16) {
        self.dataType = dataType
    }

    /// The adapter calls this once our channel slot is usable.
    mutating func slotReady(_ index: UInt8) {
        slot = index
    }

    /// Adapter ends that follow an `.adapterUnavailable` event, so they stay plain drops.
    private static let adapterEndReasons: Set<String> = ["unauthorized", "unsupported"]

    mutating func map(_ event: MeshCoreEvent) -> MeshCoreLiveStep {
        if !sawConnecting {
            if case .connection(.connecting) = event { sawConnecting = true }
            return .ignore
        }
        switch event {
        case let .configured(info):
            slot = nil
            return .configure(info)
        case let .channelData(index, type, payload):
            guard let slot, index == slot, type == dataType else { return .ignore }
            return .emit(.datagram(payload))
        case let .rawData(payload):
            guard slot != nil else { return .ignore }
            return .emit(.datagram(payload))
        case .connection(.reconnecting), .connection(.disconnected(reason: nil)):
            slot = nil
            return .emit(.disconnected(reason: nil))
        case let .connection(.disconnected(reason?)):
            slot = nil
            if Self.adapterEndReasons.contains(reason) { return .ignore }
            if reason == MeshCoreSession.firmwareTooOldReason {
                return .emit(.unavailable(.other(MeshCoreLiveMessage.firmwareTooOld)))
            }
            return .emit(.unavailable(.other(reason)))
        case let .adapterUnavailable(cause):
            slot = nil
            return .emit(.unavailable(Self.bleCause(cause)))
        case .connection(.connecting), .connection(.configuring), .connection(.connected), .frame:
            return .ignore
        }
    }

    static func connected(_ info: MeshCoreRadioInfo) -> MeshCoreDriverEvent {
        .connected(selfPrefix: info.publicKey.prefix(4), publicKey: info.publicKey,
                   params: MeshCoreLinkParams(spreadingFactor: info.spreadingFactor,
                                              bandwidthHz: info.bandwidthHz,
                                              codingRate: info.codingRate))
    }

    static func bleCause(_ cause: MeshCoreAdapterUnavailable) -> BLEAdapterUnavailable {
        switch cause {
        case .poweredOff:        return .poweredOff
        case .unauthorized:      return .unauthorized
        case .unsupported:       return .unsupported
        case let .other(detail): return .other(detail)
        }
    }
}

/// The state behind `MeshCoreDriver.live(session:details:)`, shaped like `MeshtasticLiveAdapter`.
/// `MeshCoreInterface` may `start` again from `.unavailable` without a `stop()` in between, so
/// `pendingConnects` is a counter and `stop()` drains them all.
///
/// The config holds the real 16-byte channel key (the app's wrapper fills it at `start`). It is
/// never logged, and never part of a reported reason.
final class MeshCoreLiveAdapter: Sendable {
    /// Reported (and the radio released) when the config's key isn't 16 bytes, or is all zero.
    static let channelKeyMissing = "The channel key is missing"

    let session: MeshCoreSession
    private let details: @Sendable (MeshCoreRadioDetails?) -> Void
    /// The current start's config, read by `send` and `removeChannel`.
    private let config = LockIsolated<MeshCoreDriverConfig?>(nil)
    /// The slot `send` uses, with the start it belongs to. Set only once the policy has
    /// finished on the current link; cleared by every drop, every handshake and `stop`, so a
    /// send left over from before a drop never goes out on an index the policy hasn't re-checked.
    private let link = LockIsolated(Link())
    /// `connect(radio:)` calls launched by `start` that have not returned yet.
    private let pendingConnects = LockIsolated(0)

    private struct Link {
        /// Bumped by every `start` and `stop`: a superseded pump never sets the slot.
        var generation: UInt64 = 0
        var slot: UInt8?
        /// `removeChannel` succeeded during this start: no later policy pass may write our
        /// channel back (a reconnect before the `stop` would otherwise rerun it).
        var channelRemoved = false
    }

    /// How one policy pass ended.
    private enum PassOutcome {
        case ready(UInt8)
        /// The link went away (or the stream ended) mid-pass: the session will reconnect and
        /// configure again, so report nothing.
        case abandoned
        /// Reported, finished and disconnected.
        case released
    }

    init(session: MeshCoreSession, details: @escaping @Sendable (MeshCoreRadioDetails?) -> Void) {
        self.session = session
        self.details = details
    }

    func start(_ newConfig: MeshCoreDriverConfig) -> AsyncStream<MeshCoreDriverEvent> {
        config.setValue(newConfig)
        let generation = link.withValue { link -> UInt64 in
            link.generation &+= 1
            link.slot = nil
            link.channelRemoved = false
            return link.generation
        }
        // Subscribe BEFORE connecting: the hub registers a subscriber synchronously, so this
        // stream sees every event of the connect below (the current state is replayed first,
        // and the mapper drops it).
        let events = session.events()
        let session = self.session
        let pendingConnects = self.pendingConnects
        pendingConnects.withValue { $0 += 1 }
        // CoreBluetooth connects never time out: connect from a task (Contract 1).
        Task {
            await session.connect(radio: newConfig.radio)
            pendingConnects.withValue { $0 -= 1 }
        }
        return AsyncStream { continuation in
            let pump = Task {
                await self.pump(events, config: newConfig, generation: generation, continuation)
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    private func pump(_ events: AsyncStream<MeshCoreEvent>, config: MeshCoreDriverConfig,
                      generation: UInt64,
                      _ continuation: AsyncStream<MeshCoreDriverEvent>.Continuation) async {
        var mapper = MeshCoreEventMapper(dataType: config.dataType)
        for await event in events {
            switch mapper.map(event) {
            case .ignore:
                continue
            case let .emit(mapped):
                switch mapped {
                case .disconnected, .unavailable: forgetSlot(generation)
                case .connected, .datagram, .retiredChannelsCleared: break
                }
                continuation.yield(mapped)
            case let .configure(info):
                forgetSlot(generation)
                // A superseded start's pump never touches the radio, and after a removal the
                // policy never runs again: it would write our channel back.
                guard isCurrent(generation), !link.value.channelRemoved else { continue }
                switch await runPolicy(info, config: config, generation: generation, continuation) {
                case let .ready(index):
                    guard !Task.isCancelled, setSlot(index, generation) else { continue }
                    mapper.slotReady(index)
                    details(MeshCoreRadioDetails(name: info.name, firmwareCode: info.firmwareCode,
                                                 channelSlot: index))
                    // A stop between `setSlot` and the sink has already sent its nil: don't
                    // leave our stale details after it.
                    guard isCurrent(generation) else {
                        details(nil)
                        continue
                    }
                    continuation.yield(MeshCoreEventMapper.connected(info))
                case .abandoned:
                    continue
                case .released:
                    return
                }
            }
        }
        continuation.finish()
    }

    /// Spec Contract 2's slot policy, on a radio that just completed a handshake.
    private func runPolicy(_ info: MeshCoreRadioInfo, config: MeshCoreDriverConfig, generation: UInt64,
                           _ continuation: AsyncStream<MeshCoreDriverEvent>.Continuation) async -> PassOutcome {
        guard info.firmwareCode >= 11 else {
            await release(MeshCoreLiveMessage.firmwareTooOld, generation, continuation)
            return .released
        }
        guard Self.isUsableKey(config.channelSecret) else {
            await release(Self.channelKeyMissing, generation, continuation)
            return .released
        }
        do {
            // A failed read (including a reply for the wrong index) throws: never guess a slot.
            let channels = try await session.channels()
            let plan = MeshCoreChannelPolicy.plan(channels: channels, secret: config.channelSecret,
                                                  retired: config.retiredChannelSecrets)
            for index in plan.clears {
                guard !Task.isCancelled else { return .abandoned }
                try await session.setChannel(index: index, name: "",
                                             secret: MeshCoreChannelPolicy.clearedSecret)
            }
            // Reaching here means no clear failed (including when none was needed).
            if !config.retiredChannelSecrets.isEmpty {
                continuation.yield(.retiredChannelsCleared)
            }
            switch plan.outcome {
            case let .use(index):
                return .ready(index)
            case let .write(index):
                guard !Task.isCancelled else { return .abandoned }
                try await session.setChannel(index: index, name: config.channelName,
                                             secret: config.channelSecret)
                return .ready(index)
            case .noFreeSlot:
                await release(MeshCoreLiveMessage.noFreeSlot, generation, continuation)
                return .released
            }
        } catch MeshCoreSessionError.notConnected {
            return .abandoned
        } catch {
            await release(MeshCoreLiveMessage.channelSetupFailed, generation, continuation)
            return .released
        }
    }

    /// A policy failure: report it, end the stream (so a following `.disconnected` can't flip
    /// the interface back to `.connecting`), and give up the radio's only BLE link, so the
    /// person can fix it in the MeshCore app and the radio's queue isn't drained meanwhile.
    private func release(_ text: String, _ generation: UInt64,
                         _ continuation: AsyncStream<MeshCoreDriverEvent>.Continuation) async {
        continuation.yield(.unavailable(.other(text)))
        continuation.finish()
        // A newer start owns the session now: leave its link alone.
        guard isCurrent(generation) else { return }
        await session.disconnect()
        // Re-checked after the hop: a stop has already sent its own nil, and a newer start's
        // details must not be wiped.
        if isCurrent(generation) { details(nil) }
    }

    func send(_ frame: Data) async -> Bool {
        guard let config = config.value, let slot = link.value.slot else { return false }
        do {
            try await session.sendChannelData(channelIndex: slot, dataType: config.dataType, payload: frame)
            return true
        } catch {
            return false
        }
    }

    /// Re-reads the radio rather than trusting the remembered index (the person may have moved
    /// the channel), then clears every slot holding our key. Bounded by the session's command
    /// timeouts. On success, sends stop (the slot is gone) and no later policy pass in this
    /// start writes the channel back.
    func removeChannel() async -> Bool {
        guard let config = config.value else { return false }
        do {
            let channels = try await session.channels()
            for channel in channels where channel.secret == config.channelSecret {
                try await session.setChannel(index: channel.index, name: "",
                                             secret: MeshCoreChannelPolicy.clearedSecret)
            }
            link.withValue {
                $0.slot = nil
                $0.channelRemoved = true
            }
            return true
        } catch {
            return false
        }
    }

    /// Always returns (Contract 3). A connect launched by `start` is an unstructured hop onto the
    /// session actor and may reach it AFTER this disconnect; it returns promptly once a later
    /// disconnect supersedes it, so disconnect again until none is outstanding.
    func stop() async {
        config.setValue(nil)
        link.withValue {
            $0.generation &+= 1
            $0.slot = nil
        }
        details(nil)
        await session.disconnect()
        while pendingConnects.value > 0 {
            try? await Task.sleep(for: .milliseconds(10))
            await session.disconnect()
        }
    }

    /// 16 bytes, not all zero (all zero is what an empty slot holds).
    static func isUsableKey(_ secret: Data) -> Bool {
        secret.count == 16 && secret.contains { $0 != 0 }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        link.value.generation == generation
    }

    private func forgetSlot(_ generation: UInt64) {
        link.withValue { if $0.generation == generation { $0.slot = nil } }
    }

    /// Sets the slot `send` uses, unless a newer start or a stop has superseded `generation`, or
    /// the channel was removed meanwhile.
    private func setSlot(_ index: UInt8, _ generation: UInt64) -> Bool {
        link.withValue { link -> Bool in
            guard link.generation == generation, !link.channelRemoved else { return false }
            link.slot = index
            return true
        }
    }
}
