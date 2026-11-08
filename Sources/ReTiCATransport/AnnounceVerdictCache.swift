import Foundation
import ReTiCA

/// Reference RNS 1.6.0's announce verdict caches, `Identity.announce_valid_cache` and
/// `announce_invalid_cache` (Identity.py:682-714, 745-791): what an announce's bytes were judged to
/// be, so the same bytes heard again (a relay's re-broadcast, a held announce released, a replay) are
/// not parsed and signature-checked again. Each holds at most `capacity` entries and evicts the one
/// inserted first.
///
/// Keyed by the packet hash AND the context flag. Reference keys by the packet hash alone, but the
/// packet hash leaves the context flag out (`Packet.hashablePart`) while the parse depends on it (it
/// says whether a ratchet sits in the payload). Keyed by the hash alone, a copy of a valid announce
/// with the flag flipped, heard first, fails its signature and is cached invalid under the genuine
/// announce's key, and the genuine one is then dropped unparsed. Hops and transport ID, also outside
/// the hash, play no part in the parse.
///
/// Session-only. Reference clears both caches when its blackhole list changes
/// (`_reset_validation_caches`, Transport.py:4493, 4515, 4563); this layer has no blackhole list.
struct AnnounceVerdictCache: Equatable {
    /// Reference `__valid_cache_max` and `__invalid_cache_max` (Identity.py:683, 702).
    static let capacity = 128

    struct Key: Hashable {
        let packetHash: Data
        let contextFlag: Bool
        init(_ packet: Packet) {
            packetHash = packet.packetHash
            contextFlag = packet.contextFlag
        }
    }

    /// A valid announce as parsed, with the fixed-point destination cost it was parsed at: the app
    /// data and link cost of a stamped announce depend on that cost.
    struct Valid: Equatable {
        let parsed: Announce.Parsed
        let costFixedPoint: Int
    }

    private(set) var valid = FIFOMap<Key, Valid>(capacity: capacity)
    private(set) var invalid = FIFOMap<Key, Announce.Rejection>(capacity: capacity)

    /// The announce in `packet`, parsed or from the caches, or nil if it is refused. `cost` is the
    /// receiving interface's destination cost.
    ///
    /// * A cached rejection drops the announce unparsed, except a stamp rejection: a low stamp is
    ///   parsed again when `cost` is at or below its value (Identity.py:758-763), and either stamp
    ///   rejection is parsed again when not enforcing (a state reference never reaches, since its
    ///   enforcement is fixed for the process).
    /// * A cached valid announce is reused when it was parsed at the same fixed-point cost, or carries
    ///   no stamp (the cost then changes nothing in the parse). Enforcing, it must carry a stamp that met
    ///   that cost (Identity.py:776-785). A stamped one parsed at another cost is parsed again, so its
    ///   app data and link cost are those of the interface it arrived on now; reference reuses them as
    ///   first parsed.
    mutating func resolve(_ packet: Packet, cost: Double, enforce: Bool) -> Announce.Parsed? {
        let key = Key(packet)
        let costFixedPoint = NetworkStamp.fixedPoint(cost: cost)
        if let rejection = invalid[key] {
            switch rejection {
            case .invalid:
                return nil
            case .noStamp:
                if enforce { return nil }
            case let .lowStamp(value):
                if enforce, costFixedPoint > NetworkStamp.fixedPoint(cost: value) { return nil }
            }
        }
        if let cached = valid[key], cached.costFixedPoint == costFixedPoint || cached.parsed.stamp == nil {
            if enforce, cached.parsed.linkCost == nil { return nil }
            return cached.parsed
        }
        switch Announce.validate(payload: packet.payload, destinationHash: packet.destinationHash,
                                 contextFlagSet: packet.contextFlag, requiredStampValue: cost,
                                 enforceStamp: enforce) {
        case let .success(parsed):
            valid[key] = Valid(parsed: parsed, costFixedPoint: costFixedPoint)
            invalid[key] = nil
            return parsed
        case let .failure(rejection):
            invalid[key] = rejection
            return nil
        }
    }
}

/// A dictionary of at most `capacity` entries that, when full, evicts the key inserted first.
/// Assigning to a present key keeps its place, as assigning to a Python dict does.
struct FIFOMap<Key: Hashable, Value: Equatable>: Equatable {
    let capacity: Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []

    init(capacity: Int) { self.capacity = capacity }

    var count: Int { values.count }
    /// Keys, first inserted first.
    var keys: [Key] { order }

    subscript(key: Key) -> Value? {
        get { values[key] }
        set {
            guard let newValue else {
                if values.removeValue(forKey: key) != nil { order.removeAll { $0 == key } }
                return
            }
            if values.updateValue(newValue, forKey: key) == nil {
                order.append(key)
                if order.count > capacity { values[order.removeFirst()] = nil }
            }
        }
    }
}
