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
