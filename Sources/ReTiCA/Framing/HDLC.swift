import Foundation

/// HDLC framing used by byte-stream Reticulum interfaces (TCP, serial).
/// Matches `RNS/Interfaces/TCPInterface.py` `HDLC`.
public enum HDLC {
    public static let flag: UInt8 = 0x7E
    public static let esc: UInt8 = 0x7D
    public static let escMask: UInt8 = 0x20
    /// HEADER_MINSIZE. Deframed frames must be STRICTLY longer than this to be delivered.
    public static let minFrameSize = 19

    /// Escape a raw ESC byte to `ESC, ESC^ESC_MASK` and a raw FLAG byte to `ESC, FLAG^ESC_MASK`.
    /// Single pass over the original bytes (equivalent to the reference's ESC-then-FLAG replaces).
    public static func escape(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        for byte in data {
            switch byte {
            case esc:  out.append(esc); out.append(esc ^ escMask)
            case flag: out.append(esc); out.append(flag ^ escMask)
            default:   out.append(byte)
            }
        }
        return out
    }

    public static func unescape(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == esc, i + 1 < bytes.count {
                let next = bytes[i + 1]
                if next == flag ^ escMask { out.append(flag); i += 2; continue }
                if next == esc ^ escMask  { out.append(esc);  i += 2; continue }
            }
            out.append(bytes[i]); i += 1
        }
        return Data(out)
    }

    public static func frame(_ data: Data) -> Data {
        var out = Data([flag])
        out.append(escape(data))
        out.append(flag)
        return out
    }
}

/// Streaming HDLC deframer. Accumulates bytes and yields complete, unescaped frames longer
/// than `minFrameSize` and no larger than `maxFrameSize`, mirroring the reference read loop
/// (shared-FLAG framing).
///
/// The three buffer-management guards mirror `TCPInterface.py:337, 408, 411`:
/// - No FLAG present → clear the buffer entirely (`:411`).
/// - Opening FLAG but no closing FLAG and buffer exceeds `maxFrameSize * 2` → clear (`:408`).
/// - Assembled frame longer than `maxFrameSize` → drop without delivering (`:337`).
///
/// `maxFrameSize` defaults to 262 144, matching `InterfaceProfile.tcp.hwMTU`. This is a runaway
/// guard, not a policy: a caller on a smaller medium (e.g. BLE at 1 196 B) should pass its own.
public struct HDLCDeframer: Equatable {
    private var buffer: [UInt8] = []
    private let minFrameSize: Int
    private let maxFrameSize: Int

    /// Exposed for bound tests only — do not use this in production code.
    public var bufferedByteCount: Int { buffer.count }

    public init(minFrameSize: Int = HDLC.minFrameSize, maxFrameSize: Int = 262_144) {
        self.minFrameSize = minFrameSize
        self.maxFrameSize = maxFrameSize
    }

    public mutating func ingest(_ bytes: Data) -> [Data] {
        buffer.append(contentsOf: bytes)
        var frames: [Data] = []
        while true {
            // No FLAG anywhere: clear the buffer entirely (TCPInterface.py:411).
            guard let start = buffer.firstIndex(of: HDLC.flag) else {
                buffer = []
                break
            }
            // Opening FLAG found but no closing FLAG yet.
            guard let end = buffer[(start + 1)...].firstIndex(of: HDLC.flag) else {
                // If the buffer has grown beyond the runaway threshold, discard it
                // (TCPInterface.py:408). The stream is unrecoverable at this point.
                if buffer.count > maxFrameSize * 2 { buffer = [] }
                break
            }
            let frame = HDLC.unescape(Data(buffer[(start + 1)..<end]))
            // Reject frames outside [minFrameSize+1 … maxFrameSize] (TCPInterface.py:337).
            if frame.count > minFrameSize && frame.count <= maxFrameSize {
                frames.append(frame)
            }
            buffer = Array(buffer[end...]) // keep the closing FLAG as the next opening FLAG
        }
        return frames
    }
}
