# Transport Relaying 4b-3b-2 — Announce Re-broadcast Retries + Grace

**Status:** approved (design)
**Date:** 2026-07-25
**Sub-project:** Transport relaying #4b, third sub-slice (4b-3), second piece (4b-3b), part 2 of 3.
Prior merged: 4b-1, 4b-2, 4b-2b, 4b-3a (anti-replay), 4b-3b-1 (jittered single re-broadcast).

## Re-scoping note

The original decomposition put collaborative suppression before retries. Reading genuine RNS
(`Transport.py:1774-1791`) showed suppression only cancels the pending re-broadcast when
`IDX_AT_RETRIES > 0`, and RNS **always performs the initial jittered send** — `retries` only becomes
non-zero after the first re-broadcast fires. So suppression cancels *retries*, and a retry-less world
(4b-3b-1) has nothing to suppress. Retries are therefore the prerequisite; this slice (4b-3b-2, now)
builds the retry lifecycle, and collaborative suppression follows as its own slice.

## Problem

4b-3b-1 re-broadcasts each fresh announce exactly **once**, after a jittered delay. RNS re-broadcasts
a held announce up to `LOCAL_REBROADCASTS_MAX = 2` times — the initial jittered send plus one retry
after a grace period — so an announce still propagates when the first re-broadcast is lost on a lossy
link. Without retries, a single dropped re-broadcast silently truncates propagation.

## Goal

Turn 4b-3b-1's single send into RNS's bounded retry lifecycle: **2 total re-broadcasts** per fresh
announce — the initial one after jitter `∈ [0, PATHFINDER_RW)`, then one retry after a **fixed**
`PATHFINDER_G + PATHFINDER_RW` (= 5.0 + 0.5 = 5.5s) — capped by `LOCAL_REBROADCASTS_MAX`. (RNS
`Transport.py:603` adds the two *constants* for the retry timeout — it is NOT a `rand()*PATHFINDER_RW`
draw; only the *initial* send is jittered, `Transport.py:1925`.) Each re-broadcast is byte-identical
(the same held `raw`). Path learning, blob-dedup, and the jitter window are all unchanged. Constants
cross-validated against genuine RNS.

## Scope

**In scope (4b-3b-2):**
- A per-announce re-broadcast counter; re-broadcast up to `announceMaxRebroadcasts (2)` times.
- Retry timers spaced `announceRetryGrace (5s) + jitter` after each send, capped; entry removed when
  the cap is reached.
- A superseding fresh announce resets the lifecycle (re-arm from `rebroadcasts: 0`).
- Migrate/audit the existing relay tests that now observe a second re-broadcast.

**Explicitly out of scope (later sub-slices):**
- **Collaborative suppression** (the redefined next slice): cancel the pending retry when neighbours
  are heard re-broadcasting the same announce (`local_rebroadcasts >= LOCAL_REBROADCASTS_MAX`,
  hops-match, Transport.py:1774-1791). This slice does the fixed 2 sends regardless of what is heard.
- **4b-3c expiry/GC:** timer cancellation on interface-disconnect / identity-clear; longer-lived
  table GC. (A completed lifecycle already removes its own entry here.)
- Any change to blob-dedup, path selection, the re-broadcast **packet bytes**, the jitter window, or
  `.data`/`.linkRequest` handling.

## Design

All changes live in `Sources/ReTiCATransport/Transport.swift`. Core `Sources/ReTiCA/*` untouched. This
builds directly on 4b-3b-1's `announceTable`, `PendingAnnounce`, `CancelID.announceRetransmit`,
`.announceRetransmitDue`, clock, `announceJitter`, and `announceRebroadcastWindow`.

### 1. Constants (both cross-validated against RNS)

```swift
/// RNS LOCAL_REBROADCASTS_MAX (Transport.py:77): total local re-broadcasts of one announce.
static let announceMaxRebroadcasts = 2
/// RNS PATHFINDER_G (Transport.py:69): grace period between announce re-broadcast retries, seconds.
static let announceRetryGrace = 5.0
```

### 2. `PendingAnnounce` gains a counter

```swift
public struct PendingAnnounce: Equatable, Sendable {
    public var raw: Data
    public var arrivalInterface: InterfaceID
    public var rebroadcasts: Int          // sends performed so far (starts 0)
    public init(raw: Data, arrivalInterface: InterfaceID, rebroadcasts: Int = 0) {
        self.raw = raw; self.arrivalInterface = arrivalInterface; self.rebroadcasts = rebroadcasts
    }
}
```

The `.announce` scheduling path is unchanged except it constructs `PendingAnnounce(raw:…,
arrivalInterface:…)` (default `rebroadcasts: 0`) and schedules the first timer with a jitter-only
delay, exactly as 4b-3b-1.

### 3. `.announceRetransmitDue` becomes a bounded retry loop

```swift
case let .announceRetransmitDue(destinationHash):
    guard var entry = state.announceTable[destinationHash] else { return .none }
    let sends = state.interfaces
        .filter { $0 != entry.arrivalInterface }
        .map { Effect<Action>.send(.delegate(.transmit($0, entry.raw))) }
    entry.rebroadcasts += 1
    if entry.rebroadcasts >= Transport.announceMaxRebroadcasts {
        state.announceTable[destinationHash] = nil          // lifecycle complete
        return sends.isEmpty ? .none : .merge(sends)
    }
    state.announceTable[destinationHash] = entry            // keep for the next retry
    // Fixed PATHFINDER_G + PATHFINDER_RW (RNS Transport.py:603 adds the constants; no rand draw).
    let delay = Transport.announceRetryGrace + Transport.announceRebroadcastWindow
    let retry = Effect<Action>.run { send in
        try await clock.sleep(for: .seconds(delay))
        await send(.announceRetransmitDue(destinationHash: destinationHash))
    }.cancellable(id: CancelID.announceRetransmit(destinationHash), cancelInFlight: true)
    return .merge(sends + [retry])
```

Notes:
- Every retry re-broadcasts the same `entry.raw` (RNS re-sends the stored packet bytes).
- The retry timer reuses the per-destination `CancelID.announceRetransmit(destinationHash)`, so a
  superseding fresh announce (which overwrites the entry with `rebroadcasts: 0` and re-arms with
  `cancelInFlight: true`) cancels the whole retry chain and restarts the lifecycle.
- `rebroadcasts` counts **sends**; the cap `>= announceMaxRebroadcasts (2)` yields exactly 2 sends
  (initial + one retry), matching RNS's completion checks (`retries >= LOCAL_REBROADCASTS_MAX` and
  `retries > PATHFINDER_R`, both firing at `retries == 2`).

### 4. What does NOT change

- The `.announce` fresh path above the scheduling tail (own-dest guard, parse, blob-dedup, path
  update, `pathLearned`), the three-condition schedule guard, and the re-broadcast packet bytes.
- The jitter window/mapping (`announceJitter`, `announceRebroadcastWindow`).
- `.data` / `.linkRequest` / link-packet handling.

## Test-migration impact

Every relay announce re-broadcast now emits up to **two** `.delegate(.transmit)` actions (the initial
send and one retry). Under the existing relay tests' `ImmediateClock`, the grace collapses to zero, so
both fire back-to-back and the entry pops with no lingering effect. Consequences:
- Tests asserting re-broadcast **content** with a `.off` predicate receive keep matching the first
  transmit; the identical second is skipped by `.off`. Where a test uses an exhaustive assertion or a
  "no further action" check that the second transmit would trip, the plan updates it to drain the
  second (identical) transmit.
- The multi-node relay pumps (`threeNodeRelayDeliversMessageEndToEnd`, the relay cross-val,
  `threeNodeRelayLinkEstablishesAndCarriesData`) relay the **first** re-broadcast to the next node; the
  second is drained/ignored at the relay. The plan verifies each pump still completes.

The plan enumerates the exact affected tests. This is a behavioural extension (one send → two), not a
change to any test's intent.

## Testing

### Unit (`Tests/ReTiCATransportTests/TransportTests.swift`), TestClock
- **Two sends then stop:** fresh announce → advance past jitter → exactly one transmit,
  `announceTable[dest].rebroadcasts == 1`; advance past `grace+jitter` → a second identical transmit,
  `announceTable[dest] == nil`; advance a further `grace+jitter` → no third transmit.
- **Retry bytes identical:** the second transmit's bytes equal the first (same held `raw`).
- **Supersede resets the lifecycle:** a fresh announce for the same dest during the grace window
  cancels the pending retry and restarts (only the newer announce's send chain fires).
- **Cap constant honoured:** with `announceMaxRebroadcasts == 2`, no send beyond the second.

### Cross-validation (constant parity — [[cross-validation-drive-real-rns]])
The generator emits `RNS.Transport.LOCAL_REBROADCASTS_MAX` and `RNS.Transport.PATHFINDER_G`; the test
asserts `announceMaxRebroadcasts == fixture.local_rebroadcasts_max` and `announceRetryGrace ==
fixture.pathfinder_g`. Timing behaviour is validated behaviourally under `TestClock`; the constants
are pinned to genuine RNS.

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
