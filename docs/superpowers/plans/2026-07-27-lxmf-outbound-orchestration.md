# LXMF-4b: Core Outbound Orchestration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `LXMFRouter` with the happy-path send side — method selection (with opportunistic→direct size fallback), direct-link establish/reuse/queue-until-up, and driving the send via delegates.

**Architecture:** A pure `LXMessage` size helper (`encryptedPacketMDU` + `opportunisticFits`, cross-validated) + an outbound extension to the `LXMFRouter` reducer (new `directLinks`/`outboundQueue` state; `.send`/`.linkEstablished`/`.linkClosed` actions; `.sendOpportunistic`/`.requestLink`/`.sendDirect` delegates the app wires to Endpoint). Retries/timing/path-requests are LXMF-4c.

**Tech Stack:** Swift, The Composable Architecture, Swift Testing, genuine `lxmf 1.1.0` for the constant cross-val.

## Global Constraints

- Commit directly to `main`; no feature branch.
- No compound shell commands (no `&&`, `||`, `;`, `xargs`, inline interpreter scripts). One command per Bash call. A single `>` redirect allowed. Never use echo/printf/heredoc to write files — use editor tools.
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test.
- TCA tests non-exhaustive (`store.exhaustivity = .off`), asserting outcomes; "no delegate" assertions via flip-`.on`-last.
- Cross-val fixtures MUST derive from genuine LXMF; reuse/extend the committed `lxmf_fixtures.json` (regeneration churns it — LXMF-1/2/3 cross-vals re-derive and still pass; confirm).
- Signatures validated, never byte-compared (`ed25519-hedged-nondeterministic`).
- New production: `LXMessage.encryptedPacketMDU`/`opportunisticFits` (ReTiCA, in `LXMessage+Opportunistic.swift`) + `LXMFRouter` outbound extension (ReTiCANode). No Endpoint/Transport changes.
- Wire pin (proven): opportunistic fits ⟺ `opportunisticPayload.count <= ENCRYPTED_PACKET_MDU`; `ENCRYPTED_PACKET_MDU = 391`. DIRECT sends whole `packed`; opportunistic sends `opportunisticPayload` (`packed.dropFirst(16)`).
- Build gotcha: signal-11/10/SIGILL → `swift package clean` then retry.
- Commit trailers, exactly:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```

**Spec:** `docs/superpowers/specs/2026-07-27-lxmf-outbound-orchestration-design.md`
**Base:** this plan's own commit (verify with `git log --oneline <planCommit>..HEAD`, never `HEAD~1`).

---

## File Structure

- **Modify** `Sources/ReTiCA/LXMF/LXMessage+Opportunistic.swift` — add `encryptedPacketMDU` + `opportunisticFits`.
- **Modify** `Tests/ReTiCATests/LXMessageTests.swift` — `opportunisticFits` unit tests.
- **Modify** `Tests/ReTiCATests/Vectors/{generate_lxmf_fixtures.py, LXMFVectorFixtures.swift, LXMessageCrossValidationTests.swift}` (+ regenerate `lxmf_fixtures.json`) — `encrypted_packet_mdu` cross-val.
- **Modify** `Sources/ReTiCANode/LXMFRouter.swift` — outbound state/actions/delegates/reducer.
- **Modify** `Tests/ReTiCANodeTests/LXMFRouterTests.swift` — outbound reducer tests.

---

## Task 1: `encryptedPacketMDU` + `opportunisticFits` + cross-val

**Files:**
- Modify: `Sources/ReTiCA/LXMF/LXMessage+Opportunistic.swift`
- Test: `Tests/ReTiCATests/LXMessageTests.swift`, `Tests/ReTiCATests/Vectors/*`

**Interfaces:**
- Produces: `LXMessage.encryptedPacketMDU: Int`, `LXMessage.opportunisticFits: Bool`. Task 2 uses `opportunisticFits`.

- [ ] **Step 1: Write the failing unit tests**

Add to `Tests/ReTiCATests/LXMessageTests.swift`:

```swift
@Test func opportunisticFitsSmallNotLarge() {
    let source = Identity()
    let destHash = LXMessage.deliveryHash(identityHash: Identity().hash)
    let small = LXMessage.create(source: source, destinationHash: destHash,
                                 timestamp: 1700000000.5, title: Data(), content: Data("hi".utf8))
    #expect(small.opportunisticPayload.count <= LXMessage.encryptedPacketMDU)
    #expect(small.opportunisticFits == true)
    let large = LXMessage.create(source: source, destinationHash: destHash,
                                 timestamp: 1700000000.5, title: Data(), content: Data(repeating: 0x41, count: 1000))
    #expect(large.opportunisticPayload.count > LXMessage.encryptedPacketMDU)
    #expect(large.opportunisticFits == false)
}

/// Boundary at exactly encryptedPacketMDU (opportunisticPayload.count == MDU → fits; +1 → not).
@Test func opportunisticFitsBoundary() {
    let source = Identity()
    let destHash = LXMessage.deliveryHash(identityHash: Identity().hash)
    func msg(_ n: Int) -> LXMessage {
        LXMessage.create(source: source, destinationHash: destHash, timestamp: 1700000000.5,
                         title: Data(), content: Data(repeating: 0x41, count: n))
    }
    let probeLen = 300   // bin16 range → +1 content == +1 opportunisticPayload byte
    let atMduLen = probeLen + (LXMessage.encryptedPacketMDU - msg(probeLen).opportunisticPayload.count)
    let atMdu = msg(atMduLen)
    #expect(atMdu.opportunisticPayload.count == LXMessage.encryptedPacketMDU)
    #expect(atMdu.opportunisticFits == true)
    let overMdu = msg(atMduLen + 1)
    #expect(overMdu.opportunisticPayload.count == LXMessage.encryptedPacketMDU + 1)
    #expect(overMdu.opportunisticFits == false)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "opportunisticFits" 2>&1 | tail -20`
Expected: compile failure — `encryptedPacketMDU`/`opportunisticFits` don't exist.

- [ ] **Step 3: Implement the helper**

In `Sources/ReTiCA/LXMF/LXMessage+Opportunistic.swift`, add to the `extension LXMessage`:

```swift
    /// Max plaintext of a single opportunistic encrypted packet (RNS `ENCRYPTED_PACKET_MDU`, = 391).
    public static let encryptedPacketMDU = 391

    /// True if this message fits a single opportunistic packet (else DIRECT is required). Reference LXMF
    /// falls back opportunistic→direct when `content_size > ENCRYPTED_PACKET_MAX_CONTENT`, which reduces
    /// exactly to `opportunisticPayload.count <= ENCRYPTED_PACKET_MDU` (LXMessage.py:397-401).
    public var opportunisticFits: Bool {
        opportunisticPayload.count <= LXMessage.encryptedPacketMDU
    }
```

- [ ] **Step 4: Run the unit tests to verify they pass**

Run: `swift test --filter "opportunisticFits" 2>&1 | tail -20`
Expected: both PASS.

- [ ] **Step 5: Add the cross-val**

In `Tests/ReTiCATests/Vectors/generate_lxmf_fixtures.py`, add to the emitted dict:

```python
    "encrypted_packet_mdu": LXMF.LXMessage.ENCRYPTED_PACKET_MDU,
```

Regenerate: `/Users/ell/opt/anaconda3/envs/rns/bin/python Tests/ReTiCATests/Vectors/generate_lxmf_fixtures.py > Tests/ReTiCATests/Vectors/lxmf_fixtures.json`
(Expected: exit 0; `encrypted_packet_mdu` present with value 391. The whole fixture is regenerated — LXMF-1/2/3 cross-vals re-derive; confirm in Step 6.)

Add to `Tests/ReTiCATests/Vectors/LXMFVectorFixtures.swift`: `let encryptedPacketMdu: Int` and CodingKey `case encryptedPacketMdu = "encrypted_packet_mdu"`.

Add to `Tests/ReTiCATests/Vectors/LXMessageCrossValidationTests.swift`:

```swift
/// Our encryptedPacketMDU equals genuine RNS/LXMF ENCRYPTED_PACKET_MDU — the opportunistic→direct
/// size-fallback threshold.
@Test func encryptedPacketMduMatchesRns() throws {
    let f = try LXMFVectorFixtures.load()
    #expect(LXMessage.encryptedPacketMDU == f.encryptedPacketMdu)
}
```

- [ ] **Step 6: Run to verify pass (incl. siblings)**

Run: `swift test --filter "encryptedPacketMdu" 2>&1 | tail -10` then `swift test --filter "lxMessage" 2>&1 | tail -10` then `swift test --filter "linkMdu\|fromOpportunistic\|directRepresentation" 2>&1 | tail -10` (run separately if the regex is fiddly).
Expected: `encryptedPacketMduMatchesRns` PASSES; all LXMF-1/2/3 cross-val + unit tests still PASS after regeneration.

- [ ] **Step 7: Mutation-verify (three-step)**

Batch-mutate: (1) `opportunisticPayload.count <= ...` → `<` — `opportunisticFitsBoundary` fails (the exact-mdu message is now `false`). (2) `encryptedPacketMDU = 391` → `390` — `encryptedPacketMduMatchesRns` fails AND `opportunisticFitsBoundary` shifts. Run the filters; confirm each named test fails. Revert both; run again; PASS. (One at a time if batching masks either.)

- [ ] **Step 8: Commit**

```bash
git add Sources/ReTiCA/LXMF/LXMessage+Opportunistic.swift Tests/ReTiCATests/
git commit -F /tmp/ReTiCA/commit-lxmf4b-t1.txt
```

(Message e.g. `feat: LXMF-4b task 1 — encryptedPacketMDU + opportunisticFits + cross-val` plus trailers.)

---

## Task 2: LXMFRouter outbound state machine

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift`
- Test: `Tests/ReTiCANodeTests/LXMFRouterTests.swift`

**Interfaces:**
- Consumes: `LXMessage.opportunisticFits` (Task 1), `opportunisticPayload`/`packed`/`directRepresentation`/`destinationHash` (LXMF-1/2/3), `DeliveryMethod` (4a).
- Produces: `LXMFRouter.LinkStatus`, `State.directLinks`/`.outboundQueue`, actions `.send`/`.linkEstablished`/`.linkClosed`, delegates `.sendOpportunistic`/`.requestLink`/`.sendDirect`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ReTiCANodeTests/LXMFRouterTests.swift` (the `makeMessage` helper exists from 4a):

```swift
// MARK: - LXMF-4b outbound

@Test @MainActor func routerSendsSmallMessageOpportunistically() async {
    let msg = makeMessage(source: Identity(), content: "small")
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.receive { action in
        if case let .delegate(.sendOpportunistic(dest, payload)) = action {
            #expect(dest == msg.destinationHash); #expect(payload == msg.opportunisticPayload); return true
        }
        return false
    }
}

@Test @MainActor func routerFallsBackToDirectWhenOpportunisticTooLarge() async {
    let big = makeMessage(source: Identity(), content: String(repeating: "x", count: 1000))
    #expect(big.opportunisticFits == false)
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.send(message: big, desiredMethod: .opportunistic))   // desired opportunistic, too big
    await store.receive { action in                                        // → treated as direct → requestLink
        if case let .delegate(.requestLink(dest)) = action { #expect(dest == big.destinationHash); return true }
        return false
    }
    #expect(store.state.directLinks[big.destinationHash] == .establishing)
}

@Test @MainActor func routerDirectWithNoLinkRequestsAndQueues() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { action in
        if case let .delegate(.requestLink(dest)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    #expect(store.state.directLinks[msg.destinationHash] == .establishing)
}

@Test @MainActor func routerLinkEstablishedDrainsQueueAsSendDirect() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let linkID = Data(repeating: 0xCD, count: 16)
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    await store.send(.linkEstablished(destinationHash: msg.destinationHash, linkID: linkID))
    await store.receive { action in
        if case let .delegate(.sendDirect(lid, data, asResource)) = action {
            #expect(lid == linkID); #expect(data == msg.packed)
            #expect(asResource == (msg.directRepresentation == .resource)); return true
        }
        return false
    }
    #expect(store.state.directLinks[msg.destinationHash] == .active(linkID: linkID))
}

@Test @MainActor func routerDirectWithActiveLinkSendsImmediately() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let linkID = Data(repeating: 0xAB, count: 16)
    var initial = LXMFRouter.State()
    initial.directLinks[msg.destinationHash] = .active(linkID: linkID)
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { action in
        if case let .delegate(.sendDirect(lid, data, _)) = action {
            #expect(lid == linkID); #expect(data == msg.packed); return true
        }
        return false
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "router" 2>&1 | tail -30`
Expected: compile failure — the new actions/state don't exist.

- [ ] **Step 3: Extend the reducer**

In `Sources/ReTiCANode/LXMFRouter.swift`:

Add the `LinkStatus` type (next to `DeliveryMethod`):
```swift
    public enum LinkStatus: Equatable { case establishing; case active(linkID: Data) }
```

Add to `State`:
```swift
        /// destinationHash → direct-link state (reuse an active link, or one being established).
        public var directLinks: [Data: LinkStatus] = [:]
        /// destinationHash → messages queued until a direct link to it becomes active.
        var outboundQueue: [Data: [LXMessage]] = [:]
```

Add to `Action` (alongside the 4a cases):
```swift
        case send(message: LXMessage, desiredMethod: DeliveryMethod)
        case linkEstablished(destinationHash: Data, linkID: Data)
        case linkClosed(destinationHash: Data)
```

Add to `Action.Delegate` (alongside `messageDelivered`/`duplicateDropped`):
```swift
            case sendOpportunistic(destinationHash: Data, payload: Data)
            case requestLink(destinationHash: Data)
            case sendDirect(linkID: Data, data: Data, asResource: Bool)
```

Add the reducer cases (in the `switch`, before `case .delegate`):
```swift
            case let .send(message, desiredMethod):
                let effective: DeliveryMethod =
                    (desiredMethod == .opportunistic && !message.opportunisticFits) ? .direct : desiredMethod
                switch effective {
                case .opportunistic:
                    return .send(.delegate(.sendOpportunistic(destinationHash: message.destinationHash,
                                                              payload: message.opportunisticPayload)))
                case .direct:
                    let dest = message.destinationHash
                    if case let .active(linkID) = state.directLinks[dest] {
                        return .send(.delegate(.sendDirect(linkID: linkID, data: message.packed,
                                                           asResource: message.directRepresentation == .resource)))
                    }
                    state.outboundQueue[dest, default: []].append(message)
                    if state.directLinks[dest] == nil {
                        state.directLinks[dest] = .establishing
                        return .send(.delegate(.requestLink(destinationHash: dest)))
                    }
                    return .none   // a link request is already in flight
                }

            case let .linkEstablished(dest, linkID):
                state.directLinks[dest] = .active(linkID: linkID)
                let queued = state.outboundQueue[dest] ?? []
                state.outboundQueue[dest] = nil
                let sends = queued.map { m in
                    Effect<Action>.send(.delegate(.sendDirect(linkID: linkID, data: m.packed,
                                                              asResource: m.directRepresentation == .resource)))
                }
                return sends.isEmpty ? .none : .merge(sends)

            case let .linkClosed(dest):
                state.directLinks[dest] = nil
                return .none
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter "router" 2>&1 | tail -30`
Expected: all outbound tests PASS; the 4a tests still PASS.

- [ ] **Step 5: Mutation-verify (three-step)**

Verify one at a time (revert between):
1. Drop the size-fallback (`effective = desiredMethod`): `routerFallsBackToDirectWhenOpportunisticTooLarge` fails (a too-big opportunistic message emits `sendOpportunistic` instead of `requestLink`).
2. In `.direct`, don't enqueue / always `requestLink` even when active: `routerDirectWithActiveLinkSendsImmediately` fails (emits `requestLink`/nothing instead of `sendDirect`).
3. In `.linkEstablished`, don't drain (`return .none` after setting active): `routerLinkEstablishedDrainsQueueAsSendDirect` fails (no `sendDirect`).
4. In the drain, hardcode `asResource: false`: add a resource-sized-message variant to `routerLinkEstablishedDrainsQueueAsSendDirect` (or a second test) so a `directRepresentation == .resource` message fails when `asResource` is wrong. (If the existing small message is `.packet`, add a large-message assertion to make `asResource` load-bearing.)

Run `swift test --filter "router"` after each; confirm; revert; final run PASSES.

- [ ] **Step 6: Commit**

```bash
git add Sources/ReTiCANode/LXMFRouter.swift Tests/ReTiCANodeTests/LXMFRouterTests.swift
git commit -F /tmp/ReTiCA/commit-lxmf4b-t2.txt
```

(Message e.g. `feat: LXMF-4b task 2 — LXMFRouter outbound state machine (method + link lifecycle)` plus trailers.)

---

## Self-Review

- **Spec coverage:** size threshold + `opportunisticFits` + cross-val (Task 1); opportunistic dispatch + size fallback + direct reuse/establish/queue + `linkEstablished` drain + `linkClosed` (Task 2). Retries/timing/path-requests/CLOSED-recovery deferred (spec §Deferred) — no task.
- **Placeholder scan:** none (the `linkID` test constant is `Data(repeating: 0xCD, count: 16)`); everything else is complete code.
- **Type consistency:** `LXMessage.encryptedPacketMDU`/`opportunisticFits`; `LXMFRouter.LinkStatus`/`.directLinks`/`.outboundQueue`/`.send`/`.linkEstablished`/`.linkClosed`/`.sendOpportunistic`/`.requestLink`/`.sendDirect`; reuses `DeliveryMethod` (4a), `LXMessage.opportunisticPayload`/`packed`/`directRepresentation`/`destinationHash`. `LinkStatus`/`LXMessage` `Equatable` → TCA state compiles.
- **Behavior:** size fallback = `opportunisticPayload.count <= 391`; establish-once (no re-request while `.establishing`); drain-on-established; `.linkClosed` clears so a later `.send` re-establishes — matches the scoped RNS happy path (`process_outbound`).
