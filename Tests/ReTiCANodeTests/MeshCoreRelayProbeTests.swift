import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

//  A: LXMFNode, MeshCore slot  <-- datagrams -->  R: TransportEndpoint, MeshCore slot + TCP client,
//  relay on  <-- HDLC bytes -->  B: LXMFNode, TCP client
//
// Transport's pacing sits upstream of the limiter (plan, Contract issue 2): at 473 bps a relayed
// announce spends ~155 s of pacing, so the 6-per-10-minute aggregate cap can't trip end to end.
// These probes use the hop cap and the per-destination interval; the aggregate caps are pinned at
// limiter and endpoint level.

private let relayRadioA = UUID(uuidString: "0000AAAA-0000-0000-0000-0000000000D1")!
private let relayRadioR = UUID(uuidString: "0000EEEE-0000-0000-0000-0000000000D2")!
private let relayPrefixA = Data([0xA1, 0xA1, 0xA1, 0xA1])
private let relayPrefixR = Data([0xE5, 0xE5, 0xE5, 0xE5])
/// SF7 / 62.5 kHz / CR 4/5: 473 bps, so Transport's announce pacing is real.
private let sf7Params = MeshCoreLinkParams(spreadingFactor: 7, bandwidthHz: 62_500, codingRate: 5)
private let receiveTimeout: Duration = .seconds(5)
private let waitTimeout: Duration = .seconds(10)
private let startTime: TimeInterval = 1_700_000_000

@MainActor
private struct RelayHarness {
    let a: TestStore<LXMFNode.State, LXMFNode.Action>
    let r: TestStore<TransportEndpoint.State, TransportEndpoint.Action>
    let b: TestStore<LXMFNode.State, LXMFNode.Action>
    let aIdentity: Identity
    let bIdentity: Identity
    let rIdentity: Identity
    let rClock: TestClock<Duration>
    let now: LockIsolated<Date>
    let aRadio: AsyncStream<MeshCoreDriverEvent>.Continuation
    let rRadio: AsyncStream<MeshCoreDriverEvent>.Continuation
    /// R's TCP event stream: anything yielded here arrives at R as if B had sent it.
    let rTCP: AsyncStream<TCPEvent>.Continuation
    let bTCP: AsyncStream<TCPEvent>.Continuation
    /// The datagrams R put on the air.
    let rOnAir: LockIsolated<[Data]>

    /// The Reticulum packets R put on the air.
    var radioPackets: [Data] { meshCoreReassembleOnAir(rOnAir.value) }

    var rSenderDrained: Bool {
        r.state.meshCore.map { $0.interface.queue.isEmpty && !$0.interface.pacing } ?? true
    }

    var announcesLimited: Int { r.state.meshCore?.counters.announcesLimited ?? 0 }

    var aDelivery: Data { LXMessage.deliveryHash(identityHash: aIdentity.hash) }
    var bDelivery: Data { LXMessage.deliveryHash(identityHash: bIdentity.hash) }

    /// Moves R's date, then R's clock: the retry reads pacing from the date when its timer fires.
    func advanceR(by seconds: Int) async {
        now.withValue { $0 = $0.addingTimeInterval(TimeInterval(seconds)) }
        await Task.megaYield()
        await rClock.advance(by: .seconds(seconds))
        await Task.megaYield()
    }

    /// Polls `condition` over R's state. A TestStore's `state` moves only as received actions are
    /// asserted or skipped, so each round skips R's, then runs `nudge`.
    func waitForR(nudge: () async -> Void = {}, _ condition: () -> Bool) async -> Bool {
        await meshCoreWaitUntil(timeout: waitTimeout) {
            await r.skipReceivedActions(strict: false)
            await nudge()
        } until: { condition() }
    }

    /// Waits until R holds a jittered rebroadcast for `destination`, then fires the jitter
    /// (≤ 0.5 s) and waits for it to run. The zero advances catch a jitter timer that registered
    /// only after the 1 s advance: its deadline is then "now".
    func fireRebroadcast(of destination: Data) async {
        let held = await waitForR { r.state.transport.announceTable[destination] != nil }
        #expect(held, "R never scheduled a rebroadcast")
        await Task.megaYield()
        await rClock.advance(by: .seconds(1))
        let fired = await waitForR(nudge: { await rClock.advance(by: .zero) }) {
            (r.state.transport.announceTable[destination]?.rebroadcasts ?? 0) >= 1
        }
        #expect(fired, "R's rebroadcast timer never fired")
    }

    /// Feeds R an announce over TCP, as B's link would carry it, and waits until R learns it.
    func injectOverTCP(_ raw: Data) async {
        rTCP.yield(.data(HDLC.frame(raw)))
        await r.receive({ if case .delegate(.pathLearned) = $0 { return true }; return false }, timeout: receiveTimeout)
    }

    func shutdown() async {
        await a.send(.endpoint(.stop))
        await r.send(.stop)
        await b.send(.endpoint(.stop))
        await a.skipReceivedActions(strict: false)
        await r.skipReceivedActions(strict: false)
        await b.skipReceivedActions(strict: false)
    }
}

@MainActor
private func makeRelayHarness() -> RelayHarness {
    let aIdentity = Identity(), bIdentity = Identity(), rIdentity = Identity()
    let aRadio = AsyncStream<MeshCoreDriverEvent>.makeStream()
    let rRadio = AsyncStream<MeshCoreDriverEvent>.makeStream()
    let rTCP = AsyncStream<TCPEvent>.makeStream()
    let bTCP = AsyncStream<TCPEvent>.makeStream()
    let rOnAir = LockIsolated<[Data]>([])
    let now = LockIsolated(Date(timeIntervalSince1970: startTime))
    let rClock = TestClock<Duration>()

    let aConfig = MeshCoreDriverConfig(radio: relayRadioA, channelSecret: Data(repeating: 0x22, count: 16))
    let a = TestStore(initialState: LXMFNode.State(
        identity: aIdentity,
        endpoint: .meshCore(MeshCoreEndpoint.State(config: aConfig, profile: .meshCore(params: nil))))) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: startTime + 0.5))
        $0.meshCoreDate = .constant(Date(timeIntervalSince1970: startTime + 0.5))
        $0.uuid = .incrementing
        $0.meshCoreClock = ImmediateClock()
        $0.meshCoreDriver = MeshCoreDriver(
            start: { _ in aRadio.stream },
            send: { datagram in
                rRadio.continuation.yield(.datagram(datagram))
                return true
            },
            removeChannel: { true },
            stop: {})
    }
    a.exhaustivity = .off

    let rConfig = MeshCoreDriverConfig(radio: relayRadioR, channelSecret: Data(repeating: 0x22, count: 16))
    let r = TestStore(initialState: TransportEndpoint.State(
        tcpClients: [TCPEndpoint.State(host: "b", port: 4242, reconnectOnDrop: false)],
        meshCore: MeshCoreEndpoint.State(config: rConfig, profile: .meshCore(params: nil)))) {
        TransportEndpoint()
    } withDependencies: {
        $0.continuousClock = rClock
        $0.date = .constant(Date(timeIntervalSince1970: startTime))
        $0.transportDate = DateGenerator { now.value }
        $0.meshCoreDate = DateGenerator { now.value }
        $0.uuid = .incrementing
        $0.meshCoreClock = ImmediateClock()
        $0.meshCoreDriver = MeshCoreDriver(
            start: { _ in rRadio.stream },
            send: { datagram in
                rOnAir.withValue { $0.append(datagram) }
                aRadio.continuation.yield(.datagram(datagram))
                return true
            },
            removeChannel: { true },
            stop: {})
        $0.tcpConnection = TCPConnection(open: { _, _ in rTCP.stream },
                                         send: { bTCP.continuation.yield(.data($0)) },
                                         close: { })
    }
    r.exhaustivity = .off

    let b = TestStore(initialState: LXMFNode.State(
        identity: bIdentity, endpoint: tcpDriverEndpoint(host: "r", port: 4242, reconnectOnDrop: false))) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: startTime + 0.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in bTCP.stream },
                                         send: { rTCP.continuation.yield(.data($0)) },
                                         close: { })
    }
    b.exhaustivity = .off

    return RelayHarness(a: a, r: r, b: b, aIdentity: aIdentity, bIdentity: bIdentity, rIdentity: rIdentity,
                        rClock: rClock, now: now, aRadio: aRadio.continuation, rRadio: rRadio.continuation,
                        rTCP: rTCP.continuation, bTCP: bTCP.continuation, rOnAir: rOnAir)
}

/// Relay on first, then all three nodes up: A's radio, R's radio and TCP client, B's TCP client.
@MainActor
private func bringRelayOnline(_ h: RelayHarness) async {
    await h.r.send(.enableRelay(h.rIdentity))
    await h.r.receive({ if case .transport(.setTransportIdentity) = $0 { return true }; return false },
                      timeout: receiveTimeout)
    await h.a.send(.endpoint(.start))
    await h.r.send(.start)
    await h.b.send(.endpoint(.start))

    h.aRadio.yield(.connected(selfPrefix: relayPrefixA, publicKey: relayPrefixA + Data(repeating: 0xA1, count: 28),
                              params: sf7Params))
    await h.a.receive({ if case .endpoint(.transport(.interfaceConnected)) = $0 { return true }; return false },
                      timeout: receiveTimeout)
    h.rRadio.yield(.connected(selfPrefix: relayPrefixR, publicKey: relayPrefixR + Data(repeating: 0xE5, count: 28),
                              params: sf7Params))
    let radioID = meshCoreInterfaceID(radio: relayRadioR)
    await h.r.receive({ if case .transport(.interfaceConnected(radioID, _)) = $0 { return true }; return false },
                      timeout: receiveTimeout)
    h.rTCP.yield(.connected)
    await h.r.receive({ if case .transport(.interfaceConnected(InterfaceID("tcp"), _)) = $0 { return true }; return false },
                      timeout: receiveTimeout)
    h.bTCP.yield(.connected)
    await h.b.receive({ if case .endpoint(.transport(.interfaceConnected)) = $0 { return true }; return false },
                      timeout: receiveTimeout)
    #expect(h.r.state.interfaces[radioID]?.bitrate == 473)
}

/// Both register delivery; each announce waits in R for its jitter, so firing `rClock` is what
/// teaches each side the other, via R.
@MainActor
private func learnEachOtherThroughTheRelay(_ h: RelayHarness) async {
    await h.a.send(.registerDelivery)
    await h.fireRebroadcast(of: h.aDelivery)
    await h.b.receive({ if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false },
                      timeout: receiveTimeout)
    await h.b.send(.registerDelivery)
    await h.fireRebroadcast(of: h.bDelivery)
    await h.a.receive({ if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false },
                      timeout: receiveTimeout)
    #expect(h.a.state.endpoint.learned[h.bDelivery]?.nextHop == h.rIdentity.hash, "A did not learn B via R")
    #expect(h.b.state.endpoint.learned[h.aDelivery]?.nextHop == h.rIdentity.hash, "B did not learn A via R")
}

@MainActor
private func receivedContent(_ store: TestStore<LXMFNode.State, LXMFNode.Action>) async -> Data? {
    let received = LockIsolated<Data?>(nil)
    await store.receive({ action in
        if case let .delegate(.messageReceived(message, _, _)) = action {
            received.setValue(message.content)
            return true
        }
        return false
    }, timeout: receiveTimeout)
    return received.value
}

/// Polls `condition`, running `step` and yielding (never sleeping) between checks, until it holds
/// or `timeout` of real time passes.
@MainActor
private func meshCoreWaitUntil(timeout: Duration, step: () async -> Void,
                               until condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        await step()
        if condition() { return true }
        await Task.megaYield()
    }
    return condition()
}

private func relayAnnounce(hops: UInt8) -> (raw: Data, destinationHash: Data) {
    let identity = Identity()
    let nameHash = Destination.nameHash(appName: "app", aspects: ["far"])
    let destHash = Destination.hash(identityHash: identity.hash, appName: "app", aspects: ["far"])
    let randomHash = Announce.randomHash(now: UInt64(startTime), randomPrefix: Data(repeating: 0xA5, count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, appData: nil)
    let packet = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: hops,
                        destinationHash: destHash, transportId: nil, payload: payload)
    return (try! packet.packed(), destHash)
}

@MainActor @Suite struct MeshCoreRelayProbeTests {
    @Test func messageFromMeshCoreReachesTCPThroughTheRelay() async {
        let h = makeRelayHarness()
        await bringRelayOnline(h)
        await learnEachOtherThroughTheRelay(h)
        await h.a.send(.send(destinationHash: h.bDelivery, title: Data("hi".utf8),
                             content: Data("radio to tcp".utf8), method: .opportunistic))
        let content = await receivedContent(h.b)
        #expect(content == Data("radio to tcp".utf8))
        await h.shutdown()
    }

    @Test func messageFromTCPReachesMeshCoreThroughTheRelay() async {
        let h = makeRelayHarness()
        await bringRelayOnline(h)
        await learnEachOtherThroughTheRelay(h)
        await h.b.send(.send(destinationHash: h.aDelivery, title: Data("hi".utf8),
                             content: Data("tcp to radio".utf8), method: .opportunistic))
        let content = await receivedContent(h.a)
        #expect(content == Data("tcp to radio".utf8))
        await h.shutdown()
    }

    @Test func announceAtTheHopCapReachesTheRadio() async {
        let h = makeRelayHarness()
        await bringRelayOnline(h)
        let (raw, dest) = relayAnnounce(hops: 1)
        await h.injectOverTCP(raw)
        await h.fireRebroadcast(of: dest)
        let sent = await h.waitForR {!h.radioPackets.isEmpty && h.rSenderDrained }
        #expect(sent, "nothing reached the air")
        let packets = h.radioPackets
        #expect(packets.count == 1)
        #expect(packets.first.flatMap { Packet(raw: $0) }?.hops == 2)
        await h.shutdown()
    }

    @Test func announcePastTheHopCapDoesNotReachTheRadio() async {
        let h = makeRelayHarness()
        await bringRelayOnline(h)
        let (raw, dest) = relayAnnounce(hops: 2)
        await h.injectOverTCP(raw)
        await h.fireRebroadcast(of: dest)
        let limited = await h.waitForR {h.announcesLimited >= 1 && h.rSenderDrained }
        #expect(limited, "the limiter never dropped the rebroadcast")
        #expect(h.radioPackets == [], "on the air at hops \(h.radioPackets.compactMap { Packet(raw: $0)?.hops })")
        #expect(h.announcesLimited >= 1)
        await h.shutdown()
    }

    /// R's rebroadcast goes out; its retry (5.5 s later, paced ~155 s at 473 bps) is inside the
    /// 600 s per-destination interval, so the limiter drops it.
    @Test func relayedAnnounceIsNotRepeatedOntoTheRadio() async {
        let h = makeRelayHarness()
        await bringRelayOnline(h)
        let (raw, dest) = relayAnnounce(hops: 0)
        await h.injectOverTCP(raw)
        await h.fireRebroadcast(of: dest)
        let first = await h.waitForR {!h.radioPackets.isEmpty && h.rSenderDrained }
        #expect(first, "the first rebroadcast never reached the air")
        await h.advanceR(by: 200)
        let limited = await h.waitForR {h.announcesLimited >= 1 && h.rSenderDrained }
        #expect(limited, "the retry never reached the limiter")
        #expect(h.radioPackets.count == 1)
        #expect(h.announcesLimited == 1)
        await h.shutdown()
    }

    /// A destination at hops 3 is never advertised on the radio, but a path request from A gets a
    /// path response through the 15 s heard-request bypass, which the hop cap exempts.
    @Test func distantDestinationIsReachableOnDemandThroughAPathRequest() async {
        let h = makeRelayHarness()
        await bringRelayOnline(h)
        let (raw, dest) = relayAnnounce(hops: 3)
        await h.injectOverTCP(raw)
        await h.fireRebroadcast(of: dest)
        let limited = await h.waitForR {h.announcesLimited >= 1 && h.rSenderDrained }
        #expect(limited, "the hop-capped rebroadcast never reached the limiter")
        #expect(h.radioPackets == [], "the distant destination was advertised on the radio")

        await h.a.send(.endpoint(.requestPath(destinationHash: dest)))
        await h.a.receive({ action in
            if case let .endpoint(.delegate(.pathLearned(learned, _))) = action { return learned == dest }
            return false
        }, timeout: receiveTimeout)
        let packets = h.radioPackets
        #expect(!packets.isEmpty, "R put no path response on the air")
        #expect(packets.contains { packet in
            Packet(raw: packet).map { $0.context == .pathResponse && $0.destinationHash == dest } ?? false
        })
        #expect(h.a.state.endpoint.learned[dest]?.nextHop == h.rIdentity.hash)
        await h.shutdown()
    }
}
