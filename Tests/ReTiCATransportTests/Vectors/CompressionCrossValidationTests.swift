import Testing
import Foundation
@testable import ReTiCATransport
@testable import ReTiCA

@Test func swiftCompressMatchesPythonBz2ByteForByte() throws {
    let f = try TransportVectorFixtures.load()
    let original = Data(hexString: f.bz2Original)!
    let expected = Data(hexString: f.bz2Compressed)!
    #expect(Bzip2.compress(original) == expected)          // byte-identical to Python bz2.compress(x, 9)
}

@Test func swiftDecompressesGenuineRnsBz2Stream() throws {
    let f = try TransportVectorFixtures.load()
    let compressed = Data(hexString: f.bz2Compressed)!
    let original = Data(hexString: f.bz2Original)!
    #expect(Bzip2.decompress(compressed, expectedSize: f.bz2OriginalLen) == original)
}
