import Foundation
import ComposableArchitecture
import ReTiCA

/// LXMF propagation node — the store-and-forward server role (LXMF-4d-3b). A decoupled reducer holding
/// a `PropagationStore`: the app forwards `lxmf.propagation` events in as actions (a client's concluded
/// container, a client's message request, a client's delivery confirmation) and wires the delegates back
/// out to the transport. The literal TCPEndpoint registration, resource framing, and IDENTIFY resolution are
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
        /// `transferLimitBytes`: the client's declared per-transfer cap (from `data[2]` in the /get
        /// request). `nil` means no cap. Per the reference (LXMRouter.py:1547) the cap is applied per
        /// message inclusively (skip — do NOT stop — on overflow). **Do not pass 0 as unlimited** — 0
        /// is a 0-byte cap that serves nothing (reference `float(data[2])*1000 = 0.0 < cumulative`).
        case messagesRequested(destinationHash: Data, wants: [Data], haves: [Data], transferLimitBytes: Int? = nil)
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
            /// The full entries just ingested — the bytes a host persists. Emitted alongside `stored`.
            case storedEntries(entries: [PropagationStore.Entry])
            /// Transient ids just removed from the store (client purge or delivery confirmation), so a
            /// host can delete its mirrored copies.
            case purged(transientIds: [Data])
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .ingestContainer(data):
                let (added, evicted) = state.store.ingest(container: data)
                let entries = state.store.entries(forTransientIds: added)
                var effects: [Effect<Action>] = [
                    .send(.delegate(.stored(transientIds: added))),
                    .send(.delegate(.storedEntries(entries: entries)))
                ]
                // Eviction is a third removal route; surface evicted ids so the host's mirror stays in sync.
                if !evicted.isEmpty { effects.append(.send(.delegate(.purged(transientIds: evicted)))) }
                return .merge(effects)

            case let .messagesRequested(destinationHash, wants, haves, transferLimitBytes):
                // Ownership check: only purge entries that belong to the requesting destination
                // (reference LXMRouter.py:1510). Without this any identified client could evict
                // entries for other destinations.
                let ownedIds = Set(state.store.entries(forDestination: destinationHash).map(\.transientId))
                let ownedHaves = haves.filter { ownedIds.contains($0) }
                let purged = ownedHaves.filter { state.store.contains(transientId: $0) }
                for tid in ownedHaves { state.store.remove(transientId: tid) }     // purge what the client already has
                let wantSet = Set(wants)
                let candidates = state.store.entries(forDestination: destinationHash)
                    .filter { wantSet.contains($0.transientId) }
                // Apply the client's declared per-transfer limit, matching reference LXMRouter.py:1524-1550.
                // Overhead constants mirror the Python: per_message_overhead=16, cumulative_size starts at 24.
                // Messages that exceed the cap are SKIPPED (not truncated) — reference uses `pass` on overflow.
                // 0 is NOT treated as unlimited: float(0)*1000=0.0 serves nothing (same as reference).
                let perMessageOverhead = 16
                var cumulativeSize = 24
                var served: [Data] = []
                for entry in candidates {
                    let stripped = LXMFPropagation.strippedCore(lxmfData: entry.lxmfData)   // serve stampless (reference LXMRouter.py:1551)
                    let nextSize = cumulativeSize + stripped.count + perMessageOverhead
                    if let limit = transferLimitBytes, nextSize > limit { continue }   // skip — do not stop
                    served.append(stripped)
                    cumulativeSize += stripped.count + perMessageOverhead
                }
                var effects: [Effect<Action>] = [
                    .send(.delegate(.deliverMessages(destinationHash: destinationHash, entries: served)))
                ]
                if !purged.isEmpty { effects.append(.send(.delegate(.purged(transientIds: purged)))) }
                return .merge(effects)

            case let .messageListRequested(destinationHash):
                let ids = state.store.entries(forDestination: destinationHash).map(\.transientId)
                return .send(.delegate(.deliverMessageList(destinationHash: destinationHash, transientIds: ids)))

            case let .messagesDelivered(transientIds):
                let purged = transientIds.filter { state.store.contains(transientId: $0) }
                for tid in transientIds { state.store.remove(transientId: tid) }
                guard !purged.isEmpty else { return .none }
                return .send(.delegate(.purged(transientIds: purged)))

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
