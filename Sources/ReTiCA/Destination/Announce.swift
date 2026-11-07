import Foundation
import CryptoKit

/// Reticulum announce payload construction and validation. Only the pure parse/verify
/// logic lives here; the "remember" side effects (known-destination and ratchet tables)
/// belong to the Transport layer.
public struct Announce {
    static let keySize = 64        // Identity.keySize
    static let nameHashLength = 10 // NAME_HASH_LENGTH / 8
    static let randomHashLength = 10
    static let ratchetSize = 32    // RATCHETSIZE / 8
    static let signatureLength = 64

    public struct Parsed: Equatable {
        public let identity: Identity
        public let publicKey: Data
        public let nameHash: Data
        public let randomHash: Data
        public let ratchet: Data?
        public let signature: Data
        /// The app data as the reference hands it on: with a network stamp that met the required value
        /// stripped off, and nil if that leaves nothing. A stamp below the value stays in, extension and
        /// all, exactly as reference leaves it (Identity.py:867-871).
        public let appData: Data?
        /// The 14-byte network stamp when the app data ends in a well-formed extension, valid or not
        /// (reference `stamp`).
        public let stamp: Data?
        /// That stamp's value, reported whether or not it met the required value (reference `stamp_value`).
        public let stampValue: Double?
        /// The link-request cost the extension carries, only when the stamp met the required value
        /// (reference `lr_cost`).
        public let linkCost: Double?
    }

    /// What the trailing 18-byte network-stamp extension of `appData` says (Identity.py:840-873).
    struct StampExtension {
        var stamp: Data?
        var stampValue: Double?
        var linkCost: Double?
        /// `appData` with the extension stripped when the stamp is valid, else `appData` unchanged.
        var appData: Data?
    }

    /// Read a network-stamp extension off the end of signed app data. `material` is
    /// `destinationHash ‖ publicKey ‖ nameHash` (Identity.py:862). Validating costs two SHA-256 and
    /// never searches, whatever the announce claims.
    static func readStampExtension(appData: Data?, material: Data, requiredValue: Double) -> StampExtension {
        let length = NetworkStamp.extensionLength
        guard let appData, appData.count >= length else {
            return StampExtension(appData: appData)
        }
        let ext = [UInt8](appData.suffix(length))
        let marker = ext[0]
        let anchor = ext[length - 1]                         // integer part, reserved flag in the MSB
        let fraction = ext[length - 2]
        let extended = anchor & 0x80 != 0
        guard let cost = NetworkStamp.cost(fromBytes: Data([anchor & 0x7F, fraction])) else {
            return StampExtension(appData: appData)
        }
        let knownFormat = !extended && cost <= Double(NetworkStamp.stampCostCap)
        guard marker == NetworkStamp.extensionMarker, knownFormat else {
            return StampExtension(appData: appData)
        }
        let stamp = Data(ext[2..<(2 + NetworkStamp.stampLength)])
        let value = NetworkStamp.value(stamp: stamp, material: material)
        guard NetworkStamp.isValid(stamp: stamp, cost: requiredValue, material: material) else {
            return StampExtension(stamp: stamp, stampValue: value, linkCost: nil, appData: appData)
        }
        let kept = appData.count > length ? Data(appData.prefix(appData.count - length)) : nil
        return StampExtension(stamp: stamp, stampValue: value, linkCost: cost, appData: kept)
    }

    /// Build a signed announce payload for a SINGLE destination.
    public static func buildPayload(identity: Identity, destinationHash: Data, nameHash: Data,
                                    randomHash: Data, ratchet: Data? = nil,
                                    appData: Data? = nil) -> Data {
        let publicKey = identity.publicKey
        let ratchetBytes = ratchet ?? Data()
        var signedData = destinationHash + publicKey + nameHash + randomHash + ratchetBytes
        if let appData { signedData += appData }
        let signature = identity.sign(signedData)
        var payload = publicKey + nameHash + randomHash + ratchetBytes + signature
        if let appData { payload += appData }
        return payload
    }

    /// Parse and validate an announce payload against an expected destination hash.
    /// Returns nil on invalid signature or destination-hash mismatch.
    ///
    /// A trailing RNS 1.6.0 network-stamp extension is read as reference `validate_announce` reads it
    /// (Identity.py:840-873): a stamp meeting `requiredStampValue` is stripped from `appData` and its link
    /// cost reported; any other stamp is left in `appData`. Nothing is rejected for its stamp: reference
    /// enforcement is off by default.
    public static func parse(payload rawPayload: Data, destinationHash: Data,
                             contextFlagSet: Bool,
                             requiredStampValue: Double = NetworkStamp.defaultDestinationCost) -> Parsed? {
        let payload = Data(rawPayload)
        let ratchetLen = contextFlagSet ? ratchetSize : 0
        let minLen = keySize + nameHashLength + randomHashLength + ratchetLen + signatureLength
        guard payload.count >= minLen else { return nil }

        var idx = 0
        let publicKey = payload.subdata(in: idx..<idx + keySize); idx += keySize
        let nameHash = payload.subdata(in: idx..<idx + nameHashLength); idx += nameHashLength
        let randomHash = payload.subdata(in: idx..<idx + randomHashLength); idx += randomHashLength
        // wireRatchet: the 32 bytes on the wire (or Data() when absent) — used verbatim in the
        // signed-data reconstruction so the signature verifies against what the sender signed.
        // ratchet: the value we actually store — nil if the ratchet is not agreement-safe (see below).
        var wireRatchet = Data()
        var ratchet: Data? = nil
        if contextFlagSet {
            let rawRatchet = payload.subdata(in: idx..<idx + ratchetSize); idx += ratchetSize
            wireRatchet = rawRatchet
            // Only store the ratchet if it can actually perform key agreement. CryptoKit accepts
            // low-order X25519 points at PublicKey(rawRepresentation:) but throws at agreement,
            // which is force-unwrapped in Identity.encrypt — a process abort. Drop the ratchet
            // and keep the announce: the peer is still reachable via its static key, exactly as
            // for peers that announce no ratchet at all.
            if let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawRatchet),
               Identity.isUsableX25519PublicKey(pub) {
                ratchet = rawRatchet
            }
        }
        let signature = payload.subdata(in: idx..<idx + signatureLength); idx += signatureLength
        let appData: Data? = idx < payload.count ? payload.subdata(in: idx..<payload.count) : nil

        guard let identity = Identity(publicKey: publicKey) else { return nil }
        var signedData = destinationHash + publicKey + nameHash + randomHash + wireRatchet
        if let appData { signedData += appData }
        guard identity.validate(signature: signature, message: signedData) else { return nil }

        let expectedHash = Crypto.fullHash(nameHash + identity.hash).prefix(16)
        guard destinationHash == Data(expectedHash) else { return nil }

        // Only now, with the signature checked over the full wire app data, read and strip the
        // network-stamp extension. Relays forward the packet's own bytes, never these.
        let ext = readStampExtension(appData: appData, material: destinationHash + publicKey + nameHash,
                                     requiredValue: requiredStampValue)
        return Parsed(identity: identity, publicKey: publicKey, nameHash: nameHash,
                      randomHash: randomHash, ratchet: ratchet, signature: signature, appData: ext.appData,
                      stamp: ext.stamp, stampValue: ext.stampValue, linkCost: ext.linkCost)
    }

    /// `randomPrefix[:5] ‖ now.bigEndian(5 bytes)` — matches RNS random_hash construction.
    public static func randomHash(now: UInt64, randomPrefix: Data) -> Data {
        var result = Data(randomPrefix.prefix(5))
        for shift in stride(from: 32, through: 0, by: -8) {
            result.append(UInt8((now >> UInt64(shift)) & 0xFF))
        }
        return result
    }
}
