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

private func testClock() -> TestClock<Duration> { TestClock() }

// A single initiator store driven to .active by feeding a proof crafted from `owner`'s identity.
// Timers (inactivity, and — after Task 2 — keepalive) are running; the caller must close the link
// (which cancels them) to end the test cleanly.
@MainActor
private func activeInitiatorStore(owner: Identity, clock: TestClock<Duration>)
    async -> TestStore<LinkSession.State, LinkSession.Action>
{
    let store = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: owner.publicKey)!,
                                        destinationHash: Data(repeating: 0x55, count: 16),
                                        interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing }
    store.exhaustivity = .off
    await store.send(.establish)
    _ = await captureTransmit(store)                                   // LINKREQUEST
    let proof = Link.buildProof(linkID: store.state.linkID, responderEphemeral: Identity(),
                                destinationIdentity: owner)             // signed by owner → initiator accepts
    let proofPacket = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                             destinationType: .link, context: .linkRequestProof, contextFlag: false,
                             hops: 0, destinationHash: store.state.linkID, transportId: nil, payload: proof)
    await store.send(.received(try! proofPacket.packed()))
    _ = await captureTransmit(store)                                   // LRRTT
    await store.receive { if case .delegate(.established) = $0 { return true }; return false }
    return store
}

// A single responder store driven to .active by feeding a crafted LRRTT (encrypted with the
// responder's own derived session key). The responder runs only the inactivity timer (no keepalive).
@MainActor
private func activeResponderStore(clock: TestClock<Duration>)
    async -> TestStore<LinkSession.State, LinkSession.Action>
{
    let owner = Identity()
    let initEph = Identity()
    let destHash = Data(repeating: 0x66, count: 16)
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: destHash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    let store = TestStore(
        initialState: LinkSession.State(responderFor: owner, destinationHash: destHash,
                                        interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing }
    store.exhaustivity = .off
    await store.send(.acceptRequest(try! request.packed()))
    _ = await captureTransmit(store)                                   // LRPROOF
    let rttCipher = Link.encrypt(MsgPack.encode(0.0), sessionKey: store.state.sessionKey)
    let rttPacket = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                           destinationType: .link, context: .linkRequestRTT, contextFlag: false, hops: 0,
                           destinationHash: store.state.linkID, transportId: nil, payload: rttCipher)
    await store.send(.received(try! rttPacket.packed()))
    await store.receive { if case .delegate(.established) = $0 { return true }; return false }
    return store
}

// As `activeResponderStore`, but the `date` dependency reads a mutable `seconds` box so a test can
// make distinct events land at distinct timestamps. `activeResponderStore` pins `.constant(epoch)`,
// under which every stamp is 0 — that cannot distinguish "stamped again with the same value" from
// "not stamped at all", so a clock-valued assertion built on it is blind in both directions.
@MainActor
private func advancingResponderStore(clock: TestClock<Duration>, seconds: LockIsolated<Double>)
    async -> TestStore<LinkSession.State, LinkSession.Action>
{
    let owner = Identity()
    let initEph = Identity()
    let destHash = Data(repeating: 0x66, count: 16)
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: destHash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    let store = TestStore(
        initialState: LinkSession.State(responderFor: owner, destinationHash: destHash,
                                        interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: {
        $0.date = .init { Date(timeIntervalSince1970: seconds.value) }
        $0.continuousClock = clock
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.acceptRequest(try! request.packed()))
    _ = await captureTransmit(store)                                   // LRPROOF
    let rttCipher = Link.encrypt(MsgPack.encode(0.0), sessionKey: store.state.sessionKey)
    let rttPacket = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                           destinationType: .link, context: .linkRequestRTT, contextFlag: false, hops: 0,
                           destinationHash: store.state.linkID, transportId: nil, payload: rttCipher)
    await store.send(.received(try! rttPacket.packed()))
    await store.receive { if case .delegate(.established) = $0 { return true }; return false }
    return store
}

@Test @MainActor func initiatorEstablishEmitsLinkRequestAndGoesPending() async {
    let clock = testClock()
    let dest = Identity()
    let destHash = Data(repeating: 0x55, count: 16)
    let store = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: dest.publicKey)!,
                                        destinationHash: destHash, interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing }
    store.exhaustivity = .off

    await store.send(.establish)
    let raw = await captureTransmit(store)
    let packet = Packet(raw: raw)!
    #expect(packet.packetType == .linkRequest)
    #expect(packet.destinationHash == destHash)
    #expect(packet.payload.count == 67)                          // ephemeral pub (64) + signalling (3)
    #expect(store.state.status == .pending)
    #expect(store.state.linkID == Link.linkID(requestPacket: packet))
    await clock.advance(by: .seconds(store.state.establishmentTimeout))
    await store.receive(.establishmentDeadline)
    // Initiators emit .establishmentFailed so LinkPlane routes the timeout to linkFailed(destinationHash:),
    // giving the delivery layer a destination-keyed signal it can act on.
    await store.receive(.delegate(.establishmentFailed(.timedOut))) { $0.status = .closed }
}

@Test @MainActor func responderAcceptRequestEmitsProofAndGoesHandshake() async {
    let clock = testClock()
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
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing }
    store.exhaustivity = .off

    await store.send(.acceptRequest(requestRaw))
    let raw = await captureTransmit(store)
    let packet = Packet(raw: raw)!
    #expect(packet.packetType == .proof)
    #expect(packet.context == .linkRequestProof)
    #expect(packet.destinationHash == Link.linkID(requestPacket: request))
    #expect(store.state.status == .handshake)
    #expect(store.state.sessionKey.count == 64)
    await clock.advance(by: .seconds(store.state.establishmentTimeout))
    await store.receive(.establishmentDeadline)
    // Responders deliberately keep .closed(.timedOut) — not .establishmentFailed. The role gate in
    // LinkSession.establishmentDeadline is intentional: a responder's destinationHash is our OWN
    // served destination, so linkFailed for it carries no reachability information — a timeout here
    // says only that an inbound handshake stalled.
    //
    // Not a claim that responders never emit .establishmentFailed: they already do on a malformed
    // handshake (LinkSession.swift:235, :285), and those are benign. The narrower point is that the
    // timeout path should not add another such instance for no gain.
    await store.receive(.delegate(.closed(.timedOut))) { $0.status = .closed }
}

/// F12: an invalid LRPROOF is UNAUTHENTICATED input — linkID is cleartext and link packets
/// bypass Transport's dedup, so anyone can inject one. The element must survive when a
/// wrongly-signed proof arrives (old contract: it was reaped and the establishment ended).
///
/// Renamed from `initiatorRejectsTamperedProof`. That name encoded the old behaviour: the branch
/// REJECTED the proof by emitting `.establishmentFailed(.handshakeRejected)` and reaping the
/// element. The new contract is IGNORE — the branch returns `.none` and the element stays alive
/// so the real proof can still establish the link.
///
/// Mutation-catching: after the tampered proof, exhaustivity is flipped to `.on`. With the old
/// code, `.handshakeRejected` queues as a received action; `store.receive(.establishmentDeadline)`
/// then finds `.handshakeRejected` as the first action and fails. Under the correct (`.none`)
/// implementation, no action is queued and the deadline is the first action received.
@Test @MainActor func initiatorIgnoresTamperedProofElementSurvives() async {
    let clock = testClock()
    let dest = Identity()
    let store = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: dest.publicKey)!,
                                        destinationHash: Data(repeating: 0x55, count: 16),
                                        interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing }
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
    // No delegate action — the element is not reaped, still pending.
    #expect(store.state.status == .pending)
    // Flip to .on so that if a stray .handshakeRejected was queued, receive(.establishmentDeadline)
    // finds it as the first action and fails the test (mutation catcher).
    store.exhaustivity = .on
    await clock.advance(by: .seconds(store.state.establishmentTimeout))
    // .establishmentDeadline sets status=.closed and emits .establishmentFailed(.timedOut).
    await store.receive(.establishmentDeadline) { $0.status = .closed }
    await store.receive(.delegate(.establishmentFailed(.timedOut)))
}

/// F12, second half — the MISLABEL. After an injected proof (degenerate session-key variant),
/// the element must fail as PATH-shaped (.timedOut → .establishmentTimedOut), not PEER-shaped
/// (.handshakeRejected → link-retry).
///
/// Renamed from `initiatorEmptySessionKeyReportsHandshakeRejectedNotTimeout`. The old name
/// asserted `.handshakeRejected`; the new contract is the opposite: this guard now returns `.none`
/// and failure only arrives via `establishmentDeadline` as `.timedOut`. The name was exactly
/// backwards. The session-key guard is the second failure point inside the same branch
/// (`validateProof` is the first); both now return `.none`.
///
/// The drive: a degenerate-X25519 proof, correctly signed so `validateProof` succeeds, but whose
/// key causes `Link.sessionKey` to return empty. Preconditions verify both properties hold.
///
/// Mutation-catching: exhaustivity is flipped to `.on` after the degenerate proof is sent.
/// With the old (mutation-b) code, `.handshakeRejected` queues as a received action before the
/// clock advance; `store.receive(.establishmentDeadline)` finds `.handshakeRejected` first
/// and fails. Under the correct implementation, no action queues and the test receives
/// `.establishmentDeadline` → `.timedOut`.
@Test @MainActor func initiatorEmptySessionKeyFailsAsTimedOutNotHandshakeRejected() async {
    let clock = testClock()
    let dest = Identity()
    let store = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: dest.publicKey)!,
                                        destinationHash: Data(repeating: 0x55, count: 16),
                                        interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing }
    store.exhaustivity = .off

    await store.send(.establish)
    _ = await captureTransmit(store)
    let linkID = store.state.linkID

    // Hand-build the proof rather than using Link.buildProof, so the embedded X25519 key can be
    // the degenerate all-zeros point while the signature over it stays valid.
    let degeneratePub = Data(repeating: 0, count: Link.publicKeyHalf)
    let destEd25519Pub = Data(dest.publicKey.suffix(Link.publicKeyHalf))
    let signedData = linkID + degeneratePub + destEd25519Pub + Link.signallingBytes
    let proof = dest.sign(signedData) + degeneratePub + Link.signallingBytes

    // Precondition: the proof really does validate. If this ever returns nil the test would be
    // re-testing the tampered-proof path instead of the empty-key path.
    #expect(Link.validateProof(proofData: proof, linkID: linkID, destinationIdentity: dest) != nil,
            "proof must validate — otherwise this test no longer reaches the session-key guard")
    // Precondition: derivation really does fail, which is what makes the guard fire.
    #expect(Link.sessionKey(ephemeralPrivateX25519: Data((store.state.ephemeral.privateKey ?? Data()).prefix(32)),
                            peerPublicX25519: degeneratePub, linkID: linkID).isEmpty,
            "session key must be empty — otherwise the link would establish")

    let proofPacket = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                             destinationType: .link, context: .linkRequestProof, contextFlag: false,
                             hops: 0, destinationHash: linkID, transportId: nil, payload: proof)
    await store.send(.received(try! proofPacket.packed()))
    // The branch returns .none — no delegate action, no transition.
    #expect(store.state.status == .pending)
    #expect(store.state.sessionKey.isEmpty)                      // no key was adopted

    // Flip to .on: if the old code queued .handshakeRejected, receive(.establishmentDeadline)
    // finds it first and fails (mutation-b catcher).
    store.exhaustivity = .on
    // Failure arrives PATH-shaped via the establishment deadline, not PEER-shaped immediately.
    await clock.advance(by: .seconds(store.state.establishmentTimeout))
    // .establishmentDeadline sets status=.closed and emits .establishmentFailed(.timedOut).
    await store.receive(.establishmentDeadline) { $0.status = .closed }
    await store.receive(.delegate(.establishmentFailed(.timedOut)))
}

/// F12: an invalid LRPROOF is UNAUTHENTICATED input — linkID is cleartext and link packets
/// bypass Transport's dedup, so anyone can inject one. Reaping here let a single packet kill
/// our own outbound establishment. The element must survive and still establish when the real
/// proof arrives.
///
/// Mutation coverage is provided by `initiatorIgnoresTamperedProofElementSurvives` (mutation-a)
/// and `initiatorEmptySessionKeyFailsAsTimedOutNotHandshakeRejected` (mutation-b), both of which
/// flip exhaustivity to `.on` at the critical point. This test focuses on the survival-then-
/// establish flow end-to-end.
@Test @MainActor func garbageLinkProofDoesNotReapTheInitiatorElement() async {
    let clock = testClock()
    let dest = Identity()
    let destHash = Data(repeating: 0x91, count: 16)
    let store = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: dest.publicKey)!,
                                        destinationHash: destHash, interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: {
        $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.establish)
    _ = await captureTransmit(store)                                   // LINKREQUEST
    #expect(store.state.status == .pending)

    // Inject a bogus proof at the (publicly derivable) linkID.
    let garbage = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                         destinationType: .link, context: .linkRequestProof, contextFlag: false,
                         hops: 0, destinationHash: store.state.linkID, transportId: nil,
                         payload: Data(repeating: 0x00, count: 99))
    await store.send(.received(try! garbage.packed()))

    // Not reaped, still pending.
    #expect(store.state.status == .pending)

    // The genuine proof still establishes the link.
    let proof = Link.buildProof(linkID: store.state.linkID,
                                responderEphemeral: Identity(),
                                destinationIdentity: dest)
    let proofPacket = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                             destinationType: .link, context: .linkRequestProof, contextFlag: false,
                             hops: 0, destinationHash: store.state.linkID, transportId: nil,
                             payload: proof)
    await store.send(.received(try! proofPacket.packed()))
    _ = await captureTransmit(store)                                   // LRRTT
    await store.receive { if case .delegate(.established) = $0 { return true }; return false }
    #expect(store.state.status == .active)
}

/// F12, second half — the MISLABEL. After an injected proof, the establishment must fail as
/// PATH-shaped (.timedOut → .establishmentTimedOut), not PEER-shaped (.handshakeRejected).
/// LXMFNode answers .handshakeRejected by retrying the link instead of requesting a path, so a
/// mislabel here burns the whole delivery budget against a route that works. This is the
/// expensive half of F12 and needs its own test — a survival assertion would not catch it.
///
/// Mutation-catching: exhaustivity is flipped to `.on` after the garbage proof is sent.
/// With the old code, `.handshakeRejected` queues as a received action before the clock advance;
/// `store.receive(.establishmentDeadline)` finds `.handshakeRejected` as the first action and fails.
@Test @MainActor func garbageLinkProofFailsAsPathShapedNotPeerShaped() async {
    let clock = testClock()
    let dest = Identity()
    let destHash = Data(repeating: 0x92, count: 16)
    let store = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: dest.publicKey)!,
                                        destinationHash: destHash, interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: {
        $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.establish)
    _ = await captureTransmit(store)
    let garbage = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                         destinationType: .link, context: .linkRequestProof, contextFlag: false,
                         hops: 0, destinationHash: store.state.linkID, transportId: nil,
                         payload: Data(repeating: 0x00, count: 99))
    await store.send(.received(try! garbage.packed()))

    // Flip to .on: if the old code queued .handshakeRejected, receive(.establishmentDeadline)
    // finds it first and fails (mutation catcher for the path-shape / peer-shape distinction).
    store.exhaustivity = .on
    await clock.advance(by: .seconds(store.state.establishmentTimeout))
    // .establishmentDeadline sets status=.closed and emits .establishmentFailed(.timedOut).
    await store.receive(.establishmentDeadline) { $0.status = .closed }
    await store.receive(.delegate(.establishmentFailed(.timedOut)))
}

@Test @MainActor func initiatorAndResponderReachActiveWithEqualSessionKey() async {
    let clock = testClock()
    let owner = Identity()                                  // responder owns this destination identity
    let destHash = Data(repeating: 0x77, count: 16)

    let initiator = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: owner.publicKey)!,
                                        destinationHash: destHash, interfaceID: InterfaceID("a"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing }
    initiator.exhaustivity = .off

    let responder = TestStore(
        initialState: LinkSession.State(responderFor: owner, destinationHash: destHash,
                                        interfaceID: InterfaceID("b"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing }
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

    await initiator.send(.close)
    _ = await captureTransmit(initiator)
    await initiator.receive(.delegate(.closed(.initiatorClosed))) { $0.status = .closed }
    await responder.send(.close)
    _ = await captureTransmit(responder)
    await responder.receive(.delegate(.closed(.destinationClosed))) { $0.status = .closed }
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
        withDependencies: { $0.date = .constant(epoch); $0.continuousClock = testClock(); $0.uuid = .incrementing }
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
        withDependencies: { $0.date = .constant(epoch); $0.continuousClock = testClock(); $0.uuid = .incrementing }
    store.exhaustivity = .off
    let plaintext = Data("inbound".utf8)
    let cipher = Link.encrypt(plaintext, sessionKey: sampleKey)
    let captured = LockIsolated<Data?>(nil)
    await store.send(.received(linkPacket(context: .none, payload: cipher)))
    await store.receive { action in
        if case let .delegate(.dataReceived(p, _)) = action { captured.setValue(p); return true }
        return false
    }
    #expect(captured.value == plaintext)
    #expect(store.state.status == .active)
}

@Test @MainActor func corruptInboundDataIsIgnoredAndLinkStaysActive() async {
    // A corrupt (undecryptable) DATA packet must not surface .dataReceived or tear the link
    // down. Per RNS/Link.py:935, last_inbound IS stamped before the decryption attempt, so
    // the inactivity timer IS re-armed — the corrupt send must run under .off to absorb that
    // persistent timer effect, which an exhaustive store rejects at teardown.
    let clock = testClock()
    let store = TestStore(initialState: activeState(role: .responder)) { LinkSession() }
        withDependencies: { $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing }
    store.exhaustivity = .off
    await store.send(.received(linkPacket(context: .none, payload: Data(repeating: 0xFF, count: 80))))
    #expect(store.state.status == .active)   // no teardown
    // "no .dataReceived" is the other half of the claim, and .off alone will NOT prove it:
    // send() under .off(showSkippedAssertions: false) clears `receivedActions`
    // (TestStore.swift:921-928), so a stray .dataReceived would vanish silently. Flip to .on
    // BEFORE the close — the close cancels the inactivity timer, so nothing is left in flight
    // and teardown is free to catch the stray.
    store.exhaustivity = .on
    await store.send(.close) { $0.status = .closed }
    _ = await captureTransmit(store)
    await store.receive(.delegate(.closed(.destinationClosed)))
}

@Test @MainActor func initiatorCloseEmitsLinkCloseAndGoesClosed() async {
    let store = TestStore(initialState: activeState(role: .initiator)) { LinkSession() }
        withDependencies: { $0.date = .constant(epoch); $0.continuousClock = testClock(); $0.uuid = .incrementing }
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
        withDependencies: { $0.date = .constant(epoch); $0.continuousClock = testClock(); $0.uuid = .incrementing }
    store.exhaustivity = .off
    let closeCipher = Link.encrypt(sampleLinkID, sessionKey: sampleKey)
    await store.send(.received(linkPacket(context: .linkClose, payload: closeCipher)))
    #expect(store.state.status == .closed)
    await store.receive(.delegate(.closed(.initiatorClosed)))  // responder observing peer close → initiatorClosed
}

@Test @MainActor func initiatorReceivesLinkCloseAndGetsDestinationClosed() async {
    let store = TestStore(initialState: activeState(role: .initiator)) { LinkSession() }
        withDependencies: { $0.date = .constant(epoch); $0.continuousClock = testClock(); $0.uuid = .incrementing }
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
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch); $0.continuousClock = testClock(); $0.uuid = .incrementing }
    store.exhaustivity = .off
    let badRequest = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                            destinationType: .single, context: .none, contextFlag: false, hops: 0,
                            destinationHash: Data(repeating: 0x02, count: 16), transportId: nil,
                            payload: Data(repeating: 0x33, count: 65))
    await store.send(.acceptRequest(try! badRequest.packed()))
    #expect(store.state.status == .pending)   // rejected, no handshake
}

@Test @MainActor func establishedLinkExchangesDataThenCloses() async {
    let clock = testClock()
    let owner = Identity()
    let destHash = Data(repeating: 0x77, count: 16)

    let initiator = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: owner.publicKey)!,
                                        destinationHash: destHash, interfaceID: InterfaceID("a"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing }
    initiator.exhaustivity = .off

    let responder = TestStore(
        initialState: LinkSession.State(responderFor: owner, destinationHash: destHash,
                                        interfaceID: InterfaceID("b"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing }
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
        if case let .delegate(.dataReceived(p, _)) = action { gotUp.setValue(p); return true }
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
        if case let .delegate(.dataReceived(p, _)) = action { gotDown.setValue(p); return true }
        return false
    }
    #expect(gotDown.value == down)

    // Initiator closes; responder observes the close.
    await initiator.send(.close)
    let closePacket = await captureTransmit(initiator)
    await initiator.receive(.delegate(.closed(.initiatorClosed))) { $0.status = .closed }
    #expect(initiator.state.status == .closed)
    await responder.send(.received(closePacket))
    await responder.receive(.delegate(.closed(.initiatorClosed))) { $0.status = .closed }
    #expect(responder.state.status == .closed)
}

// MARK: - New timer tests

@Test @MainActor func establishmentTimesOutWhenNoProofArrives() async {
    let clock = TestClock()
    let store = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: Identity().publicKey)!,
                                        destinationHash: Data(repeating: 0x55, count: 16),
                                        interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: {
        $0.date = .constant(epoch)
        $0.continuousClock = clock
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.establish)
    _ = await captureTransmit(store)                  // the LINKREQUEST
    await clock.advance(by: .seconds(store.state.establishmentTimeout))
    await store.receive(.establishmentDeadline)
    // Initiators emit .establishmentFailed so the delivery layer receives a destination-keyed signal.
    await store.receive(.delegate(.establishmentFailed(.timedOut)))
    #expect(store.state.status == .closed)
}

@Test @MainActor func establishmentTimerIsCancelledOnceActive() async {
    // Reach .active, then advance past establishmentTimeout — the establishment timer was
    // cancelled at .active, so no establishment deadline fires. The keepalive loop runs at the
    // RTT-derived cadence (5 s for this store's measured rtt of 0), which is now SHORTER than
    // establishmentTimeout, so its ticks are drained below: they prove the link is alive, and
    // draining them is what makes "no establishment deadline" observable rather than merely
    // skipped by non-exhaustive receiving.
    let clock = TestClock()
    let store = await activeInitiatorStore(owner: Identity(), clock: clock)
    #expect(store.state.status == .active)
    let cadence = store.state.effectiveKeepalive
    #expect(cadence < store.state.establishmentTimeout)
    await clock.advance(by: .seconds(store.state.establishmentTimeout))
    for _ in 0..<Int(store.state.establishmentTimeout / cadence) {
        await store.receive(.keepaliveDeadline)
        _ = await captureTransmit(store)
    }
    #expect(store.state.status == .active)
    // Clean up the running inactivity/keepalive timers.
    await store.send(.close); _ = await captureTransmit(store)
    await store.receive(.delegate(.closed(.initiatorClosed)))
}

@Test @MainActor func silentActiveLinkTimesOutAfterStaleTime() async {
    // A responder (no keepalive timer of its own) that hears nothing for staleTime tears down.
    let clock = TestClock()
    let store = await activeResponderStore(clock: clock)
    #expect(store.state.status == .active)
    await clock.advance(by: .seconds(store.state.staleTime))
    await store.receive(.inactivityDeadline)
    let close = await captureTransmit(store)                 // LINKCLOSE teardown
    await store.receive(.delegate(.closed(.timedOut)))
    #expect(store.state.status == .closed)
    #expect(Packet(raw: close)!.context == .linkClose)
}

// The inactivity watchdog measures INBOUND silence, so nothing we do locally may disarm it —
// least of all sending data, which is exactly when a hung peer most needs detecting.
//
// This is a regression probe for an eager `Effect.cancel` binding. `.cancel(id:)` performs its
// cancellation at CONSTRUCTION (see the comment on `cancelAll()` in LinkSession.swift), so while
// `cancelAll` was bound as a `let` at the top of the reducer it tore down the inactivity timer on
// EVERY action — here, on the `.delegate(.transmit)` echo of our own `.send` — and the link then
// never timed out at all. The hoisted re-arm in `.received` hides this from any inbound-driven
// test, because inbound packets rebuild the timer they just destroyed; an OUTBOUND action is the
// cheapest way to observe a cancel with no re-arm behind it.
@Test @MainActor func outboundSendDoesNotDisarmTheInactivityTimer() async {
    let clock = TestClock()
    let store = await activeResponderStore(clock: clock)
    await store.send(.send(Data("payload".utf8)))
    _ = await captureTransmit(store)
    await clock.advance(by: .seconds(store.state.staleTime))
    await store.receive(.inactivityDeadline)
    _ = await captureTransmit(store)                          // LINKCLOSE teardown
    await store.receive(.delegate(.closed(.timedOut)))
    #expect(store.state.status == .closed)
}

// The same regression probe on the ESTABLISHMENT timer, where the consequence is worse: a hung
// handshake that never fires its deadline never reaches .closed, and `LinkPlane` only reaps
// elements on a delegate — so the session leaks and `routeLinkPacket` linear-scans it forever.
// The stray packet is addressed to a DIFFERENT link, so it takes the earliest possible exit from
// `.received`; if merely REACHING the reducer can cancel a timer, this is the cheapest proof.
@Test @MainActor func strayPacketDoesNotDisarmTheEstablishmentTimer() async {
    let clock = TestClock()
    let store = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: Identity().publicKey)!,
                                        destinationHash: Data(repeating: 0x55, count: 16),
                                        interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: {
        $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.establish)
    _ = await captureTransmit(store)                          // the LINKREQUEST
    let stray = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                       destinationType: .link, context: .none, contextFlag: false, hops: 0,
                       destinationHash: Data(repeating: 0x11, count: 16), transportId: nil,
                       payload: Data([0x00]))
    await store.send(.received(try! stray.packed()))          // not our link → ignored
    await clock.advance(by: .seconds(store.state.establishmentTimeout))
    await store.receive(.establishmentDeadline)
    await store.receive(.delegate(.establishmentFailed(.timedOut)))
    #expect(store.state.status == .closed)
}

@Test @MainActor func activeInitiatorEmitsKeepaliveEveryInterval() async {
    // THREE consecutive intervals, not one. The keepalive effect is a `while true` loop, and a
    // single tick fires even when the loop is torn down by the very `.keepaliveDeadline` it just
    // emitted — which is precisely what the eager `cancelAll` binding did (see the comment on
    // `cancelAll()` in LinkSession.swift). Only repetition proves the loop survives its own output.
    let clock = TestClock()
    let store = await activeInitiatorStore(owner: Identity(), clock: clock)   // arms the keepalive loop
    // The cadence the loop was actually armed with — RTT-derived, not the configured interval.
    let interval = store.state.effectiveKeepalive
    let linkID = store.state.linkID

    for _ in 0..<3 {
        await clock.advance(by: .seconds(interval))
        await store.receive(.keepaliveDeadline)
        let ka = await captureTransmit(store)
        let packet = Packet(raw: ka)!
        #expect(packet.context == .keepalive)
        #expect(packet.payload == Data([0xFF]))                    // unencrypted sentinel
        #expect(packet.destinationHash == linkID)
        // A live peer answers 0xFE (RNS/Link.py:1125). Feeding the reply back exercises the
        // inbound path that resets the INITIATOR's own inactivity timer: an outbound keepalive
        // is not proof of life, only the reply is.
        let pong = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                          destinationType: .link, context: .keepalive, contextFlag: false, hops: 0,
                          destinationHash: linkID, transportId: nil, payload: Data([0xFE]))
        await store.send(.received(try! pong.packed()))
        #expect(store.state.status == .active)
    }

    // Clean up (cancels the keepalive + inactivity timers).
    await store.send(.close); _ = await captureTransmit(store)
    await store.receive(.delegate(.closed(.initiatorClosed)))
}

/// Reference RNS derives a link's keepalive cadence from its measured RTT, clamped to a 5 s
/// floor, and calls a link stale after twice that (RNS/Link.py:92-99, 795-797) — so **10 s is
/// the tightest stale window any conforming peer can have**, and only the initiator transmits
/// keepalives. An initiator whose first keepalive lands after that window never gets one in at
/// all: the peer tears the link down, both sides reconnect, and the link flaps forever. Observed
/// against a real RNS 1.5.2 sidecar as a link dropping every ~20 s while TCP stayed up.
@Test @MainActor func initiatorKeepaliveLandsInsideAnRNSPeerStaleWindow() async {
    let clock = TestClock()
    // This store measured its RTT locally during the handshake under a constant clock, so
    // `rtt` is 0 — the same clamp-to-the-floor case a real fast link produces.
    let store = await activeInitiatorStore(owner: Identity(), clock: clock)
    #expect(store.state.rtt == 0)

    // Advance to just inside the tightest window a conforming peer can have. The first
    // keepalive must already be on the wire by then.
    await clock.advance(by: .seconds(9))
    await store.receive(.keepaliveDeadline)
    let ka = await captureTransmit(store)
    #expect(Packet(raw: ka)!.context == .keepalive)
    #expect(Packet(raw: ka)!.payload == Data([0xFF]))
    #expect(store.state.status == .active)

    await store.send(.close); _ = await captureTransmit(store)
    await store.receive(.delegate(.closed(.initiatorClosed)))
}

/// The other half of the derivation. Coupling `staleTime` to the configured interval alone would
/// let a slow link reap itself between two of its own keepalives; coupling it to the derived
/// cadence alone would drop the 60 s tolerance fast links have always had. Both halves are
/// load-bearing, and neither is observable from a store driven at rtt 0.
@Test @MainActor func keepaliveCadenceAndStaleTimeFollowMeasuredRTT() {
    func state(rtt: Double?) -> LinkSession.State {
        var s = LinkSession.State(initiatorTo: Identity(publicKey: Identity().publicKey)!,
                                  destinationHash: Data(repeating: 0x55, count: 16),
                                  interfaceID: InterfaceID("i"))
        s.rtt = rtt
        return s
    }

    // Before the handshake measures anything: the configured interval, exactly as before.
    #expect(state(rtt: nil).effectiveKeepalive == 30)
    #expect(state(rtt: nil).staleTime == 60)

    // A fast link clamps to RNS's 5 s floor, so its first keepalive lands inside the 10 s stale
    // window any conforming peer derives from the same RTT — while tolerance keeps its 60 s floor.
    #expect(state(rtt: 0).effectiveKeepalive == LinkSession.keepaliveMin)
    #expect(state(rtt: 0).staleTime == 60)

    // A slow link scales the cadence with RTT, and scales tolerance with it so the link is never
    // reaped between two of its own keepalives.
    let slow = state(rtt: 1.0)
    #expect(slow.effectiveKeepalive == LinkSession.keepaliveMaxRTTRatio)
    #expect(slow.staleTime == slow.effectiveKeepalive * 2)

    // And the cadence is clamped at the ceiling however large RTT gets.
    #expect(state(rtt: 100).effectiveKeepalive == LinkSession.keepaliveMax)
}

@Test @MainActor func responderRepliesToKeepaliveWith0xFE() async {
    var s = LinkSession.State(responderFor: Identity(), destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"))
    s.status = .active
    s.sessionKey = Data(repeating: 0x01, count: 64)
    s.linkID = Data(repeating: 0xAB, count: 16)
    let clock = TestClock()
    let store = TestStore(initialState: s) { LinkSession() }
        withDependencies: { $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing }
    store.exhaustivity = .off

    // Inbound 0xFF keepalive → 0xFE reply.
    let ka = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                    destinationType: .link, context: .keepalive, contextFlag: false, hops: 0,
                    destinationHash: s.linkID, transportId: nil, payload: Data([0xFF]))
    await store.send(.received(try! ka.packed()))
    let reply = await captureTransmit(store)
    let packet = Packet(raw: reply)!
    #expect(packet.context == .keepalive)
    #expect(packet.payload == Data([0xFE]))

    await store.send(.close); _ = await captureTransmit(store)
    await store.receive(.delegate(.closed(.destinationClosed)))
}

@Test @MainActor func keepaliveKeepsLinkAliveThenStarvedSideTimesOut() async {
    // Verifies the full watchdog lifecycle:
    //   (a) initiator sends 0xFF keepalives and stays .active while they flow;
    //   (b) a responder whose inactivity is periodically reset stays .active;
    //   (c) once pings stop, the responder's inactivity expires → .closed(.timedOut).
    //
    // This test deliberately covers only ONE initiator keepalive cycle and then pivots to the
    // responder's inactivity-reset mechanism, because its subject is the responder's teardown.
    // A previous version of this comment blamed a "TCA 1.26 limitation" for the single cycle,
    // claiming consecutive keepalives could not be captured from a `while true` loop effect.
    // That was wrong: the loop really was dying after one tick, because the eager `cancelAll`
    // binding cancelled it (see `cancelAll()` in LinkSession.swift). Repeated keepalives are
    // now asserted directly by activeInitiatorEmitsKeepaliveEveryInterval.

    let owner = Identity()
    let initiatorClock = TestClock()
    let initiator = await activeInitiatorStore(owner: owner, clock: initiatorClock)
    #expect(initiator.state.status == .active)

    // One keepalive fires → 0xFF emitted; initiator stays .active.
    await initiatorClock.advance(by: .seconds(initiator.state.effectiveKeepalive))
    let ping = await captureTransmit(initiator)
    let pingPacket = Packet(raw: ping)!
    #expect(pingPacket.context == .keepalive)
    #expect(pingPacket.payload == Data([0xFF]))
    #expect(initiator.state.status == .active)

    // Set up a responder with its own clock.
    let responderClock = TestClock()
    let responder = await activeResponderStore(clock: responderClock)
    #expect(responder.state.status == .active)

    // Two synthetic 0xFF deliveries to the responder:
    //   • Each resets its inactivity timer (via the .keepalive case in the reducer).
    //   • Responder replies 0xFE, proving the reset happened.
    //   • `staleTime` is 60 s here — the configured floor wins, because this link's derived
    //     5 s cadence is shorter — so a ping every 5 s keeps it from expiring.
    for _ in 0..<2 {
        let syntheticPing = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                                   destinationType: .link, context: .keepalive, contextFlag: false,
                                   hops: 0, destinationHash: responder.state.linkID, transportId: nil,
                                   payload: Data([0xFF]))
        await responder.send(.received(try! syntheticPing.packed()))
        let pong = await captureTransmit(responder)
        #expect(Packet(raw: pong)!.payload == Data([0xFE]))   // 0xFE confirms inactivity was reset
        #expect(responder.state.status == .active)
    }
    #expect(initiator.state.status == .active)
    #expect(responder.state.status == .active)

    // Stop pings: close the initiator so only the responder is left to starve.
    await initiator.send(.close); _ = await captureTransmit(initiator)
    await initiator.receive(.delegate(.closed(.initiatorClosed)))

    // Advance responder's clock past staleTime — no new pings → inactivity deadline fires
    // → LINKCLOSE emitted → .closed(.timedOut).
    await responderClock.advance(by: .seconds(responder.state.staleTime))
    await responder.receive(.inactivityDeadline)
    _ = await captureTransmit(responder)
    await responder.receive(.delegate(.closed(.timedOut)))
    #expect(responder.state.status == .closed)
}

// MARK: - Inactivity timer: any inbound packet re-arms

// An active link carrying only DATA (no keepalives) must NOT time out. Reference peers
// suppress keepalives while traffic flows (RNS/Link.py:749, :1125), so inbound data is the
// only proof of life available during a transfer.
//
// This probes the timer directly and therefore BITES both halves of the claim. A RESPONDER is
// used deliberately: it arms no keepalive loop of its own, so the inactivity timer is the only
// thing consuming the clock and every observation is unambiguous. `staleTime` is 60 s — the
// configured 30 s floor wins over this link's RTT-derived 5 s cadence — and every advance below
// is derived from that and nothing else:
//
//   t=59  (staleTime - 1)  DATA #1, comfortably inside the original t=60 deadline → re-arm to 119.
//   t=61  (+2)             past the ORIGINAL deadline. DATA #2 is sent here under EXHAUSTIVE
//                          exhaustivity, which is the actual probe: if the deadline had NOT moved,
//                          the t=60 teardown is sitting unhandled in `receivedActions` and
//                          `send` fails with "Must handle 3 received actions before sending an
//                          action". Re-arms to 121.
//   t=122 (+staleTime+1)   past the RE-ARMED deadline → `.inactivityDeadline` must arrive. This is
//                          the half that proves the re-arm produced a LIVE timer rather than one
//                          that something else immediately cancelled.
//
// Do NOT replace the exhaustivity probe with `#expect(store.state.status == .active)` after the
// advance. Measured: `TestStore` does not fold an effect-emitted action into `store.state` until
// something drains it, so immediately after `clock.advance(by: staleTime + 1)` on an untouched
// active link the status still reads `.active` even though the teardown is already queued. Any
// liveness assertion of that shape is vacuous.
@Test @MainActor func inboundDataKeepsLinkAlive() async {
    let clock = testClock()
    let store = await activeResponderStore(clock: clock)
    let stale = store.state.staleTime
    let key = store.state.sessionKey
    let linkID = store.state.linkID
    func dataPacket(_ body: String) -> Data {
        let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                       destinationType: .link, context: .none, contextFlag: false, hops: 0,
                       destinationHash: linkID, transportId: nil,
                       payload: Link.encrypt(Data(body.utf8), sessionKey: key))
        return try! p.packed()
    }

    // t = staleTime - 1 — inside the original deadline.
    await clock.advance(by: .seconds(stale - 1))
    await store.send(.received(dataPacket("one")))
    await store.receive { if case .delegate(.dataReceived) = $0 { return true }; return false }

    // t = staleTime + 1 — past the ORIGINAL deadline. Exhaustive from here: the next `send` is the
    // assertion that no teardown happened at t=60. (`lastInbound` is unchanged — the `date`
    // dependency is a constant — so neither `send` needs a state-mutation closure.)
    store.exhaustivity = .on
    await clock.advance(by: .seconds(2))
    await store.send(.received(dataPacket("two")))
    await store.receive { if case .delegate(.dataReceived) = $0 { return true }; return false }

    // t = 2*staleTime + 2 — past the RE-ARMED deadline. Now the timer must actually fire.
    await clock.advance(by: .seconds(stale + 1))
    await store.receive(.inactivityDeadline) { $0.status = .closed }
    let close = await captureTransmit(store)
    await store.receive(.delegate(.closed(.timedOut)))
    #expect(Packet(raw: close)!.context == .linkClose)
}

// MARK: - GC: close clears pending requests

@Test @MainActor func closeClearsPendingRequestsAndCancelsTheirTimers() async {
    let clock = TestClock<Duration>()
    // Build a pre-active store (same pattern as activeState(role:) above but with a real clock).
    var s = activeState(role: .initiator)
    s.rtt = 1.0   // sets timeout = 1*6 + 11.25 = 17.25 s
    let store = TestStore(initialState: s) { LinkSession() } withDependencies: {
        $0.date = .constant(epoch)
        $0.continuousClock = clock
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    // Send a small inline request — arms pendingRequests + a CancelID.request timer.
    await store.send(.sendRequest(path: "svc/x", data: Data([1, 2])))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.pendingRequests.isEmpty == false)
    let requestID = store.state.pendingRequests.first!
    // Close — emits LINKCLOSE transmit + .closed, and cancelPending cancels the request timer.
    await store.send(.close)
    #expect(store.state.pendingRequests.isEmpty == true)
    // Drain the transmit + closed delegate actions emitted by .close.
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    await store.receive { if case .delegate(.closed(.initiatorClosed)) = $0 { return true }; return false }
    _ = requestID   // captured above; used only to document what was pending before the close
    // Advance past the request timeout (rtt*6+11.25 = 17.25 s) under exhaustive mode: if a request
    // timer were still armed AND its .requestDeadline surfaced, this would fail on an unexpected
    // action. pendingRequests is already empty, so even a fired .requestDeadline is guard-dropped.
    store.exhaustivity = .on
    await clock.advance(by: .seconds(120))
    // NOTE (mutation coverage of cancelPending):
    //  • Dropping `removeAll()` is caught deterministically by the `pendingRequests.isEmpty` assertion
    //    above, in every environment.
    //  • Dropping ONLY the `.cancel(id:)` (keeping removeAll) is behaviorally inert through the
    //    reducer — the cleared set makes the leaked timer's .requestDeadline guard-drop to .none — so
    //    the only possible signal is the harness surfacing the leaked effect's action as *unexpected*
    //    under the exhaustive advance above. Whether it does is TCA-scheduler-dependent: it was
    //    observed to fail the run in final review, but did NOT reproduce in the controller's
    //    environment (the leaked action never surfaced there). Because there is no
    //    environment-independent behavioral discriminator (removeAll runs in both the correct and
    //    mutant paths), the `.cancel` is retained as correct resource hygiene rather than for
    //    test-observability; it prevents a genuinely leaked sleeping task in production.
}

// NOTE (TCA 1.26 choreography): TCA 1.26's receive-with-predicate takes a synchronous path
// (no waiting) when inFlightEffects is empty at the call site. Capturing two consecutive
// keepalive transmits from a `while true` loop effect is unreliable in this version because
// the effect's tracking momentarily drops between iterations. The test therefore verifies:
//   • ONE initiator keepalive fires correctly (sufficient to prove the loop works);
//   • The responder's inactivity IS reset by synthetic pings (proving .keepalive reset path);
//   • Starvation causes .closed(.timedOut) (the spec's key assertion).
// These are the same semantic assertions as the brief's original test.

// MARK: - HEADER_2 LINKREQUEST (via-relay)

@Test @MainActor func initiatorViaRelayBuildsHeader2LinkRequest() async {
    let clock = TestClock<Duration>()
    let relay = Data(repeating: 0x5A, count: 16)
    let s = LinkSession.State(initiatorTo: Identity(), destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"), relayNextHop: relay)
    let store = TestStore(initialState: s) { LinkSession() } withDependencies: {
        $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    let captured = LockIsolated<Data?>(nil)
    await store.send(.establish)
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }
    let p = Packet(raw: captured.value!)!
    #expect(p.headerType == .header2)
    #expect(p.transportType == .transport)
    #expect(p.transportId == relay)
    #expect(p.packetType == .linkRequest)
    // link_id is header-independent: the id LinkSession stored == Link.linkID of the packet.
    #expect(store.state.linkID == Link.linkID(requestPacket: p))
    await clock.advance(by: .seconds(store.state.establishmentTimeout))    // quiesce the establishment timer
}

/// F6: an RTT we cannot decrypt is UNAUTHENTICATED input — link packets route by cleartext
/// linkID ahead of Transport's dedup, so anyone can inject one. Reaping on it would let a
/// single injected packet silently kill a legitimate establishment. The element must survive
/// and still establish when the real RTT arrives.
@Test @MainActor func garbageRTTDoesNotReapTheResponderElement() async {
    let clock = testClock()
    let owner = Identity()
    let initEph = Identity()
    let destHash = Data(repeating: 0x77, count: 16)
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: destHash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    let store = TestStore(
        initialState: LinkSession.State(responderFor: owner, destinationHash: destHash,
                                        interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: {
        $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.acceptRequest(try! request.packed()))
    _ = await captureTransmit(store)                                   // LRPROOF
    #expect(store.state.status == .handshake)

    // Inject a garbage RTT at the (publicly derivable) linkID.
    let garbage = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                         destinationType: .link, context: .linkRequestRTT, contextFlag: false,
                         hops: 0, destinationHash: store.state.linkID, transportId: nil,
                         payload: Data(repeating: 0x00, count: 48))
    await store.send(.received(try! garbage.packed()))

    // The element must NOT have been reaped and must still be mid-handshake.
    #expect(store.state.status == .handshake)

    // The legitimate RTT still completes the handshake. Use .on exhaustivity for the
    // second send so that TCA's "must handle received actions before sending" check fires
    // if the garbage produced a spurious .establishmentFailed that is still unhandled.
    // (.off's store.send clears receivedActions, which would hide the spurious action.)
    let rttCipher = Link.encrypt(MsgPack.encode(0.0), sessionKey: store.state.sessionKey)
    let rttPacket = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                           destinationType: .link, context: .linkRequestRTT, contextFlag: false,
                           hops: 0, destinationHash: store.state.linkID, transportId: nil,
                           payload: rttCipher)
    store.exhaustivity = .on
    await store.send(.received(try! rttPacket.packed())) { $0.status = .active
        $0.rtt = 0.0; $0.activatedAt = 0.0; $0.lastInbound = 0.0; $0.lastData = 0.0
    }
    await store.receive { if case .delegate(.established) = $0 { return true }; return false }
    store.exhaustivity = .off
    #expect(store.state.status == .active)
}

@Test @MainActor func initiatorDirectBuildsHeader1LinkRequest() async {
    // relayNextHop == nil → HEADER_1 as before.
    let clock = TestClock<Duration>()
    let s = LinkSession.State(initiatorTo: Identity(), destinationHash: Data(repeating: 0x03, count: 16),
                              interfaceID: InterfaceID("i"), relayNextHop: nil)
    let store = TestStore(initialState: s) { LinkSession() } withDependencies: {
        $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    let captured = LockIsolated<Data?>(nil)
    await store.send(.establish)
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }
    let p = Packet(raw: captured.value!)!
    #expect(p.headerType == .header1)
    #expect(p.transportId == nil)
    #expect(p.packetType == .linkRequest)
    #expect(store.state.linkID == Link.linkID(requestPacket: p))
    await clock.advance(by: .seconds(store.state.establishmentTimeout))    // quiesce the establishment timer
}

/// `lastData` must advance ONLY on successfully-decrypted non-keepalive traffic. Task 4 evicts
/// on it, so if a keepalive or an undecryptable packet advanced it, an attacker could hold its
/// link at the head of the eviction order with garbage and the cap would evict legitimate links
/// instead. RNS stamps last_data BEFORE decrypting (RNS/Link.py:936, 1.4.1); we deliberately add
/// the decryption requirement RNS lacks, while keeping RNS's keepalive-vs-data distinction intact.
///
/// Every event below lands at a DISTINCT timestamp. Under a constant clock these assertions would
/// be vacuous: "stamped again with the same value" and "not stamped at all" are indistinguishable.
@Test @MainActor func lastDataAdvancesOnlyOnDecryptedNonKeepaliveTraffic() async {
    let clock = testClock()
    let seconds = LockIsolated(100.0)                                   // t0 — establishment
    let store = await advancingResponderStore(clock: clock, seconds: seconds)

    // LRRTT is a non-keepalive that decrypts, so it DOES stamp lastData. That matches the
    // reference: RNS stamps last_data for every non-KEEPALIVE context (Link.py:936) and handles
    // LRRTT later in the same receive path (Link.py:1015). We narrow RNS on decryption, not on
    // which contexts count.
    #expect(store.state.lastData == 100.0)

    // 1. A plaintext keepalive must NOT advance lastData.
    seconds.setValue(200.0)                                             // t1
    let ka = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                    destinationType: .link, context: .keepalive, contextFlag: false, hops: 0,
                    destinationHash: store.state.linkID, transportId: nil,
                    payload: Data([0xFF]))
    await store.send(.received(try! ka.packed()))
    #expect(store.state.lastData == 100.0)                              // still t0, not t1

    // 2. An UNDECRYPTABLE non-keepalive packet must NOT advance lastData either. This is the
    //    case RNS would stamp and we deliberately do not.
    seconds.setValue(300.0)                                             // t2
    let garbage = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                         destinationType: .link, context: .none, contextFlag: false, hops: 0,
                         destinationHash: store.state.linkID, transportId: nil,
                         payload: Data(repeating: 0x00, count: 48))
    await store.send(.received(try! garbage.packed()))
    #expect(store.state.lastData == 100.0)                              // still t0, not t2

    // 3. Real decrypted application data DOES advance it.
    seconds.setValue(400.0)                                             // t3
    let cipher = Link.encrypt(Data([0x01, 0x02, 0x03]), sessionKey: store.state.sessionKey)
    let dataPacket = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                            destinationType: .link, context: .none, contextFlag: false, hops: 0,
                            destinationHash: store.state.linkID, transportId: nil, payload: cipher)
    await store.send(.received(try! dataPacket.packed()))
    await store.receive { if case .delegate(.dataReceived) = $0 { return true }; return false }
    #expect(store.state.lastData == 400.0)                              // advanced to t3
}

/// An authenticated packet from a new interface re-homes the link. A plaintext keepalive from a
/// new interface must NOT — that is the link-theft vector: linkID is public and link packets
/// bypass Transport's dedup, so an unauthenticated peer could otherwise redirect a legitimate
/// peer's traffic to itself.
@Test @MainActor func onlyAuthenticatedTrafficReHomesTheSession() async {
    let clock = testClock()
    let store = await activeResponderStore(clock: clock)
    let original = store.state.interfaceID
    let attacker = InterfaceID("attacker")

    // Plaintext keepalive from a NEW interface: must not move the link.
    let ka = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                    destinationType: .link, context: .keepalive, contextFlag: false, hops: 0,
                    destinationHash: store.state.linkID, transportId: nil, payload: Data([0xFF]))
    await store.send(.received(try! ka.packed(), arrivalInterface: attacker))
    #expect(store.state.interfaceID == original)

    // Authenticated data from a new interface: DOES move the link.
    let peer = InterfaceID("peer-reconnected")
    let cipher = Link.encrypt(Data([0x09]), sessionKey: store.state.sessionKey)
    let dataPacket = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                            destinationType: .link, context: .none, contextFlag: false, hops: 0,
                            destinationHash: store.state.linkID, transportId: nil, payload: cipher)
    await store.send(.received(try! dataPacket.packed(), arrivalInterface: peer))
    await store.receive { if case .delegate(.dataReceived) = $0 { return true }; return false }
    #expect(store.state.interfaceID == peer)
}

/// INTEROP GUARD — pins a deliberate NON-change. RNS keepalives are unencrypted by explicit
/// design (`Packet.pack` has a dedicated KEEPALIVE branch: "Keepalive packets contain no actual
/// data"). A peer on an otherwise-idle link sends nothing else, so a plaintext keepalive MUST
/// keep refreshing the inactivity clock. Gating that refresh on authentication would tear down
/// links with real RNS peers — and would not bound anything anyway, since an attacker holds a
/// valid session key and can send authenticated keepalives.
///
/// Two-part structure, because "the keepalive refreshed the clock" and "the clock is still armed
/// afterwards" are different properties and a bug can break either one alone:
///   (1) The keepalive must refresh. Each `almostStale` advance stops deliberately short of the
///       deadline, so two of them back-to-back overshoot a timer that was NEVER re-armed while
///       leaving a re-armed one comfortably alive. The observation runs under `.on`, because a
///       fired-but-unhandled `.inactivityDeadline` is silent under `.off`.
///   (2) The refreshed timer is still armed, not cancelled. A change that cancelled the
///       inactivity timer on a keepalive without re-arming it would sail through (1) — no
///       deadline is queued — while leaving the link immortal, which is the opposite failure.
///       Advancing a full `stale` past the last keepalive must therefore still reap it.
@Test @MainActor func plaintextKeepaliveStillRefreshesInactivity() async {
    let clock = testClock()
    let store = await activeResponderStore(clock: clock)
    let stale = store.state.staleTime
    let linkID = store.state.linkID
    // Deliberately short of the deadline: one of these alone never reaps, two back-to-back reap
    // an un-refreshed timer. Let the advances carry the arithmetic.
    let almostStale = Duration.seconds(stale * 0.9)

    func plaintextKeepalive() -> Data {
        let ka = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .link, context: .keepalive, contextFlag: false, hops: 0,
                        destinationHash: linkID, transportId: nil, payload: Data([0xFF]))
        return try! ka.packed()
    }

    // Advance to just under the stale deadline, then ping with an UNAUTHENTICATED keepalive.
    await clock.advance(by: almostStale)
    await store.send(.received(plaintextKeepalive()))
    _ = await captureTransmit(store)                       // 0xFE reply confirms keepalive processed

    // Advance again by the same amount. The timer armed at establishment is now overshot, so if
    // the keepalive had not re-armed it the deadline would already have fired; the timer the
    // keepalive armed still has time left on it.
    await clock.advance(by: almostStale)

    // (1) Detection step: send a second keepalive under `.on`. `TestStore.send` checks
    // `receivedActions` before clearing them, but routes the complaint through
    // `reportIssueHelper`, which reads exhaustivity at call time — under `.off` the message is
    // dropped and the queue then cleared, so a fired `.inactivityDeadline` leaves no trace.
    // Under `.on` it fails the test. Without a mutation the queue is empty here.
    store.exhaustivity = .on
    await store.send(.received(plaintextKeepalive()))
    store.exhaustivity = .off
    _ = await captureTransmit(store)                       // second 0xFE reply
    #expect(store.state.status == .active, "link must survive if keepalive reset the inactivity clock")

    // (2) The timer that keepalive armed is real: a full stale of silence past it reaps the link.
    store.exhaustivity = .on
    await clock.advance(by: .seconds(stale))
    await store.receive(.inactivityDeadline) { $0.status = .closed }
    _ = await captureTransmit(store)                       // LINKCLOSE teardown
    await store.receive(.delegate(.closed(.timedOut)))
    store.exhaustivity = .off
    #expect(store.state.status == .closed)
}
