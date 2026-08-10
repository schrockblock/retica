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
    private enum CancelID: Hashable { case retry(Data); case idle(Data); case pathRequest(Data) }

    @ObservableState
    public struct State: Equatable {
        /// Dedup of already-delivered LXMF message IDs (`message.hash`). Bounded (RNS uses age-based
        /// expiry; a bounded ring is the LXMF-4a approximation).
        var seen = RingSet(capacity: 10_000)
        /// sourceHash (sender's lxmf.delivery destination hash) → identity, for signature validation.
        public var knownIdentities: [Data: Identity] = [:]
        /// destinationHash → direct-link state (reuse an active link, or one being established).
        public var directLinks: [Data: LinkStatus] = [:]
        /// destinationHash → we have a learned path to it. Gates direct-link establishment: with no
        /// path, request one first (RNS process_outbound, LXMRouter.py:2829-2838).
        public var knownPaths: Set<Data> = []
        /// destinationHash → messages queued until a direct link to it becomes active.
        var outboundQueue: [Data: [LXMessage]] = [:]
        /// message.hash → in-flight send awaiting a delivery outcome (with its resend info + attempts).
        public var pendingDeliveries: [Data: PendingDelivery] = [:]
        /// linkID → message.hash of the Resource-direct send currently in flight on that link.
        /// Single-in-flight per link (last write wins); resolves resourceDeliveredOnLink → deliveryConfirmed.
        public var linkResourceInFlight: [Data: Data] = [:]
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
        /// Three distinct drivers reach this counter:
        ///
        ///  • `TCPEndpoint.openLink` with no `transport.learned[dest]` entry
        ///    (TCPEndpoint.swift:149-151) returns `linkFailed` IMMEDIATELY — a hot, zero-delay
        ///    spin whenever the router's `knownPaths` outlives Transport's `learned` table.
        ///  • An establishment TIMEOUT: an initiator's `LinkSession` emits `.establishmentFailed`
        ///    (LinkSession.swift:546-547), which `LinkPlane` routes to `linkFailed(destinationHash:)`
        ///    and `LXMFNode.swift:267` forwards here keyed by DESTINATION. That paces the cycle at
        ///    the 15s establishment timeout rather than spinning.
        ///  • `.pathRequestDeadline`: when `establish()` parks in `.awaitingPath` and the path
        ///    response never arrives, the park timer fires and increments this counter, re-emitting
        ///    `requestPath` until the budget is exhausted. The two establish branches therefore
        ///    share ONE budget — a destination cannot ping-pong between them to get a fresh allowance.
        ///
        /// The slow path (establishment timeouts) reaches the give-up branch in roughly
        /// `maxAttempts × establishmentTimeout` = 5 × 15s ≈ 75s. Queued messages are reported there
        /// as `deliveryFailed`; a PN SYNC has no message to fail, so it terminates silently — the
        /// flag is cleared but the app is not told. See the give-up branch.
        ///
        /// Reset on `linkEstablished` — the one event that proves the destination is
        /// reachable again. Deliberately NOT reset on `learnedPath`; see that case for why a
        /// re-announce must not refresh the budget, and for the invariant tying this map to
        /// `knownPaths`.
        public var establishAttempts: [Data: Int] = [:]
        public init() {}
    }

    public enum DeliveryMethod: Equatable { case opportunistic, direct }
    public enum LinkStatus: Equatable { case awaitingPath; case establishing; case active(linkID: Data) }

    public enum ResendInfo: Equatable {
        case opportunistic(destinationHash: Data, payload: Data)
        case direct(destinationHash: Data, data: Data, asResource: Bool)
        case propagated(destinationHash: Data, data: Data)
    }
    public struct PendingDelivery: Equatable { public var resend: ResendInfo; public var attempts: Int }
    public struct PropagationItem: Equatable { public var messageHash: Data; public var propagationPacked: Data }

    public enum Action: Equatable {
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
        case delivered(messageHash: Data)
        case resourceDeliveredOnLink(linkID: Data)
        case retryDue(messageHash: Data)
        case idleDeadline(destinationHash: Data)
        case pathRequestDeadline(destinationHash: Data)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case messageDelivered(message: LXMessage, signatureValidated: Bool)
            case duplicateDropped(hash: Data)
            case sendOpportunistic(destinationHash: Data, payload: Data)
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
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { [clock] state, action in
            func retryTimer(_ hash: Data, _ seconds: Int) -> Effect<Action> {
                .run { send in
                    try await clock.sleep(for: .seconds(seconds))
                    await send(.retryDue(messageHash: hash))
                }.cancellable(id: CancelID.retry(hash), cancelInFlight: true)
            }
            func idleTimer(_ dest: Data) -> Effect<Action> {
                .run { send in
                    try await clock.sleep(for: .seconds(LXMFDelivery.linkMaxInactivitySeconds))
                    await send(.idleDeadline(destinationHash: dest))
                }.cancellable(id: CancelID.idle(dest), cancelInFlight: true)
            }
            func pathRequestTimer(_ dest: Data) -> Effect<Action> {
                .run { send in
                    try await clock.sleep(for: .seconds(LXMFDelivery.pathRequestWaitSeconds))
                    await send(.pathRequestDeadline(destinationHash: dest))
                }.cancellable(id: CancelID.pathRequest(dest), cancelInFlight: true)
            }
            func arm(_ state: inout State, _ hash: Data, _ resend: ResendInfo) {
                state.pendingDeliveries[hash] = PendingDelivery(resend: resend, attempts: 1)
            }
            /// Give up on `dest`: cancel the path-request park timer, fail everything queued for it,
            /// forget the path, and clear all establishment state. Both call sites (the `establish`
            /// ceiling and `.pathRequestDeadline`) must terminate identically — extract here rather
            /// than duplicate.
            func giveUp(_ state: inout State, _ dest: Data) -> Effect<Action> {
                state.establishAttempts[dest] = nil
                state.knownPaths.remove(dest)
                state.directLinks[dest] = nil
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
                var effects: [Effect<Action>] = [.cancel(id: CancelID.pathRequest(dest))]
                effects += queued.map { .send(.delegate(.deliveryFailed(messageHash: $0.hash))) }
                effects += propQueued.map { .send(.delegate(.deliveryFailed(messageHash: $0.messageHash))) }
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
            switch action {
            case let .learnedIdentity(destinationHash, identity):
                state.knownIdentities[destinationHash] = identity
                return .none

            case let .received(method, destinationHash, data):
                let reconstructed: LXMessage?
                switch method {
                case .opportunistic:
                    reconstructed = LXMessage.fromOpportunistic(destinationHash: destinationHash, payload: data)
                case .direct:
                    reconstructed = LXMessage.unpack(data)
                }
                guard let message = reconstructed else { return .none }   // malformed → drop
                guard state.seen.insert(message.hash) else {
                    return .send(.delegate(.duplicateDropped(hash: message.hash)))
                }
                let validated = state.knownIdentities[message.sourceHash]
                    .map { message.validateSignature(source: $0) } ?? false
                return .send(.delegate(.messageDelivered(message: message, signatureValidated: validated)))

            case let .send(message, desiredMethod):
                let effective: DeliveryMethod =
                    (desiredMethod == .opportunistic && !message.opportunisticFits) ? .direct : desiredMethod
                switch effective {
                case .opportunistic:
                    let resend = ResendInfo.opportunistic(destinationHash: message.destinationHash,
                                                          payload: message.opportunisticPayload)
                    arm(&state, message.hash, resend)
                    return .merge(.send(.delegate(.sendOpportunistic(destinationHash: message.destinationHash,
                                                                     payload: message.opportunisticPayload))),
                                  retryTimer(message.hash, LXMFDelivery.retryWaitSeconds))
                case .direct:
                    let dest = message.destinationHash
                    if case let .active(linkID) = state.directLinks[dest] {
                        let asResource = message.directRepresentation == .resource
                        arm(&state, message.hash, .direct(destinationHash: dest, data: message.packed, asResource: asResource))
                        if asResource { state.linkResourceInFlight[linkID] = message.hash }
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: message.packed,
                                                                  asResource: asResource))),
                                      retryTimer(message.hash, LXMFDelivery.retryWaitSeconds),
                                      idleTimer(dest))
                    }
                    state.outboundQueue[dest, default: []].append(message)
                    if state.directLinks[dest] == nil {
                        return establish(&state, dest)
                    }
                    return .none   // a link/path request is already in flight
                }

            case let .setOutboundPropagationNode(pn):
                state.outboundPropagationNode = pn
                return .none

            case let .sendViaPropagation(message, propagationPacked):
                guard let pn = state.outboundPropagationNode else {
                    return .send(.delegate(.deliveryFailed(messageHash: message.hash)))
                }
                if case let .active(linkID) = state.directLinks[pn] {
                    arm(&state, message.hash, .propagated(destinationHash: pn, data: propagationPacked))
                    if propagationPacked.count <= Link.mdu {
                        // Small container: send as a proof-requesting link packet.
                        // token = message.hash so packetDelivered maps back to this pending delivery.
                        return .merge(.send(.delegate(.sendPropagatedPacket(linkID: linkID,
                                                                            propagationPacked: propagationPacked,
                                                                            messageHash: message.hash))),
                                      retryTimer(message.hash, LXMFDelivery.retryWaitSeconds),
                                      idleTimer(pn))
                    } else {
                        // Large container: send as Resource; receipt via resourceDeliveredOnLink (unchanged).
                        state.linkResourceInFlight[linkID] = message.hash
                        return .merge(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: propagationPacked))),
                                      retryTimer(message.hash, LXMFDelivery.retryWaitSeconds),
                                      idleTimer(pn))
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
                var effects: [Effect<Action>] = []
                for m in queued {
                    let asResource = m.directRepresentation == .resource
                    arm(&state, m.hash, .direct(destinationHash: dest, data: m.packed, asResource: asResource))
                    if asResource { state.linkResourceInFlight[linkID] = m.hash }
                    effects.append(.send(.delegate(.sendDirect(linkID: linkID, data: m.packed, asResource: asResource))))
                    effects.append(retryTimer(m.hash, LXMFDelivery.retryWaitSeconds))
                }
                for item in propQueued {
                    arm(&state, item.messageHash, .propagated(destinationHash: dest, data: item.propagationPacked))
                    if item.propagationPacked.count <= Link.mdu {
                        effects.append(.send(.delegate(.sendPropagatedPacket(linkID: linkID,
                                                                              propagationPacked: item.propagationPacked,
                                                                              messageHash: item.messageHash))))
                    } else {
                        state.linkResourceInFlight[linkID] = item.messageHash
                        effects.append(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: item.propagationPacked))))
                    }
                    effects.append(retryTimer(item.messageHash, LXMFDelivery.retryWaitSeconds))
                }
                if !queued.isEmpty || !propQueued.isEmpty { effects.append(idleTimer(dest)) }
                if dest == state.outboundPropagationNode, state.pendingDownloadFromPN {
                    state.pendingDownloadFromPN = false
                    effects.append(.send(.delegate(.requestMessageList(linkID: linkID))))
                }
                effects.append(cancelPathTimer)
                return .merge(effects)

            case let .linkClosed(dest):
                if case let .active(linkID) = state.directLinks[dest] {
                    state.linkResourceInFlight[linkID] = nil
                }
                state.directLinks[dest] = nil
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
                    return establish(&state, dest)
                }
                // No work left for this destination: the establishment saga is OVER, so its budget
                // ends with it. The other clearers are `.linkEstablished` (success) and `giveUp`
                // (the ceiling) — on the FAILURE path `giveUp` is the only one, and it is reachable
                // only while work still exists. So without this the counter is stranded at whatever
                // it had reached, and the NEXT message to this peer inherits a spent budget,
                // truncating or instantly failing a delivery that deserved a full allowance.
                //
                // `knownPaths` is deliberately NOT removed here. This is also the ordinary healthy
                // close, where the path is fine and discarding it would be wrong. That does mean a
                // ceiling-stranded destination keeps a route five failed establishments argued
                // against — the same evidence `giveUp` cites when it DOES discard — so the next
                // message spends another full saga before reaching the `requestPath` recovery.
                // Accepted: distinguishing the two cases needs a budget-aware condition here.
                //
                // This branch became reachable with a non-nil budget once establishment was paced
                // by the 15s timeout: the establishment saga (maxAttempts × 15s = 75s) now outlives
                // the message retry saga it was started for (maxAttempts × 10s = 50s), so the
                // pending delivery self-clears first and the final `linkClosed` arrives with
                // nothing to do.
                //
                // The synchronous cascade is NOT purely historical: `BLEEndpoint.openLink` fails
                // immediately with `.pathStale` when the learned entry names a departed interface,
                // so a stale BLE binding again burns every attempt in one zero-delay cascade while
                // the work is still present, and `giveUp` runs. It is bounded by `establishAttempts`
                // — but it is fast. Routing `.pathStale` into the `.awaitingPath` park (rather than
                // into another `requestLink`) is what tames it; see the `linkFailed` handler.
                state.establishAttempts[dest] = nil
                return .none

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

            case let .delivered(hash):
                guard let pending = state.pendingDeliveries[hash] else { return .none }
                state.pendingDeliveries[hash] = nil
                let outcome: Action.Delegate = {
                    if case .propagated = pending.resend { return .propagationAccepted(messageHash: hash) }
                    return .deliveryConfirmed(messageHash: hash)
                }()
                return .merge(.cancel(id: CancelID.retry(hash)), .send(.delegate(outcome)))

            case let .resourceDeliveredOnLink(linkID):
                guard let hash = state.linkResourceInFlight[linkID] else { return .none }
                state.linkResourceInFlight[linkID] = nil
                return .send(.delivered(messageHash: hash))

            case let .retryDue(hash):
                guard var pending = state.pendingDeliveries[hash] else { return .none }
                pending.attempts += 1
                if pending.attempts > LXMFDelivery.maxAttempts {
                    state.pendingDeliveries[hash] = nil
                    return .send(.delegate(.deliveryFailed(messageHash: hash)))
                }
                state.pendingDeliveries[hash] = pending
                switch pending.resend {
                case let .opportunistic(destinationHash, payload):
                    if !state.knownPaths.contains(destinationHash) {
                        // Pathless opportunistic retry: request a path instead of resending, and wait longer.
                        return .merge(.send(.delegate(.requestPath(destinationHash: destinationHash))),
                                      retryTimer(hash, LXMFDelivery.pathRequestWaitSeconds))
                    }
                    return .merge(.send(.delegate(.sendOpportunistic(destinationHash: destinationHash, payload: payload))),
                                  retryTimer(hash, LXMFDelivery.retryWaitSeconds))
                case let .direct(destinationHash, data, asResource):
                    if case let .active(linkID) = state.directLinks[destinationHash] {
                        if asResource { state.linkResourceInFlight[linkID] = hash }
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: asResource))),
                                      retryTimer(hash, LXMFDelivery.retryWaitSeconds))
                    }
                    // Link is down or re-establishing: no live link to send on. Wait and re-check; the
                    // attempt was already counted, so the saga stays bounded by maxAttempts.
                    return retryTimer(hash, LXMFDelivery.retryWaitSeconds)
                case let .propagated(destinationHash, data):
                    if case let .active(linkID) = state.directLinks[destinationHash] {
                        if data.count <= Link.mdu {
                            return .merge(.send(.delegate(.sendPropagatedPacket(linkID: linkID,
                                                                                propagationPacked: data,
                                                                                messageHash: hash))),
                                          retryTimer(hash, LXMFDelivery.retryWaitSeconds))
                        } else {
                            state.linkResourceInFlight[linkID] = hash
                            return .merge(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: data))),
                                          retryTimer(hash, LXMFDelivery.retryWaitSeconds))
                        }
                    }
                    // Link down/re-establishing: no live link; wait and re-check (bounded by maxAttempts).
                    return retryTimer(hash, LXMFDelivery.retryWaitSeconds)
                }

            case let .idleDeadline(dest):
                guard case .active = state.directLinks[dest] else { return .none }
                state.directLinks[dest] = nil
                return .send(.delegate(.closeLink(destinationHash: dest)))

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
