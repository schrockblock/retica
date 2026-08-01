import Testing
import Foundation
@testable import ReTiCAInterfaces

// MARK: - Framing

@Test func frameProducesBigEndianLengthPrefix() throws {
    let packet = Data([0xAA, 0xBB, 0xCC])
    #expect(try BLEFraming.frame(packet) == Data([0x00, 0x03, 0xAA, 0xBB, 0xCC]))
    let big = Data(repeating: 0x42, count: 300)
    #expect(try BLEFraming.frame(big) == Data([0x01, 0x2C]) + big)
}

@Test func frameRejectsEmptyAndOversizedPackets() {
    #expect(throws: BLEFramingError.invalidLength(0)) { try BLEFraming.frame(Data()) }
    #expect(throws: BLEFramingError.invalidLength(1197)) {
        try BLEFraming.frame(Data(repeating: 0, count: 1197))
    }
    // Boundary: exactly 1196 is legal.
    #expect((try? BLEFraming.frame(Data(repeating: 0, count: 1196))) != nil)
}

@Test func frameBufferRecoversMultiplePacketsFromOneAppend() throws {
    var buffer = BLEFrameBuffer()
    let a = Data([0x01]); let b = Data([0x02, 0x03])
    let stream = try BLEFraming.frame(a) + BLEFraming.frame(b)
    #expect(try buffer.append(stream) == [a, b])
}

@Test func frameBufferHandlesSplitDelivery() throws {
    var buffer = BLEFrameBuffer()
    let packet = Data((0..<30).map { UInt8($0) })
    let framed = try BLEFraming.frame(packet)
    // Split mid-header, then mid-payload.
    #expect(try buffer.append(framed.prefix(1)) == [])
    #expect(try buffer.append(framed.dropFirst(1).prefix(10)) == [])
    #expect(try buffer.append(framed.dropFirst(11)) == [packet])
}

@Test func frameBufferThrowsOnZeroLength() {
    var buffer = BLEFrameBuffer()
    #expect(throws: BLEFramingError.invalidLength(0)) {
        _ = try buffer.append(Data([0x00, 0x00, 0xFF]))
    }
}

@Test func frameBufferThrowsOnOversizedLength() {
    var buffer = BLEFrameBuffer()
    // 0x04AD = 1197 > 1196
    #expect(throws: BLEFramingError.invalidLength(1197)) {
        _ = try buffer.append(Data([0x04, 0xAD]))
    }
}

// MARK: - HELLO

@Test func helloPackParseRoundTrip() {
    let token = Data((0..<16).map { UInt8($0 &+ 0x10) })
    let packed = BLEHello.pack(version: 2, token: token)
    #expect(packed.count == BLEHello.length)
    #expect(packed.prefix(3) == Data("RBT".utf8))
    let parsed = BLEHello.parse(packed)
    #expect(parsed?.version == 2)
    #expect(parsed?.token == token)
}

@Test func helloParseRejectsBadInput() {
    let token = Data(repeating: 0xAA, count: 16)
    var wrongMagic = BLEHello.pack(version: 2, token: token)
    wrongMagic[wrongMagic.startIndex] = 0x51
    #expect(BLEHello.parse(wrongMagic) == nil)
    #expect(BLEHello.parse(Data(repeating: 0, count: 19)) == nil)  // short
    #expect(BLEHello.parse(Data(repeating: 0, count: 21)) == nil)  // long
    #expect(BLEHello.parse(Data()) == nil)
}
