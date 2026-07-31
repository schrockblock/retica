# LXMF Direct-over-Link Endpoint Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire `LXMFNode` so a real node delivers an LXMF message directly over a Link (as a link packet or a Resource) and receives one over an inbound link, including link lifecycle (establish / reuse / drain / close / fail / path-request-on-no-path).

**Architecture:** `LXMFNode` composes `Endpoint` + `LXMFRouter` via `Scope` and translates their delegates/actions. Two low-ripple shared changes land in `Endpoint` (`linkEstablished` gains `destinationHash`; a new `requestPath` forwarder). `LXMFNode` adds a `dest→linkID` correlation map, a `method:` parameter on `send`, and the direct/link translations. Delivery confirmation is deferred (a known limitation — direct re-sends up to 5× then `deliveryFailed` even on success).

**Tech Stack:** Swift, Point-Free Composable Architecture (TCA), Swift Testing (`@Test`/`#expect`), `swift test`.

## Global Constraints

- **Commit directly to `main`** — no feature branch, no merge dance.
- **No compound shell commands** — one command per invocation; no `&&`/`||`/`;`/`|`-chains/`xargs`/inline interpreter scripts. A single `>` redirect is allowed.
- **Temp files** go in `/tmp/ReTiCA/`.
- **Commit trailers, verbatim**, using `git commit -F <file>` (never `-m`, because the trailers contain `;`):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```
- **Three-step mutation verification** for every new/changed test: run pass → mutate production to force fail + confirm → revert + confirm pass. One mutation at a time.
- **Prefer non-exhaustive TCA tests** (`store.exhaustivity = .off`), asserting outcomes.
- **Ed25519 is hedged/randomized** — validate signatures, never byte-compare them.
- **Deferred (out of scope):** delivery confirmation (`resourceConcluded → router.delivered`). Do NOT wire it.

---

### Task 1: Endpoint direct-lifecycle surface

Add the two shared-code changes to `Endpoint`: surface `destinationHash` on the `linkEstablished` delegate, and add a `requestPath` action that forwards to Transport. Both are additive/low-ripple; existing `Endpoint`/direct tests must stay green.

**Files:**
- Modify: `Sources/ReTiCANode/Endpoint.swift` (delegate case ~line 55; established handler ~line 165-166; new action in the `Action` enum near `openLink`; new handler near the `openLink` handler ~line 124-134)
- Test: `Tests/ReTiCANodeTests/EndpointTests.swift` (append one test)

**Interfaces:**
- Consumes: `Transport.Action.requestPath(destinationHash: Data)` (Transport.swift:97); `LinkSession.State.destinationHash` (always populated — LinkSession.swift:74/100).
- Produces (for Task 2): `Endpoint.Action.Delegate.linkEstablished(linkID: Data, destinationHash: Data)`; `Endpoint.Action.requestPath(destinationHash: Data)`.

- [ ] **Step 1: Change the `linkEstablished` delegate to carry `destinationHash`.**

In `Sources/ReTiCANode/Endpoint.swift`, in the `Delegate` enum, change:

```swift
            case linkEstablished(linkID: Data)
```
to:
```swift
            case linkEstablished(linkID: Data, destinationHash: Data)
```

- [ ] **Step 2: Update the `established` handler to pass the dest.**

Change the handler (currently at ~line 165-166):

```swift
            case let .link(.element(_, .delegate(.established(linkID, _)))):
                return .send(.delegate(.linkEstablished(linkID: linkID)))
```
to:
```swift
            case let .link(.element(elementID, .delegate(.established(linkID, _)))):
                guard let destHash = state.links[id: elementID]?.destinationHash else { return .none }
                return .send(.delegate(.linkEstablished(linkID: linkID, destinationHash: destHash)))
```

- [ ] **Step 3: Add the `requestPath` action.**

In the `Action` enum, immediately after the `openLink` case, add:

```swift
        case requestPath(destinationHash: Data)
```

- [ ] **Step 4: Add the `requestPath` handler.**

In the `Reduce` body, immediately after the `openLink` handler (the block ending `return .send(.link(.element(id: newID, action: .establish)))`), add:

```swift
            case let .requestPath(destinationHash):
                return .send(.transport(.requestPath(destinationHash: destinationHash)))
```

- [ ] **Step 5: Write the failing test for the `requestPath` forwarder.**

Append to `Tests/ReTiCANodeTests/EndpointTests.swift`:

```swift
@Test @MainActor func endpointRequestPathForwardsToTransport() async {
    let clock = TestClock()
    let events = AsyncStream<TCPEvent>.makeStream()
    let sent = LockIsolated<[Data]>([])
    let store = TestStore(initialState: Endpoint.State(host: "a", port: 4242, reconnectOnDrop: false)) {
        Endpoint()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                         send: { d in sent.withValue { $0.append(d) } },
                                         close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.connect); events.continuation.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    let dest = Data((0..<16).map { UInt8($0) })
    await store.send(.requestPath(destinationHash: dest))
    await store.receive(\.transport.requestPath)                 // forwarder reaches Transport
    await store.receive { if case .interface(.send) = $0 { return true }; return false }
    #expect(!sent.value.isEmpty)                                 // a path-request packet went out

    await store.send(.disconnect)
}
```

- [ ] **Step 6: Run the new test; confirm it passes.**

Run: `swift test --filter endpointRequestPathForwardsToTransport`
Expected: PASS. (If the build stale-links, run `swift package clean` first.)

- [ ] **Step 7: Run the existing Endpoint + direct-delivery suites; confirm still green (ripple check).**

Run: `swift test --filter EndpointTests`
Then: `swift test --filter LXMFDirectDelivery`
Expected: all PASS — the `linkEstablished` payload addition must not break any existing `receive(\.delegate.linkEstablished)` (all are bare case-path matches with no payload binding).

- [ ] **Step 8: Mutation-verify the new test (one mutation at a time).**

Mutation A: in the `requestPath` handler, replace the body with `return .none`. Run the filter from Step 6 → the test must FAIL (no `.transport.requestPath` received). Revert.
Run the filter again → PASS.

- [ ] **Step 9: Commit.**

Write the message to `/tmp/ReTiCA/commit-msg-direct-task1.txt` (with the verbatim trailers), then:

```bash
git add Sources/ReTiCANode/Endpoint.swift Tests/ReTiCANodeTests/EndpointTests.swift
git commit -F /tmp/ReTiCA/commit-msg-direct-task1.txt
```

Suggested subject: `feat: LXMF direct task 1 — Endpoint linkEstablished+dest & requestPath forwarder`

---

### Task 2: LXMFNode direct-over-link wiring + integration test

Add the direct/link translations to `LXMFNode`, the `dest→linkID` correlation map, and the `method:` parameter on `send`; prove it with a 2-node in-memory integration test that delivers a large LXMF message as a Resource over a Link, driven entirely through `LXMFNode`.

**Files:**
- Modify: `Sources/ReTiCANode/LXMFNode.swift`
- Modify: `Tests/ReTiCANodeTests/LXMFNodeOpportunisticTests.swift` (update the one `send` call site, line 56)
- Test: `Tests/ReTiCANodeTests/LXMFNodeDirectTests.swift` (create)

**Interfaces:**
- Consumes: `Endpoint.Action.Delegate.linkEstablished(linkID:, destinationHash:)`, `.linkClosed(linkID:, reason:)`, `.linkFailed(destinationHash:)`, `.linkDataReceived(linkID:, data:)`, `.resourceReceived(linkID:, data:)`, `.pathLearned(destinationHash:, hops:)` (Endpoint.swift); `Endpoint.Action.openLink`, `.requestPath`, `.sendOverLink`, `.sendResourceOverLink`, `.closeLink`; `LXMFRouter.Action.received`, `.linkEstablished`, `.linkClosed`, `.learnedPath`, `.learnedIdentity`, `.send`; `LXMFRouter.Action.Delegate.requestLink`, `.requestPath`, `.sendDirect(linkID:, data:, asResource:)`, `.closeLink`; `DeliveryMethod` (`{ case opportunistic, direct }`, LXMFRouter.swift:41).
- Produces: `LXMFNode.Action.send(destinationHash:, title:, content:, method:)`.

- [ ] **Step 1: Add the correlation map to `LXMFNode.State`.**

In `Sources/ReTiCANode/LXMFNode.swift`, in `State`, after `public var identity: Identity`, add:

```swift
        public var directLinks: [Data: Data] = [:]   // destinationHash → linkID (close/linkClosed correlation)
```

- [ ] **Step 2: Add the `method:` parameter to the `send` action.**

Change:
```swift
        case send(destinationHash: Data, title: Data, content: Data)
```
to:
```swift
        case send(destinationHash: Data, title: Data, content: Data, method: DeliveryMethod)
```

- [ ] **Step 3: Thread `method` through the `send` handler.**

Change the `.send` handler:
```swift
            case let .send(destinationHash, title, content):
                let msg = LXMessage.create(source: state.identity, destinationHash: destinationHash,
                                           timestamp: date.now.timeIntervalSince1970, title: title, content: content)
                return .send(.router(.send(message: msg, desiredMethod: .opportunistic)))
```
to:
```swift
            case let .send(destinationHash, title, content, method):
                let msg = LXMessage.create(source: state.identity, destinationHash: destinationHash,
                                           timestamp: date.now.timeIntervalSince1970, title: title, content: content)
                return .send(.router(.send(message: msg, desiredMethod: method)))
```

- [ ] **Step 4: Update the `pathLearned` translation to also forward `learnedPath`.**

Change:
```swift
            case let .endpoint(.delegate(.pathLearned(h, _))):
                guard let identity = state.endpoint.transport.learned[h]?.identity else { return .none }
                return .send(.router(.learnedIdentity(destinationHash: h, identity: identity)))
```
to:
```swift
            case let .endpoint(.delegate(.pathLearned(h, _))):
                var effects: [Effect<Action>] = [.send(.router(.learnedPath(destinationHash: h)))]
                if let identity = state.endpoint.transport.learned[h]?.identity {
                    effects.append(.send(.router(.learnedIdentity(destinationHash: h, identity: identity))))
                }
                return .merge(effects)
```

- [ ] **Step 5: Add the direct/link translations.**

Immediately before the final catch-all (`case .endpoint, .router, .delegate: return .none`), add these cases:

```swift
            // --- Direct-over-link: router delegates → endpoint actions ---
            case let .router(.delegate(.requestLink(dest))):
                return .send(.endpoint(.openLink(destinationHash: dest)))

            case let .router(.delegate(.requestPath(dest))):
                return .send(.endpoint(.requestPath(destinationHash: dest)))

            case let .router(.delegate(.sendDirect(linkID, data, asResource))):
                return asResource
                    ? .send(.endpoint(.sendResourceOverLink(linkID: linkID, data: data)))
                    : .send(.endpoint(.sendOverLink(linkID: linkID, data: data)))

            case let .router(.delegate(.closeLink(dest))):
                guard let linkID = state.directLinks[dest] else { return .none }
                return .send(.endpoint(.closeLink(linkID: linkID)))

            // --- Direct-over-link: endpoint delegates → router actions ---
            case let .endpoint(.delegate(.linkEstablished(linkID, dest))):
                state.directLinks[dest] = linkID
                return .send(.router(.linkEstablished(destinationHash: dest, linkID: linkID)))

            case let .endpoint(.delegate(.linkClosed(linkID, _))):
                guard let dest = state.directLinks.first(where: { $0.value == linkID })?.key else { return .none }
                state.directLinks[dest] = nil
                return .send(.router(.linkClosed(destinationHash: dest)))

            case let .endpoint(.delegate(.linkFailed(dest))):
                state.directLinks[dest] = nil
                return .send(.router(.linkClosed(destinationHash: dest)))

            case let .endpoint(.delegate(.linkDataReceived(_, data))):
                return .send(.router(.received(method: .direct, destinationHash: Data(), data: data)))

            case let .endpoint(.delegate(.resourceReceived(_, data))):
                return .send(.router(.received(method: .direct, destinationHash: Data(), data: data)))
```

Note: the throwaway `destinationHash: Data()` on inbound is correct — the `.direct` branch of `LXMFRouter.received` calls `LXMessage.unpack(data)`, which reads the dest from the packed bytes and ignores the argument (LXMFRouter.swift:119-121).

- [ ] **Step 6: Update the opportunistic test call site.**

In `Tests/ReTiCANodeTests/LXMFNodeOpportunisticTests.swift`, line 56, change:
```swift
    await a.send(.send(destinationHash: bDeliveryHash, title: Data("hi".utf8), content: Data("hello node".utf8)))
```
to:
```swift
    await a.send(.send(destinationHash: bDeliveryHash, title: Data("hi".utf8), content: Data("hello node".utf8), method: .opportunistic))
```

- [ ] **Step 7: Confirm the build compiles and the opportunistic test still passes.**

Run: `swift test --filter lxmfNodeOpportunisticDeliversEndToEnd`
Expected: PASS (behavior unchanged — only the method arg was threaded).

- [ ] **Step 8: Write the direct-Resource integration test.**

Create `Tests/ReTiCANodeTests/LXMFNodeDirectTests.swift`. This drives the full direct path through `LXMFNode`: B announces → A learns path+identity → `A.send(.direct)` triggers the router to establish a Link (no path-request round trip needed, path already known) → the large message is sent as a Resource → B surfaces it validated. It reuses the Link-handshake + Resource-transfer bridge from `directLXMFLargeMessageDeliversAsResource` (LXMFDirectDeliveryTests.swift:99-213), but every `Endpoint` action/delegate is now nested under `.endpoint(...)` in `LXMFNode.Action`.

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// End-to-end through the LXMFNode composition: node A delivers a large LXMF message to node B directly
/// over a Link (as a Resource), and B's LXMFNode surfaces the reconstructed, signature-validated message —
/// with no hand-wiring of LXMessage/Endpoint/Link (the router + composition do it). Delivery confirmation
/// is out of scope for this slice.
@Test @MainActor func lxmfNodeDirectDeliversResourceEndToEnd() async {
    let clock = TestClock()
    let aIdentity = Identity()
    let bIdentity = Identity()
    let bDeliveryHash = LXMessage.deliveryHash(identityHash: bIdentity.hash)

    func make(_ host: String, _ identity: Identity, _ sent: LockIsolated<[Data]>)
        -> (TestStore<LXMFNode.State, LXMFNode.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: LXMFNode.State(
            identity: identity, endpoint: Endpoint.State(host: host, port: 4242, reconnectOnDrop: false))
        ) {
            LXMFNode()
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } },
                                             close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    // Predicate helpers for the .off store (everything is wrapped under .endpoint(...)).
    func isInterfaceSend(_ a: LXMFNode.Action) -> Bool {
        if case .endpoint(.interface(.send)) = a { return true }; return false
    }

    let sentA = LockIsolated<[Data]>([]); let sentB = LockIsolated<[Data]>([])
    let (a, eventsA) = make("a", aIdentity, sentA)
    let (b, eventsB) = make("b", bIdentity, sentB)

    await a.send(.endpoint(.connect)); eventsA.yield(.connected)
    await b.send(.endpoint(.connect)); eventsB.yield(.connected)

    // Both register + announce; bridge announces so A learns B (path + identity for signing/validation)
    // and B learns A (identity — B validates A's signature).
    await a.send(.registerDelivery)
    await a.receive(isInterfaceSend)
    await b.send(.registerDelivery)
    await b.receive(isInterfaceSend)
    eventsA.yield(.data(sentB.value.last!))                 // B's announce → A learns B
    await a.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!))                 // A's announce → B learns A
    await b.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // A sends a LARGE message to B via .direct → router establishes a link (path already known),
    // then sends the message as a Resource. First: the LINKREQUEST goes out.
    let bigContent = Data((0..<800).map { UInt8($0 & 0xff) })
    await a.send(.send(destinationHash: bDeliveryHash, title: Data("big".utf8), content: bigContent, method: .direct))
    await a.receive(isInterfaceSend)                        // LINKREQUEST out

    // Link handshake (mirrors LXMFDirectDeliveryTests steps 2–4, wrapped through LXMFNode).
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(isInterfaceSend)                        // LRPROOF out
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(isInterfaceSend)                        // LRRTT out
    await a.receive { if case .endpoint(.delegate(.linkEstablished)) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!))
    await b.receive { if case .endpoint(.delegate(.linkEstablished)) = $0 { return true }; return false }

    // Link is active on both ends; router drains the queue → RESOURCE_ADV out from A.
    await a.receive(isInterfaceSend)                        // RESOURCE_ADV out

    // ADV → B: B spawns a receiver, emits RESOURCE_REQ.
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(isInterfaceSend)                        // RESOURCE_REQ out

    // REQ → A: A serves its parts.
    eventsA.yield(.data(sentB.value.last!))
    let partCount = a.state.endpoint.links[0].transfers[0].parts.count
    for _ in 0..<partCount { await a.receive(isInterfaceSend) }

    // Deliver every part frame A emitted (the last `partCount` frames in sentA) to B.
    let parts = Array(sentA.value.suffix(partCount))
    let gotContent = LockIsolated<Data?>(nil)
    let gotTitle = LockIsolated<Data?>(nil)
    let gotSrcHash = LockIsolated<Data?>(nil)
    let gotValidated = LockIsolated<Bool>(false)
    for (i, frame) in parts.enumerated() {
        eventsB.yield(.data(frame))
        if i == partCount - 1 {
            await b.receive(isInterfaceSend)               // RESOURCE_PRF out
            await b.receive { action in
                if case let .delegate(.messageReceived(m, v)) = action {
                    gotContent.setValue(m.content)
                    gotTitle.setValue(m.title)
                    gotSrcHash.setValue(m.sourceHash)
                    gotValidated.setValue(v)
                    return true
                }
                return false
            }
        }
    }

    #expect(gotContent.value == bigContent)
    #expect(gotTitle.value == Data("big".utf8))
    #expect(gotSrcHash.value == LXMessage.deliveryHash(identityHash: aIdentity.hash))
    #expect(gotValidated.value == true)                    // B learned A's identity → signature validates

    await a.send(.endpoint(.disconnect)); await b.send(.endpoint(.disconnect))
}
```

- [ ] **Step 9: Run the direct integration test.**

Run: `swift test --filter lxmfNodeDirectDeliversResourceEndToEnd`
Expected: PASS. If the exact `receive` interleaving differs (emission order), adjust the intermediate `receive` predicates to match actual order — the `.off` store tolerates skipped intermediate receives, but each network-`send`-producing effect must be advanced (via a `receive`) before its bytes are bridged. Do NOT change the final assertions. If the build stale-links after Task 1, run `swift package clean` first.

- [ ] **Step 10: Mutation-verify the new test (one mutation at a time, revert between each).**

- Mutation A — drop the `learnedPath` forward: in the `pathLearned` handler, remove the `.send(.router(.learnedPath(destinationHash: h)))` element (leave only the identity effect). Run the Step 9 filter → must FAIL (A never gets `knownPaths`, so `.direct` parks in `.awaitingPath` and no link is established → no delivery). Revert → PASS.
- Mutation B — invert `asResource`: in the `sendDirect` translation, swap the two branches (`asResource ? sendOverLink : sendResourceOverLink`). Run → must FAIL (large message sent as a link packet, not a Resource → B never receives the Resource). Revert → PASS.
- Mutation C — break the inbound resource wire: in the `resourceReceived` translation, `return .none` instead of forwarding to the router. Run → must FAIL (B never reconstructs the message). Revert → PASS.

- [ ] **Step 11: Run the full ReTiCANode suite; confirm green.**

Run: `swift test --filter ReTiCANodeTests`
Expected: all PASS (no regressions in Endpoint / LXMFRouter / opportunistic / direct hand-wired tests).

- [ ] **Step 12: Commit.**

Write the message to `/tmp/ReTiCA/commit-msg-direct-task2.txt` (verbatim trailers), then:

```bash
git add Sources/ReTiCANode/LXMFNode.swift Tests/ReTiCANodeTests/LXMFNodeDirectTests.swift Tests/ReTiCANodeTests/LXMFNodeOpportunisticTests.swift
git commit -F /tmp/ReTiCA/commit-msg-direct-task2.txt
```

Suggested subject: `feat: LXMF direct task 2 — LXMFNode direct-over-link wiring + resource integration test`

---

## Self-Review

**Spec coverage:**
- Endpoint `linkEstablished`+dest → Task 1 Steps 1-2. ✅
- Endpoint `requestPath` forwarder → Task 1 Steps 3-4 + test 5. ✅
- Low-ripple guarantee (existing tests green) → Task 1 Step 7. ✅
- `LXMFNode` `directLinks` map → Task 2 Step 1. ✅
- `send` `method:` param → Task 2 Steps 2-3, call-site update Step 6. ✅
- All direct translations (requestLink/requestPath/sendDirect/closeLink/linkEstablished/linkClosed/linkFailed/linkDataReceived/resourceReceived) → Task 2 Step 5. ✅
- `learnedPath` added to `pathLearned` wire → Task 2 Step 4. ✅
- Throwaway inbound dest justified → Task 2 Step 5 note. ✅
- Resource-path integration test (message > Link.mdu) → Task 2 Step 8. ✅
- Delivery confirmation NOT wired → absent by construction; Global Constraints call it out. ✅

**Placeholder scan:** none — all steps carry concrete code or exact commands.

**Type consistency:** `linkEstablished(linkID:, destinationHash:)`, `requestPath(destinationHash:)`, `send(..., method: DeliveryMethod)`, `router.received(method: .direct, destinationHash:, data:)`, `router.learnedPath(destinationHash:)` all match the surfaces read from `Endpoint.swift`/`LXMFRouter.swift`. `a.state.endpoint.links[0].transfers[0].parts.count` matches the `LXMFNode.State.endpoint: Endpoint.State` composition (Endpoint exposes `links`).
