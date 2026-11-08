import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

private let codec = ScotMeshRawCodec()
/// SF 7, 62.5 kHz, CR 5: 2.5 s per datagram.
private let sf7 = MeshCoreLinkParams(spreadingFactor: 7, bandwidthHz: 62_500, codingRate: 5)
private let peerKey = Data((0..<32).map { UInt8(0xB1 &+ $0) })
private let enqueueTime = Date(timeIntervalSince1970: 1_000)

/// A one-datagram frame of `type` carrying the peer's key, from `src` to `dst`.
private func frame(_ type: MeshCoreFrameType = .bindRequest, src: Data = meshCorePeerPrefix,
                   dst: Data = ScotMeshRawCodec.broadcast) -> Data {
    meshCoreDatagrams(peerKey, type: type, src: src, dst: dst, packetID: 0x3000)[0]
}

/// Our `BIND` with `packetID`, as the interface should produce it.
private func ourBind(packetID: UInt16) -> Data {
    codec.split(meshCoreOwnKey, type: .bind, src: meshCoreOwnPrefix, dst: ScotMeshRawCodec.broadcast,
                packetID: packetID, canRoute: true)[0]
}

private func packetID(_ datagram: Data) -> UInt16 {
    UInt16(datagram[datagram.startIndex + 10]) << 8 | UInt16(datagram[datagram.startIndex + 11])
}

@MainActor
private func makeBindInterface() async -> MeshCoreInterfaceHarness {
    await makeOnlineMeshCoreInterface(params: sf7, bindDelay: .seconds(7))
}

private extension MeshCoreInterfaceHarness {
    var sent: [Data] { calls.value.meshCoreSentDatagrams }

    func receiveSent() async {
        await store.receive { if case .datagramSent = $0 { return true }; return false }
    }

    /// Advances the pacing clock by `ms` and lets any effect it woke run.
    func advance(ms: Int) async {
        await clock.advance(by: .milliseconds(ms))
        await Task.megaYield()
    }

    /// Polls until at least `count` sends happened, without failing: the caller's `#expect` judges.
    func waitForSends(_ count: Int) async {
        for _ in 0..<400 where sent.count < count { await Task.megaYield() }
    }

    /// Delivers `datagram` from the radio and waits until it has been reduced.
    func hear(_ datagram: Data) async {
        radio.yield(.datagram(datagram))
        await store.receive { $0 == .driverEvent(.datagram(datagram)) }
    }

    /// One answered request: the `BIND` is enqueued (and sent) at `enqueueTime`.
    func answerOneRequest() async {
        now.setValue(enqueueTime)
        await hear(frame())
        await advance(ms: 7_000)
        await receiveSent()
    }

    func disconnect() async {
        radio.yield(.disconnected(reason: nil))
        await store.receive { $0 == .delegate(.offline(reason: nil)) }
    }

    func reconnect() async {
        radio.yield(.connected(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey, params: sf7))
        await store.receive { if case .delegate(.online) = $0 { return true }; return false }
    }
}

/// A host around the real interface that reduces a `BIND_REQ` and a drop in ONE burst, before the
/// reply timer's task has started and registered its cancel id.
private struct MeshCoreBindBurstHost: Reducer {
    struct State: Equatable { var meshCore: MeshCoreInterface.State }

    @CasePathable
    enum Action: Equatable {
        case meshCore(MeshCoreInterface.Action)
        /// `.concatenate(.send(.datagram(request)), .send(.disconnected))`.
        case requestThenDisconnect(Data)
    }

    var body: some ReducerOf<Self> {
        Reduce { _, action in
            guard case let .requestThenDisconnect(request) = action else { return .none }
            return .concatenate(.send(.meshCore(.driverEvent(.datagram(request)))),
                                .send(.meshCore(.driverEvent(.disconnected(reason: nil)))))
        }
        Scope(state: \.meshCore, action: \.meshCore) { MeshCoreInterface() }
    }
}

@MainActor
private struct MeshCoreBindBurstHarness {
    let store: TestStore<MeshCoreBindBurstHost.State, MeshCoreBindBurstHost.Action>
    let calls: LockIsolated<[MeshCoreMockCall]>
    let clock: TestClock<Duration>
    let now: LockIsolated<Date>

    var sent: [Data] { calls.value.meshCoreSentDatagrams }

    func waitForSends(_ count: Int) async {
        for _ in 0..<400 where sent.count < count { await Task.megaYield() }
    }
}

/// Events are delivered with `store.send`; the driver's stream ends at once. Date `enqueueTime`,
/// `BIND` delay 7 s, first packet ID `0x1000`.
@MainActor
private func makeMeshCoreBindBurstHarness() -> MeshCoreBindBurstHarness {
    let calls = LockIsolated<[MeshCoreMockCall]>([])
    let clock = TestClock<Duration>()
    let now = LockIsolated(enqueueTime)
    let store = TestStore(
        initialState: MeshCoreBindBurstHost.State(meshCore: MeshCoreInterface.State(config: meshCoreTestConfig))
    ) {
        MeshCoreBindBurstHost()
    } withDependencies: {
        $0.meshCoreDriver = MeshCoreDriver(
            start: { config in
                calls.withValue { $0.append(.start(config)) }
                return AsyncStream { $0.finish() }
            },
            send: { datagram in
                calls.withValue { $0.append(.send(datagram)) }
                return true
            },
            removeChannel: { true },
            stop: { calls.withValue { $0.append(.stop) } })
        $0.meshCoreClock = clock
        $0.meshCoreDate = DateGenerator { now.value }
        $0.meshCoreRandom = MeshCoreRandom(packetID: { 0x1000 }, bindDelay: { .seconds(7) })
    }
    store.exhaustivity = .off
    store.timeout = .seconds(5)
    return MeshCoreBindBurstHarness(store: store, calls: calls, clock: clock, now: now)
}

@MainActor @Suite struct MeshCoreInterfaceBindTests {
    @Test func bindRequestIsAnsweredAfterTheRandomDelay() async {
        let h = await makeBindInterface()
        await h.hear(frame())
        await h.advance(ms: 6_999)
        #expect(h.sent.isEmpty)
        await h.advance(ms: 1)
        await h.receiveSent()
        #expect(h.sent.count == 1)
        await stopMeshCoreInterface(h)
    }

    @Test func bindReplyIsByteExact() async throws {
        let h = await makeBindInterface()
        await h.answerOneRequest()
        let reply = try #require(h.sent.first)
        let parsed = try #require(codec.parse(reply))
        #expect(parsed.type == .bind)
        #expect(parsed.src == meshCoreOwnPrefix)
        #expect(parsed.dst == Data(repeating: 0, count: 4))
        #expect(parsed.body == meshCoreOwnKey)
        #expect(parsed.fragmentIndex == 0)
        #expect(parsed.fragmentTotal == 1)
        #expect(reply.count == 46)
        await stopMeshCoreInterface(h)
    }

    @Test func bindReplyCarriesTheCanRouteBit() async {
        let h = await makeBindInterface()
        await h.answerOneRequest()
        #expect(h.sent.map { $0[$0.startIndex + 1] } == [0x12])
        await stopMeshCoreInterface(h)
    }

    @Test func bindRequestAddressedToUsIsAnswered() async {
        let h = await makeBindInterface()
        await h.hear(frame(dst: meshCoreOwnPrefix))
        await h.advance(ms: 7_000)
        await h.receiveSent()
        #expect(h.sent == [ourBind(packetID: 0x1000)])
        await stopMeshCoreInterface(h)
    }

    @Test func bindRequestForAnotherPrefixIsNotAnswered() async {
        let h = await makeBindInterface()
        await h.hear(frame(dst: Data([0xC1, 0xC2, 0xC3, 0xC4])))
        #expect(h.store.state.counters.notAddressed == 1)
        await h.advance(ms: 7_000)
        #expect(h.sent.isEmpty)
        await stopMeshCoreInterface(h)
    }

    @Test func furtherRequestsWhileAReplyIsPendingDoNothing() async {
        let h = await makeBindInterface()
        for _ in 0..<3 { await h.hear(frame()) }
        await h.advance(ms: 7_000)
        await h.receiveSent()
        await h.advance(ms: 2_500)
        await h.advance(ms: 2_500)
        #expect(h.sent.count == 1)
        await stopMeshCoreInterface(h)
    }

    @Test func requestWithin60SecondsOfABindDoesNothing() async {
        let h = await makeBindInterface()
        await h.answerOneRequest()
        h.now.setValue(enqueueTime.addingTimeInterval(59.9))
        await h.hear(frame())
        #expect(!h.store.state.bindReplyPending)
        await h.advance(ms: 7_000)
        #expect(h.sent.count == 1)
        await stopMeshCoreInterface(h)
    }

    @Test func requestAt60SecondsIsAnswered() async {
        let h = await makeBindInterface()
        await h.answerOneRequest()
        h.now.setValue(enqueueTime.addingTimeInterval(60))
        await h.hear(frame())
        await h.advance(ms: 7_000)
        await h.receiveSent()
        #expect(h.sent == [ourBind(packetID: 0x1000), ourBind(packetID: 0x1001)])
        await stopMeshCoreInterface(h)
    }

    @Test func ourOwnBindRequestEchoIsNotAnswered() async {
        let h = await makeBindInterface()
        await h.hear(frame(src: meshCoreOwnPrefix))
        await h.advance(ms: 7_000)
        #expect(h.sent.isEmpty)
        await stopMeshCoreInterface(h)
    }

    @Test func incomingBindIsNotAnswered() async {
        let h = await makeBindInterface()
        await h.hear(frame(.bind))
        await h.advance(ms: 7_000)
        #expect(h.sent.isEmpty)
        await stopMeshCoreInterface(h)
    }

    /// A request at 0 s, a drop, and a fresh request at 3 s: the reply is the fresh request's, at
    /// 10 s. A surviving first timer would answer at 7 s (the fresh request re-arms the pending
    /// flag its guard checks).
    @Test func disconnectCancelsAPendingReply() async {
        let h = await makeBindInterface()
        await h.hear(frame())
        await h.disconnect()
        await h.reconnect()
        await h.advance(ms: 3_000)
        await h.hear(frame())
        await h.advance(ms: 4_000)
        #expect(h.sent.isEmpty)
        await h.advance(ms: 3_000)
        await h.waitForSends(1)
        #expect(h.sent == [ourBind(packetID: 0x1000)])
        await stopMeshCoreInterface(h)
    }

    /// As `disconnectCancelsAPendingReply`, with a stop and start in place of the drop.
    @Test func stopCancelsAPendingReply() async {
        let h = await makeBindInterface()
        await h.hear(frame())
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await h.store.send(.start)
        // The mock's stream ended with the first driver run, so deliver events by hand.
        await h.store.send(.driverEvent(.connected(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey,
                                                   params: sf7)))
        await h.advance(ms: 3_000)
        await h.store.send(.driverEvent(.datagram(frame())))
        await h.advance(ms: 4_000)
        #expect(h.sent.isEmpty)
        await h.advance(ms: 3_000)
        await h.waitForSends(1)
        #expect(h.sent == [ourBind(packetID: 0x1000)])
        await stopMeshCoreInterface(h)
    }

    // Review Focus 1.
    @Test func backwardsClockExpiresTheBindWindow() async {
        let h = await makeBindInterface()
        await h.answerOneRequest()
        h.now.setValue(enqueueTime.addingTimeInterval(-10))
        await h.hear(frame())
        await h.advance(ms: 7_000)
        await h.waitForSends(2)
        #expect(h.sent == [ourBind(packetID: 0x1000), ourBind(packetID: 0x1001)])
        await stopMeshCoreInterface(h)
    }

    /// The request comes 70 s after a `BIND`; by the time its delay elapses the wall clock reads
    /// 30 s after it. The window is checked again before the reply is queued.
    @Test func bindWindowIsRecheckedWhenTheReplyDelayElapses() async {
        let h = await makeBindInterface()
        await h.answerOneRequest()
        h.now.setValue(enqueueTime.addingTimeInterval(70))
        await h.hear(frame())
        #expect(h.store.state.bindReplyPending)
        h.now.setValue(enqueueTime.addingTimeInterval(30))
        await h.advance(ms: 7_000)
        await h.advance(ms: 2_500)
        #expect(h.sent.count == 1)
        await stopMeshCoreInterface(h)
    }

    /// A drop reduced in the request's burst, before the timer task registers its cancel id: the
    /// timer escapes. After a reconnect a fresh request arms a second timer. Only one `BIND` goes
    /// out. The wall clock is moved past 60 s between the two timers, so only the pending guard,
    /// not the 60 s window, can stop the second.
    @Test func escapedBindTimerDoesNotSendASecondBind() async {
        let connected = MeshCoreDriverEvent.connected(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey,
                                                      params: sf7)
        for run in 0..<5 {
            let h = makeMeshCoreBindBurstHarness()
            await h.store.send(.meshCore(.start))
            await h.store.send(.meshCore(.driverEvent(connected)))
            await h.store.send(.requestThenDisconnect(frame()))
            await h.store.receive { $0 == .meshCore(.delegate(.offline(reason: nil))) }
            await h.store.send(.meshCore(.driverEvent(connected)))
            await h.clock.advance(by: .seconds(3))
            await h.store.send(.meshCore(.driverEvent(.datagram(frame()))))
            await h.clock.advance(by: .seconds(4))
            await h.waitForSends(1)
            // The escaped timer fired at 7 s and answered the fresh request.
            #expect(h.sent == [ourBind(packetID: 0x1000)], "run \(run): the first timer did not escape")
            h.now.setValue(enqueueTime.addingTimeInterval(61))
            await h.clock.advance(by: .seconds(3))
            for _ in 0..<50 { await Task.megaYield() }
            await h.clock.advance(by: .seconds(3))
            for _ in 0..<50 { await Task.megaYield() }
            #expect(h.sent == [ourBind(packetID: 0x1000)], "run \(run)")
            await h.store.send(.meshCore(.stop))
            await h.store.skipReceivedActions(strict: false)
        }
    }

    @Test func sixtySecondLimitSurvivesADisconnect() async {
        let h = await makeBindInterface()
        await h.answerOneRequest()
        await h.disconnect()
        await h.reconnect()
        h.now.setValue(enqueueTime.addingTimeInterval(30))
        await h.hear(frame())
        await h.advance(ms: 7_000)
        #expect(h.sent.count == 1)
        await stopMeshCoreInterface(h)
    }

    @Test func bindConsumesAPacketID() async {
        let h = await makeBindInterface()
        await h.answerOneRequest()
        await h.store.send(.send(meshCorePattern(100, seed: 1)))     // inside the BIND's pacing window
        #expect(h.sent.map(packetID) == [0x1000])
        #expect(h.store.state.queue.map(packetID) == [0x1001])
        await stopMeshCoreInterface(h)
    }

    /// Five data datagrams go out at 0, 2.5, 5, 7.5 and 10 s; the `BIND` enqueued at 7 s waits
    /// behind them and goes at 12.5 s.
    @Test func bindGoesThroughThePacedQueue() async {
        let h = await makeBindInterface()
        let data = meshCorePattern(600, seed: 1)
        let dataFrames = codec.split(data, type: .rnsFragment, src: meshCoreOwnPrefix,
                                     dst: ScotMeshRawCodec.broadcast, packetID: 0x1000, canRoute: true)
        #expect(dataFrames.count == 5)
        await h.store.send(.send(data))
        await h.receiveSent()
        await h.hear(frame())
        for expected in 2...4 {
            await h.advance(ms: 2_500)
            await h.receiveSent()
            #expect(h.sent.count == expected)
        }
        await h.advance(ms: 2_500)
        await h.receiveSent()
        await h.advance(ms: 2_500)
        await h.receiveSent()
        #expect(h.sent == dataFrames + [ourBind(packetID: 0x1001)])
        await stopMeshCoreInterface(h)
    }

    @Test func neverSendsABindRequest() async {
        let h = await makeBindInterface()
        await h.store.send(.send(meshCorePattern(100, seed: 1)))
        await h.receiveSent()
        await h.flush()
        await h.hear(frame())
        await h.advance(ms: 7_000)
        await h.receiveSent()
        #expect(h.sent.count == 2)
        #expect(!h.sent.contains { codec.parse($0)?.type == .bindRequest })
        await stopMeshCoreInterface(h)
    }
}
