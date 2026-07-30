# LXMF-5c: Propagation / Peering Stamps — Design

**Sub-project:** LXMF-5, final slice. LXMF-5: 5a rich fields [done] → 5b delivery stamp [done] → **5c propagation/peering stamps [this]**. Also closes the peering-key gap deferred by LXMF-4d-5 (the mesh). See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0` — `LXStamper.validate_peering_key` (`:79-82`), `validate_pn_stamp` (`:84-96`); constants `WORKBLOCK_EXPAND_ROUNDS_PEERING = 25`, `WORKBLOCK_EXPAND_ROUNDS_PN = 1000`.

## What these are

Two more proof-of-work validators, both reusing 5b's `stampWorkblock`/`stampValid`/`stampValue` with **different workblock expand-round counts**:

- **Peering key** — a stamp over a `peering_id` (in RNS, `own_identity.hash ‖ peer_identity.hash`) with the *short* 25-round workblock. Two propagation nodes present peering keys to authorize multi-message sync; this is exactly the peering key LXMF-4d-5 (mesh) deferred.
- **PN stamp** — a stamp *appended to* `lxmf_data` for propagation-node message acceptance, over the message's `transient_id` (4d-1), with the *medium* 1000-round workblock. `transient_data = lxmf_data ‖ stamp(32)`; validation strips the trailing 32 bytes, recomputes `transient_id = full_hash(lxm_data)`, and checks the stamp.

## Architecture

Extend the pure `LXStamper` (5b) — no new type:

```swift
public static let workblockExpandRoundsPeering = 25     // RNS WORKBLOCK_EXPAND_ROUNDS_PEERING
public static let workblockExpandRoundsPN = 1000        // RNS WORKBLOCK_EXPAND_ROUNDS_PN

/// Validate a peering key: a stamp over `peeringId` with the short (25-round) workblock.
public static func validatePeeringKey(peeringId: Data, peeringKey: Data, targetCost: Int) -> Bool

/// Validate a PN stamp appended to lxmf_data (transientData = lxmf_data ‖ stamp[32]): strip the
/// trailing 32-byte stamp, recompute transient_id = full_hash(lxm_data), and validate over the
/// medium (1000-round) workblock. Returns (transientId, lxmfData, value, stamp) or nil.
public static func validatePnStamp(transientData: Data, targetCost: Int)
    -> (transientId: Data, lxmfData: Data, value: Int, stamp: Data)?
```

- `validatePeeringKey` = `stampValid(stamp: peeringKey, targetCost: targetCost, workblock: stampWorkblock(material: peeringId, expandRounds: workblockExpandRoundsPeering))`.
- `validatePnStamp` = `guard transientData.count > stampSize else { return nil }`; `lxmfData = transientData.dropLast(stampSize)`; `stamp = transientData.suffix(stampSize)`; `transientId = Crypto.fullHash(lxmfData)`; `wb = stampWorkblock(material: transientId, expandRounds: workblockExpandRoundsPN)`; `guard stampValid(stamp, targetCost, wb) else { return nil }`; return `(transientId, lxmfData, stampValue(wb, stamp), stamp)`. (RNS uses a stricter `LXMF_OVERHEAD + STAMP_SIZE` minimum-length guard; the looser `> stampSize` guard is sufficient for the split — the caller supplies a real `lxmf_data`.)

## Cross-validation

New isolated fixture `lxmf_peering_fixtures.json` + generator (genuine `LXStamper`): emit a valid peering key (`generate_stamp(peering_id, cost, expand_rounds=25)`) and a valid PN stamp (`generate_stamp(transient_id, cost, expand_rounds=1000)` appended to `lxmf_data`), plus the deterministic anchors (workblock hashes, value). Low costs (≤ 4) keep generation fast. Emit: `peering_id`, `peering_cost`, `peering_key`, `peering_workblock_hash`; `lxmf_data`, `pn_cost`, `pn_stamp`, `transient_data`, `transient_id`, `pn_value`, `pn_workblock_hash`; and the round-count constants (`workblock_expand_rounds_peering`, `workblock_expand_rounds_pn`).

Tests:
1. **Constants match** genuine RNS (`workblockExpandRoundsPeering == 25`, `workblockExpandRoundsPN == 1000`).
2. **Peering key validates**: `validatePeeringKey(peering_id, peering_key, peering_cost) == true`; `Crypto.fullHash(stampWorkblock(material: peering_id, expandRounds: 25)) == peering_workblock_hash` (workblock byte-parity); a tampered key (flip a byte) → `false`.
3. **PN stamp validates**: `validatePnStamp(transient_data, pn_cost)` returns non-nil with `transientId == transient_id`, `lxmfData == lxmf_data`, `value == pn_value`; `Crypto.fullHash(stampWorkblock(material: transient_id, expandRounds: 1000)) == pn_workblock_hash`; a too-short `transientData` (≤ 32 bytes) → nil; a tampered stamp → nil.

## Also in this slice (carried from 5b review)

Correct the now-stale `LXMessage` struct **file-header** doc comment (it still says "LXMF-1 scope … rich fields and stamps are deferred"); rich fields (5a) and stamps (5b) are now supported.

## Deferred

- The peer registry, sync-over-link wiring, and `peering_id` construction/exchange (the mesh networking) — still 4d-5b integration; 5c provides the *validators* those would call.
- `defer_propagation_stamp` scheduling, stamp generation policy — app-level.

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`). No compound shell commands; temp files in `/tmp/ReTiCA/`; a single `>` for fixture generation.
- Three-step mutation verification for every new test (ensure each mutation fails a named test; substitute a biting one if needed).
- Cross-val drives genuine LXMF/LXStamper (new isolated `lxmf_peering_fixtures.json`; do NOT touch other fixtures). Reference env: conda `rns`. Workblock hashes deterministic and pinned.
- New production extends pure core (`LXStamper.swift`); the one-line `LXMessage.swift` doc-comment fix; tests in `ReTiCATests`. No ReTiCANode/Transport changes.
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
