# LXMF-4d-2b: Router PROPAGATED Orchestration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `PROPAGATED` send path to `LXMFRouter`: link to a configured `outboundPropagationNode` and transfer an app-built `propagationPacked` as a Resource, reusing the direct link machinery keyed on the PN hash.

**Architecture:** Extend the `LXMFRouter` reducer (ReTiCANode). A parallel `propagationQueue` (drained alongside the direct queue in `.linkEstablished`) keeps the direct queue's type unchanged — so existing direct/opportunistic tests are untouched. `ResendInfo.propagated` carries the PN hash + the opaque `propagationPacked`; retries re-send the same bytes. Establish/retry/close/idle are all reused from 4c.

**Tech Stack:** Swift, The Composable Architecture (TCA), swift-testing (`@Test`), SwiftPM.

## Global Constraints

- Commit directly to `main`; no feature branch, no finishing-a-development-branch merge dance.
- No compound shell commands: no `|` chains, `&&`, `||`, `;`, `$(...)`-feeding, `xargs`, or inlining scripts into interpreters. One command per Bash call. A single `>` redirect is allowed. Never use echo/printf/heredoc to WRITE source files (use Write/Edit).
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new test; apply the mutations one at a time.
- Prefer non-exhaustive TCA tests (`store.exhaustivity = .off`) asserting outcomes; assert absence of a stray delegate by flipping `.on` last (only where no timer is left in flight — a `sendPropagated` arms a long-lived idle timer, like `sendDirect`, so do not flip `.on` after one).
- The router moves `propagationPacked` as opaque bytes; tests use an arbitrary `Data` and assert the router carries those exact bytes through (no ciphertext semantics here — those were pinned in 4d-1/4d-2a).
- Commit trailers (exact); the `;` means author the message with the Write tool to `/tmp/ReTiCA/` and `git commit -F`, never `-m`:
  - `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`

---

### Task 1: PROPAGATED send path in `LXMFRouter`

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` (State lines 17-33; `ResendInfo` lines 38-41; `PropagationItem` near line 42; `Action` lines 44-54; `Delegate` lines 56-66; `.send`-adjacent new cases after line 143; `.linkEstablished` lines 145-157; `.linkClosed` lines 159-169; `.retryDue` `.propagated` case after line 209)
- Modify (add tests): `Tests/ReTiCANodeTests/LXMFRouterTests.swift` (append a new MARK section)

**Interfaces:**
- Consumes (existing): `LinkStatus.active(linkID:)`/`.establishing`, `directLinks`, `knownPaths`, `pendingDeliveries`, the nested `arm`/`retryTimer`/`idleTimer`/`establish` helpers, `LXMFDelivery.retryWaitSeconds`/`.maxAttempts`, `LXMessage.hash`, the `makeMessage(source:recipientIdentityHash:content:)` test helper.
- Produces: `State.outboundPropagationNode: Data?`, `State.propagationQueue: [Data: [PropagationItem]]`, `PropagationItem`, `ResendInfo.propagated(destinationHash:data:)`, `Action.setOutboundPropagationNode(Data?)`, `Action.sendViaPropagation(message:propagationPacked:)`, `Action.Delegate.sendPropagated(linkID:propagationPacked:)`.

- [ ] **Step 1: Write the headline failing test (no PN → deliveryFailed)**

Append to `Tests/ReTiCANodeTests/LXMFRouterTests.swift`:

```swift
// MARK: - LXMF-4d-2b PROPAGATED outbound

@Test @MainActor func routerPropagationFailsWithNoNode() async {
    let msg = makeMessage(source: Identity(), content: "prop")
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.sendViaPropagation(message: msg, propagationPacked: Data("container".utf8)))
    await store.receive { action in
        if case let .delegate(.deliveryFailed(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
}
```

- [ ] **Step 2: Run it — verify it fails**

Run: `swift test --filter LXMFRouterTests.routerPropagationFailsWithNoNode`
Expected: BUILD FAILURE — `.sendViaPropagation` / `.sendPropagated` don't exist yet. Expected red.

- [ ] **Step 3: Add state, types, action, and delegate**

In `Sources/ReTiCANode/LXMFRouter.swift`:

State — after `pendingDeliveries` (line 31), add:

```swift
        /// The configured store-and-forward propagation node (all PROPAGATED sends link to it).
        public var outboundPropagationNode: Data? = nil
        /// PN hash → propagated messages queued until a link to the PN becomes active.
        var propagationQueue: [Data: [PropagationItem]] = [:]
```

`ResendInfo` — add after the `.direct` case (line 40):

```swift
        case propagated(destinationHash: Data, data: Data)
```

After the `PendingDelivery` struct (line 42), add:

```swift
    public struct PropagationItem: Equatable { public var messageHash: Data; public var propagationPacked: Data }
```

`Action` — after `case send(...)` (line 47), add:

```swift
        case setOutboundPropagationNode(Data?)
        case sendViaPropagation(message: LXMessage, propagationPacked: Data)
```

`Action.Delegate` — after `case sendDirect(...)` (line 62), add:

```swift
            case sendPropagated(linkID: Data, propagationPacked: Data)
```

- [ ] **Step 4: Add the `.setOutboundPropagationNode` and `.sendViaPropagation` reducer cases**

In the `switch action`, after the `.send` case closes (after line 143), add:

```swift
            case let .setOutboundPropagationNode(pn):
                state.outboundPropagationNode = pn
                return .none

            case let .sendViaPropagation(message, propagationPacked):
                guard let pn = state.outboundPropagationNode else {
                    return .send(.delegate(.deliveryFailed(messageHash: message.hash)))
                }
                if case let .active(linkID) = state.directLinks[pn] {
                    arm(&state, message.hash, .propagated(destinationHash: pn, data: propagationPacked))
                    return .merge(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: propagationPacked))),
                                  retryTimer(message.hash, LXMFDelivery.retryWaitSeconds),
                                  idleTimer(pn))
                }
                state.propagationQueue[pn, default: []].append(
                    PropagationItem(messageHash: message.hash, propagationPacked: propagationPacked))
                if state.directLinks[pn] == nil {
                    return establish(&state, pn)
                }
                return .none
```

- [ ] **Step 5: Drain the propagation queue in `.linkEstablished`**

Replace the `.linkEstablished` case (lines 145-157) with:

```swift
            case let .linkEstablished(dest, linkID):
                state.directLinks[dest] = .active(linkID: linkID)
                let queued = state.outboundQueue[dest] ?? []
                state.outboundQueue[dest] = nil
                let propQueued = state.propagationQueue[dest] ?? []
                state.propagationQueue[dest] = nil
                var effects: [Effect<Action>] = []
                for m in queued {
                    let asResource = m.directRepresentation == .resource
                    arm(&state, m.hash, .direct(destinationHash: dest, data: m.packed, asResource: asResource))
                    effects.append(.send(.delegate(.sendDirect(linkID: linkID, data: m.packed, asResource: asResource))))
                    effects.append(retryTimer(m.hash, LXMFDelivery.retryWaitSeconds))
                }
                for item in propQueued {
                    arm(&state, item.messageHash, .propagated(destinationHash: dest, data: item.propagationPacked))
                    effects.append(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: item.propagationPacked))))
                    effects.append(retryTimer(item.messageHash, LXMFDelivery.retryWaitSeconds))
                }
                if !queued.isEmpty || !propQueued.isEmpty { effects.append(idleTimer(dest)) }
                return effects.isEmpty ? .none : .merge(effects)
```

- [ ] **Step 6: Extend the `.linkClosed` recovery check for propagation**

Replace the `.linkClosed` case (lines 159-169) with:

```swift
            case let .linkClosed(dest):
                state.directLinks[dest] = nil
                let hasPending = state.pendingDeliveries.values.contains {
                    switch $0.resend {
                    case let .direct(d, _, _): return d == dest
                    case let .propagated(d, _): return d == dest
                    case .opportunistic: return false
                    }
                }
                let hasQueued = !(state.outboundQueue[dest]?.isEmpty ?? true)
                    || !(state.propagationQueue[dest]?.isEmpty ?? true)
                if hasPending || hasQueued {
                    return establish(&state, dest)
                }
                return .none
```

- [ ] **Step 7: Add the `.propagated` case to `.retryDue`**

In the `switch pending.resend` inside `.retryDue`, after the `.direct` case (after line 209, before the closing `}` of the switch), add:

```swift
                case let .propagated(destinationHash, data):
                    if case let .active(linkID) = state.directLinks[destinationHash] {
                        return .merge(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: data))),
                                      retryTimer(hash, LXMFDelivery.retryWaitSeconds))
                    }
                    // Link down/re-establishing: no live link; wait and re-check (bounded by maxAttempts).
                    return retryTimer(hash, LXMFDelivery.retryWaitSeconds)
```

- [ ] **Step 8: Run the headline test — verify it passes**

Run: `swift test --filter LXMFRouterTests.routerPropagationFailsWithNoNode`
Expected: PASS.

- [ ] **Step 9: Add the 4 remaining tests**

Append to the `// MARK: - LXMF-4d-2b PROPAGATED outbound` section:

```swift
@Test @MainActor func routerPropagationEstablishesLinkToNode() async {
    let msg = makeMessage(source: Identity(), content: "prop")
    let packed = Data("container".utf8)
    let pn = Data(repeating: 0xBB, count: 16)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.knownPaths.insert(pn)   // path known → establishes directly
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.sendViaPropagation(message: msg, propagationPacked: packed))
    await store.receive { action in
        if case let .delegate(.requestLink(d)) = action { #expect(d == pn); return true }
        return false
    }
    #expect(store.state.directLinks[pn] == .establishing)
    #expect(store.state.propagationQueue[pn]?.count == 1)
    store.exhaustivity = .on   // no sendPropagated yet (no active link); no timer armed → a stray fails teardown
}

@Test @MainActor func routerPropagationDrainsOnLinkEstablished() async {
    let msg = makeMessage(source: Identity(), content: "prop")
    let packed = Data("container-bytes".utf8)
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.knownPaths.insert(pn)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.sendViaPropagation(message: msg, propagationPacked: packed))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    await store.send(.linkEstablished(destinationHash: pn, linkID: linkID))
    await store.receive { action in
        if case let .delegate(.sendPropagated(lid, p)) = action {
            #expect(lid == linkID); #expect(p == packed); return true
        }
        return false
    }
    #expect(store.state.pendingDeliveries[msg.hash]?.attempts == 1)
}

@Test @MainActor func routerPropagationSendsImmediatelyWithActiveLink() async {
    let msg = makeMessage(source: Identity(), content: "prop")
    let packed = Data("container-bytes".utf8)
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.directLinks[pn] = .active(linkID: linkID)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.sendViaPropagation(message: msg, propagationPacked: packed))
    await store.receive { action in
        if case let .delegate(.sendPropagated(lid, p)) = action {
            #expect(lid == linkID); #expect(p == packed); return true
        }
        return false
    }
    #expect(store.state.pendingDeliveries[msg.hash]?.attempts == 1)
}

@Test @MainActor func routerPropagationRetryResendsSameBytes() async {
    let msg = makeMessage(source: Identity(), content: "prop")
    let packed = Data("container-bytes".utf8)
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.directLinks[pn] = .active(linkID: linkID)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.sendViaPropagation(message: msg, propagationPacked: packed))
    await store.receive { if case .delegate(.sendPropagated) = $0 { return true }; return false }
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { action in
        if case let .delegate(.sendPropagated(lid, p)) = action {
            #expect(lid == linkID); #expect(p == packed); return true   // same bytes on retry
        }
        return false
    }
    #expect(store.state.pendingDeliveries[msg.hash]?.attempts == 2)
}
```

- [ ] **Step 10: Run the full router test file — verify all pass**

Run: `swift test --filter LXMFRouterTests`
Expected: PASS — all existing router tests (unaffected — the direct queue type is unchanged) plus the 5 new ones.

- [ ] **Step 11: Mutation verification (one mutation at a time)**

Apply each individually in `Sources/ReTiCANode/LXMFRouter.swift`, run `swift test --filter LXMFRouterTests`, confirm the named test fails, revert, confirm pass, then the next.

1. **No-PN guard removed** — in `.sendViaPropagation`, change the `guard ... else { return .send(.delegate(.deliveryFailed(messageHash: message.hash))) }` to `else { return .none }`.
   → `routerPropagationFailsWithNoNode` FAILS (no `deliveryFailed` arrives; the receive times out).
2. **Immediate-send branch dropped** — in `.sendViaPropagation`, delete the `if case let .active(linkID) = state.directLinks[pn] { … }` block so an active PN link falls through to enqueue.
   → `routerPropagationSendsImmediatelyWithActiveLink` FAILS (no immediate `sendPropagated`).
3. **linkEstablished propagation drain dropped** — delete the `for item in propQueued { … }` loop in `.linkEstablished`.
   → `routerPropagationDrainsOnLinkEstablished` FAILS (no `sendPropagated` after the link establishes).
4. **retryDue propagated resend dropped** — in the `.retryDue` `.propagated` active branch, remove the `.send(.delegate(.sendPropagated(...)))` (return only the timer).
   → `routerPropagationRetryResendsSameBytes` FAILS (no `sendPropagated` on the retry).

After each: revert, re-run, expect PASS before the next.

- [ ] **Step 12: Full test gate**

Run: `swift test`
Expected: PASS. The 4d-2a baseline was 432 passed / 1 pre-existing live-node skip / 0 fail; this slice adds 5 router tests → 437 passed. On a signal-11/signal-10 build flake, run `swift package clean` (single command) and re-run.

- [ ] **Step 13: Commit**

Write the message to `/tmp/ReTiCA/commit-msg-4d2b.txt` with the Write tool (body below), then:

```bash
git add Sources/ReTiCANode/LXMFRouter.swift Tests/ReTiCANodeTests/LXMFRouterTests.swift
```

```bash
git commit -F /tmp/ReTiCA/commit-msg-4d2b.txt
```

Commit message body:

```
feat: LXMF-4d-2b — router PROPAGATED orchestration

Adds the PROPAGATED send path: outboundPropagationNode config +
.sendViaPropagation(message, propagationPacked). No PN → deliveryFailed.
The PN link reuses the direct establish/retry/close/idle machinery keyed
on the PN hash; a separate propagationQueue is drained alongside the
direct queue in .linkEstablished (direct queue type unchanged → no
existing-test ripple). ResendInfo.propagated + retryDue re-send the same
bytes (stable transient_id); .sendPropagated Resource-transfer delegate.
5 new tests.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Self-Review

**Spec coverage:**
- Spec state/types (`outboundPropagationNode`, `propagationQueue`, `PropagationItem`, `ResendInfo.propagated`) → Step 3. ✓
- Spec actions (`setOutboundPropagationNode`, `sendViaPropagation`) + delegate (`sendPropagated`) → Step 3. ✓
- Spec `.sendViaPropagation` (no-PN fail / active-link send / enqueue+establish) → Step 4. ✓
- Spec `.linkEstablished` propagation drain (+ idle-arm condition) → Step 5. ✓
- Spec `.linkClosed` recovery includes propagation queue/pending → Step 6. ✓
- Spec `.retryDue` `.propagated` (live-link resend / wait) → Step 7. ✓
- Spec test 1 (no PN) → `routerPropagationFailsWithNoNode`, Step 1. ✓
- Spec test 2 (establish + queue) → `routerPropagationEstablishesLinkToNode`, Step 9. ✓
- Spec test 3 (drain on linkEstablished) → `routerPropagationDrainsOnLinkEstablished`, Step 9. ✓
- Spec test 4 (active link immediate) → `routerPropagationSendsImmediatelyWithActiveLink`, Step 9. ✓
- Spec test 5 (retry same bytes) → `routerPropagationRetryResendsSameBytes`, Step 9. ✓
- Spec "no direct-queue type change → no existing-test ripple" → `outboundQueue` untouched; `.linkClosed` switch preserves prior direct/opportunistic results. ✓

**Placeholder scan:** none — every code step shows exact code.

**Type consistency:** `ResendInfo.propagated(destinationHash:data:)` is created in `.sendViaPropagation` and `.linkEstablished` and destructured in `.retryDue` and `.linkClosed` with matching labels. `PropagationItem(messageHash:propagationPacked:)` created in `.sendViaPropagation`, read in `.linkEstablished`. `Delegate.sendPropagated(linkID:propagationPacked:)` emitted in `.sendViaPropagation`/`.linkEstablished`/`.retryDue` and matched in all 5 tests. `Action.sendViaPropagation(message:propagationPacked:)` matches the test call sites.
