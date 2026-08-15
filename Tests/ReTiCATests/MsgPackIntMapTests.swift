import Testing
import Foundation
@testable import ReTiCA

// MARK: - CVE-class: map key above Int.max must be REJECTED, not trap

/// Eleven attacker bytes: fixmap-1 with a uint64 key of UInt64.max and a zero value.
/// Before the fix, `Int(key)` in `MsgPack.parseMap` (the guard now at MsgPack.swift:268) traps —
/// the process aborts.
/// After the fix it must return nil cleanly.
///
/// Payload: 0x81  0xCF FF FF FF FF FF FF FF FF  0x00
///           map1  uint64 (UInt64.max)           fixint 0
@Test func msgPackIntMapAboveIntMaxIsRejected() {
    let payload = Data([0x81, 0xCF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
    #expect(MsgPack.decodeValue(payload) == nil,
            "a map key above Int.max must be rejected, not trap")
}

/// A key exactly at Int.max (0x7FFF_FFFF_FFFF_FFFF) is a legitimate large-but-representable value
/// and must still decode successfully — the fix cannot be "reject everything".
@Test func msgPackIntMapAtIntMaxDecodes() {
    // fixmap-1 ‖ uint64(Int.max) ‖ fixint 0
    let intMaxBytes: [UInt8] = [
        0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    ]
    let payload = Data([0x81, 0xCF] + intMaxBytes + [0x00])
    let result = MsgPack.decodeValue(payload)
    #expect(result != nil, "Int.max is representable and must decode")
    if let result {
        #expect(result == .intMap([.init(Int.max, .uint(0))]))
    }
}

/// The realistic attack shape. `ResourceAdvertisement.unpack` (ResourceAdvertisement.swift:44)
/// calls `MsgPack.decodeValue` FIRST and only then checks `case let .map(pairs)?` — so a hostile
/// `intMap` nested anywhere inside an otherwise well-formed advertisement is walked by the parser
/// before any shape validation runs. Validating the top-level shape does not protect the parse.
///
/// The guard (`Int(exactly: key)`, MsgPack.swift:268) lives inside `parseMap`, and every path to
/// `parseMap` goes through `parse`, so it fires at any depth. These tests prove that rather than
/// arguing it.
@Test func msgPackIntMapAboveIntMaxIsRejectedWhenNestedInArray() {
    // fixarray1 [ fixmap1 { uint64(UInt64.max): 0 } ]
    let payload = Data([0x91, 0x81, 0xCF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
    #expect(MsgPack.decodeValue(payload) == nil,
            "a hostile intMap key nested in an array must be rejected, not trap")
}

/// Deeper still — nested two levels down, to show the guard is not depth-one only.
@Test func msgPackIntMapAboveIntMaxIsRejectedWhenDeeplyNested() {
    // fixarray1 [ fixarray1 [ fixmap1 { uint64(UInt64.max): 0 } ] ]
    let payload = Data([0x91, 0x91, 0x81, 0xCF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
    #expect(MsgPack.decodeValue(payload) == nil,
            "depth does not bypass the key guard")
}

/// Advertisement-shaped: a well-formed string-keyed outer map (what `ResourceAdvertisement.unpack`
/// expects) whose value carries the hostile `intMap`. Driven through both `MsgPack.decodeValue`
/// and `ResourceAdvertisement.unpack` — the latter is the actual unauthenticated entry point, and
/// it must return nil rather than abort.
@Test func advertisementShapedPayloadWithHostileNestedIntMapIsRejected() {
    // fixmap1 { "t": fixmap1 { uint64(UInt64.max): 0 } }
    let hostileIntMap: [UInt8] = [0x81, 0xCF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
    let payload = Data([0x81, 0xA1, 0x74] + hostileIntMap)
    #expect(MsgPack.decodeValue(payload) == nil,
            "the parser must reject before ResourceAdvertisement's shape check ever runs")
    #expect(ResourceAdvertisement.unpack(payload) == nil,
            "the unauthenticated advertisement entry point must not abort")
}

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
