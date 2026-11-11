import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

/// A destination parked in `.awaitingPath` must leave the park once Transport holds a usable route
/// to it, even when no `.pathLearned` ever comes: the answers to its path requests are usually a
/// hub's cached copy of the very announce that route came from, which never beats it. Seen on a
/// device (2026-11-11): the propagation node was parked at launch, before the saved paths loaded,
/// then re-requested five times and gave up, so every fallback copy failed with a good route held.
/// A route a link has just FAILED on is the exception: the router does not retry it.

private let iface = InterfaceID("parked-path-iface")

@MainActor
private func makeNode(_ me: Identity, _ clock: TestClock<Duration>) -> TestStoreOf<LXMFNode> {
    let store = TestStore(initialState: LXMFNode.State(identity: me, endpoint: TransportEndpoint.State())) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

private func route(to peer: Identity) -> [Data: LearnedDestination] {
    let dest = LXMessage.deliveryHash(identityHash: peer.hash)
    return [dest: LearnedDestination(identity: peer, appData: nil, ratchet: nil, interfaceID: iface, hops: 1,
                                     nextHop: dest, announceEmitted: 0, learnedAt: Date(timeIntervalSince1970: 0))]
}

/// Hand the router a direct message for `dest`, as `LXMFNode` does after stamping.
@MainActor
private func routerSend(_ store: TestStoreOf<LXMFNode>, from me: Identity, to dest: Data) async {
    let message = LXMessage.create(source: me, destinationHash: dest, timestamp: 1700000000,
                                   title: Data(), content: Data("hi".utf8))
    await store.send(.router(.send(message: message, desiredMethod: .direct)))
    await store.skipReceivedActions(strict: false)
}

@Suite @MainActor struct LXMFNodeParkedPathTests {
    /// The device trace: parked before the saved paths loaded, the route restored meanwhile, and the
    /// next park deadline must open the link rather than ask again.
    @Test func aParkedDestinationConnectsOnceTransportHoldsARoute() async {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let dest = LXMessage.deliveryHash(identityHash: peer.hash)
        let store = makeNode(me, clock)
        await store.send(.endpoint(.transport(.interfaceConnected(iface, .tcp))))
        await routerSend(store, from: me, to: dest)
        #expect(store.state.router.directLinks[dest] == .awaitingPath, "no route yet: parked")
        await store.send(.endpoint(.transport(.rehydrateLearnedDestinations(route(to: peer)))))
        await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.router.directLinks[dest] == .establishing)
    }

    /// A route whose link just timed out is not handed straight back to the router.
    @Test func aRouteALinkJustFailedOnIsNotRetried() async {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let dest = LXMessage.deliveryHash(identityHash: peer.hash)
        let store = makeNode(me, clock)
        await store.send(.endpoint(.transport(.interfaceConnected(iface, .tcp))))
        await store.send(.endpoint(.transport(.rehydrateLearnedDestinations(route(to: peer)))))
        await routerSend(store, from: me, to: dest)
        #expect(store.state.router.directLinks[dest] == .establishing)
        await store.send(.endpoint(.delegate(.linkFailed(destinationHash: dest, reason: .establishmentTimedOut))))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.router.directLinks[dest] == .awaitingPath)
        await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.router.directLinks[dest] == .awaitingPath, "still waiting for a different route")
    }
}
