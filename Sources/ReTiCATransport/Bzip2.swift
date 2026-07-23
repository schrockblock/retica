import Foundation
import Cbzip2

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
        var destLen = UInt32(max(expectedSize, 1))
        var dest = [UInt8](repeating: 0, count: Int(destLen))
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
