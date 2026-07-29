# LXMF-4d-4: Client Inbound Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The router can request a message download from its configured propagation node: link to the PN and emit a download-request delegate.

**Architecture:** Extend `LXMFRouter` (ReTiCANode). Reuses `outboundPropagationNode` + the `directLinks`/`establish` machinery keyed on the PN. A `pendingDownloadFromPN` flag defers the request until the link is active; `.linkEstablished` drains it. The receive side reuses 4a (app opens returned entries and feeds `.received`).

**Tech Stack:** Swift, The Composable Architecture (TCA), swift-testing (`@Test`).

## Global Constraints

- Commit directly to `main`; no feature branch, no finishing-a-development-branch merge dance.
- No compound shell commands: no `|` chains, `&&`, `||`, `;`, `$(...)`-feeding, `xargs`, or inlining scripts into interpreters. One command per Bash call. A single `>` redirect is allowed. Never use echo/printf/heredoc to WRITE source files (use Write/Edit).
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new test; absence-of-delegate via flipping `.on` last (sync requests arm no timers, so `.on` teardown is safe in those tests).
- Commit trailers (exact); the `;` means author the message with the Write tool to `/tmp/ReTiCA/` and `git commit -F`, never `-m`:
  - `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`

---

### Task 1: Client sync request orchestration in `LXMFRouter`

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` (State after line 35; Action after line 55; Delegate after line 71; new `.syncFromPropagationNode` case after the `.sendViaPropagation` case ~line 173; `.linkEstablished` ~lines 175-194)
- Modify (add tests): `Tests/ReTiCANodeTests/LXMFRouterTests.swift` (append a new MARK section)

**Interfaces:**
- Consumes: `outboundPropagationNode`, `directLinks`, `LinkStatus.active(linkID:)`, the `establish(&state, dest)` helper, `makeMessage`.
- Produces: `State.pendingDownloadFromPN: Bool`, `Action.syncFromPropagationNode`, `Action.Delegate.requestMessageDownload(linkID: Data)`.

- [ ] **Step 1: Write the headline failing test (active link → requests download)**

Append to `Tests/ReTiCANodeTests/LXMFRouterTests.swift`:

```swift
// MARK: - LXMF-4d-4 client inbound sync

@Test @MainActor func routerSyncActiveLinkRequestsDownload() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.directLinks[pn] = .active(linkID: linkID)
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.syncFromPropagationNode)
    await store.receive { action in
        if case let .delegate(.requestMessageDownload(lid)) = action { #expect(lid == linkID); return true }
        return false
    }
    #expect(store.state.pendingDownloadFromPN == false)
}
```

- [ ] **Step 2: Run it — verify it fails**

Run: `swift test --filter LXMFRouterTests.routerSyncActiveLinkRequestsDownload`
Expected: BUILD FAILURE — `.syncFromPropagationNode` / `.requestMessageDownload` don't exist yet. Expected red.

- [ ] **Step 3: Add state, action, and delegate**

In `Sources/ReTiCANode/LXMFRouter.swift`:

State — after `propagationQueue` (line 35), add:

```swift
        /// Set when a sync was requested but the PN link is not yet active; drained on `.linkEstablished`.
        var pendingDownloadFromPN: Bool = false
```

`Action` — after `case sendViaPropagation(...)` (line 55), add:

```swift
        case syncFromPropagationNode
```

`Action.Delegate` — after `case sendPropagated(...)` (line 71), add:

```swift
            case requestMessageDownload(linkID: Data)
```

- [ ] **Step 4: Add the `.syncFromPropagationNode` reducer case**

After the `.sendViaPropagation` case closes (after its `return .none`, ~line 173), add:

```swift
            case .syncFromPropagationNode:
                guard let pn = state.outboundPropagationNode else { return .none }
                if case let .active(linkID) = state.directLinks[pn] {
                    return .send(.delegate(.requestMessageDownload(linkID: linkID)))
                }
                state.pendingDownloadFromPN = true
                if state.directLinks[pn] == nil {
                    return establish(&state, pn)
                }
                return .none
```

- [ ] **Step 5: Drain the pending download in `.linkEstablished`**

In the `.linkEstablished` case, immediately before the final `return effects.isEmpty ? .none : .merge(effects)` (line 194), add:

```swift
                if dest == state.outboundPropagationNode, state.pendingDownloadFromPN {
                    state.pendingDownloadFromPN = false
                    effects.append(.send(.delegate(.requestMessageDownload(linkID: linkID))))
                }
```

(The idle-arm condition on the line above is unchanged — a download-only link's idle teardown is app-managed, per the spec.)

- [ ] **Step 6: Run the headline test — verify it passes**

Run: `swift test --filter LXMFRouterTests.routerSyncActiveLinkRequestsDownload`
Expected: PASS.

- [ ] **Step 7: Add the 3 remaining tests**

Append to the `// MARK: - LXMF-4d-4 client inbound sync` section:

```swift
@Test @MainActor func routerSyncNoNodeIsNoOp() async {
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.syncFromPropagationNode)
    #expect(store.state.pendingDownloadFromPN == false)
    store.exhaustivity = .on   // no PN → no requestLink / requestMessageDownload; a stray fails teardown
}

@Test @MainActor func routerSyncEstablishesThenRequestsOnLinkEstablished() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.knownPaths.insert(pn)   // path known → establishes directly
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.syncFromPropagationNode)
    await store.receive { action in
        if case let .delegate(.requestLink(d)) = action { #expect(d == pn); return true }
        return false
    }
    #expect(store.state.pendingDownloadFromPN == true)
    await store.send(.linkEstablished(destinationHash: pn, linkID: linkID))
    await store.receive { action in
        if case let .delegate(.requestMessageDownload(lid)) = action { #expect(lid == linkID); return true }
        return false
    }
    #expect(store.state.pendingDownloadFromPN == false)
}

@Test @MainActor func routerSyncFlagClearedNoDoubleRequest() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.knownPaths.insert(pn)
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.syncFromPropagationNode)
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    await store.send(.linkEstablished(destinationHash: pn, linkID: linkID))
    await store.receive { if case .delegate(.requestMessageDownload) = $0 { return true }; return false }
    // A second establish (e.g. link re-open) must NOT re-request the download — the flag was cleared.
    await store.send(.linkEstablished(destinationHash: pn, linkID: linkID))
    #expect(store.state.pendingDownloadFromPN == false)
    store.exhaustivity = .on   // a stray requestMessageDownload would fail teardown
}
```

- [ ] **Step 8: Run the full router test file — verify all pass**

Run: `swift test --filter LXMFRouterTests`
Expected: PASS — existing router tests (unaffected) plus the 4 new sync tests.

- [ ] **Step 9: Mutation verification (one mutation at a time)**

Apply each individually in `Sources/ReTiCANode/LXMFRouter.swift`, run `swift test --filter LXMFRouterTests`, confirm the named test fails, revert, confirm pass, then the next.

1. **Active-link branch dropped** — in `.syncFromPropagationNode`, delete the `if case let .active(linkID) = state.directLinks[pn] { return … }` block (fall through to set the flag).
   → `routerSyncActiveLinkRequestsDownload` FAILS (no immediate `requestMessageDownload`).
2. **linkEstablished download-drain dropped** — delete the `if dest == state.outboundPropagationNode, state.pendingDownloadFromPN { … }` block.
   → `routerSyncEstablishesThenRequestsOnLinkEstablished` FAILS (no `requestMessageDownload` after the link establishes).
3. **Flag not cleared** — in the `.linkEstablished` download-drain, remove `state.pendingDownloadFromPN = false`.
   → `routerSyncFlagClearedNoDoubleRequest` FAILS (the second `.linkEstablished` re-emits `requestMessageDownload`, caught by the `.on` teardown); `routerSyncEstablishesThenRequestsOnLinkEstablished` also FAILS (its `#expect(pendingDownloadFromPN == false)`).
4. **No-PN guard weakened** — in `.syncFromPropagationNode`, change `guard let pn = state.outboundPropagationNode else { return .none }` to `guard let pn = state.outboundPropagationNode else { return .send(.delegate(.requestMessageDownload(linkID: Data()))) }`.
   → `routerSyncNoNodeIsNoOp` FAILS (a stray `requestMessageDownload` is caught by the `.on` teardown).

After each: revert, re-run, expect PASS before the next.

- [ ] **Step 10: Full test gate**

Run: `swift test`
Expected: PASS. The 4d-3 baseline was 442 passed / 1 pre-existing live-node skip / 0 fail; this slice adds 4 router tests → 446 passed. On a signal-11/signal-10 build flake, run `swift package clean` (single command) and re-run.

- [ ] **Step 11: Commit**

Write the message to `/tmp/ReTiCA/commit-msg-4d4.txt` with the Write tool (body below), then:

```bash
git add Sources/ReTiCANode/LXMFRouter.swift Tests/ReTiCANodeTests/LXMFRouterTests.swift
```

```bash
git commit -F /tmp/ReTiCA/commit-msg-4d4.txt
```

Commit message body:

```
feat: LXMF-4d-4 — client inbound sync (request orchestration)

Adds .syncFromPropagationNode: with an active PN link, emit
.requestMessageDownload(linkID); otherwise set pendingDownloadFromPN and
establish the link (reusing the path-aware establish), draining the
request in .linkEstablished. The receive side reuses 4a (the app opens
returned entries via 4d-2a open and feeds .received). 4 new tests.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Self-Review

**Spec coverage:**
- Spec state `pendingDownloadFromPN`, action `syncFromPropagationNode`, delegate `requestMessageDownload` → Step 3. ✓
- Spec `.syncFromPropagationNode` (no PN → .none / active → requestMessageDownload / else flag + establish) → Step 4. ✓
- Spec `.linkEstablished` download-drain (gated on `dest == outboundPropagationNode` + flag; clears flag) → Step 5. ✓
- Spec test 1 (no PN no-op) → `routerSyncNoNodeIsNoOp`, Step 7. ✓
- Spec test 2 (active link) → `routerSyncActiveLinkRequestsDownload`, Step 1. ✓
- Spec test 3 (establish then request) → `routerSyncEstablishesThenRequestsOnLinkEstablished`, Step 7. ✓
- Spec test 4 (flag cleared) → `routerSyncFlagClearedNoDoubleRequest`, Step 7. ✓
- Spec "receive reuses 4a" → no new receive code (documented); optional test 5 omitted (existing 4a behavior). ✓

**Placeholder scan:** none.

**Type consistency:** `Action.syncFromPropagationNode` (no payload) and `Delegate.requestMessageDownload(linkID:)` match the test call sites; `pendingDownloadFromPN: Bool` read/written consistently in `.syncFromPropagationNode` and `.linkEstablished`. The `.linkEstablished` insertion uses the in-scope `dest`/`linkID`/`effects`/`state`.
