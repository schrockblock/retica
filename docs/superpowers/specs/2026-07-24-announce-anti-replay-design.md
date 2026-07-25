# Transport Relaying 4b-3a — Announce Anti-Replay (Random-Blob Dedup)

**Status:** approved (design); problem-statement corrected 2026-07-25 after reading genuine RNS
`Transport.py` — the mechanism is unchanged, but the *justification* and *tests* were made
accurate (see "Problem" and "Testing"). The original title said "+ Path-Improvement Propagation";
that framing was wrong (RNS drops same-blob copies too, so path improvement rides on *fresh*
announces, which 4b-1 already handles) and has been removed.
**Date:** 2026-07-24 (corrected 2026-07-25)
**Sub-project:** Transport relaying #4b, third sub-slice (4b-3), first piece (4b-3a).
Prior merged: 4b-1 (announce propagation + path table), 4b-2 (one-way data forwarding),
4b-2b (bidirectional links over a relay).

## Problem

Transport currently deduplicates **all** non-link inbound packets by `packetHash`
(`seenPacketHashes` RingSet, `Transport.swift:125`), a single global ring of 1000 packet hashes
shared across every destination and packet type. `packetHash` is computed over
`Packet.hashablePart` = `[destType|packetType] ‖ destHash ‖ context ‖ payload`, i.e. the whole
byte-image **except** `hops`, `transport_id`, and `header_type`.

RNS instead dedups announces by a **per-destination memory of recently-seen announce random
blobs** — the 10-byte announce `random_hash` (`RNS/Transport.py:1807`, `1824`; the list is bounded
to `MAX_RANDOM_BLOBS = 64` per destination, `Transport.py:98`). RNS's own comment states the
purpose (`Transport.py:1818-1820`): *"Make sure we haven't heard the random blob before, so
announces can't be replayed to forge paths."*

Two concrete reasons to match RNS here:

1. **Anti-replay / anti-path-forgery.** Keying dedup on the unforgeable-per-announce `random_hash`
   means a captured announce cannot be re-injected to re-assert or forge a path — even if the
   attacker mutates the non-blob bytes (`appData`, `signature`, `hops`, `transport_id`). The
   current `packetHash` dedup keys on the full payload image, so mutating `appData` or re-signing
   (Ed25519 signatures are randomised) produces a different `packetHash` and **bypasses** dedup.
2. **RNS behavioural parity + bounded per-destination memory.** Interop correctness, and 64 blobs
   *per destination* rather than a shared global 1000-entry ring that different destinations
   evict each other from.

Note on what this does **not** change: an *exact relayed copy* of an announce (payload-verbatim,
so same `random_hash`) is dropped under **both** schemes — RNS drops it too (`not random_blob in
random_blobs`). Genuine **path improvement rides on fresh announces** (new `random_hash`, newer
emission), which 4b-1 already adopts via `shouldReplace`. This slice does **not** claim to adopt a
better path from an already-seen (same-blob) announce; that is not how RNS behaves.

The code NOTE at `Transport.swift:120-124` (and the `transport-relaying` memory) flagged this as
"4b-3's random-blob anti-replay"; this slice delivers exactly that.

## Goal

Dedup announces the RNS way: a per-destination bounded ring (capacity 64) of announce random
blobs, replacing `packetHash` dedup for `.announce` only. A repeated blob for a destination is a
replay → dropped; a fresh blob is processed (path updated only when `shouldReplace`, unchanged) and
— in relay mode — **re-broadcast regardless of whether it improved the local path**. Non-announce
packets keep `packetHash` dedup unchanged. **No packet bytes change**; the re-broadcast packet is
byte-identical to 4b-1. Validated behaviourally and byte-wise against genuine RNS.

## Scope

**In scope (4b-3a):**
- Per-destination bounded ring (capacity 64 = RNS `MAX_RANDOM_BLOBS`) of announce random-blobs in
  `Transport.State`.
- Announce dedup by blob (replacing `packetHash` dedup for `.announce` only).
- Re-broadcast **every** fresh (new-blob, non-replay) announce in relay mode, subject to the
  existing hop limit — path entry updated only when `shouldReplace` (unchanged logic). This is the
  observable propagation change vs 4b-1, which re-broadcast only `shouldReplace`-improving
  announces (`return .none` otherwise).

**Explicitly out of scope (later 4b-3 sub-slices):**
- **4b-3b:** jittered/delayed re-broadcast, retransmit retries, rate-limiting. Until then a relay
  re-broadcasts fresh announces **immediately and unthrottled** — acceptable here; throttling is
  4b-3b's job.
- **4b-3c:** expiry / GC of the blob rings, the `learned` path table, and `linkTable`. The blob
  ring is bounded per destination (a fixed ring), but the **number of destinations** tracked is
  unbounded until 4b-3c, same as `learned` today.
- Any change to `.data` / `.linkRequest` dedup (they keep `packetHash` dedup unchanged).

## Design

All changes live in `Sources/ReTiCATransport/Transport.swift`. **Core `Sources/ReTiCA/*` is
untouched** — `Announce.parse` already exposes `randomHash` (10 bytes: 5 random ‖ 5 big-endian
time), and Transport already reads it (`parsed.randomHash`, used for `announceEmitted`).

### 1. Blob memory

New `Transport.State` field, a per-destination bounded ring, **reusing the existing `RingSet`**
(`Sources/ReTiCATransport/RingSet.swift`) — it is already an `Equatable` bounded, insertion-ordered
set whose `insert` returns `false` when the item is already present and evicts the oldest once over
capacity, which is exactly the blob-ring semantics. No new type is needed:

```swift
public var announceBlobs: [Data /* destinationHash */: RingSet] = [:]
```

Each destination's ring is created on first sight as `RingSet(capacity: Transport.announceBlobRingSize)`,
with a single constant:

```swift
static let announceBlobRingSize = 64   // RNS Transport.MAX_RANDOM_BLOBS (Transport.py:98)
```

**Confirmed against genuine RNS** (`Transport.py:98`, `1934-1936`): RNS keeps a per-destination list
of random_blobs trimmed to the last `MAX_RANDOM_BLOBS = 64` in memory. The count bound is a local
anti-replay-window size; it is **not** wire-visible and RNS interop does not depend on our choosing
the same number — but matching 64 keeps parity. Time-based expiry of the whole entry is 4b-3c. The
ring lives **separately** from `LearnedDestination` so blob tracking is testable in isolation and
updates even when a fresh announce does not replace the path.

### 2. The announce blob

The blob is the parsed announce's `randomHash` (`parsed.randomHash`) — the 10-byte
`5 random ‖ 5 big-endian time` value. It is per-announce-unique (5 random bytes) so distinct
announces have distinct blobs, and a replayed announce (identical payload) has an identical blob.

**Blob key confirmed against genuine RNS.** RNS extracts its `random_blob` as
`packet.data[KEYSIZE//8 + NAME_HASH_LENGTH//8 : +10]` (`Transport.py:1807`) — the 10 bytes of the
announce payload immediately after the public key and name hash, i.e. exactly the `random_hash`
that `Announce.parse` returns as `randomHash`. RNS's `timebase_from_random_blob` reads
`random_blob[5:10]` big-endian (`Transport.py:3206-3207`), matching our `announceEmitted`
(`randomHash.suffix(5)`). The cross-validation test asserts this byte-parity directly against an
RNS-generated announce, so any drift is caught.

### 3. Dedup split

Inbound `.received` handling, in order:
1. Link traffic recognised and routed **before** any dedup (unchanged).
2. **Branch by packet type before the `seenPacketHashes` guard:**
   - `.announce`: **skip** the `packetHash` guard. Parse the announce. Guard it is not one of our
     own destinations (unchanged). Take (or create) that destination's ring and
     `insert(parsed.randomHash)`: if `insert` returns `false` the blob was already present → **drop
     (replay)**, return `.none`. Otherwise the blob is fresh and now recorded → continue to announce
     processing. (Because `RingSet.insert` both tests and records in one call, the ring is written
     back to `announceBlobs[destHash]` after a fresh insert.)
   - `.data`, `.linkRequest`, and any other type: keep the existing `seenPacketHashes.insert`
     `packetHash` dedup guard exactly as today, then the existing per-type handling.

   The existing "route link before dedup" behaviour and the `.data` / `.linkRequest` relay paths
   are unchanged.

### 4. Fresh-announce processing

On a fresh (new-blob) announce:
- Compute `nextHop`, `emitted`, `candidate` as today.
- Update `state.learned[destHash]` **only if** `Transport.shouldReplace(existing, candidate)`
  (unchanged). If it does not improve the path, the path entry is left as-is — but the announce is
  still fresh, so it is still re-broadcast.
- Emit `pathLearned` when the path entry is (re)written, as today. (When the path is not replaced,
  no new `pathLearned` is emitted — matching today's "only on adopt" behaviour.)
- **Re-broadcast** in relay mode (`transportIdentity != nil`) subject to the hop limit
  (`Int(hops)+1 < maxHops`): the same HEADER_2 re-broadcast packet as 4b-1 (same payload verbatim,
  `transportType=.transport`, `transportId=our hash`, `hops+1`), to every interface except the
  arrival interface. Byte-identical to the current 4b-1 re-broadcast.

Loop protection for announces is now: (a) blob dedup — a looped-back relayed copy carries the same
blob for the same destination and is dropped as a replay; plus (b) the hop limit as a backstop.

### 5. What does NOT change

- `.data` / `.linkRequest` dedup and relay forwarding.
- The re-broadcast packet bytes.
- `shouldReplace` path-selection logic.
- `Announce` / `Packet` / any core type.
- Handling of announces for our own local destinations (still ignored — no learn, no blob track,
  no re-broadcast).

## Testing

### Unit (`Tests/ReTiCATransportTests/TransportTests.swift`)
- **Exact replay dropped:** feed an announce, then the identical announce again → second is dropped
  (no second `pathLearned`, no second re-broadcast).
- **Forge-replay dropped (the discriminator vs packetHash):** two announces for the same destination
  with the **same** `random_hash` but **different** `appData` (so a **different** `packetHash` but
  the **same** blob). The second is dropped by blob-dedup — where `packetHash`-dedup would have let
  it through. This is the test that proves the dedup is blob-keyed, and that the anti-replay cannot
  be bypassed by mutating non-blob bytes. (Mutation check: removing blob-dedup lets the second
  through → this test fails.)
- **Non-improving fresh announce still re-broadcast (the propagation change vs 4b-1):** a relay with
  a stored path to D (newer emission) receives a **fresh** announce for D with an **older** emission
  (new blob, `shouldReplace` false) → path entry unchanged (no `pathLearned`) **but** the announce
  is still re-broadcast. (Mutation check: gating re-broadcast on `shouldReplace` → no re-broadcast →
  this test fails.) Under 4b-1 this announce produced `.none` (dropped, no re-broadcast).
- **Fresh newer announce adopted + re-broadcast (sanity):** new blob, newer emission → `pathLearned`
  **and** re-broadcast (relay mode, ≥2 interfaces).
- **Blob ring bound (64):** feed 64 distinct-blob announces for one destination, then a 65th; a
  replay of the **first** (now-evicted) blob is treated as **fresh** again (processed, not dropped).
  Documents the `announceBlobRingSize == 64` bound explicitly.
- **Data dedup unchanged:** a duplicate `.data` packet to a local destination is still deduped by
  `packetHash` (regression guard — announces leaving the shared guard must not disturb it).
- **Own-destination announce ignored:** an announce for a local destination is neither blob-tracked
  nor re-broadcast (regression guard).
- **Fix the one existing casualty:** `recencyEqualEmissionPrefersFewerHops` sends two announces for
  the same destination with the same `emitted` and the same fixed random-prefix → identical blob →
  the second (better-hops) announce would now be dropped as a replay, breaking the test. It passes
  today only because randomised Ed25519 signatures give the two packets different `packetHash`es.
  Two **distinct physical announces carry distinct random blobs**, so the fix is to give the two
  announces **distinct random prefixes** (add an optional `randomPrefix` parameter to the
  `makeAnnouncePacket(identity:…)` helper, default unchanged) — with a comment explaining why.

### Cross-validation (drive real RNS — [[cross-validation-drive-real-rns]])
Extend `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py` (run under the `rns`
conda env, `[[rns-reference-env]]`) to emit, for one destination, **two genuine RNS announces with
distinct `random_hash`es** and, for each, the `random_blob` extracted by **RNS's own slice
expression** `packet.data[KEYSIZE//8 + NAME_HASH_LENGTH//8 : +10]` (`Transport.py:1807`). The Swift
cross-val test then asserts:
1. **Blob-key byte parity:** our `Announce.parse(...).randomHash` byte-equals RNS's `random_blob`
   slice for each genuine announce. This is the load-bearing check — it fails if our blob key is
   even one byte off from what RNS keys its dedup on.
2. **Dedup sequence parity:** feeding `[ann1, ann1-replay, ann2]` into a Transport yields
   accept / drop / accept (observable via `pathLearned` on ann1 and ann2, and no effect on the
   replay), matching RNS's `not random_blob in random_blobs` decision for the same sequence.

This drives genuine RNS `random_hash` generation and RNS's own offset math (non-circular per
[[cross-validation-drive-real-rns]]) rather than re-deriving the slice ourselves.

## Constraints (project-wide)

- Wire-compatible with Python-RNS 1.3.8; two-layer purity — core `Sources/ReTiCA/*` stays zero-dep
  and **untouched** by this slice.
- Commit **directly to `main`** — no feature branch ([[commit-directly-to-main]]).
- No compound shell commands; temp files under `/tmp/ReTiCA/`.
- Mutation-testing verification for every new/changed test.
- Commit trailers (exact):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```
