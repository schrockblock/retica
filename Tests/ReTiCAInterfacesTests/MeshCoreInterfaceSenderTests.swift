import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

private let codec = ScotMeshRawCodec()
/// SF 7, 62.5 kHz, CR 5: 2.5 s per datagram.
private let sf7 = MeshCoreLinkParams(spreadingFactor: 7, bandwidthHz: 62_500, codingRate: 5)
/// SF 8, 62.5 kHz, CR 8: 3378 ms per datagram.
private let sf8 = MeshCoreLinkParams(spreadingFactor: 8, bandwidthHz: 62_500, codingRate: 8)
/// The test config with the Relay setting off.
private var noRouteState: MeshCoreInterface.State {
    var config = meshCoreTestConfig
    config.canRoute = false
    return MeshCoreInterface.State(config: config)
}

/// Our framing of `packet`, as the interface should produce it.
private func ours(_ packet: Data, packetID: UInt16 = 0x1000, canRoute: Bool = true) -> [Data] {
    codec.split(packet, type: .rnsFragment, src: meshCoreOwnPrefix, dst: ScotMeshRawCodec.broadcast,
                packetID: packetID, canRoute: canRoute)
}

private func packetID(_ datagram: Data) -> UInt16 {
    UInt16(datagram[datagram.startIndex + 10]) << 8 | UInt16(datagram[datagram.startIndex + 11])
}

private func flags(_ datagram: Data) -> UInt8 { datagram[datagram.startIndex + 1] }

private extension MeshCoreInterfaceHarness {
    var sent: [Data] { calls.value.meshCoreSentDatagrams }

    func receiveSent() async {
        await store.receive { if case .datagramSent = $0 { return true }; return false }
    }

    func receiveFailedSend() async {
        await store.receive { if case .datagramSent(ok: false, _) = $0 { return true }; return false }
    }

    /// Advances the pacing clock by `ms` and lets any effect it woke run.
    func advance(ms: Int) async {
        await clock.advance(by: .milliseconds(ms))
        await Task.megaYield()
    }

    func disconnect() async {
        radio.yield(.disconnected(reason: nil))
        await store.receive { $0 == .delegate(.offline(reason: nil)) }
    }

    func reconnect(params: MeshCoreLinkParams?) async {
        radio.yield(.connected(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey, params: params))
        await store.receive { if case .delegate(.online) = $0 { return true }; return false }
    }
}

/// A host around the real interface that reduces a `.send` and a second action in ONE burst,
/// before the pump's task has started and registered its pacing cancel id: the pump escapes.
private struct MeshCoreSendBurstHost: Reducer {
    struct State: Equatable { var meshCore: MeshCoreInterface.State }

    @CasePathable
    enum Action: Equatable {
        case meshCore(MeshCoreInterface.Action)
        /// `.concatenate(.send(.send(packet)), .send(next))`.
        case sendThen(Data, MeshCoreInterface.Action)
    }

    var body: some ReducerOf<Self> {
        Reduce { _, action in
            guard case let .sendThen(packet, next) = action else { return .none }
            return .concatenate(.send(.meshCore(.send(packet))), .send(.meshCore(next)))
        }
        Scope(state: \.meshCore, action: \.meshCore) { MeshCoreInterface() }
    }
}

@MainActor
private struct MeshCoreSendBurstHarness {
    let store: TestStore<MeshCoreSendBurstHost.State, MeshCoreSendBurstHost.Action>
    let calls: LockIsolated<[MeshCoreMockCall]>
    let clock: TestClock<Duration>
    /// Holds the FIRST driver `send` only.
    let firstSendGate: MeshCoreSendGate

    var sent: [Data] { calls.value.meshCoreSentDatagrams }

    /// Polls until at least `count` sends happened, without failing: the caller's `#expect` judges.
    func waitForSends(_ count: Int) async {
        for _ in 0..<400 where sent.count < count { await Task.megaYield() }
    }

    func connect() async {
        await store.send(.meshCore(.driverEvent(.connected(selfPrefix: meshCoreOwnPrefix,
                                                            publicKey: meshCoreOwnKey, params: sf7))))
    }

    func receiveSent() async {
        await store.receive { if case .meshCore(.datagramSent) = $0 { return true }; return false }
        for _ in 0..<50 { await Task.megaYield() }
    }

    func advance(ms: Int) async {
        await clock.advance(by: .milliseconds(ms))
        for _ in 0..<50 { await Task.megaYield() }
    }
}

/// Events are delivered with `store.send`; the driver's stream ends at once. SF 7 (2.5 s pacing),
/// first packet ID `0x1000`. `sendResults` are returned by successive driver sends (then `true`).
/// The first send waits for `firstSendGate` only when `holdFirstSend`.
@MainActor
private func makeMeshCoreSendBurstHarness(sendResults: [Bool] = [],
                                          holdFirstSend: Bool = false) -> MeshCoreSendBurstHarness {
    let calls = LockIsolated<[MeshCoreMockCall]>([])
    let results = LockIsolated(sendResults)
    let clock = TestClock<Duration>()
    let gate = MeshCoreSendGate()
    if !holdFirstSend { gate.open() }
    let store = TestStore(
        initialState: MeshCoreSendBurstHost.State(meshCore: MeshCoreInterface.State(config: meshCoreTestConfig))
    ) {
        MeshCoreSendBurstHost()
    } withDependencies: {
        $0.meshCoreDriver = MeshCoreDriver(
            start: { config in
                calls.withValue { $0.append(.start(config)) }
                return AsyncStream { $0.finish() }
            },
            send: { datagram in
                let first = calls.withValue { calls -> Bool in
                    calls.append(.send(datagram))
                    return calls.meshCoreSentDatagrams.count == 1
                }
                if first { await gate.wait() }
                return results.withValue { $0.isEmpty ? true : $0.removeFirst() }
            },
            removeChannel: { true },
            stop: { calls.withValue { $0.append(.stop) } })
        $0.meshCoreClock = clock
        $0.meshCoreDate = DateGenerator { Date(timeIntervalSince1970: 1_000) }
        $0.meshCoreRandom = MeshCoreRandom(packetID: { 0x1000 }, bindDelay: { .seconds(3) })
    }
    store.exhaustivity = .off
    store.timeout = .seconds(5)
    return MeshCoreSendBurstHarness(store: store, calls: calls, clock: clock, firstSendGate: gate)
}

@MainActor @Suite struct MeshCoreInterfaceSenderTests {
    @Test func sendFramesThePacketForBroadcastFromOurPrefix() async {
        let h = await makeOnlineMeshCoreInterface(initial: noRouteState)
        let raw = meshCorePattern(300, seed: 1)
        await h.store.send(.send(raw))
        await h.receiveSent()
        let expected = codec.split(raw, type: .rnsFragment, src: meshCoreOwnPrefix,
                                   dst: ScotMeshRawCodec.broadcast, packetID: 0x1000, canRoute: false)[0]
        #expect(h.sent.first == expected)
        await stopMeshCoreInterface(h)
    }

    @Test func firstDatagramGoesOutWithoutWaiting() async {
        let h = await makeOnlineMeshCoreInterface()
        await h.store.send(.send(meshCorePattern(100, seed: 1)))
        await h.receiveSent()
        #expect(h.sent == ours(meshCorePattern(100, seed: 1)))
        await stopMeshCoreInterface(h)
    }

    @Test func nextDatagramWaitsTheFragmentDelay() async {
        let h = await makeOnlineMeshCoreInterface(params: sf7)
        await h.store.send(.send(meshCorePattern(200, seed: 1)))
        await h.receiveSent()
        await h.advance(ms: 2_499)
        #expect(h.sent.count == 1)
        await h.advance(ms: 1)
        await h.receiveSent()
        #expect(h.sent.count == 2)
        await stopMeshCoreInterface(h)
    }

    @Test func delayFollowsTheRadiosParams() async {
        let h = await makeOnlineMeshCoreInterface(params: sf8)
        await h.store.send(.send(meshCorePattern(200, seed: 1)))
        await h.receiveSent()
        await h.advance(ms: 3_377)
        #expect(h.sent.count == 1)
        await h.advance(ms: 1)
        await h.receiveSent()
        #expect(h.sent.count == 2)
        await stopMeshCoreInterface(h)
    }

    @Test func unknownParamsPaceAtFiveSeconds() async {
        let h = await makeOnlineMeshCoreInterface(params: nil)
        await h.store.send(.send(meshCorePattern(200, seed: 1)))
        await h.receiveSent()
        await h.advance(ms: 4_999)
        #expect(h.sent.count == 1)
        await h.advance(ms: 1)
        await h.receiveSent()
        #expect(h.sent.count == 2)
        await stopMeshCoreInterface(h)
    }

    @Test func nextDatagramWaitsForTheDriverToReturn() async {
        let gate = MeshCoreSendGate()
        let h = await makeOnlineMeshCoreInterface(params: sf7, sendGate: gate)
        await h.store.send(.send(meshCorePattern(200, seed: 1)))
        await h.advance(ms: 60_000)
        #expect(h.sent.count == 1)
        gate.open()
        await h.receiveSent()
        await h.advance(ms: 2_500)
        await h.receiveSent()
        #expect(h.sent.count == 2)
        await stopMeshCoreInterface(h)
    }

    @Test func sendFailureCountsSendFailed() async {
        let h = await makeOnlineMeshCoreInterface(sendResults: [false])
        await h.store.send(.send(meshCorePattern(100, seed: 1)))
        await h.receiveFailedSend()
        #expect(h.store.state.counters.sendFailed == 1)
        await stopMeshCoreInterface(h)
    }

    @Test func sendFailureDropsTheDatagram() async {
        let h = await makeOnlineMeshCoreInterface(params: sf7, sendResults: [false])
        let packet = meshCorePattern(200, seed: 1)
        await h.store.send(.send(packet))
        await h.receiveFailedSend()
        await h.advance(ms: 5_000)
        await h.receiveSent()
        #expect(h.sent.count == 2)
        #expect(h.sent.last == ours(packet)[1])
        await stopMeshCoreInterface(h)
    }

    @Test func sendFailureWaitsAnExtraFragmentDelay() async {
        let h = await makeOnlineMeshCoreInterface(params: sf7, sendResults: [false])
        await h.store.send(.send(meshCorePattern(200, seed: 1)))
        await h.receiveFailedSend()
        await h.advance(ms: 4_999)
        #expect(h.sent.count == 1)
        await h.advance(ms: 1)
        await h.receiveSent()
        #expect(h.sent.count == 2)
        await stopMeshCoreInterface(h)
    }

    /// One failed send among three: still each fragment once, in order.
    @Test func everyFragmentGoesOutExactlyOnce() async {
        let h = await makeOnlineMeshCoreInterface(params: sf7, sendResults: [false])
        let packet = meshCorePattern(400, seed: 1)
        await h.store.send(.send(packet))
        await h.receiveFailedSend()
        await h.advance(ms: 5_000)
        await h.receiveSent()
        await h.advance(ms: 2_500)
        await h.receiveSent()
        await h.advance(ms: 2_500)
        await h.advance(ms: 2_500)
        #expect(h.sent == ours(packet))
        await stopMeshCoreInterface(h)
    }

    /// One in flight, 64 queued, the 66th dropped.
    @Test func queueHoldsAtMost64Datagrams() async {
        let h = await makeOnlineMeshCoreInterface()
        for seed in 0..<66 { await h.store.send(.send(meshCorePattern(100, seed: seed))) }
        #expect(h.store.state.queuedDatagramCount == 64)
        #expect(h.store.state.counters.queueFull == 1)
        await stopMeshCoreInterface(h)
    }

    @Test func aPacketThatDoesNotFitIsDroppedWhole() async {
        let h = await makeOnlineMeshCoreInterface()
        for seed in 0..<63 { await h.store.send(.send(meshCorePattern(100, seed: seed))) }
        #expect(h.store.state.queuedDatagramCount == 62)
        await h.store.send(.send(meshCorePattern(500, seed: 99)))       // 4 datagrams: 66 > 64
        #expect(h.store.state.queuedDatagramCount == 62)
        #expect(h.store.state.counters.queueFull == 1)
        await stopMeshCoreInterface(h)
    }

    @Test func disconnectClearsTheQueue() async {
        let h = await makeOnlineMeshCoreInterface()
        await h.store.send(.send(meshCorePattern(400, seed: 1)))
        await h.receiveSent()
        await h.disconnect()
        #expect(h.store.state.queuedDatagramCount == 0)
        await stopMeshCoreInterface(h)
    }

    @Test func disconnectCancelsThePacingTimer() async {
        let h = await makeOnlineMeshCoreInterface(params: sf7)
        let a = meshCorePattern(200, seed: 1)
        let b = meshCorePattern(100, seed: 2)
        await h.store.send(.send(a))
        await h.receiveSent()
        await Task.megaYield()
        await h.disconnect()
        // The timer was running when the drop came, so it is cancelled, not merely ignored:
        // no `.pacingElapsed` reaches the reducer, stale or not.
        await h.advance(ms: 2_500)
        await h.advance(ms: 2_500)
        #expect(h.pacingElapsedCount.value == 0)
        await h.reconnect(params: sf7)
        await h.store.send(.send(b))
        await h.receiveSent()
        #expect(h.sent == [ours(a)[0], ours(b, packetID: 0x1001)[0]])
        await h.advance(ms: 2_500)
        await h.advance(ms: 2_500)
        #expect(h.sent.count == 2)
        await stopMeshCoreInterface(h)
    }

    /// A `.stop` in the send's burst misses the pump's cancel id, so the pump escapes. It must
    /// not reach the driver after the stop, nor send anything back: a host may drop the slot as
    /// soon as it is idle. A restarted radio still sends at once and paces.
    @Test func escapedPumpAfterStopNeverReachesTheDriver() async {
        let a = meshCorePattern(100, seed: 1)
        let b = meshCorePattern(200, seed: 2)
        for run in 0..<5 {
            let h = makeMeshCoreSendBurstHarness()
            await h.store.send(.meshCore(.start))
            await h.connect()
            await h.store.send(.sendThen(a, .stop))
            await h.store.receive { $0 == .meshCore(.delegate(.offline(reason: nil))) }
            #expect(h.store.state.meshCore.isIdle, "run \(run)")
            for _ in 0..<50 { await Task.megaYield() }
            await h.advance(ms: 5_000)
            #expect(h.sent.isEmpty, "run \(run): the escaped pump sent after the stop")
            await h.store.send(.meshCore(.start))
            await h.connect()
            await h.store.send(.meshCore(.send(b)))
            await h.waitForSends(1)
            await h.receiveSent()
            await h.advance(ms: 2_500)
            await h.waitForSends(2)
            #expect(h.sent == ours(b, packetID: 0x1001), "run \(run)")
            await h.store.send(.meshCore(.stop))
            await h.store.skipReceivedActions(strict: false)
        }
    }

    /// A drop in the send's burst: the pump escapes with its driver `send` still waiting on the
    /// radio, which returns a failure only after the reconnect. The drop already discarded that
    /// datagram, so the stale `.datagramSent` counts nothing, and the stale `.pacingElapsed` that
    /// follows 5 s later changes nothing either.
    @Test func staleSendFailureAfterADropIsNotCounted() async {
        let a = meshCorePattern(100, seed: 1)
        for run in 0..<5 {
            let h = makeMeshCoreSendBurstHarness(sendResults: [false], holdFirstSend: true)
            await h.store.send(.meshCore(.start))
            await h.connect()
            await h.store.send(.sendThen(a, .driverEvent(.disconnected(reason: nil))))
            await h.store.receive { $0 == .meshCore(.delegate(.offline(reason: nil))) }
            await h.waitForSends(1)
            #expect(h.sent == [ours(a)[0]], "run \(run): the pump did not escape")
            await h.connect()
            h.firstSendGate.open()
            await h.receiveSent()
            #expect(h.store.state.meshCore.counters.sendFailed == 0, "run \(run)")
            await h.advance(ms: 5_000)
            await h.store.receive { if case .meshCore(.pacingElapsed) = $0 { return true }; return false }
            #expect(!h.store.state.meshCore.pacing, "run \(run)")
            #expect(h.store.state.meshCore.counters.sendFailed == 0, "run \(run)")
            await h.store.send(.meshCore(.stop))
            await h.store.skipReceivedActions(strict: false)
        }
    }

    @Test func reconnectRecomputesTheDelay() async {
        let h = await makeOnlineMeshCoreInterface(params: sf7)
        await h.store.send(.send(meshCorePattern(100, seed: 1)))
        await h.receiveSent()
        await h.disconnect()
        await h.reconnect(params: sf8)
        await h.store.send(.send(meshCorePattern(200, seed: 2)))
        await h.receiveSent()
        await h.advance(ms: 3_377)
        #expect(h.sent.count == 2)
        await h.advance(ms: 1)
        await h.receiveSent()
        #expect(h.sent.count == 3)
        await stopMeshCoreInterface(h)
    }

    @Test func sendWhileOfflineIsDropped() async {
        let h = makeMeshCoreInterface()
        await h.store.send(.start)
        await h.store.send(.send(meshCorePattern(100, seed: 1)))
        await Task.megaYield()
        #expect(h.sent.isEmpty)
        #expect(h.store.state.queuedDatagramCount == 0)
        #expect(h.store.state.counters.queueFull == 0)
        await stopMeshCoreInterface(h)
    }

    @Test func shortPrefixSendsNothing() async {
        let h = makeMeshCoreInterface()
        await h.store.send(.start)
        h.radio.yield(.connected(selfPrefix: Data([0xA0, 0xA1, 0xA2]), publicKey: meshCoreOwnKey, params: nil))
        await h.store.receive { if case .delegate(.online) = $0 { return true }; return false }
        // Two datagrams' worth: one framed datagram would stay queued even if the sender held it.
        await h.store.send(.send(meshCorePattern(200, seed: 1)))
        await Task.megaYield()
        #expect(h.sent.isEmpty)
        #expect(h.store.state.queuedDatagramCount == 0)
        await stopMeshCoreInterface(h)
    }

    @Test func packetIDStartsAtTheInjectedRandomValue() async {
        for value: UInt16 in [0x1000, 0x2222] {
            let h = await makeOnlineMeshCoreInterface(packetID: value)
            await h.store.send(.send(meshCorePattern(100, seed: 1)))
            await h.receiveSent()
            #expect(h.sent.map(packetID) == [value])
            await stopMeshCoreInterface(h)
        }
    }

    @Test func fragmentsOfOnePacketShareAPacketID() async {
        let h = await makeOnlineMeshCoreInterface(params: sf7)
        await h.store.send(.send(meshCorePattern(400, seed: 1)))
        await h.receiveSent()
        await h.advance(ms: 2_500)
        await h.receiveSent()
        await h.advance(ms: 2_500)
        await h.receiveSent()
        #expect(h.sent.map(packetID) == [0x1000, 0x1000, 0x1000])
        await stopMeshCoreInterface(h)
    }

    @Test func packetIDAdvancesPerPacket() async {
        let h = await makeOnlineMeshCoreInterface()
        await h.store.send(.send(meshCorePattern(100, seed: 1)))
        await h.receiveSent()
        await h.store.send(.send(meshCorePattern(100, seed: 2)))
        #expect(h.sent.map(packetID) + h.store.state.queue.map(packetID) == [0x1000, 0x1001])
        await stopMeshCoreInterface(h)
    }

    @Test func packetIDWrapsFrom65535To0() async {
        let h = await makeOnlineMeshCoreInterface(packetID: 0xFFFF)
        await h.store.send(.send(meshCorePattern(100, seed: 1)))
        await h.receiveSent()
        await h.store.send(.send(meshCorePattern(100, seed: 2)))
        #expect(h.sent.map(packetID) + h.store.state.queue.map(packetID) == [0xFFFF, 0x0000])
        await stopMeshCoreInterface(h)
    }

    @Test func reconnectContinuesThePacketID() async {
        let h = await makeOnlineMeshCoreInterface()
        await h.store.send(.send(meshCorePattern(100, seed: 1)))
        await h.receiveSent()
        await h.disconnect()
        await h.reconnect(params: meshCoreTestParams)
        await h.store.send(.send(meshCorePattern(100, seed: 2)))
        await h.receiveSent()
        #expect(h.sent.map(packetID) == [0x1000, 0x1001])
        await stopMeshCoreInterface(h)
    }

    @Test func stopAndStartContinuesThePacketID() async {
        let h = await makeOnlineMeshCoreInterface()
        await h.store.send(.send(meshCorePattern(100, seed: 1)))
        await h.receiveSent()
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await h.store.send(.start)
        // The mock's stream ended with the first driver run, so connect by hand.
        await h.store.send(.driverEvent(.connected(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey,
                                                   params: meshCoreTestParams)))
        await h.store.send(.send(meshCorePattern(100, seed: 2)))
        await h.receiveSent()
        #expect(h.sent.map(packetID) == [0x1000, 0x1001])
        await stopMeshCoreInterface(h)
    }

    @Test func canRouteFromTheConfigSetsTheHeaderBit() async {
        let h = await makeOnlineMeshCoreInterface()
        await h.store.send(.send(meshCorePattern(100, seed: 1)))
        await h.receiveSent()
        #expect(h.sent.map(flags) == [0x10])
        await stopMeshCoreInterface(h)
    }

    // Review Focus 4.
    @Test func setCanRouteAffectsTheNextPacket() async {
        let h = await makeOnlineMeshCoreInterface(initial: noRouteState)
        await h.store.send(.setCanRoute(true))
        await h.store.send(.send(meshCorePattern(100, seed: 1)))
        await h.receiveSent()
        #expect(h.sent.map(flags) == [0x10])
        await stopMeshCoreInterface(h)
    }

    // Review Focus 4.
    @Test func setCanRouteDoesNotRestartTheDriver() async {
        let h = await makeOnlineMeshCoreInterface(initial: noRouteState)
        await h.store.send(.setCanRoute(true))
        await Task.megaYield()
        #expect(h.calls.value.meshCoreStartCount == 1)
        #expect(!h.calls.value.contains(.stop))
        await stopMeshCoreInterface(h)
    }

    // Review Focus 4.
    @Test func setCanRouteLeavesQueuedDatagramsAlone() async {
        let h = await makeOnlineMeshCoreInterface(params: sf7, initial: noRouteState)
        await h.store.send(.send(meshCorePattern(400, seed: 1)))
        await h.receiveSent()
        await h.store.send(.setCanRoute(true))
        await h.advance(ms: 2_500)
        await h.receiveSent()
        await h.advance(ms: 2_500)
        await h.receiveSent()
        #expect(h.sent.map(flags) == [0x00, 0x00, 0x00])
        await stopMeshCoreInterface(h)
    }
}
