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
| **Adversarial robustness** | ~18 remotely-reachable aborts closed, plus two fail-opens, one unkillable-work DoS and one wire-sized allocation. Tier 2 is **clear**; the wire-input trap sweep is complete. Still absent: admission control, and any bound on `LinkPlane.state.links` / `LinkSession.state.transfers`. |
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

## Tier 2 — remotely reachable crashes (nine closed, Task 5 only partly)

*Plan: `2026-08-12-wire-input-trap-sweep.md` — **10/10 tasks executed; 9/10 defects fully closed**.
Task 5 is partly closed and is detailed two paragraphs down — this heading deliberately does not
say "all closed", because an earlier draft did and that is the overclaim the whole-branch review
had to correct.*
*Gate status: **zero known-open conversions** — `--fail-on-open` exits 0. But **five of the sweep's
nine defects were not conversions** (Tasks 3, 4, 5, 9, 10), and the gate is structurally blind to
every one: it is a lexical checker for one defect shape. Read it as "no unreviewed narrowing
conversion in `Sources/`", never as "input handling is safe". For those five, the named tests are
the only regression guard — see `docs/wire-narrowing-inventory.md`, "Not detectable by this check".*

*One of the ten is **only partly closed**, and the tier heading should not be read as covering it.
**Task 5** (proof-of-work ordered before a cheap check, in the propagation ingest path) closed a
**replay** flood — measured 10 328x on the production packet path, which routed around the first
version of the fix entirely — but did **not** close the **junk flood** it was scoped to: dedup skips
only entries already stored, which requires a previously valid stamp, so an attacker who never
produces one still costs 21.98 ms per 33-byte entry and **1.56 KiB/s saturates a core**. Reference's
defence there is a throttle, not a cheaper check (`propagation_sequential_validation`,
`LXMRouter.py:2274`), and we have no equivalent. Measured, not suspected; filed under Tier 7 with the
other admission-control gaps and detailed in `docs/wire-narrowing-inventory.md` § "Task 5, precisely".*

- [x] **Task 6 — `LXMFServiceNode.swift` `Int(raw)` (in `requestReceived`)** — `[[], [], float64(NaN)]` on a `/get`
      aborts. **No `/get` handler is registered, so no `RequestPolicy` gate applies** — any client.
      **Fixed** — `59f900e`: NaN/negative/infinite float → 0 (serve nothing); negative int → 0
      (not nil/unlimited). Also closes the `.int` fall-through divergence opened by `177da8c`.
      `aca7453` later closed the same fall-through for `.float` (msgpack `0xCA`), found by the
      whole-branch review — the identical defect one `case` over, in a switch whose own comment
      already documented the shape for `.int`.
      **Still open, same class, three more types.** `.string`, `.bin` and `.bool` also fall to
      `default: break` → `nil` = **no cap**. I verified by running stock CPython 3.12 that
      reference's `float(data[2])` (`LXMRouter.py:1528`, LXMF 1.1.0) accepts all of them —
      `float("500")`, `float(b"500")`, `float(bytearray(b"500"))` → `500.0`, `float(True)` → `1.0` —
      so reference applies a cap where we apply none. Note the fall-through is *correct* parity for
      types `float()` genuinely rejects (a list, a map): reference's bare `except: pass` also leaves
      the limit unset there. The gap is exactly the four types it accepts. Low severity (no
      legitimate client sends them, and the cost is serving uncapped rather than a crash), but this
      is now the **third** time this switch has fail-opened by fall-through — the fix worth making is
      structural: enumerate exhaustively so a new `MsgPackValue` case cannot silently mean
      "unlimited".
- [x] **Task 7 — `PNAnnounce.swift:56-59`, six `Int(UInt64)` (in `PNAnnounce.parse`)** — a 21-byte
      app-data blob aborts. `PNAnnounce.isValid`, the *validity predicate*, crashed on the input it
      exists to reject. **Fixed** — all six `Int(x)` replaced with `Int(exactly:)` guard-returning
      `nil`; any single bad field fails the whole predicate, matching reference's per-field
      `try/except` shape in `pn_announce_data_is_valid` (LXMF.py:224-250). Reject, not truncate.
      Commit: see Task 7 report.
- [x] **Task 8 — `ResourceTransfer.swift` `Int(chunkIndex)` (in `ResourceTransfer.reduce`, `.resourceHashmapUpdate` case)** — traps twice, at the
      conversion *and* the multiply. **Fixed** — `guard chunkIndex <= UInt64(Int.max) / hmProduct`
      added before the conversion, bounding the product. Reject semantics: a large chunkIndex
      violates the contiguity invariant. Commit: see Task 8 report.
- [x] **Task 9 — unkillable proof-of-work driven by an unauthenticated wire value** — **two** sites,
      not the one the plan named: `LXStamper.generatePnStamp` (cost from `LXMFNode.propagationStampCost`,
      i.e. a wire PN announce) and `LXStamper.generatePeeringKey` (cost from the peer's advertised
      peering cost, via `PNNode.syncToPeer` → `PNNode`'s `linkEstablished` branch). Both were a bare
      `while true` inside an uncancellable `.run`. **Fixed** — three independent guards, each of which
      the others do not cover:
      1. **Cost ceilings.** `LXMFPropagation.maxPeeringCost = 26` is exact reference parity
         (`LXMRouter.MAX_PEERING_COST`, LXMRouter.py:51) *including the shape* — `LXMRouter.peer`
         (LXMRouter.py:2005-2010) refuses to peer rather than clamping, and clamping would be a silent
         failure (a key below the peer's demand is one it rejects, LXMPeer.py:228-233). We refuse in
         both `PNNode.syncToPeer` and the `linkEstablished` branch where the search starts.
         `maxPropagationStampCost = 20` is a **documented divergence**: reference bounds this nowhere
         (`LXMRouter.get_outbound_propagation_cost`, LXMRouter.py:421-442, returns the announced value
         verbatim; `pn_announce_data_is_valid`, LXMF.py:238-239, only checks it is int-able), relying on
         cancellation alone. 20 is the equal-work counterpart of reference's sanctioned 26 over the 40x
         larger PN workblock, and clears `PROPAGATION_COST + PROPAGATION_COST_FLEX` = 19.
      2. **Cooperative cancellation in the loop.** `LXStamper.search` now tests `Task.isCancelled` each
         round and returns nil, mirroring `LXStamper.job_simple` (LXStamper.py:199-206). A `CancelID`
         alone does not stop a synchronous loop — it only suppresses delivery of its result.
      3. **The loop yields.** A search that never suspends occupies its executor outright, so the
         cancellation can never be *delivered*: measured at **267 s** for a cost-26 peering search
         inside a `TestStore` that had explicitly cancelled it. Reference sidesteps this by generating
         in separate threads/processes; `await Task.yield()` every 32 rounds is the equivalent here.
      Cancelled at: `LXMFNode.cancelPropagationStamps` (explicit) and `LXMFNode.setPropagationNode`
      (the in-flight stamp was sized to the old node's cost); `PNNode`'s `linkClosed` and
      `requestFailed` branches (the key is only usable in an `/offer` on that link). The third
      generator, `LXStamper.generateStamp`, has **no production caller** — delivery stamps are unwired
      (Tier 3) — and is made cancellable defensively; when they are wired, its cost must be bounded
      where the peer's advertised `stamp_cost` is read. No emitted bytes change. Commit `3e919ed`.
- [x] **Task 10 — decompression allocates the ceiling, not the content** (in `Bzip2.decompress` /
      `Bzip2.decompressReportingAllocation`, reached from `ResourceTransfer.reduce`'s
      `.resourceHashmapUpdate`→assemble branch): 41 bytes could drive a 64 MiB allocation,
      repeatable per advertisement. **Fixed** — `7209fb7`. The one-shot
      `BZ2_bzBuffToBuffDecompress` *requires* the destination buffer before any output exists, so
      the wire's `d` field sized the allocation. Now incremental
      (`BZ2_bzDecompressInit`/`BZ2_bzDecompress`/`BZ2_bzDecompressEnd`, already vendored): the buffer
      starts at `max(4096, compressedInput.count)`, doubles as output is produced, and is capped by
      `expectedSize`. Peak allocation therefore tracks **content** (within 2x from the doubling),
      never the claim.
      Reference reading **confirmed, not inherited** — `Resource.assemble` (RNS/Resource.py:690-696,
      identical in the 1.4.1 fork and stock 1.4.2) does
      `decompressor.decompress(data, max_length=self.max_decompressed_size)` then `if not
      decompressor.eof:` → CORRUPT + `cancel()`. So "cap reached with input remaining" is a
      **failure**, not a truncated success; we return nil, never a partial buffer. One divergence
      worth recording: reference's cap is always the 64 MiB constant
      (`max_decompressed_size = AUTO_COMPRESS_MAX_SIZE`, RNS/Resource.py:360), whereas ours is the
      per-resource `d`, which is *tighter* — and `d` is an **upper bound, not an exact size**, since
      the split branch passes `min(adv.dataSize, maxEfficientSize)` where `adv.dataSize` is the whole
      object's. Requiring an exact fit would have capped every multi-segment transfer silently.
      `Bzip2.compress` is untouched (blockSize100k 9 / workFactor 0 stay byte-exact vs
      `bz2.compress(x, 9)`), and no emitted byte changes: this is receive-side only. The gate cannot
      see this defect — `Bzip2AllocationTests` plus
      `ResourceTransferTests.compressedSplitSegmentRoundTripsWhenDeclaredSizeExceedsSegmentOutput`
      are its only regression guard.

## Tier 2b — the amplifier, and a live data-loss vector in its own right

*Originally filed as "not a defect on its own". **That was wrong** — see the correction inside the
item. It is both the thing that turns decode bugs into remote aborts, and a silent-loss vector of
exactly the class Tier 1 just closed.*

- [x] **`LXMessage.validateSignature` re-encodes unconditionally.** Reference validates against the
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
         `unpack_from_bytes` re-packs only when `len(unpacked_payload) > 4` (`LXMessage.py:755-758`),
         so with no stamp `packed_payload` **is** the received slice and `signed_part` (`:764`) is
         built from it. We always rebuild via `payloadBytes(...)` (`LXMessage.swift`, in
         `validateSignature`). So a legitimate sender whose packing differs from ours **in
         any single byte** fails validation and `LXMFRouter.received` drops the message — the same
         silent-loss class as the Tier 1 defects, not a hypothetical.
      2. **Fixing `validateSignature` alone would narrow the coupling, not remove it.** Two paths
         survive: (a) the **stamped** path, where reference itself re-packs `payload[:4]`, so
         canonical re-encode is still required there; and (b) our `packed` property recomputes from
         fields, whereas reference stores `message.packed = lxmf_bytes` (`:798`) and
         **re-transmits the received bytes**.

         ~~so a ReTiCA propagation node *forwarding* a message still depends on byte-exact
         re-encode.~~ **That clause was wrong about the mechanism** — caught by Task 2's review,
         and left visible here rather than quietly deleted because it is the third overclaim of
         this shape in a week. ReTiCA's propagation node **never decodes to `LXMessage` at all**:
         `PropagationStore.swift` and `PropagationNode.swift` contain zero references to it, and
         the PN stores and serves raw container `Data` keyed by `transient_id`. Something that
         never decodes cannot re-encode. The real exposure was the **client relay**: an app
         re-sending a message it received, via `LXMFNode.sendMessage` (`LXMFNode.swift:56`, handled
         `:133-149`, which takes a *caller-supplied* `LXMessage`), reaches `opportunisticPayload`,
         `directRepresentation` and `LXMFPropagation.pack` — all four of which read `packed`, so
         every forwarded message was re-encoded and its signature invalidated for the next hop.

      **Fixed in two tasks — both entry points closed:**

      - `validateSignature` (`LXMessage.swift`): **Task 1**, commit **`c0638fc`**.
        Uses `receivedBytes` for non-stamped inbound messages, re-packs for stamped messages
        exactly as reference does at `LXMessage.py:758` — canonical encoding remains required on
        the stamped path, by design, not oversight.
      - `packed` (`LXMessage.swift`): **Task 2**, commit **`bd51a33`**. Returns
        `receivedBytes` when present (mirroring `message.packed = lxmf_bytes`, `LXMessage.py:798`),
        re-encodes from fields for locally-created messages (`receivedBytes == nil`). The stamped
        path still requires canonical encoding: `withStamp` constructs a new message **without**
        threading `receivedBytes` through (commented at the construction site,
        `LXMessage.swift`, in `withStamp`) so `packed` falls back to re-encoding and includes the
        stamp.

        That is parity, and the reason is structural rather than about storage. *An earlier
        revision of this line said "the stamped wire form is never stored; it is assembled fresh at
        each send" — wrong on both halves: reference sets `message.packed = lxmf_bytes` including
        the stamp (`:798`) and caches in `pack()` (`:381-386`), and `pack()` opens with
        `if not self.packed:` (`:356`) so it does not reassemble per send.* The actual reason:
        `get_stamp()` (`:296`) is called from exactly one place, `pack()` at `:372`, and `pack()`
        no-ops when `self.packed` is already set — so **reference structurally cannot stamp a
        message it received**, because receiving is what sets `packed`. Our `withStamp` dropping
        `receivedBytes` therefore cannot diverge from it.

      **Reachability, stated honestly:** no path inside `Sources/` closes the receive→send loop
      today. `LXMFRouter.received` reconstructs, validates and delivers without packing; every
      `packed` consumer is reached only from `.send`/`.sendViaPropagation`, which inside the library
      are fed only `LXMessage.create` products. The fix takes effect one app-level hop away, for
      callers of `LXMFNode.sendMessage` or `LXMFPropagation.open`. Task 1's half was live; Task 2's
      is latent-but-reachable. *Remaining gap: no test above `LXMessage` exercises the relay seam —
      filed below.*

## Tier 3 — identity and anti-spam interop

- [x] **No delivery-announce app data** — `LXMFNode.swift:92` announces `appData: nil`.
      Reference packs `msgpack([display_name, stamp_cost, [SF_COMPRESSION]])` (`LXMRouter.py:1034-1050`).
      **ReTiCA users appear unnamed in every reference client** (Sideband, NomadNet), and we can
      never advertise a required stamp cost. *Verified `46e838e`.*
      **Fixed in four commits (plan `2026-08-15-lxmf-delivery-announce-app-data.md`):**
      - `08356e4` — `LXMFAnnounceData.pack` / `LXMFAnnounceData.parse` codec, byte-cross-validated
        against genuine LXMF 1.1.0 output (Tasks 1–2).
      - `eb0abd5` — `LXMFNode.registerDelivery` now packs real app-data instead of `nil`; reference
        `get_announce_app_data` (`LXMRouter.py:1034-1050`) always packs, even when both name and cost
        are absent, so we match that (Task 3). **ReTiCA users are now named in Sideband/NomadNet.**
      - `dcb543f` + `2ab55ac` — `LXMFNode.State.learnedPeers` records each LXMF delivery peer's
        `displayName`, `stampCost` and `supportsCompression` on `pathLearned`, gated on
        `LXMessage.deliveryHash(identityHash:)` to match reference's own destination-hash dispatch
        (`Transport.py:2077-2086`, RNS 1.4.2; `Handlers.py:11` aspect filter) (Task 4).

      **What this slice does NOT close — stated plainly:**

      - **Delivery stamps remain entirely unwired.** `LXStamper.generateStamp` has no production
        caller. `LXMFNode.send` never generates a stamp; `LXMFRouter.received` never validates one.
        Any peer running `enforce_stamps()` drops every ReTiCA message (`LXMRouter.py:1875-1877`).
        This slice *learns* a peer's advertised stamp cost and stores it in `learnedPeers.stampCost`,
        but never spends it. The delivery-stamps item below remains open.

      - **`learnedPeers` is still unbounded.** The `deliveryHash` gate narrows the table from "every
        destination ever heard" to "every LXMF delivery peer ever heard" — a reduction, not a bound.
        This is already filed under Tier 4 ("LXMFNode.State.learnedPeers is never collected"); the
        tick here does not close that item.

- [ ] **Delivery stamps not wired** — all PoW primitives exist (`LXStamper.swift`,
      `LXMessage.swift`) but `validateStamp` **has no caller** and `send` never generates one.
      Any peer running `enforce_stamps()` drops every ReTiCA message (`LXMRouter.py:1875-1877`).
      *Verified `46e838e`.* See delivery-announce tick above — learning a peer's cost (Task 4) is
      a prerequisite; spending it safely (bounded PoW, ceiling enforcement) is the remaining work.
- [x] **`setNodeMode(false)` never re-announces** — `LXMFServiceNode.swift` `setNodeMode` returned
      `.none` on disable, so the last announce on the network still said `nodeState: true`. Reference
      `disable_propagation` (verified against stock LXMF 1.1.0, `LXMRouter.py:692-694`) sets
      `self.propagation_node = False` then calls `announce_propagation_node()` (`LXMRouter.py:338-345`,
      in `announce_propagation_node`), which packs `node_state = False` and re-announces. Peers act
      on that: `Handlers.py:98-99` (`received_announce`) calls `unpeer(destination_hash)` when
      `propagation_enabled == False`. Reference announces on **both** transitions — `enable_propagation`
      (`:685`) and `disable_propagation` (`:694`); our `setNodeMode(true)` already re-announced via
      `registerPropagation`, so only the disable path was missing.
      **Fixed `32e39ca`** — `setNodeMode` in `LXMFServiceNode`, disable branch: guard on
      `state.client.propagationDestinationHash` (no-op when `registerPropagation` was never called),
      then emit `.client(.endpoint(.announce(destinationHash:appData:)))` with `nodeState: false`.
      Two new tests pin both directions: `serviceNodeDisableReAnnouncesWithNodeStateFalse` (asserts on
      parsed `PNAnnounce.nodeState`, not on `state.nodeModeEnabled`) and
      `serviceNodeDisableWithoutPriorRegistrationDoesNotAnnounce` (exhaustive teardown catches any
      stray announce when no destination is registered). Mutation-verified: three mutations, each
      breaks exactly the test it should. 952 tests, 121 reviewed conversions, zero known-open.
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
- [ ] **`LXMFNode.State.learnedPeers` is never collected — the deferred risk is GROWTH, not staleness.**
      Reference expires `outbound_stamp_costs` entries older than
      `STAMP_COST_EXPIRY = 45 * 24 * 60 * 60` seconds in `clean_outbound_stamp_costs`
      (`LXMRouter.py:1272-1281`, LXMF 1.1.0). We store each entry's `learnedAt` so the same expiry
      can be added without a schema change, but no cleanup runs.
      **Staleness is the benign half** — a fresh announce overwrites the entry, and nothing spends
      the value today. **Unbounded growth is the real gap:** one entry per distinct `lxmf.delivery`
      destination ever heard, retained after the transport has expired the path that produced it.
      `Transport.maintenanceTick` sweeps `Transport.State.learned` and deliberately piggybacks
      `announceBlobs` and `announceCache` on it (`Transport.swift`, the `.maintenanceTick` case);
      `learnedPeers` joins none of them, because it lives in `LXMFNode.State` and no path-expiry
      delegate crosses the `TransportEndpoint` boundary. Closing this wants either a new
      `.delegate(.pathExpired)` emitted from both transports, or a sweep driven from `LXMFNode`.
      *An earlier revision of this entry called the gap low-impact on the grounds that no stale
      entry causes a wrong outcome. That was true of correctness and silently dropped the growth
      mode — which the delivery-hash gate bounds to LXMF peers but does not close.*
      *Filed 2026-08-15.*

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
- [ ] **The relay seam has no test above `LXMessage`** (filed from Tier 2b, Task 2's review).
      Byte-preserving forward is pinned only at the `LXMessage` unit level; every `LXMFNode` test
      passes an `LXMessage.create` product, so the receive→re-send path — the one the Tier 2b fix
      exists for — is unexercised end to end. Wanted: drive
      `.router(.received(method: .direct, …, data: nonCanonicalWire))`, take the message off
      `.delegate(.messageReceived)`, feed it to `.sendMessage(message:alsoViaPropagation: false)`,
      and assert the emitted `.endpoint(.send(plaintext:))` equals `nonCanonicalWire.dropFirst(16)`.
      **Trap for whoever writes it:** `LXMessage.==` deliberately excludes `receivedBytes`, so a
      TestStore *state* assertion on `outboundQueue` compares equal no matter which bytes are
      carried — assert on the delegate payload, not on state, or the test will be vacuous.
- [ ] **No path-request rate control** — fresh random tags pass the `discoveryPrTags` ring every
      time, each drawing a cached response or a recursive fan-out.
- [ ] **Propagation stamp validation is unthrottled — the residue Task 5 could not close.** A peer
      that never produces a valid stamp is never stored, so the dedup preflight never matches it and
      it pays a full 256 KB workblock every time: **21.98 ms per 33-byte entry, 1.56 KiB/s saturates
      one core**. Reachable by anyone who can open a link to the propagation destination
      (`nodeModeEnabled` + `isPropagationLink`, no identity check). Reference bounds this with
      `propagation_sequential_validation` / `validating_pn_stamps_from` — an offer is refused with
      `ERROR_THROTTLED` while another peer's batch is validating (`LXMRouter.py:2274`, `:2398`) — and
      also spreads validation across processes (`validate_pn_stamps_job_multip`, `LXStamper.py:106`).
      We have neither. Plan together with: the double validation of every accepted entry (a parity
      regression — reference validates once, `LXMRouter.py:2243-2249`), the unbounded
      `LinkSession.state.transfers`, and `PNNode` defaulting `storageLimitBytes` to nil.

---

## Slices

| Slice | Covers | Plan | Status |
|---|---|---|---|
| Interop & crashes | Tier 1 | `2026-08-14-lxmf-interop-data-loss.md` | **in progress** |
| Wire-input trap sweep | Tier 2 | `2026-08-12-wire-input-trap-sweep.md` | 9/10 |
| Link liveness remainder | — | `2026-08-11-link-liveness-remainder.md` | ⚠️ do-not-execute; needs rework |
