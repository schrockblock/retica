import Foundation
import CryptoKit

/// A Reticulum identity: an X25519 encryption keypair concatenated with an Ed25519
/// signing keypair. Public/private serializations are 64 bytes: `X25519(32) ‖ Ed25519(32)`.
public struct Identity: Equatable, Sendable {
    public static let keySize = 64
    private static let halfKey = 32
    private static let derivedKeyLength = 64 // AES-256 Token

    // Raw 32-byte representations.
    private let x25519Public: Data
    private let ed25519Public: Data
    private let x25519Private: Data?
    private let ed25519Private: Data?

    // MARK: Init

    public init() {
        let enc = Curve25519.KeyAgreement.PrivateKey()
        let sig = Curve25519.Signing.PrivateKey()
        x25519Private = enc.rawRepresentation
        ed25519Private = sig.rawRepresentation
        x25519Public = enc.publicKey.rawRepresentation
        ed25519Public = sig.publicKey.rawRepresentation
    }

    public init?(privateKey: Data) {
        guard privateKey.count == Identity.keySize else { return nil }
        let encSeed = privateKey.prefix(Identity.halfKey)
        let sigSeed = privateKey.suffix(Identity.halfKey)
        guard let enc = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: encSeed),
              let sig = try? Curve25519.Signing.PrivateKey(rawRepresentation: sigSeed)
        else { return nil }
        x25519Private = Data(encSeed)
        ed25519Private = Data(sigSeed)
        x25519Public = enc.publicKey.rawRepresentation
        ed25519Public = sig.publicKey.rawRepresentation
    }

    public init?(publicKey: Data) {
        guard publicKey.count == Identity.keySize else { return nil }
        let encPub = publicKey.prefix(Identity.halfKey)
        let sigPub = publicKey.suffix(Identity.halfKey)
        guard let encKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: encPub),
              (try? Curve25519.Signing.PublicKey(rawRepresentation: sigPub)) != nil
        else { return nil }
        // CryptoKit accepts a low-order point at PublicKey(rawRepresentation:) but throws at key
        // agreement — so constructibility is NOT sufficient. A peer can announce such a key with a
        // valid Ed25519 signature and a matching destination hash (neither check touches the X25519
        // key), and the force-try in encrypt() would abort the process on the first send.
        // Reject it at the boundary instead, so every Identity that exists is safe to encrypt to.
        //
        // isUsableX25519PublicKey(_:) is defined here (not in Task 2) so there is exactly one
        // implementation and Task 2 can call it without editing this file.
        //
        // Cost: one X25519 op per construction. Announce validation already does an Ed25519 verify
        // of the same order, and announce ingest is ingress-rate-limited, so this adds no new
        // CPU-amplification surface.
        guard Identity.isUsableX25519PublicKey(encKey) else { return nil }
        x25519Public = Data(encPub)
        ed25519Public = Data(sigPub)
        x25519Private = nil
        ed25519Private = nil
    }

    /// Returns true iff `key` can actually perform a key agreement.
    ///
    /// CryptoKit accepts low-order Curve25519 points at `PublicKey(rawRepresentation:)` but throws
    /// at `sharedSecretFromKeyAgreement`. This trial agreement is the only reliable gate.
    static func isUsableX25519PublicKey(_ key: Curve25519.KeyAgreement.PublicKey) -> Bool {
        (try? Curve25519.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(with: key)) != nil
    }

    // MARK: Accessors

    public var publicKey: Data { x25519Public + ed25519Public }

    public var privateKey: Data? {
        guard let x = x25519Private, let e = ed25519Private else { return nil }
        return x + e
    }

    public var hash: Data { Crypto.truncatedHash(publicKey) }
    public var hexHash: String { hash.hexString }

    // MARK: Encryption

    public func encrypt(_ plaintext: Data, ratchet: Data? = nil) -> Data {
        encrypt(plaintext, ratchet: ratchet,
                ephemeralPrivateKey: SecureRandom.bytes(32),
                iv: SecureRandom.bytes(16))
    }

    /// Deterministic entry point for tests.
    func encrypt(_ plaintext: Data, ratchet: Data?,
                 ephemeralPrivateKey: Data, iv: Data) -> Data {
        let ephemeral = try! Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: ephemeralPrivateKey)
        let targetPub = try! Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: ratchet ?? x25519Public)
        // INVARIANT: targetPub is guaranteed agreement-safe by two boundaries:
        //   • x25519Public — Identity.init?(publicKey:) performs a trial key agreement and returns
        //     nil for low-order points, so every Identity that exists carries a usable static key.
        //   • ratchet — Announce.parse validates each announced ratchet with the same trial
        //     agreement and drops it (keeping the announce) if unusable. No unvalidated ratchet
        //     bytes can reach this call site.
        // This try! is genuinely unreachable. Do NOT change it to return plaintext on failure —
        // that would convert a crash into a silent confidentiality failure, which is far worse.
        let shared = try! ephemeral.sharedSecretFromKeyAgreement(with: targetPub)
        let sharedData = shared.withUnsafeBytes { Data($0) }
        let derived = Crypto.hkdf(length: Identity.derivedKeyLength,
                                  derivedFrom: sharedData, salt: hash, context: nil)
        let token = try! Token(key: derived)
        return ephemeral.publicKey.rawRepresentation + token.encrypt(plaintext, iv: iv)
    }

    public func decrypt(_ token: Data, ratchets: [Data]? = nil,
                        enforceRatchets: Bool = false) -> Data? {
        guard let x = x25519Private, token.count > Identity.halfKey else { return nil }
        let peerPubBytes = token.prefix(Identity.halfKey)
        let ciphertext = Data(token.dropFirst(Identity.halfKey))
        guard let peerPub = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: peerPubBytes) else { return nil }

        if let ratchets {
            for ratchet in ratchets {
                guard let rPriv = try? Curve25519.KeyAgreement.PrivateKey(
                        rawRepresentation: ratchet),
                      let shared = try? rPriv.sharedSecretFromKeyAgreement(with: peerPub)
                else { continue }
                if let pt = decryptCiphertext(ciphertext,
                                              shared: shared.withUnsafeBytes { Data($0) }) {
                    return pt
                }
            }
            if enforceRatchets { return nil }
        }

        guard let staticPriv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: x),
              let shared = try? staticPriv.sharedSecretFromKeyAgreement(with: peerPub)
        else { return nil }
        return decryptCiphertext(ciphertext, shared: shared.withUnsafeBytes { Data($0) })
    }

    private func decryptCiphertext(_ ciphertext: Data, shared: Data) -> Data? {
        let derived = Crypto.hkdf(length: Identity.derivedKeyLength,
                                  derivedFrom: shared, salt: hash, context: nil)
        guard let token = try? Token(key: derived) else { return nil }
        return try? token.decrypt(ciphertext)
    }

    // MARK: Signing

    public func sign(_ message: Data) -> Data {
        guard let seed = ed25519Private,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
            preconditionFailure("Cannot sign without a private key")
        }
        return try! key.signature(for: message)
    }

    public func validate(signature: Data, message: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: ed25519Public)
        else { return false }
        return key.isValidSignature(signature, for: message)
    }

    // Identity equality is public-key equality: two Identity values representing the
    // same Reticulum identity compare equal regardless of whether they carry private keys.
    public static func == (lhs: Identity, rhs: Identity) -> Bool {
        lhs.x25519Public == rhs.x25519Public && lhs.ed25519Public == rhs.ed25519Public
    }
}
