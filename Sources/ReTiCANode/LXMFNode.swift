import Foundation
import ComposableArchitecture
import OSLog
import ReTiCA
import ReTiCATransport

/// The first production composition connecting the decoupled `LXMFRouter` to real transport (LXMF-Node,
/// opportunistic 1:1). Composes `TransportEndpoint` (TCP or BLE) + `LXMFRouter` and translates their
/// delegates/actions: the app calls `.registerDelivery` then `.send(...)`, and receives
/// `.delegate(.messageReceived(...))`. Direct-over-link, path requests, delivery confirmation, and
/// propagation wiring are follow-ons.
@Reducer
public struct LXMFNode {
    /// Inbound drops the app is never told about (`.messageRejected`).
    static let log = Logger(subsystem: "com.retica", category: "lxmf")

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
        /// Stamp cost the peer advertised, or nil. Fractional since LXMF 1.3.0.
        ///
        /// **Unauthenticated, potentially hostile.** See the note on this struct and on
        /// `LXMFAnnounceData.stampCost` before acting on this value. A value parsed from an announce
        /// is in `0 < cost < 100` (`LXMFAnnounceData.parse` gates it), but this initializer is public
        /// and a host restoring persisted rows can put anything here; it has NOT been validated
        /// against the outbound ceiling.
        public var stampCost: Double?
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

        public init(displayName: String?, stampCost: Double?, supportsCompression: Bool, learnedAt: Date) {
            self.displayName = displayName
            self.stampCost = stampCost
            self.supportsCompression = supportsCompression
            self.learnedAt = learnedAt
        }
    }

    /// An LXMF stamp ticket (LXMF 1.3.0): 16 bytes that let the holder stamp messages to the issuer
    /// with `LXMessage.ticketStamp` instead of proof-of-work, until `expires`.
    public struct Ticket: Equatable, Sendable {
        public var ticket: Data
        public var expires: Date

        public init(ticket: Data, expires: Date) {
            self.ticket = ticket
            self.expires = expires
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
        /// Senders whose messages are dropped on delivery: `lxmf.delivery` destination hashes
        /// (what `LXMessage.sourceHash` carries), never raw identity hashes. Reference
        /// `LXMRouter.ignored_list` (LXMRouter.py, LXMF 1.1.1). The library holds the set in
        /// memory only; the host persists it and replays it with `.rehydrateIgnoredDestinations`
        /// on launch, like `rehydrateLearnedPeers`. Announces from an ignored peer still update
        /// `learnedPeers`: the library hides no peers, the host does.
        public var ignoredDestinations: Set<Data> = []

        /// Tickets peers gave us, by the peer's `lxmf.delivery` hash: one per peer, the newest
        /// received wins (reference `remember_ticket`'s upsert, `Storage.py:228-238`). Written only
        /// from a message whose signature validated that carries a well-formed, unexpired
        /// `FIELD_TICKET` (`LXMRouter.py:2176-2184`); reported as `.ticketReceived`. While unexpired,
        /// a send to that peer is stamped with the ticket — no cost wait, no search — even when the
        /// peer advertises no cost, as reference does (`LXMessage.py:303-310`). An expired entry is
        /// never used; it stays here for the rest of the session and is dropped by the next
        /// `.rehydrateTickets` (reference also culls every ~8 minutes; this library does not).
        public var outboundTickets: [Data: LXMFNode.Ticket] = [:]
        /// Tickets we issued, by the `lxmf.delivery` hash of the peer we issued them to. When we
        /// have a `deliveryStampCost`, an inbound message whose stamp is the ticket stamp of one of
        /// the unexpired tickets issued to ITS sender is valid without proof-of-work
        /// (`LXMRouter.py:2190-2193`, `Storage.py:290-301`). Tickets issued to anyone else do not count.
        /// Written when a ticket is minted for an outbound message (see `issueTickets` and
        /// `ticketFieldToIssue(destinationHash:now:)`), reported as `.ticketIssued`, and restored by
        /// `.rehydrateTickets`.
        public var inboundTickets: [Data: [LXMFNode.Ticket]] = [:]
        /// When a message carrying a ticket we issued was last confirmed delivered, by recipient
        /// `lxmf.delivery` hash (reference `ticket_deliveries`, `LXMRouter.py:3060-3067`). While
        /// less than `LXMessage.ticketInterval` (1 day) old, no ticket is put in messages to that
        /// peer. Reported as `.ticketDelivered`; restored by `.rehydrateTickets`.
        public var lastTicketDeliveries: [Data: Date] = [:]
        /// Whether messages this node builds (`.send`, `.sendViaPropagation`) carry a ticket for
        /// their recipient, by reference `generate_ticket` (`LXMRouter.py:1205-1228`). Reference
        /// leaves this to the client per message (`include_ticket`, default off); here it is one
        /// switch, **off by default**, set with `.setIssueTickets`. Host-built messages
        /// (`.sendMessage`) get theirs from `ticketFieldToIssue(destinationHash:now:)`.
        public var issueTickets: Bool = false
        /// Outbound messages that carry a ticket we issued, by message hash → recipient. Lets a
        /// delivery confirmation record `lastTicketDeliveries`. An entry goes at the message's
        /// delivery confirmation, or at the first sweep after it can no longer be confirmed. A sweep
        /// runs at every terminal outcome reported for any message and at every new ticket-carrying
        /// send. So entries are bounded by the messages still out, plus those ended silently since the
        /// last sweep (a delivery copy that ends after its propagated copy was accepted reports nothing).
        public internal(set) var ticketCarryingMessages: [Data: Data] = [:]
        /// Ticket-carrying messages whose propagated copy was accepted while their delivery copy was
        /// still out. Tells a sweep that the router's success for them has been handled here.
        public internal(set) var ticketMessagesAccepted: Set<Data> = []

        /// Display name advertised in every delivery-destination announce.
        /// Nil means no name is encoded (the announce still carries the full app-data blob per
        /// reference parity — see `LXMFAnnounceData.pack` and `get_announce_app_data` in
        /// LXMF 1.1.0 LXMRouter.py:1034-1050 which always calls `msgpack.packb(peer_data)`).
        public var displayName: String?

        /// Delivery stamp cost advertised in every delivery-destination announce and demanded of
        /// inbound messages. Fractional (LXMF 1.3.0). `setDisplayName` keeps it in 1..<100; a value
        /// written here directly outside reference's `> 0 and < STAMP_COST_CAP` emit gate
        /// (LXMRouter.py:1172-1174) is announced as null.
        public var deliveryStampCost: Double?

        /// Whether to DROP inbound messages whose stamp fails validation (or is absent) when a
        /// `deliveryStampCost` is configured.
        ///
        /// **Defaults to `false`**, matching reference (`enforce_stamps=False` in `LXMRouter.__init__`,
        /// LXMRouter.py:99). With enforcement off, an invalid or absent stamp is logged but the
        /// message is delivered — exactly `LXMRouter.lxmf_delivery`'s else-branch at line 1878.
        ///
        /// Set to `true` to drop messages with invalid stamps, mirroring reference's `enforce_stamps()`
        /// call (LXMRouter.py:696-697). A stamp equal to the ticket stamp of an unexpired ticket in
        /// `inboundTickets` for the sender is valid too, as in reference `validate_stamp`
        /// (LXMessage.py:280-301, LXMF 1.3.0); a ticket only counts if this node holds it.
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
        /// The failure is therefore started by the `.cancelDeliveryStamps` reducer branch, which is
        /// not itself cancelled, over this list (through the router's `fail`). Reference works the same way: `cancel_outbound`
        /// only flags the message and calls `LXStamper.cancel_work` (LXMRouter.py:1719-1725,
        /// LXMF 1.1.0); the `failed_callback` is invoked later by `process_deferred_stamps` on the
        /// router's own thread, once `get_stamp()` has returned None (LXMRouter.py:2620-2630).
        ///
        /// Entries are appended when a delivery-stamp job enters `stampQueue` (whether it starts at
        /// once or waits) and removed when `.router(.send)` carries the message onward, so a search
        /// that already completed is never failed retroactively.
        ///
        /// A send in `waitingForPeerCost` is listed here too. It has not reached the router either,
        /// so the same cancel and fallback handling applies to it.
        public internal(set) var inFlightDeliveryStamps: [Data] = []

        /// The last `deliveryPreparing` phase reported per message that has not reached the router
        /// (`.waitingForPeer`, `.queued` or `.stamping`; `.handedOver` is never stored). Lets each
        /// phase be reported once, and `.handedOver` only for a message that reported an earlier phase.
        /// Removed at hand-over and at every terminal outcome or cancel.
        public internal(set) var preparingPhases: [Data: PreparingPhase] = [:]

        /// LXMF stamp jobs waiting for `runningStampJob` to end, oldest first. One search runs at a
        /// time, router-wide, as reference does (`process_deferred_stamps` takes `stamp_gen_lock` and
        /// works on the oldest entry of `pending_deferred_stamps`, LXMRouter.py:2944-3033, LXMF 1.3.0).
        /// When the running job ends — its stamp found, its search cancelled, or nothing found — the
        /// first job here starts in the same reduction.
        ///
        /// A queued job is "in flight" for every cancel: a delivery job is in `inFlightDeliveryStamps`
        /// and an explicit propagated send has its `preparingPhases` entry, from the moment it is
        /// queued, so `.cancelDeliveryStamps`, `.cancelPropagationStamps`, `.setPropagationNode`
        /// and `.cancelOutbound` report it exactly as they report a running one, and remove it here.
        /// Sends stamped with a ticket and sends to a peer with no cost never enter the queue.
        /// Link-request key searches are not LXMF stamps and are not queued here.
        public internal(set) var stampQueue: [StampJob] = []
        /// The one LXMF stamp search running, or nil. See `stampQueue`.
        public internal(set) var runningStampJob: StampJob?
        /// The serial the next `StampJob` gets. A search's effect is cancelled by its serial, and its
        /// result names it, so a result from a job that was stopped is never taken for another's.
        var nextStampJobSerial = 0

        /// First sends to a peer we have no path to and no cost for, by destination, oldest first.
        /// The announce that brings the path also brings the cost, so they wait for it instead of
        /// going out unstamped. See `deliverySend`.
        public internal(set) var waitingForPeerCost: [Data: [WaitingSend]] = [:]

        /// Sends whose wait ran out, handed to the router unstamped with their recipient's cost still
        /// unknown, by destination. Nothing of them has gone out: there is no path. At the first
        /// announce from that destination, if it brings a cost, each copy the router has not yet
        /// sent is taken back and handed over again stamped. See `restampUnsentHandOvers`.
        public internal(set) var unstampedHandOvers: [Data: [WaitingSend]] = [:]

        /// Messages sent with `fallbackToPropagation` whose propagated copy has not started: it is
        /// packed only when the router reports `propagationFallbackDue` (spec Amendment A2). Dropped
        /// at the hand-off and when the message ends any other way.
        public internal(set) var pendingFallbacks: [Data: LXMessage] = [:]

        /// linkID → the resource hash of OUR Resource in flight on that link, learned from the first
        /// sender-role `resourceProgress` after the router starts a copy there. A conclusion or
        /// failure naming any other hash on that link is not our copy's: an inbound transfer's, or a
        /// cancelled one landing late.
        public internal(set) var outboundTransfers: [Data: Data] = [:]
        /// The last fraction reported per outbound copy, so `deliveryProgress` /
        /// `propagationProgress` never go backwards — a retry restarts the wire transfer, not the copy.
        public internal(set) var transferProgress: [LXMFRouter.DeliveryKey: Double] = [:]
        /// linkID → the last `inboundTransferProgress` fraction reported for the Resource arriving on it.
        public internal(set) var inboundProgress: [Data: Double] = [:]

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
        /// Drop every message whose `sourceHash` equals this lxmf.delivery hash. State only.
        /// Reference `LXMRouter.ignore_destination`.
        case ignoreDestination(Data)
        /// Reverse of `ignoreDestination`. State only. Reference `LXMRouter.unignore_destination`.
        case unignoreDestination(Data)
        /// Replace the whole ignore set. The host sends it on launch next to
        /// `rehydrateLearnedPeers`; an empty set clears everything.
        case rehydrateIgnoredDestinations(Set<Data>)
        /// Turn ticket issuing on or off (`State.issueTickets`, default off). State only.
        case setIssueTickets(Bool)
        /// Restore ticket state from a previous session: `outbound` → `State.outboundTickets`,
        /// `inbound` → `State.inboundTickets`, `lastDeliveries` → `State.lastTicketDeliveries`.
        /// The host sends it on launch next to `rehydrateLearnedPeers`.
        ///
        /// Sweeps in the same pass, as reference `clean_available_tickets` does at startup
        /// (`LXMRouter.py:1498-1512`, cull `expires < cutoff`): an outbound ticket whose expiry is
        /// before now is dropped, and an inbound one whose expiry is more than
        /// `LXMessage.ticketGrace` (5 days) before now. Also dropped: a ticket that is not
        /// `LXMessage.ticketLength` bytes or whose expiry is not finite, and a delivery time that is
        /// not finite or is in the future (it would stop issuing to that peer until the clock caught up).
        ///
        /// A restored row never replaces live state: a live outbound ticket arrived this session, so
        /// it is the newest (reference keeps the newest received); an inbound ticket already held is
        /// not duplicated; a live delivery time at least as recent is kept.
        case rehydrateTickets(outbound: [Data: Ticket], inbound: [Data: [Ticket]], lastDeliveries: [Data: Date])
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
        case setDisplayName(String?, stampCost: Double?)
        /// Announce the delivery destination now, carrying the current `displayName` and
        /// `deliveryStampCost`. Broadcasts on EVERY connected interface with no throttle, so call
        /// it when a change is settled — not on every keystroke of an edit.
        /// Requires `registerDelivery` to have been called first; silently ignored otherwise.
        /// For the interface-up re-announce use `.announceDeliveryOnInterface`.
        case announceDelivery
        /// Announce the delivery destination on ONE interface: the interface-up re-announce
        /// (2026-10-16 Meshtastic spec, Contract 4), so a node joining a slow link does not
        /// re-broadcast on every other interface too. Same app data and same no-op rule as
        /// `.announceDelivery`; transmits nothing when that interface is not connected.
        case announceDeliveryOnInterface(InterfaceID)
        /// Build and send a message. With `State.issueTickets` on it carries a stamp ticket for its
        /// recipient when reference `generate_ticket` would include one (so does `.sendViaPropagation`).
        case send(destinationHash: Data, title: Data, content: Data, method: LXMFRouter.DeliveryMethod)
        case setPropagationNode(destinationHash: Data)
        case sendViaPropagation(destinationHash: Data, title: Data, content: Data)
        /// Send `message` directly. With `fallbackToPropagation`, a copy goes to the propagation node
        /// only if the direct copy stalls (its third attempt) or fails; a copy the node would refuse
        /// for size is reported `propagationRefused` at once instead.
        ///
        /// `message` is already hashed and signed, so the node cannot add a stamp ticket to it. To
        /// issue one, build the message with `State.ticketFieldToIssue(destinationHash:now:)` in its
        /// fields; a ticket from our own delivery destination found here is recorded in
        /// `State.inboundTickets` (reported `.ticketIssued` if new) and its delivery is counted.
        case sendMessage(message: LXMessage, fallbackToPropagation: Bool)
        case syncFromPropagationNode
        /// Cancel in-flight propagation stamp work. An explicit `.sendViaPropagation` still stamping is
        /// reported `.delegate(.deliveryFailed(messageHash:))` (once, never handed over), and so is
        /// one still stamping when `.setPropagationNode` names a different node. The same holds for
        /// the pending propagated copies of fallback sends, which fail through the router.
        case cancelPropagationStamps
        /// Cancel any in-flight delivery-stamp searches. Call when the app backgrounds, the user
        /// abandons a send, or the destination is no longer reachable. Mirrors `cancelPropagationStamps`
        /// for delivery-stamp searches, running or queued (`State.stampQueue`).
        ///
        /// **Every message still searching is FAILED, not sent unstamped.** One
        /// `.delegate(.deliveryFailed(messageHash:))` is emitted per entry in
        /// `State.inFlightDeliveryStamps` — the app must treat those messages as not sent — unless
        /// the message's propagated copy is still out (its outcome is the message's) or a copy
        /// already succeeded (no second terminal). Reference
        /// does the same (`process_deferred_stamps` → `failed_callback`, LXMRouter.py:2620-2625,
        /// LXMF 1.1.0). The alternative — sending unstamped — is not available: the cancellation that
        /// ends the search also suppresses every action the search's effect could still emit, so
        /// "send it unstamped instead" cannot be implemented from inside that effect at all.
        case cancelDeliveryStamps
        /// Cancel one outbound message, wherever it is: in its delivery or propagation stamp search,
        /// queued, retrying, or mid-transfer (its Resource is cancelled on the wire). Reports
        /// `.delegate(.deliveryCancelled)` once; nothing else is reported for it afterwards. That
        /// includes an explicit `.sendViaPropagation` still stamping: its stamp work is stopped.
        /// Reference `LXMRouter.cancel_outbound` (LXMRouter.py:1719-1744).
        case cancelOutbound(messageHash: Data)
        /// Internal: a path-request interval has passed for sends in `waitingForPeerCost`.
        case peerCostWaitElapsed(destinationHash: Data, requestsLeft: Int)
        /// Hold (`true`) outbound retries when the app is suspended and its sockets close, and release
        /// them (`false`) when an interface reconnects. While held no attempt is counted and nothing
        /// is sent, so no message fails or falls back; the release resumes each from where it stood.
        /// Packing a propagated copy goes on regardless. Spec Amendment A3; see `LXMFRouter.State.held`.
        ///
        /// **Order matters.** Send `holdOutbound(true)` BEFORE closing the sockets: the hold refunds a
        /// transfer the closure kills, and defers re-establishing its link, only if it is already in
        /// place when the resulting `linkClosed` / `resourceFailedOnLink` reach the router.
        ///
        /// **Release on foreground too**, not only when an interface reconnects. Otherwise, with the
        /// app open and no connectivity, the hold stays on and no send ever fails or falls back.
        case holdOutbound(Bool)
        /// Internal: the running stamp search `serial` ended. `outcome` is nil when it returned no
        /// stamp without being cancelled (a cancelled search sends nothing: TCA drops sends from a
        /// cancelled effect). See `State.stampQueue`.
        case stampSearchEnded(serial: Int, outcome: StampSearchOutcome?)
        case delegate(Delegate)

        /// **Terminal outcomes of an outbound message**: `deliveryConfirmed`, `propagationAccepted`,
        /// `deliveryFailed`, `deliveryRejected`, `deliveryCancelled`.
        ///  • Every message sent gets at least one.
        ///  • It may get two: `deliveryConfirmed` AND `propagationAccepted`, in either order, when
        ///    both its copies succeed (a fallback copy already handed to the node goes on after the
        ///    delivery copy is confirmed).
        ///  • A failure (`deliveryFailed`, `deliveryRejected`) or `deliveryCancelled` never follows
        ///    a success.
        /// So consumers must handle terminals idempotently: a second success changes nothing.
        public enum Delegate: Equatable {
            /// `method` is how the message arrived: a single packet, a link, or a propagation node
            /// download. With duplicates the first arrival wins (the router's dedup is unchanged).
            case messageReceived(message: LXMessage, signatureValidated: Bool, method: LXMFRouter.DeliveryMethod)
            case deliveryFailed(messageHash: Data)
            case deliveryConfirmed(messageHash: Data)
            case propagationAccepted(messageHash: Data)
            /// Every copy is over, none succeeded, and the last one's transfer was refused by its peer.
            case deliveryRejected(messageHash: Data)
            /// The app cancelled the message (`.cancelOutbound`).
            case deliveryCancelled(messageHash: Data)
            /// The delivery copy's progress on the reference scale: 0.05 when its link is up and the
            /// transfer is about to start, 0.10 when it starts, `0.10 + 0.90 × done` during (at most
            /// 0.99 — the last part served is not yet a confirmation), 1.0 when confirmed
            /// (LXMRouter.py:2788-2790, LXMessage.py:623-624). Never decreases.
            case deliveryProgress(messageHash: Data, fraction: Double)
            /// The same for the copy sent to the propagation node; 1.0 when it is accepted.
            case propagationProgress(messageHash: Data, fraction: Double)
            /// A Resource arriving on `linkID`, 0…1, before any message can be unpacked from it.
            /// `sourceHash` is the far end of the link when WE opened it; nil when a peer linked to our
            /// own destination, because LXMF senders do not identify on delivery links.
            case inboundTransferProgress(sourceHash: Data?, linkID: Data, fraction: Double)
            /// The propagated copy was not attempted — `.tooLargeForNode`: larger than the configured
            /// node's announced per-transfer limit. The delivery copy is unaffected.
            case propagationRefused(messageHash: Data, reason: LXMFRouter.RefusalReason)
            /// A send is being prepared before the router has it, in the phase named. Reported once per
            /// transition, and only for sends that need preparing: one that goes straight to the router
            /// reports nothing. `.handedOver` follows a `.waitingForPeer`, `.queued` or `.stamping` report
            /// when the message reaches the router. A send queued behind another stamp search reports
            /// `.queued`, then `.stamping` when its own search starts. A re-stamp of a copy taken back after hand-over reports
            /// `.stamping` again, then `.handedOver` again. A message that ends or is cancelled while
            /// preparing reports its terminal outcome and no `.handedOver`.
            case deliveryPreparing(messageHash: Data, phase: PreparingPhase)
            /// A peer gave us a ticket, now in `State.outboundTickets[destinationHash]` (the peer's
            /// `lxmf.delivery` hash). Reported when the stored entry changes, so the host can persist it.
            case ticketReceived(destinationHash: Data, ticket: LXMFNode.Ticket)
            /// We minted a ticket for the peer `destinationHash` and put it in an outbound message;
            /// it is now in `State.inboundTickets[destinationHash]`. Persist it: without it, after a
            /// relaunch that peer's ticket stamps no longer validate. Not reported when a ticket
            /// already held is reused. It can repeat a ticket reported in an earlier session: a
            /// message carrying it, resent before `.rehydrateTickets` restores `inboundTickets`, is
            /// reported again. Hosts should upsert by the ticket bytes.
            case ticketIssued(destinationHash: Data, ticket: LXMFNode.Ticket)
            /// A message carrying a ticket we issued to `destinationHash` was confirmed delivered at
            /// `at`, now in `State.lastTicketDeliveries`. Persist it.
            case ticketDelivered(destinationHash: Data, at: Date)
        }
    }

    /// Where a send stands before the router has it. See `Action.Delegate.deliveryPreparing`.
    public enum PreparingPhase: Equatable, Sendable {
        /// A first send to a peer we have no path and no stamp cost for, waiting for its announce.
        case waitingForPeer
        /// Its stamp search waits behind another message's: one LXMF stamp search runs at a time,
        /// oldest first (`State.stampQueue`).
        case queued
        /// A stamp search is running (the delivery stamp, or the work for an explicit propagated send).
        case stamping
        /// The message reached the router.
        case handedOver
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
    /// stamp_cost = None)`, LXMRouter.py:348) and `set_inbound_stamp_cost` accepts **any int or float
    /// in 1..<100** (LXMF 1.3.0 LXMRouter.py:444-462; 1…254 in 1.1.0). So a perfectly conforming peer
    /// may demand anything above 20 and below 100, and we
    /// refuse to stamp for every one of them — those peers, if they `enforce_stamps()`, will drop
    /// our messages. We are choosing bounded CPU over deliverability to that (unbounded-cost) tail.
    /// An earlier version of this comment cited `PROPAGATION_COST + PROPAGATION_COST_FLEX = 19` as
    /// evidence that nothing legitimate exceeds 20; that is a propagation-side constant with no
    /// bearing on delivery costs, and it told the reader the opposite of the truth.
    ///
    /// Refusal, not clamping: a stamp generated below the peer's advertised cost is one that peer
    /// will drop — a silent failure after all that work. Refusing is clean.
    ///
    /// A Double since peer costs are fractional (LXMF 1.3.0); still 20, and a cost of 20.5 is refused.
    public static let maxDeliveryStampCost: Double = 20

    /// Age at which a `learnedPeers` entry is swept. Matches reference's
    /// `STAMP_COST_EXPIRY = 45 * 24 * 60 * 60` (LXMRouter.py:39, LXMF 1.1.0).
    ///
    /// The sweep runs when `.rehydrateLearnedPeers` restores the table at launch — reference
    /// sweeps `outbound_stamp_costs` once per startup, immediately after loading it from disk
    /// (LXMRouter.py:276-277), and runs no periodic timer. On iOS the launch is the routine path,
    /// so a launch-time sweep fires routinely; entries learned live during a session are swept at
    /// the next one.
    public static let stampCostExpiry: TimeInterval = 45 * 24 * 60 * 60

    /// Progress when a copy's link is active and its transfer is about to start (LXMRouter.py:2788-2790).
    public static let linkActiveProgress = 0.05
    /// Progress when a copy's transfer starts (reference: once the Resource exists).
    public static let transferStartProgress = 0.10

    /// A Resource's overall done fraction: finished segments plus this segment's share.
    public static func transferFraction(bytesDone: Int, bytesTotal: Int, segment: Int, segments: Int) -> Double {
        guard bytesTotal > 0, segments > 0 else { return 0 }
        let within = min(max(Double(bytesDone) / Double(bytesTotal), 0), 1)
        let index = min(max(segment, 1), segments)
        return (Double(index - 1) + within) / Double(segments)
    }

    /// An outbound copy's progress during its transfer: `0.10 + 0.90 × transfer progress`
    /// (reference `LXMessage.__update_transfer_progress`, LXMessage.py:623-624).
    /// Capped at `maxTransferProgress`: the last part served is not a confirmation, so only the
    /// confirmation itself reports 1.0 — otherwise a retry after a fully-sent transfer would sit at 100%.
    public static func outboundFraction(bytesDone: Int, bytesTotal: Int, segment: Int, segments: Int) -> Double {
        min(transferStartProgress + (1 - transferStartProgress)
                * transferFraction(bytesDone: bytesDone, bytesTotal: bytesTotal, segment: segment, segments: segments),
            maxTransferProgress)
    }
    /// The highest progress a transfer reports before its copy is confirmed.
    public static let maxTransferProgress = 0.99

    /// One LXMF stamp job in `State.stampQueue`: a message's delivery stamp, or — for a propagated
    /// copy — its delivery stamp (when one is still needed) then its propagation stamp, as one job, as
    /// reference does both for one message before anything for the next (LXMRouter.py:2979-3029).
    public struct StampJob: Equatable, Sendable {
        public enum Work: Equatable, Sendable {
            /// The delivery stamp at `cost`; the stamped message goes to the router with `method`.
            case delivery(method: LXMFRouter.DeliveryMethod, cost: Double)
            /// A propagated copy: the delivery stamp at `deliveryCost` (none when nil), then packed for
            /// the propagation node with a stamp at the node's cost as read when the job STARTS
            /// (reference reads `get_outbound_propagation_cost` in `process_deferred_stamps`,
            /// LXMRouter.py:3003). `explicit`: a `.sendViaPropagation`, which reports phases;
            /// otherwise a fallback copy, which does not.
            case propagated(explicit: Bool, deliveryCost: Double?, recipient: Identity, timestamp: Double)
        }
        public let serial: Int
        public let message: LXMessage
        public let work: Work

        var isDelivery: Bool { if case .delivery = work { return true } else { return false } }
        /// Delivery jobs and explicit propagated sends report `deliveryPreparing`; fallback copies do not.
        var reportsPhases: Bool {
            if case .propagated(explicit: false, _, _, _) = work { return false }
            return true
        }
    }

    /// What a stamp search that was not cancelled produced. See `Action.stampSearchEnded`.
    public enum StampSearchOutcome: Equatable, Sendable {
        /// The message with its delivery stamp.
        case delivery(LXMessage)
        /// The message (with its delivery stamp, if it needed one) and its packed propagated copy.
        case propagated(LXMessage, propagationPacked: Data)
    }

    /// Cancellation identities.
    ///
    /// `stampSearch(serial)` is the running stamp job's search (`State.runningStampJob`): every
    /// cancel that stops a running job cancels it by its serial, so exactly that search stops.
    /// Reference's `LXStamper.cancel_work` is keyed per message (LXStamper.py:146).
    enum CancelID: Hashable {
        case stampSearch(Int)
        case peerCostWait(Data)
    }

    /// A first send waiting for its recipient's stamp cost.
    public struct WaitingSend: Equatable {
        let message: LXMessage
        let method: LXMFRouter.DeliveryMethod
    }

    /// How many path requests a first send makes, `LXMFDelivery.pathRequestWaitSeconds` apart, before
    /// it is handed to the router unstamped: 21 s in all. A compromise. Waiting is what gets the
    /// stamp right, but the router only starts its own path budget and any propagation fallback once
    /// it has the message, so a recipient that is really offline is delayed by this long. An announce
    /// that comes after the hand-over still gets the message stamped: `restampUnsentHandOvers`.
    static let peerCostPathRequests = 3

    @Dependency(\.date) var date
    /// Transport's clock: a peer ratchet's receive time is stamped with it, so its freshness is read
    /// with it too (`recallRatchet`).
    @Dependency(\.transportDate) var transportDate
    @Dependency(\.continuousClock) var clock
    /// A minted ticket's bytes. Live: `SecRandomCopyBytes`. Test: the ramp `00 01 02 …`.
    @Dependency(\.randomBytes) var randomBytes
    /// The stamp searches the stamp queue runs. Live: `LXStamper` / `LXMFPropagation.pack`.
    @Dependency(\.lxmfStampGenerator) var stampGenerator
    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.endpoint, action: \.endpoint) { TransportEndpoint() }
        Scope(state: \.router, action: \.router) { LXMFRouter() }
        Reduce { [date] state, action in
            func isServedPropagationLink(_ state: LXMFNode.State, _ linkID: Data) -> Bool {
                guard let served = state.propagationDestinationHash else { return false }
                return state.linkDestinations[linkID] == served
            }
            /// Report `fraction` for this copy unless it would not move its progress forward.
            func reportProgress(_ state: inout LXMFNode.State, _ key: LXMFRouter.DeliveryKey,
                                _ fraction: Double) -> Effect<Action> {
                let clamped = min(max(fraction, 0), 1)
                if let last = state.transferProgress[key], clamped <= last { return .none }
                state.transferProgress[key] = clamped
                let event: Action.Delegate = key.leg == .delivery
                    ? .deliveryProgress(messageHash: key.messageHash, fraction: clamped)
                    : .propagationProgress(messageHash: key.messageHash, fraction: clamped)
                return .send(.delegate(event))
            }
            /// The message is over: forget both copies' progress.
            func clearProgress(_ state: inout LXMFNode.State, _ hash: Data) {
                state.transferProgress[.delivery(hash)] = nil
                state.transferProgress[.propagated(hash)] = nil
            }
            /// The copy succeeded: report 1.0 (unless its transfer already did) and forget it — and,
            /// when that was the message's last copy, the other copy's progress too. A copy that
            /// failed while this one was outstanding got no delegate (the router's `fail` stays
            /// silent then), so its entry would otherwise outlive the message. The other copy's
            /// entry is kept while that copy is still outstanding, so its progress stays monotonic.
            func finishProgress(_ state: inout LXMFNode.State, _ key: LXMFRouter.DeliveryKey) -> Effect<Action> {
                let finished = state.transferProgress.removeValue(forKey: key)
                if !state.router.hasOutboundState(for: key.messageHash) { clearProgress(&state, key.messageHash) }
                guard let last = finished, last < 1 else { return .none }
                let event: Action.Delegate = key.leg == .delivery
                    ? .deliveryProgress(messageHash: key.messageHash, fraction: 1)
                    : .propagationProgress(messageHash: key.messageHash, fraction: 1)
                return .send(.delegate(event))
            }
            /// A new Resource transfer starts on `linkID`: clear any stale hash recorded for it (a
            /// fresh copy names its own hash from its first sender-role progress event) and report the
            /// reference scale's 0.05 if the router started a copy there. Shared by `.sendDirect`'s and
            /// `.sendPropagated`'s handlers (Ruling P10) — both start a Resource copy on a link the same way.
            func startResourceTransfer(_ state: inout LXMFNode.State, _ linkID: Data) -> Effect<Action> {
                state.outboundTransfers[linkID] = nil
                guard let key = state.router.linkResourceInFlight[linkID] else { return .none }
                return reportProgress(&state, key, LXMFNode.linkActiveProgress)
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

            case let .ignoreDestination(hash):
                state.ignoredDestinations.insert(hash)
                return .none

            case let .unignoreDestination(hash):
                state.ignoredDestinations.remove(hash)
                return .none

            case let .rehydrateIgnoredDestinations(hashes):
                state.ignoredDestinations = hashes
                return .none

            case let .setIssueTickets(on):
                state.issueTickets = on
                return .none

            case let .rehydrateTickets(outbound, inbound, lastDeliveries):
                // Reference culls `expires < cutoff` (Storage.py:132-137, LXMRouter.py:1504-1505), so a
                // row exactly at its cutoff survives. Non-finite expiries are dropped: NaN compares
                // false both ways, so a plain `<` cutoff test would keep it forever.
                let now = date.now
                func wellFormed(_ t: Ticket) -> Bool {
                    t.ticket.count == LXMessage.ticketLength && t.expires.timeIntervalSinceReferenceDate.isFinite
                }
                var restoredOutbound: [Data] = []
                for (hash, ticket) in outbound where state.outboundTickets[hash] == nil {
                    guard wellFormed(ticket), ticket.expires >= now else { continue }
                    state.outboundTickets[hash] = ticket
                    if ticket.expires > now { restoredOutbound.append(hash) }
                }
                let inboundCutoff = now - LXMessage.ticketGrace
                for (hash, tickets) in inbound {
                    for ticket in tickets {
                        guard wellFormed(ticket), ticket.expires >= inboundCutoff,
                              state.inboundTickets[hash]?.contains(where: { $0.ticket == ticket.ticket }) != true
                        else { continue }
                        state.inboundTickets[hash, default: []].append(ticket)
                    }
                }
                for (hash, at) in lastDeliveries {
                    guard at.timeIntervalSinceReferenceDate.isFinite, at <= now else { continue }
                    if let live = state.lastTicketDeliveries[hash], live >= at { continue }
                    state.lastTicketDeliveries[hash] = at
                }
                // A send parked in the first-send cost wait for a peer whose ticket was just restored
                // gets the ticket stamp at once. A stamp search already running for that peer is not
                // restarted: it finishes with a valid stamp.
                return .merge(restoredOutbound.map { handOverWaitingSends(&state, destinationHash: $0) })

            case .registerDelivery:
                guard let d = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                          aspects: LXMessage.deliveryAspects, identity: state.identity)
                else { return .none }
                state.deliveryDestinationHash = d.hash
                // Always pack app-data — reference `get_announce_app_data` (LXMRouter.py:1034-1050)
                // returns `msgpack.packb(peer_data)` for every registered delivery destination, even
                // when display_name and stamp_cost are both None. The nil-checks on those fields
                // control only the *contents* of the packed list, never whether to emit one.
                let appData = deliveryAnnounceAppData(state)
                // LXMF 1.3.0 announces a link cost of 3.25 on its delivery destination
                // (LXMRouter.py:422); it is on the wire only when the host stamps announces.
                return .merge(.send(.endpoint(.registerLocalDestination(d, linkCost: LXMFDelivery.deliveryLinkCost))),
                              .send(.endpoint(.announce(destinationHash: d.hash, appData: appData))))

            case let .setDisplayName(name, stampCost):
                // Setter only — see the action's declaration for why the broadcast is a separate
                // action. Emitting an announce from here made an unthrottled network broadcast the
                // side effect of a state write, which a per-keystroke binding turns into a flood.
                state.displayName = name
                // Range-sanitise the cost HERE, because this is the only write to the field that the
                // whole inbound half keys on. Reference does it in the same place —
                // `set_inbound_stamp_cost` (LXMF 1.3.0 LXMRouter.py:444-462), the same rule for an int
                // and a float:
                //
                //     if stamp_cost == None:  stamp_cost = None; return True
                //     elif type(stamp_cost) == int (or float):
                //         if   stamp_cost < 1:   stamp_cost = None
                //         elif stamp_cost < cap: stamp_cost = stamp_cost      # cap = 100
                //         else:                  return False      # rejected, previous value KEPT
                //
                // So a fractional cost is kept exactly (99.5 is accepted), anything below 1 —
                // including 0.5, 0, negatives and -infinity — clears the cost, and 100, +infinity and
                // NaN are rejected with the previous cost kept. NaN takes the `default` arm because
                // both comparisons are false for it, as both are false in reference.
                //
                // Storing the raw value made the announce and the enforcement disagree, because
                // `LXMFAnnounceData.pack` already applies reference's emit gate (`> 0` and below the
                // cap). Measured, on this reducer, before this sanitising existed:
                //   • cost 0  — announced as "no cost required", yet `validateStamp(targetCost: 0)`
                //     was reached for every inbound message and returned false for an ABSENT stamp
                //     (`guard let stamp else { return false }` in `LXMessage.validateStamp`), so with
                //     enforcement on we dropped every message from every conforming peer.
                //   • cost -1 — at a negative cost every stamp is valid (the fixed-point target
                //     clamps to cost 0, as reference's `cost_to_fp` does), so an all-0xFF stamp
                //     validated. We reported `stampValid == true` to the app: a false trust signal,
                //     the worst outcome here.
                //
                // The upper bound is RNS 1.6.0's `Transport.STAMP_COST_CAP` (100), compared STRICTLY,
                // so 100 itself is rejected (LXMF 1.1.0's bound was 255). A host advertising more
                // than 100 made every reference sender fail: `generate_stamp` raises ValueError above
                // the cap (RNS/Stamps.py:255).
                //
                // A rejected cost keeps the previous cost rather than clearing it, exactly as
                // reference's `return False` leaves `delivery_destination.stamp_cost` untouched.
                // Silently disabling a configured cost because a later call was out of range would
                // be a downgrade an attacker-influenced settings value could trigger.
                switch stampCost {
                case .none:                                                       state.deliveryStampCost = nil
                case let .some(c) where c < 1:                                    state.deliveryStampCost = nil
                case let .some(c) where c < Double(NetworkStamp.stampCostCap):    state.deliveryStampCost = c
                default:                                                          break    // rejected; previous value kept
                }
                return .none

            case .announceDelivery:
                // No-op when registerDelivery was never called (deliveryDestinationHash nil).
                guard let hash = state.deliveryDestinationHash else { return .none }
                let appData = deliveryAnnounceAppData(state)
                return .send(.endpoint(.announce(destinationHash: hash, appData: appData)))

            case let .announceDeliveryOnInterface(interfaceID):
                guard let hash = state.deliveryDestinationHash else { return .none }
                let appData = deliveryAnnounceAppData(state)
                return .send(.endpoint(.announceOn(interface: interfaceID, destinationHash: hash, appData: appData)))

            case let .send(destinationHash, title, content, method):
                // The ticket field is part of the hashed, signed payload, so it is chosen before the
                // message exists (reference `handle_outbound` sets it before `pack`, LXMRouter.py:2098-2102).
                let msg = LXMessage.create(source: state.identity, destinationHash: destinationHash,
                                           timestamp: date.now.timeIntervalSince1970, title: title, content: content,
                                           fields: ticketFields(state, destinationHash))
                state.router.uncancel(msg.hash)   // an app send is a fresh send (see `.sendMessage`)
                let issued = recordIssuedTicket(&state, msg)
                return .merge(issued, deliverySend(&state, message: msg, method: method))

            case let .setPropagationNode(destinationHash):
                // The node already set is NOT a change: the app re-applies it on every
                // `interfaceConnected` (a listener client, a loopback slot, a TCP redial), and
                // treating that as a change cancelled a fallback copy's stamp search mid-way and
                // abandoned the copy — the message then failed when its delivery copy ran out,
                // having never reached the node (the photo of 2026-10-21). Every stamp in flight
                // was sized to THIS node's cost, so there is nothing to stop or redo.
                guard destinationHash != state.router.outboundPropagationNode else { return .none }
                let strandedSends = forgetPropagationStamping(&state)
                // Every in-flight stamp was sized to the PREVIOUS node's advertised cost, and a stamp
                // below a node's enforced minimum is dropped by its ingest — so finishing that search
                // could only burn a core for a message the new node would reject. Queued propagated
                // jobs are dropped; the running one is cancelled inside `dropStampJobs`, on this branch
                // only (`Effect.cancel(id:)` cancels when BUILT, 86ee622), and the next job starts.
                // The copies whose searches this abandons have failed (through the router's `fail`,
                // so a message whose delivery copy is still pending is not reported failed).
                let abandoned = abandonPendingPropagatedCopies(state)
                let dropped = dropStampJobs(&state) { !$0.isDelivery }
                return .merge(dropped, abandoned, strandedSends,
                              .send(.router(.setOutboundPropagationNode(destinationHash))))

            case let .sendViaPropagation(destinationHash, title, content):
                // `recall`, not the path table: a propagated copy needs only the recipient's key,
                // which a host may know without a path (an lxma:// contact, a persisted announce).
                // The cost is checked here so a refused node refuses the send at once; the job reads it
                // again when it starts (`startStampJob`).
                guard let recipient = state.endpoint.recall(destinationHash: destinationHash),
                      propagationStampCost(state) != nil
                else { return .none }
                let created = LXMessage.create(source: state.identity, destinationHash: destinationHash,
                                               timestamp: date.now.timeIntervalSince1970, title: title, content: content,
                                               fields: ticketFields(state, destinationHash))
                state.router.uncancel(created.hash)   // an app send is a fresh send (see `.sendMessage`)
                let issued = recordIssuedTicket(&state, created)
                refreshOutboundPropagationNodeRetryWait(&state)
                let ts = date.now.timeIntervalSince1970
                // The recipient's ticket, if we hold one, is the delivery stamp: no delivery search.
                // The propagation stamp is still searched, so the send is still queued and reports
                // `.queued` / `.stamping` (reference defers every PROPAGATED message, LXMRouter.py:2117-2123).
                let msg = ticketStamped(state, created) ?? created
                let deliveryCost = msg.stamp == nil ? deliveryStampCost(state, destinationHash: destinationHash) : nil
                let work = enqueueStampJob(&state, message: msg,
                                           work: .propagated(explicit: true, deliveryCost: deliveryCost,
                                                             recipient: recipient, timestamp: ts))
                return .merge(issued, work)

            case let .sendMessage(message, fallbackToPropagation):
                // The delivery copy is stamped on exactly the same terms as `.send` — this is the
                // path ReTiCaMsgr actually calls, so leaving it unstamped would have defeated the
                // whole point of bounding the cost elsewhere. The propagated copy keeps its OWN,
                // separate stamp (`startPropagatedCopy`): different workblock (1000 rounds vs 3000),
                // different material (transient_id vs message hash), its own job in `stampQueue`. See
                // `deliverySend` for why a caller-supplied stamp is never overwritten.
                //
                // A re-send of a message the app cancelled earlier is a FRESH send: forget the
                // cancel first, synchronously, before anything below consults it. The router's
                // `cancelledMessages` guards are for late hand-overs from the cancelled attempt
                // (whose per-message stamp effects were cancelled with it), and would otherwise
                // swallow this deliberate re-send and leave its row on "sending" for good.
                state.router.uncancel(message.hash)
                // A ticket the host put in from `ticketFieldToIssue` is recorded here, where the
                // message (and so its hash) first reaches the node.
                let issued = recordIssuedTicket(&state, message)
                // Direct first (spec Amendment A2): the propagated copy is only remembered here, and
                // packed when the router reports `propagationFallbackDue`. The router must know the
                // message is eligible BEFORE the delivery copy reaches it — a destination whose link
                // budget is already spent gives up inside `.send`, and that is a hand-off too — so
                // the two effects are concatenated, not merged.
                var fallback: Effect<Action> = .none
                if fallbackToPropagation,
                   state.endpoint.recall(destinationHash: message.destinationHash) != nil,
                   propagationStampCost(state) != nil {
                    if let limit = propagationTransferLimitBytes(state), message.packed.count > limit {
                        // Spec §6: the node would refuse it, so the copy is not attempted at all.
                        fallback = .send(.router(.propagatedCopyRefused(messageHash: message.hash,
                                                                        reason: .tooLargeForNode)))
                    } else {
                        state.pendingFallbacks[message.hash] = message
                        fallback = .send(.router(.markFallbackEligible(messageHash: message.hash)))
                    }
                }
                return .merge(issued, .concatenate(fallback, deliverySend(&state, message: message, method: .opportunistic)))

            case .syncFromPropagationNode:
                return .send(.router(.syncFromPropagationNode))

            case let .holdOutbound(held):
                return .send(.router(.setHold(held)))

            case let .stampSearchEnded(serial, outcome):
                // A job stopped by a cancel is no longer running; its result (if a send got through
                // before the cancel) is not this job's.
                guard let job = state.runningStampJob, job.serial == serial else { return .none }
                state.runningStampJob = nil
                let result: Effect<Action>
                switch (job.work, outcome) {
                case let (.delivery(method, _), .delivery(stamped)?):
                    result = .send(.router(.send(message: stamped, desiredMethod: method)))
                case let (.propagated, .propagated(stamped, packed)?):
                    result = .send(.router(.sendViaPropagation(message: stamped, propagationPacked: packed)))
                default:
                    result = failStampJob(&state, job)
                }
                // Orders only the hand-over ACTION before the next job's effects. That action's own
                // `.handedOver` report is an effect it returns, so it is delivered AFTER the next
                // message's `.stamping`. Hosts key phases by message hash, so the interleaving is harmless.
                return .concatenate(result, startNextStampJob(&state))

            case .cancelPropagationStamps:
                // The app's explicit reclaim: backgrounding, sign-out, or abandoning a send. Even an
                // accepted cost is minutes of hashing, so this must exist — `LXStamper.search` reads
                // `Task.isCancelled` each round, which is what makes the cancel stop the CPU and not
                // merely discard its result. Reference exposes the same lever as
                // `LXMRouter.cancel_outbound` → `LXStamper.cancel_work` (LXStamper.py:146-175).
                // ...and the copies those searches were for have failed, through the router's `fail`.
                // An explicit `.sendViaPropagation` still stamping is reported `deliveryFailed` here.
                // Queued propagated jobs are dropped with the running one, which starts the next job.
                let strandedSends = forgetPropagationStamping(&state)
                let abandoned = abandonPendingPropagatedCopies(state)
                let dropped = dropStampJobs(&state) { !$0.isDelivery }
                return .merge(dropped, abandoned, strandedSends)

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
                //
                // The failure goes through the router's `fail` (`.deliveryCopyAbandoned`), so a message
                // ends once: nothing is reported while its propagated copy is still out, or after a copy
                // succeeded. The router drops a fallback the message was waiting on (a later hand-off
                // would revive a failed message), and refuses a stamped copy that a search missed by
                // this cancel hands over late.
                //
                // Queued delivery jobs are in `inFlightDeliveryStamps` too, so they are failed the same
                // way; they leave the queue, the running delivery job is cancelled, and the next job (a
                // propagated one, if any) starts.
                let abandoned = state.inFlightDeliveryStamps
                state.inFlightDeliveryStamps = []
                for hash in abandoned { state.preparingPhases[hash] = nil }
                var effects: [Effect<Action>] = [dropStampJobs(&state) { $0.isDelivery }]
                for dest in state.waitingForPeerCost.keys {
                    effects.append(.cancel(id: CancelID.peerCostWait(dest)))
                }
                state.waitingForPeerCost = [:]
                for hash in abandoned {
                    state.pendingFallbacks[hash] = nil
                    effects.append(.send(.router(.deliveryCopyAbandoned(messageHash: hash))))
                }
                return .merge(effects)

            case let .cancelOutbound(hash):
                // Stop the stamp work for this message (reference `LXStamper.cancel_work`, keyed per
                // message) and hand the rest to the router, which owns every copy it was given. A
                // delivery copy still in its stamp search was never handed over, so if the router holds
                // nothing else for the message the cancel is reported here — once either way.
                // An explicit `.sendViaPropagation` still queued or stamping has a phase but is in neither
                // the delivery list nor the router; `dropStampJobs` below removes its job from the queue,
                // or cancels its running search by job serial (`CancelID.stampSearch`).
                // A queued job counts as searching: it leaves the queue without its search starting.
                let wasSearching = state.inFlightDeliveryStamps.contains(hash)
                    || state.preparingPhases[hash] == .stamping || state.preparingPhases[hash] == .queued
                state.inFlightDeliveryStamps.removeAll { $0 == hash }
                state.preparingPhases[hash] = nil
                state.pendingFallbacks[hash] = nil      // the router drops its eligibility below
                forgetUnstampedHandOver(&state, hash)
                let routerReports = state.router.hasOutboundState(for: hash)
                var effects: [Effect<Action>] = [
                    dropStampJobs(&state) { $0.message.hash == hash },
                    .send(.router(.cancelOutbound(messageHash: hash))),
                ]
                for (dest, waiting) in state.waitingForPeerCost where waiting.contains(where: { $0.message.hash == hash }) {
                    let remaining = waiting.filter { $0.message.hash != hash }
                    state.waitingForPeerCost[dest] = remaining.isEmpty ? nil : remaining
                    if remaining.isEmpty { effects.append(.cancel(id: CancelID.peerCostWait(dest))) }
                }
                // A message one of whose copies already succeeded has had its terminal outcome: the
                // stamp search is still stopped above, but silently (the router is silent too, F1).
                if wasSearching && !routerReports && !state.router.succeededMessages.contains(hash) {
                    effects.append(.send(.delegate(.deliveryCancelled(messageHash: hash))))
                }
                return .merge(effects)

            case let .peerCostWaitElapsed(dest, requestsLeft):
                guard state.waitingForPeerCost[dest] != nil else { return .none }
                // Held, nothing can answer a request. As in the router, no attempt is counted.
                if state.router.held { return peerCostWaitTimer(dest, requestsLeft: requestsLeft) }
                guard requestsLeft > 0 else {
                    return handOverWaitingSends(&state, destinationHash: dest, costMayArriveLater: true)
                }
                return .merge(.send(.endpoint(.requestPath(destinationHash: dest))),
                              peerCostWaitTimer(dest, requestsLeft: requestsLeft - 1))

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
                        // Only an entry addressed to our delivery destination is decrypted (reference
                        // `if destination_hash in self.delivery_destinations`, LXMRouter.py:2855); any other
                        // is still marked downloaded above. A decrypt can scan the whole ring, so this
                        // keeps foreign entries from costing one.
                        guard let delivery = state.deliveryDestinationHash,
                              LXMFPropagation.destinationHash(lxmfData: blob) == delivery else { continue }
                        // With our delivery destination's own ratchets enabled, they are tried first and
                        // enforcement applies, as reference decrypts through `delivery_destination.decrypt`.
                        let own = state.endpoint.transport.ownRatchets[delivery]
                        if let packed = LXMFPropagation.recoverPacked(lxmfData: blob, recipientIdentity: state.identity,
                                                                      ratchets: own?.ring,
                                                                      enforceRatchets: own?.enforce ?? false) {
                            // Our delivery hash: the router drops a message whose own destination is
                            // anyone else. Its transient id is still marked downloaded below (spec settled
                            // detail 5).
                            effects.append(.send(.router(.received(method: .propagated,
                                                                   destinationHash: delivery,
                                                                   data: packed))))
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
                // Synchronous, before the router sees anything for `h` (Transport already holds the
                // new path: its Scope ran first).
                //
                // Only for hashes the router can retry to: an `lxmf.delivery` destination (same
                // destination check as the app-data gate below) or our outbound propagation node.
                // `.pathLearned` fires for every announce from every app, and nothing prunes
                // `nextHopRetryWaits`, so refreshing unconditionally grew it with every slow-link
                // destination ever heard. Send-time refreshes remain the backstop.
                let isDeliveryDestination = state.endpoint.learned[h].map {
                    h == LXMessage.deliveryHash(identityHash: $0.identity.hash)
                } ?? false
                if isDeliveryDestination || h == state.router.outboundPropagationNode {
                    refreshNextHopRetryWait(&state, h)
                }
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
                // Copies handed over unstamped are taken back, synchronously, before the router hears
                // about the path. Once it has one, its next retry, or a link opened for its queue, would
                // send them as they are.
                let (withdraw, restamp) = restampUnsentHandOvers(&state, destinationHash: h)
                // After the cost above is stored, and after the router has heard about the path. The
                // searches enter `stampQueue` in the order of these calls (re-stamps first) and run one
                // at a time.
                return .concatenate(withdraw, .merge(effects),
                                    .merge(restamp, handOverWaitingSends(&state, destinationHash: h)))

            case let .router(.delegate(.messageDelivered(message, validated, method))):
                // Remember a ticket the sender gave us, first, as reference `lxmf_delivery` does
                // (LXMRouter.py:2176-2188, LXMF 1.3.0): before stamp validation and the ignore
                // check, so a ticket is kept even from a message that is then dropped. Only when the
                // signature validated: otherwise `sourceHash` is unauthenticated and anyone could
                // plant a ticket for any peer. `ticketField` has refused malformed entries.
                var ticketEffect: Effect<Action> = .none
                if validated, let entry = message.ticketField, date.now.timeIntervalSince1970 < entry.expires {
                    let ticket = Ticket(ticket: entry.ticket, expires: Date(timeIntervalSince1970: entry.expires))
                    if state.outboundTickets[message.sourceHash] != ticket {
                        state.outboundTickets[message.sourceHash] = ticket
                        // A send parked in the first-send cost wait for this peer now gets the
                        // ticket stamp at once instead of waiting out the timer. A stamp search
                        // already running for the peer is not restarted: it finishes with a valid stamp.
                        ticketEffect = .merge(
                            .send(.delegate(.ticketReceived(destinationHash: message.sourceHash,
                                                            ticket: ticket))),
                            handOverWaitingSends(&state, destinationHash: message.sourceHash))
                    }
                }

                // Ignore list, reference `LXMRouter.lxmf_delivery`'s `ignored_list` check: the
                // sender's lxmf.delivery hash is on the host's list, so the message goes nowhere.
                // Sits BEFORE stamp validation so a blocked sender never costs the ~60 ms
                // workblock, and after the router's `seen` dedup, so a resend of this message is
                // reported as a duplicate rather than reaching here again. The proof already went
                // out when the packet arrived; a propagated copy is already marked downloaded.
                // `sourceHash` is unauthenticated when `validated == false`; a forged hash only
                // loses the forger's own message. Spec 2026-10-15 §1.
                if state.ignoredDestinations.contains(message.sourceHash) {
                    return ticketEffect
                }

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
                // Tickets first: a stamp equal to `truncated_hash(ticket + message_id)` for an unexpired
                // ticket we issued TO THIS SENDER is valid, with no workblock (reference
                // `get_inbound_tickets` + `validate_stamp`, LXMRouter.py:2192-2193, Storage.py:290-301,
                // LXMessage.py:280-301). Tickets issued to other peers are not consulted.
                //
                // The RESULT is carried on the message (`stampValid`/`stampChecked`), mirroring
                // reference's assignment pair at LXMRouter.py:1865-1869 — not added as a delegate
                // parameter, because reference keeps it on the object too (LXMessage.py:157-158) and the
                // message already reaches the app via `.messageReceived`. A message arriving with
                // `stampChecked == false` was never validated (no cost configured), which is a different
                // statement from "validated and failed"; the app can tell those apart.
                var delivered = message
                if let cost = state.deliveryStampCost {
                    let now = date.now
                    let tickets = (state.inboundTickets[message.sourceHash] ?? [])
                        .filter { $0.expires > now }.map(\.ticket)
                    let stampValid = message.validateStamp(targetCost: cost, tickets: tickets)
                    delivered = message.withStampValidation(valid: stampValid)
                    if !stampValid {
                        // Enforcement off (default): deliver anyway, matching reference's
                        // "allow anyway, since stamp enforcement is disabled" branch (LXMRouter.py:1878-1879).
                        // Enforcement on: drop, matching `return False` (LXMRouter.py:1877).
                        if state.enforceDeliveryStamps {
                            return ticketEffect    // drop — app receives nothing
                        }
                        // fall through to deliver, flagged checked-and-invalid
                    }
                }
                return .concatenate(ticketEffect,
                                    .send(.delegate(.messageReceived(message: delivered, signatureValidated: validated,
                                                                     method: method))))

            case let .router(.delegate(.messageRejected(hash, reason))):
                // A forgery-check drop is the router's business: the app is told nothing, as for a
                // duplicate. A propagated copy is already marked downloaded. It is logged, so a
                // rejection is not invisible when debugging delivery. `Data.hexString` is internal
                // to ReTiCA, so the 8-byte prefix is formatted inline.
                let prefix = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
                Self.log.notice("rejected inbound message \(prefix, privacy: .public): \(String(describing: reason), privacy: .public)")
                return .none

            case let .router(.send(handedOn, _)):
                // The search for this message is over — it is the router's problem now, so it can no
                // longer be failed by `.cancelDeliveryStamps`. Reached on BOTH `deliverySend` paths:
                // the unstamped fast path (which never appended) and the completed search. Removing an
                // absent hash is a no-op, which is why no branch is needed here.
                state.inFlightDeliveryStamps.removeAll { $0 == handedOn.hash }
                // A fallback packs this copy, so it reuses the stamp rather than searching again.
                if handedOn.stamp != nil, state.pendingFallbacks[handedOn.hash] != nil {
                    state.pendingFallbacks[handedOn.hash] = handedOn
                }
                return reportHandedOver(&state, handedOn.hash)

            // The hand-over point of an explicit propagated send (`.sendViaPropagation`) and of a
            // fallback copy. Only a message that reported a phase earlier reports `.handedOver`.
            case let .router(.sendViaPropagation(handedOn, _)):
                return reportHandedOver(&state, handedOn.hash)

            // The message is over, so a fallback it was waiting on is not needed (a rejected
            // delivery copy ends the message without a hand-off).
            case let .router(.delegate(.deliveryFailed(hash))):
                clearProgress(&state, hash)
                state.pendingFallbacks[hash] = nil
                state.preparingPhases[hash] = nil
                forgetUnstampedHandOver(&state, hash)
                return .send(.delegate(.deliveryFailed(messageHash: hash)))

            case let .router(.delegate(.deliveryRejected(hash))):
                clearProgress(&state, hash)
                state.pendingFallbacks[hash] = nil
                state.preparingPhases[hash] = nil
                forgetUnstampedHandOver(&state, hash)
                return .send(.delegate(.deliveryRejected(messageHash: hash)))

            case let .router(.delegate(.deliveryCancelled(hash))):
                clearProgress(&state, hash)
                state.pendingFallbacks[hash] = nil
                state.preparingPhases[hash] = nil
                forgetUnstampedHandOver(&state, hash)
                return .send(.delegate(.deliveryCancelled(messageHash: hash)))

            case let .router(.delegate(.deliveryConfirmed(hash))):
                // The propagated copy is not needed: drop one not yet started, and stop one still in
                // its stamp search (the router has already dropped its pending marker).
                state.pendingFallbacks[hash] = nil
                state.preparingPhases[hash] = nil
                forgetUnstampedHandOver(&state, hash)
                let done = finishProgress(&state, .delivery(hash))
                // A delivered ticket starts the interval in which no new one is sent to that peer
                // (reference `process_outbound`, LXMRouter.py:3060-3067).
                var ticketDelivered: Effect<Action> = .none
                state.ticketMessagesAccepted.remove(hash)
                if let dest = state.ticketCarryingMessages.removeValue(forKey: hash) {
                    let at = date.now
                    state.lastTicketDeliveries[dest] = at
                    ticketDelivered = .send(.delegate(.ticketDelivered(destinationHash: dest, at: at)))
                }
                let dropped = dropStampJobs(&state) { !$0.isDelivery && $0.message.hash == hash }
                return .merge(dropped, done, ticketDelivered,
                              .send(.delegate(.deliveryConfirmed(messageHash: hash))))

            case let .router(.delegate(.propagationFallbackDue(hash))):
                // The delivery copy stalled: the router already counts the propagated copy as
                // pending (spec A2). With no message left to pack, that copy fails there instead.
                guard let message = state.pendingFallbacks.removeValue(forKey: hash) else {
                    return .send(.router(.propagatedCopyFailed(messageHash: hash)))
                }
                return startPropagatedCopy(&state, message: message)

            case let .router(.delegate(.propagationAccepted(hash))):
                if state.ticketCarryingMessages[hash] != nil { state.ticketMessagesAccepted.insert(hash) }
                let done = finishProgress(&state, .propagated(hash))
                return .merge(done, .send(.delegate(.propagationAccepted(messageHash: hash))))

            case let .router(.delegate(.propagationRefused(hash, reason))):
                state.transferProgress[.propagated(hash)] = nil
                return .send(.delegate(.propagationRefused(messageHash: hash, reason: reason)))

            case let .router(.delegate(.cancelResource(linkID))):
                // Our transfer's hash on that link names it to the session. Unknown (the router
                // started the copy but its transfer never reported): nothing on the wire to cancel.
                guard let hash = state.outboundTransfers.removeValue(forKey: linkID) else { return .none }
                return .send(.endpoint(.cancelResource(linkID: linkID, hash: hash)))

            // --- Direct-over-link: router delegates → endpoint actions ---
            case let .router(.delegate(.requestLink(dest))):
                return .send(.endpoint(.openLink(destinationHash: dest)))

            case let .router(.delegate(.requestPath(dest))):
                return .send(.endpoint(.requestPath(destinationHash: dest)))

            case let .router(.delegate(.sendDirect(linkID, data, asResource))):
                guard asResource else { return .send(.endpoint(.sendOverLink(linkID: linkID, data: data))) }
                // A new transfer starts on this link; its first sender progress names its hash.
                let started = startResourceTransfer(&state, linkID)
                return .merge(started, .send(.endpoint(.sendResourceOverLink(linkID: linkID, data: data))))

            case let .router(.delegate(.sendPropagated(linkID, propagationPacked))):
                let started = startResourceTransfer(&state, linkID)
                return .merge(started, .send(.endpoint(.sendResourceOverLink(linkID: linkID, data: propagationPacked))))

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

            case let .router(.delegate(.abandonLink(dest))):
                // Only a link still waiting for its link-request key is stopped: nothing has left this
                // node for it, so dropping it is silent. Its search is cancelled and the router told the
                // link is gone (it re-establishes if work arrived meanwhile). A link already minted is
                // left to finish; the router, still `.establishing`, takes its outcome as usual.
                guard state.endpoint.linkPlane.stampingLinks.contains(where: { $0.destinationHash == dest })
                else { return .none }
                return .concatenate(.send(.endpoint(.linkPlane(.abandonStampSearches(destinationHash: dest)))),
                                    .send(.router(.linkClosed(destinationHash: dest))))

            // --- Direct-over-link: endpoint delegates → router actions ---
            case let .endpoint(.delegate(.linkEstablished(linkID, dest))):
                state.directLinks[dest] = linkID
                state.linkDestinations[linkID] = dest
                return .send(.router(.linkEstablished(destinationHash: dest, linkID: linkID)))

            case let .endpoint(.delegate(.linkClosed(linkID, _))):
                state.linkDestinations[linkID] = nil
                state.outboundTransfers[linkID] = nil
                state.inboundProgress[linkID] = nil
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
                case .stampFailure:
                    // No LINKREQUEST left this node: the destination announced a link cost we could
                    // not meet (above `LinkPlane.maxLinkStampCost`, or the search timed out). The path
                    // is not in question, so do not request one. Retry the link like `.handshakeRejected`:
                    // each search is an independent random trial, so a fresh one may succeed where the
                    // last timed out, and `establishAttempts` bounds the retries, each costing at most
                    // `NetworkStamp.linkStampTimeout` of search. Reference also searches afresh: LXMF 1.3.0
                    // opens a new link per delivery attempt (LXMRouter.py:3190-3225), though it waits
                    // `DELIVERY_RETRY_WAIT` between attempts where this retries at once.
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
                // Our delivery hash, whichever link it came on: the router drops a message
                // addressed to anyone else.
                let ours = state.deliveryDestinationHash ?? Data()
                if isDeliveryLink {
                    return .merge(
                        .send(.endpoint(.provePacketOverLink(linkID: linkID, packetHash: packetHash))),
                        .send(.router(.received(method: .direct, destinationHash: ours, data: data))))
                }
                return .send(.router(.received(method: .direct, destinationHash: ours, data: data)))

            case let .endpoint(.delegate(.resourceReceived(linkID, data))):
                state.inboundProgress[linkID] = nil
                guard !isServedPropagationLink(state, linkID) else { return .none }
                return .send(.router(.received(method: .direct, destinationHash: state.deliveryDestinationHash ?? Data(),
                                               data: data)))

            case let .endpoint(.delegate(.resourceConcluded(linkID, hash))):
                // Only OUR transfer on that link resolves the copy (Review Focus 1).
                guard state.outboundTransfers[linkID] == hash else { return .none }
                state.outboundTransfers[linkID] = nil
                return .send(.router(.resourceDeliveredOnLink(linkID: linkID)))

            case let .endpoint(.delegate(.resourceFailed(linkID, hash, rejected))):
                guard state.outboundTransfers[linkID] == hash else {
                    state.inboundProgress[linkID] = nil          // an inbound transfer failed
                    return .none
                }
                state.outboundTransfers[linkID] = nil
                return .send(.router(.resourceFailedOnLink(linkID: linkID, rejected: rejected)))

            case let .endpoint(.delegate(.resourceProgress(linkID, hash, role, done, total, segment, segments))):
                let activity = Effect<Action>.send(.router(.linkActivity(linkID: linkID)))
                switch role {
                case .sender:
                    guard let key = state.router.linkResourceInFlight[linkID] else { return .none }
                    if state.outboundTransfers[linkID] == nil { state.outboundTransfers[linkID] = hash }
                    guard state.outboundTransfers[linkID] == hash else { return .none }
                    let fraction = LXMFNode.outboundFraction(bytesDone: done, bytesTotal: total,
                                                             segment: segment, segments: segments)
                    return .merge(reportProgress(&state, key, fraction), activity)
                case .receiver:
                    guard !isServedPropagationLink(state, linkID) else { return activity }
                    let fraction = LXMFNode.transferFraction(bytesDone: done, bytesTotal: total,
                                                             segment: segment, segments: segments)
                    if let last = state.inboundProgress[linkID], fraction <= last { return activity }
                    state.inboundProgress[linkID] = fraction
                    let terminus = state.linkDestinations[linkID]
                    let source = terminus == state.deliveryDestinationHash
                        || terminus == state.propagationDestinationHash ? nil : terminus
                    return .merge(.send(.delegate(.inboundTransferProgress(sourceHash: source, linkID: linkID,
                                                                           fraction: fraction))),
                                  activity)
                }

            // Every terminal outcome reaches the host as one of these, from whichever branch decided
            // it. Each one sweeps every ticket-carrying message that can no longer be confirmed,
            // not only its own: a delivery copy that ends after its propagated copy was accepted
            // ends silently (the router reports no second outcome), so its message is collected
            // by the next sweep.
            case .delegate(.deliveryFailed), .delegate(.deliveryRejected), .delegate(.deliveryCancelled),
                 .delegate(.deliveryConfirmed), .delegate(.propagationAccepted):
                sweepTicketCarryingMessages(&state)
                return .none

            case .endpoint, .router, .delegate:
                return .none
            }
        }
    }

    /// The delivery destination's announce app data. Its display name is cut to the smaller budget
    /// when the destination announces its own ratchet (`Transport.State.ownRatchets`, read when the
    /// action is handled), so the announce still fits.
    private func deliveryAnnounceAppData(_ state: State) -> Data {
        let ratchet = state.deliveryDestinationHash.map { state.endpoint.transport.ownRatchets[$0] != nil } ?? false
        return LXMFAnnounceData.pack(displayName: state.displayName, stampCost: state.deliveryStampCost,
                                     ratchet: ratchet)
    }

    /// The `FIELD_TICKET` entry for a message this node builds to `destinationHash`, or none when
    /// issuing is off or the rule says not to include one. See `State.ticketFieldToIssue`.
    private func ticketFields(_ state: State, _ destinationHash: Data) -> [MsgPackValue.IntPair] {
        guard state.issueTickets else { return [] }
        return state.ticketFieldToIssue(destinationHash: destinationHash, now: date.now,
                                        newTicket: randomBytes(LXMessage.ticketLength))
            .map { [$0] } ?? []
    }

    /// Forget every ticket-carrying message that can no longer be confirmed delivered: the router
    /// holds no copy of it, the node is not preparing, stamping or holding it, and no delivery
    /// success for it is still on its way. A message the router counts as succeeded is kept until
    /// the node has handled a success for it (`ticketMessagesAccepted`, or the confirmation itself,
    /// which removes the entry), so a `deliveryConfirmed` queued behind this sweep still finds it.
    ///
    /// Two gaps, both unproven to occur, both costing only a missed `lastTicketDeliveries` update (a
    /// ticket may then go to that peer again within a day):
    ///  - A send recorded here reaches the router through a queued `.router(.send)`. Until it is
    ///    processed nothing holds the message, so a sweep processed first would drop it. In every
    ///    send branch the hand-over is queued before anything that reports a terminal outcome.
    ///  - A message whose propagated copy was already accepted, whose delivery copy then succeeds,
    ///    is dropped by a sweep processed between that success and its `deliveryConfirmed`.
    private func sweepTicketCarryingMessages(_ state: inout State) {
        for hash in Array(state.ticketCarryingMessages.keys) {
            let stillOut = state.router.hasOutboundState(for: hash)
                || state.preparingPhases[hash] != nil
                || state.inFlightDeliveryStamps.contains(hash)
                || state.pendingFallbacks[hash] != nil
                || state.waitingForPeerCost.values.contains { $0.contains { $0.message.hash == hash } }
            let successUnhandled = state.router.succeededMessages.contains(hash)
                && !state.ticketMessagesAccepted.contains(hash)
            guard !stillOut, !successUnhandled else { continue }
            state.ticketCarryingMessages[hash] = nil
            state.ticketMessagesAccepted.remove(hash)
        }
    }

    /// Record the ticket `message` carries to its recipient as one we issued: remember the message
    /// so its delivery confirmation can be counted, and add a ticket not yet held to
    /// `inboundTickets`, reported as `.ticketIssued`. Only for a message from our own delivery
    /// destination with a well-formed, unexpired `FIELD_TICKET`; anything else is left alone.
    private func recordIssuedTicket(_ state: inout State, _ message: LXMessage) -> Effect<Action> {
        guard message.sourceHash == LXMessage.deliveryHash(identityHash: state.identity.hash),
              let entry = message.ticketField,
              entry.expires > date.now.timeIntervalSince1970
        else { return .none }
        let dest = message.destinationHash
        sweepTicketCarryingMessages(&state)
        state.ticketCarryingMessages[message.hash] = dest
        if state.inboundTickets[dest]?.contains(where: { $0.ticket == entry.ticket }) == true { return .none }
        let ticket = Ticket(ticket: entry.ticket, expires: Date(timeIntervalSince1970: entry.expires))
        state.inboundTickets[dest, default: []].append(ticket)
        return .send(.delegate(.ticketIssued(destinationHash: dest, ticket: ticket)))
    }

    /// The propagation stamp cost to work at, or **nil meaning "do not send via this node"**.
    ///
    /// `ann.targetStampCost` comes from the propagation node's announce app-data — element [7][0]
    /// when present, else [5][0], fractional — which is unauthenticated: any peer can advertise 64,
    /// and the search is exponential in the cost, so 64 is ~2^64 hash rounds over a 256 KB workblock.
    ///
    /// Reference (`get_outbound_propagation_cost`, LXMF 1.3.0 LXMRouter.py:494-519) clamps the value
    /// to `max(0, min(cost, STAMP_COST_CAP))`, and by Python's `min`/`max` argument order a NaN comes
    /// out of that as 0; so do negatives and -infinity. We clamp the same way, then refuse anything
    /// above `LXMFPropagation.maxPropagationStampCost` (a deliberate divergence: reference has no
    /// ceiling; see that constant for why refusing beats clamping). So a NaN, negative or -infinite
    /// cost gives 0 (a stamp at cost 0, which every stamp meets), as reference's does, and +infinity
    /// gives 100, which we refuse.
    private func propagationStampCost(_ state: State) -> Double? {
        guard let pn = state.router.outboundPropagationNode,
              let appData = state.endpoint.learned[pn]?.appData,
              let ann = PNAnnounce.parse(appData)
        else { return LXMFPropagation.defaultPropagationStampCost }
        let raw = ann.targetStampCost
        let cost = raw.isNaN ? 0 : min(max(raw, 0), Double(NetworkStamp.stampCostCap))
        guard cost <= LXMFPropagation.maxPropagationStampCost else { return nil }
        return cost
    }

    /// The configured propagation node's per-transfer limit in bytes, or nil when unknown.
    ///
    /// Reference expresses these limits in KB and compares byte sizes against `limit * 1000`
    /// (LXMRouter.py:1528, `client_transfer_limit = float(data[2])*1000`). A limit of 0 or less is
    /// treated as UNKNOWN rather than "nothing fits": no working node announces it (it would refuse
    /// every message), while test fixtures and minimal announces do, and the spec's rule for an
    /// unknown limit is to attempt the copy as before. The product is overflow-checked because the
    /// field is unauthenticated wire input.
    private func propagationTransferLimitBytes(_ state: State) -> Int? {
        guard let pn = state.router.outboundPropagationNode,
              let appData = state.endpoint.learned[pn]?.appData,
              let ann = PNAnnounce.parse(appData), ann.perTransferLimit > 0
        else { return nil }
        let (bytes, overflow) = ann.perTransferLimit.multipliedReportingOverflow(by: 1000)
        return overflow ? nil : bytes
    }

    /// The copies whose propagation stamp searches `.cancelPropagationStamps` or
    /// `.setPropagationNode` abandon have failed and must be reported so — through the router's
    /// `fail`, so a message whose delivery copy is still pending is not reported failed yet.
    /// (Ruling P10: this effect is built once and shared by both call sites, not duplicated.)
    /// Messages whose delivery copy is still in its delivery-stamp search are passed along: the
    /// router cannot see that copy, and must not fail the message while it can still succeed.
    private func abandonPendingPropagatedCopies(_ state: State) -> Effect<Action> {
        guard !state.router.pendingPropagatedCopies.isEmpty else { return .none }
        return .send(.router(.abandonPendingPropagatedCopies(stillSearching: Set(state.inFlightDeliveryStamps))))
    }

    /// Start the propagated copy the router handed off with `propagationFallbackDue`: search its
    /// propagation stamp, pack it, and give it to the router. The router already counts it as
    /// pending, so a copy that can no longer be packed (the recipient's identity is unknown, or the node
    /// now advertises a cost we refuse) is failed through the router's `fail` — the message still
    /// gets its terminal outcome.
    ///
    /// **The copy carries the recipient's delivery stamp**, because a recipient enforcing stamps checks
    /// them on propagated messages too (`lxmf_propagation`, LXMRouter.py:2826-2861, LXMF 1.3.0). The
    /// delivery copy normally has one by now: a fallback only comes due after that copy reached the
    /// router, and `.router(.send)` swapped the stamped message into `pendingFallbacks`. The search here
    /// is for a cost learned since then. Retries stay stable because `ResendInfo.propagated` re-sends
    /// the packed bytes and never packs again.
    private func startPropagatedCopy(_ state: inout State, message: LXMessage) -> Effect<Action> {
        guard let recipient = state.endpoint.recall(destinationHash: message.destinationHash),
              propagationStampCost(state) != nil      // read again when the job starts
        else { return .send(.router(.propagatedCopyFailed(messageHash: message.hash))) }
        refreshOutboundPropagationNodeRetryWait(&state)
        let ts = date.now.timeIntervalSince1970
        // A ticket learned since the delivery copy left stamps the copy without a search.
        let message = ticketStamped(state, message) ?? message
        let deliveryCost = message.stamp == nil ? deliveryStampCost(state, destinationHash: message.destinationHash) : nil
        // A later job than any already queued: it waits behind them (`stampQueue`).
        return enqueueStampJob(&state, message: message,
                               work: .propagated(explicit: false, deliveryCost: deliveryCost, recipient: recipient,
                                                 timestamp: ts))
    }

    /// Copy Transport's CURRENT next hop for `destinationHash` into the router's retry-wait table
    /// (Contract 4: LXMF retry wait = max(10, 4·MTU·8/b)). A wait equal to the default is REMOVED
    /// rather than stored, so on TCP/BLE the router's state never changes.
    ///
    /// Called where a path can appear or change (`.pathLearned`) and when a send is ACCEPTED
    /// (`deliverySend`, and the two propagated hand-overs via
    /// `refreshOutboundPropagationNodeRetryWait`), i.e. before any stamp search. The second call
    /// covers what the first cannot see: a path restored by `rehydrateLearnedDestinations` (no
    /// `pathLearned`), an interface re-registered under the same id with a new bitrate, and a next
    /// hop that has disconnected (falls back to the default). Accepted gap (spec), same class: a
    /// change DURING a retry run, or during an async stamp search (the router receives the copy
    /// only after it), is seen only at the next announce or send.
    private func refreshNextHopRetryWait(_ state: inout State, _ destinationHash: Data) {
        let bitrate = state.endpoint.transport.nextHopInterfaceProfile(destinationHash)?.bitrate
        let wait = LXMFDelivery.retryWait(nextHopBitrate: bitrate)
        let stored: Int? = wait == LXMFDelivery.retryWaitSeconds ? nil : wait
        if state.router.nextHopRetryWaits[destinationHash] != stored {
            state.router.nextHopRetryWaits[destinationHash] = stored
        }
    }

    /// Propagated retries are keyed on the PROPAGATION NODE's hash (`ResendInfo.propagated`), so a
    /// propagated send refreshes the wait for that hash, not the recipient's. No node, no-op.
    private func refreshOutboundPropagationNodeRetryWait(_ state: inout State) {
        guard let pn = state.router.outboundPropagationNode else { return }
        refreshNextHopRetryWait(&state, pn)
    }

    /// The delivery stamp cost to apply when sending to `destinationHash`, or **nil meaning
    /// "no stamp"** (no cost is known, the cost is outside reference's gate, or it exceeds the
    /// ceiling). Fractional: a peer's 8.5 is searched at 8.5.
    ///
    /// `peer.stampCost` comes from the `lxmf.delivery` announce app-data, which is unauthenticated:
    /// any reachable peer can advertise any value. The search is exponential — 64 is ~2^64 rounds
    /// over a 768 KB (3000-round) workblock — so the ceiling is mandatory. See
    /// `LXMFNode.maxDeliveryStampCost` for the ceiling and why refusing beats clamping.
    ///
    /// The cost must also pass `LXStamper.costInRange` (`0 < cost < 100`; false for NaN and
    /// infinities). `LXMFAnnounceData.parse` already applies it, but `learnedPeers` is also written
    /// by `.rehydrateLearnedPeers` from host storage, so it is checked again here, where the search
    /// starts. A cost of 0 means "no stamp required", matching reference's emit gate at
    /// `get_announce_app_data` (LXMRouter.py:1172-1174, LXMF 1.3.0): a conforming peer never emits 0.
    /// A negative cost gets no stamp, where reference's `generate_stamp` raises (RNS/Stamps.py:255).
    private func deliveryStampCost(_ state: State, destinationHash: Data) -> Double? {
        guard let peer = state.learnedPeers[destinationHash],
              let cost = peer.stampCost,
              LXStamper.costInRange(cost),
              cost <= LXMFNode.maxDeliveryStampCost
        else { return nil }
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
    /// The cancellation is reported instead by `.cancelDeliveryStamps`, which fails every hash in
    /// `State.inFlightDeliveryStamps` (appended here) through the router's `fail`.
    ///
    /// **A send with no path and no learned cost waits.** The cost arrives in the announce that
    /// brings the path, so at this point "no cost" means "not known yet", not "none required".
    /// Sending now would be unstamped, and a peer enforcing stamps proves the packet and then drops
    /// it (LXMRouter.py:2263 and 2204, LXMF 1.3.0), so we would also report it delivered. MeshChatX
    /// enforces by default. Deliberate divergence: reference reads the cost once in `handle_outbound`
    /// (LXMRouter.py:2080-2084) and has this gap. A path we already hold means we did hear the
    /// announce, so an absent cost really is absent and nothing waits.
    private func deliverySend(_ state: inout State, message: LXMessage, method: LXMFRouter.DeliveryMethod,
                              waitForUnknownCost: Bool = true) -> Effect<Action> {
        refreshNextHopRetryWait(&state, message.destinationHash)
        let dest = message.destinationHash
        // A ticket from the peer replaces the stamp: no cost wait and no search, so nothing to report
        // as preparing. Before the wait, because the wait exists only to learn a cost (reference
        // `handle_outbound` applies the ticket and un-defers the stamp, LXMRouter.py:2089-2094).
        if let ticketed = ticketStamped(state, message) {
            return .send(.router(.send(message: ticketed, desiredMethod: method)))
        }
        if waitForUnknownCost, message.stamp == nil, state.learnedPeers[dest] == nil, state.endpoint.learned[dest] == nil {
            return waitForPeerCost(&state, message: message, method: method)
        }
        guard message.stamp == nil,
              let cost = deliveryStampCost(state, destinationHash: dest)
        else { return .send(.router(.send(message: message, desiredMethod: method))) }
        if !state.inFlightDeliveryStamps.contains(message.hash) {
            state.inFlightDeliveryStamps.append(message.hash)
        }
        // One search at a time, oldest first: it waits in `stampQueue` behind any running search.
        return enqueueStampJob(&state, message: message, work: .delivery(method: method, cost: cost))
    }

    /// Put a stamp job at the back of `stampQueue`: it starts now if no search is running (reporting
    /// `.stamping`), else it waits (reporting `.queued`). Fallback copies report neither.
    ///
    /// A message that already has a job of the same kind (delivery, or propagated) running or queued
    /// is not queued again: the existing job keeps its place, as reference's
    /// `pending_deferred_stamps[message_id] = lxm` does (LXMRouter.py:2123). A delivery job and a
    /// propagated job for one message are different work (a re-stamp and a fallback copy) and both stay.
    private func enqueueStampJob(_ state: inout State, message: LXMessage, work: StampJob.Work) -> Effect<Action> {
        let job = StampJob(serial: state.nextStampJobSerial, message: message, work: work)
        let sameWork = { (other: StampJob) in other.message.hash == message.hash && other.isDelivery == job.isDelivery }
        if state.runningStampJob.map(sameWork) == true || state.stampQueue.contains(where: sameWork) { return .none }
        state.nextStampJobSerial += 1
        guard state.runningStampJob != nil else { return startStampJob(&state, job) }
        state.stampQueue.append(job)
        return job.reportsPhases ? reportPhase(&state, message.hash, .queued) : .none
    }

    /// Start the oldest queued job, if none is running.
    private func startNextStampJob(_ state: inout State) -> Effect<Action> {
        guard state.runningStampJob == nil, !state.stampQueue.isEmpty else { return .none }
        return startStampJob(&state, state.stampQueue.removeFirst())
    }

    /// Run `job`'s search. Its result comes back as `.stampSearchEnded`; a cancelled search sends
    /// nothing (TCA drops sends from a cancelled effect), so whoever cancels it starts the next job.
    ///
    /// A propagated job reads the node's propagation stamp cost here, when it starts, as reference
    /// does (`get_outbound_propagation_cost` in `process_deferred_stamps`, LXMRouter.py:3003-3008).
    /// When the node now advertises a cost we refuse (or above our ceiling), the job fails without
    /// searching (reference fails the message when the cost is unknown) and the next job starts.
    private func startStampJob(_ state: inout State, _ job: StampJob) -> Effect<Action> {
        let propagationCost: Double
        if case .propagated = job.work {
            guard let cost = propagationStampCost(state) else {
                return .merge(failStampJob(&state, job), startNextStampJob(&state))
            }
            propagationCost = cost
        } else {
            propagationCost = 0     // unused by a delivery job
        }
        state.runningStampJob = job
        let preparing = job.reportsPhases ? reportPhase(&state, job.message.hash, .stamping) : .none
        let message = job.message, serial = job.serial
        let search: Effect<Action>
        switch job.work {
        case let .delivery(_, cost):
            search = .run { [stampGenerator] send in
                let stamp = await stampGenerator.deliveryStamp(message.hash, cost)
                await send(.stampSearchEnded(serial: serial, outcome: stamp.map { .delivery(message.withStamp($0)) }))
            }
        case let .propagated(_, deliveryCost, recipient, timestamp):
            // The recipient's ratchet as of now, as reference reads it when it packs after the stamp.
            let ratchet = state.endpoint.transport.recallRatchet(destinationHash: message.destinationHash,
                                                                 now: transportDate.now)
            search = .run { [stampGenerator] send in
                var stamped = message
                if let deliveryCost {
                    guard let stamp = await stampGenerator.deliveryStamp(message.hash, deliveryCost) else {
                        await send(.stampSearchEnded(serial: serial, outcome: nil))
                        return
                    }
                    stamped = message.withStamp(stamp)
                }
                let packed = await stampGenerator.propagationPack(stamped, recipient, ratchet, timestamp, propagationCost)
                await send(.stampSearchEnded(serial: serial,
                                             outcome: packed.map { .propagated(stamped, propagationPacked: $0) }))
            }
        }
        return .merge(preparing, search.cancellable(id: CancelID.stampSearch(serial)))
    }

    /// Remove the jobs `matching` from `stampQueue`, and stop the running job if it matches and start
    /// the next. Reports nothing: each caller reports the messages it stops as it did before the queue.
    /// Call it from the reducer branch that stops the jobs: the `.cancel(id:)` it builds cancels when
    /// it is constructed (86ee622).
    private func dropStampJobs(_ state: inout State, where matching: (StampJob) -> Bool) -> Effect<Action> {
        state.stampQueue.removeAll(where: matching)
        guard let running = state.runningStampJob, matching(running) else { return .none }
        state.runningStampJob = nil
        return .merge(.cancel(id: CancelID.stampSearch(running.serial)), startNextStampJob(&state))
    }

    /// A search ended without a stamp and was not cancelled, or a propagated job found no acceptable
    /// propagation cost when it started: the copy it was for has failed, reported
    /// as reference's `fail_message` would (LXMRouter.py:2996-2999, 3004-3008) for this job's message — not, as
    /// reference's cancel branches do, for whichever message is last in its queue (LXMRouter.py:2965).
    /// A delivery copy fails as a cancelled one does (through the router's `fail`), an explicit
    /// propagated send is reported `deliveryFailed`, and a fallback copy fails in the router.
    private func failStampJob(_ state: inout State, _ job: StampJob) -> Effect<Action> {
        let hash = job.message.hash
        switch job.work {
        case .delivery:
            state.inFlightDeliveryStamps.removeAll { $0 == hash }
            state.preparingPhases[hash] = nil
            state.pendingFallbacks[hash] = nil
            return .send(.router(.deliveryCopyAbandoned(messageHash: hash)))
        case .propagated(explicit: true, _, _, _):
            state.preparingPhases[hash] = nil
            return .send(.delegate(.deliveryFailed(messageHash: hash)))
        case .propagated(explicit: false, _, _, _):
            return .send(.router(.propagatedCopyFailed(messageHash: hash)))
        }
    }

    /// `message` stamped with the ticket its recipient gave us, or nil when it already has a stamp or
    /// we hold no unexpired ticket for that recipient. Reference uses a ticket while `expires > now`
    /// (`Storage.py:240-251`) and only when it is `TICKET_LENGTH` bytes (`LXMessage.py:306`). An
    /// existing stamp is kept, as everywhere on the send path (see `deliverySend`).
    private func ticketStamped(_ state: State, _ message: LXMessage) -> LXMessage? {
        guard message.stamp == nil,
              let ticket = state.outboundTickets[message.destinationHash],
              ticket.expires > date.now,
              ticket.ticket.count == LXMessage.ticketLength
        else { return nil }
        return message.withStamp(LXMessage.ticketStamp(ticket: ticket.ticket, messageHash: message.hash))
    }

    /// `deliveryPreparing` for `phase`, unless the message already reported it (once per transition).
    private func reportPhase(_ state: inout State, _ hash: Data, _ phase: PreparingPhase) -> Effect<Action> {
        guard state.preparingPhases[hash] != phase else { return .none }
        state.preparingPhases[hash] = phase
        return .send(.delegate(.deliveryPreparing(messageHash: hash, phase: phase)))
    }

    /// `.handedOver`, only for a message that reported `.waitingForPeer`, `.queued` or `.stamping`.
    private func reportHandedOver(_ state: inout State, _ hash: Data) -> Effect<Action> {
        guard state.preparingPhases.removeValue(forKey: hash) != nil else { return .none }
        return .send(.delegate(.deliveryPreparing(messageHash: hash, phase: .handedOver)))
    }

    /// The propagation stamp work was cancelled or its node changed: a message that reported
    /// `.queued` or `.stamping` for an explicit propagated send, and so is not in `inFlightDeliveryStamps`, will
    /// not reach the router, so its phase is forgotten and it is reported `deliveryFailed`, once.
    /// The router has no record of such a message before its hand-over (it is in neither
    /// `pendingPropagatedCopies` nor `inFlightDeliveryStamps`), so nothing else can report it.
    private func forgetPropagationStamping(_ state: inout State) -> Effect<Action> {
        let searching = Set(state.inFlightDeliveryStamps)
        let stranded = state.preparingPhases.keys.filter { !searching.contains($0) }
            .sorted { $0.lexicographicallyPrecedes($1) }
        for hash in stranded { state.preparingPhases[hash] = nil }
        return .merge(stranded.map { .send(.delegate(.deliveryFailed(messageHash: $0))) })
    }

    /// Park a first send and, for the first one to this destination, start asking for a path.
    private func waitForPeerCost(_ state: inout State, message: LXMessage,
                                 method: LXMFRouter.DeliveryMethod) -> Effect<Action> {
        let dest = message.destinationHash
        if !state.inFlightDeliveryStamps.contains(message.hash) {
            state.inFlightDeliveryStamps.append(message.hash)
        }
        let alreadyAsking = state.waitingForPeerCost[dest] != nil
        if !(state.waitingForPeerCost[dest]?.contains { $0.message.hash == message.hash } ?? false) {
            state.waitingForPeerCost[dest, default: []].append(WaitingSend(message: message, method: method))
        }
        let preparing = reportPhase(&state, message.hash, .waitingForPeer)
        guard !alreadyAsking else { return preparing }
        return .merge(preparing, .send(.endpoint(.requestPath(destinationHash: dest))),
                      peerCostWaitTimer(dest, requestsLeft: LXMFNode.peerCostPathRequests - 1))
    }

    private func peerCostWaitTimer(_ dest: Data, requestsLeft: Int) -> Effect<Action> {
        .run { [clock] send in
            try await clock.sleep(for: .seconds(LXMFDelivery.pathRequestWaitSeconds))
            await send(.peerCostWaitElapsed(destinationHash: dest, requestsLeft: requestsLeft))
        }
        .cancellable(id: CancelID.peerCostWait(dest), cancelInFlight: true)
    }

    /// Send everything waiting on `dest`, stamped if a cost is now known. It does not wait again.
    ///
    /// `costMayArriveLater`: the wait ran out with no announce, so a send that goes over unstamped
    /// is remembered in `unstampedHandOvers`, to be re-stamped if the announce comes after all.
    private func handOverWaitingSends(_ state: inout State, destinationHash dest: Data,
                                      costMayArriveLater: Bool = false) -> Effect<Action> {
        guard let waiting = state.waitingForPeerCost.removeValue(forKey: dest) else { return .none }
        // `.cancel(id:)` cancels when constructed (86ee622); the guard above keeps this to a real hand-over.
        var effects: [Effect<Action>] = [.cancel(id: CancelID.peerCostWait(dest))]
        for send in waiting {
            if costMayArriveLater, send.message.stamp == nil, state.learnedPeers[dest] == nil,
               ticketStamped(state, send.message) == nil {     // a ticketed copy is stamped already
                state.unstampedHandOvers[dest, default: []].append(send)
            }
            effects.append(deliverySend(&state, message: send.message, method: send.method, waitForUnknownCost: false))
        }
        return .merge(effects)
    }

    /// At the first announce from `dest` since its sends were handed over unstamped
    /// (`unstampedHandOvers`): if it brought a cost, take back each copy the router has not sent and
    /// stamp it. Returns the take-backs, which must reach the router before it learns the path, and the
    /// stamp searches, whose results reach it as ordinary `.router(.send)`s.
    ///
    /// Why taking back is safe:
    ///  • Nothing has gone out. The sends were handed over while Transport had not learned `dest`,
    ///    which drops every send to it, and this is the first announce since (the entry is removed
    ///    here whatever the announce says). The router confirms each copy is still unsent
    ///    (`holdsUnsentDeliveryCopy`) and gives it back silently.
    ///  • One outcome. The copy is now a stamp search here, in `inFlightDeliveryStamps`, so
    ///    `.cancelOutbound` and `.cancelDeliveryStamps` reach it as they reach any search, and the
    ///    router counts it as outstanding (`withdrawnDeliveryCopies`) so a propagated copy failing
    ///    meanwhile does not end the message. Its retry budget restarts when it comes back.
    ///  • A fallback is untouched: the router keeps the message's eligibility, and `.router(.send)`
    ///    swaps the stamped copy into `pendingFallbacks`.
    private func restampUnsentHandOvers(_ state: inout State,
                                        destinationHash dest: Data) -> (withdraw: Effect<Action>, restamp: Effect<Action>) {
        guard let handed = state.unstampedHandOvers.removeValue(forKey: dest),
              deliveryStampCost(state, destinationHash: dest) != nil
        else { return (.none, .none) }
        var withdraw: [Effect<Action>] = []
        var restamp: [Effect<Action>] = []
        for send in handed where state.router.holdsUnsentDeliveryCopy(send.message.hash) {
            withdraw.append(.send(.router(.withdrawUnsentDeliveryCopy(messageHash: send.message.hash))))
            restamp.append(deliverySend(&state, message: send.message, method: send.method, waitForUnknownCost: false))
        }
        return (.concatenate(withdraw), .merge(restamp))
    }

    /// The message has ended (or been cancelled): it will not need re-stamping.
    private func forgetUnstampedHandOver(_ state: inout State, _ hash: Data) {
        for (dest, sends) in state.unstampedHandOvers where sends.contains(where: { $0.message.hash == hash }) {
            let rest = sends.filter { $0.message.hash != hash }
            state.unstampedHandOvers[dest] = rest.isEmpty ? nil : rest
        }
    }
}

// MARK: - Issuing tickets

extension LXMFNode.State {
    /// The `FIELD_TICKET` entry to put in a message YOU build to `destinationHash` before sending it
    /// with `.sendMessage`, or nil when `issueTickets` is off or no ticket should be included.
    /// Messages the node builds itself (`.send`, `.sendViaPropagation`) get theirs automatically.
    ///
    /// The ticket is part of the message's hashed, signed payload, so ask before creating it:
    ///
    /// ```swift
    /// let now = Date()
    /// let field = store.state.ticketFieldToIssue(destinationHash: peer, now: now)
    /// let message = LXMessage.create(source: identity, destinationHash: peer,
    ///                                timestamp: now.timeIntervalSince1970,
    ///                                title: title, content: content,
    ///                                fields: otherFields + (field.map { [$0] } ?? []))
    /// store.send(.sendMessage(message: message, fallbackToPropagation: true))
    /// ```
    ///
    /// This only reads state. The node records a minted ticket in `inboundTickets` (and reports
    /// `.ticketIssued`) when the message carrying it reaches `.sendMessage`, which is also where it
    /// starts watching for that message's delivery confirmation. A field asked for but never sent is
    /// never recorded, and no separate "I minted one" action exists to forget. Two messages built
    /// before either is sent can each mint a ticket; both are recorded and both stay valid.
    ///
    /// The rule is reference `generate_ticket` (`LXMRouter.py:1205-1228`, LXMF 1.3.0):
    ///  1. none if a ticket was delivered to this peer less than `LXMessage.ticketInterval` (1 day) ago;
    ///  2. else the ticket already issued to this peer with the latest expiry, if that is more than
    ///     `LXMessage.ticketRenew` (14 days) away;
    ///  3. else a new random 16-byte ticket expiring `LXMessage.ticketExpiry` (21 days) from `now`.
    ///
    /// The value is `[expires, ticket]` with `expires` a float unix time, as reference sends it.
    /// A new ticket's bytes come from `SecureRandom.bytes` (`SecRandomCopyBytes`).
    public func ticketFieldToIssue(destinationHash: Data, now: Date) -> MsgPackValue.IntPair? {
        ticketFieldToIssue(destinationHash: destinationHash, now: now,
                           newTicket: SecureRandom.bytes(LXMessage.ticketLength))
    }

    /// `ticketFieldToIssue(destinationHash:now:)` with `newTicket` as the bytes of a ticket minted now
    /// (unused when the rule reuses one or includes none). Bytes that are not `LXMessage.ticketLength`
    /// long are never minted: the result is nil where a mint would have happened.
    public func ticketFieldToIssue(destinationHash: Data, now: Date, newTicket: Data) -> MsgPackValue.IntPair? {
        guard issueTickets else { return nil }
        if let last = lastTicketDeliveries[destinationHash], now.timeIntervalSince(last) < LXMessage.ticketInterval {
            return nil
        }
        let ticket: LXMFNode.Ticket
        if let reusable = (inboundTickets[destinationHash] ?? [])
            .filter({ $0.expires > now + LXMessage.ticketRenew })
            .max(by: { $0.expires < $1.expires }) {
            ticket = reusable
        } else {
            guard newTicket.count == LXMessage.ticketLength else { return nil }
            ticket = LXMFNode.Ticket(ticket: newTicket, expires: now + LXMessage.ticketExpiry)
        }
        return .init(LXMessage.fieldTicket, .array([.double(ticket.expires.timeIntervalSince1970), .bin(ticket.ticket)]))
    }
}
