import Foundation

/// The seam between the interface and an on-air fragment format (spec §5.1). v1 ships one
/// implementation, `LandandairCodec`; a sturdier format can be added as another conformer without
/// touching the reassembler or the sender.
public protocol MeshtasticFragmentCodec: Sendable {
    /// Framed fragments for one packet, in send order. Empty when the packet cannot be framed.
    func split(_ packet: Data, index: UInt8) -> [Data]
    /// nil = malformed.
    func parse(_ frame: Data) -> MeshtasticFrame?
}

public enum MeshtasticFrame: Equatable, Sendable {
    case data(index: UInt8, pos: Int8, body: Data)
    case request(index: UInt8, pos: Int8)
}

/// Which codec an interface speaks. An enum (not an existential) so interface state stays Equatable.
public enum MeshtasticFraming: Equatable, Sendable {
    case landandair

    public var codec: any MeshtasticFragmentCodec {
        switch self {
        case .landandair: return LandandairCodec()
        }
    }
}

/// landandair/RNS_Over_Meshtastic's format, byte-exact (`PacketHandler`, Meshtastic_Interface.py:
/// 332-416). Data frame `[index: UInt8][pos: Int8][body]`, `pos` 1-based with the LAST negated
/// (a single fragment is −1). Request frame: ASCII "REQ" + `[index][pos]`.
public struct LandandairCodec: MeshtasticFragmentCodec, Equatable {
    /// `max_payload` (Meshtastic_Interface.py:335).
    public static let maxBody = 200
    /// Meshtastic `DATA_PAYLOAD_LEN`.
    public static let maxFrameLength = 233
    /// A signed pos byte numbers at most 1...127 plus a final −128.
    public static let maxFragments = 128
    public static let requestPrefix = Data("REQ".utf8)

    public init() {}

    public func split(_ packet: Data, index: UInt8) -> [Data] {
        let data = Data(packet)   // 0-based: a caller's slice must not shift our indices
        let length = data.count
        let count = length / Self.maxBody + 1
        let size = length / count + 1
        let starts = Array(stride(from: 0, to: length, by: size))
        guard starts.count <= Self.maxFragments else { return [] }
        return starts.enumerated().map { offset, start in
            let pos = offset + 1
            let signed = pos == starts.count ? -pos : pos
            var frame = Data([index, UInt8(bitPattern: Int8(signed))])
            frame.append(data[start ..< min(start + size, length)])
            return frame
        }
    }

    public func parse(_ frameInput: Data) -> MeshtasticFrame? {
        let frame = Data(frameInput)   // 0-based: drivers may hand over a slice
        guard frame.count >= 3, frame.count <= Self.maxFrameLength else { return nil }
        // A data frame can only start "REQ" with index 0x52 and pos 0x45 (= 69 fragments), which
        // no packet ≤ 508 B produces — so the 5-byte length check is what disambiguates.
        if frame.count == 5, frame.prefix(3) == Self.requestPrefix {
            let pos = Int8(bitPattern: frame[4])
            guard pos != 0 else { return nil }
            return .request(index: frame[3], pos: pos)
        }
        let pos = Int8(bitPattern: frame[1])
        guard pos != 0 else { return nil }
        return .data(index: frame[0], pos: pos, body: Data(frame.dropFirst(2)))
    }
}
