import Foundation

/// Minimal MessagePack codec — only the float64 form (`0xCB`) used by Reticulum link RTT
/// packets. `umsgpack.packb(<python float>)` always emits this form. Other MessagePack types
/// are intentionally unimplemented (YAGNI).
public enum MsgPack {
    static let float64Tag: UInt8 = 0xCB

    /// Encode a `Double` as MessagePack float64: `0xCB ‖ big-endian IEEE-754 bits` (9 bytes).
    public static func encode(_ value: Double) -> Data {
        var data = Data([float64Tag])
        var be = value.bitPattern.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        return data
    }

    /// Decode a MessagePack float64. Returns nil unless the input is exactly the 9-byte
    /// `0xCB`-tagged form.
    public static func decodeDouble(_ data: Data) -> Double? {
        let bytes = Data(data) // normalize to 0-based indices
        guard bytes.count == 9, bytes[bytes.startIndex] == float64Tag else { return nil }
        let bits = bytes.dropFirst().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Double(bitPattern: bits)
    }
}
