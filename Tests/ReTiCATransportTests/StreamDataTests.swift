import Testing
import Foundation
@testable import ReTiCATransport

// RNS 1.6.0 Buffer's stream header and chunk inflation (Buffer.py:81-98). Observed against the
// reference (rns-latest, a real Channel with a RawChannelReader): a compressed chunk that inflates
// past 16 KiB, a truncated one, an empty compressed body and a 1-byte payload all raise in unpack;
// exactly 16 KiB is accepted; bytes after the end of the bz2 stream are ignored.

private func compressed(_ data: Data) throws -> Data {
    try #require(Bzip2.compress(data))
}

private let compressedHeader = StreamDataHeader(streamID: 1, eof: false, compressed: true)

@Test func aChunkThatInflatesPastSixteenKiBIsRejected() throws {
    let bomb = try compressed(Data(repeating: 0, count: 17_000))
    #expect(bomb.count < 100)
    #expect(StreamChunker.decodeStreamPayload(compressedHeader, bomb) == nil)
    // One byte past the cap is past it.
    #expect(StreamChunker.decodeStreamPayload(compressedHeader,
                                              try compressed(Data(repeating: 0, count: 16_385))) == nil)
}

@Test func aChunkThatInflatesToExactlySixteenKiBIsAccepted() throws {
    let exact = Data(repeating: 0, count: StreamChunker.maxChunkLen)
    #expect(StreamChunker.decodeStreamPayload(compressedHeader, try compressed(exact)) == exact)
}

@Test func aTruncatedCompressedChunkIsRejected() throws {
    let input = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0 * 7) })
    let whole = try compressed(input)
    #expect(StreamChunker.decodeStreamPayload(compressedHeader, whole) == input)
    #expect(StreamChunker.decodeStreamPayload(compressedHeader, Data(whole.dropLast(5))) == nil)
    #expect(StreamChunker.decodeStreamPayload(compressedHeader, Data()) == nil)
}

@Test func bytesAfterTheEndOfTheBz2StreamAreIgnored() throws {
    let data = try compressed(Data("xyz".utf8)) + Data("junk".utf8)
    #expect(StreamChunker.decodeStreamPayload(compressedHeader, data) == Data("xyz".utf8))
}

@Test func anUncompressedChunkIsTakenAsItIs() {
    let header = StreamDataHeader(streamID: 1, eof: false, compressed: false)
    #expect(StreamChunker.decodeStreamPayload(header, Data([0xBA, 0xD0])) == Data([0xBA, 0xD0]))
    #expect(StreamChunker.decodeStreamPayload(header, Data()) == Data())
}

@Test func aHeaderNeedsTwoBytes() throws {
    #expect(StreamDataHeader.parse(Data()) == nil)
    #expect(StreamDataHeader.parse(Data([0x80])) == nil)
    let (header, rest) = try #require(StreamDataHeader.parse(Data([0xAA, 0xC0, 0x01, 0x02]).dropFirst(1)))
    #expect(header == StreamDataHeader(streamID: 1, eof: true, compressed: true))
    #expect(rest == Data([0x02]))
}

@Test func theChunkingConstantsMatchTheReference() {
    #expect(StreamChunker.maxChunkLen == 16_384)
    #expect(StreamChunker.compressionTries == 4)
    #expect(StreamDataHeader.streamIDMax == 0x3FFF)
    #expect(StreamDataHeader.length == 2)
}
