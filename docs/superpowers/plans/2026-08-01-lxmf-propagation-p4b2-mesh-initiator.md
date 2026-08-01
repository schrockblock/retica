# LXMF Propagation P4b-2 — PNNode Mesh Initiator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `PNNode` actively syncs its stored messages to a peer PN — its first outbound link-initiation: `syncToPeer` → link → IDENTIFY → offer → parse the peer's wanted response → gather → transfer as a Resource.

**Architecture:** Add outbound state (`pendingSyncPeers`, `offerLinks`), a `syncToPeer` trigger, outbound `linkEstablished` handling (IDENTIFY + offer), and `responseReceived` handling (parse `True`/`False`/list → gather via P4b-1's `entries(forTransientIds:)` → build container → `sendResourceOverLink`). No `Endpoint`/`PropagationNode`/core changes; the transfer ingests on the peer via P4a→P3b.

**Tech Stack:** Swift, Point-Free Composable Architecture (TCA), Swift Testing (`@Test`/`#expect`), `swift test`.

## Global Constraints

- **Commit directly to `main`** — no feature branch, no merge dance.
- **No compound shell commands** — one command per invocation; no `&&`/`||`/`;`/`|`-chains/`xargs`/inline interpreter scripts. A single `>` redirect is allowed. Write files with the editor, not echo/heredoc.
- **Temp files** go in `/tmp/ReTiCA/`.
- **Commit trailers, verbatim, at COLUMN 0 (no leading whitespace)**, via `git commit -F <file>` (never `-m`, the trailers contain `;`):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```
  Indented trailers are NOT parsed by git — keep both lines flush-left. Verify with `git log -1 --format='%(trailers:key=Claude-Session,valueonly=true)'` (must print the URL).
- **Three-step mutation verification** for every new/changed test: run pass → mutate production to force fail + confirm → revert + confirm pass. One mutation at a time.
- **Non-exhaustive TCA tests** (`store.exhaustivity = .off`); flip `.on` last to assert an absence.
- **Ed25519/hedged** — never byte-compare a signature; deterministic `transientId`/container-parse (msgpack/entry equality) is fine.
- **Scope:** the initiator (`syncToPeer`, outbound `linkEstablished`, `responseReceived` → transfer) only. Do NOT add per-peer unhandled tracking (offer ALL `transientIds`), PoW peering-key generation (trivial cost-0 `.bin` key), peer registry, scheduling/throttle, or post-transfer link teardown.
- If `swift test` shows a stale cross-module link error, run `swift package clean` then retry.

---

### Task 1: PNNode initiator wiring + injected-delegate unit tests

**Files:**
- Modify: `Sources/ReTiCANode/PNNode.swift`
- Test: `Tests/ReTiCANodeTests/PNNodeTests.swift`

**Interfaces:**
- Consumes: `Endpoint` (`openLink`, `identifyOverLink`, `sendRequestOverLink`, `sendResourceOverLink`, delegates `linkEstablished(linkID:destinationHash:)`, `responseReceived(linkID:requestID:data:)`); `PropagationStore.transientIds`, `.entries(forTransientIds:)` (P4b-1); `LXMFPropagation.container(timestamp:entries:)`; `MsgPack`/`MsgPackValue`.
- Produces (for Task 2 / P4c): `PNNode.Action.syncToPeer(destinationHash:)`, `PNNode.State.pendingSyncPeers`, `PNNode.State.offerLinks`.

- [ ] **Step 1: Add the outbound state.**

In `State`, after `public var pendingOffer: [Data: PendingOffer] = [:]`, add:
```swift
        public var pendingSyncPeers: Set<Data> = []        // peer dests openLink'd, awaiting linkEstablished
        public var offerLinks: [Data: [Data]] = [:]        // outbound offer linkID → offeredIds we sent
```

- [ ] **Step 2: Add the `syncToPeer` action + handler.**

In `Action`, after `case registerPropagation`, add:
```swift
        case syncToPeer(destinationHash: Data)
```
In the `Reduce`, after the `registerPropagation` handler block, add:
```swift
            case let .syncToPeer(destinationHash):
                state.pendingSyncPeers.insert(destinationHash)
                return .send(.endpoint(.openLink(destinationHash: destinationHash)))
```

- [ ] **Step 3: Add outbound `linkEstablished` handling (IDENTIFY + offer).**

Immediately before the final `case .endpoint, .node, .delegate:` catch-all, add:
```swift
            case let .endpoint(.delegate(.linkEstablished(linkID, dest))):
                guard state.pendingSyncPeers.contains(dest) else { return .none }   // inbound responder link → ignore
                state.pendingSyncPeers.remove(dest)
                let offeredIds = state.node.store.transientIds
                state.offerLinks[linkID] = offeredIds
                let offer = MsgPack.encode(.array([.bin(Data([0x01])),             // trivial cost-0 peering key (P4c: PoW)
                                                   .array(offeredIds.map { .bin($0) })]))
                return .merge(.send(.endpoint(.identifyOverLink(linkID: linkID, identity: state.identity))),
                              .send(.endpoint(.sendRequestOverLink(linkID: linkID, path: "/offer", data: offer))))
```

- [ ] **Step 4: Add `responseReceived` handling (parse + transfer).**

Immediately after the `linkEstablished` case, add:
```swift
            case let .endpoint(.delegate(.responseReceived(linkID, _, data))):
                guard let offeredIds = state.offerLinks[linkID] else { return .none }   // not an outbound offer link
                state.offerLinks[linkID] = nil
                let wanted: [Data]
                switch MsgPack.decodeValue(data) {
                case .bool(false):      wanted = []                          // peer has all → nothing
                case .bool(true):       wanted = offeredIds                  // peer wants all offered
                case let .array(items): wanted = items.compactMap { if case let .bin(d) = $0 { return d } else { return nil } }
                default:                return .none                         // malformed
                }
                guard !wanted.isEmpty else { return .none }
                let entries = state.node.store.entries(forTransientIds: wanted).map(\.lxmfData)
                let container = LXMFPropagation.container(timestamp: date.now.timeIntervalSince1970, entries: entries)
                return .send(.endpoint(.sendResourceOverLink(linkID: linkID, data: container)))
```

- [ ] **Step 5: Confirm build + the existing pnNode tests pass (regression).**

Run: `swift build`
Then: `swift test --filter pnNode`
Expected: builds clean; all existing `pnNode*` tests (register, ingest, `/get`, `/offer` responder) still PASS — the additions are new cases before the catch-all. (If stale-links, `swift package clean` first.)

- [ ] **Step 6: Write the initiator unit tests.**

Append to `Tests/ReTiCANodeTests/PNNodeTests.swift` (reuse the `makeStore` harness). A shared setup builds a store holding one message and drives it to the offer:

```swift
// MARK: - P4b-2 mesh initiator

/// syncToPeer opens a link and, on establishment to a pending peer, IDENTIFYs and offers store.transientIds.
@Test @MainActor func pnNodeSyncToPeerOffersOnLinkEstablished() async {
    let sender = Identity(); let recipient = Identity()
    let msg = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: recipient.hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("m".utf8))
    let (container, _) = LXMFPropagation.pack(message: msg, recipientIdentity: recipient, timestamp: 1700000000.5)
    let tid = LXMFPropagation.transientId(lxmfData: LXMFPropagation.parseContainer(container)!.entries[0])
    let peerDest = Data(repeating: 0xD0, count: 16)
    let linkID = Data(repeating: 0xD1, count: 16)
    let store = makeStore(Identity())

    await store.send(.endpoint(.delegate(.resourceReceived(linkID: Data([9]), data: container))))  // PN-A now holds `tid`
    await store.receive { if case .delegate(.messagesStored) = $0 { return true }; return false }

    await store.send(.syncToPeer(destinationHash: peerDest))
    await store.receive { if case .endpoint(.openLink(peerDest)) = $0 { return true }; return false }
    #expect(store.state.pendingSyncPeers.contains(peerDest))

    await store.send(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: peerDest))))
    await store.receive { if case let .endpoint(.identifyOverLink(lid, _)) = $0 { return lid == linkID }; return false }
    await store.receive { action in
        if case let .endpoint(.sendRequestOverLink(lid, path, data)) = action {
            #expect(lid == linkID); #expect(path == "/offer")
            #expect(MsgPack.decodeValue(data) == .array([.bin(Data([0x01])), .array([.bin(tid)])]))
            return true
        }
        return false
    }
    #expect(store.state.offerLinks[linkID] == [tid])
    #expect(!store.state.pendingSyncPeers.contains(peerDest))
}

/// Offer response (list): transfer the wanted subset as a container Resource.
@Test @MainActor func pnNodeTransfersWantedListOnOfferResponse() async {
    let sender = Identity(); let recipient = Identity()
    let msg = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: recipient.hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("m".utf8))
    let (container, _) = LXMFPropagation.pack(message: msg, recipientIdentity: recipient, timestamp: 1700000000.5)
    let entry = LXMFPropagation.parseContainer(container)!.entries[0]
    let tid = LXMFPropagation.transientId(lxmfData: entry)
    let linkID = Data(repeating: 0xD1, count: 16)
    var initial = PNNode.State(identity: Identity(), endpoint: Endpoint.State(host: "pn", port: 4242, reconnectOnDrop: false))
    _ = initial.node.store.ingest(container: container)
    initial.offerLinks[linkID] = [tid]
    let store = TestStore(initialState: initial) { PNNode() } withDependencies: {
        $0.continuousClock = TestClock(); $0.date = .constant(Date(timeIntervalSince1970: 1700000000)); $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.endpoint(.delegate(.responseReceived(linkID: linkID, requestID: Data([1]),
        data: MsgPack.encode(.array([.bin(tid)]))))))
    await store.receive { action in
        if case let .endpoint(.sendResourceOverLink(lid, data)) = action {
            #expect(lid == linkID)
            #expect(LXMFPropagation.parseContainer(data)?.entries == [entry]); return true
        }
        return false
    }
    #expect(store.state.offerLinks[linkID] == nil)   // consumed
}

/// Offer response `true` (wants all): transfer all offered entries.
@Test @MainActor func pnNodeTransfersAllOnTrueResponse() async {
    let sender = Identity(); let recipient = Identity()
    let msg = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: recipient.hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("m".utf8))
    let (container, _) = LXMFPropagation.pack(message: msg, recipientIdentity: recipient, timestamp: 1700000000.5)
    let entry = LXMFPropagation.parseContainer(container)!.entries[0]
    let tid = LXMFPropagation.transientId(lxmfData: entry)
    let linkID = Data(repeating: 0xD1, count: 16)
    var initial = PNNode.State(identity: Identity(), endpoint: Endpoint.State(host: "pn", port: 4242, reconnectOnDrop: false))
    _ = initial.node.store.ingest(container: container)
    initial.offerLinks[linkID] = [tid]
    let store = TestStore(initialState: initial) { PNNode() } withDependencies: {
        $0.continuousClock = TestClock(); $0.date = .constant(Date(timeIntervalSince1970: 1700000000)); $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.endpoint(.delegate(.responseReceived(linkID: linkID, requestID: Data([1]),
        data: MsgPack.encode(.bool(true))))))
    await store.receive { action in
        if case let .endpoint(.sendResourceOverLink(_, data)) = action {
            #expect(LXMFPropagation.parseContainer(data)?.entries == [entry]); return true
        }
        return false
    }
}

/// Offer response `false` (has all): no transfer.
@Test @MainActor func pnNodeTransfersNothingOnFalseResponse() async {
    let linkID = Data(repeating: 0xD1, count: 16)
    var initial = PNNode.State(identity: Identity(), endpoint: Endpoint.State(host: "pn", port: 4242, reconnectOnDrop: false))
    initial.offerLinks[linkID] = [Data(repeating: 0x11, count: 32)]
    let store = TestStore(initialState: initial) { PNNode() } withDependencies: {
        $0.continuousClock = TestClock(); $0.date = .constant(Date(timeIntervalSince1970: 1700000000)); $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.endpoint(.delegate(.responseReceived(linkID: linkID, requestID: Data([1]),
        data: MsgPack.encode(.bool(false))))))
    store.exhaustivity = .on   // a stray sendResourceOverLink would fail teardown
}

/// linkEstablished for a dest NOT in pendingSyncPeers (an inbound responder link) is ignored — no offer.
@Test @MainActor func pnNodeInboundLinkEstablishedIgnored() async {
    let store = makeStore(Identity())
    let linkID = Data(repeating: 0xD1, count: 16)
    await store.send(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: Data(repeating: 0xEE, count: 16)))))
    store.exhaustivity = .on   // a stray identify/sendRequest would fail teardown
}
```

- [ ] **Step 7: Run the new tests; confirm green.**

Run: `swift test --filter pnNode`
Expected: all PASS (new initiator tests + existing responder/get tests).

- [ ] **Step 8: Mutation-verify (one at a time, revert between each).**

- Mutation A — drop the IDENTIFY from the offer: in the `linkEstablished` handler, return only the `sendRequestOverLink` (no `.merge` with `identifyOverLink`). Run `swift test --filter pnNodeSyncToPeerOffersOnLinkEstablished` → must FAIL (no `identifyOverLink` received). Revert → PASS.
- Mutation B — break the transfer gather: in `responseReceived`, `return .none` instead of `sendResourceOverLink`. Run `swift test --filter pnNodeTransfersWantedListOnOfferResponse` → must FAIL (no transfer). Revert → PASS.
- Mutation C — ignore `true`: in `responseReceived`, change the `.bool(true)` case to `wanted = []`. Run `swift test --filter pnNodeTransfersAllOnTrueResponse` → must FAIL (no transfer). Revert → PASS.

- [ ] **Step 9: Run the full ReTiCANode suite; confirm green.**

Run: `swift test --filter ReTiCANodeTests`
Expected: all PASS.

- [ ] **Step 10: Commit.** (column-0 trailers)

Write the message to `/tmp/ReTiCA/commit-msg-p4b2-task1.txt`, then:
```bash
git add Sources/ReTiCANode/PNNode.swift Tests/ReTiCANodeTests/PNNodeTests.swift
git commit -F /tmp/ReTiCA/commit-msg-p4b2-task1.txt
```
Suggested subject: `feat: LXMF propagation P4b-2 task 1 — PNNode mesh initiator wiring`

---

### Task 2: 2-PNNode mesh integration test (capstone)

Prove the full bidirectional mesh over real transport: PN-A syncs its stored message to PN-B, and PN-B ingests it.

**Files:**
- Test: `Tests/ReTiCANodeTests/PNNodeMeshTests.swift` (create)

**Interfaces:**
- Consumes: `PNNode` (initiator Task 1 + responder P4a); `Endpoint`; `LXMFPropagation.pack`/`.parseContainer`/`.transientId`.

- [ ] **Step 1: Write the 2-PNNode integration test.**

Create `Tests/ReTiCANodeTests/PNNodeMeshTests.swift`. Both PN-A and PN-B are `PNNode`s (actions wrapped `.endpoint(...)`/`.node(...)`). PN-A holds a message and initiates; PN-B is empty and responds via its P4a responder, then ingests the transfer. Model the link handshake + IDENTIFY + inline request/response + Resource-transfer bridges on `PNNodeIntegrationTests.swift`, `LXMFNodePropagationTests.swift`, and `EndpointTests.twoEndpointsIdentifyAndRoundTripARequest`. Keep the message short so the offer/response stay inline (the container transfer is a Resource).

Sketch (implementer reconciles the exact receive/bridge interleaving by running; recall the synchronous-multi-send index gotcha — e.g. A's IDENTIFY + `/offer` request may co-emit within one receive):

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// Full bidirectional PN↔PN mesh over a real link: PN-A (holding a message) syncs to PN-B — A offers its
/// transient_ids, B (P4a responder) returns the ones it wants, A transfers them as a Resource, and B ingests.
/// Proves initiator (P4b) + responder (P4a) compose end-to-end.
@Test @MainActor func pnNodeMeshSyncTransfersStoredMessage() async {
    let clock = TestClock()
    let aIdentity = Identity(); let bIdentity = Identity()
    let sender = Identity(); let recipient = Identity()
    let msg = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: recipient.hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("mesh".utf8))
    let (container, _) = LXMFPropagation.pack(message: msg, recipientIdentity: recipient, timestamp: 1700000000.5)
    let tid = LXMFPropagation.transientId(lxmfData: LXMFPropagation.parseContainer(container)!.entries[0])
    let bPropDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                aspects: ["propagation"], identity: bIdentity)!

    // makeA/makeB: TestStore<PNNode.State, PNNode.Action> (PNNode(), identities aIdentity/bIdentity, TestClock,
    // $0.date = .constant(1700000000), $0.uuid = .incrementing, exhaustivity = .off), each with its events
    // continuation + a sent LockIsolated<[Data]>. Connect both.
    // ... build (a, eventsA, sentA) and (b, eventsB, sentB) ...

    // Pre-populate A's store: inject a container so A holds `tid` (inject resourceReceived on a dummy link,
    // OR construct A's initialState with node.store.ingest(container:)). Assert A.messagesStored.
    // B.registerPropagation → announce bridged to A so A learns B's propagation dest (path + identity).
    // A.syncToPeer(bPropDest.hash) → open link → bridge the handshake (A initiator ↔ B responder).
    // A emits IDENTIFY + /offer request → bridge to B → B (P4a) validates + responds wanted list → bridge back.
    // A responseReceived → builds the wanted container → sendResourceOverLink → bridge the resource frames to B →
    //   B resourceReceived → ingestContainer → B.delegate.messagesStored([tid]).

    // Final assertions (load-bearing):
    // #expect B emitted .delegate(.messagesStored) containing tid
    #expect(b.state.node.store.contains(transientId: tid))   // B now holds A's message
}
```

The implementer completes the harness/bridging (copy the makeA/makeB + announce + link-handshake + request/response + resource bridges from the referenced tests). The final assertion (`b.state.node.store.contains(transientId: tid)` and B's `messagesStored`) is load-bearing and must not change.

- [ ] **Step 2: Run the integration test.**

Run: `swift test --filter pnNodeMeshSyncTransfersStoredMessage`
Expected: PASS. Reconcile intermediate `receive` predicates to the real emission order if needed; do NOT change the final assertions. (`swift package clean` first if it stale-links.)

- [ ] **Step 3: Mutation-verify (one at a time, revert between each).**

- Mutation A — in `PNNode.responseReceived`, `return .none` (no transfer). Run the Step 2 filter → must FAIL (B never ingests → `contains(tid) == false`). Revert → PASS.
- Mutation B — in `PNNode.requestFromPeer` (the P4a responder), `return .none` (no wanted response). Run → must FAIL (A gets no response → no transfer → B empty). Revert → PASS.

- [ ] **Step 4: Run the full ReTiCANode suite; confirm green.**

Run: `swift test --filter ReTiCANodeTests`
Expected: all PASS.

- [ ] **Step 5: Commit.** (column-0 trailers)

Write the message to `/tmp/ReTiCA/commit-msg-p4b2-task2.txt`, then:
```bash
git add Tests/ReTiCANodeTests/PNNodeMeshTests.swift
git commit -F /tmp/ReTiCA/commit-msg-p4b2-task2.txt
```
Suggested subject: `feat: LXMF propagation P4b-2 task 2 — 2-PNNode mesh integration test`

---

## Self-Review

**Spec coverage:**
- `pendingSyncPeers` + `offerLinks` state → Task 1 Step 1. ✅
- `syncToPeer → openLink` → Step 2. ✅
- Outbound `linkEstablished` (gated) → IDENTIFY-first + offer `[cost-0 key, transientIds]` → Step 3. ✅
- `responseReceived` parse `false`/`true`/list → gather → container → transfer → Step 4. ✅
- Inbound `linkEstablished` ignored → Step 3 guard + test. ✅
- Unit tests (offer, list/true/false transfer, inbound-ignore) → Step 6; 2-PNNode capstone → Task 2. ✅
- No per-peer tracking / PoW key / registry / scheduling / teardown → absent by construction; Global Constraints call it out. ✅

**Placeholder scan:** Task 1 fully concrete. Task 2 is a structured sketch (the multi-store bridge is reconciled by running, per prior slices) with concrete final assertions + exact named source models.

**Type consistency:** `syncToPeer(destinationHash:)`, `openLink(destinationHash:)`, `linkEstablished(linkID:destinationHash:)`, `identifyOverLink(linkID:identity:)`, `sendRequestOverLink(linkID:path:data:)`, `responseReceived(linkID:requestID:data:)`, `sendResourceOverLink(linkID:data:)`, `store.transientIds`, `store.entries(forTransientIds:)`, `LXMFPropagation.container(timestamp:entries:)`/`.parseContainer`, `MsgPackValue.bool`/`.array`/`.bin` all match the current sources. New tests reuse `makeStore` and the container helpers in `PNNodeTests.swift`.
