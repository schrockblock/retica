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
