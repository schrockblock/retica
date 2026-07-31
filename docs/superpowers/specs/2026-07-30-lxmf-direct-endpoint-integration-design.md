# LXMF Direct-over-Link Endpoint Integration — Design

**Date:** 2026-07-30
**Status:** Approved (design)

## Goal

Wire `LXMFNode` (the production composition of `Endpoint` + `LXMFRouter`) so a
real node can deliver an LXMF message **directly over a Link** — as a link
packet or a Resource — and receive one over an inbound link. This is the
second production integration slice, following the opportunistic 1:1 slice
(commit `648c036`).

## Scope

**In scope:** direct outbound (establish / reuse / queue-drain), direct
inbound (link packet + Resource), and link lifecycle (close, fail,
path-request-on-no-path). Both the `Endpoint` shared-code changes and the
`LXMFNode` wiring.

**Deferred (explicit decision):** **delivery confirmation.** The retry timer
in `LXMFRouter` re-sends whatever representation is pending, so a direct
message re-sends its **whole representation up to `maxAttempts` (5×)** on the
retry timer, then emits `deliveryFailed` even when the message actually
arrived; `deliveryConfirmed` never fires for direct. This is a **known
limitation of this slice**, to be closed by the next slice (wire
`endpoint.resourceConcluded(linkID, resourceHash) → router.delivered(messageHash)`
with a `linkID → messageHash` correlation, since `resourceHash =
fullHash(data + randomHash)` folds in 4 random bytes and is not derivable at
send time).

## Architecture

`LXMFNode` composes `Endpoint` and `LXMFRouter` via `Scope`, translating
delegates ↔ actions. The direct path adds the missing translations plus one
small piece of correlation state; two shared-code changes land in `Endpoint`.

### 1. Shared `Endpoint` changes (low ripple)

**a. `linkEstablished` carries `destinationHash`.**

Delegate signature:

```swift
// before
case linkEstablished(linkID: Data)
// after
case linkEstablished(linkID: Data, destinationHash: Data)
```

Handler (Endpoint.swift:165-166) pulls the dest from the link element's state,
mirroring how `linkFailed` already does it (Endpoint.swift:178):

```swift
case let .link(.element(elementID, .delegate(.established(linkID, _)))):
    guard let destHash = state.links[id: elementID]?.destinationHash else { return .none }
    return .send(.delegate(.linkEstablished(linkID: linkID, destinationHash: destHash)))
```

`destinationHash` is always populated — both the initiator init
(LinkSession.swift:64-74) and responder init (LinkSession.swift:91-100) set
`self.destinationHash`. Every existing `receive(\.delegate.linkEstablished)`
in `EndpointTests` and `LXMFDirectDeliveryTests` is a bare case-path match
with **no payload binding**, so adding the associated value does **not**
require edits to those tests.

**b. New `requestPath` action.**

```swift
case requestPath(destinationHash: Data)
```

Handler forwards to Transport (which already has `.requestPath`,
Transport.swift:97), mirroring `openLink`'s forward pattern:

```swift
case let .requestPath(destinationHash):
    return .send(.transport(.requestPath(destinationHash: destinationHash)))
```

### 2. `LXMFNode` changes

**State:** add

```swift
public var directLinks: [Data: Data] = [:]   // destinationHash → linkID
```

for close / linkClosed correlation. No `resourceHash ↔ messageHash` map
(delivery confirmation is deferred).

**`send` action:** thread a `method` parameter so callers can choose the
delivery method:

```swift
case send(destinationHash: Data, title: Data, content: Data, method: DeliveryMethod)
```

The existing opportunistic integration test's single call site is updated to
pass `.opportunistic` (assertions unchanged). Direct callers pass `.direct`.
The `send` handler passes `method` through to `router.send(message:,
desiredMethod: method)`.

**New translations** (added to the `Reduce` body):

| Trigger | Effect |
|---|---|
| `router.delegate.requestLink(dest)` | `endpoint.openLink(destinationHash: dest)` |
| `router.delegate.requestPath(dest)` | `endpoint.requestPath(destinationHash: dest)` |
| `router.delegate.sendDirect(linkID, data, asResource)` | `asResource ? endpoint.sendResourceOverLink(linkID:, data:) : endpoint.sendOverLink(linkID:, data:)` |
| `router.delegate.closeLink(dest)` | if `directLinks[dest]` present → `endpoint.closeLink(linkID:)`, else `.none` |
| `endpoint.delegate.linkEstablished(linkID, dest)` | set `directLinks[dest] = linkID`; `router.linkEstablished(destinationHash: dest, linkID:)` |
| `endpoint.delegate.linkClosed(linkID, _)` | reverse-find dest for `linkID`, remove entry, `router.linkClosed(destinationHash: dest)` |
| `endpoint.delegate.linkFailed(dest)` | remove `directLinks[dest]`, `router.linkClosed(destinationHash: dest)` |
| `endpoint.delegate.linkDataReceived(linkID, data)` | `router.received(method: .direct, destinationHash: Data(), data:)` |
| `endpoint.delegate.resourceReceived(linkID, data)` | `router.received(method: .direct, destinationHash: Data(), data:)` |
| `endpoint.delegate.pathLearned(h, _)` | `.merge(router.learnedIdentity(...) [existing, if identity known], router.learnedPath(destinationHash: h))` |

**Why the throwaway `destinationHash` on inbound is correct:** in the
`.direct` branch of `LXMFRouter.received` (LXMFRouter.swift:119-121),
`LXMessage.unpack(data)` reconstructs the message from the packed bytes and
**ignores** the `destinationHash` argument (the dest is embedded in the
packed payload). Passing `Data()` is therefore correct — no `linkID → dest`
map is needed for the inbound path.

**Why `learnedPath` must be added to the `pathLearned` wire:** the router's
`establish` gate checks `knownPaths.contains(dest)` — on a no-path send it
emits `requestPath` and parks in `.awaitingPath`. The router only flips
`awaitingPath → establishing → requestLink` when it receives `.learnedPath`
(LXMFRouter.swift:231-236). So `endpoint.pathLearned` must forward
`router.learnedPath` in addition to the existing `learnedIdentity` wire, or a
no-path direct send would stall.

### Data flow (no pre-known path → direct Resource delivery)

```
A.send(.direct)
  → router.send(.direct): dest unknown → establish → requestPath, park .awaitingPath
  → endpoint.requestPath → transport path request
  → (path learned) → endpoint.pathLearned → router.learnedPath
  → router: awaitingPath → establishing → requestLink
  → endpoint.openLink → Link handshake
  → endpoint.linkEstablished(linkID, dest) → router.linkEstablished → drain queue
  → router.sendDirect(linkID, packed, asResource: true) → endpoint.sendResourceOverLink
  → [wire] → B endpoint.resourceReceived(linkID, data)
  → B router.received(.direct, _, data) → unpack → B .delegate.messageReceived (validated)
```

## Testing

One 2-node in-memory integration test, reusing the `LXMFDirectDeliveryTests`
link-handshake bridge but driven entirely through `LXMFNode` (no hand-wired
Endpoint/router):

1. B announces its `lxmf.delivery` destination; bridge B's announce to A so A
   learns B's path + identity.
2. `A.send(destinationHash: B, …, method: .direct)` with a message **sized to
   exceed `Link.mdu`** so `directRepresentation == .resource` (exercises the
   `sendResourceOverLink` path — the primary/interesting direct
   representation).
3. Bridge the Link handshake packets A↔B.
4. Assert B emits `.delegate.messageReceived(message, signatureValidated:
   true)` with correct content/title/source/dest.

Mutation verification: mutate one load-bearing wire at a time (e.g. drop the
`learnedPath` merge, invert `asResource`, drop the `resourceReceived` wire),
confirm the test fails, revert, confirm it passes.

## Known Limitations (this slice)

- **No delivery confirmation for direct** — see Scope/Deferred. Direct
  messages re-send up to 5× and end in `deliveryFailed` even on success.
- **Single-in-flight assumption** documented for the follow-on: when
  confirmation is added, `linkID → messageHash` correlation assumes one
  in-flight resource per link at a time.
