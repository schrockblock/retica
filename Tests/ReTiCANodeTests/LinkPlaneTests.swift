import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

private let ifA = InterfaceID("iface-a")

@Test @MainActor func openLinkMintsInitiatorLinkOnTheGivenInterface() async {
    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    let dest = Data(repeating: 0x02, count: 16)
    await store.send(.openLink(initiatorTo: Identity(), destinationHash: dest,
                               interfaceID: ifA, relayNextHop: nil))
    #expect(store.state.links.count == 1)
    #expect(store.state.links[0].interfaceID == ifA)
    #expect(store.state.links[0].destinationHash == dest)
    // Establishment emits an outbound LINKREQUEST as a routing delegate on that interface.
    let captured = LockIsolated<InterfaceID?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(txID, _)) = action { captured.setValue(txID); return true }
        return false
    }
    #expect(captured.value == ifA)
    await store.send(.closeLink(linkID: store.state.links[0].linkID))
}

@Test @MainActor func acceptLinkRequestMintsResponderLinkOnTheArrivalInterface() async {
    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    let owner = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: owner)!
    let initEph = Identity()
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: dest.hash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    await store.send(.acceptLinkRequest(owner: owner, destinationHash: dest.hash,
                                        interfaceID: ifA, data: try! request.packed()))
    #expect(store.state.links.count == 1)
    #expect(store.state.links[0].interfaceID == ifA)
    // The responder emits its LRPROOF as a routing delegate on the ARRIVAL interface.
    let captured = LockIsolated<(InterfaceID, Data)?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(txID, raw)) = action { captured.setValue((txID, raw)); return true }
        return false
    }
    #expect(captured.value?.0 == ifA)
    #expect(Packet(raw: captured.value!.1)?.packetType == .proof)
    await store.send(.closeLink(linkID: store.state.links[0].linkID))
}

/// Verify that every `LinkPlane.Action` case round-trips through `TransportEndpoint`'s
/// `linkPlaneRoute` alias: `linkPlaneRoute.extract(from: linkPlaneRoute.embed(a)) == a`.
///
/// This is a structural test: if the bijection ever mis-maps a case (e.g. routes `.openLink`
/// through the wrong embed branch, or forgets a case in `extract`), at least one assertion
/// below will fail.  Fourteen cases are checked — one representative value per case.
@Test func linkPlaneRouteCasePathRoundTripsEveryPlaneAction() {
    let route = TransportEndpoint.Action.allCasePaths.linkPlaneRoute

    func roundTrips(_ plane: LinkPlane.Action) -> Bool {
        route.extract(from: route.embed(plane)) == plane
    }

    // .link — aliased to TCPEndpoint.Action.link
    let elementID = UUID()
    let linkAction: LinkPlane.Action = .link(.element(id: elementID, action: .establish))
    #expect(roundTrips(linkAction))

    // .openLink — NOT aliased; rides .linkPlane(...)
    let ident = Identity()
    let destHash = Data(repeating: 0x01, count: 16)
    let ifaceID = InterfaceID("test-iface")
    #expect(roundTrips(.openLink(initiatorTo: ident, destinationHash: destHash,
                                 interfaceID: ifaceID, relayNextHop: nil)))
    #expect(roundTrips(.openLink(initiatorTo: ident, destinationHash: destHash,
                                 interfaceID: ifaceID, relayNextHop: Data(repeating: 0x02, count: 16))))

    // .acceptLinkRequest — NOT aliased; rides .linkPlane(...)
    let owner = Identity()
    #expect(roundTrips(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                          interfaceID: ifaceID, data: Data([0xAB]))))

    // .routeLinkPacket — NOT aliased; rides .linkPlane(...)
    #expect(roundTrips(.routeLinkPacket(linkID: Data(repeating: 0x03, count: 16),
                                        arrivalInterface: InterfaceID("test-iface"),
                                        data: Data([0x01, 0x02]))))

    // Verb cases — aliased to TCPEndpoint.Action top-level
    let linkID = Data(repeating: 0x04, count: 16)
    #expect(roundTrips(.sendOverLink(linkID: linkID, data: Data("hello".utf8))))
    #expect(roundTrips(.sendResourceOverLink(linkID: linkID, data: Data("res".utf8))))
    #expect(roundTrips(.cancelResource(linkID: linkID, hash: Data(repeating: 0x0E, count: 32))))
    #expect(roundTrips(.identifyOverLink(linkID: linkID, identity: Identity())))
    #expect(roundTrips(.sendRequestOverLink(linkID: linkID, path: "svc/echo", data: Data("req".utf8))))
    #expect(roundTrips(.sendResponseOverLink(linkID: linkID, requestID: Data(repeating: 0x05, count: 16),
                                             data: Data("resp".utf8))))
    #expect(roundTrips(.sendWithReceiptOverLink(linkID: linkID, data: Data("msg".utf8),
                                               token: Data(repeating: 0x06, count: 16))))
    #expect(roundTrips(.provePacketOverLink(linkID: linkID, packetHash: Data(repeating: 0x0C, count: 32))))
    #expect(roundTrips(.closeLink(linkID: linkID)))
    #expect(roundTrips(.registerRequestHandler(path: "svc/echo", policy: .all)))
    #expect(roundTrips(.deregisterRequestHandler(path: "svc/echo")))

    // .interfaceDisconnected — NOT aliased; rides .linkPlane(...)
    #expect(roundTrips(.interfaceDisconnected(InterfaceID("gone"))))

    // .delegate — NOT aliased; rides .linkPlane(...)
    #expect(roundTrips(.delegate(.transmit(ifaceID, Data([0xFF])))))
    #expect(roundTrips(.delegate(.linkEstablished(linkID: linkID, destinationHash: destHash))))
    #expect(roundTrips(.delegate(.linkDataReceived(linkID: linkID, data: Data([0x00]),
                                                   packetHash: Data(repeating: 0x0D, count: 32)))))
    #expect(roundTrips(.delegate(.linkClosed(linkID: linkID, reason: .initiatorClosed))))
    #expect(roundTrips(.delegate(.linkFailed(destinationHash: destHash, reason: .establishmentTimedOut))))
    #expect(roundTrips(.delegate(.linkFailed(destinationHash: destHash, reason: .handshakeRejected))))
    #expect(roundTrips(.delegate(.resourceReceived(linkID: linkID, data: Data([0x11])))))
    #expect(roundTrips(.delegate(.resourceConcluded(linkID: linkID, resourceHash: Data(repeating: 0x07, count: 16)))))
    #expect(roundTrips(.delegate(.resourceFailed(linkID: linkID, resourceHash: Data(repeating: 0x08, count: 16),
                                                 rejected: true))))
    #expect(roundTrips(.delegate(.resourceProgress(linkID: linkID, resourceHash: Data(repeating: 0x0F, count: 16),
                                                   role: .sender, bytesDone: 1, bytesTotal: 2,
                                                   segment: 1, segments: 1))))
    #expect(roundTrips(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: Identity()))))
    let rid = Data(repeating: 0x09, count: 16)
    let ph  = Data(repeating: 0x0A, count: 16)
    #expect(roundTrips(.delegate(.requestReceived(linkID: linkID, requestID: rid, pathHash: ph, data: Data("body".utf8)))))
    #expect(roundTrips(.delegate(.responseReceived(linkID: linkID, requestID: rid, data: Data("ans".utf8)))))
    #expect(roundTrips(.delegate(.requestFailed(linkID: linkID, requestID: rid))))
    let tok = Data(repeating: 0x0B, count: 16)
    #expect(roundTrips(.delegate(.packetDelivered(token: tok))))
    #expect(roundTrips(.delegate(.packetDeliveryFailed(token: tok))))
}

// MARK: - Re-homing helpers (Task 5)

/// Drives a full responder handshake through the plane and returns (elementID, linkID,
/// sessionKey) for an ACTIVE session on `interfaceID`. Real handshake, not seeded state — the
/// session key has to be genuine for the re-home tests to send authenticated traffic.
@MainActor
private func activeResponderInPlane(
    _ store: TestStore<LinkPlane.State, LinkPlane.Action>,
    owner: Identity, destHash: Data, interfaceID: InterfaceID
) async -> (id: UUID, linkID: Data, sessionKey: Data) {
    await store.send(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                        interfaceID: interfaceID,
                                        data: freshLinkRequest(destHash: destHash)))
    await store.receive { if case .link(.element(_, .acceptRequest)) = $0 { return true }; return false }
    let element = store.state.links.first { $0.role == .responder && $0.status == .handshake }!
    let rttCipher = Link.encrypt(MsgPack.encode(0.0), sessionKey: element.sessionKey)
    let rtt = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                     destinationType: .link, context: .linkRequestRTT, contextFlag: false, hops: 0,
                     destinationHash: element.linkID, transportId: nil, payload: rttCipher)
    await store.send(.routeLinkPacket(linkID: element.linkID, arrivalInterface: interfaceID,
                                      data: try! rtt.packed()))
    await store.receive { if case .delegate(.linkEstablished) = $0 { return true }; return false }
    return (element.id, element.linkID, element.sessionKey)
}

/// Builds an authenticated application-data packet for an established link.
private func authenticatedPacket(linkID: Data, sessionKey: Data, body: Data) -> Data {
    let cipher = Link.encrypt(body, sessionKey: sessionKey)
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .link, context: .none, contextFlag: false, hops: 0,
                        destinationHash: linkID, transportId: nil, payload: cipher)
    return try! packet.packed()
}

// MARK: - Re-homing tests (Task 1: BLE peer reconnect)

/// A BLE InterfaceID is derived from the peer's session token, so a reconnected peer is a
/// different interface and the link's stored binding is stale. Re-homing still happens — but
/// now ONLY for traffic that authenticated (see `onlyAuthenticatedTrafficReHomesTheSession`
/// for the negative case).
@Test @MainActor func linkPacketFromANewInterfaceReHomesTheSession() async {
    let ifOld = InterfaceID("old")
    let ifNew = InterfaceID("new")
    let destHash = Data(repeating: 0x01, count: 16)
    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    let session = await activeResponderInPlane(store, owner: Identity(),
                                               destHash: destHash, interfaceID: ifOld)
    #expect(store.state.links[id: session.id]?.interfaceID == ifOld)

    let raw = authenticatedPacket(linkID: session.linkID, sessionKey: session.sessionKey,
                                  body: Data([0x01, 0x02]))
    await store.send(.routeLinkPacket(linkID: session.linkID, arrivalInterface: ifNew, data: raw))
    await store.receive { if case .delegate(.linkDataReceived) = $0 { return true }; return false }
    #expect(store.state.links[id: session.id]?.interfaceID == ifNew)
}

/// An authenticated packet arriving on the SAME interface must not re-home — the common case
/// must not churn. This is also the TCP case: TCPEndpoint has one fixed InterfaceID, so the
/// arrival always equals the stored value.
///
/// The load-bearing assertion is that NO `.rehomed` action is emitted, not merely that the
/// binding ends up unchanged. Those differ: without the `arrival != state.interfaceID` guard
/// the session would be reassigned to the value it already holds, so an end-state-only
/// assertion passes either way and the test proves nothing. `.rehomed` is the observable that
/// distinguishes them — which matters because a one-shot re-home permission consumed inside
/// that same block would be spent by ordinary same-interface traffic.
///
/// Driven under `.on` exhaustivity so a spurious `.rehomed` cannot be silently skipped:
/// under `.off`, `receive(predicate)` skips non-matching actions, which is exactly how this
/// test failed to catch the missing guard before.
@Test @MainActor func linkPacketFromTheSameInterfaceLeavesTheSessionUnchanged() async {
    let ifTCP = InterfaceID("tcp")
    let destHash = Data(repeating: 0x02, count: 16)
    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    let session = await activeResponderInPlane(store, owner: Identity(),
                                               destHash: destHash, interfaceID: ifTCP)
    #expect(store.state.links[id: session.id]?.interfaceID == ifTCP)

    // Authenticated packet on the SAME interface: the binding must not move, and no re-home
    // may be announced. Flip to exhaustive BEFORE the send so every resulting action must be
    // accounted for by name.
    store.exhaustivity = .on
    let raw = authenticatedPacket(linkID: session.linkID, sessionKey: session.sessionKey,
                                  body: Data([0x03, 0x04]))
    await store.send(.routeLinkPacket(linkID: session.linkID, arrivalInterface: ifTCP, data: raw))
    await store.receive { if case .link(.element(_, .received)) = $0 { return true }; return false }
    await store.receive { if case .link(.element(_, .delegate(.dataReceived))) = $0 { return true }; return false }
    await store.receive { if case .delegate(.linkDataReceived) = $0 { return true }; return false }
    #expect(store.state.links[id: session.id]?.interfaceID == ifTCP)

    // Close so the inactivity timer the inbound packet re-armed is cancelled; an in-flight
    // effect at teardown is reported as a failure under `.on`.
    store.exhaustivity = .off
    await store.send(.closeLink(linkID: session.linkID))
}

/// Re-homing is keyed to the addressed link only: an authenticated packet arriving on a new
/// interface for session A does not disturb session B on its original interface.
@Test @MainActor func reHomingDoesNotDisturbOtherSessions() async {
    let ifA2 = InterfaceID("ifA")
    let ifB = InterfaceID("ifB")
    let ifNew = InterfaceID("ifNew")
    let destA = Data(repeating: 0x03, count: 16)
    let destB = Data(repeating: 0x04, count: 16)
    let owner = Identity()
    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    let sessionA = await activeResponderInPlane(store, owner: owner,
                                                destHash: destA, interfaceID: ifA2)
    let sessionB = await activeResponderInPlane(store, owner: owner,
                                                destHash: destB, interfaceID: ifB)
    #expect(store.state.links[id: sessionA.id]?.interfaceID == ifA2)
    #expect(store.state.links[id: sessionB.id]?.interfaceID == ifB)

    // Authenticated packet for A on ifNew — A re-homes; B stays on ifB.
    let raw = authenticatedPacket(linkID: sessionA.linkID, sessionKey: sessionA.sessionKey,
                                  body: Data([0x05]))
    await store.send(.routeLinkPacket(linkID: sessionA.linkID, arrivalInterface: ifNew, data: raw))
    await store.receive { if case .delegate(.linkDataReceived) = $0 { return true }; return false }
    #expect(store.state.links[id: sessionA.id]?.interfaceID == ifNew)
    #expect(store.state.links[id: sessionB.id]?.interfaceID == ifB)
}

/// Re-homing must extend to in-flight resource transfers: ResourceTransfer.State.interfaceID is
/// a snapshot taken at creation, and every transfer transmit uses that stored copy verbatim.
/// Without the transfer loop in the `.rehomed` delegate handler, parts/hashmap-updates/proofs/
/// cancels would keep going to the dead interface after the session itself moved.
///
/// This is the end-to-end proof that the `rehomed` delegate handler is wired: the session
/// re-homes via `LinkSession` (which emits `.delegate(.rehomed)`), and `LinkPlane`'s handler
/// for that delegate updates the transfers. If the handler body is deleted, the transfer
/// assertion below fails — proving the wiring is actually exercised.
@Test @MainActor func linkPacketFromANewInterfaceReHomesSessionAndItsTransfers() async {
    let ifOld = InterfaceID("old-xfer")
    let ifNew = InterfaceID("new-xfer")
    let destHash = Data(repeating: 0x05, count: 16)
    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    let session = await activeResponderInPlane(store, owner: Identity(),
                                               destHash: destHash, interfaceID: ifOld)
    #expect(store.state.links[id: session.id]?.interfaceID == ifOld)

    // Start a transfer on the old interface so there is something to re-home.
    await store.send(.sendResourceOverLink(linkID: session.linkID, data: Data(repeating: 0xAB, count: 64)))
    // Drain the advertisement that fires immediately from sendResource.
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }

    // Confirm a transfer is now in-flight on the old interface. Bail rather than trap if the
    // transfer never started: without one this test would silently assert nothing.
    guard let xferID = store.state.links[id: session.id]?.transfers.ids.first else {
        Issue.record("no in-flight transfer was created; the re-home assertions below would be vacuous")
        return
    }
    #expect(store.state.links[id: session.id]?.transfers[id: xferID]?.interfaceID == ifOld)

    // Authenticated packet from the new interface: session AND transfer must re-home.
    let raw = authenticatedPacket(linkID: session.linkID, sessionKey: session.sessionKey,
                                  body: Data([0x01, 0x02]))
    await store.send(.routeLinkPacket(linkID: session.linkID, arrivalInterface: ifNew, data: raw))
    await store.receive { if case .delegate(.linkDataReceived) = $0 { return true }; return false }

    // Both session and transfer moved — this is the assertion that dies if the rehomed
    // handler body is deleted.
    #expect(store.state.links[id: session.id]?.interfaceID == ifNew)
    #expect(store.state.links[id: session.id]?.transfers[id: xferID]?.interfaceID == ifNew)
}

// MARK: - Duplicate inbound LINKREQUEST dedup tests

/// F2: a replayed LINKREQUEST must not mint a second element. Duplicates share a linkID, and
/// each one costs a DH, an HKDF, an Ed25519 signature with our long-term destination key, and a
/// fresh keypair generation. A retry is never a duplicate — both we and RNS mint a fresh
/// ephemeral per attempt, so an identical linkID is always a replay or a multipath copy.
@Test @MainActor func replayedLinkRequestMintsExactlyOneElementAndOneProof() async {
    let owner = Identity()
    let initEph = Identity()
    let destHash = Data(repeating: 0x21, count: 16)
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: destHash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    let raw = try! request.packed()

    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                        interfaceID: InterfaceID("i"), data: raw))
    await store.receive { if case .link(.element(_, .acceptRequest)) = $0 { return true }; return false }
    #expect(store.state.links.count == 1)

    // Byte-identical replay: no new element, and — the half this test is named for — no new
    // PROOF. The proof half is load-bearing on its own. A dedupe that recognised the duplicate
    // but re-dispatched `.acceptRequest` to the existing element would keep `links.count` at 1
    // while still paying the DH, HKDF, Ed25519 signature and fresh keypair generation the guard
    // exists to avoid, and putting a second LRPROOF on the wire per replay. Element-count
    // assertions alone cannot see that.
    //
    // The emission is invisible under `.off`: `TestStore.send` checks `receivedActions` before
    // it clears them, but routes the complaint through `reportIssueHelper`, which reads
    // exhaustivity at call time and drops the message entirely under
    // `.off(showSkippedAssertions: false)` — then clears the queue, so nothing downstream can
    // recover it. So the observation has to happen under `.on`.
    await store.send(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                        interfaceID: InterfaceID("i"), data: raw))
    #expect(store.state.links.count == 1)

    // Proof probe: a no-op action (unknown linkID → `.none`, no state change) sent under `.on`,
    // purely so its pre-send check runs against whatever the replay left queued. A re-dispatched
    // `.acceptRequest` shows up here as an unhandled received action.
    store.exhaustivity = .on
    await store.send(.sendOverLink(linkID: Data(repeating: 0xEE, count: 16), data: Data()))
    store.exhaustivity = .off

    // A genuinely NEW request (different ephemeral → different linkID) still works.
    let request2 = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                          destinationType: .single, context: .none, contextFlag: false, hops: 0,
                          destinationHash: destHash, transportId: nil,
                          payload: Identity().publicKey + Link.signallingBytes)
    await store.send(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                        interfaceID: InterfaceID("i"), data: try! request2.packed()))
    await store.receive { if case .link(.element(_, .acceptRequest)) = $0 { return true }; return false }
    #expect(store.state.links.count == 2)
}

// MARK: - Malformed inbound LINKREQUEST element-reaping tests

/// A malformed inbound LINKREQUEST must not leave a permanent element behind. Remotely
/// triggerable: any peer that has heard our announce can send wrong-sized payloads and grow
/// `state.links` without bound, which `routeLinkPacket` then linear-scans on every inbound
/// packet.
///
/// Three malformed shapes are covered:
///   1. Unparseable bytes (random garbage that `Packet(raw:)` cannot parse). With the dedup
///      guard in `acceptLinkRequest`, `Packet(raw:)` fails before any element is minted — the
///      "no leak" property holds by a STRONGER mechanism than before: zero element is created,
///      not one-then-reaped.
///   2. A validly-packed packet whose `packetType` is not `.linkRequest`. This parses
///      successfully, so an element is minted and then reaped by `LinkSession.acceptRequest`'s
///      malformed guard (unchanged behaviour).
///   3. A validly-packed `.linkRequest` with the wrong payload size (10 bytes, not 64/67).
///      Same as shape 2: parses, element minted, reaped downstream.
///
/// For shapes 2 and 3: no `.linkFailed` delegate must escape (a responder's `destinationHash`
/// is the destination WE serve — reporting it as unreachable would misinform the delivery
/// layer). This is verified by teardown enforcement: `LinkPlane` gates `.linkFailed` on
/// `session.role == .initiator`, and the spawned session is always `.responder` (set by
/// `acceptLinkRequest`). The `store.exhaustivity = .on` at the end of each shape arms the TCA
/// deinit check — deleting `LinkPlane`'s role gate causes the test to FAIL at teardown with an
/// unhandled `.linkFailed` action. Those `.on` lines are not decoration; they are the only thing
/// that pins the gate.
@Test @MainActor func malformedInboundLinkRequestReapsItsElement() async {
    let owner = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: owner)!

    // Shape 1: unparseable bytes.
    // `Packet(raw:)` returns nil for garbage, so the `acceptLinkRequest` dedup guard fires and
    // returns `.none` BEFORE any element is minted. The "no leak" property holds by an even
    // stronger mechanism: zero elements are ever created, so links is empty immediately after
    // the send, with no action to drain.
    do {
        let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 0))
        }
        store.exhaustivity = .off
        let garbage = Data(repeating: 0xFF, count: 10)
        await store.send(.acceptLinkRequest(owner: owner, destinationHash: dest.hash,
                                            interfaceID: ifA, data: garbage))
        // No element was minted: links is immediately empty, no action to drain.
        #expect(store.state.links.isEmpty, "Shape 1 (unparseable): no element must be minted")
        store.exhaustivity = .on
    }

    // Shape 2: a validly-packed packet with the wrong packetType (not .linkRequest).
    do {
        let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 0))
        }
        store.exhaustivity = .off
        let wrongType = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                               destinationType: .single, context: .none, contextFlag: false, hops: 0,
                               destinationHash: dest.hash, transportId: nil,
                               payload: Data(repeating: 0x01, count: 67))
        await store.send(.acceptLinkRequest(owner: owner, destinationHash: dest.hash,
                                            interfaceID: ifA, data: try! wrongType.packed()))
        await store.receive(
            { if case .link(.element(_, .delegate(.establishmentFailed(.handshakeRejected)))) = $0 { return true }; return false }
        )
        await store.receive(
            { if case .delegate(.localLinkClosed) = $0 { return true }; return false }
        )
        #expect(store.state.links.isEmpty, "Shape 2 (wrong packetType): element must be reaped")
        store.exhaustivity = .on
    }

    // Shape 3: a validly-packed .linkRequest with the wrong payload size (10 bytes, not 64/67).
    do {
        let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 0))
        }
        store.exhaustivity = .off
        let wrongSize = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                               destinationType: .single, context: .none, contextFlag: false, hops: 0,
                               destinationHash: dest.hash, transportId: nil,
                               payload: Data(repeating: 0xAB, count: 10))
        await store.send(.acceptLinkRequest(owner: owner, destinationHash: dest.hash,
                                            interfaceID: ifA, data: try! wrongSize.packed()))
        await store.receive(
            { if case .link(.element(_, .delegate(.establishmentFailed(.handshakeRejected)))) = $0 { return true }; return false }
        )
        await store.receive(
            { if case .delegate(.localLinkClosed) = $0 { return true }; return false }
        )
        #expect(store.state.links.isEmpty, "Shape 3 (wrong payload size): element must be reaped")
        store.exhaustivity = .on
    }
}

/// An initiator that cannot pack its LINKREQUEST must not leave a permanent element behind.
///
/// `LinkPlane.openLink` appends the session and dispatches `.establish`, which writes `linkID`
/// and `requestedAt` before attempting `packet.packed()`. If `packed()` throws (because
/// `destinationHash` is not 16 bytes), the original code returned `.none` — leaving the element
/// both unreachable and unreapable, with no timer to drive reaping later.
///
/// The fix emits `.establishmentFailed(.handshakeRejected)`, which `LinkPlane` handles by
/// removing the element and — because `session.role == .initiator` — forwarding a `linkFailed`
/// delegate with reason `.handshakeRejected`.
///
/// The failure is driven honestly via `openLink` with an 8-byte `destinationHash`. That makes
/// `Packet.packed()` throw `PacketError.malformed` (which the `guard let raw = try? …` catches),
/// without seeding state directly. This is the same probe the Task 1 reviewer used to confirm
/// the leak before the fix.
///
/// Note: `.handshakeRejected` is not a perfectly honest label (no handshake was attempted; the
/// error is local). It is the closest existing `EstablishmentFailure` case — `.timedOut` would
/// be worse because it triggers a path request. A new case would be more accurate but requires
/// updating `LinkPlane`'s exhaustive switch; that is a separate decision flagged to the author.
@Test @MainActor func initiatorThatCannotPackItsLinkRequestReapsItsElement() async {
    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    // An 8-byte destinationHash makes Packet.packed() throw PacketError.malformed.
    // `.establish` writes `linkID` and `requestedAt` BEFORE the guard, so without the fix
    // the element is stranded (no timer, no delegate, no removal path).
    let shortHash = Data(repeating: 0xAB, count: 8)
    await store.send(.openLink(initiatorTo: Identity(), destinationHash: shortHash,
                               interfaceID: ifA, relayNextHop: nil))
    // The session element is appended synchronously, so links.count == 1 here.
    #expect(store.state.links.count == 1, "Element must be appended before establish fires")
    // Drain: .establish runs synchronously within the send, emitting .establishmentFailed.
    // LinkPlane removes the element and forwards .linkFailed(destinationHash:reason:).
    await store.receive(
        { if case .link(.element(_, .delegate(.establishmentFailed(.handshakeRejected)))) = $0 { return true }; return false }
    )
    #expect(store.state.links.isEmpty, "Element must be reaped after pack failure")
    // The initiator role means LinkPlane also surfaces a .linkFailed delegate.
    await store.receive(
        { if case .delegate(.linkFailed(let dest, .handshakeRejected)) = $0 { return dest == shortHash }; return false }
    )
    // Flip to exhaustive for teardown: no stray actions should remain.
    store.exhaustivity = .on
}

// MARK: - Responder link cap tests (Task 4: F1)

/// Helper: a well-formed LINKREQUEST with a fresh ephemeral (hence a fresh linkID).
private func freshLinkRequest(destHash: Data) -> Data {
    let packet = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: destHash, transportId: nil,
                        payload: Identity().publicKey + Link.signallingBytes)
    return try! packet.packed()
}

/// A LINKREQUEST whose 64-byte payload is not derived from any key. `Link.sessionKey` still
/// succeeds on it, so the element it mints reaches `.handshake` — which is what made the pre-fix
/// flush possible, and which the test below asserts rather than assumes. Several canonical
/// low-order X25519 values (all-zeros among them) are rejected by CryptoKit; a random 32-byte key
/// is overwhelmingly likely to be accepted, which is why the original F14 probe looked milder than
/// the defect was when it chose all-zeros. The bytes are generated by a fixed
/// recurrence rather than an RNG so the test is deterministic; nothing about them comes from a
/// keypair, which is the point.
private func junkLinkRequest(destHash: Data, seed: UInt8) -> Data {
    var byte = seed
    let payload = Data((0 ..< 64).map { _ -> UInt8 in
        byte = byte &* 37 &+ 11
        return byte
    })
    let packet = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: destHash, transportId: nil, payload: payload)
    return try! packet.packed()
}

/// Drive one NEW responder element all the way to `.active` through the plane's real entry
/// points, and return its element id.
///
/// This matters because a responder activates only via `(.responder, .handshake, .data,
/// .linkRequestRTT)`, and that transition is what emits `.delegate(.established)` — the action the
/// active-responder cap is enforced on. A test that merely floods `acceptLinkRequest` leaves every
/// element in `.handshake` and never reaches the eviction path at all. Feeding the LRRTT back
/// through `routeLinkPacket` (which is how Transport delivers it) is what makes eviction reachable.
@MainActor
private func acceptAndActivateResponder(_ store: TestStore<LinkPlane.State, LinkPlane.Action>,
                                        owner: Identity, destHash: Data,
                                        iface: InterfaceID) async -> UUID {
    await store.send(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                        interfaceID: iface, data: freshLinkRequest(destHash: destHash)))
    // `.acceptRequest` is an effect; it must drain before `linkID`/`sessionKey` are populated.
    await store.receive { if case .link(.element(_, .acceptRequest)) = $0 { return true }; return false }
    let element = store.state.links.last!
    // The initiator's RTT reply, encrypted under the session key the handshake just derived.
    let rttCipher = Link.encrypt(MsgPack.encode(0.0), sessionKey: element.sessionKey)
    let rtt = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                     destinationType: .link, context: .linkRequestRTT, contextFlag: false, hops: 0,
                     destinationHash: element.linkID, transportId: nil, payload: rttCipher)
    await store.send(.routeLinkPacket(linkID: element.linkID, arrivalInterface: iface,
                                      data: try! rtt.packed()))
    await store.receive { if case .link(.element(_, .received)) = $0 { return true }; return false }
    #expect(store.state.links[id: element.id]?.status == .active,
            "helper must actually reach .active, or the eviction path stays unreachable")
    return element.id
}

/// END-TO-END eviction: a link is actually chosen, closed, and REMOVED, and the responder count
/// settles back at the cap.
///
/// Every element here is created AND promoted through the plane's real entry points; nothing is
/// seeded. That is what distinguishes this test from the three comparator tests below, which seed
/// their incumbents and drive only the promotion that triggers the eviction. It is also the only
/// test that follows the victim past `.close` to its REMOVAL and asserts the population settles.
@Test @MainActor func evictionClosesTheOldestResponderAndCountSettlesAtTheCap() async {
    let owner = Identity()
    let destHash = Data(repeating: 0x51, count: 16)
    let iface = InterfaceID("i")
    let cap = 2
    // A mutable clock box so each activation lands at a distinct timestamp; under a constant date
    // every stamp is 0 and "oldest" would be decided by sort stability, not by the key.
    let seconds = LockIsolated(0.0)
    let store = TestStore(
        initialState: LinkPlane.State(maxResponderLinks: cap)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .init { Date(timeIntervalSince1970: seconds.value) }
    }
    store.exhaustivity = .off

    // Two ACTIVE responders. `older` activates first, so it carries the smaller sort key. The key
    // in play is `lastData`, not the `?? activatedAt` fallback: the LRRTT that promotes each
    // element goes through `authDecrypt`, so the hoisted tail in `LinkSession.received` stamps
    // `lastData` at activation time. (The fallback is exercised by the nil-`lastData` attacker
    // element in `evictionPrefersLinksWithNoAuthenticatedTrafficEvenIfRecentlyPinged`.)
    seconds.setValue(100)
    let older = await acceptAndActivateResponder(store, owner: owner, destHash: destHash, iface: iface)
    seconds.setValue(200)
    let newer = await acceptAndActivateResponder(store, owner: owner, destHash: destHash, iface: iface)
    #expect(store.state.links.filter { $0.role == .responder }.count == cap)

    // A third peer completes a handshake. THAT is what costs an incumbent its slot — not the
    // request, which is unauthenticated and evicts nothing.
    seconds.setValue(300)
    let newest = await acceptAndActivateResponder(store, owner: owner, destHash: destHash, iface: iface)
    await store.receive { action in
        if case let .link(.element(id, .close)) = action { return id == older }
        return false
    }
    // Eviction must REMOVE, not merely mark: the element leaves through the `.closed` delegate,
    // which is the path that also reaps its transfers.
    await store.receive { if case .link(.element(_, .delegate(.closed))) = $0 { return true }; return false }
    #expect(store.state.links[id: older] == nil, "the victim must be removed, not just marked")
    #expect(store.state.links[id: newer]?.status == .active, "the newer responder must be spared")
    #expect(store.state.links[id: newest]?.status == .active,
            "the link whose promotion triggered the eviction must not be its own victim")
    #expect(store.state.links.filter { $0.role == .responder }.count == cap,
            "responder count settles back at the cap after the eviction")
}

/// C1 REGRESSION: a burst of unauthenticated LINKREQUESTs must not cost a single established link.
///
/// The shape this pins closed: while the `maxResponderLinks` cap was enforced in
/// `acceptLinkRequest`, each inbound request evicted an `.active` responder to make room and then
/// parked in the freed slot as a `.handshake` element — which is not evictable, so it held the slot
/// for a full establishment timeout. A burst the size of the cap therefore flushed EVERY
/// established responder link, for an attacker that generates no keypair and holds no key.
///
/// Driven entirely through `acceptLinkRequest` with real packets: nothing is seeded, so the
/// incumbents are genuinely `.active` and genuinely evictable if the plane chose to evict them.
@Test @MainActor func junkLinkRequestBurstDoesNotEvictASingleEstablishedLink() async {
    let owner = Identity()
    let destHash = Data(repeating: 0x33, count: 16)
    let iface = InterfaceID("i")
    let cap = 4
    let store = TestStore(
        initialState: LinkPlane.State(maxResponderLinks: cap)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    // Fill to the active cap with real handshakes.
    var established: [UUID] = []
    for _ in 0 ..< cap {
        established.append(await acceptAndActivateResponder(store, owner: owner,
                                                            destHash: destHash, iface: iface))
    }
    #expect(store.state.links.filter { $0.status == .active }.count == cap)

    // The attack: a burst of LINKREQUESTs whose payloads are not derived from any key.
    for seed in 0 ..< UInt8(cap * 2) {
        await store.send(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                            interfaceID: InterfaceID("attacker"),
                                            data: junkLinkRequest(destHash: destHash, seed: seed)))
        await store.receive { if case .link(.element(_, .acceptRequest)) = $0 { return true }; return false }
    }

    // The junk really is viable — it reaches `.handshake`, which is what made the flush possible.
    // If this ever stops holding, the test below is passing for the wrong reason.
    #expect(store.state.links.contains { $0.status == .handshake },
            "junk requests must still mint .handshake elements, or this test proves nothing")

    for id in established {
        #expect(store.state.links[id: id]?.status == .active,
                "an unauthenticated LINKREQUEST must not be able to close an established link")
    }
    #expect(store.state.links.filter { $0.status == .active }.count == cap,
            "every established link survives the burst")
}

/// F1: an inbound flood is bounded, and never costs us one of our own outbound links.
///
/// Since C1 the flood is bounded by `maxIncompleteResponderLinks`, not by `maxResponderLinks`:
/// nothing in this test ever completes a handshake, so no element leaves `.handshake` and the
/// active cap is never consulted. The name of the property is "a flood cannot grow the plane and
/// cannot reach our own links", not "the active cap binds here".
@Test @MainActor func responderFloodIsBoundedAndNeverCostsUsOurOwnOutboundLink() async {
    let owner = Identity()
    let destHash = Data(repeating: 0x31, count: 16)
    let halfOpenCap = 3
    let store = TestStore(
        initialState: LinkPlane.State(maxResponderLinks: 256,
                                      maxIncompleteResponderLinks: halfOpenCap)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    // One of OUR outbound links. It must survive any amount of inbound pressure.
    await store.send(.openLink(initiatorTo: Identity(), destinationHash: destHash,
                               interfaceID: InterfaceID("i"), relayNextHop: nil))
    let initiatorCount = { store.state.links.filter { $0.role == .initiator }.count }
    #expect(initiatorCount() == 1)

    // Flood well past the bound with distinct, well-formed requests.
    for _ in 0 ..< (halfOpenCap * 4) {
        await store.send(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                            interfaceID: InterfaceID("i"),
                                            data: freshLinkRequest(destHash: destHash)))
    }

    let responders = store.state.links.filter { $0.role == .responder }
    #expect(responders.count <= halfOpenCap)
    // The DoS-amplifier trap: the flood must never cost us our own outbound link.
    #expect(initiatorCount() == 1)
}

/// The half-open bound must bound the ATTACK, not just orderly usage. An attacker floods
/// LINKREQUESTs and never completes a handshake, so every element sits in `.handshake` — where
/// `LinkSession.close` is a no-op. If the plane appended regardless, `links` would grow without
/// bound in exactly the case the bound exists to stop, which is why the guard REFUSES rather than
/// trying to make room.
@Test @MainActor func floodOfIncompleteHandshakesCannotGrowLinksWithoutBound() async {
    let owner = Identity()
    let destHash = Data(repeating: 0x32, count: 16)
    let halfOpenCap = 4
    let store = TestStore(
        initialState: LinkPlane.State(maxIncompleteResponderLinks: halfOpenCap)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    // Every request is well-formed and distinct, but none is ever completed with an RTT,
    // so every element stays in .handshake.
    for _ in 0 ..< (halfOpenCap * 10) {
        await store.send(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                            interfaceID: InterfaceID("i"),
                                            data: freshLinkRequest(destHash: destHash)))
    }
    #expect(store.state.links.count <= halfOpenCap)
}

/// The eviction ORDER is the load-bearing half of the cap. An attacker keeps `lastInbound`
/// fresh with keepalives for free; only `lastData` reflects traffic it could not forge. If
/// eviction ever sorts on `lastInbound`, this test must fail — the attacker's link would
/// survive and the quiet legitimate link would be evicted.
///
/// This test seeds its two INCUMBENTS deliberately — the property under test is the *ordering
/// comparator*, not reachability, and constructing the two clock skews through real traffic would
/// take more machinery than it proves. The promotion that triggers the eviction is still driven
/// through real entry points, because that is the only thing that evicts anything.
@Test @MainActor func evictionPrefersLinksWithNoAuthenticatedTrafficEvenIfRecentlyPinged() async {
    let destHash = Data(repeating: 0x41, count: 16)
    // attacker: pinged very recently (high lastInbound) but never carried data (nil lastData).
    var attacker = LinkSession.State(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
                                     responderFor: Identity(), destinationHash: destHash,
                                     interfaceID: InterfaceID("i"))
    attacker.linkID = Data(repeating: 0xA1, count: 16)
    attacker.status = .active
    attacker.activatedAt = 0
    attacker.lastInbound = 1_000
    attacker.lastData = nil

    // legitimate: quiet lately (low lastInbound) but carried real data (lastData set).
    var legit = LinkSession.State(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
                                  responderFor: Identity(), destinationHash: destHash,
                                  interfaceID: InterfaceID("i"))
    legit.linkID = Data(repeating: 0xB1, count: 16)
    legit.status = .active
    legit.activatedAt = 0
    legit.lastInbound = 10
    legit.lastData = 500

    // The clock sits ABOVE both seeded keys, so the newly promoted link is unambiguously the
    // NEWEST candidate and the choice between the other two is made by the comparator alone.
    let store = TestStore(
        initialState: LinkPlane.State(links: [attacker, legit], maxResponderLinks: 2)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
    }
    store.exhaustivity = .off

    _ = await acceptAndActivateResponder(store, owner: Identity(), destHash: destHash,
                                         iface: InterfaceID("i"))
    // The attacker's link is the victim; the legitimate one is closed on neither count.
    await store.receive { action in
        if case let .link(.element(id, .close)) = action { return id == attacker.id }
        return false
    }
    // Assert the SPARED party too. Under `.off`, `receive(predicate)` skips non-matching actions
    // — so matching the attacker's `.close` alone does not prove `legit` escaped one of its own.
    // `.close` sets `status = .closed` synchronously, so a spared element is still `.active`
    // whether or not its removal has drained.
    #expect(store.state.links[id: legit.id]?.status == .active,
            "the link that carried real data must be spared")
}

/// An inbound flood must never evict one of OUR OWN outbound links. Only responder links are
/// counted and eviction-eligible; dropping the `role == .responder` filter turns the cap into a
/// DoS amplifier, because an attacker can then make us close the links we initiated.
///
/// The incumbents are seeded deliberately: the property under test is the ROLE FILTER, not
/// reachability. The initiator is given a sort key at least as old as every other candidate, so
/// if the role filter is removed it is the element the comparator picks — which is exactly the
/// trap. The promotion that triggers the eviction is driven through real entry points.
@Test @MainActor func evictionNeverChoosesAnInitiatorEvenWhenItIsTheOldest() async {
    let destHash = Data(repeating: 0x42, count: 16)
    // Our own outbound link, older than every responder.
    var ours = LinkSession.State(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!,
                                 initiatorTo: Identity(), destinationHash: destHash,
                                 interfaceID: InterfaceID("i"))
    ours.linkID = Data(repeating: 0xC1, count: 16)
    ours.status = .active
    ours.activatedAt = 0
    ours.lastData = 0

    // A responder with a strictly NEWER sort key, so the role filter is the only thing that can
    // stop the initiator being chosen ahead of it.
    var theirs = LinkSession.State(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!,
                                   responderFor: Identity(), destinationHash: destHash,
                                   interfaceID: InterfaceID("i"))
    theirs.linkID = Data(repeating: 0xC2, count: 16)
    theirs.status = .active
    theirs.activatedAt = 0
    theirs.lastData = 500

    let store = TestStore(
        initialState: LinkPlane.State(links: [ours, theirs], maxResponderLinks: 1)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    _ = await acceptAndActivateResponder(store, owner: Identity(), destHash: destHash,
                                         iface: InterfaceID("i"))
    // The responder is the victim...
    await store.receive { action in
        if case let .link(.element(id, .close)) = action { return id == theirs.id }
        return false
    }
    // ...and our own outbound link is untouched. This is the assertion that dies if the
    // `role == .responder` filter is dropped: the initiator would be closed first, on the
    // strength of its older key.
    #expect(store.state.links[id: ours.id]?.status == .active,
            "an inbound flood must never close one of our own outbound links")
}

/// Drive one NEW initiator element to `.active` through the plane's real entry points: open the
/// link, then answer its LINKREQUEST with a genuine LRPROOF signed by the destination identity the
/// test owns. Returns the element id.
@MainActor
private func openAndActivateInitiator(_ store: TestStore<LinkPlane.State, LinkPlane.Action>,
                                      peer: Identity, destHash: Data, iface: InterfaceID) async -> UUID {
    await store.send(.openLink(initiatorTo: peer, destinationHash: destHash,
                               interfaceID: iface, relayNextHop: nil))
    // `.establish` is an effect; `linkID` is written there, not by `openLink`.
    await store.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    let element = store.state.links.last!
    let proof = Link.buildProof(linkID: element.linkID, responderEphemeral: Identity(),
                                destinationIdentity: peer)
    let packet = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                        destinationType: .link, context: .linkRequestProof, contextFlag: false,
                        hops: 0, destinationHash: element.linkID, transportId: nil, payload: proof)
    await store.send(.routeLinkPacket(linkID: element.linkID, arrivalInterface: iface,
                                      data: try! packet.packed()))
    await store.receive { if case .delegate(.linkEstablished) = $0 { return true }; return false }
    #expect(store.state.links[id: element.id]?.status == .active,
            "helper must actually reach .active, or nothing is being promoted")
    return element.id
}

/// Promoting one of OUR OWN outbound links must neither evict a responder nor be refused, even
/// when the responder population is over its cap and nothing there is evictable.
///
/// This is the DoS-amplifier trap in the shape the promotion handler introduces: the refusal
/// branch closes the element that just established, so without the `promoted.role == .responder`
/// gate an inbound population we cannot evict would make us close a link WE opened, the moment it
/// came up. The incumbents are seeded over the cap and given in-flight transfers so that
/// `evictable` is empty and the refusal branch is the one reached.
@Test @MainActor func promotingOneOfOurOwnLinksIsNeverRefusedByTheResponderCap() async {
    let destHash = Data(repeating: 0x44, count: 16)
    func pinnedResponder(_ tag: UInt8, id: UUID, transferID: UUID) -> LinkSession.State {
        let linkID = Data(repeating: tag, count: 16)
        var s = LinkSession.State(id: id, responderFor: Identity(), destinationHash: destHash,
                                  interfaceID: InterfaceID("i"))
        s.linkID = linkID
        s.status = .active
        s.activatedAt = 0
        s.lastData = 0
        s.transfers.append(ResourceTransfer.State(
            sending: Data(repeating: 0xAB, count: 64), linkID: linkID,
            sessionKey: Data(repeating: 0x00, count: 32), interfaceID: InterfaceID("i"),
            prefix: Data(repeating: 0x00, count: 16), randomHash: Data(repeating: tag, count: 32),
            sdu: 464, id: transferID))
        return s
    }
    let pinnedA = pinnedResponder(0xE1,
                                  id: UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!,
                                  transferID: UUID(uuidString: "00000000-0000-0000-0000-00000000E1DD")!)
    let pinnedB = pinnedResponder(0xE2,
                                  id: UUID(uuidString: "00000000-0000-0000-0000-0000000000E2")!,
                                  transferID: UUID(uuidString: "00000000-0000-0000-0000-00000000E2DD")!)

    let store = TestStore(
        initialState: LinkPlane.State(links: [pinnedA, pinnedB], maxResponderLinks: 1)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    let ours = await openAndActivateInitiator(store, peer: Identity(), destHash: destHash,
                                              iface: InterfaceID("i"))
    // Drain whatever the promotion emitted BEHIND `linkEstablished`. This is load-bearing: under
    // `.off`, `store.send` clears undrained received actions WITHOUT applying them, so a `.close`
    // sitting in the queue would never reach the state the assertion reads.
    // `skipReceivedActions` advances the state instead of discarding it.
    await store.skipReceivedActions(strict: false)
    #expect(store.state.links[id: ours]?.status == .active,
            "promoting our own outbound link must never close it, whatever the responders are doing")
    #expect(store.state.links.filter { $0.role == .responder && $0.status == .active }.count == 2,
            "an initiator promotion must not trim the responder population either")
}

/// A link with an IN-FLIGHT RESOURCE TRANSFER must never be evicted, even when it holds the
/// oldest sort key of any candidate.
///
/// Resource SEGMENT contexts (`.resource`, `.resourceHashmapUpdate`, and friends) forward raw
/// bytes to `ResourceTransfer` children that decrypt internally, so they never advance
/// `lastData` — only `.resourceAdvertisement` does, at transfer START. A link midway through a
/// large transfer therefore looks maximally IDLE to a `lastData`-only comparator, which is
/// precisely when evicting it is most wasteful.
///
/// The incumbents are seeded deliberately: the property under test is the `transfers.isEmpty`
/// filter outranking the sort key, not reachability. The promotion that triggers the eviction is
/// driven through real entry points.
@Test @MainActor func evictionSkipsALinkWithAnInFlightTransferEvenWhenItIsTheOldest() async {
    let destHash = Data(repeating: 0x43, count: 16)
    let busyLinkID = Data(repeating: 0xD1, count: 16)
    // Mid-transfer: the OLDEST key of the two, so only the transfers filter can spare it.
    var busy = LinkSession.State(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!,
                                 responderFor: Identity(), destinationHash: destHash,
                                 interfaceID: InterfaceID("i"))
    busy.linkID = busyLinkID
    busy.status = .active
    busy.activatedAt = 0
    busy.lastData = 0
    busy.transfers.append(ResourceTransfer.State(
        sending: Data(repeating: 0xAB, count: 64),
        linkID: busyLinkID,
        sessionKey: Data(repeating: 0x00, count: 32),
        interfaceID: InterfaceID("i"),
        prefix: Data(repeating: 0x00, count: 16),
        randomHash: Data(repeating: 0x01, count: 32),
        sdu: 464,
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000DD")!
    ))

    // Idle but strictly NEWER: this is the correct victim.
    var quiet = LinkSession.State(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!,
                                  responderFor: Identity(), destinationHash: destHash,
                                  interfaceID: InterfaceID("i"))
    quiet.linkID = Data(repeating: 0xD2, count: 16)
    quiet.status = .active
    quiet.activatedAt = 0
    quiet.lastData = 500

    let store = TestStore(
        initialState: LinkPlane.State(links: [busy, quiet], maxResponderLinks: 2)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    _ = await acceptAndActivateResponder(store, owner: Identity(), destHash: destHash,
                                         iface: InterfaceID("i"))
    // The idle link is evicted despite having the NEWER key — the transfers filter outranks
    // the comparator.
    await store.receive { action in
        if case let .link(.element(id, .close)) = action { return id == quiet.id }
        return false
    }
    #expect(store.state.links[id: busy.id]?.status == .active,
            "a link with an in-flight transfer must never be evicted mid-transfer")
}

// MARK: - Unauthenticated re-home permission (Task 6)

/// A LOCAL interface disconnect grants ONE unauthenticated re-home, so an idle BLE link whose
/// peer reconnects is not stranded on a dead interface. An attacker cannot forge a local
/// disconnect. The permission is one-shot: a second unauthenticated move must not follow.
@Test @MainActor func localDisconnectGrantsExactlyOneUnauthenticatedReHome() async {
    let dead = InterfaceID("dead")
    let reconnected = InterfaceID("reconnected")
    let attacker = InterfaceID("attacker")
    let linkID = Data(repeating: 0x51, count: 16)
    var session = LinkSession.State(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!,
                                    responderFor: Identity(),
                                    destinationHash: Data(repeating: 0x05, count: 16),
                                    interfaceID: dead)
    session.linkID = linkID
    session.status = .active

    let store = TestStore(
        initialState: LinkPlane.State(links: [session])
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    let keepalive = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                           destinationType: .link, context: .keepalive, contextFlag: false, hops: 0,
                           destinationHash: linkID, transportId: nil, payload: Data([0xFF]))
    let kaRaw = try! keepalive.packed()

    // Without a disconnect, an unauthenticated keepalive must not move the link.
    await store.send(.routeLinkPacket(linkID: linkID, arrivalInterface: attacker, data: kaRaw))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.links[id: session.id]?.interfaceID == dead)

    // A local disconnect grants the permission; the next keepalive re-homes.
    await store.send(.interfaceDisconnected(dead))
    await store.send(.routeLinkPacket(linkID: linkID, arrivalInterface: reconnected, data: kaRaw))
    // The re-home and the keepalive reply both emit effects; drain the transmit delegate so the
    // state update from the child reducer is visible before we read interfaceID.
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.links[id: session.id]?.interfaceID == reconnected)

    // One-shot: a further unauthenticated keepalive from elsewhere must NOT move it again.
    await store.send(.routeLinkPacket(linkID: linkID, arrivalInterface: attacker, data: kaRaw))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.links[id: session.id]?.interfaceID == reconnected)
}

/// The grant must survive ordinary SAME-interface traffic. `arrival != state.interfaceID` guards
/// the consumption as well as the re-home, so a keepalive arriving on the interface the link is
/// already bound to must not burn the permission — otherwise the first packet after a disconnect
/// would spend the grant and the reconnecting peer, arriving second, would still be stranded.
/// Pinned directly (rather than via a spurious `.rehomed`) because that is the failure mode.
@Test @MainActor func samePathTrafficDoesNotConsumeTheReHomePermission() async {
    let dead = InterfaceID("dead")
    let reconnected = InterfaceID("reconnected")
    let linkID = Data(repeating: 0x52, count: 16)
    var session = LinkSession.State(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!,
                                    responderFor: Identity(),
                                    destinationHash: Data(repeating: 0x06, count: 16),
                                    interfaceID: dead)
    session.linkID = linkID
    session.status = .active

    let store = TestStore(
        initialState: LinkPlane.State(links: [session])
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    let keepalive = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                           destinationType: .link, context: .keepalive, contextFlag: false, hops: 0,
                           destinationHash: linkID, transportId: nil, payload: Data([0xFF]))
    let kaRaw = try! keepalive.packed()

    await store.send(.interfaceDisconnected(dead))
    #expect(store.state.links[id: session.id]?.rehomePermitted == true)

    // Ordinary traffic on the interface the link is ALREADY bound to. No re-home is possible here,
    // so the grant must be left intact.
    await store.send(.routeLinkPacket(linkID: linkID, arrivalInterface: dead, data: kaRaw))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.links[id: session.id]?.interfaceID == dead)
    #expect(store.state.links[id: session.id]?.rehomePermitted == true,
            "same-interface traffic must not consume the one-shot re-home permission")

    // The grant is still spendable: the reconnecting peer's unauthenticated keepalive re-homes.
    await store.send(.routeLinkPacket(linkID: linkID, arrivalInterface: reconnected, data: kaRaw))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.links[id: session.id]?.interfaceID == reconnected)
    #expect(store.state.links[id: session.id]?.rehomePermitted == false)
}

// MARK: - Characterization tests for the three residuals accepted by this slice (Task 8)
//
// These pin DELIBERATE CURRENT BEHAVIOUR, not desired behaviour. Each one exists so that the
// residual is carried by an executable assertion rather than by a comment: two commits in this
// slice turned on a comment surviving an edit, and one residual was lost when a comment block
// was deleted. If you are here because one of these went red, you have most likely FIXED the
// residual — read the referenced handoff item, then delete or invert the test deliberately.
//
// Handoff: docs/superpowers/2026-08-10-handoff-link-lifecycle-and-delivery-termination.md
// Sweep:   docs/superpowers/2026-08-13-unauthenticated-link-element-sweep.md

/// **F9 — link traffic has no per-packet replay rejection, anywhere in the link path.**
///
/// `Transport` dispatches `.delegate(.linkPacket(...))` before `seenPacketHashes.insert(...)`
/// (deliberately — byte-identical keepalives share a packet hash and must not be deduped), and
/// `LinkSession` adds no dedup of its own: it keeps no inbound packet-hash SET, so nothing there
/// remembers that a packet has been seen. So the same ciphertext decrypts, and is acted on,
/// however many times it arrives and from wherever.
///
/// State that precisely. The tempting shorthand — "every `packetHash` use there is outbound-keyed"
/// — is FALSE: `(_, .active, .data, .none)` surfaces the INBOUND `packet.packetHash` via
/// `.dataReceived(data:packetHash:)`, and `.provePacket(packetHash:)` signs that inbound value.
/// Only `pendingDataReceipts` is outbound-keyed. Inbound hashes are computed and used; they are
/// never RETAINED for comparison, and retention is the property that matters.
///
/// This test pins the consequence that bounds Task 5's re-home gate. That gate establishes that a
/// packet ORIGINATED from a holder of the session key — not that the party which just sent it
/// holds one. Replaying captured bytes therefore still moves the binding: the vector was narrowed
/// from "observe a cleartext linkID" to "capture one authenticated packet", not closed.
///
/// The second delivery is the load-bearing half. An end-state-only assertion on `interfaceID`
/// would also pass if the plane re-homed on the FIRST packet and merely failed to move back, so
/// the test asserts that the replayed bytes are processed as a fresh packet each time.
@Test @MainActor func replayedAuthenticatedLinkPacketIsProcessedAgainAndMovesTheBinding() async {
    let ifOriginal = InterfaceID("original")
    let ifReplay = InterfaceID("replay")
    let destHash = Data(repeating: 0x61, count: 16)
    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    let session = await activeResponderInPlane(store, owner: Identity(),
                                               destHash: destHash, interfaceID: ifOriginal)
    // ONE authenticated packet. Every later send reuses these exact bytes — nothing is re-encrypted,
    // so this is a capture-and-replay, not a second legitimate transmission.
    let raw = authenticatedPacket(linkID: session.linkID, sessionKey: session.sessionKey,
                                  body: Data([0x10, 0x11]))

    await store.send(.routeLinkPacket(linkID: session.linkID, arrivalInterface: ifOriginal, data: raw))
    await store.receive { if case .delegate(.linkDataReceived) = $0 { return true }; return false }
    #expect(store.state.links[id: session.id]?.interfaceID == ifOriginal)

    // Same bytes, different interface. Currently: delivered AGAIN, and the link re-homes.
    await store.send(.routeLinkPacket(linkID: session.linkID, arrivalInterface: ifReplay, data: raw))
    await store.receive { if case .delegate(.linkDataReceived) = $0 { return true }; return false }
    #expect(store.state.links[id: session.id]?.interfaceID == ifReplay,
            "no inbound replay rejection exists on the link path, so replayed bytes still re-home")

    // And again, back the other way: replay is not a one-shot. A dedup that remembered only the
    // most recent packet would pass the step above and fail here.
    await store.send(.routeLinkPacket(linkID: session.linkID, arrivalInterface: ifOriginal, data: raw))
    await store.receive { if case .delegate(.linkDataReceived) = $0 { return true }; return false }
    #expect(store.state.links[id: session.id]?.interfaceID == ifOriginal)
}

/// **F10 — the local-disconnect re-home grant is spent by whichever interface speaks first.**
///
/// `LinkPlane.interfaceDisconnected` sets `rehomePermitted` on every link bound to the departing
/// interface, and `LinkSession`'s re-home block consumes it on the first link-addressed packet
/// from any interface other than the stored one. The TRIGGER is unforgeable — a remote attacker
/// cannot cause a local interface to disconnect — but the CONSUMPTION is not authenticated at all:
/// the reducer sees only `arrivalInterface`, so it cannot tell the reconnecting peer from anyone
/// else. `BLEEndpoint.State.peerInterfaces` is a multi-peer map and every peer's link packets reach
/// `routeLinkPacket` tagged with that peer's `InterfaceID`, so a second connected peer that has
/// merely observed the cleartext `linkID` is in a position to claim the grant first.
///
/// This is inherent to the chosen design (authenticate, or spend a local-disconnect grant). The
/// alternative considered — closing every link on a local disconnect — aborts in-flight transfers
/// on every reconnect, which is worse. It is bounded to one re-home per disconnect. It is NOT
/// usefully bounded by the inactivity watchdog: the re-arm below `dispatch` fires for ANY packet
/// bearing the cleartext linkID while the link is `.active`, so the same party that spends the
/// grant can hold the element open indefinitely with undecryptable junk (see F16 in the handoff).
/// Nothing clears `rehomePermitted` except the re-home that spends it, so the grant does not
/// expire either.
///
/// `localDisconnectGrantsExactlyOneUnauthenticatedReHome` already pins the one-shot property when
/// the RIGHT party spends it. What is pinned here is who may spend it, and that the party the
/// grant was issued for is then stranded.
///
/// The last phase pins the half the original write-up missed: `interfaceDisconnected` does not
/// filter on role, so the grant is issued to INITIATOR links — links WE opened — on exactly the
/// same terms. After a local disconnect, one unauthenticated packet from a foreign interface
/// re-homes one of our own outbound links. That is deliberate rather than an oversight, and the
/// reason is recorded at `LinkPlane.interfaceDisconnected`: our outbound links go stale on the same
/// event, their peer is the responder and so never initiates a keepalive of its own, and a peer
/// mid-transfer to us sends only segments, which never set `sawAuthenticatedData`. Restricting the
/// grant to responders would strand those links until they time out.
@Test @MainActor func theReHomeGrantIsSpentByWhicheverInterfaceSpeaksFirst() async {
    let dead = InterfaceID("dead")
    let firstToSpeak = InterfaceID("first-to-speak")
    let returningPeer = InterfaceID("returning-peer")
    let linkID = Data(repeating: 0x62, count: 16)
    var session = LinkSession.State(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!,
                                    responderFor: Identity(),
                                    destinationHash: Data(repeating: 0x07, count: 16),
                                    interfaceID: dead)
    session.linkID = linkID
    session.status = .active

    // One of OUR OWN outbound links, on the same departing interface.
    let oursLinkID = Data(repeating: 0x64, count: 16)
    var ours = LinkSession.State(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!,
                                 initiatorTo: Identity(),
                                 destinationHash: Data(repeating: 0x08, count: 16),
                                 interfaceID: dead)
    ours.linkID = oursLinkID
    ours.status = .active

    let store = TestStore(
        initialState: LinkPlane.State(links: [session, ours])
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    let keepalive = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                           destinationType: .link, context: .keepalive, contextFlag: false, hops: 0,
                           destinationHash: linkID, transportId: nil, payload: Data([0xFF]))
    let kaRaw = try! keepalive.packed()

    await store.send(.interfaceDisconnected(dead))
    #expect(store.state.links[id: session.id]?.rehomePermitted == true)
    #expect(store.state.links[id: ours.id]?.rehomePermitted == true,
            "the grant is not filtered by role: our own outbound links receive it too")

    // The grant was issued so a reconnecting peer could recover. It is claimed by whoever sends
    // the first off-path link packet — no authentication is required or checked.
    await store.send(.routeLinkPacket(linkID: linkID, arrivalInterface: firstToSpeak, data: kaRaw))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.links[id: session.id]?.interfaceID == firstToSpeak)
    #expect(store.state.links[id: session.id]?.rehomePermitted == false)

    // The party the grant was meant for now cannot recover: with the one-shot spent, its own
    // unauthenticated keepalive no longer moves the binding.
    await store.send(.routeLinkPacket(linkID: linkID, arrivalInterface: returningPeer, data: kaRaw))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.links[id: session.id]?.interfaceID == firstToSpeak,
            "the grant is one-shot and is not reserved for the peer it was issued for")

    // Same story on OUR OWN outbound link. The payload is `0xFE`, the responder's keepalive reply,
    // because a `0xFF` on an initiator link is dropped as our own loopback at the top of
    // `LinkSession.received` before the re-home block is reached. Nothing about these bytes is
    // authenticated — the link carries no session key at all here.
    let reply = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                       destinationType: .link, context: .keepalive, contextFlag: false, hops: 0,
                       destinationHash: oursLinkID, transportId: nil, payload: Data([0xFE]))
    await store.send(.routeLinkPacket(linkID: oursLinkID, arrivalInterface: firstToSpeak,
                                      data: try! reply.packed()))
    await store.receive { if case .link(.element(_, .received)) = $0 { return true }; return false }
    #expect(store.state.links[id: ours.id]?.interfaceID == firstToSpeak,
            "after a local disconnect an unauthenticated packet re-homes one of OUR OWN links")
    #expect(store.state.links[id: ours.id]?.rehomePermitted == false)
}

/// Builds an encrypted RESOURCE_ADV link packet for `linkID` announcing `resourceHash`.
/// Constructed directly rather than driven out of a sender `ResourceTransfer`, because what
/// matters here is only that `ResourceAdvertisement.unpack` accepts it and that the hash differs
/// between calls.
private func advertisementPacket(linkID: Data, sessionKey: Data, resourceHash: Data) -> Data {
    let adv = ResourceAdvertisement(
        transferSize: 512, dataSize: 512, numberOfParts: 2,
        hash: resourceHash, randomHash: Data(repeating: 0x01, count: 32),
        originalHash: resourceHash, segmentIndex: 1, totalSegments: 1,
        requestID: nil, flags: 0x01, hashmap: Data(repeating: 0x02, count: 8))
    let cipher = Link.encrypt(adv.pack(), sessionKey: sessionKey)
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .link, context: .resourceAdvertisement, contextFlag: false,
                        hops: 0, destinationHash: linkID, transportId: nil, payload: cipher)
    return try! packet.packed()
}

/// **F11 — a stalled advertiser is now an eviction candidate; genuine in-progress transfers stay immune.**
///
/// `LinkSession`'s `(_, .active, .data, .resourceAdvertisement)` branch appends to
/// `state.transfers` after decrypt, unpack and a SAME-hash dedup only, so DISTINCT-hash
/// advertisements append without bound. Under the old filter (`transfers.isEmpty`), any non-empty
/// `transfers` conferred full eviction immunity — so a peer that advertises and never sends a
/// segment became permanently immune.
///
/// The fix (Fix #1 of F11): `transfers.allSatisfy { $0.role == .receiver && !$0.receivedFirstPart }`.
/// A link is immune when any transfer is either sender-role (always progressing) or a receiver that
/// has received at least one part, distinguishing genuine progress from a bare advertisement.
@Test @MainActor func stalledAdvertiserIsEvictedNotThePinnedNewcomer() async {
    let owner = Identity()
    let destHash = Data(repeating: 0x63, count: 16)
    let iface = InterfaceID("advertiser")
    let store = TestStore(
        initialState: LinkPlane.State(maxResponderLinks: 1)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    let session = await activeResponderInPlane(store, owner: owner,
                                               destHash: destHash, interfaceID: iface)

    // Three DISTINCT-hash advertisements, no segment ever sent → three no-parts transfers.
    for i: UInt8 in 1 ... 3 {
        let adv = advertisementPacket(linkID: session.linkID, sessionKey: session.sessionKey,
                                      resourceHash: Data(repeating: i, count: 32))
        await store.send(.routeLinkPacket(linkID: session.linkID, arrivalInterface: iface, data: adv))
        await store.receive { if case .link(.element(_, .received)) = $0 { return true }; return false }
    }
    #expect(store.state.links[id: session.id]?.transfers.count == 3)

    // A newcomer completes a full handshake at the cap. Because none of the advertiser's transfers
    // has received a part, the advertiser is now the eviction candidate — it is closed, not the
    // newcomer.
    let newcomer = await acceptAndActivateResponder(store, owner: owner, destHash: destHash,
                                                    iface: InterfaceID("newcomer"))
    await store.receive { action in
        if case let .link(.element(id, .close)) = action { return id == session.id }
        return false
    }
    #expect(store.state.links[id: session.id]?.status != .active,
            "a stalled advertiser must be evicted, not immune")
    #expect(store.state.links[id: newcomer]?.status == .active,
            "the newcomer that paid for a handshake keeps the slot")
}

/// Guard test: a transfer that has received a part confers genuine immunity.
///
/// Seeds link A (active responder, one transfer with `receivedFirstPart == true`) and link B
/// (active responder, no transfers). A newcomer promotes at cap 2, forcing an eviction. Because
/// link A's transfer has received a part, it is immune; link B — the bare link — is the victim.
///
/// This test is expected to PASS before and after Fix #1. Its role is to confirm the fix does not
/// over-evict: a link genuinely mid-transfer must never be displaced.
@Test @MainActor func aTransferThatReceivedAPartIsNotEvicted() async {
    let iface = InterfaceID("seed")
    // Link A: active responder, holds a transfer that has received a part → immune.
    var linkA = LinkSession.State(id: UUID(1), responderFor: Identity(),
                                  destinationHash: Data(repeating: 0x0A, count: 16), interfaceID: iface)
    linkA.status = .active
    linkA.sessionKey = Data(repeating: 0x01, count: 64)
    linkA.linkID = Data(repeating: 0xAA, count: 16)
    linkA.activatedAt = 10          // older than link B, so a naive LRU would pick A
    var partTransfer = ResourceTransfer.State(receivingOn: linkA.linkID, sessionKey: linkA.sessionKey,
                                              interfaceID: iface, rtt: .seconds(1), id: UUID(101))
    partTransfer.receivedFirstPart = true
    linkA.transfers.append(partTransfer)

    // Link B: active responder, bare (no transfers) → evictable.
    var linkB = LinkSession.State(id: UUID(2), responderFor: Identity(),
                                  destinationHash: Data(repeating: 0x0B, count: 16), interfaceID: iface)
    linkB.status = .active
    linkB.sessionKey = Data(repeating: 0x02, count: 64)
    linkB.linkID = Data(repeating: 0xBB, count: 16)
    linkB.activatedAt = 20

    let owner = Identity()
    let destHash = Data(repeating: 0x63, count: 16)
    let store = TestStore(
        initialState: LinkPlane.State(links: [linkA, linkB], maxResponderLinks: 2)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    let newcomer = await acceptAndActivateResponder(store, owner: owner, destHash: destHash,
                                                    iface: InterfaceID("newcomer"))
    await store.receive { action in
        if case let .link(.element(id, .close)) = action { return id == linkB.id }
        return false
    }
    #expect(store.state.links[id: linkA.id]?.status == .active,
            "a link with a part-receiving transfer must stay immune, even as the oldest link")
    #expect(store.state.links[id: newcomer]?.status == .active)
}

@Test @MainActor func registerThenDeregisterMutatesPlaneRegistrations() async {
    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    let ph = Crypto.truncatedHash(Data("svc/echo".utf8))
    await store.send(.registerRequestHandler(path: "svc/echo", policy: .all)) {
        $0.registrations[ph] = RequestRegistration(path: "svc/echo", policy: .all)
    }
    await store.send(.deregisterRequestHandler(path: "svc/echo")) {
        $0.registrations[ph] = nil
    }
}

/// **F11 Fix #2 — a resource advertisement must not advance the eviction clock.**
///
/// `lastData` is the LRU key used to pick the eviction victim. An advertisement authenticates
/// (so re-home is unchanged) but is NOT genuine use of the slot. If an advertisement advanced
/// `lastData`, a stalled re-advertiser would look "recently active" and outrank quiet legitimate
/// peers in the eviction LRU — eliminating Fix #1's benefit.
///
/// This test uses a mutable date box so "advanced" vs "unchanged" is observable:
/// the clock is at 100 when the advertisement arrives (lastData must NOT move to 500),
/// then at 900 when genuine application data arrives (lastData MUST move to 900).
@Test @MainActor func advertisementDoesNotAdvanceLastDataButGenuineDataDoes() async {
    let owner = Identity()
    let destHash = Data(repeating: 0x71, count: 16)
    let iface = InterfaceID("clock")
    let dateBox = LockIsolated(Date(timeIntervalSince1970: 100))
    let store = TestStore(
        initialState: LinkPlane.State(maxResponderLinks: 4)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .init { dateBox.value }
    }
    store.exhaustivity = .off

    let session = await activeResponderInPlane(store, owner: owner,
                                               destHash: destHash, interfaceID: iface)

    // Advance the clock, then deliver an advertisement. lastData must NOT move to this time.
    dateBox.setValue(Date(timeIntervalSince1970: 500))
    let before = store.state.links[id: session.id]?.lastData
    let adv = advertisementPacket(linkID: session.linkID, sessionKey: session.sessionKey,
                                  resourceHash: Data(repeating: 0x01, count: 32))
    await store.send(.routeLinkPacket(linkID: session.linkID, arrivalInterface: iface, data: adv))
    await store.receive { if case .link(.element(_, .received)) = $0 { return true }; return false }
    #expect(store.state.links[id: session.id]?.lastData == before,
            "an advertisement must not advance the eviction clock")

    // Advance again, then deliver genuine application data. lastData MUST move to this time.
    dateBox.setValue(Date(timeIntervalSince1970: 900))
    let data = authenticatedPacket(linkID: session.linkID, sessionKey: session.sessionKey,
                                   body: Data([0x01, 0x02]))
    await store.send(.routeLinkPacket(linkID: session.linkID, arrivalInterface: iface, data: data))
    await store.receive { if case .delegate(.linkDataReceived) = $0 { return true }; return false }
    #expect(store.state.links[id: session.id]?.lastData == 900,
            "genuine application data must advance the eviction clock")
}

/// **F11 Fix #2 — self-reap: a no-parts transfer is reaped by ITS OWN watchdog while the link lives.**
///
/// This is the property F11 relies on under a CONTINUOUS re-advertising / traffic attack: the link
/// stays alive (its inactivity timer keeps getting reset by inbound traffic), so the ONLY thing that
/// can remove a stalled transfer is the transfer's own receiver watchdog — NOT link teardown.
///
/// The distinction matters. The link's inactivity timer (`staleTime` = 60s at rtt≈0, where the
/// configured 30s floor wins over the RTT-derived 5s keepalive cadence)
/// fires BEFORE the receiver watchdog's full 16-retry budget (~72.25s at rtt≈0: the initial arm
/// plus arms for retriesLeft 15…0 sum to Σ_{k=0}^{16}(0.25 + 0.5k) = 17·0.25 + 0.5·136 = 72.25s).
/// So a single large clock advance tears the whole link down and would let a broken transfer-removal
/// path pass silently. To prove the WATCHDOG reaps the transfer, this test keeps the link alive by
/// injecting a genuine `.data/.none` packet before each sub-`staleTime` clock step — that resets the
/// link's inactivity timer but does NOT touch the transfer's separate `CancelID.watchdog`, so the
/// watchdog budget still elapses. The assertion then witnesses the transfer removed WHILE the link
/// is still present.
///
/// Expected: PASS before the Fix #2 production change (characterization test — no production change
/// to the watchdog or the stale timer).
///
/// Discrimination (mutation reasoning, not applied to production): the assertion requires
/// `links[id:] != nil` AND `transfers.isEmpty`. Because the link is deliberately kept alive, a
/// broken `.receiverDeadline → .failed → transfers.remove` path would leave `transfers.count == 1`
/// and the second `#expect` would fail — so this cannot pass via link teardown.
@Test @MainActor func aStalledTransferSelfReapsAfterItsWatchdogExhausts() async {
    let owner = Identity()
    let destHash = Data(repeating: 0x72, count: 16)
    let iface = InterfaceID("reap")
    let clock = TestClock()
    let store = TestStore(
        initialState: LinkPlane.State(maxResponderLinks: 4)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    let session = await activeResponderInPlane(store, owner: owner,
                                               destHash: destHash, interfaceID: iface)
    let adv = advertisementPacket(linkID: session.linkID, sessionKey: session.sessionKey,
                                  resourceHash: Data(repeating: 0x01, count: 32))
    await store.send(.routeLinkPacket(linkID: session.linkID, arrivalInterface: iface, data: adv))
    await store.receive { if case .link(.element(_, .received)) = $0 { return true }; return false }
    #expect(store.state.links[id: session.id]?.transfers.count == 1)

    // No SEGMENT ever arrives, so the transfer's receiver watchdog keeps retrying and eventually
    // exhausts at ~72.25s. Keep the LINK alive across that budget by injecting a genuine data packet
    // before each sub-staleTime (60s) step: genuine link data resets the link's inactivity timer but
    // does not reset the transfer's own watchdog. Two 50s steps (100s total ≫ 72.25s budget) exhaust
    // the watchdog while every gap stays under 60s, so the link never times out.
    let genuine = authenticatedPacket(linkID: session.linkID, sessionKey: session.sessionKey,
                                      body: Data([0x01, 0x02]))
    for _ in 0 ..< 2 {
        await store.send(.routeLinkPacket(linkID: session.linkID, arrivalInterface: iface, data: genuine))
        await store.receive { if case .delegate(.linkDataReceived) = $0 { return true }; return false }
        await clock.advance(by: .seconds(50))
        await store.skipReceivedActions(strict: false)
    }

    // The LINK is still present (its inactivity timer was reset by the genuine traffic), yet the
    // stalled transfer has been removed — proving the transfer's OWN watchdog reaped it, not link
    // teardown.
    #expect(store.state.links[id: session.id] != nil,
            "the link must still be alive — its inactivity timer was reset by genuine traffic")
    #expect(store.state.links[id: session.id]?.transfers.isEmpty == true,
            "a no-parts transfer must be reaped by its own receiver watchdog while the link lives")
}

// MARK: - F4: unguarded public sign paths must not crash on a keyless identity

/// `LinkPlane.acceptLinkRequest` is public API. A direct-composition caller that passes an owner
/// with no private key (an `Identity(publicKey:)`) must be REFUSED, not crash inside `Identity.sign`
/// while building the LRPROOF — the only `preconditionFailure` in `Sources`. The endpoints already
/// guard `owner.privateKey != nil` before forwarding (TransportEndpoint's `.linkRequest` handler);
/// the plane, being public, must guard too.
@Test @MainActor func acceptLinkRequestWithAKeylessOwnerIsRefusedNotCrashed() async {
    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    let full = Identity()
    let destHash = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                               identity: full)!.hash
    let keylessOwner = Identity(publicKey: full.publicKey)!
    await store.send(.acceptLinkRequest(owner: keylessOwner, destinationHash: destHash,
                                        interfaceID: ifA, data: freshLinkRequest(destHash: destHash)))
    #expect(store.state.links.isEmpty,
            "a keyless owner cannot sign a proof, so no responder element may be minted")
}

/// `LinkPlane.identifyOverLink` is public API and reaches `Identity.sign` on an active initiator
/// link (`LinkSession.identify`). A keyless identity must be refused, not crash. Same shape as the
/// `acceptLinkRequest` guard above; the handoff (F4) says to fix both together.
@Test @MainActor func identifyOverLinkWithAKeylessIdentityIsRefusedNotCrashed() async {
    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    let destHash = Data(repeating: 0x07, count: 16)
    let id = await openAndActivateInitiator(store, peer: Identity(), destHash: destHash, iface: ifA)
    let linkID = store.state.links[id: id]!.linkID
    let keyless = Identity(publicKey: Identity().publicKey)!
    await store.send(.identifyOverLink(linkID: linkID, identity: keyless))
    #expect(store.state.links[id: id]?.status == .active,
            "the link is untouched; identify is refused before it can sign")
}

/// Third path to `Identity.sign`, found by whole-branch review of the F4 fix: `provePacketOverLink`
/// signs with the link's `owningIdentity` (`LinkSession.provePacket`). A responder link whose owner
/// has no private key — constructible directly, since `LinkSession.State(responderFor:)` and its
/// `status`/`linkID` are public — must be refused, not crash. `acceptLinkRequest`'s guard cannot
/// cover this: the owner is read from session state here, not passed to the action.
@Test @MainActor func provePacketOverLinkWithAKeylessOwnerIsRefusedNotCrashed() async {
    let keyless = Identity(publicKey: Identity().publicKey)!
    let linkID = Data(repeating: 0x09, count: 16)
    var link = LinkSession.State(responderFor: keyless, destinationHash: Data(repeating: 0x01, count: 16),
                                 interfaceID: ifA)
    link.linkID = linkID
    link.status = .active
    let store = TestStore(initialState: LinkPlane.State(links: [link])) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    await store.send(.provePacketOverLink(linkID: linkID, packetHash: Data(repeating: 0xAB, count: 16)))
    #expect(store.state.links.count == 1, "proving is refused before it can sign; the link is untouched")
}
