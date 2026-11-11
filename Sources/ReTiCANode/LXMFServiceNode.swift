import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCATransport

/// A node that is BOTH an LXMF client and (optionally) an LXMF propagation node over ONE endpoint —
/// the shape reference LXMF uses: one identity, one connection, both destinations registered.
///
/// Composes the unchanged `LXMFNode` (client; owns the `TransportEndpoint`) with the unchanged
/// `PropagationNode` (store + serve logic), adding only the translation between the endpoint's inbound
/// delegates and the propagation node's actions. Every serve behavior is gated on `nodeModeEnabled`, so
/// with node-mode off this behaves exactly like a bare `LXMFNode`.
///
/// Serve scope: register/announce, ingest offers, two-phase `/get`, and both halves of PN↔PN peering,
/// as a default lxmd does it. Server half: `/offer` answered as reference does, multi-message
/// containers refused on links without a validated peering key, inbound syncs accounted in `peering`
/// (a `PNPeerTable`), auto-peering with a recallable sender. Client half: auto-peering from announces
/// (`.announceReceived`), static peers, the 24 s peer-sync job (`.peerSyncTick`, node mode only),
/// peering keys mined per peer and cached with it, the `/offer` exchange and the sync transfer, and
/// the persistence hooks (`.rehydrate(entries:peers:)`, `Delegate.peersChanged`). This reducer is
/// `PNPeerTable`'s host: it carries out the table's `Command`s (see its host protocol). Time-based
/// expiry is not driven here. Inbound proving of PACKET-framed propagation offers is in scope and lives
/// at the `.linkDataReceived` handler below (reference LXMRouter.py:2255); Resource-framed offers are
/// proved by the resource transfer protocol.
///
/// **Sync links are this reducer's own.** They are opened with `.openOwnedLink(owner:
/// .propagationPeerSync)`, so their establishment and failure reach only this reducer
/// (`ownedLinkEstablished` / `ownedLinkFailed`): `LXMFNode` never records one as its router's link,
/// never arms the router's idle timer on it, and never sends a sync or an upload over it, even when the
/// peer is also this node's outbound propagation node. Reference keeps them apart the same way, as
/// separate `RNS.Link` objects with their own callbacks. Two links to one node (the client's and the
/// sync's) can be up at once. The `/offer` answer is also matched by request id.
@Reducer
public struct LXMFServiceNode {
    @ObservableState
    public struct State: Equatable {
        public var client: LXMFNode.State
        public var pn: PropagationNode.State
        /// While false, nothing is registered, ingested, or served.
        public var nodeModeEnabled: Bool = false
        /// linkID → the IDENTIFY'd remote client on that link. A `/get` without one is dropped.
        public var clientIdentities: [Data: Identity] = [:]
        /// client delivery hash → FIFO queue of in-flight /get requests. Clients can tear down and
        /// retry (reference LXMessage.py:616-621), so concurrent /gets from the same identity are
        /// possible. Using a queue per key prevents the second request from silently overwriting the
        /// first (the first's linkID would be lost and its response never sent).
        public var pendingGet: [Data: [PendingGet]] = [:]
        /// Our propagation-node peers. Inbound: `/offer` validates keys at `peering.config.peeringCost`
        /// (which the announce advertises), inbound syncs mark ids handled for the sending peer and
        /// distribute fresh ones to the others. Outbound: announces, the sync job, keys, offers and
        /// transfers drive it. Every store removal prunes it. The host persists `peering.persisted`
        /// (reported by `Delegate.peersChanged`) and hands it back with `.rehydrate(entries:peers:)`.
        public var peering: PNPeerTable
        /// Links on which a peer presented a peering key valid at our cost (reference
        /// `validated_peer_links`, LXMRouter.py:2649). Only such a link may deliver more than one
        /// message per container (:2716-2724). Cleared when the link closes and on node-mode disable.
        public var validatedOfferLinks: Set<Data> = []
        /// Sync links still being opened, per peer: each `.openOwnedLink` adds one, each
        /// `ownedLinkEstablished` / `ownedLinkFailed` takes one away. A failure is the peer's
        /// `linkFailed` only when it was the last attempt outstanding, so a stale attempt (one from
        /// before a node-mode off/on) cannot fail the current one.
        public var peerLinkOpens: [Data: Int] = [:]
        /// Sync link → the request id of the `/offer` on it (from `requestSent`). Only the response
        /// or failure carrying it is the offer's.
        public var peerOfferRequests: [Data: Data] = [:]
        /// Peers waiting out `PNPeerTable.pathRequestGrace` after a path request.
        public var peerPathWaits: Set<Data> = []
        /// Sync link → the sync transfer's size in bytes, per resource segment (key 0: the container's
        /// size until the sender reports progress), for `transferConcluded(bytes:)`.
        public var peerTransferBytes: [Data: [Int: Int]] = [:]
        /// The 24 s peer-sync job is running: set when `setNodeMode(true)` starts it, cleared when
        /// `setNodeMode(false)` cancels it. A redundant enable leaves a running job alone.
        public var peerSyncJobRunning: Bool = false

        /// 32 MB — a mobile-appropriate cap for the store-and-forward backlog.
        public static let defaultStorageLimitBytes: Int = 32 * 1024 * 1024

        public init(identity: Identity, endpoint: TransportEndpoint.State,
                    storageLimitBytes: Int? = State.defaultStorageLimitBytes,
                    targetStampCost: Double = LXMFPropagation.defaultPropagationStampCost,
                    stampCostFlexibility: Double = 0,
                    peering: PNPeerTable.Config = .init()) {
            self.client = LXMFNode.State(identity: identity, endpoint: endpoint)
            self.pn = PropagationNode.State(storageLimitBytes: storageLimitBytes, targetStampCost: targetStampCost,
                                            stampCostFlexibility: stampCostFlexibility)
            self.peering = PNPeerTable(config: peering)
        }

        /// Convenience: run this node over TCP.
        public init(identity: Identity, endpoint: TCPEndpoint.State,
                    storageLimitBytes: Int? = State.defaultStorageLimitBytes,
                    targetStampCost: Double = LXMFPropagation.defaultPropagationStampCost,
                    stampCostFlexibility: Double = 0,
                    peering: PNPeerTable.Config = .init()) {
            self.init(identity: identity, endpoint: .tcp(endpoint),
                      storageLimitBytes: storageLimitBytes, targetStampCost: targetStampCost,
                      stampCostFlexibility: stampCostFlexibility, peering: peering)
        }

        /// Convenience: run this node over BLE.
        public init(identity: Identity, endpoint: BLEEndpoint.State,
                    storageLimitBytes: Int? = State.defaultStorageLimitBytes,
                    targetStampCost: Double = LXMFPropagation.defaultPropagationStampCost,
                    stampCostFlexibility: Double = 0,
                    peering: PNPeerTable.Config = .init()) {
            self.init(identity: identity, endpoint: .ble(endpoint),
                      storageLimitBytes: storageLimitBytes, targetStampCost: targetStampCost,
                      stampCostFlexibility: stampCostFlexibility, peering: peering)
        }
    }

    public struct PendingGet: Equatable {
        public var linkID: Data
        public var requestID: Data
    }

    public enum Action: Equatable {
        case client(LXMFNode.Action)
        case pn(PropagationNode.Action)
        case registerPropagation
        case setNodeMode(Bool)
        /// The peer-sync job (`sync_peers`, every 24 s: LXMRouter.py:38, :973). Sent by the timer
        /// `setNodeMode(true)` starts; ignored with node mode off.
        case peerSyncTick
        /// A peering key mined for `peer`, worth `value` (internal: the key search's result).
        case peeringKeyReady(peer: Data, key: Data, value: Double)
        /// The key search for `peer` failed or was cancelled (internal).
        case peeringKeyFailed(peer: Data)
        /// `PATH_REQUEST_GRACE` after a path request for `peer`'s sync link ran out (internal).
        case peerPathRequestGraceElapsed(peer: Data)
        /// A sync link saw no sync activity for `peerLinkStallTimeout` (internal).
        case peerLinkStalled(linkID: Data)
        /// A relaunch: the stored entries (each `lxmf_data ‖ stamp`, as `PropagationStore.Entry.lxmfData`
        /// holds it) and the persisted peers (`Delegate.peersChanged`), in ONE action so the order is
        /// fixed: the entries are ingested first, WITHOUT distribution to peers and without
        /// `messagesStored` (an eviction still reports `messagesPurged`), then each peer is loaded with
        /// its handled and unhandled ids pruned to the store (as `LXMPeer.from_bytes` does) — Review
        /// Focus 3. A peer already in the table is replaced; a sync link it held is closed and its key
        /// search cancelled first.
        case rehydrate(entries: [Data], peers: [PNPeerTable.Peer])
        /// The configured static peers (lxmd `static_peers`): each gets a table entry, with a path
        /// request when it has never been heard (LXMRouter.py:728-737). Never culled.
        case setStaticPeers(Set<Data>)
        /// lxmd `autopeer` (default true).
        case setAutopeer(Bool)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            /// Entries just accepted into the store — the host persists these.
            case messagesStored(entries: [PropagationStore.Entry])
            /// Entries just removed — the host deletes its mirrored copies.
            case messagesPurged(transientIds: [Data])
            /// The peer table changed: `peering.persisted`, every peer in table order. Emitted at most
            /// once per action, after it. The host replaces its stored copy and hands it back with
            /// `.rehydrate(entries:peers:)`. It includes each peer's cached peering key (ruling 6c).
            case peersChanged([PNPeerTable.Peer])
        }
    }

    enum CancelID: Hashable { case peerSyncJob, peeringKey(Data), peerPathGrace(Data), peerLinkStall(Data) }

    /// How long a sync link may go without sync activity (establishment, the `/offer` going out, its
    /// answer, sender progress on the transfer) before this node closes it: RNS's `Link.STALE_TIME`,
    /// `STALE_FACTOR` 2 × `KEEPALIVE` 360 s = 720 s (Link.py:92-99), the silence after which reference
    /// itself declares a link stale. Reference's own sync has no separate bound; it relies on the
    /// request timeout (which `LinkSession` reports as `requestFailed`) and on the resource's own
    /// failure. This bound catches the case those miss: a peer that keeps the link alive with
    /// keepalives but stops moving the transfer. Progress is reported per whole percent, so even a
    /// 256 KB transfer at LoRa rates (about 2.6 KB per percent at ~25 B/s ≈ 100 s) re-arms well
    /// inside it.
    public static let peerLinkStallTimeout: TimeInterval = 720

    @Dependency(\.date) var date
    @Dependency(\.continuousClock) var clock
    @Dependency(\.withRandomNumberGenerator) var withRandomNumberGenerator
    @Dependency(\.lxmfStampGenerator) var stampGenerator
    public init() {}

    /// Reference's hop count for a path or announce that ReTiCA holds at `wireHops`: reference adds
    /// one on receipt (RNS Transport.py:2028), ReTiCA keeps the on-wire count (Transport.swift, the
    /// `LearnedDestination` built from `packet.hops`). Every `autopeerMaxDepth` comparison goes
    /// through this, so both auto-peer paths (announce and inbound sync) peer at depth 6 and not 7.
    static func referenceHops(_ wireHops: UInt8) -> UInt8 {
        wireHops == .max ? .max : wireHops + 1
    }

    private static func arrayOfBin(_ value: MsgPackValue) -> [Data] {
        guard case let .array(items) = value else { return [] }
        return items.compactMap { if case let .bin(d) = $0 { return d } else { return nil } }
    }

    /// The `/get` per-transfer cap in bytes, from a floating-point `data[2]` in kilobytes.
    ///
    /// Shared by the `.double` (float64, 0xCB) and `.float` (float32, 0xCA) branches of the
    /// transfer-limit switch, deliberately: they had drifted apart once already — `.float` was simply
    /// missing, so a float32 cap fell to `default: break` and became nil = NO CAP, strictly more
    /// permissive than reference. One function means one set of guards to get right.
    ///
    /// Guard every non-finite and negative value BEFORE converting: `Int(Double)` traps on NaN and on
    /// anything outside Int's range, and `raw >= x` is FALSE for NaN — so the NaN bound has to be an
    /// explicit isNaN test, not a comparison.
    ///
    /// Reference keeps the cap as a FLOAT and never converts it to an int:
    ///   client_transfer_limit = float(data[2])*1000      (LXMF 1.1.0 LXMRouter.py:1528, in a
    ///                                                     bare `try/except: pass`)
    ///   if limit != None and next_size > limit: pass     (LXMRouter.py:1547 — skip)
    /// Verified by reading the installed LXMF 1.1.0 source and modelling :1525-1547; `int()` appears
    /// nowhere, so no ValueError/OverflowError is ever raised there and the behaviour is decided
    /// entirely by float comparison. That matters because EVERY comparison against NaN is false,
    /// which flips the outcome:
    ///   - -inf / large finite negative / -0.0 / 0: `next_size > limit` is true, so reference skips
    ///     every message and serves nothing. Our 0 matches exactly.
    ///   - large finite positive, +inf, and any kb whose *1000 overflows to +inf: `next_size > limit`
    ///     is false, so reference serves everything. The Int.max clamp matches exactly — +inf
    ///     included. (By a different route: reference never overflows because Python floats saturate
    ///     to inf and inf loses the comparison; we saturate the cap instead. Same outcome.)
    ///   - NaN: `next_size > nan` is FALSE, so reference takes the else branch and serves EVERYTHING —
    ///     a NaN cap silently disables the cap. We serve NOTHING. DELIBERATE DIVERGENCE, and the one
    ///     place this path does not match reference: treating a hostile NaN as "no cap" lets any
    ///     client opt out of the limit it just asked for, so we take the restrictive direction. No
    ///     legitimate client sends NaN, so there is no interop cost. Pinned by
    ///     serviceNodeParsesNaNTransferLimitAsZero (float64) and serviceNodeParsesNaNFloat32-
    ///     TransferLimitAsZero (float32).
    /// -0.0 reaches 0 via the conversion, not the negative arm: IEEE 754 makes `-0.0 < 0` false.
    /// Reference's `next_size > -0.0` is true → serves nothing, so 0 is also the parity-correct
    /// answer. Pinned by the -0.0 tests.
    private static func transferLimitBytes(kilobytes kb: Double) -> Int {
        let raw = kb * 1000
        if raw.isNaN || raw < 0 { return 0 }
        if raw >= Double(Int.max) { return Int.max }
        return Int(raw)
    }

    public var body: some ReducerOf<Self> {
        Scope(state: \.client, action: \.client) { LXMFNode() }
        Scope(state: \.pn, action: \.pn) { PropagationNode() }
        Reduce { [date, clock, stampGenerator] state, action in
            /// True when this link terminates on the lxmf.propagation destination WE serve — i.e. the
            /// peer is a propagation client of ours, not a direct correspondent.
            func isPropagationLink(_ state: State, _ linkID: Data) -> Bool {
                guard let served = state.client.propagationDestinationHash else { return false }
                return state.client.linkDestinations[linkID] == served
            }

            /// The propagation-node announce app data. ONE construction, two callers
            /// (`.registerPropagation` with `nodeState: true`, `setNodeMode(false)` with `false`) —
            /// they differ in that flag and nothing else.
            ///
            /// Extracted because the two were verbatim copies. Every field below is read from a
            /// single source of truth rather than mirrored, and the reason is concrete: a mirrored
            /// copy is what let this node advertise `targetStampCost: 0` while `PropagationStore`
            /// enforced 16. Duplicating the whole construction re-armed exactly that hazard on the
            /// second copy.
            ///
            /// The limits are a REQUEST our peers honour, not a promise we keep: a peer stores them
            /// on its `LXMPeer` record for US and filters its own outbound offer against them
            /// (LXMPeer.py:370). 0 meant "no message may ever be sent to me" — and reference marks
            /// each oversized message handled, so it dropped everything, permanently.
            func pnAnnounceAppData(_ state: State, nodeState: Bool) -> Data {
                PNAnnounce(timebase: Int(date.now.timeIntervalSince1970),
                           nodeState: nodeState,
                           perTransferLimit: LXMFPropagation.defaultPropagationTransferLimitKB,
                           perSyncLimit: LXMFPropagation.defaultPropagationSyncLimitKB,
                           // The values `PropagationStore.ingest` actually enforces: it accepts
                           // at max(0, cost - flex).
                           targetStampCost: state.pn.store.targetStampCost,
                           stampCostFlexibility: state.pn.store.stampCostFlexibility,
                           // The cost `/offer` validates peering keys at, read from the same
                           // config, so advertised == enforced (lxmd's default 18).
                           peeringCost: state.peering.config.peeringCost).packed
            }

            /// A remote identity's propagation destination hash: reference's
            /// `RNS.Destination(remote_identity, OUT, SINGLE, APP_NAME, "propagation").hash`.
            func propagationHash(of identity: Identity) -> Data {
                Destination.hash(identityHash: identity.hash, appName: LXMessage.appName, aspects: ["propagation"])
            }

            /// Ingests a container that arrived on a propagation link and accounts it in the peer
            /// table. `source` is the sending peer's propagation hash when that peer is in the table.
            ///
            /// Reference marks each validated id handled for the sending peer, fresh or duplicate
            /// (`queue_handled_message` after every `lxmf_propagation`, LXMRouter.py:2765-2784), and
            /// queues each FRESH id for every other peer (`enqueue_peer_distribution(transient_id,
            /// from_peer)`, :2882, flushed by :2811-2824). The handled set here is the fresh ids
            /// plus entries byte-identical to ones already stored: `ingest` skips a stored entry before
            /// validating it, and a byte-identical one is known valid because it was accepted.
            ///
            /// Known divergence: an entry pairing a stored core with a DIFFERENT stamp is not counted.
            /// Reference validates it, and when that other stamp is also valid (a sender that stamped the
            /// same message twice, or a peer holding another copy) it marks the id handled for the peer;
            /// we do not, because `ingest` skips the stored core before any validation and validating
            /// here would cost a 256 KB workblock per such entry. The cost is one wasted offer round
            /// trip: we offer the id back to that peer, it answers that it has it, and that marks it.
            /// An entry whose other stamp is invalid is not counted by reference either.
            ///
            /// Done here rather than through `PropagationNode.ingestContainer` because only this
            /// reducer knows the source, and the pre-ingest store state is needed for the duplicates.
            /// The same `PropagationNode` delegates are sent, so the host-facing signals are unchanged.
            func ingest(_ state: inout State, _ container: Data, from source: Data?) -> Effect<Action> {
                let (container, local) = deliverOwn(&state, container, from: source)
                var duplicates: [Data] = []
                if source != nil, let (_, entries) = LXMFPropagation.parseContainer(container) {
                    duplicates = entries.compactMap { entry in
                        guard state.pn.store.containsIdenticalStampedEntry(entry) else { return nil }
                        return state.pn.store.preflightTransientId(ofStampedEntry: entry)
                    }
                }
                let (added, evicted) = state.pn.store.ingest(container: container, now: date.now)
                if let source { state.peering.markHandled(added + duplicates, for: source) }
                state.peering.distribute(added, from: source)
                var effects: [Effect<Action>] = local + [
                    .send(.pn(.delegate(.stored(transientIds: added)))),
                    .send(.pn(.delegate(.storedEntries(entries: state.pn.store.entries(forTransientIds: added))))),
                ]
                // The `.purged` handler prunes the peer table, as it does for every removal route.
                if !evicted.isEmpty { effects.append(.send(.pn(.delegate(.purged(transientIds: evicted))))) }
                return .merge(effects)
            }

            /// Reference `lxmf_propagation` (LXMRouter.py:2852-2866): an entry addressed to one of OUR
            /// delivery destinations is decrypted and delivered locally with method PROPAGATED, and is
            /// neither stored nor queued for peer distribution. Final review I3: without this, a
            /// message for this device that a peer synced to us (the normal route once we peer) was
            /// stored, forwarded to every other peer, and never shown.
            ///
            /// Splits such entries off `container` and returns the rest, re-packed, for the store,
            /// plus the delivery effects. Each split-off entry must carry a valid stamp at the store's
            /// acceptance cost, as reference delivers only `validated_messages` (an invalid one is
            /// dropped, as `ingest` drops it). Its transient id is marked handled for `source` (the
            /// sending peer: reference `queue_handled_message` after every `lxmf_propagation`,
            /// :2783-2784) and recorded as downloaded by our router, so a later `/get` at our own
            /// propagation node purges it there as a have. One already downloaded is not delivered
            /// again (reference's `locally_processed_transient_ids`); the router's message-hash dedup
            /// backs that up. An entry that does not decrypt is dropped, as reference drops it.
            ///
            /// The delivery goes through `LXMFNode.propagatedDelivery`, the path `/get` downloads take:
            /// this reducer composes the client (`state.client`), so its delivery destination,
            /// identity and ratchets are right here, and the router's `messageDelivered` reaches the
            /// host through `LXMFNode`'s delegate as any other delivery does.
            func deliverOwn(_ state: inout State, _ container: Data,
                            from source: Data?) -> (container: Data, effects: [Effect<Action>]) {
                guard let delivery = state.client.deliveryDestinationHash,
                      let (timestamp, entries) = LXMFPropagation.parseContainer(container),
                      entries.contains(where: { LXMFPropagation.destinationHash(lxmfData: $0) == delivery })
                else { return (container, []) }
                let store = state.pn.store
                var kept: [Data] = [], handled: [Data] = [], effects: [Effect<Action>] = []
                for entry in entries {
                    guard LXMFPropagation.destinationHash(lxmfData: entry) == delivery else {
                        kept.append(entry)
                        continue
                    }
                    let core: Data
                    if store.targetStampCost > 0 {
                        guard let validated = LXStamper.validatePnStamp(transientData: entry,
                                                                        targetCost: store.minAcceptedStampCost)
                        else { continue }
                        core = validated.lxmfData
                    } else {
                        core = LXMFPropagation.strippedCore(lxmfData: entry)
                    }
                    let tid = LXMFPropagation.transientId(lxmfData: core)
                    handled.append(tid)
                    guard !state.client.router.downloadedTransientIds.contains(tid),
                          let delivered = LXMFNode.propagatedDelivery(state.client, lxmfData: core) else { continue }
                    effects.append(.send(.client(.router(delivered))))
                }
                if !handled.isEmpty {
                    if let source { state.peering.markHandled(handled, for: source) }
                    effects.append(.send(.client(.router(.propagatedMessagesDeliveredLocally(transientIds: handled)))))
                }
                return (LXMFPropagation.container(timestamp: timestamp, entries: kept), effects)
            }

            /// The response body for a request: `umsgpack.packb(value)`.
            func respond(_ linkID: Data, _ requestID: Data, _ value: MsgPackValue) -> Effect<Action> {
                .send(.client(.endpoint(.sendResponseOverLink(linkID: linkID, requestID: requestID,
                                                              data: MsgPack.encode(value)))))
            }

            // --- Peering: `PNPeerTable`'s host ---

            /// The peer whose sync link `linkID` is, if any. Only an ESTABLISHED sync link has an id.
            func peerOnLink(_ state: State, _ linkID: Data) -> Data? {
                state.peering.peers.values.first { $0.linkID == linkID }?.destinationHash
            }

            /// Opens a sync link to `peer`, owned by this reducer.
            func openSyncLink(_ state: inout State, _ peer: Data) -> Effect<Action> {
                state.peerLinkOpens[peer, default: 0] += 1
                return .send(.client(.endpoint(.openOwnedLink(destinationHash: peer, owner: .propagationPeerSync))))
            }

            /// (Re)arms the stall bound on sync link `linkID`.
            func armStall(_ linkID: Data) -> Effect<Action> {
                .run { send in
                    try await clock.sleep(for: .seconds(LXMFServiceNode.peerLinkStallTimeout))
                    await send(.peerLinkStalled(linkID: linkID))
                }.cancellable(id: CancelID.peerLinkStall(linkID), cancelInFlight: true)
            }

            /// Carries out the table's commands. Link packets (identify, `/offer`, the resource, closes)
            /// go out in command order, before the offer a caller appends; timers and key searches run
            /// alongside. With node mode off only closes go out (ruling 6b), and a command that would
            /// have started work is reported back to the table as that work's failure, so no peer is
            /// left waiting for an outcome that will never come.
            func interpret(_ commands: [PNPeerTable.Command], _ state: inout State,
                           ordered: inout [Effect<Action>], concurrent: inout [Effect<Action>]) {
                let now = date.now
                for command in commands {
                    switch command {
                    case let .closeLink(link):
                        state.peerTransferBytes[link] = nil
                        ordered.append(.send(.client(.endpoint(.closeLink(linkID: link)))))

                    case let .openLink(peer):
                        guard state.nodeModeEnabled else { state.peering.linkFailed(peer: peer, now: now); continue }
                        // Reference `sync()` (LXMPeer.py:297-306): with no path, request one, wait
                        // PATH_REQUEST_GRACE, and give up (`linkFailed`) if there is still none.
                        if state.client.endpoint.transport.reachableLearned(peer) != nil {
                            ordered.append(openSyncLink(&state, peer))
                        } else {
                            state.peerPathWaits.insert(peer)
                            ordered.append(.send(.client(.endpoint(.requestPath(destinationHash: peer)))))
                            concurrent.append(.run { send in
                                try await clock.sleep(for: .seconds(PNPeerTable.pathRequestGrace))
                                await send(.peerPathRequestGraceElapsed(peer: peer))
                            }.cancellable(id: CancelID.peerPathGrace(peer), cancelInFlight: true))
                        }

                    case let .identify(link):
                        guard state.nodeModeEnabled else { continue }
                        ordered.append(.send(.client(.endpoint(.identifyOverLink(linkID: link,
                                                                                 identity: state.client.identity)))))

                    case let .generatePeeringKey(peer, cost):
                        // `LXMPeer.generate_peering_key` (LXMPeer.py:240-267): a stamp over the peer's
                        // identity hash followed by ours, on the 25-round workblock. Its value is
                        // recorded with it, so a later, higher cost discards it (ruling 6c).
                        guard state.nodeModeEnabled,
                              let identity = state.client.endpoint.recall(destinationHash: peer) else {
                            state.peering.keyFailed(peer: peer, now: now)
                            continue
                        }
                        // One search at a time (final review minor 2). A cost-26 search takes minutes
                        // on a phone and two at once starve a 2-core pool (`LXStamper.swift`'s note),
                        // while up to `maxPeers` new peers would each start one. Every running search
                        // is a peer in `.keyPending` (it leaves that state when the search reports, is
                        // cancelled, or its peer leaves), so another such peer means one is running:
                        // this peer goes back to idle, unpenalised, for a later tick to pick.
                        if state.peering.peers.values.contains(where: { $0.destinationHash != peer && $0.state == .keyPending }) {
                            state.peering.keyDeferred(peer: peer)
                            continue
                        }
                        let peeringID = identity.hash + state.client.identity.hash
                        concurrent.append(.run { send in
                            guard let key = await stampGenerator.peeringKey(peeringID, cost) else {
                                await send(.peeringKeyFailed(peer: peer))
                                return
                            }
                            let workblock = LXStamper.stampWorkblock(material: peeringID,
                                                                     expandRounds: LXStamper.workblockExpandRoundsPeering)
                            await send(.peeringKeyReady(peer: peer, key: key,
                                                        value: LXStamper.stampValue(workblock: workblock, stamp: key)))
                        }.cancellable(id: CancelID.peeringKey(peer), cancelInFlight: true))

                    case let .sendOffer(link, key, ids):
                        guard state.nodeModeEnabled else {
                            state.peering.linkClosed(linkID: link)
                            ordered.append(.send(.client(.endpoint(.closeLink(linkID: link)))))
                            continue
                        }
                        // `[peering_key, offered_ids]` (LXMPeer.py:390-393).
                        let body = MsgPack.encode(.array([.bin(key), .array(ids.map { .bin($0) })]))
                        ordered.append(.send(.client(.endpoint(.sendRequestOverLink(linkID: link, path: "/offer",
                                                                                    data: body)))))

                    case let .sendResource(link, ids):
                        let entries = state.pn.store.entries(forTransientIds: ids)
                        // Nothing left to send (evicted since the offer), or node mode off: the
                        // transfer fails, which closes the link and marks nothing.
                        guard state.nodeModeEnabled, !entries.isEmpty else {
                            interpret(state.peering.transferFailed(linkID: link), &state,
                                      ordered: &ordered, concurrent: &concurrent)
                            continue
                        }
                        // Reference packs `[time.time(), lxm_list]` (LXMPeer.py:474-478).
                        let container = LXMFPropagation.container(timestamp: now.timeIntervalSince1970,
                                                                  entries: entries.map(\.lxmfData))
                        state.peerTransferBytes[link] = [0: container.count]
                        ordered.append(.send(.client(.endpoint(.sendResourceOverLink(linkID: link, data: container)))))

                    case let .requestPath(peer):
                        guard state.nodeModeEnabled else { continue }
                        ordered.append(.send(.client(.endpoint(.requestPath(destinationHash: peer)))))
                    }
                }
            }

            /// The offer reference's `sync()` prepares on a ready link (LXMPeer.py:339-395), when `peer`
            /// is left in `.linkReady`: the store's candidates among its unhandled ids, at its accepted
            /// cost and limits, with the unhandled ids the store no longer holds as `purged`.
            func offerIfReady(_ state: inout State, _ peer: Data) -> [PNPeerTable.Command] {
                guard let p = state.peering.peers[peer], p.state == .linkReady, let link = p.linkID else { return [] }
                guard state.nodeModeEnabled, let announce = p.announce else {
                    state.peering.linkClosed(linkID: link)
                    return [.closeLink(link)]
                }
                let store = state.pn.store
                let purged = p.unhandled.filter { !store.contains(transientId: $0) }
                    .sorted { $0.lexicographicallyPrecedes($1) }
                let selection = store.offerCandidates(
                    acceptedAt: LXMFPropagation.peerMinimumAcceptedCost(announce),
                    transferLimitKB: announce.perTransferLimit, syncLimitKB: announce.perSyncLimit,
                    among: p.unhandled, excluding: p.handled, now: date.now)
                return state.peering.offerSelected(peer: peer, offer: selection.offer, oversized: selection.oversized,
                                                   lowValue: selection.lowValue, purged: purged, now: date.now)
            }

            /// Runs `commands`, then makes the offer when `offerFor` was left link-ready.
            func run(_ commands: [PNPeerTable.Command], _ state: inout State, offerFor peer: Data? = nil) -> Effect<Action> {
                var ordered: [Effect<Action>] = [], concurrent: [Effect<Action>] = []
                interpret(commands, &state, ordered: &ordered, concurrent: &concurrent)
                if let peer {
                    interpret(offerIfReady(&state, peer), &state, ordered: &ordered, concurrent: &concurrent)
                }
                if ordered.isEmpty, concurrent.isEmpty { return .none }
                return .merge([.concatenate(ordered)] + concurrent)
            }

            /// Every configured static peer in the table, and a path request for each one never heard
            /// (LXMRouter.py:702-704 for a loaded one, :728-737 for a new one): its costs come only
            /// from an announce or a path response (Handlers.py:76-86).
            func activateStaticPeers(_ state: inout State) -> [PNPeerTable.Command] {
                var commands = state.peering.activateStaticPeers(now: date.now)
                for dest in state.peering.config.staticPeers.sorted(by: { $0.lexicographicallyPrecedes($1) })
                where state.peering.peers[dest]?.lastHeard == PNPeerTable.never && !commands.contains(.requestPath(dest)) {
                    commands.append(.requestPath(dest))
                }
                return commands
            }

            /// The 24 s peer-sync job.
            func peerSyncJob() -> Effect<Action> {
                .run { send in
                    for await _ in clock.timer(interval: .seconds(PNPeerTable.peerSyncInterval)) {
                        await send(.peerSyncTick)
                    }
                }.cancellable(id: CancelID.peerSyncJob, cancelInFlight: true)
            }

            func handle(_ state: inout State, _ action: Action) -> Effect<Action> {
            switch action {
            case let .setNodeMode(enabled):
                // ENABLE is deliberately NOT idempotence-guarded, and that asymmetry is a judgement
                // call rather than an oversight: a redundant enable has a defensible "refresh my
                // announce" reading, whereas a redundant disable has none. The cost is real though
                // — ReTiCaMsgr drives this from a settings toggle, and N redundant enables emit N
                // unpaced announces on every interface. Revisit together with a general rate limit
                // on locally-originated announces, which `Transport` does not have (it paces only
                // RELAYED announces).
                //
                // Reference's `enable_propagation` re-announces on every call too
                // (`announce_propagation_node()`, LXMRouter.py:780, LXMF 1.3.0), so the announce stays.
                //
                // Enabling also activates the static peers, as reference's `enable_propagation` does
                // (LXMRouter.py:728-737), and starts the peer-sync job (ruling 6b: it runs only in node
                // mode) — but only when it is not already running (final review I2). Restarting it
                // reset the 24 s period: ReTiCaMsgr sends `setNodeMode(true)` on every
                // `interfaceConnected`, so interfaces coming up more often than every 24 s (BLE peers
                // in a crowd, a flapping hub) meant `.peerSyncTick` never fired and nothing was
                // forwarded to peers. Reference's sync job is its job loop, which enabling never
                // touches.
                if enabled {
                    state.nodeModeEnabled = true
                    let job: Effect<Action> = state.peerSyncJobRunning ? .none : peerSyncJob()
                    state.peerSyncJobRunning = true
                    return .merge(.send(.registerPropagation), job,
                                  run(activateStaticPeers(&state), &state))
                }
                // Disabling is idempotent. Without this guard N calls with the mode already off
                // produced N unpeer announces on every interface, and `Transport` does not pace
                // locally-originated announces. Reference's `disable_propagation`
                // (LXMRouter.py:692-694) is equally unguarded — but parity with an unguarded
                // function is not a bound, and the serve-side state cleared below cannot have been
                // repopulated meanwhile: both writers (`linkIdentified` → `clientIdentities`,
                // `requestReceived` → `pendingGet`) are themselves gated on `nodeModeEnabled`.
                guard state.nodeModeEnabled else { return .none }
                state.nodeModeEnabled = false
                // Do NOT clear propagationDestinationHash on disable. The lxmf.propagation destination
                // cannot be unregistered, so links to it are still accepted. Keeping the classification
                // hint ensures arriving propagation data is recognised and DROPPED (because nodeModeEnabled
                // is false) rather than misclassified as a direct delivery message. Clearing serve-side
                // bookkeeping is sufficient — all serve behaviour is independently gated on nodeModeEnabled.
                state.clientIdentities = [:]
                state.pendingGet = [:]
                state.validatedOfferLinks = []
                // Re-announce with nodeState = false so peers unpeer immediately rather than continuing
                // to sync into a node that now drops everything. Reference: LXMRouter.disable_propagation
                // (LXMRouter.py:692-694) sets self.propagation_node = False then calls
                // announce_propagation_node() (LXMRouter.py:338-345), which announces with the new
                // node_state. Peers react in Handlers.py:98-99: unpeer(destination_hash) when
                // propagation_enabled == False. Guard on propagationDestinationHash: without it there
                // is no destination to announce on (enable_propagation must have run first).
                //
                // Peering (ruling 6b, Review Focus 5): the sync job stops, every key search and
                // path-grace wait is cancelled, and the sync links not yet transferring are closed, so
                // no further `/offer` or Resource goes out. A transfer already under way finishes; its
                // conclusion starts nothing new (`interpret` sends only closes in node mode off). Every
                // peer is idled through the table's own failure calls, and the table itself is kept:
                // nothing is unpeered. A cancelled search reports nothing (its effect is cancelled), so
                // the table is told here; a link still establishing stays counted in `peerLinkOpens`,
                // and the table closes it if it establishes later.
                state.peerSyncJobRunning = false
                var peering: [Effect<Action>] = [.cancel(id: CancelID.peerSyncJob)]
                for peer in state.peerPathWaits.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                    peering.append(.cancel(id: CancelID.peerPathGrace(peer)))
                }
                state.peerPathWaits = []
                for p in state.peering.persisted {
                    switch p.state {
                    case .keyPending:
                        peering.append(.cancel(id: CancelID.peeringKey(p.destinationHash)))
                        state.peering.keyFailed(peer: p.destinationHash, now: date.now)
                    case .linkEstablishing:
                        state.peering.linkFailed(peer: p.destinationHash, now: date.now)
                    case .linkReady, .requestSent:
                        guard let link = p.linkID else { continue }
                        state.peering.linkClosed(linkID: link)
                        peering.append(.send(.client(.endpoint(.closeLink(linkID: link)))))
                    case .idle, .transferring:
                        break
                    }
                }
                guard let hash = state.client.propagationDestinationHash else { return .merge(peering) }
                return .merge(peering + [.send(.client(.endpoint(.announce(
                    destinationHash: hash, appData: pnAnnounceAppData(state, nodeState: false)))))])

            case .registerPropagation:
                guard state.nodeModeEnabled,
                      let d = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                          aspects: ["propagation"], identity: state.client.identity)
                else { return .none }
                state.client.propagationDestinationHash = d.hash
                return .merge(
                    // LXMF 1.3.0's propagation link cost (LXMRouter.py:634), on the wire when stamping.
                    .send(.client(.endpoint(.registerLocalDestination(d, linkCost: LXMFPropagation.propagationLinkCost)))),
                    .send(.client(.endpoint(.announce(
                        destinationHash: d.hash,
                        appData: pnAnnounceAppData(state, nodeState: true))))))

            // --- Inbound offers (only on the link to the destination we serve) ---
            case let .client(.endpoint(.delegate(.resourceReceived(linkID, data)))):
                guard state.nodeModeEnabled, isPropagationLink(state, linkID) else { return .none }
                // Reference `propagation_resource_concluded` (LXMRouter.py:2669-2805). A container that
                // does not parse is ignored (:2795-2796).
                guard let (_, messages) = LXMFPropagation.parseContainer(data) else { return .none }
                var source: Data? = nil
                if let remote = state.clientIdentities[linkID] {
                    let remoteHash = propagationHash(of: remote)
                    // Auto-peer via incoming sync (:2682-2714): an unknown sender whose recalled
                    // announce says it is an enabled propagation node, within `autopeerMaxDepth`, is
                    // peered BEFORE the container is judged, so even a refused container peers it.
                    // `hops_to` is the path's hop count as reference counts it (`referenceHops`, the
                    // conversion the announce path uses too); with no path, reference's
                    // `PATHFINDER_M` (128) is over any depth.
                    if state.peering.peers[remoteHash] == nil, state.peering.config.autopeer,
                       let appData = state.client.endpoint.transport.recallAppData(destinationHash: remoteHash),
                       let announce = PNAnnounce.parse(appData), announce.nodeState,
                       let path = state.client.endpoint.learned[remoteHash],
                       LXMFServiceNode.referenceHops(path.hops) <= state.peering.config.autopeerMaxDepth {
                        // A new peer: `peer` returns no commands for one (only an unpeer closes a link).
                        _ = state.peering.peer(remoteHash, announce: announce, now: date.now)
                    }
                    if state.peering.peers[remoteHash] != nil { source = remoteHash }
                }
                // Only a link with a validated peering key (which requires an identity: `/offer` answers
                // ERROR_NO_IDENTITY without one) may deliver more than one message per container
                // (:2716-2724): anything else is torn down and nothing is ingested.
                if messages.count > 1, !state.validatedOfferLinks.contains(linkID) {
                    return .send(.client(.endpoint(.closeLink(linkID: linkID))))
                }
                return ingest(&state, data, from: source)

            case let .client(.endpoint(.delegate(.linkDataReceived(linkID, data, packetHash)))):
                guard state.nodeModeEnabled, isPropagationLink(state, linkID) else { return .none }
                // Reference LXMRouter.py:2252-2260: validate ALL entries in the container before deciding
                // whether to prove. If ANY entry fails stamp validation, send ERROR_INVALID_STAMP and tear
                // the link down — without a prove, which would falsely confirm delivery to the client.
                // If ALL entries pass (or the container is unstamped because targetStampCost == 0), prove the
                // packet to complete the client's receipt (reference LXMRouter.py:2255).
                //
                // Deliberately scoped: this is the ONLY place ReTiCA proves an inbound data packet.
                // RNS proves per-destination (`proof_strategy`, default PROVE_NONE), so a blanket
                // auto-prove would be wrong; the decision lives here, in the composition that knows
                // the link terminates on the lxmf.propagation destination we serve AND that node mode
                // is on. Resource-framed offers already get a resource proof from `ResourceTransfer`.
                //
                // Unparseable containers: guard on parseContainer so a malformed wire payload neither
                // proves nor ingests (reference LXMRouter.py:2262 except block skips the prove).
                guard let (_, entries) = LXMFPropagation.parseContainer(data) else { return .none }
                if state.pn.store.targetStampCost > 0 {
                    let anyRejected = entries.contains {
                        // Cheap dedup BEFORE the proof-of-work, and it has to be here rather than only
                        // in `PropagationStore.ingest`: this pre-scan runs first, so a replay used to
                        // pay a full 256 KB workblock per entry here and then hit ingest's dedup for
                        // free — measured 21.67 ms versus 0.0021 ms, a 10 328x bypass of the fix that
                        // was supposed to prevent exactly this. Reachable by any peer that can open a
                        // link to the propagation destination; the branch is gated on nodeModeEnabled
                        // and isPropagationLink only, with no identity check.
                        //
                        // Byte-identical replays only (`containsIdenticalStampedEntry`, not a
                        // stampless-core match). An entry that pairs a stored core with a different
                        // 32-byte tail carries a genuinely invalid stamp and must still earn
                        // ERROR_INVALID_STAMP plus teardown — a core-only match would silently
                        // convert that rejection into a prove. Such an entry therefore still pays the
                        // workblock; that is the junk-flood residue filed with the admission-control
                        // gap, not something dedup can close.
                        //
                        // One accepted edge: a stored entry was validated at whatever acceptance cost
                        // was in force when it was accepted, so raising the cost afterwards lets
                        // a replay of a now-under-cost entry be proved rather than rejected.
                        // Deliberate — we already hold the entry, so "I have this" is the true
                        // answer, and re-validating what we have already stored buys nothing.
                        //
                        // STILL OPEN, deliberately: an entry that is ACCEPTED is validated TWICE —
                        // once here and once inside PropagationStore.ingest. Measured at 2 workblock
                        // derivations per novel entry by
                        // serviceNodeDoesNotRederiveWorkblockForStoredPacketOfferReplay's liveness
                        // counter. Reference validates once and passes the validated lxmf_data
                        // onward (LXMF 1.1.0 LXMRouter.py:2243-2249), so this is a parity regression.
                        // Not fixed here: threading validated entries into ingest would give the
                        // store a second entry point that trusts its caller's validation, and an
                        // attacker can only reach this path at all by doing the ~2^cost work of a
                        // valid stamp themselves. Filed with the admission-control gap.
                        !state.pn.store.containsIdenticalStampedEntry($0)
                            && LXStamper.validatePnStamp(transientData: $0,
                                                         targetCost: state.pn.store.minAcceptedStampCost) == nil
                    }
                    if anyRejected {
                        // Reference LXMRouter.py:2258-2260: send the error as a plain data packet, then teardown.
                        let errorBytes = MsgPack.encode(.array([.uint(LXMFPropagation.errorInvalidStamp)]))
                        return .merge(
                            .send(.client(.endpoint(.sendOverLink(linkID: linkID, data: errorBytes)))),
                            .send(.client(.endpoint(.closeLink(linkID: linkID)))))
                    }
                }
                // A packet comes from a client, never a peer: reference's `propagation_packet` passes no
                // `from_peer` (LXMRouter.py:2584), so every fresh id goes to every peer.
                return .merge(
                    ingest(&state, data, from: nil),
                    .send(.client(.endpoint(.provePacketOverLink(linkID: linkID, packetHash: packetHash)))))

            case let .client(.endpoint(.delegate(.linkIdentified(linkID, remoteIdentity)))):
                // Only record identity for links to OUR served propagation destination (Minor-4 / reference
                // LXMRouter.py:670: the /get handler is registered only on the propagation destination).
                guard state.nodeModeEnabled, isPropagationLink(state, linkID) else { return .none }
                state.clientIdentities[linkID] = remoteIdentity
                return .none

            // --- Two-phase /get ---
            case let .client(.endpoint(.delegate(.requestReceived(linkID, requestID, pathHash, data)))):
                // Guard on propagation-link classification (Minor-4): the /get handler is registered only
                // on the propagation destination (reference LXMRouter.py:670), so a /get on the delivery
                // link must be silently dropped rather than served.
                guard state.nodeModeEnabled, isPropagationLink(state, linkID) else { return .none }
                if pathHash == Crypto.truncatedHash(Data("/offer".utf8)) {
                    // Reference `offer_request` (LXMRouter.py:2601-2667), registered on the
                    // propagation destination only (LXMF 1.3.0 :764). Admission control (ERROR_THROTTLED,
                    // sequential validation, max inbound syncs, throttled peers, from_static_only) is
                    // not implemented: ruling 5a.
                    guard let remote = state.clientIdentities[linkID] else {
                        return respond(linkID, requestID, .uint(LXMFPropagation.errorNoIdentity))
                    }
                    // Ruling 5b: any body that is not an array of at least two elements with a bin key
                    // is ERROR_INVALID_DATA. Reference answers that only for a non-list shorter than 2
                    // and answers None (its `except`) for the rest, which no reference peer sends.
                    guard case let .array(items)? = MsgPack.decodeValue(data), items.count >= 2,
                          case let .bin(peeringKey) = items[0]
                    else { return respond(linkID, requestID, .uint(LXMFPropagation.errorInvalidData)) }
                    // Synchronous, as reference validates in the handler (ruling 5c): one 25-round
                    // workblock (6 400 bytes) and one hash.
                    let peeringID = state.client.identity.hash + remote.hash
                    guard LXStamper.validatePeeringKey(peeringId: peeringID, peeringKey: peeringKey,
                                                       targetCost: state.peering.config.peeringCost)
                    else { return respond(linkID, requestID, .uint(LXMFPropagation.errorInvalidKey)) }
                    state.validatedOfferLinks.insert(linkID)
                    // Reference iterates `data[1]` after validating; anything but a list of ids raises
                    // there and answers None (the link stays validated). Ruling 5b's answer instead.
                    guard case let .array(idItems) = items[1] else {
                        return respond(linkID, requestID, .uint(LXMFPropagation.errorInvalidData))
                    }
                    var offered: [Data] = []
                    for item in idItems {
                        guard case let .bin(id) = item else {
                            return respond(linkID, requestID, .uint(LXMFPropagation.errorInvalidData))
                        }
                        offered.append(id)
                    }
                    // Not `PropagationStore.wanted(fromOffered:)`, which de-duplicates: reference
                    // appends every offered id it lacks, repeats included, and compares that count to
                    // the offer's (an offer repeating an id we lack is answered `True`).
                    let wanted = offered.filter { !state.pn.store.contains(transientId: $0) }
                    if wanted.isEmpty { return respond(linkID, requestID, .bool(false)) }
                    if wanted.count == offered.count { return respond(linkID, requestID, .bool(true)) }
                    return respond(linkID, requestID, .array(wanted.map { .bin($0) }))
                }
                guard pathHash == Crypto.truncatedHash(Data("/get".utf8)) else { return .none }
                // Reference LXMRouter.py:1483 — `message_get_request` returns LXMPeer.ERROR_NO_IDENTITY
                // (0xF0) as the response BODY when the link never IDENTIFY'd. Reference clients branch on
                // exactly that value (LXMRouter.py:1563 / :1608) to tear the link down and set
                // PR_NO_IDENTITY_RCVD; dropping silently instead makes them wait out the full request
                // timeout. Encoded the way the reference does: umsgpack.packb(0xF0) → uint8 0xCC 0xF0.
                guard let clientIdentity = state.clientIdentities[linkID] else {
                    return .send(.client(.endpoint(.sendResponseOverLink(
                        linkID: linkID, requestID: requestID,
                        data: MsgPack.encode(.uint(LXMFPropagation.errorNoIdentity))))))
                }
                guard case let .array(items)? = MsgPack.decodeValue(data), items.count >= 2 else { return .none }
                let clientHash = LXMessage.deliveryHash(identityHash: clientIdentity.hash)
                let pending = PendingGet(linkID: linkID, requestID: requestID)
                // Queue the request (Minor-3): a client may have a concurrent in-flight /get (reference
                // LXMessage.py:616-621 tears down and retries on timeout). Appending preserves FIFO order;
                // the delegate pops the front when it responds.
                state.pendingGet[clientHash, default: []].append(pending)
                if case .null = items[0], case .null = items[1] {
                    return .send(.pn(.messageListRequested(destinationHash: clientHash)))
                }
                // Parse the optional third element as the client's per-transfer limit (Important-5).
                // Reference LXMRouter.py:1526-1529: client_transfer_limit = float(data[2])*1000.
                // The wire value may be a uint or a float (reference reads it via float()). Missing or
                // unparseable → nil (no limit). 0 is a valid 0-byte cap, NOT unlimited: the reference
                // computes `float(0)*1000 = 0.0` and then skips every message that would exceed it
                // (LXMRouter.py:1547), i.e. serves nothing. There is deliberately no `kb > 0` guard
                // here — that guard would silently turn a wire-level 0 into "unlimited".
                // Clamp: UInt64.max * 1000 overflows Int. Cap to Int.max when kb is too large.
                var transferLimitBytes: Int? = nil
                if items.count >= 3 {
                    switch items[2] {
                    case let .uint(kb):
                        transferLimitBytes = kb > UInt64(Int.max / 1000) ? Int.max : Int(kb) * 1000
                    case let .double(kb):
                        // float64 (0xCB). Every guard lives in transferLimitBytes(kilobytes:), shared
                        // with the .float branch below so the two cannot drift apart again.
                        transferLimitBytes = LXMFServiceNode.transferLimitBytes(kilobytes: kb)
                    case let .float(kb):
                        // float32 (0xCA) — the arm this switch was missing. Reference reads data[2]
                        // through `float()` (LXMF 1.1.0 LXMRouter.py:1528), which handles a float32
                        // exactly as it handles a float64, so falling to `default: break` left
                        // transferLimitBytes nil = NO CAP: strictly more permissive than reference,
                        // the identical failure the `.int` note below records one case over. Both
                        // arrived the same way — the decoder gained a type and this switch never grew
                        // the arm for it.
                        //
                        // Widen to Double BEFORE the *1000: Float arithmetic overflows a large float32
                        // to +-inf, whereas Float -> Double is lossless and Python's `float()` is a
                        // double, so this matches reference's arithmetic exactly. It is not a bug fix
                        // and no test pins it: the two routes return the same Int for every input
                        // (an overflow to +-inf lands on the clamp or the negative arm, which give the
                        // same answers as the finite comparisons do).
                        transferLimitBytes = LXMFServiceNode.transferLimitBytes(kilobytes: Double(kb))
                    case let .int(kb):
                        // A wire-decoded signed integer (e.g. int8(-1) = 0xFF). Before the decoder
                        // widening (177da8c) this type failed the msgpack parse and the whole request
                        // was rejected. Now it decodes as .int and fell to default: break → nil →
                        // unlimited — strictly more permissive than reference. Reference: `float(kb)*1000`
                        // on a negative kb produces a negative float, which is less than every message
                        // size, so nothing is served. We match that: negative → 0 (serve nothing).
                        // For non-negative: Int(kb) is an identity conversion (both are 64-bit Int/Int64),
                        // safe as long as kb <= Int.max / 1000. On this platform Int.max == Int64.max.
                        if kb < 0 {
                            transferLimitBytes = 0
                        } else if kb > Int64(Int.max / 1000) {
                            transferLimitBytes = Int.max
                        } else {
                            transferLimitBytes = Int(kb) * 1000
                        }
                    default: break
                    }
                }
                return .send(.pn(.messagesRequested(destinationHash: clientHash,
                                                    wants: LXMFServiceNode.arrayOfBin(items[0]),
                                                    haves: LXMFServiceNode.arrayOfBin(items[1]),
                                                    transferLimitBytes: transferLimitBytes)))

            case let .pn(.delegate(.deliverMessageList(dest, ids))):
                guard var queue = state.pendingGet[dest], !queue.isEmpty else { return .none }
                let p = queue.removeFirst()
                state.pendingGet[dest] = queue.isEmpty ? nil : queue
                return .send(.client(.endpoint(.sendResponseOverLink(
                    linkID: p.linkID, requestID: p.requestID,
                    data: MsgPack.encode(.array(ids.map { .bin($0) }))))))

            case let .pn(.delegate(.deliverMessages(dest, entries))):
                guard var queue = state.pendingGet[dest], !queue.isEmpty else { return .none }
                let p = queue.removeFirst()
                state.pendingGet[dest] = queue.isEmpty ? nil : queue
                return .send(.client(.endpoint(.sendResponseOverLink(
                    linkID: p.linkID, requestID: p.requestID,
                    data: MsgPack.encode(.array(entries.map { .bin($0) }))))))

            // --- Persistence signals out to the host ---
            case let .pn(.delegate(.storedEntries(entries))):
                guard !entries.isEmpty else { return .none }
                return .send(.delegate(.messagesStored(entries: entries)))

            case let .pn(.delegate(.purged(ids))):
                guard !ids.isEmpty else { return .none }
                // Every removal route reports here (a client's purge or delivery confirmation, and
                // eviction on ingest), so this is the one place the peer table is pruned, which
                // `PNPeerTable.prune(toStored:)` requires after every store removal.
                state.peering.prune(toStored: Set(state.pn.store.transientIds))
                return .send(.delegate(.messagesPurged(transientIds: ids)))

            // --- Link lifecycle cleanup ---
            case let .client(.endpoint(.delegate(.linkClosed(linkID, _)))):
                state.clientIdentities[linkID] = nil
                state.validatedOfferLinks.remove(linkID)
                // Drop all queued requests for this link; responses can never be delivered.
                state.pendingGet = state.pendingGet.compactMapValues { queue in
                    let remaining = queue.filter { $0.linkID != linkID }
                    return remaining.isEmpty ? nil : remaining
                }
                // A sync link: idle its peer (`link_closed`, LXMPeer.py:549-551), and end its stall
                // bound (built on this branch only: `.cancel` cancels when constructed).
                state.peerTransferBytes[linkID] = nil
                state.peerOfferRequests[linkID] = nil
                // A sync link closing under a transfer is a failed transfer: back off (minor 3).
                let failedTransfer = peerOnLink(state, linkID).flatMap { dest in
                    state.peering.peers[dest]?.state == .transferring ? dest : nil
                }
                state.peering.linkClosed(linkID: linkID)
                if let failedTransfer { state.peering.backOff(peer: failedTransfer, now: date.now) }
                return .cancel(id: CancelID.peerLinkStall(linkID))

            case let .client(.endpoint(.delegate(.requestFailed(linkID, requestID)))):
                state.pendingGet = state.pendingGet.compactMapValues { queue in
                    let remaining = queue.filter { $0.linkID != linkID }
                    return remaining.isEmpty ? nil : remaining
                }
                // Our `/offer` failed (`request_failed`, LXMPeer.py:400-403): only its own request id.
                guard peerOnLink(state, linkID) != nil,
                      state.peerOfferRequests[linkID].map({ $0 == requestID }) ?? true else { return .none }
                state.peerOfferRequests[linkID] = nil
                return run(state.peering.requestFailed(linkID: linkID), &state)

            case let .client(.endpoint(.delegate(.requestSent(linkID, requestID, path)))):
                guard path == "/offer", peerOnLink(state, linkID) != nil else { return .none }
                state.peerOfferRequests[linkID] = requestID
                return armStall(linkID)

            case let .peerLinkStalled(linkID):
                guard let dest = peerOnLink(state, linkID) else { return .none }
                state.peering.linkClosed(linkID: linkID)
                // A stalled sync is retried after a backoff step, not on the next tick (minor 3).
                state.peering.backOff(peer: dest, now: date.now)
                return run([.closeLink(linkID)], &state)

            // --- Peering: the client half ---

            case let .client(.endpoint(.delegate(.announceReceived(dest, hops, isPathResponse, appData)))):
                // `LXMFPropagationAnnounceHandler` (Handlers.py:56-107): registered for
                // `lxmf.propagation` only, and peering only while we are a propagation node.
                guard state.nodeModeEnabled, dest != state.client.propagationDestinationHash,
                      let appData, let announce = PNAnnounce.parse(appData),
                      let identity = state.client.endpoint.recall(destinationHash: dest),
                      propagationHash(of: identity) == dest
                else { return .none }
                return run(state.peering.announceHeard(dest, announce: announce,
                                                       hops: LXMFServiceNode.referenceHops(hops),
                                                       isPathResponse: isPathResponse, now: date.now), &state)

            case .peerSyncTick:
                guard state.nodeModeEnabled else { return .none }
                let now = date.now
                let table = state.peering
                let (ticked, commands) = withRandomNumberGenerator { generator in
                    var copy = table
                    let commands = copy.syncTick(now: now, random: &generator)
                    return (copy, commands)
                }
                state.peering = ticked
                return run(commands, &state)

            case let .peeringKeyReady(peer, key, value):
                return run(state.peering.keyReady(peer: peer, key: key, value: value, now: date.now), &state)

            case let .peeringKeyFailed(peer):
                state.peering.keyFailed(peer: peer, now: date.now)
                return .none

            case let .peerPathRequestGraceElapsed(peer):
                state.peerPathWaits.remove(peer)
                guard state.peering.peers[peer]?.state == .linkEstablishing else { return .none }
                if state.nodeModeEnabled, state.client.endpoint.transport.reachableLearned(peer) != nil {
                    return openSyncLink(&state, peer)
                }
                state.peering.linkFailed(peer: peer, now: date.now)
                return .none

            case let .client(.endpoint(.delegate(.ownedLinkEstablished(owner, linkID, dest)))):
                // Every sync link we opened goes to the table, which answers one for a peer not
                // establishing a link (unpeered, idled by node mode off, or already given an earlier
                // link after a node-mode off/on) with `.closeLink`, so none is left open.
                guard owner == .propagationPeerSync else { return .none }
                if let open = state.peerLinkOpens[dest] { state.peerLinkOpens[dest] = open > 1 ? open - 1 : nil }
                let commands = state.peering.linkEstablished(peer: dest, linkID: linkID, now: date.now)
                let stall = commands.contains(.closeLink(linkID)) ? Effect<Action>.none : armStall(linkID)
                return .merge(run(commands, &state, offerFor: dest), stall)

            case let .client(.endpoint(.delegate(.ownedLinkFailed(owner, dest, _)))):
                // THE call for every sync link that never establishes (no path, timed out, rejected,
                // key search failed or cancelled), but only for the last attempt outstanding.
                guard owner == .propagationPeerSync else { return .none }
                let open = state.peerLinkOpens[dest] ?? 0
                state.peerLinkOpens[dest] = open > 1 ? open - 1 : nil
                guard open <= 1 else { return .none }
                state.peering.linkFailed(peer: dest, now: date.now)
                return .none

            case let .client(.endpoint(.delegate(.responseReceived(linkID, requestID, data)))):
                guard let dest = peerOnLink(state, linkID), let p = state.peering.peers[dest],
                      p.state == .requestSent,
                      state.peerOfferRequests[linkID].map({ $0 == requestID }) ?? true else { return .none }
                state.peerOfferRequests[linkID] = nil
                let response = PNPeerTable.OfferResponse.parse(data, offered: p.lastOffer)
                // `noIdentity` leaves the peer link-ready on the same link: offer again.
                return .merge(run(state.peering.offerResponse(linkID: linkID, response, now: date.now), &state,
                                  offerFor: dest),
                              armStall(linkID))

            case let .client(.endpoint(.delegate(.resourceProgress(linkID, _, role, _, total, segment, _)))):
                guard role == .sender, var bytes = state.peerTransferBytes[linkID] else { return .none }
                bytes[0] = nil
                bytes[segment] = total
                state.peerTransferBytes[linkID] = bytes
                return armStall(linkID)

            case let .client(.endpoint(.delegate(.resourceConcluded(linkID, _)))):
                guard let dest = peerOnLink(state, linkID), state.peering.peers[dest]?.state == .transferring
                else { return .none }
                // `resource.get_transfer_size()` (LXMPeer.py:515): the bytes on the wire, which the
                // sender's progress reports per segment.
                let bytes = state.peerTransferBytes.removeValue(forKey: linkID)?.values.reduce(0, +) ?? 0
                return run(state.peering.transferConcluded(linkID: linkID, bytes: bytes, now: date.now), &state)

            case let .client(.endpoint(.delegate(.resourceFailed(linkID, _, _)))):
                guard let dest = peerOnLink(state, linkID), state.peering.peers[dest]?.state == .transferring
                else { return .none }
                state.peerTransferBytes[linkID] = nil
                let commands = state.peering.transferFailed(linkID: linkID)
                // Reference retries a failed transfer on the next sync job (LXMPeer.py:531-537), which
                // resends the whole container every 24 s to a peer whose transfers always fail; one
                // backoff step instead (final review minor 3).
                state.peering.backOff(peer: dest, now: date.now)
                return run(commands, &state)

            // --- Peering: configuration and persistence ---

            case let .rehydrate(entries, peers):
                // Entries first, so the peers are pruned to a full store (Review Focus 3). No
                // `distribute`: these entries were in the store before the relaunch, and each peer's
                // unhandled set comes back with it.
                var effects: [Effect<Action>] = []
                if !entries.isEmpty {
                    let container = LXMFPropagation.container(timestamp: date.now.timeIntervalSince1970,
                                                              entries: entries)
                    let (_, evicted) = state.pn.store.ingest(container: container, now: date.now)
                    if !evicted.isEmpty { effects.append(.send(.pn(.delegate(.purged(transientIds: evicted))))) }
                }
                // A peer being replaced mid-sync: close the link it holds and stop its key search, which
                // `rehydrate` would otherwise forget (its fresh state is idle, link-less).
                for loaded in peers {
                    guard let current = state.peering.peers[loaded.destinationHash] else { continue }
                    if let link = current.linkID {
                        state.peering.linkClosed(linkID: link)
                        effects.append(.send(.client(.endpoint(.closeLink(linkID: link)))))
                    }
                    if current.state == .keyPending {
                        effects.append(.cancel(id: CancelID.peeringKey(loaded.destinationHash)))
                    }
                }
                state.peering.rehydrate(peers, stored: Set(state.pn.store.transientIds))
                if state.nodeModeEnabled { effects.append(run(activateStaticPeers(&state), &state)) }
                return .merge(effects)

            case let .setStaticPeers(peers):
                state.peering.config.staticPeers = peers
                guard state.nodeModeEnabled else { return .none }
                return run(activateStaticPeers(&state), &state)

            case let .setAutopeer(enabled):
                state.peering.config.autopeer = enabled
                return .none

            case .client, .pn, .delegate:
                return .none
            }
            }

            // `peersChanged`: once per action that changed the persisted table, after it. Comparing
            // the table first is cheap when nothing touched it (copy-on-write storage compares by
            // identity); `persisted` then decides, so a config-only change reports nothing.
            if case .delegate = action { return handle(&state, action) }
            let before = state.peering
            var effect = handle(&state, action)
            guard state.peering != before else { return effect }
            // A peer that left the table (unpeered, culled) while mining a key: stop the search, which
            // would otherwise run on to completion (up to cost 26) for nobody.
            for (dest, p) in before.peers where p.state == .keyPending && state.peering.peers[dest] == nil {
                effect = .merge(effect, .cancel(id: CancelID.peeringKey(dest)))
            }
            guard state.peering.persisted != before.persisted else { return effect }
            return .merge(effect, .send(.delegate(.peersChanged(state.peering.persisted))))
        }
    }
}
