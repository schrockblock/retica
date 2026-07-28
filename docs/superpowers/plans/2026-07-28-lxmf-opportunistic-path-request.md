# LXMF-4c-2 remainder: Opportunistic Pathless-Retry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An opportunistic outbound retry with no known path requests a path (instead of resending) and waits the longer `PATH_REQUEST_WAIT` before the next attempt; normal resends resume once a path is learned.

**Architecture:** Add one cross-validated core constant (`LXMFDelivery.pathRequestWaitSeconds`), parameterize the `LXMFRouter` reducer's `retryTimer` helper to take a wait duration, and branch `.retryDue`: an opportunistic pending delivery with no `knownPaths` entry emits `.requestPath` on the (already-present) delegate and restarts the timer at the path-request wait. Direct pending deliveries are unchanged. `MAX_PATHLESS_TRIES=1` is honored structurally (the first send at `.send` is the one unconditional best-effort try).

**Tech Stack:** Swift, The Composable Architecture (TCA), swift-testing (`@Test`), SwiftPM. Cross-validation fixtures generated from genuine `lxmf 1.1.0` in the conda `rns` env.

## Global Constraints

- Commit directly to `main`; no feature branch, no finishing-a-development-branch merge dance.
- No compound shell commands: no `|` chains, `&&`, `||`, `;`, `$(...)`-feeding, `xargs`, or inlining scripts into interpreters. One command per Bash call. A single `>` redirect is allowed (used to write the regenerated fixture from the generator's stdout). Never use echo/printf/heredoc to WRITE source files (use Write/Edit).
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test: (a) run pass, (b) mutate production to force fail + confirm fail, (c) revert + confirm pass. Several Task 2 mutations touch the same condition — apply mutations ONE AT A TIME, each mapped to the test(s) it should break.
- Cross-val fixtures must drive genuine LXMF; regenerate `lxmf_fixtures.json` only via the generator run in the conda `rns` env (absolute python path). Regeneration churns the whole fixture (new identities/signature/packed) — all existing LXMF cross-val tests re-derive from it and pass.
- Reference env: `/Users/ell/opt/anaconda3/envs/rns/bin/python` (baseline rns 1.4.2 / lxmf 1.1.0). `PATH_REQUEST_WAIT = 7` in `LXMF.LXMRouter`.
- Signatures validated, never byte-compared (Ed25519 hedged/randomized). Constants/hashes stay deterministic.
- Commit trailers (exact); the `;` in the second line means author the message with the Write tool to `/tmp/ReTiCA/` and `git commit -F`, never `-m`:
  - `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`

---

### Task 1: `pathRequestWaitSeconds` core constant + cross-validation

**Files:**
- Modify: `Sources/ReTiCA/LXMF/LXMFDelivery.swift:6-11`
- Modify: `Tests/ReTiCATests/Vectors/generate_lxmf_fixtures.py:42` (add one emitted field)
- Modify (regenerate): `Tests/ReTiCATests/Vectors/lxmf_fixtures.json`
- Modify: `Tests/ReTiCATests/Vectors/LXMFVectorFixtures.swift` (add field + coding key)
- Modify (add test): `Tests/ReTiCATests/Vectors/LXMessageCrossValidationTests.swift`

**Interfaces:**
- Produces: `LXMFDelivery.pathRequestWaitSeconds: Int` (== 7) — consumed by Task 2's reducer. Fixture gains `path_request_wait`; `LXMFVectorFixtures` gains `pathRequestWait: Int`.

- [ ] **Step 1: Add the constant**

In `Sources/ReTiCA/LXMF/LXMFDelivery.swift`, after the `maxAttempts` declaration (line 10), add:

```swift
    /// Seconds to wait after requesting a path before the next opportunistic delivery attempt — longer
    /// than `retryWaitSeconds` (RNS `LXMRouter.PATH_REQUEST_WAIT`).
    public static let pathRequestWaitSeconds = 7
```

- [ ] **Step 2: Emit the reference value from the generator**

In `Tests/ReTiCATests/Vectors/generate_lxmf_fixtures.py`, add a line after `"max_delivery_attempts": ...,` (line 42), inside the `json.dumps({...})` dict:

```python
    "path_request_wait": LXMF.LXMRouter.PATH_REQUEST_WAIT,
```

- [ ] **Step 3: Regenerate the fixture**

Run (single command, one redirect):

```bash
/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/generate_lxmf_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/lxmf_fixtures.json
```

Expected: the file now contains a `"path_request_wait": 7` entry (plus regenerated identity/signature/packed values — that churn is expected and harmless).

- [ ] **Step 4: Add the decoded field**

In `Tests/ReTiCATests/Vectors/LXMFVectorFixtures.swift`, add the stored property after `maxDeliveryAttempts` (line 16):

```swift
    let pathRequestWait: Int
```

and the coding key after `case maxDeliveryAttempts = "max_delivery_attempts"` (line 27):

```swift
        case pathRequestWait = "path_request_wait"
```

- [ ] **Step 5: Add the cross-val test**

In `Tests/ReTiCATests/Vectors/LXMessageCrossValidationTests.swift`, after `lxmfDeliveryConstantsMatchRns` (ends line 57), add:

```swift
/// Our LXMF path-request wait matches genuine RNS LXMRouter.PATH_REQUEST_WAIT.
@Test func pathRequestWaitMatchesRns() throws {
    let f = try LXMFVectorFixtures.load()
    #expect(LXMFDelivery.pathRequestWaitSeconds == f.pathRequestWait)
}
```

- [ ] **Step 6: Run the cross-val test — verify it passes**

Run: `swift test --filter LXMessageCrossValidationTests`
Expected: PASS (including `pathRequestWaitMatchesRns`, and all sibling LXMF cross-val tests re-deriving from the regenerated fixture).

- [ ] **Step 7: Mutation verification**

Mutate `Sources/ReTiCA/LXMF/LXMFDelivery.swift`: change `pathRequestWaitSeconds = 7` to `= 8`.
Run: `swift test --filter LXMessageCrossValidationTests`
Expected: `pathRequestWaitMatchesRns` FAILS (7 != 8).
Revert to `= 7`. Run again. Expected: PASS.

- [ ] **Step 8: Commit**

Write the message to `/tmp/ReTiCA/commit-msg-4c2opp-t1.txt` with the Write tool (body below), then:

```bash
git add Sources/ReTiCA/LXMF/LXMFDelivery.swift Tests/ReTiCATests/Vectors/generate_lxmf_fixtures.py Tests/ReTiCATests/Vectors/lxmf_fixtures.json Tests/ReTiCATests/Vectors/LXMFVectorFixtures.swift Tests/ReTiCATests/Vectors/LXMessageCrossValidationTests.swift
```

```bash
git commit -F /tmp/ReTiCA/commit-msg-4c2opp-t1.txt
```

Commit message body:

```
feat: LXMF-4c-2 remainder task 1 — pathRequestWaitSeconds + cross-val

Adds core LXMFDelivery.pathRequestWaitSeconds (=7), emitted from the
generator as path_request_wait (LXMF.LXMRouter.PATH_REQUEST_WAIT) and
pinned by a cross-val test. Fixture regenerated (whole-file churn;
siblings re-derive + pass).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

### Task 2: Opportunistic pathless-retry in `LXMFRouter.retryDue`

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` (`retryTimer` helper lines 71-76; call sites lines 111, 119, 142; `.retryDue` case lines 164-179)
- Modify (add tests): `Tests/ReTiCANodeTests/LXMFRouterTests.swift` (append a new MARK section)

**Interfaces:**
- Consumes: `LXMFDelivery.pathRequestWaitSeconds` and `.retryWaitSeconds` (Task 1 + existing); existing `LXMFRouter` state (`knownPaths: Set<Data>`, `pendingDeliveries`, `ResendInfo`), the `.requestPath(destinationHash:)` delegate, `.sendOpportunistic`, `.sendDirect`, `.delivered`, `.retryDue` actions; the `makeMessage(source:recipientIdentityHash:content:)` test helper.
- Produces: no new public API — behavior change only.

- [ ] **Step 1: Write the headline failing test (pathless retry requests a path)**

Append to `Tests/ReTiCANodeTests/LXMFRouterTests.swift` a new section (after the existing LXMF-4c-1 tests):

```swift
// MARK: - LXMF-4c-2 opportunistic pathless-retry

@Test @MainActor func routerOpportunisticPathlessRetryRequestsPath() async {
    let msg = makeMessage(source: Identity(), content: "small")
    let clock = TestClock()
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.receive { if case .delegate(.sendOpportunistic) = $0 { return true }; return false }   // best-effort try #1
    #expect(store.state.pendingDeliveries[msg.hash]?.attempts == 1)
    // No known path → the first retry requests a path instead of resending.
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { action in
        if case let .delegate(.requestPath(dest)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    #expect(store.state.pendingDeliveries[msg.hash]?.attempts == 2)
    // The post-request wait is pathRequestWaitSeconds (7): advancing it fires the next retry (another requestPath).
    await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
    await store.receive { if case .delegate(.requestPath) = $0 { return true }; return false }
    #expect(store.state.pendingDeliveries[msg.hash]?.attempts == 3)
    await store.send(.delivered(messageHash: msg.hash))   // cancel the pending timer before teardown
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    store.exhaustivity = .on
}
```

- [ ] **Step 2: Run it — verify it fails**

Run: `swift test --filter LXMFRouterTests.routerOpportunisticPathlessRetryRequestsPath`
Expected: FAIL — the current `.retryDue` re-emits `sendOpportunistic`, so the `receive { requestPath }` never matches and times out.

- [ ] **Step 3: Parameterize `retryTimer` and update its call sites**

In `Sources/ReTiCANode/LXMFRouter.swift`, replace the `retryTimer` helper (lines 71-76):

```swift
            func retryTimer(_ hash: Data) -> Effect<Action> {
                .run { send in
                    try await clock.sleep(for: .seconds(LXMFDelivery.retryWaitSeconds))
                    await send(.retryDue(messageHash: hash))
                }.cancellable(id: CancelID.retry(hash), cancelInFlight: true)
            }
```

with:

```swift
            func retryTimer(_ hash: Data, _ seconds: Int) -> Effect<Action> {
                .run { send in
                    try await clock.sleep(for: .seconds(seconds))
                    await send(.retryDue(messageHash: hash))
                }.cancellable(id: CancelID.retry(hash), cancelInFlight: true)
            }
```

Update the three surviving call sites to pass the normal wait:
- Line 111 (`.send` opportunistic): `retryTimer(message.hash)` → `retryTimer(message.hash, LXMFDelivery.retryWaitSeconds)`
- Line 119 (`.send` direct-active): `retryTimer(message.hash)` → `retryTimer(message.hash, LXMFDelivery.retryWaitSeconds)`
- Line 142 (`.linkEstablished` drain): `retryTimer(m.hash)` → `retryTimer(m.hash, LXMFDelivery.retryWaitSeconds)`

(The fourth call site in `.retryDue` is replaced in the next step.)

- [ ] **Step 4: Branch `.retryDue` for the opportunistic pathless case**

Replace the `.retryDue` case (lines 164-179) — from `case let .retryDue(hash):` through the final `return .merge(resendDelegate, retryTimer(hash))` — with:

```swift
            case let .retryDue(hash):
                guard var pending = state.pendingDeliveries[hash] else { return .none }
                pending.attempts += 1
                if pending.attempts > LXMFDelivery.maxAttempts {
                    state.pendingDeliveries[hash] = nil
                    return .send(.delegate(.deliveryFailed(messageHash: hash)))
                }
                state.pendingDeliveries[hash] = pending
                switch pending.resend {
                case let .opportunistic(destinationHash, payload):
                    if !state.knownPaths.contains(destinationHash) {
                        // Pathless opportunistic retry: request a path instead of resending, and wait longer.
                        return .merge(.send(.delegate(.requestPath(destinationHash: destinationHash))),
                                      retryTimer(hash, LXMFDelivery.pathRequestWaitSeconds))
                    }
                    return .merge(.send(.delegate(.sendOpportunistic(destinationHash: destinationHash, payload: payload))),
                                  retryTimer(hash, LXMFDelivery.retryWaitSeconds))
                case let .direct(linkID, data, asResource):
                    return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: asResource))),
                                  retryTimer(hash, LXMFDelivery.retryWaitSeconds))
                }
```

- [ ] **Step 5: Run the headline test — verify it passes**

Run: `swift test --filter LXMFRouterTests.routerOpportunisticPathlessRetryRequestsPath`
Expected: PASS.

- [ ] **Step 6: Add the 3 remaining tests**

Append to the same `// MARK: - LXMF-4c-2 opportunistic pathless-retry` section:

```swift
/// Learning a path mid-flight lets the next opportunistic retry resume sending (not another requestPath).
@Test @MainActor func routerOpportunisticResumesSendingAfterLearnedPath() async {
    let msg = makeMessage(source: Identity(), content: "small")
    let clock = TestClock()
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.receive { if case .delegate(.sendOpportunistic) = $0 { return true }; return false }
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { if case .delegate(.requestPath) = $0 { return true }; return false }   // pathless retry
    await store.send(.learnedPath(destinationHash: msg.destinationHash))
    // Path now known → next retry resends opportunistically instead of requesting a path again.
    await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
    await store.receive { action in
        if case let .delegate(.sendOpportunistic(dest, _)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    await store.send(.delivered(messageHash: msg.hash))
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    store.exhaustivity = .on
}

/// Known path from the start → opportunistic retries resend at retryWaitSeconds, never requestPath.
@Test @MainActor func routerOpportunisticWithKnownPathResendsNotRequestsPath() async {
    let msg = makeMessage(source: Identity(), content: "small")
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(msg.destinationHash)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.receive { if case .delegate(.sendOpportunistic) = $0 { return true }; return false }
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { if case .delegate(.sendOpportunistic) = $0 { return true }; return false }   // resend, not requestPath
    #expect(store.state.pendingDeliveries[msg.hash]?.attempts == 2)
    await store.send(.delivered(messageHash: msg.hash))
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    store.exhaustivity = .on
}

/// A DIRECT pending delivery retries over its link even with no known path — pathless-retry is
/// opportunistic-only.
@Test @MainActor func routerDirectRetryUnaffectedByMissingPath() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let linkID = Data(repeating: 0x9A, count: 16)
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.directLinks[msg.destinationHash] = .active(linkID: linkID)   // active link, but no knownPaths entry
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.sendDirect) = $0 { return true }; return false }
    #expect(store.state.pendingDeliveries[msg.hash]?.attempts == 1)
    // Direct retry resends over the link despite no known path (would be requestPath if pathless-retry leaked in).
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { action in
        if case let .delegate(.sendDirect(lid, _, _)) = action { #expect(lid == linkID); return true }
        return false
    }
    await store.send(.delivered(messageHash: msg.hash))
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    store.exhaustivity = .on
}
```

- [ ] **Step 7: Run the full router test file — verify all pass**

Run: `swift test --filter LXMFRouterTests`
Expected: PASS — all existing router tests plus the 4 new ones.

- [ ] **Step 8: Mutation verification (one mutation at a time)**

Several mutations touch the same condition, so apply each individually, run `swift test --filter LXMFRouterTests`, confirm the named test(s) fail, then revert before the next.

1. **Force resend on pathless retry** — in `.retryDue` opportunistic branch, change `if !state.knownPaths.contains(destinationHash) {` to `if false {`.
   → `routerOpportunisticPathlessRetryRequestsPath` FAILS (retry emits `sendOpportunistic`, `receive { requestPath }` times out); `routerOpportunisticResumesSendingAfterLearnedPath` FAILS (no `requestPath` before `learnedPath`).
2. **Force requestPath even with a known path** — change the same condition to `if true {`.
   → `routerOpportunisticWithKnownPathResendsNotRequestsPath` FAILS (retry emits `requestPath`, `receive { sendOpportunistic }` times out).
3. **Wrong wait after a path request** — change `retryTimer(hash, LXMFDelivery.pathRequestWaitSeconds)` (pathless branch) to `retryTimer(hash, LXMFDelivery.retryWaitSeconds)`.
   → `routerOpportunisticPathlessRetryRequestsPath` FAILS (advancing 7s no longer fires the second `requestPath`; it would need 10).
4. **Leak pathless-retry into direct** — in the `.direct` branch of `.retryDue`, replace the body with the pathless logic: `if !state.knownPaths.contains(linkID) { return .merge(.send(.delegate(.requestPath(destinationHash: linkID))), retryTimer(hash, LXMFDelivery.pathRequestWaitSeconds)) }` before the existing `sendDirect` return. (Uses `linkID` only to force the mutated path; it is a deliberate wrong mutation.)
   → `routerDirectRetryUnaffectedByMissingPath` FAILS (direct retry emits `requestPath`, `receive { sendDirect }` times out).

After each: revert the mutation, run `swift test --filter LXMFRouterTests`, expect PASS before applying the next.

- [ ] **Step 9: Full test gate**

Run: `swift test`
Expected: PASS. The 4c-2 baseline was 417 passed / 1 pre-existing live-node skip / 0 fail; this slice adds 1 cross-val test (Task 1) + 4 router tests (Task 2) → 422 passed. If a signal-11/signal-10 build flake appears, run `swift package clean` (single command) and re-run.

- [ ] **Step 10: Commit**

Write the message to `/tmp/ReTiCA/commit-msg-4c2opp-t2.txt` with the Write tool (body below), then:

```bash
git add Sources/ReTiCANode/LXMFRouter.swift Tests/ReTiCANodeTests/LXMFRouterTests.swift
```

```bash
git commit -F /tmp/ReTiCA/commit-msg-4c2opp-t2.txt
```

Commit message body:

```
feat: LXMF-4c-2 remainder task 2 — opportunistic pathless-retry

.retryDue now branches: an opportunistic pending delivery with no known
path requests a path (instead of resending) and restarts the timer at
pathRequestWaitSeconds; path known → resend at retryWaitSeconds. Direct
pending unchanged. Parameterized retryTimer(hash, seconds). The first
send stays the one best-effort try (MAX_PATHLESS_TRIES=1, structural).
4 new tests.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Self-Review

**Spec coverage:**
- Spec "Core constant" (`pathRequestWaitSeconds = 7`) → Task 1 Steps 1-2. ✓
- Spec cross-val constant test → Task 1 Steps 3-5. ✓
- Spec "Reducer change" (parameterized `retryTimer`) → Task 2 Step 3. ✓
- Spec "Reducer change" (`.retryDue` opportunistic pathless branch; direct unchanged) → Task 2 Step 4. ✓
- Spec test 1 (pathless retry requests path, 7s wait) → `routerOpportunisticPathlessRetryRequestsPath`, Task 2 Step 1. ✓
- Spec test 2 (learnedPath resumes sending) → `routerOpportunisticResumesSendingAfterLearnedPath`, Step 6. ✓
- Spec test 3 (known path resends, regression guard) → `routerOpportunisticWithKnownPathResendsNotRequestsPath`, Step 6. ✓
- Spec test 4 (direct unaffected) → `routerDirectRetryUnaffectedByMissingPath`, Step 6. ✓
- Spec "Deferred" (path rediscovery) → no task, correctly absent. ✓

**Placeholder scan:** none — every code step shows exact code.

**Type consistency:** `LXMFDelivery.pathRequestWaitSeconds` (Task 1) is referenced verbatim in Task 2's reducer and tests. `retryTimer(_ hash: Data, _ seconds: Int)` signature is used consistently at all four call sites (three updated in Step 3, one in the replaced `.retryDue`). `LXMFVectorFixtures.pathRequestWait` matches the generator's `path_request_wait` key and the cross-val test's `f.pathRequestWait`.
