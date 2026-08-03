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

/// Composes the FCB-backed `BLEInterface` with `Transport`, mapping each connected BLE peer
/// (16-byte session token) to its own Transport `InterfaceID`. Packet plane only: announces,
/// path learning, opportunistic send/receive. Links/resources/requests are follow-ons.
@Reducer
public struct BLEEndpoint {
    @ObservableState
    public struct State: Equatable {
        public var ble: BLEInterface.State
        public var transport: Transport.State
        var peerInterfaces: [InterfaceID: Data] = [:]   // InterfaceID → 16-byte peer token

        public init(maxPeers: Int = BLEInterface.defaultMaxPeers,
                    pairingMode: BLEPairingMode = .open) {
            self.ble = BLEInterface.State(maxPeers: maxPeers, pairingMode: pairingMode)
            self.transport = Transport.State()
        }
    }

    public enum Action: Equatable {
        case ble(BLEInterface.Action)
        case transport(Transport.Action)

        case start
        case stop
        case registerLocalDestination(Destination)
        case announce(destinationHash: Data, appData: Data?)
        case send(destinationHash: Data, plaintext: Data)
        case enableRelay(Identity)

        case delegate(Delegate)
        @CasePathable
        public enum Delegate: Equatable {
            case messageReceived(destinationHash: Data, plaintext: Data)
            case pathLearned(destinationHash: Data, hops: UInt8)
            case sendFailed(destinationHash: Data, reason: Transport.SendFailure)
            case peerOnline(Data)
            case peerOffline(Data)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.ble, action: \.ble) { BLEInterface() }
        Scope(state: \.transport, action: \.transport) { Transport() }
        Reduce { state, action in
            switch action {
            case .start:                            return .send(.ble(.start))
            case .stop:                             return .send(.ble(.stop))
            case let .registerLocalDestination(d):  return .send(.transport(.registerLocalDestination(d)))
            case let .announce(h, a):               return .send(.transport(.announce(destinationHash: h, appData: a)))
            case let .send(h, p):                   return .send(.transport(.send(destinationHash: h, plaintext: p)))
            case let .enableRelay(identity):        return .send(.transport(.setTransportIdentity(identity)))

            // --- BLE peer lifecycle → Transport interface set (+ maintenance) ---
            case let .ble(.delegate(.peerOnline(token))):
                let id = bleInterfaceID(token)
                let wasEmpty = state.peerInterfaces.isEmpty
                state.peerInterfaces[id] = token
                var effects: [Effect<Action>] = [
                    .send(.transport(.interfaceConnected(id))),
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
                guard let token = state.peerInterfaces[txID] else { return .none }
                return .send(.ble(.send(peer: token, packet: raw)))

            case let .transport(.delegate(.received(h, p))):
                return .send(.delegate(.messageReceived(destinationHash: h, plaintext: p)))
            case let .transport(.delegate(.pathLearned(h, hops))):
                return .send(.delegate(.pathLearned(destinationHash: h, hops: hops)))
            case let .transport(.delegate(.sendFailed(h, r))):
                return .send(.delegate(.sendFailed(destinationHash: h, reason: r)))

            case .ble, .transport, .delegate:
                return .none
            }
        }
    }
}
