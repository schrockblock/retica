import Foundation

/// A Reticulum destination: an addressable endpoint. Owns addressing (name/hash) and
/// crypto dispatch. Framing is handled separately by `Packet`.
public struct Destination: Equatable {
    public enum Direction: UInt8, Equatable { case `in` = 0x11, out = 0x12 }

    public static let nameHashLength = 10 // NAME_HASH_LENGTH / 8
    public static let hashLength = 16     // TRUNCATED_HASHLENGTH / 8

    public let kind: DestinationType
    public let direction: Direction
    public let appName: String
    public let aspects: [String]
    public let identity: Identity?
    public let groupKey: Data?

    // MARK: Addressing (pure statics)

    /// Full human-readable name: `app[.aspect]*[.identityHexHash]`.
    public static func expandName(appName: String, aspects: [String],
                                  identityHexHash: String?) -> String {
        var name = appName
        for aspect in aspects { name += "." + aspect }
        if let hex = identityHexHash { name += "." + hex }
        return name
    }

    /// `SHA256(expandName(without identity))[:10]`.
    public static func nameHash(appName: String, aspects: [String]) -> Data {
        let expanded = expandName(appName: appName, aspects: aspects, identityHexHash: nil)
        return Crypto.fullHash(Data(expanded.utf8)).prefix(nameHashLength)
    }

    /// `SHA256( nameHash ‖ identityHash? )[:16]`.
    public static func hash(identityHash: Data?, appName: String, aspects: [String]) -> Data {
        var material = nameHash(appName: appName, aspects: aspects)
        if let idHash = identityHash { material.append(idHash) }
        return Crypto.fullHash(material).prefix(hashLength)
    }

    // MARK: Init

    public init?(kind: DestinationType, direction: Direction, appName: String,
                 aspects: [String], identity: Identity? = nil, groupKey: Data? = nil) {
        guard !appName.contains(".") else { return nil }
        guard !aspects.contains(where: { $0.contains(".") }) else { return nil }
        switch kind {
        case .single: guard identity != nil, groupKey == nil else { return nil }
        case .group:
            // Validate by attempting Token construction — Token owns the key-length rule
            // (Token.swift:18-29; 32 or 64 bytes). Duplicating the lengths here would let
            // the two drift. This is the same boundary-validation pattern used in
            // Identity.init?(publicKey:) (d37d32d) and Announce.parse (eeeeff7).
            guard let key = groupKey, (try? Token(key: key)) != nil else { return nil }
        case .plain:  guard identity == nil, groupKey == nil else { return nil }
        case .link:   break
        }
        self.kind = kind
        self.direction = direction
        self.appName = appName
        self.aspects = aspects
        self.identity = identity
        self.groupKey = groupKey
    }

    // MARK: Derived addressing

    public var nameHash: Data { Destination.nameHash(appName: appName, aspects: aspects) }
    public var hash: Data {
        Destination.hash(identityHash: identity?.hash, appName: appName, aspects: aspects)
    }

    // MARK: Crypto dispatch

    public func encrypt(_ plaintext: Data, ratchet: Data? = nil) -> Data {
        switch kind {
        case .plain, .link:
            return plaintext
        case .single:
            return identity?.encrypt(plaintext, ratchet: ratchet) ?? plaintext
        case .group:
            // init? validates the key via Token construction, so this guard is
            // unreachable-by-construction. It is kept as defence in depth. NEVER
            // relax the fallback to return plaintext — that would convert a construction
            // error into a silent confidentiality failure (the exact bug this fixed).
            guard let key = groupKey, let token = try? Token(key: key) else { return plaintext }
            return token.encrypt(plaintext)
        }
    }

    public func decrypt(_ ciphertext: Data, ratchets: [Data]? = nil,
                        enforceRatchets: Bool = false) -> Data? {
        switch kind {
        case .plain, .link:
            return ciphertext
        case .single:
            return identity?.decrypt(ciphertext, ratchets: ratchets, enforceRatchets: enforceRatchets)
        case .group:
            guard let key = groupKey, let token = try? Token(key: key) else { return nil }
            return try? token.decrypt(ciphertext)
        }
    }
}
