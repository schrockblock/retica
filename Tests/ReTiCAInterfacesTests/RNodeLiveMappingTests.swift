import Testing
import Foundation
import RNodeKit
import ReTiCAInterfaces
@testable import ReTiCARNodeLive

private let echoed = RNodeRadioConfig(frequencyHz: 868_100_000, bandwidthHz: 125_000, txPowerDBm: 14,
                                      spreadingFactor: 8, codingRate: 5)

private func info() -> RNodeRadioInfo {
    RNodeRadioInfo(name: "RNode A1B2", firmwareMajor: 1, firmwareMinor: 86, platform: 0x80, mcu: 0x81,
                   reported: echoed)
}

/// A mapper that has seen its subscription's `.connecting`.
private func live() -> RNodeEventMapper {
    var mapper = RNodeEventMapper()
    _ = mapper.map(.connection(.connecting))
    return mapper
}

private func end(_ reason: String) -> RNodeEvent {
    .connection(.disconnected(reason: reason))
}

@Suite struct RNodeLiveMappingTests {
    @Test func aReplayedStaleTerminalEndIsDropped() {
        var mapper = RNodeEventMapper()
        #expect(mapper.map(end("radio not found")) == .ignore)
    }

    @Test func eventsAfterConnectingMapNormally() {
        var mapper = RNodeEventMapper()
        #expect(mapper.map(.connection(.connecting)) == .ignore)
        #expect(mapper.map(.connection(.reconnecting(attempt: 1))) == .emit(.disconnected(reason: nil)))
        #expect(mapper.map(.packet(Data([0x01]), rssi: -70, snr: 5.5))
                == .emit(.packet(Data([0x01]), rssi: -70, snr: 5.5)))
    }

    @Test func configuredBecomesConnectedWithTheReport() {
        var mapper = live()
        let params = RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 125_000, txPowerDBm: 14,
                                     spreadingFactor: 8, codingRate: 5)
        let expected = RNodeRadioReport(name: "RNode A1B2", firmwareMajor: 1, firmwareMinor: 86,
                                        platform: 0x80, mcu: 0x81, params: params)
        #expect(mapper.map(.configured(info())) == .emit(.connected(expected)))
        #expect(RNodeEventMapper.report(info()) == expected)
    }

    @Test func packetsKeepTheirSignal() {
        var mapper = live()
        let packet = Data([0xAA, 0xBB, 0xCC])
        #expect(mapper.map(.packet(packet, rssi: -67, snr: 6.0)) == .emit(.packet(packet, rssi: -67, snr: 6.0)))
        #expect(mapper.map(.packet(packet, rssi: nil, snr: nil)) == .emit(.packet(packet, rssi: nil, snr: nil)))
    }

    @Test func channelStatsBecomeChannelLoad() {
        var mapper = live()
        let stats = RNodeChannelStats(airtimeShort: 1.5, airtimeLong: 2.25, channelLoadShort: 3.5,
                                      channelLoadLong: 4.75, currentRSSI: -90, noiseFloor: -110,
                                      interferenceRSSI: -95)
        let expected = RNodeChannelLoad(airtimeShort: 1.5, airtimeLong: 2.25, channelLoadShort: 3.5,
                                        channelLoadLong: 4.75, noiseFloor: -110, interferenceRSSI: -95)
        #expect(mapper.map(.channelStats(stats)) == .emit(.channelLoad(expected)))
        #expect(RNodeEventMapper.load(stats) == expected)
    }

    @Test func radioErrorsBecomeHardwareErrors() {
        var mapper = live()
        #expect(mapper.map(.radioError(code: 0x03)) == .emit(.hardwareError(0x03)))
    }

    @Test func reconnectingIsADisconnect() {
        var mapper = live()
        #expect(mapper.map(.connection(.reconnecting(attempt: 3))) == .emit(.disconnected(reason: nil)))
        #expect(mapper.map(.connection(.disconnected(reason: nil))) == .emit(.disconnected(reason: nil)))
    }

    @Test(arguments: ["unauthorized", "unsupported"])
    func anAdapterEndIsIgnored(reason: String) {
        var mapper = live()
        #expect(mapper.map(end(reason)) == .ignore)
    }

    @Test func firmwareTooOldFinishesWithItsMessage() {
        var mapper = live()
        #expect(mapper.map(end(RNodeSession.firmwareTooOldReason))
                == .finish(.unavailable(.other("This RNode's firmware is too old. Update it to 1.52 or later."))))
    }

    @Test func pairingRequiredFinishesWithItsMessage() {
        var mapper = live()
        #expect(mapper.map(end(RNodeSession.pairingRequiredReason))
                == .finish(.unavailable(.other(
                    "Pairing didn't finish. Hold the RNode's button for 5 to 10 seconds until it shows a PIN, then Connect and enter that PIN."))))
    }

    @Test func pairingRemovedFinishesWithItsMessage() {
        var mapper = live()
        #expect(mapper.map(end(RNodeSession.pairingRemovedReason))
                == .finish(.unavailable(.other(
                    "This RNode no longer recognises this device. Forget the RNode in this device's Bluetooth settings, then pair again."))))
    }

    @Test func rejectionFinishesWithTheRememberedMismatches() {
        var mapper = live()
        #expect(mapper.map(.configurationRejected([RNodeParameterMismatch(field: .txPower, requested: 30,
                                                                           reported: 22)])) == .ignore)
        #expect(mapper.map(end(RNodeSession.configurationRejectedReason))
                == .finish(.unavailable(.other(
                    "The radio didn't accept these settings: TX power 22 dBm (asked for 30 dBm). Change them in Settings, then Connect."))))
    }

    @Test func rejectionMessageFormatsEveryField() {
        let text = RNodeLiveMessage.configurationRejected([
            RNodeParameterMismatch(field: .frequency, requested: 868_100_000, reported: 868_125_000),
            RNodeParameterMismatch(field: .bandwidth, requested: 62_500, reported: 125_000),
            RNodeParameterMismatch(field: .txPower, requested: 30, reported: 22),
            RNodeParameterMismatch(field: .spreadingFactor, requested: 13, reported: 12),
            RNodeParameterMismatch(field: .codingRate, requested: 9, reported: 8),
            RNodeParameterMismatch(field: .radioState, requested: 1, reported: 0),
        ])
        #expect(text == "The radio didn't accept these settings: "
                + "frequency 868.125 MHz (asked for 868.1 MHz), bandwidth 125 kHz (asked for 62.5 kHz), "
                + "TX power 22 dBm (asked for 30 dBm), spreading factor 12 (asked for 13), "
                + "coding rate 8 (asked for 9), the radio didn't turn on. Change them in Settings, then Connect.")
    }

    @Test func rejectionMessageForAMissingEcho() {
        let text = RNodeLiveMessage.configurationRejected([
            RNodeParameterMismatch(field: .codingRate, requested: 6, reported: nil),
        ])
        #expect(text == "The radio didn't accept these settings: coding rate no reply (asked for 6). "
                + "Change them in Settings, then Connect.")
    }

    /// Ledger ruling (preflight L4): the radio state reads the same whatever the radio echoed.
    @Test func rejectionMessageRadioStateIgnoresTheEcho() {
        let text = RNodeLiveMessage.configurationRejected([
            RNodeParameterMismatch(field: .radioState, requested: 1, reported: nil),
        ])
        #expect(text == "The radio didn't accept these settings: the radio didn't turn on. "
                + "Change them in Settings, then Connect.")
    }

    @Test func anUnknownTerminalEndPassesItsReason() {
        var mapper = live()
        #expect(mapper.map(end("radio not found")) == .finish(.unavailable(.other("radio not found"))))
    }

    @Test(arguments: [
        (RNodeAdapterUnavailable.poweredOff, BLEAdapterUnavailable.poweredOff),
        (.unauthorized, .unauthorized),
        (.unsupported, .unsupported),
        (.other("x"), .other("x")),
        (.other(nil), .other(nil)),
    ])
    func adapterCausesMap(cause: RNodeAdapterUnavailable, expected: BLEAdapterUnavailable) {
        var mapper = live()
        #expect(mapper.map(.adapterUnavailable(cause)) == .emit(.unavailable(expected)))
    }

    @Test func needsUserActionIsExactlyTheFourMessages() {
        #expect(RNodeLiveMessage.needsUserAction(RNodeLiveMessage.firmwareTooOld))
        #expect(RNodeLiveMessage.needsUserAction(RNodeLiveMessage.pairingRequired))
        #expect(RNodeLiveMessage.needsUserAction(RNodeLiveMessage.pairingRemoved))
        #expect(RNodeLiveMessage.needsUserAction(RNodeLiveMessage.configurationRejected([
            RNodeParameterMismatch(field: .txPower, requested: 30, reported: 22),
        ])))
        #expect(!RNodeLiveMessage.needsUserAction("radio not found"))
        #expect(!RNodeLiveMessage.needsUserAction(""))
        #expect(RNodeLiveMessage.configurationRejectedPrefix == "The radio didn't accept these settings: ")
    }

    @Test func configFromParamsKeepsEveryValue() {
        let params = RNodeLoRaParams(frequencyHz: 915_000_000, bandwidthHz: 62_500, txPowerDBm: 7,
                                     spreadingFactor: 9, codingRate: 6)
        #expect(RNodeRadioConfig(params) == RNodeRadioConfig(frequencyHz: 915_000_000, bandwidthHz: 62_500,
                                                             txPowerDBm: 7, spreadingFactor: 9, codingRate: 6))
    }
}
