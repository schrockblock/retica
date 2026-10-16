import Testing
import Foundation
@testable import ReTiCAInterfaces

private struct Part { let index: UInt8; let pos: Int8; let body: Data }

private func ramp(_ count: Int, seed: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ seed) })
}

private func parts(_ packet: Data, index: UInt8) -> [Part] {
    let codec = LandandairCodec()
    var out: [Part] = []
    for frame in codec.split(packet, index: index) {
        if case let .data(i, p, b)? = codec.parse(frame) { out.append(Part(index: i, pos: p, body: b)) }
    }
    return out
}

private let t0 = Date(timeIntervalSince1970: 1_000)

extension MeshtasticReassembler {
    @discardableResult
    fileprivate mutating func feed(_ part: Part, from: UInt32 = 1, at now: Date = t0) -> Data? {
        receive(from: from, index: part.index, pos: part.pos, body: part.body, now: now)
    }
}

@Suite struct MeshtasticReassemblerTests {
    @Test func inOrderFragmentsCompleteOnTheLast() {
        var r = MeshtasticReassembler()
        let packet = ramp(500, seed: 1)
        let ps = parts(packet, index: 0)
        #expect(r.feed(ps[0]) == nil)
        #expect(r.feed(ps[1]) == nil)
        #expect(r.feed(ps[2]) == packet)
    }

    @Test func singleFragmentPacketCompletesAtOnce() {
        var r = MeshtasticReassembler()
        let packet = ramp(100, seed: 2)
        #expect(r.feed(parts(packet, index: 0)[0]) == packet)
    }

    /// The reference only assembles when the arriving fragment is the last (process_packet,
    /// Meshtastic_Interface.py:380-387); we also complete on a late middle fragment (spec §5.2).
    @Test func lateMiddleFragmentCompletesThePacket() {
        var r = MeshtasticReassembler()
        let packet = ramp(500, seed: 3)
        let ps = parts(packet, index: 0)
        r.feed(ps[0])
        r.feed(ps[2])
        #expect(r.feed(ps[1]) == packet)
    }

    @Test func lastFragmentFirstStillCompletes() {
        var r = MeshtasticReassembler()
        let packet = ramp(500, seed: 4)
        let ps = parts(packet, index: 0)
        #expect(r.feed(ps[2]) == nil)
        #expect(r.feed(ps[0]) == nil)
        #expect(r.feed(ps[1]) == packet)
    }

    @Test func interleavedSendersReassembleIndependently() {
        var r = MeshtasticReassembler()
        let a = ramp(500, seed: 5), b = ramp(500, seed: 6)
        let pa = parts(a, index: 0), pb = parts(b, index: 0)
        r.feed(pa[0], from: 1); r.feed(pb[0], from: 2)
        r.feed(pa[1], from: 1); r.feed(pb[1], from: 2)
        #expect(r.feed(pa[2], from: 1) == a)
        #expect(r.feed(pb[2], from: 2) == b)
    }

    @Test func interleavedIndicesFromOneSenderReassembleIndependently() {
        var r = MeshtasticReassembler()
        let a = ramp(500, seed: 7), b = ramp(500, seed: 8)
        let pa = parts(a, index: 0), pb = parts(b, index: 1)
        r.feed(pa[0]); r.feed(pb[0]); r.feed(pa[1]); r.feed(pb[1])
        #expect(r.feed(pa[2]) == a)
        #expect(r.feed(pb[2]) == b)
    }

    @Test func duplicateFragmentDoesNotDisturbReassembly() {
        var r = MeshtasticReassembler()
        let packet = ramp(500, seed: 9)
        let ps = parts(packet, index: 0)
        r.feed(ps[0]); r.feed(ps[0]); r.feed(ps[1])
        #expect(r.feed(ps[2]) == packet)
        #expect(r.counters.completed == 1)
    }

    /// x1, x2, then y1 conflicts at position 1 → the buffer restarts holding only y1, so x's last
    /// fragment cannot complete a y1+x2+x3 chimera.
    @Test func conflictingBodyRestartsTheBufferWithOnlyTheNewFragment() {
        var r = MeshtasticReassembler()
        let px = parts(ramp(500, seed: 10), index: 0), py = parts(ramp(500, seed: 11), index: 0)
        r.feed(px[0]); r.feed(px[1]); r.feed(py[0])
        #expect(r.feed(px[2]) == nil)
    }

    @Test func bufferIdleUnder30SecondsStillCompletes() {
        var r = MeshtasticReassembler()
        let packet = ramp(500, seed: 12)
        let ps = parts(packet, index: 0)
        r.feed(ps[0], at: t0); r.feed(ps[1], at: t0)
        #expect(r.feed(ps[2], at: t0.addingTimeInterval(29.9)) == packet)
    }

    @Test func bufferIdle30SecondsIsPurged() {
        var r = MeshtasticReassembler()
        let ps = parts(ramp(500, seed: 13), index: 0)
        r.feed(ps[0], at: t0)
        #expect(r.feed(ps[1], at: t0.addingTimeInterval(30)) == nil)
        #expect(r.counters.timedOut == 1)
        #expect(r.bufferCount == 1, "only the fragment that arrived after the purge remains")
    }

    @Test func ninthBufferFromOneSenderEvictsItsOldest() {
        var r = MeshtasticReassembler()
        let packets = (0..<9).map { ramp(500, seed: 20 + $0) }
        let ps = packets.enumerated().map { parts($0.element, index: UInt8($0.offset)) }
        for i in 0..<9 { r.feed(ps[i][0], at: t0.addingTimeInterval(Double(i))) }
        #expect(r.bufferCount == 8)
        #expect(r.counters.evicted == 1)
        let later = t0.addingTimeInterval(10)
        r.feed(ps[0][1], at: later)
        #expect(r.feed(ps[0][2], at: later) == nil, "index 0 was the oldest and must have been evicted")
        r.feed(ps[8][1], at: later)
        #expect(r.feed(ps[8][2], at: later) == packets[8])
    }

    @Test func sixtyFifthBufferEvictsTheOldestOverall() {
        var r = MeshtasticReassembler()
        let packets = (1...65).map { ramp(500, seed: $0) }
        let ps = packets.map { parts($0, index: 0) }
        for sender in 1...65 {
            r.feed(ps[sender - 1][0], from: UInt32(sender),
                   at: t0.addingTimeInterval(Double(sender) / 10))
        }
        #expect(r.bufferCount == 64)
        #expect(r.counters.evicted == 1)
        let later = t0.addingTimeInterval(10)
        r.feed(ps[0][1], from: 1, at: later)
        #expect(r.feed(ps[0][2], from: 1, at: later) == nil, "sender 1's buffer was the oldest and must have been evicted")
        r.feed(ps[64][1], from: 65, at: later)
        #expect(r.feed(ps[64][2], from: 65, at: later) == packets[64])
    }

    @Test func packetOf508BytesCompletes() {
        var r = MeshtasticReassembler()
        let packet = ramp(508, seed: 30)
        var out: Data?
        for p in parts(packet, index: 0) { out = r.feed(p) }
        #expect(out == packet)
    }

    @Test func packetOver508BytesIsDroppedAsOversize() {
        var r = MeshtasticReassembler()
        var out: Data?
        for p in parts(ramp(509, seed: 31), index: 0) { out = r.feed(p) }
        #expect(out == nil)
        #expect(r.counters.oversize == 1)
    }

    @Test func completedCountsEachReassembledPacket() {
        var r = MeshtasticReassembler()
        r.feed(parts(ramp(100, seed: 40), index: 0)[0])
        r.feed(parts(ramp(100, seed: 41), index: 1)[0])
        #expect(r.counters.completed == 2)
    }

    @Test func positionZeroIsMalformed() {
        var r = MeshtasticReassembler()
        #expect(r.receive(from: 1, index: 0, pos: 0, body: Data([1]), now: t0) == nil)
        #expect(r.counters.malformed == 1)
    }

    @Test func emptyBodyIsMalformed() {
        var r = MeshtasticReassembler()
        #expect(r.receive(from: 1, index: 0, pos: -1, body: Data(), now: t0) == nil)
        #expect(r.counters.malformed == 1)
    }

    @Test func resetDropsEveryBuffer() {
        var r = MeshtasticReassembler()
        r.feed(parts(ramp(500, seed: 50), index: 0)[0])
        r.reset()
        #expect(r.bufferCount == 0)
    }

    @Test func resetKeepsCounters() {
        var r = MeshtasticReassembler()
        r.recordMalformed()
        r.reset()
        #expect(r.counters.malformed == 1)
    }

    // Review Focus 1 — trap-class (step b′).
    @Test func int8MinPositionDoesNotTrap() {
        var r = MeshtasticReassembler()
        #expect(r.receive(from: 1, index: 0, pos: .min, body: Data([1]), now: t0) == nil)
        #expect(r.bufferCount == 1)
    }
}
