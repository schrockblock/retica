import Foundation
import ComposableArchitecture
import ReTiCA

/// The search `Transport` runs for a destination stamp on our own announces. Live, it is
/// `NetworkStamp.generate`. A test replaces it to hold a search open, or end it, deterministically:
/// a real search's duration is random, so asserting "still searching" against one is a race.
///
/// Contract: return a stamp valid for `cost` over `material`, or nil, and return promptly once the
/// enclosing task is cancelled.
public struct DestinationStampGenerator: Sendable {
    public var generate: @Sendable (_ material: Data, _ cost: Double) async -> (stamp: Data, value: Double)?

    public init(generate: @escaping @Sendable (_ material: Data, _ cost: Double) async -> (stamp: Data, value: Double)?) {
        self.generate = generate
    }
}

extension DestinationStampGenerator: DependencyKey {
    public static let liveValue = DestinationStampGenerator { material, cost in
        await NetworkStamp.generate(material: material, cost: cost)
    }
    /// The real search: tests that do not care which generator runs get the live behaviour.
    public static let testValue = liveValue
}

extension DependencyValues {
    /// The destination stamp search `Transport` uses (see `DestinationStampGenerator`).
    public var destinationStampGenerator: DestinationStampGenerator {
        get { self[DestinationStampGenerator.self] }
        set { self[DestinationStampGenerator.self] = newValue }
    }
}
