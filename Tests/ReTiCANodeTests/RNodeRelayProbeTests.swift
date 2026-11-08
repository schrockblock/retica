import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

//  A: LXMFNode, RNode slot  <-- packets -->  R: TransportEndpoint, RNode slot + TCP client,
//  relay on  <-- HDLC bytes -->  B: LXMFNode, TCP client
//
// No limiter and no hop cap on this leg (spec §5.8): R relays whatever Transport rebroadcasts.

private let relayRadioA = UUID(uuidString: "0000AAAA-0000-0000-0000-0000000000D1")!
private let relayRadioR = UUID(uuidString: "0000EEEE-0000-0000-0000-0000000000D2")!
/// Sideband's defaults: 868.1 MHz, 62.5 kHz, 0 dBm, SF 8, CR 6: 1302 bps.
private let relayParams = RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 62_500, txPowerDBm: 0,
                                          spreadingFactor: 8, codingRate: 6)
private let relayReceiveTimeout: Duration = .seconds(5)
private let relayWaitTimeout: Duration = .seconds(10)
private let relayStartTime: TimeInterval = 1_700_000_000

private func relayReport() -> RNodeRadioReport {
    RNodeRadioReport(firmwareMajor: 1, firmwareMinor: 86, platform: 0x80, params: relayParams)
}

@MainActor
private struct RNodeRelayHarness {
    let a: TestStore<LXMFNode.State, LXMFNode.Action>
    let r: TestStore<TransportEndpoint.State, TransportEndpoint.Action>
    let b: TestStore<LXMFNode.State, LXMFNode.Action>
    let aIdentity: Identity
    let bIdentity: Identity
    let rIdentity: Identity
    let rClock: TestClock<Duration>
    let aRadio: AsyncStream<RNodeDriverEvent>.Continuation
    let rRadio: AsyncStream<RNodeDriverEvent>.Continuation
    /// R's TCP event stream: anything yielded here arrives at R as if B had sent it.
    let rTCP: AsyncStream<TCPEvent>.Continuation
    let bTCP: AsyncStream<TCPEvent>.Continuation
    /// The whole packets R put on the air.
    let rOnAir: LockIsolated<[Data]>

    var rSenderDrained: Bool {
        r.state.rnode.map { $0.interface.queuedPacketCount == 0 && !$0.interface.sendInFlight } ?? true
    }

    var aDelivery: Data { LXMessage.deliveryHash(identityHash: aIdentity.hash) }
    var bDelivery: Data { LXMessage.deliveryHash(identityHash: bIdentity.hash) }

    /// Polls `condition` over R's state. A TestStore's `state` moves only as received actions are
    /// asserted or skipped, so each round skips R's, then runs `nudge`.
    func waitForR(nudge: () async -> Void = {}, _ condition: () -> Bool) async -> Bool {
        await rnodeWaitUntil(timeout: relayWaitTimeout) {
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
        await r.receive({ if case .delegate(.pathLearned) = $0 { return true }; return false },
                        timeout: relayReceiveTimeout)
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
private func makeRelayHarness() -> RNodeRelayHarness {
    let aIdentity = Identity(), bIdentity = Identity(), rIdentity = Identity()
    let aRadio = AsyncStream<RNodeDriverEvent>.makeStream()
    let rRadio = AsyncStream<RNodeDriverEvent>.makeStream()
    let rTCP = AsyncStream<TCPEvent>.makeStream()
    let bTCP = AsyncStream<TCPEvent>.makeStream()
    let rOnAir = LockIsolated<[Data]>([])
    let now = LockIsolated(Date(timeIntervalSince1970: relayStartTime))
    let rClock = TestClock<Duration>()

    let aConfig = RNodeDriverConfig(radio: relayRadioA, params: relayParams)
    let a = TestStore(initialState: LXMFNode.State(
        identity: aIdentity,
        endpoint: .rnode(RNodeEndpoint.State(config: aConfig, profile: .rnode(params: nil))))) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: relayStartTime + 0.5))
        $0.uuid = .incrementing
        $0.rnodeDriver = RNodeDriver(
            start: { _ in aRadio.stream },
            send: { packet in
                rRadio.continuation.yield(.packet(packet, rssi: nil, snr: nil))
                return true
            },
            stop: {})
    }
    a.exhaustivity = .off

    let rConfig = RNodeDriverConfig(radio: relayRadioR, params: relayParams)
    let r = TestStore(initialState: TransportEndpoint.State(
        tcpClients: [TCPEndpoint.State(host: "b", port: 4242, reconnectOnDrop: false)],
        rnode: RNodeEndpoint.State(config: rConfig, profile: .rnode(params: nil)))) {
        TransportEndpoint()
    } withDependencies: {
        $0.continuousClock = rClock
        $0.date = .constant(Date(timeIntervalSince1970: relayStartTime))
        $0.transportDate = DateGenerator { now.value }
        $0.uuid = .incrementing
        $0.rnodeDriver = RNodeDriver(
            start: { _ in rRadio.stream },
            send: { packet in
                rOnAir.withValue { $0.append(packet) }
                aRadio.continuation.yield(.packet(packet, rssi: nil, snr: nil))
                return true
            },
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
        $0.date = .constant(Date(timeIntervalSince1970: relayStartTime + 0.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in bTCP.stream },
                                         send: { rTCP.continuation.yield(.data($0)) },
                                         close: { })
    }
    b.exhaustivity = .off

    return RNodeRelayHarness(a: a, r: r, b: b, aIdentity: aIdentity, bIdentity: bIdentity,
                             rIdentity: rIdentity, rClock: rClock, aRadio: aRadio.continuation,
                             rRadio: rRadio.continuation, rTCP: rTCP.continuation,
                             bTCP: bTCP.continuation, rOnAir: rOnAir)
}

/// Relay on first (unless `relay` is false), then all three nodes up: A's radio, R's radio and TCP
/// client, B's TCP client.
@MainActor
private func bringRelayOnline(_ h: RNodeRelayHarness, relay: Bool = true) async {
    if relay {
        await h.r.send(.enableRelay(h.rIdentity))
        await h.r.receive({ if case .transport(.setTransportIdentity) = $0 { return true }; return false },
                          timeout: relayReceiveTimeout)
    }
    await h.a.send(.endpoint(.start))
    await h.r.send(.start)
    await h.b.send(.endpoint(.start))

    h.aRadio.yield(.connected(relayReport()))
    await h.a.receive({ if case .endpoint(.transport(.interfaceConnected)) = $0 { return true }; return false },
                      timeout: relayReceiveTimeout)
    h.rRadio.yield(.connected(relayReport()))
    let radioID = rnodeInterfaceID(radio: relayRadioR)
    await h.r.receive({ if case .transport(.interfaceConnected(radioID, _)) = $0 { return true }; return false },
                      timeout: relayReceiveTimeout)
    h.rTCP.yield(.connected)
    await h.r.receive({ if case .transport(.interfaceConnected(InterfaceID("tcp"), _)) = $0 { return true }; return false },
                      timeout: relayReceiveTimeout)
    h.bTCP.yield(.connected)
    await h.b.receive({ if case .endpoint(.transport(.interfaceConnected)) = $0 { return true }; return false },
                      timeout: relayReceiveTimeout)
    #expect(h.r.state.interfaces[radioID]?.bitrate == 1302)
}

/// Both register delivery; each announce waits in R for its jitter, so firing `rClock` is what
/// teaches each side the other, via R.
@MainActor
private func learnEachOtherThroughTheRelay(_ h: RNodeRelayHarness) async {
    await h.a.send(.registerDelivery)
    await h.fireRebroadcast(of: h.aDelivery)
    await h.b.receive({ if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false },
                      timeout: relayReceiveTimeout)
    await h.b.send(.registerDelivery)
    await h.fireRebroadcast(of: h.bDelivery)
    await h.a.receive({ if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false },
                      timeout: relayReceiveTimeout)
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
    }, timeout: relayReceiveTimeout)
    return received.value
}

/// Polls `condition`, running `step` and yielding (never sleeping) between checks, until it holds
/// or `timeout` of real time passes.
@MainActor
private func rnodeWaitUntil(timeout: Duration, step: () async -> Void,
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
    let randomHash = Announce.randomHash(now: UInt64(relayStartTime), randomPrefix: Data(repeating: 0xA5, count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, appData: nil)
    let packet = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: hops,
                        destinationHash: destHash, transportId: nil, payload: payload)
    return (try! packet.packed(), destHash)
}

@MainActor @Suite struct RNodeRelayProbeTests {
    @Test func messageFromRNodeReachesTCPThroughTheRelay() async {
        let h = makeRelayHarness()
        await bringRelayOnline(h)
        await learnEachOtherThroughTheRelay(h)
        await h.a.send(.send(destinationHash: h.bDelivery, title: Data("hi".utf8),
                             content: Data("radio to tcp".utf8), method: .opportunistic))
        let content = await receivedContent(h.b)
        #expect(content == Data("radio to tcp".utf8))
        await h.shutdown()
    }

    @Test func messageFromTCPReachesRNodeThroughTheRelay() async {
        let h = makeRelayHarness()
        await bringRelayOnline(h)
        await learnEachOtherThroughTheRelay(h)
        await h.b.send(.send(destinationHash: h.aDelivery, title: Data("hi".utf8),
                             content: Data("tcp to radio".utf8), method: .opportunistic))
        let content = await receivedContent(h.a)
        #expect(content == Data("tcp to radio".utf8))
        await h.shutdown()
    }

    /// No MeshCore-style hop cap on this leg (spec §5.8): hops 2 in, hops 3 on the air.
    @Test func aTCPAnnounceIsRelayedOntoTheRadio() async {
        let h = makeRelayHarness()
        await bringRelayOnline(h)
        let (raw, dest) = relayAnnounce(hops: 2)
        await h.injectOverTCP(raw)
        await h.fireRebroadcast(of: dest)
        let sent = await h.waitForR { !h.rOnAir.value.isEmpty && h.rSenderDrained }
        #expect(sent, "nothing reached the air")
        let packets = h.rOnAir.value
        #expect(packets.count == 1)
        #expect(packets.first.flatMap { Packet(raw: $0) }?.hops == 3)
        #expect(packets.first.flatMap { Packet(raw: $0) }?.destinationHash == dest)
        await h.shutdown()
    }

    @Test func relayOffForwardsNothing() async {
        let h = makeRelayHarness()
        await bringRelayOnline(h, relay: false)
        let (raw, dest) = relayAnnounce(hops: 2)
        await h.injectOverTCP(raw)
        for seconds in [1, 200] {
            await Task.megaYield()
            await h.rClock.advance(by: .seconds(seconds))
            await Task.megaYield()
            await h.r.skipReceivedActions(strict: false)
            #expect(h.r.state.transport.announceTable[dest] == nil, "R queued a rebroadcast with relay off")
            #expect(h.rOnAir.value.isEmpty, "R put a TCP announce on the air after +\(seconds) s")
        }
        await h.shutdown()
    }
}
