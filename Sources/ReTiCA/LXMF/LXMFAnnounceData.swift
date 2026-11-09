import Foundation

/// LXMF delivery-destination announce app-data codec. Mirrors LXMF 1.3.0
/// `LXMRouter.get_announce_app_data` (LXMRouter.py:1163-1182) for packing and the three
/// consumer helpers `display_name_from_app_data`, `stamp_cost_from_app_data`,
/// `compression_support_from_app_data` (LXMF.py:151-209) for parsing.
///
/// **Wire format (LXMF 1.3.0):** msgpack array
/// `[display_name, ceil(stamp_cost), [SF_COMPRESSION], stamp_cost]` where `display_name` is bin
/// (Python `bytes`) or null, element [1] is the integer ceiling of the cost or null, the third
/// element is an array of supported functionality codes (`SF_COMPRESSION = 0x00`), and element [3]
/// is the cost on the 1/256 grid as a float64, or null. Element [3] is transitional: reference says
/// the float moves into [1] after RNS 1.6.2 (LXMRouter.py:1178-1180). Older peers send only the
/// first three elements, with an integer [1]. See `stampCost` for what parsing accepts.
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

    /// Stamp cost advertised by the delivery destination, or nil. Fractional since LXMF 1.3.0.
    ///
    /// - **On pack** only a cost in reference's gate `> 0 and < STAMP_COST_CAP` (LXMF 1.3.0
    ///   LXMRouter.py:1173, cap 100) is emitted, quantized to the 1/256 grid; anything else
    ///   (nil, 0, negative, 100 or more, NaN, infinities) emits null in both [1] and [3].
    ///
    /// - **On parse** the same gate applies, and this is a DELIBERATE NARROWING of reference:
    ///   `stamp_cost_from_app_data` (LXMF.py:183-199) returns the chosen element verbatim, of any
    ///   value. We surface a cost only when it is a number with `0 < cost < 100`
    ///   (`LXStamper.costInRange`), and nil otherwise. Reference would go on to fail stamp
    ///   generation for a negative, NaN or above-100 cost (`generate_stamp` raises,
    ///   RNS/Stamps.py:255, and `cost_to_fp` raises on NaN) and send no stamp for 0; we send no
    ///   stamp for any of them. 100 itself, which reference would generate for, no conforming
    ///   emitter sends, and it is above our outbound ceiling in any case.
    ///
    /// **Still hostile input inside the gate.** Announce app-data is unauthenticated, and a cost
    /// of 99 is a proof-of-work search far beyond what we will do. `LXMFNode.deliveryStampCost`
    /// applies the outbound ceiling (`LXMFNode.maxDeliveryStampCost`); any other caller that
    /// spends this value must apply its own.
    public var stampCost: Double?

    /// Whether the destination supports LXMF compression (`SF_COMPRESSION = 0x00`).
    /// Defaults to true when the functionality list is absent or not an array
    /// (reference: `len < 3 → True`; `not type(peer_data[2]) == list → True`).
    public var supportsCompression: Bool

    public init(displayName: String?, stampCost: Double?, supportsCompression: Bool) {
        self.displayName = displayName
        self.stampCost = stampCost
        self.supportsCompression = supportsCompression
    }

    // MARK: - Pack

    /// Largest app-data blob, in bytes, that still fits inside a Reticulum announce packet.
    ///
    ///     Packet.mtu                               500
    ///   − HEADER_1 announce header                − 19   flags + hops + 16-byte destination
    ///                                                    hash + context (`Packet.packed()`)
    ///   − fixed announce payload                  − 148  64-byte public key + 10-byte name hash
    ///                                                    + 10-byte random hash + 64-byte
    ///                                                    signature (`Announce.buildPayload`)
    ///   − RNS 1.6 network-stamp extension         − 18   `NetworkStamp.extensionLength`, which
    ///                                                    `Transport` appends when the host stamps
    ///                                                    its announces (`stampDestinations`)
    ///                                             = 315
    ///
    /// **The extension is reserved whether or not stamping is on**, so a display name has the same
    /// length either way and turning stamping on never makes an announce that used to fit unsendable
    /// (nor truncates a name further). Reserving it cut the null-cost name budget from 326 to 308
    /// UTF-8 bytes; the fourth (fractional cost) element of LXMF 1.3.0 costs one more byte when null
    /// (307) and nine more with a cost (299), so the budget is now 299-307 bytes.
    ///
    /// **Without a ratchet.** A destination with its own ratchets enabled (`Transport`'s
    /// `.enableRatchets`) announces a fifth fixed payload field of `Announce.ratchetSize` (32) bytes;
    /// its budget is `maxAppDataBytesWithRatchet` (283), and `pack(displayName:stampCost:ratchet:)`
    /// takes which one applies. Unlike the stamp extension the ratchet is not reserved
    /// unconditionally: ratchets are a host opt-in, and reserving them would cut every name by 32
    /// bytes for hosts that never enable them.
    ///
    /// **Shrinking the budget is necessary but not sufficient.** A name captured in
    /// `Transport.state.localAppData` while it fit without a ratchet would be unsendable with one,
    /// and `announce(nil)` and local path responses would go silent with no self-heal (a re-review
    /// probe showed it: seeded oversize sticky entry → zero transmits). So `.enableRatchets`
    /// re-validates the capture with the ratchet's 32 bytes and forgets it when it no longer fits.
    public static let maxAppDataBytes =
        Packet.mtu
        - (Packet.addressLength + 3)
        - (Announce.keySize + Announce.nameHashLength + Announce.randomHashLength
           + Announce.signatureLength)
        - NetworkStamp.extensionLength

    /// `maxAppDataBytes` less the 32-byte ratchet, for a destination announcing its own ratchet.
    public static let maxAppDataBytesWithRatchet = maxAppDataBytes - Announce.ratchetSize

    /// Pack delivery-destination announce app-data in the LXMF 1.3.0 four-element format.
    ///
    /// `displayName` is encoded as msgpack bin (Python `bytes`), not str, matching the
    /// `.encode("utf-8")` call in `get_announce_app_data` (LXMRouter.py:1169).
    ///
    /// `stampCost` outside reference's gate (`> 0 and < STAMP_COST_CAP`, LXMRouter.py:1173, cap 100)
    /// advertises as null in [1] and [3]. Inside it, [3] is `quantize_cost(cost)` as a float64 and
    /// [1] is its integer ceiling, or null when the quantized cost is 0.0 (a cost below 1/512):
    /// reference's `ceil(stamp_cost) if stamp_cost else None` (LXMRouter.py:1179).
    ///
    /// The functionality array always contains `SF_COMPRESSION` (0x00),
    /// mirroring `supported_functionality = [SF_COMPRESSION]` at LXMRouter.py:1176.
    ///
    /// **`displayName` is truncated to fit `maxAppDataBytes`** (or `maxAppDataBytesWithRatchet`) — see `displayNameBudget`. This is
    /// a DELIBERATE DIVERGENCE: reference `get_announce_app_data` (LXMRouter.py:1034-1050) applies
    /// no length bound, and an over-long name there makes `RNS.Packet.pack` raise IOError
    /// (RNS 1.4.2 Packet.py:234-236) so the announce simply fails. ReTiCA's `Transport` `.announce`
    /// swallows that failure (`try?`), so an unbounded name here silently took the destination off
    /// the network — a shortened name is strictly better than no announce. Names that fit the budget
    /// are emitted unchanged, so the cross-validation vectors (all far shorter) are untouched.
    ///
    /// `ratchet` says whether the announce carrying this blob also carries our own ratchet: the
    /// budget is then `maxAppDataBytesWithRatchet`.
    public static func pack(displayName: String?, stampCost: Double?, ratchet: Bool = false) -> Data {
        // Reference's gate, then `quantize_cost` (LXMRouter.py:1172-1174). `quantizedCost` is at
        // most 100 inside the gate, so the ceiling fits a UInt64.
        let quantized = stampCost.flatMap { LXStamper.costInRange($0) ? LXStamper.quantizedCost($0) : nil }
        let ceilingValue: MsgPackValue
        if let quantized, quantized != 0 {
            ceilingValue = .uint(UInt64(quantized.rounded(.up)))
        } else {
            ceilingValue = .null
        }
        let exactValue: MsgPackValue = quantized.map { .double($0) } ?? .null

        let functionalityValue: MsgPackValue = .array([.uint(UInt64(sfCompression))])
        let tail = [ceilingValue, functionalityValue, exactValue]

        guard let displayName else {
            return MsgPack.encode(.array([.null] + tail))
        }

        var nameBytes = Data(displayName.utf8)
        let budget = displayNameBudget(tail: tail,
                                       maxBytes: ratchet ? maxAppDataBytesWithRatchet : maxAppDataBytes)
        if nameBytes.count > budget {
            nameBytes = Data(truncated(displayName, toUTF8Bytes: budget).utf8)
        }
        return MsgPack.encode(.array([.bin(nameBytes)] + tail))
    }

    /// How many UTF-8 bytes of display name fit in `maxBytes` (`maxAppDataBytes`, or
    /// `maxAppDataBytesWithRatchet`), given the rest of this particular blob (`tail`: a null cost
    /// encodes shorter than a ceiling plus a float64).
    ///
    /// The non-name overhead is MEASURED by encoding the blob with an empty name, not tallied by
    /// hand, so a change to the msgpack encoder or to the shape of the array cannot silently
    /// invalidate it.
    ///
    /// The extra `- 1` covers the bin header growing from bin8 (2 bytes) to bin16 (3 bytes) above
    /// 255 name bytes. It is unconditional because this budget only ever binds well above 255
    /// (its smallest possible value here is 299, or 267 with a ratchet), so reserving the byte costs
    /// nothing real.
    private static func displayNameBudget(tail: [MsgPackValue], maxBytes: Int) -> Int {
        let overhead = MsgPack.encode(.array([.bin(Data())] + tail)).count
        return maxBytes - overhead - 1
    }

    /// The longest prefix of `name` that is at most `budget` UTF-8 bytes, cut on an extended
    /// grapheme cluster boundary.
    ///
    /// Iterating `Character`s rather than slicing bytes is load-bearing. Cutting mid-scalar emits
    /// invalid UTF-8, and reference's `dn.decode("utf-8")` (LXMF.py:165) would then raise — so a
    /// peer would see NO name at all instead of a shortened one. Cutting mid-cluster (between the
    /// scalars of an emoji ZWJ sequence, or before a combining mark) is valid UTF-8 but renders as
    /// a different glyph; `Character` granularity avoids both.
    private static func truncated(_ name: String, toUTF8Bytes budget: Int) -> String {
        var out = ""
        var used = 0
        for character in name {
            let width = String(character).utf8.count
            if used + width > budget { break }
            out.append(character)
            used += width
        }
        return out
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
        // Leading value, not strict: a stamped RNS 1.6 announce has 18 more bytes after the array.
        guard case let .array(items)? = MsgPack.decodeLeadingValue(data) else { return nil }

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

    /// Extract the stamp cost: element [3] when it is a number, else element [1]
    /// (`stamp_cost_from_app_data`, LXMF 1.3.0 LXMF.py:183-199, which tests `type(peer_data[3])` for
    /// `float` or `int`; a msgpack bool is neither there, and is not `isNumber` here).
    ///
    /// The element is chosen by TYPE first and only then gated, as reference chooses: a numeric [3]
    /// outside the gate gives nil, not a fall-back to [1].
    ///
    /// The gate is `LXStamper.costInRange` (`0 < cost < 100`, false for NaN and infinities); see the
    /// note on `stampCost` for how that narrows reference, which returns the element verbatim. A
    /// non-numeric element (a string, a list) is also nil, where reference returns it as-is and lets
    /// the caller trip over it.
    ///
    /// The value is surfaced exactly, not re-quantized: reference stores what it parsed
    /// (`update_stamp_cost`, LXMRouter.py:1154-1157) and its stamp arithmetic quantizes when it uses
    /// it, as `LXStamper` does.
    private static func parseStampCost(from items: [MsgPackValue]) -> Double? {
        guard items.count >= 2 else { return nil }
        let chosen = items.count > 3 && items[3].isNumber ? items[3] : items[1]
        guard let cost = chosen.numberValue, LXStamper.costInRange(cost) else { return nil }
        return cost
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
