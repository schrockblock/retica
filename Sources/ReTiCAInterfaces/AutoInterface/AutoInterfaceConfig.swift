import Foundation

/// Configuration of an AutoInterface (spec 2026-11-10-autointerface §3 and §5.2).
///
/// Reference: RNS 1.6.0 `Interfaces/AutoInterface.py`. Defaults come from `AI:47-49`.
public struct AutoInterfaceConfig: Equatable, Sendable {
    /// Discovery scope. The reference accepts exactly these five names, case-insensitively, and
    /// crashes its constructor on anything else (`AI:190-201`). An enum makes the bad value
    /// unrepresentable, and `init?(configValue:)` rejects it at parse time.
    public enum Scope: String, Equatable, Sendable, CaseIterable {
        case link, admin, site, organisation, global

        /// Multicast scope nibble (`AI:52-56`).
        public var nibble: UInt8 {
            switch self {
            case .link: return 0x2
            case .admin: return 0x4
            case .site: return 0x5
            case .organisation: return 0x8
            case .global: return 0xe
            }
        }

        /// Parses the `discovery_scope` config value. Case-insensitive. Returns nil for an unknown
        /// name (the reference crashes there, `AI:190-201` and spec §3, we reject).
        public init?(configValue: String) {
            self.init(rawValue: configValue.lowercased())
        }
    }

    /// Multicast address type (`AI:58-59`).
    public enum AddressType: String, Equatable, Sendable, CaseIterable {
        case permanent, temporary

        /// Address-type nibble (`AI:58-59`).
        public var nibble: UInt8 {
            switch self {
            case .permanent: return 0x0
            case .temporary: return 0x1
            }
        }

        /// Parses `multicast_address_type`. Anything unrecognised falls back to temporary, as the
        /// reference does (`AI:176-183`).
        public init(configValue: String) {
            self = AddressType(rawValue: configValue.lowercased()) ?? .temporary
        }
    }

    /// UTF-8 group id (`AI:164-167`), default `reticulum`.
    public var groupID: Data
    public var scope: Scope
    public var addressType: AddressType
    /// Multicast discovery port. Unicast (reverse peering) discovery is `discoveryPort + 1` (`AI:174`).
    public var discoveryPort: UInt16
    public var dataPort: UInt16
    /// Allow-list of NIC names. Empty means all (`AI:154-157`).
    public var devices: [String]
    public var ignoredDevices: [String]
    /// Maximum number of peers. A new peer beyond it is dropped (spec §9 R4, deviation D4). The
    /// reference has no cap.
    public var peerCap: Int

    public init(
        groupID: Data = AutoInterfaceWire.defaultGroupID,
        scope: Scope = .link,
        addressType: AddressType = .temporary,
        discoveryPort: UInt16 = AutoInterfaceWire.defaultDiscoveryPort,
        dataPort: UInt16 = AutoInterfaceWire.defaultDataPort,
        devices: [String] = [],
        ignoredDevices: [String] = [],
        peerCap: Int = 64
    ) {
        self.groupID = groupID
        self.scope = scope
        self.addressType = addressType
        self.discoveryPort = discoveryPort
        self.dataPort = dataPort
        self.devices = devices
        self.ignoredDevices = ignoredDevices
        self.peerCap = peerCap
    }

    /// Unicast discovery port (`AI:174`).
    public var unicastDiscoveryPort: UInt16 { discoveryPort &+ 1 }

    /// NIC name prefixes ReTiCA skips on top of the reference (spec §5.5.5, §8.3): VPN and Private
    /// Relay tunnels and cellular. No wire effect.
    static let retiCAIgnoredPrefixes = ["utun", "ipsec", "pdp_ip"]

    /// NIC eligibility, spec §5.5 rules 1-5 in this order (reference order `AI:218-231`).
    /// Rule 6 (adopt the last `fe80:` address) belongs to whoever enumerates NICs, see
    /// `selectLinkLocal`.
    public func isEligible(nicName: String) -> Bool {
        // 1. `lo0` is always skipped on Darwin, even when listed in `devices` (`AI:220`).
        if nicName == "lo0" { return false }
        // 2. The Darwin ignore list, unless explicitly listed in `devices` (`AI:67`, `AI:221`).
        if AutoInterfaceWire.darwinIgnoreIfs.contains(nicName), !devices.contains(nicName) { return false }
        // 3. `ignored_devices`.
        if ignoredDevices.contains(nicName) { return false }
        // 4. A non-empty `devices` is an allow-list.
        if !devices.isEmpty, !devices.contains(nicName) { return false }
        // 5. ReTiCA addition: tunnels and cellular, unless explicitly listed.
        if Self.retiCAIgnoredPrefixes.contains(where: { nicName.hasPrefix($0) }), !devices.contains(nicName) {
            return false
        }
        return true
    }

    /// Spec §5.5.6: when a NIC has several `fe80:` addresses, adopt the LAST in getifaddrs order
    /// (`AI:235-240`). Addresses that do not start with `fe80:` are ignored. Nil when there is none.
    public static func selectLinkLocal(_ addrs: [String]) -> String? {
        addrs.last(where: { $0.hasPrefix("fe80:") })
    }
}
