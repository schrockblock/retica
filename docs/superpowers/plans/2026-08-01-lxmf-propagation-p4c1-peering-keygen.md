# LXMF Propagation P4c-1 — LXStamper.generatePeeringKey Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `LXStamper.generatePeeringKey(peeringId:targetCost:)` — the PoW search that produces a peering key validating at a target cost (the initiator's counterpart to `validatePeeringKey`).

**Architecture:** One pure `LXStamper` static method, mirroring `generateStamp` over the 25-round peering workblock. No reducer/composition/transport.

**Tech Stack:** Swift, Swift Testing (`@Test`/`#expect`), `swift test`.

## Global Constraints

- **Commit directly to `main`** — no feature branch, no merge dance.
- **No compound shell commands** — one command per invocation; no `&&`/`||`/`;`/`|`-chains/`xargs`/inline interpreter scripts. A single `>` redirect is allowed. Write files with the editor, not echo/heredoc.
- **Temp files** go in `/tmp/ReTiCA/`.
- **Commit trailers, verbatim, at COLUMN 0 (no leading whitespace)**, via `git commit -F <file>` (never `-m`, the trailers contain `;`):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```
  Verify after commit: `git log -1 --format='%(trailers:key=Claude-Session,valueonly=true)'` must print the URL.
- **Three-step mutation verification** for the new test: run pass → mutate production to force fail + confirm → revert + confirm pass. One mutation at a time.
- **Scope:** the one primitive + its test only. Do NOT add PNNode cost enforcement, announce-cost parsing, or effect wiring.
- If `swift test` shows a stale cross-module link error, run `swift package clean` then retry.

---

### Task 1: LXStamper.generatePeeringKey

**Files:**
- Modify: `Sources/ReTiCA/LXMF/LXStamper.swift`
- Test: `Tests/ReTiCATests/LXStamperTests.swift` (or wherever peering-key validation is tested — find the file containing `validatePeeringKey`).

**Interfaces:**
- Consumes: `LXStamper.stampWorkblock(material:expandRounds:)`, `.stampValid(stamp:targetCost:workblock:)`, `workblockExpandRoundsPeering` (25), `stampSize` (32), `SecureRandom.bytes(_:)`.
- Produces (for P4c-2): `LXStamper.generatePeeringKey(peeringId: Data, targetCost: Int) -> Data`.

- [ ] **Step 1: Add the method.**

In `Sources/ReTiCA/LXMF/LXStamper.swift`, immediately after the `validatePeeringKey` method, add:

```swift
    /// Generate a peering key: search random 32-byte stamps until one is valid for `targetCost` over
    /// `peeringId`'s short (25-round) peering workblock — the initiator's counterpart to
    /// `validatePeeringKey` (RNS LXMPeer.generate_peering_key). Mirrors `generateStamp`. Cost averages
    /// ~2^targetCost hash iterations.
    public static func generatePeeringKey(peeringId: Data, targetCost: Int) -> Data {
        let wb = stampWorkblock(material: peeringId, expandRounds: workblockExpandRoundsPeering)
        while true {
            let s = SecureRandom.bytes(stampSize)
            if stampValid(stamp: s, targetCost: targetCost, workblock: wb) { return s }
        }
    }
```

- [ ] **Step 2: Write the failing test.**

Find the test file that already tests `LXStamper.validatePeeringKey` (grep `validatePeeringKey` under `Tests/`) and append there (reuse its imports/style):

```swift
@Test func lxStamperGeneratePeeringKeyValidatesAtTargetCost() {
    let peeringId = Data((0..<32).map { UInt8($0) })
    let key = LXStamper.generatePeeringKey(peeringId: peeringId, targetCost: 16)   // fast sub-second search
    #expect(LXStamper.validatePeeringKey(peeringId: peeringId, peeringKey: key, targetCost: 16))
    // Cost 0: any generated key validates trivially.
    let key0 = LXStamper.generatePeeringKey(peeringId: peeringId, targetCost: 0)
    #expect(LXStamper.validatePeeringKey(peeringId: peeringId, peeringKey: key0, targetCost: 0))
}
```

(If `validatePeeringKey`'s test file uses a different `peeringId` construction, match it; the load-bearing assertion is the round-trip `validatePeeringKey(generatePeeringKey(...)) == true` at cost 16.)

- [ ] **Step 3: Run the test; confirm it passes.**

Run: `swift test --filter lxStamperGeneratePeeringKeyValidatesAtTargetCost`
Expected: PASS (a few hundred ms for the cost-16 search). (If it stale-links, run `swift package clean` first.)

- [ ] **Step 4: Mutation-verify (one at a time, revert between each).**

- Mutation A — drop the search guard: replace the loop body with `return SecureRandom.bytes(stampSize)` (return the first random key, no `stampValid` check). Run the Step 3 filter → must FAIL (the random key validates at cost 16 only with probability 2⁻¹⁶). Revert → PASS.
- Mutation B — wrong workblock: change `expandRounds: workblockExpandRoundsPeering` to the default (drop the argument: `stampWorkblock(material: peeringId)`). Run → must FAIL (the key is generated over the wrong workblock; `validatePeeringKey`'s 25-round workblock rejects it at cost 16). Revert → PASS.

- [ ] **Step 5: Run the full LXStamper suite; confirm no regressions.**

Run: `swift test --filter LXStamper`
Expected: all PASS.

- [ ] **Step 6: Commit.** (column-0 trailers; verify parse after)

Write the message to `/tmp/ReTiCA/commit-msg-p4c1-task1.txt`, then:
```bash
git add Sources/ReTiCA/LXMF/LXStamper.swift Tests/ReTiCATests/LXStamperTests.swift
git commit -F /tmp/ReTiCA/commit-msg-p4c1-task1.txt
```
(Adjust the test path if the peering-key tests live in a different file.)

Suggested subject: `feat: LXMF propagation P4c-1 — LXStamper.generatePeeringKey`

---

## Self-Review

**Spec coverage:**
- `generatePeeringKey` over the 25-round peering workblock → Task 1 Step 1. ✅
- Round-trip invariant test + cost-0 sanity → Step 2. ✅
- Mutations (drop search / wrong workblock) → Step 4. ✅
- No PNNode / enforcement / announce-parse → absent by construction; Global Constraints call it out. ✅

**Placeholder scan:** none — concrete code + commands. The "adjust path/peeringId to match the actual test file" note is a guard against helper drift; the load-bearing assertion is fixed.

**Type consistency:** `generatePeeringKey(peeringId: Data, targetCost: Int) -> Data` mirrors `generateStamp`; `stampWorkblock(material:expandRounds:)`, `stampValid(stamp:targetCost:workblock:)`, `validatePeeringKey(peeringId:peeringKey:targetCost:)`, `workblockExpandRoundsPeering`, `stampSize`, `SecureRandom.bytes(_:)` all match the current `LXStamper.swift`.
