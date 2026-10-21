import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

private let pn = Data(repeating: 0xBB, count: 16)
private let pnLink = Data(repeating: 0xC0, count: 16)
private let small = Data("small-container".utf8)

private func makeMessage() -> LXMessage {
    LXMessage.create(source: Identity(),
                     destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                     timestamp: 1700000000.5, title: Data("t".utf8), content: Data("two copies".utf8))
}

/// A live link to the propagation node and a known path to `recipient`, so both copies are armed
/// with retry timers and every retry resends (10 s apart).
private func bothCopiesLive(recipient: Data) -> LXMFRouter.State {
    var state = LXMFRouter.State()
    state.outboundPropagationNode = pn
    state.directLinks[pn] = .active(linkID: pnLink)
    state.knownPaths.insert(recipient)
    return state
}

@MainActor
private func makeStore(_ state: LXMFRouter.State, clock: TestClock<Duration>) -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

/// Advance to just before a copy's LAST retry, drop everything so far, and turn exhaustive on:
/// the final retry is then asserted exactly, and anything after it (a deliveryFailed) is a stray.
@MainActor
private func advanceToTheFinalRetry(_ store: TestStore<LXMFRouter.State, LXMFRouter.Action>, _ clock: TestClock<Duration>) async {
    for _ in 0..<(LXMFDelivery.maxAttempts - 1) {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    }
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
}

@Test @MainActor func copyOutcomeDeliveryFailedWaitsForEveryCopy() async {
    let msg = makeMessage()
    let clock = TestClock()
    let store = makeStore(bothCopiesLive(recipient: msg.destinationHash), clock: clock)
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))
    for _ in 0..<LXMFDelivery.maxAttempts {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    }
    await store.receive(.delegate(.deliveryFailed(messageHash: msg.hash)))
    #expect(store.state.pendingDeliveries.isEmpty)
    await store.skipInFlightEffects(strict: false)   // the PN link's idle timer
    store.exhaustivity = .on   // a SECOND deliveryFailed (from the first copy to fail) fails teardown
}

@Test @MainActor func copyOutcomeNoFailureAfterThePropagatedCopySucceeded() async {
    let msg = makeMessage()
    let clock = TestClock()
    let store = makeStore(bothCopiesLive(recipient: msg.destinationHash), clock: clock)
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))
    await store.send(.delivered(messageHash: msg.hash, leg: .propagated))
    await store.receive(.delegate(.propagationAccepted(messageHash: msg.hash)))
    await advanceToTheFinalRetry(store, clock)
    await store.receive(.retryDue(messageHash: msg.hash, leg: .delivery)) {
        $0.pendingDeliveries[.delivery(msg.hash)] = nil
    }
    // Exhaustive no-op: both copies are settled, so this does nothing — but it fails if a stray
    // deliveryFailed is still unhandled.
    await store.send(.retryDue(messageHash: msg.hash, leg: .delivery))
    store.exhaustivity = .off   // the PN link's idle timer (and any settled retry timer) run on by design
}

@Test @MainActor func copyOutcomeNoFailureAfterTheDeliveryCopySucceeded() async {
    let msg = makeMessage()
    let clock = TestClock()
    let store = makeStore(bothCopiesLive(recipient: msg.destinationHash), clock: clock)
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))
    await store.send(.opportunisticDelivered(messageHash: msg.hash))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    await advanceToTheFinalRetry(store, clock)
    await store.receive(.retryDue(messageHash: msg.hash, leg: .propagated)) {
        $0.pendingDeliveries[.propagated(msg.hash)] = nil
    }
    // Exhaustive no-op: both copies are settled, so this does nothing — but it fails if a stray
    // deliveryFailed is still unhandled.
    await store.send(.retryDue(messageHash: msg.hash, leg: .propagated))
    store.exhaustivity = .off   // the PN link's idle timer (and any settled retry timer) run on by design
}

/// The propagated copy is armed only after its propagation stamp is found — possibly after the
/// delivery copy was already confirmed. Its later failure must stay silent.
@Test @MainActor func copyOutcomeLateArmedPropagatedFailureAfterSuccessIsSilent() async {
    let msg = makeMessage()
    let clock = TestClock()
    let store = makeStore(bothCopiesLive(recipient: msg.destinationHash), clock: clock)
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.opportunisticDelivered(messageHash: msg.hash))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))   // armed only now
    await advanceToTheFinalRetry(store, clock)
    await store.receive(.retryDue(messageHash: msg.hash, leg: .propagated)) {
        $0.pendingDeliveries[.propagated(msg.hash)] = nil
    }
    // Exhaustive no-op: both copies are settled, so this does nothing — but it fails if a stray
    // deliveryFailed is still unhandled.
    await store.send(.retryDue(messageHash: msg.hash, leg: .propagated))
    store.exhaustivity = .off   // the PN link's idle timer (and any settled retry timer) run on by design
}

/// A propagated copy QUEUED behind a link request has no timer yet, but it is outstanding: the
/// delivery copy running out must not fail the message.
@Test @MainActor func copyOutcomeQueuedPropagatedCopyKeepsTheMessageAlive() async {
    let msg = makeMessage()
    let clock = TestClock()
    var state = LXMFRouter.State()
    state.outboundPropagationNode = pn
    state.knownPaths.insert(pn)                    // no link yet → the copy queues and a link is requested
    state.knownPaths.insert(msg.destinationHash)
    let store = makeStore(state, clock: clock)
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))
    #expect(store.state.propagationQueue[pn]?.count == 1)
    await advanceToTheFinalRetry(store, clock)
    await store.receive(.retryDue(messageHash: msg.hash, leg: .delivery)) {
        $0.pendingDeliveries[.delivery(msg.hash)] = nil
    }
}

/// A queued copy that gives up (its destination's establishment budget is spent) does not fail
/// the message while the other copy is still pending.
@Test @MainActor func copyOutcomeGiveUpOnAQueuedCopyWaitsForTheOtherCopy() async {
    let msg = makeMessage()
    var state = LXMFRouter.State()
    state.outboundPropagationNode = pn
    state.directLinks[pn] = .awaitingPath
    state.establishAttempts[pn] = LXMFDelivery.maxAttempts
    state.propagationQueue[pn] = [LXMFRouter.PropagationItem(messageHash: msg.hash, propagationPacked: small)]
    state.pendingDeliveries[.delivery(msg.hash)] = LXMFRouter.PendingDelivery(
        resend: .opportunistic(destinationHash: msg.destinationHash, payload: msg.opportunisticPayload), attempts: 1)
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    // Exhaustive: the park deadline gives up on the PN; a deliveryFailed would be unexpected.
    await store.send(.pathRequestDeadline(destinationHash: pn)) {
        $0.directLinks[pn] = nil
        $0.establishAttempts[pn] = nil
        $0.propagationQueue[pn] = nil
    }
}

/// Mirror of the above for `giveUp`'s DELIVERY half: a direct delivery copy queued behind the
/// recipient gives up (budget spent) while the propagated copy is armed — nothing is reported.
@Test @MainActor func copyOutcomeGiveUpOnAQueuedDeliveryCopyWaitsForThePropagatedCopy() async {
    let msg = makeMessage()
    let dest = msg.destinationHash
    var state = LXMFRouter.State()
    state.outboundPropagationNode = pn
    state.directLinks[dest] = .awaitingPath
    state.establishAttempts[dest] = LXMFDelivery.maxAttempts
    state.outboundQueue[dest] = [msg]
    state.pendingDeliveries[.propagated(msg.hash)] = LXMFRouter.PendingDelivery(
        resend: .propagated(destinationHash: pn, data: small), attempts: 1)
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    // Exhaustive: the park deadline gives up on the recipient; a deliveryFailed would be unexpected.
    await store.send(.pathRequestDeadline(destinationHash: dest)) {
        $0.directLinks[dest] = nil
        $0.establishAttempts[dest] = nil
        $0.outboundQueue[dest] = nil
    }
}

/// `sendMessage(fallbackToPropagation: true)`'s hand-off with no propagation node configured: the propagated copy
/// fails at once, but the delivery copy is pending, so nothing is reported.
@Test @MainActor func copyOutcomeNoPropagationNodeDoesNotFailAPendingDeliveryCopy() async {
    let msg = makeMessage()
    var state = LXMFRouter.State()
    state.pendingDeliveries[.delivery(msg.hash)] = LXMFRouter.PendingDelivery(
        resend: .opportunistic(destinationHash: msg.destinationHash, payload: msg.opportunisticPayload), attempts: 1)
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))   // exhaustive: nothing happens
}
