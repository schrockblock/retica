import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCATransport

/// LXMF propagation-node SERVER composition (P3b): composes `TCPEndpoint` + `PropagationNode` so a node
/// registers/announces `lxmf.propagation`, ingests clients' concluded containers, and serves the two-phase
/// `/get` download. `/get` is handled via the unregistered-request surface (registered paths auto-respond
/// through a static dependency that cannot read the store). Mirrors lxmf 1.1.0 LXMRouter propagation serve.
@Reducer
public struct PNNode {
    @ObservableState
    public struct State: Equatable {
        public var endpoint: TransportEndpoint.State
        public var node: PropagationNode.State
        public var identity: Identity
        /// Required cost for inbound `/offer` peering keys, advertised in our announce (LXMF 1.3.0
        /// `peering_cost`, fractional). Sanitized on every write as a configured flexibility is
        /// (`PropagationStore.sanitizedNonNegative`): negative → 0, NaN / +infinity / 100 or more
        /// refused and the previous value kept (0 at `init`).
        public var peeringCost: Double = 0 {
            didSet { peeringCost = PropagationStore.sanitizedNonNegative(peeringCost, otherwise: oldValue) }
        }
        public var clientIdentities: [Data: Identity] = [:]   // linkID → IDENTIFY'd client
        public var pendingGet: [Data: PendingGet] = [:]        // client delivery hash → (linkID, requestID)
        public var pendingOffer: [Data: PendingOffer] = [:]   // peerHash → (linkID, requestID, offeredIds)
        public var pendingSyncPeers: [Data: Double] = [:]  // peer dest → the peer's peering cost, awaiting linkEstablished
        public var offerLinks: [Data: [Data]] = [:]        // outbound offer linkID → offeredIds we sent
        /// Outbound offer linkID → the peer it syncs to, so the offer response and the transfer's
        /// conclusion can mark that peer's handled ids. Cleared with the link.
        public var offerLinkPeers: [Data: Data] = [:]
        /// Outbound offer linkID → the ids in the sync transfer on it, marked handled for the peer once
        /// the transfer concludes (reference `resource_concluded`, LXMPeer.py:505-507). Cleared with the
        /// link, or when the transfer fails, as reference marks nothing then.
        public var syncTransfers: [Data: [Data]] = [:]
        /// Peer propagation-node hash → the transient ids never to offer that peer again: reference's
        /// per-peer handled list (`propagation_entries[tid][4]`, LXMPeer.py:580-585) together with the
        /// ids reference drops from the peer's unhandled list without marking handled (low value,
        /// LXMPeer.py:359-361), since neither is offered again. An id becomes handled when it is
        /// oversized for the peer (LXMPeer.py:375-378), below its stamp cost, declined in its offer
        /// response (:432-437, :448-453), sent to it in a concluded transfer (:505-507), or offered to
        /// us by it (see `peerValidated`).
        ///
        /// In memory only: a relaunch forgets it, costing one redundant offer per peer (the peer
        /// declines what it has, and that marks them again). Holds only ids the store holds: each
        /// time a peer's set is touched it is pruned to them (reference's lists live inside the store
        /// entries and go with them), and a set that prunes to empty is removed. A set is not pruned
        /// when an entry leaves the store between touches, so it can outlive its entries until then.
        public var handledByPeer: [Data: Set<Data>] = [:]
        public init(identity: Identity, endpoint: TransportEndpoint.State, storageLimitBytes: Int? = nil,
                    targetStampCost: Double = LXMFPropagation.defaultPropagationStampCost,
                    stampCostFlexibility: Double = 0, peeringCost: Double = 0) {
            self.identity = identity
            self.endpoint = endpoint
            self.peeringCost = PropagationStore.sanitizedNonNegative(peeringCost, otherwise: 0)
            self.node = PropagationNode.State(storageLimitBytes: storageLimitBytes, targetStampCost: targetStampCost,
                                              stampCostFlexibility: stampCostFlexibility)
        }

        /// Convenience: run this propagation node over a single TCP-client driver. Mirrors
        /// `LXMFNode.init(endpoint: TCPEndpoint.State)` — callers keep constructing a bare TCP
        /// driver while the endpoint now owns the shared router / link plane.
        public init(identity: Identity, endpoint: TCPEndpoint.State, storageLimitBytes: Int? = nil,
                    targetStampCost: Double = LXMFPropagation.defaultPropagationStampCost,
                    stampCostFlexibility: Double = 0, peeringCost: Double = 0) {
            self.init(identity: identity, endpoint: .tcp(endpoint), storageLimitBytes: storageLimitBytes,
                      targetStampCost: targetStampCost, stampCostFlexibility: stampCostFlexibility,
                      peeringCost: peeringCost)
        }
    }

    public struct PendingGet: Equatable {
        public var linkID: Data
        public var requestID: Data
    }

    public struct PendingOffer: Equatable {
        public var linkID: Data
        public var requestID: Data
        public var offeredIds: [Data]
    }

    public enum Action: Equatable {
        case endpoint(TransportEndpoint.Action)
        case node(PropagationNode.Action)
        case registerPropagation
        case syncToPeer(destinationHash: Data, peeringCost: Double)
        case offerKeyReady(linkID: Data, key: Data)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case messagesStored(transientIds: [Data])
            /// An outbound sync to `destinationHash` failed before a link was established. `PNNode`
            /// carries no retry machinery (that lives in `LXMFRouter`) and has no production consumer
            /// today, so this exists to make the drop OBSERVABLE rather than abandoning the pending
            /// sync silently (handoff F3). The `LinkFailure` reason is surfaced, not discarded.
            /// A node stop fails a sync still waiting for its link (one whose link-request key was being
            /// searched) with `.pathStale`: `LinkPlane` chose that over
            /// `.stampFailure` on purpose (see its `failStampSearches`).
            case syncFailed(destinationHash: Data, reason: LinkFailure)
        }
    }

    /// Cancellation identity for the peering-key search, keyed on the link it is being generated for —
    /// the key is only ever useful in an `/offer` on that link, so the link dying makes the work dead.
    enum CancelID: Hashable { case peeringKey(Data) }

    @Dependency(\.date) var date
    public init() {}

    /// The peer propagation node's announce, as we last learned it; nil when we have none or it does
    /// not parse.
    private static func peerAnnounce(_ state: State, _ destinationHash: Data) -> PNAnnounce? {
        state.endpoint.learned[destinationHash]?.appData.flatMap(PNAnnounce.parse)
    }

    private static func arrayOfBin(_ value: MsgPackValue) -> [Data] {
        guard case let .array(items) = value else { return [] }
        return items.compactMap { if case let .bin(d) = $0 { return d } else { return nil } }
    }

    public var body: some ReducerOf<Self> {
        Scope(state: \.endpoint, action: \.endpoint) { TransportEndpoint() }
        Scope(state: \.node, action: \.node) { PropagationNode() }
        Reduce { [date] state, action in
            /// Adds `ids` to `peer`'s handled set, keeping only ids the store holds (the set is pruned
            /// to them each time). An empty set is removed rather than stored, so a peer leaves no key
            /// behind unless it has handled ids we hold.
            func markHandled(_ state: inout State, _ peer: Data, _ ids: some Sequence<Data>) {
                let store = state.node.store
                var handled = state.handledByPeer[peer, default: []]
                handled.formUnion(ids)
                handled = handled.filter { store.contains(transientId: $0) }
                state.handledByPeer[peer] = handled.isEmpty ? nil : handled
            }
            func clearLink(_ state: inout State, _ linkID: Data) {
                state.offerLinks[linkID] = nil
                state.offerLinkPeers[linkID] = nil
                state.syncTransfers[linkID] = nil
                state.clientIdentities[linkID] = nil
                state.pendingGet = state.pendingGet.filter { $0.value.linkID != linkID }
                state.pendingOffer = state.pendingOffer.filter { $0.value.linkID != linkID }
            }
            switch action {
            case .registerPropagation:
                guard let d = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                          aspects: ["propagation"], identity: state.identity) else { return .none }
                // Advertise exactly what `PropagationStore.ingest` enforces. A reference client
                // reads this field and treats 0 as "cost unavailable" (LXMRouter.py:428 —
                // `if not target_propagation_cost`), path-requests once, then FAILS the send. So
                // advertising 0 while the store enforces 16 breaks every reference client, and any
                // unstamped entry that did arrive would be silently skipped with no error returned.
                // Read from the store rather than a mirrored copy: one source of truth, no drift.
                // The propagation limits are a REQUEST our peers honour, not a promise we keep: a peer
                // stores them on its LXMPeer record for US (Handlers.py:61 → LXMRouter.py:2025) and
                // filters its own outbound offer against them (LXMPeer.py:370). Advertising 0 said "no
                // message may ever be sent to me", and reference marks each oversized message handled,
                // so mesh sync into this node dropped everything, permanently and silently.
                // Shared constants rather than literals, for the reason the stamp-cost fix exists.
                let appData = PNAnnounce(timebase: Int(date.now.timeIntervalSince1970), nodeState: true,
                                         perTransferLimit: LXMFPropagation.defaultPropagationTransferLimitKB,
                                         perSyncLimit: LXMFPropagation.defaultPropagationSyncLimitKB,
                                         targetStampCost: state.node.store.targetStampCost,
                                         stampCostFlexibility: state.node.store.stampCostFlexibility,
                                         peeringCost: state.peeringCost).packed
                // LXMF 1.3.0's propagation link cost (LXMRouter.py:634), on the wire when stamping.
                return .merge(.send(.endpoint(.registerLocalDestination(d, linkCost: LXMFPropagation.propagationLinkCost))),
                              .send(.endpoint(.announce(destinationHash: d.hash, appData: appData))))

            case let .syncToPeer(destinationHash, peeringCost):
                // `peeringCost` is the PEER's demand, read from its announce. Reference declines to peer
                // above `MAX_PEERING_COST` rather than clamping (LXMRouter.py:2005-2010), and declining
                // is the only honest answer: a key generated at a cost below what the peer requires is
                // one it rejects (LXMPeer.py:228-233), so clamping would spend the work and still fail —
                // silently. Cost is exponential, so an unbounded value pins a core indefinitely.
                // Also refused: NaN and negatives, where reference's key generation raises (see
                // `peeringCostAcceptable`). `cost <= max` alone let a negative cost through.
                guard LXMFPropagation.peeringCostAcceptable(peeringCost) else { return .none }
                // Reference postpones a sync while the peer's stamp costs are unknown
                // (`stamp_costs_known`, LXMPeer.py:274-284): without its announce we cannot tell which
                // entries it accepts, and offering one it refuses gets the link torn down and us
                // throttled (LXMRouter.py:2786-2793). No link is opened.
                guard Self.peerAnnounce(state, destinationHash) != nil else { return .none }
                state.pendingSyncPeers[destinationHash] = peeringCost
                return .send(.endpoint(.openLink(destinationHash: destinationHash)))

            case let .endpoint(.delegate(.resourceReceived(_, data))):
                return .send(.node(.ingestContainer(data)))

            // Small propagation containers arrive as link data packets (not Resources); ingest them too.
            case let .endpoint(.delegate(.linkDataReceived(_, data, _))):
                return .send(.node(.ingestContainer(data)))

            case let .node(.delegate(.stored(tids))):
                return .send(.delegate(.messagesStored(transientIds: tids)))

            case let .endpoint(.delegate(.linkIdentified(linkID, remoteIdentity))):
                state.clientIdentities[linkID] = remoteIdentity
                return .none

            case let .endpoint(.delegate(.requestReceived(linkID, requestID, pathHash, data))):
                guard let clientIdentity = state.clientIdentities[linkID] else { return .none }   // no IDENTIFY → drop (both paths)
                if pathHash == Crypto.truncatedHash(Data("/get".utf8)) {
                    let clientHash = LXMessage.deliveryHash(identityHash: clientIdentity.hash)
                    state.pendingGet[clientHash] = PendingGet(linkID: linkID, requestID: requestID)
                    guard case let .array(items)? = MsgPack.decodeValue(data), items.count >= 2 else { return .none }
                    if case .null = items[0], case .null = items[1] {
                        return .send(.node(.messageListRequested(destinationHash: clientHash)))
                    }
                    return .send(.node(.messagesRequested(destinationHash: clientHash,
                                                          wants: PNNode.arrayOfBin(items[0]),
                                                          haves: PNNode.arrayOfBin(items[1]))))
                }
                if pathHash == Crypto.truncatedHash(Data("/offer".utf8)) {
                    guard case let .array(items)? = MsgPack.decodeValue(data), items.count >= 2,
                          case let .bin(peeringKey) = items[0] else { return .none }
                    let offeredIds = PNNode.arrayOfBin(items[1])
                    let peerHash = Destination.hash(identityHash: clientIdentity.hash,
                                                    appName: LXMessage.appName, aspects: ["propagation"])
                    let peeringId = state.identity.hash + clientIdentity.hash
                    state.pendingOffer[peerHash] = PendingOffer(linkID: linkID, requestID: requestID, offeredIds: offeredIds)
                    return .send(.node(.validatePeeringKey(peerHash: peerHash, peeringId: peeringId,
                                                           peeringKey: peeringKey, targetCost: state.peeringCost)))   // configured cost
                }
                return .none

            case let .node(.delegate(.deliverMessageList(dest, ids))):
                guard let p = state.pendingGet[dest] else { return .none }
                state.pendingGet[dest] = nil
                return .send(.endpoint(.sendResponseOverLink(linkID: p.linkID, requestID: p.requestID,
                                                             data: MsgPack.encode(.array(ids.map { .bin($0) })))))

            case let .node(.delegate(.deliverMessages(dest, entries))):
                guard let p = state.pendingGet[dest] else { return .none }
                state.pendingGet[dest] = nil
                return .send(.endpoint(.sendResponseOverLink(linkID: p.linkID, requestID: p.requestID,
                                                             data: MsgPack.encode(.array(entries.map { .bin($0) })))))

            case let .node(.delegate(.peerValidated(peerHash, valid))):
                guard let pending = state.pendingOffer[peerHash] else { return .none }
                if valid {
                    // A peer that offers an id holds it, so an offered id WE also hold is handled for
                    // that peer (we will not want it, and should not offer it back). Only held ids are
                    // marked: any identity whose key validates (every one at peering cost 0) reaches
                    // here, and ids we do not hold would be state chosen by an unpeered stranger.
                    // Reference marks only the ids it RECEIVES from a peer (`queue_handled_message`,
                    // LXMRouter.py:2784), so it offers a held-but-declined id back once; we skip that
                    // round trip. The ids we want are NOT marked when they arrive (reference does): we
                    // offer them back once, and the peer declines them, which marks them.
                    markHandled(&state, peerHash, pending.offeredIds)
                    return .send(.node(.peerOffered(peerHash: peerHash, transientIds: pending.offeredIds)))
                }
                state.pendingOffer[peerHash] = nil                     // invalid key → drop
                return .none

            case let .node(.delegate(.requestFromPeer(peerHash, wanted))):
                guard let pending = state.pendingOffer[peerHash] else { return .none }
                state.pendingOffer[peerHash] = nil
                return .send(.endpoint(.sendResponseOverLink(linkID: pending.linkID, requestID: pending.requestID,
                                                             data: MsgPack.encode(.array(wanted.map { .bin($0) })))))

            case let .endpoint(.delegate(.linkEstablished(linkID, dest))):
                guard let cost = state.pendingSyncPeers[dest] else { return .none }   // inbound responder link → ignore
                state.pendingSyncPeers[dest] = nil
                // Second gate, at the point the unbounded search would actually start. `pendingSyncPeers`
                // is public state, so `syncToPeer`'s refusal is not the only way a cost can get here.
                guard LXMFPropagation.peeringCostAcceptable(cost) else { return .none }   // decline to peer
                guard let peerIdentity = state.endpoint.learned[dest]?.identity else { return .none }
                let selfIdentity = state.identity
                let identify = Effect<Action>.send(.endpoint(.identifyOverLink(linkID: linkID, identity: selfIdentity)))
                // Offer only what the peer accepts: entries whose stamp value meets its
                // `max(0, cost - flex)` and that fit its announced per-transfer and per-sync limits, in
                // reference weight order, leaving out its handled ids (LXMPeer.py:336-384). Read from
                // its announce again here because it may have changed since `syncToPeer`. An unknown
                // announce offers nothing and marks nothing.
                guard let announce = Self.peerAnnounce(state, dest) else { return identify }
                let selection = state.node.store.offerCandidates(
                    acceptedAt: LXMFPropagation.peerMinimumAcceptedCost(announce),
                    transferLimitKB: announce.perTransferLimit, syncLimitKB: announce.perSyncLimit,
                    excluding: state.handledByPeer[dest] ?? [], now: date.now)
                // Never offered to this peer again: oversized ones reference marks handled
                // (LXMPeer.py:375-378), low-value ones it drops from the peer's unhandled list
                // (:359-361). Marked even when nothing is left to offer, as reference marks before
                // its empty check.
                markHandled(&state, dest, selection.oversized + selection.lowValue)
                let offerable = selection.offer
                // Nothing qualifies: no offer, so no peering key either, as reference returns before
                // offering (LXMPeer.py:386-388). The identify still goes out, as reference identifies on
                // every established sync link (LXMPeer.py:540).
                guard !offerable.isEmpty else { return identify }
                state.offerLinks[linkID] = offerable
                state.offerLinkPeers[linkID] = dest
                let peeringId = peerIdentity.hash + state.identity.hash              // responder-first (matches P4a)
                return .merge(
                    identify,
                    .run { send in
                        guard let key = await LXStamper.generatePeeringKey(peeringId: peeringId, targetCost: cost)
                        else { return }                              // cancelled mid-search
                        await send(.offerKeyReady(linkID: linkID, key: key))
                    }
                    .cancellable(id: CancelID.peeringKey(linkID), cancelInFlight: true))

            case let .offerKeyReady(linkID, key):
                guard let offeredIds = state.offerLinks[linkID] else { return .none }
                let offer = MsgPack.encode(.array([.bin(key), .array(offeredIds.map { .bin($0) })]))
                return .send(.endpoint(.sendRequestOverLink(linkID: linkID, path: "/offer", data: offer)))

            case let .endpoint(.delegate(.responseReceived(linkID, _, data))):
                guard let offeredIds = state.offerLinks[linkID] else { return .none }   // not an outbound offer link
                state.offerLinks[linkID] = nil
                let peer = state.offerLinkPeers[linkID]
                let wanted: [Data]
                switch MsgPack.decodeValue(data) {
                case .bool(false):      wanted = []                          // peer has all → nothing
                case .bool(true):       wanted = offeredIds                  // peer wants all offered
                case let .array(items):
                    // Only ids we offered, which were filtered to what the peer accepts. Narrower than
                    // reference, which sends any id in the response that its store holds, offered or
                    // not (LXMPeer.py:455-457), and raises on one it does not hold.
                    let offered = Set(offeredIds)
                    wanted = items.compactMap { if case let .bin(d) = $0, offered.contains(d) { return d } else { return nil } }
                default:                return .none                         // malformed
                }
                // The offered ids the peer did not want it already has (from another peer): handled,
                // never offered to it again (`False`, LXMPeer.py:432-437; a list, :448-453).
                if let peer {
                    let wantedSet = Set(wanted)
                    markHandled(&state, peer, offeredIds.filter { !wantedSet.contains($0) })
                }
                guard !wanted.isEmpty else { return .none }
                let entries = state.node.store.entries(forTransientIds: wanted)
                // The wanted ids become handled once the transfer concludes (`resource_concluded`,
                // LXMPeer.py:505-507), not now: a transfer that fails leaves them to offer again.
                if peer != nil { state.syncTransfers[linkID] = entries.map(\.transientId) }
                let container = LXMFPropagation.container(timestamp: date.now.timeIntervalSince1970,
                                                          entries: entries.map(\.lxmfData))
                return .send(.endpoint(.sendResourceOverLink(linkID: linkID, data: container)))

            case let .endpoint(.delegate(.resourceConcluded(linkID, _))):
                guard let sent = state.syncTransfers.removeValue(forKey: linkID),
                      let peer = state.offerLinkPeers[linkID] else { return .none }
                markHandled(&state, peer, sent)
                return .none

            case let .endpoint(.delegate(.resourceFailed(linkID, _, _))):
                state.syncTransfers[linkID] = nil                    // reference marks nothing on a failed transfer
                return .none

            // Both of these are where the peering-key search is actually reclaimed: the key exists only
            // to go into an `/offer` on this link, so once the link is gone the search is dead work.
            // `Effect.cancel(id:)` is built ONLY on these branches — binding it above the switch would
            // cancel on every action (that exact defect, 86ee622).
            case let .endpoint(.delegate(.linkClosed(linkID, _))):
                clearLink(&state, linkID)
                return .cancel(id: CancelID.peeringKey(linkID))

            case let .endpoint(.delegate(.requestFailed(linkID, _))):
                clearLink(&state, linkID)
                return .cancel(id: CancelID.peeringKey(linkID))

            case let .endpoint(.delegate(.linkFailed(dest, reason))):
                // Outbound openLink failed before a link existed. Surface it: PNNode has no retry
                // machinery (that is LXMFRouter's job) and no production consumer, so abandoning the
                // sync silently — as this did — hides the failure from any future consumer entirely
                // (handoff F3). Only report for a sync WE initiated: a `linkFailed` for a dest with no
                // pending entry is not ours to fail.
                guard state.pendingSyncPeers[dest] != nil else { return .none }
                state.pendingSyncPeers[dest] = nil
                return .send(.delegate(.syncFailed(destinationHash: dest, reason: reason)))

            case .endpoint, .node, .delegate:
                return .none
            }
        }
    }
}
