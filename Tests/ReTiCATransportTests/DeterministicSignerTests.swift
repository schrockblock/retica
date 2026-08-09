import Testing
import Foundation
import CryptoKit
@testable import ReTiCATransport

private func hexBytes(_ s: String) -> Data {
    Data(stride(from: 0, to: s.count, by: 2).map { i in
        let a = s.index(s.startIndex, offsetBy: i)
        let b = s.index(a, offsetBy: 2)
        return UInt8(s[a..<b], radix: 16)!
    })
}
private func hexString(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

/// RFC 8032 section 7.1 TEST 1 (empty message). Pins the dependency to the standard:
/// a substituted or altered Ed25519 cannot reproduce this signature.
@Test func deterministicSignerMatchesRFC8032Test1() {
    let seed = hexBytes("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
    let sig = DeterministicSigner.sign(message: Data(), seed: seed)
    #expect(hexString(sig) == "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
}

/// RFC 8032 section 7.1 TEST 2 (one-byte message 0x72).
@Test func deterministicSignerMatchesRFC8032Test2() {
    let seed = hexBytes("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
    let sig = DeterministicSigner.sign(message: Data([0x72]), seed: seed)
    #expect(hexString(sig) == "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")
}

/// THE property IFAC depends on: signing the same message with the same seed twice must
/// be byte-identical. CryptoKit's Ed25519 is hedged and fails this — which is exactly why
/// this dependency exists.
@Test func deterministicSignerIsByteReproducible() {
    let seed = hexBytes("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
    let msg = Data("ifac reproducibility".utf8)
    #expect(DeterministicSigner.sign(message: msg, seed: seed)
            == DeterministicSigner.sign(message: msg, seed: seed))
}

/// Interop anchor: the signer must live in the SAME Ed25519 universe as the CryptoKit
/// identity layer — same public key from the same seed, and CryptoKit must accept its
/// signatures. Guards against a "deterministic but subtly different curve" substitution.
@Test func deterministicSignerInteroperatesWithCryptoKit() throws {
    let seed = hexBytes("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
    let ck = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    #expect(hexString(Data(ck.publicKey.rawRepresentation))
            == "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")
    let msg = Data("cross-implementation check".utf8)
    let sig = DeterministicSigner.sign(message: msg, seed: seed)
    #expect(ck.publicKey.isValidSignature(sig, for: msg))
}
