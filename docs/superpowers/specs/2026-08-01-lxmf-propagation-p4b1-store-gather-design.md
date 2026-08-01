# LXMF Propagation P4b-1 — PropagationStore Gather-by-Transient-Id — Design

**Date:** 2026-08-01
**Status:** Approved (design)

## Context

P4b is the PN↔PN mesh **initiator** (a PN actively syncing out to a peer):
link → IDENTIFY → offer `[peering_key, transientIds]` on `/offer` → parse the
peer's wanted list → **build a container of the wanted messages** → transfer it
as a Resource (the peer ingests via P4a). To build that transfer, the initiator
must fetch the `lxmf_data` for a set of transient-ids — which the store cannot
currently do (only `entries(forDestination:)`).

P4b-1 (this slice) adds that pure store query. P4b-2 (next) is the `PNNode`
initiator glue that uses it, plus a 2-`PNNode` mesh integration test.

## Scope

**In scope:** one pure `PropagationStore` method + its unit test. No reducer,
composition, or transport.

**Out of scope:** the `PNNode` initiator, offer construction, response parsing,
the transfer, per-peer tracking, peering-key generation (all P4b-2 / P4c).

## Design

`PropagationStore` keys its entries by `transientId` in the internal `stored`
dict. Add:

```swift
/// The entries this store holds for a set of transient_ids — used to build a peer-sync transfer of the
/// messages a peer requested (`/offer` wanted list). Preserves the requested order; silently skips ids
/// not present (a peer may want an id we have since evicted).
public func entries(forTransientIds ids: [Data]) -> [Entry] {
    ids.compactMap { stored[$0] }
}
```

- **Order-preserving:** maps over `ids` in the given order (the peer's wanted
  order), not the store's sequence order.
- **Skips absent ids:** `compactMap` drops ids not in `stored`.
- `Entry.lxmfData` (already public) is what P4b-2 wraps via
  `LXMFPropagation.container(timestamp:entries:)` for the Resource.

Mirrors the existing `entries(forDestination:) -> [Entry]` shape (a sibling
query), so it reads naturally alongside it.

## Testing

Unit test in `PropagationStoreTests`:

1. Ingest three entries (tid1, tid2, tid3). `entries(forTransientIds: [tid3,
   <absent 32-byte id>, tid1])` → `[entry3, entry1]` — requested order
   preserved, the absent id skipped, tid2 excluded (not requested). Assert on
   the returned entries' `.transientId` (or `.lxmfData`).
2. `entries(forTransientIds: [])` → `[]`.

Mutation verification, one at a time (e.g. return `Array(stored.values)`
ignoring `ids` → wrong set/order; or sort by sequence → wrong order). Each must
break the test, then revert to green.

## Known Limitations (P4b-1)

- No transfer-size/limit filtering (the initiator/`P4c` applies limits).
- The initiator glue, offer/response, and transfer are P4b-2.
