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

/// Verify that every `LinkPlane.Action` case round-trips through `TCPEndpoint`'s `linkPlaneRoute`
/// alias: `linkPlaneRoute.extract(from: linkPlaneRoute.embed(a)) == a`.
///
/// This is a structural test: if the bijection ever mis-maps a case (e.g. routes `.openLink`
/// through the wrong embed branch, or forgets a case in `extract`), at least one assertion
/// below will fail.  Fourteen cases are checked — one representative value per case.
@Test func linkPlaneRouteCasePathRoundTripsEveryPlaneAction() {
    let route = TCPEndpoint.Action.allCasePaths.linkPlaneRoute

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
    #expect(roundTrips(.delegate(.resourceFailed(linkID: linkID, resourceHash: Data(repeating: 0x08, count: 16)))))
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

/// Drive one NEW responder element all the way to `.active` through the plane's real entry
/// points, and return its element id.
///
/// This matters because a responder activates only via `(.responder, .handshake, .data,
/// .linkRequestRTT)`. A test that merely floods `acceptLinkRequest` leaves every element in
/// `.handshake`, where nothing is evictable — so the cap binds by REFUSAL and the eviction path
/// never runs. Feeding the LRRTT back through `routeLinkPacket` (which is how Transport delivers
/// it) is what makes eviction reachable at all.
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
/// Every other cap test drives elements that never reach `.active`, so the cap binds by refusal
/// and `for victim in evictable` never executes. This is the only test in which it does — a
/// `fatalError` inside that loop traps here and nowhere else.
@Test @MainActor func evictionClosesTheOldestResponderAndCountSettlesAtTheCap() async {
    let owner = Identity()
    let destHash = Data(repeating: 0x51, count: 16)
    let iface = InterfaceID("i")
    let cap = 2
    // A mutable clock box so each activation lands at a distinct `activatedAt`; under a constant
    // date every stamp is 0 and "oldest" would be decided by sort stability, not by the key.
    let seconds = LockIsolated(0.0)
    let store = TestStore(
        initialState: LinkPlane.State(maxResponderLinks: cap)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .init { Date(timeIntervalSince1970: seconds.value) }
    }
    store.exhaustivity = .off

    // Two ACTIVE responders. `older` activates first, so it carries the smaller sort key —
    // neither ever carries data, so the key falls back to `activatedAt`.
    seconds.setValue(100)
    let older = await acceptAndActivateResponder(store, owner: owner, destHash: destHash, iface: iface)
    seconds.setValue(200)
    let newer = await acceptAndActivateResponder(store, owner: owner, destHash: destHash, iface: iface)
    #expect(store.state.links.filter { $0.role == .responder }.count == cap)

    // At the cap with something evictable, the next request must EVICT rather than refuse.
    seconds.setValue(300)
    await store.send(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                        interfaceID: iface, data: freshLinkRequest(destHash: destHash)))
    await store.receive { action in
        if case let .link(.element(id, .close)) = action { return id == older }
        return false
    }
    // Eviction must REMOVE, not merely mark: the element leaves through the `.closed` delegate,
    // which is the path that also reaps its transfers.
    await store.receive { if case .link(.element(_, .delegate(.closed))) = $0 { return true }; return false }
    #expect(store.state.links[id: older] == nil, "the victim must be removed, not just marked")
    #expect(store.state.links[id: newer]?.status == .active, "the newer responder must be spared")
    #expect(store.state.links.filter { $0.role == .responder }.count == cap,
            "responder count settles back at the cap after the eviction")
}

/// F1: responder links are capped. An attacker completes real handshakes and holds elements
/// forever, so authentication cannot bound this — only resource policy can.
@Test @MainActor func responderLinksAreCappedAndInitiatorLinksAreNeverEvicted() async {
    let owner = Identity()
    let destHash = Data(repeating: 0x31, count: 16)
    let cap = 3
    let store = TestStore(
        initialState: LinkPlane.State(maxResponderLinks: cap)
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

    // Flood well past the cap with distinct, well-formed requests.
    for _ in 0 ..< (cap * 4) {
        await store.send(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                            interfaceID: InterfaceID("i"),
                                            data: freshLinkRequest(destHash: destHash)))
    }

    let responders = store.state.links.filter { $0.role == .responder }
    #expect(responders.count <= cap)
    // The DoS-amplifier trap: the flood must never cost us our own outbound link.
    #expect(initiatorCount() == 1)
}

/// The cap must bound the ATTACK, not just orderly usage. An attacker floods LINKREQUESTs and
/// never completes a handshake, so every element sits in .handshake — where `LinkSession.close`
/// is a no-op. If the plane appended regardless, `links` would grow without bound in exactly the
/// case the cap exists to stop.
@Test @MainActor func floodOfIncompleteHandshakesCannotGrowLinksWithoutBound() async {
    let owner = Identity()
    let destHash = Data(repeating: 0x32, count: 16)
    let cap = 4
    let store = TestStore(
        initialState: LinkPlane.State(maxResponderLinks: cap)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    // Every request is well-formed and distinct, but none is ever completed with an RTT,
    // so every element stays in .handshake and none is evictable.
    for _ in 0 ..< (cap * 10) {
        await store.send(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                            interfaceID: InterfaceID("i"),
                                            data: freshLinkRequest(destHash: destHash)))
    }
    #expect(store.state.links.count <= cap)
}

/// The eviction ORDER is the load-bearing half of the cap. An attacker keeps `lastInbound`
/// fresh with keepalives for free; only `lastData` reflects traffic it could not forge. If
/// eviction ever sorts on `lastInbound`, this test must fail — the attacker's link would
/// survive and the quiet legitimate link would be evicted.
///
/// This test seeds state deliberately — the property under test is the *ordering comparator*,
/// not reachability, and constructing the two clock skews through real traffic would take more
/// machinery than it proves. A future reader should NOT "fix" this into the reachability style.
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

    let store = TestStore(
        initialState: LinkPlane.State(links: [attacker, legit], maxResponderLinks: 2)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.acceptLinkRequest(owner: Identity(), destinationHash: destHash,
                                        interfaceID: InterfaceID("i"),
                                        data: freshLinkRequest(destHash: destHash)))
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
/// Seeded deliberately: the property under test is the ROLE FILTER, not reachability. The
/// initiator here is given the OLDEST sort key of all three elements, so if the role filter is
/// removed it becomes the first element the comparator picks — which is exactly the trap.
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

    await store.send(.acceptLinkRequest(owner: Identity(), destinationHash: destHash,
                                        interfaceID: InterfaceID("i"),
                                        data: freshLinkRequest(destHash: destHash)))
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

/// A link with an IN-FLIGHT RESOURCE TRANSFER must never be evicted, even when it holds the
/// oldest sort key of any candidate.
///
/// Resource SEGMENT contexts (`.resource`, `.resourceHashmapUpdate`, and friends) forward raw
/// bytes to `ResourceTransfer` children that decrypt internally, so they never advance
/// `lastData` — only `.resourceAdvertisement` does, at transfer START. A link midway through a
/// large transfer therefore looks maximally IDLE to a `lastData`-only comparator, which is
/// precisely when evicting it is most wasteful.
///
/// Seeded deliberately: the property under test is the `transfers.isEmpty` filter outranking the
/// sort key, not reachability.
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

    await store.send(.acceptLinkRequest(owner: Identity(), destinationHash: destHash,
                                        interfaceID: InterfaceID("i"),
                                        data: freshLinkRequest(destHash: destHash)))
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
