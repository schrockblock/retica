import Foundation
import ReTiCA

/// Bitrate-aware link timing (2026-10-16 Meshtastic spec, amended Contract 4).
///
/// HOP SEMANTICS. Hop arguments are the ON-WIRE count ReTiCA stores (`LearnedDestination.hops`):
/// Transport never increments on receipt, so a directly heard peer is 0. `h = max(1, wire)` is
/// the convention the existing per-hop timers use (`Transport`'s link-table proof deadline and
/// receipt timeout). It is deliberately NOT the reference's wire + 1 (`RNS/Transport.py:1496`,
/// local 1.4.1 fork increments on receipt) — decided in the spec amendment.
public enum LinkTiming {
    /// The fixed establishment timeout ReTiCA used before Contract 4. Kept as the floor of both
    /// establishment formulas and as the value when the bitrate is unknown.
    public static let defaultEstablishmentTimeout: TimeInterval = 15

    /// RNS `Link.ESTABLISHMENT_TIMEOUT_PER_HOP` = `Reticulum.DEFAULT_PER_HOP_TIMEOUT` = 6 s
    /// (`RNS/Link.py:75`; `RNS/Reticulum.py:143` in the local fork, :142 in stock 1.4.2).
    public static let establishmentTimeoutPerHop: TimeInterval = 6

    /// Seconds to clock one MTU onto an interface of `bitrate` bits/s: the latency term of
    /// reference `Transport.first_hop_timeout`, `Reticulum.MTU * next_hop_per_byte_latency`
    /// (`RNS/Transport.py:2782-2791`). Callers guarantee `bitrate > 0`.
    public static func firstHopLatency(bitrate: Int) -> TimeInterval {
        Double(Packet.mtu * 8) / Double(bitrate)
    }

    /// `max(1, wire)`, clamped at PATHFINDER_M. Computed in `Int` so no hop value can trap.
    public static func effectiveHops(wire: UInt8) -> Int {
        min(max(1, Int(wire)), Int(Packet.maxHops))
    }

    /// Initiator: `max(15, MTU·8/b + 6 + 6·h)` — the shape of reference `Link.py:282-283`
    /// (`first_hop_timeout + ESTABLISHMENT_TIMEOUT_PER_HOP * max(1, hops_to)`) plus the 15 s floor.
    /// `bitrate` is the next-hop interface's (`Transport.State.nextHopInterfaceProfile`); unknown → 15.
    public static func initiatorEstablishmentTimeout(bitrate: Int?, wireHops: UInt8) -> TimeInterval {
        guard let bitrate, bitrate > 0 else { return defaultEstablishmentTimeout }
        let h = Double(effectiveHops(wire: wireHops))
        return max(defaultEstablishmentTimeout,
                   firstHopLatency(bitrate: bitrate) + establishmentTimeoutPerHop + establishmentTimeoutPerHop * h)
    }

    /// Responder: `max(15, 2·MTU·8/b + 6)`, `bitrate` = the interface the LINKREQUEST arrived on;
    /// unknown → 15. Two MTUs of airtime (our LRPROOF out, their LRRTT back) plus one per-hop allowance.
    ///
    /// No hop term: a LINKREQUEST's hop count is attacker-controlled, and this timeout is how long a
    /// half-open element spends `LinkPlane`'s unauthenticated `maxIncompleteResponderLinks` budget.
    /// DELIBERATE DEVIATION from reference `6·hops + KEEPALIVE` (`RNS/Link.py:204`), per the spec.
    public static func responderEstablishmentTimeout(bitrate: Int?) -> TimeInterval {
        guard let bitrate, bitrate > 0 else { return defaultEstablishmentTimeout }
        return max(defaultEstablishmentTimeout,
                   2 * firstHopLatency(bitrate: bitrate) + establishmentTimeoutPerHop)
    }

    /// Extra allowance on a RELAY's link-table proof deadline: one MTU of airtime on the interface
    /// the LINKREQUEST ARRIVED on — reference `extra_link_proof_timeout(packet.receiving_interface)`
    /// (`RNS/Transport.py:2794-2796`, applied at :1643). Unknown → 0.
    public static func relayProofExtraTimeout(bitrate: Int?) -> TimeInterval {
        guard let bitrate, bitrate > 0 else { return 0 }
        return firstHopLatency(bitrate: bitrate)
    }
}
