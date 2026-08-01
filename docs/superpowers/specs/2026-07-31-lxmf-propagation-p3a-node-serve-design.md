# LXMF Propagation P3a — PropagationNode Two-Phase Serve — Design

**Date:** 2026-07-31
**Status:** Approved (design)

## Context

P3 is the propagation-node **server** role (the store-and-forward node that
ingests clients' containers and serves them on download). It is the first
server-role composition and decomposes into:

- **P3a (this slice) — `PropagationNode` two-phase serve:** extend the
  decoupled reducer so it answers the RNS `/get` protocol's two phases —
  phase-1 (list transient_ids for a client) and phase-2 (serve the wanted
  blobs + purge the client's haves). Unit-testable, no transport.
- **P3b — `PNNode` server composition:** a new `Endpoint` + `PropagationNode`
  reducer that registers/announces `lxmf.propagation`, ingests concluded
  resources, tracks the IDENTIFY'd client per link, and dispatches the `/get`
  request handler to the P3a serve actions — closing the store-and-forward
  loop against real P1 client-send and P2 client-sync.
- **P3c — propagation-accept confirmation (small client follow-on):** record
  `linkResourceInFlight` for propagation sends so P1's deferred
  "PN accepted" confirmation fires through the existing `resourceConcluded`
  wire.

## Scope (P3a)

**In scope:** the two-phase serve on `PropagationNode` — a phase-1 id-list
action/delegate, and extending the phase-2 serve to filter by the client's
`wants` and purge its `haves`. Pure reducer logic over the existing
`PropagationStore`.

**Out of scope:** the Endpoint composition, IDENTIFY resolution, request
handler, announce (all P3b); `max_messages`/transfer-limit capping;
stamped-message handling.

## Architecture

`PropagationStore.Entry` already carries `transientId`, `destinationHash`,
`lxmfData`, `sequence`; `entries(forDestination:)` returns a destination's
entries sorted by sequence; `remove(transientId:)` deletes one. Both phases
derive from these.

### Phase-1 — list

New action + delegate:

```swift
case messageListRequested(destinationHash: Data)
// Delegate:
case deliverMessageList(destinationHash: Data, transientIds: [Data])
```

Handler:

```swift
case let .messageListRequested(destinationHash):
    let ids = state.store.entries(forDestination: destinationHash).map(\.transientId)
    return .send(.delegate(.deliverMessageList(destinationHash: destinationHash, transientIds: ids)))
```

(Sorted by the store's `sequence`, matching `entries(forDestination:)`.)

### Phase-2 — get (serve wanted + purge haves)

Extend the existing `messagesRequested`:

```swift
// before: case messagesRequested(destinationHash: Data)
case messagesRequested(destinationHash: Data, wants: [Data], haves: [Data])
```

Handler:

```swift
case let .messagesRequested(destinationHash, wants, haves):
    for tid in haves { state.store.remove(transientId: tid) }              // purge what the client already has
    let wantSet = Set(wants)
    let entries = state.store.entries(forDestination: destinationHash)
        .filter { wantSet.contains($0.transientId) }
        .map(\.lxmfData)
    return .send(.delegate(.deliverMessages(destinationHash: destinationHash, entries: entries)))
```

Serving is filtered to `wants ∩ (this destination's entries)`; a `want` for a
non-stored id or another destination's id is silently skipped (matches RNS
`message_get_request`, which serves only ids present for the remote
destination).

### Existing-test churn

The 3 `PropagationNodeTests` that call `messagesRequested(destinationHash:)`
update to the new signature by passing explicit `wants` (and `haves: []`):

- `propagationNodeServesByDestination` — `wants: [tid(a1), tid(a2)]` → still
  `[a1, a2]`.
- `propagationNodeServesEmptyWhenNoneAddressed` — `wants: []` → empty.
- `propagationNodeDropsDeliveredMessages` — `wants: [tid]` → empty (already
  removed).

## Testing

Unit tests in `PropagationNodeTests` (no Endpoint):

1. **Phase-1 lists only the destination's ids:** ingest entries for dest A and
   dest B; `messageListRequested(A)` → `deliverMessageList(A, [tid(a1),
   tid(a2)])` in sequence order, excluding B's.
2. **Phase-2 serves only wanted:** ingest a1, a2 for A; `messagesRequested(A,
   wants: [tid(a1)], haves: [])` → `deliverMessages(A, [a1])` (a2 withheld).
3. **Phase-2 purges haves:** ingest a1, a2; `messagesRequested(A, wants:
   [tid(a2)], haves: [tid(a1)])` → serves `[a2]` and `store.contains(tid(a1))
   == false` afterward.
4. **Want for a foreign/absent id is skipped:** `messagesRequested(A, wants:
   [tid(b1), <random>], haves: [])` → empty (b1 belongs to B; random absent).

Plus the 3 updated existing tests. Mutation verification, one at a time (e.g.
drop the `haves` purge loop; invert the `wants` filter to `!contains`). Each
must break its covering test, then revert to green.

## Known Limitations (P3a)

- No transfer-limit / `max_messages` capping (P3b or later).
- Endpoint glue, IDENTIFY, announce, and the `/get` handler are P3b.
