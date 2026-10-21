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
| **Durability** | Present for what a restart notices. The **LXMF layer** persists dedup sets and learned stamp costs, so a restart no longer re-delivers every message or sends unstamped to every peer; the **transport path table** persists too, so a restart can route immediately instead of waiting for re-announces. Still transient by decision, not omission: the 8.4 MB packet-hash ring, the announce cache, and tunnels — see Tier 4 for what each costs. |
| **Breadth** | 3 of 15 interfaces (TCP client, BLE, TCP server — server added by lib `f363dff` + app `5e77ebb`, though a listener is not auto-discoverable without AutoInterface and accepts unbounded connections); no `Channel`/`Buffer`, tickets, tunnels, or non-link proofs. |

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

- [x] **No delivery-announce app data** — `LXMFNode.registerDelivery` *announced* `appData: nil`.
      Reference packs `msgpack([display_name, stamp_cost, [SF_COMPRESSION]])` (`LXMRouter.py:1034-1050`).
      **ReTiCA users appeared unnamed in every reference client** (Sideband, NomadNet), and we could
      never advertise a required stamp cost. *Verified `46e838e`.*
      **Fixed in four commits (plan `2026-08-15-lxmf-delivery-announce-app-data.md`):**
      - `08356e4` — `LXMFAnnounceData.pack` / `LXMFAnnounceData.parse` codec, byte-cross-validated
        against genuine LXMF 1.1.0 output (Tasks 1–2).
      - `eb0abd5` — `LXMFNode.registerDelivery` now packs real app-data instead of `nil`; reference
        `get_announce_app_data` (`LXMRouter.py:1034-1050`) always packs, even when both name and cost
        are absent, so we match that (Task 3).
        **ReTiCA *can* now be named in Sideband/NomadNet — the app must supply the name.**
        ~~ReTiCA users are now named in Sideband/NomadNet.~~ That claim was false as shipped and is
        struck rather than deleted, because it is the fourth "summary wider than its evidence" in a
        week and the pattern is worth more than the correction. `State.displayName` defaults to nil,
        so `registerDelivery` alone emits `93c0c09100`, and a whole-branch probe fed exactly those
        bytes to genuine LXMF 1.1.0 and got `display_name: null` — a reference client still shows the
        node unnamed. Naming requires seeding `State.displayName` or calling `.setDisplayName`, and
        no caller in this workspace did yet: grepping ReTiCaMsgr returned zero hits for `setDisplayName`.
        The slice delivered the **capability**; the **outcome** needed one app-side line.
        **Task 3 (2026-08-16 slice):** ReTiCaMsgr now calls `.setDisplayName("ReTiCaMsgr", stampCost: nil)`
        before `.registerDelivery` in `AppFeature.interfaceConnected` so the registration announce carries
        the name. **PROVISIONAL constant** — ReTiCaMsgr has no user-facing name entry UI; `"ReTiCaMsgr"`
        is a placeholder until a name field is added. Reference clients (Sideband, NomadNet) will now
        show the node as `"ReTiCaMsgr"` rather than unnamed. ReTiCaMsgr commit `0a3d026`.
        **The name does NOT identify the user, and this tick should not be read as if it did.** The
        constant is the same string for *every* ReTiCaMsgr install, so in a Sideband contact list all
        ReTiCA peers are mutually indistinguishable — the field now says which *app* is running, not
        who is running it. That is still better than blank (reference clients render an unnamed peer
        as a bare hash), but "ReTiCA users are now named" remains false in the sense a reader cares
        about. Saying only "PROVISIONAL" left that inference available; this sentence closes it.
        **Pinned since the branch-review pass** by `interfaceConnectedSetsTheDisplayNameBeforeRegisteringDelivery`
        (ReTiCaMsgr `AppFeatureTests`), which asserts the name *and* that it precedes
        `.registerDelivery`. Before that test, deleting the `.setDisplayName` line left the whole
        ReTiCaMsgr suite green: `grep displayName AppFeatureTests.swift` returned zero hits, and both
        `interfaceConnected…` tests use predicate-`receive`, which skips non-matching actions.
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

- [x] **Delivery stamps wired** — outbound generation and inbound validation are both wired.
      *Task 1 (2026-08-16 slice)*: `LXMFNode.deliverySend` generates a stamp when the peer's
      `lxmf.delivery` announce carries a cost ≤ `maxDeliveryStampCost = 20`; the search is
      cancellable via `CancelID.deliveryStamp`; a **refused** cost (0, or above the ceiling) sends
      unstamped rather than dropping. Commits: `09c44a0` (initial generation), `8a84fd3` (fix ceiling
      and send path — `LXMFNode.deliverySend` is the correct call site, not `LXMFNode.send`).
      **A CANCELLED search does not send unstamped — it fails the message, and must.** This entry,
      and the docstring it was copied from, previously claimed the opposite. TCA suppresses every
      action sent from a cancelled effect (`Send.callAsFunction`'s `guard !Task.isCancelled`,
      ComposableArchitecture `Effect.swift:191-194`), so the substitute unstamped send was a no-op
      and the `else` branch implementing it was dead code — `.cancelDeliveryStamps`, which documents
      itself as "call when the app backgrounds", silently discarded every in-flight message with no
      delegate at all. Now `.cancelDeliveryStamps` emits `.delegate(.deliveryFailed(messageHash:))`
      for every entry in `State.inFlightDeliveryStamps`, matching reference, which reports the same
      cancellation from its own uncancelled router loop (`process_deferred_stamps` →
      `failed_callback`, `LXMRouter.py:2620-2625`; generation failure → `fail_message`, `:2627-2630`).
      Fixed `de50cce`.
      *Task 2 addendum (branch-review pass, `1cd6a2d`)*: the cost the inbound half validates against
      is now **range-sanitised at the setter**, matching `set_inbound_stamp_cost` (LXMRouter.py:378-392,
      LXMF 1.1.0): nil and `< 1` clear it, `1...254` store it, `>= 255` is rejected with the previous
      value kept. It had been stored raw while `LXMFAnnounceData.pack` applied reference's
      `> 0 && < 255` emit gate, so the announce and the enforcement disagreed — cost 0 advertised
      "no cost required" and then failed every unstamped message (dropped, under enforcement), and
      cost -1 reported an all-0xFF stamp as **valid** to the app, because `stampValid` is
      `stampValue >= targetCost` and a bit count is never negative. Unreachable from ReTiCaMsgr
      today (it passes `stampCost: nil`), so this was a public-API footgun rather than a live bug.
      *Task 2 (2026-08-16 slice)*: `LXMFNode` validates the stamp on every inbound
      `messageDelivered` when `State.deliveryStampCost != nil`, and carries the outcome on the
      message as `LXMessage.stampValid`/`stampChecked` — mirroring reference, which stores the same
      pair on the object (`LXMessage.py:157-158`) and assigns it at `LXMRouter.py:1865-1869`.
      `State.enforceDeliveryStamps` (default `false`, matching `LXMRouter.__init__` LXMRouter.py:99)
      gates the drop: with enforcement on an invalid/absent stamp is dropped (`return .none`,
      reference `return False` at LXMRouter.py:1877); with enforcement off the message is delivered
      flagged checked-and-invalid (reference's else-branch, LXMRouter.py:1878-1879).
      Commits: `b652df8` (validation), `9a3b64f` (surface stamp result via `stampValid`/`stampChecked`).

      **Scope of this tick, stated precisely.** What is wired is *validation and reporting*: every
      inbound message now arrives carrying an honest tri-state (never-checked / checked-valid /
      checked-invalid) that an app can render.

      **What this tick does NOT close:**

      - **The whole INBOUND half is dead in the shipping app — not just enforcement.** An earlier
        revision of this bullet said only that *enforcement* was test-only, which understated it.
        ReTiCaMsgr's sole `setDisplayName` call passes `stampCost: nil`
        (`AppFeature.swift:109`), so `State.deliveryStampCost` is nil, the `if let cost` gate in the
        `messageDelivered` branch never opens, `validateStamp` never runs, and **every delivered
        message reaches the app with `stampChecked == false`** — the never-checked leg of the
        tri-state, on every message, always. What Task 2 shipped is a correct mechanism with no
        caller. Turning it on is one argument at that call site (plus a UI to choose the value).

      - **Enforcement is test-only, additionally.** `enforceDeliveryStamps` defaults false and **no
        caller in this repo or in ReTiCaMsgr sets it true**, so the drop branch is reachable only
        from tests today. Enabling it also exposes the ticket divergence below — reference accepts
        ticket-backed stamps that we reject (`LXMessage.py:273-283` checks `truncated_hash(ticket +
        message_id)` regardless of cost; we have no ticket path).

      - **The outbound ceiling means we decline to stamp for demanding peers.** `maxDeliveryStampCost = 20`
        (`LXMFNode.swift`): when a peer's announced `stamp_cost` exceeds 20 we send unstamped.
        Reference has no default delivery stamp cost and accepts 1–254 (`register_delivery_identity`,
        `LXMRouter.py:348`; `set_inbound_stamp_cost`, `LXMRouter.py:378-388`), so any conforming
        peer advertising 21–254 will receive our messages unstamped. If that peer enforces stamps,
        it drops them. **Which peers this affects:** peers that call `set_inbound_stamp_cost` with a
        value above 20 — an uncommon but legitimate configuration, not a hostile one.

      - **No propagation-bound message carries a delivery stamp — via EITHER path.**
        `.sendMessage(fallbackToPropagation: true)` packs the unstamped message into the propagation
        container (`LXMFPropagation.pack` is called on the original `LXMessage`), and so does
        **`.sendViaPropagation(destinationHash:title:content:)`**, which builds its own message with
        `LXMessage.create` (never stamped) and hands it straight to `pack`. The bullet previously
        named only the first; the second has the identical gap and no mitigation, so a
        stamp-enforcing recipient reached only through a propagation node drops the message either
        way. Deferred deliberately: wiring it requires collapsing two concurrent async stamp searches
        (delivery + propagation) into a sequential chain with its own cancellation ordering.
        Documented in `LXMFNode.swift` at the `.sendMessage` call site (commit `d3e19d2`).

      - **A peer's advertised stamp cost is forgotten at every app launch.** `LXMFNode.State.learnedPeers`
        is populated only from a live announce (`pathLearned`), is never persisted, and is never
        expired. Reference does both: it writes `outbound_stamp_costs` to
        `storagepath/outbound_stamp_costs` on every update (`save_outbound_stamp_costs`,
        `LXMRouter.py:1287-1296`, called at `:1032`), reloads it at startup (`:267-277`), and expires
        entries older than `STAMP_COST_EXPIRY = 45 * 24 * 60 * 60` (`:39`, swept at `:1272-1281`).
        **The consequence is exactly the failure this slice exists to fix:** after every launch —
        and on iOS the process is killed constantly — ReTiCA sends *unstamped* to every peer until it
        happens to re-hear that peer's announce, and a peer running `enforce_stamps()` drops all of
        it. The generation logic is correct and simply has nothing to spend. Growth/expiry is filed
        under Tier 4; **persistence is the half that undermines the tick above**, and neither is done.

      - **LXMF tickets remain absent** (Tier 3's fourth item — separate entry below). Enabling
        enforcement exposes this gap explicitly.

      988 tests; **zero known-open *conversions*** (this checklist's gate metric).

      **What a green `swift test` actually prints, measured — because this line has now been wrong
      twice in opposite directions.** A full run reports `988 tests in 7 suites failed ... with 3
      issues (including 1 known issue)`. Both non-conversion items are expected and neither is a
      regression:

      - **1 known issue, at `TransportTests.swift:3943`** — in
        `holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood`. The original wording of this line,
        "a structural `skipInFlightEffects` known issue", was **right**, and a whole-branch review
        correction that replaced it with "no known-issue annotations exist; `:3943` is an ordinary
        teardown call" was **wrong** — on the strength of `grep -rin knownissue Tests Sources`
        returning nothing. That grep result is accurate and the inference from it is not: the
        annotation lives in TCA, not in our source. `TestStore._skipInFlightEffects` reports the
        cancelled-effects message with `overrideExhaustivity: .off(showSkippedAssertions: true)`
        whenever exhaustivity is `.on` (`TestStore.swift:2172-2187`), and that branch of
        `reportIssueHelper` wraps the report in `withExpectedIssue` (`TestStore.swift:2204-2218`) —
        which is precisely a known issue. The test flips `.on` and calls `skipInFlightEffects()` at
        `:3942-3943`, so it takes that path by construction. **Structural, unrelated to LXMF work,
        and not suppressible from here.** Verify a claim like this by *running the suite*, not by
        grepping our own tree for someone else's annotation.

      - **1 failing test, `pairedModePublishesWithEncryptionAndEncryptedReadPerms`**
        (`Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift:183`, 2 issues at `:191` and
        `:193`) — the FCB BLE driver adapter, an unrelated target with no LXMF dependency.
        **Measured over five full runs: it failed in four and passed in the fifth.** It also
        **passes in isolation** (`--filter pairedModePublishes…`, 0.21 s) and **passes with its whole
        file** (`--filter FCBDriverAdapterTests`, 16/16). One of the four failures was at base
        `57beaa6` with the delivery-stamp work stashed (982 tests, same two issues, same known
        issue), so it is **not** a regression from any LXMF change.
        So: a genuine intermittent, strongly correlated with full-suite load — which is what this
        line said before a branch-review pass had it as "load-sensitive rather than randomly flaky,
        fails on every full run". That sharpening was written after three failing runs and no
        passing one, and the fifth run falsified it within the hour. Recorded rather than quietly
        edited, because it is the same failure mode as the known-issue paragraph above: a claim
        stated wider than the evidence that produced it. **Do not re-sharpen this without a run
        count.**

      A run whose only failure is that FCB test is a green run for this checklist's purposes.
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

- [x] **Nothing in the transport core persists.** No path table, announce cache, packet-hash list,
      or known-destination store. Reference persists all of them (`Transport.py:3291-3504`,
      `Identity.py:176-239`).
      **The path table now persists** — plan `2026-08-21-transport-path-persistence.md`. Library
      `9667afe` adds `Transport.rehydrateLearnedDestinations([Data: LearnedDestination])`, which on
      restore refuses to overwrite a **fresher live** entry and **drops** malformed or future-dated
      timestamps rather than clamping them (clamping makes a future row look maximally fresh, hence
      immortal — a mistake made and caught by test in the preceding slice). App ReTiCaMsgr `5d2b33a`
      persists and replays it; `aa19115`/`cbe1845` export `Transport.pathExpiry` so the app prunes
      on the library's terms instead of mirroring the constant.
      **Write policy is debounced — dirty, at most every ~30 s, plus a flush on background** — which
      deliberately differs from the per-message policy used for LXMF durability. The reason is write
      *rate*, not principle: a delivered message is discrete and rare; `learned` updates on every
      announce that improves a path.

      **The rest of the transport core is still not persisted, and three of the four are deliberate:**

      - **Packet-hash ring — deliberate divergence.** `seenPacketHashes` is `seenPacketRingSize =
        262_144` ≈ **8.4 MB**; writing that on a 30 s debounce is untenable. Reference persists its
        *larger* equivalent (`hashlist_maxsize = 1_000_000`, `Transport.py:177`) but only on a
        **12-hour** timer, precisely because each write is expensive. The cost of losing ours is
        lower than reference's, too: `LXMFRouter.seen` persists at the LXMF layer, so a replayed
        *message* is still deduplicated. Losing the transport ring costs re-processing work and
        briefly reopens announce-loop damping — not data.
      - **Announce cache and announce blobs — a real divergence, not parity.** *An earlier draft of
        this entry was going to say reference does not persist its equivalents. It does*: cached
        announce packets are written per-hash under `cachepath/announces/`
        (`Transport.get_cached_packet`, `:2663-2675`), and reference's path-table **load depends on
        them** — an entry is skipped when `get_cached_packet` returns nil. We diverge harmlessly
        because our `LearnedDestination` rows are self-contained where reference's path entries are
        not. The cost is narrower: after a restart we cannot answer a path request from cache for a
        destination until we hear it announce again.
      - **Tunnels** remain absent entirely (Tier 6), so `save_tunnel_table` (`:3425`) has no analogue.
      - **The debounce loss window** is up to ~30 s of path learning, re-learned from the next
        announce.

      **Reference's own triggers, for whoever revisits the cadence:** a 12-hour timer in the jobs
      loop (`Reticulum.py:386-387`, `PERSIST_INTERVAL`), an opportunistic 5-minute-gated save when a
      shared-instance client disconnects (`_should_persist_data`, `:1187-1191`), and `exit_handler`
      (`Transport.py:3527`). **None transfers**: iOS rarely runs exit handlers, 12 hours is never
      before a kill, and we have no shared-instance disconnect.
      *Closed 2026-08-21.*
- [x] **Cold start causes duplicate message delivery.** `LXMFRouter.seen` and
      `downloadedTransientIds` both reset, so the next PN sync re-downloads everything the node
      still holds and re-delivers it as new. Reference avoids this with `local_deliveries` /
      `locally_processed`. **On iOS the process is killed constantly, so this is the normal path.**
      **Fixed** — plan `2026-08-17-lxmf-durability.md`. Library: `5459c49` adds
      `LXMFRouter.rehydrateDedup(seenHashes:downloadedTransientIds:)`. App: ReTiCaMsgr `bcbbef4`
      persists both sets (`SeenHashRow`, `DownloadedTransientIdRow`) and replays them from
      `AppFeature.onLaunch`; `eb5312d` pins the transient-id half, which `bcbbef4` persisted but
      no test observed — stubbing the launch read left all 49 tests green.
      **`seenHashes` must be supplied oldest-first**, and that contract is the fragile part: the
      reducer inserts one at a time into a `RingSet(capacity: 10_000)` which evicts at capacity, so
      reversing the order persists the newest 10 000 and restores the oldest — defeating the feature
      while every test passes. The app's `order(by: \.storedAt)` is what satisfies it.
- [x] **`LXMFNode.State.learnedPeers` is never collected — the deferred risk is GROWTH, not staleness.**
      Reference expires `outbound_stamp_costs` entries older than
      `STAMP_COST_EXPIRY = 45 * 24 * 60 * 60` seconds in `clean_outbound_stamp_costs`
      (`LXMRouter.py:1272-1281`, LXMF 1.1.0). We store each entry's `learnedAt` so the same expiry
      can be added without a schema change, but no cleanup runs.
      ~~**Staleness is the benign half** — a fresh announce overwrites the entry, and nothing spends
      the value today.~~ **That was true on 2026-08-15 and false on 2026-08-16**: the delivery-stamp
      slice made `LXMFNode.deliverySend` spend `learnedPeers[…].stampCost`. Staleness now means
      stamping at an outdated price, and **under**-paying gets us dropped by exactly the peers
      stamps exist for. Struck rather than deleted — it is a one-day-old instance of this file's own
      maintenance rule, and the seventh summary-wider-than-its-evidence in three weeks.
      **Unbounded growth is the real gap:** one entry per distinct `lxmf.delivery`
      destination ever heard, retained after the transport has expired the path that produced it.
      **Fixed** — library `5cfe1db` sweeps entries past `stampCostExpiry` during
      `.rehydrateLearnedPeers`, mirroring reference's startup sequence (load, then
      `clean_outbound_stamp_costs`, `LXMRouter.py:276`); `54fb7a2` stops a restored entry
      clobbering a *fresher* live one and drops malformed/future-dated rows; app `eb5312d` deletes
      expired rows from disk at launch, because the library can skip a row but cannot tell the app
      to forget it.
      **Two limits this does NOT reach, both inherited from reference:** the sweep runs only at
      rehydration, so a long-running **macOS** session never sweeps (reference has the same
      limitation — `clean_outbound_stamp_costs` has exactly one caller — but reference is a daemon
      and never faced a 45-day GUI session); and within a session growth is still uncollected,
      since no path-expiry delegate crosses the `TransportEndpoint` boundary. Closing the second
      still wants `.delegate(.pathExpired)` from both transports, or a sweep driven from `LXMFNode`.
      *An earlier revision of this entry called the gap low-impact on the grounds that no stale
      entry causes a wrong outcome. That was true of correctness and silently dropped the growth
      mode — which the delivery-hash gate bounds to LXMF peers but does not close.*
      *Filed 2026-08-15; closed 2026-08-21.*

*What this slice does NOT close — each checked against a run, not assumed:*

- **Transport-core persistence remains absent** (the item above this one). After a restart there
  are no known paths until announces arrive, so the first sends of a session may have nowhere to
  go. Ruled out of scope on 2026-08-17: losing paths costs *delay*, not correctness.
- **`downloadedTransientIdRows` is deliberately unbounded.** Disk is the only limit. Ruled
  2026-08-17 so that real usage can inform a cap rather than a guess — any cap trades storage
  against re-downloading old messages from a propagation node. **Accepted risk, not an oversight.**
  Revisit trigger: a report of the table growing uncomfortably, or operational data giving a
  representative steady-state size.
- **Writes happen per delivered message, not batched.** Chosen for durability because on iOS the
  process kill is routine, so a batch window is a routine loss window; reference likewise saves at
  each update rather than on a timer. Expected pull-back if write traffic bites: batch with a flush
  on `applicationDidEnterBackground` / `applicationWillTerminate`.
- **One library write-site the app cannot observe.** `LXMFRouter` inserts a hash into `seen`
  before `LXMFNode` drops a message whose delivery stamp is invalid under `enforceDeliveryStamps`,
  and that path emits no `.messageReceived` — so the hash is in `seen` but never in `seenHashRows`,
  and the ~60 ms validation is re-paid after a restart. **Latent only**: nothing sets a delivery
  stamp cost today, so the drop branch is unreachable. It becomes live the moment enforcement is.
- **The seen-hash write shares a transaction with the inbound message insert**, so a failing
  persist rolls back the chat message too. TCA reports the issue and drops the effect rather than
  crashing, but there is no retry and no user-visible signal.

## Tier 5 — capability and throughput

- [x] **One transport at a time** — CLOSED (lib `1d91913` Task 1b hoisted the shared
      `transport`/`linkPlane` into one `TransportEndpoint` container; `f363dff` added the TCP-server
      driver slot; earlier interface-conformance work `258dd94`/`d19f9e2`; app wired to the new
      surface in ReTiCaMsgr `5e77ebb`). `TransportEndpoint.State` is now a STRUCT product: one
      shared router + link plane, plus optional per-KIND driver slots (`tcpClient`, `tcpServer`,
      `ble`). Several drivers can be present at once, routing through the single shared `Transport`.
      The app now composes client + opt-in listener. NOT yet automatic ("internet when available,
      BLE when not"): slot presence is chosen by the app/config, there is no capability-based
      auto-selection between transports — the router picks the OUTBOUND interface per learned path,
      but nothing promotes/demotes whole transports by availability.
- [x] **Outbound Resource semantics** — CLOSED (`2026-09-27-transfer-aware-delivery-design.md`).
      A message sent as a Resource is no longer resent while its transfer runs (reference: a
      SENDING message is not resent, LXMRouter.py:2788-2796): `LXMFRouter` puts the copy in
      `.transferring` with no retry timer and lets the transfer decide — concluded → confirmed,
      failed → the link is torn down and one retry follows `DELIVERY_RETRY_WAIT` later on a fresh
      link, rejected (any RESOURCE_RCL at the sender) → terminal `deliveryRejected`
      (`LXMessage.__resource_concluded`, LXMessage.py:597-606). A link lost mid-transfer counts as
      a failed transfer. **Cancel:** `LXMFNode.cancelOutbound(messageHash:)` mirrors
      `LXMRouter.cancel_outbound` (LXMRouter.py:1719-1744): stamp searches for that message stop,
      a Resource in flight gets the standard RESOURCE_ICL, `deliveryCancelled` is reported once.
      **Progress:** `deliveryProgress` / `propagationProgress` on the reference scale (0.05 link
      active, 0.10 transfer start, `0.10 + 0.90 × progress`, 1.0 done — LXMessage.py:623-624) and
      `inboundTransferProgress` for arriving Resources; `LinkSession` reports per-transfer progress
      at whole-percent steps. Transfer traffic re-arms the router's 600 s link idle timer.
      **Deliberate divergence:** reference allows several concurrent Resources per link; we run
      one per link and queue the rest (`LXMFRouter.resourceQueue`), because `LinkSession` keeps a
      single split-send slot. Not a wire behaviour. **Also:** a propagated copy larger than the
      node's announced per-transfer limit is refused up front (`propagationRefused`); reference
      attempts it and lets the node reject it. A rejected *propagated* copy is terminal for that
      copy (reference retries it like any failure). `cancelOutbound` does not stop the
      propagation-only entry point's stamp search
      (`sendViaPropagation(destinationHash:title:content:)` is not per-hash cancellable).
      Known gaps: the propagation-only entry point
      (`LXMFNode.sendViaPropagation(destinationHash:title:content:)`) gets neither the size refusal
      nor the pending marker, and the size check compares the packed message, not the larger
      propagation container, so a message just under the limit can still be rejected by the node.
- [x] **Direct first, the propagation node as fallback** — `.sendMessage(message:fallbackToPropagation:)`
      (2026-10-21 propagation-push spec, Amendments A2/A3; it replaced `alsoViaPropagation`, which
      sent the delivery copy and the propagated copy at once). **Deliberate divergence:** reference
      LXMF goes to the propagation node only once direct delivery has failed for good. We start the
      propagated copy after the delivery copy's **third** attempt
      (`LXMFDelivery.propagationFallbackAfterAttempts`, a retry or a link/path attempt), or at its
      terminal failure if that comes first, and the delivery copy keeps retrying meanwhile. So a
      late direct proof can mean both copies arrive (`deliveryConfirmed` and `propagationAccepted`);
      a propagated copy not yet transmitted when the direct proof arrives is dropped. A rejected
      delivery copy is the peer's answer and never falls back. `holdOutbound` defers retries while
      the app is suspended, so nothing fails or falls back then (no reference equivalent).
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
- [~] **Non-link proofs / `PacketReceipt` / reverse table** (§1.6) — **endpoint DONE**
      (`docs/superpowers/specs/2026-09-26-single-packet-proofs-design.md`): ReTiCA proves inbound
      opportunistic LXMF packets, so a reference sender no longer times out on messages we
      received, and validates implicit and explicit proofs for its own opportunistic sends.
      **Still open:** the reverse table — a ReTiCA relay does not route proofs for third parties.
- [ ] **Tunnels** — no path restoration when a transport peer reappears; every TCP reconnect
      (backgrounding, cell↔Wi-Fi handoff) loses the peer's routes to us.
- [~] **Interfaces: 3 of 15** (was 2 of 15) — **TCP server DONE** (lib `f363dff` `TCPServerEndpoint`
      driver + container slot; app opt-in listener in ReTiCaMsgr `5e77ebb`). Two phones on one Wi-Fi
      can now peer over IP — *if the dialler knows the listener's address:port*. STILL OPEN and the
      reason this is only a PARTIAL tick:
      - **12 of 15 interfaces remain** (TCP client + BLE + TCP server = 3 done).
      - **A listening node is NOT auto-discoverable.** Without **AutoInterface** (zero-config LAN
        discovery, still absent) the dialler must be handed the listener's `address:port` out of
        band — the listener does not announce its presence on the LAN.
      - **Accepted connections are UNBOUNDED.** The listener has no per-connection cap and no
        admission control — the opt-in default-off toggle is the only mitigation. Admission control
        is tracked under Tier 7 (`No accepts_links policy`, and the link/transfer caps above it).
      - **RNodeInterface over BLE** (LoRa hardware; CoreBluetooth plumbing exists) remains absent.
      - Known Task-2 follow-up (Minor M-2-1): the live `NWListener` path has no real-socket
        loopback test yet — verified only via the reducer with a mocked `TCPListener`.
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
      `.delegate(.messageReceived)`, feed it to `.sendMessage(message:fallbackToPropagation: false)`,
      and assert the emitted `.endpoint(.send(plaintext:))` equals `nonCanonicalWire.dropFirst(16)`.
      **Trap for whoever writes it:** `LXMessage.==` deliberately excludes `receivedBytes`, so a
      TestStore *state* assertion on `outboundQueue` compares equal no matter which bytes are
      carried — assert on the delegate payload, not on state, or the test will be vacuous.
- [ ] **No path-request rate control** — fresh random tags pass the `discoveryPrTags` ring every
      time, each drawing a cached response or a recursive fan-out.
- [ ] **Delivery-stamp searches are not serialised — N queued sends multiply an N-times-unbounded
      CPU burn.** `LXMFNode.deliverySend` registers its search `.cancellable(id: CancelID.deliveryStamp)`
      **without** `cancelInFlight`, deliberately, so two concurrent sends coexist and are reclaimed
      together. **Measured on this machine** (arm64 Mac, 8 cores, cost 12, `LXStamper.generateStamp`
      via a `TaskGroup`): four concurrent searches finished in **1.04 s wall for 2.46 s of summed
      work**, and the wall time equalled the slowest single search to three decimals — i.e. no
      serialisation whatsoever. Reference does not permit this: `process_deferred_stamps`
      takes `stamp_gen_lock` and returns immediately if it is already held (`LXMRouter.py:2573-2580`,
      LXMF 1.1.0; the lock is created at `:181`), so at most one delivery stamp is generated at a
      time, whatever the queue depth.
      **Why the existing ceiling does not cover this.** `maxDeliveryStampCost = 20`'s rationale
      bounds *one* search. N messages to N stamp-demanding peers is N of them, and on a 2-core phone
      that saturates the same cooperative pool the transport runs on — the exact starvation
      `LXStamper.search`'s `Task.yield()` exists to prevent for a single search.
      Two related facts worth recording while this is open. **"cost 20 ≈ 8 minutes" is a geometric
      mean, not a bound** — the search is memoryless, so the 95th percentile is ~3× that (≈ 24
      minutes). The same probe showed how wide that is in practice: a *single* cost-12 search took
      **6.32 s** while four concurrent searches at the identical cost drew **0.17 / 0.62 / 0.63 /
      1.04 s**. And **there is no timeout** — only the app calling `.cancelDeliveryStamps` (which now
      fails those messages, see Tier 3) ever ends a search that has not succeeded.
      *Filed 2026-08-16 (whole-branch review of the delivery-stamps slice); not fixed in it.*
- [ ] **`.sendMessage(fallbackToPropagation: true)` races on `pendingDeliveries[hash]`, and the
      delivery-stamps slice changed who wins.** Both `LXMFRouter`'s `.send` (`LXMFRouter.swift:332`
      opportunistic, `:340` direct) and `.sendViaPropagation` (`:363`) call
      `arm(&state, message.hash, …)`, which overwrites `state.pendingDeliveries[hash]`
      unconditionally (`:189-191`) and arms `retryTimer` with `cancelInFlight: true` (`:175`) — so the
      second arrival replaces the first's `ResendInfo` *and* cancels its retry timer. `.delivered`
      then reads that single entry to choose the delegate: `.propagated` → `.propagationAccepted`,
      otherwise `.deliveryConfirmed` (`:495-502`). Whichever effect lands last decides what the app
      is told.
      **The collision predates the slice; its resolution did not.** The delivery copy used to be an
      immediate `.send`, so propagation — always an async `LXMFPropagation.pack` search — reliably
      arrived second and `.propagationAccepted` reliably won. Now the delivery copy is *also* an
      async search whenever the recipient advertised an in-range cost, so the winner is whichever
      proof-of-work finishes first. **Exact reachability condition:** `fallbackToPropagation` is true
      (`!state.propagationNodeHex.isEmpty`, ReTiCaMsgr `AppFeature.swift:168`) **and** the recipient
      is in `learnedPeers` with a `stampCost` in 1…`maxDeliveryStampCost` — `deliverySend`'s guard
      falls back to a synchronous `.send` in every other case, so an unstamped send keeps the old
      deterministic ordering. Verified by reading each cited site, not inferred.
      *Filed 2026-08-16 (whole-branch review of the delivery-stamps slice); not fixed in it.*
- [ ] **`validate_retica_delivery_stamp.py` cannot be re-run from a fresh checkout.**
      `Tests/ReTiCATests/Vectors/validate_retica_delivery_stamp.py` reads its input from
      `/tmp/ReTiCA/retica_raw_stamp.json` and **no committed test writes that file**, so the recorded
      2026-08-16 verdict ("reference ACCEPTS ReTiCA's stamp") cannot be reproduced without hand-writing
      a throwaway `@Test` first. Its docstring says the gap is "filed: see
      docs/reference-parity-checklist.md" — it was not, until now. Closing it wants a committed
      sub-second `@Test` at **cost 10** (2¹⁰ rounds over the 768 KB workblock) that emits the
      artefact to a path inside the repo's own scratch, plus a note that `/tmp/ReTiCA/` is shared
      between agents and has already caused one collision. **Generation cost is exponential: never
      generate above ~10 in a test.** Validation is O(1) and safe at any cost.
      *Filed 2026-08-16 (whole-branch review of the delivery-stamps slice).*
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
| Transfer-aware delivery | Tier 5 | `2026-09-27-transfer-aware-delivery.md` | done |
