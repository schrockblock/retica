import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCATransport

/// The interface-agnostic link/resource/request plane: owns the live `LinkSession`s and the
/// request-handler registry, and surfaces link lifecycle + resource + request delegates.
///
/// It never reads `Transport` state — the host passes in whatever a link needs at creation
/// time (identity, destination hash, the `InterfaceID` the link rides). Outbound link packets
/// are surfaced as `.delegate(.transmit(interfaceID, raw))`; the host resolves that
/// `InterfaceID` to a concrete interface (one fixed ID for TCP; a per-peer map for BLE).
@Reducer
public struct LinkPlane {
    @ObservableState
    public struct State: Equatable {
        public var links: IdentifiedArrayOf<LinkSession.State> = []
        public var registrations: [Data: RequestRegistration] = [:]
        public init(links: IdentifiedArrayOf<LinkSession.State> = [],
                    registrations: [Data: RequestRegistration] = [:]) {
            self.links = links
            self.registrations = registrations
        }
    }

    public enum Action: Equatable {
        case link(IdentifiedActionOf<LinkSession>)

        /// Create an initiator link and start establishment.
        case openLink(initiatorTo: Identity, destinationHash: Data,
                      interfaceID: InterfaceID, relayNextHop: Data?)
        /// Create a responder link for an inbound LINKREQUEST and accept it.
        case acceptLinkRequest(owner: Identity, destinationHash: Data,
                               interfaceID: InterfaceID, data: Data)
        /// Route an inbound link-addressed packet to the link that owns it.
        case routeLinkPacket(linkID: Data, arrivalInterface: InterfaceID, data: Data)

        case sendOverLink(linkID: Data, data: Data)
        case sendResourceOverLink(linkID: Data, data: Data)
        case identifyOverLink(linkID: Data, identity: Identity)
        case sendRequestOverLink(linkID: Data, path: String, data: Data)
        case sendResponseOverLink(linkID: Data, requestID: Data, data: Data)
        case sendWithReceiptOverLink(linkID: Data, data: Data, token: Data)
        /// Prove one inbound data packet on `linkID` (reference `RNS.Packet.prove()`).
        case provePacketOverLink(linkID: Data, packetHash: Data)
        case closeLink(linkID: Data)
        case registerRequestHandler(path: String, policy: RequestPolicy)
        case deregisterRequestHandler(path: String)

        case delegate(Delegate)
        @CasePathable
        public enum Delegate: Equatable {
            /// Send `data` on the interface identified by this `InterfaceID`.
            case transmit(InterfaceID, Data)
            case linkEstablished(linkID: Data, destinationHash: Data)
            case linkDataReceived(linkID: Data, data: Data, packetHash: Data)
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

    @Dependency(\.uuid) var uuid
    @Dependency(\.requestResponder) var requestResponder

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .openLink(identity, destinationHash, interfaceID, relayNextHop):
                let newID = uuid()
                state.links.append(LinkSession.State(id: newID, initiatorTo: identity,
                                                     destinationHash: destinationHash,
                                                     interfaceID: interfaceID,
                                                     relayNextHop: relayNextHop))
                return .send(.link(.element(id: newID, action: .establish)))

            case let .acceptLinkRequest(owner, destinationHash, interfaceID, data):
                let newID = uuid()
                state.links.append(LinkSession.State(id: newID, responderFor: owner,
                                                     destinationHash: destinationHash,
                                                     interfaceID: interfaceID))
                return .send(.link(.element(id: newID, action: .acceptRequest(data))))

            case let .routeLinkPacket(linkID, arrivalInterface, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                // Re-home: a BLE InterfaceID is derived from the peer's HELLO session token, so a
                // reconnected peer is a DIFFERENT interface and the binding taken at link creation is
                // stale — outbound would go to a dead interface until the ~60s watchdog closed the link.
                //
                // Re-homing follows link ADDRESSING, not link authentication. The gate here is
                // cleartext addressing only (destinationType == .link, destinationHash == linkID).
                // Decryption and validation happen downstream in LinkSession.received, which may still
                // reject the packet — by which time the interface has already moved. Consequently:
                //
                // - No replay protection: link traffic bypasses seenPacketHashes (Transport.swift:283-285)
                //   so a captured link packet re-injected from another interface re-homes the link.
                //   In a multi-peer mesh a duplicate arriving over a second peer does the same
                //   non-adversarially.
                // - RNS divergence: RNS gates delivery on interface match (RNS/Transport.py:2166-2187)
                //   and uses a stable tunnel_id exchanged in the interface handshake for endpoint
                //   re-appearance. We lack that stable identity.
                // - Keepalive wrinkle: keepalives are plaintext 0xFF/0xFE byte compares
                //   (LinkSession.swift:309-310, 534), so on an idle link the only inbound packet
                //   available to re-home from does NOT authenticate. Gating re-homing on successful
                //   decryption is therefore a real design decision, not a one-liner — deferred.
                //
                // Inert on TCP, whose single fixed InterfaceID always matches.
                if element.interfaceID != arrivalInterface {
                    state.links[id: element.id]?.interfaceID = arrivalInterface
                    // Re-home all in-flight resource transfers. ResourceTransfer.State.interfaceID is
                    // a snapshot taken at creation; every transfer transmit uses that stored copy
                    // (ResourceTransfer.swift:20, forwarded verbatim at LinkSession.swift:597-598).
                    // Without this loop, any transfer already running when the peer reconnects keeps
                    // firing parts, hashmap updates, proofs, and cancels at the dead interface.
                    for tid in state.links[id: element.id]?.transfers.ids ?? [] {
                        state.links[id: element.id]?.transfers[id: tid]?.interfaceID = arrivalInterface
                    }
                }
                return .send(.link(.element(id: element.id, action: .received(data))))

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

            case let .sendWithReceiptOverLink(linkID, data, token):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .sendWithReceipt(data: data, token: token))))

            case let .provePacketOverLink(linkID, packetHash):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .provePacket(packetHash: packetHash))))

            case let .closeLink(linkID):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .close)))

            case let .registerRequestHandler(path, policy):
                state.registrations[Crypto.truncatedHash(Data(path.utf8))] = RequestRegistration(path: path, policy: policy)
                return .none

            case let .deregisterRequestHandler(path):
                state.registrations[Crypto.truncatedHash(Data(path.utf8))] = nil
                return .none

            // --- LinkSession element delegates → LinkPlane delegates ---

            case let .link(.element(_, .delegate(.transmit(txID, raw)))):
                return .send(.delegate(.transmit(txID, raw)))

            case let .link(.element(elementID, .delegate(.established(linkID, _)))):
                guard let destHash = state.links[id: elementID]?.destinationHash else { return .none }
                return .send(.delegate(.linkEstablished(linkID: linkID, destinationHash: destHash)))

            case let .link(.element(elementID, .delegate(.dataReceived(data, packetHash)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.linkDataReceived(linkID: linkID, data: data, packetHash: packetHash)))

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
                    // No registered handler for this path: surface to the app.
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

            case let .link(.element(_, .delegate(.packetDelivered(token)))):
                return .send(.delegate(.packetDelivered(token: token)))

            case let .link(.element(_, .delegate(.packetDeliveryFailed(token)))):
                return .send(.delegate(.packetDeliveryFailed(token: token)))

            case .link, .delegate:
                return .none
            }
        }
        .forEach(\.links, action: \.link) { LinkSession() }
    }
}
