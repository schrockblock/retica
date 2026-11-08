import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport

/// Transport `InterfaceID` for a Meshtastic radio: ONE id per radio (spec Contract 3). The radio is
/// a broadcast medium, so unlike BLE there is no per-peer interface; the id follows the TCP-client
/// lifecycle — registered at the radio's `.connected`, deregistered at `.disconnected`.
public func meshtasticInterfaceID(radio: UUID) -> InterfaceID {
    InterfaceID("meshtastic:" + radio.uuidString)
}

extension InterfaceProfile {
    /// Contract 3: name "meshtastic", hwMTU 500, the `.tcp` default mode, and the EFFECTIVE paced
    /// bitrate of the preset (`Int(202 * 8 / fragmentDelay(preset))`) — what the sender can
    /// actually put on the air, not the LoRa symbol rate.
    ///
    /// Lives here, not in `InterfaceProfile.swift`: the preset table is shared with
    /// `MeshtasticInterface` in `ReTiCAInterfaces`, which `ReTiCATransport` does not depend on.
    public static func meshtastic(modemPreset: Int?) -> InterfaceProfile {
        InterfaceProfile(name: "meshtastic", bitrate: MeshtasticModemPreset.pacedBitrate(modemPreset), hwMTU: 500)
    }
}

/// A Meshtastic DRIVER: the `MeshtasticInterface` plus the endpoint profile the shared router
/// needs. Like the other drivers it owns no `Transport` or `LinkPlane`; `TransportEndpoint` does
/// all the wiring against `interfaceID`.
@Reducer
public struct MeshtasticEndpoint {
    /// landandair's `DEFAULT_IFAC_SIZE` (Meshtastic_Interface.py:30). A peer configured with a
    /// different size cannot interoperate.
    public static let ifacSize = 8

    /// The IFAC to put in a Meshtastic endpoint's profile: always 8-byte access codes.
    public static func ifac(networkName: String?, passphrase: String?) -> IFAC? {
        IFAC(networkName: networkName, passphrase: passphrase, size: ifacSize)
    }

    @ObservableState
    public struct State: Equatable {
        public var interface: MeshtasticInterface.State
        /// Supplies every field of the registered profile except the name, bitrate and hardware MTU,
        /// which are the radio's (the bitrate is known at `.connected`).
        public let profile: InterfaceProfile

        public var interfaceID: InterfaceID { meshtasticInterfaceID(radio: interface.config.radio) }

        /// The radio's diagnostics (reassembly + sender), read-only, for the app's diagnostics view.
        public var counters: MeshtasticCounters { interface.diagnostics }

        public init(config: MeshtasticDriverConfig, profile: InterfaceProfile = .meshtastic(modemPreset: nil)) {
            self.interface = MeshtasticInterface.State(config: config)
            self.profile = profile
        }

        /// The profile registered with the shared router when the radio comes online.
        public func registeredProfile(modemPreset: Int?) -> InterfaceProfile {
            // Start from the host's profile so every field it sets survives; only what the radio
            // decides (name, bitrate from the modem preset, hardware MTU) is overwritten.
            let radio = InterfaceProfile.meshtastic(modemPreset: modemPreset)
            var registered = profile
            registered.name = radio.name
            registered.bitrate = radio.bitrate
            registered.hwMTU = radio.hwMTU
            return registered
        }
    }

    public enum Action: Equatable {
        case interface(MeshtasticInterface.Action)
        case start
        case stop
        case delegate(Delegate)

        /// Meshtastic-only — observe via `TransportEndpoint`'s `.meshtastic(.delegate(...))` hatch;
        /// deliberately absent from the unified surface (LXMF has no use for them).
        @CasePathable
        public enum Delegate: Equatable {
            case radioOnline(myNodeNum: UInt32, modemPreset: Int?)
            case radioOffline(reason: String?)
            case adapterUnavailable(BLEAdapterUnavailable)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.interface, action: \.interface) { MeshtasticInterface() }
        Reduce { _, action in
            switch action {
            case .start:                return .send(.interface(.start))
            case .stop:                 return .send(.interface(.stop))
            case .interface, .delegate: return .none
            }
        }
    }
}
