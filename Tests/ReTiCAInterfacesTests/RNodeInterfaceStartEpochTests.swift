import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

/// A host around the real interface that can put a `.stop` in the SAME burst as the action that
/// builds (or queues) a start — the burst `.cancellable` cannot order, because the start's cancel
/// id is registered only once its task runs.
private struct RNodeBurstHost: Reducer {
    struct State: Equatable { var rnode: RNodeInterface.State }

    @CasePathable
    enum Action: Equatable {
        case rnode(RNodeInterface.Action)
        /// `.concatenate(.send(.start), .send(.stop))`.
        case startThenStop
    }

    /// Answer a `.driverStopped` that is about to run a deferred start with `.stop`, in its burst.
    let answerRestartWithStop: Bool

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .startThenStop:
                return .concatenate(.send(.rnode(.start)), .send(.rnode(.stop)))
            case .rnode(.driverStopped) where answerRestartWithStop && state.rnode.restartPending:
                return .send(.rnode(.stop))
            default:
                return .none
            }
        }
        Scope(state: \.rnode, action: \.rnode) { RNodeInterface() }
    }
}

@MainActor
private struct RNodeEpochHarness {
    let store: TestStore<RNodeBurstHost.State, RNodeBurstHost.Action>
    let calls: LockIsolated<[RNodeMockCall]>
    let sessions: LockIsolated<Int>
    let ended: LockIsolated<Set<Int>>
    let held: LockIsolated<Bool>

    var stopCount: Int { calls.value.filter { $0 == .stop }.count }

    /// No `driver.start()` after the last `driver.stop()` returned, and every session ended.
    func expectNoSessionOutlivesTheLastStop(_ iteration: Int) {
        let log = calls.value
        let lastStop = log.lastIndex(of: .stop) ?? -1
        #expect(!log[(lastStop + 1)...].contains(.start(rnodeTestConfig)),
                "run \(iteration): driver.start() ran after the last driver.stop(): \(log)")
        #expect(ended.value.count == sessions.value,
                "run \(iteration): \(sessions.value - ended.value.count) session(s) never ended: \(log)")
        #expect(store.state.rnode.isIdle, "run \(iteration)")
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
private func makeRNodeEpochHarness(answerRestartWithStop: Bool, holdStops: Bool) -> RNodeEpochHarness {
    let calls = LockIsolated<[RNodeMockCall]>([])
    let held = LockIsolated(holdStops)
    let sessions = LockIsolated(0)
    let ended = LockIsolated<Set<Int>>([])
    let live = LockIsolated<[AsyncStream<RNodeDriverEvent>.Continuation]>([])
    let store = TestStore(
        initialState: RNodeBurstHost.State(rnode: RNodeInterface.State(config: rnodeTestConfig))
    ) {
        RNodeBurstHost(answerRestartWithStop: answerRestartWithStop)
    } withDependencies: {
        $0.rnodeDriver = RNodeDriver(
            start: { config in
                let session = AsyncStream<RNodeDriverEvent>.makeStream()
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
    }
    store.exhaustivity = .off
    store.timeout = .seconds(5)
    return RNodeEpochHarness(store: store, calls: calls, sessions: sessions, ended: ended, held: held)
}

/// A `.stop` reduced in the same burst as the action that builds or queues a start must still
/// win. Scope: both same-burst shapes, whichever guard holds each. The from-stopped test pins
/// the epoch. The deferred-restart test pins `restartQueued`, which the epoch cannot reach.
@MainActor @Suite struct RNodeInterfaceStartEpochTests {
    /// The host answers the deferred restart's `.driverStopped` with `.stop` in that burst. Here
    /// the `restartQueued` guard, not the epoch, keeps the restart off the driver: the restart's
    /// start effect is built at `.restartDeferred`, after this stop's bump.
    @Test func aStopInTheDeferredRestartsBurstKeepsTheRestartOffTheDriver() async {
        for run in 0..<5 {
            let h = makeRNodeEpochHarness(answerRestartWithStop: true, holdStops: true)
            await h.store.send(.rnode(.start))
            for _ in 0..<200 where h.calls.value.isEmpty { await Task.megaYield() }
            await h.store.send(.rnode(.stop))
            await h.store.send(.rnode(.start))
            #expect(h.store.state.rnode.restartPending, "run \(run): the start did not defer")
            h.held.setValue(false)
            await h.settle(stops: 2)
            h.expectNoSessionOutlivesTheLastStop(run)
            #expect(h.calls.value == [.start(rnodeTestConfig), .stop, .stop], "run \(run)")
        }
    }

    /// `.concatenate(.send(.start), .send(.stop))` from a stopped interface: only the epoch
    /// keeps this start off the driver.
    @Test func aStopInTheStartsBurstFromStoppedKeepsTheStartOffTheDriver() async {
        for run in 0..<5 {
            let h = makeRNodeEpochHarness(answerRestartWithStop: false, holdStops: false)
            await h.store.send(.startThenStop)
            await h.settle(stops: 1)
            h.expectNoSessionOutlivesTheLastStop(run)
            #expect(h.calls.value == [.stop], "run \(run)")
        }
    }
}
