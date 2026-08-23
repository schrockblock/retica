# F13 — reflected LINKREQUEST redirects our own link's traffic (relay linkTable hardening)

**Written:** 2026-08-22. **Repo:** ReTiCA (`/Users/ell/development/ios/pods/ReTiCA`). Target: `main`.
**Layer:** `ReTiCATransport` (`Transport`), with wiring through `ReTiCANode` (`TransportEndpoint`,
`LinkPlane`/`LinkSession`).

## Goal

Close backlog item **F13**: in relay mode, an attacker reflects our own outbound LINKREQUEST back to
us and makes us forward our own link's traffic (including the peer's LRPROOF) to the attacker,
stranding our link. Also fix the two adjacent relay-`linkTable` hygiene defects the same probes
found: entries that survive garbage collection forever on unauthenticated junk, and (largely)
unbounded growth. The fix is behavior-aligned with stock Reticulum 1.4.2.

## Status / severity context

F13 is **latent today**: every relay branch is gated on `state.transportIdentity != nil`
(`Transport.swift:40`, set only via `Transport.setTransportIdentity`, `:318-319`), which is reached
only through `TCPEndpoint.enableRelay` / `BLEEndpoint.enableRelay` — and nothing in the repo calls
either. So nothing that ships today is exploitable; this hardens relay deployments, which are a
one-line integrator decision away. It is the highest-severity backlog item because it *redirects* a
legitimate peer's traffic rather than merely denying service.

## Root cause

`Transport` owns the relay `linkTable` (transit links it forwards for); our own local links live in
the sibling `LinkPlane` reducer (`LinkPlane.State.links`, keyed by `linkID`). `Transport` has **no
knowledge of which linkIDs are local**, and its relay lookup is ordered ahead of local delivery.

`Link.linkID` (`Link.swift:26-33`) is a truncated hash of `Packet.hashablePart`, which excludes
`headerType`, `transportType`, `transportId`, and `hops`. So a HEADER_1 request and a HEADER_2
reflection of it yield the **same linkID**. An attacker takes our outbound LINKREQUEST off the wire
and re-emits it to us as HEADER_2 naming us as relay. Every precondition on the relay branch holds
(`Transport.swift:669-671`: `headerType == .header2`, `transportId == relayID.hash`, destination
not local, and we have a learned path — we must, we opened the link). `seenPacketHashes`
(`Transport.swift:413-414`) does not stop it: we never insert our own outbound packet hashes, and
the link-packet routing runs *before* that dedup anyway.

Result: `linkTable[ourLinkID]` is created (`Transport.swift:674-676`), and on the next link packet
the `destinationType == .link` block (`Transport.swift:387-402`) matches the entry and forwards the
packet (`:390-400`) **before** local delivery (`:402`). The genuine LRPROOF is transmitted to the
attacker instead of reaching our `LinkSession`; our link dies at `establishmentFailed(.timedOut)`,
which `LXMFNode` treats as PATH-shaped and so discards a good path. Against an already-`.active`
link, the same reflection blackholes inbound link traffic until the inactivity watchdog closes it.

**Two adjacent `linkTable` facts from the same probes:** entries are created with no size bound, and
`refreshedAt = date.now` is stamped on *any* matching link packet with no decryption, so an entry
survives the `maintenanceTick` `linkTableExpiry` GC forever on unauthenticated junk.

## Reference alignment (stock RNS 1.4.2)

Verified against `RNS/Transport.py` in the conda `rns` env:
- RNS `link_table` entries carry a `validated` flag (`IDX_LT_VALIDATED`), false at creation, set true
  after a link proof.
- **Unvalidated** entries expire at a hard proof-deadline (`IDX_LT_PROOF_TMO`, established from the
  per-hop establishment timeout) — not refreshable. **Validated** entries roll on a
  `LINK_TIMEOUT = 900s` (`STALE_TIME * 1.25`) idle timeout.
- RNS refreshes the timestamp (`Transport.py:1739`) only on forwarded data packets that pass hop and
  interface checks — **never** on LINKREQUEST, LRPROOF, or ANNOUNCE.
- RNS has **no count cap** on `link_table` (nor on `path_table`); it relies on the timeouts. We match
  this — no cap (see "Accepted limitations").

## Design

App/library-side, in `ReTiCATransport` with wiring through `ReTiCANode`. No wire-format change.

### Part A — Core: never relay or shadow a local link

1. **`Transport.State.localLinkIDs: Set<Data>`** — the set of linkIDs we are an endpoint of.
2. **`Transport` actions `registerLocalLink(Data)` / `unregisterLocalLink(Data)`** — insert/remove.
3. **Wiring:** `LinkPlane`/`LinkSession` emit an open/close delegate that `TransportEndpoint`
   forwards to `Transport`:
   - **Register** when an initiator link's `linkID` is computed (`LinkSession.swift:278`) and when a
     responder link is accepted (`LinkPlane.acceptLinkRequest`).
   - **Unregister** on link close/teardown.
   - Registration and the LINKREQUEST transmit are dispatched in the same reducer turn. The guarantee
     against a reflection racing ahead is NOT the order within that turn (TCA does not order the
     actions sibling effects emit) but that a reflection is an inbound network event — only possible
     after the attacker observes our transmitted request — so `localLinkIDs` already holds the linkID
     a full network round-trip before any reflection can be processed.
4. **Two guards in `Transport.received`:**
   - **LINKREQUEST relay branch** (`Transport.swift:669-678`): `guard !state.localLinkIDs.contains(linkID)`
     before creating a relay entry. A reflection of our own request is dropped (`return .none`),
     never tabled.
   - **Link-packet routing** (`Transport.swift:387-402`): if `state.localLinkIDs.contains(linkID)`,
     skip the relay table and fall through to local delivery (the existing `.delegate(.linkPacket)`
     path at `:402`). Local ownership takes precedence over the relay table.

Genuine transit links are never in `localLinkIDs`, so real relaying is unaffected.

### Part B — Table hardening (reference-aligned validated/unvalidated split)

1. **`LinkTableEntry` gains `validated: Bool` (default false) and `proofDeadline` (a hard timestamp).**
   On creation from a relayed LINKREQUEST: `validated = false`,
   `proofDeadline = now + establishmentTimeout`, where `establishmentTimeout` is ReTiCA's existing
   `LinkSession.establishmentTimeout` (currently 15s). Reference scales this per remaining hop; the
   plan may add hop-scaling only if `LinkTableEntry` already carries a hop count — otherwise the flat
   `establishmentTimeout` is the base (a longer, safer deadline than the sub-15s a single hop would
   give, so it never reaps a real in-flight relay early).
2. **Validation:** set `validated = true` when an LRPROOF for that `linkID` is forwarded back through
   the relay (observed on the link-packet routing path). This is the same signal reference uses
   (mark-on-proof); it does not require decryption.
3. **GC in `maintenanceTick`, two paths (mirroring reference):**
   - *Unvalidated* entry → expires at `proofDeadline` (hard; not refreshed). Junk that never carries
     a real proof is reaped in ~establishment-timeout seconds.
   - *Validated* entry → expires at `refreshedAt + linkTableExpiry`, with `linkTableExpiry` aligned to
     reference `LINK_TIMEOUT = 900s`.
4. **Fix the refresh:** `refreshedAt` is updated **only** on forwarded **data** packets that pass the
   existing direction/interface check (`Transport.swift:393-395`) — never on LINKREQUEST, LRPROOF, or
   announce. (Today it is stamped on any matching link packet, which is the GC-evasion.)

This bounds junk **by time** rather than by eviction: an unvalidated junk entry cannot be kept alive
by replayed junk, so it disappears almost immediately.

## Data flow

```
Open (initiator):  LinkSession computes linkID (:278) ──► register delegate
                     ──► TransportEndpoint ──► Transport.registerLocalLink(linkID)
                     ──► (then) transmit LINKREQUEST
Open (responder):  LinkPlane.acceptLinkRequest ──► register delegate ──► Transport.registerLocalLink
Close:             link teardown ──► unregister delegate ──► Transport.unregisterLocalLink

Inbound .link packet in Transport.received:
   linkID = destinationHash
   if localLinkIDs.contains(linkID):   deliver locally (.delegate(.linkPacket))   ◄── Part A guard
   else if linkTable[linkID]:          direction-check, forward; refresh only if data ◄── Part B
   else:                               local delivery (existing)

Inbound LINKREQUEST relay branch (relay mode):
   if localLinkIDs.contains(linkID):   return .none (drop reflection)             ◄── Part A guard
   else:                               create UNVALIDATED entry (proofDeadline), forward ◄── Part B

maintenanceTick GC:
   unvalidated: drop if now > proofDeadline
   validated:   drop if now > refreshedAt + linkTableExpiry
```

## Edge cases

- **Registration race:** closed by the network round-trip — a reflection can't be processed until
  after the transmit is observed and echoed, by which time registration has been dispatched (see A.3).
- **linkID reuse after close:** unregister makes a no-longer-owned linkID relayable again — correct.
- **Responder links:** registered on accept, so an inbound link we terminate can't be shadowed.
- **Genuine transit unaffected:** non-local linkIDs are never in `localLinkIDs`.
- **LRPROOF for our own link:** delivered locally by Part A (never marks a relay entry validated,
  because no relay entry exists for a local linkID).

## Testing

Relay mode set directly via `transportIdentity` (as existing relay tests do). `TestClock` for GC
timing (Transport timer tests require it). Each test mutation-verified per the three-step rule.

1. **Reflection doesn't shadow our link** (the backlog's end-to-end probe as a regression test): with
   a registered initiator link, a reflected HEADER_2 LINKREQUEST creates no relay entry, and a
   following LRPROOF for that linkID is delivered locally (`.delegate(.linkPacket)`), not forwarded.
2. **Active-link blackhole prevented:** same, against an `.active` local link.
3. **Genuine relay still works:** a non-local linkID still tables and forwards
   (`relayForwardsLinkRequestAndRecordsLinkTable`, `TransportTests.swift:940`, stays green; add the
   local-vs-non-local contrast).
4. **Register/unregister lifecycle:** initiator open and responder accept register; close
   unregisters; a reused linkID after close is relayable again.
5. **Unvalidated entry dies at hard deadline:** junk matching packets in between do not keep it alive.
6. **Validated entry rolls:** an LRPROOF flowing through marks it validated; data traffic refreshes;
   it expires at `refreshedAt + linkTableExpiry` once traffic stops.
7. **Refresh excludes non-data / wrong-direction:** LINKREQUEST/LRPROOF/announce/wrong-interface
   packets do not refresh `refreshedAt`.

## Accepted limitations

- **Validated-junk accumulation (matches reference):** the time-bound does not stop a determined
  attacker from creating many *validated*-junk entries (junk LINKREQUEST + a fake LRPROOF-context
  packet, then trickle traffic). Stock RNS has this same exposure — it has no count cap. We
  deliberately match reference (no cap) for wire/behavior fidelity and to avoid evicting legitimate
  transit links under load. Revisit only if a relay deployment needs defense beyond reference.
- **F13 is latent** until an integrator enables relay mode (see "Status / severity context").

## Out of scope

- Enabling relay mode / adding an `enableRelay` caller.
- A count cap or LRU eviction on `linkTable` (deliberately declined; see Accepted limitations).
- Any wire-format change or change to `Link.linkID` derivation.
- The other open backlog items (F11, F19, F7, F9, F10, F16).
