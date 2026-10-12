import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

// `TCPConnection.liveValue` is ONE socket actor per value. A node that dials several TCP nodes at
// once needs one per client, keyed by what the client dials. These pin the pool and the key.

private func quietConnection() -> TCPConnection {
    TCPConnection(open: { _, _ in .finished }, send: { _ in }, close: { })
}

@Test func tcpPoolMemoizedMakesOneConnectionPerKey() {
    let made = LockIsolated(0)
    let pool = TCPConnectionPool.memoized {
        made.withValue { $0 += 1 }
        return quietConnection()
    }
    _ = pool.connection("a:1")
    _ = pool.connection("a:1")
    _ = pool.connection("b:2")
    #expect(made.value == 2, "one connection per distinct key, reused on the second request")
}

@Test func tcpPoolMemoizedHandsBackTheSameConnectionForAKey() async {
    let tags = LockIsolated<[String]>([])
    let pool = TCPConnectionPool.memoized {
        let tag = UUID().uuidString
        return TCPConnection(open: { _, _ in .finished },
                             send: { _ in tags.withValue { $0.append(tag) } },
                             close: { })
    }
    await pool.connection("a:1").send(Data())
    await pool.connection("a:1").send(Data())
    #expect(tags.value.count == 2)
    #expect(Set(tags.value).count == 1, "both sends must reach the one connection made for the key")
}

@Test func tcpPoolTestValueForwardsEveryKeyToTheInjectedConnection() async {
    let closed = LockIsolated(0)
    await withDependencies {
        $0.tcpConnection = TCPConnection(open: { _, _ in .finished }, send: { _ in },
                                         close: { closed.withValue { $0 += 1 } })
    } operation: {
        @Dependency(\.tcpConnectionPool) var pool
        await pool.connection("any:1").close()
        await pool.connection("other:2").close()
    }
    #expect(closed.value == 2, "single-client tests keep their one `\\.tcpConnection` mock")
}

@Test func tcpPoolConnectionKeyIsHostAndPort() {
    let state = TCPClientInterface.State(host: "gaefu.ddns.net", port: 4242)
    #expect(state.connectionKey == "gaefu.ddns.net:4242")
}

@Test @MainActor func tcpPoolClientInterfaceDialsThroughItsOwnKey() async {
    let opened = LockIsolated<[String]>([])
    let store = TestStore(initialState: TCPClientInterface.State(host: "h", port: 7, reconnectOnDrop: false)) {
        TCPClientInterface()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.tcpConnectionPool = TCPConnectionPool { key in
            TCPConnection(open: { _, _ in
                              opened.withValue { $0.append(key) }
                              return .finished
                          },
                          send: { _ in }, close: { })
        }
    }
    store.exhaustivity = .off
    await store.send(.connect)
    // The finished stream ends the dial: the interface reports the end as a drop.
    await store.receive(.connectionEvent(.disconnected(reason: "connection stream ended")))
    #expect(opened.value == ["h:7"], "the interface must dial the pool entry for its own host:port")
}

@Test func tcpPoolEvictMakesTheNextRequestANewConnection() {
    let made = LockIsolated(0)
    let pool = TCPConnectionPool.memoized {
        made.withValue { $0 += 1 }
        return quietConnection()
    }
    _ = pool.connection("a:1")
    pool.evict("a:1")
    _ = pool.connection("a:1")
    _ = pool.connection("a:1")
    #expect(made.value == 2, "an evicted key is made again exactly once")
}

@Test func tcpPoolEvictOfAnUnknownKeyIsANoOp() {
    let made = LockIsolated(0)
    let pool = TCPConnectionPool.memoized {
        made.withValue { $0 += 1 }
        return quietConnection()
    }
    _ = pool.connection("a:1")
    pool.evict("nobody:9")
    _ = pool.connection("a:1")
    #expect(made.value == 1)
}
