import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

@Suite struct MeshtasticDriverTests {
    /// Contract 2: an app that forgot to install `ReTiCAMeshtasticLive` must hear about it, not
    /// get a radio that silently never connects.
    @Test func liveValueReportsTheMissingLiveAdapterLoudly() async {
        var events: [MeshtasticDriverEvent] = []
        for await event in MeshtasticDriver.liveValue.start(MeshtasticDriverConfig(radio: UUID())) {
            events.append(event)
        }
        #expect(events == [.unavailable(.other("ReTiCAMeshtasticLive not installed"))])
    }

    @Test func liveValueSendReportsFailure() async {
        #expect(await MeshtasticDriver.liveValue.send(Data([0x01])) == false)
    }

    /// landandair `speed_to_delay` verbatim, including its fallback of 7 s
    /// (Meshtastic_Interface.py:31-39, 281).
    @Test func fragmentDelayIsLandandairsSpeedToDelay() {
        let rows: [(Int?, Duration)] = [
            (8, .milliseconds(400)), (6, .seconds(1)), (5, .seconds(3)), (7, .seconds(12)),
            (4, .seconds(4)), (3, .seconds(6)), (1, .seconds(15)), (0, .seconds(8)),
            (2, .seconds(7)), (99, .seconds(7)), (nil, .seconds(7)),
        ]
        for (preset, delay) in rows {
            #expect(MeshtasticModemPreset.fragmentDelay(preset) == delay,
                    "preset \(String(describing: preset))")
        }
    }

    /// Contract 3's bitrate column: `Int(202 * 8 / fragmentDelay(preset))`.
    @Test func pacedBitrateMatchesTheContractTable() {
        let rows: [(Int?, Int)] = [
            (8, 4040), (6, 1616), (5, 538), (4, 404), (3, 269),
            (0, 202), (7, 134), (1, 107), (2, 230), (nil, 230),
        ]
        for (preset, bitrate) in rows {
            #expect(MeshtasticModemPreset.pacedBitrate(preset) == bitrate,
                    "preset \(String(describing: preset))")
        }
    }
}
