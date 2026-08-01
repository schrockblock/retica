# LXMF Propagation P3c — Propagation-Accept Confirmation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a propagation node concludes a client's ingest Resource (proves receipt), the client emits a distinct `propagationAccepted` signal and cancels the retry timer — closing P1's deferred confirmation and the propagation retry-storm.

**Architecture:** Record `linkResourceInFlight` at the 3 propagation-send sites so the existing `resourceConcluded → resourceDeliveredOnLink → .delivered` wire resolves; the `.delivered` handler branches on the pending send type (`.propagated → propagationAccepted`, else `deliveryConfirmed`). `LXMFNode` forwards the new delegate. No `Endpoint`/core changes.

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
- **Non-exhaustive TCA tests** (`store.exhaustivity = .off`), asserting outcomes. NOTE: a propagation send over an active link arms a 600s idle timer; do NOT flip `.on` at the end of a test with an in-flight idle timer.
- **Ed25519/encrypted tail hedged** — never byte-compare a signature; `message.hash` is deterministic and safe to compare.
- **Scope:** propagation-accept confirmation only. Do NOT touch the 3-store capstone loop, P4 mesh, `retain`/transfer-limit.
- If `swift test` shows a stale cross-module link error, run `swift package clean` then retry.

---

### Task 1: LXMFRouter propagation-accept

Record `linkResourceInFlight` at the propagation-send sites and branch `.delivered` to emit a distinct `propagationAccepted`.

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift`
- Test: `Tests/ReTiCANodeTests/LXMFRouterTests.swift`

**Interfaces:**
- Consumes: existing `linkResourceInFlight`, `pendingDeliveries` (`PendingDelivery.resend: ResendInfo` with `.propagated`/`.direct`/`.opportunistic`), `CancelID.retry`, `resourceDeliveredOnLink`.
- Produces (for Task 2): `LXMFRouter.Action.Delegate.propagationAccepted(messageHash: Data)`.

- [ ] **Step 1: Add the `propagationAccepted` delegate.**

In `Action.Delegate`, immediately after `case deliveryConfirmed(messageHash: Data)`, add:
```swift
            case propagationAccepted(messageHash: Data)
```

- [ ] **Step 2: Record `linkResourceInFlight` at the `.sendViaPropagation` active-link site.**

In the `.sendViaPropagation` handler's active-link branch, which reads:
```swift
                if case let .active(linkID) = state.directLinks[pn] {
                    arm(&state, message.hash, .propagated(destinationHash: pn, data: propagationPacked))
                    return .merge(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: propagationPacked))),
```
add one line after the `arm(...)`:
```swift
                    state.linkResourceInFlight[linkID] = message.hash
```

- [ ] **Step 3: Record at the `.linkEstablished` propagation-queue drain.**

In the `for item in propQueued { … }` loop, which reads:
```swift
                for item in propQueued {
                    arm(&state, item.messageHash, .propagated(destinationHash: dest, data: item.propagationPacked))
                    effects.append(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: item.propagationPacked))))
```
add one line after the `arm(...)`:
```swift
                    state.linkResourceInFlight[linkID] = item.messageHash
```

- [ ] **Step 4: Record at the `.retryDue` `.propagated` resend.**

In the `.retryDue` handler's `.propagated` branch, which reads:
```swift
                case let .propagated(destinationHash, data):
                    if case let .active(linkID) = state.directLinks[destinationHash] {
                        return .merge(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: data))),
```
insert the record line inside the `if case`, before the `return`:
```swift
                    if case let .active(linkID) = state.directLinks[destinationHash] {
                        state.linkResourceInFlight[linkID] = hash
                        return .merge(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: data))),
                                      retryTimer(hash, LXMFDelivery.retryWaitSeconds))
                    }
```

- [ ] **Step 5: Branch the `.delivered` handler on the pending send type.**

Replace the existing `.delivered` handler:
```swift
            case let .delivered(hash):
                guard state.pendingDeliveries[hash] != nil else { return .none }
                state.pendingDeliveries[hash] = nil
                return .merge(.cancel(id: CancelID.retry(hash)),
                              .send(.delegate(.deliveryConfirmed(messageHash: hash))))
```
with:
```swift
            case let .delivered(hash):
                guard let pending = state.pendingDeliveries[hash] else { return .none }
                state.pendingDeliveries[hash] = nil
                let outcome: Action.Delegate = {
                    if case .propagated = pending.resend { return .propagationAccepted(messageHash: hash) }
                    return .deliveryConfirmed(messageHash: hash)
                }()
                return .merge(.cancel(id: CancelID.retry(hash)), .send(.delegate(outcome)))
```

- [ ] **Step 6: Write the propagation-accept unit test.**

Append to `Tests/ReTiCANodeTests/LXMFRouterTests.swift`:

```swift
/// Propagation-accept: a propagation send over an active PN link records linkResourceInFlight; when the PN
/// concludes the resource, resourceDeliveredOnLink resolves it to propagationAccepted (NOT deliveryConfirmed)
/// and clears the pending delivery — closing the propagation retry-storm on PN accept.
@Test @MainActor func routerConfirmsPropagationAcceptOnResourceDelivered() async {
    let msg = makeMessage(source: Identity(), content: "via pn")
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.directLinks[pn] = .active(linkID: linkID)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    await store.send(.sendViaPropagation(message: msg, propagationPacked: Data("container".utf8)))
    await store.receive { action in
        if case let .delegate(.sendPropagated(lid, _)) = action { #expect(lid == linkID); return true }
        return false
    }
    #expect(store.state.linkResourceInFlight[linkID] == msg.hash)      // recorded on propagation send
    #expect(store.state.pendingDeliveries[msg.hash] != nil)

    await store.send(.resourceDeliveredOnLink(linkID: linkID))
    await store.receive { action in
        if case let .delegate(.propagationAccepted(hash)) = action { #expect(hash == msg.hash); return true }
        return false
    }
    #expect(store.state.pendingDeliveries[msg.hash] == nil)           // resolved → retry cancelled
    #expect(store.state.linkResourceInFlight[linkID] == nil)
}
```

- [ ] **Step 7: Run the new test + the direct-confirmation regression; confirm green.**

Run: `swift test --filter routerConfirmsPropagationAcceptOnResourceDelivered`
Then: `swift test --filter routerConfirmsResourceDirectOnResourceDelivered`
Expected: both PASS — the direct test confirms `.delivered` still emits `deliveryConfirmed` for `.direct` (no regression from the branch).

- [ ] **Step 8: Mutation-verify (one at a time, revert between each).**

- Mutation A — drop the record: in the `.sendViaPropagation` active branch (Step 2), delete the `state.linkResourceInFlight[linkID] = message.hash` line. Run `swift test --filter routerConfirmsPropagationAcceptOnResourceDelivered` → must FAIL (`linkResourceInFlight` empty → `resourceDeliveredOnLink` no-ops → no `propagationAccepted`). Revert → PASS.
- Mutation B — invert the branch: in `.delivered` (Step 5), swap so `.propagated` returns `deliveryConfirmed` and the else returns `propagationAccepted`. Run `swift test --filter routerConfirmsPropagationAcceptOnResourceDelivered` → must FAIL (propagation now emits `deliveryConfirmed`). Then run `swift test --filter routerConfirmsResourceDirectOnResourceDelivered` → must ALSO FAIL (direct now emits `propagationAccepted`). Revert → both PASS.

- [ ] **Step 9: Run the full LXMFRouter suite; confirm no regressions.**

Run: `swift test --filter LXMFRouterTests`
Expected: all PASS.

- [ ] **Step 10: Commit.**

Write the message to `/tmp/ReTiCA/commit-msg-p3c-task1.txt` (verbatim trailers), then:

```bash
git add Sources/ReTiCANode/LXMFRouter.swift Tests/ReTiCANodeTests/LXMFRouterTests.swift
git commit -F /tmp/ReTiCA/commit-msg-p3c-task1.txt
```

Suggested subject: `feat: LXMF propagation P3c task 1 — LXMFRouter propagation-accept signal`

---

### Task 2: LXMFNode propagationAccepted forward + integration

Surface the new signal on `LXMFNode` and prove it end-to-end by extending the P1 send test.

**Files:**
- Modify: `Sources/ReTiCANode/LXMFNode.swift`
- Test: `Tests/ReTiCANodeTests/LXMFNodePropagationTests.swift` (extend the existing `lxmfNodeSendsViaPropagationNode`)

**Interfaces:**
- Consumes: `LXMFRouter.Action.Delegate.propagationAccepted(messageHash:)` (Task 1); the existing `resourceConcluded → router.resourceDeliveredOnLink` wire (already present in `LXMFNode`).
- Produces: `LXMFNode.Action.Delegate.propagationAccepted(messageHash: Data)`.

- [ ] **Step 1: Add the `propagationAccepted` app delegate.**

In `LXMFNode.Action.Delegate`, after `case deliveryConfirmed(messageHash: Data)`, add:
```swift
            case propagationAccepted(messageHash: Data)
```

- [ ] **Step 2: Wire the forward.**

Immediately after the existing `router.deliveryConfirmed` forward (`case let .router(.delegate(.deliveryConfirmed(hash))): return .send(.delegate(.deliveryConfirmed(messageHash: hash)))`), add:
```swift
            case let .router(.delegate(.propagationAccepted(hash))):
                return .send(.delegate(.propagationAccepted(messageHash: hash)))
```

- [ ] **Step 3: Confirm existing suites still compile/pass.**

Run: `swift test --filter LXMFNode`
Expected: PASS (additive).

- [ ] **Step 4: Extend the P1 send test to assert propagation accept.**

Read `Tests/ReTiCANodeTests/LXMFNodePropagationTests.swift` and locate `lxmfNodeSendsViaPropagationNode`. It drives client A sending a container as a Resource to a bare-`Endpoint` PN stub, up to the PN's `resourceReceived` (after which the PN emits its `RESOURCE_PRF`). Extend the test (rename it to `lxmfNodeSendsViaPropagationNodeAndConfirmsAccept`): after the PN receives the container, capture the PN's `RESOURCE_PRF` frame and bridge it back to A so A's `resourceConcluded` fires, and assert A emits `.delegate.propagationAccepted(messageHash:)` matching the sent message's deterministic hash.

- Recover the sent hash by rebuilding the message with the same fixed params the store uses (source `aIdentity`, `destinationHash: rDeliveryHash`, the store's `$0.date` timestamp, same title/content), e.g.:
  ```swift
  let sentHash = LXMessage.create(source: aIdentity, destinationHash: rDeliveryHash,
                                  timestamp: 1700000000.5, title: <sameTitle>, content: <sameContent>).hash
  ```
- Tail (after the PN's `resourceReceived` / `RESOURCE_PRF` emission — capture the PRF frame from `sentPN` at that point, as the direct-confirmation test does with `resourcePrfBytes`):
  ```swift
  let gotAccepted = LockIsolated<Data?>(nil)
  eventsA.yield(.data(prfBytes))                          // PN's RESOURCE_PRF → A concludes the resource
  await a.receive { action in
      if case let .delegate(.propagationAccepted(hash)) = action { gotAccepted.setValue(hash); return true }
      return false
  }
  #expect(gotAccepted.value == sentHash)
  ```

Reconcile the exact `receive`/bridge interleaving by running (the `.off` store tolerates skipped intermediate receives; A's actions are wrapped `.endpoint(...)`, the PN's are bare `Endpoint.Action`). Keep the existing container-delivery assertions; do NOT weaken them.

- [ ] **Step 5: Run the extended test.**

Run: `swift test --filter lxmfNodeSendsViaPropagationNodeAndConfirmsAccept`
Expected: PASS.

- [ ] **Step 6: Mutation-verify (one at a time, revert between each).**

- Mutation A — break the forward: in `LXMFNode`'s `propagationAccepted` wire (Step 2), `return .none`. Run the Step 5 filter → must FAIL (A never emits `propagationAccepted`). Revert → PASS.
- Mutation B — in `LXMFRouter`'s `.sendViaPropagation` active branch, drop the `linkResourceInFlight` record (Task 1 Step 2 line). Run → must FAIL (no accept resolves). Revert → PASS.

- [ ] **Step 7: Run the full ReTiCANode suite; confirm green.**

Run: `swift test --filter ReTiCANodeTests`
Expected: all PASS.

- [ ] **Step 8: Commit.**

Write the message to `/tmp/ReTiCA/commit-msg-p3c-task2.txt` (verbatim trailers), then:

```bash
git add Sources/ReTiCANode/LXMFNode.swift Tests/ReTiCANodeTests/LXMFNodePropagationTests.swift
git commit -F /tmp/ReTiCA/commit-msg-p3c-task2.txt
```

Suggested subject: `feat: LXMF propagation P3c task 2 — LXMFNode propagationAccepted + integration`

---

## Self-Review

**Spec coverage:**
- `linkResourceInFlight` recorded at all 3 propagation-send sites → Task 1 Steps 2-4. ✅
- New `propagationAccepted` delegate → Task 1 Step 1; forwarded on `LXMFNode` → Task 2 Steps 1-2. ✅
- `.delivered` branch on `.propagated` (direct unchanged) → Task 1 Step 5, regression Step 7. ✅
- Retry cancelled on accept (pending cleared) → Task 1 Step 6 asserts `pendingDeliveries == nil`. ✅
- End-to-end accept via the existing `resourceConcluded` wire → Task 2 Step 4. ✅
- No 3-store/mesh/retain/transfer-limit → absent by construction; Global Constraints call it out. ✅

**Placeholder scan:** Task 1 fully concrete. Task 2 Step 4 references the existing test by name and gives the exact tail + assertion + hash-recovery; the implementer reads the actual test to place the PRF-bridge (same pattern as the direct-confirmation slice). All production code and the load-bearing assertion are concrete.

**Type consistency:** `propagationAccepted(messageHash: Data)` (router + node), `PendingDelivery.resend`/`ResendInfo.propagated`, `linkResourceInFlight`, `resourceDeliveredOnLink`, `sendViaPropagation(message:propagationPacked:)`, `sendPropagated(linkID:propagationPacked:)` all match the current `LXMFRouter.swift`/`LXMFNode.swift` surfaces. The new test mirrors `routerConfirmsResourceDirectOnResourceDelivered`.
