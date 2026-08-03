import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// End-to-end through the LXMFNode composition: node A delivers a large LXMF message to node B directly
/// over a Link (as a Resource), and B's LXMFNode surfaces the reconstructed, signature-validated message.
/// Then B's RESOURCE_PRF is bridged back to A so A's resourceConcluded fires, which LXMFNode maps through
/// to deliveryConfirmed — proving the full round-trip.
///
/// Key sequencing note (vs. the brief's skeleton): TCA processes the entire chain
/// LRRTT-transmit → link.established → LXMFNode.linkEstablished → router.drain → sendDirect →
/// endpoint.sendResourceOverLink → RESOURCE_ADV within a single `await a.receive(isInterfaceSend)`
/// call for LRRTT. So both sentA[lrrttIdx] and sentA[lrrttIdx+1] are written before that receive
/// returns. Byte bridging uses explicit index arithmetic rather than `sentA.value.last!`.
@Test @MainActor func lxmfNodeDirectDeliversResourceAndConfirms() async {
    let clock = TestClock()
    let aIdentity = Identity()
    let bIdentity = Identity()
    let bDeliveryHash = LXMessage.deliveryHash(identityHash: bIdentity.hash)

    func make(_ host: String, _ identity: Identity, _ sent: LockIsolated<[Data]>)
        -> (TestStore<LXMFNode.State, LXMFNode.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: LXMFNode.State(
            identity: identity, endpoint: TCPEndpoint.State(host: host, port: 4242, reconnectOnDrop: false))
        ) {
            LXMFNode()
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } },
                                             close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    // Predicate helpers for the .off store (everything is wrapped under .endpoint(...)).
    func isInterfaceSend(_ a: LXMFNode.Action) -> Bool {
        if case .endpoint(.interface(.send)) = a { return true }; return false
    }

    let sentA = LockIsolated<[Data]>([]); let sentB = LockIsolated<[Data]>([])
    let (a, eventsA) = make("a", aIdentity, sentA)
    let (b, eventsB) = make("b", bIdentity, sentB)

    await a.send(.endpoint(.connect)); eventsA.yield(.connected)
    await b.send(.endpoint(.connect)); eventsB.yield(.connected)

    // Both register + announce; bridge announces so A learns B (path + identity for signing/validation)
    // and B learns A (identity — B validates A's signature).
    await a.send(.registerDelivery)
    await a.receive(isInterfaceSend)
    await b.send(.registerDelivery)
    await b.receive(isInterfaceSend)
    eventsA.yield(.data(sentB.value.last!))                 // B's announce → A learns B
    await a.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!))                 // A's announce → B learns A
    await b.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // A sends a LARGE message to B via .direct → router establishes a link (path already known),
    // then sends the message as a Resource. First: the LINKREQUEST goes out.
    let bigContent = Data((0..<800).map { UInt8($0 & 0xff) })
    // Recover the deterministic message hash by rebuilding with the same params (timestamp from the fixed date).
    let sentMessageHash = LXMessage.create(
        source: aIdentity, destinationHash: bDeliveryHash,
        timestamp: 1700000000.5, title: Data("big".utf8), content: bigContent).hash
    await a.send(.send(destinationHash: bDeliveryHash, title: Data("big".utf8), content: bigContent, method: .direct))
    await a.receive(isInterfaceSend)                        // LINKREQUEST out

    // Link handshake (mirrors LXMFDirectDeliveryTests steps 2–4, wrapped through LXMFNode).
    //
    // Step 2: LINKREQUEST → B; B sends LRPROOF.
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(isInterfaceSend)                        // LRPROOF out
    let lrproofBytes = sentB.value.last!                    // capture LRPROOF

    // Step 3: LRPROOF → A; A sends LRRTT AND (via the linkEstablished chain) RESOURCE_ADV in the
    // same receive call. Capture LRRTT by index before the receive so we know its position.
    let lrrttIdx = sentA.value.count                        // LRRTT will land at this index
    eventsA.yield(.data(lrproofBytes))
    await a.receive(isInterfaceSend)                        // LRRTT out (RESOURCE_ADV also fires here)
    let lrrttBytes = sentA.value[lrrttIdx]                  // LRRTT bytes (not last! which is RESOURCE_ADV)
    let resourceAdvBytes = sentA.value[lrrttIdx + 1]        // RESOURCE_ADV bytes (second send of this chain)

    // Step 4: LRRTT → B; B becomes active.
    eventsB.yield(.data(lrrttBytes))
    await a.receive { if case .endpoint(.delegate(.linkEstablished)) = $0 { return true }; return false }
    await b.receive { if case .endpoint(.delegate(.linkEstablished)) = $0 { return true }; return false }

    // Link is active on both ends; router already drained → RESOURCE_ADV was emitted in step 3.
    await a.receive(isInterfaceSend)                        // RESOURCE_ADV (already queued in store)

    // ADV → B: B spawns a receiver, emits RESOURCE_REQ.
    eventsB.yield(.data(resourceAdvBytes))
    await b.receive(isInterfaceSend)                        // RESOURCE_REQ out
    let resourceReqBytes = sentB.value.last!               // capture RESOURCE_REQ bytes

    // REQ → A: A serves its parts.
    eventsA.yield(.data(resourceReqBytes))
    let partCount = a.state.endpoint.links[0].transfers[0].parts.count
    for _ in 0..<partCount { await a.receive(isInterfaceSend) }

    // Deliver every part frame A emitted (the last `partCount` frames in sentA) to B.
    let parts = Array(sentA.value.suffix(partCount))
    let gotContent = LockIsolated<Data?>(nil)
    let gotTitle = LockIsolated<Data?>(nil)
    let gotSrcHash = LockIsolated<Data?>(nil)
    let gotValidated = LockIsolated<Bool>(false)
    let resourcePrfBytes = LockIsolated<Data?>(nil)
    for (i, frame) in parts.enumerated() {
        eventsB.yield(.data(frame))
        if i == partCount - 1 {
            await b.receive(isInterfaceSend)               // RESOURCE_PRF out
            resourcePrfBytes.setValue(sentB.value.last!)   // capture RESOURCE_PRF before messageReceived
            await b.receive { action in
                if case let .delegate(.messageReceived(m, v)) = action {
                    gotContent.setValue(m.content)
                    gotTitle.setValue(m.title)
                    gotSrcHash.setValue(m.sourceHash)
                    gotValidated.setValue(v)
                    return true
                }
                return false
            }
        }
    }

    #expect(gotContent.value == bigContent)
    #expect(gotTitle.value == Data("big".utf8))
    #expect(gotSrcHash.value == LXMessage.deliveryHash(identityHash: aIdentity.hash))
    #expect(gotValidated.value == true)                    // B learned A's identity → signature validates

    // B's RESOURCE_PRF → A: A concludes the resource, which LXMFNode maps
    // resourceConcluded → router.resourceDeliveredOnLink → deliveryConfirmed.
    let gotConfirmed = LockIsolated<Data?>(nil)
    eventsA.yield(.data(resourcePrfBytes.value!))
    await a.receive { action in
        if case let .delegate(.deliveryConfirmed(hash)) = action { gotConfirmed.setValue(hash); return true }
        return false
    }
    #expect(gotConfirmed.value == sentMessageHash)         // the hash of the message A sent

    await a.send(.endpoint(.disconnect)); await b.send(.endpoint(.disconnect))
}
