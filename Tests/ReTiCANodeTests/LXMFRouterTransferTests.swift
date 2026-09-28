import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

// Transfer-aware delivery, Task 3: a copy sent as a Resource is decided by its transfer. No retry
// timer runs while it is in flight; a failure closes the link and retries once, 10 s later, on a
// fresh link; a rejection is terminal; a link lost mid-transfer sends the copy back to retrying.

private let recipient = Data(repeating: 0xD5, count: 16)
private let recipientLink = Data(repeating: 0xEF, count: 16)
private let freshLink = Data(repeating: 0xF0, count: 16)
private let pn = Data(repeating: 0xBB, count: 16)
private let pnLink = Data(repeating: 0xC0, count: 16)
private let large = Data(repeating: 0xAA, count: 432)        // > Link.mdu → Resource
private let small = Data("small-container".utf8)            // <= Link.mdu → link packet
/// An exhaustive no-op: no link is in flight on it, so it changes nothing and emits nothing — and
/// under `.on` it fails if any earlier received action is still unasserted.
/// `@MainActor`: `LXMFRouter.Action` is not `Sendable`, and every use site is an `@MainActor` test —
/// required for this global to compile under this package's Swift 6 strict concurrency checking.
@MainActor private let probe = LXMFRouter.Action.resourceFailedOnLink(linkID: Data(repeating: 0x99, count: 16), rejected: false)

private func bigMessage(_ fill: String = "y") -> LXMessage {
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
private func transferStore(_ state: LXMFRouter.State, _ clock: TestClock<Duration>)
    -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

@Test @MainActor func routerTransferResourceCopyArmsNoRetryTimer() async {
    let big = bigMessage()
    #expect(big.directRepresentation == .resource)
    let key = LXMFRouter.DeliveryKey.delivery(big.hash)
    let clock = TestClock()
    let store = transferStore(liveRecipient(), clock)
    store.exhaustivity = .on
    await store.send(.send(message: big, desiredMethod: .direct)) {
        $0.pendingDeliveries[key] = LXMFRouter.PendingDelivery(
            resend: .direct(destinationHash: recipient, data: big.packed, asResource: true),
            attempts: 1, phase: .transferring)
        $0.linkResourceInFlight[recipientLink] = key
    }
    await store.receive(.delegate(.sendDirect(linkID: recipientLink, data: big.packed, asResource: true)))
    // The old saga resent every 10 s and failed at 50 s. Now nothing may happen.
    await clock.advance(by: .seconds(60))
    await store.send(probe)
    store.exhaustivity = .off   // the recipient link's idle timer runs on by design
}

@Test @MainActor func routerTransferFailureClosesTheLinkAndArmsOneRetry() async {
    let big = bigMessage()
    let key = LXMFRouter.DeliveryKey.delivery(big.hash)
    let clock = TestClock()
    let store = transferStore(liveRecipient(), clock)
    await store.send(.send(message: big, desiredMethod: .direct))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.resourceFailedOnLink(linkID: recipientLink, rejected: false)) {
        $0.linkResourceInFlight[recipientLink] = nil
        $0.directLinks[recipient] = nil
        $0.pendingDeliveries[key]?.phase = .retrying
    }
    await store.receive(.delegate(.closeLink(destinationHash: recipient)))
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds - 1))
    await store.send(probe)                                    // nothing before the 10 s wait is up
    await clock.advance(by: .seconds(1))
    await store.receive(.retryDue(messageHash: big.hash, leg: .delivery)) {
        $0.pendingDeliveries[key]?.attempts = 2
    }
    store.exhaustivity = .off   // the link is down, so that retry re-armed its timer
}

@Test @MainActor func routerTransferRetryAfterFailureStartsAFreshTransferOnTheNewLink() async {
    let big = bigMessage()
    let key = LXMFRouter.DeliveryKey.delivery(big.hash)
    let clock = TestClock()
    let store = transferStore(liveRecipient(), clock)
    await store.send(.send(message: big, desiredMethod: .direct))
    await store.send(.resourceFailedOnLink(linkID: recipientLink, rejected: false))
    await store.receive(.delegate(.closeLink(destinationHash: recipient)))
    await store.send(.linkEstablished(destinationHash: recipient, linkID: freshLink))
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive(.delegate(.sendDirect(linkID: freshLink, data: big.packed, asResource: true)))
    #expect(store.state.pendingDeliveries[key]?.attempts == 2)
    #expect(store.state.pendingDeliveries[key]?.phase == .transferring)
    #expect(store.state.linkResourceInFlight == [freshLink: key])
}

@Test @MainActor func routerTransferFifthFailureFailsTheCopy() async {
    let big = bigMessage()
    let key = LXMFRouter.DeliveryKey.delivery(big.hash)
    let clock = TestClock()
    let store = transferStore(liveRecipient(), clock)
    await store.send(.send(message: big, desiredMethod: .direct))
    var current = recipientLink
    for attempt in 1..<LXMFDelivery.maxAttempts {
        let next = Data(repeating: 0xF0 + UInt8(attempt), count: 16)
        await store.send(.resourceFailedOnLink(linkID: current, rejected: false))
        await store.send(.linkEstablished(destinationHash: recipient, linkID: next))
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
        await store.receive(.delegate(.sendDirect(linkID: next, data: big.packed, asResource: true)))
        current = next
    }
    #expect(store.state.pendingDeliveries[key]?.attempts == LXMFDelivery.maxAttempts)
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.resourceFailedOnLink(linkID: current, rejected: false)) {
        $0.linkResourceInFlight[current] = nil
        $0.directLinks[recipient] = nil
        $0.pendingDeliveries[key] = nil
    }
    await store.receive(.delegate(.closeLink(destinationHash: recipient)))
    await store.receive(.delegate(.deliveryFailed(messageHash: big.hash)))
    await store.send(probe)
    store.exhaustivity = .off
}

@Test @MainActor func routerTransferRejectionFailsImmediatelyWithNoRetry() async {
    let big = bigMessage()
    let key = LXMFRouter.DeliveryKey.delivery(big.hash)
    let clock = TestClock()
    let store = transferStore(liveRecipient(), clock)
    await store.send(.send(message: big, desiredMethod: .direct))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.resourceFailedOnLink(linkID: recipientLink, rejected: true)) {
        $0.linkResourceInFlight[recipientLink] = nil
        $0.pendingDeliveries[key] = nil
    }
    await store.receive(.delegate(.deliveryRejected(messageHash: big.hash)))
    await clock.advance(by: .seconds(60))
    await store.send(probe)
    #expect(store.state.directLinks[recipient] == .active(linkID: recipientLink))   // a rejection keeps the link
    store.exhaustivity = .off
}

@Test @MainActor func routerTransferRejectionWaitsForTheOtherCopy() async {
    let big = bigMessage()
    var state = liveRecipient()
    state.outboundPropagationNode = pn
    state.directLinks[pn] = .active(linkID: pnLink)
    let store = transferStore(state, TestClock())
    await store.send(.send(message: big, desiredMethod: .direct))
    await store.send(.sendViaPropagation(message: big, propagationPacked: small))   // armed packet copy
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.resourceFailedOnLink(linkID: recipientLink, rejected: true)) {
        $0.linkResourceInFlight[recipientLink] = nil
        $0.pendingDeliveries[.delivery(big.hash)] = nil
    }
    await store.send(probe)                                    // no deliveryRejected while the other copy runs
    store.exhaustivity = .off
}

@Test @MainActor func routerTransferRetryDueForATransferringCopyIsANoOp() async {
    let big = bigMessage()
    let store = transferStore(liveRecipient(), TestClock())
    await store.send(.send(message: big, desiredMethod: .direct))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.retryDue(messageHash: big.hash, leg: .delivery))   // no attempt counted, nothing resent
    await store.send(probe)
    store.exhaustivity = .off
}

/// A closing link reaps its transfers without any `resourceFailed`, so the router itself must send
/// the orphaned copy back to retrying — or it would sit in `.transferring` forever.
@Test @MainActor func routerTransferLinkClosedMidTransferRequeuesTheCopy() async {
    let big = bigMessage()
    let key = LXMFRouter.DeliveryKey.delivery(big.hash)
    let clock = TestClock()
    let store = transferStore(liveRecipient(), clock)
    await store.send(.send(message: big, desiredMethod: .direct))
    await store.send(.linkClosed(destinationHash: recipient))
    #expect(store.state.linkResourceInFlight[recipientLink] == nil)
    #expect(store.state.pendingDeliveries[key]?.phase == .retrying)
    await store.receive(.delegate(.requestLink(destinationHash: recipient)))
    await store.send(.linkEstablished(destinationHash: recipient, linkID: freshLink))
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive(.delegate(.sendDirect(linkID: freshLink, data: big.packed, asResource: true)))
    #expect(store.state.pendingDeliveries[key]?.attempts == 2)
}

/// Ruling P6: a link lost mid-transfer is itself a failed attempt (`orphanTransfer`). If the copy
/// already used its last transfer, losing the link must fail it outright — not arm a sixth.
@Test @MainActor func routerTransferLinkLostAtMaxAttemptsFailsTheCopy() async {
    let big = bigMessage()
    let key = LXMFRouter.DeliveryKey.delivery(big.hash)
    let clock = TestClock()
    let store = transferStore(liveRecipient(), clock)
    await store.send(.send(message: big, desiredMethod: .direct))
    var current = recipientLink
    for attempt in 1..<LXMFDelivery.maxAttempts {
        let next = Data(repeating: 0xF0 + UInt8(attempt), count: 16)
        await store.send(.resourceFailedOnLink(linkID: current, rejected: false))
        await store.send(.linkEstablished(destinationHash: recipient, linkID: next))
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
        await store.receive(.delegate(.sendDirect(linkID: next, data: big.packed, asResource: true)))
        current = next
    }
    #expect(store.state.pendingDeliveries[key]?.attempts == LXMFDelivery.maxAttempts)
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.linkClosed(destinationHash: recipient)) {
        $0.linkResourceInFlight[current] = nil
        $0.directLinks[recipient] = nil
        $0.pendingDeliveries[key] = nil
    }
    await store.receive(.delegate(.deliveryFailed(messageHash: big.hash)))
    await clock.advance(by: .seconds(60))
    await store.send(probe)
    store.exhaustivity = .off
}

@Test @MainActor func routerTransferPropagatedFailureRetriesTheSameBytesOnAFreshLink() async {
    let msg = bigMessage("p")
    let key = LXMFRouter.DeliveryKey.propagated(msg.hash)
    var state = LXMFRouter.State()
    state.outboundPropagationNode = pn
    state.directLinks[pn] = .active(linkID: pnLink)
    state.knownPaths.insert(pn)
    let clock = TestClock()
    let store = transferStore(state, clock)
    await store.send(.sendViaPropagation(message: msg, propagationPacked: large))
    await store.receive(.delegate(.sendPropagated(linkID: pnLink, propagationPacked: large)))
    await store.send(.resourceFailedOnLink(linkID: pnLink, rejected: false))
    await store.receive(.delegate(.closeLink(destinationHash: pn)))
    await store.send(.linkEstablished(destinationHash: pn, linkID: freshLink))
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive(.delegate(.sendPropagated(linkID: freshLink, propagationPacked: large)))   // same bytes
    #expect(store.state.pendingDeliveries[key]?.attempts == 2)
}
