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
