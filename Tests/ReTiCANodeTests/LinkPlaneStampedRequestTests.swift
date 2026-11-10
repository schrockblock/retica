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

/// TransportEndpoint, recording the public key of every key search that finishes (each ends in
/// `.stampedKeyFound`).
private struct FoundKeyCountingEndpoint: Reducer {
    typealias State = TransportEndpoint.State
    typealias Action = TransportEndpoint.Action
    let found: LockIsolated<[Data]>

    var body: some ReducerOf<Self> {
        Reduce { _, action in
            if case let .linkPlane(.stampedKeyFound(_, _, publicKey)) = action { found.withValue { $0.append(publicKey) } }
            return .none
        }
        TransportEndpoint()
    }
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
        for cost: Double? in [nil, 0, -1, .nan] {
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
        // `advance` wakes only sleeps already registered: let the search's timeout sleep register.
        await Task.megaYield()
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
        // `.pathStale`, not `.stampFailure`: the interface is going away, and LXMFNode answers a stamp
        // failure by retrying the link at once, which would start a new search on a stopping endpoint.
        await store.receive(.delegate(.linkFailed(destinationHash: destHash, reason: .pathStale)), timeout: .seconds(5))
        #expect(store.state.linkPlane.stampingLinks.isEmpty)
        #expect(store.state.linkPlane.links.isEmpty)
        // A search still running (cost 20, over a minute) would keep its effect alive past `finish`.
        store.exhaustivity = .on
        await store.finish()
    }

    /// A path-request stamp search is CPU work too, so stopping the endpoint must end it.
    @Test func stoppingTheEndpointCancelsAPathRequestStampSearch() async {
        var initial = TransportEndpoint.State()
        initial.transport.stampPathRequests = true
        initial.transport.pathRequestValue = 100      // cannot finish here
        let stopping = TestStore(initialState: initial) { TransportEndpoint() } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 0))
        }
        stopping.exhaustivity = .off
        // A search needs an interface to send on.
        await stopping.send(.transport(.interfaceConnected(InterfaceID("i0"), .default)))
        await stopping.send(.requestPath(destinationHash: destHash))
        await stopping.receive(.transport(.requestPath(destinationHash: destHash)))
        #expect(Set(stopping.state.transport.stampingPathRequests.keys) == [destHash])
        await stopping.send(.stop)
        await stopping.skipReceivedActions(strict: false)
        #expect(stopping.state.transport.stampingPathRequests.isEmpty)
        // A search still running (cost 100) would keep its effect alive past `finish`.
        stopping.exhaustivity = .on
        await stopping.finish()
    }

    /// Endpoint wiring: the cost an announce carried reaches the plane, and the request meets it.
    @Test func anAnnouncedLinkCostStampsTheEndpointsLinkRequest() async throws {
        let stamped = try fixture("stripped")
        // Cost 3.25 is met by a random key about one time in ten, so `isValid` alone cannot show a
        // search ran. A found key arrives as `.stampedKeyFound`, which only the search produces.
        let found = LockIsolated<[Data]>([])
        let store = TestStore(initialState: TransportEndpoint.State()) {
            FoundKeyCountingEndpoint(found: found)
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 0))
        }
        store.exhaustivity = .off
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
        #expect(found.value.count == 1, "the key must come from the search")
        #expect(found.value.first == Data(request.payload.prefix(32)), "the request carries the key the search found")
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

    /// A search is bound to the interface its link would ride. When that interface goes, the search
    /// is cancelled and its link fails at once, rather than minting a link on a dead interface when
    /// the search ends. Searches on other interfaces are untouched.
    @Test func aSearchWhoseInterfaceDisconnectsIsCancelled() async {
        let other = InterfaceID("other-iface")
        let otherDest = Data(repeating: 0x6B, count: 16)
        let store = makePlane()
        await store.send(.openLink(initiatorTo: Identity(), destinationHash: destHash, interfaceID: iface,
                                   relayNextHop: nil, linkCost: LinkPlane.maxLinkStampCost))
        await store.send(.openLink(initiatorTo: Identity(), destinationHash: otherDest, interfaceID: other,
                                   relayNextHop: nil, linkCost: LinkPlane.maxLinkStampCost))
        #expect(store.state.stampingLinks.count == 2)

        await store.send(.interfaceDisconnected(iface))
        #expect(store.state.stampingLinks.map(\.destinationHash) == [otherDest], "only the gone interface's search ends")
        await store.receive(.delegate(.linkFailed(destinationHash: destHash, reason: .pathStale)), timeout: .seconds(5))
        #expect(store.state.links.isEmpty)

        // The other search is still running: end it, then prove nothing at all is left running.
        await store.send(.cancelStampSearches)
        await store.receive(.delegate(.linkFailed(destinationHash: otherDest, reason: .pathStale)), timeout: .seconds(5))
        store.exhaustivity = .on
        await store.finish()
    }
}

// MARK: - Stopping an LXMFNode with a message queued behind a key search

/// LXMFNode, counting every link the endpoint opens with a stamp cost (each one starts a key search).
private struct SearchCountingNode: Reducer {
    typealias State = LXMFNode.State
    typealias Action = LXMFNode.Action
    let searches: LockIsolated<Int>
    /// Searches that reported back (found a key or timed out). A cancelled search reports nothing, so
    /// one that is still running after its link failed shows up here when the clock runs it out.
    let ended: LockIsolated<Int>
    /// LINKREQUEST packets the link plane transmitted.
    let linkRequests: LockIsolated<Int>

    var body: some ReducerOf<Self> {
        Reduce { _, action in
            if case let .endpoint(.linkPlane(.delegate(.transmit(_, raw)))) = action,
               Packet(raw: raw)?.packetType == .linkRequest {
                linkRequests.withValue { $0 += 1 }
            }
            if case let .endpoint(.linkPlane(.openLink(_, _, _, _, _, cost))) = action, let cost, cost > 0 {
                searches.withValue { $0 += 1 }
            }
            switch action {
            case .endpoint(.linkPlane(.stampedKeyFound)), .endpoint(.linkPlane(.stampSearchTimedOut)):
                ended.withValue { $0 += 1 }
            default: break
            }
            return .none
        }
        LXMFNode()
    }
}

/// With `interfaceID` up: hear an lxmf.delivery destination announcing link cost 20 (a search that
/// cannot finish here), queue a direct message to it, let the search start, then stop the endpoint.
/// After the interface has gone, no search may be running and none may have started after the stop.
@MainActor
private func stopWithASearchRunning(_ store: TestStore<LXMFNode.State, LXMFNode.Action>,
                                    searches: LockIsolated<Int>, ended: LockIsolated<Int>,
                                    linkRequests: LockIsolated<Int>, interfaceID: InterfaceID,
                                    clock: TestClock<Duration>, endDriverEvents: () -> Void) async throws {
    let peer = try fixture("lxmf_delivery_cost_20")
    await store.send(.endpoint(.transport(.received(interfaceID, peer.raw(hops: 1)))))
    await store.receive({ if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false },
                        timeout: .seconds(5))
    #expect(store.state.endpoint.knownDestinations[peer.destinationHash]?.linkCost == 20)

    await store.send(.send(destinationHash: peer.destinationHash, title: Data("t".utf8),
                           content: Data("queued behind a search".utf8), method: .direct))
    await store.receive({ if case .endpoint(.linkPlane(.openLink)) = $0 { return true }; return false },
                        timeout: .seconds(5))
    #expect(store.state.endpoint.linkPlane.stampingLinks.count == 1, "the search must be running before the stop")
    #expect(searches.value == 1)

    await store.send(.endpoint(.stop))
    await store.receive({ if case .endpoint(.transport(.interfaceDisconnected(interfaceID))) = $0 { return true }; return false },
                        timeout: .seconds(5))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.endpoint.linkPlane.stampingLinks.isEmpty, "no search may outlive the stop")
    #expect(searches.value == 1, "no search may start after the stop")
    #expect(store.state.endpoint.linkPlane.links.isEmpty, "no link may be opened after the stop")
    // Two other effects outlive the stop and are not the search: the driver's event stream (the test
    // owns it, so end it) and the router's timers on this TestClock (run them out). If running them
    // out starts a search, that is a search the stop failed to prevent.
    endDriverEvents()
    await clock.advance(by: .seconds(3600))
    await store.skipReceivedActions(strict: false)
    #expect(searches.value == 1, "no search may start once the timers have run")
    #expect(store.state.endpoint.linkPlane.stampingLinks.isEmpty)
    #expect(store.state.endpoint.linkPlane.links.isEmpty, "no link may appear once the timers have run")
    #expect(linkRequests.value == 0, "no LINKREQUEST may be transmitted: the search was cancelled before it found a key")
    #expect(ended.value == 0, "the search was cancelled, not left to run out its timeout")
    // A search still running (cost 20, over a minute) would keep its effect alive past `finish`.
    store.exhaustivity = .on
    await store.finish()
}

@Suite @MainActor struct StoppingAStampSearchTests {
    @Test func aTCPClientStopEndsTheSearchAndStartsNoOther() async throws {
        let searches = LockIsolated(0)
        let ended = LockIsolated(0)
        let linkRequests = LockIsolated(0)
        let clock = TestClock()
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: LXMFNode.State(
            identity: Identity(), endpoint: TCPEndpoint.State(host: "a", port: 4242, reconnectOnDrop: false))) {
            SearchCountingNode(searches: searches, ended: ended, linkRequests: linkRequests)
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream }, send: { _ in }, close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        await store.send(.endpoint(.start))
        events.continuation.yield(.connected)
        await store.receive({ if case .endpoint(.transport(.interfaceConnected)) = $0 { return true }; return false },
                            timeout: .seconds(5))
        let id = try #require(store.state.endpoint.transport.interfaces.keys.first)
        try await stopWithASearchRunning(store, searches: searches, ended: ended, linkRequests: linkRequests, interfaceID: id, clock: clock) { events.continuation.finish() }
    }

    @Test func aBLEStopEndsTheSearchAndStartsNoOther() async throws {
        let searches = LockIsolated(0)
        let ended = LockIsolated(0)
        let linkRequests = LockIsolated(0)
        let clock = TestClock()
        let events = AsyncStream<BLEDriverEvent>.makeStream()
        let store = TestStore(initialState: LXMFNode.State(
            identity: Identity(), endpoint: BLEEndpoint.State(localIdentity: Data(repeating: 0x5A, count: 16)))) {
            SearchCountingNode(searches: searches, ended: ended, linkRequests: linkRequests)
        } withDependencies: {
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000.5))
            $0.uuid = .incrementing
            $0.bleDriver = BLEDriver(start: { _ in events.stream }, readIdentity: { _ in }, openChannel: { _ in },
                                     send: { _, _ in }, closeChannel: { _ in }, stop: { })
        }
        store.exhaustivity = .off
        await store.send(.endpoint(.start))
        events.continuation.yield(.ready)
        let channel = BLEChannelID(id: UUID(uuidString: "11111111-0000-0000-0000-0000000000F1")!)
        let handle = BLEPeerHandle(id: UUID(uuidString: "22222222-0000-0000-0000-0000000000F2")!)
        events.continuation.yield(.channelOpened(channel, handle, direction: .inbound, mtu: 512))
        events.continuation.yield(.channelData(channel, Data(repeating: 0xC7, count: 16)))
        await store.receive({ if case .endpoint(.transport(.interfaceConnected)) = $0 { return true }; return false },
                            timeout: .seconds(5))
        let id = try #require(store.state.endpoint.transport.interfaces.keys.first)
        try await stopWithASearchRunning(store, searches: searches, ended: ended, linkRequests: linkRequests, interfaceID: id, clock: clock) { events.continuation.finish() }
    }

    @Test func aTCPServerStopEndsTheSearchAndStartsNoOther() async throws {
        let searches = LockIsolated(0)
        let ended = LockIsolated(0)
        let linkRequests = LockIsolated(0)
        let clock = TestClock()
        let events = AsyncStream<TCPListenerEvent>.makeStream()
        let store = TestStore(initialState: LXMFNode.State(
            identity: Identity(), endpoint: TransportEndpoint.State.tcpServer(TCPServerEndpoint.State(port: 4242, profile: .tcp)))) {
            SearchCountingNode(searches: searches, ended: ended, linkRequests: linkRequests)
        } withDependencies: {
            $0.tcpListener = TCPListener(listen: { _ in events.stream }, send: { _, _ in }, close: { _ in }, stop: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        await store.send(.endpoint(.start))
        events.continuation.yield(.started)
        events.continuation.yield(.accepted(TCPConnID(1)))
        // Poll rather than `receive`: this store is non-exhaustive, so a `receive` predicate cannot
        // see the actions an earlier `send` skipped, and it timed out here although the connection
        // was accepted.
        for _ in 0..<500 where store.state.endpoint.transport.interfaces.isEmpty {
            await store.skipReceivedActions(strict: false)
            try await Task.sleep(for: .milliseconds(10))
        }
        let id = try #require(store.state.endpoint.transport.interfaces.keys.first)
        try await stopWithASearchRunning(store, searches: searches, ended: ended, linkRequests: linkRequests, interfaceID: id,
                                         clock: clock) { events.continuation.finish() }
    }

    /// The radio reports offline only after `driver.stop()` returns, so its interface outlives the
    /// endpoint's `.stop` by at least one effect hop.
    @Test func aMeshtasticStopEndsTheSearchAndStartsNoOther() async throws {
        let searches = LockIsolated(0)
        let ended = LockIsolated(0)
        let linkRequests = LockIsolated(0)
        let clock = TestClock()
        let radio = AsyncStream<MeshtasticDriverEvent>.makeStream()
        let endpoint = TransportEndpoint.State.meshtastic(MeshtasticEndpoint.State(
            config: MeshtasticDriverConfig(radio: UUID(uuidString: "0000AAAA-0000-0000-0000-0000000000F3")!),
            profile: .meshtastic(modemPreset: nil)))
        let store = TestStore(initialState: LXMFNode.State(identity: Identity(), endpoint: endpoint)) {
            SearchCountingNode(searches: searches, ended: ended, linkRequests: linkRequests)
        } withDependencies: {
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000.5))
            $0.uuid = .incrementing
            $0.meshtasticClock = ImmediateClock()
            $0.meshtasticDriver = MeshtasticDriver(start: { _ in radio.stream }, send: { _ in true }, stop: { })
        }
        store.exhaustivity = .off
        await store.send(.endpoint(.start))
        radio.continuation.yield(.connected(myNodeNum: 0xA1A1_A1A1, modemPreset: 8))
        await store.receive({ if case .endpoint(.transport(.interfaceConnected)) = $0 { return true }; return false },
                            timeout: .seconds(5))
        let id = try #require(store.state.endpoint.transport.interfaces.keys.first)
        try await stopWithASearchRunning(store, searches: searches, ended: ended, linkRequests: linkRequests, interfaceID: id, clock: clock) { radio.continuation.finish() }
    }
}

// MARK: - Abandoning a search the router no longer needs

private let otherDest = Data(repeating: 0x6B, count: 16)

/// Advance `clock` by the key-search timeout until `searching()` is false. One advance is not
/// enough under load: it wakes only sleeps already registered, and the search's timeout sleep may
/// not be yet (seen once in the full parallel suite).
@MainActor
private func runSearchOut(_ clock: TestClock<Duration>, while searching: () -> Bool) async throws {
    for _ in 0..<200 where searching() {
        await clock.advance(by: .seconds(NetworkStamp.linkStampTimeout))
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// A router whose link to `destHash` is establishing, with `queued` queued behind it.
@MainActor
private func establishingRouter(_ queued: [LXMessage]) async -> (TestStore<LXMFRouter.State, LXMFRouter.Action>,
                                                                  LockIsolated<Int>) {
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(destHash)
    let abandons = LockIsolated(0)
    let store = TestStore(initialState: initial) {
        CombineReducers {
            Reduce<LXMFRouter.State, LXMFRouter.Action> { _, action in
                if case .delegate(.abandonLink(destHash)) = action { abandons.withValue { $0 += 1 } }
                return .none
            }
            LXMFRouter()
        }
    } withDependencies: { $0.continuousClock = TestClock() }
    store.exhaustivity = .off
    for message in queued { await store.send(.send(message: message, desiredMethod: .direct)) }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.directLinks[destHash] == .establishing)
    return (store, abandons)
}

private func directNote(_ text: String) -> LXMessage {
    LXMessage.create(source: Identity(), destinationHash: destHash, timestamp: 1700000000.5,
                     title: Data("t".utf8), content: Data(text.utf8))
}

@Suite @MainActor struct LinkStampSearchBoundsTests {
    /// Abandoned: the search is dropped and its effect cancelled, and nothing at all is reported, not
    /// even when its timeout would have fired. Another destination's search runs on.
    @Test func anAbandonedSearchReportsNothingAndStops() async throws {
        let clock = TestClock()
        let store = makePlane(clock: clock)
        await store.send(.openLink(initiatorTo: Identity(), destinationHash: destHash, interfaceID: iface,
                                   relayNextHop: nil, linkCost: LinkPlane.maxLinkStampCost))
        await store.send(.openLink(initiatorTo: Identity(), destinationHash: otherDest, interfaceID: iface,
                                   relayNextHop: nil, linkCost: LinkPlane.maxLinkStampCost))
        #expect(store.state.stampingLinks.ids == [UUID(0), UUID(1)])

        // Exhaustive from here: any action the abandoned search sent would fail the test.
        store.exhaustivity = .on
        await store.send(.abandonStampSearches(destinationHash: destHash)) {
            $0.stampingLinks.remove(id: UUID(0))
        }
        try await runSearchOut(clock) { store.state.stampingLinks[id: UUID(1)] != nil }
        await store.receive(.stampSearchTimedOut(id: UUID(1)), timeout: .seconds(5)) {
            $0.stampingLinks.remove(id: UUID(1))
        }
        await store.receive(.delegate(.linkFailed(destinationHash: otherDest, reason: .stampFailure)))
        // A search still running (cost 20, over a minute) would keep its effect alive past `finish`.
        await store.finish()
    }

    /// Searches are independent random trials, so a failed one says nothing about the next: a second
    /// `openLink` at the same cost right after a `.stampFailure` searches again, as reference does.
    @Test func aSearchAfterAFailedOneAtTheSameCostSearchesAgain() async throws {
        let clock = TestClock()
        let store = makePlane(clock: clock)
        await store.send(.openLink(initiatorTo: Identity(), destinationHash: destHash, interfaceID: iface,
                                   relayNextHop: nil, linkCost: LinkPlane.maxLinkStampCost))
        try await runSearchOut(clock) { !store.state.stampingLinks.isEmpty }
        await store.receive(.delegate(.linkFailed(destinationHash: destHash, reason: .stampFailure)), timeout: .seconds(5))

        await store.send(.openLink(initiatorTo: Identity(), destinationHash: destHash, interfaceID: iface,
                                   relayNextHop: nil, linkCost: LinkPlane.maxLinkStampCost))
        #expect(store.state.stampingLinks.count == 1, "the retry must search")
        await store.send(.abandonStampSearches(destinationHash: destHash))
        store.exhaustivity = .on
        await store.finish()
    }

    /// The router abandons an establishing link when its last queued message is cancelled, not before,
    /// and stays `.establishing` (the link's outcome may still come).
    @Test func routerAbandonsAnEstablishingLinkWhenItsLastMessageIsCancelled() async {
        let first = directNote("one"), second = directNote("two")
        let (store, abandons) = await establishingRouter([first, second])
        await store.send(.cancelOutbound(messageHash: first.hash))
        await store.skipReceivedActions(strict: false)
        #expect(abandons.value == 0, "a message still needs the link")
        await store.send(.cancelOutbound(messageHash: second.hash))
        await store.skipReceivedActions(strict: false)
        #expect(abandons.value == 1)
        #expect(store.state.directLinks[destHash] == .establishing)
    }

    /// A copy withdrawn to be re-stamped still needs the link: cancelling another message does not
    /// abandon it. Cancelling the withdrawn copy, its last work, does.
    @Test func routerAbandonsAnEstablishingLinkWhenAWithdrawnCopyIsCancelled() async {
        let withdrawn = directNote("re-stamped"), other = directNote("other")
        let (store, abandons) = await establishingRouter([withdrawn, other])
        await store.send(.withdrawUnsentDeliveryCopy(messageHash: withdrawn.hash))
        await store.send(.cancelOutbound(messageHash: other.hash))
        await store.skipReceivedActions(strict: false)
        #expect(abandons.value == 0, "the withdrawn copy comes back for this link")
        await store.send(.cancelOutbound(messageHash: withdrawn.hash))
        await store.skipReceivedActions(strict: false)
        #expect(abandons.value == 1)
    }

    /// `.cancelDeliveryStamps` reclaiming a withdrawn copy (`.deliveryCopyAbandoned`) that was the
    /// link's last work abandons the link.
    @Test func routerAbandonsAnEstablishingLinkWhenAWithdrawnCopyIsReclaimed() async {
        let withdrawn = directNote("re-stamped")
        let (store, abandons) = await establishingRouter([withdrawn])
        await store.send(.withdrawUnsentDeliveryCopy(messageHash: withdrawn.hash))
        await store.skipReceivedActions(strict: false)
        #expect(abandons.value == 0)
        await store.send(.deliveryCopyAbandoned(messageHash: withdrawn.hash))
        await store.skipReceivedActions(strict: false)
        #expect(abandons.value == 1)
    }

    /// The router abandons an establishing link when the last copy waiting for it fails.
    @Test func routerAbandonsAnEstablishingLinkWhenItsLastCopyFails() async {
        let hash = Data(repeating: 0x11, count: 32)
        var initial = LXMFRouter.State()
        initial.knownPaths.insert(destHash)
        initial.directLinks[destHash] = .establishing
        initial.pendingDeliveries[.delivery(hash)] = LXMFRouter.PendingDelivery(
            resend: .direct(destinationHash: destHash, data: Data("m".utf8), asResource: false),
            attempts: LXMFDelivery.maxAttempts)
        let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: { $0.continuousClock = TestClock() }
        store.exhaustivity = .off
        await store.send(.retryDue(messageHash: hash, leg: .delivery))
        await store.receive(.delegate(.abandonLink(destinationHash: destHash)))
        #expect(store.state.pendingDeliveries.isEmpty)
    }

    /// A confirmed delivery copy drops its unsent propagated copy; if that was all the propagation
    /// node's establishing link was for, the link is abandoned.
    @Test func routerAbandonsAnEstablishingLinkADeliverySuccessMadeUnnecessary() async {
        let hash = Data(repeating: 0x22, count: 32)
        var initial = LXMFRouter.State()
        initial.outboundPropagationNode = otherDest
        initial.directLinks[otherDest] = .establishing
        initial.propagationQueue[otherDest] = [LXMFRouter.PropagationItem(messageHash: hash, propagationPacked: Data("p".utf8))]
        initial.pendingDeliveries[.delivery(hash)] = LXMFRouter.PendingDelivery(
            resend: .opportunistic(destinationHash: destHash, payload: Data("m".utf8)), attempts: 1)
        let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: { $0.continuousClock = TestClock() }
        store.exhaustivity = .off
        await store.send(.opportunisticDelivered(messageHash: hash))
        await store.receive(.delegate(.abandonLink(destinationHash: otherDest)))
        #expect(store.state.propagationQueue[otherDest] == nil)
    }

    /// A late proof for a direct copy still retrying while its link re-establishes settles the last
    /// work for that link: it is abandoned.
    @Test func routerAbandonsAnEstablishingLinkWhenItsLastCopySucceeds() async {
        let hash = Data(repeating: 0x33, count: 32)
        var initial = LXMFRouter.State()
        initial.knownPaths.insert(destHash)
        initial.directLinks[destHash] = .establishing
        initial.pendingDeliveries[.delivery(hash)] = LXMFRouter.PendingDelivery(
            resend: .direct(destinationHash: destHash, data: Data("m".utf8), asResource: false), attempts: 2)
        let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: { $0.continuousClock = TestClock() }
        store.exhaustivity = .off
        await store.send(.delivered(messageHash: hash, leg: .delivery))
        await store.receive(.delegate(.abandonLink(destinationHash: destHash)))
    }

    /// After an abandon the router is still `.establishing`, so a new message queues. When the host
    /// then reports the link closed (as `LXMFNode` does after cancelling the search), the router
    /// re-establishes for it.
    @Test func routerReestablishesWhenWorkArrivesBetweenAbandonAndClose() async {
        let first = directNote("one"), later = directNote("later")
        let (store, abandons) = await establishingRouter([first])
        await store.send(.cancelOutbound(messageHash: first.hash))
        await store.skipReceivedActions(strict: false)
        #expect(abandons.value == 1)
        await store.send(.send(message: later, desiredMethod: .direct))
        #expect(store.state.outboundQueue[destHash]?.map(\.hash) == [later.hash])
        await store.send(.linkClosed(destinationHash: destHash))
        await store.receive(.delegate(.requestLink(destinationHash: destHash)))
        #expect(store.state.directLinks[destHash] == .establishing)
    }
}

/// LXMFNode, counting key searches started (distinct searching links seen), searches that reported
/// back, every link failure the endpoint reported, and every message reported failed.
private struct SearchLifecycleNode: Reducer {
    typealias State = LXMFNode.State
    typealias Action = LXMFNode.Action
    let seen = LockIsolated<Set<UUID>>([])
    let ended = LockIsolated(0)
    let failures = LockIsolated<[LinkFailure]>([])
    let failedMessages = LockIsolated<[Data]>([])
    var started: Int { seen.value.count }

    var body: some ReducerOf<Self> {
        LXMFNode()
        Reduce { state, action in
            let ids = state.endpoint.linkPlane.stampingLinks.ids
            seen.withValue { $0.formUnion(ids) }
            switch action {
            case .endpoint(.linkPlane(.stampedKeyFound)), .endpoint(.linkPlane(.stampSearchTimedOut)):
                ended.withValue { $0 += 1 }
            case let .endpoint(.delegate(.linkFailed(_, reason))):
                failures.withValue { $0.append(reason) }
            case let .delegate(.deliveryFailed(hash)):
                failedMessages.withValue { $0.append(hash) }
            default: break
            }
            return .none
        }
    }
}

/// A connected TCP-client LXMFNode that has heard an lxmf.delivery destination announcing link cost
/// 20 (a search that cannot finish here) and queued one direct message to it, whose key search is
/// running. Returns the destination and the message hash.
@MainActor
private func nodeSearchingForAKey(_ counter: SearchLifecycleNode, clock: TestClock<Duration>,
                                  events: (stream: AsyncStream<TCPEvent>, continuation: AsyncStream<TCPEvent>.Continuation))
    async throws -> (TestStore<LXMFNode.State, LXMFNode.Action>, dest: Data, message: Data) {
    let store = TestStore(initialState: LXMFNode.State(
        identity: Identity(), endpoint: TCPEndpoint.State(host: "a", port: 4242, reconnectOnDrop: false))) {
        counter
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in events.stream }, send: { _ in }, close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000.5))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.endpoint(.start))
    events.continuation.yield(.connected)
    await store.receive({ if case .endpoint(.transport(.interfaceConnected)) = $0 { return true }; return false },
                        timeout: .seconds(5))
    let id = try #require(store.state.endpoint.transport.interfaces.keys.first)
    let peer = try fixture("lxmf_delivery_cost_20")
    await store.send(.endpoint(.transport(.received(id, peer.raw(hops: 1)))))
    await store.receive({ if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false },
                        timeout: .seconds(5))
    await store.send(.send(destinationHash: peer.destinationHash, title: Data("t".utf8),
                           content: Data("behind a search".utf8), method: .direct))
    await store.receive({ if case .endpoint(.linkPlane(.openLink)) = $0 { return true }; return false },
                        timeout: .seconds(5))
    #expect(store.state.endpoint.linkPlane.stampingLinks.count == 1, "the search must be running")
    let message = try #require(store.state.router.outboundQueue[peer.destinationHash]?.first?.hash)
    return (store, peer.destinationHash, message)
}

@Suite @MainActor struct LXMFNodeLinkStampSearchBoundsTests {
    /// Cancelling the only message that needed the link stops its key search, silently: no link
    /// failure is reported, the search never reports back, and no other search starts.
    @Test func cancellingTheOnlyMessageStopsItsLinksSearchSilently() async throws {
        let counter = SearchLifecycleNode()
        let clock = TestClock()
        let events = AsyncStream<TCPEvent>.makeStream()
        let (store, dest, message) = try await nodeSearchingForAKey(counter, clock: clock, events: events)

        await store.send(.cancelOutbound(messageHash: message))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.endpoint.linkPlane.stampingLinks.isEmpty, "the search must be cancelled")
        #expect(store.state.router.directLinks[dest] == nil, "the router must no longer wait for the link")
        #expect(counter.failures.value.isEmpty, "an abandoned search reports no link failure")

        events.continuation.finish()
        await clock.advance(by: .seconds(3600))
        await store.skipReceivedActions(strict: false)
        #expect(counter.ended.value == 0, "the search was cancelled, not left to run out its timeout")
        #expect(counter.started == 1, "no search may start after the cancel")
        #expect(counter.failures.value.isEmpty)
        store.exhaustivity = .on
        await store.finish()
    }

    /// After a search times out the router retries the link at once, and each retry searches afresh
    /// (searches are independent random trials; reference searches again per attempt too). A full
    /// saga is `maxAttempts` searches, each run out to its timeout, then the message fails.
    @Test func aRouterRetryAfterAStampFailureStartsAFreshSearch() async throws {
        let counter = SearchLifecycleNode()
        let clock = TestClock()
        let events = AsyncStream<TCPEvent>.makeStream()
        let (store, dest, message) = try await nodeSearchingForAKey(counter, clock: clock, events: events)

        for attempt in 1...LXMFDelivery.maxAttempts {
            #expect(counter.started == attempt, "attempt \(attempt) must run its own search")
            try await runSearchOut(clock) { counter.ended.value < attempt }
            await store.skipReceivedActions(strict: false)
        }
        // Counted, not `receive`d: the last skip above has already consumed it.
        #expect(counter.failedMessages.value == [message])
        #expect(counter.started == LXMFDelivery.maxAttempts)
        #expect(counter.ended.value == LXMFDelivery.maxAttempts)
        #expect(counter.failures.value == Array(repeating: .stampFailure, count: LXMFDelivery.maxAttempts))
        #expect(store.state.endpoint.linkPlane.stampingLinks.isEmpty)
        #expect(store.state.router.directLinks[dest] == nil)

        events.continuation.finish()
        await clock.advance(by: .seconds(3600))
        await store.skipReceivedActions(strict: false)
        #expect(counter.started == LXMFDelivery.maxAttempts, "nothing searches after the router gives up")
        store.exhaustivity = .on
        await store.finish()
    }
}

/// This target's copy of the stamped-announce fixtures must be byte-identical to the ReTiCATests copy,
/// which the one generator writes. A regeneration that misses a copy fails here.
@Test func theStampedAnnounceFixtureMatchesTheReTiCATestsCopy() throws {
    let here = try #require(Bundle.module.url(forResource: "stamped_announce_packet_fixtures", withExtension: "json"))
    let reference = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/ReTiCANodeTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("ReTiCATests/Vectors/stamped_announce_packet_fixtures.json")
    let ours = try Data(contentsOf: here)
    let theirs = try Data(contentsOf: reference)
    #expect(!theirs.isEmpty)
    #expect(ours == theirs)
}
