import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCATransport

/// LXMF inbound router (LXMF-4a): ingests inbound LXMF deliveries from any arrival method, validates
/// and de-duplicates them by `message.hash`, and surfaces each unique message once. Decoupled from
/// `TCPEndpoint` — the app forwards TCPEndpoint's delivery/announce events in as `.received`/`.learnedIdentity`.
/// Mirrors reference LXMRouter.lxmf_delivery (LXMRouter.py:1837-1919): always deliver a well-formed,
/// non-duplicate message (flagging signature validity), never drop on a bad/unknown signature.
@Reducer
public struct LXMFRouter {
    @Dependency(\.continuousClock) var clock
    private enum CancelID: Hashable { case retry(DeliveryKey); case idle(Data); case pathRequest(Data) }

    @ObservableState
    public struct State: Equatable {
        /// Dedup of already-delivered LXMF message IDs (`message.hash`). Bounded (RNS uses age-based
        /// expiry; a bounded ring is the LXMF-4a approximation).
        var seen = RingSet(capacity: 10_000)
        /// Message hashes one of whose copies has succeeded. A copy that fails LATER — even one armed
        /// after the success, as a propagated copy is once its stamp search finishes — is then not
        /// reported as `deliveryFailed`. Bounded like `seen`; see `succeededMessageMemory`.
        var succeededMessages = RingSet(capacity: LXMFRouter.succeededMessageMemory)
        /// Message hashes whose DELIVERY copy succeeded, inserted alongside `succeededMessages` (in
        /// either order relative to a propagated copy). It records only that success, not whether
        /// `LXMFNode` has handled the `deliveryConfirmed` it produced: `LXMFNode`'s ticket sweep pairs
        /// it with its own entry, which the confirmation removes. Bounded to the same capacity as
        /// `succeededMessages`, but evicts on its own, as only delivery copies are inserted. Removed by
        /// `uncancel` (a fresh send), which leaves `succeededMessages` alone.
        var confirmedDeliveryCopies = RingSet(capacity: LXMFRouter.succeededMessageMemory)
        /// Message hashes the app cancelled. A copy of one handed over later (a stamp search that
        /// finished after the cancel) is never armed. Bounded like `succeededMessages`.
        var cancelledMessages = RingSet(capacity: LXMFRouter.succeededMessageMemory)
        /// Message hashes whose delivery copy `LXMFNode` abandoned in its stamp search
        /// (`.deliveryCopyAbandoned`). A delivery copy of one handed over later is never armed; unlike
        /// `cancelledMessages`, the message's propagated copy is untouched, since it may still decide
        /// the outcome. Cleared by `uncancel` (a fresh send). Bounded like `succeededMessages`.
        var abandonedDeliveryCopies = RingSet(capacity: LXMFRouter.succeededMessageMemory)
        /// Message hashes whose propagated copy is still in `LXMFNode`'s stamp search, so not yet
        /// handed over. `isOutstanding` counts them: without this, the delivery copy running out first
        /// reported `deliveryFailed` for a message whose propagated copy was about to go out
        /// (2026-09-26 single-packet proofs spec, Amendment 3).
        public var pendingPropagatedCopies: Set<Data> = []
        /// Message hashes whose propagated copy starts only if the delivery copy stalls: at
        /// `LXMFDelivery.propagationFallbackAfterAttempts`, or at its terminal failure, the hash moves
        /// to `pendingPropagatedCopies` and `propagationFallbackDue` asks `LXMFNode` for the copy
        /// (spec Amendment A2). `isOutstanding` counts them as a propagated copy to come.
        public var fallbackEligible: Set<Data> = []
        /// sourceHash (sender's lxmf.delivery destination hash) → identity, for signature validation.
        public var knownIdentities: [Data: Identity] = [:]
        /// destinationHash → direct-link state (reuse an active link, or one being established).
        public var directLinks: [Data: LinkStatus] = [:]
        /// destinationHash → we have a learned path to it. Gates direct-link establishment: with no
        /// path, request one first (RNS process_outbound, LXMRouter.py:2829-2838).
        public var knownPaths: Set<Data> = []
        /// destinationHash → messages queued until a direct link to it becomes active.
        var outboundQueue: [Data: [LXMessage]] = [:]
        /// Message hashes whose delivery copy `LXMFNode` took back (`.withdrawUnsentDeliveryCopy`) to
        /// stamp it, and has not handed over again yet. Counted as an outstanding delivery copy, so the
        /// other copy failing meanwhile does not end the message. Cleared when the copy comes back
        /// (`.send`), on `.cancelOutbound`, and on `.deliveryCopyAbandoned`.
        var withdrawnDeliveryCopies: Set<Data> = []
        /// The withdrawn copies that were queued behind a direct link: message hash → destination.
        /// Such a copy still needs that link when it comes back, so it counts as link work
        /// (`hasLinkWork`), and losing it (cancel, abandon) can leave the link with none. Cleared with
        /// `withdrawnDeliveryCopies`.
        var withdrawnLinkCopies: [Data: Data] = [:]
        /// (message.hash, copy) → in-flight send awaiting a delivery outcome (with its resend info +
        /// attempts). Keyed per COPY because `LXMFNode.sendMessage(fallbackToPropagation:)` can arm a
        /// delivery copy and a propagated copy of one message; under one key the second overwrote
        /// the first and its outcome was reported as the other's.
        public var pendingDeliveries: [DeliveryKey: PendingDelivery] = [:]
        /// linkID → the copy whose Resource is currently in flight on that link. One per link:
        /// `resourceDeliveredOnLink` / `resourceFailedOnLink` resolve exactly that copy.
        public var linkResourceInFlight: [Data: DeliveryKey] = [:]
        /// Destination (recipient or propagation node) → Resource copies waiting for its link's
        /// transfer slot, oldest first; each is `.queued` in `pendingDeliveries`. One transfer per
        /// link: `LinkSession` keeps a single split-send slot, and reference's several concurrent
        /// Resources per link is out of scope (spec §4).
        public var resourceQueue: [Data: [DeliveryKey]] = [:]
        /// The configured store-and-forward propagation node (all PROPAGATED sends link to it).
        public var outboundPropagationNode: Data? = nil
        /// PN hash → propagated messages queued until a link to the PN becomes active.
        var propagationQueue: [Data: [PropagationItem]] = [:]
        /// Set when a sync was requested but the PN link is not yet active; drained on `.linkEstablished`.
        var pendingDownloadFromPN: Bool = false
        /// Where the propagation node sync stands, on reference's `PR_*` scale
        /// (`LXMRouter.propagation_transfer_state`). Failure states are sticky until the next
        /// `.syncFromPropagationNode`; see `PropagationTransferState`. Every change is reported as
        /// `.delegate(.propagationTransferStateChanged)`.
        public var propagationTransferState: PropagationTransferState = .idle
        /// The number of messages the last completed sync downloaded (0 for an empty offer), as
        /// reference's `propagation_transfer_last_result`. Cleared to nil whenever the sync's link
        /// closes, as `acknowledge_sync_completion` does (LXMRouter.py:1875).
        public var propagationTransferLastResult: Int? = nil
        /// What `.propagationTransferStateChanged` last reported; the body reports when it differs.
        var reportedTransfer = TransferReport(state: .idle, lastResult: nil)
        /// Client "have" set: transient_ids already downloaded from a PN. Drives the wants/haves split on
        /// the next offer (wants = offered we lack; haves = offered we have → PN purges). Unbounded for now.
        public var downloadedTransientIds: Set<Data> = []
        /// Consecutive failed link-establishment attempts per destination.
        ///
        /// `pendingDeliveries.attempts` bounds the retry-TIMER saga; a message sitting in
        /// `outboundQueue` is not armed with a timer until `linkEstablished` drains it, so without
        /// this counter `linkClosed -> establish -> requestLink -> linkFailed -> linkClosed` recurs
        /// forever.
        ///
        /// Two drivers reach this counter, and only one of them repeats:
        ///
        ///  • A LINK-shaped failure charges one attempt per route BELIEF. `establish` charges on
        ///    entry to its `knownPaths.contains` branch; whatever comes back then decides the rest.
        ///    A PATH-shaped answer (`.noPath` from either endpoint's `openLink`, `.pathStale` from
        ///    `BLEEndpoint.openLink`'s reachability gate, or an establishment `.timedOut`) is routed
        ///    by `LXMFNode` through `.pathLostAndClosed`, which FORGETS the route — so the next
        ///    `establish` takes the park branch and cannot charge again under that belief. Only
        ///    `.handshakeRejected` — the peer answered, so the route is fine — keeps the route, and
        ///    is therefore the one reason that charges repeatedly.
        ///  • `.pathRequestDeadline`: when `establish()` parks in `.awaitingPath` and the path
        ///    response never arrives, the park timer fires and increments this counter, re-emitting
        ///    `requestPath` until the budget is exhausted. The two establish branches therefore
        ///    share ONE budget — a destination cannot ping-pong between them to get a fresh allowance.
        ///
        /// So the ordinary unreachable-peer timeline is: at most one link attempt, then the park
        /// spends the remainder at `pathRequestWaitSeconds` intervals, ending in `deliveryFailed`.
        /// A BLE stale binding skips the link delay entirely (`openLink` gates synchronously); a
        /// silent peer pays one `LinkSession.establishmentTimeout` first.
        ///
        /// DELIBERATELY NOT STATED HERE: the wall-clock totals. This comment has been falsified
        /// three times by multiplying these constants out, because any change to `maxAttempts`,
        /// `pathRequestWaitSeconds`, `establishmentTimeout`, or the routing itself invalidates the
        /// arithmetic while leaving the prose confidently wrong. The authoritative figures are the
        /// clock advances in `establishmentTimeoutReachesRouterAndDoesNotWedgeDestination` and
        /// `routerBoundsTheAwaitingPathPark` — those are executable and cannot go stale silently.
        ///
        /// The TRADE, which is durable and worth stating: routing path-shaped failures into the
        /// park SHORTENS the deadline for both shapes relative to retrying links (the park interval
        /// is well under the establishment timeout). A peer whose reconnect-and-re-announce is
        /// slower than the park budget is now failed where a pure link-retry cycle would still have
        /// caught it. Judged the better default because the park actively SOLICITS the path with
        /// `requestPath` rather than retrying a route already known to be wrong, and because a
        /// failed message is re-sendable whereas a burned budget was not. If it proves too tight,
        /// raise `pathRequestWaitSeconds` before `maxAttempts` — the budget is shared, so raising
        /// the count also lengthens every other saga that draws on it.
        ///
        /// Queued copies are failed at the ceiling through `fail` (`deliveryFailed` unless the
        /// message's other copy is outstanding or already succeeded); a PN SYNC has no message
        /// to fail: its flag is cleared and `propagationTransferState` becomes `noPath` (the park ran
        /// out) or `linkFailed` (the establishment ceiling). See the give-up branch.
        ///
        /// Reset on `linkEstablished` — the one event that proves the destination is
        /// reachable again. Deliberately NOT reset on `learnedPath`; see that case for why a
        /// re-announce must not refresh the budget, and for the invariant tying this map to
        /// `knownPaths`.
        public var establishAttempts: [Data: Int] = [:]
        /// destinationHash → retry wait (seconds) for copies addressed there, for destinations whose
        /// next hop is slow enough to stretch it (`LXMFDelivery.retryWait(nextHopBitrate:)`).
        /// ABSENT means `LXMFDelivery.retryWaitSeconds`: fast paths are never stored, so on TCP/BLE
        /// this map stays empty. Written by `LXMFNode`, which can read Transport; the router only reads it.
        public var nextHopRetryWaits: [Data: Int] = [:]
        /// Outbound retries are held (`setHold`): the app is suspended and its sockets are closed
        /// (spec Amendment A3). Retry and park timers re-arm without counting an attempt or sending,
        /// new copies are armed but not sent, and establishment is deferred. So nothing fails, and no
        /// fallback hands off, while held. A held retry re-arms at `deliveryRetryTimer`'s wait, even
        /// one first armed at the path-request wait: the release decides when it next runs.
        ///
        /// Paths that run only on live connectivity still transmit while held — `.linkEstablished`
        /// draining its queues, a sync over an active link, `startNextQueued` — and every attempt
        /// they count is real. A transfer the suspension kills is not one: it is refunded.
        ///
        /// The contract with the app (`LXMFNode.Action.holdOutbound`):
        ///  • Hold BEFORE closing the sockets. `refundIfHeld` and `establish`'s held guard read this
        ///    flag when the closure's `linkClosed` / `resourceFailedOnLink` arrive; set after them, the
        ///    killed transfer is charged and the link is re-requested at once.
        ///  • Release on returning to the foreground as well as on an interface reconnecting. A hold
        ///    left on while the app is open with no connectivity keeps every send "sending": nothing
        ///    fails and nothing falls back to the propagation node.
        public var held = false
        public init() {}
    }

    /// How an LXMF message travels. Inbound it is the arrival path reported on `messageDelivered`:
    /// a single packet (`opportunistic`), a link packet or Resource (`direct`), or a download from a
    /// propagation node (`propagated`). Outbound, `.send` accepts `opportunistic` and `direct` only;
    /// propagated sends go through `.sendViaPropagation`.
    public enum DeliveryMethod: Equatable, Sendable { case opportunistic, direct, propagated }
    public enum LinkStatus: Equatable { case awaitingPath; case establishing; case active(linkID: Data) }

    /// Which copy of an outbound message a pending delivery tracks. `delivery` is the copy addressed
    /// to the recipient — opportunistic, or direct over a link, including an opportunistic send
    /// promoted to direct because it does not fit one packet. `propagated` is the copy handed to the
    /// outbound propagation node.
    public enum Leg: Hashable, Sendable { case delivery, propagated }

    /// Key of `pendingDeliveries` and of each copy's retry timer.
    public struct DeliveryKey: Hashable, Sendable {
        public var messageHash: Data
        public var leg: Leg
        public init(messageHash: Data, leg: Leg) {
            self.messageHash = messageHash
            self.leg = leg
        }
        public static func delivery(_ messageHash: Data) -> DeliveryKey { DeliveryKey(messageHash: messageHash, leg: .delivery) }
        public static func propagated(_ messageHash: Data) -> DeliveryKey { DeliveryKey(messageHash: messageHash, leg: .propagated) }
    }

    public enum ResendInfo: Equatable {
        case opportunistic(destinationHash: Data, payload: Data)
        case direct(destinationHash: Data, data: Data, asResource: Bool)
        case propagated(destinationHash: Data, data: Data)
    }
    /// Where a pending copy is in its life (spec §1).
    public enum Phase: Equatable, Sendable {
        /// Armed with a retry timer: opportunistic packets, link packets, and a Resource copy whose
        /// last transfer failed and is waiting for its retry.
        case retrying
        /// A Resource is in flight for this copy. No retry timer: the transfer decides the outcome,
        /// as reference does while a message is SENDING (LXMRouter.py:2788-2796).
        case transferring
        /// Waiting for its link's current Resource transfer to finish (one transfer per link).
        case queued
    }
    public struct PendingDelivery: Equatable {
        public var resend: ResendInfo
        public var attempts: Int
        public var phase: Phase
        /// Explicit because the synthesised memberwise init on a `public struct` is INTERNAL,
        /// which made this type public in name only — no other module could construct one.
        public init(resend: ResendInfo, attempts: Int, phase: Phase = .retrying) {
            self.resend = resend
            self.attempts = attempts
            self.phase = phase
        }
    }
    /// Why a copy failed for good; the terminal delegate says which.
    enum FailureReason: Equatable { case exhausted, rejected }
    /// Why a propagated copy was not attempted at all.
    public enum RefusalReason: Equatable, Sendable {
        /// Larger than the propagation node's announced per-transfer limit.
        case tooLargeForNode
    }
    /// Why an inbound message was dropped before delivery (`.messageRejected`).
    public enum RejectReason: Equatable, Sendable {
        /// A `.direct` or `.propagated` message whose destination is not our delivery destination,
        /// or one that arrived before any delivery destination was registered.
        case notAddressedToUs
        /// The sender's identity is known and the signature does not verify against it.
        case badSignature
    }
    public struct PropagationItem: Equatable { public var messageHash: Data; public var propagationPacked: Data }

    /// Reference's client sync states, raw values verbatim from `LXMRouter.PR_*` (lxmf 1.3.0
    /// LXMRouter.py:78-91). A CLIENT STATE space: 0xF0/0xF1 here are `noPath`/`linkFailed`, while
    /// the same bytes on the wire are `ERROR_NO_IDENTITY`/`ERROR_NO_ACCESS` (`LXMFPropagation`).
    ///
    /// Transitions follow reference (LXMRouter.py:579-621, 1096-1106, 1683-1692, 1780-1883):
    /// a sync request sets `pathRequested`, `linkEstablishing` or `requestSent`; an empty offer or a
    /// download sets `complete`; `ERROR_NO_IDENTITY` / `ERROR_NO_ACCESS` set `noIdentityReceived` /
    /// `noAccess`. When the sync's link closes: `complete` → `idle`; below `linkEstablished` →
    /// `linkFailed`; from `linkEstablished` up to `complete` → `transferFailed`; anything above
    /// `complete` is kept (sticky until the next sync request).
    ///
    /// ReTiCA retries link establishment (`establishAttempts`) where reference fails on the first
    /// closed link, so `noPath` and `linkFailed` are set only where the router gives up: the park
    /// ending at `.pathRequestDeadline` gives `noPath`, the establishment ceiling `linkFailed`.
    /// `receiving` and `responseReceived` are declared but never entered: there is no response
    /// progress for link requests. `failed` is reference's catch-all, also never entered.
    public enum PropagationTransferState: UInt8, Equatable, Sendable {
        case idle = 0x00
        case pathRequested = 0x01
        case linkEstablishing = 0x02
        case linkEstablished = 0x03
        case requestSent = 0x04
        case receiving = 0x05
        case responseReceived = 0x06
        case complete = 0x07
        case noPath = 0xF0
        case linkFailed = 0xF1
        case transferFailed = 0xF2
        case noIdentityReceived = 0xF3
        case noAccess = 0xF4
        case failed = 0xFE
    }

    /// A propagation node's sync response that is not a usable answer, as `LXMFNode` classifies it.
    /// `noIdentity`: `ERROR_NO_IDENTITY` (0xF0). `noAccess`: `ERROR_NO_ACCESS` (0xF1). `invalid`:
    /// anything else that is not a list (another error code, nil, garbage).
    public enum SyncError: Equatable, Sendable { case noIdentity, noAccess, invalid }

    public enum Action: Equatable {
        /// Restore dedup state from a previous session so a cold-start does not re-deliver messages
        /// the router already processed, and does not re-request transient IDs already downloaded
        /// from a propagation node.
        ///
        /// **`seenHashes` — ordering is load-bearing.**
        /// Supply hashes **oldest-first** (ascending `storedAt`, matching the app's `ORDER BY storedAt`
        /// query). `seen` is a bounded `RingSet(capacity: 10_000)`: inserting more entries than the
        /// capacity evicts the oldest ones. If entries are supplied newest-first the wrong 10 000 are
        /// retained — the newest are evicted and the oldest survive, which is the opposite of what is
        /// wanted. Oldest-first ensures that eviction during rehydration matches what would have
        /// happened had those inserts been live.
        ///
        /// **`downloadedTransientIds` — unbounded growth is known, accepted, and deliberate.**
        /// This set grows without bound: every transient ID ever downloaded from a propagation node
        /// accumulates here. A cap would trade disk space against re-downloading old messages from the
        /// PN (any evicted ID would look "new" again on the next offer), and there is no field data yet
        /// to price that trade. The decision is deferred until real usage reveals how large the set
        /// grows in practice. Revisit trigger: a user report that the table is growing uncomfortably
        /// large, or operational data showing a representative steady-state size.
        case rehydrateDedup(seenHashes: [Data], downloadedTransientIds: [Data])
        case learnedIdentity(destinationHash: Data, identity: Identity)
        /// `destinationHash`: for `.opportunistic`, the packet's destination, from which the message
        /// is rebuilt. For `.direct` and `.propagated`, OUR delivery destination hash (empty when none
        /// is registered); the message's own destination must equal it.
        case received(method: DeliveryMethod, destinationHash: Data, data: Data)
        case send(message: LXMessage, desiredMethod: DeliveryMethod)
        case setOutboundPropagationNode(Data?)
        case sendViaPropagation(message: LXMessage, propagationPacked: Data)
        case syncFromPropagationNode
        /// The PN's answer to the list request. An empty list completes the sync (last result 0).
        case offeredMessageList(transientIds: [Data])
        /// The PN's answer to the wanted-messages request: completes the sync (last result `count`).
        case messagesDownloaded(transientIds: [Data])
        /// The PN answered a sync request on `linkID` with an error or with something that is not a
        /// list. `LXMFNode` tears that link down itself. If `linkID` is the active link to the current
        /// propagation node, `noIdentity` / `noAccess` set their (sticky) state; otherwise nothing.
        case syncError(SyncError, linkID: Data)
        case linkEstablished(destinationHash: Data, linkID: Data)
        case linkClosed(destinationHash: Data)
        case learnedPath(destinationHash: Data)
        /// `linkClosed`, preceded by the inverse of `learnedPath`: forget that a usable route to
        /// `dest` exists, THEN close. Sent when a link failure was PATH-shaped — the route is
        /// falsified, so re-establishing against it is wasted budget. `establish` consequently
        /// takes its `.awaitingPath` branch and requests a fresh path.
        ///
        /// Deliberately ONE action rather than a `pathLost` + `linkClosed` pair. The pair had an
        /// ordering requirement (clear before close, or `establish` reads the stale `knownPaths`
        /// and emits `requestLink` anyway), and any gap between the two — a `.run` with two
        /// `await send`s opens a MainActor suspension — is a window in which an inbound
        /// `learnedPath` from a routine announce can re-insert the very entry just removed,
        /// restoring the pre-fix behaviour non-deterministically. Fusing them removes the window
        /// and the requirement together: there is no ordering left to get wrong.
        ///
        /// The cost of getting the old ordering wrong was a SPENT BUDGET, not a stuck destination
        /// — `establish` charges an attempt only on its `knownPaths.contains` branch, and the park
        /// branch is free. `stalePathLinkFailureRequestsAPathInsteadOfRetryingTheLink` pins that
        /// via `establishAttempts == nil`, and it remains the mutation catcher for this action:
        /// drop the `knownPaths.remove` below and it fails.
        case pathLostAndClosed(destinationHash: Data)
        /// Give the delivery copy of this message back, silently, if it has not gone out yet
        /// (`State.holdsUnsentDeliveryCopy`): `LXMFNode` learned the recipient's stamp cost after
        /// handing it over unstamped, and hands it over again stamped. Nothing is reported; the copy
        /// stays outstanding (`withdrawnDeliveryCopies`) until it comes back.
        case withdrawUnsentDeliveryCopy(messageHash: Data)
        /// A receipt for one copy of a message. The copy is named by the path that produced the
        /// receipt, never inferred from which copy was armed last.
        case delivered(messageHash: Data, leg: Leg)
        /// A single-packet proof arrived for one of this message's opportunistic packets (Transport
        /// `singlePacketDelivered`, token = message hash). Confirms the DELIVERY copy.
        case opportunisticDelivered(messageHash: Data)
        case resourceDeliveredOnLink(linkID: Data)
        /// The Resource in flight on `linkID` failed. `rejected`: the peer refused it (terminal).
        /// Otherwise the link is closed and the copy retried once, after the destination's retry wait (`nextHopRetryWaits`, default `retryWaitSeconds`).
        case resourceFailedOnLink(linkID: Data, rejected: Bool)
        /// The app cancelled this message: drop every copy, cancel a Resource in flight, report
        /// `deliveryCancelled` once — or nothing, when a copy already succeeded (that success was the
        /// message's terminal outcome). Reference `LXMRouter.cancel_outbound` (LXMRouter.py:1719-1744).
        case cancelOutbound(messageHash: Data)
        /// Resource traffic on `linkID` (either direction). Re-arms the idle timer of the
        /// destination it serves, so a long transfer never trips `linkMaxInactivitySeconds` (spec §5).
        case linkActivity(linkID: Data)
        /// `LXMFNode` started the stamp search for this message's propagated copy.
        case propagatedCopyPending(messageHash: Data)
        /// This message's propagated copy is a fallback: it is requested with `propagationFallbackDue`
        /// only if the delivery copy stalls. Send before the delivery copy is handed over.
        case markFallbackEligible(messageHash: Data)
        /// `LXMFNode`'s `.cancelDeliveryStamps` stopped this message's delivery copy in its stamp
        /// search: that copy has failed, through `fail`, with no fallback started. So `deliveryFailed`
        /// is reported only if no other copy is out and none succeeded, and a stamped copy handed
        /// over late is refused (`abandonedDeliveryCopies`).
        case deliveryCopyAbandoned(messageHash: Data)
        /// `LXMFNode` could not pack the propagated copy `propagationFallbackDue` asked for: that
        /// copy has failed, through `fail`. Ignored unless the copy is still pending.
        case propagatedCopyFailed(messageHash: Data)
        /// `LXMFNode` did not start this message's propagated copy at all (spec §6).
        case propagatedCopyRefused(messageHash: Data, reason: RefusalReason)
        /// Every propagated-copy stamp search was cancelled: those copies have failed. A message in
        /// `stillSearching` (its delivery copy is still in `LXMFNode`'s delivery-stamp search, which
        /// this router cannot see) only loses its marker: its delivery copy decides the outcome.
        case abandonPendingPropagatedCopies(stillSearching: Set<Data>)
        case retryDue(messageHash: Data, leg: Leg)
        case idleDeadline(destinationHash: Data, linkID: Data)
        case pathRequestDeadline(destinationHash: Data)
        /// Hold (`true`) or release outbound retries; see `State.held`. Releasing a hold fires `.retryDue`
        /// at once for every retrying copy, from its stored attempt count, and re-establishes every
        /// destination with work waiting on a link.
        case setHold(Bool)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case messageDelivered(message: LXMessage, signatureValidated: Bool, method: DeliveryMethod)
            case duplicateDropped(hash: Data)
            /// The message was dropped by a forgery check and NOT marked seen, so a genuine copy with
            /// the same hash is still delivered.
            case messageRejected(hash: Data, reason: RejectReason)
            /// `messageHash` becomes the packet's receipt token, so a proof for ANY attempt of this
            /// message comes back as `.opportunisticDelivered(messageHash:)`.
            case sendOpportunistic(destinationHash: Data, payload: Data, messageHash: Data)
            case requestLink(destinationHash: Data)
            case requestPath(destinationHash: Data)
            case sendDirect(linkID: Data, data: Data, asResource: Bool)
            case sendPropagated(linkID: Data, propagationPacked: Data)
            case sendPropagatedPacket(linkID: Data, propagationPacked: Data, messageHash: Data)
            case requestMessageList(linkID: Data)
            case requestMessages(linkID: Data, wants: [Data], haves: [Data])
            case closeLink(destinationHash: Data)
            /// The link to `destinationHash` is still `.establishing` and the last work that needed it
            /// has gone (cancelled, failed, or made unnecessary by a success). The router stays
            /// `.establishing`: the host may stop that work and report `.linkClosed`, or let the
            /// establishment finish and report its outcome as usual. `LXMFNode` stops a link-request
            /// key search this way.
            case abandonLink(destinationHash: Data)
            case deliveryConfirmed(messageHash: Data)
            case propagationAccepted(messageHash: Data)
            case deliveryFailed(messageHash: Data)
            /// Every copy is over, none succeeded, and the last to fail was REJECTED by its peer.
            case deliveryRejected(messageHash: Data)
            /// The app cancelled the message. Nothing else is reported for it afterwards.
            case deliveryCancelled(messageHash: Data)
            /// Cancel our Resource in flight on `linkID` (its copy was cancelled).
            case cancelResource(linkID: Data)
            /// The propagated copy was not attempted. Not terminal: the delivery copy decides.
            case propagationRefused(messageHash: Data, reason: RefusalReason)
            /// A fallback-eligible message's delivery copy stalled: pack and hand over its propagated
            /// copy (`.sendViaPropagation`). Already marked pending. For `LXMFNode`, not the app.
            case propagationFallbackDue(messageHash: Data)
            /// `State.propagationTransferState` or `propagationTransferLastResult` changed. Once per
            /// change, with the new values.
            case propagationTransferStateChanged(PropagationTransferState, lastResult: Int?)
        }
    }

    public init() {}

    /// How many recently-succeeded message hashes `succeededMessages` remembers. A copy that fails
    /// more than this many successes later could be reported failed; far beyond any retry saga.
    static let succeededMessageMemory = 1024

    /// `transitions`, plus one `.propagationTransferStateChanged` whenever an action changed the sync
    /// state or its last result — whichever case changed it.
    public var body: some ReducerOf<Self> {
        transitions
        Reduce { state, _ in
            let current = TransferReport(state: state.propagationTransferState,
                                         lastResult: state.propagationTransferLastResult)
            guard current != state.reportedTransfer else { return .none }
            state.reportedTransfer = current
            return .send(.delegate(.propagationTransferStateChanged(current.state, lastResult: current.lastResult)))
        }
    }

    /// The sync state and last result as last reported by `.propagationTransferStateChanged`.
    struct TransferReport: Equatable {
        var state: PropagationTransferState
        var lastResult: Int?
    }

    var transitions: some ReducerOf<Self> {
        Reduce { [clock] state, action in
            /// Reference `acknowledge_sync_completion` (LXMRouter.py:1874-1883): clear the last result,
            /// and move to `failure` (or idle) only from a state up to `complete`. A state above
            /// `complete` is a failure already reported, kept until the next sync request.
            func acknowledgeSync(_ state: inout State, failure: PropagationTransferState?) {
                state.propagationTransferLastResult = nil
                if state.propagationTransferState.rawValue <= PropagationTransferState.complete.rawValue {
                    state.propagationTransferState = failure ?? .idle
                }
            }
            /// A sync waiting for its link reports how the link is coming: a path request or an
            /// establishment. Unchanged when no link is under way (held).
            func syncAwaitingLink(_ state: inout State, _ pn: Data) {
                switch state.directLinks[pn] {
                case .awaitingPath: state.propagationTransferState = .pathRequested
                case .establishing: state.propagationTransferState = .linkEstablishing
                case .active, nil: break
                }
            }
            /// Reference `clean_links` on a closed outbound propagation link (LXMRouter.py:1096-1106).
            /// One departure: from `idle` nothing changes. Reference would report `linkFailed` when a
            /// link it opened only to SEND propagated messages closes with no sync ever run; here the
            /// PN link also carries those sends, and its routine idle close is not a sync failure.
            func syncLinkClosed(_ state: inout State) {
                let current = state.propagationTransferState
                guard current != .idle else { return }
                if current == .complete {
                    acknowledgeSync(&state, failure: nil)
                } else if current.rawValue < PropagationTransferState.linkEstablished.rawValue {
                    acknowledgeSync(&state, failure: .linkFailed)
                } else if current.rawValue < PropagationTransferState.complete.rawValue {
                    acknowledgeSync(&state, failure: .transferFailed)
                } else {
                    acknowledgeSync(&state, failure: nil)
                }
            }
            func retryTimer(_ key: DeliveryKey, _ seconds: Int) -> Effect<Action> {
                .run { send in
                    try await clock.sleep(for: .seconds(seconds))
                    await send(.retryDue(messageHash: key.messageHash, leg: key.leg))
                }.cancellable(id: CancelID.retry(key), cancelInFlight: true)
            }
            /// Arm `key`'s retry timer at its destination's wait. EVERY delivery-retry site uses this
            /// (the path-request wait is separate); `key` is armed in `pendingDeliveries` first.
            func deliveryRetryTimer(_ state: State, _ key: DeliveryKey) -> Effect<Action> {
                let wait = state.pendingDeliveries[key].flatMap { state.nextHopRetryWaits[$0.resend.destinationHash] }
                    ?? LXMFDelivery.retryWaitSeconds
                return retryTimer(key, wait)
            }
            /// `.abandonLink` for `dest`, if its link is still being established and no work for it is
            /// left. Call after removing work for `dest`.
            func abandonIfIdle(_ state: State, _ dest: Data) -> Effect<Action> {
                guard state.directLinks[dest] == .establishing, !state.hasLinkWork(for: dest) else { return .none }
                return .send(.delegate(.abandonLink(destinationHash: dest)))
            }
            func idleTimer(_ dest: Data, _ linkID: Data) -> Effect<Action> {
                .run { send in
                    try await clock.sleep(for: .seconds(LXMFDelivery.linkMaxInactivitySeconds))
                    await send(.idleDeadline(destinationHash: dest, linkID: linkID))
                }.cancellable(id: CancelID.idle(dest), cancelInFlight: true)
            }
            func pathRequestTimer(_ dest: Data) -> Effect<Action> {
                .run { send in
                    try await clock.sleep(for: .seconds(LXMFDelivery.pathRequestWaitSeconds))
                    await send(.pathRequestDeadline(destinationHash: dest))
                }.cancellable(id: CancelID.pathRequest(dest), cancelInFlight: true)
            }
            func arm(_ state: inout State, _ key: DeliveryKey, _ resend: ResendInfo) {
                state.pendingDeliveries[key] = PendingDelivery(resend: resend, attempts: 1)
            }
            /// `arm` while held: nothing is sent, so no attempt is counted. The retry timer re-arms
            /// until the release fires it, and that `.retryDue` counts and sends the first attempt.
            func armHeld(_ state: inout State, _ key: DeliveryKey, _ resend: ResendInfo) -> Effect<Action> {
                state.pendingDeliveries[key] = PendingDelivery(resend: resend, attempts: 0)
                return deliveryRetryTimer(state, key)
            }
            /// The destination whose ACTIVE link is `linkID`, if any.
            func destination(ofLink linkID: Data, _ state: State) -> Data? {
                state.directLinks.first { $0.value == .active(linkID: linkID) }?.key
            }
            /// Start this Resource copy's transfer on `linkID`: it becomes `.transferring` and owns the
            /// link's transfer slot. No retry timer — `resourceDeliveredOnLink` / `resourceFailedOnLink`
            /// (or losing the link, see `orphanTransfer`) decide what happens next.
            func startResource(_ state: inout State, _ key: DeliveryKey, linkID: Data) -> Effect<Action> {
                guard var pending = state.pendingDeliveries[key] else { return .none }
                pending.phase = .transferring
                state.pendingDeliveries[key] = pending
                state.linkResourceInFlight[linkID] = key
                switch pending.resend {
                case let .direct(_, data, _):
                    return .send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: true)))
                case let .propagated(_, data):
                    return .send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: data)))
                case .opportunistic:
                    return .none
                }
            }
            /// Start this Resource copy now if `linkID` has no transfer in flight, else queue it.
            func startOrQueueResource(_ state: inout State, _ key: DeliveryKey, dest: Data, linkID: Data) -> Effect<Action> {
                guard state.linkResourceInFlight[linkID] == nil else {
                    state.pendingDeliveries[key]?.phase = .queued
                    state.resourceQueue[dest, default: []].append(key)
                    return .none
                }
                return startResource(&state, key, linkID: linkID)
            }
            /// `dest`'s transfer slot may be free: start its oldest copy still waiting, if the link is up.
            func startNextQueued(_ state: inout State, dest: Data) -> Effect<Action> {
                guard case let .active(linkID) = state.directLinks[dest],
                      state.linkResourceInFlight[linkID] == nil else { return .none }
                while var queue = state.resourceQueue[dest], !queue.isEmpty {
                    let key = queue.removeFirst()
                    state.resourceQueue[dest] = queue.isEmpty ? nil : queue
                    if state.pendingDeliveries[key]?.phase == .queued {
                        return startResource(&state, key, linkID: linkID)
                    }
                }
                return .none
            }
            /// `linkID` is going away with a Resource in flight. A closing `LinkSession` reaps its
            /// transfers without reporting them, so this IS that transfer's failure: back to
            /// `.retrying` with one retry timer, exactly as `.resourceFailedOnLink` would — UNLESS
            /// this copy already used its last transfer (Ruling P6): a lost link is a failed attempt
            /// too, so at `maxAttempts` it fails the copy outright rather than arming a sixth. While
            /// held the suspension killed it, so it is refunded (`refundIfHeld`) and retries.
            func orphanTransfer(_ state: inout State, linkID: Data) -> Effect<Action> {
                guard let key = state.linkResourceInFlight.removeValue(forKey: linkID),
                      var pending = state.pendingDeliveries[key],
                      pending.phase == .transferring else { return .none }
                refundIfHeld(state, &pending)
                guard pending.attempts < LXMFDelivery.maxAttempts else {
                    return fail(&state, key)
                }
                pending.phase = .retrying
                state.pendingDeliveries[key] = pending
                return deliveryRetryTimer(state, key)
            }
            /// A transfer lost while held was killed by the suspension, not by the peer or the path:
            /// it does not count, so the copy cannot fail at the release because of the suspension.
            func refundIfHeld(_ state: State, _ pending: inout PendingDelivery) {
                if state.held { pending.attempts = max(0, pending.attempts - 1) }
            }
            /// One copy of a message was confirmed: settle that copy only, stop its retries, remember
            /// the success, and report the outcome that copy stands for. A receipt for a copy no
            /// longer pending is ignored. A confirmed delivery copy also drops the propagated copy
            /// if it has not gone out yet (`dropUnsentPropagatedCopy`).
            func succeed(_ state: inout State, _ key: DeliveryKey) -> Effect<Action> {
                guard let settled = state.pendingDeliveries.removeValue(forKey: key) else { return .none }
                state.succeededMessages.insert(key.messageHash)
                var dropped: Effect<Action> = .none
                if key.leg == .delivery {
                    state.confirmedDeliveryCopies.insert(key.messageHash)
                    state.fallbackEligible.remove(key.messageHash)
                    dropped = dropUnsentPropagatedCopy(&state, key.messageHash)
                }
                let outcome: Action.Delegate = key.leg == .propagated
                    ? .propagationAccepted(messageHash: key.messageHash)
                    : .deliveryConfirmed(messageHash: key.messageHash)
                // The settled copy may have been the last work for a link still re-establishing.
                let abandoned = abandonIfIdle(state, settled.resend.destinationHash)
                return .merge(.cancel(id: CancelID.retry(key)), dropped, abandoned, .send(.delegate(outcome)))
            }
            /// The delivery copy of `hash` succeeded: its propagated copy is not needed, so one that has
            /// not gone out is dropped silently — still in its stamp search (`LXMFNode` stops that
            /// search on `deliveryConfirmed`), queued behind the node's link, or armed but never sent
            /// (attempts 0: armed while held). Otherwise it would go out long after the message
            /// arrived, perhaps at a hold's release, and reach the recipient twice. A copy already
            /// transmitted is left to finish: its `propagationAccepted` is a second success, not a
            /// contradiction.
            func dropUnsentPropagatedCopy(_ state: inout State, _ hash: Data) -> Effect<Action> {
                state.pendingPropagatedCopies.remove(hash)
                var emptied: [Data] = []
                for (dest, items) in state.propagationQueue where items.contains(where: { $0.messageHash == hash }) {
                    let rest = items.filter { $0.messageHash != hash }
                    state.propagationQueue[dest] = rest.isEmpty ? nil : rest
                    emptied.append(dest)
                }
                let key = DeliveryKey.propagated(hash)
                var cancelRetry: Effect<Action> = .none
                if state.pendingDeliveries[key]?.attempts == 0 {
                    state.pendingDeliveries[key] = nil
                    cancelRetry = .cancel(id: CancelID.retry(key))
                }
                return .merge([cancelRetry] + emptied.map { abandonIfIdle(state, $0) })
            }
            /// Whether the `leg` copy of `hash` can still succeed: armed with a retry timer, or queued
            /// behind its link (not yet armed, but it will be when the link comes up).
            ///
            /// Accepted gap: a delivery copy still in its stamp search (in `LXMFNode`, not yet handed
            /// to this router) is invisible here, so it does not count as outstanding.
            func isOutstanding(_ state: State, _ hash: Data, _ leg: Leg) -> Bool {
                if state.pendingDeliveries[DeliveryKey(messageHash: hash, leg: leg)] != nil { return true }
                switch leg {
                case .delivery:
                    return state.withdrawnDeliveryCopies.contains(hash)
                        || state.outboundQueue.values.contains { $0.contains { $0.hash == hash } }
                case .propagated:
                    return state.pendingPropagatedCopies.contains(hash)
                        || state.fallbackEligible.contains(hash)
                        || state.propagationQueue.values.contains { $0.contains { $0.messageHash == hash } }
                }
            }
            /// One copy of a message has failed for good. `deliveryFailed` is reported only when no
            /// other copy can still succeed and none already did (spec §3). Every router failure path
            /// goes through here, `LXMFNode`'s `.cancelDeliveryStamps` included (`.deliveryCopyAbandoned`).
            func fail(_ state: inout State, _ key: DeliveryKey, reason: FailureReason = .exhausted) -> Effect<Action> {
                let dest = state.pendingDeliveries.removeValue(forKey: key)?.resend.destinationHash
                if key.leg == .propagated { state.pendingPropagatedCopies.remove(key.messageHash) }
                let abandoned = dest.map { abandonIfIdle(state, $0) } ?? .none
                // A delivery copy that ran out before its hand-off hands off now, and the propagated
                // copy it starts keeps the message alive below. A REJECTED one was answered, not
                // stalled: it ends the message as it always did.
                var handOff: Effect<Action> = .none
                if key.leg == .delivery {
                    if reason == .rejected {
                        state.fallbackEligible.remove(key.messageHash)
                    } else {
                        handOff = startFallbackIfEligible(&state, key.messageHash)
                    }
                }
                let other: Leg = key.leg == .delivery ? .propagated : .delivery
                guard !isOutstanding(state, key.messageHash, other),
                      !state.succeededMessages.contains(key.messageHash)
                else { return .merge(abandoned, handOff) }
                // The terminal outcome carries the reason of the copy that ended the message.
                let outcome: Action.Delegate = reason == .rejected
                    ? .deliveryRejected(messageHash: key.messageHash)
                    : .deliveryFailed(messageHash: key.messageHash)
                return .merge(abandoned, handOff, .send(.delegate(outcome)))
            }
            /// A fallback-eligible message's delivery copy has stalled: its propagated copy is now
            /// pending, and `LXMFNode` is asked for it. The ONE place the hand-off happens; it fires
            /// at most once per message, because it ends the eligibility (spec Amendment A2).
            func startFallbackIfEligible(_ state: inout State, _ hash: Data) -> Effect<Action> {
                guard state.fallbackEligible.remove(hash) != nil else { return .none }
                state.pendingPropagatedCopies.insert(hash)
                return .send(.delegate(.propagationFallbackDue(messageHash: hash)))
            }
            /// `dest`'s establishment budget reached `attempts`: an attempt for every copy queued
            /// behind it, so each may be due its hand-off. Both establish branches charge the budget.
            func startFallbackForQueued(_ state: inout State, _ dest: Data, attempts: Int) -> Effect<Action> {
                guard attempts >= LXMFDelivery.propagationFallbackAfterAttempts else { return .none }
                let queued = state.outboundQueue[dest] ?? []
                return .merge(queued.map { startFallbackIfEligible(&state, $0.hash) })
            }
            // Tear down a direct link, reaping its in-flight Resource entry. `linkResourceInFlight`
            // is keyed on the linkID carried by `.active`, so it can only be reaped BEFORE
            // `directLinks[dest]` is cleared — do both here so no teardown path can strand an entry (F7).
            // The copy that owned the entry goes back to retrying (`orphanTransfer`); the returned
            // effect is its retry timer.
            func clearDirectLink(_ state: inout State, _ dest: Data) -> Effect<Action> {
                var orphaned: Effect<Action> = .none
                if case let .active(linkID) = state.directLinks[dest] {
                    orphaned = orphanTransfer(&state, linkID: linkID)
                }
                state.directLinks[dest] = nil
                return orphaned
            }
            /// Give up on `dest`: cancel the path-request park timer, fail everything queued for it,
            /// forget the path, and clear all establishment state. Both call sites (the `establish`
            /// ceiling and `.pathRequestDeadline`) must terminate identically — extract here rather
            /// than duplicate.
            ///
            /// `syncFailure` is the state an outstanding sync to this destination ends in: `noPath`
            /// when the path-request park ran out, `linkFailed` at the establishment ceiling.
            func giveUp(_ state: inout State, _ dest: Data, syncFailure: PropagationTransferState) -> Effect<Action> {
                state.establishAttempts[dest] = nil
                state.knownPaths.remove(dest)
                let orphaned = clearDirectLink(&state, dest)
                let queued = state.outboundQueue[dest] ?? []
                let propQueued = state.propagationQueue[dest] ?? []
                state.outboundQueue[dest] = nil
                state.propagationQueue[dest] = nil
                // An outstanding sync needs an explicit terminus too. Unlike the queues above
                // (drained here) and `pendingDeliveries` (self-clearing via the retry saga),
                // `pendingDownloadFromPN` is otherwise cleared ONLY when `.linkEstablished`
                // drains it. Left set, it would (a) keep this destination permanently "has work"
                // so every later `linkClosed(pn)` re-enters establish, and (b) let an unrelated
                // future PN link resurrect the abandoned sync with a surprise `requestMessageList`.
                // Guarded on the PN: an unrelated destination giving up says nothing about the sync.
                if dest == state.outboundPropagationNode {
                    if state.pendingDownloadFromPN { acknowledgeSync(&state, failure: syncFailure) }
                    state.pendingDownloadFromPN = false
                }
                var effects: [Effect<Action>] = [orphaned, .cancel(id: CancelID.pathRequest(dest))]
                // `fail` hands off a fallback-eligible copy whose earlier trigger never fired.
                for message in queued { effects.append(fail(&state, .delivery(message.hash))) }
                for item in propQueued { effects.append(fail(&state, .propagated(item.messageHash))) }
                // Resource copies waiting for this destination's link have no timer of their own.
                for key in state.resourceQueue.removeValue(forKey: dest) ?? [] where state.pendingDeliveries[key] != nil {
                    effects.append(fail(&state, key))
                }
                return .merge(effects)
            }
            /// `.retryDue`'s next attempt for `key`, already counted: resend it, or wait and re-check.
            func resend(_ state: inout State, _ key: DeliveryKey, _ info: ResendInfo) -> Effect<Action> {
                let hash = key.messageHash
                switch info {
                case let .opportunistic(destinationHash, payload):
                    if !state.knownPaths.contains(destinationHash) {
                        // Pathless opportunistic retry: request a path instead of resending, and wait longer.
                        return .merge(.send(.delegate(.requestPath(destinationHash: destinationHash))),
                                      retryTimer(key, LXMFDelivery.pathRequestWaitSeconds))
                    }
                    return .merge(.send(.delegate(.sendOpportunistic(destinationHash: destinationHash, payload: payload,
                                                                     messageHash: hash))),
                                  deliveryRetryTimer(state, key))
                case let .direct(destinationHash, data, asResource):
                    if case let .active(linkID) = state.directLinks[destinationHash] {
                        if asResource { return startOrQueueResource(&state, key, dest: destinationHash, linkID: linkID) }
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: false))),
                                      deliveryRetryTimer(state, key))
                    }
                    // Link is down or re-establishing: no live link to send on. Wait and re-check; the
                    // attempt was already counted, so the saga stays bounded by maxAttempts.
                    return deliveryRetryTimer(state, key)
                case let .propagated(destinationHash, data):
                    if case let .active(linkID) = state.directLinks[destinationHash] {
                        if data.count <= Link.mdu {
                            return .merge(.send(.delegate(.sendPropagatedPacket(linkID: linkID,
                                                                                propagationPacked: data,
                                                                                messageHash: hash))),
                                          deliveryRetryTimer(state, key))
                        } else {
                            return startOrQueueResource(&state, key, dest: destinationHash, linkID: linkID)
                        }
                    }
                    // Link down/re-establishing: no live link; wait and re-check (bounded by maxAttempts).
                    return deliveryRetryTimer(state, key)
                }
            }
            func establish(_ state: inout State, _ dest: Data) -> Effect<Action> {
                // Held: no link or path request, and no attempt counted. The release re-establishes
                // every destination that still has work (`destinationsAwaitingLinks`).
                guard !state.held else { return .none }
                if state.knownPaths.contains(dest) {
                    let attempts = (state.establishAttempts[dest] ?? 0) + 1
                    if attempts > LXMFDelivery.maxAttempts {
                        // Give up on this destination: fail everything queued for it, and forget the
                        // path — our belief that we know a usable route has been empirically falsified,
                        // so the NEXT send should request a fresh one rather than retry links.
                        return giveUp(&state, dest, syncFailure: .linkFailed)
                    }
                    state.establishAttempts[dest] = attempts
                    let wasAwaitingPath = state.directLinks[dest] == .awaitingPath
                    state.directLinks[dest] = .establishing
                    let requestLink = Effect<Action>.merge(
                        startFallbackForQueued(&state, dest, attempts: attempts),
                        .send(.delegate(.requestLink(destinationHash: dest))))
                    // Leaving `.awaitingPath` ends the park, so the park timer must die with it.
                    // Cancelling HERE rather than in the calling case keeps the cancel adjacent to
                    // the state transition it pairs with, so any future caller that reaches
                    // establish() while parked is covered automatically. Today `learnedPath` is the
                    // only such caller (every other caller either requires `directLinks[dest] == nil`
                    // or nils it first), so this is defence-in-depth, not a live fix.
                    return wasAwaitingPath
                        ? .merge(requestLink, .cancel(id: CancelID.pathRequest(dest)))
                        : requestLink
                }
                state.directLinks[dest] = .awaitingPath
                return .merge(.send(.delegate(.requestPath(destinationHash: dest))), pathRequestTimer(dest))
            }
            /// The link to `dest` is gone. Drop it, and re-establish iff work remains. Shared by
            /// `.linkClosed` and `.pathLostAndClosed` — the only difference between them is whether
            /// `knownPaths` was cleared before this runs, which decides which branch `establish`
            /// takes.
            func closed(_ state: inout State, _ dest: Data) -> Effect<Action> {
                // The sync's state on its link closing. A sync still waiting for a link (it never
                // got one) re-establishes below and reports how; `giveUp` ends it at the ceiling.
                // Otherwise the link the sync ran on is gone: reference `clean_links`.
                let isPN = dest == state.outboundPropagationNode
                let syncWasWaiting = isPN && state.pendingDownloadFromPN
                defer {
                    if isPN {
                        if state.pendingDownloadFromPN { syncAwaitingLink(&state, dest) }
                        else if !syncWasWaiting { syncLinkClosed(&state) }
                    }
                }
                let orphaned = clearDirectLink(&state, dest)
                if state.hasLinkWork(for: dest) {
                    return .merge(orphaned, establish(&state, dest))
                }
                // No work left for this destination: the establishment saga is OVER, so its budget
                // ends with it. The other clearers are `.linkEstablished` (success) and `giveUp`
                // (the ceiling) — on the FAILURE path `giveUp` is the only one, and it is reachable
                // only while work still exists. So without this the counter is stranded at whatever
                // it had reached, and the NEXT message to this peer inherits a spent budget,
                // truncating or instantly failing a delivery that deserved a full allowance.
                //
                // `knownPaths` is deliberately NOT removed here. This is the ordinary healthy close,
                // where the path is fine and discarding it would be wrong. A caller that KNOWS the
                // route was falsified uses `.pathLostAndClosed` instead, which clears it first.
                //
                // That does mean a ceiling-stranded destination keeps a route five failed
                // establishments argued against — the same evidence `giveUp` cites when it DOES
                // discard — so the next message spends another full saga before reaching the
                // `requestPath` recovery. Accepted: distinguishing the two cases needs a
                // budget-aware condition here.
                //
                // Reachable with a NON-NIL budget whenever the establishment saga outlasts the work
                // that started it, so the final close arrives with nothing to do. Do not re-derive
                // that from saga durations — routing path-shaped failures into the park changed the
                // relative lengths, and the previous version of this sentence kept a conclusion
                // whose supporting arithmetic had been deleted. The durable statement is
                // STRUCTURAL: a `.handshakeRejected` cycle charges repeatedly while the retry saga
                // runs its own independent course, and an ordinary healthy close reaches here too.
                // `routerStaleEstablishBudgetDoesNotTruncateTheNextMessage` drives it.
                //
                // The zero-delay cascade this comment used to describe is GONE: a `.pathStale`
                // bounce from `BLEEndpoint.openLink` no longer re-enters `requestLink`, because
                // `LXMFNode` routes every path-shaped failure through `.pathLostAndClosed`, which
                // parks instead. A stale binding now costs ONE attempt, not the whole budget.
                state.establishAttempts[dest] = nil
                return orphaned
            }
            switch action {
            case let .rehydrateDedup(seenHashes, transientIds):
                // Insert hashes one by one through the RingSet's normal insert path.
                // Caller must supply oldest-first: the RingSet evicts at capacity, so insertion order
                // determines which hashes survive. Oldest-first ensures the newest 10 000 are retained,
                // matching what would have happened had the same inserts been live.
                for hash in seenHashes { state.seen.insert(hash) }
                state.downloadedTransientIds.formUnion(transientIds)
                return .none

            case let .learnedIdentity(destinationHash, identity):
                state.knownIdentities[destinationHash] = identity
                return .none

            case let .received(method, destinationHash, data):
                let reconstructed: LXMessage?
                switch method {
                case .opportunistic:
                    reconstructed = LXMessage.fromOpportunistic(destinationHash: destinationHash, payload: data)
                case .direct, .propagated:
                    // Both carry the full packed message, destination hash included: a link packet or
                    // Resource for `.direct`, a decrypted propagation entry for `.propagated`.
                    reconstructed = LXMessage.unpack(data)
                }
                guard let message = reconstructed else { return .none }   // malformed → drop
                // Addressing: a link packet or Resource, and a propagated download, each carry the
                // message's own destination hash, which must be ours; otherwise a link peer or a
                // propagation node could hand us a validly-signed message meant for someone else.
                // Reference `LXMRouter.lxmf_delivery` drops these only incidentally, when
                // `self.delivery_destinations[message.destination_hash]` (LXMRouter.py:1861, LXMF
                // 1.1.0) raises into its catch-all. An opportunistic message is rebuilt from the
                // packet's destination, which Transport only decrypts for us.
                if method != .opportunistic {
                    guard !destinationHash.isEmpty, message.destinationHash == destinationHash else {
                        return .send(.delegate(.messageRejected(hash: message.hash, reason: .notAddressedToUs)))
                    }
                }
                // A known sender's signature must verify. Deliberate departure from reference
                // `lxmf_delivery`, which delivers such a message flagged `signature_validated = False`:
                // a forgery would then show as the contact's. Unknown senders cannot be checked, so
                // they are delivered unvalidated (the app marks them). Both drops come BEFORE `seen`:
                // a forged copy arriving first must not make the genuine one look like a duplicate.
                let validated: Bool
                if let identity = state.knownIdentities[message.sourceHash] {
                    guard message.validateSignature(source: identity) else {
                        return .send(.delegate(.messageRejected(hash: message.hash, reason: .badSignature)))
                    }
                    validated = true
                } else {
                    validated = false
                }
                guard state.seen.insert(message.hash) else {
                    return .send(.delegate(.duplicateDropped(hash: message.hash)))
                }
                return .send(.delegate(.messageDelivered(message: message, signatureValidated: validated,
                                                         method: method)))

            case let .send(message, desiredMethod):
                state.withdrawnDeliveryCopies.remove(message.hash)
                state.withdrawnLinkCopies[message.hash] = nil
                // A cancelled message is never armed again, whichever path hands it over late. Nor is
                // a delivery copy abandoned in its stamp search: it was already reported over.
                guard !state.cancelledMessages.contains(message.hash),
                      !state.abandonedDeliveryCopies.contains(message.hash)
                else { return .none }
                let effective: DeliveryMethod =
                    (desiredMethod == .opportunistic && !message.opportunisticFits) ? .direct : desiredMethod
                switch effective {
                case .opportunistic:
                    let key = DeliveryKey.delivery(message.hash)
                    let resend = ResendInfo.opportunistic(destinationHash: message.destinationHash,
                                                          payload: message.opportunisticPayload)
                    if state.held { return armHeld(&state, key, resend) }
                    arm(&state, key, resend)
                    return .merge(.send(.delegate(.sendOpportunistic(destinationHash: message.destinationHash,
                                                                     payload: message.opportunisticPayload,
                                                                     messageHash: message.hash))),
                                  deliveryRetryTimer(state, key))
                case .direct:
                    let dest = message.destinationHash
                    if case let .active(linkID) = state.directLinks[dest] {
                        let key = DeliveryKey.delivery(message.hash)
                        let asResource = message.directRepresentation == .resource
                        let resend = ResendInfo.direct(destinationHash: dest, data: message.packed, asResource: asResource)
                        if state.held { return .merge(armHeld(&state, key, resend), idleTimer(dest, linkID)) }
                        arm(&state, key, resend)
                        if asResource {
                            return .merge(startOrQueueResource(&state, key, dest: dest, linkID: linkID),
                                          idleTimer(dest, linkID))
                        }
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: message.packed,
                                                                  asResource: false))),
                                      deliveryRetryTimer(state, key),
                                      idleTimer(dest, linkID))
                    }
                    state.outboundQueue[dest, default: []].append(message)
                    if state.directLinks[dest] == nil {
                        return establish(&state, dest)
                    }
                    return .none   // a link/path request is already in flight
                case .propagated:
                    // A propagated copy needs a packed propagation container, which `.send` cannot
                    // build; `.sendViaPropagation` is the entry point. Fail this copy rather than send
                    // it some other way.
                    return fail(&state, .delivery(message.hash))
                }

            case let .setOutboundPropagationNode(pn):
                state.outboundPropagationNode = pn
                return .none

            case let .sendViaPropagation(message, propagationPacked):
                state.pendingPropagatedCopies.remove(message.hash)       // handed over: armed or failed below
                guard !state.cancelledMessages.contains(message.hash) else { return .none }
                guard let pn = state.outboundPropagationNode else {
                    return fail(&state, .propagated(message.hash))
                }
                if case let .active(linkID) = state.directLinks[pn] {
                    let key = DeliveryKey.propagated(message.hash)
                    let resend = ResendInfo.propagated(destinationHash: pn, data: propagationPacked)
                    if state.held { return .merge(armHeld(&state, key, resend), idleTimer(pn, linkID)) }
                    arm(&state, key, resend)
                    if propagationPacked.count <= Link.mdu {
                        // Small container: send as a proof-requesting link packet. token = message.hash,
                        // and LXMFNode maps its packetDelivered back to THIS copy (leg .propagated).
                        return .merge(.send(.delegate(.sendPropagatedPacket(linkID: linkID,
                                                                            propagationPacked: propagationPacked,
                                                                            messageHash: message.hash))),
                                      deliveryRetryTimer(state, key),
                                      idleTimer(pn, linkID))
                    } else {
                        // Large container: send as Resource; its transfer decides the outcome.
                        return .merge(startOrQueueResource(&state, key, dest: pn, linkID: linkID),
                                      idleTimer(pn, linkID))
                    }
                }
                state.propagationQueue[pn, default: []].append(
                    PropagationItem(messageHash: message.hash, propagationPacked: propagationPacked))
                if state.directLinks[pn] == nil {
                    return establish(&state, pn)
                }
                return .none

            case .syncFromPropagationNode:
                guard let pn = state.outboundPropagationNode else { return .none }
                // A new request overwrites any state, a sticky failure included
                // (`request_messages_from_propagation_node`, LXMRouter.py:588-616).
                if case let .active(linkID) = state.directLinks[pn] {
                    state.propagationTransferState = .requestSent
                    return .send(.delegate(.requestMessageList(linkID: linkID)))
                }
                state.pendingDownloadFromPN = true
                if state.directLinks[pn] == nil {
                    // Set before `establish`, which may give up at once (a spent budget): the give-up
                    // must then see a state it can fail, not a sticky failure from the last sync.
                    state.propagationTransferState = state.knownPaths.contains(pn) ? .linkEstablishing : .pathRequested
                    let effect = establish(&state, pn)
                    if state.pendingDownloadFromPN { syncAwaitingLink(&state, pn) }
                    return effect
                }
                syncAwaitingLink(&state, pn)
                return .none

            case let .offeredMessageList(offered):
                guard !offered.isEmpty else {
                    // Empty offer: nothing to fetch, the sync is complete (LXMRouter.py:1815-1818).
                    state.propagationTransferState = .complete
                    state.propagationTransferLastResult = 0
                    return .none
                }
                let wants = offered.filter { !state.downloadedTransientIds.contains($0) }
                let haves = offered.filter { state.downloadedTransientIds.contains($0) }
                guard let pn = state.outboundPropagationNode,
                      case let .active(linkID) = state.directLinks[pn] else { return .none }  // link gone → abort
                return .send(.delegate(.requestMessages(linkID: linkID, wants: wants, haves: haves)))

            case let .messagesDownloaded(transientIds):
                state.downloadedTransientIds.formUnion(transientIds)
                // LXMRouter.py:1858-1861. The purge request `LXMFNode` sends next does not change it:
                // the link dropping before the purge lands goes from here to idle, not to a failure.
                state.propagationTransferState = .complete
                state.propagationTransferLastResult = transientIds.count
                return .none

            case let .syncError(error, linkID):
                // LXMRouter.py:1781-1791, 1820-1823, 1826-1836. `LXMFNode` tears down `linkID`, the link
                // the answer arrived on. The two PN error codes set their state, which the close that
                // follows keeps (it is above `complete`); anything else leaves it, so the close reports
                // `transferFailed`. Only an answer on the CURRENT propagation node's active link is the
                // sync's: an old PN's link answering after a switch must not mark the new one.
                guard let pn = state.outboundPropagationNode, state.directLinks[pn] == .active(linkID: linkID)
                else { return .none }
                switch error {
                case .noIdentity: state.propagationTransferState = .noIdentityReceived
                case .noAccess: state.propagationTransferState = .noAccess
                case .invalid: break
                }
                return .none

            case let .linkEstablished(dest, linkID):
                // Defensive (unreachable through `establish` today, which only runs with no active
                // link): a new link replacing a still-active one would otherwise strand the old
                // link's transfer — its `linkResourceInFlight` entry and its `.transferring` copy,
                // which no event names any more. Treat it as lost with that link.
                var orphaned: Effect<Action> = .none
                if case let .active(oldLink) = state.directLinks[dest], oldLink != linkID,
                   state.linkResourceInFlight[oldLink] != nil {
                    orphaned = orphanTransfer(&state, linkID: oldLink)
                }
                state.directLinks[dest] = .active(linkID: linkID)
                state.establishAttempts[dest] = nil
                // Defensive: if a link arrived while we were still parked in awaitingPath, cancel
                // the park timer — the park is over.
                let cancelPathTimer: Effect<Action> = .cancel(id: CancelID.pathRequest(dest))
                let queued = state.outboundQueue[dest] ?? []
                state.outboundQueue[dest] = nil
                let propQueued = state.propagationQueue[dest] ?? []
                state.propagationQueue[dest] = nil
                // Copies queued on a previous link go first; newly drained ones queue behind them.
                var effects: [Effect<Action>] = [orphaned, startNextQueued(&state, dest: dest)]
                for m in queued {
                    let key = DeliveryKey.delivery(m.hash)
                    let asResource = m.directRepresentation == .resource
                    arm(&state, key, .direct(destinationHash: dest, data: m.packed, asResource: asResource))
                    if asResource {
                        effects.append(startOrQueueResource(&state, key, dest: dest, linkID: linkID))
                    } else {
                        effects.append(.send(.delegate(.sendDirect(linkID: linkID, data: m.packed, asResource: false))))
                        effects.append(deliveryRetryTimer(state, key))
                    }
                }
                for item in propQueued {
                    let key = DeliveryKey.propagated(item.messageHash)
                    arm(&state, key, .propagated(destinationHash: dest, data: item.propagationPacked))
                    if item.propagationPacked.count <= Link.mdu {
                        effects.append(.send(.delegate(.sendPropagatedPacket(linkID: linkID,
                                                                              propagationPacked: item.propagationPacked,
                                                                              messageHash: item.messageHash))))
                        effects.append(deliveryRetryTimer(state, key))
                    } else {
                        effects.append(startOrQueueResource(&state, key, dest: dest, linkID: linkID))
                    }
                }
                // Always arm — not only when a queue was drained. A link re-established for a
                // still-pending delivery or a PN sync drains no queue, so the old "only if queued"
                // left it with no timer while the prior link's stale timer lived on (F5.2). The
                // cancelInFlight on CancelID.idle(dest) also cancels that stale timer here.
                effects.append(idleTimer(dest, linkID))
                if dest == state.outboundPropagationNode, state.pendingDownloadFromPN {
                    state.pendingDownloadFromPN = false
                    state.propagationTransferState = .requestSent
                    effects.append(.send(.delegate(.requestMessageList(linkID: linkID))))
                }
                effects.append(cancelPathTimer)
                return .merge(effects)

            case let .linkClosed(dest):
                return closed(&state, dest)

            case let .pathLostAndClosed(dest):
                // ONE reduction: forget the falsified route, then run the ordinary close. Because
                // both happen in a single pass, `closed`'s call to `establish` is guaranteed to see
                // the cleared `knownPaths` and take the park branch. Nothing can interleave between
                // the two halves — which is the entire reason this is one action and not two.
                state.knownPaths.remove(dest)
                return closed(&state, dest)

            case let .withdrawUnsentDeliveryCopy(hash):
                guard state.holdsUnsentDeliveryCopy(hash) else { return .none }
                state.withdrawnDeliveryCopies.insert(hash)
                var effects: [Effect<Action>] = []
                let key = DeliveryKey.delivery(hash)
                if state.pendingDeliveries.removeValue(forKey: key) != nil {
                    effects.append(.cancel(id: CancelID.retry(key)))
                }
                // A park or establishment for this destination is left alone: the `learnedPath` that
                // follows opens the link, and the stamped copy queues behind it when it comes back.
                for (dest, messages) in state.outboundQueue where messages.contains(where: { $0.hash == hash }) {
                    let rest = messages.filter { $0.hash != hash }
                    state.outboundQueue[dest] = rest.isEmpty ? nil : rest
                    state.withdrawnLinkCopies[hash] = dest
                }
                return .merge(effects)

            case let .learnedPath(dest):
                // Deliberately does NOT reset the establishment budget.
                //
                // There is no longer any invariant tying `establishAttempts` to `knownPaths`:
                // `.pathRequestDeadline` increments the budget for a destination that is by
                // definition NOT in `knownPaths` (it is parked in `.awaitingPath` precisely
                // because no path is known). So on reaching here the budget may be non-nil and
                // already partly spent by the PARK, not just by link attempts.
                //
                // That is exactly why a reset here would be wrong, and the argument no longer
                // depends on which branch spent the budget:
                //
                //  • The park and the link attempts deliberately SHARE one budget, so that a
                //    destination cannot alternate between the two establish branches and draw a
                //    fresh allowance from each. `learnedPath` is the very transition between
                //    those branches — resetting here would hand out that fresh allowance and
                //    reopen the unbounded cycle assembled from two bounded halves.
                //  • `knownPaths` is a bare Set with no epoch, so a live peer re-announcing on
                //    its normal period reaches here repeatedly; resetting would refresh the
                //    budget forever.
                //
                // Consequence to keep in mind (accepted, not a bug): a path learned late in the
                // park can arrive with the budget nearly or fully spent, so the destination may
                // give up with few or no link attempts. The bound is on the whole establishment
                // saga, not on either half.
                state.knownPaths.insert(dest)
                if state.directLinks[dest] == .awaitingPath {
                    // Route through establish() so there is exactly ONE counted emitter of
                    // requestLink. Behaviour is unchanged (knownPaths now contains dest, so
                    // establish takes the requestLink branch and sets .establishing).
                    // `establish` cancels the path-request park timer when transitioning from
                    // .awaitingPath to .establishing — no extra cancel needed here.
                    return establish(&state, dest)
                }
                return .none

            case let .delivered(hash, leg):
                return succeed(&state, DeliveryKey(messageHash: hash, leg: leg))

            case let .opportunisticDelivered(hash):
                return succeed(&state, .delivery(hash))

            case let .resourceDeliveredOnLink(linkID):
                guard let key = state.linkResourceInFlight[linkID] else { return .none }
                state.linkResourceInFlight[linkID] = nil
                var next: Effect<Action> = .none
                if let dest = destination(ofLink: linkID, state) { next = startNextQueued(&state, dest: dest) }
                return .merge(.send(.delivered(messageHash: key.messageHash, leg: key.leg)), next)

            case let .resourceFailedOnLink(linkID, rejected):
                // Reference `LXMessage.__resource_concluded` (LXMessage.py:597-606): REJECTED is
                // terminal; any other failure tears the link down and returns the message to
                // OUTBOUND, where the next pass counts an attempt after DELIVERY_RETRY_WAIT.
                guard let key = state.linkResourceInFlight.removeValue(forKey: linkID),
                      var pending = state.pendingDeliveries[key] else { return .none }
                if rejected {
                    // The link stays up (reference does not tear it down on REJECTED): next copy.
                    let failed = fail(&state, key, reason: .rejected)
                    var next: Effect<Action> = .none
                    if let dest = destination(ofLink: linkID, state) { next = startNextQueued(&state, dest: dest) }
                    return .merge(failed, next)
                }
                var close: Effect<Action> = .none
                if let dest = destination(ofLink: linkID, state) {
                    close = .merge(clearDirectLink(&state, dest), .send(.delegate(.closeLink(destinationHash: dest))))
                }
                // `attempts` counts transfers started: the `maxAttempts`-th failure is the last.
                refundIfHeld(state, &pending)
                guard pending.attempts < LXMFDelivery.maxAttempts else {
                    return .merge(close, fail(&state, key))
                }
                pending.phase = .retrying
                state.pendingDeliveries[key] = pending
                return .merge(close, deliveryRetryTimer(state, key))

            case let .cancelOutbound(hash):
                let hadWork = state.hasOutboundState(for: hash)
                state.cancelledMessages.insert(hash)
                state.withdrawnDeliveryCopies.remove(hash)
                let withdrawnFrom = state.withdrawnLinkCopies.removeValue(forKey: hash)
                state.pendingPropagatedCopies.remove(hash)
                state.fallbackEligible.remove(hash)
                guard hadWork else { return .none }
                var effects: [Effect<Action>] = []
                var freed: [Data] = []
                // Every destination this message's work named: one now without work, whose link is
                // still being established, is abandoned (below).
                var touched: [Data] = withdrawnFrom.map { [$0] } ?? []
                for leg in [Leg.delivery, .propagated] {
                    let key = DeliveryKey(messageHash: hash, leg: leg)
                    guard let pending = state.pendingDeliveries.removeValue(forKey: key) else { continue }
                    touched.append(pending.resend.destinationHash)
                    effects.append(.cancel(id: CancelID.retry(key)))
                    switch pending.phase {
                    case .retrying:
                        break
                    case .queued:
                        for (dest, keys) in state.resourceQueue where keys.contains(key) {
                            let rest = keys.filter { $0 != key }
                            state.resourceQueue[dest] = rest.isEmpty ? nil : rest
                        }
                    case .transferring:
                        guard let linkID = state.linkResourceInFlight.first(where: { $0.value == key })?.key
                        else { break }
                        state.linkResourceInFlight[linkID] = nil
                        effects.append(.send(.delegate(.cancelResource(linkID: linkID))))
                        if let dest = destination(ofLink: linkID, state) { freed.append(dest) }
                    }
                }
                for (dest, messages) in state.outboundQueue where messages.contains(where: { $0.hash == hash }) {
                    let rest = messages.filter { $0.hash != hash }
                    state.outboundQueue[dest] = rest.isEmpty ? nil : rest
                    touched.append(dest)
                }
                for (dest, items) in state.propagationQueue where items.contains(where: { $0.messageHash == hash }) {
                    let rest = items.filter { $0.messageHash != hash }
                    state.propagationQueue[dest] = rest.isEmpty ? nil : rest
                    touched.append(dest)
                }
                for dest in Set(touched).sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                    effects.append(abandonIfIdle(state, dest))
                }
                // A message one of whose copies already succeeded has had its terminal outcome
                // (`deliveryConfirmed` / `propagationAccepted`): the remaining copy is torn down
                // above, silently — reporting `deliveryCancelled` after a success would be a second,
                // contradictory terminal.
                if !state.succeededMessages.contains(hash) {
                    effects.append(.send(.delegate(.deliveryCancelled(messageHash: hash))))
                }
                // The cancel reaches the link (above) before the next copy starts on it (below).
                for dest in freed { effects.append(startNextQueued(&state, dest: dest)) }
                return .merge(effects)

            case let .linkActivity(linkID):
                guard let dest = destination(ofLink: linkID, state) else { return .none }
                return idleTimer(dest, linkID)

            case let .propagatedCopyPending(hash):
                state.markPropagatedCopyPending(hash)
                return .none

            case let .markFallbackEligible(hash):
                state.fallbackEligible.insert(hash)
                return .none

            case let .deliveryCopyAbandoned(hash):
                // Eligibility goes first, so `fail` hands off nothing: the app stopped this work.
                state.fallbackEligible.remove(hash)
                state.withdrawnDeliveryCopies.remove(hash)
                let withdrawnFrom = state.withdrawnLinkCopies.removeValue(forKey: hash)
                state.abandonedDeliveryCopies.insert(hash)
                // A copy withdrawn from behind a link may have been that link's last work.
                let failed = fail(&state, .delivery(hash))
                return .merge(failed, withdrawnFrom.map { abandonIfIdle(state, $0) } ?? .none)

            case let .propagatedCopyFailed(hash):
                // A cancel (or an abandon) that got here first already settled this copy.
                guard state.pendingPropagatedCopies.contains(hash) else { return .none }
                return fail(&state, .propagated(hash))

            case let .propagatedCopyRefused(hash, reason):
                // Never started, so there is nothing to fail: the delivery copy's own outcome decides
                // the message. Running `fail` here could report `deliveryFailed` while the delivery copy
                // is still in ITS stamp search, which the router cannot see.
                state.pendingPropagatedCopies.remove(hash)
                return .send(.delegate(.propagationRefused(messageHash: hash, reason: reason)))

            case let .abandonPendingPropagatedCopies(stillSearching):
                let abandoned = state.pendingPropagatedCopies.sorted { $0.lexicographicallyPrecedes($1) }
                state.pendingPropagatedCopies = []
                var effects: [Effect<Action>] = []
                // A delivery copy still searching its stamp is invisible to `fail`'s outstanding
                // check, so failing here would report `deliveryFailed` and then, once that copy is
                // handed over and confirmed, a second terminal.
                for hash in abandoned where !stillSearching.contains(hash) {
                    effects.append(fail(&state, .propagated(hash)))
                }
                return .merge(effects)

            case let .retryDue(hash, leg):
                let key = DeliveryKey(messageHash: hash, leg: leg)
                guard var pending = state.pendingDeliveries[key] else { return .none }
                // Only a `.retrying` copy has a timer. One whose Resource is in flight (or queued
                // behind one) is decided by its transfer, so a stray retry must not count or resend.
                guard pending.phase == .retrying else { return .none }
                // Held: wait again (at `deliveryRetryTimer`'s wait), counting and sending nothing.
                // The release fires this at once if the copy can transmit.
                guard !state.held else { return deliveryRetryTimer(state, key) }
                pending.attempts += 1
                if pending.attempts > LXMFDelivery.maxAttempts {
                    return fail(&state, key)
                }
                state.pendingDeliveries[key] = pending
                // A stalled delivery copy hands off to the propagation node, and keeps retrying (A2).
                let handOff = leg == .delivery && pending.attempts >= LXMFDelivery.propagationFallbackAfterAttempts
                    ? startFallbackIfEligible(&state, hash) : .none
                return .merge(handOff, resend(&state, key, pending.resend))

            case let .idleDeadline(dest, linkID):
                // Close ONLY the link this timer was armed for. A stale timer from a prior link on
                // this dest (or one that fired in the close→re-establish gap) finds a different
                // linkID — or none — and no-ops (F5.2).
                guard case let .active(current) = state.directLinks[dest], current == linkID
                else { return .none }
                let orphaned = clearDirectLink(&state, dest)
                return .merge(orphaned, .send(.delegate(.closeLink(destinationHash: dest))))

            case let .pathRequestDeadline(dest):
                // The park timer fired: the path response never arrived (or was rejected by
                // shouldReplace). Reuse `establishAttempts` — the park is part of the same
                // establishment saga, so the destination cannot get a fresh budget by alternating
                // between the requestLink branch and the awaitingPath branch.
                guard state.directLinks[dest] == .awaitingPath else { return .none }
                // Held: park again, counting and requesting nothing. The release re-establishes.
                guard !state.held else { return pathRequestTimer(dest) }
                let attempts = (state.establishAttempts[dest] ?? 0) + 1
                if attempts > LXMFDelivery.maxAttempts {
                    return giveUp(&state, dest, syncFailure: .noPath)
                }
                state.establishAttempts[dest] = attempts
                return .merge(startFallbackForQueued(&state, dest, attempts: attempts),
                              .send(.delegate(.requestPath(destinationHash: dest))), pathRequestTimer(dest))

            case let .setHold(held):
                let wasHeld = state.held
                state.held = held
                // Only a release ends a hold. The app may release on every reconnect, and firing
                // every retry then would resend early and spend an attempt each time.
                guard wasHeld, !held else { return .none }
                // Resume where the hold stopped: establishment the hold deferred, then a retry now
                // for every copy that can transmit, from its stored attempt count (spec Amendment A3).
                // A link copy whose link is gone is re-armed at its normal wait instead: firing it
                // would count an attempt that `resend` cannot send, once per suspension.
                var effects: [Effect<Action>] = []
                for dest in state.destinationsAwaitingLinks { effects.append(establish(&state, dest)) }
                let retrying = state.pendingDeliveries.filter { $0.value.phase == .retrying }
                let due = retrying.keys.sorted {
                    $0.messageHash == $1.messageHash
                        ? $0.leg == .delivery
                        : $0.messageHash.lexicographicallyPrecedes($1.messageHash)
                }
                for key in due {
                    guard let resend = retrying[key]?.resend else { continue }
                    var canTransmit = false
                    if case .opportunistic = resend { canTransmit = true }
                    if case .active = state.directLinks[resend.destinationHash] { canTransmit = true }
                    if canTransmit {
                        effects.append(.concatenate(.cancel(id: CancelID.retry(key)),
                                                    .send(.retryDue(messageHash: key.messageHash, leg: key.leg))))
                    } else {
                        effects.append(deliveryRetryTimer(state, key))
                    }
                }
                return .merge(effects)

            case .delegate:
                return .none
            }
        }
    }
}

extension LXMFRouter.State {
    /// Whether the router holds any outbound work for `messageHash`: a pending copy in any phase, or
    /// a message queued behind link establishment. `cancelOutbound` reports `deliveryCancelled` only
    /// when this is true; `LXMFNode` reports it itself when the only work was a delivery stamp search.
    func hasOutboundState(for messageHash: Data) -> Bool {
        pendingDeliveries.keys.contains { $0.messageHash == messageHash }
            || outboundQueue.values.contains { $0.contains { $0.hash == messageHash } }
            || propagationQueue.values.contains { $0.contains { $0.messageHash == messageHash } }
            || pendingPropagatedCopies.contains(messageHash)
            || withdrawnDeliveryCopies.contains(messageHash)
    }

    /// Every message hash `hasOutboundState(for:)` is true for, built in one pass, so a caller asking
    /// about many messages pays O(outbound work) once instead of per message. Keep the two in step.
    func outboundMessageHashes() -> Set<Data> {
        var hashes = Set(pendingDeliveries.keys.map(\.messageHash))
        for queued in outboundQueue.values { hashes.formUnion(queued.map(\.hash)) }
        for queued in propagationQueue.values { hashes.formUnion(queued.map(\.messageHash)) }
        hashes.formUnion(pendingPropagatedCopies)
        hashes.formUnion(withdrawnDeliveryCopies)
        return hashes
    }

    /// Whether this router holds the delivery copy of `messageHash` and can give it back: queued
    /// behind a link that is not up (so not transmitted), or armed as an opportunistic copy.
    ///
    /// The opportunistic case relies on the caller. That copy went out at once when it was handed
    /// over, and each retry sends it again once a path is known; Transport drops every such send to
    /// a destination it has not learned. `LXMFNode` only asks for a copy it handed over while the
    /// destination was unlearned, and only at the first announce since, so none of it left the node.
    /// A link copy already armed (sent on an active link) or transferring is never given back.
    func holdsUnsentDeliveryCopy(_ messageHash: Data) -> Bool {
        if let pending = pendingDeliveries[.delivery(messageHash)] {
            if case .opportunistic = pending.resend { return true }
            return false
        }
        return outboundQueue.values.contains { $0.contains { $0.hash == messageHash } }
    }

    /// Whether `dest` has work that needs a link to it: a pending direct or propagated copy, a queued
    /// message (or one withdrawn from that queue to be re-stamped), or an outstanding sync.
    ///
    /// A closed link with work re-establishes; one without it ends its retry budget.
    func hasLinkWork(for dest: Data) -> Bool {
        let hasPending = pendingDeliveries.values.contains {
            switch $0.resend {
            case let .direct(d, _, _): return d == dest
            case let .propagated(d, _): return d == dest
            case .opportunistic: return false
            }
        }
        let hasQueued = !(outboundQueue[dest]?.isEmpty ?? true)
            || !(propagationQueue[dest]?.isEmpty ?? true)
            || withdrawnLinkCopies.values.contains(dest)
        // An outstanding sync is work too. `pendingDownloadFromPN` is only cleared when the
        // `.linkEstablished` case actually drains it into `requestMessageList` (see that
        // case; deliberately not a line number — this citation has drifted three times), so
        // if it is still set here the sync never happened — without this the PN link would un-wedge
        // but never retry, since a bare `syncFromPropagationNode` queues no message and arms
        // no timer. Bounded by `establish()`'s budget like any other destination.
        let hasPendingSync = dest == outboundPropagationNode && pendingDownloadFromPN
        return hasPending || hasQueued || hasPendingSync
    }

    /// Destinations with link work and no link under way (none, or parked awaiting a path): those a
    /// hold deferred, which its release re-establishes. Sorted, so the release's effects are ordered.
    var destinationsAwaitingLinks: [Data] {
        var candidates = Set(outboundQueue.keys).union(propagationQueue.keys)
        candidates.formUnion(pendingDeliveries.values.map(\.resend.destinationHash))
        if pendingDownloadFromPN, let pn = outboundPropagationNode { candidates.insert(pn) }
        return candidates
            .filter { (directLinks[$0] == nil || directLinks[$0] == .awaitingPath) && hasLinkWork(for: $0) }
            .sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// Mark `hash`'s propagated copy pending — UNLESS the message is cancelled, in which case there
    /// is nothing to mark. (A deliberate re-send from the app is not cancelled: `LXMFNode` calls
    /// `uncancel` before this.) A cancelled message must not be revived (the
    /// router holds no delivery copy for it either, so marking it pending here would make
    /// `hasOutboundState` report work that doesn't exist, and a later `abandonPendingPropagatedCopies`
    /// would `fail` it into a stray `deliveryFailed` with no preceding send).
    ///
    /// The ONE place this rule is applied: `.propagatedCopyPending` goes through here. (A fallback's
    /// copy is marked by `startFallbackIfEligible` instead, which a cancel has already disarmed.)
    mutating func markPropagatedCopyPending(_ hash: Data) {
        guard !cancelledMessages.contains(hash) else { return }
        pendingPropagatedCopies.insert(hash)
    }

    /// The app is sending `hash` afresh: forget that it was cancelled, so this send is an ordinary
    /// send. `LXMFNode`'s app-facing send actions call this FIRST, synchronously. The guards on
    /// `cancelledMessages` exist for LATE hand-overs from a cancelled attempt's stamp search, not
    /// for a deliberate re-send, which they would otherwise swallow (the row stuck on "sending").
    mutating func uncancel(_ hash: Data) {
        cancelledMessages.remove(hash)
        abandonedDeliveryCopies.remove(hash)
        confirmedDeliveryCopies.remove(hash)
    }
}

extension LXMFRouter.ResendInfo {
    /// The destination this copy is addressed to: the recipient, or the propagation node.
    var destinationHash: Data {
        switch self {
        case let .opportunistic(destinationHash, _): return destinationHash
        case let .direct(destinationHash, _, _): return destinationHash
        case let .propagated(destinationHash, _): return destinationHash
        }
    }
}
