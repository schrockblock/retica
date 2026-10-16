import Testing
import Foundation
@testable import ReTiCAInterfaces

private func ramp(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }) }

@Suite struct MeshtasticCodecTests {
    private let codec = LandandairCodec()

    /// Spec §5.1: n = len/200 + 1; size = len/n + 1; chunks stepping by size.
    @Test func splitBodySizesFollowLandandairsArithmetic() {
        let rows: [(Int, [Int])] = [
            (1, [1]), (199, [199]), (200, [101, 99]), (201, [101, 100]),
            (400, [134, 134, 132]), (500, [167, 167, 166]), (508, [170, 170, 168]),
        ]
        for (length, sizes) in rows {
            #expect(codec.split(ramp(length), index: 0).map { $0.count - 2 } == sizes, "length \(length)")
        }
    }

    @Test func splitBodiesConcatenateToThePacket() {
        for length in [1, 199, 200, 201, 400, 500, 508] {
            let packet = ramp(length)
            let joined = codec.split(packet, index: 0).reduce(into: Data()) { $0.append($1.dropFirst(2)) }
            #expect(joined == packet, "length \(length)")
        }
    }

    @Test func splitHeadersCarryTheIndexAndOneBasedPositionsWithTheLastNegated() {
        let headers = codec.split(ramp(500), index: 9).map { Array($0.prefix(2)) }
        #expect(headers == [[9, 1], [9, 2], [9, 0xFD]])
    }

    @Test func singleFragmentPacketCarriesPositionMinusOne() {
        #expect(codec.split(ramp(199), index: 4).map { Array($0.prefix(2)) } == [[4, 0xFF]])
    }

    /// 128 fragments is the most a signed pos byte can number (1...127, last −128).
    @Test func splitRefusesMoreThan128Fragments() {
        let largest = codec.split(ramp(25_400), index: 0)
        #expect(largest.count == 128)
        #expect(largest.last?.dropFirst().first == 0x80)
        #expect(codec.split(ramp(25_600), index: 0).isEmpty)
    }

    @Test func parseReadsADataFrame() {
        #expect(codec.parse(Data([7, 0xFE, 1, 2, 3])) == .data(index: 7, pos: -2, body: Data([1, 2, 3])))
    }

    @Test func parseReadsARequestFrame() {
        #expect(codec.parse(Data("REQ".utf8) + Data([3, 2])) == .request(index: 3, pos: 2))
    }

    /// Spec §5.1: only a 5-byte frame with a "REQ" prefix is a request.
    @Test func requestPrefixOfAnyOtherLengthIsData() {
        let frame = Data("REQ".utf8) + Data([3, 2, 9])
        #expect(codec.parse(frame) == .data(index: 0x52, pos: 0x45, body: Data("Q".utf8) + Data([3, 2, 9])))
    }

    @Test func parseRejectsFramesShorterThanThreeBytes() {
        #expect(codec.parse(Data()) == nil)
        #expect(codec.parse(Data([1])) == nil)
        #expect(codec.parse(Data([1, 0xFF])) == nil)
    }

    @Test func parseRejectsPositionZero() {
        #expect(codec.parse(Data([1, 0, 5])) == nil)
        #expect(codec.parse(Data("REQ".utf8) + Data([1, 0])) == nil)
    }

    @Test func parseRejectsFramesOver233Bytes() {
        #expect(codec.parse(Data([1, 0xFF]) + Data(repeating: 0xAB, count: 232)) == nil)   // 234
        #expect(codec.parse(Data([1, 0xFF]) + Data(repeating: 0xAB, count: 231)) != nil)   // 233
    }

    // Review Focus 1 — trap-class (step b′).
    @Test func parseReadsInt8MinPosition() {
        #expect(codec.parse(Data([1, 0x80, 9])) == .data(index: 1, pos: .min, body: Data([9])))
    }

    // Review Focus 2 — trap-class (step b′).
    @Test func parseHandlesANonZeroBasedSlice() {
        let backing = Data([0xAA, 0xBB, 7, 0xFF, 1, 2])
        #expect(codec.parse(backing.dropFirst(2)) == .data(index: 7, pos: -1, body: Data([1, 2])))
        let request = Data([0xAA, 0xBB]) + Data("REQ".utf8) + Data([3, 2])
        #expect(codec.parse(request.dropFirst(2)) == .request(index: 3, pos: 2))
    }

    // Review Focus 2 — trap-class (step b′).
    @Test func splitHandlesANonZeroBasedSlice() {
        let backing = ramp(350)
        #expect(codec.split(backing.dropFirst(50), index: 3) == codec.split(Data(backing.dropFirst(50)), index: 3))
    }

    @Test func landandairFramingVendsTheLandandairCodec() {
        #expect(MeshtasticFraming.landandair.codec.split(ramp(300), index: 1) == codec.split(ramp(300), index: 1))
    }
}
