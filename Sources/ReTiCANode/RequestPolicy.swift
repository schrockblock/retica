import Foundation
import ReTiCA

/// Who may invoke a registered request handler. Mirrors RNS ALLOW_NONE / ALLOW_ALL / ALLOW_LIST.
public enum RequestPolicy: Equatable, Sendable {
    case none                 // reject all
    case all                  // accept all (identity not required)
    case list([Data])         // accept only these 16-byte identity hashes
}

/// A registered handler's addressing + policy. `path` is retained because a request arrives only as a
/// `pathHash` (a truncated hash that cannot be reversed), and the responder needs the original string.
public struct RequestRegistration: Equatable, Sendable {
    public let path: String
    public let policy: RequestPolicy
    public init(path: String, policy: RequestPolicy) {
        self.path = path
        self.policy = policy
    }
}

/// Pure allow-gate. `.list` matches the link's identified `remoteIdentity` hash; an un-identified peer
/// (`nil`) is allowed only under `.all`.
public func isAllowed(_ policy: RequestPolicy, _ identity: Identity?) -> Bool {
    switch policy {
    case .none:             return false
    case .all:              return true
    case .list(let hashes): guard let id = identity else { return false }
                            return hashes.contains(id.hash)
    }
}
