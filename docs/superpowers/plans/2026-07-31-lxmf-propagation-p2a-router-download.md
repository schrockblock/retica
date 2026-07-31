# LXMF Propagation P2a — Router Download State Machine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Model the two-phase `/get` offer/get download protocol in the decoupled `LXMFRouter` so it is unit-testable with no transport: sync → request the message list → compute wants/haves → request wanted messages → track downloaded transient_ids.

**Architecture:** Pure reducer logic in `LXMFRouter`. Rename the phase-1 delegate `requestMessageDownload → requestMessageList`; add a `downloadedTransientIds` have-set, an `offeredMessageList` action that computes the wants/haves split and emits a new `requestMessages` phase-2 delegate, and a `messagesDownloaded` action that records the have-set. No transport, no decryption, no msgpack (all P2b). No `Endpoint`/core changes.

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
- **Three-step mutation verification** for the new tests: run pass → mutate production to force fail + confirm → revert + confirm pass. One mutation at a time.
- **Non-exhaustive TCA tests** (`store.exhaustivity = .off`), asserting outcomes; flip `.on` last to assert the absence of a delegate.
- **Scope:** router-side state machine only. Do NOT add IDENTIFY, request/response transport, msgpack, decryption/opening, `max_messages` cap, or `retain_synced_on_node` — all P2b or later.
- `wants`/`haves` MUST preserve the offered-list order (use `filter` on the offered array, not Set operations).
- If `swift test` shows a stale cross-module link error, run `swift package clean` then retry.

---

### Task 1: LXMFRouter two-phase download state machine

Rename the phase-1 delegate, add the have-set state, the two new actions, and the phase-2 delegate; update the 3 existing download tests and add the new coverage.

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift`
- Test: `Tests/ReTiCANodeTests/LXMFRouterTests.swift`

**Interfaces:**
- Consumes: `state.outboundPropagationNode`, `state.directLinks[pn]` (`LinkStatus.active(linkID:)`), the existing `establish`/`pendingDownloadFromPN` machinery.
- Produces (for P2b): `LXMFRouter.Action.offeredMessageList(transientIds: [Data])`, `LXMFRouter.Action.messagesDownloaded(transientIds: [Data])`, `LXMFRouter.Action.Delegate.requestMessageList(linkID: Data)` (renamed), `LXMFRouter.Action.Delegate.requestMessages(linkID: Data, wants: [Data], haves: [Data])`, `LXMFRouter.State.downloadedTransientIds`.

- [ ] **Step 1: Add the `downloadedTransientIds` state.**

In `State`, immediately after `var pendingDownloadFromPN: Bool = false`, add:

```swift
        /// Client "have" set: transient_ids already downloaded from a PN. Drives the wants/haves split on
        /// the next offer (wants = offered we lack; haves = offered we have → PN purges). Unbounded for now.
        public var downloadedTransientIds: Set<Data> = []
```

- [ ] **Step 2: Add the two new actions.**

In the `Action` enum, immediately after `case syncFromPropagationNode`, add:

```swift
        case offeredMessageList(transientIds: [Data])
        case messagesDownloaded(transientIds: [Data])
```

- [ ] **Step 3: Rename the phase-1 delegate and add the phase-2 delegate.**

In `Action.Delegate`, change `case requestMessageDownload(linkID: Data)` to:

```swift
            case requestMessageList(linkID: Data)
            case requestMessages(linkID: Data, wants: [Data], haves: [Data])
```

- [ ] **Step 4: Update the two phase-1 emission sites to the renamed delegate.**

In the `.syncFromPropagationNode` handler, change:
```swift
                    return .send(.delegate(.requestMessageDownload(linkID: linkID)))
```
to:
```swift
                    return .send(.delegate(.requestMessageList(linkID: linkID)))
```

In the `.linkEstablished` handler's PN-drain block, change:
```swift
                    effects.append(.send(.delegate(.requestMessageDownload(linkID: linkID))))
```
to:
```swift
                    effects.append(.send(.delegate(.requestMessageList(linkID: linkID))))
```

- [ ] **Step 5: Add the `offeredMessageList` and `messagesDownloaded` handlers.**

In the main `switch action`, immediately after the `.syncFromPropagationNode` handler's block (the one ending `return .none` before `case let .linkEstablished`), add:

```swift
            case let .offeredMessageList(offered):
                guard !offered.isEmpty else { return .none }            // empty offer → nothing to fetch
                let wants = offered.filter { !state.downloadedTransientIds.contains($0) }
                let haves = offered.filter { state.downloadedTransientIds.contains($0) }
                guard let pn = state.outboundPropagationNode,
                      case let .active(linkID) = state.directLinks[pn] else { return .none }  // link gone → abort
                return .send(.delegate(.requestMessages(linkID: linkID, wants: wants, haves: haves)))

            case let .messagesDownloaded(transientIds):
                state.downloadedTransientIds.formUnion(transientIds)
                return .none
```

- [ ] **Step 6: Update the 3 existing download tests to the renamed delegate.**

In `Tests/ReTiCANodeTests/LXMFRouterTests.swift`, replace every `requestMessageDownload` with `requestMessageList` in the three tests `routerSyncActiveLinkRequestsDownload`, `routerSyncNoNodeIsNoOp` (comment only), and `routerSyncEstablishesThenRequestsOnLinkEstablished` / `routerSyncFlagClearedNoDoubleRequest` (assertions + comment). Do a scoped rename — every occurrence of the identifier `requestMessageDownload` in this file becomes `requestMessageList`. Assertions and structure are otherwise unchanged.

- [ ] **Step 7: Run the renamed tests; confirm green.**

Run: `swift test --filter routerSync`
Expected: all four `routerSync*` tests PASS.

- [ ] **Step 8: Write the new phase-2 tests.**

Append to `Tests/ReTiCANodeTests/LXMFRouterTests.swift`:

```swift
// MARK: - Propagation download two-phase offer/get (P2a)

/// Phase-2: an offered list with nothing yet downloaded → request all of them as `wants`, no `haves`.
@Test @MainActor func routerOfferedListRequestsAllWantsWhenNoneHeld() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    let id1 = Data(repeating: 0x11, count: 32); let id2 = Data(repeating: 0x22, count: 32)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.directLinks[pn] = .active(linkID: linkID)
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.offeredMessageList(transientIds: [id1, id2]))
    await store.receive { action in
        if case let .delegate(.requestMessages(lid, wants, haves)) = action {
            #expect(lid == linkID); #expect(wants == [id1, id2]); #expect(haves == []); return true
        }
        return false
    }
}

/// Phase-2 with a have-set: a previously downloaded id moves from `wants` to `haves` (for PN purge).
@Test @MainActor func routerOfferedListSplitsWantsAndHaves() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    let id1 = Data(repeating: 0x11, count: 32); let id2 = Data(repeating: 0x22, count: 32)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.directLinks[pn] = .active(linkID: linkID)
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.messagesDownloaded(transientIds: [id1]))
    #expect(store.state.downloadedTransientIds.contains(id1))
    await store.send(.offeredMessageList(transientIds: [id1, id2]))
    await store.receive { action in
        if case let .delegate(.requestMessages(_, wants, haves)) = action {
            #expect(wants == [id2]); #expect(haves == [id1]); return true
        }
        return false
    }
}

/// An empty offer → sync done, no phase-2 request.
@Test @MainActor func routerEmptyOfferedListRequestsNothing() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.directLinks[pn] = .active(linkID: linkID)
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.offeredMessageList(transientIds: []))
    store.exhaustivity = .on   // a stray requestMessages would fail teardown
}

/// No active PN link (offer arrived after the link dropped) → abort, no phase-2 request.
@Test @MainActor func routerOfferedListWithoutActiveLinkAborts() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let id1 = Data(repeating: 0x11, count: 32)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn                 // configured, but no active link
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.offeredMessageList(transientIds: [id1]))
    store.exhaustivity = .on   // a stray requestMessages would fail teardown
}
```

- [ ] **Step 9: Run the new tests; confirm green.**

Run: `swift test --filter routerOffered`
Then: `swift test --filter routerEmptyOfferedListRequestsNothing`
Expected: all PASS.

- [ ] **Step 10: Mutation-verify (one at a time, revert between each).**

- Mutation A — invert the split: in `offeredMessageList`, swap the two filter predicates (`wants` uses `contains`, `haves` uses `!contains`). Run `swift test --filter routerOfferedListSplitsWantsAndHaves` → must FAIL (wants/haves swapped). Revert → PASS.
- Mutation B — drop the have-set update: in `messagesDownloaded`, replace the body with `return .none` (no `formUnion`). Run `swift test --filter routerOfferedListSplitsWantsAndHaves` → must FAIL (`id1` no longer tracked → it stays in `wants`). Revert → PASS.

- [ ] **Step 11: Run the full LXMFRouter suite; confirm no regressions.**

Run: `swift test --filter LXMFRouterTests`
Expected: all PASS (the rename touched no other behavior).

- [ ] **Step 12: Commit.**

Write the message to `/tmp/ReTiCA/commit-msg-p2a-task1.txt` (verbatim trailers), then:

```bash
git add Sources/ReTiCANode/LXMFRouter.swift Tests/ReTiCANodeTests/LXMFRouterTests.swift
git commit -F /tmp/ReTiCA/commit-msg-p2a-task1.txt
```

Suggested subject: `feat: LXMF propagation P2a — LXMFRouter two-phase download state machine`

---

## Self-Review

**Spec coverage:**
- `downloadedTransientIds` have-set → Task 1 Step 1. ✅
- Rename `requestMessageDownload → requestMessageList` (delegate + 2 emission sites + 3 tests) → Steps 3, 4, 6. ✅
- `offeredMessageList` → wants/haves split → `requestMessages` phase-2 delegate → Steps 2, 3, 5. ✅
- `messagesDownloaded` → have-set `formUnion` → Steps 2, 5. ✅
- Order preserved (filter on offered array) → Step 5. ✅
- Empty-offer and no-active-link guards → Step 5, tests Step 8. ✅
- No transport / decryption / msgpack / max_messages / retain → absent by construction; Global Constraints call it out. ✅

**Placeholder scan:** none — all steps carry concrete code or exact commands.

**Type consistency:** `offeredMessageList(transientIds: [Data])`, `messagesDownloaded(transientIds: [Data])`, `requestMessageList(linkID: Data)`, `requestMessages(linkID: Data, wants: [Data], haves: [Data])`, `downloadedTransientIds: Set<Data>`, `LinkStatus.active(linkID:)`, `state.outboundPropagationNode` all match the current `LXMFRouter.swift` surface. New tests mirror the existing `routerSync*` harness (`initial.directLinks[pn] = .active(linkID:)`, `store.exhaustivity = .off`).
