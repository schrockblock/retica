import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

private let receiptKey = Data(repeating: 0x02, count: 64)
private let receiptLinkID = Data(repeating: 0xBC, count: 16)

// Build an active initiator store whose destinationIdentity is the supplied `pn` identity.
@MainActor
private func initiatorStore(pn: Identity, _ clock: TestClock<Duration>)
    -> TestStore<LinkSession.State, LinkSession.Action> {
    var s = LinkSession.State(initiatorTo: pn, destinationHash: Data(repeating: 0x03, count: 16),
                              interfaceID: InterfaceID("i"))
    s.status = .active
    s.sessionKey = receiptKey
    s.linkID = receiptLinkID
    s.rtt = 1.0
    let store = TestStore(initialState: s) { LinkSession() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = clock
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

// Capture the next transmit's raw bytes.
@MainActor
private func captureTransmit(_ store: TestStore<LinkSession.State, LinkSession.Action>) async -> Data {
    let captured = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }
    return captured.value!
}

// Sender records a receipt and transmits; a valid proof fires packetDelivered(token).
@Test @MainActor func sendWithReceiptDeliveredOnValidProof() async {
    let clock = TestClock<Duration>()
    let pn = Identity()
    let store = initiatorStore(pn: pn, clock)
    let token = Data(repeating: 0x11, count: 32)

    // Send with receipt; the reducer should transmit the data packet.
    await store.send(.sendWithReceipt(data: Data("hello".utf8), token: token))
    let raw = await captureTransmit(store)

    // Recover the sent packet's 32-byte packetHash.
    let sentPacket = Packet(raw: raw)!
    let sentHash = sentPacket.packetHash

    // Build a valid proof: payload = packetHash(32) ‖ pn.sign(packetHash)(64).
    // pn is the destinationIdentity (the link's peer) so its signature is what we validate.
    let sig = pn.sign(sentHash)
    let proofPayload = sentHash + sig
    let proofPacket = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                             destinationType: .link, context: .none, contextFlag: false, hops: 0,
                             destinationHash: receiptLinkID, transportId: nil, payload: proofPayload)
    let proofRaw = try! proofPacket.packed()

    await store.send(.received(proofRaw))
    await store.receive { action in
        if case let .delegate(.packetDelivered(t)) = action { return t == token }
        return false
    }
    // After delivery, the pending receipt should be cleared.
    #expect(store.state.pendingDataReceipts[sentHash] == nil)
}

// A proof with a bad signature does NOT fire packetDelivered; receipt stays pending.
@Test @MainActor func sendWithReceiptIgnoresInvalidProof() async {
    let clock = TestClock<Duration>()
    let pn = Identity()
    let store = initiatorStore(pn: pn, clock)
    let token = Data(repeating: 0x22, count: 32)

    await store.send(.sendWithReceipt(data: Data("hello".utf8), token: token))
    let raw = await captureTransmit(store)

    let sentHash = Packet(raw: raw)!.packetHash

    // Build a proof with a zeroed (invalid) signature.
    let badSig = Data(repeating: 0, count: 64)
    let badPayload = sentHash + badSig
    let badProofPacket = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                                destinationType: .link, context: .none, contextFlag: false, hops: 0,
                                destinationHash: receiptLinkID, transportId: nil, payload: badPayload)
    await store.send(.received(try! badProofPacket.packed()))

    await store.finish()
    // packetDelivered must NOT have fired; receipt must still be pending.
    #expect(store.state.pendingDataReceipts[sentHash] != nil)
}
