import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let radio = UUID(uuidString: "0000AAAA-0000-0000-0000-00000000BEEF")!
private let selfPrefix = Data([1, 2, 3, 4])
private let publicKey = Data(repeating: 0x11, count: 32)

private func params(_ sf: UInt8, _ bw: UInt32, _ cr: UInt8) -> MeshCoreLinkParams {
    MeshCoreLinkParams(spreadingFactor: sf, bandwidthHz: bw, codingRate: cr)
}

private func endpointConfig() -> MeshCoreDriverConfig {
    MeshCoreDriverConfig(radio: radio, channelSecret: Data(repeating: 0x22, count: 16))
}

private func isOnlineDelegate(_ action: MeshCoreEndpoint.Action) -> Bool {
    if case .interface(.delegate(.online)) = action { return true }
    return false
}

@MainActor @Suite struct MeshCoreEndpointTests {
    @Test func profileBitrateMatchesTheSpecTable() {
        let rows: [(MeshCoreLinkParams?, Int)] = [
            (params(7, 62_500, 5), 473), (params(7, 62_500, 7), 473), (params(8, 62_500, 8), 350),
            (params(9, 125_000, 5), 473), (params(10, 250_000, 5), 473), (params(11, 250_000, 5), 373),
            (nil, 236),
        ]
        for (linkParams, bitrate) in rows {
            #expect(InterfaceProfile.meshCore(params: linkParams).bitrate == bitrate,
                    "params \(String(describing: linkParams))")
        }
    }

    @Test func profileIsNamedMeshCore() {
        #expect(InterfaceProfile.meshCore(params: nil).name == "meshcore")
    }

    @Test func profileDeclaresAHardwareMTUOf500() {
        #expect(InterfaceProfile.meshCore(params: nil).hwMTU == 500)
    }

    @Test func profileModeIsTheTCPDefault() {
        #expect(InterfaceProfile.meshCore(params: nil).mode == InterfaceProfile.tcp.mode)
    }

    /// Review Focus 2: nonsense params give the nil rate, never a zero bitrate that traps.
    @Test func profileForOutOfRangeParamsDoesNotTrap() {
        #expect(InterfaceProfile.meshCore(params: params(0, 0, 5)).bitrate == 236)
    }

    @Test func registeredProfileTakesIFACFromTheEndpointProfile() {
        var profile = InterfaceProfile.meshCore(params: nil)
        profile.ifac = MeshCoreEndpoint.ifac(networkName: "mesh", passphrase: "pw")
        let state = MeshCoreEndpoint.State(config: endpointConfig(), profile: profile)
        #expect(state.registeredProfile(params: nil).ifac == profile.ifac)
    }

    @Test func registeredProfileTakesModeFromTheEndpointProfile() {
        var profile = InterfaceProfile.meshCore(params: nil)
        profile.mode = .roaming
        let state = MeshCoreEndpoint.State(config: endpointConfig(), profile: profile)
        #expect(state.registeredProfile(params: nil).mode == .roaming)
    }

    @Test func registeredProfileTakesStampCostsFromTheEndpointProfile() {
        var profile = InterfaceProfile.meshCore(params: nil)
        profile.destinationCost = 9
        profile.pathRequestCost = 12
        let state = MeshCoreEndpoint.State(config: endpointConfig(), profile: profile)
        #expect(state.registeredProfile(params: nil).destinationCost == 9)
        #expect(state.registeredProfile(params: nil).pathRequestCost == 12)
    }

    /// Every host-settable field survives except the radio-derived name, bitrate and hardware MTU,
    /// so a field added to `InterfaceProfile` later and forgotten by the driver fails this.
    @Test func registeredProfileKeepsEveryHostFieldExceptTheRadioDerivedOnes() {
        let profile = InterfaceProfile(name: "host", bitrate: 999, mode: .roaming, hwMTU: 1,
                                       announceCap: 0.5, ifac: MeshCoreEndpoint.ifac(networkName: "mesh", passphrase: "pw"),
                                       destinationCost: 9, pathRequestCost: 12)
        let state = MeshCoreEndpoint.State(config: endpointConfig(), profile: profile)
        let linkParams = params(8, 62_500, 8)
        let radioDerived = InterfaceProfile.meshCore(params: linkParams)
        var expected = profile
        expected.name = radioDerived.name
        expected.bitrate = radioDerived.bitrate
        expected.hwMTU = radioDerived.hwMTU
        #expect(state.registeredProfile(params: linkParams) == expected)
        #expect(state.registeredProfile(params: linkParams).announceCap == 0.5)
    }

    /// The endpoint's own profile bitrate is ignored: the radio's params decide it when it is online.
    @Test func registeredProfileTakesBitrateFromTheParams() {
        let profile = InterfaceProfile(name: "meshcore", bitrate: 999, hwMTU: 500)
        let state = MeshCoreEndpoint.State(config: endpointConfig(), profile: profile)
        #expect(state.registeredProfile(params: params(8, 62_500, 8)).bitrate == 350)
    }

    @Test func interfaceIDIsMeshCoreColonTheRadioUUID() {
        #expect(meshCoreInterfaceID(radio: radio) == InterfaceID("meshcore:0000AAAA-0000-0000-0000-00000000BEEF"))
    }

    @Test func ifacHelperUsesEightByteAccessCodes() throws {
        let ifac = try #require(MeshCoreEndpoint.ifac(networkName: "n", passphrase: "p"))
        let raw = Data(repeating: 0x05, count: 40)
        #expect(ifac.protect(raw).count == raw.count + 8)
    }

    @Test func endpointStartStartsTheDriver() async {
        let started = LockIsolated<[MeshCoreDriverConfig]>([])
        let stream = AsyncStream<MeshCoreDriverEvent>.makeStream()
        let config = endpointConfig()
        let store = TestStore(initialState: MeshCoreEndpoint.State(config: config)) {
            MeshCoreEndpoint()
        } withDependencies: {
            $0.meshCoreDriver = MeshCoreDriver(
                start: { cfg in
                    started.withValue { $0.append(cfg) }
                    return stream.stream
                },
                send: { _ in true }, removeChannel: { true }, stop: {})
            $0.meshCoreClock = ImmediateClock()
        }
        store.exhaustivity = .off
        await store.send(.start)
        stream.continuation.yield(.connected(selfPrefix: selfPrefix, publicKey: publicKey, params: nil))
        await store.receive(isOnlineDelegate)
        #expect(started.value == [config])
        await store.send(.stop)
        await store.skipReceivedActions(strict: false)
    }

    @Test func endpointRemoveChannelReachesTheDriver() async {
        let removals = LockIsolated(0)
        let (store, _) = await makeOnlineEndpoint(removeChannel: {
            removals.withValue { $0 += 1 }
            return true
        })
        await store.send(.removeChannel)
        await store.receive(.delegate(.channelRemoved(true)))
        #expect(removals.value == 1)
        await store.send(.stop)
        await store.skipReceivedActions(strict: false)
    }

    @Test func retiredChannelsClearedSurfacesOnTheEndpoint() async {
        let (store, radioEvents) = await makeOnlineEndpoint()
        radioEvents.yield(.retiredChannelsCleared)
        await store.receive(.delegate(.retiredChannelsCleared))
        await store.send(.stop)
        await store.skipReceivedActions(strict: false)
    }

    @Test func setCanRouteReachesTheInterface() async {
        let (store, _) = await makeOnlineEndpoint()
        await store.send(.setCanRoute(true))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.interface.config.canRoute == true)
        await store.send(.stop)
        await store.skipReceivedActions(strict: false)
    }

    @Test func countersShowAMalformedDatagram() async {
        let (store, radioEvents) = await makeOnlineEndpoint()
        radioEvents.yield(.datagram(Data([0x01])))
        await store.receive { if case .interface(.driverEvent(.datagram)) = $0 { return true }; return false }
        #expect(store.state.counters.malformed == 1)
        await store.send(.stop)
        await store.skipReceivedActions(strict: false)
    }

    /// One datagram goes in flight, 64 wait in the queue (pacing clock never advanced); the 66th
    /// single-datagram packet does not fit and is dropped whole.
    @Test func countersShowAQueueFullDrop() async {
        let (store, _) = await makeOnlineEndpoint()
        let packet = Data(repeating: 0x5A, count: 20)
        for _ in 0..<66 { await store.send(.interface(.send(packet))) }
        #expect(store.state.counters.queueFull == 1)
        await store.send(.stop)
        await store.skipReceivedActions(strict: false)
    }
}

/// A MeshCoreEndpoint whose radio is online with nil params, pacing on a TestClock that is never advanced.
@MainActor
private func makeOnlineEndpoint(removeChannel: @escaping @Sendable () async -> Bool = { true }) async
    -> (TestStore<MeshCoreEndpoint.State, MeshCoreEndpoint.Action>, AsyncStream<MeshCoreDriverEvent>.Continuation) {
    let stream = AsyncStream<MeshCoreDriverEvent>.makeStream()
    let store = TestStore(initialState: MeshCoreEndpoint.State(config: endpointConfig())) {
        MeshCoreEndpoint()
    } withDependencies: {
        $0.meshCoreDriver = MeshCoreDriver(start: { _ in stream.stream }, send: { _ in true },
                                           removeChannel: removeChannel, stop: {})
        $0.meshCoreClock = TestClock<Duration>()
        $0.meshCoreDate = DateGenerator { Date(timeIntervalSince1970: 0) }
    }
    store.exhaustivity = .off
    await store.send(.start)
    stream.continuation.yield(.connected(selfPrefix: selfPrefix, publicKey: publicKey, params: nil))
    await store.receive(isOnlineDelegate)
    return (store, stream.continuation)
}
