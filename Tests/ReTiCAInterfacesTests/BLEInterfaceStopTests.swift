import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

@MainActor
private struct BLEStopHarness {
    let store: TestStore<BLEInterface.State, BLEInterface.Action>
    let calls: LockIsolated<[MockDriverCall]>
    let sessions: LockIsolated<[AsyncStream<BLEDriverEvent>.Continuation]>
    let held: LockIsolated<Bool>

    var startCount: Int { calls.value.filter { $0 == .start }.count }
    var stopCount: Int { calls.value.filter { $0 == .stop }.count }

    func releaseStop() { held.setValue(false) }

    func waitForStarts(_ count: Int) async {
        for _ in 0..<200 where startCount < count { await Task.megaYield() }
    }

    func shutdown() async {
        held.setValue(false)
        await store.send(.stop)
        await Task.megaYield()
        await store.skipReceivedActions(strict: false)
    }
}

/// A mock driver shaped like the live adapter: every `start` opens a FRESH session stream, and
/// `stop` blocks while `held` is true, ends the latest session, and records `.stop` only when it
/// RETURNS — so the call log shows whether a start ran before the stop had finished.
@MainActor
private func makeBLEStopHarness(online: Bool, holdStops: Bool = true) async -> BLEStopHarness {
    let calls = LockIsolated<[MockDriverCall]>([])
    let held = LockIsolated(holdStops)
    let sessions = LockIsolated<[AsyncStream<BLEDriverEvent>.Continuation]>([])
    let store = TestStore(initialState: BLEInterface.State(localIdentity: localIdentity, keepaliveInterval: nil)) {
        BLEInterface()
    } withDependencies: {
        $0.bleDriver = BLEDriver(
            start: { _ in
                let session = AsyncStream<BLEDriverEvent>.makeStream()
                calls.withValue { $0.append(.start) }
                sessions.withValue { $0.append(session.continuation) }
                return session.stream
            },
            readIdentity: { h in calls.withValue { $0.append(.readIdentity(h)) } },
            openChannel: { h in calls.withValue { $0.append(.openChannel(h)) } },
            send: { c, d in calls.withValue { $0.append(.send(c, d)) } },
            closeChannel: { c in calls.withValue { $0.append(.closeChannel(c)) } },
            disconnect: { h in calls.withValue { $0.append(.disconnect(h)) } },
            stop: {
                while held.value { await Task.yield() }
                sessions.value.last?.finish()
                calls.withValue { $0.append(.stop) }
            })
        $0.continuousClock = TestClock<Duration>()
        $0.bleDate = DateGenerator { Date(timeIntervalSince1970: 1_000) }
    }
    store.exhaustivity = .off
    if online {
        await store.send(.start)
        for _ in 0..<200 where sessions.value.isEmpty { await Task.megaYield() }
        sessions.value.last?.yield(.ready)
        await store.receive(.driverEvent(.ready))
    }
    return BLEStopHarness(store: store, calls: calls, sessions: sessions, held: held)
}

/// The driver's `stop()` ends whatever session is live when it runs, so the interface must never
/// let a `driver.start()` run before a preceding `driver.stop()` has returned.
@MainActor @Suite struct BLEInterfaceStopTests {
    @Test func aStartDuringAStopReachesTheDriverOnlyOnceTheStopReturned() async {
        let h = await makeBLEStopHarness(online: true)
        await h.store.send(.stop)
        await h.store.send(.start)
        await Task.megaYield()
        #expect(h.startCount == 1, "driver.start() ran while driver.stop() was in flight: \(h.calls.value)")
        #expect(h.store.state.status == .starting)
        h.releaseStop()
        await h.store.receive(.driverStopped)
        await h.waitForStarts(2)
        #expect(h.calls.value == [.start, .stop, .start])
        await h.shutdown()
    }

    @Test func aStopOnAnIdleInterfaceDoesNotReachTheDriver() async {
        let fresh = await makeBLEStopHarness(online: false, holdStops: false)
        await fresh.store.send(.stop)
        await Task.megaYield()
        #expect(fresh.calls.value.isEmpty)
        #expect(fresh.store.state.isIdle)

        let stopped = await makeBLEStopHarness(online: true, holdStops: false)
        await stopped.store.send(.stop)
        await stopped.store.receive(.driverStopped)
        await stopped.store.send(.stop)
        await Task.megaYield()
        #expect(stopped.calls.value == [.start, .stop])
    }

    /// Pins the OUTCOME only: one driver.stop(), idle once it returns. With status already
    /// `.stopped`, the `stopping` branch of `.stop` and the idle guard both make the second stop a
    /// no-op with identical state, so no observable outcome tells them apart here. The `stopping`
    /// branch is pinned by `aStopCancelsAStartDeferredBehindTheStopInFlight`, where status is
    /// `.starting` and only that branch keeps the second stop off the driver.
    @Test func aSecondStopDuringAStopDoesNotReachTheDriver() async {
        let h = await makeBLEStopHarness(online: true)
        await h.store.send(.stop)
        await h.store.send(.stop)
        h.releaseStop()
        await h.store.receive(.driverStopped)
        await Task.megaYield()
        #expect(h.stopCount == 1)
        #expect(h.store.state.isIdle)
    }

    @Test func aStopCancelsAStartDeferredBehindTheStopInFlight() async {
        let h = await makeBLEStopHarness(online: true)
        await h.store.send(.stop)
        await h.store.send(.start)
        await h.store.send(.stop)
        #expect(h.store.state.status == .stopped)
        h.releaseStop()
        await h.store.receive(.driverStopped)
        await Task.megaYield()
        #expect(h.calls.value == [.start, .stop])
        #expect(h.store.state.isIdle)
    }

    /// peerOffline does NOT wait for driver.stop(): the host deregisters the peer's interface at
    /// once, while the stop is still in flight.
    @Test func peerOfflineIsReportedBeforeTheDriverStopReturns() async {
        let h = await makeBLEStopHarness(online: true)
        await establishOutbound(h.store, h.sessions.value[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
        await h.store.send(.stop)
        await h.store.receive(.delegate(.peerOffline(identityHigh)))
        #expect(h.stopCount == 0, "the stop had already returned, so this does not show the offline came first")
        h.releaseStop()
        await h.store.receive(.driverStopped)
    }

    @Test func isIdleOnlyOnceTheDriverStopReturned() async {
        let h = await makeBLEStopHarness(online: true)
        await h.store.send(.stop)
        #expect(h.store.state.status == .stopped)
        #expect(!h.store.state.isIdle)
        h.releaseStop()
        await h.store.receive(.driverStopped)
        #expect(h.store.state.isIdle)
    }
}
