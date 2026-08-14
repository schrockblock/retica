import Testing
import Foundation
@testable import ReTiCA

/// Byte-cross-validation of the signed-integer / float32 / map32 decoder against genuine
/// `RNS/vendor/umsgpack.py` output — the very codec RNS and LXMF pack with.
///
/// The question these vectors settle is not "does it decode" but **"does it re-encode to the same
/// bytes"**. `LXMessage.validateSignature` (LXMessage.swift:119) rebuilds the packed payload from
/// the decoded fields on every inbound message, so any width the encoder gets wrong turns a valid
/// signature invalid. Reference `_pack_integer` (umsgpack.py:288-314) chooses the encoding purely
/// from the value, narrowest first — so a value-canonical encoder reproduces it exactly, and these
/// vectors are the proof rather than the assertion.

private func expectedValue(forDecimal s: String) -> MsgPackValue? {
    if s.hasPrefix("-") { return Int64(s).map { MsgPackValue.int($0) } }
    return UInt64(s).map { MsgPackValue.uint($0) }
}

@Test func msgPackIntegerBoundariesMatchReferenceUmsgpack() throws {
    let f = try MsgPackSignedFixtures.load()
    #expect(f.integers.count == 27)
    for v in f.integers {
        let wire = try #require(Data(hexString: v.packed), "fixture hex for \(v.value)")
        let expected = try #require(expectedValue(forDecimal: v.value), "fixture value \(v.value)")

        // Decode: reference bytes -> our value.
        #expect(MsgPack.decodeValue(wire) == expected, "decoding \(v.value) (\(v.packed))")
        // Encode: our value -> reference bytes. This is the half that keeps signatures valid.
        #expect(MsgPack.encode(expected) == wire, "encoding \(v.value)")
    }
}

/// Every one of the 27 boundaries survives decode → encode with its bytes intact. Stated
/// separately from the value assertions above because byte-identical round-trip is the property
/// the LXMF signature depends on, and it deserves to fail by name.
@Test func msgPackIntegerBoundariesRoundTripByteIdentically() throws {
    let f = try MsgPackSignedFixtures.load()
    for v in f.integers {
        let wire = try #require(Data(hexString: v.packed))
        let decoded = try #require(MsgPack.decodeValue(wire), "decoding \(v.value)")
        #expect(MsgPack.encode(decoded) == wire, "round-tripping \(v.value)")
    }
}

/// `_pack_float` (umsgpack.py:325-333) picks its width from the module global `_float_precision`,
/// which `umsgpack.py:1177-1181` sets to `"double"` whenever `sys.float_info.mant_dig == 53` — i.e.
/// on every mainstream CPython. Reference therefore never emits float32 on its own; the fixture
/// forces it. Because the width is NOT recoverable from the value, `.float` has to be a case of its
/// own: folding float32 into `.double` would re-encode 5 bytes as 9 and invalidate the signature.
@Test func msgPackFloatWidthsMatchReferenceUmsgpack() throws {
    let f = try MsgPackSignedFixtures.load()
    #expect(f.floats.count == 6)
    for v in f.floats {
        let value = try #require(Double(v.value), "fixture float \(v.value)")
        let single = try #require(Data(hexString: v.packedSingle))
        let double = try #require(Data(hexString: v.packedDouble))

        #expect(MsgPack.decodeValue(single) == .float(Float(value)), "float32 \(v.value)")
        #expect(MsgPack.decodeValue(double) == .double(value), "float64 \(v.value)")
        #expect(MsgPack.encode(.float(Float(value))) == single, "float32 encode \(v.value)")
        #expect(MsgPack.encode(.double(value)) == double, "float64 encode \(v.value)")
        #expect(single.count == 5 && double.count == 9)
    }
}

/// A 65536-entry map is the smallest reference emits with a `0xDF` header. Compared by SHA-256 of
/// the whole byte stream rather than half a megabyte of fixture hex — still a byte-compare.
///
/// This is also the regression guard for the trap the map32 work had to avoid creating: the
/// allowlist blessed `UInt16(n)` in the map encoders solely because the decoder had no `0xDF`
/// branch, so no decoded map could exceed 65535 pairs. Decode without encode would have made that
/// a remote abort.
@Test func msgPackMap32MatchesReferenceUmsgpack() throws {
    let f = try MsgPackSignedFixtures.load()
    let pairs = (0..<f.map32EntryCount).map { MsgPackValue.IntPair($0, .uint(UInt64($0))) }
    let encoded = MsgPack.encode(.intMap(pairs))

    #expect(encoded.count == f.map32PackedLength)
    #expect(encoded.prefix(16).hexString == f.map32PackedPrefix)
    #expect(Crypto.fullHash(encoded).hexString == f.map32PackedSha256)
    // Decoding bytes just proven byte-identical to reference's closes the loop.
    #expect(MsgPack.decodeValue(encoded) == .intMap(pairs))
}

/// A map32 header declaring a single pair. Non-canonical — reference would use a fixmap — but
/// legal, and `umsgpack.unpackb` accepts it (asserted in the generator). The decoder must honour
/// the declared count rather than assuming a `0xDF` map is large.
@Test func msgPackSmallMap32FromReferenceDecodes() throws {
    let f = try MsgPackSignedFixtures.load()
    let wire = try #require(Data(hexString: f.smallMap32Packed))
    #expect(MsgPack.decodeValue(wire) == .intMap([.init(1, .int(-1))]))
}

// MARK: - The behaviour that motivated all of it

private func referenceFields(_ f: LXMFSignedFixtures) -> [MsgPackValue.IntPair] {
    [
        .init(0x02, .array(f.telemetry.map { .int(Int64($0)!) })),   // FIELD_TELEMETRY
        .init(0x0F, .uint(UInt64(f.renderer))),                      // FIELD_RENDERER
    ]
}

/// The Tier 1 defect, end to end: a genuine lxmf 1.1.0 message whose `fields` carry negative
/// integers across every signed width. Before this change `MsgPack.parse` hit `default: return nil`
/// on the first `0xD0`/`0xFF` tag, `LXMessage.unpack` returned nil, and `LXMFRouter.received`
/// dropped the message whole — content and all — with no error to the sender.
///
/// `validateSignature` is the assertion that matters: it re-packs the payload from the decoded
/// fields and checks the result against the signature the reference produced over ITS packing. It
/// can only pass if every negative integer re-encoded to the identical width.
@Test func negativeFieldsMessageFromReferenceUnpacksAndValidates() throws {
    let f = try LXMFSignedFixtures.load()
    let privateKey = try #require(Data(hexString: f.sourcePrivateKey))
    let source = try #require(Identity(privateKey: privateKey))
    let refPacked = try #require(Data(hexString: f.packed))

    let unpacked = LXMessage.unpack(refPacked)
    #expect(unpacked != nil)
    if let unpacked {
        #expect(unpacked.fields == referenceFields(f))
        #expect(unpacked.content == Data(hexString: f.content))
        #expect(unpacked.title == Data(hexString: f.title))
        #expect(unpacked.hash == Data(hexString: f.hash))
        #expect(unpacked.validateSignature(source: source) == true)
        // The whole packed form must reproduce byte for byte, signature region included: `packed`
        // re-encodes the payload, and this message is what a propagation node would re-transmit.
        #expect(unpacked.packed == refPacked)
    }
}

/// The same message built from scratch by us must produce reference's payload bytes and message
/// hash. The signature is hedged/randomized on macOS 26+, so it is validated, not byte-compared.
@Test func negativeFieldsMessageWeBuildMatchesReferenceBytes() throws {
    let f = try LXMFSignedFixtures.load()
    let privateKey = try #require(Data(hexString: f.sourcePrivateKey))
    let source = try #require(Identity(privateKey: privateKey))
    let refPacked = try #require(Data(hexString: f.packed))
    let destinationHash = try #require(Data(hexString: f.destinationHash))
    let title = try #require(Data(hexString: f.title))
    let content = try #require(Data(hexString: f.content))

    let msg = LXMessage.create(source: source, destinationHash: destinationHash,
                               timestamp: f.timestamp, title: title, content: content,
                               fields: referenceFields(f))
    #expect(msg.hash == Data(hexString: f.hash))                              // hash byte-parity
    #expect(Data(msg.packed.dropFirst(96)) == Data(refPacked.dropFirst(96)))  // payload byte-parity
    #expect(msg.validateSignature(source: source) == true)
}

/// Round-trip through our own stack, so the guarantee does not depend on the fixture being present.
@Test func negativeFieldsSurviveOurOwnPackUnpackAndSignature() throws {
    let source = Identity()
    let fields: [MsgPackValue.IntPair] = [
        .init(0x02, .array([.int(-1), .int(-33), .int(-129), .int(-32769), .int(-2147483649), .int(Int64.min)])),
        .init(0x0F, .uint(0)),
    ]
    let msg = LXMessage.create(source: source,
                               destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("c".utf8),
                               fields: fields)
    let unpacked = LXMessage.unpack(msg.packed)
    #expect(unpacked != nil)
    if let unpacked {
        #expect(unpacked.fields == fields)
        #expect(unpacked.hash == msg.hash)
        #expect(unpacked.validateSignature(source: source) == true)
        #expect(unpacked.packed == msg.packed)
    }
}
