import Foundation
import Security
import ComposableArchitecture

/// A dependency that produces `count` random bytes. Live is CSPRNG-backed
/// (`SecRandomCopyBytes`); test/preview is a deterministic ramp so spawned resource
/// hashes are reproducible. The specific bytes never affect wire compatibility.
public struct RandomBytesGenerator: Sendable {
    public var generate: @Sendable (Int) -> Data
    public init(generate: @escaping @Sendable (Int) -> Data) { self.generate = generate }
    public func callAsFunction(_ count: Int) -> Data { generate(count) }
}

extension RandomBytesGenerator: DependencyKey {
    public static let liveValue = RandomBytesGenerator { count in
        var bytes = [UInt8](repeating: 0, count: count)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return Data(bytes)
    }
    public static let testValue = RandomBytesGenerator { count in
        Data((0..<count).map { UInt8($0 & 0xff) })
    }
    public static let previewValue = testValue
}

extension DependencyValues {
    public var randomBytes: RandomBytesGenerator {
        get { self[RandomBytesGenerator.self] }
        set { self[RandomBytesGenerator.self] = newValue }
    }
}
