# Bound the Link-Establishment Saga Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A queued LXMF message to an unreachable peer stops retrying link establishment forever. It gives up after `maxAttempts`, fails its messages cleanly, and forgets the path it can demonstrably no longer use.

**Architecture:** A per-destination attempt counter in `LXMFRouter`, mirroring the existing `pendingDeliveries.attempts` saga rather than inventing a second bounding concept. At the ceiling: drain the destination's queues, emit `deliveryFailed` per message, and clear `knownPaths[dest]` so the next send requests a path instead of another link.

**Tech Stack:** Swift 6 / TCA / swift-testing. Repo: `/Users/ell/development/ios/pods/ReTiCA`.

## The bug, which exists today and is not hypothetical

`LXMFRouter.linkClosed` (`:260-278`) re-establishes whenever anything is queued:

```swift
let hasQueued = !(state.outboundQueue[dest]?.isEmpty ?? true)
    || !(state.propagationQueue[dest]?.isEmpty ?? true)
if hasPending || hasQueued { return establish(&state, dest) }
```

Nothing counts those attempts. `pendingDeliveries.attempts` bounds only the **`retryDue` timer** path (`:302-307`); a *queued* message lives in `outboundQueue` and is never armed with a retry timer until `linkEstablished` drains it (`:226-238`). So:

`.send(.direct)` with no link → queue + `establish` → `requestLink` → `LXMFNode` → `openLink` → link minted on a dead/unreachable interface → `establishmentDeadline` (~15 s) → `linkFailed` → `LXMFNode:267` → `linkClosed` → `hasQueued` → `establish` → …

**forever.** Today it is paced at ~15 s per iteration by the establishment timeout, so it reads as "slow retry" rather than an unbounded loop — but it never terminates, the radio keeps working, and the message never fails. On a phone whose peer has genuinely gone, this runs until the app is killed.

> ## ⚠️ CORRECTION — the paragraph above is FALSE. Verified after execution.
>
> The `establishmentDeadline → linkFailed` step does not exist. `LinkSession.swift:527-530`
> emits `.delegate(.closed(.timedOut))`, **not** `.establishmentFailed`. Only malformed-handshake
> cases emit `.establishmentFailed` (`LinkSession.swift:235, 260, 264, 285`). So a timeout arrives
> as `linkClosed(linkID:)` (`LinkPlane.swift:184-187`) and dies at `LXMFNode.swift:263`, whose
> reverse-map `directLinks.first(where: { $0.value == linkID })` finds nothing — `directLinks` is
> written **only** on `linkEstablished` (`:256`). The router never sees it.
>
> **The loop this slice actually bounds** is `TCPEndpoint.swift:149-151`: `openLink` with no
> `transport.learned[dest]` returns `linkFailed` IMMEDIATELY. That is a hot, zero-delay spin —
> strictly worse than the 15 s-paced loop described above — and it is reachable exactly when the
> router's `knownPaths` outlives Transport's `learned` table, i.e. the stale-path scenario that
> motivated this work. The slice is therefore MORE valuable than claimed, for a different reason.
>
> **The timeout route is a separate, worse, still-unfixed bug**: the destination wedges at
> `.establishing` permanently. The message sits in `outboundQueue` with no timer, no retry, and no
> `deliveryFailed`; `.learnedPath` acts only on `.awaitingPath` (`LXMFRouter.swift:324`), so even a
> peer that returns and re-announces does not recover it; and `pendingDownloadFromPN` stays true so
> propagation sync dies for the process lifetime. Tracked as the next slice.
>
> **Process note:** the plan's `file:line` citations were all verified before dispatch, but the
> CAUSAL CHAIN between them was not. Verifying that `LXMFNode:267` handles `linkFailed` is not the
> same as verifying that anything EMITS `linkFailed` on the path in question.

This is also why the reverted `openLink` fast-fail (`f0c4670`, reverted `e01f0ce`) was so damaging: it did not *create* the loop, it removed the accidental brake on a loop that was already unbounded. **This slice is the prerequisite that makes fast failure safe** — with a bound in place, failing immediately becomes 5 quick attempts and a clean failure, strictly better than 5 attempts spread over 75 s. Doing these in the other order was the mistake.

## Global Constraints

- Commit directly to `main`. No branches, merges, rebases, resets.
- **You are the implementer, NOT the controller. Do NOT invoke the `superpowers:subagent-driven-development` skill or run any of its scripts.**
- The user commits CONCURRENTLY. `git add` ONLY the files each task names — never `-A`, never `.`.
- One command per Bash invocation — no `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, no inline interpreter scripts. Multi-step work = a script under `/tmp/ReTiCA/`.
- Commit trailers MUST start at column 0:
```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
```
- Mutation discipline every task, **failing through DISJOINT observation points**; run mutations separately when they would mask each other.
- Baseline: 740/740. Known flakes — `PNNode*`, `LXMFNodeSync*`, `twoEndpointsTransferMultiSegmentResourceOverALink`, `pairedModePublishesWithEncryptionAndEncryptedReadPerms` — pass in isolation; classify with `--filter` before reporting. Never say "pre-existing failures" without that classification.
- `skipInFlightEffects()` records a KNOWN issue by design; a test whose only issues are known ones still PASSES.
- **If a PRE-EXISTING test fails, STOP and report — do not fix it.** That call is the controller's. Also report any pre-existing test that keeps PASSING while no longer exercising what its name claims.

## TestStore trap — read before any absence assertion

`store.exhaustivity = .off` is `.off(showSkippedAssertions: false)`, and `TestStore.send` runs `receivedActions = []` on **every** send (`TestStore.swift:921-928`). An "assert nothing was emitted" test is vacuous by default, and a trailing `.on` flip as the last statement is a **no-op**. Make the send whose consequence you assert the **last** `store.send`, or capture effects in a dependency stub.

---

### Task 1: Bound the establishment saga

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift`
- Test: `Tests/ReTiCANodeTests/LXMFRouterTests.swift`

**Interfaces:**
- Consumes: `LXMFDelivery.maxAttempts` (the existing ceiling, already used at `:304`); `Action.Delegate.deliveryFailed(messageHash:)` (`:90`).
- Produces: `State.establishAttempts: [Data: Int]`. Task 2 asserts on the `knownPaths` clearing it performs.

- [ ] **Step 1: Write the failing tests**

Read `LXMFRouterTests.swift` first — it already has `routerLinkClosedWithPendingReestablishes` (`:565-588`) and `routerDirectDeliveryBoundedWhenLinkNeverReturns` (`:592`), which pin the current behaviour. Reuse their store setup and follow their naming.

```swift
/// A queued direct message to a peer whose link never establishes gives up after
/// maxAttempts instead of re-establishing forever. Before this change the establish
/// cycle (linkClosed -> hasQueued -> establish -> requestLink -> openLink -> linkFailed ->
/// linkClosed) had no attempt counter at all — `pendingDeliveries.attempts` bounds only the
/// retryDue timer path, and a QUEUED message is never armed with a retry timer.
@Test @MainActor func routerQueuedDirectSendStopsEstablishingAfterMaxAttempts() async {
    // Seed knownPaths so establish() takes the requestLink branch.
    // .send(.direct) -> assert ONE .requestLink.
    // Then drive .linkClosed repeatedly. Assert:
    //   - exactly maxAttempts .requestLink delegates in total (count them; do not eyeball),
    //   - then .deliveryFailed(messageHash:) for the queued message,
    //   - and NO further .requestLink after that.
    // Count via a LockIsolated capture rather than sequential receives, so the assertion is
    // about the TOTAL and cannot be satisfied by a prefix.
}

/// A successful establishment resets the counter — a peer that flaps and recovers gets a
/// full budget again rather than inheriting a nearly-exhausted one.
@Test @MainActor func routerEstablishAttemptsResetOnLinkEstablished() async {
    // Drive a few linkClosed cycles (fewer than maxAttempts), then .linkEstablished.
    // Then drive linkClosed cycles again and assert the full budget is available —
    // i.e. deliveryFailed does not arrive earlier than a fresh maxAttempts would allow.
}

/// Learning a path also resets the counter: it is new information that the situation changed.
@Test @MainActor func routerEstablishAttemptsResetOnLearnedPath() async {
    // As above but reset via .learnedPath(dest) instead of .linkEstablished.
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter LXMFRouterTests`
Expected: the first test FAILS (today the establish cycle is unbounded — `.requestLink` keeps arriving and `deliveryFailed` never does). The reset tests fail to compile (`establishAttempts` does not exist).

- [ ] **Step 3: Implement**

Add to `LXMFRouter.State`, beside `directLinks`/`knownPaths`:

```swift
/// Consecutive failed link-establishment attempts per destination.
///
/// `pendingDeliveries.attempts` bounds the retry-TIMER saga; a message sitting in
/// `outboundQueue` is not armed with a timer until `linkEstablished` drains it, so without
/// this counter `linkClosed -> establish -> requestLink -> linkFailed -> linkClosed` recurs
/// forever. Reset whenever the situation genuinely changes: a link established, or a path
/// learned.
public var establishAttempts: [Data: Int] = [:]
```

In `establish` (`:113-120`), count and enforce the ceiling. Keep the existing `knownPaths` branch shape:

```swift
func establish(_ state: inout State, _ dest: Data) -> Effect<Action> {
    if state.knownPaths.contains(dest) {
        let attempts = (state.establishAttempts[dest] ?? 0) + 1
        if attempts > LXMFDelivery.maxAttempts {
            // Give up on this destination: fail everything queued for it, and forget the
            // path — our belief that we know a usable route has been empirically falsified,
            // so the NEXT send should request a fresh one rather than retry links.
            state.establishAttempts[dest] = nil
            state.knownPaths.remove(dest)
            state.directLinks[dest] = nil
            let queued = state.outboundQueue[dest] ?? []
            let propQueued = state.propagationQueue[dest] ?? []
            state.outboundQueue[dest] = nil
            state.propagationQueue[dest] = nil
            var effects: [Effect<Action>] = queued.map {
                .send(.delegate(.deliveryFailed(messageHash: $0.hash)))
            }
            effects += propQueued.map {
                .send(.delegate(.deliveryFailed(messageHash: $0.messageHash)))
            }
            return effects.isEmpty ? .none : .merge(effects)
        }
        state.establishAttempts[dest] = attempts
        state.directLinks[dest] = .establishing
        return .send(.delegate(.requestLink(destinationHash: dest)))
    }
    state.directLinks[dest] = .awaitingPath
    return .send(.delegate(.requestPath(destinationHash: dest)))
}
```

Reset at the two points where the situation genuinely changed:
- `.linkEstablished` (`:226`): `state.establishAttempts[dest] = nil` — put it beside `state.directLinks[dest] = .active(...)`.
- `.learnedPath` (`:279`): `state.establishAttempts[dest] = nil` beside `state.knownPaths.insert(dest)`.

Adapt field names to the real `outboundQueue` / `propagationQueue` element types — read them rather than assuming `.hash` / `.messageHash` are right.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter LXMFRouterTests`
Expected: all three pass, and the pre-existing `routerLinkClosedWithPendingReestablishes` / `routerDirectDeliveryBoundedWhenLinkNeverReturns` still pass. **If either now fails, STOP and report** — they pin the behaviour this changes, and whether their expectations are still right is the controller's call.

- [ ] **Step 5: Full suite**

Run: `swift test`
Expected: 743/743 (740 + 3).

- [ ] **Step 6: Mutation verification (run SEPARATELY — all three target overlapping tests)**

1. Remove the ceiling check (always `requestLink`) → `routerQueuedDirectSendStopsEstablishingAfterMaxAttempts` fails: no `deliveryFailed`, unbounded `requestLink`.
2. Remove the `.linkEstablished` reset → `routerEstablishAttemptsResetOnLinkEstablished` fails.
3. Remove the `.learnedPath` reset → `routerEstablishAttemptsResetOnLearnedPath` fails.
Report each verbatim. Revert; green.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/bound-task1-msg.txt` (subject `fix: bound the link-establishment saga so a queued send cannot retry forever`), then:

```bash
git add Sources/ReTiCANode/LXMFRouter.swift Tests/ReTiCANodeTests/LXMFRouterTests.swift
git commit -F /tmp/ReTiCA/bound-task1-msg.txt
```

---

### Task 2: Prove the recovery — the next send requests a path

Task 1 clears `knownPaths[dest]` at the ceiling. This task proves that turns into the behaviour the reverted slice wanted: the *next* send asks for a path rather than another link.

**Files:**
- Test: `Tests/ReTiCANodeTests/LXMFRouterTests.swift`

**Interfaces:**
- Consumes: Task 1's ceiling behaviour.
- Produces: nothing.

- [ ] **Step 1: Write the failing test**

```swift
/// After giving up on link establishment, the destination is no longer treated as a known
/// path — so the NEXT send requests a path instead of retrying links. This is the recovery
/// the reverted openLink fast-fail slice was aiming at, reached without threading a reason
/// through the delegate surface: a path request refreshes `learned` with the live interface
/// (Transport.swift:486-495 builds a FRESH announce for a locally-owned destination, so
/// shouldReplace accepts it), after which a link can be established normally.
@Test @MainActor func routerRequestsPathOnTheNextSendAfterGivingUpOnLinks() async {
    // Exhaust the budget as in Task 1 (assert deliveryFailed arrives).
    // Then .send(.direct) a NEW message to the same destination.
    // Assert .requestPath(destinationHash:) is emitted, NOT .requestLink.
    // ABSENCE HALF: make that .send the LAST store.send, or capture delegates in a
    // LockIsolated and assert no .requestLink appears after the give-up point.
}
```

- [ ] **Step 2: Run to verify it fails against a mutation, not just passes**

With Task 1 merged this test is expected to PASS immediately. **That is not evidence.** Before proceeding, temporarily remove the `state.knownPaths.remove(dest)` line from Task 1's ceiling branch and confirm this test FAILS (it should emit `requestLink` again). Restore. Report that disproof verbatim — it is the point of the step.

- [ ] **Step 3: Full suite**

Run: `swift test`
Expected: 744/744.

- [ ] **Step 4: Commit**

Write `/tmp/ReTiCA/bound-task2-msg.txt` (subject `test: after giving up on links, the next send requests a path`), then:

```bash
git add Tests/ReTiCANodeTests/LXMFRouterTests.swift
git commit -F /tmp/ReTiCA/bound-task2-msg.txt
```

---

## Final verification (after Task 2)

- [ ] `swift test` — full suite green; report the exact count.
- [ ] `grep -n "establishAttempts" Sources/ReTiCANode/LXMFRouter.swift` — the declaration, the increment/ceiling in `establish`, and the resets.

  **Superseded during execution.** This plan originally specified resets at BOTH
  `.linkEstablished` and `.learnedPath`. Review finding I-4 showed the `.learnedPath` reset
  was unconditional, letting a periodically re-announcing peer refresh the budget forever —
  re-opening the very loop this slice closes. It was first gated on `.inserted`, then removed
  entirely once that gate proved to be dead code (invariant: `establishAttempts[dest]` is
  non-nil only for destinations already in `knownPaths`, so an `.inserted` insert always
  finds a nil budget). Correct final shape: **one** reset, at `.linkEstablished`, plus the
  nil-out inside the ceiling branch.
- [ ] Confirm by reading that `pendingDeliveries.attempts` and the `retryDue` saga are UNCHANGED — this slice adds a second, separate counter for a different saga and must not disturb the first.
- [ ] Confirm `knownPaths` now has exactly one insert (`.learnedPath`) and one remove (the ceiling branch).
- [ ] `git log --format='%(trailers:key=Claude-Session)' -2` — both task commits' trailers parse.
