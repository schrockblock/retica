import Foundation
import CryptoKit

/// Pure cryptographic primitives of a Reticulum Link (AES-256-CBC mode, base handshake).
/// The stateful Link session (PENDING→HANDSHAKE→ACTIVE→CLOSED) is a separate layer.
public enum Link {
    public static let ecPublicKeySize = 64   // ECPUBSIZE (X25519 32 ‖ Ed25519 32)
    public static let sessionKeyLength = 64   // AES-256 Token key
    public static let signatureLength = 64
    static let publicKeyHalf = 32

    /// Deterministic link id from a link-request packet: truncated hash of its hashable part.
    public static func linkID(requestPacket: Packet) -> Data {
        Crypto.truncatedHash(requestPacket.hashablePart)
    }

    /// The session key both sides derive:
    /// HKDF(64, ECDH(ephemeralPrivateX25519, peerPublicX25519), salt: linkID).
    public static func sessionKey(ephemeralPrivateX25519: Data, peerPublicX25519: Data,
                                  linkID: Data) -> Data {
        guard let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ephemeralPrivateX25519),
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicX25519),
              let shared = try? priv.sharedSecretFromKeyAgreement(with: peer)
        else { return Data() }
        let sharedData = shared.withUnsafeBytes { Data($0) }
        return Crypto.hkdf(length: sessionKeyLength, derivedFrom: sharedData,
                           salt: linkID, context: nil)
    }

    /// Responder builds the LRPROOF proof data.
    public static func buildProof(linkID: Data, responderEphemeral: Identity,
                                  destinationIdentity: Identity) -> Data {
        let responderX25519Pub = Data(responderEphemeral.publicKey.prefix(publicKeyHalf))
        let destinationEd25519Pub = Data(destinationIdentity.publicKey.suffix(publicKeyHalf))
        let signedData = linkID + responderX25519Pub + destinationEd25519Pub
        let signature = destinationIdentity.sign(signedData)
        return signature + responderX25519Pub
    }

    /// Initiator validates the proof against the destination's known identity; returns the
    /// responder's X25519 public key on success, nil on bad signature or malformed input.
    public static func validateProof(proofData: Data, linkID: Data,
                                     destinationIdentity: Identity) -> Data? {
        let data = Data(proofData)
        guard data.count >= signatureLength + publicKeyHalf else { return nil }
        let signature = data.prefix(signatureLength)
        let peerPub = data.subdata(in: signatureLength..<(signatureLength + publicKeyHalf))
        let destinationEd25519Pub = Data(destinationIdentity.publicKey.suffix(publicKeyHalf))
        let signedData = Data(linkID) + peerPub + destinationEd25519Pub
        guard destinationIdentity.validate(signature: Data(signature), message: signedData) else {
            return nil
        }
        return peerPub
    }

    /// Link data cipher over the derived session key (wraps `Token`).
    public static func encrypt(_ plaintext: Data, sessionKey: Data) -> Data {
        guard let token = try? Token(key: sessionKey) else { return Data() }
        return token.encrypt(plaintext)
    }

    public static func decrypt(_ ciphertext: Data, sessionKey: Data) -> Data? {
        guard let token = try? Token(key: sessionKey) else { return nil }
        return try? token.decrypt(ciphertext)
    }
}
