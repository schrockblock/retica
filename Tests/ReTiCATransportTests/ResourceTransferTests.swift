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
    let captured = LockIsolated<[Data]>([])
    for _ in 0..<count {
        await store.receive { action in
            if case let .delegate(.transmit(_, raw)) = action { captured.withValue { $0.append(raw) }; return true }
            return false
        }
    }
    return captured.value
}

// Build a RESOURCE_REQ packet asking for all parts of `s`.
private func resourceRequestPacket(_ s: ResourceTransfer.State) -> Data {
    let req = Data([0x00]) + s.resourceHash + s.advertisement!.hashmap
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .resourceRequest, contextFlag: false, hops: 0,
                   destinationHash: linkID, transportId: nil, payload: Link.encrypt(req, sessionKey: key))
    return try! p.packed()
}

@Test @MainActor func senderAdvertiseEmitsResourceAdvertisement() async {
    let data = Data("a small resource to send".utf8)
    let s = senderState(data)
    let store = TestStore(initialState: s) { ResourceTransfer() }
    store.exhaustivity = .off
    await store.send(.advertise) { $0.status = .advertised }
    let raw = (await captureTransmits(store, count: 1))[0]
    let packet = Packet(raw: raw)!
    #expect(packet.context == .resourceAdvertisement)
    let plain = Link.decrypt(packet.payload, sessionKey: key)!
    let adv = ResourceAdvertisement.unpack(plain)!
    #expect(adv.hash == s.resourceHash)
    #expect(adv.numberOfParts == UInt64(s.parts.count))
    #expect(adv.flags == 0x01)
}

@Test @MainActor func senderRespondsToRequestWithAllParts() async {
    let data = Data(repeating: 0x7A, count: 200)   // several parts at sdu 24
    let s = senderState(data)
    let store = TestStore(initialState: s) { ResourceTransfer() }
    store.exhaustivity = .off
    await store.send(.received(resourceRequestPacket(s))) { $0.status = .transferring }
    let raws = await captureTransmits(store, count: s.parts.count)
    // Every emitted part is a raw RESOURCE packet carrying one of the ciphertext chunks.
    let sentChunks = raws.map { Packet(raw: $0)!.payload }
    #expect(raws.allSatisfy { Packet(raw: $0)!.context == .resource })
    #expect(Set(sentChunks) == Set(s.parts))
}

@Test @MainActor func senderConcludesOnValidProofFailsOnBad() async {
    let data = Data("prove it".utf8)
    let s = senderState(data)
    let store = TestStore(initialState: s) { ResourceTransfer() }
    store.exhaustivity = .off

    func proofPacket(_ payload: Data) -> Data {
        let p = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                       destinationType: .link, context: .resourceProof, contextFlag: false, hops: 0,
                       destinationHash: linkID, transportId: nil, payload: payload)
        return try! p.packed()
    }
    let goodProof = Resource.proofData(data: data, hash: s.resourceHash)   // hash ‖ full_hash(data ‖ hash)
    await store.send(.received(proofPacket(goodProof)))
    await store.receive(.delegate(.concluded)) { $0.status = .complete }

    let store2 = TestStore(initialState: senderState(data)) { ResourceTransfer() }
    store2.exhaustivity = .off
    await store2.send(.received(proofPacket(s.resourceHash + Data(repeating: 0x00, count: 32))))
    await store2.receive(.delegate(.failed)) { $0.status = .failed }
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
    // Drive to failure to cancel the armed watchdog (16 timeouts).
    for _ in 0..<ResourceTransfer.Const.maxRetries { await store.send(.receiverDeadline) }
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
    for _ in 0..<(ResourceTransfer.Const.maxRetries - 1) { await store.send(.receiverDeadline) }
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

@Test @MainActor func endToEndTwoReducerResourceTransfer() async {
    // Use data that fits in a single window (≤4 parts at sdu:24) to keep the end-to-end routing simple.
    // At sdu=24, token overhead=48 (IV+HMAC), prefix=4: 29 bytes data -> 33 plaintext -> PKCS7 48 -> 96 stream -> 4 parts.
    let data = Data("End-to-end windowed: 1 round.".utf8)
    let senderInit = senderState(data)
    let sender = TestStore(initialState: senderInit) { ResourceTransfer() }
    sender.exhaustivity = .off
    let clock = TestClock<Duration>()
    let receiver = TestStore(initialState: receiverState()) { ResourceTransfer() } withDependencies: { $0.continuousClock = clock }
    receiver.exhaustivity = .off

    // 1. Sender advertises → receiver accepts → requests first window.
    await sender.send(.advertise)
    let adv = (await captureTransmits(sender, count: 1))[0]
    await receiver.send(.accept(adv))
    let req = (await captureTransmits(receiver, count: 1))[0]

    // 2. Sender processes the windowed REQ and emits the requested parts.
    await sender.send(.received(req))
    _ = await captureTransmits(sender, count: senderInit.parts.count)

    // 3. Receiver ingests all parts (single window) using partPacket on the sender's chunks.
    //    All parts fit in the first window, so no intermediate window-request transmit is emitted.
    let partCount = senderInit.parts.count
    let got = LockIsolated<Data?>(nil)
    for (n, chunk) in senderInit.parts.enumerated() {
        await receiver.send(.received(partPacket(chunk)))
        if n == partCount - 1 {
            let proofOut = LockIsolated<Data?>(nil)
            await receiver.receive { action in
                if case let .delegate(.transmit(_, p)) = action,
                   Packet(raw: p)?.packetType == .proof { proofOut.setValue(p); return true }
                return false
            }
            await receiver.receive { action in
                if case let .delegate(.received(d)) = action { got.setValue(d); return true }
                return false
            }
            // 4. Proof → sender concludes.
            await sender.send(.received(proofOut.value!))
            await sender.receive(.delegate(.concluded))
        }
    }
    #expect(got.value == data)                       // receiver reconstructed the ORIGINAL data
    #expect(receiver.state.status == .complete)
    #expect(sender.state.status == .complete)
}
