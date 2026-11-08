import Foundation
import Testing

@testable import ReTiCAInterfaces

private let codecSrc = Data([0x01, 0x02, 0x03, 0x04])
private let codecDst = Data(repeating: 0, count: 4)
private let codecPacketID: UInt16 = 0xBEEF

private func codecPacket(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) })
}

private func codecSplit(
    _ data: Data, type: MeshCoreFrameType = .rnsFragment,
    src: Data = codecSrc, dst: Data = codecDst, canRoute: Bool = false
) -> [Data] {
    ScotMeshRawCodec().split(
        data, type: type, src: src, dst: dst, packetID: codecPacketID, canRoute: canRoute)
}

private func codecHeader(
    flags: UInt8 = 0, index: UInt8 = 0, total: UInt8 = 1, magic: UInt8 = 0x52,
    body: [UInt8] = []
) -> Data {
    Data([magic, flags, 1, 2, 3, 4, 0, 0, 0, 0, 0xBE, 0xEF, index, total] + body)
}

@Suite struct MeshCoreCodecTests {
    @Test(arguments: [
        (1, [1]), (147, [147]), (148, [148]), (149, [148, 1]), (296, [148, 148]),
        (500, [148, 148, 148, 56]), (508, [148, 148, 148, 64]),
    ])
    func splitBodySizesAreChunksOf148(length: Int, expected: [Int]) {
        let sizes = codecSplit(codecPacket(length)).map { $0.count - 14 }
        #expect(sizes == expected)
    }

    @Test(arguments: [1, 147, 148, 149, 296, 500, 508])
    func splitBodiesConcatenateToThePacket(length: Int) {
        let packet = codecPacket(length)
        let joined = codecSplit(packet).reduce(into: Data()) { $0.append($1.dropFirst(14)) }
        #expect(joined == packet)
    }

    @Test func largestDatagramIs162Bytes() {
        let datagrams = codecSplit(codecPacket(508))
        #expect(datagrams.allSatisfy { $0.count <= 162 })
        #expect(datagrams.first?.count == 162)
    }

    @Test func headerIsByteExact() {
        let datagrams = codecSplit(codecPacket(149), canRoute: true)
        let expected = Data([0x52, 0x10, 1, 2, 3, 4, 0, 0, 0, 0, 0xBE, 0xEF, 0x00, 0x02])
        #expect(datagrams[0].prefix(14) == expected)
    }

    @Test func canRouteClearLeavesBit4Clear() {
        #expect(codecSplit(codecPacket(10), canRoute: false)[0][1] == 0x00)
    }

    @Test func fragmentIndexCountsFromZero() {
        let last = codecSplit(codecPacket(500)).last!
        #expect(last[12] == 3)
        #expect(last[13] == 4)
    }

    @Test func bindFrameUsesTypeNibble2() {
        #expect(codecSplit(codecPacket(32), type: .bind)[0][1] == 0x02)
        #expect(codecSplit(codecPacket(32), type: .bindRequest)[0][1] == 0x01)
    }

    @Test func splitOfEmptyDataIsEmpty() {
        #expect(codecSplit(Data()).isEmpty)
    }

    @Test func splitRefusesABadPrefixLength() {
        #expect(codecSplit(codecPacket(10), src: Data([1, 2, 3])).isEmpty)
        #expect(codecSplit(codecPacket(10), dst: Data([0, 0, 0, 0, 0])).isEmpty)
    }

    @Test func splitRefusesMoreThan255Fragments() {
        #expect(codecSplit(codecPacket(148 * 255)).count == 255)
        #expect(codecSplit(codecPacket(148 * 255 + 1)).isEmpty)
    }

    @Test func parseReadsEveryField() throws {
        let raw = Data([0x52, 0x11, 9, 8, 7, 6, 5, 4, 3, 2, 0x12, 0x34, 2, 5, 0xAA, 0xBB])
        let parsed = try #require(ScotMeshRawCodec().parse(raw))
        #expect(parsed.type == .bindRequest)
        #expect(parsed.canRoute)
        #expect(parsed.src == Data([9, 8, 7, 6]))
        #expect(parsed.dst == Data([5, 4, 3, 2]))
        #expect(parsed.packetID == 0x1234)
        #expect(parsed.fragmentIndex == 2)
        #expect(parsed.fragmentTotal == 5)
        #expect(parsed.body == Data([0xAA, 0xBB]))
    }

    @Test func parseAcceptsAHeaderOnlyDatagram() throws {
        let parsed = try #require(ScotMeshRawCodec().parse(codecHeader()))
        #expect(parsed.body.isEmpty)
    }

    @Test func parseRejectsAShortDatagram() {
        #expect(ScotMeshRawCodec().parse(codecHeader().dropLast()) == nil)
    }

    @Test func parseRejectsABadMagic() {
        #expect(ScotMeshRawCodec().parse(codecHeader(magic: 0x58)) == nil)
    }

    @Test func parseRejectsZeroTotal() {
        #expect(ScotMeshRawCodec().parse(codecHeader(index: 0, total: 0)) == nil)
    }

    @Test func parseRejectsIndexAtOrPastTotal() {
        #expect(ScotMeshRawCodec().parse(codecHeader(index: 5, total: 5)) == nil)
        #expect(ScotMeshRawCodec().parse(codecHeader(index: 4, total: 5)) != nil)
    }

    @Test func parseMapsAnUnknownTypeToOther() {
        #expect(ScotMeshRawCodec().parse(codecHeader(flags: 0x03))?.type == .other(3))
    }

    @Test func parseIgnoresTheHighFlagBits() {
        let parsed = ScotMeshRawCodec().parse(codecHeader(flags: 0xE0))
        #expect(parsed?.type == .rnsFragment)
        #expect(parsed?.canRoute == false)
    }

    @Test func parseHandlesANonZeroBasedSlice() {
        let raw = codecHeader(flags: 0x10, index: 1, total: 3, body: [7, 8, 9])
        let slice = (Data([0xFF, 0xFF, 0xFF]) + raw).dropFirst(3)
        #expect(slice.startIndex == 3)
        #expect(ScotMeshRawCodec().parse(slice) == ScotMeshRawCodec().parse(raw))
        #expect(ScotMeshRawCodec().parse(slice)?.body == Data([7, 8, 9]))
    }

    @Test func splitHandlesANonZeroBasedSlice() {
        let packet = codecPacket(300)
        let slice = (Data([0xFF, 0xFF]) + packet).dropFirst(2)
        let src = (Data([9]) + codecSrc).dropFirst()
        let dst = (Data([9]) + codecDst).dropFirst()
        #expect(slice.startIndex == 2)
        #expect(codecSplit(slice, src: src, dst: dst) == codecSplit(packet))
    }

    @Test func scotMeshRawFramingVendsTheCodec() {
        let packet = codecPacket(300)
        let viaFraming = MeshCoreFraming.scotMeshRaw.codec.split(
            packet, type: .rnsFragment, src: codecSrc, dst: codecDst,
            packetID: codecPacketID, canRoute: true)
        let direct = ScotMeshRawCodec().split(
            packet, type: .rnsFragment, src: codecSrc, dst: codecDst,
            packetID: codecPacketID, canRoute: true)
        #expect(viaFraming == direct)
        #expect(!viaFraming.isEmpty)
    }
}
