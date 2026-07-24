# Transport Relaying 4b-2b: Links Over a Relay (minimal) — Design

**Status:** Approved (design phase)
**Date:** 2026-07-24
**Depends on:** 4b-1 (announce propagation + path table) and 4b-2 (one-way data forwarding). Third sub-slice of
transport relaying (#4b).

## Goal

Establish and carry a bidirectional Reticulum LINK across ONE transport relay: the initiator's LINKREQUEST is
forwarded to the responder, a relay records reverse-routing state (`link_table`), the LRPROOF routes back,
and established link traffic (data / keepalive / close / resources / requests) flows both ways through the
relay by `link_id`. Wire-compatible with Python-RNS 1.3.8. Minimal robustness (see Deferred).

## Scope

**In scope**

1. **Initiator (path-aware LINKREQUEST):** `Endpoint.openLink` passes the learned relay next-hop to the
   `LinkSession`; the initiator builds a HEADER_2 LINKREQUEST (`transport_id = nextHop`) when the destination
   is reached via a relay (else HEADER_1 direct, as today). Subsequent link packets stay HEADER_1.
2. **Relay (`Transport`):** a `linkTable: [Data: LinkTableEntry]` keyed by `link_id`.
   - Inbound transport-id-addressed LINKREQUEST for a remote dest → derive `link_id`, store
     `linkTable[link_id] = (rcvdIf, nhIf)`, forward it toward the dest (nextHop-based HEADER_2/HEADER_1
     rewrite, as 4b-2).
   - Inbound `destType == .link` packet (LRPROOF + established link traffic) whose `link_id ∈ linkTable` →
     forward direction-aware (`rcvdIf ↔ nhIf`), `hops+1`; else the existing `linkPacket` delegate (local
     link).

**Explicitly deferred**

- Relay-side LRPROOF signature validation + `link_table` "validated" flag; per-hop proof-timeout extension
  (`ESTABLISHMENT_TIMEOUT_PER_HOP`); `link_table` expiry (leak until then); MTU renegotiation; shared-interface
  hop-matching (we assume a relay's two link legs are distinct interfaces).
- Multi-relay link chains beyond a single relay are supported by the same mechanism per hop, but only the
  1-relay case is E2E-tested here.
- No `Packet`/`Link` core change (`link_id` derivation already matches RNS).

## Reference mechanics (Python-RNS 1.3.8)

- **`link_id`** (`Link.py:337-343` / ReTiCA `Link.linkID`): `truncated_hash(hashable_part)` with the trailing
  signalling bytes stripped when `payload > 64`. `hashable_part` excludes header_type + transport_id, so the
  `link_id` is IDENTICAL across HEADER_1/HEADER_2 forms — the relay derives the same id the endpoints use.
- **LINKREQUEST relay + `link_table`** (`Transport.py:1636-1677`, `IDX_LT_*` `3600-3608`): on forwarding a
  LINKREQUEST, `link_table[link_id] = [ts, next_hop, nh_if (toward dest), remaining_hops, rcvd_if (toward
  initiator), taken_hops, dst_hash, validated, proof_timeout]`. We keep the two load-bearing fields for
  minimal routing: `nh_if` (toward dest) and `rcvd_if` (toward initiator).
- **LRPROOF reverse routing** (`Transport.py:2199-2232`): a proof whose `destination_hash (link_id) ∈
  link_table`, arriving from the dest direction, is transmitted back out `rcvd_if`. (RNS also validates the
  signature + marks `validated`; deferred.)
- **Established link packet relay** (`Transport.py:1699-1738`): a `destType == LINK` packet whose `link_id ∈
  link_table` is forwarded direction-aware — arrived on `rcvd_if` → out `nh_if`; arrived on `nh_if` → out
  `rcvd_if`. (RNS disambiguates shared interfaces via hop-matching; we use the arrival interface, assuming
  distinct legs.)
- Forwarding uses the same HEADER_2→HEADER_1 rewrite + `hops+1` + hop limit as 4b-2 data.

## Current state (what exists / what's missing)

- `Transport.received` (pre-dedup, `Transport.swift:68-76`): `destType == .link` → `linkPacket(linkID:
  destHash)` delegate for ALL link packets; `packetType == .linkRequest` + LOCAL dest → `linkRequest`
  delegate. A remote LINKREQUEST → falls through → dedup → `default` → dropped. A link packet for a
  non-hosted link → `linkPacket` delegate → `Endpoint` finds no `LinkSession` → dropped. No relay, no
  `linkTable`.
- `LinkSession` initiator (`.establish`, `LinkSession.swift:185-198`) builds a HEADER_1 LINKREQUEST
  (`transportId: nil`, `destHash = destinationHash`) and transmits on its fixed `interfaceID` — never
  HEADER_2, no path consultation. `link_id = Link.linkID(requestPacket:)` (wire-compatible).
- LRPROOF (`LinkSession.swift:216-224`) + established link packets (`:467-475`): HEADER_1, `destType ==
  .link`, `destHash == link_id`.
- `Endpoint` routes `linkPacket`/`linkRequest` by `link_id`/`destHash` to a hosted `LinkSession`
  (`Endpoint.swift:105-116`); a relay has none for a transited link → drop.

## Architecture

Changes in `LinkSession` (build HEADER_2 LINKREQUEST when relayed), `Endpoint` (thread the learned nextHop
into `openLink`), and `Transport` (linkTable + relay forwarding). Core `Packet`/`Link` unchanged.

### Initiator — HEADER_2 LINKREQUEST

- `LinkSession.State` gains `relayNextHop: Data? = nil` (the relay to reach the destination through, or nil
  for a direct link). Set via the initiator init.
- `Endpoint.openLink(destinationHash)`: if `learned[dest].nextHop != destHash`, pass `relayNextHop =
  learned[dest].nextHop` when constructing the initiator `LinkSession`.
- `LinkSession.establish`: build the LINKREQUEST as HEADER_2 (`transportType: .transport, transportId:
  relayNextHop`) when `relayNextHop != nil`, else HEADER_1 as today. `link_id = Link.linkID(requestPacket:)`
  is unchanged (header-independent). Subsequent link packets remain HEADER_1.

### Relay — `linkTable` (`Transport`)

- `Transport.State` gains `public var linkTable: [Data: LinkTableEntry] = [:]` where `LinkTableEntry =
  { rcvdIf: InterfaceID, nhIf: InterfaceID }`.
- **LINKREQUEST relay** (transport-id-addressed, remote dest — handled alongside the 4b-2 transport_id
  forwarding, post-dedup): when `transportIdentity != nil`, `headerType == .header2`, `transportId ==
  transportIdentity.hash`, `packetType == .linkRequest`, and `destHash` non-local:
  - `let linkID = Link.linkID(requestPacket: packet)`; guard `learned[destHash]` exists +
    `Int(hops)+1 < maxHops`.
  - `state.linkTable[linkID] = LinkTableEntry(rcvdIf: interfaceID, nhIf: learned[destHash].interfaceID)`.
  - Forward toward the dest with the nextHop-based rewrite (final-hop HEADER_1 / onward HEADER_2), `hops+1`,
    out `learned[destHash].interfaceID` — identical to 4b-2 data forwarding.
- **Link-packet + LRPROOF relay** (in the pre-dedup `destType == .link` branch): if `linkTable[destHash]`
  exists (a transited link), forward direction-aware instead of surfacing `linkPacket`:
  - arrived on `entry.rcvdIf` → re-emit `hops+1` out `entry.nhIf` (toward dest);
  - arrived on `entry.nhIf` → re-emit `hops+1` out `entry.rcvdIf` (toward initiator);
  - guard `Int(hops)+1 < maxHops`; the packet is otherwise unchanged (HEADER_1, `destType == .link`,
    `destHash == link_id`, payload verbatim). If `linkTable` has no entry → the existing `linkPacket`
    delegate (local link / drop-upstream).

The responder and initiator `LinkSession`s are UNCHANGED — they process `link_id`-addressed packets exactly
as for a direct link (they don't know the link was relayed).

## Data flow (A—R—B link, full)

1. A learned B via R (4b-1): `learned[B] = (interfaceID: A→R, nextHop: R)`. `Endpoint.openLink(B)` →
   `LinkSession(initiatorTo: B, relayNextHop: R)`.
2. A `.establish` → HEADER_2 LINKREQUEST (`transport_id = R`, `destHash = B`) → out A→R. `link_id` computed.
3. R receives (transport_id == R, `.linkRequest`, B remote): `linkTable[link_id] = (rcvdIf: A-leg, nhIf:
   R→B)`; forwards HEADER_1 LINKREQUEST to B (final hop) out R→B.
4. B receives a normal HEADER_1 LINKREQUEST for its local dest → responder `LinkSession` → LRPROOF
   (`destType == .link`, `destHash == link_id`) out B→R.
5. R receives the LRPROOF on its R→B interface (`== nhIf`) → `link_id ∈ linkTable` → forward `hops+1` out
   `rcvdIf` (A-leg) → to A. A's initiator `LinkSession` validates → link ACTIVE.
6. Link data/keepalive/close/resources/requests (`destType == .link`, `link_id`) flow both ways: A→R (on
   rcvdIf) → out nhIf → B; B→R (on nhIf) → out rcvdIf → A.

## Error handling / edge cases

- Relay LINKREQUEST with no learned path for the dest, or past the hop limit → not forwarded (`.none`), no
  linkTable entry.
- `destType == .link` packet whose `link_id ∉ linkTable` → the existing `linkPacket` delegate (local link;
  or drop-upstream if unknown) — leaf behavior unchanged.
- Link packets are pre-dedup (as today, so keepalives aren't dropped) — the relay's link forwarding is
  likewise pre-dedup; loop protection is the hop limit (link traffic is point-to-point, no fan-out).
- A node that is BOTH a relay and a link endpoint: `linkTable` lookup first (transited), else local
  `LinkSession`.
- `link_id` parity: identical across HEADER_1/HEADER_2 (hashablePart excludes header_type/transport_id), so R
  and both endpoints agree.

## Testing

- **`link_id` parity (cross-val):** the relay derives the same `link_id` (`Link.linkID(requestPacket:)`) from
  the received HEADER_2 LINKREQUEST that the initiator computed and that B computes from the forwarded HEADER_1
  — assert all three equal. (RNS `link_id_from_lr_packet` is byte-identical; a fixture LINKREQUEST or a
  constructed one confirms parity.)
- **Initiator:** `openLink` to a via-relay destination → the emitted LINKREQUEST is HEADER_2 with `transportId
  == relayNextHop`; a direct destination → HEADER_1 (unchanged).
- **Relay LINKREQUEST:** a transport-id-addressed remote LINKREQUEST → `linkTable[link_id]` created with the
  right `rcvdIf`/`nhIf`, and the LINKREQUEST forwarded (final-hop HEADER_1) toward the dest.
- **Relay link forwarding (both directions):** a `destType == .link` packet with `link_id ∈ linkTable`
  arriving on `rcvdIf` → forwarded `hops+1` out `nhIf`; arriving on `nhIf` → out `rcvdIf`; payload verbatim; a
  packet with an unknown `link_id` → `linkPacket` delegate (not forwarded).
- **3-node link E2E (Transport + LinkSession level):** A[ar], R[ar,rb] relay-enabled, B[rb]. B announces →
  R re-broadcasts → A learns B via R → A opens a link → the LINKREQUEST/LRPROOF traverse R → the link goes
  ACTIVE on both ends → A sends link data → B receives the exact plaintext, and B→A likewise. (Reuse the
  two-endpoint link + resource E2E idioms, inserting R as a relay Transport between them.)
- Every new/changed test mutation-swept. Committed directly to `main`.

## Known simplifications (carry to review)

- Minimal: no relay-side proof validation / validated flag, no per-hop proof-timeout extension, no
  `link_table` expiry (grows until a future robustness pass), no MTU renegotiation, no shared-interface
  hop-matching (assumes distinct relay legs).
- 1-relay E2E only (the mechanism generalizes per hop).
- `link_id` parity is the wire-compat guarantee; forwarded link/LR packets reuse the 4b-2 `hops+1` handling.
