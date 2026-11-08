import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

@MainActor @Suite struct RNodeInterfaceLifecycleTests {
    // MARK: - Lifecycle

    @Test func startHandsTheConfigToTheDriver() async {
        let h = await makeOnlineRNodeInterface()
        #expect(h.calls.value == [.start(rnodeTestConfig)])
        await stopRNodeInterface(h)
    }

    @Test func connectedEventReportsOnlineWithItsReport() async {
        let h = makeRNodeInterface()
        await h.store.send(.start)
        h.radio.yield(.connected(rnodeTestReport))
        await h.store.receive { $0 == .delegate(.online(rnodeTestReport)) }
        #expect(h.store.state.report == rnodeTestReport)
        #expect(h.store.state.status == .online(rnodeTestReport))
        await stopRNodeInterface(h)
    }

    /// The radio reconnects (or re-reports) with different echoed params: the host must hear
    /// about it, so it can re-register with the new bitrate.
    @Test func aSecondConnectedReportsOnlineAgain() async {
        var clamped = rnodeTestReport
        clamped.params.spreadingFactor = 9
        clamped.params.txPowerDBm = 14
        let h = await makeOnlineRNodeInterface()
        h.radio.yield(.connected(clamped))
        await h.store.receive { $0 == .delegate(.online(clamped)) }
        let onlines = h.delegates.value.compactMap { if case let .online(report) = $0 { return report }; return nil }
        #expect(onlines == [rnodeTestReport, clamped])
        #expect(h.store.state.report?.params == clamped.params)
        await stopRNodeInterface(h)
    }

    @Test func unavailableSurfacesTheCause() async {
        let h = makeRNodeInterface()
        await h.store.send(.start)
        h.radio.yield(.unavailable(.poweredOff))
        await h.store.receive { $0 == .delegate(.adapterUnavailable(.poweredOff)) }
        await stopRNodeInterface(h)
    }

    @Test func userActionMessagesSurfaceVerbatim() async {
        let cause = BLEAdapterUnavailable.other("This RNode's firmware is too old. Update it to 1.52 or later.")
        let h = makeRNodeInterface()
        await h.store.send(.start)
        h.radio.yield(.unavailable(cause))
        await h.store.receive { $0 == .delegate(.adapterUnavailable(cause)) }
        #expect(h.store.state.status == .unavailable(cause))
        await stopRNodeInterface(h)
    }

    /// After `.unavailable(.poweredOff)` a `.disconnected(nil)` (the session retrying) means the
    /// adapter is back: status is `.connecting`, and a `.start` must not restart the driver.
    @Test func aReconnectAttemptAfterUnavailableIsConnectingAndBlocksStart() async {
        let h = await makeOnlineRNodeInterface()
        h.radio.yield(.disconnected(reason: nil))
        await h.store.receive { $0 == .driverEvent(.disconnected(reason: nil)) }
        h.radio.yield(.unavailable(.poweredOff))
        await h.store.receive { $0 == .delegate(.adapterUnavailable(.poweredOff)) }
        #expect(h.store.state.status == .unavailable(.poweredOff))
        h.radio.yield(.disconnected(reason: nil))
        await h.store.receive { $0 == .driverEvent(.disconnected(reason: nil)) }
        #expect(h.store.state.status == .connecting)
        let startsBefore = h.calls.value.rnodeStartCount
        await h.store.send(.start)
        #expect(h.calls.value.rnodeStartCount == startsBefore)
        await stopRNodeInterface(h)
    }

    @Test func unavailableWhileOnlineReportsOffline() async {
        let h = await makeOnlineRNodeInterface()
        h.radio.yield(.unavailable(.unauthorized))
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await stopRNodeInterface(h)
    }

    @Test func stopStopsTheDriver() async {
        let h = await makeOnlineRNodeInterface()
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await Task.megaYield()
        #expect(h.calls.value.contains(.stop))
    }

    /// Contract 3: the host sends `.stop` and WAITS for offline, so a radio that never came
    /// online must report it too.
    @Test func stopWhileConnectingReportsOffline() async {
        let h = makeRNodeInterface()
        await h.store.send(.start)
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
    }

    @Test func startDuringASlowStopReachesTheDriverAfterTheStop() async {
        let h = await makeSlowStopRNodeInterface()
        await h.store.send(.stop)
        await h.store.send(.start)
        h.releaseStop()
        await h.store.receive { $0 == .driverStopped }
        await h.waitForStarts(2)
        #expect(h.calls.value.last == .start(rnodeTestConfig), "driver calls: \(h.calls.value)")
        await h.shutdown()
    }

    @Test func startDuringASlowStopBringsTheRadioOnline() async {
        let h = await makeSlowStopRNodeInterface()
        await h.store.send(.stop)
        await h.store.send(.start)
        h.releaseStop()
        await h.store.receive { $0 == .driverStopped }
        await h.waitForStarts(2)
        h.yieldToLatest(.connected(rnodeTestReport))
        await h.store.receive { $0 == .delegate(.online(rnodeTestReport)) }
        #expect(h.store.state.isOnline)
        await h.shutdown()
    }

    @Test func stopCancelsAStartDeferredBehindASlowStop() async {
        let h = await makeSlowStopRNodeInterface()
        await h.store.send(.stop)
        await h.store.send(.start)
        await h.store.send(.stop)
        h.releaseStop()
        await h.store.receive { $0 == .driverStopped }
        await Task.megaYield()
        #expect(h.calls.value.rnodeStartCount == 1, "driver calls: \(h.calls.value)")
        #expect(h.store.state.status == .stopped)
    }

    @Test func eventsAfterStopAreIgnored() async {
        let h = makeRNodeInterface()
        await h.store.send(.start)
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await h.store.send(.driverEvent(.connected(rnodeTestReport)))
        await Task.megaYield()
        #expect(h.store.state.status == .stopped)
        #expect(!h.delegates.value.contains { if case .online = $0 { return true }; return false })
    }

    @Test func disconnectReportsOfflineWithTheReason() async {
        let h = await makeOnlineRNodeInterface()
        h.radio.yield(.disconnected(reason: "link lost"))
        await h.store.receive { $0 == .delegate(.offline(reason: "link lost")) }
        await stopRNodeInterface(h)
    }

    // MARK: - Receive

    @Test func packetBeforeOnlineIsDropped() async {
        let h = makeRNodeInterface()
        await h.store.send(.start)
        let packet = Data(repeating: 0x42, count: 40)
        h.radio.yield(.packet(packet, rssi: nil, snr: nil))
        await h.store.receive { $0 == .driverEvent(.packet(packet, rssi: nil, snr: nil)) }
        #expect(h.store.state.status == .connecting)
        #expect(h.packets.isEmpty)
        #expect(h.store.state.diagnostics.received == 0)
        await stopRNodeInterface(h)
    }

    @Test func packetWhileOnlineIsDelivered() async {
        let h = await makeOnlineRNodeInterface()
        let packet = Data((0..<200).map { UInt8($0 & 0xFF) })
        h.radio.yield(.packet(packet, rssi: -97, snr: 6.25))
        await h.store.receive { $0 == .delegate(.packetReceived(packet)) }
        #expect(h.packets == [packet])
        #expect(h.store.state.diagnostics.received == 1)
        await stopRNodeInterface(h)
    }

    // MARK: - Diagnostics

    @Test func diagnosticsCarryEveryCounter() {
        var state = RNodeInterface.State(config: rnodeTestConfig)
        state.counters = RNodeCounters(received: 1, sent: 2, oversize: 3, queueFull: 4, sendFailed: 5,
                                       hardwareErrors: 6)
        #expect(state.diagnostics == RNodeCounters(received: 1, sent: 2, oversize: 3, queueFull: 4,
                                                   sendFailed: 5, hardwareErrors: 6))
    }
}

// MARK: - Slow-stop harness

/// A mock radio modelled on the live adapter: every `start` opens a FRESH session stream, and
/// `stop` blocks until released, then tears down whichever session is current at that moment.
@MainActor
private struct SlowStopRNodeHarness {
    let store: TestStore<RNodeInterface.State, RNodeInterface.Action>
    let calls: LockIsolated<[RNodeMockCall]>
    let sessions: LockIsolated<[AsyncStream<RNodeDriverEvent>.Continuation]>
    let released: LockIsolated<Bool>

    func releaseStop() { released.setValue(true) }

    func yieldToLatest(_ event: RNodeDriverEvent) {
        sessions.value.last?.yield(event)
    }

    func waitForStarts(_ count: Int) async {
        for _ in 0..<100 where sessions.value.count < count { await Task.megaYield() }
    }

    func shutdown() async {
        released.setValue(true)
        await store.send(.stop)
        await Task.megaYield()
        await store.skipReceivedActions(strict: false)
    }
}

/// Started and online; the next `stop` waits for `releaseStop()`.
@MainActor
private func makeSlowStopRNodeInterface() async -> SlowStopRNodeHarness {
    let calls = LockIsolated<[RNodeMockCall]>([])
    let sessions = LockIsolated<[AsyncStream<RNodeDriverEvent>.Continuation]>([])
    let released = LockIsolated(false)
    let store = TestStore(initialState: RNodeInterface.State(config: rnodeTestConfig)) {
        RNodeInterface()
    } withDependencies: {
        $0.rnodeDriver = RNodeDriver(
            start: { config in
                let session = AsyncStream<RNodeDriverEvent>.makeStream()
                calls.withValue { $0.append(.start(config)) }
                sessions.withValue { $0.append(session.continuation) }
                return session.stream
            },
            send: { _ in true },
            stop: {
                while !released.value { await Task.yield() }
                sessions.value.last?.finish()
                calls.withValue { $0.append(.stop) }
            }
        )
    }
    store.exhaustivity = .off
    store.timeout = .seconds(5)
    await store.send(.start)
    for _ in 0..<200 where sessions.value.isEmpty { await Task.megaYield() }
    sessions.value.last?.yield(.connected(rnodeTestReport))
    await store.receive { if case .delegate(.online) = $0 { return true }; return false }
    return SlowStopRNodeHarness(store: store, calls: calls, sessions: sessions, released: released)
}
