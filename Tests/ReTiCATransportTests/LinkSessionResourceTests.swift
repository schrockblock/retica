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
