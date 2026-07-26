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

    public init(identity: Identity, appData: Data?, ratchet: Data?, interfaceID: InterfaceID,
                hops: UInt8, nextHop: Data?, announceEmitted: UInt64,
                learnedAt: Date = Date(timeIntervalSince1970: 0)) {
        self.identity = identity
        self.appData = appData
        self.ratchet = ratchet
        self.interfaceID = interfaceID
        self.hops = hops
        self.nextHop = nextHop
        self.announceEmitted = announceEmitted
        self.learnedAt = learnedAt
    }
}
