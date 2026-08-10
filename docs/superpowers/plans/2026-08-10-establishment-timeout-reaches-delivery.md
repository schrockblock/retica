# Establishment Timeout Reaches the Delivery Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A link that times out during establishment reaches the delivery layer instead of wedging the destination forever, and the path-request park that follows a give-up is itself bounded — so a queued message always terminates in `deliveryFailed`.

**Architecture:** Two independent fixes. (1) `LinkSession` emits `.establishmentFailed` — not `.closed(.timedOut)` — when the establishment deadline fires for an **initiator**, so it routes to `linkFailed(destinationHash:)` which needs no reverse-map. (2) `LXMFRouter` arms a bounded timer on the `.awaitingPath` park, reusing the `establishAttempts` budget added by the previous slice.

**Tech Stack:** Swift 6 / TCA / swift-testing. Repo: `/Users/ell/development/ios/pods/ReTiCA`.

## Background: the two defects, both verified against source

### Defect 1 — an establishment timeout never reaches the router

`LinkSession.swift:527-530` emits `.delegate(.closed(.timedOut))` when the establishment deadline fires. `.establishmentFailed` is emitted **only** for malformed handshakes (`LinkSession.swift:235, 260, 264, 285`). The two delegates route differently:

- `.closed(reason)` → `LinkPlane.swift:184-187` → `linkClosed(linkID:reason:)`
- `.establishmentFailed` → `LinkPlane.swift:189-192` → `linkFailed(destinationHash:)`

`LXMFNode.swift:260-265` handles `linkClosed` by reverse-mapping the linkID to a destination:

```swift
guard let dest = state.directLinks.first(where: { $0.value == linkID })?.key else { return .none }
```

`LXMFNode.directLinks` is written **only** at `LXMFNode.swift:256`, inside `.linkEstablished`. A link that timed out *during establishment* never established, so it has no entry, so this returns `.none`.

**Consequence:** `LXMFRouter.State.directLinks[dest]` stays pinned at `.establishing` (set at `LXMFRouter.swift:146`) for the process lifetime. Nothing unsticks it:
- `.send(.direct)` sees `directLinks[dest] != nil` and silently appends to `outboundQueue`.
- `.learnedPath` acts only on `.awaitingPath` (`LXMFRouter.swift:324`) — **so a peer that returns and re-announces does not recover the destination.**
- `.idleDeadline` guards on `case .active`.
- `.syncFromPropagationNode` short-circuits, leaving `pendingDownloadFromPN = true` — **propagation sync dies for the process lifetime.**

No timer, no retry, no `deliveryFailed`. The message sits in `outboundQueue` and the UI row stays at "sending" until the app is killed.

### Defect 2 — the post-ceiling `.awaitingPath` park is unbounded

The previous slice's ceiling clears `knownPaths`, so the next send takes `establish`'s else-branch: `directLinks[dest] = .awaitingPath` + `.requestPath` (`LXMFRouter.swift:149-150`). **Nothing bounds that park.** No timer is armed, no attempt is counted, no `deliveryFailed` is ever emitted.

The `.retryDue` opportunistic saga already solves exactly this correctly (`LXMFRouter.swift:369-372`): emit `requestPath`, re-arm `retryTimer(hash, pathRequestWaitSeconds)`, and the attempt still counts toward `maxAttempts`. The queued/direct path has no equivalent. We replaced an unbounded retry with an unbounded wait.

The exit event is also not guaranteed: `pathLearned` is gated on `shouldReplace` (`Transport.swift:997-1002`), and a **relay-cached** path response (`Transport.swift:511-517`) re-emits the cached payload verbatim, so `shouldReplace` returns false unless hop count improved → no `pathLearned` → the router never leaves `.awaitingPath`.

## Global Constraints

- Commit directly to `main`. No branches, merges, rebases, resets.
- **You are the implementer, NOT the controller. Do NOT invoke the `superpowers:subagent-driven-development` skill or run any of its scripts.**
- The user commits CONCURRENTLY. `git add` ONLY the files each task names — never `-A`, never `.`.
- **One command per Bash invocation** — no `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, and never inline a script into a CLI (`python -c`, `bash -c`, heredocs into interpreters). Redirect output to a file under `/tmp/ReTiCA/` and read it.
- Commit trailers MUST start at column 0:
```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
```
- Baseline: **745/745 with 1 known issue** (`holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood`). Use `swift test --no-parallel` for the final run — parallel execution flakes `PNNode*`, `LXMFNodeSync*`, `twoEndpointsTransferMultiSegmentResourceOverALink`, `pairedModePublishesWithEncryptionAndEncryptedReadPerms`. Classify with `--filter` before reporting any failure.
- **If a PRE-EXISTING test fails, STOP and report — do not fix it**, EXCEPT the two tests Task 1 explicitly names as needing updates.
- Mutation discipline every task, through DISJOINT observation points; run mutations SEPARATELY when they would mask each other.

## TestStore traps — both cost us fix rounds on the previous slice

1. **Do NOT count actions with a `LockIsolated` mutated inside a `store.receive` predicate.** Verified in TCA source: the predicate is invoked in four places including an unbounded polling loop (`TestStore.swift:1855-1863`), so counts inflate. Assert via ordered `store.receive` and/or `store.state`.
2. **`.off` swallows absence assertions.** `assertNoReceivedActions` routes through `reportIssueHelper` (`TestStore.swift:2191`), a no-op under `.off`. To assert "X was NOT emitted": set `store.exhaustivity = .on`, **then send once more**, and let teardown catch a stray. A trailing `.on` flip with no send after it is a **no-op**.
3. **Do not seed the state you claim to prove.** Drive the reducer to its precondition.

---

### Task 1: An initiator's establishment timeout becomes an establishment failure

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift` (the `.establishmentDeadline` case, `:527-530`)
- Test: `Tests/ReTiCATransportTests/LinkSessionTests.swift` (two EXISTING tests need updating)
- Test: `Tests/ReTiCANodeTests/LXMFNodeTests.swift` (new integration test — check the actual filename; put it wherever the existing `LXMFNode` store tests live)

**Interfaces:**
- Consumes: `LinkSession.Role` (`:15`), `LinkSession.Action.Delegate.establishmentFailed` (`:145`), both existing.
- Produces: initiator establishment timeouts now surface as `LinkPlane.Delegate.linkFailed(destinationHash:)` instead of `.linkClosed(linkID:reason:)`.

- [ ] **Step 1: Write the failing integration test**

This is the test the previous slice never had — it is the whole point of the task. It must drive a **real `LXMFNode` store**, not a bare `LXMFRouter`, because the defect lives in the seam between them.

Read the existing `LXMFNode` integration tests first (search for `lxmfNodeOpportunisticDeliversEndToEnd` and `lxmfNodeDirectDeliversResourceAndConfirms`) and follow their store-construction pattern and clock injection.

```swift
/// An establishment timeout must reach the router. Before this change, LinkSession emitted
/// .closed(.timedOut) rather than .establishmentFailed, so it arrived as linkClosed(linkID:)
/// and died at the LXMFNode reverse-map (directLinks is written only on linkEstablished) —
/// leaving the destination pinned at .establishing forever, with the message parked in
/// outboundQueue, no timer, no retry and no deliveryFailed.
@Test @MainActor func establishmentTimeoutReachesRouterAndDoesNotWedgeDestination() async {
    // Build an LXMFNode store with a TestClock.
    // Send a direct message to a destination that has a learned path (so openLink proceeds
    // and a link is actually minted) but whose peer never answers.
    // Advance the clock past establishmentTimeout.
    // Assert: the router LEAVES .establishing — i.e. directLinks[dest] is not stuck.
    //         Prefer asserting the OBSERVABLE consequence (a re-established attempt, or
    //         eventually deliveryFailed) over asserting an internal enum, so the test says
    //         something about behaviour rather than representation.
}
```

If wiring a full `LXMFNode` store proves impractical for this scenario, STOP and report rather than silently downgrading to an `LXMFRouter`-only test — an `LXMFRouter`-only test cannot observe this defect at all, which is exactly why it survived the previous slice's review.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter establishmentTimeoutReachesRouterAndDoesNotWedgeDestination`
Expected: FAIL — the destination stays `.establishing` and nothing is emitted.

- [ ] **Step 3: Implement**

Replace the `.establishmentDeadline` case at `LinkSession.swift:527-530`:

```swift
            case .establishmentDeadline:
                guard state.status == .pending || state.status == .handshake else { return .none }
                state.status = .closed
                // An INITIATOR's establishment timeout is an establishment FAILURE, and must be
                // delivered keyed by DESTINATION. Emitting .closed here instead surfaces as
                // linkClosed(linkID:), which LXMFNode cannot reverse-map — directLinks is written
                // only on linkEstablished (LXMFNode.swift:256) — so the destination would wedge at
                // .establishing forever with no timer, no retry and no deliveryFailed.
                //
                // A RESPONDER's timeout stays .closed: the peer opened a link to US, our
                // destinationHash is our own served destination, and reporting linkFailed for it
                // would tell the delivery layer that a peer it never contacted is unreachable.
                if state.role == .initiator {
                    return .merge(.send(.delegate(.establishmentFailed)), cancelAll, cancelPending(&state))
                }
                return .merge(.send(.delegate(.closed(.timedOut))), cancelAll, cancelPending(&state))
```

- [ ] **Step 4: Update the two existing tests that pin the old behaviour**

Both are in `Tests/ReTiCATransportTests/LinkSessionTests.swift` and currently assert `.delegate(.closed(.timedOut))` after `.establishmentDeadline`:

- `:96-97` — the **initiator** case (status `.pending`). Change to expect `.delegate(.establishmentFailed)`. Note the state mutation: the old assertion carried `{ $0.status = .closed }`; keep whatever the reducer actually does (it still sets `.closed`) — adapt the trailing closure rather than deleting it.
- `:125-127` — the **responder** case (status `.handshake`). This one must STAY `.closed(.timedOut)`. Add a comment explaining that the role gate is deliberate, so a future reader does not "fix" the asymmetry.

Do not delete either test. If either now fails for a reason other than the delegate change, STOP and report.

- [ ] **Step 5: Run the full suite**

Run: `swift test --no-parallel > /tmp/ReTiCA/task1-suite.txt 2>&1` then read the file.
Expected: 746/746 (745 + 1 new), 1 known issue.

- [ ] **Step 6: Mutation verification (run SEPARATELY)**

1. Remove the `role == .initiator` gate so BOTH roles emit `.establishmentFailed` → the responder test at `:125-127` must fail.
2. Revert the whole case to always emitting `.closed(.timedOut)` → the new integration test AND the initiator test must fail.

Report each verbatim. Revert; green.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/timeout-task1-msg.txt` (subject `fix: an initiator's establishment timeout must reach the delivery layer`), then `git add` exactly the three files you touched and `git commit -F`.

---

### Task 2: Bound the `.awaitingPath` park

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift`
- Test: `Tests/ReTiCANodeTests/LXMFRouterTests.swift`

**Interfaces:**
- Consumes: `State.establishAttempts` and `LXMFDelivery.maxAttempts` (from the previous slice); `LXMFDelivery.pathRequestWaitSeconds` (already used at `LXMFRouter.swift:372`).
- Produces: `Action.pathRequestDeadline(destinationHash:)`; `CancelID.pathRequest(Data)`.

- [ ] **Step 1: Write the failing tests**

```swift
/// A queued message parked in .awaitingPath must not wait forever. Before this change,
/// establish's else-branch emitted requestPath and parked with NO timer, NO attempt count and
/// NO deliveryFailed — so a destination whose path response never arrives (or arrives as a
/// relay-cached response that shouldReplace rejects) stalled indefinitely.
@Test @MainActor func routerBoundsTheAwaitingPathPark() async {
    // Drive a send to a destination NOT in knownPaths -> assert requestPath + .awaitingPath.
    // Advance the clock by pathRequestWaitSeconds repeatedly.
    // Assert the path request is RE-emitted each round, and after maxAttempts the queued
    // message gets deliveryFailed and the park is cleared.
}

/// Learning a path cancels the park timer — a destination that recovers must not later be
/// failed by a stale deadline.
@Test @MainActor func routerLearnedPathCancelsTheAwaitingPathTimer() async {
    // Park in .awaitingPath, then send .learnedPath(dest).
    // Advance the clock well past pathRequestWaitSeconds.
    // Assert NO pathRequestDeadline consequence fires (no spurious deliveryFailed).
    // Use the .on-flip-then-send idiom for the absence half — a trailing .on is a no-op.
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter routerBoundsTheAwaitingPathPark` — FAIL (no such action; nothing is armed).

- [ ] **Step 3: Implement**

Add to the CancelID enum (`LXMFRouter.swift:14`):

```swift
private enum CancelID: Hashable { case retry(Data); case idle(Data); case pathRequest(Data) }
```

Add the action beside `idleDeadline` (`:96`):

```swift
case pathRequestDeadline(destinationHash: Data)
```

Add a timer helper beside `idleTimer` (`:127`), following its exact shape:

```swift
func pathRequestTimer(_ dest: Data) -> Effect<Action> {
    .run { send in
        try await clock.sleep(for: .seconds(LXMFDelivery.pathRequestWaitSeconds))
        await send(.pathRequestDeadline(destinationHash: dest))
    }.cancellable(id: CancelID.pathRequest(dest), cancelInFlight: true)
}
```

In `establish`'s else-branch (`:149-150`), arm it alongside the request:

```swift
state.directLinks[dest] = .awaitingPath
return .merge(.send(.delegate(.requestPath(destinationHash: dest))), pathRequestTimer(dest))
```

Handle the deadline. **Reuse `establishAttempts`** — the park is part of the same establishment saga, so a destination cannot get a fresh budget by alternating between the two branches:

```swift
case let .pathRequestDeadline(dest):
    guard state.directLinks[dest] == .awaitingPath else { return .none }
    let attempts = (state.establishAttempts[dest] ?? 0) + 1
    if attempts > LXMFDelivery.maxAttempts {
        return giveUp(&state, dest)
    }
    state.establishAttempts[dest] = attempts
    return .merge(.send(.delegate(.requestPath(destinationHash: dest))), pathRequestTimer(dest))
```

**Extract the ceiling body from `establish` into a shared `giveUp(_:_:)` helper** rather than duplicating it — it already clears `establishAttempts`/`knownPaths`/`directLinks`, drains both queues and emits `deliveryFailed` per message. Both call sites must behave identically. Place it beside `establish`.

Cancel the park timer wherever the park ends:
- `.learnedPath` (`:311-330`) — the destination left `.awaitingPath`.
- inside `giveUp` — the park is over.
- `.linkEstablished` (`:255-`) — defensive; a link arriving while parked ends the park.

Cancel with `.cancel(id: CancelID.pathRequest(dest))`, merged into the returned effect.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter LXMFRouterTests`
Expected: all pass, including every test from the previous slice. **If a previous-slice test now fails, STOP and report** — `giveUp` extraction must be behaviour-preserving.

- [ ] **Step 5: Full suite**

Run: `swift test --no-parallel > /tmp/ReTiCA/task2-suite.txt 2>&1` then read it.
Expected: 748/748, 1 known issue.

- [ ] **Step 6: Mutation verification (run SEPARATELY)**

1. Drop the `pathRequestTimer` from `establish`'s else-branch → `routerBoundsTheAwaitingPathPark` fails.
2. Remove the ceiling check in `.pathRequestDeadline` (always re-request) → the same test fails at the `deliveryFailed` assertion.
3. Remove the `.learnedPath` cancel → `routerLearnedPathCancelsTheAwaitingPathTimer` fails.

Report each verbatim. Revert; green.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/timeout-task2-msg.txt` (subject `fix: bound the awaitingPath park so a queued message always terminates`), then `git add` the two files and `git commit -F`.

---

## Final verification (after Task 2)

- [ ] `swift test --no-parallel` — report the exact count.
- [ ] `grep -rn "establishmentFailed" Sources/` — confirm the new initiator-timeout emitter is present alongside the four malformed-handshake ones.
- [ ] Confirm `giveUp` has exactly two call sites (the `establish` ceiling and `.pathRequestDeadline`) and that both previously-passing ceiling tests still pass.
- [ ] Confirm every path out of `.awaitingPath` cancels `CancelID.pathRequest` — grep the cancel and match against the transitions.
- [ ] `git log --format='%(trailers:key=Claude-Session)' -2` — both commits' trailers parse.
