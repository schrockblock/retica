import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

@Suite struct RNodeDriverTests {
    @Test func liveValueReportsTheMissingLiveAdapter() async {
        var events: [RNodeDriverEvent] = []
        let config = RNodeDriverConfig(
            radio: UUID(),
            params: RNodeLoRaParams(frequencyHz: 868_000_000, bandwidthHz: 62500, txPowerDBm: 0,
                                    spreadingFactor: 8, codingRate: 6)
        )
        for await event in RNodeDriver.liveValue.start(config) {
            events.append(event)
        }
        #expect(events == [.unavailable(.other("ReTiCARNodeLive not installed"))])
    }

    @Test func liveValueSendReportsFailure() async {
        #expect(await RNodeDriver.liveValue.send(Data([0x01])) == false)
    }
}

private func rnodeParams(_ sf: UInt8, _ bw: UInt32, _ cr: UInt8) -> RNodeLoRaParams {
    RNodeLoRaParams(frequencyHz: 868_000_000, bandwidthHz: bw, txPowerDBm: 0,
                    spreadingFactor: sf, codingRate: cr)
}

@Suite struct RNodeBitrateTests {
    @Test func bitrateMatchesTheSpecTable() {
        let rows: [(UInt8, UInt32, UInt8, Int)] = [
            (7, 125000, 5, 5469), (8, 125000, 5, 3125), (8, 62500, 6, 1302), (9, 125000, 5, 1758),
            (10, 250000, 5, 1953), (12, 125000, 8, 183), (12, 7800, 8, 11), (5, 1_625_000, 5, 203_125),
        ]
        for (sf, bw, cr, bps) in rows {
            #expect(rnodeParams(sf, bw, cr).bitrate == bps, "SF \(sf) BW \(bw) CR \(cr)")
        }
    }

    @Test func bitrateRoundsToTheNearestBit() {
        // 5468.75 exactly: rounding gives 5469, truncating 5468.
        #expect(rnodeParams(7, 125000, 5).bitrate == 5469)
        #expect(rnodeParams(7, 125000, 5).bitrate != 5468)
    }

    @Test func bitrateIsNeverBelowOne() {
        #expect(rnodeParams(12, 1, 8).bitrate == 1)
        #expect(rnodeParams(0, 0, 0).bitrate == 1)
    }

    @Test func everyAppRangeCombinationIsAtLeastElevenBps() {
        for sf in UInt8(5)...12 {
            for cr in UInt8(5)...8 {
                for bw in [UInt32(7800), 62500, 1_625_000] {
                    #expect(rnodeParams(sf, bw, cr).bitrate >= 11, "SF \(sf) BW \(bw) CR \(cr)")
                }
            }
        }
    }
}
