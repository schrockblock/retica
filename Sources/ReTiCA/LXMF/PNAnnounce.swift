import Foundation

/// Propagation-node announce app-data (LXMF discovery). A msgpack array a propagation node includes in
/// its RNS announce so clients can read its config. Mirrors lxmf 1.3.0
/// LXMRouter.get_propagation_node_app_data (LXMRouter.py:387-401) / pn_announce_data_is_valid
/// (LXMF.py:239-273):
/// `[false, timebase, node_state, per_transfer_limit, per_sync_limit, [ceil(stamp_cost), ceil(flex), ceil(peering_cost)], metadata, [stamp_cost, flex, peering_cost]]`.
/// Element [7] carries the exact (fractional) costs and is transitional: reference says it moves into
/// [5] after RNS 1.6.2 (LXMRouter.py:399). Older nodes send seven elements, integers in [5].
/// Field semantics (auto-peering, limit enforcement) are app/mesh-level; this is the wire format + validity.
///
/// **The three costs are unauthenticated and unbounded once parsed.** `parse` accepts any number there,
/// including negatives, NaN and infinities, because reference's validity test does (`float()` of each).
/// Every consumer gates the value it uses: `LXMFNode.propagationStampCost` (client),
/// `LXMFPropagation.peeringCostAcceptable` (peering).
public struct PNAnnounce: Equatable, Sendable {
    public var timebase: Int
    public var nodeState: Bool
    public var perTransferLimit: Int
    public var perSyncLimit: Int
    public var targetStampCost: Double
    public var stampCostFlexibility: Double
    public var peeringCost: Double
    public var metadata: MsgPackValue          // element [6]; empty map by default

    public init(timebase: Int, nodeState: Bool, perTransferLimit: Int, perSyncLimit: Int,
                targetStampCost: Double, stampCostFlexibility: Double, peeringCost: Double,
                metadata: MsgPackValue = .map([])) {
        self.timebase = timebase; self.nodeState = nodeState
        self.perTransferLimit = perTransferLimit; self.perSyncLimit = perSyncLimit
        self.targetStampCost = targetStampCost; self.stampCostFlexibility = stampCostFlexibility
        self.peeringCost = peeringCost; self.metadata = metadata
    }

    /// The eight-element LXMF 1.3.0 layout: [5] the integer ceilings, [7] the exact costs as float64
    /// (lxmd reads them with `as_float`, and the defaults are floats, LXMRouter.py:63-67).
    ///
    /// Never traps, whatever the fields hold. A node's own costs are sanitized before they get here
    /// (`PropagationStore`), but the fields are public and a parsed announce may hold NaN or a
    /// negative: those encode as reference would write the Python value where it can (a negative
    /// ceiling as a signed int) and as a float64 where reference's `ceil` would raise (NaN,
    /// infinities) or the ceiling does not fit 64 bits. `perTransferLimit` / `perSyncLimit` /
    /// `timebase` are Ints; a negative one encodes as a signed int instead of trapping.
    public var packed: Data {
        let costs = [targetStampCost, stampCostFlexibility, peeringCost]
        return MsgPack.encode(.array([
            .bool(false),                       // [0] legacy flag
            Self.integer(timebase),
            .bool(nodeState),
            Self.integer(perTransferLimit),
            Self.integer(perSyncLimit),
            .array(costs.map(Self.ceiling)),    // [5]
            metadata,                           // [6]
            .array(costs.map { .double($0) }),  // [7] transitional exact costs
        ]))
    }

    private static func integer(_ value: Int) -> MsgPackValue {
        value >= 0 ? .uint(UInt64(value)) : .int(Int64(value))
    }

    /// Python's `ceil(cost)` as msgpack: an int when the ceiling is finite and fits, else the
    /// float64 itself (reference would raise there; see `packed`).
    private static func ceiling(_ cost: Double) -> MsgPackValue {
        let c = cost.rounded(.up)
        if c >= 0, let u = UInt64(exactly: c) { return .uint(u) }
        if c < 0, let i = Int64(exactly: c) { return .int(i) }
        return .double(c)
    }

    /// Parse + validate announce app-data. Returns nil unless the msgpack shape matches
    /// pn_announce_data_is_valid: >= 7 elements, [1] number, [2] bool, [3]/[4] number, [5] 3 numbers,
    /// [6] a map, and [7], when present, 3 numbers. Element [0] (legacy flag) is ignored.
    ///
    /// Things reference tolerates and this must too:
    /// * Trailing bytes. A stamped RNS 1.6 announce has an 18-byte extension after the array.
    /// * Float limits. Reference runs `int()` over [1], [3] and [4], and MeshChatX computes the limits
    ///   as `bytes / 1000`, a Python float. They truncate here as they do there.
    /// * Fractional costs. Reference prefers [7] over [5] (`pn_stamp_cost_from_app_data`,
    ///   LXMF.py:229-237; the peer handler, LXMRouter.py:2707-2711), and so do we, exactly.
    /// * Any number as a cost. Reference checks only that `float()` accepts each of the three, so a
    ///   negative, NaN, infinite or huge cost is a VALID announce there, and is here. The value is
    ///   surfaced as a Double, unclamped; consumers gate it (see the type's note).
    ///
    /// Not tolerated, though reference's `float()` / `int()` would take them: a string, bytes or a bool
    /// in a numeric slot (pre-existing narrowing; no reference emitter writes one).
    ///
    /// The limits and the timebase reject negative values, NaN, infinities and anything past Int.max
    /// rather than truncating or trapping (pre-existing; narrower than reference's `int()`).
    public static func parse(_ data: Data) -> PNAnnounce? {
        guard case let .array(items)? = MsgPack.decodeLeadingValue(data), items.count >= 7,
              let timebase = items[1].nonNegativeTruncated,
              case let .bool(nodeState) = items[2],
              let transfer = items[3].nonNegativeTruncated,
              let sync = items[4].nonNegativeTruncated,
              case let .array(wholeCosts) = items[5], wholeCosts.count >= 3,
              // Checked even when [7] supplies the values, as reference does (LXMF.py:252-258).
              wholeCosts.prefix(3).allSatisfy({ $0.numberValue != nil })
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
        guard let cost = costs[0].numberValue,
              let flexibility = costs[1].numberValue,
              let peering = costs[2].numberValue
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

    /// A msgpack number as a Double, as Python's `float()` reads it (exact for the integers a cost
    /// takes; a uint past 2^53 rounds, as `float()` does). Nil for anything that is not a number.
    var numberValue: Double? {
        switch self {
        case let .uint(u): return Double(u)
        case let .int(i): return Double(i)
        case let .float(f): return Double(f)
        case let .double(d): return d
        default: return nil
        }
    }

    /// A number with its fraction dropped, like Python's `int()`, as a non-negative Int. Nil for
    /// anything else, for negatives, and for NaN, infinities or values past Int.max:
    /// `Int(exactly:)` returns nil for those instead of trapping.
    var nonNegativeTruncated: Int? {
        switch self {
        case let .uint(u): return Int(exactly: u)
        case let .int(i): return i >= 0 ? Int(exactly: i) : nil
        case let .float(f): return f >= 0 ? Int(exactly: Double(f).rounded(.towardZero)) : nil
        case let .double(d): return d >= 0 ? Int(exactly: d.rounded(.towardZero)) : nil
        default: return nil
        }
    }
}
