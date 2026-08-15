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

// MARK: — Stamp cost gate (strict both ends: > 0 && < 255)

/// Cost 0 is below the gate: must advertise as nil (reference: `> 0 and < 255`).
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

/// Cost 1 is inside the gate; cost 254 is inside the gate.
@Test func lxmfAnnounceDataStampCostEdgeValuesInside() {
    let lo = LXMFAnnounceData.parse(LXMFAnnounceData.pack(displayName: nil, stampCost: 1))
    #expect(lo != nil)
    if let lo { #expect(lo.stampCost == 1) }

    let hi = LXMFAnnounceData.parse(LXMFAnnounceData.pack(displayName: nil, stampCost: 254))
    #expect(hi != nil)
    if let hi { #expect(hi.stampCost == 254) }
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

/// A stamp cost of UInt64.max is REJECTED (surfaces as nil), not truncated, and does not trap.
///
/// Both halves of the name are asserted:
/// - "without trapping" — the test reaching its assertions at all is the proof; `Int(_:)` on
///   UInt64.max aborts the process, so a regression here kills the run rather than failing.
/// - "rejected" — `stampCost == nil`. This is the load-bearing assertion and the one that
///   distinguishes `Int(exactly:)` from a truncating conversion, which would yield -1.
///
/// The rest of the struct must still parse: an out-of-range cost degrades that one field,
/// it does not fail the whole announce.
@Test func lxmfAnnounceDataStampCostUInt64MaxRejectedWithoutTrapping() {
    // fixarray(3) [ null, uint64(UInt64.max), fixarray(0) ]
    // CF FFFFFFFFFFFFFFFF = uint64 UInt64.max
    let blob = Data([0x93, 0xC0, 0xCF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x90])
    let result = LXMFAnnounceData.parse(blob)
    #expect(result != nil)                       // the announce still parses
    #expect(result?.stampCost == nil)            // rejected, NOT truncated to -1
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
