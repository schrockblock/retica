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
    // A failure after clear starts over at strike 1 (5 s), not a stale escalated count.
    let t = t0.addingTimeInterval(60)
    greylist.recordFailure("peer", now: t)
    #expect(greylist.isBlocked("peer", now: t.addingTimeInterval(5.0)))
    #expect(!greylist.isBlocked("peer", now: t.addingTimeInterval(5.01)))
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

// MARK: - Fragmenter (ble-reticulum v2.2)

@Test func singleFragmentPacketIsStartWithTotalOne() throws {
    let f = BLEFragmenter(mtu: 185)
    let packet = Data([0xAA, 0xBB, 0xCC])
    let frags = try f.fragment(packet)
    #expect(frags == [Data([0x01, 0x00, 0x00, 0x00, 0x01, 0xAA, 0xBB, 0xCC])])
}

@Test func multiFragmentPacketHasStartContinueEndHeaders() throws {
    let f = BLEFragmenter(mtu: 23)                 // payload 18
    #expect(f.payloadSize == 18)
    let packet = Data((0..<40).map { UInt8($0) })  // 18 + 18 + 4 → 3 fragments
    let frags = try f.fragment(packet)
    #expect(frags.count == 3)
    #expect(frags[0].prefix(5) == Data([0x01, 0x00, 0x00, 0x00, 0x03]))
    #expect(frags[1].prefix(5) == Data([0x02, 0x00, 0x01, 0x00, 0x03]))
    #expect(frags[2].prefix(5) == Data([0x03, 0x00, 0x02, 0x00, 0x03]))
    #expect(frags[0].dropFirst(5) == packet[0..<18])
    #expect(frags[1].dropFirst(5) == packet[18..<36])
    #expect(frags[2].dropFirst(5) == packet[36..<40])
}

@Test func exactMultipleOfPayloadNeedsNoExtraFragment() throws {
    let f = BLEFragmenter(mtu: 23)
    let frags = try f.fragment(Data(repeating: 0x5A, count: 36))
    #expect(frags.count == 2)
    #expect(frags[1][frags[1].startIndex] == 0x03)   // END, not CONTINUE
}

@Test func mtuIsFlooredAtTwenty() {
    #expect(BLEFragmenter(mtu: 3).mtu == 20)
    #expect(BLEFragmenter(mtu: 3).payloadSize == 15)
    #expect(BLEFragmenter(mtu: 517).payloadSize == 512)
}

@Test func fragmentRejectsEmptyPacket() {
    #expect(throws: BLEFragmentError.emptyPacket) { try BLEFragmenter(mtu: 185).fragment(Data()) }
}

@Test func fragmentRejectsMoreThan65535Fragments() {
    // mtu 20 → payload 15; 65 536 × 15 bytes needs 65 536 fragments.
    let packet = Data(repeating: 0, count: 65_536 * 15)
    #expect(throws: BLEFragmentError.tooManyFragments(65_536)) { try BLEFragmenter(mtu: 20).fragment(packet) }
}

@Test func sequenceAndTotalAreBigEndianUInt16() throws {
    // 300 fragments of 15 bytes: sequence 299 = 0x012B, total 300 = 0x012C.
    let frags = try BLEFragmenter(mtu: 20).fragment(Data(repeating: 1, count: 300 * 15))
    #expect(frags[299].prefix(5) == Data([0x03, 0x01, 0x2B, 0x01, 0x2C]))
}

// MARK: - Reassembler (ble-reticulum v2.2)

private let t0 = Date(timeIntervalSince1970: 10_000)

@Test func reassemblesInOrderFragmentsIntoOnePacket() throws {
    let packet = Data((0..<40).map { UInt8($0) })
    let frags = try BLEFragmenter(mtu: 23).fragment(packet)
    var r = BLEReassembler()
    #expect(try r.receive(frags[0], now: t0) == nil)
    #expect(try r.receive(frags[1], now: t0) == nil)
    #expect(try r.receive(frags[2], now: t0) == packet)
    #expect(r.inFlightCount == 0)
}

@Test func singleFragmentPacketCompletesImmediately() throws {
    var r = BLEReassembler()
    let frag = try BLEFragmenter(mtu: 185).fragment(Data([9, 8, 7]))[0]
    #expect(try r.receive(frag, now: t0) == Data([9, 8, 7]))
}

@Test func identicalDuplicateFragmentIsIgnored() throws {
    let packet = Data(repeating: 0x44, count: 30)
    let frags = try BLEFragmenter(mtu: 23).fragment(packet)   // 2 fragments
    var r = BLEReassembler()
    _ = try r.receive(frags[0], now: t0)
    _ = try r.receive(frags[0], now: t0)                      // retransmit, harmless
    #expect(try r.receive(frags[1], now: t0) == packet)
}

@Test func conflictingDuplicateThrowsAndDiscardsBuffer() throws {
    // A 3-fragment packet; the conflict lands on sequence 1, mid-flight.
    var r = BLEReassembler()
    let big = try BLEFragmenter(mtu: 23).fragment(Data(repeating: 0x55, count: 50))
    _ = try r.receive(big[0], now: t0)
    _ = try r.receive(big[1], now: t0)
    var altered = big[1]; altered[altered.startIndex + 5] = 0x99
    #expect(throws: BLEReassemblyError.conflictingDuplicate(1)) { _ = try r.receive(altered, now: t0) }
    #expect(r.inFlightCount == 0)   // buffer discarded
}

@Test func malformedFragmentsThrowWithoutTouchingOtherBuffers() throws {
    var r = BLEReassembler()
    let big = try BLEFragmenter(mtu: 23).fragment(Data(repeating: 0x55, count: 50))
    _ = try r.receive(big[0], now: t0)
    #expect(throws: BLEReassemblyError.tooShort(4)) { _ = try r.receive(Data([1, 0, 0, 0]), now: t0) }
    #expect(throws: BLEReassemblyError.badType(0x07)) { _ = try r.receive(Data([7, 0, 0, 0, 1, 0xAA]), now: t0) }
    #expect(throws: BLEReassemblyError.badSequence(3, total: 3)) { _ = try r.receive(Data([2, 0, 3, 0, 3, 0xAA]), now: t0) }
    #expect(throws: BLEReassemblyError.zeroTotal) { _ = try r.receive(Data([1, 0, 0, 0, 0, 0xAA]), now: t0) }
    #expect(r.inFlightCount == 1)   // the in-flight packet survived the junk
}

@Test func sequenceZeroRestartsBufferForThatTotal() throws {
    // Review Focus 5: a fresh START for the same total replaces the partial packet.
    let a = try BLEFragmenter(mtu: 23).fragment(Data(repeating: 0xA1, count: 50))
    let b = try BLEFragmenter(mtu: 23).fragment(Data(repeating: 0xB2, count: 50))
    var r = BLEReassembler()
    _ = try r.receive(a[0], now: t0)
    _ = try r.receive(a[1], now: t0)
    _ = try r.receive(b[0], now: t0)          // restart
    #expect(try r.receive(b[1], now: t0) == nil)
    #expect(try r.receive(b[2], now: t0) == Data(repeating: 0xB2, count: 50))
    #expect(r.inFlightCount == 0)
}

@Test func twoPacketsWithDifferentTotalsInterleave() throws {
    let a = try BLEFragmenter(mtu: 23).fragment(Data(repeating: 0xA1, count: 50))  // 3 frags
    let b = try BLEFragmenter(mtu: 23).fragment(Data(repeating: 0xB2, count: 30))  // 2 frags
    var r = BLEReassembler()
    _ = try r.receive(a[0], now: t0)
    _ = try r.receive(b[0], now: t0)
    #expect(r.inFlightCount == 2)
    #expect(try r.receive(b[1], now: t0) == Data(repeating: 0xB2, count: 30))
    _ = try r.receive(a[1], now: t0)
    #expect(try r.receive(a[2], now: t0) == Data(repeating: 0xA1, count: 50))
}

@Test func staleBuffersArePurgedWhenAPacketCompletes() throws {
    var r = BLEReassembler()
    let stale = try BLEFragmenter(mtu: 23).fragment(Data(repeating: 0x11, count: 50))
    _ = try r.receive(stale[0], now: t0)
    let later = t0.addingTimeInterval(BLEReassembler.staleAge + 1)
    let quick = try BLEFragmenter(mtu: 185).fragment(Data([1]))[0]
    #expect(try r.receive(quick, now: later) == Data([1]))
    #expect(r.inFlightCount == 0)   // stale 3-fragment packet purged on completion
}

@Test func ninthInFlightPacketEvictsTheOldest() throws {
    var r = BLEReassembler()
    // Nine partial packets with distinct totals 2...10 (one START each).
    for total in 2...10 {
        let size = (total - 1) * 18 + 1            // exactly `total` fragments at payload 18
        let frags = try BLEFragmenter(mtu: 23).fragment(Data(repeating: UInt8(total), count: size))
        _ = try r.receive(frags[0], now: t0.addingTimeInterval(Double(total)))
    }
    #expect(r.inFlightCount == BLEReassembler.maxInFlight)
    // The oldest (total 2) was evicted: its END now lands in a fresh, incomplete buffer.
    let two = try BLEFragmenter(mtu: 23).fragment(Data(repeating: 2, count: 19))
    #expect(try r.receive(two[1], now: t0.addingTimeInterval(20)) == nil)
}

@Test func packetCompletingAtCapacityWithTiedTimestampIsNotEvicted() throws {
    var r = BLEReassembler()
    for total in 2...9 {   // eight partial packets, all started at t0
        let size = (total - 1) * 18 + 1
        let frags = try BLEFragmenter(mtu: 23).fragment(Data(repeating: UInt8(total), count: size))
        _ = try r.receive(frags[0], now: t0)
    }
    #expect(r.inFlightCount == BLEReassembler.maxInFlight)
    let quick = try BLEFragmenter(mtu: 185).fragment(Data([7, 7]))[0]   // total 1, same instant
    #expect(try r.receive(quick, now: t0) == Data([7, 7]))
    #expect(r.inFlightCount == BLEReassembler.maxInFlight)              // nothing else evicted
}

@Test func keepalivePredicateMatchesOnlyASingleZeroByte() {
    #expect(BLEKeepalive.isKeepalive(Data([0x00])))
    #expect(BLEKeepalive.frame == Data([0x00]))
    #expect(!BLEKeepalive.isKeepalive(Data([0x01])))
    #expect(!BLEKeepalive.isKeepalive(Data([0x00, 0x00])))
    #expect(!BLEKeepalive.isKeepalive(Data()))
}
