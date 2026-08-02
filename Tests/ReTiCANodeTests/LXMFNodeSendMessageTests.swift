import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

@MainActor
private func makeNode(identity: Identity, seedLearned: Identity?, dest: Data,
                      pn: Data?) -> TestStore<LXMFNode.State, LXMFNode.Action> {
    var ep = Endpoint.State(host: "h", port: 4242, reconnectOnDrop: false)
    if let r = seedLearned {
        ep.transport.learned[dest] = LearnedDestination(
            identity: r, appData: nil, ratchet: nil, interfaceID: InterfaceID("tcp"),
            hops: 1, nextHop: nil, announceEmitted: 0)
    }
    var node = LXMFNode.State(identity: identity, endpoint: ep)
    // Seed the router so the opportunistic send can arm, and (when set) propagation can arm.
    node.router.knownIdentities[dest] = seedLearned ?? Identity()
    node.router.knownPaths.insert(dest)
    if let pn { node.router.outboundPropagationNode = pn }
    let store = TestStore(initialState: node) { LXMFNode() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.continuousClock = TestClock()
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } },
                                         send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

private func isPropagated(_ resend: LXMFRouter.ResendInfo?) -> Bool {
    if case .propagated = resend { return true }; return false
}
private func isOpportunistic(_ resend: LXMFRouter.ResendInfo?) -> Bool {
    if case .opportunistic = resend { return true }; return false
}

@MainActor @Test func sendMessageFlagFalseSendsOpportunisticOnly() async {
    let me = Identity(); let recipient = Identity()
    let dest = Data(repeating: 0xA1, count: 16)
    let store = makeNode(identity: me, seedLearned: recipient, dest: dest, pn: Data(repeating: 0xC0, count: 16))
    let msg = LXMessage.create(source: me, destinationHash: dest, timestamp: 1700000000,
                               title: Data(), content: Data("x".utf8))
    await store.send(.sendMessage(message: msg, alsoViaPropagation: false))
    await store.receive { if case let .router(.send(m, method)) = $0 { return m == msg && method == .opportunistic }; return false }
    #expect(isOpportunistic(store.state.router.pendingDeliveries[msg.hash]?.resend))
}

@MainActor @Test func sendMessageFlagTrueKnownIdentitySendsBoth() async {
    let me = Identity(); let recipient = Identity()
    let dest = Data(repeating: 0xA2, count: 16)
    let store = makeNode(identity: me, seedLearned: recipient, dest: dest, pn: Data(repeating: 0xC0, count: 16))
    let msg = LXMessage.create(source: me, destinationHash: dest, timestamp: 1700000000,
                               title: Data(), content: Data("x".utf8))
    await store.send(.sendMessage(message: msg, alsoViaPropagation: true))
    await store.receive { if case let .router(.send(m, method)) = $0 { return m == msg && method == .opportunistic }; return false }
    await store.receive { if case let .router(.sendViaPropagation(m, _)) = $0 { return m == msg }; return false }
    #expect(isPropagated(store.state.router.pendingDeliveries[msg.hash]?.resend))
}

@MainActor @Test func sendMessageFlagTrueUnknownIdentitySkipsPropagation() async {
    let me = Identity()
    let dest = Data(repeating: 0xA3, count: 16)
    // NOTE: seedLearned nil → transport.learned has no identity for dest → propagation must be skipped.
    let store = makeNode(identity: me, seedLearned: nil, dest: dest, pn: Data(repeating: 0xC0, count: 16))
    let msg = LXMessage.create(source: me, destinationHash: dest, timestamp: 1700000000,
                               title: Data(), content: Data("x".utf8))
    await store.send(.sendMessage(message: msg, alsoViaPropagation: true))
    await store.receive { if case let .router(.send(m, method)) = $0 { return m == msg && method == .opportunistic }; return false }
    #expect(isOpportunistic(store.state.router.pendingDeliveries[msg.hash]?.resend))
}
