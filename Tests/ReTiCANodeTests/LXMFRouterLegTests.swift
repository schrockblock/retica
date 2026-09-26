import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let pn = Data(repeating: 0xBB, count: 16)
private let pnLink = Data(repeating: 0xC0, count: 16)
private let small = Data("small-container".utf8)          // <= Link.mdu → proof-requesting link packet
private let large = Data(repeating: 0xAA, count: 432)     // >  Link.mdu → Resource

private func makeMessage(content: String = "two copies") -> LXMessage {
    LXMessage.create(source: Identity(),
                     destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                     timestamp: 1700000000.5, title: Data("t".utf8), content: Data(content.utf8))
}

/// A live link to the outbound propagation node, and a known path to `recipient`.
private func routerState(recipient: Data) -> LXMFRouter.State {
    var state = LXMFRouter.State()
    state.outboundPropagationNode = pn
    state.directLinks[pn] = .active(linkID: pnLink)
    state.knownPaths.insert(recipient)
    return state
}

@MainActor
private func makeStore(_ state: LXMFRouter.State,
                       clock: TestClock<Duration> = TestClock()) -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

@Test @MainActor func routerLegBothCopiesAreArmedSideBySide() async {
    let msg = makeMessage()
    let store = makeStore(routerState(recipient: msg.destinationHash))
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))
    #expect(store.state.pendingDeliveries.count == 2)
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)]?.resend
            == .opportunistic(destinationHash: msg.destinationHash, payload: msg.opportunisticPayload))
    #expect(store.state.pendingDeliveries[.propagated(msg.hash)]?.resend
            == .propagated(destinationHash: pn, data: small))
}

/// Regression for the collision: the propagated copy was armed LAST, and a receipt for the
/// delivery copy used to be reported as `propagationAccepted`. Exhaustive from the receipt on, so
/// a stray `propagationAccepted` fails the test.
@Test @MainActor func routerLegDeliveryReceiptAfterThePropagatedCopyIsArmedReportsDeliveryConfirmed() async {
    let msg = makeMessage()
    let store = makeStore(routerState(recipient: msg.destinationHash))
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))
    await store.skipReceivedActions()
    store.exhaustivity = .on
    await store.send(.delivered(messageHash: msg.hash, leg: .delivery)) {
        $0.pendingDeliveries[.delivery(msg.hash)] = nil
    }
    await store.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)] == nil)
    #expect(store.state.pendingDeliveries[.propagated(msg.hash)] != nil)   // the other copy is untouched
    // An exhaustive send fails if any received action (e.g. a stray `propagationAccepted`) is still
    // unhandled. A repeat receipt for the settled copy is itself a no-op.
    await store.send(.delivered(messageHash: msg.hash, leg: .delivery))
    // The absence window is over. The propagated copy's retry timer and the PN idle timer are still
    // running by design, so return to non-exhaustive teardown instead of asserting them.
    store.exhaustivity = .off
}

@Test @MainActor func routerLegPropagatedReceiptResolvesOnlyThePropagatedCopy() async {
    let msg = makeMessage()
    let store = makeStore(routerState(recipient: msg.destinationHash))
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))
    await store.send(.delivered(messageHash: msg.hash, leg: .propagated))
    await store.receive(.delegate(.propagationAccepted(messageHash: msg.hash)))
    #expect(store.state.pendingDeliveries[.propagated(msg.hash)] == nil)
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)] != nil)
}

/// One retry timer per copy: before, arming the second copy cancelled the first copy's timer.
@Test @MainActor func routerLegEachCopyRunsItsOwnRetryTimer() async {
    let msg = makeMessage()
    let clock = TestClock()
    let store = makeStore(routerState(recipient: msg.destinationHash), clock: clock)
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    let legs = LockIsolated<Set<LXMFRouter.Leg>>([])
    for _ in 0..<2 {
        await store.receive { action in
            guard case let .retryDue(hash, leg) = action, hash == msg.hash else { return false }
            legs.withValue { _ = $0.insert(leg) }
            return true
        }
    }
    #expect(legs.value == [.delivery, .propagated])
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)]?.attempts == 2)
    #expect(store.state.pendingDeliveries[.propagated(msg.hash)]?.attempts == 2)
}

/// A Resource conclusion resolves the copy that sent that Resource, not whichever was armed last.
@Test @MainActor func routerLegResourceConclusionResolvesTheCopyThatSentIt() async {
    let big = makeMessage(content: String(repeating: "y", count: 2000))
    #expect(big.directRepresentation == .resource)
    let recipientLink = Data(repeating: 0xEF, count: 16)
    var state = routerState(recipient: big.destinationHash)
    state.directLinks[big.destinationHash] = .active(linkID: recipientLink)
    let store = makeStore(state)
    await store.send(.send(message: big, desiredMethod: .direct))                  // Resource on the recipient link
    await store.send(.sendViaPropagation(message: big, propagationPacked: large))   // Resource on the PN link, armed LAST
    #expect(store.state.linkResourceInFlight[recipientLink] == LXMFRouter.DeliveryKey.delivery(big.hash))
    #expect(store.state.linkResourceInFlight[pnLink] == LXMFRouter.DeliveryKey.propagated(big.hash))

    await store.send(.resourceDeliveredOnLink(linkID: recipientLink))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: big.hash)))
    #expect(store.state.pendingDeliveries[.propagated(big.hash)] != nil)

    await store.send(.resourceDeliveredOnLink(linkID: pnLink))
    await store.receive(.delegate(.propagationAccepted(messageHash: big.hash)))
}

/// Link receipts come only from `sendPropagatedPacket` (the one receipted link send), so LXMFNode
/// routes them to the propagated copy.
@Test @MainActor func routerLegNodeRoutesLinkReceiptsToThePropagatedCopy() async {
    let store = TestStore(initialState: LXMFNode.State(
        identity: Identity(), endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    ) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    let hash = Data(repeating: 0x42, count: 32)
    await store.send(.endpoint(.delegate(.packetDelivered(token: hash))))
    await store.receive(.router(.delivered(messageHash: hash, leg: .propagated)))
    await store.send(.endpoint(.delegate(.packetDeliveryFailed(token: hash))))
    await store.receive(.router(.retryDue(messageHash: hash, leg: .propagated)))
}
