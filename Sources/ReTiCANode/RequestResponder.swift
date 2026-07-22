import Foundation
import ComposableArchitecture
import ReTiCA

/// App-supplied generator that answers a registered request. Returns the response payload, or `nil` to
/// decline (no response is sent). One closure dispatches all registered paths (the app switches on `path`),
/// keeping handler closures out of TCA state, which must stay `Equatable`.
public struct RequestResponder: Sendable {
    public var respond: @Sendable (_ path: String, _ data: Data, _ remoteIdentity: Identity?) async -> Data?
    public init(respond: @escaping @Sendable (_ path: String, _ data: Data, _ remoteIdentity: Identity?) async -> Data?) {
        self.respond = respond
    }
    public func callAsFunction(_ path: String, _ data: Data, _ remoteIdentity: Identity?) async -> Data? {
        await respond(path, data, remoteIdentity)
    }
}

extension RequestResponder: DependencyKey {
    /// Declines everything by default, so a store that registers no handler behaves exactly as before.
    public static let liveValue = RequestResponder { _, _, _ in nil }
    public static let testValue = RequestResponder { _, _, _ in nil }
    public static let previewValue = testValue
}

extension DependencyValues {
    public var requestResponder: RequestResponder {
        get { self[RequestResponder.self] }
        set { self[RequestResponder.self] = newValue }
    }
}
