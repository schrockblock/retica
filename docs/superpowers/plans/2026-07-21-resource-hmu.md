# Resource Hashmap-Update (HMU) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transfer resources exceeding 74 parts (~34 KB) in a single `ResourceTransfer` by delivering the part-hashmap incrementally via `RESOURCE_HMU` (0x04), wire-compatible with Python-RNS 1.3.8.

**Architecture:** The advertisement caps its hashmap at `HASHMAP_MAX_LEN = 74` map-hashes; the receiver keeps a growing `knownHashmap`, and when its window scan reaches an unknown slot it sends an exhausted-flagged `RESOURCE_REQ` (`0xFF ‖ last_hash ‖ hash ‖ req`); the sender serves the requested parts and replies with the next 74-hash `RESOURCE_HMU` chunk (`hash ‖ msgpack([chunkIndex, hashes])`); the receiver splices it in and continues. Adds `.array` to the core `MsgPack` codec.

**Tech Stack:** Swift 6, The Composable Architecture ~1.26 (`ResourceTransfer`/`LinkSession` reducers, `TestStore`, `TestClock`), the in-core `MsgPack`/`Resource`/`Link`/`Packet`, CryptoKit; cross-validation against genuine `umsgpack`/Python-RNS 1.3.8.

## Global Constraints

- **`HASHMAP_MAX_LEN = 74`** = `floor((Link.MDU 431 − OVERHEAD 134) / MAPHASH_LEN 4)`. Map-hashes are 4 bytes; the resource hash is 32 bytes.
- **Wire encryption (unchanged):** RESOURCE parts (0x01) and RESOURCE_PRF (0x05) plaintext; RESOURCE_ADV (0x02), RESOURCE_REQ (0x03), **RESOURCE_HMU (0x04)**, ICL (0x06), RCL (0x07) encrypted with the link session key. All resource packets `destinationType == .link`, `destinationHash == linkID`.
- **RESOURCE_REQ formats:** not-exhausted `0x00 ‖ hash(32) ‖ req-map-hashes`; exhausted `0xFF ‖ last_known_map_hash(4) ‖ hash(32) ‖ req-map-hashes`. **RESOURCE_HMU payload:** `hash(32) ‖ MsgPack([chunkIndex: UInt, hashmap_bytes: bin])`, `chunkIndex = part_index / 74`.
- **Advertisement `m`** carries only the first `min(74, numberOfParts)` map-hashes; `n` (numberOfParts) stays the full count.
- **HMU contiguity:** a chunk is spliced only if `chunkIndex·74·4 == knownHashmap.count` (extends exactly); otherwise ignored.
- **Data-slice index safety:** materialize `Data(...)` before subscripting; stride via `startIndex`/`endIndex`.
- **Two-layer purity:** the `ReTiCA` core stays dependency-free; TCA lives only in `ReTiCATransport`. `ResourceTransfer.State` stays `Equatable` + `Identifiable`.
- **Commit directly to `main`** (no feature branch, per project preference).
- **No compound shell commands** (one per invocation; multi-line commit messages via `git commit -F <file>` under `/tmp/ReTiCA/`). **Build gotcha:** a signal-11 crash means a stale build cache → `swift package clean`; never delete/restructure code to "fix" it.
- **Mutation-test discipline** for every new/changed test: run-pass → batch-mutate to force fail → revert to green, before commit.
- **Commit trailers:** `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.

## File Structure

- `Sources/ReTiCA/Support/MsgPack.swift` (**modify**, Task 1) — add `.array`.
- `Sources/ReTiCA/Resource/Resource.swift` (**modify**, Task 2) — `hashmapMaxLen`, `nextWindowRequest` `exhausted`.
- `Sources/ReTiCATransport/ResourceTransfer.swift` (**modify**, Tasks 3–4) — sender + receiver HMU.
- `Sources/ReTiCATransport/LinkSession.swift` (**modify**, Task 4) — route `RESOURCE_HMU`.
- `Tests/ReTiCATests/Support/MsgPackTests.swift` (**modify/create**, Task 1).
- `Tests/ReTiCATests/Resource/ResourceTests.swift` (**modify**, Task 2).
- `Tests/ReTiCATransportTests/ResourceTransferTests.swift` (**modify**, Tasks 3–5).
- `Tests/ReTiCATests/Vectors/generate_fixtures.py` + `fixtures.json` + `VectorFixtures.swift` + a cross-val test (**modify**, Task 5).
- `README.md` (**modify**, Task 5).

---

### Task 1: MsgPack `.array` support (core)

**Files:**
- Modify: `Sources/ReTiCA/Support/MsgPack.swift`
- Test: `Tests/ReTiCATests/Support/MsgPackTests.swift`

**Interfaces:**
- Produces: `MsgPackValue.array([MsgPackValue])`; `MsgPack.encode`/`decodeValue` handle fixarray (`0x90|n`), `array16` (`0xDC`), `array32` (`0xDD`).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ReTiCATests/Support/MsgPackTests.swift` (create the file with `import Testing` + `@testable import ReTiCA` if it does not exist):

```swift
@Test func msgpackEncodesFixarrayOfIntAndBin() {
    // [5, 0x01020304] → 0x92 (fixarray-2) 0x05 (uint 5) 0xC4 0x04 (bin8 len4) 01 02 03 04
    let v = MsgPackValue.array([.uint(5), .bin(Data([1, 2, 3, 4]))])
    #expect(MsgPack.encode(v) == Data([0x92, 0x05, 0xC4, 0x04, 1, 2, 3, 4]))
}

@Test func msgpackArrayRoundTrips() {
    let v = MsgPackValue.array([.uint(148), .bin(Data(repeating: 0xAB, count: 296))])
    #expect(MsgPack.decodeValue(MsgPack.encode(v)) == v)
}

@Test func msgpackEmptyArrayRoundTrips() {
    #expect(MsgPack.decodeValue(MsgPack.encode(.array([]))) == .array([]))
}

@Test func msgpackArray16RoundTripsForLargeArrays() {
    let v = MsgPackValue.array((0..<20).map { MsgPackValue.uint(UInt64($0)) })   // 20 > 15 → array16
    let encoded = MsgPack.encode(v)
    #expect(encoded[encoded.startIndex] == 0xDC)      // array16 tag
    #expect(MsgPack.decodeValue(encoded) == v)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter MsgPack`
Expected: FAIL (no `.array` case).

- [ ] **Step 3: Implement `.array`**

In `Sources/ReTiCA/Support/MsgPack.swift`, add the enum case (in `MsgPackValue`, after `case map([Pair])`):

```swift
    case array([MsgPackValue])
```

In `encode(_ value: MsgPackValue)`, add a case (after `case let .map(pairs):`):

```swift
        case let .array(items): return encodeArray(items)
```

Add the encoder (after `encodeMap`):

```swift
    private static func encodeArray(_ items: [MsgPackValue]) -> Data {
        let n = items.count
        var d: Data
        if n <= 15 { d = Data([0x90 | UInt8(n)]) }
        else if n <= 0xFFFF { d = Data([0xDC]) + beBytes(UInt16(n)) }
        else { d = Data([0xDD]) + beBytes(UInt32(n)) }
        for it in items { d.append(encode(it)) }
        return d
    }
```

In `parse(_:_:)`, add cases (before `default: return nil`):

```swift
        case 0x90...0x9F: return parseArray(b, i + 1, Int(tag & 0x0F))
        case 0xDC: guard i + 2 < b.count else { return nil }; return parseArray(b, i + 3, Int(be(b, i + 1, 2)))
        case 0xDD: guard i + 4 < b.count else { return nil }; return parseArray(b, i + 5, Int(be(b, i + 1, 4)))
```

Add the parser (after `parseMap`):

```swift
    private static func parseArray(_ b: [UInt8], _ start: Int, _ count: Int) -> (MsgPackValue, Int)? {
        var i = start; var items: [MsgPackValue] = []
        for _ in 0..<count {
            guard let (v, ni) = parse(b, i) else { return nil }
            items.append(v); i = ni
        }
        return (.array(items), i)
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter MsgPack`
Expected: PASS (the 4 new tests + any existing MsgPack tests).

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter MsgPack`, confirm the named test fails, revert; final green:
- In `encodeArray`, change `0x90 | UInt8(n)` to `0x80 | UInt8(n)` (emit fixmap tag) → `msgpackEncodesFixarrayOfIntAndBin` fails.
- In `parseArray`, change the loop to `for _ in 0..<(count + 1)` → `msgpackArrayRoundTrips` fails (parse runs off the end / mismatch).

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCA/Support/MsgPack.swift Tests/ReTiCATests/Support/MsgPackTests.swift
git commit -F /tmp/ReTiCA/commit-t1.txt
```
(`/tmp/ReTiCA/commit-t1.txt` first line: `feat: MsgPack array support (fixarray/array16/array32)`, blank line, trailers.)

---

### Task 2: `Resource.hashmapMaxLen` + `nextWindowRequest` exhaustion (core)

**Files:**
- Modify: `Sources/ReTiCA/Resource/Resource.swift`
- Test: `Tests/ReTiCATests/Resource/ResourceTests.swift`

**Interfaces:**
- Consumes: `Resource.mapHashLength` (== 4).
- Produces: `Resource.hashmapMaxLen` (== 74); `nextWindowRequest(receivedIndices:hashmap:height:window:partCount:) -> (indices: [Int], mapHashes: Data, exhausted: Bool)`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ReTiCATests/Resource/ResourceTests.swift`:

```swift
@Test func hashmapMaxLenMatchesRNS() {
    // floor((Link.MDU 431 - OVERHEAD 134) / MAPHASH_LEN 4) = 74
    #expect(Resource.hashmapMaxLen == 74)
}

@Test func nextWindowRequestNotExhaustedWhenHashmapComplete() {
    var hashmap = Data()
    for i in 0..<8 { hashmap += Data(repeating: UInt8(i), count: 4) }
    let req = Resource.nextWindowRequest(receivedIndices: [], hashmap: hashmap,
                                         height: -1, window: 4, partCount: 8)
    #expect(req.indices == [0, 1, 2, 3])
    #expect(req.exhausted == false)
}

@Test func nextWindowRequestExhaustedWhenSlotBeyondKnownHashmap() {
    // Only 2 map hashes known, but 8 parts total. Requesting from height 1 reaches slot 2 (unknown).
    var hashmap = Data()
    for i in 0..<2 { hashmap += Data(repeating: UInt8(i), count: 4) }   // known slots 0,1 only
    let req = Resource.nextWindowRequest(receivedIndices: [0, 1], hashmap: hashmap,
                                         height: 1, window: 4, partCount: 8)
    #expect(req.indices.isEmpty)          // slot 2 is unknown → nothing requested this round
    #expect(req.exhausted == true)
}

@Test func nextWindowRequestExhaustedStopsAfterKnownMissingParts() {
    // 3 map hashes known (slots 0,1,2); slot 0 received, slots 1,2 missing-known, slot 3 unknown.
    var hashmap = Data()
    for i in 0..<3 { hashmap += Data(repeating: UInt8(i), count: 4) }
    let req = Resource.nextWindowRequest(receivedIndices: [0], hashmap: hashmap,
                                         height: 0, window: 4, partCount: 8)
    #expect(req.indices == [1, 2])        // requests the known-missing 1 and 2, then hits unknown 3
    #expect(req.exhausted == true)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter nextWindowRequest`
Expected: FAIL (no `hashmapMaxLen`; `req.exhausted` doesn't exist).

- [ ] **Step 3: Implement**

In `Sources/ReTiCA/Resource/Resource.swift`, add the constant near `mapHashLength`:

```swift
    /// Map hashes that fit in one advertisement / HMU chunk: floor((Link.MDU 431 - 134) / 4) = 74.
    public static let hashmapMaxLen = 74
```

Replace the `nextWindowRequest` function with the exhaustion-aware version:

```swift
    /// Select the next window of still-missing parts to request. Scans the `window` slots after
    /// `height` (bounded by `partCount`), returning the missing indices whose map-hash is KNOWN
    /// (present in `hashmap`) and their concatenated 4-byte map hashes. `exhausted` is `true` when the
    /// scan reaches a missing part whose map-hash is not yet in `hashmap` (the receiver must request an
    /// HMU). Index-safe.
    public static func nextWindowRequest(
        receivedIndices: Set<Int>, hashmap: Data, height: Int, window: Int, partCount: Int
    ) -> (indices: [Int], mapHashes: Data, exhausted: Bool) {
        let m = Data(hashmap)
        var indices: [Int] = []
        var mapHashes = Data()
        var exhausted = false
        var pn = height + 1
        let searchEnd = min(height + 1 + window, partCount)
        while pn < searchEnd {
            if !receivedIndices.contains(pn) {
                let start = m.startIndex + pn * mapHashLength
                let end = start + mapHashLength
                if end > m.endIndex { exhausted = true; break }   // map-hash for this missing part not yet known
                indices.append(pn)
                mapHashes.append(Data(m[start..<end]))
            }
            pn += 1
        }
        return (indices, mapHashes, exhausted)
    }
```

> Note: existing 6c call sites and tests access `req.indices` / `req.mapHashes` by member name, which is unchanged by adding a third tuple member — the package still compiles and the 6c `nextWindowRequest*` tests still pass. For a ≤74-part transfer the hashmap is complete, so `exhausted` is always `false` (behavior identical to 6c).

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter nextWindowRequest`
Then: `swift test --filter Resource` (confirm the existing 6c `nextWindowRequest*` tests still pass).
Expected: PASS.

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter nextWindowRequest`, confirm the named test fails, revert; final green:
- Change `if end > m.endIndex { exhausted = true; break }` to `if end > m.endIndex { break }` (drop the flag) → `nextWindowRequestExhaustedWhenSlotBeyondKnownHashmap` fails.
- Change `hashmapMaxLen = 74` to `= 75` → `hashmapMaxLenMatchesRNS` fails.

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCA/Resource/Resource.swift Tests/ReTiCATests/Resource/ResourceTests.swift
git commit -F /tmp/ReTiCA/commit-t2.txt
```
(First line: `feat: Resource.hashmapMaxLen + nextWindowRequest exhaustion signal`, blank line, trailers.)

---

### Task 3: ResourceTransfer sender HMU

**Files:**
- Modify: `Sources/ReTiCATransport/ResourceTransfer.swift`
- Test: `Tests/ReTiCATransportTests/ResourceTransferTests.swift`

**Interfaces:**
- Consumes: `MsgPack.encode(.array(...))` (Task 1), `Resource.hashmapMaxLen` (Task 2), existing `linkPacket`, `Link.encrypt`, `state.partMapHashes`/`state.parts`.
- Produces: the sender advertises a capped hashmap; the `.resourceRequest` handler parses the `0x00`/`0xFF` flag, serves parts, and emits `RESOURCE_HMU` on exhaustion (cancels on a non-74-boundary).

- [ ] **Step 1: Cap the advertisement hashmap at `hashmapMaxLen`**

In `Sources/ReTiCATransport/ResourceTransfer.swift`, in `init(sending:)`, replace the advertisement's `hashmap:` argument (currently `hashmap: mapHashes.reduce(Data()) { $0 + $1 }`) with the capped form:

```swift
                hashmap: mapHashes.prefix(Resource.hashmapMaxLen).reduce(Data()) { $0 + $1 })
```

(For ≤74 parts this is unchanged: `prefix(74)` of ≤74 items is all of them.)

- [ ] **Step 2: Rewrite the sender request handler to parse both flags and emit HMU**

Replace the entire `case (.sender, .data, .resourceRequest):` block with:

```swift
                case (.sender, .data, .resourceRequest):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey) else { return .none }
                    let p = Data(plain)
                    guard let flag = p.first else { return .none }
                    let wantsHMU = flag == 0xFF
                    let pad = wantsHMU ? 1 + Resource.mapHashLength : 1      // 5 or 1
                    guard p.count >= pad + 32,
                          Data(p[(p.startIndex + pad)..<(p.startIndex + pad + 32)]) == state.resourceHash
                    else { return .none }
                    state.status = .transferring
                    state.retriesLeft = Const.maxRetries
                    let reqHashes = Data(p.dropFirst(pad + 32))
                    var effects: [Effect<Action>] = []
                    var i = reqHashes.startIndex
                    while i + 4 <= reqHashes.endIndex {
                        let mh = Data(reqHashes[i..<(i + 4)])
                        if let idx = state.partMapHashes.firstIndex(of: mh),
                           let raw = linkPacket(.data, .resource, state.parts[idx]) {
                            state.sentIndices.insert(idx)
                            effects.append(.send(.delegate(.transmit(state.interfaceID, raw))))
                        }
                        i += 4
                    }
                    if wantsHMU {
                        let lastMapHash = Data(p[(p.startIndex + 1)..<(p.startIndex + 1 + Resource.mapHashLength)])
                        if let li = state.partMapHashes.firstIndex(of: lastMapHash) {
                            let partIndex = li + 1
                            if partIndex % Resource.hashmapMaxLen != 0 {
                                // sequencing error → cancel the transfer (matches RNS)
                                state.status = .failed
                                let icl = linkPacket(.data, .resourceInitiatorCancel,
                                                     Link.encrypt(state.resourceHash, sessionKey: state.sessionKey))
                                return .merge(.cancel(id: CancelID.watchdog),
                                              icl.map { Effect.send(.delegate(.transmit(state.interfaceID, $0))) } ?? .none,
                                              .send(.delegate(.failed)))
                            }
                            let chunk = partIndex / Resource.hashmapMaxLen
                            let lo = chunk * Resource.hashmapMaxLen
                            let hi = min((chunk + 1) * Resource.hashmapMaxLen, state.partMapHashes.count)
                            let chunkBytes = state.partMapHashes[lo..<hi].reduce(Data()) { $0 + $1 }
                            let hmu = state.resourceHash + MsgPack.encode(.array([.uint(UInt64(chunk)), .bin(chunkBytes)]))
                            if let raw = linkPacket(.data, .resourceHashmapUpdate,
                                                    Link.encrypt(hmu, sessionKey: state.sessionKey)) {
                                effects.append(.send(.delegate(.transmit(state.interfaceID, raw))))
                            }
                        }
                    }
                    if state.sentIndices.count == state.parts.count {
                        state.status = .awaitingProof
                    }
                    effects.append(armSenderWatchdog(state))
                    return .merge(effects)
```

- [ ] **Step 3: Write the sender tests**

Append to `Tests/ReTiCATransportTests/ResourceTransferTests.swift`. Reuse the existing `senderState(_:sdu:)`, `captureTransmits(_:count:)`, `key`, `linkID` helpers. Use a payload big enough for >74 parts at a small SDU (e.g. `sdu: 8` → each part 8 bytes; 700 bytes of data → stream ≈ 704+ → ~88 parts).

```swift
// Build an exhausted RESOURCE_REQ (0xFF ‖ lastHash ‖ hash ‖ requested) for a sender state.
private func exhaustedRequestPacket(_ s: ResourceTransfer.State, lastMapHash: Data, requested: [Data]) -> Data {
    var payload = Data([0xFF]) + lastMapHash + s.resourceHash
    for h in requested { payload += h }
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .resourceRequest, contextFlag: false, hops: 0,
                   destinationHash: linkID, transportId: nil, payload: Link.encrypt(payload, sessionKey: key))
    return try! p.packed()
}

@Test @MainActor func senderAdvertisementCapsHashmapAt74() async {
    let data = Data(repeating: 0x5A, count: 800)          // > 74 parts at sdu 8
    let s = senderState(data, sdu: 8)
    #expect(s.parts.count > 74)
    #expect(s.advertisement!.hashmap.count == 74 * 4)     // capped, not the full N*4
    #expect(s.advertisement!.numberOfParts == UInt64(s.parts.count))
}

@Test @MainActor func senderRepliesWithHmuChunkOnExhaustedRequest() async {
    let data = Data(repeating: 0x5A, count: 800)
    let s = senderState(data, sdu: 8)
    let clock = TestClock<Duration>()
    let store = TestStore(initialState: s) { ResourceTransfer() }
        withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    // Exhausted request: last known map-hash is partMapHashes[73] (74-boundary).
    let last = s.partMapHashes[73]
    await store.send(.received(exhaustedRequestPacket(s, lastMapHash: last, requested: [])))
    // The sender emits a RESOURCE_HMU for chunk 1 (parts 74..147).
    let raw = (await captureTransmits(store, count: 1)).first { Packet(raw: $0)?.context == .resourceHashmapUpdate }!
    let plain = Data(Link.decrypt(Packet(raw: raw)!.payload, sessionKey: key)!)
    #expect(Data(plain.prefix(32)) == s.resourceHash)
    guard case let .array(items)? = MsgPack.decodeValue(Data(plain.dropFirst(32))),
          case let .uint(chunkIndex) = items[0], case let .bin(bytes) = items[1] else { Issue.record("bad HMU"); return }
    #expect(chunkIndex == 1)
    let expectedCount = min(74, s.partMapHashes.count - 74) * 4
    #expect(bytes.count == expectedCount)
    #expect(bytes == s.partMapHashes[74..<min(148, s.partMapHashes.count)].reduce(Data()) { $0 + $1 })
    // cleanup: drive terminal
    await store.send(.received(cancelPacket(.resourceReceiverCancel, s.resourceHash)))
}

@Test @MainActor func senderCancelsOnNonBoundaryHmuRequest() async {
    let data = Data(repeating: 0x5A, count: 800)
    let s = senderState(data, sdu: 8)
    let clock = TestClock<Duration>()
    let store = TestStore(initialState: s) { ResourceTransfer() }
        withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    // last known map-hash at a NON-boundary index (e.g. partMapHashes[72] → partIndex 73, 73 % 74 != 0).
    let last = s.partMapHashes[72]
    await store.send(.received(exhaustedRequestPacket(s, lastMapHash: last, requested: [])))
    await store.receive(.delegate(.failed))
    #expect(store.state.status == .failed)
    let icl = (await captureTransmits(store, count: 1)).first { Packet(raw: $0)?.context == .resourceInitiatorCancel }
    #expect(icl != nil)
}
```

> If `cancelPacket(_:_:)` is not already a helper in this test file (it was added in the integration slice's tests, which live in a different file), inline the RCL cleanup: build a `.resourceReceiverCancel` packet with `Link.encrypt(s.resourceHash, sessionKey: key)` payload, or instead drive the sender to `.awaitingProof`+conclude. Keep whichever compiles; the point of the cleanup is only to cancel the armed sender watchdog.

- [ ] **Step 4: Run to verify**

Run: `swift test --filter ResourceTransfer`
Expected: PASS — the 3 new sender tests plus all existing ResourceTransfer tests (the flag-parsing change is backward-compatible: a `0x00` REQ still parses with `pad = 1`).

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter ResourceTransfer`, confirm the named test fails, revert; final green:
- In `init(sending:)`, drop the `.prefix(Resource.hashmapMaxLen)` (emit the full hashmap) → `senderAdvertisementCapsHashmapAt74` fails.
- In the HMU emit, change `let chunk = partIndex / Resource.hashmapMaxLen` to `... + 1` → `senderRepliesWithHmuChunkOnExhaustedRequest` fails (wrong chunkIndex + wrong bytes).
- Change the boundary guard `partIndex % Resource.hashmapMaxLen != 0` to `== 0` → `senderCancelsOnNonBoundaryHmuRequest` fails (no cancel) and `senderRepliesWithHmuChunkOnExhaustedRequest` fails (cancels instead of HMU).

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCATransport/ResourceTransfer.swift Tests/ReTiCATransportTests/ResourceTransferTests.swift
git commit -F /tmp/ReTiCA/commit-t3.txt
```
(First line: `feat: ResourceTransfer sender HMU (capped ADV, exhausted-REQ parse, HMU reply)`, blank line, trailers.)

---

### Task 4: ResourceTransfer receiver HMU + LinkSession routing

**Files:**
- Modify: `Sources/ReTiCATransport/ResourceTransfer.swift`
- Modify: `Sources/ReTiCATransport/LinkSession.swift`
- Test: `Tests/ReTiCATransportTests/ResourceTransferTests.swift`

**Interfaces:**
- Consumes: Task 2's `nextWindowRequest` (with `exhausted`) + `Resource.hashmapMaxLen`; Task 1's `MsgPack`; existing receiver flow.
- Produces: receiver `State` fields `knownHashmap: Data`, `hashmapHeight: Int`, `waitingForHMU: Bool`; exhausted-REQ emission; `(.receiver, .data, .resourceHashmapUpdate)` ingest; `LinkSession` routes `RESOURCE_HMU`.

- [ ] **Step 1: Add receiver State fields**

In `ResourceTransfer.State` (after `public var proofRetriesLeft: Int`), add:

```swift
        // hashmap-update (receiver)
        public var knownHashmap: Data
        public var hashmapHeight: Int
        public var waitingForHMU: Bool
```

In BOTH initializers, initialize them (after the `proofRetriesLeft` assignment):

```swift
            self.knownHashmap = Data()
            self.hashmapHeight = 0
            self.waitingForHMU = false
```

- [ ] **Step 2: Seed the hashmap on `.accept`**

In `case let .accept(data):`, after `state.advertisement = adv`, add:

```swift
                state.knownHashmap = Data(adv.hashmap)
                state.hashmapHeight = adv.hashmap.count / Resource.mapHashLength
                state.waitingForHMU = false
```

- [ ] **Step 3: Rewrite `requestNextWindow` to use the growing hashmap + emit exhausted REQ**

Replace the `requestNextWindow` local function with:

```swift
            func requestNextWindow(_ s: inout State) -> Effect<Action> {
                if s.waitingForHMU { return armReceiverWatchdog(s) }   // await the HMU; don't spam REQs
                let received = Set(s.receivedParts.keys)
                let req = Resource.nextWindowRequest(
                    receivedIndices: received, hashmap: s.knownHashmap,
                    height: s.consecutiveCompletedHeight, window: s.window.window,
                    partCount: Int(s.expectedParts))
                s.outstanding = Set(req.indices)
                var payload: Data
                if req.exhausted, s.hashmapHeight > 0 {
                    let last = Data(s.knownHashmap.suffix(Resource.mapHashLength))   // knownHashmap[hashmapHeight-1]
                    payload = Data([0xFF]) + last + s.resourceHash + req.mapHashes
                    s.waitingForHMU = true
                } else {
                    payload = Data([0x00]) + s.resourceHash + req.mapHashes
                }
                let linkID = s.linkID
                let interfaceID = s.interfaceID
                let sessionKey = s.sessionKey
                let watchdog = armReceiverWatchdog(s)
                let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                               destinationType: .link, context: .resourceRequest, contextFlag: false, hops: 0,
                               destinationHash: linkID, transportId: nil,
                               payload: Link.encrypt(payload, sessionKey: sessionKey))
                guard let raw = try? p.packed() else { return .none }
                return .merge(.send(.delegate(.transmit(interfaceID, raw))), watchdog)
            }
```

- [ ] **Step 4: Reset `waitingForHMU` on the retransmit watchdog**

In `case .receiverDeadline:`, in the retry branch (after `state.retriesLeft -= 1`, before `return requestNextWindow(&state)`), add:

```swift
                state.waitingForHMU = false
```

(so a lost HMU is retried — the exhausted REQ is re-sent).

- [ ] **Step 5: Use `knownHashmap` for inbound part placement**

In `case (.receiver, .data, .resource):`, change the placement scan to use `state.knownHashmap` instead of `adv.hashmap`. Replace `let m = Data(adv.hashmap)` with:

```swift
                    let m = Data(state.knownHashmap)
```

(the `guard ... let adv = state.advertisement` line stays — `adv` is no longer needed for the scan but the guard confirms an advertisement was accepted; leave it.)

- [ ] **Step 6: Add the HMU ingest case**

Add a new inbound case in the `switch (state.role, packet.packetType, packet.context)`, before `default:`:

```swift
                case (.receiver, .data, .resourceHashmapUpdate):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey) else { return .none }
                    let p = Data(plain)
                    guard p.count >= 32,
                          Data(p[p.startIndex..<(p.startIndex + 32)]) == state.resourceHash else { return .none }
                    guard case let .array(items)? = MsgPack.decodeValue(Data(p.dropFirst(32))),
                          items.count == 2,
                          case let .uint(chunkIndex) = items[0],
                          case let .bin(chunkBytes) = items[1] else { return .none }
                    let offset = Int(chunkIndex) * Resource.hashmapMaxLen * Resource.mapHashLength
                    guard offset == state.knownHashmap.count else { return .none }   // must extend contiguously
                    state.knownHashmap.append(chunkBytes)
                    state.hashmapHeight = state.knownHashmap.count / Resource.mapHashLength
                    state.waitingForHMU = false
                    return requestNextWindow(&state)
```

- [ ] **Step 7: Route `RESOURCE_HMU` in LinkSession**

In `Sources/ReTiCATransport/LinkSession.swift`, add `.resourceHashmapUpdate` to the existing broadcast routing case (the tuple list that currently ends with `(_, .active, .proof, .resourceProof):`). Add one line to the case list:

```swift
                     (_, .active, .data, .resourceHashmapUpdate),
```

(place it among the other `(_, .active, .data, .resource*)` entries so HMU packets fan out to the hosted transfers).

- [ ] **Step 8: Write the receiver tests**

Append to `Tests/ReTiCATransportTests/ResourceTransferTests.swift`. Reuse `receiverStore(_:)`, `advertisementPacket(_:)`, `partPacket(_:)`, `senderState`, `captureTransmits`, `key`, `linkID`.

```swift
// Build a RESOURCE_HMU packet for chunk `idx` carrying `hashes`.
private func hmuPacket(_ hash: Data, chunk: Int, hashes: Data) -> Data {
    let payload = hash + MsgPack.encode(.array([.uint(UInt64(chunk)), .bin(hashes)]))
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .resourceHashmapUpdate, contextFlag: false, hops: 0,
                   destinationHash: linkID, transportId: nil, payload: Link.encrypt(payload, sessionKey: key))
    return try! p.packed()
}

@Test @MainActor func receiverEmitsExhaustedRequestWhenHashmapRunsOut() async {
    let data = Data(repeating: 0x33, count: 800)          // > 74 parts at sdu 8
    let sender = senderState(data, sdu: 8)
    let clock = TestClock<Duration>()
    let store = receiverStore(clock)
    await store.send(.accept(advertisementPacket(sender)))
    #expect(store.state.hashmapHeight == 74)              // ADV seeded first 74
    _ = await captureTransmits(store, count: 1)           // first REQ (parts 0..3, all known)

    // Feed parts 0..73 so the window advances to the hashmap boundary.
    for n in 0..<74 {
        await store.send(.received(partPacket(sender.parts[n])))
    }
    // The receiver, reaching an unknown slot, emits an EXHAUSTED request.
    let raw = (await captureTransmits(store, count: 1)).first {
        Link.decrypt(Packet(raw: $0)!.payload, sessionKey: key)?.first == 0xFF
    }
    #expect(raw != nil)
    let plain = Data(Link.decrypt(Packet(raw: raw!)!.payload, sessionKey: key)!)
    #expect(Data(plain[(plain.startIndex + 1)..<(plain.startIndex + 5)]) == sender.partMapHashes[73])  // last known hash
    #expect(store.state.waitingForHMU == true)
    // cleanup
    await store.send(.cancel); _ = await captureTransmits(store, count: 1)
}

@Test @MainActor func receiverIngestsHmuAndExtendsHashmap() async {
    let data = Data(repeating: 0x33, count: 800)
    let sender = senderState(data, sdu: 8)
    let clock = TestClock<Duration>()
    let store = receiverStore(clock)
    await store.send(.accept(advertisementPacket(sender)))
    _ = await captureTransmits(store, count: 1)
    for n in 0..<74 { await store.send(.received(partPacket(sender.parts[n]))) }
    _ = await captureTransmits(store, count: 1)           // exhausted REQ
    #expect(store.state.waitingForHMU == true)

    // Deliver chunk 1 (parts 74..min(148,N)).
    let hi = min(148, sender.partMapHashes.count)
    let chunkBytes = sender.partMapHashes[74..<hi].reduce(Data()) { $0 + $1 }
    await store.send(.received(hmuPacket(sender.resourceHash, chunk: 1, hashes: chunkBytes)))
    #expect(store.state.hashmapHeight == hi)
    #expect(store.state.waitingForHMU == false)
    // The receiver resumes requesting (a normal REQ goes out).
    let more = (await captureTransmits(store, count: 1)).first {
        Link.decrypt(Packet(raw: $0)!.payload, sessionKey: key)?.first == 0x00
    }
    #expect(more != nil)
    // cleanup
    await store.send(.cancel); _ = await captureTransmits(store, count: 1)
}
```

- [ ] **Step 9: Run to verify**

Run: `swift test --filter ResourceTransfer` then `swift test --filter LinkSession`
Expected: PASS (new receiver tests + existing transfer/link tests; the ≤74-part existing tests are unaffected because their hashmap is complete → never exhausted).

- [ ] **Step 10: Mutation sweep**

Apply each, run `swift test --filter ResourceTransfer`, confirm the named test fails, revert; final green:
- In `requestNextWindow`, remove the `if req.exhausted, s.hashmapHeight > 0 { ... }` branch (always send `0x00`) → `receiverEmitsExhaustedRequestWhenHashmapRunsOut` fails.
- In the HMU ingest, change `guard offset == state.knownHashmap.count` to `guard offset >= 0` (drop contiguity) then also change the append to a no-op is two changes — instead change `state.knownHashmap.append(chunkBytes)` to a no-op (`state.knownHashmap.append(Data())`) → `receiverIngestsHmuAndExtendsHashmap` fails (`hashmapHeight` doesn't grow).
- In LinkSession, remove the `(_, .active, .data, .resourceHashmapUpdate),` line → run `swift test --filter ResourceTransfer` is unaffected, so instead verify via the E2E in Task 5; note this mutation is covered there. (Skip here.)

- [ ] **Step 11: Commit**

```
git add Sources/ReTiCATransport/ResourceTransfer.swift Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/ResourceTransferTests.swift
git commit -F /tmp/ReTiCA/commit-t4.txt
```
(First line: `feat: ResourceTransfer receiver HMU + LinkSession routing`, blank line, trailers.)

---

### Task 5: End-to-end >74-part transfer, umsgpack cross-validation, gate, README

**Files:**
- Modify: `Tests/ReTiCATransportTests/ResourceTransferTests.swift` (E2E)
- Modify: `Tests/ReTiCATests/Vectors/generate_fixtures.py`, regenerate `fixtures.json`, `VectorFixtures.swift`
- Create: `Tests/ReTiCATests/Vectors/HmuCrossValidationTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–4.

- [ ] **Step 1: Write the end-to-end >74-part transfer test**

Append to `Tests/ReTiCATransportTests/ResourceTransferTests.swift`. Model it on the existing `endToEndWindowedTransferWithADroppedPart` (two `ResourceTransfer` stores, packet pump, no `clock.advance`). Use a payload that yields ~90–120 parts at `sdu: 8` so the transfer crosses at least one HMU boundary (74).

```swift
@Test @MainActor func endToEndTransferWithHmuAcrossHashmapBoundary() async {
    let data = Data((0..<900).map { UInt8($0 & 0xff) })   // ~113 parts at sdu 8 → ≥1 HMU round
    let senderClock = TestClock<Duration>()
    let receiverClock = TestClock<Duration>()
    let sender = TestStore(initialState: senderState(data, sdu: 8)) { ResourceTransfer() }
        withDependencies: { $0.continuousClock = senderClock }
    sender.exhaustivity = .off
    let receiver = TestStore(initialState: receiverState()) { ResourceTransfer() }
        withDependencies: { $0.continuousClock = receiverClock }
    receiver.exhaustivity = .off

    await sender.send(.advertise)
    let adv = (await captureTransmits(sender, count: 1))[0]
    await receiver.send(.accept(adv))
    var req = (await captureTransmits(receiver, count: 1))[0]

    let got = LockIsolated<Data?>(nil)
    var guardCount = 0
    while receiver.state.status != .complete && guardCount < 400 {
        guardCount += 1
        // The sender emits exactly `requested parts (+ 1 HMU if the REQ was exhausted)` transmits.
        let n = expectedSenderTransmits(req)
        await sender.send(.received(req))
        let outs = await captureTransmits(sender, count: n)
        for frame in outs { await receiver.send(.received(frame)) }   // parts + HMU both route in
        if receiver.state.status == .complete {
            await receiver.receive { if case .delegate(.transmit) = $0 { return true }; return false }  // PRF
            await receiver.receive { action in
                if case let .delegate(.received(d)) = action { got.setValue(d); return true }
                return false
            }
            break
        }
        // Receiver emits its next request (normal or exhausted) in response to the parts/HMU it got.
        req = (await captureTransmits(receiver, count: 1))[0]
    }
    #expect(got.value == data)
    #expect(receiver.state.status == .complete)
    #expect(sender.state.parts.count > 74)               // the transfer genuinely crossed the HMU boundary

    // Feed the proof back so the sender concludes.
    let proof = Resource.proofData(data: data, hash: sender.state.resourceHash)
    let pkt = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                     destinationType: .link, context: .resourceProof, contextFlag: false, hops: 0,
                     destinationHash: linkID, transportId: nil, payload: proof)
    await sender.send(.received(try! pkt.packed()))
    await sender.receive(.delegate(.concluded))
    #expect(sender.state.status == .complete)
}
```

Add the `expectedSenderTransmits` helper near `captureTransmits` — it derives the exact transmit count for a round by parsing the request the receiver just sent (requested-part count, plus one HMU when the request is exhausted-flagged):

```swift
// How many transmits the sender will emit in response to `reqFrame`:
// one RESOURCE part per requested map-hash, plus one RESOURCE_HMU if the request was exhausted (0xFF).
private func expectedSenderTransmits(_ reqFrame: Data) -> Int {
    let plain = Data(Link.decrypt(Packet(raw: reqFrame)!.payload, sessionKey: key)!)
    let exhausted = plain.first == 0xFF
    let pad = exhausted ? 5 : 1                    // flag(1) [+ last_map_hash(4) when exhausted]
    let reqBytes = max(0, plain.count - pad - 32)  // minus flag/pad and the 32-byte resource hash
    let parts = reqBytes / 4
    return parts + (exhausted ? 1 : 0)
}
```

> Implementer note: this deterministic pump requires that every part and every HMU the sender emits reaches the receiver, the receiver reconstructs the exact `data`, both reach `.complete`, and the transfer crosses the 74-part boundary (`sender.state.parts.count > 74`). Do NOT weaken `#expect(got.value == data)` or the `.complete` assertions. If TCA effect-ordering needs a small adjustment (e.g. the sender emits an HMU on a round where `reqBytes == 0`, which `expectedSenderTransmits` already handles as `0 + 1`), adjust the pump while keeping every invariant proven; document any change. If a chosen payload size doesn't cross the boundary, enlarge it (keep >74 parts at `sdu: 8`).

- [ ] **Step 2: Add the umsgpack cross-validation vector**

In `Tests/ReTiCATests/Vectors/generate_fixtures.py`, after the existing resource block, add (using the same `umsgpack` the generator already imports):

```python
# --- HMU msgpack payload: umsgpack.packb([chunk_index, hashmap_bytes]) ---
hmu_chunk_index = 1
hmu_hashmap = bytes(range(0, 296))[:296]   # 74 * 4 deterministic bytes
hmu_msgpack = umsgpack.packb([hmu_chunk_index, hmu_hashmap])
```

Then in the `json.dumps({...})` dict add:

```python
    "hmu_msgpack": hmu_msgpack.hex(),
    "hmu_hashmap": hmu_hashmap.hex(),
```

Regenerate: `/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/generate_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/fixtures.json`

Verify: `grep -n "hmu_msgpack" /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/fixtures.json` (expect one line).

- [ ] **Step 3: Decode the new fields + write the cross-validation test**

In `Tests/ReTiCATests/Vectors/VectorFixtures.swift`, add the two properties + CodingKeys:

```swift
    let hmuMsgpack: String
    let hmuHashmap: String
```
```swift
        case hmuMsgpack = "hmu_msgpack"
        case hmuHashmap = "hmu_hashmap"
```

Create `Tests/ReTiCATests/Vectors/HmuCrossValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func swiftMsgpackArrayMatchesUmsgpack() throws {
    let f = try VectorFixtures.load()
    let hashmap = Data(hexString: f.hmuHashmap)!
    // Our MsgPack must encode [1, hashmap] byte-identically to genuine umsgpack.
    let built = MsgPack.encode(.array([.uint(1), .bin(hashmap)]))
    #expect(built == Data(hexString: f.hmuMsgpack))
}
```

- [ ] **Step 4: Run the filtered suites**

Run: `swift test --filter ResourceTransfer`
Run: `swift test --filter Hmu`
Expected: PASS.

- [ ] **Step 5: Run the full suite (gate)**

Run: `swift test`
Expected: PASS — all prior suites plus the HMU core/reducer/cross-val tests and the E2E.

- [ ] **Step 6: Commit (verify fixtures captured)**

```
git add Tests/ReTiCATransportTests/ResourceTransferTests.swift Tests/ReTiCATests/Vectors/generate_fixtures.py Tests/ReTiCATests/Vectors/fixtures.json Tests/ReTiCATests/Vectors/VectorFixtures.swift Tests/ReTiCATests/Vectors/HmuCrossValidationTests.swift
git commit -F /tmp/ReTiCA/commit-t5a.txt
```
(First line: `test: end-to-end HMU transfer + umsgpack cross-validation`, blank line, trailers.)

After committing, run `git show HEAD:Tests/ReTiCATests/Vectors/fixtures.json` and confirm `hmu_msgpack` is present in the committed blob (an external linter has reverted this file before); if missing, re-stage and `git commit --amend --no-edit`, then re-verify.

- [ ] **Step 7: Mutation sweep (cross-cutting)**

Apply each, run the named filter, confirm the expected failure, revert; final full `swift test` green:
- In `LinkSession`, remove the `(_, .active, .data, .resourceHashmapUpdate),` routing line → `endToEndTransferWithHmuAcrossHashmapBoundary` (if it runs through LinkSession) OR, since the E2E is reducer-level, instead: in `ResourceTransfer` HMU ingest change `state.knownHashmap.append(chunkBytes)` to a no-op → `endToEndTransferWithHmuAcrossHashmapBoundary` fails (never gets past part 74). Run `swift test --filter ResourceTransfer`.
- In `MsgPack.encodeArray`, change `0x90 | UInt8(n)` to `0x80 | UInt8(n)` → `swiftMsgpackArrayMatchesUmsgpack` fails. Run `swift test --filter Hmu`.
Run `swift test` after reverting both → green.

- [ ] **Step 8: Update the README**

In `README.md`, extend the resource-transfer section with an HMU paragraph:

```markdown
### Large resources: hashmap-update (HMU)

A resource with more than `HASHMAP_MAX_LEN` = 74 parts (~34 KB at SDU 464) is transferred in a single
`ResourceTransfer` whose part-hashmap is delivered incrementally. The advertisement carries only the
first 74 map-hashes; as the receiver's window reaches an unknown slot it sends an exhausted-flagged
`RESOURCE_REQ` (`0xFF ‖ last-hash ‖ hash ‖ requested`), and the sender replies with the next 74-hash
`RESOURCE_HMU` chunk (`hash ‖ msgpack([chunkIndex, hashes])`, encrypted). This lifts the single-transfer
ceiling to ~1 MB, wire-compatible with Python-RNS 1.3.8. Resources larger than that (true multi-segment
sub-resources) remain a future slice.
```

- [ ] **Step 9: Commit**

```
git add README.md
git commit -F /tmp/ReTiCA/commit-t5b.txt
```
(First line: `docs: Resource hashmap-update (HMU)`, blank line, trailers.)

---

## Self-Review

**Spec coverage:**
- MsgPack `.array` (fixarray/array16/array32) → Task 1. ✓
- `hashmapMaxLen = 74` + `nextWindowRequest` `exhausted` → Task 2. ✓
- Sender: capped ADV hashmap, `0x00`/`0xFF` REQ parse, `RESOURCE_HMU` reply, 74-boundary cancel → Task 3. ✓
- Receiver: `knownHashmap`/`hashmapHeight`/`waitingForHMU`, accept-seed, exhausted-REQ emit, HMU ingest (contiguity), `knownHashmap` placement, watchdog reset → Task 4. ✓
- `LinkSession` routes `RESOURCE_HMU` → Task 4. ✓
- E2E >74-part transfer + umsgpack cross-val + gate + README → Task 5. ✓
- Deferred (multi-segment, compression) → untouched. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. The Task 5 `drainAllTransmits`/pump note is explicit implementer guidance (the E2E's exact effect-draining shape depends on this TCA version), with the required invariants stated and assertions locked — not a missing implementation.

**Type consistency:** `hashmapMaxLen`, `nextWindowRequest(...) -> (indices, mapHashes, exhausted)`, `knownHashmap`/`hashmapHeight`/`waitingForHMU`, `MsgPackValue.array`, the `0xFF ‖ last(4) ‖ hash(32) ‖ req` REQ and `hash(32) ‖ msgpack([chunk, bin])` HMU layouts, and context `.resourceHashmapUpdate` (0x04) are used identically across Tasks 1–5. `resourceHash` is 32 bytes everywhere (matching the existing `.resourceRequest` parse). `mapHashLength` (4) and `hashmapMaxLen` (74) are the two distinct constants used consistently.
