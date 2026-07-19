import Foundation
import CommonCrypto

public enum AESError: Error, Equatable {
    case invalidKeySize
    case invalidIVSize
    case cryptoFailed(Int32)
}

/// AES-CBC (128/256) with no built-in padding — callers pre-pad with PKCS7.
public enum AESCBC {
    public static func encrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(input: plaintext, key: key, iv: iv, operation: kCCEncrypt)
    }

    public static func decrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(input: ciphertext, key: key, iv: iv, operation: kCCDecrypt)
    }

    private static func crypt(input: Data, key: Data, iv: Data,
                              operation: Int) throws -> Data {
        guard key.count == kCCKeySizeAES128 || key.count == kCCKeySizeAES256 else {
            throw AESError.invalidKeySize
        }
        guard iv.count == kCCBlockSizeAES128 else { throw AESError.invalidIVSize }

        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let outputCount = output.count
        let status = output.withUnsafeMutableBytes { outRaw in
            input.withUnsafeBytes { inRaw in
                key.withUnsafeBytes { keyRaw in
                    iv.withUnsafeBytes { ivRaw in
                        CCCrypt(
                            CCOperation(operation),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0), // no padding, CBC (ECB bit unset)
                            keyRaw.baseAddress, key.count,
                            ivRaw.baseAddress,
                            inRaw.baseAddress, input.count,
                            outRaw.baseAddress, outputCount,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw AESError.cryptoFailed(status) }
        return output.prefix(moved)
    }
}
