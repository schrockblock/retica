import Foundation

@testable import ReTiCAInterfaces

func meshCoreData(hex: String) -> Data {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return data
}

extension Data {
    var meshCoreHex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Byte i = (7i + seed) mod 256, identical to `pattern` in generate_meshcore_fixtures.py.
func meshCorePattern(_ count: Int, seed: Int) -> Data {
    Data((0..<count).map { UInt8((($0 * 7) + seed) % 256) })
}

struct MeshCoreFixtureMissing: Error { let name: String }

/// The reference's outputs (generate_meshcore_fixtures.py writes meshcore_fixtures.json).
struct MeshCoreFixtures: Decodable {
    struct Split: Decodable {
        let length: Int
        let canRoute: Bool
        let chunk: Int
        let packet: String
        let fragments: [String]
    }
    struct Bind: Decodable {
        let type: String
        let canRoute: Bool
        let key: String
        let frame: String
    }
    struct Reject: Decodable {
        let name: String
        let frame: String
    }
    struct ParsedFragment: Decodable {
        let type: Int
        let canRoute: Bool
        let src: String
        let dst: String
        let pktId: Int
        let idx: Int
        let total: Int
        let payload: String
    }
    struct OurSplitParsed: Decodable {
        let packet: String
        let canRoute: Bool
        let fragments: [String]
        let parsed: [ParsedFragment]
        let reassembled: String
    }
    struct Delivered: Decodable {
        let packet: String
        let order: String
        let fragments: [String]
        let delivered: [String]
    }
    struct Retransmit: Decodable {
        let packet: String
        let fragments: [String]
        let delivered: [String]
    }
    struct Conflict: Decodable {
        let first: String
        let second: String
        let fragments: [String]
        let delivered: [String]
        let deliveredAfterStep: Int
    }
    struct BindAccepted: Decodable {
        let frame: String
        let accepted: Bool
    }
    struct HopCap: Decodable {
        let data: String
        let hops: Int
        let pathResponse: Bool
        let header2: Bool
        let exceeds: Bool
    }

    let theirSplit: [Split]
    let theirBind: [Bind]
    let theirRejects: [Reject]
    let ourSplitParsed: [OurSplitParsed]
    let ourSplitDelivered: [Delivered]
    let retransmit: Retransmit
    let conflict: Conflict
    let ourBindAccepted: BindAccepted
    let hopCap: [HopCap]

    static func load() throws -> MeshCoreFixtures {
        guard let url = Bundle.module.url(forResource: "meshcore_fixtures", withExtension: "json")
        else { throw MeshCoreFixtureMissing(name: "meshcore_fixtures.json") }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(MeshCoreFixtures.self, from: Data(contentsOf: url))
    }
}

/// OUR codec's split of a fixed packet set. Written by `MeshCoreOurSplitEmitter`, read by the
/// generator (which feeds it to the reference), and pinned to the current codec by
/// `committedSplitIsWhatOurCodecEmitsToday`.
struct MeshCoreOurSplitFile: Codable, Equatable {
    struct Case: Codable, Equatable {
        let length: Int
        let canRoute: Bool
        let packet: String
        let fragments: [String]
    }
    let cases: [Case]
    /// Our `BIND` for `bindKey`, whose first four bytes are `src`.
    let bind: String

    static let lengths = [1, 147, 148, 149, 296, 500, 508]
    static let src = Data([0x01, 0x02, 0x03, 0x04])
    static let packetID: UInt16 = 0xBEEF
    static let bindKey = src + meshCorePattern(28, seed: 9)

    static func current() -> MeshCoreOurSplitFile {
        let codec = ScotMeshRawCodec()
        let cases = [false, true].flatMap { canRoute in
            lengths.map { length in
                let packet = meshCorePattern(length, seed: 5)
                let fragments = codec.split(
                    packet, type: .rnsFragment, src: src, dst: ScotMeshRawCodec.broadcast,
                    packetID: packetID, canRoute: canRoute)
                return Case(
                    length: length, canRoute: canRoute, packet: packet.meshCoreHex,
                    fragments: fragments.map(\.meshCoreHex))
            }
        }
        let bind = codec.split(
            bindKey, type: .bind, src: src, dst: ScotMeshRawCodec.broadcast,
            packetID: packetID, canRoute: true)
        return MeshCoreOurSplitFile(cases: cases, bind: bind[0].meshCoreHex)
    }

    static func load() throws -> MeshCoreOurSplitFile {
        guard let url = Bundle.module.url(forResource: "meshcore_our_split", withExtension: "json")
        else { throw MeshCoreFixtureMissing(name: "meshcore_our_split.json") }
        return try JSONDecoder().decode(MeshCoreOurSplitFile.self, from: Data(contentsOf: url))
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
