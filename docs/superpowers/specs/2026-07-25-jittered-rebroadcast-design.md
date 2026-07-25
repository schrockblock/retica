# Transport Relaying 4b-3b-1 — Jittered Delayed Announce Re-broadcast

**Status:** approved (design)
**Date:** 2026-07-25
**Sub-project:** Transport relaying #4b, third sub-slice (4b-3), second piece (4b-3b), first part (4b-3b-1).
Prior merged: 4b-1 (announce propagation), 4b-2 (one-way data forwarding), 4b-2b (links over a relay),
4b-3a (announce anti-replay / random-blob dedup).

## Problem

4b-3a re-broadcasts every fresh announce **immediately and synchronously** in the reducer. When many
relays hear the same announce at once, they all re-broadcast at the same instant — a synchronized
broadcast storm. RNS avoids this by **holding** each relayed announce in an `announce_table` and
re-broadcasting it after a **jittered delay** drawn from `[0, PATHFINDER_RW)` where
`PATHFINDER_RW = 0.5`s (`Transport.py:70`, `1925`: `retransmit_timeout = now + RNS.rand() *
PATHFINDER_RW`). The jitter de-synchronizes the mesh.

RNS's full `announce_table` also does retries with a grace period (`PATHFINDER_R`/`PATHFINDER_G`) and
collaborative suppression (`LOCAL_REBROADCASTS_MAX`). Those are deferred to later sub-slices
(4b-3b-2 suppression, 4b-3b-3 retries); this slice delivers **only the jittered single
re-broadcast**, which is the foundational de-storm behaviour and stands up the timer machinery the
later parts build on.

## Goal

Defer each fresh announce's re-broadcast by a random delay in `[0, 0.5)`s instead of emitting it
synchronously. The **count** of re-broadcasts is unchanged (still exactly one per fresh announce);
only the **timing** changes. Path learning stays immediate. Introduce a clock + injected-jitter +
cancellable per-destination retransmit + a holding table in `Transport`, reusing the exact
patterns already established in `LinkSession`.

## Scope

**In scope (4b-3b-1):**
- Hold each fresh, relay-mode, under-hop-limit announce in a per-destination `announceTable` and
  re-broadcast it **once** after a jittered delay `∈ [0, PATHFINDER_RW)` via the clock.
- A cancellable, per-destination retransmit timer; a fresh announce for a destination already
  pending **replaces** the entry and **re-arms** the timer (newer supersedes — RNS keys
  `announce_table` by destination).
- Migrate the existing tests that assumed a synchronous re-broadcast (see "Test-migration impact").

**Explicitly out of scope (later sub-slices):**
- **4b-3b-2 collaborative suppression:** cancelling the pending retransmit when neighbours are heard
  re-broadcasting the same announce (`LOCAL_REBROADCASTS_MAX`).
- **4b-3b-3 retries + grace:** re-broadcasting up to `PATHFINDER_R` extra times with `PATHFINDER_G`
  spacing. This slice re-broadcasts exactly **once** per fresh announce.
- **4b-3c expiry/GC:** the `announceTable` entry is removed as soon as its single re-broadcast fires
  (or is superseded), so it does not accumulate here; longer-lived table GC belongs to 4b-3c.
- Any change to blob-dedup, path selection (`shouldReplace`), `.data`/`.linkRequest` handling, or
  the re-broadcast **packet bytes** (identical to 4b-3a).

## Design

All changes live in `Sources/ReTiCATransport/Transport.swift`. Core `Sources/ReTiCA/*` is untouched.
The clock/cancellation/random patterns are copied from `LinkSession` (`@Dependency(\.continuousClock)`,
`.run { try await clock.sleep(...); await send(...) }.cancellable(id:cancelInFlight:)`, a `CancelID`
enum with a per-key case).

### 1. Constant

```swift
/// RNS PATHFINDER_RW (Transport.py:70): the random window for an announce re-broadcast, seconds.
static let announceRebroadcastWindow = 0.5
```

### 2. Dependencies

Add to `Transport`:

```swift
@Dependency(\.continuousClock) var clock
@Dependency(\.randomBytes) var randomBytes
```

(`randomBytes` already exists — `RandomBytesGenerator`, injectable/deterministic in tests.)

### 3. Holding table + cancel id

```swift
public struct PendingAnnounce: Equatable, Sendable {
    public var raw: Data              // the built HEADER_2 re-broadcast packet bytes
    public var arrivalInterface: InterfaceID
    public init(raw: Data, arrivalInterface: InterfaceID) {
        self.raw = raw; self.arrivalInterface = arrivalInterface
    }
}
public var announceTable: [Data: PendingAnnounce] = [:]   // keyed by destinationHash
```

```swift
private enum CancelID: Hashable { case announceRetransmit(Data) }
```

### 4. Jitter computation

Delay drawn from `[0, announceRebroadcastWindow)` using one injected random byte:

```swift
let jitter = Double(randomBytes(1).first ?? 0) / 256.0 * Transport.announceRebroadcastWindow
```

`randomBytes(1).first` ∈ 0…255 → `jitter` ∈ [0, 0.5·255/256] ⊂ [0, 0.5). Under the test ramp
generator the default byte is 0 (delay 0); tests override `randomBytes` to select a specific delay.
The exact value is **not wire-visible**, so matching RNS's window (not RNS's `rand()` bit-for-bit)
is the fidelity target.

### 5. Reducer: defer the re-broadcast

In the `.announce` fresh path, everything up to and including the `shouldReplace` path update and
the `pathLearned` effect stays **exactly as 4b-3a** (immediate). The change is only the re-broadcast
tail. Where 4b-3a built the HEADER_2 re-broadcast packet and returned `.delegate(.transmit(...))`
effects immediately, now — in relay mode (`transportIdentity != nil`) and under the hop limit
(`Int(hops)+1 < maxHops`):

1. Build the same HEADER_2 re-broadcast raw bytes as 4b-3a (payload verbatim, `transportType
   = .transport`, `transportId = our hash`, `hops+1`).
2. Store `state.announceTable[destinationHash] = PendingAnnounce(raw: rebroadcastRaw,
   arrivalInterface: interfaceID)`.
3. Return (merged with any `pathLearned` effect) a cancellable timer:

```swift
.run { send in
    try await clock.sleep(for: .seconds(jitter))
    await send(.announceRetransmitDue(destinationHash: destHash))
}.cancellable(id: CancelID.announceRetransmit(destHash), cancelInFlight: true)
```

`cancelInFlight: true` means a second fresh announce for the same destination cancels the stale
sleep and re-arms with the new entry (replace + re-arm).

A non-relay node, an own-destination announce, a replay, or an over-hop-limit announce schedules
nothing (returns exactly as it does after 4b-3a, minus the now-deferred transmit).

### 6. New action: fire the re-broadcast

```swift
case announceRetransmitDue(destinationHash: Data)
```

Handler: pop `state.announceTable[destinationHash]`; if absent (cancelled/superseded), return
`.none`. Otherwise emit `.delegate(.transmit(iface, entry.raw))` for every interface in
`state.interfaces` except `entry.arrivalInterface`, and leave the table without the entry (single
re-broadcast — retries are 4b-3b-3).

### 7. What does NOT change

- Blob-dedup recording, `shouldReplace` path update, `pathLearned` delegate — all still immediate.
- The re-broadcast packet bytes and interface-exclusion set.
- `.data` / `.linkRequest` handling; link routing before dedup.
- `Announce` / `Packet` / any core type.

## Test-migration impact (significant — budget for it)

Adding a clock dependency and deferring the re-broadcast breaks **every existing test that feeds a
fresh announce to a relay-mode Transport and expects a synchronous re-broadcast**. Each such test
must now: inject a clock (`ImmediateClock` when it does not care about timing, else a `TestClock`),
and account for the extra `.announceRetransmitDue` action hop before the `transmit` delegate.

Known affected surfaces (the plan enumerates the exact tests):
- `relayRebroadcastsAnnounceWithHeader2AndOurTransportId` and the 4b-3a relay tests
  (`exactReplayAnnounceIsDroppedAndNotRebroadcast`, `forgeReplayWithMutatedAppDataIsDropped`,
  `nonImprovingFreshAnnounceIsStillRebroadcast`) — they assert re-broadcast presence/absence in
  relay mode.
- The multi-node relay E2E pumps that relay an announce to reach a far node:
  `Tests/ReTiCATransportTests/TransportTests.swift` (3-node data relay), the relay
  cross-validation test (`RelayCrossValidationTests.swift`), and the 4b-2b 3-node link E2E
  (`Tests/ReTiCANodeTests/EndpointTests.swift threeNodeRelayLinkEstablishesAndCarriesData`) — each
  must advance/immediate-clock the relay node's announce re-broadcast step.
- Tests that assert **no** re-broadcast (own-destination, non-relay, replay-drop) are unaffected in
  spirit but may still need a clock injected if they share a relay store — the plan checks each.

`Endpoint`/`Node` wrappers that embed a `Transport` must propagate a clock dependency so their
stores resolve it; the plan verifies the dependency wiring.

This migration is inherent to introducing timers and is the bulk of the slice's effort. It is **not**
a behavioural change to those tests' intent — only to how they observe the (now-deferred)
re-broadcast.

## Testing

### Unit (`Tests/ReTiCATransportTests/TransportTests.swift`)
- **Deferred, not immediate:** a fresh announce to a relay emits `pathLearned` immediately but **no**
  `transmit`; after advancing a `TestClock` past the jitter delay, exactly one `transmit` fires with
  the 4b-3a re-broadcast bytes to every interface except the arrival one.
- **Jitter window:** with `randomBytes` overridden to a chosen byte, the scheduled delay equals
  `byte/256 * 0.5`; advancing to just-before does not fire, advancing to the delay does. A
  property-style check that any byte yields a delay in `[0, 0.5)`.
- **Replace + re-arm:** two fresh announces for the same destination within the window → only one
  `transmit` fires (for the newer entry), because the second cancels the first's timer.
- **Path learning still immediate:** `pathLearned` (and `state.learned`) is present before any clock
  advance.
- **No schedule when not relaying / own dest / replay / over hop limit:** no timer, no eventual
  `transmit` (regression guards, adapted to the clock).

### Cross-validation (constant parity — [[cross-validation-drive-real-rns]])
Timing/jitter is not byte-cross-validatable. Assert instead that `announceRebroadcastWindow` equals
RNS `Transport.PATHFINDER_RW` (read from genuine RNS at generation time and emitted into the
transport fixture as `pathfinder_rw`), and that the jitter mapping keeps the delay within
`[0, PATHFINDER_RW)`. This pins our constant to RNS without pretending to byte-match a random value.

## Constraints (project-wide)

- Wire-compatible with Python-RNS 1.3.8; core `Sources/ReTiCA/*` stays zero-dep and **untouched**.
- Commit **directly to `main`** — no feature branch ([[commit-directly-to-main]]).
- No compound shell commands; temp files under `/tmp/ReTiCA/`.
- Mutation-testing verification for every new/changed test.
- Reference RNS at `/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/RNS/`
  ([[rns-reference-env]]).
- Commit trailers (exact):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```
