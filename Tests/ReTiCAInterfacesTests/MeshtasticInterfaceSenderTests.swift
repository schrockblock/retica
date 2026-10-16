import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

private func request(_ index: UInt8, _ pos: UInt8) -> Data { Data("REQ".utf8) + Data([index, pos]) }
private let codec = LandandairCodec()
private let longFast = 0      // 8 s per fragment
private let shortTurbo = 8    // 0.4 s per fragment

@MainActor
private func receiveSent(_ h: MeshInterfaceHarness) async {
    await h.store.receive { if case .fragmentSent = $0 { return true }; return false }
}

@MainActor
private func receiveFragmentEvent(_ h: MeshInterfaceHarness) async {
    await h.store.receive { if case .driverEvent(.fragment) = $0 { return true }; return false }
}

@MainActor @Suite struct MeshtasticInterfaceSenderTests {
    @Test func firstFragmentGoesOutImmediately() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        let packet = meshPattern(500, seed: 1)
        await h.store.send(.send(packet))
        await receiveSent(h)
        #expect(h.calls.value.sentFrames == [codec.split(packet, index: 0)[0]])
        await stopMeshInterface(h)
    }

    @Test func nextFragmentWaitsTheFullLongFastDelay() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        let packet = meshPattern(500, seed: 1)
        await h.store.send(.send(packet))
        await receiveSent(h)
        await h.clock.advance(by: .milliseconds(7_999))
        await Task.megaYield()
        #expect(h.calls.value.sentFrames.count == 1)
        await h.clock.advance(by: .milliseconds(1))
        await receiveSent(h)
        #expect(h.calls.value.sentFrames == Array(codec.split(packet, index: 0).prefix(2)))
        await stopMeshInterface(h)
    }

    @Test func shortTurboPacesFragmentsAt400Milliseconds() async {
        let h = await makeOnlineMeshInterface(modemPreset: shortTurbo)
        await h.store.send(.send(meshPattern(500, seed: 2)))
        await receiveSent(h)
        await h.clock.advance(by: .milliseconds(399))
        await Task.megaYield()
        #expect(h.calls.value.sentFrames.count == 1)
        await h.clock.advance(by: .milliseconds(1))
        await receiveSent(h)
        #expect(h.calls.value.sentFrames.count == 2)
        await stopMeshInterface(h)
    }

    /// 85 three-fragment packets: one fragment in flight, 254 queued. An 86th (3 more → 257 > 256)
    /// is dropped whole.
    @Test func packetThatDoesNotFitIsDroppedWhole() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        for seed in 0..<85 { await h.store.send(.send(meshPattern(500, seed: seed))) }
        #expect(h.store.state.queuedFragmentCount == 254)
        await h.store.send(.send(meshPattern(500, seed: 99)))
        #expect(h.store.state.queuedFragmentCount == 254)
        #expect(h.store.state.counters.queueFull == 1)
        await stopMeshInterface(h)
    }

    @Test func droppedPacketDoesNotConsumeAnIndex() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        for seed in 0..<85 { await h.store.send(.send(meshPattern(500, seed: seed))) }
        await h.store.send(.send(meshPattern(500, seed: 99)))     // dropped
        await h.store.send(.send(meshPattern(10, seed: 98)))      // 255 ≤ 256: fits
        #expect(h.store.state.queue.last?.frame.first == 85)
        await stopMeshInterface(h)
    }

    @Test func failedDriverSendIncrementsSendFailed() async {
        let h = await makeOnlineMeshInterface(modemPreset: shortTurbo, sendResults: [false])
        await h.store.send(.send(meshPattern(10, seed: 1)))
        await h.store.receive { $0 == .fragmentSent(ok: false) }
        #expect(h.store.state.counters.sendFailed == 1)
        await stopMeshInterface(h)
    }

    @Test func pacingContinuesAfterAFailedSend() async {
        let h = await makeOnlineMeshInterface(modemPreset: shortTurbo, sendResults: [false])
        let packet = meshPattern(300, seed: 4)
        await h.store.send(.send(packet))
        await h.store.receive { $0 == .fragmentSent(ok: false) }
        await h.clock.advance(by: .milliseconds(400))
        await h.store.receive { $0 == .fragmentSent(ok: true) }
        #expect(h.calls.value.sentFrames == codec.split(packet, index: 0))
        await stopMeshInterface(h)
    }

    @Test func requestedFragmentJumpsTheQueue() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        let a = codec.split(meshPattern(500, seed: 1), index: 0)
        await h.store.send(.send(meshPattern(500, seed: 1)))
        await receiveSent(h)
        await h.store.send(.send(meshPattern(500, seed: 2)))
        h.radio.yield(.fragment(from: meshPeerNode, request(0, 1)))
        await receiveFragmentEvent(h)
        #expect(h.store.state.queue.first == .init(frame: a[0], isRetransmit: true))
        await h.clock.advance(by: .seconds(8))
        await receiveSent(h)
        #expect(h.calls.value.sentFrames == [a[0], a[0]])
        await stopMeshInterface(h)
    }

    // Review Focus 4.
    @Test func requestForAnIndexNeverSentIsIgnored() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        await h.store.send(.send(meshPattern(500, seed: 1)))
        await receiveSent(h)
        let before = h.store.state.queue
        h.radio.yield(.fragment(from: meshPeerNode, request(7, 1)))
        await receiveFragmentEvent(h)
        #expect(h.store.state.queue == before)
        #expect(h.store.state.counters.requestsAnswered == 0)
        await stopMeshInterface(h)
    }

    // Review Focus 4.
    @Test func requestPastThePacketsLastFragmentIsIgnored() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        await h.store.send(.send(meshPattern(500, seed: 1)))      // 3 fragments
        await receiveSent(h)
        h.radio.yield(.fragment(from: meshPeerNode, request(0, 4)))
        await receiveFragmentEvent(h)
        #expect(h.store.state.counters.requestsAnswered == 0)
        await stopMeshInterface(h)
    }

    // Review Focus 1 — trap-class (step b′).
    @Test func requestWithPositionInt8MinIsIgnored() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        await h.store.send(.send(meshPattern(500, seed: 1)))
        await receiveSent(h)
        h.radio.yield(.fragment(from: meshPeerNode, request(0, 0x80)))
        await receiveFragmentEvent(h)
        #expect(h.store.state.counters.requestsAnswered == 0)
        await stopMeshInterface(h)
    }

    // Review Focus 3.
    @Test func repeatedRequestQueuesTheFragmentOnce() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        await h.store.send(.send(meshPattern(500, seed: 1)))
        await receiveSent(h)                                       // queue: [a2, a3]
        for _ in 0..<3 {
            h.radio.yield(.fragment(from: meshPeerNode, request(0, 1)))
            await receiveFragmentEvent(h)
        }
        #expect(h.store.state.queuedFragmentCount == 3)
        #expect(h.store.state.counters.requestsAnswered == 1)
        await stopMeshInterface(h)
    }

    @Test func requestCacheKeepsOnlyTheLast16Packets() async {
        let h = await makeOnlineMeshInterface(modemPreset: shortTurbo)
        await h.store.send(.send(meshPattern(10, seed: 0)))
        await receiveSent(h)
        for seed in 1..<17 { await h.store.send(.send(meshPattern(10, seed: seed))) }
        await drainMeshFrames(h, every: .milliseconds(400), count: 16)
        await h.clock.advance(by: .milliseconds(400))
        await h.store.receive { $0 == .pacingElapsed }
        h.radio.yield(.fragment(from: meshPeerNode, request(0, 1)))     // evicted: index 0 is the 17th-newest
        await receiveFragmentEvent(h)
        #expect(h.store.state.counters.requestsAnswered == 0)
        h.radio.yield(.fragment(from: meshPeerNode, request(1, 1)))     // retained
        await receiveFragmentEvent(h)
        await receiveSent(h)
        #expect(h.store.state.counters.requestsAnswered == 1)
        #expect(h.calls.value.sentFrames.last == codec.split(meshPattern(10, seed: 1), index: 1)[0])
        await stopMeshInterface(h)
    }

    // Review Focus 5.
    @Test func packetIndexWrapsFrom255To0() async {
        var initial = MeshtasticInterface.State(config: meshTestConfig)
        initial.nextIndex = 255
        let h = await makeOnlineMeshInterface(modemPreset: longFast, initial: initial)
        await h.store.send(.send(meshPattern(10, seed: 1)))
        await receiveSent(h)
        await h.store.send(.send(meshPattern(10, seed: 2)))
        #expect(h.calls.value.sentFrames.first?.first == 255)
        #expect(h.store.state.queue.first?.frame.first == 0)
        await stopMeshInterface(h)
    }

    // Review Focus 5.
    @Test func requestAfterTheWrapIsAnsweredFromTheNewestPacket() async {
        var initial = MeshtasticInterface.State(config: meshTestConfig)
        initial.nextIndex = 255
        initial.sentCache = [.init(index: 0, fragments: [Data([0, 0xFF, 0xEE])])]   // a stale index 0
        let h = await makeOnlineMeshInterface(modemPreset: shortTurbo, initial: initial)
        await h.store.send(.send(meshPattern(10, seed: 1)))       // index 255
        await receiveSent(h)
        await h.store.send(.send(meshPattern(10, seed: 2)))       // index 0 (wrapped)
        await drainMeshFrames(h, every: .milliseconds(400), count: 1)
        await h.clock.advance(by: .milliseconds(400))
        await h.store.receive { $0 == .pacingElapsed }
        h.radio.yield(.fragment(from: meshPeerNode, request(0, 1)))
        await receiveSent(h)
        #expect(h.calls.value.sentFrames.last == codec.split(meshPattern(10, seed: 2), index: 0)[0])
        await stopMeshInterface(h)
    }

    @Test func disconnectEmptiesTheSendQueue() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        await h.store.send(.send(meshPattern(500, seed: 1)))
        await receiveSent(h)
        h.radio.yield(.disconnected(reason: nil))
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        #expect(h.store.state.queuedFragmentCount == 0)
        await stopMeshInterface(h)
    }

    @Test func firstSendAfterReconnectGoesOutImmediately() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        await h.store.send(.send(meshPattern(500, seed: 1)))
        await receiveSent(h)
        h.radio.yield(.disconnected(reason: nil))
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        h.radio.yield(.connected(myNodeNum: meshOwnNode, modemPreset: longFast))
        await h.store.receive { if case .delegate(.online) = $0 { return true }; return false }
        await h.store.send(.send(meshPattern(10, seed: 3)))
        await receiveSent(h)
        #expect(h.calls.value.sentFrames.last == codec.split(meshPattern(10, seed: 3), index: 1)[0])
        await stopMeshInterface(h)
    }

    @Test func requestCacheSurvivesADisconnect() async {
        let h = await makeOnlineMeshInterface(modemPreset: shortTurbo)
        let frame = codec.split(meshPattern(10, seed: 1), index: 0)[0]
        await h.store.send(.send(meshPattern(10, seed: 1)))
        await receiveSent(h)
        await h.clock.advance(by: .milliseconds(400))
        await h.store.receive { $0 == .pacingElapsed }
        h.radio.yield(.disconnected(reason: nil))
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        h.radio.yield(.connected(myNodeNum: meshOwnNode, modemPreset: shortTurbo))
        await h.store.receive { if case .delegate(.online) = $0 { return true }; return false }
        h.radio.yield(.fragment(from: meshPeerNode, request(0, 1)))
        await receiveSent(h)
        #expect(h.calls.value.sentFrames == [frame, frame])
        await stopMeshInterface(h)
    }

    @Test func repeatedConnectedEventAdoptsTheNewPresetDelay() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        h.radio.yield(.connected(myNodeNum: meshOwnNode, modemPreset: shortTurbo))
        await h.store.receive { $0 == .delegate(.online(myNodeNum: meshOwnNode, modemPreset: shortTurbo)) }
        await h.store.send(.send(meshPattern(300, seed: 5)))
        await receiveSent(h)
        await h.clock.advance(by: .milliseconds(400))
        await receiveSent(h)
        #expect(h.calls.value.sentFrames.count == 2)
        await stopMeshInterface(h)
    }

    /// landandair's process_outgoing for the same three packets: index from 0, queue order.
    @Test func outgoingFramesMatchTheReferenceSender() async throws {
        let fixtures = try MeshtasticFixtures.load()
        let h = await makeOnlineMeshInterface(modemPreset: shortTurbo)
        let packets = fixtures.outgoing.packets.map(meshData(hex:))
        await h.store.send(.send(packets[0]))
        await receiveSent(h)
        for packet in packets.dropFirst() { await h.store.send(.send(packet)) }
        await drainMeshFrames(h, every: .milliseconds(400), count: fixtures.outgoing.frames.count - 1)
        #expect(h.calls.value.sentFrames == fixtures.outgoing.frames.map(meshData(hex:)))
        await stopMeshInterface(h)
    }

    /// landandair's answer to each REQ, after the same three packets.
    @Test func requestAnswersMatchTheReferenceSender() async throws {
        let fixtures = try MeshtasticFixtures.load()
        let h = await makeOnlineMeshInterface(modemPreset: shortTurbo)
        let packets = fixtures.outgoing.packets.map(meshData(hex:))
        await h.store.send(.send(packets[0]))
        await receiveSent(h)
        for packet in packets.dropFirst() { await h.store.send(.send(packet)) }
        await drainMeshFrames(h, every: .milliseconds(400), count: fixtures.outgoing.frames.count - 1)
        await h.clock.advance(by: .milliseconds(400))
        await h.store.receive { $0 == .pacingElapsed }
        #expect(fixtures.requestAnswers.count == 4)
        for answer in fixtures.requestAnswers {
            h.radio.yield(.fragment(from: meshPeerNode, meshData(hex: answer.request)))
            await receiveSent(h)
            #expect(h.calls.value.sentFrames.last == meshData(hex: answer.answer), "request \(answer.request)")
            await h.clock.advance(by: .milliseconds(400))
            await h.store.receive { $0 == .pacingElapsed }
        }
        await stopMeshInterface(h)
    }
}
