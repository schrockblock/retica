# LXMF Propagation P2b — Client Sync Endpoint Glue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the P2a router download state machine to real transport in `LXMFNode`, so a client syncs messages from a propagation node over a link (IDENTIFY + two `/get` request/response round-trips + open + deliver).

**Architecture:** Task 1 adds a small symmetric core helper `LXMFPropagation.recoverPacked` (decrypt one entry to packed LXMF bytes; `open` refactors to `unpack(recoverPacked(...))`). Task 2 adds the `LXMFNode` sync state machine: a `syncFromPropagationNode` trigger, per-link `syncPhase` state, and the request/response translations. No `Endpoint`/`LXMFRouter` changes (P2a already built the router side). MsgPack needs no change — `.null` already exists.

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
- **Non-exhaustive TCA tests** (`store.exhaustivity = .off`), asserting outcomes.
- **Ed25519 and the propagation encrypted tail are hedged/randomized** — never byte-compare a signature or a container/entry; `message.packed`, `message.hash`, and `transientId(entry)` are deterministic given a fixed entry and are safe to compare.
- **Scope:** client-side sync glue only. Do NOT wire the PN server (P3), PN↔PN mesh (P4), `max_messages`/`retain`, or stamped-message transient_id correlation.
- The `"/get"` request path string is `LXMPeer.MESSAGE_GET_PATH` in RNS; use the literal `"/get"`.
- If `swift test` shows a stale cross-module link error, run `swift package clean` then retry.

---

### Task 1: LXMFPropagation.recoverPacked

Extract the decrypt-to-packed step into a reusable, testable helper and refactor `open` onto it.

**Files:**
- Modify: `Sources/ReTiCA/LXMF/LXMFPropagation+Message.swift`
- Test: `Tests/ReTiCATests/LXMFPropagationRecoverPackedTests.swift` (create)

**Interfaces:**
- Consumes: `LXMFPropagation.destinationHash(lxmfData:)`, `Identity.decrypt(_:) -> Data?`, `LXMessage.destinationLength`, `LXMessage.unpack(_:)`.
- Produces (for Task 2): `LXMFPropagation.recoverPacked(lxmfData: Data, recipientIdentity: Identity) -> Data?`.

- [ ] **Step 1: Add `recoverPacked` and refactor `open`.**

In `Sources/ReTiCA/LXMF/LXMFPropagation+Message.swift`, replace the existing `open` method:

```swift
    public static func open(lxmfData: Data, recipientIdentity: Identity) -> LXMessage? {
        guard let destHash = destinationHash(lxmfData: lxmfData) else { return nil }
        let encrypted = Data(lxmfData.dropFirst(LXMessage.destinationLength))
        guard let tail = recipientIdentity.decrypt(encrypted) else { return nil }
        return LXMessage.unpack(destHash + tail)
    }
```
with:
```swift
    /// Recover the packed LXMF wire bytes (destinationHash ‖ decrypted tail) from one container/download
    /// entry, decrypting the tail with `recipientIdentity`. Nil if malformed or decryption fails. The
    /// symmetric inverse of `pack`'s encryption step; `open` is `unpack(recoverPacked(...))`.
    public static func recoverPacked(lxmfData: Data, recipientIdentity: Identity) -> Data? {
        guard let destHash = destinationHash(lxmfData: lxmfData) else { return nil }
        let encrypted = Data(lxmfData.dropFirst(LXMessage.destinationLength))
        guard let tail = recipientIdentity.decrypt(encrypted) else { return nil }
        return destHash + tail
    }

    /// Recover the LXMessage from one container entry by decrypting its tail with `recipientIdentity`.
    /// Returns nil if the entry is malformed or decryption/unpack fails.
    public static func open(lxmfData: Data, recipientIdentity: Identity) -> LXMessage? {
        guard let packed = recoverPacked(lxmfData: lxmfData, recipientIdentity: recipientIdentity) else { return nil }
        return LXMessage.unpack(packed)
    }
```

- [ ] **Step 2: Write the failing unit test.**

Create `Tests/ReTiCATests/LXMFPropagationRecoverPackedTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

/// recoverPacked is the inverse of pack's encryption step: for an entry packed to R, it reproduces the
/// original message.packed bytes (so the router's received(.direct) path can consume it), and open() is
/// just unpack(recoverPacked). A wrong recipient identity fails to decrypt → nil.
@Test func recoverPackedReproducesPackedBytesAndOpenRoundTrips() {
    let sender = Identity()
    let recipient = Identity()
    let msg = LXMessage.create(source: sender,
                               destinationHash: LXMessage.deliveryHash(identityHash: recipient.hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("hello".utf8))
    let (container, _) = LXMFPropagation.pack(message: msg, recipientIdentity: recipient, timestamp: 1700000000.5)
    let entries = LXMFPropagation.parseContainer(container)!.entries
    #expect(entries.count == 1)
    let entry = entries[0]

    let packed = LXMFPropagation.recoverPacked(lxmfData: entry, recipientIdentity: recipient)
    #expect(packed == msg.packed)                                   // deterministic wire bytes reproduced

    let opened = LXMFPropagation.open(lxmfData: entry, recipientIdentity: recipient)
    #expect(opened?.hash == msg.hash)
    #expect(opened?.validateSignature(source: sender) == true)      // real Ed25519 validation

    #expect(LXMFPropagation.recoverPacked(lxmfData: entry, recipientIdentity: Identity()) == nil)  // wrong key
}
```

- [ ] **Step 3: Run the test; confirm it passes.**

Run: `swift test --filter recoverPackedReproducesPackedBytesAndOpenRoundTrips`
Expected: PASS. (If it stale-links, run `swift package clean` first.)

- [ ] **Step 4: Mutation-verify (one at a time, revert between each).**

- Mutation A — break the reconstruction: in `recoverPacked`, `return tail` instead of `destHash + tail`. Run the Step 3 filter → must FAIL (`packed != msg.packed`, and `open` can't unpack). Revert → PASS.
- Mutation B — drop the decrypt guard: in `recoverPacked`, change the wrong-key path by replacing `recipientIdentity.decrypt(encrypted)` with `Data()` on failure — concretely, replace the `guard let tail = ... else { return nil }` with `let tail = recipientIdentity.decrypt(encrypted) ?? Data()`. Run → must FAIL (wrong-key case no longer returns nil). Revert → PASS.

- [ ] **Step 5: Run the ReTiCA propagation suites; confirm green.**

Run: `swift test --filter LXMFPropagation`
Expected: all PASS (the `open` refactor is behavior-preserving).

- [ ] **Step 6: Commit.**

Write the message to `/tmp/ReTiCA/commit-msg-p2b-task1.txt` (verbatim trailers), then:

```bash
git add Sources/ReTiCA/LXMF/LXMFPropagation+Message.swift Tests/ReTiCATests/LXMFPropagationRecoverPackedTests.swift
git commit -F /tmp/ReTiCA/commit-msg-p2b-task1.txt
```

Suggested subject: `feat: LXMF propagation P2b task 1 — LXMFPropagation.recoverPacked`

---

### Task 2: LXMFNode client-sync wiring + integration test

Add the sync trigger, the per-link phase state, and the IDENTIFY + two-phase `/get` request/response translations to `LXMFNode`; prove it with a 2-store integration test where the test plays the PN server.

**Files:**
- Modify: `Sources/ReTiCANode/LXMFNode.swift`
- Test: `Tests/ReTiCANodeTests/LXMFNodeSyncTests.swift` (create)

**Interfaces:**
- Consumes: `LXMFRouter.Action.syncFromPropagationNode`, `.offeredMessageList(transientIds:)`, `.messagesDownloaded(transientIds:)`, `.received(method:destinationHash:data:)`; `LXMFRouter.Action.Delegate.requestMessageList(linkID:)`, `.requestMessages(linkID:wants:haves:)`; `Endpoint.Action.identifyOverLink(linkID:identity:)`, `.sendRequestOverLink(linkID:path:data:)`; `Endpoint.Action.Delegate.responseReceived(linkID:requestID:data:)`; `LXMFPropagation.recoverPacked(lxmfData:recipientIdentity:)`, `.transientId(lxmfData:)`; `MsgPack.encode`, `MsgPack.decodeValue`, `MsgPackValue`.
- Produces: `LXMFNode.Action.syncFromPropagationNode`; `LXMFNode.State.syncPhase`, `LXMFNode.SyncPhase`.

- [ ] **Step 1: Add the `SyncPhase` type and state.**

In `Sources/ReTiCANode/LXMFNode.swift`, add the nested enum inside `struct LXMFNode` (e.g. just before `@ObservableState`):

```swift
    public enum SyncPhase: Equatable { case awaitingList, awaitingMessages }
```

In `State`, after `public var directLinks: [Data: Data] = [:]`, add:

```swift
        public var syncPhase: [Data: SyncPhase] = [:]   // linkID → current download phase (one sync/link)
```

- [ ] **Step 2: Add the `syncFromPropagationNode` action.**

In `Action`, after `case sendViaPropagation(...)`, add:

```swift
        case syncFromPropagationNode
```

- [ ] **Step 3: Add the `syncFromPropagationNode` handler.**

In the `Reduce` body, after the `sendViaPropagation` handler, add:

```swift
            case .syncFromPropagationNode:
                return .send(.router(.syncFromPropagationNode))
```

- [ ] **Step 4: Add the phase-1 and phase-2 request wires.**

Among the direct/propagation translations (before the `.endpoint, .router, .delegate` catch-all), add:

```swift
            case let .router(.delegate(.requestMessageList(linkID))):
                state.syncPhase[linkID] = .awaitingList
                return .merge(
                    .send(.endpoint(.identifyOverLink(linkID: linkID, identity: state.identity))),
                    .send(.endpoint(.sendRequestOverLink(linkID: linkID, path: "/get",
                                                         data: MsgPack.encode(.array([.null, .null]))))))

            case let .router(.delegate(.requestMessages(linkID, wants, haves))):
                state.syncPhase[linkID] = .awaitingMessages
                let payload = MsgPack.encode(.array([.array(wants.map { .bin($0) }),
                                                     .array(haves.map { .bin($0) })]))
                return .send(.endpoint(.sendRequestOverLink(linkID: linkID, path: "/get", data: payload)))
```

- [ ] **Step 5: Add the `responseReceived` phase dispatch wire.**

Immediately after the wires from Step 4, add:

```swift
            case let .endpoint(.delegate(.responseReceived(linkID, _, data))):
                switch state.syncPhase[linkID] {
                case .awaitingList:
                    guard case let .array(items)? = MsgPack.decodeValue(data) else { return .none }
                    let ids = items.compactMap { item -> Data? in
                        if case let .bin(d) = item { return d } else { return nil }
                    }
                    return .send(.router(.offeredMessageList(transientIds: ids)))
                case .awaitingMessages:
                    state.syncPhase[linkID] = nil
                    guard case let .array(items)? = MsgPack.decodeValue(data) else { return .none }
                    let blobs = items.compactMap { item -> Data? in
                        if case let .bin(d) = item { return d } else { return nil }
                    }
                    var effects: [Effect<Action>] = []
                    var tids: [Data] = []
                    for blob in blobs {
                        tids.append(LXMFPropagation.transientId(lxmfData: blob))
                        if let packed = LXMFPropagation.recoverPacked(lxmfData: blob, recipientIdentity: state.identity) {
                            effects.append(.send(.router(.received(method: .direct, destinationHash: Data(), data: packed))))
                        }
                    }
                    effects.append(.send(.router(.messagesDownloaded(transientIds: tids))))
                    return .merge(effects)
                case .none:
                    return .none
                }
```

- [ ] **Step 6: Confirm the existing suites still compile/pass.**

Run: `swift test --filter LXMFNode`
Expected: PASS (additive; `responseReceived` was previously unhandled → `.none`).

- [ ] **Step 7: Write the sync integration test.**

Create `Tests/ReTiCANodeTests/LXMFNodeSyncTests.swift`. Client `A` is an `LXMFNode`; the PN is a bare `Endpoint` where the test plays the server (responding to `requestReceived` via `sendResponseOverLink`). Model the IDENTIFY + inline request/response bridge on `EndpointTests.twoEndpointsIdentifyAndRoundTripARequest` (EndpointTests.swift:667-740) and the link-handshake bridge on `LXMFNodeDirectTests`. Keep the message content short so the phase-2 response stays a single inline packet (below `Link.mdu = 431`), not a Resource.

Sketch (reconcile the exact `receive` interleaving by running — `.off` tolerates skipped intermediate receives, but each network-send effect must be advanced before its bytes are bridged; A's actions are wrapped `.endpoint(...)`, the PN's are bare `Endpoint.Action`; recall the multi-send-in-one-`receive` index gotcha for the IDENTIFY+request pair):

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// End-to-end through LXMFNode: client A syncs from a propagation node. A establishes a link to the PN's
/// lxmf.propagation destination, IDENTIFYs, and runs the two-phase /get exchange (list → wanted → blobs).
/// The PN is a bare Endpoint stub whose two responses the test supplies. A opens the returned blob with its
/// own identity and surfaces the sender's signature-valid message. (PN server logic is P3.)
@Test @MainActor func lxmfNodeSyncsMessagesFromPropagationNode() async {
    let clock = TestClock()
    let aIdentity = Identity()      // client / recipient
    let sIdentity = Identity()      // the original sender of the stored message
    let pnIdentity = Identity()
    let aDeliveryHash = LXMessage.deliveryHash(identityHash: aIdentity.hash)
    let sDelivery = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                aspects: LXMessage.deliveryAspects, identity: sIdentity)!
    let pnDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                             aspects: ["propagation"], identity: pnIdentity)!

    // The stored message (from S to A) and its propagation entry + transient id.
    let storedMsg = LXMessage.create(source: sIdentity, destinationHash: aDeliveryHash,
                                     timestamp: 1700000000.5, title: Data("t".utf8), content: Data("hi A".utf8))
    let (container, _) = LXMFPropagation.pack(message: storedMsg, recipientIdentity: aIdentity, timestamp: 1700000000.5)
    let entry = LXMFPropagation.parseContainer(container)!.entries[0]
    let tid = LXMFPropagation.transientId(lxmfData: entry)

    // makeNode / makeEndpoint harnesses: copy from LXMFNodePropagationTests.swift (LXMFNode + bare Endpoint,
    // TestClock, $0.date = .constant(1700000000.5), $0.uuid = .incrementing, exhaustivity = .off).
    // ... build (a, eventsA) as LXMFNode and (pn, eventsPN) as Endpoint ...

    // Setup: connect all; PN registers + announces lxmf.propagation → A learns PN path/identity;
    // S announces lxmf.delivery → A learns S's identity (to validate the stored message's signature).
    // A.setPropagationNode(pnDest.hash).

    // Sync: A.syncFromPropagationNode → link handshake A↔PN → A emits IDENTIFY + phase-1 /get([null,null]).
    // Bridge to PN; on PN's requestReceived (phase-1), reply:
    //   pn.send(.sendResponseOverLink(linkID: linkID, requestID: rid1, data: MsgPack.encode(.array([.bin(tid)]))))
    // Bridge back → A emits phase-2 /get([[tid],[]]); on PN's requestReceived (phase-2), reply:
    //   pn.send(.sendResponseOverLink(linkID: linkID, requestID: rid2, data: MsgPack.encode(.array([.bin(entry)]))))
    // Bridge back → A surfaces messageReceived.

    let gotContent = LockIsolated<Data?>(nil)
    let gotValidated = LockIsolated<Bool>(false)
    // await a.receive matching .delegate(.messageReceived(m, v)) → capture m.content, v

    #expect(gotContent.value == Data("hi A".utf8))
    #expect(gotValidated.value == true)                        // A learned S → signature validates
    #expect(a.state.router.downloadedTransientIds.contains(tid))
}
```

The implementer completes the harness/bridging (copy the `makeNode`/`makeEndpoint` helpers and the announce+link-handshake steps from `LXMFNodePropagationTests.swift`, and the identify/request/response bridge from `EndpointTests.twoEndpointsIdentifyAndRoundTripARequest`). Final assertions (content, validated, `downloadedTransientIds.contains(tid)`) are load-bearing and must not change.

- [ ] **Step 8: Run the integration test.**

Run: `swift test --filter lxmfNodeSyncsMessagesFromPropagationNode`
Expected: PASS. Reconcile intermediate `receive` predicates to the real emission order if needed; do NOT change the final assertions.

- [ ] **Step 9: Mutation-verify the integration test (one at a time, revert between each).**

- Mutation A — break the phase-2 request wire: in the `requestMessages` wire (Step 4), `return .none` instead of sending the phase-2 request. Run the Step 8 filter → must FAIL (PN never gets phase-2 → no blob → no `messageReceived`). Revert → PASS.
- Mutation B — break the blob delivery: in the `.awaitingMessages` branch (Step 5), skip the `received` effect (e.g. never append it). Run → must FAIL (no `messageReceived`). Revert → PASS.

- [ ] **Step 10: Run the full ReTiCANode suite; confirm green.**

Run: `swift test --filter ReTiCANodeTests`
Expected: all PASS.

- [ ] **Step 11: Commit.**

Write the message to `/tmp/ReTiCA/commit-msg-p2b-task2.txt` (verbatim trailers), then:

```bash
git add Sources/ReTiCANode/LXMFNode.swift Tests/ReTiCANodeTests/LXMFNodeSyncTests.swift
git commit -F /tmp/ReTiCA/commit-msg-p2b-task2.txt
```

Suggested subject: `feat: LXMF propagation P2b task 2 — LXMFNode client-sync wiring + integration test`

---

## Self-Review

**Spec coverage:**
- `recoverPacked` helper + `open` refactor → Task 1 Steps 1-2. ✅
- `SyncPhase` state + `syncFromPropagationNode` trigger → Task 2 Steps 1-3. ✅
- Phase-1 wire (IDENTIFY + `/get [null,null]`) → Step 4. ✅
- Phase-2 wire (`/get [wants,haves]`) → Step 4. ✅
- `responseReceived` phase dispatch (offeredMessageList / recoverPacked→received + messagesDownloaded + clear phase) → Step 5. ✅
- Stub-PN integration test proving open + deliver + validated + downloaded tracking → Step 7. ✅
- No PN-server / mesh / max_messages / retain / stamped-tid work → absent by construction; Global Constraints call it out. ✅
- Hedged values not byte-compared (deterministic `packed`/`hash`/`transientId`, real signature validation) → Steps 2, 7. ✅

**Placeholder scan:** the Task 2 test is a sketch with an explicit "implementer completes the harness" directive and named source models (`LXMFNodePropagationTests`, `EndpointTests.twoEndpointsIdentifyAndRoundTripARequest`) — the load-bearing assertions and all production code are concrete. Acceptable given the intricate multi-store bridge; the models are exact.

**Type consistency:** `recoverPacked(lxmfData:recipientIdentity:) -> Data?`, `SyncPhase`, `syncPhase: [Data: SyncPhase]`, `identifyOverLink(linkID:identity:)`, `sendRequestOverLink(linkID:path:data:)`, `responseReceived(linkID:requestID:data:)`, `offeredMessageList(transientIds:)`, `messagesDownloaded(transientIds:)`, `requestMessageList(linkID:)`, `requestMessages(linkID:wants:haves:)`, `MsgPackValue.null`/`.array`/`.bin`, `transientId(lxmfData:)` all match the surfaces read from the current sources.
