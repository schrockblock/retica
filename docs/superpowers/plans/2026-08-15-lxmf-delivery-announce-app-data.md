# LXMF delivery-announce app data Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ReTiCA users appear with their display names in Sideband and NomadNet, let ReTiCA advertise a delivery stamp cost, and learn both from the peers it hears.

**Architecture:** A pure `LXMFAnnounceData` value type with `pack`/`parse`, byte-cross-validated against genuine Python output — the same shape as the existing `PNAnnounce` (`Sources/ReTiCA/LXMF/PNAnnounce.swift`), which is the precedent to follow. Then three small wiring tasks: outbound announce, inbound learning, and the missing re-announce on node-mode change.

**Tech Stack:** Swift 6, swift-testing, The Composable Architecture 1.26.

## Global Constraints

- Platform floor **iOS 17 / macOS 13 / macCatalyst 17** (`Package.swift:6-10`).
- `ReTiCATransport` is interface-agnostic; no new dependencies.
- **Wire compatibility with Python-RNS 1.4.1/1.4.2 and LXMF 1.1.0 is mandatory. No existing emitted byte may change.**
- `swift-testing`, not XCTest.
- `#expect(optional?.field == x)` **aborts** when the optional is nil. Use `#expect(x != nil)` then `if let`.
- Durable records **name the enclosing function**, not a bare line.
- Reference: `/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/{RNS,LXMF}` is stock 1.4.2 / LXMF 1.1.0. The other tree is a 1.4.1 **fork** whose extra import at `Reticulum.py:37` shifts later lines +1. **Cite the version with the line.**
- **Verify every reference claim in this plan.** Reference claims in recent slices were wrong four times; each was caught only because someone re-checked instead of inheriting. My line numbers here were read from the stock tree on 2026-08-15, but re-derive rather than trust.
- **This is wire input.** Everything `parse` touches is attacker-controlled. `Int(someUInt64)` traps; `data[0]` on empty `Data` traps; `Data` slices are not zero-indexed. `Scripts/check-wire-narrowing.swift --fail-on-open` must stay at zero known-open, and any new conversion needs an allowlist entry with a reason.
- Mutation-verify per repo rule: run and pass; batch-mutate so all changed tests fail in one run; revert and confirm green.
- Commit trailers start at **column 0**:

```
Co-Authored-By: Claude <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Background: the wire format, verified 2026-08-15

**Producer** — `LXMRouter.get_announce_app_data` (stock LXMF 1.1.0, `LXMRouter.py:1034-1050`):

```python
display_name = None
if delivery_destination.display_name != None:
    display_name = delivery_destination.display_name.encode("utf-8")

stamp_cost = None
if delivery_destination.stamp_cost != None and type(delivery_destination.stamp_cost) == int:
    if delivery_destination.stamp_cost > 0 and delivery_destination.stamp_cost < 255:
        stamp_cost = delivery_destination.stamp_cost

supported_functionality = [SF_COMPRESSION]
peer_data = [display_name, stamp_cost, supported_functionality]
return msgpack.packb(peer_data)
```

`SF_COMPRESSION = 0x00` (`LXMF.py:142`). Note the cost gate is strict on **both** ends: `> 0` and `< 255`. A cost of 0 or 255 is advertised as `None`, not as itself.

**Consumers** — `LXMF.py`, three separate functions (`display_name_from_app_data`, `stamp_cost_from_app_data`, `compression_support_from_app_data`, around `:150-200`). Their shared structure is the important part:

```python
if app_data == None or app_data == b"": return None
if (app_data[0] >= 0x90 and app_data[0] <= 0x9f) or app_data[0] == 0xdc:
    peer_data = msgpack.unpackb(app_data)
    if type(peer_data) == list:
        ...                       # 0.5.0+ format
else:
    return app_data.decode("utf-8")   # ORIGINAL pre-0.5.0 format: raw utf-8 display name
```

Four behaviours to reproduce exactly:

1. **Two formats.** First byte in `0x90...0x9F` (fixarray) or `0xDC` (array16) ⇒ msgpack. **Anything else ⇒ the whole blob is a raw utf-8 display name.** Note `0xDD` (array32) is *not* accepted — a 3-element array is `0x93`, so this never bites us on send, but our parser must match the gate rather than accept any array.
2. **Display name** is `bin` (Python `bytes`), decoded utf-8 then `.replace("\x00", "").strip()`. Reproduce the null-stripping and whitespace-trim.
3. **Short arrays degrade, they do not fail.** `len < 2` ⇒ stamp cost `None`. `len < 3` ⇒ compression `True`. `peer_data[2]` not a list ⇒ `True`. Only `SF_COMPRESSION in peer_data[2]` decides otherwise.
4. **Empty and nil app data return `None`**, checked *before* `app_data[0]`.

---

## File Structure

- `Sources/ReTiCA/LXMF/LXMFAnnounceData.swift` — **new**; pure pack/parse. Model it on `PNAnnounce.swift`.
- `Tests/ReTiCATests/LXMFAnnounceDataTests.swift` — **new**; unit + hostile-input tests.
- `Tests/ReTiCATests/LXMFAnnounceDataCrossValidationTests.swift` — **new**; byte-comparison against generated Python fixtures.
- `Sources/ReTiCANode/LXMFNode.swift` — outbound announce, inbound learning.
- `Sources/ReTiCANode/LXMFServiceNode.swift` — the `setNodeMode` re-announce.

---

### Task 1: `LXMFAnnounceData` pack and parse

**Files:**
- Create: `Sources/ReTiCA/LXMF/LXMFAnnounceData.swift`
- Test: `Tests/ReTiCATests/LXMFAnnounceDataTests.swift`

**Interfaces:**
- Produces: `LXMFAnnounceData` with `displayName: String?`, `stampCost: Int?`, `supportsCompression: Bool`; `static func pack(displayName:stampCost:) -> Data`; `static func parse(_ appData: Data) -> LXMFAnnounceData?`. Tasks 2 and 3 consume both.

- [ ] **Step 1: Read `Sources/ReTiCA/LXMF/PNAnnounce.swift` first.** It is the existing, reviewed precedent for exactly this kind of type — a pure announce-payload codec with a hostile-input `parse`. Match its structure, its guard style, and its documentation conventions. Task 7 of the recent trap sweep hardened its `parse`; read *why* before writing yours.

- [ ] **Step 2: Write the failing tests.** Cover, at minimum:
  - round-trip with a display name and a stamp cost
  - round-trip with `nil` display name and `nil` stamp cost (must emit `0xC0` nils, not omit elements)
  - stamp cost `0` and `255` both advertise as **nil** (reference's strict `> 0 && < 255` gate)
  - **pre-0.5.0 format**: `Data("Alice".utf8)` parses to `displayName == "Alice"`, since `0x41` is outside the array gate
  - a display name containing embedded `\u{0}` and surrounding whitespace comes back stripped and trimmed
  - `len == 1` array ⇒ stamp cost nil, compression **true**
  - `len == 2` array ⇒ compression **true**
  - `peer_data[2]` present but not an array ⇒ compression **true**
  - `peer_data[2] == []` ⇒ compression **false** (`SF_COMPRESSION` absent)
  - **hostile input**: empty `Data()` returns nil without trapping; a truncated msgpack body returns nil; a stamp cost of `UInt64.max` returns nil or a bounded value but **never traps**; invalid utf-8 in the display name yields `nil` display name rather than a crash
  - a `Data` slice with a non-zero `startIndex` parses identically (this codebase has been bitten by non-zero-based `Data` indices before — construct one with `.dropFirst()` and confirm)

- [ ] **Step 3: Run and confirm RED.**

- [ ] **Step 4: Implement.** Keep `parse` total: every path returns a value or nil, none traps. Guard `appData.isEmpty` **before** touching the first byte. Use `Int(exactly:)` for the stamp cost, never `Int(_:)`.

- [ ] **Step 5: Green, then run `Scripts/check-wire-narrowing.swift --fail-on-open`.** Zero known-open. If you added a conversion, add an allowlist entry naming the enclosing function and the guard that makes it safe.

- [ ] **Step 6: Mutation-verify** and commit.

---

### Task 2: Cross-validate against genuine Python output

**Files:**
- Create: `Tests/ReTiCATests/LXMFAnnounceDataCrossValidationTests.swift`
- Create: a fixture generator, committed — **not** left in `/tmp`

**Interfaces:**
- Consumes: `LXMFAnnounceData.pack`/`parse` from Task 1.

A round-trip test proves we are self-consistent, not that we are wire-compatible. This task is what makes the claim real.

- [ ] **Step 1: Find where existing fixture generators live and follow that pattern.** Look for the generators behind the existing cross-validation suites (`PNAnnounce`, `LXMessage`). **Commit the generator** — a previous slice left one in `/tmp` and it was lost.

- [ ] **Step 2: Generate fixtures by driving genuine LXMF**, not by hand-rolling msgpack. Run `/Users/ell/opt/anaconda3/envs/rns/bin/python` against a script file (never `python -c`, per repo convention). Emit, at minimum: a name-and-cost blob, a both-nil blob, a name-only blob, and a pre-0.5.0 raw-utf-8 blob. Where practical drive `LXMRouter.get_announce_app_data` itself rather than reimplementing its logic in the generator; if that needs too much router scaffolding, call `msgpack.packb` on the exact `peer_data` list it would build and say in the generator's header that you did so, and why.

- [ ] **Step 3: Assert both directions.** Our `pack` output must be **byte-identical** to the fixture, and our `parse` must recover the same values from the genuine fixture. Both, for every fixture.

- [ ] **Step 4:** Green, mutation-verify, commit.

---

### Task 3: Announce our display name and stamp cost

**Files:**
- Modify: `Sources/ReTiCANode/LXMFNode.swift`
- Test: the existing `LXMFNode` test suite

**Interfaces:**
- Consumes: `LXMFAnnounceData.pack`.

`LXMFNode.swift:102` currently announces `appData: nil` — which is why ReTiCA users show up unnamed in every reference client.

- [ ] **Step 1:** Add `displayName: String?` and `deliveryStampCost: Int?` to `LXMFNode.State`, defaulting to nil (current behaviour: an all-nil blob is still a *valid* 0.5.0 announce, so decide deliberately whether a fully-nil configuration should emit `pack(nil, nil)` or keep `appData: nil`, and say which in the report — **reference emits the packed blob unconditionally**, so matching it means always packing).
- [ ] **Step 2:** Write the failing test: with a display name set, `.registerDelivery` emits `.announce` whose `appData` parses back to that name.
- [ ] **Step 3:** Confirm RED, implement, confirm green.
- [ ] **Step 4:** Add a `.setDisplayName` action that updates state **and re-announces** — a name change nobody hears is not a name change.
- [ ] **Step 5:** Full suite, gate, mutation-verify, commit.

---

### Task 4: Learn peers' display names and stamp costs

**Files:**
- Modify: `Sources/ReTiCANode/LXMFNode.swift`
- Test: the existing `LXMFNode` test suite

**Interfaces:**
- Consumes: `LXMFAnnounceData.parse`.

- [ ] **Step 1: Read `LXMFNode.swift:370-380` first** — the existing inbound-announce path that parses `PNAnnounce` from `state.endpoint.learned[...]?.appData`. Follow it; do not invent a second mechanism.
- [ ] **Step 2:** Store learned peer data keyed by delivery destination hash. Include the **timestamp** — reference keeps `[time.time(), stamp_cost]` (`LXMRouter.py:1029`) and expires entries in `clean_outbound_stamp_costs` (`:1272-1281`). Read that expiry and decide whether to mirror it now or file it; either is defensible, but say which and why.
- [ ] **Step 3:** Write the failing test, confirm RED, implement, confirm green.
- [ ] **Step 4: Do NOT act on a learned stamp cost in this task.** Generating a delivery stamp is deliberately out of scope — a peer-advertised cost drives an unbounded proof-of-work search, and `LXStamper.generateStamp`'s own docstring warns that cancellability alone does not stop a hostile peer pinning a core. **Store it; do not spend it.** Note this explicitly where you store it.
- [ ] **Step 5:** Full suite, gate, mutation-verify, commit.

---

### Task 5: `setNodeMode(false)` must re-announce

**Files:**
- Modify: `Sources/ReTiCANode/LXMFServiceNode.swift` (around `:111`)
- Test: the existing `LXMFServiceNode` suite

`setNodeMode(false)` returns `.none`, so the last announce on the network still says `nodeState: true`. Peers keep syncing into a node that now drops everything.

- [ ] **Step 1: Verify the reference behaviour and cite it.** The checklist claims `LXMRouter.py:692-694` → `:338-345` and `Handlers.py:98-99`. Confirm those line numbers against stock LXMF 1.1.0 before relying on them — and confirm the direction: does reference re-announce on *both* transitions, or only on disable?
- [ ] **Step 2:** Write the failing test — `setNodeMode(false)` emits an announce whose parsed `PNAnnounce` has `nodeState == false`. Confirm RED.
- [ ] **Step 3:** Implement, confirm green. Check the `true` transition too; if it already announces, say so, and if it does not, fix both.
- [ ] **Step 4:** Full suite, gate, mutation-verify, commit.

- [ ] **Step 5: Tick the two Tier 3 items** in `docs/reference-parity-checklist.md` — the announce-app-data item and the `setNodeMode` item — recording the fixing commit SHAs **inline** (not "see the task report": `.superpowers/sdd/` is gitignored, so a tracked doc must not point into it). Name enclosing functions. Do not re-stamp the header date unless you re-checked the other items. State plainly that **delivery stamps remain unwired** — this slice learns costs but never spends them — so nobody reads the tick as closing that.

---

## Self-review notes for the implementer

- **The stamp-cost gate is `> 0 && < 255` on both ends.** It is easy to write `<= 255` or to drop the `> 0`. A cost of 0 means "advertise nothing", not "advertise zero".
- **`SF_COMPRESSION` is safe for us to advertise — I checked, so you do not have to re-derive it, but do sanity-check the citation.** It gates exactly one thing in reference: `auto_compress` on the outbound `RNS.Resource` (`LXMessage.py:654`, set in `determine_compression_support` at `:510-513`). It means "I can receive a **Resource** that the RNS Resource layer bzip2-compressed" — *not* LXMF payload compression. ReTiCA implements Resource auto-compression already (`Sources/ReTiCATransport/Bzip2.swift`, `Resource.autoCompressMaxSize`). Reference also **defaults it to `True`** when a peer publishes no app data (`LXMessage.py:146` and `:513`), so every reference peer has been sending us compressed resources all along and we have been handling them. Advertising the flag is therefore an accurate claim, not an aspirational one, and it changes no behaviour — it just stops us looking like a peer that opted out.
- **`Data` indices are not zero-based** after slicing. `appData[0]` on a slice is a trap waiting to happen; use `appData.first` or normalise with `Data(appData)`.
