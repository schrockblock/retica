import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCATransport
@testable import ReTiCAInterfaces
@testable import ReTiCA

// LIVE INTEROP PROBE — disabled by default; requires the reference harness to be running.
//
// Drives the real `TCPEndpoint` against a stock Reticulum topology:
//
//     ReTiCA  ->  rnsd (transport node, 127.0.0.1:4250)  ->  reference LXMF peer
//
// which is the same shape as the device setup being debugged (relayed, so the link
// request takes the HEADER_2 path and carries a transport id). A stock RNS prober
// establishes over this topology in ~5ms, so the harness is known good: a failure
// here is ReTiCA's.
//
// To run:
//   1. rnsd --config /tmp/ReTiCA/linkprobe/hub_config -v
//   2. python /tmp/ReTiCA/linkprobe/peer.py
//   3. RETICA_LIVE_PROBE=1 swift test --no-parallel --filter LiveLinkProbe
//
// Left in the tree rather than /tmp because it is the only executable statement of
// what ReTiCA-as-link-initiator does against genuine reference code.
private let liveProbeEnabled = ProcessInfo.processInfo.environment["RETICA_LIVE_PROBE"] == "1"
private let peerHashPath = "/tmp/ReTiCA/linkprobe/peer_hash.txt"

/// Records every endpoint delegate so the probe can wait on outcomes.
@Reducer
private struct ProbeHarness {
    @ObservableState
    struct State: Equatable { var endpoint = TCPEndpoint.State(host: "127.0.0.1", port: 4250) }
    enum Action { case endpoint(TCPEndpoint.Action) }

    /// `TCPEndpoint.Action.Delegate` is not Sendable, so the probe records a rendered
    /// summary rather than the value itself.
    let sink: @Sendable (String) -> Void

    var body: some ReducerOf<Self> {
        Scope(state: \.endpoint, action: \.endpoint) { TCPEndpoint() }
        Reduce { _, action in
            guard case let .endpoint(.delegate(d)) = action else { return .none }
            switch d {
            case let .linkEstablished(linkID, _):
                sink("ESTABLISHED linkID=\(linkID.hexString.prefix(8))")
            case let .linkFailed(_, reason):
                sink("FAILED reason=\(reason)")
            case let .linkClosed(_, reason):
                sink("CLOSED reason=\(reason)")
            case let .pathLearned(h, hops):
                sink("PATH dest=\(h.hexString.prefix(8)) hops=\(hops)")
            default:
                break
            }
            return .none
        }
    }
}

@Suite(.serialized)
struct LiveLinkProbeTests {

    @MainActor
    private func waitFor(
        _ label: String,
        timeout: Duration = .seconds(30),
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test(.enabled(if: liveProbeEnabled))
    @MainActor
    func reTiCAEstablishesAnOutboundLinkToAReferencePeer() async throws {
        let hex = try String(contentsOfFile: peerHashPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let peerHash = try #require(Data(hexString: hex))
        #expect(peerHash.count == 16)

        let events = LockIsolated<[String]>([])
        // `.live` is load-bearing: inside a test context TCA resolves dependencies to
        // `testValue`, and several of ReTiCA's (the clocks, `\.transportDate`) are
        // `unimplemented`, so the probe traps before it reaches the network.
        let store = Store(initialState: ProbeHarness.State()) {
            ProbeHarness { e in events.withValue { $0.append(e) } }
        } withDependencies: {
            $0.context = .live
        }

        store.send(.endpoint(.connect))

        // 1. The socket must come up.
        let connected = await waitFor("connect") {
            store.state.endpoint.interface.status == .online
        }
        #expect(connected, "never connected to the hub — is rnsd running on 4250?")

        // 2. The peer announces every 20s; ask for a path rather than waiting on the cycle.
        store.send(.endpoint(.requestPath(destinationHash: peerHash)))
        let learned = await waitFor("path", timeout: .seconds(45)) {
            store.state.endpoint.transport.learned[peerHash] != nil
        }
        #expect(learned, "no path learned for the peer — announce never arrived")
        guard learned else { return }

        let entry = store.state.endpoint.transport.learned[peerHash]
        print("PROBE: path learned hops=\(entry?.hops ?? 255) "
              + "nextHop=\(entry?.nextHop?.hexString.prefix(8) ?? "nil") "
              + "dest=\(peerHash.hexString.prefix(8))")

        // 3. The thing under test.
        store.send(.endpoint(.openLink(destinationHash: peerHash)))

        let settled = await waitFor("link", timeout: .seconds(25)) {
            events.value.contains { $0.hasPrefix("ESTABLISHED") || $0.hasPrefix("FAILED") }
        }
        #expect(settled, "link neither established nor failed within 25s")

        for event in events.value { print("PROBE: \(event)") }

        let established = events.value.contains { $0.hasPrefix("ESTABLISHED") }
        #expect(established, "ReTiCA could not establish an outbound link to a stock RNS peer")

        store.send(.endpoint(.disconnect))
    }
}
