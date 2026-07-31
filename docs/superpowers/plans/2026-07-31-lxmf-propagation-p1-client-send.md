# LXMF Propagation P1 — Client Send-via-PN Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `LXMFNode` builds a propagation container and ships it as a Resource over a link to a configured propagation node's `lxmf.propagation` destination.

**Architecture:** Thin `LXMFNode` wiring only — two new actions (`setPropagationNode`, `sendViaPropagation`) and one new translation (`sendPropagated → sendResourceOverLink`). The router already establishes / reuses / queue-drains a link keyed on the PN hash inside `sendViaPropagation`; all link machinery reuses the existing direct wiring. No `Endpoint`/`LXMFRouter`/core changes. Propagation-accept confirmation is deferred.

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
- **Three-step mutation verification** for the new test: run pass → mutate production to force fail + confirm → revert + confirm pass. One mutation at a time.
- **Non-exhaustive TCA tests** (`store.exhaustivity = .off`), asserting outcomes.
- **Ed25519 is hedged/randomized** — validate signatures, never byte-compare them. The propagation container's encrypted tail is ALSO hedged (non-reproducible per call) — do NOT assert a fixed `transientId` or fixed container bytes; assert the deterministic destination-hash prefix and that `open()` recovers a signature-valid message.
- **Scope:** client-side send only. Do NOT wire propagation-accept confirmation, sync/download (`requestMessageDownload`), or any server-side ingest.
- If `swift test` shows a stale cross-module link error, run `swift package clean` then retry.

---

### Task 1: LXMFNode client send-via-propagation-node

Add the two propagation actions and the `sendPropagated` translation to `LXMFNode`, and prove it with a 3-store integration test that ships a container to a bare-`Endpoint` PN stub.

**Files:**
- Modify: `Sources/ReTiCANode/LXMFNode.swift`
- Test: `Tests/ReTiCANodeTests/LXMFNodePropagationTests.swift` (create)

**Interfaces:**
- Consumes: `LXMFRouter.Action.setOutboundPropagationNode(Data?)`; `LXMFRouter.Action.sendViaPropagation(message: LXMessage, propagationPacked: Data)`; `LXMFRouter.Action.Delegate.sendPropagated(linkID: Data, propagationPacked: Data)`; `LXMFPropagation.pack(message:recipientIdentity:timestamp:) -> (propagationPacked: Data, transientId: Data)`; `Endpoint.Action.sendResourceOverLink(linkID:, data:)`; `state.endpoint.transport.learned[Data]?.identity`.
- Produces: `LXMFNode.Action.setPropagationNode(destinationHash: Data)`, `LXMFNode.Action.sendViaPropagation(destinationHash: Data, title: Data, content: Data)`.

- [ ] **Step 1: Add the two new actions.**

In `LXMFNode.Action`, immediately after the existing `case send(...)` (the one with `method:`), add:

```swift
        case setPropagationNode(destinationHash: Data)
        case sendViaPropagation(destinationHash: Data, title: Data, content: Data)
```

- [ ] **Step 2: Add the `setPropagationNode` handler.**

In the `Reduce` body, immediately after the existing `.send` handler (the `case let .send(destinationHash, title, content, method):` block), add:

```swift
            case let .setPropagationNode(destinationHash):
                return .send(.router(.setOutboundPropagationNode(destinationHash)))
```

- [ ] **Step 3: Add the `sendViaPropagation` handler.**

Immediately after the `setPropagationNode` handler, add:

```swift
            case let .sendViaPropagation(destinationHash, title, content):
                guard let recipient = state.endpoint.transport.learned[destinationHash]?.identity
                else { return .none }
                let msg = LXMessage.create(source: state.identity, destinationHash: destinationHash,
                                           timestamp: date.now.timeIntervalSince1970, title: title, content: content)
                let (packed, _) = LXMFPropagation.pack(message: msg, recipientIdentity: recipient,
                                                       timestamp: date.now.timeIntervalSince1970)
                return .send(.router(.sendViaPropagation(message: msg, propagationPacked: packed)))
```

- [ ] **Step 4: Add the `sendPropagated → sendResourceOverLink` translation.**

Among the direct/link translations, immediately after the `sendDirect` translation (the `case let .router(.delegate(.sendDirect(...)))` block), add:

```swift
            case let .router(.delegate(.sendPropagated(linkID, propagationPacked))):
                return .send(.endpoint(.sendResourceOverLink(linkID: linkID, data: propagationPacked)))
```

(The final `case .endpoint, .router, .delegate: return .none` catch-all stays last; the router's `requestMessageDownload` delegate — P2 — falls through to it.)

- [ ] **Step 5: Confirm the existing suites still compile/pass.**

Run: `swift test --filter LXMFNodeDirectTests`
Then: `swift test --filter lxmfNodeOpportunisticDeliversEndToEnd`
Expected: PASS (additive changes only).

- [ ] **Step 6: Write the failing integration test.**

Create `Tests/ReTiCANodeTests/LXMFNodePropagationTests.swift`. The client `A` is an `LXMFNode`; the recipient `R` and the propagation node `PN` are bare `Endpoint`s. `R` exists only to announce its `lxmf.delivery` destination so `A` learns `R`'s identity (to encrypt the container tail). `PN` registers `lxmf.propagation`, completes the Link handshake, and receives the container Resource — the full `PropagationNode` ingest is P3; here we just inspect the delivered bytes.

This reuses the Link-handshake + Resource-transfer bridge from `LXMFNodeDirectTests.swift` (`lxmfNodeDirectDeliversResourceAndConfirms`). NOTE: `A` is an `LXMFNode` (actions wrapped under `.endpoint(...)`), but `PN`/`R` are bare `Endpoint`s (actions are un-wrapped `Endpoint.Action`). The exact `receive` interleaving must be reconciled by running (as in the prior slice) — the `.off` store tolerates skipped intermediate receives, but each network-`send`-producing effect must be advanced (via a `receive`) before its bytes are bridged; recall the index-based byte-bridging gotcha (LRRTT + RESOURCE_ADV can co-land in one `A` receive). Do NOT change the final assertions.

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// End-to-end through the LXMFNode composition: client A sends a message to recipient R VIA a propagation
/// node PN. A builds the propagation container (encrypted to R), establishes a link to PN's lxmf.propagation
/// destination, and ships the container as a Resource. PN (a bare Endpoint stub — ingest is P3) receives it;
/// we verify the container is addressed to R and that opening it recovers A's signature-valid message.
/// Propagation-accept confirmation is out of scope (P1 is client-send only).
@Test @MainActor func lxmfNodeSendsViaPropagationNode() async {
    let clock = TestClock()
    let aIdentity = Identity()
    let rIdentity = Identity()
    let pnIdentity = Identity()
    let rDeliveryHash = LXMessage.deliveryHash(identityHash: rIdentity.hash)
    let rDelivery = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                aspects: LXMessage.deliveryAspects, identity: rIdentity)!
    let pnDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                             aspects: ["propagation"], identity: pnIdentity)!

    func makeNode(_ host: String, _ identity: Identity, _ sent: LockIsolated<[Data]>)
        -> (TestStore<LXMFNode.State, LXMFNode.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: LXMFNode.State(
            identity: identity, endpoint: Endpoint.State(host: host, port: 4242, reconnectOnDrop: false))
        ) { LXMFNode() } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } }, close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    func makeEndpoint(_ host: String, _ sent: LockIsolated<[Data]>)
        -> (TestStore<Endpoint.State, Endpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: Endpoint.State(host: host, port: 4242, reconnectOnDrop: false)) {
            Endpoint()
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } }, close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    func aSend(_ act: LXMFNode.Action) -> Bool { if case .endpoint(.interface(.send)) = act { return true }; return false }
    func epSend(_ act: Endpoint.Action) -> Bool { if case .interface(.send) = act { return true }; return false }

    let sentA = LockIsolated<[Data]>([]); let sentR = LockIsolated<[Data]>([]); let sentPN = LockIsolated<[Data]>([])
    let (a, eventsA) = makeNode("a", aIdentity, sentA)
    let (r, eventsR) = makeEndpoint("r", sentR)
    let (pn, eventsPN) = makeEndpoint("pn", sentPN)

    await a.send(.endpoint(.connect)); eventsA.yield(.connected)
    await r.send(.connect); eventsR.yield(.connected)
    await pn.send(.connect); eventsPN.yield(.connected)

    // R announces its delivery destination → A learns R's identity (to encrypt the container tail).
    await r.send(.registerLocalDestination(rDelivery))
    await r.send(.announce(destinationHash: rDelivery.hash, appData: nil))
    await r.receive(epSend)
    eventsA.yield(.data(sentR.value.last!))
    await a.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // PN announces its lxmf.propagation destination → A learns PN's path + identity (to establish the link).
    await pn.send(.registerLocalDestination(pnDest))
    await pn.send(.announce(destinationHash: pnDest.hash, appData: nil))
    await pn.receive(epSend)
    eventsA.yield(.data(sentPN.value.last!))
    await a.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // Configure PN and send via propagation.
    await a.send(.setPropagationNode(destinationHash: pnDest.hash))
    await a.send(.sendViaPropagation(destinationHash: rDeliveryHash, title: Data("t".utf8),
                                     content: Data("hello via PN".utf8)))
    await a.receive(aSend)                                   // LINKREQUEST out to PN

    // Link handshake A ↔ PN (A = LXMFNode, PN = Endpoint), mirroring the direct test.
    eventsPN.yield(.data(sentA.value.last!))
    await pn.receive(epSend)                                 // LRPROOF out
    let lrrttIdx = sentA.value.count
    eventsA.yield(.data(sentPN.value.last!))
    await a.receive(aSend)                                   // LRRTT out (RESOURCE_ADV also fires this chain)
    let lrrttBytes = sentA.value[lrrttIdx]
    let resourceAdvBytes = sentA.value[lrrttIdx + 1]
    eventsPN.yield(.data(lrrttBytes))
    await a.receive { if case .endpoint(.delegate(.linkEstablished)) = $0 { return true }; return false }
    await pn.receive(\.delegate.linkEstablished)
    await a.receive(aSend)                                   // RESOURCE_ADV (already queued in A's store)

    // ADV → PN: PN spawns a receiver, emits RESOURCE_REQ.
    eventsPN.yield(.data(resourceAdvBytes))
    await pn.receive(epSend)                                 // RESOURCE_REQ out
    eventsA.yield(.data(sentPN.value.last!))
    let partCount = a.state.endpoint.links[0].transfers[0].parts.count
    for _ in 0..<partCount { await a.receive(aSend) }

    // Deliver all part frames to PN; capture the concluded container from resourceReceived.
    let parts = Array(sentA.value.suffix(partCount))
    let gotContainer = LockIsolated<Data?>(nil)
    for (i, frame) in parts.enumerated() {
        eventsPN.yield(.data(frame))
        if i == partCount - 1 {
            await pn.receive(epSend)                         // RESOURCE_PRF out
            await pn.receive { action in
                if case let .delegate(.resourceReceived(_, d)) = action { gotContainer.setValue(d); return true }
                return false
            }
        }
    }

    // Verify the delivered container: addressed to R, and opens to A's signature-valid message.
    let container = gotContainer.value
    #expect(container != nil)
    let parsed = LXMFPropagation.parseContainer(container!)
    #expect(parsed != nil)
    #expect(parsed?.entries.count == 1)
    let entry = parsed!.entries[0]
    #expect(LXMFPropagation.destinationHash(lxmfData: entry) == rDeliveryHash)   // addressed to R
    let recovered = LXMFPropagation.open(lxmfData: entry, recipientIdentity: rIdentity)
    #expect(recovered != nil)
    #expect(recovered?.content == Data("hello via PN".utf8))
    #expect(recovered?.title == Data("t".utf8))
    #expect(recovered?.sourceHash == LXMessage.deliveryHash(identityHash: aIdentity.hash))
    #expect(recovered?.validateSignature(source: aIdentity) == true)             // real Ed25519 validation

    await a.send(.endpoint(.disconnect)); await r.send(.disconnect); await pn.send(.disconnect)
}
```

- [ ] **Step 7: Run the integration test.**

Run: `swift test --filter lxmfNodeSendsViaPropagationNode`
Expected: PASS. If the exact `receive` interleaving differs, adjust the intermediate `receive` predicates to match actual emission order (do NOT change the final assertions). If it stale-links, run `swift package clean` first.

- [ ] **Step 8: Mutation-verify the test (one at a time, revert between each).**

- Mutation A — drop the `sendPropagated` wire: in Step 4's translation, change the body to `return .none`. Run the Step 7 filter → must FAIL (PN never receives the container — `resourceReceived` never fires / `gotContainer` stays nil). Revert → PASS.
- Mutation B — corrupt the recipient identity used to encrypt: in the `sendViaPropagation` handler (Step 3), replace `recipientIdentity: recipient` with `recipientIdentity: Identity()` (a fresh, wrong key). Run → must FAIL (`LXMFPropagation.open(... recipientIdentity: rIdentity)` cannot decrypt → `recovered == nil`). Revert → PASS.

- [ ] **Step 9: Run the full ReTiCANode suite; confirm green.**

Run: `swift test --filter ReTiCANodeTests`
Expected: all PASS.

- [ ] **Step 10: Commit.**

Write the message to `/tmp/ReTiCA/commit-msg-p1-task1.txt` (verbatim trailers), then:

```bash
git add Sources/ReTiCANode/LXMFNode.swift Tests/ReTiCANodeTests/LXMFNodePropagationTests.swift
git commit -F /tmp/ReTiCA/commit-msg-p1-task1.txt
```

Suggested subject: `feat: LXMF propagation P1 — LXMFNode client send-via-PN`

---

## Self-Review

**Spec coverage:**
- `setPropagationNode` → router.setOutboundPropagationNode → Task 1 Steps 1-2. ✅
- `sendViaPropagation`: build LXMessage + `LXMFPropagation.pack` to recipient identity + router.sendViaPropagation → Steps 1, 3. ✅
- Recipient identity from `transport.learned[destinationHash]?.identity` → Step 3. ✅
- `sendPropagated → sendResourceOverLink` wire → Step 4. ✅
- Two identities (PN for link, recipient for tail) exercised → test setup (R announce, PN announce). ✅
- Bare-Endpoint PN stub; assert container addressed to R + open+validate → Step 6. ✅
- Confirmation / sync / server-ingest NOT wired → absent by construction; Global Constraints call it out. ✅
- Hedged encryption not byte-compared (deterministic destHash prefix + open+validate) → Step 6, Global Constraints. ✅

**Placeholder scan:** none — all steps carry concrete code or exact commands.

**Type consistency:** `setOutboundPropagationNode(Data?)`, `sendViaPropagation(message:propagationPacked:)`, `sendPropagated(linkID:propagationPacked:)`, `sendResourceOverLink(linkID:data:)`, `LXMFPropagation.pack(message:recipientIdentity:timestamp:)`, `parseContainer`, `destinationHash(lxmfData:)`, `open(lxmfData:recipientIdentity:)` all match the surfaces read from `LXMFRouter.swift` / `Endpoint.swift` / `LXMFPropagation*.swift`. The test's Endpoint harness mirrors `LXMFDirectDeliveryTests`; the resource bridge mirrors `lxmfNodeDirectDeliversResourceAndConfirms`.
