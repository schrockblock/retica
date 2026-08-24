# F5.2 — a stale router idle timer tears down a re-established link

**Written:** 2026-08-23. **Repo:** ReTiCA (`/Users/ell/development/ios/pods/ReTiCA`). Target: `main`.
**Layer:** `ReTiCANode` (`LXMFRouter`).

## Goal

Close backlog item **F5.2**: `LXMFRouter`'s per-destination idle timer (`CancelID.idle(dest)`) is
armed but never cancelled on close, and `.linkEstablished` re-arms it only when it drained a queue. So
when a link closes and is re-established for a still-pending delivery (message in `pendingDeliveries`,
not the queue), the old link's timer survives and fires on its original deadline — and `.idleDeadline`'s
`.active` guard matches the *new* link on that destination, tearing down a legitimate link that just
established. Reachable in normal operation, no attacker. The PN-sync branch has the identical shape.

## Root cause

- The idle timer is `idleTimer(dest)` (`LXMFRouter.swift:206-211`): sleeps
  `LXMFDelivery.linkMaxInactivitySeconds`, then `.send(.idleDeadline(destinationHash: dest))`,
  `.cancellable(id: CancelID.idle(dest), cancelInFlight: true)`. `CancelID.idle(dest)` is
  per-destination (`:14`).
- It is armed at three sites: `.send` direct-active (`:389`), `.sendViaPropagation` (`:415, :421`), and
  the `.linkEstablished` drain — but there only `if !queued.isEmpty || !propQueued.isEmpty` (`:484`).
  `.retryDue` deliberately does not re-arm.
- `CancelID.idle` is **never cancelled** anywhere (grep: it appears once, at the arming site). `closed()`
  (`:285-338`) reaps `directLinks`/`linkResourceInFlight` via `clearDirectLink` but does not cancel the
  idle timer, and re-establishes (`establish(&state, dest)`) when the dest still has pending
  deliveries, queued work, or a pending PN sync.
- `.idleDeadline` (`:596-599`): `guard case .active = state.directLinks[dest] else { return .none };
  clearDirectLink(&state, dest); return .send(.delegate(.closeLink(destinationHash: dest)))`.

The bug: send arms timer A for link A; link A closes; `closed()` re-establishes because the message is
still in `pendingDeliveries` (it was sent, not queued); `.linkEstablished` binds a new link B but does
**not** arm a fresh timer (both queues empty), so timer A is neither cancelled nor superseded; timer A
fires at its original deadline → `.idleDeadline(dest)` → the `.active` guard matches `.active(B)` →
link B is torn down prematurely. PN-sync: a PN link re-established for a pending sync (no queued sends)
is closed by a stale timer from a prior PN propagation send.

No reference concern: this is ReTiCA's own router-side link/timer state, not a Reticulum wire behavior.

## Design

Library-side only, in `LXMFRouter`. No wire-format change. Two changes that together fix both halves —
the premature close and the flip-side "re-established link never idle-closes" gap — for the direct and
PN-sync shapes alike.

### 1. Always arm the idle timer at `.linkEstablished`

Drop the `if !queued.isEmpty || !propQueued.isEmpty` condition (`:484`): every established link arms
`idleTimer(dest, linkID)` (see #2 for the added `linkID`). Two effects:
- The new arm's `cancelInFlight: true` on `CancelID.idle(dest)` **cancels the stale timer** from the
  prior link on that dest, so it cannot fire against the new link.
- Every re-established link — including retry-re-established and PN-sync links, which get no timer today
  — now gets its own idle teardown, closing the "link stays open forever" gap.

If the stale timer fires in the brief close→re-establish window (before `.linkEstablished`),
`directLinks[dest]` is `nil` (cleared by `closed()`), so the deadline handler no-ops.

### 2. linkID-stamp the idle deadline (robustness / self-evident correctness)

Carry the linkID the timer was armed for, so the handler closes only the link it was armed for:
- `idleTimer(_ dest: Data, _ linkID: Data)` → `.send(.idleDeadline(destinationHash: dest, linkID: linkID))`.
- `Action.idleDeadline(destinationHash: Data)` → `.idleDeadline(destinationHash: Data, linkID: Data)`.
- Handler: `guard case let .active(current) = state.directLinks[dest], current == linkID else
  { return .none }; clearDirectLink(&state, dest); return .send(.delegate(.closeLink(destinationHash: dest)))`.
- All three arming sites already have the linkID in scope (`.send`/`.sendViaPropagation` via
  `if case let .active(linkID)`, `.linkEstablished` via its `linkID` parameter), so each passes it.

A stale timer for an old linkID can then **never** close a link it wasn't armed for — the correctness
is local to the handler, not dependent on the non-local "every `.active` transition arms a timer"
invariant, and future-proof against any new path that sets `.active` without arming. (Same
generation-stamp pattern that fixed the NWConnection reconnect bug.)

## Data flow (after the fix)

```
send/linkEstablished on dest → directLinks[dest] = .active(L) ; arm idleTimer(dest, L)
                               (cancelInFlight kills any prior CancelID.idle(dest) timer)

link closes → closed(): clearDirectLink(dest) (directLinks[dest]=nil), maybe re-establish
   stale timer for old link fires meanwhile → .idleDeadline(dest, Lold):
      directLinks[dest] is nil (in the gap) OR .active(Lnew) with Lnew != Lold → guard fails → no-op

.linkEstablished(dest, Lnew) → always arm idleTimer(dest, Lnew) → cancels any lingering timer;
   Lnew's own deadline governs and closes Lnew only when genuinely idle.
```

## Edge cases

- **Stale timer fires during the close→re-establish gap:** `directLinks[dest]` is `nil` → guard
  fails → no-op (covered by both the `.active` guard and the linkID stamp).
- **Reused destination, different linkID:** the stamp makes the old timer no-op even if it somehow
  outlived `cancelInFlight`.
- **Retry saga on the re-established link:** `.retryDue` still does not re-arm (a saga is far shorter
  than `linkMaxInactivitySeconds`, and the establish/`.linkEstablished` arm already spans it).
- **PN-sync link:** now gets an idle timer via the unconditional `.linkEstablished` arm, so a
  sync-only PN link idle-closes instead of lingering, and a stale prior timer cannot close it.

## Testing

Three-step verification (green → mutate to red → revert). Tests at the `LXMFRouter` level in
`Tests/ReTiCANodeTests/LXMFRouterTests.swift`; `TestClock`; model on `routerTearsDownIdleLink`.

1. **Stamp — a stale deadline cannot close a newer link.** Seed `directLinks[dest] = .active(newLinkID)`
   and send `.idleDeadline(destinationHash: dest, linkID: oldLinkID)` directly. Assert the link is not
   closed (still `.active(newLinkID)`, no `.closeLink`). Mutation: drop the `current == linkID` clause →
   the stale deadline closes the current link → fails.
2. **Always-arm — a re-established link gets its own idle timer.** Drive `.linkEstablished(dest, linkID)`
   with an empty outbound queue, advance the clock by `LXMFDelivery.linkMaxInactivitySeconds`, and assert
   `.closeLink(dest)` fires. Mutation: restore the `if !queued.isEmpty || !propQueued.isEmpty` condition
   → no timer armed → nothing fires → the `receive` times out → fails.
3. **End-to-end regression (the F5.2 bug).** Send direct → link A established (arms A's timer), message
   left pending → close link A → the router re-establishes → `.linkEstablished(dest, B)`. Advance the
   clock past link A's original deadline: assert link B is still `.active(B)` (the stale A timer neither
   fired against B nor was left to). Then advance to B's own deadline and assert B closes cleanly.
   Passes only with both fixes.

**Non-regression:** `routerTearsDownIdleLink`, `routerActivityRestartsIdleTimer`, and the F7
`idleTeardownReapsLinkResourceInFlight` stay green. Two ripples the implementer must handle: (a)
`.idleDeadline` gains a `linkID` payload — update the helper, handler, and any test referencing that
action (existing idle tests match on `.closeLink`, so most are unaffected); (b) always-arming means an
empty-queue `.linkEstablished` now leaves an idle timer in flight, so any existing test that flips
`exhaustivity = .on` after such a call must drop the trailing `.on`.

## Out of scope

- The rest of the F5 grab-bag (`sendFailed` design change, `sendViaPropagation` silent drop,
  `.handshakeRejected` label coverage, the app-side double-saga) — separate items.
- Any change to `.retryDue`'s deliberate non-re-arm.
- Any wire-format change.
