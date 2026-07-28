# LXMF-4c-2: Path-Request on No-Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Before establishing a direct link, if the router has no path to the recipient, request a path first and establish the link only once the path is learned.

**Architecture:** Extend the existing `LXMFRouter` reducer (ReTiCANode). Add a `knownPaths` set and an `.awaitingPath` link state; the direct-send "no active link" branch now chooses `.requestLink` (path known) vs `.requestPath` (path unknown), and a new `.learnedPath` action transitions `.awaitingPath → .establishing`. Event-driven — no new clock, no core/Endpoint/Transport changes.

**Tech Stack:** Swift, The Composable Architecture (TCA), swift-testing (`@Test`), SwiftPM.

## Global Constraints

- Commit directly to `main`; no feature branch, no finishing-a-development-branch merge dance.
- No compound shell commands: no `|` chains, `&&`, `||`, `;`, `$(...)`-feeding, `xargs`, or inlining scripts into interpreters. One command per Bash call. A single `>` redirect is allowed. Never use echo/printf/heredoc to WRITE files (use Write/Edit); redirecting a real command's output to a file is fine.
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test: (a) run pass, (b) mutate production to force fail + confirm fail, (c) revert + confirm pass. If mutations could mask each other, isolate them one at a time.
- Prefer non-exhaustive TCA tests (`store.exhaustivity = .off`) asserting outcomes/behavior, not implementation path. To assert the ABSENCE of a stray delegate, flip `store.exhaustivity = .on` as the last step (isolated store; teardown catches a stray transmit).
- Ed25519 is hedged/randomized: never byte-compare a produced signature (or a packed artifact containing one) — validate instead. Hashes/message-IDs stay deterministic.
- Commit trailers (exact):
  - `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`
  - Commit-message bodies contain `;` in the trailer → author the message with the Write tool to a file in `/tmp/ReTiCA/` and `git commit -F`, never `-m`.

---

### Task 1: Path-request gate on the direct-establish path

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` (LinkStatus enum line 33; State lines 24-28; Action enum lines 41-49; Delegate enum lines 51-59; `.send` direct branch lines 116-121; add a `.learnedPath` case near `.linkClosed` line 137-139)
- Modify (test): `Tests/ReTiCANodeTests/LXMFRouterTests.swift` (reseed 5 existing tests; add 4 new tests)

**Interfaces:**
- Consumes (existing, unchanged): `LXMessage.destinationHash: Data`, `.packed: Data`, `.hash: Data`, `.directRepresentation` (`.packet`/`.resource`), `LXMFRouter.State.directLinks: [Data: LinkStatus]`, `.outboundQueue: [Data: [LXMessage]]`, `LXMessage.deliveryHash(identityHash:) -> Data`, the `makeMessage(source:recipientIdentityHash:content:)` test helper.
- Produces (new, used by the app wiring and later slices):
  - `LXMFRouter.LinkStatus.awaitingPath` (new case; `.establishing`, `.active(linkID:)` unchanged).
  - `LXMFRouter.State.knownPaths: Set<Data>` (public, defaults `[]`).
  - `LXMFRouter.Action.learnedPath(destinationHash: Data)` — app forwards `Endpoint.pathLearned`.
  - `LXMFRouter.Action.Delegate.requestPath(destinationHash: Data)` — app wires to `Transport.requestPath`.

#### Behavior being added (reference)

RNS `LXMRouter.process_outbound` requests a path before opening a link when none is known, and opens the link once the path resolves (`LXMRouter.py:2829-2838`). Today `Endpoint.openLink` to a destination with no learned path returns `linkFailed` immediately — this slice makes the router request the path first.

The `.send` direct, no-active-link branch changes from "always `.requestLink`" to:
- `knownPaths.contains(dest)` → `directLinks[dest] = .establishing`, emit `.requestLink(dest)` (unchanged behavior when a path is known).
- else → `directLinks[dest] = .awaitingPath`, emit `.requestPath(dest)`.

The existing establish-once guard (`directLinks[dest] == nil`) now also means request-path-once: a second direct send while `.awaitingPath` or `.establishing` just enqueues.

`.learnedPath(dest)` inserts into `knownPaths`; if `directLinks[dest] == .awaitingPath`, transition to `.establishing` and emit `.requestLink(dest)`.

**Consequence for existing tests:** five current tests send a direct message with an EMPTY `knownPaths` and assert `.requestLink` + `directLinks[dest] == .establishing`. After this change an empty `knownPaths` yields `.requestPath` + `.awaitingPath` instead. Those tests are about other behaviors (size fallback, queueing, establish-once, retry-arming), so they get a `knownPaths` seed for their destination to keep exercising the known-path branch. This is the honest precondition: "given a path is known, a direct send with no active link requests a link."

- [ ] **Step 1: Write the headline failing test (no path → requests path)**

Add to `Tests/ReTiCANodeTests/LXMFRouterTests.swift`, after the LXMF-4b outbound section (after `routerValidationDependsOnLearnedIdentity`, before `// MARK: - LXMF-4c-1 outbound retry`), a new section:

```swift
// MARK: - LXMF-4c-2 path request on no-path

@Test @MainActor func routerDirectWithNoPathRequestsPath() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))   // no known path
    await store.receive { action in
        if case let .delegate(.requestPath(dest)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    #expect(store.state.directLinks[msg.destinationHash] == .awaitingPath)
    #expect(store.state.outboundQueue[msg.destinationHash]?.count == 1)   // message parked
    store.exhaustivity = .on   // a stray requestLink would fail teardown
}
```

- [ ] **Step 2: Run it — verify it fails to build**

Run: `swift test --filter LXMFRouterTests.routerDirectWithNoPathRequestsPath`
Expected: BUILD FAILURE — `.requestPath`, `.awaitingPath` are undefined. (In SwiftPM a missing symbol fails the whole test target build; that is the expected "red".)

- [ ] **Step 3: Implement the production change**

In `Sources/ReTiCANode/LXMFRouter.swift`:

Extend `LinkStatus` (line 33):

```swift
    public enum LinkStatus: Equatable { case awaitingPath; case establishing; case active(linkID: Data) }
```

Add `knownPaths` to `State` (after the `directLinks` declaration, around line 24):

```swift
        /// destinationHash → we have a learned path to it. Gates direct-link establishment: with no
        /// path, request one first (RNS process_outbound, LXMRouter.py:2829-2838).
        public var knownPaths: Set<Data> = []
```

Add the action (in `Action`, e.g. after `.linkClosed`, line 46):

```swift
        case learnedPath(destinationHash: Data)
```

Add the delegate (in `Action.Delegate`, after `.requestLink`, line 55):

```swift
            case requestPath(destinationHash: Data)
```

Replace the direct-send no-active-link block (current lines 116-121):

```swift
                    state.outboundQueue[dest, default: []].append(message)
                    if state.directLinks[dest] == nil {
                        state.directLinks[dest] = .establishing
                        return .send(.delegate(.requestLink(destinationHash: dest)))
                    }
                    return .none   // a link request is already in flight
```

with:

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

Add the `.learnedPath` case (after the `.linkClosed` case, around line 139):

```swift
            case let .learnedPath(dest):
                state.knownPaths.insert(dest)
                if state.directLinks[dest] == .awaitingPath {
                    state.directLinks[dest] = .establishing
                    return .send(.delegate(.requestLink(destinationHash: dest)))
                }
                return .none
```

- [ ] **Step 4: Run the headline test — verify it passes**

Run: `swift test --filter LXMFRouterTests.routerDirectWithNoPathRequestsPath`
Expected: PASS.

- [ ] **Step 5: Reseed the 5 existing direct-send tests that assumed `.requestLink` on empty `knownPaths`**

Each edit adds a `knownPaths` seed for the destination so the test keeps exercising the known-path (`.requestLink` + `.establishing`) branch. Make exactly these edits in `Tests/ReTiCANodeTests/LXMFRouterTests.swift`:

**(a) `routerFallsBackToDirectWhenOpportunisticTooLarge`** — replace:

```swift
    let big = makeMessage(source: Identity(), content: String(repeating: "x", count: 1000))
    #expect(big.opportunisticFits == false)
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
```

with:

```swift
    let big = makeMessage(source: Identity(), content: String(repeating: "x", count: 1000))
    #expect(big.opportunisticFits == false)
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(big.destinationHash)   // path known → establishes directly
    let store = TestStore(initialState: initial) { LXMFRouter() }
```

**(b) `routerDirectWithNoLinkRequestsAndQueues`** — replace:

```swift
    let msg = makeMessage(source: Identity(), content: "direct")
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
```

with:

```swift
    let msg = makeMessage(source: Identity(), content: "direct")
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(msg.destinationHash)   // path known → establishes directly
    let store = TestStore(initialState: initial) { LXMFRouter() }
```

**(c) `routerLinkEstablishedDrainsQueueAsSendDirect`** — the first store (`store`) does a direct send at the top. Replace:

```swift
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
```

with:

```swift
    var initial1 = LXMFRouter.State()
    initial1.knownPaths.insert(msg.destinationHash)   // path known → establishes directly
    let store = TestStore(initialState: initial1) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
```

(The second store, `store2`, seeds `directLinks[...] = .establishing` directly and sends `.linkEstablished` — no `.send(direct)`, so it needs no `knownPaths` seed.)

**(d) `routerEstablishesLinkOnceForConcurrentSends`** — replace:

```swift
    #expect(m1.destinationHash == m2.destinationHash)   // same recipient delivery destination
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
```

with:

```swift
    #expect(m1.destinationHash == m2.destinationHash)   // same recipient delivery destination
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(m1.destinationHash)   // path known → establishes directly
    let store = TestStore(initialState: initial) { LXMFRouter() }
```

**(e) `routerArmsRetryForDrainedResourceMessage`** — replace:

```swift
    let clock = TestClock()
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: big, desiredMethod: .direct))
```

with:

```swift
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(big.destinationHash)   // path known → establishes directly
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: big, desiredMethod: .direct))
```

- [ ] **Step 6: Add the 3 remaining new tests**

Append these to the `// MARK: - LXMF-4c-2 path request on no-path` section:

```swift
/// After requesting a path, learning it transitions awaitingPath → establishing (emits requestLink);
/// the queued message then drains as sendDirect once the link establishes.
@Test @MainActor func routerLearnedPathTriggersLinkThenDrains() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let linkID = Data(repeating: 0xEE, count: 16)
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestPath) = $0 { return true }; return false }
    #expect(store.state.directLinks[msg.destinationHash] == .awaitingPath)
    await store.send(.learnedPath(destinationHash: msg.destinationHash))
    await store.receive { action in
        if case let .delegate(.requestLink(dest)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    #expect(store.state.directLinks[msg.destinationHash] == .establishing)
    #expect(store.state.knownPaths.contains(msg.destinationHash))
    await store.send(.linkEstablished(destinationHash: msg.destinationHash, linkID: linkID))
    await store.receive { action in
        if case let .delegate(.sendDirect(lid, data, _)) = action {
            #expect(lid == linkID); #expect(data == msg.packed); return true
        }
        return false
    }
}

/// Request-path-once: a second direct send to a still-awaitingPath destination is queued but does NOT
/// emit a second requestPath. (Removing the `directLinks[dest] == nil` guard would fire a second
/// requestPath — an un-received delegate caught by the exhaustive teardown.)
@Test @MainActor func routerRequestsPathOnceWhileAwaitingPath() async {
    let sender = Identity()
    let recipient = Identity().hash
    let m1 = makeMessage(source: sender, recipientIdentityHash: recipient, content: "one")
    let m2 = makeMessage(source: sender, recipientIdentityHash: recipient, content: "two")
    #expect(m1.destinationHash == m2.destinationHash)   // same recipient delivery destination
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.send(message: m1, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestPath) = $0 { return true }; return false }
    #expect(store.state.directLinks[m1.destinationHash] == .awaitingPath)
    await store.send(.send(message: m2, desiredMethod: .direct))   // still awaitingPath → enqueue only
    #expect(store.state.outboundQueue[m1.destinationHash]?.count == 2)   // both queued
    store.exhaustivity = .on   // a stray second requestPath would fail teardown
}

/// learnedPath for a destination with no awaitingPath entry records the path but starts no link
/// machinery (no requestLink, no directLinks entry).
@Test @MainActor func routerUnrelatedLearnedPathIsInert() async {
    let other = LXMessage.deliveryHash(identityHash: Identity().hash)
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.learnedPath(destinationHash: other))
    #expect(store.state.knownPaths.contains(other))   // recorded
    #expect(store.state.directLinks[other] == nil)    // but no link/path machinery started
    store.exhaustivity = .on   // a stray requestLink would fail teardown
}
```

- [ ] **Step 7: Run the full router test file — verify all pass**

Run: `swift test --filter LXMFRouterTests`
Expected: PASS — all existing router tests (reseeded) plus the 4 new ones.

- [ ] **Step 8: Mutation verification (three-step)**

The three new behaviors map to distinct tests via distinct code paths (they do not mask each other), so a single batched mutation run is sound here. Apply all three mutations in `LXMFRouter.swift` at once:

1. In the `.send` direct no-active-link block, force the known-path branch regardless of `knownPaths`: change `if state.knownPaths.contains(dest) {` to `if true {`.
   → breaks `routerDirectWithNoPathRequestsPath` (gets `.requestLink`/`.establishing`, expected `.requestPath`/`.awaitingPath`) and `routerRequestsPathOnceWhileAwaitingPath` (first send emits `.requestLink`, not `.requestPath`).
2. In `.learnedPath`, drop the transition: replace the `if state.directLinks[dest] == .awaitingPath { ... }` block with just `return .none` (keep the `knownPaths.insert`).
   → breaks `routerLearnedPathTriggersLinkThenDrains` (no `.requestLink` after `.learnedPath`).
3. In `.learnedPath`, drop the record: remove `state.knownPaths.insert(dest)`.
   → breaks `routerUnrelatedLearnedPathIsInert` (`knownPaths.contains(other)` false).

Run: `swift test --filter LXMFRouterTests`
Expected: the four named tests FAIL. If any of them still passes, isolate that one mutation (revert the others) and diagnose before continuing.

Then revert all three mutations. Run: `swift test --filter LXMFRouterTests`
Expected: PASS (clean green restored).

- [ ] **Step 9: Full test gate**

Run: `swift test`
Expected: PASS (the 4c-1 baseline was 413 passed / 1 pre-existing live-node skip / 0 fail; this slice adds 4 tests → 417 passed). If a signal-11/signal-10 build flake appears, run `swift package clean` (single command) and re-run.

- [ ] **Step 10: Commit**

Write the commit message to `/tmp/ReTiCA/commit-msg-4c2.txt` with the Write tool (body below), then:

```bash
git add Sources/ReTiCANode/LXMFRouter.swift Tests/ReTiCANodeTests/LXMFRouterTests.swift
```

```bash
git commit -F /tmp/ReTiCA/commit-msg-4c2.txt
```

Commit message body:

```
feat: LXMF-4c-2 — path-request on no-path (direct establish)

Direct outbound now requests a path before opening a link when none is
known: the no-active-link branch chooses requestLink (path known) vs
requestPath (path unknown, parks the message as .awaitingPath), and
.learnedPath transitions .awaitingPath → .establishing + requestLink.
Fixes Endpoint.openLink → linkFailed on no-path. Establish-once now
also means request-path-once. Event-driven, no new clock.

Adds LinkStatus.awaitingPath, State.knownPaths, .learnedPath action,
.requestPath delegate. Reseeds 5 existing direct-send tests (path now a
precondition for requestLink) + 4 new tests.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Deferred (not in this slice)

- Opportunistic-retry path-request (RNS requests a path after `MAX_PATHLESS_TRIES=1` failed opportunistic sends).
- Path-request timeout / give-up (`PATH_REQUEST_WAIT=7`).
- These belong to a later 4c sub-slice; this slice is the direct-establish path check only.

## Self-Review

**Spec coverage:**
- Spec "State + types" (`knownPaths`, `LinkStatus.awaitingPath`) → Task 1 Step 3. ✓
- Spec "Actions" (`.learnedPath`, `.requestPath` delegate) → Step 3. ✓
- Spec "Reducer" (direct no-link branch; `.learnedPath` handler) → Step 3. ✓
- Spec test 1 (known path → establishes directly) → covered by reseeded `routerDirectWithNoLinkRequestsAndQueues` (asserts `.requestLink` + `.establishing`), Step 5(b). ✓
- Spec test 2 (no path → requests path) → `routerDirectWithNoPathRequestsPath`, Step 1. ✓
- Spec test 3 (learnedPath proceeds + drains) → `routerLearnedPathTriggersLinkThenDrains`, Step 6. ✓
- Spec test 4 (establish-once across awaitingPath) → `routerRequestsPathOnceWhileAwaitingPath`, Step 6. ✓
- Spec test 5 (unrelated learnedPath inert) → `routerUnrelatedLearnedPathIsInert`, Step 6. ✓
- Spec "No cross-val" → no fixture task. ✓

**Placeholder scan:** none — every code step shows exact code.

**Type consistency:** `LinkStatus.awaitingPath`, `State.knownPaths: Set<Data>`, `Action.learnedPath(destinationHash:)`, `Delegate.requestPath(destinationHash:)` used identically across production and all tests. Reducer references `state.knownPaths`, `state.directLinks[dest] == .awaitingPath` consistently.
