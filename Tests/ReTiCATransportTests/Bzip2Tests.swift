import Testing
import Foundation
import ReTiCA
@testable import ReTiCATransport

@Suite struct Bzip2Tests {
    @Test func roundTripsCompressibleText() throws {
        let data = Data(String(repeating: "reticulum resource payload ", count: 20).utf8)
        let c = try #require(Bzip2.compress(data))
        #expect(c.count < data.count)                       // genuinely compressed
        #expect(Bzip2.decompress(c, expectedSize: data.count) == data)
    }

    @Test func roundTripsRandomData() throws {
        // Incompressible: bz2 output is >= input, but decompress must still recover it exactly.
        let data = Data((0..<256).map { UInt8(($0 * 37 + 11) & 0xff) })
        let c = try #require(Bzip2.compress(data))
        #expect(Bzip2.decompress(c, expectedSize: data.count) == data)
    }

    @Test func roundTripsEmpty() throws {
        let c = try #require(Bzip2.compress(Data()))
        #expect(Bzip2.decompress(c, expectedSize: 0) == Data())
    }

    @Test func decompressRejectsGarbage() {
        #expect(Bzip2.decompress(Data([0x00, 0x01, 0x02, 0x03]), expectedSize: 10) == nil)
    }

    // `expectedSize` is attacker-controlled; sizes above UInt32.max used to TRAP before this fix.
    // A size above AUTO_COMPRESS_MAX_SIZE must return nil, never trap and never allocate.
    @Test func decompressRejectsAbsurdExpectedSize() throws {
        let compressed = try #require(Bzip2.compress(Data(repeating: 0x41, count: 1024)))
        // Above UInt32.max: old code unconditionally trapped here.
        #expect(Bzip2.decompress(compressed, expectedSize: Int(UInt32.max) + 1) == nil)
        // Above AUTO_COMPRESS_MAX_SIZE ceiling: must also be nil.
        #expect(Bzip2.decompress(compressed, expectedSize: Resource.autoCompressMaxSize + 1) == nil)
        // A legitimate size still round-trips.
        #expect(Bzip2.decompress(compressed, expectedSize: 1024)?.count == 1024)
    }
}

// MARK: - Allocation is driven by content, not by the declared ceiling
//
// `Scripts/check-wire-narrowing.swift` CANNOT see this defect — it is not a narrowing conversion.
// These tests are its only regression guard. They assert on the buffer the implementation actually
// allocates (via `decompressReportingAllocation`) rather than on elapsed time or resident memory,
// because a measured assertion of either kind is the first thing to flake on a loaded machine.

@Suite struct Bzip2AllocationTests {
    /// The defect, exactly: a *tiny* compressed stream plus a *large* declared size. `expectedSize`
    /// comes from a RESOURCE_ADV's `d` field, so it is a claim by the sender; sizing the output
    /// buffer from it let ~41 bytes of attacker-chosen input reserve 64 MiB, repeatable per
    /// advertisement. Allocation must track what was produced, not what was claimed.
    @Test func decompressAllocatesForContentNotForTheDeclaredCeiling() throws {
        let payload = Data("x".utf8)
        let tiny = try #require(Bzip2.compress(payload))
        #expect(tiny.count < 64)                                  // the whole attack fits in a tweet
        let r = try #require(Bzip2.decompressReportingAllocation(
            tiny, expectedSize: Resource.autoCompressMaxSize))     // the ceiling, i.e. 64 MiB
        #expect(r.data == payload)                                 // still correct
        #expect(r.allocatedBytes <= 64 * 1024)                     // was 67_108_864
    }

    /// Growth must follow the output. A payload far larger than the initial buffer still decodes
    /// exactly, while the buffer stays proportional to the bytes produced — not to the 64 MiB claim.
    @Test func decompressGrowsWithProducedOutputNotWithTheClaim() throws {
        let payload = Data(String(repeating: "reticulum resource payload ", count: 12_000).utf8)
        #expect(payload.count > 256 * 1024)
        let c = try #require(Bzip2.compress(payload))
        let r = try #require(Bzip2.decompressReportingAllocation(
            c, expectedSize: Resource.autoCompressMaxSize))
        #expect(r.data == payload)                                 // byte-exact through the growth loop
        #expect(r.allocatedBytes <= 2 * payload.count)             // doubling overshoots by at most 2x
        #expect(r.allocatedBytes < Resource.autoCompressMaxSize)   // never the ceiling
    }

    /// `expectedSize` is an UPPER BOUND, never an exact size. The split path passes
    /// `min(adv.dataSize, LinkSession.maxEfficientSize)` where `adv.dataSize` is the WHOLE object's
    /// size, so a segment's real output is routinely much smaller. Requiring an exact fit would cap
    /// every multi-segment transfer silently.
    @Test func decompressTreatsExpectedSizeAsAnUpperBoundNotAnExactSize() throws {
        let payload = Data(String(repeating: "segment ", count: 100).utf8)
        let c = try #require(Bzip2.compress(payload))
        // Exactly what ResourceTransfer's split branch passes for a small final segment.
        let r = try #require(Bzip2.decompressReportingAllocation(
            c, expectedSize: LinkSession.maxEfficientSize))
        #expect(r.data == payload)
        #expect(r.allocatedBytes <= 64 * 1024)
    }

    /// Reference treats "cap reached with input remaining" as CORRUPT, not as success: it checks
    /// `decompressor.eof` after `decompress(max_length=...)` and cancels the resource
    /// (`Resource.assemble`, RNS/Resource.py:690-696). Truncating instead would be worse than the
    /// allocation this task fixes — a partial buffer that looks like data.
    @Test func decompressRejectsOutputExceedingExpectedSizeRatherThanTruncating() throws {
        let payload = Data(String(repeating: "reticulum ", count: 200).utf8)   // 2000 bytes
        let c = try #require(Bzip2.compress(payload))
        #expect(Bzip2.decompress(c, expectedSize: payload.count) == payload)   // exact fit is fine
        #expect(Bzip2.decompress(c, expectedSize: payload.count - 1) == nil)   // one short → nil
        #expect(Bzip2.decompress(c, expectedSize: 10) == nil)                  // not a 10-byte prefix
        #expect(Bzip2.decompress(c, expectedSize: 0) == nil)
    }

    /// Fail closed: a stream that ends mid-way yields nil, never the bytes decoded so far. The
    /// incremental loop has a partial buffer in hand at that moment, so this is the invariant most
    /// at risk from the change.
    @Test func decompressRejectsTruncatedStreamWithoutReturningAPartialResult() throws {
        let payload = Data(String(repeating: "reticulum ", count: 200).utf8)
        let c = try #require(Bzip2.compress(payload))
        for dropped in [1, 8, c.count / 2] {
            #expect(Bzip2.decompress(c.prefix(c.count - dropped), expectedSize: payload.count) == nil)
        }
    }
}
