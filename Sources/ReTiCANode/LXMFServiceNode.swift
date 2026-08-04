import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCATransport

/// A node that is BOTH an LXMF client and (optionally) an LXMF propagation node over ONE endpoint —
/// the shape reference LXMF uses: one identity, one connection, both destinations registered.
///
/// Composes the unchanged `LXMFNode` (client; owns the `TransportEndpoint`) with the unchanged
/// `PropagationNode` (store + serve logic), adding only the translation between the endpoint's inbound
/// delegates and the propagation node's actions. Every serve behavior is gated on `nodeModeEnabled`, so
/// with node-mode off this behaves exactly like a bare `LXMFNode`.
///
/// Serve scope is client-facing only (register/announce, ingest offers, two-phase `/get`). PN↔PN mesh
/// peering, inbound proving, and time-based expiry are out of scope — see `PNNode` for the peering path.
@Reducer
public struct LXMFServiceNode {
    @ObservableState
    public struct State: Equatable {
        public var client: LXMFNode.State
        public var pn: PropagationNode.State
        /// While false, nothing is registered, ingested, or served.
        public var nodeModeEnabled: Bool = false
        /// The stamp cost this node ENFORCES on inbound entries, and therefore also ADVERTISES.
        public var minStampCost: Int
        /// linkID → the IDENTIFY'd remote client on that link. A `/get` without one is dropped.
        public var clientIdentities: [Data: Identity] = [:]
        /// client delivery hash → the request awaiting a response.
        public var pendingGet: [Data: PendingGet] = [:]

        /// 32 MB — a mobile-appropriate cap for the store-and-forward backlog.
        public static let defaultStorageLimitBytes: Int = 32 * 1024 * 1024

        public init(identity: Identity, endpoint: TransportEndpoint.State,
                    storageLimitBytes: Int? = State.defaultStorageLimitBytes,
                    minStampCost: Int = LXMFPropagation.defaultPropagationStampCost) {
            self.client = LXMFNode.State(identity: identity, endpoint: endpoint)
            self.pn = PropagationNode.State(storageLimitBytes: storageLimitBytes, minStampCost: minStampCost)
            self.minStampCost = minStampCost
        }

        /// Convenience: run this node over TCP.
        public init(identity: Identity, endpoint: TCPEndpoint.State,
                    storageLimitBytes: Int? = State.defaultStorageLimitBytes,
                    minStampCost: Int = LXMFPropagation.defaultPropagationStampCost) {
            self.init(identity: identity, endpoint: .tcp(endpoint),
                      storageLimitBytes: storageLimitBytes, minStampCost: minStampCost)
        }

        /// Convenience: run this node over BLE.
        public init(identity: Identity, endpoint: BLEEndpoint.State,
                    storageLimitBytes: Int? = State.defaultStorageLimitBytes,
                    minStampCost: Int = LXMFPropagation.defaultPropagationStampCost) {
            self.init(identity: identity, endpoint: .ble(endpoint),
                      storageLimitBytes: storageLimitBytes, minStampCost: minStampCost)
        }
    }

    public struct PendingGet: Equatable {
        public var linkID: Data
        public var requestID: Data
    }

    public enum Action: Equatable {
        case client(LXMFNode.Action)
        case pn(PropagationNode.Action)
        case registerPropagation
        case setNodeMode(Bool)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            /// Entries just accepted into the store — the host persists these.
            case messagesStored(entries: [PropagationStore.Entry])
            /// Entries just removed — the host deletes its mirrored copies.
            case messagesPurged(transientIds: [Data])
        }
    }

    @Dependency(\.date) var date
    public init() {}

    private static func arrayOfBin(_ value: MsgPackValue) -> [Data] {
        guard case let .array(items) = value else { return [] }
        return items.compactMap { if case let .bin(d) = $0 { return d } else { return nil } }
    }

    public var body: some ReducerOf<Self> {
        Scope(state: \.client, action: \.client) { LXMFNode() }
        Scope(state: \.pn, action: \.pn) { PropagationNode() }
        Reduce { [date] state, action in
            /// True when this link terminates on the lxmf.propagation destination WE serve — i.e. the
            /// peer is a propagation client of ours, not a direct correspondent.
            func isPropagationLink(_ state: State, _ linkID: Data) -> Bool {
                guard let served = state.client.propagationDestinationHash else { return false }
                return state.client.linkDestinations[linkID] == served
            }

            switch action {
            case let .setNodeMode(enabled):
                state.nodeModeEnabled = enabled
                if enabled { return .send(.registerPropagation) }
                state.client.propagationDestinationHash = nil    // client resumes normal handling
                state.clientIdentities = [:]
                state.pendingGet = [:]
                return .none

            case .registerPropagation:
                guard state.nodeModeEnabled,
                      let d = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                          aspects: ["propagation"], identity: state.client.identity)
                else { return .none }
                state.client.propagationDestinationHash = d.hash
                let appData = PNAnnounce(timebase: Int(date.now.timeIntervalSince1970), nodeState: true,
                                         perTransferLimit: 0, perSyncLimit: 0,
                                         targetStampCost: state.minStampCost,   // advertised == enforced
                                         stampCostFlexibility: 0, peeringCost: 0).packed
                return .merge(
                    .send(.client(.endpoint(.registerLocalDestination(d)))),
                    .send(.client(.endpoint(.announce(destinationHash: d.hash, appData: appData)))))

            // --- Inbound offers (only on the link to the destination we serve) ---
            case let .client(.endpoint(.delegate(.resourceReceived(linkID, data)))):
                guard state.nodeModeEnabled, isPropagationLink(state, linkID) else { return .none }
                return .send(.pn(.ingestContainer(data)))

            case let .client(.endpoint(.delegate(.linkDataReceived(linkID, data)))):
                guard state.nodeModeEnabled, isPropagationLink(state, linkID) else { return .none }
                return .send(.pn(.ingestContainer(data)))

            case let .client(.endpoint(.delegate(.linkIdentified(linkID, remoteIdentity)))):
                guard state.nodeModeEnabled else { return .none }
                state.clientIdentities[linkID] = remoteIdentity
                return .none

            // --- Two-phase /get ---
            case let .client(.endpoint(.delegate(.requestReceived(linkID, requestID, pathHash, data)))):
                guard state.nodeModeEnabled,
                      pathHash == Crypto.truncatedHash(Data("/get".utf8)),
                      let clientIdentity = state.clientIdentities[linkID]   // no IDENTIFY → drop
                else { return .none }
                guard case let .array(items)? = MsgPack.decodeValue(data), items.count >= 2 else { return .none }
                let clientHash = LXMessage.deliveryHash(identityHash: clientIdentity.hash)
                state.pendingGet[clientHash] = PendingGet(linkID: linkID, requestID: requestID)
                if case .null = items[0], case .null = items[1] {
                    return .send(.pn(.messageListRequested(destinationHash: clientHash)))
                }
                return .send(.pn(.messagesRequested(destinationHash: clientHash,
                                                    wants: LXMFServiceNode.arrayOfBin(items[0]),
                                                    haves: LXMFServiceNode.arrayOfBin(items[1]))))

            case let .pn(.delegate(.deliverMessageList(dest, ids))):
                guard let p = state.pendingGet[dest] else { return .none }
                state.pendingGet[dest] = nil
                return .send(.client(.endpoint(.sendResponseOverLink(
                    linkID: p.linkID, requestID: p.requestID,
                    data: MsgPack.encode(.array(ids.map { .bin($0) }))))))

            case let .pn(.delegate(.deliverMessages(dest, entries))):
                guard let p = state.pendingGet[dest] else { return .none }
                state.pendingGet[dest] = nil
                return .send(.client(.endpoint(.sendResponseOverLink(
                    linkID: p.linkID, requestID: p.requestID,
                    data: MsgPack.encode(.array(entries.map { .bin($0) }))))))

            // --- Persistence signals out to the host ---
            case let .pn(.delegate(.storedEntries(entries))):
                guard !entries.isEmpty else { return .none }
                return .send(.delegate(.messagesStored(entries: entries)))

            case let .pn(.delegate(.purged(ids))):
                guard !ids.isEmpty else { return .none }
                return .send(.delegate(.messagesPurged(transientIds: ids)))

            // --- Link lifecycle cleanup ---
            case let .client(.endpoint(.delegate(.linkClosed(linkID, _)))):
                state.clientIdentities[linkID] = nil
                state.pendingGet = state.pendingGet.filter { $0.value.linkID != linkID }
                return .none

            case let .client(.endpoint(.delegate(.requestFailed(linkID, _)))):
                state.pendingGet = state.pendingGet.filter { $0.value.linkID != linkID }
                return .none

            case .client, .pn, .delegate:
                return .none
            }
        }
    }
}
