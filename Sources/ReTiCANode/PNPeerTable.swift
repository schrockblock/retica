import Foundation
import ReTiCA

/// A propagation node's peers: reference LXMF 1.3.0's peering (`LXMRouter.peer` / `unpeer` /
/// `sync_peers`, LXMRouter.py:2340-2521, and `LXMPeer`, LXMPeer.py) as a pure value type. The host
/// (`LXMFServiceNode`) owns it, feeds it events through synchronous mutating methods and carries out
/// the `Command`s they return. It never reads the message store: where reference's `sync()` reads
/// `propagation_entries`, the host computes the selection and calls `offerSelected`.
///
/// Cross-validated step by step against a real `LXMRouter` / `LXMPeer` in `PNPeerTableTests`
/// (`Vectors/generate_lxmf_peer_state_fixtures.py`).
///
/// **Host protocol.**
/// - `.openLink(peer)`: open a link to the peer's `lxmf.propagation` destination. With no path,
///   request one, wait `pathRequestGrace`, and if there is still none call `linkFailed`, which is
///   where reference's `sync()` does the same (LXMPeer.py:297-306). A link that fails to establish
///   also goes to `linkFailed` (the endpoint reports it by destination; the table knows a link id only
///   from `linkEstablished` on). An established one goes to `linkEstablished`.
/// - After `linkEstablished`, or after `offerResponse(.noIdentity)`, a peer left in `.linkReady`
///   wants an offer: the host calls `offerSelected` with
///   `store.offerCandidates(acceptedAt: LXMFPropagation.peerMinimumAcceptedCost(peer.announce!), …,
///   among: peer.unhandled, excluding: peer.handled, now:)` and `purged:` = the peer's unhandled ids
///   the store does not hold.
/// - `.generatePeeringKey(peer, cost)`: mine a peering key over `peerIdentity.hash + ourIdentity.hash`
///   and report it with `keyReady`, or `keyFailed` if the search fails or is cancelled. The table does
///   not ask again while the peer is `.keyPending`.
/// - `.sendOffer` / `.sendResource`: the `/offer` request and the sync container, on that link;
///   report the response with `offerResponse` (parsed by `OfferResponse.parse`), a failed request with
///   `requestFailed`, the transfer with `transferConcluded` / `transferFailed`, and any close of the
///   link with `linkClosed`.
/// - `.closeLink` is also returned by every path that removes a peer holding a link (`unpeer`,
///   `peer` / `announceHeard` unpeering, the cull in `syncTick`).
/// - Run `syncTick` every `peerSyncInterval` seconds. Call `distribute` on every fresh ingest and
///   `markHandled` for ids a peer sent us. Call `prune` after EVERY store eviction (see `prune`).
///   Call `announceHeard` only in node mode.
///
/// **Deliberate divergences from reference**, each where reference strands a peer with its sync link
/// open and out of selection (`sync_peers` only picks `IDLE` peers) until the link happens to die:
/// a throttled response (reference sets only `next_sync_attempt`, LXMPeer.py:426-430), a no-access
/// response whose unpeer is refused or succeeds (reference never closes the link, :421-424), an empty
/// offer or an empty unhandled set on an established link (:315-317, :386-388), and a peering key that
/// went stale between opening the link and establishing it (:285-288). In each the table closes the
/// link and returns the peer to `.idle`. Also: a peering cost that is negative or NaN is refused like
/// one above the maximum (reference peers, then its key generation raises forever); `linkFailed`
/// marks the peer not alive on an establishment failure too (reference does so only for a missing
/// path, and its next selection does the same through `sync()`'s backoff check); and `linkClosed`
/// clears a transfer in flight (reference relies on the resource's own failure callback for that).
///
/// **Not implemented:** `rotate_peers` (LXMRouter.py:2396-2466); the lazy sync strategy (only
/// `STRATEGY_PERSISTENT`, LXMPeer.py:33-35). Reference never syncs to a peer whose peering cost is
/// exactly 0 (`peering_key_ready` returns False on `not self.peering_cost`, LXMPeer.py:230), and
/// neither does this.
public struct PNPeerTable: Equatable, Sendable {
    /// `LXMPeer.MAX_UNREACHABLE` (LXMPeer.py:39): a non-static peer unheard this long is culled.
    public static let maxUnreachable: TimeInterval = 14 * 24 * 60 * 60
    /// `LXMPeer.SYNC_BACKOFF_STEP` (LXMPeer.py:45).
    public static let syncBackoffStep: TimeInterval = 12 * 60
    /// `LXMPeer.PATH_REQUEST_GRACE` (LXMPeer.py:50).
    public static let pathRequestGrace: TimeInterval = 7.5
    /// `LXMRouter.FASTEST_N_RANDOM_POOL` (LXMRouter.py:59).
    public static let fastestNRandomPool = 2
    /// `LXMRouter.PN_STAMP_THROTTLE` (LXMRouter.py:76).
    public static let pnStampThrottle: TimeInterval = 300
    /// `JOB_PEERSYNC_INTERVAL` 6 × `PROCESSING_INTERVAL` 4 (LXMRouter.py:38, :973).
    public static let peerSyncInterval: TimeInterval = 24
    /// Reference's 0 for an unset time (`last_heard`, `next_sync_attempt`).
    public static let never = Date(timeIntervalSince1970: 0)

    public struct Config: Equatable, Sendable {
        /// lxmd defaults (LXMRouter.py:56-57, :63-64; lxmd.py:66-69, :207-247). `autopeerMaxDepth` is
        /// the 6 lxmd writes to its config, not `LXMRouter.AUTOPEER_MAXDEPTH` (4).
        public var autopeer = true; public var autopeerMaxDepth: UInt8 = 6; public var maxPeers = 20
        /// Our own demand on inbound offers (the host validates keys at it and advertises it).
        public var peeringCost = 18.0
        /// The highest peering cost we mine a key for (`max_peering_cost`).
        public var maxRemotePeeringCost = 26.0
        public var staticPeers: Set<Data> = []

        public init(autopeer: Bool = true, autopeerMaxDepth: UInt8 = 6, maxPeers: Int = 20,
                    peeringCost: Double = 18.0, maxRemotePeeringCost: Double = 26.0, staticPeers: Set<Data> = []) {
            self.autopeer = autopeer; self.autopeerMaxDepth = autopeerMaxDepth; self.maxPeers = maxPeers
            self.peeringCost = peeringCost; self.maxRemotePeeringCost = maxRemotePeeringCost
            self.staticPeers = staticPeers
        }
    }

    /// `LXMPeer`'s states (LXMPeer.py:17-22), plus `keyPending`: idle, with a key search requested.
    /// Reference's `RESPONSE_RECEIVED` is never held: every response leaves the peer elsewhere.
    public enum PeerState: Equatable, Sendable { case idle, keyPending, linkEstablishing, linkReady, requestSent, transferring }

    public struct Peer: Equatable, Sendable {
        public var destinationHash: Data; public var peeringTimebase: Int; public var alive: Bool
        public var lastHeard: Date; public var lastSyncAttempt: Date?; public var nextSyncAttempt: Date
        public var syncBackoff: TimeInterval; public var syncTransferRate: Double
        public var announce: PNAnnounce?              // limits + costs; nil = costs unknown (static peer not yet heard)
        public var peeringKey: Data?; public var peeringKeyValue: Double?
        public var state: PeerState; public var linkID: Data?
        public var handled: Set<Data>; public var unhandled: Set<Data>
        public var lastOffer: [Data]; public var transferring: [Data]?
        public var offered: Int; public var outgoing: Int; public var incoming: Int

        public init(destinationHash: Data, peeringTimebase: Int = 0, alive: Bool = false,
                    lastHeard: Date = PNPeerTable.never, lastSyncAttempt: Date? = nil,
                    nextSyncAttempt: Date = PNPeerTable.never, syncBackoff: TimeInterval = 0,
                    syncTransferRate: Double = 0, announce: PNAnnounce? = nil,
                    peeringKey: Data? = nil, peeringKeyValue: Double? = nil,
                    state: PeerState = .idle, linkID: Data? = nil,
                    handled: Set<Data> = [], unhandled: Set<Data> = [],
                    lastOffer: [Data] = [], transferring: [Data]? = nil,
                    offered: Int = 0, outgoing: Int = 0, incoming: Int = 0) {
            self.destinationHash = destinationHash; self.peeringTimebase = peeringTimebase; self.alive = alive
            self.lastHeard = lastHeard; self.lastSyncAttempt = lastSyncAttempt; self.nextSyncAttempt = nextSyncAttempt
            self.syncBackoff = syncBackoff; self.syncTransferRate = syncTransferRate; self.announce = announce
            self.peeringKey = peeringKey; self.peeringKeyValue = peeringKeyValue
            self.state = state; self.linkID = linkID; self.handled = handled; self.unhandled = unhandled
            self.lastOffer = lastOffer; self.transferring = transferring
            self.offered = offered; self.outgoing = outgoing; self.incoming = incoming
        }
    }

    public enum Command: Equatable, Sendable {
        case openLink(Data), identify(linkID: Data), generatePeeringKey(peer: Data, cost: Double)
        case sendOffer(linkID: Data, key: Data, ids: [Data]), sendResource(linkID: Data, ids: [Data])
        case closeLink(Data), requestPath(Data)
    }

    /// A peer's answer to our `/offer`, as `LXMPeer.offer_response` tells them apart (LXMPeer.py:413-457).
    public enum OfferResponse: Equatable, Sendable {
        case noIdentity, noAccess, throttled, wantsNone, wantsAll, wants([Data]), other

        /// `wants` is the response's ids that we offered, in the response's order and as often as it
        /// lists them, which is the order (and the duplicates) reference sends them in
        /// (LXMPeer.py:455-457) and what `PNNode` always did. Narrower than reference, which sends any
        /// id in the list its store holds, offered or not, and raises on one it does not. An error code matches by value under any integer or float encoding,
        /// as Python's `==` does. `ERROR_INVALID_KEY`, `ERROR_INVALID_DATA` and anything else are
        /// `other`; so are the integers 0 and 1, although Python's `0 == False` would read them as the
        /// booleans (no responder sends them).
        public static func parse(_ data: Data, offered: [Data]) -> OfferResponse {
            guard let value = MsgPack.decodeValue(data) else { return .other }
            let number: Double?
            switch value {
            case .bool(false): return .wantsNone
            case .bool(true): return .wantsAll
            case let .array(items):
                let offeredSet = Set(offered)
                return .wants(items.compactMap { item -> Data? in
                    if case let .bin(d) = item, offeredSet.contains(d) { return d }
                    return nil
                })
            case let .uint(u): number = Double(u)
            case let .int(i): number = Double(i)
            case let .double(d): number = d
            case let .float(f): number = Double(f)
            default: number = nil
            }
            switch number {
            case Double(LXMFPropagation.errorNoIdentity)?: return .noIdentity
            case Double(LXMFPropagation.errorNoAccess)?: return .noAccess
            case Double(LXMFPropagation.errorThrottled)?: return .throttled
            default: return .other
            }
        }
    }

    public var config: Config
    public private(set) var peers: [Data: Peer] = [:]
    /// Insertion order, as reference's `self.peers` dict keeps it: selection and distribution walk it.
    private var order: [Data] = []
    /// When each peer's sync transfer began (`current_sync_transfer_started`), for the transfer rate.
    private var transferStarted: [Data: Date] = [:]

    public init(config: Config) { self.config = config }

    // MARK: - Peering

    /// `LXMFPropagationAnnounceHandler.received_announce` (Handlers.py:56-107), for a parsed, valid
    /// propagation-node announce heard while we are a propagation node. A static peer is fed by any
    /// announce, and by a path response only while it has never been heard; one not in the table is
    /// ignored (reference raises a KeyError there). Any other node autopeers on a real announce
    /// (never a path response) within `autopeerMaxDepth` hops, is unpeered when it moves beyond it,
    /// and is unpeered when it announces its node disabled.
    ///
    /// The host must call this only while it is itself a propagation node (node mode on): reference
    /// evaluates peering only `if self.lxmrouter.propagation_node` (Handlers.py:56). Returns
    /// `.closeLink` when an unpeered peer held a sync link.
    public mutating func announceHeard(_ dest: Data, announce: PNAnnounce, hops: UInt8, isPathResponse: Bool,
                                       now: Date) -> [Command] {
        if config.staticPeers.contains(dest) {
            guard let existing = peers[dest] else { return [] }
            if !isPathResponse || existing.lastHeard == Self.never { return peer(dest, announce: announce, now: now) }
            return []
        }
        guard config.autopeer, !isPathResponse else { return [] }
        if announce.nodeState {
            if hops <= config.autopeerMaxDepth {
                return peer(dest, announce: announce, now: now)
            } else if peers[dest] != nil {
                return unpeer(dest, timebase: announce.timebase, now: now)
            }
            return []
        } else {
            return unpeer(dest, timebase: announce.timebase, now: now)
        }
    }

    /// `LXMRouter.peer` (LXMRouter.py:2340-2383). A cost over `maxRemotePeeringCost` (or negative, or
    /// NaN) refuses a new peer and unpeers an existing one. An existing peer is updated only by a newer
    /// timebase. A new peer keeps timebase 0, as reference never sets it there. Returns `.closeLink`
    /// when an unpeered peer held a sync link.
    public mutating func peer(_ dest: Data, announce: PNAnnounce, now: Date) -> [Command] {
        let cost = announce.peeringCost
        guard cost >= 0, cost <= config.maxRemotePeeringCost else {
            if peers[dest] != nil { return unpeer(dest, timebase: announce.timebase, now: now) }
            return []
        }
        if var p = peers[dest] {
            guard announce.timebase > p.peeringTimebase else { return [] }
            p.alive = true
            p.syncBackoff = 0
            p.nextSyncAttempt = Self.never
            p.peeringTimebase = announce.timebase
            p.lastHeard = now
            p.announce = announce
            peers[dest] = p
        } else {
            guard peers.count < config.maxPeers else { return [] }
            insert(Peer(destinationHash: dest, alive: true, lastHeard: now, announce: announce))
        }
        return []
    }

    /// `LXMRouter.unpeer` (LXMRouter.py:2385-2394): removed when `timebase` (now, truncated, when nil)
    /// is not older than the peering. Returns `.closeLink` when the peer held a sync link, so the host
    /// is not left with a link (and a transfer) no peer owns. A peer removed while still establishing
    /// has no link id yet: its late `linkEstablished` is answered with `.closeLink`.
    public mutating func unpeer(_ dest: Data, timebase: Int?, now: Date) -> [Command] {
        guard let p = peers[dest] else { return [] }
        let stamp = timebase ?? Self.truncatedSeconds(now)
        guard stamp >= p.peeringTimebase else { return [] }
        return remove(dest)
    }

    /// Adds every configured static peer not yet in the table, with its costs unknown, and requests a
    /// path to each (LXMRouter.py:728-737; a new peer has never been heard). Kept even past
    /// `maxPeers`, as reference does. Sorted, so the commands are deterministic.
    public mutating func activateStaticPeers(now: Date) -> [Command] {
        var commands: [Command] = []
        for dest in config.staticPeers.sorted(by: { $0.lexicographicallyPrecedes($1) }) where peers[dest] == nil {
            insert(Peer(destinationHash: dest))
            commands.append(.requestPath(dest))
        }
        return commands
    }

    // MARK: - Distribution

    /// `flush_peer_distribution_queue` + `process_queues` (LXMRouter.py:2811-2824, LXMPeer.py:572-575):
    /// each id becomes unhandled for every peer but `source`, unless that peer has handled it.
    public mutating func distribute(_ ids: [Data], from source: Data?) {
        for dest in order where dest != source {
            guard var p = peers[dest] else { continue }
            for id in ids where !p.handled.contains(id) { p.unhandled.insert(id) }
            peers[dest] = p
        }
    }

    /// `queue_handled_message` + `process_queues` (LXMPeer.py:567-570): handled, and no longer unhandled.
    public mutating func markHandled(_ ids: [Data], for peer: Data) {
        guard var p = peers[peer] else { return }
        p.handled.formUnion(ids)
        p.unhandled.subtract(ids)
        peers[peer] = p
    }

    /// Keeps only ids the store holds, as reference's lists live inside the store entries
    /// (LXMPeer.py:118-128 on load, :579-593 always).
    ///
    /// **Mandatory after every store eviction or removal.** Reference needs no such call, because a
    /// peer's handled and unhandled lists ARE fields of the store entries and leave with them. Here
    /// they are separate sets, so without `prune`: they grow without bound with every id ever
    /// distributed, and an evicted id stays in `unhandled`, keeping the peer selectable for a sync
    /// that can offer nothing (the host should also pass such ids as `purged` to `offerSelected`).
    public mutating func prune(toStored stored: Set<Data>) {
        for dest in order {
            guard var p = peers[dest] else { continue }
            p.handled.formIntersection(stored)
            p.unhandled.formIntersection(stored)
            peers[dest] = p
        }
    }

    // MARK: - Sync

    /// `sync_peers` (LXMRouter.py:2468-2521). Culls non-static peers unheard for `maxUnreachable`;
    /// among idle peers with unhandled ids, pools the `fastestNRandomPool` fastest alive ones plus as
    /// many unknown-speed alive ones (or, with none alive, the dead ones past their backoff), picks one
    /// with `random`, and runs reference's `sync()` on it. The pick is `random.next() % pool.count`.
    /// A culled peer that held a sync link adds its `.closeLink` after the sync's commands.
    public mutating func syncTick(now: Date, random: inout some RandomNumberGenerator) -> [Command] {
        var culled: [Data] = [], waiting: [Data] = [], unresponsive: [Data] = []
        for dest in order {
            guard let p = peers[dest] else { continue }
            if now.timeIntervalSince1970 > p.lastHeard.timeIntervalSince1970 + Self.maxUnreachable {
                if !config.staticPeers.contains(dest) { culled.append(dest) }
            } else if p.state == .idle || p.state == .keyPending, !p.unhandled.isEmpty {
                if p.alive { waiting.append(dest) } else if now > p.nextSyncAttempt { unresponsive.append(dest) }
            }
        }
        var pool: [Data] = []
        if !waiting.isEmpty {
            // Python's sort with reverse=True is stable: equal rates keep table order.
            let fastest = waiting.enumerated()
                .sorted { a, b in
                    let ra = peers[a.element]!.syncTransferRate, rb = peers[b.element]!.syncTransferRate
                    return ra != rb ? ra > rb : a.offset < b.offset
                }
                .prefix(Self.fastestNRandomPool).map(\.element)
            pool = fastest
            let unknownSpeed = waiting.filter { peers[$0]!.syncTransferRate == 0 }
            pool += unknownSpeed.prefix(min(unknownSpeed.count, fastest.count))
        } else if !unresponsive.isEmpty {
            pool = unresponsive
        }
        var commands: [Command] = []
        if !pool.isEmpty {
            let index = Int(random.next() % UInt64(pool.count))
            commands = sync(pool[index], now: now)
        }
        for dest in culled { commands += remove(dest) }
        return commands
    }

    /// The host's key search for `peer` failed or was cancelled: back to idle, with one backoff step
    /// before the next attempt, so the peer is neither stranded in `.keyPending` nor retried every tick.
    /// Reference has no such outcome (its search runs to completion in a thread).
    public mutating func keyFailed(peer: Data, now: Date) {
        guard var p = peers[peer], p.state == .keyPending else { return }
        p.state = .idle
        p.syncBackoff += Self.syncBackoffStep
        p.nextSyncAttempt = now + p.syncBackoff
        peers[peer] = p
    }

    /// A peering key the host mined. Kept when it meets the peer's current cost (`generate_peering_key`,
    /// LXMPeer.py:262-265); the next `syncTick` uses it. Returns no commands, as reference waits for the
    /// next sync job too.
    public mutating func keyReady(peer: Data, key: Data, value: Double, now: Date) -> [Command] {
        guard var p = peers[peer] else { return [] }
        if let cost = p.announce?.peeringCost, value >= cost {
            p.peeringKey = key
            p.peeringKeyValue = value
        }
        if p.state == .keyPending { p.state = .idle }
        peers[peer] = p
        return []
    }

    /// `LXMPeer.link_established` (LXMPeer.py:539-547): identify, link-ready, then `sync()`, which marks
    /// the peer alive and clears its backoff. Returns `[.identify(linkID)]`, and leaves the peer in
    /// `.linkReady` when it wants an offer: the host then calls `offerSelected` with
    /// `store.offerCandidates(..., among: peer.unhandled, excluding: peer.handled, ...)`. A link for a
    /// peer that is not establishing one (or not in the table) is closed.
    public mutating func linkEstablished(peer: Data, linkID: Data, now: Date) -> [Command] {
        guard var p = peers[peer], p.state == .linkEstablishing else { return [.closeLink(linkID)] }
        p.linkID = linkID
        p.state = .linkReady
        p.nextSyncAttempt = Self.never
        peers[peer] = p
        return [.identify(linkID: linkID)] + sync(peer, now: now)
    }

    /// The offer reference's `sync()` prepares on a ready link (LXMPeer.py:339-395), computed by the host:
    /// `purged` (unhandled ids the store no longer holds, `peer.unhandled` minus the store) and low-value
    /// ids leave the unhandled set (LXMPeer.py:353-361), oversized ones become handled (:375-378), and the
    /// rest go out with the cached key.
    ///
    /// An empty offer closes the link (a divergence; see the type's documentation). If unhandled ids
    /// remain (ones the sync limit skipped this time), the next attempt waits `syncBackoffStep`:
    /// otherwise the peer, idle again with unhandled ids and no backoff, would get a new link every tick
    /// for an offer that is empty every time.
    public mutating func offerSelected(peer: Data, offer: [Data], oversized: [Data], lowValue: [Data],
                                       purged: [Data], now: Date) -> [Command] {
        guard var p = peers[peer], p.state == .linkReady, let link = p.linkID else { return [] }
        p.unhandled.subtract(purged)
        p.unhandled.subtract(lowValue)
        p.unhandled.subtract(oversized)
        p.handled.formUnion(oversized)
        guard !offer.isEmpty, let key = p.peeringKey else {
            p.linkID = nil
            p.state = .idle
            if !p.unhandled.isEmpty { p.nextSyncAttempt = now + Self.syncBackoffStep }
            peers[peer] = p
            return [.closeLink(link)]
        }
        p.lastOffer = offer
        p.state = .requestSent
        peers[peer] = p
        return [.sendOffer(linkID: link, key: key, ids: offer)]
    }

    /// `LXMPeer.offer_response` (LXMPeer.py:405-495).
    /// - `noIdentity`: identify again and re-run `sync()` on the same link (the host offers again).
    /// - `noAccess`: unpeer.
    /// - `throttled`: no sync attempt for `pnStampThrottle`.
    /// - `wantsNone`: every offered id still unhandled becomes handled.
    /// - `wantsAll` / `wants`: the offered ids not wanted become handled (for `wants`), the wanted ones
    ///   go out as one resource.
    /// - `other`: close, nothing marked (reference raises inside its `else` branch).
    /// Nothing wanted closes the link and counts the offer. Where reference leaves the link open
    /// (`noAccess`, `throttled`), the table closes it.
    public mutating func offerResponse(linkID: Data, _ response: OfferResponse, now: Date) -> [Command] {
        guard let dest = peerOnLink(linkID), var p = peers[dest], p.state == .requestSent else { return [] }
        let wanted: [Data]
        switch response {
        case .noIdentity:
            p.state = .linkReady
            peers[dest] = p
            return [.identify(linkID: linkID)] + sync(dest, now: now)
        case .noAccess:
            if unpeer(dest, timebase: nil, now: now).isEmpty { idle(dest) }   // refused: still a peer
            return [.closeLink(linkID)]
        case .throttled:
            p.nextSyncAttempt = now + Self.pnStampThrottle
            p.linkID = nil
            p.state = .idle
            peers[dest] = p
            return [.closeLink(linkID)]
        case .wantsNone:
            for id in p.lastOffer where p.unhandled.contains(id) {
                p.handled.insert(id)
                p.unhandled.remove(id)
            }
            wanted = []
        case .wantsAll:
            wanted = p.lastOffer
        case let .wants(ids):
            let wantedSet = Set(ids)
            for id in p.lastOffer where !wantedSet.contains(id) {
                p.handled.insert(id)
                p.unhandled.remove(id)
            }
            wanted = ids
        case .other:
            p.linkID = nil
            p.state = .idle
            peers[dest] = p
            return [.closeLink(linkID)]
        }
        if wanted.isEmpty {
            p.offered += p.lastOffer.count
            p.linkID = nil
            p.state = .idle
            peers[dest] = p
            return [.closeLink(linkID)]
        }
        p.transferring = wanted
        p.state = .transferring
        transferStarted[dest] = now
        peers[dest] = p
        return [.sendResource(linkID: linkID, ids: wanted)]
    }

    /// `LXMPeer.resource_concluded` with a complete resource (LXMPeer.py:497-529): the sent ids become
    /// handled, the link closes, the rate is `bytes * 8 / seconds`, and with unhandled ids left the
    /// persistent strategy runs `sync()` again, which opens a new link. `bytes` is the resource's
    /// TRANSFER size (`resource.get_transfer_size()`, LXMPeer.py:515: the bytes on the wire, after
    /// compression), not the container's data size.
    public mutating func transferConcluded(linkID: Data, bytes: Int, now: Date) -> [Command] {
        guard let dest = peerOnLink(linkID), var p = peers[dest], p.state == .transferring,
              let sent = p.transferring else { return [] }
        p.handled.formUnion(sent)
        p.unhandled.subtract(sent)
        p.linkID = nil
        p.state = .idle
        if let started = transferStarted.removeValue(forKey: dest) {
            // Reference: get_transfer_size()*8 / max(elapsed, 1E-6), LXMPeer.py:515.
            p.syncTransferRate = Double(bytes) * 8 / max(now.timeIntervalSince(started), 1e-6)
        }
        p.alive = true
        p.lastHeard = now
        p.offered += p.lastOffer.count
        p.outgoing += sent.count
        p.transferring = nil
        peers[dest] = p
        var commands: [Command] = [.closeLink(linkID)]
        if !p.unhandled.isEmpty { commands += sync(dest, now: now) }
        return commands
    }

    /// A failed sync transfer (LXMPeer.py:531-537): close the link, idle, nothing marked.
    public mutating func transferFailed(linkID: Data) -> [Command] {
        guard let dest = peerOnLink(linkID) else { return [] }
        idle(dest)
        return [.closeLink(linkID)]
    }

    /// The sync link closed (`link_closed`, LXMPeer.py:549-551): idle. A transfer still in flight is
    /// dropped, as the resource's failure would drop it. Only an ESTABLISHED link has an id here; an id
    /// no peer holds (a link still establishing, or one a removed peer owned) is ignored, harmlessly.
    /// A link that ends before it is established must be reported with `linkFailed(peer:now:)`.
    public mutating func linkClosed(linkID: Data) {
        guard let dest = peerOnLink(linkID) else { return }
        idle(dest)
    }

    /// THE call for every outcome of an `.openLink` other than `linkEstablished`: no path after the
    /// grace period, or a link that never established (the endpoint reports those by destination
    /// only, `TransportEndpoint.Delegate.linkFailed(destinationHash:reason:)`, since no link id exists
    /// for the host until establishment). Not alive, and no attempt before the backoff `syncTick`
    /// added (LXMPeer.py:302-306). A peer left in `.linkEstablishing` without this call is never
    /// selected again, so the host must make it. Ignored for a peer not establishing.
    public mutating func linkFailed(peer: Data, now: Date) {
        guard var p = peers[peer], p.state == .linkEstablishing else { return }
        p.state = .idle
        p.linkID = nil
        p.alive = false
        p.nextSyncAttempt = now + p.syncBackoff
        peers[peer] = p
    }

    /// The `/offer` request failed (`request_failed`, LXMPeer.py:400-403): close, idle.
    public mutating func requestFailed(linkID: Data) -> [Command] {
        guard let dest = peerOnLink(linkID) else { return [] }
        idle(dest)
        return [.closeLink(linkID)]
    }

    // MARK: - Persistence

    /// Every peer, in table order (what `LXMPeer.to_bytes` keeps and more).
    public var persisted: [Peer] { order.compactMap { peers[$0] } }

    /// Loads persisted peers as `LXMPeer.from_bytes` does (LXMPeer.py:53-136): handled and unhandled
    /// pruned to `stored`; the transient state (link, offer, transfer, backoff, next attempt) starts
    /// afresh. A peer already in the table is replaced in place.
    public mutating func rehydrate(_ loaded: [Peer], stored: Set<Data>) {
        for var p in loaded {
            p.handled.formIntersection(stored)
            p.unhandled.formIntersection(stored)
            p.state = .idle
            p.linkID = nil
            p.lastOffer = []
            p.transferring = nil
            p.syncBackoff = 0
            p.nextSyncAttempt = Self.never
            transferStarted[p.destinationHash] = nil
            insert(p)
        }
    }

    // MARK: - Internals

    /// Reference's `sync()` (LXMPeer.py:269-395) up to the point the host takes over: the path check
    /// is the host's (`.openLink`), the offer selection is the host's (`offerSelected`).
    private mutating func sync(_ dest: Data, now: Date) -> [Command] {
        guard var p = peers[dest] else { return [] }
        p.lastSyncAttempt = now
        let timeReached = now > p.nextSyncAttempt
        let costsKnown = p.announce != nil
        let keyReady = Self.peeringKeyReady(&p)
        var commands: [Command] = []
        guard timeReached, costsKnown, keyReady else {
            var generating = false
            if !timeReached {
                if now > p.lastHeard { p.alive = false }
            } else if costsKnown, p.peeringKey == nil, p.state != .keyPending, let cost = p.announce?.peeringCost {
                commands.append(.generatePeeringKey(peer: dest, cost: cost))
                generating = true
            }
            if p.state == .linkReady, let link = p.linkID {
                // Reference postpones with the link left open; the table closes it.
                commands.append(.closeLink(link))
                p.linkID = nil
                p.state = generating ? .keyPending : .idle
            } else if generating, p.state == .idle {
                p.state = .keyPending
            }
            peers[dest] = p
            return commands
        }
        if p.unhandled.isEmpty || p.transferring != nil {
            if p.state == .linkReady, let link = p.linkID {
                commands.append(.closeLink(link))
                p.linkID = nil
                p.state = .idle
            }
            peers[dest] = p
            return commands
        }
        switch p.state {
        case .idle, .keyPending:
            p.syncBackoff += Self.syncBackoffStep
            p.nextSyncAttempt = now + p.syncBackoff
            p.state = .linkEstablishing
            commands.append(.openLink(dest))
        case .linkReady:
            p.alive = true
            p.lastHeard = now
            p.syncBackoff = 0
        case .linkEstablishing, .requestSent, .transferring:
            break
        }
        peers[dest] = p
        return commands
    }

    /// `peering_key_ready` (LXMPeer.py:229-238): a key worth at least the peer's cost. A key that is
    /// not is discarded. A cost of 0 is never ready, as `not self.peering_cost` makes it in reference.
    private static func peeringKeyReady(_ p: inout Peer) -> Bool {
        guard let cost = p.announce?.peeringCost, cost != 0 else { return false }
        if p.peeringKey != nil, let value = p.peeringKeyValue {
            if value >= cost { return true }
            p.peeringKey = nil
            p.peeringKeyValue = nil
        }
        return false
    }

    private func peerOnLink(_ linkID: Data) -> Data? {
        order.first { peers[$0]?.linkID == linkID }
    }

    private mutating func idle(_ dest: Data) {
        guard var p = peers[dest] else { return }
        p.linkID = nil
        p.state = .idle
        p.transferring = nil
        transferStarted[dest] = nil
        peers[dest] = p
    }

    private mutating func insert(_ p: Peer) {
        if peers[p.destinationHash] == nil { order.append(p.destinationHash) }
        peers[p.destinationHash] = p
    }

    /// Removes a peer; `.closeLink` for the sync link it held, if any.
    private mutating func remove(_ dest: Data) -> [Command] {
        let link = peers[dest]?.linkID
        peers[dest] = nil
        order.removeAll { $0 == dest }
        transferStarted[dest] = nil
        return link.map { [.closeLink($0)] } ?? []
    }

    /// Python's `int(time.time())`, without trapping on a non-finite or out-of-range date.
    private static func truncatedSeconds(_ date: Date) -> Int {
        let t = date.timeIntervalSince1970.rounded(.towardZero)
        guard t.isFinite else { return t > 0 ? .max : .min }
        if t >= Double(Int.max) { return .max }
        if t <= Double(Int.min) { return .min }
        return Int(t)
    }
}
