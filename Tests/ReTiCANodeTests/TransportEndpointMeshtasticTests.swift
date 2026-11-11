import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let radioUUID = UUID(uuidString: "0000AAAA-0000-0000-0000-00000000BEEF")!
private let radioID = meshtasticInterfaceID(radio: radioUUID)
private let tcpID = InterfaceID("tcp")
private let ownNode: UInt32 = 0x0A0A_0A0A
private let peerNode: UInt32 = 0x0B0B_0B0B

/// Records every maintenance start/stop, and every deregistration of the radio's interface id,
/// that the wrapped reducer processes, exactly once each.
private struct MeshMaintenanceRecorder<Wrapped: Reducer>: Reducer
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
        return wrapped.reduce(into: &state, action: action)
    }
}

@MainActor
private struct MeshEndpointHarness {
    let store: TestStore<TransportEndpoint.State, TransportEndpoint.Action>
    let radio: AsyncStream<MeshtasticDriverEvent>.Continuation
    let onAir: LockIsolated<[Data]>
    let tcp: AsyncStream<TCPEvent>.Continuation
    let now: LockIsolated<Date>
    let clock: TestClock<Duration>
    let maintenance: LockIsolated<[String]>
}

@MainActor
private func makeMeshEndpoint(profile: InterfaceProfile = .meshtastic(modemPreset: nil),
                              withTCPClient: Bool = false,
                              liveDriver: Bool = false) -> MeshEndpointHarness {
    let radio = AsyncStream<MeshtasticDriverEvent>.makeStream()
    let tcp = AsyncStream<TCPEvent>.makeStream()
    let onAir = LockIsolated<[Data]>([])
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let clock = TestClock<Duration>()
    let log = LockIsolated<[String]>([])
    let initial = TransportEndpoint.State(
        tcpClients: withTCPClient ? [TCPEndpoint.State(host: "peer", port: 4242, reconnectOnDrop: false)] : [],
        meshtastic: MeshtasticEndpoint.State(config: MeshtasticDriverConfig(radio: radioUUID), profile: profile))
    let mock = MeshtasticDriver(
        start: { _ in radio.stream },
        send: { frame in
            onAir.withValue { $0.append(frame) }
            return true
        },
        stop: {})
    let store = TestStore(initialState: initial) {
        MeshMaintenanceRecorder(log: log) { TransportEndpoint() }
    } withDependencies: {
        $0.meshtasticDriver = liveDriver ? MeshtasticDriver.liveValue : mock
        $0.meshtasticClock = ImmediateClock()
        $0.meshtasticDate = DateGenerator { Date(timeIntervalSince1970: 0) }
        $0.tcpConnection = TCPConnection(open: { _, _ in tcp.stream }, send: { _ in }, close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.transportDate = DateGenerator { now.value }
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return MeshEndpointHarness(store: store, radio: radio.continuation, onAir: onAir, tcp: tcp.continuation,
                               now: now, clock: clock, maintenance: log)
}

@MainActor
private func bringRadioOnline(_ h: MeshEndpointHarness, preset: Int? = 8, start: Bool = true) async {
    if start { await h.store.send(.start) }
    h.radio.yield(.connected(myNodeNum: ownNode, modemPreset: preset))
    await h.store.receive { if case .transport(.interfaceConnected(radioID, _)) = $0 { return true }; return false }
}

@MainActor
private func stopEndpoint(_ h: MeshEndpointHarness) async {
    await h.store.send(.stop)
    await h.store.skipReceivedActions(strict: false)
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

@MainActor @Suite struct TransportEndpointMeshtasticTests {
    @Test func radioOnlineRegistersItsInterfaceWithThePresetProfile() async {
        let h = makeMeshEndpoint()
        await bringRadioOnline(h, preset: 8)
        #expect(h.store.state.interfaces[radioID] == InterfaceProfile.meshtastic(modemPreset: 8))
        await stopEndpoint(h)
    }

    @Test func newPresetWhileOnlineReRegistersWithItsBitrate() async {
        let h = makeMeshEndpoint()
        await bringRadioOnline(h, preset: 8)
        h.radio.yield(.connected(myNodeNum: ownNode, modemPreset: 4))
        await h.store.receive { action in
            if case let .transport(.interfaceConnected(id, profile)) = action { return id == radioID && profile.bitrate == 404 }
            return false
        }
        #expect(h.store.state.interfaces[radioID]?.bitrate == 404)
        await stopEndpoint(h)
    }

    @Test func radioOnlineSurfacesOnTheMeshtasticHatch() async {
        let h = makeMeshEndpoint()
        await h.store.send(.start)
        h.radio.yield(.connected(myNodeNum: ownNode, modemPreset: 8))
        await h.store.receive { $0 == .meshtastic(.delegate(.radioOnline(myNodeNum: ownNode, modemPreset: 8))) }
        await stopEndpoint(h)
    }

    @Test func radioDropDeregistersItsInterface() async {
        let h = makeMeshEndpoint()
        await bringRadioOnline(h)
        h.radio.yield(.disconnected(reason: "gone"))
        await h.store.receive { $0 == .transport(.interfaceDisconnected(radioID)) }
        #expect(h.store.state.interfaces[radioID] == nil)
        await stopEndpoint(h)
    }

    @Test func radioDropSurfacesOnTheMeshtasticHatch() async {
        let h = makeMeshEndpoint()
        await bringRadioOnline(h)
        h.radio.yield(.disconnected(reason: "gone"))
        await h.store.receive { $0 == .meshtastic(.delegate(.radioOffline(reason: "gone"))) }
        await stopEndpoint(h)
    }

    @Test func endpointStopDeregistersTheRadio() async {
        let h = makeMeshEndpoint()
        await bringRadioOnline(h)
        await h.store.send(.stop)
        await h.store.receive { $0 == .transport(.interfaceDisconnected(radioID)) }
        #expect(h.store.state.interfaces[radioID] == nil)
        await h.store.skipReceivedActions(strict: false)
    }

    /// Contract 3: lane E sends `.meshtastic(.stop)` and waits for `.radioOffline` before
    /// clearing the slot — so a radio that never connected must still report it.
    @Test func endpointStopBeforeTheRadioConnectsSurfacesRadioOffline() async {
        let h = makeMeshEndpoint()
        await h.store.send(.start)                       // started, never connected
        await h.store.send(.stop)
        await h.store.receive { $0 == .meshtastic(.delegate(.radioOffline(reason: nil))) }
        await h.store.skipReceivedActions(strict: false)
    }

    /// A `.stop` after a drop reports offline a second time; the radio was already
    /// deregistered by the drop and must not be deregistered again.
    @Test func endpointStopAfterARadioDropDeregistersTheRadioOnce() async {
        let h = makeMeshEndpoint()
        await bringRadioOnline(h)
        h.radio.yield(.disconnected(reason: "gone"))
        await h.store.receive { $0 == .meshtastic(.delegate(.radioOffline(reason: "gone"))) }
        await h.store.send(.stop)
        await h.store.receive { $0 == .meshtastic(.delegate(.radioOffline(reason: nil))) }
        await h.store.skipReceivedActions(strict: false)
        let deregistrations = h.maintenance.value.filter { $0 == "radioDisconnected" }.count
        #expect(deregistrations == 1, "saw \(deregistrations) interfaceDisconnected for the radio")
    }

    @Test func inboundFragmentsReachTheRouterTaggedWithTheRadioID() async {
        let h = makeMeshEndpoint()
        await bringRadioOnline(h)
        let (raw, dest) = makeAnnounce()
        for frame in LandandairCodec().split(raw, index: 3) { h.radio.yield(.fragment(from: peerNode, frame)) }
        await h.store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
        #expect(h.store.state.learned[dest]?.interfaceID == radioID)
        await stopEndpoint(h)
    }

    @Test func transmitToTheRadioIDPutsThePacketOnTheAir() async {
        let h = makeMeshEndpoint()
        await bringRadioOnline(h)
        let (raw, _) = makeAnnounce()
        let expected = LandandairCodec().split(raw, index: 0)
        await h.store.send(.transport(.delegate(.transmit(radioID, raw))))
        for _ in expected {
            await h.store.receive { if case .meshtastic(.interface(.fragmentSent)) = $0 { return true }; return false }
        }
        #expect(h.onAir.value == expected)
        await stopEndpoint(h)
    }

    @Test func transmitOverAnIFACRadioMasksBeforeFragmenting() async {
        var profile = InterfaceProfile.meshtastic(modemPreset: nil)
        profile.ifac = MeshtasticEndpoint.ifac(networkName: "mesh", passphrase: "pw")
        let h = makeMeshEndpoint(profile: profile)
        await bringRadioOnline(h)
        let (raw, _) = makeAnnounce()
        let expected = LandandairCodec().split(profile.ifac!.protect(raw), index: 0)
        await h.store.send(.transport(.delegate(.transmit(radioID, raw))))
        for _ in expected {
            await h.store.receive { if case .meshtastic(.interface(.fragmentSent)) = $0 { return true }; return false }
        }
        #expect(h.onAir.value == expected)
        await stopEndpoint(h)
    }

    @Test func transmitWhileTheRadioIsOfflineReportsInterfaceUnavailable() async {
        let h = makeMeshEndpoint()
        await h.store.send(.start)                       // started, never connected
        let (raw, dest) = makeAnnounce()
        await h.store.send(.transport(.delegate(.transmit(radioID, raw))))
        await h.store.receive { $0 == .delegate(.sendFailed(destinationHash: dest, reason: .interfaceUnavailable)) }
        await stopEndpoint(h)
    }

    @Test func missingLiveAdapterSurfacesOnTheMeshtasticHatch() async {
        let h = makeMeshEndpoint(liveDriver: true)
        await h.store.send(.start)
        await h.store.receive {
            $0 == .meshtastic(.delegate(.adapterUnavailable(.other(MeshtasticDriver.liveAdapterMissing))))
        }
        await stopEndpoint(h)
    }
}

/// Shared maintenance must follow the SHARED interface count, never the radio slot's own state
/// (memory: multi-interface lesson; TransportEndpoint.swift:374-401).
@MainActor @Suite struct TransportEndpointMeshtasticMaintenanceTests {
    @Test func radioDropKeepsSharedMaintenanceAliveForTheTCPClient() async {
        let h = makeMeshEndpoint(withTCPClient: true)
        await h.store.send(.start)
        h.tcp.yield(.connected)
        await h.store.receive { $0 == .transport(.interfaceConnected(tcpID, .tcpClient)) }
        await bringRadioOnline(h, start: false)
        let (raw, dest) = makeAnnounce(hops: 3)
        h.tcp.yield(.data(HDLC.frame(raw)))
        await h.store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
        #expect(h.store.state.learned[dest]?.interfaceID == tcpID)

        h.radio.yield(.disconnected(reason: nil))
        await h.store.receive { $0 == .transport(.interfaceDisconnected(radioID)) }
        await h.store.skipReceivedActions(strict: false)
        #expect(h.store.state.interfaces.count == 1)

        h.now.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))
        await h.clock.advance(by: .seconds(Transport.maintenanceTickInterval))
        await h.store.skipReceivedActions(strict: false)
        #expect(h.store.state.learned[dest] == nil, "maintenance must survive the radio dropping while TCP is up")
        await stopEndpoint(h)
    }

    @Test func radioAsTheLastInterfaceToDropStopsSharedMaintenance() async {
        let h = makeMeshEndpoint(withTCPClient: true)
        await h.store.send(.start)
        h.tcp.yield(.connected)
        await h.store.receive { $0 == .transport(.interfaceConnected(tcpID, .tcpClient)) }
        await bringRadioOnline(h, start: false)
        let (raw, dest) = makeAnnounce(hops: 3)
        h.tcp.yield(.data(HDLC.frame(raw)))
        await h.store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }

        h.tcp.yield(.disconnected(reason: nil))           // TCP first: 2 → 1
        await h.store.receive { $0 == .transport(.interfaceDisconnected(tcpID)) }
        h.radio.yield(.disconnected(reason: nil))         // the radio last: 1 → 0
        await h.store.receive { $0 == .transport(.interfaceDisconnected(radioID)) }
        await h.store.skipReceivedActions(strict: false)
        #expect(h.store.state.interfaces.isEmpty)

        h.now.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))
        await h.clock.advance(by: .seconds(Transport.maintenanceTickInterval))
        await h.store.skipReceivedActions(strict: false)
        #expect(h.store.state.learned[dest] != nil, "with every interface gone no tick may sweep")
        await stopEndpoint(h)
    }

    @Test func radioLifecycleWithALiveTCPClientArmsMaintenanceOnce() async {
        let h = makeMeshEndpoint(withTCPClient: true)
        await h.store.send(.start)
        h.tcp.yield(.connected)
        await h.store.receive { $0 == .transport(.interfaceConnected(tcpID, .tcpClient)) }
        await bringRadioOnline(h, preset: 8, start: false)
        await bringRadioOnline(h, preset: 4, start: false)     // preset change, no drop
        h.radio.yield(.disconnected(reason: nil))
        await h.store.receive { $0 == .transport(.interfaceDisconnected(radioID)) }
        await bringRadioOnline(h, preset: 8, start: false)     // reconnect
        await h.store.skipReceivedActions(strict: false)
        let starts = h.maintenance.value.filter { $0 == "start" }.count
        #expect(starts == 1, "only the node's 0 → 1 transition arms maintenance; saw \(starts)")
        await stopEndpoint(h)
    }
}
