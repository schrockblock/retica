import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let slotRadioA = UUID(uuidString: "0000EEEE-0000-0000-0000-0000000000A1")!
private let slotRadioB = UUID(uuidString: "0000FFFF-0000-0000-0000-0000000000B2")!

private func rnodeSlotParams(frequencyHz: UInt32) -> RNodeLoRaParams {
    RNodeLoRaParams(frequencyHz: frequencyHz, bandwidthHz: 125_000, txPowerDBm: 7,
                    spreadingFactor: 8, codingRate: 5)
}

private let configA = RNodeDriverConfig(radio: slotRadioA, params: rnodeSlotParams(frequencyHz: 867_200_000))
private let configB = RNodeDriverConfig(radio: slotRadioB, params: rnodeSlotParams(frequencyHz: 867_200_000))
/// The same radio as `configA`, retuned.
private let configARetuned = RNodeDriverConfig(radio: slotRadioA, params: rnodeSlotParams(frequencyHz: 869_525_000))

private let slotReport = RNodeRadioReport(firmwareMajor: 1, firmwareMinor: 86, platform: 0x80,
                                          params: rnodeSlotParams(frequencyHz: 867_200_000))

/// The whole config, so a retune of the same radio shows in the log.
private enum RNodeSlotCall: Equatable { case start(RNodeDriverConfig), stop }

/// Contract 3's slot-removal protocol exactly as lane D's app runs it: `.replaceRadio` sends
/// `.rnode(.stop)`, and the slot is replaced (nil'd, then a new one started) only at
/// `.radioOffline`. Any `RNodeDriverConfig` change replaces the slot this way (spec §6).
@Reducer
struct RNodeRadioSlotHost {
    struct State: Equatable {
        var endpoint: TransportEndpoint.State
        var next: RNodeDriverConfig?
    }

    enum Action: Equatable {
        case endpoint(TransportEndpoint.Action)
        case replaceRadio(RNodeDriverConfig)
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.endpoint, action: \.endpoint) { TransportEndpoint() }
        Reduce { state, action in
            switch action {
            case let .replaceRadio(config):
                state.next = config
                return .send(.endpoint(.rnode(.stop)))
            case .endpoint(.rnode(.delegate(.radioOffline))):
                guard let next = state.next else { return .none }
                if let slot = state.endpoint.rnode, !slot.interface.isIdle {
                    // The app's rule: offline from a non-idle slot (a deferred restart follows)
                    // is answered with another stop; the swap completes at the next offline.
                    return .send(.endpoint(.rnode(.stop)))
                }
                state.next = nil
                state.endpoint.rnode = RNodeEndpoint.State(config: next)
                return .send(.endpoint(.rnode(.start)))
            case .endpoint:
                return .none
            }
        }
    }
}

@MainActor
private struct RNodeSlotHarness {
    let store: TestStoreOf<RNodeRadioSlotHost>
    let calls: LockIsolated<[RNodeSlotCall]>
    let sessions: LockIsolated<[AsyncStream<RNodeDriverEvent>.Continuation]>
    let held: LockIsolated<Bool>

    var startCount: Int { calls.value.filter { if case .start = $0 { return true }; return false }.count }

    func waitForStarts(_ count: Int) async {
        for _ in 0..<200 where startCount < count { await Task.megaYield() }
    }

    func yieldToLatest(_ event: RNodeDriverEvent) { sessions.value.last?.yield(event) }

    func bringOnline() async {
        await waitForStarts(1)
        yieldToLatest(.connected(slotReport))
        await store.receive({ if case .endpoint(.rnode(.delegate(.radioOnline))) = $0 { return true }; return false },
                            timeout: .seconds(5))
    }

    func shutdown() async {
        held.setValue(false)
        await store.send(.endpoint(.stop))
        await Task.megaYield()
        await store.skipReceivedActions(strict: false)
    }
}

@MainActor
private func makeRNodeSlotHost(holdStops: Bool, initial config: RNodeDriverConfig = configA) -> RNodeSlotHarness {
    let calls = LockIsolated<[RNodeSlotCall]>([])
    let sessions = LockIsolated<[AsyncStream<RNodeDriverEvent>.Continuation]>([])
    let held = LockIsolated(holdStops)
    let initial = RNodeRadioSlotHost.State(
        endpoint: TransportEndpoint.State(rnode: RNodeEndpoint.State(config: config)),
        next: nil)
    let store = TestStore(initialState: initial) { RNodeRadioSlotHost() } withDependencies: {
        $0.rnodeDriver = RNodeDriver(
            start: { config in
                let session = AsyncStream<RNodeDriverEvent>.makeStream()
                // The session first, so a yield after `waitForStarts` never hits an old stream.
                sessions.withValue { $0.append(session.continuation) }
                calls.withValue { $0.append(.start(config)) }
                return session.stream
            },
            send: { _ in true },
            stop: {
                while held.value { await Task.yield() }
                sessions.value.last?.finish()
                calls.withValue { $0.append(.stop) }
            })
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.transportDate = DateGenerator { Date(timeIntervalSince1970: 0) }
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return RNodeSlotHarness(store: store, calls: calls, sessions: sessions, held: held)
}

@MainActor @Suite struct RNodeSlotReplacementTests {
    /// Nil the slot at `.radioOffline`, start a new slot: driver calls must be `start, stop,
    /// start`, never `start, start, stop`.
    @Test func aReplacedSlotStartsOnlyAfterTheOldDriverStopped() async {
        let h = makeRNodeSlotHost(holdStops: true)
        await h.store.send(.endpoint(.start))
        await h.bringOnline()
        await h.store.send(.replaceRadio(configB))
        await Task.megaYield()
        #expect(h.calls.value == [.start(configA)], "a driver call happened while the old stop was in flight")
        h.held.setValue(false)
        await h.store.receive(.endpoint(.rnode(.delegate(.radioOffline(reason: nil)))), timeout: .seconds(5))
        await h.waitForStarts(2)
        #expect(h.calls.value == [.start(configA), .stop, .start(configB)])
        await h.shutdown()
    }

    @Test func stopToANeverStartedSlotReportsRadioOfflineAtOnce() async {
        let h = makeRNodeSlotHost(holdStops: false)
        await h.store.send(.endpoint(.rnode(.stop)))
        await h.store.receive(.endpoint(.rnode(.delegate(.radioOffline(reason: nil)))), timeout: .seconds(5))
        #expect(h.calls.value.isEmpty)
    }

    /// Connect's `.start` reaches the old slot mid-stop. The interface restarts it after its stop
    /// and reports offline first; the host sees a NON-idle slot, stops again, and only then
    /// installs the new radio. Driver calls never show two starts without a stop.
    @Test func aStartReachingTheOldSlotMidStopNeverOverlapsTheNewRadiosStart() async {
        let h = makeRNodeSlotHost(holdStops: true)
        await h.store.send(.endpoint(.start))
        await h.bringOnline()
        await h.store.send(.replaceRadio(configB))
        await h.store.send(.endpoint(.rnode(.start)))
        h.held.setValue(false)
        let ended = await rnodeSlotWaitUntil(timeout: .seconds(3)) { h.calls.value.last == .start(configB) }
        #expect(ended, "calls: \(h.calls.value)")
        #expect(rnodeSlotNoOverlappingStarts(h.calls.value), "calls: \(h.calls.value)")
        await h.store.skipReceivedActions(strict: false)
        #expect(h.store.state.endpoint.rnode?.interface.config == configB)
        #expect(h.store.state.next == nil)
        await h.shutdown()
    }

    /// The same radio, retuned: the slot is replaced like any other config change, and the new
    /// params reach `driver.start` only after the old session stopped.
    @Test func aParameterChangeReplacesTheSlotTheSameWay() async {
        let h = makeRNodeSlotHost(holdStops: true)
        await h.store.send(.endpoint(.start))
        await h.bringOnline()
        await h.store.send(.replaceRadio(configARetuned))
        await Task.megaYield()
        #expect(h.calls.value == [.start(configA)], "a driver call happened while the old stop was in flight")
        h.held.setValue(false)
        await h.store.receive(.endpoint(.rnode(.delegate(.radioOffline(reason: nil)))), timeout: .seconds(5))
        await h.waitForStarts(2)
        #expect(h.calls.value == [.start(configA), .stop, .start(configARetuned)])
        await h.shutdown()
    }
}

private func rnodeSlotWaitUntil(timeout: Duration, _ condition: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// No `.start` directly follows a `.start`.
private func rnodeSlotNoOverlappingStarts(_ calls: [RNodeSlotCall]) -> Bool {
    zip(calls, calls.dropFirst()).allSatisfy { pair in
        if case .start = pair.0, case .start = pair.1 { return false }
        return true
    }
}
