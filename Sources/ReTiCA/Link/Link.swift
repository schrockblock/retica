import Foundation
import CryptoKit

/// Pure cryptographic primitives of a Reticulum Link (AES-256-CBC mode, base handshake).
/// The stateful Link session (PENDING→HANDSHAKE→ACTIVE→CLOSED) is a separate layer.
public enum Link {
    public static let ecPublicKeySize = 64   // ECPUBSIZE (X25519 32 ‖ Ed25519 32)
    public static let sessionKeyLength = 64   // AES-256 Token key
    public static let signatureLength = 64
    static let publicKeyHalf = 32

    /// Maximum single-packet data unit over a link (RNS `Link.MDU`, = 431). An LXMF DIRECT message
    /// whose `packed` fits this is sent as one link packet, else as a Resource.
    public static let mdu = 431

    /// Link MTU/mode signalling appended to link requests and proofs (RNS `LINK_MTU_SIZE`).
    /// Fixed to the default MTU (500) and AES-256-CBC mode; ReTiCA does not negotiate MTU, but the
    /// bytes are part of the reference wire format (`Link.signalling_bytes(500, MODE_AES256_CBC)`),
    /// so they must appear in the signed/serialized payloads for byte-exact RNS 1.3.8 compatibility.
    public static let signallingLength = 3
    public static let signallingBytes = Data([0x20, 0x01, 0xf4])

    /// Deterministic link id from a link-request packet: truncated hash of its hashable part.
    /// Mirrors RNS `link_id_from_lr_packet`: when the request carries trailing signalling bytes
    /// (payload longer than the ephemeral public key), they are stripped before hashing.
    public static func linkID(requestPacket: Packet) -> Data {
        var hashable = requestPacket.hashablePart
        if requestPacket.payload.count > ecPublicKeySize {
            let diff = requestPacket.payload.count - ecPublicKeySize
            hashable = Data(hashable.prefix(hashable.count - diff))
        }
        return Crypto.truncatedHash(hashable)
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

    /// Responder builds the LRPROOF proof data. Mirrors RNS `Link.prove`:
    /// signs `linkID ‖ responderX25519Pub ‖ destinationEd25519Pub ‖ signalling`, then serializes
    /// `signature ‖ responderX25519Pub ‖ signalling` (99 bytes).
    public static func buildProof(linkID: Data, responderEphemeral: Identity,
                                  destinationIdentity: Identity) -> Data {
        let responderX25519Pub = Data(responderEphemeral.publicKey.prefix(publicKeyHalf))
        let destinationEd25519Pub = Data(destinationIdentity.publicKey.suffix(publicKeyHalf))
        let signedData = linkID + responderX25519Pub + destinationEd25519Pub + signallingBytes
        let signature = destinationIdentity.sign(signedData)
        return signature + responderX25519Pub + signallingBytes
    }

    /// Initiator validates the proof against the destination's known identity; returns the
    /// responder's X25519 public key on success, nil on bad signature or malformed input.
    /// Accepts both the 99-byte form (with trailing signalling bytes) and the 96-byte
    /// signalling-free form, matching RNS `validate_proof`.
    public static func validateProof(proofData: Data, linkID: Data,
                                     destinationIdentity: Identity) -> Data? {
        let data = Data(proofData)
        let base = signatureLength + publicKeyHalf
        var signalling = Data()
        if data.count == base + signallingLength {
            signalling = Data(data.suffix(signallingLength))
        } else if data.count != base {
            return nil
        }
        let signature = data.prefix(signatureLength)
        let peerPub = data.subdata(in: signatureLength..<(signatureLength + publicKeyHalf))
        let destinationEd25519Pub = Data(destinationIdentity.publicKey.suffix(publicKeyHalf))
        let signedData = Data(linkID) + peerPub + destinationEd25519Pub + signalling
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
