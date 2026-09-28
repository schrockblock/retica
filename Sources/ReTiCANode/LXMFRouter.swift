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
        /// Message hashes the app cancelled. A copy of one handed over later (a stamp search that
        /// finished after the cancel) is never armed. Bounded like `succeededMessages`.
        var cancelledMessages = RingSet(capacity: LXMFRouter.succeededMessageMemory)
        /// Message hashes whose propagated copy is still in `LXMFNode`'s stamp search, so not yet
        /// handed over. `isOutstanding` counts them: without this, the delivery copy running out first
        /// reported `deliveryFailed` for a message whose propagated copy was about to go out
        /// (2026-09-26 single-packet proofs spec, Amendment 3).
        public var pendingPropagatedCopies: Set<Data> = []
        /// sourceHash (sender's lxmf.delivery destination hash) → identity, for signature validation.
        public var knownIdentities: [Data: Identity] = [:]
        /// destinationHash → direct-link state (reuse an active link, or one being established).
        public var directLinks: [Data: LinkStatus] = [:]
        /// destinationHash → we have a learned path to it. Gates direct-link establishment: with no
        /// path, request one first (RNS process_outbound, LXMRouter.py:2829-2838).
        public var knownPaths: Set<Data> = []
        /// destinationHash → messages queued until a direct link to it becomes active.
        var outboundQueue: [Data: [LXMessage]] = [:]
        /// (message.hash, copy) → in-flight send awaiting a delivery outcome (with its resend info +
        /// attempts). Keyed per COPY because `LXMFNode.sendMessage(alsoViaPropagation:)` arms a
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
        /// to fail, so it terminates silently — the flag is cleared but the app is not told. See the
        /// give-up branch.
        ///
        /// Reset on `linkEstablished` — the one event that proves the destination is
        /// reachable again. Deliberately NOT reset on `learnedPath`; see that case for why a
        /// re-announce must not refresh the budget, and for the invariant tying this map to
        /// `knownPaths`.
        public var establishAttempts: [Data: Int] = [:]
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
    public struct PropagationItem: Equatable { public var messageHash: Data; public var propagationPacked: Data }

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
        case received(method: DeliveryMethod, destinationHash: Data, data: Data)
        case send(message: LXMessage, desiredMethod: DeliveryMethod)
        case setOutboundPropagationNode(Data?)
        case sendViaPropagation(message: LXMessage, propagationPacked: Data)
        case syncFromPropagationNode
        case offeredMessageList(transientIds: [Data])
        case messagesDownloaded(transientIds: [Data])
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
        /// A receipt for one copy of a message. The copy is named by the path that produced the
        /// receipt, never inferred from which copy was armed last.
        case delivered(messageHash: Data, leg: Leg)
        /// A single-packet proof arrived for one of this message's opportunistic packets (Transport
        /// `singlePacketDelivered`, token = message hash). Confirms the DELIVERY copy.
        case opportunisticDelivered(messageHash: Data)
        case resourceDeliveredOnLink(linkID: Data)
        /// The Resource in flight on `linkID` failed. `rejected`: the peer refused it (terminal).
        /// Otherwise the link is closed and the copy retried once, `retryWaitSeconds` later.
        case resourceFailedOnLink(linkID: Data, rejected: Bool)
        /// The app cancelled this message: drop every copy, cancel a Resource in flight, report
        /// `deliveryCancelled` once. Reference `LXMRouter.cancel_outbound` (LXMRouter.py:1719-1744).
        case cancelOutbound(messageHash: Data)
        /// Resource traffic on `linkID` (either direction). Re-arms the idle timer of the
        /// destination it serves, so a long transfer never trips `linkMaxInactivitySeconds` (spec §5).
        case linkActivity(linkID: Data)
        /// `LXMFNode` started the stamp search for this message's propagated copy.
        case propagatedCopyPending(messageHash: Data)
        /// `LXMFNode` did not start this message's propagated copy at all (spec §6).
        case propagatedCopyRefused(messageHash: Data, reason: RefusalReason)
        /// Every propagated-copy stamp search was cancelled: those copies have failed.
        case abandonPendingPropagatedCopies
        case retryDue(messageHash: Data, leg: Leg)
        case idleDeadline(destinationHash: Data, linkID: Data)
        case pathRequestDeadline(destinationHash: Data)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case messageDelivered(message: LXMessage, signatureValidated: Bool, method: DeliveryMethod)
            case duplicateDropped(hash: Data)
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
        }
    }

    public init() {}

    /// How many recently-succeeded message hashes `succeededMessages` remembers. A copy that fails
    /// more than this many successes later could be reported failed; far beyond any retry saga.
    static let succeededMessageMemory = 1024

    public var body: some ReducerOf<Self> {
        Reduce { [clock] state, action in
            func retryTimer(_ key: DeliveryKey, _ seconds: Int) -> Effect<Action> {
                .run { send in
                    try await clock.sleep(for: .seconds(seconds))
                    await send(.retryDue(messageHash: key.messageHash, leg: key.leg))
                }.cancellable(id: CancelID.retry(key), cancelInFlight: true)
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
            /// too, so at `maxAttempts` it fails the copy outright rather than arming a sixth.
            func orphanTransfer(_ state: inout State, linkID: Data) -> Effect<Action> {
                guard let key = state.linkResourceInFlight.removeValue(forKey: linkID),
                      state.pendingDeliveries[key]?.phase == .transferring else { return .none }
                guard let attempts = state.pendingDeliveries[key]?.attempts,
                      attempts < LXMFDelivery.maxAttempts else {
                    return fail(&state, key)
                }
                state.pendingDeliveries[key]?.phase = .retrying
                return retryTimer(key, LXMFDelivery.retryWaitSeconds)
            }
            /// One copy of a message was confirmed: settle that copy only, stop its retries, remember
            /// the success, and report the outcome that copy stands for. A receipt for a copy no
            /// longer pending is ignored.
            func succeed(_ state: inout State, _ key: DeliveryKey) -> Effect<Action> {
                guard state.pendingDeliveries[key] != nil else { return .none }
                state.pendingDeliveries[key] = nil
                state.succeededMessages.insert(key.messageHash)
                let outcome: Action.Delegate = key.leg == .propagated
                    ? .propagationAccepted(messageHash: key.messageHash)
                    : .deliveryConfirmed(messageHash: key.messageHash)
                return .merge(.cancel(id: CancelID.retry(key)), .send(.delegate(outcome)))
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
                    return state.outboundQueue.values.contains { $0.contains { $0.hash == hash } }
                case .propagated:
                    return state.pendingPropagatedCopies.contains(hash)
                        || state.propagationQueue.values.contains { $0.contains { $0.messageHash == hash } }
                }
            }
            /// One copy of a message has failed for good. `deliveryFailed` is reported only when no
            /// other copy can still succeed and none already did (spec §3). Every router failure path
            /// goes through here. (Accepted gap: `LXMFNode`'s `.cancelDeliveryStamps` emits
            /// `deliveryFailed` itself and bypasses this helper.)
            func fail(_ state: inout State, _ key: DeliveryKey, reason: FailureReason = .exhausted) -> Effect<Action> {
                state.pendingDeliveries[key] = nil
                if key.leg == .propagated { state.pendingPropagatedCopies.remove(key.messageHash) }
                let other: Leg = key.leg == .delivery ? .propagated : .delivery
                guard !isOutstanding(state, key.messageHash, other),
                      !state.succeededMessages.contains(key.messageHash)
                else { return .none }
                // The terminal outcome carries the reason of the copy that ended the message.
                let outcome: Action.Delegate = reason == .rejected
                    ? .deliveryRejected(messageHash: key.messageHash)
                    : .deliveryFailed(messageHash: key.messageHash)
                return .send(.delegate(outcome))
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
            func giveUp(_ state: inout State, _ dest: Data) -> Effect<Action> {
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
                if dest == state.outboundPropagationNode { state.pendingDownloadFromPN = false }
                var effects: [Effect<Action>] = [orphaned, .cancel(id: CancelID.pathRequest(dest))]
                for message in queued { effects.append(fail(&state, .delivery(message.hash))) }
                for item in propQueued { effects.append(fail(&state, .propagated(item.messageHash))) }
                // Resource copies waiting for this destination's link have no timer of their own.
                for key in state.resourceQueue.removeValue(forKey: dest) ?? [] where state.pendingDeliveries[key] != nil {
                    effects.append(fail(&state, key))
                }
                return .merge(effects)
            }
            func establish(_ state: inout State, _ dest: Data) -> Effect<Action> {
                if state.knownPaths.contains(dest) {
                    let attempts = (state.establishAttempts[dest] ?? 0) + 1
                    if attempts > LXMFDelivery.maxAttempts {
                        // Give up on this destination: fail everything queued for it, and forget the
                        // path — our belief that we know a usable route has been empirically falsified,
                        // so the NEXT send should request a fresh one rather than retry links.
                        return giveUp(&state, dest)
                    }
                    state.establishAttempts[dest] = attempts
                    let wasAwaitingPath = state.directLinks[dest] == .awaitingPath
                    state.directLinks[dest] = .establishing
                    let requestLink = Effect<Action>.send(.delegate(.requestLink(destinationHash: dest)))
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
                let orphaned = clearDirectLink(&state, dest)
                let hasPending = state.pendingDeliveries.values.contains {
                    switch $0.resend {
                    case let .direct(d, _, _): return d == dest
                    case let .propagated(d, _): return d == dest
                    case .opportunistic: return false
                    }
                }
                let hasQueued = !(state.outboundQueue[dest]?.isEmpty ?? true)
                    || !(state.propagationQueue[dest]?.isEmpty ?? true)
                // An outstanding sync is work too. `pendingDownloadFromPN` is only cleared when the
                // `.linkEstablished` case actually drains it into `requestMessageList` (see that
                // case; deliberately not a line number — this citation has drifted three times), so
                // if it is still set here the sync never happened — without this the PN link would un-wedge
                // but never retry, since a bare `syncFromPropagationNode` queues no message and arms
                // no timer. Bounded by `establish()`'s budget like any other destination.
                let hasPendingSync = dest == state.outboundPropagationNode && state.pendingDownloadFromPN
                if hasPending || hasQueued || hasPendingSync {
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
                guard state.seen.insert(message.hash) else {
                    return .send(.delegate(.duplicateDropped(hash: message.hash)))
                }
                let validated = state.knownIdentities[message.sourceHash]
                    .map { message.validateSignature(source: $0) } ?? false
                return .send(.delegate(.messageDelivered(message: message, signatureValidated: validated,
                                                         method: method)))

            case let .send(message, desiredMethod):
                // A cancelled message is never armed again, whichever path hands it over late.
                guard !state.cancelledMessages.contains(message.hash) else { return .none }
                let effective: DeliveryMethod =
                    (desiredMethod == .opportunistic && !message.opportunisticFits) ? .direct : desiredMethod
                switch effective {
                case .opportunistic:
                    let key = DeliveryKey.delivery(message.hash)
                    let resend = ResendInfo.opportunistic(destinationHash: message.destinationHash,
                                                          payload: message.opportunisticPayload)
                    arm(&state, key, resend)
                    return .merge(.send(.delegate(.sendOpportunistic(destinationHash: message.destinationHash,
                                                                     payload: message.opportunisticPayload,
                                                                     messageHash: message.hash))),
                                  retryTimer(key, LXMFDelivery.retryWaitSeconds))
                case .direct:
                    let dest = message.destinationHash
                    if case let .active(linkID) = state.directLinks[dest] {
                        let key = DeliveryKey.delivery(message.hash)
                        let asResource = message.directRepresentation == .resource
                        arm(&state, key, .direct(destinationHash: dest, data: message.packed, asResource: asResource))
                        if asResource {
                            return .merge(startOrQueueResource(&state, key, dest: dest, linkID: linkID),
                                          idleTimer(dest, linkID))
                        }
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: message.packed,
                                                                  asResource: false))),
                                      retryTimer(key, LXMFDelivery.retryWaitSeconds),
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
                    arm(&state, key, .propagated(destinationHash: pn, data: propagationPacked))
                    if propagationPacked.count <= Link.mdu {
                        // Small container: send as a proof-requesting link packet. token = message.hash,
                        // and LXMFNode maps its packetDelivered back to THIS copy (leg .propagated).
                        return .merge(.send(.delegate(.sendPropagatedPacket(linkID: linkID,
                                                                            propagationPacked: propagationPacked,
                                                                            messageHash: message.hash))),
                                      retryTimer(key, LXMFDelivery.retryWaitSeconds),
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
                if case let .active(linkID) = state.directLinks[pn] {
                    return .send(.delegate(.requestMessageList(linkID: linkID)))
                }
                state.pendingDownloadFromPN = true
                if state.directLinks[pn] == nil {
                    return establish(&state, pn)
                }
                return .none

            case let .offeredMessageList(offered):
                guard !offered.isEmpty else { return .none }            // empty offer → nothing to fetch
                let wants = offered.filter { !state.downloadedTransientIds.contains($0) }
                let haves = offered.filter { state.downloadedTransientIds.contains($0) }
                guard let pn = state.outboundPropagationNode,
                      case let .active(linkID) = state.directLinks[pn] else { return .none }  // link gone → abort
                return .send(.delegate(.requestMessages(linkID: linkID, wants: wants, haves: haves)))

            case let .messagesDownloaded(transientIds):
                state.downloadedTransientIds.formUnion(transientIds)
                return .none

            case let .linkEstablished(dest, linkID):
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
                var effects: [Effect<Action>] = [startNextQueued(&state, dest: dest)]
                for m in queued {
                    let key = DeliveryKey.delivery(m.hash)
                    let asResource = m.directRepresentation == .resource
                    arm(&state, key, .direct(destinationHash: dest, data: m.packed, asResource: asResource))
                    if asResource {
                        effects.append(startOrQueueResource(&state, key, dest: dest, linkID: linkID))
                    } else {
                        effects.append(.send(.delegate(.sendDirect(linkID: linkID, data: m.packed, asResource: false))))
                        effects.append(retryTimer(key, LXMFDelivery.retryWaitSeconds))
                    }
                }
                for item in propQueued {
                    let key = DeliveryKey.propagated(item.messageHash)
                    arm(&state, key, .propagated(destinationHash: dest, data: item.propagationPacked))
                    if item.propagationPacked.count <= Link.mdu {
                        effects.append(.send(.delegate(.sendPropagatedPacket(linkID: linkID,
                                                                              propagationPacked: item.propagationPacked,
                                                                              messageHash: item.messageHash))))
                        effects.append(retryTimer(key, LXMFDelivery.retryWaitSeconds))
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
                guard pending.attempts < LXMFDelivery.maxAttempts else {
                    return .merge(close, fail(&state, key))
                }
                pending.phase = .retrying
                state.pendingDeliveries[key] = pending
                return .merge(close, retryTimer(key, LXMFDelivery.retryWaitSeconds))

            case let .cancelOutbound(hash):
                let hadWork = state.hasOutboundState(for: hash)
                state.cancelledMessages.insert(hash)
                state.pendingPropagatedCopies.remove(hash)
                guard hadWork else { return .none }
                var effects: [Effect<Action>] = []
                var freed: [Data] = []
                for leg in [Leg.delivery, .propagated] {
                    let key = DeliveryKey(messageHash: hash, leg: leg)
                    guard let pending = state.pendingDeliveries.removeValue(forKey: key) else { continue }
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
                }
                for (dest, items) in state.propagationQueue where items.contains(where: { $0.messageHash == hash }) {
                    let rest = items.filter { $0.messageHash != hash }
                    state.propagationQueue[dest] = rest.isEmpty ? nil : rest
                }
                effects.append(.send(.delegate(.deliveryCancelled(messageHash: hash))))
                // The cancel reaches the link (above) before the next copy starts on it (below).
                for dest in freed { effects.append(startNextQueued(&state, dest: dest)) }
                return .merge(effects)

            case let .linkActivity(linkID):
                guard let dest = destination(ofLink: linkID, state) else { return .none }
                return idleTimer(dest, linkID)

            case let .propagatedCopyPending(hash):
                guard !state.cancelledMessages.contains(hash) else { return .none }
                state.pendingPropagatedCopies.insert(hash)
                return .none

            case let .propagatedCopyRefused(hash, reason):
                // Never started, so there is nothing to fail: the delivery copy's own outcome decides
                // the message. Running `fail` here could report `deliveryFailed` while the delivery copy
                // is still in ITS stamp search, which the router cannot see.
                state.pendingPropagatedCopies.remove(hash)
                return .send(.delegate(.propagationRefused(messageHash: hash, reason: reason)))

            case .abandonPendingPropagatedCopies:
                let abandoned = state.pendingPropagatedCopies.sorted { $0.lexicographicallyPrecedes($1) }
                state.pendingPropagatedCopies = []
                var effects: [Effect<Action>] = []
                for hash in abandoned { effects.append(fail(&state, .propagated(hash))) }
                return .merge(effects)

            case let .retryDue(hash, leg):
                let key = DeliveryKey(messageHash: hash, leg: leg)
                guard var pending = state.pendingDeliveries[key] else { return .none }
                // Only a `.retrying` copy has a timer. One whose Resource is in flight (or queued
                // behind one) is decided by its transfer, so a stray retry must not count or resend.
                guard pending.phase == .retrying else { return .none }
                pending.attempts += 1
                if pending.attempts > LXMFDelivery.maxAttempts {
                    return fail(&state, key)
                }
                state.pendingDeliveries[key] = pending
                switch pending.resend {
                case let .opportunistic(destinationHash, payload):
                    if !state.knownPaths.contains(destinationHash) {
                        // Pathless opportunistic retry: request a path instead of resending, and wait longer.
                        return .merge(.send(.delegate(.requestPath(destinationHash: destinationHash))),
                                      retryTimer(key, LXMFDelivery.pathRequestWaitSeconds))
                    }
                    return .merge(.send(.delegate(.sendOpportunistic(destinationHash: destinationHash, payload: payload,
                                                                     messageHash: hash))),
                                  retryTimer(key, LXMFDelivery.retryWaitSeconds))
                case let .direct(destinationHash, data, asResource):
                    if case let .active(linkID) = state.directLinks[destinationHash] {
                        if asResource { return startOrQueueResource(&state, key, dest: destinationHash, linkID: linkID) }
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: false))),
                                      retryTimer(key, LXMFDelivery.retryWaitSeconds))
                    }
                    // Link is down or re-establishing: no live link to send on. Wait and re-check; the
                    // attempt was already counted, so the saga stays bounded by maxAttempts.
                    return retryTimer(key, LXMFDelivery.retryWaitSeconds)
                case let .propagated(destinationHash, data):
                    if case let .active(linkID) = state.directLinks[destinationHash] {
                        if data.count <= Link.mdu {
                            return .merge(.send(.delegate(.sendPropagatedPacket(linkID: linkID,
                                                                                propagationPacked: data,
                                                                                messageHash: hash))),
                                          retryTimer(key, LXMFDelivery.retryWaitSeconds))
                        } else {
                            return startOrQueueResource(&state, key, dest: destinationHash, linkID: linkID)
                        }
                    }
                    // Link down/re-establishing: no live link; wait and re-check (bounded by maxAttempts).
                    return retryTimer(key, LXMFDelivery.retryWaitSeconds)
                }

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
                let attempts = (state.establishAttempts[dest] ?? 0) + 1
                if attempts > LXMFDelivery.maxAttempts {
                    return giveUp(&state, dest)
                }
                state.establishAttempts[dest] = attempts
                return .merge(.send(.delegate(.requestPath(destinationHash: dest))), pathRequestTimer(dest))

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
    public func hasOutboundState(for messageHash: Data) -> Bool {
        pendingDeliveries.keys.contains { $0.messageHash == messageHash }
            || outboundQueue.values.contains { $0.contains { $0.hash == messageHash } }
            || propagationQueue.values.contains { $0.contains { $0.messageHash == messageHash } }
            || pendingPropagatedCopies.contains(messageHash)
    }
}
