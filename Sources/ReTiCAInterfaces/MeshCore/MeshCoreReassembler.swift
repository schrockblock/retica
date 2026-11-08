import Foundation

/// Bounded reassembly of ScotMesh Raw fragments keyed `(src, packetID)`, with a
/// short memory of completed keys so a retransmit isn't delivered twice.
public struct MeshCoreReassembler: Equatable, Sendable {
    public static let inactivityTimeout: TimeInterval = 60
    public static let dedupeWindow: TimeInterval = 30
    public static let maxDedupeKeys = 256
    public static let maxBuffersPerSender = 8
    public static let maxBuffersTotal = 64
    public static let maxPacketLength = 508

    public struct Counters: Equatable, Sendable {
        public var malformed = 0
        public var evicted = 0
        public var timedOut = 0
        public var oversize = 0
        public var completed = 0

        public init() {}
    }

    private struct Key: Hashable, Sendable {
        var src: Data
        var packetID: UInt16
    }

    private struct Buffer: Equatable, Sendable {
        var total: UInt8
        var bodies: [UInt8: Data]
        var byteCount: Int
        var lastActivity: Date
        var touch: Int
    }

    private struct Completed: Equatable, Sendable {
        var at: Date
        var touch: Int
    }

    public private(set) var counters = Counters()

    private var buffers: [Key: Buffer] = [:]
    private var completedKeys: [Key: Completed] = [:]
    private var touchCounter = 0

    public var bufferCount: Int { buffers.count }
    public var dedupeKeyCount: Int { completedKeys.count }

    public init() {}

    /// Feeds one fragment. Returns the whole packet when this fragment completes it.
    @discardableResult
    public mutating func receive(
        src: Data, packetID: UInt16, index: UInt8, total: UInt8, body: Data, now: Date
    ) -> Data? {
        guard total > 0, index < total else {
            counters.malformed += 1
            return nil
        }
        purge(now: now)

        let key = Key(src: Data(src), packetID: packetID)
        if completedKeys[key] != nil { return nil }

        let body = Data(body)
        touchCounter += 1
        let touch = touchCounter

        if var buffer = buffers[key], buffer.total == total {
            if let existing = buffer.bodies[index], existing != body {
                // Conflicting content: the earlier fragments belong to another packet.
                buffers[key] = nil
            } else {
                if buffer.bodies[index] == nil {
                    buffer.bodies[index] = body
                    buffer.byteCount += body.count
                }
                buffer.lastActivity = now
                buffer.touch = touch
                buffers[key] = buffer
                return finish(key: key, now: now)
            }
        } else if buffers[key] != nil {
            buffers[key] = nil
        }

        makeRoom(forSender: key.src)
        buffers[key] = Buffer(
            total: total, bodies: [index: body], byteCount: body.count,
            lastActivity: now, touch: touch)
        return finish(key: key, now: now)
    }

    public mutating func recordMalformed() {
        counters.malformed += 1
    }

    /// Drops every buffer. Counters and dedupe keys stay.
    public mutating func reset() {
        buffers.removeAll()
    }

    // MARK: - Private

    private static func isExpired(since start: Date, now: Date, limit: TimeInterval) -> Bool {
        let elapsed = now.timeIntervalSince(start)
        return elapsed < 0 || elapsed >= limit
    }

    private mutating func purge(now: Date) {
        for (key, buffer) in buffers
        where Self.isExpired(since: buffer.lastActivity, now: now, limit: Self.inactivityTimeout) {
            buffers[key] = nil
            counters.timedOut += 1
        }
        for (key, entry) in completedKeys
        where Self.isExpired(since: entry.at, now: now, limit: Self.dedupeWindow) {
            completedKeys[key] = nil
        }
    }

    private mutating func makeRoom(forSender src: Data) {
        let sameSender = buffers.filter { $0.key.src == src }
        if sameSender.count >= Self.maxBuffersPerSender,
            let oldest = sameSender.min(by: { $0.value.touch < $1.value.touch })
        {
            buffers[oldest.key] = nil
            counters.evicted += 1
        }
        if buffers.count >= Self.maxBuffersTotal,
            let oldest = buffers.min(by: { $0.value.touch < $1.value.touch })
        {
            buffers[oldest.key] = nil
            counters.evicted += 1
        }
    }

    private mutating func finish(key: Key, now: Date) -> Data? {
        guard let buffer = buffers[key] else { return nil }
        if buffer.byteCount > Self.maxPacketLength {
            buffers[key] = nil
            counters.oversize += 1
            return nil
        }
        guard buffer.bodies.count == Int(buffer.total) else { return nil }

        buffers[key] = nil
        var packet = Data()
        packet.reserveCapacity(buffer.byteCount)
        for index in 0..<buffer.total {
            if let body = buffer.bodies[index] { packet.append(body) }
        }
        guard !packet.isEmpty else {
            counters.malformed += 1
            return nil
        }
        counters.completed += 1
        remember(key, at: now)
        return packet
    }

    private mutating func remember(_ key: Key, at now: Date) {
        touchCounter += 1
        completedKeys[key] = Completed(at: now, touch: touchCounter)
        if completedKeys.count > Self.maxDedupeKeys,
            let oldest = completedKeys.min(by: { $0.value.touch < $1.value.touch })
        {
            completedKeys[oldest.key] = nil
        }
    }
}
