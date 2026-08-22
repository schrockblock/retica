import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport

/// Deterministic Transport `InterfaceID` for an accepted server connection, keyed by its
/// `TCPConnID`. Node-local: each server derives IDs from the connections IT accepts, so no
/// cross-node coordination is needed — Transport only requires locally-distinct interface IDs.
public func tcpServerInterfaceID(_ conn: TCPConnID) -> InterfaceID {
    InterfaceID("tcpserver:" + String(conn.rawValue))
}

/// A TCP-SERVER DRIVER: a listening `TCPServerInterface` plus the per-connection
/// `InterfaceID → TCPConnID` map that the shared router's transmit routing resolves against.
///
/// This is the 1:N analogue of `BLEEndpoint`: one listener owns N accepted connections, each
/// getting its OWN Transport `InterfaceID` — exactly as reference `TCPServerInterface` spawns one
/// `TCPClientInterface` per socket into `spawned_interfaces` (stock 1.4.2 `TCPInterface.py`
/// `incoming_connection`, spawn at `:591`, `RNS.Transport.add_interface` at `:643`, tracked at
/// `:644-646`). The driver no longer owns a `Transport` or a `LinkPlane` — those are SHARED in
/// the enclosing `TransportEndpoint`; this driver only carries the interface, the connection→id
/// map, and the endpoint profile.
@Reducer
public struct TCPServerEndpoint {
    @ObservableState
    public struct State: Equatable {
        public var interface: TCPServerInterface.State
        /// InterfaceID → connection id, maintained by the container as connections come and go.
        /// The container's transmit routing resolves an outbound `InterfaceID` to a connection
        /// through this map.
        public internal(set) var connInterfaces: [InterfaceID: TCPConnID] = [:]
        /// Profile registered for EVERY accepted connection (C1). All share the endpoint's
        /// profile — per-connection variation is a non-goal (reference copies the parent's config).
        public let profile: InterfaceProfile

        public init(port: UInt16, profile: InterfaceProfile = .tcp) {
            self.interface = TCPServerInterface.State(port: port)
            self.profile = profile
        }
    }

    public enum Action: Equatable {
        case interface(TCPServerInterface.Action)
        /// Start listening.
        case start
        /// Stop listening.
        case stop
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.interface, action: \.interface) { TCPServerInterface() }
        Reduce { _, action in
            switch action {
            case .start:      return .send(.interface(.listen))
            case .stop:       return .send(.interface(.stop))
            case .interface:  return .none
            }
        }
    }
}
