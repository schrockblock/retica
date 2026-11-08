import Foundation
import ComposableArchitecture

/// What the live adapter needs to talk to ONE radio (spec Contract 2).
public struct MeshCoreDriverConfig: Equatable, Sendable {
    public var radio: UUID
    /// 16 bytes.
    public var channelSecret: Data
    public var channelName: String = "RNSTunnel"
    /// Firmware's DATA_TYPE_DEV; also ScotMesh's default.
    public var dataType: UInt16 = 0xFFFF
    /// Keys this app used before a key change. Any slot holding one is ours to clear.
    public var retiredChannelSecrets: [Data] = []
    /// Mirrors the app's Relay setting; sets the header's can-route bit.
    public var canRoute: Bool = false

    public init(radio: UUID, channelSecret: Data, channelName: String = "RNSTunnel",
                dataType: UInt16 = 0xFFFF, retiredChannelSecrets: [Data] = [],
                canRoute: Bool = false) {
        self.radio = radio
        self.channelSecret = channelSecret
        self.channelName = channelName
        self.dataType = dataType
        self.retiredChannelSecrets = retiredChannelSecrets
        self.canRoute = canRoute
    }
}

public struct MeshCoreLinkParams: Equatable, Sendable {
    public var spreadingFactor: UInt8, bandwidthHz: UInt32, codingRate: UInt8

    public init(spreadingFactor: UInt8, bandwidthHz: UInt32, codingRate: UInt8) {
        self.spreadingFactor = spreadingFactor
        self.bandwidthHz = bandwidthHz
        self.codingRate = codingRate
    }
}

public enum MeshCoreDriverEvent: Equatable, Sendable {
    /// `selfPrefix` is the first 4 bytes of the radio's public key.
    case connected(selfPrefix: Data, publicKey: Data, params: MeshCoreLinkParams?)
    case disconnected(reason: String?)
    /// A tunnel candidate from either carrier, already filtered to our channel slot and data type.
    case datagram(Data)
    case retiredChannelsCleared
    case unavailable(BLEAdapterUnavailable)
}

public struct MeshCoreDriver: Sendable {
    public var start: @Sendable (MeshCoreDriverConfig) -> AsyncStream<MeshCoreDriverEvent>
    /// One already-framed tunnel datagram, <= 162 B. False if not connected or the radio refused it.
    public var send: @Sendable (Data) async -> Bool
    /// Clears the slot holding the current key. False if not connected or the radio refused.
    public var removeChannel: @Sendable () async -> Bool
    public var stop: @Sendable () async -> Void

    public init(start: @escaping @Sendable (MeshCoreDriverConfig) -> AsyncStream<MeshCoreDriverEvent>,
                send: @escaping @Sendable (Data) async -> Bool,
                removeChannel: @escaping @Sendable () async -> Bool,
                stop: @escaping @Sendable () async -> Void) {
        self.start = start
        self.send = send
        self.removeChannel = removeChannel
        self.stop = stop
    }
}

extension MeshCoreDriver: DependencyKey {
    /// The cause the default live value reports, so an app that never installed the live adapter
    /// sees `.unavailable(.other(liveAdapterMissing))` on the first start.
    public static let liveAdapterMissing = "ReTiCAMeshCoreLive not installed"

    public static var liveValue: MeshCoreDriver {
        MeshCoreDriver(
            start: { _ in
                AsyncStream { continuation in
                    continuation.yield(.unavailable(.other(liveAdapterMissing)))
                    continuation.finish()
                }
            },
            send: { _ in false },
            removeChannel: { false },
            stop: {}
        )
    }

    public static let testValue = MeshCoreDriver(
        start: unimplemented("MeshCoreDriver.start", placeholder: AsyncStream { $0.finish() }),
        send: unimplemented("MeshCoreDriver.send", placeholder: false),
        removeChannel: unimplemented("MeshCoreDriver.removeChannel", placeholder: false),
        stop: unimplemented("MeshCoreDriver.stop")
    )
}

/// Randomness the interface needs, as a small dependency because `\.withRandomNumberGenerator`'s
/// test value fails on use and two call sites need scripted values.
public struct MeshCoreRandom: Sendable {
    /// The first fragment/BIND packet ID.
    public var packetID: @Sendable () -> UInt16
    /// How long to wait before answering a `BIND_REQ`.
    public var bindDelay: @Sendable () -> Duration

    public init(packetID: @escaping @Sendable () -> UInt16,
                bindDelay: @escaping @Sendable () -> Duration) {
        self.packetID = packetID
        self.bindDelay = bindDelay
    }
}

extension MeshCoreRandom: DependencyKey {
    public static var liveValue: MeshCoreRandom {
        MeshCoreRandom(
            packetID: { UInt16.random(in: .min ... .max) },
            bindDelay: { .milliseconds(Int.random(in: 3000...15000)) }
        )
    }

    public static var testValue: MeshCoreRandom {
        MeshCoreRandom(packetID: { 0x1000 }, bindDelay: { .seconds(3) })
    }
}

// "now" for the limiter and the BIND limit. \.date's testValue is unimplemented in this TCA
// version, so a custom key, as for Meshtastic.
private enum MeshCoreDateKey: DependencyKey {
    static let liveValue = DateGenerator { Date() }
    static let testValue = DateGenerator { Date(timeIntervalSince1970: 0) }
    static let previewValue = liveValue
}

// The sender's pacing clock, separate from \.continuousClock for the reason given in
// MeshtasticDriver.swift.
private enum MeshCoreClockKey: DependencyKey {
    static var liveValue: any Clock<Duration> { ContinuousClock() }
    static var testValue: any Clock<Duration> { UnimplementedClock(name: "meshCoreClock") }
}

extension DependencyValues {
    public var meshCoreDriver: MeshCoreDriver {
        get { self[MeshCoreDriver.self] }
        set { self[MeshCoreDriver.self] = newValue }
    }

    public var meshCoreDate: DateGenerator {
        get { self[MeshCoreDateKey.self] }
        set { self[MeshCoreDateKey.self] = newValue }
    }

    public var meshCoreClock: any Clock<Duration> {
        get { self[MeshCoreClockKey.self] }
        set { self[MeshCoreClockKey.self] = newValue }
    }

    public var meshCoreRandom: MeshCoreRandom {
        get { self[MeshCoreRandom.self] }
        set { self[MeshCoreRandom.self] = newValue }
    }
}
