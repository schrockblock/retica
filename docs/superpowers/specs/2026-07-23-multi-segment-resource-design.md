# True Multi-Segment (>1MB) Resources — Design

**Status:** Approved (design phase)
**Date:** 2026-07-23
**Depends on:** the full Resource stack (6a–6c + Link/Resource integration + HMU + bzip2 compression), all merged.

## Goal

Transfer resources larger than a single-segment ceiling by splitting them into sub-resources
(segments), byte-for-byte compatible with Python-RNS 1.3.8. Bidirectional: split on send, reassemble on
receive. This finishes the Resource subsystem. It ALSO fixes a latent single-segment interop bug
(`segment_index` must be 1-based, not 0).

## Scope

**In scope**

1. Fix the base case: a single-segment resource advertises `segmentIndex = 1` (not 0), `totalSegments = 1`,
   `originalHash = hash`, `isSplit` clear.
2. Sender: `LinkSession.sendResource` splits data whose `total_size > MAX_EFFICIENT_SIZE` into segments and
   sends them sequentially (advertise segment k+1 only after segment k concludes), each a `ResourceTransfer`
   with its own hash/random/hashmap/proof/compression, sharing `originalHash = h₁`.
3. Receiver: `LinkSession` groups inbound segment transfers by `originalHash`, buffers each verified
   segment's data by `segmentIndex`, and on the last segment (`segmentIndex == totalSegments`) concatenates
   in index order and surfaces the whole once via the existing `resourceReceived` path.
4. Cross-validation against genuine RNS 1.3.8 multi-segment advertisements + reassembly.

**Explicitly deferred (out of scope)**

- Parallel/overlapping segment transfers (RNS permits overlap; we send sequentially — fully interoperable).
- Resource metadata (`x`/`has_metadata`) and file-handle streaming; our API stays in-memory `Data`.
- Any wire advertisement model change (the `i`/`l`/`o`/`isSplit` fields already exist and pack/unpack).

## Reference mechanics (Python-RNS 1.3.8, read from `RNS/Resource.py`)

- **`MAX_EFFICIENT_SIZE = 1*1024*1024 - 1 = 1,048,575`** (line 116). A resource splits when `total_size >
  MAX_EFFICIENT_SIZE`. RNS writes a large in-memory `bytes` to a temp file and segments it (lines 274–280),
  so segmenting in-memory data is faithful.
- **`total_segments = ((total_size - 1) // MAX_EFFICIENT_SIZE) + 1`** (ceil division, line 299). Segment 1
  carries the first `MAX_EFFICIENT_SIZE` bytes (minus metadata; we have none), each subsequent segment the
  next `MAX_EFFICIENT_SIZE` (lines 303–313).
- **`segment_index` is 1-based** (1..N). A single-segment resource is `segment_index = 1, total_segments =
  1, split = False` (lines 285–288, 321–323).
- **Each segment is an independent Resource**: its own `hash = full_hash(segment_uncompressed_data ‖ r_seg)`,
  own `random_hash`, own `hashmap`/parts, own bz2 compression decision, own proof. HMU applies per-segment
  (a >74-part segment uses HMU exactly as today).
- **`original_hash` (o) = the FIRST segment's hash `h₁`** (lines 445–448: segment 1 sets
  `original_hash = self.hash`; `__prepare_next_segment` passes it to later segments, lines 769–772). Carried
  in every segment's ADV; it is the receiver's grouping key.
- **Advertisement field mapping** (lines 1281–1293): `t = resource.size` (this segment's transfer/stream
  size), **`d = resource.total_size` (the WHOLE resource's uncompressed size — the same value in every
  segment's ADV)**, `n` = this segment's part count, `h` = this segment's hash, `r` = this segment's random,
  `o` = `h₁`, `i` = segment_index (1-based), `l` = total_segments, `s` = split. Flag byte
  `f = x<<5 | p<<4 | u<<3 | s<<2 | c<<1 | e` (line 1307) — `isSplit` is bit 2 (`0x04`).
- **Sequential send**: RNS advertises the next segment only after the current segment's transfer concludes
  (`__prepare_next_segment` is triggered on conclusion; the watchdog completes the whole only when
  `segment_index == total_segments`, lines 1130/1184).
- **Receiver assembly** (lines 694–749): each segment is verified (`full_hash(decompressed ‖ r) == h`),
  appended to a file keyed by `original_hash.hex()` (append mode), and its own proof is sent. The whole is
  delivered (callback) ONLY when `segment_index == total_segments`; otherwise it waits for the next segment.
  The whole is the plain concatenation of segment datas in index order — there is NO hash of the whole; each
  segment is verified independently and the concatenation is trusted.

## Current state (what exists / what's missing)

- `ResourceAdvertisement` already has `segmentIndex`/`totalSegments`/`originalHash` fields + `isSplit` (bit 2)
  accessor; pack/unpack are correct. **No change.**
- `ResourceTransfer.init(sending:)` hard-codes `segmentIndex: 0, totalSegments: 1, originalHash: h` and never
  sets `isSplit`. The `0` is the latent bug. `dataSize = data.count` (fine for single-segment where
  segment size == total size).
- The receiver ignores `segmentIndex`/`totalSegments`/`originalHash`/`isSplit` and delivers each transfer's
  data as one blob. Decompression uses `adv.dataSize` as the decompressed size.
- `LinkSession` hosts `transfers: IdentifiedArrayOf<...>`, dedups inbound ADVs by `adv.hash`, and surfaces
  `resourceReceived`/`resourceConcluded`/`resourceFailed` per transfer. No grouping by `originalHash`. No
  `MAX_EFFICIENT_SIZE` constant exists.

## Architecture

Segment splitting/coordination lives in `ReTiCATransport`. The `ReTiCA` core is unchanged. `Endpoint` is
unchanged (a multi-segment receive still surfaces one `resourceReceived(linkID:data:)`).

### `ResourceTransfer.init(sending:)` — segment parameters (`Sources/ReTiCATransport/ResourceTransfer.swift`)

Add three defaulted parameters:
```
init(sending data: Data, …, segmentIndex: UInt64 = 1, totalSegments: UInt64 = 1,
     originalHash: Data? = nil, totalDataSize: UInt64? = nil, …)
```
- `hash h = resourceHash(data)` (this segment's data; unchanged).
- `advertisement.segmentIndex = segmentIndex` (default **1**), `totalSegments = totalSegments` (default 1),
  `originalHash = originalHash ?? h` (segment 1 / single → its own hash), `dataSize = totalDataSize ??
  UInt64(data.count)` (whole size; default = this data's size for single-segment).
- `advFlags` gains `| (totalSegments > 1 ? 0x04 : 0)` (isSplit).
- `transferSize = stream.count` (this segment's encrypted stream — unchanged).

The default arguments make every EXISTING `sending:` call site produce the now-correct single-segment ADV
(`i=1, l=1, o=h, isSplit clear`) — the interop fix.

### `LinkSession` sender coordinator (`Sources/ReTiCATransport/LinkSession.swift`)

New `static let maxEfficientSize = 1_048_575`. New State to track a segmented send:
`sendSegments: [Data]` (the split payloads), `segmentCursor: Int`, `originalHash: Data?`,
`totalDataSize: UInt64`, and the current segment's transfer id — grouped in a small `SegmentedSend?` value.

`.sendResource(data)`:
- If `data.count <= maxEfficientSize` → today's single path (now with the default `i=1`).
- Else → split into `N = ceil(data.count / maxEfficientSize)` chunks of `maxEfficientSize` (last is the
  remainder). Build segment 1's `ResourceTransfer(sending: chunk0, segmentIndex: 1, totalSegments: N,
  originalHash: nil, totalDataSize: data.count)`, record `originalHash = segment1.resourceHash`, store the
  remaining chunks + cursor, and `.advertise` segment 1.
- On a hosted **sender** transfer's `.concluded` that belongs to a `SegmentedSend` with more chunks: build
  the next segment `ResourceTransfer(sending: chunk_k, segmentIndex: k+1, totalSegments: N, originalHash:
  originalHash, totalDataSize: data.count)`, `.advertise` it. When the last segment concludes, surface
  `resourceConcluded(originalHash)` once and clear the `SegmentedSend`. (Single-segment: unchanged, concludes
  immediately.)

### `LinkSession` receiver accumulator (`Sources/ReTiCATransport/LinkSession.swift`)

- **ADV-spawn** already spawns a receiver per inbound ADV. Change the dedup/spawn to also record the ADV's
  `originalHash`, `segmentIndex`, `totalSegments`, `isSplit` on the transfer (via the stored
  `advertisement`). Dedup still by `adv.hash` (each segment has a distinct hash, so each spawns its own
  transfer — correct).
- New State: `incomingSegments: [Data: SegmentAccumulator]` keyed by `originalHash`, where
  `SegmentAccumulator = { total: UInt64, parts: [UInt64: Data] }`.
- **Terminal interception** — when a hosted receiver transfer completes (`.received(payload)`), read its
  stored `advertisement`:
  - `isSplit == false` (single segment) → surface `resourceReceived(payload)` as today.
  - `isSplit == true` → buffer `parts[segmentIndex] = payload` under `originalHash`, learning `total` from
    `totalSegments`. If `parts.count == total` (have all 1..N) → concatenate `parts[1], parts[2], …,
    parts[N]` in index order → surface `resourceReceived(whole)` once + remove the accumulator; else `.none`
    (wait for the next segment). Each segment still sends its own proof (unchanged transfer behavior).
  - `.concluded`/`.failed`: a split segment's `.concluded` is internal (surface `resourceConcluded` only on
    the whole — i.e. when the accumulator completes, or piggyback on the last segment); a split segment's
    `.failed` fails the whole (`resourceFailed(originalHash)` + drop the accumulator).

### Receiver decompression sizing

Per-segment decompression currently uses `adv.dataSize` (= whole size for a split resource). Since a segment
never exceeds `maxEfficientSize` uncompressed, decompress with `expectedSize = min(Int(adv.dataSize),
Self.maxEfficientSize + slack)` to avoid over-allocating a whole-resource-sized buffer per segment. (Bzip2
trims to the actual output, so correctness is unaffected — this is only an allocation cap.)

## Data flow (2-segment round-trip)

1. `sendResource(3 MB)` → `N = ceil(3_145_728 / 1_048_575) = 3` segments (1_048_575, 1_048_575, 1_048_578).
   Build segment 1 → `h₁`, `originalHash = h₁`; advertise seg 1 (`i=1, l=3, o=h₁, d=3_145_728, isSplit`).
2. Receiver spawns a transfer for seg 1, downloads it, verifies against `h₁`, buffers `parts[1]`, proves it;
   `parts.count(1) < 3` → waits.
3. Seg 1 concludes at sender → build + advertise seg 2 (`i=2, l=3, o=h₁`). … seg 3 (`i=3`).
4. On seg 3 (`i == l`), receiver has parts {1,2,3} → concatenate → `resourceReceived(3 MB whole)` once.
   Sender surfaces `resourceConcluded(h₁)` once.

## Error handling / edge cases

- **A segment fails** (verify/timeout/cancel) → the whole fails: `resourceFailed(originalHash)`, drop the
  accumulator; sender aborts the `SegmentedSend`.
- **Out-of-order / duplicate segment ADV**: buffered by `segmentIndex` (a map), so idempotent; a duplicate
  segment hash is deduped at spawn.
- **`data.count == 0` / exactly `maxEfficientSize`**: `<=` keeps it single-segment (`i=1`). One byte over →
  2 segments.
- **Compression interplay**: per-segment (unchanged) — each segment independently compresses; `d` is the
  whole uncompressed size, but per-segment verify uses `h` over that segment's uncompressed data.
- **Memory**: the whole resource is buffered in memory on both ends (our `Data` API) — acceptable and
  already true for single resources; noted as a known constraint (RNS streams to a file).

## Testing

- **Base-case fix:** a single-segment `ResourceTransfer` advertises `segmentIndex == 1`, `totalSegments ==
  1`, `originalHash == hash`, `isSplit == false`. (Update existing fixtures/tests that asserted `i == 0`.)
- **Sender split:** `sendResource` of `> maxEfficientSize` data produces `N = ceil(size/max)` sequential
  segments with `i = 1..N`, shared `originalHash = h₁`, `l = N`, `isSplit` set, `d = whole size`; segment
  k+1 is advertised only after segment k concludes.
- **Receiver reassembly:** feeding N segment transfers (grouped by `originalHash`) surfaces exactly one
  `resourceReceived(whole)` equal to the concatenation, only after the last segment; a mid-stream segment
  failure surfaces one `resourceFailed(originalHash)`.
- **End-to-end (two Endpoints):** round-trip a `> maxEfficientSize` resource over a live link — B receives
  the exact multi-MB original as one `resourceReceived`. (Use a modest over-threshold size for test speed,
  e.g. `maxEfficientSize + a few KB` → 2 segments; a highly-compressible payload keeps part counts sane.)
- **Cross-validation (genuine RNS):** generate genuine RNS multi-segment advertisements (drive a real
  `RNS.Resource` over a mock/loopback, or construct segment `ResourceAdvertisement`s with the reference
  field values) and assert our packed segment ADVs match byte-for-byte (`i`/`l`/`o`/`d`/`isSplit`), and that
  our reassembly of a genuine RNS segment set yields the original. Reuse the existing resource cross-val
  harness.
- Every new/changed test is mutation-swept. Committed directly to `main`.

## Known simplifications (carry to review)

- Sequential (not parallel) segments; whole resource buffered in memory; no metadata/file-streaming.
- The whole is verified per-segment (RNS-faithful) — there is no end-to-end hash of the concatenation.
- `maxEfficientSize = 1_048_575` matches RNS exactly, so our segment boundaries/counts are byte-identical.
- The single-segment `i = 0 → 1` change is a real interop fix; existing i=0 fixtures/tests are updated to the
  correct RNS value (they were circular on that field).
