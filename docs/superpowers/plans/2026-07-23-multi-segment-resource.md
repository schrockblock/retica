# True Multi-Segment (>1MB) Resources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transfer resources larger than `MAX_EFFICIENT_SIZE` (1,048,575 bytes) by splitting them into sequential sub-resources (segments), byte-compatible with Python-RNS 1.3.8; reassemble on receive. Also fixes the latent single-segment `segment_index = 0` interop bug (RNS uses 1-based).

**Architecture:** `ResourceTransfer.init(sending:)` gains segment parameters (`segmentIndex`/`totalSegments`/`originalHash`/`totalDataSize`) that populate the advertisement's already-existing `i`/`l`/`o` fields + `isSplit` flag. `LinkSession` grows a sender coordinator (split → send segments sequentially, advancing on each `.concluded`) and a receiver accumulator (group by `originalHash`, buffer by `segmentIndex`, concatenate on the last segment). Core `ReTiCA` and `Endpoint` are unchanged.

**Tech Stack:** Swift 6, The Composable Architecture (~1.26), the existing `Resource`/`ResourceAdvertisement`/`ResourceTransfer`/`LinkSession` machinery, and cross-validation against genuine Python-RNS 1.3.8 (driven via a proven `RNS.Resource` segmentation harness).

## Global Constraints

- **`MAX_EFFICIENT_SIZE = 1_048_575`** (1 MiB − 1). Split when `data.count > MAX_EFFICIENT_SIZE`; `N = ((count - 1) / MAX_EFFICIENT_SIZE) + 1` (ceil). Segment k (1-based) carries bytes `[(k-1)*MAX, min(k*MAX, count))`.
- **`segment_index` is 1-based** (1..N). Single-segment = `i=1, l=1, o=h, isSplit clear`. **This changes the current hard-coded `i=0` — a real interop fix.**
- **Per-segment independence:** each segment is its own `ResourceTransfer` with its own `hash = resourceHash(segment_data)`, `random_hash`, hashmap, proof, and bz2 compression decision (HMU applies per-segment, unchanged). `originalHash` (o) = the FIRST segment's `hash` `h₁`, shared by every segment's ADV (the grouping key). `dataSize` (d) = the WHOLE resource size in every segment's ADV; `transferSize` (t) = that segment's encrypted stream size. `isSplit` = advertisement flag bit 2 (`0x04`), set iff `totalSegments > 1`.
- **Sequential send:** advertise segment k+1 only after segment k concludes. **Sequential/in-order receive-buffer:** buffer each verified segment by index; deliver the whole (concatenation in index order) only when all N are present.
- **Two-layer purity:** all changes in `ReTiCATransport`. `Sources/ReTiCA/*` (core) and the wire advertisement model do NOT change. `Endpoint` is unchanged (a multi-segment receive still surfaces one `resourceReceived(linkID:data:)`).
- **Verified during planning (empirically, against genuine RNS 1.3.8):** the above field mapping — `i` 1-based, `l=N`, `o=h₁` (shared), `d`=whole, `t`=per-segment stream, `f` split bit `0x04` — was confirmed by driving a real `RNS.Resource` to segment (see Task 4's harness).
- Build gotcha: signal-11/SIGILL during `swift test` → `swift package clean` then retry; never delete State fields to "fix" a crash.
- **Mutation-test discipline** for every new/changed test. **Commit directly to `main`.** Trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.

## File Structure

- `Sources/ReTiCATransport/ResourceTransfer.swift` (**modify**, Task 1) — segment params + `i=1` default + isSplit.
- `Tests/ReTiCATransportTests/ResourceTransferTests.swift` (**modify**, Task 1).
- `Tests/ReTiCATests/Vectors/generate_fixtures.py` + `fixtures.json` + `Tests/ReTiCATests/Vectors/ResourceCrossValidationTests.swift` (**modify**, Task 1) — the existing resource-adv fixture hard-codes `i=0`; correct to `i=1`.
- `Sources/ReTiCATransport/LinkSession.swift` (**modify**, Tasks 2 & 3) — sender coordinator + receiver accumulator.
- `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift` (**modify**, Tasks 2 & 3).
- `Tests/ReTiCANodeTests/EndpointTests.swift` (**modify**, Task 4) — E2E.
- `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py` + `transport_fixtures.json` + `TransportVectorFixtures.swift` + new `MultiSegmentCrossValidationTests.swift` (**modify/create**, Task 4).
- `README.md` (**modify**, Task 4).

---

### Task 1: `ResourceTransfer` segment parameters + single-segment `i=1` fix

**Files:**
- Modify: `Sources/ReTiCATransport/ResourceTransfer.swift`
- Test: `Tests/ReTiCATransportTests/ResourceTransferTests.swift`
- Modify: `Tests/ReTiCATests/Vectors/generate_fixtures.py`, `fixtures.json`, `Tests/ReTiCATests/Vectors/ResourceCrossValidationTests.swift`

**Interfaces:**
- Produces: `ResourceTransfer.State.init(sending:…, segmentIndex: UInt64 = 1, totalSegments: UInt64 = 1, originalHash: Data? = nil, totalDataSize: UInt64? = nil, …)` populating advertisement `i`/`l`/`o`/`d` + isSplit.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ReTiCATransportTests/ResourceTransferTests.swift` (reuse the file's `key`/`linkID`/`prefix`/`r`):

```swift
@Test func singleSegmentAdvertisesIndexOneNotSplit() {
    let s = ResourceTransfer.State(sending: incompressibleData(count: 40), linkID: linkID, sessionKey: key,
                                   interfaceID: InterfaceID("s"), prefix: prefix, randomHash: r, sdu: 24)
    #expect(s.advertisement!.segmentIndex == 1)          // RNS uses 1-based (was 0)
    #expect(s.advertisement!.totalSegments == 1)
    #expect(s.advertisement!.originalHash == s.advertisement!.hash)
    #expect(s.advertisement!.isSplit == false)
}

@Test func segmentParamsPopulateAdvertisement() {
    let whole: UInt64 = 3_000_000
    let oh = Data(repeating: 0xAB, count: 32)
    let s = ResourceTransfer.State(sending: incompressibleData(count: 500), linkID: linkID, sessionKey: key,
                                   interfaceID: InterfaceID("s"), prefix: prefix, randomHash: r, sdu: 24,
                                   segmentIndex: 2, totalSegments: 3, originalHash: oh, totalDataSize: whole)
    #expect(s.advertisement!.segmentIndex == 2)
    #expect(s.advertisement!.totalSegments == 3)
    #expect(s.advertisement!.originalHash == oh)          // inherited, NOT this segment's hash
    #expect(s.advertisement!.dataSize == whole)           // whole size, not this segment's
    #expect(s.advertisement!.isSplit == true)             // l > 1
}
```

Run: `swift test --filter segmentParamsPopulateAdvertisement` → FAIL (params don't exist).

- [ ] **Step 2: Add the parameters + advertisement plumbing**

In `init(sending:)`, add the four defaulted params (before `rtt`):

```swift
        public init(sending data: Data, linkID: Data, sessionKey: Data, interfaceID: InterfaceID,
                    prefix: Data, randomHash: Data, sdu: Int, requestID: Data? = nil, isResponse: Bool = false,
                    segmentIndex: UInt64 = 1, totalSegments: UInt64 = 1, originalHash: Data? = nil,
                    totalDataSize: UInt64? = nil, rtt: Duration = .seconds(1), id: UUID = UUID()) {
```

Change the advertisement construction: `advFlags` gains the split bit, and `originalHash`/`segmentIndex`/`totalSegments`/`dataSize` use the params:

```swift
            let advFlags: UInt8 = 0x01 | (didCompress ? 0x02 : 0) | (totalSegments > 1 ? 0x04 : 0)
                                       | (requestID != nil ? (isResponse ? 0x10 : 0x08) : 0)
            self.advertisement = ResourceAdvertisement(
                transferSize: UInt64(stream.count), dataSize: totalDataSize ?? UInt64(data.count),
                numberOfParts: UInt64(chunks.count), hash: h, randomHash: randomHash,
                originalHash: originalHash ?? h,
                segmentIndex: segmentIndex, totalSegments: totalSegments, requestID: requestID, flags: advFlags,
                hashmap: mapHashes.prefix(Resource.hashmapMaxLen).reduce(Data()) { $0 + $1 })
```

(`h = Resource.resourceHash(data: data, …)` stays this segment's own hash; `didCompress`/`payload` from the compression slice are unchanged.)

- [ ] **Step 3: Run to verify** — `swift test --filter ResourceTransfer` → the 2 new pass. Existing `sending:` call sites pass no segment params → `i=1, l=1, o=h, isSplit clear`.

- [ ] **Step 4: Fix the `i=0` cross-val fixture + tests**

The existing resource-advertisement cross-val hard-codes `i=0`. In `Tests/ReTiCATests/Vectors/generate_fixtures.py`, find the resource advertisement block (`_adv.i = 0; _adv.l = 1`) and change to `_adv.i = 1` (RNS's real single-segment value). Regenerate: `/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/generate_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/fixtures.json` (its own command). Then update any Swift assertion in `ResourceCrossValidationTests.swift` (and elsewhere) that constructed a `ResourceAdvertisement(… segmentIndex: 0 …)` to `segmentIndex: 1`, so our pack still matches the regenerated fixture. Grep the repo for `segmentIndex: 0` and `\.i = 0` and fix each. (This is the interop-fix half of the task — our single-segment resources now advertise the RNS-correct index.)

- [ ] **Step 5: Run** — `swift test --filter Resource` and `swift test --filter CrossValidation` → PASS.

- [ ] **Step 6: Mutation sweep**

Apply each, run `swift test --filter ResourceTransfer`, confirm the named test fails, revert; final green:
- Change default `segmentIndex: UInt64 = 1` to `= 0` → `singleSegmentAdvertisesIndexOneNotSplit` fails.
- Change `originalHash ?? h` to `h` (ignore param) → `segmentParamsPopulateAdvertisement` fails (originalHash wrong).
- Change `(totalSegments > 1 ? 0x04 : 0)` to `0` → `segmentParamsPopulateAdvertisement` fails (isSplit false).
- Change `totalDataSize ?? UInt64(data.count)` to `UInt64(data.count)` → `segmentParamsPopulateAdvertisement` fails (dataSize wrong).

- [ ] **Step 7: Commit**

```
git add Sources/ReTiCATransport/ResourceTransfer.swift Tests/ReTiCATransportTests/ResourceTransferTests.swift Tests/ReTiCATests/Vectors/generate_fixtures.py Tests/ReTiCATests/Vectors/fixtures.json Tests/ReTiCATests/Vectors/ResourceCrossValidationTests.swift
git commit -F /tmp/ReTiCA/commit-m1.txt
```
(First line: `feat: ResourceTransfer segment params + fix single-segment index to 1 (RNS interop)`, blank line, trailers.)

---

### Task 2: `LinkSession` sender split coordinator

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift`
- Test: `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift`

**Interfaces:**
- Consumes: Task 1's segment params; the existing `sendResource`/`.advertise` path; the hosted-transfer `.concluded` interception.
- Produces: `LinkSession.sendResource` splits `> maxEfficientSize` data into sequential segments; surfaces `resourceConcluded(originalHash)` once when the last concludes.

- [ ] **Step 1: Add the constant + coordinator State**

In `LinkSession`: `static let maxEfficientSize = 1_048_575`. Add to `State` a value describing an in-flight segmented send:

```swift
        public struct SegmentedSend: Equatable, Sendable {
            public var remaining: [Data]        // segment payloads not yet sent (index order, cursor at front)
            public var nextIndex: UInt64         // 1-based index of the NEXT segment to send
            public var total: UInt64
            public var originalHash: Data
            public var totalDataSize: UInt64
            public var currentTransferID: UUID   // the hosted transfer for the segment in flight
        }
        public var segmentedSend: SegmentedSend? = nil
```

- [ ] **Step 2: Split in `sendResource`**

Replace the `.sendResource(data)` case body: single-segment unchanged (now `i=1` via Task 1 defaults); oversize splits and sends segment 1.

```swift
            case let .sendResource(data):
                guard state.status == .active else { return .none }
                let rnd = Data(randomBytes(8))
                let prefix = Data(rnd[rnd.startIndex ..< rnd.startIndex + 4])
                let randomHash = Data(rnd[rnd.startIndex + 4 ..< rnd.startIndex + 8])
                let newID = uuid()
                if data.count <= Self.maxEfficientSize {
                    state.transfers.append(ResourceTransfer.State(
                        sending: data, linkID: state.linkID, sessionKey: state.sessionKey,
                        interfaceID: state.interfaceID, prefix: prefix, randomHash: randomHash,
                        sdu: Self.resourceSDU, rtt: .seconds(state.rtt ?? 1), id: newID))
                    return .send(.transfer(.element(id: newID, action: .advertise)))
                }
                // Split into ceil(count / maxEfficientSize) segments (index order).
                var segments: [Data] = []
                var off = data.startIndex
                while off < data.endIndex {
                    let end = data.index(off, offsetBy: Self.maxEfficientSize, limitedBy: data.endIndex) ?? data.endIndex
                    segments.append(Data(data[off ..< end]))
                    off = end
                }
                let total = UInt64(segments.count)
                let seg0 = segments[0]
                state.transfers.append(ResourceTransfer.State(
                    sending: seg0, linkID: state.linkID, sessionKey: state.sessionKey,
                    interfaceID: state.interfaceID, prefix: prefix, randomHash: randomHash,
                    sdu: Self.resourceSDU, segmentIndex: 1, totalSegments: total,
                    originalHash: nil, totalDataSize: UInt64(data.count),
                    rtt: .seconds(state.rtt ?? 1), id: newID))
                let originalHash = state.transfers[id: newID]?.resourceHash ?? Data()
                state.segmentedSend = State.SegmentedSend(
                    remaining: Array(segments.dropFirst()), nextIndex: 2, total: total,
                    originalHash: originalHash, totalDataSize: UInt64(data.count), currentTransferID: newID)
                return .send(.transfer(.element(id: newID, action: .advertise)))
```

- [ ] **Step 3: Advance on `.concluded` (sender segments)**

In the hosted-transfer `.concluded` interception, BEFORE the existing plain-resource `resourceConcluded` surface, handle a segmented send:

```swift
            case let .transfer(.element(elementID, .delegate(.concluded))):
                let adv = state.transfers[id: elementID]?.advertisement
                let hash = state.transfers[id: elementID]?.resourceHash
                state.transfers.remove(id: elementID)
                if adv?.isRequest == true || adv?.isResponse == true { return .none }
                // Segmented send in progress on this element?
                if var send = state.segmentedSend, send.currentTransferID == elementID {
                    if send.remaining.isEmpty {
                        // last segment concluded → surface the whole once
                        state.segmentedSend = nil
                        return .send(.delegate(.resourceConcluded(send.originalHash)))
                    }
                    let nextData = send.remaining.removeFirst()
                    let idx = send.nextIndex
                    let rnd = Data(randomBytes(8))
                    let prefix = Data(rnd[rnd.startIndex ..< rnd.startIndex + 4])
                    let randomHash = Data(rnd[rnd.startIndex + 4 ..< rnd.startIndex + 8])
                    let nextID = uuid()
                    state.transfers.append(ResourceTransfer.State(
                        sending: nextData, linkID: state.linkID, sessionKey: state.sessionKey,
                        interfaceID: state.interfaceID, prefix: prefix, randomHash: randomHash,
                        sdu: Self.resourceSDU, segmentIndex: idx, totalSegments: send.total,
                        originalHash: send.originalHash, totalDataSize: send.totalDataSize,
                        rtt: .seconds(state.rtt ?? 1), id: nextID))
                    send.nextIndex += 1
                    send.currentTransferID = nextID
                    state.segmentedSend = send
                    return .send(.transfer(.element(id: nextID, action: .advertise)))
                }
                guard let hash else { return .none }
                return .send(.delegate(.resourceConcluded(hash)))
```

(A segmented-send `.failed` on the current element clears `segmentedSend` and surfaces `resourceFailed(originalHash)` — add the symmetric check in the `.failed` interception.)

- [ ] **Step 4: Write the tests**

Append to `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift`. Reuse the file's active-store helper. Because a real >1 MB transfer is huge, TEST WITH A LOWERED VIEW where possible: assert the SPLIT + SEQUENCING logic by inspecting `state.transfers` advertisements and driving `.concluded` manually, rather than pumping millions of real bytes.

```swift
@Test @MainActor func sendResourceSplitsOversizeIntoSequentialSegments() async {
    let clock = TestClock<Duration>()
    let store = activeResourceStore(clock)               // existing active-link store helper
    store.exhaustivity = .off
    // 2 segments: maxEfficientSize + 100. Use incompressible so it doesn't shrink under threshold.
    let whole = incompressibleData(count: LinkSession.maxEfficientSize + 100)
    await store.send(.sendResource(whole))
    // Segment 1 is advertised now: i=1, l=2, isSplit, d=whole.
    let t0 = store.state.transfers[0]
    #expect(t0.advertisement!.segmentIndex == 1)
    #expect(t0.advertisement!.totalSegments == 2)
    #expect(t0.advertisement!.isSplit == true)
    #expect(t0.advertisement!.dataSize == UInt64(whole.count))
    #expect(store.state.segmentedSend != nil)
    let oh = store.state.segmentedSend!.originalHash
    // Segment 1 concludes → segment 2 is advertised (i=2, same originalHash), no resourceConcluded yet.
    await store.send(.transfer(.element(id: t0.id, action: .delegate(.concluded))))
    let t1 = store.state.transfers.first { $0.advertisement?.segmentIndex == 2 }
    #expect(t1 != nil)
    #expect(t1!.advertisement!.originalHash == oh)
    #expect(t1!.advertisement!.totalSegments == 2)
    // Segment 2 concludes → resourceConcluded(originalHash) once, segmentedSend cleared.
    await store.send(.transfer(.element(id: t1!.id, action: .delegate(.concluded))))
    await store.receive { if case let .delegate(.resourceConcluded(h)) = $0 { return h == oh }; return false }
    #expect(store.state.segmentedSend == nil)
    // Quiesce any spawned sender watchdogs.
    await clock.advance(by: .seconds(300))
}
```

> Implementer note: build `activeResourceStore` / segment payloads to match the file's real helpers. `LinkSession.maxEfficientSize + 100` is ~1 MB — the sender `ResourceTransfer.init` will chunk seg 1 into ~2260 parts (fast, no network). If that construction is too slow for the test, lower the effective threshold ONLY via test data by asserting the split arithmetic on a smaller boundary is not possible (the constant is fixed); instead keep the ~1 MB payload but assert on advertisement fields + `.concluded`-driven sequencing WITHOUT pumping real parts (as above). Do NOT weaken the assertions: segment 1 is i=1/l=2/isSplit/d=whole; concluding segment 1 spawns i=2 with the shared originalHash; concluding the last surfaces exactly one `resourceConcluded(originalHash)`.

- [ ] **Step 5: Run** — `swift test --filter LinkSessionResource` → PASS.

- [ ] **Step 6: Mutation sweep**

Apply each, confirm the named test fails, revert; final green:
- In `.sendResource`, change `if data.count <= Self.maxEfficientSize` to `if true` (never split) → `sendResourceSplitsOversizeIntoSequentialSegments` fails (no segmentedSend / not split).
- In the `.concluded` advance, change `send.originalHash` in the surfaced `resourceConcluded` to `hash ?? Data()` → the test's `resourceConcluded(originalHash)` match fails.
- Change `segmentIndex: idx` for the next segment to `segmentIndex: 1` → the `t1.segmentIndex == 2` expectation fails.

- [ ] **Step 7: Commit**

```
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionResourceTests.swift
git commit -F /tmp/ReTiCA/commit-m2.txt
```
(First line: `feat: LinkSession splits oversize resources into sequential segments`, blank line, trailers.)

---

### Task 3: `LinkSession` receiver accumulator

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift`
- Test: `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift`

**Interfaces:**
- Consumes: the hosted receiver transfer's stored `advertisement` (with `isSplit`/`segmentIndex`/`totalSegments`/`originalHash`) at `.received`; the terminal interception.
- Produces: multi-segment receives surface exactly one `resourceReceived(whole)`.

- [ ] **Step 1: Add accumulator State**

```swift
        public struct SegmentAccumulator: Equatable, Sendable {
            public var total: UInt64
            public var parts: [UInt64: Data]     // segmentIndex (1-based) -> segment data
        }
        public var incomingSegments: [Data: SegmentAccumulator] = [:]   // keyed by originalHash
```

- [ ] **Step 2: Route split segments at `.received`**

In the `.transfer(.element(_, .delegate(.received(payload))))` interception, after the request/response branches, replace the final plain `resourceReceived` with split-aware handling:

```swift
                let advR = state.transfers[id: elementID]?.advertisement
                if advR?.isSplit == true, let a = advR {
                    var acc = state.incomingSegments[a.originalHash] ?? State.SegmentAccumulator(total: a.totalSegments, parts: [:])
                    acc.parts[a.segmentIndex] = payload
                    if UInt64(acc.parts.count) == acc.total {
                        // All segments in → concatenate in index order (1..total) → surface once.
                        state.incomingSegments[a.originalHash] = nil
                        var whole = Data()
                        for i in 1...acc.total { whole.append(acc.parts[i] ?? Data()) }
                        return .send(.delegate(.resourceReceived(whole)))
                    }
                    state.incomingSegments[a.originalHash] = acc
                    return .none    // wait for the next segment
                }
                return .send(.delegate(.resourceReceived(payload)))
```

(A split segment still sends its own proof via the transfer's own `.received`→proof path — unchanged; only the LinkSession-level surfacing is deferred.)

- [ ] **Step 3: Fail the whole on a split-segment failure**

In the `.failed` interception, before the plain `resourceFailed`, if the failed transfer's advertisement `isSplit`, drop the accumulator + surface `resourceFailed(originalHash)`:

```swift
                if let a = t?.advertisement, a.isSplit == true {
                    state.incomingSegments[a.originalHash] = nil
                    return .send(.delegate(.resourceFailed(a.originalHash)))
                }
```

- [ ] **Step 4: Write the tests**

Append to `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift`. Build a store hosting two receiver transfers whose advertisements are split segments 1 and 2 sharing an `originalHash`; fire their `.received` in turn; assert the whole is surfaced ONCE after the second, equal to `seg1 ‖ seg2`.

```swift
@Test @MainActor func receivedSplitSegmentsReassembleAndSurfaceOnce() async {
    let clock = TestClock<Duration>()
    let oh = Data(repeating: 0x11, count: 32)
    let seg1 = Data("hello ".utf8), seg2 = Data("world".utf8)
    // Host two receiver transfers with split advertisements (i=1 and i=2, l=2, shared o=oh).
    let store = resourceStoreHostingSplitReceivers(oh: oh, total: 2, clock)   // helper: see note
    let (id1, id2) = (store.state.transfers[0].id, store.state.transfers[1].id)
    store.exhaustivity = .off
    // Segment 1 received → buffered, nothing surfaced yet.
    await store.send(.transfer(.element(id: id1, action: .delegate(.received(seg1)))))
    #expect(store.state.incomingSegments[oh]?.parts.count == 1)
    // Segment 2 received → whole surfaced once = seg1 ‖ seg2.
    await store.send(.transfer(.element(id: id2, action: .delegate(.received(seg2)))))
    await store.receive { if case let .delegate(.resourceReceived(d)) = $0 { return d == seg1 + seg2 }; return false }
    #expect(store.state.incomingSegments[oh] == nil)
}

@Test @MainActor func splitSegmentFailureFailsTheWhole() async {
    let clock = TestClock<Duration>()
    let oh = Data(repeating: 0x11, count: 32)
    let store = resourceStoreHostingSplitReceivers(oh: oh, total: 2, clock)
    let id1 = store.state.transfers[0].id
    store.exhaustivity = .off
    await store.send(.transfer(.element(id: id1, action: .delegate(.failed))))
    await store.receive { if case let .delegate(.resourceFailed(h)) = $0 { return h == oh }; return false }
}
```

> Implementer note: `resourceStoreHostingSplitReceivers(oh:total:_:)` builds an active-link store whose `state.transfers` holds `total` receiver `ResourceTransfer.State`s, each with a stored `advertisement` that is split (`isSplit`, `totalSegments = total`, `originalHash = oh`, `segmentIndex = 1..total`, and a per-segment `hash`). Mirror how the file already injects receiver transfers with advertisements (the existing inbound-ADV tests). The REQUIRED assertions (do NOT weaken): after the last segment's `.received`, exactly ONE `resourceReceived(seg1 ‖ seg2 ‖ …)` in index order; a single-segment (non-split) `.received` still surfaces immediately (add/keep a test); a split-segment `.failed` surfaces one `resourceFailed(originalHash)`.

- [ ] **Step 5: Run** — `swift test --filter LinkSessionResource` → PASS. Confirm the existing single-segment (non-split) resource tests still surface `resourceReceived` immediately (the new branch only fires when `isSplit`).

- [ ] **Step 6: Mutation sweep**

Apply each, confirm the named test fails, revert; final green:
- Change `for i in 1...acc.total { whole.append(acc.parts[i] ?? Data()) }` to `for i in stride(from: acc.total, through: 1, by: -1) …` (reverse order) → `receivedSplitSegmentsReassembleAndSurfaceOnce` fails (`world hello ` ≠ `hello world`).
- Change `if UInt64(acc.parts.count) == acc.total` to `>= 1` (surface after the first) → the "nothing surfaced yet after segment 1" assertion fails (surfaces early / wrong data).
- In `.failed`, remove the `isSplit` branch → `splitSegmentFailureFailsTheWhole` fails (no `resourceFailed(oh)`).

- [ ] **Step 7: Commit**

```
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionResourceTests.swift
git commit -F /tmp/ReTiCA/commit-m3.txt
```
(First line: `feat: LinkSession reassembles multi-segment resources by originalHash`, blank line, trailers.)

---

### Task 4: End-to-end round-trip + genuine-RNS cross-validation + gate + README

**Files:**
- Modify: `Tests/ReTiCANodeTests/EndpointTests.swift`
- Modify: `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py`, `transport_fixtures.json`, `TransportVectorFixtures.swift`
- Create: `Tests/ReTiCATransportTests/Vectors/MultiSegmentCrossValidationTests.swift`
- Modify: `README.md`

- [ ] **Step 1: End-to-end two-Endpoint multi-segment round-trip**

Append to `Tests/ReTiCANodeTests/EndpointTests.swift`, modeled on the existing `twoEndpointsTransferAResourceOverALink` / `endToEndTransferWithHmuAcrossHashmapBoundary` (establish a link, then pump the resource). Round-trip a **> maxEfficientSize** resource (2 segments) and assert B surfaces ONE `resourceReceived(linkID:data:)` equal to the exact original.

Required assertions (do NOT weaken): a payload of `LinkSession.maxEfficientSize + K` bytes (2 segments) is sent via `sendResourceOverLink`; both segments are pumped over the link (each its own ADV/parts/proof); B surfaces exactly one `delegate.resourceReceived(linkID:, data:)` with `data == original`. Use an INCOMPRESSIBLE payload so it genuinely exceeds the threshold post-compression and stays 2 segments; a ~1 MB transfer at sdu 464 is many parts — reuse the existing HMU E2E pump idiom and keep `K` small (e.g. a few KB) so segment 2 is tiny.

> Implementer note: this is the heaviest pump in the suite (~2260 parts for segment 1). If wall-clock is a problem, this is the one place a temporarily very large test SDU is unacceptable (SDU is wire-fixed at 464). Keep the test but scope segment 1 to exactly one over-threshold boundary; if it proves too slow to be a good unit test, mark it clearly and still assert the two-segment round-trip. If, after genuinely reusing the existing resource-pump idiom, the full pump is intractable, deliver the split/reassemble coverage via Tasks 2–3 (already unit-tested) and report the E2E as BLOCKED with specifics — do NOT fake it.

- [ ] **Step 2: Genuine-RNS multi-segment cross-validation fixture**

Add to `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py` a segmentation harness that drives a REAL `RNS.Resource` to split a >MAX payload and emits the two genuine segment advertisements (packed bytes + field values). This harness is PROVEN (verified during planning):

```python
import os, RNS
from RNS.Resource import Resource, ResourceAdvertisement

_RealPacket = RNS.Packet
class _FakePacket:                     # bypass real part-packet construction (needs a full link)
    RESOURCE = _RealPacket.RESOURCE
    def __init__(self, *a, **k): self.map_hash = None; self.data = None
    def pack(self, *a, **k): return b""
RNS.Packet = _FakePacket

class _StubLink:
    mtu = None
    mdu = 200000                       # large SDU → few parts → fast; segmentation is sdu-independent
    rtt = 0.1
    traffic_timeout_factor = 1.5
    def encrypt(self, data): return data

_MAX = Resource.MAX_EFFICIENT_SIZE      # 1048575
_total = _MAX + 100                     # 2 segments
_payload = os.urandom(_total)           # distinct parts → avoids RNS's collision-remap loop
_link = _StubLink()
_seg1 = Resource(_payload, _link, advertise=False, auto_compress=False, segment_index=1)
_seg2 = Resource(_seg1.input_file, _link, advertise=False, auto_compress=False,
                 segment_index=2, original_hash=_seg1.original_hash)
_a1, _a2 = ResourceAdvertisement(_seg1), ResourceAdvertisement(_seg2)
RNS.Packet = _RealPacket                # restore
```

Add to the emitted JSON dict (each `adv.pack()` is the genuine RNS-packed segment advertisement):

```python
    "ms_max_efficient_size": _MAX,
    "ms_total_size": _total,
    "ms_seg1_adv": _a1.pack().hex(),
    "ms_seg2_adv": _a2.pack().hex(),
    "ms_seg1_i": _a1.i, "ms_seg1_l": _a1.l, "ms_seg1_o": _a1.o.hex(), "ms_seg1_d": _a1.d, "ms_seg1_f": _a1.f,
    "ms_seg2_i": _a2.i, "ms_seg2_o": _a2.o.hex(), "ms_seg2_f": _a2.f,
```

Regenerate (its own command): `/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATransportTests/Vectors/transport_fixtures.json`. Verify: `grep -n ms_seg1_adv /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATransportTests/Vectors/transport_fixtures.json` (one line).

- [ ] **Step 3: Decode + cross-validation test**

Add the `ms_*` fields to `TransportVectorFixtures.swift` (snake_case CodingKeys). Create `Tests/ReTiCATransportTests/Vectors/MultiSegmentCrossValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCATransport
@testable import ReTiCA

@Test func genuineRnsSegmentAdvertisementsUnpackWithSegmentFields() throws {
    let f = try TransportVectorFixtures.load()
    let a1 = ResourceAdvertisement.unpack(Data(hexString: f.msSeg1Adv)!)!
    let a2 = ResourceAdvertisement.unpack(Data(hexString: f.msSeg2Adv)!)!
    #expect(a1.segmentIndex == 1)                                   // RNS 1-based
    #expect(a2.segmentIndex == 2)
    #expect(a1.totalSegments == 2 && a2.totalSegments == 2)
    #expect(a1.isSplit && a2.isSplit)                               // f bit 2
    #expect(a1.originalHash == a2.originalHash)                     // shared grouping key = seg1 hash
    #expect(a1.originalHash == a1.hash)                             // seg1's o == its own hash
    #expect(a1.dataSize == UInt64(f.msTotalSize))                  // d = whole size in every segment
    #expect(a2.dataSize == UInt64(f.msTotalSize))
}

@Test func ourPackMatchesGenuineRnsSegmentAdvertisementBytes() throws {
    let f = try TransportVectorFixtures.load()
    let genuine = Data(hexString: f.msSeg1Adv)!
    let a = ResourceAdvertisement.unpack(genuine)!                  // take genuine field values
    #expect(a.pack() == genuine)                                   // our re-pack is byte-identical
}
```

(The first test proves the segment SEMANTICS against genuine RNS output; the second proves our msgpack encoding round-trips genuine RNS segment advertisements byte-for-byte.)

- [ ] **Step 4: Run** — `swift test --filter MultiSegmentCrossValidation` → PASS.

- [ ] **Step 5: Full gate** — `swift test` → PASS; report pass/skip counts.

- [ ] **Step 6: Mutation sweep (cross-cutting)**

Apply, run the named filter, confirm failure, revert; final full `swift test` green:
- In `ResourceAdvertisement.unpack` handling of `i`… no — instead: in Task 1's advertisement build, revert `segmentIndex: segmentIndex` to `segmentIndex: 0` → `genuineRnsSegmentAdvertisementsUnpackWithSegmentFields` still passes (it reads genuine bytes) but `ourPackMatchesGenuineRnsSegmentAdvertisementBytes` is unaffected; the meaningful cross-cutting mutation is: change `for i in 1...acc.total` reassembly (Task 3) to reversed → the E2E `resourceReceived == original` fails. Use that under `swift test --filter Endpoint`.

- [ ] **Step 7: Commit (verify fixture)**

```
git add Tests/ReTiCANodeTests/EndpointTests.swift Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py Tests/ReTiCATransportTests/Vectors/transport_fixtures.json Tests/ReTiCATransportTests/Vectors/TransportVectorFixtures.swift Tests/ReTiCATransportTests/Vectors/MultiSegmentCrossValidationTests.swift
git commit -F /tmp/ReTiCA/commit-m4a.txt
```
(First line: `test: end-to-end multi-segment round-trip + genuine-RNS segment cross-validation`, blank line, trailers.)

After committing: `git show HEAD:Tests/ReTiCATransportTests/Vectors/transport_fixtures.json | grep ms_seg1_adv` (its own command) — confirm the key is in the committed blob; if missing, re-stage + `git commit --amend --no-edit`, re-verify.

- [ ] **Step 8: README**

Extend the resources section: resources larger than 1,048,575 bytes are split into sequential segments (each an independent transfer sharing an `originalHash`; the advertisement carries a 1-based `segmentIndex`, `totalSegments`, and a split flag), reassembled by concatenation in index order and delivered as one `resourceReceived`. Note this completes >1 MB support and is wire-compatible with Python-RNS 1.3.8. Remove any remaining "multi-segment … future slice" wording.

- [ ] **Step 9: Commit** — `git add README.md`; `git commit -F /tmp/ReTiCA/commit-m4b.txt` (First line: `docs: multi-segment (>1MB) resources`, blank line, trailers.)

---

## Self-Review

**Spec coverage:**
- Single-segment `i=0 → 1` interop fix (+ fixture/test updates) → Task 1. ✓
- Sender segment params (`i`/`l`/`o`/`d` + isSplit) → Task 1. ✓
- Sender split coordinator (sequential, advance on `.concluded`, one `resourceConcluded`) → Task 2. ✓
- Receiver accumulator (group by `originalHash`, buffer by index, concatenate on last, one `resourceReceived`; fail-the-whole) → Task 3. ✓
- E2E >MAX round-trip + genuine-RNS segment cross-val + gate + README → Task 4. ✓
- `MAX_EFFICIENT_SIZE = 1_048_575`, 1-based, `o=h₁`, `d`=whole → Global Constraints (empirically RNS-verified). ✓
- No core / Endpoint / wire-model change → respected. ✓
- Deferred (parallel segments, metadata, file streaming) → untouched. ✓

**Placeholder scan:** No TBD/TODO in production steps. The test-helper notes (`activeResourceStore`, `resourceStoreHostingSplitReceivers`) and the E2E-pump note are explicit implementer guidance (reuse the file's existing injection/pump idioms) with assertions locked — not missing implementation.

**Type consistency:** `init(sending:…, segmentIndex: UInt64 = 1, totalSegments: UInt64 = 1, originalHash: Data? = nil, totalDataSize: UInt64? = nil, …)`, `maxEfficientSize = 1_048_575`, `SegmentedSend`/`SegmentAccumulator`, `advFlags … | (totalSegments > 1 ? 0x04 : 0)`, `originalHash ?? h`, `dataSize = totalDataSize ?? UInt64(data.count)`, and the unchanged `resourceReceived`/`resourceConcluded`/`resourceFailed` delegates are used identically across Tasks 1–4. The `ms_*` fixture keys and `ResourceAdvertisement.segmentIndex/totalSegments/originalHash/isSplit` accessors match the core (unchanged) advertisement.
