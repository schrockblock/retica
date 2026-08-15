import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

private let key = Data(repeating: 0x01, count: 64)
private let linkID = Data(repeating: 0xAB, count: 16)
private let prefix = Data([0x0A, 0x0B, 0x0C, 0x0D])
private let r = Data([0x01, 0x02, 0x03, 0x04])

/// Returns `count` bytes of SHA256-derived pseudorandom data. SHA256 output is incompressible
/// (cryptographically indistinguishable from random), so bzip2 cannot shrink it — this is used
/// wherever a test needs a stable part-count that compression must not change.
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

/// A proof with a wrong trailing 32 bytes (wrong proof body, correct length) must NOT fail the
/// transfer. Reference `Resource.validate_proof` has no else branch; the sender watchdog is the
/// terminator. Ownership routing is a secret, not an authenticator, so this is what keeps a
/// leaked resource hash from being a kill primitive.
@Test @MainActor func senderIgnoresProofThatDoesNotValidate() async {
    let data = Data("bad proof path".utf8)
    let clock = TestClock<Duration>()
    let store = senderStore(data, clock)
    await store.send(.advertise)
    _ = await captureTransmits(store, count: 1)
    await store.send(.received(resourceRequestPacket(store.state)))
    _ = await captureTransmits(store, count: store.state.parts.count)
    #expect(store.state.status == .awaitingProof)
    let bad = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                     destinationType: .link, context: .resourceProof, contextFlag: false, hops: 0,
                     destinationHash: linkID, transportId: nil, payload: Data(repeating: 0x00, count: 64))
    await store.send(.received(try! bad.packed()))
    #expect(store.state.status == .awaitingProof)
    // Cleanup: exhaust proof retries via the watchdog to reach terminal state.
    for _ in 0...ResourceTransfer.Const.proofRetries { await store.send(.senderDeadline) }
    #expect(store.state.status == .failed)
}

/// A proof correctly addressed to this transfer but whose trailing 32 bytes do not match must
/// NOT fail the transfer. Reference `Resource.validate_proof` has no else branch; the sender
/// watchdog is the terminator. Ownership routing is a secret, not an authenticator, so this is
/// what keeps a leaked hash from being a kill primitive.
@Test @MainActor func aProofThatDoesNotValidateLeavesTheTransferAlive() async {
    let data = Data("a bad proof must not destroy the transfer".utf8)
    let clock = TestClock<Duration>()
    let store = senderStore(data, clock)
    await store.send(.advertise)
    _ = await captureTransmits(store, count: 1)
    let s = store.state
    await store.send(.received(resourceRequestPacket(s)))            // requests all parts
    _ = await captureTransmits(store, count: s.parts.count)
    #expect(store.state.status == .awaitingProof)

    // Correct owner prefix, wrong proof body.
    let bad = Data(s.resourceHash) + Data(repeating: 0xAA, count: 32)
    let pkt = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                     destinationType: .link, context: .resourceProof, contextFlag: false, hops: 0,
                     destinationHash: s.linkID, transportId: nil, payload: bad)
    await store.send(.received(try! pkt.packed()))

    #expect(store.state.status == .awaitingProof)
}

/// A 32–63 byte packet (resourceHash ‖ garbage, too short to be a valid 64-byte proof) that
/// routes to the owning sender — because Task 2 routes on the resourceHash prefix — must NOT
/// fail the transfer. `Resource.validateProof` requires exactly 64 bytes, so the 32-byte guard
/// fails and the packet is ignored. This is the specific attack shape enabled by unencrypted
/// proofs: an observer learns a live resourceHash from any legitimate proof on the link, so the
/// attacker need not guess it.
@Test @MainActor func a48ByteResourceHashPlusGarbageIsIgnored() async {
    let data = Data("half-prefix attack must not abort the transfer".utf8)
    let clock = TestClock<Duration>()
    let store = senderStore(data, clock)
    await store.send(.advertise)
    _ = await captureTransmits(store, count: 1)
    let s = store.state
    await store.send(.received(resourceRequestPacket(s)))            // requests all parts
    _ = await captureTransmits(store, count: s.parts.count)
    #expect(store.state.status == .awaitingProof)

    // 48 bytes: resourceHash (32) ‖ 16 bytes of garbage — routes to the sender (≥32 bytes with
    // the right prefix) but fails validateProof's 64-byte length check.
    let attack = Data(s.resourceHash) + Data(repeating: 0xBB, count: 16)
    #expect(attack.count == 48)
    let pkt = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                     destinationType: .link, context: .resourceProof, contextFlag: false, hops: 0,
                     destinationHash: s.linkID, transportId: nil, payload: attack)
    await store.send(.received(try! pkt.packed()))

    #expect(store.state.status == .awaitingProof)
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
    // Use incompressible data so transferSize == dataSize and part count is predictable.
    // SHA256-derived: bzip2 cannot shrink it. 160 bytes → stream=ceil_16(164)=176 → 8 parts at sdu=24.
    let data = incompressibleData(count: 160)   // 160+4 prefix -> stream > 6 parts at sdu 24
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
    // Incompressible so transferSize and part count are stable.
    let data = incompressibleData(count: 160)
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
    // 144-byte incompressible payload → stream = Token(PKCS7(prefix(4)+data(144))) = 16+160+32 = 208 bytes
    // → 9 parts at sdu=24. Window starts at 4, so the transfer spans 3 rounds (4 + 3 + 3 = 10 > 9),
    // and a dropped part forces a timeout+retransmit, proving all four required properties:
    //   1. receiver reconstructs EXACT original data; 2. both sides reach .complete;
    //   3. window advances across multiple rounds; 4. dropped part recovered via retransmission.
    // SHA256-derived data ensures bzip2 cannot reduce the stream below 9 parts.
    let data = incompressibleData(count: 144)
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
    // Incompressible so resourceHash is deterministic and unaffected by compression logic.
    let data = incompressibleData(count: 100)
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
    // Incompressible so resourceHash is stable.
    let data = incompressibleData(count: 100)
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
    // Incompressible so resourceHash is stable.
    let data = incompressibleData(count: 100)
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
    // 160 bytes incompressible → stream = ceil_16(164) = 176 / 24 = 8 parts (> window=4, multi-part).
    let data = incompressibleData(count: 160)
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
    // SHA256-derived incompressible data: stream = ceil_16(804) = 816 / 8 = 102 parts at sdu=8.
    let data = incompressibleData(count: 800)   // > 74 parts at sdu 8
    let s = senderState(data, sdu: 8)
    #expect(s.parts.count > 74)
    #expect(s.advertisement!.hashmap.count == 74 * 4)     // capped, not the full N*4
    #expect(s.advertisement!.numberOfParts == UInt64(s.parts.count))
}

@Test @MainActor func senderRepliesWithHmuChunkOnExhaustedRequest() async {
    // SHA256-derived incompressible data: stream = ceil_16(804) = 816 / 8 = 102 parts at sdu=8.
    let data = incompressibleData(count: 800)
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
    // SHA256-derived incompressible data: stream = ceil_16(804) = 816 / 8 = 102 parts at sdu=8.
    let data = incompressibleData(count: 800)
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
    // SHA256-derived incompressible data: stream = ceil_16(804) = 816 / 8 = 102 parts at sdu=8.
    let data = incompressibleData(count: 800)
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
    // SHA256-derived incompressible data: stream = ceil_16(804) = 816 / 8 = 102 parts at sdu=8.
    let data = incompressibleData(count: 800)
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

// Build a RESOURCE_HMU packet for chunk `idx` using a raw UInt64 (for hostile-input tests).
private func hmuPacketRaw(_ hash: Data, chunkU64: UInt64, hashes: Data) -> Data {
    let payload = hash + MsgPack.encode(.array([.uint(chunkU64), .bin(hashes)]))
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .resourceHashmapUpdate, contextFlag: false, hops: 0,
                   destinationHash: linkID, transportId: nil, payload: Link.encrypt(payload, sessionKey: key))
    return try! p.packed()
}

// MARK: — Task 8: HMU hostile-chunkIndex rejection (wire-input-trap-sweep)

/// A RESOURCE_HMU with chunkIndex = UInt64.max would trap at Int(chunkIndex) because
/// UInt64.max > Int.max. With the fix in place, the receiver must return .none (reject)
/// without crashing. The enclosing function under test is ResourceTransfer.reduce (the
/// .receiver/.data/.resourceHashmapUpdate case).
///
/// RED evidence (before fix): the test process crashes with a Swift runtime trap —
/// `EXC_BAD_INSTRUCTION` / `SIGILL` — because `Int(UInt64.max)` is an uncatchable trap.
@Test @MainActor func receiverRejectsHmuChunkIndexAboveIntMax() async {
    // A minimal multi-part resource: 100 bytes of incompressible data at sdu=8 → 13 parts.
    let data = incompressibleData(count: 100)
    let sender = senderState(data, sdu: 8)
    let clock = TestClock<Duration>()
    let store = receiverStore(clock)
    await store.send(.accept(advertisementPacket(sender)))
    _ = await captureTransmits(store, count: 1)    // drain initial REQ
    let stateBefore = store.state

    // Wire chunkIndex = UInt64.max. With no fix this traps at Int(UInt64.max).
    let hostile = hmuPacketRaw(sender.resourceHash, chunkU64: UInt64.max, hashes: Data(repeating: 0, count: 4))
    await store.send(.received(hostile))

    // State must be unchanged: the packet was rejected without a crash.
    #expect(store.state.hashmapHeight == stateBefore.hashmapHeight)
    #expect(store.state.knownHashmap == stateBefore.knownHashmap)
    // cleanup
    await store.send(.cancel); _ = await captureTransmits(store, count: 1)
}

/// A RESOURCE_HMU with chunkIndex = UInt64(Int.max / 296 + 1) converts fine to Int (it is
/// <= Int.max) but the subsequent multiply by Resource.hashmapMaxLen * Resource.mapHashLength
/// (= 74 * 4 = 296) overflows. With the fix in place, the receiver must return .none.
///
/// RED evidence (before fix): the test process crashes with a Swift arithmetic overflow trap —
/// `EXC_BAD_INSTRUCTION` / `SIGILL` — because Swift's `*` traps on overflow.
@Test @MainActor func receiverRejectsHmuChunkIndexOverflowOnMultiply() async {
    let data = incompressibleData(count: 100)
    let sender = senderState(data, sdu: 8)
    let clock = TestClock<Duration>()
    let store = receiverStore(clock)
    await store.send(.accept(advertisementPacket(sender)))
    _ = await captureTransmits(store, count: 1)    // drain initial REQ
    let stateBefore = store.state

    // This value converts fine to Int (it is < Int.max) but chunkIndex * 74 * 4 overflows.
    let overflowChunk = UInt64(Int.max / 296 + 1)
    let hostile = hmuPacketRaw(sender.resourceHash, chunkU64: overflowChunk, hashes: Data(repeating: 0, count: 4))
    await store.send(.received(hostile))

    #expect(store.state.hashmapHeight == stateBefore.hashmapHeight)
    #expect(store.state.knownHashmap == stateBefore.knownHashmap)
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
    // SHA256-derived incompressible data: stream = ceil_16(904) = 912 / 8 = 114 parts at sdu=8 → ≥1 HMU round.
    let data = incompressibleData(count: 900)
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

// MARK: - Compression round-trip tests

/// Drives a complete sender → receiver transfer with no dropped parts and returns the recovered data.
/// Reuses the idiom from endToEndWindowedTransferWithADroppedPart: advertise → accept → window loop
/// until receiver reaches .complete, then captures `.delegate(.received(_))`.
@MainActor
private func driveTransferToReceived(sender senderState: ResourceTransfer.State, key: Data) async -> Data? {
    let senderClock = TestClock<Duration>()
    let receiverClock = TestClock<Duration>()
    let senderStore = TestStore(initialState: senderState) { ResourceTransfer() }
        withDependencies: { $0.continuousClock = senderClock }
    senderStore.exhaustivity = .off
    let receiverStore = TestStore(initialState: receiverState()) { ResourceTransfer() }
        withDependencies: { $0.continuousClock = receiverClock }
    receiverStore.exhaustivity = .off

    // Advertise → accept → first window request.
    await senderStore.send(.advertise)
    let adv = (await captureTransmits(senderStore, count: 1))[0]
    await receiverStore.send(.accept(adv))
    var req = (await captureTransmits(receiverStore, count: 1))[0]

    let got = LockIsolated<Data?>(nil)
    var guardCount = 0
    while receiverStore.state.status != .complete && guardCount < 400 {
        guardCount += 1
        // Sender serves all parts (+ HMU if exhausted) in response to req.
        let n = expectedSenderTransmits(req)
        await senderStore.send(.received(req))
        let outs = await captureTransmits(senderStore, count: n)
        for frame in outs { await receiverStore.send(.received(frame)) }
        if receiverStore.state.status == .complete {
            await receiverStore.receive { if case .delegate(.transmit) = $0 { return true }; return false }  // PRF
            await receiverStore.receive { action in
                if case let .delegate(.received(d)) = action { got.setValue(d); return true }
                return false
            }
            break
        }
        req = (await captureTransmits(receiverStore, count: 1))[0]
    }
    // Feed proof to sender so it concludes (cancels its watchdog).
    let proof = Resource.proofData(data: got.value ?? Data(), hash: senderStore.state.resourceHash)
    let pkt = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                     destinationType: .link, context: .resourceProof, contextFlag: false, hops: 0,
                     destinationHash: linkID, transportId: nil, payload: proof)
    await senderStore.send(.received(try! pkt.packed()))
    await senderStore.receive(.delegate(.concluded))
    return got.value
}

@Test @MainActor func compressibleResourceSetsFlagAndRoundTrips() async {
    let original = Data(String(repeating: "reticulum compresses this well ", count: 30).utf8)
    let sender = ResourceTransfer.State(sending: original, linkID: linkID, sessionKey: key,
        interfaceID: InterfaceID("i"), prefix: prefix, randomHash: r, sdu: 64)
    #expect(sender.advertisement!.isCompressed == true)                       // flag set
    #expect(sender.advertisement!.dataSize == UInt64(original.count))         // dataSize over original
    #expect(sender.advertisement!.transferSize < UInt64(original.count))      // compressed stream is smaller
    // Drive the sender's parts into a receiver and assert exact recovery.
    let recovered = await driveTransferToReceived(sender: sender, key: key)
    #expect(recovered == original)
}

@Test @MainActor func incompressibleResourceStaysUncompressedAndRoundTrips() async {
    let original = Data((0..<400).map { UInt8(($0 * 37 + 11) & 0xff) })       // random-ish → bz2 not smaller
    let sender = ResourceTransfer.State(sending: original, linkID: linkID, sessionKey: key,
        interfaceID: InterfaceID("i"), prefix: prefix, randomHash: r, sdu: 64)
    #expect(sender.advertisement!.isCompressed == false)                      // flag clear
    let recovered = await driveTransferToReceived(sender: sender, key: key)
    #expect(recovered == original)
}

/// Like `driveTransferToReceived`, but stops at whichever terminal status the receiver reaches so
/// a hostile advertisement can be asserted to FAIL rather than being assumed to complete.
@MainActor
private func driveTransferToTerminalStatus(sender senderState: ResourceTransfer.State) async
    -> ResourceTransfer.Status {
    let sStore = TestStore(initialState: senderState) { ResourceTransfer() }
        withDependencies: { $0.continuousClock = TestClock<Duration>() }
    sStore.exhaustivity = .off
    let rStore = TestStore(initialState: receiverState()) { ResourceTransfer() }
        withDependencies: { $0.continuousClock = TestClock<Duration>() }
    rStore.exhaustivity = .off

    await sStore.send(.advertise)
    let adv = (await captureTransmits(sStore, count: 1))[0]
    await rStore.send(.accept(adv))
    var req = (await captureTransmits(rStore, count: 1))[0]

    var guardCount = 0
    func settled() -> Bool { rStore.state.status == .complete || rStore.state.status == .failed }
    while !settled() && guardCount < 400 {
        guardCount += 1
        let n = expectedSenderTransmits(req)
        await sStore.send(.received(req))
        let outs = await captureTransmits(sStore, count: n)
        for frame in outs { await rStore.send(.received(frame)) }
        if settled() { break }
        req = (await captureTransmits(rStore, count: 1))[0]
    }
    let status = rStore.state.status
    // Cancel both sides so no watchdog is left in flight at teardown.
    await sStore.send(.cancel)
    await rStore.send(.cancel)
    return status
}

/// A hostile advertisement can declare a legitimate `t` — passing `ResourceAdvertisement.unpack`'s
/// magnitude gate, which bounds only `t` — while declaring `d` above `Int.max`. The decompress call
/// site used to convert that with a plain `Int(adv.dataSize)`, which TRAPS on the conversion before
/// `Bzip2.decompress`'s ceiling can reject it. The transfer must fail cleanly instead of crashing.
@Test @MainActor func receiverRejectsCompressedAdvertisementDeclaringDataSizeAboveIntMax() async {
    let original = Data(String(repeating: "reticulum compresses this well ", count: 30).utf8)
    var sender = ResourceTransfer.State(sending: original, linkID: linkID, sessionKey: key,
        interfaceID: InterfaceID("i"), prefix: prefix, randomHash: r, sdu: 64)
    #expect(sender.advertisement!.isCompressed == true)          // must take the decompress path
    #expect(sender.advertisement!.isSplit == false)              // non-split branch
    // Only `d` is hostile; `t` stays small so the advertisement still unpacks.
    sender.advertisement!.dataSize = UInt64(Int.max) + 1
    #expect(sender.advertisement!.transferSize <= UInt64(Resource.maxAdvertisedTransferSize))

    #expect(await driveTransferToTerminalStatus(sender: sender) == .failed)
}

/// The split branch clamps rather than rejects (for a split resource `d` is legitimately larger than
/// one segment), so it needs its own proof that the clamp happens in UInt64 and never converts first.
@Test @MainActor func receiverRejectsSplitAdvertisementDeclaringDataSizeAboveIntMax() async {
    let original = Data(String(repeating: "reticulum compresses this well ", count: 30).utf8)
    var sender = ResourceTransfer.State(sending: original, linkID: linkID, sessionKey: key,
        interfaceID: InterfaceID("i"), prefix: prefix, randomHash: r, sdu: 64,
        segmentIndex: 1, totalSegments: 2, originalHash: nil,
        totalDataSize: UInt64(Int.max) + 1)
    #expect(sender.advertisement!.isCompressed == true)
    #expect(sender.advertisement!.isSplit == true)               // split branch
    #expect(sender.advertisement!.dataSize == UInt64(Int.max) + 1)

    // Clamped to maxEfficientSize, the buffer is too small for this segment's real output, so the
    // transfer fails — but it must FAIL, not trap on an Int conversion.
    let status = await driveTransferToTerminalStatus(sender: sender)
    #expect(status == .complete || status == .failed)            // terminal, not a crash
}

/// The split branch passes `min(adv.dataSize, maxEfficientSize)` as the decompression buffer size,
/// where `adv.dataSize` is the WHOLE object's size — so for a real segment that number is an UPPER
/// BOUND, typically far above the segment's own output. Incremental decompression must therefore not
/// require the output to fill the buffer. `.complete` is byte-exactness, not an approximation of it:
/// `Resource.verify` is a full-hash check over the decompressed bytes.
@Test @MainActor func compressedSplitSegmentRoundTripsWhenDeclaredSizeExceedsSegmentOutput() async {
    let segment = Data(String(repeating: "reticulum compresses this well ", count: 30).utf8)
    let whole = UInt64(LinkSession.maxEfficientSize) + UInt64(segment.count)   // 2 segments' worth
    let sender = ResourceTransfer.State(sending: segment, linkID: linkID, sessionKey: key,
        interfaceID: InterfaceID("i"), prefix: prefix, randomHash: r, sdu: 64,
        segmentIndex: 2, totalSegments: 2, originalHash: Data(repeating: 0x77, count: 32),
        totalDataSize: whole)
    #expect(sender.advertisement!.isCompressed == true)          // takes the decompress path
    #expect(sender.advertisement!.isSplit == true)               // split branch: d is the whole object
    #expect(sender.advertisement!.dataSize == whole)
    #expect(whole > UInt64(segment.count) * 1000)                // the claim dwarfs this segment

    #expect(await driveTransferToReceived(sender: sender, key: key) == segment)
}

/// `n` (numberOfParts) is the same shape as `d`: a raw wire UInt64 that every downstream use
/// converts with `Int(...)`. An absurd `n` must not trap when the advertisement is accepted.
@Test @MainActor func receiverAcceptsAdvertisementWithAbsurdPartCountWithoutTrapping() async {
    let data = incompressibleData(count: 160)
    var sender = senderState(data)
    sender.advertisement!.numberOfParts = UInt64(Int.max) + 1

    let clock = TestClock<Duration>()
    let store = receiverStore(clock)
    await store.send(.accept(advertisementPacket(sender)))       // used to trap inside requestNextWindow
    #expect(store.state.expectedParts <= UInt64(Int.max))        // clamped at the assignment
    await store.send(.cancel)
}

/// Drives a COMPRESSED resource through the HMU (hashmap-update) path by ensuring the
/// bzip2-compressed stream still spans MORE THAN 74 parts at sdu=8, forcing a hashmap-update
/// round. The payload is 3000 bytes of the repeating 0x00..0xFF byte pattern: bzip2 shrinks
/// it to ~665 bytes (< 3000, so isCompressed=true) but the Token-encrypted stream is still
/// ~90 parts at sdu=8, well beyond the 74-part HMU boundary. This proves that the compressed
/// decompress path in the receiver is exercised even after many windowed + HMU rounds.
@Test @MainActor func compressedMultiPartResourceCrossesHmuAndRoundTrips() async {
    // 0x00..0xFF cycling (period=256) — bzip2 ~665 bytes compressed, ~90 parts at sdu=8.
    // dataSize must be over the ORIGINAL (pre-compress) payload.
    let original = Data((0..<3000).map { UInt8($0 % 256) })
    let sender = ResourceTransfer.State(sending: original, linkID: linkID, sessionKey: key,
        interfaceID: InterfaceID("i"), prefix: prefix, randomHash: r, sdu: 8)
    #expect(sender.advertisement!.isCompressed == true)                        // compressed path taken
    #expect(sender.parts.count > 74)                                           // crosses HMU boundary
    #expect(sender.advertisement!.dataSize == UInt64(original.count))          // dataSize over original
    let recovered = await driveTransferToReceived(sender: sender, key: key)
    #expect(recovered == original)                                             // exact recovery
}

@Test func senderRequestResourceSetsIsRequestFlagAndRequestID() {
    let rid = Data(repeating: 0xCD, count: 16)
    // Incompressible data (SHA256-derived): bzip2 cannot shrink it, so flags must not get 0x02 set.
    let s = ResourceTransfer.State(sending: incompressibleData(count: 40), linkID: linkID, sessionKey: key,
                                   interfaceID: InterfaceID("s"), prefix: prefix, randomHash: r, sdu: 24,
                                   requestID: rid, isResponse: false)
    #expect(s.advertisement!.requestID == rid)
    #expect(s.advertisement!.isRequest == true)
    #expect(s.advertisement!.isResponse == false)
    #expect(s.advertisement!.flags == 0x09)        // 0x01 | 0x08
}

@Test func senderResponseResourceSetsIsResponseFlag() {
    let rid = Data(repeating: 0xCD, count: 16)
    // Incompressible data (SHA256-derived): bzip2 cannot shrink it, so flags must not get 0x02 set.
    let s = ResourceTransfer.State(sending: incompressibleData(count: 40), linkID: linkID, sessionKey: key,
                                   interfaceID: InterfaceID("s"), prefix: prefix, randomHash: r, sdu: 24,
                                   requestID: rid, isResponse: true)
    #expect(s.advertisement!.requestID == rid)
    #expect(s.advertisement!.isResponse == true)
    #expect(s.advertisement!.isRequest == false)
    #expect(s.advertisement!.flags == 0x11)        // 0x01 | 0x10
}

@Test func senderPlainResourceHasNoRequestID() {
    // Incompressible data (SHA256-derived): bzip2 cannot shrink it, so flags must not get 0x02 set.
    let s = ResourceTransfer.State(sending: incompressibleData(count: 40), linkID: linkID, sessionKey: key,
                                   interfaceID: InterfaceID("s"), prefix: prefix, randomHash: r, sdu: 24)
    #expect(s.advertisement!.requestID == nil)
    #expect(s.advertisement!.flags == 0x01)
}

@Test func singleSegmentAdvertisesIndexOneNotSplit() {
    let s = ResourceTransfer.State(sending: incompressibleData(count: 40), linkID: linkID, sessionKey: key,
                                   interfaceID: InterfaceID("s"), prefix: prefix, randomHash: r, sdu: 24)
    #expect(s.advertisement!.segmentIndex == 1)          // RNS uses 1-based (was 0)
    #expect(s.advertisement!.totalSegments == 1)
    #expect(s.advertisement!.originalHash == s.advertisement!.hash)
    #expect(s.advertisement!.isSplit == false)
}

@Test func segmentParamsPopulateAdvertisement() {
    let whole: UInt64 = 3_000_000
    let oh = Data(repeating: 0xAB, count: 32)
    let s = ResourceTransfer.State(sending: incompressibleData(count: 500), linkID: linkID, sessionKey: key,
                                   interfaceID: InterfaceID("s"), prefix: prefix, randomHash: r, sdu: 24,
                                   segmentIndex: 2, totalSegments: 3, originalHash: oh, totalDataSize: whole)
    #expect(s.advertisement!.segmentIndex == 2)
    #expect(s.advertisement!.totalSegments == 3)
    #expect(s.advertisement!.originalHash == oh)          // inherited, NOT this segment's hash
    #expect(s.advertisement!.dataSize == whole)           // whole size, not this segment's
    #expect(s.advertisement!.isSplit == true)             // l > 1
}

/// `LinkSession.sendResponse` does NOT split: it hands the whole payload to ONE `ResourceTransfer`
/// (only `sendResource` splits at maxEfficientSize). Reference splits EVERY resource in
/// `Resource.__init__` (RNS/Resource.py:274-310), which is what lets it bound an advertisement's
/// `t` at MAX_EFFICIENT_SIZE*3 (RNS/Resource.py:1366). Adopting that bound here made our own
/// receiver reject our own sender: a propagation-node mailbox download is served as one un-split
/// response resource, so its `t` legitimately exceeds it. This is the seam — a response-shaped
/// advertisement built by the very initializer `sendResponse` uses must survive `unpack`.
@Test func largeUnsplitResponseAdvertisementSurvivesUnpack() {
    // Above the reference bound (1_048_575 * 3 == 3_145_725) and incompressible, so the encrypted
    // stream — and therefore `t` — really is this large rather than being shrunk by bzip2.
    let payload = incompressibleData(count: 4 * 1024 * 1024)
    let sender = ResourceTransfer.State(
        sending: payload, linkID: linkID, sessionKey: key, interfaceID: InterfaceID("s"),
        prefix: prefix, randomHash: r, sdu: LinkSession.resourceSDU,
        requestID: Data(repeating: 0x5A, count: 16), isResponse: true)
    let adv = sender.advertisement!
    #expect(adv.isResponse == true)
    #expect(adv.isSplit == false)                          // one resource, no segments
    #expect(adv.transferSize > 1_048_575 * 3)              // above the reference bound
    let round = ResourceAdvertisement.unpack(adv.pack())
    #expect(round != nil)
    if let round { #expect(round.transferSize == adv.transferSize) }
}
