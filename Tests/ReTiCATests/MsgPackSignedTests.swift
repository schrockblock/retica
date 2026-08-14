import Testing
import Foundation
@testable import ReTiCA

// MARK: - Tier 1 data loss: the types reference emits but the decoder rejected
//
// `MsgPack.parse` handled positive fixint, uint8/16/32/64, float64, bin, str, fixmap/map16,
// fixarray/array16/32, nil and bool — and nothing else. Everything else fell to `default: return nil`,
// which `LXMessage.unpack` turns into a nil message and `LXMFRouter.received` turns into a silent
// drop. A Sideband/NomadNet message with one negative integer in `fields` (routine for
// FIELD_TELEMETRY coordinates) was discarded whole, content and all, with no error to the sender.
//
// These are the unit branches. The behaviour that actually matters — a real LXMessage carrying
// negative fields round-tripping with a still-valid signature — is in
// Vectors/MsgPackSignedCrossValidationTests.swift, against genuine reference bytes.

// MARK: Negative fixint (0xE0-0xFF)

@Test func msgPackNegativeFixintDecodes() {
    #expect(MsgPack.decodeValue(Data([0xFF])) == .int(-1))
    #expect(MsgPack.decodeValue(Data([0xE1])) == .int(-31))
    #expect(MsgPack.decodeValue(Data([0xE0])) == .int(-32))
}

// MARK: int8 / int16 / int32 / int64 (0xD0-0xD3)

@Test func msgPackInt8Decodes() {
    #expect(MsgPack.decodeValue(Data([0xD0, 0xDF])) == .int(-33))     // one past negative fixint
    #expect(MsgPack.decodeValue(Data([0xD0, 0x80])) == .int(-128))    // Int8.min
    #expect(MsgPack.decodeValue(Data([0xD0, 0x7F])) == .int(127))     // non-canonical but legal
}

@Test func msgPackInt16Decodes() {
    #expect(MsgPack.decodeValue(Data([0xD1, 0xFF, 0x7F])) == .int(-129))       // one past int8
    #expect(MsgPack.decodeValue(Data([0xD1, 0x80, 0x00])) == .int(-32768))     // Int16.min
    #expect(MsgPack.decodeValue(Data([0xD1, 0x7F, 0xFF])) == .int(32767))      // Int16.max
}

@Test func msgPackInt32Decodes() {
    #expect(MsgPack.decodeValue(Data([0xD2, 0xFF, 0xFF, 0x7F, 0xFF])) == .int(-32769))          // one past int16
    #expect(MsgPack.decodeValue(Data([0xD2, 0x80, 0x00, 0x00, 0x00])) == .int(-2147483648))     // Int32.min
    #expect(MsgPack.decodeValue(Data([0xD2, 0x7F, 0xFF, 0xFF, 0xFF])) == .int(2147483647))      // Int32.max
}

@Test func msgPackInt64Decodes() {
    // one past int32
    #expect(MsgPack.decodeValue(Data([0xD3, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF])) == .int(-2147483649))
    // Int64.min — the value that has no positive counterpart, so the sign-extension must not
    // route through negation anywhere.
    #expect(MsgPack.decodeValue(Data([0xD3, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])) == .int(Int64.min))
    // Int64.max
    #expect(MsgPack.decodeValue(Data([0xD3, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])) == .int(Int64.max))
}

@Test func msgPackTruncatedSignedIntsAreRejected() {
    #expect(MsgPack.decodeValue(Data([0xD0])) == nil)
    #expect(MsgPack.decodeValue(Data([0xD1, 0x00])) == nil)
    #expect(MsgPack.decodeValue(Data([0xD2, 0x00, 0x00, 0x00])) == nil)
    #expect(MsgPack.decodeValue(Data([0xD3, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])) == nil)
}

// MARK: Encode — the other half of the coupling

/// `LXMessage.validateSignature` re-encodes `fields` on every inbound message, so decode support
/// without encode support would merely move the failure. Every value the decoder can produce must
/// re-encode, and to the reference's narrowest form.
@Test func msgPackSignedIntsEncodeToTheNarrowestForm() {
    #expect(Array(MsgPack.encode(.int(-1))) == [0xFF])
    #expect(Array(MsgPack.encode(.int(-32))) == [0xE0])
    #expect(Array(MsgPack.encode(.int(-33))) == [0xD0, 0xDF])
    #expect(Array(MsgPack.encode(.int(-128))) == [0xD0, 0x80])
    #expect(Array(MsgPack.encode(.int(-129))) == [0xD1, 0xFF, 0x7F])
    #expect(Array(MsgPack.encode(.int(-32768))) == [0xD1, 0x80, 0x00])
    #expect(Array(MsgPack.encode(.int(-32769))) == [0xD2, 0xFF, 0xFF, 0x7F, 0xFF])
    #expect(Array(MsgPack.encode(.int(-2147483648))) == [0xD2, 0x80, 0x00, 0x00, 0x00])
    #expect(Array(MsgPack.encode(.int(-2147483649))) == [0xD3, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF])
    #expect(Array(MsgPack.encode(.int(Int64.min))) == [0xD3, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
}

/// `_pack_integer` (umsgpack.py:288-314) dispatches on the SIGN first, so a non-negative value in a
/// signed slot packs as an unsigned. `.int(5)` and `.uint(5)` must therefore emit the same byte —
/// mirroring Python, where both are just `int`.
@Test func msgPackNonNegativeSignedIntEncodesAsUnsigned() {
    #expect(Array(MsgPack.encode(.int(0))) == [0x00])
    #expect(Array(MsgPack.encode(.int(127))) == [0x7F])
    #expect(Array(MsgPack.encode(.int(128))) == [0xCC, 0x80])
    #expect(Array(MsgPack.encode(.int(Int64.max))) == [0xCF, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    #expect(MsgPack.encode(.int(5)) == MsgPack.encode(.uint(5)))
}

// MARK: float32 (0xCA)

@Test func msgPackFloat32Decodes() {
    #expect(MsgPack.decodeValue(Data([0xCA, 0x3F, 0x80, 0x00, 0x00])) == .float(1.0))
    #expect(MsgPack.decodeValue(Data([0xCA, 0xBF, 0x80, 0x00, 0x00])) == .float(-1.0))
    #expect(MsgPack.decodeValue(Data([0xCA, 0x00, 0x00, 0x00, 0x00])) == .float(0.0))
    #expect(MsgPack.decodeValue(Data([0xCA, 0x3F, 0x80, 0x00])) == nil)      // truncated
}

/// float32 is the one type whose wire width is NOT recoverable from the value: `_pack_float`
/// (umsgpack.py:325-333) reads a module global, not the value. So `.float` must stay distinct from
/// `.double` or a re-encode would widen 5 bytes to 9 and break the signature.
@Test func msgPackFloat32StaysFiveBytesThroughARoundTrip() {
    let wire = Data([0xCA, 0xC0, 0x20, 0x00, 0x00])          // -2.5 as float32
    let decoded = MsgPack.decodeValue(wire)
    #expect(decoded != nil)
    if let decoded {
        #expect(decoded == .float(-2.5))
        #expect(MsgPack.encode(decoded) == wire)
        #expect(MsgPack.encode(decoded) != MsgPack.encode(.double(-2.5)))
    }
}

@Test func msgPackFloat64StillDecodesToDouble() {
    // Regression: float64 must not be rerouted through the new .float case.
    #expect(MsgPack.decodeValue(Data([0xCB, 0xBF, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])) == .double(-1.0))
}

// MARK: map32 (0xDF)

@Test func msgPackMap32Decodes() {
    // map32 declaring one pair: 0xDF 00 00 00 01 ‖ fixint 1 ‖ negative fixint -1
    #expect(MsgPack.decodeValue(Data([0xDF, 0x00, 0x00, 0x00, 0x01, 0x01, 0xFF])) == .intMap([.init(1, .int(-1))]))
    // string-keyed map32
    #expect(MsgPack.decodeValue(Data([0xDF, 0x00, 0x00, 0x00, 0x01, 0xA1, 0x6B, 0x07])) == .map([.init("k", .uint(7))]))
    // empty map32
    #expect(MsgPack.decodeValue(Data([0xDF, 0x00, 0x00, 0x00, 0x00])) == .map([]))
    // truncated header
    #expect(MsgPack.decodeValue(Data([0xDF, 0x00, 0x00, 0x00])) == nil)
    // declared count exceeds the buffer — must fail cleanly, not spin or over-allocate
    #expect(MsgPack.decodeValue(Data([0xDF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x01])) == nil)
}

/// The reason map32 decode could not land alone. `Scripts/wire-narrowing-allowlist.txt` blessed
/// `UInt16(n)` in the map encoders as host-only, its recorded justification being *"Not reachable
/// from the wire: the DECODER has no map32 (0xDF) branch either, so a decoded map is capped at
/// 65535 pairs."* Adding the decode branch without the encode branch would have converted that
/// recorded host-only trap into a remote process abort, reached through
/// `LXMessage.validateSignature`'s unconditional re-encode.
@Test func msgPackMapOverSixtyFiveThousandPairsEncodesAsMap32WithoutTrapping() {
    let pairs = (0..<70000).map { MsgPackValue.IntPair($0, .uint(0)) }
    let encoded = MsgPack.encode(.intMap(pairs))
    #expect(Array(encoded.prefix(5)) == [0xDF, 0x00, 0x01, 0x11, 0x70])   // 70000 == 0x00011170
    #expect(MsgPack.decodeValue(encoded) == .intMap(pairs))
}

@Test func msgPackStringMapOverSixtyFiveThousandPairsEncodesAsMap32() {
    let pairs = (0..<70000).map { MsgPackValue.Pair("k\($0)", .uint(0)) }
    let encoded = MsgPack.encode(.map(pairs))
    #expect(Array(encoded.prefix(5)) == [0xDF, 0x00, 0x01, 0x11, 0x70])
    #expect(MsgPack.decodeValue(encoded) == .map(pairs))
}

@Test func msgPackMap16BoundaryUnchanged() {
    // Regression: the map32 branch must not disturb the fixmap/map16 boundary.
    let fifteen = (0..<15).map { MsgPackValue.IntPair($0, .uint(0)) }
    let sixteen = (0..<16).map { MsgPackValue.IntPair($0, .uint(0)) }
    #expect(MsgPack.encode(.intMap(fifteen)).first == 0x8F)
    #expect(Array(MsgPack.encode(.intMap(sixteen)).prefix(3)) == [0xDE, 0x00, 0x10])
}

// MARK: ext / fixext — rejected on purpose

/// Neither RNS nor LXMF ever packs an `Ext` or a `datetime`: a package-wide grep of both installed
/// packages finds `datetime.datetime` only in log formatting (`RNS/__init__.py:123`) and in
/// `rnodeconf.py`, never inside a msgpack payload, and no use of `umsgpack.Ext` at all. So ext is
/// not a reference-emitted shape, and rejecting it is a decision rather than an oversight.
@Test func msgPackExtIsRejected() {
    #expect(MsgPack.decodeValue(Data([0xD4, 0x01, 0xFF])) == nil)                       // fixext1
    #expect(MsgPack.decodeValue(Data([0xD5, 0x01, 0xFF, 0xFF])) == nil)                 // fixext2
    #expect(MsgPack.decodeValue(Data([0xD6, 0x01, 0, 0, 0, 0])) == nil)                 // fixext4
    #expect(MsgPack.decodeValue(Data([0xD7, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0])) == nil)     // ext timestamp
    #expect(MsgPack.decodeValue(Data([0xD8] + [UInt8](repeating: 0, count: 17))) == nil) // fixext16
    #expect(MsgPack.decodeValue(Data([0xC7, 0x01, 0x01, 0xFF])) == nil)                 // ext8
    #expect(MsgPack.decodeValue(Data([0xC8, 0x00, 0x01, 0x01, 0xFF])) == nil)           // ext16
    #expect(MsgPack.decodeValue(Data([0xC9, 0x00, 0x00, 0x00, 0x01, 0x01, 0xFF])) == nil) // ext32
}

// MARK: intMap keys stay unsigned — a documented boundary, not a new hole

/// LXMF's field keys are the non-negative `FIELD_*` constants (`LXMF/LXMF.py:8-51`), so a negative
/// map key is not a shape reference emits. It is rejected rather than supported, deliberately:
/// accepting one would put a negative `IntPair.key` into `encodeIntMap`'s `UInt64(p.key)`, which is
/// the exact trap `eb244c3` closed by rejecting at the decoder.
@Test func msgPackNegativeMapKeyIsRejected() {
    #expect(MsgPack.decodeValue(Data([0x81, 0xFF, 0x00])) == nil)     // fixmap1 { -1: 0 }
    #expect(MsgPack.decodeValue(Data([0x81, 0xD0, 0x80, 0x00])) == nil) // fixmap1 { int8(-128): 0 }
}

// MARK: Nothing we already emit changed

/// The sharpest test of the design: every value the encoder could already produce must still
/// produce the identical bytes. A single changed byte breaks wire compatibility everywhere.
@Test func msgPackExistingEncodingsAreByteIdentical() {
    #expect(Array(MsgPack.encode(.uint(0))) == [0x00])
    #expect(Array(MsgPack.encode(.uint(127))) == [0x7F])
    #expect(Array(MsgPack.encode(.uint(128))) == [0xCC, 0x80])
    #expect(Array(MsgPack.encode(.uint(65535))) == [0xCD, 0xFF, 0xFF])
    #expect(Array(MsgPack.encode(.uint(65536))) == [0xCE, 0x00, 0x01, 0x00, 0x00])
    #expect(Array(MsgPack.encode(.uint(UInt64.max))) == [0xCF] + [UInt8](repeating: 0xFF, count: 8))
    #expect(Array(MsgPack.encode(.double(-1.0))) == [0xCB, 0xBF, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    #expect(Array(MsgPack.encode(.null)) == [0xC0])
    #expect(Array(MsgPack.encode(.bool(true))) == [0xC3])
    #expect(Array(MsgPack.encode(.bool(false))) == [0xC2])
    #expect(Array(MsgPack.encode(.string("k"))) == [0xA1, 0x6B])
    #expect(Array(MsgPack.encode(.bin(Data([0xAA])))) == [0xC4, 0x01, 0xAA])
    #expect(Array(MsgPack.encode(.array([.uint(1), .uint(2)]))) == [0x92, 0x01, 0x02])
    #expect(Array(MsgPack.encode(.map([]))) == [0x80])
    #expect(Array(MsgPack.encode(.map([.init("k", .uint(1))]))) == [0x81, 0xA1, 0x6B, 0x01])
    #expect(Array(MsgPack.encode(.intMap([.init(1, .uint(2))]))) == [0x81, 0x01, 0x02])
}

// MARK: Nesting

@Test func msgPackSignedValuesNestAndRoundTrip() {
    let v = MsgPackValue.intMap([
        .init(0x02, .array([.int(-1), .int(-33), .int(Int64.min), .uint(7), .float(1.5)])),
        .init(0x0F, .map([.init("k", .int(-129))])),
    ])
    #expect(MsgPack.decodeValue(MsgPack.encode(v)) == v)
}

@Test func msgPackSignedValuesRespectTheDepthLimit() {
    // Regression: the new tags must go through `parse`, so the depth guard still applies to them.
    var payload = Data(repeating: 0x91, count: MsgPack.maxParseDepth + 2)   // fixarray1 nesting
    payload.append(0xFF)                                                    // negative fixint leaf
    #expect(MsgPack.decodeValue(payload) == nil)
}
