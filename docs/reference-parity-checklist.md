# Reference-parity checklist

**Living document.** The prioritised list of what still separates ReTiCA from reference
Reticulum/LXMF, ordered by *what a real peer notices*. Tick items as they land.

**Last verified against:** `46e838e` (2026-08-14).
**Full evidence:** `docs/reference-gap-analysis-2026-08-10.md` (itself re-verified at `46e838e`).

> ### Maintenance rule — read before editing
>
> **Every item carries the commit it was last checked against.** The gap analysis rotted badly
> because nothing forced that: ten defects it reported as live were already fixed, eight of them
> before its own last edit. A checklist that reports closed holes as open misdirects effort worse
> than one that is merely out of date.
>
> When you tick an item: record the fixing commit, and re-stamp the *header* date only if you
> re-checked the untouched items too. Do not re-stamp the header on the strength of one fix.
>
> Line numbers rot. The durable keys are *file + expression + behaviour*.

---

## Where we are, in one table

| Layer | State |
|---|---|
| **Wire format** | Essentially complete, byte-verified against genuine reference output. No algorithmic gap in the crypto primitives. |
| **Protocol mechanics** | Good for the paths ReTiCA uses — links, resources, requests, announces, path requests, relaying, LXMF opportunistic/direct/propagated. |
| **Adversarial robustness** | ~17 remotely-reachable aborts closed plus two fail-opens; **3 remain** (Tier 2, Tasks 8-10 — and only one of those, Task 8, is a narrowing conversion the gate can see). |
| **Durability** | Absent. Nothing in the transport core persists. |
| **Breadth** | 2 of 15 interfaces; no `Channel`/`Buffer`, tickets, tunnels, or non-link proofs. |

The useful frame: ReTiCA speaks the wire correctly, then **loses messages for reasons the peer
cannot see**. That is what tier 1 is about.

---

## Tier 1 — silent data loss against real peers

*Fix first. Both sides believe the exchange succeeded.*

- [x] **`perTransferLimit` / `perSyncLimit` advertised as `0`** — `LXMFServiceNode.swift:120`, `PNNode.swift:85`
      Reference reads 0, drops **every** message, and calls `add_handled_message` so it is never
      retried (`LXMPeer.py:370-373`). Reference→ReTiCA mesh sync silently delivers nothing, forever.
      Default-reachable via `AUTOPEER` / `AUTOPEER_MAXDEPTH = 4`. Reference defaults are 256 / 10240
      (`LXMRouter.py:55, 59`). *Verified `46e838e`.* → **slice 1**
      **Fixed `f2eb255`** — both nodes advertise `LXMFPropagation.defaultPropagationTransferLimitKB`
      (256) / `defaultPropagationSyncLimitKB` (`256*40`), from one shared constant. Established that
      these fields are a *request the SENDER honours*, never receiver-enforced: `Handlers.py:61` →
      `LXMRouter.py:2025/2041` stores them on the peer's `LXMPeer` record for **us**, and that same
      object filters its own outbound offer at `LXMPeer.py:370`. No inbound cap is needed — a
      package-wide grep finds no inbound enforcement of `propagation_transfer_limit` in reference at
      all, and under-enforcing is the safe direction (we accept more than we asked for). Note we
      still do **not** enforce a sync-size cap on inbound resources, which reference does do
      (`LXMRouter.py:2220-2224`); deliberately out of scope.
- [x] **MsgPack decoder rejects types reference emits** — `MsgPack.swift:121-148`
      Missing negative fixint (`0xE0-0xFF`), `int8/16/32/64` (`0xD0-0xD3`), `float32` (`0xCA`),
      `map32` (`0xDF`), all ext. `LXMessage.unpack` decodes in one shot and `LXMFRouter.received`
      drops on failure with no diagnostic — so a message whose `fields` carry a **negative integer**
      (routine for telemetry/coordinates) is discarded whole, content and all, no error to the
      sender. *Verified `46e838e`.* → **slice 1**
      **Fixed `177da8c`** — all of the above decode *and* encode. Decode alone would have been
      wrong twice over: `LXMessage.validateSignature` re-packs the payload from the decoded fields
      on every inbound message, so a readable-but-unwritable type just moves the failure to the
      signature check; and `mapHeader`'s `UInt16(n)` was allowlisted as host-only *because the
      decoder had no `0xDF` branch*, so map32 decode by itself would have made a >65535-pair map a
      remote abort. Reference `_pack_integer` picks the width from the value alone
      (`umsgpack.py:288-314`), so integers round-trip byte-identically with no wire-width memory;
      `_pack_float` (`:325-333`) reads a module global instead, so float32 needs its own
      `MsgPackValue.float` case or a re-encode would widen 5 bytes to 9. **ext/fixext is rejected
      on purpose**, not still missing: umsgpack writes it only for a `datetime.datetime` or an
      `umsgpack.Ext` (`:517-520`), and neither appears in an RNS or LXMF msgpack payload. Negative
      `intMap` **keys** also remain rejected, per `eb244c3`'s reject-don't-truncate ruling — LXMF's
      field keys are the non-negative `FIELD_*` constants (`LXMF.py:8-51`). No emitted byte
      changed; the 167 cross-validation vectors that byte-compare against genuine Python output
      all still pass.

## Tier 2 — remotely reachable crashes still open

*Planned and gated; mostly execution. Plan: `2026-08-12-wire-input-trap-sweep.md` (7/10 done).*
*Gate status: **1 known-open conversion left** (Task 8). Tasks 9 and 10 are not narrowing
conversions, so the gate cannot see them — their tests are the only regression guard.*

- [x] **Task 6 — `LXMFServiceNode.swift` `Int(raw)` (in `requestReceived`)** — `[[], [], float64(NaN)]` on a `/get`
      aborts. **No `/get` handler is registered, so no `RequestPolicy` gate applies** — any client.
      **Fixed** — `59f900e`: NaN/negative/infinite float → 0 (serve nothing); negative int → 0
      (not nil/unlimited). Also closes the `.int` fall-through divergence opened by `177da8c`.
- [x] **Task 7 — `PNAnnounce.swift:56-59`, six `Int(UInt64)` (in `PNAnnounce.parse`)** — a 21-byte
      app-data blob aborts. `PNAnnounce.isValid`, the *validity predicate*, crashed on the input it
      exists to reject. **Fixed** — all six `Int(x)` replaced with `Int(exactly:)` guard-returning
      `nil`; any single bad field fails the whole predicate, matching reference's per-field
      `try/except` shape in `pn_announce_data_is_valid` (LXMF.py:224-250). Reject, not truncate.
      Commit: see Task 7 report.
- [ ] **Task 8 — `ResourceTransfer.swift:451` `Int(chunkIndex) * 74 * 4`** — traps twice, at the
      conversion *and* the multiply. Bound the **product**, not just the conversion.
- [ ] **Task 9 — unkillable stamp generation** — `LXMFNode.swift:340` → `LXStamper.swift:73-79`: a
      wire `targetStampCost` reaches a bare `while true` in a `.run` effect with **no cancellation
      ID**. Clamp the cost *and* give the effect an ID.
- [ ] **Task 10 — decompression allocates the ceiling, not the content** — `Bzip2.swift:36-38` /
      `ResourceTransfer.swift:408`: 41 bytes can drive a 64 MiB allocation. Not reference parity —
      `Resource.py:691` uses an incremental `BZ2Decompressor(max_length=)`.

## Tier 2b — the amplifier, and a live data-loss vector in its own right

*Originally filed as "not a defect on its own". **That was wrong** — see the correction inside the
item. It is both the thing that turns decode bugs into remote aborts, and a silent-loss vector of
exactly the class Tier 1 just closed.*

- [ ] **`LXMessage.validateSignature` re-encodes unconditionally.** Reference validates against the
      **received bytes** when there is no stamp; we always re-pack the decoded fields and validate
      against our own output. Consequences: (a) every inbound rich message traverses the
      decode→re-encode path, so any encode-side trap becomes **wire-reachable** — this is exactly
      how a recorded *host-only* `UInt16(n)` in the map encoders was one commit away from becoming
      a remote abort; (b) round-trip must be **byte-identical** or valid messages fail validation,
      which is a far stricter constraint on the codec than reference labours under.
      ~~Validating against received bytes would demote "decode support requires byte-exact encode
      support" from a **correctness** constraint to a tidiness one.~~

      **CORRECTED after review, same day — twice, and both ways it moved make it worse:**

      1. **This is not merely an amplifier; it loses messages today.** Reference
         `unpack_from_bytes` re-packs only when `len(unpacked_payload) > 4` (`LXMessage.py:745-750`),
         so with no stamp `packed_payload` **is** the received slice and `signed_part` (`:761`) is
         built from it. We always rebuild via `payloadBytes(...)`
         (`LXMessage.swift:118-122`). So a legitimate sender whose packing differs from ours **in
         any single byte** fails validation and `LXMFRouter.received` drops the message — the same
         silent-loss class as the Tier 1 defects, not a hypothetical.
      2. **Fixing `validateSignature` alone would narrow the coupling, not remove it.** Two paths
         survive: (a) the **stamped** path, where reference itself re-packs `payload[:4]`, so
         canonical re-encode is still required there; and (b) our `packed` property recomputes from
         fields, whereas reference stores `message.packed = lxmf_bytes` (`:798`) and
         **re-transmits the received bytes** — so a ReTiCA propagation node *forwarding* a message
         still depends on byte-exact re-encode.

      **Scope any task on this to carry the original bytes on `LXMessage` and use them in _both_
      places** — validation and forwarding. Fixing only validation leaves the forwarding path
      exposed and would read as done. *Found 2026-08-14 while landing the decoder widening;
      pre-existing and untouched.*

## Tier 3 — identity and anti-spam interop

- [ ] **No delivery-announce app data** — `LXMFNode.swift:92` announces `appData: nil`.
      Reference packs `msgpack([display_name, stamp_cost, [SF_COMPRESSION]])` (`LXMRouter.py:1034-1050`).
      **ReTiCA users appear unnamed in every reference client** (Sideband, NomadNet), and we can
      never advertise a required stamp cost. *Verified `46e838e`.*
- [ ] **Delivery stamps not wired** — all PoW primitives exist (`LXStamper.swift`,
      `LXMessage.swift`) but `validateStamp` **has no caller** and `send` never generates one.
      Any peer running `enforce_stamps()` drops every ReTiCA message (`LXMRouter.py:1875-1877`).
      *Verified `46e838e`.*
- [ ] **`setNodeMode(false)` never re-announces** — `LXMFServiceNode.swift:111` returns `.none`, so
      the last announce on the network still says `nodeState: true`. Reference re-announces
      immediately and peers unpeer on it (`LXMRouter.py:692-694` → `:338-345`, `Handlers.py:98-99`).
      Peers keep syncing into a node that drops everything.
- [ ] **LXMF tickets — entirely absent.** Zero `ticket` hits in `Sources/`. No stamp-cost exemption
      in either direction; an inbound `FIELD_TICKET` survives round-trip but is never acted on.

## Tier 4 — durability

- [ ] **Nothing in the transport core persists.** No path table, announce cache, packet-hash list,
      or known-destination store. Reference persists all of them (`Transport.py:3291-3504`,
      `Identity.py:176-239`).
- [ ] **Cold start causes duplicate message delivery.** `LXMFRouter.seen` and
      `downloadedTransientIds` both reset, so the next PN sync re-downloads everything the node
      still holds and re-delivers it as new. Reference avoids this with `local_deliveries` /
      `locally_processed`. **On iOS the process is killed constantly, so this is the normal path.**

## Tier 5 — capability and throughput

- [ ] **One transport at a time** — `TransportEndpoint.State` is an enum. No "internet when
      available, BLE when not". The `Transport` core is already multi-interface-capable
      (`State.interfaces` is a dictionary); the **composition layer** is not. Largest capability gap.
- [ ] **Resource window capped at the slow ceiling** — `ResourceWindow.swift`: `maxWindowSlow = 10`
      vs reference's `WINDOW_MAX_FAST = 75`. A **7.5× throughput ceiling** on any link fast enough
      to qualify — every TCP link and most BLE.
- [ ] **Link MTU frozen at 500** — `Link.swift:16-21`. No negotiation, so no benefit from BLE's
      1196 or TCP's larger frames. Degrades correctly as a *terminus*; unsafe as a **relay**, where
      reference clamps the forwarded signalling (`Transport.py:1646-1668`).
- [ ] **>3 MB request/response cannot reach a reference peer** — reference splits *every* resource
      (`Resource.py:274-310`) so it enforces `adv.t > MAX_EFFICIENT_SIZE*3`;
      `LinkSession.sendRequest`/`sendResponse` never split. Our own gate was raised to compensate,
      which fixes ReTiCA↔ReTiCA only.

## Tier 6 — absent subsystems

- [ ] **`Channel` — fails LOUDLY, not gracefully.** `PacketContext.channel = 0x0E` is declared but
      has no case in `LinkSession.received`. A peer calling `link.get_channel()` gets no response,
      retries 5×, then **tears the link down** (`Channel.py:479-483`). Most gaps degrade; this one
      actively breaks.
- [ ] **`Buffer`** — downstream of `Channel`. Blocks `rnx`-style remote execution and any
      `BufferedRWPair` peer.
- [ ] **Non-link proofs / `PacketReceipt` / reverse table** (§1.6, deferred by decision) — a
      reference peer proving a plain DATA packet to a ReTiCA destination **always times out**, on a
      message we received fine. Also breaks proof relay *through* a ReTiCA node.
- [ ] **Tunnels** — no path restoration when a transport peer reappears; every TCP reconnect
      (backgrounding, cell↔Wi-Fi handoff) loses the peer's routes to us.
- [ ] **Interfaces: 2 of 15.** Material for iOS: **TCP server** (we can only dial out — two phones
      on one Wi-Fi cannot peer over IP), **AutoInterface** (zero-config LAN discovery), and
      **RNodeInterface over BLE** (LoRa hardware; the CoreBluetooth plumbing already exists).
- [ ] **Paper messaging** (`lxm://` URI, QR) — the encryption step it needs already exists.

## Tier 7 — security posture (no known live exploit, but real)

- [ ] **Ratchets are send-side only.** ReTiCA honours a peer's announced ratchet but never
      generates, rotates, persists or announces one. Consequences: **no forward secrecy for any
      inbound traffic** to a ReTiCA destination, and a **hard break with any peer calling
      `enforce_ratchets()`** — it drops everything we send, silently.
- [ ] **Resources are the last unbounded allocation, and they defeat the link cap.** No
      `resource_strategy`, no `ready_for_new_resource()` gate, no per-link transfer cap. One held
      link still buys unbounded growth; and because eviction skips transfer-bearing links, a peer
      that advertises a resource and never sends a segment becomes **eviction-immune**.
- [ ] **No `accepts_links` policy** — no per-destination allow/deny. Quantity is now capped
      (a divergence in our favour; reference has no cap at all), but any peer may still open a link
      to any registered destination.
- [ ] **No path-request rate control** — fresh random tags pass the `discoveryPrTags` ring every
      time, each drawing a cached response or a recursive fan-out.

---

## Slices

| Slice | Covers | Plan | Status |
|---|---|---|---|
| Interop & crashes | Tier 1 | `2026-08-14-lxmf-interop-data-loss.md` | **in progress** |
| Wire-input trap sweep | Tier 2 | `2026-08-12-wire-input-trap-sweep.md` | 5/10 |
| Link liveness remainder | — | `2026-08-11-link-liveness-remainder.md` | ⚠️ do-not-execute; needs rework |
