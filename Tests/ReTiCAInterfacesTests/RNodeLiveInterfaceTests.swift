import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
import RNodeKit
import RNodeMock
@testable import ReTiCAInterfaces
import ReTiCARNodeLive

private typealias RNodeStore = TestStore<RNodeInterface.State, RNodeInterface.Action>

/// A REAL `RNodeInterface` over `RNodeDriver.live` over a real session over FCB `mocked()` over
/// RNodeMock, with every delegate logged in reduce order (exhaustivity is off, so a test can only
/// prove a delegate was NOT sent from the log).
@MainActor
private struct LiveRNodeInterface {
    let store: RNodeStore
    let delegates: LockIsolated<[RNodeInterface.Action.Delegate]>

    func count(_ match: (RNodeInterface.Action.Delegate) -> Bool) -> Int {
        delegates.value.filter(match).count
    }
}

@MainActor
private func makeLiveRNodeInterface(_ config: RNodeDriverConfig, driver: RNodeDriver) -> LiveRNodeInterface {
    let delegates = LockIsolated<[RNodeInterface.Action.Delegate]>([])
    let store = TestStore(initialState: RNodeInterface.State(config: config)) {
        RNodeDelegateRecorder(delegates: delegates)
    } withDependencies: {
        $0.rnodeDriver = driver
    }
    store.exhaustivity = .off
    return LiveRNodeInterface(store: store, delegates: delegates)
}

private func isOnlineDelegate(_ action: RNodeInterface.Action) -> Bool {
    if case .delegate(.online) = action { return true }
    return false
}

private func isOfflineDelegate(_ action: RNodeInterface.Action) -> Bool {
    if case .delegate(.offline) = action { return true }
    return false
}

private func isUnavailable(_ delegate: RNodeInterface.Action.Delegate) -> Bool {
    if case .adapterUnavailable = delegate { return true }
    return false
}

private func isOnline(_ delegate: RNodeInterface.Action.Delegate) -> Bool {
    if case .online = delegate { return true }
    return false
}

@MainActor
private func goOnline(_ live: LiveRNodeInterface) async {
    await live.store.send(.start)
    await live.store.receive(isOnlineDelegate, timeout: .seconds(10))
}

@MainActor
private func stopLive(_ live: LiveRNodeInterface, session: RNodeSession) async {
    await live.store.send(.stop)
    await live.store.receive(isOfflineDelegate, timeout: .seconds(10))
    await live.store.skipReceivedActions(strict: false)
    await session.disconnect()
}

/// What the mock reports for `params` with its default identity.
private func liveInterfaceReport(_ params: RNodeLoRaParams) -> RNodeRadioReport {
    RNodeRadioReport(name: "RNode 1A2B", firmwareMajor: 1, firmwareMinor: 0x56, platform: 0x80, mcu: 0x81,
                     params: params)
}

/// 30 dBm asked of a radio whose maximum is 22.
private let liveInterfaceTooHotParams = RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 62_500,
                                                        txPowerDBm: 30, spreadingFactor: 8, codingRate: 6)
private let liveInterfaceLoweredParams = RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 62_500,
                                                         txPowerDBm: 17, spreadingFactor: 8, codingRate: 6)
private let liveInterfaceRejection = BLEAdapterUnavailable.other(
    "The radio didn't accept these settings: TX power 22 dBm (asked for 30 dBm). Change them in Settings, then Connect.")

private let liveInterfaceInsufficientEncryption: any Error = CBATTError(.insufficientEncryption)

/// The session's connection state right now (the hub replays it first to a new subscriber).
private func currentRNodeConnection(_ session: RNodeSession) async -> RNodeConnectionState? {
    for await event in session.events() {
        if case let .connection(state) = event { return state }
    }
    return nil
}

extension FCBDriverAdapterCBMTests {
    @Suite @MainActor
    struct RNodeLiveInterfaceTests {
        @Test func liveInterfaceComesOnlineWithTheReport() async {
            let radio = await makeLiveRNodeRadio()
            let session = RNodeSession(central: radio.central)
            let live = makeLiveRNodeInterface(radio.config(), driver: .live(session: session))
            await goOnline(live)
            #expect(live.store.state.status == .online(liveInterfaceReport(rnodeLiveParams)))
            await stopLive(live, session: session)
        }

        @Test func liveInterfaceDeliversAPacketFromTheRadio() async {
            let radio = await makeLiveRNodeRadio()
            let session = RNodeSession(central: radio.central)
            let live = makeLiveRNodeInterface(radio.config(), driver: .live(session: session))
            await goOnline(live)
            let packet = Data([0x52, 0x11]) + Data(repeating: 0x44, count: 60)
            radio.device.injectPacket(packet)
            await live.store.receive({ $0 == .delegate(.packetReceived(packet)) }, timeout: .seconds(10))
            #expect(live.store.state.telemetry.lastRSSI == -67)
            await stopLive(live, session: session)
        }

        /// Stop-and-wait over the live driver: five sends in one burst queue behind the first and
        /// reach the radio whole, in order.
        @Test func liveInterfaceSendsQueuedPacketsInOrder() async {
            let radio = await makeLiveRNodeRadio()
            let session = RNodeSession(central: radio.central)
            let live = makeLiveRNodeInterface(radio.config(), driver: .live(session: session))
            await goOnline(live)
            let packets = (0..<5).map { Data([0x52, UInt8($0)]) + Data(repeating: UInt8($0) &+ 0x30, count: 80) }
            for packet in packets { await live.store.send(.send(packet)) }
            let sent = await liveWaitUntil(timeout: .seconds(10)) { radio.device.receivedPackets.count >= 5 }
            #expect(sent, "packets: \(radio.device.receivedPackets.count)")
            #expect(radio.device.receivedPackets == packets)
            await stopLive(live, session: session)
        }

        /// Ledger carry 3: the live stream yields `.unavailable` before it finishes, so the
        /// interface leaves `.connecting` and shows the Contract 2 message.
        @Test func liveInterfaceRejectedConfigIsUnavailableWithTheMessage() async {
            let radio = await makeLiveRNodeRadio(maxTXPower: 22)
            let session = RNodeSession(central: radio.central)
            let live = makeLiveRNodeInterface(radio.config(liveInterfaceTooHotParams), driver: .live(session: session))
            await live.store.send(.start)
            await live.store.receive({ $0 == .delegate(.adapterUnavailable(liveInterfaceRejection)) },
                                     timeout: .seconds(10))
            #expect(live.store.state.status == .unavailable(liveInterfaceRejection))
            #expect(live.count(isOnline) == 0, "delegates: \(live.delegates.value)")
            await stopLive(live, session: session)
        }

        /// Review Focus 1's driver half: after the rejection, the host stops the slot and builds a
        /// new one with 17 dBm on the SAME session; it comes online with the new params.
        @Test func liveInterfaceRestartAfterARejectionComesOnline() async {
            let radio = await makeLiveRNodeRadio(maxTXPower: 22)
            let session = RNodeSession(central: radio.central)
            let driver = RNodeDriver.live(session: session)
            let rejected = makeLiveRNodeInterface(radio.config(liveInterfaceTooHotParams), driver: driver)
            await rejected.store.send(.start)
            // Preflight L7: the rejection must be seen BEFORE the stop, or dropping `.finish`
            // would leave this test passing on the stop-and-restart alone.
            await rejected.store.receive({ $0 == .delegate(.adapterUnavailable(liveInterfaceRejection)) },
                                         timeout: .seconds(10))
            #expect(rejected.store.state.status == .unavailable(liveInterfaceRejection))
            await rejected.store.send(.stop)
            await rejected.store.receive(isOfflineDelegate, timeout: .seconds(10))
            await rejected.store.skipReceivedActions(strict: false)
            #expect(rejected.store.state.isIdle)
            let slot = makeLiveRNodeInterface(radio.config(liveInterfaceLoweredParams), driver: driver)
            await goOnline(slot)
            #expect(slot.store.state.status == .online(liveInterfaceReport(liveInterfaceLoweredParams)))
            await stopLive(slot, session: session)
        }

        /// Review Focus 2: one pairing retry, then the firmware drops the freshly paired link
        /// (ledger: `simulateDisconnect()` after `.connected`). The slot flips offline-online once,
        /// never reports the adapter unavailable, and ends online.
        @Test func liveInterfacePostPairingDropEndsOnline() async {
            let radio = await makeLiveRNodeRadio()
            radio.device.setNotifyErrors = [liveInterfaceInsufficientEncryption]
            let session = RNodeSession(central: radio.central)
            let live = makeLiveRNodeInterface(radio.config(), driver: .live(session: session))
            await goOnline(live)
            radio.device.simulateDisconnect()
            await live.store.receive(isOfflineDelegate, timeout: .seconds(10))
            await live.store.receive(isOnlineDelegate, timeout: .seconds(15))
            #expect(live.store.state.status == .online(liveInterfaceReport(rnodeLiveParams)))
            #expect(live.count(isUnavailable) == 0, "delegates: \(live.delegates.value)")
            #expect(live.count(isOnline) == 2, "delegates: \(live.delegates.value)")
            await stopLive(live, session: session)
        }

        /// Contract 3 with the LIVE driver: the offline that follows `.stop` comes only after
        /// `driver.stop()` returned, and by then the session is down.
        @Test func liveInterfaceStopReportsOfflineOnlyAfterTheSessionIsDown() async {
            let radio = await makeLiveRNodeRadio()
            let session = RNodeSession(central: radio.central)
            let inner = RNodeDriver.live(session: session)
            let stateWhenStopReturned = LockIsolated<RNodeConnectionState?>(nil)
            let driver = RNodeDriver(
                start: inner.start, send: inner.send,
                stop: {
                    await inner.stop()
                    let state = await currentRNodeConnection(session)
                    stateWhenStopReturned.setValue(state)
                })
            let live = makeLiveRNodeInterface(radio.config(), driver: driver)
            await goOnline(live)
            await live.store.send(.stop)
            await live.store.receive({ $0 == .driverStopped }, timeout: .seconds(10))
            await live.store.receive(isOfflineDelegate, timeout: .seconds(2))
            #expect(stateWhenStopReturned.value == .disconnected(reason: nil),
                    "the session was \(String(describing: stateWhenStopReturned.value)) when stop returned")
            await session.disconnect()
        }

        @Test func liveInterfaceReconnectDeliversAgain() async {
            let radio = await makeLiveRNodeRadio()
            let session = RNodeSession(central: radio.central)
            let live = makeLiveRNodeInterface(radio.config(), driver: .live(session: session))
            await goOnline(live)
            radio.spec.simulateDisconnection()
            await live.store.receive(isOfflineDelegate, timeout: .seconds(10))
            await live.store.receive(isOnlineDelegate, timeout: .seconds(15))
            let packet = Data([0x52, 0x12]) + Data(repeating: 0x66, count: 30)
            radio.device.injectPacket(packet)
            await live.store.receive({ $0 == .delegate(.packetReceived(packet)) }, timeout: .seconds(10))
            await stopLive(live, session: session)
        }
    }
}
