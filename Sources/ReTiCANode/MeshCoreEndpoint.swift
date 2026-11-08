import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport

/// Transport `InterfaceID` for a MeshCore radio: ONE id per radio (spec Contract 3). The radio is a
/// broadcast medium, so unlike BLE there is no per-peer interface; the id follows the TCP-client
/// lifecycle — registered at the radio's `.online`, deregistered at `.offline`.
public func meshCoreInterfaceID(radio: UUID) -> InterfaceID {
    InterfaceID("meshcore:" + radio.uuidString)
}

extension InterfaceProfile {
    /// Contract 3: name "meshcore", hwMTU 500, the `.tcp` default mode, and the EFFECTIVE paced
    /// bitrate of the link (`MeshCoreLinkPacing.bitrate`; 236 for nil or out-of-range params) —
    /// what the sender can actually put on the air, not the LoRa symbol rate. Always positive, so
    /// `InterfaceProfile`'s `bitrate > 0` precondition cannot trap on nonsense radio params.
    ///
    /// Lives here, not in `InterfaceProfile.swift`: the pacing table is shared with
    /// `MeshCoreInterface` in `ReTiCAInterfaces`, which `ReTiCATransport` does not depend on.
    public static func meshCore(params: MeshCoreLinkParams?) -> InterfaceProfile {
        InterfaceProfile(name: "meshcore", bitrate: MeshCoreLinkPacing.bitrate(params), hwMTU: 500)
    }
}

/// A MeshCore DRIVER: the `MeshCoreInterface` plus the endpoint profile the shared router needs.
/// Like the other drivers it owns no `Transport` or `LinkPlane`; `TransportEndpoint` does all the
/// wiring against `interfaceID`.
@Reducer
public struct MeshCoreEndpoint {
    /// ScotMesh's IFAC size for this interface. A peer configured with a different size cannot
    /// interoperate.
    public static let ifacSize = 8

    /// The IFAC to put in a MeshCore endpoint's profile: always 8-byte access codes.
    public static func ifac(networkName: String?, passphrase: String?) -> IFAC? {
        IFAC(networkName: networkName, passphrase: passphrase, size: ifacSize)
    }

    @ObservableState
    public struct State: Equatable {
        public var interface: MeshCoreInterface.State
        /// Supplies every field of the registered profile except the name, bitrate and hardware MTU,
        /// which are the radio's (the bitrate is known at `.online`).
        public let profile: InterfaceProfile

        public var interfaceID: InterfaceID { meshCoreInterfaceID(radio: interface.config.radio) }

        /// The radio's diagnostics (reassembly, sender, limiter), read-only, for the app's
        /// diagnostics view.
        public var counters: MeshCoreCounters { interface.diagnostics }

        public init(config: MeshCoreDriverConfig, profile: InterfaceProfile = .meshCore(params: nil)) {
            self.interface = MeshCoreInterface.State(config: config)
            self.profile = profile
        }

        /// The profile registered with the shared router when the radio comes online.
        public func registeredProfile(params: MeshCoreLinkParams?) -> InterfaceProfile {
            // Start from the host's profile so every field it sets survives; only what the radio
            // decides (name, bitrate from the params, hardware MTU) is overwritten.
            let radio = InterfaceProfile.meshCore(params: params)
            var registered = profile
            registered.name = radio.name
            registered.bitrate = radio.bitrate
            registered.hwMTU = radio.hwMTU
            return registered
        }
    }

    public enum Action: Equatable {
        case interface(MeshCoreInterface.Action)
        case start
        case stop
        case removeChannel
        case setCanRoute(Bool)
        case delegate(Delegate)

        /// MeshCore-only — `radioOnline`, `radioOffline` and `adapterUnavailable` are translated
        /// by `TransportEndpoint`, which touches the router; the other two are translated here.
        @CasePathable
        public enum Delegate: Equatable {
            case radioOnline(publicKey: Data, params: MeshCoreLinkParams?)
            case radioOffline(reason: String?)
            case adapterUnavailable(BLEAdapterUnavailable)
            case retiredChannelsCleared
            case channelRemoved(Bool)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.interface, action: \.interface) { MeshCoreInterface() }
        Reduce { _, action in
            switch action {
            case .start:                return .send(.interface(.start))
            case .stop:                 return .send(.interface(.stop))
            case .removeChannel:        return .send(.interface(.removeChannel))
            case let .setCanRoute(on):  return .send(.interface(.setCanRoute(on)))
            case .interface(.delegate(.retiredChannelsCleared)):
                return .send(.delegate(.retiredChannelsCleared))
            case let .interface(.delegate(.channelRemoved(ok))):
                return .send(.delegate(.channelRemoved(ok)))
            case .interface, .delegate: return .none
            }
        }
    }
}
