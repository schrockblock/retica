# LXMF-5c: Propagation / Peering Stamps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `LXStamper.validatePeeringKey` (25-round workblock) and `LXStamper.validatePnStamp` (1000-round workblock, stamp appended to `lxmf_data`) — the peering-key/PN-stamp validators, reusing 5b's workblock/valid/value.

**Architecture:** Extend the pure `LXStamper`. Byte-cross-validated via a new isolated `lxmf_peering_fixtures.json`. Also corrects the stale `LXMessage` file-header doc comment.

**Tech Stack:** Swift, SwiftPM, swift-testing (`@Test`). Cross-validation from genuine LXMF/LXStamper in the conda `rns` env.

## Global Constraints

- Commit directly to `main`; no feature branch, no finishing-a-development-branch merge dance.
- No compound shell commands: no `|` chains, `&&`, `||`, `;`, `$(...)`-feeding, `xargs`, or inlining scripts into interpreters. One command per Bash call. A single `>` redirect is allowed (fixture generation). Never use echo/printf/heredoc to WRITE source files (use Write/Edit).
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new test; ensure each mutation fails a named test (substitute a biting one if needed).
- Cross-val must drive genuine LXMF/LXStamper (new isolated `lxmf_peering_fixtures.json`; do NOT touch other fixtures). Reference env: `/Users/ell/opt/anaconda3/envs/rns/bin/python`. Keep generation costs LOW (≤ 4).
- Commit trailers (exact); the `;` means author the message with the Write tool to `/tmp/ReTiCA/` and `git commit -F`, never `-m`:
  - `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`

---

### Task 1: `LXStamper` peering/PN validators + cross-val

**Files:**
- Modify: `Sources/ReTiCA/LXMF/LXStamper.swift` (add constants + two validators before the closing `}`, line 46)
- Modify: `Sources/ReTiCA/LXMF/LXMessage.swift` (fix the stale file-header doc comment, lines 3-6)
- Create: `Tests/ReTiCATests/Vectors/generate_lxmf_peering_fixtures.py`
- Create (generated): `Tests/ReTiCATests/Vectors/lxmf_peering_fixtures.json`
- Create: `Tests/ReTiCATests/Vectors/LXMFPeeringFixtures.swift`
- Create: `Tests/ReTiCATests/Vectors/LXStamperPeeringCrossValidationTests.swift`
- Modify: `Package.swift` (add the new fixture to the `ReTiCATests` resources)

**Interfaces:**
- Consumes: `LXStamper.stampWorkblock(material:expandRounds:)`, `.stampValid`, `.stampValue`, `.stampSize`; `Crypto.fullHash`; `Data(hexString:)`.
- Produces: `LXStamper.workblockExpandRoundsPeering` (25), `.workblockExpandRoundsPN` (1000), `.validatePeeringKey(peeringId:peeringKey:targetCost:) -> Bool`, `.validatePnStamp(transientData:targetCost:) -> (transientId:lxmfData:value:stamp:)?`.

- [ ] **Step 1: Add the validators to `LXStamper`**

In `Sources/ReTiCA/LXMF/LXStamper.swift`, before the closing `}` (after `generateStamp`, line 46), add:

```swift
    public static let workblockExpandRoundsPeering = 25     // RNS WORKBLOCK_EXPAND_ROUNDS_PEERING
    public static let workblockExpandRoundsPN = 1000        // RNS WORKBLOCK_EXPAND_ROUNDS_PN

    /// Validate a peering key: a stamp over `peeringId` with the short (25-round) workblock
    /// (RNS LXStamper.validate_peering_key).
    public static func validatePeeringKey(peeringId: Data, peeringKey: Data, targetCost: Int) -> Bool {
        stampValid(stamp: peeringKey, targetCost: targetCost,
                   workblock: stampWorkblock(material: peeringId, expandRounds: workblockExpandRoundsPeering))
    }

    /// Validate a propagation-node stamp appended to lxmf_data (`transientData = lxmf_data ‖ stamp[32]`):
    /// strip the trailing 32-byte stamp, recompute `transient_id = full_hash(lxm_data)`, and validate over
    /// the medium (1000-round) workblock. Returns (transientId, lxmfData, value, stamp) or nil
    /// (RNS LXStamper.validate_pn_stamp).
    public static func validatePnStamp(transientData: Data, targetCost: Int)
        -> (transientId: Data, lxmfData: Data, value: Int, stamp: Data)? {
        guard transientData.count > stampSize else { return nil }
        let lxmfData = Data(transientData.dropLast(stampSize))
        let stamp = Data(transientData.suffix(stampSize))
        let transientId = Crypto.fullHash(lxmfData)
        let wb = stampWorkblock(material: transientId, expandRounds: workblockExpandRoundsPN)
        guard stampValid(stamp: stamp, targetCost: targetCost, workblock: wb) else { return nil }
        return (transientId, lxmfData, stampValue(workblock: wb, stamp: stamp), stamp)
    }
```

- [ ] **Step 2: Fix the stale `LXMessage` file-header doc comment**

In `Sources/ReTiCA/LXMF/LXMessage.swift`, replace the struct's file-header doc comment (lines 3-6):

```swift
/// A Lightweight Extensible Message Format (LXMF) message — the RNS application message envelope.
/// Pure value type, byte-compatible with reference lxmf 1.1.0 (LXMessage.py). LXMF-1 scope: the
/// message core with an empty `fields` map (plain title+content messages); rich integer-keyed
/// fields and stamps are deferred to later slices.
```

with:

```swift
/// A Lightweight Extensible Message Format (LXMF) message — the RNS application message envelope.
/// Pure value type, byte-compatible with reference lxmf 1.1.0 (LXMessage.py). Carries the message core
/// plus optional rich integer-keyed `fields` (LXMF-5a) and an optional proof-of-work `stamp` (LXMF-5b,
/// the payload's 5th element).
```

- [ ] **Step 3: Write the fixture generator**

Create `Tests/ReTiCATests/Vectors/generate_lxmf_peering_fixtures.py`:

```python
#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_lxmf_peering_fixtures.py > lxmf_peering_fixtures.json
#
# Emits genuine lxmf 1.1.0 LXStamper peering-key and PN-stamp artefacts so the Swift validators can be
# cross-validated. Costs are small (4) so generation is fast. Workblocks (6 KB peering / 256 KB PN) are
# emitted as their full_hash (compact). RNS logging is suppressed so stdout JSON stays clean.
import logging
logging.disable(logging.CRITICAL)
import json
import RNS
import LXMF.LXStamper as LXStamper
RNS.loglevel = -1

# --- Peering key: a stamp over peering_id with the 25-round workblock ---
peering_id   = bytes.fromhex("00112233445566778899aabbccddeeff")   # e.g. own.hash ‖ peer.hash (opaque here)
peering_cost = 4
peering_key  = LXStamper.generate_stamp(peering_id, peering_cost, expand_rounds=LXStamper.WORKBLOCK_EXPAND_ROUNDS_PEERING)
peering_wb   = LXStamper.stamp_workblock(peering_id, expand_rounds=LXStamper.WORKBLOCK_EXPAND_ROUNDS_PEERING)

# --- PN stamp: a stamp appended to lxmf_data, over transient_id, with the 1000-round workblock ---
lxmf_data    = bytes.fromhex("aabbccddeeff00112233445566778899") + b"encrypted-lxmf-payload-placeholder"
transient_id = RNS.Identity.full_hash(lxmf_data)
pn_cost      = 4
pn_stamp     = LXStamper.generate_stamp(transient_id, pn_cost, expand_rounds=LXStamper.WORKBLOCK_EXPAND_ROUNDS_PN)
pn_wb        = LXStamper.stamp_workblock(transient_id, expand_rounds=LXStamper.WORKBLOCK_EXPAND_ROUNDS_PN)
transient_data = lxmf_data + pn_stamp
pn_value     = LXStamper.stamp_value(pn_wb, pn_stamp)

print(json.dumps({
    "workblock_expand_rounds_peering": LXStamper.WORKBLOCK_EXPAND_ROUNDS_PEERING,
    "workblock_expand_rounds_pn": LXStamper.WORKBLOCK_EXPAND_ROUNDS_PN,
    "peering_id": peering_id.hex(),
    "peering_cost": peering_cost,
    "peering_key": peering_key.hex(),
    "peering_workblock_hash": RNS.Identity.full_hash(peering_wb).hex(),
    "lxmf_data": lxmf_data.hex(),
    "pn_cost": pn_cost,
    "pn_stamp": pn_stamp.hex(),
    "transient_data": transient_data.hex(),
    "transient_id": transient_id.hex(),
    "pn_value": pn_value,
    "pn_workblock_hash": RNS.Identity.full_hash(pn_wb).hex(),
}, indent=2))
```

- [ ] **Step 4: Generate the fixture**

Run (single command, one redirect):

```bash
/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/generate_lxmf_peering_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/lxmf_peering_fixtures.json
```

Expected: JSON with `workblock_expand_rounds_peering: 25`, `workblock_expand_rounds_pn: 1000`, a `peering_key`, a `pn_stamp`, `transient_id`, `pn_value`, and the two workblock hashes. (If the generator errors, fix the generator — never hand-write the JSON.)

- [ ] **Step 5: Register the fixture resource**

In `Package.swift`, append `.process("Vectors/lxmf_peering_fixtures.json")` to the `ReTiCATests` target's `resources:` array.

- [ ] **Step 6: Write the fixtures decoder**

Create `Tests/ReTiCATests/Vectors/LXMFPeeringFixtures.swift`:

```swift
import Foundation

struct LXMFPeeringFixtures: Decodable {
    let workblockExpandRoundsPeering: Int
    let workblockExpandRoundsPN: Int
    let peeringId: String
    let peeringCost: Int
    let peeringKey: String
    let peeringWorkblockHash: String
    let lxmfData: String
    let pnCost: Int
    let pnStamp: String
    let transientData: String
    let transientId: String
    let pnValue: Int
    let pnWorkblockHash: String

    enum CodingKeys: String, CodingKey {
        case workblockExpandRoundsPeering = "workblock_expand_rounds_peering"
        case workblockExpandRoundsPN = "workblock_expand_rounds_pn"
        case peeringId = "peering_id"
        case peeringCost = "peering_cost"
        case peeringKey = "peering_key"
        case peeringWorkblockHash = "peering_workblock_hash"
        case lxmfData = "lxmf_data"
        case pnCost = "pn_cost"
        case pnStamp = "pn_stamp"
        case transientData = "transient_data"
        case transientId = "transient_id"
        case pnValue = "pn_value"
        case pnWorkblockHash = "pn_workblock_hash"
    }

    static func load() throws -> LXMFPeeringFixtures {
        let url = Bundle.module.url(forResource: "lxmf_peering_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(LXMFPeeringFixtures.self, from: Data(contentsOf: url))
    }
}
```

- [ ] **Step 7: Write the cross-val tests**

Create `Tests/ReTiCATests/Vectors/LXStamperPeeringCrossValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func peeringStampConstantsMatchReference() throws {
    let f = try LXMFPeeringFixtures.load()
    #expect(LXStamper.workblockExpandRoundsPeering == f.workblockExpandRoundsPeering)
    #expect(LXStamper.workblockExpandRoundsPN == f.workblockExpandRoundsPN)
}

@Test func validatePeeringKeyMatchesReference() throws {
    let f = try LXMFPeeringFixtures.load()
    let peeringId = Data(hexString: f.peeringId)!
    let key = Data(hexString: f.peeringKey)!
    #expect(LXStamper.validatePeeringKey(peeringId: peeringId, peeringKey: key, targetCost: f.peeringCost) == true)
    // Workblock byte-parity (short 25-round).
    let wb = LXStamper.stampWorkblock(material: peeringId, expandRounds: LXStamper.workblockExpandRoundsPeering)
    #expect(Crypto.fullHash(wb) == Data(hexString: f.peeringWorkblockHash)!)
    // A tampered key does not validate.
    var bad = Array(key); bad[0] ^= 0x01
    #expect(LXStamper.validatePeeringKey(peeringId: peeringId, peeringKey: Data(bad), targetCost: f.peeringCost) == false)
}

@Test func validatePnStampMatchesReference() throws {
    let f = try LXMFPeeringFixtures.load()
    let transientData = Data(hexString: f.transientData)!
    let result = LXStamper.validatePnStamp(transientData: transientData, targetCost: f.pnCost)
    #expect(result != nil)
    #expect(result?.transientId == Data(hexString: f.transientId)!)
    #expect(result?.lxmfData == Data(hexString: f.lxmfData)!)
    #expect(result?.value == f.pnValue)
    // Workblock byte-parity (medium 1000-round), keyed on the recovered transient_id.
    let wb = LXStamper.stampWorkblock(material: Data(hexString: f.transientId)!,
                                      expandRounds: LXStamper.workblockExpandRoundsPN)
    #expect(Crypto.fullHash(wb) == Data(hexString: f.pnWorkblockHash)!)
    // Too-short data → nil; tampered stamp → nil.
    #expect(LXStamper.validatePnStamp(transientData: Data(repeating: 0, count: 10), targetCost: f.pnCost) == nil)
    var tampered = Array(transientData); tampered[tampered.count - 1] ^= 0x01
    #expect(LXStamper.validatePnStamp(transientData: Data(tampered), targetCost: f.pnCost) == nil)
}
```

- [ ] **Step 8: Run the cross-val — verify it passes**

Run: `swift test --filter LXStamperPeeringCrossValidationTests`
Expected: PASS (3).

- [ ] **Step 9: Mutation verification (one at a time)**

Apply each in `Sources/ReTiCA/LXMF/LXStamper.swift`, run `swift test --filter LXStamperPeeringCrossValidationTests`, confirm the named test fails, revert, confirm pass. (If a proposed mutation does not bite for the specific fixture values, substitute one that does and record it.)

1. **Peering uses the wrong rounds** — in `validatePeeringKey`, change `expandRounds: workblockExpandRoundsPeering` to `expandRounds: workblockExpandRoundsPN`.
   → `validatePeeringKeyMatchesReference` FAILS (wrong workblock → key invalid + workblock-hash mismatch; note this call now also does 1000 rounds, still fast).
2. **PN stamp split wrong** — in `validatePnStamp`, change `dropLast(stampSize)` / `suffix(stampSize)` to `dropLast(stampSize - 1)` / `suffix(stampSize - 1)`.
   → `validatePnStampMatchesReference` FAILS (`transientId`/`lxmfData` wrong; stamp likely invalid → nil).
3. **PN uses the wrong rounds** — in `validatePnStamp`, change `expandRounds: workblockExpandRoundsPN` to `expandRounds: workblockExpandRoundsPeering`.
   → `validatePnStampMatchesReference` FAILS (workblock-hash mismatch and stamp invalid → nil).
4. **Constant drift** — change `workblockExpandRoundsPeering = 25` to `= 24`.
   → `peeringStampConstantsMatchReference` FAILS (and `validatePeeringKeyMatchesReference`).

After each: revert, re-run, expect PASS.

- [ ] **Step 10: Full test gate**

Run: `swift test`
Expected: PASS. The 5b baseline was 463 passed / 1 pre-existing live-node skip / 0 fail; this slice adds 3 tests → 466 passed. On a signal-11/signal-10 build flake, run `swift package clean` (single command) and re-run.

- [ ] **Step 11: Commit**

Write the message to `/tmp/ReTiCA/commit-msg-5c.txt` with the Write tool (body below), then:

```bash
git add Sources/ReTiCA/LXMF/LXStamper.swift Sources/ReTiCA/LXMF/LXMessage.swift Tests/ReTiCATests/Vectors/generate_lxmf_peering_fixtures.py Tests/ReTiCATests/Vectors/lxmf_peering_fixtures.json Tests/ReTiCATests/Vectors/LXMFPeeringFixtures.swift Tests/ReTiCATests/Vectors/LXStamperPeeringCrossValidationTests.swift Package.swift
```

```bash
git commit -F /tmp/ReTiCA/commit-msg-5c.txt
```

Commit message body:

```
feat: LXMF-5c — propagation/peering stamps

LXStamper gains validatePeeringKey (stamp over peering_id, 25-round
workblock) and validatePnStamp (stamp appended to lxmf_data, over
transient_id, 1000-round workblock; strips the 32-byte stamp, recomputes
transient_id), reusing the 5b workblock/valid/value. Closes the peering-
key gap deferred by LXMF-4d-5. Byte-cross-validated vs genuine lxmf 1.1.0
LXStamper with a new isolated peering fixture. Also fixes the stale
LXMessage file-header doc comment (fields + stamps now supported).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Self-Review

**Spec coverage:**
- Spec constants (`workblockExpandRoundsPeering=25`, `workblockExpandRoundsPN=1000`) → Step 1. ✓
- Spec `validatePeeringKey` (25-round workblock) → Step 1. ✓
- Spec `validatePnStamp` (strip stamp, recompute transient_id, 1000-round, returns tuple/nil) → Step 1. ✓
- Spec cross-val (isolated fixture/generator/decoder/tests + Package.swift) → Steps 3-7. ✓
- Spec test 1 (constants) → `peeringStampConstantsMatchReference`. ✓
- Spec test 2 (peering key validates + workblock parity + tamper→false) → `validatePeeringKeyMatchesReference`. ✓
- Spec test 3 (PN stamp validates + transientId/lxmfData/value + workblock parity + too-short/tamper→nil) → `validatePnStampMatchesReference`. ✓
- Spec "also fix the stale LXMessage header comment" → Step 2. ✓

**Placeholder scan:** none.

**Type consistency:** `validatePeeringKey(peeringId:peeringKey:targetCost:) -> Bool` and `validatePnStamp(transientData:targetCost:) -> (transientId:lxmfData:value:stamp:)?` match the test call sites; both reuse `stampWorkblock(material:expandRounds:)`/`stampValid`/`stampValue`/`stampSize`. Fixture keys match the generator emission and `LXMFPeeringFixtures` `CodingKeys`.
