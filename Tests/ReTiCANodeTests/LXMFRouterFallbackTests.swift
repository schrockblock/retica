import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

private let link = Data(repeating: 0xD1, count: 16)

private func makeMessage() -> LXMessage {
    LXMessage.create(source: Identity(),
                     destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                     timestamp: 1700000000.5, title: Data("t".utf8), content: Data("direct first".utf8))
}

/// A known path to `recipient`, so an opportunistic copy resends on every retry (10 s apart).
private func pathTo(_ recipient: Data) -> LXMFRouter.State {
    var state = LXMFRouter.State()
    state.knownPaths.insert(recipient)
    return state
}

@MainActor
private func makeStore(_ state: LXMFRouter.State, clock: TestClock<Duration>) -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

/// Spec Amendment A2: the delivery copy keeps retrying, and the propagated copy is asked for exactly
/// when its third attempt is armed — not one retry earlier or later.
@Test @MainActor func fallbackDueAfterTheThirdDeliveryAttempt() async {
    let msg = makeMessage()
    let h = msg.hash
    let clock = TestClock()
    let store = makeStore(pathTo(msg.destinationHash), clock: clock)
    await store.send(.markFallbackEligible(messageHash: h))
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    for _ in 0..<(LXMFDelivery.propagationFallbackAfterAttempts - 2) {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    }
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive(.retryDue(messageHash: h, leg: .delivery)) {
        $0.pendingDeliveries[.delivery(h)]?.attempts = LXMFDelivery.propagationFallbackAfterAttempts
        $0.fallbackEligible.remove(h)
        $0.pendingPropagatedCopies.insert(h)
    }
    await store.receive(.delegate(.propagationFallbackDue(messageHash: h)))
    await store.receive(.delegate(.sendOpportunistic(destinationHash: msg.destinationHash,
                                                     payload: msg.opportunisticPayload, messageHash: h)))
    store.exhaustivity = .off   // the delivery copy's retry timer runs on by design
}

/// The link-establishment budget counts too: the third `requestLink` for a queued copy hands off.
@Test @MainActor func fallbackDueAtTheThirdLinkAttempt() async {
    let msg = makeMessage()
    let h = msg.hash
    let dest = msg.destinationHash
    let store = makeStore(pathTo(dest), clock: TestClock())
    await store.send(.markFallbackEligible(messageHash: h))
    await store.send(.send(message: msg, desiredMethod: .direct))          // link attempt 1
    await store.send(.linkClosed(destinationHash: dest))                     // link attempt 2
    await store.skipReceivedActions(strict: false)
    #expect(store.state.pendingPropagatedCopies.isEmpty)
    store.exhaustivity = .on
    await store.send(.linkClosed(destinationHash: dest)) {                   // link attempt 3
        $0.establishAttempts[dest] = LXMFDelivery.propagationFallbackAfterAttempts
        $0.fallbackEligible.remove(h)
        $0.pendingPropagatedCopies.insert(h)
    }
    await store.receive(.delegate(.propagationFallbackDue(messageHash: h)))
    await store.receive(.delegate(.requestLink(destinationHash: dest)))
}

/// A park spends the same budget: the third path request for a queued copy hands off.
@Test @MainActor func fallbackDueAtTheThirdPathRequest() async {
    let msg = makeMessage()
    let h = msg.hash
    let dest = msg.destinationHash
    let clock = TestClock()
    let store = makeStore(LXMFRouter.State(), clock: clock)                 // no path: the copy parks
    await store.send(.markFallbackEligible(messageHash: h))
    await store.send(.send(message: msg, desiredMethod: .direct))
    for _ in 0..<(LXMFDelivery.propagationFallbackAfterAttempts - 1) {
        await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
    }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.pendingPropagatedCopies.isEmpty)
    store.exhaustivity = .on
    await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
    await store.receive(.pathRequestDeadline(destinationHash: dest)) {
        $0.establishAttempts[dest] = LXMFDelivery.propagationFallbackAfterAttempts
        $0.fallbackEligible.remove(h)
        $0.pendingPropagatedCopies.insert(h)
    }
    await store.receive(.delegate(.propagationFallbackDue(messageHash: h)))
    await store.receive(.delegate(.requestPath(destinationHash: dest)))
    store.exhaustivity = .off   // the park timer runs on by design
}

/// A destination whose establishment budget is already spent gives up before any trigger fires:
/// the hand-off happens at that terminal failure instead, and the message is not failed.
@Test @MainActor func fallbackDueAtTerminalFailureWhenEarlierTriggerMissed() async {
    let msg = makeMessage()
    let h = msg.hash
    let dest = msg.destinationHash
    var state = pathTo(dest)
    state.establishAttempts[dest] = LXMFDelivery.maxAttempts
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    await store.send(.markFallbackEligible(messageHash: h)) {
        $0.fallbackEligible.insert(h)
    }
    // Exhaustive: `giveUp` at once; a deliveryFailed would be unexpected.
    await store.send(.send(message: msg, desiredMethod: .direct)) {
        $0.knownPaths.remove(dest)
        $0.establishAttempts[dest] = nil
        $0.fallbackEligible.remove(h)
        $0.pendingPropagatedCopies.insert(h)
    }
    await store.receive(.delegate(.propagationFallbackDue(messageHash: h)))
}

/// A rejected delivery copy is the peer's answer, not a stall: the message ends as today.
@Test @MainActor func fallbackNeverForARejectedDeliveryLeg() async {
    let msg = makeMessage()
    let h = msg.hash
    let dest = msg.destinationHash
    var state = LXMFRouter.State()
    state.directLinks[dest] = .active(linkID: link)
    state.linkResourceInFlight[link] = .delivery(h)
    state.pendingDeliveries[.delivery(h)] = LXMFRouter.PendingDelivery(
        resend: .direct(destinationHash: dest, data: msg.packed, asResource: true), attempts: 1, phase: .transferring)
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    await store.send(.markFallbackEligible(messageHash: h)) {
        $0.fallbackEligible.insert(h)
    }
    await store.send(.resourceFailedOnLink(linkID: link, rejected: true)) {
        $0.linkResourceInFlight[link] = nil
        $0.pendingDeliveries[.delivery(h)] = nil
        $0.fallbackEligible.remove(h)
    }
    await store.receive(.delegate(.deliveryRejected(messageHash: h)))
}

/// A delivery copy confirmed before its third attempt ends the eligibility: no hand-off later.
@Test @MainActor func fallbackEligibleClearedOnDeliverySuccess() async {
    let msg = makeMessage()
    let h = msg.hash
    let clock = TestClock()
    let store = makeStore(pathTo(msg.destinationHash), clock: clock)
    await store.send(.markFallbackEligible(messageHash: h))
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))       // attempt 2
    await store.send(.opportunisticDelivered(messageHash: h))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: h)))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.fallbackEligible.isEmpty)
    store.exhaustivity = .on
    // Exhaustive: the retry timer is cancelled, so nothing — no propagationFallbackDue — arrives.
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds * LXMFDelivery.maxAttempts))
}

/// The hand-off fired, then the delivery proof arrived (the double buzz A2 accepts), then the
/// propagated copy failed: one `deliveryConfirmed`, and no `deliveryFailed` after it.
@Test @MainActor func fallbackLateProofStillConfirmsOnce() async {
    let msg = makeMessage()
    let h = msg.hash
    let clock = TestClock()
    let store = makeStore(pathTo(msg.destinationHash), clock: clock)        // no propagation node configured
    await store.send(.markFallbackEligible(messageHash: h))
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    // Up to just before the delivery copy's last attempt, so it is still pending for the proof.
    for _ in 0..<(LXMFDelivery.maxAttempts - 2) {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    }
    await store.receive(.delegate(.propagationFallbackDue(messageHash: h)))
    await store.send(.opportunisticDelivered(messageHash: h))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: h)))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    // The confirmation already dropped the copy's marker. A copy handed over anyway fails at once
    // (no node). Exhaustive: a deliveryFailed would be unexpected.
    #expect(store.state.pendingPropagatedCopies.isEmpty)
    await store.send(.sendViaPropagation(message: msg, propagationPacked: Data("container".utf8)))
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds * LXMFDelivery.maxAttempts))
}

/// `LXMFNode` fails a handed-off copy it cannot pack. A cancel that landed first already ended the
/// message, so the late failure reports nothing.
@Test @MainActor func fallbackCopyFailedAfterACancelIsSilent() async {
    let h = makeMessage().hash
    var state = LXMFRouter.State()
    state.pendingPropagatedCopies = [h]
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    await store.send(.cancelOutbound(messageHash: h)) {
        $0.pendingPropagatedCopies = []
        $0.cancelledMessages.insert(h)
    }
    await store.receive(.delegate(.deliveryCancelled(messageHash: h)))
    await store.send(.propagatedCopyFailed(messageHash: h))     // exhaustive: a deliveryFailed would be unexpected
}

// MARK: - A confirmed delivery copy drops the propagated copy that has not gone out

private let pn = Data(repeating: 0xB7, count: 16)
private let pnLink = Data(repeating: 0xC0, count: 16)
private let container = Data("container".utf8)
/// An exhaustive no-op (activity on a link we do not have): sent only after every received action
/// is accounted for, so a late `propagationAccepted` / `deliveryFailed` fails the test there.
@MainActor
private let probe = LXMFRouter.Action.linkActivity(linkID: Data(repeating: 0x99, count: 16))

/// Stall the (opportunistic) delivery copy until the hand-off, with a propagation node configured.
@MainActor
private func handedOff(_ msg: LXMessage, _ state: LXMFRouter.State,
                       clock: TestClock<Duration>) async -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    var state = state
    state.knownPaths.insert(msg.destinationHash)
    state.outboundPropagationNode = pn
    let store = makeStore(state, clock: clock)
    await store.send(.markFallbackEligible(messageHash: msg.hash))
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    for _ in 0..<(LXMFDelivery.propagationFallbackAfterAttempts - 1) {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    }
    await store.receive(.delegate(.propagationFallbackDue(messageHash: msg.hash)))
    await store.skipReceivedActions(strict: false)
    return store
}

/// The confirmation, exhaustively: one `deliveryConfirmed`, and the delivery copy's retries stop.
@MainActor
private func confirmOnce(_ store: TestStore<LXMFRouter.State, LXMFRouter.Action>, _ h: Data,
                         _ update: @escaping (inout LXMFRouter.State) -> Void) async {
    store.exhaustivity = .on
    await store.send(.opportunisticDelivered(messageHash: h)) {
        $0.pendingDeliveries[.delivery(h)] = nil
        $0.succeededMessages.insert(h)
        update(&$0)
    }
    await store.receive(.delegate(.deliveryConfirmed(messageHash: h)))
}

/// Still in `LXMFNode`'s stamp search: the pending marker goes, silently. (The node stops the
/// search itself: `successStopsTheFallbacksStampSearch`.)
@Test @MainActor func successDropsAPropagatedCopyStillInItsStampSearch() async {
    let msg = makeMessage()
    let h = msg.hash
    let clock = TestClock()
    let store = await handedOff(msg, LXMFRouter.State(), clock: clock)
    #expect(store.state.pendingPropagatedCopies == [h])
    await confirmOnce(store, h) { $0.pendingPropagatedCopies.remove(h) }
    // Exhaustive: nothing more — no propagationAccepted, no deliveryFailed.
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds * LXMFDelivery.maxAttempts))
    await store.send(probe)
}

/// Queued behind the node's link: it is dequeued, so the link coming up sends nothing.
@Test @MainActor func successDropsAQueuedPropagatedCopy() async {
    let msg = makeMessage()
    let h = msg.hash
    let clock = TestClock()
    var state = LXMFRouter.State()
    state.knownPaths.insert(pn)
    let store = await handedOff(msg, state, clock: clock)
    await store.send(.sendViaPropagation(message: msg, propagationPacked: container))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.propagationQueue[pn]?.count == 1)
    await confirmOnce(store, h) { $0.propagationQueue[pn] = nil }
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds * LXMFDelivery.maxAttempts))
    // The link comes up with nothing to send: no sendPropagatedPacket, so no propagationAccepted.
    await store.send(.linkEstablished(destinationHash: pn, linkID: pnLink)) {
        $0.directLinks[pn] = .active(linkID: pnLink)
        $0.establishAttempts[pn] = nil
    }
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds * LXMFDelivery.maxAttempts))
    await store.send(probe)
    store.exhaustivity = .off   // the PN link's idle timer runs on by design
}

/// Already transmitted: left to finish. It keeps retrying, and running out after the success is
/// silent — the one terminal stays `deliveryConfirmed`.
@Test @MainActor func successKeepsAPropagatedCopyAlreadyTransmitted() async {
    let msg = makeMessage()
    let h = msg.hash
    let clock = TestClock()
    var state = LXMFRouter.State()
    state.directLinks[pn] = .active(linkID: pnLink)
    let store = await handedOff(msg, state, clock: clock)
    await store.send(.sendViaPropagation(message: msg, propagationPacked: container))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.pendingDeliveries[.propagated(h)]?.attempts == 1)
    await confirmOnce(store, h) { _ in }
    for attempt in 2...LXMFDelivery.maxAttempts {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
        await store.receive(.retryDue(messageHash: h, leg: .propagated)) {
            $0.pendingDeliveries[.propagated(h)]?.attempts = attempt
        }
        await store.receive(.delegate(.sendPropagatedPacket(linkID: pnLink, propagationPacked: container,
                                                            messageHash: h)))
    }
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive(.retryDue(messageHash: h, leg: .propagated)) {
        $0.pendingDeliveries[.propagated(h)] = nil
    }
    await store.send(probe)
    store.exhaustivity = .off   // the PN link's idle timer runs on by design
}

/// Armed while held, so never sent (attempts 0): dropped with its timer, and the release sends
/// nothing — the stale copy that would otherwise go out long after the message arrived.
@Test @MainActor func successDropsAHeldUnsentPropagatedCopy() async {
    let msg = makeMessage()
    let h = msg.hash
    let clock = TestClock()
    var state = LXMFRouter.State()
    state.directLinks[pn] = .active(linkID: pnLink)
    let store = await handedOff(msg, state, clock: clock)
    await store.send(.setHold(true))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: container))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.pendingDeliveries[.propagated(h)]?.attempts == 0)
    await confirmOnce(store, h) { $0.pendingDeliveries[.propagated(h)] = nil }
    await store.send(.setHold(false)) { $0.held = false }
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds * LXMFDelivery.maxAttempts))
    await store.send(probe)
    store.exhaustivity = .off   // the PN link's idle timer runs on by design
}

/// A send never marked eligible fails after its last retry, as before this change (~50 s on TCP).
@Test @MainActor func fallbackIneligibleSendKeepsTodaysFailure() async {
    let msg = makeMessage()
    let h = msg.hash
    let clock = TestClock()
    let store = makeStore(pathTo(msg.destinationHash), clock: clock)
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    for _ in 0..<(LXMFDelivery.maxAttempts - 1) {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    }
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))       // t = 50 s
    await store.receive(.retryDue(messageHash: h, leg: .delivery)) {
        $0.pendingDeliveries[.delivery(h)] = nil
    }
    await store.receive(.delegate(.deliveryFailed(messageHash: h)))
}
