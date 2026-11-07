import Foundation
import Testing

@testable import ReTiCAInterfaces

private let t0 = Date(timeIntervalSince1970: 1000)

private func bytes(_ count: Int, seed: UInt8 = 0) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) })
}

private func sender(_ n: Int) -> Data {
    Data([0xAA, 0xBB, UInt8(n >> 8), UInt8(n & 0xFF)])
}

private func parts(
    _ packet: Data, packetID: UInt16 = 1, src: Data = sender(0)
) -> [MeshCoreDatagram] {
    let codec = ScotMeshRawCodec()
    let datagrams = codec.split(
        packet, type: .rnsFragment, src: src, dst: ScotMeshRawCodec.broadcast,
        packetID: packetID, canRoute: false)
    return datagrams.compactMap { codec.parse($0) }
}

extension MeshCoreReassembler {
    fileprivate mutating func feed(_ part: MeshCoreDatagram, at now: Date = t0) -> Data? {
        receive(
            src: part.src, packetID: part.packetID, index: part.fragmentIndex,
            total: part.fragmentTotal, body: part.body, now: now)
    }

    fileprivate mutating func feedAll(_ list: [MeshCoreDatagram], at now: Date = t0) -> [Data?] {
        list.map { feed($0, at: now) }
    }
}

@Suite struct MeshCoreReassemblerTests {
    @Test func inOrderFragmentsCompleteOnTheLast() {
        var sut = MeshCoreReassembler()
        let packet = bytes(500)
        let results = sut.feedAll(parts(packet))
        #expect(results == [nil, nil, nil, packet])
    }

    @Test func singleFragmentPacketCompletesAtOnce() {
        var sut = MeshCoreReassembler()
        let packet = bytes(20)
        #expect(sut.feedAll(parts(packet)) == [packet])
    }

    @Test func reversedFragmentsComplete() {
        var sut = MeshCoreReassembler()
        let packet = bytes(400)
        let results = sut.feedAll(parts(packet).reversed())
        #expect(results == [nil, nil, packet])
    }

    @Test func interleavedSendersReassembleIndependently() {
        var sut = MeshCoreReassembler()
        let a = bytes(300, seed: 1)
        let b = bytes(300, seed: 2)
        let pa = parts(a, src: sender(1))
        let pb = parts(b, src: sender(2))
        var out: [Data] = []
        for i in 0..<pa.count {
            if let r = sut.feed(pa[i]) { out.append(r) }
            if let r = sut.feed(pb[i]) { out.append(r) }
        }
        #expect(out == [a, b])
    }

    @Test func interleavedPacketIDsFromOneSenderReassembleIndependently() {
        var sut = MeshCoreReassembler()
        let a = bytes(300, seed: 1)
        let b = bytes(300, seed: 2)
        let pa = parts(a, packetID: 1)
        let pb = parts(b, packetID: 2)
        var out: [Data] = []
        for i in 0..<pa.count {
            if let r = sut.feed(pa[i]) { out.append(r) }
            if let r = sut.feed(pb[i]) { out.append(r) }
        }
        #expect(out == [a, b])
    }

    @Test func duplicateFragmentDoesNotDisturbReassembly() {
        var sut = MeshCoreReassembler()
        let packet = bytes(500)
        let p = parts(packet)
        for _ in 0..<4 { #expect(sut.feed(p[0]) == nil) }
        #expect(sut.feed(p[1]) == nil)
        #expect(sut.feed(p[2]) == nil)
        #expect(sut.feed(p[3]) == packet)
        #expect(sut.counters.completed == 1)
        #expect(sut.counters.oversize == 0)
    }

    @Test func conflictingBodyRestartsTheBufferWithOnlyThatFragment() {
        var sut = MeshCoreReassembler()
        let x = parts(bytes(500, seed: 1))
        let y = parts(bytes(500, seed: 2))
        #expect(sut.feed(x[0]) == nil)
        #expect(sut.feed(x[1]) == nil)
        #expect(sut.feed(y[0]) == nil)
        #expect(sut.feed(x[2]) == nil)
        #expect(sut.feed(x[3]) == nil)
        #expect(sut.bufferCount == 1)
    }

    @Test func conflictingTotalRestartsTheBufferWithOnlyThatFragment() {
        var sut = MeshCoreReassembler()
        let four = parts(bytes(500, seed: 1))
        let twoPacket = bytes(250, seed: 2)
        let two = parts(twoPacket)
        #expect(sut.feed(four[0]) == nil)
        #expect(sut.feed(two[1]) == nil)
        #expect(sut.feed(two[0]) == twoPacket)
    }

    @Test func bufferIdleUnder60SecondsStillCompletes() {
        var sut = MeshCoreReassembler()
        let packet = bytes(300)
        let p = parts(packet)
        _ = sut.feed(p[0])
        _ = sut.feed(p[1])
        #expect(sut.feed(p[2], at: t0.addingTimeInterval(59.9)) == packet)
    }

    @Test func bufferIdle60SecondsIsPurged() {
        var sut = MeshCoreReassembler()
        let p = parts(bytes(300))
        _ = sut.feed(p[0])
        _ = sut.feed(p[1])
        #expect(sut.feed(p[2], at: t0.addingTimeInterval(60)) == nil)
        #expect(sut.counters.timedOut == 1)
    }

    @Test func ninthBufferFromOneSenderEvictsItsOldest() {
        var sut = MeshCoreReassembler()
        let packets = (1...9).map { bytes(300, seed: UInt8($0)) }
        let all = packets.enumerated().map { parts($1, packetID: UInt16($0 + 1)) }
        for p in all { _ = sut.feed(p[0]) }
        #expect(sut.bufferCount == 8)
        #expect(sut.counters.evicted == 1)
        _ = sut.feed(all[8][1])
        #expect(sut.feed(all[8][2]) == packets[8])
        _ = sut.feed(all[0][1])
        #expect(sut.feed(all[0][2]) == nil)
    }

    @Test func sixtyFifthBufferEvictsTheOldestOverall() {
        var sut = MeshCoreReassembler()
        for n in 0...64 {
            _ = sut.feed(parts(bytes(300), src: sender(n))[0])
        }
        #expect(sut.bufferCount == 64)
        #expect(sut.counters.evicted == 1)
    }

    @Test func packetOf508BytesCompletes() {
        var sut = MeshCoreReassembler()
        let packet = bytes(508)
        #expect(sut.feedAll(parts(packet)).last == packet)
    }

    @Test func packetOver508BytesIsDroppedAsOversize() {
        var sut = MeshCoreReassembler()
        let results = sut.feedAll(parts(bytes(509)))
        #expect(results.last! == nil)
        #expect(sut.counters.oversize == 1)
        #expect(sut.bufferCount == 0)
    }

    @Test func emptyPacketIsDropped() {
        var sut = MeshCoreReassembler()
        let result = sut.receive(
            src: sender(0), packetID: 1, index: 0, total: 1, body: Data(), now: t0)
        #expect(result == nil)
        #expect(sut.counters.malformed == 1)
        #expect(sut.counters.completed == 0)
    }

    @Test func emptyFragmentInANonEmptyPacketIsAccepted() {
        var sut = MeshCoreReassembler()
        let tail = bytes(5)
        _ = sut.receive(src: sender(0), packetID: 1, index: 0, total: 2, body: Data(), now: t0)
        let result = sut.receive(
            src: sender(0), packetID: 1, index: 1, total: 2, body: tail, now: t0)
        #expect(result == tail)
        #expect(sut.counters.malformed == 0)
        #expect(sut.counters.completed == 1)
    }

    @Test func fragmentsOfAnyChunkSizeReassemble() {
        var sut = MeshCoreReassembler()
        let packet = bytes(500)
        let chunks = stride(from: 0, to: packet.count, by: 140).map {
            packet.subdata(in: $0..<min($0 + 140, packet.count))
        }
        var last: Data?
        for (i, chunk) in chunks.enumerated() {
            last = sut.receive(
                src: sender(0), packetID: 1, index: UInt8(i), total: UInt8(chunks.count),
                body: chunk, now: t0)
        }
        #expect(last == packet)
    }

    @Test func largestTotalDoesNotTrap() {
        var sut = MeshCoreReassembler()
        let result = sut.receive(
            src: sender(0), packetID: 1, index: 254, total: 255, body: bytes(10), now: t0)
        #expect(result == nil)
        #expect(sut.bufferCount == 1)
    }

    @Test func retransmitWithin30SecondsIsNotDeliveredTwice() {
        var sut = MeshCoreReassembler()
        let p = parts(bytes(300))
        _ = sut.feedAll(p)
        let again = sut.feedAll(p, at: t0.addingTimeInterval(29.9))
        #expect(again == [nil, nil, nil])
        #expect(sut.counters.completed == 1)
    }

    @Test func retransmitAt30SecondsDeliversAgain() {
        var sut = MeshCoreReassembler()
        let packet = bytes(300)
        let p = parts(packet)
        _ = sut.feedAll(p)
        let again = sut.feedAll(p, at: t0.addingTimeInterval(30))
        #expect(again.last == packet)
    }

    @Test func dedupeRemembersAtMost256Keys() {
        var sut = MeshCoreReassembler()
        let packets = (0..<257).map { parts(bytes(10, seed: UInt8($0 & 0xFF)), packetID: UInt16($0)) }
        for p in packets { _ = sut.feedAll(p) }
        #expect(sut.dedupeKeyCount == 256)
        #expect(sut.feedAll(packets[256]) == [nil])
        #expect(sut.feedAll(packets[0]).last! != nil)
    }

    @Test func backwardsClockExpiresADedupeKey() {
        var sut = MeshCoreReassembler()
        let packet = bytes(10)
        let p = parts(packet)
        _ = sut.feedAll(p)
        #expect(sut.feedAll(p, at: t0.addingTimeInterval(-100)) == [packet])
    }

    @Test func resetDropsEveryBuffer() {
        var sut = MeshCoreReassembler()
        _ = sut.feed(parts(bytes(300))[0])
        sut.reset()
        #expect(sut.bufferCount == 0)
    }

    @Test func resetKeepsCounters() {
        var sut = MeshCoreReassembler()
        sut.recordMalformed()
        sut.reset()
        #expect(sut.counters.malformed == 1)
    }

    @Test func resetKeepsDedupeKeys() {
        var sut = MeshCoreReassembler()
        let p = parts(bytes(300))
        _ = sut.feedAll(p)
        sut.reset()
        #expect(sut.feedAll(p) == [nil, nil, nil])
    }
}
