import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// RNS 1.6.0 link-request stamps (Link.py:300-390). A destination that announced a link cost gets a
// LINKREQUEST whose ephemeral X25519 public key meets that cost over `destinationHash + ed25519Public`.

private let iface = InterfaceID("stamp-iface")
private let destHash = Data(repeating: 0x5A, count: 16)

@MainActor
private func makePlane(clock: TestClock<Duration> = TestClock()) -> TestStoreOf<LinkPlane> {
    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    return store
}

@MainActor
private func makeEndpoint(clock: TestClock<Duration> = TestClock()) -> TestStoreOf<TransportEndpoint> {
    let store = TestStore(initialState: TransportEndpoint.State()) { TransportEndpoint() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    return store
}

/// The next LINKREQUEST the plane transmits.
@MainActor
private func nextLinkRequest(_ store: TestStoreOf<LinkPlane>) async -> Packet? {
    let captured = LockIsolated<Data?>(nil)
    await store.receive({ action in
        guard case let .delegate(.transmit(_, raw)) = action,
              Packet(raw: raw)?.packetType == .linkRequest else { return false }
        captured.setValue(raw)
        return true
    }, timeout: .seconds(10))
    return captured.value.flatMap { Packet(raw: $0) }
}

private struct StampedCase: Decodable {
    let destination_hash: String
    let context_flag: Bool
    let payload: String
    let lr_cost: Double?

    var destinationHash: Data { Data(hexString: destination_hash)! }

    /// The announce as heard directly (HEADER_1) at `hops`.
    func raw(hops: UInt8) -> Data {
        try! Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                    destinationType: .single, context: .none, contextFlag: context_flag, hops: hops,
                    destinationHash: destinationHash, transportId: nil, payload: Data(hexString: payload)!).packed()
    }
}

/// Real RNS 1.6.0 `Destination._announce` packets: see
/// Tests/ReTiCATests/Vectors/generate_stamped_announce_packet_fixtures.py.
private func fixture(_ name: String) throws -> StampedCase {
    struct File: Decodable { let cases: [String: StampedCase] }
    let url = try #require(Bundle.module.url(forResource: "stamped_announce_packet_fixtures", withExtension: "json"))
    return try #require(try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases[name])
}

/// The link cost the endpoint handed the plane when it opened a link.
@MainActor
private func openedWithCost(_ store: TestStoreOf<TransportEndpoint>) async -> Double?? {
    let cost = LockIsolated<Double??>(nil)
    await store.receive({ action in
        guard case let .linkPlane(.openLink(_, _, _, _, _, linkCost)) = action else { return false }
        cost.setValue(.some(linkCost))
        return true
    }, timeout: .seconds(10))
    return cost.value
}

@Suite @MainActor struct LinkPlaneStampedRequestTests {
    @Test func aLinkToADestinationWithACostUsesAKeyMeetingIt() async throws {
        let store = makePlane()
        await store.send(.openLink(initiatorTo: Identity(), destinationHash: destHash,
                                   interfaceID: iface, relayNextHop: nil, linkCost: 10))
        #expect(store.state.stampingLinks.count == 1, "the search runs before any link exists")
        #expect(store.state.links.isEmpty, "no LinkSession, so no establishment timer, until the search ends")

        let request = try #require(await nextLinkRequest(store))
        let x25519Public = request.payload.prefix(32)
        let ed25519Public = request.payload.dropFirst(32).prefix(32)
        // A random key meets cost 10 one time in 1,024.
        #expect(NetworkStamp.isValid(stamp: Data(x25519Public), cost: 10, material: destHash + ed25519Public))
        #expect(store.state.stampingLinks.isEmpty)
        let link = try #require(store.state.links.first)
        #expect(link.ephemeral.publicKey == Data(request.payload.prefix(64)), "the link must hold the stamped key")
        #expect(link.ephemeral.privateKey != nil)
    }

    @Test func noCostMeansAnOrdinaryKeyAndNoSearch() async {
        for cost: Double? in [nil, 0] {
            let store = makePlane()
            await store.send(.openLink(initiatorTo: Identity(), destinationHash: destHash,
                                       interfaceID: iface, relayNextHop: nil, linkCost: cost))
            #expect(store.state.stampingLinks.isEmpty, "cost \(String(describing: cost)) must not search")
            #expect(store.state.links.count == 1, "cost \(String(describing: cost)) opens the link at once")
        }
    }

    @Test func aSearchThatTimesOutFailsTheLinkWithoutSendingARequest() async {
        let clock = TestClock()
        let store = makePlane(clock: clock)
        // Cost 20 takes about 2^20 keys, over a minute here: it cannot finish in this test.
        await store.send(.openLink(initiatorTo: Identity(), destinationHash: destHash,
                                   interfaceID: iface, relayNextHop: nil, linkCost: LinkPlane.maxLinkStampCost))
        #expect(store.state.stampingLinks.count == 1, "the ceiling itself is searched")
        await clock.advance(by: .seconds(14.9))
        #expect(store.state.stampingLinks.count == 1, "still searching before the timeout")
        #expect(store.state.links.isEmpty)
        await clock.advance(by: .seconds(0.1))
        await store.receive(.delegate(.linkFailed(destinationHash: destHash, reason: .stampFailure)), timeout: .seconds(5))
        #expect(store.state.stampingLinks.isEmpty)
        #expect(store.state.links.isEmpty, "no LinkSession means no LINKREQUEST was ever sent")
        store.exhaustivity = .on
        await store.finish()
    }

    @Test func aCostAboveTheCeilingFailsTheLinkWithoutSearching() async {
        let store = makePlane()
        await store.send(.openLink(initiatorTo: Identity(), destinationHash: destHash,
                                   interfaceID: iface, relayNextHop: nil,
                                   linkCost: LinkPlane.maxLinkStampCost + 0.25))
        #expect(store.state.stampingLinks.isEmpty, "no search above the ceiling")
        await store.receive(.delegate(.linkFailed(destinationHash: destHash, reason: .stampFailure)))
        #expect(store.state.links.isEmpty)
        store.exhaustivity = .on
        await store.finish()
    }

    @Test func stoppingTheEndpointCancelsTheSearch() async {
        let store = makeEndpoint()
        await store.send(.linkPlane(.openLink(initiatorTo: Identity(), destinationHash: destHash,
                                              interfaceID: iface, relayNextHop: nil,
                                              linkCost: LinkPlane.maxLinkStampCost)))
        #expect(store.state.linkPlane.stampingLinks.count == 1)
        await store.send(.stop)
        await store.receive(.delegate(.linkFailed(destinationHash: destHash, reason: .stampFailure)), timeout: .seconds(5))
        #expect(store.state.linkPlane.stampingLinks.isEmpty)
        #expect(store.state.linkPlane.links.isEmpty)
        // A search still running (cost 20, over a minute) would keep its effect alive past `finish`.
        store.exhaustivity = .on
        await store.finish()
    }

    /// Endpoint wiring: the cost an announce carried reaches the plane, and the request meets it.
    @Test func anAnnouncedLinkCostStampsTheEndpointsLinkRequest() async throws {
        let stamped = try fixture("stripped")
        let store = makeEndpoint()
        await store.send(.transport(.interfaceConnected(iface, .tcp)))
        await store.send(.transport(.received(iface, stamped.raw(hops: 1))))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.transport.knownDestinations[stamped.destinationHash]?.linkCost == 3.25)

        await store.send(.openLink(destinationHash: stamped.destinationHash))
        #expect(await openedWithCost(store) == .some(3.25))
        let captured = LockIsolated<Data?>(nil)
        await store.receive({ action in
            guard case let .linkPlane(.delegate(.transmit(_, raw))) = action,
                  Packet(raw: raw)?.packetType == .linkRequest else { return false }
            captured.setValue(raw)
            return true
        }, timeout: .seconds(10))
        let request = try #require(captured.value.flatMap { Packet(raw: $0) })
        #expect(NetworkStamp.isValid(stamp: Data(request.payload.prefix(32)), cost: 3.25,
                                     material: stamped.destinationHash + request.payload.dropFirst(32).prefix(32)))
    }

    /// Reference records `lr_cost` on every valid announce (`Identity.remember`), not only on one that
    /// wins the path. A cost raised in an announce that loses the path is the one a link must pay.
    @Test func aLinkCostRaisedInANonReplacingAnnounceIsUsed() async throws {
        let first = try fixture("stripped")     // cost 3.25
        let raised = try fixture("at_cap")      // same destination, same second, cost 100
        #expect(first.destinationHash == raised.destinationHash)
        #expect(raised.lr_cost == 100)
        let dest = first.destinationHash
        let store = makeEndpoint()
        await store.send(.transport(.interfaceConnected(iface, .tcp)))
        await store.send(.transport(.received(iface, first.raw(hops: 1))))
        await store.skipReceivedActions(strict: false)
        await store.send(.transport(.received(iface, raised.raw(hops: 4))))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.transport.learned[dest]?.hops == 1, "the raised announce must NOT replace the path")

        await store.send(.openLink(destinationHash: dest))
        #expect(await openedWithCost(store) == .some(100))
        await store.receive(.delegate(.linkFailed(destinationHash: dest, reason: .stampFailure)), timeout: .seconds(5))
        #expect(store.state.linkPlane.links.isEmpty, "a stale 3.25 would have opened a link")
    }

    /// No packet left the node, so the path is not in question: retry the link, do not request a path.
    @Test func aStampFailureRetriesTheLinkNotThePath() async {
        let dest = LXMessage.deliveryHash(identityHash: Identity().hash)
        let me = Identity()
        var initial = LXMFNode.State(identity: me, endpoint: TCPEndpoint.State(host: "a", port: 4242, reconnectOnDrop: false))
        initial.router.knownPaths.insert(dest)
        initial.router.outboundQueue[dest] = [LXMessage.create(source: me, destinationHash: dest, timestamp: 1700000000.5,
                                                               title: Data("t".utf8), content: Data("c".utf8))]
        let store = TestStore(initialState: initial) { LXMFNode() } withDependencies: {
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
            $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        }
        store.exhaustivity = .off

        await store.send(.endpoint(.delegate(.linkFailed(destinationHash: dest, reason: .stampFailure))))
        await store.receive { action in
            if case .router(.delegate(.requestLink(let d))) = action { return d == dest }
            return false
        }
        #expect(store.state.router.knownPaths.contains(dest), "a stamp failure says nothing about the path")
        #expect(store.state.router.directLinks[dest] == .establishing)
    }
}
