import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport

/// An AutoInterface DRIVER slot: the `AutoInterface` mechanism plus the per-peer
/// `InterfaceID → AutoPeer` map the shared router's transmit routing resolves against (spec
/// 2026-11-10-autointerface §5.2, §5.7).
///
/// The 1:N shape of `BLEEndpoint` and `TCPServerEndpoint`: every discovered peer is registered with
/// the shared `Transport` as its OWN interface, as reference RNS 1.6.0 spawns one
/// `AutoInterfacePeer` per peer and adds it to Transport (`AutoInterface.py:543-598`). The parent is
/// never registered: the reference's parent is a no-op sink (`AutoInterface.py:617`). The enclosing
/// `TransportEndpoint` does all the wiring; this slot only carries the interface, the peer map and
/// the profile every peer is registered with.
///
/// App-facing signals (`peerAdded`, `peerRemoved`, `carrierLost`/`carrierRecovered`,
/// `multicastUnavailable`, `dataPortInUse`, `noUsableInterfaces`, `localNetworkDenied`) stay on
/// this hatch, at `.auto(.interface(.delegate(...)))`, off the unified surface (spec §6). For the
/// live peer count read `peerInterfaces`: a `.stop` clears the interface's peers without one
/// `peerRemoved` each, and the container deregisters them from this map.
@Reducer
public struct AutoEndpoint {
    /// One registered peer: the address the interface keys it by, and the NIC it was first heard on
    /// (part of its `InterfaceID`; the interface reports `peerRemoved(addr:)` without it).
    public struct AutoPeer: Equatable, Sendable {
        public var addr: String
        public var nic: String
    }

    @ObservableState
    public struct State: Equatable {
        public var interface: AutoInterface.State
        /// InterfaceID → peer, maintained by the container as peers come and go.
        public internal(set) var peerInterfaces: [InterfaceID: AutoPeer] = [:]
        /// Profile registered for EVERY peer interface. The reference copies the parent's bitrate,
        /// announce cap, mode and IFAC to each spawned peer (`AutoInterface.py:543-598`), so all
        /// peers share it (spec §4.9.1-3).
        public let profile: InterfaceProfile
        /// `.removeAuto` is waiting for `driver.stop()` to return before it drops the slot.
        public internal(set) var removalPending = false

        /// - Parameters:
        ///   - profile: bitrate, mode, announce cap and stamp costs for every peer. Its `ifac` is
        ///     REPLACED: the IFAC is built here from `ifacNetworkName`/`ifacPassphrase` at size 16,
        ///     the AutoInterface default (`AutoInterface.py:50`, applied at `Reticulum.py:1130-1131`),
        ///     so another profile's IFAC size is never inherited (spec R9).
        ///   - ifacNetworkName, ifacPassphrase: the IFAC credentials; both nil means an open network.
        public init(config: AutoInterfaceConfig = AutoInterfaceConfig(),
                    profile: InterfaceProfile = .auto,
                    ifacNetworkName: String? = nil,
                    ifacPassphrase: String? = nil) {
            self.interface = AutoInterface.State(config: config, ifacSize: AutoInterfaceWire.defaultIFACSize)
            var profile = profile
            profile.ifac = IFAC(networkName: ifacNetworkName, passphrase: ifacPassphrase,
                                size: AutoInterfaceWire.defaultIFACSize)
            self.profile = profile
        }

        /// The registered peer with this address, if any.
        func peer(addr: String) -> (id: InterfaceID, peer: AutoPeer)? {
            peerInterfaces.first { $0.value.addr == addr }.map { ($0.key, $0.value) }
        }
    }

    public enum Action: Equatable {
        case interface(AutoInterface.Action)
        /// Start the interface.
        case start
        /// Stop the interface.
        case stop
    }

    /// The Transport `InterfaceID` of a peer: `auto:<nic>/<addr>`, mirroring the reference's
    /// `AutoInterfacePeer[ifname/addr]` (`AutoInterface.py:649-650`) so logs line up (spec §5.2).
    public static func autoInterfaceID(nic: String, addr: String) -> InterfaceID {
        InterfaceID("auto:\(nic)/\(addr)")
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.interface, action: \.interface) { AutoInterface() }
        Reduce { _, action in
            switch action {
            case .start:      return .send(.interface(.start))
            case .stop:       return .send(.interface(.stop))
            case .interface:  return .none
            }
        }
    }
}
