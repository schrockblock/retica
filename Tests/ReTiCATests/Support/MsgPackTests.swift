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
}
