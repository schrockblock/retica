import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

private let load = RNodeChannelLoad(airtimeShort: 1.5, airtimeLong: 0.75, channelLoadShort: 12.25,
                                    channelLoadLong: 8.5, noiseFloor: -112, interferenceRSSI: -90)

/// Telemetry rule (pre-flight F6): `.channelLoad` and `.hardwareError` are recorded in every status
/// but `.stopped`; a packet's RSSI/SNR only when the packet is delivered (online).
@MainActor @Suite struct RNodeInterfaceTelemetryTests {
    @Test func packetSignalUpdatesTelemetry() async {
        let h = await makeOnlineRNodeInterface()
        let p = Data(repeating: 0x11, count: 60)
        h.radio.yield(.packet(p, rssi: -97, snr: 6.25))
        await h.store.receive { $0 == .delegate(.packetReceived(p)) }
        #expect(h.store.state.telemetry.lastRSSI == -97)
        #expect(h.store.state.telemetry.lastSNR == 6.25)
        await stopRNodeInterface(h)
    }

    @Test func aPacketWithoutSignalKeepsTheLastValues() async {
        let h = await makeOnlineRNodeInterface()
        let p = Data(repeating: 0x11, count: 60)
        let q = Data(repeating: 0x22, count: 60)
        h.radio.yield(.packet(p, rssi: -97, snr: 6.25))
        h.radio.yield(.packet(q, rssi: nil, snr: nil))
        await h.store.receive { $0 == .delegate(.packetReceived(q)) }
        #expect(h.store.state.telemetry.lastRSSI == -97)
        #expect(h.store.state.telemetry.lastSNR == 6.25)
        await stopRNodeInterface(h)
    }

    /// A packet the interface does not deliver (not yet online) leaves the signal alone.
    @Test func aPacketBeforeOnlineLeavesTheSignalAlone() async {
        let h = makeRNodeInterface()
        await h.store.send(.start)
        let p = Data(repeating: 0x11, count: 60)
        h.radio.yield(.packet(p, rssi: -97, snr: 6.25))
        await h.store.receive { $0 == .driverEvent(.packet(p, rssi: -97, snr: 6.25)) }
        #expect(h.store.state.telemetry.lastRSSI == nil)
        #expect(h.store.state.telemetry.lastSNR == nil)
        await stopRNodeInterface(h)
    }

    @Test func channelLoadIsRecorded() async {
        let h = await makeOnlineRNodeInterface()
        h.radio.yield(.channelLoad(load))
        await h.store.receive { $0 == .driverEvent(.channelLoad(load)) }
        #expect(h.store.state.telemetry.channelLoad == load)
        await stopRNodeInterface(h)
    }

    /// Stats arrive mid-handshake (§5.2) and are real radio data.
    @Test func telemetryWhileConnectingIsRecorded() async {
        let h = makeRNodeInterface()
        await h.store.send(.start)
        h.radio.yield(.channelLoad(load))
        h.radio.yield(.hardwareError(3))
        await h.store.receive { $0 == .driverEvent(.hardwareError(3)) }
        #expect(h.store.state.status == .connecting)
        #expect(h.store.state.telemetry.channelLoad == load)
        #expect(h.store.state.telemetry.lastHardwareError == 3)
        #expect(h.store.state.counters.hardwareErrors == 1)
        await stopRNodeInterface(h)
    }

    // Review Focus 4.
    @Test func hardwareErrorsAreCountedWithoutChangingStatus() async {
        let h = await makeOnlineRNodeInterface()
        for _ in 0..<5 { h.radio.yield(.hardwareError(2)) }
        for _ in 0..<5 { await h.store.receive { $0 == .driverEvent(.hardwareError(2)) } }
        #expect(h.store.state.counters.hardwareErrors == 5)
        #expect(h.store.state.telemetry.lastHardwareError == 2)
        #expect(h.store.state.status == .online(rnodeTestReport))
        #expect(!h.delegates.value.contains { if case .offline = $0 { return true }; return false })
        await stopRNodeInterface(h)
    }

    @Test func telemetrySurvivesADisconnect() async {
        let h = await makeOnlineRNodeInterface()
        let p = Data(repeating: 0x11, count: 60)
        h.radio.yield(.packet(p, rssi: -97, snr: 6.25))
        h.radio.yield(.channelLoad(load))
        h.radio.yield(.hardwareError(2))
        await h.store.receive { $0 == .driverEvent(.hardwareError(2)) }
        let expected = RNodeTelemetry(lastRSSI: -97, lastSNR: 6.25, channelLoad: load, lastHardwareError: 2)
        #expect(h.store.state.telemetry == expected)
        h.radio.yield(.disconnected(reason: nil))
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        #expect(h.store.state.telemetry == expected)
        await stopRNodeInterface(h)
    }

    @Test func telemetryEventsAfterStopAreIgnored() async {
        let h = await makeOnlineRNodeInterface()
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await h.store.send(.driverEvent(.channelLoad(load)))
        await h.store.send(.driverEvent(.hardwareError(2)))
        #expect(h.store.state.telemetry.channelLoad == nil)
        #expect(h.store.state.telemetry.lastHardwareError == nil)
        #expect(h.store.state.counters.hardwareErrors == 0)
    }
}
