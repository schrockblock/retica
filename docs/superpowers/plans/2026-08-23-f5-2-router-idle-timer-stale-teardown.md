# F5.2 — Stale Router Idle-Timer Teardown Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop a closed link's stale idle timer from tearing down the link that re-established on the same destination, and give every re-established link its own idle timer.

**Architecture:** In `LXMFRouter`, always arm the idle timer at `.linkEstablished` (its `cancelInFlight` cancels the prior link's stale timer and provisions the new link), and stamp the idle deadline with the linkID it was armed for so the handler closes only that exact link. Fixes the direct and PN-sync shapes together.

**Tech Stack:** Swift, The Composable Architecture (TCA / swift-testing). Package: ReTiCA, target `ReTiCANode` (`LXMFRouter`).

## Global Constraints

- Repo: `/Users/ell/development/ios/pods/ReTiCA`. Edits in `Sources/ReTiCANode/LXMFRouter.swift` and `Tests/ReTiCANodeTests/LXMFRouterTests.swift` only. No wire-format change. No reference/cap concern (internal router timer state).
- Commit directly to `main`. No feature branch.
- Commit trailers start at **column 0**. End every commit with exactly:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
  ```
  Write the message to a file, `git commit -F <file>`, verify: `git -C /Users/ell/development/ios/pods/ReTiCA log -1 --format='%(trailers:key=Claude-Session)'` echoes the trailer.
- **One command per shell invocation.** No `|`, `&&`, `||`, `;`, `$(...)`, `xargs`. Redirect a single command's output to a file under /tmp/ReTiCA/ (create with one `mkdir -p`) and Read it back.
- Run tests: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter <TestName>` (single) or without `--filter` for the full suite (expect the 1 known-issue test `holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood` — not your failure). Timeout up to 600000ms. On a spurious signal-11/signal-10 or stale-link `LinkSessionRequestTests` failure, run `swift package clean --package-path /Users/ell/development/ios/pods/ReTiCA` once and retry.
- **Mutation verification mandatory** (three-step rule): green → apply the stated mutation → confirm red → revert → confirm green, before committing.
- Tests keep `store.exhaustivity = .off`. Line numbers here are approximate — locate code by the quoted surrounding lines and report drift.

---

### Task 1: Always-arm the idle timer and linkID-stamp its deadline

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` — the `Action.idleDeadline` case (`:174`), the `idleTimer` helper (`:206-211`), three arming call sites (`:389`, `:415`, `:421`), the `.linkEstablished` arm condition (`:484`), and the `.idleDeadline` handler (`:596-599`).
- Test: `Tests/ReTiCANodeTests/LXMFRouterTests.swift` — add two `@Test` functions.

**Interfaces:**
- Consumes (existing): `LXMFRouter.State.directLinks: [Data: LinkStatus]`, `LinkStatus.active(linkID: Data)`, `clearDirectLink(_:_:)` (from F7), `LXMFDelivery.linkMaxInactivitySeconds`; test helper `makeMessage(...)`.
- Produces: `idleTimer(_ dest: Data, _ linkID: Data)`; `Action.idleDeadline(destinationHash: Data, linkID: Data)`.

- [ ] **Step 1: Write the failing tests**

Add to `LXMFRouterTests.swift`:

```swift
// F5.2 (stamp): a stale idle deadline carrying an OLD linkID must not close the link that has since
// re-established on the same destination with a NEW linkID.
@Test @MainActor func staleIdleDeadlineDoesNotCloseANewerLink() async {
    let dest = Data(repeating: 0x51, count: 16)
    let oldLinkID = Data(repeating: 0xA1, count: 16)
    let newLinkID = Data(repeating: 0xB2, count: 16)
    var initial = LXMFRouter.State()
    initial.directLinks[dest] = .active(linkID: newLinkID)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.idleDeadline(destinationHash: dest, linkID: oldLinkID))
    #expect(store.state.directLinks[dest] == .active(linkID: newLinkID),
            "a stale idle deadline (old linkID) must not close the current link")
}

// F5.2 (always-arm): a link established with NOTHING queued (the retry / PN-sync re-establish shape)
// must still get its own idle timer, so it idle-closes instead of lingering forever.
@Test @MainActor func linkEstablishedWithEmptyQueueStillArmsAnIdleTimer() async {
    let dest = Data(repeating: 0x52, count: 16)
    let linkID = Data(repeating: 0xC3, count: 16)
    let clock = TestClock()
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.linkEstablished(destinationHash: dest, linkID: linkID))
    #expect(store.state.directLinks[dest] == .active(linkID: linkID))
    await clock.advance(by: .seconds(LXMFDelivery.linkMaxInactivitySeconds))
    await store.receive { action in
        if case let .delegate(.closeLink(d)) = action { #expect(d == dest); return true }
        return false
    }
    #expect(store.state.directLinks[dest] == nil,
            "an empty-queue re-established link must still idle-close on its own timer")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter staleIdleDeadlineDoesNotCloseANewerLink`
Expected: FAILS to compile first — `.idleDeadline` has no `linkID` yet. That IS the red state; both tests reference the new signature.

- [ ] **Step 3: Add `linkID` to the `.idleDeadline` action**

In `LXMFRouter.swift:174`, change:
```swift
        case idleDeadline(destinationHash: Data)
```
to:
```swift
        case idleDeadline(destinationHash: Data, linkID: Data)
```

- [ ] **Step 4: Thread `linkID` through the `idleTimer` helper**

Replace the `idleTimer` helper (`:206-211`):
```swift
            func idleTimer(_ dest: Data) -> Effect<Action> {
                .run { send in
                    try await clock.sleep(for: .seconds(LXMFDelivery.linkMaxInactivitySeconds))
                    await send(.idleDeadline(destinationHash: dest))
                }.cancellable(id: CancelID.idle(dest), cancelInFlight: true)
            }
```
with:
```swift
            func idleTimer(_ dest: Data, _ linkID: Data) -> Effect<Action> {
                .run { send in
                    try await clock.sleep(for: .seconds(LXMFDelivery.linkMaxInactivitySeconds))
                    await send(.idleDeadline(destinationHash: dest, linkID: linkID))
                }.cancellable(id: CancelID.idle(dest), cancelInFlight: true)
            }
```

- [ ] **Step 5: Pass `linkID` at the two send-path arming sites**

In the `.send` direct-active arm (`:389`), change `idleTimer(dest)` to `idleTimer(dest, linkID)` (the `linkID` is already bound by the enclosing `if case let .active(linkID) = state.directLinks[dest]`). In the two `.sendViaPropagation` arms (`:415` and `:421`), change `idleTimer(pn)` to `idleTimer(pn, linkID)` (bound by `if case let .active(linkID) = state.directLinks[pn]`).

- [ ] **Step 6: Always arm at `.linkEstablished`**

At `:484`, replace:
```swift
                    if !queued.isEmpty || !propQueued.isEmpty { effects.append(idleTimer(dest)) }
```
with:
```swift
                    // Always arm — not only when a queue was drained. A link re-established for a
                    // still-pending delivery or a PN sync drains no queue, so the old "only if queued"
                    // left it with no timer while the prior link's stale timer lived on (F5.2). The
                    // cancelInFlight on CancelID.idle(dest) also cancels that stale timer here.
                    effects.append(idleTimer(dest, linkID))
```
(`linkID` is the `.linkEstablished(destinationHash: dest, linkID: linkID)` case binding.)

- [ ] **Step 7: linkID-stamp the `.idleDeadline` handler**

Replace the handler (`:596-599`):
```swift
            case let .idleDeadline(dest):
                guard case .active = state.directLinks[dest] else { return .none }
                clearDirectLink(&state, dest)
                return .send(.delegate(.closeLink(destinationHash: dest)))
```
with:
```swift
            case let .idleDeadline(dest, linkID):
                // Close ONLY the link this timer was armed for. A stale timer from a prior link on
                // this dest (or one that fired in the close→re-establish gap) finds a different
                // linkID — or none — and no-ops (F5.2).
                guard case let .active(current) = state.directLinks[dest], current == linkID
                else { return .none }
                clearDirectLink(&state, dest)
                return .send(.delegate(.closeLink(destinationHash: dest)))
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter staleIdleDeadlineDoesNotCloseANewerLink` → PASS.
Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter linkEstablishedWithEmptyQueueStillArmsAnIdleTimer` → PASS.

- [ ] **Step 9: Mutation-verify both fixes**

(a) In Step 7, drop the `, current == linkID` clause (guard only `case .active`). Run `staleIdleDeadlineDoesNotCloseANewerLink` → FAIL (the stale deadline closes the current link). Revert.
(b) In Step 6, restore the `if !queued.isEmpty || !propQueued.isEmpty { … }` condition. Run `linkEstablishedWithEmptyQueueStillArmsAnIdleTimer` → FAIL (no timer armed → the expected `.closeLink` never arrives → the `receive` times out). Revert.
Run both tests again → PASS.

- [ ] **Step 10: Full suite + commit**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA` — all pass except the known issue. Watch for two ripples: (a) any test that matched or sent `.idleDeadline(destinationHash:)` must add the `linkID:` argument (existing idle tests match on `.delegate(.closeLink)`, so most are unaffected — grep to confirm); (b) always-arming means an empty-queue `.linkEstablished` now leaves an idle timer in flight, so any existing test that flips `exhaustivity = .on` after such a call must drop the trailing `.on` (the same adjustment the F7/F11 work made). If an existing test breaks for either reason, update it to the new shape — do not weaken the new behavior.
Stage only the two files. Commit:
```
fix: F5.2 — a stale router idle timer no longer tears down a re-established link

LXMFRouter's per-dest idle timer was never cancelled on close and was re-armed
at .linkEstablished only when a queue was drained, so a link re-established for a
still-pending delivery (or a PN sync) kept the prior link's timer alive; it fired
on its original deadline and .idleDeadline's .active guard matched the NEW link,
closing it. Always arm at .linkEstablished (cancelInFlight cancels the stale
timer and provisions the new link) and stamp .idleDeadline with the linkID it was
armed for so it closes only that link. Fixes the direct and PN-sync shapes.
```
Verify the trailer parses.

---

## Notes for the executor

- **The two changes are complementary:** always-arm (Step 6) both cancels the stale timer via `cancelInFlight` and gives every re-established link its own timer; the linkID stamp (Step 7) makes "a stale timer can't close a link it wasn't armed for" a local guarantee in the handler. Keep both.
- **The end-to-end narrative** (send → establish A → close → re-establish B → advance past A's original deadline → B survives → B closes on its own deadline) is deliberately decomposed into the two tests above rather than driven literally: a literal E2E keeps the message pending to trigger re-establishment, which keeps the retry saga (retryWaitSeconds/maxAttempts) firing during the long clock advance and makes the test brittle. The stamp test proves a stale deadline can't close the newer link; the always-arm test proves the re-established link gets its own timer — together they establish the property without the retry-saga entanglement. Do not add a brittle literal E2E.
- **Do not** touch `.retryDue`'s deliberate non-re-arm, the six `linkResourceInFlight` write sites, or `clearDirectLink` (F7).
- **Out of scope:** the rest of the F5 grab-bag (separate items).
