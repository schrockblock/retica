import Foundation

/// Propagation-node announce app-data (LXMF discovery). A msgpack 7-element array a propagation node
/// includes in its RNS announce so clients can read its config. Mirrors lxmf 1.1.0
/// LXMRouter.get_propagation_node_app_data / pn_announce_data_is_valid:
/// `[false, timebase, node_state, per_transfer_limit, per_sync_limit, [stamp_cost, flex, peering_cost], metadata]`.
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
    /// pn_announce_data_is_valid: >= 7 elements, [1] uint, [2] bool, [3]/[4] uint, [5] a 3-uint array,
    /// [6] a map. Element [0] (legacy flag) is ignored.
    public static func parse(_ data: Data) -> PNAnnounce? {
        guard case let .array(items)? = MsgPack.decodeValue(data), items.count >= 7,
              case let .uint(timebase) = items[1],
              case let .bool(nodeState) = items[2],
              case let .uint(transfer) = items[3],
              case let .uint(sync) = items[4],
              case let .array(costs) = items[5], costs.count == 3,
              case let .uint(cost) = costs[0], case let .uint(flex) = costs[1], case let .uint(peer) = costs[2]
        else { return nil }
        let metadata = items[6]
        switch metadata {
        case .map, .intMap: break
        default: return nil
        }
        // Each field is a wire UInt64. Int(UInt64) traps on values > Int.max — identical to
        // Python pn_announce_data_is_valid (LXMF.py:230-243) wrapping each int() in its own
        // try/except so any bad field fails the whole predicate. We reject rather than truncate:
        // truncating produces a negative Int that would later trap in PNAnnounce.packed
        // (UInt64(Int) traps on a negative). Task 7 fix; Task 7 brief §constraint.
        guard let tbInt  = Int(exactly: timebase),
              let trInt  = Int(exactly: transfer),
              let syInt  = Int(exactly: sync),
              let coInt  = Int(exactly: cost),
              let flInt  = Int(exactly: flex),
              let peInt  = Int(exactly: peer)
        else { return nil }
        return PNAnnounce(timebase: tbInt, nodeState: nodeState,
                          perTransferLimit: trInt, perSyncLimit: syInt,
                          targetStampCost: coInt, stampCostFlexibility: flInt,
                          peeringCost: peInt, metadata: metadata)
    }

    /// True iff `data` is well-formed announce app-data (mirrors pn_announce_data_is_valid).
    public static func isValid(_ data: Data) -> Bool { parse(data) != nil }
}
