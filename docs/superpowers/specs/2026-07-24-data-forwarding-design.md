# Transport Relaying 4b-2: Data-Packet Forwarding (one-way) — Design

**Status:** Approved (design phase)
**Date:** 2026-07-24
**Depends on:** 4b-1 (announce propagation + path-table `nextHop`). Second sub-slice of transport relaying (#4b).

## Goal

Make data packets flow multi-hop: an originator sends a HEADER_2 packet toward the next hop when a
destination is reached via a relay, and a relay forwards a HEADER_2 data packet addressed to it (as
`transport_id`) toward the destination — HEADER_2 to the next relay, or HEADER_1 on the final hop. One-way,
connectionless. Wire-compatible with Python-RNS 1.3.8.

## Scope

**In scope**

1. Originator: in `Transport.send`, send HEADER_2 (`transport_id = learned.nextHop`) when `nextHop !=
   destinationHash` (path is via a relay); HEADER_1 direct otherwise (today's behavior).
2. Relay (relay mode only): in the inbound `.data` path, a HEADER_2 packet whose `transport_id == our
   transportIdentity.hash` and whose `destinationHash` is non-local is forwarded per the path table
   (`nextHop`-based: HEADER_1 final hop / HEADER_2 to next relay), `hops = received + 1`, hop-limit-guarded.

**Explicitly deferred**

- **4b-2b:** reverse path (`reverse_table`) + links-over-a-relay (bidirectional LR handshake/proof routing).
- **4b-3:** re-broadcast robustness, random-blob anti-replay, path expiry.
- No `Packet` wire-model change; no `learned.hops` change (the decision is `nextHop`-based).

## Reference mechanics (Python-RNS 1.3.8, `Transport.py`)

- A relay processes a non-announce packet whose `transport_id == Transport.identity.hash` (`1597-1598`) by
  looking up `path_table[destination_hash]` → `next_hop`, `remaining_hops` (`1600-1601`), then
  (`1603-1614`):
  - `remaining_hops > 1`: keep the flags byte (stays HEADER_2), `hops` (already incremented on inbound
    `1491`), replace `transport_id` with `next_hop`, keep `destHash‖context‖payload` — `new_raw = raw[0:1] ‖
    hops ‖ next_hop ‖ raw[18:]`.
  - `remaining_hops == 1`: strip transport headers → `new_flags = HEADER_1<<6 | BROADCAST<<4 | (flags &
    0x0F)`, `hops`, then `destHash‖context‖payload` (`raw[18:]`, skipping the old `transport_id`).
  - `remaining_hops == 0`: shared-instance/local-client edge — no ReTiCA equivalent.
  - Forward out `path_table[dest][RVCD_IF]` (`1634`) — the interface the announce was received on.
- **Flag-byte handling (byte-level):** the relay case keeps the ENTIRE original flags byte (`raw[0:1]`), so
  `context_flag` (bit 5) is preserved; the final-hop case rebuilds flags as `HEADER_1<<6 | BROADCAST<<4 |
  (flags & 0x0F)`, which keeps only `destination_type` (bits 2-3) + `packet_type` (bits 0-1) and **zeroes
  `context_flag`**. For connectionless data `context_flag` is false, so it is moot in practice, but the
  byte-fidelity test enforces exact parity: relay-hop → `contextFlag = packet.contextFlag`; final-hop →
  `contextFlag = false`.
- **`nextHop`-equivalence:** RNS's `remaining_hops > 1` vs `== 1` is exactly "destination reached via
  another relay" vs "destination directly adjacent." In ReTiCA that is `learned[dest].nextHop != destHash`
  vs `== destHash` (4b-1's fallback set `nextHop = transportId ?? destHash`; only the relay adjacent to the
  destination heard it directly → `nextHop == destHash`). This holds for any chain length, so no
  `learned.hops` counter is needed for the decision — the 4b-1 hops off-by-one stays out of the data path.

## Current state (what exists / what's missing)

- `Transport.send` (`Transport.swift`): builds a HEADER_1 data packet to `learned[dest].interfaceID`;
  `nextHop` is unused on send.
- `Transport.received` `.data` case: delivers if `destHash` is a local destination whose kind matches; else
  `.none` (a HEADER_2 data packet addressed to us-as-`transport_id` for a remote dest currently falls
  through to `.none` — dropped). No forwarding.
- `Packet` fully models HEADER_2/`transportId`; `hops` byte 1, excluded from hash, limit-checked
  `< maxHops (128)`. 4b-1 added `transportIdentity`/relay re-broadcast; `learned[dest].nextHop` is now
  `transportId ?? destHash`.

## Architecture

All changes in `Transport.swift`. Core `Packet` unchanged.

### Originator send (`Transport.send`)

Replace the packet construction: after computing `ciphertext` (unchanged), branch on
`entry.nextHop != destinationHash`:
- via relay → `Packet(headerType: .header2, packetType: .data, transportType: .transport,
  destinationType: .single, context: .none, contextFlag: false, hops: 0, destinationHash: destinationHash,
  transportId: entry.nextHop, payload: ciphertext)`.
- direct → the existing HEADER_1 packet.

Transmit to `entry.interfaceID` as today. (`entry.nextHop` is never nil post-4b-1.)

### Relay forward (`Transport.received`, `.data` case)

Before the existing local-delivery logic:
```
case .data:
    if let relayID = state.transportIdentity, packet.headerType == .header2,
       packet.transportId == relayID.hash,
       state.localDestinations[packet.destinationHash] == nil {
        guard let entry = state.learned[packet.destinationHash],
              Int(packet.hops) + 1 < Int(Packet.maxHops) else { return .none }
        let fwd: Packet
        if entry.nextHop == packet.destinationHash {
            // final hop → strip transport headers, HEADER_1 direct
            fwd = Packet(headerType: .header1, packetType: packet.packetType, transportType: .broadcast,
                         destinationType: packet.destinationType, context: packet.context,
                         contextFlag: false, hops: packet.hops + 1,   // RNS final-hop drops context_flag (flags & 0x0F)
                         destinationHash: packet.destinationHash, transportId: nil, payload: packet.payload)
        } else {
            // relay → keep HEADER_2, swap transport_id to the next hop
            fwd = Packet(headerType: .header2, packetType: packet.packetType, transportType: .transport,
                         destinationType: packet.destinationType, context: packet.context,
                         contextFlag: packet.contextFlag, hops: packet.hops + 1,
                         destinationHash: packet.destinationHash, transportId: entry.nextHop,
                         payload: packet.payload)
        }
        guard let raw = try? fwd.packed() else { return .none }
        return .send(.delegate(.transmit(entry.interfaceID, raw)))
    }
    // else: existing local delivery
    guard let destination = state.localDestinations[packet.destinationHash], ... deliver ...
```

The forwarded packet preserves `destinationType`/`packetType`/`context`/`contextFlag`/`payload` from the
original and only rewrites the header per RNS. Leaf mode (`transportIdentity == nil`) skips the block →
today's behavior.

## Data flow (3-node A→R→B, one-way message)

1. B announces D. R (relay) re-broadcasts (4b-1) → A learns `learned[D] = (interfaceID: A→R link, nextHop:
   R.hash, …)`. R learns `learned[D] = (interfaceID: R→B link, nextHop: D (heard directly))`.
2. A `.send(msg to D)`: `nextHop (R) != D` → HEADER_2, `transport_id = R`, dest = D, out the A→R link.
3. R receives: HEADER_2, `transport_id == R.hash`, D not local, `learned[D].nextHop == D` → final hop →
   HEADER_1 to D, `hops = 1`, out the R→B link.
4. B receives: HEADER_1 data for local destination D → decrypts → `messageReceived(D, plaintext)` = A's exact
   message.

## Error handling / edge cases

- Relay with no path for `destHash` → `.none` (can't route).
- `hops + 1 >= maxHops` → `.none` (hop limit).
- `destHash` local AND `transport_id == us` → falls through to local delivery (we are the final dest).
- Loop: a forwarded packet that returns shares the original's `packetHash` (excludes hops/transport_id) → the
  dedup guard drops it; `hops` limit is the secondary bound.
- Leaf (`transportIdentity == nil`) → never forwards.
- A HEADER_2 data packet whose `transport_id` is NOT us → not forwarded here (falls to local delivery / drop
  as today).

## Testing

- **Originator:** `.send` to a destination learned via a relay (`nextHop != destHash`) → emits a HEADER_2 packet with `transportId == nextHop`, `hops == 0`, out `interfaceID`; a directly-heard destination (`nextHop == destHash`) → HEADER_1 as today.
- **Relay final hop:** relay-mode Transport, inbound HEADER_2 data (`transport_id == our hash`) for a dest whose `learned.nextHop == destHash` → forwards HEADER_1 (`transportId == nil`, `transportType == .broadcast`), `hops == received+1`, `payload == original`, out `learned.interfaceID`.
- **Relay to next relay:** dest whose `learned.nextHop != destHash` → forwards HEADER_2 with `transportId == learned.nextHop`, `hops == received+1`, payload verbatim.
- **Byte-fidelity vs RNS:** the forwarded bytes equal RNS's exact rewrite — for the relay case `raw[0:1] ‖ (hops+1) ‖ nextHop ‖ raw[18:]`; for the final case the HEADER_1 flag reconstruction. (Construct the expected bytes from the inbound packet's raw and compare.)
- **No path → drop; hop limit → drop; leaf → no forward; local dest → delivered (not forwarded).**
- **3-node E2E (Transport-level):** A[ifAR], R[ifAR, ifRB] relay-enabled, B[ifRB]. B announces → R
  re-broadcasts → A learns B-via-R; A `.send(msg)` → pumped A→R→B → B surfaces `messageReceived` with A's
  exact plaintext. (Hand-pump `.transmit` frames between the three stores.)
- Every new/changed test mutation-swept. Committed directly to `main`.

## Known simplifications (carry to review)

- One-way connectionless forwarding only; reverse path / links-over-a-relay is 4b-2b.
- `nextHop`-based decision (no `learned.hops` reconciliation) — equivalent to RNS's remaining-hops for all
  chain lengths since only the destination-adjacent relay has `nextHop == destHash`.
- The 3-node E2E is at the `Transport` level (Endpoint is single-interface; multi-interface endpoints are a
  separate deferred item).
