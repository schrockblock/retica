import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let radioUUID = UUID(uuidString: "0000CCCC-0000-0000-0000-00000000BEEF")!
private let radioID = meshCoreInterfaceID(radio: radioUUID)
private let tcpID = InterfaceID("tcp")
private let ownPrefix = Data([0x0A, 0x0A, 0x0A, 0x0A])
private let ownKey = ownPrefix + Data(repeating: 0x0A, count: 28)
private let peerPrefix = Data([0x0B, 0x0B, 0x0B, 0x0B])
/// SF8 / 62.5 kHz / CR 4/8: 350 bps paced (spec §5.4 table).
private let slowParams = MeshCoreLinkParams(spreadingFactor: 8, bandwidthHz: 62_500, codingRate: 8)
/// SF7 / 62.5 kHz / CR 4/5: 473 bps paced.
private let fastParams = MeshCoreLinkParams(spreadingFactor: 7, bandwidthHz: 62_500, codingRate: 5)
private let receiveTimeout: Duration = .seconds(5)
private let settleDeadline: Duration = .seconds(15)

/// Records maintenance start/stop, deregistrations of the radio's id and unified `sendFailed`
/// delegates that the wrapped reducer processes, exactly once each.
private struct MeshCoreEndpointRecorder<Wrapped: Reducer>: Reducer
where Wrapped.State == TransportEndpoint.State, Wrapped.Action == TransportEndpoint.Action {
    let log: LockIsolated<[String]>
    let wrapped: Wrapped
    init(log: LockIsolated<[String]>, @ReducerBuilder<State, Action> _ wrapped: () -> Wrapped) {
        self.log = log
        self.wrapped = wrapped()
    }
    func reduce(into state: inout TransportEndpoint.State, action: TransportEndpoint.Action)
        -> Effect<TransportEndpoint.Action> {
        if case .transport(.startMaintenance) = action { log.withValue { $0.append("start") } }
        if case .transport(.stopMaintenance) = action { log.withValue { $0.append("stop") } }
        if case .transport(.interfaceDisconnected(radioID)) = action { log.withValue { $0.append("radioDisconnected") } }
        if case .delegate(.sendFailed) = action { log.withValue { $0.append("sendFailed") } }
        return wrapped.reduce(into: &state, action: action)
    }
}

@MainActor
private struct MeshCoreEndpointHarness {
    let store: TestStore<TransportEndpoint.State, TransportEndpoint.Action>
    /// One driver session per `driver.start()`, in order: a stop/start reaches the next one.
    let sessions: [AsyncStream<MeshCoreDriverEvent>.Continuation]
    let onAir: LockIsolated<[Data]>
    let meshtastic: AsyncStream<MeshtasticDriverEvent>.Continuation
    let tcp: AsyncStream<TCPEvent>.Continuation
    let tcpSends: LockIsolated<[Data]>
    let now: LockIsolated<Date>
    let clock: TestClock<Duration>
    let log: LockIsolated<[String]>

    var radio: AsyncStream<MeshCoreDriverEvent>.Continuation { sessions[0] }
    /// The Reticulum packets the radio sent, reassembled from the datagrams on the air.
    var onAirPackets: [Data] { meshCoreReassembleOnAir(onAir.value) }

    func at(_ seconds: TimeInterval) { now.setValue(Date(timeIntervalSince1970: seconds)) }
}

@MainActor
private func makeMeshCoreEndpoint(profile: InterfaceProfile = .meshCore(params: nil),
                                  withTCPClient: Bool = false,
                                  liveDriver: Bool = false,
                                  meshtasticRadio: UUID? = nil) -> MeshCoreEndpointHarness {
    let streams = (0..<3).map { _ in AsyncStream<MeshCoreDriverEvent>.makeStream() }
    let started = LockIsolated(0)
    let meshtastic = AsyncStream<MeshtasticDriverEvent>.makeStream()
    let tcp = AsyncStream<TCPEvent>.makeStream()
    let tcpSends = LockIsolated<[Data]>([])
    let onAir = LockIsolated<[Data]>([])
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let clock = TestClock<Duration>()
    let log = LockIsolated<[String]>([])
    let config = MeshCoreDriverConfig(radio: radioUUID, channelSecret: Data(repeating: 0x22, count: 16))
    let initial = TransportEndpoint.State(
        tcpClients: withTCPClient ? [TCPEndpoint.State(host: "peer", port: 4242, reconnectOnDrop: false)] : [],
        meshtastic: meshtasticRadio.map { MeshtasticEndpoint.State(config: MeshtasticDriverConfig(radio: $0)) },
        meshCore: MeshCoreEndpoint.State(config: config, profile: profile))
    let sessionStreams = streams.map(\.stream)
    let mock = MeshCoreDriver(
        start: { _ in
            let index = started.withValue { count in
                defer { count += 1 }
                return count
            }
            return sessionStreams[min(index, sessionStreams.count - 1)]
        },
        send: { datagram in
            onAir.withValue { $0.append(datagram) }
            return true
        },
        removeChannel: { true },
        stop: {})
    let store = TestStore(initialState: initial) {
        MeshCoreEndpointRecorder(log: log) { TransportEndpoint() }
    } withDependencies: {
        $0.meshCoreDriver = liveDriver ? MeshCoreDriver.liveValue : mock
        $0.meshCoreClock = ImmediateClock()
        $0.meshCoreDate = DateGenerator { now.value }
        $0.meshtasticDriver = MeshtasticDriver(start: { _ in meshtastic.stream }, send: { _ in true }, stop: {})
        $0.meshtasticClock = ImmediateClock()
        $0.meshtasticDate = DateGenerator { Date(timeIntervalSince1970: 0) }
        $0.tcpConnection = TCPConnection(open: { _, _ in tcp.stream },
                                         send: { data in tcpSends.withValue { $0.append(data) } },
                                         close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.transportDate = DateGenerator { now.value }
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return MeshCoreEndpointHarness(store: store, sessions: streams.map(\.continuation), onAir: onAir,
                                   meshtastic: meshtastic.continuation, tcp: tcp.continuation,
                                   tcpSends: tcpSends, now: now, clock: clock, log: log)
}

/// Groups datagrams by packet ID, in first-seen order, and joins each complete packet's bodies.
/// Independent of `MeshCoreReassembler`, so a mutated production reassembler can't hide what went
/// on the air. Datagrams from one sender only.
func meshCoreReassembleOnAir(_ datagrams: [Data]) -> [Data] {
    let codec = ScotMeshRawCodec()
    var order: [UInt16] = []
    var bodies: [UInt16: [UInt8: Data]] = [:]
    var totals: [UInt16: UInt8] = [:]
    for bytes in datagrams {
        guard let datagram = codec.parse(bytes), datagram.type == .rnsFragment else { continue }
        if bodies[datagram.packetID] == nil {
            order.append(datagram.packetID)
            bodies[datagram.packetID] = [:]
        }
        bodies[datagram.packetID]?[datagram.fragmentIndex] = datagram.body
        totals[datagram.packetID] = datagram.fragmentTotal
    }
    return order.compactMap { id in
        guard let parts = bodies[id], let total = totals[id], parts.count == Int(total) else { return nil }
        return (0..<total).reduce(into: Data()) { joined, index in joined.append(parts[index] ?? Data()) }
    }
}

@MainActor
private func bringRadioOnline(_ h: MeshCoreEndpointHarness, params: MeshCoreLinkParams? = slowParams,
                              session: Int = 0, start: Bool = true) async {
    if start { await h.store.send(.start) }
    h.sessions[session].yield(.connected(selfPrefix: ownPrefix, publicKey: ownKey, params: params))
    await h.store.receive({ if case .transport(.interfaceConnected(radioID, _)) = $0 { return true }; return false },
                          timeout: receiveTimeout)
}

@MainActor
private func stopEndpoint(_ h: MeshCoreEndpointHarness) async {
    await h.store.send(.stop)
    await h.store.skipReceivedActions(strict: false)
}

/// Waits (real time) until at least `count` packets are on the air AND the sender has drained its
/// queue, so an exact count can be asserted: anything the limiter let through has gone out by then.
/// The deadline is generous for parallel load; a passing test leaves as soon as both hold.
@MainActor
private func settleOnAir(_ h: MeshCoreEndpointHarness, atLeast count: Int) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: settleDeadline)
    while clock.now < deadline {
        let sender = h.store.state.meshCore?.interface
        let drained = sender.map { $0.queue.isEmpty && !$0.pacing } ?? true
        if drained, h.onAirPackets.count >= count { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    await Task.megaYield()
    await h.store.skipReceivedActions(strict: false)
}

@MainActor
private func transmit(_ h: MeshCoreEndpointHarness, _ raw: Data, to id: InterfaceID = radioID) async {
    await h.store.send(.transport(.delegate(.transmit(id, raw))))
}

/// Frames `packet` as a peer would send it and hands it to the radio as received datagrams.
@MainActor
private func receiveFromPeer(_ h: MeshCoreEndpointHarness, _ packet: Data, packetID: UInt16) async {
    let datagrams = ScotMeshRawCodec().split(packet, type: .rnsFragment, src: peerPrefix,
                                             dst: ScotMeshRawCodec.broadcast, packetID: packetID,
                                             canRoute: false)
    for datagram in datagrams { h.radio.yield(.datagram(datagram)) }
    await h.store.receive({ if case .meshCore(.interface(.delegate(.packetReceived))) = $0 { return true }; return false },
                          timeout: receiveTimeout)
}

private func makeAnnounce(hops: UInt8 = 0, pathResponse: Bool = false,
                          emitted: UInt64 = 1000) -> (raw: Data, destinationHash: Data) {
    let identity = Identity()
    let nameHash = Destination.nameHash(appName: "app", aspects: ["svc"])
    let destHash = Destination.hash(identityHash: identity.hash, appName: "app", aspects: ["svc"])
    let randomHash = Announce.randomHash(now: emitted, randomPrefix: Data(repeating: 0xA5, count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, appData: nil)
    let packet = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                        destinationType: .single, context: pathResponse ? .pathResponse : .none,
                        contextFlag: false, hops: hops, destinationHash: destHash, transportId: nil,
                        payload: payload)
    return (try! packet.packed(), destHash)
}

/// A path request for `requested`, to the fixed control destination, with a 16-byte tag.
private func pathRequestPacket(requested: Data, tag: UInt8 = 0x01) -> Data {
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                        destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                        payload: requested + Data(repeating: tag, count: 16))
    return try! packet.packed()
}

private func meshCoreDestination(_ seed: UInt8) -> Data { Data(repeating: seed, count: 16) }

private func ifacProfile() -> InterfaceProfile {
    var profile = InterfaceProfile.meshCore(params: nil)
    profile.ifac = MeshCoreEndpoint.ifac(networkName: "mesh", passphrase: "pw")
    return profile
}

@MainActor @Suite struct TransportEndpointMeshCoreTests {
    @Test func radioOnlineRegistersItsInterfaceWithTheParamsProfile() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h, params: slowParams)
        #expect(h.store.state.interfaces[radioID] == InterfaceProfile.meshCore(params: slowParams))
        await stopEndpoint(h)
    }

    @Test func newParamsWhileOnlineReRegistersWithTheirBitrate() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h, params: slowParams)
        h.radio.yield(.connected(selfPrefix: ownPrefix, publicKey: ownKey, params: fastParams))
        await h.store.receive({ action in
            if case let .transport(.interfaceConnected(id, profile)) = action { return id == radioID && profile.bitrate == 473 }
            return false
        }, timeout: receiveTimeout)
        #expect(h.store.state.interfaces[radioID]?.bitrate == 473)
        await stopEndpoint(h)
    }

    @Test func radioOnlineSurfacesOnTheMeshCoreHatch() async {
        let h = makeMeshCoreEndpoint()
        await h.store.send(.start)
        h.radio.yield(.connected(selfPrefix: ownPrefix, publicKey: ownKey, params: slowParams))
        await h.store.receive(.meshCore(.delegate(.radioOnline(publicKey: ownKey, params: slowParams))),
                              timeout: receiveTimeout)
        await stopEndpoint(h)
    }

    @Test func radioDropDeregistersItsInterface() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h)
        h.radio.yield(.disconnected(reason: "gone"))
        await h.store.receive(.transport(.interfaceDisconnected(radioID)), timeout: receiveTimeout)
        #expect(h.store.state.interfaces[radioID] == nil)
        await stopEndpoint(h)
    }

    @Test func radioDropSurfacesOnTheMeshCoreHatch() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h)
        h.radio.yield(.disconnected(reason: "gone"))
        await h.store.receive(.meshCore(.delegate(.radioOffline(reason: "gone"))), timeout: receiveTimeout)
        await stopEndpoint(h)
    }

    @Test func endpointStopDeregistersTheRadio() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h)
        await h.store.send(.stop)
        await h.store.receive(.transport(.interfaceDisconnected(radioID)), timeout: receiveTimeout)
        #expect(h.store.state.interfaces[radioID] == nil)
        await h.store.skipReceivedActions(strict: false)
    }

    /// Contract 3: the host sends `.meshCore(.stop)` and waits for `.radioOffline` before clearing
    /// the slot, so a radio that never connected must still report it.
    @Test func endpointStopBeforeTheRadioConnectsSurfacesRadioOffline() async {
        let h = makeMeshCoreEndpoint()
        await h.store.send(.start)                       // started, never connected
        await h.store.send(.stop)
        await h.store.receive(.meshCore(.delegate(.radioOffline(reason: nil))), timeout: receiveTimeout)
        await h.store.skipReceivedActions(strict: false)
    }

    /// A `.stop` after a drop reports offline a second time; the radio was already deregistered by
    /// the drop and must not be deregistered again.
    @Test func endpointStopAfterARadioDropDeregistersTheRadioOnce() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h)
        h.radio.yield(.disconnected(reason: "gone"))
        await h.store.receive(.meshCore(.delegate(.radioOffline(reason: "gone"))), timeout: receiveTimeout)
        await h.store.send(.stop)
        await h.store.receive(.meshCore(.delegate(.radioOffline(reason: nil))), timeout: receiveTimeout)
        await h.store.skipReceivedActions(strict: false)
        let deregistrations = h.log.value.filter { $0 == "radioDisconnected" }.count
        #expect(deregistrations == 1, "saw \(deregistrations) interfaceDisconnected for the radio")
    }

    @Test func inboundDatagramsReachTheRouterTaggedWithTheRadioID() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h)
        let (raw, dest) = makeAnnounce()
        for datagram in ScotMeshRawCodec().split(raw, type: .rnsFragment, src: peerPrefix,
                                                 dst: ScotMeshRawCodec.broadcast, packetID: 7, canRoute: false) {
            h.radio.yield(.datagram(datagram))
        }
        await h.store.receive({ if case .delegate(.pathLearned) = $0 { return true }; return false },
                              timeout: receiveTimeout)
        #expect(h.store.state.learned[dest]?.interfaceID == radioID)
        await stopEndpoint(h)
    }

    @Test func transmitToTheRadioIDPutsThePacketOnTheAir() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h)
        let (raw, _) = makeAnnounce()
        await transmit(h, raw)
        await settleOnAir(h, atLeast: 1)
        #expect(h.onAirPackets == [raw])
        await stopEndpoint(h)
    }

    @Test func transmitOverAnIFACRadioMasksBeforeSplitting() async {
        let profile = ifacProfile()
        let h = makeMeshCoreEndpoint(profile: profile)
        await bringRadioOnline(h)
        let (raw, _) = makeAnnounce()
        let expected = ScotMeshRawCodec().split(profile.ifac!.protect(raw), type: .rnsFragment, src: ownPrefix,
                                                dst: ScotMeshRawCodec.broadcast,
                                                packetID: MeshCoreRandom.testValue.packetID(), canRoute: false)
        await transmit(h, raw)
        await settleOnAir(h, atLeast: 1)
        #expect(h.onAir.value == expected)
        await stopEndpoint(h)
    }

    @Test func transmitWhileTheRadioIsOfflineReportsInterfaceUnavailable() async {
        let h = makeMeshCoreEndpoint()
        await h.store.send(.start)                       // started, never connected
        let (raw, dest) = makeAnnounce()
        await transmit(h, raw)
        await h.store.receive(.delegate(.sendFailed(destinationHash: dest, reason: .interfaceUnavailable)),
                              timeout: receiveTimeout)
        await stopEndpoint(h)
    }

    @Test func missingLiveAdapterSurfacesOnTheMeshCoreHatch() async {
        let h = makeMeshCoreEndpoint(liveDriver: true)
        await h.store.send(.start)
        await h.store.receive(.meshCore(.delegate(.adapterUnavailable(.other(MeshCoreDriver.liveAdapterMissing)))),
                              timeout: receiveTimeout)
        await stopEndpoint(h)
    }

    /// Spec §6: both radio slots at once, even for the same radio UUID, register two interfaces.
    @Test func aMeshtasticAndAMeshCoreSlotRegisterSeparateInterfaces() async {
        let h = makeMeshCoreEndpoint(meshtasticRadio: radioUUID)
        let meshtasticID = meshtasticInterfaceID(radio: radioUUID)
        await h.store.send(.start)
        h.meshtastic.yield(.connected(myNodeNum: 0x0A0A_0A0A, modemPreset: 8))
        await h.store.receive({ if case .transport(.interfaceConnected(meshtasticID, _)) = $0 { return true }; return false },
                              timeout: receiveTimeout)
        await bringRadioOnline(h, start: false)
        await h.store.skipReceivedActions(strict: false)
        #expect(h.store.state.interfaces.count == 2)
        #expect(h.store.state.interfaces[meshtasticID] == InterfaceProfile.meshtastic(modemPreset: 8))
        #expect(h.store.state.interfaces[radioID] == InterfaceProfile.meshCore(params: slowParams))
        await stopEndpoint(h)
    }
}

/// Shared maintenance must follow the SHARED interface count, never the radio slot's own state.
@MainActor @Suite struct TransportEndpointMeshCoreMaintenanceTests {
    @Test func radioDropKeepsSharedMaintenanceAliveForTheTCPClient() async {
        let h = makeMeshCoreEndpoint(withTCPClient: true)
        await h.store.send(.start)
        h.tcp.yield(.connected)
        await h.store.receive(.transport(.interfaceConnected(tcpID, .tcp)), timeout: receiveTimeout)
        await bringRadioOnline(h, start: false)
        let (raw, dest) = makeAnnounce(hops: 3)
        h.tcp.yield(.data(HDLC.frame(raw)))
        await h.store.receive({ if case .delegate(.pathLearned) = $0 { return true }; return false },
                              timeout: receiveTimeout)
        #expect(h.store.state.learned[dest]?.interfaceID == tcpID)

        h.radio.yield(.disconnected(reason: nil))
        await h.store.receive(.transport(.interfaceDisconnected(radioID)), timeout: receiveTimeout)
        await h.store.skipReceivedActions(strict: false)
        #expect(h.store.state.interfaces.count == 1)

        h.now.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))
        await h.clock.advance(by: .seconds(Transport.maintenanceTickInterval))
        await h.store.skipReceivedActions(strict: false)
        #expect(h.store.state.learned[dest] == nil, "maintenance must survive the radio dropping while TCP is up")
        await stopEndpoint(h)
    }

    @Test func radioAsTheLastInterfaceToDropStopsSharedMaintenance() async {
        let h = makeMeshCoreEndpoint(withTCPClient: true)
        await h.store.send(.start)
        h.tcp.yield(.connected)
        await h.store.receive(.transport(.interfaceConnected(tcpID, .tcp)), timeout: receiveTimeout)
        await bringRadioOnline(h, start: false)
        let (raw, dest) = makeAnnounce(hops: 3)
        h.tcp.yield(.data(HDLC.frame(raw)))
        await h.store.receive({ if case .delegate(.pathLearned) = $0 { return true }; return false },
                              timeout: receiveTimeout)

        h.tcp.yield(.disconnected(reason: nil))           // TCP first: 2 → 1
        await h.store.receive(.transport(.interfaceDisconnected(tcpID)), timeout: receiveTimeout)
        h.radio.yield(.disconnected(reason: nil))         // the radio last: 1 → 0
        await h.store.receive(.transport(.interfaceDisconnected(radioID)), timeout: receiveTimeout)
        await h.store.skipReceivedActions(strict: false)
        #expect(h.store.state.interfaces.isEmpty)

        h.now.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))
        await h.clock.advance(by: .seconds(Transport.maintenanceTickInterval))
        await h.store.skipReceivedActions(strict: false)
        #expect(h.store.state.learned[dest] != nil, "with every interface gone no tick may sweep")
        await stopEndpoint(h)
    }

    @Test func radioLifecycleWithALiveTCPClientArmsMaintenanceOnce() async {
        let h = makeMeshCoreEndpoint(withTCPClient: true)
        await h.store.send(.start)
        h.tcp.yield(.connected)
        await h.store.receive(.transport(.interfaceConnected(tcpID, .tcp)), timeout: receiveTimeout)
        await bringRadioOnline(h, params: slowParams, start: false)
        await bringRadioOnline(h, params: fastParams, start: false)   // params change, no drop
        h.radio.yield(.disconnected(reason: nil))
        await h.store.receive(.transport(.interfaceDisconnected(radioID)), timeout: receiveTimeout)
        await bringRadioOnline(h, params: slowParams, start: false)   // reconnect
        await h.store.skipReceivedActions(strict: false)
        let starts = h.log.value.filter { $0 == "start" }.count
        #expect(starts == 1, "only the node's 0 → 1 transition arms maintenance; saw \(starts)")
        await stopEndpoint(h)
    }
}

/// The §5.5 limiter as `TransportEndpoint` runs it: in `transmit`, on the unmasked packet, with
/// its state in the slot.
@MainActor @Suite struct TransportEndpointMeshCoreLimiterTests {
    @Test func limiterStateSurvivesTheTransmitCall() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h)
        let (raw, _) = makeAnnounce()
        await transmit(h, raw)
        await transmit(h, raw)
        await settleOnAir(h, atLeast: 1)
        #expect(h.onAirPackets.count == 1)
        await stopEndpoint(h)
    }

    @Test func countersReachTheEndpointState() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h)
        let (raw, _) = makeAnnounce()
        await transmit(h, raw)
        await transmit(h, raw)
        #expect(h.store.state.meshCore?.counters.announcesLimited == 1)
        await stopEndpoint(h)
    }

    @Test func announceAt600SecondsReachesTheRadio() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h)
        let (raw, _) = makeAnnounce()
        await transmit(h, raw)
        h.at(600)
        await transmit(h, raw)
        await settleOnAir(h, atLeast: 2)
        #expect(h.onAirPackets.count == 2)
        await stopEndpoint(h)
    }

    @Test func limiterClassifiesTheUnmaskedPacketWithIFACOn() async {
        let h = makeMeshCoreEndpoint(profile: ifacProfile())
        await bringRadioOnline(h)
        let (raw, _) = makeAnnounce()
        await transmit(h, raw)
        await transmit(h, raw)
        await settleOnAir(h, atLeast: 1)
        #expect(h.onAirPackets.count == 1)
        #expect(h.store.state.meshCore?.counters.announcesLimited == 1)
        await stopEndpoint(h)
    }

    @Test func hopCapIsReadFromTheUnmaskedPacketWithIFACOn() async {
        let h = makeMeshCoreEndpoint(profile: ifacProfile())
        await bringRadioOnline(h)
        await transmit(h, makeAnnounce(hops: 3).raw)
        await Task.megaYield()
        #expect(h.onAirPackets.isEmpty)
        #expect(h.store.state.meshCore?.counters.announcesLimited == 1)
        await transmit(h, makeAnnounce(hops: 2).raw)
        await settleOnAir(h, atLeast: 1)
        #expect(h.onAirPackets.count == 1)
        await stopEndpoint(h)
    }

    @Test func seventhRelayedAnnounceDoesNotReachTheRadio() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h)
        for _ in 0..<7 { await transmit(h, makeAnnounce(hops: 1).raw) }
        await settleOnAir(h, atLeast: 6)
        #expect(h.onAirPackets.count == 6)
        await stopEndpoint(h)
    }

    @Test func thirteenthRelayedPathResponseDoesNotReachTheRadio() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h)
        for _ in 0..<13 { await transmit(h, makeAnnounce(hops: 1, pathResponse: true).raw) }
        await settleOnAir(h, atLeast: 12)
        #expect(h.onAirPackets.count == 12)
        await stopEndpoint(h)
    }

    @Test func seventhPathRequestDoesNotReachTheRadio() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h)
        for seed in UInt8(1)...7 { await transmit(h, pathRequestPacket(requested: meshCoreDestination(seed), tag: seed)) }
        await settleOnAir(h, atLeast: 6)
        #expect(h.onAirPackets.count == 6)
        #expect(h.store.state.meshCore?.counters.pathRequestsLimited == 1)
        await stopEndpoint(h)
    }

    @Test func aggregateCapsHoldWithIFACOn() async {
        let h = makeMeshCoreEndpoint(profile: ifacProfile())
        await bringRadioOnline(h)
        for seed in UInt8(1)...7 { await transmit(h, pathRequestPacket(requested: meshCoreDestination(seed), tag: seed)) }
        await settleOnAir(h, atLeast: 6)
        #expect(h.onAirPackets.count == 6)
        await stopEndpoint(h)
    }

    /// Keyed on the requested destination, not the fixed control hash every request is sent to:
    /// Y at +200 s is outside X's 60 s burst, but it's a different destination.
    @Test func pathRequestIsKeyedOnTheRequestedDestinationAtTheEndpoint() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h)
        await transmit(h, pathRequestPacket(requested: meshCoreDestination(0x58), tag: 1))
        h.at(200)
        await transmit(h, pathRequestPacket(requested: meshCoreDestination(0x59), tag: 2))
        await settleOnAir(h, atLeast: 2)
        #expect(h.onAirPackets.count == 2)
        await stopEndpoint(h)
    }

    @Test func limiterStateSurvivesARadioDrop() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h)
        let (raw, _) = makeAnnounce()
        await transmit(h, raw)
        await settleOnAir(h, atLeast: 1)
        h.radio.yield(.disconnected(reason: "flap"))
        await h.store.receive(.transport(.interfaceDisconnected(radioID)), timeout: receiveTimeout)
        await bringRadioOnline(h, start: false)
        await transmit(h, raw)
        await settleOnAir(h, atLeast: 1)
        #expect(h.onAirPackets.count == 1)
        #expect(h.store.state.meshCore?.counters.announcesLimited == 1)
        await stopEndpoint(h)
    }

    @Test func limiterStateSurvivesStopAndStart() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h)
        let (raw, _) = makeAnnounce()
        await transmit(h, raw)
        await settleOnAir(h, atLeast: 1)
        await h.store.send(.stop)
        await h.store.receive(.meshCore(.delegate(.radioOffline(reason: nil))), timeout: receiveTimeout)
        await bringRadioOnline(h, session: 1)
        await transmit(h, raw)
        await settleOnAir(h, atLeast: 1)
        #expect(h.onAirPackets.count == 1)
        #expect(h.store.state.meshCore?.counters.announcesLimited == 1)
        await stopEndpoint(h)
    }

    /// Limiting is policy, not a delivery failure: nothing above may retry or fail over on it.
    @Test func limitedPacketDoesNotReportSendFailed() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h)
        await transmit(h, makeAnnounce(hops: 3).raw)
        await Task.megaYield()
        await h.store.skipReceivedActions(strict: false)
        #expect(!h.log.value.contains("sendFailed"))
        await stopEndpoint(h)
    }

    @Test func transmitWhileOfflineConsumesNoLimiterBudget() async {
        let h = makeMeshCoreEndpoint()
        await h.store.send(.start)                       // started, not yet online
        let (raw, dest) = makeAnnounce()
        await transmit(h, raw)
        await h.store.receive(.delegate(.sendFailed(destinationHash: dest, reason: .interfaceUnavailable)),
                              timeout: receiveTimeout)
        h.at(1)
        await bringRadioOnline(h, start: false)
        await transmit(h, raw)
        await settleOnAir(h, atLeast: 1)
        #expect(h.onAirPackets == [raw])
        await stopEndpoint(h)
    }

    @Test func limiterDoesNotApplyToTheTCPInterface() async {
        let h = makeMeshCoreEndpoint(withTCPClient: true)
        await h.store.send(.start)
        h.tcp.yield(.connected)
        await h.store.receive(.transport(.interfaceConnected(tcpID, .tcp)), timeout: receiveTimeout)
        let (raw, _) = makeAnnounce()
        await transmit(h, raw, to: tcpID)
        h.at(1)
        await transmit(h, raw, to: tcpID)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: settleDeadline)
        while h.tcpSends.value.count < 2, clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        await Task.megaYield()
        #expect(h.tcpSends.value.count == 2)
        await stopEndpoint(h)
    }

    @Test func linkPlaneTransmitReachesTheRadioUnlimited() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h)
        let linkID = Data(repeating: 0x4C, count: 16)
        for index in UInt8(0)..<10 {
            let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                                destinationType: .link, context: .none, contextFlag: false, hops: 0,
                                destinationHash: linkID, transportId: nil, payload: Data([index]))
            await h.store.send(.linkPlane(.delegate(.transmit(radioID, try! packet.packed()))))
        }
        await settleOnAir(h, atLeast: 10)
        #expect(h.onAirPackets.count == 10)
        await stopEndpoint(h)
    }

    @Test func heardPathRequestLetsThePathResponseThrough() async {
        await assertHeardPathRequestAnswered(profile: .meshCore(params: nil))
    }

    @Test func heardPathRequestLetsThePathResponseThroughWithIFACOn() async {
        await assertHeardPathRequestAnswered(profile: ifacProfile())
    }

    /// Review Focus 3: a stranger without the IFAC key sends a plain request for a stamped
    /// destination. It fails the gate, so it must not open the 15 s bypass.
    @Test func pathRequestFailingIFACDoesNotOpenTheBypass() async {
        let h = makeMeshCoreEndpoint(profile: ifacProfile())
        await bringRadioOnline(h)
        let (raw, dest) = makeAnnounce()
        await transmit(h, raw)
        await settleOnAir(h, atLeast: 1)
        await receiveFromPeer(h, pathRequestPacket(requested: dest), packetID: 0x2000)
        h.at(1)
        await transmit(h, raw)
        await settleOnAir(h, atLeast: 1)
        #expect(h.onAirPackets.count == 1)
        #expect(h.store.state.meshCore?.counters.announcesLimited == 1)
        await stopEndpoint(h)
    }

    @Test func plainInterfaceIgnoresAnIFACFlaggedRequest() async {
        let h = makeMeshCoreEndpoint()
        await bringRadioOnline(h)
        var flagged = pathRequestPacket(requested: meshCoreDestination(0x33))
        flagged[0] |= 0x80
        await receiveFromPeer(h, flagged, packetID: 0x2000)
        #expect(h.store.state.meshCore?.interface.limiter.heardEntryCount == 0)
        await stopEndpoint(h)
    }
}

/// A local destination announced at t; a framed path request for it arrives at t+10, inside the
/// 600 s interval. The path response Transport answers with must reach the air.
@MainActor
private func assertHeardPathRequestAnswered(profile: InterfaceProfile) async {
    let h = makeMeshCoreEndpoint(profile: profile)
    await bringRadioOnline(h)
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["me"], identity: Identity())!
    await h.store.send(.registerLocalDestination(dest))
    await h.store.send(.announce(destinationHash: dest.hash, appData: nil))
    await settleOnAir(h, atLeast: 1)
    #expect(h.onAirPackets.count == 1)
    h.at(10)
    let request = pathRequestPacket(requested: dest.hash)
    await receiveFromPeer(h, profile.ifac?.protect(request) ?? request, packetID: 0x2000)
    await settleOnAir(h, atLeast: 2)
    let packets = h.onAirPackets
    #expect(packets.count == 2)
    guard packets.count == 2 else { await stopEndpoint(h); return }
    let response: Data? = if let ifac = profile.ifac { ifac.unprotect(packets[1]) } else { packets[1] }
    #expect(response.flatMap { Packet(raw: $0) }?.context == .pathResponse)
    await stopEndpoint(h)
}
