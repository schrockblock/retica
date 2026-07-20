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
        case openLink(destinationHash: Data)
        case sendOverLink(linkID: Data, data: Data)
        case closeLink(linkID: Data)

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
        }
    }

    public init() {}

    @Dependency(\.uuid) var uuid

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

            case let .closeLink(linkID):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .close)))

            case let .link(.element(_, .delegate(.established(linkID, _)))):
                return .send(.delegate(.linkEstablished(linkID: linkID)))

            case let .link(.element(elementID, .delegate(.dataReceived(data)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.linkDataReceived(linkID: linkID, data: data)))

            case let .link(.element(elementID, .delegate(.closed(reason)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.linkClosed(linkID: linkID, reason: reason)))

            case let .link(.element(elementID, .delegate(.establishmentFailed))):
                guard let destHash = state.links[id: elementID]?.destinationHash else { return .none }
                return .send(.delegate(.linkFailed(destinationHash: destHash)))

            case .interface, .transport, .delegate, .link:
                return .none
            }
        }
    }
}
