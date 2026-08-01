# LXMF Propagation P3b — PNNode Server Composition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `PNNode` reducer composing `Endpoint` + `PropagationNode` that registers/announces `lxmf.propagation`, ingests clients' containers, and serves the two-phase `/get` download — the propagation-node server role.

**Architecture:** New `PNNode` @Reducer (two `Scope`s). Serves `/get` via the unregistered-request surface (registered paths auto-respond through a static dependency that can't read the store). Translations: `registerPropagation` → register + `PNAnnounce` announce; `resourceReceived → node.ingestContainer`; `linkIdentified →` per-link client identity; `requestReceived("/get")` → phase dispatch to P3a serve actions; `deliverMessageList`/`deliverMessages` → `sendResponseOverLink` correlated via a `pendingGet[dest] = (linkID, requestID)` map. No `Endpoint`/`PropagationNode`/core changes.

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
- **Non-exhaustive TCA tests** (`store.exhaustivity = .off`), asserting outcomes; flip `.on` last to assert an absence.
- **Ed25519 + the propagation encrypted tail are hedged** — never byte-compare a signature/blob/transientId; deterministic content/hash/`transientId` and signature VALIDATION are the allowed assertions.
- **Scope:** the `PNNode` server composition only. Do NOT wire the 3-store loop, `transfer_limit`/`max_messages`, packet (non-resource) ingest, or P3c propagation-accept confirmation.
- If `swift test` shows a stale cross-module link error, run `swift package clean` then retry.

---

### Task 1: PNNode reducer + injected-delegate unit tests

Create the `PNNode` composition and prove all server logic by injecting Endpoint delegate actions directly (no link handshake — the transport is already proven by EndpointTests/P1/P2).

**Files:**
- Create: `Sources/ReTiCANode/PNNode.swift`
- Test: `Tests/ReTiCANodeTests/PNNodeTests.swift` (create)
- Modify: `Package.swift` only if a new source file needs registering (ReTiCANode target globs its sources — check; usually no change).

**Interfaces:**
- Consumes: `Endpoint` (`registerLocalDestination(Destination)`, `announce(destinationHash:appData:)`, `sendResponseOverLink(linkID:requestID:data:)`, delegates `resourceReceived(linkID:data:)`, `linkIdentified(linkID:remoteIdentity:)`, `requestReceived(linkID:requestID:pathHash:data:)`); `PropagationNode` (`ingestContainer(_:)`, `messageListRequested(destinationHash:)`, `messagesRequested(destinationHash:wants:haves:)`, delegates `stored(transientIds:)`, `deliverMessageList(destinationHash:transientIds:)`, `deliverMessages(destinationHash:entries:)`); `Destination`, `LXMessage.appName`/`.deliveryHash(identityHash:)`, `PNAnnounce`, `Crypto.truncatedHash(_:)`, `MsgPack`/`MsgPackValue`.
- Produces (for Task 2 / P3c): `PNNode` with `registerPropagation` action and `Delegate.messagesStored(transientIds:)`.

- [ ] **Step 1: Create `Sources/ReTiCANode/PNNode.swift`.**

```swift
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCATransport

/// LXMF propagation-node SERVER composition (P3b): composes `Endpoint` + `PropagationNode` so a node
/// registers/announces `lxmf.propagation`, ingests clients' concluded containers, and serves the two-phase
/// `/get` download. `/get` is handled via the unregistered-request surface (registered paths auto-respond
/// through a static dependency that cannot read the store). Mirrors lxmf 1.1.0 LXMRouter propagation serve.
@Reducer
public struct PNNode {
    @ObservableState
    public struct State: Equatable {
        public var endpoint: Endpoint.State
        public var node: PropagationNode.State
        public var identity: Identity
        public var clientIdentities: [Data: Identity] = [:]   // linkID → IDENTIFY'd client
        public var pendingGet: [Data: PendingGet] = [:]        // client delivery hash → (linkID, requestID)
        public init(identity: Identity, endpoint: Endpoint.State, storageLimitBytes: Int? = nil) {
            self.identity = identity
            self.endpoint = endpoint
            self.node = PropagationNode.State(storageLimitBytes: storageLimitBytes)
        }
    }

    public struct PendingGet: Equatable {
        public var linkID: Data
        public var requestID: Data
    }

    public enum Action: Equatable {
        case endpoint(Endpoint.Action)
        case node(PropagationNode.Action)
        case registerPropagation
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case messagesStored(transientIds: [Data])
        }
    }

    @Dependency(\.date) var date
    public init() {}

    private static func arrayOfBin(_ value: MsgPackValue) -> [Data] {
        guard case let .array(items) = value else { return [] }
        return items.compactMap { if case let .bin(d) = $0 { return d } else { return nil } }
    }

    public var body: some ReducerOf<Self> {
        Scope(state: \.endpoint, action: \.endpoint) { Endpoint() }
        Scope(state: \.node, action: \.node) { PropagationNode() }
        Reduce { [date] state, action in
            switch action {
            case .registerPropagation:
                guard let d = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                          aspects: ["propagation"], identity: state.identity) else { return .none }
                let appData = PNAnnounce(timebase: Int(date.now.timeIntervalSince1970), nodeState: true,
                                         perTransferLimit: 0, perSyncLimit: 0, targetStampCost: 0,
                                         stampCostFlexibility: 0, peeringCost: 0).packed
                return .merge(.send(.endpoint(.registerLocalDestination(d))),
                              .send(.endpoint(.announce(destinationHash: d.hash, appData: appData))))

            case let .endpoint(.delegate(.resourceReceived(_, data))):
                return .send(.node(.ingestContainer(data)))

            case let .node(.delegate(.stored(tids))):
                return .send(.delegate(.messagesStored(transientIds: tids)))

            case let .endpoint(.delegate(.linkIdentified(linkID, remoteIdentity))):
                state.clientIdentities[linkID] = remoteIdentity
                return .none

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

            case let .node(.delegate(.deliverMessageList(dest, ids))):
                guard let p = state.pendingGet[dest] else { return .none }
                state.pendingGet[dest] = nil
                return .send(.endpoint(.sendResponseOverLink(linkID: p.linkID, requestID: p.requestID,
                                                             data: MsgPack.encode(.array(ids.map { .bin($0) })))))

            case let .node(.delegate(.deliverMessages(dest, entries))):
                guard let p = state.pendingGet[dest] else { return .none }
                state.pendingGet[dest] = nil
                return .send(.endpoint(.sendResponseOverLink(linkID: p.linkID, requestID: p.requestID,
                                                             data: MsgPack.encode(.array(entries.map { .bin($0) })))))

            case .endpoint, .node, .delegate:
                return .none
            }
        }
    }
}
```

- [ ] **Step 2: Confirm it compiles.**

Run: `swift build`
Expected: builds clean. (If `Package.swift` uses explicit source lists rather than globbing, add `PNNode.swift`; otherwise no change.)

- [ ] **Step 3: Write the injected-delegate unit tests.**

Create `Tests/ReTiCANodeTests/PNNodeTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private func makeStore(_ pnIdentity: Identity) -> TestStore<PNNode.State, PNNode.Action> {
    let store = TestStore(initialState: PNNode.State(
        identity: pnIdentity, endpoint: Endpoint.State(host: "pn", port: 4242, reconnectOnDrop: false))
    ) { PNNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

/// registerPropagation registers the lxmf.propagation destination and announces valid PNAnnounce app-data.
@Test @MainActor func pnNodeRegistersAndAnnounces() async {
    let store = makeStore(Identity())
    let gotAppData = LockIsolated<Data?>(nil)
    await store.send(.registerPropagation)
    await store.receive { if case .endpoint(.registerLocalDestination) = $0 { return true }; return false }
    await store.receive { action in
        if case let .endpoint(.announce(_, appData)) = action { gotAppData.setValue(appData); return true }
        return false
    }
    #expect(gotAppData.value != nil)
    #expect(PNAnnounce.isValid(gotAppData.value!))
}

/// A concluded container (resourceReceived) is ingested and surfaced as messagesStored.
@Test @MainActor func pnNodeIngestsConcludedContainer() async {
    let client = Identity(); let sender = Identity()
    let msg = LXMessage.create(source: sender, destinationHash: LXMessage.deliveryHash(identityHash: client.hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("hi".utf8))
    let (container, _) = LXMFPropagation.pack(message: msg, recipientIdentity: client, timestamp: 1700000000.5)
    let entry = LXMFPropagation.parseContainer(container)!.entries[0]
    let tid = LXMFPropagation.transientId(lxmfData: entry)
    let store = makeStore(Identity())
    let linkID = Data(repeating: 0xA0, count: 16)
    await store.send(.endpoint(.delegate(.resourceReceived(linkID: linkID, data: container))))
    await store.receive { action in
        if case let .delegate(.messagesStored(tids)) = action { #expect(tids == [tid]); return true }
        return false
    }
    #expect(store.state.node.store.contains(transientId: tid))
}

/// Full serve: ingest a message for client C, IDENTIFY the link as C, then the two /get phases return the
/// id list (phase-1) and the blob (phase-2).
@Test @MainActor func pnNodeServesTwoPhaseGet() async {
    let client = Identity(); let sender = Identity()
    let clientHash = LXMessage.deliveryHash(identityHash: client.hash)
    let msg = LXMessage.create(source: sender, destinationHash: clientHash,
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("hi".utf8))
    let (container, _) = LXMFPropagation.pack(message: msg, recipientIdentity: client, timestamp: 1700000000.5)
    let entry = LXMFPropagation.parseContainer(container)!.entries[0]
    let tid = LXMFPropagation.transientId(lxmfData: entry)
    let getPath = Crypto.truncatedHash(Data("/get".utf8))
    let store = makeStore(Identity())
    let linkID = Data(repeating: 0xA0, count: 16)

    await store.send(.endpoint(.delegate(.resourceReceived(linkID: linkID, data: container))))
    await store.receive { if case .delegate(.messagesStored) = $0 { return true }; return false }
    await store.send(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: client))))

    // Phase-1: [null,null] → id list.
    await store.send(.endpoint(.delegate(.requestReceived(linkID: linkID, requestID: Data([1]),
        pathHash: getPath, data: MsgPack.encode(.array([.null, .null]))))))
    await store.receive { action in
        if case let .endpoint(.sendResponseOverLink(lid, rid, data)) = action {
            #expect(lid == linkID); #expect(rid == Data([1]))
            #expect(MsgPack.decodeValue(data) == .array([.bin(tid)])); return true
        }
        return false
    }

    // Phase-2: [[tid],[]] → the blob.
    await store.send(.endpoint(.delegate(.requestReceived(linkID: linkID, requestID: Data([2]),
        pathHash: getPath, data: MsgPack.encode(.array([.array([.bin(tid)]), .array([])]))))))
    await store.receive { action in
        if case let .endpoint(.sendResponseOverLink(_, rid, data)) = action {
            #expect(rid == Data([2]))
            #expect(MsgPack.decodeValue(data) == .array([.bin(entry)])); return true
        }
        return false
    }
}

/// A /get without a prior IDENTIFY on the link is dropped (no response).
@Test @MainActor func pnNodeDropsGetWithoutIdentify() async {
    let getPath = Crypto.truncatedHash(Data("/get".utf8))
    let store = makeStore(Identity())
    let linkID = Data(repeating: 0xA0, count: 16)
    await store.send(.endpoint(.delegate(.requestReceived(linkID: linkID, requestID: Data([1]),
        pathHash: getPath, data: MsgPack.encode(.array([.null, .null]))))))
    store.exhaustivity = .on   // a stray sendResponseOverLink / node action would fail teardown
}
```

- [ ] **Step 4: Run the unit tests; confirm green.**

Run: `swift test --filter pnNode`
Expected: all PASS. (If it stale-links, run `swift package clean` first.)

- [ ] **Step 5: Mutation-verify (one at a time, revert between each).**

- Mutation A — drop the identity guard: in `requestReceived`, remove the `guard let clientIdentity = state.clientIdentities[linkID] else { return .none }` and hardcode `let clientIdentity = state.identity`. Run `swift test --filter pnNodeDropsGetWithoutIdentify` → must FAIL (now serves without IDENTIFY → a stray action fails the `.on` teardown). Revert → PASS.
- Mutation B — break the correlation: in `deliverMessageList`, `return .none` instead of sending the response. Run `swift test --filter pnNodeServesTwoPhaseGet` → must FAIL (phase-1 response never sent). Revert → PASS.
- Mutation C — drop the ingest wire: in `resourceReceived`, `return .none`. Run `swift test --filter pnNodeIngestsConcludedContainer` → must FAIL (no `messagesStored`, store empty). Revert → PASS.

- [ ] **Step 6: Run the full ReTiCANode suite; confirm green.**

Run: `swift test --filter ReTiCANodeTests`
Expected: all PASS.

- [ ] **Step 7: Commit.**

Write the message to `/tmp/ReTiCA/commit-msg-p3b-task1.txt` (verbatim trailers), then:

```bash
git add Sources/ReTiCANode/PNNode.swift Tests/ReTiCANodeTests/PNNodeTests.swift
git commit -F /tmp/ReTiCA/commit-msg-p3b-task1.txt
```

(If `Package.swift` changed, add it too.)

Suggested subject: `feat: LXMF propagation P3b task 1 — PNNode server composition`

---

### Task 2: 2-store real-transport integration test

Prove ingest + two-phase serve over a real link: a bare-`Endpoint` client establishes a link to `PNNode`, sends a container as a Resource, then IDENTIFYs and runs the two-phase `/get`.

**Files:**
- Test: `Tests/ReTiCANodeTests/PNNodeIntegrationTests.swift` (create)

**Interfaces:**
- Consumes: `PNNode` (Task 1); `Endpoint`; `LXMFPropagation.pack`/`.parseContainer`/`.open`/`.transientId`; `Crypto.truncatedHash`.

- [ ] **Step 1: Write the integration test.**

Create `Tests/ReTiCANodeTests/PNNodeIntegrationTests.swift`. The PN is a `PNNode`; the client `C` is a bare `Endpoint` (the test drives its link/resource/identify/request and inspects `responseReceived`). Model the announce + link-handshake + Resource send on `LXMFNodePropagationTests.swift`, and the IDENTIFY + inline request/response on `EndpointTests.twoEndpointsIdentifyAndRoundTripARequest` (EndpointTests.swift:667-740). `C` is both the link peer AND the recipient of the stored message (so it can `open` the served blob). Keep the message content SHORT so the phase-2 response stays inline (< `Link.mdu = 431`).

Sketch (implementer reconciles the exact `receive`/bridge interleaving by running — `.off` tolerates skipped intermediate receives; recall the synchronous-multi-send index gotcha; PN actions are wrapped `.endpoint(...)`/`.node(...)`, the client's are bare `Endpoint.Action`):

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// End-to-end over a real link: client C sends a container to a PNNode (ingested), then C IDENTIFYs and
/// runs the two-phase /get; the PN serves C's message list and blob, and C opens the blob to the original
/// signature-valid message. Closes the store-and-forward server loop at the wire level. (Full 3-store
/// LXMFNode↔PNNode↔LXMFNode loop is a capstone follow-on.)
@Test @MainActor func pnNodeIngestsAndServesOverRealLink() async {
    let clock = TestClock()
    let pnIdentity = Identity()
    let cIdentity = Identity()      // the client AND the recipient of the stored message
    let sIdentity = Identity()      // the original sender
    let cDeliveryHash = LXMessage.deliveryHash(identityHash: cIdentity.hash)

    // The message C will retrieve, packed as a container for C.
    let msg = LXMessage.create(source: sIdentity, destinationHash: cDeliveryHash,
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("hi C".utf8))
    let (container, _) = LXMFPropagation.pack(message: msg, recipientIdentity: cIdentity, timestamp: 1700000000.5)
    let entry = LXMFPropagation.parseContainer(container)!.entries[0]
    let tid = LXMFPropagation.transientId(lxmfData: entry)

    // makePN: TestStore<PNNode.State, PNNode.Action> (PNNode(), identity: pnIdentity, TestClock, date const, uuid).
    // makeClient: TestStore<Endpoint.State, Endpoint.Action> (Endpoint(), same deps). Both exhaustivity = .off.
    // ... build (pn, eventsPN, sentPN) and (c, eventsC, sentC) ...

    // Connect both; PN.registerPropagation → announce bridged to C so C learns the PN's propagation dest.
    // C opens a link to the PN dest; bridge the handshake (LINKREQUEST/LRPROOF/LRRTT).
    // C sends the container as a Resource (sendResourceOverLink) → bridge the resource frames to PN →
    //   assert PN emits .delegate(.messagesStored([tid])).
    // C identifies (identifyOverLink(cIdentity)) → bridge to PN (PN records clientIdentities).
    // C requests /get [null,null] → bridge → PN serves → bridge response back → C responseReceived == [tid].
    // C requests /get [[tid],[]] → bridge → PN serves → bridge back → C responseReceived == [entry].

    let gotList = LockIsolated<Data?>(nil); let gotBlob = LockIsolated<Data?>(nil)
    // capture the two responseReceived payloads on C

    #expect(MsgPack.decodeValue(gotList.value!) == .array([.bin(tid)]))
    let served = MsgPack.decodeValue(gotBlob.value!)
    #expect(served == .array([.bin(entry)]))
    let recovered = LXMFPropagation.open(lxmfData: entry, recipientIdentity: cIdentity)
    #expect(recovered?.content == Data("hi C".utf8))
    #expect(recovered?.validateSignature(source: sIdentity) == true)
}
```

The implementer completes the harness/bridging (copy `makePN`/`makeClient` and the announce + link-handshake + resource-send bridge from `LXMFNodePropagationTests.swift`, and the identify/request/response bridge from `EndpointTests.twoEndpointsIdentifyAndRoundTripARequest`). The final assertions (`messagesStored`, the two response payloads, and `open`+`validateSignature`) are load-bearing and must not change. Send the client's `identifyOverLink` before the first `/get` so the PN records the identity.

- [ ] **Step 2: Run the integration test.**

Run: `swift test --filter pnNodeIngestsAndServesOverRealLink`
Expected: PASS. Reconcile intermediate `receive` predicates to the real emission order if needed; do NOT change the final assertions.

- [ ] **Step 3: Mutation-verify (one at a time, revert between each).**

- Mutation A — in `PNNode`'s `resourceReceived`, `return .none`. Run the Step 2 filter → must FAIL (no ingest → phase-1 returns empty → `gotList != [tid]`). Revert → PASS.
- Mutation B — in `PNNode`'s `deliverMessages`, `return .none`. Run → must FAIL (phase-2 blob never served → `gotBlob` nil). Revert → PASS.

- [ ] **Step 4: Run the full ReTiCANode suite; confirm green.**

Run: `swift test --filter ReTiCANodeTests`
Expected: all PASS.

- [ ] **Step 5: Commit.**

Write the message to `/tmp/ReTiCA/commit-msg-p3b-task2.txt` (verbatim trailers), then:

```bash
git add Tests/ReTiCANodeTests/PNNodeIntegrationTests.swift
git commit -F /tmp/ReTiCA/commit-msg-p3b-task2.txt
```

Suggested subject: `feat: LXMF propagation P3b task 2 — PNNode ingest+serve real-transport integration test`

---

## Self-Review

**Spec coverage:**
- `PNNode` composition (Scope endpoint + node) + State (clientIdentities, pendingGet) → Task 1 Step 1. ✅
- `registerPropagation` register + `PNAnnounce` announce → Step 1, test `pnNodeRegistersAndAnnounces`. ✅
- Ingest `resourceReceived → ingestContainer → messagesStored` → Step 1, test `pnNodeIngestsConcludedContainer`. ✅
- IDENTIFY tracking + `/get` phase dispatch (unregistered-surface, pathHash guard, no-identity drop) → Step 1, tests `pnNodeServesTwoPhaseGet`/`pnNodeDropsGetWithoutIdentify`. ✅
- Response correlation via `pendingGet` → Step 1, `pnNodeServesTwoPhaseGet`. ✅
- Real-transport ingest + serve → Task 2. ✅
- No 3-store loop / transfer-limit / packet ingest / P3c → absent by construction; Global Constraints call it out. ✅
- Hedged values not byte-compared (deterministic `tid`/`entry` via msgpack equality, `open`+`validateSignature`) → tests. ✅

**Placeholder scan:** Task 1 is fully concrete. The Task 2 test is a sketch with an explicit "implementer completes the harness" directive and exact named source models — acceptable for the intricate 2-store bridge; all production code and load-bearing assertions are concrete.

**Type consistency:** `resourceReceived(linkID:data:)`, `linkIdentified(linkID:remoteIdentity:)`, `requestReceived(linkID:requestID:pathHash:data:)`, `sendResponseOverLink(linkID:requestID:data:)`, `registerLocalDestination(_)`, `announce(destinationHash:appData:)`, `ingestContainer(_)`, `messageListRequested(destinationHash:)`, `messagesRequested(destinationHash:wants:haves:)`, `deliverMessageList(destinationHash:transientIds:)`, `deliverMessages(destinationHash:entries:)`, `Crypto.truncatedHash(_)`, `PNAnnounce(...).packed`/`.isValid`, `LXMFPropagation.pack`/`.parseContainer`/`.open`/`.transientId` all match the current sources. `MsgPackValue.null`/`.array`/`.bin` confirmed present.
