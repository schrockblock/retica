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

---

## Status

| | |
|---|---|
| Conversions found in `Sources/` | **117** across **80** distinct file+expression groups, in 56 files |
| Reviewed safe | 109 findings / 72 groups |
| **Known-open (confirmed traps)** | **8 findings / 8 groups** — Tasks 6, 7, 8 |
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

- [ ] **`Sources/ReTiCANode/LXMFServiceNode.swift:219`** — `Int(raw)` — **Task 6**
  Source: `raw = kb * 1000` where `kb` is a wire `float64` from a `/get` request.
  Guarded: **partially, and the partial guard is the problem.** The ternary
  `raw >= Double(Int.max) ? Int.max : Int(raw)` evaluates before the conversion (correct order)
  but covers only `+inf` and the large-positive range. `NaN >= x` is `false`, so `NaN` falls
  through to `Int(NaN)` and traps; so does any sufficiently large negative. `[[], [], float64(NaN)]`
  on a `/get` aborts. No `/get` handler is registered, so no `RequestPolicy` gate applies.

- [ ] **`Sources/ReTiCATransport/ResourceTransfer.swift:442`** — `Int(chunkIndex)` — **Task 8**
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
| `PropagationStore.swift:ingest` | 5 | Expensive PoW validation ordered before cheap dedup check — **FIXED**: cheap `transient_id` dedup now runs before `LXStamper.validatePnStamp`. Gate does NOT cover it; `PropagationStoreTests.duplicateIngestBypasesPoW` is the sole regression guard. See commit for SHA. | none |

Detecting these needs a different instrument — a fuzz/property harness over the decode entry
points — which is out of scope for this plan. What the gate *does* give Tasks 3-5 is the
guarantee that their fixes do not introduce a new trapping conversion: Task 3's in-progress
depth-limit change was scanned and adds none.

---

## Reviewed safe

Grouped by *why* they cannot trap. Full reasons live in
`Scripts/wire-narrowing-allowlist.txt`, one line per group.

### Widening (destination is wider than the source type) — 32 findings
`PKCS7.swift:17,20`; `MsgPack.swift:105,109,20,162,100,101,96`;
`ResourceAdvertisement.swift:39`; `BLESupport.swift:40,41`; `FCBDriverAdapter.swift:245,246`;
`Bzip2.swift:11,24,50`; `RingSet.swift:77,78`; `Transport.swift:347,416,499,567,612,629,981,1093`.

`RingSet.swift:77-78` (`Int64(Hasher.finalize())`) and `Bzip2.swift` (`Int(UInt32)`) are only
identity/widening **because `Int` is 64-bit**, which the iOS 17 / macOS 13 / macCatalyst 17
floor guarantees.

### Masked or range-bounded inside the argument — 20 findings
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

### Cannot trap on wire input, but can on a hostile host or dependency — 27 findings

Recorded, not fixed: none is remotely triggerable, so none belongs to this plan.

- **`PNAnnounce.swift:30,32,33,34`(×3)** — `UInt64(Int)` in `packed`; traps on a negative field.
  Only producers are `PNNode.swift:84` / `LXMFServiceNode.swift:119`, which take
  `Int(date.now.timeIntervalSince1970)`; negative only if the `date` dependency is set pre-1970.
- **`LXMFServiceNode.swift:119`, `PNNode.swift:84`** — `Int(Double)` on the TCA `date` dependency;
  traps on NaN.
- **`Transport.swift:542,878`** — `UInt64(Double)` on `date`; traps on NaN *and* on any pre-1970
  date, because the destination is unsigned.
- **`MsgPack.swift:64,70`** — the encoder **map32 gap** the plan lists as out of scope: the
  `n <= 15 ? … : UInt16(n)` ternary has no upper bound, so a host-built map with >65535 pairs
  traps. Not wire-reachable — the decoder has no map32 (`0xDF`) branch either, so a decoded map
  is capped at 65535 pairs.
- **`MsgPack.swift:50,59,79`** — `UInt32(n)` in the final `else` of the bin/str/array encoders,
  unbounded above. Host-side; needs a >4 GiB in-memory value.
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
