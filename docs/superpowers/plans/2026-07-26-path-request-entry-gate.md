# Transport #4c-3a: PATH_REQUEST Entry Gate — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the RNS `path_request_handler` entry gate in front of the existing owner (#4c-1) and relay-cache (#4c-2) PATH_REQUEST answers: parse the request tag, ignore tagless requests, and ignore duplicate `(destHash+tag)` requests.

**Architecture:** All changes in `Sources/ReTiCATransport/Transport.swift` (TCA state + reducer). Add a bounded `discoveryPrTags` ring (RNS `max_pr_tags=32000`) keyed on `unique_tag = destHash ‖ tag`. At the front of the `pathRequestDestinationHash` branch, parse the tag (RNS variable-length slicing), drop tagless requests (length exactly 16), and drop duplicate tags; a fresh tag records and falls through to the unchanged owner/relay answers.

**Tech Stack:** Swift, The Composable Architecture (TCA), Swift Testing, genuine RNS 1.3.8 (conda `rns` env) for cross-validation.

## Global Constraints

- Commit directly to `main`; no feature branch.
- No compound shell commands (no `&&`, `||`, `;`, `xargs`, inline interpreter scripts). One command per Bash call. A single `>` redirect is allowed. Never use echo/printf/heredoc to write files — use editor tools.
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test: (a) run pass; (b) batch-mutate production to force fail + confirm each fails; (c) revert + confirm pass.
- TCA tests are non-exhaustive (`store.exhaustivity = .off`), asserting outcomes.
- Data slicing is COUNT-based (`Data(payload.prefix(16))`, `Data(payload.dropFirst(16).prefix(16))`), never index-based.
- Pure core (`Sources/ReTiCA/*`) untouched; changes confined to `Transport.swift`, its tests, and the cross-val fixture generator/vectors.
- Cross-val fixtures MUST derive from genuine RNS (here: the genuine-RNS `pr_request_payload`/`pr_tag`), never hand-rolled.
- RNS pins: tagless request (length == 16) ignored (Transport.py:2935); tag parse — `count > 32` → transport_id in bytes 16..32, tag = bytes 32.. (truncate to 16); `count > 16` → tag = bytes 16.. (truncate to 16); `unique_tag = destHash + tag` (Transport.py:2905-2921); `max_pr_tags = 32000` (Transport.py:127); duplicate `unique_tag` ignored (Transport.py:2924-2934).
- Build gotcha: signal-11/SIGILL → `swift package clean` then retry.
- Commit trailers, exactly:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```

**Spec:** `docs/superpowers/specs/2026-07-26-path-request-entry-gate-design.md`
**Base:** this plan's own commit (verify with `git log --oneline <planCommit>..HEAD`, never `HEAD~1`).

---

## File Structure

- **Modify** `Sources/ReTiCATransport/Transport.swift`
  - `State`: add `discoveryPrTags` ring (after `announceCache`, ~line 42).
  - static constants (~line 462, near `announceBlobRingSize`): add `pathRequestTagRingSize = 32000`.
  - PATH_REQUEST responder (~line 275, after `let requested = ...`, before the owner branch): add the tag parse + tagless-ignore + dedup gate.
- **Modify** `Tests/ReTiCATransportTests/TransportTests.swift`: tagless-ignore + duplicate-tag tests + a tagless-request helper.
- **Modify** `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py`: emit `pr_tag`.
- **Regenerate** `Tests/ReTiCATransportTests/Vectors/transport_fixtures.json`.
- **Modify** `Tests/ReTiCATransportTests/Vectors/TransportVectorFixtures.swift`: add `prTag`.
- **Modify** `Tests/ReTiCATransportTests/Vectors/TransportCrossValidationTests.swift`: tag-slicing parity test.

---

## Task 1: Entry gate — tag ring, tag parse, tagless-ignore, dedup

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (State field; static constant; responder gate)
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`

**Interfaces:**
- Produces: `Transport.State.discoveryPrTags: RingSet` and `Transport.pathRequestTagRingSize: Int`. Task 2 does not consume these directly (it tests slicing parity).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ReTiCATransportTests/TransportTests.swift`, in the `#4c-1 path requests` section (the `makePathRequest(for:tag:)` helper at line ~1742 already exists and appends a 16-byte tag). First a tagless-request helper:

```swift
/// A tagless PATH_REQUEST: just the 16-byte destination hash, no tag (RNS ignores these).
private func makeTaglessPathRequest(for destHash: Data) -> Data {
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                        destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                        payload: destHash)
    return try! packet.packed()
}
```

Tests:

```swift
/// A tagless (16-byte, no tag) request to an OWNED destination is ignored (RNS Transport.py:2935).
@Test @MainActor func taglessPathRequestToOwnedDestinationIsIgnored() async {
    let identity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: identity)!
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1000))
    }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations[dest.hash] = dest }
    await store.send(.received(InterfaceID("in"), makeTaglessPathRequest(for: dest.hash)))
    store.exhaustivity = .on          // no transmit — the tagless request produced no answer
}

/// A duplicate tagged request is ignored; a fresh tag is answered again (RNS discovery_pr_tags,
/// Transport.py:2924-2934). Exercised on the owner-answer path.
@Test @MainActor func duplicateTaggedPathRequestIsIgnored() async {
    let identity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: identity)!
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1000))
    }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations[dest.hash] = dest }
    let tagA = Data(repeating: 0xA1, count: 16)
    let tagB = Data(repeating: 0xB2, count: 16)

    // Fresh tag A → answered.
    let first = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("in"), makePathRequest(for: dest.hash, tag: tagA)))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { first.setValue(raw); return true }
        return false
    }
    #expect(Packet(raw: first.value!)?.context == .pathResponse)

    // Same tag A again → ignored (no transmit).
    await store.send(.received(InterfaceID("in"), makePathRequest(for: dest.hash, tag: tagA)))

    // Different tag B → answered again.
    let third = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("in"), makePathRequest(for: dest.hash, tag: tagB)))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { third.setValue(raw); return true }
        return false
    }
    #expect(Packet(raw: third.value!)?.context == .pathResponse)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "PathRequest" 2>&1 | tail -40`
Expected: `taglessPathRequestToOwnedDestinationIsIgnored` fails (currently the owner answers a 16-byte request); `duplicateTaggedPathRequestIsIgnored` fails on the second-send assertion (currently the duplicate is answered, so the different-tag `receive` consumes the duplicate's transmit and the exhaustive teardown or the ordering trips). (If `discoveryPrTags`/`pathRequestTagRingSize` do not yet exist there is no compile dependency in the tests — they only exercise behavior.)

- [ ] **Step 3: Add the static constant**

In `Sources/ReTiCATransport/Transport.swift`, near `announceBlobRingSize` (~line 462):

```swift
    static let pathRequestTagRingSize = 32000      // RNS max_pr_tags (Transport.py:127)
```

- [ ] **Step 4: Add the state field**

In `State`, after `announceCache` (~line 42):

```swift
        /// unique_tag (destHash ‖ tag) ring for PATH_REQUEST dedup — a duplicate tagged request is
        /// ignored rather than re-answered (RNS discovery_pr_tags, Transport.py:2924-2934). Bounded
        /// (auto-evicts oldest at capacity), so no separate GC pass.
        public var discoveryPrTags = RingSet(capacity: Transport.pathRequestTagRingSize)
```

- [ ] **Step 5: Add the entry gate**

In the responder, immediately after `let requested = Data(packet.payload.prefix(16))` (~line 275) and before the owner branch (`// (1) We OWN ...`):

```swift
                        // Entry gate (RNS path_request_handler:2905-2934). Parse the request tag;
                        // ignore tagless requests and duplicate (destHash ‖ tag) requests.
                        let tag: Data
                        if packet.payload.count > 32 {
                            tag = Data(packet.payload.dropFirst(32).prefix(16))   // after destHash + transport_id
                        } else if packet.payload.count > 16 {
                            tag = Data(packet.payload.dropFirst(16).prefix(16))   // after destHash
                        } else {
                            return .none                                          // tagless (== 16) → ignore
                        }
                        guard state.discoveryPrTags.insert(requested + tag) else { return .none }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter "PathRequest" 2>&1 | tail -40`
Expected: both new tests PASS; the existing #4c-1/#4c-2 responder tests (`localDestinationAnswersPathRequestWithPathResponse`, `relayAnswersPathRequestFromCache`, `relayLoopGuard*`, `pathResponseAnnounceIsLearnedByRequester`, `relayCachePathResponseIsLearnedByRequester`) still PASS — they all use tagged requests with distinct tags, so the gate passes them.

- [ ] **Step 7: Mutation-verify (three-step)**

Batch-mutate: (1) change the tagless `else { return .none }` to `else { tag = Data() }` (fall through instead of ignoring); (2) change `guard state.discoveryPrTags.insert(requested + tag) else { return .none }` to `state.discoveryPrTags.insert(requested + tag)` (record but never dedup). Run `swift test --filter "PathRequest"`. Expected: mutation (1) fails `taglessPathRequestToOwnedDestinationIsIgnored` (owner now answers the tagless request); mutation (2) fails `duplicateTaggedPathRequestIsIgnored` (the duplicate is answered). Revert both; run again; expected all PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -F /tmp/ReTiCA/commit-4c3a-t1.txt
```

(Write the message to `/tmp/ReTiCA/commit-4c3a-t1.txt` first, e.g. `feat: transport #4c-3a task 1 — PATH_REQUEST entry gate (tag dedup + tagless-ignore)` plus the two required trailers.)

---

## Task 2: Cross-validate tag slicing against genuine RNS request bytes

**Files:**
- Modify: `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py`
- Regenerate: `Tests/ReTiCATransportTests/Vectors/transport_fixtures.json`
- Modify: `Tests/ReTiCATransportTests/Vectors/TransportVectorFixtures.swift`
- Modify: `Tests/ReTiCATransportTests/Vectors/TransportCrossValidationTests.swift`

**Interfaces:**
- Consumes: the tag-slicing formula from Task 1 (`payload[16:32]` for the 32-byte leaf request).

**Context:** The generator already builds `_pr_tag = RNS.Identity.get_random_hash()` (a genuine RNS 16-byte tag) and `_pr_request_payload = dest_hash + _pr_tag` (a genuine RNS-shaped leaf request). This task exposes `pr_tag` and asserts our tag slicing extracts it — validating our formula against genuine-RNS-produced request bytes, extending #4c-1's `Data(payload.prefix(16)) == pr_requested_dest` slicing check.

- [ ] **Step 1: Emit `pr_tag` from the generator**

In `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py`, add to the `json.dumps({...})` dict (near `pr_request_payload`):

```python
    "pr_tag": _pr_tag.hex(),
```

- [ ] **Step 2: Regenerate the fixture JSON**

Run: `/Users/ell/opt/anaconda3/envs/rns/bin/python Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py > Tests/ReTiCATransportTests/Vectors/transport_fixtures.json`
Expected: exit 0; the JSON now contains `pr_tag` (a 16-byte hex string), and `pr_request_payload == pr_requested_dest ‖ pr_tag`.

- [ ] **Step 3: Add the fixture field to the Swift struct**

In `Tests/ReTiCATransportTests/Vectors/TransportVectorFixtures.swift`, add a property near `prRequestPayload`:

```swift
    let prTag: String
```

and a `CodingKeys` case near `prRequestPayload`:

```swift
        case prTag = "pr_tag"
```

- [ ] **Step 4: Write the cross-val test**

In `Tests/ReTiCATransportTests/Vectors/TransportCrossValidationTests.swift`, add:

```swift
/// Our PATH_REQUEST tag slicing extracts the same tag genuine RNS placed in the request, and our
/// unique_tag matches RNS's destHash ‖ tag (RNS path_request_handler:2905-2921).
@Test func pathRequestTagSlicingMatchesRns() throws {
    let f = try TransportVectorFixtures.load()
    let payload = Data(hexString: f.prRequestPayload)!    // genuine RNS leaf request: destHash ‖ tag (32 bytes)
    let requested = Data(payload.prefix(16))
    let tag = Data(payload.dropFirst(16).prefix(16))      // our > 16 branch (count == 32)
    #expect(tag == Data(hexString: f.prTag)!)
    #expect(requested + tag == Data(hexString: f.prRequestedDest)! + Data(hexString: f.prTag)!)
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter "TransportCrossValidation" 2>&1 | tail -20`
Expected: `pathRequestTagSlicingMatchesRns` PASSES and all sibling cross-val tests still pass (the struct/JSON change is additive).

- [ ] **Step 6: Mutation-verify**

Mutate the test's slicing (e.g. `dropFirst(16)` → `dropFirst(15)`) and confirm the `tag == pr_tag` assertion fails; revert and confirm it passes. (Confirms the assertion is load-bearing on the exact slice offsets.)

- [ ] **Step 7: Commit**

```bash
git add Tests/ReTiCATransportTests/Vectors/
git commit -F /tmp/ReTiCA/commit-4c3a-t2.txt
```

(Message e.g. `test: transport #4c-3a task 2 — cross-validate PATH_REQUEST tag slicing vs RNS` plus trailers.)

---

## Self-Review

- **Spec coverage:** tag ring (Task 1 state + constant); tag parse + tagless-ignore + dedup (Task 1 gate); cross-val (Task 2). Grace timing, requester throttle, recursive re-broadcast deferred (spec §Scope) — no task, by design.
- **Placeholder scan:** none — every step has concrete code/commands.
- **Type consistency:** `discoveryPrTags: RingSet` with `RingSet(capacity:)`/`insert -> Bool` (confirmed against `RingSet.swift`); `pathRequestTagRingSize: Int`; fixture field `prTag` consistent across generator key (`pr_tag`), struct property, CodingKeys, and test.
- **Wire correctness:** tag slicing (`> 32` → bytes 32.., `> 16` → bytes 16.., `== 16` → ignore) and `unique_tag = destHash+tag` mirror RNS Transport.py:2905-2921; ring capacity 32000 = RNS `max_pr_tags`.
- **Integration:** the gate sits after the `payload.count >= 16` guard and `requested` binding, before the owner branch — existing owner/relay answers and their tests (tagged requests) are unaffected.
