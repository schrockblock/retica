# LXMF-5b: Delivery-Stamp Proof-of-Work Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add LXMF delivery-stamp proof-of-work: a pure `LXStamper` (workblock / valid / value / generate) and `LXMessage` stamp inclusion (5-element payload, hash over `payload[:4]`, `validateStamp`).

**Architecture:** Two pure-core additions. `LXStamper` mirrors genuine `LXStamper.py`; `LXMessage` gains an optional `stamp` attached via `withStamp` (generation stays in `LXStamper`, so the cross-val can attach the reference stamp for byte-parity). Byte-cross-validated with a new isolated `lxmf_stamp_fixtures.json`.

**Tech Stack:** Swift, SwiftPM, swift-testing (`@Test`). Cross-validation from genuine LXMF/LXStamper in the conda `rns` env.

## Global Constraints

- Commit directly to `main`; no feature branch, no finishing-a-development-branch merge dance.
- No compound shell commands: no `|` chains, `&&`, `||`, `;`, `$(...)`-feeding, `xargs`, or inlining scripts into interpreters. One command per Bash call. A single `>` redirect is allowed (fixture generation). Never use echo/printf/heredoc to WRITE source files (use Write/Edit).
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new test.
- Cross-val must drive genuine LXMF/LXStamper (new isolated `lxmf_stamp_fixtures.json`; do NOT touch other fixtures). Reference env: `/Users/ell/opt/anaconda3/envs/rns/bin/python`. Ed25519 hedged → signatures validated; workblock/stamp/hash deterministic and pinned. Keep our `generateStamp` test cost LOW (≤ 8) so the 768 KB workblock + search stay fast.
- Commit trailers (exact); the `;` means author the message with the Write tool to `/tmp/ReTiCA/` and `git commit -F`, never `-m`:
  - `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`

---

### Task 1: `LXStamper` core + cross-validation fixture

**Files:**
- Create: `Sources/ReTiCA/LXMF/LXStamper.swift`
- Create: `Tests/ReTiCATests/Vectors/generate_lxmf_stamp_fixtures.py`
- Create (generated): `Tests/ReTiCATests/Vectors/lxmf_stamp_fixtures.json`
- Create: `Tests/ReTiCATests/Vectors/LXMFStampFixtures.swift`
- Create: `Tests/ReTiCATests/Vectors/LXStamperCrossValidationTests.swift`
- Modify: `Package.swift` (add the new fixture to the `ReTiCATests` resources)

**Interfaces:**
- Consumes: `Crypto.hkdf(length:derivedFrom:salt:context:)`, `Crypto.fullHash`, `MsgPack.encode(.uint(_:))`, `SecureRandom.bytes(_:)`, `Data(hexString:)`.
- Produces: `LXStamper.{workblockExpandRounds, stampSize, stampWorkblock, stampValid, stampValue, generateStamp}`. Fixture keys `message_id`, `stamp`, `stamp_cost`, `workblock_hash`, `stamp_value` (and the Task-2 message keys).

- [ ] **Step 1: Write the fixture generator**

Create `Tests/ReTiCATests/Vectors/generate_lxmf_stamp_fixtures.py`:

```python
#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_lxmf_stamp_fixtures.py > lxmf_stamp_fixtures.json
#
# Emits a genuine lxmf 1.1.0 stamped LXMessage plus the LXStamper artefacts so the Swift LXStamper and
# LXMessage stamp handling can be cross-validated. Stamp cost is small (8) so generation is fast. The
# workblock is 768 KB, so we emit its full_hash (compact) rather than the block itself. The stamp is a
# PoW search result (not reproducible), so the Swift byte-parity test attaches THIS exact stamp.
import json
import RNS
import LXMF
import LXMF.LXStamper as LXStamper

RNS.Transport.register_destination = staticmethod(lambda *a, **k: None)

src_id = RNS.Identity()
dst_id = RNS.Identity()
src = RNS.Destination(src_id, RNS.Destination.IN, RNS.Destination.SINGLE, "lxmf", "delivery")
dst = RNS.Destination(dst_id, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")

title = b"greeting"
content = b"hello stamp"
stamp_cost = 8
msg = LXMF.LXMessage(dst, src, content=content, title=title, stamp_cost=stamp_cost)
msg.timestamp = 1700000000.5
msg.defer_stamp = False        # generate the stamp during pack()
msg.pack()

message_id = msg.hash          # stamp is bound to the message_id (= hash over the 4-element payload)
stamp = msg.stamp
workblock = LXStamper.stamp_workblock(message_id)
workblock_hash = RNS.Identity.full_hash(workblock)
stamp_value = LXStamper.stamp_value(workblock, stamp)

print(json.dumps({
    "source_private_key": src_id.get_private_key().hex(),
    "destination_hash": dst.hash.hex(),
    "timestamp": msg.timestamp,
    "title": title.hex(),
    "content": content.hex(),
    "stamp_cost": stamp_cost,
    "message_id": message_id.hex(),
    "stamp": stamp.hex(),
    "workblock_hash": workblock_hash.hex(),
    "stamp_value": stamp_value,
    "hash": msg.hash.hex(),
    "signature": msg.signature.hex(),
    "packed": msg.packed.hex(),
}, indent=2))
```

- [ ] **Step 2: Generate the fixture**

Run (single command, one redirect):

```bash
/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/generate_lxmf_stamp_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/lxmf_stamp_fixtures.json
```

Expected: JSON with `stamp_cost: 8`, `message_id`, `stamp`, `workblock_hash`, `stamp_value`, and a 5-element `packed`. (If the generator errors, fix the generator — never hand-write the JSON.)

- [ ] **Step 3: Register the fixture resource**

In `Package.swift`, append `.process("Vectors/lxmf_stamp_fixtures.json")` to the `ReTiCATests` target's `resources:` array.

- [ ] **Step 4: Implement `LXStamper`**

Create `Sources/ReTiCA/LXMF/LXStamper.swift`:

```swift
import Foundation

/// LXMF proof-of-work stamps (LXMF-5b). A stamp is a 32-byte value whose full_hash(workblock ‖ stamp)
/// has at least `targetCost` leading zero bits, where the workblock is deterministically expanded from
/// the material (message_id). Validation is deterministic; generation is a brute-force search. Mirrors
/// lxmf 1.1.0 LXStamper (stamp_workblock / stamp_valid / stamp_value / generate_stamp).
public enum LXStamper {
    public static let workblockExpandRounds = 3000     // RNS WORKBLOCK_EXPAND_ROUNDS
    public static let stampSize = 32                   // RNS STAMP_SIZE (HASHLENGTH/8)

    /// Deterministic ~256*expandRounds-byte workblock: concat of hkdf(256, ikm=material,
    /// salt=full_hash(material ‖ msgpack(n))) for n in 0..<expandRounds.
    public static func stampWorkblock(material: Data, expandRounds: Int = workblockExpandRounds) -> Data {
        var wb = Data()
        for n in 0..<expandRounds {
            let salt = Crypto.fullHash(material + MsgPack.encode(.uint(UInt64(n))))
            wb += Crypto.hkdf(length: 256, derivedFrom: material, salt: salt, context: nil)
        }
        return wb
    }

    /// True iff full_hash(workblock ‖ stamp) has >= targetCost leading zero bits.
    public static func stampValid(stamp: Data, targetCost: Int, workblock: Data) -> Bool {
        stampValue(workblock: workblock, stamp: stamp) >= targetCost
    }

    /// Count of leading zero bits of full_hash(workblock ‖ stamp).
    public static func stampValue(workblock: Data, stamp: Data) -> Int {
        let digest = Crypto.fullHash(workblock + stamp)
        var value = 0
        for byte in digest {
            if byte == 0 { value += 8; continue }
            value += byte.leadingZeroBitCount
            break
        }
        return value
    }

    /// Search random 32-byte stamps until one is valid for `targetCost` over `messageId`'s workblock.
    public static func generateStamp(messageId: Data, targetCost: Int) -> Data {
        let wb = stampWorkblock(material: messageId)
        while true {
            let s = SecureRandom.bytes(stampSize)
            if stampValid(stamp: s, targetCost: targetCost, workblock: wb) { return s }
        }
    }
}
```

- [ ] **Step 5: Write the fixtures decoder**

Create `Tests/ReTiCATests/Vectors/LXMFStampFixtures.swift`:

```swift
import Foundation

struct LXMFStampFixtures: Decodable {
    let sourcePrivateKey: String
    let destinationHash: String
    let timestamp: Double
    let title: String
    let content: String
    let stampCost: Int
    let messageId: String
    let stamp: String
    let workblockHash: String
    let stampValue: Int
    let hash: String
    let signature: String
    let packed: String

    enum CodingKeys: String, CodingKey {
        case sourcePrivateKey = "source_private_key"
        case destinationHash = "destination_hash"
        case timestamp, title, content
        case stampCost = "stamp_cost"
        case messageId = "message_id"
        case stamp
        case workblockHash = "workblock_hash"
        case stampValue = "stamp_value"
        case hash, signature, packed
    }

    static func load() throws -> LXMFStampFixtures {
        let url = Bundle.module.url(forResource: "lxmf_stamp_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(LXMFStampFixtures.self, from: Data(contentsOf: url))
    }
}
```

- [ ] **Step 6: Write the LXStamper cross-val tests**

Create `Tests/ReTiCATests/Vectors/LXStamperCrossValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

/// Our LXStamper reproduces genuine lxmf 1.1.0 LXStamper: the deterministic workblock (pinned via its
/// full_hash), stamp validity, and stamp value; and our own generateStamp produces valid stamps.
@Test func lxStamperWorkblockAndValidateMatchReference() throws {
    let f = try LXMFStampFixtures.load()
    let messageId = Data(hexString: f.messageId)!
    let stamp = Data(hexString: f.stamp)!
    let wb = LXStamper.stampWorkblock(material: messageId)
    #expect(Crypto.fullHash(wb) == Data(hexString: f.workblockHash)!)          // workblock byte-parity
    #expect(LXStamper.stampValid(stamp: stamp, targetCost: f.stampCost, workblock: wb) == true)
    #expect(LXStamper.stampValue(workblock: wb, stamp: stamp) == f.stampValue)
}

@Test func lxStamperGeneratesValidStamp() throws {
    // Low cost keeps the search + 768 KB workblock cheap.
    let messageId = Crypto.fullHash(Data("stamp-gen-material".utf8))
    let cost = 4
    let stamp = LXStamper.generateStamp(messageId: messageId, targetCost: cost)
    #expect(stamp.count == LXStamper.stampSize)
    let wb = LXStamper.stampWorkblock(material: messageId)
    #expect(LXStamper.stampValid(stamp: stamp, targetCost: cost, workblock: wb) == true)
}
```

- [ ] **Step 7: Run the LXStamper cross-val — verify it passes**

Run: `swift test --filter LXStamperCrossValidationTests`
Expected: PASS (2). (These do 3000-round workblock expansion; a few hundred ms is normal.)

- [ ] **Step 8: Mutation verification (one at a time)**

Apply each in `Sources/ReTiCA/LXMF/LXStamper.swift`, run `swift test --filter LXStamperCrossValidationTests`, confirm fail, revert, confirm pass.

1. **Wrong workblock salt** — change the salt to `Crypto.fullHash(material)` (drop the `+ MsgPack.encode(.uint(UInt64(n)))`).
   → `lxStamperWorkblockAndValidateMatchReference` FAILS (workblock hash ≠ reference; likely also validity/value).
2. **Wrong value count** — in `stampValue`, change `value += 8` to `value += 7` for the all-zero-byte case.
   → `lxStamperWorkblockAndValidateMatchReference` FAILS (`stampValue` ≠ reference) — provided the reference value ≥ 8; if the reference `stamp_value` is < 8 the all-zero branch isn't exercised, so instead mutate `byte.leadingZeroBitCount` to `byte.leadingZeroBitCount + 1` which always shifts the value.
3. **Validity threshold off-by-one** — in `stampValid`, change `>= targetCost` to `> targetCost`.
   → `lxStamperWorkblockAndValidateMatchReference` FAILS if the reference stamp's value equals the cost exactly; to guarantee a bite, `lxStamperGeneratesValidStamp` also asserts validity of a freshly generated stamp whose value is ≥ cost — a `> targetCost` mutation makes `generateStamp` loop unless it finds value > cost, and the subsequent `stampValid` re-check with `>` would reject a value==cost stamp. If uncertain the mutation bites deterministically, prefer mutating `2^(256-target)` logic equivalently; the implementer should confirm the chosen mutation actually fails a named test and adjust to one that does.

(The implementer must ensure each mutation makes a *named test fail*; if a proposed mutation does not bite because of the specific reference values, substitute a meaningful mutation that does — e.g. `full_hash(workblock + stamp)` → `full_hash(stamp + workblock)` for validity/value — and record it.)

- [ ] **Step 9: Commit Task 1**

Write `/tmp/ReTiCA/commit-msg-5b-t1.txt` (body below), then `git add Sources/ReTiCA/LXMF/LXStamper.swift Tests/ReTiCATests/Vectors/generate_lxmf_stamp_fixtures.py Tests/ReTiCATests/Vectors/lxmf_stamp_fixtures.json Tests/ReTiCATests/Vectors/LXMFStampFixtures.swift Tests/ReTiCATests/Vectors/LXStamperCrossValidationTests.swift Package.swift` then `git commit -F /tmp/ReTiCA/commit-msg-5b-t1.txt`.

```
feat: LXMF-5b task 1 — LXStamper proof-of-work

Pure LXStamper: stampWorkblock (hkdf-expand 3000 rounds), stampValid /
stampValue (leading-zero-bits of full_hash(workblock‖stamp)), and
generateStamp (search). Byte-cross-validated vs genuine lxmf 1.1.0
LXStamper via a new isolated stamp fixture (workblock full_hash + valid
+ value pinned); our generateStamp verified to produce valid stamps.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

### Task 2: `LXMessage` stamp inclusion + cross-val

**Files:**
- Modify: `Sources/ReTiCA/LXMF/LXMessage.swift`
- Create: `Tests/ReTiCATests/Vectors/LXMFStampMessageCrossValidationTests.swift`

**Interfaces:**
- Consumes: `LXStamper` (Task 1); the `LXMFStampFixtures` decoder (Task 1); existing `LXMessage`.
- Produces: `LXMessage.stamp: Data?`, `LXMessage.withStamp(_:) -> LXMessage`, `LXMessage.validateStamp(targetCost:) -> Bool`.

- [ ] **Step 1: Thread the stamp through `LXMessage`**

In `Sources/ReTiCA/LXMF/LXMessage.swift`:

(a) Add the stored property after `fields` (line 18):

```swift
    public let stamp: Data?                       // optional PoW delivery stamp (payload 5th element)
```

(b) Replace `payloadBytes` (lines 32-36) to optionally append the stamp:

```swift
    private static func payloadBytes(timestamp: Double, title: Data, content: Data,
                                     fields: [MsgPackValue.IntPair], stamp: Data? = nil) -> Data {
        let fieldsValue: MsgPackValue = fields.isEmpty ? .map([]) : .intMap(fields)
        var items: [MsgPackValue] = [.double(timestamp), .bin(title), .bin(content), fieldsValue]
        if let stamp { items.append(.bin(stamp)) }
        return MsgPack.encode(.array(items))
    }
```

(c) In `create` (lines 49-51), pass `stamp: nil` to the init:

```swift
        return LXMessage(destinationHash: destinationHash, sourceHash: sourceHash,
                         timestamp: timestamp, title: title, content: content,
                         hash: hash, signature: signature, fields: fields, stamp: nil)
```

(d) Replace `packed` (lines 55-58):

```swift
    public var packed: Data {
        destinationHash + sourceHash + signature
            + LXMessage.payloadBytes(timestamp: timestamp, title: title, content: content,
                                     fields: fields, stamp: stamp)
    }
```

(e) Add `withStamp` and `validateStamp` after `packed` (before `unpack`):

```swift
    /// A copy of this message with a delivery stamp attached (hash/signature unchanged — the stamp is
    /// not part of the signed payload). The stamp is produced by `LXStamper.generateStamp(messageId: hash, …)`.
    public func withStamp(_ stamp: Data) -> LXMessage {
        LXMessage(destinationHash: destinationHash, sourceHash: sourceHash, timestamp: timestamp,
                  title: title, content: content, hash: hash, signature: signature, fields: fields, stamp: stamp)
    }

    /// Validate the attached stamp against `targetCost` (workblock derived from this message's hash).
    public func validateStamp(targetCost: Int) -> Bool {
        guard let stamp else { return false }
        return LXStamper.stampValid(stamp: stamp, targetCost: targetCost,
                                    workblock: LXStamper.stampWorkblock(material: hash))
    }
```

(f) Update the `unpack` doc comment (lines 60-62) and body (lines 63-86). Replace the doc comment with:

```swift
    /// Parse wire bytes back into a message (structure + recomputed hash). The payload is a 4-element
    /// array [float64, bin, bin, fields] — where `fields` is an empty map or an integer-keyed map — with
    /// an optional 5th `bin` stamp element. The hash is recomputed over the 4-element payload (the stamp
    /// is excluded, matching the reference). Returns nil for malformed input. Signature validation is separate.
```

Replace the guard + fields + return (lines 70-85) with:

```swift
        guard let value = MsgPack.decodeValue(packedPayload),
              case let .array(items) = value, items.count == 4 || items.count == 5,
              case let .double(timestamp) = items[0],
              case let .bin(title) = items[1],
              case let .bin(content) = items[2]
        else { return nil }
        let fields: [MsgPackValue.IntPair]
        switch items[3] {
        case let .map(pairs) where pairs.isEmpty: fields = []
        case let .intMap(pairs): fields = pairs
        default: return nil
        }
        let stamp: Data?
        if items.count == 5 {
            guard case let .bin(s) = items[4] else { return nil }
            stamp = s
        } else { stamp = nil }
        // Hash is over the 4-element payload only (stamp excluded); re-pack payload[:4] when a stamp is present.
        let hashPayload = items.count == 5
            ? payloadBytes(timestamp: timestamp, title: title, content: content, fields: fields)
            : packedPayload
        let hash = Crypto.fullHash(destinationHash + sourceHash + hashPayload)
        return LXMessage(destinationHash: destinationHash, sourceHash: sourceHash,
                         timestamp: timestamp, title: title, content: content,
                         hash: hash, signature: signature, fields: fields, stamp: stamp)
```

(g) In `validateSignature` (line 91), the `payloadBytes(...)` call already omits `stamp` (defaults nil) — leave it unchanged (4-element preimage).

- [ ] **Step 2: Write the message-stamp cross-val tests**

Create `Tests/ReTiCATests/Vectors/LXMFStampMessageCrossValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

/// Our LXMessage reproduces genuine lxmf 1.1.0's stamped 5-element wire form and validates its stamp.
@Test func stampedMessageUnpacksAndValidates() throws {
    let f = try LXMFStampFixtures.load()
    let source = Identity(privateKey: Data(hexString: f.sourcePrivateKey)!)!
    let unpacked = LXMessage.unpack(Data(hexString: f.packed)!)
    #expect(unpacked != nil)
    #expect(unpacked?.stamp == Data(hexString: f.stamp)!)
    #expect(unpacked?.hash == Data(hexString: f.hash)!)                    // hash over payload[:4]
    #expect(unpacked?.content == Data(hexString: f.content)!)
    #expect(unpacked?.validateSignature(source: source) == true)
    #expect(unpacked?.validateStamp(targetCost: f.stampCost) == true)
}

@Test func stampAttachmentMatchesReferenceBytes() throws {
    let f = try LXMFStampFixtures.load()
    let source = Identity(privateKey: Data(hexString: f.sourcePrivateKey)!)!
    let refPacked = Data(hexString: f.packed)!
    // Build the unstamped message, then attach the reference stamp → 5-element payload must byte-match.
    let msg = LXMessage.create(source: source, destinationHash: Data(hexString: f.destinationHash)!,
                               timestamp: f.timestamp, title: Data(hexString: f.title)!,
                               content: Data(hexString: f.content)!)
        .withStamp(Data(hexString: f.stamp)!)
    #expect(msg.hash == Data(hexString: f.hash)!)                          // stamp doesn't change the hash
    #expect(Data(msg.packed.dropFirst(96)) == Data(refPacked.dropFirst(96)))   // 5-element payload byte-parity
}

@Test func generatedStampRoundTrips() throws {
    let source = Identity()
    let cost = 4
    let base = LXMessage.create(source: source,
                                destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                                timestamp: 1700000000.5, title: Data("t".utf8), content: Data("c".utf8))
    let stamped = base.withStamp(LXStamper.generateStamp(messageId: base.hash, targetCost: cost))
    let recovered = LXMessage.unpack(stamped.packed)
    #expect(recovered?.stamp == stamped.stamp)
    #expect(recovered?.hash == base.hash)                                  // hash unchanged by stamping
    #expect(recovered?.validateStamp(targetCost: cost) == true)
    #expect(recovered?.validateSignature(source: source) == true)
}

/// Regression (carried from 5a review): unpack rejects a 4-element payload with an unrecognized 4th
/// element (a non-empty string-keyed map is not a valid LXMF fields element).
@Test func unpackRejectsUnrecognizedFieldsElement() throws {
    let header = Data(repeating: 0, count: 2 * LXMessage.destinationLength + LXMessage.signatureLength)
    let badPayload = MsgPack.encode(.array([.double(1), .bin(Data()), .bin(Data()), .map([.init("k", .uint(1))])]))
    #expect(LXMessage.unpack(header + badPayload) == nil)
}
```

- [ ] **Step 3: Run + verify**

Run: `swift test --filter LXMFStampMessageCrossValidationTests`
Expected: PASS (4).

- [ ] **Step 4: Full test gate**

Run: `swift test`
Expected: PASS. The 5a baseline was 457 passed / 1 skip / 0 fail; this slice adds 2 (Task 1) + 4 (Task 2) → 463 passed. Existing empty-fields + rich cross-val unaffected. On a signal-11/signal-10 build flake, run `swift package clean` and re-run.

- [ ] **Step 5: Mutation verification (one at a time)**

Apply each in `Sources/ReTiCA/LXMF/LXMessage.swift`, run `swift test --filter "LXMFStampMessageCrossValidationTests"` (and the full `LXMessage` cross-val for #3), confirm the named test fails, revert, confirm pass.

1. **packed omits the stamp** — in `payloadBytes`, delete the `if let stamp { items.append(.bin(stamp)) }`.
   → `stampAttachmentMatchesReferenceBytes` FAILS (payload region ≠ reference 5-element) and `generatedStampRoundTrips` FAILS (`recovered?.stamp` becomes nil).
2. **unpack hashes the 5-element payload** — change the `hashPayload` for `items.count == 5` to `packedPayload` (don't strip the stamp).
   → `stampedMessageUnpacksAndValidates` FAILS (`unpacked?.hash` ≠ reference) and `generatedStampRoundTrips` FAILS (`recovered?.hash` ≠ base.hash).
3. **unpack drops the stamp** — change the 5-element branch to `stamp = nil`.
   → `stampedMessageUnpacksAndValidates` FAILS (`unpacked?.stamp` ≠ reference) and `generatedStampRoundTrips` FAILS.
4. **unpack accepts unrecognized fields element** — change the `default:` in the fields `switch` to `default: fields = []`.
   → `unpackRejectsUnrecognizedFieldsElement` FAILS (returns non-nil).

After each: revert, re-run, expect PASS.

- [ ] **Step 6: Commit Task 2**

Write `/tmp/ReTiCA/commit-msg-5b-t2.txt` (body below), then `git add Sources/ReTiCA/LXMF/LXMessage.swift Tests/ReTiCATests/Vectors/LXMFStampMessageCrossValidationTests.swift` then `git commit -F /tmp/ReTiCA/commit-msg-5b-t2.txt`.

```
feat: LXMF-5b task 2 — LXMessage stamp inclusion

LXMessage gains an optional stamp (payload 5th element): withStamp
attaches it, packed emits the 5-element payload, unpack strips the stamp
before rehashing (hash stays over payload[:4]), and validateStamp checks
it against a target cost via LXStamper. Byte-cross-validated vs genuine
lxmf 1.1.0 (5-element payload parity by attaching the reference stamp;
unpack + validateStamp on a genuine stamped message). Also corrects the
now-stale unpack doc comment and adds an unrecognized-fields rejection
test (5a review follow-ups).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Self-Review

**Spec coverage:** LXStamper (workblock/valid/value/generate + constants) → Task 1 Step 4; its cross-val (workblock_hash + valid + value + generate) → Steps 1-6. LXMessage stamp (stored `stamp`, `withStamp`, 5-element `packed`, hash-over-4 `unpack` strip, `validateStamp`, signature unchanged) → Task 2 Step 1; cross-val (unpack+validate genuine, byte-parity via reference stamp, own round-trip) → Step 2. 5a follow-ups (unpack doc comment + rejection test) → Task 2 Steps 1(f), 2. ✓

**Placeholder scan:** none (the Step-8 mutation note explicitly instructs the implementer to substitute a biting mutation if a proposed one does not fail a named test — this is a real instruction, not a placeholder).

**Type consistency:** `LXStamper.stampWorkblock/stampValid/stampValue/generateStamp` signatures match Task 2's `validateStamp`/tests. `LXMessage.stamp: Data?` created (nil) in `create`, set in `withStamp`, decoded in `unpack`, packed in `payloadBytes`; the memberwise init gains a trailing `stamp:` at all three construction sites (create, withStamp, unpack). Fixture keys match the generator and `LXMFStampFixtures` `CodingKeys`.
