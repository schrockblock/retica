import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let radio = UUID(uuidString: "0000AAAA-0000-0000-0000-00000000BEEF")!
/// Sideband's defaults: 868.1 MHz, 62.5 kHz, 0 dBm, SF 8, CR 6.
private let sidebandParams = RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 62_500, txPowerDBm: 0,
                                             spreadingFactor: 8, codingRate: 6)
private let config = RNodeDriverConfig(radio: radio, params: sidebandParams)
private let report = RNodeRadioReport(firmwareMajor: 1, firmwareMinor: 86, platform: 0x80, params: sidebandParams)

private enum Call: Equatable {
    case start
    case stop
}

@MainActor @Suite struct RNodeEndpointTests {
    @Test func profileBitrateFollowsTheParams() {
        #expect(InterfaceProfile.rnode(params: sidebandParams).bitrate == 1302)
        let slow = RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 125_000, txPowerDBm: 0,
                                   spreadingFactor: 12, codingRate: 8)
        #expect(InterfaceProfile.rnode(params: slow).bitrate == 183)
    }

    @Test func profileForNilParamsUsesTheUnknownBitrate() {
        #expect(InterfaceProfile.rnode(params: nil).bitrate == 183)
        #expect(RNodeEndpoint.unknownBitrate == 183)
    }

    @Test func profileIsNamedRNode() {
        #expect(InterfaceProfile.rnode(params: nil).name == "rnode")
    }

    @Test func profileDeclaresAHardwareMTUOf508() {
        #expect(InterfaceProfile.rnode(params: nil).hwMTU == 508)
    }

    @Test func profileModeIsFull() {
        #expect(InterfaceProfile.rnode(params: nil).mode == .full)
    }

    @Test func registeredProfileTakesIFACFromTheEndpointProfile() {
        var profile = InterfaceProfile.rnode(params: nil)
        profile.ifac = RNodeEndpoint.ifac(networkName: "mesh", passphrase: "pw")
        let state = RNodeEndpoint.State(config: config, profile: profile)
        #expect(profile.ifac != nil)
        #expect(state.registeredProfile(params: sidebandParams).ifac == profile.ifac)
    }

    @Test func registeredProfileTakesModeFromTheEndpointProfile() {
        var profile = InterfaceProfile.rnode(params: nil)
        profile.mode = .roaming
        let state = RNodeEndpoint.State(config: config, profile: profile)
        #expect(state.registeredProfile(params: sidebandParams).mode == .roaming)
    }

    @Test func registeredProfileTakesStampCostsFromTheEndpointProfile() {
        var profile = InterfaceProfile.rnode(params: nil)
        profile.destinationCost = 9
        profile.pathRequestCost = 12
        let state = RNodeEndpoint.State(config: config, profile: profile)
        #expect(state.registeredProfile(params: sidebandParams).destinationCost == 9)
        #expect(state.registeredProfile(params: sidebandParams).pathRequestCost == 12)
    }

    /// Every host-settable field survives except the radio-derived name, bitrate and hardware MTU,
    /// so a driver that drops a current field fails this. (A field added later passes until the
    /// host profile here sets it to a non-default value.)
    @Test func registeredProfileKeepsEveryHostFieldExceptTheRadioDerivedOnes() {
        let profile = InterfaceProfile(name: "host", bitrate: 999, mode: .roaming, hwMTU: 1,
                                       announceCap: 0.5, ifac: RNodeEndpoint.ifac(networkName: "mesh", passphrase: "pw"),
                                       destinationCost: 9, pathRequestCost: 12)
        let state = RNodeEndpoint.State(config: config, profile: profile)
        let radioDerived = InterfaceProfile.rnode(params: sidebandParams)
        var expected = profile
        expected.name = radioDerived.name
        expected.bitrate = radioDerived.bitrate
        expected.hwMTU = radioDerived.hwMTU
        #expect(state.registeredProfile(params: sidebandParams) == expected)
        #expect(state.registeredProfile(params: sidebandParams).announceCap == 0.5)
    }

    /// The endpoint's own profile bitrate is ignored: the params the radio echoed decide it.
    @Test func registeredProfileTakesBitrateFromTheReportedParams() {
        let profile = InterfaceProfile(name: "rnode", bitrate: 999, hwMTU: 508)
        let state = RNodeEndpoint.State(config: config, profile: profile)
        let reported = RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 250_000, txPowerDBm: 0,
                                       spreadingFactor: 10, codingRate: 5)
        #expect(state.registeredProfile(params: reported).bitrate == 1953)
    }

    @Test func interfaceIDIsRNodeColonTheRadioUUID() {
        #expect(rnodeInterfaceID(radio: radio) == InterfaceID("rnode:" + radio.uuidString))
        #expect(RNodeEndpoint.State(config: config).interfaceID == InterfaceID("rnode:" + radio.uuidString))
    }

    @Test func ifacHelperUsesEightByteAccessCodes() throws {
        let ifac = try #require(RNodeEndpoint.ifac(networkName: "n", passphrase: "p"))
        #expect(RNodeEndpoint.ifacSize == 8)
        let raw = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B])
        #expect(ifac.protect(raw).count == raw.count + 8)
    }

    @Test func endpointStartStartsTheDriver() async {
        let (store, _, calls) = makeEndpoint()
        await store.send(.start)
        await waitFor(calls, count: 1)
        #expect(calls.value == [.start])
        await shutDown(store)
    }

    @Test func endpointStopStopsTheDriver() async {
        let (store, events, calls) = await makeOnlineEndpoint()
        await store.send(.stop)
        await store.skipReceivedActions(strict: false)
        events.finish()
        #expect(calls.value == [.start, .stop])
    }

    @Test func countersShowAnOversizePacket() async {
        let (store, _, _) = await makeOnlineEndpoint()
        await store.send(.interface(.send(Data(repeating: 0x5A, count: RNodeInterface.maxPacketSize + 1))))
        #expect(store.state.counters.oversize == 1)
        await shutDown(store)
    }

    @Test func telemetryShowsTheLastRSSI() async {
        let (store, events, _) = await makeOnlineEndpoint()
        let packet = Data(repeating: 0x11, count: 60)
        events.yield(.packet(packet, rssi: -97, snr: 6.25))
        await store.receive { if case .interface(.delegate(.packetReceived)) = $0 { return true }; return false }
        #expect(store.state.telemetry.lastRSSI == -97)
        await shutDown(store)
    }
}

private typealias EndpointStore = TestStore<RNodeEndpoint.State, RNodeEndpoint.Action>

@MainActor
private func makeEndpoint() -> (EndpointStore, AsyncStream<RNodeDriverEvent>.Continuation, LockIsolated<[Call]>) {
    let stream = AsyncStream<RNodeDriverEvent>.makeStream()
    let calls = LockIsolated<[Call]>([])
    let store = TestStore(initialState: RNodeEndpoint.State(config: config)) {
        RNodeEndpoint()
    } withDependencies: {
        $0.rnodeDriver = RNodeDriver(
            start: { _ in calls.withValue { $0.append(.start) }; return stream.stream },
            send: { _ in true },
            stop: { calls.withValue { $0.append(.stop) } })
    }
    store.exhaustivity = .off
    store.timeout = .seconds(5)
    return (store, stream.continuation, calls)
}

@MainActor
private func makeOnlineEndpoint() async
    -> (EndpointStore, AsyncStream<RNodeDriverEvent>.Continuation, LockIsolated<[Call]>) {
    let (store, events, calls) = makeEndpoint()
    await store.send(.start)
    events.yield(.connected(report))
    await store.receive { if case .interface(.delegate(.online)) = $0 { return true }; return false }
    return (store, events, calls)
}

@MainActor
private func shutDown(_ store: EndpointStore) async {
    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

/// Polls (no fixed sleep) until `calls` holds at least `count` entries, without failing.
@MainActor
private func waitFor(_ calls: LockIsolated<[Call]>, count: Int) async {
    for _ in 0..<400 where calls.value.count < count { await Task.megaYield() }
}
