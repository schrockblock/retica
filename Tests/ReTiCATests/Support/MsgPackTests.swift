import Testing
import Foundation
@testable import ReTiCA

@Test func msgPackEncodesFloat64WithTag() {
    // umsgpack.packb(0.125) == cb 3f c0 00 00 00 00 00 00 (verified vs RNS.vendor.umsgpack)
    #expect(MsgPack.encode(0.125) == Data([0xCB, 0x3F, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
}

@Test func msgPackDoubleRoundTrips() {
    for v in [0.0, 0.125, -1.5, 3.141592653589793, 1234.5] {
        #expect(MsgPack.decodeDouble(MsgPack.encode(v)) == v)
    }
}

@Test func msgPackDecodeRejectsMalformed() {
    #expect(MsgPack.decodeDouble(Data([0x00, 0x01])) == nil)                                   // wrong length
    #expect(MsgPack.decodeDouble(Data([0xCA]) + Data(repeating: 0, count: 8)) == nil)          // float32 tag, right length
    #expect(MsgPack.decodeDouble(Data()) == nil)                                                // empty
    #expect(MsgPack.decodeDouble(Data([0xCB]) + Data(repeating: 0, count: 7)) == nil)          // too short
    #expect(MsgPack.decodeDouble(Data([0xCB]) + Data(repeating: 0, count: 9)) == nil)          // too long (10 bytes)
}

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

@Test func msgPackEncodesLengthPrefixedForms() {
    // bin16: 0xC5 + 2-byte BE length + data
    let bin256 = Data(repeating: 0xEE, count: 256)
    #expect(MsgPack.encode(.bin(bin256)) == Data([0xC5, 0x01, 0x00]) + bin256)
    // str8: 0xD9 + 1-byte length + utf8
    let str32 = String(repeating: "a", count: 32)
    #expect(MsgPack.encode(.string(str32)) == Data([0xD9, 0x20]) + Data(str32.utf8))
    // str16: 0xDA + 2-byte BE length + utf8
    let str256 = String(repeating: "a", count: 256)
    #expect(MsgPack.encode(.string(str256)) == Data([0xDA, 0x01, 0x00]) + Data(str256.utf8))
    // and they round-trip
    #expect(MsgPack.decodeValue(MsgPack.encode(.string(str256))) == .string(str256))
    #expect(MsgPack.decodeValue(MsgPack.encode(.bin(bin256))) == .bin(bin256))
}
