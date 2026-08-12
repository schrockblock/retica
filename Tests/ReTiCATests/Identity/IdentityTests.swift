import Testing
import Foundation
import CryptoKit
@testable import ReTiCA

@Test func generatedIdentityHasCorrectSizes() {
    let id = Identity()
    #expect(id.publicKey.count == 64)
    #expect(id.privateKey?.count == 64)
    #expect(id.hash.count == 16)
    #expect(id.hexHash == id.hash.hexString)
}

@Test func hashIsTruncatedHashOfPublicKey() {
    let id = Identity()
    #expect(id.hash == Crypto.truncatedHash(id.publicKey))
}

@Test func privateKeyRoundTripsThroughBytes() {
    let original = Identity()
    let restored = Identity(privateKey: original.privateKey!)
    #expect(restored != nil)
    #expect(restored?.publicKey == original.publicKey)
    #expect(restored?.hash == original.hash)
}

@Test func publicOnlyIdentityHasNoPrivateKey() {
    let full = Identity()
    let pub = Identity(publicKey: full.publicKey)
    #expect(pub?.privateKey == nil)
    #expect(pub?.hash == full.hash)
}

@Test func rejectsWrongSizedKeys() {
    #expect(Identity(privateKey: Data(count: 32)) == nil)
    #expect(Identity(publicKey: Data(count: 10)) == nil)
}

@Test func signAndValidateRoundTrip() {
    let id = Identity()
    let msg = Data("prove it".utf8)
    let sig = id.sign(msg)
    #expect(sig.count == 64)
    #expect(id.validate(signature: sig, message: msg) == true)
    #expect(id.validate(signature: sig, message: Data("tampered".utf8)) == false)
}

@Test func encryptDecryptRoundTrip() {
    let id = Identity()
    let pt = Data("secret payload".utf8)
    let decrypted = id.decrypt(id.encrypt(pt))
    #expect(decrypted == pt)
}

@Test func encryptOutputStartsWithEphemeralKeyAndDecryptsDeterministically() throws {
    let id = Identity()
    let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    let iv = Data(repeating: 0x07, count: 16)
    let pt = Data("determinism".utf8)
    let out = id.encrypt(pt, ratchet: nil,
                         ephemeralPrivateKey: ephemeral.rawRepresentation, iv: iv)
    #expect(out.prefix(32) == ephemeral.publicKey.rawRepresentation)
    #expect(id.decrypt(out) == pt)
}

@Test func decryptWithRatchetKey() {
    let id = Identity()
    let ratchetPriv = Curve25519.KeyAgreement.PrivateKey()
    let ratchetPub = ratchetPriv.publicKey.rawRepresentation
    let pt = Data("ratcheted".utf8)
    let ct = id.encrypt(pt, ratchet: ratchetPub)
    // Static key cannot decrypt a ratchet-encrypted token.
    #expect(id.decrypt(ct) == nil)
    // Providing the ratchet private key recovers it.
    #expect(id.decrypt(ct, ratchets: [ratchetPriv.rawRepresentation]) == pt)
}

@Test func decryptReturnsNilOnGarbage() {
    let id = Identity()
    #expect(id.decrypt(Data(repeating: 0, count: 10)) == nil)
}

@Test func publicOnlyIdentityDecryptReturnsNil() {
    let full = Identity()
    let ct = full.encrypt(Data("x".utf8))
    let pub = Identity(publicKey: full.publicKey)!
    #expect(pub.decrypt(ct) == nil)
}

@Test func enforceRatchetsRejectsWhenNoRatchetMatches() {
    let id = Identity()
    let ct = id.encrypt(Data("y".utf8)) // encrypted to the STATIC key, no ratchet
    let wrongRatchet = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    // Without enforcement, static-key fallback recovers it:
    #expect(id.decrypt(ct, ratchets: [wrongRatchet]) == Data("y".utf8))
    // With enforcement, a non-matching ratchet set must return nil (no static fallback):
    #expect(id.decrypt(ct, ratchets: [wrongRatchet], enforceRatchets: true) == nil)
}

// CryptoKit accepts a low-order Curve25519 point at PublicKey(rawRepresentation:) and only
// throws at key agreement. Identity must reject such a key at construction, or the force-try
// in encrypt() aborts the process on the first send to that peer.
@Test func identityRejectsLowOrderX25519PublicKey() {
    let sig = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    // Canonical low-order points: all-zero, and 0x01 followed by zeros.
    for lowOrder in [Data(repeating: 0x00, count: 32),
                     Data([0x01]) + Data(repeating: 0x00, count: 31)] {
        #expect(Identity(publicKey: lowOrder + sig) == nil)
    }
    // A genuine key still constructs.
    let good = Identity()
    #expect(Identity(publicKey: good.publicKey) != nil)
}
