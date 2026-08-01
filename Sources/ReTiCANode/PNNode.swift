import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCATransport

/// LXMF propagation-node SERVER composition (P3b): composes `Endpoint` + `PropagationNode` so a node
/// registers/announces `lxmf.propagation`, ingests clients' concluded containers, and serves the two-phase
/// `/get` download. `/get` is handled via the unregistered-request surface (registered paths auto-respond
/// through a static dependency that cannot read the store). Mirrors lxmf 1.1.0 LXMRouter propagation serve.
@Reducer
public struct PNNode {
    @ObservableState
    public struct State: Equatable {
        public var endpoint: Endpoint.State
        public var node: PropagationNode.State
        public var identity: Identity
        public var clientIdentities: [Data: Identity] = [:]   // linkID → IDENTIFY'd client
        public var pendingGet: [Data: PendingGet] = [:]        // client delivery hash → (linkID, requestID)
        public var pendingOffer: [Data: PendingOffer] = [:]   // peerHash → (linkID, requestID, offeredIds)
        public init(identity: Identity, endpoint: Endpoint.State, storageLimitBytes: Int? = nil) {
            self.identity = identity
            self.endpoint = endpoint
            self.node = PropagationNode.State(storageLimitBytes: storageLimitBytes)
        }
    }

    public struct PendingGet: Equatable {
        public var linkID: Data
        public var requestID: Data
    }

    public struct PendingOffer: Equatable {
        public var linkID: Data
        public var requestID: Data
        public var offeredIds: [Data]
    }

    public enum Action: Equatable {
        case endpoint(Endpoint.Action)
        case node(PropagationNode.Action)
        case registerPropagation
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case messagesStored(transientIds: [Data])
        }
    }

    @Dependency(\.date) var date
    public init() {}

    private static func arrayOfBin(_ value: MsgPackValue) -> [Data] {
        guard case let .array(items) = value else { return [] }
        return items.compactMap { if case let .bin(d) = $0 { return d } else { return nil } }
    }

    public var body: some ReducerOf<Self> {
        Scope(state: \.endpoint, action: \.endpoint) { Endpoint() }
        Scope(state: \.node, action: \.node) { PropagationNode() }
        Reduce { [date] state, action in
            switch action {
            case .registerPropagation:
                guard let d = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                          aspects: ["propagation"], identity: state.identity) else { return .none }
                let appData = PNAnnounce(timebase: Int(date.now.timeIntervalSince1970), nodeState: true,
                                         perTransferLimit: 0, perSyncLimit: 0, targetStampCost: 0,
                                         stampCostFlexibility: 0, peeringCost: 0).packed
                return .merge(.send(.endpoint(.registerLocalDestination(d))),
                              .send(.endpoint(.announce(destinationHash: d.hash, appData: appData))))

            case let .endpoint(.delegate(.resourceReceived(_, data))):
                return .send(.node(.ingestContainer(data)))

            case let .node(.delegate(.stored(tids))):
                return .send(.delegate(.messagesStored(transientIds: tids)))

            case let .endpoint(.delegate(.linkIdentified(linkID, remoteIdentity))):
                state.clientIdentities[linkID] = remoteIdentity
                return .none

            case let .endpoint(.delegate(.requestReceived(linkID, requestID, pathHash, data))):
                guard let clientIdentity = state.clientIdentities[linkID] else { return .none }   // no IDENTIFY → drop (both paths)
                if pathHash == Crypto.truncatedHash(Data("/get".utf8)) {
                    let clientHash = LXMessage.deliveryHash(identityHash: clientIdentity.hash)
                    state.pendingGet[clientHash] = PendingGet(linkID: linkID, requestID: requestID)
                    guard case let .array(items)? = MsgPack.decodeValue(data), items.count >= 2 else { return .none }
                    if case .null = items[0], case .null = items[1] {
                        return .send(.node(.messageListRequested(destinationHash: clientHash)))
                    }
                    return .send(.node(.messagesRequested(destinationHash: clientHash,
                                                          wants: PNNode.arrayOfBin(items[0]),
                                                          haves: PNNode.arrayOfBin(items[1]))))
                }
                if pathHash == Crypto.truncatedHash(Data("/offer".utf8)) {
                    guard case let .array(items)? = MsgPack.decodeValue(data), items.count >= 2,
                          case let .bin(peeringKey) = items[0] else { return .none }
                    let offeredIds = PNNode.arrayOfBin(items[1])
                    let peerHash = Destination.hash(identityHash: clientIdentity.hash,
                                                    appName: LXMessage.appName, aspects: ["propagation"])
                    let peeringId = state.identity.hash + clientIdentity.hash
                    state.pendingOffer[peerHash] = PendingOffer(linkID: linkID, requestID: requestID, offeredIds: offeredIds)
                    return .send(.node(.validatePeeringKey(peerHash: peerHash, peeringId: peeringId,
                                                           peeringKey: peeringKey, targetCost: 0)))   // cost 0 = open mesh (P4c enforces)
                }
                return .none

            case let .node(.delegate(.deliverMessageList(dest, ids))):
                guard let p = state.pendingGet[dest] else { return .none }
                state.pendingGet[dest] = nil
                return .send(.endpoint(.sendResponseOverLink(linkID: p.linkID, requestID: p.requestID,
                                                             data: MsgPack.encode(.array(ids.map { .bin($0) })))))

            case let .node(.delegate(.deliverMessages(dest, entries))):
                guard let p = state.pendingGet[dest] else { return .none }
                state.pendingGet[dest] = nil
                return .send(.endpoint(.sendResponseOverLink(linkID: p.linkID, requestID: p.requestID,
                                                             data: MsgPack.encode(.array(entries.map { .bin($0) })))))

            case let .node(.delegate(.peerValidated(peerHash, valid))):
                guard let pending = state.pendingOffer[peerHash] else { return .none }
                if valid { return .send(.node(.peerOffered(peerHash: peerHash, transientIds: pending.offeredIds))) }
                state.pendingOffer[peerHash] = nil                     // invalid key → drop (dead path at cost 0)
                return .none

            case let .node(.delegate(.requestFromPeer(peerHash, wanted))):
                guard let pending = state.pendingOffer[peerHash] else { return .none }
                state.pendingOffer[peerHash] = nil
                return .send(.endpoint(.sendResponseOverLink(linkID: pending.linkID, requestID: pending.requestID,
                                                             data: MsgPack.encode(.array(wanted.map { .bin($0) })))))

            case .endpoint, .node, .delegate:
                return .none
            }
        }
    }
}
