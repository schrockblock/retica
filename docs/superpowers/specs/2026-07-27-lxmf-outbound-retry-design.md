# LXMF-4c-1: Outbound Retry Timer + Terminal Outcomes — Design

**Sub-project:** LXMF-4 (LXMRouter), third area (4c robustness), first sub-slice. Follows 4a inbound, 4b core outbound. See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0` (`LXMRouter.py:2682-2839 process_outbound` retry branches, `2564 fail_message`; constants `DELIVERY_RETRY_WAIT=10`, `MAX_DELIVERY_ATTEMPTS=5`).

**Goal.** Give the outbound router a retry timer and terminal delivery outcomes: after sending, retry every `DELIVERY_RETRY_WAIT` up to `MAX_DELIVERY_ATTEMPTS`, confirm on a forwarded delivery signal, and surface `deliveryConfirmed`/`deliveryFailed` to the sender.

## Problem

4b sends a message once (fire-and-forget). Real delivery needs retries (packets/links are lossy) and a terminal outcome the sender can act on. RNS's `process_outbound` re-drives each pending message on a timer, capping attempts and failing the message at the limit; delivery is confirmed by a packet/resource proof.

**Constraint (decided):** ReTiCA's stack surfaces delivery outcomes only for resource transfers (`resourceConcluded`) and link lifecycle — there is no DATA-packet receipt. So the router does not *detect* delivery; it takes it as a **forwarded action** (`.delivered(messageHash:)`), which the app supplies from whatever Endpoint surfaces (`resourceConcluded → .delivered`). Opportunistic/direct-packet sends stay best-effort: no confirmation arrives, so they retry to the limit and then `deliveryFailed`. This keeps the router decoupled (consistent with 4a/4b) and defers packet-receipt support to a future Transport slice.

## Architecture

Extends `Sources/ReTiCANode/LXMFRouter.swift`. First timer in this reducer.

- Dependency: `@Dependency(\.continuousClock) var clock`.
- Cancel IDs: `private enum CancelID: Hashable { case retry(Data) }` (per message.hash).
- Constants: `static let deliveryRetryWait: TimeInterval = 10` (RNS `DELIVERY_RETRY_WAIT`); `static let maxDeliveryAttempts = 5` (RNS `MAX_DELIVERY_ATTEMPTS`).

### State
```swift
public enum ResendInfo: Equatable {
    case opportunistic(destinationHash: Data, payload: Data)
    case direct(linkID: Data, data: Data, asResource: Bool)
}
public struct PendingDelivery: Equatable { public var resend: ResendInfo; public var attempts: Int }
var pendingDeliveries: [Data: PendingDelivery] = [:]   // message.hash → in-flight send awaiting outcome
```

### Actions
```swift
case delivered(messageHash: Data)     // app forwards a delivery confirmation (e.g. from resourceConcluded)
case retryDue(messageHash: Data)      // internal: a retry timer fired
// Delegates (added to the existing 4a/4b Delegate):
case deliveryConfirmed(messageHash: Data)
case deliveryFailed(messageHash: Data)
```

### Reducer
- **Arming on send.** Wherever the 4b reducer emits a send delegate — `.sendOpportunistic` (on `.send` opportunistic), `.sendDirect` (on `.send` with an active link, and per drained message on `.linkEstablished`) — it now *also* records `pendingDeliveries[message.hash] = PendingDelivery(resend: <matching ResendInfo>, attempts: 1)` and merges a retry timer:
  ```
  retryTimer(hash) = .run { try await clock.sleep(for: .seconds(deliveryRetryWait)); await send(.retryDue(messageHash: hash)) }
                     .cancellable(id: CancelID.retry(hash), cancelInFlight: true)
  ```
  (Queued direct messages — no link yet — are *not* armed; the timer starts when they are actually sent on drain.)
- `.delivered(hash)` → `guard pendingDeliveries[hash] != nil`; remove it; `.merge(.cancel(id: .retry(hash)), .send(.delegate(.deliveryConfirmed(messageHash: hash))))`.
- `.retryDue(hash)` → `guard var pending = pendingDeliveries[hash]`; `pending.attempts += 1`; if `pending.attempts > maxDeliveryAttempts` → remove + `.send(.delegate(.deliveryFailed(messageHash: hash)))`; else store back, re-emit the `resend` delegate, and restart the timer (`.merge(resendDelegate, retryTimer(hash))`).

## Data flow

```
.send(msg) → emit sendOpportunistic/sendDirect  ┐
                                                 ├─ record pendingDeliveries[msg.hash] + start retry timer (10s)
.linkEstablished drain → sendDirect per queued msg ┘

.delivered(msg.hash)  ──▶ cancel retry timer, drop pending, .delegate(.deliveryConfirmed(msg.hash))
.retryDue(msg.hash)   ──▶ attempts++ ; > 5 → drop, .delegate(.deliveryFailed) ; else re-emit send delegate + restart timer
```

## Testing

TCA `TestStore` with an injected `TestClock`, mutation-verified.

**Task 1 (constants + cross-val):**
1. Cross-val: `LXMFRouter.deliveryRetryWait == RNS DELIVERY_RETRY_WAIT (10)` and `maxDeliveryAttempts == MAX_DELIVERY_ATTEMPTS (5)` — the fixture generator emits both.

**Task 2 (retry state machine + 4b test migration):**
2. **Arm on send** — `.send(opportunistic)` → `sendOpportunistic` + `pendingDeliveries[hash]` recorded (attempts 1).
3. **Confirm cancels retries** — arm, then `.delivered(hash)` before advancing the clock → `.deliveryConfirmed(hash)`, `pendingDeliveries[hash] == nil`; advancing the clock afterward emits no retry.
4. **Retry re-emits** — arm; advance `deliveryRetryWait` → `.retryDue` → the same send delegate re-emitted, attempts 2.
5. **Fail at max** — advance the clock `maxDeliveryAttempts` times → after the last, `.deliveryFailed(hash)` and `pendingDeliveries[hash] == nil` (no further retries).
6. **Direct arms too** — `.linkEstablished` drain of a queued message arms a delivery timer for it (a resource-sized message, so `resend` is `.direct(..., asResource: true)`).
7. **Migration:** the existing 4b `.send`/drain tests inject a `TestClock` (unadvanced) so their now-spawned retry timer sits pending and they pass unchanged.

No cross-val beyond the two constants (the rest is behavior over LXMF-1/2/3/4a/4b).

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test.
- Cross-val fixtures MUST derive from genuine LXMF; extend the committed `lxmf_fixtures.json`.
- Signatures validated, never byte-compared (`ed25519-hedged-nondeterministic`).
- Timer tests use `TestClock` (swift-dependencies `\.continuousClock` testValue is unimplemented — must inject); a `.off` TestStore tolerates an in-flight timer at teardown.
- New production: `LXMFRouter` retry extension (ReTiCANode). Tests in `ReTiCANodeTests` + the cross-val in `ReTiCATests/Vectors`.
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
