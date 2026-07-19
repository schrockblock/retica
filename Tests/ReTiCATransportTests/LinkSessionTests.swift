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

private let sampleKey = Data(repeating: 0x01, count: 64)   // valid AES-256 Token key
private let sampleLinkID = Data(repeating: 0xAB, count: 16)

private func activeState(role: LinkSession.Role) -> LinkSession.State {
    var s: LinkSession.State
    switch role {
    case .initiator:
        s = LinkSession.State(initiatorTo: Identity(), destinationHash: Data(repeating: 0x01, count: 16),
                              interfaceID: InterfaceID("i"))
    case .responder:
        s = LinkSession.State(responderFor: Identity(), destinationHash: Data(repeating: 0x01, count: 16),
                              interfaceID: InterfaceID("i"))
    }
    s.status = .active
    s.sessionKey = sampleKey
    s.linkID = sampleLinkID
    return s
}

private func linkPacket(context: PacketContext, payload: Data) -> Data {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: context, contextFlag: false, hops: 0,
                   destinationHash: sampleLinkID, transportId: nil, payload: payload)
    return try! p.packed()
}

@Test @MainActor func activeLinkSendEmitsEncryptedDataPacket() async {
    let store = TestStore(initialState: activeState(role: .initiator)) { LinkSession() }
        withDependencies: { $0.date = .constant(epoch) }
    store.exhaustivity = .off
    let plaintext = Data("hello link".utf8)
    await store.send(.send(plaintext))
    let raw = await captureTransmit(store)
    let packet = Packet(raw: raw)!
    #expect(packet.packetType == .data)
    #expect(packet.context == .none)
    #expect(packet.destinationHash == sampleLinkID)
    #expect(Link.decrypt(packet.payload, sessionKey: sampleKey) == plaintext)
}

@Test @MainActor func activeLinkReceivesDataAndBubblesDataReceived() async {
    let store = TestStore(initialState: activeState(role: .responder)) { LinkSession() }
        withDependencies: { $0.date = .constant(epoch) }
    store.exhaustivity = .off
    let plaintext = Data("inbound".utf8)
    let cipher = Link.encrypt(plaintext, sessionKey: sampleKey)
    let captured = LockIsolated<Data?>(nil)
    await store.send(.received(linkPacket(context: .none, payload: cipher)))
    await store.receive { action in
        if case let .delegate(.dataReceived(p)) = action { captured.setValue(p); return true }
        return false
    }
    #expect(captured.value == plaintext)
    #expect(store.state.status == .active)
}

@Test @MainActor func corruptInboundDataIsIgnoredAndLinkStaysActive() async {
    // Exhaustive: an unexpected .dataReceived (or any effect) would fail the test at deinit,
    // so this asserts the corrupt packet is dropped silently — no teardown, no dataReceived.
    let store = TestStore(initialState: activeState(role: .responder)) { LinkSession() }
        withDependencies: { $0.date = .constant(epoch) }
    await store.send(.received(linkPacket(context: .none, payload: Data(repeating: 0xFF, count: 80))))
    #expect(store.state.status == .active)   // no teardown, no dataReceived
}

@Test @MainActor func initiatorCloseEmitsLinkCloseAndGoesClosed() async {
    let store = TestStore(initialState: activeState(role: .initiator)) { LinkSession() }
        withDependencies: { $0.date = .constant(epoch) }
    store.exhaustivity = .off
    await store.send(.close)
    #expect(store.state.status == .closed)
    let raw = await captureTransmit(store)
    let packet = Packet(raw: raw)!
    #expect(packet.context == .linkClose)
    #expect(packet.destinationHash == sampleLinkID)
    #expect(Link.decrypt(packet.payload, sessionKey: sampleKey) == sampleLinkID)  // payload = encrypt(link_id)
    await store.receive(.delegate(.closed(.initiatorClosed)))
}

@Test @MainActor func responderReceivesLinkCloseAndGoesClosed() async {
    let store = TestStore(initialState: activeState(role: .responder)) { LinkSession() }
        withDependencies: { $0.date = .constant(epoch) }
    store.exhaustivity = .off
    let closeCipher = Link.encrypt(sampleLinkID, sessionKey: sampleKey)
    await store.send(.received(linkPacket(context: .linkClose, payload: closeCipher)))
    #expect(store.state.status == .closed)
    await store.receive(.delegate(.closed(.initiatorClosed)))  // responder observing peer close → initiatorClosed
}

@Test @MainActor func initiatorReceivesLinkCloseAndGetsDestinationClosed() async {
    let store = TestStore(initialState: activeState(role: .initiator)) { LinkSession() }
        withDependencies: { $0.date = .constant(epoch) }
    store.exhaustivity = .off
    let closeCipher = Link.encrypt(sampleLinkID, sessionKey: sampleKey)
    await store.send(.received(linkPacket(context: .linkClose, payload: closeCipher)))
    #expect(store.state.status == .closed)
    await store.receive(.delegate(.closed(.destinationClosed)))  // initiator observing peer close → destinationClosed
}

@Test @MainActor func acceptRequestRejectsWrongLengthRequest() async {
    // The tightened check accepts only 64 or 67 byte payloads (RNS-exact). 65 must be rejected.
    let owner = Identity()
    let store = TestStore(
        initialState: LinkSession.State(responderFor: owner, destinationHash: Data(repeating: 0x02, count: 16),
                                        interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch) }
    store.exhaustivity = .off
    let badRequest = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                            destinationType: .single, context: .none, contextFlag: false, hops: 0,
                            destinationHash: Data(repeating: 0x02, count: 16), transportId: nil,
                            payload: Data(repeating: 0x33, count: 65))
    await store.send(.acceptRequest(try! badRequest.packed()))
    #expect(store.state.status == .pending)   // rejected, no handshake
}

@Test @MainActor func establishedLinkExchangesDataThenCloses() async {
    let owner = Identity()
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

    // Establish (LINKREQUEST → LRPROOF → LRRTT).
    await initiator.send(.establish)
    let linkRequest = await captureTransmit(initiator)
    await responder.send(.acceptRequest(linkRequest))
    let proof = await captureTransmit(responder)
    await initiator.send(.received(proof))
    let rttPacket = await captureTransmit(initiator)
    await initiator.receive { if case .delegate(.established) = $0 { return true }; return false }
    await responder.send(.received(rttPacket))
    await responder.receive { if case .delegate(.established) = $0 { return true }; return false }
    #expect(initiator.state.status == .active)
    #expect(responder.state.status == .active)

    // Initiator → responder application data.
    let up = Data("ping".utf8)
    await initiator.send(.send(up))
    let dataToResp = await captureTransmit(initiator)
    let gotUp = LockIsolated<Data?>(nil)
    await responder.send(.received(dataToResp))
    await responder.receive { action in
        if case let .delegate(.dataReceived(p)) = action { gotUp.setValue(p); return true }
        return false
    }
    #expect(gotUp.value == up)

    // Responder → initiator application data.
    let down = Data("pong".utf8)
    await responder.send(.send(down))
    let dataToInit = await captureTransmit(responder)
    let gotDown = LockIsolated<Data?>(nil)
    await initiator.send(.received(dataToInit))
    await initiator.receive { action in
        if case let .delegate(.dataReceived(p)) = action { gotDown.setValue(p); return true }
        return false
    }
    #expect(gotDown.value == down)

    // Initiator closes; responder observes the close.
    await initiator.send(.close)
    let closePacket = await captureTransmit(initiator)
    await initiator.receive(.delegate(.closed(.initiatorClosed)))
    #expect(initiator.state.status == .closed)
    await responder.send(.received(closePacket))
    await responder.receive(.delegate(.closed(.initiatorClosed)))
    #expect(responder.state.status == .closed)
}
