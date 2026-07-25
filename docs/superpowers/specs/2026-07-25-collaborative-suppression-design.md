# Transport Relaying 4b-3b-3 — Collaborative Announce Suppression

**Status:** approved (design)
**Date:** 2026-07-25
**Sub-project:** Transport relaying #4b, third sub-slice (4b-3), second piece (4b-3b), final part (3 of 3).
Prior merged: 4b-1, 4b-2, 4b-2b, 4b-3a (anti-replay), 4b-3b-1 (jittered send), 4b-3b-2 (retries+grace).

## Problem

4b-3b-2 re-broadcasts a held announce twice (initial jittered send, then one retry after a fixed
grace). In a dense mesh many relays hold the same announce and all retry it, producing redundant
re-broadcasts. RNS suppresses this: while a re-broadcast is pending, if it **hears neighbours
re-broadcast the same announce** enough times, it **cancels its own pending retry** — the announce
is already propagating, so no further tries are needed (`Transport.py:1774-1791`).

## Goal

Cancel our pending announce **retry** when we hear the announce being re-broadcast by peers or passed
on downstream, matching RNS's `LOCAL_REBROADCASTS_MAX`-gated suppression. This reduces redundant
announce traffic without dropping propagation reliability (the initial send is never suppressed).
No packet bytes change; path learning and the re-broadcast are unchanged.

## Key insight — suppression lives in the blob-dedup *replay* branch

A peer's (or downstream node's) re-broadcast of the announce we are holding carries the **same
payload → same `random_hash` → same blob**, so to us it is exactly a 4b-3a blob-dedup **replay**.
RNS runs its suppression check *before* the random_blob dedup (`Transport.py:1774` precedes the
`random_blob in random_blobs` check at `:1824`); for us that is the same location — the replay
branch, which today simply `return .none`. **The fresh-announce path is not restructured at all** —
only the replay branch is enriched.

## RNS grounding (Transport.py:1774-1791) and the hop arithmetic

RNS increments inbound `packet.hops` once (`:1491`) before the suppression check, and stores
`IDX_AT_HOPS = announce_hops` (the post-increment arrival hops = wire_arrival + 1). Its conditions:
- **Peer** (`:1777`): `packet.hops - 1 == IDX_AT_HOPS` → increment `IDX_AT_LCL_RBRD`; pop if
  `IDX_AT_RETRIES > 0` **and** `IDX_AT_LCL_RBRD >= LOCAL_REBROADCASTS_MAX`.
- **Downstream** (`:1786`): `packet.hops - 1 == IDX_AT_HOPS + 1` and `IDX_AT_RETRIES > 0` (and before
  the next retry timeout) → pop.

ReTiCA does **not** pre-increment inbound hops (our `packet.hops` is the wire value as received), and
we already store the re-broadcast's hops (`= arrival_wire + 1`). Translating RNS's arithmetic to our
convention, the equivalents are:
- **Peer:** the heard re-broadcast's `packet.hops == rebroadcastHops` (our re-broadcast's hops).
- **Downstream:** `packet.hops == rebroadcastHops + 1`.

The hops-match is anchored by the existing byte-validated re-broadcast (`relayRebroadcastsGenuineRns
AnnounceCorrectly`): a re-broadcast of an announce heard at wire hops `H` carries hops `H+1`, so a
peer that heard the same original at `H` emits `H+1 == rebroadcastHops`, and a downstream node that
heard our `H+1` emits `H+2 == rebroadcastHops + 1`.

## Design

All changes in `Sources/ReTiCATransport/Transport.swift`. Core `Sources/ReTiCA/*` untouched. Builds
on 4b-3b-2's `announceTable`, `PendingAnnounce`, `announceMaxRebroadcasts`,
`CancelID.announceRetransmit`.

### 1. `PendingAnnounce` gains two fields

```swift
public struct PendingAnnounce: Equatable, Sendable {
    public var raw: Data
    public var arrivalInterface: InterfaceID
    public var rebroadcasts: Int
    public var rebroadcastHops: UInt8     // hops our re-broadcast carries (= arrival packet.hops + 1)
    public var localRebroadcasts: Int     // count of heard peer re-broadcasts (RNS IDX_AT_LCL_RBRD)
    public init(raw: Data, arrivalInterface: InterfaceID, rebroadcastHops: UInt8,
                rebroadcasts: Int = 0, localRebroadcasts: Int = 0) {
        self.raw = raw; self.arrivalInterface = arrivalInterface
        self.rebroadcastHops = rebroadcastHops
        self.rebroadcasts = rebroadcasts; self.localRebroadcasts = localRebroadcasts
    }
}
```

At the `.announce` scheduling site, the initializer now passes `rebroadcastHops: packet.hops + 1`
(the hops already baked into the built re-broadcast `raw`). Everything else at that site is unchanged.

### 2. Suppression in the replay branch

The blob-dedup guard currently reads `guard ring.insert(parsed.randomHash) else { return .none }`.
Replace the `else` body with a suppression check (a nested helper keeps the switch readable):

```swift
guard ring.insert(parsed.randomHash) else {
    // REPLAY. A peer/downstream re-broadcast of an announce we are holding is a same-blob replay.
    // Collaborative suppression: cancel our pending RETRY once neighbours have propagated it.
    guard var entry = state.announceTable[packet.destinationHash],
          packet.transportId != nil                       // HEADER_2 re-broadcast (RNS transport_id != None)
    else { return .none }
    if packet.hops == entry.rebroadcastHops {             // a peer re-broadcast of the same announce
        entry.localRebroadcasts += 1                       // count always (RNS increments unconditionally)
        if entry.rebroadcasts >= 1,                        // a retry is pending (RNS IDX_AT_RETRIES > 0)
           entry.localRebroadcasts >= Transport.announceMaxRebroadcasts {
            state.announceTable[packet.destinationHash] = nil
            return .cancel(id: CancelID.announceRetransmit(packet.destinationHash))
        }
        state.announceTable[packet.destinationHash] = entry
        return .none
    }
    if packet.hops == entry.rebroadcastHops + 1, entry.rebroadcasts >= 1 {   // our re-broadcast passed on
        state.announceTable[packet.destinationHash] = nil
        return .cancel(id: CancelID.announceRetransmit(packet.destinationHash))
    }
    return .none
}
state.announceBlobs[packet.destinationHash] = ring
```

Notes:
- The `.cancel(id:)` tears down the sleeping retry timer (both faithful to RNS's pop and clean for
  TestStore, which would otherwise flag a lingering in-flight effect).
- Removing the `announceTable` entry alone would already make the pending timer a no-op when it fires
  (the handler's `guard let entry else { return .none }`), but we cancel explicitly for hygiene.
- The count increments even when `rebroadcasts == 0` (initial jitter window), matching RNS; only the
  **cancellation** is gated on `rebroadcasts >= 1`, so the **initial send is never suppressed**.

### 3. What does NOT change

- The fresh-announce path (own-dest guard, parse, path update, `pathLearned`, the 3-condition
  schedule guard, the re-broadcast bytes) — untouched; only the blob-dedup `else` (replay) body and
  the `PendingAnnounce` initializer call change.
- The retry lifecycle (2 sends, fixed grace), the jitter window, `.data`/`.linkRequest` handling.

## Scope

**In scope (4b-3b-3):** `PendingAnnounce.rebroadcastHops` + `localRebroadcasts`; the replay-branch
suppression (peer count + cap-cancel; downstream cancel); behavioral unit tests.

**Out of scope:** any new RNS fixture (see cross-validation); timer cancellation on
interface-disconnect / identity-clear and table expiry/GC (**4b-3c**); path-request handling (#4c).

## Testing

### Unit (`Tests/ReTiCATransportTests/TransportTests.swift`), TestClock
- **Peer re-broadcasts cancel the retry at the cap:** relay holds an announce; advance past jitter so
  send #1 fires (`rebroadcasts == 1`, retry pending). Feed a HEADER_2 peer re-broadcast (same payload,
  `hops == rebroadcastHops`) → `localRebroadcasts == 1`, entry still present, no cancel. Feed a second
  → entry removed; advancing past the grace fires **no** retry (the retry was cancelled).
- **Downstream re-broadcast cancels immediately:** after send #1, one HEADER_2 packet with
  `hops == rebroadcastHops + 1` → entry removed, no retry.
- **No suppression before the first send:** during the initial jitter window (`rebroadcasts == 0`),
  two peer re-broadcasts increment `localRebroadcasts` but do NOT cancel; send #1 still fires.
- **Non-matching hops do nothing:** a same-blob HEADER_2 replay with `hops` neither `rebroadcastHops`
  nor `+1` leaves the entry and the retry intact.
- **HEADER_1 replay / no pending entry:** a replay with `transportId == nil`, or for a dest with no
  `announceTable` entry, is `.none` (unchanged) and does not crash.
- **Regression:** the 4b-3a exact-replay/forge-replay drop tests still pass (a replay with no pending
  retry entry still drops silently).

### Cross-validation
Behavioral unit tests only (user-approved). The load-bearing constant `LOCAL_REBROADCASTS_MAX (2)` is
already cross-validated against genuine RNS (4b-3b-2, `announceMaxRebroadcasts`), and the re-broadcast
hop arithmetic (`rebroadcastHops == arrival + 1`) is already byte-validated
(`relayRebroadcastsGenuineRnsAnnounceCorrectly`). The peer/downstream match conditions are documented
from genuine RNS `Transport.py:1774-1791`. No new fixture is added.

## Constraints (project-wide)

- Wire-compatible with Python-RNS 1.3.8; core `Sources/ReTiCA/*` stays zero-dep and **untouched**.
- Commit **directly to `main`** — no feature branch ([[commit-directly-to-main]]). Every commit leaves
  the full suite green.
- No compound shell commands; temp files under `/tmp/ReTiCA/`.
- Mutation-testing verification for every new/changed test.
- Reference RNS at `/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/RNS/`
  ([[rns-reference-env]]).
- Commit trailers (exact):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```
