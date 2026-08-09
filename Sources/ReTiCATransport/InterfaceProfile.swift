import Foundation

/// RNS interface operating mode. Raw values are the reference wire constants
/// (RNS Interface.py:45-51). `internal` is a Swift keyword, hence `interfaceInternal`.
public enum InterfaceMode: UInt8, Equatable, Sendable {
    case full              = 0x01
    case pointToPoint      = 0x02
    case accessPoint       = 0x03
    case roaming           = 0x04
    case boundary          = 0x05
    case gateway           = 0x06
    case interfaceInternal = 0x07
}

/// Per-interface metadata an endpoint declares when registering an interface with Transport.
/// Mode is CONFIGURATION, not an interface property — every shipped reference interface
/// hardcodes MODE_FULL and config overwrites it (Reticulum.py:736,911) — so the profile is
/// supplied at registration, keeping interface reducers mechanism-only.
public struct InterfaceProfile: Equatable, Sendable {
    public var name: String
    /// Bits per second. Zero/negative is a programmer error, not "unknown": reference RNS
    /// silently hard-blocks all announce relay on a nil/0 bitrate (Transport.py:1282).
    public var bitrate: Int
    public var mode: InterfaceMode
    public var hwMTU: Int?
    /// Fraction of bandwidth for relayed announces — 0.02 = 2%, NEVER a percent. Reference has
    /// a lazy-init bug storing the raw `2` (Interface.py:322-323); we store the fraction once.
    public var announceCap: Double
    /// C5: IFAC configuration for this interface. `nil` means the interface is on an open
    /// network (no access control). When set, inbound packets are unmasked by Transport and
    /// outbound packets are masked by the Endpoint. `Equatable` still holds because `IFAC`
    /// is `Equatable`.
    public var ifac: IFAC? = nil

    public init(name: String, bitrate: Int, mode: InterfaceMode = .full,
                hwMTU: Int? = nil, announceCap: Double = 0.02, ifac: IFAC? = nil) {
        precondition(bitrate > 0, "InterfaceProfile.bitrate must be > 0")
        precondition(announceCap > 0 && announceCap <= 1,
                     "announceCap is a fraction in (0, 1], e.g. 0.02 — not a percent")
        self.name = name
        self.bitrate = bitrate
        self.mode = mode
        self.hwMTU = hwMTU
        self.announceCap = announceCap
        self.ifac = ifac
    }

    /// Reference TCPInterface declared values (TCPInterface.py:76, 42).
    public static let tcp = InterfaceProfile(name: "tcp", bitrate: 10_000_000, hwMTU: 262_144)
    /// Reference (fork) BLEInterface declared values (BLEInterface.py:40, 41).
    public static let ble = InterfaceProfile(name: "ble", bitrate: 80_000, hwMTU: 1196)
    /// Reference base-class defaults (Interface.py:104-105).
    public static let `default` = InterfaceProfile(name: "default", bitrate: 62_500)
}
