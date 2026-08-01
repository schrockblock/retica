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

// MARK: - Greylist

@Test func greylistBackoffGrowsExponentiallyAndIsInclusive() {
    var greylist = BLEPeerGreylist<String>()
    let t0 = Date(timeIntervalSince1970: 0)
    greylist.recordFailure("peer", now: t0)
    // Strike 1: 5 s delay; boundary is inclusive.
    #expect(greylist.isBlocked("peer", now: t0.addingTimeInterval(5.0)))
    #expect(!greylist.isBlocked("peer", now: t0.addingTimeInterval(5.01)))
    // Strike 2 at t=10: 10 s delay -> blocked through t=20.
    greylist.recordFailure("peer", now: t0.addingTimeInterval(10))
    #expect(greylist.isBlocked("peer", now: t0.addingTimeInterval(20.0)))
    #expect(!greylist.isBlocked("peer", now: t0.addingTimeInterval(20.01)))
}

@Test func greylistCapsAtMaxDelay() {
    var greylist = BLEPeerGreylist<String>()
    var t = Date(timeIntervalSince1970: 0)
    for _ in 0..<8 {  // strikes 1..8; 5*2^7 = 640 would exceed the 300 s cap
        greylist.recordFailure("peer", now: t)
        t = t.addingTimeInterval(10)
    }
    let last = t.addingTimeInterval(-10)  // time of the 8th strike
    #expect(greylist.isBlocked("peer", now: last.addingTimeInterval(300)))
    #expect(!greylist.isBlocked("peer", now: last.addingTimeInterval(300.01)))
}

@Test func greylistForgetsStrikesAfterQuietPeriod() {
    var greylist = BLEPeerGreylist<String>()
    let t0 = Date(timeIntervalSince1970: 0)
    greylist.recordFailure("peer", now: t0)
    greylist.recordFailure("peer", now: t0.addingTimeInterval(10))  // strike 2
    // 601 s after the last failure: strikes reset, next failure is strike 1 (5 s).
    let late = t0.addingTimeInterval(10 + 601)
    greylist.recordFailure("peer", now: late)
    #expect(greylist.isBlocked("peer", now: late.addingTimeInterval(5.0)))
    #expect(!greylist.isBlocked("peer", now: late.addingTimeInterval(5.01)))
}

@Test func greylistUnknownPeerIsNotBlockedAndClearWorks() {
    var greylist = BLEPeerGreylist<String>()
    let t0 = Date(timeIntervalSince1970: 0)
    #expect(!greylist.isBlocked("stranger", now: t0))
    greylist.recordFailure("peer", now: t0)
    greylist.clear("peer")
    #expect(!greylist.isBlocked("peer", now: t0))
}

// MARK: - Duplicate resolution

@Test func tokenComparisonIsUnsignedLexicographic() {
    #expect(bleTokenIsLower(Data([0x01, 0xFF]), Data([0x02, 0x00])))
    #expect(!bleTokenIsLower(Data([0x80]), Data([0x7F])))  // unsigned, not signed
    #expect(!bleTokenIsLower(Data([0x01]), Data([0x01])))  // equal is not lower
}

@Test func crossConnectBothEndpointsKeepTheLowerInitiatorsChannel() {
    let low = Data(repeating: 0x01, count: 16)
    let high = Data(repeating: 0x02, count: 16)
    // Endpoint LOW: its outbound channel exists, HIGH's inbound arrives second.
    #expect(bleResolveDuplicate(localToken: low, peerToken: high,
                                existingDirection: .outbound, newDirection: .inbound) == .keepExisting)
    // Endpoint HIGH: its outbound channel exists, LOW's inbound arrives second.
    #expect(bleResolveDuplicate(localToken: high, peerToken: low,
                                existingDirection: .outbound, newDirection: .inbound) == .keepNew)
    // Arrival order flipped on both endpoints — conclusions must still agree (keep LOW's channel).
    #expect(bleResolveDuplicate(localToken: low, peerToken: high,
                                existingDirection: .inbound, newDirection: .outbound) == .keepNew)
    #expect(bleResolveDuplicate(localToken: high, peerToken: low,
                                existingDirection: .inbound, newDirection: .outbound) == .keepExisting)
}

@Test func sameDirectionDuplicateIsAReconnectKeepNew() {
    let a = Data(repeating: 0x01, count: 16)
    let b = Data(repeating: 0x02, count: 16)
    #expect(bleResolveDuplicate(localToken: a, peerToken: b,
                                existingDirection: .outbound, newDirection: .outbound) == .keepNew)
    #expect(bleResolveDuplicate(localToken: a, peerToken: b,
                                existingDirection: .inbound, newDirection: .inbound) == .keepNew)
}
