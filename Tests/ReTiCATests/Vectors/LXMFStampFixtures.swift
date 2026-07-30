import Foundation

struct LXMFStampFixtures: Decodable {
    let sourcePrivateKey: String
    let destinationHash: String
    let timestamp: Double
    let title: String
    let content: String
    let stampCost: Int
    let messageId: String
    let stamp: String
    let workblockHash: String
    let stampValue: Int
    let hash: String
    let signature: String
    let packed: String

    enum CodingKeys: String, CodingKey {
        case sourcePrivateKey = "source_private_key"
        case destinationHash = "destination_hash"
        case timestamp, title, content
        case stampCost = "stamp_cost"
        case messageId = "message_id"
        case stamp
        case workblockHash = "workblock_hash"
        case stampValue = "stamp_value"
        case hash, signature, packed
    }

    static func load() throws -> LXMFStampFixtures {
        let url = Bundle.module.url(forResource: "lxmf_stamp_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(LXMFStampFixtures.self, from: Data(contentsOf: url))
    }
}
