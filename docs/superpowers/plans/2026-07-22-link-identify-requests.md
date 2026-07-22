# Link IDENTIFY + Inline Request/Response Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a responder authenticate the initiator over a link (IDENTIFY) and provide an authenticated request/response RPC for payloads ≤ 431 bytes, wire-compatible with Python-RNS 1.3.8.

**Architecture:** All logic lives in the `LinkSession` reducer (`ReTiCATransport`) — the `Identity`/`Link.encrypt`/`Packet.truncatedHash`/`MsgPack`/`Crypto.truncatedHash` primitives it needs are already in the `ReTiCA` core — plus the `Endpoint` (`ReTiCANode`) public surface mirroring `sendOverLink`. The reducer surfaces inbound requests to the app (which replies via `sendResponse` and enforces its own policy using the identified `remoteIdentity`).

**Tech Stack:** Swift 6, The Composable Architecture ~1.26 (`LinkSession`/`Endpoint` reducers, `TestStore`, `TestClock`, cancellable timers), the in-core `Identity` (Ed25519 sign/validate), `Link.encrypt/decrypt`, `Packet.truncatedHash`, `MsgPack`, `Crypto.truncatedHash`; cross-validation against genuine Python-RNS 1.3.8 / `umsgpack`.

## Global Constraints

- **Contexts (already in `PacketContext`):** `linkIdentify = 0xFB`, `request = 0x09`, `response = 0x0A`. All are `.data` packet type, **encrypted** with the link session key (`Link.encrypt`). All dest `.link`, destHash == `linkID`.
- **IDENTIFY payload (128 B, encrypted):** `identity.publicKey(64) ‖ identity.sign(linkID ‖ identity.publicKey)(64)`. `publicKey` = X25519_pub(32) ‖ Ed25519_pub(32). Signed message = `linkID(16) ‖ publicKey(64)`. Only the initiator sends; only the responder processes.
- **REQUEST payload (encrypted):** `MsgPack([.double(time), .bin(pathHash), .bin(data)])`, `pathHash = Crypto.truncatedHash(path.utf8)` (16 B). **`request_id` = the REQUEST packet's `truncatedHash`** (16 B) — never carried in the request. Inline only when packed ≤ `431` bytes (`Link.MDU`); larger is deferred.
- **RESPONSE payload (encrypted):** `MsgPack([.bin(requestID), .bin(data)])`; matched by the requester against `pendingRequests`. Inline only ≤ 431 bytes.
- **Timeout:** `rtt · 6 + 11.25` seconds (`TRAFFIC_TIMEOUT_FACTOR=6`, `RESPONSE_MAX_GRACE_TIME=10 · 1.125`). Use `(state.rtt ?? 0.5)`.
- Requests/responses are **bidirectional** (no role guard on `.sendRequest`/`.sendResponse`/inbound `.request`/`.response`); only IDENTIFY is role-gated.
- **Data-slice index safety:** materialize `Data(...)` before subscripting; stride via `startIndex`.
- **Two-layer purity:** the `ReTiCA` core stays untouched (all primitives already exist); TCA lives only in `ReTiCATransport`/`ReTiCANode`. `LinkSession.State`/`Endpoint.State` stay `Equatable` (`Identity` is `Equatable`).
- **Commit directly to `main`** (no feature branch). **Build gotcha:** signal-11 = stale build cache → `swift package clean`; never delete code to "fix" it.
- **Mutation-test discipline** for every new/changed test: run-pass → batch-mutate to fail → revert to green, before commit.
- **Commit trailers:** `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.

## File Structure

- `Sources/ReTiCATransport/LinkSession.swift` (**modify**, Tasks 1–3) — IDENTIFY + request/response.
- `Sources/ReTiCANode/Endpoint.swift` (**modify**, Task 4) — public API + delegates.
- `Tests/ReTiCATransportTests/LinkSessionRequestTests.swift` (**create**, Tasks 1–3).
- `Tests/ReTiCANodeTests/EndpointTests.swift` (**modify**, Tasks 4–5).
- `Tests/ReTiCATests/Vectors/generate_fixtures.py` + `fixtures.json` + `VectorFixtures.swift` + a cross-val test (**modify/create**, Task 5).
- `README.md` (**modify**, Task 5).

---

### Task 1: Link IDENTIFY

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift`
- Test: `Tests/ReTiCATransportTests/LinkSessionRequestTests.swift` (create)

**Interfaces:**
- Consumes: `Identity.publicKey` (64 B), `Identity.sign(_:)`, `Identity.validate(signature:message:)`, `Identity(publicKey:)`, `Link.encrypt/decrypt`, `linkPacket`.
- Produces: `LinkSession.State.remoteIdentity: Identity?`; `Action.identify(Identity)`; `Delegate.identified(Identity)`; inbound `.linkIdentify` handling.

- [ ] **Step 1: Add State field + Action/Delegate cases**

In `Sources/ReTiCATransport/LinkSession.swift`:

Add to `State` (after `lastInbound` / near the identity fields):
```swift
        public var remoteIdentity: Identity?
```
Initialize `self.remoteIdentity = nil` in BOTH initializers (`initiatorTo:` and `responderFor:`).

Add to `Action` (near `.send`):
```swift
        case identify(Identity)
```
Add to `Action.Delegate` (near `.dataReceived`):
```swift
            case identified(Identity)
```

- [ ] **Step 2: Add the `.identify` send case**

In the outer `switch action`, add (e.g. after `case .send`):
```swift
            case let .identify(identity):
                guard state.role == .initiator, state.status == .active else { return .none }
                let payload = identity.publicKey + identity.sign(state.linkID + identity.publicKey)
                guard let raw = linkPacket(state.linkID, .linkIdentify,
                                           Link.encrypt(payload, sessionKey: state.sessionKey))
                else { return .none }
                return .send(.delegate(.transmit(state.interfaceID, raw)))
```

- [ ] **Step 3: Add the inbound `.linkIdentify` case**

In the `switch (state.role, state.status, packet.packetType, packet.context)` (inside `.received`), add before `default:`:
```swift
                case (_, .active, .data, .linkIdentify):
                    guard state.role == .responder,
                          let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey)
                    else { return .none }
                    let p = Data(plain)
                    guard p.count == 128,
                          let peer = Identity(publicKey: Data(p[p.startIndex..<(p.startIndex + 64)])),
                          peer.validate(signature: Data(p[(p.startIndex + 64)..<(p.startIndex + 128)]),
                                        message: state.linkID + Data(p[p.startIndex..<(p.startIndex + 64)]))
                    else { return .none }
                    state.remoteIdentity = peer
                    return .send(.delegate(.identified(peer)))
```

- [ ] **Step 4: Write the tests**

Create `Tests/ReTiCATransportTests/LinkSessionRequestTests.swift`:

```swift
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
```

- [ ] **Step 5: Run to verify**

Run: `swift test --filter LinkSessionRequest`
Then: `swift test --filter LinkSession` (confirm the existing LinkSession tests still pass — additive changes).
Expected: PASS.

- [ ] **Step 6: Mutation sweep**

Apply each, run `swift test --filter LinkSessionRequest`, confirm the named test fails, revert; final green:
- In `.identify`, sign `state.linkID` alone (drop `+ identity.publicKey`) → `initiatorIdentifyEmits128ByteSignedPayload` fails (signature no longer verifies over `linkID ‖ publicKey`).
- In the inbound case, remove the `peer.validate(...)` guard clause (accept any 128-byte payload) → `responderRejectsTamperedIdentifySignature` fails.
- In the inbound case, change `state.role == .responder` to `state.role == .initiator` → `initiatorIgnoresInboundIdentify` fails (and `responderAccepts...` fails).

- [ ] **Step 7: Commit**

```
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionRequestTests.swift
git commit -F /tmp/ReTiCA/commit-t1.txt
```
(`/tmp/ReTiCA/commit-t1.txt` first line: `feat: Link IDENTIFY (initiator signs identity, responder verifies + stores)`, blank line, trailers.)

---

### Task 2: Requester inline request

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift`
- Test: `Tests/ReTiCATransportTests/LinkSessionRequestTests.swift`

**Interfaces:**
- Consumes: `Crypto.truncatedHash`, `MsgPack.encode(.array)`/`decodeValue`, `Packet.truncatedHash`, `Link.encrypt/decrypt`, `@Dependency(\.date)`/`(\.continuousClock)`, the `CancelID` enum.
- Produces: `State.pendingRequests: Set<Data>`; `State`-level `requestMDU`; `Action.sendRequest(path:data:)`/`.requestDeadline(Data)`; `Delegate.responseReceived(requestID:data:)`/`.requestFailed(requestID:)`; `CancelID.request(Data)`; inbound `.response` handling.

- [ ] **Step 1: Add State field, constant, CancelID case, Action/Delegate cases**

In `LinkSession.swift`:

Add the MDU constant near the other `static let`s (`keepaliveByte` etc.):
```swift
    static let requestMDU = 431
```
Add to `State` (after `remoteIdentity`):
```swift
        public var pendingRequests: Set<Data>
```
Initialize `self.pendingRequests = []` in BOTH initializers.

Add the request timeout to `CancelID` (currently `case establishment, keepalive, inactivity`):
```swift
    private enum CancelID: Hashable { case establishment, keepalive, inactivity, request(Data) }
```
Add to `Action`:
```swift
        case sendRequest(path: String, data: Data)
        case requestDeadline(Data)
```
Add to `Action.Delegate`:
```swift
            case responseReceived(requestID: Data, data: Data)
            case requestFailed(requestID: Data)
```

- [ ] **Step 2: Add the `.sendRequest` case**

In the outer `switch action`:
```swift
            case let .sendRequest(path, data):
                guard state.status == .active else { return .none }
                let pathHash = Crypto.truncatedHash(Data(path.utf8))
                let packed = MsgPack.encode(.array([.double(date.now.timeIntervalSince1970),
                                                    .bin(pathHash), .bin(data)]))
                guard packed.count <= Self.requestMDU else { return .none }
                let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                                    destinationType: .link, context: .request, contextFlag: false, hops: 0,
                                    destinationHash: state.linkID, transportId: nil,
                                    payload: Link.encrypt(packed, sessionKey: state.sessionKey))
                let requestID = packet.truncatedHash
                guard let raw = try? packet.packed() else { return .none }
                state.pendingRequests.insert(requestID)
                let timeout = (state.rtt ?? 0.5) * 6 + 11.25
                let id = state.interfaceID
                return .merge(
                    .send(.delegate(.transmit(id, raw))),
                    .run { send in
                        try await clock.sleep(for: .seconds(timeout))
                        await send(.requestDeadline(requestID))
                    }.cancellable(id: CancelID.request(requestID), cancelInFlight: true))
```

- [ ] **Step 3: Add the inbound `.response` case + the `.requestDeadline` case**

Inbound (in the received tuple switch, before `default:`):
```swift
                case (_, .active, .data, .response):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          case let .array(items)? = MsgPack.decodeValue(Data(plain)), items.count == 2,
                          case let .bin(requestID) = items[0], case let .bin(data) = items[1],
                          state.pendingRequests.contains(requestID)
                    else { return .none }
                    state.pendingRequests.remove(requestID)
                    return .merge(.cancel(id: CancelID.request(requestID)),
                                  .send(.delegate(.responseReceived(requestID: requestID, data: data))))
```
Outer switch (`.requestDeadline`):
```swift
            case let .requestDeadline(requestID):
                guard state.pendingRequests.contains(requestID) else { return .none }
                state.pendingRequests.remove(requestID)
                return .send(.delegate(.requestFailed(requestID: requestID)))
```

- [ ] **Step 4: Write the tests**

Append to `Tests/ReTiCATransportTests/LinkSessionRequestTests.swift`:

```swift
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

@Test @MainActor func oversizeRequestIsNotSent() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .initiator, clock)
    await store.send(.sendRequest(path: "svc/big", data: Data(repeating: 0x7A, count: 500)))  // > 431 packed
    #expect(store.state.pendingRequests.isEmpty)
}
```

- [ ] **Step 5: Run to verify**

Run: `swift test --filter LinkSessionRequest`
Expected: PASS (Task 1 + 4 new tests).

- [ ] **Step 6: Mutation sweep**

Apply each, run `swift test --filter LinkSessionRequest`, confirm the named test fails, revert; final green:
- In `.sendRequest`, change `guard packed.count <= Self.requestMDU` to `<= 100000` → `oversizeRequestIsNotSent` fails (the 500-byte request is now sent, so `pendingRequests` is non-empty).
- In the inbound `.response` case, change `state.pendingRequests.remove(requestID)` to a no-op (e.g. `_ = requestID`) → `inboundResponseMatchesPendingRequestAndClearsIt` fails (`pendingRequests` still contains it).
- In `.requestDeadline`, replace the return with `return .none` → `requestDeadlineFiresRequestFailed` fails (no `requestFailed` delegate).

- [ ] **Step 7: Commit**

```
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionRequestTests.swift
git commit -F /tmp/ReTiCA/commit-t2.txt
```
(First line: `feat: LinkSession requester inline request (send + pending + timeout + response match)`, blank line, trailers.)

---

### Task 3: Responder inline response

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift`
- Test: `Tests/ReTiCATransportTests/LinkSessionRequestTests.swift`

**Interfaces:**
- Consumes: Task 2's `requestMDU`, `MsgPack`, `Packet.truncatedHash`, `Link.encrypt/decrypt`, `linkPacket`.
- Produces: `Action.sendResponse(requestID:data:)`; `Delegate.requestReceived(requestID:pathHash:data:)`; inbound `.request` handling.

- [ ] **Step 1: Add Action/Delegate cases**

In `LinkSession.swift`:
```swift
        case sendResponse(requestID: Data, data: Data)   // in Action
```
```swift
            case requestReceived(requestID: Data, pathHash: Data, data: Data)   // in Action.Delegate
```

- [ ] **Step 2: Add the inbound `.request` case**

In the received tuple switch, before `default:`:
```swift
                case (_, .active, .data, .request):
                    let requestID = packet.truncatedHash
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          case let .array(items)? = MsgPack.decodeValue(Data(plain)), items.count == 3,
                          case let .bin(pathHash) = items[1], case let .bin(data) = items[2]
                    else { return .none }
                    return .send(.delegate(.requestReceived(requestID: requestID, pathHash: pathHash, data: data)))
```

- [ ] **Step 3: Add the `.sendResponse` case**

In the outer `switch action`:
```swift
            case let .sendResponse(requestID, data):
                guard state.status == .active else { return .none }
                let packed = MsgPack.encode(.array([.bin(requestID), .bin(data)]))
                guard packed.count <= Self.requestMDU,
                      let raw = linkPacket(state.linkID, .response,
                                           Link.encrypt(packed, sessionKey: state.sessionKey))
                else { return .none }
                return .send(.delegate(.transmit(state.interfaceID, raw)))
```

- [ ] **Step 4: Write the tests**

Append to `Tests/ReTiCATransportTests/LinkSessionRequestTests.swift`:

```swift
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
```

- [ ] **Step 5: Run to verify**

Run: `swift test --filter LinkSessionRequest`
Expected: PASS (all prior + 2 new).

- [ ] **Step 6: Mutation sweep**

Apply each, run `swift test --filter LinkSessionRequest`, confirm the named test fails, revert; final green:
- In the inbound `.request` case, change `let requestID = packet.truncatedHash` to `let requestID = Data()` → `inboundRequestSurfacesRequestReceivedWithPacketID` fails.
- In `.sendResponse`, change `.bin(requestID)` to `.bin(Data())` → `sendResponseEmitsResponsePacketEchoingRequestID` fails.

- [ ] **Step 7: Commit**

```
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionRequestTests.swift
git commit -F /tmp/ReTiCA/commit-t3.txt
```
(First line: `feat: LinkSession responder inline response (requestReceived + sendResponse)`, blank line, trailers.)

---

### Task 4: Endpoint public API + delegates

**Files:**
- Modify: `Sources/ReTiCANode/Endpoint.swift`
- Test: `Tests/ReTiCANodeTests/EndpointTests.swift`

**Interfaces:**
- Consumes: `LinkSession.Action.identify/sendRequest/sendResponse` and `LinkSession.Action.Delegate.identified/requestReceived/responseReceived/requestFailed` (Tasks 1–3).
- Produces: `Endpoint.Action.identifyOverLink/sendRequestOverLink/sendResponseOverLink`; `Endpoint.Action.Delegate.linkIdentified/requestReceived/responseReceived/requestFailed`.

- [ ] **Step 1: Add the action + delegate cases**

In `Sources/ReTiCANode/Endpoint.swift`, add to `Action` (near `.sendOverLink`):
```swift
        case identifyOverLink(linkID: Data, identity: Identity)
        case sendRequestOverLink(linkID: Data, path: String, data: Data)
        case sendResponseOverLink(linkID: Data, requestID: Data, data: Data)
```
Add to `Action.Delegate`:
```swift
        case linkIdentified(linkID: Data, remoteIdentity: Identity)
        case requestReceived(linkID: Data, requestID: Data, pathHash: Data, data: Data)
        case responseReceived(linkID: Data, requestID: Data, data: Data)
        case requestFailed(linkID: Data, requestID: Data)
```

- [ ] **Step 2: Add the dispatch cases**

In the `Reduce`, near `.sendOverLink`:
```swift
            case let .identifyOverLink(linkID, identity):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .identify(identity))))
            case let .sendRequestOverLink(linkID, path, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .sendRequest(path: path, data: data))))
            case let .sendResponseOverLink(linkID, requestID, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .sendResponse(requestID: requestID, data: data))))
```

- [ ] **Step 3: Add the delegate re-surfacing cases**

Insert BEFORE the final catch-all `case .interface, .transport, .delegate, .link:`:
```swift
            case let .link(.element(elementID, .delegate(.identified(identity)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: identity)))
            case let .link(.element(elementID, .delegate(.requestReceived(rid, ph, data)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.requestReceived(linkID: linkID, requestID: rid, pathHash: ph, data: data)))
            case let .link(.element(elementID, .delegate(.responseReceived(rid, data)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.responseReceived(linkID: linkID, requestID: rid, data: data)))
            case let .link(.element(elementID, .delegate(.requestFailed(rid)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.requestFailed(linkID: linkID, requestID: rid)))
```

- [ ] **Step 4: Write the tests**

Append to `Tests/ReTiCANodeTests/EndpointTests.swift` (build an Endpoint with a hand-made active link element, mirroring the existing `sendResourceOverLinkDispatchesToTheMatchingLink` test; use the same zero-UUID convention already in the file):

```swift
@Test @MainActor func identifyOverLinkDispatchesToTheMatchingLink() async {
    let clock = TestClock()
    let linkID = Data(repeating: 0xAB, count: 16)
    let store = TestStore(initialState: {
        var s = Endpoint.State(host: "n", port: 4242, reconnectOnDrop: false)
        var link = LinkSession.State(id: UUID(0), initiatorTo: Identity(),
                                     destinationHash: Data(repeating: 0x02, count: 16), interfaceID: InterfaceID("tcp"))
        link.status = .active; link.sessionKey = Data(repeating: 0x01, count: 64); link.linkID = linkID; link.rtt = 1.0
        s.links.append(link)
        return s
    }()) { Endpoint() } withDependencies: {
        $0.continuousClock = clock; $0.date = .constant(Date(timeIntervalSince1970: 0)); $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    await store.send(.identifyOverLink(linkID: linkID, identity: Identity()))
    await store.receive { if case .link(.element(_, .identify)) = $0 { return true }; return false }
}

@Test @MainActor func requestReceivedDelegateSurfacesWithLinkID() async {
    let clock = TestClock()
    let linkID = Data(repeating: 0xAB, count: 16)
    let store = TestStore(initialState: {
        var s = Endpoint.State(host: "n", port: 4242, reconnectOnDrop: false)
        var link = LinkSession.State(id: UUID(0), responderFor: Identity(),
                                     destinationHash: Data(repeating: 0x02, count: 16), interfaceID: InterfaceID("tcp"))
        link.status = .active; link.sessionKey = Data(repeating: 0x01, count: 64); link.linkID = linkID; link.rtt = 1.0
        s.links.append(link)
        return s
    }()) { Endpoint() } withDependencies: {
        $0.continuousClock = clock; $0.date = .constant(Date(timeIntervalSince1970: 0)); $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    let rid = Data(repeating: 0x11, count: 16); let ph = Data(repeating: 0x22, count: 16)
    let got = LockIsolated<(Data, Data)?>(nil)
    await store.send(.link(.element(id: UUID(0), action: .delegate(.requestReceived(requestID: rid, pathHash: ph, data: Data("x".utf8))))))
    await store.receive { action in
        if case let .delegate(.requestReceived(lid, gotRid, _, _)) = action { got.setValue((lid, gotRid)); return true }
        return false
    }
    #expect(got.value?.0 == linkID)
    #expect(got.value?.1 == rid)
}
```

- [ ] **Step 5: Run to verify**

Run: `swift test --filter Endpoint`
Expected: PASS (2 new + existing Endpoint tests).

- [ ] **Step 6: Mutation sweep**

Apply each, run `swift test --filter Endpoint`, confirm the named test fails, revert; final green:
- In `.identifyOverLink`, change the lookup predicate to `{ $0.linkID == Data() }` → `identifyOverLinkDispatchesToTheMatchingLink` fails.
- In the `.requestReceived` re-surface, change `linkID: linkID` to `linkID: Data()` → `requestReceivedDelegateSurfacesWithLinkID` fails.

- [ ] **Step 7: Commit**

```
git add Sources/ReTiCANode/Endpoint.swift Tests/ReTiCANodeTests/EndpointTests.swift
git commit -F /tmp/ReTiCA/commit-t4.txt
```
(First line: `feat: Endpoint identify/request/response API + delegates`, blank line, trailers.)

---

### Task 5: End-to-end identify+request+response, cross-validation, gate, README

**Files:**
- Modify: `Tests/ReTiCANodeTests/EndpointTests.swift` (E2E)
- Modify: `Tests/ReTiCATests/Vectors/generate_fixtures.py`, regenerate `fixtures.json`, `VectorFixtures.swift`
- Create: `Tests/ReTiCATests/Vectors/LinkRequestCrossValidationTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–4.

- [ ] **Step 1: Write the end-to-end test**

Append to `Tests/ReTiCANodeTests/EndpointTests.swift`. Model it on `twoEndpointsEstablishLinkExchangeDataAndClose` (the two-store `make(...)` helper + handshake pump to `.active`). After both links are active: A (initiator) identifies; B (responder) surfaces `linkIdentified`; A sends a request; B surfaces `requestReceived`; B responds; A surfaces `responseReceived`.

```swift
@Test @MainActor func twoEndpointsIdentifyAndRoundTripARequest() async {
    let clock = TestClock()
    let aIdentity = Identity()
    let bIdentity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: bIdentity)!

    func make(_ host: String, _ sent: LockIsolated<[Data]>) -> (TestStore<Endpoint.State, Endpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: Endpoint.State(host: host, port: 4242, reconnectOnDrop: false)) {
            Endpoint()
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } }, close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    let sentA = LockIsolated<[Data]>([]); let sentB = LockIsolated<[Data]>([])
    let (a, eventsA) = make("a", sentA)
    let (b, eventsB) = make("b", sentB)

    // Establish (identical to twoEndpointsEstablishLinkExchangeDataAndClose steps 1–4).
    await a.send(.connect); eventsA.yield(.connected); await a.receive(\.transport.interfaceConnected)
    await b.send(.registerLocalDestination(dest))
    await b.send(.connect); eventsB.yield(.connected); await b.receive(\.transport.interfaceConnected)
    await b.send(.announce(destinationHash: dest.hash, appData: nil))
    eventsA.yield(.data(sentB.value.last!)); await a.receive(\.transport.received); await a.receive(\.delegate.pathLearned)
    await a.send(.openLink(destinationHash: dest.hash))
    await a.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await a.receive { if case .interface(.send) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!)); await b.receive(\.transport.received); await b.receive(\.transport.delegate.linkRequest)
    await b.receive { if case .interface(.send) = $0 { return true }; return false }
    eventsA.yield(.data(sentB.value.last!)); await a.receive(\.transport.received)
    await a.receive { if case .interface(.send) = $0 { return true }; return false }
    await a.receive(\.delegate.linkEstablished)
    eventsB.yield(.data(sentA.value.last!)); await b.receive(\.transport.received); await b.receive(\.delegate.linkEstablished)
    let linkID = a.state.links[0].linkID

    // A identifies → B surfaces linkIdentified with A's identity.
    await a.send(.identifyOverLink(linkID: linkID, identity: aIdentity))
    await a.receive { if case .interface(.send) = $0 { return true }; return false }
    let idHash = LockIsolated<Data?>(nil)
    eventsB.yield(.data(sentA.value.last!)); await b.receive(\.transport.received)
    await b.receive { action in
        if case let .delegate(.linkIdentified(_, id)) = action { idHash.setValue(id.hash); return true }
        return false
    }
    #expect(idHash.value == aIdentity.hash)

    // A requests → B surfaces requestReceived → B responds → A surfaces responseReceived.
    await a.send(.sendRequestOverLink(linkID: linkID, path: "svc/echo", data: Data("ping".utf8)))
    await a.receive { if case .interface(.send) = $0 { return true }; return false }
    let reqID = LockIsolated<Data?>(nil)
    eventsB.yield(.data(sentA.value.last!)); await b.receive(\.transport.received)
    await b.receive { action in
        if case let .delegate(.requestReceived(_, rid, _, d)) = action, d == Data("ping".utf8) { reqID.setValue(rid); return true }
        return false
    }
    await b.send(.sendResponseOverLink(linkID: linkID, requestID: reqID.value!, data: Data("pong".utf8)))
    await b.receive { if case .interface(.send) = $0 { return true }; return false }
    let respData = LockIsolated<Data?>(nil)
    eventsA.yield(.data(sentB.value.last!)); await a.receive(\.transport.received)
    await a.receive { action in
        if case let .delegate(.responseReceived(_, rid, d)) = action, rid == reqID.value! { respData.setValue(d); return true }
        return false
    }
    #expect(respData.value == Data("pong".utf8))

    await a.send(.disconnect); await b.send(.disconnect)
}
```

> Implementer note: the E2E never advances the clock, so link keepalive/inactivity timers and the request timeout don't fire. If TCA effect-ordering needs a small adjustment (an extra `.receive` for an intermediate action), make it while keeping the assertions (`idHash == aIdentity.hash`, `respData == "pong"`, matched `reqID`) intact; document any change.

- [ ] **Step 2: Add cross-validation vectors**

In `Tests/ReTiCATests/Vectors/generate_fixtures.py`, after the existing block (the generator already imports `RNS`/`umsgpack`), add:

```python
# --- Link IDENTIFY: RNS-produced payload for a fixed identity + link_id ---
identify_prv = bytes([(i * 7 + 3) % 256 for i in range(64)])
identify_identity = RNS.Identity.from_bytes(identify_prv)
identify_link_id = bytes([0xAB] * 16)
identify_pub = identify_identity.get_public_key()
identify_signature = identify_identity.sign(identify_link_id + identify_pub)
identify_payload = identify_pub + identify_signature

# --- path hash + msgpack request/response layouts ---
req_path = "svc/echo"
req_path_hash = RNS.Identity.truncated_hash(req_path.encode("utf-8"))
req_msgpack = umsgpack.packb([1.5, req_path_hash, b"ping"])
resp_msgpack = umsgpack.packb([bytes([0xCD] * 16), b"pong"])
```

Then in the `json.dumps({...})` dict add:
```python
    "identify_prv": identify_prv.hex(),
    "identify_link_id": identify_link_id.hex(),
    "identify_pub": identify_pub.hex(),
    "identify_payload": identify_payload.hex(),
    "req_path_hash": req_path_hash.hex(),
    "req_msgpack": req_msgpack.hex(),
    "resp_msgpack": resp_msgpack.hex(),
```

Regenerate: `/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/generate_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/fixtures.json`

Verify: `grep -n "identify_payload" /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/fixtures.json` (expect one line).

> Note on `RNS.Identity.from_bytes`: if that constructor name differs in this RNS version, use whatever the generator already uses to build an `RNS.Identity` from a known private key (check the existing resource/identity fixtures in `generate_fixtures.py`); the requirement is a deterministic identity from `identify_prv` whose `get_public_key()` and `sign(...)` are captured.

- [ ] **Step 3: Decode the fields + write the cross-validation test**

In `Tests/ReTiCATests/Vectors/VectorFixtures.swift`, add the properties + CodingKeys for `identifyPrv`/`identifyLinkId`/`identifyPub`/`identifyPayload`/`reqPathHash`/`reqMsgpack`/`respMsgpack` (mapping the snake_case keys).

Create `Tests/ReTiCATests/Vectors/LinkRequestCrossValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func swiftVerifiesGenuineRnsIdentifyPayload() throws {
    let f = try VectorFixtures.load()
    let payload = Data(hexString: f.identifyPayload)!
    let linkID = Data(hexString: f.identifyLinkId)!
    // Our identity from the same private seed reproduces the public key deterministically.
    let identity = Identity(privateKey: Data(hexString: f.identifyPrv)!)!
    #expect(identity.publicKey == Data(hexString: f.identifyPub)!)
    #expect(Data(payload.prefix(64)) == identity.publicKey)          // pubkey half is byte-exact
    // Our verifier accepts RNS's Ed25519 signature over linkID ‖ publicKey (interop, no determinism assumption).
    let signature = Data(payload.suffix(64))
    #expect(identity.validate(signature: signature, message: linkID + identity.publicKey))
}

@Test func swiftPathHashMatchesRns() throws {
    let f = try VectorFixtures.load()
    #expect(Crypto.truncatedHash(Data("svc/echo".utf8)) == Data(hexString: f.reqPathHash))
}

@Test func swiftRequestResponseMsgpackMatchUmsgpack() throws {
    let f = try VectorFixtures.load()
    let req = MsgPack.encode(.array([.double(1.5), .bin(Data(hexString: f.reqPathHash)!), .bin(Data("ping".utf8))]))
    #expect(req == Data(hexString: f.reqMsgpack))
    let resp = MsgPack.encode(.array([.bin(Data(repeating: 0xCD, count: 16)), .bin(Data("pong".utf8))]))
    #expect(resp == Data(hexString: f.respMsgpack))
}
```

- [ ] **Step 4: Run the filtered suites**

Run: `swift test --filter Endpoint`
Run: `swift test --filter LinkRequestCrossValidation`
Expected: PASS.

- [ ] **Step 5: Run the full suite (gate)**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit (verify fixtures captured)**

```
git add Tests/ReTiCANodeTests/EndpointTests.swift Tests/ReTiCATests/Vectors/generate_fixtures.py Tests/ReTiCATests/Vectors/fixtures.json Tests/ReTiCATests/Vectors/VectorFixtures.swift Tests/ReTiCATests/Vectors/LinkRequestCrossValidationTests.swift
git commit -F /tmp/ReTiCA/commit-t5a.txt
```
(First line: `test: end-to-end identify+request/response + RNS cross-validation`, blank line, trailers.)

After committing, run `git show HEAD:Tests/ReTiCATests/Vectors/fixtures.json` (its own command) and confirm `identify_payload` is present in the committed blob; if missing, re-stage and `git commit --amend --no-edit`, then re-verify.

- [ ] **Step 7: Mutation sweep (cross-cutting)**

Apply each, run the named filter, confirm the expected failure, revert; final full `swift test` green:
- In `LinkSession`'s inbound `.linkIdentify` case, change the signed message check to `message: state.linkID` (drop `+ publicKey`) → `twoEndpointsIdentifyAndRoundTripARequest` fails (B rejects A's identify) — run `swift test --filter Endpoint`.
- In `LinkSession`'s `.sendResponse`, change `.bin(requestID)` to `.bin(Data())` → `twoEndpointsIdentifyAndRoundTripARequest` fails (A never matches the response's request_id); run `swift test --filter Endpoint`.
Run `swift test` after reverting both → green.

- [ ] **Step 8: Update the README**

In `README.md`, add a subsection near the link sections:

```markdown
### Link identify & request/response (`Endpoint`)

Over an established link, the initiator can prove its identity and either peer can make an
authenticated request:

- `Endpoint.identifyOverLink(linkID:identity:)` sends `publicKey ‖ sign(linkID ‖ publicKey)` (encrypted,
  context `LINKIDENTIFY`); the responder verifies the Ed25519 signature and surfaces
  `linkIdentified(linkID:remoteIdentity:)`.
- `Endpoint.sendRequestOverLink(linkID:path:data:)` sends `REQUEST` = `msgpack([time, path_hash, data])`
  (encrypted); the peer surfaces `requestReceived(linkID:requestID:pathHash:data:)` and replies with
  `sendResponseOverLink(linkID:requestID:data:)` → `RESPONSE` = `msgpack([request_id, data])`, matched
  back to `responseReceived(...)` by `request_id` (the request packet's truncated hash). A lost response
  surfaces `requestFailed(...)` after `rtt·6 + 11.25 s`.

Requests/responses are inline for payloads ≤ 431 bytes and wire-compatible with Python-RNS 1.3.8. The
application generates responses and enforces its own allow-policy using the identified `remoteIdentity`;
RNS's in-library handler-registry/allow-policy and large (Resource-based) requests/responses remain
future slices.
```

- [ ] **Step 9: Commit**

```
git add README.md
git commit -F /tmp/ReTiCA/commit-t5b.txt
```
(First line: `docs: Link identify + request/response`, blank line, trailers.)

---

## Self-Review

**Spec coverage:**
- IDENTIFY (send + verify + `remoteIdentity` + delegate) → Task 1. ✓
- Requester inline request (send + `pendingRequests` + timeout + `.response` match) → Task 2. ✓
- Responder inline response (`requestReceived` + `sendResponse`) → Task 3. ✓
- Endpoint API + delegates → Task 4. ✓
- E2E + RNS cross-val (IDENTIFY payload, path_hash, msgpack) + gate + README → Task 5. ✓
- App-side policy, inline-only, `request_id` = packet truncated hash → as specced. ✓
- Deferred (large-via-Resource, in-library allow-policy) → untouched. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. The two implementer notes (RNS `from_bytes` constructor name in Task 5, E2E effect-ordering) are guidance for matching existing conventions with assertions locked — not missing implementation.

**Type consistency:** `remoteIdentity`/`pendingRequests`/`requestMDU`/`CancelID.request(Data)`, the `identify`/`sendRequest`/`sendResponse`/`requestDeadline` actions, the `identified`/`requestReceived`/`responseReceived`/`requestFailed` delegates (LinkSession) and their `linkID`-keyed Endpoint counterparts, and the byte layouts (128-B IDENTIFY, `msgpack([double,bin,bin])` request, `msgpack([bin,bin])` response, `request_id = Packet.truncatedHash`) are used identically across Tasks 1–5. `Crypto.truncatedHash` (16 B), `Identity.publicKey` (64 B), and context values `.linkIdentify`/`.request`/`.response` match the core.
