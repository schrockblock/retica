import Foundation
import ComposableArchitecture
import ReTiCA

/// The search `Transport` runs for the stamp on one of our own path requests. Live, it is
/// `NetworkStamp.generate`. A test replaces it to hold a search open, or end it, deterministically.
/// `Transport` still races it against `NetworkStamp.pathStampTimeout` on the injected clock.
///
/// Contract: return a stamp valid for `cost` over `material`, or nil, and return promptly once the
/// enclosing task is cancelled.
public struct PathRequestStampGenerator: Sendable {
    public var generate: @Sendable (_ material: Data, _ cost: Double) async -> Data?

    public init(generate: @escaping @Sendable (_ material: Data, _ cost: Double) async -> Data?) {
        self.generate = generate
    }
}

extension PathRequestStampGenerator: DependencyKey {
    public static let liveValue = PathRequestStampGenerator { material, cost in
        await NetworkStamp.generate(material: material, cost: cost)?.stamp
    }
    /// The real search: tests that do not care which generator runs get the live behaviour.
    public static let testValue = liveValue
}

extension DependencyValues {
    /// The path-request stamp search `Transport` uses (see `PathRequestStampGenerator`).
    public var pathRequestStampGenerator: PathRequestStampGenerator {
        get { self[PathRequestStampGenerator.self] }
        set { self[PathRequestStampGenerator.self] = newValue }
    }
}
