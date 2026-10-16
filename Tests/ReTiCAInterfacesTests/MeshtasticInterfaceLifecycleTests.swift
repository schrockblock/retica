import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

@MainActor @Suite struct MeshtasticInterfaceLifecycleTests {
    @Test func startHandsTheConfigToTheDriver() async {
        let h = await makeOnlineMeshInterface()
        #expect(h.calls.value.first == .start(meshTestConfig))
        await stopMeshInterface(h)
    }

    @Test func connectedEventReportsOnlineWithItsPreset() async {
        let h = makeMeshInterface()
        await h.store.send(.start)
        h.radio.yield(.connected(myNodeNum: meshOwnNode, modemPreset: 8))
        await h.store.receive { $0 == .delegate(.online(myNodeNum: meshOwnNode, modemPreset: 8)) }
        await stopMeshInterface(h)
    }

    @Test func fragmentsFromAPeerReassembleIntoOnePacket() async {
        let h = await makeOnlineMeshInterface()
        let packet = meshPattern(400, seed: 9)
        for frame in LandandairCodec().split(packet, index: 4) {
            h.radio.yield(.fragment(from: meshPeerNode, frame))
        }
        await h.store.receive { $0 == .delegate(.packetReceived(packet)) }
        await stopMeshInterface(h)
    }

    @Test func malformedFrameIncrementsTheMalformedCounter() async {
        let h = await makeOnlineMeshInterface()
        h.radio.yield(.fragment(from: meshPeerNode, Data([0x01])))
        await h.store.receive { if case .driverEvent(.fragment) = $0 { return true }; return false }
        #expect(h.store.state.reassembler.counters.malformed == 1)
        await stopMeshInterface(h)
    }

    @Test func fragmentsBeforeTheRadioIsOnlineAreDropped() async {
        let h = makeMeshInterface()
        await h.store.send(.start)
        let frames = LandandairCodec().split(meshPattern(300, seed: 1), index: 0)
        h.radio.yield(.fragment(from: meshPeerNode, frames[0]))
        h.radio.yield(.connected(myNodeNum: meshOwnNode, modemPreset: 0))
        h.radio.yield(.fragment(from: meshPeerNode, frames[1]))
        await h.store.receive { if case let .driverEvent(.fragment(_, f)) = $0 { return f == frames[1] }; return false }
        #expect(h.store.state.reassembler.counters.completed == 0)
        await stopMeshInterface(h)
    }

    @Test func disconnectReportsOfflineWithTheReason() async {
        let h = await makeOnlineMeshInterface()
        h.radio.yield(.disconnected(reason: "link lost"))
        await h.store.receive { $0 == .delegate(.offline(reason: "link lost")) }
        await stopMeshInterface(h)
    }

    @Test func disconnectDiscardsPartialReassembly() async {
        let h = await makeOnlineMeshInterface()
        let frames = LandandairCodec().split(meshPattern(300, seed: 2), index: 0)
        h.radio.yield(.fragment(from: meshPeerNode, frames[0]))
        h.radio.yield(.disconnected(reason: nil))
        h.radio.yield(.connected(myNodeNum: meshOwnNode, modemPreset: 0))
        h.radio.yield(.fragment(from: meshPeerNode, frames[1]))
        await h.store.receive { if case let .driverEvent(.fragment(_, f)) = $0 { return f == frames[1] }; return false }
        #expect(h.store.state.reassembler.counters.completed == 0)
        await stopMeshInterface(h)
    }

    @Test func unavailableSurfacesTheCause() async {
        let h = makeMeshInterface()
        await h.store.send(.start)
        h.radio.yield(.unavailable(.poweredOff))
        await h.store.receive { $0 == .delegate(.adapterUnavailable(.poweredOff)) }
        await stopMeshInterface(h)
    }

    @Test func unavailableWhileOnlineReportsOffline() async {
        let h = await makeOnlineMeshInterface()
        h.radio.yield(.unavailable(.unauthorized))
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await stopMeshInterface(h)
    }

    @Test func stopWhileOnlineReportsOffline() async {
        let h = await makeOnlineMeshInterface()
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
    }

    @Test func stopStopsTheDriver() async {
        let h = await makeOnlineMeshInterface()
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await Task.megaYield()
        #expect(h.calls.value.contains(.stop))
    }

    /// Contract 3: the host sends `.stop` and WAITS for offline, so a radio that never came
    /// online must report it too.
    @Test func stopWhileConnectingReportsOffline() async {
        let h = makeMeshInterface()
        await h.store.send(.start)
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
    }

    @Test func startDuringASlowStopReachesTheDriverAfterTheStop() async {
        let h = await makeSlowStopMeshInterface()
        await h.store.send(.stop)
        await h.store.send(.start)
        h.releaseStop()
        await h.store.receive { $0 == .driverStopped }
        await Task.megaYield()
        #expect(h.calls.value.last == .start(meshTestConfig), "driver calls: \(h.calls.value)")
        await h.shutdown()
    }

    @Test func startDuringASlowStopBringsTheRadioOnline() async {
        let h = await makeSlowStopMeshInterface()
        await h.store.send(.stop)
        await h.store.send(.start)
        h.releaseStop()
        await h.store.receive { $0 == .driverStopped }
        await h.waitForStarts(2)
        h.yieldToLatest(.connected(myNodeNum: meshOwnNode, modemPreset: 8))
        await h.store.receive { $0 == .delegate(.online(myNodeNum: meshOwnNode, modemPreset: 8)) }
        #expect(h.store.state.isOnline)
        await h.shutdown()
    }

    @Test func stopCancelsAStartDeferredBehindASlowStop() async {
        let h = await makeSlowStopMeshInterface()
        await h.store.send(.stop)
        await h.store.send(.start)
        await h.store.send(.stop)
        h.releaseStop()
        await h.store.receive { $0 == .driverStopped }
        await Task.megaYield()
        let starts = h.calls.value.filter { if case .start = $0 { return true }; return false }.count
        #expect(starts == 1, "driver calls: \(h.calls.value)")
        #expect(h.store.state.status == .stopped)
    }
}

/// A mock radio modelled on the live adapter: every `start` opens a FRESH session stream, and
/// `stop` blocks until released, then tears down whichever session is current at that moment.
@MainActor
private struct SlowStopMeshHarness {
    let store: TestStore<MeshtasticInterface.State, MeshtasticInterface.Action>
    let calls: LockIsolated<[MeshMockCall]>
    let sessions: LockIsolated<[AsyncStream<MeshtasticDriverEvent>.Continuation]>
    let released: LockIsolated<Bool>

    func releaseStop() { released.setValue(true) }

    func yieldToLatest(_ event: MeshtasticDriverEvent) {
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
private func makeSlowStopMeshInterface() async -> SlowStopMeshHarness {
    let calls = LockIsolated<[MeshMockCall]>([])
    let sessions = LockIsolated<[AsyncStream<MeshtasticDriverEvent>.Continuation]>([])
    let released = LockIsolated(false)
    let store = TestStore(initialState: MeshtasticInterface.State(config: meshTestConfig)) {
        MeshtasticInterface()
    } withDependencies: {
        $0.meshtasticDriver = MeshtasticDriver(
            start: { config in
                let session = AsyncStream<MeshtasticDriverEvent>.makeStream()
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
        $0.meshtasticClock = TestClock<Duration>()
        $0.meshtasticDate = DateGenerator { Date(timeIntervalSince1970: 1_000) }
    }
    store.exhaustivity = .off
    await store.send(.start)
    await Task.megaYield()
    sessions.value.last?.yield(.connected(myNodeNum: meshOwnNode, modemPreset: 0))
    await store.receive { if case .delegate(.online) = $0 { return true }; return false }
    return SlowStopMeshHarness(store: store, calls: calls, sessions: sessions, released: released)
}
