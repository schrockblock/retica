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

    /// `.pathLearned` fires for every announce from every app; only hashes the router can retry
    /// to may enter the (never-pruned) retry-wait table.
    @Test func aNonLXMFAnnounceOverASlowInterfaceLeavesNoRetryWaitEntry() async {
        let store = makeNode(Identity(), TestClock())
        let other = Identity()
        let dest = Destination(kind: .single, direction: .in, appName: "someapp", aspects: ["telemetry"],
                               identity: other)!
        await hear(store, signedAnnounce(of: dest, identity: other), on: slowIface, as: slow202)
        #expect(store.state.endpoint.transport.learned[dest.hash]?.interfaceID == slowIface,
                "the path must really be learned over the slow interface")
        #expect(store.state.router.nextHopRetryWaits.isEmpty)
    }

    @Test func anOutboundPropagationNodeAnnounceOverASlowInterfaceStretchesItsRetryWait() async {
        let pn = Identity()
        let pnDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                 aspects: ["propagation"], identity: pn)!
        var initial = LXMFNode.State(identity: Identity(), endpoint: TransportEndpoint.State())
        initial.router.outboundPropagationNode = pnDest.hash
        let store = TestStore(initialState: initial) { LXMFNode() } withDependencies: {
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: sentAt))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        await hear(store, signedAnnounce(of: pnDest, identity: pn), on: slowIface, as: slow202)
        #expect(store.state.endpoint.transport.learned[pnDest.hash]?.interfaceID == slowIface)
        #expect(store.state.router.nextHopRetryWaits[pnDest.hash] == 80)
    }
}

/// A signed announce for an arbitrary destination, heard directly (0 wire hops).
private func signedAnnounce(of dest: Destination, identity: Identity) -> Data {
    let randomHash = Announce.randomHash(now: 1_700_000_000, randomPrefix: Data(repeating: 0x04, count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: dest.hash,
                                        nameHash: dest.nameHash, randomHash: randomHash)
    return try! Packet.announce(from: dest, payload: payload).packed()
}

// MARK: - Propagated copies (retry timer keyed on the PROPAGATION NODE's hash)

private let pnLinkID = Data(repeating: 0x5C, count: 16)

private func rehydrated(_ identity: Identity, hash: Data, on iface: InterfaceID,
                        appData: Data? = nil) -> LearnedDestination {
    LearnedDestination(identity: identity, appData: appData, ratchet: nil, interfaceID: iface, hops: 0,
                       nextHop: hash, announceEmitted: 0, learnedAt: Date(timeIntervalSince1970: 0))
}

/// A node whose router already has a PN as outbound propagation node with an ACTIVE link to it
/// (the propagated retry timer is armed only with a live link), and whose Transport has
/// REHYDRATED paths to the PN and to the recipient over `slowIface` (so no `.pathLearned` ever
/// fires). `staleWait` seeds a leftover table entry for the PN.
@MainActor
private func makePropagatedNode(_ me: Identity, _ clock: TestClock<Duration>, pn: Identity, recipient: Identity,
                                staleWait: Int? = nil) async
    -> (store: TestStoreOf<LXMFNode>, pnHash: Data, recipientDest: Data) {
    let pnHash = LXMessage.deliveryHash(identityHash: pn.hash)   // any 16-byte key; just consistent
    let recipientDest = LXMessage.deliveryHash(identityHash: recipient.hash)
    var initial = LXMFNode.State(identity: me, endpoint: TransportEndpoint.State())
    initial.router.outboundPropagationNode = pnHash
    initial.router.directLinks[pnHash] = .active(linkID: pnLinkID)
    initial.router.nextHopRetryWaits[pnHash] = staleWait
    let store = TestStore(initialState: initial) { LXMFNode() } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: sentAt))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.endpoint(.transport(.interfaceConnected(slowIface, slow202))))
    await store.send(.endpoint(.transport(.rehydrateLearnedDestinations([
        // Advertised stamp cost 4 keeps the propagation stamp search fast (the default, 16, takes ~1 min).
        pnHash: rehydrated(pn, hash: pnHash, on: slowIface, appData: PNAnnounce(
            timebase: 0, nodeState: true, perTransferLimit: 0, perSyncLimit: 0,
            targetStampCost: 4, stampCostFlexibility: 0, peeringCost: 0).packed),
        recipientDest: rehydrated(recipient, hash: recipientDest, on: slowIface)]))))
    return (store, pnHash, recipientDest)
}

@MainActor
private func propagatedAttempts(_ store: TestStoreOf<LXMFNode>, _ clock: TestClock<Duration>, _ seconds: Int,
                                _ hash: Data) async -> Int? {
    await clock.advance(by: .seconds(seconds))
    await store.skipReceivedActions(strict: false)
    return store.state.router.pendingDeliveries[.propagated(hash)]?.attempts
}

@MainActor
private func sendViaPN(_ store: TestStoreOf<LXMFNode>, from me: Identity, to dest: Data) async -> Data {
    await store.send(.sendViaPropagation(destinationHash: dest, title: Data("t".utf8), content: Data("hi".utf8)))
    // The stamp search runs off-thread; wait for its hand-over to reach the router.
    await store.receive({ if case .router(.sendViaPropagation) = $0 { return true } else { return false } },
                        timeout: .seconds(60))
    return LXMessage.create(source: me, destinationHash: dest, timestamp: sentAt,
                            title: Data("t".utf8), content: Data("hi".utf8)).hash
}

@Suite @MainActor struct LXMFNodeSlowLinkPropagatedRetryTests {
    @Test func aRehydratedSlowPropagationNodeStretchesThePropagatedRetry() async {
        let me = Identity(), pn = Identity(), recipient = Identity(), clock = TestClock()
        let (store, pnHash, recipientDest) = await makePropagatedNode(me, clock, pn: pn, recipient: recipient)
        #expect(store.state.router.nextHopRetryWaits[pnHash] == nil, "no pathLearned fires on rehydration")
        let hash = await sendViaPN(store, from: me, to: recipientDest)
        #expect(store.state.router.nextHopRetryWaits[pnHash] == 80)
        #expect(store.state.router.pendingDeliveries[.propagated(hash)]?.attempts == 1, "armed on the live PN link")
        #expect(await propagatedAttempts(store, clock, 79, hash) == 1)
        #expect(await propagatedAttempts(store, clock, 1, hash) == 2)
    }

    @Test func aSendMessagePropagatedCopyStretchesThePropagatedRetryToo() async {
        let me = Identity(), pn = Identity(), recipient = Identity(), clock = TestClock()
        let (store, pnHash, recipientDest) = await makePropagatedNode(me, clock, pn: pn, recipient: recipient)
        let msg = LXMessage.create(source: me, destinationHash: recipientDest, timestamp: sentAt,
                                   title: Data("t".utf8), content: Data("hi".utf8))
        await store.send(.sendMessage(message: msg, fallbackToPropagation: true))
        // The router's hand-off, played directly: this test is about the wait, not the trigger.
        await store.send(.router(.delegate(.propagationFallbackDue(messageHash: msg.hash))))
        await store.receive({ if case .router(.sendViaPropagation) = $0 { return true } else { return false } },
                            timeout: .seconds(60))
        #expect(store.state.router.nextHopRetryWaits[pnHash] == 80)
        #expect(await propagatedAttempts(store, clock, 79, msg.hash) == 1)
        #expect(await propagatedAttempts(store, clock, 1, msg.hash) == 2)
    }

    @Test func aDisconnectedPropagationNodeHopFallsBackToTenSeconds() async {
        let me = Identity(), pn = Identity(), recipient = Identity(), clock = TestClock()
        let (store, pnHash, recipientDest) = await makePropagatedNode(me, clock, pn: pn, recipient: recipient,
                                                                       staleWait: 80)
        #expect(store.state.router.nextHopRetryWaits[pnHash] == 80, "stale stretched entry from an earlier send")
        await store.send(.endpoint(.transport(.interfaceDisconnected(slowIface))))
        let hash = await sendViaPN(store, from: me, to: recipientDest)
        #expect(store.state.router.nextHopRetryWaits[pnHash] == nil, "stale stretched wait removed")
        #expect(await propagatedAttempts(store, clock, 9, hash) == 1)
        #expect(await propagatedAttempts(store, clock, 1, hash) == 2)
    }
}
