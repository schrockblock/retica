# LXMF-4d-5: Mesh Gossip Primitive — Design

**Sub-project:** LXMF-4d (propagation), final core slice. LXMF-4d: 4d-1 container → 4d-2 client send → 4d-3 PN store → 4d-4 client sync → **4d-5 mesh gossip primitive [this]**. See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0` — `LXMRouter.offer_request` (`LXMRouter.py:2266+`, computes `wanted_ids` from an offered `transient_id` list minus what the node already has) and `LXMPeer` sync (a peer offers its `transient_id` set; the receiver pulls the ones it lacks).

## Scope decision (autonomous)

Full PN↔PN peering is a large networking feature: an `LXMPeer` registry, a sync protocol wired over links, and **peering keys that are proof-of-work stamps (LXMF-5)** — and it depends on a propagation-node *component* (the deferred 4d-3b serve wiring) that does not exist yet. Building all of that is out of reach here and partly blocked on LXMF-5.

The pure, in-stack-testable **heart** of the mesh is its dedup computation: given a peer's offered `transient_id` set, which ones does the local store lack (and would therefore pull)? This is exactly `offer_request`'s `wanted_ids`. It extends `PropagationStore`, reuses `contains`, and is the natural capstone for 4d under our core-first architecture. Everything else (peer registry, sync-over-link wiring, peering-key PoW, auto-peering, throttling) is deferred to a future mesh-integration slice and LXMF-5.

## Architecture

Extend the pure `PropagationStore` (4d-3) — no new type, no TCA, no networking:

```swift
extension PropagationStore {
    /// All stored transient_ids, oldest-first (a propagation node's "offer" set to a peer).
    public var transientIds: [Data]

    /// Of a peer's offered transient_ids, the ones this store is missing (and would pull). Preserves
    /// the offered order and de-duplicates repeated ids within the offer.
    public func wanted(fromOffered offered: [Data]) -> [Data]
}
```

- `transientIds`: `stored.values.sorted { $0.sequence < $1.sequence }.map { $0.transientId }` (deterministic, oldest-first).
- `wanted(fromOffered:)`: keep each offered id that is **not** `contains(transientId:)`, in offered order, dropping duplicates within the offer:
  ```swift
  var seen = Set<Data>()
  return offered.filter { !contains(transientId: $0) && seen.insert($0).inserted }
  ```

Gossip dedup rests on `transient_id`: two propagation nodes converge because each pulls only the ids it lacks, and identical messages carry identical `transient_id`s (4d-1).

## Testing

Unit tests (pure; extends `PropagationStoreTests`). Build stored entries via `ingest` as in 4d-3.

1. **transientIds lists all stored, oldest-first.** Ingest entries e1, e2, e3 (one container) → `transientIds == [tid(e1), tid(e2), tid(e3)]`.
2. **wanted returns only the missing ids, in offered order.** Store holds e1, e2; offer `[tid(e1), tid(e2), tid(x), tid(y)]` (x, y not stored) → `wanted == [tid(x), tid(y)]`.
3. **wanted de-dups within the offer.** Store empty; offer `[tid(x), tid(x), tid(y)]` → `wanted == [tid(x), tid(y)]`.
4. **wanted is empty when the store already has everything offered.** Store holds e1, e2; offer `[tid(e1), tid(e2)]` → `wanted == []`.

Mutation-verify each.

## Deferred (not in this slice)

- `LXMPeer` registry + PN↔PN sync protocol wired over links (needs the PN component / 4d-3b).
- Peering keys / proof-of-work stamps (`LXStamper`, `PROPAGATION_COST`) → LXMF-5.
- Auto-peering, throttling, `control_allowed_list`, unpeer.

## LXMF-4d status after this slice

The **pure/core + router** substance of propagation is complete: container + `transient_id` (4d-1), client send crypto + router orchestration (4d-2), the PN message store (4d-3), client sync request (4d-4), and the mesh gossip primitive (4d-5). Remaining propagation work is **integration/networking** (PN serve wiring 4d-3b, mesh sync-over-link) and **LXMF-5** (peering-key + delivery stamps) — documented in the `lxmf` memory.

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new test.
- New production is pure core (extends `Sources/ReTiCA/LXMF/PropagationStore.swift`); tests in `ReTiCATests`. No ReTiCANode/Transport changes.
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
