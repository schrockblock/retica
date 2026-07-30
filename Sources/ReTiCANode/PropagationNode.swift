import Foundation
import ComposableArchitecture
import ReTiCA

/// LXMF propagation node — the store-and-forward server role (LXMF-4d-3b). A decoupled reducer holding
/// a `PropagationStore`: the app forwards `lxmf.propagation` events in as actions (a client's concluded
/// container, a client's message request, a client's delivery confirmation) and wires the delegates back
/// out to the transport. The literal Endpoint registration, resource framing, and IDENTIFY resolution are
/// app glue. Mirrors lxmf 1.1.0 LXMRouter (propagation_resource_concluded / message_get_request /
/// save_locally_delivered_transient_ids); peering, stamps, and the PN↔PN mesh are separate.
@Reducer
public struct PropagationNode {
    @ObservableState
    public struct State: Equatable {
        public var store: PropagationStore
        public init(storageLimitBytes: Int? = nil) {
            store = PropagationStore(storageLimitBytes: storageLimitBytes)
        }
    }

    public enum Action: Equatable {
        case ingestContainer(Data)
        case messagesRequested(destinationHash: Data)
        case messagesDelivered(transientIds: [Data])
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case stored(transientIds: [Data])
            case deliverMessages(destinationHash: Data, entries: [Data])
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .ingestContainer(data):
                let added = state.store.ingest(container: data)
                return .send(.delegate(.stored(transientIds: added)))

            case let .messagesRequested(destinationHash):
                let entries = state.store.entries(forDestination: destinationHash).map(\.lxmfData)
                return .send(.delegate(.deliverMessages(destinationHash: destinationHash, entries: entries)))

            case let .messagesDelivered(transientIds):
                for tid in transientIds { state.store.remove(transientId: tid) }
                return .none

            case .delegate:
                return .none
            }
        }
    }
}
