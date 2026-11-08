import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

/// Runs the real interface and logs, in REDUCE order, every `.driverStopped` and every
/// `.delegate(.offline)` — the latter tagged with how many driver starts had happened by then.
private struct StopOrderRecorder: Reducer {
    typealias State = MeshCoreInterface.State
    typealias Action = MeshCoreInterface.Action
    let log: LockIsolated<[String]>
    let calls: LockIsolated<[MeshCoreMockCall]>
    /// When true, the next `.delegate(.offline)` is answered once with `.stop` (a host that saw a
    /// non-idle interface at offline). Default: answer nothing.
    let stopOnOffline: LockIsolated<Bool>

    func reduce(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
        case .driverStopped:
            log.withValue { $0.append("driverStopped") }
        case .delegate(.offline):
            log.withValue { $0.append("offline@\(calls.value.meshCoreStartCount)") }
            if stopOnOffline.value {
                stopOnOffline.setValue(false)
                return .merge(MeshCoreInterface().reduce(into: &state, action: action), .send(.stop))
            }
        default:
            break
        }
        return MeshCoreInterface().reduce(into: &state, action: action)
    }
}

@MainActor
private struct StopHarness {
    let store: TestStore<MeshCoreInterface.State, MeshCoreInterface.Action>
    let log: LockIsolated<[String]>
    let calls: LockIsolated<[MeshCoreMockCall]>
    let held: LockIsolated<Bool>
    let stopOnOffline: LockIsolated<Bool>

    var offlineCount: Int { log.value.filter { $0.hasPrefix("offline") }.count }
    var startCount: Int { calls.value.meshCoreStartCount }

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

/// A mock radio shaped like the live adapter: every `start` opens a FRESH session stream, and
/// `stop` blocks while `held` is true and records `.stop` only when it RETURNS.
@MainActor
private func makeStopHarness(online: Bool, holdStops: Bool = true,
                             answerOfflineWithStop: Bool = false) async -> StopHarness {
    let log = LockIsolated<[String]>([])
    let calls = LockIsolated<[MeshCoreMockCall]>([])
    let held = LockIsolated(holdStops)
    let stopOnOffline = LockIsolated(answerOfflineWithStop)
    let sessions = LockIsolated<[AsyncStream<MeshCoreDriverEvent>.Continuation]>([])
    let store = TestStore(initialState: MeshCoreInterface.State(config: meshCoreTestConfig)) {
        StopOrderRecorder(log: log, calls: calls, stopOnOffline: stopOnOffline)
    } withDependencies: {
        $0.meshCoreDriver = MeshCoreDriver(
            start: { config in
                let session = AsyncStream<MeshCoreDriverEvent>.makeStream()
                calls.withValue { $0.append(.start(config)) }
                sessions.withValue { $0.append(session.continuation) }
                return session.stream
            },
            send: { _ in true },
            removeChannel: { true },
            stop: {
                while held.value { await Task.yield() }
                sessions.value.last?.finish()
                calls.withValue { $0.append(.stop) }
            })
        $0.meshCoreClock = TestClock<Duration>()
        $0.meshCoreDate = DateGenerator { Date(timeIntervalSince1970: 1_000) }
    }
    store.exhaustivity = .off
    store.timeout = .seconds(5)
    if online {
        await store.send(.start)
        for _ in 0..<200 where sessions.value.isEmpty { await Task.megaYield() }
        sessions.value.last?.yield(.connected(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey, params: nil))
        await store.receive { if case .delegate(.online) = $0 { return true }; return false }
    }
    return StopHarness(store: store, log: log, calls: calls, held: held, stopOnOffline: stopOnOffline)
}

/// Contract 3 (Meshtastic's, amended 2026-10-16, inherited): offline means "the driver is fully down".
@MainActor @Suite struct MeshCoreInterfaceStopTests {
    @Test func offlineWaitsForTheDriverStopToReturn() async {
        let h = await makeStopHarness(online: true)
        await h.store.send(.stop)
        await Task.megaYield()
        #expect(h.offlineCount == 0, "offline before driver.stop() returned: \(h.log.value)")
        h.releaseStop()
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        #expect(h.log.value == ["driverStopped", "offline@1"])
    }

    @Test func stopOnANeverStartedInterfaceReportsOfflineAtOnce() async {
        let h = await makeStopHarness(online: false)
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        #expect(h.calls.value.isEmpty)
    }

    @Test func stopAfterACompletedStopReportsOfflineAgain() async {
        let h = await makeStopHarness(online: true, holdStops: false)
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        #expect(h.offlineCount == 2)
    }

    @Test func aSecondStopDuringAStopReportsOfflineOnceTheDriverStops() async {
        let h = await makeStopHarness(online: true)
        await h.store.send(.stop)
        await h.store.send(.stop)
        await Task.megaYield()
        #expect(h.offlineCount == 0, "offline while driver.stop() is still in flight: \(h.log.value)")
        h.releaseStop()
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await Task.megaYield()
        #expect(h.offlineCount == 1)
    }

    @Test func stopCancellingADeferredStartWaitsForTheInFlightStop() async {
        let h = await makeStopHarness(online: true)
        await h.store.send(.stop)
        await h.store.send(.start)
        await h.store.send(.stop)
        await Task.megaYield()
        #expect(h.offlineCount == 0, "offline before the in-flight driver.stop() returned: \(h.log.value)")
        h.releaseStop()
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        #expect(h.store.state.status == .stopped)
        #expect(h.startCount == 1)
    }

    @Test func aStartDuringAStopReportsOfflineBeforeTheDriverRestarts() async {
        let h = await makeStopHarness(online: true)
        await h.store.send(.stop)
        await h.store.send(.start)
        h.releaseStop()
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await h.waitForStarts(2)
        #expect(h.log.value == ["driverStopped", "offline@1"])
        #expect(h.calls.value == [.start(meshCoreTestConfig), .stop, .start(meshCoreTestConfig)])
        await h.shutdown()
    }

    @Test func isIdleOnlyOnceTheDriverStopReturned() async {
        let h = await makeStopHarness(online: true)
        await h.store.send(.stop)
        #expect(h.store.state.status == .stopped)
        #expect(!h.store.state.isIdle)
        h.releaseStop()
        await h.store.receive { $0 == .driverStopped }
        #expect(h.store.state.isIdle)
    }

    /// The host answers the deferred-restart offline with `.stop` (it saw a non-idle interface).
    /// That stop must win: the driver is never left running after it.
    @Test func aStopAnsweringTheRestartOfflineWinsOverTheDeferredStart() async {
        let h = await makeStopHarness(online: true, answerOfflineWithStop: true)
        await h.store.send(.stop)
        await h.store.send(.start)
        h.releaseStop()
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        for _ in 0..<50 { await Task.megaYield() }
        await h.store.skipReceivedActions(strict: false)
        #expect(h.calls.value.last == .stop, "a driver start outlived the answering stop: \(h.calls.value)")
        #expect(h.store.state.isIdle)
        #expect(h.offlineCount == 2)
    }
}
