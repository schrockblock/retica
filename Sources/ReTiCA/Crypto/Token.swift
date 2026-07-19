import Foundation

public enum TokenError: Error, Equatable {
    case invalidKeySize
    case hmacFailed
    case tokenTooShort
    case decryptionFailed
}

/// Simplified Fernet (no version/timestamp). Mode is chosen by key length:
/// 32 bytes → AES-128-CBC, 64 bytes → AES-256-CBC.
public struct Token {
    public static let overhead = 48 // 16 IV + 32 HMAC

    private let signingKey: Data
    private let encryptionKey: Data

    public init(key: Data) throws {
        switch key.count {
        case 32:
            signingKey = key.prefix(16)
            encryptionKey = key.suffix(16)
        case 64:
            signingKey = key.prefix(32)
            encryptionKey = key.suffix(32)
        default:
            throw TokenError.invalidKeySize
        }
    }

    public func encrypt(_ data: Data) -> Data {
        encrypt(data, iv: SecureRandom.bytes(16))
    }

    /// Deterministic entry point for tests.
    func encrypt(_ data: Data, iv: Data) -> Data {
        // AESCBC.encrypt only throws on bad key/IV sizes, which the initializer prevents.
        let ciphertext = try! AESCBC.encrypt(PKCS7.pad(data), key: encryptionKey, iv: iv)
        let signed = iv + ciphertext
        return signed + Crypto.hmacSHA256(key: signingKey, signed)
    }

    public func verifyHMAC(_ token: Data) -> Bool {
        guard token.count > 32 else { return false }
        let received = token.suffix(32)
        let expected = Crypto.hmacSHA256(key: signingKey, token.prefix(token.count - 32))
        return constantTimeEquals(Data(received), expected)
    }

    public func decrypt(_ token: Data) throws -> Data {
        guard token.count > 48 else { throw TokenError.tokenTooShort }
        guard verifyHMAC(token) else { throw TokenError.hmacFailed }
        let iv = token.prefix(16)
        let ciphertext = token.dropFirst(16).dropLast(32)
        do {
            let padded = try AESCBC.decrypt(Data(ciphertext), key: encryptionKey, iv: Data(iv))
            return try PKCS7.unpad(padded)
        } catch {
            throw TokenError.decryptionFailed
        }
    }

    private func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}
