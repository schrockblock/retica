# LXMF Propagation P4c-3 — PNNode Link Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `PNNode` clears per-link state on `linkClosed`/`requestFailed`/`linkFailed` (currently swallowed), closing the accumulated benign leaks; fix the stale cost-0 comment.

**Architecture:** A `clearLink(linkID)` helper + three Endpoint-delegate handlers in `PNNode`. No `Endpoint`/`PropagationNode`/core changes.

**Tech Stack:** Swift, Point-Free Composable Architecture (TCA), Swift Testing (`@Test`/`#expect`), `swift test`.

## Global Constraints

- **Commit directly to `main`** — no feature branch, no merge dance.
- **No compound shell commands** — one command per invocation. Write files with the editor, not echo/heredoc.
- **Temp files** go in `/tmp/ReTiCA/`.
- **Commit trailers, verbatim, at COLUMN 0 (no leading whitespace)**, via `git commit -F <file>` (never `-m`):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```
  Verify after commit: `git log -1 --format='%(trailers:key=Claude-Session,valueonly=true)'` must print the URL.
- **Three-step mutation verification** for every new test. One mutation at a time.
- **Non-exhaustive TCA tests** (`store.exhaustivity = .off`).
- **Scope:** state cleanup on failure/close + the comment fix only. Do NOT add proactive post-transfer `closeLink`, registry, or scheduling.
- If `swift test` shows a stale cross-module link error, run `swift package clean` then retry.

---

### Task 1: PNNode link cleanup handlers

**Files:**
- Modify: `Sources/ReTiCANode/PNNode.swift`
- Test: `Tests/ReTiCANodeTests/PNNodeTests.swift`

**Interfaces:**
- Consumes: `Endpoint.Action.Delegate.linkClosed(linkID:reason:)`, `.requestFailed(linkID:requestID:)`, `.linkFailed(destinationHash:)`; `PNNode.State.{offerLinks, clientIdentities, pendingGet, pendingOffer, pendingSyncPeers}`; `LinkSession.CloseReason`.
- Produces: (behavioral) per-link state cleanup.

- [ ] **Step 1: Add the `clearLink` helper.**

In the `Reduce { [date] state, action in … }` closure, at the top (before `switch action {`), add a nested function:

```swift
            func clearLink(_ state: inout State, _ linkID: Data) {
                state.offerLinks[linkID] = nil
                state.clientIdentities[linkID] = nil
                state.pendingGet = state.pendingGet.filter { $0.value.linkID != linkID }
                state.pendingOffer = state.pendingOffer.filter { $0.value.linkID != linkID }
            }
```

- [ ] **Step 2: Add the three delegate handlers.**

Immediately before the final `case .endpoint, .node, .delegate:` catch-all, add:

```swift
            case let .endpoint(.delegate(.linkClosed(linkID, _))):
                clearLink(&state, linkID)
                return .none

            case let .endpoint(.delegate(.requestFailed(linkID, _))):
                clearLink(&state, linkID)
                return .none

            case let .endpoint(.delegate(.linkFailed(dest))):
                state.pendingSyncPeers[dest] = nil          // outbound openLink failed before a link existed
                return .none
```

- [ ] **Step 3: Fix the stale comment.**

At `PNNode.swift` line ~132 (the `peerValidated` invalid-key drop), change:
```swift
                state.pendingOffer[peerHash] = nil                     // invalid key → drop (dead path at cost 0)
```
to:
```swift
                state.pendingOffer[peerHash] = nil                     // invalid key → drop
```

- [ ] **Step 4: Confirm build + existing pnNode tests pass (no behavior change).**

Run: `swift build`
Then: `swift test --filter pnNode`
Expected: builds clean; all existing `pnNode*` tests PASS (the new handlers replace `.none` only for links that fail/close, which existing tests don't trigger). (If stale-links, `swift package clean` first.)

- [ ] **Step 5: Write the cleanup tests.**

Append to `Tests/ReTiCANodeTests/PNNodeTests.swift`:

```swift
// MARK: - P4c-3 link cleanup

/// linkClosed clears all per-link state (clientIdentities, offerLinks, and any pendingGet/pendingOffer on it).
@Test @MainActor func pnNodeLinkClosedClearsPerLinkState() async {
    let linkID = Data(repeating: 0xC0, count: 16)
    let pHash = Data(repeating: 0xAB, count: 16)               // any 16-byte peer hash
    var initial = PNNode.State(identity: Identity(), endpoint: Endpoint.State(host: "pn", port: 4242, reconnectOnDrop: false))
    initial.clientIdentities[linkID] = Identity()
    initial.offerLinks[linkID] = [Data(repeating: 0x11, count: 32)]
    initial.pendingGet[Data(repeating: 0xCC, count: 16)] = PNNode.PendingGet(linkID: linkID, requestID: Data([1]))
    initial.pendingOffer[pHash] = PNNode.PendingOffer(linkID: linkID, requestID: Data([2]), offeredIds: [])
    let store = TestStore(initialState: initial) { PNNode() } withDependencies: {
        $0.continuousClock = TestClock(); $0.date = .constant(Date(timeIntervalSince1970: 1700000000)); $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.endpoint(.delegate(.linkClosed(linkID: linkID, reason: .initiatorClosed))))
    #expect(store.state.clientIdentities[linkID] == nil)
    #expect(store.state.offerLinks[linkID] == nil)
    #expect(!store.state.pendingGet.values.contains { $0.linkID == linkID })
    #expect(!store.state.pendingOffer.values.contains { $0.linkID == linkID })
}

/// requestFailed clears the outbound offer link entry.
@Test @MainActor func pnNodeRequestFailedClearsOfferLink() async {
    let linkID = Data(repeating: 0xC0, count: 16)
    var initial = PNNode.State(identity: Identity(), endpoint: Endpoint.State(host: "pn", port: 4242, reconnectOnDrop: false))
    initial.offerLinks[linkID] = [Data(repeating: 0x11, count: 32)]
    let store = TestStore(initialState: initial) { PNNode() } withDependencies: {
        $0.continuousClock = TestClock(); $0.date = .constant(Date(timeIntervalSince1970: 1700000000)); $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.endpoint(.delegate(.requestFailed(linkID: linkID, requestID: Data([1])))))
    #expect(store.state.offerLinks[linkID] == nil)
}

/// linkFailed clears the pending sync peer (outbound openLink failed).
@Test @MainActor func pnNodeLinkFailedClearsPendingSyncPeer() async {
    let peerDest = Data(repeating: 0xD0, count: 16)
    let store = makeStore(Identity())
    await store.send(.syncToPeer(destinationHash: peerDest, peeringCost: 0))
    await store.receive { if case .endpoint(.openLink(peerDest)) = $0 { return true }; return false }
    #expect(store.state.pendingSyncPeers[peerDest] == 0)
    await store.send(.endpoint(.delegate(.linkFailed(destinationHash: peerDest))))
    #expect(store.state.pendingSyncPeers[peerDest] == nil)
}
```

NOTE: `PNNode.PendingGet`/`PNNode.PendingOffer` memberwise inits are accessible via `@testable import ReTiCANode`; if their init labels differ from `(linkID:requestID:)` / `(linkID:requestID:offeredIds:)`, match the actual definitions.

- [ ] **Step 6: Run the new tests; confirm green.**

Run: `swift test --filter pnNode`
Expected: all PASS.

- [ ] **Step 7: Mutation-verify (one at a time, revert between each).**

- Mutation A — drop the `offerLinks` clear: in `clearLink`, remove `state.offerLinks[linkID] = nil`. Run `swift test --filter pnNodeLinkClosedClearsPerLinkState` → must FAIL (`offerLinks[linkID]` still set). Then `swift test --filter pnNodeRequestFailedClearsOfferLink` → also FAIL. Revert → both PASS.
- Mutation B — no-op the `linkFailed` handler: change its body to `return .none` (without clearing). Run `swift test --filter pnNodeLinkFailedClearsPendingSyncPeer` → must FAIL (`pendingSyncPeers[dest]` still set). Revert → PASS.
- Mutation C — drop the `pendingGet` filter in `clearLink`. Run `swift test --filter pnNodeLinkClosedClearsPerLinkState` → must FAIL (pendingGet entry with that linkID remains). Revert → PASS.

- [ ] **Step 8: Run the full ReTiCANode suite; confirm green.**

Run: `swift test --filter ReTiCANodeTests`
Expected: all PASS.

- [ ] **Step 9: Commit.** (column-0 trailers; verify parse after)

Write `/tmp/ReTiCA/commit-msg-p4c3-task1.txt`, then:
```bash
git add Sources/ReTiCANode/PNNode.swift Tests/ReTiCANodeTests/PNNodeTests.swift
git commit -F /tmp/ReTiCA/commit-msg-p4c3-task1.txt
```
Suggested subject: `feat: LXMF propagation P4c-3 — PNNode link cleanup`

---

## Self-Review

**Spec coverage:**
- `clearLink` helper (offerLinks/clientIdentities/pendingGet/pendingOffer by linkID) → Task 1 Step 1. ✅
- `linkClosed`/`requestFailed`/`linkFailed` handlers → Step 2. ✅
- Comment fix → Step 3. ✅
- Cleanup tests (linkClosed clears all; requestFailed clears offer; linkFailed clears pending sync) → Step 5. ✅
- No proactive closeLink / registry / scheduling → absent by construction; Global Constraints call it out. ✅

**Placeholder scan:** none — all code is concrete (the `pendingGet` key is `Data(repeating: 0xCC, count: 16)`).

**Type consistency:** `linkClosed(linkID:reason:)`, `requestFailed(linkID:requestID:)`, `linkFailed(destinationHash:)`, `LinkSession.CloseReason.initiatorClosed`, `PNNode.PendingGet(linkID:requestID:)`, `PNNode.PendingOffer(linkID:requestID:offeredIds:)`, `pendingSyncPeers[dest]`, `syncToPeer(destinationHash:peeringCost:)` all match the current sources.
