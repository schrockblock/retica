import Foundation

/// Minimal MessagePack codec covering every type reference `RNS/vendor/umsgpack.py` can emit
/// except `ext`/`fixext`, which no RNS or LXMF code path packs (see the `parse` switch).
///
/// Decode and encode are one feature, not two. `LXMessage.validateSignature` re-packs the payload
/// from the decoded fields on every inbound message, so a type this codec can read but not write
/// merely moves the failure from the parser to the signature check. Anything added to `parse` must
/// be added to `encode` in the same change, and must reproduce reference's byte choice.
public enum MsgPack {
    static let float64Tag: UInt8 = 0xCB
    static let float32Tag: UInt8 = 0xCA

    /// Maximum MessagePack container nesting depth accepted by `parse`.
    ///
    /// **Justification (protocol depth survey):**
    /// The deepest structure defined by the Reticulum / LXMF protocol stack is an LXMessage
    /// payload: `array([double, bin, bin, intMap([IntPair])])` where `intMap` values can be any
    /// MsgPackValue — depth 3 for scalar field values. No other protocol structure exceeds 2
    /// (PNAnnounce: outer array → costs array / metadata map). ResourceAdvertisement is flat
    /// (depth 1 — a map whose values are all scalars). Link request/response are depth 2 (array
    /// wrapping a data element).
    ///
    /// **Headroom:**
    /// - Above deepest known structure (3): 29 levels of headroom for application data in
    ///   `LXMessage.fields` values (telemetry, coordinates, attachments), which ReTiCA does not
    ///   define and cannot bound.
    /// - Below stack exhaustion: the bomb test crashes at ~431 depth on a 512 KiB background
    ///   thread stack in a debug build, and at ~10 000 depth in a release build. 32 is
    ///   substantially below both; a 32-deep legitimate payload is never near the stack limit.
    ///
    /// **Reference divergence:** Python's `umsgpack` (RNS/vendor/umsgpack.py) imposes NO
    /// explicit depth limit — it is equally recursive but survives via CPython's catchable
    /// `RecursionError`. A native Swift port has no such safety net; stack exhaustion is
    /// uncatchable and crashes the process (SIGBUS/SIGILL). We deliberately diverge from the
    /// reference to add this guard.
    ///
    /// **Detection gap:** `Scripts/check-wire-narrowing.swift` covers narrowing-conversion
    /// defects only; unbounded recursion is a different shape and is INVISIBLE to it.
    /// The `MsgPackDepthTests` suite is the **sole** regression guard for this defect.
    public static let maxParseDepth = 32

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
        case let .int(i):     return encodeInt(i)
        case let .bin(d):     return encodeBin(d)
        case let .string(s):  return encodeStr(s)
        case let .double(x):  return encode(x)          // existing float64 encoder
        case let .float(f):   return Data([float32Tag]) + beBytes(f.bitPattern)
        case .null:           return Data([0xC0])
        case let .map(pairs): return encodeMap(pairs)
        case let .array(items): return encodeArray(items)
        case let .intMap(pairs): return encodeIntMap(pairs)
        case let .bool(b):    return Data([b ? 0xC3 : 0xC2])
        }
    }

    private static func encodeUInt(_ u: UInt64) -> Data {
        if u <= 0x7F { return Data([UInt8(u)]) }
        if u <= 0xFF { return Data([0xCC, UInt8(u)]) }
        if u <= 0xFFFF { return Data([0xCD]) + beBytes(UInt16(u)) }
        if u <= 0xFFFF_FFFF { return Data([0xCE]) + beBytes(UInt32(u)) }
        return Data([0xCF]) + beBytes(u)
    }

    /// Signed integers, mirroring reference `_pack_integer` (`umsgpack.py:288-314`) branch for
    /// branch: dispatch on the sign first, then take the NARROWEST form that holds the value.
    ///
    /// **Why the branch structure has to match.** `LXMessage.validateSignature` rebuilds the packed
    /// payload from the decoded fields and checks it against a signature the sender computed over
    /// *its* packing, so a decoded value must re-encode to the byte it arrived as. Reference picks
    /// that byte purely from the value — nothing about the arriving width is remembered — so
    /// reproducing the same value → width function is sufficient, and no wire-width memory is
    /// needed on the integer side. (`.float` is the exception; see `MsgPackValue.float`.)
    ///
    /// A non-negative value packs unsigned, exactly as `_pack_integer`'s `else` branch does: in
    /// Python there is one `int` type and the sign alone selects the branch.
    private static func encodeInt(_ v: Int64) -> Data {
        guard v < 0 else { return encodeUInt(UInt64(bitPattern: v)) }
        if v >= -32 { return Data([UInt8(bitPattern: Int8(truncatingIfNeeded: v))]) }         // negative fixint
        if v >= -128 { return Data([0xD0, UInt8(bitPattern: Int8(truncatingIfNeeded: v))]) }  // int8
        if v >= -32768 { return Data([0xD1]) + beBytes(UInt16(bitPattern: Int16(truncatingIfNeeded: v))) }
        if v >= -2147483648 { return Data([0xD2]) + beBytes(UInt32(bitPattern: Int32(truncatingIfNeeded: v))) }
        return Data([0xD3]) + beBytes(UInt64(bitPattern: v))
    }
    private static func encodeBin(_ b: Data) -> Data {
        let n = b.count
        var d: Data
        if n <= 0xFF { d = Data([0xC4, UInt8(n)]) }
        else if n <= 0xFFFF { d = Data([0xC5]) + beBytes(UInt16(n)) }
        else { d = Data([0xC6]) + beBytes(UInt32(n)) }
        d.append(b); return d
    }
    private static func encodeStr(_ s: String) -> Data {
        let u = Data(s.utf8); let n = u.count
        var d: Data
        if n <= 31 { d = Data([0xA0 | UInt8(n)]) }
        else if n <= 0xFF { d = Data([0xD9, UInt8(n)]) }              // str8
        else if n <= 0xFFFF { d = Data([0xDA]) + beBytes(UInt16(n)) } // str16
        else { d = Data([0xDB]) + beBytes(UInt32(n)) }                // str32
        d.append(u); return d
    }
    /// fixmap / map16 / map32 header, mirroring reference `_pack_map` (`umsgpack.py:438-447`).
    ///
    /// Shared by both map encoders on purpose. When these were two separate ternaries neither had a
    /// map32 branch, so `UInt16(n)` trapped above 65535 pairs — recorded in the wire-narrowing
    /// allowlist as host-only *because the decoder had no `0xDF` branch either*. Adding map32
    /// decode without this would have turned that into a remotely reachable abort, reached through
    /// `LXMessage.validateSignature`'s re-encode. One header path means the two cannot diverge again.
    private static func mapHeader(_ n: Int) -> Data {
        if n <= 15 { return Data([0x80 | UInt8(n)]) }
        if n <= 0xFFFF { return Data([0xDE]) + beBytes(UInt16(n)) }
        return Data([0xDF]) + beBytes(UInt32(n))
    }
    private static func encodeMap(_ pairs: [MsgPackValue.Pair]) -> Data {
        var d = mapHeader(pairs.count)
        for p in pairs { d.append(encodeStr(p.key)); d.append(encode(p.value)) }
        return d
    }
    private static func encodeIntMap(_ pairs: [MsgPackValue.IntPair]) -> Data {
        var d = mapHeader(pairs.count)
        for p in pairs { d.append(encodeUInt(UInt64(p.key))); d.append(encode(p.value)) }
        return d
    }
    private static func encodeArray(_ items: [MsgPackValue]) -> Data {
        let n = items.count
        var d: Data
        if n <= 15 { d = Data([0x90 | UInt8(n)]) }
        else if n <= 0xFFFF { d = Data([0xDC]) + beBytes(UInt16(n)) }
        else { d = Data([0xDD]) + beBytes(UInt32(n)) }
        for it in items { d.append(encode(it)) }
        return d
    }
    private static func beBytes<T: FixedWidthInteger>(_ v: T) -> Data {
        var be = v.bigEndian; return withUnsafeBytes(of: &be) { Data($0) }
    }

    public static func decodeValue(_ data: Data) -> MsgPackValue? {
        let b = [UInt8](data)
        guard let (v, next) = parse(b, 0), next == b.count else { return nil }
        return v
    }
    private static func parse(_ b: [UInt8], _ i: Int, _ depth: Int = 0) -> (MsgPackValue, Int)? {
        guard depth <= maxParseDepth, i < b.count else { return nil }
        let tag = b[i]
        switch tag {
        case 0x00...0x7F: return (.uint(UInt64(tag)), i + 1)
        case 0xC0: return (.null, i + 1)
        case 0xC2: return (.bool(false), i + 1)
        case 0xC3: return (.bool(true), i + 1)
        case 0xCC: guard i + 1 < b.count else { return nil }; return (.uint(UInt64(b[i + 1])), i + 2)
        case 0xCD: guard i + 2 < b.count else { return nil }; return (.uint(UInt64(be(b, i + 1, 2))), i + 3)
        case 0xCE: guard i + 4 < b.count else { return nil }; return (.uint(be(b, i + 1, 4)), i + 5)
        case 0xCF: guard i + 8 < b.count else { return nil }; return (.uint(be(b, i + 1, 8)), i + 9)
        case 0xE0...0xFF: return (.int(signExtend(UInt64(tag), bytes: 1)), i + 1)                     // negative fixint
        case 0xD0: guard i + 1 < b.count else { return nil }; return (.int(signExtend(UInt64(b[i + 1]), bytes: 1)), i + 2)
        case 0xD1: guard i + 2 < b.count else { return nil }; return (.int(signExtend(be(b, i + 1, 2), bytes: 2)), i + 3)
        case 0xD2: guard i + 4 < b.count else { return nil }; return (.int(signExtend(be(b, i + 1, 4), bytes: 4)), i + 5)
        case 0xD3: guard i + 8 < b.count else { return nil }; return (.int(signExtend(be(b, i + 1, 8), bytes: 8)), i + 9)
        case 0xCB: guard i + 8 < b.count else { return nil }; return (.double(Double(bitPattern: be(b, i + 1, 8))), i + 9)
        case float32Tag: guard i + 4 < b.count else { return nil }
                         return (.float(Float(bitPattern: UInt32(truncatingIfNeeded: be(b, i + 1, 4)))), i + 5)
        case 0xC4: guard i + 1 < b.count else { return nil }; return bin(b, i + 2, Int(b[i + 1]))
        case 0xC5: guard i + 2 < b.count else { return nil }; return bin(b, i + 3, Int(be(b, i + 1, 2)))
        case 0xC6: guard i + 4 < b.count else { return nil }; return bin(b, i + 5, Int(be(b, i + 1, 4)))
        case 0xA0...0xBF: return str(b, i + 1, Int(tag & 0x1F))
        case 0xD9: guard i + 1 < b.count else { return nil }; return str(b, i + 2, Int(b[i + 1]))
        case 0xDA: guard i + 2 < b.count else { return nil }; return str(b, i + 3, Int(be(b, i + 1, 2)))
        case 0xDB: guard i + 4 < b.count else { return nil }; return str(b, i + 5, Int(be(b, i + 1, 4)))
        case 0x80...0x8F: return parseMap(b, i + 1, Int(tag & 0x0F), depth)
        case 0xDE: guard i + 2 < b.count else { return nil }; return parseMap(b, i + 3, Int(be(b, i + 1, 2)), depth)
        case 0xDF: guard i + 4 < b.count else { return nil }; return parseMap(b, i + 5, Int(be(b, i + 1, 4)), depth)
        case 0x90...0x9F: return parseArray(b, i + 1, Int(tag & 0x0F), depth)
        case 0xDC: guard i + 2 < b.count else { return nil }; return parseArray(b, i + 3, Int(be(b, i + 1, 2)), depth)
        case 0xDD: guard i + 4 < b.count else { return nil }; return parseArray(b, i + 5, Int(be(b, i + 1, 4)), depth)

        // ext8/16/32 and fixext1/2/4/8/16 — REJECTED on purpose, not an unremarked gap.
        //
        // umsgpack only ever writes these for a `datetime.datetime` or an explicit `umsgpack.Ext`
        // (`umsgpack.py:517-520`), and neither RNS nor LXMF constructs either: a package-wide grep
        // of both finds `datetime.datetime` only in log formatting (`RNS/__init__.py:123`) and in
        // the `rnodeconf` CLI, never inside a msgpack payload, and no use of `umsgpack.Ext` at all.
        // So no reference peer can emit an ext, and speculative support would be an untested
        // decode path reachable from unauthenticated input. Listed explicitly so that a future
        // reader sees a decision rather than an oversight — revisit if a reference release starts
        // packing timestamps as ext.
        case 0xC7, 0xC8, 0xC9, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8: return nil

        default: return nil   // 0xC1 (reserved) and any tag msgpack does not define
        }
    }

    /// Sign-extend the low `bytes * 8` bits of a big-endian accumulation into `Int64`.
    /// Total for `bytes` in 1...8; `Int64.min` needs no special case because nothing negates.
    private static func signExtend(_ raw: UInt64, bytes: Int) -> Int64 {
        let bits = bytes * 8
        guard bits < 64 else { return Int64(bitPattern: raw) }
        let signMask = UInt64(1) << (bits - 1)
        let extended = (raw & signMask) != 0 ? raw | ~((UInt64(1) << bits) - 1) : raw
        return Int64(bitPattern: extended)
    }
    private static func bin(_ b: [UInt8], _ start: Int, _ n: Int) -> (MsgPackValue, Int)? {
        guard start + n <= b.count else { return nil }
        return (.bin(Data(b[start..<start + n])), start + n)
    }
    private static func str(_ b: [UInt8], _ start: Int, _ n: Int) -> (MsgPackValue, Int)? {
        guard start + n <= b.count, let s = String(bytes: b[start..<start + n], encoding: .utf8) else { return nil }
        return (.string(s), start + n)
    }
    private static func parseMap(_ b: [UInt8], _ start: Int, _ count: Int, _ depth: Int) -> (MsgPackValue, Int)? {
        if count == 0 { return (.map([]), start) }
        guard let (firstKey, _) = parse(b, start, depth + 1) else { return nil }   // peek to pick key type
        var i = start
        switch firstKey {
        case .string:
            var pairs: [MsgPackValue.Pair] = []
            for _ in 0..<count {
                guard let (kv, ni) = parse(b, i, depth + 1), case let .string(key) = kv,
                      let (vv, ni2) = parse(b, ni, depth + 1) else { return nil }
                pairs.append(.init(key, vv)); i = ni2
            }
            return (.map(pairs), i)
        case .uint:
            var pairs: [MsgPackValue.IntPair] = []
            for _ in 0..<count {
                // Reject any map key that exceeds Int.max. A bare Int(key) traps on
                // such values (UInt64 > Int.max), and truncating to a negative Int
                // would relocate the trap to encodeIntMap's UInt64(p.key) at :140,
                // reached via LXMessage.unpack's re-encode path (LXMessage.swift:108).
                // Rejection is the correct semantic: a key outside the representable
                // range is malformed input. This sets the precedent for Task 7
                // (PNAnnounce.swift), which has the same shape.
                guard let (kv, ni) = parse(b, i, depth + 1), case let .uint(key) = kv,
                      let intKey = Int(exactly: key),
                      let (vv, ni2) = parse(b, ni, depth + 1) else { return nil }
                pairs.append(.init(intKey, vv)); i = ni2
            }
            return (.intMap(pairs), i)
        default:
            // Includes a `.int` first key. Rejected deliberately: LXMF's field keys are the
            // non-negative `FIELD_*` constants (`LXMF/LXMF.py:8-51`), so a negative map key is not a
            // shape any reference peer emits. Accepting one would put a negative `IntPair.key` into
            // `encodeIntMap`'s `UInt64(p.key)` — the trap `eb244c3` closed by rejecting at the
            // decoder. Reject-not-truncate, same ruling, one level up.
            return nil
        }
    }
    private static func parseArray(_ b: [UInt8], _ start: Int, _ count: Int, _ depth: Int) -> (MsgPackValue, Int)? {
        var i = start; var items: [MsgPackValue] = []
        for _ in 0..<count {
            guard let (v, ni) = parse(b, i, depth + 1) else { return nil }
            items.append(v); i = ni
        }
        return (.array(items), i)
    }
    private static func be(_ b: [UInt8], _ i: Int, _ n: Int) -> UInt64 {
        (0..<n).reduce(UInt64(0)) { ($0 << 8) | UInt64(b[i + $1]) }
    }
}

/// A MessagePack value covering the subset Reticulum uses: unsigned and signed ints, byte strings,
/// UTF-8 strings, booleans, nil, float32/float64, arrays, ordered string-keyed maps, and ordered
/// integer-keyed maps (`intMap`).
///
/// `uint` and `int` together span exactly `-2^63 ... 2^64-1`, which is precisely the domain reference
/// `_pack_integer` accepts — outside it, umsgpack raises `"huge signed int"` / `"huge unsigned int"`
/// (`umsgpack.py:300-314`). Neither case alone covers it, which is why `int` is a case rather than a
/// widening of `uint`.
public indirect enum MsgPackValue: Equatable, Sendable {
    case uint(UInt64)
    /// A negative integer, or one that arrived under an `int8`/`int16`/`int32`/`int64` tag. Reference
    /// only ever writes a signed tag for a negative value, so in practice this case is the negatives;
    /// `encode` handles a non-negative `.int` the way Python does, by packing it unsigned.
    case int(Int64)
    case bin(Data)
    case string(String)
    case double(Double)
    /// A float that arrived as float32 (`0xCA`), kept distinct from `double` so it re-encodes to the
    /// same five bytes.
    ///
    /// This is the one type whose wire width is NOT recoverable from the value. `_pack_float`
    /// (`umsgpack.py:325-333`) reads the module global `_float_precision` rather than inspecting the
    /// number, and `umsgpack.py:1177-1181` sets that to `"double"` whenever
    /// `sys.float_info.mant_dig == 53` — every mainstream CPython — so reference never emits float32
    /// on its own. Folding float32 into `double` would still be wrong for anything that does: the
    /// re-encode in `LXMessage.validateSignature` would widen 5 bytes to 9 and invalidate the
    /// signature. Note reference has that defect; decoding `0xCA` gives a plain Python float, which
    /// re-packs as `0xCB`. We are deliberately stricter.
    case float(Float)
    case null
    case map([Pair])
    case array([MsgPackValue])
    case intMap([IntPair])
    case bool(Bool)

    public struct Pair: Equatable, Sendable {
        public let key: String
        public let value: MsgPackValue
        public init(_ key: String, _ value: MsgPackValue) { self.key = key; self.value = value }
    }
    public struct IntPair: Equatable, Sendable {
        public let key: Int
        public let value: MsgPackValue
        public init(_ key: Int, _ value: MsgPackValue) { self.key = key; self.value = value }
    }
}
