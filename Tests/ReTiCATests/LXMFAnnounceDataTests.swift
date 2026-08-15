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
/// "Alice" starts with 0x41, which is outside the array-byte gate, so parse must
/// treat the entire blob as a UTF-8 display name.
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

/// A name that begins with a byte in 0x90-0x9F (fixarray) would be misread as msgpack.
/// Verify that a name starting with 0x41 (a safe byte) is correct.
@Test func lxmfAnnounceDataPre050ByteNotInArrayRange() {
    // 0x41 = 'A', outside the 0x90-0x9F and 0xDC gate
    let first = Data("Alice".utf8).first!
    #expect(!(first >= 0x90 && first <= 0x9F) && first != 0xDC)
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

/// A stamp cost of UInt64.max must never trap; it must return nil or a bounded value.
@Test func lxmfAnnounceDataStampCostUInt64MaxNeverTraps() {
    // fixarray(3) [ null, uint64(UInt64.max), fixarray(0) ]
    // CF FFFFFFFFFFFFFFFF = uint64 UInt64.max
    let blob = Data([0x93, 0xC0, 0xCF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x90])
    let result = LXMFAnnounceData.parse(blob)
    // Must not trap. UInt64.max cannot fit in Int (on 64-bit: UInt64.max > Int.max),
    // so it either returns nil or a value that's within the valid cost range.
    // Either outcome is acceptable; a crash is not.
    if let result {
        // If we got a result, the stamp cost must be either nil or in 1...254.
        if let cost = result.stampCost {
            #expect(cost > 0 && cost < 255)
        }
    }
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
    // 0xDD is array32; reference gate excludes it, so the whole blob is treated as
    // a legacy UTF-8 display name. Since 0xDD is not valid UTF-8, displayName will be nil.
    // The crucial invariant: the result must not be parsed as a 3-element msgpack struct.
    let blob = Data([0xDD, 0x00, 0x00, 0x00, 0x03, 0xC0, 0xC0, 0x90])
    let result = LXMFAnnounceData.parse(blob)
    // It may return a result with nil displayName (legacy path, invalid UTF-8) or nil.
    // It must NOT return a result whose supportsCompression == false (which would only
    // happen if it parsed the 0xDD blob as a 3-element array with an empty [2]).
    if let result {
        // If we got a result via the legacy path, displayName is nil (invalid UTF-8)
        // and compression defaults to true.
        #expect(result.supportsCompression == true)
    }
}
