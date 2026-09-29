import Foundation

/// Text and file forms of a Reticulum identity backup, shared by every adopting app so one
/// backup restores in any of them. Pure functions — callers own secret handling. Never log the
/// inputs or outputs.
public enum IdentityBackup {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    /// RFC 4648 base32, uppercase, '=' padded — byte-identical to Python's base64.b32encode
    /// (what Sideband's identity restore and `rnid -B` decode).
    public static func base32(_ data: Data) -> String {
        var out = [UInt8]()
        out.reserveCapacity((data.count + 4) / 5 * 8)
        var buffer = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(buffer >> bits) & 0x1F])
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 {
            out.append(alphabet[(buffer << (5 - bits)) & 0x1F])
        }
        while out.count % 8 != 0 { out.append(UInt8(ascii: "=")) }
        return String(decoding: out, as: UTF8.self)
    }

    /// Strict RFC 4648 base32 decode — the inverse of `base32`, and of Python's
    /// `base64.b32decode` (no casefold): uppercase alphabet only; '=' padding must be exactly right
    /// or entirely absent; impossible lengths and non-zero trailing bits are rejected. It does not
    /// trim whitespace (callers do). Never log the input or the output.
    public static func decodeBase32(_ text: String) -> Data? {
        var symbols = Array(text.utf8)
        var padCount = 0
        while symbols.last == UInt8(ascii: "=") {
            symbols.removeLast()
            padCount += 1
        }
        let remainder = symbols.count % 8
        // 8 symbols = 5 bytes; a final group of 2, 4, 5 or 7 symbols = 1, 2, 3 or 4 bytes.
        guard [0, 2, 4, 5, 7].contains(remainder) else { return nil }
        if padCount > 0 {
            guard padCount == (8 - remainder) % 8 else { return nil }
        }
        var out = [UInt8]()
        out.reserveCapacity(symbols.count * 5 / 8)
        var buffer = 0, bits = 0
        for symbol in symbols {
            guard let value = alphabet.firstIndex(of: symbol) else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xFF))
                buffer &= (1 << bits) - 1
            }
        }
        // Canonical input only: the spare bits of the last symbol must be zero.
        guard buffer == 0 else { return nil }
        return Data(out)
    }
}
