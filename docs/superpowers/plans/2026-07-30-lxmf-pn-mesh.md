# LXMF-4d-5b: Propagation Node Mesh (peer sync) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `PropagationNode` with the PN↔PN dedup exchange — request only the `transient_id`s we lack from a peer's offer, offer our own, and validate a peer's peering key.

**Architecture:** Add three stateless-over-the-store actions/delegates to the existing `PropagationNode` reducer, reusing `PropagationStore.wanted`/`transientIds` (4d-5) and `LXStamper.validatePeeringKey` (5c). Peer-fetched batches return via the existing `.ingestContainer`.

**Tech Stack:** Swift, The Composable Architecture (TCA), swift-testing (`@Test`).

## Global Constraints

- Commit directly to `main`; no feature branch, no finishing-a-development-branch merge dance.
- No compound shell commands: no `|` chains, `&&`, `||`, `;`, `$(...)`-feeding, `xargs`, or inlining scripts into interpreters. One command per Bash call. A single `>` redirect is allowed. Never use echo/printf/heredoc to WRITE source files (use Write/Edit).
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new test.
- Commit trailers (exact); the `;` means author the message with the Write tool to `/tmp/ReTiCA/` and `git commit -F`, never `-m`:
  - `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`

---

### Task 1: Peer-sync actions on `PropagationNode`

**Files:**
- Modify: `Sources/ReTiCANode/PropagationNode.swift` (Action after line 24; Delegate after line 29; reducer cases after line 48; doc comment line 10)
- Modify (append tests): `Tests/ReTiCANodeTests/PropagationNodeTests.swift` (reuses the file's `entry`/`container` helpers)

**Interfaces:**
- Consumes: `PropagationStore.wanted(fromOffered:) -> [Data]`, `.transientIds: [Data]` (4d-5); `LXStamper.validatePeeringKey(peeringId:peeringKey:targetCost:) -> Bool` (5c). All in `ReTiCA` (already imported).
- Produces: `PropagationNode.Action` cases `.peerOffered`, `.offerToPeer`, `.validatePeeringKey`; `Delegate` cases `.requestFromPeer`, `.offerTransientIds`, `.peerValidated`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ReTiCANodeTests/PropagationNodeTests.swift`:

```swift
// MARK: - LXMF-4d-5b peer sync (mesh)

@Test @MainActor func propagationNodePeerOfferedRequestsOnlyMissing() async {
    let x = entry(dest: 0xAA, tail: "x"), y = entry(dest: 0xAA, tail: "y")
    let z = entry(dest: 0xAA, tail: "z"), w = entry(dest: 0xAA, tail: "w")
    let tid: (Data) -> Data = { LXMFPropagation.transientId(lxmfData: $0) }
    let store = TestStore(initialState: PropagationNode.State()) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([x, y])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    let peer = Data(repeating: 0x11, count: 16)
    await store.send(.peerOffered(peerHash: peer, transientIds: [tid(x), tid(y), tid(z), tid(w)]))
    await store.receive { action in
        if case let .delegate(.requestFromPeer(p, ids)) = action {
            #expect(p == peer); #expect(ids == [tid(z), tid(w)]); return true   // only the ids we lack
        }
        return false
    }
}

@Test @MainActor func propagationNodeOffersOurTransientIds() async {
    let e1 = entry(dest: 0xAA, tail: "e1"), e2 = entry(dest: 0xBB, tail: "e2")
    let tid: (Data) -> Data = { LXMFPropagation.transientId(lxmfData: $0) }
    let store = TestStore(initialState: PropagationNode.State()) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([e1, e2])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    let peer = Data(repeating: 0x11, count: 16)
    await store.send(.offerToPeer(peerHash: peer))
    await store.receive { action in
        if case let .delegate(.offerTransientIds(p, ids)) = action {
            #expect(p == peer); #expect(ids == [tid(e1), tid(e2)]); return true   // oldest-first
        }
        return false
    }
}

@Test @MainActor func propagationNodeValidatesPeeringKey() async {
    let peer = Data(repeating: 0x11, count: 16)
    let peeringId = Data(repeating: 0x22, count: 32)
    let key = Data(repeating: 0x33, count: LXStamper.stampSize)
    let store = TestStore(initialState: PropagationNode.State()) { PropagationNode() }
    store.exhaustivity = .off
    // cost 0 → any key validates (leading-zero-bits >= 0 always true)
    await store.send(.validatePeeringKey(peerHash: peer, peeringId: peeringId, peeringKey: key, targetCost: 0))
    await store.receive { action in
        if case let .delegate(.peerValidated(p, valid)) = action { #expect(p == peer); #expect(valid == true); return true }
        return false
    }
    // an arbitrary key cannot meet a high cost → rejected
    await store.send(.validatePeeringKey(peerHash: peer, peeringId: peeringId, peeringKey: key, targetCost: 250))
    await store.receive { action in
        if case let .delegate(.peerValidated(_, valid)) = action { #expect(valid == false); return true }
        return false
    }
}
```

- [ ] **Step 2: Run them — verify they fail**

Run: `swift test --filter PropagationNodeTests.propagationNodePeerOfferedRequestsOnlyMissing`
Expected: BUILD FAILURE — `.peerOffered` / `.requestFromPeer` don't exist yet. Expected red.

- [ ] **Step 3: Add the peer-sync actions, delegates, and reducer cases**

In `Sources/ReTiCANode/PropagationNode.swift`:

(a) `Action` — after `case messagesDelivered(transientIds: [Data])` (line 24) add:

```swift
        case peerOffered(peerHash: Data, transientIds: [Data])
        case offerToPeer(peerHash: Data)
        case validatePeeringKey(peerHash: Data, peeringId: Data, peeringKey: Data, targetCost: Int)
```

(b) `Delegate` — after `case deliverMessages(destinationHash: Data, entries: [Data])` (line 29) add:

```swift
            case requestFromPeer(peerHash: Data, transientIds: [Data])
            case offerTransientIds(peerHash: Data, transientIds: [Data])
            case peerValidated(peerHash: Data, valid: Bool)
```

(c) Reducer — after the `.messagesDelivered` case (after line 48), before `case .delegate:` add:

```swift
            case let .peerOffered(peerHash, offered):
                return .send(.delegate(.requestFromPeer(peerHash: peerHash,
                                                        transientIds: state.store.wanted(fromOffered: offered))))

            case let .offerToPeer(peerHash):
                return .send(.delegate(.offerTransientIds(peerHash: peerHash, transientIds: state.store.transientIds)))

            case let .validatePeeringKey(peerHash, peeringId, peeringKey, targetCost):
                let valid = LXStamper.validatePeeringKey(peeringId: peeringId, peeringKey: peeringKey, targetCost: targetCost)
                return .send(.delegate(.peerValidated(peerHash: peerHash, valid: valid)))
```

(d) Doc comment — update the last sentence (line 10) so it no longer says the mesh is separate:

```swift
/// save_locally_delivered_transient_ids). Also does PN↔PN peer sync (offer/wanted exchange + peering-key
/// validation); stamps enforcement and the peer link/transfer networking + peer registry are app/mesh glue.
```

- [ ] **Step 4: Run them — verify they pass**

Run: `swift test --filter PropagationNodeTests`
Expected: PASS (the 5 existing + 3 new = 8).

- [ ] **Step 5: Mutation verification (one at a time)**

Apply each in `Sources/ReTiCANode/PropagationNode.swift`, run `swift test --filter PropagationNodeTests`, confirm the named test fails, revert, confirm pass.

1. **peerOffered ignores the dedup** — replace `state.store.wanted(fromOffered: offered)` with `state.store.transientIds` (offer our ids instead of the wanted subset).
   → `propagationNodePeerOfferedRequestsOnlyMissing` FAILS (requests `[tid(x), tid(y)]`, not `[tid(z), tid(w)]`).
2. **offerToPeer offers nothing** — replace `state.store.transientIds` with `[]`.
   → `propagationNodeOffersOurTransientIds` FAILS (empty ids, not `[tid(e1), tid(e2)]`).
3. **validatePeeringKey ignores the verdict** — replace `let valid = LXStamper.validatePeeringKey(...)` with `let valid = true`.
   → `propagationNodeValidatesPeeringKey` FAILS (the `targetCost: 250` case yields `true`, expected `false`).

After each: revert, re-run, expect PASS.

- [ ] **Step 6: Full test gate**

Run: `swift test`
Expected: PASS. The PN-announce baseline was 476 passed / 1 pre-existing live-node skip / 0 fail; this slice adds 3 router tests → 479 passed. On a signal-11/signal-10 build flake (or after any `Sources/ReTiCA/Support/MsgPack.swift` change — not touched here), run `swift package clean` (single command) and re-run.

- [ ] **Step 7: Commit**

Write the message to `/tmp/ReTiCA/commit-msg-mesh.txt` with the Write tool (body below), then:

```bash
git add Sources/ReTiCANode/PropagationNode.swift Tests/ReTiCANodeTests/PropagationNodeTests.swift
```

```bash
git commit -F /tmp/ReTiCA/commit-msg-mesh.txt
```

Commit message body:

```
feat: LXMF-4d-5b — propagation node mesh (peer sync)

Extends PropagationNode with the PN↔PN dedup exchange: .peerOffered →
.requestFromPeer(store.wanted(offered)) (request only the ids we lack);
.offerToPeer → .offerTransientIds(store.transientIds); .validatePeeringKey
→ .peerValidated via LXStamper.validatePeeringKey. Peer-fetched batches
ingest through the existing .ingestContainer. Peer link/transfer
networking + peer registry/policy remain app glue. 3 new tests.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Self-Review

**Spec coverage:**
- Spec actions (`peerOffered`/`offerToPeer`/`validatePeeringKey`) + delegates (`requestFromPeer`/`offerTransientIds`/`peerValidated`) → Step 3. ✓
- Spec reducer (peerOffered→wanted; offerToPeer→transientIds; validatePeeringKey→LXStamper verdict) → Step 3. ✓
- Spec test 1 (request only missing) → `propagationNodePeerOfferedRequestsOnlyMissing`. ✓
- Spec test 2 (offer our ids) → `propagationNodeOffersOurTransientIds`. ✓
- Spec test 3 (peering-key verdict routes) → `propagationNodeValidatesPeeringKey`. ✓
- Spec "peer-fetched batch ingests via existing .ingestContainer" → no new code (documented; the optional loop test omitted per spec). ✓

**Placeholder scan:** none.

**Type consistency:** `Action.peerOffered(peerHash:transientIds:)`, `.offerToPeer(peerHash:)`, `.validatePeeringKey(peerHash:peeringId:peeringKey:targetCost:)` and `Delegate.requestFromPeer(peerHash:transientIds:)`, `.offerTransientIds(peerHash:transientIds:)`, `.peerValidated(peerHash:valid:)` match the test call sites. Consumes `store.wanted(fromOffered:)`/`store.transientIds` and `LXStamper.validatePeeringKey`/`.stampSize` with their exact signatures. Tests reuse the existing `entry`/`container`/`LXMFPropagation.transientId` helpers already in `PropagationNodeTests.swift`.
