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
    let packed = MsgPack.encode(.array([.bin(requestID), MsgPack.decodeValue(data) ?? .null]))
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .response, contextFlag: false, hops: 0,
                   destinationHash: reqLinkID, transportId: nil, payload: Link.encrypt(packed, sessionKey: reqKey))
    return try! p.packed()
}

@Test @MainActor func sendRequestEmitsRequestPacketWithPathHash() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .initiator, clock)
    // data must be valid msgpack so decodeValue can embed it inline on the wire
    let helloData = MsgPack.encode(.string("hello"))
    await store.send(.sendRequest(path: "svc/echo", data: helloData))
    let raw = await captureTransmitReq(store)
    let packet = Packet(raw: raw)!
    #expect(packet.context == .request)
    let plain = Data(Link.decrypt(packet.payload, sessionKey: reqKey)!)
    guard case let .array(items)? = MsgPack.decodeValue(plain), items.count == 3,
          case let .bin(pathHash) = items[1] else { Issue.record("bad req"); return }
    let data = MsgPack.encode(items[2])
    #expect(pathHash == Crypto.truncatedHash(Data("svc/echo".utf8)))
    #expect(data == helloData)
    #expect(store.state.pendingRequests.contains(packet.truncatedHash))
    // cleanup: fire the deadline to drain the timer
    await store.send(.requestDeadline(packet.truncatedHash))
}

@Test @MainActor func inboundResponseMatchesPendingRequestAndClearsIt() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .initiator, clock)
    // data must be valid msgpack; use msgpack str so the round-trip is stable
    let hiData = MsgPack.encode(.string("hi"))
    await store.send(.sendRequest(path: "svc/echo", data: hiData))
    let raw = await captureTransmitReq(store)
    let requestID = Packet(raw: raw)!.truncatedHash
    let worldData = MsgPack.encode(.string("world"))
    let got = LockIsolated<Data?>(nil)
    await store.send(.received(responsePacket(requestID, worldData)))
    await store.receive { action in
        if case let .delegate(.responseReceived(rid, d)) = action, rid == requestID { got.setValue(d); return true }
        return false
    }
    #expect(got.value == worldData)
    #expect(!store.state.pendingRequests.contains(requestID))   // cleared (+ timeout cancelled)
}

@Test @MainActor func requestDeadlineFiresRequestFailed() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .initiator, clock)
    await store.send(.sendRequest(path: "svc/slow", data: MsgPack.encode(.null)))
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

// A large request/response payload (> ~431 packed → Resource path).
// Must be valid msgpack so decodeValue can embed it inline on the wire.
// A 450-element array of nulls encodes to ~452 bytes inline, pushing the response payload > 431 MDU.
private func bigData() -> Data { MsgPack.encode(.array(Array(repeating: .null, count: 450))) }

@Test @MainActor func largeSendRequestSpawnsRequestResource() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .initiator, clock)
    await store.send(.sendRequest(path: "svc/big", data: bigData()))
    #expect(store.state.transfers.count == 1)
    let adv = store.state.transfers[0].advertisement!
    #expect(adv.isRequest == true)
    // request_id = truncatedHash(packed) where packed uses the deterministic epoch timestamp (0.0).
    let expectedPacked = MsgPack.encode(.array([.double(0), .bin(Crypto.truncatedHash(Data("svc/big".utf8))), MsgPack.decodeValue(bigData()) ?? .null]))
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
    await store.send(.sendRequest(path: "svc/small", data: MsgPack.encode(.string("hi"))))
    #expect(store.state.transfers.isEmpty)                 // inline → no Resource spawned
    let raw = await captureTransmitReq(store)
    #expect(Packet(raw: raw)?.context == .request)
    // Cleanup: fire the inline request timeout.
    await clock.advance(by: .seconds(30))
}

// A hosted sender transfer whose advertisement is marked isRequest/isResponse (used to exercise
// the completion-routing interception directly, without driving a full transfer).
private func hostedTransfer(_ packed: Data, requestID: Data, isResponse: Bool) -> ResourceTransfer.State {
    ResourceTransfer.State(sending: packed, linkID: reqLinkID, sessionKey: reqKey,
                           interfaceID: InterfaceID("i"), prefix: Data([0, 1, 2, 3]),
                           randomHash: Data([4, 5, 6, 7]), sdu: 24, requestID: requestID, isResponse: isResponse)
}

@MainActor
private func responderStoreWith(_ transfer: ResourceTransfer.State, _ pending: Set<Data>,
                                _ clock: TestClock<Duration>) -> TestStore<LinkSession.State, LinkSession.Action> {
    var s = LinkSession.State(responderFor: Identity(), destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"))
    s.status = .active; s.sessionKey = reqKey; s.linkID = reqLinkID; s.rtt = 1.0
    s.transfers.append(transfer)
    s.pendingRequests = pending
    let store = TestStore(initialState: s) { LinkSession() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0)); $0.continuousClock = clock; $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

@Test @MainActor func completedRequestResourceRoutesToRequestReceived() async {
    let clock = TestClock<Duration>()
    // bodyData must be valid msgpack so it can be embedded inline in the wire payload
    let bodyData = MsgPack.encode(.string("body"))
    let packed = MsgPack.encode(.array([.double(0), .bin(Crypto.truncatedHash(Data("svc/x".utf8))), MsgPack.decodeValue(bodyData) ?? .null]))
    let t = hostedTransfer(packed, requestID: Crypto.truncatedHash(packed), isResponse: false)
    let store = responderStoreWith(t, [], clock)
    let got = LockIsolated<(Data, Data)?>(nil)
    await store.send(.transfer(.element(id: t.id, action: .delegate(.received(packed)))))
    await store.receive { action in
        if case let .delegate(.requestReceived(rid, ph, d)) = action { got.setValue((ph, d)); return rid == Crypto.truncatedHash(packed) }
        return false
    }
    #expect(got.value?.0 == Crypto.truncatedHash(Data("svc/x".utf8)))
    #expect(got.value?.1 == bodyData)
    #expect(store.state.transfers[id: t.id] == nil)          // receiver GC'd on .received
}

@Test @MainActor func completedResponseResourceRoutesToResponseReceivedAndClearsPending() async {
    let clock = TestClock<Duration>()
    let rid = Data(repeating: 0xCD, count: 16)
    // answerData must be valid msgpack so it can be embedded inline in the wire payload
    let answerData = MsgPack.encode(.string("answer"))
    let packed = MsgPack.encode(.array([.bin(rid), MsgPack.decodeValue(answerData) ?? .null]))
    let t = hostedTransfer(packed, requestID: rid, isResponse: true)
    let store = responderStoreWith(t, [rid], clock)
    let got = LockIsolated<Data?>(nil)
    await store.send(.transfer(.element(id: t.id, action: .delegate(.received(packed)))))
    await store.receive { action in
        if case let .delegate(.responseReceived(r, d)) = action, r == rid { got.setValue(d); return true }
        return false
    }
    #expect(got.value == answerData)
    #expect(!store.state.pendingRequests.contains(rid))
    #expect(store.state.transfers[id: t.id] == nil)          // receiver GC'd on .received
}

@Test @MainActor func responseAdvertisementNotPendingIsIgnored() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .initiator, clock)
    // Build a response-Resource advertisement packet whose request_id is NOT pending.
    let rid = Data(repeating: 0xEE, count: 16)
    let sender = hostedTransfer(MsgPack.encode(.array([.bin(rid), MsgPack.decodeValue(bigData()) ?? .null])), requestID: rid, isResponse: true)
    let advPacket = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                           destinationType: .link, context: .resourceAdvertisement, contextFlag: false, hops: 0,
                           destinationHash: reqLinkID, transportId: nil,
                           payload: Link.encrypt(sender.advertisement!.pack(), sessionKey: reqKey))
    await store.send(.received(try! advPacket.packed()))
    #expect(store.state.transfers.isEmpty)     // unmatched response ADV → not spawned
}

// Build an inbound REQUEST packet for a path+data.
private func requestPacket(_ path: String, _ data: Data) -> Data {
    let packed = MsgPack.encode(.array([.double(0), .bin(Crypto.truncatedHash(Data(path.utf8))), MsgPack.decodeValue(data) ?? .null]))
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .request, contextFlag: false, hops: 0,
                   destinationHash: reqLinkID, transportId: nil, payload: Link.encrypt(packed, sessionKey: reqKey))
    return try! p.packed()
}

@Test @MainActor func inboundRequestSurfacesRequestReceivedWithPacketID() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .responder, clock)
    let pingData = MsgPack.encode(.string("ping"))
    let raw = requestPacket("svc/echo", pingData)
    let expectedID = Packet(raw: raw)!.truncatedHash
    let got = LockIsolated<(Data, Data, Data)?>(nil)
    await store.send(.received(raw))
    await store.receive { action in
        if case let .delegate(.requestReceived(rid, ph, d)) = action { got.setValue((rid, ph, d)); return true }
        return false
    }
    #expect(got.value?.0 == expectedID)
    #expect(got.value?.1 == Crypto.truncatedHash(Data("svc/echo".utf8)))
    #expect(got.value?.2 == pingData)
}

@Test @MainActor func sendResponseEmitsResponsePacketEchoingRequestID() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .responder, clock)
    let requestID = Data(repeating: 0xCD, count: 16)
    let pongData = MsgPack.encode(.string("pong"))
    await store.send(.sendResponse(requestID: requestID, data: pongData))
    let raw = await captureTransmitReq(store)
    let packet = Packet(raw: raw)!
    #expect(packet.context == .response)
    let plain = Data(Link.decrypt(packet.payload, sessionKey: reqKey)!)
    guard case let .array(items)? = MsgPack.decodeValue(plain), items.count == 2,
          case let .bin(rid) = items[0] else { Issue.record("bad resp"); return }
    let d = MsgPack.encode(items[1])
    #expect(rid == requestID)
    #expect(d == pongData)
}

// Locks the wire shape: the data field of a request must be a NESTED msgpack value,
// not a binary blob wrapping already-encoded bytes (the old double-encoding bug).
// Mutation: revert element [2] to .bin(data) in sendRequest → this test fails.
@Test @MainActor func sendRequestDataEmbeddedAsNestedValueNotBinBlob() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .initiator, clock)
    // Encode [None, None] as the data payload, matching the LXMF sync /get argument shape.
    let data = MsgPack.encode(.array([.null, .null]))
    await store.send(.sendRequest(path: "/get", data: data))
    let raw = await captureTransmitReq(store)
    let packet = Packet(raw: raw)!
    let plain = Data(Link.decrypt(packet.payload, sessionKey: reqKey)!)
    guard case let .array(items)? = MsgPack.decodeValue(plain), items.count == 3,
          case let .bin(pathHash) = items[1] else { Issue.record("outer array malformed"); return }
    // Element [2] MUST be the decoded value .array([.null, .null]), NOT .bin(...).
    // If sendRequest uses .bin(data) instead, items[2] would be .bin(data) and this would fail.
    #expect(items[2] == .array([.null, .null]))
    #expect(pathHash == Crypto.truncatedHash(Data("/get".utf8)))
    // Cleanup: fire the deadline to drain the timer
    await store.send(.requestDeadline(packet.truncatedHash))
}
