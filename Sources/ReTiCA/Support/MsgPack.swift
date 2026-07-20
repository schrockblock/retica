import Foundation

/// Minimal MessagePack codec — supports float64 and value types (uint/bin/string/nil/map).
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

    public static func encode(_ value: MsgPackValue) -> Data {
        switch value {
        case let .uint(u):    return encodeUInt(u)
        case let .bin(d):     return encodeBin(d)
        case let .string(s):  return encodeStr(s)
        case let .double(x):  return encode(x)          // existing float64 encoder
        case .null:           return Data([0xC0])
        case let .map(pairs): return encodeMap(pairs)
        }
    }

    static func encodeUInt(_ u: UInt64) -> Data {
        if u <= 0x7F { return Data([UInt8(u)]) }
        if u <= 0xFF { return Data([0xCC, UInt8(u)]) }
        if u <= 0xFFFF { return Data([0xCD]) + beBytes(UInt16(u)) }
        if u <= 0xFFFF_FFFF { return Data([0xCE]) + beBytes(UInt32(u)) }
        return Data([0xCF]) + beBytes(u)
    }
    static func encodeBin(_ b: Data) -> Data {
        let n = b.count
        var d: Data
        if n <= 0xFF { d = Data([0xC4, UInt8(n)]) }
        else if n <= 0xFFFF { d = Data([0xC5]) + beBytes(UInt16(n)) }
        else { d = Data([0xC6]) + beBytes(UInt32(n)) }
        d.append(b); return d
    }
    static func encodeStr(_ s: String) -> Data {
        let u = Data(s.utf8); let n = u.count
        var d = n <= 31 ? Data([0xA0 | UInt8(n)]) : Data([0xD9, UInt8(n)])
        d.append(u); return d
    }
    static func encodeMap(_ pairs: [MsgPackValue.Pair]) -> Data {
        let n = pairs.count
        var d = n <= 15 ? Data([0x80 | UInt8(n)]) : Data([0xDE]) + beBytes(UInt16(n))
        for p in pairs { d.append(encodeStr(p.key)); d.append(encode(p.value)) }
        return d
    }
    static func beBytes<T: FixedWidthInteger>(_ v: T) -> Data {
        var be = v.bigEndian; return withUnsafeBytes(of: &be) { Data($0) }
    }

    public static func decodeValue(_ data: Data) -> MsgPackValue? {
        let b = [UInt8](data)
        guard let (v, next) = parse(b, 0), next == b.count else { return nil }
        return v
    }
    private static func parse(_ b: [UInt8], _ i: Int) -> (MsgPackValue, Int)? {
        guard i < b.count else { return nil }
        let tag = b[i]
        switch tag {
        case 0x00...0x7F: return (.uint(UInt64(tag)), i + 1)
        case 0xC0: return (.null, i + 1)
        case 0xCC: guard i + 1 < b.count else { return nil }; return (.uint(UInt64(b[i + 1])), i + 2)
        case 0xCD: guard i + 2 < b.count else { return nil }; return (.uint(UInt64(be(b, i + 1, 2))), i + 3)
        case 0xCE: guard i + 4 < b.count else { return nil }; return (.uint(be(b, i + 1, 4)), i + 5)
        case 0xCF: guard i + 8 < b.count else { return nil }; return (.uint(be(b, i + 1, 8)), i + 9)
        case 0xCB: guard i + 8 < b.count else { return nil }; return (.double(Double(bitPattern: be(b, i + 1, 8))), i + 9)
        case 0xC4: guard i + 1 < b.count else { return nil }; return bin(b, i + 2, Int(b[i + 1]))
        case 0xC5: guard i + 2 < b.count else { return nil }; return bin(b, i + 3, Int(be(b, i + 1, 2)))
        case 0xC6: guard i + 4 < b.count else { return nil }; return bin(b, i + 5, Int(be(b, i + 1, 4)))
        case 0xA0...0xBF: return str(b, i + 1, Int(tag & 0x1F))
        case 0xD9: guard i + 1 < b.count else { return nil }; return str(b, i + 2, Int(b[i + 1]))
        case 0x80...0x8F: return parseMap(b, i + 1, Int(tag & 0x0F))
        case 0xDE: guard i + 2 < b.count else { return nil }; return parseMap(b, i + 3, Int(be(b, i + 1, 2)))
        default: return nil
        }
    }
    private static func bin(_ b: [UInt8], _ start: Int, _ n: Int) -> (MsgPackValue, Int)? {
        guard start + n <= b.count else { return nil }
        return (.bin(Data(b[start..<start + n])), start + n)
    }
    private static func str(_ b: [UInt8], _ start: Int, _ n: Int) -> (MsgPackValue, Int)? {
        guard start + n <= b.count, let s = String(bytes: b[start..<start + n], encoding: .utf8) else { return nil }
        return (.string(s), start + n)
    }
    private static func parseMap(_ b: [UInt8], _ start: Int, _ count: Int) -> (MsgPackValue, Int)? {
        var i = start; var pairs: [MsgPackValue.Pair] = []
        for _ in 0..<count {
            guard let (kv, ni) = parse(b, i), case let .string(key) = kv,
                  let (vv, ni2) = parse(b, ni) else { return nil }
            pairs.append(.init(key, vv)); i = ni2
        }
        return (.map(pairs), i)
    }
    private static func be(_ b: [UInt8], _ i: Int, _ n: Int) -> UInt64 {
        (0..<n).reduce(UInt64(0)) { ($0 << 8) | UInt64(b[i + $1]) }
    }
}

/// A MessagePack value covering the subset Reticulum resource advertisements use:
/// unsigned ints, byte strings, UTF-8 strings, nil, float64, and ordered string-keyed maps.
public indirect enum MsgPackValue: Equatable {
    case uint(UInt64)
    case bin(Data)
    case string(String)
    case double(Double)
    case null
    case map([Pair])

    public struct Pair: Equatable {
        public let key: String
        public let value: MsgPackValue
        public init(_ key: String, _ value: MsgPackValue) { self.key = key; self.value = value }
    }
}
