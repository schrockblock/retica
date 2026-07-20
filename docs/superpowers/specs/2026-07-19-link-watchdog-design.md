# Link Watchdog — Timers + Keepalive — Design (slice 5-links-d)

**Status:** Approved
**Date:** 2026-07-19
**Depends on:** 5-links-b (establishment) + 5-links-c (data + close), merged

## Goal

Add the time-driven robustness layer to `LinkSession`: establishment timeout, a keepalive
protocol, and inactivity teardown. Completes the Link lifecycle so an established link stays
alive under a keepalive and is torn down when the peer goes silent or a handshake hangs.
Wire-compatible with reference Reticulum 1.3.8 for the one wire-visible piece (the keepalive
packet); timer *durations* are local policy.

## Scope

**In scope**
- `@Dependency(\.continuousClock)` and cancellable timer effects on `LinkSession`.
- **Establishment timeout:** a link stuck in `.pending`/`.handshake` past `establishmentTimeout`
  → `.closed` with `CloseReason.timedOut` (no packet). Cancelled when the link reaches `.active`.
- **Keepalive:** the initiator sends an unencrypted `0xFF` keepalive packet every
  `keepaliveInterval`; the responder replies `0xFE`; any inbound packet resets the inactivity
  timer.
- **Inactivity teardown:** an `.active` link with no inbound for `staleTime` → emit a LINKCLOSE
  teardown packet, `.closed`, `CloseReason.timedOut`.
- `CloseReason` gains `.timedOut`.
- Configurable durations (`establishmentTimeout`, `keepaliveInterval`; `staleTime = 2 ×
  keepaliveInterval`) with sensible defaults.

**Explicitly out of scope** (future)
- RTT-derived adaptive keepalive interval (RNS `__update_keepalive`) — durations are fixed
  defaults / injectable, not computed from measured RTT.
- The RNS intermediate `STALE` state with its grace period — collapsed into a single
  inactivity timeout (identical observable outcome: close after silence).
- Phy-layer stats (RSSI/SNR/Q), identify, requests, resources.
- Transport/Endpoint wiring (routing link packets by link_id). `LinkSession` stays standalone;
  the parent hosts the store (so the timer effects run) and feeds inbound packets.
- MTU negotiation.

## Architecture

Extend the existing `LinkSession` `@Reducer` (`Sources/ReTiCATransport/LinkSession.swift`) — no
new source files. The watchdog is modeled as **cancellable "sleep-then-fire" timer effects**
keyed by a per-instance cancel id, not a polling loop. This is deterministic under `TestClock`
and mirrors the existing `TCPClientInterface` reconnect pattern.

### State additions

```
public var activatedAt: Double?      // set when the link reaches .active
public var lastInbound: Double?      // updated on every inbound link packet

// Local-policy durations (seconds). Not wire-visible; simplified from RNS per-hop timing.
public var establishmentTimeout: TimeInterval   // default 15
public var keepaliveInterval: TimeInterval      // default 30
// staleTime is derived: keepaliveInterval * 2 (RNS STALE_FACTOR) => default 60
```

`staleTime` is a computed property (`keepaliveInterval * 2`). Durations get defaults in the
`initiatorTo`/`responderFor` initializers and may be overridden for tests.

`CloseReason` gains `.timedOut`:

```
public enum CloseReason: Equatable, Sendable { case initiatorClosed, destinationClosed, timedOut }
```

### Dependencies

```
@Dependency(\.continuousClock) var clock
@Dependency(\.date) var date            // already present; used for lastInbound/activatedAt stamps
```

### Internal actions

Not part of the public delegate surface, but public on `Action` (TCA requires cases the reducer
sends to be on the enum):

```
case establishmentDeadline
case keepaliveDeadline
case inactivityDeadline
```

### Cancel ids

```
private enum CancelID: Hashable { case establishment, keepalive, inactivity }
```

Because a `LinkSession` store hosts exactly one link, module-private static cancel ids are
sufficient (each store has its own effect scope).

## Behavior

### Timer lifecycle

- **On `establish` / `acceptRequest`** (link enters `.pending`/`.handshake`): start the
  establishment timer — `.run { try await clock.sleep(for: .seconds(establishmentTimeout)); await
  send(.establishmentDeadline) }.cancellable(id: CancelID.establishment)`.
- **On reaching `.active`** (initiator LRPROOF-validated path; responder LRRTT path): cancel the
  establishment timer; set `activatedAt` and `lastInbound = now`; start the inactivity timer; and
  (initiator only) start the repeating keepalive timer. These are merged with the existing
  establishment effects (LRRTT transmit, `.established` delegate).

### `.establishmentDeadline`

- If `status` is `.pending` or `.handshake` → `status = .closed`, emit
  `.delegate(.closed(.timedOut))`, cancel all timers. (No teardown packet — the link was never
  active; matches RNS establishment-timeout path.)
- Otherwise ignore (`.none`).

### `.keepaliveDeadline` (repeating timer, initiator)

- If `status == .active` and `role == .initiator` → emit an unencrypted keepalive packet:
  DATA / `.keepalive` (0xFA) / `destinationType .link` / destHash = link_id / payload =
  `Data([0xFF])`. (Not encrypted — the sentinel byte is sent raw, per RNS plaintext-exempt
  contexts.)
- Otherwise ignore.

The keepalive timer is a repeating effect: `.run { while true { try await clock.sleep(for:
.seconds(keepaliveInterval)); await send(.keepaliveDeadline) } }.cancellable(id:
CancelID.keepalive)`.

### `.inactivityDeadline`

- If `status == .active` → emit a LINKCLOSE teardown packet (DATA / `.linkClose` / payload =
  `Link.encrypt(link_id, sessionKey)`), `status = .closed`, emit `.delegate(.closed(.timedOut))`,
  cancel all timers.
- Otherwise ignore.

### Inbound handling additions (in `.received`, when `.active`)

- **Any inbound link packet** (data, keepalive, close) updates `lastInbound = now` and **restarts
  the inactivity timer** (cancel + re-start `sleep(staleTime) → .inactivityDeadline`).
- **Keepalive `0xFF`** received by a responder → reply with a `0xFE` keepalive packet (DATA /
  `.keepalive` / payload `Data([0xFE])`, unencrypted), in addition to resetting inactivity.
- **Keepalive `0xFE`** received by the initiator → just resets inactivity (no reply).
- **Keepalive `0xFF` received by an initiator** (its own loopback) → ignored, does not reset
  (mirrors RNS `Link.py:923` guard). In practice initiators only receive `0xFE`.

Data (`.none`) and close (`.linkClose`) handling from 5-links-c is unchanged except that they now
also reset the inactivity timer.

### Emergent keep-alive

Because `keepaliveInterval < staleTime` (interval vs 2×interval), on a healthy link the
initiator's periodic `0xFF` and the responder's `0xFE` replies keep both sides' inactivity timers
fresh, so the link never times out. If either peer dies, replies stop and the survivor's
inactivity timer fires → teardown. A real RNS peer replies `0xFE` to our `0xFF` and vice-versa, so
this interoperates.

### Close interaction

On any `.closed` transition (explicit `close`, inbound LINKCLOSE, establishment/inactivity
deadline), cancel all three timers so no effect lingers.

## Wire compatibility

Only the keepalive packet is wire-visible and new:
- `packetType .data`, `context .keepalive` (0xFA), `destinationType .link`, destHash = link_id,
  payload = `Data([0xFF])` (initiator) or `Data([0xFE])` (responder reply). **Unencrypted.**
This is verified by unit test (framing + raw sentinel byte). Timer durations are local policy and
have no wire representation, so there is nothing new to cross-validate cryptographically; the
packet framing itself is already covered by the Packet cross-validation vectors.

## Error handling

- Deadlines that fire after the link already left the relevant state (e.g. establishment
  deadline after `.active`, or any deadline after `.closed`) are ignored.
- Inactivity resets only on recognized active-link packets addressed to the link_id (data,
  keepalive, close). An unrecognized packet (wrong destHash, or a context/type that matches no
  active-link case) is ignored entirely and does not reset the timer. A keepalive packet with an
  unexpected payload byte still counts as inbound (it reached the link) but the responder replies
  only to exactly `0xFF`.
- Timer effects are always cancelled on close, preventing leaked effects (TestStore requires all
  effects to finish).

## Testing

`TestStore` + `TestClock` (advance time deterministically; `$0.date` controlled for stamps):

- **Establishment timeout:** an initiator that `establish`es but never receives a proof →
  advance `TestClock` by `establishmentTimeout` → `.delegate(.closed(.timedOut))`, `status ==
  .closed`.
- **Establishment timer cancelled on establish:** complete the handshake to `.active`, advance
  past `establishmentTimeout` → NO `.closed(.timedOut)` (the establishment timer was cancelled).
- **Keepalive emission:** an active initiator, advance by `keepaliveInterval` → a keepalive
  packet is transmitted with `context .keepalive`, payload `Data([0xFF])`, and the raw bytes are
  unencrypted (parse the packet, assert payload is literally `0xFF`).
- **Responder reply:** an active responder receives a `0xFF` keepalive → transmits a `0xFE`
  keepalive.
- **Inactivity teardown:** an active link (responder, no initiator pinging) → advance by
  `staleTime` with no inbound → a LINKCLOSE teardown transmit + `.closed(.timedOut)`.
- **Inbound resets inactivity:** an active link, advance nearly to `staleTime`, feed an inbound
  packet, advance again — the link does NOT time out until a full `staleTime` passes with silence.
- **End-to-end:** two `LinkSession` stores sharing one `TestClock`; establish; advance several
  keepalive intervals feeding each side's keepalive/reply across — both stay `.active`; then stop
  delivering one side's packets and advance past `staleTime` — the starved side times out with
  `.closed(.timedOut)`.
- **Mutation testing** per the project three-step discipline for every new/changed test.

All tests must leave no un-finished effects (cancel timers on close; use `store.finish()` or
advance/await as needed).

## Global constraints

- Full wire compatibility with reference RNS 1.3.8 for the keepalive packet (context 0xFA,
  unencrypted `0xFF`/`0xFE`, addressed to the link).
- The `ReTiCA` core stays dependency-free; TCA (including `continuousClock`) confined to
  `ReTiCATransport`.
- Swift 6 strict concurrency; `LinkSession.State` remains `Equatable`; `Identity` is `Sendable`.
- Platform floor iOS 16 / macOS 13 / tvOS 16 / watchOS 9 / macCatalyst 16.

## Non-goals recap

Adaptive RTT-based intervals, a distinct STALE state/grace, phy-stats, identify, requests,
resources, and Transport/Endpoint wiring are all deferred. This slice makes a `LinkSession` a
self-maintaining connection: it times out hung handshakes, keeps active links alive with
keepalives, and tears down silent links — cross-validated (for the keepalive wire format) against
real RNS.
