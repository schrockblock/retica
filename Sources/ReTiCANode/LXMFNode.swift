import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCATransport

/// The first production composition connecting the decoupled `LXMFRouter` to real transport (LXMF-Node,
/// opportunistic 1:1). Composes `TransportEndpoint` (TCP or BLE) + `LXMFRouter` and translates their
/// delegates/actions: the app calls `.registerDelivery` then `.send(...)`, and receives
/// `.delegate(.messageReceived(...))`. Direct-over-link, path requests, delivery confirmation, and
/// propagation wiring are follow-ons.
@Reducer
public struct LXMFNode {
    public enum SyncPhase: Equatable { case awaitingList, awaitingMessages }

    /// Data learned from a peer's delivery-destination announce (`lxmf.delivery` aspect).
    ///
    /// Mirrors reference's per-destination entry in `outbound_stamp_costs`
    /// (`LXMRouter.py:1029`, LXMF 1.1.0): `[time.time(), stamp_cost]`. We also carry
    /// `displayName` and `supportsCompression`, which the reference stores per-`delivery_destination`
    /// object rather than in a separate dict.
    ///
    /// **Expiry:** Reference expires entries older than `STAMP_COST_EXPIRY = 45 * 24 * 60 * 60`
    /// seconds in `clean_outbound_stamp_costs` (LXMRouter.py:1272-1281). This cleanup is filed as a
    /// known gap in `docs/reference-parity-checklist.md` (Tier 4/durability, stamp-cost expiry). The
    /// `learnedAt` timestamp is stored precisely so a future pass can implement the same expiry without
    /// a schema change.
    ///
    /// **Do not spend `stampCost` without a ceiling check.** Announce app-data is unauthenticated;
    /// any reachable peer can advertise any value. Generating a delivery stamp is an
    /// **exponential proof-of-work** search — `LXStamper.generateStamp`'s own docstring warns that
    /// cancellation alone cannot prevent a hostile peer from pinning a core via a large cost. Before
    /// any caller feeds `stampCost` into stamp generation it MUST validate the value against a
    /// ceiling (analogous to `LXMFPropagation.maxPropagationStampCost`). Generating delivery stamps
    /// is out of scope for this slice; this note exists so the next reader does not miss the
    /// requirement.
    public struct LearnedPeer: Equatable, Sendable {
        /// Display name from the peer's announce app-data, or nil if absent.
        public var displayName: String?
        /// Stamp cost the peer advertised, or nil.
        ///
        /// **Unauthenticated, potentially hostile.** See the note on this struct and on
        /// `LXMFAnnounceData.stampCost` before acting on this value. Treat it as bounded only by
        /// `Int.max`; it has NOT been validated against any ceiling here.
        public var stampCost: Int?
        /// Whether the peer's announce indicates compression support.
        public var supportsCompression: Bool
        /// Wall-clock time this entry was last written, from the `\.date` dependency.
        /// Matches reference, which stores `time.time()` alongside the cost (LXMRouter.py:1029).
        ///
        /// Stored so a future cleanup pass (reference `STAMP_COST_EXPIRY = 45 days`,
        /// `LXMRouter.clean_outbound_stamp_costs`, LXMRouter.py:1272-1281) can expire stale entries
        /// without a schema change. See `docs/reference-parity-checklist.md` for the filed gap.
        ///
        /// Deliberately separate from `LearnedDestination.learnedAt`, which records when the
        /// *path* was learned and is reset by the transport's own expiry sweep. This one records
        /// when the *peer's advertised LXMF parameters* were last refreshed; reference keeps the
        /// two in different structures for the same reason (`outbound_stamp_costs` vs the RNS
        /// path table), and a peer's stamp cost must not be considered fresh merely because a
        /// path to it was re-learned.
        public var learnedAt: Date

        public init(displayName: String?, stampCost: Int?, supportsCompression: Bool, learnedAt: Date) {
            self.displayName = displayName
            self.stampCost = stampCost
            self.supportsCompression = supportsCompression
            self.learnedAt = learnedAt
        }
    }

    @ObservableState
    public struct State: Equatable {
        public var endpoint: TransportEndpoint.State
        public var router: LXMFRouter.State
        public var identity: Identity
        public var directLinks: [Data: Data] = [:]   // destinationHash → linkID (close/linkClosed correlation)
        public var syncPhase: [Data: SyncPhase] = [:]   // linkID → current download phase (one sync/link)
        /// linkID → the destination hash that link terminates on. For an inbound (responder) link this is
        /// OUR local destination; for an outbound link it is the remote one.
        public var linkDestinations: [Data: Data] = [:]
        /// Our served `lxmf.propagation` destination hash while node-mode is on (nil = not serving).
        /// Data arriving on a link to this destination is a propagation offer, not a direct message.
        public var propagationDestinationHash: Data?
        /// Our `lxmf.delivery` destination hash, set when `registerDelivery` is called (nil = not registered).
        /// Used to scope packet proving to inbound direct-delivery links only.
        public var deliveryDestinationHash: Data?

        /// Learned peer data, keyed by `lxmf.delivery` destination hash.
        ///
        /// Populated by the `.endpoint(.delegate(.pathLearned))` handler for an announce whose
        /// destination hash equals `LXMessage.deliveryHash(identityHash:)` of the announced
        /// identity, and whose app-data is non-nil and parses as `LXMFAnnounceData`. That
        /// destination check is what restricts the table to delivery destinations —
        /// `.pathLearned` itself fires for every announce on the network, and
        /// `LXMFAnnounceData.parse` accepts every non-empty blob, so neither narrows anything on
        /// its own. Mirrors `LXMFDeliveryAnnounceHandler.received_announce` in reference LXMF
        /// 1.1.0 (Handlers.py:15-18) — whose own aspect filter is applied by the identical
        /// recomputed-hash comparison in `Transport.py:2077-2086` (RNS 1.4.2).
        ///
        /// **Unbounded.** One entry per distinct LXMF delivery peer heard, never collected. The
        /// transport's `maintenanceTick` expires `Transport.State.learned` (and piggybacks
        /// `announceBlobs` / `announceCache` on that sweep) but has no signal this layer observes,
        /// so entries here outlive the path that produced them. Filed in
        /// `docs/reference-parity-checklist.md` Tier 4.
        ///
        /// Apps may read `displayName` to show a sender's name, and in future may read `stampCost`
        /// to generate a delivery stamp. **Do not feed `stampCost` into stamp generation without a
        /// ceiling check first** — see `LXMFNode.LearnedPeer` for the security rationale.
        public var learnedPeers: [Data: LXMFNode.LearnedPeer] = [:]

        /// Display name advertised in every delivery-destination announce.
        /// Nil means no name is encoded (the announce still carries the full app-data blob per
        /// reference parity — see `LXMFAnnounceData.pack` and `get_announce_app_data` in
        /// LXMF 1.1.0 LXMRouter.py:1034-1050 which always calls `msgpack.packb(peer_data)`).
        public var displayName: String?

        /// Delivery stamp cost advertised in every delivery-destination announce.
        /// Nil or out-of-range values (outside 1...254) are emitted as null per reference's
        /// `> 0 and < 255` gate (LXMRouter.py:1044).
        public var deliveryStampCost: Int?

        public init(identity: Identity, endpoint: TransportEndpoint.State) {
            self.identity = identity
            self.endpoint = endpoint
            self.router = LXMFRouter.State()
        }

        /// Convenience: run this node over TCP.
        public init(identity: Identity, endpoint: TCPEndpoint.State) {
            self.init(identity: identity, endpoint: .tcp(endpoint))
        }

        /// Convenience: run this node over BLE.
        public init(identity: Identity, endpoint: BLEEndpoint.State) {
            self.init(identity: identity, endpoint: .ble(endpoint))
        }
    }

    public enum Action: Equatable {
        case endpoint(TransportEndpoint.Action)
        case router(LXMFRouter.Action)
        case registerDelivery
        /// Update the display name (and optionally the delivery stamp cost) announced in the
        /// delivery-destination app data. Re-announces immediately so peers see the new name
        /// without waiting for the next scheduled announce cycle.
        /// Requires `registerDelivery` to have been called first; silently ignored otherwise.
        case setDisplayName(String?, stampCost: Int?)
        case send(destinationHash: Data, title: Data, content: Data, method: LXMFRouter.DeliveryMethod)
        case setPropagationNode(destinationHash: Data)
        case sendViaPropagation(destinationHash: Data, title: Data, content: Data)
        case sendMessage(message: LXMessage, alsoViaPropagation: Bool)
        case syncFromPropagationNode
        case cancelPropagationStamps
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case messageReceived(message: LXMessage, signatureValidated: Bool)
            case deliveryFailed(messageHash: Data)
            case deliveryConfirmed(messageHash: Data)
            case propagationAccepted(messageHash: Data)
        }
    }

    /// Per-transfer accept limit (KB) sent as the third element of the phase-2 /get payload. lxmd
    /// (LXMRouter.py:1528) reads `float(data[2])*1000` as a byte cap and SKIPS every message larger
    /// than it — so 0 means "serve nothing". A generous positive value (1000 KB ≈ 1 MB) defers to the
    /// PN, which caps at min(client, its own limit). Never send 0.
    public static let propagationTransferLimitKB: UInt64 = 1000

    /// Cancellation identity for the propagation stamp search.
    ///
    /// One id for all in-flight searches rather than one per message: `.sendViaPropagation` builds the
    /// `LXMessage` internally, so a caller wanting to abandon *that* send has no message hash to name.
    /// Reference's `LXStamper.cancel_work` is keyed per message (LXStamper.py:146), driven from
    /// `cancel_outbound(message_id)`; ours is coarser by exactly that much. Effects are registered
    /// **without** `cancelInFlight`, so two concurrent sends coexist and are reclaimed together.
    enum CancelID: Hashable { case propagationStamp }

    @Dependency(\.date) var date
    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.endpoint, action: \.endpoint) { TransportEndpoint() }
        Scope(state: \.router, action: \.router) { LXMFRouter() }
        Reduce { [date] state, action in
            func isServedPropagationLink(_ state: LXMFNode.State, _ linkID: Data) -> Bool {
                guard let served = state.propagationDestinationHash else { return false }
                return state.linkDestinations[linkID] == served
            }
            switch action {
            case .registerDelivery:
                guard let d = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                          aspects: LXMessage.deliveryAspects, identity: state.identity)
                else { return .none }
                state.deliveryDestinationHash = d.hash
                // Always pack app-data — reference `get_announce_app_data` (LXMRouter.py:1034-1050)
                // returns `msgpack.packb(peer_data)` for every registered delivery destination, even
                // when display_name and stamp_cost are both None. The nil-checks on those fields
                // control only the *contents* of the packed list, never whether to emit one.
                let appData = LXMFAnnounceData.pack(displayName: state.displayName,
                                                    stampCost: state.deliveryStampCost)
                return .merge(.send(.endpoint(.registerLocalDestination(d))),
                              .send(.endpoint(.announce(destinationHash: d.hash, appData: appData))))

            case let .setDisplayName(name, stampCost):
                state.displayName = name
                state.deliveryStampCost = stampCost
                // Re-announce so peers see the updated name without waiting for the next scheduled
                // announce cycle. No-op when registerDelivery was never called (deliveryDestinationHash nil).
                guard let hash = state.deliveryDestinationHash else { return .none }
                let appData = LXMFAnnounceData.pack(displayName: name, stampCost: stampCost)
                return .send(.endpoint(.announce(destinationHash: hash, appData: appData)))

            case let .send(destinationHash, title, content, method):
                let msg = LXMessage.create(source: state.identity, destinationHash: destinationHash,
                                           timestamp: date.now.timeIntervalSince1970, title: title, content: content)
                return .send(.router(.send(message: msg, desiredMethod: method)))

            case let .setPropagationNode(destinationHash):
                // Every in-flight stamp was sized to the PREVIOUS node's advertised cost, and a stamp
                // below a node's enforced minimum is dropped by its ingest — so finishing that search
                // could only burn a core for a message the new node would reject. Constructed on this
                // branch only: `Effect.cancel(id:)` performs the cancellation when it is BUILT, so
                // hoisting it out of the switch would cancel on every action (fixed once already, 86ee622).
                return .merge(.cancel(id: CancelID.propagationStamp),
                              .send(.router(.setOutboundPropagationNode(destinationHash))))

            case let .sendViaPropagation(destinationHash, title, content):
                guard let recipient = state.endpoint.learned[destinationHash]?.identity,
                      let cost = propagationStampCost(state)
                else { return .none }
                let msg = LXMessage.create(source: state.identity, destinationHash: destinationHash,
                                           timestamp: date.now.timeIntervalSince1970, title: title, content: content)
                let ts = date.now.timeIntervalSince1970
                return .run { send in
                    guard let (packed, _) = await LXMFPropagation.pack(
                        message: msg, recipientIdentity: recipient, timestamp: ts, stampCost: cost)
                    else { return }                                  // cancelled mid-search
                    await send(.router(.sendViaPropagation(message: msg, propagationPacked: packed)))
                }
                .cancellable(id: CancelID.propagationStamp)

            case let .sendMessage(message, alsoViaPropagation):
                var effects: [Effect<Action>] = [
                    .send(.router(.send(message: message, desiredMethod: .opportunistic)))
                ]
                if alsoViaPropagation,
                   let recipient = state.endpoint.learned[message.destinationHash]?.identity,
                   let cost = propagationStampCost(state) {
                    let ts = date.now.timeIntervalSince1970
                    effects.append(.run { send in
                        guard let (packed, _) = await LXMFPropagation.pack(
                            message: message, recipientIdentity: recipient, timestamp: ts, stampCost: cost)
                        else { return }                              // cancelled mid-search
                        await send(.router(.sendViaPropagation(message: message, propagationPacked: packed)))
                    }
                    .cancellable(id: CancelID.propagationStamp))
                }
                return .merge(effects)

            case .syncFromPropagationNode:
                return .send(.router(.syncFromPropagationNode))

            case .cancelPropagationStamps:
                // The app's explicit reclaim: backgrounding, sign-out, or abandoning a send. Even an
                // accepted cost is minutes of hashing, so this must exist — `LXStamper.search` reads
                // `Task.isCancelled` each round, which is what makes the cancel stop the CPU and not
                // merely discard its result. Reference exposes the same lever as
                // `LXMRouter.cancel_outbound` → `LXStamper.cancel_work` (LXStamper.py:146-175).
                return .cancel(id: CancelID.propagationStamp)

            // --- Propagation sync: phase-1 (IDENTIFY + list request) ---
            case let .router(.delegate(.requestMessageList(linkID))):
                state.syncPhase[linkID] = .awaitingList
                let identity = state.identity
                return .run { send in
                    await send(.endpoint(.identifyOverLink(linkID: linkID, identity: identity)))
                    await send(.endpoint(.sendRequestOverLink(linkID: linkID, path: "/get",
                                                              data: MsgPack.encode(.array([.null, .null])))))
                }

            // --- Propagation sync: phase-2 (wanted messages request) ---
            case let .router(.delegate(.requestMessages(linkID, wants, haves))):
                state.syncPhase[linkID] = .awaitingMessages
                let payload = MsgPack.encode(.array([.array(wants.map { .bin($0) }),
                                                     .array(haves.map { .bin($0) }),
                                                     .uint(LXMFNode.propagationTransferLimitKB)]))
                return .send(.endpoint(.sendRequestOverLink(linkID: linkID, path: "/get", data: payload)))

            // --- Propagation sync: dispatch on responseReceived based on phase ---
            case let .endpoint(.delegate(.responseReceived(linkID, _, data))):
                switch state.syncPhase[linkID] {
                case .awaitingList:
                    // Detect the ERROR_NO_IDENTITY error value: the reference PN sends this when the link
                    // was never IDENTIFY'd (LXMRouter.py:1483). Reference clients branch on exactly this
                    // value (LXMRouter.py:1563-1567) to tear the link down and set PR_NO_IDENTITY_RCVD.
                    // Not reachable against our own node (we IDENTIFY before the first /get) but reachable
                    // against any reference PN. Leaving the phase as .awaitingList would stall the sync.
                    if case .uint(LXMFPropagation.errorNoIdentity)? = MsgPack.decodeValue(data) {
                        state.syncPhase[linkID] = nil
                        return .send(.endpoint(.closeLink(linkID: linkID)))
                    }
                    guard case let .array(items)? = MsgPack.decodeValue(data) else { return .none }
                    let ids = items.compactMap { item -> Data? in
                        if case let .bin(d) = item { return d } else { return nil }
                    }
                    return .send(.router(.offeredMessageList(transientIds: ids)))
                case .awaitingMessages:
                    state.syncPhase[linkID] = nil
                    guard case let .array(items)? = MsgPack.decodeValue(data) else { return .none }
                    let blobs = items.compactMap { item -> Data? in
                        if case let .bin(d) = item { return d } else { return nil }
                    }
                    var effects: [Effect<Action>] = []
                    var tids: [Data] = []
                    for blob in blobs {
                        // The propagation node serves stampless entries (reference LXMRouter strips the
                        // trailing stamp before serving, LXMRouter.py:1551), so the canonical transient_id
                        // is full_hash of the served bytes AS-IS — which equals the node's stored key. Do
                        // NOT strip again here (that double-strip hashed served[:-32] → purge never matched).
                        tids.append(LXMFPropagation.transientId(lxmfData: blob))
                        if let packed = LXMFPropagation.recoverPacked(lxmfData: blob, recipientIdentity: state.identity) {
                            effects.append(.send(.router(.received(method: .direct, destinationHash: Data(), data: packed))))
                        }
                    }
                    effects.append(.send(.router(.messagesDownloaded(transientIds: tids))))
                    if !tids.isEmpty {
                        effects.append(.send(.endpoint(.sendRequestOverLink(linkID: linkID, path: "/get",
                            data: MsgPack.encode(.array([.null, .array(tids.map { .bin($0) })]))))))
                    }
                    return .merge(effects)
                case .none:
                    return .none
                }

            case let .router(.delegate(.sendOpportunistic(dest, payload))):
                return .send(.endpoint(.send(destinationHash: dest, plaintext: payload)))

            case let .endpoint(.delegate(.messageReceived(destHash, plaintext))):
                return .send(.router(.received(method: .opportunistic, destinationHash: destHash, data: plaintext)))

            case let .endpoint(.delegate(.pathLearned(h, _))):
                var effects: [Effect<Action>] = [.send(.router(.learnedPath(destinationHash: h)))]
                if let learned = state.endpoint.learned[h] {
                    effects.append(.send(.router(.learnedIdentity(destinationHash: h, identity: learned.identity))))
                    // Mirror `LXMFDeliveryAnnounceHandler.received_announce` (Handlers.py:15-18,
                    // LXMF 1.1.0): for a delivery-destination announce, extract the app-data and
                    // store the peer's display name and stamp cost.
                    //
                    // The aspect gate is a DESTINATION check, exactly as reference does it.
                    // `Transport.py:2077-2086` (RNS 1.4.2) recomputes
                    // `hash_from_name_and_identity(handler.aspect_filter, announce_identity)` and runs
                    // the handler only when it equals the announced destination hash;
                    // `LXMFDeliveryAnnounceHandler.aspect_filter` is `"lxmf.delivery"` (Handlers.py:11).
                    // `LXMessage.deliveryHash(identityHash:)` is that same computation, and both
                    // inputs are in hand here.
                    //
                    // This gate is load-bearing in BOTH directions, and a payload-shape heuristic
                    // cannot replace it:
                    //   • `.pathLearned` fires for EVERY announce on the network, from every
                    //     application and aspect (Transport.swift, the `shouldReplace` branch), and
                    //     `LXMFAnnounceData.parse` returns non-nil for every non-empty blob — its
                    //     legacy path treats arbitrary bytes as a UTF-8 display name. Without this
                    //     check, `learnedPeers` becomes a table of every destination ever heard,
                    //     with foreign app-data misread as display names.
                    //   • Excluding propagation announces by SHAPE leaks: a 6-element PN announce
                    //     (reference's own "Insufficient peer data, likely from deprecated LXMF
                    //     version", LXMF.py:228) fails `PNAnnounce.parse` and would be stored with
                    //     its timebase uint misread as a stamp cost. Same for a PN announce whose
                    //     metadata element is an array rather than a map. The destination check has
                    //     no such family of near-misses.
                    if h == LXMessage.deliveryHash(identityHash: learned.identity.hash),
                       let appData = learned.appData,
                       let ann = LXMFAnnounceData.parse(appData) {
                        state.learnedPeers[h] = LXMFNode.LearnedPeer(
                            displayName: ann.displayName,
                            stampCost: ann.stampCost,
                            supportsCompression: ann.supportsCompression,
                            learnedAt: date.now)
                    }
                }
                return .merge(effects)

            case let .router(.delegate(.messageDelivered(message, validated))):
                return .send(.delegate(.messageReceived(message: message, signatureValidated: validated)))

            case let .router(.delegate(.deliveryFailed(hash))):
                return .send(.delegate(.deliveryFailed(messageHash: hash)))

            case let .router(.delegate(.deliveryConfirmed(hash))):
                return .send(.delegate(.deliveryConfirmed(messageHash: hash)))

            case let .router(.delegate(.propagationAccepted(hash))):
                return .send(.delegate(.propagationAccepted(messageHash: hash)))

            // --- Direct-over-link: router delegates → endpoint actions ---
            case let .router(.delegate(.requestLink(dest))):
                return .send(.endpoint(.openLink(destinationHash: dest)))

            case let .router(.delegate(.requestPath(dest))):
                return .send(.endpoint(.requestPath(destinationHash: dest)))

            case let .router(.delegate(.sendDirect(linkID, data, asResource))):
                return asResource
                    ? .send(.endpoint(.sendResourceOverLink(linkID: linkID, data: data)))
                    : .send(.endpoint(.sendOverLink(linkID: linkID, data: data)))

            case let .router(.delegate(.sendPropagated(linkID, propagationPacked))):
                return .send(.endpoint(.sendResourceOverLink(linkID: linkID, data: propagationPacked)))

            case let .router(.delegate(.sendPropagatedPacket(linkID, propagationPacked, messageHash))):
                return .send(.endpoint(.sendWithReceiptOverLink(linkID: linkID, data: propagationPacked, token: messageHash)))

            case let .endpoint(.delegate(.packetDelivered(token))):
                // token == message.hash (set when sendPropagatedPacket was dispatched)
                // → feeds the router's existing delivered→propagationAccepted path
                return .send(.router(.delivered(messageHash: token)))

            case let .endpoint(.delegate(.packetDeliveryFailed(token))):
                // Treat a lost packet the same as a retry-due so the message isn't silently dropped.
                return .send(.router(.retryDue(messageHash: token)))

            case let .router(.delegate(.closeLink(dest))):
                guard let linkID = state.directLinks[dest] else { return .none }
                return .send(.endpoint(.closeLink(linkID: linkID)))

            // --- Direct-over-link: endpoint delegates → router actions ---
            case let .endpoint(.delegate(.linkEstablished(linkID, dest))):
                state.directLinks[dest] = linkID
                state.linkDestinations[linkID] = dest
                return .send(.router(.linkEstablished(destinationHash: dest, linkID: linkID)))

            case let .endpoint(.delegate(.linkClosed(linkID, _))):
                state.linkDestinations[linkID] = nil
                state.syncPhase[linkID] = nil   // Minor-2: clear leak from a mid-phase sync death
                guard let dest = state.directLinks.first(where: { $0.value == linkID })?.key else { return .none }
                state.directLinks[dest] = nil
                return .send(.router(.linkClosed(destinationHash: dest)))

            case let .endpoint(.delegate(.linkFailed(dest, reason))):
                state.directLinks[dest] = nil
                switch reason {
                case .noPath, .pathStale, .establishmentTimedOut:
                    // PATH-shaped failure: our route to `dest` is wrong, not the peer. Clear the
                    // router's belief that a usable path exists so `establish` parks in
                    // `.awaitingPath` (requesting a fresh path) rather than emitting `requestLink`
                    // against a route already proven dead.
                    //
                    // The park is bounded: `pathRequestTimer` plus the shared `establishAttempts`
                    // budget cap the total saga, so this is a bounded terminus — which is why an
                    // earlier un-bounded attempt (f0c4670, reverted e01f0ce) was unsafe and this
                    // is not.
                    //
                    // ONE action, deliberately. Clearing the route and closing the link must not be
                    // separable: any gap between them is a window in which an inbound `learnedPath`
                    // (a routine peer announce — see the `pathLearned` case above) re-inserts the
                    // entry just removed, so the close re-establishes against the stale route after
                    // all. A `.run` with two `await send`s opens exactly that window at its
                    // MainActor suspension point. `.pathLostAndClosed` does both in one reduction.
                    return .send(.router(.pathLostAndClosed(destinationHash: dest)))
                case .handshakeRejected:
                    // PEER-shaped failure: the path demonstrably works (the peer replied), but
                    // the handshake proof failed to validate. Requesting a fresh path would not
                    // help — retry the link instead, on the bounded `establishAttempts` budget.
                    return .send(.router(.linkClosed(destinationHash: dest)))
                }

            case let .endpoint(.delegate(.linkDataReceived(linkID, data, packetHash))):
                // On our served lxmf.propagation link this is an offer for the node, not a message for us.
                // `LXMFServiceNode` handles proving for propagation-link packets; return early here so
                // that proving is never double-counted and delivery is not attempted for propagation data.
                guard !isServedPropagationLink(state, linkID) else { return .none }
                // Reference `LXMRouter.delivery_packet` (LXMRouter.py:1925-1927) calls `packet.prove()`
                // as its FIRST statement for every inbound delivery-link packet. Without this proof,
                // a reference client's `LXMessage.__link_packet_timed_out` (LXMessage.py:616-619)
                // tears the link down and retries forever, never marking the message sent.
                //
                // Scope: prove ONLY when the link terminates on OUR delivery destination. This excludes:
                //   • the served lxmf.propagation link (handled above),
                //   • our client's outbound sync link to a remote PN (linkDestinations holds the REMOTE
                //     hash there, which cannot match deliveryDestinationHash),
                //   • any link when registerDelivery was never called (deliveryDestinationHash == nil).
                //
                // Resource-framed direct messages are proved by the resource transfer protocol, so no
                // prove is needed for the `.resourceReceived` path.
                let isDeliveryLink = state.deliveryDestinationHash != nil
                    && state.linkDestinations[linkID] == state.deliveryDestinationHash
                if isDeliveryLink {
                    return .merge(
                        .send(.endpoint(.provePacketOverLink(linkID: linkID, packetHash: packetHash))),
                        .send(.router(.received(method: .direct, destinationHash: Data(), data: data))))
                }
                return .send(.router(.received(method: .direct, destinationHash: Data(), data: data)))

            case let .endpoint(.delegate(.resourceReceived(linkID, data))):
                guard !isServedPropagationLink(state, linkID) else { return .none }
                return .send(.router(.received(method: .direct, destinationHash: Data(), data: data)))

            case let .endpoint(.delegate(.resourceConcluded(linkID, _))):
                return .send(.router(.resourceDeliveredOnLink(linkID: linkID)))

            case .endpoint, .router, .delegate:
                return .none
            }
        }
    }

    /// The propagation stamp cost to work at, or **nil meaning "do not send via this node"**.
    ///
    /// `ann.targetStampCost` comes from the propagation node's announce app-data, which is
    /// unauthenticated: any peer can advertise 64, and the search is exponential in the cost, so 64 is
    /// ~2^64 hash rounds over a 256 KB workblock. Reference reads the same field with no ceiling
    /// (`LXMRouter.get_outbound_propagation_cost`, LXMRouter.py:421-442; `pn_announce_data_is_valid`
    /// only checks it is int-able, LXMF.py:238-239) — see `LXMFPropagation.maxPropagationStampCost`
    /// for the ceiling and why refusing beats clamping.
    private func propagationStampCost(_ state: State) -> Int? {
        guard let pn = state.router.outboundPropagationNode,
              let appData = state.endpoint.learned[pn]?.appData,
              let ann = PNAnnounce.parse(appData)
        else { return LXMFPropagation.defaultPropagationStampCost }
        guard ann.targetStampCost <= LXMFPropagation.maxPropagationStampCost else { return nil }
        return ann.targetStampCost
    }
}
