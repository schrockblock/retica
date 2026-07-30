import Foundation

struct LXMFRichFixtures: Decodable {
    let sourcePrivateKey: String
    let destinationHash: String
    let timestamp: Double
    let title: String
    let content: String
    let fieldTicket: String
    let fieldRenderer: Int
    let hash: String
    let signature: String
    let packed: String

    enum CodingKeys: String, CodingKey {
        case sourcePrivateKey = "source_private_key"
        case destinationHash = "destination_hash"
        case timestamp, title, content
        case fieldTicket = "field_ticket"
        case fieldRenderer = "field_renderer"
        case hash, signature, packed
    }

    static func load() throws -> LXMFRichFixtures {
        let url = Bundle.module.url(forResource: "lxmf_rich_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(LXMFRichFixtures.self, from: Data(contentsOf: url))
    }
}
