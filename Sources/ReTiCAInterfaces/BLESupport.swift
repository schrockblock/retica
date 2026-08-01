import Foundation

/// Pure support logic for the Reticulum BLE transport (RBTP v2, Apple profile).
/// Port of the fork's ble_support.py — no CoreBluetooth, no TCA, testable everywhere.

public enum BLEFramingError: Error, Equatable {
    case invalidLength(Int)
}

/// Wire framing: [len: 2 bytes big-endian][packet], 1 <= len <= 1196.
public enum BLEFraming {
    public static let maxFrameLength = 1196
    public static let headerLength = 2

    public static func frame(_ packet: Data) throws -> Data {
        guard packet.count >= 1, packet.count <= maxFrameLength else {
            throw BLEFramingError.invalidLength(packet.count)
        }
        var out = Data([UInt8(packet.count >> 8), UInt8(packet.count & 0xFF)])
        out.append(packet)
        return out
    }
}

/// Streaming deframer. Accumulates bytes and yields complete packets; throws on a
/// malformed length prefix (no recovery — the caller must drop the connection).
public struct BLEFrameBuffer: Equatable, Sendable {
    public let maxFrameLength: Int
    var buffer: Data

    public init(maxFrameLength: Int = BLEFraming.maxFrameLength) {
        self.maxFrameLength = maxFrameLength
        self.buffer = Data()
    }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var packets: [Data] = []
        while buffer.count >= BLEFraming.headerLength {
            let b0 = Int(buffer[buffer.startIndex])
            let b1 = Int(buffer[buffer.startIndex + 1])
            let length = (b0 << 8) | b1
            guard length >= 1, length <= maxFrameLength else {
                throw BLEFramingError.invalidLength(length)
            }
            guard buffer.count >= BLEFraming.headerLength + length else { break }
            let start = buffer.startIndex + BLEFraming.headerLength
            packets.append(Data(buffer[start ..< start + length]))
            buffer = Data(buffer[(start + length)...])
        }
        return packets
    }
}

/// The mandatory first frame on every channel: "RBT" + version + 16-byte session token.
public enum BLEHello {
    public static let magic = Data("RBT".utf8)
    public static let tokenLength = 16
    public static let length = 20

    public static func pack(version: UInt8, token: Data) -> Data {
        precondition(token.count == tokenLength, "HELLO token must be \(tokenLength) bytes")
        var out = magic
        out.append(version)
        out.append(token)
        return out
    }

    public static func parse(_ frame: Data) -> (version: UInt8, token: Data)? {
        guard frame.count == length else { return nil }
        let rebased = Data(frame)
        guard rebased.prefix(magic.count) == magic else { return nil }
        return (version: rebased[magic.count], token: Data(rebased.suffix(tokenLength)))
    }
}

/// Per-peer reconnection rate limiter with exponential backoff. Port of
/// ble_support.PeerGreylist: delay = min(base * 2^(strikes-1), max); strikes are
/// forgotten when more than strikeForget elapses since the last failure; the
/// blocking boundary is INCLUSIVE (blocked while now <= unblock time).
public struct BLEPeerGreylist<Key: Hashable & Sendable>: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var strikes: Int
        var lastFailure: Date
        var blockedUntil: Date
    }

    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let strikeForget: TimeInterval
    var entries: [Key: Entry] = [:]

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
