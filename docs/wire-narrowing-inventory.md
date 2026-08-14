# Narrowing-conversion inventory

**Every fixed-width integer conversion in `Sources/`, triaged.** `Int(someUInt64)` traps — it
aborts the process rather than returning nil — and so does `Int(someDouble)` on NaN or an
out-of-range double. Wire-derived integers are attacker-controlled, so each unguarded narrowing
conversion of one is a remote process abort.

This file is the human-readable record. The machine-readable gate is
`Scripts/wire-narrowing-allowlist.txt`, enforced by `Scripts/check-wire-narrowing.swift`.
The two must agree; the script fails if a conversion exists that the allowlist does not cover.

**Line numbers are as of `656555e`** (the commit this inventory was built against). They rot.
The durable key is *file + expression text*, which is what the allowlist matches on.

> **Re-verified 2026-08-14 at `46e838e`, and the gate earned its keep.** Two security slices
> landed in between (`16db5e7..46e838e` — unauthenticated-link-elements, then
> destructive-transitions), neither aimed at this sweep, both touching `LinkSession.swift`,
> `LinkPlane.swift` and `ResourceTransfer.swift`. The gate reports **117 reviewed conversions
> across 56 files, 8 known-open, zero unreviewed** — so neither slice introduced a new narrowing
> conversion, and the count is unchanged.
>
> Exactly one recorded location rotted: Task 8's `Int(chunkIndex)` moved from `:442` to `:451`.
> Because the allowlist keys on expression text rather than line number, the gate never lost
> track of it — which is the design working as intended. The surrounding logic is unchanged: the
> contiguity check still evaluates *after* the conversion, so it still does not protect it.

> **Updated 2026-08-14 by the LXMF-interop-data-loss slice (MsgPack signed/float32/map32 decode).**
> 117 → **119** conversions; no new groups, six count changes, and one recorded reason falsified.
>
> The falsified one is the interesting one. `UInt16(n)` in the map encoders was blessed as
> host-only on the grounds that *"the DECODER has no map32 (`0xDF`) branch either, so a decoded
> map is capped at 65535 pairs."* That reason was load-bearing on a fact in a **different
> function**, and the slice's job was to add exactly that decode branch. Adding it alone would
> have converted a recorded host-only trap into a remote abort, reachable because
> `LXMessage.validateSignature` re-encodes every inbound message's fields. The encode branch
> landed in the same commit; `encodeMap`/`encodeIntMap` now share one `mapHeader` so the two
> cannot diverge again.
>
> **The generalisable lesson:** an allowlist reason that cites the *absence* of a capability
> elsewhere is a reason with an expiry date. Grep the allowlist for the function you are about to
> add a capability to, not just the lines you are about to edit.
>
> **Two entries of that shape are still live.** Named here so nobody has to rediscover them:
> - `wire-narrowing-allowlist.txt:102` — `UInt64(p.key)` in `encodeIntMap`, safe only because
>   `parseMap` dispatches to the intMap branch on a `.uint` first key and rejects everything else.
>   Re-verified by this slice; the expiry trigger is documented in code at `MsgPack.swift:257-263`.
>   **Widening `parseMap`'s accepted key types re-opens it.**
> - `wire-narrowing-allowlist.txt:120` — `UInt64(timebase)` in `PNAnnounce.packed`, safe only
>   because no producer supplies a negative. It already carries a predecessor's forward warning:
>   **Task 7 must not fix `PNAnnounce.parse` by truncating**, or a wire value reaches it negative.
>
> Line numbers in reasons rot silently — this slice first shipped nine that were uniformly `+6`
> off, because a doc comment was added to the top of `MsgPack.swift` *after* the reasons were
> written. The gate cannot catch that: it keys on expression text, so it stayed green while a
> reader following "the map32 decode branch at `:184`" landed on `case 0xA0...0xBF` (fixstr).
> When you edit a reason, re-derive its line numbers from the file as committed, and name the
> enclosing function too — the function name survives what the line number does not.

---

## Status

| | |
|---|---|
| Conversions found in `Sources/` | **121** across **82** distinct file+expression groups, in 56 files |
| Reviewed safe | 114 findings / 75 groups |
| **Known-open (confirmed traps)** | **7 findings / 7 groups** — Tasks 7, 8 |
| Defects in this plan that are *not* conversions | 3 — Tasks 3, 4, 5 (see [Not detectable by this check](#not-detectable-by-this-check)) |

Run the gate:

```
swift Scripts/check-wire-narrowing.swift              # fails on an unreviewed conversion
swift Scripts/check-wire-narrowing.swift --report     # every finding, allowlist ignored
swift Scripts/check-wire-narrowing.swift --fail-on-open   # also fails on known-open sites
```

`--fail-on-open` is the completion gate: when it exits 0, every site in this plan is closed.

---

## Known-open — confirmed traps, do not bless

Tick a box when the owning task lands, **and delete the matching `OPEN` line from
`Scripts/wire-narrowing-allowlist.txt`**. The gate's stale-entry check will tell you if you
forget one; `--fail-on-open` will tell you if any remain.

- [x] **`Sources/ReTiCA/Support/MsgPack.swift:146`** — `Int(key)` — **Task 2 FIXED**
  Fixed by rejection: `Int(exactly: key)` with `return nil` if the key exceeds `Int.max`.
  Commit: `eb244c3`.

- [x] **`Sources/ReTiCA/Support/MsgPack.swift:71`** — `UInt64(p.key)` — **Task 2 constraint CLOSED**
  This site is now safe: the `Int(exactly:)` guard at decode time guarantees every wire-decoded
  `IntPair.key` is in `0...Int.max`. A hostile host could construct a negative `IntPair.key`
  directly, but that is not wire-reachable — same category as `PNAnnounce.packed`. Allowlist
  entry updated from OPEN to reviewed-safe.

- [ ] **`Sources/ReTiCA/LXMF/PNAnnounce.swift:56`** — `Int(timebase)` — **Task 7**
- [ ] **`Sources/ReTiCA/LXMF/PNAnnounce.swift:57`** — `Int(transfer)` — **Task 7**
- [ ] **`Sources/ReTiCA/LXMF/PNAnnounce.swift:57`** — `Int(sync)` — **Task 7**
- [ ] **`Sources/ReTiCA/LXMF/PNAnnounce.swift:58`** — `Int(cost)` — **Task 7**
- [ ] **`Sources/ReTiCA/LXMF/PNAnnounce.swift:58`** — `Int(flex)` — **Task 7**
- [ ] **`Sources/ReTiCA/LXMF/PNAnnounce.swift:59`** — `Int(peer)` — **Task 7**
  Source: all six are `UInt64`s destructured from wire announce app-data in `PNAnnounce.parse`.
  Guarded: **no.** A 21-byte app-data blob aborts. `PNAnnounce.isValid` — the validity predicate
  itself — crashes on the input it exists to reject.
  Note for the fix: `PNAnnounce.packed` converts these fields straight back with `UInt64(...)`
  (`:30`, `:32`, `:33`, `:34` ×3), which traps on a negative. Same constraint as Task 2 —
  reject or clamp, do not truncate.

- [x] **`Sources/ReTiCANode/LXMFServiceNode.swift:261` (in `requestReceived`, `.double` branch)** — `Int(raw)` — **Task 6 FIXED**
  Source: `raw = kb * 1000` where `kb` is a wire `float64` from a `/get` request.
  Guarded: **partially, and the partial guard was the problem.** The ternary
  `raw >= Double(Int.max) ? Int.max : Int(raw)` evaluated before the conversion (correct order)
  but covered only `+inf` and the large-positive range. `NaN >= x` is `false`, so `NaN` fell
  through to `Int(NaN)` and trapped; so did any sufficiently large negative. `[[], [], float64(NaN)]`
  on a `/get` aborted. No `/get` handler is registered, so no `RequestPolicy` gate applies.
  Fixed by checking `raw.isNaN` and `raw < 0` (→ 0) before the existing `raw >= Double(Int.max)`
  guard, then converting only when raw is finite and non-negative and less than `Double(Int.max)`.
  The `.int` divergence (negative int → nil → unlimited) is also fixed in the same switch.
  **Parity note, and a correction worth keeping.** The task brief, this inventory's predecessor and a
  reviewer all stated that reference calls `int(float(data[2])*1000)` and is therefore protected by a
  catchable `ValueError`/`OverflowError`. **It does not call `int()` at all.** `LXMRouter.py:1528`
  keeps the cap as a float inside a bare `try/except: pass`, and `:1547` only ever compares
  `next_size > client_transfer_limit`. Nothing raises. Re-derived by reading the installed LXMF 1.1.0
  source and modelling `:1525-1547`. Consequences, all verified rather than assumed:
  - `+inf` (and any `kb` whose `*1000` overflows to `+inf`) is **parity, not divergence**:
    `next_size > inf` is false, so reference serves everything, and so does our `Int.max` clamp.
  - `-inf`, large-finite-negative, `-0.0` and `0` are **parity**: the comparison is true, so reference
    skips every message; our `0` cap does the same.
  - **`NaN` is the one real divergence, and it runs opposite to the direction everyone assumed.**
    Every comparison against NaN is false, so reference takes the else branch and **serves
    everything** — a NaN cap silently disables the cap. We serve nothing. Deliberate: the permissive
    reading lets a client opt out of the limit it just requested. Pinned by
    `serviceNodeParsesNaNTransferLimitAsZero`, with the reasoning in-code.
  Lesson for this file's own conventions: the false claim survived a brief, an inventory and a review
  because each verified the *node* (`int(nan)` really does raise) and none verified the *arrow*
  (that reference calls `int`). Cite the reference line you actually read.
  Line number drifted `:219` (inventory) → `:227` (dispatch) → `:239` (fix) → `:261` (fix-round
  comment rewrite) — **four times, twice within this task alone, and the last two were caused by
  editing the comment directly above the conversion.** The allowlist's expression-text key tracked it
  correctly throughout; this bullet is the only thing that needed hand-editing, which is why the
  header now names `requestReceived` as well.

- [ ] **`Sources/ReTiCATransport/ResourceTransfer.swift:451`** — `Int(chunkIndex)` — **Task 8** *(was `:442`; drifted 2026-08-14 when the destructive-transition slice touched this file. The allowlist keys on expression text, not line number, so the gate stayed correct throughout — this line number is documentation only.)*
  Source: `chunkIndex` is a raw wire `UInt64` from a RESOURCE_HMU msgpack array.
  Guarded: **no.** The predecessor's ledger recorded this as guarded by the contiguity check
  `offset == state.knownHashmap.count` — that check is on `:443` and evaluates *after*. Traps
  twice: at the conversion, and again at `* Resource.hashmapMaxLen * Resource.mapHashLength`.
  **Bound the product, not just the conversion.**

---

## New finding

**`MsgPack.swift:71` `UInt64(p.key)` was not on the known list.** It is the mirror image of
Task 2's site — the *encode* side of the same `IntPair` key — and it traps on a negative `Int`.
It is unreachable from the wire today only because `:146` traps first, which is precisely why
three prior sweeps could class it as safe. It matters because it constrains Task 2's fix: the
wire → `decodeValue` → `LXMessage.unpack` → `payloadBytes` re-encode round trip is real and runs
on every inbound LXMF message carrying rich fields, so a truncating fix at `:146` relocates the
abort to `:71` rather than removing it. Not fixed here, per scope.

---

## Not detectable by this check

Three of the ten known sites are **not narrowing conversions**, so no narrowing-conversion
checker can flag them. This is a limit of the defect shape, not a bug in the tool. Verified by
reading each site:

| Site | Task | Actual shape | Conversions present? |
|---|---|---|---|
| `MsgPack.swift:92/128/153` | 3 | Unbounded parse recursion — **FIXED** (`maxParseDepth = 32`, depth threaded through `parse`/`parseMap`/`parseArray`). Gate does NOT cover it; `MsgPackDepthTests` is the sole regression guard. | none |
| `Packet.swift:69-100` | 4 | Missing ingress MTU ceiling — **FIXED** (`guard raw.count <= Packet.mtu` added at top of `init?(raw:)`). Reference RNS `Packet.unpack` has no equivalent check (interface-layer `check_frame_len` is the primary bound), so lacking one was not a divergence. The guard is load-bearing at the primary inbound decode `Transport.swift:339`, where the deframers admit 262144 (TCP) / 1196 (BLE) — far above the 500-byte MTU. IFAC is stripped upstream in `Transport.received` before `Packet.init?(raw:)` sees bytes, so the 500-byte post-strip bound is correct for all interfaces. Commit: `e64f0e0`. | none |
| `PropagationStore.swift:ingest` | 5 | Expensive PoW validation ordered before cheap dedup check — **FIXED**: cheap `transient_id` dedup now runs before `LXStamper.validatePnStamp`. Gate does NOT cover it; `PropagationStoreTests.duplicateIngestBypasesPoW` is the sole regression guard. Commit: `bd832b1`. | none |

Detecting these needs a different instrument — a fuzz/property harness over the decode entry
points — which is out of scope for this plan. What the gate *does* give Tasks 3-5 is the
guarantee that their fixes do not introduce a new trapping conversion: Task 3's in-progress
depth-limit change was scanned and adds none.

---

## Reviewed safe

Grouped by *why* they cannot trap. Full reasons live in
`Scripts/wire-narrowing-allowlist.txt`, one line per group.

### Widening (destination is wider than the source type) — 34 findings
`PKCS7.swift:17,20`; `MsgPack.swift:105,109,20,162,100,101,96`;
`ResourceAdvertisement.swift:39`; `BLESupport.swift:40,41`; `FCBDriverAdapter.swift:245,246`;
`Bzip2.swift:11,24,50`; `RingSet.swift:77,78`; `Transport.swift:347,416,499,567,612,629,981,1093`.

`RingSet.swift:77-78` (`Int64(Hasher.finalize())`) and `Bzip2.swift` (`Int(UInt32)`) are only
identity/widening **because `Int` is 64-bit**, which the iOS 17 / macOS 13 / macCatalyst 17
floor guarantees.

### Masked or range-bounded inside the argument — 21 findings
`HKDF.swift:22`; `PKCS7.swift:13`; `Announce.swift:88` (both); `LXStamper.swift:16`;
`Data+Hex.swift:14`; `MsgPack.swift:108,112,114` and `:106,110,113,115` and `:107,111,116`;
`BLEDriver.swift:126`; `RandomBytesDependency.swift:21`; `FCBDriverAdapter.swift:19` (both).

`MsgPack.swift:107,111,116` — `Int(be(b, i + 1, 4))` — yields 0…4294967295, which fits a 64-bit
`Int` but **would trap on a 32-bit platform**. It is safe only under the declared floor. These
also produce unbounded *lengths*, which is a separate exposure owned by Tasks 3 and 4.

### Compile-time constants — 6 findings
`BLEInterface.swift:174`; `LXMFServiceNode.swift:216`; `ResourceAdvertisement.swift:60`;
`ResourceTransfer.swift:263,389,393`.

### Non-negative collection counts widened — 9 findings
`LinkSession.swift:544,550,555,762`; `ResourceTransfer.swift:75,80(×2),81,318`.

### Guarded by a check that provably evaluates first — 14 findings

Every entry here names its guard *and* its position, because the predecessor's ledger recorded
one site as guarded by a check on the following line.

| Site | Guard | Position relative to the conversion |
|---|---|---|
| `MsgPack.swift:39,40` | `u <= 0x7F` / `u <= 0xFF` | same line, `if` condition — evaluates first |
| `MsgPack.swift:41` | `u <= 0xFFFF` | same line, `if` condition |
| `MsgPack.swift:42` | `u <= 0xFFFF_FFFF` | same line, `if` condition |
| `BLESupport.swift:19` (both) | `packet.count <= maxFrameLength` (1196) | `:16`, three lines **earlier**, throws |
| `LXMFServiceNode.swift:216` | `kb > UInt64(Int.max / 1000)` | same line, ternary condition |
| `Bzip2.swift:37` | `expectedSize <= Resource.autoCompressMaxSize` | `:34`, three lines **earlier**, returns nil |
| `ResourceTransfer.swift:397` | `adv.dataSize <= UInt64(Resource.autoCompressMaxSize)` | `:393`, four lines **earlier**, fails the transfer |
| `ResourceTransfer.swift:389` | `min(..., UInt64(LinkSession.maxEfficientSize))` | inside the argument — cannot be bypassed |
| `ResourceTransfer.swift:220,365,371,372` | type invariant, see below | all three assignment sites |

**The `expectedParts` invariant.** `State.expectedParts` is a `UInt64` assigned at exactly three
sites — `:75` `UInt64(chunks.count)`, `:115` literal `0`, `:263`
`min(adv.numberOfParts, UInt64(Int.max))` — all of which are ≤ `Int.max`. The four `Int(...)`
uses are safe *because of that invariant*, not because of any local guard. The field is
`public var`, so a host can break it; it holds against wire input.

**Remote guards are the fragile class.** Six of the thirteen (`Bzip2.swift:37`,
`ResourceTransfer.swift:397`, the four `expectedParts` uses) depend on a guard that is not part
of the conversion's own expression. The gate keys on expression text, so **deleting a remote
guard does not change the expression and will not be flagged.** If you edit any of the guard
sites named above, re-verify by hand.

### Cannot trap on wire input, but can on a hostile host or dependency — 26 findings

Recorded, not fixed: none is remotely triggerable, so none belongs to this plan.

- **`PNAnnounce.swift:30,32,33,34`(×3)** — `UInt64(Int)` in `packed`; traps on a negative field.
  Only producers are `PNNode.swift:84` / `LXMFServiceNode.swift:119`, which take
  `Int(date.now.timeIntervalSince1970)`; negative only if the `date` dependency is set pre-1970.
- **`LXMFServiceNode.swift:119`, `PNNode.swift:84`** — `Int(Double)` on the TCA `date` dependency;
  traps on NaN.
- **`Transport.swift:542,878`** — `UInt64(Double)` on `date`; traps on NaN *and* on any pre-1970
  date, because the destination is unsigned.
- ~~**`MsgPack.swift:64,70`** — the encoder **map32 gap**~~ **CLOSED.** `encodeMap` and
  `encodeIntMap` now share `mapHeader`, which has a `0xDF` branch, so `UInt16(n)` is bounded by
  `n <= 0xFFFF` on every path. Closed together with the map32 *decode* branch, because the old
  reason ("not wire-reachable — the decoder has no map32 branch either") would have stopped being
  true the moment the decoder gained one.
- **`MsgPack.swift`** — `UInt32(n)` in the final `else` of the bin/str/array encoders **and** in
  `mapHeader`'s map32 branch, unbounded above. Host-side; needs a >4 GiB in-memory value.
- **`Bzip2.swift:10,20`** — egress; our own outbound payload.
- **`Bzip2.swift:46`** — `UInt32(data.count)` on the *received* compressed payload, so genuinely
  wire-derived, but reaching `UInt32.max` means an attacker actually transferred 4 GiB, which
  exhausts memory in `Resource.assemble` first. Bounded by admission control, out of scope.

---

## How the check works, and where it is wrong

### The rule

Every `Int(…)` / `Int8` / `Int16` / `Int32` / `Int64` / `UInt` / `UInt8` / `UInt16` / `UInt32` /
`UInt64` call in `Sources/` must be one of:

1. a compile-time-checked literal — `UInt8(0xC4)`;
2. a non-trapping labelled init — `exactly:`, `clamping:`, `truncatingIfNeeded:`, `bitPattern:`,
   `littleEndian:`, `bigEndian:`, `byteSwapped:`, `ascii:`, `truncating:` — **not**
   force-unwrapped, since `Int(exactly: x)!` puts the trap straight back;
3. listed in `Scripts/wire-narrowing-allowlist.txt` with a reason.

Anything else fails the build.

### Why "wire-derived" is not the trigger

It cannot be. Deciding whether a value came off the wire needs interprocedural dataflow, and
that judgement is exactly what failed three times: two independent sweeps plus a reviewer each
found Criticals the others missed. So the gate is **default-deny on the lexical shape** and
makes a human write down why each site cannot trap. The cost is allowlist entries for
locally-computed values; the benefit is that a new conversion cannot enter `Sources/` unreviewed.

`UInt64` is policed alongside the genuinely narrow types because `UInt64(x)` traps for a negative
`Int` and for a NaN `Double` — and a negative `Int` is what a wire-derived subtraction produces.
Two of the entries above (`MsgPack.swift:71`, `PNAnnounce.packed`) are exactly that shape.

### False negatives — what it will not catch

1. **Non-conversion defects.** Unbounded recursion, missing length ceilings, work-ordering DoS.
   Tasks 3, 4 and 5 are all invisible to it.
2. **Removal of a remote guard.** The allowlist keys on expression text, so deleting the clamp
   that makes a conversion safe leaves the expression — and therefore the gate — unchanged.
   Demonstrated: at `4b4526d^` the unclamped `n` handling still passes, because
   `Int(state.expectedParts)` reads identically before and after the fix. The six affected
   entries are listed under *Remote guards are the fragile class* above.
3. **Overflow that is not a conversion.** `a * b` traps on its own. Task 8's multiply is caught
   only because the conversion on the same line is caught.
4. **Interpolation inside a raw string.** Comment and string content is blanked before scanning;
   `\(…)` interpolation is deliberately left as code, but only for non-raw strings.

### False positives — and what they cost

Widening conversions (`Int(someUInt8)`), literals-in-disguise and locally-bounded arguments are
indistinguishable from narrowing ones without type information, so they are flagged and need an
allowlist entry. That is **67 of the 118 findings (57%)** — the widening, masked/bounded,
constant and collection-count groups above, none of which can trap on its own terms.

The remaining 51 are true positives in the sense that the value's range is not established by
the expression itself: 14 rely on a separate guard, 27 can trap given a hostile host or
dependency, and 10 are the confirmed open traps.

The cost of a false positive is one line, and the error message prints the exact line to paste:

```
Sources/Foo/Bar.swift:12:9: error: bare narrowing conversion — traps if the value is out of range: `Int(x)`
  note: prove it cannot trap (use Int(exactly:) and handle nil, or clamp), or
  note: add to wire-narrowing-allowlist.txt: Sources/Foo/Bar.swift | 1 | <why this cannot trap> | Int(x)
```

That is the trade: a false positive is an annotation, never a reason to switch the check off.

### Allowlist mechanics

`file | count | reason | expression` — expression last and unrestricted, because Swift
expressions contain `|`.

- Keyed on **expression text**, not line number, so it survives edits elsewhere in the file.
- The **count is exact**. A second copy of an allowlisted expression is a new, unreviewed site
  and fails; removing one leaves a stale entry, which also fails. That is what makes Tasks 2-10
  tick sites off rather than quietly accumulate.
- A reason starting with `OPEN` marks a known-broken site: printed loudly on every run, but not
  a failure, because a permanently-red gate gets switched off and then catches nothing.
  `--fail-on-open` flips that for the run that asserts the plan is complete.

### Recommended rule going forward

**Use `Int(exactly:)` and handle the `nil`, always — not "only on wire values".**

"Only on wire values" requires classifying every value's provenance, which is the judgement that
has already failed three times on this codebase; and provenance changes silently when a caller
is rewired, with no diff at the conversion site. The stronger rule is the only one a machine can
enforce, and it is the one the gate implements.

On **reject vs clamp**: prefer rejection — `guard let n = Int(exactly: x) else { return nil }`.
Clamping silently truncates, and for a non-split resource that corrupts data instead of crashing.
Clamp only where an over-large value is *legitimate* and the clamp is the semantically correct
bound, as at `ResourceTransfer.swift:389`, where a split resource's whole-object size genuinely
exceeds one segment. **Never truncate** (`truncatingIfNeeded:`) on a value that is re-encoded:
see the `MsgPack.swift:71` finding.

### CI

The check needs no dependency beyond the Swift toolchain that already builds the package:

```yaml
- name: Wire-narrowing gate
  run: swift Scripts/check-wire-narrowing.swift
```

It runs in ~0.8s on this tree and is independent of `swift build`, so it can gate a PR before the
build does. Add `--fail-on-open` once Tasks 2-8 have landed.

**SwiftLint was considered and not adopted.** It has no built-in rule for this, and its custom
rules are `NSRegularExpression` patterns, which cannot balance parentheses — so a custom rule
could not extract the conversion's argument, and therefore could not distinguish a literal from
a wire value, recognise `Int(exactly:)`, or spot the force-unwrap that undoes it. It would also
add a binary dependency to a package whose core deliberately has none. If a linter is adopted
later for other reasons, this check should stay as it is.

### Known gap in the tooling

`Scripts/check-wire-narrowing.swift` has no automated self-test. Its classification logic was
verified by hand against a fixture covering literals, each non-trapping label, a force-unwrapped
`Int(exactly:)!`, `!=` (which must *not* count as a force-unwrap), nested conversions, line and
nested-block comments, plain/raw/multiline strings, and string interpolation — 6 expected flags,
11 expected passes, all correct. It was also run against `95e8739^` and `4b4526d^`, where it
fails on the sites those commits fixed. Committing that fixture as a regression test is a
reasonable follow-up.
