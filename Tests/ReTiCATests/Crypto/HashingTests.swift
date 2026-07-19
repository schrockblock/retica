import Testing
import Foundation
@testable import ReTiCA

// NIST SHA-256 known answer: SHA256("abc")
@Test func fullHashMatchesNISTVector() {
    let digest = Crypto.fullHash(Data("abc".utf8))
    #expect(digest.hexString == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(digest.count == 32)
}

@Test func truncatedHashIsFirst16BytesOfFullHash() {
    let data = Data("reticulum".utf8)
    let full = Crypto.fullHash(data)
    let truncated = Crypto.truncatedHash(data)
    #expect(truncated.count == 16)
    #expect(truncated == full.prefix(16))
}

@Test func randomHashIs16BytesAndVaries() {
    let a = Crypto.randomHash()
    let b = Crypto.randomHash()
    #expect(a.count == 16)
    #expect(a != b)
}
