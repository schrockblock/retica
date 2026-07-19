# Packet + Destination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the byte-exact Reticulum **Packet** wire format and the **Destination** addressing + **Announce** model to the ReTiCA library, wire-compatible with `markqvist/Reticulum`, with framing cleanly separated from crypto.

**Architecture:** Pure Swift value types, no TCA, zero third-party deps. `Packet` is pure framing over opaque payload bytes. `Destination` owns addressing (name/hash) and crypto dispatch (SINGLE→`Identity`, GROUP→`Token`, PLAIN→passthrough). `Announce` builds/validates the signed announce payload. Thin composers (`Packet.data`, `Packet.announce`) wire crypto + framing for the common cases. Determinism seams keep encryption-free paths testable byte-for-byte; cross-validation fixtures prove interop against Python-RNS 1.3.8.

**Tech Stack:** Swift 6.3 / Swift 6 language mode, Swift Testing, builds on the existing `Crypto`/`Token`/`Identity` from sub-project #1.

## Global Constraints

- **Toolchain:** swift-tools-version 6.3; `swiftLanguageModes: [.v6]`. Do not modify `Package.swift` except the fixtures task (adding nothing — `fixtures.json` is already a bundled resource).
- **Test framework:** Swift Testing (`import Testing`, `@Test`, `#expect`). Run with `swift test`.
- **Zero third-party dependencies.** Only CryptoKit + CommonCrypto (via existing code).
- **Byte-exact with the reference** (`/tmp/ReTiCA/Reticulum-ref`). Key constants: MTU 500; address length 16; HEADER_MINSIZE 19; HEADER_MAXSIZE 35; MDU 464; name-hash length 10; hop limit (`PATHFINDER_M`) 128.
- **Flags byte:** `header_type<<6 | context_flag<<5 | transport_type<<4 | destination_type<<2 | packet_type`.
- **Packet layout:** HEADER_1 = `flags ‖ hops ‖ dest_hash(16) ‖ context(1) ‖ payload`; HEADER_2 = `flags ‖ hops ‖ transport_id(16) ‖ dest_hash(16) ‖ context(1) ‖ payload`.
- **Packet hash:** `SHA256( bytes([flags & 0x0F]) ‖ dest_hash ‖ context ‖ payload )` — excludes hops/transport_id/header_type/context_flag/transport_type.
- **Destination hash:** `SHA256( SHA256(expand_name(None,app,*aspects))[:10] ‖ identity_hash(16 or absent) )[:16]`.
- **Announce payload:** `public_key(64) ‖ name_hash(10) ‖ random_hash(10) ‖ ratchet(0|32) ‖ signature(64) [‖ app_data]`, signed over `dest_hash ‖ public_key ‖ name_hash ‖ random_hash ‖ ratchet [‖ app_data]`.
- **No TCA in this slice.** Value semantics; no shared mutable global state.
- **Mutation-testing discipline:** after each task's tests pass, batch-mutate the covered production code, confirm the tests fail, revert, confirm green. Only then is the commit final.

---

## File Structure

```
Sources/ReTiCA/
  Packet/
    PacketConstants.swift  // PacketType, HeaderType, TransportType, DestinationType, PacketContext
    Packet.swift           // Packet struct: flags, packed(), init?(raw:), hash + composers (later task)
  Destination/
    Destination.swift      // addressing statics + instance + encrypt/decrypt dispatch
    Announce.swift         // buildPayload + parse/validate + randomHash seam

Tests/ReTiCATests/
  Packet/PacketTests.swift
  Packet/PacketHashTests.swift
  Destination/DestinationTests.swift
  Destination/AnnounceTests.swift
  Vectors/
    generate_fixtures.py   // extended
    fixtures.json          // regenerated (user's RNS env)
    VectorFixtures.swift   // extended decoder
    PacketDestinationCrossValidationTests.swift
```

Composers (`Packet.data`, `Packet.announce`) live in `Packet.swift` as static factory methods (added in Task 5).

---

### Task 1: Packet framing + constants

**Files:**
- Create: `Sources/ReTiCA/Packet/PacketConstants.swift`
- Create: `Sources/ReTiCA/Packet/Packet.swift`
- Test: `Tests/ReTiCATests/Packet/PacketTests.swift`

**Interfaces:**
- Consumes: nothing from prior slices (pure framing).
- Produces:
  - `enum PacketType: UInt8 { data=0, announce=1, linkRequest=2, proof=3 }`
  - `enum HeaderType: UInt8 { header1=0, header2=1 }`
  - `enum TransportType: UInt8 { broadcast=0, transport=1 }`
  - `enum DestinationType: UInt8 { single=0, group=1, plain=2, link=3 }`
  - `enum PacketContext: UInt8` (full reference set)
  - `struct Packet: Equatable` with fields + `flags: UInt8`, `func packed() throws -> Data`, `init?(raw: Data)`, statics `mtu=500`, `addressLength=16`, `maxHops: UInt8 = 128`
  - `enum PacketError: Error { exceedsMTU, missingTransportId, malformed }`

- [ ] **Step 1: Write the failing tests**

`Tests/ReTiCATests/Packet/PacketTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func flagsByteEncodesAllSubfields() {
    // header2(1)<<6 | cf(1)<<5 | transport(1)<<4 | plain(2)<<2 | announce(1)
    let p = Packet(headerType: .header2, packetType: .announce, transportType: .transport,
                   destinationType: .plain, context: .none, contextFlag: true, hops: 0,
                   destinationHash: Data(repeating: 0xAA, count: 16),
                   transportId: Data(repeating: 0xBB, count: 16), payload: Data())
    #expect(p.flags == 0b0111_1001) // 0x79
}

@Test func header1PackUnpackRoundTrips() throws {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .single, context: .none, contextFlag: false, hops: 3,
                   destinationHash: Data(repeating: 0x11, count: 16), transportId: nil,
                   payload: Data("hello".utf8))
    let raw = try p.packed()
    // flags: single(0)<<2 | data(0) = 0
    #expect(raw.first == 0x00)
    #expect(raw.count == 2 + 16 + 1 + 5)
    let parsed = try #require(Packet(raw: raw))
    #expect(parsed == p)
}

@Test func header2PackUnpackRoundTripsWithTransportId() throws {
    let p = Packet(headerType: .header2, packetType: .data, transportType: .transport,
                   destinationType: .single, context: .resource, contextFlag: false, hops: 7,
                   destinationHash: Data(repeating: 0x22, count: 16),
                   transportId: Data(repeating: 0x33, count: 16), payload: Data("x".utf8))
    let raw = try p.packed()
    #expect(raw.count == 2 + 16 + 16 + 1 + 1)
    let parsed = try #require(Packet(raw: raw))
    #expect(parsed == p)
    #expect(parsed.transportId == Data(repeating: 0x33, count: 16))
}

@Test func packedRejectsOverMTU() {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                   destinationHash: Data(repeating: 0x00, count: 16), transportId: nil,
                   payload: Data(repeating: 0x00, count: 500))
    #expect(throws: PacketError.exceedsMTU) { _ = try p.packed() }
}

@Test func header2WithoutTransportIdThrows() {
    let p = Packet(headerType: .header2, packetType: .data, transportType: .broadcast,
                   destinationType: .single, context: .none, contextFlag: false, hops: 0,
                   destinationHash: Data(repeating: 0x00, count: 16), transportId: nil,
                   payload: Data())
    #expect(throws: PacketError.missingTransportId) { _ = try p.packed() }
}

@Test func unpackRejectsExcessiveHops() {
    var raw = Data([0x00, 200]) // hops 200 >= 128
    raw.append(Data(repeating: 0, count: 16 + 1))
    #expect(Packet(raw: raw) == nil)
}

@Test func unpackRejectsTruncated() {
    #expect(Packet(raw: Data([0x00, 0x00])) == nil) // no room for dest hash + context
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PacketTests`
Expected: FAIL — `Packet`/`PacketType` not defined.

- [ ] **Step 3: Write minimal implementation**

`Sources/ReTiCA/Packet/PacketConstants.swift`:

```swift
import Foundation

/// Packet type (2 low bits of the flags byte).
public enum PacketType: UInt8, Equatable { case data = 0, announce = 1, linkRequest = 2, proof = 3 }

/// Header type (bit 6 of the flags byte).
public enum HeaderType: UInt8, Equatable { case header1 = 0, header2 = 1 }

/// Transport type (bit 4 of the flags byte).
public enum TransportType: UInt8, Equatable { case broadcast = 0, transport = 1 }

/// Destination type (bits 2-3 of the flags byte).
public enum DestinationType: UInt8, Equatable { case single = 0, group = 1, plain = 2, link = 3 }

/// Packet context byte (full reference set from RNS/Packet.py).
public enum PacketContext: UInt8, Equatable {
    case none = 0x00
    case resource = 0x01
    case resourceAdvertisement = 0x02
    case resourceRequest = 0x03
    case resourceHashmapUpdate = 0x04
    case resourceProof = 0x05
    case resourceInitiatorCancel = 0x06
    case resourceReceiverCancel = 0x07
    case cacheRequest = 0x08
    case request = 0x09
    case response = 0x0A
    case pathResponse = 0x0B
    case command = 0x0C
    case commandStatus = 0x0D
    case channel = 0x0E
    case keepalive = 0xFA
    case linkIdentify = 0xFB
    case linkClose = 0xFC
    case linkProof = 0xFD
    case linkRequestRTT = 0xFE
    case linkRequestProof = 0xFF
}
```

`Sources/ReTiCA/Packet/Packet.swift`:

```swift
import Foundation

public enum PacketError: Error, Equatable {
    case exceedsMTU
    case missingTransportId
    case malformed
}

/// A Reticulum packet. Pure framing over an opaque `payload` (plaintext or ciphertext);
/// encryption is a separate concern handled by `Destination`.
public struct Packet: Equatable {
    public static let mtu = 500
    public static let addressLength = 16   // TRUNCATED_HASHLENGTH / 8
    public static let maxHops: UInt8 = 128 // PATHFINDER_M

    public var headerType: HeaderType
    public var packetType: PacketType
    public var transportType: TransportType
    public var destinationType: DestinationType
    public var context: PacketContext
    public var contextFlag: Bool
    public var hops: UInt8
    public var destinationHash: Data       // 16 bytes (or link_id for LRPROOF)
    public var transportId: Data?          // 16 bytes, present iff headerType == .header2
    public var payload: Data               // opaque

    public init(headerType: HeaderType = .header1, packetType: PacketType,
                transportType: TransportType = .broadcast, destinationType: DestinationType,
                context: PacketContext = .none, contextFlag: Bool = false, hops: UInt8 = 0,
                destinationHash: Data, transportId: Data? = nil, payload: Data) {
        self.headerType = headerType
        self.packetType = packetType
        self.transportType = transportType
        self.destinationType = destinationType
        self.context = context
        self.contextFlag = contextFlag
        self.hops = hops
        self.destinationHash = destinationHash
        self.transportId = transportId
        self.payload = payload
    }

    public var flags: UInt8 {
        let h = headerType.rawValue << 6
        let cf = (contextFlag ? UInt8(1) : UInt8(0)) << 5
        let tt = transportType.rawValue << 4
        let dt = destinationType.rawValue << 2
        return h | cf | tt | dt | packetType.rawValue
    }

    public func packed() throws -> Data {
        guard destinationHash.count == Packet.addressLength else { throw PacketError.malformed }
        var raw = Data()
        raw.append(flags)
        raw.append(hops)
        if headerType == .header2 {
            guard let tid = transportId, tid.count == Packet.addressLength else {
                throw PacketError.missingTransportId
            }
            raw.append(tid)
        }
        raw.append(destinationHash)
        raw.append(context.rawValue)
        raw.append(payload)
        guard raw.count <= Packet.mtu else { throw PacketError.exceedsMTU }
        return raw
    }

    public init?(raw rawInput: Data) {
        let raw = Data(rawInput) // normalize to 0-based indices
        guard raw.count >= 2 else { return nil }
        let flags = raw[0]
        let hops = raw[1]
        guard hops < Packet.maxHops else { return nil }
        guard let headerType = HeaderType(rawValue: (flags & 0b0100_0000) >> 6),
              let transportType = TransportType(rawValue: (flags & 0b0001_0000) >> 4),
              let destinationType = DestinationType(rawValue: (flags & 0b0000_1100) >> 2),
              let packetType = PacketType(rawValue: flags & 0b0000_0011)
        else { return nil }
        let contextFlag = ((flags & 0b0010_0000) >> 5) == 1
        let dstLen = Packet.addressLength

        var idx = 2
        var transportId: Data? = nil
        if headerType == .header2 {
            guard raw.count >= idx + dstLen else { return nil }
            transportId = raw.subdata(in: idx..<(idx + dstLen))
            idx += dstLen
        }
        guard raw.count >= idx + dstLen + 1 else { return nil }
        let destinationHash = raw.subdata(in: idx..<(idx + dstLen)); idx += dstLen
        guard let context = PacketContext(rawValue: raw[idx]) else { return nil }
        idx += 1
        let payload = raw.subdata(in: idx..<raw.count)

        self.init(headerType: headerType, packetType: packetType, transportType: transportType,
                  destinationType: destinationType, context: context, contextFlag: contextFlag,
                  hops: hops, destinationHash: destinationHash, transportId: transportId,
                  payload: payload)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PacketTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCA/Packet Tests/ReTiCATests/Packet/PacketTests.swift
git commit -m "feat: Packet wire format (framing, flags, pack/unpack)"
```

---

### Task 2: Packet hash

**Files:**
- Modify: `Sources/ReTiCA/Packet/Packet.swift` (add `hashablePart`, `packetHash`, `truncatedHash`)
- Test: `Tests/ReTiCATests/Packet/PacketHashTests.swift`

**Interfaces:**
- Consumes: `Crypto.fullHash`, `Crypto.truncatedHash` (from sub-project #1).
- Produces: `Packet.hashablePart: Data`, `Packet.packetHash: Data` (32), `Packet.truncatedHash: Data` (16).

- [ ] **Step 1: Write the failing test**

`Tests/ReTiCATests/Packet/PacketHashTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

private func base() -> Packet {
    Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
           destinationType: .single, context: .none, contextFlag: false, hops: 0,
           destinationHash: Data(repeating: 0x11, count: 16), transportId: nil,
           payload: Data("payload".utf8))
}

@Test func hashablePartMatchesReferenceShape() {
    let p = base()
    var expected = Data([p.flags & 0x0F])
    expected.append(p.destinationHash)
    expected.append(p.context.rawValue)
    expected.append(p.payload)
    #expect(p.hashablePart == expected)
    #expect(p.packetHash == Crypto.fullHash(expected))
    #expect(p.truncatedHash.count == 16)
}

@Test func packetHashIsStableAcrossHopsHeaderAndTransportId() {
    var a = base()
    var b = base()
    b.hops = 42
    b.headerType = .header2
    b.transportId = Data(repeating: 0x99, count: 16)
    b.transportType = .transport
    b.contextFlag = true
    #expect(a.packetHash == b.packetHash)
    // changing destination hash / context / payload DOES change the hash
    a.destinationHash = Data(repeating: 0x77, count: 16)
    #expect(a.packetHash != b.packetHash)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PacketHashTests`
Expected: FAIL — `hashablePart`/`packetHash` not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/ReTiCA/Packet/Packet.swift` inside `extension Packet`:

```swift
extension Packet {
    /// The bytes hashed to produce the packet hash. Excludes hops, transport id,
    /// header type, context flag, and transport type — matching RNS `get_hashable_part`.
    public var hashablePart: Data {
        var part = Data([(destinationType.rawValue << 2) | packetType.rawValue])
        part.append(destinationHash)
        part.append(context.rawValue)
        part.append(payload)
        return part
    }

    /// SHA-256 packet hash (32 bytes), stable across transport-mutated fields.
    public var packetHash: Data { Crypto.fullHash(hashablePart) }

    /// First 16 bytes of the packet hash.
    public var truncatedHash: Data { Crypto.truncatedHash(hashablePart) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PacketHashTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCA/Packet/Packet.swift Tests/ReTiCATests/Packet/PacketHashTests.swift
git commit -m "feat: transport-stable packet hash"
```

---

### Task 3: Destination (addressing + crypto dispatch)

**Files:**
- Create: `Sources/ReTiCA/Destination/Destination.swift`
- Test: `Tests/ReTiCATests/Destination/DestinationTests.swift`

**Interfaces:**
- Consumes: `Crypto.fullHash`, `Identity` (encrypt/decrypt/hash/hexHash), `Token`, `DestinationType`.
- Produces:
  - `struct Destination`
  - `enum Destination.Direction: UInt8 { in=0x11, out=0x12 }`
  - statics `expandName(appName:aspects:identityHexHash:) -> String`, `nameHash(appName:aspects:) -> Data` (10), `hash(identityHash:appName:aspects:) -> Data` (16)
  - `init?(kind: DestinationType, direction: Direction, appName: String, aspects: [String], identity: Identity?, groupKey: Data?)`
  - `var hash: Data`, `var nameHash: Data`
  - `func encrypt(_:ratchet:) -> Data`, `func decrypt(_:ratchets:enforceRatchets:) -> Data?`
  - `static let nameHashLength = 10`, `static let hashLength = 16`

Validation: dots forbidden in `appName`/aspects → `nil`. SINGLE requires `identity`, `groupKey == nil`. GROUP requires `groupKey`. PLAIN forbids both. LINK: no key requirement (session deferred).

- [ ] **Step 1: Write the failing test**

`Tests/ReTiCATests/Destination/DestinationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func expandNameBuildsDottedNameWithIdentityHex() {
    let n = Destination.expandName(appName: "app", aspects: ["a", "b"], identityHexHash: "deadbeef")
    #expect(n == "app.a.b.deadbeef")
    #expect(Destination.expandName(appName: "app", aspects: [], identityHexHash: nil) == "app")
}

@Test func nameHashIsTenBytesOfNameWithoutIdentity() {
    let nh = Destination.nameHash(appName: "app", aspects: ["a"])
    #expect(nh.count == 10)
    #expect(nh == Crypto.fullHash(Data("app.a".utf8)).prefix(10))
}

@Test func destinationHashMatchesConstruction() {
    let idHash = Data(repeating: 0x44, count: 16)
    let expected = Crypto.fullHash(Crypto.fullHash(Data("app.a".utf8)).prefix(10) + idHash).prefix(16)
    #expect(Destination.hash(identityHash: idHash, appName: "app", aspects: ["a"]) == expected)
}

@Test func plainDestinationHashHasNoIdentityMaterial() {
    let expected = Crypto.fullHash(Crypto.fullHash(Data("app".utf8)).prefix(10)).prefix(16)
    #expect(Destination.hash(identityHash: nil, appName: "app", aspects: []) == expected)
}

@Test func initRejectsDotsAndBadTypeCombos() {
    let id = Identity()
    #expect(Destination(kind: .single, direction: .out, appName: "a.b", aspects: [],
                        identity: id, groupKey: nil) == nil)
    #expect(Destination(kind: .single, direction: .out, appName: "app", aspects: ["x.y"],
                        identity: id, groupKey: nil) == nil)
    #expect(Destination(kind: .single, direction: .out, appName: "app", aspects: [],
                        identity: nil, groupKey: nil) == nil) // SINGLE needs identity
    #expect(Destination(kind: .plain, direction: .out, appName: "app", aspects: [],
                        identity: id, groupKey: nil) == nil) // PLAIN forbids identity
    #expect(Destination(kind: .group, direction: .out, appName: "app", aspects: [],
                        identity: nil, groupKey: nil) == nil) // GROUP needs key
}

@Test func singleDestinationEncryptDecryptRoundTrips() {
    let id = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: id, groupKey: nil)!
    #expect(dest.hash == Destination.hash(identityHash: id.hash, appName: "app", aspects: ["svc"]))
    let pt = Data("single secret".utf8)
    #expect(dest.decrypt(dest.encrypt(pt)) == pt)
}

@Test func groupDestinationUsesTokenKey() {
    let key = Data(repeating: 0x5A, count: 64)
    let dest = Destination(kind: .group, direction: .in, appName: "app", aspects: [],
                           identity: nil, groupKey: key)!
    let pt = Data("group secret".utf8)
    #expect(dest.decrypt(dest.encrypt(pt)) == pt)
}

@Test func plainDestinationIsPassthrough() {
    let dest = Destination(kind: .plain, direction: .out, appName: "app", aspects: [],
                           identity: nil, groupKey: nil)!
    let pt = Data("clear".utf8)
    #expect(dest.encrypt(pt) == pt)
    #expect(dest.decrypt(pt) == pt)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DestinationTests`
Expected: FAIL — `Destination` not defined.

- [ ] **Step 3: Write minimal implementation**

`Sources/ReTiCA/Destination/Destination.swift`:

```swift
import Foundation

/// A Reticulum destination: an addressable endpoint. Owns addressing (name/hash) and
/// crypto dispatch. Framing is handled separately by `Packet`.
public struct Destination {
    public enum Direction: UInt8, Equatable { case `in` = 0x11, out = 0x12 }

    public static let nameHashLength = 10 // NAME_HASH_LENGTH / 8
    public static let hashLength = 16     // TRUNCATED_HASHLENGTH / 8

    public let kind: DestinationType
    public let direction: Direction
    public let appName: String
    public let aspects: [String]
    public var identity: Identity?
    public var groupKey: Data?

    // MARK: Addressing (pure statics)

    /// Full human-readable name: `app[.aspect]*[.identityHexHash]`.
    public static func expandName(appName: String, aspects: [String],
                                  identityHexHash: String?) -> String {
        var name = appName
        for aspect in aspects { name += "." + aspect }
        if let hex = identityHexHash { name += "." + hex }
        return name
    }

    /// `SHA256(expandName(without identity))[:10]`.
    public static func nameHash(appName: String, aspects: [String]) -> Data {
        let expanded = expandName(appName: appName, aspects: aspects, identityHexHash: nil)
        return Crypto.fullHash(Data(expanded.utf8)).prefix(nameHashLength)
    }

    /// `SHA256( nameHash ‖ identityHash? )[:16]`.
    public static func hash(identityHash: Data?, appName: String, aspects: [String]) -> Data {
        var material = nameHash(appName: appName, aspects: aspects)
        if let idHash = identityHash { material.append(idHash) }
        return Crypto.fullHash(material).prefix(hashLength)
    }

    // MARK: Init

    public init?(kind: DestinationType, direction: Direction, appName: String,
                 aspects: [String], identity: Identity? = nil, groupKey: Data? = nil) {
        guard !appName.contains(".") else { return nil }
        guard !aspects.contains(where: { $0.contains(".") }) else { return nil }
        switch kind {
        case .single: guard identity != nil, groupKey == nil else { return nil }
        case .group:  guard groupKey != nil else { return nil }
        case .plain:  guard identity == nil, groupKey == nil else { return nil }
        case .link:   break
        }
        self.kind = kind
        self.direction = direction
        self.appName = appName
        self.aspects = aspects
        self.identity = identity
        self.groupKey = groupKey
    }

    // MARK: Derived addressing

    public var nameHash: Data { Destination.nameHash(appName: appName, aspects: aspects) }
    public var hash: Data {
        Destination.hash(identityHash: identity?.hash, appName: appName, aspects: aspects)
    }

    // MARK: Crypto dispatch

    public func encrypt(_ plaintext: Data, ratchet: Data? = nil) -> Data {
        switch kind {
        case .plain, .link:
            return plaintext
        case .single:
            return identity?.encrypt(plaintext, ratchet: ratchet) ?? plaintext
        case .group:
            guard let key = groupKey, let token = try? Token(key: key) else { return plaintext }
            return token.encrypt(plaintext)
        }
    }

    public func decrypt(_ ciphertext: Data, ratchets: [Data]? = nil,
                        enforceRatchets: Bool = false) -> Data? {
        switch kind {
        case .plain, .link:
            return ciphertext
        case .single:
            return identity?.decrypt(ciphertext, ratchets: ratchets, enforceRatchets: enforceRatchets)
        case .group:
            guard let key = groupKey, let token = try? Token(key: key) else { return nil }
            return try? token.decrypt(ciphertext)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DestinationTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCA/Destination/Destination.swift Tests/ReTiCATests/Destination/DestinationTests.swift
git commit -m "feat: Destination addressing and encrypt/decrypt dispatch"
```

---

### Task 4: Announce (build + validate)

**Files:**
- Create: `Sources/ReTiCA/Destination/Announce.swift`
- Test: `Tests/ReTiCATests/Destination/AnnounceTests.swift`

**Interfaces:**
- Consumes: `Identity` (publicKey/hash/sign/validate), `Crypto.fullHash`.
- Produces:
  - `struct Announce` with `struct Parsed: Equatable`
  - `static func buildPayload(identity:destinationHash:nameHash:randomHash:ratchet:appData:) -> Data`
  - `static func parse(payload:destinationHash:contextFlagSet:) -> Parsed?`
  - `static func randomHash(now: UInt64, randomPrefix: Data) -> Data`

- [ ] **Step 1: Write the failing test**

`Tests/ReTiCATests/Destination/AnnounceTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

private func announceDestHash(_ id: Identity, nameHash: Data) -> Data {
    Crypto.fullHash(nameHash + id.hash).prefix(16)
}

@Test func buildAndParseRoundTripNoRatchetNoAppData() {
    let id = Identity()
    let nameHash = Destination.nameHash(appName: "app", aspects: ["svc"])
    let destHash = announceDestHash(id, nameHash: nameHash)
    let randomHash = Announce.randomHash(now: 1_700_000_000, randomPrefix: Data(repeating: 0xAB, count: 5))
    let payload = Announce.buildPayload(identity: id, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash)
    let parsed = Announce.parse(payload: payload, destinationHash: destHash, contextFlagSet: false)
    #expect(parsed != nil)
    #expect(parsed?.publicKey == id.publicKey)
    #expect(parsed?.nameHash == nameHash)
    #expect(parsed?.randomHash == randomHash)
    #expect(parsed?.ratchet == nil)
    #expect(parsed?.appData == nil)
    #expect(parsed?.identity.hash == id.hash)
}

@Test func buildAndParseRoundTripWithRatchetAndAppData() {
    let id = Identity()
    let nameHash = Destination.nameHash(appName: "app", aspects: [])
    let destHash = announceDestHash(id, nameHash: nameHash)
    let randomHash = Announce.randomHash(now: 1, randomPrefix: Data(repeating: 0x01, count: 5))
    let ratchet = Data(repeating: 0x2C, count: 32)
    let appData = Data("hello-app".utf8)
    let payload = Announce.buildPayload(identity: id, destinationHash: destHash, nameHash: nameHash,
                                        randomHash: randomHash, ratchet: ratchet, appData: appData)
    let parsed = Announce.parse(payload: payload, destinationHash: destHash, contextFlagSet: true)
    #expect(parsed?.ratchet == ratchet)
    #expect(parsed?.appData == appData)
}

@Test func parseRejectsTamperedSignature() {
    let id = Identity()
    let nameHash = Destination.nameHash(appName: "app", aspects: [])
    let destHash = announceDestHash(id, nameHash: nameHash)
    let randomHash = Announce.randomHash(now: 5, randomPrefix: Data(repeating: 0x00, count: 5))
    var payload = Announce.buildPayload(identity: id, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash)
    payload[payload.count - 1] ^= 0xFF // corrupt the signature (last field, no app_data)
    #expect(Announce.parse(payload: payload, destinationHash: destHash, contextFlagSet: false) == nil)
}

@Test func parseRejectsDestinationHashMismatch() {
    let id = Identity()
    let nameHash = Destination.nameHash(appName: "app", aspects: [])
    let destHash = announceDestHash(id, nameHash: nameHash)
    let randomHash = Announce.randomHash(now: 5, randomPrefix: Data(repeating: 0x00, count: 5))
    let payload = Announce.buildPayload(identity: id, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash)
    let wrongHash = Data(repeating: 0xEE, count: 16)
    #expect(Announce.parse(payload: payload, destinationHash: wrongHash, contextFlagSet: false) == nil)
}

@Test func randomHashIsPrefixPlusBigEndianTime() {
    let rh = Announce.randomHash(now: 0x0102030405, randomPrefix: Data([1, 2, 3, 4, 5, 6, 7]))
    #expect(rh.count == 10)
    #expect(rh.prefix(5) == Data([1, 2, 3, 4, 5]))              // prefix truncated to 5
    #expect(rh.suffix(5) == Data([0x01, 0x02, 0x03, 0x04, 0x05])) // 5-byte big-endian time
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AnnounceTests`
Expected: FAIL — `Announce` not defined.

- [ ] **Step 3: Write minimal implementation**

`Sources/ReTiCA/Destination/Announce.swift`:

```swift
import Foundation

/// Reticulum announce payload construction and validation. Only the pure parse/verify
/// logic lives here; the "remember" side effects (known-destination and ratchet tables)
/// belong to the Transport layer.
public struct Announce {
    static let keySize = 64        // Identity.keySize
    static let nameHashLength = 10 // NAME_HASH_LENGTH / 8
    static let randomHashLength = 10
    static let ratchetSize = 32    // RATCHETSIZE / 8
    static let signatureLength = 64

    public struct Parsed: Equatable {
        public let identity: Identity
        public let publicKey: Data
        public let nameHash: Data
        public let randomHash: Data
        public let ratchet: Data?
        public let signature: Data
        public let appData: Data?
    }

    /// Build a signed announce payload for a SINGLE destination.
    public static func buildPayload(identity: Identity, destinationHash: Data, nameHash: Data,
                                    randomHash: Data, ratchet: Data? = nil,
                                    appData: Data? = nil) -> Data {
        let publicKey = identity.publicKey
        let ratchetBytes = ratchet ?? Data()
        var signedData = destinationHash + publicKey + nameHash + randomHash + ratchetBytes
        if let appData { signedData += appData }
        let signature = identity.sign(signedData)
        var payload = publicKey + nameHash + randomHash + ratchetBytes + signature
        if let appData { payload += appData }
        return payload
    }

    /// Parse and validate an announce payload against an expected destination hash.
    /// Returns nil on invalid signature or destination-hash mismatch.
    public static func parse(payload rawPayload: Data, destinationHash: Data,
                             contextFlagSet: Bool) -> Parsed? {
        let payload = Data(rawPayload)
        let ratchetLen = contextFlagSet ? ratchetSize : 0
        let minLen = keySize + nameHashLength + randomHashLength + ratchetLen + signatureLength
        guard payload.count >= minLen else { return nil }

        var idx = 0
        let publicKey = payload.subdata(in: idx..<idx + keySize); idx += keySize
        let nameHash = payload.subdata(in: idx..<idx + nameHashLength); idx += nameHashLength
        let randomHash = payload.subdata(in: idx..<idx + randomHashLength); idx += randomHashLength
        var ratchet: Data? = nil
        if contextFlagSet {
            ratchet = payload.subdata(in: idx..<idx + ratchetSize); idx += ratchetSize
        }
        let signature = payload.subdata(in: idx..<idx + signatureLength); idx += signatureLength
        let appData: Data? = idx < payload.count ? payload.subdata(in: idx..<payload.count) : nil

        guard let identity = Identity(publicKey: publicKey) else { return nil }
        var signedData = destinationHash + publicKey + nameHash + randomHash + (ratchet ?? Data())
        if let appData { signedData += appData }
        guard identity.validate(signature: signature, message: signedData) else { return nil }

        let expectedHash = Crypto.fullHash(nameHash + identity.hash).prefix(16)
        guard destinationHash == Data(expectedHash) else { return nil }

        return Parsed(identity: identity, publicKey: publicKey, nameHash: nameHash,
                      randomHash: randomHash, ratchet: ratchet, signature: signature, appData: appData)
    }

    /// `randomPrefix[:5] ‖ now.bigEndian(5 bytes)` — matches RNS random_hash construction.
    public static func randomHash(now: UInt64, randomPrefix: Data) -> Data {
        var result = Data(randomPrefix.prefix(5))
        for shift in stride(from: 32, through: 0, by: -8) {
            result.append(UInt8((now >> UInt64(shift)) & 0xFF))
        }
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AnnounceTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCA/Destination/Announce.swift Tests/ReTiCATests/Destination/AnnounceTests.swift
git commit -m "feat: Announce payload build and validation"
```

---

### Task 5: Composers (Packet.data / Packet.announce)

**Files:**
- Modify: `Sources/ReTiCA/Packet/Packet.swift` (add composer statics)
- Test: `Tests/ReTiCATests/Packet/PacketTests.swift` (append)

**Interfaces:**
- Consumes: `Destination` (hash/kind/encrypt).
- Produces:
  - `Packet.data(to: Destination, plaintext: Data, ratchet: Data? = nil, context: PacketContext = .none) -> Packet`
  - `Packet.announce(from: Destination, payload: Data, pathResponse: Bool = false, ratchetPresent: Bool = false) -> Packet`

- [ ] **Step 1: Write the failing test**

Append to `Tests/ReTiCATests/Packet/PacketTests.swift`:

```swift
@Test func dataComposerEncryptsAndFrames() throws {
    let id = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: id, groupKey: nil)!
    let plaintext = Data("composed".utf8)
    let packet = Packet.data(to: dest, plaintext: plaintext)
    #expect(packet.packetType == .data)
    #expect(packet.destinationType == .single)
    #expect(packet.destinationHash == dest.hash)
    #expect(packet.headerType == .header1)
    // payload is ciphertext, not plaintext
    #expect(packet.payload != plaintext)
    #expect(dest.decrypt(packet.payload) == plaintext)
    _ = try packet.packed() // frames within MTU
}

@Test func announceComposerSetsTypeAndRatchetFlag() {
    let id = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: [],
                           identity: id, groupKey: nil)!
    let payload = Data("announce-bytes".utf8)
    let plain = Packet.announce(from: dest, payload: payload)
    #expect(plain.packetType == .announce)
    #expect(plain.context == .none)
    #expect(plain.contextFlag == false)
    #expect(plain.payload == payload)

    let withRatchet = Packet.announce(from: dest, payload: payload,
                                      pathResponse: true, ratchetPresent: true)
    #expect(withRatchet.context == .pathResponse)
    #expect(withRatchet.contextFlag == true)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PacketTests`
Expected: FAIL — `Packet.data`/`Packet.announce` not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/ReTiCA/Packet/Packet.swift` inside an `extension Packet`:

```swift
extension Packet {
    /// Compose an encrypted DATA packet to a destination (HEADER_1, BROADCAST).
    public static func data(to destination: Destination, plaintext: Data,
                            ratchet: Data? = nil, context: PacketContext = .none) -> Packet {
        Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
               destinationType: destination.kind, context: context, contextFlag: false, hops: 0,
               destinationHash: destination.hash, transportId: nil,
               payload: destination.encrypt(plaintext, ratchet: ratchet))
    }

    /// Compose an ANNOUNCE packet from a destination (HEADER_1, BROADCAST). The announce
    /// payload is built separately via `Announce.buildPayload`.
    public static func announce(from destination: Destination, payload: Data,
                                pathResponse: Bool = false, ratchetPresent: Bool = false) -> Packet {
        Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
               destinationType: destination.kind,
               context: pathResponse ? .pathResponse : .none, contextFlag: ratchetPresent, hops: 0,
               destinationHash: destination.hash, transportId: nil, payload: payload)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PacketTests`
Expected: PASS (9 tests total in file).

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCA/Packet/Packet.swift Tests/ReTiCATests/Packet/PacketTests.swift
git commit -m "feat: packet composers for data and announce"
```

---

### Task 6: Python-RNS cross-validation fixtures

**Files:**
- Modify: `Tests/ReTiCATests/Vectors/generate_fixtures.py`
- Modify: `Tests/ReTiCATests/Vectors/fixtures.json` (regenerated in the RNS env)
- Modify: `Tests/ReTiCATests/Vectors/VectorFixtures.swift` (add fields)
- Create: `Tests/ReTiCATests/Vectors/PacketDestinationCrossValidationTests.swift`

**Interfaces:**
- Consumes: `Packet`, `Destination`, `Announce`, `Identity`, `Token`, `Data(hexString:)`.
- Produces: extended `VectorFixtures` with the new fields below.

New fixture fields (all byte fields lowercase hex; the announce/single fields reuse the
existing `identity_private_key`/`identity_public_key`):

```
plain_app_name (string), plain_aspect (string),
plain_dest_hash, plain_packet_plaintext, plain_packet_raw, plain_packet_hash,
single_app_name (string), single_aspect (string), single_dest_hash,
announce_app_name (string), announce_aspect (string),
announce_dest_hash, announce_payload, announce_context_flag (bool)
```

- [ ] **Step 1: Extend the generator**

Append to `Tests/ReTiCATests/Vectors/generate_fixtures.py`, before the final `print(json.dumps(...))`, and add the new keys to the dict. Replace the existing `print(json.dumps({...}, indent=2))` block with one that includes both the original 10 fields and these additions:

```python
import struct  # add near the top imports if not present

# --- Packet + Destination vectors ---

# PLAIN packet (deterministic: PLAIN encryption is passthrough). OUT direction is
# headless-safe (register_destination only touches Transport.owner for IN destinations).
plain_app, plain_aspect = "reticula", "plain"
plain_dest = RNS.Destination(None, RNS.Destination.OUT, RNS.Destination.PLAIN, plain_app, plain_aspect)
plain_plaintext = b"plain packet payload"
plain_packet = RNS.Packet(plain_dest, plain_plaintext, RNS.Packet.DATA)
plain_packet.pack()
plain_packet_raw = plain_packet.raw
plain_packet_hash = plain_packet.get_hash()

# SINGLE destination hash for the fixture identity (static, headless-safe).
single_app, single_aspect = "reticula", "single"
single_dest_hash = RNS.Destination.hash(identity, single_app, single_aspect)

# Announce payload, built from authoritative statics (avoids creating an IN destination,
# which would require a running Transport). Mirrors Destination.announce exactly.
ann_app, ann_aspect = "reticula", "announce"
ann_name_hash = RNS.Identity.full_hash(
    RNS.Destination.expand_name(None, ann_app, ann_aspect).encode("utf-8")
)[:RNS.Identity.NAME_HASH_LENGTH // 8]
ann_random_hash = RNS.Identity.get_random_hash()[:5] + int(time.time()).to_bytes(5, "big")
ann_dest_hash = RNS.Destination.hash(identity, ann_app, ann_aspect)
ann_ratchet = b""
ann_signed = ann_dest_hash + identity.get_public_key() + ann_name_hash + ann_random_hash + ann_ratchet
ann_signature = identity.sign(ann_signed)
ann_payload = identity.get_public_key() + ann_name_hash + ann_random_hash + ann_ratchet + ann_signature
```

Then extend the printed dict with:

```python
    "plain_app_name": plain_app,
    "plain_aspect": plain_aspect,
    "plain_dest_hash": plain_dest.hash.hex(),
    "plain_packet_plaintext": plain_plaintext.hex(),
    "plain_packet_raw": plain_packet_raw.hex(),
    "plain_packet_hash": plain_packet_hash.hex(),
    "single_app_name": single_app,
    "single_aspect": single_aspect,
    "single_dest_hash": single_dest_hash.hex(),
    "announce_app_name": ann_app,
    "announce_aspect": ann_aspect,
    "announce_dest_hash": ann_dest_hash.hex(),
    "announce_payload": ann_payload.hex(),
    "announce_context_flag": False,
```

- [ ] **Step 2: Regenerate fixtures in the RNS env (user action)**

Run (conda `rns` env, real terminal — see project RNS notes, use `python` not `python3`):
`python Tests/ReTiCATests/Vectors/generate_fixtures.py > Tests/ReTiCATests/Vectors/fixtures.json`
Expected: `fixtures.json` now has the original 10 fields plus the 14 new ones, all populated. If any line errors, STOP and report the traceback (do not fabricate fixture values).

- [ ] **Step 3: Extend the Swift decoder**

Add these properties + CodingKeys to `Tests/ReTiCATests/Vectors/VectorFixtures.swift` (keep the existing fields):

```swift
    let plainAppName: String
    let plainAspect: String
    let plainDestHash: String
    let plainPacketPlaintext: String
    let plainPacketRaw: String
    let plainPacketHash: String
    let singleAppName: String
    let singleAspect: String
    let singleDestHash: String
    let announceAppName: String
    let announceAspect: String
    let announceDestHash: String
    let announcePayload: String
    let announceContextFlag: Bool
```

CodingKeys additions:

```swift
        case plainAppName = "plain_app_name"
        case plainAspect = "plain_aspect"
        case plainDestHash = "plain_dest_hash"
        case plainPacketPlaintext = "plain_packet_plaintext"
        case plainPacketRaw = "plain_packet_raw"
        case plainPacketHash = "plain_packet_hash"
        case singleAppName = "single_app_name"
        case singleAspect = "single_aspect"
        case singleDestHash = "single_dest_hash"
        case announceAppName = "announce_app_name"
        case announceAspect = "announce_aspect"
        case announceDestHash = "announce_dest_hash"
        case announcePayload = "announce_payload"
        case announceContextFlag = "announce_context_flag"
```

- [ ] **Step 4: Write the failing cross-validation tests**

`Tests/ReTiCATests/Vectors/PacketDestinationCrossValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func swiftUnpacksReferencePlainPacket() throws {
    let f = try VectorFixtures.load()
    let raw = Data(hexString: f.plainPacketRaw)!
    let packet = try #require(Packet(raw: raw))
    #expect(packet.packetType == .data)
    #expect(packet.destinationType == .plain)
    #expect(packet.headerType == .header1)
    #expect(packet.destinationHash == Data(hexString: f.plainDestHash))
    #expect(packet.payload == Data(hexString: f.plainPacketPlaintext))
}

@Test func swiftPacksToReferencePlainPacketBytes() throws {
    let f = try VectorFixtures.load()
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                        destinationHash: Data(hexString: f.plainDestHash)!, transportId: nil,
                        payload: Data(hexString: f.plainPacketPlaintext)!)
    #expect(try packet.packed() == Data(hexString: f.plainPacketRaw))
}

@Test func swiftPacketHashMatchesReference() throws {
    let f = try VectorFixtures.load()
    let packet = try #require(Packet(raw: Data(hexString: f.plainPacketRaw)!))
    #expect(packet.packetHash == Data(hexString: f.plainPacketHash))
}

@Test func swiftDestinationHashMatchesReferenceSingle() throws {
    let f = try VectorFixtures.load()
    let id = Identity(publicKey: Data(hexString: f.identityPublicKey)!)!
    let hash = Destination.hash(identityHash: id.hash, appName: f.singleAppName,
                                aspects: [f.singleAspect])
    #expect(hash == Data(hexString: f.singleDestHash))
}

@Test func swiftDestinationHashMatchesReferencePlain() throws {
    let f = try VectorFixtures.load()
    let hash = Destination.hash(identityHash: nil, appName: f.plainAppName, aspects: [f.plainAspect])
    #expect(hash == Data(hexString: f.plainDestHash))
}

@Test func swiftValidatesReferenceAnnounce() throws {
    let f = try VectorFixtures.load()
    let parsed = Announce.parse(payload: Data(hexString: f.announcePayload)!,
                                destinationHash: Data(hexString: f.announceDestHash)!,
                                contextFlagSet: f.announceContextFlag)
    let unwrapped = try #require(parsed)
    #expect(unwrapped.publicKey == Data(hexString: f.identityPublicKey))
    #expect(unwrapped.nameHash == Destination.nameHash(appName: f.announceAppName,
                                                       aspects: [f.announceAspect]))
}

@Test func swiftGroupDestinationDecryptsReferenceToken() throws {
    let f = try VectorFixtures.load()
    let dest = Destination(kind: .group, direction: .in, appName: "g", aspects: [],
                           identity: nil, groupKey: Data(hexString: f.tokenKey)!)!
    #expect(dest.decrypt(Data(hexString: f.tokenCiphertext)!) == Data(hexString: f.tokenPlaintext))
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter CrossValidation`
Expected: PASS — the 4 sub-project-#1 cross-validation tests plus these 7 new ones.

- [ ] **Step 6: Commit**

```bash
git add Tests/ReTiCATests/Vectors
git commit -m "test: Packet/Destination/Announce cross-validation vs Python-RNS"
```

---

### Task 7: Full suite + mutation gate + README

**Files:** `README.md` (modify); no new source.

- [ ] **Step 1: Run the full suite**

Run: `swift test`
Expected: PASS — all sub-project #1 and #2 tests together (pristine output).

- [ ] **Step 2: Mutation sweep (project convention)**

Batch-mutate one production line per new unit, run `swift test` once, confirm the covering tests fail, then revert all and confirm green. Suggested mutations:
- `Packet.flags`: change `headerType.rawValue << 6` to `<< 5` (breaks flags round-trip + cross-validation pack).
- `Packet.init?(raw:)`: change the HEADER_2 branch offset `idx += dstLen` to `idx += 0` (breaks header2 round-trip).
- `Packet.hashablePart`: change `destinationType.rawValue << 2` to `<< 3` (breaks packet hash + stability + cross-validation).
- `Destination.hash`: append identity hash BEFORE nameHash instead of after (breaks dest-hash cross-validation).
- `Announce.buildPayload`: drop `nameHash` from `signedData` (breaks announce round-trip + cross-validation).
- `Announce.randomHash`: use `through: 8` instead of `through: 0` (wrong byte count — breaks the big-endian-time test).

Confirm each corresponding test fails; if any mutation is not caught, add a covering test. Revert all; confirm green. Commit nothing with mutations.

- [ ] **Step 3: Update the README**

Update the "Sub-project #1" framing and add a Packet/Destination section. In `README.md`, change the architecture/deliverable text to note sub-project #2 is complete, and add a table row set:

```markdown
## Sub-project #2: Packet + Destination

| Module | What it implements |
|--------|--------------------|
| `Packet` | Byte-exact Reticulum packet framing (flags, HEADER_1/HEADER_2, pack/unpack) and the transport-stable packet hash |
| `PacketContext` / `PacketType` / `HeaderType` / `TransportType` / `DestinationType` | Wire constants |
| `Destination` | Addressing (`expandName`/`nameHash`/`hash`) and encrypt/decrypt dispatch for SINGLE/GROUP/PLAIN |
| `Announce` | Signed announce payload build + signature/hash validation |

Framing is separated from crypto: `Packet` is pure framing over opaque payload bytes; `Destination` owns encryption; `Packet.data`/`Packet.announce` compose them. Wire compatibility is verified against Python-RNS 1.3.8 fixtures (packet bytes, packet hash, destination hash, announce validation).
```

Also update the "Not Yet Implemented" section to remove Packet/Destination/Announce and keep Transport, Link establishment, and Resource delivery.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document Packet + Destination sub-project"
```

---

## Self-Review

**Spec coverage:**
- Packet framing (flags, HEADER_1/2, pack/unpack, MTU, malformed) → Task 1.
- Packet hash (masked hashable part, stability) → Task 2.
- Destination addressing (expandName/nameHash/hash) + SINGLE/GROUP/PLAIN encrypt/decrypt dispatch → Task 3.
- Announce build + parse/validate + randomHash seam → Task 4.
- Composers (`Packet.data`/`Packet.announce`) → Task 5.
- Cross-validation vs Python-RNS (PLAIN packet bytes + hash, destination hash, announce validation, GROUP decrypt) → Task 6.
- Full-suite + mutation gate + README → Task 7.
- Constants (MTU/addressLength/maxHops/nameHashLength/hashLength, all enums) → Tasks 1, 3, 4.
- Determinism seams (announce randomHash) → Task 4. PLAIN-based byte-exact determinism → Task 6.
- Deferred items (Transport/send/receipts/ratchet lifecycle/links/LINK session/TCA) → not built, per scope.

**Placeholder scan:** No TBD/TODO; every code step has complete code; every command has expected output. The `PacketContext` full set is enumerated in Task 1.

**Type consistency:** `DestinationType` defined in Task 1 and reused as `Destination.kind` (Task 3) and by composers (Task 5); `Packet` init signature identical across Tasks 1/2/5/6; `Destination.hash(identityHash:appName:aspects:)`, `Destination.nameHash(appName:aspects:)`, `Announce.buildPayload(...)`, `Announce.parse(...)`, `Announce.randomHash(now:randomPrefix:)` used identically in tests and cross-validation; `Data(hexString:)`/`.hexString` and `Identity(publicKey:)` reused from sub-project #1; `Crypto.fullHash`/`truncatedHash` reused.

**Decision recorded:** framing separated from crypto (Packet opaque payload; Destination crypto; composers wire them). GROUP allows an optional addressing identity; SINGLE requires identity; PLAIN forbids keys. Announce "remember" side effects and ratchet lifecycle remain deferred to Transport (#4).
