import Foundation
import Testing
@testable import ReTiCAKeychain

/// RFC 4648 §10 vectors — what Python's base64.b32encode / b32decode produce and accept.
@Suite("IdentityBackup base32")
struct IdentityBackupTests {
    private let vectors: [(String, String)] = [
        ("", ""), ("f", "MY======"), ("fo", "MZXQ===="), ("foo", "MZXW6==="),
        ("foob", "MZXW6YQ="), ("fooba", "MZXW6YTB"), ("foobar", "MZXW6YTBOI======"),
    ]

    @Test func encodesTheRFCVectors() {
        for (plain, encoded) in vectors {
            #expect(IdentityBackup.base32(Data(plain.utf8)) == encoded)
        }
    }

    @Test func decodesWithAndWithoutPadding() {
        for (plain, encoded) in vectors {
            #expect(IdentityBackup.decodeBase32(encoded) == Data(plain.utf8))
            let unpadded = String(encoded.filter { $0 != "=" })
            #expect(IdentityBackup.decodeBase32(unpadded) == Data(plain.utf8))
        }
    }

    @Test func roundTripsAn64ByteKey() {
        var bytes = [UInt8](repeating: 0, count: 64)
        for i in 0..<64 { bytes[i] = UInt8((i * 37 + 11) & 0xFF) }
        let data = Data(bytes)
        let text = IdentityBackup.base32(data)
        #expect(text.count == 104)          // 64 bytes → 103 symbols + 1 pad
        #expect(text.hasSuffix("="))
        #expect(IdentityBackup.decodeBase32(text) == data)
    }

    @Test func rejectsNonCanonicalInput() {
        #expect(IdentityBackup.decodeBase32("mzxw6===") == nil)      // lowercase
        #expect(IdentityBackup.decodeBase32("MZXW6Y=") == nil)       // wrong pad count
        #expect(IdentityBackup.decodeBase32("MZXW6YTBO") == nil)     // impossible length (remainder 1)
        #expect(IdentityBackup.decodeBase32("MZXW6YR=") == nil)      // non-zero trailing bits
        #expect(IdentityBackup.decodeBase32("MZXW6===\n") == nil)    // callers trim; the codec does not
        #expect(IdentityBackup.decodeBase32("MZXW1===") == nil)      // '1' is not in the alphabet
        #expect(IdentityBackup.decodeBase32("========") == nil)      // padding only
    }
}
