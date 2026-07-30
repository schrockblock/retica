import Testing
import Foundation
@testable import ReTiCA

@Test func msgPackBoolRoundTrips() throws {
    #expect(Array(MsgPack.encode(.bool(false))) == [0xC2])
    #expect(Array(MsgPack.encode(.bool(true))) == [0xC3])
    #expect(MsgPack.decodeValue(Data([0xC2])) == .bool(false))
    #expect(MsgPack.decodeValue(Data([0xC3])) == .bool(true))
}

@Test func msgPackBoolInArrayRoundTrips() throws {
    let v = MsgPackValue.array([.bool(false), .uint(7), .bool(true)])
    #expect(MsgPack.decodeValue(MsgPack.encode(v)) == v)
}
