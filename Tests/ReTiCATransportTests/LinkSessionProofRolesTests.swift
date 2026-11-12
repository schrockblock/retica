import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// Link-packet proofs in BOTH link roles, as RNS. A link's `sig_prv` is the owning destination's
// identity key on a responder (RNS/Link.py:303) and a fresh per-link Ed25519 key on an initiator
// (RNS/Link.py:316), whose public half travels in the LINKREQUEST (bytes 32..<64). `prove_packet`
// signs with `sig_prv` (Link.py:463-474, 1276-1277); `validate` checks `peer_sig_pub`
// (Link.py:1279-1283), loaded from the destination identity on an initiator (Link.py:492) and from
// the link request on a responder (Link.py:411-416).

private let epoch = Date(timeIntervalSince1970: 0)

@MainActor
private func captureTransmit(_ store: TestStore<LinkSession.State, LinkSession.Action>) async throws -> Data {
    let captured = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }
    return try #require(captured.value)
}

@MainActor
private func makeStore(_ state: LinkSession.State, _ clock: TestClock<Duration>)
    -> TestStore<LinkSession.State, LinkSession.Action> {
    let store = TestStore(initialState: state) { LinkSession() } withDependencies: {
        $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

/// Two `LinkSession` stores taken through a REAL handshake (LINKREQUEST → LRPROOF → LRRTT), so the
/// responder learns the initiator's signing key only from the wire, exactly as in production.
@MainActor
private func activePair(_ clock: TestClock<Duration>)
    async throws -> (initiator:TestStore<LinkSession.State, LinkSession.Action>,
              responder: TestStore<LinkSession.State, LinkSession.Action>) {
    let owner = Identity()
    let destHash = Data(repeating: 0x77, count: 16)
    let initiator = makeStore(LinkSession.State(initiatorTo: Identity(publicKey: owner.publicKey)!,
                                                destinationHash: destHash, interfaceID: InterfaceID("a")), clock)
    let responder = makeStore(LinkSession.State(responderFor: owner, destinationHash: destHash,
                                                interfaceID: InterfaceID("b")), clock)
    await initiator.send(.establish)
    let linkRequest = try await captureTransmit(initiator)
    await responder.send(.acceptRequest(linkRequest))
    let lrProof = try await captureTransmit(responder)
    await initiator.send(.received(lrProof))
    let rtt = try await captureTransmit(initiator)
    await initiator.receive { if case .delegate(.established) = $0 { return true }; return false }
    await responder.send(.received(rtt))
    await responder.receive { if case .delegate(.established) = $0 { return true }; return false }
    #expect(initiator.state.status == .active)
    #expect(responder.state.status == .active)
    return (initiator, responder)
}

/// `sender` sends `data` with a receipt; `receiver` takes it in and surfaces its packet hash.
@MainActor
private func deliverWithReceipt(from sender: TestStore<LinkSession.State, LinkSession.Action>,
                                to receiver: TestStore<LinkSession.State, LinkSession.Action>,
                                data: Data, token: Data) async throws -> Data {
    await sender.send(.sendWithReceipt(data: data, token: token))
    let raw = try await captureTransmit(sender)
    let seen = LockIsolated<Data?>(nil)
    await receiver.send(.received(raw))
    await receiver.receive { action in
        if case let .delegate(.dataReceived(d, h)) = action, d == data { seen.setValue(h); return true }
        return false
    }
    #expect(seen.value == Packet(raw: raw)?.packetHash)
    return try #require(seen.value)
}

@MainActor
private func closeBoth(_ a: TestStore<LinkSession.State, LinkSession.Action>,
                       _ b: TestStore<LinkSession.State, LinkSession.Action>) async {
    await a.send(.close)
    await b.send(.close)
}

@Test @MainActor func initiatorProofOfAResponderPacketValidates() async throws {
    let clock = TestClock<Duration>()
    let (initiator, responder) = try await activePair(clock)
    let token = Data(repeating: 0x5A, count: 32)

    let h = try await deliverWithReceipt(from: responder, to: initiator, data: Data("down".utf8), token: token)
    await initiator.send(.provePacket(packetHash: h))
    let proof = try await captureTransmit(initiator)

    await responder.send(.received(proof))
    await responder.receive { action in
        if case let .delegate(.packetDelivered(t)) = action { return t == token }
        return false
    }
    #expect(responder.state.pendingDataReceipts[h] == nil)
    await closeBoth(initiator, responder)
}

@Test @MainActor func responderProofOfAnInitiatorPacketValidates() async throws {
    let clock = TestClock<Duration>()
    let (initiator, responder) = try await activePair(clock)
    let token = Data(repeating: 0xA5, count: 32)

    let h = try await deliverWithReceipt(from: initiator, to: responder, data: Data("up".utf8), token: token)
    await responder.send(.provePacket(packetHash: h))
    let proof = try await captureTransmit(responder)

    await initiator.send(.received(proof))
    await initiator.receive { action in
        if case let .delegate(.packetDelivered(t)) = action { return t == token }
        return false
    }
    #expect(initiator.state.pendingDataReceipts[h] == nil)
    await closeBoth(initiator, responder)
}

@Test @MainActor func aResponderRejectsAProofSignedByAnotherKey() async throws {
    let clock = TestClock<Duration>()
    let (initiator, responder) = try await activePair(clock)
    let token = Data(repeating: 0x3C, count: 32)

    let h = try await deliverWithReceipt(from: responder, to: initiator, data: Data("down".utf8), token: token)
    let forged = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                        destinationType: .link, context: .none, contextFlag: false, hops: 0,
                        destinationHash: responder.state.linkID, transportId: nil,
                        payload: h + Identity().sign(h))
    await responder.send(.received(try! forged.packed()))
    #expect(responder.state.pendingDataReceipts[h] == token)   // still pending: not delivered

    // The receipt runs out at its deadline instead: rtt * 6 + 11.25 s (`.sendWithReceipt`).
    let deadline = (responder.state.rtt ?? 0.5) * 6 + 11.25
    await clock.advance(by: .seconds(deadline))
    await responder.receive { action in
        if case let .delegate(.packetDeliveryFailed(t)) = action { return t == token }
        return false
    }
    #expect(responder.state.pendingDataReceipts[h] == nil)
    await closeBoth(initiator, responder)
}

@Test @MainActor func anInitiatorProofSignatureVerifiesUnderItsLinkRequestKey() async throws {
    let clock = TestClock<Duration>()
    let (initiator, responder) = try await activePair(clock)
    let initiatorEphemeral = initiator.state.ephemeral

    let h = try await deliverWithReceipt(from: responder, to: initiator, data: Data("down".utf8),
                                     token: Data(repeating: 0x01, count: 32))
    await initiator.send(.provePacket(packetHash: h))
    let proof = try #require(Packet(raw: try await captureTransmit(initiator)))

    #expect(proof.packetType == .proof)
    #expect(proof.context == PacketContext.none)
    #expect(proof.destinationHash == initiator.state.linkID)
    #expect(proof.payload.count == 96)
    #expect(Data(proof.payload.prefix(32)) == h)
    let signature = Data(proof.payload.suffix(64))
    #expect(Identity(publicKey: initiatorEphemeral.publicKey)!.validate(signature: signature, message: h))
    // The responder learned that same key from the LINKREQUEST, not from any side channel.
    #expect(responder.state.peerSigningPub == Data(initiatorEphemeral.publicKey.suffix(32)))
    await closeBoth(initiator, responder)
}

// F4: the signer comes from state, the link must be `.active`, and the signer must hold a private
// key — in either role. Exhaustive stores: any transmit at all fails teardown.
@Test @MainActor func aKeylessOrInactiveLinkProvesNothing() async {
    let clock = TestClock<Duration>()
    let h = Data(repeating: 0x44, count: 32)
    let keyed = Identity()
    let keyless = Identity(publicKey: Identity().publicKey)!
    #expect(keyless.privateKey == nil)

    func initiator(ephemeral: Identity, status: LinkSession.Status) -> LinkSession.State {
        var s = LinkSession.State(initiatorTo: Identity(), destinationHash: Data(repeating: 0x03, count: 16),
                                  interfaceID: InterfaceID("i"), ephemeral: ephemeral)
        s.status = status; s.linkID = Data(repeating: 0xBC, count: 16); s.sessionKey = Data(repeating: 2, count: 64)
        return s
    }
    func responder(owner: Identity, status: LinkSession.Status) -> LinkSession.State {
        var s = LinkSession.State(responderFor: owner, destinationHash: Data(repeating: 0x03, count: 16),
                                  interfaceID: InterfaceID("r"))
        s.status = status; s.linkID = Data(repeating: 0xBC, count: 16); s.sessionKey = Data(repeating: 2, count: 64)
        return s
    }

    for state in [initiator(ephemeral: keyed, status: .handshake),
                  initiator(ephemeral: keyed, status: .closed),
                  initiator(ephemeral: keyless, status: .active),
                  responder(owner: keyed, status: .handshake),
                  responder(owner: keyed, status: .closed),
                  responder(owner: keyless, status: .active)] {
        let store = makeStore(state, clock)
        store.exhaustivity = .on
        await store.send(.provePacket(packetHash: h))
    }
}
