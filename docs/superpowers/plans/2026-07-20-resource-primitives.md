# Resource Primitives Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the pure, single-segment, uncompressed Resource representation primitives in the `ReTiCA` core — a richer `MsgPack` codec, the resource content computations (hash, encrypted stream, parts, map-hashes, assembly, proof), and `ResourceAdvertisement` pack/unpack — byte-for-byte wire-compatible with reference RNS 1.3.8.

**Architecture:** All in the pure `ReTiCA` core (zero deps). `MsgPack` gains a `MsgPackValue` model (uint/bin/string/nil/ordered-map + existing double). `Resource` (pure `enum`) holds session-key-parameterized content primitives wrapping the existing `Crypto`/`Token`. `ResourceAdvertisement` packs a msgpack dict in RNS's exact key order. Cross-validated by driving genuine `umsgpack`/`full_hash`/`Token`/`ResourceAdvertisement`.

**Tech Stack:** Swift 6, Swift Testing, CryptoKit/CommonCrypto (via existing `Crypto`/`Token`). Cross-validation against Python-RNS 1.3.8.

## Global Constraints

- Full wire compatibility with reference RNS 1.3.8; cross-validation drives GENUINE reference code (never a reimplementation).
- The `ReTiCA` core stays dependency-free (stdlib + existing in-core `Crypto`/`Token` only).
- Swift 6 strict concurrency; new value types are `Equatable`.
- Platform floor iOS 16 / macOS 13 / tvOS 16 / watchOS 9 / macCatalyst 16.
- Scope: single-segment, uncompressed ONLY. NO transfer state machine, windowing, segmentation, compression, retransmission, request/response, metadata, TCA, or Link/Endpoint integration.
- Reference facts (RNS 1.3.8): resource hash `h = full_hash(data ‖ r)` over ORIGINAL data + 4-byte resource random hash `r`; map hash `full_hash(chunk ‖ r)[:4]`; stream `Token(key).encrypt(prefix(4) ‖ data)` split into `sdu`-sized ciphertext chunks; assembly `decrypt(join(chunks))` then drop the 4-byte prefix; proof `proof_data = h ‖ full_hash(data ‖ h)` (64B); advertisement `umsgpack.packb({t,d,n,h,r,o,i,l,q,f,m})` in that key order, flags `f = (hasMeta<<5)|(isResp<<4)|(isReq<<3)|(split<<2)|(compressed<<1)|encrypted` (= `0x01` here, encrypted-only).
- msgpack minimal forms (verified vs `RNS.vendor.umsgpack`): fixint `0x00–0x7F`; uint8 `0xCC`; uint16 `0xCD`; uint32 `0xCE`; uint64 `0xCF`; bin8 `0xC4`/bin16 `0xC5`/bin32 `0xC6`; fixstr `0xA0|len`/str8 `0xD9`; nil `0xC0`; fixmap `0x80|n`/map16 `0xDE`; float64 `0xCB`.
- Reference env: run the fixture generator with `/Users/ell/opt/anaconda3/envs/rns/bin/python`.
- User global rules: temp files under `/tmp/ReTiCA/`; NO compound shell commands (no `|`/`&&`/`;`/command-substitution feeding another command); one command per invocation; write scripts to a file; mutation-testing three-step verification for every new/changed test.

---

## File Structure

- `Sources/ReTiCA/Support/MsgPack.swift` (modify) — add the `MsgPackValue` model + `encode`/`decodeValue`.
- `Sources/ReTiCA/Resource/Resource.swift` (new) — pure `enum Resource` content primitives.
- `Sources/ReTiCA/Resource/ResourceAdvertisement.swift` (new) — the advertisement struct + pack/unpack.
- `Tests/ReTiCATests/Support/MsgPackTests.swift` (modify) — value-codec unit tests.
- `Tests/ReTiCATests/Resource/ResourceTests.swift` (new) — content-primitive unit tests.
- `Tests/ReTiCATests/Resource/ResourceAdvertisementTests.swift` (new) — advertisement unit tests.
- `Tests/ReTiCATests/Vectors/generate_fixtures.py` (modify) / `fixtures.json` (regenerate) / `VectorFixtures.swift` (modify) / `ResourceCrossValidationTests.swift` (new) — cross-validation + end-to-end round-trip.
- `README.md` (modify).

---

### Task 1: MsgPack value codec (uint / bin / string / nil / ordered map)

**Files:**
- Modify: `Sources/ReTiCA/Support/MsgPack.swift`
- Test: `Tests/ReTiCATests/Support/MsgPackTests.swift`

**Interfaces:**
- Consumes: the existing `MsgPack.encode(Double)`.
- Produces: `MsgPackValue` (with nested `Pair`), `MsgPack.encode(_ value: MsgPackValue) -> Data`, `MsgPack.decodeValue(_ data: Data) -> MsgPackValue?`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ReTiCATests/Support/MsgPackTests.swift`:

```swift
@Test func msgPackEncodesScalarForms() {
    #expect(MsgPack.encode(.uint(5)) == Data([0x05]))                                  // fixint
    #expect(MsgPack.encode(.uint(200)) == Data([0xCC, 0xC8]))                           // uint8
    #expect(MsgPack.encode(.uint(1000)) == Data([0xCD, 0x03, 0xE8]))                    // uint16
    #expect(MsgPack.encode(.uint(100000)) == Data([0xCE, 0x00, 0x01, 0x86, 0xA0]))      // uint32
    #expect(MsgPack.encode(.null) == Data([0xC0]))
    #expect(MsgPack.encode(.bin(Data([0x01, 0x02, 0x03]))) == Data([0xC4, 0x03, 0x01, 0x02, 0x03])) // bin8
    #expect(MsgPack.encode(.string("t")) == Data([0xA1, 0x74]))                          // fixstr
}

@Test func msgPackEncodesOrderedMap() {
    // umsgpack.packb({"t":5,"h":b"\xaa\xbb"}) == 82 a174 05 a168 c402aabb
    let v = MsgPackValue.map([.init("t", .uint(5)), .init("h", .bin(Data([0xAA, 0xBB])))])
    #expect(MsgPack.encode(v) == Data([0x82, 0xA1, 0x74, 0x05, 0xA1, 0x68, 0xC4, 0x02, 0xAA, 0xBB]))
}

@Test func msgPackValueRoundTrips() {
    let v = MsgPackValue.map([
        .init("t", .uint(40)), .init("q", .null), .init("h", .bin(Data(repeating: 0x11, count: 32))),
        .init("f", .uint(1)),
    ])
    #expect(MsgPack.decodeValue(MsgPack.encode(v)) == v)
    // Scalars round-trip too.
    for s in [MsgPackValue.uint(0), .uint(255), .uint(65535), .uint(4_000_000_000),
              .bin(Data(repeating: 0xEE, count: 300)), .string("hello"), .null] {
        #expect(MsgPack.decodeValue(MsgPack.encode(s)) == s)
    }
}

@Test func msgPackValueDecodeRejectsMalformed() {
    #expect(MsgPack.decodeValue(Data([0xCC])) == nil)              // truncated uint8
    #expect(MsgPack.decodeValue(Data([0xC4, 0x05, 0x01])) == nil)  // bin length exceeds data
    #expect(MsgPack.decodeValue(Data([0x82, 0xA1, 0x74, 0x05])) == nil) // map claims 2 entries, only 1
    #expect(MsgPack.decodeValue(Data()) == nil)
    #expect(MsgPack.decodeValue(Data([0x05, 0x05])) == nil)        // trailing bytes after a value
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter MsgPack`
Expected: FAIL — `MsgPackValue` doesn't exist.

- [ ] **Step 3: Implement the value codec**

In `Sources/ReTiCA/Support/MsgPack.swift`, add inside `enum MsgPack` (keep the existing double `encode`/`decodeDouble`). First the value model (top-level in the file, after the `enum MsgPack` closing brace, OR nested — put it top-level for clarity):

```swift
/// A MessagePack value covering the subset Reticulum resource advertisements use:
/// unsigned ints, byte strings, UTF-8 strings, nil, float64, and ordered string-keyed maps.
public indirect enum MsgPackValue: Equatable {
    case uint(UInt64)
    case bin(Data)
    case string(String)
    case double(Double)
    case null
    case map([Pair])

    public struct Pair: Equatable {
        public let key: String
        public let value: MsgPackValue
        public init(_ key: String, _ value: MsgPackValue) { self.key = key; self.value = value }
    }
}
```

Then add these methods inside `enum MsgPack`:

```swift
    public static func encode(_ value: MsgPackValue) -> Data {
        switch value {
        case let .uint(u):    return encodeUInt(u)
        case let .bin(d):     return encodeBin(d)
        case let .string(s):  return encodeStr(s)
        case let .double(x):  return encode(x)          // existing float64 encoder
        case .null:           return Data([0xC0])
        case let .map(pairs): return encodeMap(pairs)
        }
    }

    static func encodeUInt(_ u: UInt64) -> Data {
        if u <= 0x7F { return Data([UInt8(u)]) }
        if u <= 0xFF { return Data([0xCC, UInt8(u)]) }
        if u <= 0xFFFF { return Data([0xCD]) + beBytes(UInt16(u)) }
        if u <= 0xFFFF_FFFF { return Data([0xCE]) + beBytes(UInt32(u)) }
        return Data([0xCF]) + beBytes(u)
    }
    static func encodeBin(_ b: Data) -> Data {
        let n = b.count
        var d: Data
        if n <= 0xFF { d = Data([0xC4, UInt8(n)]) }
        else if n <= 0xFFFF { d = Data([0xC5]) + beBytes(UInt16(n)) }
        else { d = Data([0xC6]) + beBytes(UInt32(n)) }
        d.append(b); return d
    }
    static func encodeStr(_ s: String) -> Data {
        let u = Data(s.utf8); let n = u.count
        var d = n <= 31 ? Data([0xA0 | UInt8(n)]) : Data([0xD9, UInt8(n)])
        d.append(u); return d
    }
    static func encodeMap(_ pairs: [MsgPackValue.Pair]) -> Data {
        let n = pairs.count
        var d = n <= 15 ? Data([0x80 | UInt8(n)]) : Data([0xDE]) + beBytes(UInt16(n))
        for p in pairs { d.append(encodeStr(p.key)); d.append(encode(p.value)) }
        return d
    }
    static func beBytes<T: FixedWidthInteger>(_ v: T) -> Data {
        var be = v.bigEndian; return withUnsafeBytes(of: &be) { Data($0) }
    }

    public static func decodeValue(_ data: Data) -> MsgPackValue? {
        let b = [UInt8](data)
        guard let (v, next) = parse(b, 0), next == b.count else { return nil }
        return v
    }
    private static func parse(_ b: [UInt8], _ i: Int) -> (MsgPackValue, Int)? {
        guard i < b.count else { return nil }
        let tag = b[i]
        switch tag {
        case 0x00...0x7F: return (.uint(UInt64(tag)), i + 1)
        case 0xC0: return (.null, i + 1)
        case 0xCC: guard i + 1 < b.count else { return nil }; return (.uint(UInt64(b[i + 1])), i + 2)
        case 0xCD: guard i + 2 < b.count else { return nil }; return (.uint(UInt64(be(b, i + 1, 2))), i + 3)
        case 0xCE: guard i + 4 < b.count else { return nil }; return (.uint(be(b, i + 1, 4)), i + 5)
        case 0xCF: guard i + 8 < b.count else { return nil }; return (.uint(be(b, i + 1, 8)), i + 9)
        case 0xCB: guard i + 8 < b.count else { return nil }; return (.double(Double(bitPattern: be(b, i + 1, 8))), i + 9)
        case 0xC4: guard i + 1 < b.count else { return nil }; return bin(b, i + 2, Int(b[i + 1]))
        case 0xC5: guard i + 2 < b.count else { return nil }; return bin(b, i + 3, Int(be(b, i + 1, 2)))
        case 0xC6: guard i + 4 < b.count else { return nil }; return bin(b, i + 5, Int(be(b, i + 1, 4)))
        case 0xA0...0xBF: return str(b, i + 1, Int(tag & 0x1F))
        case 0xD9: guard i + 1 < b.count else { return nil }; return str(b, i + 2, Int(b[i + 1]))
        case 0x80...0x8F: return parseMap(b, i + 1, Int(tag & 0x0F))
        case 0xDE: guard i + 2 < b.count else { return nil }; return parseMap(b, i + 3, Int(be(b, i + 1, 2)))
        default: return nil
        }
    }
    private static func bin(_ b: [UInt8], _ start: Int, _ n: Int) -> (MsgPackValue, Int)? {
        guard start + n <= b.count else { return nil }
        return (.bin(Data(b[start..<start + n])), start + n)
    }
    private static func str(_ b: [UInt8], _ start: Int, _ n: Int) -> (MsgPackValue, Int)? {
        guard start + n <= b.count, let s = String(bytes: b[start..<start + n], encoding: .utf8) else { return nil }
        return (.string(s), start + n)
    }
    private static func parseMap(_ b: [UInt8], _ start: Int, _ count: Int) -> (MsgPackValue, Int)? {
        var i = start; var pairs: [MsgPackValue.Pair] = []
        for _ in 0..<count {
            guard let (kv, ni) = parse(b, i), case let .string(key) = kv,
                  let (vv, ni2) = parse(b, ni) else { return nil }
            pairs.append(.init(key, vv)); i = ni2
        }
        return (.map(pairs), i)
    }
    private static func be(_ b: [UInt8], _ i: Int, _ n: Int) -> UInt64 {
        (0..<n).reduce(UInt64(0)) { ($0 << 8) | UInt64(b[i + $1]) }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter MsgPack`
Expected: PASS.

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter MsgPack`, confirm the named test fails, revert; final green:
- In `encodeUInt`, change the `u <= 0xFF` branch tag `0xCC` to `0xCD` → `msgPackEncodesScalarForms` (uint8) fails.
- In `encodeMap`, emit `0x80 | UInt8(n) + 1` (wrong entry count) → `msgPackEncodesOrderedMap` fails.
- In `parse`, change the `0xC4` bin length read to `Int(b[i])` (off-by-one) → `msgPackValueRoundTrips`/`decodeRejectsMalformed` fails.
- In `decodeValue`, drop the `next == b.count` trailing-bytes check → `msgPackValueDecodeRejectsMalformed` (trailing bytes) fails.

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCA/Support/MsgPack.swift Tests/ReTiCATests/Support/MsgPackTests.swift
git commit -m "feat: msgpack value codec (uint/bin/string/nil/ordered map)"
```

---

### Task 2: Resource content primitives

**Files:**
- Create: `Sources/ReTiCA/Resource/Resource.swift`
- Test: `Tests/ReTiCATests/Resource/ResourceTests.swift`

**Interfaces:**
- Consumes: `Crypto.fullHash(_ data: Data) -> Data` (32-byte SHA-256); `Token(key: Data) throws`, `Token.encrypt(_:) -> Data`, `Token.decrypt(_:) throws -> Data` (both in-core, as used by `Link.encrypt`/`decrypt`).
- Produces the `enum Resource` static funcs listed in Step 3.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCATests/Resource/ResourceTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

private let key = Data(repeating: 0x01, count: 64)   // valid AES-256 Token key
private let r = Data([0xAA, 0xBB, 0xCC, 0xDD])       // 4-byte resource random hash
private let prefix = Data([0x01, 0x02, 0x03, 0x04])  // 4-byte stream prefix

@Test func resourceHashIsFullHashOfDataAndRandom() {
    let data = Data("resource payload".utf8)
    #expect(Resource.resourceHash(data: data, randomHash: r) == Crypto.fullHash(data + r))
}

@Test func mapHashIsFirst4OfFullHashChunkAndRandom() {
    let chunk = Data(repeating: 0x5A, count: 40)
    #expect(Resource.mapHash(chunk: chunk, randomHash: r) == Data(Crypto.fullHash(chunk + r).prefix(4)))
}

@Test func buildStreamAssembleRoundTrips() {
    let data = Data("some resource bytes to transfer".utf8)
    let stream = Resource.buildStream(data: data, prefix: prefix, sessionKey: key)
    #expect(!stream.isEmpty)
    let parts = Resource.parts(stream: stream, sdu: 16)
    #expect(parts.count == Int(ceil(Double(stream.count) / 16.0)))
    #expect(Resource.assemble(parts: parts, sessionKey: key) == data)   // decrypt + strip prefix
}

@Test func hashmapLengthIsFourPerPart() {
    let stream = Resource.buildStream(data: Data(repeating: 0x11, count: 100), prefix: prefix, sessionKey: key)
    let parts = Resource.parts(stream: stream, sdu: 16)
    #expect(Resource.hashmap(parts: parts, randomHash: r).count == parts.count * 4)
}

@Test func verifyAcceptsCorrectHashRejectsTamper() {
    let data = Data("verify me".utf8)
    let h = Resource.resourceHash(data: data, randomHash: r)
    #expect(Resource.verify(data: data, randomHash: r, hash: h) == true)
    #expect(Resource.verify(data: data + Data([0x00]), randomHash: r, hash: h) == false)
}

@Test func proofRoundTrips() {
    let data = Data("prove me".utf8)
    let h = Resource.resourceHash(data: data, randomHash: r)
    let expected = Resource.expectedProof(data: data, hash: h)
    let proof = Resource.proofData(data: data, hash: h)
    #expect(proof.count == 64)
    #expect(proof.prefix(32) == h)
    #expect(Resource.validateProof(proofData: proof, expectedProof: expected) == true)
    #expect(Resource.validateProof(proofData: proof, expectedProof: Data(repeating: 0, count: 32)) == false)
    #expect(Resource.validateProof(proofData: Data(repeating: 0, count: 10), expectedProof: expected) == false)
}

@Test func buildStreamReturnsEmptyOnBadKey() {
    #expect(Resource.buildStream(data: Data([0x01]), prefix: prefix, sessionKey: Data([0x01, 0x02])).isEmpty)
    #expect(Resource.assemble(parts: [Data([0x01])], sessionKey: Data([0x01, 0x02])) == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter Resource`
Expected: FAIL — `Resource` doesn't exist.

- [ ] **Step 3: Implement the primitives**

Create `Sources/ReTiCA/Resource/Resource.swift`:

```swift
import Foundation

/// Pure content primitives of a Reticulum Resource (single-segment, uncompressed). Resources are
/// Link-coupled: the whole data stream is encrypted with the link's session key (`Token`) before
/// being split into parts, so the encryption primitives take the session key as a parameter.
public enum Resource {
    public static let mapHashLength = 4
    public static let randomHashSize = 4

    /// Resource hash: `full_hash(data ‖ r)` over the original (pre-encryption) data.
    public static func resourceHash(data: Data, randomHash: Data) -> Data {
        Crypto.fullHash(data + randomHash)
    }

    /// Encrypted transfer stream: `Token(key).encrypt(prefix(4) ‖ data)`. Empty on bad key.
    public static func buildStream(data: Data, prefix: Data, sessionKey: Data) -> Data {
        guard let token = try? Token(key: sessionKey) else { return Data() }
        return token.encrypt(prefix + data)
    }

    /// Split an encrypted stream into `sdu`-sized ciphertext chunks (the resource parts).
    public static func parts(stream: Data, sdu: Int) -> [Data] {
        guard sdu > 0 else { return [] }
        let s = Data(stream)
        var out: [Data] = []
        var i = s.startIndex
        while i < s.endIndex {
            let end = s.index(i, offsetBy: sdu, limitedBy: s.endIndex) ?? s.endIndex
            out.append(Data(s[i..<end]))
            i = end
        }
        return out
    }

    /// Map hash of a part: `full_hash(chunk ‖ r)[:4]`.
    public static func mapHash(chunk: Data, randomHash: Data) -> Data {
        Data(Crypto.fullHash(chunk + randomHash).prefix(mapHashLength))
    }

    /// The concatenated map hashes for all parts.
    public static func hashmap(parts: [Data], randomHash: Data) -> Data {
        var m = Data()
        for p in parts { m.append(mapHash(chunk: p, randomHash: randomHash)) }
        return m
    }

    /// Sender-side expected proof value: `full_hash(data ‖ h)`.
    public static func expectedProof(data: Data, hash: Data) -> Data {
        Crypto.fullHash(data + hash)
    }

    /// Reassemble parts back to the original data: `decrypt(join(parts))` then drop the 4-byte prefix.
    public static func assemble(parts: [Data], sessionKey: Data) -> Data? {
        guard let token = try? Token(key: sessionKey) else { return nil }
        var stream = Data()
        for p in parts { stream.append(p) }
        guard let plain = try? token.decrypt(stream), plain.count >= randomHashSize else { return nil }
        return Data(plain.dropFirst(randomHashSize))
    }

    /// Verify assembled data against the advertised hash: `full_hash(data ‖ r) == h`.
    public static func verify(data: Data, randomHash: Data, hash: Data) -> Bool {
        Crypto.fullHash(data + randomHash) == hash
    }

    /// Receiver-side proof data sent back to the sender: `h ‖ full_hash(data ‖ h)` (64 bytes).
    public static func proofData(data: Data, hash: Data) -> Data {
        Data(hash) + Crypto.fullHash(data + hash)
    }

    /// Sender validates a received proof: 64 bytes and its trailing 32 equal the expected proof.
    public static func validateProof(proofData: Data, expectedProof: Data) -> Bool {
        let d = Data(proofData)
        guard d.count == 64 else { return false }
        return Data(d.suffix(32)) == expectedProof
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter Resource`
Expected: PASS.

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter Resource`, confirm the named test fails, revert; final green:
- In `mapHash`, change `.prefix(mapHashLength)` to `.prefix(8)` → `mapHashIsFirst4OfFullHashChunkAndRandom` fails.
- In `assemble`, drop the `.dropFirst(randomHashSize)` → `buildStreamAssembleRoundTrips` fails.
- In `verify`, change `==` to `!=` → `verifyAcceptsCorrectHashRejectsTamper` fails.
- In `validateProof`, change `d.suffix(32)` to `d.prefix(32)` → `proofRoundTrips` fails (prefix is `h`, not the proof).
- In `resourceHash`, hash `data` alone (drop `+ randomHash`) → `resourceHashIsFullHashOfDataAndRandom` fails.

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCA/Resource/Resource.swift Tests/ReTiCATests/Resource/ResourceTests.swift
git commit -m "feat: Resource content primitives (hash, stream, parts, assembly, proof)"
```

---

### Task 3: ResourceAdvertisement pack/unpack

**Files:**
- Create: `Sources/ReTiCA/Resource/ResourceAdvertisement.swift`
- Test: `Tests/ReTiCATests/Resource/ResourceAdvertisementTests.swift`

**Interfaces:**
- Consumes: `MsgPack.encode(MsgPackValue)`, `MsgPack.decodeValue(Data)`, `MsgPackValue`.
- Produces: `ResourceAdvertisement` (memberwise init, fields below), `.pack() -> Data`, `static unpack(_:) -> ResourceAdvertisement?`, and the `isEncrypted`/`isCompressed`/`isSplit`/`isRequest`/`isResponse`/`hasMetadata` accessors.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCATests/Resource/ResourceAdvertisementTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

private func sampleAdvertisement() -> ResourceAdvertisement {
    ResourceAdvertisement(
        transferSize: 40, dataSize: 20, numberOfParts: 1,
        hash: Data(repeating: 0x11, count: 32), randomHash: Data(repeating: 0x22, count: 4),
        originalHash: Data(repeating: 0x11, count: 32), segmentIndex: 0, totalSegments: 1,
        requestID: nil, flags: 0x01, hashmap: Data(repeating: 0x33, count: 4))
}

@Test func advertisementPacksToReferenceBytes() {
    // umsgpack.packb of {t:40,d:20,n:1,h:0x11*32,r:0x22*4,o:0x11*32,i:0,l:1,q:None,f:1,m:0x33*4}
    let expected = Data(hexString:
        "8ba17428a16414a16e01a168c420" + String(repeating: "11", count: 32) +
        "a172c40422222222a16fc420" + String(repeating: "11", count: 32) +
        "a16900a16c01a171c0a16601a16dc40433333333")!
    #expect(sampleAdvertisement().pack() == expected)
}

@Test func advertisementRoundTrips() {
    let adv = sampleAdvertisement()
    #expect(ResourceAdvertisement.unpack(adv.pack()) == adv)
}

@Test func advertisementFlagAccessors() {
    var adv = sampleAdvertisement()
    #expect(adv.isEncrypted == true && adv.isCompressed == false && adv.isRequest == false)
    adv.flags = 0b0011_1110   // meta+response+request+split+compressed, not encrypted
    #expect(adv.hasMetadata && adv.isResponse && adv.isRequest && adv.isSplit && adv.isCompressed)
    #expect(adv.isEncrypted == false)
}

@Test func advertisementUnpackWithRequestID() {
    var adv = sampleAdvertisement()
    adv.requestID = Data(repeating: 0x9A, count: 16)
    #expect(ResourceAdvertisement.unpack(adv.pack())?.requestID == adv.requestID)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ResourceAdvertisement`
Expected: FAIL — `ResourceAdvertisement` doesn't exist.

- [ ] **Step 3: Implement the advertisement**

Create `Sources/ReTiCA/Resource/ResourceAdvertisement.swift`:

```swift
import Foundation

/// A Reticulum resource advertisement (`RESOURCE_ADV` payload): a MessagePack dictionary with keys
/// `t,d,n,h,r,o,i,l,q,f,m` (in that order, matching RNS `ResourceAdvertisement.pack`).
public struct ResourceAdvertisement: Equatable {
    public var transferSize: UInt64    // t — encrypted transfer stream size
    public var dataSize: UInt64        // d — original (uncompressed) data size
    public var numberOfParts: UInt64   // n
    public var hash: Data              // h
    public var randomHash: Data        // r
    public var originalHash: Data      // o — first-segment hash (== h for a single segment)
    public var segmentIndex: UInt64    // i
    public var totalSegments: UInt64   // l
    public var requestID: Data?        // q
    public var flags: UInt8            // f
    public var hashmap: Data           // m

    public init(transferSize: UInt64, dataSize: UInt64, numberOfParts: UInt64, hash: Data,
                randomHash: Data, originalHash: Data, segmentIndex: UInt64, totalSegments: UInt64,
                requestID: Data?, flags: UInt8, hashmap: Data) {
        self.transferSize = transferSize; self.dataSize = dataSize; self.numberOfParts = numberOfParts
        self.hash = hash; self.randomHash = randomHash; self.originalHash = originalHash
        self.segmentIndex = segmentIndex; self.totalSegments = totalSegments
        self.requestID = requestID; self.flags = flags; self.hashmap = hashmap
    }

    public func pack() -> Data {
        let q: MsgPackValue = requestID.map { .bin($0) } ?? .null
        return MsgPack.encode(.map([
            .init("t", .uint(transferSize)),
            .init("d", .uint(dataSize)),
            .init("n", .uint(numberOfParts)),
            .init("h", .bin(hash)),
            .init("r", .bin(randomHash)),
            .init("o", .bin(originalHash)),
            .init("i", .uint(segmentIndex)),
            .init("l", .uint(totalSegments)),
            .init("q", q),
            .init("f", .uint(UInt64(flags))),
            .init("m", .bin(hashmap)),
        ]))
    }

    public static func unpack(_ data: Data) -> ResourceAdvertisement? {
        guard case let .map(pairs)? = MsgPack.decodeValue(data) else { return nil }
        var dict: [String: MsgPackValue] = [:]
        for p in pairs { dict[p.key] = p.value }
        func uint(_ k: String) -> UInt64? { if case let .uint(x)? = dict[k] { return x } else { return nil } }
        func bin(_ k: String) -> Data? { if case let .bin(x)? = dict[k] { return x } else { return nil } }
        guard let t = uint("t"), let d = uint("d"), let n = uint("n"),
              let h = bin("h"), let r = bin("r"), let o = bin("o"),
              let i = uint("i"), let l = uint("l"), let f = uint("f"), let m = bin("m")
        else { return nil }
        let q: Data?
        switch dict["q"] {
        case .some(.bin(let x)): q = x
        case .some(.null), .none: q = nil
        default: return nil
        }
        return ResourceAdvertisement(transferSize: t, dataSize: d, numberOfParts: n, hash: h,
                                     randomHash: r, originalHash: o, segmentIndex: i, totalSegments: l,
                                     requestID: q, flags: UInt8(truncatingIfNeeded: f), hashmap: m)
    }

    public var isEncrypted: Bool { flags & 0x01 == 0x01 }
    public var isCompressed: Bool { (flags >> 1) & 0x01 == 0x01 }
    public var isSplit: Bool { (flags >> 2) & 0x01 == 0x01 }
    public var isRequest: Bool { (flags >> 3) & 0x01 == 0x01 }
    public var isResponse: Bool { (flags >> 4) & 0x01 == 0x01 }
    public var hasMetadata: Bool { (flags >> 5) & 0x01 == 0x01 }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ResourceAdvertisement`
Expected: PASS.

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter ResourceAdvertisement`, confirm the named test fails, revert; final green:
- In `pack`, swap the order of the `"t"` and `"d"` pairs → `advertisementPacksToReferenceBytes` fails.
- In `pack`, emit `.uint(UInt64(flags))` as `.uint(0)` → `advertisementPacksToReferenceBytes` fails.
- In `unpack`, read `q` as always `nil` (drop the `.bin` case) → `advertisementUnpackWithRequestID` fails.
- In `isEncrypted`, change `& 0x01` to `& 0x02` → `advertisementFlagAccessors` fails.

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCA/Resource/ResourceAdvertisement.swift Tests/ReTiCATests/Resource/ResourceAdvertisementTests.swift
git commit -m "feat: ResourceAdvertisement msgpack pack/unpack"
```

---

### Task 4: Cross-validation vs Python-RNS, end-to-end round-trip, gate, README

**Files:**
- Modify: `Tests/ReTiCATests/Vectors/generate_fixtures.py`
- Regenerate: `Tests/ReTiCATests/Vectors/fixtures.json`
- Modify: `Tests/ReTiCATests/Vectors/VectorFixtures.swift`
- Create: `Tests/ReTiCATests/Vectors/ResourceCrossValidationTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: fixture fields `resource_data`, `resource_random_hash`, `resource_prefix`, `resource_token_key`, `resource_sdu`, `resource_stream`, `resource_hash`, `resource_map_hash0`, `resource_proof`, `resource_adv_msgpack`; matching `VectorFixtures` properties.

**Gotcha (bit this workflow before):** an external linter can revert `generate_fixtures.py`/`fixtures.json`. After regenerating AND after committing, verify the committed blob (`git show HEAD:Tests/ReTiCATests/Vectors/fixtures.json` contains `resource_adv_msgpack`); if missing, re-stage and `git commit --amend --no-edit`, then re-verify.

- [ ] **Step 1: Add resource vectors to the generator**

In `Tests/ReTiCATests/Vectors/generate_fixtures.py`, after the existing link/RTT block (and after `import RNS.vendor.umsgpack as umsgpack` — add that import near the top if not already imported by an earlier task; it is imported for the RTT vectors), add:

```python
# --- Resource primitive vectors (single-segment, uncompressed; genuine RNS building blocks) ---
from RNS.Resource import ResourceAdvertisement as RNSResourceAdvertisement

res_data     = b"reticulum resource payload for cross validation"
res_r        = os.urandom(4)                       # resource random hash
res_prefix   = os.urandom(4)                       # 4-byte stream prefix
res_key      = os.urandom(64)                      # AES-256 Token key
res_sdu      = 32
res_stream   = LinkToken(res_key).encrypt(res_prefix + res_data)   # genuine Token (aliased LinkToken in this generator)
res_hash     = RNS.Identity.full_hash(res_data + res_r)         # genuine full_hash
res_parts    = [res_stream[i:i+res_sdu] for i in range(0, len(res_stream), res_sdu)]
res_map_hash0 = RNS.Identity.full_hash(res_parts[0] + res_r)[:4]
res_proof    = RNS.Identity.full_hash(res_data + res_hash)
res_hashmap  = b"".join(RNS.Identity.full_hash(p + res_r)[:4] for p in res_parts)

# Genuine RNS advertisement pack (construct empty, set fields, pack).
_adv = RNSResourceAdvertisement()
_adv.t = len(res_stream); _adv.d = len(res_data); _adv.n = len(res_parts)
_adv.h = res_hash; _adv.r = res_r; _adv.o = res_hash
_adv.i = 0; _adv.l = 1; _adv.q = None; _adv.f = 0x01; _adv.m = res_hashmap
res_adv_msgpack = _adv.pack(segment=0)
```

Then add to the `json.dumps({...})` dict:

```python
    "resource_data": res_data.hex(),
    "resource_random_hash": res_r.hex(),
    "resource_prefix": res_prefix.hex(),
    "resource_token_key": res_key.hex(),
    "resource_sdu": res_sdu,
    "resource_stream": res_stream.hex(),
    "resource_hash": res_hash.hex(),
    "resource_map_hash0": res_map_hash0.hex(),
    "resource_proof": res_proof.hex(),
    "resource_adv_msgpack": res_adv_msgpack.hex(),
```

- [ ] **Step 2: Regenerate the fixtures**

Run: `/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/generate_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/fixtures.json`

Verify: `grep -n "resource_adv_msgpack" /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/fixtures.json`
Expected: one line present.

- [ ] **Step 3: Decode the new fields in VectorFixtures**

In `Tests/ReTiCATests/Vectors/VectorFixtures.swift`, add the properties (alongside the existing ones):

```swift
    let resourceData: String
    let resourceRandomHash: String
    let resourcePrefix: String
    let resourceTokenKey: String
    let resourceSdu: Int
    let resourceStream: String
    let resourceHash: String
    let resourceMapHash0: String
    let resourceProof: String
    let resourceAdvMsgpack: String
```

And to the explicit exhaustive `enum CodingKeys` add:

```swift
        case resourceData = "resource_data"
        case resourceRandomHash = "resource_random_hash"
        case resourcePrefix = "resource_prefix"
        case resourceTokenKey = "resource_token_key"
        case resourceSdu = "resource_sdu"
        case resourceStream = "resource_stream"
        case resourceHash = "resource_hash"
        case resourceMapHash0 = "resource_map_hash0"
        case resourceProof = "resource_proof"
        case resourceAdvMsgpack = "resource_adv_msgpack"
```

- [ ] **Step 4: Write the cross-validation + end-to-end tests**

Create `Tests/ReTiCATests/Vectors/ResourceCrossValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func swiftResourceHashMatchesReference() throws {
    let f = try VectorFixtures.load()
    #expect(Resource.resourceHash(data: Data(hexString: f.resourceData)!,
                                  randomHash: Data(hexString: f.resourceRandomHash)!)
            == Data(hexString: f.resourceHash))
}

@Test func swiftAssemblesReferenceResourceStream() throws {
    let f = try VectorFixtures.load()
    let key = Data(hexString: f.resourceTokenKey)!
    let parts = Resource.parts(stream: Data(hexString: f.resourceStream)!, sdu: f.resourceSdu)
    #expect(Resource.assemble(parts: parts, sessionKey: key) == Data(hexString: f.resourceData))
    // map hash of the first part matches the reference
    #expect(Resource.mapHash(chunk: parts[0], randomHash: Data(hexString: f.resourceRandomHash)!)
            == Data(hexString: f.resourceMapHash0))
}

@Test func swiftResourceProofMatchesReference() throws {
    let f = try VectorFixtures.load()
    let data = Data(hexString: f.resourceData)!
    let h = Data(hexString: f.resourceHash)!
    #expect(Resource.expectedProof(data: data, hash: h) == Data(hexString: f.resourceProof))
    #expect(Resource.proofData(data: data, hash: h).suffix(32) == Data(hexString: f.resourceProof))
}

@Test func swiftAdvertisementPackMatchesReference() throws {
    let f = try VectorFixtures.load()
    let key = Data(hexString: f.resourceTokenKey)!
    let stream = Data(hexString: f.resourceStream)!
    let parts = Resource.parts(stream: stream, sdu: f.resourceSdu)
    let r = Data(hexString: f.resourceRandomHash)!
    let h = Data(hexString: f.resourceHash)!
    let adv = ResourceAdvertisement(
        transferSize: UInt64(stream.count), dataSize: UInt64(Data(hexString: f.resourceData)!.count),
        numberOfParts: UInt64(parts.count), hash: h, randomHash: r, originalHash: h,
        segmentIndex: 0, totalSegments: 1, requestID: nil, flags: 0x01,
        hashmap: Resource.hashmap(parts: parts, randomHash: r))
    #expect(adv.pack() == Data(hexString: f.resourceAdvMsgpack))
    _ = key
}

@Test func endToEndResourcePrimitiveRoundTrip() {
    // Sender builds; receiver assembles + verifies + proves; sender validates. No fixtures.
    let key = Data(repeating: 0x07, count: 64)
    let data = Data("the quick brown fox jumps over the lazy dog, twice for good measure".utf8)
    let r = Data([0x01, 0x02, 0x03, 0x04])
    let prefix = Data([0x0A, 0x0B, 0x0C, 0x0D])
    let stream = Resource.buildStream(data: data, prefix: prefix, sessionKey: key)
    let parts = Resource.parts(stream: stream, sdu: 24)
    let h = Resource.resourceHash(data: data, randomHash: r)
    let expected = Resource.expectedProof(data: data, hash: h)
    let adv = ResourceAdvertisement(
        transferSize: UInt64(stream.count), dataSize: UInt64(data.count), numberOfParts: UInt64(parts.count),
        hash: h, randomHash: r, originalHash: h, segmentIndex: 0, totalSegments: 1,
        requestID: nil, flags: 0x01, hashmap: Resource.hashmap(parts: parts, randomHash: r))

    // Receiver
    let recvAdv = ResourceAdvertisement.unpack(adv.pack())!
    let assembled = Resource.assemble(parts: parts, sessionKey: key)!
    #expect(assembled == data)
    #expect(Resource.verify(data: assembled, randomHash: recvAdv.randomHash, hash: recvAdv.hash))
    let proof = Resource.proofData(data: assembled, hash: recvAdv.hash)

    // Sender validates
    #expect(Resource.validateProof(proofData: proof, expectedProof: expected))
}
```

- [ ] **Step 5: Run the cross-validation + full suite**

Run: `swift test --filter Resource`
Expected: PASS (content, advertisement, cross-validation, end-to-end).

Run: `swift test`
Expected: PASS — all prior tests plus the resource tests.

- [ ] **Step 6: Commit (verify fixtures captured)**

```
git add Tests/ReTiCATests/Vectors/generate_fixtures.py Tests/ReTiCATests/Vectors/fixtures.json Tests/ReTiCATests/Vectors/VectorFixtures.swift Tests/ReTiCATests/Vectors/ResourceCrossValidationTests.swift
git commit -m "test: cross-validate resource primitives + end-to-end round-trip vs Python-RNS"
```

After committing, run `git show HEAD:Tests/ReTiCATests/Vectors/fixtures.json` and confirm `resource_adv_msgpack` is present; if not, re-stage and `git commit --amend --no-edit`, then re-verify.

- [ ] **Step 7: Mutation sweep on the cross-validation tests**

Apply each, run `swift test --filter Resource`, confirm the named test fails, revert; final green:
- In `ResourceAdvertisement.pack`, change the `"h"` value to `.bin(randomHash)` (wrong field) → `swiftAdvertisementPackMatchesReference` fails.
- In `Resource.assemble`, drop `.dropFirst(randomHashSize)` → `swiftAssemblesReferenceResourceStream` and `endToEndResourcePrimitiveRoundTrip` fail.
Run `swift test` after reverting → green.

- [ ] **Step 8: Update the README**

In `README.md`, add a subsection under the core layer (near the Link/crypto sections):

```markdown
### Resource primitives (`Resource`, `ResourceAdvertisement`)

The `Resource` namespace (pure core) implements the single-segment, uncompressed representation
primitives of a Reticulum Resource — the chunked large-object transfer that rides over a link:

- `Resource.buildStream` / `parts` — the data is prefixed with a 4-byte random hash, encrypted as
  one stream under the link's session key (`Token`), then split into SDU-sized ciphertext parts.
- `Resource.resourceHash` / `mapHash` / `hashmap` — the resource hash `full_hash(data ‖ r)` and the
  per-part map hashes `full_hash(chunk ‖ r)[:4]`.
- `Resource.assemble` / `verify` — reassemble (decrypt + strip prefix) and verify against the hash.
- `Resource.proofData` / `expectedProof` / `validateProof` — the receiver's `h ‖ full_hash(data ‖ h)`
  proof and the sender's validation.
- `ResourceAdvertisement.pack` / `unpack` — the `RESOURCE_ADV` MessagePack dictionary
  (`t,d,n,h,r,o,i,l,q,f,m`), built on a `MsgPack` value codec (uint/bin/string/nil/ordered-map).

All of it is cross-validated against Python-RNS 1.3.8 (msgpack bytes, hashes, `Token` decrypt, and a
genuine `ResourceAdvertisement.pack`). Multi-segment resources, compression, and the transfer state
machine (advertise → request → send → assemble → prove, with windowing/retransmission) are future
slices, as is wiring resources over a live `LinkSession`.
```

- [ ] **Step 9: Commit**

```
git add README.md
git commit -m "docs: Resource primitives"
```

---

## Self-Review

**Spec coverage:**
- MsgPack value codec (uint/bin/string/nil/ordered-map) → Task 1. ✓
- Resource content primitives (hash/stream/parts/mapHash/hashmap/expectedProof/assemble/verify/proofData/validateProof) → Task 2. ✓
- ResourceAdvertisement pack/unpack + flag accessors → Task 3. ✓
- Cross-validation (msgpack bytes, hashes, Token decrypt, genuine advertisement) driving reference code → Task 4. ✓
- End-to-end primitive round-trip → Task 4. ✓
- Mutation discipline → each task. ✓
- Scope: single-segment/uncompressed, pure core, no state machine/TCA/integration → confirmed; only `MsgPack`/`Resource`/`ResourceAdvertisement` + tests + fixtures + README touched. ✓

**Placeholder scan:** No TBD/TODO; every code step has complete code. The Task-1 codec, Task-2 primitives, and Task-3 advertisement are given in full; Task-4 fixtures give the exact generator additions and the expected-byte `hexString` for the advertisement test.

**Type consistency:** `MsgPackValue`/`MsgPackValue.Pair` (Task 1) are used by `ResourceAdvertisement.pack`/`unpack` (Task 3) and the fixtures (Task 4). `Resource` func signatures (Task 2) are used identically in Tasks 3–4. `ResourceAdvertisement` field names/order match between `pack` (Task 3) and the round-trip/cross-val tests (Tasks 3–4). Fixture field names (`resource_*`) match between the Task-4 generator and `VectorFixtures`. The advertisement's expected bytes in Task 3 (`8b…`) are the fixmap(11) encoding verified against `umsgpack`.
