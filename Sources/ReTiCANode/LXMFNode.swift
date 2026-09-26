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
    /// **Expiry:** Entries older than `LXMFNode.stampCostExpiry` (45 days, reference
    /// `STAMP_COST_EXPIRY = 45 * 24 * 60 * 60`, LXMRouter.py:39) are swept when
    /// `.rehydrateLearnedPeers` restores the table at launch — reference's
    /// `clean_outbound_stamp_costs` (LXMRouter.py:1272-1285), which runs once per startup,
    /// immediately after the table is loaded (LXMRouter.py:276-277).
    ///
    /// **Do not spend `stampCost` without a ceiling check.** Announce app-data is unauthenticated;
    /// any reachable peer can advertise any value. Generating a delivery stamp is an
    /// **exponential proof-of-work** search — `LXStamper.generateStamp`'s own docstring warns that
    /// cancellation alone cannot prevent a hostile peer from pinning a core via a large cost. Before
    /// any caller feeds `stampCost` into stamp generation it MUST validate the value against a
    /// ceiling (analogous to `LXMFPropagation.maxPropagationStampCost`).
    ///
    /// Delivery stamps **are now generated** (this note previously said doing so was out of scope
    /// for its slice). The one caller that spends this field is `LXMFNode.deliverySend`, and it
    /// applies the ceiling via `LXMFNode.deliveryStampCost` → `LXMFNode.maxDeliveryStampCost`.
    /// The requirement above is therefore satisfied at that single site — and it stays stated here
    /// because the field is public and a *second* caller would have to satisfy it independently.
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
        /// Consumed by `.rehydrateLearnedPeers`, which sweeps entries older than
        /// `LXMFNode.stampCostExpiry` (reference `STAMP_COST_EXPIRY = 45 days`,
        /// `LXMRouter.clean_outbound_stamp_costs`, LXMRouter.py:1272-1285) when it restores the
        /// table at launch.
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
        /// **Expiry-bounded.** Entries older than `LXMFNode.stampCostExpiry` (45 days) are swept
        /// when `.rehydrateLearnedPeers` restores the table at launch — reference's
        /// `clean_outbound_stamp_costs`, which runs once per startup (LXMRouter.py:276-277) and
        /// never on a timer, so entries learned live during a session are swept at the NEXT launch.
        /// The table is therefore bounded by the distinct `lxmf.delivery` peers heard within one
        /// expiry window. The transport's own sweep does not reach this table: `maintenanceTick`
        /// expires `Transport.State.learned` (and piggybacks `announceBlobs` / `announceCache`) but
        /// has no signal this layer observes, so entries here outlive the path that produced them —
        /// the expiry above is what collects them.
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

        /// Whether to DROP inbound messages whose stamp fails validation (or is absent) when a
        /// `deliveryStampCost` is configured.
        ///
        /// **Defaults to `false`**, matching reference (`enforce_stamps=False` in `LXMRouter.__init__`,
        /// LXMRouter.py:99). With enforcement off, an invalid or absent stamp is logged but the
        /// message is delivered — exactly `LXMRouter.lxmf_delivery`'s else-branch at line 1878.
        ///
        /// Set to `true` to drop messages with invalid stamps, mirroring reference's `enforce_stamps()`
        /// call (LXMRouter.py:696-697). **Ticket divergence:** reference `validate_stamp`
        /// (LXMessage.py:273-283) also accepts a stamp equal to `truncated_hash(ticket + message_id)`
        /// regardless of cost ("inbound tickets", Tier 3, unticketed in ReTiCA). With enforcement on,
        /// a ticket-holding peer that reference accepts, we reject. This divergence is harmless with
        /// enforcement off (the default). Whoever enables enforcement should account for this gap.
        public var enforceDeliveryStamps: Bool = false

        /// Hashes of messages whose delivery-stamp search is currently in flight, oldest first.
        ///
        /// **This exists because a cancelled search cannot report its own failure.**
        /// `LXStamper.search` returns nil only when `Task.isCancelled`, and TCA's
        /// `Send.callAsFunction` opens with `guard !Task.isCancelled else { return }`
        /// (ComposableArchitecture Effect.swift:191-194) — so *every* `await send(...)` inside a
        /// cancelled `.run` body is a no-op, including one that tries to report the cancellation.
        /// Measured, not deduced: a probe emitting `.delegate(.deliveryFailed)` from the nil branch
        /// of `deliverySend` produced no action at all.
        ///
        /// The failure is therefore emitted by the `.cancelDeliveryStamps` reducer branch, which is
        /// not itself cancelled, over this list. Reference works the same way: `cancel_outbound`
        /// only flags the message and calls `LXStamper.cancel_work` (LXMRouter.py:1719-1725,
        /// LXMF 1.1.0); the `failed_callback` is invoked later by `process_deferred_stamps` on the
        /// router's own thread, once `get_stamp()` has returned None (LXMRouter.py:2620-2630).
        ///
        /// Entries are appended when a search starts and removed when `.router(.send)` carries the
        /// message onward, so a search that already completed is never failed retroactively.
        public internal(set) var inFlightDeliveryStamps: [Data] = []

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
        /// Restore `learnedPeers` from a previous session so that after a cold start we stamp
        /// outbound messages at the costs peers last advertised, instead of sending unstamped to
        /// every peer until each announce is re-heard — which a peer running `enforce_stamps()`
        /// drops. The app sends this on launch, mirroring `.rehydrateDedup` for the router's dedup
        /// sets (library holds state, app persists and replays).
        ///
        /// **Sweeps expired entries in the same pass.** Reference loads `outbound_stamp_costs`
        /// from disk at startup and immediately runs `clean_outbound_stamp_costs`
        /// (LXMRouter.py:276-277, 1272-1285), dropping entries older than
        /// `STAMP_COST_EXPIRY = 45 days` (LXMRouter.py:39). It runs no periodic sweep — the launch
        /// is the sweep. This action is that launch: an entry whose `learnedAt` is more than
        /// `LXMFNode.stampCostExpiry` before the current `\.date` is dropped, not restored. The
        /// comparison keeps an entry exactly one expiry old, matching reference's strict
        /// `time.time() > entry[0] + STAMP_COST_EXPIRY`.
        case rehydrateLearnedPeers([Data: LearnedPeer])
        case registerDelivery
        /// Update the display name and delivery stamp cost carried in the delivery-destination
        /// app data. **State only — this sends nothing.** Follow it with `.announceDelivery`
        /// when the edit is settled.
        ///
        /// The two are separate on purpose. This action previously broadcast on every interface as
        /// a side effect of the setter, and `Transport` does not pace locally-originated announces
        /// (its per-interface gate applies to RELAYED announces only), so a settings `TextField`
        /// bound straight through to this action would have put one announce on the air per
        /// keystroke. Reference draws the same line: `delivery_destination.display_name = x` is a
        /// plain assignment and `LXMRouter.announce(destination_hash)` is a separate explicit call.
        case setDisplayName(String?, stampCost: Int?)
        /// Announce the delivery destination now, carrying the current `displayName` and
        /// `deliveryStampCost`. Broadcasts on EVERY connected interface with no throttle, so call
        /// it when a change is settled — not on every keystroke of an edit.
        /// Requires `registerDelivery` to have been called first; silently ignored otherwise.
        case announceDelivery
        case send(destinationHash: Data, title: Data, content: Data, method: LXMFRouter.DeliveryMethod)
        case setPropagationNode(destinationHash: Data)
        case sendViaPropagation(destinationHash: Data, title: Data, content: Data)
        case sendMessage(message: LXMessage, alsoViaPropagation: Bool)
        case syncFromPropagationNode
        case cancelPropagationStamps
        /// Cancel any in-flight delivery-stamp searches. Call when the app backgrounds, the user
        /// abandons a send, or the destination is no longer reachable. Mirrors `cancelPropagationStamps`
        /// for the delivery-stamp `CancelID.deliveryStamp` effect set.
        ///
        /// **Every message still searching is FAILED, not sent unstamped.** One
        /// `.delegate(.deliveryFailed(messageHash:))` is emitted per entry in
        /// `State.inFlightDeliveryStamps` — the app must treat those messages as not sent. Reference
        /// does the same (`process_deferred_stamps` → `failed_callback`, LXMRouter.py:2620-2625,
        /// LXMF 1.1.0). The alternative — sending unstamped — is not available: the cancellation that
        /// ends the search also suppresses every action the search's effect could still emit, so
        /// "send it unstamped instead" cannot be implemented from inside that effect at all.
        case cancelDeliveryStamps
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

    /// Highest delivery stamp cost we will do proof-of-work for when a peer advertises one in its
    /// `lxmf.delivery` announce app-data.
    ///
    /// **This is a deliberate divergence from reference — reference has no such cap.**
    /// `LXMRouter.handle_outbound` (LXMRouter.py:1752-1757, LXMF 1.1.0) copies the peer's announced
    /// cost onto the message verbatim (`outbound_stamp_costs[destination_hash][1]`, populated at
    /// LXMRouter.py:1027-1029) — it does **not** itself generate anything. The search is reached
    /// later, via `pack()` → `LXMessage.get_stamp`, whose only gate is `stamp_cost == None`
    /// (LXMessage.py:307) before it calls `LXStamper.generate_stamp` (LXMessage.py:320).
    /// Reference survives a hostile value by making that search *cancellable*
    /// (`LXStamper.cancel_work`), not by bounding it — so an uncancelled reference client burns a
    /// core just as we would. We implement cancellation *and* this cap, because an unkillable core
    /// burn triggered by an unauthenticated announce is not acceptable on a mobile client even for
    /// the seconds before a user notices and cancels.
    ///
    /// **Why 20 — and what it costs us.** Workblock sizes are `expandRounds × 256` bytes:
    /// delivery uses 3000 rounds (768 000 B), propagation 1000 (256 000 B), peering 25 (6 400 B).
    /// `LXStamper.search` re-hashes the **whole** workblock every attempt, so expected work at
    /// cost C is ~2^C × workblock.
    ///
    /// Deriving against the largest worst case reference itself sanctions — `MAX_PEERING_COST = 26`
    /// (LXMRouter.py:51), i.e. ~2^26 × 6 400 B — equal work at the delivery workblock is
    /// 26 − log₂(768000/6400) = 26 − log₂(120) ≈ **19.1**. This is the method used for
    /// `LXMFPropagation.maxPropagationStampCost`, applied with the delivery:peering ratio (120)
    /// rather than the delivery:propagation ratio.
    ///
    /// We round **up** to 20 rather than down to 19, and that is a real (small) cost, not a free
    /// choice: delivery@20 is ~1.9× reference's sanctioned peering@26 worst case, and ~3× the work
    /// of propagation@20 — the two ceilings share the number 20 but *not* the workblock, so this is
    /// equal-numbered, not equal-work. It buys a single ceiling constant across the codebase, and
    /// stays the same order of magnitude. **Measured** (arm64 Mac, this repo's `LXStamper`):
    /// 768 000-byte workblock, ~2 200 search rounds/s → cost 20 ≈ **8 minutes** expected, cost 21
    /// ≈ 16 minutes. On a phone, materially longer.
    ///
    /// **The trade this ceiling makes is real, and it is not "we only refuse absurd values".**
    /// Reference sets **no default delivery stamp cost** (`register_delivery_identity(...,
    /// stamp_cost = None)`, LXMRouter.py:348) and `set_inbound_stamp_cost` accepts **any int in
    /// 1…254** (LXMRouter.py:378-388). So a perfectly conforming peer may demand 21–254, and we
    /// refuse to stamp for every one of them — those peers, if they `enforce_stamps()`, will drop
    /// our messages. We are choosing bounded CPU over deliverability to that (unbounded-cost) tail.
    /// An earlier version of this comment cited `PROPAGATION_COST + PROPAGATION_COST_FLEX = 19` as
    /// evidence that nothing legitimate exceeds 20; that is a propagation-side constant with no
    /// bearing on delivery costs, and it told the reader the opposite of the truth.
    ///
    /// Refusal, not clamping: a stamp generated below the peer's advertised cost is one that peer
    /// will drop — a silent failure after all that work. Refusing is clean.
    public static let maxDeliveryStampCost = 20

    /// Age at which a `learnedPeers` entry is swept. Matches reference's
    /// `STAMP_COST_EXPIRY = 45 * 24 * 60 * 60` (LXMRouter.py:39, LXMF 1.1.0).
    ///
    /// The sweep runs when `.rehydrateLearnedPeers` restores the table at launch — reference
    /// sweeps `outbound_stamp_costs` once per startup, immediately after loading it from disk
    /// (LXMRouter.py:276-277), and runs no periodic timer. On iOS the launch is the routine path,
    /// so a launch-time sweep fires routinely; entries learned live during a session are swept at
    /// the next one.
    public static let stampCostExpiry: TimeInterval = 45 * 24 * 60 * 60

    /// Cancellation identity for the propagation stamp search.
    ///
    /// One id for all in-flight searches rather than one per message: `.sendViaPropagation` builds the
    /// `LXMessage` internally, so a caller wanting to abandon *that* send has no message hash to name.
    /// Reference's `LXStamper.cancel_work` is keyed per message (LXStamper.py:146), driven from
    /// `cancel_outbound(message_id)`; ours is coarser by exactly that much. Effects are registered
    /// **without** `cancelInFlight`, so two concurrent sends coexist and are reclaimed together.
    enum CancelID: Hashable { case propagationStamp; case deliveryStamp }

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
            case let .rehydrateLearnedPeers(peers):
                // Restore + sweep in one pass, matching reference's startup sequence: load the
                // table from disk, then clean_outbound_stamp_costs (LXMRouter.py:276-277,
                // 1272-1285). Reference runs no periodic sweep; on iOS the launch (hence this
                // action) is the routine path, so a launch-time sweep fires routinely. The keep
                // condition `now <= learnedAt + expiry` is reference's strict inequality inverted:
                // an entry exactly one expiry old survives.
                //
                // A restored entry NEVER replaces a fresher live one. Rehydration is not guaranteed
                // to land before the network does: the app pattern this action is built for merges
                // `.endpoint(.start)` with an async database read (`AppFeature.onLaunch`), so an
                // announce can reach `learnedPeers` first. An unconditional write would then move
                // `learnedAt` BACKWARDS and restore a superseded stamp cost — which is precisely the
                // failure this slice exists to prevent, since under-paying gets us dropped by an
                // enforcing peer. Reference is not exposed to this: it loads `outbound_stamp_costs`
                // synchronously in `__init__`, before any network exists.
                //
                // A row whose `learnedAt` is non-finite or in the FUTURE is dropped, not restored.
                // `Date + TimeInterval` is Double arithmetic, so it saturates rather than traps —
                // there is no crash here, which is why this needs a test rather than a guard. Two
                // ways an unclamped sweep keeps such a row forever: NaN fails OPEN, because
                // `now <= nan` is `!(nan < now)` = true; and a future date is trivially unexpired.
                //
                // Clamping to `now` instead of dropping does NOT work, and a test caught that here:
                // clamping makes a future row look maximally FRESH, so it is kept — and re-clamped
                // against each later `now`, so it is immortal, which is the defect being fixed.
                // Dropping is cheap: the next announce from that peer repopulates the entry.
                let now = date.now
                for (hash, peer) in peers {
                    guard peer.learnedAt.timeIntervalSinceReferenceDate.isFinite,
                          peer.learnedAt <= now,
                          now <= peer.learnedAt + LXMFNode.stampCostExpiry
                    else { continue }
                    if let live = state.learnedPeers[hash], live.learnedAt >= peer.learnedAt { continue }
                    state.learnedPeers[hash] = peer
                }
                return .none

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
                // Setter only — see the action's declaration for why the broadcast is a separate
                // action. Emitting an announce from here made an unthrottled network broadcast the
                // side effect of a state write, which a per-keystroke binding turns into a flood.
                state.displayName = name
                // Range-sanitise the cost HERE, because this is the only write to the field that the
                // whole inbound half keys on. Reference does it in the same place —
                // `set_inbound_stamp_cost` (LXMRouter.py:378-392, LXMF 1.1.0):
                //
                //     if stamp_cost == None:  stamp_cost = None; return True
                //     elif type(stamp_cost) == int:
                //         if   stamp_cost < 1:   stamp_cost = None
                //         elif stamp_cost < 255: stamp_cost = stamp_cost
                //         else:                  return False      # rejected, previous value KEPT
                //
                // Storing the raw value made the announce and the enforcement disagree, because
                // `LXMFAnnounceData.pack` already applies reference's `> 0 and < 255` emit gate
                // (LXMFAnnounceData.swift:113). Measured, on this reducer:
                //   • cost 0  — announced as "no cost required", yet `validateStamp(targetCost: 0)`
                //     is reached for every inbound message and returns false for an ABSENT stamp
                //     (`guard let stamp else { return false }`, LXMessage.swift:167), so with
                //     enforcement on we dropped every message from every conforming peer.
                //   • cost -1 — `stampValid` is `stampValue >= targetCost` (LXStamper.swift:57-58)
                //     and a bit count is never negative, so an all-0xFF stamp validated. We reported
                //     `stampValid == true` to the app: a false trust signal, the worst outcome here.
                //
                // The `>= 255` case keeps the previous cost rather than clearing it, exactly as
                // reference's `return False` leaves `delivery_destination.stamp_cost` untouched.
                // Silently disabling a configured cost because a later call was out of range would
                // be a downgrade an attacker-influenced settings value could trigger.
                switch stampCost {
                case .none:                             state.deliveryStampCost = nil
                case let .some(c) where c < 1:          state.deliveryStampCost = nil
                case let .some(c) where c < 255:        state.deliveryStampCost = c
                default:                                break    // rejected; previous value kept
                }
                return .none

            case .announceDelivery:
                // No-op when registerDelivery was never called (deliveryDestinationHash nil).
                guard let hash = state.deliveryDestinationHash else { return .none }
                let appData = LXMFAnnounceData.pack(displayName: state.displayName,
                                                    stampCost: state.deliveryStampCost)
                return .send(.endpoint(.announce(destinationHash: hash, appData: appData)))

            case let .send(destinationHash, title, content, method):
                let msg = LXMessage.create(source: state.identity, destinationHash: destinationHash,
                                           timestamp: date.now.timeIntervalSince1970, title: title, content: content)
                return deliverySend(&state, message: msg, method: method)

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
                // The delivery copy is stamped on exactly the same terms as `.send` — this is the
                // path ReTiCaMsgr actually calls, so leaving it unstamped would have defeated the
                // whole point of bounding the cost elsewhere. The propagation copy below keeps its
                // OWN, separate stamp: different workblock (1000 rounds vs 3000), different material
                // (transient_id vs message hash), different CancelID. See `deliverySend` for why a
                // caller-supplied stamp is never overwritten.
                var effects: [Effect<Action>] = [
                    deliverySend(&state, message: message, method: .opportunistic)
                ]
                // KNOWN GAP, deliberately deferred: the propagation copy packs the ORIGINAL,
                // UNSTAMPED `message`, so a recipient who enforces delivery stamps drops it even
                // though the opportunistic copy above carries one. Same failure class as the
                // `.sendMessage`-had-no-stamp gap this task just closed, one layer down.
                //
                // The barrier is EFFECT SEQUENCING, not `transient_id` stability — an earlier note
                // here said the latter and a re-review corrected it, so it is recorded rather than
                // silently replaced. It is true that stamping first changes `message.packed` and
                // therefore the `transient_id` that `LXMFPropagation.pack` derives from it. But that
                // does NOT destabilise retries: `ResendInfo.propagated` re-sends the already-packed
                // `propagationPacked` bytes and never re-calls `pack`, so stamping once and packing
                // once would still give a stable id. The real cost is that both the delivery-stamp
                // search and `pack`'s own propagation-stamp search are async and potentially
                // minutes long, so doing both means turning these two CONCURRENT effects into a
                // sequential chain — with its own cancellation ordering and partial-failure cases.
                // That deserves its own design and tests; it is not a line to slip in here.
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

            case .cancelDeliveryStamps:
                // The app's explicit reclaim for in-flight delivery-stamp searches. Even an accepted
                // cost at `maxDeliveryStampCost` is minutes of CPU. `LXStamper.search` reads
                // `Task.isCancelled` each round, so cancellation stops the CPU burn — it does not
                // merely discard the result. Mirrors `cancelPropagationStamps` for the delivery path.
                //
                // ...and then FAILS every message that was still searching. This branch is the only
                // place that can: the cancelled effect's own `await send` is swallowed by
                // `Send.callAsFunction`'s `guard !Task.isCancelled` (Effect.swift:191-194), so a
                // message abandoned here would otherwise vanish with no delegate at all — leaving the
                // app showing "sending" forever for a message that will never be sent. Reference
                // reports it from the equally-uncancelled router loop (`process_deferred_stamps` →
                // `failed_callback`, LXMRouter.py:2620-2625, LXMF 1.1.0).
                //
                // No race with a search that just finished: the effect can only deliver
                // `.router(.send)` by hopping to the MainActor, and both that hop's cancellation
                // check and this reduction run there — so the completed case has already emptied
                // `inFlightDeliveryStamps` via the `.router(.send)` branch, and the not-yet-delivered
                // case is dropped by the same guard that necessitates this code.
                //
                // `.cancel(id:)` cancels when it is CONSTRUCTED, so it stays on this branch (86ee622).
                let abandoned = state.inFlightDeliveryStamps
                state.inFlightDeliveryStamps = []
                return .merge([Effect<Action>.cancel(id: CancelID.deliveryStamp)]
                              + abandoned.map { .send(.delegate(.deliveryFailed(messageHash: $0))) })

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

            case let .router(.delegate(.sendOpportunistic(dest, payload, messageHash))):
                // The message hash is the receipt token: every resend is a new packet with its own
                // receipt under the same token, so a proof for any attempt confirms the message.
                return .send(.endpoint(.send(destinationHash: dest, plaintext: payload, receiptToken: messageHash)))

            case let .endpoint(.delegate(.messageReceived(destHash, plaintext, packetHash, interfaceID))):
                // Reference `LXMRouter.delivery_packet` (LXMRouter.py:1926-1927) calls `packet.prove()`
                // as its FIRST statement, for opportunistic (non-link) packets too. The proof therefore
                // goes out BEFORE the router's `seen` dedup, so a resend of an already-delivered message
                // is proved again, and before unpacking, so LXMF-level malformation is proved too.
                // Only packets for OUR delivery destination are proved: `Transport` surfaces a packet
                // here only after decrypting it for a local destination, and link traffic and
                // propagated downloads never arrive on this path.
                let deliver = Effect<Action>.send(.router(.received(method: .opportunistic,
                                                                    destinationHash: destHash, data: plaintext)))
                guard let ours = state.deliveryDestinationHash, destHash == ours else { return deliver }
                return .merge(.send(.endpoint(.proveSinglePacket(packetHash: packetHash, interfaceID: interfaceID,
                                                                 identity: state.identity))),
                              deliver)

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
                // Stamp validation mirrors `LXMRouter.lxmf_delivery` (LXMRouter.py:1861-1880, LXMF 1.1.0).
                //
                // Only validates when WE have configured a stamp cost (`State.deliveryStampCost != nil`).
                // The cost is OURS — `delivery_destinations[message.destination_hash].stamp_cost`, which
                // maps to `State.deliveryStampCost` we set via `setDisplayName(_, stampCost:)` — so it is
                // trusted configuration, not a wire value. No ceiling applies here (the ceiling in
                // `deliveryStampCost(_:destinationHash:)` is OUTBOUND-only, protecting against a hostile
                // peer's unauthenticated announce driving an exponential search).
                //
                // COST: O(1) in the cost parameter, but NOT free — ~3000 HKDF rounds deriving a 768 KB
                // workblock per inbound message (order 60 ms; see `LXMessage.validateStamp`), incurred
                // regardless of `signatureValidated`. Reference has the identical property
                // (LXMessage.py:288-289). This sits downstream of the router's `seen` dedup, so a
                // replayed message does not repeat the work, but a flood of distinct messages pays it
                // per message.
                //
                // Ticket divergence: reference also accepts `truncated_hash(ticket + message_id)` stamps
                // (LXMessage.py:273-283, "inbound tickets"). ReTiCA has no tickets (Tier 3, unticketed).
                // With enforcement off (default) the gap is invisible — both deliver. With enforcement on
                // a ticket-holding peer reference accepts, we reject. Documented in `enforceDeliveryStamps`.
                //
                // The RESULT is carried on the message (`stampValid`/`stampChecked`), mirroring
                // reference's assignment pair at LXMRouter.py:1865-1869 — not added as a delegate
                // parameter, because reference keeps it on the object too (LXMessage.py:157-158) and the
                // message already reaches the app via `.messageReceived`. A message arriving with
                // `stampChecked == false` was never validated (no cost configured), which is a different
                // statement from "validated and failed"; the app can tell those apart.
                var delivered = message
                if let cost = state.deliveryStampCost {
                    let stampValid = message.validateStamp(targetCost: cost)
                    delivered = message.withStampValidation(valid: stampValid)
                    if !stampValid {
                        // Enforcement off (default): deliver anyway, matching reference's
                        // "allow anyway, since stamp enforcement is disabled" branch (LXMRouter.py:1878-1879).
                        // Enforcement on: drop, matching `return False` (LXMRouter.py:1877).
                        if state.enforceDeliveryStamps {
                            return .none    // drop — app receives nothing
                        }
                        // fall through to deliver, flagged checked-and-invalid
                    }
                }
                return .send(.delegate(.messageReceived(message: delivered, signatureValidated: validated)))

            case let .router(.send(handedOn, _)):
                // The search for this message is over — it is the router's problem now, so it can no
                // longer be failed by `.cancelDeliveryStamps`. Reached on BOTH `deliverySend` paths:
                // the unstamped fast path (which never appended) and the completed search. Removing an
                // absent hash is a no-op, which is why no branch is needed here.
                state.inFlightDeliveryStamps.removeAll { $0 == handedOn.hash }
                return .none

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
                // token == message.hash, set when `sendPropagatedPacket` was dispatched. That is the
                // ONLY link send that requests a receipt (direct link packets go out via
                // `sendOverLink`, unreceipted), so a link receipt always belongs to the PROPAGATED copy.
                return .send(.router(.delivered(messageHash: token, leg: .propagated)))

            case let .endpoint(.delegate(.packetDeliveryFailed(token))):
                // Treat a lost packet the same as a retry-due so the message isn't silently dropped.
                // Same reasoning as above: a link receipt is always the propagated copy's.
                return .send(.router(.retryDue(messageHash: token, leg: .propagated)))

            case let .endpoint(.delegate(.singlePacketDelivered(token))):
                return .send(.router(.opportunisticDelivered(messageHash: token)))

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

    /// The delivery stamp cost to apply when sending to `destinationHash`, or **nil meaning
    /// "no stamp"** (either no cost is known or the announced cost exceeds the ceiling).
    ///
    /// `peer.stampCost` comes from the `lxmf.delivery` announce app-data, which is unauthenticated:
    /// any reachable peer can advertise any value. The search is exponential — 64 is ~2^64 rounds
    /// over a 768 KB (3000-round) workblock — so the ceiling is mandatory. See
    /// `LXMFNode.maxDeliveryStampCost` for the ceiling and why refusing beats clamping.
    ///
    /// A cost of 0 is treated as "no stamp required", matching reference's own emit gate at
    /// `get_announce_app_data` (LXMRouter.py:1044): it only emits a stamp_cost when `> 0 and < 255`,
    /// so 0 in `outbound_stamp_costs` means "peer said no cost", and `handle_outbound`
    /// (LXMRouter.py:1752-1757) only calls `get_stamp()` when `stamp_cost != None` — a 0 stored
    /// there would still trigger the search, but no conforming peer emits 0, so in practice 0 means
    /// the field was absent. We map it explicitly: cost=0 → no stamp.
    private func deliveryStampCost(_ state: State, destinationHash: Data) -> Int? {
        guard let peer = state.learnedPeers[destinationHash],
              let cost = peer.stampCost,
              cost > 0
        else { return nil }
        guard cost <= LXMFNode.maxDeliveryStampCost else { return nil }
        return cost
    }

    /// Hand `message` to the router, generating a delivery stamp first when the recipient has
    /// advertised a cost we are willing to pay. Shared by `.send` (which builds its own message)
    /// and `.sendMessage` (which takes the caller's) so the two cannot drift — they did drift once:
    /// stamping landed on `.send` only, while the app's sole send path is `.sendMessage`.
    ///
    /// **An existing stamp is never overwritten.** `.sendMessage` takes a caller-supplied
    /// `LXMessage` that may already carry one, and re-stamping would discard work already done and
    /// change the bytes the caller expects to send. Reference behaves identically: `get_stamp`
    /// returns the existing stamp untouched (`elif self.stamp != None: return self.stamp`,
    /// LXMessage.py:313, LXMF 1.1.0). Messages from `LXMessage.create` always have `stamp == nil`,
    /// so this check is a no-op on the `.send` path.
    ///
    /// Refusing to stamp never refuses to send: a cost of 0, or one above `maxDeliveryStampCost`,
    /// takes the guard below and hands the message on **unstamped**. The recipient may drop it if it
    /// enforces stamps; that is its choice, and it beats losing the message on our side.
    ///
    /// **A CANCELLED search is different, and it does drop the message.** `LXStamper.search` returns
    /// nil only when `Task.isCancelled`, and TCA suppresses every action sent from a cancelled effect
    /// (`Send.callAsFunction`, Effect.swift:191-194), so "send it unstamped instead" is not
    /// implementable from in here — the substitute send would be swallowed exactly like the real one.
    /// This docstring previously claimed the opposite ("an unstamped send, not a dropped message"),
    /// and the `else { stamped = message }` branch that appeared to implement it was dead code.
    /// The cancellation is reported instead by `.cancelDeliveryStamps`, which emits
    /// `.delegate(.deliveryFailed)` for every hash in `State.inFlightDeliveryStamps` — appended here.
    private func deliverySend(_ state: inout State, message: LXMessage,
                              method: LXMFRouter.DeliveryMethod) -> Effect<Action> {
        guard message.stamp == nil,
              let cost = deliveryStampCost(state, destinationHash: message.destinationHash)
        else { return .send(.router(.send(message: message, desiredMethod: method))) }
        if !state.inFlightDeliveryStamps.contains(message.hash) {
            state.inFlightDeliveryStamps.append(message.hash)
        }
        return .run { send in
            // nil ⟹ cancelled (the only way `search` returns nil). Nothing to send: see above.
            guard let stamp = await LXStamper.generateStamp(messageId: message.hash, targetCost: cost)
            else { return }
            await send(.router(.send(message: message.withStamp(stamp), desiredMethod: method)))
        }
        .cancellable(id: CancelID.deliveryStamp)
    }
}
