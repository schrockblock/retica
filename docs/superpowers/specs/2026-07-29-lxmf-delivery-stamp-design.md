# LXMF-5b: Delivery-Stamp Proof-of-Work — Design

**Sub-project:** LXMF-5. LXMF-5: 5a rich fields [done] → **5b delivery-stamp PoW [this]** → 5c propagation/peering stamps. See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0` — `LXStamper.stamp_workblock` / `stamp_valid` / `stamp_value` / `generate_stamp` (`LXStamper.py:50-140`); `LXMessage.pack` stamp append (`LXMessage.py:371-373`, `validate_stamp` `:273-294`). Constants `WORKBLOCK_EXPAND_ROUNDS = 3000`, `STAMP_SIZE = 32`.

## What a stamp is

An anti-spam proof-of-work bound to a message's `message_id` (= its `hash`). A "workblock" is expanded deterministically from the material; a stamp is a 32-byte value whose `full_hash(workblock ‖ stamp)` has at least `target_cost` leading zero bits. Generation is a brute-force search; validation is deterministic.

- `stamp_workblock(material, rounds=3000)` = concatenation over `n in 0..<rounds` of `hkdf(length=256, ikm=material, salt=full_hash(material ‖ msgpack(n)), context=nil)` → a 768 KB block.
- `stamp_valid(stamp, target_cost, workblock)` = `int(full_hash(workblock ‖ stamp)) < 2^(256 - target_cost)`.
- `stamp_value(workblock, stamp)` = count of leading zero bits of `full_hash(workblock ‖ stamp)`.
- `generate_stamp(message_id, target_cost)` = search random 32-byte stamps against `stamp_workblock(message_id)` until `stamp_valid`.

**Wire placement (critical):** in `LXMessage.pack`, the `hash`/`message_id` and `signature` are computed over the **4-element** payload `[ts, title, content, fields]`; the stamp is then **appended** as a 5th payload element and the whole 5-element array is msgpacked into `packed`. So the hash is over `payload[:4]` (stamp excluded); `unpack` must strip the 5th element before rehashing; the signature is unaffected by the stamp.

## Architecture — two tasks, one slice

### Task 1 — `LXStamper` core (pure `Sources/ReTiCA/LXMF/LXStamper.swift`)

```swift
public enum LXStamper {
    public static let workblockExpandRounds = 3000     // RNS WORKBLOCK_EXPAND_ROUNDS
    public static let stampSize = 32                   // RNS STAMP_SIZE (HASHLENGTH/8)

    public static func stampWorkblock(material: Data, expandRounds: Int = workblockExpandRounds) -> Data
    public static func stampValid(stamp: Data, targetCost: Int, workblock: Data) -> Bool
    public static func stampValue(workblock: Data, stamp: Data) -> Int
    public static func generateStamp(messageId: Data, targetCost: Int) -> Data
}
```
- `stampWorkblock`: `var wb = Data(); for n in 0..<expandRounds { wb += Crypto.hkdf(length: 256, derivedFrom: material, salt: Crypto.fullHash(material + MsgPack.encode(.uint(UInt64(n)))), context: nil) }`.
- `stampValid`: compare `Crypto.fullHash(workblock + stamp)` as a big-endian integer against `2^(256 - targetCost)`. Implemented by checking the top `targetCost` bits are zero (leading-zero-bit count `>= targetCost`), avoiding bignum.
- `stampValue`: count leading zero bits of `Crypto.fullHash(workblock + stamp)`.
- `generateStamp`: `let wb = stampWorkblock(material: messageId); loop { let s = SecureRandom.bytes(stampSize); if stampValid(stamp: s, targetCost: targetCost, workblock: wb) { return s } }`.

**Cross-validation** (new isolated fixture `lxmf_stamp_fixtures.json` + generator): the generator builds a genuine stamped LXMessage (see Task 2) and also emits, via genuine `LXStamper`, `message_id` (= hash), `stamp`, `stamp_cost`, `workblock_hash` (= `full_hash` of the 768 KB workblock — compact, avoids a 1.5 MB hex fixture), and `stamp_value`. Tests:
1. `Crypto.fullHash(stampWorkblock(material: messageId)) == workblock_hash` — byte-parity of the deterministic workblock.
2. `stampValid(stamp, stamp_cost, wb) == true` and `stampValue(wb, stamp) == stamp_value`.
3. `generateStamp(messageId, lowCost)` (e.g. cost 4, kept cheap) returns a stamp that `stampValid(...)` accepts — our search produces valid stamps.

### Task 2 — `LXMessage` stamp inclusion (`Sources/ReTiCA/LXMF/LXMessage.swift`)

- Add stored `public let stamp: Data?` (nil = unstamped). Memberwise init gains a trailing `stamp:` (default `nil` is not possible on a `let` with the memberwise init, so `create`/`unpack` pass it explicitly; `create` sets `stamp: nil`).
- `packed`: when `stamp == nil`, the current 4-element payload (unchanged); when set, a 5-element payload `[ts, title, content, fields, .bin(stamp)]`.
- `hash` / `payloadBytes` / `validateSignature`: unchanged — always over the 4-element payload (stamp excluded).
- `func withStamp(_ stamp: Data) -> LXMessage`: returns a copy with `stamp` set (all other fields, incl. `hash`/`signature`, unchanged). This separates attachment from generation, so real use is `LXMessage.create(…).withStamp(LXStamper.generateStamp(messageId: msg.hash, targetCost: cost))`, and a test can attach a specific (reference) stamp for byte-parity.
- `unpack`: the payload may be 4 **or** 5 elements. 4 → `stamp = nil` (as now). 5 → element[4] must be `.bin(stamp)` (`stamp = stamp`), and the hash is recomputed over `msgpack(payload[:4])` (re-pack the first four elements — the reference strips the stamp the same way). Any other 5th-element shape → nil. Fields decoding (element[3]) unchanged from 5a.
- `func validateStamp(targetCost: Int) -> Bool`: `guard let stamp else { return false }; return LXStamper.stampValid(stamp: stamp, targetCost: targetCost, workblock: LXStamper.stampWorkblock(material: hash))`.

**Cross-validation** (same `lxmf_stamp_fixtures.json`): the generator emits a genuine stamped message's `source_private_key`, `destination_hash`, `timestamp`, `title`, `content`, `stamp`, `stamp_cost`, `hash`, `packed` (5-element). Tests:
1. `unpack(reference packed)` recovers a message whose `stamp == reference stamp`, `hash == reference hash`, `content` matches, `validateSignature == true`, and `validateStamp(targetCost: stamp_cost) == true` — proving our 5-element unpack + stamp validation against genuine LXMF.
2. **Byte-parity of the 5-element packing:** build the unstamped message (`create` with the reference `fields`… here fields are empty) then `withStamp(reference stamp)`; assert `packed[96:] == reference packed[96:]` (the 5-element payload region) — proving our stamp-append wire layout matches genuine LXMF exactly (deterministic, since we attach the reference's stamp).
3. Our own round-trip: `create(…).withStamp(LXStamper.generateStamp(messageId: msg.hash, targetCost: lowCost))` → `unpack(that.packed)` recovers the stamp, `hash` unchanged, `validateStamp(lowCost) == true`.

**Also in Task 2 (carried from 5a review):** fix the now-stale `unpack` doc comment (rich fields are accepted) and add a `unpack`-rejects assertion for an unrecognized 4th-element payload type.

## Deferred

- Tickets (`FIELD_TICKET`-based stamp shortcut, `COST_TICKET`) and `defer_stamp` scheduling — app-level policy.
- Propagation/peering stamps (`validate_pn_stamp`, `validate_peering_key`, `WORKBLOCK_EXPAND_ROUNDS_PN/PEERING`) → 5c.

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`). No compound shell commands; temp files in `/tmp/ReTiCA/`; a single `>` for fixture generation.
- Three-step mutation verification for every new test.
- Cross-val drives genuine LXMF / LXStamper (new isolated `lxmf_stamp_fixtures.json`; do NOT touch other fixtures). Reference env: conda `rns`. Ed25519/encryption hedged → signatures validated; the workblock/stamp/hash are deterministic and pinned. Keep our `generateStamp` test cost LOW (≤ 8) so the search + 768 KB workblock stay fast.
- New production is pure core (`LXStamper.swift`, `LXMessage.swift`); tests in `ReTiCATests`. No ReTiCANode/Transport changes.
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
