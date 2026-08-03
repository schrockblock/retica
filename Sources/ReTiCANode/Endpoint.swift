import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport

/// Composes a `TCPClientInterface`, a `Transport` and the interface-agnostic `LinkPlane` into a
/// single runnable Reticulum endpoint, wiring their delegates bidirectionally. Single TCP
/// interface this slice.
///
/// The link/resource/request machinery lives in `LinkPlane`; `Endpoint` is the TCP *host* for it:
/// it decides which links may be created (from `Transport`'s learned paths and local
/// destinations) and resolves the plane's `.delegate(.transmit(InterfaceID, Data))` routing
/// delegate to its one TCP interface.
@Reducer
public struct Endpoint {
    @ObservableState
    public struct State: Equatable {
        public var interface: TCPClientInterface.State
        public var transport: Transport.State
        public var linkPlane: LinkPlane.State = LinkPlane.State()
        public let interfaceID: InterfaceID

        /// Live links (owned by the embedded `LinkPlane`).
        public var links: IdentifiedArrayOf<LinkSession.State> {
            get { linkPlane.links }
            set { linkPlane.links = newValue }
        }
        /// Request-handler registrations (owned by the embedded `LinkPlane`).
        public var registrations: [Data: RequestRegistration] {
            get { linkPlane.registrations }
            set { linkPlane.registrations = newValue }
        }

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
        /// `LinkPlane` actions that have no identically-shaped `Endpoint` case. The rest of the
        /// plane's surface is aliased onto `Endpoint`'s own cases — see `linkPlaneRoute`.
        case linkPlane(LinkPlane.Action)

        case connect
        case disconnect
        case registerLocalDestination(Destination)
        case announce(destinationHash: Data, appData: Data?)
        case send(destinationHash: Data, plaintext: Data)
        case enableRelay(Identity)
        case openLink(destinationHash: Data)
        case requestPath(destinationHash: Data)
        case sendOverLink(linkID: Data, data: Data)
        case sendResourceOverLink(linkID: Data, data: Data)
        case closeLink(linkID: Data)
        case identifyOverLink(linkID: Data, identity: Identity)
        case sendRequestOverLink(linkID: Data, path: String, data: Data)
        case sendResponseOverLink(linkID: Data, requestID: Data, data: Data)
        case sendWithReceiptOverLink(linkID: Data, data: Data, token: Data)
        case registerRequestHandler(path: String, policy: RequestPolicy)
        case deregisterRequestHandler(path: String)

        case delegate(Delegate)
        @CasePathable
        public enum Delegate: Equatable {
            case messageReceived(destinationHash: Data, plaintext: Data)
            case pathLearned(destinationHash: Data, hops: UInt8)
            case sendFailed(destinationHash: Data, reason: Transport.SendFailure)
            case linkEstablished(linkID: Data, destinationHash: Data)
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
            case packetDelivered(token: Data)
            case packetDeliveryFailed(token: Data)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.interface, action: \.interface) { TCPClientInterface() }
        Scope(state: \.transport, action: \.transport) { Transport() }
        Scope(state: \.linkPlane, action: \.linkPlaneRoute) { LinkPlane() }
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
                return .merge(.send(.transport(.interfaceConnected(id))),
                              .send(.transport(.startMaintenance)))
            case .interface(.connectionEvent(.disconnected)):
                return .merge(.send(.transport(.interfaceDisconnected(id))),
                              .send(.transport(.stopMaintenance)))

            case let .transport(.delegate(.transmit(txID, raw))):
                guard txID == id else { return .none }
                return .send(.interface(.send(raw)))
            case let .transport(.delegate(.received(h, p))):
                return .send(.delegate(.messageReceived(destinationHash: h, plaintext: p)))
            case let .transport(.delegate(.pathLearned(h, hops))):
                return .send(.delegate(.pathLearned(destinationHash: h, hops: hops)))
            case let .transport(.delegate(.sendFailed(h, r))):
                return .send(.delegate(.sendFailed(destinationHash: h, reason: r)))

            // --- Transport → LinkPlane ---

            case let .transport(.delegate(.linkPacket(linkID, data))):
                return .send(.linkPlane(.routeLinkPacket(linkID: linkID, data: data)))

            case let .transport(.delegate(.linkRequest(destHash, _, data))):
                guard let owner = state.transport.localDestinations[destHash]?.identity,
                      owner.privateKey != nil
                else { return .none }
                return .send(.linkPlane(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                                           interfaceID: id, data: data)))

            case let .openLink(destinationHash):
                guard let learned = state.transport.learned[destinationHash] else {
                    return .send(.delegate(.linkFailed(destinationHash: destinationHash)))
                }
                // Via a relay (learned nextHop != the destination) → HEADER_2 LINKREQUEST to the relay.
                let relayNextHop: Data? = learned.nextHop == destinationHash ? nil : learned.nextHop
                return .send(.linkPlane(.openLink(initiatorTo: learned.identity,
                                                  destinationHash: destinationHash,
                                                  interfaceID: id, relayNextHop: relayNextHop)))

            case let .requestPath(destinationHash):
                return .send(.transport(.requestPath(destinationHash: destinationHash)))

            // --- LinkPlane delegates → interface / Endpoint delegates ---

            case let .linkPlane(.delegate(.transmit(txID, raw))):
                guard txID == id else { return .none }
                return .send(.interface(.send(raw)))

            case let .linkPlane(.delegate(.linkEstablished(linkID, destHash))):
                return .send(.delegate(.linkEstablished(linkID: linkID, destinationHash: destHash)))
            case let .linkPlane(.delegate(.linkDataReceived(linkID, data))):
                return .send(.delegate(.linkDataReceived(linkID: linkID, data: data)))
            case let .linkPlane(.delegate(.linkClosed(linkID, reason))):
                return .send(.delegate(.linkClosed(linkID: linkID, reason: reason)))
            case let .linkPlane(.delegate(.linkFailed(destHash))):
                return .send(.delegate(.linkFailed(destinationHash: destHash)))
            case let .linkPlane(.delegate(.resourceReceived(linkID, data))):
                return .send(.delegate(.resourceReceived(linkID: linkID, data: data)))
            case let .linkPlane(.delegate(.resourceConcluded(linkID, hash))):
                return .send(.delegate(.resourceConcluded(linkID: linkID, resourceHash: hash)))
            case let .linkPlane(.delegate(.resourceFailed(linkID, hash))):
                return .send(.delegate(.resourceFailed(linkID: linkID, resourceHash: hash)))
            case let .linkPlane(.delegate(.linkIdentified(linkID, identity))):
                return .send(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: identity)))
            case let .linkPlane(.delegate(.requestReceived(linkID, rid, ph, data))):
                return .send(.delegate(.requestReceived(linkID: linkID, requestID: rid, pathHash: ph, data: data)))
            case let .linkPlane(.delegate(.responseReceived(linkID, rid, data))):
                return .send(.delegate(.responseReceived(linkID: linkID, requestID: rid, data: data)))
            case let .linkPlane(.delegate(.requestFailed(linkID, rid))):
                return .send(.delegate(.requestFailed(linkID: linkID, requestID: rid)))
            case let .linkPlane(.delegate(.packetDelivered(token))):
                return .send(.delegate(.packetDelivered(token: token)))
            case let .linkPlane(.delegate(.packetDeliveryFailed(token))):
                return .send(.delegate(.packetDeliveryFailed(token: token)))

            // Every remaining link action is aliased straight into the plane by `linkPlaneRoute`
            // and has already been handled by the `Scope` above.
            case .interface, .transport, .delegate, .linkPlane, .link,
                 .sendOverLink, .sendResourceOverLink, .closeLink, .identifyOverLink,
                 .sendRequestOverLink, .sendResponseOverLink, .sendWithReceiptOverLink,
                 .registerRequestHandler, .deregisterRequestHandler:
                return .none
            }
        }
    }
}

extension Endpoint.Action.AllCasePaths {
    /// The case path `Endpoint` scopes `LinkPlane` through.
    ///
    /// It is a *bijection*, not a forward-plus-mirror pair: every `LinkPlane.Action` that already
    /// had an identically-shaped `Endpoint.Action` case (`.link`, `.sendOverLink`, `.closeLink`,
    /// `.registerRequestHandler`, …) is aliased onto that case, and the plane-only actions
    /// (`.openLink(initiatorTo:…)`, `.acceptLinkRequest`, `.routeLinkPacket`, `.delegate`) ride
    /// `.linkPlane(...)`.
    ///
    /// Two consequences matter:
    ///  1. Callers (and the existing `EndpointTests`) can keep sending AND matching
    ///     `.link(.element(id:action:))`, `.sendResponseOverLink(...)` etc. — plane-originated
    ///     actions surface under exactly those names, because the `Scope` embeds its child
    ///     effects through this path.
    ///  2. There is no action cycle. A mirror (`.link` → `.linkPlane(.link)` → `.link` → …)
    ///     would loop and double-deliver; a bijection delivers each action to the plane exactly
    ///     once, with no re-entry.
    ///
    /// `Endpoint.Action.openLink(destinationHash:)` is deliberately NOT aliased: it is the
    /// host-level action that resolves a learned path before minting the plane's `.openLink`.
    public var linkPlaneRoute: AnyCasePath<Endpoint.Action, LinkPlane.Action> {
        AnyCasePath(
            embed: { plane in
                switch plane {
                case let .link(action):
                    return .link(action)
                case let .sendOverLink(linkID, data):
                    return .sendOverLink(linkID: linkID, data: data)
                case let .sendResourceOverLink(linkID, data):
                    return .sendResourceOverLink(linkID: linkID, data: data)
                case let .identifyOverLink(linkID, identity):
                    return .identifyOverLink(linkID: linkID, identity: identity)
                case let .sendRequestOverLink(linkID, path, data):
                    return .sendRequestOverLink(linkID: linkID, path: path, data: data)
                case let .sendResponseOverLink(linkID, requestID, data):
                    return .sendResponseOverLink(linkID: linkID, requestID: requestID, data: data)
                case let .sendWithReceiptOverLink(linkID, data, token):
                    return .sendWithReceiptOverLink(linkID: linkID, data: data, token: token)
                case let .closeLink(linkID):
                    return .closeLink(linkID: linkID)
                case let .registerRequestHandler(path, policy):
                    return .registerRequestHandler(path: path, policy: policy)
                case let .deregisterRequestHandler(path):
                    return .deregisterRequestHandler(path: path)
                case .openLink, .acceptLinkRequest, .routeLinkPacket, .delegate:
                    return .linkPlane(plane)
                }
            },
            extract: { action in
                switch action {
                case let .link(elementAction):
                    return .link(elementAction)
                case let .sendOverLink(linkID, data):
                    return .sendOverLink(linkID: linkID, data: data)
                case let .sendResourceOverLink(linkID, data):
                    return .sendResourceOverLink(linkID: linkID, data: data)
                case let .identifyOverLink(linkID, identity):
                    return .identifyOverLink(linkID: linkID, identity: identity)
                case let .sendRequestOverLink(linkID, path, data):
                    return .sendRequestOverLink(linkID: linkID, path: path, data: data)
                case let .sendResponseOverLink(linkID, requestID, data):
                    return .sendResponseOverLink(linkID: linkID, requestID: requestID, data: data)
                case let .sendWithReceiptOverLink(linkID, data, token):
                    return .sendWithReceiptOverLink(linkID: linkID, data: data, token: token)
                case let .closeLink(linkID):
                    return .closeLink(linkID: linkID)
                case let .registerRequestHandler(path, policy):
                    return .registerRequestHandler(path: path, policy: policy)
                case let .deregisterRequestHandler(path):
                    return .deregisterRequestHandler(path: path)
                case let .linkPlane(plane):
                    return plane
                default:
                    return nil
                }
            }
        )
    }
}
