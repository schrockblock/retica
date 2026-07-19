import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

private let epoch = Date(timeIntervalSince1970: 0)

// Capture the raw bytes from the next delegate(.transmit(...)) emission.
@MainActor
private func captureTransmit(_ store: TestStore<LinkSession.State, LinkSession.Action>) async -> Data {
    let captured = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }
    return captured.value!
}

@Test @MainActor func initiatorEstablishEmitsLinkRequestAndGoesPending() async {
    let dest = Identity()
    let destHash = Data(repeating: 0x55, count: 16)
    let store = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: dest.publicKey)!,
                                        destinationHash: destHash, interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch) }
    store.exhaustivity = .off

    await store.send(.establish)
    let raw = await captureTransmit(store)
    let packet = Packet(raw: raw)!
    #expect(packet.packetType == .linkRequest)
    #expect(packet.destinationHash == destHash)
    #expect(packet.payload.count == 67)                          // ephemeral pub (64) + signalling (3)
    #expect(store.state.status == .pending)
    #expect(store.state.linkID == Link.linkID(requestPacket: packet))
}

@Test @MainActor func responderAcceptRequestEmitsProofAndGoesHandshake() async {
    let owner = Identity()
    let initEph = Identity()
    let destHash = Data(repeating: 0x66, count: 16)
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: destHash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    let requestRaw = try! request.packed()

    let store = TestStore(
        initialState: LinkSession.State(responderFor: owner, destinationHash: destHash,
                                        interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch) }
    store.exhaustivity = .off

    await store.send(.acceptRequest(requestRaw))
    let raw = await captureTransmit(store)
    let packet = Packet(raw: raw)!
    #expect(packet.packetType == .proof)
    #expect(packet.context == .linkRequestProof)
    #expect(packet.destinationHash == Link.linkID(requestPacket: request))
    #expect(store.state.status == .handshake)
    #expect(store.state.sessionKey.count == 64)
}

@Test @MainActor func initiatorRejectsTamperedProof() async {
    let dest = Identity()
    let store = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: dest.publicKey)!,
                                        destinationHash: Data(repeating: 0x55, count: 16),
                                        interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch) }
    store.exhaustivity = .off

    await store.send(.establish)
    _ = await captureTransmit(store)
    let linkID = store.state.linkID
    // A structurally valid but wrongly-signed proof (signed by a different identity).
    let proof = Link.buildProof(linkID: linkID, responderEphemeral: Identity(),
                                destinationIdentity: Identity())
    let proofPacket = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                             destinationType: .link, context: .linkRequestProof, contextFlag: false,
                             hops: 0, destinationHash: linkID, transportId: nil, payload: proof)
    await store.send(.received(try! proofPacket.packed()))
    await store.receive(.delegate(.establishmentFailed))
    #expect(store.state.status == .pending)                      // no transition on failure
}

@Test @MainActor func initiatorAndResponderReachActiveWithEqualSessionKey() async {
    let owner = Identity()                                  // responder owns this destination identity
    let destHash = Data(repeating: 0x77, count: 16)

    let initiator = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: owner.publicKey)!,
                                        destinationHash: destHash, interfaceID: InterfaceID("a"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch) }
    initiator.exhaustivity = .off

    let responder = TestStore(
        initialState: LinkSession.State(responderFor: owner, destinationHash: destHash,
                                        interfaceID: InterfaceID("b"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch) }
    responder.exhaustivity = .off

    // 1. Initiator → LINKREQUEST
    await initiator.send(.establish)
    let linkRequest = await captureTransmit(initiator)

    // 2. Responder accepts request → LRPROOF
    await responder.send(.acceptRequest(linkRequest))
    let proof = await captureTransmit(responder)
    #expect(responder.state.status == .handshake)

    // 3. Initiator validates proof → ACTIVE, emits LRRTT + established
    await initiator.send(.received(proof))
    let rttPacket = await captureTransmit(initiator)
    await initiator.receive { if case .delegate(.established) = $0 { return true }; return false }
    #expect(initiator.state.status == .active)

    // 4. Responder receives LRRTT → ACTIVE, established
    await responder.send(.received(rttPacket))
    await responder.receive { if case .delegate(.established) = $0 { return true }; return false }
    #expect(responder.state.status == .active)

    // Both sides derived the same non-empty session key.
    #expect(initiator.state.sessionKey.count == 64)
    #expect(initiator.state.sessionKey == responder.state.sessionKey)
}
