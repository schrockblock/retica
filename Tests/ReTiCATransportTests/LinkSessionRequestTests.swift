import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

private let reqKey = Data(repeating: 0x01, count: 64)
private let reqLinkID = Data(repeating: 0xAB, count: 16)

@MainActor
private func activeStore(role: LinkSession.Role, _ clock: TestClock<Duration>)
    -> TestStore<LinkSession.State, LinkSession.Action> {
    var s: LinkSession.State
    if role == .initiator {
        s = LinkSession.State(initiatorTo: Identity(), destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"))
    } else {
        s = LinkSession.State(responderFor: Identity(), destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"))
    }
    s.status = .active
    s.sessionKey = reqKey
    s.linkID = reqLinkID
    s.rtt = 1.0
    let store = TestStore(initialState: s) { LinkSession() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = clock
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

// Build an inbound LINKIDENTIFY packet for `identity` over the link key.
private func identifyPacket(_ identity: Identity) -> Data {
    let payload = identity.publicKey + identity.sign(reqLinkID + identity.publicKey)
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .linkIdentify, contextFlag: false, hops: 0,
                   destinationHash: reqLinkID, transportId: nil, payload: Link.encrypt(payload, sessionKey: reqKey))
    return try! p.packed()
}

@Test @MainActor func initiatorIdentifyEmits128ByteSignedPayload() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .initiator, clock)
    let identity = Identity()
    await store.send(.identify(identity))
    let raw = await captureTransmitReq(store)
    let packet = Packet(raw: raw)!
    #expect(packet.context == .linkIdentify)
    let plain = Data(Link.decrypt(packet.payload, sessionKey: reqKey)!)
    #expect(plain.count == 128)
    #expect(Data(plain.prefix(64)) == identity.publicKey)
    // The signature verifies over linkID ‖ publicKey.
    #expect(identity.validate(signature: Data(plain.suffix(64)), message: reqLinkID + identity.publicKey))
}

@Test @MainActor func responderAcceptsValidIdentifyAndStoresRemoteIdentity() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .responder, clock)
    let peer = Identity()
    await store.send(.received(identifyPacket(peer)))
    await store.receive { action in
        if case let .delegate(.identified(id)) = action { return id == peer }
        return false
    }
    #expect(store.state.remoteIdentity == peer)
}

@Test @MainActor func responderRejectsTamperedIdentifySignature() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .responder, clock)
    let peer = Identity()
    // Corrupt the signature: valid publicKey, random 64-byte signature.
    let payload = peer.publicKey + Data(repeating: 0x00, count: 64)
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .linkIdentify, contextFlag: false, hops: 0,
                   destinationHash: reqLinkID, transportId: nil, payload: Link.encrypt(payload, sessionKey: reqKey))
    await store.send(.received(try! p.packed()))
    #expect(store.state.remoteIdentity == nil)
}

@Test @MainActor func initiatorIgnoresInboundIdentify() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .initiator, clock)   // initiator must NOT process LINKIDENTIFY
    await store.send(.received(identifyPacket(Identity())))
    #expect(store.state.remoteIdentity == nil)
}

// Capture the next transmit's raw bytes.
@MainActor
private func captureTransmitReq(_ store: TestStore<LinkSession.State, LinkSession.Action>) async -> Data {
    let captured = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }
    return captured.value!
}
