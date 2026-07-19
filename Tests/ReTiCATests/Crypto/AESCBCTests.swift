import Testing
import Foundation
@testable import ReTiCA

// NIST SP 800-38A F.2.1 AES-128-CBC encrypt, first block.
@Test func aes128CBCMatchesNISTFirstBlock() throws {
    let key = Data(hexString: "2b7e151628aed2a6abf7158809cf4f3c")!
    let iv  = Data(hexString: "000102030405060708090a0b0c0d0e0f")!
    let pt  = Data(hexString: "6bc1bee22e409f96e93d7e117393172a")!
    let ct  = try AESCBC.encrypt(pt, key: key, iv: iv)
    #expect(ct.hexString == "7649abac8119b246cee98e9b12e9197d")
    #expect(try AESCBC.decrypt(ct, key: key, iv: iv) == pt)
}

@Test func aes256CBCRoundTrips() throws {
    let key = Data(repeating: 0x24, count: 32)
    let iv  = Data(repeating: 0x11, count: 16)
    let pt  = Data(repeating: 0xab, count: 48)
    let ct  = try AESCBC.encrypt(pt, key: key, iv: iv)
    #expect(ct != pt)
    #expect(try AESCBC.decrypt(ct, key: key, iv: iv) == pt)
}

@Test func aesRejectsBadKeySize() {
    #expect(throws: AESError.self) {
        _ = try AESCBC.encrypt(Data(count: 16), key: Data(count: 20), iv: Data(count: 16))
    }
}
