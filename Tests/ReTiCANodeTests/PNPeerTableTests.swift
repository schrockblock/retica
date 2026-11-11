import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport
@testable import ReTiCAInterfaces

// `PNPeerTable`, the propagation-node peer state machine, replayed step by step against a real LXMF
// 1.3.0 `LXMRouter` / `LXMPeer` by `Vectors/generate_lxmf_peer_state_fixtures.py`
// (lxmf_peer_state_fixtures.json). Each test plays the host: it feeds the table the same events the
// generator fed reference, then compares the commands and every peer's state with what reference did.
//
// Where reference does something the table splits differently, the host here does what
// `LXMFServiceNode` will do, and the comparison says so:
//   - reference checks for a path inside `sync()` and sleeps 7.5 s; the table emits `.openLink` and the
//     host, finding no path, requests one, waits `pathRequestGrace` and calls `linkFailed`.
//   - after `linkEstablished` / a no-identity response leaves a peer in `.linkReady`, the host calls
//     `offerSelected` with the selection reference computed inside `sync()` (the selection itself is
//     cross-validated against reference in PNOfferLimitsCrossValidationTests).
//   - where reference strands a peer with its link open (throttled or no-access responses), the table
//     closes the link: one extra `.closeLink` (see `PNPeerTable.offerResponse`).

enum PeerStateFixtures {
    nonisolated(unsafe) static let json: [String: Any] = {
        let url = Bundle.module.url(forResource: "lxmf_peer_state_fixtures", withExtension: "json")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    static func hex(_ any: Any?) -> Data { Data(hexString: any as! String)! }
    static let t0 = json["t0"] as! Double
    static let key = hex(json["key"])
    static let peers = (json["peers"] as! [String]).map { Data(hexString: $0)! }
    static let tids = (json["tids"] as! [String]).map { Data(hexString: $0)! }
    nonisolated(unsafe) static let cases: [String: [String: Any]] = {
        var out: [String: [String: Any]] = [:]
        for c in json["cases"] as! [[String: Any]] { out[c["name"] as! String] = c }
        return out
    }()
    static func names(_ prefix: String) -> [String] { cases.keys.filter { $0.hasPrefix(prefix) }.sorted() }
}

/// A command as both sides can say it: by peer, not by link.
enum SeenCommand: Equatable, CustomStringConvertible {
    case openLink(Data), identify(Data), offer(Data, [Data]), resource(Data, [Data])
    case teardown(Data), requestPath(Data), generateKey(Data)

    var description: String {
        func h(_ d: Data) -> String { d.prefix(3).map { String(format: "%02x", $0) }.joined() }
        switch self {
        case let .openLink(p): return "openLink(\(h(p)))"
        case let .identify(p): return "identify(\(h(p)))"
        case let .offer(p, ids): return "offer(\(h(p)), \(ids.map(h)))"
        case let .resource(p, ids): return "resource(\(h(p)), \(ids.map(h)))"
        case let .teardown(p): return "teardown(\(h(p)))"
        case let .requestPath(p): return "requestPath(\(h(p)))"
        case let .generateKey(p): return "generateKey(\(h(p)))"
        }
    }

    init(reference c: [String: Any]) {
        let p = PeerStateFixtures.hex(c["peer"])
        let ids = (c["ids"] as? [String])?.map { Data(hexString: $0)! } ?? []
        switch c["kind"] as! String {
        case "open_link": self = .openLink(p)
        case "identify": self = .identify(p)
        case "offer": self = .offer(p, ids)
        case "resource": self = .resource(p, ids)
        case "teardown": self = .teardown(p)
        case "request_path": self = .requestPath(p)
        case "generate_key": self = .generateKey(p)
        default: fatalError("unknown reference command \(c)")
        }
    }

    var isTeardown: Bool { if case .teardown = self { return true }; return false }
}

/// Answers `next()` with the scripted values in turn: the table picks `value % pool.count`, so a
/// value below the pool size is reference's `randint` result.
struct ScriptedRandom: RandomNumberGenerator {
    var values: [UInt64]
    mutating func next() -> UInt64 { values.removeFirst() }
}

/// The host side of the replay: assigns link ids, translates commands, and plays the host's part
/// where the table hands work back.
struct PeerTableHost {
    var table: PNPeerTable
    var now: Date
    var linkPeer: [Data: Data] = [:]      // link id → peer
    var currentLink: [Data: Data] = [:]   // peer → its latest link id
    var nextLink: UInt8 = 0

    mutating func translate(_ commands: [PNPeerTable.Command]) -> [SeenCommand] {
        commands.map { c in
            switch c {
            case let .openLink(p):
                nextLink += 1
                let id = Data(repeating: nextLink, count: 16)
                linkPeer[id] = p; currentLink[p] = id
                return .openLink(p)
            case let .identify(l): return .identify(linkPeer[l]!)
            case let .sendOffer(l, key, ids):
                #expect(key == PeerStateFixtures.key)
                return .offer(linkPeer[l]!, ids)
            case let .sendResource(l, ids): return .resource(linkPeer[l]!, ids)
            case let .closeLink(l): return .teardown(linkPeer[l]!)
            case let .requestPath(p): return .requestPath(p)
            case let .generatePeeringKey(p, cost):
                #expect(cost == table.peers[p]?.announce?.peeringCost)
                return .generateKey(p)
            }
        }
    }

    /// The host's half of an offer: when the table leaves the peer link-ready, offer the selection.
    mutating func offerIfReady(_ peer: Data, _ step: [String: Any]) -> [PNPeerTable.Command] {
        guard table.peers[peer]?.state == .linkReady else { return [] }
        let sel = step["selection"] as! [String: Any]
        func ids(_ k: String) -> [Data] { (sel[k] as! [String]).map { Data(hexString: $0)! } }
        return table.offerSelected(peer: peer, offer: ids("offer"), oversized: ids("oversized"),
                                   lowValue: ids("low_value"), purged: [], now: now)
    }
}

private func announce(_ s: [String: Any]) -> PNAnnounce {
    PNAnnounce(timebase: s["timebase"] as! Int, nodeState: s["node_state"] as? Bool ?? true,
               perTransferLimit: s["transfer_kb"] as? Int ?? 256, perSyncLimit: s["sync_kb"] as? Int ?? 10240,
               targetStampCost: s["stamp_cost"] as? Double ?? 16, stampCostFlexibility: s["flexibility"] as? Double ?? 3,
               peeringCost: s["peering_cost"] as? Double ?? 18)
}

private func date(_ any: Any?) -> Date { Date(timeIntervalSince1970: (any as! NSNumber).doubleValue) }
private func ids(_ any: Any?) -> [Data] { (any as! [Int]).map { PeerStateFixtures.tids[$0] } }

/// Replays one fixture case and compares every step.
private func replay(_ name: String) {
    let c = PeerStateFixtures.cases[name]!
    let statics = Set((c["static"] as! [String]).map { Data(hexString: $0)! })
    var host = PeerTableHost(table: PNPeerTable(config: .init(maxPeers: c["max_peers"] as! Int, staticPeers: statics)),
                             now: Date(timeIntervalSince1970: PeerStateFixtures.t0))
    let P = PeerStateFixtures.peers
    for (index, step) in (c["steps"] as! [[String: Any]]).enumerated() {
        let op = step["op"] as! String
        let peer = (step["peer"] as? Int).map { P[$0] }
        var commands: [SeenCommand] = []
        var expected = (step["commands"] as! [[String: Any]]).map(SeenCommand.init(reference:))
        switch op {
        case "activate_static":
            commands = host.translate(host.table.activateStaticPeers(now: host.now))
        case "announce":
            for i in step["who"] as! [Int] {
                commands += host.translate(host.table.announceHeard(
                    P[i], announce: announce(step), hops: UInt8(step["hops"] as? Int ?? 1),
                    isPathResponse: step["path_response"] as? Bool ?? false, now: host.now))
            }
        case "advance":
            host.now += (step["seconds"] as! NSNumber).doubleValue
        case "distribute":
            host.table.distribute(ids(step["ids"]), from: (step["from"] as? Int).map { P[$0] })
        case "mark_handled":
            host.table.markHandled(ids(step["ids"]), for: peer!)
        case "key_ready":
            commands = host.translate(host.table.keyReady(peer: peer!, key: PeerStateFixtures.key,
                                                          value: (step["value"] as! NSNumber).doubleValue, now: host.now))
        case "sync_tick":
            var random = ScriptedRandom(values: (step["randint"] as? [Int] ?? []).map(UInt64.init))
            let raw = host.table.syncTick(now: host.now, random: &random)
            #expect(random.values.isEmpty, "\(name) step \(index): the table drew fewer random values than reference")
            if step["has_path"] as? Bool == false {
                // No path: the host requests one, waits the grace period and reports the failure.
                for cmd in raw {
                    if case let .openLink(p) = cmd {
                        commands.append(.requestPath(p))
                        host.now += PNPeerTable.pathRequestGrace
                        host.table.linkFailed(peer: p, now: host.now)
                    } else { commands += host.translate([cmd]) }
                }
            } else {
                commands = host.translate(raw)
            }
        case "link_established":
            var raw = host.table.linkEstablished(peer: peer!, linkID: host.currentLink[peer!]!, now: host.now)
            raw += host.offerIfReady(peer!, step)
            commands = host.translate(raw)
        case "offer_response":
            let link = host.currentLink[peer!]!
            let offered = host.table.peers[peer!]!.lastOffer
            let response = PNPeerTable.OfferResponse.parse(Data(hexString: step["response"] as! String)!, offered: offered)
            var raw = host.table.offerResponse(linkID: link, response, now: host.now)
            raw += host.offerIfReady(peer!, step)
            commands = host.translate(raw)
            // Reference strands the peer with its link open; the table closes it.
            let after = (step["peers"] as! [[String: Any]]).first { PeerStateFixtures.hex($0["dest"]) == peer! }
            if !expected.contains(where: \.isTeardown), after == nil || after?["state"] as? Int == 4 {
                expected.append(.teardown(peer!))
            }
        case "resource_concluded":
            let link = host.currentLink[peer!]!
            if step["status"] as! String == "complete" {
                commands = host.translate(host.table.transferConcluded(linkID: link, bytes: step["transfer_size"] as! Int,
                                                                       now: host.now))
            } else {
                commands = host.translate(host.table.transferFailed(linkID: link))
            }
        case "request_failed":
            commands = host.translate(host.table.requestFailed(linkID: host.currentLink[peer!]!))
        case "link_closed":
            host.table.linkClosed(linkID: host.currentLink[peer!]!)
        case "rehydrate":
            // Transient fields set to junk: reference's from_bytes starts them afresh.
            let loaded = (step["load"] as! [[String: Any]]).map { d -> PNPeerTable.Peer in
                PNPeerTable.Peer(destinationHash: P[d["peer"] as! Int], peeringTimebase: d["timebase"] as? Int ?? 0,
                                 alive: d["alive"] as? Bool ?? true,
                                 lastHeard: d["last_heard"].map(date) ?? host.now,
                                 lastSyncAttempt: nil, nextSyncAttempt: host.now + 9999, syncBackoff: 1440,
                                 syncTransferRate: (d["rate"] as? NSNumber)?.doubleValue ?? 0,
                                 announce: PNAnnounce(timebase: 0, nodeState: true, perTransferLimit: 256,
                                                      perSyncLimit: 10240, targetStampCost: 16,
                                                      stampCostFlexibility: 3, peeringCost: 18),
                                 peeringKey: PeerStateFixtures.key, peeringKeyValue: 18,
                                 state: .transferring, linkID: Data(repeating: 0xEE, count: 16),
                                 handled: Set(ids(d["handled"] ?? [Int]())), unhandled: Set(ids(d["unhandled"] ?? [Int]())),
                                 lastOffer: [PeerStateFixtures.tids[9]], transferring: [PeerStateFixtures.tids[9]])
            }
            host.table.rehydrate(loaded, stored: Set(PeerStateFixtures.tids))
        default:
            Issue.record("unknown op \(op)")
        }
        let label = "\(name) step \(index) (\(op))"
        #expect(commands == expected, "\(label): commands")
        #expect(abs(host.now.timeIntervalSince1970 - (step["now"] as! NSNumber).doubleValue) < 1e-6, "\(label): clock")
        comparePeers(host.table, step["peers"] as! [[String: Any]], label)
    }
}

private func comparePeers(_ table: PNPeerTable, _ reference: [[String: Any]], _ label: String) {
    #expect(table.persisted.map(\.destinationHash) == reference.map { PeerStateFixtures.hex($0["dest"]) },
            "\(label): peers and their order")
    for r in reference {
        let dest = PeerStateFixtures.hex(r["dest"])
        guard let p = table.peers[dest] else { continue }
        func near(_ a: Double, _ b: Any?) -> Bool { abs(a - (b as! NSNumber).doubleValue) < 1e-6 }
        func hexes(_ any: Any?) -> [Data] { (any as! [String]).map { Data(hexString: $0)! } }
        #expect(p.peeringTimebase == r["timebase"] as! Int, "\(label): timebase")
        #expect(p.alive == r["alive"] as! Bool, "\(label): alive")
        #expect(near(p.lastHeard.timeIntervalSince1970, r["last_heard"]), "\(label): last_heard")
        #expect(near(p.lastSyncAttempt?.timeIntervalSince1970 ?? 0, r["last_sync_attempt"]), "\(label): last_sync_attempt")
        #expect(near(p.nextSyncAttempt.timeIntervalSince1970, r["next_sync_attempt"]), "\(label): next_sync_attempt")
        #expect(near(p.syncBackoff, r["sync_backoff"]), "\(label): sync_backoff")
        #expect(abs(p.syncTransferRate - (r["rate"] as! NSNumber).doubleValue) < 1e-3, "\(label): rate")
        let states: [Int: Set<PNPeerTable.PeerState>] = [0: [.idle, .keyPending], 1: [.linkEstablishing],
                                                          2: [.linkReady], 3: [.requestSent], 4: [.idle],
                                                          5: [.transferring]]
        #expect(states[r["state"] as! Int]?.contains(p.state) == true, "\(label): state \(p.state) vs \(r["state"]!)")
        #expect(p.handled == Set(hexes(r["handled"])), "\(label): handled")
        #expect(p.unhandled == Set(hexes(r["unhandled"])), "\(label): unhandled")
        #expect(p.lastOffer == hexes(r["last_offer"]), "\(label): last_offer")
        #expect(p.transferring == (r["transferring"] is NSNull ? nil : hexes(r["transferring"])), "\(label): transferring")
        #expect(p.offered == r["offered"] as! Int && p.outgoing == r["outgoing"] as! Int
                && p.incoming == r["incoming"] as! Int, "\(label): counters")
        if r["peering_cost"] is NSNull {
            #expect(p.announce == nil, "\(label): costs unknown")
        } else {
            #expect(p.announce.map { near($0.peeringCost, r["peering_cost"]) } == true, "\(label): peering cost")
            #expect(p.announce.map { near($0.targetStampCost, r["stamp_cost"]) && near($0.stampCostFlexibility, r["flexibility"]) } == true,
                    "\(label): stamp costs")
            #expect(p.announce.map { near(Double($0.perTransferLimit), r["transfer_limit"]) && near(Double($0.perSyncLimit), r["sync_limit"]) } == true,
                    "\(label): limits")
        }
        if r["key_value"] is NSNull {
            #expect(p.peeringKey == nil && p.peeringKeyValue == nil, "\(label): no key")
        } else {
            #expect(p.peeringKeyValue.map { near($0, r["key_value"]) } == true && p.peeringKey != nil, "\(label): key")
        }
    }
}

// MARK: - Fixture groups

@Test(arguments: ["announce_depth", "static_peer", "unpeer_node_state", "peering_cost", "max_peers",
                  "static_counts_toward_max_peers"])
func peerTableAnnouncesMatchReference(_ name: String) { replay(name) }

@Test(arguments: ["distribute"])
func peerTableDistributionMatchesReference(_ name: String) { replay(name) }

@Test(arguments: PeerStateFixtures.names("offer_"))
func peerTableOfferResponsesMatchReference(_ name: String) { replay(name) }

@Test(arguments: ["persistent_resync", "key_regeneration"])
func peerTableSyncLifecycleMatchesReference(_ name: String) { replay(name) }

@Test(arguments: ["cull"])
func peerTableCullMatchesReference(_ name: String) { replay(name) }

@Test(arguments: ["selection", "selection_unknown_speed", "no_path"])
func peerTableSelectionMatchesReference(_ name: String) { replay(name) }

// MARK: - Parser and shared pieces

@Test func offerResponseParseCoversEveryWireForm() {
    let a = Data(repeating: 0xA, count: 32), b = Data(repeating: 0xB, count: 32), c = Data(repeating: 0xC, count: 32)
    let offered = [a, b, c]
    func parse(_ v: MsgPackValue) -> PNPeerTable.OfferResponse { .parse(MsgPack.encode(v), offered: offered) }
    #expect(parse(.uint(0xF0)) == .noIdentity)
    #expect(parse(.uint(0xF1)) == .noAccess)
    #expect(parse(.uint(0xF6)) == .throttled)
    #expect(parse(.bool(false)) == .wantsNone)
    #expect(parse(.bool(true)) == .wantsAll)
    // Offered ids only, in the response's order, each once (final review I1: reference sends one copy
    // per listed id, LXMPeer.py:455-457, which lets a peer multiply our container without bound).
    #expect(parse(.array([.bin(c), .bin(Data(repeating: 9, count: 32)), .bin(a), .string("x"), .bin(c)])) == .wants([c, a]))
    #expect(parse(.array(Array(repeating: .bin(b), count: 500) + [.bin(a), .bin(b)])) == .wants([b, a]))
    #expect(parse(.array([])) == .wants([]))
    #expect(parse(.uint(0xF3)) == .other)
    #expect(parse(.uint(0xF4)) == .other)
    #expect(parse(.null) == .other)
    #expect(PNPeerTable.OfferResponse.parse(Data([0xC1]), offered: offered) == .other)
}

private func entryData(_ tag: Int) -> Data {
    let label = Data("among-\(tag)-".utf8)
    return Data(repeating: 0xAB, count: 16) + label + Data(repeating: 0x5A, count: 200 - 16 - label.count)
}

@Test func offerCandidatesAmongRestrictsToTheGivenIds() {
    var store = PropagationStore(targetStampCost: 0)
    var tids: [Data] = []
    for i in 0..<4 {
        let added = store.ingest(container: LXMFPropagation.container(timestamp: 0, entries: [entryData(i)]),
                                 now: Date(timeIntervalSince1970: 1_700_000_000)).added
        tids += added
    }
    #expect(tids.count == 4)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let all = store.offerCandidates(acceptedAt: 0, transferLimitKB: nil, syncLimitKB: nil, excluding: [], now: now)
    #expect(all.offer == tids)                                       // nil: today's behaviour
    let among = store.offerCandidates(acceptedAt: 0, transferLimitKB: nil, syncLimitKB: nil,
                                      among: [tids[1], tids[3], Data(repeating: 7, count: 32)],
                                      excluding: [tids[3]], now: now)
    #expect(among.offer == [tids[1]])
    #expect(among.oversized.isEmpty && among.lowValue.isEmpty)
}

/// PNNode's response arm now goes through `OfferResponse.parse`: the error codes, which it never
/// answered, still send nothing and mark nothing (its other forms are pinned by the PNNode suites).
@Test(arguments: [MsgPackValue.uint(0xF0), .uint(0xF1), .uint(0xF6), .uint(0xF3), .null, .string("x")])
@MainActor func pnNodeOfferResponseUnchanged(_ response: MsgPackValue) async {
    let linkID = Data(repeating: 0xD1, count: 16)
    let peer = Data(repeating: 0x77, count: 16)
    var initial = PNNode.State(identity: Identity(), endpoint: TCPEndpoint.State(host: "pn", port: 4242, reconnectOnDrop: false))
    initial.offerLinks[linkID] = [Data(repeating: 0x11, count: 32)]
    initial.offerLinkPeers[linkID] = peer
    let store = TestStore(initialState: initial) { PNNode() } withDependencies: {
        $0.continuousClock = TestClock(); $0.date = .constant(Date(timeIntervalSince1970: 1700000000)); $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.endpoint(.delegate(.responseReceived(linkID: linkID, requestID: Data([1]),
                                                           data: MsgPack.encode(response)))))
    #expect(store.state.handledByPeer[peer] == nil)
    #expect(store.state.syncTransfers[linkID] == nil)
    #expect(store.state.offerLinks[linkID] == nil)
    store.exhaustivity = .on   // a stray sendResourceOverLink would fail teardown
}

// MARK: - Table behaviour outside the fixtures

private let pA = Data(repeating: 0xA1, count: 16)
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private func ann(_ tb: Int, cost: Double = 18) -> PNAnnounce {
    PNAnnounce(timebase: tb, nodeState: true, perTransferLimit: 256, perSyncLimit: 10240,
               targetStampCost: 16, stampCostFlexibility: 3, peeringCost: cost)
}

private let idX = Data(repeating: 1, count: 32)
private let key9 = Data(repeating: 9, count: 32)

/// A peer with `idX` unhandled and a ready key.
private func readyTable() -> PNPeerTable {
    var table = PNPeerTable(config: .init())
    _ = table.peer(pA, announce: ann(100), now: t0)
    table.distribute([idX], from: nil)
    _ = table.keyReady(peer: pA, key: key9, value: 18, now: t0)
    return table
}

/// Opens and establishes `pA`'s sync link from a tick at `now`; returns the link id.
private func establish(_ table: inout PNPeerTable, now: Date, link: Data = Data(repeating: 0x55, count: 16)) -> Data {
    var random = ScriptedRandom(values: [0])
    #expect(table.syncTick(now: now, random: &random) == [.openLink(pA)])
    #expect(table.linkEstablished(peer: pA, linkID: link, now: now + 1) == [.identify(linkID: link)])
    return link
}

/// Fix round 1, ruling 1: an empty offer with unhandled ids left (the sync limit skipped them, or the
/// store dropped them and nobody pruned) used to reopen a link every tick. Five 24 s ticks now open at
/// most one link. With `purged` passed, the dropped id leaves `unhandled` at once.
@Test(arguments: [false, true])
func emptyOfferProbeOpensAtMostOneLinkInFiveTicks(_ passPurged: Bool) {
    var table = readyTable()
    var opened = 0
    var now = t0
    for _ in 0..<5 {
        now += PNPeerTable.peerSyncInterval
        var random = ScriptedRandom(values: [0])
        let commands = table.syncTick(now: now, random: &random)
        guard commands == [.openLink(pA)] else { continue }
        opened += 1
        let link = Data(repeating: UInt8(opened), count: 16)
        _ = table.linkEstablished(peer: pA, linkID: link, now: now)
        #expect(table.offerSelected(peer: pA, offer: [], oversized: [], lowValue: [],
                                    purged: passPurged ? [idX] : [], now: now) == [.closeLink(link)])
    }
    #expect(opened == 1)
    #expect(table.peers[pA]!.unhandled == (passPurged ? [] : [idX]))
}

/// Ruling 2: a link that ends before establishment is reported by destination with `linkFailed`; an
/// unknown link id in `linkClosed` is harmless. The peer is retried once the backoff passes.
@Test func establishingThenFailedPeerIsRetriedAfterBackoff() {
    var table = readyTable()
    var random = ScriptedRandom(values: [0, 0])
    #expect(table.syncTick(now: t0 + 24, random: &random) == [.openLink(pA)])
    let before = table
    table.linkClosed(linkID: Data(repeating: 0x99, count: 16))
    #expect(table == before)
    table.linkFailed(peer: pA, now: t0 + 40)
    #expect(table.peers[pA]!.state == .idle && !table.peers[pA]!.alive)
    #expect(table.syncTick(now: t0 + 48, random: &random) == [])                      // in backoff
    #expect(table.syncTick(now: t0 + 40 + PNPeerTable.syncBackoffStep + 1, random: &random) == [.openLink(pA)])
    #expect(random.values.isEmpty)
}

/// Ruling 3: a failed key search returns the peer to idle with a backoff step; it is asked again
/// only after the backoff.
@Test func keyFailedReturnsThePeerToIdleWithBackoff() {
    var table = PNPeerTable(config: .init())
    _ = table.peer(pA, announce: ann(100), now: t0)
    table.distribute([idX], from: nil)
    var random = ScriptedRandom(values: [0, 0, 0])
    #expect(table.syncTick(now: t0 + 24, random: &random) == [.generatePeeringKey(peer: pA, cost: 18)])
    table.keyFailed(peer: pA, now: t0 + 30)
    #expect(table.peers[pA]!.state == .idle)
    #expect(table.peers[pA]!.nextSyncAttempt == t0 + 30 + PNPeerTable.syncBackoffStep)
    #expect(table.syncTick(now: t0 + 48, random: &random) == [])
    #expect(table.syncTick(now: t0 + 30 + PNPeerTable.syncBackoffStep + 1, random: &random)
            == [.generatePeeringKey(peer: pA, cost: 18)])
}

/// Ruling 4: unpeering a peer mid-transfer closes its link, and the transfer's later outcome finds
/// no peer.
@Test func unpeerMidTransferClosesItsLink() {
    var table = readyTable()
    let link = establish(&table, now: t0 + 24)
    #expect(table.offerSelected(peer: pA, offer: [idX], oversized: [], lowValue: [], purged: [], now: t0 + 25)
            == [.sendOffer(linkID: link, key: key9, ids: [idX])])
    #expect(table.offerResponse(linkID: link, .wantsAll, now: t0 + 26) == [.sendResource(linkID: link, ids: [idX])])
    var off = ann(200); off.nodeState = false
    #expect(table.announceHeard(pA, announce: off, hops: 1, isPathResponse: false, now: t0 + 27) == [.closeLink(link)])
    #expect(table.peers.isEmpty)
    #expect(table.transferConcluded(linkID: link, bytes: 100, now: t0 + 28) == [])
}

/// Ruling 4: the 14-day cull closes a link the culled peer still held.
@Test func cullClosesALinkTheCulledPeerHeld() {
    var table = readyTable()
    let link = establish(&table, now: t0 + 24)
    var random = ScriptedRandom(values: [])
    #expect(table.syncTick(now: t0 + PNPeerTable.maxUnreachable + 100, random: &random) == [.closeLink(link)])
    #expect(table.peers.isEmpty)
}

@Test func persistedRoundTripsThroughRehydratePruningToTheStore() {
    var table = PNPeerTable(config: .init())
    _ = table.peer(pA, announce: ann(100), now: t0)
    let x = Data(repeating: 1, count: 32), y = Data(repeating: 2, count: 32), z = Data(repeating: 3, count: 32)
    table.distribute([x, y], from: nil)
    table.markHandled([z], for: pA)
    _ = table.keyReady(peer: pA, key: Data(repeating: 9, count: 32), value: 18.5, now: t0)
    var restored = PNPeerTable(config: .init())
    restored.rehydrate(table.persisted, stored: [x, z])
    let p = restored.peers[pA]!
    #expect(p.unhandled == [x] && p.handled == [z])
    #expect(p.peeringKey == Data(repeating: 9, count: 32) && p.peeringKeyValue == 18.5)
    #expect(p.announce == ann(100) && p.lastHeard == t0 && p.alive)
}

@Test func pruneDropsIdsTheStoreNoLongerHolds() {
    var table = PNPeerTable(config: .init())
    _ = table.peer(pA, announce: ann(100), now: t0)
    let x = Data(repeating: 1, count: 32), y = Data(repeating: 2, count: 32)
    table.distribute([x, y], from: nil)
    table.markHandled([y], for: pA)
    table.prune(toStored: [x])
    #expect(table.peers[pA]!.unhandled == [x] && table.peers[pA]!.handled.isEmpty)
}

@Test func emptyOfferClosesTheLinkRatherThanStrandingThePeer() {
    var table = PNPeerTable(config: .init())
    _ = table.peer(pA, announce: ann(100), now: t0)
    table.distribute([Data(repeating: 1, count: 32)], from: nil)
    _ = table.keyReady(peer: pA, key: Data(repeating: 9, count: 32), value: 18, now: t0)
    var random = ScriptedRandom(values: [0])
    #expect(table.syncTick(now: t0 + 1, random: &random) == [.openLink(pA)])
    let link = Data(repeating: 0x55, count: 16)
    #expect(table.linkEstablished(peer: pA, linkID: link, now: t0 + 2) == [.identify(linkID: link)])
    #expect(table.offerSelected(peer: pA, offer: [], oversized: [], lowValue: [Data(repeating: 1, count: 32)], purged: [], now: t0 + 3)
            == [.closeLink(link)])
    #expect(table.peers[pA]!.state == .idle && table.peers[pA]!.linkID == nil)
    #expect(table.peers[pA]!.unhandled.isEmpty)
}

@Test func keyPendingIsNotRequestedTwiceAndAnUnderCostKeyIsRefused() {
    var table = PNPeerTable(config: .init())
    _ = table.peer(pA, announce: ann(100), now: t0)
    table.distribute([Data(repeating: 1, count: 32)], from: nil)
    var random = ScriptedRandom(values: [0, 0, 0])
    #expect(table.syncTick(now: t0 + 1, random: &random) == [.generatePeeringKey(peer: pA, cost: 18)])
    #expect(table.peers[pA]!.state == .keyPending)
    #expect(table.syncTick(now: t0 + 25, random: &random) == [])     // still searching
    _ = table.keyReady(peer: pA, key: Data(repeating: 9, count: 32), value: 17, now: t0 + 30)
    #expect(table.peers[pA]!.peeringKey == nil && table.peers[pA]!.state == .idle)
    #expect(table.syncTick(now: t0 + 49, random: &random) == [.generatePeeringKey(peer: pA, cost: 18)])
}

@Test func staticPeersAreActivatedOnceWithAPathRequest() {
    let s = Data(repeating: 0x5A, count: 16)
    var table = PNPeerTable(config: .init(staticPeers: [s]))
    #expect(table.activateStaticPeers(now: t0) == [.requestPath(s)])
    #expect(table.peers[s]?.announce == nil && table.peers[s]?.alive == false)
    #expect(table.activateStaticPeers(now: t0) == [])
}
