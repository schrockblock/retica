# Transport Relaying 4b-1: Announce Propagation + Path Table — Design

**Status:** Approved (design phase)
**Date:** 2026-07-24
**Depends on:** the merged `Transport` (announce learning, dedup, link routing) and `Packet` (HEADER_2 +
`transportId` already modeled). First sub-slice of transport relaying (#4b).

## Goal

Give `Transport` an opt-in relay capability: on hearing an announce for a non-local destination, re-broadcast
it with the RNS-faithful header rewrite (so downstream nodes learn to route through us) and record a usable
next-hop in the path table. This is the routing-table-building foundation; **data-packet forwarding is 4b-2**,
and re-broadcast robustness (timing/retries/anti-replay/expiry) is 4b-3.

## Scope

**In scope**

1. Opt-in relay mode via `Transport.State.transportIdentity: Identity?` (nil = leaf, today's behavior; non-nil
   = relay enabled), threaded through `Endpoint`.
2. Path-table next-hop fallback: on learning an announce, `nextHop = transportId ?? destinationHash` (the
   fallback the current code explicitly deferred to 4b).
3. Immediate single re-broadcast of an inbound non-local announce (relay mode only): same payload, HEADER_2,
   `transport_type = .transport`, `transport_id = our transportIdentity.hash`, `hops = received + 1`, to all
   interfaces except the received-from one.

**Explicitly deferred**

- **4b-2:** data-packet forwarding (relay HEADER_2 data by path table; originator sends HEADER_2 to next-hop);
  reconciling the stored path-table `hops` counter with RNS's increment-on-receive semantics.
- **4b-3:** delayed/jittered retransmit, retries (`LOCAL_REBROADCASTS_MAX`), rate-limiting, random-blob
  anti-replay, path expiry.
- No change to the `Packet` wire model (HEADER_2/`transportId` already implemented).

## Reference mechanics (Python-RNS 1.3.8, read from `Transport.py`)

- A relay re-broadcasts an announce as (`Transport.py:616-635`): a NEW packet over the same destination with
  the **same announce payload** (`announce_data` — identity‖name_hash‖random_hash‖ratchet‖signature‖app_data,
  reused verbatim; the relay does NOT re-sign), `header_type = HEADER_2`, `transport_type = TRANSPORT`,
  `transport_id = Transport.identity.hash` (the RELAY's own hash → downstream routes back through it), and
  `hops = announce_hops` where `announce_hops` is `packet.hops` after the inbound `packet.hops += 1`
  (`Transport.py:1491`). Net: re-broadcast wire hops = received wire hops + 1.
- Path-table next-hop: `received_from = packet.transport_id if packet.transport_id != None else
  packet.destination_hash` (`Transport.py:1768-1793`) — HEADER_2 announce → next_hop = its transport_id;
  HEADER_1 (directly heard) → next_hop = the destination hash itself.
- Relaying/re-broadcast is gated by `transport_enabled()` (`Transport.py:1576`, `1938`). Hop limit
  `PATHFINDER_M = 128` (`hops >= 128` rejected). RNS delays + retries re-broadcasts via `announce_table`
  (deferred to 4b-3).

## Current state (what exists / what's missing)

- `Transport.received` (`Sources/ReTiCATransport/Transport.swift`): link traffic → up (pre-dedup); dedup by
  `packet.packetHash` (`RingSet`); announce → learn path if `localDestinations[destHash] == nil`; data →
  deliver if for a local destination; else `.none` (dropped). No relay, no re-broadcast.
- Announce learning stores `LearnedDestination(identity, appData, ratchet, interfaceID, hops:
  packet.hops, nextHop: packet.transportId, announceEmitted)` — `nextHop` is the raw `transportId` (nil for
  HEADER_1); the `transportId ?? destinationHash` fallback is explicitly DEFERRED (a code comment names 4b).
- `Packet` fully models `headerType`/`transportType`/`transportId` (HEADER_2 parse/serialize); `hops` is byte
  1, excluded from the hash, limit-checked `< maxHops (128)`, never incremented. `Transport.State.interfaces:
  Set<InterfaceID>`; transmit via `delegate(.transmit(InterfaceID, Data))`.
- No `transportIdentity`, no relay mode, no announce re-broadcast anywhere.

## Architecture

All changes in `ReTiCATransport`. The `ReTiCA` core (`Packet`) is unchanged.

### `LearnedDestination` (`Sources/ReTiCATransport/LearnedDestination.swift`)

No new field. The `nextHop` fallback is applied where it is POPULATED (in `Transport`), so `nextHop` becomes
non-nil for directly-heard announces too. (Existing consumers read `interfaceID`; `nextHop` is consumed by
4b-2.)

### `Transport` (`Sources/ReTiCATransport/Transport.swift`)

- **State:** add `public var transportIdentity: Identity? = nil`. nil = leaf (unchanged behavior); non-nil =
  relay enabled.
- **Enable action:** add `case setTransportIdentity(Identity?)` (or an init param) → `state.transportIdentity
  = identity`. Endpoint exposes a thin pass-through to enable relay mode.
- **Announce learn (in the existing `.announce` non-local branch):**
  - Compute `nextHop = packet.transportId ?? packet.destinationHash` and store it in `LearnedDestination`
    (replacing the current `nextHop: packet.transportId`). `hops` stays `packet.hops` (received wire value —
    see Deferred; the re-broadcast wire hops is still correctly received+1).
  - After learning, if `state.transportIdentity != nil` AND `packet.hops + 1 < Packet.maxHops`, build the
    re-broadcast packet:
    ```
    Packet(headerType: .header2, packetType: .announce, transportType: .transport,
           destinationType: packet.destinationType, context: packet.context,
           contextFlag: packet.contextFlag, hops: packet.hops + 1,
           destinationHash: packet.destinationHash, transportId: transportIdentity.hash,
           payload: packet.payload)                      // payload reused verbatim
    ```
    and transmit its `packed()` bytes to every interface in `state.interfaces` except `interfaceID`
    (received-from). Merge these transmits with the existing `pathLearned` delegate.
- **Leaf mode (`transportIdentity == nil`):** the re-broadcast block is skipped entirely — byte-for-byte the
  current behavior.

## Data flow (relay learns + propagates)

1. Relay R (transport enabled) hears an announce for remote destination D on interface `i0` (HEADER_1,
   hops `h`).
2. R learns `learned[D] = (…, interfaceID: i0, nextHop: D (fallback), hops: h)`.
3. R re-broadcasts on `i1, i2, …` (all interfaces ≠ i0): HEADER_2, `transport_id = R.hash`, `hops = h+1`,
   same payload.
4. A downstream node N on `i1` hears R's re-broadcast (HEADER_2, transport_id = R): it learns
   `learned[D] = (…, interfaceID: <N's link to R>, nextHop: R, hops: h+1)` — i.e. "reach D via R." (N's
   learning is the existing leaf path; the `nextHop = transport_id ?? destHash` fallback now records `R`.)

## Error handling / edge cases

- Relay off → re-broadcast skipped; identical to current leaf behavior.
- Announce for a local destination → not learned and not re-broadcast (existing guard).
- `packet.hops + 1 >= maxHops (128)` → not re-broadcast (respect the hop limit).
- Single-interface relay → the received-from exclusion leaves no interface to send out → no-op (correct).
- Dedup: the inbound announce is deduped by `packetHash` as today (a byte-identical duplicate is dropped
  before re-broadcast); the re-broadcast is a NEW packet (different header/hops → different bytes) so it is
  not self-deduped. (Loop/storm control beyond hop-limit is 4b-3.)

## Testing

- **Relay, HEADER_1 announce (remote dest):** learns `nextHop == destinationHash`; emits exactly one
  re-broadcast per non-received interface — HEADER_2, `transportId == transportIdentity.hash`, `hops ==
  received + 1`, `payload == original`, and the re-broadcast parses back to a valid announce whose signature
  validates.
- **Relay, HEADER_2 announce:** learns `nextHop == the announce's transportId`; re-broadcast at hops+1 with
  our transport_id.
- **Received-from excluded:** with interfaces {i0, i1}, an announce on i0 re-broadcasts only on i1.
- **For-local-destination announce:** not re-broadcast.
- **Hop limit:** an announce at `hops == maxHops - 1` is not re-broadcast.
- **Leaf mode (`transportIdentity == nil`):** no re-broadcast; all existing announce-learning tests unchanged.
- **Cross-validation (genuine RNS):** feed a genuine-RNS announce packet (reuse the announce fixtures) into a
  relay Transport; assert the re-broadcast header (HEADER_2 / `transport_id == our hash` / `hops == fixture
  hops + 1` / `transport_type == .transport`) and that its payload byte-equals the original genuine-RNS
  announce payload (so the reference signature is intact); assert the learned `nextHop` fallback matches RNS
  semantics (HEADER_1 → destHash).
- **End-to-end (optional, two/three Endpoints):** a relay-enabled Endpoint between two others re-broadcasts an
  announce so the far node learns a path with `nextHop` = the relay. (May defer the full 3-node E2E to 4b-2
  where forwarding makes it meaningful.)
- Every new/changed test mutation-swept. Committed directly to `main`.

## Known simplifications (carry to review)

- Immediate single re-broadcast; RNS's delayed/jittered/retried/rate-limited/anti-replayed propagation is
  4b-3.
- `learned.hops` keeps the received wire value (not RNS's increment-on-receive) to avoid disturbing merged
  leaf behavior; the re-broadcast wire hops is still received+1 (matches RNS). Reconciled in 4b-2 when
  forwarding consumes remaining-hops.
- Relay identity is a provided `Identity` used only for its `.hash` here (private key unused until path
  responses / 4c); presence of the field is the mode switch.
- No data forwarding (4b-2); the path table (`learned`) now carries a usable `nextHop` for it.
