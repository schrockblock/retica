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
        let cost = NetworkStamp.cost(high: anchor & 0x7F, low: fraction)
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
    /// cost reported; any other stamp is left in `appData`.
    ///
    /// With `enforceStamp` false (the default, as reference enforcement is off by default) nothing is
    /// rejected for its stamp. With it true, an announce without a stamp meeting `requiredStampValue`
    /// returns nil, and that is decided BEFORE the signature is verified, as reference does
    /// (Identity.py:883-889 precede the validate at 900): a junk announce costs at most two SHA-256
    /// (the stamp's validity and its value, as reference computes both), not an Ed25519 verification
    /// or an X25519 agreement. Nothing before the gate does public-key work: the ratchet's usability
    /// check runs after it. The stamp material is wire bytes only, so nothing is trusted early.
    public static func parse(payload rawPayload: Data, destinationHash: Data,
                             contextFlagSet: Bool,
                             requiredStampValue: Double = NetworkStamp.defaultDestinationCost,
                             enforceStamp: Bool = false) -> Parsed? {
        try? validate(payload: rawPayload, destinationHash: destinationHash, contextFlagSet: contextFlagSet,
                      requiredStampValue: requiredStampValue, enforceStamp: enforceStamp).get()
    }

    /// Why `validate` refused an announce, as reference's `validate_announce` tells its verdicts apart
    /// when it caches them (Identity.py:885-889, 919, 932, 937).
    public enum Rejection: Error, Equatable, Sendable {
        /// Enforcing, and the app data carries no well-formed stamp extension (reference "no_stamp").
        case noStamp
        /// Enforcing, and the stamp's value falls short of the required value (reference
        /// "invalid_stamp", cached with the stamp's value).
        case lowStamp(value: Double)
        /// Too short, an unusable key, a bad signature or a destination-hash mismatch. Each depends on
        /// the announce's bytes alone.
        case invalid
    }

    /// `parse`, saying why an announce was refused. Same checks in the same order.
    public static func validate(payload rawPayload: Data, destinationHash: Data,
                                contextFlagSet: Bool,
                                requiredStampValue: Double = NetworkStamp.defaultDestinationCost,
                                enforceStamp: Bool = false) -> Result<Parsed, Rejection> {
        parseProbe?.withValue { $0 += 1 }
        let payload = Data(rawPayload)
        let ratchetLen = contextFlagSet ? ratchetSize : 0
        let minLen = keySize + nameHashLength + randomHashLength + ratchetLen + signatureLength
        guard payload.count >= minLen else { return .failure(.invalid) }

        var idx = 0
        let publicKey = payload.subdata(in: idx..<idx + keySize); idx += keySize
        let nameHash = payload.subdata(in: idx..<idx + nameHashLength); idx += nameHashLength
        let randomHash = payload.subdata(in: idx..<idx + randomHashLength); idx += randomHashLength
        // wireRatchet: the 32 bytes on the wire (or Data() when absent) — used verbatim in the
        // signed-data reconstruction so the signature verifies against what the sender signed.
        // ratchet: the value we actually store — nil if the ratchet is not agreement-safe (see below).
        var wireRatchet = Data()
        if contextFlagSet {
            wireRatchet = payload.subdata(in: idx..<idx + ratchetSize); idx += ratchetSize
        }
        let signature = payload.subdata(in: idx..<idx + signatureLength); idx += signatureLength
        let appData: Data? = idx < payload.count ? payload.subdata(in: idx..<payload.count) : nil

        let material = destinationHash + publicKey + nameHash
        // Enforcing: an announce whose stamp is missing or short is refused here, before the signature.
        // A met stamp always reports its link cost, so a nil cost is exactly reference's
        // `not dst_stamped or not stamp_validated`.
        var early: StampExtension? = nil
        if enforceStamp {
            let ext = readStampExtension(appData: appData, material: material, requiredValue: requiredStampValue)
            guard ext.linkCost != nil else {
                guard ext.stamp != nil, let value = ext.stampValue else { return .failure(.noStamp) }
                return .failure(.lowStamp(value: value))
            }
            early = ext
        }

        // Only store the ratchet if it can actually perform key agreement. CryptoKit accepts
        // low-order X25519 points at PublicKey(rawRepresentation:) but throws at agreement,
        // which is force-unwrapped in Identity.encrypt — a process abort. Drop the ratchet
        // and keep the announce: the peer is still reachable via its static key, exactly as
        // for peers that announce no ratchet at all.
        //
        // After the stamp gate, not where the bytes are sliced: the trial agreement is a key
        // generation plus a DH, and before the gate any sender could buy one for an unstamped
        // announce by setting the context flag. It only decides whether `ratchet` is set, never
        // accepts or rejects, so where it runs changes no output.
        var ratchet: Data? = nil
        if contextFlagSet,
           let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: wireRatchet),
           Identity.isUsableX25519PublicKey(pub) {
            ratchet = wireRatchet
        }

        guard let identity = Identity(publicKey: publicKey) else { return .failure(.invalid) }
        var signedData = destinationHash + publicKey + nameHash + randomHash + wireRatchet
        if let appData { signedData += appData }
        guard identity.validate(signature: signature, message: signedData) else { return .failure(.invalid) }

        let expectedHash = Crypto.fullHash(nameHash + identity.hash).prefix(16)
        guard destinationHash == Data(expectedHash) else { return .failure(.invalid) }

        // Only now, with the signature checked over the full wire app data, read and strip the
        // network-stamp extension. Relays forward the packet's own bytes, never these.
        let ext = early ?? readStampExtension(appData: appData, material: material,
                                              requiredValue: requiredStampValue)
        return .success(Parsed(identity: identity, publicKey: publicKey, nameHash: nameHash,
                               randomHash: randomHash, ratchet: ratchet, signature: signature, appData: ext.appData,
                               stamp: ext.stamp, stampValue: ext.stampValue, linkCost: ext.linkCost))
    }

    /// Test seam: when a test binds a counter here, each `validate` (and so each `parse`) increments
    /// it, so a test can show that a path does not parse again. Task-local, so parallel tests do not
    /// mix counts; unbound (nil) in production, where it costs one task-local read.
    @TaskLocal static var parseProbe: Identity.LockedCounter? = nil

    /// `randomPrefix[:5] ‖ now.bigEndian(5 bytes)` — matches RNS random_hash construction.
    public static func randomHash(now: UInt64, randomPrefix: Data) -> Data {
        var result = Data(randomPrefix.prefix(5))
        for shift in stride(from: 32, through: 0, by: -8) {
            result.append(UInt8((now >> UInt64(shift)) & 0xFF))
        }
        return result
    }
}
