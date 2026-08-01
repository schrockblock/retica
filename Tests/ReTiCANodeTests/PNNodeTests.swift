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
