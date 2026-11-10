import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// I1: a sync offers a peer only the entries it accepts. Reference computes
// `min_accepted_cost = max(0, cost - flex)` from the peer's announce and drops every entry whose stored
// stamp value is below it (LXMPeer.py:336-361); it sends no offer when nothing is left (:386-388), and
// postpones the sync while the peer's costs are unknown (:274-284). A reference peer that receives an
// entry it refuses tears the link down and throttles us (LXMRouter.py:2786-2793).
//
// Entries here are worth 13 to 24.5, which no test can mine, so their recorded values are seeded
// through `PropagationStore.setStampValue`; the value `ingest` records for a real stamp is tested in
// PropagationStoreTests.offerSetKeepsEntriesWhoseRecordedStampValueMeetsThePeerMinimum, and the
// formula against a real `LXMPeer.sync` in peerOfferFilterMatchesReferenceSync.

enum PNNodeOfferTestSupport {
    static func ids(_ value: MsgPackValue) -> [Data] {
        guard case let .array(items) = value else { return [] }
        return items.compactMap { if case let .bin(d) = $0 { return d } else { return nil } }
    }
}

private let peerDest = Data(repeating: 0xD0, count: 16)
private let peerLinkID = Data(repeating: 0xD1, count: 16)

/// Recorded stamp values of the held entries, oldest first; nil is an entry stored unvalidated.
private let heldValues: [Double?] = [nil, 12.99609375, 13.0, 13.24609375, 13.25, 16.0, 19.99609375, 20.0, 24.5]

private func heldEntry(_ index: Int) -> Data {
    Data(repeating: 0xAB, count: 16) + Data("held-\(index)".utf8)
}

private func heldId(_ index: Int) -> Data { LXMFPropagation.transientId(lxmfData: heldEntry(index)) }

/// The held ids whose value (nil as 0) is at least `minimum`, oldest first: the expected offer.
private func idsAtOrAbove(_ minimum: Double) -> [Data] {
    heldValues.indices.filter { (heldValues[$0] ?? 0) >= minimum }.map(heldId)
}

/// A node holding `heldValues`, whose peer has announced `announce` (or nothing), and, when
/// `pendingPeeringCost` is set, is waiting for its sync link to that peer.
@MainActor
private func makeNode(announce: Data?, pendingPeeringCost: Double? = nil,
                      offerLink: [Data]? = nil) -> TestStore<PNNode.State, PNNode.Action> {
    var initial = PNNode.State(identity: Identity(),
                               endpoint: TCPEndpoint.State(host: "a", port: 4242, reconnectOnDrop: false),
                               targetStampCost: 0)
    let entries = heldValues.indices.map(heldEntry)
    let added = initial.node.store.ingest(container: LXMFPropagation.container(timestamp: 1700000000, entries: entries), now: Date(timeIntervalSince1970: 1700000000)).added
    precondition(added == heldValues.indices.map(heldId), "setup: every entry is held, in order")
    for (index, value) in heldValues.enumerated() {
        initial.node.store.setStampValue(value, forTransientId: heldId(index))
    }
    initial.endpoint.transport.learned[peerDest] = LearnedDestination(
        identity: Identity(), appData: announce, ratchet: nil,
        interfaceID: initial.endpoint.tcpClients[0].interfaceID, hops: 1, nextHop: nil, announceEmitted: 0)
    initial.endpoint.transport.interfaces[initial.endpoint.tcpClients[0].interfaceID] = .tcp
    if let pendingPeeringCost { initial.pendingSyncPeers[peerDest] = pendingPeeringCost }
    if let offerLink { initial.offerLinks[peerLinkID] = offerLink }
    let store = TestStore(initialState: initial) { PNNode() } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

private func announce(cost: Double, flexibility: Double) -> Data {
    PNAnnounce(timebase: 0, nodeState: true, perTransferLimit: 256, perSyncLimit: 10240,
               targetStampCost: cost, stampCostFlexibility: flexibility, peeringCost: 0).packed
}

/// The ids in the `/offer` this node sends once its sync link is established (peering cost 0, so the
/// key is found at once).
@MainActor
private func offeredIds(cost: Double, flexibility: Double) async -> [Data] {
    let store = makeNode(announce: announce(cost: cost, flexibility: flexibility), pendingPeeringCost: 0)
    await store.send(.endpoint(.delegate(.linkEstablished(linkID: peerLinkID, destinationHash: peerDest))))
    let got = LockIsolated<[Data]?>(nil)
    await store.receive({ action in
        if case let .endpoint(.sendRequestOverLink(lid, path, data)) = action, lid == peerLinkID, path == "/offer",
           case let .array(items)? = MsgPack.decodeValue(data), items.count >= 2 {
            got.setValue(PNNodeOfferTestSupport.ids(items[1]))
            return true
        }
        return false
    }, timeout: .seconds(10))
    await store.skipReceivedActions(strict: false)
    return got.value ?? []
}

/// A reference-default peer at cost 20, flexibility 0 accepts at 20, so only the entries worth 20 and
/// 24.5 are offered; 19.99609375 is one 1/256 step short. At 16 - 3 the minimum is 13: 13.0 is offered,
/// 12.99609375 is not. At 16.5 - 3.25 it is the fractional 13.25: 13.24609375 is not.
///
/// Anti-vacuity: each case's expected set is a strict, non-empty subset of what is held, and the three
/// differ, so offering everything, using the cost without the flexibility, or rounding the minimum fails.
@MainActor @Test func pnNodeOffersAPeerOnlyEntriesAtOrAboveItsCostMinusFlexibility() async {
    let at20 = await offeredIds(cost: 20, flexibility: 0)
    #expect(at20 == [heldId(7), heldId(8)])
    #expect(at20 == idsAtOrAbove(20))

    let at13 = await offeredIds(cost: 16, flexibility: 3)
    #expect(at13 == idsAtOrAbove(13))
    #expect(at13.first == heldId(2))                       // 13.0 in, 12.99609375 out

    let at1325 = await offeredIds(cost: 16.5, flexibility: 3.25)
    #expect(at1325 == idsAtOrAbove(13.25))
    #expect(at1325.first == heldId(4))                     // 13.25 in, 13.24609375 out
}

/// Hostile and odd announces, as reference's `max(0, cost - flex)` reads them: a NaN cost, -infinity, and
/// a flexibility above the cost all accept at 0, so every entry is offered, including the unvalidated one.
@MainActor @Test func pnNodeOffersEverythingToAPeerAcceptingAtZero() async {
    for (cost, flexibility) in [(Double.nan, 3.0), (-.infinity, 0), (8, 12)] {
        let ids = await offeredIds(cost: cost, flexibility: flexibility)
        #expect(ids == heldValues.indices.map(heldId), "cost \(cost) flex \(flexibility)")
    }
}

/// Nothing qualifies (a peer at +infinity, or at 25 above everything held): no offer and no peering-key
/// search, as reference returns before offering. The pending peering cost is 26, minutes of work, so the
/// store can only finish inside its timeout if no search started. The identify still goes out.
@MainActor @Test(.timeLimit(.minutes(1))) func pnNodeSkipsTheKeySearchAndOfferWhenNothingQualifies() async {
    for cost in [Double.infinity, 25] {
        let store = makeNode(announce: announce(cost: cost, flexibility: 0),
                             pendingPeeringCost: LXMFPropagation.maxPeeringCost)
        await store.send(.endpoint(.delegate(.linkEstablished(linkID: peerLinkID, destinationHash: peerDest))))
        await store.receive { if case let .endpoint(.identifyOverLink(lid, _)) = $0 { return lid == peerLinkID }
                              return false }
        #expect(store.state.offerLinks[peerLinkID] == nil, "cost \(cost)")
        await store.skipReceivedActions(strict: false)
        await store.finish(timeout: .seconds(5))
    }
}

/// Reference postpones a sync while the peer's stamp costs are unknown: no announce, or one that does
/// not parse, opens no link. With the announce, the same call opens one (the positive control).
@MainActor @Test func pnNodeDoesNotSyncToAPeerWhoseAnnounceIsUnknown() async {
    for unknown in [nil, Data([0xC0])] as [Data?] {
        let store = makeNode(announce: unknown)
        await store.send(.syncToPeer(destinationHash: peerDest, peeringCost: 0))
        #expect(store.state.pendingSyncPeers[peerDest] == nil)
        store.exhaustivity = .on                       // an `openLink` would fail teardown
        await store.finish(timeout: .seconds(2))
    }
    let known = makeNode(announce: announce(cost: 16, flexibility: 3))
    await known.send(.syncToPeer(destinationHash: peerDest, peeringCost: 0))
    await known.receive { if case .endpoint(.openLink(peerDest)) = $0 { return true }; return false }
    #expect(known.state.pendingSyncPeers[peerDest] == 0)
    await known.skipReceivedActions(strict: false)
}

/// The announce is read again when the link is up: one that disappeared in between offers nothing.
@MainActor @Test(.timeLimit(.minutes(1))) func pnNodeOffersNothingWhenThePeerAnnounceIsGoneAtLinkEstablished() async {
    let store = makeNode(announce: nil, pendingPeeringCost: LXMFPropagation.maxPeeringCost)
    await store.send(.endpoint(.delegate(.linkEstablished(linkID: peerLinkID, destinationHash: peerDest))))
    #expect(store.state.offerLinks[peerLinkID] == nil)
    await store.skipReceivedActions(strict: false)
    await store.finish(timeout: .seconds(5))
}

/// Optional hardening (narrower than reference): a response naming an id we did not offer gets only
/// the offered ones.
@MainActor @Test func pnNodeTransfersOnlyOfferedIdsFromAWantedList() async {
    let store = makeNode(announce: announce(cost: 20, flexibility: 0), offerLink: [heldId(7), heldId(8)])
    await store.send(.endpoint(.delegate(.responseReceived(linkID: peerLinkID, requestID: Data([1]),
        data: MsgPack.encode(.array([.bin(heldId(2)), .bin(heldId(8))]))))))
    await store.receive { action in
        if case let .endpoint(.sendResourceOverLink(lid, data)) = action {
            #expect(lid == peerLinkID)
            #expect(LXMFPropagation.parseContainer(data)?.entries == [heldEntry(8)])
            return true
        }
        return false
    }
}
