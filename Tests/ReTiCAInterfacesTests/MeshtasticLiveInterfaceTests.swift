import Testing
import Foundation
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
import MeshProto
import MeshtasticKit
import MeshtasticMock
@testable import ReTiCAInterfaces
import ReTiCAMeshtasticLive

/// LIVE values end to end: the `MeshtasticInterface` reducer over `MeshtasticDriver.live` over a
/// real session over FCB `mocked()` over MeshtasticMock. Pacing on an ImmediateClock is fine — the
/// session keeps its own ContinuousClock.
@MainActor
private func makeLiveInterface(_ radio: LiveRadio) -> TestStore<MeshtasticInterface.State, MeshtasticInterface.Action> {
    let session = MeshtasticSession(central: radio.central)
    let store = TestStore(initialState: MeshtasticInterface.State(config: radio.config)) {
        MeshtasticInterface()
    } withDependencies: {
        $0.meshtasticDriver = .live(session: session)
        $0.meshtasticClock = ImmediateClock()
        $0.meshtasticDate = DateGenerator { Date(timeIntervalSince1970: 1_000) }
    }
    store.exhaustivity = .off
    return store
}

@MainActor
private func goOnline(_ store: TestStore<MeshtasticInterface.State, MeshtasticInterface.Action>) async {
    await store.send(.start)
    await store.receive({ $0 == .delegate(.online(myNodeNum: MockMeshtasticDevice.selfNodeNum,
                                                  modemPreset: Config.LoRaConfig.ModemPreset.shortFast.rawValue)) },
                        timeout: .seconds(10))
}

private func livePattern(_ count: Int, seed: UInt8) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0) &+ seed })
}

extension FCBDriverAdapterCBMTests {
    @Suite @MainActor
    struct MeshtasticLiveInterfaceTests {
        @Test func liveRadioPutsAPacketsFragmentsOnPort76() async {
            let radio = await makeLiveRadio()
            let store = makeLiveInterface(radio)
            await goOnline(store)
            let packet = livePattern(300, seed: 3)
            await store.send(.send(packet))
            let expected = LandandairCodec().split(packet, index: 0)
            let sent = await liveWaitUntil(timeout: .seconds(10)) {
                radio.device.receivedPackets.filter { $0.decoded.portnum == .reticulumTunnelApp }.count == expected.count
            }
            #expect(sent)
            #expect(radio.device.receivedPackets.filter { $0.decoded.portnum == .reticulumTunnelApp }.map(\.decoded.payload) == expected)
            await store.send(.stop)
            await store.skipReceivedActions(strict: false)
        }

        @Test func liveRadioReassemblesAPeersFragments() async {
            let radio = await makeLiveRadio()
            let store = makeLiveInterface(radio)
            await goOnline(store)
            let packet = livePattern(400, seed: 9)
            for frame in LandandairCodec().split(packet, index: 12) {
                radio.device.injectIncomingPacket(portnum: .reticulumTunnelApp, payload: frame, from: livePeer)
            }
            await store.receive({ $0 == .delegate(.packetReceived(packet)) }, timeout: .seconds(10))
            await store.send(.stop)
            await store.skipReceivedActions(strict: false)
        }

        /// MeshtasticKit emits `.adapterUnavailable(.unauthorized)` then a terminal
        /// `.disconnected("unauthorized")`. The interface must stay `.unavailable` (never wedge in
        /// `.connecting`) so a second `.start` reaches the driver.
        @Test func anUnauthorizedAdapterLeavesTheInterfaceUnavailableAndRestartable() async {
            let radio = await makeLiveRadio(initialState: .unauthorized)
            let session = MeshtasticSession(central: radio.central)
            let live = MeshtasticDriver.live(session: session)
            let starts = LockIsolated(0)
            let store = TestStore(initialState: MeshtasticInterface.State(config: radio.config)) {
                MeshtasticInterface()
            } withDependencies: {
                $0.meshtasticDriver = MeshtasticDriver(
                    start: { config in
                        starts.withValue { $0 += 1 }
                        return live.start(config)
                    },
                    send: live.send,
                    stop: live.stop)
                $0.meshtasticClock = ImmediateClock()
                $0.meshtasticDate = DateGenerator { Date(timeIntervalSince1970: 1_000) }
            }
            store.exhaustivity = .off
            await store.send(.start)
            await store.receive({ $0 == .delegate(.adapterUnavailable(.unauthorized)) }, timeout: .seconds(10))
            // The session's terminal end has happened, so any mapped `.disconnected` has been sent.
            #expect(await liveSessionIs(session, .disconnected(reason: "unauthorized")),
                    "precondition: the session ended with unauthorized")
            await store.skipReceivedActions(strict: false)
            #expect(store.state.status == .unavailable(.unauthorized))
            await store.send(.start)
            #expect(starts.value == 2)
            await store.send(.stop)
            await store.skipReceivedActions(strict: false)
            await session.disconnect()
        }

        /// Contract 3 with the LIVE driver: `driver.stop()` returns, and offline follows it.
        @Test func liveRadioStopReportsOfflineAfterTheDriverStops() async {
            let radio = await makeLiveRadio()
            let store = makeLiveInterface(radio)
            await goOnline(store)
            await store.send(.stop)
            await store.receive({ $0 == .driverStopped }, timeout: .seconds(10))
            await store.receive({ $0 == .delegate(.offline(reason: nil)) }, timeout: .seconds(2))
        }
    }
}
