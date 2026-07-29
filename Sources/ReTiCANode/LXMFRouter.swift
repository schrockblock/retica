import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCATransport

/// LXMF inbound router (LXMF-4a): ingests inbound LXMF deliveries from any arrival method, validates
/// and de-duplicates them by `message.hash`, and surfaces each unique message once. Decoupled from
/// `Endpoint` — the app forwards Endpoint's delivery/announce events in as `.received`/`.learnedIdentity`.
/// Mirrors reference LXMRouter.lxmf_delivery (LXMRouter.py:1837-1919): always deliver a well-formed,
/// non-duplicate message (flagging signature validity), never drop on a bad/unknown signature.
@Reducer
public struct LXMFRouter {
    @Dependency(\.continuousClock) var clock
    private enum CancelID: Hashable { case retry(Data); case idle(Data) }

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
        /// The configured store-and-forward propagation node (all PROPAGATED sends link to it).
        public var outboundPropagationNode: Data? = nil
        /// PN hash → propagated messages queued until a link to the PN becomes active.
        var propagationQueue: [Data: [PropagationItem]] = [:]
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
        case linkEstablished(destinationHash: Data, linkID: Data)
        case linkClosed(destinationHash: Data)
        case learnedPath(destinationHash: Data)
        case delivered(messageHash: Data)
        case retryDue(messageHash: Data)
        case idleDeadline(destinationHash: Data)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case messageDelivered(message: LXMessage, signatureValidated: Bool)
            case duplicateDropped(hash: Data)
            case sendOpportunistic(destinationHash: Data, payload: Data)
            case requestLink(destinationHash: Data)
            case requestPath(destinationHash: Data)
            case sendDirect(linkID: Data, data: Data, asResource: Bool)
            case sendPropagated(linkID: Data, propagationPacked: Data)
            case closeLink(destinationHash: Data)
            case deliveryConfirmed(messageHash: Data)
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
            func arm(_ state: inout State, _ hash: Data, _ resend: ResendInfo) {
                state.pendingDeliveries[hash] = PendingDelivery(resend: resend, attempts: 1)
            }
            func establish(_ state: inout State, _ dest: Data) -> Effect<Action> {
                if state.knownPaths.contains(dest) {
                    state.directLinks[dest] = .establishing
                    return .send(.delegate(.requestLink(destinationHash: dest)))
                }
                state.directLinks[dest] = .awaitingPath
                return .send(.delegate(.requestPath(destinationHash: dest)))
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
                    return .merge(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: propagationPacked))),
                                  retryTimer(message.hash, LXMFDelivery.retryWaitSeconds),
                                  idleTimer(pn))
                }
                state.propagationQueue[pn, default: []].append(
                    PropagationItem(messageHash: message.hash, propagationPacked: propagationPacked))
                if state.directLinks[pn] == nil {
                    return establish(&state, pn)
                }
                return .none

            case let .linkEstablished(dest, linkID):
                state.directLinks[dest] = .active(linkID: linkID)
                let queued = state.outboundQueue[dest] ?? []
                state.outboundQueue[dest] = nil
                let propQueued = state.propagationQueue[dest] ?? []
                state.propagationQueue[dest] = nil
                var effects: [Effect<Action>] = []
                for m in queued {
                    let asResource = m.directRepresentation == .resource
                    arm(&state, m.hash, .direct(destinationHash: dest, data: m.packed, asResource: asResource))
                    effects.append(.send(.delegate(.sendDirect(linkID: linkID, data: m.packed, asResource: asResource))))
                    effects.append(retryTimer(m.hash, LXMFDelivery.retryWaitSeconds))
                }
                for item in propQueued {
                    arm(&state, item.messageHash, .propagated(destinationHash: dest, data: item.propagationPacked))
                    effects.append(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: item.propagationPacked))))
                    effects.append(retryTimer(item.messageHash, LXMFDelivery.retryWaitSeconds))
                }
                if !queued.isEmpty || !propQueued.isEmpty { effects.append(idleTimer(dest)) }
                return effects.isEmpty ? .none : .merge(effects)

            case let .linkClosed(dest):
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
                if hasPending || hasQueued {
                    return establish(&state, dest)
                }
                return .none

            case let .learnedPath(dest):
                state.knownPaths.insert(dest)
                if state.directLinks[dest] == .awaitingPath {
                    state.directLinks[dest] = .establishing
                    return .send(.delegate(.requestLink(destinationHash: dest)))
                }
                return .none

            case let .delivered(hash):
                guard state.pendingDeliveries[hash] != nil else { return .none }
                state.pendingDeliveries[hash] = nil
                return .merge(.cancel(id: CancelID.retry(hash)),
                              .send(.delegate(.deliveryConfirmed(messageHash: hash))))

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
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: asResource))),
                                      retryTimer(hash, LXMFDelivery.retryWaitSeconds))
                    }
                    // Link is down or re-establishing: no live link to send on. Wait and re-check; the
                    // attempt was already counted, so the saga stays bounded by maxAttempts.
                    return retryTimer(hash, LXMFDelivery.retryWaitSeconds)
                case let .propagated(destinationHash, data):
                    if case let .active(linkID) = state.directLinks[destinationHash] {
                        return .merge(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: data))),
                                      retryTimer(hash, LXMFDelivery.retryWaitSeconds))
                    }
                    // Link down/re-establishing: no live link; wait and re-check (bounded by maxAttempts).
                    return retryTimer(hash, LXMFDelivery.retryWaitSeconds)
                }

            case let .idleDeadline(dest):
                guard case .active = state.directLinks[dest] else { return .none }
                state.directLinks[dest] = nil
                return .send(.delegate(.closeLink(destinationHash: dest)))

            case .delegate:
                return .none
            }
        }
    }
}
