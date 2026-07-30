# LXMF-4d PN Announce app-data — Design

**Sub-project:** LXMF-4d propagation, integration layer (discovery). Follows 4d-3b (PropagationNode). See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0` — `LXMRouter.get_propagation_node_app_data` (`LXMRouter.py:324-336`) and `pn_announce_data_is_valid` (`LXMF.py:224-250`).

## What this is

The `app_data` a propagation node includes in its RNS announce, so clients can discover it and read its config (timebase, limits, stamp costs). It is a msgpack 7-element array:

```
[0] false                              # legacy PN support flag (always false)
[1] timebase (int, wall-clock seconds)
[2] node_state (bool)
[3] per_transfer_limit (int, KB)       # PROPAGATION_LIMIT
[4] per_sync_limit (int)               # SYNC_LIMIT
[5] [target_stamp_cost, flexibility, peering_cost]   # 3 ints (PROPAGATION_COST, _FLEX, peering)
[6] metadata (map)
```

`pn_announce_data_is_valid` requires ≥ 7 elements with `[1]` int, `[2]` bool, `[3]`/`[4]` int, `[5]` a 3-int list, `[6]` a map.

## Architecture — two pure-core changes

### 1. `MsgPack` boolean support (`Sources/ReTiCA/Support/MsgPack.swift`)

The announce uses msgpack booleans, which our codec lacks. Add:
- `MsgPackValue.bool(Bool)`.
- `encode(.bool(b))` → `Data([b ? 0xC3 : 0xC2])` (msgpack `true`/`false`).
- `parse`: `0xC2 → .bool(false)`, `0xC3 → .bool(true)`.
- Add the `.bool` case to the `encode` switch (exhaustiveness). Existing consumers unaffected (they don't produce bools).
- While here, refresh the now-stale `MsgPackValue` doc comment to mention booleans and integer-keyed maps (`intMap`, added in 5a).

### 2. `PNAnnounce` (`Sources/ReTiCA/LXMF/PNAnnounce.swift`, pure, zero-dep)

```swift
public struct PNAnnounce: Equatable {
    public var timebase: Int
    public var nodeState: Bool
    public var perTransferLimit: Int
    public var perSyncLimit: Int
    public var targetStampCost: Int
    public var stampCostFlexibility: Int
    public var peeringCost: Int
    public var metadata: MsgPackValue        // element [6]; default .map([]) (empty)

    public var packed: Data                  // msgpack([false, timebase, nodeState, transfer, sync, [cost,flex,peer], metadata])
    public static func parse(_ data: Data) -> PNAnnounce?    // full structural validation (nil if malformed)
    public static func isValid(_ data: Data) -> Bool         // parse(data) != nil
}
```

- `packed` = `MsgPack.encode(.array([.bool(false), .uint(timebase), .bool(nodeState), .uint(perTransferLimit), .uint(perSyncLimit), .array([.uint(targetStampCost), .uint(stampCostFlexibility), .uint(peeringCost)]), metadata]))` (all counts are non-negative → `.uint`).
- `parse` = decode → `.array(items)`, `items.count >= 7`; `items[1]` `.uint`→timebase, `items[2]` `.bool`→nodeState, `items[3]`/`items[4]` `.uint`, `items[5]` `.array` of exactly 3 `.uint`, `items[6]` a `.map` **or** `.intMap` (the metadata map); else nil. `items[0]` is ignored (legacy flag). `isValid` = `parse(data) != nil`, mirroring `pn_announce_data_is_valid`.

Field *semantics* (what a client does with the config) stay at the app/mesh layer; this slice is the wire format + validity.

## Cross-validation

New isolated fixture `lxmf_pn_announce_fixtures.json` + generator: build the announce list with genuine LXMF constants (`LXMF.LXMRouter.PROPAGATION_LIMIT` etc.), `msgpack.packb` it (genuine encoder), and assert genuine `LXMF.pn_announce_data_is_valid(packed) == True`. Also emit an invalid sample (a 6-element array) whose genuine `pn_announce_data_is_valid` is `False`. Emit: `packed`, `timebase`, `node_state`, `per_transfer_limit`, `per_sync_limit`, `target_stamp_cost`, `stamp_cost_flexibility`, `peering_cost`, `invalid_packed`.

Tests:
1. **parse recovers the fields** — `PNAnnounce.parse(reference packed)` yields the emitted `timebase`/`nodeState`/limits/costs and `metadata == .map([])`.
2. **pack byte-parity** — building `PNAnnounce` from the emitted values and reading `.packed` equals the reference `packed` byte-for-byte (genuine msgpack is deterministic).
3. **isValid** — `isValid(reference packed) == true`; `isValid(invalid_packed) == false` (agreeing with genuine `pn_announce_data_is_valid`).
4. A direct `MsgPack` bool unit test (encode/parse `true` and `false` round-trip; `0xC2`/`0xC3` bytes).

## Deferred

- The RNS announce mechanics (attaching this app_data to a `Destination` announce) — Endpoint/Transport glue.
- Field semantics (auto-peering decisions, limit enforcement) — mesh/app layer.
- Non-empty metadata content — carried opaquely; specific metadata keys are app-level.

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`). No compound shell commands; temp files in `/tmp/ReTiCA/`; a single `>` for fixture generation.
- Three-step mutation verification for every new test.
- Cross-val drives genuine LXMF (new isolated fixture via genuine `msgpack.packb` + `pn_announce_data_is_valid`; do NOT touch other fixtures). Reference env: conda `rns`.
- New production is pure core (`MsgPack.swift`, `PNAnnounce.swift`); tests in `ReTiCATests`. No ReTiCANode/Transport changes.
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
