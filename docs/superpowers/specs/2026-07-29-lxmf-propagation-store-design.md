# LXMF-4d-3: Propagation Node Message Store — Design

**Sub-project:** LXMF-4d (propagation). LXMF-4d: 4d-1 container [done] → 4d-2 client send via PN [done] → **4d-3 PN message store [this]** → 4d-4 client sync → 4d-5 mesh. See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0` — `LXMRouter.propagation_resource_concluded` (`LXMRouter.py:2336+`, ingest), `clean_message_store` (`LXMRouter.py:1183+`, size-limited eviction), `message_get_request` (`LXMRouter.py:1482+`, serve-by-recipient).

## Scope decision (autonomous)

The reference propagation node is dominated by peering keys, proof-of-work stamps, throttling, and auto-peering — which belong to **4d-5 (mesh)** and **LXMF-5 (stamps)**, not here. The substantive, unit-testable heart of a PN is its **message store**: ingest containers, dedup by `transient_id`, evict under a storage limit, and query entries addressed to a recipient. This slice builds that as a pure value type. The **serve wiring** (registering the `lxmf.propagation` destination, handling links/resources/request-handlers) is app/Endpoint integration glue — deferred to a follow-on (4d-3b), consistent with how the router's transport interactions are app-wired delegates. No peering, no stamps here (a single client's store-and-forward).

## Architecture

New pure value type `Sources/ReTiCA/LXMF/PropagationStore.swift` (zero-dep like `LXMFPropagation`; depends only on `LXMFPropagation` + `LXMessage.destinationLength`). A propagation node (or its future reducer/app) holds one and drives it.

```swift
public struct PropagationStore: Equatable {
    public struct Entry: Equatable {
        public var transientId: Data
        public var destinationHash: Data
        public var lxmfData: Data
        var sequence: Int            // insertion order, for oldest-first eviction/serve
    }
    private var stored: [Data: Entry] = [:]   // keyed by transientId
    private var nextSequence: Int = 0
    public var storageLimitBytes: Int?        // nil = unbounded (RNS default)

    public init(storageLimitBytes: Int? = nil)

    /// Ingest a propagation container (msgpack([timestamp, [lxmf_data…]])). Parses it, computes each
    /// entry's transient_id, and stores entries not already present (dedup by transient_id). Then evicts
    /// oldest entries while over `storageLimitBytes`. Returns the transient_ids newly stored and retained.
    @discardableResult public mutating func ingest(container: Data) -> [Data]

    public func contains(transientId: Data) -> Bool
    public var count: Int
    public var sizeBytes: Int                 // sum of stored lxmfData counts

    /// Entries addressed to `destinationHash` (the leading 16 bytes of each lxmf_data), oldest first.
    public func entries(forDestination destinationHash: Data) -> [Entry]

    /// Remove a stored entry (e.g. after a client confirms delivery).
    public mutating func remove(transientId: Data)
}
```

### Semantics

- **ingest:** `guard let (_, lxmfDatas) = LXMFPropagation.parseContainer(container) else { return [] }`. For each `lxmfData`: `let tid = LXMFPropagation.transientId(lxmfData:)`; `guard let dest = LXMFPropagation.destinationHash(lxmfData:) else { continue }` (skip malformed/short entries); if `stored[tid] != nil` skip (**dedup** — a re-sent message has identical bytes → identical `transient_id`); else insert `Entry(tid, dest, lxmfData, nextSequence)`, `nextSequence += 1`, record `tid` as newly stored. After the loop, **evict** the lowest-`sequence` entries while `sizeBytes > storageLimitBytes` (if a limit is set). Return the newly-stored ids that remain after eviction.
- **entries(forDestination):** `stored.values.filter { $0.destinationHash == destinationHash }.sorted { $0.sequence < $1.sequence }`.
- **contains / count / sizeBytes / remove:** direct.
- `transient_id` dedup is why a PN can store idempotently even as clients retry (4d-2b re-sends the same bytes).

## Testing

Unit tests (pure value type; no TCA, no cross-val — the wire/`transient_id` were pinned in 4d-1). Build containers with `LXMFPropagation.container(timestamp:entries:)` over arbitrary `lxmf_data` blobs (`destHash(16) ‖ arbitrary bytes`), since the store treats the encrypted tail as opaque.

1. **Ingest stores + dedups by transient_id.** Ingest a container with one entry → `count == 1`, `contains(tid)`, `ingest` returned `[tid]`. Ingest the same container again → `count == 1`, second `ingest` returns `[]`.
2. **entries(forDestination) filters by destHash.** Ingest entries for two different destination hashes → `entries(forDestination: A)` returns only A's (correct count + all with destHash A), oldest-first by insertion.
3. **remove drops an entry.** Ingest one → `remove(tid)` → `count == 0`, `!contains(tid)`.
4. **Storage-limit eviction removes oldest first.** With a small `storageLimitBytes`, ingest several entries exceeding it → `sizeBytes <= limit`, the oldest entries are gone and the newest remain (`contains` newest, `!contains` oldest).
5. **Malformed / short entries are skipped, not crashing.** A container whose entry is < 16 bytes → skipped (not stored); a non-container blob → `ingest` returns `[]`, `count == 0`.

Mutation-verify each.

## Deferred (not in this slice)

- **PN serve wiring (4d-3b):** register the `lxmf.propagation` `IN` destination; on a client link + concluded resource → `store.ingest`; a download request-handler → `store.entries(forDestination: clientDeliveryHash)` → respond; a PN announce (`pn_announce_data`). This is Endpoint/Transport integration.
- Peering keys, proof-of-work stamps, throttling, auto-peering, PN↔PN mesh → 4d-5 / LXMF-5.
- Persistence to disk (RNS writes files); our store is in-memory.

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new test.
- New production is pure core (`Sources/ReTiCA/LXMF/PropagationStore.swift`); tests in `ReTiCATests`. No ReTiCANode/Transport changes.
- Reuses `LXMFPropagation` (4d-1); no new fixture (behavioral unit tests).
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
