import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// End-to-end over a real link: client C sends a container to a PNNode (ingested), then C IDENTIFYs and
/// runs the two-phase /get; the PN serves C's message list and blob, and C opens the blob to the original
/// signature-valid message. Closes the store-and-forward server loop at the wire level. (Full 3-store
/// LXMFNode↔PNNode↔LXMFNode loop is a capstone follow-on.)
@Test @MainActor func pnNodeIngestsAndServesOverRealLink() async {
    let clock = TestClock()
    let pnIdentity = Identity()
    let cIdentity = Identity()      // the client AND the recipient of the stored message
    let sIdentity = Identity()      // the original sender
    let cDeliveryHash = LXMessage.deliveryHash(identityHash: cIdentity.hash)

    // The message C will retrieve, packed as a container for C.
    let msg = LXMessage.create(source: sIdentity, destinationHash: cDeliveryHash,
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("hi C".utf8))
    let (container, tid) = LXMFPropagation.pack(message: msg, recipientIdentity: cIdentity, timestamp: 1700000000.5, stampCost: 4)
    let entry = LXMFPropagation.parseContainer(container)!.entries[0]  // stamped — what PN stores and serves

    // makePN: builds a PNNode TestStore with isolated TCP (sends captured in sentPN).
    func makePN(_ host: String, _ identity: Identity, _ sent: LockIsolated<[Data]>)
        -> (TestStore<PNNode.State, PNNode.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: PNNode.State(
            identity: identity, endpoint: Endpoint.State(host: host, port: 4242, reconnectOnDrop: false),
            minStampCost: 4)
        ) { PNNode() } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } }, close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    // makeClient: builds a bare Endpoint TestStore for client C.
    func makeClient(_ host: String, _ sent: LockIsolated<[Data]>)
        -> (TestStore<Endpoint.State, Endpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: Endpoint.State(host: host, port: 4242, reconnectOnDrop: false)) {
            Endpoint()
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

    // Predicate helpers.
    func pnSend(_ act: PNNode.Action) -> Bool { if case .endpoint(.interface(.send)) = act { return true }; return false }
    func cSend(_ act: Endpoint.Action) -> Bool { if case .interface(.send) = act { return true }; return false }

    let sentPN = LockIsolated<[Data]>([])
    let sentC  = LockIsolated<[Data]>([])
    let (pn, eventsPN) = makePN("pn", pnIdentity, sentPN)
    let (c, eventsC)   = makeClient("c", sentC)

    // Connect both.
    await pn.send(.endpoint(.connect)); eventsPN.yield(.connected)
    await c.send(.connect); eventsC.yield(.connected)

    // PN.registerPropagation → registers lxmf.propagation dest + announces.
    await pn.send(.registerPropagation)
    await pn.receive { if case .endpoint(.registerLocalDestination) = $0 { return true }; return false }
    await pn.receive(pnSend)   // announce frame out

    // Bridge the announce to C so C learns the PN's lxmf.propagation destination + identity.
    eventsC.yield(.data(sentPN.value.last!))
    await c.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }

    // C opens a link to the PN's propagation destination.
    let pnPropDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                 aspects: ["propagation"], identity: pnIdentity)!
    await c.send(.openLink(destinationHash: pnPropDest.hash))
    await c.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await c.receive(cSend)     // LINKREQUEST out

    // Link handshake C ↔ PN.
    // Step 1: LINKREQUEST → PN; PN sends LRPROOF.
    eventsPN.yield(.data(sentC.value.last!))
    await pn.receive(pnSend)   // LRPROOF out

    // Step 2: LRPROOF → C; C sends LRRTT (and RESOURCE_ADV if a resource was queued, but here none yet).
    let lrrttIdx = sentC.value.count
    eventsC.yield(.data(sentPN.value.last!))
    await c.receive(cSend)     // LRRTT out
    let lrrttBytes = sentC.value[lrrttIdx]

    // Step 3: LRRTT → PN; both become active.
    eventsPN.yield(.data(lrrttBytes))
    await c.receive { if case .delegate(.linkEstablished) = $0 { return true }; return false }
    await pn.receive { if case .endpoint(.delegate(.linkEstablished)) = $0 { return true }; return false }

    let linkID = c.state.links[0].linkID

    // --- C sends the container as a Resource to PN ---
    await c.send(.sendResourceOverLink(linkID: linkID, data: container))
    await c.receive(cSend)     // RESOURCE_ADV out

    // ADV → PN: PN spawns a receiver, emits RESOURCE_REQ.
    eventsPN.yield(.data(sentC.value.last!))
    await pn.receive(pnSend)   // RESOURCE_REQ out

    // REQ → C: C serves its parts.
    eventsC.yield(.data(sentPN.value.last!))
    let partCount = c.state.links[0].transfers[0].parts.count
    for _ in 0..<partCount { await c.receive(cSend) }

    // Deliver all part frames to PN; on the last part PN emits PRF + resourceReceived → ingest → messagesStored.
    let parts = Array(sentC.value.suffix(partCount))
    for (i, frame) in parts.enumerated() {
        eventsPN.yield(.data(frame))
        if i == partCount - 1 {
            await pn.receive(pnSend)   // RESOURCE_PRF out
            await pn.receive { action in
                if case let .delegate(.messagesStored(tids)) = action {
                    #expect(tids == [tid])
                    return true
                }
                return false
            }
        }
    }

    // --- C identifies over the link ---
    await c.send(.identifyOverLink(linkID: linkID, identity: cIdentity))
    await c.receive(cSend)     // IDENTIFY frame out

    eventsPN.yield(.data(sentC.value.last!))
    await pn.receive { if case .endpoint(.delegate(.linkIdentified)) = $0 { return true }; return false }

    // --- Phase-1 /get: [null, null] → PN returns id list [[tid]] ---
    let getPath = "/get"
    let phase1Data = MsgPack.encode(.array([.null, .null]))
    await c.send(.sendRequestOverLink(linkID: linkID, path: getPath, data: phase1Data))
    await c.receive(cSend)     // REQUEST frame out

    let reqID1 = LockIsolated<Data?>(nil)
    eventsPN.yield(.data(sentC.value.last!))
    await pn.receive { action in
        if case let .endpoint(.delegate(.requestReceived(_, rid, _, _))) = action { reqID1.setValue(rid); return true }
        return false
    }

    // PN now sends the response (sendResponseOverLink → interface.send).
    await pn.receive(pnSend)   // response frame out

    let gotList = LockIsolated<Data?>(nil)
    eventsC.yield(.data(sentPN.value.last!))
    await c.receive { action in
        if case let .delegate(.responseReceived(_, _, d)) = action { gotList.setValue(d); return true }
        return false
    }

    // --- Phase-2 /get: [[tid],[]] → PN returns blob [[entry]] ---
    let phase2Data = MsgPack.encode(.array([.array([.bin(tid)]), .array([])]))
    await c.send(.sendRequestOverLink(linkID: linkID, path: getPath, data: phase2Data))
    await c.receive(cSend)     // REQUEST frame out

    eventsPN.yield(.data(sentC.value.last!))
    await pn.receive { action in
        if case .endpoint(.delegate(.requestReceived)) = action { return true }
        return false
    }

    // PN sends the blob response.
    await pn.receive(pnSend)   // response frame out

    let gotBlob = LockIsolated<Data?>(nil)
    eventsC.yield(.data(sentPN.value.last!))
    await c.receive { action in
        if case let .delegate(.responseReceived(_, _, d)) = action { gotBlob.setValue(d); return true }
        return false
    }

    // --- Final assertions ---
    #expect(MsgPack.decodeValue(gotList.value!) == .array([.bin(tid)]))
    let served = MsgPack.decodeValue(gotBlob.value!)
    #expect(served == .array([.bin(entry)]))
    let recovered = LXMFPropagation.open(lxmfData: entry, recipientIdentity: cIdentity)
    #expect(recovered?.content == Data("hi C".utf8))
    #expect(recovered?.validateSignature(source: sIdentity) == true)

    await pn.send(.endpoint(.disconnect)); await c.send(.disconnect)
}
