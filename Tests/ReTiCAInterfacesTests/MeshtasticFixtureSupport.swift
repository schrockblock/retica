import Foundation
@testable import ReTiCAInterfaces

func meshData(hex: String) -> Data {
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
    var meshHex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Byte i = (7i + seed) mod 256 — identical to `pattern` in generate_meshtastic_fixtures.py.
func meshPattern(_ count: Int, seed: Int) -> Data {
    Data((0..<count).map { UInt8((($0 * 7) + seed) % 256) })
}

struct MeshFixtureMissing: Error { let name: String }

/// The reference's outputs (generate_meshtastic_fixtures.py → meshtastic_fixtures.json).
struct MeshtasticFixtures: Decodable {
    struct Split: Decodable { let length: Int; let index: Int; let packet: String; let fragments: [String] }
    struct Reassembled: Decodable { let index: Int; let packet: String; let reassembled: String }
    struct Outgoing: Decodable { let packets: [String]; let frames: [String] }
    struct Request: Decodable { let frame: String; let index: Int; let pos: Int }
    struct RequestAnswer: Decodable { let request: String; let answer: String }
    struct Reorder: Decodable { let packet: String; let fragments: [String]; let referenceCompletes: Bool }

    let theirSplit: [Split]
    let ourSplitReassembled: [Reassembled]
    let outgoing: Outgoing
    let requests: [Request]
    let requestAnswers: [RequestAnswer]
    let reorder: [Reorder]

    static func load() throws -> MeshtasticFixtures {
        guard let url = Bundle.module.url(forResource: "meshtastic_fixtures", withExtension: "json") else {
            throw MeshFixtureMissing(name: "meshtastic_fixtures.json")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(MeshtasticFixtures.self, from: Data(contentsOf: url))
    }
}

/// OUR codec's split of a fixed packet set. Written by `MeshtasticOurSplitEmitter`, read by the
/// generator (which feeds it to the reference), and pinned to the current codec by
/// `referenceReassemblesWhatOurCodecEmitsToday`.
struct MeshtasticOurSplitFile: Codable, Equatable {
    struct Case: Codable, Equatable { let index: Int; let packet: String; let fragments: [String] }
    let cases: [Case]

    static let lengths = [1, 2, 3, 199, 200, 201, 400, 500, 508]
    static let indices = [0, 255]

    static func current() -> MeshtasticOurSplitFile {
        let codec = LandandairCodec()
        return MeshtasticOurSplitFile(cases: lengths.flatMap { length in
            indices.map { index in
                let packet = meshPattern(length, seed: 5)
                return Case(index: index, packet: packet.meshHex,
                            fragments: codec.split(packet, index: UInt8(index)).map(\.meshHex))
            }
        })
    }

    static func load() throws -> MeshtasticOurSplitFile {
        guard let url = Bundle.module.url(forResource: "meshtastic_our_split", withExtension: "json") else {
            throw MeshFixtureMissing(name: "meshtastic_our_split.json")
        }
        return try JSONDecoder().decode(MeshtasticOurSplitFile.self, from: Data(contentsOf: url))
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
