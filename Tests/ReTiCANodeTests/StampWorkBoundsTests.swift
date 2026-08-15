import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// Two proof-of-work searches in this package are driven by a cost an **unauthenticated peer chooses**
/// and run inside a `.run` effect: the propagation stamp (`LXMFNode` → `LXStamper.generatePnStamp`,
/// cost from a wire PN announce) and the peering key (`PNNode` → `LXStamper.generatePeeringKey`, cost
/// from the peer's advertised peering cost). Both are exponential in the cost — 64 is ~2^64 rounds — so
/// each needs two independent guards:
///
///   1. a **ceiling on the cost**, so a hostile value cannot start unbounded work at all, and
///   2. a **`CancelID`**, so work we *did* legitimately start can be reclaimed when its reason dies.
///
/// A ceiling alone leaves a long-running effect that outlives its reason; a `CancelID` alone leaves a
/// hostile peer able to pin a core for as long as nobody notices. These tests cover both, per site.
///
/// **These tests are structurally binary, not timed.** Every one either completes promptly or cannot
/// complete at all: the refusal tests use a cost (64) whose search would never end, and the
/// cancellation tests use a cost at our own ceiling — legitimate, but minutes of work — so the store
/// can only finish if something cancelled it. `store.exhaustivity = .on` before `finish` is load-bearing:
/// TestStore's "an effect ... is still running" report is suppressed under `.off`
/// (`TestStore.reportIssueHelper`), so without the flip these tests would pass against an unkillable effect.
///
/// The `.timeLimit` on the cancellation tests is a **safety net, not a timing assertion**: cancelled,
/// they finish in well under a second. It exists because a search that does not yield its executor
/// starves the `TestStore`'s main serial executor, so the cancel can never be *delivered* and the test
/// would sit until the search happened to succeed — measured at 267 s for the cost-26 peering case,
/// i.e. it would have passed *vacuously*, having proven the opposite of its name. One minute against
/// a sub-second expectation is a 100x+ margin.
///
/// That the *CPU loop itself* stops (rather than merely its result being discarded) is proven
/// separately and at the pure layer, in `LXStamperCancellationTests` — TestStore drops a cancelled
/// effect from its in-flight set without knowing whether the underlying task actually stopped, so a
/// reducer-level test cannot make that claim on its own.

// MARK: - propagation stamp (LXMFNode, cost from a wire PN announce)

private let pnHash = Data(repeating: 0xC0, count: 16)
private let recipientDest = Data(repeating: 0xA1, count: 16)

@MainActor
private func makePropagationClient(advertisedStampCost: Int) -> TestStore<LXMFNode.State, LXMFNode.Action> {
    var ep = TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false)
    ep.transport.learned[recipientDest] = LearnedDestination(
        identity: Identity(), appData: nil, ratchet: nil, interfaceID: InterfaceID("tcp"),
        hops: 1, nextHop: nil, announceEmitted: 0)
    ep.transport.learned[pnHash] = LearnedDestination(
        identity: Identity(),
        appData: PNAnnounce(timebase: 0, nodeState: true, perTransferLimit: 0, perSyncLimit: 0,
                            targetStampCost: advertisedStampCost, stampCostFlexibility: 0,
                            peeringCost: 0).packed,
        ratchet: nil, interfaceID: InterfaceID("tcp"), hops: 1, nextHop: nil, announceEmitted: 0)
    var node = LXMFNode.State(identity: Identity(), endpoint: ep)
    node.router.outboundPropagationNode = pnHash
    let store = TestStore(initialState: node) { LXMFNode() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.continuousClock = TestClock()
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

/// A propagation node that advertises a stamp cost of 64 demands ~2^64 hash rounds over a 256 KB
/// workblock. The announce is unauthenticated app-data, so any peer on the network can put that number
/// there. Nothing may be started for it.
///
/// Reference does **not** bound this — `LXMRouter.get_outbound_propagation_cost` (LXMRouter.py:421-442)
/// returns the announced `pn_config[5][0]` verbatim and `pn_announce_data_is_valid` (LXMF.py:238-239)
/// only checks it is int-able. See `LXMFPropagation.maxPropagationStampCost` for why we diverge.
@MainActor @Test func lxmfNodeRefusesAnAbsurdAdvertisedPropagationStampCost() async {
    let store = makePropagationClient(advertisedStampCost: 64)
    await store.send(.sendViaPropagation(destinationHash: recipientDest, title: Data("t".utf8),
                                         content: Data("x".utf8)))
    store.exhaustivity = .on         // an unkillable stamp effect shows up here as "still running"
    await store.finish(timeout: .seconds(2))
}

/// The same refusal on the `.sendMessage(alsoViaPropagation:)` path, which builds its own effect:
/// the opportunistic copy must still go out, and only the propagation copy is skipped.
@MainActor @Test func lxmfNodeSendMessageRefusesAnAbsurdAdvertisedPropagationStampCost() async {
    let store = makePropagationClient(advertisedStampCost: 64)
    let me = Identity()
    let msg = LXMessage.create(source: me, destinationHash: recipientDest, timestamp: 1700000000,
                               title: Data(), content: Data("x".utf8))
    await store.send(.sendMessage(message: msg, alsoViaPropagation: true))
    await store.receive { if case let .router(.send(m, _)) = $0 { return m == msg }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.router.propagationQueue.isEmpty)
    // The queue being empty proves nothing on its own — an unrefused cost-64 search never delivers
    // either. What distinguishes the two is whether a stamp effect was *started*, so cancel the
    // opportunistic side (its retry timer is a legitimate long-lived effect) and require that nothing
    // is left running.
    await store.send(.router(.delivered(messageHash: msg.hash)))   // retires the opportunistic retry timer
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.finish(timeout: .seconds(2))
}

/// A cost we *do* accept still produces and delivers a propagation container — the bound refuses
/// absurd costs, it does not disable propagation.
@MainActor @Test func lxmfNodeStillPacksAtAnAcceptedPropagationStampCost() async {
    let store = makePropagationClient(advertisedStampCost: 4)
    await store.send(.sendViaPropagation(destinationHash: recipientDest, title: Data("t".utf8),
                                         content: Data("x".utf8)))
    await store.receive { if case .router(.sendViaPropagation) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
}

/// Cancellation, at a cost we accept. `maxPropagationStampCost` is ~2^20 rounds over a 256 KB
/// workblock — minutes of CPU — so the store can only finish because the effect was torn down.
/// This is the half a cost ceiling looks like it fixed but did not: a legitimate cost is still real
/// work, and when the user leaves, the app backgrounds or the send is abandoned it must be reclaimable.
@MainActor @Test(.timeLimit(.minutes(1))) func lxmfNodeCancelsInFlightPropagationStampGeneration() async {
    let store = makePropagationClient(advertisedStampCost: LXMFPropagation.maxPropagationStampCost)
    await store.send(.sendViaPropagation(destinationHash: recipientDest, title: Data("t".utf8),
                                         content: Data("x".utf8)))
    await store.send(.cancelPropagationStamps)
    store.exhaustivity = .on
    await store.finish(timeout: .seconds(10))
}

/// Pointing the client at a different propagation node also reclaims the work: every in-flight stamp
/// was sized to the *previous* node's advertised cost, and a stamp below a node's enforced
/// `minStampCost` is dropped by that node's ingest — so continuing to compute it can only waste the core.
@MainActor @Test(.timeLimit(.minutes(1))) func lxmfNodeCancelsPropagationStampGenerationWhenTheNodeChanges() async {
    let store = makePropagationClient(advertisedStampCost: LXMFPropagation.maxPropagationStampCost)
    await store.send(.sendViaPropagation(destinationHash: recipientDest, title: Data("t".utf8),
                                         content: Data("x".utf8)))
    await store.send(.setPropagationNode(destinationHash: Data(repeating: 0xC1, count: 16)))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.finish(timeout: .seconds(10))
}

// MARK: - peering key (PNNode, cost from the peer's advertised peering cost)

private let peerDest = Data(repeating: 0xD0, count: 16)
private let peerLinkID = Data(repeating: 0xD1, count: 16)

@MainActor
private func makePeeringNode(pendingCostForPeer: Int? = nil) -> TestStore<PNNode.State, PNNode.Action> {
    var initial = PNNode.State(identity: Identity(),
                               endpoint: TCPEndpoint.State(host: "a", port: 4242, reconnectOnDrop: false))
    initial.endpoint.transport.learned[peerDest] = LearnedDestination(
        identity: Identity(), appData: nil, ratchet: nil, interfaceID: initial.endpoint.interfaceID,
        hops: 1, nextHop: nil, announceEmitted: 0)
    if let pendingCostForPeer { initial.pendingSyncPeers[peerDest] = pendingCostForPeer }
    let store = TestStore(initialState: initial) { PNNode() } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

/// Reference refuses to peer above `MAX_PEERING_COST = 26` rather than clamping — "Not peering with …,
/// since its peering cost of {peering_cost} exceeds local maximum" (LXMRouter.py:2005-2010). Clamping
/// would be a silent failure: the cost is the peer's demand, so a cheaper key is one it will reject
/// (LXMPeer.py:228-233). We decline the same way, and the link is never even opened.
@MainActor @Test func pnNodeDeclinesToPeerAboveTheMaximumPeeringCost() async {
    let store = makePeeringNode()
    await store.send(.syncToPeer(destinationHash: peerDest,
                                 peeringCost: LXMFPropagation.maxPeeringCost + 1))
    #expect(store.state.pendingSyncPeers[peerDest] == nil)
    store.exhaustivity = .on         // an `openLink` would fail teardown as an unasserted action
    await store.finish(timeout: .seconds(2))
}

/// The ceiling is enforced where the work actually starts, not only at the `syncToPeer` entry:
/// `pendingSyncPeers` is public state, so a cost that got in by another route must still not start a
/// ~2^64-round search.
@MainActor @Test func pnNodeDoesNotGenerateAPeeringKeyForAnAbsurdCost() async {
    let store = makePeeringNode(pendingCostForPeer: 64)
    await store.send(.endpoint(.delegate(.linkEstablished(linkID: peerLinkID, destinationHash: peerDest))))
    #expect(store.state.pendingSyncPeers[peerDest] == nil)
    #expect(store.state.offerLinks[peerLinkID] == nil)   // no offer is prepared for a peer we decline
    store.exhaustivity = .on
    await store.finish(timeout: .seconds(2))
}

/// A cost at reference's own maximum is accepted — the search starts — and is then reclaimed when the
/// link it exists for closes. `maxPeeringCost` is ~2^26 rounds, minutes of CPU, so the store can only
/// finish because `linkClosed` cancelled it. Doubles as the pin that 26 is *accepted*, not refused.
@MainActor @Test(.timeLimit(.minutes(1))) func pnNodeCancelsPeeringKeyGenerationWhenTheLinkCloses() async {
    let store = makePeeringNode(pendingCostForPeer: LXMFPropagation.maxPeeringCost)
    await store.send(.endpoint(.delegate(.linkEstablished(linkID: peerLinkID, destinationHash: peerDest))))
    await store.receive { if case let .endpoint(.identifyOverLink(lid, _)) = $0 { return lid == peerLinkID }
                          return false }
    await store.send(.endpoint(.delegate(.linkClosed(linkID: peerLinkID, reason: .initiatorClosed))))
    store.exhaustivity = .on
    await store.finish(timeout: .seconds(10))
}

/// The same reclamation when the request the key was being generated for fails outright.
@MainActor @Test(.timeLimit(.minutes(1))) func pnNodeCancelsPeeringKeyGenerationWhenTheRequestFails() async {
    let store = makePeeringNode(pendingCostForPeer: LXMFPropagation.maxPeeringCost)
    await store.send(.endpoint(.delegate(.linkEstablished(linkID: peerLinkID, destinationHash: peerDest))))
    await store.receive { if case let .endpoint(.identifyOverLink(lid, _)) = $0 { return lid == peerLinkID }
                          return false }
    await store.send(.endpoint(.delegate(.requestFailed(linkID: peerLinkID, requestID: Data([1])))))
    store.exhaustivity = .on
    await store.finish(timeout: .seconds(10))
}
