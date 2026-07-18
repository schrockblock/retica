import Foundation

/// Cryptographically secure random bytes. The single source of randomness for the
/// core; internal encrypt overloads accept explicit bytes so tests stay deterministic.
public enum SecureRandom {
    public static func bytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { raw in
            SecRandomCopyBytes(kSecRandomDefault, count, raw.baseAddress!)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return data
    }
}
