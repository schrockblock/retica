import Foundation

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
        public let appData: Data?
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
    public static func parse(payload rawPayload: Data, destinationHash: Data,
                             contextFlagSet: Bool) -> Parsed? {
        let payload = Data(rawPayload)
        let ratchetLen = contextFlagSet ? ratchetSize : 0
        let minLen = keySize + nameHashLength + randomHashLength + ratchetLen + signatureLength
        guard payload.count >= minLen else { return nil }

        var idx = 0
        let publicKey = payload.subdata(in: idx..<idx + keySize); idx += keySize
        let nameHash = payload.subdata(in: idx..<idx + nameHashLength); idx += nameHashLength
        let randomHash = payload.subdata(in: idx..<idx + randomHashLength); idx += randomHashLength
        var ratchet: Data? = nil
        if contextFlagSet {
            ratchet = payload.subdata(in: idx..<idx + ratchetSize); idx += ratchetSize
        }
        let signature = payload.subdata(in: idx..<idx + signatureLength); idx += signatureLength
        let appData: Data? = idx < payload.count ? payload.subdata(in: idx..<payload.count) : nil

        guard let identity = Identity(publicKey: publicKey) else { return nil }
        var signedData = destinationHash + publicKey + nameHash + randomHash + (ratchet ?? Data())
        if let appData { signedData += appData }
        guard identity.validate(signature: signature, message: signedData) else { return nil }

        let expectedHash = Crypto.fullHash(nameHash + identity.hash).prefix(16)
        guard destinationHash == Data(expectedHash) else { return nil }

        return Parsed(identity: identity, publicKey: publicKey, nameHash: nameHash,
                      randomHash: randomHash, ratchet: ratchet, signature: signature, appData: appData)
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
