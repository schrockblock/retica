import Foundation
import ComposableArchitecture

/// One `TCPConnection` per dial target, so several `TCPClientInterface`s in one store each own a
/// socket. `TCPConnection.liveValue` wraps ONE `NWConnectionActor` whose `open` tears down the
/// previous connection and whose `send`/`close` act on whichever connection is current — sharing
/// one value between two clients would make each dial close the other's socket and route every
/// `send` to the client that dialed last. The pool keys by `TCPClientInterface.State.connectionKey`.
///
/// Entries live until `evict`: `TransportEndpoint.removeTCPClient` evicts before closing, so a
/// slot re-added for the same target dials a fresh actor and a late close cannot hit it.
public struct TCPConnectionPool: Sendable {
    /// The connection for `key` (`"host:port"`).
    public var connection: @Sendable (_ key: String) -> TCPConnection
    /// Forget the connection for `key`: the next `connection(key)` makes a new one. The caller
    /// still owns closing the old one. No-op for an unknown key.
    public var evict: @Sendable (_ key: String) -> Void

    public init(connection: @escaping @Sendable (String) -> TCPConnection,
                evict: @escaping @Sendable (String) -> Void = { _ in }) {
        self.connection = connection
        self.evict = evict
    }

    /// Calls `make` once per distinct key and hands the same connection back for every later
    /// request of that key until `evict(key)`. One lock across every key: `make` must stay cheap
    /// and never do I/O — `TCPConnection.liveValue` only allocates an actor.
    public static func memoized(_ make: @escaping @Sendable () -> TCPConnection) -> TCPConnectionPool {
        let pool = LockIsolated<[String: TCPConnection]>([:])
        return TCPConnectionPool(
            connection: { key in
                pool.withValue { connections in
                    if let existing = connections[key] { return existing }
                    let made = make()
                    connections[key] = made
                    return made
                }
            },
            evict: { key in pool.withValue { $0[key] = nil } })
    }
}

extension TCPConnectionPool: DependencyKey {
    public static var liveValue: TCPConnectionPool {
        // `TCPConnection.liveValue` is a computed property: every call builds a fresh actor.
        .memoized { TCPConnection.liveValue }
    }

    /// Every key resolves to the one `\.tcpConnection` the test injected, so a single-client test
    /// keeps its existing mock untouched; a multi-client test overrides `\.tcpConnectionPool`.
    /// `evict` is the default no-op: there is nothing per key to forget.
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
