import Testing
import Foundation
@testable import ReTiCA

// MARK: — Round-trip tests

/// A display name and stamp cost that survive pack → parse unchanged.
@Test func lxmfAnnounceDataRoundTripWithNameAndCost() {
    let packed = LXMFAnnounceData.pack(displayName: "Alice", stampCost: 8)
    let result = LXMFAnnounceData.parse(packed)
    #expect(result != nil)
    if let result {
        #expect(result.displayName == "Alice")
        #expect(result.stampCost == 8)
        #expect(result.supportsCompression == true)
    }
}

/// nil display name and nil stamp cost must pack as msgpack null (0xC0), not be omitted,
/// so that the array element count stays at 3 and round-trips cleanly.
@Test func lxmfAnnounceDataRoundTripWithNils() {
    let packed = LXMFAnnounceData.pack(displayName: nil, stampCost: nil)
    let result = LXMFAnnounceData.parse(packed)
    #expect(result != nil)
    if let result {
        #expect(result.displayName == nil)
        #expect(result.stampCost == nil)
        #expect(result.supportsCompression == true)
    }
}

// MARK: — Stamp cost gate (strict both ends: > 0 && < 100)

/// Cost 0 is below the gate: must advertise as nil (reference: `> 0 and < STAMP_COST_CAP`, cap 100).
@Test func lxmfAnnounceDataStampCostZeroAdvertisesAsNil() {
    let packed = LXMFAnnounceData.pack(displayName: nil, stampCost: 0)
    let result = LXMFAnnounceData.parse(packed)
    #expect(result != nil)
    if let result {
        #expect(result.stampCost == nil)
    }
}

/// Cost 255 is above the gate: must advertise as nil.
@Test func lxmfAnnounceDataStampCostMaxBoundAdvertisesAsNil() {
    let packed = LXMFAnnounceData.pack(displayName: nil, stampCost: 255)
    let result = LXMFAnnounceData.parse(packed)
    #expect(result != nil)
    if let result {
        #expect(result.stampCost == nil)
    }
}

/// Cost 1 is inside the gate; cost 99 (one under the cap of 100) is inside the gate.
@Test func lxmfAnnounceDataStampCostEdgeValuesInside() {
    let lo = LXMFAnnounceData.parse(LXMFAnnounceData.pack(displayName: nil, stampCost: 1))
    #expect(lo != nil)
    if let lo { #expect(lo.stampCost == 1) }

    let hi = LXMFAnnounceData.parse(LXMFAnnounceData.pack(displayName: nil, stampCost: 99))
    #expect(hi != nil)
    if let hi { #expect(hi.stampCost == 99) }
}

/// LXMF 1.3.0 emits a cost only when `> 0 and < STAMP_COST_CAP` (cap 100, LXMRouter.py:1173), so
/// 100 and above advertise as nil. A reference sender cannot stamp at a cost above 100
/// (`generate_stamp` raises), so advertising one would make us undeliverable.
@Test func lxmfAnnounceDataStampCostAtAndAboveTheCapAdvertisesAsNil() {
    for cost: Double in [100, 101, 254, .nan, .infinity, -.infinity, -1, 0] {
        let parsed = LXMFAnnounceData.parse(LXMFAnnounceData.pack(displayName: nil, stampCost: cost))
        #expect(parsed != nil)
        #expect(parsed?.stampCost == nil, "cost \(cost) must not be advertised")
    }
}

/// The parser surfaces a PEER's cost only inside reference's emit gate (`0 < cost < 100`). This
/// narrows LXMF 1.3.0's `stamp_cost_from_app_data` (LXMF.py:183-199), which returns the element
/// verbatim, so reference reads a hand-built 101 as 101 (cross-validated in
/// LXMFFractionalCostAppDataCrossValidationTests); we read nil, and send no stamp, as we would for
/// any cost above our outbound ceiling.
@Test func lxmfAnnounceDataParseNarrowsAPeersAdvertisedCostToTheGate() {
    let blob = MsgPack.encode(.array([.null, .uint(101), .array([.uint(0)])]))
    #expect(LXMFAnnounceData.parse(blob)?.stampCost == nil)
    let inside = MsgPack.encode(.array([.null, .uint(99), .array([.uint(0)])]))
    #expect(LXMFAnnounceData.parse(inside)?.stampCost == 99)
}

/// A fractional cost round-trips exactly, on the 1/256 grid, in element [3] as a float64, with its
/// ceiling in element [1] (LXMRouter.py:1179).
@Test func lxmfAnnounceDataFractionalCostRoundTripsAndCarriesItsCeiling() throws {
    let packed = LXMFAnnounceData.pack(displayName: nil, stampCost: 8.5)
    guard case let .array(items)? = MsgPack.decodeValue(packed) else { Issue.record("not an array"); return }
    try #require(items.count == 4)              // require: the index reads below would trap
    #expect(items[1] == .uint(9))
    #expect(items[3] == .double(8.5))
    #expect(LXMFAnnounceData.parse(packed)?.stampCost == 8.5)
    // Off the grid: quantized half up, as reference's quantize_cost.
    #expect(LXMFAnnounceData.parse(LXMFAnnounceData.pack(displayName: nil, stampCost: 13.3))?.stampCost
            == 13.30078125)
}

// MARK: — Pre-0.5.0 legacy format (first byte outside 0x90-0x9F / 0xDC)

/// LXMF before 0.5.0 stored just a raw UTF-8 display name, not a msgpack array.
/// "Alice" starts with 0x41, which is outside the array-byte gate (0x90-0x9F, 0xDC), so
/// parse must treat the entire blob as a UTF-8 display name.
///
/// The fixture assumption — that 'A' is outside the gate — is self-guarding rather than
/// separately asserted: a first byte inside the gate would send this blob down the msgpack
/// path, where it fails to decode and `displayName` comes back nil, failing the test below.
/// (A predecessor asserted the byte range as its own test; that asserted a property of a
/// Swift string literal, not of `parse`, so it could never fail. Folded to this comment.)
@Test func lxmfAnnounceDataPre050LegacyFormat() {
    let blob = Data("Alice".utf8)
    let result = LXMFAnnounceData.parse(blob)
    #expect(result != nil)
    if let result {
        #expect(result.displayName == "Alice")
        #expect(result.stampCost == nil)
        #expect(result.supportsCompression == true)
    }
}

// MARK: — Display name null-stripping and whitespace trimming

/// display_name_from_app_data does `.replace("\x00","").strip()` before returning.
/// Embedded NUL bytes must be stripped; surrounding whitespace must be trimmed.
@Test func lxmfAnnounceDataDisplayNameStrippedAndTrimmed() {
    // Pack a name with embedded NUL and surrounding spaces
    let raw = "  Al\u{00}ice  "
    let packed = LXMFAnnounceData.pack(displayName: raw, stampCost: nil)
    let result = LXMFAnnounceData.parse(packed)
    #expect(result != nil)
    if let result {
        #expect(result.displayName == "Alice")
    }
}

// MARK: — Short-array degradation (no failure, just defaults)

/// A 1-element msgpack array has displayName but no stamp cost. Reference: `len < 2 -> nil`.
/// Compression must return true (reference: `len < 3 -> True`).
@Test func lxmfAnnounceDataOneElementArrayDegrades() {
    // fixarray(1) [ null ]
    let blob = Data([0x91, 0xC0])
    let result = LXMFAnnounceData.parse(blob)
    #expect(result != nil)
    if let result {
        #expect(result.displayName == nil)
        #expect(result.stampCost == nil)
        #expect(result.supportsCompression == true)
    }
}

/// A 2-element msgpack array has displayName and stamp cost but no functionality list.
/// Reference: `len < 3 -> True` for compression.
@Test func lxmfAnnounceDataTwoElementArrayDegrades() {
    // fixarray(2) [ null, null ]
    let blob = Data([0x92, 0xC0, 0xC0])
    let result = LXMFAnnounceData.parse(blob)
    #expect(result != nil)
    if let result {
        #expect(result.stampCost == nil)
        #expect(result.supportsCompression == true)
    }
}

/// peer_data[2] present but not an array → compression true.
@Test func lxmfAnnounceDataFunctionalityNotAnArrayMeansCompressionTrue() {
    // fixarray(3) [ null, null, null ]  — [2] is null, not an array
    let blob = Data([0x93, 0xC0, 0xC0, 0xC0])
    let result = LXMFAnnounceData.parse(blob)
    #expect(result != nil)
    if let result {
        #expect(result.supportsCompression == true)
    }
}

/// peer_data[2] is an empty array → SF_COMPRESSION (0x00) not present → compression false.
@Test func lxmfAnnounceDataEmptyFunctionalityArrayMeansCompressionFalse() {
    // fixarray(3) [ null, null, fixarray(0) ]
    let blob = Data([0x93, 0xC0, 0xC0, 0x90])
    let result = LXMFAnnounceData.parse(blob)
    #expect(result != nil)
    if let result {
        #expect(result.supportsCompression == false)
    }
}

// MARK: — Hostile input (must never trap)

/// Empty Data must return nil without trapping (guard before first-byte read).
@Test func lxmfAnnounceDataEmptyDataReturnsNil() {
    #expect(LXMFAnnounceData.parse(Data()) == nil)
}

/// A truncated msgpack body (array header present, content missing) must return nil.
@Test func lxmfAnnounceDataTruncatedMsgpackReturnsNil() {
    // fixarray(3) header only — no elements
    let blob = Data([0x93])
    #expect(LXMFAnnounceData.parse(blob) == nil)
}

/// A stamp cost of UInt64.max is REJECTED (surfaces as nil) and does not trap.
///
/// Both halves of the name are asserted:
/// - "without trapping" — the test reaching its assertions at all is the proof.
/// - "rejected" — `stampCost == nil`: the value, read as a Double, is outside the `0 < cost < 100`
///   gate (`LXStamper.costInRange`).
///
/// The rest of the struct must still parse: an out-of-range cost degrades that one field,
/// it does not fail the whole announce.
@Test func lxmfAnnounceDataStampCostUInt64MaxRejectedWithoutTrapping() {
    // fixarray(3) [ null, uint64(UInt64.max), fixarray(0) ]
    // CF FFFFFFFFFFFFFFFF = uint64 UInt64.max
    let blob = Data([0x93, 0xC0, 0xCF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x90])
    let result = LXMFAnnounceData.parse(blob)
    #expect(result != nil)                       // the announce still parses
    #expect(result?.stampCost == nil)            // rejected
    #expect(result?.displayName == nil)          // [0] is null
    #expect(result?.supportsCompression == false) // [2] is an empty list → no SF_COMPRESSION
}

/// Invalid UTF-8 in a bin field yields nil display name (no crash from String init failure).
@Test func lxmfAnnounceDataInvalidUtf8DisplayNameYieldsNil() {
    // fixarray(3) [ bin(2)[ 0xFF, 0xFE ] (invalid UTF-8), null, fixarray(0) ]
    // C4 02 FF FE = bin8(2) followed by two invalid UTF-8 bytes
    let blob = Data([0x93, 0xC4, 0x02, 0xFF, 0xFE, 0xC0, 0x90])
    let result = LXMFAnnounceData.parse(blob)
    // The parse must succeed (not return nil for the whole struct),
    // but displayName must be nil because the bytes are not valid UTF-8.
    #expect(result != nil)
    if let result {
        #expect(result.displayName == nil)
    }
}

// MARK: — Non-zero startIndex (Data slice safety)

/// Parsing a Data slice with a non-zero startIndex must behave identically to
/// parsing the same bytes starting at index 0. This codebase has been bitten by
/// non-zero-based Data indices before (data[0] on a slice traps).
@Test func lxmfAnnounceDataParsesSliceWithNonZeroStartIndex() {
    // Build a valid packed payload and prepend a sentinel byte, then drop it.
    let packed = LXMFAnnounceData.pack(displayName: "Bob", stampCost: 16)
    let prefixed = Data([0xFF]) + packed          // startIndex of the dropped slice will be 1
    let slice = prefixed.dropFirst()              // slice.startIndex == 1
    #expect(slice.startIndex == 1)
    let resultFromSlice = LXMFAnnounceData.parse(slice)
    let resultFromFull  = LXMFAnnounceData.parse(packed)
    // Assert the CONCRETE values, not just slice-equals-full. A bare `a?.x == b?.x` chain
    // passes when BOTH sides are nil, so a parse that failed on every input would satisfy it
    // while proving nothing about slice handling. Same vacuity class as the two the review
    // flagged; found by re-reading for the pattern.
    #expect(resultFromSlice != nil)
    #expect(resultFromFull  != nil)
    #expect(resultFromSlice?.displayName == "Bob")
    #expect(resultFromSlice?.stampCost == 16)
    #expect(resultFromSlice?.supportsCompression == true)
    // ...and that the slice agrees with the zero-based parse on every field.
    #expect(resultFromSlice?.displayName == resultFromFull?.displayName)
    #expect(resultFromSlice?.stampCost   == resultFromFull?.stampCost)
    #expect(resultFromSlice?.supportsCompression == resultFromFull?.supportsCompression)
}

// MARK: — 0xDC (array16) IS accepted as the msgpack gate

/// Reference gate includes 0xDC (array16). A 3-element array16 blob must be parsed as
/// the 0.5.0+ format, not the legacy path. Smoke-tests the second branch of the gate.
@Test func lxmfAnnounceDataArray16FirstByteAcceptedAsMsgpackGate() {
    // DC 00 03 = array16(3), then [null, null, fixarray(0)]
    let blob = Data([0xDC, 0x00, 0x03, 0xC0, 0xC0, 0x90])
    let result = LXMFAnnounceData.parse(blob)
    // Must be parsed as 3-element msgpack array: displayName nil, stampCost nil, compression false
    #expect(result != nil)
    if let result {
        #expect(result.displayName == nil)
        #expect(result.stampCost == nil)
        #expect(result.supportsCompression == false)   // empty [2] array → no SF_COMPRESSION
    }
}

// MARK: — 0xDD (array32) must NOT be accepted as the array gate

/// Reference consumers only accept 0x90-0x9F (fixarray) and 0xDC (array16) as the
/// array gate. 0xDD (array32) is NOT accepted — match the reference gate, don't
/// accept any array tag. When first byte is 0xDD the pre-0.5.0 path fires instead.
@Test func lxmfAnnounceDataArray32ByteNotAcceptedAsMsgpackGate() {
    // 0xDD is array32; the reference gate excludes it, so the whole blob takes the legacy
    // path and is treated as a raw UTF-8 display name. 0xDD is a 2-byte lead byte (110xxxxx)
    // followed by 0x00, which is not a continuation byte, so the blob is not valid UTF-8 and
    // the decoded name is nil.
    let blob = Data([0xDD, 0x00, 0x00, 0x00, 0x03, 0xC0, 0xC0, 0x90])
    let result = LXMFAnnounceData.parse(blob)
    // The outer non-nil assertion is load-bearing, not ceremony: without it, a future change
    // making parseLegacyFormat return nil on invalid UTF-8 would skip the whole body and this
    // test would pass while asserting nothing. It also pins today's behaviour — the legacy
    // path always yields a struct.
    #expect(result != nil)
    #expect(result?.displayName == nil)
    // The crucial invariant: 0xDD was NOT parsed as a 3-element array. If it had been,
    // items[2] would be the empty fixarray and compression would read false.
    #expect(result?.supportsCompression == true)
}

// MARK: — Display-name length bound

/// The name budget when the stamp cost is null: `maxAppDataBytes` (315: 333 left in the packet, less
/// the 18-byte RNS 1.6 stamp extension reserved for when the host stamps announces) minus 7 bytes of
/// non-name overhead (fixarray header + 2-byte bin8 header + null ceiling + 2-byte functionality
/// array + null fractional cost) minus the 1 byte the bin header grows by above 255 name bytes = 307
/// UTF-8 bytes.
private let nameBudgetWithNullCost = 307

/// With a cost, [1] is a one-byte ceiling (at most 100) and [3] a 9-byte float64: 8 bytes more than
/// the two nulls, so 299.
private let nameBudgetWithCost = 299

@Test func lxmfAnnounceDataReservesTheStampExtension() {
    #expect(LXMFAnnounceData.maxAppDataBytes == 333 - NetworkStamp.extensionLength)
}

/// An over-budget display name must be TRUNCATED, not emitted whole. Emitting it whole produced a
/// blob that `Packet.packed()` rejects, and `Transport`'s `.announce` swallows that failure — so an
/// unbounded name meant no announce at all. Reference has no bound here (`get_announce_app_data`,
/// LXMF 1.1.0 LXMRouter.py:1034-1050); it relies on `RNS.Packet.pack` raising IOError (RNS 1.4.2
/// Packet.py:234-236), which ReTiCA's `try?` does not surface. Deliberate divergence.
///
/// Anti-vacuity: both the packed size AND the recovered name are asserted. A `pack` returning
/// `Data()` fails the `#require` on parse; one that dropped the name fails the count check.
@Test func lxmfAnnounceDataPackTruncatesAnOverBudgetDisplayName() throws {
    let name = String(repeating: "A", count: 400)
    let packed = LXMFAnnounceData.pack(displayName: name, stampCost: nil)

    #expect(packed.count <= LXMFAnnounceData.maxAppDataBytes)
    let parsed = try #require(LXMFAnnounceData.parse(packed))
    let recovered = try #require(parsed.displayName)
    #expect(recovered.utf8.count == nameBudgetWithNullCost)
    #expect(recovered == String(repeating: "A", count: nameBudgetWithNullCost))
}

/// A name that already fits must be emitted byte-identically — truncation must not touch it. This
/// is the wire-compatibility half: every name already announced by any peer is at or under the
/// budget, so no previously-emitted byte may change. Exactly-at-the-budget is the case a fencepost
/// error breaks.
///
/// Anti-vacuity: asserts the recovered name equals the ORIGINAL, so an off-by-one that shaved one
/// character fails; and the packed size is asserted exactly, so a budget that drifted fails too.
@Test func lxmfAnnounceDataPackLeavesAnExactlyBudgetedDisplayNameIntact() throws {
    let name = String(repeating: "B", count: nameBudgetWithNullCost)
    let packed = LXMFAnnounceData.pack(displayName: name, stampCost: nil)

    #expect(packed.count == LXMFAnnounceData.maxAppDataBytes)
    let parsed = try #require(LXMFAnnounceData.parse(packed))
    #expect(parsed.displayName == name)
}

/// The largest cost `pack` emits rounds to at most 100, so its ceiling takes one msgpack byte, but
/// the LXMF 1.3.0 fractional element [3] adds a float64, so the name budget with a cost is
/// `nameBudgetWithCost`, 8 bytes under the null-cost one. `displayNameBudget` measures the
/// encoding rather than assuming it.
///
/// Anti-vacuity: asserts the packed size fits exactly AND that exactly the with-cost budget of name
/// bytes survived AND that the cost itself round-trips.
@Test func lxmfAnnounceDataPackShrinksTheNameBudgetForACost() throws {
    let name = String(repeating: "C", count: 400)
    let packed = LXMFAnnounceData.pack(displayName: name, stampCost: 99.5)

    #expect(packed.count == LXMFAnnounceData.maxAppDataBytes)
    let parsed = try #require(LXMFAnnounceData.parse(packed))
    let recovered = try #require(parsed.displayName)
    #expect(recovered.utf8.count == nameBudgetWithCost)
    #expect(parsed.stampCost == 99.5)
}

/// Truncation must cut on an extended grapheme cluster boundary. A byte-wise cut lands inside the
/// family emoji's ZWJ sequence, producing invalid UTF-8 that reference's `dn.decode("utf-8")`
/// (LXMF.py:165) rejects — the peer would then see NO name rather than a shortened one.
///
/// 300 ASCII bytes + a 25-byte emoji = 325, over the 307-byte budget; a byte-wise cut at 307 would
/// keep 7 bytes of the emoji.
///
/// Anti-vacuity: `try #require` on the recovered name fails outright if the blob decodes to
/// nothing, which is exactly what a mid-scalar cut produces.
@Test func lxmfAnnounceDataPackTruncatesOnAGraphemeBoundary() throws {
    let prefix = String(repeating: "D", count: 300)
    let family = "👩‍👩‍👧‍👦"
    #expect(family.utf8.count == 25)            // pins the arithmetic this test depends on
    let packed = LXMFAnnounceData.pack(displayName: prefix + family, stampCost: nil)

    #expect(packed.count <= LXMFAnnounceData.maxAppDataBytes)
    let parsed = try #require(LXMFAnnounceData.parse(packed))
    let recovered = try #require(parsed.displayName, "a mid-cluster cut yields undecodable UTF-8")
    #expect(recovered == prefix)                // the cluster did not fit, so none of it survives
}

/// A multi-BYTE scalar straddling the budget must be dropped whole. Distinct from the cluster test
/// above: here the cut point falls mid-scalar, the case that produces invalid UTF-8 directly.
@Test func lxmfAnnounceDataPackDropsAStraddlingMultiByteScalarWhole() throws {
    // "é" is 2 UTF-8 bytes and the budget (307) is odd, so the scalar that would reach byte 307
    // starts at 307 and ends at 308 — i.e. it straddles.
    #expect(nameBudgetWithNullCost % 2 == 1)    // pins the parity this test depends on
    let name = String(repeating: "é", count: 200)
    let packed = LXMFAnnounceData.pack(displayName: name, stampCost: nil)

    #expect(packed.count <= LXMFAnnounceData.maxAppDataBytes)
    let parsed = try #require(LXMFAnnounceData.parse(packed))
    let recovered = try #require(parsed.displayName, "a mid-scalar cut yields undecodable UTF-8")
    // 2n <= 307 → n = 153, total 306 bytes; the 154th "é" would have straddled 307.
    #expect(recovered == String(repeating: "é", count: 153))
    #expect(recovered.utf8.count == 306)
}

/// End-to-end: a 400-character name must produce an announce packet that actually PACKS, with the
/// 18-byte RNS 1.6 stamp extension that `Transport` appends when stamping. This is the property the
/// bound exists for; the codec-level size assertions above are a proxy, and a wrong header/payload
/// constant would satisfy them while still overflowing the MTU.
///
/// Anti-vacuity: `Packet.packed()` THROWS `.exceedsMTU` on overflow, so a bad budget fails the test
/// rather than passing quietly. The exact-equality check additionally rejects a budget that was far
/// too conservative, which the `<=` alone would accept.
@Test func lxmfAnnounceDataOversizeNameStillProducesASendableAnnouncePacket() throws {
    let identity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "lxmf",
                           aspects: ["delivery"], identity: identity)!
    let appData = LXMFAnnounceData.pack(displayName: String(repeating: "F", count: 400), stampCost: 200)
    let stampExtension = Data([NetworkStamp.extensionMarker, 0x00]) + Data(repeating: 0x01, count: 14)
        + Data([0x40, 0x03])
    let payload = Announce.buildPayload(identity: identity, destinationHash: dest.hash,
                                        nameHash: dest.nameHash,
                                        randomHash: Data(repeating: 0x01, count: 10),
                                        ratchet: nil, appData: appData + stampExtension)
    let raw = try Packet.announce(from: dest, payload: payload).packed()
    #expect(raw.count == Packet.mtu)
}

// MARK: — parseStampCost signed-integer branch

/// A stamp cost encoded as a msgpack SIGNED int (0xD0 int8, rather than a uint) must still be read.
/// Reference `stamp_cost_from_app_data` (LXMF.py:174-185) returns `peer_data[1]` verbatim and Python
/// does not distinguish the two encodings, so a peer packing 42 as int8 is conformant. The `.int`
/// branch had no test at all.
///
/// Anti-vacuity: asserts the concrete value, so a branch returning nil fails; and asserts
/// compression, which proves the blob parsed as a 3-element array rather than falling to legacy.
@Test func lxmfAnnounceDataParsesAStampCostEncodedAsASignedInt() throws {
    // [null, int8(42), [0]] — 0xD0 is msgpack int8.
    let blob = Data([0x93, 0xC0, 0xD0, 42, 0x91, 0x00])
    let parsed = try #require(LXMFAnnounceData.parse(blob))
    #expect(parsed.stampCost == 42)
    #expect(parsed.supportsCompression == true)
}

/// A NEGATIVE signed stamp cost is surfaced as nil. DELIBERATE, documented divergence: reference
/// returns `peer_data[1]` verbatim, negatives included. Pinned as a test so the divergence is a
/// decision rather than an accident: it is outside the `0 < cost < 100` gate, and reference's own
/// `generate_stamp` refuses a negative cost (RNS/Stamps.py:255), so it would send no stamp either.
@Test func lxmfAnnounceDataParsesANegativeStampCostAsNil() throws {
    // [null, int8(-1), [0]] — 0xD0 0xFF is int8(-1).
    let blob = Data([0x93, 0xC0, 0xD0, 0xFF, 0x91, 0x00])
    let parsed = try #require(LXMFAnnounceData.parse(blob))
    #expect(parsed.stampCost == nil)
    #expect(parsed.supportsCompression == true)
}
