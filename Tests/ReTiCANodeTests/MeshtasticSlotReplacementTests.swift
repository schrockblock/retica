import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let slotRadioA = UUID(uuidString: "0000AAAA-0000-0000-0000-0000000000A1")!
private let slotRadioB = UUID(uuidString: "0000BBBB-0000-0000-0000-0000000000B2")!

private enum SlotRadioCall: Equatable { case start(UUID), stop }

/// Contract 3's slot-removal protocol exactly as lane E's app runs it: `.replaceRadio` sends
/// `.meshtastic(.stop)`, and the slot is replaced (nil'd, then a new one started) only at
/// `.radioOffline`.
@Reducer
struct MeshtasticRadioSlotHost {
    struct State: Equatable {
        var endpoint: TransportEndpoint.State
        var next: MeshtasticDriverConfig?
    }

    enum Action: Equatable {
        case endpoint(TransportEndpoint.Action)
        case replaceRadio(MeshtasticDriverConfig)
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.endpoint, action: \.endpoint) { TransportEndpoint() }
        Reduce { state, action in
            switch action {
            case let .replaceRadio(config):
                state.next = config
                return .send(.endpoint(.meshtastic(.stop)))
            case .endpoint(.meshtastic(.delegate(.radioOffline))):
                guard let next = state.next else { return .none }
                if let slot = state.endpoint.meshtastic, !slot.interface.isIdle {
                    // The app's rule: offline from a non-idle slot (a deferred restart follows)
                    // is answered with another stop; the swap completes at the next offline.
                    return .send(.endpoint(.meshtastic(.stop)))
                }
                state.next = nil
                state.endpoint.meshtastic = MeshtasticEndpoint.State(config: next)
                return .send(.endpoint(.meshtastic(.start)))
            case .endpoint, .replaceRadio:
                return .none
            }
        }
    }
}

@MainActor
private struct SlotHostHarness {
    let store: TestStoreOf<MeshtasticRadioSlotHost>
    let calls: LockIsolated<[SlotRadioCall]>
    let sessions: LockIsolated<[AsyncStream<MeshtasticDriverEvent>.Continuation]>
    let held: LockIsolated<Bool>

    var startCount: Int { calls.value.filter { if case .start = $0 { return true }; return false }.count }

    func waitForStarts(_ count: Int) async {
        for _ in 0..<200 where startCount < count { await Task.megaYield() }
    }

    func yieldToLatest(_ event: MeshtasticDriverEvent) { sessions.value.last?.yield(event) }

    func shutdown() async {
        held.setValue(false)
        await store.send(.endpoint(.stop))
        await Task.megaYield()
        await store.skipReceivedActions(strict: false)
    }
}

@MainActor
private func makeSlotHost(holdStops: Bool) -> SlotHostHarness {
    let calls = LockIsolated<[SlotRadioCall]>([])
    let sessions = LockIsolated<[AsyncStream<MeshtasticDriverEvent>.Continuation]>([])
    let held = LockIsolated(holdStops)
    let initial = MeshtasticRadioSlotHost.State(
        endpoint: TransportEndpoint.State(
            meshtastic: MeshtasticEndpoint.State(config: MeshtasticDriverConfig(radio: slotRadioA))),
        next: nil)
    let store = TestStore(initialState: initial) { MeshtasticRadioSlotHost() } withDependencies: {
        $0.meshtasticDriver = MeshtasticDriver(
            start: { config in
                let session = AsyncStream<MeshtasticDriverEvent>.makeStream()
                calls.withValue { $0.append(.start(config.radio)) }
                sessions.withValue { $0.append(session.continuation) }
                return session.stream
            },
            send: { _ in true },
            stop: {
                while held.value { await Task.yield() }
                sessions.value.last?.finish()
                calls.withValue { $0.append(.stop) }
            })
        $0.meshtasticClock = ImmediateClock()
        $0.meshtasticDate = DateGenerator { Date(timeIntervalSince1970: 0) }
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.transportDate = DateGenerator { Date(timeIntervalSince1970: 0) }
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return SlotHostHarness(store: store, calls: calls, sessions: sessions, held: held)
}

@MainActor @Suite struct MeshtasticSlotReplacementTests {
    /// Spec §7 E.0(a): nil the slot at `.radioOffline`, start a new slot — driver calls must be
    /// `start, stop, start`, never `start, start, stop`.
    @Test func aReplacedSlotStartsOnlyAfterTheOldDriverStopped() async {
        let h = makeSlotHost(holdStops: true)
        await h.store.send(.endpoint(.start))
        await h.waitForStarts(1)
        h.yieldToLatest(.connected(myNodeNum: 0x0A0A_0A0A, modemPreset: 8))
        await h.store.receive { if case .endpoint(.meshtastic(.delegate(.radioOnline))) = $0 { return true }; return false }
        await h.store.send(.replaceRadio(MeshtasticDriverConfig(radio: slotRadioB)))
        await Task.megaYield()
        #expect(h.calls.value == [.start(slotRadioA)], "a driver call happened while the old stop was in flight")
        h.held.setValue(false)
        await h.store.receive { $0 == .endpoint(.meshtastic(.delegate(.radioOffline(reason: nil)))) }
        await h.waitForStarts(2)
        #expect(h.calls.value == [.start(slotRadioA), .stop, .start(slotRadioB)])
        await h.shutdown()
    }

    @Test func stopToANeverStartedSlotReportsRadioOfflineAtOnce() async {
        let h = makeSlotHost(holdStops: false)
        await h.store.send(.endpoint(.meshtastic(.stop)))
        await h.store.receive { $0 == .endpoint(.meshtastic(.delegate(.radioOffline(reason: nil)))) }
        #expect(h.calls.value.isEmpty)
    }

    /// Review Focus 5: Connect's `.start` reaches the old slot mid-stop. The interface restarts
    /// it after its stop and reports offline first; the host sees a NON-idle slot, stops again,
    /// and only then installs the new radio. Driver calls never show two starts without a stop.
    @Test func aStartReachingTheOldSlotMidStopNeverOverlapsTheNewRadiosStart() async {
        let h = makeSlotHost(holdStops: true)
        await h.store.send(.endpoint(.start))
        await h.waitForStarts(1)
        h.yieldToLatest(.connected(myNodeNum: 0x0A0A_0A0A, modemPreset: 8))
        await h.store.receive { if case .endpoint(.meshtastic(.delegate(.radioOnline))) = $0 { return true }; return false }
        await h.store.send(.replaceRadio(MeshtasticDriverConfig(radio: slotRadioB)))
        await h.store.send(.endpoint(.meshtastic(.start)))
        h.held.setValue(false)
        let ended = await slotWaitUntil(timeout: .seconds(3)) { h.calls.value.last == .start(slotRadioB) }
        #expect(ended, "calls: \(h.calls.value)")
        #expect(slotNoOverlappingStarts(h.calls.value), "calls: \(h.calls.value)")
        await h.store.skipReceivedActions(strict: false)
        #expect(h.store.state.endpoint.meshtastic?.interface.config.radio == slotRadioB)
        #expect(h.store.state.next == nil)
        await h.shutdown()
    }
}

private func slotWaitUntil(timeout: Duration, _ condition: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// No `.start` directly follows a `.start`.
private func slotNoOverlappingStarts(_ calls: [SlotRadioCall]) -> Bool {
    zip(calls, calls.dropFirst()).allSatisfy { pair in
        if case .start = pair.0, case .start = pair.1 { return false }
        return true
    }
}
