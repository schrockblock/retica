# LXMF Propagation P4c-2 — PNNode Peering-Cost Enforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `PNNode` validates peering keys at a configured cost, and the mesh initiator generates a real key at the peer's (caller-supplied) cost via `LXStamper.generatePeeringKey` in an async effect.

**Architecture:** Add `peeringCost` config (used in the announce + responder validation); change `pendingSyncPeers: Set<Data> → [Data: Int]` (dest→cost); `syncToPeer` gains a `peeringCost:` arg; outbound `linkEstablished` computes `peeringId` and generates the key off-reducer (`.run`) then a new `offerKeyReady` action sends the offer. No `Endpoint`/`PropagationNode`/core changes.

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
- **Three-step mutation verification** for every new/changed test. One mutation at a time.
- **Non-exhaustive TCA tests** (`store.exhaustivity = .off`); flip `.on` last to assert an absence.
- **Ed25519/PoW** — never byte-compare a signature; a generated peering key is validated via `validatePeeringKey`, not byte-compared.
- **Scope:** cost config + responder validation at that cost + initiator async key-gen only. Do NOT auto-parse the peer's cost from `PNAnnounce`, add an `ERROR_INVALID_KEY` reply, add a peer registry/scheduling, or link teardown (P4c-3).
- Peering-key PoW cost in tests: use a **modest** cost (e.g. 8) — fast search, and high enough that an invalid `Data([0])` reliably fails validation.
- If `swift test` shows a stale cross-module link error, run `swift package clean` then retry.

---

### Task 1: PNNode cost enforcement wiring + unit tests

**Files:**
- Modify: `Sources/ReTiCANode/PNNode.swift`
- Test: `Tests/ReTiCANodeTests/PNNodeTests.swift`

**Interfaces:**
- Consumes: `LXStamper.generatePeeringKey(peeringId:targetCost:)` (P4c-1); `state.endpoint.transport.learned[dest]?.identity`; `PropagationNode.validatePeeringKey(...targetCost:)`.
- Produces (for Task 2 / P4c-3): `PNNode.State.peeringCost`, `syncToPeer(destinationHash:peeringCost:)`, `PNNode.Action.offerKeyReady(linkID:key:)`.

- [ ] **Step 1: Add `peeringCost` config.**

In `State`, after `public var identity: Identity`, add:
```swift
        public var peeringCost: Int = 0                        // required cost for inbound /offer peering keys
```
In `State.init`, add a `peeringCost` parameter (default 0) and assign it:
```swift
        public init(identity: Identity, endpoint: Endpoint.State, storageLimitBytes: Int? = nil, peeringCost: Int = 0) {
            self.identity = identity
            self.endpoint = endpoint
            self.peeringCost = peeringCost
            self.node = PropagationNode.State(storageLimitBytes: storageLimitBytes)
        }
```

- [ ] **Step 2: Change `pendingSyncPeers` to a cost map.**

Change:
```swift
        public var pendingSyncPeers: Set<Data> = []        // peer dests openLink'd, awaiting linkEstablished
```
to:
```swift
        public var pendingSyncPeers: [Data: Int] = [:]     // peer dest → the peer's peering cost, awaiting linkEstablished
```

- [ ] **Step 3: Update the `Action` (syncToPeer arg + offerKeyReady).**

Change `case syncToPeer(destinationHash: Data)` to:
```swift
        case syncToPeer(destinationHash: Data, peeringCost: Int)
        case offerKeyReady(linkID: Data, key: Data)
```

- [ ] **Step 4: Announce the configured cost.**

In `registerPropagation`, change the `PNAnnounce(...)` `peeringCost: 0` to `peeringCost: state.peeringCost`.

- [ ] **Step 5: Update the `syncToPeer` handler.**

```swift
            case let .syncToPeer(destinationHash, peeringCost):
                state.pendingSyncPeers[destinationHash] = peeringCost
                return .send(.endpoint(.openLink(destinationHash: destinationHash)))
```

- [ ] **Step 6: Enforce the configured cost in the `/offer` responder.**

In the `requestReceived` `/offer` branch, change `targetCost: 0` to `targetCost: state.peeringCost` (and update the trailing comment).

- [ ] **Step 7: Rewrite the outbound `linkEstablished` for async key-gen; add `offerKeyReady`.**

Replace the `linkEstablished` handler:
```swift
            case let .endpoint(.delegate(.linkEstablished(linkID, dest))):
                guard state.pendingSyncPeers.contains(dest) else { return .none }
                state.pendingSyncPeers.remove(dest)
                let offeredIds = state.node.store.transientIds
                state.offerLinks[linkID] = offeredIds
                let offer = MsgPack.encode(.array([.bin(Data([0x01])),
                                                   .array(offeredIds.map { .bin($0) })]))
                return .merge(.send(.endpoint(.identifyOverLink(linkID: linkID, identity: state.identity))),
                              .send(.endpoint(.sendRequestOverLink(linkID: linkID, path: "/offer", data: offer))))
```
with:
```swift
            case let .endpoint(.delegate(.linkEstablished(linkID, dest))):
                guard let cost = state.pendingSyncPeers[dest] else { return .none }   // inbound responder link → ignore
                state.pendingSyncPeers[dest] = nil
                guard let peerIdentity = state.endpoint.transport.learned[dest]?.identity else { return .none }
                state.offerLinks[linkID] = state.node.store.transientIds
                let peeringId = peerIdentity.hash + state.identity.hash              // responder-first (matches P4a)
                let selfIdentity = state.identity
                return .merge(
                    .send(.endpoint(.identifyOverLink(linkID: linkID, identity: selfIdentity))),
                    .run { send in
                        let key = LXStamper.generatePeeringKey(peeringId: peeringId, targetCost: cost)
                        await send(.offerKeyReady(linkID: linkID, key: key))
                    })
```
Add the `offerKeyReady` handler immediately after:
```swift
            case let .offerKeyReady(linkID, key):
                guard let offeredIds = state.offerLinks[linkID] else { return .none }
                let offer = MsgPack.encode(.array([.bin(key), .array(offeredIds.map { .bin($0) })]))
                return .send(.endpoint(.sendRequestOverLink(linkID: linkID, path: "/offer", data: offer)))
```

- [ ] **Step 8: Update `makeStore` + the rippled existing tests.**

In `Tests/ReTiCANodeTests/PNNodeTests.swift`:
- Change the `makeStore` helper signature to `func makeStore(_ pnIdentity: Identity, peeringCost: Int = 0) -> ...` and pass `peeringCost:` into `PNNode.State(...)`. Existing callers default to 0 (unaffected).
- **`pnNodeSyncToPeerOffersOnLinkEstablished`** asserted the old synchronous trivial-key offer — it must be REWRITTEN as the async key-gen test (see Step 9's `pnNodeInitiatorGeneratesValidPeeringKey`); remove the old version.
- Any other `syncToPeer(destinationHash:)` call sites (e.g. in `pnNodeMeshSyncTransfersStoredMessage` in `PNNodeMeshTests.swift`) must pass `peeringCost: 0` to compile. Update them to `syncToPeer(destinationHash: …, peeringCost: 0)` (Task 2 raises the mesh test's cost).

- [ ] **Step 9: Write the enforcement unit tests.**

Append to `Tests/ReTiCANodeTests/PNNodeTests.swift` (`ReTiCATransport` is already imported for `LearnedDestination`):

```swift
// MARK: - P4c-2 peering-cost enforcement

/// Responder validates the offer's peering key at the configured cost: a valid key is accepted (wanted response).
@Test @MainActor func pnNodeOfferAcceptedWithValidPeeringKey() async {
    let pnIdentity = Identity(); let peer = Identity()
    let cost = 8
    let peeringId = pnIdentity.hash + peer.hash                       // responder-first: responder + initiator
    let key = LXStamper.generatePeeringKey(peeringId: peeringId, targetCost: cost)
    let offerPath = Crypto.truncatedHash(Data("/offer".utf8))
    let id1 = Data(repeating: 0x11, count: 32)
    let store = makeStore(pnIdentity, peeringCost: cost)
    let linkID = Data(repeating: 0xB0, count: 16)
    await store.send(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: peer))))
    await store.send(.endpoint(.delegate(.requestReceived(linkID: linkID, requestID: Data([1]),
        pathHash: offerPath, data: MsgPack.encode(.array([.bin(key), .array([.bin(id1)])]))))))
    await store.receive { action in
        if case let .endpoint(.sendResponseOverLink(_, _, data)) = action {
            #expect(MsgPack.decodeValue(data) == .array([.bin(id1)])); return true
        }
        return false
    }
}

/// Responder rejects an invalid peering key at cost > 0: no response.
@Test @MainActor func pnNodeOfferRejectedWithInvalidPeeringKey() async {
    let peer = Identity()
    let offerPath = Crypto.truncatedHash(Data("/offer".utf8))
    let store = makeStore(Identity(), peeringCost: 8)
    let linkID = Data(repeating: 0xB0, count: 16)
    await store.send(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: peer))))
    await store.send(.endpoint(.delegate(.requestReceived(linkID: linkID, requestID: Data([1]),
        pathHash: offerPath, data: MsgPack.encode(.array([.bin(Data([0])), .array([.bin(Data(repeating: 0x11, count: 32))])]))))))
    store.exhaustivity = .on   // an invalid key must NOT produce a sendResponseOverLink
}

/// Initiator generates a peering key valid at the peer's cost and puts it in the /offer.
@Test @MainActor func pnNodeInitiatorGeneratesValidPeeringKey() async {
    let aIdentity = Identity(); let peerIdentity = Identity()
    let cost = 8
    let peerDest = Data(repeating: 0xD0, count: 16); let linkID = Data(repeating: 0xD1, count: 16)
    var initial = PNNode.State(identity: aIdentity, endpoint: Endpoint.State(host: "a", port: 4242, reconnectOnDrop: false))
    initial.endpoint.transport.learned[peerDest] = LearnedDestination(
        identity: peerIdentity, appData: nil, ratchet: nil, interfaceID: initial.endpoint.interfaceID,
        hops: 1, nextHop: nil, announceEmitted: 0)
    let store = TestStore(initialState: initial) { PNNode() } withDependencies: {
        $0.continuousClock = TestClock(); $0.date = .constant(Date(timeIntervalSince1970: 1700000000)); $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.syncToPeer(destinationHash: peerDest, peeringCost: cost))
    await store.receive { if case .endpoint(.openLink(peerDest)) = $0 { return true }; return false }
    #expect(store.state.pendingSyncPeers[peerDest] == cost)

    await store.send(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: peerDest))))
    await store.receive { if case let .endpoint(.identifyOverLink(lid, _)) = $0 { return lid == linkID }; return false }
    let gotKey = LockIsolated<Data?>(nil)
    await store.receive { action in                              // driven by the async offerKeyReady effect
        if case let .endpoint(.sendRequestOverLink(lid, path, data)) = action, lid == linkID, path == "/offer" {
            if case let .array(items)? = MsgPack.decodeValue(data), case let .bin(k) = items[0] { gotKey.setValue(k) }
            return true
        }
        return false
    }
    // The generated key validates at the peer's cost over the same responder-first peeringId.
    #expect(LXStamper.validatePeeringKey(peeringId: peerIdentity.hash + aIdentity.hash,
                                         peeringKey: gotKey.value!, targetCost: cost))
}
```

- [ ] **Step 10: Run the pnNode tests; confirm green (incl. the rippled updates).**

Run: `swift test --filter pnNode`
Expected: all PASS (new enforcement tests + updated existing; the mesh test still green at cost 0). (`swift package clean` first if it stale-links.)

- [ ] **Step 11: Mutation-verify (one at a time, revert between each).**

- Mutation A — responder ignores config: in the `/offer` branch, use `targetCost: 0` again. Run `swift test --filter pnNodeOfferRejectedWithInvalidPeeringKey` → must FAIL (invalid key now accepted → a stray `sendResponseOverLink` fails the `.on` teardown). Revert → PASS.
- Mutation B — initiator wrong peeringId ordering: in `linkEstablished`, compute `peeringId = state.identity.hash + peerIdentity.hash` (self-first). Run `swift test --filter pnNodeInitiatorGeneratesValidPeeringKey` → must FAIL (the key validates over the wrong peeringId, so `validatePeeringKey(peerIdentity.hash + aIdentity.hash, …)` is false). Revert → PASS.
- Mutation C — initiator ignores cost: in `linkEstablished`'s `.run`, use `targetCost: 0`. Run `swift test --filter pnNodeInitiatorGeneratesValidPeeringKey` → must FAIL (key generated at 0 does not validate at cost 8). Revert → PASS.

- [ ] **Step 12: Run the full ReTiCANode suite; confirm green.**

Run: `swift test --filter ReTiCANodeTests`
Expected: all PASS.

- [ ] **Step 13: Commit.** (column-0 trailers; verify parse after)

Write `/tmp/ReTiCA/commit-msg-p4c2-task1.txt`, then:
```bash
git add Sources/ReTiCANode/PNNode.swift Tests/ReTiCANodeTests/PNNodeTests.swift Tests/ReTiCANodeTests/PNNodeMeshTests.swift
git commit -F /tmp/ReTiCA/commit-msg-p4c2-task1.txt
```
Suggested subject: `feat: LXMF propagation P4c-2 task 1 — PNNode peering-cost enforcement`

---

### Task 2: cost>0 mesh integration (enforcement end-to-end)

**Files:**
- Modify: `Tests/ReTiCANodeTests/PNNodeMeshTests.swift`

- [ ] **Step 1: Raise the mesh test's peering cost.**

In `pnNodeMeshSyncTransfersStoredMessage`, configure PN-B with `peeringCost: 8` (pass it into B's `PNNode.State(...)` via the `makeB`/harness) and change A's call to `syncToPeer(destinationHash: bPropDest.hash, peeringCost: 8)`. The flow is otherwise unchanged: A generates a valid cost-8 key → B (cost 8) validates + accepts → A transfers → B ingests. (The offer is now sent via the async `offerKeyReady` effect — reconcile the extra receive if needed; the container transfer + final assertions are unchanged.) Rename to `pnNodeMeshSyncEnforcesPeeringCost`.

Load-bearing assertion unchanged: `b.state.node.store.contains(transientId: tid)`.

- [ ] **Step 2: Run the test.**

Run: `swift test --filter pnNodeMeshSyncEnforcesPeeringCost`
Expected: PASS (A's generated cost-8 key passes B's cost-8 validation → transfer → ingest). Reconcile intermediate receives for the async key-gen if needed; do NOT change the final assertion.

- [ ] **Step 3: Mutation-verify (one at a time, revert between each).**

- Mutation A — initiator generates at cost 0: in `PNNode.linkEstablished`'s `.run`, `targetCost: 0`. Run the Step 2 filter → must FAIL (B at cost 8 rejects A's cost-0 key → no wanted response → no transfer → B empty → `contains(tid) == false`). Revert → PASS.
- Mutation B — responder validates at cost 0: in `PNNode`'s `/offer` branch, `targetCost: 0`. Run → must PASS still (a valid cost-8 key also passes cost-0). This is NOT a useful mutation — SKIP it; use instead: responder validates at a HIGHER cost than configured is not applicable. Rely on Mutation A + the Task 1 responder-reject test for the responder side.

- [ ] **Step 4: Run the full ReTiCANode suite; confirm green.**

Run: `swift test --filter ReTiCANodeTests`
Expected: all PASS.

- [ ] **Step 5: Commit.** (column-0 trailers; verify parse after)

Write `/tmp/ReTiCA/commit-msg-p4c2-task2.txt`, then:
```bash
git add Tests/ReTiCANodeTests/PNNodeMeshTests.swift
git commit -F /tmp/ReTiCA/commit-msg-p4c2-task2.txt
```
Suggested subject: `feat: LXMF propagation P4c-2 task 2 — cost>0 mesh enforcement integration`

---

## Self-Review

**Spec coverage:**
- `peeringCost` config (init) + announce + responder validation → Task 1 Steps 1, 4, 6. ✅
- `pendingSyncPeers: [Data: Int]` + `syncToPeer(…, peeringCost:)` → Steps 2, 3, 5. ✅
- Async key-gen (`.run generatePeeringKey`) + `offerKeyReady` + `peeringId` responder-first → Step 7. ✅
- Responder valid-accept / invalid-reject; initiator generates-valid-key → Step 9. ✅
- cost>0 end-to-end enforcement → Task 2. ✅
- No announce-cost auto-parse / ERROR_INVALID_KEY / registry / teardown → absent by construction; Global Constraints call it out. ✅
- Ripple: `makeStore` peeringCost arg, rewrite `pnNodeSyncToPeerOffersOnLinkEstablished`, update mesh test `syncToPeer` → Step 8. ✅

**Placeholder scan:** Task 1 fully concrete. Task 2 modifies an existing test with concrete cost + assertion.

**Type consistency:** `generatePeeringKey(peeringId:targetCost:)`, `validatePeeringKey(peeringId:peeringKey:targetCost:)`, `LearnedDestination(identity:appData:ratchet:interfaceID:hops:nextHop:announceEmitted:)`, `transport.learned[dest]?.identity`, `syncToPeer(destinationHash:peeringCost:)`, `offerKeyReady(linkID:key:)`, `validatePeeringKey(...targetCost:)` all match the current sources.
