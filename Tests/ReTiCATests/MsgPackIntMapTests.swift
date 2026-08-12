import Testing
import Foundation
@testable import ReTiCA

// MARK: - CVE-class: map key above Int.max must be REJECTED, not trap

/// Eleven attacker bytes: fixmap-1 with a uint64 key of UInt64.max and a zero value.
/// Before the fix, `Int(key)` at MsgPack.swift:146 traps — the process aborts.
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
