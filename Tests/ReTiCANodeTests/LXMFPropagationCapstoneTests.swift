import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// Full store-and-forward loop over real transport: real LXMFNode sender S sends a message to recipient R
/// VIA a real PNNode PN; PN ingests it; R (real LXMFNode) syncs from PN and receives S's signature-valid
/// message. Proves the P1 send + P3b ingest + P3b serve + P2 sync compositions interoperate end-to-end
/// (each half previously proven only against a stub of the other).
@Test @MainActor func lxmfPropagationCapstoneSenderPnRecipient() async {
    let clock = TestClock()
    let sIdentity = Identity()      // sender
    let rIdentity = Identity()      // recipient
    let pnIdentity = Identity()     // propagation node

    let rDeliveryHash = LXMessage.deliveryHash(identityHash: rIdentity.hash)
    let sDeliveryHash = LXMessage.deliveryHash(identityHash: sIdentity.hash)

    let pnPropDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                 aspects: ["propagation"], identity: pnIdentity)!

    // --- Helpers to build LXMFNode and PNNode stores with isolated TCP ---

    func makeNode(_ host: String, _ identity: Identity, _ sent: LockIsolated<[Data]>)
        -> (TestStore<LXMFNode.State, LXMFNode.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: LXMFNode.State(
            identity: identity, endpoint: TCPEndpoint.State(host: host, port: 4242, reconnectOnDrop: false))
        ) { LXMFNode() } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } }, close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    func makePN(_ host: String, _ identity: Identity, _ sent: LockIsolated<[Data]>)
        -> (TestStore<PNNode.State, PNNode.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: PNNode.State(
            identity: identity, endpoint: TCPEndpoint.State(host: host, port: 4242, reconnectOnDrop: false),
            minStampCost: 0)
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

    // Send-frame predicates.
    func sSend(_ act: LXMFNode.Action) -> Bool { if case .endpoint(.tcp(.interface(.send))) = act { return true }; return false }
    func rSend(_ act: LXMFNode.Action) -> Bool { if case .endpoint(.tcp(.interface(.send))) = act { return true }; return false }
    func pnSend(_ act: PNNode.Action) -> Bool { if case .endpoint(.interface(.send)) = act { return true }; return false }

    let sentS  = LockIsolated<[Data]>([])
    let sentR  = LockIsolated<[Data]>([])
    let sentPN = LockIsolated<[Data]>([])

    let (s, eventsS)   = makeNode("s", sIdentity, sentS)
    let (r, eventsR)   = makeNode("r", rIdentity, sentR)
    let (pn, eventsPN) = makePN("pn", pnIdentity, sentPN)

    // Connect all three.
    await s.send(.endpoint(.start));  eventsS.yield(.connected)
    await r.send(.endpoint(.start));  eventsR.yield(.connected)
    await pn.send(.endpoint(.connect)); eventsPN.yield(.connected)

    // ─────────────────────────────────────────────────────────────────────────────
    // ANNOUNCE PHASE
    //
    // R.registerDelivery → announce → bridge to S  (S needs R's identity to encrypt the container)
    // S.registerDelivery → announce → bridge to R  (R needs S's identity to validate the signature)
    // PN.registerPropagation → announce → bridge to S AND R  (both link to PN)
    // ─────────────────────────────────────────────────────────────────────────────

    // R announces its delivery destination → S learns R's identity.
    await r.send(.registerDelivery)
    await r.receive { if case .endpoint(.registerLocalDestination) = $0 { return true }; return false }
    await r.receive(rSend)                                    // announce frame out
    eventsS.yield(.data(sentR.value.last!))
    await s.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // S announces its delivery destination → R learns S's identity (for signature validation).
    await s.send(.registerDelivery)
    await s.receive { if case .endpoint(.registerLocalDestination) = $0 { return true }; return false }
    await s.receive(sSend)                                    // announce frame out
    eventsR.yield(.data(sentS.value.last!))
    await r.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // PN.registerPropagation → registers + announces lxmf.propagation; bridge to S and R.
    await pn.send(.registerPropagation)
    await pn.receive { if case .endpoint(.registerLocalDestination) = $0 { return true }; return false }
    await pn.receive(pnSend)                                  // announce frame out
    let pnAnnounce = sentPN.value.last!
    eventsS.yield(.data(pnAnnounce))
    await s.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }
    eventsR.yield(.data(pnAnnounce))
    await r.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // ─────────────────────────────────────────────────────────────────────────────
    // SEND PHASE: S → PN ingest
    //
    // S.setPropagationNode + S.sendViaPropagation → S↔PN link handshake + Resource transfer → PN ingests
    // ─────────────────────────────────────────────────────────────────────────────

    let messageContent = Data("store and forward".utf8)
    await s.send(.setPropagationNode(destinationHash: pnPropDest.hash))
    await s.send(.sendViaPropagation(destinationHash: rDeliveryHash,
                                     title: Data("t".utf8),
                                     content: messageContent))
    await s.receive(sSend)                                    // LINKREQUEST out to PN

    // Link handshake S ↔ PN (mirrors LXMFNodePropagationTests).
    // Step 1: LINKREQUEST → PN; PN sends LRPROOF.
    eventsPN.yield(.data(sentS.value.last!))
    await pn.receive(pnSend)                                  // LRPROOF out

    // Step 2: LRPROOF → S; S goes active and the router immediately drains the propagation queue. The SMALL
    // container (<= Link.mdu = 431) takes the packet route (sendWithReceiptOverLink) rather than Resource,
    // so the link data packet co-fires with LRRTT in this chain; capture both by index.
    let afterLrproofS = sentS.value.count
    eventsS.yield(.data(sentPN.value.last!))
    await s.receive(sSend)                                    // LRRTT out
    let lrrttBytesS = sentS.value[afterLrproofS]
    let propPacketBytes = sentS.value[afterLrproofS + 1]     // link data packet (receipt-tracked container)

    // LRRTT → PN; PN becomes active (linkEstablished both sides).
    eventsPN.yield(.data(lrrttBytesS))
    await s.receive { if case .endpoint(.delegate(.linkEstablished)) = $0 { return true }; return false }
    await pn.receive { if case .endpoint(.delegate(.linkEstablished)) = $0 { return true }; return false }
    await s.receive(sSend)                                    // link data packet (already queued in S's store)

    // PN genuinely receives the link data packet → linkDataReceived → ingestContainer → messagesStored.
    // This node is a bare `LXMFNode` (not `LXMFServiceNode`), acting as a RECEIVE-side PN. `LXMFNode`
    // is a non-proving client: it does NOT auto-prove inbound link packets (matching RNS's default
    // prove-none strategy). `LXMFServiceNode.linkDataReceived` is the place that proves propagation
    // offers — that path is covered by serviceNodeProvesPacketOfferOnPropagationLink. So no DATA_PROOF
    // is emitted by the bare PN here; the capstone drives a synthetic proof below to unblock S.
    let gotTid = LockIsolated<Data?>(nil)
    eventsPN.yield(.data(propPacketBytes))
    await pn.receive { action in
        if case let .delegate(.messagesStored(tids)) = action {
            gotTid.setValue(tids.first)
            return true
        }
        return false
    }
    #expect(gotTid.value != nil)                              // PN has ingested the container

    // Drive the genuine ack by injecting a synthetic signed DATA_PROOF into S's LinkSession (stands in for
    // a proving PN). Non-circular: the proof carries a REAL Ed25519 signature by pnIdentity (S's link peer)
    // over the REAL hash of the packet S actually sent. Mirrors LinkSessionReceiptTests.
    // propPacketBytes is HDLC-framed at the interface level; deframe to recover the raw packet, then hash it.
    let sLinkID = s.state.endpoint.links[0].linkID
    var deframer = HDLCDeframer()
    let rawPropPacket = deframer.ingest(propPacketBytes).first!
    let sentPacketHash = Packet(raw: rawPropPacket)!.packetHash
    let proofSig = pnIdentity.sign(sentPacketHash)
    let proofPacket = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                             destinationType: .link, context: .none, contextFlag: false, hops: 0,
                             destinationHash: sLinkID, transportId: nil, payload: sentPacketHash + proofSig)
    // Inbound bytes are HDLC-framed at the interface; frame the synthetic proof before feeding it in.
    eventsS.yield(.data(HDLC.frame(try! proofPacket.packed())))  // DATA_PROOF → S: packetDelivered → delivered → propagationAccepted
    await s.receive { if case .delegate(.propagationAccepted) = $0 { return true }; return false }

    // ─────────────────────────────────────────────────────────────────────────────
    // SYNC PHASE: R ← PN serve
    //
    // R.setPropagationNode + R.syncFromPropagationNode → R↔PN link handshake + IDENTIFY
    // + phase-1 /get (PN serves id list) + phase-2 /get (PN serves blob) → R opens → messageReceived
    // ─────────────────────────────────────────────────────────────────────────────

    await r.send(.setPropagationNode(destinationHash: pnPropDest.hash))
    await r.send(.syncFromPropagationNode)
    await r.receive(rSend)                                    // LINKREQUEST out to PN

    // Link handshake R ↔ PN (mirrors LXMFNodeSyncTests).
    // Step 1: LINKREQUEST → PN; PN sends LRPROOF.
    eventsPN.yield(.data(sentR.value.last!))
    await pn.receive(pnSend)                                  // LRPROOF out

    // Step 2: LRPROOF → R; R sends LRRTT + IDENTIFY + phase-1 /get (all co-emit, capture by index).
    let afterLrproofR = sentR.value.count
    eventsR.yield(.data(sentPN.value.last!))
    await r.receive(rSend)                                    // LRRTT out
    await r.receive(rSend)                                    // IDENTIFY out
    await r.receive(rSend)                                    // phase-1 /get out
    let lrrttBytesR    = sentR.value[afterLrproofR]
    let identifyBytes  = sentR.value[afterLrproofR + 1]
    let phase1ReqBytes = sentR.value[afterLrproofR + 2]

    // Step 3: LRRTT → PN; PN becomes active (R's linkEstablished already fired with LRPROOF chain).
    eventsPN.yield(.data(lrrttBytesR))
    await pn.receive { if case .endpoint(.delegate(.linkEstablished)) = $0 { return true }; return false }

    // Bridge IDENTIFY to PN → PN surfaces linkIdentified (stores R's identity for /get dispatch).
    eventsPN.yield(.data(identifyBytes))
    await pn.receive { if case .endpoint(.delegate(.linkIdentified)) = $0 { return true }; return false }

    // Bridge phase-1 /get to PN → PN dispatches messageListRequested → deliverMessageList → response out.
    eventsPN.yield(.data(phase1ReqBytes))
    await pn.receive { if case .endpoint(.delegate(.requestReceived)) = $0 { return true }; return false }
    await pn.receive(pnSend)                                  // phase-1 response (id list) out

    // Bridge phase-1 response to R → responseReceived (awaitingList) → offeredMessageList → phase-2 /get.
    eventsR.yield(.data(sentPN.value.last!))
    await r.receive { if case .endpoint(.delegate(.responseReceived)) = $0 { return true }; return false }
    await r.receive(rSend)                                    // phase-2 /get out
    let phase2ReqBytes = sentR.value.last!

    // Bridge phase-2 /get to PN → PN dispatches messagesRequested → deliverMessages → response out.
    eventsPN.yield(.data(phase2ReqBytes))
    await pn.receive { if case .endpoint(.delegate(.requestReceived)) = $0 { return true }; return false }
    await pn.receive(pnSend)                                  // phase-2 response (blob list) out

    // Bridge phase-2 response to R → responseReceived (awaitingMessages) → recoverPacked → received → messageDelivered.
    let gotContent   = LockIsolated<Data?>(nil)
    let gotSrcHash   = LockIsolated<Data?>(nil)
    let gotValidated = LockIsolated<Bool>(false)
    eventsR.yield(.data(sentPN.value.last!))
    await r.receive { if case .endpoint(.delegate(.responseReceived)) = $0 { return true }; return false }
    await r.receive { action in
        if case let .delegate(.messageReceived(m, v)) = action {
            gotContent.setValue(m.content)
            gotSrcHash.setValue(m.sourceHash)
            gotValidated.setValue(v)
            return true
        }
        return false
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // FINAL ASSERTIONS (load-bearing — do not change)
    // ─────────────────────────────────────────────────────────────────────────────
    #expect(gotContent.value == messageContent)  // == what S sent
    #expect(gotSrcHash.value == sDeliveryHash)                   // from S
    #expect(gotValidated.value == true)                          // R learned S → signature validates

    // Disconnect all.
    await s.send(.endpoint(.stop))
    await r.send(.endpoint(.stop))
    await pn.send(.endpoint(.disconnect))
}
