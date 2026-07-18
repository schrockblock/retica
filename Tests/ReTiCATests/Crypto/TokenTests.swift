import Testing
import Foundation
@testable import ReTiCA

@Test func tokenRejectsWrongKeySize() {
    #expect(throws: TokenError.self) { _ = try Token(key: Data(count: 40)) }
}

@Test func token256RoundTrips() throws {
    let token = try Token(key: Data(repeating: 0x33, count: 64))
    let pt = Data("hello reticulum".utf8)
    let ct = token.encrypt(pt)
    #expect(ct.count >= pt.count + Token.overhead)
    #expect(try token.decrypt(ct) == pt)
}

@Test func token128RoundTrips() throws {
    let token = try Token(key: Data(repeating: 0x44, count: 32))
    let pt = Data("legacy path".utf8)
    #expect(try token.decrypt(token.encrypt(pt)) == pt)
}

@Test func tokenDeterministicLayoutWithFixedIV() throws {
    // AES-256: signKey = key[:32], encKey = key[32:]
    let key = Data((0..<64).map { UInt8($0) })
    let token = try Token(key: key)
    let iv = Data(repeating: 0x01, count: 16)
    let pt = Data("abc".utf8)
    let out = token.encrypt(pt, iv: iv)

    let signKey = key.prefix(32)
    let encKey = key.suffix(32)
    let expectedCT = try AESCBC.encrypt(PKCS7.pad(pt), key: Data(encKey), iv: iv)
    let signed = iv + expectedCT
    let expectedMAC = Crypto.hmacSHA256(key: Data(signKey), signed)
    #expect(out == signed + expectedMAC)
}

@Test func tokenRejectsTamperedHMAC() throws {
    let token = try Token(key: Data(repeating: 0x55, count: 64))
    var ct = token.encrypt(Data("x".utf8))
    ct[ct.count - 1] ^= 0xFF
    #expect(token.verifyHMAC(ct) == false)
    #expect(throws: TokenError.self) { _ = try token.decrypt(ct) }
}
