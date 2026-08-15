import Foundation
import Cbzip2
import ReTiCA

/// Thin wrapper over the vendored reference libbzip2.
///
/// Compression uses the one-shot buffer API; its parameters (blockSize100k = 9, workFactor = 0)
/// match Python's `bz2.compress(data, 9)` byte-for-byte and are load-bearing — do not change them.
///
/// Decompression is **incremental** (`BZ2_bzDecompressInit`/`BZ2_bzDecompress`/`BZ2_bzDecompressEnd`).
/// The one-shot `BZ2_bzBuffToBuffDecompress` requires the entire destination buffer to exist before
/// any output does, which meant a *wire-declared* size sized the allocation. See
/// `decompressReportingAllocation`.
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

    // MARK: - Decompression

    /// Floor for the first output allocation: one 4 KiB page. Ordinary payloads land in a single
    /// allocation and the growth loop never runs, while a hostile 41-byte stream costs 4 KiB rather
    /// than the 64 MiB it used to.
    private static let initialOutputCapacity = 4096

    /// libbzip2's `avail_in`/`avail_out` are `unsigned int`, so one call can see at most this much
    /// of either; the loop re-supplies the remainder. Nothing here comes close (output is bounded by
    /// `expectedSize` <= 64 MiB), but bounding the window is what makes the `UInt32` conversions in
    /// the loop exact by construction rather than merely unlikely to overflow.
    private static let bzWindowMax = 0xFFFF_FFFF

    static func decompress(_ data: Data, expectedSize: Int) -> Data? {
        decompressReportingAllocation(data, expectedSize: expectedSize)?.data
    }

    /// `decompress`, plus the high-water mark of the output buffer it allocated.
    ///
    /// **The allocation is the contract here**, and it is invisible in the returned bytes — so it is
    /// reported and asserted on in `Bzip2AllocationTests`. `Scripts/check-wire-narrowing.swift`
    /// cannot see this defect (it is not a narrowing conversion), so those tests are its *only*
    /// regression guard. A timing or resident-memory assertion would flake; this makes it binary.
    ///
    /// `expectedSize` derives from a RESOURCE_ADV's `d` field, so it is a claim, not a fact. It
    /// bounds what we ACCEPT; it must never size what we ALLOCATE. Sizing the buffer from it let
    /// ~41 bytes of attacker-chosen input reserve 64 MiB, repeatable per advertisement.
    ///
    /// It is also an **upper bound, never an exact size**: `ResourceTransfer`'s split branch passes
    /// `min(adv.dataSize, LinkSession.maxEfficientSize)` where `adv.dataSize` is the WHOLE object's
    /// size, so a segment's real output is routinely much smaller. Requiring an exact fit would cap
    /// every multi-segment transfer — silently, which is worse than failing.
    ///
    /// Reference shape (`Resource.assemble`, RNS/Resource.py:690-696): an incremental
    /// `bz2.BZ2Decompressor().decompress(data, max_length=self.max_decompressed_size)` followed by
    /// `if not decompressor.eof:` → CORRUPT + cancel. So "cap reached with input remaining" is a
    /// **failure**, not a truncated success; we return nil, never a partial buffer.
    static func decompressReportingAllocation(
        _ data: Data, expectedSize: Int
    ) -> (data: Data, allocatedBytes: Int)? {
        guard !data.isEmpty else { return expectedSize == 0 ? (Data(), 0) : nil }
        // Above UInt32.max the old `UInt32(...)` conversion TRAPPED before allocating; between
        // 1-4 GiB it allocated for real. Reference caps at AUTO_COMPRESS_MAX_SIZE (`Resource.__init__`
        // sets `max_decompressed_size`, RNS/Resource.py:360). This is the LAST line of defence, not
        // the only one: a caller that writes `Int(someWireUInt64)` traps before we are ever called.
        guard expectedSize <= Resource.autoCompressMaxSize else { return nil }
        let ceiling = max(expectedSize, 0)

        var src = [CChar](repeating: 0, count: data.count)
        src.withUnsafeMutableBytes { data.copyBytes(to: $0) }

        // Start small and double as output appears. The first allocation is bounded by the
        // attacker's own input length — a bzip2 stream is never shorter than the bytes they had to
        // send — with a page floor so ordinary payloads need no growth at all. Peak allocation
        // therefore tracks CONTENT (within 2x, from the doubling), never the claim.
        // `ceiling` may be 0: a compressed *empty* payload is legitimate, and libbzip2 still needs a
        // non-null `next_out`, so the buffer is at least one byte and `produced` is checked below.
        var capacity = min(max(ceiling, 1), max(initialOutputCapacity, data.count))
        var dest = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { dest.deallocate() }
        var allocatedHighWater = capacity

        var strm = bz_stream()                       // zero-initialised: bzalloc/bzfree/opaque nil → malloc/free
        guard BZ2_bzDecompressInit(&strm, 0, 0) == BZ_OK else { return nil }   // verbosity 0, small 0
        defer { BZ2_bzDecompressEnd(&strm) }

        var consumed = 0
        var produced = 0
        return src.withUnsafeMutableBufferPointer { s -> (data: Data, allocatedBytes: Int)? in
            while true {
                let inWindow = min(data.count - consumed, bzWindowMax)
                let outWindow = min(capacity - produced, bzWindowMax)
                strm.next_in = s.baseAddress! + consumed
                strm.avail_in = UInt32(clamping: inWindow)          // exact: inWindow <= bzWindowMax
                strm.next_out = dest + produced
                strm.avail_out = UInt32(clamping: outWindow)        // exact: outWindow <= bzWindowMax
                let rc = BZ2_bzDecompress(&strm)
                // Track by delta against the window we handed over, so a window clamped to
                // `bzWindowMax` still accounts correctly.
                let ate = inWindow - Int(strm.avail_in)
                let made = outWindow - Int(strm.avail_out)
                consumed += ate
                produced += made

                if rc == BZ_STREAM_END {
                    // Trailing bytes after the stream end are ignored, exactly as the one-shot API
                    // did (bzlib.c:1331-1334) and as Python's BZ2Decompressor does (`unused_data`).
                    guard produced <= ceiling else { return nil }
                    return (Data(bytes: dest, count: produced), allocatedHighWater)
                }
                guard rc == BZ_OK else { return nil }               // BZ_DATA_ERROR &c — fail closed

                if produced == capacity {
                    // Out of room. Grow, unless we are already at the declared size — in which case
                    // the stream wants to produce more than was claimed, which reference calls
                    // CORRUPT. Fail; never hand back the prefix decoded so far.
                    guard capacity < max(ceiling, 1) else { return nil }
                    let grown = min(max(ceiling, 1), capacity * 2)
                    let bigger = UnsafeMutablePointer<CChar>.allocate(capacity: grown)
                    bigger.update(from: dest, count: produced)
                    dest.deallocate()
                    dest = bigger
                    capacity = grown
                    allocatedHighWater = max(allocatedHighWater, capacity)
                    continue
                }
                // Room to spare, so BZ_OK means libbzip2 wants more input. If there is none the
                // stream ended mid-way: truncated or corrupt. The progress check is a belt-and-braces
                // bound on the loop itself — a call that neither ate nor made anything would spin.
                guard consumed < data.count, ate > 0 || made > 0 else { return nil }
            }
        }
    }
}
