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

// Build an active RESPONDER store owned by `owner`, sharing the initiator's linkID + session key.
@MainActor
private func responderStore(owner: Identity, _ clock: TestClock<Duration>)
    -> TestStore<LinkSession.State, LinkSession.Action> {
    var s = LinkSession.State(responderFor: owner, destinationHash: Data(repeating: 0x03, count: 16),
                              interfaceID: InterfaceID("r"))
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

// ROUND TRIP: the proof GENERATOR (`.provePacket`) must produce exactly what the existing
// `pendingDataReceipts` CONSUMER accepts. A real sender's receipt completes end to end:
//   initiator .sendWithReceipt → data packet → responder .received → .dataReceived(data, packetHash)
//   → responder .provePacket(packetHash) → proof packet → initiator .received → .packetDelivered.
//
// This is the defect Item 1 fixes: reference LXMF clients pick the PACKET path whenever the packed
// propagation payload fits the link MDU (LXMessage.py:426-444), and `LXMRouter.propagation_packet`
// calls `packet.prove()` (LXMRouter.py:2255). With no proof the client's receipt times out forever.
// Construction mirrors RNS/Link.py:378-388 (`packet_hash + sign(packet_hash)`, PROOF/NONE, unencrypted).
@Test @MainActor func inboundDataPacketProofCompletesSenderReceipt() async {
    let clock = TestClock<Duration>()
    let owner = Identity()                                  // the node's destination-owning identity
    let sender = initiatorStore(pn: owner, clock)           // its peer identity == owner (RNS Link.py:407)
    let node = responderStore(owner: owner, clock)
    let token = Data(repeating: 0x33, count: 32)

    // 1. Sender transmits a data packet and records a pending receipt.
    await sender.send(.sendWithReceipt(data: Data("propagation-offer".utf8), token: token))
    let dataRaw = await captureTransmit(sender)
    let sentHash = Packet(raw: dataRaw)!.packetHash
    #expect(sender.state.pendingDataReceipts[sentHash] != nil)

    // 2. The node receives it and is handed the very hash the sender is waiting on.
    let seenHash = LockIsolated<Data?>(nil)
    let seenData = LockIsolated<Data?>(nil)
    await node.send(.received(dataRaw))
    await node.receive { action in
        if case let .delegate(.dataReceived(d, h)) = action {
            seenData.setValue(d); seenHash.setValue(h); return true
        }
        return false
    }
    #expect(seenData.value == Data("propagation-offer".utf8))
    #expect(seenHash.value == sentHash)      // the delegate surfaces the sender's receipt key

    // 3. The node proves that packet.
    await node.send(.provePacket(packetHash: seenHash.value!))
    let proofRaw = await captureTransmit(node)

    // The proof is a PROOF packet addressed to the link, payload = packetHash(32) ‖ signature(64).
    let proofPacket = Packet(raw: proofRaw)!
    #expect(proofPacket.packetType == .proof)
    #expect(proofPacket.destinationType == .link)
    #expect(proofPacket.context == PacketContext.none)
    #expect(proofPacket.destinationHash == receiptLinkID)
    #expect(proofPacket.payload.count == 96)
    #expect(Data(proofPacket.payload.prefix(32)) == sentHash)

    // 4. The sender's receipt completes.
    await sender.send(.received(proofRaw))
    await sender.receive { action in
        if case let .delegate(.packetDelivered(t)) = action { return t == token }
        return false
    }
    #expect(sender.state.pendingDataReceipts[sentHash] == nil)
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
