import Testing
import Foundation
@testable import ReTiCAInterfaces

/// Writes Vectors/meshtastic_our_split.json for generate_meshtastic_fixtures.py. Disabled unless
/// RETICA_EMIT_MESHTASTIC_SPLIT=1, so an ordinary `swift test` never rewrites a committed file.
@Suite struct MeshtasticOurSplitEmitter {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RETICA_EMIT_MESHTASTIC_SPLIT"] == "1"))
    func writeOurSplitForTheReferenceGenerator() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Vectors/meshtastic_our_split.json")
        try MeshtasticOurSplitFile.current().encoded().write(to: url, options: .atomic)
    }
}

private func reassemble(_ frames: [Data], from sender: UInt32 = 1) -> [Data?] {
    let codec = LandandairCodec()
    var reassembler = MeshtasticReassembler()
    var results: [Data?] = []
    for frame in frames {
        guard case let .data(index, pos, body)? = codec.parse(frame) else {
            results.append(nil)
            continue
        }
        results.append(reassembler.receive(from: sender, index: index, pos: pos, body: body,
                                           now: Date(timeIntervalSince1970: 0)))
    }
    return results
}

@Suite struct MeshtasticCrossValidationTests {
    @Test func ourSplitMatchesTheReferenceSplitByteForByte() throws {
        let fixtures = try MeshtasticFixtures.load()
        #expect(fixtures.theirSplit.count == 54)   // 9 lengths × 6 indices
        for c in fixtures.theirSplit {
            let got = LandandairCodec().split(meshData(hex: c.packet), index: UInt8(c.index))
            #expect(got == c.fragments.map(meshData(hex:)), "length \(c.length) index \(c.index)")
        }
    }

    @Test func ourReassemblerRebuildsReferenceFragments() throws {
        let fixtures = try MeshtasticFixtures.load()
        for c in fixtures.theirSplit {
            let results = reassemble(c.fragments.map(meshData(hex:)))
            #expect(results.dropLast().allSatisfy { $0 == nil }, "length \(c.length) completed early")
            #expect(results.last == meshData(hex: c.packet), "length \(c.length) index \(c.index)")
        }
    }

    /// Our split, run through the reference's receive path by the generator, came back intact —
    /// and the committed split file is what our codec emits TODAY (a codec change without
    /// regenerating fails here).
    @Test func referenceReassemblesWhatOurCodecEmitsToday() throws {
        let committed = try MeshtasticOurSplitFile.load()
        #expect(committed == MeshtasticOurSplitFile.current(), "regenerate: emitter, then generator")
        let fixtures = try MeshtasticFixtures.load()
        #expect(fixtures.ourSplitReassembled.map(\.packet) == committed.cases.map(\.packet))
        #expect(fixtures.ourSplitReassembled.count == 18)
        for c in fixtures.ourSplitReassembled { #expect(c.reassembled == c.packet, "index \(c.index)") }
    }

    @Test func referenceRequestFramesParseAsRequests() throws {
        let fixtures = try MeshtasticFixtures.load()
        #expect(fixtures.requests.count == 2)
        for r in fixtures.requests {
            #expect(LandandairCodec().parse(meshData(hex: r.frame)) == .request(index: UInt8(r.index), pos: Int8(r.pos)))
        }
    }

    /// Spec §5.2 deviation, pinned against the reference: the reference completes (2, 1, −3) but
    /// NOT (−3, 1, 2); we complete both.
    @Test func lateMiddleFragmentCompletesWhereTheReferenceDoesNot() throws {
        let fixtures = try MeshtasticFixtures.load()
        #expect(fixtures.reorder.map(\.referenceCompletes) == [true, false])
        for c in fixtures.reorder {
            #expect(reassemble(c.fragments.map(meshData(hex:))).last == meshData(hex: c.packet))
        }
    }
}
