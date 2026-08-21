import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport

/// A Reticulum endpoint over one concrete transport. Presents ONE unified action/delegate
/// surface so compositions above it (`LXMFNode`) stay transport-agnostic: the same
/// `.send`/`.openLink`/`.sendRequestOverLink`… reach whichever endpoint is active, and both
/// endpoints' delegates surface under the same names.
///
/// Transport-specific driving stays available through the `.tcp` / `.ble` escape hatches —
/// which is also where BLE-only delegates (`peerOnline`/`peerOffline`) remain observable; they
/// are deliberately absent from the unified surface because LXMF has no use for them.
@Reducer
public struct TransportEndpoint {
    @ObservableState
    public enum State: Equatable {
        case tcp(TCPEndpoint.State)
        case ble(BLEEndpoint.State)

        /// Learned-destination table of the active transport (identity / appData / path).
        public var learned: [Data: LearnedDestination] {
            switch self {
            case let .tcp(s): return s.transport.learned
            case let .ble(s): return s.transport.learned
            }
        }

        /// Connected interfaces of the active transport. Paired with `learned`: an entry in
        /// `learned` names an `interfaceID`, and only an id present HERE is still reachable —
        /// which is the test `Transport.reachableLearned` performs and `openLink` gates on.
        public var interfaces: [InterfaceID: InterfaceProfile] {
            switch self {
            case let .tcp(s): return s.transport.interfaces
            case let .ble(s): return s.transport.interfaces
            }
        }

        /// Live links of the active transport.
        public var links: IdentifiedArrayOf<LinkSession.State> {
            switch self {
            case let .tcp(s): return s.links
            case let .ble(s): return s.links
            }
        }

        /// Request-handler registrations of the active transport.
        public var registrations: [Data: RequestRegistration] {
            switch self {
            case let .tcp(s): return s.registrations
            case let .ble(s): return s.registrations
            }
        }
    }

    public enum Action: Equatable {
        case tcp(TCPEndpoint.Action)
        case ble(BLEEndpoint.Action)

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
            case linkEstablished(linkID: Data, destinationHash: Data)
            case linkDataReceived(linkID: Data, data: Data, packetHash: Data)
            case linkClosed(linkID: Data, reason: LinkSession.CloseReason)
            case linkFailed(destinationHash: Data, reason: LinkFailure)
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
        Scope(state: \.tcp, action: \.tcp) { TCPEndpoint() }
        Scope(state: \.ble, action: \.ble) { BLEEndpoint() }
        Reduce { state, action in
            switch action {
            // --- unified → the active transport ---
            case .start:
                return route(state, tcp: .connect, ble: .start)
            case .stop:
                return route(state, tcp: .disconnect, ble: .stop)
            case let .registerLocalDestination(d):
                return route(state, tcp: .registerLocalDestination(d), ble: .registerLocalDestination(d))
            case let .announce(h, a):
                return route(state, tcp: .announce(destinationHash: h, appData: a),
                                    ble: .announce(destinationHash: h, appData: a))
            case let .send(h, p):
                return route(state, tcp: .send(destinationHash: h, plaintext: p),
                                    ble: .send(destinationHash: h, plaintext: p))
            case let .enableRelay(i):
                return route(state, tcp: .enableRelay(i), ble: .enableRelay(i))
            case let .requestPath(h):
                return route(state, tcp: .requestPath(destinationHash: h),
                                    ble: .requestPath(destinationHash: h))
            case let .openLink(h):
                return route(state, tcp: .openLink(destinationHash: h),
                                    ble: .openLink(destinationHash: h))
            case let .sendOverLink(l, d):
                return route(state, tcp: .sendOverLink(linkID: l, data: d),
                                    ble: .sendOverLink(linkID: l, data: d))
            case let .sendResourceOverLink(l, d):
                return route(state, tcp: .sendResourceOverLink(linkID: l, data: d),
                                    ble: .sendResourceOverLink(linkID: l, data: d))
            case let .identifyOverLink(l, i):
                return route(state, tcp: .identifyOverLink(linkID: l, identity: i),
                                    ble: .identifyOverLink(linkID: l, identity: i))
            case let .sendRequestOverLink(l, p, d):
                return route(state, tcp: .sendRequestOverLink(linkID: l, path: p, data: d),
                                    ble: .sendRequestOverLink(linkID: l, path: p, data: d))
            case let .sendResponseOverLink(l, r, d):
                return route(state, tcp: .sendResponseOverLink(linkID: l, requestID: r, data: d),
                                    ble: .sendResponseOverLink(linkID: l, requestID: r, data: d))
            case let .sendWithReceiptOverLink(l, d, t):
                return route(state, tcp: .sendWithReceiptOverLink(linkID: l, data: d, token: t),
                                    ble: .sendWithReceiptOverLink(linkID: l, data: d, token: t))
            case let .provePacketOverLink(l, h):
                return route(state, tcp: .provePacketOverLink(linkID: l, packetHash: h),
                                    ble: .provePacketOverLink(linkID: l, packetHash: h))
            case let .closeLink(l):
                return route(state, tcp: .closeLink(linkID: l), ble: .closeLink(linkID: l))
            case let .registerRequestHandler(p, pol):
                return route(state, tcp: .registerRequestHandler(path: p, policy: pol),
                                    ble: .registerRequestHandler(path: p, policy: pol))
            case let .deregisterRequestHandler(p):
                return route(state, tcp: .deregisterRequestHandler(path: p),
                                    ble: .deregisterRequestHandler(path: p))

            // --- child delegates → the unified delegate ---
            case let .tcp(.delegate(d)):
                return .send(.delegate(unify(d)))
            case let .ble(.delegate(d)):
                guard let unified = unify(d) else { return .none }   // BLE-only → not surfaced
                return .send(.delegate(unified))

            case .tcp, .ble, .delegate:
                return .none
            }
        }
    }

    /// Sends the transport-appropriate action to whichever case is active.
    private func route(_ state: State,
                       tcp: TCPEndpoint.Action,
                       ble: BLEEndpoint.Action) -> Effect<Action> {
        switch state {
        case .tcp: return .send(.tcp(tcp))
        case .ble: return .send(.ble(ble))
        }
    }

    /// TCP delegates map 1:1 onto the unified surface.
    private func unify(_ d: TCPEndpoint.Action.Delegate) -> Action.Delegate {
        switch d {
        case let .messageReceived(h, p):        return .messageReceived(destinationHash: h, plaintext: p)
        case let .pathLearned(h, hops):         return .pathLearned(destinationHash: h, hops: hops)
        case let .sendFailed(h, r):             return .sendFailed(destinationHash: h, reason: r)
        case let .linkEstablished(l, h):        return .linkEstablished(linkID: l, destinationHash: h)
        case let .linkDataReceived(l, d, h):    return .linkDataReceived(linkID: l, data: d, packetHash: h)
        case let .linkClosed(l, r):             return .linkClosed(linkID: l, reason: r)
        case let .linkFailed(h, r):             return .linkFailed(destinationHash: h, reason: r)
        case let .resourceReceived(l, d):       return .resourceReceived(linkID: l, data: d)
        case let .resourceConcluded(l, h):      return .resourceConcluded(linkID: l, resourceHash: h)
        case let .resourceFailed(l, h):         return .resourceFailed(linkID: l, resourceHash: h)
        case let .linkIdentified(l, i):         return .linkIdentified(linkID: l, remoteIdentity: i)
        case let .requestReceived(l, r, p, d):  return .requestReceived(linkID: l, requestID: r, pathHash: p, data: d)
        case let .responseReceived(l, r, d):    return .responseReceived(linkID: l, requestID: r, data: d)
        case let .requestFailed(l, r):          return .requestFailed(linkID: l, requestID: r)
        case let .packetDelivered(t):           return .packetDelivered(token: t)
        case let .packetDeliveryFailed(t):      return .packetDeliveryFailed(token: t)
        }
    }

    /// BLE delegates map 1:1 EXCEPT the BLE-only peer lifecycle, which returns nil.
    private func unify(_ d: BLEEndpoint.Action.Delegate) -> Action.Delegate? {
        switch d {
        case .peerOnline, .peerOffline:         return nil     // BLE-only: observe via `.ble`
        case let .messageReceived(h, p):        return .messageReceived(destinationHash: h, plaintext: p)
        case let .pathLearned(h, hops):         return .pathLearned(destinationHash: h, hops: hops)
        case let .sendFailed(h, r):             return .sendFailed(destinationHash: h, reason: r)
        case let .linkEstablished(l, h):        return .linkEstablished(linkID: l, destinationHash: h)
        case let .linkDataReceived(l, d, h):    return .linkDataReceived(linkID: l, data: d, packetHash: h)
        case let .linkClosed(l, r):             return .linkClosed(linkID: l, reason: r)
        case let .linkFailed(h, r):             return .linkFailed(destinationHash: h, reason: r)
        case let .resourceReceived(l, d):       return .resourceReceived(linkID: l, data: d)
        case let .resourceConcluded(l, h):      return .resourceConcluded(linkID: l, resourceHash: h)
        case let .resourceFailed(l, h):         return .resourceFailed(linkID: l, resourceHash: h)
        case let .linkIdentified(l, i):         return .linkIdentified(linkID: l, remoteIdentity: i)
        case let .requestReceived(l, r, p, d):  return .requestReceived(linkID: l, requestID: r, pathHash: p, data: d)
        case let .responseReceived(l, r, d):    return .responseReceived(linkID: l, requestID: r, data: d)
        case let .requestFailed(l, r):          return .requestFailed(linkID: l, requestID: r)
        case let .packetDelivered(t):           return .packetDelivered(token: t)
        case let .packetDeliveryFailed(t):      return .packetDeliveryFailed(token: t)
        }
    }
}
