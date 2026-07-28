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
    @ObservableState
    public struct State: Equatable {
        /// Dedup of already-delivered LXMF message IDs (`message.hash`). Bounded (RNS uses age-based
        /// expiry; a bounded ring is the LXMF-4a approximation).
        var seen = RingSet(capacity: 10_000)
        /// sourceHash (sender's lxmf.delivery destination hash) → identity, for signature validation.
        public var knownIdentities: [Data: Identity] = [:]
        /// destinationHash → direct-link state (reuse an active link, or one being established).
        public var directLinks: [Data: LinkStatus] = [:]
        /// destinationHash → messages queued until a direct link to it becomes active.
        var outboundQueue: [Data: [LXMessage]] = [:]
        public init() {}
    }

    public enum DeliveryMethod: Equatable { case opportunistic, direct }
    public enum LinkStatus: Equatable { case establishing; case active(linkID: Data) }

    public enum Action: Equatable {
        case learnedIdentity(destinationHash: Data, identity: Identity)
        case received(method: DeliveryMethod, destinationHash: Data, data: Data)
        case send(message: LXMessage, desiredMethod: DeliveryMethod)
        case linkEstablished(destinationHash: Data, linkID: Data)
        case linkClosed(destinationHash: Data)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case messageDelivered(message: LXMessage, signatureValidated: Bool)
            case duplicateDropped(hash: Data)
            case sendOpportunistic(destinationHash: Data, payload: Data)
            case requestLink(destinationHash: Data)
            case sendDirect(linkID: Data, data: Data, asResource: Bool)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
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
                    return .send(.delegate(.sendOpportunistic(destinationHash: message.destinationHash,
                                                              payload: message.opportunisticPayload)))
                case .direct:
                    let dest = message.destinationHash
                    if case let .active(linkID) = state.directLinks[dest] {
                        return .send(.delegate(.sendDirect(linkID: linkID, data: message.packed,
                                                           asResource: message.directRepresentation == .resource)))
                    }
                    state.outboundQueue[dest, default: []].append(message)
                    if state.directLinks[dest] == nil {
                        state.directLinks[dest] = .establishing
                        return .send(.delegate(.requestLink(destinationHash: dest)))
                    }
                    return .none   // a link request is already in flight
                }

            case let .linkEstablished(dest, linkID):
                state.directLinks[dest] = .active(linkID: linkID)
                let queued = state.outboundQueue[dest] ?? []
                state.outboundQueue[dest] = nil
                let sends = queued.map { m in
                    Effect<Action>.send(.delegate(.sendDirect(linkID: linkID, data: m.packed,
                                                              asResource: m.directRepresentation == .resource)))
                }
                return sends.isEmpty ? .none : .merge(sends)

            case let .linkClosed(dest):
                state.directLinks[dest] = nil
                return .none

            case .delegate:
                return .none
            }
        }
    }
}
