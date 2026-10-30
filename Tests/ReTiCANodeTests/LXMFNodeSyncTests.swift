import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// End-to-end through LXMFNode: client A syncs from a propagation node. A establishes a link to the PN's
/// lxmf.propagation destination, IDENTIFYs, and runs the two-phase /get exchange (list → wanted → blobs).
/// The PN is a bare TCPEndpoint stub whose two responses the test supplies. A opens the returned blob with its
/// own identity and surfaces the sender's signature-valid message. (PN server logic is P3.)
@Test @MainActor func lxmfNodeSyncsMessagesFromPropagationNode() async {
    let clock = TestClock()
    let aIdentity = Identity()      // client / recipient
    let sIdentity = Identity()      // the original sender of the stored message
    let pnIdentity = Identity()
    let aDeliveryHash = LXMessage.deliveryHash(identityHash: aIdentity.hash)
    let sDelivery = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                aspects: LXMessage.deliveryAspects, identity: sIdentity)!
    let pnDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                             aspects: ["propagation"], identity: pnIdentity)!

    // The stored message (from S to A) and its propagation entry + transient id.
    let storedMsg = LXMessage.create(source: sIdentity, destinationHash: aDeliveryHash,
                                     timestamp: 1700000000.5, title: Data("t".utf8), content: Data("hi A".utf8))
    let (container, tid) = await LXMFPropagation.pack(message: storedMsg, recipientIdentity: aIdentity, timestamp: 1700000000.5, stampCost: 4)!
    let entry = LXMFPropagation.parseContainer(container)!.entries[0]  // stamped entry — what PN stores and serves

    func makeNode(_ host: String, _ identity: Identity, _ sent: LockIsolated<[Data]>)
        -> (TestStore<LXMFNode.State, LXMFNode.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        var state = LXMFNode.State(
            identity: identity, endpoint: tcpDriverEndpoint(host: host, port: 4242, reconnectOnDrop: false))
        // As `registerDelivery` sets it (without its announce on the wire): a propagated download
        // is delivered only when addressed to our delivery destination.
        state.deliveryDestinationHash = LXMessage.deliveryHash(identityHash: identity.hash)
        let store = TestStore(initialState: state) { LXMFNode() } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } }, close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    func makeEndpoint(_ host: String, _ sent: LockIsolated<[Data]>)
        -> (TestStore<TransportEndpoint.State, TransportEndpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: tcpDriverEndpoint(host: host, port: 4242, reconnectOnDrop: false)) {
            TransportEndpoint()
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } }, close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    func aSend(_ act: LXMFNode.Action) -> Bool { if case .endpoint(.tcpClients(.element(id: _, action: .interface(.send)))) = act { return true }; return false }
    func epSend(_ act: TransportEndpoint.Action) -> Bool { if case .tcpClients(.element(id: _, action: .interface(.send))) = act { return true }; return false }

    let sentA = LockIsolated<[Data]>([]); let sentS = LockIsolated<[Data]>([]); let sentPN = LockIsolated<[Data]>([])
    let (a, eventsA) = makeNode("a", aIdentity, sentA)
    let (s, eventsS) = makeEndpoint("s", sentS)
    let (pn, eventsPN) = makeEndpoint("pn", sentPN)

    await a.send(.endpoint(.start)); eventsA.yield(.connected)
    await s.send(.start); eventsS.yield(.connected)
    await pn.send(.start); eventsPN.yield(.connected)

    // S announces its delivery destination → A learns S's path + identity (for signature validation).
    await s.send(.registerLocalDestination(sDelivery))
    await s.send(.announce(destinationHash: sDelivery.hash, appData: nil))
    await s.receive(epSend)
    eventsA.yield(.data(sentS.value.last!))
    await a.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // PN announces its lxmf.propagation destination → A learns PN's path + identity.
    await pn.send(.registerLocalDestination(pnDest))
    await pn.send(.announce(destinationHash: pnDest.hash, appData: nil))
    await pn.receive(epSend)
    eventsA.yield(.data(sentPN.value.last!))
    await a.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // Configure A with the PN and trigger sync → router sets pendingDownloadFromPN + fires requestLink(pn).
    await a.send(.setPropagationNode(destinationHash: pnDest.hash))
    await a.send(.syncFromPropagationNode)
    await a.receive(aSend)                                   // LINKREQUEST out to PN

    // LINKREQUEST → PN; PN sends LRPROOF.
    eventsPN.yield(.data(sentA.value.last!))
    await pn.receive(epSend)                                 // LRPROOF out

    // LRPROOF → A: A becomes active. Within this single chain A also fires:
    //   LRRTT, then (linkEstablished → router.linkEstablished → pendingDownloadFromPN →
    //   requestMessageList → IDENTIFY + phase-1 /get).
    // All three sends (LRRTT, IDENTIFY, phase-1 /get) are emitted before the receive returns.
    let preLRPROOFIdx = sentA.value.count
    eventsA.yield(.data(sentPN.value.last!))
    await a.receive(aSend)                                   // LRRTT out
    await a.receive(aSend)                                   // IDENTIFY out
    await a.receive(aSend)                                   // phase-1 /get out
    let lrrttBytes = sentA.value[preLRPROOFIdx]
    let identifyBytes = sentA.value[preLRPROOFIdx + 1]
    let phase1ReqBytes = sentA.value[preLRPROOFIdx + 2]

    // LRRTT → PN; PN becomes active (linkEstablished on PN side).
    eventsPN.yield(.data(lrrttBytes))
    await pn.receive { if case .delegate(.linkEstablished) = $0 { return true }; return false }

    // Bridge IDENTIFY to PN.
    eventsPN.yield(.data(identifyBytes))
    await pn.receive { if case .delegate(.linkIdentified) = $0 { return true }; return false }

    // Bridge phase-1 /get to PN; PN surfaces requestReceived.
    let reqID1 = LockIsolated<Data?>(nil)
    eventsPN.yield(.data(phase1ReqBytes))
    await pn.receive { action in
        if case let .delegate(.requestReceived(_, rid, _, _)) = action { reqID1.setValue(rid); return true }
        return false
    }

    // PN responds with the transient id list.
    let phase1Resp = MsgPack.encode(.array([.bin(tid)]))
    let pnLinkID = pn.state.links[0].linkID
    await pn.send(.sendResponseOverLink(linkID: pnLinkID, requestID: reqID1.value!, data: phase1Resp))
    await pn.receive(epSend)                                 // response frame out

    // Bridge response to A → responseReceived (awaitingList) → offeredMessageList → requestMessages → phase-2 /get.
    eventsA.yield(.data(sentPN.value.last!))
    await a.receive { if case .endpoint(.delegate(.responseReceived)) = $0 { return true }; return false }
    await a.receive(aSend)                                   // phase-2 /get out
    let phase2ReqBytes = sentA.value.last!

    // Bridge phase-2 /get to PN; PN surfaces requestReceived.
    let reqID2 = LockIsolated<Data?>(nil)
    eventsPN.yield(.data(phase2ReqBytes))
    await pn.receive { action in
        if case let .delegate(.requestReceived(_, rid, _, _)) = action { reqID2.setValue(rid); return true }
        return false
    }

    // PN responds with the blob list. Reference LXMRouter serves the STAMPLESS entry (strips the
    // trailing stamp before serving, LXMRouter.py:1551), so the fixture serves strippedCore(entry);
    // the client computes transient_id = full_hash of the served bytes as-is, recovering `tid`.
    let phase2Resp = MsgPack.encode(.array([.bin(LXMFPropagation.strippedCore(lxmfData: entry))]))
    await pn.send(.sendResponseOverLink(linkID: pnLinkID, requestID: reqID2.value!, data: phase2Resp))
    await pn.receive(epSend)                                 // response frame out

    // Bridge response to A → responseReceived (awaitingMessages) → recoverPacked → received → messageDelivered.
    let gotContent = LockIsolated<Data?>(nil)
    let gotValidated = LockIsolated<Bool>(false)
    eventsA.yield(.data(sentPN.value.last!))
    await a.receive { if case .endpoint(.delegate(.responseReceived)) = $0 { return true }; return false }
    await a.receive { action in
        if case let .delegate(.messageReceived(m, v, _)) = action {
            gotContent.setValue(m.content)
            gotValidated.setValue(v)
            return true
        }
        return false
    }

    #expect(gotContent.value == Data("hi A".utf8))
    #expect(gotValidated.value == true)                        // A learned S → signature validates
    #expect(a.state.router.downloadedTransientIds.contains(tid))

    await a.send(.endpoint(.stop)); await s.send(.stop); await pn.send(.stop)
}

// MARK: - Unit: ordering and purge

/// IDENTIFY must be transmitted before the /get list request. The sequential `.run` in
/// `requestMessageList` guarantees this; a `.merge` would allow either order.
@MainActor @Test func syncIdentifiesBeforeRequesting() async {
    let identity = Identity()
    let linkID = Data(repeating: 0xAB, count: 16)

    var initialState = LXMFNode.State(
        identity: identity,
        endpoint: tcpDriverEndpoint(host: "h", port: 4242, reconnectOnDrop: false))
    initialState.syncPhase = [:]   // nothing pre-set

    let store = TestStore(initialState: initialState) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } },
                                         send: { _ in }, close: { })
    }
    store.exhaustivity = .off

    await store.send(.router(.delegate(.requestMessageList(linkID: linkID))))

    // The sequential .run guarantees IDENTIFY arrives before the /get request.
    var sawIdentify = false
    var sawRequest = false
    var identifyBeforeRequest = false

    await store.receive { action in
        if case let .endpoint(.identifyOverLink(lid, _)) = action, lid == linkID {
            sawIdentify = true
            return true
        }
        return false
    }
    identifyBeforeRequest = sawIdentify && !sawRequest

    await store.receive { action in
        if case let .endpoint(.sendRequestOverLink(lid, path, _)) = action, lid == linkID, path == "/get" {
            sawRequest = true
            return true
        }
        return false
    }

    #expect(sawIdentify)
    #expect(sawRequest)
    #expect(identifyBeforeRequest, "IDENTIFY must be emitted before the /get request")
}

/// After messagesDownloaded, a phase-3 purge /get [nil, [tid]] is emitted carrying the downloaded
/// transient_ids so the PN can evict them.
@MainActor @Test func syncPurgesAfterDownload() async {
    let aIdentity = Identity()
    let sIdentity = Identity()
    let aDeliveryHash = LXMessage.deliveryHash(identityHash: aIdentity.hash)
    let linkID = Data(repeating: 0xBC, count: 16)
    let requestID = Data(repeating: 0x01, count: 16)

    // Build a real stored message so recoverPacked succeeds and we get a real transient_id.
    let storedMsg = LXMessage.create(source: sIdentity, destinationHash: aDeliveryHash,
                                     timestamp: 1700000000.5, title: Data("t".utf8), content: Data("purge-me".utf8))
    let (container, tid) = await LXMFPropagation.pack(message: storedMsg, recipientIdentity: aIdentity,
                                                 timestamp: 1700000000.5, stampCost: 4)!
    let entry = LXMFPropagation.parseContainer(container)!.entries[0]  // stamped entry

    var initialState = LXMFNode.State(
        identity: aIdentity,
        endpoint: tcpDriverEndpoint(host: "h", port: 4242, reconnectOnDrop: false))
    // Put the link into awaitingMessages phase so responseReceived dispatches that branch.
    initialState.syncPhase[linkID] = .awaitingMessages

    let store = TestStore(initialState: initialState) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } },
                                         send: { _ in }, close: { })
    }
    store.exhaustivity = .off

    // Supply the PN response. Reference LXMRouter serves the STAMPLESS entry (LXMRouter.py:1551 strips
    // the trailing stamp before serving), so the fixture must too — the client's purge transient_id =
    // full_hash of the served bytes as-is, which equals the node's stored `tid`.
    let blobResponse = MsgPack.encode(.array([.bin(LXMFPropagation.strippedCore(lxmfData: entry))]))
    await store.send(.endpoint(.delegate(.responseReceived(linkID: linkID, requestID: requestID, data: blobResponse))))

    // Expect messagesDownloaded carrying the transient_id.
    await store.receive { action in
        if case let .router(.messagesDownloaded(tids)) = action { return tids.contains(tid) }
        return false
    }

    // Expect the purge /get: [null, [tid]].
    let expectedPurgeData = MsgPack.encode(.array([.null, .array([.bin(tid)])]))
    var gotPurge = false
    await store.receive { action in
        if case let .endpoint(.sendRequestOverLink(lid, path, data)) = action,
           lid == linkID, path == "/get", data == expectedPurgeData {
            gotPurge = true
            return true
        }
        return false
    }
    #expect(gotPurge, "Phase-3 purge /get must be sent after messagesDownloaded")
}

/// The phase-2 fetch (`requestMessages`) must carry a POSITIVE per-transfer limit as data[2].
/// lxmd (LXMRouter.py:1528/1547) reads `float(data[2])*1000` as a byte cap and skips every message
/// larger than it — a 0 there means "serve nothing", so the recipient would download an empty set.
@MainActor @Test func syncPhase2FetchCarriesPositiveTransferLimit() async {
    let identity = Identity()
    let linkID = Data(repeating: 0xCD, count: 16)
    let want = Data(repeating: 0x11, count: 16)
    let have = Data(repeating: 0x22, count: 16)

    let store = TestStore(initialState: LXMFNode.State(
        identity: identity,
        endpoint: tcpDriverEndpoint(host: "h", port: 4242, reconnectOnDrop: false))
    ) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } },
                                         send: { _ in }, close: { })
    }
    store.exhaustivity = .off

    await store.send(.router(.delegate(.requestMessages(linkID: linkID, wants: [want], haves: [have]))))

    // The emitted phase-2 /get payload must be [[want], [have], .uint(positive)] — never .uint(0).
    let expected = MsgPack.encode(.array([.array([.bin(want)]),
                                          .array([.bin(have)]),
                                          .uint(LXMFNode.propagationTransferLimitKB)]))
    var gotFetch = false
    await store.receive { action in
        if case let .endpoint(.sendRequestOverLink(lid, path, data)) = action,
           lid == linkID, path == "/get", data == expected {
            gotFetch = true
            return true
        }
        return false
    }
    #expect(gotFetch, "phase-2 /get must carry [wants, haves, .uint(limit)]")
    #expect(LXMFNode.propagationTransferLimitKB > 0, "transfer limit must be positive (0 = lxmd serves nothing)")
}
