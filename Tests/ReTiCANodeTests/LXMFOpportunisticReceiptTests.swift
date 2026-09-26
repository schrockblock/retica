import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let pn = Data(repeating: 0xBB, count: 16)
private let pnLink = Data(repeating: 0xC0, count: 16)

private func makeMessage() -> LXMessage {
    LXMessage.create(source: Identity(),
                     destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                     timestamp: 1700000000.5, title: Data("t".utf8), content: Data("receipted".utf8))
}

@MainActor
private func makeRouter(_ state: LXMFRouter.State,
                        clock: TestClock<Duration> = TestClock()) -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

@MainActor
private func makeNode() -> TestStore<LXMFNode.State, LXMFNode.Action> {
    let store = TestStore(initialState: LXMFNode.State(
        identity: Identity(), endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    ) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

@Test @MainActor func opportunisticReceiptSendCarriesTheMessageHash() async {
    let msg = makeMessage()
    let store = makeRouter(LXMFRouter.State())
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.receive(.delegate(.sendOpportunistic(destinationHash: msg.destinationHash,
                                                     payload: msg.opportunisticPayload,
                                                     messageHash: msg.hash)))
}

/// A proof confirms the delivery copy, and no retry survives it.
@Test @MainActor func opportunisticReceiptConfirmsAndCancelsTheRetry() async {
    let msg = makeMessage()
    let clock = TestClock()
    var state = LXMFRouter.State()
    state.knownPaths.insert(msg.destinationHash)
    let store = makeRouter(state, clock: clock)
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.opportunisticDelivered(messageHash: msg.hash))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    #expect(store.state.pendingDeliveries.isEmpty)
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on   // a retry that outlived the proof is an unexpected action at teardown
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds * LXMFDelivery.maxAttempts))
}

/// Each resend carries the same message hash (so its packet gets a receipt under the same token),
/// and a proof for the RESEND confirms the message.
@Test @MainActor func opportunisticReceiptProofOfTheResendConfirms() async {
    let msg = makeMessage()
    let clock = TestClock()
    var state = LXMFRouter.State()
    state.knownPaths.insert(msg.destinationHash)
    let store = makeRouter(state, clock: clock)
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.receive { if case .delegate(.sendOpportunistic) = $0 { return true }; return false }   // first send
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { action in                                                                    // the resend
        guard case let .delegate(.sendOpportunistic(_, _, hash)) = action else { return false }
        return hash == msg.hash
    }
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)]?.attempts == 2)
    await store.send(.opportunisticDelivered(messageHash: msg.hash))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
}

@Test @MainActor func opportunisticReceiptDoesNotTouchThePropagatedCopy() async {
    let msg = makeMessage()
    var state = LXMFRouter.State()
    state.outboundPropagationNode = pn
    state.directLinks[pn] = .active(linkID: pnLink)
    let store = makeRouter(state)
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: Data("small".utf8)))
    await store.send(.opportunisticDelivered(messageHash: msg.hash))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    #expect(store.state.pendingDeliveries[.propagated(msg.hash)] != nil)
}

@Test @MainActor func opportunisticReceiptNodeSendsWithTheMessageHashAsToken() async {
    let store = makeNode()
    let dest = Data(repeating: 0xD2, count: 16)
    let payload = Data("p".utf8)
    let hash = Data(repeating: 0x43, count: 32)
    await store.send(.router(.delegate(.sendOpportunistic(destinationHash: dest, payload: payload, messageHash: hash))))
    await store.receive(.endpoint(.send(destinationHash: dest, plaintext: payload, receiptToken: hash)))
}

@Test @MainActor func opportunisticReceiptNodeRoutesSinglePacketDelivered() async {
    let store = makeNode()
    let hash = Data(repeating: 0x44, count: 32)
    await store.send(.endpoint(.delegate(.singlePacketDelivered(token: hash))))
    await store.receive(.router(.opportunisticDelivered(messageHash: hash)))
}
