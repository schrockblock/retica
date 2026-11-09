import Foundation
import ReTiCA

/// A destination learned from an announce: its identity (public), plus routing info.
public struct LearnedDestination: Equatable, Sendable {
    public var identity: Identity     // public-only, recovered from the announce
    public var appData: Data?
    /// **Ignored.** Transport neither reads nor writes this: a peer's ratchet lives on
    /// `KnownDestination.ratchet`, read through `Transport.State.recallRatchet(destinationHash:now:)`.
    /// Kept only so a host that still stores it with the path row keeps compiling; it is whatever
    /// the host put in (nil for every entry Transport builds).
    @available(*, deprecated, message: "Ignored by Transport. A peer's ratchet is KnownDestination.ratchet; read it with Transport.State.recallRatchet(destinationHash:now:).")
    public var ratchet: Data? {
        get { legacyRatchet }
        set { legacyRatchet = newValue }
    }
    private var legacyRatchet: Data?
    public var interfaceID: InterfaceID
    public var hops: UInt8
    /// The announce's transport_id, or the destination's own hash when heard directly: Transport
    /// always sets `packet.transportId ?? packet.destinationHash`. Nil only in a value built
    /// elsewhere (a test, or a host's rehydrated entry); `relayNextHop` treats nil as direct.
    public var nextHop: Data?
    public var announceEmitted: UInt64
    public var learnedAt: Date
    // No link cost or stamp value here: a path is replaced only by a better announce, so a cost kept
    // on it would go stale when the destination changed it in an announce that lost the path. They
    // live on `KnownDestination`, which every valid announce refreshes, as reference keeps them.

    /// `ratchet` is ignored by Transport (see the property); it defaults to nil and is kept for
    /// hosts that still pass it.
    public init(identity: Identity, appData: Data?, ratchet: Data? = nil, interfaceID: InterfaceID,
                hops: UInt8, nextHop: Data?, announceEmitted: UInt64,
                learnedAt: Date = Date(timeIntervalSince1970: 0)) {
        self.identity = identity
        self.appData = appData
        self.legacyRatchet = ratchet
        self.interfaceID = interfaceID
        self.hops = hops
        self.nextHop = nextHop
        self.announceEmitted = announceEmitted
        self.learnedAt = learnedAt
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
