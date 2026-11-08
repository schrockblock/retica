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

    @Test func disconnectCancelsAPendingReply() async {
        let h = await makeBindInterface()
        await h.hear(frame())
        await h.disconnect()
        await h.reconnect()
        await h.advance(ms: 7_000)
        #expect(h.sent.isEmpty)
        await stopMeshCoreInterface(h)
    }

    @Test func stopCancelsAPendingReply() async {
        let h = await makeBindInterface()
        await h.hear(frame())
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await h.store.send(.start)
        // The mock's stream ended with the first driver run, so connect by hand.
        await h.store.send(.driverEvent(.connected(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey,
                                                   params: sf7)))
        await h.advance(ms: 7_000)
        #expect(h.sent.isEmpty)
        await stopMeshCoreInterface(h)
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
