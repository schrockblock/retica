import Foundation

/// Pure support logic for the Reticulum BLE interface (ble-reticulum protocol v2.2). Ports of ble_reticulum.BLEFragmentation and the fork's ble_support.PeerGreylist — no CoreBluetooth, no TCA, testable everywhere.

/// Per-peer reconnection rate limiter with exponential backoff. Port of
/// ble_support.PeerGreylist: delay = min(base * 2^(strikes-1), max); strikes are
/// forgotten when more than strikeForget elapses since the last failure; the
/// blocking boundary is INCLUSIVE (blocked while now <= unblock time).
public struct BLEPeerGreylist<Key: Hashable & Sendable>: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        var strikes: Int
        var lastFailure: Date
        var blockedUntil: Date
    }

    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let strikeForget: TimeInterval
    private var entries: [Key: Entry] = [:]

    public init(baseDelay: TimeInterval = 5, maxDelay: TimeInterval = 300,
                strikeForget: TimeInterval = 600) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.strikeForget = strikeForget
    }

    public mutating func recordFailure(_ peer: Key, now: Date) {
        var strikes = 0
        if let entry = entries[peer], now.timeIntervalSince(entry.lastFailure) <= strikeForget {
            strikes = entry.strikes
        }
        strikes += 1
        let delay = min(baseDelay * pow(2, Double(strikes - 1)), maxDelay)
        entries[peer] = Entry(strikes: strikes, lastFailure: now,
                              blockedUntil: now.addingTimeInterval(delay))
    }

    public func isBlocked(_ peer: Key, now: Date) -> Bool {
        guard let entry = entries[peer] else { return false }
        return now <= entry.blockedUntil
    }

    public mutating func clear(_ peer: Key) {
        entries[peer] = nil
    }
}

public enum BLEChannelDirection: Equatable, Sendable {
    case outbound, inbound
}

public enum BLEDuplicateResolution: Equatable, Sendable {
    case keepExisting, keepNew
}

/// Unsigned byte-wise lexicographic comparison.
public func bleTokenIsLower(_ a: Data, _ b: Data) -> Bool {
    for (x, y) in zip(a, b) where x != y { return x < y }
    return a.count < b.count
}

/// Symmetric duplicate-channel resolution. Same direction = reconnect (new wins).
/// Opposite directions = simultaneous cross-connect: the channel initiated by the
/// owner of the LOWER token survives; both endpoints reach complementary
/// conclusions from their own (localToken, direction) view.
public func bleResolveDuplicate(
    localToken: Data, peerToken: Data,
    existingDirection: BLEChannelDirection, newDirection: BLEChannelDirection
) -> BLEDuplicateResolution {
    guard existingDirection != newDirection else { return .keepNew }
    let localInitiatorWins = bleTokenIsLower(localToken, peerToken)
    let existingInitiatedLocally = existingDirection == .outbound
    return existingInitiatedLocally == localInitiatorWins ? .keepExisting : .keepNew
}

// MARK: - ble-reticulum protocol v2.2

/// Wire constants for ble-reticulum protocol v2.2 (BLE_PROTOCOL_v2.2.md §UUID Reference).
/// Strings, not CBUUIDs, so this file stays free of CoreBluetooth.
public enum BLEProtocol {
    public static let serviceUUID      = "37145b00-442d-4a94-917f-8f42c5da28e3"
    public static let txCharUUID       = "37145b00-442d-4a94-917f-8f42c5da28e4"
    public static let rxCharUUID       = "37145b00-442d-4a94-917f-8f42c5da28e5"
    public static let identityCharUUID = "37145b00-442d-4a94-917f-8f42c5da28e6"
    public static let identityLength   = 16
}

public enum BLEFragmentType: UInt8, Sendable {
    case start = 0x01, cont = 0x02, end = 0x03
}

public enum BLEFragmentError: Error, Equatable {
    case emptyPacket
    case tooManyFragments(Int)
}

/// Port of ble_reticulum.BLEFragmentation.BLEFragmenter. Every packet — even one that fits in a
/// single fragment — is sent with the 5-byte header `!BHH` (type, sequence, total).
public struct BLEFragmenter: Equatable, Sendable {
    public static let headerLength = 5
    public static let minimumMTU = 20
    public static let maxFragments = 65_535

    public let mtu: Int
    public var payloadSize: Int { mtu - Self.headerLength }

    public init(mtu: Int) {
        self.mtu = max(mtu, Self.minimumMTU)
    }

    public func fragment(_ packet: Data) throws -> [Data] {
        guard !packet.isEmpty else { throw BLEFragmentError.emptyPacket }
        let count = (packet.count + payloadSize - 1) / payloadSize
        guard count <= Self.maxFragments else { throw BLEFragmentError.tooManyFragments(count) }
        let bytes = Data(packet)   // rebase indices to 0
        var out: [Data] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let type: BLEFragmentType = (i == 0) ? .start : (i == count - 1 ? .end : .cont)
            var frag = Data([type.rawValue,
                             UInt8(i >> 8), UInt8(i & 0xFF),
                             UInt8(count >> 8), UInt8(count & 0xFF)])
            let start = i * payloadSize
            frag.append(bytes[start ..< min(start + payloadSize, bytes.count)])
            out.append(frag)
        }
        return out
    }
}

/// ble-reticulum receivers treat ANY exactly-16-byte write/notification as an identity handshake
/// once the peer is known (BLEInterface.py `_handle_identity_handshake`), so a fragment whose
/// payload is 11 bytes would be swallowed. This post-pass re-cuts the LAST fragment so no fragment
/// on the wire is 16 bytes: the reference reassembler concatenates payloads by sequence and never
/// checks their sizes, so an uneven last pair is wire-legal.
public enum BLEFragmentSanitizer {
    public static let forbiddenLength = BLEProtocol.identityLength   // 16
    /// `fragments` must be a complete, in-order output of `BLEFragmenter.fragment` with total ≥ 1.
    public static func avoidHandshakeCollision(_ fragments: [Data]) -> [Data] {
        guard let last = fragments.last, last.count == forbiddenLength else { return fragments }
        let header = BLEFragmenter.headerLength
        let total = UInt16(fragments.count)
        func fragment(type: BLEFragmentType, sequence: Int, total: UInt16, payload: Data) -> Data {
            var d = Data([type.rawValue, UInt8(sequence >> 8), UInt8(sequence & 0xFF), UInt8(total >> 8), UInt8(total & 0xFF)])
            d.append(payload); return d
        }
        if fragments.count == 1 {
            // An 11-byte packet: split it 10 + 1 as START/END, total 2.
            let payload = Data(last.dropFirst(header))
            return [fragment(type: .start, sequence: 0, total: 2, payload: payload.prefix(10)),
                    fragment(type: .end, sequence: 1, total: 2, payload: payload.suffix(1))]
        }
        // Move one payload byte from the second-to-last fragment onto the last one (17 bytes).
        var out = fragments
        let prevIndex = fragments.count - 2
        let prevPayload = Data(fragments[prevIndex].dropFirst(header))
        let lastPayload = Data(last.dropFirst(header))
        let prevType: BLEFragmentType = prevIndex == 0 ? .start : .cont
        out[prevIndex] = fragment(type: prevType, sequence: prevIndex, total: total, payload: prevPayload.dropLast(1))
        out[fragments.count - 1] = fragment(type: .end, sequence: fragments.count - 1, total: total, payload: prevPayload.suffix(1) + lastPayload)
        return out
    }
}

public enum BLEReassemblyError: Error, Equatable {
    case tooShort(Int)
    case badType(UInt8)
    case badSequence(UInt16, total: UInt16)
    case zeroTotal
    case totalMismatch(expected: UInt16, got: UInt16)
    case conflictingDuplicate(UInt16)
}

/// Port of ble_reticulum.BLEFragmentation.BLEReassembler for ONE peer. Buffers are keyed by
/// `total` exactly as the reference does (its packet_key collapses to (sender, 0, total)):
/// sequence 0 starts or restarts the buffer for that total; other sequences join it.
/// Bounded: at most `maxInFlight` buffers (oldest evicted) and a stale purge on completion.
public struct BLEReassembler: Equatable, Sendable {
    public static let staleAge: TimeInterval = 30
    public static let maxInFlight = 8

    private struct Buffer: Equatable, Sendable {
        var fragments: [UInt16: Data] = [:]
        var total: UInt16
        var startedAt: Date
    }
    private var buffers: [UInt16: Buffer] = [:]

    public init() {}

    public var inFlightCount: Int { buffers.count }

    public mutating func receive(_ fragment: Data, now: Date) throws -> Data? {
        let f = Data(fragment)
        guard f.count >= BLEFragmenter.headerLength else { throw BLEReassemblyError.tooShort(f.count) }
        guard BLEFragmentType(rawValue: f[0]) != nil else { throw BLEReassemblyError.badType(f[0]) }
        let sequence = UInt16(f[1]) << 8 | UInt16(f[2])
        let total = UInt16(f[3]) << 8 | UInt16(f[4])
        guard total != 0 else { throw BLEReassemblyError.zeroTotal }
        guard sequence < total else { throw BLEReassemblyError.badSequence(sequence, total: total) }
        let payload = Data(f[BLEFragmenter.headerLength...])

        if sequence == 0 {
            buffers[total] = Buffer(fragments: [0: payload], total: total, startedAt: now)
        } else {
            if buffers[total] == nil {
                buffers[total] = Buffer(fragments: [:], total: total, startedAt: now)
            }
            // Unreachable under total-keyed buffers; kept for parity with the reference.
            guard buffers[total]!.total == total else {
                let expected = buffers[total]!.total
                buffers[total] = nil
                throw BLEReassemblyError.totalMismatch(expected: expected, got: total)
            }
            if let existing = buffers[total]!.fragments[sequence] {
                if existing == payload { return nil }          // benign retransmit
                buffers[total] = nil
                throw BLEReassemblyError.conflictingDuplicate(sequence)
            }
            buffers[total]!.fragments[sequence] = payload
        }

        guard let buffer = buffers[total], buffer.fragments.count == Int(total) else {
            evictIfOverCapacity()
            return nil
        }
        var packet = Data()
        for i in 0..<total {
            guard let part = buffer.fragments[i] else { evictIfOverCapacity(); return nil }
            packet.append(part)
        }
        buffers[total] = nil
        purgeStale(now: now)
        evictIfOverCapacity()
        return packet
    }

    private mutating func evictIfOverCapacity() {
        while buffers.count > Self.maxInFlight {
            guard let oldest = buffers.min(by: { $0.value.startedAt < $1.value.startedAt }) else { return }
            buffers[oldest.key] = nil
        }
    }

    private mutating func purgeStale(now: Date) {
        buffers = buffers.filter { now.timeIntervalSince($0.value.startedAt) <= Self.staleAge }
    }
}

/// Columba's 1-byte keepalive; every ble-reticulum peer filters it before reassembly.
public enum BLEKeepalive {
    public static let frame = Data([0x00])
    public static func isKeepalive(_ data: Data) -> Bool { data.count == 1 && data[data.startIndex] == 0x00 }
}
