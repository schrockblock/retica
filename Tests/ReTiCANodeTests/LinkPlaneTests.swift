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

// MARK: - Re-homing tests (Task 1: BLE peer reconnect)

/// A link packet arriving on a DIFFERENT interface re-homes the session, so subsequent
/// outbound traffic goes to the new interface. This is the BLE peer-reconnect case: an
/// InterfaceID is derived from the peer's session token, so a reconnected peer is a
/// different interface and the link's stored binding is stale.
@Test @MainActor func linkPacketFromANewInterfaceReHomesTheSession() async {
    let ifOld = InterfaceID("old")
    let ifNew = InterfaceID("new")
    let linkID = Data(repeating: 0xAA, count: 16)
    let dest = Data(repeating: 0x01, count: 16)
    var session = LinkSession.State(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                    initiatorTo: Identity(), destinationHash: dest,
                                    interfaceID: ifOld)
    session.linkID = linkID
    let store = TestStore(
        initialState: LinkPlane.State(links: [session])
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    let payload = Data([0x01, 0x02])
    // After routing a packet from the new interface, the session must be re-homed AND
    // the packet forwarded unchanged.
    await store.send(.routeLinkPacket(linkID: linkID, arrivalInterface: ifNew, data: payload)) {
        $0.links[id: session.id]?.interfaceID = ifNew
    }
    await store.receive { action in
        if case let .link(.element(_, .received(d))) = action { return d == payload }
        return false
    }
    #expect(store.state.links[id: session.id]?.interfaceID == ifNew)
}

/// A link packet arriving on the SAME interface changes nothing — the common case must not
/// churn state. This is also the TCP case: TCPEndpoint has one fixed InterfaceID, so the
/// arrival always equals the stored value and the assignment is inert.
@Test @MainActor func linkPacketFromTheSameInterfaceLeavesTheSessionUnchanged() async {
    let ifTCP = InterfaceID("tcp")
    let linkID = Data(repeating: 0xBB, count: 16)
    let dest = Data(repeating: 0x02, count: 16)
    var session = LinkSession.State(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                                    initiatorTo: Identity(), destinationHash: dest,
                                    interfaceID: ifTCP)
    session.linkID = linkID
    let store = TestStore(
        initialState: LinkPlane.State(links: [session])
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    let payload = Data([0x03, 0x04])
    // Same interface: no state mutation, packet still forwarded.
    await store.send(.routeLinkPacket(linkID: linkID, arrivalInterface: ifTCP, data: payload))
    await store.receive { action in
        if case let .link(.element(_, .received(d))) = action { return d == payload }
        return false
    }
    #expect(store.state.links[id: session.id]?.interfaceID == ifTCP)
}

/// Re-homing is keyed to the addressed link only: an unrelated session on another interface
/// is untouched.
@Test @MainActor func reHomingDoesNotDisturbOtherSessions() async {
    let ifA2 = InterfaceID("ifA")
    let ifB = InterfaceID("ifB")
    let ifNew = InterfaceID("ifNew")
    let linkIDA = Data(repeating: 0xCC, count: 16)
    let linkIDB = Data(repeating: 0xDD, count: 16)
    let destA = Data(repeating: 0x03, count: 16)
    let destB = Data(repeating: 0x04, count: 16)
    var sessionA = LinkSession.State(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                                     initiatorTo: Identity(), destinationHash: destA,
                                     interfaceID: ifA2)
    sessionA.linkID = linkIDA
    var sessionB = LinkSession.State(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                                     initiatorTo: Identity(), destinationHash: destB,
                                     interfaceID: ifB)
    sessionB.linkID = linkIDB
    let store = TestStore(
        initialState: LinkPlane.State(links: [sessionA, sessionB])
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    let payload = Data([0x05])
    // Route packet for A on "ifNew" — A should re-home; B must remain on ifB.
    await store.send(.routeLinkPacket(linkID: linkIDA, arrivalInterface: ifNew, data: payload)) {
        $0.links[id: sessionA.id]?.interfaceID = ifNew
    }
    await store.receive { action in
        if case let .link(.element(_, .received(d))) = action { return d == payload }
        return false
    }
    #expect(store.state.links[id: sessionA.id]?.interfaceID == ifNew)
    #expect(store.state.links[id: sessionB.id]?.interfaceID == ifB)
}

/// Re-homing must extend to in-flight resource transfers: ResourceTransfer.State.interfaceID is
/// a snapshot taken at creation, and every transfer transmit uses that stored copy verbatim.
/// Without the transfer loop, parts/hashmap-updates/proofs/cancels would keep going to the
/// dead interface after the session itself moved.
///
/// Mutation guard: deleting the transfer loop in LinkPlane while keeping the session line causes
/// this test to FAIL on the transfer assertion, proving the test actually exercises the fix.
@Test @MainActor func linkPacketFromANewInterfaceReHomesSessionAndItsTransfers() async {
    let ifOld = InterfaceID("old-xfer")
    let ifNew = InterfaceID("new-xfer")
    let linkID = Data(repeating: 0xEE, count: 16)
    let dest = Data(repeating: 0x05, count: 16)
    let xferID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    var session = LinkSession.State(id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                                    initiatorTo: Identity(), destinationHash: dest,
                                    interfaceID: ifOld)
    session.linkID = linkID
    // Seed one in-flight sender transfer on the old interface.
    let transfer = ResourceTransfer.State(
        sending: Data(repeating: 0xAB, count: 64),
        linkID: linkID,
        sessionKey: Data(repeating: 0x00, count: 32),
        interfaceID: ifOld,
        prefix: Data(repeating: 0x00, count: 16),
        randomHash: Data(repeating: 0x01, count: 32),
        sdu: 464,
        id: xferID
    )
    session.transfers.append(transfer)
    let store = TestStore(
        initialState: LinkPlane.State(links: [session])
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    let payload = Data([0x01, 0x02])
    await store.send(.routeLinkPacket(linkID: linkID, arrivalInterface: ifNew, data: payload)) {
        $0.links[id: session.id]?.interfaceID = ifNew
        $0.links[id: session.id]?.transfers[id: xferID]?.interfaceID = ifNew
    }
    await store.receive { action in
        if case let .link(.element(_, .received(d))) = action { return d == payload }
        return false
    }
    // Confirm both bindings moved — session and transfer.
    #expect(store.state.links[id: session.id]?.interfaceID == ifNew)
    #expect(store.state.links[id: session.id]?.transfers[id: xferID]?.interfaceID == ifNew)
}

// MARK: - Malformed inbound LINKREQUEST element-reaping tests

/// A malformed inbound LINKREQUEST must not leave a permanent element behind. `LinkPlane`
/// appends the session BEFORE dispatching `.acceptRequest`, and removal happens only on a
/// delegate — so a guard that bails to `.none` leaks the element forever. Remotely triggerable:
/// any peer that has heard our announce can send wrong-sized payloads and grow `state.links`
/// without bound, which `routeLinkPacket` then linear-scans on every inbound packet.
///
/// Three malformed shapes are covered:
///   1. Unparseable bytes (random garbage that is not a valid packet).
///   2. A validly-packed packet whose `packetType` is not `.linkRequest`.
///   3. A validly-packed `.linkRequest` with the wrong payload size (10 bytes, not 64/67).
///
/// In all three cases the element must be reaped (links is empty after draining) and NO
/// `.linkFailed` delegate must escape (a responder's `destinationHash` is the destination WE
/// serve — reporting it as unreachable would misinform the delivery layer).
///
/// No `.linkFailed` escape is verified by teardown enforcement: `LinkPlane` gates `.linkFailed`
/// on `session.role == .initiator`, and the spawned session is always `.responder` (set by
/// `acceptLinkRequest`). The `store.exhaustivity = .on` at the end of each shape arms the TCA
/// deinit check — deleting `LinkPlane`'s role gate causes the test to FAIL at teardown with an
/// unhandled `.linkFailed` action. Those `.on` lines are not decoration; they are the only thing
/// that pins the gate.
@Test @MainActor func malformedInboundLinkRequestReapsItsElement() async {
    let owner = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: owner)!

    // Shape 1: unparseable bytes.
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
        // Drain: must see .establishmentFailed from the session — LinkPlane reaps the element and
        // the role gate suppresses any .linkFailed delegate (verified by exhaustivity ON below).
        await store.receive(
            { if case .link(.element(_, .delegate(.establishmentFailed(.handshakeRejected)))) = $0 { return true }; return false }
        )
        #expect(store.state.links.isEmpty, "Shape 1 (unparseable): element must be reaped")
        // Flip to exhaustive for teardown: any stray .delegate(.linkFailed) would surface here.
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
