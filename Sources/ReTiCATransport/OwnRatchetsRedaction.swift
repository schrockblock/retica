import Foundation

// `OwnRatchets.ring` holds X25519 private keys. Every generic printing path (`description`,
// `debugDescription`, `Mirror`, so `dump`, and `customDump` too, which honours `CustomReflectable`)
// shows the ring as a key count, never the keys. `Data` already prints as a byte count; this keeps
// that true whatever prints the ring.
extension Transport.State.OwnRatchets: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private var redactedRing: String { "<redacted, \(ring.count) keys>" }

    public var description: String {
        "OwnRatchets(ring: \(redactedRing), lastRotation: \(lastRotation.map { "\($0)" } ?? "nil"), enforce: \(enforce))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["ring": redactedRing, "lastRotation": lastRotation as Any, "enforce": enforce],
               displayStyle: .struct)
    }
}
