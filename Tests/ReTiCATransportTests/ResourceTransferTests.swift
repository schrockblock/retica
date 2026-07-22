import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

private let key = Data(repeating: 0x01, count: 64)
private let linkID = Data(repeating: 0xAB, count: 16)
private let prefix = Data([0x0A, 0x0B, 0x0C, 0x0D])
private let r = Data([0x01, 0x02, 0x03, 0x04])

private func senderState(_ data: Data, sdu: Int = 24) -> ResourceTransfer.State {
    ResourceTransfer.State(sending: data, linkID: linkID, sessionKey: key, interfaceID: InterfaceID("s"),
                           prefix: prefix, randomHash: r, sdu: sdu)
}

@MainActor
private func captureTransmits(_ store: TestStore<ResourceTransfer.State, ResourceTransfer.Action>,
                              count: Int) async -> [Data] {
    // The predicate must be pure (no side effects): TCA's TestStore calls it multiple times per
    // matched action (for async polling, contains-check, while-loop guard, and final guard).
    // Capture using a separate LockIsolated per iteration so each iteration appends exactly once.
    var captured: [Data] = []
    for _ in 0..<count {
        let slot = LockIsolated<Data?>(nil)
        await store.receive { action in
            if case let .delegate(.transmit(_, raw)) = action {
                slot.withValue { if $0 == nil { $0 = raw } }  // set once; idempotent on re-calls
                return true
            }
            return false
        }
        if let raw = slot.value { captured.append(raw) }
    }
    return captured
}

// Build a RESOURCE_REQ packet asking for all parts of `s`.
private func resourceRequestPacket(_ s: ResourceTransfer.State) -> Data {
    let req = Data([0x00]) + s.resourceHash + s.advertisement!.hashmap
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .resourceRequest, contextFlag: false, hops: 0,
                   destinationHash: linkID, transportId: nil, payload: Link.encrypt(req, sessionKey: key))
    return try! p.packed()
}

@MainActor
private func senderStore(_ data: Data, _ clock: TestClock<Duration>) -> TestStore<ResourceTransfer.State, ResourceTransfer.Action> {
    let store = TestStore(initialState: senderState(data)) { ResourceTransfer() }
        withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

@Test @MainActor func senderAdvertiseEmitsResourceAdvertisement() async {
    let data = Data("a small resource to send".utf8)
    let clock = TestClock<Duration>()
    let store = senderStore(data, clock)
    await store.send(.advertise) { $0.status = .advertised }
    let raw = (await captureTransmits(store, count: 1))[0]
    let packet = Packet(raw: raw)!
    #expect(packet.context == .resourceAdvertisement)
    let adv = ResourceAdvertisement.unpack(Link.decrypt(packet.payload, sessionKey: key)!)!
    #expect(adv.hash == store.state.resourceHash)
    // Cleanup: exhaust adv retries to fail (cancels the watchdog).
    for _ in 0...ResourceTransfer.Const.maxAdvRetries { await store.send(.senderDeadline) }
    #expect(store.state.status == .failed)
}

@Test @MainActor func senderReAdvertisesThenFailsAndCancels() async {
    let data = Data("re-advertise then give up".utf8)
    let clock = TestClock<Duration>()
    let store = senderStore(data, clock)
    await store.send(.advertise)
    _ = await captureTransmits(store, count: 1)                       // initial ADV
    // Each deadline while ADVERTISED re-advertises, up to maxAdvRetries times.
    for _ in 0..<ResourceTransfer.Const.maxAdvRetries {
        await store.send(.senderDeadline)
        _ = await captureTransmits(store, count: 1)                  // re-ADV
    }
    #expect(store.state.advRetriesLeft == 0)
    await store.send(.senderDeadline)                                // no retries left -> fail + ICL
    #expect(store.state.status == .failed)
    let icl = (await captureTransmits(store, count: 1))[0]
    let p = Packet(raw: icl)!
    #expect(p.context == .resourceInitiatorCancel)
    #expect(Link.decrypt(p.payload, sessionKey: key) == store.state.resourceHash)
}

@Test @MainActor func senderServesAllPartsThenAwaitsProofAndConcludes() async {
    let data = Data("sender serves parts, then awaits and validates the proof".utf8)
    let clock = TestClock<Duration>()
    let store = senderStore(data, clock)
    await store.send(.advertise)
    _ = await captureTransmits(store, count: 1)
    let s = store.state
    await store.send(.received(resourceRequestPacket(s)))            // requests all parts
    _ = await captureTransmits(store, count: s.parts.count)
    #expect(store.state.status == .awaitingProof)

    // Valid proof concludes.
    let proof = Resource.proofData(data: data, hash: s.resourceHash)
    let pkt = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                     destinationType: .link, context: .resourceProof, contextFlag: false, hops: 0,
                     destinationHash: linkID, transportId: nil, payload: proof)
    await store.send(.received(try! pkt.packed()))
    await store.receive(.delegate(.concluded))
    #expect(store.state.status == .complete)
}

@Test @MainActor func senderAwaitingProofTimesOutThenFails() async {
    let data = Data("sender never receives a proof".utf8)
    let clock = TestClock<Duration>()
    let store = senderStore(data, clock)
    await store.send(.advertise)
    _ = await captureTransmits(store, count: 1)
    await store.send(.received(resourceRequestPacket(store.state)))
    _ = await captureTransmits(store, count: store.state.parts.count)
    #expect(store.state.status == .awaitingProof)
    // Exhaust proof retries.
    for _ in 0...ResourceTransfer.Const.proofRetries { await store.send(.senderDeadline) }
    #expect(store.state.status == .failed)
    let icl = (await captureTransmits(store, count: 1))[0]
    #expect(Packet(raw: icl)!.context == .resourceInitiatorCancel)
}

@Test @MainActor func senderRejectsInvalidProof() async {
    let data = Data("bad proof path".utf8)
    let clock = TestClock<Duration>()
    let store = senderStore(data, clock)
    await store.send(.advertise)
    _ = await captureTransmits(store, count: 1)
    await store.send(.received(resourceRequestPacket(store.state)))
    _ = await captureTransmits(store, count: store.state.parts.count)
    let bad = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                     destinationType: .link, context: .resourceProof, contextFlag: false, hops: 0,
                     destinationHash: linkID, transportId: nil, payload: Data(repeating: 0x00, count: 64))
    await store.send(.received(try! bad.packed()))
    await store.receive(.delegate(.failed))
    #expect(store.state.status == .failed)
}

private func receiverState() -> ResourceTransfer.State {
    ResourceTransfer.State(receivingOn: linkID, sessionKey: key, interfaceID: InterfaceID("r"))
}
private func advertisementPacket(_ s: ResourceTransfer.State) -> Data {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .resourceAdvertisement, contextFlag: false, hops: 0,
                   destinationHash: linkID, transportId: nil,
                   payload: Link.encrypt(s.advertisement!.pack(), sessionKey: key))
    return try! p.packed()
}
private func partPacket(_ chunk: Data) -> Data {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .resource, contextFlag: false, hops: 0,
                   destinationHash: linkID, transportId: nil, payload: chunk)
    return try! p.packed()
}

@MainActor
private func receiverStore(_ clock: TestClock<Duration>) -> TestStore<ResourceTransfer.State, ResourceTransfer.Action> {
    let store = TestStore(initialState: receiverState()) { ResourceTransfer() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

@Test @MainActor func receiverAcceptRequestsFirstWindowOnly() async {
    let data = Data(repeating: 0x33, count: 160)          // 160+4 prefix -> stream > 6 parts at sdu 24
    let sender = senderState(data)
    let clock = TestClock<Duration>()
    let store = receiverStore(clock)
    await store.send(.accept(advertisementPacket(sender)))
    let raw = (await captureTransmits(store, count: 1))[0]
    let packet = Packet(raw: raw)!
    #expect(packet.context == .resourceRequest)
    let plain = Link.decrypt(packet.payload, sessionKey: key)!
    let body = Data(plain)
    // 1 flag + 32 hash + 4*window map-hashes; window == 4
    let expectedBodyCount = 1 + 32 + 4 * 4
    #expect(body.count == expectedBodyCount)
    #expect(store.state.outstanding == [0, 1, 2, 3])
    // Drive to failure to cancel the armed watchdog (17 timeouts: 16 retries + 1 final fail).
    for _ in 0..<(ResourceTransfer.Const.maxRetries + 1) { await store.send(.receiverDeadline) }
    #expect(store.state.status == .failed)
}

@Test @MainActor func receiverWindowsThroughAllPartsAndProves() async {
    let data = Data("windowed receiver reconstructs this exact payload across multiple request rounds ok".utf8)
    let sender = senderState(data)
    let clock = TestClock<Duration>()
    let store = receiverStore(clock)
    await store.send(.accept(advertisementPacket(sender)))
    _ = await captureTransmits(store, count: 1)           // first-window request

    let got = LockIsolated<Data?>(nil)
    let total = sender.parts.count
    // Feed every part in order; each completed window triggers the next request; last completes.
    for (n, chunk) in sender.parts.enumerated() {
        await store.send(.received(partPacket(chunk)))
        if n == total - 1 {
            // Drain any intermediate window-request transmits, then wait for the PRF (proof packet).
            await store.receive { action in
                if case let .delegate(.transmit(_, raw)) = action,
                   Packet(raw: raw)?.packetType == .proof { return true }
                return false
            }
            await store.receive { action in
                if case let .delegate(.received(d)) = action { got.setValue(d); return true }
                return false
            }
        }
    }
    #expect(got.value == data)
    #expect(store.state.status == .complete)
}

@Test @MainActor func receiverRetransmitsThenFailsAfterMaxRetries() async {
    let data = Data(repeating: 0x5A, count: 160)
    let sender = senderState(data)
    let clock = TestClock<Duration>()
    let store = receiverStore(clock)
    await store.send(.accept(advertisementPacket(sender)))
    _ = await captureTransmits(store, count: 1)

    // First timeout: window shrinks (4 -> 3), a retry is spent, a new request goes out.
    await store.send(.receiverDeadline)
    #expect(store.state.window.window == 3)
    #expect(store.state.retriesLeft == ResourceTransfer.Const.maxRetries - 1)
    _ = await captureTransmits(store, count: 1)           // re-request

    // Exhaust the remaining retries; the final timeout fails the transfer and emits an RCL.
    for _ in 0..<ResourceTransfer.Const.maxRetries { await store.send(.receiverDeadline) }
    #expect(store.state.status == .failed)
    // Skip any intermediate request transmits and find the RCL (non-exhaustive receive skips non-matching).
    let rclData = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action,
           Packet(raw: raw)?.context == .resourceReceiverCancel { rclData.setValue(raw); return true }
        return false
    }
    let rcl = rclData.value!
    let p = Packet(raw: rcl)!
    #expect(p.context == .resourceReceiverCancel)
    #expect(Link.decrypt(p.payload, sessionKey: key) == sender.resourceHash)
}

@Test @MainActor func endToEndWindowedTransferWithADroppedPart() async {
    // 142-byte payload → 9 parts at sdu=24 (stream = 208 bytes).
    // Window starts at 4, so the transfer spans at least 3 rounds (4 + 3 + 3 = 10 > 9 part slots),
    // and a dropped part forces a timeout+retransmit, proving all four required properties:
    //   1. receiver reconstructs EXACT original data; 2. both sides reach .complete;
    //   3. window advances across multiple rounds; 4. dropped part recovered via retransmission.
    let data = Data("End-to-end windowed resource transfer with retransmission of a dropped part, spanning multiple request rounds so the window actually advances.".utf8)
    let senderClock = TestClock<Duration>()
    let receiverClock = TestClock<Duration>()
    let sender = TestStore(initialState: senderState(data)) { ResourceTransfer() }
        withDependencies: { $0.continuousClock = senderClock }
    sender.exhaustivity = .off
    let receiver = TestStore(initialState: receiverState()) { ResourceTransfer() }
        withDependencies: { $0.continuousClock = receiverClock }
    receiver.exhaustivity = .off

    // --- Advertise → accept → first window request (parts 0..3, window=4) ---
    await sender.send(.advertise)
    let adv = (await captureTransmits(sender, count: 1))[0]
    await receiver.send(.accept(adv))
    // Capture the first window request from the receiver.
    let req1 = (await captureTransmits(receiver, count: 1))[0]

    // --- Round 1: sender serves parts 0,1,2,3; receiver gets 0,1,2 (part 3 dropped) ---
    await sender.send(.received(req1))
    let round1Parts = await captureTransmits(sender, count: 4)
    // Deliver parts 0, 1, 2 only — drop part 3 (index 3, last in this window).
    await receiver.send(.received(round1Parts[0]))
    await receiver.send(.received(round1Parts[1]))
    await receiver.send(.received(round1Parts[2]))
    // window=4 shrunk once after the deadline below → window=3 (proving window advanced)
    #expect(receiver.state.outstanding == [3])   // only dropped part remains

    // --- Simulate the receiver watchdog firing for the dropped part ---
    await receiver.send(.receiverDeadline)
    #expect(receiver.state.window.window == 3)    // window shrank: proves retransmit path
    // receiverDeadline calls requestNextWindow(height=2, window=3) → requests parts 3,4,5
    let req2 = (await captureTransmits(receiver, count: 1))[0]

    // --- Round 2: sender serves parts 3,4,5; all delivered ---
    await sender.send(.received(req2))
    let round2Parts = await captureTransmits(sender, count: 3)
    await receiver.send(.received(round2Parts[0]))
    await receiver.send(.received(round2Parts[1]))
    await receiver.send(.received(round2Parts[2]))
    // Round complete; window grown back (3→4). requestNextWindow(height=5, window=4) → parts 6,7,8.
    let req3 = (await captureTransmits(receiver, count: 1))[0]

    // --- Round 3: sender serves parts 6,7,8; receiver completes ---
    await sender.send(.received(req3))
    let round3Parts = await captureTransmits(sender, count: 3)
    await receiver.send(.received(round3Parts[0]))
    await receiver.send(.received(round3Parts[1]))
    await receiver.send(.received(round3Parts[2]))
    #expect(receiver.state.status == .complete)

    // The completing receive emits the proof + the reconstructed data.
    let got = LockIsolated<Data?>(nil)
    await receiver.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    await receiver.receive { action in
        if case let .delegate(.received(d)) = action { got.setValue(d); return true }
        return false
    }
    #expect(got.value == data)

    // Feed the proof back to the sender to conclude.
    let proof = Resource.proofData(data: data, hash: sender.state.resourceHash)
    let pkt = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                     destinationType: .link, context: .resourceProof, contextFlag: false, hops: 0,
                     destinationHash: linkID, transportId: nil, payload: proof)
    await sender.send(.received(try! pkt.packed()))
    await sender.receive(.delegate(.concluded))
    #expect(sender.state.status == .complete)
}

// Encrypted cancel packet carrying the resource hash.
private func cancelPacket(_ context: PacketContext, _ hash: Data) -> Data {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: context, contextFlag: false, hops: 0,
                   destinationHash: linkID, transportId: nil,
                   payload: Link.encrypt(hash, sessionKey: key))
    return try! p.packed()
}

@Test @MainActor func receiverFailsOnInboundInitiatorCancel() async {
    let data = Data(repeating: 0x22, count: 100)
    let sender = senderState(data)
    let clock = TestClock<Duration>()
    let store = receiverStore(clock)
    await store.send(.accept(advertisementPacket(sender)))
    _ = await captureTransmits(store, count: 1)
    await store.send(.received(cancelPacket(.resourceInitiatorCancel, sender.resourceHash)))
    await store.receive(.delegate(.failed))
    #expect(store.state.status == .failed)
}

@Test @MainActor func senderFailsOnInboundReceiverCancel() async {
    let data = Data("sender aborts when the receiver rejects".utf8)
    let clock = TestClock<Duration>()
    let store = senderStore(data, clock)
    await store.send(.advertise)
    _ = await captureTransmits(store, count: 1)
    await store.send(.received(cancelPacket(.resourceReceiverCancel, store.state.resourceHash)))
    await store.receive(.delegate(.failed))
    #expect(store.state.status == .failed)
}

@Test @MainActor func externalCancelEmitsReceiverCancelPacket() async {
    let data = Data(repeating: 0x77, count: 100)
    let sender = senderState(data)
    let clock = TestClock<Duration>()
    let store = receiverStore(clock)
    await store.send(.accept(advertisementPacket(sender)))
    _ = await captureTransmits(store, count: 1)
    await store.send(.cancel)
    let raw = (await captureTransmits(store, count: 1))[0]
    let p = Packet(raw: raw)!
    #expect(p.context == .resourceReceiverCancel)
    #expect(Link.decrypt(p.payload, sessionKey: key) == sender.resourceHash)
    #expect(store.state.status == .failed)
}

@Test @MainActor func inboundCancelWithWrongHashIsIgnored() async {
    let data = Data(repeating: 0x22, count: 100)
    let sender = senderState(data)
    let clock = TestClock<Duration>()
    let store = receiverStore(clock)
    await store.send(.accept(advertisementPacket(sender)))
    _ = await captureTransmits(store, count: 1)
    await store.send(.received(cancelPacket(.resourceInitiatorCancel, Data(repeating: 0xEE, count: 32))))
    #expect(store.state.status != .failed)
    // Cleanup: cancel to a terminal state.
    await store.send(.cancel); _ = await captureTransmits(store, count: 1)
}

// MARK: - Watchdog arming coverage (clock-advance tests)

/// Proves the receiver watchdog is truly ARMED inside requestNextWindow (called from .accept).
/// After .accept, advancing the TestClock past the timeout must cause .receiverDeadline to fire
/// automatically — no manual store.send(.receiverDeadline) — and the handler must run (window 4→3).
/// If the watchdog arm is removed from requestNextWindow, the clock advance produces nothing and
/// the test hangs/times-out waiting for the auto-fired action, causing a mutation failure.
@Test @MainActor func receiverWatchdogAutoFiresAfterWindowRequest() async {
    // 160 bytes → 7 parts at sdu 24 (stream includes 4-byte prefix = 164 bytes / 24 ≈ 7 parts).
    let data = Data(repeating: 0x33, count: 160)
    let sender = senderState(data)
    let clock = TestClock<Duration>()
    let store = receiverStore(clock)

    // .accept → calls requestNextWindow → arms receiver watchdog.
    await store.send(.accept(advertisementPacket(sender)))

    // Receiver watchdog timeout = rtt * partTimeoutFactor + retryGrace + perRetryDelay * (maxRetries - retriesLeft)
    // With defaults: 1s * 4 + 0.25s + 0.5s * 0 = 4.25s. Advance well past it.
    await clock.advance(by: .seconds(10))

    // The watchdog must fire on its own — this is NOT a manual send.
    // We drain both the transmit and the auto-fired deadline; order is transmit-first then deadline.
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    await store.receive { if case .receiverDeadline = $0 { return true }; return false }

    // Handler ran: window should have shrunk from 4 → 3.
    #expect(store.state.window.window == 3)

    // Drive to terminal state to cancel all watchdogs (avoids leaked effects).
    // retriesLeft is now maxRetries-1; the subsequent requestNextWindow re-arms the watchdog.
    // Exhaust remaining retries manually, draining each re-request transmit.
    for _ in 0..<ResourceTransfer.Const.maxRetries {
        await store.send(.receiverDeadline)
    }
    #expect(store.state.status == .failed)
}

/// Proves the sender watchdog is truly ARMED inside the .advertise handler.
/// After .advertise, advancing the TestClock past the advertised-state timeout must cause
/// .senderDeadline to fire automatically. The handler re-advertises (advRetriesLeft decrements).
/// If the watchdog arm is removed from .advertise, no deadline fires and the test hangs/times-out,
/// causing a mutation failure.
@Test @MainActor func senderWatchdogAutoFiresAfterAdvertise() async {
    let data = Data("sender watchdog auto-arming probe".utf8)
    let clock = TestClock<Duration>()
    let store = senderStore(data, clock)

    // .advertise → transitions to .advertised + arms sender watchdog.
    await store.send(.advertise) { $0.status = .advertised }

    // Sender watchdog timeout in .advertised = rtt * partTimeoutFactor + processingGrace
    // With defaults: 1s * 4 + 1s = 5s. Advance well past it.
    await clock.advance(by: .seconds(15))

    // The watchdog must fire on its own — NOT a manual send.
    // We drain the initial ADV transmit, then the auto-fired senderDeadline.
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    await store.receive { if case .senderDeadline = $0 { return true }; return false }

    // Handler ran: advRetriesLeft should have decremented (maxAdvRetries → maxAdvRetries-1).
    #expect(store.state.advRetriesLeft == ResourceTransfer.Const.maxAdvRetries - 1)

    // Drive to terminal state: exhaust remaining adv retries then one final deadline.
    for _ in 0...ResourceTransfer.Const.maxAdvRetries {
        await store.send(.senderDeadline)
    }
    #expect(store.state.status == .failed)
}

// MARK: - HMU sender tests

// Build an exhausted RESOURCE_REQ (0xFF ‖ lastHash ‖ hash ‖ requested) for a sender state.
private func exhaustedRequestPacket(_ s: ResourceTransfer.State, lastMapHash: Data, requested: [Data]) -> Data {
    var payload = Data([0xFF]) + lastMapHash + s.resourceHash
    for h in requested { payload += h }
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .resourceRequest, contextFlag: false, hops: 0,
                   destinationHash: linkID, transportId: nil, payload: Link.encrypt(payload, sessionKey: key))
    return try! p.packed()
}

@Test @MainActor func senderAdvertisementCapsHashmapAt74() async {
    let data = Data(repeating: 0x5A, count: 800)          // > 74 parts at sdu 8
    let s = senderState(data, sdu: 8)
    #expect(s.parts.count > 74)
    #expect(s.advertisement!.hashmap.count == 74 * 4)     // capped, not the full N*4
    #expect(s.advertisement!.numberOfParts == UInt64(s.parts.count))
}

@Test @MainActor func senderRepliesWithHmuChunkOnExhaustedRequest() async {
    let data = Data(repeating: 0x5A, count: 800)
    let s = senderState(data, sdu: 8)
    let clock = TestClock<Duration>()
    let store = TestStore(initialState: s) { ResourceTransfer() }
        withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    // Exhausted request: last known map-hash is partMapHashes[73] (74-boundary).
    let last = s.partMapHashes[73]
    await store.send(.received(exhaustedRequestPacket(s, lastMapHash: last, requested: [])))
    // The sender emits a RESOURCE_HMU for chunk 1 (parts 74..147).
    let raw = (await captureTransmits(store, count: 1)).first { Packet(raw: $0)?.context == .resourceHashmapUpdate }!
    let plain = Data(Link.decrypt(Packet(raw: raw)!.payload, sessionKey: key)!)
    #expect(Data(plain.prefix(32)) == s.resourceHash)
    guard case let .array(items)? = MsgPack.decodeValue(Data(plain.dropFirst(32))),
          case let .uint(chunkIndex) = items[0], case let .bin(bytes) = items[1] else { Issue.record("bad HMU"); return }
    #expect(chunkIndex == 1)
    let expectedCount = min(74, s.partMapHashes.count - 74) * 4
    #expect(bytes.count == expectedCount)
    #expect(bytes == s.partMapHashes[74..<min(148, s.partMapHashes.count)].reduce(Data()) { $0 + $1 })
    // cleanup: drive terminal
    await store.send(.received(cancelPacket(.resourceReceiverCancel, s.resourceHash)))
}

@Test @MainActor func senderCancelsOnNonBoundaryHmuRequest() async {
    let data = Data(repeating: 0x5A, count: 800)
    let s = senderState(data, sdu: 8)
    let clock = TestClock<Duration>()
    let store = TestStore(initialState: s) { ResourceTransfer() }
        withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    // last known map-hash at a NON-boundary index (e.g. partMapHashes[72] → partIndex 73, 73 % 74 != 0).
    let last = s.partMapHashes[72]
    await store.send(.received(exhaustedRequestPacket(s, lastMapHash: last, requested: [])))
    // ICL transmit fires before .failed in the merge order; capture it using the predicate form.
    let iclData = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action,
           Packet(raw: raw)?.context == .resourceInitiatorCancel { iclData.setValue(raw); return true }
        return false
    }
    await store.receive(.delegate(.failed))
    #expect(store.state.status == .failed)
    #expect(iclData.value != nil)
}

// Build a RESOURCE_HMU packet for chunk `idx` carrying `hashes`.
private func hmuPacket(_ hash: Data, chunk: Int, hashes: Data) -> Data {
    let payload = hash + MsgPack.encode(.array([.uint(UInt64(chunk)), .bin(hashes)]))
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .resourceHashmapUpdate, contextFlag: false, hops: 0,
                   destinationHash: linkID, transportId: nil, payload: Link.encrypt(payload, sessionKey: key))
    return try! p.packed()
}

@Test @MainActor func receiverEmitsExhaustedRequestWhenHashmapRunsOut() async {
    let data = Data(repeating: 0x33, count: 800)          // > 74 parts at sdu 8
    let sender = senderState(data, sdu: 8)
    let clock = TestClock<Duration>()
    let store = receiverStore(clock)
    await store.send(.accept(advertisementPacket(sender)))
    #expect(store.state.hashmapHeight == 74)              // ADV seeded first 74
    _ = await captureTransmits(store, count: 1)           // first REQ (parts 0..3, all known)

    // In TCA 1.26.0 non-exhaustive TestStore, unobserved effect-actions are discarded on
    // the next store.send call. So we must drain each round-boundary REQ immediately after
    // the send that triggers it. We save the last drained REQ (the 0xFF one).
    // (Deviation from brief: interleave drain inside loop; all correctness assertions kept.)
    var lastREQ: Data? = nil
    for n in 0..<74 {
        let prevWaiting = store.state.waitingForHMU
        let prevOutstanding = store.state.outstanding
        await store.send(.received(partPacket(sender.parts[n])))
        let newOutstanding = store.state.outstanding
        // A REQ is emitted when a round completes: outstanding transitions to a fully new set.
        // Also when waitingForHMU just became true (exhausted REQ).
        let newRoundStarted = !newOutstanding.isEmpty && newOutstanding.isDisjoint(with: prevOutstanding)
        let exhaustedFired = store.state.waitingForHMU && !prevWaiting
        if newRoundStarted || exhaustedFired {
            let captured = await captureTransmits(store, count: 1)
            if let pkt = captured.first { lastREQ = pkt }
        }
    }
    // lastREQ is the 0xFF exhausted request.
    let raw = lastREQ
    #expect(raw != nil)
    guard let raw = raw else { return }
    let plain = Data(Link.decrypt(Packet(raw: raw)!.payload, sessionKey: key)!)
    #expect(plain.first == 0xFF)
    #expect(Data(plain[(plain.startIndex + 1)..<(plain.startIndex + 5)]) == sender.partMapHashes[73])  // last known hash
    #expect(store.state.waitingForHMU == true)
    // cleanup
    await store.send(.cancel); _ = await captureTransmits(store, count: 1)
}

@Test @MainActor func receiverIngestsHmuAndExtendsHashmap() async {
    let data = Data(repeating: 0x33, count: 800)
    let sender = senderState(data, sdu: 8)
    let clock = TestClock<Duration>()
    let store = receiverStore(clock)
    await store.send(.accept(advertisementPacket(sender)))
    _ = await captureTransmits(store, count: 1)
    // Feed 74 parts with same round-boundary drain technique as receiverEmitsExhaustedRequest.
    for n in 0..<74 {
        let prevWaiting = store.state.waitingForHMU
        let prevOutstanding = store.state.outstanding
        await store.send(.received(partPacket(sender.parts[n])))
        let newOutstanding = store.state.outstanding
        let newRoundStarted = !newOutstanding.isEmpty && newOutstanding.isDisjoint(with: prevOutstanding)
        let exhaustedFired = store.state.waitingForHMU && !prevWaiting
        if newRoundStarted || exhaustedFired {
            _ = await captureTransmits(store, count: 1)  // drain each REQ as it appears
        }
    }
    #expect(store.state.waitingForHMU == true)

    // Deliver chunk 1 (parts 74..min(148,N)).
    let hi = min(148, sender.partMapHashes.count)
    let chunkBytes = sender.partMapHashes[74..<hi].reduce(Data()) { $0 + $1 }
    await store.send(.received(hmuPacket(sender.resourceHash, chunk: 1, hashes: chunkBytes)))
    #expect(store.state.hashmapHeight == hi)
    #expect(store.state.waitingForHMU == false)
    // The receiver resumes requesting (a normal REQ goes out).
    let more = (await captureTransmits(store, count: 1)).first {
        Link.decrypt(Packet(raw: $0)!.payload, sessionKey: key)?.first == 0x00
    }
    #expect(more != nil)
    // cleanup
    await store.send(.cancel); _ = await captureTransmits(store, count: 1)
}

// How many transmits the sender will emit in response to `reqFrame`:
// one RESOURCE part per requested map-hash, plus one RESOURCE_HMU if the request was exhausted (0xFF).
private func expectedSenderTransmits(_ reqFrame: Data) -> Int {
    let plain = Data(Link.decrypt(Packet(raw: reqFrame)!.payload, sessionKey: key)!)
    let exhausted = plain.first == 0xFF
    let pad = exhausted ? 5 : 1                    // flag(1) [+ last_map_hash(4) when exhausted]
    let reqBytes = max(0, plain.count - pad - 32)  // minus flag/pad and the 32-byte resource hash
    let parts = reqBytes / 4
    return parts + (exhausted ? 1 : 0)
}

@Test @MainActor func endToEndTransferWithHmuAcrossHashmapBoundary() async {
    let data = Data((0..<900).map { UInt8($0 & 0xff) })   // ~113 parts at sdu 8 → ≥1 HMU round
    let senderClock = TestClock<Duration>()
    let receiverClock = TestClock<Duration>()
    let sender = TestStore(initialState: senderState(data, sdu: 8)) { ResourceTransfer() }
        withDependencies: { $0.continuousClock = senderClock }
    sender.exhaustivity = .off
    let receiver = TestStore(initialState: receiverState()) { ResourceTransfer() }
        withDependencies: { $0.continuousClock = receiverClock }
    receiver.exhaustivity = .off

    await sender.send(.advertise)
    let adv = (await captureTransmits(sender, count: 1))[0]
    await receiver.send(.accept(adv))
    var req = (await captureTransmits(receiver, count: 1))[0]

    let got = LockIsolated<Data?>(nil)
    var guardCount = 0
    while receiver.state.status != .complete && guardCount < 400 {
        guardCount += 1
        // The sender emits exactly `requested parts (+ 1 HMU if the REQ was exhausted)` transmits.
        let n = expectedSenderTransmits(req)
        await sender.send(.received(req))
        let outs = await captureTransmits(sender, count: n)
        for frame in outs { await receiver.send(.received(frame)) }   // parts + HMU both route in
        if receiver.state.status == .complete {
            await receiver.receive { if case .delegate(.transmit) = $0 { return true }; return false }  // PRF
            await receiver.receive { action in
                if case let .delegate(.received(d)) = action { got.setValue(d); return true }
                return false
            }
            break
        }
        // Receiver emits its next request (normal or exhausted) in response to the parts/HMU it got.
        req = (await captureTransmits(receiver, count: 1))[0]
    }
    #expect(got.value == data)
    #expect(receiver.state.status == .complete)
    #expect(sender.state.parts.count > 74)               // the transfer genuinely crossed the HMU boundary

    // Feed the proof back so the sender concludes.
    let proof = Resource.proofData(data: data, hash: sender.state.resourceHash)
    let pkt = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                     destinationType: .link, context: .resourceProof, contextFlag: false, hops: 0,
                     destinationHash: linkID, transportId: nil, payload: proof)
    await sender.send(.received(try! pkt.packed()))
    await sender.receive(.delegate(.concluded))
    #expect(sender.state.status == .complete)
}
