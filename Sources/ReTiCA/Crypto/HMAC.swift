import Foundation
import CryptoKit

extension Crypto {
    /// HMAC-SHA256 of `data` under `key` (32 bytes).
    public static func hmacSHA256(key: Data, _ data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }
}
