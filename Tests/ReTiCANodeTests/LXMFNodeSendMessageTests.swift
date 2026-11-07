import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let pnHash = Data(repeating: 0xC0, count: 16)

@MainActor
private func makeNode(identity: Identity, seedLearned: Identity?, dest: Data, pn: Data?,
                      pnStampCost: Int = 4, limitKB: Int = 0, deliveryStampCost: Int? = nil,
                      _ configure: (inout LXMFNode.State) -> Void = { _ in })
    -> TestStore<LXMFNode.State, LXMFNode.Action> {
    var ep = TransportEndpoint.State.tcp(TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    if let r = seedLearned {
        ep.transport.learned[dest] = LearnedDestination(
            identity: r, appData: nil, ratchet: nil, interfaceID: InterfaceID("tcp"),
            hops: 1, nextHop: nil, announceEmitted: 0)
    }
    // Seed the PN with targetStampCost:4 so the async PoW of the propagated copy is fast.
    if let pn {
        ep.transport.learned[pn] = LearnedDestination(
            identity: Identity(),
            appData: PNAnnounce(timebase: 0, nodeState: true, perTransferLimit: limitKB, perSyncLimit: limitKB,
                                targetStampCost: pnStampCost, stampCostFlexibility: 0, peeringCost: 0).packed,
            ratchet: nil, interfaceID: InterfaceID("tcp"), hops: 1, nextHop: nil, announceEmitted: 0)
    }
    var node = LXMFNode.State(identity: identity, endpoint: ep)
    // Seed the router so the opportunistic send can arm, and (when set) propagation can arm.
    node.router.knownIdentities[dest] = seedLearned ?? Identity()
    node.router.knownPaths.insert(dest)
    if let pn { node.router.outboundPropagationNode = pn }
    if let deliveryStampCost {
        node.learnedPeers[dest] = LXMFNode.LearnedPeer(displayName: nil, stampCost: deliveryStampCost,
                                                       supportsCompression: false,
                                                       learnedAt: Date(timeIntervalSince1970: 1700000000))
    }
    configure(&node)
    let store = TestStore(initialState: node) { LXMFNode() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.continuousClock = TestClock()
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } },
                                         send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

@MainActor @Test func sendMessageFlagFalseSendsOpportunisticOnly() async {
    let me = Identity(); let recipient = Identity()
    let dest = Data(repeating: 0xA1, count: 16)
    let store = makeNode(identity: me, seedLearned: recipient, dest: dest, pn: pnHash)
    let msg = LXMessage.create(source: me, destinationHash: dest, timestamp: 1700000000,
                               title: Data(), content: Data("x".utf8))
    await store.send(.sendMessage(message: msg, fallbackToPropagation: false))
    await store.receive { if case let .router(.send(m, method)) = $0 { return m == msg && method == .opportunistic }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.router.propagationQueue.isEmpty)
}

/// Spec A2: the delivery copy goes alone. The propagated copy is only remembered, and the router is
/// told it is a fallback BEFORE it receives the delivery copy (it may give up inside `.send`).
@MainActor @Test func sendMessageFallbackSendsDirectOnlyAtFirst() async {
    let me = Identity(); let recipient = Identity()
    let dest = Data(repeating: 0xA2, count: 16)
    let store = makeNode(identity: me, seedLearned: recipient, dest: dest, pn: pnHash)
    let msg = LXMessage.create(source: me, destinationHash: dest, timestamp: 1700000000,
                               title: Data(), content: Data("x".utf8))
    await store.send(.sendMessage(message: msg, fallbackToPropagation: true))
    #expect(store.state.router.pendingPropagatedCopies.isEmpty)       // no stamp search was started
    #expect(store.state.pendingFallbacks[msg.hash] == msg)
    // In this order: receiving `.send` first would skip past it and fail the second receive.
    await store.receive(.router(.markFallbackEligible(messageHash: msg.hash)))
    await store.receive { if case let .router(.send(m, method)) = $0 { return m == msg && method == .opportunistic }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.router.fallbackEligible == [msg.hash])
    #expect(store.state.router.propagationQueue.isEmpty)
}

@MainActor @Test func sendMessageFallbackPacksWhenDue() async {
    let me = Identity(); let recipient = Identity()
    let dest = Data(repeating: 0xA4, count: 16)
    let store = makeNode(identity: me, seedLearned: recipient, dest: dest, pn: pnHash)
    let msg = LXMessage.create(source: me, destinationHash: dest, timestamp: 1700000000,
                               title: Data(), content: Data("x".utf8))
    await store.send(.sendMessage(message: msg, fallbackToPropagation: true))
    #expect(store.state.router.pendingPropagatedCopies.isEmpty)       // so the copy below is the due one
    await store.skipReceivedActions(strict: false)
    // The router's hand-off, played directly.
    await store.send(.router(.delegate(.propagationFallbackDue(messageHash: msg.hash))))
    #expect(store.state.pendingFallbacks.isEmpty)
    await store.receive { if case let .router(.sendViaPropagation(m, _)) = $0 { return m == msg }; return false }
    #expect(store.state.router.propagationQueue[pnHash]?.count == 1)
}

@MainActor @Test func sendMessageFallbackUnknownIdentityNeverFallsBack() async {
    let me = Identity()
    let dest = Data(repeating: 0xA3, count: 16)
    // NOTE: seedLearned nil → transport.learned has no identity for dest → no propagated copy.
    let store = makeNode(identity: me, seedLearned: nil, dest: dest, pn: pnHash)
    let msg = LXMessage.create(source: me, destinationHash: dest, timestamp: 1700000000,
                               title: Data(), content: Data("x".utf8))
    await store.send(.sendMessage(message: msg, fallbackToPropagation: true))
    await store.skipReceivedActions(strict: false)
    // With no path it waits for the peer's cost, and that decision has already been made by then.
    #expect(store.state.waitingForPeerCost[dest]?.map(\.message) == [msg])
    #expect(store.state.pendingFallbacks.isEmpty)
    #expect(store.state.router.fallbackEligible.isEmpty)
    #expect(store.state.router.propagationQueue.isEmpty)
}

/// Spec §6: a copy the node would refuse is refused at send time, and never becomes a fallback.
@MainActor @Test func sendMessageFallbackTooLargeRefusesUpFront() async {
    let me = Identity(); let recipient = Identity()
    let dest = Data(repeating: 0xA5, count: 16)
    let store = makeNode(identity: me, seedLearned: recipient, dest: dest, pn: pnHash, limitKB: 1)
    let msg = LXMessage.create(source: me, destinationHash: dest, timestamp: 1700000000,
                               title: Data(), content: Data(repeating: 0x41, count: 2000))
    #expect(msg.packed.count > 1000)
    await store.send(.sendMessage(message: msg, fallbackToPropagation: true))
    await store.receive(.router(.propagatedCopyRefused(messageHash: msg.hash, reason: .tooLargeForNode)))
    await store.receive(.delegate(.propagationRefused(messageHash: msg.hash, reason: .tooLargeForNode)))
    #expect(store.state.pendingFallbacks.isEmpty)
    #expect(store.state.router.fallbackEligible.isEmpty)
}

@MainActor @Test func sendMessageFallbackDroppedOnConfirm() async {
    let me = Identity(); let recipient = Identity()
    let dest = Data(repeating: 0xA6, count: 16)
    let store = makeNode(identity: me, seedLearned: recipient, dest: dest, pn: pnHash)
    let msg = LXMessage.create(source: me, destinationHash: dest, timestamp: 1700000000,
                               title: Data(), content: Data("x".utf8))
    await store.send(.sendMessage(message: msg, fallbackToPropagation: true))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.pendingFallbacks[msg.hash] == msg)
    await store.send(.router(.opportunisticDelivered(messageHash: msg.hash)))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    #expect(store.state.pendingFallbacks.isEmpty)
}

/// `.cancelDeliveryStamps` fails the message itself, past the router's `fail`: the fallback it was
/// waiting on must go with it, here and in the router, or a later hand-off would revive the message.
@MainActor @Test(.timeLimit(.minutes(1))) func sendMessageFallbackDroppedWhenTheDeliveryStampIsCancelled() async {
    let me = Identity(); let recipient = Identity()
    let dest = Data(repeating: 0xA7, count: 16)
    let store = makeNode(identity: me, seedLearned: recipient, dest: dest, pn: pnHash,
                         deliveryStampCost: LXMFNode.maxDeliveryStampCost)
    let msg = LXMessage.create(source: me, destinationHash: dest, timestamp: 1700000000,
                               title: Data(), content: Data("x".utf8))
    await store.send(.sendMessage(message: msg, fallbackToPropagation: true))
    await store.receive(.router(.markFallbackEligible(messageHash: msg.hash)))
    #expect(store.state.inFlightDeliveryStamps == [msg.hash])
    await store.send(.cancelDeliveryStamps)
    await store.receive(.delegate(.deliveryFailed(messageHash: msg.hash)))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.pendingFallbacks.isEmpty)
    #expect(store.state.router.fallbackEligible.isEmpty)
}

/// The router counts the hand-off as a pending propagated copy; when the node has no message to
/// pack for it, that copy is failed through the router so the message still ends.
@MainActor @Test func sendMessageFallbackDueForAMissingMessageFailsTheCopy() async {
    let me = Identity()
    let dest = Data(repeating: 0xA8, count: 16)
    let gone = Data(repeating: 0x5A, count: 32)
    let store = makeNode(identity: me, seedLearned: Identity(), dest: dest, pn: pnHash) { node in
        node.router.pendingPropagatedCopies = [gone]            // the delivery copy already failed
    }
    await store.send(.router(.delegate(.propagationFallbackDue(messageHash: gone))))
    await store.receive(.router(.propagatedCopyFailed(messageHash: gone)))
    await store.receive(.delegate(.deliveryFailed(messageHash: gone)))
    #expect(store.state.router.pendingPropagatedCopies.isEmpty)
}

/// The same when the copy can no longer be packed: here the node now advertises a cost we refuse.
@MainActor @Test func sendMessageFallbackDueThatCannotBePackedFailsTheCopy() async {
    let me = Identity(); let recipient = Identity()
    let dest = Data(repeating: 0xA9, count: 16)
    let msg = LXMessage.create(source: me, destinationHash: dest, timestamp: 1700000000,
                               title: Data(), content: Data("x".utf8))
    let store = makeNode(identity: me, seedLearned: recipient, dest: dest, pn: pnHash, pnStampCost: 64) { node in
        node.pendingFallbacks[msg.hash] = msg
        node.router.pendingPropagatedCopies = [msg.hash]
    }
    await store.send(.router(.delegate(.propagationFallbackDue(messageHash: msg.hash))))
    #expect(store.state.pendingFallbacks.isEmpty)
    await store.receive(.router(.propagatedCopyFailed(messageHash: msg.hash)))
    await store.receive(.delegate(.deliveryFailed(messageHash: msg.hash)))
}
