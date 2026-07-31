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
    @ObservableState
    public struct State: Equatable {
        public var endpoint: Endpoint.State
        public var router: LXMFRouter.State
        public var identity: Identity
        public var directLinks: [Data: Data] = [:]   // destinationHash → linkID (close/linkClosed correlation)
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
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case messageReceived(message: LXMessage, signatureValidated: Bool)
            case deliveryFailed(messageHash: Data)
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

            // --- Direct-over-link: router delegates → endpoint actions ---
            case let .router(.delegate(.requestLink(dest))):
                return .send(.endpoint(.openLink(destinationHash: dest)))

            case let .router(.delegate(.requestPath(dest))):
                return .send(.endpoint(.requestPath(destinationHash: dest)))

            case let .router(.delegate(.sendDirect(linkID, data, asResource))):
                return asResource
                    ? .send(.endpoint(.sendResourceOverLink(linkID: linkID, data: data)))
                    : .send(.endpoint(.sendOverLink(linkID: linkID, data: data)))

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

            case .endpoint, .router, .delegate:
                return .none
            }
        }
    }
}
