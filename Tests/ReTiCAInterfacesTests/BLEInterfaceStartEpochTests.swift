import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

/// A host around the real interface that can put a `.stop` in the SAME burst as the action that
/// builds a start effect — the burst `.cancellable` cannot order, because the start's cancel id is
/// registered only once its task runs.
private struct BLEBurstHost: Reducer {
    struct State: Equatable { var ble: BLEInterface.State }

    @CasePathable
    enum Action: Equatable {
        case ble(BLEInterface.Action)
        /// `.concatenate(.send(.start), .send(.stop))`.
        case startThenStop
    }

    /// Answer a `.driverStopped` that is about to run a deferred start with `.stop`, in its burst.
    let answerRestartWithStop: Bool

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .startThenStop:
                return .concatenate(.send(.ble(.start)), .send(.ble(.stop)))
            case .ble(.driverStopped) where answerRestartWithStop && state.ble.restartPending:
                return .send(.ble(.stop))
            default:
                return .none
            }
        }
        Scope(state: \.ble, action: \.ble) { BLEInterface() }
    }
}

@MainActor
private struct BLEEpochHarness {
    let store: TestStore<BLEBurstHost.State, BLEBurstHost.Action>
    let calls: LockIsolated<[MockDriverCall]>
    let sessions: LockIsolated<Int>
    let ended: LockIsolated<Set<Int>>
    let held: LockIsolated<Bool>

    var stopCount: Int { calls.value.filter { $0 == .stop }.count }

    /// No `driver.start()` after the last `driver.stop()` returned, and every session ended.
    func expectNoSessionOutlivesTheLastStop(_ iteration: Int) {
        let log = calls.value
        let lastStop = log.lastIndex(of: .stop) ?? -1
        #expect(!log[(lastStop + 1)...].contains(.start),
                "run \(iteration): driver.start() ran after the last driver.stop(): \(log)")
        #expect(ended.value.count == sessions.value,
                "run \(iteration): \(sessions.value - ended.value.count) session(s) never ended: \(log)")
        #expect(store.state.ble.isIdle, "run \(iteration)")
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
private func makeBLEEpochHarness(answerRestartWithStop: Bool, holdStops: Bool) -> BLEEpochHarness {
    let calls = LockIsolated<[MockDriverCall]>([])
    let held = LockIsolated(holdStops)
    let sessions = LockIsolated(0)
    let ended = LockIsolated<Set<Int>>([])
    let live = LockIsolated<[AsyncStream<BLEDriverEvent>.Continuation]>([])
    let initial = BLEBurstHost.State(ble: BLEInterface.State(localIdentity: localIdentity, keepaliveInterval: nil))
    let store = TestStore(initialState: initial) {
        BLEBurstHost(answerRestartWithStop: answerRestartWithStop)
    } withDependencies: {
        $0.bleDriver = BLEDriver(
            start: { _ in
                let session = AsyncStream<BLEDriverEvent>.makeStream()
                let index = sessions.withValue { n in defer { n += 1 }; return n }
                session.continuation.onTermination = { _ in ended.withValue { _ = $0.insert(index) } }
                calls.withValue { $0.append(.start) }
                live.withValue { $0.append(session.continuation) }
                return session.stream
            },
            readIdentity: { _ in }, openChannel: { _ in }, send: { _, _ in },
            closeChannel: { _ in }, disconnect: { _ in },
            stop: {
                while held.value { await Task.yield() }
                live.value.last?.finish()
                calls.withValue { $0.append(.stop) }
            })
        $0.continuousClock = TestClock<Duration>()
        $0.bleDate = DateGenerator { Date(timeIntervalSince1970: 1_000) }
    }
    store.exhaustivity = .off
    return BLEEpochHarness(store: store, calls: calls, sessions: sessions, ended: ended, held: held)
}

/// A `.stop` reduced in the same burst as a start effect's construction must still win: the
/// start's `.cancellable` id is not registered yet, so only the epoch keeps it off the driver.
@MainActor @Suite struct BLEInterfaceStartEpochTests {
    /// The host answers the deferred restart's `.driverStopped` with `.stop` in that burst.
    @Test func aStopInTheDeferredRestartsBurstKeepsTheRestartOffTheDriver() async {
        for run in 0..<5 {
            let h = makeBLEEpochHarness(answerRestartWithStop: true, holdStops: true)
            await h.store.send(.ble(.start))
            for _ in 0..<200 where h.calls.value.isEmpty { await Task.megaYield() }
            await h.store.send(.ble(.stop))
            await h.store.send(.ble(.start))
            #expect(h.store.state.ble.restartPending, "run \(run): the start did not defer")
            h.held.setValue(false)
            await h.settle(stops: 2)
            h.expectNoSessionOutlivesTheLastStop(run)
            #expect(h.calls.value == [.start, .stop, .stop], "run \(run)")
        }
    }

    /// `.concatenate(.send(.start), .send(.stop))` from a stopped interface.
    @Test func aStopInTheStartsBurstFromStoppedKeepsTheStartOffTheDriver() async {
        for run in 0..<5 {
            let h = makeBLEEpochHarness(answerRestartWithStop: false, holdStops: false)
            await h.store.send(.startThenStop)
            await h.settle(stops: 1)
            h.expectNoSessionOutlivesTheLastStop(run)
            #expect(h.calls.value == [.stop], "run \(run)")
        }
    }
}
