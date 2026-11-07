import Foundation
import ReTiCA

/// A destination learned from an announce: its identity (public), plus routing info.
public struct LearnedDestination: Equatable, Sendable {
    public var identity: Identity     // public-only, recovered from the announce
    public var appData: Data?
    public var ratchet: Data?         // received 32-byte ratchet public key, or nil
    public var interfaceID: InterfaceID
    public var hops: UInt8
    public var nextHop: Data?         // transport_id, or nil if directly heard
    public var announceEmitted: UInt64
    public var learnedAt: Date
    /// The link-request stamp cost this destination announced, or nil. Read only from an announce whose
    /// network stamp met the cost we demand (`Announce.Parsed.linkCost`, reference `lr_cost`).
    public var linkCost: Double?
    /// The value of the network stamp on the announce, valid or not, or nil when it carried none
    /// (`Announce.Parsed.stampValue`, reference `stamp_value`).
    public var stampValue: Double?

    public init(identity: Identity, appData: Data?, ratchet: Data?, interfaceID: InterfaceID,
                hops: UInt8, nextHop: Data?, announceEmitted: UInt64,
                learnedAt: Date = Date(timeIntervalSince1970: 0),
                linkCost: Double? = nil, stampValue: Double? = nil) {
        self.identity = identity
        self.appData = appData
        self.ratchet = ratchet
        self.interfaceID = interfaceID
        self.hops = hops
        self.nextHop = nextHop
        self.announceEmitted = announceEmitted
        self.learnedAt = learnedAt
        self.linkCost = linkCost
        self.stampValue = stampValue
    }

    /// The transport instance a packet for `destinationHash` (this entry's destination) must be
    /// addressed to as HEADER_2, or nil when it goes out HEADER_1 with no transport ID.
    ///
    /// Reference inserts the transport header only when the path's hop count is > 1
    /// (RNS `Transport.outbound`, Transport.py: `if Transport.path_table[...][IDX_PT_HOPS] > 1`),
    /// and a relay strips it at `remaining_hops == 1` (`Transport.inbound`, the forward branch).
    /// Reference counts a hop on receipt; ReTiCA stores the ON-WIRE count (see `receiptTimeoutBase`
    /// in Transport.swift), so reference `> 1` is ReTiCA `>= 1`.
    ///
    /// On-wire hops 0 with a next hop that is not the destination is a LOCAL CLIENT of that next hop
    /// (lxmd behind a shared rnsd: rnsd passes its announce on as HEADER_2, transport_id = rnsd,
    /// hops 0). Addressed to rnsd, a HEADER_2 request is handed to the client unchanged and dropped
    /// there, because its transport_id is not the client's — so it must be HEADER_1. (Reference's
    /// other branch, hops == 1 while itself a client of a shared instance, does not apply: ReTiCA is
    /// never a shared-instance client.)
    public func relayNextHop(toward destinationHash: Data) -> Data? {
        guard let nextHop, nextHop != destinationHash, hops >= 1 else { return nil }
        return nextHop
    }
}
