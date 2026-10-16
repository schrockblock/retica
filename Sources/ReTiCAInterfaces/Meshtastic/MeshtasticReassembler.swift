import Foundation

/// Bounded reassembly of landandair fragments (spec §5.2). Pure value type. NOT `BLEReassembler`:
/// that keys buffers by fragment count only, so two interleaved packets from one sender with
/// equal counts corrupt each other.
///
/// Buffers are keyed by (sending node, packet index). Positions are stored by magnitude; the
/// negative (last) position records the packet's fragment count. A packet completes as soon as
/// positions 1...count are all present — whichever fragment arrives last. That is deliberately
/// STRONGER than the reference, which only assembles when the arriving fragment is the negative one
/// (`process_packet`, Meshtastic_Interface.py:380-387): a late middle fragment completes here and
/// is lost there (fixture `reorder`). A completed packet's buffer is dropped, so a late duplicate
/// of a single-fragment packet re-emits it; Transport's packet-hash dedup absorbs that.
public struct MeshtasticReassembler: Equatable, Sendable {
    public static let inactivityTimeout: TimeInterval = 30
    public static let maxBuffersPerSender = 8
    public static let maxBuffersTotal = 64
    /// `Packet.mtu` (500) + an 8-byte IFAC — landandair's DEFAULT_IFAC_SIZE (L30).
    public static let maxPacketLength = 508

    public struct Counters: Equatable, Sendable {
        public var malformed = 0
        public var evicted = 0
        public var timedOut = 0
        public var oversize = 0
        public var completed = 0
        public init() {}
    }

    struct Key: Hashable, Sendable {
        let from: UInt32
        let index: UInt8
    }

    struct Buffer: Equatable, Sendable {
        var bodies: [Int: Data] = [:]
        /// The fragment count, known once the negative position arrived.
        var total: Int?
        var byteCount = 0
        var lastActivity: Date
        /// Insertion/touch order, so eviction is deterministic when dates tie.
        var touch: UInt64
    }

    public private(set) var counters = Counters()
    var buffers: [Key: Buffer] = [:]
    private var touchCounter: UInt64 = 0

    public var bufferCount: Int { buffers.count }

    public init() {}

    public mutating func recordMalformed() { counters.malformed += 1 }

    /// Drop every partial packet (radio disconnect). Counters are diagnostics and survive.
    public mutating func reset() { buffers = [:] }

    /// Insert one data fragment. Returns the reassembled packet when this completes one.
    @discardableResult
    public mutating func receive(from: UInt32, index: UInt8, pos: Int8, body: Data, now: Date) -> Data? {
        purgeInactive(now: now)
        guard pos != 0, !body.isEmpty else {
            counters.malformed += 1
            return nil
        }
        let key = Key(from: from, index: index)
        // `magnitude`, never `abs`: abs(Int8.min) traps.
        let slot = Int(pos.magnitude)
        let isLast = pos < 0
        let body = Data(body)
        touchCounter &+= 1

        var buffer = buffers[key] ?? Buffer(lastActivity: now, touch: touchCounter)
        if conflicts(buffer, slot: slot, isLast: isLast, body: body) {
            buffer = Buffer(lastActivity: now, touch: touchCounter)
        }
        if buffer.bodies[slot] == nil { buffer.byteCount += body.count }
        buffer.bodies[slot] = body
        if isLast { buffer.total = slot }
        buffer.lastActivity = now
        buffer.touch = touchCounter

        if buffer.byteCount > Self.maxPacketLength {
            buffers[key] = nil
            counters.oversize += 1
            return nil
        }
        if let total = buffer.total, buffer.bodies.count == total {
            let ordered = (1...total).compactMap { buffer.bodies[$0] }
            if ordered.count == total {
                buffers[key] = nil
                counters.completed += 1
                return ordered.reduce(into: Data()) { $0.append($1) }
            }
        }
        buffers[key] = buffer
        enforceBounds(sender: from)
        return nil
    }

    /// A fragment that cannot belong to the packet already buffered under its key: a different
    /// body at a position we hold, a last position that disagrees with the known count, or a
    /// position at/after a known last one.
    private func conflicts(_ buffer: Buffer, slot: Int, isLast: Bool, body: Data) -> Bool {
        if let existing = buffer.bodies[slot], existing != body { return true }
        if let total = buffer.total {
            return isLast ? slot != total : slot >= total
        }
        if isLast, let highest = buffer.bodies.keys.max(), highest > slot { return true }
        return false
    }

    private mutating func purgeInactive(now: Date) {
        let stale = buffers.filter { now.timeIntervalSince($0.value.lastActivity) >= Self.inactivityTimeout }
        for key in stale.keys { buffers[key] = nil }
        counters.timedOut += stale.count
    }

    private mutating func enforceBounds(sender: UInt32) {
        while buffers.keys.filter({ $0.from == sender }).count > Self.maxBuffersPerSender {
            evictOldest { $0.from == sender }
        }
        while buffers.count > Self.maxBuffersTotal {
            evictOldest { _ in true }
        }
    }

    private mutating func evictOldest(where include: (Key) -> Bool) {
        let victim = buffers
            .filter { include($0.key) }
            .min { ($0.value.lastActivity, $0.value.touch) < ($1.value.lastActivity, $1.value.touch) }?
            .key
        guard let victim else { return }
        buffers[victim] = nil
        counters.evicted += 1
    }
}
