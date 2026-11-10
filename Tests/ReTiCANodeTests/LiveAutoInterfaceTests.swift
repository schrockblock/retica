import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCATransport
@testable import ReTiCAInterfaces
@testable import ReTiCA

// LIVE INTEROP: ReTiCA's AutoInterface against a real reference `rnsd` on a SECOND host on the same
// LAN segment. Off by default: it runs only when BOTH variables are set.
//
// One Mac cannot do this. Two AutoInterface instances on one host share each NIC's link-local
// address, so each treats the other's discovery token as its own echo and they never peer, and with
// the default data port the second instance's bind fails (spec 2026-11-10-autointerface §4.10).
// If NomadNet or rnsd runs on THIS Mac it holds the default ports: stop it first, or this test fails
// with `dataPortInUse`.
//
// Host B (Pi, Linux box, second Mac, or a Linux VM with BRIDGED networking), config in
// /tmp/rns-auto/config as in spec §7.4, then:
//     rnsd --config /tmp/rns-auto -vv
// and note the hash in the log line "will respond to probe requests on <...>".
//
// This Mac:
//     RETICA_LIVE_AUTO_DEVICE=en0 RETICA_LIVE_AUTO_PROBE=<probe hash, 32 hex> \
//       swift test --no-parallel --filter LiveAutoInterface
//
// Pass criteria, in order (§7.4 step 3), each asserted below:
//   1. no bind failure / dataPortInUse / noUsableInterfaces on this Mac's NIC,
//   2. `peerAdded` for B on that NIC, with an fe80: address, within `peerWindow`,
//   3. a path request makes B announce its probe destination, learned over `auto:<nic>/<B fe80>`,
//   4. a packet to the probe destination is proved by rnsd (PROVE_ALL): `singlePacketDelivered`,
//   5. `.stop` leaves no peer registered.
// B's side (`rnstatus --config /tmp/rns-auto -a` lists AutoInterfacePeer[en0/<Mac fe80>], and B logs
// "removed peer" 22-26 s after ReTiCA stops) is for the person running this to read; see §7.4.

private let autoDevice = ProcessInfo.processInfo.environment["RETICA_LIVE_AUTO_DEVICE"]
private let autoProbe = ProcessInfo.processInfo.environment["RETICA_LIVE_AUTO_PROBE"]
private let liveAutoEnabled = autoDevice != nil && autoProbe != nil

/// Delegate events as rendered strings (`TransportEndpoint.Action.Delegate` is not Sendable).
@Reducer
private struct AutoHarness {
    @ObservableState
    struct State: Equatable { var endpoint: TransportEndpoint.State }
    enum Action { case endpoint(TransportEndpoint.Action) }
    let sink: @Sendable (String) -> Void

    var body: some ReducerOf<Self> {
        Scope(state: \.endpoint, action: \.endpoint) { TransportEndpoint() }
        Reduce { _, action in
            switch action {
            case let .endpoint(.auto(.interface(.delegate(d)))):
                switch d {
                case let .peerAdded(addr, nic): sink("peerAdded addr=\(addr) nic=\(nic)")
                case let .peerRemoved(addr): sink("peerRemoved addr=\(addr)")
                case let .dataPortInUse(nic): sink("dataPortInUse nic=\(nic)")
                case .noUsableInterfaces: sink("noUsableInterfaces")
                case let .multicastUnavailable(nic): sink("multicastUnavailable nic=\(nic)")
                case .localNetworkDenied: sink("localNetworkDenied")
                case let .carrierLost(nic): sink("carrierLost nic=\(nic)")
                case let .carrierRecovered(nic): sink("carrierRecovered nic=\(nic)")
                case .packetReceived: break
                }
            case let .endpoint(.delegate(.singlePacketDelivered(token))):
                sink("singlePacketDelivered token=\(token.hexString)")
            case let .endpoint(.delegate(.sendFailed(dest, reason))):
                sink("sendFailed dest=\(dest.hexString) reason=\(reason)")
            default: break
            }
            return .none
        }
    }
}

@Suite(.serialized, .enabled(if: liveAutoEnabled), .timeLimit(.minutes(3)))
@MainActor struct LiveAutoInterfaceTests {
    /// Generous but bounded. The spec's pass criterion is "within about 2 s"; the elapsed time is
    /// printed so a slow-but-passing run is visible.
    private let peerWindow: Duration = .seconds(8)

    private func waitFor(_ timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    @Test func reTiCAPeersWithAReferenceRnsdOverAutoInterfaceAndGetsAProbeProved() async throws {
        let nic = try #require(autoDevice)
        let probeHex = try #require(autoProbe).trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = try #require(Data(hexString: probeHex), "RETICA_LIVE_AUTO_PROBE must be hex")
        #expect(probe.count == 16, "a destination hash is 16 bytes (32 hex characters)")

        let events = LockIsolated<[String]>([])
        func seen(_ prefix: String) -> String? { events.value.first { $0.hasPrefix(prefix) } }

        let auto = AutoEndpoint.State(config: AutoInterfaceConfig(devices: [nic]))
        // `.live` is load-bearing: under a test context TCA resolves dependencies to `testValue`, and
        // the live POSIX driver would never be used.
        let store = Store(initialState: AutoHarness.State(endpoint: .auto(auto))) {
            AutoHarness { e in events.withValue { $0.append(e) } }
        } withDependencies: { $0.context = .live }

        let started = ContinuousClock.now
        store.send(.endpoint(.start))

        // 1 and 2. A peer on the NIC. A bind failure surfaces as dataPortInUse/noUsableInterfaces,
        // and that is the likely cause of a miss on a Mac that also runs rnsd or NomadNet.
        let peered = await waitFor(peerWindow) { seen("peerAdded") != nil }
        let elapsed = ContinuousClock.now - started
        #expect(seen("dataPortInUse") == nil,
                "this Mac's data port is held by another process (NomadNet or rnsd?): stop it first")
        #expect(seen("noUsableInterfaces") == nil, "no usable NIC named \(nic)")
        #expect(seen("localNetworkDenied") == nil, "the OS denied local network access")
        #expect(peered, "no peerAdded within \(peerWindow): is host B on the same segment and NIC? events: \(events.value)")
        guard peered else { store.send(.endpoint(.stop)); return }
        print("LIVE AUTO: peerAdded after \(elapsed)")
        let added = try #require(seen("peerAdded"))
        #expect(added.contains("addr=fe80:"), "the peer address must be link-local: \(added)")
        #expect(added.hasSuffix("nic=\(nic)"), "the peer must be heard on \(nic): \(added)")
        let peers = store.state.endpoint.auto?.peerInterfaces ?? [:]
        #expect(peers.values.contains { $0.nic == nic && $0.addr.hasPrefix("fe80:") },
                "the peer must be registered as an interface")

        // 3. Path learned through the peer's own interface (`auto:<nic>/<addr>`), not a loopback one.
        // The request itself is sent to every registered peer, so it exercises the data plane out.
        store.send(.endpoint(.requestPath(destinationHash: probe)))
        let learned = await waitFor(.seconds(30)) { store.state.endpoint.transport.learned[probe] != nil }
        #expect(learned, "B never announced the probe destination (is respond_to_probes = Yes, hash right?)")
        guard learned else { store.send(.endpoint(.stop)); return }
        let route = try #require(store.state.endpoint.transport.learned[probe]).interfaceID
        #expect(route.rawValue.hasPrefix("auto:\(nic)/fe80:"), "path learned over \(route.rawValue)")
        #expect(peers.keys.contains(route), "the learned route must be a registered peer interface")

        // 4. A packet to the probe destination, proved by rnsd (PROVE_ALL, Transport.py:648).
        // Random payload as `rnprobe` sends. Both directions of data and the proof are covered.
        let token = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let payload = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        store.send(.endpoint(.send(destinationHash: probe, plaintext: payload, receiptToken: token)))
        let proved = await waitFor(.seconds(30)) {
            events.value.contains("singlePacketDelivered token=\(token.hexString)")
                || seen("sendFailed") != nil
        }
        #expect(seen("sendFailed") == nil, "the send failed outright: \(seen("sendFailed") ?? "")")
        #expect(proved && events.value.contains("singlePacketDelivered token=\(token.hexString)"),
                "rnsd never proved the probe packet. events: \(events.value)")

        // 5. Stop. B logs "removed peer" 22-26 s later; read that on B.
        store.send(.endpoint(.stop))
        let cleared = await waitFor(.seconds(5)) { store.state.endpoint.auto?.peerInterfaces.isEmpty == true }
        #expect(cleared, "a stopped AutoInterface must leave no registered peer")
    }
}
