import Testing
import Foundation
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
import MeshCoreKit
import MeshCoreMock
import ReTiCAInterfaces
import ReTiCAMeshCoreLive

private typealias CoreStore = TestStore<MeshCoreInterface.State, MeshCoreInterface.Action>

/// LIVE values end to end: the `MeshCoreInterface` reducer over `MeshCoreDriver.live` over a real
/// session over FCB `mocked()` over MeshCoreMock. Pacing on an ImmediateClock is fine: the session
/// keeps its own ContinuousClock.
@MainActor
private func makeCoreInterface(_ radio: LiveCoreRadio, session: MeshCoreSession,
                               driver: MeshCoreDriver? = nil) -> CoreStore {
    let store = TestStore(initialState: MeshCoreInterface.State(config: radio.config())) {
        MeshCoreInterface()
    } withDependencies: {
        $0.meshCoreDriver = driver ?? .live(session: session)
        $0.meshCoreClock = ImmediateClock()
        $0.meshCoreDate = DateGenerator { Date(timeIntervalSince1970: 1_700_000_000) }
    }
    store.exhaustivity = .off
    return store
}

private func isOnlineDelegate(_ action: MeshCoreInterface.Action) -> Bool {
    if case .delegate(.online) = action { return true }
    return false
}

private func isOfflineDelegate(_ action: MeshCoreInterface.Action) -> Bool {
    if case .delegate(.offline) = action { return true }
    return false
}

private func isUnavailableDelegate(_ action: MeshCoreInterface.Action) -> Bool {
    if case .delegate(.adapterUnavailable) = action { return true }
    return false
}

@MainActor
private func goOnline(_ store: CoreStore) async {
    await store.send(.start)
    await store.receive(isOnlineDelegate, timeout: .seconds(10))
}

/// ScotMesh Raw frames of `body`, from a peer to broadcast.
private let corePeerPrefix = Data([0xAA, 0xBB, 0xCC, 0xDD])

private func peerFrames(_ body: Data, packetID: UInt16) -> [Data] {
    ScotMeshRawCodec().split(body, type: .rnsFragment, src: corePeerPrefix, dst: ScotMeshRawCodec.broadcast,
                             packetID: packetID, canRoute: false)
}

/// The session's connection state right now (the hub replays it first to a new subscriber).
private func currentConnection(_ session: MeshCoreSession) async -> MeshCoreConnectionState? {
    for await event in session.events() {
        if case let .connection(state) = event { return state }
    }
    return nil
}

extension FCBDriverAdapterCBMTests {
    @Suite @MainActor
    struct MeshCoreLiveInterfaceTests {
        @Test func liveInterfaceComesOnlineWithRadioParams() async {
            let radio = await makeLiveCoreRadio()
            let session = MeshCoreSession(central: radio.central, appName: "ReTiCATests")
            let store = makeCoreInterface(radio, session: session)
            await goOnline(store)
            #expect(store.state.status == .online(
                selfPrefix: MockMeshCoreDevice.selfKey.prefix(4), publicKey: MockMeshCoreDevice.selfKey,
                params: MeshCoreLinkParams(spreadingFactor: 10, bandwidthHz: 250_000, codingRate: 5)))
            await store.send(.stop)
            await store.skipReceivedActions(strict: false)
            await session.disconnect()
        }

        @Test func liveInterfaceReassemblesAPacketFromThePeer() async {
            let radio = await makeLiveCoreRadio()
            let session = MeshCoreSession(central: radio.central, appName: "ReTiCATests")
            let store = makeCoreInterface(radio, session: session)
            await goOnline(store)
            let body = Data((0..<200).map { UInt8(truncatingIfNeeded: $0) })
            let frames = peerFrames(body, packetID: 0x0101)
            #expect(frames.count == 2)
            for frame in frames { radio.device.injectChannelData(frame, channelIndex: 1) }
            await store.receive({ $0 == .delegate(.packetReceived(body)) }, timeout: .seconds(10))
            await store.send(.stop)
            await store.skipReceivedActions(strict: false)
            await session.disconnect()
        }

        @Test func liveInterfaceSendsFramedDatagrams() async {
            let radio = await makeLiveCoreRadio()
            let session = MeshCoreSession(central: radio.central, appName: "ReTiCATests")
            let store = makeCoreInterface(radio, session: session)
            await goOnline(store)
            let packet = Data((0..<40).map { UInt8(truncatingIfNeeded: $0) &+ 5 })
            await store.send(.send(packet))
            let sent = await liveWaitUntil(timeout: .seconds(10)) { radio.frames(0x3E) == 1 }
            #expect(sent, "frames: \(radio.device.receivedFrames)")
            if let frame = radio.device.receivedFrames.last(where: { $0.first == 0x3E }) {
                // 3E slot FF(flood) FFFF(data type), then the ScotMesh datagram.
                #expect(Array(frame.prefix(6)) == [0x3E, 0x01, 0xFF, 0xFF, 0xFF, 0x52])
                let datagram = Data(frame.dropFirst(5))
                let parsed = ScotMeshRawCodec().parse(datagram)
                #expect(parsed?.src == MockMeshCoreDevice.selfKey.prefix(4))
                #expect(parsed?.dst == Data(count: 4))
                #expect(parsed?.body == packet)
            }
            await store.send(.stop)
            await store.skipReceivedActions(strict: false)
            await session.disconnect()
        }

        /// Review Focus 1: a full radio reports and releases; after the user frees a slot, a fresh
        /// `.start` comes online.
        @Test func liveInterfaceRestartAfterAFreedSlotComesOnline() async {
            let radio = await makeLiveCoreRadio(channels: liveCoreFullRadio())
            let session = MeshCoreSession(central: radio.central, appName: "ReTiCATests")
            let store = makeCoreInterface(radio, session: session)
            await store.send(.start)
            await store.receive(isUnavailableDelegate, timeout: .seconds(10))
            #expect(store.state.status == .unavailable(.other(MeshCoreLiveMessage.noFreeSlot)))
            radio.device.channelSlots = liveCoreSlots()
            await store.send(.start)
            await store.receive(isOnlineDelegate, timeout: .seconds(10))
            #expect(store.state.isOnline)
            await store.send(.stop)
            await store.skipReceivedActions(strict: false)
            await session.disconnect()
        }

        /// Contract 3 with the LIVE driver: the offline that follows `.stop` comes only after
        /// `driver.stop()` returned, and by then the session is down.
        @Test func liveInterfaceStopReportsOfflineOnlyAfterTheSessionIsDown() async {
            let radio = await makeLiveCoreRadio()
            let session = MeshCoreSession(central: radio.central, appName: "ReTiCATests")
            let live = MeshCoreDriver.live(session: session)
            let stateWhenStopReturned = LockIsolated<MeshCoreConnectionState?>(nil)
            let driver = MeshCoreDriver(
                start: live.start, send: live.send, removeChannel: live.removeChannel,
                stop: {
                    await live.stop()
                    let state = await currentConnection(session)
                    stateWhenStopReturned.setValue(state)
                })
            let store = makeCoreInterface(radio, session: session, driver: driver)
            await goOnline(store)
            await store.send(.stop)
            await store.receive({ $0 == .driverStopped }, timeout: .seconds(10))
            await store.receive(isOfflineDelegate, timeout: .seconds(2))
            if case .disconnected = stateWhenStopReturned.value {} else {
                Issue.record("the session was \(String(describing: stateWhenStopReturned.value)) when stop returned")
            }
        }

        @Test func liveInterfaceReconnectDeliversAgain() async {
            let radio = await makeLiveCoreRadio()
            let session = MeshCoreSession(central: radio.central, appName: "ReTiCATests")
            let store = makeCoreInterface(radio, session: session)
            await goOnline(store)
            radio.spec.simulateDisconnection()
            await store.receive(isOfflineDelegate, timeout: .seconds(10))
            await store.receive(isOnlineDelegate, timeout: .seconds(10))
            let body = Data((0..<30).map { UInt8(truncatingIfNeeded: $0) &+ 9 })
            for frame in peerFrames(body, packetID: 0x0202) { radio.device.injectChannelData(frame, channelIndex: 1) }
            await store.receive({ $0 == .delegate(.packetReceived(body)) }, timeout: .seconds(10))
            await store.send(.stop)
            await store.skipReceivedActions(strict: false)
            await session.disconnect()
        }

        /// Turn-off: the slot is cleared, then the stop follows; offline comes after `.channelRemoved`.
        @Test func liveInterfaceRemovalClearsTheSlotThenStops() async {
            let radio = await makeLiveCoreRadio()
            let session = MeshCoreSession(central: radio.central, appName: "ReTiCATests")
            let store = makeCoreInterface(radio, session: session)
            await goOnline(store)
            #expect(radio.device.channelSlots[1].secret == liveCoreKey, "precondition: our channel is on slot 1")
            await store.send(.removeChannel)
            await store.receive({ $0 == .delegate(.channelRemoved(true)) }, timeout: .seconds(10))
            await store.send(.stop)
            await store.receive(isOfflineDelegate, timeout: .seconds(10))
            #expect(radio.device.channelSlots[1] == liveCoreEmptySlot(1))
            #expect(store.state.status == .stopped)
            await session.disconnect()
        }
    }
}
