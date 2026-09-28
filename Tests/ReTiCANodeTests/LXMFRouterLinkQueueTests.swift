import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

// Transfer-aware delivery, Task 4: one Resource transfer per link. `LinkSession` holds a single
// split-send slot and the router a single in-flight entry per link, so a second large send used to
// overwrite both. Now it waits, and small sends never wait behind a transfer.

private let recipient = Data(repeating: 0xD5, count: 16)
private let recipientLink = Data(repeating: 0xEF, count: 16)
private let freshLink = Data(repeating: 0xF0, count: 16)
@MainActor private let probe = LXMFRouter.Action.resourceFailedOnLink(linkID: Data(repeating: 0x99, count: 16), rejected: false)

private func bigMessage(_ fill: String) -> LXMessage {
    LXMessage.create(source: Identity(), destinationHash: recipient, timestamp: 1700000000.5,
                     title: Data("t".utf8), content: Data(String(repeating: fill, count: 2000).utf8))
}

private func liveRecipient() -> LXMFRouter.State {
    var state = LXMFRouter.State()
    state.directLinks[recipient] = .active(linkID: recipientLink)
    state.knownPaths.insert(recipient)
    return state
}

@MainActor
private func queueStore(_ state: LXMFRouter.State, _ clock: TestClock<Duration> = TestClock())
    -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

private func resource(_ m: LXMessage, _ phase: LXMFRouter.Phase) -> LXMFRouter.PendingDelivery {
    LXMFRouter.PendingDelivery(resend: .direct(destinationHash: recipient, data: m.packed, asResource: true),
                               attempts: 1, phase: phase)
}

@Test @MainActor func linkQueueSecondLargeSendWaitsForTheFirst() async {
    let first = bigMessage("a"), second = bigMessage("b")
    let k1 = LXMFRouter.DeliveryKey.delivery(first.hash), k2 = LXMFRouter.DeliveryKey.delivery(second.hash)
    let store = queueStore(liveRecipient())
    store.exhaustivity = .on
    await store.send(.send(message: first, desiredMethod: .direct)) {
        $0.pendingDeliveries[k1] = resource(first, .transferring)
        $0.linkResourceInFlight[recipientLink] = k1
    }
    await store.receive(.delegate(.sendDirect(linkID: recipientLink, data: first.packed, asResource: true)))
    await store.send(.send(message: second, desiredMethod: .direct)) {      // nothing sent for it yet
        $0.pendingDeliveries[k2] = resource(second, .queued)
        $0.resourceQueue[recipient] = [k2]
    }
    await store.send(.resourceDeliveredOnLink(linkID: recipientLink)) {
        $0.linkResourceInFlight[recipientLink] = k2
        $0.pendingDeliveries[k2]?.phase = .transferring
        $0.resourceQueue[recipient] = nil
    }
    await store.receive(.delivered(messageHash: first.hash, leg: .delivery)) {
        $0.pendingDeliveries[k1] = nil
        $0.succeededMessages.insert(first.hash)
    }
    await store.receive(.delegate(.sendDirect(linkID: recipientLink, data: second.packed, asResource: true)))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: first.hash)))
    store.exhaustivity = .off   // idle timer
}

@Test @MainActor func linkQueueSmallSendIsNotQueuedBehindATransfer() async {
    let first = bigMessage("a")
    let note = LXMessage.create(source: Identity(), destinationHash: recipient, timestamp: 1700000000.5,
                                title: Data("t".utf8), content: Data("small".utf8))
    #expect(note.directRepresentation == .packet)
    let store = queueStore(liveRecipient())
    await store.send(.send(message: first, desiredMethod: .direct))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.send(message: note, desiredMethod: .direct)) {
        $0.pendingDeliveries[.delivery(note.hash)] = LXMFRouter.PendingDelivery(
            resend: .direct(destinationHash: recipient, data: note.packed, asResource: false), attempts: 1)
    }
    await store.receive(.delegate(.sendDirect(linkID: recipientLink, data: note.packed, asResource: false)))
    store.exhaustivity = .off   // retry + idle timers
}

@Test @MainActor func linkQueueFailedTransferWaitsForTheLinkThenResumesTheQueue() async {
    let first = bigMessage("a"), second = bigMessage("b")
    let k1 = LXMFRouter.DeliveryKey.delivery(first.hash), k2 = LXMFRouter.DeliveryKey.delivery(second.hash)
    let clock = TestClock()
    let store = queueStore(liveRecipient(), clock)
    await store.send(.send(message: first, desiredMethod: .direct))
    await store.send(.send(message: second, desiredMethod: .direct))
    await store.send(.resourceFailedOnLink(linkID: recipientLink, rejected: false))
    #expect(store.state.pendingDeliveries[k2]?.phase == .queued)            // its link is gone: it waits
    await store.send(.linkEstablished(destinationHash: recipient, linkID: freshLink))
    await store.receive(.delegate(.sendDirect(linkID: freshLink, data: second.packed, asResource: true)))
    #expect(store.state.linkResourceInFlight[freshLink] == k2)
    // The failed copy's retry finds the link busy and queues behind it.
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive(.retryDue(messageHash: first.hash, leg: .delivery))
    #expect(store.state.pendingDeliveries[k1]?.phase == .queued)
    #expect(store.state.resourceQueue[recipient] == [k1])
}

@Test @MainActor func linkQueueRejectionStartsTheNextCopy() async {
    let first = bigMessage("a"), second = bigMessage("b")
    let store = queueStore(liveRecipient())
    await store.send(.send(message: first, desiredMethod: .direct))
    await store.send(.send(message: second, desiredMethod: .direct))
    await store.send(.resourceFailedOnLink(linkID: recipientLink, rejected: true))
    await store.receive(.delegate(.deliveryRejected(messageHash: first.hash)))
    await store.receive(.delegate(.sendDirect(linkID: recipientLink, data: second.packed, asResource: true)))
}

@Test @MainActor func linkQueueTwoQueuedSendsDrainInOrderOnLinkEstablished() async {
    let first = bigMessage("a"), second = bigMessage("b")
    let k1 = LXMFRouter.DeliveryKey.delivery(first.hash), k2 = LXMFRouter.DeliveryKey.delivery(second.hash)
    var state = LXMFRouter.State()
    state.knownPaths.insert(recipient)
    let store = queueStore(state)
    await store.send(.send(message: first, desiredMethod: .direct))
    // `store.send` under `.off` (showSkippedAssertions: false) silently clears any not-yet-received
    // action queued by the previous send's effect before dispatching the next one — so `requestLink`
    // (already delivered by `first`'s effect within its own `megaYield`) must be received HERE, before
    // sending `second`, or the next `send` call wipes it with no failure reported.
    await store.receive(.delegate(.requestLink(destinationHash: recipient)))
    await store.send(.send(message: second, desiredMethod: .direct))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.linkEstablished(destinationHash: recipient, linkID: recipientLink)) {
        $0.directLinks[recipient] = .active(linkID: recipientLink)
        $0.establishAttempts[recipient] = nil
        $0.outboundQueue[recipient] = nil
        $0.pendingDeliveries[k1] = resource(first, .transferring)
        $0.pendingDeliveries[k2] = resource(second, .queued)
        $0.linkResourceInFlight[recipientLink] = k1
        $0.resourceQueue[recipient] = [k2]
    }
    await store.receive(.delegate(.sendDirect(linkID: recipientLink, data: first.packed, asResource: true)))
    await store.send(probe)
    store.exhaustivity = .off
}

/// A queued copy has no timer, so if its destination is given up on it must be failed there.
@Test @MainActor func linkQueueGiveUpFailsQueuedCopies() async {
    let big = bigMessage("a")
    let key = LXMFRouter.DeliveryKey.delivery(big.hash)
    var state = LXMFRouter.State()
    state.directLinks[recipient] = .awaitingPath
    state.establishAttempts[recipient] = LXMFDelivery.maxAttempts
    state.pendingDeliveries[key] = resource(big, .queued)
    state.resourceQueue[recipient] = [key]
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    await store.send(.pathRequestDeadline(destinationHash: recipient)) {
        $0.directLinks[recipient] = nil
        $0.establishAttempts[recipient] = nil
        $0.resourceQueue[recipient] = nil
        $0.pendingDeliveries[key] = nil
    }
    await store.receive(.delegate(.deliveryFailed(messageHash: big.hash)))
}
