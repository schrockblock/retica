import Foundation

public enum PKCS7Error: Error, Equatable {
    case invalidPadding
}

/// PKCS7 padding at a 16-byte block size (matches `RNS/Cryptography/PKCS7.py`).
public enum PKCS7 {
    public static let blockSize = 16

    public static func pad(_ data: Data) -> Data {
        let n = blockSize - (data.count % blockSize)
        return data + Data(repeating: UInt8(n), count: n)
    }

    public static func unpad(_ data: Data) throws -> Data {
        guard let n = data.last, n <= blockSize, n >= 1, Int(n) <= data.count else {
            throw PKCS7Error.invalidPadding
        }
        return data.prefix(data.count - Int(n))
    }
}
