# Large (Resource-based) Request/Response Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transfer requests/responses whose packed msgpack exceeds `Link.MDU` (431 bytes) as Resources, so request/response works for any payload size, wire-compatible with Python-RNS 1.3.8.

**Architecture:** The sender `ResourceTransfer` gains `requestID`/`isResponse` params that set the advertisement's `q` + is_request/is_response flag bits. `LinkSession`'s oversize `sendRequest`/`sendResponse` spawn a request/response Resource; the ADV-spawn gates a response by pending `request_id` (and cancels the request timeout); a completed request/response transfer is routed to `requestReceived`/`responseReceived` (read from the transfer's stored `advertisement`) instead of `resourceReceived`. `Endpoint` is unchanged.

**Tech Stack:** Swift 6, The Composable Architecture ~1.26 (`ResourceTransfer`/`LinkSession` reducers, `TestStore`, `TestClock`, cancellable timers), the in-core `MsgPack`/`Crypto.truncatedHash`/`ResourceAdvertisement`/`Link`/`Packet`; cross-validation against genuine Python-RNS 1.3.8.

## Global Constraints

- **Advertisement flags:** bit 3 (`0x08`) = is_request, bit 4 (`0x10`) = is_response (mutually exclusive); `q` = `request_id` (16-byte `bin`, or nil). Flags built from `(requestID != nil, isResponse)`: `0x01 | (requestID != nil ? (isResponse ? 0x10 : 0x08) : 0)`.
- **Large REQUEST `request_id` = `Crypto.truncatedHash(packed_request)`** — the msgpack blob (NOT a packet hash; the inline path uses the packet's truncated hash). The responder recomputes it as `Crypto.truncatedHash(reassembled payload)`. **Large RESPONSE** payload = `MsgPack([.bin(request_id), .bin(data)])`.
- **Inline threshold** `requestMDU = 431`. Over → Resource. Wire: request/response Resources are ordinary Resources (ADV encrypted, parts plaintext, etc. — unchanged from the merged Resource stack), only the ADV `q`/`f` fields differ.
- `request_id` is consistent per request (both sides use the same derivation for a given request); responses echo the request's `request_id`, so inline↔large cross-paths correlate.
- **Timeout** armed at send, cancelled when the response ADV arrives (a simplification vs RNS's arm-at-delivery).
- **Data-slice index safety:** materialize `Data(...)` before subscripting; stride via `startIndex`.
- **Two-layer purity:** the `ReTiCA` core stays untouched (all primitives exist); TCA lives only in `ReTiCATransport`. `ResourceTransfer.State`/`LinkSession.State` stay `Equatable`.
- **No `Endpoint` change** — existing `sendRequestOverLink`/`sendResponseOverLink` + `requestReceived`/`responseReceived`/`requestFailed` delegates handle large transparently.
- **Commit directly to `main`** (no feature branch). **Build gotcha:** signal-11 = stale build cache → `swift package clean`; never delete code to "fix" it.
- **Mutation-test discipline** for every new/changed test: run-pass → batch-mutate to fail → revert to green, before commit.
- **Commit trailers:** `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.

## File Structure

- `Sources/ReTiCATransport/ResourceTransfer.swift` (**modify**, Task 1) — sender `requestID`/`isResponse` → advertisement.
- `Sources/ReTiCATransport/LinkSession.swift` (**modify**, Tasks 2–3) — large send + inbound routing.
- `Tests/ReTiCATransportTests/ResourceTransferTests.swift` (**modify**, Task 1).
- `Tests/ReTiCATransportTests/LinkSessionRequestTests.swift` (**modify**, Tasks 2–3).
- `Tests/ReTiCANodeTests/EndpointTests.swift` + `Tests/ReTiCATests/Vectors/*` + `README.md` (**modify**, Task 4).

---

### Task 1: `ResourceTransfer` sender `requestID`/`isResponse` → advertisement

**Files:**
- Modify: `Sources/ReTiCATransport/ResourceTransfer.swift`
- Test: `Tests/ReTiCATransportTests/ResourceTransferTests.swift`

**Interfaces:**
- Consumes: `ResourceAdvertisement` (`requestID`/`flags` fields + `isRequest`/`isResponse` accessors).
- Produces: `ResourceTransfer.State.init(sending:…, requestID: Data? = nil, isResponse: Bool = false, …)` building the advertisement with the request/response `q` + flag bits.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ReTiCATransportTests/ResourceTransferTests.swift` (reuse the existing `key`/`linkID`/`prefix`/`r` private constants at the top of the file):

```swift
@Test func senderRequestResourceSetsIsRequestFlagAndRequestID() {
    let rid = Data(repeating: 0xCD, count: 16)
    let s = ResourceTransfer.State(sending: Data(repeating: 0x33, count: 40), linkID: linkID, sessionKey: key,
                                   interfaceID: InterfaceID("s"), prefix: prefix, randomHash: r, sdu: 24,
                                   requestID: rid, isResponse: false)
    #expect(s.advertisement!.requestID == rid)
    #expect(s.advertisement!.isRequest == true)
    #expect(s.advertisement!.isResponse == false)
    #expect(s.advertisement!.flags == 0x09)        // 0x01 | 0x08
}

@Test func senderResponseResourceSetsIsResponseFlag() {
    let rid = Data(repeating: 0xCD, count: 16)
    let s = ResourceTransfer.State(sending: Data(repeating: 0x33, count: 40), linkID: linkID, sessionKey: key,
                                   interfaceID: InterfaceID("s"), prefix: prefix, randomHash: r, sdu: 24,
                                   requestID: rid, isResponse: true)
    #expect(s.advertisement!.requestID == rid)
    #expect(s.advertisement!.isResponse == true)
    #expect(s.advertisement!.isRequest == false)
    #expect(s.advertisement!.flags == 0x11)        // 0x01 | 0x10
}

@Test func senderPlainResourceHasNoRequestID() {
    let s = ResourceTransfer.State(sending: Data(repeating: 0x33, count: 40), linkID: linkID, sessionKey: key,
                                   interfaceID: InterfaceID("s"), prefix: prefix, randomHash: r, sdu: 24)
    #expect(s.advertisement!.requestID == nil)
    #expect(s.advertisement!.flags == 0x01)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter senderRequestResource`
Expected: FAIL (`init` has no `requestID`/`isResponse` parameters).

- [ ] **Step 3: Add the parameters + advertisement plumbing**

In `Sources/ReTiCATransport/ResourceTransfer.swift`, change the `init(sending:)` signature to add the two defaulted params before `rtt`:

```swift
        public init(sending data: Data, linkID: Data, sessionKey: Data, interfaceID: InterfaceID,
                    prefix: Data, randomHash: Data, sdu: Int, requestID: Data? = nil, isResponse: Bool = false,
                    rtt: Duration = .seconds(1), id: UUID = UUID()) {
```

Replace the advertisement construction (currently `requestID: nil, flags: 0x01`) with:

```swift
            let advFlags: UInt8 = 0x01 | (requestID != nil ? (isResponse ? 0x10 : 0x08) : 0)
            self.advertisement = ResourceAdvertisement(
                transferSize: UInt64(stream.count), dataSize: UInt64(data.count),
                numberOfParts: UInt64(chunks.count), hash: h, randomHash: randomHash, originalHash: h,
                segmentIndex: 0, totalSegments: 1, requestID: requestID, flags: advFlags,
                hashmap: mapHashes.prefix(Resource.hashmapMaxLen).reduce(Data()) { $0 + $1 })
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ResourceTransfer`
Expected: PASS — the 3 new tests plus all existing ResourceTransfer tests (existing `sending:` call sites pass neither new param → `requestID: nil, flags: 0x01`, unchanged).

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter ResourceTransfer`, confirm the named test fails, revert; final green:
- Change `isResponse ? 0x10 : 0x08` to `isResponse ? 0x08 : 0x08` → `senderResponseResourceSetsIsResponseFlag` fails.
- Change `requestID != nil ? (...) : 0` to `false ? (...) : 0` (never sets the request/response bit) → `senderRequestResourceSetsIsRequestFlagAndRequestID` fails.
- Change `requestID: requestID` to `requestID: nil` in the advertisement → `senderRequestResourceSetsIsRequestFlagAndRequestID` fails (nil `q`).

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCATransport/ResourceTransfer.swift Tests/ReTiCATransportTests/ResourceTransferTests.swift
git commit -F /tmp/ReTiCA/commit-t1.txt
```
(`/tmp/ReTiCA/commit-t1.txt` first line: `feat: ResourceTransfer sender requestID + is_request/is_response advertisement flags`, blank line, trailers.)

---

### Task 2: `LinkSession` large-request + large-response send

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift`
- Test: `Tests/ReTiCATransportTests/LinkSessionRequestTests.swift`

**Interfaces:**
- Consumes: Task 1's `ResourceTransfer.State.init(sending:…, requestID:, isResponse:)`; `Crypto.truncatedHash`, `randomBytes`, `uuid`, `clock`, `Self.resourceSDU` (464), `Self.requestMDU` (431), `CancelID.request(Data)`.
- Produces: the oversize branches of `.sendRequest`/`.sendResponse` spawn a request/response Resource.

- [ ] **Step 1: Rewrite `.sendRequest` to branch inline vs Resource**

In `Sources/ReTiCATransport/LinkSession.swift`, replace the entire `case let .sendRequest(path, data):` block with:

```swift
            case let .sendRequest(path, data):
                guard state.status == .active else { return .none }
                let pathHash = Crypto.truncatedHash(Data(path.utf8))
                let packed = MsgPack.encode(.array([.double(date.now.timeIntervalSince1970),
                                                    .bin(pathHash), .bin(data)]))
                let ifID = state.interfaceID
                let timeout = (state.rtt ?? 0.5) * 6 + 11.25
                if packed.count <= Self.requestMDU {
                    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                                        destinationType: .link, context: .request, contextFlag: false, hops: 0,
                                        destinationHash: state.linkID, transportId: nil,
                                        payload: Link.encrypt(packed, sessionKey: state.sessionKey))
                    let requestID = packet.truncatedHash
                    guard let raw = try? packet.packed() else { return .none }
                    state.pendingRequests.insert(requestID)
                    return .merge(
                        .send(.delegate(.transmit(ifID, raw))),
                        .run { send in
                            try await clock.sleep(for: .seconds(timeout)); await send(.requestDeadline(requestID))
                        }.cancellable(id: CancelID.request(requestID), cancelInFlight: true))
                } else {
                    // Large request: send as a request-Resource; request_id = truncatedHash(packed blob).
                    let requestID = Crypto.truncatedHash(packed)
                    state.pendingRequests.insert(requestID)
                    let rnd = Data(randomBytes(8))
                    let prefix = Data(rnd[rnd.startIndex ..< rnd.startIndex + 4])
                    let randomHash = Data(rnd[rnd.startIndex + 4 ..< rnd.startIndex + 8])
                    let newID = uuid()
                    state.transfers.append(ResourceTransfer.State(
                        sending: packed, linkID: state.linkID, sessionKey: state.sessionKey,
                        interfaceID: state.interfaceID, prefix: prefix, randomHash: randomHash,
                        sdu: Self.resourceSDU, requestID: requestID, isResponse: false,
                        rtt: .seconds(state.rtt ?? 1), id: newID))
                    return .merge(
                        .send(.transfer(.element(id: newID, action: .advertise))),
                        .run { send in
                            try await clock.sleep(for: .seconds(timeout)); await send(.requestDeadline(requestID))
                        }.cancellable(id: CancelID.request(requestID), cancelInFlight: true))
                }
```

- [ ] **Step 2: Rewrite `.sendResponse` to branch inline vs Resource**

Replace the entire `case let .sendResponse(requestID, data):` block with:

```swift
            case let .sendResponse(requestID, data):
                guard state.status == .active else { return .none }
                let packed = MsgPack.encode(.array([.bin(requestID), .bin(data)]))
                if packed.count <= Self.requestMDU {
                    guard let raw = linkPacket(state.linkID, .response,
                                               Link.encrypt(packed, sessionKey: state.sessionKey))
                    else { return .none }
                    return .send(.delegate(.transmit(state.interfaceID, raw)))
                } else {
                    let rnd = Data(randomBytes(8))
                    let prefix = Data(rnd[rnd.startIndex ..< rnd.startIndex + 4])
                    let randomHash = Data(rnd[rnd.startIndex + 4 ..< rnd.startIndex + 8])
                    let newID = uuid()
                    state.transfers.append(ResourceTransfer.State(
                        sending: packed, linkID: state.linkID, sessionKey: state.sessionKey,
                        interfaceID: state.interfaceID, prefix: prefix, randomHash: randomHash,
                        sdu: Self.resourceSDU, requestID: requestID, isResponse: true,
                        rtt: .seconds(state.rtt ?? 1), id: newID))
                    return .send(.transfer(.element(id: newID, action: .advertise)))
                }
```

- [ ] **Step 3: Write the tests**

Append to `Tests/ReTiCATransportTests/LinkSessionRequestTests.swift` (reuse `activeStore(role:_:)`, `reqKey`, `reqLinkID` from the earlier tasks):

```swift
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
```

> Implementer note: the spawned sender transfer arms a sender watchdog and the request path arms a request timeout — both are in-flight `continuousClock` effects that a `TestStore` requires to settle by teardown. The cleanup shown (cancel the transfer + `clock.advance` past the timeouts) drives them to completion; if a store still reports a dangling effect, extend the advance or add the `.cancel(id:)`/terminal step needed to quiesce it — do NOT weaken the `advertisement`/`pendingRequests` assertions, which are the point of each test. `bigData()` (500 bytes) packs to > 431; if that ever changes, enlarge it.

- [ ] **Step 4: Run to verify**

Run: `swift test --filter LinkSessionRequest`
Expected: PASS (existing IDENTIFY + inline request/response tests + 3 new).

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter LinkSessionRequest`, confirm the named test fails, revert; final green:
- In the large `.sendRequest` branch, change `requestID = Crypto.truncatedHash(packed)` to `Crypto.truncatedHash(Data())` → `largeSendRequestSpawnsRequestResource` fails (wrong requestID).
- In the large `.sendResponse` branch, change `isResponse: true` to `isResponse: false` → `largeSendResponseSpawnsResponseResource` fails (isResponse is false).
- In `.sendRequest`, change `if packed.count <= Self.requestMDU` to `if packed.count <= 100000` (never takes the large branch) → `largeSendRequestSpawnsRequestResource` fails (no transfer spawned).

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionRequestTests.swift
git commit -F /tmp/ReTiCA/commit-t2.txt
```
(First line: `feat: LinkSession large request/response send (over-MDU → Resource)`, blank line, trailers.)

---

### Task 3: `LinkSession` inbound routing (ADV-spawn gate + completion/failed interception)

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift`
- Test: `Tests/ReTiCATransportTests/LinkSessionRequestTests.swift`

**Interfaces:**
- Consumes: `ResourceAdvertisement.isRequest`/`.isResponse`/`.requestID`; `state.transfers[id:]?.advertisement`; `Crypto.truncatedHash`; `MsgPack.decodeValue`; `CancelID.request(Data)`; `state.pendingRequests`.
- Produces: a completed request/response transfer surfaces `requestReceived`/`responseReceived`; the ADV-spawn ignores an unmatched response and cancels the request timeout on a matched one.

- [ ] **Step 1: Gate the ADV-spawn on pending for responses + cancel the request timeout**

Replace the `case (_, .active, .data, .resourceAdvertisement):` block with:

```swift
                case (_, .active, .data, .resourceAdvertisement):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          let adv = ResourceAdvertisement.unpack(plain) else { return .none }
                    if state.transfers.contains(where: { $0.resourceHash == adv.hash }) { return .none }
                    // A response-Resource is only ours if its request_id is currently pending.
                    if adv.isResponse {
                        guard let rid = adv.requestID, state.pendingRequests.contains(rid) else { return .none }
                    }
                    let newID = uuid()
                    let transferRTT: Duration = .seconds(state.rtt ?? 1)
                    state.transfers.append(ResourceTransfer.State(
                        receivingOn: state.linkID, sessionKey: state.sessionKey,
                        interfaceID: state.interfaceID, rtt: transferRTT, id: newID))
                    state.transfers[id: newID]?.resourceHash = adv.hash
                    let accept = Effect<Action>.send(.transfer(.element(id: newID, action: .accept(data))))
                    if adv.isResponse, let rid = adv.requestID {
                        // Response is arriving; stop the request timeout while it downloads.
                        return .merge(accept, .cancel(id: CancelID.request(rid)))
                    }
                    return accept
```

- [ ] **Step 2: Route the transfer-completion interception**

Replace the three `.transfer(.element(...))` delegate cases (`.received`, `.concluded`, `.failed`) with request/response-aware versions:

```swift
            case let .transfer(.element(elementID, .delegate(.received(payload)))):
                let adv = state.transfers[id: elementID]?.advertisement
                if adv?.isRequest == true {
                    guard case let .array(items)? = MsgPack.decodeValue(payload), items.count == 3,
                          case let .bin(pathHash) = items[1], case let .bin(data) = items[2] else { return .none }
                    return .send(.delegate(.requestReceived(requestID: Crypto.truncatedHash(payload),
                                                            pathHash: pathHash, data: data)))
                } else if adv?.isResponse == true {
                    guard case let .array(items)? = MsgPack.decodeValue(payload), items.count == 2,
                          case let .bin(rid) = items[0], case let .bin(data) = items[1],
                          state.pendingRequests.contains(rid) else { return .none }
                    state.pendingRequests.remove(rid)
                    return .merge(.cancel(id: CancelID.request(rid)),
                                  .send(.delegate(.responseReceived(requestID: rid, data: data))))
                }
                return .send(.delegate(.resourceReceived(payload)))
            case let .transfer(.element(elementID, .delegate(.concluded))):
                let adv = state.transfers[id: elementID]?.advertisement
                if adv?.isRequest == true || adv?.isResponse == true { return .none }   // internal req/resp delivery
                guard let hash = state.transfers[id: elementID]?.resourceHash else { return .none }
                return .send(.delegate(.resourceConcluded(hash)))
            case let .transfer(.element(elementID, .delegate(.failed))):
                let t = state.transfers[id: elementID]
                if let rid = t?.advertisement?.requestID, state.pendingRequests.contains(rid) {
                    state.pendingRequests.remove(rid)
                    return .merge(.cancel(id: CancelID.request(rid)),
                                  .send(.delegate(.requestFailed(requestID: rid))))
                }
                if t?.advertisement?.isRequest == true || t?.advertisement?.isResponse == true { return .none }
                guard let hash = t?.resourceHash else { return .none }
                return .send(.delegate(.resourceFailed(hash)))
```

(Leave the `.transmit` interception and the `case .transfer: return .none` fallthrough unchanged.)

- [ ] **Step 3: Write the tests**

Append to `Tests/ReTiCATransportTests/LinkSessionRequestTests.swift`:

```swift
// A hosted sender transfer whose advertisement is marked isRequest/isResponse (used to exercise
// the completion-routing interception directly, without driving a full transfer).
private func hostedTransfer(_ packed: Data, requestID: Data, isResponse: Bool) -> ResourceTransfer.State {
    ResourceTransfer.State(sending: packed, linkID: reqLinkID, sessionKey: reqKey,
                           interfaceID: InterfaceID("i"), prefix: Data([0, 1, 2, 3]),
                           randomHash: Data([4, 5, 6, 7]), sdu: 24, requestID: requestID, isResponse: isResponse)
}

@Test @MainActor func completedRequestResourceSurfacesRequestReceived() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .responder, clock)
    let packed = MsgPack.encode(.array([.double(0), .bin(Crypto.truncatedHash(Data("svc/x".utf8))), .bin(Data("body".utf8))]))
    let t = hostedTransfer(packed, requestID: Crypto.truncatedHash(packed), isResponse: false)
    let tid = t.id
    store.exhaustivity = .off
    await store.withExhaustivity(.off) {}     // no-op; keep exhaustivity off
    // Inject the transfer into state, then fire its .received completion delegate.
    await store.send(.transfer(.element(id: tid, action: .cancel)))   // ensures the id exists is NOT how we inject...
}
```

> Implementer note: `TestStore` does not allow arbitrary mid-test state injection, so build the store's INITIAL state with the hosted transfer already present, then send `.transfer(.element(id: tid, action: .delegate(.received(payload))))` to exercise the interception. Concretely, construct the tests like this (replace the placeholder above):

```swift
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
    let packed = MsgPack.encode(.array([.double(0), .bin(Crypto.truncatedHash(Data("svc/x".utf8))), .bin(Data("body".utf8))]))
    let t = hostedTransfer(packed, requestID: Crypto.truncatedHash(packed), isResponse: false)
    let store = responderStoreWith(t, [], clock)
    let got = LockIsolated<(Data, Data)?>(nil)
    await store.send(.transfer(.element(id: t.id, action: .delegate(.received(packed)))))
    await store.receive { action in
        if case let .delegate(.requestReceived(rid, ph, d)) = action { got.setValue((ph, d)); return rid == Crypto.truncatedHash(packed) }
        return false
    }
    #expect(got.value?.0 == Crypto.truncatedHash(Data("svc/x".utf8)))
    #expect(got.value?.1 == Data("body".utf8))
}

@Test @MainActor func completedResponseResourceRoutesToResponseReceivedAndClearsPending() async {
    let clock = TestClock<Duration>()
    let rid = Data(repeating: 0xCD, count: 16)
    let packed = MsgPack.encode(.array([.bin(rid), .bin(Data("answer".utf8))]))
    let t = hostedTransfer(packed, requestID: rid, isResponse: true)
    let store = responderStoreWith(t, [rid], clock)
    let got = LockIsolated<Data?>(nil)
    await store.send(.transfer(.element(id: t.id, action: .delegate(.received(packed)))))
    await store.receive { action in
        if case let .delegate(.responseReceived(r, d)) = action, r == rid { got.setValue(d); return true }
        return false
    }
    #expect(got.value == Data("answer".utf8))
    #expect(!store.state.pendingRequests.contains(rid))
}

@Test @MainActor func responseAdvertisementNotPendingIsIgnored() async {
    let clock = TestClock<Duration>()
    let store = activeStore(role: .initiator, clock)
    // Build a response-Resource advertisement packet whose request_id is NOT pending.
    let rid = Data(repeating: 0xEE, count: 16)
    let sender = hostedTransfer(MsgPack.encode(.array([.bin(rid), .bin(bigData())])), requestID: rid, isResponse: true)
    let advPacket = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                           destinationType: .link, context: .resourceAdvertisement, contextFlag: false, hops: 0,
                           destinationHash: reqLinkID, transportId: nil,
                           payload: Link.encrypt(sender.advertisement!.pack(), sessionKey: reqKey))
    await store.send(.received(try! advPacket.packed()))
    #expect(store.state.transfers.isEmpty)     // unmatched response ADV → not spawned
}
```

Delete the placeholder `completedRequestResourceSurfacesRequestReceived` stub above; keep only the three real tests (`completedRequestResourceRoutesToRequestReceived`, `completedResponseResourceRoutesToResponseReceivedAndClearsPending`, `responseAdvertisementNotPendingIsIgnored`).

- [ ] **Step 4: Run to verify**

Run: `swift test --filter LinkSessionRequest`
Expected: PASS. Also run `swift test --filter LinkSessionResource` to confirm the PLAIN resource path (received→resourceReceived, concluded→resourceConcluded, failed→resourceFailed) is unaffected — the new branches only fire when `advertisement.isRequest`/`.isResponse` is set, which plain resources never set.

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter LinkSessionRequest`, confirm the named test fails, revert; final green:
- In `.received` routing, change `if adv?.isRequest == true` to `if false` → `completedRequestResourceRoutesToRequestReceived` fails (falls through to `resourceReceived`).
- In `.received` response branch, change `state.pendingRequests.remove(rid)` to a no-op → `completedResponseResourceRoutesToResponseReceivedAndClearsPending` fails (pending not cleared).
- In the ADV-spawn gate, change `guard let rid = adv.requestID, state.pendingRequests.contains(rid)` to `guard true` → `responseAdvertisementNotPendingIsIgnored` fails (spawns anyway).

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionRequestTests.swift
git commit -F /tmp/ReTiCA/commit-t3.txt
```
(First line: `feat: LinkSession routes request/response Resources (ADV gate + completion interception)`, blank line, trailers.)

---

### Task 4: End-to-end large request→large response, cross-validation, gate, README

**Files:**
- Modify: `Tests/ReTiCANodeTests/EndpointTests.swift` (E2E)
- Modify: `Tests/ReTiCATests/Vectors/generate_fixtures.py`, regenerate `fixtures.json`, `VectorFixtures.swift`
- Create: `Tests/ReTiCATests/Vectors/LargeRequestCrossValidationTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–3.

- [ ] **Step 1: Write the end-to-end large request→large response test**

Append to `Tests/ReTiCANodeTests/EndpointTests.swift`. Model it on the merged `twoEndpointsIdentifyAndRoundTripARequest` (the two-store `make(...)` helper + handshake pump to `.active`). After the link is active, A sends a >431-byte request; because both request and response ride Resources, the test must PUMP the resource traffic between the two stores (deliver each `.interface(.send)` frame to the peer, in the same style as the merged `endToEndWindowedTransferWithADroppedPart`/`twoEndpointsTransferAResourceOverALink` tests). The REQUIRED assertions (do NOT weaken): B surfaces `requestReceived` with the exact request `data` and a `requestID`; A surfaces `responseReceived` with the exact response `data` matched to that `requestID`.

```swift
@Test @MainActor func twoEndpointsRoundTripALargeRequestAndResponse() async {
    let clock = TestClock()
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

    // Establish the link (same pump as twoEndpointsIdentifyAndRoundTripARequest steps 1–4).
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

    // A sends a large (>431 packed) request; it rides a Resource.
    let reqData = Data((0..<600).map { UInt8($0 & 0xff) })
    let respData = Data((0..<700).map { UInt8(($0 * 3) & 0xff) })
    await a.send(.sendRequestOverLink(linkID: linkID, path: "svc/echo", data: reqData))

    // Pump ALL A→B frames to B until B surfaces requestReceived (drains the request Resource transfer).
    let gotReqID = LockIsolated<Data?>(nil)
    let gotReqData = LockIsolated<Data?>(nil)
    await pumpUntil(from: a, sentFrom: sentA, to: b, clock: clock) { action in
        if case let .delegate(.requestReceived(_, rid, _, d)) = action { gotReqID.setValue(rid); gotReqData.setValue(d); return true }
        return false
    }
    #expect(gotReqData.value == reqData)

    // B replies with a large response; pump B→A until A surfaces responseReceived.
    await b.send(.sendResponseOverLink(linkID: linkID, requestID: gotReqID.value!, data: respData))
    let gotRespData = LockIsolated<Data?>(nil)
    await pumpUntil(from: b, sentFrom: sentB, to: a, clock: clock) { action in
        if case let .delegate(.responseReceived(_, rid, d)) = action, rid == gotReqID.value! { gotRespData.setValue(d); return true }
        return false
    }
    #expect(gotRespData.value == respData)

    await a.send(.disconnect); await b.send(.disconnect)
}
```

Add the `pumpUntil` helper near the top of `EndpointTests.swift` (it drains every frame the sender emits into the receiver, checking the receiver's delegate stream for the target, mirroring the frame-relay style of the existing two-store resource tests):

```swift
// Relay every frame `from` emits into `to`, until `to` produces a delegate action matching `predicate`.
@MainActor
private func pumpUntil(from: TestStore<Endpoint.State, Endpoint.Action>,
                       sentFrom: LockIsolated<[Data]>,
                       to: TestStore<Endpoint.State, Endpoint.Action>,
                       clock: TestClock<Duration>,
                       _ predicate: @escaping (Endpoint.Action) -> Bool) async {
    var lastDelivered = 0
    var guardCount = 0
    let done = LockIsolated(false)
    while !done.value && guardCount < 500 {
        guardCount += 1
        // Deliver any new frames the sender queued.
        let frames = sentFrom.value
        while lastDelivered < frames.count {
            let frame = frames[lastDelivered]; lastDelivered += 1
            eventsFor(to).yield(.data(frame))
            await to.receive(\.transport.received)
        }
        // Drain the receiver's just-produced actions, watching for the target delegate.
        await to.receive { action in
            if predicate(action) { done.setValue(true); return true }
            return false
        }
    }
}
```

> Implementer note: this pump is a STARTING POINT — the exact `.receive`/relay shape depends on this TCA version's effect-ordering (the merged `twoEndpointsTransferAResourceOverALink` and `endToEndWindowedTransferWithADroppedPart` tests are the working reference for two-store resource pumping; copy their proven relay idiom). `eventsFor(to)` is a placeholder — thread the `AsyncStream` continuations through instead (pass `eventsB`/`eventsA` into the helper, or inline the pump in the test body). The REQUIRED outcome is unchanged: B surfaces `requestReceived` with `reqData`, A surfaces `responseReceived` with `respData` matched to the same `requestID`, and both payloads exceed 431 bytes so they genuinely ride Resources. Do NOT weaken those assertions; adjust the pump mechanics (or payload sizes, keeping them > 431) and document any change. Both endpoints end with `.disconnect`.

- [ ] **Step 2: Add the request/response advertisement cross-validation vector**

In `Tests/ReTiCATests/Vectors/generate_fixtures.py`, after the existing resource block (which already builds a resource with `res_hash`, `res_random_hash`, `res_hashmap`), add a request-advertisement and a response-advertisement built with genuine RNS:

```python
# --- Request/response resource advertisements (q + is_request/is_response flags) ---
rr_request_id = bytes([0xCD] * 16)
rr_req_adv = RNS.ResourceAdvertisement()
rr_req_adv.t = 96; rr_req_adv.d = 40; rr_req_adv.n = 4
rr_req_adv.h = res_hash; rr_req_adv.r = res_random_hash; rr_req_adv.o = res_hash
rr_req_adv.i = 1; rr_req_adv.l = 1; rr_req_adv.m = res_hashmap[:4*4]
rr_req_adv.q = rr_request_id
rr_req_adv.f = 0x00 | 0 << 5 | 0 << 4 | 1 << 3 | 0 << 2 | 0 << 1 | 1   # e=1, u=1
rr_req_adv_packed = rr_req_adv.pack()

rr_resp_adv = RNS.ResourceAdvertisement()
rr_resp_adv.t = 96; rr_resp_adv.d = 40; rr_resp_adv.n = 4
rr_resp_adv.h = res_hash; rr_resp_adv.r = res_random_hash; rr_resp_adv.o = res_hash
rr_resp_adv.i = 1; rr_resp_adv.l = 1; rr_resp_adv.m = res_hashmap[:4*4]
rr_resp_adv.q = rr_request_id
rr_resp_adv.f = 0x00 | 0 << 5 | 1 << 4 | 0 << 3 | 0 << 2 | 0 << 1 | 1   # e=1, p=1
rr_resp_adv_packed = rr_resp_adv.pack()
```

Then in the `json.dumps({...})` dict add:
```python
    "rr_request_id": rr_request_id.hex(),
    "rr_req_adv": rr_req_adv_packed.hex(),
    "rr_resp_adv": rr_resp_adv_packed.hex(),
    "rr_res_hash": res_hash.hex(),
    "rr_res_random_hash": res_random_hash.hex(),
    "rr_res_hashmap4": res_hashmap[:4*4].hex(),
```

Regenerate: `/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/generate_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/fixtures.json`

Verify: `grep -n "rr_req_adv" /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/fixtures.json` (expect one line).

> Note: if `RNS.ResourceAdvertisement()` cannot be constructed field-by-field in this RNS version, build the advertisements by driving a real `RNS.Resource(...)` with `request_id=`/`is_response=` and calling `.pack()` on its advertisement (whatever the existing resource fixtures already do to obtain a packed advertisement) — the requirement is a genuine-RNS packed advertisement with `q` set and the is_request/is_response flag bit set. Report the exact construction used, and keep the Swift side asserting the `q` + `f` bytes match.

- [ ] **Step 3: Decode the fields + write the cross-validation test**

In `Tests/ReTiCATests/Vectors/VectorFixtures.swift`, add properties + CodingKeys for `rrRequestId`/`rrReqAdv`/`rrRespAdv`/`rrResHash`/`rrResRandomHash`/`rrResHashmap4` (snake_case keys).

Create `Tests/ReTiCATests/Vectors/LargeRequestCrossValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func swiftRequestAdvertisementMatchesRns() throws {
    let f = try VectorFixtures.load()
    let adv = ResourceAdvertisement(
        transferSize: 96, dataSize: 40, numberOfParts: 4,
        hash: Data(hexString: f.rrResHash)!, randomHash: Data(hexString: f.rrResRandomHash)!,
        originalHash: Data(hexString: f.rrResHash)!, segmentIndex: 1, totalSegments: 1,
        requestID: Data(hexString: f.rrRequestId)!, flags: 0x09,   // e=1, u=1 (is_request)
        hashmap: Data(hexString: f.rrResHashmap4)!)
    #expect(adv.pack() == Data(hexString: f.rrReqAdv))
}

@Test func swiftResponseAdvertisementMatchesRns() throws {
    let f = try VectorFixtures.load()
    let adv = ResourceAdvertisement(
        transferSize: 96, dataSize: 40, numberOfParts: 4,
        hash: Data(hexString: f.rrResHash)!, randomHash: Data(hexString: f.rrResRandomHash)!,
        originalHash: Data(hexString: f.rrResHash)!, segmentIndex: 1, totalSegments: 1,
        requestID: Data(hexString: f.rrRequestId)!, flags: 0x11,   // e=1, p=1 (is_response)
        hashmap: Data(hexString: f.rrResHashmap4)!)
    #expect(adv.pack() == Data(hexString: f.rrRespAdv))
}
```

> Note: our `ResourceAdvertisement.pack()` must produce the same msgpack map (RNS key order `t,d,n,h,r,o,i,l,q,f,m`) as RNS. If the byte-equality fails only due to msgpack map key-ordering or an int-width difference, that is a real wire-compat finding to surface — do not adjust the fixture to match Swift; investigate which side is right against the merged 6a advertisement cross-validation.

- [ ] **Step 4: Run the filtered suites**

Run: `swift test --filter Endpoint`
Run: `swift test --filter LargeRequestCrossValidation`
Expected: PASS.

- [ ] **Step 5: Run the full suite (gate)**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit (verify fixtures captured)**

```
git add Tests/ReTiCANodeTests/EndpointTests.swift Tests/ReTiCATests/Vectors/generate_fixtures.py Tests/ReTiCATests/Vectors/fixtures.json Tests/ReTiCATests/Vectors/VectorFixtures.swift Tests/ReTiCATests/Vectors/LargeRequestCrossValidationTests.swift
git commit -F /tmp/ReTiCA/commit-t4a.txt
```
(First line: `test: end-to-end large request/response + RNS advertisement cross-validation`, blank line, trailers.)

After committing, run `git show HEAD:Tests/ReTiCATests/Vectors/fixtures.json` (its own command) and confirm `rr_req_adv` is present in the committed blob; if missing, re-stage and `git commit --amend --no-edit`, then re-verify.

- [ ] **Step 7: Mutation sweep (cross-cutting)**

Apply each, run the named filter, confirm the expected failure, revert; final full `swift test` green:
- In `ResourceTransfer.init(sending:)`, change `requestID != nil ? (isResponse ? 0x10 : 0x08) : 0` to always `0` → `swiftRequestAdvertisementMatchesRns` fails (our flag byte no longer matches RNS's `u=1`); run `swift test --filter LargeRequest`.
- In `LinkSession`'s `.received` request routing, change `Crypto.truncatedHash(payload)` to `Data()` → `twoEndpointsRoundTripALargeRequestAndResponse` fails (B's `requestReceived` id is wrong; the subsequent response won't correlate); run `swift test --filter Endpoint`.
Run `swift test` after reverting both → green.

- [ ] **Step 8: Update the README**

In `README.md`, extend the request/response subsection with a large-payload paragraph:

```markdown
Requests and responses larger than 431 bytes are transferred as Resources: the sender advertises a
resource whose advertisement carries the `request_id` (`q`) and an is_request / is_response flag, and the
peer routes the completed transfer to `requestReceived` / `responseReceived` (matched by `request_id`)
rather than the plain `resourceReceived`. A large request's `request_id` is `truncatedHash` of the packed
request. This makes request/response work for any payload size, wire-compatible with Python-RNS 1.3.8.
```

- [ ] **Step 9: Commit**

```
git add README.md
git commit -F /tmp/ReTiCA/commit-t4b.txt
```
(First line: `docs: large (Resource-based) request/response`, blank line, trailers.)

---

## Self-Review

**Spec coverage:**
- `ResourceTransfer` sender `requestID`/`isResponse` → advertisement `q` + is_request/is_response flags → Task 1. ✓
- `LinkSession` oversize `sendRequest`/`sendResponse` → request/response Resource (large `request_id` = `truncatedHash(packed)`) → Task 2. ✓
- ADV-spawn response gate + timeout cancel; completion/failed interception routing (request/response/plain) → Task 3. ✓
- E2E large request→large response + RNS advertisement cross-val + gate + README → Task 4. ✓
- No `Endpoint` change; app-side policy; timeout armed-at-send → as specced. ✓
- Deferred (in-library allow-policy, file responses/metadata/compression) → untouched. ✓

**Placeholder scan:** No TBD/TODO in production steps. The Task 4 pump helper + the Task 2/3 test-cleanup notes are explicit implementer guidance (the exact effect-draining shape is TCA-version-dependent) with the assertions locked — not missing implementation. The Task 3 placeholder stub is explicitly marked for deletion in favor of the three real tests.

**Type consistency:** `init(sending:…, requestID: Data? = nil, isResponse: Bool = false, …)`, `advFlags = 0x01 | (requestID != nil ? (isResponse ? 0x10 : 0x08) : 0)`, `request_id = Crypto.truncatedHash(packed)` (large) vs `packet.truncatedHash` (inline), `CancelID.request(Data)`, `state.transfers[id:]?.advertisement?.isRequest/.isResponse/.requestID`, and the `requestReceived`/`responseReceived`/`requestFailed` delegates are used identically across Tasks 1–4. `requestMDU` (431) / `resourceSDU` (464) match the existing constants. Advertisement flag bits (is_request 0x08, is_response 0x10) match the merged `ResourceAdvertisement` accessors.
