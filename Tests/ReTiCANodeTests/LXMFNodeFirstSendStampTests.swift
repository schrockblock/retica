import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

// A first message to someone we have never heard from.
//
// The cost a peer requires arrives in the same announce that gives us a path to it. Reading the cost
// at send time, before that announce, means sending unstamped to a peer that may enforce stamps, and
// MeshChatX enforces by default. The peer proves the packet before checking the stamp
// (LXMRouter.py:2263, LXMF 1.3.0), so we would report it delivered as well.
//
// Reference has this gap: `handle_outbound` reads the cost once (LXMRouter.py:2080-2084). Deliberate
// divergence: we wait for the path first. Observed live against a reference LXMF 1.3.0 router.

private let iface = InterfaceID("first-send-iface")
private let sentAt: TimeInterval = 1700000000.5
/// MeshChatX's default. A real search stays quick, and random bytes pass only 1 time in 256.
private let cheapCost = 8

/// Counted in a reducer: with exhaustivity off, `store.send` skips actions before a later `receive`
/// predicate could see them.
private struct PathRequestCountingNode: Reducer {
    typealias State = LXMFNode.State
    typealias Action = LXMFNode.Action
    let pathRequests: LockIsolated<Int>

    var body: some Reducer<State, Action> {
        Reduce { _, action in
            if case .endpoint(.requestPath) = action { pathRequests.withValue { $0 += 1 } }
            return .none
        }
        LXMFNode()
    }
}

@MainActor
private func makeNode(_ identity: Identity, _ clock: TestClock<Duration>,
                      countingPathRequestsIn pathRequests: LockIsolated<Int> = LockIsolated(0)) async -> TestStoreOf<LXMFNode> {
    let store = TestStore(initialState: LXMFNode.State(identity: identity, endpoint: TransportEndpoint.State())) {
        PathRequestCountingNode(pathRequests: pathRequests)
    } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: sentAt))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.endpoint(.transport(.interfaceConnected(iface, .tcp))))
    return store
}

private func deliveryAnnounce(of peer: Identity, stampCost: Int?) -> Data {
    let dest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                           aspects: LXMessage.deliveryAspects, identity: peer)!
    let randomHash = Announce.randomHash(now: 1_700_000_000, randomPrefix: Data(repeating: 0x02, count: 5))
    let payload = Announce.buildPayload(identity: peer, destinationHash: dest.hash, nameHash: dest.nameHash,
                                        randomHash: randomHash,
                                        appData: LXMFAnnounceData.pack(displayName: "Peer", stampCost: stampCost))
    return try! Packet.announce(from: dest, payload: payload).packed()
}

private func message(from me: Identity, to peer: Identity, _ text: String = "hi") -> LXMessage {
    LXMessage.create(source: me, destinationHash: LXMessage.deliveryHash(identityHash: peer.hash), timestamp: sentAt,
                     title: Data(), content: Data(text.utf8))
}

/// The next message handed to the router. The assertions are on this, not on state, so a stamp
/// computed and then dropped on the way cannot pass.
@MainActor
private func nextHandedToRouter(_ store: TestStoreOf<LXMFNode>) async -> LXMessage? {
    let captured = LockIsolated<LXMessage?>(nil)
    await store.receive({ action in
        guard case let .router(.send(m, _)) = action else { return false }
        captured.setValue(m)
        return true
    }, timeout: .seconds(30))
    return captured.value
}

@MainActor
private func isHandedOver(_ store: TestStoreOf<LXMFNode>, _ m: LXMessage) async -> Bool {
    await store.skipReceivedActions(strict: false)
    return store.state.router.hasOutboundState(for: m.hash)
}

@Suite @MainActor struct LXMFNodeFirstSendStampTests {
    @Test func aFirstSendWaitsForThePeersCostAndCarriesAValidStamp() async throws {
        let me = Identity(), peer = Identity()
        let store = await makeNode(me, TestClock())
        let m = message(from: me, to: peer)

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        #expect(await isHandedOver(store, m) == false, "no stamp exists yet, so it must not go out")

        await store.send(.endpoint(.transport(.received(iface, deliveryAnnounce(of: peer, stampCost: cheapCost)))))
        let handed = try #require(await nextHandedToRouter(store))
        #expect(handed.hash == m.hash)
        #expect(handed.stamp != nil)
        #expect(handed.validateStamp(targetCost: cheapCost))
    }

    @Test func aFirstSendRequestsAPathWhileItWaits() async {
        let me = Identity(), peer = Identity()
        let store = await makeNode(me, TestClock())
        await store.send(.sendMessage(message: message(from: me, to: peer), fallbackToPropagation: false))
        let dest = LXMessage.deliveryHash(identityHash: peer.hash)
        await store.receive { action in
            if case .endpoint(.requestPath(destinationHash: dest)) = action { return true }
            return false
        }
    }

    @Test func aFirstSendToAPeerWithNoCostGoesOutUnstampedWhenThePathArrives() async throws {
        let me = Identity(), peer = Identity()
        let store = await makeNode(me, TestClock())
        let m = message(from: me, to: peer)

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        #expect(await isHandedOver(store, m) == false)

        await store.send(.endpoint(.transport(.received(iface, deliveryAnnounce(of: peer, stampCost: nil)))))
        let handed = try #require(await nextHandedToRouter(store))
        #expect(handed.hash == m.hash)
        #expect(handed.stamp == nil)
    }

    /// Everything waiting on that peer goes out, on one path request.
    @Test func severalFirstSendsShareOnePathRequestAndAllGetStamped() async throws {
        let me = Identity(), peer = Identity()
        let requests = LockIsolated(0)
        let store = await makeNode(me, TestClock(), countingPathRequestsIn: requests)
        let one = message(from: me, to: peer, "one"), two = message(from: me, to: peer, "two")

        await store.send(.sendMessage(message: one, fallbackToPropagation: false))
        await store.send(.sendMessage(message: two, fallbackToPropagation: false))
        await store.send(.endpoint(.transport(.received(iface, deliveryAnnounce(of: peer, stampCost: cheapCost)))))

        let handed = LockIsolated<[Data: LXMessage]>([:])
        for _ in 0..<2 {
            await store.receive({ action in
                if case let .router(.send(m, _)) = action {
                    handed.withValue { $0[m.hash] = m }
                    return true
                }
                return false
            }, timeout: .seconds(30))
        }
        #expect(handed.value[one.hash]?.validateStamp(targetCost: cheapCost) == true)
        #expect(handed.value[two.hash]?.validateStamp(targetCost: cheapCost) == true)
        #expect(requests.value == 1)
    }

    /// The wait is bounded: with no path at all, the router's own path budget takes over. Three
    /// requests, seven seconds apart.
    @Test func aFirstSendIsHandedOverUnstampedWhenNoPathArrives() async throws {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let requests = LockIsolated(0)
        let store = await makeNode(me, clock, countingPathRequestsIn: requests)
        let m = message(from: me, to: peer)

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        await clock.advance(by: .seconds(20))
        #expect(await isHandedOver(store, m) == false, "still inside the wait")
        #expect(requests.value == 3)

        await clock.advance(by: .seconds(1))
        let handed = try #require(await nextHandedToRouter(store))
        #expect(handed.hash == m.hash)
        #expect(handed.stamp == nil)
    }

    /// Suspended, nothing can answer a path request, so time spent held must not use up the wait.
    /// Otherwise the message goes out unstamped as soon as the app comes back.
    @Test func timeSpentHeldDoesNotUseUpTheWait() async throws {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let store = await makeNode(me, clock)
        let m = message(from: me, to: peer)

        await store.send(.holdOutbound(true))
        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        // Stepped, because each elapsed interval arms the next timer only once it has been received.
        for _ in 0..<8 {
            await clock.advance(by: .seconds(7))
            await store.skipReceivedActions(strict: false)
        }
        #expect(await isHandedOver(store, m) == false, "held: the wait must not have run out")

        await store.send(.holdOutbound(false))
        await store.send(.endpoint(.transport(.received(iface, deliveryAnnounce(of: peer, stampCost: cheapCost)))))
        let handed = try #require(await nextHandedToRouter(store))
        #expect(handed.validateStamp(targetCost: cheapCost))
    }

    @Test func cancellingAWaitingSendReportsCancelledAndNeverSendsIt() async {
        let me = Identity(), peer = Identity()
        let store = await makeNode(me, TestClock())
        let m = message(from: me, to: peer)

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        await store.send(.cancelOutbound(messageHash: m.hash))
        await store.receive(.delegate(.deliveryCancelled(messageHash: m.hash)))
        // Checked here because the router also refuses a cancelled message, which would hide a leak.
        #expect(store.state.waitingForPeerCost.isEmpty)

        await store.send(.endpoint(.transport(.received(iface, deliveryAnnounce(of: peer, stampCost: nil)))))
        #expect(await isHandedOver(store, m) == false)
        #expect(store.state.inFlightDeliveryStamps.isEmpty)
    }

    @Test func cancelDeliveryStampsFailsAWaitingSendAndNeverSendsIt() async {
        let me = Identity(), peer = Identity()
        let store = await makeNode(me, TestClock())
        let m = message(from: me, to: peer)

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        await store.send(.cancelDeliveryStamps)
        await store.receive(.delegate(.deliveryFailed(messageHash: m.hash)))

        await store.send(.endpoint(.transport(.received(iface, deliveryAnnounce(of: peer, stampCost: nil)))))
        #expect(await isHandedOver(store, m) == false)
    }

    /// A cost restored from a previous session needs no path to be known, so nothing waits.
    @Test func aPersistedCostSkipsTheWait() async throws {
        let me = Identity(), peer = Identity()
        let store = await makeNode(me, TestClock())
        let m = message(from: me, to: peer)
        await store.send(.rehydrateLearnedPeers([m.destinationHash: LXMFNode.LearnedPeer(
            displayName: nil, stampCost: cheapCost, supportsCompression: true, learnedAt: Date(timeIntervalSince1970: sentAt))]))

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        let handed = try #require(await nextHandedToRouter(store))
        #expect(handed.validateStamp(targetCost: cheapCost))
    }
}
