import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport

/// Deterministic Transport `InterfaceID` for a BLE peer, keyed by its 16-byte session token.
/// Node-local: each node derives IDs from the tokens IT observes, so no cross-node
/// coordination is needed — Transport only requires locally-distinct interface IDs.
///
/// Compile-driven adjustment: `Data.hexString` in ReTiCA is `internal`, so we inline the
/// equivalent lowercase-hex conversion here rather than importing it across modules.
public func bleInterfaceID(_ token: Data) -> InterfaceID {
    let hex = token.map { String(format: "%02x", $0) }.joined()
    return InterfaceID("ble:" + hex)
}

/// Composes the FCB-backed `BLEInterface` with `Transport` and the interface-agnostic
/// `LinkPlane`, mapping each connected BLE peer (16-byte session token) to its own Transport
/// `InterfaceID`. Provides packet plane (announces, path learning, opportunistic send/receive)
/// and link plane (links/resources/requests) with per-peer transmit routing.
@Reducer
public struct BLEEndpoint {
    @ObservableState
    public struct State: Equatable {
        public var ble: BLEInterface.State
        public var transport: Transport.State
        public var linkPlane: LinkPlane.State = LinkPlane.State()
        var peerInterfaces: [InterfaceID: Data] = [:]   // InterfaceID → 16-byte peer token
        /// Profile registered for EVERY peer interface (C1). BLE registers one InterfaceID per
        /// peer; all share the endpoint's profile — per-peer variation is a spec non-goal
        /// (BLEHello carries no such field).
        public let profile: InterfaceProfile

        /// Live links (owned by the embedded LinkPlane).
        public var links: IdentifiedArrayOf<LinkSession.State> {
            get { linkPlane.links }
            set { linkPlane.links = newValue }
        }
        /// Request-handler registrations (owned by the embedded LinkPlane).
        public var registrations: [Data: RequestRegistration] {
            get { linkPlane.registrations }
            set { linkPlane.registrations = newValue }
        }

        public init(maxPeers: Int = BLEInterface.defaultMaxPeers,
                    pairingMode: BLEPairingMode = .open,
                    profile: InterfaceProfile = .ble) {
            self.ble = BLEInterface.State(maxPeers: maxPeers, pairingMode: pairingMode)
            self.transport = Transport.State()
            self.profile = profile
        }
    }

    public enum Action: Equatable {
        case ble(BLEInterface.Action)
        case transport(Transport.Action)
        case linkPlane(LinkPlane.Action)

        case start
        case stop
        case registerLocalDestination(Destination)
        case announce(destinationHash: Data, appData: Data?)
        case send(destinationHash: Data, plaintext: Data)
        case enableRelay(Identity)
        case requestPath(destinationHash: Data)
        case openLink(destinationHash: Data)
        case sendOverLink(linkID: Data, data: Data)
        case sendResourceOverLink(linkID: Data, data: Data)
        case identifyOverLink(linkID: Data, identity: Identity)
        case sendRequestOverLink(linkID: Data, path: String, data: Data)
        case sendResponseOverLink(linkID: Data, requestID: Data, data: Data)
        case sendWithReceiptOverLink(linkID: Data, data: Data, token: Data)
        case provePacketOverLink(linkID: Data, packetHash: Data)
        case closeLink(linkID: Data)
        case registerRequestHandler(path: String, policy: RequestPolicy)
        case deregisterRequestHandler(path: String)

        case delegate(Delegate)
        @CasePathable
        public enum Delegate: Equatable {
            case messageReceived(destinationHash: Data, plaintext: Data)
            case pathLearned(destinationHash: Data, hops: UInt8)
            case sendFailed(destinationHash: Data, reason: Transport.SendFailure)
            case peerOnline(Data)
            case peerOffline(Data)
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

    public var body: some ReducerOf<Self> {
        Scope(state: \.ble, action: \.ble) { BLEInterface() }
        Scope(state: \.transport, action: \.transport) { Transport() }
        Scope(state: \.linkPlane, action: \.linkPlane) { LinkPlane() }
        Reduce { state, action in
            switch action {
            case .start:                            return .send(.ble(.start))
            case .stop:                             return .send(.ble(.stop))
            case let .registerLocalDestination(d):  return .send(.transport(.registerLocalDestination(d)))
            case let .announce(h, a):               return .send(.transport(.announce(destinationHash: h, appData: a)))
            case let .send(h, p):                   return .send(.transport(.send(destinationHash: h, plaintext: p)))
            case let .enableRelay(identity):        return .send(.transport(.setTransportIdentity(identity)))

            case let .requestPath(destinationHash):
                return .send(.transport(.requestPath(destinationHash: destinationHash)))

            // --- BLE peer lifecycle → Transport interface set (+ maintenance) ---
            case let .ble(.delegate(.peerOnline(token))):
                let id = bleInterfaceID(token)
                let wasEmpty = state.peerInterfaces.isEmpty
                state.peerInterfaces[id] = token
                var effects: [Effect<Action>] = [
                    .send(.transport(.interfaceConnected(id, state.profile))),
                    .send(.delegate(.peerOnline(token))),
                ]
                if wasEmpty { effects.append(.send(.transport(.startMaintenance))) }
                return .merge(effects)

            case let .ble(.delegate(.peerOffline(token))):
                let id = bleInterfaceID(token)
                state.peerInterfaces[id] = nil
                var effects: [Effect<Action>] = [
                    .send(.transport(.interfaceDisconnected(id))),
                    .send(.delegate(.peerOffline(token))),
                ]
                if state.peerInterfaces.isEmpty { effects.append(.send(.transport(.stopMaintenance))) }
                return .merge(effects)

            case let .ble(.delegate(.packetReceived(token, packet))):
                return .send(.transport(.received(bleInterfaceID(token), packet)))

            // --- Transport → BLE ---
            case let .transport(.delegate(.transmit(txID, raw))):
                // C5 IFAC outbound masking. Lives here (not in Transport) because `state.profile`
                // is in scope at the Endpoint — fewer sites than masking at every Transport
                // emission point — and outbound has no C4 replay constraint (inbound unmasks in
                // Transport so that C4's hold stores the original masked bytes for replay safety).
                guard let token = state.peerInterfaces[txID] else { return .none }
                return .send(.ble(.send(peer: token, packet: state.profile.ifac?.protect(raw) ?? raw)))

            case let .transport(.delegate(.received(h, p))):
                return .send(.delegate(.messageReceived(destinationHash: h, plaintext: p)))
            case let .transport(.delegate(.pathLearned(h, hops))):
                return .send(.delegate(.pathLearned(destinationHash: h, hops: hops)))
            case let .transport(.delegate(.sendFailed(h, r))):
                return .send(.delegate(.sendFailed(destinationHash: h, reason: r)))

            // --- Transport → LinkPlane (per-peer interface) ---
            case let .transport(.delegate(.linkPacket(linkID, data))):
                return .send(.linkPlane(.routeLinkPacket(linkID: linkID, data: data)))

            case let .transport(.delegate(.linkRequest(destHash, arrivalInterface, data))):
                guard let owner = state.transport.localDestinations[destHash]?.identity,
                      owner.privateKey != nil
                else { return .none }
                // Reply on the peer the request arrived from.
                return .send(.linkPlane(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                                           interfaceID: arrivalInterface, data: data)))

            // --- Public link actions → LinkPlane ---
            case let .openLink(destinationHash):
                guard let learned = state.transport.learned[destinationHash] else {
                    return .send(.delegate(.linkFailed(destinationHash: destinationHash)))
                }
                let relayNextHop: Data? = learned.nextHop == destinationHash ? nil : learned.nextHop
                // The learned entry records which BLE peer's interface the destination was heard on.
                return .send(.linkPlane(.openLink(initiatorTo: learned.identity,
                                                  destinationHash: destinationHash,
                                                  interfaceID: learned.interfaceID,
                                                  relayNextHop: relayNextHop)))

            case let .sendOverLink(linkID, data):
                return .send(.linkPlane(.sendOverLink(linkID: linkID, data: data)))
            case let .sendResourceOverLink(linkID, data):
                return .send(.linkPlane(.sendResourceOverLink(linkID: linkID, data: data)))
            case let .identifyOverLink(linkID, identity):
                return .send(.linkPlane(.identifyOverLink(linkID: linkID, identity: identity)))
            case let .sendRequestOverLink(linkID, path, data):
                return .send(.linkPlane(.sendRequestOverLink(linkID: linkID, path: path, data: data)))
            case let .sendResponseOverLink(linkID, requestID, data):
                return .send(.linkPlane(.sendResponseOverLink(linkID: linkID, requestID: requestID, data: data)))
            case let .sendWithReceiptOverLink(linkID, data, token):
                return .send(.linkPlane(.sendWithReceiptOverLink(linkID: linkID, data: data, token: token)))
            case let .provePacketOverLink(linkID, packetHash):
                return .send(.linkPlane(.provePacketOverLink(linkID: linkID, packetHash: packetHash)))
            case let .closeLink(linkID):
                return .send(.linkPlane(.closeLink(linkID: linkID)))
            case let .registerRequestHandler(path, policy):
                return .send(.linkPlane(.registerRequestHandler(path: path, policy: policy)))
            case let .deregisterRequestHandler(path):
                return .send(.linkPlane(.deregisterRequestHandler(path: path)))

            // --- LinkPlane delegates: route transmit per-peer, forward the rest ---
            case let .linkPlane(.delegate(.transmit(txID, raw))):
                // C5 IFAC outbound masking (same rationale as transport transmit above).
                guard let peer = state.peerInterfaces[txID] else { return .none }
                return .send(.ble(.send(peer: peer, packet: state.profile.ifac?.protect(raw) ?? raw)))

            case let .linkPlane(.delegate(.linkEstablished(linkID, destHash))):
                return .send(.delegate(.linkEstablished(linkID: linkID, destinationHash: destHash)))
            case let .linkPlane(.delegate(.linkDataReceived(linkID, data, packetHash))):
                return .send(.delegate(.linkDataReceived(linkID: linkID, data: data, packetHash: packetHash)))
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

            case .ble, .transport, .delegate, .linkPlane:
                return .none
            }
        }
    }
}
