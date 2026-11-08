import Foundation
import ReTiCA

/// The §5.5 announce and path-request limiter. Reads unmasked packets only.
///
/// Announces are keyed on their destination hash. Path requests (DATA + PLAIN) are keyed on
/// the requested destination, the first 16 bytes of the payload, not on the fixed control
/// hash they're addressed to. A drop stamps, consumes and counts nothing but the drop counter.
public struct MeshCoreAnnounceLimiter: Equatable, Sendable {
    public static let maxAnnounceHops: UInt8 = 2
    public static let announceInterval: TimeInterval = 600
    public static let heardRequestBypass: TimeInterval = 15
    public static let pathRequestBurst: TimeInterval = 60
    public static let pathRequestInterval: TimeInterval = 1800
    public static let aggregateWindow: TimeInterval = 600
    public static let maxPathRequestsPerWindow = 6
    public static let maxRelayedAnnouncesPerWindow = 6
    public static let maxRelayedPathResponsesPerWindow = 12
    public static let maxEntries = 512

    public struct Counters: Equatable, Sendable {
        public var announcesLimited = 0
        public var pathRequestsLimited = 0

        public init() {}
    }

    private struct Stamp: Equatable, Sendable {
        var at: Date
        var touch: Int
    }

    private struct Burst: Equatable, Sendable {
        var first: Date
        var last: Date
        var touch: Int
    }

    public private(set) var counters = Counters()

    private var announces: [Data: Stamp] = [:]
    private var pathRequests: [Data: Burst] = [:]
    private var heard: [Data: Stamp] = [:]
    private var relayedAnnounceTimes: [Date] = []
    private var relayedPathResponseTimes: [Date] = []
    private var pathRequestTimes: [Date] = []
    private var touchCounter = 0

    var announceEntryCount: Int { announces.count }
    var pathRequestEntryCount: Int { pathRequests.count }
    var heardEntryCount: Int { heard.count }

    public init() {}

    /// Outbound. true = put it on the radio. `unmasked` is never IFAC-masked.
    public mutating func admit(unmasked: Data, now: Date) -> Bool {
        guard let packet = Packet(raw: unmasked) else { return true }
        switch (packet.packetType, packet.destinationType) {
        case (.announce, _):
            return admitAnnounce(packet, now: now)
        case (.data, .plain):
            return admitPathRequest(key: Data(packet.payload.prefix(16)), now: now)
        default:
            return true
        }
    }

    /// Inbound, already past the IFAC gate. Records a heard path request.
    public mutating func noteHeard(unmasked: Data, now: Date) {
        guard let packet = Packet(raw: unmasked),
            packet.packetType == .data, packet.destinationType == .plain
        else { return }
        prune(now: now)
        heard[Data(packet.payload.prefix(16))] = Stamp(at: now, touch: nextTouch())
        Self.evictOldest(&heard, by: { ($0.at, $0.touch) })
    }

    // MARK: - Private

    private mutating func admitAnnounce(_ packet: Packet, now: Date) -> Bool {
        prune(now: now)
        let isPathResponse = packet.context == .pathResponse
        if packet.hops > Self.maxAnnounceHops, !isPathResponse {
            return dropAnnounce()
        }
        let destination = packet.destinationHash
        let answering = heard[destination].map { heardIsLive($0.at, now: now) } ?? false
        if !answering, let stamp = announces[destination], announceIsHeld(stamp.at, now: now) {
            return dropAnnounce()
        }
        let relayed = packet.hops >= 1
        if relayed {
            let full =
                isPathResponse
                ? relayedPathResponseTimes.count >= Self.maxRelayedPathResponsesPerWindow
                : relayedAnnounceTimes.count >= Self.maxRelayedAnnouncesPerWindow
            if full { return dropAnnounce() }
        }

        announces[destination] = Stamp(at: now, touch: nextTouch())
        Self.evictOldest(&announces, by: { ($0.at, $0.touch) })
        heard[destination] = nil
        if relayed {
            if isPathResponse {
                relayedPathResponseTimes.append(now)
            } else {
                relayedAnnounceTimes.append(now)
            }
        }
        return true
    }

    private mutating func admitPathRequest(key: Data, now: Date) -> Bool {
        prune(now: now)
        // `prune` keeps only entries still held, so an entry here is inside its burst window
        // (keep `first`, update `last` on allow) or held. One 1800 s past `last` is already gone:
        // a new burst.
        let burst = pathRequests[key]
        if let entry = burst, !Self.isWithin(since: entry.first, now: now, limit: Self.pathRequestBurst) {
            return dropPathRequest()
        }
        guard pathRequestTimes.count < Self.maxPathRequestsPerWindow else {
            return dropPathRequest()
        }

        let touch = nextTouch()
        if var entry = burst {
            entry.last = now
            entry.touch = touch
            pathRequests[key] = entry
        } else {
            pathRequests[key] = Burst(first: now, last: now, touch: touch)
        }
        Self.evictOldest(&pathRequests, by: { ($0.last, $0.touch) })
        pathRequestTimes.append(now)
        return true
    }

    private mutating func dropAnnounce() -> Bool {
        counters.announcesLimited += 1
        return false
    }

    private mutating func dropPathRequest() -> Bool {
        counters.pathRequestsLimited += 1
        return false
    }

    private mutating func nextTouch() -> Int {
        touchCounter += 1
        return touchCounter
    }

    private func announceIsHeld(_ stamp: Date, now: Date) -> Bool {
        Self.isWithin(since: stamp, now: now, limit: Self.announceInterval)
    }

    private func heardIsLive(_ stamp: Date, now: Date) -> Bool {
        Self.isWithin(since: stamp, now: now, limit: Self.heardRequestBypass)
    }

    private func pathRequestIsHeld(_ last: Date, now: Date) -> Bool {
        Self.isWithin(since: last, now: now, limit: Self.pathRequestInterval)
    }

    private func inAggregateWindow(_ stamp: Date, now: Date) -> Bool {
        Self.isWithin(since: stamp, now: now, limit: Self.aggregateWindow)
    }

    /// A window computed as negative elapsed time (the clock went backwards) counts as expired.
    private static func isWithin(since start: Date, now: Date, limit: TimeInterval) -> Bool {
        let elapsed = now.timeIntervalSince(start)
        return elapsed >= 0 && elapsed < limit
    }

    private mutating func prune(now: Date) {
        announces = announces.filter { announceIsHeld($0.value.at, now: now) }
        heard = heard.filter { heardIsLive($0.value.at, now: now) }
        pathRequests = pathRequests.filter { pathRequestIsHeld($0.value.last, now: now) }
        relayedAnnounceTimes = relayedAnnounceTimes.filter { inAggregateWindow($0, now: now) }
        relayedPathResponseTimes = relayedPathResponseTimes.filter { inAggregateWindow($0, now: now) }
        pathRequestTimes = pathRequestTimes.filter { inAggregateWindow($0, now: now) }
    }

    private static func evictOldest<Value>(
        _ map: inout [Data: Value], by order: (Value) -> (Date, Int)
    ) {
        guard map.count > maxEntries,
            let oldest = map.min(by: { order($0.value) < order($1.value) })
        else { return }
        map[oldest.key] = nil
    }
}
