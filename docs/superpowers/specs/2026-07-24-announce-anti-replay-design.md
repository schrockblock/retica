# Transport Relaying 4b-3a — Announce Anti-Replay + Path-Improvement Propagation

**Status:** approved (design)
**Date:** 2026-07-24
**Sub-project:** Transport relaying #4b, third sub-slice (4b-3), first piece (4b-3a).
Prior merged: 4b-1 (announce propagation + path table), 4b-2 (one-way data forwarding),
4b-2b (bidirectional links over a relay).

## Problem

Transport currently deduplicates **all** non-link inbound packets by `packetHash`
(`seenPacketHashes` RingSet, `Transport.swift:125`). But `packetHash` is computed over
`Packet.hashablePart`, which **excludes** `hops` and `transport_id`. So a relayed announce
(HEADER_2, our `transport_id`, `hops+1`) shares the **same** packet hash as the original
HEADER_1 announce. Consequences on any node that already heard the original:

1. The relayed copy is dropped as a "duplicate," so a **relay-improved path** (fewer hops via
   a better next hop) for an already-seen destination is **never adopted or propagated**.
2. A destination's periodic **re-announce** (a fresh announce carrying a new random hash but the
   same reachable path) is dropped after the first hop, so the mesh does not stay fresh.

This is the gotcha flagged in the code NOTE at `Transport.swift:120-124` and in the
`transport-relaying` memory.

RNS solves this by deduping announces **not** by packet hash but by a per-destination memory of
recently-seen announce *random blobs* (`Transport.destination_table` random_blobs, RNS
`Transport.py`). A repeated blob for a destination is a replay and is dropped; a new blob is a
fresh announce and is processed (path updated if better) and re-broadcast.

## Goal

Make the Swift Transport dedup announces the RNS way: a per-destination bounded ring of
random-blobs. Replays drop; every fresh announce — including a relay-improved path for an
already-seen destination — is processed and (in relay mode) re-broadcast. **No packet bytes
change**; the re-broadcast packet is byte-identical to 4b-1. This is a mesh-behaviour /
correctness fix, validated behaviourally against genuine RNS.

## Scope

**In scope (4b-3a):**
- Per-destination bounded ring of announce random-blobs in `Transport.State`.
- Announce dedup by blob (replacing `packetHash` dedup for `.announce` only).
- Re-broadcast **every** fresh (new-blob, non-replay) announce in relay mode, subject to the
  existing hop limit — path entry updated only when `shouldReplace` (unchanged logic).

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

New `Transport.State` field, a per-destination bounded ring:

```
public var announceBlobs: [Data /* destinationHash */: BlobRing] = [:]
```

`BlobRing` is a small bounded FIFO of recent blobs (Equatable, Sendable) with:
- `contains(_ blob: Data) -> Bool`
- `mutating func insert(_ blob: Data)` — appends; evicts oldest when over capacity.

Capacity is a single constant `announceBlobRingSize`. Its value is confirmed against genuine RNS
`destination_table` random_blobs retention at plan time; if RNS's retention is time-bounded rather
than count-bounded, use a small fixed count here (the count bound is a 4b-3a stand-in; precise
time-based expiry is 4b-3c). The ring lives **separately** from `LearnedDestination` so blob
tracking is testable in isolation and updates even when a fresh announce does not replace the path.

### 2. The announce blob

The blob is the parsed announce's `randomHash` (`parsed.randomHash`). It is per-announce-unique
(contains 5 random bytes) so distinct announces have distinct blobs, and a replayed announce
(identical payload) has an identical blob.

**Load-bearing fidelity assumption:** RNS must key its `destination_table` random_blobs on this
same value. The exact RNS blob key (the full 10-byte `random_hash`, a slice of it, or a hash of
announce fields) is confirmed by reading genuine RNS `Transport.py` at plan time; if it differs,
this section is corrected before implementation. The cross-validation test (below) is the backstop
— it drives real RNS and fails if our blob key produces a different accept/drop decision than RNS.

### 3. Dedup split

Inbound `.received` handling, in order:
1. Link traffic recognised and routed **before** any dedup (unchanged).
2. **Branch by packet type before the `seenPacketHashes` guard:**
   - `.announce`: **skip** the `packetHash` guard. Parse the announce. Guard it is not one of our
     own destinations (unchanged). Compute `blob = parsed.randomHash`. If
     `announceBlobs[destHash]?.contains(blob) == true` → **drop (replay)**, return `.none`. Else
     insert the blob into that destination's ring (creating the ring if absent), then continue to
     announce processing.
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
- **Replay dropped:** feed an announce, then the identical announce again → second is dropped (no
  second `pathLearned`, no second re-broadcast).
- **Fresh re-announce processed:** same destination + same reachable path but a **new** random hash
  → processed and re-broadcast (this is the case 4b-1 dropped via packetHash).
- **Relay-improved path adopted + propagated:** announce dest via a 3-hop path, then a fresh
  announce for the same dest via a 1-hop path → path replaced (`pathLearned`) and re-broadcast,
  where 4b-1 would have dropped it.
- **Non-improving fresh announce:** fresh blob, worse/equal path → still re-broadcast, path entry
  unchanged (no `pathLearned`).
- **Blob ring bound:** after more than `announceBlobRingSize` distinct blobs for one destination,
  the oldest blob is evicted (a replay of a long-since-evicted blob is no longer recognised as a
  replay). Documents the bound explicitly.
- **Data/linkRequest dedup unchanged:** a duplicate `.data` packet is still deduped by packetHash
  (regression guard).
- **Own-destination announce ignored:** an announce for a local destination is neither blob-tracked
  nor re-broadcast (regression guard).

### Cross-validation (drive real RNS — [[cross-validation-drive-real-rns]])
A fixture generated by **genuine RNS code** (not hand-rolled) produces an announce sequence for one
destination — original, exact replay, improved-path re-announce, fresh-same-path re-announce — and
records RNS's own accept/drop decision for each. The Swift test feeds the same raw announce bytes
into a Transport and asserts our accept/drop/re-broadcast decision matches RNS's for every element
of the sequence. This proves the blob-dedup semantics match RNS behaviourally, not just that our
code is internally consistent.

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
