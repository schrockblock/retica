import Foundation
import Cbzip2
import ReTiCA

/// Thin wrapper over the vendored reference libbzip2 (one-shot buffer APIs). Compression parameters
/// (blockSize100k = 9, workFactor = 0) match Python's `bz2.compress(data, 9)` byte-for-byte.
enum Bzip2 {
    static func compress(_ data: Data) -> Data? {
        // libbzip2 documented worst-case output bound: srcLen + srcLen/100 + 600.
        var destLen = UInt32(data.count + data.count / 100 + 600)
        var dest = [UInt8](repeating: 0, count: Int(destLen))
        // BZ2 takes a non-const char* source; give it its own mutable buffer (non-nil even when empty).
        var src = [UInt8](repeating: 0, count: max(data.count, 1))
        data.copyBytes(to: &src, count: data.count)
        let rc = dest.withUnsafeMutableBufferPointer { d -> Int32 in
            src.withUnsafeMutableBufferPointer { s in
                BZ2_bzBuffToBuffCompress(
                    d.baseAddress!.withMemoryRebound(to: CChar.self, capacity: d.count) { $0 }, &destLen,
                    s.baseAddress!.withMemoryRebound(to: CChar.self, capacity: s.count) { $0 },
                    UInt32(data.count), 9, 0, 0)
            }
        }
        guard rc == BZ_OK else { return nil }
        return Data(dest.prefix(Int(destLen)))
    }

    static func decompress(_ data: Data, expectedSize: Int) -> Data? {
        guard !data.isEmpty else { return expectedSize == 0 ? Data() : nil }
        // `expectedSize` is attacker-controlled (it comes from a RESOURCE_ADV's `d` field), so it
        // is a claim, not a fact. Above UInt32.max the old `UInt32(...)` conversion TRAPPED before
        // allocating; between 1-4 GiB it allocated for real. Reference clamps to
        // AUTO_COMPRESS_MAX_SIZE and checks decompressor.eof (RNS/Resource.py:360, 690-696).
        // expectedSize == 0 is legitimate (compressed empty payload); only the over-large case is hostile.
        guard expectedSize >= 0, expectedSize <= Resource.autoCompressMaxSize else { return nil }
        let bufSize = max(expectedSize, 1)   // libbzip2 requires a non-null dest pointer
        var destLen = UInt32(bufSize)
        var dest = [UInt8](repeating: 0, count: bufSize)
        var src = [UInt8](repeating: 0, count: data.count)
        data.copyBytes(to: &src, count: data.count)
        let rc = dest.withUnsafeMutableBufferPointer { d -> Int32 in
            src.withUnsafeMutableBufferPointer { s in
                BZ2_bzBuffToBuffDecompress(
                    d.baseAddress!.withMemoryRebound(to: CChar.self, capacity: d.count) { $0 }, &destLen,
                    s.baseAddress!.withMemoryRebound(to: CChar.self, capacity: s.count) { $0 },
                    UInt32(data.count), 0, 0)
            }
        }
        guard rc == BZ_OK else { return nil }
        return Data(dest.prefix(Int(destLen)))
    }
}
