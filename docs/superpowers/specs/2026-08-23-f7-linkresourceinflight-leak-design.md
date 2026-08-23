# F7 — `linkResourceInFlight` leaks on idle teardown

**Written:** 2026-08-23. **Repo:** ReTiCA (`/Users/ell/development/ios/pods/ReTiCA`). Target: `main`.
**Layer:** `ReTiCANode` (`LXMFRouter`).

## Goal

Close backlog item **F7**: `LXMFRouter.linkResourceInFlight` (a `[linkID: messageHash]` map) leaks one
entry permanently every time the idle timer tears down a direct link that had a Resource in flight. It
needs no attacker — our own `.idleDeadline` produces it — and it is genuinely unbounded over the life
of a node. Fix by reaping the in-flight entry whenever a `directLink` is cleared, enforced through a
single helper so no teardown path can bypass it.

## Root cause

The leak is an ordering bug between two handlers in `LXMFRouter`:

- `.idleDeadline` (`LXMFRouter.swift:590-593`) does `guard case .active = state.directLinks[dest]`
  (matching `.active` but **discarding the linkID**), sets `state.directLinks[dest] = nil`, and emits
  `.delegate(.closeLink(destinationHash: dest))`.
- The only clearer of `linkResourceInFlight` on the close path is `closed()`
  (`LXMFRouter.swift:276-280`): `if case let .active(linkID) = state.directLinks[dest] {
  state.linkResourceInFlight[linkID] = nil }; state.directLinks[dest] = nil`. It runs when the
  resulting `.linkClosed` arrives — but by then `.idleDeadline` has already nil'd `directLinks[dest]`,
  so the `if case let .active(linkID)` cannot match and the entry is never reaped.

So any link torn down by the idle timer with a Resource still in flight strands its
`linkResourceInFlight[linkID]` entry forever.

**Scope, verified by an exhaustive lifecycle grep:** `linkResourceInFlight` is written at six
resource-send sites (`:379, :412, :462, :473, :566, :581`), read at `:543`, and cleared at `:278`
(`closed()`) and `:544` (`.resourceDeliveredOnLink`). The only `directLinks[dest] = nil` sites are
`closed()` (`:280`, reaps correctly), `.idleDeadline` (`:592`, the leak), and `giveUp` (`:228`).
`giveUp` is unreachable with an `.active` link — its two callers hold `.establishing` (establish() over
budget) or `.awaitingPath` (`.pathRequestDeadline`), never `.active` — so it cannot leak today.
**`.idleDeadline` is the only leaking site.**

No reference concern: `linkResourceInFlight` is ReTiCA's own router-side delivery-tracking state, not a
Reticulum wire behavior.

## Design

Library-side only, in `LXMFRouter` (`ReTiCANode`). No wire-format change.

Introduce a single helper next to the router's other local reducer functions (`closed`, `giveUp`,
`establish`), and route every `directLink` teardown through it:

```swift
func clearDirectLink(_ state: inout State, _ dest: Data) {
    if case let .active(linkID) = state.directLinks[dest] {
        state.linkResourceInFlight[linkID] = nil
    }
    state.directLinks[dest] = nil
}
```

Call sites:
- **`closed()` (`:277-280`):** replace the inline `if case let .active(linkID) { … }` +
  `state.directLinks[dest] = nil` with `clearDirectLink(&state, dest)`. Behavior is identical — this is
  the dedup that makes the helper the single source of the invariant.
- **`.idleDeadline` (`:590-593`):** keep the `guard case .active = state.directLinks[dest] else
  { return .none }` (so `.closeLink` is emitted only when there was an active link), then call
  `clearDirectLink(&state, dest)` before returning `.send(.delegate(.closeLink(destinationHash: dest)))`.
  This closes the leak: the linkID is reaped even though `.idleDeadline` clears the entry before the
  close path runs.
- **`giveUp` (`:228`):** replace `state.directLinks[dest] = nil` with `clearDirectLink(&state, dest)`.
  Harmless today (no `.active` link reaches it), correct if that ever changes.

Result: "clearing a `directLink` always reaps its in-flight Resource entry" is enforced in one place a
future teardown path cannot bypass.

## Data flow (after the fix)

```
.idleDeadline(dest):
   guard directLinks[dest] is .active else return .none
   clearDirectLink(&state, dest)        // reaps linkResourceInFlight[linkID], then nils directLinks[dest]
   → emit .closeLink(dest)
   (.linkClosed later → closed() → clearDirectLink again: idempotent no-op, entry already gone)

closed(dest) / giveUp(dest):  clearDirectLink(&state, dest)   // same invariant, one code path
```

## Edge cases

- **`.linkClosed` arriving after `.idleDeadline`:** `closed()` calls `clearDirectLink` again; both the
  linkResourceInFlight entry and `directLinks[dest]` are already gone → idempotent no-op. No double-free
  issue (dictionary assignment to nil on an absent key is a no-op).
- **A packet-sized (non-Resource) send on the link:** never writes `linkResourceInFlight`, so there is
  nothing to reap — `clearDirectLink` just nils `directLinks[dest]`, exactly as today.
- **`giveUp` with `.active`:** unreachable per the scope analysis; the helper still handles it correctly
  if reached.

## Testing

Three-step verification (green → mutate to red → revert). Tests at the `LXMFRouter` level in
`Tests/ReTiCANodeTests/LXMFRouterTests.swift`; `TestClock` for the idle timer.

1. **The leak is fixed (regression test).** Model on `routerTearsDownIdleLink` (`:1091`) but send a
   *Resource-sized* message (as in `routerConfirmsResourceDirectOnResourceDelivered`'s `bigMsg`) over
   an established direct link so `linkResourceInFlight[linkID]` is set (assert
   `== bigMsg.hash`). Advance the clock by `LXMFDelivery.linkMaxInactivitySeconds` so `.idleDeadline`
   fires and emits `.closeLink`. Assert **both** `linkResourceInFlight[linkID] == nil` and
   `directLinks[dest] == nil`. Mutation: drop the `linkResourceInFlight[linkID] = nil` line from
   `clearDirectLink` → the entry survives the idle teardown → the test fails.
2. **Non-regression for the refactor.** `closed()` now calls the same helper it already inlined, so the
   existing `.linkClosed`, `.resourceDeliveredOnLink`, and `giveUp` tests must all stay green (the full
   suite covers this). No new test needed for `closed()` — its behavior is unchanged.

## Out of scope

- Any change to the six `linkResourceInFlight` write sites or the `.resourceDeliveredOnLink` clear.
- F16 and any other backlog item.
- Any wire-format change.
