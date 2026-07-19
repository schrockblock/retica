import Testing
import Foundation
@testable import ReTiCA

// RFC 5869 Appendix A.1 (SHA-256, L=42)
@Test func hkdfMatchesRFC5869Case1() {
    let ikm = Data(repeating: 0x0b, count: 22)
    let salt = Data(hexString: "000102030405060708090a0b0c")!
    let info = Data(hexString: "f0f1f2f3f4f5f6f7f8f9")!
    let okm = Crypto.hkdf(length: 42, derivedFrom: ikm, salt: salt, context: info)
    #expect(okm.hexString ==
        "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
}

@Test func hkdfEmptySaltUsesZeroBlock() {
    // With salt nil, PRK = HMAC(32 zero bytes, ikm). Length one block.
    let okm = Crypto.hkdf(length: 32, derivedFrom: Data("ikm".utf8), salt: nil, context: nil)
    let prk = Crypto.hmacSHA256(key: Data(repeating: 0, count: 32), Data("ikm".utf8))
    let expected = Crypto.hmacSHA256(key: prk, Data([0x01]))
    #expect(okm == expected)
}

@Test func hkdf64ByteOutputIsTwoBlocks() {
    let okm = Crypto.hkdf(length: 64, derivedFrom: Data("x".utf8),
                          salt: Data("salt".utf8), context: nil)
    #expect(okm.count == 64)
}
