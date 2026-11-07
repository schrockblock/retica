import Foundation

/// Propagation-node announce app-data (LXMF discovery). A msgpack array a propagation node includes in
/// its RNS announce so clients can read its config. Mirrors lxmf 1.3.0
/// LXMRouter.get_propagation_node_app_data / pn_announce_data_is_valid:
/// `[false, timebase, node_state, per_transfer_limit, per_sync_limit, [stamp_cost, flex, peering_cost], metadata, [fractional costs]?]`.
/// Element [7] is transitional: reference says it moves into [5] after RNS 1.6.2 (LXMRouter.py:399).
/// Field semantics (auto-peering, limit enforcement) are app/mesh-level; this is the wire format + validity.
public struct PNAnnounce: Equatable {
    public var timebase: Int
    public var nodeState: Bool
    public var perTransferLimit: Int
    public var perSyncLimit: Int
    public var targetStampCost: Int
    public var stampCostFlexibility: Int
    public var peeringCost: Int
    public var metadata: MsgPackValue          // element [6]; empty map by default

    public init(timebase: Int, nodeState: Bool, perTransferLimit: Int, perSyncLimit: Int,
                targetStampCost: Int, stampCostFlexibility: Int, peeringCost: Int,
                metadata: MsgPackValue = .map([])) {
        self.timebase = timebase; self.nodeState = nodeState
        self.perTransferLimit = perTransferLimit; self.perSyncLimit = perSyncLimit
        self.targetStampCost = targetStampCost; self.stampCostFlexibility = stampCostFlexibility
        self.peeringCost = peeringCost; self.metadata = metadata
    }

    public var packed: Data {
        MsgPack.encode(.array([
            .bool(false),                       // [0] legacy flag
            .uint(UInt64(timebase)),
            .bool(nodeState),
            .uint(UInt64(perTransferLimit)),
            .uint(UInt64(perSyncLimit)),
            .array([.uint(UInt64(targetStampCost)), .uint(UInt64(stampCostFlexibility)), .uint(UInt64(peeringCost))]),
            metadata,
        ]))
    }

    /// Parse + validate announce app-data. Returns nil unless the msgpack shape matches
    /// pn_announce_data_is_valid: >= 7 elements, [1] number, [2] bool, [3]/[4] number, [5] 3 numbers,
    /// [6] a map, and [7], when present, 3 numbers. Element [0] (legacy flag) is ignored.
    ///
    /// Three things reference tolerates and this must too:
    /// * Trailing bytes. A stamped RNS 1.6 announce has an 18-byte extension after the array.
    /// * Float limits. Reference runs `int()` over [1], [3] and [4], and MeshChatX computes the limits
    ///   as `bytes / 1000`, a Python float. They truncate here as they do there.
    /// * Fractional costs. Reference prefers [7] over [5]. We keep Int fields and take the ceiling,
    ///   which is what reference publishes in [5] during the transition.
    ///
    /// Every field comes from an unauthenticated announce. The conversions reject negative values,
    /// NaN, infinities and anything past Int.max rather than truncating or trapping: a negative Int
    /// would later trap in `packed` (UInt64(Int) traps on a negative).
    public static func parse(_ data: Data) -> PNAnnounce? {
        guard case let .array(items)? = MsgPack.decodeLeadingValue(data), items.count >= 7,
              let timebase = items[1].nonNegativeTruncated,
              case let .bool(nodeState) = items[2],
              let transfer = items[3].nonNegativeTruncated,
              let sync = items[4].nonNegativeTruncated,
              case let .array(wholeCosts) = items[5], wholeCosts.count == 3,
              // Checked even when [7] supplies the values, as reference does (LXMF.py:252-258).
              wholeCosts.allSatisfy({ $0.nonNegativeCeiling != nil })
        else { return nil }
        let metadata = items[6]
        switch metadata {
        case .map, .intMap: break
        default: return nil
        }
        // Reference rejects the whole announce when [7] is present and malformed (LXMF.py:262-269).
        var costs = wholeCosts
        if items.count > 7 {
            guard case let .array(fractional) = items[7], fractional.count >= 3 else { return nil }
            costs = fractional
        }
        guard let cost = costs[0].nonNegativeCeiling,
              let flexibility = costs[1].nonNegativeCeiling,
              let peering = costs[2].nonNegativeCeiling
        else { return nil }
        return PNAnnounce(timebase: timebase, nodeState: nodeState,
                          perTransferLimit: transfer, perSyncLimit: sync,
                          targetStampCost: cost, stampCostFlexibility: flexibility,
                          peeringCost: peering, metadata: metadata)
    }

    /// True iff `data` is well-formed announce app-data (mirrors pn_announce_data_is_valid).
    public static func isValid(_ data: Data) -> Bool { parse(data) != nil }
}

extension MsgPackValue {
    /// Whether this is a msgpack number, the check behind reference's `type(x) == float or int`.
    var isNumber: Bool {
        switch self {
        case .uint, .int, .float, .double: return true
        default: return false
        }
    }

    /// A number rounded up to a non-negative Int. Nil for anything else, for negatives, and for NaN,
    /// infinities or values past Int.max: `Int(exactly:)` returns nil for those instead of trapping.
    var nonNegativeCeiling: Int? { nonNegativeInt(rounding: .up) }

    /// A number with its fraction dropped, like Python's `int()`, with the same rejections.
    var nonNegativeTruncated: Int? { nonNegativeInt(rounding: .towardZero) }

    private func nonNegativeInt(rounding: FloatingPointRoundingRule) -> Int? {
        switch self {
        case let .uint(u): return Int(exactly: u)
        case let .int(i): return i >= 0 ? Int(exactly: i) : nil
        case let .float(f): return f >= 0 ? Int(exactly: Double(f).rounded(rounding)) : nil
        case let .double(d): return d >= 0 ? Int(exactly: d.rounded(rounding)) : nil
        default: return nil
        }
    }
}
