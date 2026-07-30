# LXMF-Node Integration: Opportunistic 1:1 — Design

**Sub-project:** LXMF Endpoint/Transport integration (the app-glue layer). First slice: the composition reducer + opportunistic 1:1. Direct-over-link, path-request, delivery confirmation, and propagation wiring are follow-ons. See the `lxmf` memory.

## Context

`LXMFRouter` (and `PropagationNode`) are decoupled TCA reducers, unit-tested in isolation and **never connected to `Endpoint` in production** — the LXMF-2/3 end-to-end tests wired `Endpoint` ↔ `LXMessage` by hand. This slice creates the first production composition layer: a reducer that composes `Endpoint` + `LXMFRouter` and translates their delegates/actions, so a real node can send and receive opportunistic LXMF messages over transport through the router.

Scope is opportunistic only — no links, no correlation state, no `requestPath` gap. This establishes the composition pattern the later slices (direct, propagation) extend.

## Architecture

New `@Reducer struct LXMFNode` in `Sources/ReTiCANode/LXMFNode.swift`.

```swift
@Reducer
public struct LXMFNode {
    @ObservableState
    public struct State: Equatable {
        public var endpoint: Endpoint.State
        public var router: LXMFRouter.State = .init()
        public var identity: Identity                    // this node's identity (source of sent messages)
        public init(identity: Identity, endpoint: Endpoint.State)
    }
    public enum Action: Equatable {
        case endpoint(Endpoint.Action)
        case router(LXMFRouter.Action)
        case registerDelivery                            // register + announce our lxmf.delivery destination
        case send(destinationHash: Data, title: Data, content: Data)   // opportunistic send (we build the LXMessage)
        case delegate(Delegate)
        public enum Delegate: Equatable {
            case messageReceived(message: LXMessage, signatureValidated: Bool)
            case deliveryFailed(messageHash: Data)
        }
    }
    @Dependency(\.date) var date
    public var body: some ReducerOf<Self> {
        Scope(state: \.endpoint, action: \.endpoint) { Endpoint() }
        Scope(state: \.router, action: \.router) { LXMFRouter() }
        Reduce { state, action in /* translation, below */ }
    }
}
```

`State.identity` is the node's `Identity` (used as the message source and to derive the `lxmf.delivery` destination). `Endpoint` and `LXMFRouter` states are composed via `Scope`; their dependencies (`continuousClock`, `date`, `uuid`, `tcpConnection`) resolve through the store. `LXMFNode` itself uses `@Dependency(\.date)` to timestamp outbound messages.

## Translation (the composition's whole job)

In the `Reduce`:

- **`.registerDelivery`** → let `d = Destination(kind: .single, direction: .in, appName: "lxmf", aspects: ["delivery"], identity: state.identity)`; emit `.merge(.endpoint(.registerLocalDestination(d)), .endpoint(.announce(destinationHash: d.hash, appData: nil)))`. (`d.hash == LXMessage.deliveryHash(identityHash: identity.hash)`.)
- **`.send(destinationHash, title, content)`** → `let msg = LXMessage.create(source: state.identity, destinationHash: destinationHash, timestamp: date.now.timeIntervalSince1970, title: title, content: content)`; emit `.router(.send(message: msg, desiredMethod: .opportunistic))`.
- **`.router(.delegate(.sendOpportunistic(dest, payload)))`** → `.endpoint(.send(destinationHash: dest, plaintext: payload))`.
- **`.endpoint(.delegate(.messageReceived(destHash, plaintext)))`** → `.router(.received(method: .opportunistic, destinationHash: destHash, data: plaintext))`.
- **`.endpoint(.delegate(.pathLearned(h, _)))`** → if `state.endpoint.transport.learned[h]?.identity` is non-nil, `.router(.learnedIdentity(destinationHash: h, identity: that))` (so the receiver can validate the sender's signature). Else `.none`.
- **`.router(.delegate(.messageDelivered(message, validated)))`** → `.send(.delegate(.messageReceived(message: message, signatureValidated: validated)))`.
- **`.router(.delegate(.deliveryFailed(hash)))`** → `.send(.delegate(.deliveryFailed(messageHash: hash)))`.
- **All other `.router(.delegate(...))`** (`.requestLink`/`.requestPath`/`.sendDirect`/`.closeLink`/`.deliveryConfirmed`/`.duplicateDropped`) → `.none` in this slice (opportunistic never emits `sendDirect`/`requestLink`; the direct/path ones arrive only in the follow-on).
- **Other `.endpoint(.delegate(...))`** (link/resource/request events) → `.none` here.
- **`.endpoint`/`.router` non-delegate, `.delegate`** → `.none` (handled by the scopes).

Opportunistic best-effort note: our stack has no opportunistic DATA-packet receipt, so `.router` never receives `.delivered`; its retry timer re-sends to `maxAttempts` then emits `.deliveryFailed`. That is expected — the receiver still gets the message on the first send. Tests don't advance the clock past the retry wait, leaving the timer pending (tolerated under `.off`).

## Data flow (2-node)

```
A.registerDelivery → announce ; B.registerDelivery → announce   (bridge announces → each learns the other's path+identity)
A.send(toB, title, content) → LXMessage.create(source: A) → router.send(.opportunistic)
   → router.sendOpportunistic(toB, payload) → endpoint.send → (encrypt to B, DATA packet on the wire)
B endpoint.messageReceived(toB, plaintext) → router.received(.opportunistic) → reconstruct + validate (B knows A's identity)
   → router.messageDelivered(msg, validated) → B.delegate.messageReceived(msg, true)
```

## Testing

A 2-node in-memory integration test (`Tests/ReTiCANodeTests/LXMFNodeOpportunisticTests.swift`) reusing the mock-TCP harness from `LXMFOpportunisticDeliveryTests` (a `TCPConnection` whose `send` captures bytes into a `LockIsolated`, whose events are yielded to bridge packets between the two stores), but driving two `LXMFNode` `TestStore`s instead of raw `Endpoint`s:

1. Build A and B `LXMFNode`s (identities `aIdentity`/`bIdentity`), inject `TestClock`, a constant `date`, `.incrementing` uuid, and the paired mock TCP.
2. Connect both; `A.registerDelivery`; `B.registerDelivery`; bridge each announce to the other (`transport.received` → `pathLearned` → `router.learnedIdentity`).
3. `A.send(destinationHash: bDelivery.hash, title: "hi", content: "hello node")`; bridge the DATA packet to B.
4. Assert B emits `.delegate(.messageReceived(message, signatureValidated: true))` with `message.content == "hello node"`, `message.hash` matching the sent message, and the recovered `sourceHash` == A's delivery hash.

`exhaustivity = .off`. Mutation-verify by breaking a translation (e.g. drop the `pathLearned → learnedIdentity` wire → `signatureValidated` becomes false; drop `messageReceived → router.received` → B never surfaces the message).

## Deferred (follow-ons)

- **Direct-over-link:** wiring `requestLink`→`openLink`, `sendDirect`→`sendOverLink`/`sendResourceOverLink`, `linkEstablished`(+dest)→`router.linkEstablished`, `resourceReceived`/`linkDataReceived`→`router.received(.direct)`, `resourceConcluded`→`router.delivered`; the `dest↔linkID` and `resourceHash↔messageHash` correlation state; and surfacing `destinationHash` on `Endpoint.linkEstablished`.
- **Path requests:** an `Endpoint.requestPath` action to wire `router.requestPath`.
- **Propagation:** wiring `PropagationNode` + the router's `PROPAGATED`/sync delegates to the `lxmf.propagation` destination, links, request-handlers, and announces.

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for the new test(s).
- Prefer non-exhaustive TCA tests (`exhaustivity = .off`).
- New production is `LXMFNode` (ReTiCANode); the integration test in `ReTiCANodeTests`. No changes to `Endpoint`/`LXMFRouter`/core in this slice (opportunistic needs none).
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
