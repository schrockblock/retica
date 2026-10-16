import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let radio = UUID(uuidString: "0000AAAA-0000-0000-0000-00000000BEEF")!

@MainActor @Suite struct MeshtasticEndpointTests {
    @Test func profileBitrateIsThePacedRateOfThePreset() {
        let rows: [(Int?, Int)] = [(8, 4040), (6, 1616), (5, 538), (4, 404), (3, 269),
                                   (0, 202), (7, 134), (1, 107), (2, 230), (nil, 230)]
        for (preset, bitrate) in rows {
            #expect(InterfaceProfile.meshtastic(modemPreset: preset).bitrate == bitrate,
                    "preset \(String(describing: preset))")
        }
    }

    @Test func profileIsNamedMeshtastic() {
        #expect(InterfaceProfile.meshtastic(modemPreset: 0).name == "meshtastic")
    }

    @Test func profileDeclaresAHardwareMTUOf500() {
        #expect(InterfaceProfile.meshtastic(modemPreset: 0).hwMTU == 500)
    }

    @Test func profileModeIsTheTCPDefault() {
        #expect(InterfaceProfile.meshtastic(modemPreset: 0).mode == InterfaceProfile.tcp.mode)
    }

    @Test func registeredProfileTakesIFACFromTheEndpointProfile() {
        var profile = InterfaceProfile.meshtastic(modemPreset: nil)
        profile.ifac = MeshtasticEndpoint.ifac(networkName: "mesh", passphrase: "pw")
        let state = MeshtasticEndpoint.State(config: MeshtasticDriverConfig(radio: radio), profile: profile)
        #expect(state.registeredProfile(modemPreset: 8).ifac == profile.ifac)
    }

    @Test func registeredProfileTakesModeFromTheEndpointProfile() {
        var profile = InterfaceProfile.meshtastic(modemPreset: nil)
        profile.mode = .roaming
        let state = MeshtasticEndpoint.State(config: MeshtasticDriverConfig(radio: radio), profile: profile)
        #expect(state.registeredProfile(modemPreset: 8).mode == .roaming)
    }

    /// The endpoint's own profile bitrate is ignored: the radio's preset decides it at `.connected`.
    @Test func registeredProfileTakesBitrateFromThePreset() {
        let profile = InterfaceProfile(name: "meshtastic", bitrate: 999, hwMTU: 500)
        let state = MeshtasticEndpoint.State(config: MeshtasticDriverConfig(radio: radio), profile: profile)
        #expect(state.registeredProfile(modemPreset: 8).bitrate == 4040)
    }

    @Test func interfaceIDIsMeshtasticColonTheRadioUUID() {
        #expect(meshtasticInterfaceID(radio: radio) == InterfaceID("meshtastic:0000AAAA-0000-0000-0000-00000000BEEF"))
    }

    @Test func ifacHelperUsesEightByteAccessCodes() {
        #expect(MeshtasticEndpoint.ifac(networkName: "n", passphrase: "p") == IFAC(networkName: "n", passphrase: "p", size: 8))
    }

    @Test func endpointStartStartsTheRadioDriver() async {
        let config = MeshtasticDriverConfig(radio: radio, channel: 1, hopLimit: 2)
        let started = LockIsolated<[MeshtasticDriverConfig]>([])
        let stream = AsyncStream<MeshtasticDriverEvent>.makeStream()
        let store = TestStore(initialState: MeshtasticEndpoint.State(config: config)) {
            MeshtasticEndpoint()
        } withDependencies: {
            $0.meshtasticDriver = MeshtasticDriver(
                start: { cfg in
                    started.withValue { $0.append(cfg) }
                    return stream.stream
                },
                send: { _ in true },
                stop: {})
            $0.meshtasticClock = ImmediateClock()
        }
        store.exhaustivity = .off
        await store.send(.start)
        stream.continuation.yield(.connected(myNodeNum: 1, modemPreset: 8))
        await store.receive { if case .interface(.delegate(.online)) = $0 { return true }; return false }
        #expect(started.value == [config])
        await store.send(.stop)
        await store.skipReceivedActions(strict: false)
    }

    @Test func malformedFragmentShowsInTheEndpointCounters() async {
        let (store, radioEvents) = await makeOnlineEndpoint()
        radioEvents.yield(.fragment(from: 7, Data([0x01])))
        await store.receive { if case .interface(.driverEvent(.fragment)) = $0 { return true }; return false }
        #expect(store.state.counters.malformed == 1)
        await store.send(.stop)
        await store.skipReceivedActions(strict: false)
    }

    /// 85 three-fragment packets fill the queue (1 in flight + 254 queued, pacing clock never
    /// advanced); the 86th is dropped whole.
    @Test func queueFullDropShowsInTheEndpointCounters() async {
        let (store, _) = await makeOnlineEndpoint()
        let packet = Data(repeating: 0x5A, count: 500)
        for _ in 0..<86 { await store.send(.interface(.send(packet))) }
        #expect(store.state.counters.queueFull == 1)
        await store.send(.stop)
        await store.skipReceivedActions(strict: false)
    }
}

/// A MeshtasticEndpoint whose radio is online at LongFast, pacing on a TestClock that is never advanced.
@MainActor
private func makeOnlineEndpoint() async
    -> (TestStore<MeshtasticEndpoint.State, MeshtasticEndpoint.Action>, AsyncStream<MeshtasticDriverEvent>.Continuation) {
    let stream = AsyncStream<MeshtasticDriverEvent>.makeStream()
    let store = TestStore(initialState: MeshtasticEndpoint.State(config: MeshtasticDriverConfig(radio: radio))) {
        MeshtasticEndpoint()
    } withDependencies: {
        $0.meshtasticDriver = MeshtasticDriver(start: { _ in stream.stream }, send: { _ in true }, stop: {})
        $0.meshtasticClock = TestClock<Duration>()
        $0.meshtasticDate = DateGenerator { Date(timeIntervalSince1970: 0) }
    }
    store.exhaustivity = .off
    await store.send(.start)
    stream.continuation.yield(.connected(myNodeNum: 1, modemPreset: 0))
    await store.receive { if case .interface(.delegate(.online)) = $0 { return true }; return false }
    return (store, stream.continuation)
}
