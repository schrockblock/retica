import Foundation

/// LXMF delivery-destination announce app-data codec. Mirrors LXMF 1.1.0
/// `LXMRouter.get_announce_app_data` (LXMRouter.py:1034-1050) for packing and the three
/// consumer helpers `display_name_from_app_data`, `stamp_cost_from_app_data`,
/// `compression_support_from_app_data` (LXMF.py:151-200) for parsing.
///
/// **Wire format (0.5.0+):** msgpack array `[display_name, stamp_cost, [SF_COMPRESSION]]`
/// where `display_name` is bin (Python `bytes`) or null, `stamp_cost` is a uint or null, and
/// the third element is an array of supported functionality codes. `SF_COMPRESSION = 0x00`.
/// Conforming peers emit a `stamp_cost` only in 1...254, but **that is a property of what
/// reference sends, not of what it accepts** — nothing on the parse side enforces it, so do not
/// read the range as a wire invariant. See `stampCost`.
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

    /// Stamp cost advertised by the delivery destination, or nil.
    ///
    /// **The range is asymmetric between pack and parse. Read this before using the value.**
    ///
    /// - **On pack** this is gated to 1...254: `pack` applies reference's strict
    ///   `> 0 and < 255` (LXMRouter.py:1044), so 0, 255 and anything outside emit as null.
    ///   Every value ReTiCA *emits* is therefore in 1...254 or absent.
    ///
    /// - **On parse this range is NOT guaranteed.** Reference's `stamp_cost_from_app_data`
    ///   (LXMF.py:174-185) applies no gate at all — it returns `peer_data[1]` verbatim — so a
    ///   peer may advertise 0, 255, or 60000 and we surface it as-is. `parse` bounds this only
    ///   to what an `Int` can hold: 0...Int.max (`parseStampCost` uses `Int(exactly:)`, which
    ///   rejects > Int.max rather than truncating). Announce app-data is unauthenticated and
    ///   arrives from any reachable peer, so treat a parsed value as hostile input.
    ///
    /// **Callers that store or act on a parsed value MUST validate it themselves.** In
    /// particular, a stamp cost drives a proof-of-work search whose cost is *exponential* in
    /// the value (`LXStamper`), so feeding an unvalidated parsed cost into stamp generation
    /// turns a one-byte announce field into an unbounded CPU burn. An `Int` that looks bounded
    /// because the emit side is bounded is exactly how that ceiling becomes invisible.
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

    /// Largest app-data blob, in bytes, that still fits inside a Reticulum announce packet.
    ///
    ///     Packet.mtu                               500
    ///   − HEADER_1 announce header                − 19   flags + hops + 16-byte destination
    ///                                                    hash + context (`Packet.packed()`)
    ///   − fixed announce payload                  − 148  64-byte public key + 10-byte name hash
    ///                                                    + 10-byte random hash + 64-byte
    ///                                                    signature (`Announce.buildPayload`)
    ///                                             = 333
    ///
    /// **Assumes no ratchet.** `Transport`'s `.announce` case passes `ratchet: nil` today. A
    /// ratchet is a fifth fixed payload field of `Announce.ratchetSize` (32) bytes, so if ReTiCA
    /// ever announces one this must drop by 32 — otherwise a name that fits here stops fitting
    /// on the wire, which is exactly the failure this constant exists to prevent.
    ///
    /// **Dropping the constant is necessary but not sufficient, and an earlier note here said
    /// otherwise.** It claimed a ratchet would "merely fail to announce rather than poison state,
    /// because the capture-after-pack fix is independent". That is wider than the evidence: the fix
    /// stops a *new* unsendable value being captured, but nothing clears one already captured.
    /// `Transport.state.localAppData` is written in exactly two places — cleared on
    /// `.registerLocalDestination`, and set after a successful pack — so a name captured while it
    /// fit (≤ 333 B) becomes unsendable the moment a ratchet adds 32 bytes, and from then on
    /// `announce(nil)` and local path responses go silent again with no self-heal. A re-review
    /// probe characterised exactly that state: seeded oversize sticky entry → zero transmits.
    /// So when ratchets land: drop this by 32 **and** re-validate or clear existing captures.
    public static let maxAppDataBytes =
        Packet.mtu
        - (Packet.addressLength + 3)
        - (Announce.keySize + Announce.nameHashLength + Announce.randomHashLength
           + Announce.signatureLength)

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
    ///
    /// **`displayName` is truncated to fit `maxAppDataBytes`** — see `displayNameBudget`. This is
    /// a DELIBERATE DIVERGENCE: reference `get_announce_app_data` (LXMRouter.py:1034-1050) applies
    /// no length bound, and an over-long name there makes `RNS.Packet.pack` raise IOError
    /// (RNS 1.4.2 Packet.py:234-236) so the announce simply fails. ReTiCA's `Transport` `.announce`
    /// swallows that failure (`try?`), so an unbounded name here silently took the destination off
    /// the network — a shortened name is strictly better than no announce. Names that already fit
    /// are byte-identical to before, so the cross-validation vectors are untouched.
    public static func pack(displayName: String?, stampCost: Int?) -> Data {
        let costValue: MsgPackValue
        if let cost = stampCost, cost > 0, cost < 255 {
            costValue = .uint(UInt64(cost))
        } else {
            costValue = .null
        }

        let functionalityValue: MsgPackValue = .array([.uint(UInt64(sfCompression))])

        guard let displayName else {
            return MsgPack.encode(.array([.null, costValue, functionalityValue]))
        }

        var nameBytes = Data(displayName.utf8)
        let budget = displayNameBudget(costValue: costValue, functionalityValue: functionalityValue)
        if nameBytes.count > budget {
            nameBytes = Data(truncated(displayName, toUTF8Bytes: budget).utf8)
        }
        return MsgPack.encode(.array([.bin(nameBytes), costValue, functionalityValue]))
    }

    /// How many UTF-8 bytes of display name fit in `maxAppDataBytes`, given the rest of this
    /// particular blob (a 1-byte stamp cost encodes shorter than a 2-byte one).
    ///
    /// The non-name overhead is MEASURED by encoding the blob with an empty name, not tallied by
    /// hand, so a change to the msgpack encoder or to the shape of the array cannot silently
    /// invalidate it.
    ///
    /// The extra `- 1` covers the bin header growing from bin8 (2 bytes) to bin16 (3 bytes) above
    /// 255 name bytes. It is unconditional because this budget only ever binds well above 255
    /// (its smallest possible value here is 325), so reserving the byte costs nothing real.
    private static func displayNameBudget(costValue: MsgPackValue,
                                          functionalityValue: MsgPackValue) -> Int {
        let overhead = MsgPack.encode(.array([.bin(Data()), costValue, functionalityValue])).count
        return maxAppDataBytes - overhead - 1
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
    ///
    /// Returns nil only when `items.count < 2`, when the element is not a uint, or when the
    /// uint exceeds `Int.max`. **It does NOT gate the range** — an out-of-range cost such as
    /// 0, 255 or 60000 is returned as-is, not rejected. (An earlier version of this first line
    /// said "returns nil if ... not a uint in 1...254", which contradicted the rest of this same
    /// comment and the code below. The summary was wider than the body.)
    ///
    /// That permissiveness is deliberate parity **on the range only**: reference's
    /// `stamp_cost_from_app_data` (LXMF.py:174-185) returns `peer_data[1]` verbatim with no gate.
    /// The `> 0 && < 255` gate exists only on the emit side, in `get_announce_app_data`
    /// (LXMRouter.py:1044), and ours lives correspondingly in `pack`.
    ///
    /// Parity is NOT total, and the two gaps both narrow what we surface:
    /// - a NEGATIVE cost — reference returns it verbatim (Python ints are signed and unbounded);
    ///   we return nil for the `.int` branch when `i < 0`.
    /// - a NON-INTEGER `peer_data[1]` (a string, a float, a list) — reference returns that object
    ///   as-is and lets the caller trip over it; our `default` arm returns nil.
    ///
    /// **These divergences became observable when delivery stamps were wired** (this note used to
    /// say "no caller acts on a parsed cost yet — revisit if one ever does"; that revisit trigger
    /// has now fired). The caller is `LXMFNode.deliveryStampCost`, via `LXMFNode.LearnedPeer`.
    ///
    /// Concretely, for a NEGATIVE advertised cost the two stacks now do different things:
    /// - **Reference** carries it through `handle_outbound` into `LXMessage.get_stamp`, which skips
    ///   generation only when the cost is `None` (LXMessage.py:307). The search's validity test is
    ///   `target = 1 << (256 - cost)` (LXStamper.py:74) — for a negative cost that target exceeds
    ///   every possible 256-bit hash, so the FIRST random stamp passes and reference attaches a
    ///   trivially-valid stamp at essentially zero cost.
    /// - **We** surface nil, so `deliveryStampCost` returns nil and no stamp is attached.
    ///
    /// This stays in the safe direction, and it is not a known deliverability loss: a negative cost
    /// is unreachable from a CONFORMING peer in the first place — `set_inbound_stamp_cost` coerces
    /// any cost `< 1` to `None` (LXMRouter.py:378-388) and `get_announce_app_data` emits a value
    /// only when `> 0 and < 255` (LXMRouter.py:1044) — so a peer advertising one is already
    /// non-conforming, and has no conforming route to then enforce a positive cost against us. The
    /// difference is only in how much free work each stack does for a malformed announce.
    ///
    /// Wire safety: announce app-data is unauthenticated and arrives from any reachable peer.
    /// `Int(exactly:)` converts from UInt64 so `UInt64.max` yields nil rather than trapping, and
    /// nothing here truncates. The resulting `Int` is bounded only by `Int.max`, so **callers
    /// must validate before acting on it** — see the note on the `stampCost` property, which
    /// explains why feeding an unvalidated value into stamp generation is an unbounded CPU burn.
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
