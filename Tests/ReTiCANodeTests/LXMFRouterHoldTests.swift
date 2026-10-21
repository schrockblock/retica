import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

private let pn = Data(repeating: 0xB7, count: 16)
private let link = Data(repeating: 0xD1, count: 16)

private func makeMessage() -> LXMessage {
    LXMessage.create(source: Identity(),
                     destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                     timestamp: 1700000000.5, title: Data("t".utf8), content: Data("held".utf8))
}

/// A known path to `recipient`, so an opportunistic copy resends on every retry (10 s apart).
private func pathTo(_ recipient: Data) -> LXMFRouter.State {
    var state = LXMFRouter.State()
    state.knownPaths.insert(recipient)
    return state
}

@MainActor
private func makeStore(_ state: LXMFRouter.State, clock: TestClock<Duration>) -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    TestStore(initialState: state) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
}

/// An opportunistic send on its first attempt, then the hold. The store is exhaustive.
@MainActor
private func heldOpportunisticSend(_ msg: LXMessage, clock: TestClock<Duration>) async -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    let h = msg.hash
    let store = makeStore(pathTo(msg.destinationHash), clock: clock)
    await store.send(.send(message: msg, desiredMethod: .opportunistic)) {
        $0.pendingDeliveries[.delivery(h)] = LXMFRouter.PendingDelivery(
            resend: .opportunistic(destinationHash: msg.destinationHash, payload: msg.opportunisticPayload), attempts: 1)
    }
    await store.receive(.delegate(.sendOpportunistic(destinationHash: msg.destinationHash,
                                                     payload: msg.opportunisticPayload, messageHash: h)))
    await store.send(.setHold(true)) { $0.held = true }
    return store
}

/// Spec Amendment A3: while held, each retry re-arms for the same wait, counts nothing and sends
/// nothing — two minutes is well past the five-attempt budget.
@Test @MainActor func holdStopsAttemptsCounting() async {
    let msg = makeMessage()
    let h = msg.hash
    let clock = TestClock()
    let store = await heldOpportunisticSend(msg, clock: clock)
    for _ in 0..<12 {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
        // Exhaustive: a `sendOpportunistic` or `deliveryFailed` would be unexpected.
        await store.receive(.retryDue(messageHash: h, leg: .delivery))
    }
    #expect(store.state.pendingDeliveries[.delivery(h)]?.attempts == 1)
    store.exhaustivity = .off   // the held retry timer runs on by design
}

/// The release retries at once, from the stored attempt count: the copy keeps its remaining four.
@Test @MainActor func holdReleaseResumesRetries() async {
    let msg = makeMessage()
    let h = msg.hash
    let clock = TestClock()
    let store = await heldOpportunisticSend(msg, clock: clock)
    store.exhaustivity = .off
    await clock.advance(by: .seconds(60))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.setHold(false)) { $0.held = false }
    // No clock advance: the release itself fires the retry.
    await store.receive(.retryDue(messageHash: h, leg: .delivery)) {
        $0.pendingDeliveries[.delivery(h)]?.attempts = 2
    }
    await store.receive(.delegate(.sendOpportunistic(destinationHash: msg.destinationHash,
                                                     payload: msg.opportunisticPayload, messageHash: h)))
    store.exhaustivity = .off
    for _ in 0..<(LXMFDelivery.maxAttempts - 2) {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.pendingDeliveries[.delivery(h)]?.attempts == LXMFDelivery.maxAttempts)
    store.exhaustivity = .on
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive(.retryDue(messageHash: h, leg: .delivery)) {
        $0.pendingDeliveries[.delivery(h)] = nil
    }
    await store.receive(.delegate(.deliveryFailed(messageHash: h)))
}

/// A propagated copy handed over while held queues for the node's link without asking for it. The
/// establishment timeouts that reach the router as closes count nothing, so it never gives up.
@Test @MainActor func holdDefersPropagatedCopyEstablishment() async {
    let msg = makeMessage()
    let h = msg.hash
    let packed = Data("container".utf8)
    var state = pathTo(pn)
    state.outboundPropagationNode = pn
    state.held = true
    let clock = TestClock()
    let store = makeStore(state, clock: clock)
    // Exhaustive: a `requestLink`, a counted attempt or a `deliveryFailed` would be unexpected.
    await store.send(.sendViaPropagation(message: msg, propagationPacked: packed)) {
        $0.propagationQueue[pn] = [LXMFRouter.PropagationItem(messageHash: h, propagationPacked: packed)]
    }
    for _ in 0...LXMFDelivery.maxAttempts {
        await store.send(.linkClosed(destinationHash: pn))
        await clock.advance(by: .seconds(LinkTiming.defaultEstablishmentTimeout))
    }
    #expect(store.state.establishAttempts[pn] == nil)
}

/// A release with nothing pending has nothing to resume.
@Test @MainActor func holdReleaseWithNothingPendingDoesNothing() async {
    let store = makeStore(LXMFRouter.State(), clock: TestClock())
    await store.send(.setHold(true)) { $0.held = true }
    // Exhaustive: any effect would be unexpected.
    await store.send(.setHold(false)) { $0.held = false }
}

/// A release without a hold (the app releases on every reconnect) neither retries early nor counts.
@Test @MainActor func holdReleaseWhenNotHeldDoesNothing() async {
    let msg = makeMessage()
    let clock = TestClock()
    let store = makeStore(pathTo(msg.destinationHash), clock: clock)
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.skipReceivedActions(strict: false)
    await store.send(.setHold(false))
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds - 1))   // short of the next retry
    await store.skipReceivedActions(strict: false)
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)]?.attempts == 1)
}

/// A path-request park in progress when the hold starts re-arms instead of spending the budget.
@Test @MainActor func holdStopsThePathRequestPark() async {
    let msg = makeMessage()
    let dest = msg.destinationHash
    let clock = TestClock()
    let store = makeStore(LXMFRouter.State(), clock: clock)    // no path: the copy parks
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive(.delegate(.requestPath(destinationHash: dest)))
    store.exhaustivity = .on
    await store.send(.setHold(true)) { $0.held = true }
    for _ in 0...LXMFDelivery.maxAttempts {
        await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
        // Exhaustive: a `requestPath`, a counted attempt or a `deliveryFailed` would be unexpected.
        await store.receive(.pathRequestDeadline(destinationHash: dest))
    }
    #expect(store.state.establishAttempts[dest] == nil)
    store.exhaustivity = .off   // the held park timer runs on by design
}

/// The app's `holdOutbound` reaches the router.
@Test @MainActor func holdOutboundForwardsToTheRouter() async {
    let ep = TransportEndpoint.State.tcp(TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    let store = TestStore(initialState: LXMFNode.State(identity: Identity(), endpoint: ep)) { LXMFNode() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.continuousClock = TestClock()
    }
    await store.send(.holdOutbound(true))
    await store.receive(.router(.setHold(true))) { $0.router.held = true }
    await store.send(.holdOutbound(false))
    await store.receive(.router(.setHold(false))) { $0.router.held = false }
}

/// A Resource copy that used its last transfer is not failed while held when that transfer is lost,
/// whether the link goes or the transfer fails: it fails on release, when its retry is due.
@Test(arguments: [true, false]) @MainActor func holdDefersAFinalTransferFailure(linkLost: Bool) async {
    let msg = makeMessage()
    let h = msg.hash
    let dest = msg.destinationHash
    var state = LXMFRouter.State()
    state.held = true
    state.directLinks[dest] = .active(linkID: link)
    state.linkResourceInFlight[link] = .delivery(h)
    state.pendingDeliveries[.delivery(h)] = LXMFRouter.PendingDelivery(
        resend: .direct(destinationHash: dest, data: msg.packed, asResource: true),
        attempts: LXMFDelivery.maxAttempts, phase: .transferring)
    let store = makeStore(state, clock: TestClock())
    store.exhaustivity = .off
    if linkLost {
        await store.send(.linkClosed(destinationHash: dest))
    } else {
        await store.send(.resourceFailedOnLink(linkID: link, rejected: false))
    }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.pendingDeliveries[.delivery(h)]?.phase == .retrying)
    #expect(store.state.pendingDeliveries[.delivery(h)]?.attempts == LXMFDelivery.maxAttempts)
    // The release also re-establishes the link, which this test does not follow.
    await store.send(.setHold(false))
    await store.receive(.delegate(.deliveryFailed(messageHash: h)))
    #expect(store.state.pendingDeliveries[.delivery(h)] == nil)
}
