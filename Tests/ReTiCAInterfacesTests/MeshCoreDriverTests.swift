import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

@Suite struct MeshCoreDriverTests {
    @Test func liveValueReportsTheMissingLiveAdapter() async {
        var events: [MeshCoreDriverEvent] = []
        for await event in MeshCoreDriver.liveValue.start(
            MeshCoreDriverConfig(radio: UUID(), channelSecret: Data(repeating: 1, count: 16))
        ) {
            events.append(event)
        }
        #expect(events == [.unavailable(.other("ReTiCAMeshCoreLive not installed"))])
    }

    @Test func liveValueSendReportsFailure() async {
        #expect(await MeshCoreDriver.liveValue.send(Data([0x01])) == false)
    }

    @Test func liveValueRemoveChannelReportsFailure() async {
        #expect(await MeshCoreDriver.liveValue.removeChannel() == false)
    }

    @Test func configDefaultsMatchTheContract() {
        let config = MeshCoreDriverConfig(radio: UUID(), channelSecret: Data(repeating: 1, count: 16))
        #expect(config.channelName == "RNSTunnel")
        #expect(config.dataType == 0xFFFF)
        #expect(config.retiredChannelSecrets == [])
        #expect(config.canRoute == false)
    }

    @Test func liveBindDelayStaysWithin3To15Seconds() {
        let random = MeshCoreRandom.liveValue
        for _ in 0..<1000 {
            let delay = random.bindDelay()
            #expect(delay >= .seconds(3) && delay <= .seconds(15))
        }
    }
}

private func params(_ sf: UInt8, _ bw: UInt32, _ cr: UInt8) -> MeshCoreLinkParams {
    MeshCoreLinkParams(spreadingFactor: sf, bandwidthHz: bw, codingRate: cr)
}

/// (SF, bandwidth Hz, CR) rows of the spec table.
private let meshCoreSpecRows: [(UInt8, UInt32, UInt8)] = [
    (7, 62500, 5), (7, 62500, 7), (8, 62500, 8), (9, 125000, 5), (10, 250000, 5), (11, 250000, 5),
]

@Suite struct MeshCorePacingTests {
    @Test func airtimeMatchesTheSpecTable() {
        let expected = [633.344, 850.432, 1688.576, 955.392, 873.472, 1583.104]
        for (row, ms) in zip(meshCoreSpecRows, expected) {
            let got = MeshCoreLinkPacing.airtimeMilliseconds(params(row.0, row.1, row.2))
            #expect(abs(got - ms) < 0.001, "row \(row)")
        }
    }

    @Test func fragmentDelayMatchesTheSpecTable() {
        let expected = [2500, 2500, 3378, 2500, 2500, 3167]
        for (row, ms) in zip(meshCoreSpecRows, expected) {
            #expect(MeshCoreLinkPacing.fragmentDelay(params(row.0, row.1, row.2)) == .milliseconds(ms),
                    "row \(row)")
        }
        #expect(MeshCoreLinkPacing.fragmentDelay(nil) == .seconds(5))
    }

    @Test func bitrateMatchesTheSpecTable() {
        let expected = [473, 473, 350, 473, 473, 373]
        for (row, bps) in zip(meshCoreSpecRows, expected) {
            #expect(MeshCoreLinkPacing.bitrate(params(row.0, row.1, row.2)) == bps, "row \(row)")
        }
        #expect(MeshCoreLinkPacing.bitrate(nil) == 236)
    }

    /// Expected values from an independent script of the Semtech formula. SF 9 at 41.7 kHz has a
    /// 12.28 ms symbol (optimise off); SF 11 at 125 kHz has exactly 16.384 ms (on).
    @Test func lowDataRateOptimiseStartsAt16MillisecondSymbols() {
        let rows: [(UInt8, UInt32, UInt8, Double)] = [
            (9, 41700, 5, 2863.884892086331),
            (11, 125000, 5, 3821.568),
            (12, 125000, 5, 6987.776),
        ]
        for (sf, bw, cr, ms) in rows {
            let got = MeshCoreLinkPacing.airtimeMilliseconds(params(sf, bw, cr))
            #expect(abs(got - ms) < 0.001, "SF \(sf) BW \(bw)")
        }
    }

    @Test func outOfRangeParamsUseFiveSeconds() {
        let bad = [
            params(4, 125000, 5), params(13, 125000, 5), params(7, 125000, 4), params(7, 125000, 9),
            params(7, 0, 5), params(7, 6999, 5), params(7, 500001, 5),
        ]
        for p in bad {
            #expect(!MeshCoreLinkPacing.isInRange(p), "\(p)")
            #expect(MeshCoreLinkPacing.fragmentDelay(p) == .seconds(5), "\(p)")
            #expect(MeshCoreLinkPacing.bitrate(p) == 236, "\(p)")
        }
    }

    @Test func everyValidParamCombinationHasAPositiveBitrate() {
        for sf in UInt8(5)...12 {
            for cr in UInt8(5)...8 {
                for bw in [UInt32(7000), 62500, 500_000] {
                    #expect(MeshCoreLinkPacing.bitrate(params(sf, bw, cr)) > 0, "\(sf) \(bw) \(cr)")
                }
            }
        }
        #expect(MeshCoreLinkPacing.bitrate(params(12, 7000, 8)) == 3)
    }
}
