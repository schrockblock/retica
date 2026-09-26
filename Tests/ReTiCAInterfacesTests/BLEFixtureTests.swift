import Testing
import Foundation
@testable import ReTiCAInterfaces

private struct BLEFixtures: Decodable {
    struct FragCase: Decodable { let mtu: Int; let packet: String; let fragments: [String] }
    struct Reassembly: Decodable { let mtu: Int; let fragments: [String]; let packet: String }
    struct Conflict: Decodable { let fragments: [String]; let `throws`: Bool }
    struct GreylistOp: Decodable { let op: String; let t: Double; let blocked: Bool? }
    let fragmentation: [FragCase]
    let reassembly: Reassembly
    let reassemblyConflict: Conflict
    let greylistOps: [GreylistOp]

    enum CodingKeys: String, CodingKey {
        case fragmentation, reassembly
        case reassemblyConflict = "reassembly_conflict"
        case greylistOps = "greylist_ops"
    }

    static func load() throws -> BLEFixtures {
        let url = Bundle.module.url(forResource: "ble_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(BLEFixtures.self, from: Data(contentsOf: url))
    }
}

private func dataFromHex(_ hex: String) -> Data {
    var data = Data(); var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return data
}

@Test func fragmentationMatchesReferencePythonByteForByte() throws {
    let fixtures = try BLEFixtures.load()
    #expect(fixtures.fragmentation.count == 24)   // 4 MTUs × 6 packets
    for c in fixtures.fragmentation {
        let got = try BLEFragmenter(mtu: c.mtu).fragment(dataFromHex(c.packet))
        #expect(got == c.fragments.map(dataFromHex), "mtu \(c.mtu) packet \(c.packet.count / 2) B")
        // And our reassembler re-ingests the reference fragments to the reference packet.
        var r = BLEReassembler()
        var out: Data?
        for f in c.fragments { out = try r.receive(dataFromHex(f), now: Date()) }
        #expect(out == dataFromHex(c.packet))
    }
}

@Test func reassemblyMatchesReferenceOnShuffledDeliveryWithDuplicate() throws {
    let fixtures = try BLEFixtures.load()
    var r = BLEReassembler()
    let frags = fixtures.reassembly.fragments.map(dataFromHex)
    for (i, f) in frags.enumerated() {
        let got = try r.receive(f, now: Date())
        if i < frags.count - 1 { #expect(got == nil, "completed early at \(i)") }
        else { #expect(got == dataFromHex(fixtures.reassembly.packet)) }
    }
}

@Test func conflictingDuplicateThrowsLikeTheReference() throws {
    let fixtures = try BLEFixtures.load()
    let frags = fixtures.reassemblyConflict.fragments.map(dataFromHex)
    var r = BLEReassembler()
    _ = try r.receive(frags[0], now: Date())
    _ = try r.receive(frags[1], now: Date())
    #expect(throws: BLEReassemblyError.self) { _ = try r.receive(frags[2], now: Date()) }
}

@Test func greylistArithmeticMatchesReferencePython() throws {
    let fixtures = try BLEFixtures.load()
    var greylist = BLEPeerGreylist<String>()
    for op in fixtures.greylistOps {
        let now = Date(timeIntervalSince1970: op.t)
        switch op.op {
        case "fail":  greylist.recordFailure("peer", now: now)
        case "probe": #expect(greylist.isBlocked("peer", now: now) == op.blocked!, "probe at t=\(op.t)")
        default:      Issue.record("unknown op \(op.op)")
        }
    }
}
