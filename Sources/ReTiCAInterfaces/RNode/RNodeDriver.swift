import Foundation
import ComposableArchitecture

/// The LoRa parameters of one RNode, as written to or echoed by the radio (spec Contract 2).
public struct RNodeLoRaParams: Equatable, Sendable {
    public var frequencyHz: UInt32, bandwidthHz: UInt32, txPowerDBm: UInt8, spreadingFactor: UInt8, codingRate: UInt8

    public init(frequencyHz: UInt32, bandwidthHz: UInt32, txPowerDBm: UInt8,
                spreadingFactor: UInt8, codingRate: UInt8) {
        self.frequencyHz = frequencyHz
        self.bandwidthHz = bandwidthHz
        self.txPowerDBm = txPowerDBm
        self.spreadingFactor = spreadingFactor
        self.codingRate = codingRate
    }

    /// Spec §5.7: `Int((SF · (4 / CR) / (2^SF / (BW / 1000)) · 1000).rounded())`. Never below 1.
    /// A zero CR, SF or bandwidth would divide by zero, so those return 1.
    public var bitrate: Int {
        guard codingRate > 0, spreadingFactor > 0, bandwidthHz > 0 else { return 1 }
        let sf = Double(spreadingFactor)
        let symbolsPerSecondTerm = pow(2.0, sf) / (Double(bandwidthHz) / 1000.0)
        let raw = sf * (4.0 / Double(codingRate)) / symbolsPerSecondTerm * 1000.0
        guard raw.isFinite else { return 1 }
        return max(1, Int(raw.rounded()))
    }
}

/// What the live adapter needs to talk to ONE radio.
public struct RNodeDriverConfig: Equatable, Sendable {
    public var radio: UUID
    public var params: RNodeLoRaParams

    public init(radio: UUID, params: RNodeLoRaParams) {
        self.radio = radio
        self.params = params
    }
}

public struct RNodeRadioReport: Equatable, Sendable {
    public var name: String?
    public var firmwareMajor: UInt8, firmwareMinor: UInt8
    public var platform: UInt8
    public var mcu: UInt8?
    /// What the radio echoed.
    public var params: RNodeLoRaParams

    public init(name: String? = nil, firmwareMajor: UInt8, firmwareMinor: UInt8, platform: UInt8,
                mcu: UInt8? = nil, params: RNodeLoRaParams) {
        self.name = name
        self.firmwareMajor = firmwareMajor
        self.firmwareMinor = firmwareMinor
        self.platform = platform
        self.mcu = mcu
        self.params = params
    }
}

public struct RNodeChannelLoad: Equatable, Sendable {
    public var airtimeShort: Double, airtimeLong: Double, channelLoadShort: Double, channelLoadLong: Double
    public var noiseFloor: Int
    public var interferenceRSSI: Int?

    public init(airtimeShort: Double, airtimeLong: Double, channelLoadShort: Double, channelLoadLong: Double,
                noiseFloor: Int, interferenceRSSI: Int? = nil) {
        self.airtimeShort = airtimeShort
        self.airtimeLong = airtimeLong
        self.channelLoadShort = channelLoadShort
        self.channelLoadLong = channelLoadLong
        self.noiseFloor = noiseFloor
        self.interferenceRSSI = interferenceRSSI
    }
}

public enum RNodeDriverEvent: Equatable, Sendable {
    case connected(RNodeRadioReport)
    case disconnected(reason: String?)
    case packet(Data, rssi: Int?, snr: Double?)
    case channelLoad(RNodeChannelLoad)
    case hardwareError(UInt8)
    case unavailable(BLEAdapterUnavailable)
}

public struct RNodeDriver: Sendable {
    public var start: @Sendable (RNodeDriverConfig) -> AsyncStream<RNodeDriverEvent>
    /// One whole, already IFAC-masked packet, <= 508 B. False if not connected or the write failed.
    public var send: @Sendable (Data) async -> Bool
    public var stop: @Sendable () async -> Void

    public init(start: @escaping @Sendable (RNodeDriverConfig) -> AsyncStream<RNodeDriverEvent>,
                send: @escaping @Sendable (Data) async -> Bool,
                stop: @escaping @Sendable () async -> Void) {
        self.start = start
        self.send = send
        self.stop = stop
    }
}

extension RNodeDriver: DependencyKey {
    /// The cause the default live value reports, so an app that never installed the live adapter
    /// sees `.unavailable(.other(liveAdapterMissing))` on the first start.
    public static let liveAdapterMissing = "ReTiCARNodeLive not installed"

    public static var liveValue: RNodeDriver {
        RNodeDriver(
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

    public static let testValue = RNodeDriver(
        start: unimplemented("RNodeDriver.start", placeholder: AsyncStream { $0.finish() }),
        send: unimplemented("RNodeDriver.send", placeholder: false),
        stop: unimplemented("RNodeDriver.stop")
    )
}

extension DependencyValues {
    public var rnodeDriver: RNodeDriver {
        get { self[RNodeDriver.self] }
        set { self[RNodeDriver.self] = newValue }
    }
}
