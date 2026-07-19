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
/// than `minFrameSize`, mirroring the reference read loop (shared-FLAG framing).
public struct HDLCDeframer: Equatable {
    private var buffer: [UInt8] = []
    private let minFrameSize: Int

    public init(minFrameSize: Int = HDLC.minFrameSize) {
        self.minFrameSize = minFrameSize
    }

    public mutating func ingest(_ bytes: Data) -> [Data] {
        buffer.append(contentsOf: bytes)
        var frames: [Data] = []
        while true {
            guard let start = buffer.firstIndex(of: HDLC.flag) else { break }
            guard let end = buffer[(start + 1)...].firstIndex(of: HDLC.flag) else { break }
            let frame = HDLC.unescape(Data(buffer[(start + 1)..<end]))
            if frame.count > minFrameSize { frames.append(frame) }
            buffer = Array(buffer[end...]) // keep the closing FLAG as the next opening FLAG
        }
        return frames
    }
}
