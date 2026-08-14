# Wire-Input Trap Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the *class* of remotely-triggerable process aborts caused by unguarded narrowing conversions and unbounded parsing of wire-derived values — mechanically, not site-by-site.

**Why this plan exists.** The predecessor (`2026-08-12-hostile-input-hardening.md`) fixed three such sites and claimed the class was closed. It was not. A whole-branch sweep inventoried **56 numeric conversions** across `Sources/` and found **seven more Criticals**, every one reproduced as an actual abort or measured DoS. Two further independent sweeps each found Criticals the others missed. The lesson, recorded in the ledger and in memory: *finding three instances of a pattern is evidence the pattern is systemic, not evidence you found them all.*

**Architecture:** Task 1 is a **mechanical guard** — a lint/grep gate that makes the class detectable — and it runs first deliberately, so every later task is verified against a tool rather than against someone's attention. Tasks 2-8 then close the confirmed Criticals, ordered by reach. Tasks 9-10 address the two design-level bounds (parse depth, ingress MTU) that turn individual traps into one-frame kills.

**Tech Stack:** Swift 6, `swift-testing`, The Composable Architecture.

## Global Constraints

- Platform floor: **iOS 17 / macOS 13 / macCatalyst 17**, as declared in `Package.swift:6-10`. Earlier plans in this repo asserted an iOS 16 floor; that was stale and is now resolved — `Package.swift` is authoritative and raising to 17+ is sanctioned. Do not lower it, and do not treat an iOS-16-era API restriction as binding.
- `ReTiCA` core has zero third-party dependencies. `ReTiCATransport` is interface-agnostic.
- Wire compatibility with Python-RNS 1.4.1/1.4.2 is mandatory. **Every task here changes only what we ACCEPT.** The predecessor violated this once (`Transport.swift:556`) and the per-task gate missed it — so each task must explicitly diff-check for changes to emitted bytes and say so in its report.
- Reference Python: `/Users/ell/development/python/Reticulum/RNS`.
- Tests use `swift-testing`, NOT XCTest.
- **RED evidence rule:** a Swift trap is uncatchable in-process, so RED is the **test process crashing** with the guard reverted, captured verbatim. A green test with no demonstrated RED proves nothing.
- **Known pre-existing flake:** `pairedModePublishesWithEncryptionAndEncryptedReadPerms` (`Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift`), in a target that does not depend on `ReTiCA`. Ignore it.
- Commit after each task. Trailers must start at column 0:

```
Co-Authored-By: Claude <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

### Three rules distilled from how the predecessor failed

1. **Bound the product, not just the conversion.** `Int(chunkIndex) * 74 * 4` traps twice — converting *and* multiplying. Clamping the conversion leaves the overflow live.
2. **Verify evaluation order, not just the presence of a guard.** One site was recorded as "guarded in practice by the contiguity check on the next line". It wasn't — the trapping line evaluates first.
3. **Reject vs clamp is semantic.** For a split resource the whole-object size legitimately exceeds one segment and must be **clamped**; for a non-split one it must be **rejected**, because clamping silently truncates. Backwards in either direction corrupts data instead of crashing.

---

### Task 1: Make the class mechanically detectable (do this first)

**Why:** every later task in this plan is worthless if the next feature reintroduces the pattern. Three humans/agents sweeping the same code each missed Criticals the others found; a tool does not.

**Deliverables:**
- An inventory of every narrowing conversion applied to a wire-derived value across `Sources/` — `Int(...)`, `Int32(...)`, `UInt32(...)`, `UInt16(...)`, `UInt8(...)` — committed as a checklist so later tasks can tick sites off and the residue is visible.
- A CI-runnable check that fails on a bare narrowing conversion of a wire-derived value. Preferred form: a script that greps `Sources/` and allowlists reviewed sites, since the package has no linter today and adding SwiftLint is a dependency decision outside this plan's scope. If you judge SwiftLint worth proposing, say so in the report — do not add it unilaterally.
(The platform-floor discrepancy earlier flagged here is **already resolved** — `Package.swift` at iOS 17 / macOS 13 / macCatalyst 17 is authoritative. No action needed.)

- [ ] **Step 1:** Produce the inventory. Include `file:line`, the expression, the source of the value, and whether it is currently guarded — and for "guarded", name the guard and confirm it evaluates *before* the conversion.
- [ ] **Step 2:** Write the check script and confirm it flags all ten known sites (the three the predecessor fixed plus the seven below).
- [ ] **Step 3:** Wire it so it is runnable locally; note in the report how to add it to CI.
- [ ] **Step 4:** Commit — `chore: detect unguarded narrowing conversions of wire-derived values`.

---

### Tasks 2-8: The seven confirmed Criticals

Each was reproduced as a real abort or measured DoS. Ordered by reach. Each task: write the crash-reproducing test, confirm RED (process crash), fix, confirm GREEN, tick the Task 1 inventory, commit.

- [ ] **Task 2 — `MsgPack.swift:146` `Int(key)`.** *Widest reach, best fix ratio.* **Eleven attacker bytes** kill the process. Reachable from ~15 decode sites including **unauthenticated opportunistic LXMF**. Note the `.map`/`.intMap` check at `ResourceAdvertisement.swift:45` runs *after* `decodeValue` has walked the whole tree, so a hostile `intMap` nested anywhere inside an otherwise well-formed advertisement reaches this line. One fix closes all of it.

- [ ] **Task 3 — `MsgPack.swift:92/128/153` unbounded parse recursion.** SIGBUS at depth **431** on a 512 KiB worker stack — inside a single `Link.mdu`. Add a depth limit; choose it against the deepest legitimate structure the protocol defines and cite that.

- [ ] **Task 4 — `Packet.swift:69-100` no ingress MTU ceiling.** `Packet.mtu = 500` is enforced only on egress (`:65`). An inbound payload can be ~262 KB, which is what makes Task 3 a one-frame kill. Bound on ingest. Check carefully against relayed/HEADER_2 packets and IFAC overhead before choosing the number.

- [ ] **Task 5 — `PropagationStore.swift:75` PoW before validation.** ~9,000 hash ops + 256 KB **per entry before the stamp is known bogus**. Measured 21.7 ms per 49-byte entry → **2.3 KiB/s saturates a core**; a 3 MiB container ≈ 22 minutes of blocking CPU. Reorder so cheap structural validation precedes expensive work.

- [ ] **Task 6 — `LXMFServiceNode.swift:219` `Int(Double)`.** `[[], [], float64(NaN)]` on a `/get` aborts. **No `/get` handler is registered, so no `RequestPolicy` gate applies** — any client, any PN with node mode on. Fix the conversion *and* note whether the missing policy gate is a separate defect worth its own task.

- [ ] **Task 7 — `PNAnnounce.swift:56-59`, six `Int(UInt64)`.** A 21-byte app-data blob aborts. `PNAnnounce.isValid` — the *validity predicate* — crashes on the input it exists to reject, which is the sharpest illustration of the class in the codebase.

- [ ] **Task 8 — `ResourceTransfer.swift:451` `Int(chunkIndex) * 74 * 4`.** Signal 5 **twice** — the conversion and the multiply. The predecessor's ledger wrongly recorded this as guarded by the contiguity check on the following line; the conversion evaluates first. **Bound the product.** *(Re-verified 2026-08-14: was `:442`, drifted to `:451` when the destructive-transition slice touched this file. The surrounding logic is unchanged — the `guard offset == state.knownHashmap.count` contiguity check is still on the line **after** the conversion, so it still does not protect it.)*

---

### Tasks 9-10: Important, from the same review

- [ ] **Task 9 — unkillable stamp generation.** `LXMFNode.swift:340` → `LXStamper.swift:73-79`: a wire `targetStampCost` of 64 reaches a bare `while true` inside a `.run` effect **with no cancellation ID**. Clamp the cost against a sane ceiling (reference `PROPAGATION_COST` is 16) *and* give the effect a cancellation ID so it can be torn down.

- [ ] **Task 10 — decompression allocates the ceiling, not the content.** `Bzip2.swift:36-38` / `ResourceTransfer.swift:408`: 41 bytes of input can drive a 64 MiB allocation. *(Re-verified 2026-08-14: `Bzip2.swift:36-38` still exact — `let bufSize = max(expectedSize, 1)` then `[UInt8](repeating: 0, count: bufSize)`. The call site drifted from `:393` to `:408`; `:393` is now just the `segmentExpectedSize` declaration, and the bound added by Task 3's fix round sits at `:402`.)* This is **not** reference parity — `Resource.py:691` uses an *incremental* `BZ2Decompressor(max_length=)` that allocates only what it produces. Move to incremental decompression.

---

## Deliberately out of scope

- **Resource splitting for requests/responses.** Reference splits every resource (`Resource.py:274-310`); `LinkSession.sendRequest`/`sendResponse` do not. This is why the predecessor's `t` gate risked breaking PN downloads. Reference-faithful but a substantial feature — schedule separately.
- **Admission control** (`accepts_links`, `resource_strategy`, `max_request_size`, path-request rate limiting) — still the largest single exposure, still unstarted.
- **Unbounded collections:** `LinkPlane.state.links` (`:110-115`, linear-scanned per packet) and `LinkSession.state.transfers` (`:445`, O(N) fan-out per packet). Related to admission control; fold in there.
- **MsgPack encoder `map32` gap:** no `map32` branch, so `UInt16(n)` at `:64`/`:70` is a live foot-gun for host-constructed maps. Encoder-side, not wire-input; separate.

## Self-review notes

- **Ordering is load-bearing.** Task 1 first is the whole point: the predecessor's failure was treating the sweep as a review afterthought rather than a planned task.
- **Do not trust "guarded" without checking order** — rule 2 above exists because I recorded exactly that error in the predecessor's ledger.
- **Each task must diff-check for emitted-byte changes.** The predecessor violated wire compatibility once and six per-task reviews missed it.
