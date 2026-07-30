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
