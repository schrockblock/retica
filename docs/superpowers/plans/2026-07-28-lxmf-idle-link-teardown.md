# LXMF-4c-3b: Idle-Link Teardown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The router tears down a direct link that has carried no new LXMF traffic for `LINK_MAX_INACTIVITY` (600s), so idle direct links are not hoarded.

**Architecture:** Add one cross-validated core constant (`LXMFDelivery.linkMaxInactivitySeconds`), a per-destination cancellable `idleTimer` in the `LXMFRouter` reducer that is (re)armed on each new `sendDirect` (`.send` direct-active + `.linkEstablished` drain), and an `.idleDeadline` action that drops an idle active link and emits a `.closeLink` delegate. Mirrors `LinkSession`'s `staleTime` pattern; no polling sweep, no wall-clock.

**Tech Stack:** Swift, The Composable Architecture (TCA), swift-testing (`@Test`), SwiftPM. Cross-validation from genuine `lxmf 1.1.0` in the conda `rns` env.

## Global Constraints

- Commit directly to `main`; no feature branch, no finishing-a-development-branch merge dance.
- No compound shell commands: no `|` chains, `&&`, `||`, `;`, `$(...)`-feeding, `xargs`, or inlining scripts into interpreters. One command per Bash call. A single `>` redirect is allowed (fixture regeneration). Never use echo/printf/heredoc to WRITE source files (use Write/Edit).
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test. Apply the Task 2 mutations ONE AT A TIME (each maps to a distinct test).
- Cross-val fixtures must drive genuine LXMF; regenerate `lxmf_fixtures.json` only via the generator run in the conda `rns` env (absolute python path). Regeneration churns the whole fixture (new identities/signature/packed) — all existing LXMF cross-val tests re-derive from it and pass.
- Reference env: `/Users/ell/opt/anaconda3/envs/rns/bin/python` (rns 1.4.2 / lxmf 1.1.0). `LINK_MAX_INACTIVITY = 10*60 = 600` in `LXMF.LXMRouter`.
- Signatures validated, never byte-compared. Constants/hashes deterministic.
- Commit trailers (exact); the `;` means author the message with the Write tool to `/tmp/ReTiCA/` and `git commit -F`, never `-m`:
  - `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`

---

### Task 1: `linkMaxInactivitySeconds` core constant + cross-validation

**Files:**
- Modify: `Sources/ReTiCA/LXMF/LXMFDelivery.swift` (after the `pathRequestWaitSeconds` declaration)
- Modify: `Tests/ReTiCATests/Vectors/generate_lxmf_fixtures.py:43` (add one emitted field)
- Modify (regenerate): `Tests/ReTiCATests/Vectors/lxmf_fixtures.json`
- Modify: `Tests/ReTiCATests/Vectors/LXMFVectorFixtures.swift:17,29` (add field + coding key)
- Modify (add test): `Tests/ReTiCATests/Vectors/LXMessageCrossValidationTests.swift` (after `pathRequestWaitMatchesRns`)

**Interfaces:**
- Produces: `LXMFDelivery.linkMaxInactivitySeconds: Int` (== 600) — consumed by Task 2. Fixture gains `link_max_inactivity`; `LXMFVectorFixtures` gains `linkMaxInactivity: Int`.

- [ ] **Step 1: Add the constant**

In `Sources/ReTiCA/LXMF/LXMFDelivery.swift`, after the `pathRequestWaitSeconds` declaration, add:

```swift
    /// Seconds a direct link may carry no LXMF traffic before the router tears it down — a higher GC
    /// than the Link-level keepalive watchdog (RNS `LXMRouter.LINK_MAX_INACTIVITY`).
    public static let linkMaxInactivitySeconds = 600
```

- [ ] **Step 2: Emit the reference value from the generator**

In `Tests/ReTiCATests/Vectors/generate_lxmf_fixtures.py`, add a line after `"path_request_wait": LXMF.LXMRouter.PATH_REQUEST_WAIT,` (line 43):

```python
    "link_max_inactivity": LXMF.LXMRouter.LINK_MAX_INACTIVITY,
```

- [ ] **Step 3: Regenerate the fixture**

Run (single command, one redirect):

```bash
/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/generate_lxmf_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/lxmf_fixtures.json
```

Expected: the file now contains `"link_max_inactivity": 600` (plus regenerated identity/signature/packed values — expected churn).

- [ ] **Step 4: Add the decoded field**

In `Tests/ReTiCATests/Vectors/LXMFVectorFixtures.swift`, add the stored property after `let pathRequestWait: Int` (line 17):

```swift
    let linkMaxInactivity: Int
```

and the coding key after `case pathRequestWait = "path_request_wait"` (line 29):

```swift
        case linkMaxInactivity = "link_max_inactivity"
```

- [ ] **Step 5: Add the cross-val test**

In `Tests/ReTiCATests/Vectors/LXMessageCrossValidationTests.swift`, after the `pathRequestWaitMatchesRns` test, add:

```swift
/// Our LXMF idle-link teardown threshold matches genuine RNS LXMRouter.LINK_MAX_INACTIVITY.
@Test func linkMaxInactivityMatchesRns() throws {
    let f = try LXMFVectorFixtures.load()
    #expect(LXMFDelivery.linkMaxInactivitySeconds == f.linkMaxInactivity)
}
```

- [ ] **Step 6: Run the cross-val tests — verify they pass**

Run: `swift test --filter LXMessageCrossValidationTests`
Expected: PASS (including `linkMaxInactivityMatchesRns`, and all siblings re-deriving from the regenerated fixture).

- [ ] **Step 7: Mutation verification**

Mutate `Sources/ReTiCA/LXMF/LXMFDelivery.swift`: change `linkMaxInactivitySeconds = 600` to `= 601`.
Run: `swift test --filter LXMessageCrossValidationTests`
Expected: `linkMaxInactivityMatchesRns` FAILS (600 != 601).
Revert to `= 600`. Run again. Expected: PASS.

- [ ] **Step 8: Commit**

Write the message to `/tmp/ReTiCA/commit-msg-4c3b-t1.txt` with the Write tool (body below), then:

```bash
git add Sources/ReTiCA/LXMF/LXMFDelivery.swift Tests/ReTiCATests/Vectors/generate_lxmf_fixtures.py Tests/ReTiCATests/Vectors/lxmf_fixtures.json Tests/ReTiCATests/Vectors/LXMFVectorFixtures.swift Tests/ReTiCATests/Vectors/LXMessageCrossValidationTests.swift
```

```bash
git commit -F /tmp/ReTiCA/commit-msg-4c3b-t1.txt
```

Commit message body:

```
feat: LXMF-4c-3b task 1 — linkMaxInactivitySeconds + cross-val

Adds core LXMFDelivery.linkMaxInactivitySeconds (=600), emitted from the
generator as link_max_inactivity (LXMF.LXMRouter.LINK_MAX_INACTIVITY) and
pinned by a cross-val test. Fixture regenerated (whole-file churn;
siblings re-derive + pass).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

### Task 2: Idle timer + teardown in `LXMFRouter`

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` (`CancelID` line 14; `Action` after line 52; `Action.Delegate` after line 61; add `idleTimer` helper after `retryTimer` lines 71-76; `.send` direct-active merge lines 125-127; `.linkEstablished` drain lines 140-147; add `.idleDeadline` case after `.retryDue` ends at line 200)
- Modify (adjust 3 tests + add 2): `Tests/ReTiCANodeTests/LXMFRouterTests.swift`

**Interfaces:**
- Consumes: `LXMFDelivery.linkMaxInactivitySeconds` (Task 1) + existing router state/actions; `makeMessage(source:recipientIdentityHash:content:)`.
- Produces: `LXMFRouter.Action.idleDeadline(destinationHash: Data)`, `LXMFRouter.Action.Delegate.closeLink(destinationHash: Data)` — app wires `.closeLink` to tear down the real link.

- [ ] **Step 1: Write the headline failing test (idle link torn down)**

Append to `Tests/ReTiCANodeTests/LXMFRouterTests.swift` a new section (after the LXMF-4c-3a tests):

```swift
// MARK: - LXMF-4c-3b idle-link teardown

@Test @MainActor func routerTearsDownIdleLink() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let linkID = Data(repeating: 0x33, count: 16)
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(msg.destinationHash)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    await store.send(.linkEstablished(destinationHash: msg.destinationHash, linkID: linkID))
    await store.receive { if case .delegate(.sendDirect) = $0 { return true }; return false }   // drain arms idle timer
    await store.send(.delivered(messageHash: msg.hash))   // clear pending + its retry timer; idle timer remains
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    #expect(store.state.directLinks[msg.destinationHash] == .active(linkID: linkID))
    // No further activity for the inactivity window → the link is torn down.
    await clock.advance(by: .seconds(LXMFDelivery.linkMaxInactivitySeconds))
    await store.receive { action in
        if case let .delegate(.closeLink(dest)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    #expect(store.state.directLinks[msg.destinationHash] == nil)
}
```

- [ ] **Step 2: Run it — verify it fails**

Run: `swift test --filter LXMFRouterTests.routerTearsDownIdleLink`
Expected: BUILD FAILURE — `.idleDeadline`/`.closeLink`/`linkMaxInactivitySeconds` referenced by the reducer don't exist yet (and the test references `.closeLink`). This is the expected red.

- [ ] **Step 3: Add the CancelID case, action, delegate, and idle timer helper**

In `Sources/ReTiCANode/LXMFRouter.swift`:

`CancelID` (line 14):

```swift
    private enum CancelID: Hashable { case retry(Data); case idle(Data) }
```

`Action` — add after `case retryDue(messageHash: Data)` (line 52):

```swift
        case idleDeadline(destinationHash: Data)
```

`Action.Delegate` — add after `case sendDirect(linkID: Data, data: Data, asResource: Bool)` (line 61):

```swift
            case closeLink(destinationHash: Data)
```

Idle timer helper — add after the `retryTimer` helper (after line 76):

```swift
            func idleTimer(_ dest: Data) -> Effect<Action> {
                .run { send in
                    try await clock.sleep(for: .seconds(LXMFDelivery.linkMaxInactivitySeconds))
                    await send(.idleDeadline(destinationHash: dest))
                }.cancellable(id: CancelID.idle(dest), cancelInFlight: true)
            }
```

- [ ] **Step 4: Arm/restart the idle timer on each new `sendDirect`**

At `.send` direct-active (lines 125-127), replace:

```swift
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: message.packed,
                                                                  asResource: asResource))),
                                      retryTimer(message.hash, LXMFDelivery.retryWaitSeconds))
```

with:

```swift
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: message.packed,
                                                                  asResource: asResource))),
                                      retryTimer(message.hash, LXMFDelivery.retryWaitSeconds),
                                      idleTimer(dest))
```

At the `.linkEstablished` drain, replace the tail (lines 146-147):

```swift
                }
                return effects.isEmpty ? .none : .merge(effects)
```

with:

```swift
                }
                if !queued.isEmpty { effects.append(idleTimer(dest)) }
                return effects.isEmpty ? .none : .merge(effects)
```

(The `.retryDue` active-link resend deliberately does NOT arm the idle timer — a retry saga ≈ 50s ≪ 600s, so the original send's arm already covers it.)

- [ ] **Step 5: Add the `.idleDeadline` case**

In `Sources/ReTiCANode/LXMFRouter.swift`, add a new case after the `.retryDue` case closes (after line 200, before `case .delegate:`):

```swift
            case let .idleDeadline(dest):
                guard case .active = state.directLinks[dest] else { return .none }
                state.directLinks[dest] = nil
                return .send(.delegate(.closeLink(destinationHash: dest)))
```

- [ ] **Step 6: Run the headline test — verify it passes**

Run: `swift test --filter LXMFRouterTests.routerTearsDownIdleLink`
Expected: PASS.

- [ ] **Step 7: Remove the now-incompatible trailing `.on` flip from 3 existing tests**

Adding a 600s idle timer means a test that flips `exhaustivity = .on` while an active link with recent `sendDirect` activity remains will see that timer as an in-flight effect (which `.on` rejects at teardown). In each of these THREE tests, delete the final `store.exhaustivity = .on` line (the last statement before the closing brace). Their core `.off` `receive` assertions are unchanged; only the extra teardown stray-check is dropped.

- `routerDirectRetryUnaffectedByMissingPath`
- `routerRecoversPendingOnNewLinkAfterClose`
- `routerLinkClosedWithPendingReestablishes`

(The other `.on`-flipping tests are opportunistic-only or emit no `sendDirect`, so no idle timer is armed — leave them as-is.)

- [ ] **Step 8: Add the activity-restarts test**

Append to the `// MARK: - LXMF-4c-3b idle-link teardown` section:

```swift
/// New activity on an active link restarts the idle timer, so teardown is deferred to the last send.
@Test @MainActor func routerActivityRestartsIdleTimer() async {
    let sender = Identity()
    let recipient = Identity().hash
    let msg = makeMessage(source: sender, recipientIdentityHash: recipient, content: "one")
    let msg2 = makeMessage(source: sender, recipientIdentityHash: recipient, content: "two")
    #expect(msg.destinationHash == msg2.destinationHash)   // same recipient delivery destination
    let linkID = Data(repeating: 0x44, count: 16)
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.directLinks[msg.destinationHash] = .active(linkID: linkID)
    initial.knownPaths.insert(msg.destinationHash)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    // First send arms the idle timer.
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.sendDirect) = $0 { return true }; return false }
    await store.send(.delivered(messageHash: msg.hash))
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    // Almost to the deadline — not torn down yet.
    await clock.advance(by: .seconds(LXMFDelivery.linkMaxInactivitySeconds - 1))
    #expect(store.state.directLinks[msg.destinationHash] == .active(linkID: linkID))
    // A second send restarts the idle timer.
    await store.send(.send(message: msg2, desiredMethod: .direct))
    await store.receive { if case .delegate(.sendDirect) = $0 { return true }; return false }
    await store.send(.delivered(messageHash: msg2.hash))
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    // Past the ORIGINAL deadline but before the restarted one → still active (proves the restart).
    await clock.advance(by: .seconds(LXMFDelivery.linkMaxInactivitySeconds - 1))
    #expect(store.state.directLinks[msg.destinationHash] == .active(linkID: linkID))
    // The remainder of the restarted window elapses → torn down.
    await clock.advance(by: .seconds(1))
    await store.receive { action in
        if case let .delegate(.closeLink(dest)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    #expect(store.state.directLinks[msg.destinationHash] == nil)
}
```

- [ ] **Step 9: Run the full router test file — verify all pass**

Run: `swift test --filter LXMFRouterTests`
Expected: PASS — existing router tests (3 with the `.on` flip removed) plus the 2 new ones.

- [ ] **Step 10: Mutation verification (one mutation at a time)**

Apply each individually in `Sources/ReTiCANode/LXMFRouter.swift`, run `swift test --filter LXMFRouterTests`, confirm the named test fails, then revert before the next.

1. **Drop the idle arm at `.send` direct-active** — remove the `, idleTimer(dest)` argument from the `.send` direct-active `.merge`.
   → `routerActivityRestartsIdleTimer` FAILS (no idle timer is ever armed for that seeded active link, so no `closeLink` arrives; the final `receive { closeLink }` times out).
2. **Drop the idle arm at the `.linkEstablished` drain** — remove the `if !queued.isEmpty { effects.append(idleTimer(dest)) }` line.
   → `routerTearsDownIdleLink` FAILS (the drained link arms no idle timer; `receive { closeLink }` times out after the advance).
3. **`.idleDeadline` does not tear down** — change the `.idleDeadline` body to `return .none` (drop nothing, emit nothing).
   → both `routerTearsDownIdleLink` and `routerActivityRestartsIdleTimer` FAIL (no `closeLink`, link stays active).

After each: revert, run `swift test --filter LXMFRouterTests`, expect PASS before the next.

- [ ] **Step 11: Full test gate**

Run: `swift test`
Expected: PASS. The 4c-3a baseline was 426 passed / 1 pre-existing live-node skip / 0 fail; this slice adds 1 cross-val (Task 1) + 2 router tests (Task 2) → 429 passed. On a signal-11/signal-10 build flake, run `swift package clean` (single command) and re-run.

- [ ] **Step 12: Commit**

Write the message to `/tmp/ReTiCA/commit-msg-4c3b-t2.txt` with the Write tool (body below), then:

```bash
git add Sources/ReTiCANode/LXMFRouter.swift Tests/ReTiCANodeTests/LXMFRouterTests.swift
```

```bash
git commit -F /tmp/ReTiCA/commit-msg-4c3b-t2.txt
```

Commit message body:

```
feat: LXMF-4c-3b task 2 — idle-link teardown

Per-destination cancellable idleTimer (linkMaxInactivitySeconds=600),
armed/restarted on each new sendDirect (.send direct-active +
.linkEstablished drain; cancelInFlight). On .idleDeadline an active link
is dropped and .closeLink(dest) emitted. The .retryDue resend does not
re-arm (a retry saga is far shorter than the idle window). Dropped the
now-incompatible trailing exhaustivity=.on flip from 3 existing tests
(the persistent idle timer is legitimately in-flight). 2 new tests.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Self-Review

**Spec coverage:**
- Spec "Core constant" (`linkMaxInactivitySeconds = 600` + cross-val) → Task 1. ✓
- Spec `CancelID.idle`, `Action.idleDeadline`, `Delegate.closeLink`, `idleTimer` helper → Task 2 Step 3. ✓
- Spec "restart on activity at the two send sites" → Task 2 Step 4 (`.send` direct-active + `.linkEstablished` drain; `.retryDue` deliberately excluded per the amended spec). ✓
- Spec `.idleDeadline` (guard active → drop + closeLink) → Step 5. ✓
- Spec test 1 (idle teardown fires) → `routerTearsDownIdleLink`, Step 1. ✓
- Spec test 2 (activity restarts) → `routerActivityRestartsIdleTimer`, Step 8. ✓
- Spec test 3 (cross-val constant) → Task 1 Step 5. ✓
- Spec "existing-test ripple" → Step 7 (exact set of 3 pinned by inspection: the only `.on`-flipping tests that emit a `sendDirect`). ✓

**Placeholder scan:** none — every code step shows exact code.

**Type consistency:** `LXMFDelivery.linkMaxInactivitySeconds` (Task 1) used verbatim in the `idleTimer` helper and both new tests. `Action.idleDeadline(destinationHash:)` and `Delegate.closeLink(destinationHash:)` used consistently in the reducer and tests. `CancelID.idle(dest)` matches the `idleTimer` cancellation id. `LXMFVectorFixtures.linkMaxInactivity` matches the generator's `link_max_inactivity` key and the cross-val test's `f.linkMaxInactivity`.
