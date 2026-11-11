import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

/// A path restored from disk at launch (`rehydrateLearnedDestinations`) must count as a known path
/// for the router, as a path learned from a live announce does. Before this, the router's
/// `knownPaths` was fed only by `.pathLearned`, so the first send to any contact after a relaunch
/// parked in `.awaitingPath` ("Looking for them") despite Transport holding a valid route, and a
/// cached path response could not release it (it never beats the identical restored entry).

private let iface = InterfaceID("rehydrated-path-iface")

@MainActor
private func makeNode(_ identity: Identity) -> TestStoreOf<LXMFNode> {
    let store = TestStore(initialState: LXMFNode.State(identity: identity, endpoint: TransportEndpoint.State())) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

/// A restored path to `peer`'s delivery destination, learned at `learnedAt` by Transport's clock
/// (epoch 0 under test).
private func restored(_ peer: Identity, learnedAt: TimeInterval = 0) -> [Data: LearnedDestination] {
    let dest = LXMessage.deliveryHash(identityHash: peer.hash)
    return [dest: LearnedDestination(identity: peer, appData: nil, ratchet: nil, interfaceID: iface, hops: 1,
                                     nextHop: dest, announceEmitted: 0,
                                     learnedAt: Date(timeIntervalSince1970: learnedAt))]
}

@MainActor
private func sendDirect(_ store: TestStoreOf<LXMFNode>, to dest: Data) async {
    await store.send(.send(destinationHash: dest, title: Data("t".utf8), content: Data("hi".utf8), method: .direct))
    await store.skipReceivedActions(strict: false)
}

@Suite @MainActor struct LXMFNodeRehydratedPathTests {
    @Test func aRestoredPathIsKnownToTheRouterSoTheFirstSendConnectsAtOnce() async {
        let peer = Identity()
        let dest = LXMessage.deliveryHash(identityHash: peer.hash)
        let store = makeNode(Identity())
        await store.send(.endpoint(.transport(.interfaceConnected(iface, .tcp))))
        await store.send(.endpoint(.transport(.rehydrateLearnedDestinations(restored(peer)))))
        #expect(store.state.router.knownPaths.contains(dest))
        await sendDirect(store, to: dest)
        #expect(store.state.router.directLinks[dest] == .establishing, "not parked looking for a path")
    }

    /// Only what Transport actually restored: an expired row is swept, so the router must not
    /// believe in it either.
    @Test func anExpiredRestoredPathIsNotKnownToTheRouter() async {
        let peer = Identity()
        let dest = LXMessage.deliveryHash(identityHash: peer.hash)
        let store = makeNode(Identity())
        await store.send(.endpoint(.transport(.interfaceConnected(iface, .tcp))))
        let longAgo = -(Transport.pathExpiry + 60)
        await store.send(.endpoint(.transport(.rehydrateLearnedDestinations(restored(peer, learnedAt: longAgo)))))
        #expect(store.state.endpoint.transport.learned[dest] == nil)
        #expect(!store.state.router.knownPaths.contains(dest))
    }
}
