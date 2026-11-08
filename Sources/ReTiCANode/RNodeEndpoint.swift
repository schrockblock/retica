import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport

/// Transport `InterfaceID` for an RNode: ONE id per radio (spec Contract 3). Registered at the
/// radio's online report, deregistered when it goes offline.
public func rnodeInterfaceID(radio: UUID) -> InterfaceID {
    InterfaceID("rnode:" + radio.uuidString)
}

extension InterfaceProfile {
    /// Contract 3: name "rnode", hwMTU 508, mode `.full`, and the LoRa bitrate of the params
    /// (`RNodeLoRaParams.bitrate`), or `RNodeEndpoint.unknownBitrate` while they are not known.
    ///
    /// Lives here, not in `InterfaceProfile.swift`, for the reason at `MeshtasticEndpoint.swift:19-20`:
    /// the params type is in `ReTiCAInterfaces`, which `ReTiCATransport` does not depend on.
    public static func rnode(params: RNodeLoRaParams?) -> InterfaceProfile {
        InterfaceProfile(name: "rnode", bitrate: params?.bitrate ?? RNodeEndpoint.unknownBitrate,
                         mode: .full, hwMTU: 508)
    }
}

/// An RNode DRIVER: the `RNodeInterface` plus the endpoint profile the shared router needs. Like
/// the other drivers it owns no `Transport` or `LinkPlane`; `TransportEndpoint` does all the
/// wiring against `interfaceID`.
@Reducer
public struct RNodeEndpoint {
    /// The RNS reference's `DEFAULT_IFAC_SIZE` for RNodeInterface (and Sideband's default). A peer
    /// configured with a different size cannot interoperate.
    public static let ifacSize = 8

    /// The bitrate of a profile built before the radio reported its params: the slowest
    /// SF12 / 125 kHz / CR 4:8 rate, so the router never over-estimates the link.
    public static let unknownBitrate = 183

    /// The IFAC to put in an RNode endpoint's profile: always 8-byte access codes.
    public static func ifac(networkName: String?, passphrase: String?) -> IFAC? {
        IFAC(networkName: networkName, passphrase: passphrase, size: ifacSize)
    }

    @ObservableState
    public struct State: Equatable {
        public var interface: RNodeInterface.State
        /// Supplies ONLY the IFAC and the mode. The bitrate is the radio's, known when it reports.
        public let profile: InterfaceProfile

        public var interfaceID: InterfaceID { rnodeInterfaceID(radio: interface.config.radio) }

        /// The radio's diagnostics (packets, drops, errors), read-only, for the app.
        public var counters: RNodeCounters { interface.diagnostics }

        /// The radio's last signal, channel load and hardware error, read-only, for the app.
        public var telemetry: RNodeTelemetry { interface.telemetry }

        public init(config: RNodeDriverConfig, profile: InterfaceProfile = .rnode(params: nil)) {
            self.interface = RNodeInterface.State(config: config)
            self.profile = profile
        }

        /// The profile registered with the shared router when the radio comes online: the params
        /// it echoed set the bitrate; IFAC and mode come from the endpoint's profile.
        public func registeredProfile(params: RNodeLoRaParams) -> InterfaceProfile {
            var registered = InterfaceProfile.rnode(params: params)
            registered.mode = profile.mode
            registered.ifac = profile.ifac
            return registered
        }
    }

    public enum Action: Equatable {
        case interface(RNodeInterface.Action)
        case start
        case stop
        case delegate(Delegate)

        /// RNode-only: observe via `TransportEndpoint`'s `.rnode(.delegate(...))` hatch;
        /// deliberately absent from the unified surface.
        @CasePathable
        public enum Delegate: Equatable {
            case radioOnline(RNodeRadioReport)
            case radioOffline(reason: String?)
            case adapterUnavailable(BLEAdapterUnavailable)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.interface, action: \.interface) { RNodeInterface() }
        Reduce { _, action in
            switch action {
            case .start:                return .send(.interface(.start))
            case .stop:                 return .send(.interface(.stop))
            case .interface, .delegate: return .none
            }
        }
    }
}
