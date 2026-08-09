import Foundation
import SwiftEdDSA

/// Deterministic RFC-8032 Ed25519 signing, used ONLY by IFAC.
///
/// IFAC authenticates a packet by having the receiver RE-SIGN it and byte-compare against
/// a 16-byte tail carried on the wire (RNS Transport.py:1073 vs :1469-1473). Sixteen bytes
/// is a fragment of the 64-byte signature — too short to verify — so comparison-by-
/// recomputation is the only available check, and it requires `sign(key, message)` to be a
/// pure function.
///
/// CryptoKit's `Curve25519.Signing` is HEDGED (randomized): RFC 8032 permits it and Apple
/// uses it for fault-injection resistance. Signatures stay valid but are not reproducible,
/// so a CryptoKit-based node could not verify even its own outbound IFAC. Hence this
/// separate, pinned backend. Everything else in the stack keeps using CryptoKit —
/// elsewhere signatures are VERIFIED (deterministic) or relayed verbatim, so hedging is
/// harmless there.
///
/// `internal` access is intentional: callers in `ReTiCANode` should use CryptoKit's hedged
/// signer for identity keys (correct for signing) and never reach for this type, which would
/// silently defeat CryptoKit's fault-injection resistance. `@testable import` gives tests
/// access without advertising the API surface beyond this module.
///
/// Do not replace this with CryptoKit. `DeterministicSignerTests` will fail if you do.
enum DeterministicSigner {
    /// Signs `message` with a 32-byte Ed25519 seed, returning the 64-byte signature.
    /// Traps on a wrong-sized seed: every caller derives the seed via HKDF, so a bad
    /// length is a programmer error rather than a runtime condition.
    static func sign(message: Data, seed: Data) -> Data {
        precondition(seed.count == 32, "Ed25519 seed must be 32 bytes, got \(seed.count)")
        let key = try! PrivateKey(s: [UInt8](seed))
        // `deterministic: true` is the default, but this is the single most important
        // property of this backend — IFAC auth fails silently if signatures are randomized.
        // Pass it explicitly so the intent is readable at the call site.
        return Data(try! key.sign(message: [UInt8](message), deterministic: true))
    }
}
