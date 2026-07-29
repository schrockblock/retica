# LXMF-4c-3a: Link-CLOSED Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a direct link closes, the router recovers in-flight direct messages by re-establishing a fresh link and resending on it — instead of retrying forever against a dead link id.

**Architecture:** Extend the `LXMFRouter` reducer (ReTiCANode). `ResendInfo.direct` stores the destination hash (not a stale link id); `.retryDue` for a direct pending looks up the *live* link (active → resend on it; down → wait, still counting the attempt); `.linkClosed` clears the dead link and re-establishes when there is recoverable work. A shared `establish(&state, dest)` helper (DRY with `.send`) sets the link status and emits `requestLink`/`requestPath` per `knownPaths`. Event/timer-driven; no new constant.

**Tech Stack:** Swift, The Composable Architecture (TCA), swift-testing (`@Test`), SwiftPM.

## Global Constraints

- Commit directly to `main`; no feature branch, no finishing-a-development-branch merge dance.
- No compound shell commands: no `|` chains, `&&`, `||`, `;`, `$(...)`-feeding, `xargs`, or inlining scripts into interpreters. One command per Bash call. A single `>` redirect is allowed. Never use echo/printf/heredoc to WRITE source files (use Write/Edit).
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test. The four mutations below touch different code (two mutate `.linkClosed` oppositely) — apply them ONE AT A TIME, each mapped to the test(s) it should break.
- Prefer non-exhaustive TCA tests (`store.exhaustivity = .off`) asserting outcomes; assert absence of a stray delegate by flipping `exhaustivity = .on` last (only where no timer is left in flight).
- Ed25519 hedged/randomized → signatures validated, never byte-compared (this task adds none; confirm none creep in).
- Commit trailers (exact); the `;` means author the message with the Write tool to `/tmp/ReTiCA/` and `git commit -F`, never `-m`:
  - `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`

---

### Task 1: Link-CLOSED recovery in `LXMFRouter`

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` (`ResendInfo.direct` line 40; add `establish` helper near lines 71-79; `.send` direct-active creation line 116; `.send` direct-no-link block lines 121-130; `.linkEstablished` drain creation line 140; `.linkClosed` lines 146-148; `.retryDue` direct case lines 181-183)
- Modify (add tests): `Tests/ReTiCANodeTests/LXMFRouterTests.swift` (append a new MARK section)

**Interfaces:**
- Consumes (existing): `LXMFRouter.State` (`directLinks: [Data: LinkStatus]`, `pendingDeliveries: [Data: PendingDelivery]`, `outboundQueue: [Data: [LXMessage]]`, `knownPaths: Set<Data>`), `LinkStatus` (`.awaitingPath`/`.establishing`/`.active(linkID:)`), `PendingDelivery.resend: ResendInfo`, `LXMFDelivery.retryWaitSeconds`/`.maxAttempts`, the `makeMessage(source:recipientIdentityHash:content:)` and `LXMessage.deliveryHash(identityHash:)` test helpers.
- Produces: `ResendInfo.direct(destinationHash: Data, data: Data, asResource: Bool)` (was `linkID: Data`). No new public API otherwise — behavior change.

- [ ] **Step 1: Write the headline failing test (recovery resends on the new link)**

Append to `Tests/ReTiCANodeTests/LXMFRouterTests.swift` a new section (after the LXMF-4c-2 opportunistic tests):

```swift
// MARK: - LXMF-4c-3a link-CLOSED recovery

@Test @MainActor func routerRecoversPendingOnNewLinkAfterClose() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let oldLinkID = Data(repeating: 0x01, count: 16)
    let newLinkID = Data(repeating: 0x02, count: 16)
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.directLinks[msg.destinationHash] = .active(linkID: oldLinkID)
    initial.knownPaths.insert(msg.destinationHash)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.sendDirect) = $0 { return true }; return false }   // sent on old link
    await store.send(.linkClosed(destinationHash: msg.destinationHash))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }   // re-establish
    await store.send(.linkEstablished(destinationHash: msg.destinationHash, linkID: newLinkID))
    // The pending message resends on its retry tick — over the NEW link, never the dead one.
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { action in
        if case let .delegate(.sendDirect(lid, data, _)) = action {
            #expect(lid == newLinkID); #expect(data == msg.packed); return true
        }
        return false
    }
    await store.send(.delivered(messageHash: msg.hash))
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    store.exhaustivity = .on
}
```

- [ ] **Step 2: Run it — verify it fails**

Run: `swift test --filter LXMFRouterTests.routerRecoversPendingOnNewLinkAfterClose`
Expected: FAIL — today `.linkClosed` emits no `requestLink` (the `receive { requestLink }` times out).

- [ ] **Step 3: Change `ResendInfo.direct` to carry the destination hash**

In `Sources/ReTiCANode/LXMFRouter.swift`, replace the `ResendInfo.direct` case (line 40):

```swift
        case direct(linkID: Data, data: Data, asResource: Bool)
```

with:

```swift
        case direct(destinationHash: Data, data: Data, asResource: Bool)
```

- [ ] **Step 4: Add the shared `establish` helper**

In the `Reduce` closure, after the `arm` helper (line 79, before `switch action`), add:

```swift
            func establish(_ state: inout State, _ dest: Data) -> Effect<Action> {
                if state.knownPaths.contains(dest) {
                    state.directLinks[dest] = .establishing
                    return .send(.delegate(.requestLink(destinationHash: dest)))
                }
                state.directLinks[dest] = .awaitingPath
                return .send(.delegate(.requestPath(destinationHash: dest)))
            }
```

- [ ] **Step 5: Update the two `.direct` creation sites to store `dest`**

At `.send` direct-active (line 116), replace:

```swift
                        arm(&state, message.hash, .direct(linkID: linkID, data: message.packed, asResource: asResource))
```

with:

```swift
                        arm(&state, message.hash, .direct(destinationHash: dest, data: message.packed, asResource: asResource))
```

At the `.linkEstablished` drain (line 140), replace:

```swift
                    arm(&state, m.hash, .direct(linkID: linkID, data: m.packed, asResource: asResource))
```

with:

```swift
                    arm(&state, m.hash, .direct(destinationHash: dest, data: m.packed, asResource: asResource))
```

(Both keep their existing `sendDirect(linkID: …)` delegate lines unchanged — the initial send still uses the live `linkID` in scope.)

- [ ] **Step 6: Use the `establish` helper in `.send` direct-no-link**

Replace the `.send` direct no-active-link block (lines 121-130):

```swift
                    state.outboundQueue[dest, default: []].append(message)
                    if state.directLinks[dest] == nil {
                        if state.knownPaths.contains(dest) {
                            state.directLinks[dest] = .establishing
                            return .send(.delegate(.requestLink(destinationHash: dest)))
                        }
                        state.directLinks[dest] = .awaitingPath
                        return .send(.delegate(.requestPath(destinationHash: dest)))
                    }
                    return .none   // a link/path request is already in flight
```

with:

```swift
                    state.outboundQueue[dest, default: []].append(message)
                    if state.directLinks[dest] == nil {
                        return establish(&state, dest)
                    }
                    return .none   // a link/path request is already in flight
```

- [ ] **Step 7: Re-establish on `.linkClosed` when there is recoverable work**

Replace the `.linkClosed` case (lines 146-148):

```swift
            case let .linkClosed(dest):
                state.directLinks[dest] = nil
                return .none
```

with:

```swift
            case let .linkClosed(dest):
                state.directLinks[dest] = nil
                let hasPending = state.pendingDeliveries.values.contains {
                    if case let .direct(d, _, _) = $0.resend { return d == dest }
                    return false
                }
                let hasQueued = !(state.outboundQueue[dest]?.isEmpty ?? true)
                if hasPending || hasQueued {
                    return establish(&state, dest)
                }
                return .none
```

- [ ] **Step 8: Make `.retryDue` direct resend to the live link (or wait)**

Replace the `.direct` case inside `.retryDue` (lines 181-183):

```swift
                case let .direct(linkID, data, asResource):
                    return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: asResource))),
                                  retryTimer(hash, LXMFDelivery.retryWaitSeconds))
```

with:

```swift
                case let .direct(destinationHash, data, asResource):
                    if case let .active(linkID) = state.directLinks[destinationHash] {
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: asResource))),
                                      retryTimer(hash, LXMFDelivery.retryWaitSeconds))
                    }
                    // Link is down or re-establishing: no live link to send on. Wait and re-check; the
                    // attempt was already counted, so the saga stays bounded by maxAttempts.
                    return retryTimer(hash, LXMFDelivery.retryWaitSeconds)
```

- [ ] **Step 9: Run the headline test — verify it passes**

Run: `swift test --filter LXMFRouterTests.routerRecoversPendingOnNewLinkAfterClose`
Expected: PASS.

- [ ] **Step 10: Add the 3 remaining tests**

Append to the same `// MARK: - LXMF-4c-3a link-CLOSED recovery` section:

```swift
/// Closing a link that has an in-flight (pending) direct message re-establishes and retains the pending.
@Test @MainActor func routerLinkClosedWithPendingReestablishes() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let oldLinkID = Data(repeating: 0x01, count: 16)
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.directLinks[msg.destinationHash] = .active(linkID: oldLinkID)
    initial.knownPaths.insert(msg.destinationHash)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.sendDirect) = $0 { return true }; return false }
    #expect(store.state.pendingDeliveries[msg.hash]?.attempts == 1)
    await store.send(.linkClosed(destinationHash: msg.destinationHash))
    await store.receive { action in
        if case let .delegate(.requestLink(dest)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    #expect(store.state.directLinks[msg.destinationHash] == .establishing)
    #expect(store.state.pendingDeliveries[msg.hash] != nil)   // pending retained across the close
    await store.send(.delivered(messageHash: msg.hash))       // cancel the pending timer before teardown
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    store.exhaustivity = .on
}

/// If the link never returns, a pending direct delivery ticks (link down → no send) until the attempt
/// cap trips and it fails — bounded recovery.
@Test @MainActor func routerDirectDeliveryBoundedWhenLinkNeverReturns() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let oldLinkID = Data(repeating: 0x01, count: 16)
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.directLinks[msg.destinationHash] = .active(linkID: oldLinkID)
    initial.knownPaths.insert(msg.destinationHash)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.sendDirect) = $0 { return true }; return false }
    await store.send(.linkClosed(destinationHash: msg.destinationHash))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    // Link never re-establishes; each retry tick finds no active link (no send) but still counts.
    for _ in 0..<(LXMFDelivery.maxAttempts - 1) {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    }
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { action in
        if case let .delegate(.deliveryFailed(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
    #expect(store.state.pendingDeliveries[msg.hash] == nil)
}

/// Closing a link with nothing pending/queued clears it and does NOT re-establish.
@Test @MainActor func routerLinkClosedWithNothingPendingClears() async {
    let dest = LXMessage.deliveryHash(identityHash: Identity().hash)
    var initial = LXMFRouter.State()
    initial.directLinks[dest] = .active(linkID: Data(repeating: 0x07, count: 16))
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.linkClosed(destinationHash: dest))
    #expect(store.state.directLinks[dest] == nil)   // cleared, no re-establish
    store.exhaustivity = .on   // a stray requestLink/requestPath would fail teardown
}
```

- [ ] **Step 11: Run the full router test file — verify all pass**

Run: `swift test --filter LXMFRouterTests`
Expected: PASS — all existing router tests plus the 4 new ones.

- [ ] **Step 12: Mutation verification (one mutation at a time)**

Apply each individually in `Sources/ReTiCANode/LXMFRouter.swift`, run `swift test --filter LXMFRouterTests`, confirm the named test(s) fail, then revert before the next.

1. **`.linkClosed` never re-establishes** — replace the `if hasPending || hasQueued { return establish(&state, dest) }` block with `return .none` (keep the `directLinks[dest] = nil`).
   → `routerRecoversPendingOnNewLinkAfterClose` FAILS (no `requestLink` after close); `routerLinkClosedWithPendingReestablishes` FAILS (no `requestLink`); `routerDirectDeliveryBoundedWhenLinkNeverReturns` FAILS (no `requestLink`).
2. **`.retryDue` direct never resends on an active link** — in the `.direct` case, delete the `if case let .active(linkID) = …` resend branch so it always falls through to `return retryTimer(hash, LXMFDelivery.retryWaitSeconds)`.
   → `routerRecoversPendingOnNewLinkAfterClose` FAILS (no `sendDirect(newLinkID)` after re-establish).
3. **`.retryDue` direct down-branch drops the timer** — change the final `return retryTimer(hash, LXMFDelivery.retryWaitSeconds)` in the `.direct` case to `return .none`.
   → `routerDirectDeliveryBoundedWhenLinkNeverReturns` FAILS (no further retries fire, so `deliveryFailed` never arrives and the receive times out).
4. **`.linkClosed` always re-establishes** — change `.linkClosed` to unconditionally `return establish(&state, dest)` (ignore `hasPending`/`hasQueued`).
   → `routerLinkClosedWithNothingPendingClears` FAILS (a stray `requestLink` is caught by the `.on` teardown).

After each: revert, run `swift test --filter LXMFRouterTests`, expect PASS before the next.

- [ ] **Step 13: Full test gate**

Run: `swift test`
Expected: PASS. The 4c-2-opp baseline was 422 passed / 1 pre-existing live-node skip / 0 fail; this slice adds 4 router tests → 426 passed. On a signal-11/signal-10 build flake, run `swift package clean` (single command) and re-run.

- [ ] **Step 14: Commit**

Write the message to `/tmp/ReTiCA/commit-msg-4c3a.txt` with the Write tool (body below), then:

```bash
git add Sources/ReTiCANode/LXMFRouter.swift Tests/ReTiCANodeTests/LXMFRouterTests.swift
```

```bash
git commit -F /tmp/ReTiCA/commit-msg-4c3a.txt
```

Commit message body:

```
feat: LXMF-4c-3a — link-CLOSED recovery

A direct link closing no longer strands in-flight messages. ResendInfo
.direct stores destinationHash (not a stale linkID); .retryDue resends
to the LIVE link when active, or waits (still counting the attempt, so
it stays bounded by maxAttempts) while the link is down. .linkClosed
clears the dead link and re-establishes when there is pending/queued
work, via a shared establish() helper (DRY with .send). .linkEstablished
unchanged. 4 new tests.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Self-Review

**Spec coverage:**
- Spec "Type change" (`ResendInfo.direct` → `destinationHash`) → Step 3 (+ creation sites Step 5). ✓
- Spec "Shared establish helper" → Step 4 (+ used in Steps 6, 7). ✓
- Spec "`.retryDue` direct branch" (live link → resend; down → wait) → Step 8. ✓
- Spec "`.linkClosed`" (clear + re-establish when recoverable work) → Step 7. ✓
- Spec "`.linkEstablished` unchanged" → not modified (drain creation site's resend payload changes to `dest` in Step 5, but the drain logic is untouched). ✓
- Spec test 1 (close with in-flight re-establishes) → `routerLinkClosedWithPendingReestablishes`, Step 10. ✓
- Spec test 2 (recovery headline) → `routerRecoversPendingOnNewLinkAfterClose`, Step 1. ✓
- Spec test 4 (bounded give-up) → `routerDirectDeliveryBoundedWhenLinkNeverReturns`, Step 10. ✓
- Spec test 5 (nothing pending clears) → `routerLinkClosedWithNothingPendingClears`, Step 10. ✓
- Spec test 3 (retry-while-down waits): its intent — the down-branch keeps ticking without sending, bounded by maxAttempts — is covered by `routerDirectDeliveryBoundedWhenLinkNeverReturns` (mutation 3 proves the down-branch re-arms; the terminal `deliveryFailed` proves no premature failure). A standalone "no send while down" assertion is not added because, with `ResendInfo.direct` no longer holding a linkID, the down state has no link id to send to — a stray send is not reachable by a natural mutation. Noted, not a gap.

**Placeholder scan:** none — every code step shows exact code.

**Type consistency:** `ResendInfo.direct(destinationHash: Data, data: Data, asResource: Bool)` (Step 3) is matched at both creation sites (Step 5: `.direct(destinationHash: dest, …)`) and both destructuring sites (`.linkClosed` `if case let .direct(d, _, _)` Step 7; `.retryDue` `case let .direct(destinationHash, data, asResource)` Step 8). `establish(_ state: inout State, _ dest: Data) -> Effect<Action>` (Step 4) is called identically in Steps 6 and 7. `LinkStatus.establishing`/`.active(linkID:)` and `LXMFDelivery.retryWaitSeconds`/`.maxAttempts` used consistently.
