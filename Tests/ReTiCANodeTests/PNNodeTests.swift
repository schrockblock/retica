import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private func makeStore(_ pnIdentity: Identity) -> TestStore<PNNode.State, PNNode.Action> {
    let store = TestStore(initialState: PNNode.State(
        identity: pnIdentity, endpoint: Endpoint.State(host: "pn", port: 4242, reconnectOnDrop: false))
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
    let (container, _) = LXMFPropagation.pack(message: msg, recipientIdentity: client, timestamp: 1700000000.5)
    let entry = LXMFPropagation.parseContainer(container)!.entries[0]
    let tid = LXMFPropagation.transientId(lxmfData: entry)
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
    let (container, _) = LXMFPropagation.pack(message: msg, recipientIdentity: client, timestamp: 1700000000.5)
    let entry = LXMFPropagation.parseContainer(container)!.entries[0]
    let tid = LXMFPropagation.transientId(lxmfData: entry)
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
    let (container, _) = LXMFPropagation.pack(message: msg, recipientIdentity: recipient, timestamp: 1700000000.5)
    let held = LXMFPropagation.transientId(lxmfData: LXMFPropagation.parseContainer(container)!.entries[0])
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

/// syncToPeer opens a link and, on establishment to a pending peer, IDENTIFYs and offers store.transientIds.
@Test @MainActor func pnNodeSyncToPeerOffersOnLinkEstablished() async {
    let sender = Identity(); let recipient = Identity()
    let msg = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: recipient.hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("m".utf8))
    let (container, _) = LXMFPropagation.pack(message: msg, recipientIdentity: recipient, timestamp: 1700000000.5)
    let tid = LXMFPropagation.transientId(lxmfData: LXMFPropagation.parseContainer(container)!.entries[0])
    let peerDest = Data(repeating: 0xD0, count: 16)
    let linkID = Data(repeating: 0xD1, count: 16)
    let store = makeStore(Identity())

    await store.send(.endpoint(.delegate(.resourceReceived(linkID: Data([9]), data: container))))  // PN-A now holds `tid`
    await store.receive { if case .delegate(.messagesStored) = $0 { return true }; return false }

    await store.send(.syncToPeer(destinationHash: peerDest))
    await store.receive { if case .endpoint(.openLink(peerDest)) = $0 { return true }; return false }
    #expect(store.state.pendingSyncPeers.contains(peerDest))

    await store.send(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: peerDest))))
    await store.receive { if case let .endpoint(.identifyOverLink(lid, _)) = $0 { return lid == linkID }; return false }
    await store.receive { action in
        if case let .endpoint(.sendRequestOverLink(lid, path, data)) = action {
            #expect(lid == linkID); #expect(path == "/offer")
            #expect(MsgPack.decodeValue(data) == .array([.bin(Data([0x01])), .array([.bin(tid)])]))
            return true
        }
        return false
    }
    #expect(store.state.offerLinks[linkID] == [tid])
    #expect(!store.state.pendingSyncPeers.contains(peerDest))
}

/// Offer response (list): transfer the wanted subset as a container Resource.
@Test @MainActor func pnNodeTransfersWantedListOnOfferResponse() async {
    let sender = Identity(); let recipient = Identity()
    let msg = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: recipient.hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("m".utf8))
    let (container, _) = LXMFPropagation.pack(message: msg, recipientIdentity: recipient, timestamp: 1700000000.5)
    let entry = LXMFPropagation.parseContainer(container)!.entries[0]
    let tid = LXMFPropagation.transientId(lxmfData: entry)
    let linkID = Data(repeating: 0xD1, count: 16)
    var initial = PNNode.State(identity: Identity(), endpoint: Endpoint.State(host: "pn", port: 4242, reconnectOnDrop: false))
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
    let (container, _) = LXMFPropagation.pack(message: msg, recipientIdentity: recipient, timestamp: 1700000000.5)
    let entry = LXMFPropagation.parseContainer(container)!.entries[0]
    let tid = LXMFPropagation.transientId(lxmfData: entry)
    let linkID = Data(repeating: 0xD1, count: 16)
    var initial = PNNode.State(identity: Identity(), endpoint: Endpoint.State(host: "pn", port: 4242, reconnectOnDrop: false))
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
    var initial = PNNode.State(identity: Identity(), endpoint: Endpoint.State(host: "pn", port: 4242, reconnectOnDrop: false))
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
