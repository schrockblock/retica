# F7 — linkResourceInFlight Idle-Teardown Leak Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `LXMFRouter.linkResourceInFlight` from leaking an entry when the idle timer tears down a direct link that had a Resource in flight.

**Architecture:** Route every `directLinks[dest]` teardown through one `clearDirectLink(&state, dest)` helper that reaps `linkResourceInFlight[linkID]` when the entry is `.active`. `.idleDeadline` (the only leaking site, which nils `directLinks` before the close path can reap) now goes through the helper, closing the leak and making the reap-on-teardown invariant impossible to bypass.

**Tech Stack:** Swift, The Composable Architecture (TCA / swift-testing). Package: ReTiCA, target `ReTiCANode` (`LXMFRouter`).

## Global Constraints

- Repo: `/Users/ell/development/ios/pods/ReTiCA`. Edits in `Sources/ReTiCANode/LXMFRouter.swift` and `Tests/ReTiCANodeTests/LXMFRouterTests.swift` only. No wire-format change. No reference/cap decision — this is ReTiCA's own router state.
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

### Task 1: Reap linkResourceInFlight on directLink teardown (clearDirectLink helper)

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` — add a local helper near `closed`/`giveUp`, and route `closed()` (`:277-280`), `.idleDeadline` (`:590-593`), and `giveUp` (`:228`) through it.
- Test: `Tests/ReTiCANodeTests/LXMFRouterTests.swift` — add one regression test.

**Interfaces:**
- Consumes (existing): `LXMFRouter.State.directLinks: [Data: LinkStatus]`, `LinkStatus.active(linkID: Data)`, `LXMFRouter.State.linkResourceInFlight: [Data: Data]`; test helper `makeMessage(source:recipientIdentityHash:content:)`; `LXMFDelivery.linkMaxInactivitySeconds`.
- Produces: a local reducer func `clearDirectLink(_ state: inout State, _ dest: Data)`.

- [ ] **Step 1: Write the failing regression test**

Add to `LXMFRouterTests.swift` (models on `routerTearsDownIdleLink` at `:1091`, but with a Resource-sized message so `linkResourceInFlight` is populated):

```swift
@Test @MainActor func idleTeardownReapsLinkResourceInFlight() async {
    // A Resource-sized message (directRepresentation == .resource) sets linkResourceInFlight on send.
    // When the idle timer tears the link down, that entry must be reaped — not leaked (F7).
    let bigMsg = makeMessage(source: Identity(), content: String(repeating: "y", count: 2000))
    #expect(bigMsg.directRepresentation == .resource)
    let linkID = Data(repeating: 0x37, count: 16)
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(bigMsg.destinationHash)     // path known → establishes directly
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.send(message: bigMsg, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    await store.send(.linkEstablished(destinationHash: bigMsg.destinationHash, linkID: linkID))
    await store.receive { action in                        // drain arms the idle timer; sets in-flight
        if case let .delegate(.sendDirect(lid, _, asResource)) = action {
            #expect(lid == linkID); #expect(asResource == true); return true
        }
        return false
    }
    #expect(store.state.linkResourceInFlight[linkID] == bigMsg.hash)

    // Resolve the delivery so its retry timer is cancelled; the idle timer and the in-flight entry
    // both remain (the Resource is still notionally in flight for eviction purposes).
    await store.send(.delivered(messageHash: bigMsg.hash))
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    #expect(store.state.linkResourceInFlight[linkID] == bigMsg.hash, "still in-flight before idle")
    #expect(store.state.directLinks[bigMsg.destinationHash] == .active(linkID: linkID))

    // Idle window elapses → the link is torn down. The in-flight entry MUST be reaped.
    await clock.advance(by: .seconds(LXMFDelivery.linkMaxInactivitySeconds))
    await store.receive { action in
        if case let .delegate(.closeLink(dest)) = action { #expect(dest == bigMsg.destinationHash); return true }
        return false
    }
    #expect(store.state.linkResourceInFlight[linkID] == nil,
            "idle teardown must reap the in-flight Resource entry — F7 leak")
    #expect(store.state.directLinks[bigMsg.destinationHash] == nil)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter idleTeardownReapsLinkResourceInFlight`
Expected: FAIL at `linkResourceInFlight[linkID] == nil` — today `.idleDeadline` nils `directLinks` without reaping the in-flight entry, so it survives.

- [ ] **Step 3: Add the `clearDirectLink` helper**

In `LXMFRouter.swift`, near the other local reducer functions (`giveUp` at `~:225`, `closed` at `~:276`), add:
```swift
            // Tear down a direct link, reaping its in-flight Resource entry. `linkResourceInFlight`
            // is keyed on the linkID carried by `.active`, so it can only be reaped BEFORE
            // `directLinks[dest]` is cleared — do both here so no teardown path can strand an entry (F7).
            func clearDirectLink(_ state: inout State, _ dest: Data) {
                if case let .active(linkID) = state.directLinks[dest] {
                    state.linkResourceInFlight[linkID] = nil
                }
                state.directLinks[dest] = nil
            }
```

- [ ] **Step 4: Route `closed()` through the helper**

In `closed()` (`:276-280`), replace the inline reap + nil:
```swift
                if case let .active(linkID) = state.directLinks[dest] {
                    state.linkResourceInFlight[linkID] = nil
                }
                state.directLinks[dest] = nil
```
with:
```swift
                clearDirectLink(&state, dest)
```
(behavior identical — this is the dedup that makes the helper the single source of the invariant; leave the rest of `closed()` unchanged.)

- [ ] **Step 5: Route `.idleDeadline` through the helper**

In `.idleDeadline` (`:590-593`), keep the `.active` guard (so `.closeLink` is emitted only when there was an active link) and call the helper before returning:
```swift
            case let .idleDeadline(dest):
                guard case .active = state.directLinks[dest] else { return .none }
                clearDirectLink(&state, dest)
                return .send(.delegate(.closeLink(destinationHash: dest)))
```

- [ ] **Step 6: Route `giveUp` through the helper**

In `giveUp` (`:228`), replace `state.directLinks[dest] = nil` with `clearDirectLink(&state, dest)` (harmless today — no `.active` link reaches `giveUp` — and correct if that ever changes).

- [ ] **Step 7: Run the test to verify it passes**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter idleTeardownReapsLinkResourceInFlight`
Expected: PASS.

- [ ] **Step 8: Mutation-verify**

In `clearDirectLink`, comment out the `state.linkResourceInFlight[linkID] = nil` line (leave the `directLinks[dest] = nil`). Run the test → FAIL (the entry survives idle teardown). Revert. Run again → PASS.

- [ ] **Step 9: Full suite + commit**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA` — all pass except the known issue. The refactor makes `closed()` behavior identical, so the existing `.linkClosed`, `.resourceDeliveredOnLink`, `giveUp`, and idle-teardown tests (`routerTearsDownIdleLink`, `routerActivityRestartsIdleTimer`, `routerConfirmsResourceDirectOnResourceDelivered`) must stay green.
Stage only the two files. Commit:
```
fix: F7 — reap linkResourceInFlight on directLink teardown

LXMFRouter.idleDeadline nil'd directLinks[dest] before the close path ran, so
closed()'s `if case let .active(linkID)` reaper could not match and
linkResourceInFlight[linkID] leaked permanently on every idle teardown of a
link with a Resource in flight — an unbounded, attacker-free leak. Route
closed(), idleDeadline, and giveUp through one clearDirectLink helper that
reaps the in-flight entry before clearing directLinks, so the invariant holds
in one place no teardown path can bypass.
```
Verify the trailer parses.

---

## Notes for the executor

- **The helper reaps BEFORE nil'ing `directLinks`** — order matters (the linkID lives in the `.active` case being cleared). Do not reorder.
- **`closed()`'s refactor must be behavior-preserving** — the helper is the exact logic it already inlined; only `closed()`'s reap+nil lines are replaced, the rest of the function is untouched.
- **Do not** touch the six `linkResourceInFlight` write sites or the `.resourceDeliveredOnLink` clear (`:544`) — they are correct.
- If `.delivered` does not cancel the retry timer or does not leave `linkResourceInFlight` set in this router's current code, adjust the test to quiet the retry saga another way (the goal is: idle timer armed + `linkResourceInFlight[linkID]` still set when the idle window elapses), and report the change.
