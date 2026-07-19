import Foundation

/// Opaque handle identifying an interface, so Transport stays decoupled from the
/// concrete interface type.
public struct InterfaceID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}
