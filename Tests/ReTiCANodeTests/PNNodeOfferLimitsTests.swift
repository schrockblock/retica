import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// A sync offer honours the peer's announced per-transfer and per-sync limits, in reference weight
// order, and never re-offers what the peer's handled set holds (LXMPeer.py:336-395, :405-453,
// :497-507). The selection itself is in PropagationStoreOfferTests and, against a real LXMPeer, in
// PNOfferLimitsCrossValidationTests; these drive it through PNNode's sync and offer-response path.

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private let day: TimeInterval = 60 * 60 * 24
private let peerIdentity = Identity()
private let peerDest = Destination.hash(identityHash: peerIdentity.hash, appName: LXMessage.appName,
                                        aspects: ["propagation"])

private func entryData(_ tag: Int, size: Int) -> Data {
    let label = Data("limits-\(tag)-".utf8)
    return Data(repeating: 0xAB, count: 16) + label + Data(repeating: 0x5A, count: size - 16 - label.count)
}

private func announce(transferKB: Int, syncKB: Int) -> Data {
    PNAnnounce(timebase: 0, nodeState: true, perTransferLimit: transferKB, perSyncLimit: syncKB,
               targetStampCost: 0, stampCostFlexibility: 0, peeringCost: 0).packed
}

private func link(_ n: UInt8) -> Data { Data(repeating: n, count: 16) }

/// A node state holding entries of `sizes` received `ages` before t0 (in that order), whose peer has
/// announced the given limits, and the entry ids.
private func makeState(sizes: [Int], ages: [TimeInterval]? = nil,
                       transferKB: Int = 256, syncKB: Int = 10240) -> (PNNode.State, [Data]) {
    var initial = PNNode.State(identity: Identity(),
                               endpoint: TCPEndpoint.State(host: "a", port: 4242, reconnectOnDrop: false),
                               targetStampCost: 0)
    var ids: [Data] = []
    for (i, size) in sizes.enumerated() {
        let added = initial.node.store.ingest(
            container: LXMFPropagation.container(timestamp: 0, entries: [entryData(i, size: size)]),
            now: t0.addingTimeInterval(-(ages?[i] ?? 0))).added
        precondition(added.count == 1)
        ids.append(added[0])
    }
    initial.endpoint.transport.learned[peerDest] = LearnedDestination(
        identity: peerIdentity, appData: announce(transferKB: transferKB, syncKB: syncKB), ratchet: nil,
        interfaceID: initial.endpoint.tcpClients[0].interfaceID, hops: 1, nextHop: nil, announceEmitted: 0)
    initial.endpoint.transport.interfaces[initial.endpoint.tcpClients[0].interfaceID] = .tcp
    return (initial, ids)
}

@MainActor
private func makeStore(_ state: PNNode.State) -> TestStore<PNNode.State, PNNode.Action> {
    let store = TestStore(initialState: state) { PNNode() } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.continuousClock = TestClock()
        $0.date = .constant(t0)
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

/// Runs one sync on `linkID` (peering cost 0, so the key is found at once) and returns the ids in the
/// `/offer`, or nil when none is made.
@MainActor
private func sync(_ store: TestStore<PNNode.State, PNNode.Action>, linkID: Data) async -> [Data]? {
    await store.send(.syncToPeer(destinationHash: peerDest, peeringCost: 0))
    await store.send(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: peerDest))))
    let got = LockIsolated<[Data]?>(nil)
    if store.state.offerLinks[linkID] != nil {
        await store.receive({ action in
            if case let .endpoint(.sendRequestOverLink(lid, path, data)) = action, lid == linkID, path == "/offer",
               case let .array(items)? = MsgPack.decodeValue(data), items.count >= 2 {
                got.setValue(PNNodeOfferTestSupport.ids(items[1]))
                return true
            }
            return false
        }, timeout: .seconds(10))
    }
    await store.skipReceivedActions(strict: false)
    return got.value
}

@MainActor
private func respond(_ store: TestStore<PNNode.State, PNNode.Action>, linkID: Data, _ response: MsgPackValue) async {
    await store.send(.endpoint(.delegate(.responseReceived(linkID: linkID, requestID: Data([1]),
                                                           data: MsgPack.encode(response)))))
    await store.skipReceivedActions(strict: false)
}

/// Review Focus 1: a peer announcing 256 KB is never offered an entry of 256000 - 15 bytes or more,
/// and not on the next sync either — not even after it re-announces a limit the entry fits, because
/// the entry went into its handled set (reference marks it handled, LXMPeer.py:375-378).
@MainActor @Test func pnNodeNeverOffersAPeerAnEntryOverItsTransferLimit() async {
    let (initial, ids) = makeState(sizes: [255_985, 255_984, 300])
    let first = makeStore(initial)
    #expect(await sync(first, linkID: link(1)) == [ids[2], ids[1]])          // weight order: 300 B first
    #expect(first.state.handledByPeer[peerDest] == [ids[0]])

    // Same limit, next sync: still not offered.
    await first.send(.endpoint(.delegate(.linkClosed(linkID: link(1), reason: .initiatorClosed))))
    #expect(await sync(first, linkID: link(2)) == [ids[2], ids[1]])

    // The peer now announces 1024 KB, which the entry would fit: still not offered.
    var later = first.state
    later.endpoint.transport.learned[peerDest]?.appData = announce(transferKB: 1024, syncKB: 10240)
    let second = makeStore(later)
    #expect(await sync(second, linkID: link(3)) == [ids[2], ids[1]])
}

/// Review Focus 2: a sync limit smaller than the first entry still offers the later, smaller entries
/// that fit (skip, `continue`, LXMPeer.py:380-381). The skipped entry is not handled: a later sync
/// with room offers it.
@MainActor @Test func pnNodeSkipsAnEntryOverThePeerSyncLimitAndOffersLaterOnes() async {
    // 3000 B new (weight 3000), 1000 B at 40 days (10000), 900 B at 30 days (6750).
    let (initial, ids) = makeState(sizes: [3000, 1000, 900], ages: [0, 40 * day, 30 * day], syncKB: 2)
    let store = makeStore(initial)
    #expect(await sync(store, linkID: link(1)) == [ids[2], ids[1]])
    #expect((store.state.handledByPeer[peerDest] ?? []).isEmpty)

    var roomier = store.state
    roomier.endpoint.transport.learned[peerDest]?.appData = announce(transferKB: 256, syncKB: 10240)
    #expect(await sync(makeStore(roomier), linkID: link(2)) == [ids[0], ids[2], ids[1]])
}

/// An id the peer declines (absent from its wanted list) is handled and never offered again; the
/// wanted ones are handled once the transfer concludes (LXMPeer.py:448-457, :505-507).
@MainActor @Test func pnNodeDoesNotReofferDeclinedOrDeliveredIds() async {
    let (initial, ids) = makeState(sizes: [100, 200, 300])
    let store = makeStore(initial)
    #expect(await sync(store, linkID: link(1)) == ids)
    await respond(store, linkID: link(1), .array([.bin(ids[1])]))
    #expect(store.state.handledByPeer[peerDest] == [ids[0], ids[2]])
    #expect(store.state.syncTransfers[link(1)] == [ids[1]])

    await store.send(.endpoint(.delegate(.resourceConcluded(linkID: link(1), resourceHash: Data([9])))))
    #expect(store.state.handledByPeer[peerDest] == Set(ids))
    await store.send(.endpoint(.delegate(.linkClosed(linkID: link(1), reason: .initiatorClosed))))
    #expect(await sync(store, linkID: link(2)) == nil)                       // nothing left: no offer
}

/// `False` (the peer has everything offered) marks every offered id handled (LXMPeer.py:432-437).
@MainActor @Test func pnNodeMarksEverythingHandledOnAFalseResponse() async {
    let (initial, ids) = makeState(sizes: [100, 200])
    let store = makeStore(initial)
    #expect(await sync(store, linkID: link(1)) == ids)
    await respond(store, linkID: link(1), .bool(false))
    #expect(store.state.handledByPeer[peerDest] == Set(ids))
    #expect(await sync(store, linkID: link(2)) == nil)
}

/// A transfer that fails marks nothing: the wanted ids are offered again next sync.
@MainActor @Test func pnNodeReoffersWantedIdsWhenTheTransferFails() async {
    let (initial, ids) = makeState(sizes: [100, 200])
    let store = makeStore(initial)
    #expect(await sync(store, linkID: link(1)) == ids)
    await respond(store, linkID: link(1), .bool(true))
    #expect(store.state.syncTransfers[link(1)] == ids)
    await store.send(.endpoint(.delegate(.resourceFailed(linkID: link(1), resourceHash: Data([9]), rejected: false))))
    #expect(store.state.syncTransfers[link(1)] == nil)
    #expect((store.state.handledByPeer[peerDest] ?? []).isEmpty)
    #expect(await sync(store, linkID: link(2)) == ids)
}

/// An id a peer offers US is not marked handled by the offer (reference marks handled only on receipt,
/// and only for a peer in `self.peers`, LXMRouter.py:2772-2784): our next sync offers it back once, and
/// the peer's decline is what marks it.
@MainActor @Test func pnNodeOffersBackAHeldIdThePeerOfferedUsUntilItDeclines() async {
    let (initial, ids) = makeState(sizes: [100, 200, 300])
    let store = makeStore(initial)
    let inbound = link(7)
    let unknown = Data(repeating: 0x33, count: 32)
    await store.send(.endpoint(.delegate(.linkIdentified(linkID: inbound, remoteIdentity: peerIdentity))))
    await store.send(.endpoint(.delegate(.requestReceived(
        linkID: inbound, requestID: Data([2]), pathHash: Crypto.truncatedHash(Data("/offer".utf8)),
        data: MsgPack.encode(.array([.bin(Data(repeating: 0, count: 32)), .array([.bin(ids[1]), .bin(unknown)])]))))))
    await store.receive { if case .node(.delegate(.peerValidated(peerDest, true))) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.handledByPeer[peerDest] == nil)
    #expect(await sync(store, linkID: link(1)) == ids)
    await respond(store, linkID: link(1), .array([.bin(ids[0]), .bin(ids[2])]))
    #expect(store.state.handledByPeer[peerDest] == [ids[1]])
}

/// Forty strangers (any identity validates at peering cost 0), each offering an id we hold, leave no
/// `handledByPeer` key behind: the offer marks nothing, so state does not grow per stranger.
@MainActor @Test func pnNodeKeepsNoHandledStateForStrangersOfferingHeldIds() async {
    let (initial, ids) = makeState(sizes: [100])
    let store = makeStore(initial)
    for n in 0..<40 {
        let stranger = Identity()
        let strangerDest = Destination.hash(identityHash: stranger.hash, appName: LXMessage.appName,
                                            aspects: ["propagation"])
        let inbound = Data(repeating: UInt8(n), count: 15) + Data([0xEE])
        await store.send(.endpoint(.delegate(.linkIdentified(linkID: inbound, remoteIdentity: stranger))))
        await store.send(.endpoint(.delegate(.requestReceived(
            linkID: inbound, requestID: Data([UInt8(n)]), pathHash: Crypto.truncatedHash(Data("/offer".utf8)),
            data: MsgPack.encode(.array([.bin(Data(repeating: 0, count: 32)), .array([.bin(ids[0])])]))))))
        await store.receive { if case .node(.delegate(.peerValidated(strangerDest, true))) = $0 { return true }; return false }
        await store.receive { if case .endpoint(.sendResponseOverLink(inbound, _, _)) = $0 { return true }; return false }
        await store.skipReceivedActions(strict: false)
    }
    #expect(store.state.handledByPeer.isEmpty)
}

/// An unpeered identity (key valid at peering cost 0) offering only ids we do not hold leaves no
/// state behind: no `handledByPeer` key, not even an empty set. Its offer is still answered.
@MainActor @Test func pnNodeKeepsNoHandledStateForAStrangerOfferingUnknownIds() async {
    let (initial, _) = makeState(sizes: [100])
    let store = makeStore(initial)
    let stranger = Identity()
    let strangerDest = Destination.hash(identityHash: stranger.hash, appName: LXMessage.appName, aspects: ["propagation"])
    let inbound = link(8)
    let junk = (0..<50).map { Data(repeating: UInt8($0), count: 32) }
    await store.send(.endpoint(.delegate(.linkIdentified(linkID: inbound, remoteIdentity: stranger))))
    await store.send(.endpoint(.delegate(.requestReceived(
        linkID: inbound, requestID: Data([2]), pathHash: Crypto.truncatedHash(Data("/offer".utf8)),
        data: MsgPack.encode(.array([.bin(Data(repeating: 0, count: 32)), .array(junk.map { .bin($0) })]))))))
    await store.receive { if case .node(.delegate(.peerValidated(strangerDest, true))) = $0 { return true }; return false }
    await store.receive { if case .endpoint(.sendResponseOverLink(inbound, _, _)) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.handledByPeer[strangerDest] == nil)
    #expect(store.state.handledByPeer.isEmpty)
}
