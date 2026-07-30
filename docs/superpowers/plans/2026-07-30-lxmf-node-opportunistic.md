# LXMF-Node Integration: Opportunistic 1:1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An `LXMFNode` composition reducer (Endpoint + LXMFRouter) that sends and receives opportunistic LXMF messages over real transport, validated by a 2-node in-memory integration test.

**Architecture:** `@Reducer LXMFNode` composes `Endpoint` + `LXMFRouter` via `Scope` and translates their delegates/actions. The app calls `.registerDelivery` then `.send(...)`; it receives `.delegate(.messageReceived(...))`. Opportunistic only — no links, no correlation state, no `Endpoint` changes.

**Tech Stack:** Swift, The Composable Architecture (TCA), swift-testing (`@Test`).

## Global Constraints

- Commit directly to `main`; no feature branch, no finishing-a-development-branch merge dance.
- No compound shell commands: no `|` chains, `&&`, `||`, `;`, `$(...)`-feeding, `xargs`, or inlining scripts into interpreters. One command per Bash call. A single `>` redirect is allowed. Never use echo/printf/heredoc to WRITE source files (use Write/Edit).
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for the new test.
- Prefer non-exhaustive TCA tests (`store.exhaustivity = .off`).
- Commit trailers (exact); the `;` means author the message with the Write tool to `/tmp/ReTiCA/` and `git commit -F`, never `-m`:
  - `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`

---

### Task 1: `LXMFNode` reducer + 2-node opportunistic integration test

**Files:**
- Create: `Sources/ReTiCANode/LXMFNode.swift`
- Create: `Tests/ReTiCANodeTests/LXMFNodeOpportunisticTests.swift`

**Interfaces:**
- Consumes: `Endpoint` (+ `.State(host:port:reconnectOnDrop:)`, actions `.connect`/`.registerLocalDestination`/`.announce`/`.send`, delegates `.messageReceived`/`.pathLearned`); `LXMFRouter` (actions `.send`/`.received`/`.learnedIdentity`, delegates `.sendOpportunistic`/`.messageDelivered`/`.deliveryFailed`); `Destination(kind:direction:appName:aspects:identity:)`; `LXMessage.create`/`.appName`/`.deliveryAspects`/`.deliveryHash`; `transport.learned[h]?.identity`; `@Dependency(\.date)`. Test reuses the mock-TCP harness pattern from `LXMFOpportunisticDeliveryTests`.
- Produces: `LXMFNode` (`@Reducer`), `LXMFNode.State(identity:endpoint:)`, actions `.endpoint`/`.router`/`.registerDelivery`/`.send(destinationHash:title:content:)`/`.delegate`, `Delegate.messageReceived`/`.deliveryFailed`.

- [ ] **Step 1: Implement `LXMFNode`**

Create `Sources/ReTiCANode/LXMFNode.swift`:

```swift
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCATransport

/// The first production composition connecting the decoupled `LXMFRouter` to real transport (LXMF-Node,
/// opportunistic 1:1). Composes `Endpoint` + `LXMFRouter` and translates their delegates/actions: the app
/// calls `.registerDelivery` then `.send(...)`, and receives `.delegate(.messageReceived(...))`. Direct-
/// over-link, path requests, delivery confirmation, and propagation wiring are follow-ons.
@Reducer
public struct LXMFNode {
    @ObservableState
    public struct State: Equatable {
        public var endpoint: Endpoint.State
        public var router: LXMFRouter.State
        public var identity: Identity
        public init(identity: Identity, endpoint: Endpoint.State) {
            self.identity = identity
            self.endpoint = endpoint
            self.router = LXMFRouter.State()
        }
    }

    public enum Action: Equatable {
        case endpoint(Endpoint.Action)
        case router(LXMFRouter.Action)
        case registerDelivery
        case send(destinationHash: Data, title: Data, content: Data)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case messageReceived(message: LXMessage, signatureValidated: Bool)
            case deliveryFailed(messageHash: Data)
        }
    }

    @Dependency(\.date) var date
    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.endpoint, action: \.endpoint) { Endpoint() }
        Scope(state: \.router, action: \.router) { LXMFRouter() }
        Reduce { [date] state, action in
            switch action {
            case .registerDelivery:
                guard let d = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                          aspects: LXMessage.deliveryAspects, identity: state.identity)
                else { return .none }
                return .merge(.send(.endpoint(.registerLocalDestination(d))),
                              .send(.endpoint(.announce(destinationHash: d.hash, appData: nil))))

            case let .send(destinationHash, title, content):
                let msg = LXMessage.create(source: state.identity, destinationHash: destinationHash,
                                           timestamp: date.now.timeIntervalSince1970, title: title, content: content)
                return .send(.router(.send(message: msg, desiredMethod: .opportunistic)))

            case let .router(.delegate(.sendOpportunistic(dest, payload))):
                return .send(.endpoint(.send(destinationHash: dest, plaintext: payload)))

            case let .endpoint(.delegate(.messageReceived(destHash, plaintext))):
                return .send(.router(.received(method: .opportunistic, destinationHash: destHash, data: plaintext)))

            case let .endpoint(.delegate(.pathLearned(h, _))):
                guard let identity = state.endpoint.transport.learned[h]?.identity else { return .none }
                return .send(.router(.learnedIdentity(destinationHash: h, identity: identity)))

            case let .router(.delegate(.messageDelivered(message, validated))):
                return .send(.delegate(.messageReceived(message: message, signatureValidated: validated)))

            case let .router(.delegate(.deliveryFailed(hash))):
                return .send(.delegate(.deliveryFailed(messageHash: hash)))

            case .endpoint, .router, .delegate:
                return .none
            }
        }
    }
}
```

- [ ] **Step 2: Write the 2-node integration test**

Create `Tests/ReTiCANodeTests/LXMFNodeOpportunisticTests.swift`. Adapt the mock-TCP bridging harness from `LXMFOpportunisticDeliveryTests.swift` (a `TCPConnection` whose `send` captures bytes into a `LockIsolated`, whose `open` returns a yielded event stream), but drive two `LXMFNode` `TestStore`s. Action matches gain the `.endpoint(...)` prefix; the final assertion is on `LXMFNode`'s `.delegate(.messageReceived)`.

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// End-to-end through the LXMFNode composition: node A opportunistically delivers an LXMF message to
/// node B, and B's LXMFNode surfaces the reconstructed, signature-validated message — with no hand-wiring
/// of LXMessage/Endpoint (the router does it).
@Test @MainActor func lxmfNodeOpportunisticDeliversEndToEnd() async {
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

    let sentA = LockIsolated<[Data]>([]); let sentB = LockIsolated<[Data]>([])
    let (a, eventsA) = make("a", aIdentity, sentA)
    let (b, eventsB) = make("b", bIdentity, sentB)

    await a.send(.endpoint(.connect)); eventsA.yield(.connected)
    await b.send(.endpoint(.connect)); eventsB.yield(.connected)

    // Both register + announce their lxmf.delivery destination; bridge announces so each learns the other
    // (path + identity — B needs A's identity to validate A's signature).
    await a.send(.registerDelivery)
    await a.receive { if case .endpoint(.interface(.send)) = $0 { return true }; return false }
    await b.send(.registerDelivery)
    await b.receive { if case .endpoint(.interface(.send)) = $0 { return true }; return false }
    eventsB.yield(.data(sentB.value.last!))                 // B's announce → A learns B
    await a.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }
    eventsA.yield(.data(sentA.value.last!))                 // A's announce → B learns A
    await b.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // A sends opportunistically to B; bridge the DATA packet to B.
    await a.send(.send(destinationHash: bDeliveryHash, title: Data("hi".utf8), content: Data("hello node".utf8)))
    await a.receive { if case .endpoint(.interface(.send)) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!))

    // B's LXMFNode surfaces the reconstructed + validated message.
    let got = LockIsolated<(LXMessage, Bool)?>(nil)
    await b.receive { action in
        if case let .delegate(.messageReceived(m, v)) = action { got.setValue((m, v)); return true }
        return false
    }
    let (message, validated) = got.value!
    #expect(message.content == Data("hello node".utf8))
    #expect(message.title == Data("hi".utf8))
    #expect(message.destinationHash == bDeliveryHash)
    #expect(message.sourceHash == LXMessage.deliveryHash(identityHash: aIdentity.hash))
    #expect(validated == true)                              // B learned A's identity → signature validates

    await a.send(.endpoint(.disconnect)); await b.send(.endpoint(.disconnect))
}
```

- [ ] **Step 3: Build + run the integration test**

Run: `swift test --filter lxmfNodeOpportunisticDeliversEndToEnd`
Expected: PASS. If the receive sequence needs adjustment (async bridging order), use `LXMFOpportunisticDeliveryTests.swift` as the reference for the exact yield→receive ordering (it exercises the same Transport path); keep the assertions (Step 2's `#expect`s) fixed — only adjust the intermediate `store.receive` plumbing to match how actions bubble through the composed reducer. If SwiftPM shows a signal-11/signal-10 build flake, run `swift package clean` (single command) and re-run.

- [ ] **Step 4: Mutation verification (one at a time)**

Apply each in `Sources/ReTiCANode/LXMFNode.swift`, run `swift test --filter lxmfNodeOpportunisticDeliversEndToEnd`, confirm the test fails, revert, confirm pass.

1. **Drop the inbound wire** — change `.endpoint(.delegate(.messageReceived...))` to `return .none` (don't forward to the router).
   → the test FAILS: B never emits `.delegate(.messageReceived)` (the final `receive` times out).
2. **Drop identity learning** — change `.endpoint(.delegate(.pathLearned...))` to `return .none` (never forward `learnedIdentity`).
   → the test FAILS: `validated == true` is not met (B can't resolve A's identity → `signatureValidated == false`).
3. **Wrong outbound method** — in `.send`, change `desiredMethod: .opportunistic` to `.direct`.
   → the test FAILS: the router takes the direct path (emits `requestLink`, not `sendOpportunistic`), so no DATA packet is sent and B receives nothing.

After each: revert, re-run, expect PASS.

- [ ] **Step 5: Full test gate**

Run: `swift test`
Expected: PASS. The mesh baseline was 479 passed / 1 pre-existing live-node skip / 0 fail; this slice adds 1 integration test → 480 passed. On a signal-11/signal-10 build flake, run `swift package clean` (single command) and re-run.

- [ ] **Step 6: Commit**

Write the message to `/tmp/ReTiCA/commit-msg-node.txt` with the Write tool (body below), then:

```bash
git add Sources/ReTiCANode/LXMFNode.swift Tests/ReTiCANodeTests/LXMFNodeOpportunisticTests.swift
```

```bash
git commit -F /tmp/ReTiCA/commit-msg-node.txt
```

Commit message body:

```
feat: LXMF-Node — opportunistic 1:1 integration

First production composition connecting the decoupled LXMFRouter to real
transport: LXMFNode reducer (Endpoint + LXMFRouter). .registerDelivery
registers + announces the node's lxmf.delivery; .send builds the LXMessage
and routes it opportunistically; delegates are translated both ways
(sendOpportunistic→endpoint.send, messageReceived→router.received,
pathLearned→router.learnedIdentity, messageDelivered→node delegate).
Validated by a 2-node in-memory integration test (A sends → B surfaces the
reconstructed, signature-validated message). Direct/link + path-request +
propagation wiring are follow-ons.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Self-Review

**Spec coverage:**
- Spec `LXMFNode` (State: endpoint/router/identity; Scopes; actions/delegates) → Step 1. ✓
- Spec translations (registerDelivery, send, sendOpportunistic→endpoint.send, messageReceived→router.received, pathLearned→learnedIdentity, messageDelivered→delegate, deliveryFailed→delegate, others→.none) → Step 1. ✓
- Spec 2-node integration test (mock-TCP harness, register+announce+bridge, A.send → B.messageReceived validated) → Step 2. ✓
- Spec "opportunistic only, no Endpoint/router changes" → only `LXMFNode.swift` + the test are created. ✓
- Spec deferred (direct/path/propagation) → not implemented; documented. ✓

**Placeholder scan:** none — Step 1 is exact code; Step 2 is a concrete test (with an explicit note that intermediate `store.receive` plumbing may need ordering adjustments against the reference test, while the assertions stay fixed).

**Type consistency:** `LXMFNode.Action` cases `.endpoint`/`.router`/`.registerDelivery`/`.send(destinationHash:title:content:)`/`.delegate` and `Delegate.messageReceived(message:signatureValidated:)`/`.deliveryFailed(messageHash:)` are used consistently in the reducer and test. The reducer matches the real `LXMFRouter.Action.Delegate` cases (`sendOpportunistic`/`messageDelivered`/`deliveryFailed`) and `Endpoint.Action.Delegate` cases (`messageReceived`/`pathLearned`); all other delegate cases fall through the `.endpoint, .router, .delegate` catch-all. `Destination(kind:direction:appName:aspects:identity:)` failable init is guarded. `LXMessage.create(source:destinationHash:timestamp:title:content:)` matches its signature.
```
