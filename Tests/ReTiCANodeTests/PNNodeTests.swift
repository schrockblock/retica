import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private func makeStore(_ pnIdentity: Identity, peeringCost: Int = 0, minStampCost: Int = 4) -> TestStore<PNNode.State, PNNode.Action> {
    let store = TestStore(initialState: PNNode.State(
        identity: pnIdentity, endpoint: TCPEndpoint.State(host: "pn", port: 4242, reconnectOnDrop: false),
        minStampCost: minStampCost, peeringCost: peeringCost)
    ) { PNNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
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
    let (container, tid) = LXMFPropagation.pack(message: msg, recipientIdentity: client, timestamp: 1700000000.5, stampCost: 4)
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
    let (container, tid) = LXMFPropagation.pack(message: msg, recipientIdentity: client, timestamp: 1700000000.5, stampCost: 4)
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
            #expect(MsgPack.decodeValue(data) == .array([.bin(entry)])); return true
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
    let (container, held) = LXMFPropagation.pack(message: msg, recipientIdentity: recipient, timestamp: 1700000000.5, stampCost: 4)
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
    let cost = 8
    let peerDest = Data(repeating: 0xD0, count: 16); let linkID = Data(repeating: 0xD1, count: 16)
    var initial = PNNode.State(identity: aIdentity, endpoint: TCPEndpoint.State(host: "a", port: 4242, reconnectOnDrop: false))
    initial.endpoint.transport.learned[peerDest] = LearnedDestination(
        identity: peerIdentity, appData: nil, ratchet: nil, interfaceID: initial.endpoint.interfaceID,
        hops: 1, nextHop: nil, announceEmitted: 0)
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
    await store.receive { action in                              // driven by the async offerKeyReady effect
        if case let .endpoint(.sendRequestOverLink(lid, path, data)) = action, lid == linkID, path == "/offer" {
            if case let .array(items)? = MsgPack.decodeValue(data), case let .bin(k) = items[0] { gotKey.setValue(k) }
            return true
        }
        return false
    }
    // The generated key validates at the peer's cost over the same responder-first peeringId.
    #expect(LXStamper.validatePeeringKey(peeringId: peerIdentity.hash + aIdentity.hash,
                                         peeringKey: gotKey.value!, targetCost: cost))
}

/// Offer response (list): transfer the wanted subset as a container Resource.
@Test @MainActor func pnNodeTransfersWantedListOnOfferResponse() async {
    let sender = Identity(); let recipient = Identity()
    let msg = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: recipient.hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("m".utf8))
    let (container, tid) = LXMFPropagation.pack(message: msg, recipientIdentity: recipient, timestamp: 1700000000.5, stampCost: 4)
    let entry = LXMFPropagation.parseContainer(container)!.entries[0]  // stamped — what PN stores and serves
    let linkID = Data(repeating: 0xD1, count: 16)
    var initial = PNNode.State(identity: Identity(), endpoint: TCPEndpoint.State(host: "pn", port: 4242, reconnectOnDrop: false), minStampCost: 4)
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
    let (container, tid) = LXMFPropagation.pack(message: msg, recipientIdentity: recipient, timestamp: 1700000000.5, stampCost: 4)
    let entry = LXMFPropagation.parseContainer(container)!.entries[0]  // stamped — what PN stores and serves
    let linkID = Data(repeating: 0xD1, count: 16)
    var initial = PNNode.State(identity: Identity(), endpoint: TCPEndpoint.State(host: "pn", port: 4242, reconnectOnDrop: false), minStampCost: 4)
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
    let cost = 8
    let peeringId = pnIdentity.hash + peer.hash                       // responder-first: responder + initiator
    let key = LXStamper.generatePeeringKey(peeringId: peeringId, targetCost: cost)
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

/// linkFailed clears the pending sync peer (outbound openLink failed).
@Test @MainActor func pnNodeLinkFailedClearsPendingSyncPeer() async {
    let peerDest = Data(repeating: 0xD0, count: 16)
    let store = makeStore(Identity())
    await store.send(.syncToPeer(destinationHash: peerDest, peeringCost: 0))
    await store.receive { if case .endpoint(.openLink(peerDest)) = $0 { return true }; return false }
    #expect(store.state.pendingSyncPeers[peerDest] == 0)
    await store.send(.endpoint(.delegate(.linkFailed(destinationHash: peerDest))))
    #expect(store.state.pendingSyncPeers[peerDest] == nil)
}
