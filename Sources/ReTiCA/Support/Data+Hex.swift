import Foundation

extension Data {
    /// Parse a non-delimited hex string (even length, [0-9a-fA-F]) into bytes.
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = chars.startIndex
        while index < chars.endIndex {
            guard let high = chars[index].hexDigitValue,
                  let low = chars[index + 1].hexDigitValue else { return nil }
            bytes.append(UInt8(high << 4 | low))
            index += 2
        }
        self = Data(bytes)
    }

    /// Lowercase, non-delimited hex representation (matches Python `bytes.hex()`).
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
