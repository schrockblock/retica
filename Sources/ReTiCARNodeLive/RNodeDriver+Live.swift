import Foundation
import RNodeKit
import ReTiCAInterfaces

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

    private func message(forTerminalReason reason: String) -> String {
        switch reason {
        case RNodeSession.firmwareTooOldReason:        return RNodeLiveMessage.firmwareTooOld
        case RNodeSession.pairingRequiredReason:       return RNodeLiveMessage.pairingRequired
        case RNodeSession.pairingRemovedReason:        return RNodeLiveMessage.pairingRemoved
        case RNodeSession.configurationRejectedReason: return RNodeLiveMessage.configurationRejected(rejected)
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
