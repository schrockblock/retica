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
    await store.receive(.transport(.interfaceConnected(idA, .ble))) {
        $0.transport.interfaces[idA] = .ble
    }
    await store.receive(.delegate(.peerOnline(tokenA)))
    await store.receive(.transport(.startMaintenance))
    #expect(store.state.peerInterfaces[idA] == tokenA)

    // A second peer connects: interfaceConnected fires, but NOT a second startMaintenance.
    let idB = bleInterfaceID(tokenB)
    await store.send(.ble(.delegate(.peerOnline(tokenB))))
    await store.receive(.transport(.interfaceConnected(idB, .ble))) {
        $0.transport.interfaces[idB] = .ble
    }
    await store.receive(.delegate(.peerOnline(tokenB)))
    // (no .startMaintenance here — .off exhaustivity tolerates its absence)

    // Drive both peers offline to cancel the maintenance effect cleanly.
    await store.send(.ble(.delegate(.peerOffline(tokenA))))
    await store.receive(.transport(.interfaceDisconnected(idA))) {
        $0.transport.interfaces[idA] = nil
    }
    await store.receive(.delegate(.peerOffline(tokenA)))
    await store.send(.ble(.delegate(.peerOffline(tokenB))))
    await store.receive(.transport(.interfaceDisconnected(idB))) {
        $0.transport.interfaces[idB] = nil
    }
    await store.receive(.delegate(.peerOffline(tokenB)))
    await store.receive(.transport(.stopMaintenance))
    #expect(store.state.peerInterfaces.isEmpty)
}

@Test @MainActor func lastPeerOfflineStopsMaintenance() async {
    let store = makeStore()
    let idA = bleInterfaceID(tokenA)
    await store.send(.ble(.delegate(.peerOnline(tokenA))))
    await store.receive(.transport(.interfaceConnected(idA, .ble))) { $0.transport.interfaces[idA] = .ble }
    await store.receive(.delegate(.peerOnline(tokenA)))
    await store.receive(.transport(.startMaintenance))

    await store.send(.ble(.delegate(.peerOffline(tokenA))))
    await store.receive(.transport(.interfaceDisconnected(idA))) { $0.transport.interfaces[idA] = nil }
    await store.receive(.delegate(.peerOffline(tokenA)))
    await store.receive(.transport(.stopMaintenance))
}

@Test @MainActor func packetReceivedRoutesToTransportForThatPeersInterface() async {
    let store = makeStore()
    let idA = bleInterfaceID(tokenA)
    // Bring the peer online first (so maintenance can be cancelled at the end).
    await store.send(.ble(.delegate(.peerOnline(tokenA))))
    await store.receive(.transport(.interfaceConnected(idA, .ble))) { $0.transport.interfaces[idA] = .ble }
    await store.receive(.delegate(.peerOnline(tokenA)))
    await store.receive(.transport(.startMaintenance))

    let packet = Data([0x01, 0x02, 0x03])
    await store.send(.ble(.delegate(.packetReceived(peer: tokenA, packet: packet))))
    await store.receive(.transport(.received(idA, packet)))

    await store.send(.ble(.delegate(.peerOffline(tokenA))))
    await store.receive(.transport(.interfaceDisconnected(idA))) { $0.transport.interfaces[idA] = nil }
    await store.receive(.delegate(.peerOffline(tokenA)))
    await store.receive(.transport(.stopMaintenance))
}

@Test @MainActor func transmitForLivePeerRoutesToBLESendWithRightToken() async {
    let store = makeStore()
    let idA = bleInterfaceID(tokenA)
    await store.send(.ble(.delegate(.peerOnline(tokenA))))
    await store.receive(.transport(.interfaceConnected(idA, .ble))) { $0.transport.interfaces[idA] = .ble }
    await store.receive(.delegate(.peerOnline(tokenA)))
    await store.receive(.transport(.startMaintenance))

    let raw = Data([0xAB, 0xCD])
    await store.send(.transport(.delegate(.transmit(idA, raw))))
    await store.receive(.ble(.send(peer: tokenA, packet: raw)))

    await store.send(.ble(.delegate(.peerOffline(tokenA))))
    await store.receive(.transport(.interfaceDisconnected(idA))) { $0.transport.interfaces[idA] = nil }
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

/// A Transport-level transmit to an interface that is no longer connected surfaces as
/// sendFailed rather than vanishing. This is the stale-binding case: a BLE InterfaceID is
/// derived from the peer's session token, so a reconnected peer is a different interface
/// and any link still bound to the old one transmits into the void.
@Test @MainActor func transportTransmitToUnknownInterfaceReportsSendFailed() async {
    let store = makeStore()
    let idA = bleInterfaceID(tokenA)

    // Bring peer A online so there is at least one live interface.
    await store.send(.ble(.delegate(.peerOnline(tokenA))))
    await store.receive(.transport(.interfaceConnected(idA, .ble))) { $0.transport.interfaces[idA] = .ble }
    await store.receive(.delegate(.peerOnline(tokenA)))
    await store.receive(.transport(.startMaintenance))

    // Build a minimal parseable packet whose destinationHash is a known value.
    // Packet layout (header1): [flags(1), hops(1), destHash(16), context(1), payload...]
    let destHash = Data(repeating: 0xDE, count: 16)
    var rawPacket = Data([0x00, 0x00])  // flags=header1/broadcast/single/data, hops=0
    rawPacket.append(destHash)
    rawPacket.append(0x00)              // context=none
    rawPacket.append(0xBB)             // payload byte

    // Transmit to a DIFFERENT (never-connected) interface — stale binding scenario.
    let unknownID = InterfaceID("ble:unknown1234567890ab")
    await store.send(.transport(.delegate(.transmit(unknownID, rawPacket))))
    await store.receive(.delegate(.sendFailed(destinationHash: destHash,
                                              reason: .interfaceUnavailable)))

    // Teardown: take the live peer offline to cancel maintenance cleanly.
    await store.send(.ble(.delegate(.peerOffline(tokenA))))
    await store.receive(.transport(.interfaceDisconnected(idA))) { $0.transport.interfaces[idA] = nil }
    await store.receive(.delegate(.peerOffline(tokenA)))
    await store.receive(.transport(.stopMaintenance))
}

/// The same for link-plane traffic. For a link packet the packet's destination hash IS the
/// link ID (Transport.swift:283 derives `linkID: packet.destinationHash`), so the reported
/// destinationHash correlates the failure to the link exactly.
@Test @MainActor func linkPlaneTransmitToUnknownInterfaceReportsSendFailed() async {
    let store = makeStore()
    let idA = bleInterfaceID(tokenA)

    // Bring peer A online so there is at least one live interface.
    await store.send(.ble(.delegate(.peerOnline(tokenA))))
    await store.receive(.transport(.interfaceConnected(idA, .ble))) { $0.transport.interfaces[idA] = .ble }
    await store.receive(.delegate(.peerOnline(tokenA)))
    await store.receive(.transport(.startMaintenance))

    // Build a minimal parseable packet — destination hash doubles as the link ID.
    let linkID = Data(repeating: 0xCC, count: 16)
    var rawPacket = Data([0x00, 0x00])  // flags=header1/broadcast/single/data, hops=0
    rawPacket.append(linkID)
    rawPacket.append(0x00)              // context=none
    rawPacket.append(0xDD)             // payload byte

    // Transmit via a link-plane delegate to an interface that is not connected.
    let unknownID = InterfaceID("ble:unknown9876543210ef")
    await store.send(.linkPlane(.delegate(.transmit(unknownID, rawPacket))))
    await store.receive(.delegate(.sendFailed(destinationHash: linkID,
                                              reason: .interfaceUnavailable)))

    await store.send(.ble(.delegate(.peerOffline(tokenA))))
    await store.receive(.transport(.interfaceDisconnected(idA))) { $0.transport.interfaces[idA] = nil }
    await store.receive(.delegate(.peerOffline(tokenA)))
    await store.receive(.transport(.stopMaintenance))
}

/// Regression: a transmit to a LIVE interface still goes out, unchanged, and emits no failure.
@Test @MainActor func transmitToLiveInterfaceStillSendsAndReportsNoFailure() async {
    let store = makeStore()
    let idA = bleInterfaceID(tokenA)

    await store.send(.ble(.delegate(.peerOnline(tokenA))))
    await store.receive(.transport(.interfaceConnected(idA, .ble))) { $0.transport.interfaces[idA] = .ble }
    await store.receive(.delegate(.peerOnline(tokenA)))
    await store.receive(.transport(.startMaintenance))

    // Build a parseable packet to send to the live peer's interface.
    let destHash = Data(repeating: 0xAA, count: 16)
    var rawPacket = Data([0x00, 0x00])
    rawPacket.append(destHash)
    rawPacket.append(0x00)
    rawPacket.append(0xEE)

    await store.send(.transport(.delegate(.transmit(idA, rawPacket))))
    await store.receive(.ble(.send(peer: tokenA, packet: rawPacket)))

    await store.send(.ble(.delegate(.peerOffline(tokenA))))
    await store.receive(.transport(.interfaceDisconnected(idA))) { $0.transport.interfaces[idA] = nil }
    await store.receive(.delegate(.peerOffline(tokenA)))
    await store.receive(.transport(.stopMaintenance))
    // Flip exhaustivity last so teardown catches any stray sendFailed action.
    store.exhaustivity = .on
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
