import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport

/// Composes a `TCPClientInterface` and a `Transport` into a single runnable Reticulum
/// endpoint, wiring their delegates bidirectionally. Single TCP interface this slice.
@Reducer
public struct Endpoint {
    @ObservableState
    public struct State: Equatable {
        public var interface: TCPClientInterface.State
        public var transport: Transport.State
        public var links: IdentifiedArrayOf<LinkSession.State> = []
        public var registrations: [Data: RequestRegistration] = [:]
        public let interfaceID: InterfaceID

        public init(host: String, port: UInt16, reconnectOnDrop: Bool = true,
                    interfaceID: InterfaceID = InterfaceID("tcp")) {
            self.interface = TCPClientInterface.State(host: host, port: port,
                                                      reconnectOnDrop: reconnectOnDrop)
            self.transport = Transport.State()
            self.interfaceID = interfaceID
        }
    }

    public enum Action: Equatable {
        case interface(TCPClientInterface.Action)
        case transport(Transport.Action)
        case link(IdentifiedActionOf<LinkSession>)

        case connect
        case disconnect
        case registerLocalDestination(Destination)
        case announce(destinationHash: Data, appData: Data?)
        case send(destinationHash: Data, plaintext: Data)
        case enableRelay(Identity)
        case openLink(destinationHash: Data)
        case sendOverLink(linkID: Data, data: Data)
        case sendResourceOverLink(linkID: Data, data: Data)
        case closeLink(linkID: Data)
        case identifyOverLink(linkID: Data, identity: Identity)
        case sendRequestOverLink(linkID: Data, path: String, data: Data)
        case sendResponseOverLink(linkID: Data, requestID: Data, data: Data)
        case registerRequestHandler(path: String, policy: RequestPolicy)
        case deregisterRequestHandler(path: String)

        case delegate(Delegate)
        @CasePathable
        public enum Delegate: Equatable {
            case messageReceived(destinationHash: Data, plaintext: Data)
            case pathLearned(destinationHash: Data, hops: UInt8)
            case sendFailed(destinationHash: Data, reason: Transport.SendFailure)
            case linkEstablished(linkID: Data)
            case linkDataReceived(linkID: Data, data: Data)
            case linkClosed(linkID: Data, reason: LinkSession.CloseReason)
            case linkFailed(destinationHash: Data)
            case resourceReceived(linkID: Data, data: Data)
            case resourceConcluded(linkID: Data, resourceHash: Data)
            case resourceFailed(linkID: Data, resourceHash: Data)
            case linkIdentified(linkID: Data, remoteIdentity: Identity)
            case requestReceived(linkID: Data, requestID: Data, pathHash: Data, data: Data)
            case responseReceived(linkID: Data, requestID: Data, data: Data)
            case requestFailed(linkID: Data, requestID: Data)
        }
    }

    public init() {}

    @Dependency(\.uuid) var uuid
    @Dependency(\.requestResponder) var requestResponder

    public var body: some ReducerOf<Self> {
        Scope(state: \.interface, action: \.interface) { TCPClientInterface() }
        Scope(state: \.transport, action: \.transport) { Transport() }
        .forEach(\.links, action: \.link) { LinkSession() }
        Reduce { state, action in
            let id = state.interfaceID
            switch action {
            case .connect:                          return .send(.interface(.connect))
            case .disconnect:                       return .send(.interface(.disconnect))
            case let .registerLocalDestination(d):  return .send(.transport(.registerLocalDestination(d)))
            case let .announce(h, a):               return .send(.transport(.announce(destinationHash: h, appData: a)))
            case let .send(h, p):                   return .send(.transport(.send(destinationHash: h, plaintext: p)))
            case let .enableRelay(identity):        return .send(.transport(.setTransportIdentity(identity)))

            case let .interface(.delegate(.packetReceived(data))):
                return .send(.transport(.received(id, data)))
            case .interface(.connectionEvent(.connected)):
                return .send(.transport(.interfaceConnected(id)))
            case .interface(.connectionEvent(.disconnected)):
                return .send(.transport(.interfaceDisconnected(id)))

            case let .transport(.delegate(.transmit(txID, raw))):
                guard txID == id else { return .none }
                return .send(.interface(.send(raw)))
            case let .transport(.delegate(.received(h, p))):
                return .send(.delegate(.messageReceived(destinationHash: h, plaintext: p)))
            case let .transport(.delegate(.pathLearned(h, hops))):
                return .send(.delegate(.pathLearned(destinationHash: h, hops: hops)))
            case let .transport(.delegate(.sendFailed(h, r))):
                return .send(.delegate(.sendFailed(destinationHash: h, reason: r)))

            case let .transport(.delegate(.linkPacket(linkID, data))):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .received(data))))

            case let .transport(.delegate(.linkRequest(destHash, data))):
                guard let owner = state.transport.localDestinations[destHash]?.identity,
                      owner.privateKey != nil
                else { return .none }
                let newID = uuid()
                state.links.append(LinkSession.State(id: newID, responderFor: owner,
                                                     destinationHash: destHash, interfaceID: id))
                return .send(.link(.element(id: newID, action: .acceptRequest(data))))

            case let .link(.element(_, .delegate(.transmit(txID, raw)))):
                guard txID == id else { return .none }
                return .send(.interface(.send(raw)))

            case let .openLink(destinationHash):
                guard let learned = state.transport.learned[destinationHash] else {
                    return .send(.delegate(.linkFailed(destinationHash: destinationHash)))
                }
                let newID = uuid()
                state.links.append(LinkSession.State(id: newID, initiatorTo: learned.identity,
                                                     destinationHash: destinationHash, interfaceID: id))
                return .send(.link(.element(id: newID, action: .establish)))

            case let .sendOverLink(linkID, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .send(data))))

            case let .sendResourceOverLink(linkID, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .sendResource(data))))

            case let .identifyOverLink(linkID, identity):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .identify(identity))))
            case let .sendRequestOverLink(linkID, path, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .sendRequest(path: path, data: data))))
            case let .sendResponseOverLink(linkID, requestID, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .sendResponse(requestID: requestID, data: data))))

            case let .closeLink(linkID):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .close)))

            case let .registerRequestHandler(path, policy):
                state.registrations[Crypto.truncatedHash(Data(path.utf8))] = RequestRegistration(path: path, policy: policy)
                return .none
            case let .deregisterRequestHandler(path):
                state.registrations[Crypto.truncatedHash(Data(path.utf8))] = nil
                return .none

            case let .link(.element(_, .delegate(.established(linkID, _)))):
                return .send(.delegate(.linkEstablished(linkID: linkID)))

            case let .link(.element(elementID, .delegate(.dataReceived(data)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.linkDataReceived(linkID: linkID, data: data)))

            case let .link(.element(elementID, .delegate(.closed(reason)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                state.links.remove(id: elementID)
                return .send(.delegate(.linkClosed(linkID: linkID, reason: reason)))

            case let .link(.element(elementID, .delegate(.establishmentFailed))):
                guard let destHash = state.links[id: elementID]?.destinationHash else { return .none }
                state.links.remove(id: elementID)
                return .send(.delegate(.linkFailed(destinationHash: destHash)))

            case let .link(.element(elementID, .delegate(.resourceReceived(data)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.resourceReceived(linkID: linkID, data: data)))
            case let .link(.element(elementID, .delegate(.resourceConcluded(hash)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.resourceConcluded(linkID: linkID, resourceHash: hash)))
            case let .link(.element(elementID, .delegate(.resourceFailed(hash)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.resourceFailed(linkID: linkID, resourceHash: hash)))

            case let .link(.element(elementID, .delegate(.identified(identity)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: identity)))
            case let .link(.element(elementID, .delegate(.requestReceived(rid, ph, data)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                guard let reg = state.registrations[ph] else {
                    // No registered handler for this path: surface to the app exactly as before.
                    return .send(.delegate(.requestReceived(linkID: linkID, requestID: rid, pathHash: ph, data: data)))
                }
                let identity = state.links[id: elementID]?.remoteIdentity
                guard isAllowed(reg.policy, identity) else { return .none }   // denied → silent drop
                let path = reg.path
                let responder = requestResponder
                return .run { send in
                    if let response = await responder(path, data, identity) {
                        await send(.sendResponseOverLink(linkID: linkID, requestID: rid, data: response))
                    }
                }
            case let .link(.element(elementID, .delegate(.responseReceived(rid, data)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.responseReceived(linkID: linkID, requestID: rid, data: data)))
            case let .link(.element(elementID, .delegate(.requestFailed(rid)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.requestFailed(linkID: linkID, requestID: rid)))

            case .interface, .transport, .delegate, .link:
                return .none
            }
        }
    }
}
