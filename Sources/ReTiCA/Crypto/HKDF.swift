import Foundation

extension Crypto {
    /// Reticulum's HKDF (RFC-5869-equivalent for lengths ≤ 255*32 bytes).
    public static func hkdf(length: Int, derivedFrom ikm: Data,
                            salt: Data?, context: Data?) -> Data {
        precondition(length >= 1, "HKDF output length must be >= 1")
        precondition(!ikm.isEmpty, "HKDF input key material must be non-empty")

        let hashLen = 32
        let effectiveSalt = (salt?.isEmpty == false) ? salt! : Data(repeating: 0, count: hashLen)
        let info = context ?? Data()

        let prk = hmacSHA256(key: effectiveSalt, ikm)

        var derived = Data()
        var block = Data()
        let blocks = (length + hashLen - 1) / hashLen
        for i in 0..<blocks {
            var input = block
            input.append(info)
            input.append(UInt8((i + 1) & 0xFF))
            block = hmacSHA256(key: prk, input)
            derived.append(block)
        }
        return derived.prefix(length)
    }
}
