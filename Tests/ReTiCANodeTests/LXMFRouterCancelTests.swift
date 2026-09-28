import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

// Transfer-aware delivery, Task 5: the app cancels an outbound message in any state. Reference
// `LXMRouter.cancel_outbound` (LXMRouter.py:1719-1744) marks it CANCELLED and cancels its Resource;
// nothing afterwards may report it delivered or failed.

private let recipient = Data(repeating: 0xD5, count: 16)
private let recipientLink = Data(repeating: 0xEF, count: 16)
private let pn = Data(repeating: 0xBB, count: 16)
private let pnLink = Data(repeating: 0xC0, count: 16)
private let small = Data("small-container".utf8)
@MainActor
private let probe = LXMFRouter.Action.resourceFailedOnLink(linkID: Data(repeating: 0x99, count: 16), rejected: false)

private func bigMessage(_ fill: String) -> LXMessage {
    LXMessage.create(source: Identity(), destinationHash: recipient, timestamp: 1700000000.5,
                     title: Data("t".utf8), content: Data(String(repeating: fill, count: 2000).utf8))
}

private func note() -> LXMessage {
    LXMessage.create(source: Identity(), destinationHash: recipient, timestamp: 1700000000.5,
                     title: Data("t".utf8), content: Data("cancel me".utf8))
}

private func liveRecipient() -> LXMFRouter.State {
    var state = LXMFRouter.State()
    state.directLinks[recipient] = .active(linkID: recipientLink)
    state.knownPaths.insert(recipient)
    return state
}

@MainActor
private func cancelStore(_ state: LXMFRouter.State, _ clock: TestClock<Duration> = TestClock())
    -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

@Test @MainActor func routerCancelTransferringCopyCancelsItsResource() async {
    let big = bigMessage("a")
    let store = cancelStore(liveRecipient())
    await store.send(.send(message: big, desiredMethod: .direct))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.cancelOutbound(messageHash: big.hash)) {
        $0.pendingDeliveries[.delivery(big.hash)] = nil
        $0.linkResourceInFlight[recipientLink] = nil
        $0.cancelledMessages.insert(big.hash)
    }
    await store.receive(.delegate(.cancelResource(linkID: recipientLink)))
    await store.receive(.delegate(.deliveryCancelled(messageHash: big.hash)))
    // A late outcome of the cancelled transfer finds nothing to resolve: no state, no delegate.
    await store.send(.resourceFailedOnLink(linkID: recipientLink, rejected: false))
    await store.send(.resourceDeliveredOnLink(linkID: recipientLink))
    #expect(store.state.directLinks[recipient] == .active(linkID: recipientLink))
    store.exhaustivity = .off
}

@Test @MainActor func routerCancelQueuedCopyIsRemovedAndNothingIsSent() async {
    let first = bigMessage("a"), second = bigMessage("b")
    let store = cancelStore(liveRecipient())
    await store.send(.send(message: first, desiredMethod: .direct))
    await store.send(.send(message: second, desiredMethod: .direct))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.cancelOutbound(messageHash: second.hash)) {
        $0.pendingDeliveries[.delivery(second.hash)] = nil
        $0.resourceQueue[recipient] = nil
        $0.cancelledMessages.insert(second.hash)
    }
    await store.receive(.delegate(.deliveryCancelled(messageHash: second.hash)))
    await store.send(.resourceDeliveredOnLink(linkID: recipientLink)) {
        $0.linkResourceInFlight[recipientLink] = nil
    }
    await store.receive(.delivered(messageHash: first.hash, leg: .delivery)) {
        $0.pendingDeliveries[.delivery(first.hash)] = nil
        $0.succeededMessages.insert(first.hash)
    }
    await store.receive(.delegate(.deliveryConfirmed(messageHash: first.hash)))
    await store.send(probe)                                   // no sendDirect for the cancelled copy
    store.exhaustivity = .off
}

@Test @MainActor func routerCancelRetryingCopyStopsItsTimer() async {
    let m = note()
    let clock = TestClock()
    let store = cancelStore(liveRecipient(), clock)
    await store.send(.send(message: m, desiredMethod: .opportunistic))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.cancelOutbound(messageHash: m.hash)) {
        $0.pendingDeliveries[.delivery(m.hash)] = nil
        $0.cancelledMessages.insert(m.hash)
    }
    await store.receive(.delegate(.deliveryCancelled(messageHash: m.hash)))
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds * LXMFDelivery.maxAttempts))
    await store.send(probe)                                   // no retryDue ever fired
}

@Test @MainActor func routerCancelTransferringCopyStartsTheNextQueuedCopy() async {
    let first = bigMessage("a"), second = bigMessage("b")
    let k2 = LXMFRouter.DeliveryKey.delivery(second.hash)
    let store = cancelStore(liveRecipient())
    await store.send(.send(message: first, desiredMethod: .direct))
    await store.send(.send(message: second, desiredMethod: .direct))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.cancelOutbound(messageHash: first.hash)) {
        $0.pendingDeliveries[.delivery(first.hash)] = nil
        $0.linkResourceInFlight[recipientLink] = k2
        $0.pendingDeliveries[k2]?.phase = .transferring
        $0.resourceQueue[recipient] = nil
        $0.cancelledMessages.insert(first.hash)
    }
    // The cancel reaches the link before the next transfer starts on it.
    await store.receive(.delegate(.cancelResource(linkID: recipientLink)))
    await store.receive(.delegate(.deliveryCancelled(messageHash: first.hash)))
    await store.receive(.delegate(.sendDirect(linkID: recipientLink, data: second.packed, asResource: true)))
    store.exhaustivity = .off
}

@Test @MainActor func routerCancelBothCopiesReportsOnce() async {
    let m = note()
    let clock = TestClock()
    var state = liveRecipient()
    state.outboundPropagationNode = pn
    state.directLinks[pn] = .active(linkID: pnLink)
    let store = cancelStore(state, clock)
    await store.send(.send(message: m, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: m, propagationPacked: small))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.cancelOutbound(messageHash: m.hash)) {
        $0.pendingDeliveries = [:]
        $0.cancelledMessages.insert(m.hash)
    }
    await store.receive(.delegate(.deliveryCancelled(messageHash: m.hash)))
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds * LXMFDelivery.maxAttempts))
    await store.send(probe)                                   // neither copy retries or fails later
    store.exhaustivity = .off                                 // the PN link's idle timer
}

/// A copy handed over after its message was cancelled — a stamp search that finished anyway — is
/// never armed. A cancel with nothing to cancel reports nothing (the node reports the stamp case).
@Test @MainActor func routerCancelLateCopyOfACancelledMessageArmsNothing() async {
    let m = note()
    let store = TestStore(initialState: liveRecipient()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    // `cancelledMessages` is reference-backed storage (RingSet.swift): with no other pending work
    // for `m`, inserting into it is the closure's ONLY mutation, and such a ring insert is invisible
    // to TestStore's state diffing (RingSet.swift:132-135 documents this exact trap) — asserting it
    // here would fail with "no change occurred" even though the insert genuinely happened. The
    // insert's effect is instead verified behaviourally below: a copy handed over afterwards is
    // silently dropped rather than armed.
    await store.send(.cancelOutbound(messageHash: m.hash))
    await store.send(.send(message: m, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: m, propagationPacked: small))   // no PN: would fail if armed
}

@Test @MainActor func routerCancelMessageQueuedBehindItsLinkIsDropped() async {
    let big = bigMessage("a")
    var state = LXMFRouter.State()
    state.knownPaths.insert(recipient)
    let store = cancelStore(state)
    await store.send(.send(message: big, desiredMethod: .direct))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.cancelOutbound(messageHash: big.hash)) {
        $0.outboundQueue[recipient] = nil
        $0.cancelledMessages.insert(big.hash)
    }
    await store.receive(.delegate(.deliveryCancelled(messageHash: big.hash)))
    await store.send(.linkEstablished(destinationHash: recipient, linkID: recipientLink)) {
        $0.directLinks[recipient] = .active(linkID: recipientLink)
        $0.establishAttempts[recipient] = nil
    }
    await store.send(probe)                                   // nothing was drained onto the link
    store.exhaustivity = .off
}
