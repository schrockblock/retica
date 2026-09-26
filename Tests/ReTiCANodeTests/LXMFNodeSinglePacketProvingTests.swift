import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Reference `LXMRouter.delivery_packet` (LXMRouter.py:1926-1927) calls `packet.prove()` as its FIRST
// statement for opportunistic packets too, before unpacking and before the duplicate check.
//
// Depth order these tests rely on (TCA runs `.send` effects breadth-first): the LXMFNode reduction
// of `messageReceived` returns `.merge(prove, router.received)`, so `.endpoint(.proveSinglePacket)`
// is received BEFORE `.router(.received)`, and `.endpoint(.transport(.proveSingle))` after both.

@MainActor
private func makeNode(_ identity: Identity) -> TestStore<LXMFNode.State, LXMFNode.Action> {
    let store = TestStore(
        initialState: LXMFNode.State(
            identity: identity,
            endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    ) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

/// A packet for OUR delivery destination is proved on its arrival interface, then routed. The
/// payload here is not a valid LXMF message: LXMF-level malformation is still proved, as in
/// reference, where `packet.prove()` precedes unpacking.
@MainActor @Test func inboundProvingProvesOpportunisticDeliveryBeforeRouting() async throws {
    let identity = Identity()
    let store = makeNode(identity)
    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)
    let ours = try #require(store.state.deliveryDestinationHash)
    let packetHash = Data(repeating: 0xE1, count: 32)
    let ifID = InterfaceID("tcp")
    let garbage = Data("not an lxmf message".utf8)

    await store.send(.endpoint(.delegate(.messageReceived(destinationHash: ours, plaintext: garbage,
                                                          packetHash: packetHash, interfaceID: ifID))))
    await store.receive(.endpoint(.proveSinglePacket(packetHash: packetHash, interfaceID: ifID,
                                                     identity: identity)))
    await store.receive(.router(.received(method: .opportunistic, destinationHash: ours, data: garbage)))
}

/// The proof goes out BEFORE the router's `seen` dedup, so a resend of a message we already
/// delivered is proved again — otherwise a sender whose first proof was lost never learns.
@MainActor @Test func inboundProvingProvesADuplicateAgain() async throws {
    let identity = Identity()
    let store = makeNode(identity)
    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)
    let ours = try #require(store.state.deliveryDestinationHash)
    let msg = LXMessage.create(source: Identity(), destinationHash: ours, timestamp: 1700000000.5,
                               title: Data("t".utf8), content: Data("twice".utf8))
    let first = Data(repeating: 0xE4, count: 32)
    let second = Data(repeating: 0xE5, count: 32)   // a resend is a new packet with a new hash
    let ifID = InterfaceID("tcp")

    await store.send(.endpoint(.delegate(.messageReceived(destinationHash: ours, plaintext: msg.opportunisticPayload,
                                                          packetHash: first, interfaceID: ifID))))
    await store.receive(.endpoint(.proveSinglePacket(packetHash: first, interfaceID: ifID, identity: identity)))
    await store.receive { if case .delegate(.messageReceived) = $0 { return true }; return false }

    await store.send(.endpoint(.delegate(.messageReceived(destinationHash: ours, plaintext: msg.opportunisticPayload,
                                                          packetHash: second, interfaceID: ifID))))
    await store.receive(.endpoint(.proveSinglePacket(packetHash: second, interfaceID: ifID, identity: identity)))
    await store.receive(.router(.delegate(.duplicateDropped(hash: msg.hash))))
}

/// A packet for any other local destination is routed but NOT proved.
@MainActor @Test func inboundProvingIgnoresPacketsForOtherDestinations() async {
    let store = makeNode(Identity())
    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)
    let other = Data(repeating: 0xCC, count: 16)
    let payload = Data("x".utf8)
    store.exhaustivity = .on   // from here, a stray proveSinglePacket is an unexpected action
    await store.send(.endpoint(.delegate(.messageReceived(destinationHash: other, plaintext: payload,
                                                          packetHash: Data(repeating: 0xE2, count: 32),
                                                          interfaceID: InterfaceID("tcp")))))
    await store.receive(.router(.received(method: .opportunistic, destinationHash: other, data: payload)))
}

/// Before `registerDelivery` nothing is ours, so nothing is proved — even for the hash our
/// delivery destination WOULD have.
@MainActor @Test func inboundProvingNeedsARegisteredDeliveryDestination() async {
    let identity = Identity()
    let store = makeNode(identity)
    let wouldBe = LXMessage.deliveryHash(identityHash: identity.hash)
    let payload = Data("x".utf8)
    store.exhaustivity = .on
    await store.send(.endpoint(.delegate(.messageReceived(destinationHash: wouldBe, plaintext: payload,
                                                          packetHash: Data(repeating: 0xE3, count: 32),
                                                          interfaceID: InterfaceID("tcp")))))
    await store.receive(.router(.received(method: .opportunistic, destinationHash: wouldBe, data: payload)))
}
