import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport
@testable import ReTiCAInterfaces

// The server half of propagation-node peering: `LXMFServiceNode` answers `/offer` as reference
// `LXMRouter.offer_request` does (LXMRouter.py:2601-2667), refuses a multi-message container on a link
// without a validated peering key (`propagation_resource_concluded`, :2716-2724), auto-peers with an
// unknown sender it can recall within `autopeerMaxDepth` (:2682-2714), and accounts each inbound sync
// in its `PNPeerTable`. Cross-validated by `Vectors/generate_lxmf_offer_responder_fixtures.py`
// (lxmf_offer_responder_fixtures.json).

/// The generator's output, as the tests read it.
enum OfferResponderFixtures {
    nonisolated(unsafe) static let json: [String: Any] = {
        let url = Bundle.module.url(forResource: "lxmf_offer_responder_fixtures", withExtension: "json")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    static func hex(_ any: Any?) -> Data { Data(hexString: any as! String)! }
    static func identity(_ key: String) -> Identity {
        Identity(privateKey: hex((json[key] as! [String: Any])["private_key"]))!
    }

    static let node8 = identity("node8")
    static let node18 = identity("node18")
    static let peer = identity("peer")
    static let peerPropHash = hex((json["peer"] as! [String: Any])["prop_hash"])
    static let otherPropHash = hex((json["other"] as! [String: Any])["prop_hash"])
    nonisolated(unsafe) static let constants = json["constants"] as! [String: Any]
    static let propagationCost = Double(constants["propagation_cost"] as! Int)
    static let propagationFlexibility = Double(constants["propagation_cost_flexibility"] as! Int)

    static func entry(_ label: String) -> Data {
        hex(((json["messages"] as! [String: Any])[label] as! [String: Any])["entry"])
    }
    static func tid(_ label: String) -> Data {
        hex(((json["messages"] as! [String: Any])[label] as! [String: Any])["tid"])
    }
    static let held: [Data] = (json["held"] as! [String]).map { Data(hexString: $0)! }

    struct Offer: Sendable, CustomTestStringConvertible {
        var name: String; var identified: Bool; var link: Data; var request: Data; var response: Data
        var validated: Bool
        var testDescription: String { name }
    }
    static let offers: [Offer] = (json["offers"] as! [[String: Any]]).map { o in
        Offer(name: o["name"] as! String, identified: o["identified"] as! Bool, link: hex(o["link"]),
              request: hex(o["request"]), response: hex(o["response"]), validated: o["validated"] as! Bool)
    }

    struct Resource: Sendable, CustomTestStringConvertible {
        var name: String; var link: Data; var container: Data
        var offerRequest: Data?; var offerResponse: Data?
        var tornDown: Bool; var stored: Set<Data>
        // Auto-peer cases only.
        var remotePrivateKey: Data?; var remoteHash: Data?; var appData: Data?; var hops: Int?
        var peered: Bool?; var handledByRemote: Bool?; var unhandledForOther: Bool?; var handledByOther: Bool?
        var testDescription: String { name }
    }
    static func resource(_ r: [String: Any]) -> Resource {
        func optionalHex(_ key: String) -> Data? { (r[key] as? String).map { Data(hexString: $0)! } }
        return Resource(name: r["name"] as! String, link: hex(r["link"]), container: hex(r["container"]),
                        offerRequest: optionalHex("offer_request"), offerResponse: optionalHex("offer_response"),
                        tornDown: r["torn_down"] as! Bool,
                        stored: Set((r["stored"] as! [String]).map { Data(hexString: $0)! }),
                        remotePrivateKey: optionalHex("remote_private_key"), remoteHash: optionalHex("remote_hash"),
                        appData: optionalHex("app_data"), hops: r["hops"] as? Int, peered: r["peered"] as? Bool,
                        handledByRemote: r["handled_by_remote"] as? Bool,
                        unhandledForOther: r["unhandled_for_other"] as? Bool,
                        handledByOther: r["handled_by_other"] as? Bool)
    }
    static let resources: [Resource] = (json["resources"] as! [[String: Any]]).map(resource)
    static let autopeers: [Resource] = (json["autopeers"] as! [[String: Any]]).map(resource)
    nonisolated(unsafe) static let rf4 = json["rf4"] as! [String: Any]
}

private typealias F = OfferResponderFixtures
private let offerPath = Crypto.truncatedHash(Data("/offer".utf8))
private let now = Date(timeIntervalSince1970: 1700000000.5)

/// What these tests look for among the actions `LXMFServiceNode` emits.
private enum Seen: Equatable, Sendable {
    case response(linkID: Data, requestID: Data, data: Data)
    case closeLink(Data)
}

private struct Recorded: Reducer {
    typealias State = LXMFServiceNode.State
    typealias Action = LXMFServiceNode.Action
    let log: LockIsolated<[Seen]>
    var body: some ReducerOf<Self> {
        Reduce { _, action in
            switch action {
            case let .client(.endpoint(.sendResponseOverLink(linkID, requestID, data))):
                log.withValue { $0.append(.response(linkID: linkID, requestID: requestID, data: data)) }
            case let .client(.endpoint(.closeLink(linkID))):
                log.withValue { $0.append(.closeLink(linkID)) }
            default: break
            }
            return .none
        }
        LXMFServiceNode()
    }
}

private func propagationHash(_ identity: Identity) -> Data {
    Destination.hash(identityHash: identity.hash, appName: LXMessage.appName, aspects: ["propagation"])
}

/// A node in node mode serving its propagation destination with the fixture routers' costs (accepts PN
/// stamps at max(0, 13 - 9) = 4), holding `held`, with `links` terminating on that destination.
private func nodeState(_ identity: Identity, peering: PNPeerTable.Config? = nil, held: [Data] = [],
                       links: [Data]) -> LXMFServiceNode.State {
    var s: LXMFServiceNode.State
    if let peering {
        s = LXMFServiceNode.State(identity: identity,
                                  endpoint: tcpDriverEndpoint(host: "h", port: 4242, reconnectOnDrop: false),
                                  targetStampCost: F.propagationCost, stampCostFlexibility: F.propagationFlexibility,
                                  peering: peering)
    } else {
        s = LXMFServiceNode.State(identity: identity,
                                  endpoint: tcpDriverEndpoint(host: "h", port: 4242, reconnectOnDrop: false),
                                  targetStampCost: F.propagationCost, stampCostFlexibility: F.propagationFlexibility)
    }
    s.nodeModeEnabled = true
    let served = propagationHash(identity)
    s.client.propagationDestinationHash = served
    for link in links { s.client.linkDestinations[link] = served }
    if !held.isEmpty {
        let (added, _) = s.pn.store.ingest(container: LXMFPropagation.container(timestamp: 1700000000, entries: held),
                                            now: now)
        precondition(added.count == held.count)
    }
    return s
}

@MainActor
private func makeStore(_ state: LXMFServiceNode.State, log: LockIsolated<[Seen]>) -> TestStoreOf<Recorded> {
    let store = TestStore(initialState: state) { Recorded(log: log) } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(now)
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

@MainActor
private func identify(_ store: TestStoreOf<Recorded>, _ link: Data, _ identity: Identity) async {
    await store.send(.client(.endpoint(.delegate(.linkIdentified(linkID: link, remoteIdentity: identity)))))
}

@MainActor
private func offer(_ store: TestStoreOf<Recorded>, _ link: Data, _ request: Data, requestID: Data = Data([0x0F])) async {
    await store.send(.client(.endpoint(.delegate(.requestReceived(linkID: link, requestID: requestID,
                                                                    pathHash: offerPath, data: request)))))
    await store.skipReceivedActions(strict: false)
}

@MainActor
private func push(_ store: TestStoreOf<Recorded>, _ link: Data, _ container: Data) async {
    await store.send(.client(.endpoint(.delegate(.resourceReceived(linkID: link, data: container)))))
    await store.skipReceivedActions(strict: false)
}

private func responses(_ log: LockIsolated<[Seen]>) -> [Data] {
    log.value.compactMap { if case let .response(_, _, data) = $0 { return data }; return nil }
}

private func closes(_ log: LockIsolated<[Seen]>) -> [Data] {
    log.value.compactMap { if case let .closeLink(link) = $0 { return link }; return nil }
}

/// A PN announce for a peer we already hold in the table.
private let otherAnnounce = PNAnnounce(timebase: 1, nodeState: true, perTransferLimit: 256, perSyncLimit: 10240,
                                       targetStampCost: 13, stampCostFlexibility: 9, peeringCost: 8)

// MARK: - /offer, one per reference case

/// Each `/offer` is answered with the bytes reference packs, at peering cost 8: no identity → 0xF0, a
/// key worth 7 → 0xF3, all held → `False`, none held → `True`, some held → the wanted ids. A validated
/// key marks the link validated; nothing else does.
///
/// One deliberate divergence, ruling 5b: a one-element list makes reference raise inside its `try`
/// (`type(data) != list and len(data) < 2` is false for a list, then `data[1]` raises) and answer
/// `None`; ReTiCA answers `ERROR_INVALID_DATA` for any body that is not an array of at least two
/// elements with a bin key. The fixture pins reference's `None` so the divergence stays visible.
@MainActor @Test(arguments: F.offers)
func offerResponsesMatchReference(_ c: OfferResponderFixtures.Offer) async {
    let log = LockIsolated<[Seen]>([])
    let store = makeStore(nodeState(F.node8, peering: .init(peeringCost: 8), held: F.held.map(entryFor),
                                    links: [c.link]), log: log)
    if c.identified { await identify(store, c.link, F.peer) }
    await offer(store, c.link, c.request, requestID: Data([0x42]))

    var expected = c.response
    if c.name == "malformed-one-element" {
        #expect(c.response == Data([0xC0]), "reference answers None here")
        expected = MsgPack.encode(.uint(LXMFPropagation.errorInvalidData))
    }
    #expect(log.value == [.response(linkID: c.link, requestID: Data([0x42]), data: expected)])
    #expect(store.state.validatedOfferLinks.contains(c.link) == c.validated)
}

private func entryFor(_ tid: Data) -> Data {
    for label in ["h1", "h2"] where F.tid(label) == tid { return F.entry(label) }
    fatalError("not a held id")
}

// MARK: - Resource conclusion, one per reference case

/// A container on a propagation link: two messages on an identified link with no validated key are
/// refused with a teardown and nothing stored; after a valid `/offer` on that link both are stored; a
/// single message from an unidentified client is stored. As reference's
/// `propagation_resource_concluded` does.
@MainActor @Test(arguments: F.resources)
func resourceConclusionsMatchReference(_ c: OfferResponderFixtures.Resource) async {
    let log = LockIsolated<[Seen]>([])
    let store = makeStore(nodeState(F.node8, peering: .init(peeringCost: 8), held: F.held.map(entryFor),
                                    links: [c.link]), log: log)
    if c.name != "unidentified-one-message" { await identify(store, c.link, F.peer) }
    if let request = c.offerRequest {
        await offer(store, c.link, request)
        #expect(responses(log) == [c.offerResponse!])
    }
    await push(store, c.link, c.container)

    #expect(closes(log).contains(c.link) == c.tornDown)
    let tids = LXMFPropagation.parseContainer(c.container)!.1.map { LXMFPropagation.transientId(lxmfData: Data($0.dropLast(32))) }
    #expect(Set(tids.filter { store.state.pn.store.contains(transientId: $0) }) == c.stored)
}

// MARK: - Auto-peer via incoming sync

/// A complete sync from an identified sender we have not peered with peers with it when its recalled
/// propagation announce is enabled and its path is within `autopeerMaxDepth` (6): depth 6 peers, depth 7
/// does not. Then the ids it sent are handled for it and unhandled for every other peer.
///
/// Hops: reference counts a hop on receipt, ReTiCA's learned path keeps the on-wire count (see
/// `Transport.receiptTimeoutBase`), so reference depth `d` is a learned `hops` of `d - 1`.
@MainActor @Test(arguments: F.autopeers)
func autoPeerViaIncomingSyncMatchesReference(_ c: OfferResponderFixtures.Resource) async throws {
    let remote = try #require(Identity(privateKey: c.remotePrivateKey!))
    #expect(propagationHash(remote) == c.remoteHash)
    let log = LockIsolated<[Seen]>([])
    var state = nodeState(F.node8, peering: .init(peeringCost: 8), links: [c.link])
    _ = state.peering.peer(F.otherPropHash, announce: otherAnnounce, now: now)
    state.client.endpoint.transport.learned[c.remoteHash!] = LearnedDestination(
        identity: remote, appData: c.appData, interfaceID: state.client.endpoint.tcpClients[0].interfaceID,
        hops: UInt8(c.hops! - 1), nextHop: nil, announceEmitted: 0)
    let store = makeStore(state, log: log)
    await identify(store, c.link, remote)
    await push(store, c.link, c.container)

    let tid = try #require(c.stored.first)
    #expect(store.state.pn.store.contains(transientId: tid))
    let peers = store.state.peering.peers
    #expect((peers[c.remoteHash!] != nil) == c.peered)
    #expect((peers[c.remoteHash!]?.handled.contains(tid) ?? false) == c.handledByRemote)
    #expect(peers[F.otherPropHash]?.unhandled.contains(tid) == c.unhandledForOther)
    #expect(peers[F.otherPropHash]?.handled.contains(tid) == c.handledByOther)
    #expect(closes(log).isEmpty == !c.tornDown)
}

// MARK: - Review Focus 4

/// Review Focus 4: a peer offers with a key worth 17 (between 17 and 18) while we demand the default 18.
/// It gets `ERROR_INVALID_KEY`, the link is not validated, and the two-message container it then
/// pushes on that link is refused with a teardown. Nothing is ingested.
@MainActor @Test func underCostKeyGetsInvalidKeyAndItsMultiEntryContainerIsRefused() async {
    let link = F.hex(F.rf4["link"])
    let log = LockIsolated<[Seen]>([])
    let store = makeStore(nodeState(F.node18, links: [link]), log: log)
    #expect(store.state.peering.config.peeringCost == 18)
    let value = F.rf4["key_value"] as! Double
    #expect(value >= 17 && value < 18)

    await identify(store, link, F.peer)
    await offer(store, link, F.hex(F.rf4["request"]))
    #expect(responses(log) == [F.hex(F.rf4["response"])])
    #expect(responses(log) == [MsgPack.encode(.uint(LXMFPropagation.errorInvalidKey))])
    #expect(!store.state.validatedOfferLinks.contains(link))

    await push(store, link, F.hex(F.rf4["container"]))
    #expect(F.rf4["torn_down"] as! Bool)
    #expect(closes(log) == [link])
    #expect(store.state.pn.store.count == 0)
    #expect((F.rf4["stored"] as! [String]).isEmpty)
}

// MARK: - Gates

/// `/offer` is a handler of the propagation destination only (reference registers it there,
/// LXMRouter.py:764), and nothing is served with node mode off. A valid offer on a link to some other
/// destination, and a valid offer with node mode off on an otherwise armed propagation link, get no
/// response and validate nothing.
@MainActor @Test func offerOnDeliveryLinkOrWithNodeModeOffIsIgnored() async {
    let valid = F.offers.first { $0.name == "none-held" }!
    let propagationLink = Data(repeating: 0xC1, count: 16)
    let deliveryLink = Data(repeating: 0xC2, count: 16)

    // Node mode on, the offer on a link to a destination we do not serve as a propagation node.
    let onLog = LockIsolated<[Seen]>([])
    var onState = nodeState(F.node8, peering: .init(peeringCost: 8), links: [propagationLink])
    onState.client.linkDestinations[deliveryLink] = Data(repeating: 0x5B, count: 16)
    let on = makeStore(onState, log: onLog)
    await identify(on, deliveryLink, F.peer)
    await offer(on, deliveryLink, valid.request)
    #expect(onLog.value.isEmpty)
    #expect(on.state.validatedOfferLinks.isEmpty)
    // The same offer on the propagation link is answered, so the gate is not blocking everything.
    await identify(on, propagationLink, F.peer)
    await offer(on, propagationLink, valid.request)
    #expect(responses(onLog) == [valid.response])

    // Node mode off, everything else armed: identity recorded, link on the propagation destination.
    let offLog = LockIsolated<[Seen]>([])
    var offState = nodeState(F.node8, peering: .init(peeringCost: 8), links: [propagationLink])
    offState.nodeModeEnabled = false
    offState.clientIdentities[propagationLink] = F.peer
    let off = makeStore(offState, log: offLog)
    await offer(off, propagationLink, valid.request)
    #expect(offLog.value.isEmpty)
    #expect(off.state.validatedOfferLinks.isEmpty)
}

// MARK: - Accounting

/// Ids a peer in the table sends us become handled for it and unhandled for every other peer
/// (`queue_handled_message` + `enqueue_peer_distribution(from_peer)`, LXMRouter.py:2765-2784, :2882, :2808-2824);
/// a client's upload (no peer) becomes unhandled for every peer.
@MainActor @Test func ingestFromPeerMarksItHandledForThatPeerAndUnhandledForOthers() async {
    let syncLink = Data(repeating: 0xC1, count: 16)
    let clientLink = Data(repeating: 0xC2, count: 16)
    let log = LockIsolated<[Seen]>([])
    var state = nodeState(F.node8, peering: .init(peeringCost: 8), links: [syncLink, clientLink])
    _ = state.peering.peer(F.peerPropHash, announce: otherAnnounce, now: now)
    _ = state.peering.peer(F.otherPropHash, announce: otherAnnounce, now: now)
    let store = makeStore(state, log: log)

    await identify(store, syncLink, F.peer)
    await offer(store, syncLink, F.offers.first { $0.name == "none-held" }!.request)
    await push(store, syncLink, LXMFPropagation.container(timestamp: 1700000000, entries: [F.entry("u1"), F.entry("u2")]))
    let synced: Set<Data> = [F.tid("u1"), F.tid("u2")]
    var peers = store.state.peering.peers
    #expect(peers[F.peerPropHash]!.handled.isSuperset(of: synced))
    #expect(peers[F.peerPropHash]!.unhandled.isDisjoint(with: synced))
    #expect(peers[F.otherPropHash]!.unhandled.isSuperset(of: synced))
    #expect(peers[F.otherPropHash]!.handled.isDisjoint(with: synced))

    // A client upload: single message, unidentified link. No peer sent it.
    await push(store, clientLink, LXMFPropagation.container(timestamp: 1700000000, entries: [F.entry("b1")]))
    peers = store.state.peering.peers
    #expect(store.state.pn.store.contains(transientId: F.tid("b1")))
    #expect(peers[F.peerPropHash]!.unhandled.contains(F.tid("b1")))
    #expect(peers[F.otherPropHash]!.unhandled.contains(F.tid("b1")))
    #expect(closes(log).isEmpty)
}

/// A client's single-entry upload needs no peering key, identified or not: reference refuses only
/// `len(messages) > 1` without one (LXMRouter.py:2721).
@MainActor @Test func clientSingleEntryUploadStillAcceptedWithoutKey() async {
    let identified = Data(repeating: 0xC1, count: 16)
    let anonymous = Data(repeating: 0xC2, count: 16)
    let log = LockIsolated<[Seen]>([])
    let store = makeStore(nodeState(F.node8, links: [identified, anonymous]), log: log)
    await identify(store, identified, Identity())
    await push(store, identified, LXMFPropagation.container(timestamp: 1700000000, entries: [F.entry("v1")]))
    await push(store, anonymous, LXMFPropagation.container(timestamp: 1700000000, entries: [F.entry("v2")]))
    #expect(store.state.pn.store.contains(transientId: F.tid("v1")))
    #expect(store.state.pn.store.contains(transientId: F.tid("v2")))
    #expect(closes(log).isEmpty)
    #expect(store.state.validatedOfferLinks.isEmpty)
}

/// A link's validation ends with the link: after it closes, a two-message container under the same
/// link id is refused as on any unvalidated link.
@MainActor @Test func offerValidationEndsWithTheLink() async {
    let link = Data(repeating: 0xC1, count: 16)
    let log = LockIsolated<[Seen]>([])
    let store = makeStore(nodeState(F.node8, peering: .init(peeringCost: 8), links: [link]), log: log)
    await identify(store, link, F.peer)
    await offer(store, link, F.offers.first { $0.name == "none-held" }!.request)
    #expect(store.state.validatedOfferLinks == [link])
    await store.send(.client(.endpoint(.delegate(.linkClosed(linkID: link, reason: .destinationClosed)))))
    #expect(store.state.validatedOfferLinks.isEmpty)
}

/// A peer that pushes us an entry we already hold, byte for byte, has it: reference marks every
/// validated id from a peer handled for it, duplicates included (`queue_handled_message` after each
/// `lxmf_propagation`, LXMRouter.py:2765-2784), so it is never offered back to that peer.
@MainActor @Test func peerRepushingAnIdenticalStoredEntryMarksItHandledForThatPeer() async {
    let syncLink = Data(repeating: 0xC1, count: 16)
    let log = LockIsolated<[Seen]>([])
    var state = nodeState(F.node8, peering: .init(peeringCost: 8), held: [F.entry("h1")], links: [syncLink])
    _ = state.peering.peer(F.peerPropHash, announce: otherAnnounce, now: now)
    state.peering.distribute([F.tid("h1")], from: nil)
    #expect(state.peering.peers[F.peerPropHash]!.unhandled == [F.tid("h1")])
    let store = makeStore(state, log: log)
    await identify(store, syncLink, F.peer)
    await push(store, syncLink, LXMFPropagation.container(timestamp: 1700000000, entries: [F.entry("h1")]))
    let p = store.state.peering.peers[F.peerPropHash]!
    #expect(p.handled.contains(F.tid("h1")))
    #expect(p.unhandled.isEmpty)
    #expect(closes(log).isEmpty)
}

/// Every store removal prunes the peer table (`PNPeerTable.prune(toStored:)` is mandatory after each):
/// an id a client confirms delivered, and an id evicted to make room for a new upload, leave every
/// peer's handled and unhandled sets.
@MainActor @Test func storeRemovalPrunesEveryPeer() async {
    let syncLink = Data(repeating: 0xC1, count: 16)
    let log = LockIsolated<[Seen]>([])
    var state = nodeState(F.node8, peering: .init(peeringCost: 8), links: [syncLink])
    _ = state.peering.peer(F.peerPropHash, announce: otherAnnounce, now: now)
    _ = state.peering.peer(F.otherPropHash, announce: otherAnnounce, now: now)
    let store = makeStore(state, log: log)
    await identify(store, syncLink, F.peer)
    await offer(store, syncLink, F.offers.first { $0.name == "none-held" }!.request)
    await push(store, syncLink, LXMFPropagation.container(timestamp: 1700000000, entries: [F.entry("u1"), F.entry("u2")]))
    #expect(store.state.peering.peers[F.otherPropHash]!.unhandled.contains(F.tid("u1")))

    await store.send(.pn(.messagesDelivered(transientIds: [F.tid("u1")])))
    await store.skipReceivedActions(strict: false)
    let peers = store.state.peering.peers
    #expect(!peers[F.peerPropHash]!.handled.contains(F.tid("u1")))
    #expect(!peers[F.otherPropHash]!.unhandled.contains(F.tid("u1")))
    #expect(peers[F.otherPropHash]!.unhandled.contains(F.tid("u2")))

    // Eviction: a store with room for two entries takes a client's upload and evicts the oldest.
    let (u1, u2, b1) = (F.entry("u1"), F.entry("u2"), F.entry("b1"))
    let clientLink = Data(repeating: 0xC2, count: 16)
    var small = nodeState(F.node8, peering: .init(peeringCost: 8), links: [syncLink, clientLink])
    small.pn.store.storageLimitBytes = max(u1.count + u2.count, u2.count + b1.count)
    _ = small.peering.peer(F.peerPropHash, announce: otherAnnounce, now: now)
    _ = small.peering.peer(F.otherPropHash, announce: otherAnnounce, now: now)
    let evicting = makeStore(small, log: LockIsolated<[Seen]>([]))
    await identify(evicting, syncLink, F.peer)
    await offer(evicting, syncLink, F.offers.first { $0.name == "none-held" }!.request)
    await push(evicting, syncLink, LXMFPropagation.container(timestamp: 1700000000, entries: [u1, u2]))
    #expect(evicting.state.peering.peers[F.peerPropHash]!.handled.contains(F.tid("u1")))
    #expect(evicting.state.peering.peers[F.otherPropHash]!.unhandled.contains(F.tid("u1")))
    await push(evicting, clientLink, LXMFPropagation.container(timestamp: 1700000000, entries: [b1]))
    #expect(!evicting.state.pn.store.contains(transientId: F.tid("u1")))
    #expect(evicting.state.pn.store.contains(transientId: F.tid("b1")))
    let after = evicting.state.peering.peers
    #expect(!after[F.peerPropHash]!.handled.contains(F.tid("u1")))
    #expect(!after[F.otherPropHash]!.unhandled.contains(F.tid("u1")))
    #expect(after[F.otherPropHash]!.unhandled.contains(F.tid("b1")))
}

// MARK: - Announce

/// The propagation announce advertises the peering cost this node validates keys at: lxmd's default 18
/// (LXMRouter.py:63), or whatever the host configured.
@MainActor @Test func announceAdvertisesPeeringCost18() async {
    for (config, expected) in [(PNPeerTable.Config?.none, 18.0), (PNPeerTable.Config(peeringCost: 8), 8.0)] {
        let log = LockIsolated<[Seen]>([])
        let store = makeStore(nodeState(F.node8, peering: config, links: []), log: log)
        let captured = LockIsolated<Data?>(nil)
        await store.send(.registerPropagation)
        await store.receive { action in
            if case let .client(.endpoint(.announce(_, appData))) = action { captured.setValue(appData); return true }
            return false
        }
        #expect(PNAnnounce.parse(captured.value ?? Data())?.peeringCost == expected)
    }
}
