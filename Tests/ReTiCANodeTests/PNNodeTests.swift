import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private func makeStore(_ pnIdentity: Identity, peeringCost: Double = 0, targetStampCost: Double = 4) -> TestStore<PNNode.State, PNNode.Action> {
    let store = TestStore(initialState: PNNode.State(
        identity: pnIdentity, endpoint: TCPEndpoint.State(host: "pn", port: 4242, reconnectOnDrop: false),
        targetStampCost: targetStampCost, peeringCost: peeringCost)
    ) { PNNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

/// A propagation node MUST advertise the stamp cost it enforces. Reference clients treat an
/// advertised 0 as "unavailable" (LXMRouter.py:428 — `if not target_propagation_cost`) and fail
/// the send outright, so advertising 0 while enforcing 16 breaks every reference client.
///
/// Fractional (LXMF 1.3.0): the exact target, flexibility and peering cost go in element [7], their
/// ceilings in [5]. Anti-vacuity: none of the three is an integer or a default, so advertising the
/// ceiling, 0, or a constant in place of any of them fails.
@Test @MainActor func pnNodeAdvertisesTheStampCostItEnforces() async throws {
    let identity = Identity()
    let enforced = 18.5                                   // deliberately not the default
    let store = TestStore(
        initialState: PNNode.State(identity: identity,
                                   endpoint: TCPEndpoint.State(host: "h", port: 1, reconnectOnDrop: false),
                                   targetStampCost: enforced, stampCostFlexibility: 2.25, peeringCost: 7.75)
    ) { PNNode() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    #expect(store.state.node.store.targetStampCost == enforced)
    #expect(store.state.node.store.minAcceptedStampCost == 16.25)

    let captured = LockIsolated<Data?>(nil)
    await store.send(.registerPropagation)
    await store.receive { action in
        if case let .endpoint(.announce(_, appData)) = action { captured.setValue(appData); return true }
        return false
    }

    let blob = try #require(captured.value)
    let announced = try #require(PNAnnounce.parse(blob))
    #expect(announced.targetStampCost == enforced)
    #expect(announced.stampCostFlexibility == 2.25)
    #expect(announced.peeringCost == 7.75)
    guard case let .array(items)? = MsgPack.decodeValue(blob) else { Issue.record("not an array"); return }
    try #require(items.count == 8)                        // require: the index reads below would trap
    #expect(items[5] == .array([.uint(19), .uint(3), .uint(8)]))
    #expect(items[7] == .array([.double(18.5), .double(2.25), .double(7.75)]))
}

/// A propagation node MUST advertise propagation limits a peer can actually act on. These fields are
/// a REQUEST the SENDER honours (Handlers.py:61 → LXMRouter.py:2025 → LXMPeer.py:370, where `self` is
/// the peer record for US): a reference node reads field [3], and for any message bigger than it calls
/// `remove_unhandled_message` + `add_handled_message` — dropped permanently, never retried. Advertising
/// 0 made `lxm_transfer_size > 0` unconditionally true, so reference→ReTiCA mesh sync silently
/// delivered NOTHING, forever. Field [4] = 0 likewise stalled every sync (LXMPeer.py:375).
///
/// Asserted on bytes parsed back out of the emitted announce, not read off state: a serialisation
/// mistake in these fields is exactly what reaches the peer.
@Test @MainActor func pnNodeAdvertisesActionablePropagationLimits() async {
    let store = makeStore(Identity())

    let captured = LockIsolated<Data?>(nil)
    await store.send(.registerPropagation)
    await store.receive { action in
        if case let .endpoint(.announce(_, appData)) = action { captured.setValue(appData); return true }
        return false
    }

    #expect(captured.value != nil)
    if let appData = captured.value {
        #expect(PNAnnounce.isValid(appData))
        let announced = PNAnnounce.parse(appData)
        #expect(announced != nil)
        if let announced {
            #expect(announced.perTransferLimit != 0)
            #expect(announced.perSyncLimit != 0)
            #expect(announced.perTransferLimit == LXMFPropagation.defaultPropagationTransferLimitKB)
            #expect(announced.perSyncLimit == LXMFPropagation.defaultPropagationSyncLimitKB)
            // Reference clamps sync >= transfer (LXMRouter.py:156-157); never advertise the inverse.
            #expect(announced.perSyncLimit >= announced.perTransferLimit)
            // No OTHER announce field may change as a side effect of this fix.
            #expect(announced.timebase == 1700000000)
            #expect(announced.nodeState == true)
            #expect(announced.targetStampCost == store.state.node.store.targetStampCost)
            #expect(announced.stampCostFlexibility == 0)
            #expect(announced.peeringCost == store.state.peeringCost)
            #expect(announced.metadata == .map([]))
        }
    }
}

/// registerPropagation registers the lxmf.propagation destination and announces valid PNAnnounce app-data.
@Test @MainActor func pnNodeRegistersAndAnnounces() async {
    let store = makeStore(Identity())
    let gotAppData = LockIsolated<Data?>(nil)
    await store.send(.registerPropagation)
    await store.receive { if case .endpoint(.registerLocalDestination) = $0 { return true }; return false }
    await store.receive { action in
        if case let .endpoint(.announce(_, appData)) = action { gotAppData.setValue(appData); return true }
        return false
    }
    #expect(gotAppData.value != nil)
    #expect(PNAnnounce.isValid(gotAppData.value!))
}

/// A concluded container (resourceReceived) is ingested and surfaced as messagesStored.
@Test @MainActor func pnNodeIngestsConcludedContainer() async {
    let client = Identity(); let sender = Identity()
    let msg = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: client.hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("hi".utf8))
    let (container, tid) = await LXMFPropagation.pack(message: msg, recipientIdentity: client, timestamp: 1700000000.5, stampCost: 4)!
    let store = makeStore(Identity())
    let linkID = Data(repeating: 0xA0, count: 16)
    await store.send(.endpoint(.delegate(.resourceReceived(linkID: linkID, data: container))))
    await store.receive { action in
        if case let .delegate(.messagesStored(tids)) = action { #expect(tids == [tid]); return true }
        return false
    }
    #expect(store.state.node.store.contains(transientId: tid))
}

/// Full serve: ingest a message for client C, IDENTIFY the link as C, then the two /get phases return the
/// id list (phase-1) and the blob (phase-2).
@Test @MainActor func pnNodeServesTwoPhaseGet() async {
    let client = Identity(); let sender = Identity()
    let clientHash = LXMessage.deliveryHash(identityHash: client.hash)
    let msg = LXMessage.create(source: sender, destinationHash: clientHash,
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("hi".utf8))
    let (container, tid) = await LXMFPropagation.pack(message: msg, recipientIdentity: client, timestamp: 1700000000.5, stampCost: 4)!
    let entry = LXMFPropagation.parseContainer(container)!.entries[0]  // stamped — what PN stores and serves
    let getPath = Crypto.truncatedHash(Data("/get".utf8))
    let store = makeStore(Identity())
    let linkID = Data(repeating: 0xA0, count: 16)

    await store.send(.endpoint(.delegate(.resourceReceived(linkID: linkID, data: container))))
    await store.receive { if case .delegate(.messagesStored) = $0 { return true }; return false }
    await store.send(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: client))))

    // Phase-1: [null,null] → id list.
    await store.send(.endpoint(.delegate(.requestReceived(linkID: linkID, requestID: Data([1]),
        pathHash: getPath, data: MsgPack.encode(.array([.null, .null]))))))
    await store.receive { action in
        if case let .endpoint(.sendResponseOverLink(lid, rid, data)) = action {
            #expect(lid == linkID); #expect(rid == Data([1]))
            #expect(MsgPack.decodeValue(data) == .array([.bin(tid)])); return true
        }
        return false
    }

    // Phase-2: [[tid],[]] → the blob.
    await store.send(.endpoint(.delegate(.requestReceived(linkID: linkID, requestID: Data([2]),
        pathHash: getPath, data: MsgPack.encode(.array([.array([.bin(tid)]), .array([])]))))))
    await store.receive { action in
        if case let .endpoint(.sendResponseOverLink(_, rid, data)) = action {
            #expect(rid == Data([2]))
            // Client-download serve is stampless (reference LXMRouter.py:1551 strips the trailing stamp).
            #expect(MsgPack.decodeValue(data) == .array([.bin(LXMFPropagation.strippedCore(lxmfData: entry))])); return true
        }
        return false
    }
}

/// A /get without a prior IDENTIFY on the link is dropped (no response).
@Test @MainActor func pnNodeDropsGetWithoutIdentify() async {
    let getPath = Crypto.truncatedHash(Data("/get".utf8))
    let store = makeStore(Identity())
    let linkID = Data(repeating: 0xA0, count: 16)
    await store.send(.endpoint(.delegate(.requestReceived(linkID: linkID, requestID: Data([1]),
        pathHash: getPath, data: MsgPack.encode(.array([.null, .null]))))))
    store.exhaustivity = .on   // a stray sendResponseOverLink / node action would fail teardown
}

// MARK: - P4a PN↔PN mesh responder (/offer)

/// /offer with a peer identity: the store lacks both offered ids → responds wanting both.
@Test @MainActor func pnNodeOfferWantsAllWhenStoreEmpty() async {
    let peer = Identity()
    let offerPath = Crypto.truncatedHash(Data("/offer".utf8))
    let id1 = Data(repeating: 0x11, count: 32); let id2 = Data(repeating: 0x22, count: 32)
    let store = makeStore(Identity())
    let linkID = Data(repeating: 0xB0, count: 16)
    await store.send(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: peer))))
    await store.send(.endpoint(.delegate(.requestReceived(linkID: linkID, requestID: Data([1]),
        pathHash: offerPath, data: MsgPack.encode(.array([.bin(Data([0x01])), .array([.bin(id1), .bin(id2)])]))))))
    await store.receive { action in
        if case let .endpoint(.sendResponseOverLink(lid, rid, data)) = action {
            #expect(lid == linkID); #expect(rid == Data([1]))
            #expect(MsgPack.decodeValue(data) == .array([.bin(id1), .bin(id2)])); return true
        }
        return false
    }
}

/// /offer where the store already holds one offered id → responds wanting only the other.
@Test @MainActor func pnNodeOfferWantsOnlyMissing() async {
    let peer = Identity(); let sender = Identity(); let recipient = Identity()
    let msg = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: recipient.hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("x".utf8))
    let (container, held) = await LXMFPropagation.pack(message: msg, recipientIdentity: recipient, timestamp: 1700000000.5, stampCost: 4)!
    let want = Data(repeating: 0x22, count: 32)
    let offerPath = Crypto.truncatedHash(Data("/offer".utf8))
    let store = makeStore(Identity())
    let linkID = Data(repeating: 0xB0, count: 16)

    await store.send(.endpoint(.delegate(.resourceReceived(linkID: linkID, data: container))))   // PN now holds `held`
    await store.receive { if case .delegate(.messagesStored) = $0 { return true }; return false }
    await store.send(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: peer))))
    await store.send(.endpoint(.delegate(.requestReceived(linkID: linkID, requestID: Data([2]),
        pathHash: offerPath, data: MsgPack.encode(.array([.bin(Data([0x01])), .array([.bin(held), .bin(want)])]))))))
    await store.receive { action in
        if case let .endpoint(.sendResponseOverLink(_, _, data)) = action {
            #expect(MsgPack.decodeValue(data) == .array([.bin(want)])); return true   // held excluded, only `want`
        }
        return false
    }
}

/// /offer without a prior IDENTIFY on the link is dropped (no response).
@Test @MainActor func pnNodeOfferWithoutIdentifyDrops() async {
    let offerPath = Crypto.truncatedHash(Data("/offer".utf8))
    let store = makeStore(Identity())
    let linkID = Data(repeating: 0xB0, count: 16)
    await store.send(.endpoint(.delegate(.requestReceived(linkID: linkID, requestID: Data([1]),
        pathHash: offerPath, data: MsgPack.encode(.array([.bin(Data([0x01])), .array([.bin(Data(repeating: 0x11, count: 32))])]))))))
    store.exhaustivity = .on   // a stray sendResponseOverLink / node action would fail teardown
}

// MARK: - P4b-2 mesh initiator

/// Initiator generates a peering key valid at the peer's cost and puts it in the /offer.
@Test @MainActor func pnNodeInitiatorGeneratesValidPeeringKey() async {
    let aIdentity = Identity(); let peerIdentity = Identity()
    let cost: Double = 8
    let peerDest = Data(repeating: 0xD0, count: 16); let linkID = Data(repeating: 0xD1, count: 16)
    var initial = PNNode.State(identity: aIdentity, endpoint: TCPEndpoint.State(host: "a", port: 4242, reconnectOnDrop: false),
                               targetStampCost: 0)
    // Something to offer (an offer with nothing in it is not made), to a peer accepting at 0, whose
    // announce we hold (a sync waits for it).
    let held = Data(repeating: 0xAB, count: 16) + Data("held".utf8)
    _ = initial.node.store.ingest(container: LXMFPropagation.container(timestamp: 1700000000, entries: [held]))
    let heldId = LXMFPropagation.transientId(lxmfData: held)
    initial.endpoint.transport.learned[peerDest] = LearnedDestination(
        identity: peerIdentity,
        appData: PNAnnounce(timebase: 0, nodeState: true, perTransferLimit: 256, perSyncLimit: 10240,
                            targetStampCost: 0, stampCostFlexibility: 0, peeringCost: cost).packed,
        ratchet: nil, interfaceID: initial.endpoint.tcpClients[0].interfaceID,
        hops: 1, nextHop: nil, announceEmitted: 0)
    // A learned path implies the interface it was heard on exists; seeding one without the other
    // builds a state the runtime cannot reach. `openLink` now gates on `reachableLearned`, which
    // reads BOTH, so the fixture has to be coherent.
    initial.endpoint.transport.interfaces[initial.endpoint.tcpClients[0].interfaceID] = .tcp
    let store = TestStore(initialState: initial) { PNNode() } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.continuousClock = TestClock(); $0.date = .constant(Date(timeIntervalSince1970: 1700000000)); $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.syncToPeer(destinationHash: peerDest, peeringCost: cost))
    await store.receive { if case .endpoint(.openLink(peerDest)) = $0 { return true }; return false }
    #expect(store.state.pendingSyncPeers[peerDest] == cost)

    await store.send(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: peerDest))))
    await store.receive { if case let .endpoint(.identifyOverLink(lid, _)) = $0 { return lid == linkID }; return false }
    let gotKey = LockIsolated<Data?>(nil)
    let gotIds = LockIsolated<[Data]>([])
    await store.receive { action in                              // driven by the async offerKeyReady effect
        if case let .endpoint(.sendRequestOverLink(lid, path, data)) = action, lid == linkID, path == "/offer" {
            if case let .array(items)? = MsgPack.decodeValue(data), case let .bin(k) = items[0] { gotKey.setValue(k) }
            if case let .array(items)? = MsgPack.decodeValue(data) { gotIds.setValue(PNNodeOfferTestSupport.ids(items[1])) }
            return true
        }
        return false
    }
    #expect(gotIds.value == [heldId])
    // The generated key validates at the peer's cost over the same responder-first peeringId.
    #expect(LXStamper.validatePeeringKey(peeringId: peerIdentity.hash + aIdentity.hash,
                                         peeringKey: gotKey.value ?? Data(), targetCost: cost))
}

/// Offer response (list): transfer the wanted subset as a container Resource.
@Test @MainActor func pnNodeTransfersWantedListOnOfferResponse() async {
    let sender = Identity(); let recipient = Identity()
    let msg = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: recipient.hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("m".utf8))
    let (container, tid) = await LXMFPropagation.pack(message: msg, recipientIdentity: recipient, timestamp: 1700000000.5, stampCost: 4)!
    let entry = LXMFPropagation.parseContainer(container)!.entries[0]  // stamped — what PN stores and serves
    let linkID = Data(repeating: 0xD1, count: 16)
    var initial = PNNode.State(identity: Identity(), endpoint: TCPEndpoint.State(host: "pn", port: 4242, reconnectOnDrop: false), targetStampCost: 4)
    _ = initial.node.store.ingest(container: container)
    initial.offerLinks[linkID] = [tid]
    let store = TestStore(initialState: initial) { PNNode() } withDependencies: {
        $0.continuousClock = TestClock(); $0.date = .constant(Date(timeIntervalSince1970: 1700000000)); $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.endpoint(.delegate(.responseReceived(linkID: linkID, requestID: Data([1]),
        data: MsgPack.encode(.array([.bin(tid)]))))))
    await store.receive { action in
        if case let .endpoint(.sendResourceOverLink(lid, data)) = action {
            #expect(lid == linkID)
            #expect(LXMFPropagation.parseContainer(data)?.entries == [entry]); return true
        }
        return false
    }
    #expect(store.state.offerLinks[linkID] == nil)   // consumed
}

/// Offer response `true` (wants all): transfer all offered entries.
@Test @MainActor func pnNodeTransfersAllOnTrueResponse() async {
    let sender = Identity(); let recipient = Identity()
    let msg = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: recipient.hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("m".utf8))
    let (container, tid) = await LXMFPropagation.pack(message: msg, recipientIdentity: recipient, timestamp: 1700000000.5, stampCost: 4)!
    let entry = LXMFPropagation.parseContainer(container)!.entries[0]  // stamped — what PN stores and serves
    let linkID = Data(repeating: 0xD1, count: 16)
    var initial = PNNode.State(identity: Identity(), endpoint: TCPEndpoint.State(host: "pn", port: 4242, reconnectOnDrop: false), targetStampCost: 4)
    _ = initial.node.store.ingest(container: container)
    initial.offerLinks[linkID] = [tid]
    let store = TestStore(initialState: initial) { PNNode() } withDependencies: {
        $0.continuousClock = TestClock(); $0.date = .constant(Date(timeIntervalSince1970: 1700000000)); $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.endpoint(.delegate(.responseReceived(linkID: linkID, requestID: Data([1]),
        data: MsgPack.encode(.bool(true))))))
    await store.receive { action in
        if case let .endpoint(.sendResourceOverLink(_, data)) = action {
            #expect(LXMFPropagation.parseContainer(data)?.entries == [entry]); return true
        }
        return false
    }
}

/// Offer response `false` (has all): no transfer.
@Test @MainActor func pnNodeTransfersNothingOnFalseResponse() async {
    let linkID = Data(repeating: 0xD1, count: 16)
    var initial = PNNode.State(identity: Identity(), endpoint: TCPEndpoint.State(host: "pn", port: 4242, reconnectOnDrop: false))
    initial.offerLinks[linkID] = [Data(repeating: 0x11, count: 32)]
    let store = TestStore(initialState: initial) { PNNode() } withDependencies: {
        $0.continuousClock = TestClock(); $0.date = .constant(Date(timeIntervalSince1970: 1700000000)); $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.endpoint(.delegate(.responseReceived(linkID: linkID, requestID: Data([1]),
        data: MsgPack.encode(.bool(false))))))
    store.exhaustivity = .on   // a stray sendResourceOverLink would fail teardown
}

/// linkEstablished for a dest NOT in pendingSyncPeers (an inbound responder link) is ignored — no offer.
@Test @MainActor func pnNodeInboundLinkEstablishedIgnored() async {
    let store = makeStore(Identity())
    let linkID = Data(repeating: 0xD1, count: 16)
    await store.send(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: Data(repeating: 0xEE, count: 16)))))
    store.exhaustivity = .on   // a stray identify/sendRequest would fail teardown
}

// MARK: - P4c-2 peering-cost enforcement

/// Responder validates the offer's peering key at the configured cost: a valid key is accepted (wanted response).
@Test @MainActor func pnNodeOfferAcceptedWithValidPeeringKey() async {
    let pnIdentity = Identity(); let peer = Identity()
    let cost: Double = 8
    let peeringId = pnIdentity.hash + peer.hash                       // responder-first: responder + initiator
    let key = await LXStamper.generatePeeringKey(peeringId: peeringId, targetCost: cost)!
    let offerPath = Crypto.truncatedHash(Data("/offer".utf8))
    let id1 = Data(repeating: 0x11, count: 32)
    let store = makeStore(pnIdentity, peeringCost: cost)
    let linkID = Data(repeating: 0xB0, count: 16)
    await store.send(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: peer))))
    await store.send(.endpoint(.delegate(.requestReceived(linkID: linkID, requestID: Data([1]),
        pathHash: offerPath, data: MsgPack.encode(.array([.bin(key), .array([.bin(id1)])]))))))
    await store.receive { action in
        if case let .endpoint(.sendResponseOverLink(_, _, data)) = action {
            #expect(MsgPack.decodeValue(data) == .array([.bin(id1)])); return true
        }
        return false
    }
}

/// Responder rejects an invalid peering key at cost > 0: no response.
@Test @MainActor func pnNodeOfferRejectedWithInvalidPeeringKey() async {
    let peer = Identity()
    let offerPath = Crypto.truncatedHash(Data("/offer".utf8))
    let store = makeStore(Identity(), peeringCost: 8)
    let linkID = Data(repeating: 0xB0, count: 16)
    await store.send(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: peer))))
    await store.send(.endpoint(.delegate(.requestReceived(linkID: linkID, requestID: Data([1]),
        pathHash: offerPath, data: MsgPack.encode(.array([.bin(Data([0])), .array([.bin(Data(repeating: 0x11, count: 32))])]))))))
    // Drain the internal validatePeeringKey → peerValidated chain (both return .none → no sendResponseOverLink).
    await store.receive { if case .node(.validatePeeringKey) = $0 { return true }; return false }
    await store.receive { if case .node(.delegate(.peerValidated)) = $0 { return true }; return false }
    store.exhaustivity = .on   // an invalid key must NOT produce a sendResponseOverLink
}

// MARK: - P4c-3 link cleanup

/// linkClosed clears all per-link state (clientIdentities, offerLinks, and any pendingGet/pendingOffer on it).
@Test @MainActor func pnNodeLinkClosedClearsPerLinkState() async {
    let linkID = Data(repeating: 0xC0, count: 16)
    let pHash = Data(repeating: 0xAB, count: 16)               // any 16-byte peer hash
    var initial = PNNode.State(identity: Identity(), endpoint: TCPEndpoint.State(host: "pn", port: 4242, reconnectOnDrop: false))
    initial.clientIdentities[linkID] = Identity()
    initial.offerLinks[linkID] = [Data(repeating: 0x11, count: 32)]
    initial.pendingGet[Data(repeating: 0xCC, count: 16)] = PNNode.PendingGet(linkID: linkID, requestID: Data([1]))
    initial.pendingOffer[pHash] = PNNode.PendingOffer(linkID: linkID, requestID: Data([2]), offeredIds: [])
    let store = TestStore(initialState: initial) { PNNode() } withDependencies: {
        $0.continuousClock = TestClock(); $0.date = .constant(Date(timeIntervalSince1970: 1700000000)); $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.endpoint(.delegate(.linkClosed(linkID: linkID, reason: .initiatorClosed))))
    #expect(store.state.clientIdentities[linkID] == nil)
    #expect(store.state.offerLinks[linkID] == nil)
    #expect(!store.state.pendingGet.values.contains { $0.linkID == linkID })
    #expect(!store.state.pendingOffer.values.contains { $0.linkID == linkID })
}

/// requestFailed clears the outbound offer link entry.
@Test @MainActor func pnNodeRequestFailedClearsOfferLink() async {
    let linkID = Data(repeating: 0xC0, count: 16)
    var initial = PNNode.State(identity: Identity(), endpoint: TCPEndpoint.State(host: "pn", port: 4242, reconnectOnDrop: false))
    initial.offerLinks[linkID] = [Data(repeating: 0x11, count: 32)]
    let store = TestStore(initialState: initial) { PNNode() } withDependencies: {
        $0.continuousClock = TestClock(); $0.date = .constant(Date(timeIntervalSince1970: 1700000000)); $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.endpoint(.delegate(.requestFailed(linkID: linkID, requestID: Data([1])))))
    #expect(store.state.offerLinks[linkID] == nil)
}

/// linkFailed (outbound openLink failed before a link existed) SURFACES an observable
/// `syncFailed` delegate carrying the reason (handoff F3 — the drop must not be silent) AND clears
/// the pending sync peer. Both halves are asserted: the `receive` fails hard even under `.off` if
/// the delegate is absent (a MISSING action is not silenced by non-exhaustivity), and the state
/// check pins the clearing.
@Test @MainActor func pnNodeLinkFailedSurfacesSyncFailedAndClearsPendingSyncPeer() async {
    let peerDest = Data(repeating: 0xD0, count: 16)
    // Seed the pending sync directly rather than via `syncToPeer`: an `openLink` to an unlearned
    // dest auto-fails and pre-emits its OWN `linkFailed` (and now `syncFailed`), which would
    // contaminate the queue. The handler under test only needs the pending entry as a precondition.
    var initial = PNNode.State(identity: Identity(),
                               endpoint: TCPEndpoint.State(host: "pn", port: 4242, reconnectOnDrop: false),
                               targetStampCost: 4)
    initial.pendingSyncPeers[peerDest] = 3
    let store = TestStore(initialState: initial) { PNNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.endpoint(.delegate(.linkFailed(destinationHash: peerDest, reason: .noPath))))
    await store.receive {
        if case let .delegate(.syncFailed(dest, reason)) = $0 { return dest == peerDest && reason == .noPath }
        return false
    }
    #expect(store.state.pendingSyncPeers[peerDest] == nil)
}

/// A `linkFailed` for a destination we are NOT syncing to (no `pendingSyncPeers` entry) must NOT
/// emit a spurious `syncFailed`. Trailing `.on` so teardown fails if any stray delegate is emitted.
@Test @MainActor func pnNodeLinkFailedForAnUntrackedDestEmitsNoSyncFailed() async {
    let store = makeStore(Identity())
    let unknown = Data(repeating: 0xAB, count: 16)
    store.exhaustivity = .on
    await store.send(.endpoint(.delegate(.linkFailed(destinationHash: unknown, reason: .noPath))))
}
