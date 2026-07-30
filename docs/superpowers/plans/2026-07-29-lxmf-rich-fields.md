# LXMF-5a: Rich Fields (int-keyed MsgPack maps) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Carry rich integer-keyed `fields` in an `LXMessage`, byte-compatible with genuine LXMF — via int-keyed msgpack map support.

**Architecture:** Add `MsgPackValue.intMap([IntPair])` (encode + key-type-aware parse) to the pure `MsgPack` codec, and thread an ordered `fields: [MsgPackValue.IntPair]` through `LXMessage` (create/packed/unpack/validate; empty default stays byte-identical to LXMF-1). Byte-cross-validated via a new isolated rich-fields fixture.

**Tech Stack:** Swift, SwiftPM, swift-testing (`@Test`). Cross-validation from genuine LXMF in the conda `rns` env.

## Global Constraints

- Commit directly to `main`; no feature branch, no finishing-a-development-branch merge dance.
- No compound shell commands: no `|` chains, `&&`, `||`, `;`, `$(...)`-feeding, `xargs`, or inlining scripts into interpreters. One command per Bash call. A single `>` redirect is allowed (fixture generation). Never use echo/printf/heredoc to WRITE source files (use Write/Edit).
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new test.
- Cross-val must drive genuine LXMF (new isolated fixture; do NOT touch `lxmf_fixtures.json`). Reference env: `/Users/ell/opt/anaconda3/envs/rns/bin/python` (rns 1.4.2 / lxmf 1.1.0).
- Ed25519 hedged → signatures validated, never byte-compared; payload region + hash are deterministic and pinned.
- Commit trailers (exact); the `;` means author the message with the Write tool to `/tmp/ReTiCA/` and `git commit -F`, never `-m`:
  - `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`

---

### Task 1: `MsgPack.intMap` + `LXMessage` rich fields + cross-val

**Files:**
- Modify: `Sources/ReTiCA/Support/MsgPack.swift` (encode switch; add `encodeIntMap`; rewrite `parseMap`; add `MsgPackValue.intMap` case + `IntPair`)
- Modify: `Sources/ReTiCA/LXMF/LXMessage.swift` (stored `fields`; `payloadBytes`; `create`; `packed`; `unpack`; `validateSignature`)
- Create: `Tests/ReTiCATests/MsgPackIntMapTests.swift`
- Create: `Tests/ReTiCATests/Vectors/generate_lxmf_rich_fixtures.py`
- Create (generated): `Tests/ReTiCATests/Vectors/lxmf_rich_fixtures.json`
- Create: `Tests/ReTiCATests/Vectors/LXMFRichFixtures.swift`
- Create: `Tests/ReTiCATests/Vectors/LXMFRichCrossValidationTests.swift`
- Modify: `Package.swift` (add the new fixture to the `ReTiCATests` resources list)

**Interfaces:**
- Consumes: existing `MsgPack.encode`/`decodeValue`/`encodeUInt`/`beBytes`; `Crypto.fullHash`; `Identity(privateKey:)`; `Data(hexString:)`; `LXMessage.deliveryHash`.
- Produces: `MsgPackValue.intMap([MsgPackValue.IntPair])`, `MsgPackValue.IntPair`; `LXMessage.fields: [MsgPackValue.IntPair]`, `LXMessage.create(…, fields:)`.

- [ ] **Step 1: Add int-keyed map support to `MsgPack`**

In `Sources/ReTiCA/Support/MsgPack.swift`:

(a) Extend `MsgPackValue` (after `case array([MsgPackValue])`, line 149) and add the `IntPair` struct (after the `Pair` struct, ~line 155):

```swift
    case intMap([IntPair])
```
```swift
    public struct IntPair: Equatable {
        public let key: Int
        public let value: MsgPackValue
        public init(_ key: Int, _ value: MsgPackValue) { self.key = key; self.value = value }
    }
```

(b) Add the `.intMap` case to the `encode` switch (line 31-32 area):

```swift
        case let .intMap(pairs): return encodeIntMap(pairs)
```

(c) Add `encodeIntMap` after `encodeMap` (line 65):

```swift
    private static func encodeIntMap(_ pairs: [MsgPackValue.IntPair]) -> Data {
        let n = pairs.count
        var d = n <= 15 ? Data([0x80 | UInt8(n)]) : Data([0xDE]) + beBytes(UInt16(n))
        for p in pairs { d.append(encodeUInt(UInt64(p.key))); d.append(encode(p.value)) }
        return d
    }
```

(d) Replace `parseMap` (lines 118-126) with a key-type-aware version:

```swift
    private static func parseMap(_ b: [UInt8], _ start: Int, _ count: Int) -> (MsgPackValue, Int)? {
        if count == 0 { return (.map([]), start) }
        guard let (firstKey, _) = parse(b, start) else { return nil }   // peek to pick key type
        var i = start
        switch firstKey {
        case .string:
            var pairs: [MsgPackValue.Pair] = []
            for _ in 0..<count {
                guard let (kv, ni) = parse(b, i), case let .string(key) = kv,
                      let (vv, ni2) = parse(b, ni) else { return nil }
                pairs.append(.init(key, vv)); i = ni2
            }
            return (.map(pairs), i)
        case .uint:
            var pairs: [MsgPackValue.IntPair] = []
            for _ in 0..<count {
                guard let (kv, ni) = parse(b, i), case let .uint(key) = kv,
                      let (vv, ni2) = parse(b, ni) else { return nil }
                pairs.append(.init(Int(key), vv)); i = ni2
            }
            return (.intMap(pairs), i)
        default:
            return nil
        }
    }
```

- [ ] **Step 2: Write MsgPack int-map unit tests**

Create `Tests/ReTiCATests/MsgPackIntMapTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func msgPackIntMapRoundTrips() throws {
    let v = MsgPackValue.intMap([.init(0x0C, .bin(Data([0xAA, 0xBB]))), .init(0x0F, .uint(2))])
    let encoded = MsgPack.encode(v)
    // 0x82 (map2) ‖ 0x0C ‖ 0xC4 0x02 AA BB ‖ 0x0F ‖ 0x02
    #expect(Array(encoded) == [0x82, 0x0C, 0xC4, 0x02, 0xAA, 0xBB, 0x0F, 0x02])
    #expect(MsgPack.decodeValue(encoded) == v)
}

@Test func msgPackNestedIntMapRoundTrips() throws {
    let inner = MsgPackValue.intMap([.init(0x01, .uint(7))])
    let v = MsgPackValue.intMap([.init(0x40, inner)])
    #expect(MsgPack.decodeValue(MsgPack.encode(v)) == v)
}

@Test func msgPackEmptyMapStaysStringKeyed() throws {
    // An empty map (0x80) decodes to .map([]) — preserves LXMF-1's empty-fields shape.
    #expect(MsgPack.decodeValue(Data([0x80])) == .map([]))
}

@Test func msgPackStringMapStillParses() throws {
    let v = MsgPackValue.map([.init("k", .uint(1))])
    #expect(MsgPack.decodeValue(MsgPack.encode(v)) == v)
}
```

- [ ] **Step 3: Run MsgPack tests — verify they pass**

Run: `swift test --filter MsgPackIntMapTests`
Expected: PASS (4).

- [ ] **Step 4: Thread `fields` through `LXMessage`**

In `Sources/ReTiCA/LXMF/LXMessage.swift`:

(a) Add the stored property after `signature` (line 17):

```swift
    public let fields: [MsgPackValue.IntPair]     // ordered integer-keyed fields (empty = none)
```

(b) Replace `payloadBytes` (lines 33-35) with a fields-aware version:

```swift
    private static func payloadBytes(timestamp: Double, title: Data, content: Data,
                                     fields: [MsgPackValue.IntPair]) -> Data {
        let fieldsValue: MsgPackValue = fields.isEmpty ? .map([]) : .intMap(fields)
        return MsgPack.encode(.array([.double(timestamp), .bin(title), .bin(content), fieldsValue]))
    }
```

(c) Replace `create` (lines 40-50) to accept and store `fields`:

```swift
    public static func create(source: Identity, destinationHash: Data,
                              timestamp: Double, title: Data, content: Data,
                              fields: [MsgPackValue.IntPair] = []) -> LXMessage {
        let sourceHash = deliveryHash(identityHash: source.hash)
        let payload = payloadBytes(timestamp: timestamp, title: title, content: content, fields: fields)
        let hashedPart = destinationHash + sourceHash + payload
        let hash = Crypto.fullHash(hashedPart)
        let signature = source.sign(hashedPart + hash)
        return LXMessage(destinationHash: destinationHash, sourceHash: sourceHash,
                         timestamp: timestamp, title: title, content: content,
                         hash: hash, signature: signature, fields: fields)
    }
```

(d) Replace `packed` (lines 53-56):

```swift
    public var packed: Data {
        destinationHash + sourceHash + signature
            + LXMessage.payloadBytes(timestamp: timestamp, title: title, content: content, fields: fields)
    }
```

(e) Replace the payload decode in `unpack` (the `guard` at lines 68-74 and the `LXMessage(...)` return at lines 79-81) with:

```swift
        guard let value = MsgPack.decodeValue(packedPayload),
              case let .array(items) = value, items.count == 4,
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
        let hash = Crypto.fullHash(destinationHash + sourceHash + packedPayload)
        return LXMessage(destinationHash: destinationHash, sourceHash: sourceHash,
                         timestamp: timestamp, title: title, content: content,
                         hash: hash, signature: signature, fields: fields)
```

(f) Replace `validateSignature`'s payload line (line 87):

```swift
        let payload = LXMessage.payloadBytes(timestamp: timestamp, title: title, content: content, fields: fields)
```

- [ ] **Step 5: Write the fixture generator**

Create `Tests/ReTiCATests/Vectors/generate_lxmf_rich_fixtures.py`:

```python
#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_lxmf_rich_fixtures.py > lxmf_rich_fixtures.json
#
# Emits a genuine lxmf 1.1.0 LXMessage WITH integer-keyed fields (FIELD_TICKET=0x0C bytes,
# FIELD_RENDERER=0x0F uint) so the Swift LXMessage rich-fields packing can be byte-cross-validated.
# Fields are inserted in ascending-key order so the msgpack map order is deterministic and matches the
# Swift ordered [IntPair]. The signature is hedged/randomized (validated, not byte-compared).
import json
import RNS
import LXMF

RNS.Transport.register_destination = staticmethod(lambda *a, **k: None)

src_id = RNS.Identity()
dst_id = RNS.Identity()
src = RNS.Destination(src_id, RNS.Destination.IN, RNS.Destination.SINGLE, "lxmf", "delivery")
dst = RNS.Destination(dst_id, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")

title = b"greeting"
content = b"hello fields"
field_ticket = bytes.fromhex("0011223344556677")
field_renderer = LXMF.RENDERER_MARKDOWN   # 0x02
fields = {LXMF.FIELD_TICKET: field_ticket, LXMF.FIELD_RENDERER: field_renderer}   # keys 0x0C, 0x0F

msg = LXMF.LXMessage(dst, src, content=content, title=title, fields=fields)
msg.timestamp = 1700000000.5
msg.pack()

print(json.dumps({
    "source_private_key": src_id.get_private_key().hex(),
    "destination_hash": dst.hash.hex(),
    "timestamp": msg.timestamp,
    "title": title.hex(),
    "content": content.hex(),
    "field_ticket": field_ticket.hex(),
    "field_renderer": field_renderer,
    "hash": msg.hash.hex(),
    "signature": msg.signature.hex(),
    "packed": msg.packed.hex(),
}, indent=2))
```

- [ ] **Step 6: Generate the fixture**

Run (single command, one redirect):

```bash
/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/generate_lxmf_rich_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/lxmf_rich_fixtures.json
```

Expected: a JSON with `field_ticket: "0011223344556677"`, `field_renderer: 2`, `packed`, `hash`. (If the generator errors, fix the generator — never hand-write the JSON.)

- [ ] **Step 7: Register the fixture resource**

In `Package.swift`, append `.process("Vectors/lxmf_rich_fixtures.json")` to the `ReTiCATests` target's `resources:` array (the one that already lists `lxmf_fixtures.json` / `lxmf_propagation_fixtures.json`).

- [ ] **Step 8: Write the fixtures decoder**

Create `Tests/ReTiCATests/Vectors/LXMFRichFixtures.swift`:

```swift
import Foundation

struct LXMFRichFixtures: Decodable {
    let sourcePrivateKey: String
    let destinationHash: String
    let timestamp: Double
    let title: String
    let content: String
    let fieldTicket: String
    let fieldRenderer: Int
    let hash: String
    let signature: String
    let packed: String

    enum CodingKeys: String, CodingKey {
        case sourcePrivateKey = "source_private_key"
        case destinationHash = "destination_hash"
        case timestamp, title, content
        case fieldTicket = "field_ticket"
        case fieldRenderer = "field_renderer"
        case hash, signature, packed
    }

    static func load() throws -> LXMFRichFixtures {
        let url = Bundle.module.url(forResource: "lxmf_rich_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(LXMFRichFixtures.self, from: Data(contentsOf: url))
    }
}
```

- [ ] **Step 9: Write the cross-val tests**

Create `Tests/ReTiCATests/Vectors/LXMFRichCrossValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

/// Our LXMessage reproduces genuine lxmf 1.1.0's DETERMINISTIC wire bytes for a message WITH integer-
/// keyed fields (payload region + message hash), and unpacks a genuine rich message back to its fields.
/// The signature is hedged/randomized → validated, not byte-compared.
private func referenceFields(_ f: LXMFRichFixtures) -> [MsgPackValue.IntPair] {
    [.init(0x0C, .bin(Data(hexString: f.fieldTicket)!)), .init(0x0F, .uint(UInt64(f.fieldRenderer)))]
}

@Test func richMessageMatchesReferenceLXMF() throws {
    let f = try LXMFRichFixtures.load()
    let source = Identity(privateKey: Data(hexString: f.sourcePrivateKey)!)!
    let refPacked = Data(hexString: f.packed)!
    let msg = LXMessage.create(source: source, destinationHash: Data(hexString: f.destinationHash)!,
                               timestamp: f.timestamp, title: Data(hexString: f.title)!,
                               content: Data(hexString: f.content)!, fields: referenceFields(f))
    #expect(msg.hash == Data(hexString: f.hash)!)                                   // hash byte-parity
    #expect(Data(msg.packed.dropFirst(96)) == Data(refPacked.dropFirst(96)))        // payload byte-parity
    #expect(msg.validateSignature(source: source) == true)
}

@Test func richMessageUnpackRecoversFields() throws {
    let f = try LXMFRichFixtures.load()
    let source = Identity(privateKey: Data(hexString: f.sourcePrivateKey)!)!
    let unpacked = LXMessage.unpack(Data(hexString: f.packed)!)
    #expect(unpacked != nil)
    #expect(unpacked?.fields == referenceFields(f))
    #expect(unpacked?.content == Data(hexString: f.content)!)
    #expect(unpacked?.hash == Data(hexString: f.hash)!)
    #expect(unpacked?.validateSignature(source: source) == true)
}

@Test func emptyFieldsMessageUnchanged() throws {
    // Regression: a message created with no fields still packs the empty-map payload and round-trips to [].
    let source = Identity()
    let msg = LXMessage.create(source: source, destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("c".utf8))
    #expect(msg.fields.isEmpty)
    #expect(LXMessage.unpack(msg.packed)?.fields == [])
}
```

- [ ] **Step 10: Run the rich cross-val — verify it passes**

Run: `swift test --filter LXMFRichCrossValidationTests`
Expected: PASS (3).

- [ ] **Step 11: Full test gate**

Run: `swift test`
Expected: PASS. The 4d-5 baseline was 450 passed / 1 pre-existing live-node skip / 0 fail; this slice adds 4 MsgPack + 3 rich cross-val tests → 457 passed. Existing LXMF cross-val (empty-fields) unaffected (the shared `payloadBytes` default is byte-identical). On a signal-11/signal-10 build flake, run `swift package clean` (single command) and re-run.

- [ ] **Step 12: Mutation verification (one mutation at a time)**

Apply each individually, run the relevant `--filter`, confirm the named test fails, revert, confirm pass, then the next.

1. **encodeIntMap writes wrong key** — in `encodeIntMap`, change `encodeUInt(UInt64(p.key))` to `encodeUInt(UInt64(p.key + 1))`.
   → `msgPackIntMapRoundTrips` FAILS (encoded bytes differ) and `richMessageMatchesReferenceLXMF` FAILS (payload ≠ reference).
2. **parseMap int branch mis-keys** — in the `.uint` branch, change `pairs.append(.init(Int(key), vv))` to `pairs.append(.init(Int(key) + 1, vv))`.
   → `msgPackIntMapRoundTrips` FAILS (decode ≠ original) and `richMessageUnpackRecoversFields` FAILS (fields keys wrong).
3. **LXMessage ignores fields in the payload** — in `payloadBytes`, force `let fieldsValue: MsgPackValue = .map([])` (ignore `fields`).
   → `richMessageMatchesReferenceLXMF` FAILS (payload ≠ reference; hash differs) while `emptyFieldsMessageUnchanged` still passes.
4. **unpack drops fields** — in `unpack`, replace the `.intMap` case with `case .intMap: fields = []`.
   → `richMessageUnpackRecoversFields` FAILS (`fields` is `[]`, not the reference fields).

After each: revert, re-run `swift test`, expect PASS before the next.

- [ ] **Step 13: Commit**

Write the message to `/tmp/ReTiCA/commit-msg-5a.txt` with the Write tool (body below), then:

```bash
git add Sources/ReTiCA/Support/MsgPack.swift Sources/ReTiCA/LXMF/LXMessage.swift Tests/ReTiCATests/MsgPackIntMapTests.swift Tests/ReTiCATests/Vectors/generate_lxmf_rich_fixtures.py Tests/ReTiCATests/Vectors/lxmf_rich_fixtures.json Tests/ReTiCATests/Vectors/LXMFRichFixtures.swift Tests/ReTiCATests/Vectors/LXMFRichCrossValidationTests.swift Package.swift
```

```bash
git commit -F /tmp/ReTiCA/commit-msg-5a.txt
```

Commit message body:

```
feat: LXMF-5a — rich fields (int-keyed MsgPack maps)

MsgPackValue gains .intMap([IntPair]) with encode + key-type-aware parse
(empty map stays .map([]); string maps unchanged; nested int-maps via
recursion). LXMessage carries an ordered fields: [IntPair] threaded
through create/packed/unpack/validate (empty default byte-identical to
LXMF-1). Byte-cross-validated vs genuine lxmf 1.1.0 with a new isolated
rich-fields fixture (FIELD_TICKET bytes + FIELD_RENDERER uint): payload
region + hash pinned, signature validated. 4 MsgPack + 3 cross-val tests.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Self-Review

**Spec coverage:**
- Spec MsgPack int-keyed maps (`.intMap`/`IntPair`, encode, key-type-aware parse, empty→`.map([])`, string unchanged, nested) → Step 1 + unit tests Step 2. ✓
- Spec LXMessage rich fields (stored `fields`, `payloadBytes`, `create` default, `packed`, `unpack` accept empty-map or intMap, `validateSignature`) → Step 4. ✓
- Spec cross-val (isolated generator/fixture/decoder/tests + Package.swift) → Steps 5-9. ✓
- Spec test 1 (create byte-parity payload + hash + sig) → `richMessageMatchesReferenceLXMF`. ✓
- Spec test 2 (unpack recovers fields) → `richMessageUnpackRecoversFields`. ✓
- Spec test 3 (empty-fields regression) → `emptyFieldsMessageUnchanged`. ✓

**Placeholder scan:** none.

**Type consistency:** `MsgPackValue.intMap([MsgPackValue.IntPair])` used in `MsgPack` (encode/parse) and `LXMessage` (`payloadBytes`/`unpack`) and the tests; `LXMessage.fields: [MsgPackValue.IntPair]` created in `create`, decoded in `unpack`, packed in `payloadBytes`; the memberwise `LXMessage(...)` init gains a trailing `fields:` argument at both construction sites (create, unpack). Fixture keys (`field_ticket`, `field_renderer`, `packed`, `hash`) match the generator and `LXMFRichFixtures` `CodingKeys`.
