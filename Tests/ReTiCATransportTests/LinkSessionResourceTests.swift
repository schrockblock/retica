import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

private let resKey = Data(repeating: 0x01, count: 64)
private let resLinkID = Data(repeating: 0xAB, count: 16)

@MainActor
private func activeLinkStore(_ clock: TestClock<Duration>) -> TestStore<LinkSession.State, LinkSession.Action> {
    var s = LinkSession.State(responderFor: Identity(),
                              destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"))
    s.status = .active
    s.sessionKey = resKey
    s.linkID = resLinkID
    s.rtt = 1.0
    let store = TestStore(initialState: s) { LinkSession() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = clock
        $0.uuid = .incrementing
        // randomBytes uses its deterministic testValue by default
    }
    store.exhaustivity = .off
    return store
}

// A sender ResourceTransfer over the same link/key, used to synthesize inbound packets.
private func senderFor(_ data: Data, sdu: Int = 24) -> ResourceTransfer.State {
    ResourceTransfer.State(sending: data, linkID: resLinkID, sessionKey: resKey,
                           interfaceID: InterfaceID("i"), prefix: Data([0, 1, 2, 3]),
                           randomHash: Data([4, 5, 6, 7]), sdu: sdu)
}

private func advPacket(_ s: ResourceTransfer.State) -> Data {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .resourceAdvertisement, contextFlag: false, hops: 0,
                   destinationHash: resLinkID, transportId: nil,
                   payload: Link.encrypt(s.advertisement!.pack(), sessionKey: resKey))
    return try! p.packed()
}

private func partPacket(_ chunk: Data) -> Data {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .resource, contextFlag: false, hops: 0,
                   destinationHash: resLinkID, transportId: nil, payload: chunk)
    return try! p.packed()
}

@Test @MainActor func inboundAdvertisementSpawnsReceiverAndRequests() async {
    let clock = TestClock<Duration>()
    let store = activeLinkStore(clock)
    let sender = senderFor(Data(repeating: 0x33, count: 100))
    await store.send(.received(advPacket(sender)))
    #expect(store.state.transfers.count == 1)
    #expect(store.state.transfers[0].resourceHash == sender.resourceHash)   // set at spawn
    await store.receive { if case .transfer(.element(_, .accept)) = $0 { return true }; return false }
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action, Packet(raw: raw)?.context == .resourceRequest { return true }
        return false
    }
    // Cleanup: cancel the spawned transfer (cancels its watchdog).
    let tid = store.state.transfers[0].id
    await store.send(.transfer(.element(id: tid, action: .cancel)))
}

@Test @MainActor func duplicateAdvertisementDoesNotSpawnSecondTransfer() async {
    let clock = TestClock<Duration>()
    let store = activeLinkStore(clock)
    let sender = senderFor(Data(repeating: 0x33, count: 100))
    await store.send(.received(advPacket(sender)))
    #expect(store.state.transfers.count == 1)
    await store.send(.received(advPacket(sender)))       // sender re-advertise
    #expect(store.state.transfers.count == 1)            // NOT 2
    let tid = store.state.transfers[0].id
    await store.send(.transfer(.element(id: tid, action: .cancel)))
}

@Test @MainActor func inboundPartRoutesToReceiverAndSurfacesResourceReceived() async {
    let clock = TestClock<Duration>()
    let store = activeLinkStore(clock)
    let data = Data("link routes each resource part to the hosted receiver transfer".utf8)
    let sender = senderFor(data)
    await store.send(.received(advPacket(sender)))
    _ = await store.receive { if case .transfer(.element(_, .accept)) = $0 { return true }; return false }
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action, Packet(raw: raw)?.context == .resourceRequest { return true }
        return false
    }
    let got = LockIsolated<Data?>(nil)
    for chunk in sender.parts {
        await store.send(.received(partPacket(chunk)))
    }
    // Once all parts arrive, the receiver assembles and the link surfaces resourceReceived.
    await store.receive { action in
        if case let .delegate(.resourceReceived(d)) = action { got.setValue(d); return true }
        return false
    }
    #expect(got.value == data)
    #expect(store.state.transfers.filter { $0.role == .receiver }.isEmpty)  // receiver GC'd on .received
}

@Test @MainActor func sendResourceSpawnsSenderAndEmitsEncryptedAdvertisement() async {
    let clock = TestClock<Duration>()
    let store = activeLinkStore(clock)
    let data = Data("a resource sent out over the link".utf8)
    await store.send(.sendResource(data))
    #expect(store.state.transfers.count == 1)
    #expect(store.state.transfers[0].role == .sender)
    await store.receive { if case .transfer(.element(_, .advertise)) = $0 { return true }; return false }
    let advOut = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action, Packet(raw: raw)?.context == .resourceAdvertisement {
            advOut.setValue(raw); return true
        }
        return false
    }
    // The advertisement is encrypted with the link key and unpacks to the sender's advertisement.
    let packet = Packet(raw: advOut.value!)!
    let plain = Link.decrypt(packet.payload, sessionKey: resKey)!
    let adv = ResourceAdvertisement.unpack(plain)!
    #expect(adv.hash == store.state.transfers[0].resourceHash)
    // Cleanup: cancel the sender transfer (cancels its advertise watchdog).
    let tid = store.state.transfers[0].id
    await store.send(.transfer(.element(id: tid, action: .cancel)))
}

// MARK: - GC: terminal transfer removal

/// Returns (store, transferID, resourceHash) for a link store pre-loaded with one plain (non-request,
/// non-response) sender transfer. The transfer is injected directly into initial state — no effects are
/// running for it — so firing .delegate(.concluded/.failed) on the parent LinkSession is clean.
@MainActor
private func activeLinkHostingPlainTransfer()
    -> (TestStore<LinkSession.State, LinkSession.Action>, UUID, Data)
{
    let clock = TestClock<Duration>()
    let t = senderFor(Data("plain resource payload".utf8))   // no requestID → plain advertisement
    var s = LinkSession.State(responderFor: Identity(),
                              destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"))
    s.status = .active
    s.sessionKey = resKey
    s.linkID = resLinkID
    s.rtt = 1.0
    s.transfers.append(t)
    let store = TestStore(initialState: s) { LinkSession() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = clock
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return (store, t.id, t.resourceHash)
}

@Test @MainActor func concludedTransferIsRemovedFromState() async {
    let (store, tid, hash) = activeLinkHostingPlainTransfer()
    await store.send(.transfer(.element(id: tid, action: .delegate(.concluded))))
    await store.receive { if case .delegate(.resourceConcluded(hash)) = $0 { return true }; return false }
    #expect(store.state.transfers[id: tid] == nil)              // removed
}

@Test @MainActor func failedTransferIsRemovedFromState() async {
    let (store, tid, hash) = activeLinkHostingPlainTransfer()
    await store.send(.transfer(.element(id: tid, action: .delegate(.failed))))
    await store.receive { if case .delegate(.resourceFailed(hash)) = $0 { return true }; return false }
    #expect(store.state.transfers[id: tid] == nil)              // removed
}

@Test @MainActor func sendResourceOnInactiveLinkDoesNothing() async {
    let clock = TestClock<Duration>()
    var s = LinkSession.State(responderFor: Identity(),
                              destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"))
    s.status = .pending                                     // not active
    let store = TestStore(initialState: s) { LinkSession() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0)); $0.continuousClock = clock; $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.sendResource(Data("nope".utf8)))
    #expect(store.state.transfers.isEmpty)
}

// MARK: - Multi-segment (oversize) send

/// SHA256-derived incompressible bytes: bzip2 cannot shrink them, ensuring the payload
/// stays above the split threshold under all compression paths.
private func incompressibleData(count: Int, seed: UInt8 = 0) -> Data {
    var result = Data()
    var i = 0
    while result.count < count {
        let chunk = Crypto.fullHash(Data([seed, UInt8(i & 0xff), UInt8((i >> 8) & 0xff), UInt8((i >> 16) & 0xff)]))
        result.append(contentsOf: chunk.prefix(min(chunk.count, count - result.count)))
        i += 1
    }
    return result
}

@Test @MainActor func sendResourceSplitsOversizeIntoSequentialSegments() async {
    let clock = TestClock<Duration>()
    let store = activeLinkStore(clock)               // existing active-link store helper
    store.exhaustivity = .off
    // 2 segments: maxEfficientSize + 100. Use incompressible so it doesn't shrink under threshold.
    let whole = incompressibleData(count: LinkSession.maxEfficientSize + 100)
    await store.send(.sendResource(whole))
    // Segment 1 is advertised now: i=1, l=2, isSplit, d=whole.
    let t0 = store.state.transfers[0]
    #expect(t0.advertisement!.segmentIndex == 1)
    #expect(t0.advertisement!.totalSegments == 2)
    #expect(t0.advertisement!.isSplit == true)
    #expect(t0.advertisement!.dataSize == UInt64(whole.count))
    #expect(store.state.segmentedSend != nil)
    let oh = store.state.segmentedSend!.originalHash
    // Segment 1 concludes → segment 2 is advertised (i=2, same originalHash), no resourceConcluded yet.
    await store.send(.transfer(.element(id: t0.id, action: .delegate(.concluded))))
    let t1 = store.state.transfers.first { $0.advertisement?.segmentIndex == 2 }
    #expect(t1 != nil)
    #expect(t1!.advertisement!.originalHash == oh)
    #expect(t1!.advertisement!.totalSegments == 2)
    // Segment 2 concludes → resourceConcluded(originalHash) once, segmentedSend cleared.
    await store.send(.transfer(.element(id: t1!.id, action: .delegate(.concluded))))
    await store.receive { if case let .delegate(.resourceConcluded(h)) = $0 { return h == oh }; return false }
    #expect(store.state.segmentedSend == nil)
    // Quiesce any spawned sender watchdogs.
    await clock.advance(by: .seconds(300))
}

// MARK: - Multi-segment receive accumulator

/// Builds an active-link store pre-loaded with `total` receiver ResourceTransfer.State objects,
/// each carrying a split advertisement (isSplit=true, segmentIndex=1..total, totalSegments=total,
/// originalHash=oh). No effects are running for these transfers — they are injected directly into
/// initial state — so firing .delegate(.received/.failed) on the parent LinkSession is clean.
@MainActor
private func resourceStoreHostingSplitReceivers(
    oh: Data,
    total: Int,
    _ clock: TestClock<Duration>
) -> TestStore<LinkSession.State, LinkSession.Action> {
    var s = LinkSession.State(responderFor: Identity(),
                              destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"))
    s.status = .active
    s.sessionKey = resKey
    s.linkID = resLinkID
    s.rtt = 1.0

    for i in 1...total {
        // Each segment has its own distinct hash (segment's own data hash).
        let segHash = Data(repeating: UInt8(0x20 + i), count: 32)
        let adv = ResourceAdvertisement(
            transferSize: 100,
            dataSize: UInt64(total) * 100,
            numberOfParts: 1,
            hash: segHash,
            randomHash: Data(repeating: UInt8(0x30 + i), count: 4),
            originalHash: oh,
            segmentIndex: UInt64(i),
            totalSegments: UInt64(total),
            requestID: nil,
            flags: 0x01 | 0x04,   // encrypted | isSplit
            hashmap: Data()
        )
        var t = ResourceTransfer.State(receivingOn: resLinkID, sessionKey: resKey,
                                       interfaceID: InterfaceID("i"), rtt: .seconds(1),
                                       id: UUID())
        t.advertisement = adv
        t.resourceHash = segHash
        s.transfers.append(t)
    }

    let store = TestStore(initialState: s) { LinkSession() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = clock
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

@Test @MainActor func receivedSplitSegmentsReassembleAndSurfaceOnce() async {
    let clock = TestClock<Duration>()
    let oh = Data(repeating: 0x11, count: 32)
    let seg1 = Data("hello ".utf8), seg2 = Data("world".utf8)
    // Host two receiver transfers with split advertisements (i=1 and i=2, l=2, shared o=oh).
    let store = resourceStoreHostingSplitReceivers(oh: oh, total: 2, clock)   // helper: see note
    let (id1, id2) = (store.state.transfers[0].id, store.state.transfers[1].id)
    store.exhaustivity = .off
    // Segment 1 received → buffered, nothing surfaced yet.
    await store.send(.transfer(.element(id: id1, action: .delegate(.received(seg1)))))
    #expect(store.state.incomingSegments[oh]?.parts.count == 1)
    // Segment 2 received → whole surfaced once = seg1 ‖ seg2.
    await store.send(.transfer(.element(id: id2, action: .delegate(.received(seg2)))))
    await store.receive { if case let .delegate(.resourceReceived(d)) = $0 { return d == seg1 + seg2 }; return false }
    #expect(store.state.incomingSegments[oh] == nil)
}

@Test @MainActor func splitSegmentFailureFailsTheWhole() async {
    let clock = TestClock<Duration>()
    let oh = Data(repeating: 0x11, count: 32)
    let store = resourceStoreHostingSplitReceivers(oh: oh, total: 2, clock)
    let id1 = store.state.transfers[0].id
    store.exhaustivity = .off
    await store.send(.transfer(.element(id: id1, action: .delegate(.failed))))
    await store.receive { if case let .delegate(.resourceFailed(h)) = $0 { return h == oh }; return false }
}

// MARK: - GC: completed receiver transfer removal on .received

/// Builds an active-link store pre-loaded with ONE plain (non-request, non-response, non-split)
/// receiver `ResourceTransfer.State` whose `advertisement` has flags `0x01` (encrypted only).
/// No effects are running for the transfer — injected directly into state — so firing
/// `.delegate(.received(_))` on the parent `LinkSession` is clean.
/// Returns `(store, transferID)`.
@MainActor
private func activeLinkHostingPlainReceiver(
    _ clock: TestClock<Duration>
) -> (TestStore<LinkSession.State, LinkSession.Action>, UUID) {
    let resHash = Data(repeating: 0xAA, count: 32)
    let adv = ResourceAdvertisement(
        transferSize: 50,
        dataSize: 50,
        numberOfParts: 1,
        hash: resHash,
        randomHash: Data(repeating: 0xBB, count: 4),
        originalHash: resHash,
        segmentIndex: 0,
        totalSegments: 0,
        requestID: nil,
        flags: 0x01,   // encrypted only — plain resource (not request, not response, not split)
        hashmap: Data()
    )
    var t = ResourceTransfer.State(receivingOn: resLinkID, sessionKey: resKey,
                                   interfaceID: InterfaceID("i"), rtt: .seconds(1),
                                   id: UUID())
    t.advertisement = adv
    t.resourceHash = resHash

    var s = LinkSession.State(responderFor: Identity(),
                              destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"))
    s.status = .active
    s.sessionKey = resKey
    s.linkID = resLinkID
    s.rtt = 1.0
    s.transfers.append(t)

    let store = TestStore(initialState: s) { LinkSession() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = clock
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return (store, t.id)
}

@Test @MainActor func completedPlainReceiverIsRemovedFromTransfers() async {
    let clock = TestClock<Duration>()
    let (store, tid) = activeLinkHostingPlainReceiver(clock)
    store.exhaustivity = .off
    await store.send(.transfer(.element(id: tid, action: .delegate(.received(Data("payload".utf8))))))
    await store.receive { if case .delegate(.resourceReceived(Data("payload".utf8))) = $0 { return true }; return false }
    #expect(store.state.transfers[id: tid] == nil)             // GC'd
}

// MARK: - Proof routing

/// F15: two concurrent SENDER transfers on one link. A proof must reach ONLY the transfer whose
/// `resourceHash` it names. Before this fix the proof was fanned out to every transfer and each
/// one failed itself on a mismatch, so two of our OWN transfers destroyed each other with no
/// attacker present.
///
/// The proof is deliberately addressed to the SECOND sender (B), not the first. That choice is
/// what makes the ownership check observable: a predicate that drops `resourceHash == owner` and
/// keeps only `role == .sender` selects `first(where:)` — i.e. A — so routing-to-B versus
/// routing-to-first-sender give DIFFERENT answers. Addressing the proof to A would make the two
/// indistinguishable and the hash check unpinned.
///
/// This asserts ROUTING, not just outcome: the `.on` window makes a delivery to A an unexpected
/// action. An outcome-only assertion would stop discriminating once a mis-delivered proof became
/// harmless.
///
/// SEEDED STATE, deliberately. The property under test is WHICH TRANSFER RECEIVES the routed
/// action — not whether transfers can be created, and not any part of the send pipeline. Driving
/// this through `.sendResource` would spawn live `ResourceTransfer` effects (advertise, transmit
/// delegate, advertise-retry watchdog) whose actions accumulate in `receivedActions` and cannot
/// be synchronised with the `.on` window that carries the whole assertion; the routing signal
/// would be buried under setup traffic it has nothing to do with. Seeding the two senders
/// directly (as `activeLinkHostingPlainTransfer` and `resourceStoreHostingSplitReceivers` in this
/// same file already do) gives a clean queue and leaves the reachability question to the tests
/// that own it. The two seeded senders ARE the non-adversarial scenario this fix exists for:
/// two of our own concurrent outbound transfers on one link, no attacker involved.
@Test @MainActor func aResourceProofReachesOnlyTheTransferThatOwnsIt() async {
    let clock = TestClock<Duration>()
    let tA = senderFor(Data(repeating: 0x01, count: 64))
    let tB = senderFor(Data(repeating: 0x02, count: 64))
    #expect(tA.resourceHash != tB.resourceHash)

    var s = LinkSession.State(responderFor: Identity(),
                              destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"))
    s.status = .active
    s.sessionKey = resKey
    s.linkID = resLinkID
    s.rtt = 1.0
    s.lastInbound = 0.0     // pre-seeded so the `.on`-window sends produce no nil→0 change
    s.transfers.append(tA)
    s.transfers.append(tB)
    #expect(s.transfers.first?.id == tA.id)   // A really is first — the (c) mutation's target

    let store = TestStore(initialState: s) { LinkSession() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = clock
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    // Proof for B's resource, naming B's hash in its leading 32 bytes.
    let proof = Resource.proofData(data: Data(repeating: 0x02, count: 64), hash: tB.resourceHash)
    #expect(Data(proof.prefix(32)) == tB.resourceHash)
    let packet = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                        destinationType: .link, context: .resourceProof, contextFlag: false,
                        hops: 0, destinationHash: resLinkID, transportId: nil,
                        payload: proof)

    store.exhaustivity = .on
    // The routing effect (.send(.transfer(tB.id, .received(data)))) is async — B's status
    // change happens when ResourceTransfer processes the child action, not during this send.
    await store.send(.received(try! packet.packed()))
    await store.receive { action in
        if case let .transfer(.element(id, .received)) = action { return id == tB.id }
        return false
    } assert: { state in
        // B's ResourceTransfer validates the proof → status .complete. A is untouched.
        state.transfers[id: tB.id]?.status = .complete
    }
    // B's ResourceTransfer validates the proof → .complete → emits .delegate(.concluded).
    // The parent then handles .concluded → removes B and emits .delegate(.resourceConcluded).
    // Drain these cascading actions before the inert send; they are B's own expected effects
    // and are not evidence of a stray A-delivery.
    await store.receive { action in
        if case let .transfer(.element(id, .delegate(.concluded))) = action { return id == tB.id }
        return false
    } assert: { state in
        state.transfers.remove(id: tB.id)
    }
    await store.receive { action in
        if case .delegate(.resourceConcluded) = action { return true }
        return false
    }
    // FLIP-THEN-SEND, and it is load-bearing. `send`'s "must handle N received actions" check
    // fires on actions queued by a PREVIOUS send, so a stray delivery to A is only observable
    // on the NEXT send while still `.on`. Asserting here and flipping to `.off` would let A's
    // action be silently discarded — and flipping back before teardown also disables the
    // teardown check. This second send is what makes the routing claim real.
    let inert = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                       destinationType: .link, context: .none, contextFlag: false, hops: 0,
                       destinationHash: resLinkID, transportId: nil,
                       payload: Data(repeating: 0x00, count: 8))
    await store.send(.received(try! inert.packed()))

    store.exhaustivity = .off
    // A never saw the proof, so it is neither failed nor concluded — it is still sitting there
    // untouched. Under the pre-fix fan-out A would have failed itself on the hash mismatch.
    #expect(store.state.transfers[id: tA.id]?.status != .failed)
    #expect(store.state.transfers[id: tA.id] != nil)
    await store.send(.close)
}

/// Reference scopes proof routing to `outgoing_resources` — sender-role only. A RECEIVER-role
/// transfer must not consume a proof even when its resourceHash matches.
///
/// This test uses the existing `activeLinkHostingPlainReceiver` helper in this file, which
/// stands up a link whose only transfer is receiver-role. Read that helper for its exact
/// signature and for the receiver's `resourceHash`; the assertions below are the point.
@Test @MainActor func aResourceProofIsNotDeliveredToAReceiverRoleTransfer() async {
    let clock = TestClock<Duration>()
    // activeLinkHostingPlainReceiver returns (store, transferID: UUID), not (store, hash).
    // Take the resourceHash directly from state; the helper sets it to Data(repeating: 0xAA, count: 32).
    let (store, _) = activeLinkHostingPlainReceiver(clock)
    let receiverHash = store.state.transfers.first!.resourceHash

    // Warm up lastInbound to 0.0 while still `.off` so the `.on`-window sends don't see nil→0.
    // An unencrypted .none packet fails authDecrypt → dispatch returns .none; no queued actions.
    let warmupPacket = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                              destinationType: .link, context: .none, contextFlag: false, hops: 0,
                              destinationHash: store.state.linkID, transportId: nil,
                              payload: Data(repeating: 0x00, count: 8))
    await store.send(.received(try! warmupPacket.packed()))

    // A proof addressed to the receiver's own resource hash. Sender-role scoping means it must
    // not be delivered at all — under `.on`, any `.transfer(.element(...))` is unhandled.
    let proof = Resource.proofData(data: Data(repeating: 0x04, count: 64), hash: receiverHash)
    let packet = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                        destinationType: .link, context: .resourceProof, contextFlag: false,
                        hops: 0, destinationHash: store.state.linkID, transportId: nil,
                        payload: proof)

    store.exhaustivity = .on
    await store.send(.received(try! packet.packed()))
    // FLIP-THEN-SEND — see the note in the previous test. Without this second `.on` send, a
    // delivery to the receiver-role transfer is queued, never inspected, and then discarded when
    // exhaustivity drops. The test would assert nothing at all.
    let inert = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                       destinationType: .link, context: .none, contextFlag: false, hops: 0,
                       destinationHash: store.state.linkID, transportId: nil,
                       payload: Data(repeating: 0x00, count: 8))
    await store.send(.received(try! inert.packed()))

    store.exhaustivity = .off
    #expect(store.state.transfers.first?.status != .failed)
    await store.send(.close)
}

/// A proof payload SHORTER than the 32-byte resource hash it is supposed to lead with. The
/// routing code slices `payload.prefix(32)` to recover the owner hash, so a truncated payload
/// must neither trap nor be delivered to anything.
///
/// Same seeding rationale as `aResourceProofReachesOnlyTheTransferThatOwnsIt` above: the
/// property is what the ROUTER does with a malformed payload, so the transfers are seeded.
@Test @MainActor func aShortResourceProofPayloadIsDroppedWithoutDelivery() async {
    let clock = TestClock<Duration>()
    let tA = senderFor(Data(repeating: 0x01, count: 64))
    let tB = senderFor(Data(repeating: 0x02, count: 64))

    var s = LinkSession.State(responderFor: Identity(),
                              destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"))
    s.status = .active
    s.sessionKey = resKey
    s.linkID = resLinkID
    s.rtt = 1.0
    s.lastInbound = 0.0
    s.transfers.append(tA)
    s.transfers.append(tB)

    let store = TestStore(initialState: s) { LinkSession() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = clock
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    // 8 bytes — a quarter of a resource hash. Deliberately a PREFIX of B's real hash, so a
    // router that compared only the bytes it received (rather than requiring a full hash) would
    // still be tempted to match it.
    let shortPayload = Data(tB.resourceHash.prefix(8))
    #expect(shortPayload.count == 8)
    let packet = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                        destinationType: .link, context: .resourceProof, contextFlag: false,
                        hops: 0, destinationHash: resLinkID, transportId: nil,
                        payload: shortPayload)

    store.exhaustivity = .on
    // No crash, and under `.on` any `.transfer(.element(...))` queued here is an unhandled
    // action that the inert send below reports.
    await store.send(.received(try! packet.packed()))
    // FLIP-THEN-SEND — see the note in the first proof-routing test. This is what observes a
    // delivery that would otherwise be queued, never inspected, then silently discarded.
    let inert = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                       destinationType: .link, context: .none, contextFlag: false, hops: 0,
                       destinationHash: resLinkID, transportId: nil,
                       payload: Data(repeating: 0x00, count: 8))
    await store.send(.received(try! inert.packed()))

    store.exhaustivity = .off
    // Both transfers untouched: no delivery means no status transition either way.
    #expect(store.state.transfers[id: tA.id]?.status == tA.status)
    #expect(store.state.transfers[id: tB.id]?.status == tB.status)
    await store.send(.close)
}

/// Pins the `payload.count >= 32` length guard specifically.
///
/// READ THIS BEFORE JUDGING THE SEEDING: this test seeds a SENDER whose `resourceHash` is
/// shorter than 32 bytes, which production cannot currently produce. A sender's `resourceHash`
/// has exactly one write site — `ResourceTransfer.State.init(sending:...)`, which assigns
/// `Resource.resourceHash(...)` = `Crypto.fullHash` = a 32-byte SHA-256 — so every real sender
/// carries a full-length hash. The seeding is therefore NOT a reachability claim, and this test
/// must not be read as one. It pins the guard's CONTRACT: a truncated payload must not be
/// matched against anything, independent of who the candidates happen to be.
///
/// Why the guard is nonetheless worth pinning rather than deleting as dead code. The
/// discriminator `Data(payload.prefix(32))` silently yields a SHORT `Data` for a short payload
/// instead of trapping, so the length check is the only thing standing between a truncated
/// packet and a prefix comparison. Today the `role == .sender` gate independently saves us,
/// because sender hashes are always 32 bytes and a short `owner` can never equal one. But a
/// RECEIVER's `resourceHash` is wire-controlled — `ResourceAdvertisement.unpack` reads `h` as
/// an unvalidated `.bin` and does not check its length — so a peer can advertise an EMPTY hash,
/// and an empty proof payload yields an empty `owner` that compares EQUAL to it (verified by
/// probe). That combination is live the moment the role gate is weakened. This guard is the
/// second lock on that door; it is defence-in-depth, not redundancy.
@Test @MainActor func aTruncatedProofIsRejectedBeforeThePrefixComparison() async {
    let clock = TestClock<Duration>()
    var tShort = senderFor(Data(repeating: 0x01, count: 64))
    tShort.resourceHash = Data(repeating: 0x07, count: 8)   // SEEDED: see note above
    #expect(tShort.role == .sender)
    #expect(tShort.resourceHash.count == 8)

    var s = LinkSession.State(responderFor: Identity(),
                              destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"))
    s.status = .active
    s.sessionKey = resKey
    s.linkID = resLinkID
    s.rtt = 1.0
    s.lastInbound = 0.0
    s.transfers.append(tShort)

    let store = TestStore(initialState: s) { LinkSession() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = clock
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    // A payload that is EXACTLY the seeded short hash. Without the length guard,
    // `Data(payload.prefix(32))` is those same 8 bytes and compares EQUAL to `resourceHash`,
    // so the proof routes. With the guard, it is rejected before the comparison happens.
    let packet = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                        destinationType: .link, context: .resourceProof, contextFlag: false,
                        hops: 0, destinationHash: resLinkID, transportId: nil,
                        payload: tShort.resourceHash)

    store.exhaustivity = .on
    await store.send(.received(try! packet.packed()))
    // FLIP-THEN-SEND — see the note in the first proof-routing test.
    let inert = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                       destinationType: .link, context: .none, contextFlag: false, hops: 0,
                       destinationHash: resLinkID, transportId: nil,
                       payload: Data(repeating: 0x00, count: 8))
    await store.send(.received(try! inert.packed()))

    store.exhaustivity = .off
    #expect(store.state.transfers[id: tShort.id]?.status == tShort.status)   // never delivered
    await store.send(.close)
}

@Test @MainActor func completedSplitSegmentReceiversAreRemovedAsTheyArrive() async {
    let clock = TestClock<Duration>()
    let oh = Data(repeating: 0x11, count: 32)
    let seg1 = Data("hello ".utf8), seg2 = Data("world".utf8)
    let store = resourceStoreHostingSplitReceivers(oh: oh, total: 2, clock)   // existing helper (multi-seg slice)
    let (id1, id2) = (store.state.transfers[0].id, store.state.transfers[1].id)
    store.exhaustivity = .off
    await store.send(.transfer(.element(id: id1, action: .delegate(.received(seg1)))))
    #expect(store.state.transfers[id: id1] == nil)             // segment 1 receiver GC'd (payload buffered)
    #expect(store.state.incomingSegments[oh]?.parts.count == 1)
    await store.send(.transfer(.element(id: id2, action: .delegate(.received(seg2)))))
    await store.receive { if case let .delegate(.resourceReceived(d)) = $0 { return d == seg1 + seg2 }; return false }
    #expect(store.state.transfers[id: id2] == nil)             // segment 2 receiver GC'd
    #expect(store.state.transfers.isEmpty)                     // no inert receivers left
}
