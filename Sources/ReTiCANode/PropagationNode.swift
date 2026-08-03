import Foundation
import ComposableArchitecture
import ReTiCA

/// LXMF propagation node — the store-and-forward server role (LXMF-4d-3b). A decoupled reducer holding
/// a `PropagationStore`: the app forwards `lxmf.propagation` events in as actions (a client's concluded
/// container, a client's message request, a client's delivery confirmation) and wires the delegates back
/// out to the transport. The literal Endpoint registration, resource framing, and IDENTIFY resolution are
/// app glue. Mirrors lxmf 1.1.0 LXMRouter (propagation_resource_concluded / message_get_request /
/// save_locally_delivered_transient_ids). Also does PN↔PN peer sync (offer/wanted exchange + peering-key
/// validation); stamps enforcement and the peer link/transfer networking + peer registry are app/mesh glue.
@Reducer
public struct PropagationNode {
    @ObservableState
    public struct State: Equatable {
        public var store: PropagationStore
        public init(storageLimitBytes: Int? = nil,
                    minStampCost: Int = LXMFPropagation.defaultPropagationStampCost) {
            store = PropagationStore(storageLimitBytes: storageLimitBytes, minStampCost: minStampCost)
        }
    }

    public enum Action: Equatable {
        case ingestContainer(Data)
        case messagesRequested(destinationHash: Data, wants: [Data], haves: [Data])
        case messageListRequested(destinationHash: Data)
        case messagesDelivered(transientIds: [Data])
        case peerOffered(peerHash: Data, transientIds: [Data])
        case offerToPeer(peerHash: Data)
        case validatePeeringKey(peerHash: Data, peeringId: Data, peeringKey: Data, targetCost: Int)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case stored(transientIds: [Data])
            case deliverMessages(destinationHash: Data, entries: [Data])
            case deliverMessageList(destinationHash: Data, transientIds: [Data])
            case requestFromPeer(peerHash: Data, transientIds: [Data])
            case offerTransientIds(peerHash: Data, transientIds: [Data])
            case peerValidated(peerHash: Data, valid: Bool)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .ingestContainer(data):
                let added = state.store.ingest(container: data)
                return .send(.delegate(.stored(transientIds: added)))

            case let .messagesRequested(destinationHash, wants, haves):
                for tid in haves { state.store.remove(transientId: tid) }          // purge what the client already has
                let wantSet = Set(wants)
                let entries = state.store.entries(forDestination: destinationHash)
                    .filter { wantSet.contains($0.transientId) }
                    .map(\.lxmfData)
                return .send(.delegate(.deliverMessages(destinationHash: destinationHash, entries: entries)))

            case let .messageListRequested(destinationHash):
                let ids = state.store.entries(forDestination: destinationHash).map(\.transientId)
                return .send(.delegate(.deliverMessageList(destinationHash: destinationHash, transientIds: ids)))

            case let .messagesDelivered(transientIds):
                for tid in transientIds { state.store.remove(transientId: tid) }
                return .none

            case let .peerOffered(peerHash, offered):
                return .send(.delegate(.requestFromPeer(peerHash: peerHash,
                                                        transientIds: state.store.wanted(fromOffered: offered))))

            case let .offerToPeer(peerHash):
                return .send(.delegate(.offerTransientIds(peerHash: peerHash, transientIds: state.store.transientIds)))

            case let .validatePeeringKey(peerHash, peeringId, peeringKey, targetCost):
                let valid = LXStamper.validatePeeringKey(peeringId: peeringId, peeringKey: peeringKey, targetCost: targetCost)
                return .send(.delegate(.peerValidated(peerHash: peerHash, valid: valid)))

            case .delegate:
                return .none
            }
        }
    }
}
