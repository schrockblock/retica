# LXMF PN Announce app-data Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pure `PNAnnounce` (pack/parse/isValid) for the propagation-node announce app-data, plus `MsgPack` boolean support it needs — byte-cross-validated against genuine LXMF.

**Architecture:** Add `MsgPackValue.bool` (`0xC2`/`0xC3`) to the pure codec; add a zero-dep `PNAnnounce` value type for the 7-element announce array. Byte-cross-validated via a new isolated fixture (genuine `msgpack.packb` + `pn_announce_data_is_valid`).

**Tech Stack:** Swift, SwiftPM, swift-testing (`@Test`). Cross-validation from genuine LXMF in the conda `rns` env.

## Global Constraints

- Commit directly to `main`; no feature branch, no finishing-a-development-branch merge dance.
- No compound shell commands: no `|` chains, `&&`, `||`, `;`, `$(...)`-feeding, `xargs`, or inlining scripts into interpreters. One command per Bash call. A single `>` redirect is allowed (fixture generation). Never use echo/printf/heredoc to WRITE source files (use Write/Edit).
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new test.
- Cross-val must drive genuine LXMF (new isolated `lxmf_pn_announce_fixtures.json`; do NOT touch other fixtures). Reference env: `/Users/ell/opt/anaconda3/envs/rns/bin/python`.
- Commit trailers (exact); the `;` means author the message with the Write tool to `/tmp/ReTiCA/` and `git commit -F`, never `-m`:
  - `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`

---

### Task 1: `MsgPack.bool` + `PNAnnounce` + cross-val

**Files:**
- Modify: `Sources/ReTiCA/Support/MsgPack.swift` (add `.bool` to encode/parse/`MsgPackValue`; refresh the doc comment)
- Create: `Sources/ReTiCA/LXMF/PNAnnounce.swift`
- Create: `Tests/ReTiCATests/MsgPackBoolTests.swift`
- Create: `Tests/ReTiCATests/Vectors/generate_lxmf_pn_announce_fixtures.py`
- Create (generated): `Tests/ReTiCATests/Vectors/lxmf_pn_announce_fixtures.json`
- Create: `Tests/ReTiCATests/Vectors/LXMFPNAnnounceFixtures.swift`
- Create: `Tests/ReTiCATests/Vectors/PNAnnounceCrossValidationTests.swift`
- Modify: `Package.swift` (add the new fixture to `ReTiCATests` resources)

**Interfaces:**
- Consumes: `MsgPack.encode`/`decodeValue`; `Data(hexString:)`.
- Produces: `MsgPackValue.bool(Bool)`; `PNAnnounce` (`timebase`,`nodeState`,`perTransferLimit`,`perSyncLimit`,`targetStampCost`,`stampCostFlexibility`,`peeringCost`,`metadata`,`packed`,`parse`,`isValid`).

- [ ] **Step 1: Add `MsgPack` boolean support**

In `Sources/ReTiCA/Support/MsgPack.swift`:

(a) In `MsgPackValue` (after `case array([MsgPackValue])`, line 149) add:

```swift
    case bool(Bool)
```

(b) In the `encode` switch (after `case let .array(items): return encodeArray(items)`, line 32) add:

```swift
        case let .bool(b):    return Data([b ? 0xC3 : 0xC2])
```

(c) In `parse`, add two cases (next to `case 0xC0:` for null, ~line 89):

```swift
        case 0xC2: return (.bool(false), i + 1)
        case 0xC3: return (.bool(true), i + 1)
```

(d) Refresh the `MsgPackValue` doc comment (lines 140-141) to reflect the full set:

```swift
/// A MessagePack value covering the subset Reticulum uses: unsigned ints, byte strings, UTF-8 strings,
/// booleans, nil, float64, arrays, ordered string-keyed maps, and ordered integer-keyed maps (`intMap`).
```

- [ ] **Step 2: Write the MsgPack bool unit test**

Create `Tests/ReTiCATests/MsgPackBoolTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func msgPackBoolRoundTrips() throws {
    #expect(Array(MsgPack.encode(.bool(false))) == [0xC2])
    #expect(Array(MsgPack.encode(.bool(true))) == [0xC3])
    #expect(MsgPack.decodeValue(Data([0xC2])) == .bool(false))
    #expect(MsgPack.decodeValue(Data([0xC3])) == .bool(true))
}

@Test func msgPackBoolInArrayRoundTrips() throws {
    let v = MsgPackValue.array([.bool(false), .uint(7), .bool(true)])
    #expect(MsgPack.decodeValue(MsgPack.encode(v)) == v)
}
```

- [ ] **Step 3: Implement `PNAnnounce`**

Create `Sources/ReTiCA/LXMF/PNAnnounce.swift`:

```swift
import Foundation

/// Propagation-node announce app-data (LXMF discovery). A msgpack 7-element array a propagation node
/// includes in its RNS announce so clients can read its config. Mirrors lxmf 1.1.0
/// LXMRouter.get_propagation_node_app_data / pn_announce_data_is_valid:
/// `[false, timebase, node_state, per_transfer_limit, per_sync_limit, [stamp_cost, flex, peering_cost], metadata]`.
/// Field semantics (auto-peering, limit enforcement) are app/mesh-level; this is the wire format + validity.
public struct PNAnnounce: Equatable {
    public var timebase: Int
    public var nodeState: Bool
    public var perTransferLimit: Int
    public var perSyncLimit: Int
    public var targetStampCost: Int
    public var stampCostFlexibility: Int
    public var peeringCost: Int
    public var metadata: MsgPackValue          // element [6]; empty map by default

    public init(timebase: Int, nodeState: Bool, perTransferLimit: Int, perSyncLimit: Int,
                targetStampCost: Int, stampCostFlexibility: Int, peeringCost: Int,
                metadata: MsgPackValue = .map([])) {
        self.timebase = timebase; self.nodeState = nodeState
        self.perTransferLimit = perTransferLimit; self.perSyncLimit = perSyncLimit
        self.targetStampCost = targetStampCost; self.stampCostFlexibility = stampCostFlexibility
        self.peeringCost = peeringCost; self.metadata = metadata
    }

    public var packed: Data {
        MsgPack.encode(.array([
            .bool(false),                       // [0] legacy flag
            .uint(UInt64(timebase)),
            .bool(nodeState),
            .uint(UInt64(perTransferLimit)),
            .uint(UInt64(perSyncLimit)),
            .array([.uint(UInt64(targetStampCost)), .uint(UInt64(stampCostFlexibility)), .uint(UInt64(peeringCost))]),
            metadata,
        ]))
    }

    /// Parse + validate announce app-data. Returns nil unless the msgpack shape matches
    /// pn_announce_data_is_valid: >= 7 elements, [1] uint, [2] bool, [3]/[4] uint, [5] a 3-uint array,
    /// [6] a map. Element [0] (legacy flag) is ignored.
    public static func parse(_ data: Data) -> PNAnnounce? {
        guard case let .array(items)? = MsgPack.decodeValue(data), items.count >= 7,
              case let .uint(timebase) = items[1],
              case let .bool(nodeState) = items[2],
              case let .uint(transfer) = items[3],
              case let .uint(sync) = items[4],
              case let .array(costs) = items[5], costs.count == 3,
              case let .uint(cost) = costs[0], case let .uint(flex) = costs[1], case let .uint(peer) = costs[2]
        else { return nil }
        let metadata = items[6]
        switch metadata {
        case .map, .intMap: break
        default: return nil
        }
        return PNAnnounce(timebase: Int(timebase), nodeState: nodeState,
                          perTransferLimit: Int(transfer), perSyncLimit: Int(sync),
                          targetStampCost: Int(cost), stampCostFlexibility: Int(flex),
                          peeringCost: Int(peer), metadata: metadata)
    }

    /// True iff `data` is well-formed announce app-data (mirrors pn_announce_data_is_valid).
    public static func isValid(_ data: Data) -> Bool { parse(data) != nil }
}
```

- [ ] **Step 4: Write the fixture generator**

Create `Tests/ReTiCATests/Vectors/generate_lxmf_pn_announce_fixtures.py`:

```python
#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_lxmf_pn_announce_fixtures.py > lxmf_pn_announce_fixtures.json
#
# Emits a genuine lxmf 1.1.0 propagation-node announce app_data: the exact 7-element list layout of
# LXMRouter.get_propagation_node_app_data, encoded with genuine msgpack.packb and validated by genuine
# pn_announce_data_is_valid. Also emits an invalid (6-element) sample. RNS logging suppressed for clean JSON.
import logging
logging.disable(logging.CRITICAL)
import json
import RNS.vendor.umsgpack as msgpack
import LXMF
from LXMF.LXMF import pn_announce_data_is_valid

timebase             = 1700000000
node_state           = True
per_transfer_limit   = LXMF.LXMRouter.PROPAGATION_LIMIT           # 256 (KB)
per_sync_limit       = LXMF.LXMRouter.PROPAGATION_LIMIT * 40      # SYNC_LIMIT
target_stamp_cost    = LXMF.LXMRouter.PROPAGATION_COST            # 16
stamp_cost_flex      = LXMF.LXMRouter.PROPAGATION_COST_FLEX       # 3
peering_cost         = 18

announce_data = [False, timebase, node_state, per_transfer_limit, per_sync_limit,
                 [target_stamp_cost, stamp_cost_flex, peering_cost], {}]
packed = msgpack.packb(announce_data)
assert pn_announce_data_is_valid(packed) is True, "genuine validator rejected the announce"

invalid = msgpack.packb([False, timebase, node_state, per_transfer_limit, per_sync_limit, [target_stamp_cost]])  # 6 elems
assert pn_announce_data_is_valid(invalid) is False, "genuine validator accepted a malformed announce"

print(json.dumps({
    "timebase": timebase,
    "node_state": node_state,
    "per_transfer_limit": per_transfer_limit,
    "per_sync_limit": per_sync_limit,
    "target_stamp_cost": target_stamp_cost,
    "stamp_cost_flexibility": stamp_cost_flex,
    "peering_cost": peering_cost,
    "packed": packed.hex(),
    "invalid_packed": invalid.hex(),
}, indent=2))
```

- [ ] **Step 5: Generate the fixture**

Run (single command, one redirect):

```bash
/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/generate_lxmf_pn_announce_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/lxmf_pn_announce_fixtures.json
```

Expected: JSON with `per_transfer_limit: 256`, `target_stamp_cost: 16`, a `packed` and an `invalid_packed`. (If it errors, fix the generator — never hand-write the JSON.)

- [ ] **Step 6: Register the fixture resource**

In `Package.swift`, append `.process("Vectors/lxmf_pn_announce_fixtures.json")` to the `ReTiCATests` target's `resources:` array.

- [ ] **Step 7: Write the fixtures decoder**

Create `Tests/ReTiCATests/Vectors/LXMFPNAnnounceFixtures.swift`:

```swift
import Foundation

struct LXMFPNAnnounceFixtures: Decodable {
    let timebase: Int
    let nodeState: Bool
    let perTransferLimit: Int
    let perSyncLimit: Int
    let targetStampCost: Int
    let stampCostFlexibility: Int
    let peeringCost: Int
    let packed: String
    let invalidPacked: String

    enum CodingKeys: String, CodingKey {
        case timebase
        case nodeState = "node_state"
        case perTransferLimit = "per_transfer_limit"
        case perSyncLimit = "per_sync_limit"
        case targetStampCost = "target_stamp_cost"
        case stampCostFlexibility = "stamp_cost_flexibility"
        case peeringCost = "peering_cost"
        case packed
        case invalidPacked = "invalid_packed"
    }

    static func load() throws -> LXMFPNAnnounceFixtures {
        let url = Bundle.module.url(forResource: "lxmf_pn_announce_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(LXMFPNAnnounceFixtures.self, from: Data(contentsOf: url))
    }
}
```

- [ ] **Step 8: Write the cross-val tests**

Create `Tests/ReTiCATests/Vectors/PNAnnounceCrossValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func pnAnnounceParsesReference() throws {
    let f = try LXMFPNAnnounceFixtures.load()
    let a = PNAnnounce.parse(Data(hexString: f.packed)!)
    #expect(a != nil)
    #expect(a?.timebase == f.timebase)
    #expect(a?.nodeState == f.nodeState)
    #expect(a?.perTransferLimit == f.perTransferLimit)
    #expect(a?.perSyncLimit == f.perSyncLimit)
    #expect(a?.targetStampCost == f.targetStampCost)
    #expect(a?.stampCostFlexibility == f.stampCostFlexibility)
    #expect(a?.peeringCost == f.peeringCost)
    #expect(a?.metadata == .map([]))
}

@Test func pnAnnouncePackMatchesReference() throws {
    let f = try LXMFPNAnnounceFixtures.load()
    let a = PNAnnounce(timebase: f.timebase, nodeState: f.nodeState,
                       perTransferLimit: f.perTransferLimit, perSyncLimit: f.perSyncLimit,
                       targetStampCost: f.targetStampCost, stampCostFlexibility: f.stampCostFlexibility,
                       peeringCost: f.peeringCost)
    #expect(a.packed == Data(hexString: f.packed)!)                 // byte-parity vs genuine msgpack.packb
}

@Test func pnAnnounceValidityMatchesReference() throws {
    let f = try LXMFPNAnnounceFixtures.load()
    #expect(PNAnnounce.isValid(Data(hexString: f.packed)!) == true)
    #expect(PNAnnounce.isValid(Data(hexString: f.invalidPacked)!) == false)   // 6-element → invalid, agrees with genuine
}
```

- [ ] **Step 9: Run the new tests — verify they pass**

Run: `swift test --filter MsgPackBoolTests`
Then: `swift test --filter PNAnnounceCrossValidationTests`
Expected: PASS (2 + 3).

- [ ] **Step 10: Mutation verification (one at a time)**

Apply each individually, run the relevant `--filter`, confirm the named test fails, revert, confirm pass.

1. **Bool encodes wrong** — in `encode(.bool)`, swap to `Data([b ? 0xC2 : 0xC3])`.
   → `msgPackBoolRoundTrips` FAILS and `pnAnnouncePackMatchesReference` FAILS (nodeState byte wrong).
2. **PNAnnounce packs the wrong shape** — in `packed`, drop the `.bool(false)` legacy element (6-element array).
   → `pnAnnouncePackMatchesReference` FAILS (≠ reference) and `pnAnnounceParsesReference` round is unaffected, but the reference no longer round-trips through our pack.
3. **parse mis-types the nodeState field** — in `parse`, change `case let .bool(nodeState) = items[2]` to `case let .uint(u) = items[2]` (and, to compile, `let nodeState = u != 0` on the next line).
   → `pnAnnounceParsesReference` FAILS: the reference `items[2]` is a msgpack bool, so the `.uint` pattern no longer matches → `parse` returns nil → `a != nil` fails. (Confirms the announce's boolean fields are parsed as bools, exercising the new `.bool` support end-to-end.)
4. **parse mis-reads a field** — change `case let .uint(transfer) = items[3]` handling to read `items[4]` for `transfer` (swap transfer/sync indices).
   → `pnAnnounceParsesReference` FAILS (perTransferLimit/perSyncLimit swapped ≠ reference).

(For each mutation, confirm it actually fails a NAMED test; if a proposed one does not bite, substitute a biting one and record it.)

After each: revert, re-run, expect PASS.

- [ ] **Step 11: Full test gate**

Run: `swift test`
Expected: PASS. The LXMF-4d-3b baseline was 471 passed / 1 pre-existing live-node skip / 0 fail; this slice adds 2 + 3 tests → 476 passed. On a signal-11/signal-10 build flake, run `swift package clean` (single command) and re-run.

- [ ] **Step 12: Commit**

Write the message to `/tmp/ReTiCA/commit-msg-pnann.txt` with the Write tool (body below), then:

```bash
git add Sources/ReTiCA/Support/MsgPack.swift Sources/ReTiCA/LXMF/PNAnnounce.swift Tests/ReTiCATests/MsgPackBoolTests.swift Tests/ReTiCATests/Vectors/generate_lxmf_pn_announce_fixtures.py Tests/ReTiCATests/Vectors/lxmf_pn_announce_fixtures.json Tests/ReTiCATests/Vectors/LXMFPNAnnounceFixtures.swift Tests/ReTiCATests/Vectors/PNAnnounceCrossValidationTests.swift Package.swift
```

```bash
git commit -F /tmp/ReTiCA/commit-msg-pnann.txt
```

Commit message body:

```
feat: LXMF PN announce app-data + MsgPack bool

MsgPackValue gains .bool (0xC2/0xC3). New pure PNAnnounce (pack/parse/
isValid) for the propagation-node announce app_data — msgpack([false,
timebase, node_state, transfer_limit, sync_limit, [stamp_cost,flex,
peering_cost], metadata]). Byte-cross-validated vs genuine lxmf 1.1.0
(msgpack.packb + pn_announce_data_is_valid) with a new isolated fixture;
2 MsgPack bool + 3 announce cross-val tests. Announce mechanics + field
semantics deferred.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Self-Review

**Spec coverage:**
- Spec MsgPack `.bool` (encode/parse/case + doc refresh) → Step 1 + unit test Step 2. ✓
- Spec `PNAnnounce` (fields, `packed`, `parse` structural validation, `isValid`) → Step 3. ✓
- Spec cross-val (isolated generator/fixture/decoder/tests + Package.swift) → Steps 4-8. ✓
- Spec test 1 (parse recovers fields) → `pnAnnounceParsesReference`. ✓
- Spec test 2 (pack byte-parity) → `pnAnnouncePackMatchesReference`. ✓
- Spec test 3 (isValid valid + invalid) → `pnAnnounceValidityMatchesReference`. ✓
- Spec test 4 (MsgPack bool) → `MsgPackBoolTests`. ✓

**Placeholder scan:** the Step-10 mutation note tells the implementer to pick/substitute a biting mutation (a real instruction, not a placeholder); production/test steps show exact code.

**Type consistency:** `MsgPackValue.bool(Bool)` used in encode/parse and PNAnnounce and tests. `PNAnnounce.init(...)` parameter list matches the call site in `pnAnnouncePackMatchesReference`; `parse`/`isValid`/`packed` match the test usages. Fixture keys (`node_state`, `per_transfer_limit`, `target_stamp_cost`, `packed`, `invalid_packed`, …) match the generator emission and `LXMFPNAnnounceFixtures` `CodingKeys`.
