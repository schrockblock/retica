# LXMF Direct Delivery Confirmation — Design

**Date:** 2026-07-31
**Status:** Approved (design)

## Goal

Close the retry-storm limitation left by the direct-over-link slice: when a
direct message sent as a **Resource** is proven received (the sender's
`endpoint.resourceConcluded` fires), resolve it to `deliveryConfirmed` —
cancelling the per-message retry timer instead of re-sending the whole
Resource up to `maxAttempts` and then reporting `deliveryFailed` on a message
that actually arrived.

## Scope

**In scope:** confirmation for **Resource-direct** sends only, with the
`linkID → messageHash` correlation living in `LXMFRouter` (the decoupled,
unit-testable reducer), plus the thin `LXMFNode` wiring and a new
`deliveryConfirmed` app-facing delegate.

**Out of scope / documented limitations:**
- **Packet-direct stays best-effort.** Small direct messages sent as a link
  packet (`sendOverLink`) have no receipt in our stack, so their (cheap) 5×
  packet re-send remains. Only the Resource path — the one with the expensive
  storm — gets confirmation.
- **Single-in-flight per link.** If two Resources are in flight on one link
  before either concludes, the correlation map's last-write-wins means the
  earlier message won't confirm (it retries/fails). LXMF sends are effectively
  serialized per destination, so this is the dominant case; a FIFO is rejected
  because resource-conclusion order is not guaranteed.
- **`resourceFailed` is not separately wired** — the existing retry timer
  already re-sends, so failure recovery is unchanged.
- Opportunistic delivery confirmation remains out of scope (our stack has no
  opportunistic DATA-packet receipt).

## Architecture

### Why the router owns the correlation

The map could live in `LXMFNode` (recover `messageHash` by unpacking
`sendDirect`'s `data`), but that re-parses the whole message and puts stateful
correlation in the app layer, which only has integration tests. The router
already knows, at each Resource-send site, that `message.hash` went out on
`linkID`. Keeping the map there follows the project's pattern — logic in the
decoupled reducer, the app as a dumb translator — and makes the correlation
unit-testable with no `Endpoint`.

### `LXMFRouter` changes

**State:** add

```swift
/// linkID → message.hash of the Resource-direct send currently in flight on that link.
/// Single-in-flight per link (last write wins); resolves resourceConcluded → deliveryConfirmed.
var linkResourceInFlight: [Data: Data] = [:]
```

**Record at the 3 Resource-send sites** (only when `asResource == true`):
- `.send` fast path over an already-active link (LXMFRouter.swift:143-149)
- `.linkEstablished` queue drain (LXMFRouter.swift:197-201)
- `.retryDue` resend over an active link (LXMFRouter.swift:262-265)

Set `state.linkResourceInFlight[linkID] = message.hash` (resp. `m.hash`)
alongside each `sendDirect(asResource: true)` emission. Packet sends
(`asResource == false`) record nothing.

**New action** `resourceDeliveredOnLink(linkID: Data)`:

```swift
case let .resourceDeliveredOnLink(linkID):
    guard let hash = state.linkResourceInFlight[linkID] else { return .none }
    state.linkResourceInFlight[linkID] = nil
    return .send(.delivered(messageHash: hash))
```

This reuses the existing `.delivered` handler (LXMFRouter.swift:239-243),
which clears `pendingDeliveries[hash]`, cancels the retry timer, and emits the
`deliveryConfirmed` delegate.

**Clear on link close:** in the `.linkClosed(dest)` handler
(LXMFRouter.swift:215-229), before nil'ing `directLinks[dest]`, capture the
active linkID and clear its inflight entry:

```swift
if case let .active(linkID) = state.directLinks[dest] {
    state.linkResourceInFlight[linkID] = nil
}
```

### `LXMFNode` changes (thin wiring)

- New translation: `endpoint.delegate.resourceConcluded(linkID, _) →
  router.resourceDeliveredOnLink(linkID)`.
- New translation: `router.delegate.deliveryConfirmed(hash) →
  node.delegate.deliveryConfirmed(messageHash: hash)`.
- New delegate case `deliveryConfirmed(messageHash: Data)`, mirroring the
  existing `deliveryFailed` forward.

### `Endpoint`

No change — `resourceConcluded(linkID:, resourceHash:)` is already surfaced
(Endpoint.swift:185-187).

### Data flow (direct Resource → confirmation)

```
A router: sendDirect(linkID, packed, asResource: true)
          → record linkResourceInFlight[linkID] = message.hash
A endpoint: sendResourceOverLink → RESOURCE_ADV → … → B proves receipt (PRF)
A endpoint: resourceConcluded(linkID, resourceHash)
          → router.resourceDeliveredOnLink(linkID)
          → linkResourceInFlight[linkID] → message.hash
          → .delivered(hash): cancel retry, clear pending, emit deliveryConfirmed
A node: .delegate.deliveryConfirmed(messageHash: hash)
```

## Testing

1. **Router unit test** (`LXMFRouterTests`, no Endpoint): drive
   `.send(.direct)` for a message whose `directRepresentation == .resource`
   over an active link (or via `linkEstablished` drain), assert a
   `sendDirect(asResource: true)` delegate; then send
   `.resourceDeliveredOnLink(linkID)` and assert the `deliveryConfirmed`
   delegate fires and the retry timer is cancelled (no later `retryDue`
   resend / no `deliveryFailed`).
2. **Integration test extension** (`LXMFNodeDirectTests`): continue the
   existing direct-Resource flow — after B proves receipt, bridge B's
   `RESOURCE_PRF` back to A so A's `resourceConcluded` fires, and assert A
   emits `.delegate.deliveryConfirmed(messageHash:)` (with the sent message's
   hash).

Mutation verification (one at a time, revert between each): e.g. drop the
`linkResourceInFlight` recording at the send site (→ `resourceDeliveredOnLink`
finds nothing → no confirmation), and make `resourceDeliveredOnLink` a no-op
(→ confirmation never fires). Each must break the covering test, then revert
to green.

## Known Limitations (restated)

- Confirmation covers Resource-direct only; packet-direct and opportunistic
  remain best-effort.
- Single-in-flight-per-link correlation (documented above).
- `resourceFailed` handled only by the existing retry timer.
