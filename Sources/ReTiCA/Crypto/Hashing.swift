import Foundation
import CryptoKit

/// Namespace for Reticulum's cryptographic primitives. Extended across the Crypto/ files.
public enum Crypto {
    /// Reticulum's addressable hash length: TRUNCATED_HASHLENGTH = 128 bits.
    public static let truncatedHashLength = 16

    /// SHA-256 of `data` (32 bytes).
    public static func fullHash(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// First 16 bytes of the SHA-256 hash.
    public static func truncatedHash(_ data: Data) -> Data {
        fullHash(data).prefix(truncatedHashLength)
    }

    /// Truncated hash of 16 random bytes.
    public static func randomHash() -> Data {
        truncatedHash(SecureRandom.bytes(truncatedHashLength))
    }
}
