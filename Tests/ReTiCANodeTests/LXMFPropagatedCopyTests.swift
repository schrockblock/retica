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
    await store.send(.abandonPendingPropagatedCopies(stillSearching: [])) {
        $0.pendingPropagatedCopies = []
    }
    await store.receive(.delegate(.deliveryFailed(messageHash: m.hash)))
    await store.send(.abandonPendingPropagatedCopies(stillSearching: []))                 // probe: nothing left, nothing again
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

/// An exhaustive no-op: a conclusion on a link we have no transfer on changes nothing.
@MainActor
private let pnProbe = LXMFNode.Action.endpoint(.delegate(.resourceConcluded(linkID: Data(repeating: 0x99, count: 16),
                                                                            resourceHash: Data(repeating: 0x11, count: 32))))

@MainActor
private func pnNode(limitKB: Int, stampCost: Int, clock: TestClock<Duration> = TestClock(),
                    deliveryStampCost: Int? = nil) -> (TestStore<LXMFNode.State, LXMFNode.Action>, Identity) {
    let recipient = Identity()
    var state = LXMFNode.State(identity: Identity(),
                               endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    if let deliveryStampCost {
        state.learnedPeers[dest] = LXMFNode.LearnedPeer(displayName: nil, stampCost: deliveryStampCost,
                                                        supportsCompression: false,
                                                        learnedAt: Date(timeIntervalSince1970: 1700000000))
    }
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
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return (store, recipient)
}

/// Retry the (opportunistic, path known) delivery copy until it hands off to the propagation node:
/// the propagated copy of a `fallbackToPropagation` send starts there, not at the send.
@MainActor
private func stallTheDeliveryCopy(_ store: TestStore<LXMFNode.State, LXMFNode.Action>,
                                  _ clock: TestClock<Duration>, _ m: LXMessage) async {
    #expect(store.state.router.pendingPropagatedCopies.isEmpty)
    for _ in 0..<(LXMFDelivery.propagationFallbackAfterAttempts - 1) {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    }
    await store.receive(.router(.delegate(.propagationFallbackDue(messageHash: m.hash))))
}

@Test @MainActor func pnCopyNodeRefusesAnOversizeMessageUpFront() async {
    let (store, _) = pnNode(limitKB: 1, stampCost: 4)
    let m = LXMessage.create(source: Identity(), destinationHash: dest, timestamp: 1700000000.5,
                             title: Data(), content: Data(repeating: 0x41, count: 2000))
    #expect(m.packed.count > 1000)
    await store.send(.sendMessage(message: m, fallbackToPropagation: true))
    await store.receive(.router(.propagatedCopyRefused(messageHash: m.hash, reason: .tooLargeForNode)))
    await store.receive(.delegate(.propagationRefused(messageHash: m.hash, reason: .tooLargeForNode)))
    #expect(store.state.router.pendingPropagatedCopies.isEmpty)      // no search was started for it
    #expect(store.state.router.outboundQueue[dest]?.count == 1)      // the delivery copy proceeds
}

// MARK: - The propagated copy carries the recipient's delivery stamp
//
// A recipient enforcing stamps checks them on propagated messages too (`lxmf_propagation` passes
// `no_stamp_enforcement=False` for all but paper messages, LXMRouter.py:2828-2861, LXMF 1.3.0), and
// MeshChatX enforces by default. An unstamped copy reaches the node, is accepted, is synced, and is
// then dropped. The assertions open the copy as the recipient would.

/// Small enough that real searches take well under a second.
private let cheapCost = 2
/// MeshChatX's default. High enough that random bytes pass 1 time in 256: at `cheapCost` they pass 1
/// in 4, and a garbage stamp survived these tests that way.
private let deliveryCost = 8

/// Wait for the copy handed to the router and open it with the recipient's key.
@MainActor
private func openedPropagatedCopy(_ store: TestStore<LXMFNode.State, LXMFNode.Action>, _ recipient: Identity,
                                  of hash: Data) async throws -> LXMessage {
    let packed = LockIsolated<Data?>(nil)
    await store.receive({ action in
        guard case let .router(.sendViaPropagation(sent, bytes)) = action, sent.hash == hash else { return false }
        packed.setValue(bytes)
        return true
    }, timeout: .seconds(30))
    let bytes = try #require(packed.value)
    let container = try #require(LXMFPropagation.parseContainer(bytes))
    let entry = try #require(container.entries.first)
    #expect(LXStamper.validatePnStamp(transientData: entry, targetCost: cheapCost) != nil)
    return try #require(LXMFPropagation.open(lxmfData: entry, recipientIdentity: recipient))
}

@Test @MainActor func aFallbackCopyCarriesTheDeliveryStampOfTheDeliveryCopy() async throws {
    let clock = TestClock()
    let (store, recipient) = pnNode(limitKB: 0, stampCost: cheapCost, clock: clock, deliveryStampCost: deliveryCost)
    let m = note()
    await store.send(.sendMessage(message: m, fallbackToPropagation: true))
    let handed = LockIsolated<LXMessage?>(nil)
    await store.receive({ action in
        guard case let .router(.send(sent, _)) = action else { return false }
        handed.setValue(sent)
        return true
    }, timeout: .seconds(30))
    await stallTheDeliveryCopy(store, clock, m)

    let opened = try await openedPropagatedCopy(store, recipient, of: m.hash)
    #expect(opened.validateStamp(targetCost: deliveryCost))
    // The search is not repeated: at a high cost that would be minutes more on a phone.
    #expect(opened.stamp == handed.value?.stamp)
}

/// The delivery copy went out before the peer's cost was known, and the cost arrived afterwards.
@Test @MainActor func aFallbackCopyIsStampedWhenTheCostWasLearnedAfterTheDeliveryCopyLeft() async throws {
    let clock = TestClock()
    let (store, recipient) = pnNode(limitKB: 0, stampCost: cheapCost, clock: clock)
    let m = note()
    await store.send(.sendMessage(message: m, fallbackToPropagation: true))
    await store.send(.rehydrateLearnedPeers([dest: LXMFNode.LearnedPeer(
        displayName: nil, stampCost: deliveryCost, supportsCompression: false,
        learnedAt: Date(timeIntervalSince1970: 1700000000))]))
    await stallTheDeliveryCopy(store, clock, m)

    let opened = try await openedPropagatedCopy(store, recipient, of: m.hash)
    #expect(opened.validateStamp(targetCost: deliveryCost))
}

@Test @MainActor func aFallbackCopyStaysUnstampedWhenThePeerAsksForNoStamp() async throws {
    let clock = TestClock()
    let (store, recipient) = pnNode(limitKB: 0, stampCost: cheapCost, clock: clock)
    let m = note()
    await store.send(.sendMessage(message: m, fallbackToPropagation: true))
    await stallTheDeliveryCopy(store, clock, m)
    let opened = try await openedPropagatedCopy(store, recipient, of: m.hash)
    #expect(opened.stamp == nil)
}

/// Refusing to do the work must not refuse to send, as on the delivery path.
@Test @MainActor func aFallbackCopyGoesOutUnstampedWhenThePeersCostIsAboveTheCeiling() async throws {
    let clock = TestClock()
    let (store, recipient) = pnNode(limitKB: 0, stampCost: cheapCost, clock: clock,
                                    deliveryStampCost: LXMFNode.maxDeliveryStampCost + 1)
    let m = note()
    await store.send(.sendMessage(message: m, fallbackToPropagation: true))
    await stallTheDeliveryCopy(store, clock, m)
    let opened = try await openedPropagatedCopy(store, recipient, of: m.hash)
    #expect(opened.stamp == nil)
}

@Test @MainActor func sendViaPropagationCarriesADeliveryStamp() async throws {
    let (store, recipient) = pnNode(limitKB: 0, stampCost: cheapCost, deliveryStampCost: deliveryCost)
    await store.send(.sendViaPropagation(destinationHash: dest, title: Data("t".utf8), content: Data("c".utf8)))
    let packed = LockIsolated<Data?>(nil)
    await store.receive({ action in
        guard case let .router(.sendViaPropagation(_, bytes)) = action else { return false }
        packed.setValue(bytes)
        return true
    }, timeout: .seconds(30))
    let bytes = try #require(packed.value)
    let container = try #require(LXMFPropagation.parseContainer(bytes))
    let entry = try #require(container.entries.first)
    let opened = try #require(LXMFPropagation.open(lxmfData: entry, recipientIdentity: recipient))
    #expect(opened.validateStamp(targetCost: deliveryCost))
}

/// A delivery stamp searched for the copy is part of that copy's work, so the same lever stops it.
/// At the ceiling it runs for minutes, so the store can only finish because it was cancelled.
@Test(.timeLimit(.minutes(1))) @MainActor func cancelPropagationStampsStopsADeliveryStampSearchForTheCopy() async {
    let clock = TestClock()
    let (store, _) = pnNode(limitKB: 0, stampCost: cheapCost, clock: clock)
    let m = note()
    await store.send(.sendMessage(message: m, fallbackToPropagation: true))
    await store.send(.rehydrateLearnedPeers([dest: LXMFNode.LearnedPeer(
        displayName: nil, stampCost: LXMFNode.maxDeliveryStampCost, supportsCompression: false,
        learnedAt: Date(timeIntervalSince1970: 1700000000))]))
    await stallTheDeliveryCopy(store, clock, m)
    await store.send(.cancelPropagationStamps)
    await store.receive(.router(.abandonPendingPropagatedCopies(stillSearching: [])))
    await store.send(.router(.opportunisticDelivered(messageHash: m.hash)))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on       // with exhaustivity off, a `finish` that times out reports nothing
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds * LXMFDelivery.maxAttempts))
    await store.finish(timeout: .seconds(10))
}

/// Review Focus 7: every existing fixture announces `perTransferLimit: 0`. That is "unknown", not
/// "nothing fits": the copy is attempted, and marked pending while its stamp is searched.
@Test @MainActor func pnCopyNodeMarksTheCopyPendingWhileItsStampIsSearched() async {
    let clock = TestClock()
    let (store, _) = pnNode(limitKB: 0, stampCost: 4, clock: clock)
    let m = note()
    await store.send(.sendMessage(message: m, fallbackToPropagation: true))
    await stallTheDeliveryCopy(store, clock, m)
    #expect(store.state.router.pendingPropagatedCopies == [m.hash])
    await store.receive { if case let .router(.sendViaPropagation(sent, _)) = $0 { return sent.hash == m.hash }; return false }
    #expect(store.state.router.pendingPropagatedCopies.isEmpty)
    #expect(store.state.router.propagationQueue[pn]?.count == 1)
}

@Test @MainActor func pnCopyNodeAttemptsAMessageWithinTheLimit() async {
    let clock = TestClock()
    let (store, _) = pnNode(limitKB: 1000, stampCost: 4, clock: clock)
    let m = note()
    await store.send(.sendMessage(message: m, fallbackToPropagation: true))
    await stallTheDeliveryCopy(store, clock, m)
    await store.receive { if case let .router(.sendViaPropagation(sent, _)) = $0 { return sent.hash == m.hash }; return false }
}

@Test @MainActor func pnCopyNodeCancelPropagationStampsFailsTheMarkedCopy() async {
    let clock = TestClock()
    let (store, _) = pnNode(limitKB: 0, stampCost: LXMFPropagation.maxPropagationStampCost, clock: clock)
    let m = note()
    await store.send(.sendMessage(message: m, fallbackToPropagation: true))
    await stallTheDeliveryCopy(store, clock, m)
    #expect(store.state.router.pendingPropagatedCopies == [m.hash])
    await store.send(.cancelPropagationStamps)
    await store.receive(.router(.abandonPendingPropagatedCopies(stillSearching: [])))
    #expect(store.state.router.pendingPropagatedCopies.isEmpty)
    #expect(store.state.router.pendingDeliveries[.delivery(m.hash)] != nil)   // so no failure is reported yet
}

@Test @MainActor func pnCopyNodeChangingThePropagationNodeFailsTheMarkedCopy() async {
    let clock = TestClock()
    let (store, _) = pnNode(limitKB: 0, stampCost: LXMFPropagation.maxPropagationStampCost, clock: clock)
    let m = note()
    await store.send(.sendMessage(message: m, fallbackToPropagation: true))
    await stallTheDeliveryCopy(store, clock, m)
    await store.send(.setPropagationNode(destinationHash: Data(repeating: 0xC1, count: 16)))
    await store.receive(.router(.abandonPendingPropagatedCopies(stillSearching: [])))
    #expect(store.state.router.pendingPropagatedCopies.isEmpty)
}

/// The delivery copy confirms while its fallback's stamp is searched: the search is stopped, so the
/// copy can never be handed over late. At cost 20 the search runs for minutes, so the store can only
/// finish because it was cancelled. (The router's half: `successDropsAPropagatedCopyStillInItsStampSearch`.)
@Test(.timeLimit(.minutes(1))) @MainActor func successStopsTheFallbacksStampSearch() async {
    let clock = TestClock()
    let (store, _) = pnNode(limitKB: 0, stampCost: LXMFPropagation.maxPropagationStampCost, clock: clock)
    let m = note()
    await store.send(.sendMessage(message: m, fallbackToPropagation: true))
    await stallTheDeliveryCopy(store, clock, m)
    await store.send(.router(.opportunisticDelivered(messageHash: m.hash)))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: m.hash)))
    #expect(store.state.router.pendingPropagatedCopies.isEmpty)
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds * LXMFDelivery.maxAttempts))
    await store.finish(timeout: .seconds(10))
}

/// Final review F2: the app deliberately re-sending a message it cancelled earlier is a FRESH send.
/// The node forgets the cancel first, so the propagated copy is marked a fallback and the delivery
/// copy is armed — before, both were swallowed by the cancelled-message guards and the row stayed
/// on "sending" for good. (A LATE hand-over from the cancelled attempt is still refused by the
/// router: `routerCancelLateCopyOfACancelledMessageArmsNothing`.)
@Test @MainActor func pnCopyResendOfACancelledMessageIsAFreshSend() async {
    let (store, _) = pnNode(limitKB: 0, stampCost: LXMFPropagation.maxPropagationStampCost)
    let m = note()
    await store.send(.cancelOutbound(messageHash: m.hash))
    #expect(store.state.router.cancelledMessages.contains(m.hash))
    await store.send(.sendMessage(message: m, fallbackToPropagation: true))
    #expect(!store.state.router.cancelledMessages.contains(m.hash))
    await store.receive(.router(.markFallbackEligible(messageHash: m.hash)))
    await store.receive(.router(.send(message: m, desiredMethod: .opportunistic)))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.router.fallbackEligible == [m.hash])
    #expect(store.state.router.pendingDeliveries[.delivery(m.hash)] != nil)   // the delivery copy is armed
}

/// Final review F3: abandoning the propagated copies while a message's DELIVERY copy is still in
/// its delivery-stamp search (so the router holds nothing for it) must not fail the message — that
/// copy can still succeed, and did: failing here gave `deliveryFailed` and then a confirmation.
@Test(.timeLimit(.minutes(1))) @MainActor func pnCopyAbandonWhileTheDeliveryStampIsSearchedDoesNotFailTheMessage() async {
    // The delivery stamp at cost 20 cannot finish during the test, so its search is deterministically
    // in flight when the abandon lands. Its eventual hand-over is then played by sending the
    // `.router(.send)` it would deliver. A fallback cannot start while that search runs, so the
    // pending propagated copy (from an earlier attempt's hand-off, say) is marked directly.
    let (store, _) = pnNode(limitKB: 0, stampCost: LXMFPropagation.maxPropagationStampCost,
                            deliveryStampCost: LXMFNode.maxDeliveryStampCost)
    let m = note()
    await store.send(.sendMessage(message: m, fallbackToPropagation: false))
    await store.send(.router(.propagatedCopyPending(messageHash: m.hash)))
    #expect(store.state.inFlightDeliveryStamps == [m.hash])
    #expect(store.state.router.pendingPropagatedCopies == [m.hash])
    store.exhaustivity = .on
    await store.send(.cancelPropagationStamps)
    await store.receive(.router(.abandonPendingPropagatedCopies(stillSearching: [m.hash]))) {
        $0.router.pendingPropagatedCopies = []
    }
    await store.send(pnProbe)                                    // no deliveryFailed was reported
    store.exhaustivity = .off
    // The delivery copy is handed over and confirms: the message's one terminal outcome.
    await store.send(.router(.send(message: m, desiredMethod: .opportunistic)))
    #expect(store.state.inFlightDeliveryStamps.isEmpty)
    await store.send(.router(.opportunisticDelivered(messageHash: m.hash)))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: m.hash)))
    await store.send(.cancelDeliveryStamps)                      // stop the real search (nothing to fail now)
    store.exhaustivity = .on
    await store.send(pnProbe)                                    // and it failed nothing
}
