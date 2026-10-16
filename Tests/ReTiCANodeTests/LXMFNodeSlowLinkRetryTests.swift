import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

private let slowIface = InterfaceID("lxmf-slow-iface")
private let fastIface = InterfaceID("lxmf-fast-iface")
private let slow202 = InterfaceProfile(name: "slow-202", bitrate: 202)
private let sentAt: TimeInterval = 1700000000.5

@MainActor
private func makeNode(_ identity: Identity, _ clock: TestClock<Duration>) -> TestStoreOf<LXMFNode> {
    let store = TestStore(initialState: LXMFNode.State(identity: identity, endpoint: TransportEndpoint.State())) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: sentAt))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

/// Peer's lxmf.delivery announce, heard `wireHops` relays away, emitted at `now`.
private func deliveryAnnounce(of peer: Identity, wireHops: UInt8, now: UInt64 = 1_700_000_000,
                              prefix: UInt8 = 0x02) -> Data {
    let dest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                           aspects: LXMessage.deliveryAspects, identity: peer)!
    let randomHash = Announce.randomHash(now: now, randomPrefix: Data(repeating: prefix, count: 5))
    let payload = Announce.buildPayload(identity: peer, destinationHash: dest.hash,
                                        nameHash: dest.nameHash, randomHash: randomHash)
    var packet = Packet.announce(from: dest, payload: payload)
    packet.hops = wireHops
    return try! packet.packed()
}

@MainActor
private func hear(_ store: TestStoreOf<LXMFNode>, _ raw: Data, on iface: InterfaceID, as profile: InterfaceProfile) async {
    await store.send(.endpoint(.transport(.interfaceConnected(iface, profile))))
    await store.send(.endpoint(.transport(.received(iface, raw))))
    await store.skipReceivedActions(strict: false)
}

/// Send an opportunistic message to `peer`; returns its hash.
@MainActor
private func sendTo(_ store: TestStoreOf<LXMFNode>, from me: Identity, _ peer: Identity) async -> Data {
    let dest = LXMessage.deliveryHash(identityHash: peer.hash)
    await store.send(.send(destinationHash: dest, title: Data("t".utf8), content: Data("hi".utf8), method: .opportunistic))
    return LXMessage.create(source: me, destinationHash: dest, timestamp: sentAt,
                            title: Data("t".utf8), content: Data("hi".utf8)).hash
}

@MainActor
private func attemptsAfter(_ store: TestStoreOf<LXMFNode>, _ clock: TestClock<Duration>, _ seconds: Int,
                           _ hash: Data) async -> Int? {
    await clock.advance(by: .seconds(seconds))
    await store.skipReceivedActions(strict: false)
    return store.state.router.pendingDeliveries[.delivery(hash)]?.attempts
}

@Suite @MainActor struct LXMFNodeSlowLinkRetryTests {
    @Test func anAnnounceOverASlowInterfaceStretchesTheRetryWait() async {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let store = makeNode(me, clock)
        let dest = LXMessage.deliveryHash(identityHash: peer.hash)
        await hear(store, deliveryAnnounce(of: peer, wireHops: 0), on: slowIface, as: slow202)
        #expect(store.state.router.nextHopRetryWaits[dest] == 80)                 // written at pathLearned
        let hash = await sendTo(store, from: me, peer)
        #expect(await attemptsAfter(store, clock, 79, hash) == 1)
        #expect(await attemptsAfter(store, clock, 1, hash) == 2)
    }

    @Test(arguments: [InterfaceProfile.tcp, .ble], [UInt8(0), 1, 4])
    func aFastNextHopKeepsTheTenSecondRetryAtEveryHopCount(profile: InterfaceProfile, wireHops: UInt8) async {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let store = makeNode(me, clock)
        await hear(store, deliveryAnnounce(of: peer, wireHops: wireHops), on: fastIface, as: profile)
        let hash = await sendTo(store, from: me, peer)
        #expect(store.state.router.nextHopRetryWaits.isEmpty, "fast paths are never stored")
        #expect(await attemptsAfter(store, clock, 9, hash) == 1)
        #expect(await attemptsAfter(store, clock, 1, hash) == 2)
    }

    @Test func aPathMovingToAFastInterfaceDropsTheStretchedWait() async {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let store = makeNode(me, clock)
        let dest = LXMessage.deliveryHash(identityHash: peer.hash)
        await hear(store, deliveryAnnounce(of: peer, wireHops: 0), on: slowIface, as: slow202)
        #expect(store.state.router.nextHopRetryWaits[dest] == 80)
        // A NEWER announce (later emission time, fresh blob) over TCP replaces the path.
        await hear(store, deliveryAnnounce(of: peer, wireHops: 0, now: 1_700_000_100, prefix: 0x03),
                   on: fastIface, as: .tcp)
        #expect(store.state.endpoint.transport.learned[dest]?.interfaceID == fastIface)
        #expect(store.state.router.nextHopRetryWaits[dest] == nil)
    }

    @Test func aRehydratedSlowPathStretchesTheRetryAtFirstSend() async {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let store = makeNode(me, clock)
        let dest = LXMessage.deliveryHash(identityHash: peer.hash)
        await store.send(.endpoint(.transport(.interfaceConnected(slowIface, slow202))))
        await store.send(.endpoint(.transport(.rehydrateLearnedDestinations([dest: LearnedDestination(
            identity: peer, appData: nil, ratchet: nil, interfaceID: slowIface, hops: 0, nextHop: dest,
            announceEmitted: 0, learnedAt: Date(timeIntervalSince1970: 0))]))))
        #expect(store.state.router.nextHopRetryWaits[dest] == nil, "no pathLearned fires on rehydration")
        let hash = await sendTo(store, from: me, peer)
        #expect(store.state.router.nextHopRetryWaits[dest] == 80)                 // written at send
        #expect(await attemptsAfter(store, clock, 79, hash) == 1)
        #expect(await attemptsAfter(store, clock, 1, hash) == 2)
    }

    @Test func aReRegisteredInterfaceBitrateIsReadAtSend() async {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let store = makeNode(me, clock)
        let dest = LXMessage.deliveryHash(identityHash: peer.hash)
        await hear(store, deliveryAnnounce(of: peer, wireHops: 0), on: slowIface, as: .tcp)
        #expect(store.state.router.nextHopRetryWaits[dest] == nil)
        await store.send(.endpoint(.transport(.interfaceConnected(slowIface, slow202))))   // same id, slower
        let hash = await sendTo(store, from: me, peer)
        #expect(store.state.router.nextHopRetryWaits[dest] == 80)
        #expect(await attemptsAfter(store, clock, 79, hash) == 1)
        #expect(await attemptsAfter(store, clock, 1, hash) == 2)
    }

    @Test func aDisconnectedNextHopFallsBackToTenSecondsAtSend() async {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let store = makeNode(me, clock)
        let dest = LXMessage.deliveryHash(identityHash: peer.hash)
        await hear(store, deliveryAnnounce(of: peer, wireHops: 0), on: slowIface, as: slow202)
        #expect(store.state.router.nextHopRetryWaits[dest] == 80)
        await store.send(.endpoint(.transport(.interfaceDisconnected(slowIface))))
        let hash = await sendTo(store, from: me, peer)
        #expect(store.state.router.nextHopRetryWaits[dest] == nil, "no reachable next hop → unknown bitrate")
        #expect(await attemptsAfter(store, clock, 9, hash) == 1)
        #expect(await attemptsAfter(store, clock, 1, hash) == 2)
    }
}
