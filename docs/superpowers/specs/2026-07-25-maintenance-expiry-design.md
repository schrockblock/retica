# Transport Relaying 4b-3c-1 — Maintenance Tick + Path/Link/Blob Expiry

**Status:** approved (design)
**Date:** 2026-07-25
**Sub-project:** Transport relaying #4b, third sub-slice (4b-3), third piece (4b-3c), part 1.
Prior merged: 4b-1, 4b-2, 4b-2b, 4b-3a, all of 4b-3b (jitter + retries + suppression).

## Problem

Several `Transport.State` tables grow or retain stale entries with no expiry:
- **`linkTable`** (relay link reverse-routing): an entry is created per relayed LINKREQUEST and
  **never removed** — the most concrete leak.
- **`learned`** (path table): grows per distinct destination, no expiry.
- **`announceBlobs`** (per-destination random-blob rings): grows in parallel with `learned`.

RNS ages entries out in a periodic `jobs()` loop: path table by `DESTINATION_TIMEOUT` (1 week),
`link_table` by `LINK_TIMEOUT` (`STALE_TIME × 1.25`), reverse table by `REVERSE_TIMEOUT` (8 min). Our
Transport is action-driven with no such loop.

## Goal

Introduce a standing periodic **maintenance tick** (the RNS jobs-loop analogue) that sweeps expired
entries: aged-out learned paths (removing their random-blob rings too) and stale `linkTable` entries.
This bounds table growth. Expiry timing is not wire-visible; the load-bearing timeout **constants**
are cross-validated against genuine RNS.

**Trigger — explicit, not automatic.** A diagnostic confirmed the test-default `continuousClock` is
*unimplemented*, so auto-starting the tick on a common action (e.g. `interfaceConnected`) would make
its `clock.sleep` fail every bare interface-connecting test (~29 sites). The tick is therefore started
by an explicit **`.startMaintenance`** action (and cancelled by `.stopMaintenance`). Existing tests do
not call it, so migration is near-zero; the production consumer (the Node/Endpoint layer or the app)
sends `.startMaintenance` once to enable GC — a small wiring follow-up, tracked but out of this slice.

## Scope

**In scope (4b-3c-1):**
- A self-rescheduling `.maintenanceTick`, started by an explicit `.startMaintenance` action and
  cancelled by `.stopMaintenance` (both under a `CancelID.maintenance`, `cancelInFlight: true` so a
  double-start is idempotent).
- Timestamps on `LearnedDestination` (`learnedAt`) and `LinkTableEntry` (`refreshedAt`), with
  `linkTable` refreshed on link-packet forward (active links survive).
- The sweep: expire `learned` (+ its `announceBlobs`) by `pathExpiry`; expire `linkTable` by
  `linkTableExpiry`.
- Migrate the ~4 `.on`-flipping relay tests to `skipInFlightEffects()`.

**Out of scope (later / deferred):**
- Cancelling the announce/retry timers on interface-disconnect / identity-clear (**4b-3c-2**, a
  separate lifecycle concern).
- RNS's per-interface path modes (AP_PATH_TIME / ROAMING_PATH_TIME) — we use the single
  `DESTINATION_TIMEOUT` for all learned paths.
- Data-forward path refresh (RNS refreshes `path_table` timestamp on data forward, Transport.py:1689);
  we refresh `learned` via re-announcement only (a newer-emission re-announce replaces the entry and
  re-stamps `learnedAt`). Deferrable nuance, not a growth leak.
- Reverse-table / cache / tunnel expiry (RNS-specific tables we do not have).

## Design

All changes in `Sources/ReTiCATransport/Transport.swift` and
`Sources/ReTiCATransport/LearnedDestination.swift`. Core `Sources/ReTiCA/*` untouched.

### 1. Constants

```swift
/// RNS DESTINATION_TIMEOUT (Transport.py:91): learned paths expire after one week unused, seconds.
static let pathExpiry: TimeInterval = 60 * 60 * 24 * 7          // 604800
/// RNS LINK_TIMEOUT (Transport.py:89 = Link.STALE_TIME * 1.25 = (STALE_FACTOR*KEEPALIVE)*1.25).
static let linkTableExpiry: TimeInterval = 900                  // 720 * 1.25
/// Sweep cadence for the maintenance tick — a local tuning constant (NOT wire-visible, NOT
/// cross-validated); far below the shortest expiry (linkTableExpiry = 15 min).
static let maintenanceTickInterval: TimeInterval = 60
```

### 2. Timestamps (defaulted so existing constructors do not break)

`LearnedDestination` gains `learnedAt`, defaulted so the many existing constructors compile unchanged:

```swift
    public var learnedAt: Date
    public init(identity: Identity, appData: Data?, ratchet: Data?, interfaceID: InterfaceID,
                hops: UInt8, nextHop: Data?, announceEmitted: UInt64,
                learnedAt: Date = Date(timeIntervalSince1970: 0)) {
        // …existing assignments…
        self.learnedAt = learnedAt
    }
```

`Transport.State.LinkTableEntry` gains `refreshedAt`, defaulted likewise:

```swift
        public struct LinkTableEntry: Equatable, Sendable {
            public var rcvdIf: InterfaceID
            public var nhIf: InterfaceID
            public var refreshedAt: Date
            public init(rcvdIf: InterfaceID, nhIf: InterfaceID,
                        refreshedAt: Date = Date(timeIntervalSince1970: 0)) { … }
        }
```

The default epoch is harmless in existing tests: the tick only sweeps when the `TestClock` is advanced
past `maintenanceTickInterval` (60 s), which no existing test does (the largest advance is the 5.5 s
retry), so no existing entry is ever swept.

### 3. Stamping

- **Learn:** in the `.announce` fresh path, the `LearnedDestination` candidate is built with
  `learnedAt: date.now`. A newer-emission re-announce (`shouldReplace`) replaces the entry and
  re-stamps it — this is the path refresh.
- **Link create:** at the LINKREQUEST-relay site, `LinkTableEntry(rcvdIf:…, nhIf:…, refreshedAt: date.now)`.
- **Link refresh on use:** in the pre-dedup `destinationType == .link` relay-forward branch, before
  forwarding, `state.linkTable[packet.destinationHash]?.refreshedAt = date.now` so an active relayed
  link is kept alive.

### 4. The tick and its lifecycle

New actions `case startMaintenance`, `case stopMaintenance`, `case maintenanceTick`; `private enum
CancelID` gains `case maintenance`. `interfaceConnected` / `interfaceDisconnected` are UNCHANGED.

- **`startMaintenance`**: start the self-rescheduling tick (idempotent via `cancelInFlight`):
  ```swift
  case .startMaintenance:
      return .run { send in
          while true {
              try await clock.sleep(for: .seconds(Transport.maintenanceTickInterval))
              await send(.maintenanceTick)
          }
      }.cancellable(id: CancelID.maintenance, cancelInFlight: true)
  ```
- **`stopMaintenance`**: `return .cancel(id: CancelID.maintenance)`.
- **`maintenanceTick`**: sweep, return `.none` (the `while` loop reschedules).
  ```swift
  case .maintenanceTick:
      let now = date.now
      for (dest, entry) in state.learned where now.timeIntervalSince(entry.learnedAt) > Transport.pathExpiry {
          state.learned[dest] = nil
          state.announceBlobs[dest] = nil           // blob GC piggybacks on path expiry
      }
      for (link, entry) in state.linkTable where now.timeIntervalSince(entry.refreshedAt) > Transport.linkTableExpiry {
          state.linkTable[link] = nil
      }
      return .none
  ```

### 5. What does NOT change

- Announce dedup/suppression/re-broadcast, `.data`/`.linkRequest` routing, path selection, the
  re-broadcast bytes. The link-forward branch gains only the `refreshedAt` write; the `.announce`
  candidate gains only `learnedAt`.

## Test-migration impact (near-zero)

With the explicit `.startMaintenance` trigger, **no existing test is affected** — none sends
`.startMaintenance`, so none starts the tick and none touches `continuousClock` via the tick. The two
new timestamp fields are defaulted, so existing `LearnedDestination` / `LinkTableEntry` constructors
compile unchanged. Only the new expiry tests exercise `.startMaintenance` (with a `TestClock` and a
mutable `date`). Diagnostics that informed this decision (kept for the record): a `.off` TestStore
tolerates an in-flight standing timer at deinit, but a bare TestStore's default `continuousClock` is
unimplemented and fails if used — hence the explicit opt-in trigger.

## Testing

### Unit (`Tests/ReTiCATransportTests/TransportTests.swift`), TestClock + `date`
- **Path expiry + blob GC:** a relay learns a dest (`learnedAt = t0`) and records its blob; advance the
  clock so the tick fires with `date.now > t0 + pathExpiry` → `learned[dest]` and `announceBlobs[dest]`
  are both removed. A path re-learned (re-announced) within the window survives.
- **Link expiry + refresh:** a `linkTable` entry created at `t0`; without use, after the tick fires past
  `linkTableExpiry` it is removed; an entry whose `refreshedAt` was updated by a link-packet forward
  survives past `t0 + linkTableExpiry`.
- **Tick lifecycle:** the tick starts on the first `interfaceConnected` (a sweep occurs after advancing)
  and stops after the last `interfaceDisconnected` (no sweep after that).
- **No premature sweep:** advancing less than `maintenanceTickInterval` runs no sweep; a not-yet-expired
  entry survives a tick.

Driving `date` and `continuousClock` together: use `$0.date` as a mutable dependency (or a
`LockIsolated`-backed generator) so `date.now` advances with the `TestClock`, since the sweep compares
`date.now` to the stored timestamps. The plan pins the exact dependency wiring.

### Cross-validation (constant parity — [[cross-validation-drive-real-rns]])
The generator emits `RNS.Transport.DESTINATION_TIMEOUT` and `RNS.Transport.LINK_TIMEOUT`; the test
asserts `pathExpiry == fixture.destination_timeout` and `linkTableExpiry == fixture.link_timeout`. The
tick interval is a local tuning constant and is **not** cross-validated.

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
