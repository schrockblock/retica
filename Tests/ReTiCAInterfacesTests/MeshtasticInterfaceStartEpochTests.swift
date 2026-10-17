import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

/// A host around the real interface that can put a `.stop` in the SAME burst as the action that
/// builds (or queues) a start — the burst `.cancellable` cannot order, because the start's cancel
/// id is registered only once its task runs.
private struct MeshBurstHost: Reducer {
    struct State: Equatable { var mesh: MeshtasticInterface.State }

    @CasePathable
    enum Action: Equatable {
        case mesh(MeshtasticInterface.Action)
        /// `.concatenate(.send(.start), .send(.stop))`.
        case startThenStop
    }

    /// Answer a `.driverStopped` that is about to run a deferred start with `.stop`, in its burst.
    let answerRestartWithStop: Bool

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .startThenStop:
                return .concatenate(.send(.mesh(.start)), .send(.mesh(.stop)))
            case .mesh(.driverStopped) where answerRestartWithStop && state.mesh.restartPending:
                return .send(.mesh(.stop))
            default:
                return .none
            }
        }
        Scope(state: \.mesh, action: \.mesh) { MeshtasticInterface() }
    }
}

@MainActor
private struct MeshEpochHarness {
    let store: TestStore<MeshBurstHost.State, MeshBurstHost.Action>
    let calls: LockIsolated<[MeshMockCall]>
    let sessions: LockIsolated<Int>
    let ended: LockIsolated<Set<Int>>
    let held: LockIsolated<Bool>

    var stopCount: Int { calls.value.filter { $0 == .stop }.count }

    /// No `driver.start()` after the last `driver.stop()` returned, and every session ended.
    func expectNoSessionOutlivesTheLastStop(_ iteration: Int) {
        let log = calls.value
        let lastStop = log.lastIndex(of: .stop) ?? -1
        #expect(!log[(lastStop + 1)...].contains(.start(meshTestConfig)),
                "run \(iteration): driver.start() ran after the last driver.stop(): \(log)")
        #expect(ended.value.count == sessions.value,
                "run \(iteration): \(sessions.value - ended.value.count) session(s) never ended: \(log)")
        #expect(store.state.mesh.isIdle, "run \(iteration)")
    }

    func settle(stops: Int) async {
        for _ in 0..<400 where stopCount < stops { await Task.megaYield() }
        for _ in 0..<50 { await Task.megaYield() }
        await store.skipReceivedActions(strict: false)
    }
}

/// Every `start` opens a FRESH session and records `.start` at the call; `stop` blocks while
/// `held`, ends the latest session, and records `.stop` when it RETURNS (like the live adapter).
@MainActor
private func makeMeshEpochHarness(answerRestartWithStop: Bool, holdStops: Bool) -> MeshEpochHarness {
    let calls = LockIsolated<[MeshMockCall]>([])
    let held = LockIsolated(holdStops)
    let sessions = LockIsolated(0)
    let ended = LockIsolated<Set<Int>>([])
    let live = LockIsolated<[AsyncStream<MeshtasticDriverEvent>.Continuation]>([])
    let store = TestStore(initialState: MeshBurstHost.State(mesh: MeshtasticInterface.State(config: meshTestConfig))) {
        MeshBurstHost(answerRestartWithStop: answerRestartWithStop)
    } withDependencies: {
        $0.meshtasticDriver = MeshtasticDriver(
            start: { config in
                let session = AsyncStream<MeshtasticDriverEvent>.makeStream()
                let index = sessions.withValue { n in defer { n += 1 }; return n }
                session.continuation.onTermination = { _ in ended.withValue { _ = $0.insert(index) } }
                calls.withValue { $0.append(.start(config)) }
                live.withValue { $0.append(session.continuation) }
                return session.stream
            },
            send: { _ in true },
            stop: {
                while held.value { await Task.yield() }
                live.value.last?.finish()
                calls.withValue { $0.append(.stop) }
            })
        $0.meshtasticClock = TestClock<Duration>()
        $0.meshtasticDate = DateGenerator { Date(timeIntervalSince1970: 1_000) }
    }
    store.exhaustivity = .off
    return MeshEpochHarness(store: store, calls: calls, sessions: sessions, ended: ended, held: held)
}

/// A `.stop` reduced in the same burst as the action that builds or queues a start must still
/// win. Scope: both same-burst shapes, whichever guard holds each. The from-stopped test pins
/// the epoch. The deferred-restart test pins `restartQueued`, which the epoch cannot reach; it
/// lives here because it shares the burst host with its BLE twin, where the epoch does hold it.
@MainActor @Suite struct MeshtasticInterfaceStartEpochTests {
    /// The host answers the deferred restart's `.driverStopped` with `.stop` in that burst. Here
    /// the `restartQueued` guard, not the epoch, keeps the restart off the driver: the restart's
    /// start effect is built at `.restartDeferred`, after this stop's bump.
    @Test func aStopInTheDeferredRestartsBurstKeepsTheRestartOffTheDriver() async {
        for run in 0..<5 {
            let h = makeMeshEpochHarness(answerRestartWithStop: true, holdStops: true)
            await h.store.send(.mesh(.start))
            for _ in 0..<200 where h.calls.value.isEmpty { await Task.megaYield() }
            await h.store.send(.mesh(.stop))
            await h.store.send(.mesh(.start))
            #expect(h.store.state.mesh.restartPending, "run \(run): the start did not defer")
            h.held.setValue(false)
            await h.settle(stops: 2)
            h.expectNoSessionOutlivesTheLastStop(run)
            #expect(h.calls.value == [.start(meshTestConfig), .stop, .stop], "run \(run)")
        }
    }

    /// `.concatenate(.send(.start), .send(.stop))` from a stopped interface: only the epoch
    /// keeps this start off the driver.
    @Test func aStopInTheStartsBurstFromStoppedKeepsTheStartOffTheDriver() async {
        for run in 0..<5 {
            let h = makeMeshEpochHarness(answerRestartWithStop: false, holdStops: false)
            await h.store.send(.startThenStop)
            await h.settle(stops: 1)
            h.expectNoSessionOutlivesTheLastStop(run)
            #expect(h.calls.value == [.stop], "run \(run)")
        }
    }
}
