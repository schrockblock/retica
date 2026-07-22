# Resource Hashmap-Update (HMU) — Design

**Status:** Approved (design phase)
**Date:** 2026-07-21
**Depends on:** 6a (Resource primitives + MsgPack), 6b (ResourceTransfer), 6c (windowing/retransmit/cancellation), Link↔Resource integration (LinkSession hosts transfers).

## Goal

Transfer resources that exceed `HASHMAP_MAX_LEN` = **74 parts** (~34 KB at SDU 464) in a single
`ResourceTransfer`, up to ~1 MB, by delivering the part-hashmap **incrementally**. The advertisement
carries only the first 74 map-hashes; the receiver requests further map-hashes on demand via
`RESOURCE_HMU` (0x04) as it exhausts the hashmap it knows. Byte-for-byte wire-compatible with
Python-RNS 1.3.8.

## Scope

**In scope** — single-transfer hashmap-update within one `ResourceTransfer`:

1. Advertisement `m` field capped at the first `min(74, numberOfParts)` map-hashes (currently the whole
   hashmap is emitted — wrong for >74 parts, but never exercised until now).
2. Receiver maintains a **growing** hashmap and requests more via an exhausted-flagged `RESOURCE_REQ`.
3. Sender detects the exhausted flag, serves the requested parts, and replies with the next 74-hash
   `RESOURCE_HMU` chunk.
4. Receiver ingests the HMU, extends its hashmap, and continues the windowed pull.
5. `MsgPack` array support (needed for the HMU payload) + the `RESOURCE_HMU` context wired into
   `ResourceTransfer` and `LinkSession` routing.

**Explicitly deferred (out of scope)**

- True multi-segment (>1 MB): whole-resource segmentation into sub-resources
  (`segmentIndex`/`totalSegments`/`originalHash`/`isSplit`), with a reassembly coordinator. In RNS this
  only triggers for file-handle inputs (an in-memory `bytes`/`Data` blob is always a single segment);
  our public API is in-memory `Data`, so this is a distinct later slice.
- Compression (6e); metadata (`has_metadata`); request/response resource flags (`is_request`/`is_response`).
- RNS's `receiver_min_consecutive_height` sliding search-floor optimization on the sender (our sender
  scans the full `partMapHashes` array; noted simplification, no wire impact).

## Reference mechanics (Python-RNS 1.3.8, verbatim intent)

- `HASHMAP_MAX_LEN = floor((Link.MDU 431 − OVERHEAD 134) / MAPHASH_LEN 4) = 74`.
- The receiver's hashmap is conceptually `[None] * total_parts`; the advertisement fills slots
  `[0 .. min(74, n)−1]`; `hashmap_height` counts filled slots (contiguous, since HMU delivers
  contiguous 74-chunks).
- `request_next` (receiver): scan `window` slots from `consecutive_completed_height + 1`; for each
  missing part whose map-hash is known, request it; on the first missing part whose map-hash is
  **unknown**, set `hashmap_exhausted = 0xFF`, append `last_map_hash = hashmap[hashmap_height−1]`, set
  `waiting_for_hmu = True`, and stop.
- `request` (sender): `wants_more_hashmap = (request_data[0] == 0xFF)`; `pad = 5` if so else `1`;
  requested hashes at `request_data[pad + 32:]`. Serve requested parts. If `wants_more_hashmap`: find
  the part index of `last_map_hash`; require `part_index % 74 == 0` (else cancel); `segment =
  part_index // 74`; HMU payload = `hash ‖ umsgpack([segment, hashmap_chunk])` where `hashmap_chunk` =
  map-hashes for parts `[segment·74 .. min((segment+1)·74, N))`.
- `hashmap_update` (receiver): unpack `[segment, hashmap]`, write into `hashmap[segment·74 ..]`, bump
  `hashmap_height`, clear `waiting_for_hmu`, `request_next()` again.
- All resource-management packets (ADV, REQ, HMU, ICL, RCL) are `.data` packet type, **encrypted** with
  the link key; RESOURCE parts and RESOURCE_PRF are plaintext.

## Wire formats (the three new/changed byte layouts)

**Advertisement `m` (RESOURCE_ADV):** the first `min(74, numberOfParts)` map-hashes only
(`min(74,n)·4` bytes). `n` remains the full part count. (≤74 parts → unchanged: `min(74,n)==n`.)

**RESOURCE_REQ, not exhausted (unchanged):**
```
0x00 ‖ resourceHash(32) ‖ requested-map-hashes(N·4, N ≤ window)
```

**RESOURCE_REQ, exhausted (new):**
```
0xFF ‖ last_known_map_hash(4) ‖ resourceHash(32) ‖ requested-map-hashes(N·4, N may be 0)
```
`last_known_map_hash = knownHashmap[hashmapHeight−1]`.

**RESOURCE_HMU (new):** context `.resourceHashmapUpdate` (0x04), packetType `.data`, encrypted, dest
`.link`:
```
resourceHash(32) ‖ MsgPack([ chunkIndex: UInt, hashmap_bytes: bin ])
```
`chunkIndex = part_index / 74`; `hashmap_bytes` = map-hashes for parts `[chunkIndex·74 ..
min((chunkIndex+1)·74, N))`.

## Architecture

### Pure core (`ReTiCA`)

- **`Sources/ReTiCA/Support/MsgPack.swift`** — add `case array([MsgPackValue])` to `MsgPackValue`;
  `encode` emits fixarray `0x90|n` (n ≤ 15) / `array16 0xDC` / `array32 0xDD`; `decodeValue` parses
  them. Cross-validated against genuine `umsgpack`.
- **`Sources/ReTiCA/Resource/Resource.swift`:**
  - `public static let hashmapMaxLen = 74` (documented derivation; a cross-val test asserts it equals
    RNS's computed value).
  - `nextWindowRequest` return becomes `(indices: [Int], mapHashes: Data, exhausted: Bool)`. During the
    window scan, a **missing** part whose slot index ≥ the known-hashmap slot count
    (`hashmap.count / mapHashLength`) sets `exhausted = true` and stops the scan. Full-hashmap callers
    (≤74 parts, or all chunks received) always get `exhausted == false` — backward compatible. The one
    6c call site and its 4 core tests update to the 3-tuple.

### Transport (`ReTiCATransport`)

- **`ResourceTransfer.swift`:**
  - **Sender:** `init(sending:)` keeps full `partMapHashes`/`parts`; the advertisement's `hashmap` =
    first `min(74, count)` map-hashes. The `.resourceRequest` handler parses the flag byte (`pad = 5`
    if `0xFF` else `1`), serves requested parts, and on exhaustion emits `RESOURCE_HMU` (74-boundary
    check → `.failed` + ICL on violation).
  - **Receiver:** new State `knownHashmap: Data`, `hashmapHeight: Int`, `waitingForHMU: Bool`.
    `.accept` seeds them from the ADV. `requestNextWindow` scans `knownHashmap`; on `exhausted`, emits
    the `0xFF` REQ and sets `waitingForHMU` (a part-completed round does not fire a fresh REQ while
    waiting; the retransmit watchdog recovers a lost HMU). New inbound case
    `(.receiver, .data, .resourceHashmapUpdate)`: decrypt, verify hash prefix, `MsgPack`-decode
    `[chunkIndex, bytes]`, splice into `knownHashmap` at `chunkIndex·74·4`, bump `hashmapHeight`, clear
    `waitingForHMU`, `requestNextWindow`. Part-placement scans `knownHashmap`.
- **`LinkSession.swift`:** add `(_, .active, .data, .resourceHashmapUpdate)` to the existing
  broadcast-to-transfers routing case (one line).

## State additions (`ResourceTransfer.State`, receiver)

- `knownHashmap: Data` — the growing hashmap; `= adv.hashmap` on accept, extended by each HMU.
- `hashmapHeight: Int` — count of known contiguous map-hashes (`knownHashmap.count / mapHashLength`).
- `waitingForHMU: Bool` — set when an exhausted REQ is outstanding; cleared on HMU receipt.

The sender needs no new persistent fields (it already holds the complete `partMapHashes`).

## Data flow (HMU round)

1. Sender advertises with `m` = first 74 map-hashes; `n` = full count.
2. Receiver `.accept` → `knownHashmap` = those 74; `hashmapHeight = 74`.
3. Receiver windows through the first 74 parts; when the window scan reaches part 74 (unknown slot),
   `nextWindowRequest` returns `exhausted`; receiver sends `0xFF ‖ knownHashmap[73·4..74·4] ‖ hash ‖
   (any still-missing known parts)`, sets `waitingForHMU`.
4. Sender serves the requested parts, then (74-boundary OK) sends `RESOURCE_HMU` for chunk 1 (parts
   74..147).
5. Receiver splices the chunk into `knownHashmap` (`hashmapHeight = 148`), clears `waitingForHMU`, and
   continues requesting. Repeat until all parts are known and received.
6. Assemble + verify + `RESOURCE_PRF`, exactly as 6b/6c (unchanged completion path).

## Error handling

- Sender 74-boundary violation (`part_index % 74 != 0`) → `.failed` + `RESOURCE_ICL` (matches RNS's
  "sequencing error, cancelling transfer").
- Lost HMU → the existing retransmit watchdog re-sends the exhausted REQ on timeout (no dedicated HMU
  timer).
- Malformed HMU (hash-prefix mismatch, undecodable msgpack, or a chunk that doesn't extend the hashmap
  contiguously) → ignored (`.none`).
- A part whose map-hash isn't yet known is dropped by the placement guard (shouldn't occur — the
  receiver only requests known parts).

## Testing

- **Core:** `MsgPack` `.array` round-trip and cross-validation against genuine `umsgpack` for
  `[UInt, bin]`; `Resource.hashmapMaxLen == 74`; `nextWindowRequest` exhausted detection (partial
  hashmap → `exhausted` at the boundary and stops; full hashmap → never exhausted; the 6c behaviors
  preserved).
- **Sender (`ResourceTransfer`):** a >74-part `init(sending:)` produces an advertisement whose `m` is
  exactly `74·4` bytes with `n` the full count; an inbound `0xFF` REQ serves the requested parts **and**
  emits a `RESOURCE_HMU` carrying the correct `chunkIndex` and the next ≤74 hashes; a `last_map_hash`
  that isn't on a 74-boundary yields `.failed` + ICL.
- **Receiver:** exhaustion emits the `0xFF` REQ with the correct `last_known_map_hash`; ingesting an HMU
  extends `knownHashmap`/`hashmapHeight` and resumes requesting; `waitingForHMU` suppresses a premature
  normal REQ.
- **E2E:** a two-reducer transfer of a **>74-part** resource (≈120 parts → two HMU rounds) completes
  with the receiver reconstructing the exact original bytes and the sender concluding.
- Cross-validation: the HMU msgpack payload against genuine `umsgpack`; no other new wire fixture is
  required (the exhausted-REQ layout is plain concatenation; the part/PRF/ADV formats are unchanged and
  already validated in 6a–6c).
- Every new/changed test is mutation-swept per the project's discipline.

## Known simplifications (carry to review)

- We omit RNS's `receiver_min_consecutive_height` sliding search floor — the sender matches requested
  map-hashes against the full `partMapHashes` array. No wire impact; slightly less efficient for very
  large resources.
- `hashmapHeight` is treated as the contiguous known-count (valid because HMU delivers contiguous
  74-chunks in order); we do not model the sparse `[None]`-list form.
- Constant SDU (464) and single-segment only (≤ ~1 MB / `MAX_EFFICIENT_SIZE`); >1 MB multi-segment is a
  separate slice.
