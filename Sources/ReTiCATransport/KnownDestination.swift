import Foundation
import ReTiCA

/// A remote destination this node has heard a valid announce for: its public identity and the app
/// data it last announced. Reference `Identity.known_destinations` (RNS/Identity.py:94, written by
/// `Identity.remember`, :101-113), the table `Identity.recall` reads.
///
/// Distinct from `LearnedDestination` (the PATH table, reference `Transport.path_table`): a path
/// expires after a week unused and is replaced only by a better announce, while a known destination
/// is refreshed by every valid announce and outlives its path (see `Transport.knownDestinationExpiry`),
/// so a hash heard once can still be recalled after the path is gone.
///
/// **Persistence is the host's job**, as for `LearnedDestination` and `LXMFNode.LearnedPeer`:
/// reference saves the table to `storagepath/known_destinations` and loads it at start
/// (Identity.py:177-233); a ReTiCA host saves `Transport.State.knownDestinations` (the public key is
/// `identity.publicKey`) and restores it with `Transport.Action.rehydrateKnownDestinations`.
public struct KnownDestination: Equatable, Sendable {
    /// Public-only identity recovered from the announce.
    public var identity: Identity
    /// App data from the most recent announce, or nil.
    public var appData: Data?
    /// When the most recent valid announce for this destination was heard (reference entry[0]).
    public var lastHeard: Date
    /// The link-request stamp cost the most recent announce carried, or nil (reference entry[7],
    /// `lr_cost`, read by `Identity.recall_link_cost`). Set only when that announce's network stamp met
    /// the value we demand (`Announce.Parsed.linkCost`). Overwritten by EVERY valid announce, including
    /// one that does not win the path, so a destination that changes its cost is believed at once.
    public var linkCost: Double?
    /// The value of the most recent announce's network stamp, valid or not, or nil when it carried none
    /// (reference entry[6], `Identity.recall_stamp_value`).
    public var stampValue: Double?

    public init(identity: Identity, appData: Data?, lastHeard: Date,
                linkCost: Double? = nil, stampValue: Double? = nil) {
        self.identity = identity
        self.appData = appData
        self.lastHeard = lastHeard
        self.linkCost = linkCost
        self.stampValue = stampValue
    }
}
