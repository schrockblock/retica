import Foundation

/// LXMF delivery-destination announce app-data codec. Mirrors LXMF 1.1.0
/// `LXMRouter.get_announce_app_data` (LXMRouter.py:1034-1050) for packing and the three
/// consumer helpers `display_name_from_app_data`, `stamp_cost_from_app_data`,
/// `compression_support_from_app_data` (LXMF.py:151-200) for parsing.
///
/// **Wire format (0.5.0+):** msgpack array `[display_name, stamp_cost, [SF_COMPRESSION]]`
/// where `display_name` is bin (Python `bytes`) or null, `stamp_cost` is a uint in 1...254
/// or null, and the third element is an array of supported functionality codes.
/// `SF_COMPRESSION = 0x00`.
///
/// **Legacy format (pre-0.5.0):** the entire blob is a raw UTF-8 display name. Identified
/// by the first byte being outside the msgpack array gate (0x90-0x9F fixarray or 0xDC array16).
///
/// `0xDD` (array32) is deliberately excluded from the gate: the reference consumers do not
/// accept it (see `display_name_from_app_data` gate at LXMF.py:156), so it falls through to
/// the legacy path rather than being parsed as a structured array.
public struct LXMFAnnounceData: Equatable {
    /// Display name for the delivery destination, or nil if absent.
    /// On parse: NUL bytes stripped and leading/trailing whitespace trimmed
    /// (mirrors `dn.decode("utf-8").replace("\x00", "").strip()` at LXMF.py:165).
    public var displayName: String?

    /// Stamp cost required to deliver to this destination (1...254), or nil.
    /// Reference gate at LXMRouter.py:1044: `> 0 and < 255`; values 0 and 255 advertise nil.
    public var stampCost: Int?

    /// Whether the destination supports LXMF compression (`SF_COMPRESSION = 0x00`).
    /// Defaults to true when the functionality list is absent or not an array
    /// (reference: `len < 3 → True`; `not type(peer_data[2]) == list → True`).
    public var supportsCompression: Bool

    public init(displayName: String?, stampCost: Int?, supportsCompression: Bool) {
        self.displayName = displayName
        self.stampCost = stampCost
        self.supportsCompression = supportsCompression
    }

    // MARK: - Pack

    /// Pack delivery-destination announce app-data in the 0.5.0+ msgpack format.
    ///
    /// `displayName` is encoded as msgpack bin (Python `bytes`), not str, matching the
    /// `.encode("utf-8")` call in `get_announce_app_data` (LXMRouter.py:1040).
    ///
    /// `stampCost` is silently clamped to nil if outside the strict reference gate
    /// (`> 0 and < 255`). 0 and 255 advertise as null.
    ///
    /// The functionality array always contains `SF_COMPRESSION` (0x00),
    /// mirroring `supported_functionality = [SF_COMPRESSION]` at LXMRouter.py:1047.
    public static func pack(displayName: String?, stampCost: Int?) -> Data {
        let nameValue: MsgPackValue = displayName.map { .bin(Data($0.utf8)) } ?? .null

        let costValue: MsgPackValue
        if let cost = stampCost, cost > 0, cost < 255 {
            costValue = .uint(UInt64(cost))
        } else {
            costValue = .null
        }

        let functionalityValue: MsgPackValue = .array([.uint(UInt64(sfCompression))])

        return MsgPack.encode(.array([nameValue, costValue, functionalityValue]))
    }

    // MARK: - Parse

    /// Parse LXMF delivery-destination announce app-data. Returns nil for empty input.
    /// Never traps on hostile or malformed input.
    ///
    /// Two formats are recognised, matching the reference consumer gate at LXMF.py:156:
    ///
    /// - **0.5.0+ format**: first byte in `0x90...0x9F` (fixarray) or `== 0xDC` (array16)
    ///   → decode as msgpack, extract fields with degraded defaults for short arrays.
    ///
    /// - **Pre-0.5.0 legacy format**: any other first byte → treat the entire blob as a
    ///   raw UTF-8 display name (or nil if the bytes are not valid UTF-8).
    ///
    /// Callers may pass a `Data` slice with a non-zero `startIndex`. The implementation
    /// uses `Data(appData)` to normalise to zero-based indices before byte access.
    public static func parse(_ appData: Data) -> LXMFAnnounceData? {
        guard !appData.isEmpty else { return nil }

        let bytes = Data(appData)   // normalise — Data indices are NOT zero-based after slicing

        let firstByte = bytes[bytes.startIndex]
        let isMsgpackArray = (firstByte >= 0x90 && firstByte <= 0x9F) || firstByte == 0xDC

        if isMsgpackArray {
            return parseMsgpackFormat(bytes)
        } else {
            return parseLegacyFormat(bytes)
        }
    }

    // MARK: - Private

    /// `SF_COMPRESSION = 0x00` (LXMF.py:142).
    private static let sfCompression: UInt8 = 0x00

    /// Parse the 0.5.0+ msgpack array format. Degrades gracefully on short arrays.
    private static func parseMsgpackFormat(_ data: Data) -> LXMFAnnounceData? {
        guard case let .array(items)? = MsgPack.decodeValue(data) else { return nil }

        let displayName = parseDisplayName(from: items)
        let stampCost   = parseStampCost(from: items)
        let compression = parseCompression(from: items)

        return LXMFAnnounceData(displayName: displayName,
                                stampCost: stampCost,
                                supportsCompression: compression)
    }

    /// Parse the pre-0.5.0 legacy format: the entire blob is treated as a raw UTF-8 display name.
    /// Reference: the `else` branch at LXMF.py:172 (`return app_data.decode("utf-8")`).
    /// Returns a result with nil displayName (rather than nil for the struct) when the bytes
    /// are not valid UTF-8, matching `compression_support_from_app_data`'s legacy-path `return True`.
    private static func parseLegacyFormat(_ data: Data) -> LXMFAnnounceData? {
        let name = String(bytes: data, encoding: .utf8)
        return LXMFAnnounceData(displayName: name, stampCost: nil, supportsCompression: true)
    }

    /// Extract and decode the display name from `items[0]`.
    /// Returns nil if the array is empty, the element is null, the element is not bin,
    /// or the bytes are not valid UTF-8.
    /// The resulting string is NUL-stripped and whitespace-trimmed per LXMF.py:165.
    private static func parseDisplayName(from items: [MsgPackValue]) -> String? {
        guard items.count >= 1 else { return nil }
        guard case let .bin(nameBytes) = items[0] else { return nil }
        guard let decoded = String(bytes: nameBytes, encoding: .utf8) else { return nil }
        let stripped = decoded.replacingOccurrences(of: "\u{00}", with: "")
        let trimmed  = stripped.trimmingCharacters(in: .whitespaces)
        return trimmed
    }

    /// Extract the stamp cost from `items[1]`.
    /// Returns nil if `len < 2` or the element is not a uint in 1...254.
    /// Reference: `len < 2 → nil`; reference returns the raw value without the gate,
    /// but only values 1...254 are ever packed (gate in `get_announce_app_data`).
    /// On parse we mirror what reference would store: accept any uint, but only 1...254
    /// can survive the round-trip gate, so values outside it are returned as-is for
    /// cross-validation by Task 2; the gate itself lives in `pack`.
    ///
    /// Wire safety: stamp cost is packed as a small uint (≤ 254) in `pack`. An attacker
    /// could send an out-of-range value. `Int(exactly:)` is used to convert from UInt64
    /// so that UInt64.max (> Int.max) does not trap. Values > 254 are stored as-is; the
    /// caller can decide whether to honour them. The task-1 requirement is no trap.
    private static func parseStampCost(from items: [MsgPackValue]) -> Int? {
        guard items.count >= 2 else { return nil }
        switch items[1] {
        case let .uint(u):
            // Int(exactly:) never traps — returns nil when u > Int.max.
            // Allowlist entry: LXMFAnnounceData.parseStampCost — guarded by Int(exactly:)
            // which returns nil for values > Int.max (a 64-bit Int). UInt64 -> Int narrowing.
            return Int(exactly: u)
        case let .int(i):
            // Signed int: only meaningful if non-negative and in range.
            guard i >= 0 else { return nil }
            return Int(exactly: i)
        default:
            return nil
        }
    }

    /// Determine compression support from `items[2]`.
    /// Defaults to true when the array is short, the element is not an array, or
    /// `SF_COMPRESSION` is present in the list.
    /// Reference (LXMF.py:194-197):
    ///   `len < 3 → True`
    ///   `not type(peer_data[2]) == list → True`
    ///   `SF_COMPRESSION in peer_data[2]`
    private static func parseCompression(from items: [MsgPackValue]) -> Bool {
        guard items.count >= 3 else { return true }
        guard case let .array(codes) = items[2] else { return true }
        return codes.contains { code in
            if case let .uint(u) = code { return u == UInt64(sfCompression) }
            return false
        }
    }
}
