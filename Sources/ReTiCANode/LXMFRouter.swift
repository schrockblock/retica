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
    private enum CancelID: Hashable { case retry(Data) }

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
        public init() {}
    }

    public enum DeliveryMethod: Equatable { case opportunistic, direct }
    public enum LinkStatus: Equatable { case awaitingPath; case establishing; case active(linkID: Data) }

    public enum ResendInfo: Equatable {
        case opportunistic(destinationHash: Data, payload: Data)
        case direct(linkID: Data, data: Data, asResource: Bool)
    }
    public struct PendingDelivery: Equatable { public var resend: ResendInfo; public var attempts: Int }

    public enum Action: Equatable {
        case learnedIdentity(destinationHash: Data, identity: Identity)
        case received(method: DeliveryMethod, destinationHash: Data, data: Data)
        case send(message: LXMessage, desiredMethod: DeliveryMethod)
        case linkEstablished(destinationHash: Data, linkID: Data)
        case linkClosed(destinationHash: Data)
        case learnedPath(destinationHash: Data)
        case delivered(messageHash: Data)
        case retryDue(messageHash: Data)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case messageDelivered(message: LXMessage, signatureValidated: Bool)
            case duplicateDropped(hash: Data)
            case sendOpportunistic(destinationHash: Data, payload: Data)
            case requestLink(destinationHash: Data)
            case requestPath(destinationHash: Data)
            case sendDirect(linkID: Data, data: Data, asResource: Bool)
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
            func arm(_ state: inout State, _ hash: Data, _ resend: ResendInfo) {
                state.pendingDeliveries[hash] = PendingDelivery(resend: resend, attempts: 1)
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
                        arm(&state, message.hash, .direct(linkID: linkID, data: message.packed, asResource: asResource))
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: message.packed,
                                                                  asResource: asResource))),
                                      retryTimer(message.hash, LXMFDelivery.retryWaitSeconds))
                    }
                    state.outboundQueue[dest, default: []].append(message)
                    if state.directLinks[dest] == nil {
                        if state.knownPaths.contains(dest) {
                            state.directLinks[dest] = .establishing
                            return .send(.delegate(.requestLink(destinationHash: dest)))
                        }
                        state.directLinks[dest] = .awaitingPath
                        return .send(.delegate(.requestPath(destinationHash: dest)))
                    }
                    return .none   // a link/path request is already in flight
                }

            case let .linkEstablished(dest, linkID):
                state.directLinks[dest] = .active(linkID: linkID)
                let queued = state.outboundQueue[dest] ?? []
                state.outboundQueue[dest] = nil
                var effects: [Effect<Action>] = []
                for m in queued {
                    let asResource = m.directRepresentation == .resource
                    arm(&state, m.hash, .direct(linkID: linkID, data: m.packed, asResource: asResource))
                    effects.append(.send(.delegate(.sendDirect(linkID: linkID, data: m.packed, asResource: asResource))))
                    effects.append(retryTimer(m.hash, LXMFDelivery.retryWaitSeconds))
                }
                return effects.isEmpty ? .none : .merge(effects)

            case let .linkClosed(dest):
                state.directLinks[dest] = nil
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
                case let .direct(linkID, data, asResource):
                    return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: asResource))),
                                  retryTimer(hash, LXMFDelivery.retryWaitSeconds))
                }

            case .delegate:
                return .none
            }
        }
    }
}
