import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport

/// A TCP-client DRIVER: a single `TCPClientInterface` plus the metadata (`interfaceID`,
/// `profile`) that the shared router needs to register it. After the Task-1b hoist the driver
/// no longer owns a `Transport` or a `LinkPlane` — those are SHARED, one each, in the enclosing
/// `TransportEndpoint` container, so several drivers route through a single router. The container
/// does all the transport/link-plane wiring against the arriving `interfaceID`; this driver only
/// carries the interface and forwards `connect`/`disconnect`/`send` to it.
///
/// `TransportEndpoint` holds a SET of these (`tcpClients`, keyed by `interfaceID`), one per node
/// dialed, each over its own socket (`TCPConnectionPool`).
@Reducer
public struct TCPEndpoint {
    @ObservableState
    public struct State: Equatable, Identifiable {
        public var interface: TCPClientInterface.State
        public let interfaceID: InterfaceID
        /// Metadata registered with the shared Transport for this interface (C1). Mode/bitrate
        /// are configuration — override at init to declare e.g. a roaming node.
        public let profile: InterfaceProfile
        /// The set key in `TransportEndpoint.tcpClients`: the interface id, which the host app
        /// derives from what the slot dials (`tcp:<host>:<port>`).
        public var id: InterfaceID { interfaceID }

        public init(host: String, port: UInt16, reconnectOnDrop: Bool = true,
                    interfaceID: InterfaceID = InterfaceID("tcp"),
                    profile: InterfaceProfile = .tcp) {
            self.interface = TCPClientInterface.State(host: host, port: port,
                                                      reconnectOnDrop: reconnectOnDrop)
            self.interfaceID = interfaceID
            // An outbound TCP client synthesizes a tunnel on each connect, as reference's
            // TCPClientInterface does (TCPInterface.py:179, 299). Accepted server connections use
            // `TCPServerEndpoint.State.profile`, which leaves it off.
            var profile = profile
            profile.wantsTunnel = true
            self.profile = profile
        }
    }

    public enum Action: Equatable {
        case interface(TCPClientInterface.Action)
        /// Open the socket.
        case connect
        /// Close the socket.
        case disconnect
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.interface, action: \.interface) { TCPClientInterface() }
        Reduce { _, action in
            switch action {
            case .connect:    return .send(.interface(.connect))
            case .disconnect: return .send(.interface(.disconnect))
            case .interface:  return .none
            }
        }
    }
}
