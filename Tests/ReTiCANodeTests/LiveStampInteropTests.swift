import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCATransport
@testable import ReTiCA

// LIVE INTEROP: a real LXMFNode over TCP against real reference routers. Off by default.
//
//   RETICA_LIVE_STAMP_PYTHON=/Users/ell/opt/anaconda3/envs/rns-latest/bin/python \
//     swift test --no-parallel --filter LiveStampInteropTests
//
// The peers are configured as MeshChatX configures its router: cost 8, enforced. See
// Scripts/stampprobe/peer.py.
//
// Every assertion that matters reads the PEER's log. An enforcing peer proves a packet and then drops
// it, so `deliveryConfirmed` is true of a message that was thrown away. These scenarios all passed
// that check while the messages were being lost, and 1,766 unit tests were green at the time.

private let pythonPath = ProcessInfo.processInfo.environment["RETICA_LIVE_STAMP_PYTHON"]
private let peerScript = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Scripts/stampprobe/peer.py").path

/// A reference peer process with its own Reticulum instance.
@MainActor
private final class Peer {
    let dir: String
    private let process = Process()

    init(_ name: String, _ arguments: [String]) throws {
        dir = NSTemporaryDirectory() + "retica-stamp-\(UUID().uuidString.prefix(8))-\(name)"
        process.executableURL = URL(fileURLWithPath: pythonPath!)
        process.arguments = ["-u", peerScript, "--dir", dir] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func read(_ file: String) -> String? { try? String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8) }
    var pnAddressFile: String { "\(dir)/pn_address" }

    func address(_ file: String = "address") async throws -> Data {
        let text = await poll(seconds: 30) { self.read(file)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        return try #require(text.flatMap { Data(hexString: $0) })
    }

    /// The peer's log line for a message containing `text`, which only exists if it survived enforcement.
    func received(containing text: String, within seconds: Double = 40) async -> String? {
        await poll(seconds: seconds) {
            self.read("received.log")?.split(separator: "\n").map(String.init).first { $0.contains(text) }
        }
    }
}

@MainActor
private func poll<T>(seconds: Double, _ value: () -> T?) async -> T? {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if let found = value() { return found }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return value()
}

private func nextPort() -> Int { Int.random(in: 42000..<48000) }

@Reducer
private struct Harness {
    @ObservableState
    struct State: Equatable { var node: LXMFNode.State }
    enum Action { case node(LXMFNode.Action) }
    let inbound: LockIsolated<[String]>
    let accepted: LockIsolated<Int>
    let linkFailures: LockIsolated<Int>

    var body: some ReducerOf<Self> {
        Scope(state: \.node, action: \.node) { LXMFNode() }
        Reduce { state, action in
            guard case let .node(a) = action else { return .none }
            if case .endpoint(.transport(.interfaceConnected)) = a, state.node.deliveryDestinationHash == nil {
                return .concatenate(.send(.node(.setDisplayName("ReTiCA", stampCost: nil))),
                                    .send(.node(.registerDelivery)))
            }
            if case let .delegate(.messageReceived(m, _, _)) = a {
                inbound.withValue { $0.append(String(decoding: m.content, as: UTF8.self)) }
            }
            if case .delegate(.propagationAccepted) = a { accepted.withValue { $0 += 1 } }
            if case .endpoint(.delegate(.linkFailed)) = a { linkFailures.withValue { $0 += 1 } }
            return .none
        }
    }
}

@MainActor
private final class LiveNode {
    let identity = Identity()
    let inbound = LockIsolated<[String]>([])
    let accepted = LockIsolated(0)
    /// Every `linkFailed` the endpoint reported, whatever the reason.
    let linkFailures = LockIsolated(0)
    let store: StoreOf<Harness>

    /// `stampPathRequests` is the host's switch for RNS 1.6 path-request stamps, set at construction.
    init(port: Int, stampPathRequests: Bool = false) async throws {
        let (inbound, accepted, linkFailures) = (self.inbound, self.accepted, self.linkFailures)
        var initial = Harness.State(node: LXMFNode.State(
            identity: identity, endpoint: TCPEndpoint.State(host: "127.0.0.1", port: UInt16(port), reconnectOnDrop: true)))
        initial.node.endpoint.transport.stampPathRequests = stampPathRequests
        store = Store(initialState: initial) {
            Harness(inbound: inbound, accepted: accepted, linkFailures: linkFailures)
        } withDependencies: { $0.context = .live }
        store.send(.node(.endpoint(.start)))
        let registered = await poll(seconds: 30) { self.store.state.node.deliveryDestinationHash }
        _ = try #require(registered)
    }

    func stop() { store.send(.node(.endpoint(.stop))) }

    /// Through `.sendMessage`, the path ReTiCaMsgr uses.
    func send(_ text: String, to dest: Data) {
        store.send(.node(.sendMessage(message: LXMessage.create(
            source: identity, destinationHash: dest, timestamp: Date().timeIntervalSince1970,
            title: Data(), content: Data(text.utf8)), fallbackToPropagation: false)))
    }

    func hears(_ dest: Data, within seconds: Double = 60) async -> Bool {
        await poll(seconds: seconds) { self.store.state.node.endpoint.learned[dest] != nil ? true : nil } == true
    }
}

@Suite(.serialized, .enabled(if: pythonPath != nil), .timeLimit(.minutes(5)))
@MainActor struct LiveStampInteropTests {
    /// RNS 1.6 appends a stamp extension to app-data. We must still read the cost behind it.
    @Test func aStampedAnnounceGivesUsTheCostAndTheMessageSurvivesEnforcement() async throws {
        let port = nextPort()
        let peer = try Peer("stamped", ["--listen", "\(port)", "--announce-every", "3", "--network-stamps"])
        defer { peer.stop() }
        let dest = try await peer.address()
        let node = try await LiveNode(port: port)
        defer { node.stop() }

        #expect(await node.hears(dest))
        let appData = try #require(node.store.state.node.endpoint.learned[dest]?.appData)
        #expect(appData[appData.index(appData.endIndex, offsetBy: -18)] == 0xC1, "the peer must really be stamping")
        #expect(node.store.state.node.learnedPeers[dest]?.stampCost == 8)
        #expect(node.store.state.node.learnedPeers[dest]?.displayName == "Reference peer")

        node.send("behind a stamped announce", to: dest)
        let log = try #require(await peer.received(containing: "behind a stamped announce"))
        #expect(log.contains("stamp_valid=True"))
    }

    /// Nothing heard yet: the first message is the one that used to be lost.
    @Test func aFirstMessageBeforeAnyAnnounceSurvivesEnforcement() async throws {
        let port = nextPort()
        let peer = try Peer("first", ["--listen", "\(port)"])
        defer { peer.stop() }
        let dest = try await peer.address()
        let node = try await LiveNode(port: port)
        defer { node.stop() }

        #expect(node.store.state.node.endpoint.learned[dest] == nil)
        node.send("first before any announce", to: dest)
        let log = try #require(await peer.received(containing: "first before any announce"))
        #expect(log.contains("stamp_valid=True"))
    }

    /// Too big for one packet, so over a link to a destination with a link cost (3.25 in LXMF 1.3.0).
    @Test func aLargeMessageOverALinkSurvivesEnforcement() async throws {
        let port = nextPort()
        let peer = try Peer("link", ["--listen", "\(port)", "--announce-every", "3"])
        defer { peer.stop() }
        let dest = try await peer.address()
        let node = try await LiveNode(port: port)
        defer { node.stop() }

        #expect(await node.hears(dest))
        node.send("large " + String(repeating: "x", count: 2000), to: dest)
        let log = try #require(await peer.received(containing: "large xxx"))
        #expect(log.contains("stamp_valid=True"))
        #expect(log.contains("method=2"), "2 is LXMessage.DIRECT")
    }

    /// RNS 1.6 link-request stamps against a peer that enforces them (`enforce_stamps = yes`), so an
    /// unstamped LINKREQUEST is dropped (Link.py:195). The peer's own announce carries a stamp of value
    /// 24, at least the 23.5 we demand before believing the link cost it announces.
    ///
    /// The peer announces cost 12, not LXMF's 3.25: a random key meets 3.25 about one time in ten, and
    /// LXMF retries a failed link, so at 3.25 this test passed with stamping switched off. At 12 a
    /// random key passes one time in 4,096, and the first link must come up with no failure before it.
    @Test func aLinkRequestSurvivesAPeerEnforcingNetworkStamps() async throws {
        let port = nextPort()
        let peer = try Peer("enforce-link", ["--listen", "\(port)", "--announce-every", "3", "--network-stamps",
                                             "--destination-value", "24", "--enforce-network", "--link-cost", "12"])
        defer { peer.stop() }
        let dest = try await peer.address()
        let node = try await LiveNode(port: port)
        defer { node.stop() }

        #expect(await node.hears(dest, within: 240), "mining a value-24 stamp delays the peer's first announce")
        #expect(node.store.state.node.endpoint.knownDestinations[dest]?.linkCost == 12)
        node.send("enforced link " + String(repeating: "y", count: 2000), to: dest)
        let log = try #require(await peer.received(containing: "enforced link yyy", within: 60))
        #expect(log.contains("method=2"), "2 is LXMessage.DIRECT")
        #expect(node.linkFailures.value == 0, "the first, stamped, link request must be the one accepted")
    }

    /// The control for the test above: the same enforcing peer, one link opened with an ordinary key
    /// and one through the endpoint, which stamps it. Only the stamped one may come up. Cost 12, so an
    /// ordinary key is refused 4,095 times in 4,096 (at 3.25 it would come up one time in ten).
    @Test func anUnstampedLinkRequestIsIgnoredByAnEnforcingPeer() async throws {
        let port = nextPort()
        let peer = try Peer("enforce-refuse", ["--listen", "\(port)", "--announce-every", "3", "--network-stamps",
                                               "--destination-value", "24", "--enforce-network", "--link-cost", "12"])
        defer { peer.stop() }
        let dest = try await peer.address()
        let node = try await LiveNode(port: port)
        defer { node.stop() }
        #expect(await node.hears(dest, within: 240))
        let learned = try #require(node.store.state.node.endpoint.learned[dest])
        #expect(node.store.state.node.endpoint.knownDestinations[dest]?.linkCost == 12)

        func ourLink() -> LinkSession.State? {
            node.store.state.node.endpoint.linkPlane.links.first { $0.role == .initiator && $0.destinationHash == dest }
        }
        #expect(ourLink() == nil)
        node.store.send(.node(.endpoint(.linkPlane(.openLink(initiatorTo: learned.identity, destinationHash: dest,
                                                              interfaceID: learned.interfaceID, relayNextHop: nil,
                                                              linkCost: nil)))))
        #expect(ourLink() != nil, "an unstamped link starts at once")
        // It must leave on its establishment deadline (15 s on TCP) without ever going active.
        var wentActive = false
        let gone = await poll(seconds: 30) { () -> Bool? in
            if ourLink()?.status == .active { wentActive = true }
            return ourLink() == nil ? true : nil
        }
        #expect(!wentActive, "the enforcing peer must not answer an unstamped request")
        #expect(gone == true)

        node.store.send(.node(.endpoint(.openLink(destinationHash: dest))))
        let up = await poll(seconds: 30) { ourLink()?.status == .active ? true : nil }
        #expect(up == true, "the same peer accepts a stamped request")
    }

    /// RNS 1.6 path-request stamps against a peer that enforces them: an enforcing 1.6.0 node drops a
    /// path request without a stamp meeting its interface's `pr_cost` (15.8) at ingress
    /// (Transport.py:2128-2129). The peer never announces on its own, so the only way we learn its
    /// path is its answer to our stamped request.
    @Test func aPathRequestFromReTiCAReachesAnEnforcingPeer() async throws {
        let port = nextPort()
        let peer = try Peer("enforce-pr", ["--listen", "\(port)", "--enforce-network"])
        defer { peer.stop() }
        let dest = try await peer.address()
        let node = try await LiveNode(port: port, stampPathRequests: true)
        defer { node.stop() }

        #expect(node.store.state.node.endpoint.learned[dest] == nil)
        node.store.send(.node(.endpoint(.requestPath(destinationHash: dest))))
        #expect(await node.hears(dest, within: 30), "the enforcing peer must answer a stamped request")
    }

    /// The control for the test above: the same enforcing, silent peer, asked without a stamp, never
    /// answers. A random 14 bytes would meet 15.8 about one time in 57,000, but an unstamped request
    /// carries no extension at all.
    @Test func aPathRequestToAnEnforcingPeerIsDroppedWhenItIsNotStamped() async throws {
        let port = nextPort()
        let peer = try Peer("enforce-pr-drop", ["--listen", "\(port)", "--enforce-network"])
        defer { peer.stop() }
        let dest = try await peer.address()
        let node = try await LiveNode(port: port, stampPathRequests: false)
        defer { node.stop() }

        node.store.send(.node(.endpoint(.requestPath(destinationHash: dest))))
        #expect(await node.hears(dest, within: 20) == false, "an enforcing peer must drop an unstamped request")
    }

    @Test func aMessageFromAReferencePeerArrives() async throws {
        let port = nextPort()
        let peer = try Peer("reply", ["--listen", "\(port)", "--announce-every", "3", "--reply"])
        defer { peer.stop() }
        _ = try await peer.address()
        let node = try await LiveNode(port: port)
        defer { node.stop() }
        let heard = await poll(seconds: 40) { node.inbound.value.contains("hello from the reference peer") ? true : nil }
        #expect(heard == true)
    }

    /// The whole offline path: us, to a real propagation node, to a recipient that syncs and enforces.
    @Test func aPropagatedMessageSurvivesTheRecipientsEnforcement() async throws {
        let port = nextPort()
        let hub = try Peer("hub", ["--listen", "\(port)", "--cost", "0", "--propagation-node"])
        defer { hub.stop() }
        let pn = try await hub.address("pn_address")
        let recipient = try Peer("recipient", ["--connect", "\(port)", "--announce-every", "3", "--sync-from", hub.pnAddressFile])
        defer { recipient.stop() }
        let dest = try await recipient.address()
        let node = try await LiveNode(port: port)
        defer { node.stop() }

        #expect(await node.hears(dest))
        #expect(await node.hears(pn, within: 90), "a node's first announce is delayed")
        node.store.send(.node(.setPropagationNode(destinationHash: pn)))
        node.store.send(.node(.sendViaPropagation(destinationHash: dest, title: Data(), content: Data("via the node".utf8))))
        let accepted = await poll(seconds: 150) { node.accepted.value > 0 ? true : nil }
        #expect(accepted == true, "the node must accept the propagation stamp")

        let log = try #require(await recipient.received(containing: "via the node", within: 60))
        #expect(log.contains("stamp_valid=True"))
        #expect(log.contains("method=3"), "3 is LXMessage.PROPAGATED")
    }
}
