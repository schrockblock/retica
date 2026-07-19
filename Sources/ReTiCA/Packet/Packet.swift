import Foundation

public enum PacketError: Error, Equatable {
    case exceedsMTU
    case missingTransportId
    case malformed
}

/// A Reticulum packet. Pure framing over an opaque `payload` (plaintext or ciphertext);
/// encryption is a separate concern handled by `Destination`.
public struct Packet: Equatable {
    public static let mtu = 500
    public static let addressLength = 16   // TRUNCATED_HASHLENGTH / 8
    public static let maxHops: UInt8 = 128 // PATHFINDER_M

    public var headerType: HeaderType
    public var packetType: PacketType
    public var transportType: TransportType
    public var destinationType: DestinationType
    public var context: PacketContext
    public var contextFlag: Bool
    public var hops: UInt8
    public var destinationHash: Data       // 16 bytes (or link_id for LRPROOF)
    public var transportId: Data?          // 16 bytes, present iff headerType == .header2
    public var payload: Data               // opaque

    public init(headerType: HeaderType = .header1, packetType: PacketType,
                transportType: TransportType = .broadcast, destinationType: DestinationType,
                context: PacketContext = .none, contextFlag: Bool = false, hops: UInt8 = 0,
                destinationHash: Data, transportId: Data? = nil, payload: Data) {
        self.headerType = headerType
        self.packetType = packetType
        self.transportType = transportType
        self.destinationType = destinationType
        self.context = context
        self.contextFlag = contextFlag
        self.hops = hops
        self.destinationHash = destinationHash
        self.transportId = transportId
        self.payload = payload
    }

    public var flags: UInt8 {
        let h = headerType.rawValue << 6
        let cf = (contextFlag ? UInt8(1) : UInt8(0)) << 5
        let tt = transportType.rawValue << 4
        let dt = destinationType.rawValue << 2
        return h | cf | tt | dt | packetType.rawValue
    }

    public func packed() throws -> Data {
        guard destinationHash.count == Packet.addressLength else { throw PacketError.malformed }
        var raw = Data()
        raw.append(flags)
        raw.append(hops)
        if headerType == .header2 {
            guard let tid = transportId, tid.count == Packet.addressLength else {
                throw PacketError.missingTransportId
            }
            raw.append(tid)
        }
        raw.append(destinationHash)
        raw.append(context.rawValue)
        raw.append(payload)
        guard raw.count <= Packet.mtu else { throw PacketError.exceedsMTU }
        return raw
    }

    public init?(raw rawInput: Data) {
        let raw = Data(rawInput) // normalize to 0-based indices
        guard raw.count >= 2 else { return nil }
        let flags = raw[0]
        let hops = raw[1]
        guard hops < Packet.maxHops else { return nil }
        guard let headerType = HeaderType(rawValue: (flags & 0b0100_0000) >> 6),
              let transportType = TransportType(rawValue: (flags & 0b0001_0000) >> 4),
              let destinationType = DestinationType(rawValue: (flags & 0b0000_1100) >> 2),
              let packetType = PacketType(rawValue: flags & 0b0000_0011)
        else { return nil }
        let contextFlag = ((flags & 0b0010_0000) >> 5) == 1
        let dstLen = Packet.addressLength

        var idx = 2
        var transportId: Data? = nil
        if headerType == .header2 {
            guard raw.count >= idx + dstLen else { return nil }
            transportId = raw.subdata(in: idx..<(idx + dstLen))
            idx += dstLen
        }
        guard raw.count >= idx + dstLen + 1 else { return nil }
        let destinationHash = raw.subdata(in: idx..<(idx + dstLen)); idx += dstLen
        guard let context = PacketContext(rawValue: raw[idx]) else { return nil }
        idx += 1
        let payload = raw.subdata(in: idx..<raw.count)

        self.init(headerType: headerType, packetType: packetType, transportType: transportType,
                  destinationType: destinationType, context: context, contextFlag: contextFlag,
                  hops: hops, destinationHash: destinationHash, transportId: transportId,
                  payload: payload)
    }
}

extension Packet {
    /// Compose an encrypted DATA packet to a destination (HEADER_1, BROADCAST).
    public static func data(to destination: Destination, plaintext: Data,
                            ratchet: Data? = nil, context: PacketContext = .none) -> Packet {
        Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
               destinationType: destination.kind, context: context, contextFlag: false, hops: 0,
               destinationHash: destination.hash, transportId: nil,
               payload: destination.encrypt(plaintext, ratchet: ratchet))
    }

    /// Compose an ANNOUNCE packet from a destination (HEADER_1, BROADCAST). The announce
    /// payload is built separately via `Announce.buildPayload`.
    public static func announce(from destination: Destination, payload: Data,
                                pathResponse: Bool = false, ratchetPresent: Bool = false) -> Packet {
        Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
               destinationType: destination.kind,
               context: pathResponse ? .pathResponse : .none, contextFlag: ratchetPresent, hops: 0,
               destinationHash: destination.hash, transportId: nil, payload: payload)
    }
}

extension Packet {
    /// The bytes hashed to produce the packet hash. Excludes hops, transport id,
    /// header type, context flag, and transport type — matching RNS `get_hashable_part`.
    public var hashablePart: Data {
        var part = Data([(destinationType.rawValue << 2) | packetType.rawValue])
        part.append(destinationHash)
        part.append(context.rawValue)
        part.append(payload)
        return part
    }

    /// SHA-256 packet hash (32 bytes), stable across transport-mutated fields.
    public var packetHash: Data { Crypto.fullHash(hashablePart) }

    /// First 16 bytes of the packet hash.
    public var truncatedHash: Data { Crypto.truncatedHash(hashablePart) }
}
