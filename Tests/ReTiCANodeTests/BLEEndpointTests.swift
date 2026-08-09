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

/// Pins the deliberate residue of the undeliverable-transmit path: a packet that cannot be
/// parsed drops SILENTLY, emitting neither `.ble(.send)` nor `.delegate(.sendFailed)`.
/// `sendFailed` carries a destinationHash, and an unparseable packet has no destination to
/// report — so there is nothing meaningful to surface and the drop stands. This is the ONLY
/// case that still vanishes; the unknown-interface case it superficially resembles is now
/// reported, and is covered by `transportTransmitToUnknownInterfaceReportsSendFailed` and
/// `linkPlaneTransmitToUnknownInterfaceReportsSendFailed`.
@Test @MainActor func transmitForUnparseablePacketIsDropped() async {
    let store = makeStore()
    // .on exhaustivity so ANY emitted action — a stray .ble(.send) or an unwanted
    // .delegate(.sendFailed) — fails the test when finish() drains.
    store.exhaustivity = .on
    // A 1-byte payload is below the 2-byte minimum `Packet(raw:)` needs for flags+hops, so
    // it fails to parse. The interface is also unknown, which is what routes it into the
    // guard in the first place; parseability is what decides silence vs. sendFailed there.
    let strayID = InterfaceID("ble:deadbeef")
    await store.send(.transport(.delegate(.transmit(strayID, Data([0x01])))))
    await store.finish()
}

/// A Transport-level transmit to an interface that is no longer connected surfaces as
/// sendFailed rather than vanishing. This is the stale-binding case: a BLE InterfaceID is
/// derived from the peer's session token, so a reconnected peer is a different interface
/// and any link still bound to the old one transmits into the void.
///
/// The bad transmit is the LAST store.send so teardown catches any stray .ble(.send) that
/// might be emitted alongside the sendFailed. (With .off exhaustivity a subsequent send
/// would wipe the queue, hiding a stray action.)
@Test @MainActor func transportTransmitToUnknownInterfaceReportsSendFailed() async {
    let store = makeStore()
    let idA = bleInterfaceID(tokenA)

    // Bring peer A online so there is at least one live interface.
    await store.send(.ble(.delegate(.peerOnline(tokenA))))
    await store.receive(.transport(.interfaceConnected(idA, .ble))) { $0.transport.interfaces[idA] = .ble }
    await store.receive(.delegate(.peerOnline(tokenA)))
    await store.receive(.transport(.startMaintenance))

    // Teardown the live peer FIRST — before the bad transmit — so nothing wipes the queue.
    await store.send(.ble(.delegate(.peerOffline(tokenA))))
    await store.receive(.transport(.interfaceDisconnected(idA))) { $0.transport.interfaces[idA] = nil }
    await store.receive(.delegate(.peerOffline(tokenA)))
    await store.receive(.transport(.stopMaintenance))

    // Build a minimal parseable packet whose destinationHash is a known value.
    // Packet layout (header1): [flags(1), hops(1), destHash(16), context(1), payload...]
    let destHash = Data(repeating: 0xDE, count: 16)
    var rawPacket = Data([0x00, 0x00])  // flags=header1/broadcast/single/data, hops=0
    rawPacket.append(destHash)
    rawPacket.append(0x00)              // context=none
    rawPacket.append(0xBB)             // payload byte

    // Transmit to a DIFFERENT (never-connected) interface — stale binding scenario.
    // This is the last send; teardown will catch any stray .ble(.send) emitted here.
    let unknownID = InterfaceID("ble:unknown1234567890ab")
    store.exhaustivity = .on
    await store.send(.transport(.delegate(.transmit(unknownID, rawPacket))))
    await store.receive(.delegate(.sendFailed(destinationHash: destHash,
                                              reason: .interfaceUnavailable)))
}

/// The same for link-plane traffic. For established link traffic the packet's destination
/// hash IS the link ID (Transport.swift:291 derives `linkID: packet.destinationHash`), so
/// the reported destinationHash correlates the failure to the link exactly.
///
/// flags=0x03 sets header1/broadcast/single/linkPacket (the link-packet type byte), matching
/// the comment's reasoning about a link packet. The bad transmit is last so teardown catches
/// any stray .ble(.send) that might accompany the sendFailed.
@Test @MainActor func linkPlaneTransmitToUnknownInterfaceReportsSendFailed() async {
    let store = makeStore()
    let idA = bleInterfaceID(tokenA)

    // Bring peer A online so there is at least one live interface.
    await store.send(.ble(.delegate(.peerOnline(tokenA))))
    await store.receive(.transport(.interfaceConnected(idA, .ble))) { $0.transport.interfaces[idA] = .ble }
    await store.receive(.delegate(.peerOnline(tokenA)))
    await store.receive(.transport(.startMaintenance))

    // Teardown the live peer FIRST — before the bad transmit — so nothing wipes the queue.
    await store.send(.ble(.delegate(.peerOffline(tokenA))))
    await store.receive(.transport(.interfaceDisconnected(idA))) { $0.transport.interfaces[idA] = nil }
    await store.receive(.delegate(.peerOffline(tokenA)))
    await store.receive(.transport(.stopMaintenance))

    // Build a minimal parseable link-plane packet — destination hash doubles as the link ID.
    // flags=0x03: header1 | link-packet type, matching the link-packet prose above.
    let linkID = Data(repeating: 0xCC, count: 16)
    var rawPacket = Data([0x03, 0x00])  // flags=header1/broadcast/single/linkPacket, hops=0
    rawPacket.append(linkID)
    rawPacket.append(0x00)              // context=none
    rawPacket.append(0xDD)             // payload byte

    // Transmit via a link-plane delegate to an interface that is not connected.
    // This is the last send; teardown will catch any stray .ble(.send) emitted here.
    let unknownID = InterfaceID("ble:unknown9876543210ef")
    store.exhaustivity = .on
    await store.send(.linkPlane(.delegate(.transmit(unknownID, rawPacket))))
    await store.receive(.delegate(.sendFailed(destinationHash: linkID,
                                              reason: .interfaceUnavailable)))
}

/// Regression: a transmit to a LIVE interface still goes out, unchanged, and emits no failure.
///
/// Exhaustivity is .on for the transmit and receive ONLY, so teardown catches a stray
/// sendFailed that might be emitted alongside the .ble(.send). The surrounding setup/teardown
/// uses .off (the makeStore default) to stay concise.
@Test @MainActor func transmitToLiveInterfaceStillSendsAndReportsNoFailure() async {
    let store = makeStore()  // .off by default
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

    // Flip to .on for the transmit pair: a stray sendFailed emitted alongside .ble(.send)
    // would be detected because no other store.send follows to wipe the queue.
    store.exhaustivity = .on
    await store.send(.transport(.delegate(.transmit(idA, rawPacket))))
    await store.receive(.ble(.send(peer: tokenA, packet: rawPacket)))
    // Back to .off for teardown (peerOffline cascades through several actions).
    store.exhaustivity = .off

    await store.send(.ble(.delegate(.peerOffline(tokenA))))
    await store.receive(.transport(.interfaceDisconnected(idA))) { $0.transport.interfaces[idA] = nil }
    await store.receive(.delegate(.peerOffline(tokenA)))
    await store.receive(.transport(.stopMaintenance))
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
