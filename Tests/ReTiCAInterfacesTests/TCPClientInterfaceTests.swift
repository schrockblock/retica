import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces
@testable import ReTiCA

// The mock returns the captured `first` stream on the first open() call and a harmless
// never-yielding stream on any later call (so reconnect's second open() doesn't try to
// re-consume an already-iterated AsyncStream). AsyncStream buffers yields, so the test can
// yield via `first.continuation` after `.connect` with no race. Each test ends with
// `.disconnect` to cancel the in-flight connection effect.
@MainActor
private func makeStore(reconnect: Bool = true)
    -> (TestStore<TCPClientInterface.State, TCPClientInterface.Action>,
        AsyncStream<TCPEvent>.Continuation, LockIsolated<[Data]>, TestClock<Duration>)
{
    let first = AsyncStream<TCPEvent>.makeStream()
    let calls = LockIsolated(0)
    let sent = LockIsolated<[Data]>([])
    let clock = TestClock()
    let store = TestStore(
        initialState: TCPClientInterface.State(host: "node", port: 4242, reconnectOnDrop: reconnect)
    ) {
        TCPClientInterface()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(
            open: { _, _ in
                let n = calls.withValue { $0 += 1; return $0 }
                return n == 1 ? first.stream : AsyncStream { _ in }
            },
            send: { data in sent.withValue { $0.append(data) } },
            close: { }
        )
        $0.continuousClock = clock
    }
    store.exhaustivity = .off // deframer buffer bookkeeping is covered exhaustively by core HDLC tests
    return (store, first.continuation, sent, clock)
}

@Test @MainActor func connectsThenDeframesInboundIntoPacketDelegate() async {
    let (store, events, _, _) = makeStore()
    await store.send(.connect) { $0.status = .connecting }
    events.yield(.connected)
    await store.receive(.connectionEvent(.connected)) { $0.status = .online }

    let raw = Data(repeating: 0xAB, count: 30) // > 19
    events.yield(.data(HDLC.frame(raw)))
    await store.receive(.connectionEvent(.data(HDLC.frame(raw))))
    await store.receive(.delegate(.packetReceived(raw)))

    await store.send(.disconnect) { $0.status = .disconnected }
}

@Test @MainActor func sendFramesOutboundBytes() async {
    let (store, events, sent, _) = makeStore()
    await store.send(.connect) { $0.status = .connecting }
    events.yield(.connected)
    await store.receive(.connectionEvent(.connected)) { $0.status = .online }

    let raw = Data([0x08, 0x00, 0x11])
    await store.send(.send(raw))
    #expect(sent.value == [HDLC.frame(raw)])

    await store.send(.disconnect) { $0.status = .disconnected }
}

@Test @MainActor func reconnectsAfterDropWhenEnabled() async {
    let (store, events, _, clock) = makeStore(reconnect: true)
    await store.send(.connect) { $0.status = .connecting }
    events.yield(.connected)
    await store.receive(.connectionEvent(.connected)) { $0.status = .online }

    events.yield(.disconnected(reason: "closed"))
    await store.receive(.connectionEvent(.disconnected(reason: "closed"))) { $0.status = .disconnected }

    await clock.advance(by: TCPClientInterface.reconnectDelay)
    await store.receive(.connect) { $0.status = .connecting }

    await store.send(.disconnect) { $0.status = .disconnected }
}

@Test @MainActor func noReconnectWhenDisabled() async {
    let (store, events, _, clock) = makeStore(reconnect: false)
    await store.send(.connect) { $0.status = .connecting }
    events.yield(.connected)
    await store.receive(.connectionEvent(.connected)) { $0.status = .online }

    events.yield(.disconnected(reason: nil))
    await store.receive(.connectionEvent(.disconnected(reason: nil))) { $0.status = .disconnected }

    await clock.advance(by: TCPClientInterface.reconnectDelay)
    // No .connect is issued; finish the connection stream so no effect remains in flight.
    await store.send(.disconnect) { $0.status = .disconnected }
}
