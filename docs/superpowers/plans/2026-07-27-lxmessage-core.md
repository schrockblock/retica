# LXMF-1: LXMessage Core — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pure, zero-dependency `LXMessage` value type with deterministic pack/unpack, Ed25519 signing, and SHA-256 message-ID hashing — byte-compatible with reference `lxmf 1.1.0`.

**Architecture:** New pure file `Sources/ReTiCA/LXMF/LXMessage.swift`, depending only on `Identity`, `Crypto`, and `MsgPack`. No TCA/Transport. Wire = `destinationHash(16) ‖ sourceHash(16) ‖ signature(64) ‖ msgpack([timestamp, title, content, {}])`; message hash = `SHA-256(destinationHash ‖ sourceHash ‖ msgpack(payload))`; signature = `source.sign(hashedPart ‖ hash)`. Empty-fields scope (plain messages).

**Tech Stack:** Swift, Swift Testing, genuine `lxmf 1.1.0` / `rns 1.4.2` (conda `rns` env) for cross-validation.

## Global Constraints

- Commit directly to `main`; no feature branch.
- No compound shell commands (no `&&`, `||`, `;`, `xargs`, inline interpreter scripts). One command per Bash call. A single `>` redirect is allowed. Never use echo/printf/heredoc to write files — use editor tools.
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test.
- Cross-val fixtures MUST derive from genuine LXMF, never hand-rolled.
- Pure core only: `Sources/ReTiCA/LXMF/LXMessage.swift`, its tests in `Tests/ReTiCATests/`, and new LXMF fixture files under `Tests/ReTiCATests/Vectors/`, plus the one-line `Package.swift` resource addition. No TCA/Transport changes.
- Wire pins (confirmed against genuine lxmf 1.1.0): DESTINATION_LENGTH=16, SIGNATURE_LENGTH=64; payload msgpack `0x94`(fixarray-4) ‖ `0xCB`(float64 timestamp) ‖ `0xC4..`(bin title) ‖ `0xC4..`(bin content) ‖ `0x80`(empty fixmap); hash = `Crypto.fullHash(destinationHash ‖ sourceHash ‖ payloadBytes)`; signature over `hashedPart ‖ hash`; Identity private key = 64 bytes.
- Build gotcha: signal-11/SIGILL (or signal-10) → `swift package clean` then retry.
- Commit trailers, exactly:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```

**Spec:** `docs/superpowers/specs/2026-07-26-lxmessage-core-design.md`
**Base:** this plan's own commit (verify with `git log --oneline <planCommit>..HEAD`, never `HEAD~1`).

---

## File Structure

- **Create** `Sources/ReTiCA/LXMF/LXMessage.swift` — the pure value type + pack/unpack/validate.
- **Create** `Tests/ReTiCATests/LXMessageTests.swift` — behavioral tests.
- **Create** `Tests/ReTiCATests/Vectors/generate_lxmf_fixtures.py` — genuine-LXMF fixture generator.
- **Create** `Tests/ReTiCATests/Vectors/lxmf_fixtures.json` — generated vectors.
- **Create** `Tests/ReTiCATests/Vectors/LXMFVectorFixtures.swift` — Decodable + loader.
- **Create** `Tests/ReTiCATests/Vectors/LXMessageCrossValidationTests.swift` — byte-parity test.
- **Modify** `Package.swift` — add `lxmf_fixtures.json` to the `ReTiCATests` resources.

---

## Task 1: LXMessage core + behavioral tests

**Files:**
- Create: `Sources/ReTiCA/LXMF/LXMessage.swift`
- Test: `Tests/ReTiCATests/LXMessageTests.swift`

**Interfaces:**
- Produces: `LXMessage` with `static func create(source:destinationHash:timestamp:title:content:) -> LXMessage`, `var packed: Data`, `static func unpack(_:) -> LXMessage?`, `func validateSignature(source:) -> Bool`. Task 2 cross-validates these.
- Consumes: `Identity.sign/validate/hash`, `Crypto.fullHash`, `MsgPack.encode/decodeValue` + `MsgPackValue`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCATests/LXMessageTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func lxMessageRoundTripsAndValidates() {
    let source = Identity()
    let destHash = Identity().hash
    let msg = LXMessage.create(source: source, destinationHash: destHash,
                               timestamp: 1700000000.5, title: Data("greeting".utf8),
                               content: Data("hello world".utf8))
    let unpacked = LXMessage.unpack(msg.packed)
    #expect(unpacked != nil)
    #expect(unpacked?.destinationHash == destHash)
    #expect(unpacked?.sourceHash == source.hash)
    #expect(unpacked?.timestamp == 1700000000.5)
    #expect(unpacked?.title == Data("greeting".utf8))
    #expect(unpacked?.content == Data("hello world".utf8))
    #expect(unpacked?.hash == msg.hash)
    #expect(unpacked?.validateSignature(source: source) == true)
}

@Test func lxMessageTamperFailsValidation() {
    let source = Identity()
    let msg = LXMessage.create(source: source, destinationHash: Identity().hash,
                               timestamp: 1700000000.5, title: Data("t".utf8),
                               content: Data("hello world".utf8))
    // Flip the last byte of content (packed ends with ...content‖0x80; index count-2 is the last
    // content byte). Structure stays valid → unpack succeeds, but the signature must not validate.
    var bytes = Array(msg.packed)
    bytes[bytes.count - 2] ^= 0x01
    let tampered = LXMessage.unpack(Data(bytes))
    #expect(tampered != nil)
    #expect(tampered?.validateSignature(source: source) == false)
}

@Test func lxMessageIDIsDeterministicAndContentSensitive() {
    let source = Identity()
    let destHash = Identity().hash
    let a = LXMessage.create(source: source, destinationHash: destHash,
                             timestamp: 1700000000.5, title: Data(), content: Data("x".utf8))
    let b = LXMessage.create(source: source, destinationHash: destHash,
                             timestamp: 1700000000.5, title: Data(), content: Data("x".utf8))
    let c = LXMessage.create(source: source, destinationHash: destHash,
                             timestamp: 1700000000.5, title: Data(), content: Data("y".utf8))
    #expect(a.hash == b.hash)              // deterministic
    #expect(a.signature == b.signature)    // Ed25519 deterministic
    #expect(a.hash != c.hash)              // content-sensitive message ID
}

@Test func lxMessageUnpackRejectsMalformedAndRichFields() {
    // Too short (< 16+16+64).
    #expect(LXMessage.unpack(Data(count: 50)) == nil)
    // 4th payload element is a non-empty (integer-keyed) map → not LXMF-1 → rejected.
    // payload = fixarray4 [ float64(0), bin(0), bin(0), fixmap1{ uint(1): uint(1) } ]
    let payload = Data([0x94, 0xCB]) + Data(count: 8) + Data([0xC4, 0x00, 0xC4, 0x00, 0x81, 0x01, 0x01])
    let bogus = Data(count: 16) + Data(count: 16) + Data(count: 64) + payload
    #expect(LXMessage.unpack(bogus) == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "LXMessage" 2>&1 | tail -20`
Expected: compile failure — `LXMessage` does not exist yet.

- [ ] **Step 3: Implement `LXMessage`**

Create `Sources/ReTiCA/LXMF/LXMessage.swift`:

```swift
import Foundation

/// A Lightweight Extensible Message Format (LXMF) message — the RNS application message envelope.
/// Pure value type, byte-compatible with reference lxmf 1.1.0 (LXMessage.py). LXMF-1 scope: the
/// message core with an empty `fields` map (plain title+content messages); rich integer-keyed
/// fields and stamps are deferred to later slices.
public struct LXMessage: Equatable {
    public static let destinationLength = 16      // RNS TRUNCATED_HASHLENGTH/8
    public static let signatureLength = 64        // RNS SIGLENGTH/8

    public let destinationHash: Data              // 16
    public let sourceHash: Data                   // 16
    public let timestamp: Double
    public let title: Data                        // utf-8 bytes (may be empty)
    public let content: Data                      // utf-8 bytes (may be empty)
    public let hash: Data                         // 32 — message ID
    public let signature: Data                    // 64

    /// The msgpack of the 4-element payload [timestamp, title, content, {}] — the exact bytes the
    /// reference packs (empty fields map as the 4th element).
    private static func payloadBytes(timestamp: Double, title: Data, content: Data) -> Data {
        MsgPack.encode(.array([.double(timestamp), .bin(title), .bin(content), .map([])]))
    }

    /// Build and sign a message from the source identity (which supplies `sourceHash` and the
    /// Ed25519 signature). `title`/`content` are raw utf-8 bytes.
    public static func create(source: Identity, destinationHash: Data,
                              timestamp: Double, title: Data, content: Data) -> LXMessage {
        let payload = payloadBytes(timestamp: timestamp, title: title, content: content)
        let hashedPart = destinationHash + source.hash + payload
        let hash = Crypto.fullHash(hashedPart)
        let signature = source.sign(hashedPart + hash)
        return LXMessage(destinationHash: destinationHash, sourceHash: source.hash,
                         timestamp: timestamp, title: title, content: content,
                         hash: hash, signature: signature)
    }

    /// The on-wire bytes: destinationHash ‖ sourceHash ‖ signature ‖ msgpack(payload).
    public var packed: Data {
        destinationHash + sourceHash + signature
            + LXMessage.payloadBytes(timestamp: timestamp, title: title, content: content)
    }

    /// Parse wire bytes back into a message (structure + recomputed hash). Returns nil for malformed
    /// input or a payload that is not exactly [float64, bin, bin, empty-map] (this rejects rich
    /// integer-keyed `fields`, which LXMF-1 does not yet support). Signature validation is separate.
    public static func unpack(_ data: Data) -> LXMessage? {
        let headerLen = 2 * destinationLength + signatureLength
        guard data.count >= headerLen else { return nil }
        let destinationHash = Data(data.prefix(destinationLength))
        let sourceHash = Data(data.dropFirst(destinationLength).prefix(destinationLength))
        let signature = Data(data.dropFirst(2 * destinationLength).prefix(signatureLength))
        let packedPayload = Data(data.dropFirst(headerLen))
        guard let value = MsgPack.decodeValue(packedPayload),
              case let .array(items) = value, items.count == 4,
              case let .double(timestamp) = items[0],
              case let .bin(title) = items[1],
              case let .bin(content) = items[2],
              case let .map(pairs) = items[3], pairs.isEmpty
        else { return nil }
        // Hash is recomputed from the received payload bytes (== msgpack(payload) for LXMF-1).
        let hash = Crypto.fullHash(destinationHash + sourceHash + packedPayload)
        return LXMessage(destinationHash: destinationHash, sourceHash: sourceHash,
                         timestamp: timestamp, title: title, content: content,
                         hash: hash, signature: signature)
    }

    /// Recompute the hashed/signed parts from this message's fields and validate the signature
    /// against the resolved source identity (the caller resolves it by `sourceHash`).
    public func validateSignature(source: Identity) -> Bool {
        let payload = LXMessage.payloadBytes(timestamp: timestamp, title: title, content: content)
        let hashedPart = destinationHash + sourceHash + payload
        let hash = Crypto.fullHash(hashedPart)
        return source.validate(signature: signature, message: hashedPart + hash)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "LXMessage" 2>&1 | tail -20`
Expected: all four tests PASS.

- [ ] **Step 5: Mutation-verify (three-step)**

Batch-mutate: (1) in `create`, sign `hashedPart` alone instead of `hashedPart + hash` — `lxMessageRoundTripsAndValidates` fails (`validateSignature` recomputes with the hash, so the signature no longer matches). (2) in `unpack`, drop the `pairs.isEmpty` requirement — `lxMessageUnpackRejectsMalformedAndRichFields` still passes (the int-keyed map fails to parse earlier), so instead mutate the malformed guard `data.count >= headerLen` to `>= 0` — `lxMessageUnpackRejectsMalformedAndRichFields` fails (the 50-byte input no longer returns nil / crashes on slicing). Run `swift test --filter "LXMessage"`. Confirm each named test fails. Revert both; run again; all PASS.

(Run mutations one at a time if batching masks either.)

- [ ] **Step 6: Commit**

```bash
git add Sources/ReTiCA/LXMF/LXMessage.swift Tests/ReTiCATests/LXMessageTests.swift
git commit -F /tmp/ReTiCA/commit-lxmf1-t1.txt
```

(Message e.g. `feat: LXMF-1 task 1 — LXMessage core (pack/unpack/sign/hash)` plus trailers.)

---

## Task 2: Cross-validate against genuine lxmf 1.1.0

**Files:**
- Create: `Tests/ReTiCATests/Vectors/generate_lxmf_fixtures.py`
- Create: `Tests/ReTiCATests/Vectors/lxmf_fixtures.json`
- Create: `Tests/ReTiCATests/Vectors/LXMFVectorFixtures.swift`
- Create: `Tests/ReTiCATests/Vectors/LXMessageCrossValidationTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: `LXMessage.create/packed/unpack/validateSignature` (Task 1), `Identity(privateKey:)`.

**Context — IMPORTANT (revised after Task 1):** ReTiCA's CryptoKit Ed25519 is **hedged (randomized)** on this platform — signing the same message twice yields different signature bytes. So our signature can NEVER byte-match RNS's deterministic signature, and `msg.packed` (which contains the signature) can't be byte-compared wholesale. Cross-validate by (a) byte-comparing the **deterministic** wire regions — `destinationHash ‖ sourceHash` and the `msgpack(payload)` — plus the message `hash` (SHA-256, excludes the signature), and (b) **validating** our produced signature and the reference's signature via `validateSignature`. This still fully proves wire-compat: every deterministic byte matches, both signatures verify, and we accept genuine LXMF messages. `Identity(privateKey:)` round-trips RNS private keys (exercised by the existing `swiftDecryptsReferenceIdentityToken` cross-val), so the loaded identity is correct.

- [ ] **Step 1: Write the fixture generator**

Create `Tests/ReTiCATests/Vectors/generate_lxmf_fixtures.py`:

```python
#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_lxmf_fixtures.py > lxmf_fixtures.json
#
# Emits a genuine lxmf 1.1.0 LXMessage (fixed timestamp) so the Swift LXMessage can be cross-validated:
# our create() must reproduce .packed/.hash/.signature byte-for-byte, and our unpack() must recover
# the fields and validate the signature.
import json
import RNS
import LXMF

# Destination construction registers with Transport, which needs a running instance; no-op it.
RNS.Transport.register_destination = staticmethod(lambda *a, **k: None)

src_id = RNS.Identity()
dst_id = RNS.Identity()
src = RNS.Destination(src_id, RNS.Destination.IN, RNS.Destination.SINGLE, "lxmf", "delivery")
dst = RNS.Destination(dst_id, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")

title = b"greeting"
content = b"hello world"
msg = LXMF.LXMessage(dst, src, content=content, title=title)
msg.timestamp = 1700000000.5      # fixed, deterministic
msg.pack()

print(json.dumps({
    "source_private_key": src_id.get_private_key().hex(),
    "destination_hash": dst.hash.hex(),
    "source_hash": src.hash.hex(),
    "timestamp": msg.timestamp,
    "title": title.hex(),
    "content": content.hex(),
    "hash": msg.hash.hex(),
    "signature": msg.signature.hex(),
    "packed": msg.packed.hex(),
}, indent=2))
```

- [ ] **Step 2: Generate the fixture JSON**

Run: `/Users/ell/opt/anaconda3/envs/rns/bin/python Tests/ReTiCATests/Vectors/generate_lxmf_fixtures.py > Tests/ReTiCATests/Vectors/lxmf_fixtures.json`
Expected: exit 0; the JSON has all nine fields; `packed` is 130 hex-bytes (260 chars), `source_private_key` is 64 bytes (128 chars).

- [ ] **Step 3: Register the resource in Package.swift**

In `Package.swift`, the `ReTiCATests` target, change:

```swift
            resources: [.process("Vectors/fixtures.json")]
```
to:
```swift
            resources: [.process("Vectors/fixtures.json"), .process("Vectors/lxmf_fixtures.json")]
```

- [ ] **Step 4: Write the fixture loader**

Create `Tests/ReTiCATests/Vectors/LXMFVectorFixtures.swift`:

```swift
import Foundation

struct LXMFVectorFixtures: Decodable {
    let sourcePrivateKey: String
    let destinationHash: String
    let sourceHash: String
    let timestamp: Double
    let title: String
    let content: String
    let hash: String
    let signature: String
    let packed: String

    enum CodingKeys: String, CodingKey {
        case sourcePrivateKey = "source_private_key"
        case destinationHash = "destination_hash"
        case sourceHash = "source_hash"
        case timestamp
        case title, content, hash, signature, packed
    }

    static func load() throws -> LXMFVectorFixtures {
        let url = Bundle.module.url(forResource: "lxmf_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(LXMFVectorFixtures.self, from: Data(contentsOf: url))
    }
}
```

- [ ] **Step 5: Write the cross-val test**

Create `Tests/ReTiCATests/Vectors/LXMessageCrossValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

/// Our LXMessage reproduces genuine lxmf 1.1.0's DETERMINISTIC wire bytes (destination/source hashes,
/// payload) and message-ID, produces a valid signature, and unpacks + validates a genuine reference
/// message. The signature bytes are NOT compared (ReTiCA's Ed25519 is hedged/randomized) — they are
/// validated instead.
@Test func lxMessageMatchesReferenceLXMF() throws {
    let f = try LXMFVectorFixtures.load()
    let source = Identity(privateKey: Data(hexString: f.sourcePrivateKey)!)!
    let destHash = Data(hexString: f.destinationHash)!
    let refPacked = Data(hexString: f.packed)!
    #expect(source.hash == Data(hexString: f.sourceHash)!)     // private-key round-trip → same identity

    let msg = LXMessage.create(source: source, destinationHash: destHash,
                               timestamp: f.timestamp, title: Data(hexString: f.title)!,
                               content: Data(hexString: f.content)!)
    #expect(msg.hash == Data(hexString: f.hash)!)              // SHA-256 message-ID byte-parity
    // Deterministic wire regions match byte-for-byte: destHash‖sourceHash (bytes 0..<32) and the
    // msgpack payload (bytes 96..). The 64-byte signature region (32..<96) is randomized → validated,
    // not compared.
    let ourPacked = msg.packed
    #expect(ourPacked.prefix(32) == refPacked.prefix(32))
    #expect(Data(ourPacked.dropFirst(96)) == Data(refPacked.dropFirst(96)))
    #expect(msg.validateSignature(source: source) == true)     // our signature is valid

    // Our unpack recovers a genuine reference message and validates its (deterministic) signature.
    let unpacked = LXMessage.unpack(refPacked)
    #expect(unpacked != nil)
    #expect(unpacked?.content == Data(hexString: f.content)!)
    #expect(unpacked?.hash == Data(hexString: f.hash)!)
    #expect(unpacked?.validateSignature(source: source) == true)
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `swift test --filter "lxMessageMatchesReference" 2>&1 | tail -20`
Expected: PASS. The deterministic-region byte-compares (hashes + payload) and both `validateSignature` checks hold; the signature is intentionally not byte-compared (hedged Ed25519). If a deterministic-region compare fails, our encoding diverges from genuine LXMF — investigate/escalate, do not weaken. If `validateSignature` on the reference message fails, our validation or the loaded identity is wrong — escalate. Also run `swift test --filter "CrossValidation"` to confirm the sibling pure-core cross-val tests still pass after the Package.swift resource change.

- [ ] **Step 7: Mutation-verify**

Mutate the test: change `timestamp: f.timestamp` to `timestamp: f.timestamp + 1` and confirm the deterministic-region assertions fail (different timestamp → different payload → `msg.hash != f.hash` and the payload-region byte-compare `ourPacked.dropFirst(96) != refPacked.dropFirst(96)` differ); revert and confirm pass. (Confirms the parity assertions are load-bearing on the exact inputs.)

- [ ] **Step 8: Commit**

```bash
git add Tests/ReTiCATests/Vectors/ Package.swift
git commit -F /tmp/ReTiCA/commit-lxmf1-t2.txt
```

(Message e.g. `test: LXMF-1 task 2 — cross-validate LXMessage vs genuine lxmf 1.1.0` plus trailers.)

---

## Self-Review

- **Spec coverage:** LXMessage type + create/packed/unpack/validateSignature (Task 1); empty-fields scope + rich-fields rejection (Task 1 unpack + test 4); byte cross-val incl. private-key round-trip (Task 2). Stamps, rich fields, delivery deferred (spec §Scope) — no task, by design.
- **Placeholder scan:** none — every step has concrete code/commands.
- **Type consistency:** `LXMessage.create/packed/unpack/validateSignature` signatures used identically in Task 1 impl, Task 1 tests, and Task 2 cross-val; `MsgPack.encode(.array/.double/.bin/.map)`, `MsgPack.decodeValue`, `MsgPackValue` cases match `MsgPack.swift`; `Identity.sign/validate/hash`, `Identity(privateKey:)`, `Crypto.fullHash` match their definitions; fixture field names consistent across generator keys, struct, CodingKeys, test.
- **Wire correctness:** payload `MsgPack.encode(.array([.double(ts), .bin(title), .bin(content), .map([])]))` == the probed reference `94 cb.. c4.. c4.. 80`; hash over `dh ‖ sh ‖ payloadBytes`; signature over `hashedPart ‖ hash`; 130-byte packed for the sample. All confirmed against genuine lxmf 1.1.0.
