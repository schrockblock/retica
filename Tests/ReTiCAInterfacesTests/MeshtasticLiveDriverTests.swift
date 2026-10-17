import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
import FCBComposable
import MeshProto
import MeshtasticKit
import MeshtasticMock
import ReTiCAInterfaces
@testable import ReTiCAMeshtasticLive

private let liveRadioNotFound = MeshtasticDriverEvent.unavailable(.other("radio not found"))

private func isLiveUnavailable(_ event: MeshtasticDriverEvent) -> Bool {
    if case .unavailable = event { return true }
    return false
}

/// A `.disconnected(reason: nil)` AFTER the first `.connected`: the drop of a link that was up, not
/// a replayed pre-connect state (which the mapper drops, but a regression there must not satisfy this).
private func liveDroppedAfterConnecting(_ events: [MeshtasticDriverEvent]) -> Bool {
    guard let up = events.firstIndex(where: isLiveConnected) else { return false }
    return events[(up + 1)...].contains(.disconnected(reason: nil))
}

/// `MeshtasticDriver.live(session:)` over a REAL `MeshtasticSession` over FCB's LIVE client
/// (`mocked()`) against `MeshtasticMock` — not a hand mock (mocked-boundaries lesson). Sessions use
/// their default ContinuousClock: the 30 s handshake timeout would fire at once on an ImmediateClock.
extension FCBDriverAdapterCBMTests {
    @Suite @MainActor
    struct MeshtasticLiveDriverTests {
        @Test func liveDriverConnectsWithTheRadiosNodeAndPreset() async {
            let radio = await makeLiveRadio(preset: .shortFast)
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            let saw = await run.waitFor { $0 == liveConnected }
            #expect(saw, "events: \(run.events.value)")
            await driver.stop()
            run.cancel()
        }

        @Test func liveDriverDeliversAPeersPort76Payload() async {
            let radio = await makeLiveRadio()
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            #expect(await run.waitFor(isLiveConnected), "precondition: connected")
            let frame = Data([0x04, 0xFF]) + Data(repeating: 0x33, count: 40)
            radio.device.injectIncomingPacket(portnum: .reticulumTunnelApp, payload: frame, from: livePeer)
            let saw = await run.waitFor { $0 == .fragment(from: livePeer, frame) }
            #expect(saw, "events: \(run.events.value)")
            await driver.stop()
            run.cancel()
        }

        /// Review Focus 4. Injected in order, so the own frame is drained before the peer's.
        @Test func liveDriverDropsItsOwnNodesPackets() async {
            let radio = await makeLiveRadio()
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            #expect(await run.waitFor(isLiveConnected), "precondition: connected")
            let own = Data([0x05, 0xFF, 0x01])
            let peer = Data([0x06, 0xFF, 0x02])
            radio.device.injectIncomingPacket(portnum: .reticulumTunnelApp, payload: own, from: MockMeshtasticDevice.selfNodeNum)
            radio.device.injectIncomingPacket(portnum: .reticulumTunnelApp, payload: peer, from: livePeer)
            #expect(await run.waitFor { $0 == .fragment(from: livePeer, peer) }, "precondition: the peer's frame arrived")
            #expect(run.count { if case .fragment(MockMeshtasticDevice.selfNodeNum, _) = $0 { return true }; return false } == 0)
            await driver.stop()
            run.cancel()
        }

        /// Review Focus 4. The mock also routing-acks every write, on port 5.
        @Test func liveDriverDropsOtherPorts() async {
            let radio = await makeLiveRadio()
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            #expect(await run.waitFor(isLiveConnected), "precondition: connected")
            let marker = Data([0x07, 0xFF, 0x03])
            radio.device.injectIncomingPacket(portnum: .textMessageApp, payload: Data("hi".utf8), from: livePeer)
            radio.device.injectIncomingPacket(portnum: .positionApp, payload: Data([0x01]), from: livePeer)
            radio.device.injectIncomingPacket(portnum: .reticulumTunnelApp, payload: marker, from: livePeer)
            #expect(await run.waitFor { $0 == .fragment(from: livePeer, marker) }, "precondition: the marker arrived")
            #expect(run.count { if case .fragment = $0 { return true }; return false } == 1)
            await driver.stop()
            run.cancel()
        }

        @Test func liveDriverSendsOnPort76ToBroadcastWithTheConfigsChannelAndHopLimit() async {
            let radio = await makeLiveRadio()
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            #expect(await run.waitFor(isLiveConnected), "precondition: connected")
            let frame = Data([0x08, 0xFF]) + Data(repeating: 0x5A, count: 150)
            let ok = await driver.send(frame)
            #expect(ok)
            let written = radio.device.receivedPackets.last
            #expect(written?.decoded.portnum == .reticulumTunnelApp)
            #expect(written?.decoded.payload == frame)
            #expect(written?.to == 0xFFFF_FFFF)
            #expect(written?.channel == 2)
            #expect(written?.hopLimit == 3)
            #expect(written?.wantAck == false)
            await driver.stop()
            run.cancel()
        }

        @Test func liveDriverSendBeforeTheRadioIsConnectedReturnsFalse() async {
            let radio = await makeLiveRadio()
            radio.device.answersWantConfig = false
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            let ok = await driver.send(Data([0x09, 0xFF, 0x01]))
            #expect(!ok)
            await driver.stop()
            run.cancel()
        }

        @Test func liveDriverSendOfAnOversizedFrameReturnsFalse() async {
            let radio = await makeLiveRadio()
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            #expect(await run.waitFor(isLiveConnected), "precondition: connected")
            let control = await driver.send(Data(repeating: 0x01, count: 233))
            #expect(control, "control: an exactly-233-byte frame is accepted, so rejection below is about size")
            let ok = await driver.send(Data(repeating: 0x01, count: 234))
            #expect(!ok)
            await driver.stop()
            run.cancel()
        }

        @Test func liveDriverReportsALostLinkAsDisconnectedThenReconnects() async {
            let radio = await makeLiveRadio()
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            #expect(await run.waitFor(isLiveConnected), "precondition: connected")
            radio.spec.simulateDisconnection()
            let dropped = await liveWaitUntil(timeout: .seconds(10)) { liveDroppedAfterConnecting(run.events.value) }
            #expect(dropped, "events: \(run.events.value)")
            let back = await liveWaitUntil(timeout: .seconds(10)) { run.count(isLiveConnected) == 2 }
            #expect(back, "events: \(run.events.value)")
            await driver.stop()
            run.cancel()
        }

        /// Review Focus 2.
        @Test func liveDriverComesBackAfterABluetoothPowerCycle() async {
            let radio = await makeLiveRadio()
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            #expect(await run.waitFor(isLiveConnected), "precondition: connected")
            CBMCentralManagerMock.simulatePowerOff()
            let dropped = await liveWaitUntil(timeout: .seconds(10)) { liveDroppedAfterConnecting(run.events.value) }
            #expect(dropped, "events: \(run.events.value)")
            CBMCentralManagerMock.simulatePowerOn()
            let back = await liveWaitUntil(timeout: .seconds(15)) { run.count(isLiveConnected) == 2 }
            #expect(back, "events: \(run.events.value)")
            await driver.stop()
            run.cancel()
        }

        /// Review Focus 1.
        @Test func liveDriverReportsAnUnknownRadioAsUnavailable() async {
            let radio = await makeLiveRadio()
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(MeshtasticDriverConfig(radio: UUID())))
            let saw = await run.waitFor { $0 == .unavailable(.other("radio not found")) }
            #expect(saw, "events: \(run.events.value)")
            await driver.stop()
            run.cancel()
        }

        /// Task 3 review. `MeshtasticInterface` restarts from `.unavailable` WITHOUT a stop, and the
        /// session's hub replays its terminal `.disconnected("radio not found")` to the retry's new
        /// subscription. The first start reports exactly one not-found; the retry, on a radio that
        /// is still unknown, reports exactly one more — its own, not the replay as well.
        @Test func liveDriverRetryOfAStillUnknownRadioReportsOnlyItsOwnNotFound() async {
            let radio = await makeLiveRadio()
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let unknown = MeshtasticDriverConfig(radio: UUID())
            let first = LiveDriverRun(driver.start(unknown))
            #expect(await first.waitFor { $0 == liveRadioNotFound }, "events: \(first.events.value)")
            try? await Task.sleep(for: .milliseconds(300))
            #expect(first.count { $0 == liveRadioNotFound } == 1, "events: \(first.events.value)")
            let retry = LiveDriverRun(driver.start(unknown))
            #expect(await retry.waitFor { $0 == liveRadioNotFound }, "events: \(retry.events.value)")
            try? await Task.sleep(for: .milliseconds(300))
            #expect(retry.count(isLiveUnavailable) == 1, "events: \(retry.events.value)")
            await driver.stop()
            first.cancel()
            retry.cancel()
        }

        /// Task 3 review, the other outcome: the radio becomes known between the not-found and the
        /// retry (added to CBM while powered off, the only time CBM accepts new peripherals). The
        /// retry's stream carries no `.unavailable` — the stale not-found replay is dropped — and
        /// reports `.connected`.
        @Test func liveDriverRetryOfARadioNowKnownReportsConnectedWithNoStaleUnavailable() async {
            let radio = await makeLiveRadio()
            let lateID = UUID()
            let lateDevice = MockMeshtasticDevice(now: { Date(timeIntervalSince1970: 2_000_000_000) },
                                                  modemPreset: .shortFast)
            let lateSpec = lateDevice.makeSpec(identifier: lateID)
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let late = MeshtasticDriverConfig(radio: lateID)
            let first = LiveDriverRun(driver.start(late))
            #expect(await first.waitFor { $0 == liveRadioNotFound }, "precondition: events: \(first.events.value)")
            CBMCentralManagerMock.simulatePowerOff()
            try? await Task.sleep(for: .milliseconds(300))
            CBMCentralManagerMock.simulatePeripherals([radio.spec, lateSpec])
            CBMCentralManagerMock.simulatePowerOn()
            #expect(await liveWaitUntilPoweredOn(radio.central), "precondition: powered on")
            let retry = LiveDriverRun(driver.start(late))
            #expect(await retry.waitFor(isLiveConnected), "events: \(retry.events.value)")
            #expect(retry.count(isLiveUnavailable) == 0, "events: \(retry.events.value)")
            await driver.stop()
            first.cancel()
            retry.cancel()
        }

        @Test func liveDriverReportsAPoweredOffAdapterAsUnavailable() async {
            let radio = await makeLiveRadio(initialState: .poweredOff)
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            let saw = await run.waitFor { $0 == .unavailable(.poweredOff) }
            #expect(saw, "events: \(run.events.value)")
            await driver.stop()
            run.cancel()
        }

        @Test func liveDriverStopReturnsWhileTheHandshakeIsStuck() async {
            let radio = await makeLiveRadio()
            radio.device.answersWantConfig = false
            let session = MeshtasticSession(central: radio.central)
            let driver = MeshtasticDriver.live(session: session)
            let run = LiveDriverRun(driver.start(radio.config))
            let configuring = await liveSessionIs(session, .configuring)
            #expect(configuring, "precondition: the handshake started")
            let returned = await returnsWithin(.seconds(5)) { await driver.stop() }
            #expect(returned)
            run.cancel()
        }

        /// Review Focus 3: CoreBluetooth connects never time out.
        @Test func liveDriverStopReturnsWhileTheRadioIsOutOfRange() async {
            let radio = await makeLiveRadio()
            radio.spec.simulateProximityChange(.outOfRange)
            let session = MeshtasticSession(central: radio.central)
            let driver = MeshtasticDriver.live(session: session)
            let run = LiveDriverRun(driver.start(radio.config))
            let connecting = await liveSessionIs(session, .connecting)
            #expect(connecting, "precondition: the connect is pending")
            try? await Task.sleep(for: .milliseconds(300))
            let returned = await returnsWithin(.seconds(5)) { await driver.stop() }
            #expect(returned)
            run.cancel()
        }

        @Test func liveDriverStopLeavesTheSessionDisconnected() async {
            let radio = await makeLiveRadio()
            let session = MeshtasticSession(central: radio.central)
            let driver = MeshtasticDriver.live(session: session)
            let run = LiveDriverRun(driver.start(radio.config))
            #expect(await run.waitFor(isLiveConnected), "precondition: connected")
            await driver.stop()
            try? await Task.sleep(for: .milliseconds(500))
            let down = await liveSessionIs(session, .disconnected(reason: nil), timeout: .milliseconds(300))
            #expect(down)
            run.cancel()
        }

        /// The adapter's connect is an unstructured hop onto the session actor; a stop issued at
        /// once must still leave nothing connected.
        @Test func liveDriverStopRightAfterStartLeavesTheSessionDisconnected() async {
            let radio = await makeLiveRadio()
            let session = MeshtasticSession(central: radio.central)
            let driver = MeshtasticDriver.live(session: session)
            let run = LiveDriverRun(driver.start(radio.config))
            await driver.stop()
            try? await Task.sleep(for: .milliseconds(800))
            let down = await liveSessionIs(session, .disconnected(reason: nil), timeout: .milliseconds(300))
            #expect(down)
            #expect(run.count(isLiveConnected) == 0, "events: \(run.events.value)")
            run.cancel()
        }
    }
}
