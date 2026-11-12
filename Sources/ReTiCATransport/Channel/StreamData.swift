import Foundation

/// The 2-byte header of an RNS 1.6.0 `StreamDataMessage` (Buffer.py:44-98), the payload of a Channel
/// envelope of system type `0xFF00`. Big-endian: the low 14 bits are the stream id, `0x8000` is EOF
/// and `0x4000` says the data that follows is bz2-compressed.
public struct StreamDataHeader: Equatable, Sendable {
    /// `StreamDataMessage.STREAM_ID_MAX` (Buffer.py:51).
    public static let streamIDMax: UInt16 = 0x3FFF
    /// `StreamDataMessage.HEADER_LEN` (Buffer.py:56).
    public static let length = 2

    /// 0...0x3FFF on the wire. `packed()` masks a larger value, as the reference's `pack` does.
    public var streamID: UInt16
    public var eof: Bool
    public var compressed: Bool

    public init(streamID: UInt16, eof: Bool, compressed: Bool) {
        self.streamID = streamID
        self.eof = eof
        self.compressed = compressed
    }

    /// `(0x3fff & stream_id) | eof 0x8000 | compressed 0x4000`, big-endian (Buffer.py:85-86).
    public func packed() -> Data {
        let value = (streamID & Self.streamIDMax) | (eof ? 0x8000 : 0) | (compressed ? 0x4000 : 0)
        return Data([UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    /// The header and the data after it; nil when shorter than the header, where the reference's
    /// `struct.unpack(">H", raw[:2])` raises (Buffer.py:89). The data is not decompressed here.
    public static func parse(_ raw: Data) -> (StreamDataHeader, Data)? {
        guard raw.count >= length else { return nil }
        let base = raw.startIndex
        let value = UInt16(truncatingIfNeeded: raw[base]) << 8 | UInt16(truncatingIfNeeded: raw[base + 1])
        let header = StreamDataHeader(streamID: value & streamIDMax, eof: value & 0x8000 != 0,
                                      compressed: value & 0x4000 != 0)
        return (header, Data(raw[(base + length)...]))
    }
}

/// `RawChannelWriter`'s chunking (Buffer.py:217-262) and `StreamDataMessage.unpack`'s inflation
/// (Buffer.py:95-98), as pure functions.
public enum StreamChunker {
    /// `RawChannelWriter.MAX_CHUNK_LEN` (Buffer.py:217): the most one write takes, and the most a
    /// compressed chunk may inflate to.
    public static let maxChunkLen = 16 * 1024
    /// `RawChannelWriter.COMPRESSION_TRIES` (Buffer.py:218): tries 1, 2 and 3 are made.
    public static let compressionTries = 4

    /// What one `RawChannelWriter.write` sends (Buffer.py:232-262): the chunk's data, whether it is
    /// compressed, and how many input bytes it consumed. `writerMDU` is the writer's `_mdu`, the
    /// channel MDU less the 2-byte header (Buffer.py:230).
    ///
    /// Longer than 32 bytes, it tries bz2 on the first `int(chunk_len/comp_try)` bytes for tries 1-3
    /// and takes the first result smaller than both `writerMDU` and its input segment. Otherwise it
    /// sends the first `writerMDU` bytes as they are. Integer division equals the reference's
    /// `int(a/b)` here: both are non-negative and far below 2^53.
    public static func chunk(_ input: Data, writerMDU: Int) -> (payload: Data, compressed: Bool, consumed: Int) {
        let bytes = Data(input.prefix(maxChunkLen))                       // Buffer.py:238-240
        let chunkLen = bytes.count
        var compTry = 1
        while chunkLen > 32 && compTry < compressionTries {               // Buffer.py:242
            let segmentLength = chunkLen / compTry                        // Buffer.py:243
            if let compressed = Bzip2.compress(Data(bytes.prefix(segmentLength))),
               compressed.count < writerMDU && compressed.count < segmentLength {  // Buffer.py:246
                return (compressed, true, segmentLength)                  // Buffer.py:252-254
            }
            compTry += 1
        }
        let raw = Data(bytes.prefix(max(writerMDU, 0)))                   // Buffer.py:256-257
        return (raw, false, raw.count)
    }

    /// The stream bytes a chunk carries: `data` itself, or `data` inflated. Nil when the bz2 is bad,
    /// truncated or empty, or when it does not END within `maxChunkLen` of output: the reference
    /// inflates with `max_length=MAX_CHUNK_LEN` and then raises unless `decompressor.eof`
    /// (Buffer.py:95-98). `Bzip2.decompress` returns nil in exactly those cases: it fails on a
    /// stream that would produce more than `expectedSize`, never handing back the prefix, and it
    /// never allocates past `expectedSize`. Bytes after the end of the bz2 stream are ignored, as
    /// Python's `BZ2Decompressor` leaves them in `unused_data`.
    public static func decodeStreamPayload(_ header: StreamDataHeader, _ data: Data) -> Data? {
        guard header.compressed else { return data }
        return Bzip2.decompress(data, expectedSize: maxChunkLen)
    }
}
