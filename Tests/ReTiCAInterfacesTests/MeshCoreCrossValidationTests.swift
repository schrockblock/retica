import Foundation
import Testing

@testable import ReTiCAInterfaces

/// Writes Vectors/meshcore_our_split.json for generate_meshcore_fixtures.py. Disabled unless
/// RETICA_EMIT_MESHCORE_SPLIT=1, so an ordinary `swift test` never rewrites a committed file.
@Suite struct MeshCoreOurSplitEmitter {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RETICA_EMIT_MESHCORE_SPLIT"] == "1"))
    func writeOurSplitForTheReferenceGenerator() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Vectors/meshcore_our_split.json")
        try MeshCoreOurSplitFile.current().encoded().write(to: url, options: .atomic)
    }
}

private let codec = ScotMeshRawCodec()
private let src = MeshCoreOurSplitFile.src
private let packetID = MeshCoreOurSplitFile.packetID
private let epoch = Date(timeIntervalSince1970: 1000)

private func hexes(_ values: [String]) -> [Data] {
    values.map(meshCoreData(hex:))
}

/// Feeds each frame through OUR parse and a fresh reassembler. nil for a frame that doesn't
/// complete a packet or doesn't parse.
private func reassemble(_ frames: [Data]) -> [Data?] {
    var reassembler = MeshCoreReassembler()
    return frames.map { frame in
        guard let datagram = codec.parse(frame) else { return nil }
        return reassembler.receive(
            src: datagram.src, packetID: datagram.packetID, index: datagram.fragmentIndex,
            total: datagram.fragmentTotal, body: datagram.body, now: epoch)
    }
}

@Suite struct MeshCoreCrossValidationTests {
    @Test func ourSplitMatchesTheReferenceByteForByte() throws {
        let rows = try MeshCoreFixtures.load().theirSplit.filter { $0.chunk == 148 }
        #expect(rows.count == 14)  // 7 lengths x can-route off and on
        for row in rows {
            let got = codec.split(
                meshCoreData(hex: row.packet), type: .rnsFragment, src: src,
                dst: ScotMeshRawCodec.broadcast, packetID: packetID, canRoute: row.canRoute)
            #expect(got == hexes(row.fragments), "length \(row.length) canRoute \(row.canRoute)")
        }
    }

    @Test func ourParseReadsEveryReferenceFragment() throws {
        let rows = try MeshCoreFixtures.load().theirSplit
        #expect(rows.count == 15)  // the 14 above plus 500 B at chunk 140
        for row in rows {
            let packet = meshCoreData(hex: row.packet)
            let fragments = hexes(row.fragments)
            for (index, fragment) in fragments.enumerated() {
                let start = index * row.chunk
                let expected = MeshCoreDatagram(
                    type: .rnsFragment, canRoute: row.canRoute, src: src,
                    dst: ScotMeshRawCodec.broadcast, packetID: packetID,
                    fragmentIndex: UInt8(index), fragmentTotal: UInt8(fragments.count),
                    body: packet.subdata(in: start..<min(start + row.chunk, packet.count)))
                #expect(codec.parse(fragment) == expected, "length \(row.length) fragment \(index)")
            }
        }
    }

    @Test func ourReassemblerRebuildsReferenceFragments() throws {
        for row in try MeshCoreFixtures.load().theirSplit {
            let results = reassemble(hexes(row.fragments))
            #expect(results.dropLast().allSatisfy { $0 == nil }, "length \(row.length) completed early")
            #expect(results.last == meshCoreData(hex: row.packet), "length \(row.length) chunk \(row.chunk)")
        }
    }

    @Test func ourCodecFramesBindLikeTheReference() throws {
        let rows = try MeshCoreFixtures.load().theirBind
        #expect(rows.count == 4)  // BIND_REQ and BIND, can-route off and on
        for row in rows {
            let type: MeshCoreFrameType = row.type == "BIND" ? .bind : .bindRequest
            let got = codec.split(
                meshCoreData(hex: row.key), type: type, src: src, dst: ScotMeshRawCodec.broadcast,
                packetID: packetID, canRoute: row.canRoute)
            #expect(got == [meshCoreData(hex: row.frame)], "\(row.type) canRoute \(row.canRoute)")
        }
    }

    @Test func ourParseRejectsWhatTheReferenceRejects() throws {
        let rows = try MeshCoreFixtures.load().theirRejects
        #expect(rows.count == 7)
        for row in rows {
            #expect(codec.parse(meshCoreData(hex: row.frame)) == nil, "\(row.name)")
        }
    }

    @Test func committedSplitIsWhatOurCodecEmitsToday() throws {
        #expect(
            try MeshCoreOurSplitFile.load() == MeshCoreOurSplitFile.current(),
            "regenerate: emitter, then generator")
    }

    @Test func referenceParsesOurSplitBackToThePacket() throws {
        let committed = try MeshCoreOurSplitFile.load()
        let rows = try MeshCoreFixtures.load().ourSplitParsed
        #expect(rows.map(\.packet) == committed.cases.map(\.packet))
        #expect(rows.count == 14)
        for row in rows {
            let packet = meshCoreData(hex: row.packet)
            // Our codec's split, made now, is exactly what the reference parsed.
            let ours = codec.split(
                packet, type: .rnsFragment, src: src, dst: ScotMeshRawCodec.broadcast,
                packetID: packetID, canRoute: row.canRoute)
            #expect(ours == hexes(row.fragments), "length \(packet.count) canRoute \(row.canRoute)")
            #expect(row.reassembled == row.packet, "length \(packet.count)")
            #expect(row.parsed.count == ours.count)
            for (index, parsed) in row.parsed.enumerated() {
                #expect(parsed.type == 0)
                #expect(parsed.canRoute == row.canRoute)
                #expect(parsed.src == src.meshCoreHex)
                #expect(parsed.dst == ScotMeshRawCodec.broadcast.meshCoreHex)
                #expect(parsed.pktId == Int(packetID))
                #expect(parsed.idx == index)
                #expect(parsed.total == ours.count)
                #expect(
                    parsed.payload == ours[index].dropFirst(ScotMeshRawCodec.headerSize).meshCoreHex,
                    "length \(packet.count) fragment \(index)")
            }
        }
    }

    @Test func referenceDeliversOurSplitInAnyOrder() throws {
        let rows = try MeshCoreFixtures.load().ourSplitDelivered
        #expect(rows.count == 42)  // 14 cases x in order, reversed, first repeated
        #expect(Set(rows.map(\.order)) == ["inOrder", "reversed", "firstRepeated"])
        for row in rows {
            #expect(row.delivered == [row.packet], "\(row.order) length \(row.packet.count / 2)")
            let results = reassemble(hexes(row.fragments))
            #expect(
                results.compactMap { $0 } == [meshCoreData(hex: row.packet)],
                "ours: \(row.order) length \(row.packet.count / 2)")
        }
    }

    @Test func referenceAcceptsOurBind() throws {
        let row = try MeshCoreFixtures.load().ourBindAccepted
        #expect(row.frame == MeshCoreOurSplitFile.current().bind)
        #expect(row.accepted)
    }

    @Test func retransmitIsDeliveredOnceHereAsInTheReference() throws {
        let row = try MeshCoreFixtures.load().retransmit
        #expect(row.fragments.count == 4)  // 2 fragments, sent twice
        #expect(row.delivered.count == 1)
        let ours = reassemble(hexes(row.fragments)).compactMap { $0 }
        #expect(ours == [meshCoreData(hex: row.packet)])
    }

    /// Spec §5.6 deviation, pinned against the reference: fed x0, x1, y0, x2, x3 the reference
    /// ignores y0 (index 0 is taken) and completes the first packet; we treat the changed body as a
    /// new packet, restart the buffer with y0 alone and complete nothing.
    @Test func conflictingFragmentDeliversDifferentlyFromTheReferenceByDesign() throws {
        let row = try MeshCoreFixtures.load().conflict
        #expect(row.fragments.count == 5)
        #expect(row.delivered == [row.first])
        #expect(row.deliveredAfterStep == 4)
        let results = reassemble(hexes(row.fragments))
        #expect(results[row.deliveredAfterStep] == nil)
        #expect(results.allSatisfy { $0 == nil })
    }

    @Test func hopCapMatchesTheReference() throws {
        let rows = try MeshCoreFixtures.load().hopCap
        #expect(rows.count == 8)  // hops 2 and 3, with and without PATH_RESPONSE, HEADER_1 and HEADER_2
        #expect(rows.filter(\.exceeds).count == 2)
        for row in rows {
            var limiter = MeshCoreAnnounceLimiter()
            let admitted = limiter.admit(unmasked: meshCoreData(hex: row.data), now: epoch)
            #expect(
                admitted == !row.exceeds,
                "hops \(row.hops) pathResponse \(row.pathResponse) header2 \(row.header2)")
        }
    }
}
