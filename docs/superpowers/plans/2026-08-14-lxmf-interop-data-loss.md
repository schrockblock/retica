# LXMF Interop — Silent Data Loss Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop losing messages that both sides believe were delivered. Two independent defects, each of which discards real traffic from real reference peers with no error surfaced anywhere.

**Architecture:** Task 1 is a value change plus the investigation that justifies it (`LXMFServiceNode`, `PNNode`). Task 2 widens the MessagePack decoder to the types reference emits (`MsgPack`, and whatever `MsgPackValue` requires). They are independent and can land in either order; Task 1 is smaller and is written first.

**Tech Stack:** Swift 6, The Composable Architecture, `swift-testing`.

## Global Constraints

- Platform floor **iOS 17 / macOS 13 / macCatalyst 17** per `Package.swift:6-10`.
- `ReTiCA` core has zero third-party dependencies.
- **Wire compatibility with Python-RNS 1.4.1/1.4.2 and LXMF 1.1.0 is mandatory.** Task 1 changes bytes we emit *deliberately* (that is the fix); Task 2 must **not** change bytes we emit for any type we already encode. Cross-validation fixtures byte-compare against genuine reference output — if one fails, your change is wrong, not the fixture.
- Tests use `swift-testing` (`import Testing`, `@Test`, `#expect`), NOT XCTest.
- `#expect(optional?.field == x)` **aborts** the process when the optional is nil — precisely when it should fail cleanly. Use `#expect(x != nil)` then `if let`.
- **Run `swift package clean` after touching `MsgPack.swift`** — known hazard: incremental builds stale-link `ReTiCATransport` and produce spurious `LinkSessionRequestTests` failures.
- `Scripts/check-wire-narrowing.swift` must stay green. Task 2 adds integer conversions; each needs an allowlist entry with a one-line justification, or a guard.
- Known pre-existing flake: `pairedModePublishesWithEncryptionAndEncryptedReadPerms` (`FCBDriverAdapterTests.swift`), a target that does not depend on `ReTiCA`. Ignore it.
- Reference: `/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/LXMF/` and `.../RNS/`.
- Commit after each task. Trailers must start at column 0:

```
Co-Authored-By: Claude <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

### Update the checklist

Both tasks appear in `docs/reference-parity-checklist.md` under **Tier 1**. Tick the item and record the fixing commit as part of the task — do **not** re-stamp the header date, which asserts the whole file was re-checked.

---

### Task 1: Advertise a propagation transfer limit we can actually mean

**Why:** `LXMFServiceNode.swift:120` and `PNNode.swift:85` both advertise `perTransferLimit: 0, perSyncLimit: 0`. Reference reads that and **drops every message, permanently**:

```python
# LXMPeer.py:370-373
if self.propagation_transfer_limit != None and lxm_transfer_size > (self.propagation_transfer_limit*1000):
    self.remove_unhandled_message(transient_id)
    self.add_handled_message(transient_id)
    continue
```

With limit 0, `0 != None` holds and `lxm_transfer_size > 0` always holds — so every message is dropped **and marked handled**, so it is never retried. Reference→ReTiCA mesh sync silently delivers nothing, forever, and it is default-reachable (`AUTOPEER = True`, `AUTOPEER_MAXDEPTH = 4`, `LXMRouter.py:44-45`).

`None` — not 0 — is reference's no-limit sentinel (`LXMPeer.py:192, 194`), and `None` can never arrive from the wire because `pn_announce_data_is_valid` requires `int(data[3])` to succeed. Reference's own defaults are **256 / 10240** (`LXMRouter.py:55, 59`).

**The investigation that decides the fix — do this before writing code.**

An earlier note in this repo claimed the honest fix "is not simply advertise 256 — that would be the same lie in the opposite direction until inbound caps exist." **Test that claim; I now believe it is wrong.** Read `LXMPeer.py:370-373` in context and establish **who enforces the limit**:

- If `self` in that block is the *remote peer being synced to*, then `propagation_transfer_limit` is the value **that peer advertised**, and the **sender** filters against it. Advertising a real number is then the complete and correct fix for the outbound direction, and requires no receiver-side enforcement at all — the field is a *request*, exactly as reference uses it.
- If instead the receiver is expected to enforce, advertising an unenforced number really is a misstatement, and the task needs a cap.

Report which, with the evidence. This single question determines whether Task 1 is a two-line change or the front of a much larger piece of work. Do not assume my reading is right — verify the arrow.

**Then choose the values.** Reference's 256 / 10240 KB are the obvious candidates, but state whether they are right *for us*: check what a ReTiCA PN actually serves (`PNNode.swift` `/get` path, `LXMFServiceNode.swift:204-226` honours a client's declared cap already) and whether our lack of request/response splitting interacts. If you pick reference's numbers, say why they are safe here; if you pick different ones, justify them.

**Files:**
- Modify: `Sources/ReTiCANode/LXMFServiceNode.swift` (~`:120`), `Sources/ReTiCANode/PNNode.swift` (~`:85`)
- Test: `Tests/ReTiCANodeTests/`

- [ ] **Step 1: Investigate and report** the enforcement question above, and the value choice. Do not write code first.
- [ ] **Step 2: Write the failing test** — assert the announced `perTransferLimit` and `perSyncLimit` are non-zero and equal to the chosen constants, parsed back out of the emitted `PNAnnounce` wire bytes (not read off state). Both nodes.
- [ ] **Step 3: Confirm RED** — both currently advertise 0.
- [ ] **Step 4:** Implement. Follow the precedent set by the stamp-cost fix (`8a56a25`, `08f1931`): the advertised value must come from **one source of truth**, not a literal duplicated in two files. If a shared constant does not exist, add one where `LXMFPropagation`'s other protocol constants live.
- [ ] **Step 5:** Run the full `swift test`. Tick the checklist item with the commit SHA. Commit.

**Note:** `PNNode` previously advertised a stamp cost of 0 while enforcing 16 — the same class of defect in the same announce, fixed in `8a56a25`. Check that fix's shape before writing this one; the two should look alike.

---

### Task 2: Decode the MessagePack types reference actually emits

**Why:** `MsgPack.parse` (`MsgPack.swift:121-148`) handles positive fixint, `uint8/16/32/64`, `float64`, `bin`, `str`, `fixmap`/`map16`, `fixarray`/`array16/32`, nil and bool. It does **not** handle:

- negative fixint (`0xE0-0xFF`)
- `int8` / `int16` / `int32` / `int64` (`0xD0-0xD3`)
- `float32` (`0xCA`)
- `map32` (`0xDF`)
- all `ext` / `fixext`

Everything else hits `default: return nil`. `LXMessage.unpack` decodes the payload in one shot and returns nil on any failure; `LXMFRouter.received` then drops the message with **no diagnostic**. So a message from Sideband or NomadNet whose `fields` contain a single negative integer — routine for `FIELD_TELEMETRY` coordinates — is discarded **whole, content and all**, and the sender is never told.

**The constraint that decides the implementation.**

`LXMessage.unpack` **re-encodes** decoded fields (this is the same coupling the sweep's Task 2 discovered between `MsgPack.swift:146` and `:71`). So **decode support for a type requires encode support for it**, or a legitimate inbound message will fail on the way back out. You cannot fix this by widening `parse` alone.

That means `MsgPackValue` almost certainly needs a signed-integer representation, and that ripples: encode, `Equatable`, and every existing `switch` over the enum. Design that deliberately:

- Adding a `.int` case is the obvious shape, but consider whether extending the existing `.uint` case is less invasive — and whether it can represent the full `int64` range without lying.
- **Round-trip fidelity matters more than canonical encoding.** Reference `umsgpack` will emit the narrowest form; if we re-encode a decoded `int8` as `int64`, the bytes change. Establish whether anything depends on byte-identical round-trip — **the LXMF message signature does**, since it covers the packed payload. Get this right or inbound rich messages will fail signature validation after round-trip.

**On `ext`:** determine whether LXMF or RNS ever emit it. If not, a clean rejection is acceptable and better than speculative support — but say so explicitly rather than leaving it as an unremarked hole.

**Files:**
- Modify: `Sources/ReTiCA/Support/MsgPack.swift`, and `MsgPackValue` wherever it is declared
- Test: `Tests/ReTiCATests/` — follow existing MsgPack test conventions
- Likely touched: any exhaustive `switch` over `MsgPackValue`

- [ ] **Step 1: Investigate and report** — the re-encode coupling, the `MsgPackValue` shape you propose, and the byte-identical-round-trip question. **This is the task; the parsing is mechanical.**
- [ ] **Step 2: Write the failing tests.** At minimum: (a) a payload with a negative fixint decodes; (b) each of `int8/16/32/64` decodes to the right value, including the boundary values and `Int64.min`; (c) `float32` decodes; (d) `map32` decodes; (e) **a full `LXMessage` carrying a negative integer in `fields` round-trips and its signature still validates** — that last one is the real test, the others are unit coverage beneath it.
- [ ] **Step 3: Confirm RED** — currently these return `nil` and the LXMessage test drops the message.
- [ ] **Step 4:** Implement decode + encode together.
- [ ] **Step 5: Prove no existing byte changed.** Run the cross-validation vectors specifically — they byte-compare against genuine reference output. Report which you ran.
- [ ] **Step 6:** `swift package clean`, full `swift test`, `Scripts/check-wire-narrowing.swift`. Tick the checklist item with the SHA. Commit.

---

## Self-review notes

- **Both tasks are investigation-first**, and in both the investigation is the substance. Task 1's whole scope turns on who enforces the transfer limit; Task 2's turns on the re-encode coupling. An implementer who starts coding will get a plausible-looking wrong answer in both cases.
- **Task 1 explicitly invites falsifying a claim I previously recorded** ("advertising 256 is the same lie inverted"). I now think that claim was wrong, but I have not verified it — that is the implementer's first job, and a report saying "your reading was wrong" is a good outcome.
- **Deliberately out of scope:** receiver-side inbound transfer caps and `resource_strategy` (tier 7 of the checklist, and the thing that defeats the link cap). Task 1 must not grow into it.
- **Deliberately out of scope:** the `>3 MB request/response` splitting gap. Related to Task 1's value choice, but a separate feature.
