import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let slotRadioA = UUID(uuidString: "0000CCCC-0000-0000-0000-0000000000A1")!
private let slotRadioB = UUID(uuidString: "0000DDDD-0000-0000-0000-0000000000B2")!
private let slotPrefix = Data([1, 2, 3, 4])
private let slotKey = slotPrefix + Data(repeating: 0x11, count: 28)

private enum MeshCoreSlotCall: Equatable { case start(UUID), removeChannel, stop }

private func meshCoreSlotConfig(_ radio: UUID) -> MeshCoreDriverConfig {
    MeshCoreDriverConfig(radio: radio, channelSecret: Data(repeating: 0x22, count: 16))
}

/// Contract 3's slot-removal protocol exactly as lane E's app runs it: `.replaceRadio` sends
/// `.meshCore(.stop)`, and the slot is replaced (nil'd, then a new one started) only at
/// `.radioOffline`.
@Reducer
struct MeshCoreRadioSlotHost {
    struct State: Equatable {
        var endpoint: TransportEndpoint.State
        var next: MeshCoreDriverConfig?
    }

    enum Action: Equatable {
        case endpoint(TransportEndpoint.Action)
        case replaceRadio(MeshCoreDriverConfig)
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.endpoint, action: \.endpoint) { TransportEndpoint() }
        Reduce { state, action in
            switch action {
            case let .replaceRadio(config):
                state.next = config
                return .send(.endpoint(.meshCore(.stop)))
            case .endpoint(.meshCore(.delegate(.radioOffline))):
                guard let next = state.next else { return .none }
                if let slot = state.endpoint.meshCore, !slot.interface.isIdle {
                    // The app's rule: offline from a non-idle slot (a deferred restart follows)
                    // is answered with another stop; the swap completes at the next offline.
                    return .send(.endpoint(.meshCore(.stop)))
                }
                state.next = nil
                state.endpoint.meshCore = MeshCoreEndpoint.State(config: next)
                return .send(.endpoint(.meshCore(.start)))
            case .endpoint:
                return .none
            }
        }
    }
}

@MainActor
private struct MeshCoreSlotHarness {
    let store: TestStoreOf<MeshCoreRadioSlotHost>
    let calls: LockIsolated<[MeshCoreSlotCall]>
    let sessions: LockIsolated<[AsyncStream<MeshCoreDriverEvent>.Continuation]>
    let stopsHeld: LockIsolated<Bool>
    let removalHeld: LockIsolated<Bool>

    var startCount: Int { calls.value.filter { if case .start = $0 { return true }; return false }.count }

    func waitForStarts(_ count: Int) async {
        for _ in 0..<200 where startCount < count { await Task.megaYield() }
    }

    func yieldToLatest(_ event: MeshCoreDriverEvent) { sessions.value.last?.yield(event) }

    func bringOnline() async {
        await waitForStarts(1)
        yieldToLatest(.connected(selfPrefix: slotPrefix, publicKey: slotKey, params: nil))
        await store.receive({ if case .endpoint(.meshCore(.delegate(.radioOnline))) = $0 { return true }; return false },
                            timeout: .seconds(5))
    }

    func shutdown() async {
        stopsHeld.setValue(false)
        removalHeld.setValue(false)
        await store.send(.endpoint(.stop))
        await Task.megaYield()
        await store.skipReceivedActions(strict: false)
    }
}

@MainActor
private func makeMeshCoreSlotHost(holdStops: Bool, holdRemoval: Bool = false) -> MeshCoreSlotHarness {
    let calls = LockIsolated<[MeshCoreSlotCall]>([])
    let sessions = LockIsolated<[AsyncStream<MeshCoreDriverEvent>.Continuation]>([])
    let stopsHeld = LockIsolated(holdStops)
    let removalHeld = LockIsolated(holdRemoval)
    let initial = MeshCoreRadioSlotHost.State(
        endpoint: TransportEndpoint.State(meshCore: MeshCoreEndpoint.State(config: meshCoreSlotConfig(slotRadioA))),
        next: nil)
    let store = TestStore(initialState: initial) { MeshCoreRadioSlotHost() } withDependencies: {
        $0.meshCoreDriver = MeshCoreDriver(
            start: { config in
                let session = AsyncStream<MeshCoreDriverEvent>.makeStream()
                calls.withValue { $0.append(.start(config.radio)) }
                sessions.withValue { $0.append(session.continuation) }
                return session.stream
            },
            send: { _ in true },
            removeChannel: {
                calls.withValue { $0.append(.removeChannel) }
                while removalHeld.value { await Task.yield() }
                return true
            },
            stop: {
                while stopsHeld.value { await Task.yield() }
                sessions.value.last?.finish()
                calls.withValue { $0.append(.stop) }
            })
        $0.meshCoreClock = ImmediateClock()
        $0.meshCoreDate = DateGenerator { Date(timeIntervalSince1970: 0) }
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.transportDate = DateGenerator { Date(timeIntervalSince1970: 0) }
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return MeshCoreSlotHarness(store: store, calls: calls, sessions: sessions, stopsHeld: stopsHeld,
                               removalHeld: removalHeld)
}

@MainActor @Suite struct MeshCoreSlotReplacementTests {
    /// Nil the slot at `.radioOffline`, start a new slot: driver calls must be `start, stop,
    /// start`, never `start, start, stop`.
    @Test func aReplacedSlotStartsOnlyAfterTheOldDriverStopped() async {
        let h = makeMeshCoreSlotHost(holdStops: true)
        await h.store.send(.endpoint(.start))
        await h.bringOnline()
        await h.store.send(.replaceRadio(meshCoreSlotConfig(slotRadioB)))
        await Task.megaYield()
        #expect(h.calls.value == [.start(slotRadioA)], "a driver call happened while the old stop was in flight")
        h.stopsHeld.setValue(false)
        await h.store.receive(.endpoint(.meshCore(.delegate(.radioOffline(reason: nil)))), timeout: .seconds(5))
        await h.waitForStarts(2)
        #expect(h.calls.value == [.start(slotRadioA), .stop, .start(slotRadioB)])
        await h.shutdown()
    }

    @Test func stopToANeverStartedSlotReportsRadioOfflineAtOnce() async {
        let h = makeMeshCoreSlotHost(holdStops: false)
        await h.store.send(.endpoint(.meshCore(.stop)))
        await h.store.receive(.endpoint(.meshCore(.delegate(.radioOffline(reason: nil)))), timeout: .seconds(5))
        #expect(h.calls.value.isEmpty)
    }

    /// Connect's `.start` reaches the old slot mid-stop. The interface restarts it after its stop
    /// and reports offline first; the host sees a NON-idle slot, stops again, and only then
    /// installs the new radio. Driver calls never show two starts without a stop.
    @Test func aStartReachingTheOldSlotMidStopNeverOverlapsTheNewRadiosStart() async {
        let h = makeMeshCoreSlotHost(holdStops: true)
        await h.store.send(.endpoint(.start))
        await h.bringOnline()
        await h.store.send(.replaceRadio(meshCoreSlotConfig(slotRadioB)))
        await h.store.send(.endpoint(.meshCore(.start)))
        h.stopsHeld.setValue(false)
        let ended = await meshCoreSlotWaitUntil(timeout: .seconds(3)) { h.calls.value.last == .start(slotRadioB) }
        #expect(ended, "calls: \(h.calls.value)")
        #expect(meshCoreSlotNoOverlappingStarts(h.calls.value), "calls: \(h.calls.value)")
        await h.store.skipReceivedActions(strict: false)
        #expect(h.store.state.endpoint.meshCore?.interface.config.radio == slotRadioB)
        #expect(h.store.state.next == nil)
        await h.shutdown()
    }

    /// Review Focus 5 through the host: the feature is turned off (`removeChannel`) and the slot
    /// replaced while the removal runs. The driver sees the removal, then the stop, and the new
    /// radio starts only after both.
    @Test func removeThenStopReachesTheDriverInOrderBeforeTheSlotIsReplaced() async {
        let h = makeMeshCoreSlotHost(holdStops: true, holdRemoval: true)
        await h.store.send(.endpoint(.start))
        await h.bringOnline()
        await h.store.send(.endpoint(.meshCore(.removeChannel)))
        await h.store.send(.replaceRadio(meshCoreSlotConfig(slotRadioB)))
        h.removalHeld.setValue(false)
        await h.store.receive(.endpoint(.meshCore(.delegate(.channelRemoved(true)))), timeout: .seconds(5))
        await Task.megaYield()
        #expect(h.calls.value == [.start(slotRadioA), .removeChannel], "a driver call happened while the stop was in flight")
        h.stopsHeld.setValue(false)
        await h.store.receive(.endpoint(.meshCore(.delegate(.radioOffline(reason: nil)))), timeout: .seconds(5))
        await h.waitForStarts(2)
        #expect(h.calls.value == [.start(slotRadioA), .removeChannel, .stop, .start(slotRadioB)])
        await h.shutdown()
    }
}

private func meshCoreSlotWaitUntil(timeout: Duration, _ condition: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// No `.start` directly follows a `.start`.
private func meshCoreSlotNoOverlappingStarts(_ calls: [MeshCoreSlotCall]) -> Bool {
    zip(calls, calls.dropFirst()).allSatisfy { pair in
        if case .start = pair.0, case .start = pair.1 { return false }
        return true
    }
}
