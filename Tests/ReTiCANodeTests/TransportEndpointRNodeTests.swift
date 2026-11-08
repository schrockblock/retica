import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let radioUUID = UUID(uuidString: "0000EEEE-0000-0000-0000-00000000BEEF")!
private let radioID = rnodeInterfaceID(radio: radioUUID)
/// The neighbour radios share the RNode's UUID: their ids still differ by prefix.
private let meshtasticID = meshtasticInterfaceID(radio: radioUUID)
private let meshCoreID = meshCoreInterfaceID(radio: radioUUID)
private let tcpID = InterfaceID("tcp")
/// Sideband's defaults: 868.1 MHz, 62.5 kHz, 0 dBm, SF 8, CR 6: 1302 bps.
private let sidebandParams = RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 62_500, txPowerDBm: 0,
                                             spreadingFactor: 8, codingRate: 6)
/// SF 10 / 250 kHz / CR 5: 1953 bps.
private let reclampedParams = RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 250_000, txPowerDBm: 0,
                                              spreadingFactor: 10, codingRate: 5)
private let meshCorePrefix = Data([0x0A, 0x0A, 0x0A, 0x0A])
private let meshCoreKey = meshCorePrefix + Data(repeating: 0x0A, count: 28)
private let meshCoreParams = MeshCoreLinkParams(spreadingFactor: 8, bandwidthHz: 62_500, codingRate: 8)
private let receiveTimeout: Duration = .seconds(5)
private let pollDeadline: Duration = .seconds(10)

private func rnodeReport(_ params: RNodeLoRaParams = sidebandParams) -> RNodeRadioReport {
    RNodeRadioReport(firmwareMajor: 1, firmwareMinor: 86, platform: 0x80, params: params)
}

/// Records maintenance start/stop, deregistrations of the RNode's id, and every packet handed to
/// the RNode interface, that the wrapped reducer processes, exactly once each.
private struct RNodeEndpointRecorder<Wrapped: Reducer>: Reducer
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
        if case .rnode(.interface(.send)) = action { log.withValue { $0.append("rnodeSend") } }
        return wrapped.reduce(into: &state, action: action)
    }
}

@MainActor
private struct RNodeEndpointHarness {
    let store: TestStore<TransportEndpoint.State, TransportEndpoint.Action>
    /// One fresh session per `driver.start`, appended before `start` returns.
    let sessions: LockIsolated<[AsyncStream<RNodeDriverEvent>.Continuation]>
    /// What the RNode driver was asked to send, in order.
    let onAir: LockIsolated<[Data]>
    let meshtastic: AsyncStream<MeshtasticDriverEvent>.Continuation
    let meshCore: AsyncStream<MeshCoreDriverEvent>.Continuation
    let tcp: AsyncStream<TCPEvent>.Continuation
    let now: LockIsolated<Date>
    let clock: TestClock<Duration>
    let log: LockIsolated<[String]>

    /// Polls until the RNode driver has been started `count` times, then yields to the newest
    /// session.
    func yieldToRadio(_ event: RNodeDriverEvent, afterStarts count: Int = 1) async {
        let sessions = self.sessions
        _ = await rnodeEndpointWaitUntil { sessions.value.count >= count }
        sessions.value.last?.yield(event)
    }
}

@MainActor
private func makeRNodeEndpoint(profile: InterfaceProfile = .rnode(params: nil),
                               withTCPClient: Bool = false,
                               withMeshtastic: Bool = false,
                               withMeshCore: Bool = false,
                               liveDriver: Bool = false) -> RNodeEndpointHarness {
    let sessions = LockIsolated<[AsyncStream<RNodeDriverEvent>.Continuation]>([])
    let onAir = LockIsolated<[Data]>([])
    let meshtastic = AsyncStream<MeshtasticDriverEvent>.makeStream()
    let meshCore = AsyncStream<MeshCoreDriverEvent>.makeStream()
    let tcp = AsyncStream<TCPEvent>.makeStream()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let clock = TestClock<Duration>()
    let log = LockIsolated<[String]>([])
    let initial = TransportEndpoint.State(
        tcpClients: withTCPClient ? [TCPEndpoint.State(host: "peer", port: 4242, reconnectOnDrop: false)] : [],
        meshtastic: withMeshtastic ? MeshtasticEndpoint.State(config: MeshtasticDriverConfig(radio: radioUUID)) : nil,
        meshCore: withMeshCore
            ? MeshCoreEndpoint.State(config: MeshCoreDriverConfig(radio: radioUUID,
                                                                  channelSecret: Data(repeating: 0x22, count: 16)))
            : nil,
        rnode: RNodeEndpoint.State(config: RNodeDriverConfig(radio: radioUUID, params: sidebandParams),
                                   profile: profile))
    let mock = RNodeDriver(
        start: { _ in
            let session = AsyncStream<RNodeDriverEvent>.makeStream()
            sessions.withValue { $0.append(session.continuation) }
            return session.stream
        },
        send: { packet in
            onAir.withValue { $0.append(packet) }
            return true
        },
        stop: {})
    let store = TestStore(initialState: initial) {
        RNodeEndpointRecorder(log: log) { TransportEndpoint() }
    } withDependencies: {
        $0.rnodeDriver = liveDriver ? RNodeDriver.liveValue : mock
        // The neighbour radios, when present: mock drivers, an immediate clock and constant dates
        // (`meshCoreDate` keeps its constant test value).
        $0.meshtasticDriver = MeshtasticDriver(start: { _ in meshtastic.stream }, send: { _ in true }, stop: {})
        $0.meshtasticClock = ImmediateClock()
        $0.meshtasticDate = DateGenerator { Date(timeIntervalSince1970: 0) }
        $0.meshCoreDriver = MeshCoreDriver(start: { _ in meshCore.stream }, send: { _ in true },
                                           removeChannel: { true }, stop: {})
        $0.meshCoreClock = ImmediateClock()
        $0.tcpConnection = TCPConnection(open: { _, _ in tcp.stream }, send: { _ in }, close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.transportDate = DateGenerator { now.value }
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return RNodeEndpointHarness(store: store, sessions: sessions, onAir: onAir,
                                meshtastic: meshtastic.continuation, meshCore: meshCore.continuation,
                                tcp: tcp.continuation, now: now, clock: clock, log: log)
}

/// Polls (bounded, real time) until `condition` holds; returns whether it did.
private func rnodeEndpointWaitUntil(timeout: Duration = pollDeadline,
                                    _ condition: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
private func bringRadioOnline(_ h: RNodeEndpointHarness, params: RNodeLoRaParams = sidebandParams,
                              start: Bool = true) async {
    if start { await h.store.send(.start) }
    await h.yieldToRadio(.connected(rnodeReport(params)))
    await h.store.receive({ if case .transport(.interfaceConnected(radioID, _)) = $0 { return true }; return false },
                          timeout: receiveTimeout)
}

@MainActor
private func bringMeshtasticOnline(_ h: RNodeEndpointHarness) async {
    h.meshtastic.yield(.connected(myNodeNum: 0x0A0A_0A0A, modemPreset: 8))
    await h.store.receive({ if case .transport(.interfaceConnected(meshtasticID, _)) = $0 { return true }; return false },
                          timeout: receiveTimeout)
}

@MainActor
private func bringMeshCoreOnline(_ h: RNodeEndpointHarness) async {
    h.meshCore.yield(.connected(selfPrefix: meshCorePrefix, publicKey: meshCoreKey, params: meshCoreParams))
    await h.store.receive({ if case .transport(.interfaceConnected(meshCoreID, _)) = $0 { return true }; return false },
                          timeout: receiveTimeout)
}

@MainActor
private func stopEndpoint(_ h: RNodeEndpointHarness) async {
    await h.store.send(.stop)
    await h.store.skipReceivedActions(strict: false)
}

@MainActor
private func transmit(_ h: RNodeEndpointHarness, _ raw: Data, to id: InterfaceID = radioID) async {
    await h.store.send(.transport(.delegate(.transmit(id, raw))))
}

private func makeAnnounce(hops: UInt8 = 0, emitted: UInt64 = 1000) -> (raw: Data, destinationHash: Data) {
    let identity = Identity()
    let nameHash = Destination.nameHash(appName: "app", aspects: ["svc"])
    let destHash = Destination.hash(identityHash: identity.hash, appName: "app", aspects: ["svc"])
    let randomHash = Announce.randomHash(now: emitted, randomPrefix: Data(repeating: 0xA5, count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, appData: nil)
    let packet = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: hops,
                        destinationHash: destHash, transportId: nil, payload: payload)
    return (try! packet.packed(), destHash)
}

/// A HEADER_1 data packet of exactly `Packet.mtu` (500) bytes: 2 header + 16 hash + 1 context.
private func fullSizePacket() -> Data {
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: Data(repeating: 0x3C, count: 16), transportId: nil,
                        payload: Data(repeating: 0x5A, count: 481))
    return try! packet.packed()
}

private func ifacProfile() -> InterfaceProfile {
    var profile = InterfaceProfile.rnode(params: nil)
    profile.ifac = RNodeEndpoint.ifac(networkName: "mesh", passphrase: "pw")
    return profile
}

@MainActor @Suite struct TransportEndpointRNodeTests {
    @Test func radioOnlineRegistersItsInterfaceWithTheReportedProfile() async {
        let h = makeRNodeEndpoint()
        await bringRadioOnline(h, params: sidebandParams)
        #expect(h.store.state.interfaces[radioID] == InterfaceProfile.rnode(params: sidebandParams))
        await stopEndpoint(h)
    }

    /// Review Focus 2: the radio reconnects with params the firmware clamped differently. Transport
    /// re-registers with their bitrate, and maintenance is never armed twice without a stop.
    @Test func reconnectWithNewParamsReRegistersWithTheirBitrate() async {
        let h = makeRNodeEndpoint()
        await bringRadioOnline(h, params: sidebandParams)
        await h.yieldToRadio(.disconnected(reason: "reset"))
        await h.store.receive(.transport(.interfaceDisconnected(radioID)), timeout: receiveTimeout)
        await h.yieldToRadio(.connected(rnodeReport(reclampedParams)))
        await h.store.receive({ action in
            if case let .transport(.interfaceConnected(id, profile)) = action { return id == radioID && profile.bitrate == 1953 }
            return false
        }, timeout: receiveTimeout)
        await h.store.skipReceivedActions(strict: false)
        #expect(h.store.state.interfaces[radioID]?.bitrate == 1953)
        let maintenance = h.log.value.filter { $0 == "start" || $0 == "stop" }
        let doubleArmed = zip(maintenance, maintenance.dropFirst()).contains { $0 == "start" && $1 == "start" }
        #expect(!doubleArmed, "maintenance log: \(maintenance)")
        await stopEndpoint(h)
    }

    @Test func radioOnlineSurfacesOnTheRNodeHatch() async {
        let h = makeRNodeEndpoint()
        await h.store.send(.start)
        await h.yieldToRadio(.connected(rnodeReport()))
        await h.store.receive(.rnode(.delegate(.radioOnline(rnodeReport()))), timeout: receiveTimeout)
        await stopEndpoint(h)
    }

    @Test func radioDropDeregistersItsInterface() async {
        let h = makeRNodeEndpoint()
        await bringRadioOnline(h)
        await h.yieldToRadio(.disconnected(reason: "gone"))
        await h.store.receive(.transport(.interfaceDisconnected(radioID)), timeout: receiveTimeout)
        #expect(h.store.state.interfaces[radioID] == nil)
        await stopEndpoint(h)
    }

    @Test func radioDropSurfacesOnTheRNodeHatch() async {
        let h = makeRNodeEndpoint()
        await bringRadioOnline(h)
        await h.yieldToRadio(.disconnected(reason: "gone"))
        await h.store.receive(.rnode(.delegate(.radioOffline(reason: "gone"))), timeout: receiveTimeout)
        await stopEndpoint(h)
    }

    @Test func endpointStopDeregistersTheRadio() async {
        let h = makeRNodeEndpoint()
        await bringRadioOnline(h)
        await h.store.send(.stop)
        await h.store.receive(.transport(.interfaceDisconnected(radioID)), timeout: receiveTimeout)
        #expect(h.store.state.interfaces[radioID] == nil)
        await h.store.skipReceivedActions(strict: false)
    }

    /// Contract 3: the host sends `.rnode(.stop)` and waits for `.radioOffline` before clearing
    /// the slot, so a radio that never connected must still report it.
    @Test func endpointStopBeforeTheRadioConnectsSurfacesRadioOffline() async {
        let h = makeRNodeEndpoint()
        await h.store.send(.start)                       // started, never connected
        await h.store.send(.stop)
        await h.store.receive(.rnode(.delegate(.radioOffline(reason: nil))), timeout: receiveTimeout)
        await h.store.skipReceivedActions(strict: false)
    }

    /// A `.stop` after a drop reports offline a second time; the radio was already deregistered by
    /// the drop and must not be deregistered again.
    @Test func endpointStopAfterARadioDropDeregistersTheRadioOnce() async {
        let h = makeRNodeEndpoint()
        await bringRadioOnline(h)
        await h.yieldToRadio(.disconnected(reason: "gone"))
        await h.store.receive(.rnode(.delegate(.radioOffline(reason: "gone"))), timeout: receiveTimeout)
        await h.store.send(.stop)
        await h.store.receive(.rnode(.delegate(.radioOffline(reason: nil))), timeout: receiveTimeout)
        await h.store.skipReceivedActions(strict: false)
        let deregistrations = h.log.value.filter { $0 == "radioDisconnected" }.count
        #expect(deregistrations == 1, "saw \(deregistrations) interfaceDisconnected for the radio")
    }

    @Test func inboundPacketsReachTheRouterTaggedWithTheRadioID() async {
        let h = makeRNodeEndpoint()
        await bringRadioOnline(h)
        let (raw, dest) = makeAnnounce()
        await h.yieldToRadio(.packet(raw, rssi: -90, snr: 7.5))
        await h.store.receive({ if case .delegate(.pathLearned) = $0 { return true }; return false },
                              timeout: receiveTimeout)
        #expect(h.store.state.learned[dest]?.interfaceID == radioID)
        await stopEndpoint(h)
    }

    @Test func transmitToTheRadioIDPutsThePacketOnTheDriver() async {
        let h = makeRNodeEndpoint()
        await bringRadioOnline(h)
        let (raw, _) = makeAnnounce()
        await transmit(h, raw)
        _ = await rnodeEndpointWaitUntil { !h.onAir.value.isEmpty }
        #expect(h.onAir.value == [raw])
        await stopEndpoint(h)
    }

    @Test func transmitOverAnIFACRadioMasksThePacket() async {
        let h = makeRNodeEndpoint(profile: ifacProfile())
        await bringRadioOnline(h)
        let (raw, _) = makeAnnounce()
        await transmit(h, raw)
        _ = await rnodeEndpointWaitUntil { !h.onAir.value.isEmpty }
        let sent = h.onAir.value
        #expect(sent.count == 1)
        #expect(sent.first?.count == raw.count + 8)
        #expect(sent.first.map { $0[$0.startIndex] & 0x80 } == 0x80)
        await stopEndpoint(h)
    }

    /// Review Focus 3: a full 500-byte packet with 8-byte IFAC reaches the driver as 508 bytes and
    /// isn't counted oversize.
    @Test func aFullSizePacketWithIFACIsSent() async {
        let h = makeRNodeEndpoint(profile: ifacProfile())
        await bringRadioOnline(h)
        let raw = fullSizePacket()
        #expect(raw.count == 500)
        await transmit(h, raw)
        _ = await rnodeEndpointWaitUntil { !h.onAir.value.isEmpty }
        #expect(h.onAir.value.map(\.count) == [508])
        #expect(h.store.state.rnode?.counters.oversize == 0)
        await stopEndpoint(h)
    }

    @Test func transmitWhileTheRadioIsOfflineReportsInterfaceUnavailable() async {
        let h = makeRNodeEndpoint()
        await h.store.send(.start)                       // started, never connected
        let (raw, dest) = makeAnnounce()
        await transmit(h, raw)
        await h.store.receive(.delegate(.sendFailed(destinationHash: dest, reason: .interfaceUnavailable)),
                              timeout: receiveTimeout)
        await stopEndpoint(h)
    }

    @Test func missingLiveAdapterSurfacesOnTheRNodeHatch() async {
        let h = makeRNodeEndpoint(liveDriver: true)
        await h.store.send(.start)
        await h.store.receive(.rnode(.delegate(.adapterUnavailable(.other(RNodeDriver.liveAdapterMissing)))),
                              timeout: receiveTimeout)
        await stopEndpoint(h)
    }

    /// Review Focus 5: Meshtastic, MeshCore and RNode slots at once, all for the same radio UUID,
    /// register three interfaces.
    @Test func threeRadioSlotsRegisterSeparateInterfaces() async {
        let h = makeRNodeEndpoint(withMeshtastic: true, withMeshCore: true)
        await h.store.send(.start)
        await bringMeshtasticOnline(h)
        await bringMeshCoreOnline(h)
        await bringRadioOnline(h, start: false)
        await h.store.skipReceivedActions(strict: false)
        #expect(h.store.state.interfaces.count == 3)
        #expect(h.store.state.interfaces[meshtasticID] == InterfaceProfile.meshtastic(modemPreset: 8))
        #expect(h.store.state.interfaces[meshCoreID] == InterfaceProfile.meshCore(params: meshCoreParams))
        #expect(h.store.state.interfaces[radioID] == InterfaceProfile.rnode(params: sidebandParams))
        await stopEndpoint(h)
    }

    /// Review Focus 5: an RNode drop deregisters only `rnode:`.
    @Test func anRNodeDropLeavesTheOtherRadiosRegistered() async {
        let h = makeRNodeEndpoint(withMeshtastic: true, withMeshCore: true)
        await h.store.send(.start)
        await bringMeshtasticOnline(h)
        await bringMeshCoreOnline(h)
        await bringRadioOnline(h, start: false)
        await h.yieldToRadio(.disconnected(reason: "gone"))
        await h.store.receive(.rnode(.delegate(.radioOffline(reason: "gone"))), timeout: receiveTimeout)
        await h.store.skipReceivedActions(strict: false)
        #expect(Set(h.store.state.interfaces.keys) == [meshtasticID, meshCoreID])
        await stopEndpoint(h)
    }

    /// The Meshtastic slot is present but not yet connected, so nothing ahead of the RNode branch
    /// claims its id: only the id check keeps the packet off the online RNode.
    @Test func transmitToAnotherRadiosIDNeverReachesTheRNode() async {
        let h = makeRNodeEndpoint(withMeshtastic: true)
        await bringRadioOnline(h)
        let (raw, dest) = makeAnnounce()
        await transmit(h, raw, to: meshtasticID)
        await h.store.receive(.delegate(.sendFailed(destinationHash: dest, reason: .interfaceUnavailable)),
                              timeout: receiveTimeout)
        await Task.megaYield()
        #expect(!h.log.value.contains("rnodeSend"))
        #expect(h.onAir.value.isEmpty)
        await stopEndpoint(h)
    }
}

/// Shared maintenance must follow the SHARED interface count, never the radio slot's own state.
@MainActor @Suite struct TransportEndpointRNodeMaintenanceTests {
    @Test func radioDropKeepsSharedMaintenanceAliveForTheTCPClient() async {
        let h = makeRNodeEndpoint(withTCPClient: true)
        await h.store.send(.start)
        h.tcp.yield(.connected)
        await h.store.receive(.transport(.interfaceConnected(tcpID, .tcp)), timeout: receiveTimeout)
        await bringRadioOnline(h, start: false)
        let (raw, dest) = makeAnnounce(hops: 3)
        h.tcp.yield(.data(HDLC.frame(raw)))
        await h.store.receive({ if case .delegate(.pathLearned) = $0 { return true }; return false },
                              timeout: receiveTimeout)
        #expect(h.store.state.learned[dest]?.interfaceID == tcpID)

        await h.yieldToRadio(.disconnected(reason: nil))
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
        let h = makeRNodeEndpoint(withTCPClient: true)
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
        await h.yieldToRadio(.disconnected(reason: nil))  // the radio last: 1 → 0
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
        let h = makeRNodeEndpoint(withTCPClient: true)
        await h.store.send(.start)
        h.tcp.yield(.connected)
        await h.store.receive(.transport(.interfaceConnected(tcpID, .tcp)), timeout: receiveTimeout)
        await bringRadioOnline(h, params: sidebandParams, start: false)
        await bringRadioOnline(h, params: reclampedParams, start: false)   // params change, no drop
        await h.yieldToRadio(.disconnected(reason: nil))
        await h.store.receive(.transport(.interfaceDisconnected(radioID)), timeout: receiveTimeout)
        await bringRadioOnline(h, params: sidebandParams, start: false)    // reconnect
        await h.store.skipReceivedActions(strict: false)
        let starts = h.log.value.filter { $0 == "start" }.count
        #expect(starts == 1, "only the node's 0 → 1 transition arms maintenance; saw \(starts)")
        await stopEndpoint(h)
    }
}
