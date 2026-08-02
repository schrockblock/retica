import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCATransport

/// The first production composition connecting the decoupled `LXMFRouter` to real transport (LXMF-Node,
/// opportunistic 1:1). Composes `Endpoint` + `LXMFRouter` and translates their delegates/actions: the app
/// calls `.registerDelivery` then `.send(...)`, and receives `.delegate(.messageReceived(...))`. Direct-
/// over-link, path requests, delivery confirmation, and propagation wiring are follow-ons.
@Reducer
public struct LXMFNode {
    public enum SyncPhase: Equatable { case awaitingList, awaitingMessages }

    @ObservableState
    public struct State: Equatable {
        public var endpoint: Endpoint.State
        public var router: LXMFRouter.State
        public var identity: Identity
        public var directLinks: [Data: Data] = [:]   // destinationHash → linkID (close/linkClosed correlation)
        public var syncPhase: [Data: SyncPhase] = [:]   // linkID → current download phase (one sync/link)
        public init(identity: Identity, endpoint: Endpoint.State) {
            self.identity = identity
            self.endpoint = endpoint
            self.router = LXMFRouter.State()
        }
    }

    public enum Action: Equatable {
        case endpoint(Endpoint.Action)
        case router(LXMFRouter.Action)
        case registerDelivery
        case send(destinationHash: Data, title: Data, content: Data, method: LXMFRouter.DeliveryMethod)
        case setPropagationNode(destinationHash: Data)
        case sendViaPropagation(destinationHash: Data, title: Data, content: Data)
        case sendMessage(message: LXMessage, alsoViaPropagation: Bool)
        case syncFromPropagationNode
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case messageReceived(message: LXMessage, signatureValidated: Bool)
            case deliveryFailed(messageHash: Data)
            case deliveryConfirmed(messageHash: Data)
            case propagationAccepted(messageHash: Data)
        }
    }

    @Dependency(\.date) var date
    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.endpoint, action: \.endpoint) { Endpoint() }
        Scope(state: \.router, action: \.router) { LXMFRouter() }
        Reduce { [date] state, action in
            switch action {
            case .registerDelivery:
                guard let d = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                          aspects: LXMessage.deliveryAspects, identity: state.identity)
                else { return .none }
                return .merge(.send(.endpoint(.registerLocalDestination(d))),
                              .send(.endpoint(.announce(destinationHash: d.hash, appData: nil))))

            case let .send(destinationHash, title, content, method):
                let msg = LXMessage.create(source: state.identity, destinationHash: destinationHash,
                                           timestamp: date.now.timeIntervalSince1970, title: title, content: content)
                return .send(.router(.send(message: msg, desiredMethod: method)))

            case let .setPropagationNode(destinationHash):
                return .send(.router(.setOutboundPropagationNode(destinationHash)))

            case let .sendViaPropagation(destinationHash, title, content):
                guard let recipient = state.endpoint.transport.learned[destinationHash]?.identity
                else { return .none }
                let msg = LXMessage.create(source: state.identity, destinationHash: destinationHash,
                                           timestamp: date.now.timeIntervalSince1970, title: title, content: content)
                let ts = date.now.timeIntervalSince1970
                let cost = propagationStampCost(state)
                return .run { send in
                    let (packed, _) = LXMFPropagation.pack(
                        message: msg, recipientIdentity: recipient, timestamp: ts, stampCost: cost)
                    await send(.router(.sendViaPropagation(message: msg, propagationPacked: packed)))
                }

            case let .sendMessage(message, alsoViaPropagation):
                var effects: [Effect<Action>] = [
                    .send(.router(.send(message: message, desiredMethod: .opportunistic)))
                ]
                if alsoViaPropagation,
                   let recipient = state.endpoint.transport.learned[message.destinationHash]?.identity {
                    let ts = date.now.timeIntervalSince1970
                    let cost = propagationStampCost(state)
                    effects.append(.run { send in
                        let (packed, _) = LXMFPropagation.pack(
                            message: message, recipientIdentity: recipient, timestamp: ts, stampCost: cost)
                        await send(.router(.sendViaPropagation(message: message, propagationPacked: packed)))
                    })
                }
                return .merge(effects)

            case .syncFromPropagationNode:
                return .send(.router(.syncFromPropagationNode))

            // --- Propagation sync: phase-1 (IDENTIFY + list request) ---
            case let .router(.delegate(.requestMessageList(linkID))):
                state.syncPhase[linkID] = .awaitingList
                return .merge(
                    .send(.endpoint(.identifyOverLink(linkID: linkID, identity: state.identity))),
                    .send(.endpoint(.sendRequestOverLink(linkID: linkID, path: "/get",
                                                         data: MsgPack.encode(.array([.null, .null]))))))

            // --- Propagation sync: phase-2 (wanted messages request) ---
            case let .router(.delegate(.requestMessages(linkID, wants, haves))):
                state.syncPhase[linkID] = .awaitingMessages
                let payload = MsgPack.encode(.array([.array(wants.map { .bin($0) }),
                                                     .array(haves.map { .bin($0) })]))
                return .send(.endpoint(.sendRequestOverLink(linkID: linkID, path: "/get", data: payload)))

            // --- Propagation sync: dispatch on responseReceived based on phase ---
            case let .endpoint(.delegate(.responseReceived(linkID, _, data))):
                switch state.syncPhase[linkID] {
                case .awaitingList:
                    guard case let .array(items)? = MsgPack.decodeValue(data) else { return .none }
                    let ids = items.compactMap { item -> Data? in
                        if case let .bin(d) = item { return d } else { return nil }
                    }
                    return .send(.router(.offeredMessageList(transientIds: ids)))
                case .awaitingMessages:
                    state.syncPhase[linkID] = nil
                    guard case let .array(items)? = MsgPack.decodeValue(data) else { return .none }
                    let blobs = items.compactMap { item -> Data? in
                        if case let .bin(d) = item { return d } else { return nil }
                    }
                    var effects: [Effect<Action>] = []
                    var tids: [Data] = []
                    for blob in blobs {
                        // Strip the trailing stamp (32 bytes) if present to recover the canonical transient_id
                        // (full_hash of the stampless lxmf_data), matching how PropagationStore deduplicates.
                        let blobCore = blob.count > LXMessage.destinationLength + LXStamper.stampSize
                            ? Data(blob.dropLast(LXStamper.stampSize))
                            : blob
                        tids.append(LXMFPropagation.transientId(lxmfData: blobCore))
                        if let packed = LXMFPropagation.recoverPacked(lxmfData: blob, recipientIdentity: state.identity) {
                            effects.append(.send(.router(.received(method: .direct, destinationHash: Data(), data: packed))))
                        }
                    }
                    effects.append(.send(.router(.messagesDownloaded(transientIds: tids))))
                    return .merge(effects)
                case .none:
                    return .none
                }

            case let .router(.delegate(.sendOpportunistic(dest, payload))):
                return .send(.endpoint(.send(destinationHash: dest, plaintext: payload)))

            case let .endpoint(.delegate(.messageReceived(destHash, plaintext))):
                return .send(.router(.received(method: .opportunistic, destinationHash: destHash, data: plaintext)))

            case let .endpoint(.delegate(.pathLearned(h, _))):
                var effects: [Effect<Action>] = [.send(.router(.learnedPath(destinationHash: h)))]
                if let identity = state.endpoint.transport.learned[h]?.identity {
                    effects.append(.send(.router(.learnedIdentity(destinationHash: h, identity: identity))))
                }
                return .merge(effects)

            case let .router(.delegate(.messageDelivered(message, validated))):
                return .send(.delegate(.messageReceived(message: message, signatureValidated: validated)))

            case let .router(.delegate(.deliveryFailed(hash))):
                return .send(.delegate(.deliveryFailed(messageHash: hash)))

            case let .router(.delegate(.deliveryConfirmed(hash))):
                return .send(.delegate(.deliveryConfirmed(messageHash: hash)))

            case let .router(.delegate(.propagationAccepted(hash))):
                return .send(.delegate(.propagationAccepted(messageHash: hash)))

            // --- Direct-over-link: router delegates → endpoint actions ---
            case let .router(.delegate(.requestLink(dest))):
                return .send(.endpoint(.openLink(destinationHash: dest)))

            case let .router(.delegate(.requestPath(dest))):
                return .send(.endpoint(.requestPath(destinationHash: dest)))

            case let .router(.delegate(.sendDirect(linkID, data, asResource))):
                return asResource
                    ? .send(.endpoint(.sendResourceOverLink(linkID: linkID, data: data)))
                    : .send(.endpoint(.sendOverLink(linkID: linkID, data: data)))

            case let .router(.delegate(.sendPropagated(linkID, propagationPacked))):
                return .send(.endpoint(.sendResourceOverLink(linkID: linkID, data: propagationPacked)))

            case let .router(.delegate(.closeLink(dest))):
                guard let linkID = state.directLinks[dest] else { return .none }
                return .send(.endpoint(.closeLink(linkID: linkID)))

            // --- Direct-over-link: endpoint delegates → router actions ---
            case let .endpoint(.delegate(.linkEstablished(linkID, dest))):
                state.directLinks[dest] = linkID
                return .send(.router(.linkEstablished(destinationHash: dest, linkID: linkID)))

            case let .endpoint(.delegate(.linkClosed(linkID, _))):
                guard let dest = state.directLinks.first(where: { $0.value == linkID })?.key else { return .none }
                state.directLinks[dest] = nil
                return .send(.router(.linkClosed(destinationHash: dest)))

            case let .endpoint(.delegate(.linkFailed(dest))):
                state.directLinks[dest] = nil
                return .send(.router(.linkClosed(destinationHash: dest)))

            case let .endpoint(.delegate(.linkDataReceived(_, data))):
                return .send(.router(.received(method: .direct, destinationHash: Data(), data: data)))

            case let .endpoint(.delegate(.resourceReceived(_, data))):
                return .send(.router(.received(method: .direct, destinationHash: Data(), data: data)))

            case let .endpoint(.delegate(.resourceConcluded(linkID, _))):
                return .send(.router(.resourceDeliveredOnLink(linkID: linkID)))

            case .endpoint, .router, .delegate:
                return .none
            }
        }
    }

    private func propagationStampCost(_ state: State) -> Int {
        guard let pn = state.router.outboundPropagationNode,
              let appData = state.endpoint.transport.learned[pn]?.appData,
              let ann = PNAnnounce.parse(appData)
        else { return LXMFPropagation.defaultPropagationStampCost }
        return ann.targetStampCost
    }
}
