import Testing
import Foundation
@testable import ReTiCAInterfaces

private struct BLEFixtures: Decodable {
    struct FramingCase: Decodable { let packet: String; let framed: String }
    struct GreylistOp: Decodable { let op: String; let t: Double; let blocked: Bool? }
    let framing: [FramingCase]
    let framingStream: String
    let greylistOps: [GreylistOp]

    enum CodingKeys: String, CodingKey {
        case framing
        case framingStream = "framing_stream"
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

@Test func framingMatchesReferencePythonByteForByte() throws {
    let fixtures = try BLEFixtures.load()
    for c in fixtures.framing {
        #expect(try BLEFraming.frame(dataFromHex(c.packet)) == dataFromHex(c.framed))
    }
    // The concatenated reference stream deframes back to the reference packets.
    var buffer = BLEFrameBuffer()
    let packets = try buffer.append(dataFromHex(fixtures.framingStream))
    #expect(packets == fixtures.framing.map { dataFromHex($0.packet) })
}

@Test func greylistArithmeticMatchesReferencePython() throws {
    let fixtures = try BLEFixtures.load()
    var greylist = BLEPeerGreylist<String>()
    for op in fixtures.greylistOps {
        let now = Date(timeIntervalSince1970: op.t)
        switch op.op {
        case "fail":
            greylist.recordFailure("peer", now: now)
        case "probe":
            #expect(greylist.isBlocked("peer", now: now) == op.blocked!,
                    "probe at t=\(op.t) disagrees with reference")
        default:
            Issue.record("unknown op \(op.op)")
        }
    }
}
