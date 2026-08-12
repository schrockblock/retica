import Testing
import Foundation
@testable import ReTiCA

@Test func frameWrapsWithFlagsAndEscapes() {
    let framed = HDLC.frame(Data([0x01, 0x02]))
    #expect(framed == Data([0x7E, 0x01, 0x02, 0x7E]))
}

@Test func escapeReplacesFlagAndEscBytes() {
    // raw FLAG (0x7E) -> 7D 5E ; raw ESC (0x7D) -> 7D 5D
    #expect(HDLC.escape(Data([0x7E])) == Data([0x7D, 0x5E]))
    #expect(HDLC.escape(Data([0x7D])) == Data([0x7D, 0x5D]))
    #expect(HDLC.escape(Data([0x00, 0x7E, 0x7D, 0x01])) == Data([0x00, 0x7D, 0x5E, 0x7D, 0x5D, 0x01]))
}

@Test func frameDeframeRoundTripsPayloadContainingFlagAndEsc() {
    let payload = Data([0x00, 0x7E, 0x11, 0x7D, 0x22] + Array(repeating: 0xAB, count: 20))
    var deframer = HDLCDeframer()
    let frames = deframer.ingest(HDLC.frame(payload))
    #expect(frames == [payload])
}

@Test func deframerDeliversTwoFramesSharingAFlag() {
    let a = Data(repeating: 0xA1, count: 25)
    let b = Data(repeating: 0xB2, count: 30)
    // FLAG a FLAG b FLAG (consecutive frames share the middle FLAG)
    var buf = Data([HDLC.flag]); buf.append(HDLC.escape(a))
    buf.append(HDLC.flag); buf.append(HDLC.escape(b)); buf.append(HDLC.flag)
    var deframer = HDLCDeframer()
    #expect(deframer.ingest(buf) == [a, b])
}

@Test func deframerAccumulatesAcrossIngests() {
    let payload = Data(repeating: 0xC3, count: 40)
    let framed = HDLC.frame(payload)
    let mid = framed.count / 2
    var deframer = HDLCDeframer()
    #expect(deframer.ingest(framed.prefix(mid)) == [])          // incomplete
    #expect(deframer.ingest(framed.suffix(framed.count - mid)) == [payload])
}

@Test func unescapeReversesEscapesAndPassesUnknownEscThrough() {
    #expect(HDLC.unescape(Data([0x7D, 0x5E])) == Data([0x7E]))          // 7D 5E -> FLAG
    #expect(HDLC.unescape(Data([0x7D, 0x5D])) == Data([0x7D]))          // 7D 5D -> ESC
    #expect(HDLC.unescape(Data([0x7D])) == Data([0x7D]))                // lone trailing ESC passes through
    #expect(HDLC.unescape(Data([0x7D, 0x99])) == Data([0x7D, 0x99]))    // unknown ESC pair passes through (matches reference)
}

@Test func deframerDiscardsLeadingGarbageAndTooShortFrames() {
    let payload = Data(repeating: 0xD4, count: 25)
    var buf = Data([0xFF, 0xFE])                 // leading garbage before first FLAG
    buf.append(HDLC.frame(payload))
    var deframer = HDLCDeframer()
    #expect(deframer.ingest(buf) == [payload])

    // A frame of exactly 19 bytes is dropped (must be > 19)
    let short = Data(repeating: 0x01, count: 19)
    var d2 = HDLCDeframer()
    #expect(d2.ingest(HDLC.frame(short)) == [])
    let ok = Data(repeating: 0x01, count: 20)
    var d3 = HDLCDeframer()
    #expect(d3.ingest(HDLC.frame(ok)) == [ok])
}

// A peer that never sends a FLAG must not grow the deframer without bound.
@Test func deframerDiscardsRunawayInputWithNoFlag() {
    var d = HDLCDeframer(maxFrameSize: 1024)
    for _ in 0..<64 {
        #expect(d.ingest(Data(repeating: 0x41, count: 1024)).isEmpty)
    }
    #expect(d.bufferedByteCount <= 1024 * 2)
}

// An opening FLAG with no closing FLAG must also be bounded.
@Test func deframerDiscardsUnterminatedFrame() {
    var d = HDLCDeframer(maxFrameSize: 1024)
    _ = d.ingest(Data([HDLC.flag]))
    for _ in 0..<64 {
        #expect(d.ingest(Data(repeating: 0x41, count: 1024)).isEmpty)
    }
    #expect(d.bufferedByteCount <= 1024 * 2)
}

// A legitimate frame still round-trips after a runaway reset.
@Test func deframerRecoversAfterDiscard() {
    var d = HDLCDeframer(maxFrameSize: 1024)
    _ = d.ingest(Data(repeating: 0x41, count: 4096))
    let payload = Data(repeating: 0x5A, count: 40)
    #expect(d.ingest(HDLC.frame(payload)) == [payload])
}

// A terminated frame that exceeds maxFrameSize is rejected (mirrors check_frame_len > HW_MTU).
@Test func deframerRejectsOversizedFrame() {
    var d = HDLCDeframer(minFrameSize: 19, maxFrameSize: 100)
    let big = Data(repeating: 0xBB, count: 101)
    #expect(d.ingest(HDLC.frame(big)).isEmpty)
    // A frame at exactly maxFrameSize is accepted.
    let ok = Data(repeating: 0xCC, count: 100)
    var d2 = HDLCDeframer(minFrameSize: 19, maxFrameSize: 100)
    #expect(d2.ingest(HDLC.frame(ok)) == [ok])
}
