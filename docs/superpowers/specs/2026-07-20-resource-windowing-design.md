# Resource Windowing + Retransmission Robustness (slice 6c) — Design

**Status:** Approved (design phase)
**Date:** 2026-07-20
**Depends on:** 6a (Resource primitives), 6b (ResourceTransfer sender/receiver state machine, merged)

## Goal

Make the single-segment `ResourceTransfer` robust over lossy links: request parts in an
adaptive **window** rather than all-at-once, **retransmit** on timeout, and signal aborts via
**cancellation** packets — matching the Python-RNS 1.3.8 wire protocol and window arithmetic.

## Scope

**In scope**

1. **Windowed requesting (receiver).** Request up to `window` still-missing parts per round (start
   4), tracking a `consecutiveCompletedHeight`; request the next window as rounds complete.
2. **Event-driven window adaptation.** Grow +1 per fully-completed round (bounded by `windowMax`),
   raise `windowMin` when the spread exceeds `flexibility−1`; shrink −1 on timeout (bounded by
   `windowMin`), drop `windowMax`, with a second `windowMax−1` when the spread exceeds `flexibility−1`.
   `windowMax` is **fixed at the SLOW cap (10)**.
3. **Retransmission watchdog (receiver).** A per-round timeout; on expiry re-request the outstanding
   parts (shrinking the window, burning a retry); fail after `MAX_RETRIES` (16).
4. **Sender-side timers.** Re-advertise when no request arrives (`MAX_ADV_RETRIES` = 4), fail after
   overall patience while transferring, and time out / retry while awaiting proof
   (`PROOF_TIMEOUT_FACTOR` = 3).
5. **Cancellation.** `RESOURCE_ICL` (0x06, sender abort) and `RESOURCE_RCL` (0x07, receiver abort),
   each carrying the resource hash; receiving the peer's cancel drives `.failed`.

**Explicitly deferred (out of scope)**

- Rate-adaptive `windowMax` escalation (fast 10→75 / very-slow →4) — needs measured throughput (EIFR)
  from a live link the standalone reducer does not have.
- HMU (hashmap-update, `RESOURCE_HMU` 0x04) — only fires when a resource exceeds `HASHMAP_MAX_LEN`
  (74) parts, i.e. the **multi-segment (6d)** case. Single-segment transfers know the full hashmap up
  front, so the hashmap is never exhausted.
- Compression (6e); `ResourceTransfer` ↔ `LinkSession`/`Endpoint` integration.

## Architecture

Two-layer split, consistent with the pure-core / TCA-orchestration convention.

### Pure core (`ReTiCA`)

- **New `Sources/ReTiCA/Resource/ResourceWindow.swift`** — a pure value type encoding the RNS window
  arithmetic, unit-testable with zero TCA:

  ```
  public struct ResourceWindow: Equatable, Sendable {
      public var window: Int          // current window (init 4)
      public var windowMin: Int       // floor (init 2)
      public var windowMax: Int       // ceiling (init 10, fixed in 6c)
      public var flexibility: Int     // spread control (init 4)
      public func grown() -> ResourceWindow
      public func shrunk() -> ResourceWindow
  }
  ```

  - `grown()`: if `window < windowMax` → `window += 1`; then if `(window − windowMin) > (flexibility − 1)`
    → `windowMin += 1`.
  - `shrunk()`: if `window > windowMin` → `window −= 1`; then if `windowMax > windowMin` →
    `windowMax −= 1`, and if `(windowMax − window) > (flexibility − 1)` → `windowMax −= 1` again.

- **New pure helper on `Resource`** — selects the next window of missing parts:

  ```
  public static func nextWindowRequest(
      receivedIndices: Set<Int>, hashmap: Data, height: Int, window: Int, partCount: Int
  ) -> (indices: [Int], mapHashes: Data)
  ```

  Scans indices `height+1 …` up to `partCount−1`, collecting up to `window` indices whose slot is not
  in `receivedIndices`, and concatenating their 4-byte map-hashes sliced from `hashmap` (index-safe:
  materialize `Data(hashmap)`, stride by `MAPHASH_LEN` from `startIndex`). Returns the selected indices
  and the concatenated map-hash bytes.

### Transport (`ReTiCATransport`)

Extend `Sources/ReTiCATransport/ResourceTransfer.swift`. The `PacketContext` cases `0x04`–`0x07`
already exist in the core; **no core enum change is required** for cancellation.

## State additions

Add to `ResourceTransfer.State`:

- **Receiver:** `window: ResourceWindow` (4/2/10/4), `consecutiveCompletedHeight: Int` (−1),
  `outstanding: Set<Int>`, `retriesLeft: Int` (16), `partTimeoutFactor: Int` (4, → 2 after first part),
  `receivedFirstPart: Bool` (false), `rtt: Duration` (injected via the initializer, seeded from the link).
- **Sender:** `sentIndices: Set<Int>`, `advRetriesLeft: Int` (4), `proofRetriesLeft: Int` (3),
  `rtt: Duration`.
- **Status:** add `.awaitingProof` (sender, after all parts served). Existing cases
  `idle, advertised, requesting, transferring, complete, failed` remain.

Both initializers gain an `rtt: Duration` parameter (default e.g. `.seconds(1)` for tests). `State`
stays `Equatable` + `Identifiable`; `ResourceWindow` and `Duration` are `Equatable`.

## Constants (mirror RNS 1.3.8, as `static let`)

`WINDOW = 4`, `WINDOW_MIN = 2`, `WINDOW_MAX_SLOW = 10`, `FLEXIBILITY = 4`, `MAX_RETRIES = 16`,
`MAX_ADV_RETRIES = 4`, `PROOF_RETRIES = 3`, `PART_TIMEOUT_FACTOR = 4`, `PART_TIMEOUT_FACTOR_AFTER_RTT = 2`,
`PROOF_TIMEOUT_FACTOR = 3`, `RETRY_GRACE = .milliseconds(250)`, `PER_RETRY_DELAY = .milliseconds(500)`,
`SENDER_GRACE = .seconds(10)`, `PROCESSING_GRACE = .seconds(1)`.

## Behavior / data flow

### Receiver

- **`accept`** (unchanged parse/decrypt/unpack) → set `window`, request the **first** window via
  `Resource.nextWindowRequest`, populate `outstanding`, emit the encrypted `RESOURCE_REQ`
  (`0x00 ‖ hash ‖ selected-map-hashes`), status `.requesting`, arm the part-watchdog.
- **part received** (`.receiver, .data, .resource`) → place by map-hash (existing scan), remove its
  index from `outstanding`. If this is the first part ever: `partTimeoutFactor = 2`,
  `receivedFirstPart = true`. Advance `consecutiveCompletedHeight` while the next index is present.
  Re-arm the watchdog. **If `outstanding` is now empty (round complete):** `window = window.grown()`,
  `retriesLeft = MAX_RETRIES`; if parts remain → request the next window (as above); else assemble +
  verify + prove → `.complete` + emit `RESOURCE_PRF` (raw) + `delegate(.received)` (the merged 6b
  completion path, unchanged), and cancel the watchdog.
- **part-watchdog fires (`.receiverDeadline`)** → if `retriesLeft > 0`: `window = window.shrunk()`,
  `retriesLeft −= 1`, re-request the current `outstanding` (re-arm watchdog); else `.failed` +
  `delegate(.failed)` + emit `RESOURCE_RCL`. Timeout duration =
  `rtt · partTimeoutFactor + RETRY_GRACE + (MAX_RETRIES − retriesLeft) · PER_RETRY_DELAY`.

### Sender

- **request handler** (`.sender, .data, .resourceRequest`) → serve the requested parts (existing
  map-hash lookup), record served indices into `sentIndices`, reset `retriesLeft`. `ADVERTISED →
  TRANSFERRING` and arm the sender-watchdog. When `sentIndices.count == parts.count` → `.awaitingProof`
  (re-arm watchdog for the proof timeout).
- **proof received** (`.sender, .proof, .resourceProof`) → validate (existing) → `.complete` +
  `delegate(.concluded)`, or `.failed` + `delegate(.failed)`; cancel the watchdog.
- **sender-watchdog fires (`.senderDeadline`)** — branch on status:
  - `.advertised`: `advRetriesLeft > 0` → re-advertise (`advRetriesLeft −= 1`, re-arm); else `.failed`
    + `RESOURCE_ICL`. Timeout = `rtt · PART_TIMEOUT_FACTOR + PROCESSING_GRACE`.
  - `.transferring`: overall patience expired → `.failed` + `RESOURCE_ICL`. Patience =
    `rtt · PART_TIMEOUT_FACTOR · MAX_RETRIES + SENDER_GRACE`.
  - `.awaitingProof`: `proofRetriesLeft > 0` → `proofRetriesLeft −= 1`, re-arm (there is no transport
    cache to re-query, so a retry is simply extended patience — a noted simplification); else `.failed`
    + `RESOURCE_ICL`. Timeout = `rtt · PROOF_TIMEOUT_FACTOR + SENDER_GRACE`.

### Cancellation

- **inbound `RESOURCE_ICL` (0x06)** at a receiver whose payload equals `resourceHash` → `.failed` +
  `delegate(.failed)`, cancel watchdog.
- **inbound `RESOURCE_RCL` (0x07)** at a sender whose payload equals `resourceHash` → `.failed` +
  `delegate(.failed)`, cancel watchdog.
- **`.cancel`** (external action) → emit the role's cancel packet (raw; payload = `resourceHash`;
  `RESOURCE_RCL` for a receiver, `RESOURCE_ICL` for a sender), status `.failed`, cancel watchdog.
- Local abort on retries-exhausted emits the same role cancel packet.

## Effects / timers

`@Dependency(\.continuousClock) var clock`. A single `enum CancelID: Hashable { case watchdog }` per
reducer instance; the watchdog is a **one-shot** `.run { try await clock.sleep(for: d); await
send(.receiverDeadline | .senderDeadline) }.cancellable(id: .watchdog, cancelInFlight: true)`, re-armed
on each activity (part received, request sent, re-advertise) and cancelled on `.complete` / `.failed`.
This mirrors the established `LinkSession` inactivity-timer pattern.

New `Action` cases: `.receiverDeadline`, `.senderDeadline`, `.cancel`. Existing `.advertise`,
`.accept`, `.received`, `.delegate` remain.

## Error handling

- Retries-exhausted on either side → `.failed` + `delegate(.failed)` + the role's cancel packet.
- Assembly/verify failure (existing 6b path) → `.failed` + `delegate(.failed)`.
- Malformed / non-matching cancel or unexpected-context packets are ignored (`.none`).
- Watchdog fires in a terminal (`.complete` / `.failed`) state are no-ops (the timer is cancelled on
  entry to those states; a late fire is guarded by a status check).

## Testing

### Pure-core (in `ReTiCATests`, no TCA)

- `ResourceWindow.grown()` / `shrunk()`: exact sequences and `windowMin` floor / `windowMax` ceiling /
  spread behavior against hand-computed RNS-formula expectations (e.g. grow 4→5→…→10 caps; `windowMin`
  rises at the spread boundary; shrink drops `window` and `windowMax`, with the double `windowMax−1` at
  the spread boundary).
- `Resource.nextWindowRequest`: selects ≤`window` missing indices from `height+1`, skips filled slots,
  advances with `height`, and returns index-safe map-hash bytes; empty when nothing remains.

### Reducer (in `ReTiCATransportTests`, `TestStore` + `TestClock`)

- First request emits exactly `window` (4) map-hashes, not all parts; `outstanding` populated.
- A completed round grows the window and requests the next window.
- Part-timeout retransmits the outstanding parts, shrinks the window, and decrements `retriesLeft`.
- Retries exhausted → `.failed` + `delegate(.failed)` + `RESOURCE_RCL` emitted.
- Sender re-advertises on adv-timeout and fails after `MAX_ADV_RETRIES`, emitting `RESOURCE_ICL`.
- Sender reaches `.awaitingProof` once all parts are served; proof-timeout path retries then fails.
- Inbound `RESOURCE_ICL` (receiver) / `RESOURCE_RCL` (sender) with a matching hash → `.failed`.
- Every new/changed test is mutation-swept per the project's verification discipline.

### Wire cross-validation

The windowed `RESOURCE_REQ` reuses the **6b-validated** format (`0x00 ‖ hash ‖ map-hashes`), just a
subset per round; ICL/RCL payloads are the resource hash (already covered by existing hash vectors). No
new wire fixture is strictly required. A trivial ICL/RCL framing vector (context byte + hash) may be
added only if free. HMU is deferred, so no HMU vector.

## Known simplifications (carry to review)

- `windowMax` is fixed at 10 (no EIFR-driven escalation) — an approved scope cut.
- AWAITING_PROOF "retry" is extended patience (no transport proof-cache to re-query) — noted.
- `rtt` is an injected `Duration` rather than a live link measurement; timers run on the injected
  `continuousClock` for deterministic tests.
