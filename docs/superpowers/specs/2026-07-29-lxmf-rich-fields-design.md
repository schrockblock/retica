# LXMF-5a: Rich Fields (int-keyed MsgPack maps) — Design

**Sub-project:** LXMF-5 (stamps + rich fields). LXMF-5: **5a rich fields [this]** → 5b delivery-stamp PoW → 5c propagation/peering stamps. See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0` — `LXMessage.pack` payload `[timestamp, title, content, fields]` (`LXMessage.py:362`) where `fields` is an integer-keyed dict; field keys `FIELD_* = 0x01…0xFF` (`LXMF.py:8-51`).

## Goal

Close the "empty-fields-only" scope from LXMF-1: carry rich integer-keyed `fields` in an `LXMessage`, byte-compatible with genuine LXMF. This requires int-keyed msgpack map support (our `MsgPackValue` is string-keyed only) and is the foundation for stamps (5b), which append to the same payload array.

## Architecture

Two pure-core changes, byte-cross-validated together.

### 1. `MsgPack` int-keyed maps (`Sources/ReTiCA/Support/MsgPack.swift`)

Add a case to `MsgPackValue`:
```swift
case intMap([IntPair])
public struct IntPair: Equatable { public let key: Int; public let value: MsgPackValue
    public init(_ key: Int, _ value: MsgPackValue) { self.key = key; self.value = value } }
```
- **encode:** `encode(.intMap(pairs))` writes a msgpack map (`0x80|n` / `0xDE` header, same as string maps) whose keys are encoded via the existing `encodeUInt` (LXMF keys 0x01–0xFF are single-byte positive fixints) and values via `encode`. Wire order = the array order (deterministic).
- **parse:** `parseMap` becomes key-type-aware. For each pair, parse the key generically: if `.string` → string-keyed, if `.uint` → int-keyed. A non-empty map with uint keys returns `.intMap`; with string keys returns `.map` (unchanged). An **empty** map (`0x80`) returns `.map([])` (unchanged — preserves LXMF-1's empty-fields shape). A mixed-key map returns nil (LXMF never mixes). Nested int-maps (some fields are dicts) work via the existing recursion.
- Existing string-keyed users (`ResourceAdvertisement`, `Packet`) are untouched (string keys still yield `.map`). The `encode` `switch` gains the `.intMap` case (required for exhaustiveness).

### 2. `LXMessage` rich fields (`Sources/ReTiCA/LXMF/LXMessage.swift`)

- Add stored `public let fields: [MsgPackValue.IntPair]` (ordered; empty = no fields).
- `payloadBytes(timestamp:title:content:fields:)` packs the 4th element as `.map([])` when `fields.isEmpty` (unchanged empty-map bytes) else `.intMap(fields)`.
- `create(source:destinationHash:timestamp:title:content:fields:)` — `fields: [MsgPackValue.IntPair] = []` (default keeps existing callers byte-identical). Threads `fields` into `payloadBytes`, `hash`, `signature`.
- `packed` / `validateSignature` use the stored `fields` via `payloadBytes`.
- `unpack`: the 4th payload element is accepted as either an empty `.map` (→ `fields = []`) or an `.intMap` (→ `fields = pairs`); a non-empty string `.map` or any other shape → nil. Payload still must be a **4-element** array (a 5th stamp element stays rejected until 5b). The hash is still recomputed from the received payload bytes.

## Data flow

```
create(…, fields: [IntPair]) → payload [ts, title, content, (fields.isEmpty ? {} : intMap(fields))]
  → hash = full_hash(destHash‖sourceHash‖msgpack(payload)) ; signature over hashedPart‖hash
unpack(packed) → payload[3] is {} → fields=[] | intMap → fields=pairs | else nil
```

## Cross-validation

New **isolated** fixture (no churn to `lxmf_fixtures.json`): `Tests/ReTiCATests/Vectors/{generate_lxmf_rich_fixtures.py, lxmf_rich_fixtures.json, LXMFRichFixtures.swift, LXMFRichCrossValidationTests.swift}`; register in `Package.swift` (ReTiCATests resources).

- **Generator** (genuine LXMF, conda `rns`): build `LXMF.LXMessage(dst, src, content, title, fields={0x0C: b"…ticket…", 0x0F: 0x02})` (FIELD_TICKET → bytes, FIELD_RENDERER → RENDERER_MARKDOWN), fixed timestamp, `pack()`. Emit `source_private_key`, `destination_hash`, `timestamp`, `title`, `content`, `field_ticket` (hex of the 0x0C value), `field_renderer` (int, the 0x0F value), `packed` (hex), `hash` (hex).
- **Tests** (deterministic regions byte-parity; signature validated, hedged Ed25519 not compared):
  1. Build `fields = [IntPair(0x0C, .bin(field_ticket)), IntPair(0x0F, .uint(field_renderer))]`; `LXMessage.create(…, fields:)`; assert `msg.hash == reference hash` and `msg.packed[96:] == reference packed[96:]` (the payload region — byte-parity proving int-keyed field packing) and `validateSignature == true`.
  2. `LXMessage.unpack(reference packed)` recovers a message whose `fields == [IntPair(0x0C, .bin(field_ticket)), IntPair(0x0F, .uint(field_renderer))]`, `content`/`hash` match, and signature validates.
  3. Round-trip: an empty-fields `create(…)` (no `fields:`) still produces the exact empty-map payload (regression — `payloadBytes` unchanged for the default), and `unpack` gives `fields == []`.

## Testing

The cross-val above plus a couple of direct `MsgPack` unit tests (encode/parse an int-keyed map round-trips; a nested int-map round-trips) to pin the codec independently. Mutation-verify each.

## Deferred (not in this slice)

- Field **semantics** (`FIELD_*` meanings, telemetry/attachment structures) — app-level; 5a carries arbitrary int-keyed fields faithfully.
- Stamps (payload 5th element) → 5b. Peering/PN stamps → 5c.

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`. A single `>` redirect for fixture generation is allowed.
- Three-step mutation verification for every new test.
- Cross-val must drive genuine LXMF (new isolated fixture; do NOT touch `lxmf_fixtures.json`). Reference env: conda `rns` (`rns-reference-env`). Ed25519 hedged → signatures validated, never byte-compared; payload region + hash are deterministic and pinned.
- New production is pure core (`MsgPack.swift`, `LXMessage.swift`); tests in `ReTiCATests`. No ReTiCANode/Transport changes.
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
