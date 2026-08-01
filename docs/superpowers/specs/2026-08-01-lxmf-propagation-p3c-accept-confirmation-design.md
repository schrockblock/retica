# LXMF Propagation P3c — Propagation-Accept Confirmation — Design

**Date:** 2026-08-01
**Status:** Approved (design)

## Context

P1 (client send-via-PN) deferred delivery confirmation because a PN's
resource-conclusion means *the PN accepted the container* — a distinct, weaker
state than direct `deliveryConfirmed` (*the recipient got it*). P3c adds that
confirmation as its own signal, reusing the existing resource-conclusion
machinery, and in doing so closes P1's propagation retry-storm (a successful
PN-accept now cancels the retry timer instead of re-sending up to
`maxAttempts` and reporting `deliveryFailed`).

## Scope

**In scope:** record `linkResourceInFlight` for propagation sends so the
existing `resourceConcluded → resourceDeliveredOnLink → .delivered` wire
resolves; a distinct `propagationAccepted` delegate (router + `LXMFNode`); the
`.delivered` handler branches on the pending send type.

**Out of scope:** the 3-store capstone loop; P4 mesh; `retain`/transfer-limit.

## Architecture

### Why a distinct signal

The router already tags each in-flight send with its `ResendInfo`
(`.opportunistic` / `.direct` / `.propagated`). A resource conclusion resolves
to `.delivered(hash)`; branching there on the pending send's type lets direct
keep emitting `deliveryConfirmed` while propagation emits a new
`propagationAccepted` — no overloading, no ambiguity for the app.

### `LXMFRouter` changes

**Record `linkResourceInFlight` at the 3 propagation-send sites** (mirroring
the direct sites), so a PN resource-conclusion can be correlated back to the
message:

- `.sendViaPropagation` active-link branch (after the `arm(...)`):
  ```swift
  state.linkResourceInFlight[linkID] = message.hash
  ```
- `.linkEstablished` propagation-queue drain (`for item in propQueued`, after
  the `arm(...)`):
  ```swift
  state.linkResourceInFlight[linkID] = item.messageHash
  ```
- `.retryDue` `.propagated` resend (inside `if case let .active(linkID)`,
  before the `return`):
  ```swift
  state.linkResourceInFlight[linkID] = hash
  ```

(Propagation is always sent as a Resource — `LXMFNode` wires `sendPropagated →
sendResourceOverLink` — so no `asResource` guard is needed, unlike the direct
sites.)

**New delegate** (after `deliveryConfirmed`):
```swift
case propagationAccepted(messageHash: Data)
```

**Branch `.delivered`** on the pending send type (read before clearing):
```swift
case let .delivered(hash):
    guard let pending = state.pendingDeliveries[hash] else { return .none }
    state.pendingDeliveries[hash] = nil
    let outcome: Action.Delegate = {
        if case .propagated = pending.resend { return .propagationAccepted(messageHash: hash) }
        return .deliveryConfirmed(messageHash: hash)
    }()
    return .merge(.cancel(id: CancelID.retry(hash)), .send(.delegate(outcome)))
```

`resourceDeliveredOnLink` is unchanged — it still resolves
`linkResourceInFlight[linkID] → .delivered(hash)`; the branch does the rest.

### `LXMFNode` changes

- New `Delegate.propagationAccepted(messageHash:)`.
- Wire `router.delegate.propagationAccepted(hash) → node.delegate.propagationAccepted(messageHash: hash)` (mirroring the `deliveryConfirmed`/`deliveryFailed` forwards).

### `Endpoint`

No change — `resourceConcluded` is already surfaced and already wired in
`LXMFNode` (`resourceConcluded → router.resourceDeliveredOnLink`).

### Data flow

```
Client sendViaPropagation over active PN link → sendPropagated → sendResourceOverLink
  → record linkResourceInFlight[pnLinkID] = message.hash
PN concludes the ingest resource (proves receipt)
  → client endpoint.resourceConcluded(pnLinkID, _) → router.resourceDeliveredOnLink(pnLinkID)
  → .delivered(hash): pending.resend == .propagated → propagationAccepted(hash); cancel retry
  → LXMFNode .delegate.propagationAccepted(messageHash: hash)
```

## Testing

### Task 1 — router

Unit tests in `LXMFRouterTests`:

1. **Propagation-accept:** with an active PN link (`outboundPropagationNode`
   set, `directLinks[pn] = .active(linkID)`), `sendViaPropagation(msg,
   packed)` → `sendPropagated`; assert `linkResourceInFlight[linkID] ==
   msg.hash`. Then `resourceDeliveredOnLink(linkID)` → assert
   `propagationAccepted(msg.hash)` (NOT `deliveryConfirmed`), and
   `pendingDeliveries[msg.hash] == nil`.
2. **Direct regression:** the existing direct-confirmation test still emits
   `deliveryConfirmed` (the `.delivered` branch must not regress direct) —
   either the existing `routerConfirmsResourceDirectOnResourceDelivered`
   suffices, or add an explicit assert that a `.direct` resolve yields
   `deliveryConfirmed`.

Mutation verification, one at a time (e.g. drop the `.sendViaPropagation`
`linkResourceInFlight` record → no accept; invert the `.delivered` branch →
direct/propagation swapped). Each must break its covering test, then revert.

### Task 2 — LXMFNode

Extend the P1 send test (`lxmfNodeSendsViaPropagationNode`) — after the PN stub
receives the container, bridge its `RESOURCE_PRF` back to the client so the
client's `resourceConcluded` fires, and assert the client emits
`.delegate.propagationAccepted(messageHash:)` matching the sent message's
(deterministic) hash. Mutation: break the router→node `propagationAccepted`
forward → no accept.

## Known Limitations (P3c)

- `propagationAccepted` means the PN accepted the container, not that the
  recipient received it (the recipient fetches via P2). This is the intended,
  documented semantics.
- 3-store capstone loop and P4 mesh remain.
