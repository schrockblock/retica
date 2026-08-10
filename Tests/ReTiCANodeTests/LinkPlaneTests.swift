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
    #expect(roundTrips(.delegate(.linkFailed(destinationHash: destHash, reason: .establishmentFailed))))
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
