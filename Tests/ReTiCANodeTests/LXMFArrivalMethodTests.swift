import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private func makeMessage(to recipient: Identity = Identity()) -> LXMessage {
    LXMessage.create(source: Identity(), destinationHash: LXMessage.deliveryHash(identityHash: recipient.hash),
                     timestamp: 1700000000.5, title: Data("t".utf8), content: Data("arrived".utf8))
}

@MainActor
private func makeRouter() -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    return store
}

@MainActor
private func makeNode(_ state: LXMFNode.State) -> TestStore<LXMFNode.State, LXMFNode.Action> {
    let store = TestStore(initialState: state) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

@MainActor
private func expectDelivered(_ store: TestStore<LXMFRouter.State, LXMFRouter.Action>, _ msg: LXMessage,
                             via expected: LXMFRouter.DeliveryMethod) async {
    await store.receive { action in
        guard case let .delegate(.messageDelivered(m, _, method)) = action else { return false }
        return m.hash == msg.hash && method == expected
    }
}

@Test @MainActor func arrivalMethodRouterReportsOpportunistic() async {
    let msg = makeMessage()
    let store = makeRouter()
    await store.send(.received(method: .opportunistic, destinationHash: msg.destinationHash, data: msg.opportunisticPayload))
    await expectDelivered(store, msg, via: .opportunistic)
}

@Test @MainActor func arrivalMethodRouterReportsDirect() async {
    let msg = makeMessage()
    let store = makeRouter()
    await store.send(.received(method: .direct, destinationHash: msg.destinationHash, data: msg.packed))
    await expectDelivered(store, msg, via: .direct)
}

/// `.propagated` carries the full packed message, like `.direct`, and is reconstructed the same way.
@Test @MainActor func arrivalMethodRouterReportsPropagated() async {
    let msg = makeMessage()
    let store = makeRouter()
    await store.send(.received(method: .propagated, destinationHash: msg.destinationHash, data: msg.packed))
    await expectDelivered(store, msg, via: .propagated)
}

/// Dedup is unchanged, so the FIRST arrival's method is the one reported.
@Test @MainActor func arrivalMethodFirstArrivalWins() async {
    let msg = makeMessage()
    let store = makeRouter()
    await store.send(.received(method: .propagated, destinationHash: msg.destinationHash, data: msg.packed))
    await expectDelivered(store, msg, via: .propagated)
    await store.send(.received(method: .opportunistic, destinationHash: msg.destinationHash, data: msg.opportunisticPayload))
    await store.receive(.delegate(.duplicateDropped(hash: msg.hash)))
}

@Test @MainActor func arrivalMethodNodeSurfacesTheMethod() async {
    let store = makeNode(LXMFNode.State(identity: Identity(),
                                        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false)))
    let msg = makeMessage()
    await store.send(.router(.delegate(.messageDelivered(message: msg, signatureValidated: true, method: .propagated))))
    await store.receive(.delegate(.messageReceived(message: msg, signatureValidated: true, method: .propagated)))
}

/// Messages downloaded from a propagation node reach the router as `.propagated`, not `.direct`.
@Test @MainActor func arrivalMethodNodeFeedsDownloadedMessagesAsPropagated() async {
    let me = Identity()
    let msg = makeMessage(to: me)
    let entry = LXMFPropagation.lxmfData(destinationHash: msg.destinationHash,
                                         encryptedData: me.encrypt(Data(msg.packed.dropFirst(LXMessage.destinationLength))))
    let linkID = Data(repeating: 0xA7, count: 16)
    var state = LXMFNode.State(identity: me, endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    state.syncPhase[linkID] = .awaitingMessages
    let store = makeNode(state)
    await store.send(.endpoint(.delegate(.responseReceived(linkID: linkID, requestID: Data(repeating: 1, count: 16),
                                                           data: MsgPack.encode(.array([.bin(entry)]))))))
    await store.receive(.router(.received(method: .propagated, destinationHash: Data(), data: msg.packed)))
}

/// A propagated copy needs a packed propagation container and goes through `.sendViaPropagation`;
/// `.send` cannot build one, so asking it for `.propagated` fails the copy instead of silently
/// sending it some other way.
@Test @MainActor func arrivalMethodSendingWithThePropagatedMethodFailsTheCopy() async {
    let msg = makeMessage()
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    await store.send(.send(message: msg, desiredMethod: .propagated))
    await store.receive(.delegate(.deliveryFailed(messageHash: msg.hash)))
}
