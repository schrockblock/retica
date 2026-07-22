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

// Build an inbound RESPONSE packet echoing `requestID`.
private func responsePacket(_ requestID: Data, _ data: Data) -> Data {
    let packed = MsgPack.encode(.array([.bin(requestID), .bin(data)]))
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .response, contextFlag: false, hops: 0,
                   destinationHash: reqLinkID, transportId: nil, payload: Link.encrypt(packed, sessionKey: reqKey))
    return try! p.packed()
}

@Test @MainActor func sendRequestEmitsRequestPacketWithPathHash() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .initiator, clock)
    await store.send(.sendRequest(path: "svc/echo", data: Data("hello".utf8)))
    let raw = await captureTransmitReq(store)
    let packet = Packet(raw: raw)!
    #expect(packet.context == .request)
    let plain = Data(Link.decrypt(packet.payload, sessionKey: reqKey)!)
    guard case let .array(items)? = MsgPack.decodeValue(plain), items.count == 3,
          case let .bin(pathHash) = items[1], case let .bin(data) = items[2] else { Issue.record("bad req"); return }
    #expect(pathHash == Crypto.truncatedHash(Data("svc/echo".utf8)))
    #expect(data == Data("hello".utf8))
    #expect(store.state.pendingRequests.contains(packet.truncatedHash))
    // cleanup: fire the deadline to drain the timer
    await store.send(.requestDeadline(packet.truncatedHash))
}

@Test @MainActor func inboundResponseMatchesPendingRequestAndClearsIt() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .initiator, clock)
    await store.send(.sendRequest(path: "svc/echo", data: Data("hi".utf8)))
    let raw = await captureTransmitReq(store)
    let requestID = Packet(raw: raw)!.truncatedHash
    let got = LockIsolated<Data?>(nil)
    await store.send(.received(responsePacket(requestID, Data("world".utf8))))
    await store.receive { action in
        if case let .delegate(.responseReceived(rid, d)) = action, rid == requestID { got.setValue(d); return true }
        return false
    }
    #expect(got.value == Data("world".utf8))
    #expect(!store.state.pendingRequests.contains(requestID))   // cleared (+ timeout cancelled)
}

@Test @MainActor func requestDeadlineFiresRequestFailed() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .initiator, clock)
    await store.send(.sendRequest(path: "svc/slow", data: Data()))
    let raw = await captureTransmitReq(store)
    let requestID = Packet(raw: raw)!.truncatedHash
    // Advance past the timeout (rtt 1.0 → 1*6 + 11.25 = 17.25 s).
    await clock.advance(by: .seconds(18))
    await store.receive { action in
        if case let .delegate(.requestFailed(rid)) = action, rid == requestID { return true }
        return false
    }
    #expect(!store.state.pendingRequests.contains(requestID))
}

// A large request/response payload (> ~431 packed → Resource path). 500 raw bytes packs to ~530.
private func bigData() -> Data { Data((0..<500).map { UInt8($0 & 0xff) }) }

@Test @MainActor func largeSendRequestSpawnsRequestResource() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .initiator, clock)
    await store.send(.sendRequest(path: "svc/big", data: bigData()))
    #expect(store.state.transfers.count == 1)
    let adv = store.state.transfers[0].advertisement!
    #expect(adv.isRequest == true)
    // request_id = truncatedHash(packed) where packed uses the deterministic epoch timestamp (0.0).
    let expectedPacked = MsgPack.encode(.array([.double(0), .bin(Crypto.truncatedHash(Data("svc/big".utf8))), .bin(bigData())]))
    #expect(adv.requestID == Crypto.truncatedHash(expectedPacked))
    #expect(store.state.pendingRequests.contains(Crypto.truncatedHash(expectedPacked)))
    // Cleanup: cancel the spawned transfer and fire the request timeout so no effects dangle.
    let tid = store.state.transfers[0].id
    await store.send(.transfer(.element(id: tid, action: .cancel)))
    await clock.advance(by: .seconds(30))
}

@Test @MainActor func largeSendResponseSpawnsResponseResource() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .responder, clock)
    let rid = Data(repeating: 0xCD, count: 16)
    await store.send(.sendResponse(requestID: rid, data: bigData()))
    #expect(store.state.transfers.count == 1)
    let adv = store.state.transfers[0].advertisement!
    #expect(adv.isResponse == true)
    #expect(adv.requestID == rid)
    let tid = store.state.transfers[0].id
    await store.send(.transfer(.element(id: tid, action: .cancel)))
    await clock.advance(by: .seconds(30))
}

@Test @MainActor func inlineSendRequestStillUsesAPacket() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .initiator, clock)
    await store.send(.sendRequest(path: "svc/small", data: Data("hi".utf8)))
    #expect(store.state.transfers.isEmpty)                 // inline → no Resource spawned
    let raw = await captureTransmitReq(store)
    #expect(Packet(raw: raw)?.context == .request)
    // Cleanup: fire the inline request timeout.
    await clock.advance(by: .seconds(30))
}

// Build an inbound REQUEST packet for a path+data.
private func requestPacket(_ path: String, _ data: Data) -> Data {
    let packed = MsgPack.encode(.array([.double(0), .bin(Crypto.truncatedHash(Data(path.utf8))), .bin(data)]))
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .request, contextFlag: false, hops: 0,
                   destinationHash: reqLinkID, transportId: nil, payload: Link.encrypt(packed, sessionKey: reqKey))
    return try! p.packed()
}

@Test @MainActor func inboundRequestSurfacesRequestReceivedWithPacketID() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .responder, clock)
    let raw = requestPacket("svc/echo", Data("ping".utf8))
    let expectedID = Packet(raw: raw)!.truncatedHash
    let got = LockIsolated<(Data, Data, Data)?>(nil)
    await store.send(.received(raw))
    await store.receive { action in
        if case let .delegate(.requestReceived(rid, ph, d)) = action { got.setValue((rid, ph, d)); return true }
        return false
    }
    #expect(got.value?.0 == expectedID)
    #expect(got.value?.1 == Crypto.truncatedHash(Data("svc/echo".utf8)))
    #expect(got.value?.2 == Data("ping".utf8))
}

@Test @MainActor func sendResponseEmitsResponsePacketEchoingRequestID() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .responder, clock)
    let requestID = Data(repeating: 0xCD, count: 16)
    await store.send(.sendResponse(requestID: requestID, data: Data("pong".utf8)))
    let raw = await captureTransmitReq(store)
    let packet = Packet(raw: raw)!
    #expect(packet.context == .response)
    let plain = Data(Link.decrypt(packet.payload, sessionKey: reqKey)!)
    guard case let .array(items)? = MsgPack.decodeValue(plain), items.count == 2,
          case let .bin(rid) = items[0], case let .bin(d) = items[1] else { Issue.record("bad resp"); return }
    #expect(rid == requestID)
    #expect(d == Data("pong".utf8))
}
