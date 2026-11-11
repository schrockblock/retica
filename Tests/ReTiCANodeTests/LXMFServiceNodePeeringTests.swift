import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport
@testable import ReTiCAInterfaces

// The client half of propagation-node peering: `LXMFServiceNode` drives its `PNPeerTable` outward as a
// default lxmd does — auto-peering from announces heard through `Transport`, static peers, the 24 s
// peer-sync job, peering-key mining and caching, the `/offer` exchange and the sync transfer, and the
// persistence hooks. Each test drives ONE service node through its public actions and the endpoint
// delegates, and reads what it sends from the endpoint actions it emits. The two-node seam is in
// `LXMFServiceNodePeeringSliceTests`.

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private let ifID = InterfaceID("tcp")
private let offerPathHash = Crypto.truncatedHash(Data("/offer".utf8))

/// What the node sends, as these tests look for it.
private enum Out: Equatable, Sendable {
    /// `openLink`: a sync link (owned); `plainOpen`: a client link.
    case openLink(Data), plainOpen(Data), requestPath(Data), identify(Data)
    case request(link: Data, path: String, data: Data), resource(link: Data, data: Data)
    case closeLink(Data), tick, peersChanged
}

private struct Recorded: Reducer {
    typealias State = LXMFServiceNode.State
    typealias Action = LXMFServiceNode.Action
    let log: LockIsolated<[Out]>
    var body: some ReducerOf<Self> {
        Reduce { _, action in
            let out: Out?
            switch action {
            case let .client(.endpoint(.openOwnedLink(dest, .propagationPeerSync))): out = .openLink(dest)
            case let .client(.endpoint(.openLink(dest))): out = .plainOpen(dest)
            case let .client(.endpoint(.requestPath(dest))): out = .requestPath(dest)
            case let .client(.endpoint(.identifyOverLink(link, _))): out = .identify(link)
            case let .client(.endpoint(.sendRequestOverLink(link, path, data))): out = .request(link: link, path: path, data: data)
            case let .client(.endpoint(.sendResourceOverLink(link, data))): out = .resource(link: link, data: data)
            case let .client(.endpoint(.closeLink(link))): out = .closeLink(link)
            case .peerSyncTick: out = .tick
            case .delegate(.peersChanged): out = .peersChanged
            default: out = nil
            }
            if let out { log.withValue { $0.append(out) } }
            return .none
        }
        LXMFServiceNode()
    }
}

/// A seeded generator: `syncTick` picks `next() % pool.count`.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private func propagationHash(_ identity: Identity) -> Data {
    Destination.hash(identityHash: identity.hash, appName: LXMessage.appName, aspects: ["propagation"])
}

/// A peer's propagation announce. `peeringCost` 2 keeps a real key search instant; unstamped entries
/// (our store's cost is 0) are worth 0, which a peer asking 0 accepts.
private func pnAnnounce(timebase: Int = 1, nodeState: Bool = true, peeringCost: Double = 2,
                        perSyncLimit: Int? = 10240) -> PNAnnounce {
    PNAnnounce(timebase: timebase, nodeState: nodeState, perTransferLimit: 256, perSyncLimit: perSyncLimit ?? 10240,
               targetStampCost: 0, stampCostFlexibility: 0, peeringCost: peeringCost)
}

/// A raw `lxmf.propagation` announce from `identity`, `hops` on the wire.
private func announcePacket(_ identity: Identity, hops: UInt8, appData: Data, pathResponse: Bool = false,
                            emitted: UInt64) -> Data {
    let nameHash = Destination.nameHash(appName: LXMessage.appName, aspects: ["propagation"])
    let dest = propagationHash(identity)
    let randomHash = Announce.randomHash(now: emitted, randomPrefix: Data(repeating: UInt8(truncatingIfNeeded: emitted), count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: dest, nameHash: nameHash,
                                        randomHash: randomHash, appData: appData)
    let packet = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                        destinationType: .single, context: pathResponse ? .pathResponse : .none,
                        contextFlag: false, hops: hops, destinationHash: dest, transportId: nil, payload: payload)
    return try! packet.packed()
}

/// A synthetic propagation entry: our store's cost is 0, so it is accepted unstamped.
private func entry(_ byte: UInt8) -> Data { Data(repeating: byte, count: 120) }
private func tid(_ byte: UInt8) -> Data {
    LXMFPropagation.transientId(lxmfData: LXMFPropagation.strippedCore(lxmfData: entry(byte)))
}

private let clientLink = Data(repeating: 0xCC, count: 16)

private func nodeState(_ ours: Identity, peering: PNPeerTable.Config = .init(peeringCost: 8)) -> LXMFServiceNode.State {
    var s = LXMFServiceNode.State(identity: ours, endpoint: tcpDriverEndpoint(host: "h", port: 4242, reconnectOnDrop: false),
                                  targetStampCost: 0, peering: peering)
    s.nodeModeEnabled = true
    let served = propagationHash(ours)
    s.client.propagationDestinationHash = served
    s.client.linkDestinations[clientLink] = served
    return s
}

private final class Harness: @unchecked Sendable {
    let log = LockIsolated<[Out]>([])
    let now = LockIsolated(t0)
    let clock = TestClock()
    var emitted: UInt64 = 1_700_000_000
}

@MainActor
private func makeStore(_ state: LXMFServiceNode.State, _ h: Harness,
                       peeringKey: (@Sendable (Data, Double) async -> Data?)? = nil) async -> TestStoreOf<Recorded> {
    let store = TestStore(initialState: state) { Recorded(log: h.log) } withDependencies: {
        $0.continuousClock = h.clock
        $0.date = DateGenerator { h.now.value }
        $0.transportDate = DateGenerator { h.now.value }
        $0.uuid = .incrementing
        $0.withRandomNumberGenerator = WithRandomNumberGenerator(Seeded(state: 7))
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        if let peeringKey {
            $0.lxmfStampGenerator = LXMFStampGenerator(deliveryStamp: { _, _ in nil },
                                                       propagationPack: { _, _, _, _, _ in nil },
                                                       peeringKey: peeringKey)
        }
    }
    store.exhaustivity = .off
    await store.send(.client(.endpoint(.transport(.interfaceConnected(ifID, .tcp)))))
    return store
}

@MainActor
private func hear(_ store: TestStoreOf<Recorded>, _ h: Harness, _ identity: Identity, hops: UInt8 = 0,
                  announce: PNAnnounce = pnAnnounce(), pathResponse: Bool = false) async {
    h.emitted += 1
    await store.send(.client(.endpoint(.transport(.received(ifID, announcePacket(identity, hops: hops,
        appData: announce.packed, pathResponse: pathResponse, emitted: h.emitted))))))
    await store.skipReceivedActions(strict: false)
}

/// A client's single-message upload on an unidentified link to our propagation destination.
@MainActor
private func upload(_ store: TestStoreOf<Recorded>, _ bytes: UInt8...) async {
    for b in bytes {
        await store.send(.client(.endpoint(.delegate(.resourceReceived(linkID: clientLink,
            data: LXMFPropagation.container(timestamp: 1_700_000_000, entries: [entry(b)]))))))
    }
    await store.skipReceivedActions(strict: false)
}

@MainActor
private func send(_ store: TestStoreOf<Recorded>, _ action: LXMFServiceNode.Action) async {
    await store.send(action)
    await store.skipReceivedActions(strict: false)
}

@MainActor
private func established(_ store: TestStoreOf<Recorded>, _ link: Data, _ peer: Data) async {
    await send(store, .client(.endpoint(.delegate(.ownedLinkEstablished(owner: .propagationPeerSync, linkID: link,
                                                                        destinationHash: peer)))))
}

@MainActor
private func respond(_ store: TestStoreOf<Recorded>, _ link: Data, _ value: MsgPackValue) async {
    await send(store, .client(.endpoint(.delegate(.responseReceived(linkID: link, requestID: Data([1]),
                                                                    data: MsgPack.encode(value))))))
}

private func opens(_ log: LockIsolated<[Out]>) -> [Data] {
    log.value.compactMap { if case let .openLink(d) = $0 { return d }; return nil }
}
private func offers(_ log: LockIsolated<[Out]>) -> [(link: Data, key: Data, ids: [Data])] {
    log.value.compactMap {
        guard case let .request(link, path, data) = $0, path == "/offer",
              case let .array(items)? = MsgPack.decodeValue(data), items.count == 2,
              case let .bin(key) = items[0], case let .array(ids) = items[1] else { return nil }
        return (link, key, ids.compactMap { if case let .bin(d) = $0 { return d }; return nil })
    }
}
private func resources(_ log: LockIsolated<[Out]>) -> [Data] {
    log.value.compactMap { if case let .resource(_, d) = $0 { return d }; return nil }
}
private func closes(_ log: LockIsolated<[Out]>) -> [Data] {
    log.value.compactMap { if case let .closeLink(d) = $0 { return d }; return nil }
}

/// A peer in the table with a cached key worth 10 (its announce asks 2), as a relaunch hands it back.
private func cachedPeer(_ dest: Data, announce: PNAnnounce = pnAnnounce(), handled: Set<Data> = [],
                        unhandled: Set<Data>, key: Data = Data(repeating: 0x4B, count: 32)) -> PNPeerTable.Peer {
    PNPeerTable.Peer(destinationHash: dest, peeringTimebase: announce.timebase, alive: true, lastHeard: t0,
                     announce: announce, peeringKey: key, peeringKeyValue: 10, handled: handled, unhandled: unhandled)
}

// MARK: - Auto-peering from announces

/// An announce heard through `Transport` autopeers within `autopeerMaxDepth` (6) as reference counts
/// hops: one more than the on-wire count, as reference increments on receipt (Transport.py:2028). So
/// on-wire 5 (depth 6) peers and on-wire 6 (depth 7) does not — the same conversion the inbound-sync
/// auto-peer uses.
@MainActor @Test func announceAtDepth6PeersAt7DoesNot() async {
    let h = Harness()
    let store = await makeStore(nodeState(Identity()), h)
    let near = Identity(), far = Identity()
    await hear(store, h, near, hops: 5)
    await hear(store, h, far, hops: 6)
    #expect(store.state.peering.peers[propagationHash(near)] != nil)
    #expect(store.state.peering.peers[propagationHash(near)]?.announce == pnAnnounce())
    #expect(store.state.peering.peers[propagationHash(far)] == nil)
}

/// Peering is evaluated only in node mode (Handlers.py:56), and only for `lxmf.propagation`
/// destinations: the same app data announced on another aspect peers nothing.
@MainActor @Test func announceOutsideNodeModeOrOffAspectDoesNotPeer() async {
    let h = Harness()
    var off = nodeState(Identity())
    off.nodeModeEnabled = false
    let store = await makeStore(off, h)
    let peer = Identity()
    await hear(store, h, peer, hops: 0)
    #expect(store.state.peering.peers.isEmpty)

    let on = await makeStore(nodeState(Identity()), h)
    let other = Identity()
    let nameHash = Destination.nameHash(appName: LXMessage.appName, aspects: ["delivery"])
    let dest = Destination.hash(identityHash: other.hash, appName: LXMessage.appName, aspects: ["delivery"])
    let payload = Announce.buildPayload(identity: other, destinationHash: dest, nameHash: nameHash,
                                        randomHash: Announce.randomHash(now: 5, randomPrefix: Data(repeating: 1, count: 5)),
                                        appData: pnAnnounce().packed)
    let raw = try! Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                          destinationType: .single, context: .none, contextFlag: false, hops: 0,
                          destinationHash: dest, transportId: nil, payload: payload).packed()
    await send(on, .client(.endpoint(.transport(.received(ifID, raw)))))
    #expect(on.state.client.endpoint.learned[dest] != nil)
    #expect(on.state.peering.peers.isEmpty)
}

/// A path response never autopeers (Handlers.py:89, `not is_path_response`), but it feeds a static
/// peer that has never been heard (:76-86). `setStaticPeers` adds the entry with its costs unknown
/// and requests a path to it (LXMRouter.py:728-737).
@MainActor @Test func pathResponseDoesNotAutopeerButFeedsAStaticPeer() async {
    let h = Harness()
    let store = await makeStore(nodeState(Identity()), h)
    let stranger = Identity(), fixed = Identity()
    let fixedHash = propagationHash(fixed)
    await send(store, .setStaticPeers([fixedHash]))
    #expect(h.log.value.contains(.requestPath(fixedHash)))
    #expect(store.state.peering.peers[fixedHash]?.announce == nil)

    await hear(store, h, stranger, hops: 0, pathResponse: true)
    #expect(store.state.peering.peers[propagationHash(stranger)] == nil)

    await hear(store, h, fixed, hops: 3, pathResponse: true)
    #expect(store.state.peering.peers[fixedHash]?.announce == pnAnnounce())
    #expect(store.state.peering.peers[fixedHash]?.lastHeard == t0)
}

// MARK: - The sync job

/// Reference `sync()` mines the key before any link (LXMPeer.py:285-288): the first tick starts the
/// search and opens nothing; the key is kept; the next tick opens exactly one link.
@MainActor @Test func syncTickOpensOneLinkAfterKeyReady() async {
    let h = Harness()
    let searches = LockIsolated(0)
    let store = await makeStore(nodeState(Identity()), h, peeringKey: { id, cost in
        searches.withValue { $0 += 1 }
        return await LXStamper.generatePeeringKey(peeringId: id, targetCost: cost)
    })
    let peer = Identity(), dest = propagationHash(peer)
    await hear(store, h, peer)
    await upload(store, 1)
    #expect(store.state.peering.peers[dest]?.unhandled == [tid(1)])

    await store.send(.peerSyncTick)
    await store.receive(\.peeringKeyReady, timeout: .seconds(10))
    await store.skipReceivedActions(strict: false)
    #expect(opens(h.log).isEmpty)
    #expect(searches.value == 1)
    let p = store.state.peering.peers[dest]
    #expect(p?.peeringKey != nil)
    #expect((p?.peeringKeyValue ?? 0) >= 2)
    // The key is over the peer's identity hash followed by ours.
    let ours = store.state.client.identity
    #expect(LXStamper.validatePeeringKey(peeringId: peer.hash + ours.hash, peeringKey: p?.peeringKey ?? Data(),
                                         targetCost: 2))

    await send(store, .peerSyncTick)
    #expect(opens(h.log) == [dest])
    #expect(searches.value == 1)
}

/// On an established link the node identifies, then offers with the CACHED key only the stored ids the
/// peer has not handled (LXMPeer.py:339-395); no key is mined.
@MainActor @Test func offerGoesOutWithCachedKeyAndOnlyUnhandledIds() async {
    let h = Harness()
    let searches = LockIsolated(0)
    let store = await makeStore(nodeState(Identity()), h, peeringKey: { _, _ in searches.withValue { $0 += 1 }; return nil })
    let peer = Identity(), dest = propagationHash(peer)
    await hear(store, h, peer)
    await upload(store, 1, 2)
    let key = Data(repeating: 0x4B, count: 32)
    await send(store, .rehydrate(entries: [], peers: [cachedPeer(dest, handled: [tid(1)], unhandled: [tid(2)], key: key)]))

    await send(store, .peerSyncTick)
    #expect(opens(h.log) == [dest])
    let link = Data(repeating: 0x11, count: 16)
    await established(store, link, dest)
    let identifyIndex = h.log.value.firstIndex(of: .identify(link))
    let offerIndex = h.log.value.firstIndex { if case .request(link, "/offer", _) = $0 { return true }; return false }
    #expect(identifyIndex != nil && offerIndex != nil && identifyIndex! < offerIndex!)
    #expect(offers(h.log).count == 1)
    #expect(offers(h.log).first?.key == key)
    #expect(offers(h.log).first?.ids == [tid(2)])
    #expect(searches.value == 0)
}

@MainActor
private func peerWithOfferOut(_ h: Harness, unhandled: [UInt8] = [2]) async -> (TestStoreOf<Recorded>, Data, Data) {
    let store = await makeStore(nodeState(Identity()), h, peeringKey: { _, _ in nil })
    let peer = Identity(), dest = propagationHash(peer)
    await hear(store, h, peer)
    for b in unhandled { await upload(store, b) }
    await send(store, .rehydrate(entries: [], peers: [cachedPeer(dest, unhandled: Set(unhandled.map(tid)))]))
    await send(store, .peerSyncTick)
    let link = Data(repeating: 0x11, count: 16)
    await established(store, link, dest)
    #expect(offers(h.log).count == 1)
    return (store, dest, link)
}

/// `ERROR_NO_IDENTITY`: identify again and offer again on the SAME link (LXMPeer.py:413-418).
@MainActor @Test func noIdentityResponseReidentifiesAndReoffersOnSameLink() async {
    let h = Harness()
    let (store, dest, link) = await peerWithOfferOut(h)
    await respond(store, link, .uint(LXMFPropagation.errorNoIdentity))
    #expect(h.log.value.filter { $0 == .identify(link) }.count == 2)
    #expect(offers(h.log).count == 2)
    #expect(offers(h.log).allSatisfy { $0.link == link })
    #expect(opens(h.log) == [dest])
    #expect(closes(h.log).isEmpty)
    #expect(store.state.peering.peers[dest]?.state == .requestSent)
}

/// `ERROR_NO_ACCESS`: the peer is unpeered (LXMPeer.py:421-424), and its link closed.
@MainActor @Test func noAccessUnpeers() async {
    let h = Harness()
    let (store, dest, link) = await peerWithOfferOut(h)
    await respond(store, link, .uint(LXMFPropagation.errorNoAccess))
    #expect(store.state.peering.peers[dest] == nil)
    #expect(closes(h.log) == [link])
}

/// `ERROR_THROTTLED`: no sync attempt for `PN_STAMP_THROTTLE` (300 s, LXMPeer.py:426-430).
@MainActor @Test func throttledPostpones300s() async {
    let h = Harness()
    let (store, dest, link) = await peerWithOfferOut(h)
    await respond(store, link, .uint(LXMFPropagation.errorThrottled))
    #expect(closes(h.log) == [link])
    #expect(store.state.peering.peers[dest]?.nextSyncAttempt == t0 + 300)
    await send(store, .client(.endpoint(.delegate(.linkClosed(linkID: link, reason: .initiatorClosed)))))
    h.now.setValue(t0 + 299)
    await send(store, .peerSyncTick)
    #expect(opens(h.log) == [dest])
    h.now.setValue(t0 + 301)
    await send(store, .peerSyncTick)
    #expect(opens(h.log) == [dest, dest])
}

/// After a concluded transfer the sent ids are handled, the rate is measured, the link closes, and with
/// unhandled ids left (one arrived meanwhile) the persistent strategy syncs again at once
/// (LXMPeer.py:497-529).
@MainActor @Test func concludedTransferResyncsWhenUnhandledRemain() async throws {
    let h = Harness()
    let (store, dest, link) = await peerWithOfferOut(h)
    await respond(store, link, .bool(true))
    #expect(resources(h.log).count == 1)
    let container = try #require(resources(h.log).first)
    #expect(LXMFPropagation.parseContainer(container)?.1 == [entry(2)])

    await upload(store, 3)       // arrives during the transfer
    h.now.setValue(t0 + 2)
    let resourceHash = Data(repeating: 0x5E, count: 32)
    await send(store, .client(.endpoint(.delegate(.resourceProgress(linkID: link, resourceHash: resourceHash, role: .sender,
                                                                    bytesDone: 400, bytesTotal: 400, segment: 1, segments: 1)))))
    await send(store, .client(.endpoint(.delegate(.resourceConcluded(linkID: link, resourceHash: resourceHash)))))
    let p = store.state.peering.peers[dest]
    #expect(p?.handled.contains(tid(2)) == true)
    #expect(p?.unhandled == [tid(3)])
    let rate: Double = 400 * 8 / 2      // bytes * 8 / seconds (LXMPeer.py:515)
    #expect(p?.syncTransferRate == rate)
    #expect(closes(h.log) == [link])
    #expect(opens(h.log) == [dest, dest])
}

/// A link that never establishes: the peer is marked not alive and waits out the backoff `syncTick`
/// added when it opened the link (12 min, LXMPeer.py:302-306, :326-328).
@MainActor @Test func linkFailedBacksOff720sAndMarksNotAlive() async {
    let h = Harness()
    let store = await makeStore(nodeState(Identity()), h, peeringKey: { _, _ in nil })
    let peer = Identity(), dest = propagationHash(peer)
    await hear(store, h, peer)
    await upload(store, 2)
    await send(store, .rehydrate(entries: [], peers: [cachedPeer(dest, unhandled: [tid(2)])]))
    await send(store, .peerSyncTick)
    #expect(opens(h.log) == [dest])
    // The client's own link to the same destination failing is not ours.
    await send(store, .client(.endpoint(.delegate(.linkFailed(destinationHash: dest, reason: .establishmentTimedOut)))))
    #expect(store.state.peering.peers[dest]?.state == .linkEstablishing)
    await send(store, .client(.endpoint(.delegate(.ownedLinkFailed(owner: .propagationPeerSync, destinationHash: dest,
                                                                   reason: .establishmentTimedOut)))))
    let p = store.state.peering.peers[dest]
    #expect(p?.alive == false)
    #expect(p?.state == .idle)
    #expect(p?.nextSyncAttempt == t0 + 720)
    h.now.setValue(t0 + 719)
    await send(store, .peerSyncTick)
    #expect(opens(h.log) == [dest])
    h.now.setValue(t0 + 721)
    await send(store, .peerSyncTick)
    #expect(opens(h.log) == [dest, dest])
}

/// With no path the node requests one and waits `PATH_REQUEST_GRACE` (7.5 s) before giving up the way a
/// failed link does (LXMPeer.py:297-306); a path that arrives within the grace gets the link.
@MainActor @Test func noPathRequestsOneThenOpensOrFailsAfterGrace() async {
    let h = Harness()
    let store = await makeStore(nodeState(Identity()), h, peeringKey: { _, _ in nil })
    let peer = Identity(), dest = propagationHash(peer)
    await upload(store, 2)
    await send(store, .rehydrate(entries: [], peers: [cachedPeer(dest, unhandled: [tid(2)])]))
    await send(store, .peerSyncTick)
    #expect(h.log.value.contains(.requestPath(dest)))
    #expect(opens(h.log).isEmpty)
    await h.clock.advance(by: .seconds(7))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.peering.peers[dest]?.state == .linkEstablishing)
    await h.clock.advance(by: .seconds(0.5))
    await store.skipReceivedActions(strict: false)
    #expect(opens(h.log).isEmpty)
    #expect(store.state.peering.peers[dest]?.alive == false)
    #expect(store.state.peering.peers[dest]?.state == .idle)
    #expect(store.state.peering.peers[dest]?.nextSyncAttempt == t0 + 720)

    // Again past the backoff, and this time the path response lands within the grace.
    h.now.setValue(t0 + 721)
    await send(store, .peerSyncTick)
    await hear(store, h, peer, pathResponse: true)
    await h.clock.advance(by: .seconds(7.5))
    await store.skipReceivedActions(strict: false)
    #expect(opens(h.log) == [dest])
}

// MARK: - Review Focus 5

/// Node mode off in the middle of a sync, with a key search running for one peer and an offer out to
/// another: the 24 s job stops, the search is cancelled, the open sync link is closed, no `/offer` or
/// Resource goes out afterwards, and nothing is unpeered (ruling 6b).
@MainActor @Test func nodeModeOffMidSyncStopsJobCancelsKeyAndSendsNothing() async {
    let h = Harness()
    let cancelled = LockIsolated(false)
    let store = await makeStore(nodeState(Identity()), h, peeringKey: { _, _ in
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
        cancelled.setValue(true)
        return nil
    })
    await send(store, .setNodeMode(true))         // starts the job
    let offering = Identity(), mining = Identity()
    let offeringHash = propagationHash(offering), miningHash = propagationHash(mining)
    await hear(store, h, offering)
    await hear(store, h, mining)
    await upload(store, 2)
    await send(store, .rehydrate(entries: [], peers: [cachedPeer(offeringHash, unhandled: [tid(2)])]))

    // The job ticks every 24 s; each tick syncs one peer: the keyed one gets a link (established here
    // and offered to), the other a key search.
    let link = Data(repeating: 0x11, count: 16)
    for _ in 0..<12 {
        await h.clock.advance(by: .seconds(24))
        await store.skipReceivedActions(strict: false)
        if store.state.peering.peers[offeringHash]?.state == .linkEstablishing {
            await established(store, link, offeringHash)
        }
        if offers(h.log).count == 1, store.state.peering.peers[miningHash]?.state == .keyPending { break }
    }
    #expect(h.log.value.filter { $0 == .tick }.count >= 2)
    #expect(opens(h.log) == [offeringHash])
    #expect(offers(h.log).count == 1)
    #expect(store.state.peering.peers[offeringHash]?.state == .requestSent)
    #expect(store.state.peering.peers[miningHash]?.state == .keyPending)

    await send(store, .setNodeMode(false))
    for _ in 0..<200 where !cancelled.value { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(cancelled.value)
    #expect(store.state.peering.peers[miningHash]?.state == .idle)
    #expect(closes(h.log) == [link])
    let peersBefore = Set(store.state.peering.peers.keys)
    #expect(peersBefore == [offeringHash, miningHash])
    let sentBefore = h.log.value.count

    // A late answer to the offer, more job time, a manual tick: nothing goes out.
    await respond(store, link, .bool(true))
    let ticks = h.log.value.filter { $0 == .tick }.count
    await h.clock.advance(by: .seconds(72))
    await store.skipReceivedActions(strict: false)
    #expect(h.log.value.filter { $0 == .tick }.count == ticks)
    await send(store, .peerSyncTick)
    let after = h.log.value.dropFirst(sentBefore)
    #expect(!after.contains { if case .request = $0 { return true }; if case .resource = $0 { return true }; return false })
    #expect(!after.contains { if case .openLink = $0 { return true }; return false })
    #expect(Set(store.state.peering.peers.keys) == peersBefore)
}

// MARK: - Review Focus 3

/// A node-mode relaunch: ONE `.rehydrate` hands back 500 stored entries and 3 persisted peers, so the
/// store is full before the peers are pruned to it (the order cannot be got wrong, I4). No entry may
/// become unhandled for any peer, so the first sync offers only what was unhandled before; a store
/// chunk rehydrated later distributes nothing either.
@MainActor @Test func rehydrateStoreThenPeersMarksNothingUnhandled() async {
    let h = Harness()
    let store = await makeStore(nodeState(Identity()), h, peeringKey: { _, _ in nil })
    let entries = (0..<500).map { i in Data([UInt8(i & 0xFF), UInt8(i >> 8)]) + Data(repeating: 0xE0, count: 118) }
    let tids = entries.map { LXMFPropagation.transientId(lxmfData: LXMFPropagation.strippedCore(lxmfData: $0)) }

    let identities = [Identity(), Identity(), Identity()]
    for identity in identities { await hear(store, h, identity) }
    let persisted = identities.enumerated().map { i, identity in
        cachedPeer(propagationHash(identity), handled: Set(tids[(i * 100)..<(i * 100 + 50)]),
                   unhandled: Set(tids[(i * 100 + 50)..<(i * 100 + 53)]))
    }
    await send(store, .rehydrate(entries: entries, peers: persisted))
    #expect(store.state.pn.store.count == 500)
    for p in persisted {
        #expect(store.state.peering.peers[p.destinationHash]?.unhandled == p.unhandled)
        #expect(store.state.peering.peers[p.destinationHash]?.handled == p.handled)
    }

    let late = (0..<10).map { i in Data([0xF0, UInt8(i)]) + Data(repeating: 0xE1, count: 118) }
    await send(store, .rehydrate(entries: late, peers: []))
    #expect(store.state.pn.store.count == 510)
    for p in persisted {
        #expect(store.state.peering.peers[p.destinationHash]?.unhandled == p.unhandled)
        #expect(store.state.peering.peers[p.destinationHash]?.handled == p.handled)
    }

    await send(store, .peerSyncTick)
    let opened = opens(h.log)
    #expect(opened.count == 1)
    guard let first = opened.first, let p = persisted.first(where: { $0.destinationHash == first }) else { return }
    await established(store, Data(repeating: 0x11, count: 16), first)
    #expect(Set(offers(h.log).first?.ids ?? []) == p.unhandled)
}

// MARK: - Persistence signal

/// `peersChanged` carries the whole persisted table, once per action that changed it however many
/// mutations that action made, and never for an action that changed nothing.
@MainActor @Test func peersChangedEmittedOncePerMutatingAction() async {
    let h = Harness()
    let store = await makeStore(nodeState(Identity()), h, peeringKey: { _, _ in nil })
    let a = propagationHash(Identity()), b = propagationHash(Identity())
    let captured = LockIsolated<[PNPeerTable.Peer]?>(nil)
    await store.send(.setStaticPeers([a, b]))          // two inserts, one action
    await store.receive { action in
        if case let .delegate(.peersChanged(peers)) = action { captured.setValue(peers); return true }
        return false
    }
    await store.skipReceivedActions(strict: false)
    #expect(h.log.value.filter { $0 == .peersChanged }.count == 1)
    #expect(captured.value == store.state.peering.persisted)
    #expect(captured.value?.count == 2)

    await send(store, .peerSyncTick)                    // nothing to sync: no change
    await send(store, .setAutopeer(false))              // config only
    #expect(h.log.value.filter { $0 == .peersChanged }.count == 1)

    await upload(store, 1)                              // distributes to both peers
    #expect(h.log.value.filter { $0 == .peersChanged }.count == 2)
}

// MARK: - Fix round 1: link ownership, request routing, stall bound

/// Probe A: with the `/offer` out under a known request id, an answer to some other request on the link
/// (the client's `/get` list, `[]`, which reads as "wants none") changes nothing: the offered id stays
/// unhandled and the link open. The offer's own answer is then taken.
@MainActor @Test func offerAnswerIsMatchedByRequestID() async {
    let h = Harness()
    let (store, dest, link) = await peerWithOfferOut(h)
    let offerID = Data(repeating: 0x0F, count: 16)
    await send(store, .client(.endpoint(.delegate(.requestSent(linkID: link, requestID: offerID, path: "/offer")))))
    await send(store, .client(.endpoint(.delegate(.responseReceived(linkID: link, requestID: Data(repeating: 0x0E, count: 16),
                                                                    data: MsgPack.encode(.array([])))))))
    await send(store, .client(.endpoint(.delegate(.requestFailed(linkID: link, requestID: Data(repeating: 0x0D, count: 16))))))
    #expect(store.state.peering.peers[dest]?.state == .requestSent)
    #expect(store.state.peering.peers[dest]?.unhandled == [tid(2)])
    #expect(closes(h.log).isEmpty)
    await send(store, .client(.endpoint(.delegate(.responseReceived(linkID: link, requestID: offerID,
                                                                    data: MsgPack.encode(.bool(true)))))))
    #expect(resources(h.log).count == 1)
}

/// I2: a sync link is the service node's alone. Its establishment is never recorded as the client's
/// link to that node (so the router neither arms its idle timer on it nor sends over it), its failure
/// leaves the client's own link to the node alone, and the client's link failing is not taken as ours.
@MainActor @Test func syncLinkNeverEntersTheClientsLinkBookkeeping() async {
    let h = Harness()
    let store = await makeStore(nodeState(Identity()), h, peeringKey: { _, _ in nil })
    let peer = Identity(), dest = propagationHash(peer)
    await hear(store, h, peer)
    await upload(store, 2)
    await send(store, .rehydrate(entries: [], peers: [cachedPeer(dest, unhandled: [tid(2)])]))
    // The client's own link to the same node, already up.
    let clientLinkToPeer = Data(repeating: 0x22, count: 16)
    await send(store, .client(.endpoint(.delegate(.linkEstablished(linkID: clientLinkToPeer, destinationHash: dest)))))
    #expect(store.state.client.directLinks[dest] == clientLinkToPeer)

    await send(store, .peerSyncTick)
    #expect(opens(h.log) == [dest])
    #expect(!h.log.value.contains(.plainOpen(dest)))
    // A stale attempt of ours fails: the client's link is untouched.
    await send(store, .client(.endpoint(.delegate(.ownedLinkFailed(owner: .propagationPeerSync, destinationHash: dest,
                                                                   reason: .establishmentTimedOut)))))
    #expect(store.state.client.directLinks[dest] == clientLinkToPeer)
    #expect(store.state.client.router.directLinks[dest] == .active(linkID: clientLinkToPeer))

    h.now.setValue(t0 + 721)
    await send(store, .peerSyncTick)
    let syncLink = Data(repeating: 0x11, count: 16)
    await established(store, syncLink, dest)
    #expect(offers(h.log).first?.link == syncLink)
    #expect(store.state.client.directLinks[dest] == clientLinkToPeer)
    #expect(store.state.client.linkDestinations[syncLink] == nil)
    #expect(store.state.client.router.directLinks[dest] == .active(linkID: clientLinkToPeer))
}

/// Probe C / the stall bound: a slow sync keeps its link while the transfer moves (sender progress every
/// 100 s, far past the router's 600 s idle timer, which never applies to a sync link), and a sync that
/// stops moving is closed after `peerLinkStallTimeout` (720 s) and its peer idled.
@MainActor @Test func slowSyncKeepsItsLinkAndAStalledOneIsClosed() async {
    let h = Harness()
    let (store, dest, link) = await peerWithOfferOut(h)
    await respond(store, link, .bool(true))
    #expect(resources(h.log).count == 1)
    let hash = Data(repeating: 0x5E, count: 32)
    for step in 1...9 {
        await h.clock.advance(by: .seconds(100))
        await send(store, .client(.endpoint(.delegate(.resourceProgress(linkID: link, resourceHash: hash, role: .sender,
                                                                        bytesDone: step * 10, bytesTotal: 100,
                                                                        segment: 1, segments: 1)))))
    }
    #expect(closes(h.log).isEmpty)
    #expect(store.state.peering.peers[dest]?.state == .transferring)

    await h.clock.advance(by: .seconds(719))
    await store.skipReceivedActions(strict: false)
    #expect(closes(h.log).isEmpty)
    await h.clock.advance(by: .seconds(1))
    await store.skipReceivedActions(strict: false)
    #expect(closes(h.log) == [link])
    #expect(store.state.peering.peers[dest]?.state == .idle)
    #expect(store.state.peering.peers[dest]?.unhandled == [tid(2)])
}

/// M1: after node mode off and on, a link left over from before establishes alongside the new one: the
/// first to establish becomes the sync link and the other is closed, and the stale attempt failing does
/// not fail the current one.
@MainActor @Test func aStaleSyncLinkAfterNodeModeOffOnIsClosedNotKept() async {
    let h = Harness()
    let store = await makeStore(nodeState(Identity()), h, peeringKey: { _, _ in nil })
    let peer = Identity(), dest = propagationHash(peer)
    await hear(store, h, peer)
    await upload(store, 2)
    await send(store, .rehydrate(entries: [], peers: [cachedPeer(dest, unhandled: [tid(2)])]))
    await send(store, .peerSyncTick)                       // attempt 1
    await send(store, .setNodeMode(false))
    await send(store, .setNodeMode(true))
    h.now.setValue(t0 + 721)
    await send(store, .peerSyncTick)                       // attempt 2
    await send(store, .peerSyncTick)                       // attempt 3 is not made: one is establishing
    #expect(opens(h.log) == [dest, dest])
    #expect(store.state.peering.peers[dest]?.state == .linkEstablishing)

    // One of the two attempts fails: the other is still awaited.
    await send(store, .client(.endpoint(.delegate(.ownedLinkFailed(owner: .propagationPeerSync, destinationHash: dest,
                                                                   reason: .establishmentTimedOut)))))
    #expect(store.state.peering.peers[dest]?.state == .linkEstablishing)
    // Both then establish (a late stale one included): the first is used, the second closed.
    let first = Data(repeating: 0x11, count: 16), second = Data(repeating: 0x12, count: 16)
    await established(store, first, dest)
    await established(store, second, dest)
    #expect(offers(h.log).map(\.link) == [first])
    #expect(closes(h.log) == [second])
}

/// M2: a peer unpeered while its key search runs (here it announces its node disabled) has the search
/// cancelled, not left mining to completion for nobody.
@MainActor @Test func unpeeringAMiningPeerCancelsItsKeySearch() async {
    let h = Harness()
    let cancelled = LockIsolated(false)
    let store = await makeStore(nodeState(Identity()), h, peeringKey: { _, _ in
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
        cancelled.setValue(true)
        return nil
    })
    let peer = Identity(), dest = propagationHash(peer)
    await hear(store, h, peer)
    await upload(store, 2)
    await send(store, .peerSyncTick)
    #expect(store.state.peering.peers[dest]?.state == .keyPending)
    await hear(store, h, peer, announce: pnAnnounce(timebase: 2, nodeState: false))
    #expect(store.state.peering.peers[dest] == nil)
    for _ in 0..<200 where !cancelled.value { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(cancelled.value)
}

/// M3: a rehydrate that replaces a peer in the middle of a sync closes the link that peer held, instead
/// of forgetting it open.
@MainActor @Test func rehydrateMidSyncClosesTheReplacedPeersLink() async {
    let h = Harness()
    let (store, dest, link) = await peerWithOfferOut(h)
    await send(store, .rehydrate(entries: [], peers: [cachedPeer(dest, unhandled: [tid(2)])]))
    #expect(closes(h.log) == [link])
    #expect(store.state.peering.peers[dest]?.state == .idle)
    #expect(store.state.peering.peers[dest]?.linkID == nil)
}
