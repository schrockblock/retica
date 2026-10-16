import Foundation
import ComposableArchitecture

/// What the live adapter needs to talk to ONE radio. Channel 0 and hop limit 1 are landandair's
/// defaults (Meshtastic_Interface.py:95, 302).
public struct MeshtasticDriverConfig: Equatable, Sendable {
    public var radio: UUID
    public var channel: UInt32 = 0
    public var hopLimit: UInt32 = 1

    public init(radio: UUID, channel: UInt32 = 0, hopLimit: UInt32 = 1) {
        self.radio = radio
        self.channel = channel
        self.hopLimit = hopLimit
    }
}

public enum MeshtasticDriverEvent: Equatable, Sendable {
    /// The radio finished its configuration handshake. Emitted again after every reconnect.
    /// `modemPreset` is the raw `Config.LoRaConfig.ModemPreset` value, nil when unknown.
    case connected(myNodeNum: UInt32, modemPreset: Int?)
    case disconnected(reason: String?)
    /// A port-76 payload from another node. The live adapter has already dropped from == myNodeNum.
    case fragment(from: UInt32, Data)
    case unavailable(BLEAdapterUnavailable)
}

/// Meshtastic radio dependency (spec Contract 2). Mechanism only: no fragmentation, no pacing,
/// no retries — reconnecting is MeshtasticKit's job, so the interface just sees repeated
/// `connected`/`disconnected`. The live value lives in the `ReTiCAMeshtasticLive` target (lane E),
/// installed by the app with `$0.meshtasticDriver = .live(session:)`.
public struct MeshtasticDriver: Sendable {
    public var start: @Sendable (MeshtasticDriverConfig) -> AsyncStream<MeshtasticDriverEvent>
    /// One already-framed fragment, sent on port 76 to broadcast with the config's channel/hopLimit,
    /// wantAck false. Returns false if the radio is not connected or the write failed.
    public var send: @Sendable (Data) async -> Bool
    public var stop: @Sendable () async -> Void

    public init(start: @escaping @Sendable (MeshtasticDriverConfig) -> AsyncStream<MeshtasticDriverEvent>,
                send: @escaping @Sendable (Data) async -> Bool,
                stop: @escaping @Sendable () async -> Void) {
        self.start = start
        self.send = send
        self.stop = stop
    }
}

extension MeshtasticDriver: DependencyKey {
    /// The cause the default live value reports. Not a silent no-op: an app that never installed
    /// the live adapter sees `.adapterUnavailable(.other(liveAdapterMissing))` on the first start.
    public static let liveAdapterMissing = "ReTiCAMeshtasticLive not installed"

    public static var liveValue: MeshtasticDriver {
        MeshtasticDriver(
            start: { _ in
                AsyncStream { continuation in
                    continuation.yield(.unavailable(.other(liveAdapterMissing)))
                    continuation.finish()
                }
            },
            send: { _ in false },
            stop: {}
        )
    }

    public static let testValue = MeshtasticDriver(
        start: unimplemented("MeshtasticDriver.start", placeholder: AsyncStream { $0.finish() }),
        send: unimplemented("MeshtasticDriver.send", placeholder: false),
        stop: unimplemented("MeshtasticDriver.stop")
    )
}

extension DependencyValues {
    public var meshtasticDriver: MeshtasticDriver {
        get { self[MeshtasticDriver.self] }
        set { self[MeshtasticDriver.self] = newValue }
    }
}

// "now" for reassembly inactivity. \.date's testValue is unimplemented in this TCA version, so a
// custom key — the \.bleDate pattern (BLEDriver.swift:136-148).
private enum MeshtasticDateKey: DependencyKey {
    static let liveValue = DateGenerator { Date() }
    static let testValue = DateGenerator { Date(timeIntervalSince1970: 0) }
    static let previewValue = liveValue
}

// The sender's pacing clock. Separate from \.continuousClock on purpose: a test can pace fragments
// on an ImmediateClock while Transport's maintenance loop and LXMF's retry timers sit on a
// TestClock that is never advanced (an ImmediateClock under the maintenance loop spins it hot).
private enum MeshtasticClockKey: DependencyKey {
    static var liveValue: any Clock<Duration> { ContinuousClock() }
    static var testValue: any Clock<Duration> { UnimplementedClock(name: "meshtasticClock") }
}

extension DependencyValues {
    public var meshtasticDate: DateGenerator {
        get { self[MeshtasticDateKey.self] }
        set { self[MeshtasticDateKey.self] = newValue }
    }

    public var meshtasticClock: any Clock<Duration> {
        get { self[MeshtasticClockKey.self] }
        set { self[MeshtasticClockKey.self] = newValue }
    }
}
