# LXMF Direct Delivery Confirmation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve a proven-received Resource-direct send to `deliveryConfirmed`, cancelling the retry timer instead of re-sending the whole Resource up to 5× and reporting `deliveryFailed` on a delivered message.

**Architecture:** The `linkID → messageHash` correlation lives in the decoupled `LXMFRouter` (new `linkResourceInFlight` map, recorded at the 3 Resource-send sites, resolved by a new `resourceDeliveredOnLink(linkID:)` action that reuses the existing `.delivered` path). `LXMFNode` adds two thin translations (`resourceConcluded → resourceDeliveredOnLink`, `deliveryConfirmed → node delegate`) and a `deliveryConfirmed` app delegate. `Endpoint` is unchanged.

**Tech Stack:** Swift, Point-Free Composable Architecture (TCA), Swift Testing (`@Test`/`#expect`), `swift test`.

## Global Constraints

- **Commit directly to `main`** — no feature branch, no merge dance.
- **No compound shell commands** — one command per invocation; no `&&`/`||`/`;`/`|`-chains/`xargs`/inline interpreter scripts. A single `>` redirect is allowed. Write files with the editor, not echo/heredoc.
- **Temp files** go in `/tmp/ReTiCA/`.
- **Commit trailers, verbatim**, via `git commit -F <file>` (never `-m`, the trailers contain `;`):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```
- **Three-step mutation verification** for every new/changed test: run pass → mutate production to force fail + confirm → revert + confirm pass. One mutation at a time.
- **Prefer non-exhaustive TCA tests** (`store.exhaustivity = .off`), asserting outcomes. NOTE: the `.send`-over-active-link path arms a 600s idle timer; do NOT flip `store.exhaustivity = .on` at the end of a test that has an in-flight idle timer (teardown rejects the pending effect). Assert outcomes/state instead.
- **Ed25519 is hedged/randomized** — validate signatures, never byte-compare them (deterministic hashes are fine to compare).
- **Scope:** Resource-direct confirmation ONLY. Do NOT wire packet-direct, opportunistic, or `resourceFailed`.
- If `swift test` shows a stale cross-module link error, run `swift package clean` then retry.

---

### Task 1: LXMFRouter — linkResourceInFlight correlation + resourceDeliveredOnLink

Add the `linkID → messageHash` correlation to `LXMFRouter`: record it whenever a Resource is sent on a link, resolve `resourceDeliveredOnLink(linkID)` to the existing `.delivered` path, and clear it on link close. Unit-test with no Endpoint.

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift`
- Test: `Tests/ReTiCANodeTests/LXMFRouterTests.swift` (append one test)

**Interfaces:**
- Consumes: existing `.delivered(messageHash:)` handler (LXMFRouter.swift:239-243 — clears `pendingDeliveries[hash]`, cancels `CancelID.retry(hash)`, emits `.delegate(.deliveryConfirmed(messageHash:))`); `LinkStatus.active(linkID:)`.
- Produces (for Task 2): `LXMFRouter.Action.resourceDeliveredOnLink(linkID: Data)`; `LXMFRouter.State.linkResourceInFlight` (public, for assertions).

- [ ] **Step 1: Add the `linkResourceInFlight` state.**

In `State`, immediately after the `pendingDeliveries` property (the line `public var pendingDeliveries: [Data: PendingDelivery] = [:]`), add:

```swift
        /// linkID → message.hash of the Resource-direct send currently in flight on that link.
        /// Single-in-flight per link (last write wins); resolves resourceDeliveredOnLink → deliveryConfirmed.
        public var linkResourceInFlight: [Data: Data] = [:]
```

- [ ] **Step 2: Add the `resourceDeliveredOnLink` action.**

In the `Action` enum, immediately after `case delivered(messageHash: Data)`, add:

```swift
        case resourceDeliveredOnLink(linkID: Data)
```

- [ ] **Step 3: Record the in-flight hash at the `.send` active-link site.**

In the `.direct` case of the `.send` handler, the active-link branch currently reads:

```swift
                    if case let .active(linkID) = state.directLinks[dest] {
                        let asResource = message.directRepresentation == .resource
                        arm(&state, message.hash, .direct(destinationHash: dest, data: message.packed, asResource: asResource))
```

Add one line after the `arm(...)` call:

```swift
                        if asResource { state.linkResourceInFlight[linkID] = message.hash }
```

- [ ] **Step 4: Record the in-flight hash at the `linkEstablished` drain site.**

In the `.linkEstablished` handler's `for m in queued { … }` loop, which reads:

```swift
                for m in queued {
                    let asResource = m.directRepresentation == .resource
                    arm(&state, m.hash, .direct(destinationHash: dest, data: m.packed, asResource: asResource))
                    effects.append(.send(.delegate(.sendDirect(linkID: linkID, data: m.packed, asResource: asResource))))
```

Add one line after the `arm(...)` call:

```swift
                    if asResource { state.linkResourceInFlight[linkID] = m.hash }
```

- [ ] **Step 5: Record the in-flight hash at the `.retryDue` resend site.**

In the `.retryDue` handler, the `.direct` resend branch reads:

```swift
                case let .direct(destinationHash, data, asResource):
                    if case let .active(linkID) = state.directLinks[destinationHash] {
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: asResource))),
                                      retryTimer(hash, LXMFDelivery.retryWaitSeconds))
                    }
```

Insert the recording line inside the `if case` block, before the `return`:

```swift
                    if case let .active(linkID) = state.directLinks[destinationHash] {
                        if asResource { state.linkResourceInFlight[linkID] = hash }
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: asResource))),
                                      retryTimer(hash, LXMFDelivery.retryWaitSeconds))
                    }
```

- [ ] **Step 6: Add the `resourceDeliveredOnLink` handler.**

In the main `switch action`, immediately after the `.delivered` case (the block ending `.send(.delegate(.deliveryConfirmed(messageHash: hash))))`), add:

```swift
            case let .resourceDeliveredOnLink(linkID):
                guard let hash = state.linkResourceInFlight[linkID] else { return .none }
                state.linkResourceInFlight[linkID] = nil
                return .send(.delivered(messageHash: hash))
```

- [ ] **Step 7: Clear the in-flight entry on link close.**

In the `.linkClosed(dest)` handler, the first line is `state.directLinks[dest] = nil`. Replace that single line with a capture-then-clear that runs BEFORE the link status is dropped:

```swift
            case let .linkClosed(dest):
                if case let .active(linkID) = state.directLinks[dest] {
                    state.linkResourceInFlight[linkID] = nil
                }
                state.directLinks[dest] = nil
```

(The rest of the `.linkClosed` handler — the `hasPending`/`hasQueued` re-establish logic — is unchanged.)

- [ ] **Step 8: Write the failing unit test.**

Append to `Tests/ReTiCANodeTests/LXMFRouterTests.swift`:

```swift
/// Resource-direct confirmation: a resource-sized message sent over an active link records its hash in
/// linkResourceInFlight; resourceDeliveredOnLink(linkID) resolves it to deliveryConfirmed and clears both
/// the pending delivery and the in-flight entry. (This is what stops the direct retry-storm on success.)
@Test @MainActor func routerConfirmsResourceDirectOnResourceDelivered() async {
    let bigMsg = makeMessage(source: Identity(), content: String(repeating: "y", count: 2000))
    #expect(bigMsg.directRepresentation == .resource)
    let linkID = Data(repeating: 0xEF, count: 16)
    var initial = LXMFRouter.State()
    initial.directLinks[bigMsg.destinationHash] = .active(linkID: linkID)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    await store.send(.send(message: bigMsg, desiredMethod: .direct))
    await store.receive { action in
        if case let .delegate(.sendDirect(lid, _, asResource)) = action {
            #expect(lid == linkID); #expect(asResource == true); return true
        }
        return false
    }
    #expect(store.state.linkResourceInFlight[linkID] == bigMsg.hash)     // recorded on send
    #expect(store.state.pendingDeliveries[bigMsg.hash] != nil)           // awaiting outcome

    await store.send(.resourceDeliveredOnLink(linkID: linkID))
    await store.receive { action in
        if case let .delegate(.deliveryConfirmed(hash)) = action { #expect(hash == bigMsg.hash); return true }
        return false
    }
    #expect(store.state.pendingDeliveries[bigMsg.hash] == nil)           // resolved → retry can't resend
    #expect(store.state.linkResourceInFlight[linkID] == nil)            // in-flight entry cleared
}
```

- [ ] **Step 9: Run the new test; confirm it passes.**

Run: `swift test --filter routerConfirmsResourceDirectOnResourceDelivered`
Expected: PASS. (If it stale-links, run `swift package clean` first.)

- [ ] **Step 10: Mutation-verify (one at a time, revert between each).**

- Mutation A — drop the recording: in the `.send` active-link site (Step 3), delete the `if asResource { state.linkResourceInFlight[linkID] = message.hash }` line. Run the Step 9 filter → must FAIL (`linkResourceInFlight[linkID]` is not `bigMsg.hash`, and `resourceDeliveredOnLink` finds nothing → no `deliveryConfirmed`). Revert → PASS.
- Mutation B — no-op the resolver: in the `resourceDeliveredOnLink` handler (Step 6), replace the body with `return .none`. Run → must FAIL (no `deliveryConfirmed`, `pendingDeliveries` not cleared). Revert → PASS.

- [ ] **Step 11: Run the full LXMFRouter suite; confirm no regressions.**

Run: `swift test --filter LXMFRouterTests`
Expected: all PASS.

- [ ] **Step 12: Commit.**

Write the message to `/tmp/ReTiCA/commit-msg-confirm-task1.txt` (verbatim trailers), then:

```bash
git add Sources/ReTiCANode/LXMFRouter.swift Tests/ReTiCANodeTests/LXMFRouterTests.swift
git commit -F /tmp/ReTiCA/commit-msg-confirm-task1.txt
```

Suggested subject: `feat: LXMF confirm task 1 — LXMFRouter linkResourceInFlight + resourceDeliveredOnLink`

---

### Task 2: LXMFNode — wire resourceConcluded → confirmation + integration test

Wire the sender's `resourceConcluded` through to `deliveryConfirmed`, expose a `deliveryConfirmed` app delegate, and extend the direct-Resource integration test to prove end-to-end confirmation.

**Files:**
- Modify: `Sources/ReTiCANode/LXMFNode.swift`
- Test: `Tests/ReTiCANodeTests/LXMFNodeDirectTests.swift` (append one test, or extend the existing flow into a second test)

**Interfaces:**
- Consumes: `Endpoint.Action.Delegate.resourceConcluded(linkID: Data, resourceHash: Data)` (Endpoint.swift:185-187); `LXMFRouter.Action.resourceDeliveredOnLink(linkID:)` (Task 1); `LXMFRouter.Action.Delegate.deliveryConfirmed(messageHash: Data)` (LXMFRouter.swift:77).
- Produces: `LXMFNode.Action.Delegate.deliveryConfirmed(messageHash: Data)`.

- [ ] **Step 1: Add the `deliveryConfirmed` app delegate case.**

In `LXMFNode.Action.Delegate`, after `case deliveryFailed(messageHash: Data)`, add:

```swift
            case deliveryConfirmed(messageHash: Data)
```

- [ ] **Step 2: Wire `resourceConcluded → router.resourceDeliveredOnLink`.**

Add a translation among the direct cases (before the final `case .endpoint, .router, .delegate:` catch-all):

```swift
            case let .endpoint(.delegate(.resourceConcluded(linkID, _))):
                return .send(.router(.resourceDeliveredOnLink(linkID: linkID)))
```

- [ ] **Step 3: Wire `router.deliveryConfirmed → node delegate`.**

Immediately after the existing `router.delegate.deliveryFailed` forward (the block `case let .router(.delegate(.deliveryFailed(hash))): return .send(.delegate(.deliveryFailed(messageHash: hash)))`), add:

```swift
            case let .router(.delegate(.deliveryConfirmed(hash))):
                return .send(.delegate(.deliveryConfirmed(messageHash: hash)))
```

- [ ] **Step 4: Confirm the opportunistic + direct tests still compile/pass.**

Run: `swift test --filter lxmfNodeDirectDeliversResourceEndToEnd`
Then: `swift test --filter lxmfNodeOpportunisticDeliversEndToEnd`
Expected: both PASS (additive changes only).

- [ ] **Step 5: Write the integration test extension.**

Append to `Tests/ReTiCANodeTests/LXMFNodeDirectTests.swift` a test that drives the full direct-Resource flow through `LXMFNode` exactly like `lxmfNodeDirectDeliversResourceEndToEnd`, but continues past B's receipt: after B emits its `RESOURCE_PRF` (the last frame B sends), bridge that frame back to A so A's `resourceConcluded` fires, and assert A emits `.delegate.deliveryConfirmed(messageHash:)`.

Model it on `lxmfNodeDirectDeliversResourceEndToEnd` (same harness, same handshake + resource bridging). The new tail, after the loop where B receives all parts and emits `RESOURCE_PRF`:

```swift
    // B's RESOURCE_PRF (the frame B emitted after the last part) → A: A concludes the resource,
    // which LXMFNode maps resourceConcluded → router.resourceDeliveredOnLink → deliveryConfirmed.
    let gotConfirmed = LockIsolated<Data?>(nil)
    eventsA.yield(.data(sentB.value.last!))
    await a.receive { action in
        if case let .delegate(.deliveryConfirmed(hash)) = action { gotConfirmed.setValue(hash); return true }
        return false
    }
    #expect(gotConfirmed.value == sentMessageHash)   // the hash of the message A sent
```

Capture `sentMessageHash` when A builds/sends the message. Because `LXMFNode.send` builds the `LXMessage` internally (from `date.now`), recover the hash in the test by rebuilding the same message with the same fixed `date` the store uses, e.g.:

```swift
    let sentMessageHash = LXMessage.create(
        source: aIdentity, destinationHash: bDeliveryHash,
        timestamp: 1700000000.5, title: Data("big".utf8), content: bigContent).hash
```

(Use the exact same `title`, `content`, `destinationHash`, and the store's `$0.date` timestamp so the deterministic `message.hash` matches. `message.hash` is deterministic even though the Ed25519 signature is not.)

If keeping one long test is cleaner than a second near-duplicate, instead EXTEND `lxmfNodeDirectDeliversResourceEndToEnd` with this tail and rename it (e.g. `lxmfNodeDirectDeliversResourceAndConfirms`). Either is acceptable; do not leave two tests that both re-run the full handshake unless it reads clearly.

- [ ] **Step 6: Run the integration test.**

Run: `swift test --filter LXMFNodeDirectTests`
Expected: PASS (both the delivery and the confirmation). If the exact `receive` interleaving differs, adjust intermediate `receive` predicates to match emission order (the `.off` store tolerates skipped intermediate receives) — but do NOT change the final `deliveryConfirmed`/content assertions. Recall the index-based byte-bridging gotcha from the prior slice (LRRTT + RESOURCE_ADV can both land in `sentA` within one `receive`).

- [ ] **Step 7: Mutation-verify the integration test (one at a time, revert between each).**

- Mutation A — break the confirmation wire: in `LXMFNode`, change the `resourceConcluded` translation (Step 2) to `return .none`. Run the Step 6 filter → the confirmation test must FAIL (A never emits `deliveryConfirmed`). Revert → PASS.
- Mutation B — drop the delegate forward: change the `router.deliveryConfirmed` forward (Step 3) to `return .none`. Run → must FAIL (no app-level `deliveryConfirmed`). Revert → PASS.

- [ ] **Step 8: Run the full ReTiCANode suite; confirm green.**

Run: `swift test --filter ReTiCANodeTests`
Expected: all PASS.

- [ ] **Step 9: Commit.**

Write the message to `/tmp/ReTiCA/commit-msg-confirm-task2.txt` (verbatim trailers), then:

```bash
git add Sources/ReTiCANode/LXMFNode.swift Tests/ReTiCANodeTests/LXMFNodeDirectTests.swift
git commit -F /tmp/ReTiCA/commit-msg-confirm-task2.txt
```

Suggested subject: `feat: LXMF confirm task 2 — LXMFNode resourceConcluded→deliveryConfirmed + integration test`

---

## Self-Review

**Spec coverage:**
- `linkResourceInFlight` state → Task 1 Step 1. ✅
- Record at all 3 Resource-send sites → Task 1 Steps 3-5. ✅
- `resourceDeliveredOnLink` reuses `.delivered` → Task 1 Steps 2, 6. ✅
- Clear on `linkClosed` → Task 1 Step 7. ✅
- Resource-direct only (guarded by `if asResource`) → Steps 3-5. ✅
- `resourceConcluded → resourceDeliveredOnLink` wire → Task 2 Step 2. ✅
- `deliveryConfirmed` app delegate + forward → Task 2 Steps 1, 3. ✅
- Router unit test + integration test → Task 1 Step 8, Task 2 Step 5. ✅
- No packet-direct / opportunistic / `resourceFailed` wiring → absent by construction; Global Constraints call it out. ✅

**Placeholder scan:** none — all steps carry concrete code or exact commands.

**Type consistency:** `resourceDeliveredOnLink(linkID: Data)`, `linkResourceInFlight: [Data: Data]`, `deliveryConfirmed(messageHash: Data)`, `resourceConcluded(linkID:, resourceHash:)`, `.delivered(messageHash:)`, `.active(linkID:)` all match the surfaces read from `LXMFRouter.swift`/`Endpoint.swift`. The unit test mirrors existing `routerLinkEstablishedDrainsQueueAsSendDirect` / `routerDirectWithActiveLinkSendsImmediately` patterns; `makeMessage(content: String(repeating: "y", count: 2000))` yields `directRepresentation == .resource`.
