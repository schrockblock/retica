import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Transfer-aware delivery, Task 7: the propagated copy counts as outstanding while its stamp is
// searched (the false "failed" of the proofs work, Amendment 3), and a copy larger than the node
// accepts is refused up front instead of failing after five tries.

private let dest = Data(repeating: 0xD5, count: 16)
private let pn = Data(repeating: 0xBB, count: 16)
private let pnLink = Data(repeating: 0xC0, count: 16)
private let small = Data("small-container".utf8)

private func note() -> LXMessage {
    LXMessage.create(source: Identity(), destinationHash: dest, timestamp: 1700000000.5,
                     title: Data("t".utf8), content: Data("both ways".utf8))
}

@MainActor
private func routerStore(_ state: LXMFRouter.State, _ clock: TestClock<Duration> = TestClock())
    -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

/// Drive the delivery copy (opportunistic, path known) to the retry that exhausts it, leaving the
/// store exhaustive just before that retry is received.
@MainActor
private func exhaustTheDeliveryCopy(_ store: TestStore<LXMFRouter.State, LXMFRouter.Action>,
                                    _ clock: TestClock<Duration>, _ m: LXMessage) async {
    for _ in 0..<(LXMFDelivery.maxAttempts - 1) {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    }
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive(.retryDue(messageHash: m.hash, leg: .delivery)) {
        $0.pendingDeliveries[.delivery(m.hash)] = nil
    }
}

@Test @MainActor func pnCopyPendingMarkerKeepsTheMessageAlive() async {
    let m = note()
    let clock = TestClock()
    var state = LXMFRouter.State()
    state.knownPaths.insert(dest)
    let store = routerStore(state, clock)
    await store.send(.send(message: m, desiredMethod: .opportunistic))
    await store.send(.propagatedCopyPending(messageHash: m.hash))
    await exhaustTheDeliveryCopy(store, clock, m)
    await store.send(.retryDue(messageHash: m.hash, leg: .delivery))   // probe: a stray deliveryFailed fails here
}

@Test @MainActor func pnCopyAbandonedMarkerFailsTheMessageOnce() async {
    let m = note()
    let clock = TestClock()
    var state = LXMFRouter.State()
    state.knownPaths.insert(dest)
    let store = routerStore(state, clock)
    await store.send(.send(message: m, desiredMethod: .opportunistic))
    await store.send(.propagatedCopyPending(messageHash: m.hash))
    await exhaustTheDeliveryCopy(store, clock, m)
    await store.send(.abandonPendingPropagatedCopies) {
        $0.pendingPropagatedCopies = []
    }
    await store.receive(.delegate(.deliveryFailed(messageHash: m.hash)))
    await store.send(.abandonPendingPropagatedCopies)                 // probe: nothing left, nothing again
}

@Test @MainActor func pnCopyArmingClearsTheMarker() async {
    let m = note()
    var state = LXMFRouter.State()
    state.outboundPropagationNode = pn
    state.directLinks[pn] = .active(linkID: pnLink)
    let store = routerStore(state)
    await store.send(.propagatedCopyPending(messageHash: m.hash))
    #expect(store.state.pendingPropagatedCopies == [m.hash])
    await store.send(.sendViaPropagation(message: m, propagationPacked: small))
    #expect(store.state.pendingPropagatedCopies.isEmpty)
    #expect(store.state.pendingDeliveries[.propagated(m.hash)] != nil)
}

@Test @MainActor func pnCopyRefusedReportsAndTheDeliveryCopyStillConfirms() async {
    let m = note()
    var state = LXMFRouter.State()
    state.knownPaths.insert(dest)
    let store = routerStore(state)
    await store.send(.send(message: m, desiredMethod: .opportunistic))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.propagatedCopyRefused(messageHash: m.hash, reason: .tooLargeForNode))
    await store.receive(.delegate(.propagationRefused(messageHash: m.hash, reason: .tooLargeForNode)))
    await store.send(.opportunisticDelivered(messageHash: m.hash)) {
        $0.pendingDeliveries[.delivery(m.hash)] = nil
        $0.succeededMessages.insert(m.hash)
    }
    await store.receive(.delegate(.deliveryConfirmed(messageHash: m.hash)))
}

@Test @MainActor func pnCopyCancelOutboundClearsTheMarker() async {
    let m = note()
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    await store.send(.propagatedCopyPending(messageHash: m.hash)) {
        $0.pendingPropagatedCopies = [m.hash]
    }
    await store.send(.cancelOutbound(messageHash: m.hash)) {
        $0.pendingPropagatedCopies = []
        $0.cancelledMessages.insert(m.hash)
    }
    await store.receive(.delegate(.deliveryCancelled(messageHash: m.hash)))
    await store.send(.propagatedCopyPending(messageHash: m.hash))    // a cancelled message is not re-marked
}

// MARK: - LXMFNode

@MainActor
private func pnNode(limitKB: Int, stampCost: Int) -> (TestStore<LXMFNode.State, LXMFNode.Action>, Identity) {
    let recipient = Identity()
    var state = LXMFNode.State(identity: Identity(),
                               endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    state.endpoint.transport.learned[dest] = LearnedDestination(
        identity: recipient, appData: nil, ratchet: nil, interfaceID: InterfaceID("tcp"),
        hops: 1, nextHop: nil, announceEmitted: 0)
    state.endpoint.transport.learned[pn] = LearnedDestination(
        identity: Identity(),
        appData: PNAnnounce(timebase: 0, nodeState: true, perTransferLimit: limitKB, perSyncLimit: limitKB,
                            targetStampCost: stampCost, stampCostFlexibility: 0, peeringCost: 0).packed,
        ratchet: nil, interfaceID: InterfaceID("tcp"), hops: 1, nextHop: nil, announceEmitted: 0)
    state.router.outboundPropagationNode = pn
    state.router.knownPaths.insert(dest)
    let store = TestStore(initialState: state) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return (store, recipient)
}

@Test @MainActor func pnCopyNodeRefusesAnOversizeMessageUpFront() async {
    let (store, _) = pnNode(limitKB: 1, stampCost: 4)
    let m = LXMessage.create(source: Identity(), destinationHash: dest, timestamp: 1700000000.5,
                             title: Data(), content: Data(repeating: 0x41, count: 2000))
    #expect(m.packed.count > 1000)
    await store.send(.sendMessage(message: m, alsoViaPropagation: true))
    await store.receive(.router(.propagatedCopyRefused(messageHash: m.hash, reason: .tooLargeForNode)))
    await store.receive(.delegate(.propagationRefused(messageHash: m.hash, reason: .tooLargeForNode)))
    #expect(store.state.router.pendingPropagatedCopies.isEmpty)      // no search was started for it
    #expect(store.state.router.outboundQueue[dest]?.count == 1)      // the delivery copy proceeds
}

/// Review Focus 7: every existing fixture announces `perTransferLimit: 0`. That is "unknown", not
/// "nothing fits": the copy is attempted, and marked pending while its stamp is searched.
@Test @MainActor func pnCopyNodeMarksTheCopyPendingWhileItsStampIsSearched() async {
    let (store, _) = pnNode(limitKB: 0, stampCost: 4)
    let m = note()
    await store.send(.sendMessage(message: m, alsoViaPropagation: true))
    #expect(store.state.router.pendingPropagatedCopies == [m.hash])
    await store.receive { if case let .router(.sendViaPropagation(sent, _)) = $0 { return sent.hash == m.hash }; return false }
    #expect(store.state.router.pendingPropagatedCopies.isEmpty)
    #expect(store.state.router.propagationQueue[pn]?.count == 1)
}

@Test @MainActor func pnCopyNodeAttemptsAMessageWithinTheLimit() async {
    let (store, _) = pnNode(limitKB: 1000, stampCost: 4)
    let m = note()
    await store.send(.sendMessage(message: m, alsoViaPropagation: true))
    await store.receive { if case let .router(.sendViaPropagation(sent, _)) = $0 { return sent.hash == m.hash }; return false }
}

@Test @MainActor func pnCopyNodeCancelPropagationStampsFailsTheMarkedCopy() async {
    let (store, _) = pnNode(limitKB: 0, stampCost: LXMFPropagation.maxPropagationStampCost)
    let m = note()
    await store.send(.sendMessage(message: m, alsoViaPropagation: true))
    #expect(store.state.router.pendingPropagatedCopies == [m.hash])
    await store.send(.cancelPropagationStamps)
    await store.receive(.router(.abandonPendingPropagatedCopies))
    #expect(store.state.router.pendingPropagatedCopies.isEmpty)
    #expect(store.state.router.pendingDeliveries[.delivery(m.hash)] != nil)   // so no failure is reported yet
}

@Test @MainActor func pnCopyNodeChangingThePropagationNodeFailsTheMarkedCopy() async {
    let (store, _) = pnNode(limitKB: 0, stampCost: LXMFPropagation.maxPropagationStampCost)
    let m = note()
    await store.send(.sendMessage(message: m, alsoViaPropagation: true))
    await store.send(.setPropagationNode(destinationHash: Data(repeating: 0xC1, count: 16)))
    await store.receive(.router(.abandonPendingPropagatedCopies))
    #expect(store.state.router.pendingPropagatedCopies.isEmpty)
}

/// Review finding (Task 7, fix round 1): a resend of an already-cancelled hash must never mark a
/// propagated copy pending — the router holds no delivery copy for it either, so marking it would
/// make `hasOutboundState` report phantom work and a later abandon would `fail` it into a stray
/// `deliveryFailed` with no preceding send.
@Test @MainActor func pnCopyResendOfACancelledMessageNeverMarksTheCopy() async {
    let (store, _) = pnNode(limitKB: 0, stampCost: LXMFPropagation.maxPropagationStampCost)
    let m = note()
    await store.send(.cancelOutbound(messageHash: m.hash))
    #expect(store.state.router.cancelledMessages.contains(m.hash))
    await store.send(.sendMessage(message: m, alsoViaPropagation: true))
    #expect(store.state.router.pendingPropagatedCopies.isEmpty)
    await store.send(.cancelPropagationStamps)
    store.exhaustivity = .on
    await store.send(.cancelDeliveryStamps)   // probe: a stray deliveryFailed/deliveryCancelled fails here
}
