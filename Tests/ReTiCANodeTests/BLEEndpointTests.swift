import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport

private let tokenA = Data(repeating: 0xA1, count: 16)
private let tokenB = Data(repeating: 0xB2, count: 16)

@MainActor
private func makeStore() -> TestStore<BLEEndpoint.State, BLEEndpoint.Action> {
    let store = TestStore(initialState: BLEEndpoint.State()) {
        BLEEndpoint()
    } withDependencies: {
        $0.continuousClock = TestClock()
        // Benign driver so `.start`/`.stop` forwarding runs without hitting the
        // unimplemented testValue; the wiring tests inject `.ble(.delegate(...))`
        // directly and never rely on the driver.
        $0.bleDriver = BLEDriver(
            start: { _ in AsyncStream { $0.finish() } },
            readDirectory: { _ in }, openChannel: { _, _ in },
            send: { _, _ in }, closeChannel: { _ in }, stop: { }
        )
    }
    store.exhaustivity = .off
    return store
}

// Compile-driven adjustment: store.send is async in this TCA version; all store.send(...)
// calls use `await` (not in the brief's code sample which omitted them).

@Test @MainActor func peerOnlineRegistersInterfaceAndStartsMaintenanceOnFirstPeer() async {
    let store = makeStore()
    let idA = bleInterfaceID(tokenA)

    await store.send(.ble(.delegate(.peerOnline(tokenA))))
    await store.receive(.transport(.interfaceConnected(idA))) {
        $0.transport.interfaces.insert(idA)
    }
    await store.receive(.delegate(.peerOnline(tokenA)))
    await store.receive(.transport(.startMaintenance))
    #expect(store.state.peerInterfaces[idA] == tokenA)

    // A second peer connects: interfaceConnected fires, but NOT a second startMaintenance.
    let idB = bleInterfaceID(tokenB)
    await store.send(.ble(.delegate(.peerOnline(tokenB))))
    await store.receive(.transport(.interfaceConnected(idB))) {
        $0.transport.interfaces.insert(idB)
    }
    await store.receive(.delegate(.peerOnline(tokenB)))
    // (no .startMaintenance here — .off exhaustivity tolerates its absence)

    // Drive both peers offline to cancel the maintenance effect cleanly.
    await store.send(.ble(.delegate(.peerOffline(tokenA))))
    await store.receive(.transport(.interfaceDisconnected(idA))) {
        $0.transport.interfaces.remove(idA)
    }
    await store.receive(.delegate(.peerOffline(tokenA)))
    await store.send(.ble(.delegate(.peerOffline(tokenB))))
    await store.receive(.transport(.interfaceDisconnected(idB))) {
        $0.transport.interfaces.remove(idB)
    }
    await store.receive(.delegate(.peerOffline(tokenB)))
    await store.receive(.transport(.stopMaintenance))
    #expect(store.state.peerInterfaces.isEmpty)
}

@Test @MainActor func lastPeerOfflineStopsMaintenance() async {
    let store = makeStore()
    let idA = bleInterfaceID(tokenA)
    await store.send(.ble(.delegate(.peerOnline(tokenA))))
    await store.receive(.transport(.interfaceConnected(idA))) { $0.transport.interfaces.insert(idA) }
    await store.receive(.delegate(.peerOnline(tokenA)))
    await store.receive(.transport(.startMaintenance))

    await store.send(.ble(.delegate(.peerOffline(tokenA))))
    await store.receive(.transport(.interfaceDisconnected(idA))) { $0.transport.interfaces.remove(idA) }
    await store.receive(.delegate(.peerOffline(tokenA)))
    await store.receive(.transport(.stopMaintenance))
}

@Test @MainActor func packetReceivedRoutesToTransportForThatPeersInterface() async {
    let store = makeStore()
    let idA = bleInterfaceID(tokenA)
    // Bring the peer online first (so maintenance can be cancelled at the end).
    await store.send(.ble(.delegate(.peerOnline(tokenA))))
    await store.receive(.transport(.interfaceConnected(idA))) { $0.transport.interfaces.insert(idA) }
    await store.receive(.delegate(.peerOnline(tokenA)))
    await store.receive(.transport(.startMaintenance))

    let packet = Data([0x01, 0x02, 0x03])
    await store.send(.ble(.delegate(.packetReceived(peer: tokenA, packet: packet))))
    await store.receive(.transport(.received(idA, packet)))

    await store.send(.ble(.delegate(.peerOffline(tokenA))))
    await store.receive(.transport(.interfaceDisconnected(idA))) { $0.transport.interfaces.remove(idA) }
    await store.receive(.delegate(.peerOffline(tokenA)))
    await store.receive(.transport(.stopMaintenance))
}

@Test @MainActor func transmitForLivePeerRoutesToBLESendWithRightToken() async {
    let store = makeStore()
    let idA = bleInterfaceID(tokenA)
    await store.send(.ble(.delegate(.peerOnline(tokenA))))
    await store.receive(.transport(.interfaceConnected(idA))) { $0.transport.interfaces.insert(idA) }
    await store.receive(.delegate(.peerOnline(tokenA)))
    await store.receive(.transport(.startMaintenance))

    let raw = Data([0xAB, 0xCD])
    await store.send(.transport(.delegate(.transmit(idA, raw))))
    await store.receive(.ble(.send(peer: tokenA, packet: raw)))

    await store.send(.ble(.delegate(.peerOffline(tokenA))))
    await store.receive(.transport(.interfaceDisconnected(idA))) { $0.transport.interfaces.remove(idA) }
    await store.receive(.delegate(.peerOffline(tokenA)))
    await store.receive(.transport(.stopMaintenance))
}

@Test @MainActor func transmitForUnknownInterfaceIsDropped() async {
    let store = makeStore()
    // Use .on exhaustivity so that any spurious .ble(.send(...)) action fails the test.
    // Mutation 4 produces such an action; with .off it would be silently swallowed.
    store.exhaustivity = .on
    // No peers online → no peerInterfaces entry. A stray transmit must not route.
    let strayID = InterfaceID("ble:deadbeef")
    await store.send(.transport(.delegate(.transmit(strayID, Data([0x01])))))
    // With .on exhaustivity, any unasserted received actions (e.g. a stray .ble(.send))
    // will fail the test when finish() drains.
    await store.finish()
}

@Test @MainActor func transportDelegatesForwardToEndpointDelegates() async {
    let store = makeStore()
    let h = Data(repeating: 0x11, count: 16)
    await store.send(.transport(.delegate(.pathLearned(destinationHash: h, hops: 3))))
    await store.receive(.delegate(.pathLearned(destinationHash: h, hops: 3)))

    await store.send(.transport(.delegate(.received(destinationHash: h, plaintext: Data([0x09])))))
    await store.receive(.delegate(.messageReceived(destinationHash: h, plaintext: Data([0x09]))))

    await store.send(.transport(.delegate(.sendFailed(destinationHash: h, reason: .notLearned))))
    await store.receive(.delegate(.sendFailed(destinationHash: h, reason: .notLearned)))
}
