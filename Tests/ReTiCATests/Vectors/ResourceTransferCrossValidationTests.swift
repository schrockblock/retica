import Testing
import Foundation
@testable import ReTiCA

@Test func swiftResourceRequestPlaintextMatchesReference() throws {
    let f = try VectorFixtures.load()
    // The single-window request the receiver builds: 0x00 ‖ resource_hash ‖ full hashmap.
    let built = Data([0x00]) + Data(hexString: f.resourceHash)! + referenceHashmap(f)
    #expect(built == Data(hexString: f.resourceRequestPlaintext))
}

// The full hashmap for the reference stream: map hash of each SDU-sized ciphertext chunk.
private func referenceHashmap(_ f: VectorFixtures) -> Data {
    let stream = Data(hexString: f.resourceStream)!
    let r = Data(hexString: f.resourceRandomHash)!
    var m = Data()
    var i = stream.startIndex
    while i < stream.endIndex {
        let end = stream.index(i, offsetBy: f.resourceSdu, limitedBy: stream.endIndex) ?? stream.endIndex
        m.append(Resource.mapHash(chunk: Data(stream[i..<end]), randomHash: r))
        i = end
    }
    return m
}
