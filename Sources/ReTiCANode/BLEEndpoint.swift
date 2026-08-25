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

/// A BLE DRIVER: the FCB-backed `BLEInterface` plus the per-peer `InterfaceID → session-token`
/// map that the shared router's transmit routing resolves against. After the Task-1b hoist the
/// driver no longer owns a `Transport` or a `LinkPlane` — those are SHARED, one each, in the
/// enclosing `TransportEndpoint` container. Each connected BLE peer still gets its own Transport
/// `InterfaceID` (the 1:N pattern), but the container performs the packet-plane and link-plane
/// wiring; this driver only carries the interface, the peer-token map, and the endpoint profile.
@Reducer
public struct BLEEndpoint {
    @ObservableState
    public struct State: Equatable {
        public var ble: BLEInterface.State
        /// InterfaceID → 16-byte peer token, maintained by the container as peers come and go.
        /// The container's transmit routing resolves an outbound `InterfaceID` to a peer through
        /// this map.
        public internal(set) var peerInterfaces: [InterfaceID: Data] = [:]
        /// Profile registered for EVERY peer interface (C1). BLE registers one InterfaceID per
        /// peer; all share the endpoint's profile — per-peer variation is a spec non-goal
        /// (BLEHello carries no such field).
        public let profile: InterfaceProfile

        public init(maxPeers: Int = BLEInterface.defaultMaxPeers,
                    pairingMode: BLEPairingMode = .open,
                    profile: InterfaceProfile = .ble) {
            self.ble = BLEInterface.State(maxPeers: maxPeers, pairingMode: pairingMode)
            self.profile = profile
        }
    }

    public enum Action: Equatable {
        case ble(BLEInterface.Action)
        /// Start the interface.
        case start
        /// Stop the interface.
        case stop

        case delegate(Delegate)
        @CasePathable
        public enum Delegate: Equatable {
            /// A BLE peer connected. BLE-only — never surfaced on `TransportEndpoint`'s unified
            /// delegate; observe via the `.ble(.delegate(.peerOnline))` escape hatch.
            case peerOnline(Data)
            /// A BLE peer disconnected. BLE-only — observe via `.ble(.delegate(.peerOffline))`.
            case peerOffline(Data)
            /// The BLE adapter is terminally unavailable (permission denied / no radio). BLE-only —
            /// observe via `.ble(.delegate(.adapterUnavailable))`. LXMF has no use for it; the app
            /// consumes it to show a permission-denied prompt (S6 → A5).
            case adapterUnavailable(BLEAdapterUnavailable)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.ble, action: \.ble) { BLEInterface() }
        Reduce { _, action in
            switch action {
            case .start:                return .send(.ble(.start))
            case .stop:                 return .send(.ble(.stop))
            case .ble, .delegate:       return .none
            }
        }
    }
}
