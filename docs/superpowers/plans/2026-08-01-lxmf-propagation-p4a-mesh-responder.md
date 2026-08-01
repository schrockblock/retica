# LXMF Propagation P4a — PN↔PN Mesh Responder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `PNNode` accepts an inbound `/offer` from a peer PN — validates the peering key (cost 0), computes which offered messages it wants, and responds with that list; the peer's follow-up Resource transfer ingests via the existing wire.

**Architecture:** Extend `PNNode.requestReceived` to dispatch by path (`/get` [P3b] vs `/offer`), hoisting the IDENTIFY guard to cover both. `/offer` uses a `pendingOffer[peerHash]` map to carry `(linkID, requestID, offeredIds)` across a two-hop decoupled chain (`validatePeeringKey → peerValidated`, then `peerOffered → requestFromPeer`). No `Endpoint`/`PropagationNode`/core changes.

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
- **Non-exhaustive TCA tests** (`store.exhaustivity = .off`); flip `.on` last to assert an absence.
- **Ed25519/hedged** — never byte-compare a signature/blob; deterministic `transientId` (msgpack-value equality) is fine.
- **Scope:** the `/offer` responder only. Do NOT add the initiator side, peering-*cost* enforcement (cost stays 0), peer registry, scheduling/throttle, or the `True`/`False` response optimizations.
- The `/get` refactor MUST be behavior-preserving (hoisting the identity guard and moving the `/get` body inside an `if` must not change `/get` outcomes).
- If `swift test` shows a stale cross-module link error, run `swift package clean` then retry.

---

### Task 1: PNNode /offer responder

Add the `pendingOffer` state, restructure `requestReceived` to dispatch `/get` vs `/offer`, and wire the two-hop peer-validate→wanted chain.

**Files:**
- Modify: `Sources/ReTiCANode/PNNode.swift`
- Test: `Tests/ReTiCANodeTests/PNNodeTests.swift`

**Interfaces:**
- Consumes: `PropagationNode` (`validatePeeringKey(peerHash:peeringId:peeringKey:targetCost:)`, `peerOffered(peerHash:transientIds:)`, delegates `peerValidated(peerHash:valid:)`, `requestFromPeer(peerHash:transientIds:)`); `Destination.hash(identityHash:appName:aspects:)`; `Crypto.truncatedHash(_:)`; `LXMessage.appName`; `MsgPack`/`MsgPackValue`.
- Produces (for P4b): `PNNode.State.pendingOffer`, `PNNode.PendingOffer`.

- [ ] **Step 1: Add the `pendingOffer` state + `PendingOffer` type.**

In `State`, after `public var pendingGet: [Data: PendingGet] = [:]`, add:
```swift
        public var pendingOffer: [Data: PendingOffer] = [:]   // peerHash → (linkID, requestID, offeredIds)
```
After the `PendingGet` struct, add:
```swift
    public struct PendingOffer: Equatable {
        public var linkID: Data
        public var requestID: Data
        public var offeredIds: [Data]
    }
```

- [ ] **Step 2: Restructure `requestReceived` to dispatch by path (behavior-preserving for `/get`).**

Replace the entire `requestReceived` handler:
```swift
            case let .endpoint(.delegate(.requestReceived(linkID, requestID, pathHash, data))):
                guard pathHash == Crypto.truncatedHash(Data("/get".utf8)) else { return .none }
                guard let clientIdentity = state.clientIdentities[linkID] else { return .none }   // no IDENTIFY → drop
                let clientHash = LXMessage.deliveryHash(identityHash: clientIdentity.hash)
                state.pendingGet[clientHash] = PendingGet(linkID: linkID, requestID: requestID)
                guard case let .array(items)? = MsgPack.decodeValue(data), items.count >= 2 else { return .none }
                if case .null = items[0], case .null = items[1] {
                    return .send(.node(.messageListRequested(destinationHash: clientHash)))
                }
                return .send(.node(.messagesRequested(destinationHash: clientHash,
                                                      wants: PNNode.arrayOfBin(items[0]),
                                                      haves: PNNode.arrayOfBin(items[1]))))
```
with:
```swift
            case let .endpoint(.delegate(.requestReceived(linkID, requestID, pathHash, data))):
                guard let clientIdentity = state.clientIdentities[linkID] else { return .none }   // no IDENTIFY → drop (both paths)
                if pathHash == Crypto.truncatedHash(Data("/get".utf8)) {
                    let clientHash = LXMessage.deliveryHash(identityHash: clientIdentity.hash)
                    state.pendingGet[clientHash] = PendingGet(linkID: linkID, requestID: requestID)
                    guard case let .array(items)? = MsgPack.decodeValue(data), items.count >= 2 else { return .none }
                    if case .null = items[0], case .null = items[1] {
                        return .send(.node(.messageListRequested(destinationHash: clientHash)))
                    }
                    return .send(.node(.messagesRequested(destinationHash: clientHash,
                                                          wants: PNNode.arrayOfBin(items[0]),
                                                          haves: PNNode.arrayOfBin(items[1]))))
                }
                if pathHash == Crypto.truncatedHash(Data("/offer".utf8)) {
                    guard case let .array(items)? = MsgPack.decodeValue(data), items.count >= 2,
                          case let .bin(peeringKey) = items[0] else { return .none }
                    let offeredIds = PNNode.arrayOfBin(items[1])
                    let peerHash = Destination.hash(identityHash: clientIdentity.hash,
                                                    appName: LXMessage.appName, aspects: ["propagation"])
                    let peeringId = state.identity.hash + clientIdentity.hash
                    state.pendingOffer[peerHash] = PendingOffer(linkID: linkID, requestID: requestID, offeredIds: offeredIds)
                    return .send(.node(.validatePeeringKey(peerHash: peerHash, peeringId: peeringId,
                                                           peeringKey: peeringKey, targetCost: 0)))   // cost 0 = open mesh (P4c enforces)
                }
                return .none
```

- [ ] **Step 3: Add the two-hop correlation wires.**

Immediately after the `deliverMessages` handler (before the `.endpoint, .node, .delegate` catch-all), add:
```swift
            case let .node(.delegate(.peerValidated(peerHash, valid))):
                guard let pending = state.pendingOffer[peerHash] else { return .none }
                if valid { return .send(.node(.peerOffered(peerHash: peerHash, transientIds: pending.offeredIds))) }
                state.pendingOffer[peerHash] = nil                     // invalid key → drop (dead path at cost 0)
                return .none

            case let .node(.delegate(.requestFromPeer(peerHash, wanted))):
                guard let pending = state.pendingOffer[peerHash] else { return .none }
                state.pendingOffer[peerHash] = nil
                return .send(.endpoint(.sendResponseOverLink(linkID: pending.linkID, requestID: pending.requestID,
                                                             data: MsgPack.encode(.array(wanted.map { .bin($0) })))))
```

- [ ] **Step 4: Confirm it compiles + the P3b tests still pass (regression).**

Run: `swift build`
Then: `swift test --filter pnNode`
Expected: builds clean; all existing `pnNode*` tests (registration, ingest, two-phase `/get`, no-identity drop) still PASS — the `/get` refactor is behavior-preserving. (If stale-links, `swift package clean` first.)

- [ ] **Step 5: Write the `/offer` unit tests.**

Append to `Tests/ReTiCANodeTests/PNNodeTests.swift` (reuse the file's `makeStore` harness and imports):

```swift
// MARK: - P4a PN↔PN mesh responder (/offer)

/// /offer with a peer identity: the store lacks both offered ids → responds wanting both.
@Test @MainActor func pnNodeOfferWantsAllWhenStoreEmpty() async {
    let peer = Identity()
    let offerPath = Crypto.truncatedHash(Data("/offer".utf8))
    let id1 = Data(repeating: 0x11, count: 32); let id2 = Data(repeating: 0x22, count: 32)
    let store = makeStore(Identity())
    let linkID = Data(repeating: 0xB0, count: 16)
    await store.send(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: peer))))
    await store.send(.endpoint(.delegate(.requestReceived(linkID: linkID, requestID: Data([1]),
        pathHash: offerPath, data: MsgPack.encode(.array([.bin(Data([0x01])), .array([.bin(id1), .bin(id2)])]))))))
    await store.receive { action in
        if case let .endpoint(.sendResponseOverLink(lid, rid, data)) = action {
            #expect(lid == linkID); #expect(rid == Data([1]))
            #expect(MsgPack.decodeValue(data) == .array([.bin(id1), .bin(id2)])); return true
        }
        return false
    }
}

/// /offer where the store already holds one offered id → responds wanting only the other.
@Test @MainActor func pnNodeOfferWantsOnlyMissing() async {
    let peer = Identity(); let sender = Identity(); let recipient = Identity()
    let msg = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: recipient.hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("x".utf8))
    let (container, _) = LXMFPropagation.pack(message: msg, recipientIdentity: recipient, timestamp: 1700000000.5)
    let held = LXMFPropagation.transientId(lxmfData: LXMFPropagation.parseContainer(container)!.entries[0])
    let want = Data(repeating: 0x22, count: 32)
    let offerPath = Crypto.truncatedHash(Data("/offer".utf8))
    let store = makeStore(Identity())
    let linkID = Data(repeating: 0xB0, count: 16)

    await store.send(.endpoint(.delegate(.resourceReceived(linkID: linkID, data: container))))   // PN now holds `held`
    await store.receive { if case .delegate(.messagesStored) = $0 { return true }; return false }
    await store.send(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: peer))))
    await store.send(.endpoint(.delegate(.requestReceived(linkID: linkID, requestID: Data([2]),
        pathHash: offerPath, data: MsgPack.encode(.array([.bin(Data([0x01])), .array([.bin(held), .bin(want)])]))))))
    await store.receive { action in
        if case let .endpoint(.sendResponseOverLink(_, _, data)) = action {
            #expect(MsgPack.decodeValue(data) == .array([.bin(want)])); return true   // held excluded, only `want`
        }
        return false
    }
}

/// /offer without a prior IDENTIFY on the link is dropped (no response).
@Test @MainActor func pnNodeOfferWithoutIdentifyDrops() async {
    let offerPath = Crypto.truncatedHash(Data("/offer".utf8))
    let store = makeStore(Identity())
    let linkID = Data(repeating: 0xB0, count: 16)
    await store.send(.endpoint(.delegate(.requestReceived(linkID: linkID, requestID: Data([1]),
        pathHash: offerPath, data: MsgPack.encode(.array([.bin(Data([0x01])), .array([.bin(Data(repeating: 0x11, count: 32))])]))))))
    store.exhaustivity = .on   // a stray sendResponseOverLink / node action would fail teardown
}
```

- [ ] **Step 6: Run the new tests; confirm green.**

Run: `swift test --filter pnNodeOffer`
Expected: all PASS. (`pnNodeOfferWantsAllWhenStoreEmpty` relies on cost-0 peering-key validation always passing — if it does not, the offered ids never reach `peerOffered`; the implementer confirms cost-0 validation accepts an arbitrary key.)

- [ ] **Step 7: Mutation-verify (one at a time, revert between each).**

- Mutation A — drop the validate→offer hop: in the `peerValidated` handler, replace the `if valid { … }` body with `return .none`. Run `swift test --filter pnNodeOfferWantsAllWhenStoreEmpty` → must FAIL (offered ids never reach `peerOffered` → no response). Revert → PASS.
- Mutation B — break the response correlation: in the `requestFromPeer` handler, `return .none` instead of `sendResponseOverLink`. Run `swift test --filter pnNodeOfferWantsAllWhenStoreEmpty` → must FAIL (no response). Revert → PASS.
- Mutation C — regress the `/get` refactor: in the restructured `requestReceived`, change the `/offer` `if` condition to also match `/get` (e.g. `pathHash == Crypto.truncatedHash(Data("/get".utf8))`) so `/get` falls into the `/offer` branch. Run `swift test --filter pnNodeServesTwoPhaseGet` → must FAIL. Revert → PASS. (Confirms the two paths stay distinct.)

- [ ] **Step 8: Run the full ReTiCANode suite; confirm green.**

Run: `swift test --filter ReTiCANodeTests`
Expected: all PASS.

- [ ] **Step 9: Commit.**

Write the message to `/tmp/ReTiCA/commit-msg-p4a-task1.txt` (verbatim trailers), then:

```bash
git add Sources/ReTiCANode/PNNode.swift Tests/ReTiCANodeTests/PNNodeTests.swift
git commit -F /tmp/ReTiCA/commit-msg-p4a-task1.txt
```

Suggested subject: `feat: LXMF propagation P4a — PNNode mesh /offer responder`

---

## Self-Review

**Spec coverage:**
- `pendingOffer` state + `PendingOffer` → Task 1 Step 1. ✅
- `requestReceived` dispatch by path (identity guard hoisted; `/get` unchanged) → Step 2. ✅
- `/offer`: decode `[peeringKey, offeredIds]`, `peerHash`/`peeringId`, `validatePeeringKey(cost 0)` → Step 2. ✅
- Two-hop: `peerValidated → peerOffered` (valid) / drop (invalid); `requestFromPeer → sendResponseOverLink([wanted])` → Step 3. ✅
- Wanted list (empty = has-all), transfer ingests via existing wire → Step 3 + P3b (unchanged). ✅
- No initiator / cost-enforcement / registry / scheduling / True-False → absent by construction; Global Constraints call it out. ✅
- `/get` behavior-preserving → Step 4 regression + mutation C. ✅

**Placeholder scan:** none — all steps carry concrete code or exact commands.

**Type consistency:** `validatePeeringKey(peerHash:peeringId:peeringKey:targetCost:)`, `peerOffered(peerHash:transientIds:)`, `peerValidated(peerHash:valid:)`, `requestFromPeer(peerHash:transientIds:)`, `Destination.hash(identityHash:appName:aspects:)`, `Crypto.truncatedHash(_:)`, `sendResponseOverLink(linkID:requestID:data:)`, `PNNode.arrayOfBin`, `MsgPackValue.array`/`.bin` all match the current `PNNode.swift`/`PropagationNode.swift`/`Destination.swift` surfaces. New tests reuse `makeStore` and the container helpers already in `PNNodeTests.swift`.
