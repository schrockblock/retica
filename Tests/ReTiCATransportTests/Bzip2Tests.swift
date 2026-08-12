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
