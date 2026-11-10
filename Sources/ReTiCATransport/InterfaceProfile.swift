import Foundation
import ReTiCA

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
    /// The stamp value an announce arriving on this interface is checked against (reference
    /// per-interface `destination_cost`, Interface.py:350-353). `nil` uses the Transport-wide
    /// `Transport.State.destinationCost`. Clamped to 0...`NetworkStamp.stampCostCap`, NaN to 0, when
    /// set, as reference's config parser clamps it (Reticulum.py:963-966).
    public var destinationCost: Double? {
        didSet { destinationCost = destinationCost.map(Self.clampedStampCost) }
    }
    /// The stamp value a path request arriving on this interface must carry when stamps are enforced
    /// (reference per-interface `pr_cost`, Interface.py:355-358, read at Transport.py:2103). `nil`
    /// uses the Transport-wide `Transport.State.pathRequestCost`. Clamped as `destinationCost` is
    /// (Reticulum.py:968-971).
    public var pathRequestCost: Double? {
        didSet { pathRequestCost = pathRequestCost.map(Self.clampedStampCost) }
    }

    public init(name: String, bitrate: Int, mode: InterfaceMode = .full,
                hwMTU: Int? = nil, announceCap: Double = 0.02, ifac: IFAC? = nil,
                destinationCost: Double? = nil, pathRequestCost: Double? = nil) {
        precondition(bitrate > 0, "InterfaceProfile.bitrate must be > 0")
        precondition(announceCap > 0 && announceCap <= 1,
                     "announceCap is a fraction in (0, 1], e.g. 0.02 — not a percent")
        self.name = name
        self.bitrate = bitrate
        self.mode = mode
        self.hwMTU = hwMTU
        self.announceCap = announceCap
        self.ifac = ifac
        self.destinationCost = destinationCost.map(Self.clampedStampCost)
        self.pathRequestCost = pathRequestCost.map(Self.clampedStampCost)
    }

    /// `max(0, min(v, STAMP_COST_CAP))` as Python evaluates it: NaN comes out as 0.
    static func clampedStampCost(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), Double(NetworkStamp.stampCostCap))
    }

    /// Reference TCPInterface declared values (TCPInterface.py:76, 42).
    public static let tcp = InterfaceProfile(name: "tcp", bitrate: 10_000_000, hwMTU: 262_144)
    /// ble-reticulum protocol v2.2 peers: HW_MTU 500 (BLEInterface.HW_MTU in the reference);
    /// 80 kbps is a conservative guess until measured live (spec §2.8).
    public static let ble = InterfaceProfile(name: "ble", bitrate: 80_000, hwMTU: 500)
    /// Reference AutoInterface declared values, RNS 1.6.0 (AutoInterface.py:70 BITRATE_GUESS,
    /// :44 HW_MTU), copied to every spawned peer (AutoInterface.py:565, :596). The IFAC size (16,
    /// AutoInterface.py:50) is not a profile field: `AutoEndpoint` builds the IFAC with it.
    public static let auto = InterfaceProfile(name: "auto", bitrate: 10_000_000, hwMTU: 1196)
    /// Reference base-class defaults (Interface.py:104-105).
    public static let `default` = InterfaceProfile(name: "default", bitrate: 62_500)
}
