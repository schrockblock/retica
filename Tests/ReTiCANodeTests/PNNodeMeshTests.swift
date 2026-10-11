import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// Full bidirectional PN↔PN mesh over a real link with non-zero peering cost: PN-A syncs to PN-B (cost 8).
/// A generates a real cost-8 peering key via the async offerKeyReady effect; B validates and accepts it;
/// A transfers its stored message; B ingests. Proves peering-cost enforcement end-to-end.
@Test @MainActor func pnNodeMeshSyncEnforcesPeeringCost() async {
    let clock = TestClock()
    let aIdentity = Identity()
    let bIdentity = Identity()
    let sender = Identity()
    let recipient = Identity()

    // Build the message + container that A will hold and sync to B.
    let msg = LXMessage.create(source: sender,
                               destinationHash: LXMessage.deliveryHash(identityHash: recipient.hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("mesh".utf8))
    let (container, tid) = await LXMFPropagation.pack(message: msg, recipientIdentity: recipient, timestamp: 1700000000.5, stampCost: 4)!

    // B's lxmf.propagation destination (the dest A will sync to).
    let bPropDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                aspects: ["propagation"], identity: bIdentity)!

    // Build a PNNode TestStore with isolated TCP (frames captured in sent).
    func makePN(_ host: String, _ identity: Identity, _ sent: LockIsolated<[Data]>)
        -> (TestStore<PNNode.State, PNNode.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: PNNode.State(
            identity: identity, endpoint: TCPEndpoint.State(host: host, port: 4242, reconnectOnDrop: false),
            minStampCost: 4, peeringCost: host == "b" ? 8 : 0)
        ) { PNNode() } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } }, close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    // Send-frame predicates.
    func aSend(_ act: PNNode.Action) -> Bool { if case .endpoint(.tcpClients(.element(id: _, action: .interface(.send)))) = act { return true }; return false }
    func bSend(_ act: PNNode.Action) -> Bool { if case .endpoint(.tcpClients(.element(id: _, action: .interface(.send)))) = act { return true }; return false }

    let sentA = LockIsolated<[Data]>([])
    let sentB = LockIsolated<[Data]>([])
    let (a, eventsA) = makePN("a", aIdentity, sentA)
    let (b, eventsB) = makePN("b", bIdentity, sentB)

    // Connect both.
    await a.send(.endpoint(.start)); eventsA.yield(.connected)
    await b.send(.endpoint(.start)); eventsB.yield(.connected)

    // --- Pre-populate A's store: inject a dummy resourceReceived so A holds `tid`. ---
    let dummyLinkID = Data(repeating: 0xAA, count: 16)
    await a.send(.endpoint(.delegate(.resourceReceived(linkID: dummyLinkID, data: container))))
    await a.receive { if case .delegate(.messagesStored) = $0 { return true }; return false }
    #expect(a.state.node.store.contains(transientId: tid))

    // --- B.registerPropagation → announces lxmf.propagation; bridge the announce to A. ---
    await b.send(.registerPropagation)
    await b.receive { if case .endpoint(.registerLocalDestination) = $0 { return true }; return false }
    await b.receive(bSend)   // announce frame out

    // Bridge B's announce to A so A learns B's lxmf.propagation destination + identity.
    eventsA.yield(.data(sentB.value.last!))
    await a.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // --- A.syncToPeer(bPropDest.hash) → A opens link to B. ---
    await a.send(.syncToPeer(destinationHash: bPropDest.hash, peeringCost: 8))
    await a.receive { if case .endpoint(.openLink) = $0 { return true }; return false }
    await a.receive(aSend)   // LINKREQUEST out

    // --- Link handshake A (initiator) ↔ B (responder). ---
    // Step 1: LINKREQUEST → B; B sends LRPROOF.
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(bSend)   // LRPROOF out

    // Step 2: LRPROOF → A; A sends LRRTT (and linkEstablished fires A-side, emitting IDENTIFY + /offer).
    // A's linkEstablished fires before B receives LRRTT — so LRRTT, IDENTIFY, and /offer all
    // co-emit when A processes the LRPROOF. Capture all three by index snapshot.
    let afterLrproof = sentA.value.count
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(aSend)   // LRRTT out
    await a.receive { if case .endpoint(.delegate(.linkEstablished)) = $0 { return true }; return false }
    await a.receive(aSend)   // IDENTIFY out
    await a.receive { if case .offerKeyReady = $0 { return true }; return false }  // async cost-8 key-gen completes
    await a.receive(aSend)   // /offer REQUEST out

    let lrrttBytes    = sentA.value[afterLrproof]
    let identifyBytes = sentA.value[afterLrproof + 1]
    let offerBytes    = sentA.value[afterLrproof + 2]

    // Step 3: LRRTT → B; B becomes active.
    eventsB.yield(.data(lrrttBytes))
    await b.receive { if case .endpoint(.delegate(.linkEstablished)) = $0 { return true }; return false }

    // --- Bridge IDENTIFY to B → B surfaces linkIdentified. ---
    eventsB.yield(.data(identifyBytes))
    await b.receive { if case .endpoint(.delegate(.linkIdentified)) = $0 { return true }; return false }

    // --- Bridge /offer REQUEST to B → B validates peering key → sends wanted list. ---
    eventsB.yield(.data(offerBytes))
    await b.receive { if case .endpoint(.delegate(.requestReceived)) = $0 { return true }; return false }
    // B validates (cost 8 → A's generated cost-8 key passes) → requestFromPeer → sendResponseOverLink.
    await b.receive(bSend)   // /offer response (wanted list) out

    // --- Bridge B's response back to A → A builds container and sends as Resource. ---
    eventsA.yield(.data(sentB.value.last!))
    await a.receive { if case .endpoint(.delegate(.responseReceived)) = $0 { return true }; return false }
    // A receives the wanted list → sendResourceOverLink.
    await a.receive(aSend)   // RESOURCE_ADV out

    // --- Bridge the Resource frames from A to B. ---
    // ADV → B: B spawns a receiver, emits RESOURCE_REQ.
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(bSend)   // RESOURCE_REQ out

    // REQ → A: A serves its parts.
    eventsA.yield(.data(sentB.value.last!))
    let partCount = a.state.endpoint.links[0].transfers[0].parts.count
    for _ in 0..<partCount { await a.receive(aSend) }

    // Deliver all part frames to B; on the last part B emits PRF + resourceReceived → ingest → messagesStored.
    let parts = Array(sentA.value.suffix(partCount))
    for (i, frame) in parts.enumerated() {
        eventsB.yield(.data(frame))
        if i == partCount - 1 {
            await b.receive(bSend)   // RESOURCE_PRF out
            await b.receive { action in
                if case let .delegate(.messagesStored(tids)) = action {
                    #expect(tids == [tid])
                    return true
                }
                return false
            }
        }
    }

    // --- Final assertions: B now holds A's message. ---
    #expect(b.state.node.store.contains(transientId: tid))

    await a.send(.endpoint(.stop))
    await b.send(.endpoint(.stop))
}
