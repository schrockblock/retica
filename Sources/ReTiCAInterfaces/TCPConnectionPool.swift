import Foundation
import ComposableArchitecture

/// One `TCPConnection` per dial target, so several `TCPClientInterface`s in one store each own a
/// socket. `TCPConnection.liveValue` wraps ONE `NWConnectionActor` whose `open` tears down the
/// previous connection and whose `send`/`close` act on whichever connection is current — sharing
/// one value between two clients would make each dial close the other's socket and route every
/// `send` to the client that dialed last. The pool keys by `TCPClientInterface.State.connectionKey`.
public struct TCPConnectionPool: Sendable {
    /// The connection for `key` (`"host:port"`).
    public var connection: @Sendable (_ key: String) -> TCPConnection

    public init(connection: @escaping @Sendable (String) -> TCPConnection) {
        self.connection = connection
    }

    /// Calls `make` once per distinct key and hands the same connection back for every later
    /// request of that key. Entries are never evicted: a re-dial of the same target reuses the
    /// actor, which restarts cleanly (`NWConnectionActor.start` supersedes its old connection).
    public static func memoized(_ make: @escaping @Sendable () -> TCPConnection) -> TCPConnectionPool {
        let pool = LockIsolated<[String: TCPConnection]>([:])
        return TCPConnectionPool { key in
            pool.withValue { connections in
                if let existing = connections[key] { return existing }
                let made = make()
                connections[key] = made
                return made
            }
        }
    }
}

extension TCPConnectionPool: DependencyKey {
    public static var liveValue: TCPConnectionPool {
        // `TCPConnection.liveValue` is a computed property: every call builds a fresh actor.
        .memoized { TCPConnection.liveValue }
    }

    /// Every key resolves to the one `\.tcpConnection` the test injected, so a single-client test
    /// keeps its existing mock untouched; a multi-client test overrides `\.tcpConnectionPool`.
    public static var testValue: TCPConnectionPool {
        TCPConnectionPool { _ in
            @Dependency(\.tcpConnection) var connection
            return connection
        }
    }
}

extension DependencyValues {
    public var tcpConnectionPool: TCPConnectionPool {
        get { self[TCPConnectionPool.self] }
        set { self[TCPConnectionPool.self] = newValue }
    }
}
