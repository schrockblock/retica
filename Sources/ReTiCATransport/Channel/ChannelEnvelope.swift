import Foundation

/// Constants of RNS 1.6.0 `Channel` (Channel.py:178-216), names verbatim in lowerCamel.
public enum ChannelConstants {
    /// The initial window size at channel setup.
    public static let window = 2
    /// Absolute minimum window size.
    public static let windowMin = 2
    public static let windowMinLimitSlow = 2
    public static let windowMinLimitMedium = 5
    public static let windowMinLimitFast = 16
    public static let windowMaxSlow = 5
    public static let windowMaxMedium = 12
    public static let windowMaxFast = 48
    /// For calculating maps and guard segments: the global maximum window.
    public static let windowMax = windowMaxFast
    public static let fastRateThreshold = 10
    public static let rttFast = 0.18
    public static let rttMedium = 0.75
    public static let rttSlow = 1.45
    /// The difference between window max and window min is never smaller than this.
    public static let windowFlexibility = 4
    public static let seqMax = 0xFFFF
    public static let seqModulus = seqMax + 1
    public static let maxTries = 5
    /// `>HHH` header: msgtype, sequence, length.
    public static let envelopeOverhead = 6
}

/// A user-registrable Channel message type. Types `0xF000` and above are reserved for the system
/// (Channel.py: `MessageBase` registration), so the failable init refuses them.
public struct ChannelMessageType: Hashable, Sendable {
    public let rawValue: UInt16

    public init?(_ raw: UInt16) {
        guard raw < 0xF000 else { return nil }
        self.rawValue = raw
    }

    private init(system raw: UInt16) {
        self.rawValue = raw
    }

    /// `SystemMessageTypes.SMT_STREAM_DATA`, used by Buffer.
    static let streamData = ChannelMessageType(system: 0xFF00)
}

/// The Channel envelope: `>HHH` (msgtype, sequence, payload length) then the payload (Channel.py:118-135).
public struct ChannelEnvelope: Equatable, Sendable {
    public var msgType: UInt16
    public var sequence: UInt16
    public var payload: Data

    public init(msgType: UInt16, sequence: UInt16, payload: Data) {
        self.msgType = msgType
        self.sequence = sequence
        self.payload = payload
    }

    /// Header then payload. The length field is the payload's count, truncated to 16 bits (a payload
    /// that large cannot reach here: it exceeds any link MDU).
    public func packed() -> Data {
        let length = UInt16(truncatingIfNeeded: payload.count)
        var out = Data(capacity: ChannelConstants.envelopeOverhead + payload.count)
        out.append(UInt8(truncatingIfNeeded: msgType >> 8))
        out.append(UInt8(truncatingIfNeeded: msgType))
        out.append(UInt8(truncatingIfNeeded: sequence >> 8))
        out.append(UInt8(truncatingIfNeeded: sequence))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(payload)
        return out
    }

    /// Nil when shorter than the 6-byte header. The length field is NOT checked, as the reference does
    /// (Channel.py:119-120): the payload is everything after the header.
    public static func parse(_ raw: Data) -> ChannelEnvelope? {
        guard raw.count >= ChannelConstants.envelopeOverhead else { return nil }
        let base = raw.startIndex
        let msgType = UInt16(truncatingIfNeeded: raw[base]) << 8 | UInt16(truncatingIfNeeded: raw[base + 1])
        let sequence = UInt16(truncatingIfNeeded: raw[base + 2]) << 8 | UInt16(truncatingIfNeeded: raw[base + 3])
        let payload = Data(raw[(base + ChannelConstants.envelopeOverhead)...])
        return ChannelEnvelope(msgType: msgType, sequence: sequence, payload: payload)
    }
}
