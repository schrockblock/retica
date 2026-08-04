import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// Link classification: data arriving on the link that terminates on OUR served lxmf.propagation
/// destination is a propagation offer, not a direct message — the client must NOT try to deliver it.
/// Data on any other link keeps the existing direct-message behavior.
///
/// Verification strategy: send the propagation-link data while exhaustivity is .off, then flip to .on
/// before the otherLink send. Any stray .router(.received) that leaked from the propagation-link send
/// remains in the queue and causes a failure at the next send (unhandled effect in .on mode) or at
/// teardown. The positive assertion (otherLink receive) proves the guard is not simply disabling everything.
@MainActor @Test func clientIgnoresLinkDataOnServedPropagationLink() async {
    let identity = Identity()
    let servedPropHash = Data(repeating: 0x9A, count: 16)
    let otherHash = Data(repeating: 0x5B, count: 16)
    let servedLink = Data(repeating: 0xC1, count: 16)
    let otherLink = Data(repeating: 0xC2, count: 16)

    var initial = LXMFNode.State(identity: identity,
                                 endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    initial.propagationDestinationHash = servedPropHash

    let store = TestStore(initialState: initial) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off

    // Both links establish (setup, .off absorbs .router(.linkEstablished) effects).
    await store.send(.endpoint(.delegate(.linkEstablished(linkID: servedLink, destinationHash: servedPropHash))))
    await store.send(.endpoint(.delegate(.linkEstablished(linkID: otherLink, destinationHash: otherHash))))
    #expect(store.state.linkDestinations[servedLink] == servedPropHash)
    #expect(store.state.linkDestinations[otherLink] == otherHash)

    // Data on the served propagation link must NOT reach the router: send while .off, then flip to .on.
    // A stray .router(.received) from the propagation link would survive as an unhandled effect and
    // fail teardown (or the next send in .on mode).
    await store.send(.endpoint(.delegate(.linkDataReceived(linkID: servedLink, data: Data("container".utf8)))))
    store.exhaustivity = .on   // a stray .router(.received) from the propagation link would fail teardown

    // Data on any other link keeps the existing direct-message path.
    // This also proves the guard is not simply disabling everything.
    await store.send(.endpoint(.delegate(.linkDataReceived(linkID: otherLink, data: Data("msg".utf8)))))
    await store.receive { if case .router(.received) = $0 { return true }; return false }
}
