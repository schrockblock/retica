import Foundation

struct LXMFPropagationFixtures: Decodable {
    let sourcePrivateKey: String
    let recipientPrivateKey: String
    let destinationHash: String
    let title: String
    let content: String
    let containerTimestamp: Double
    let transientId: String
    let propagationPacked: String

    enum CodingKeys: String, CodingKey {
        case sourcePrivateKey = "source_private_key"
        case recipientPrivateKey = "recipient_private_key"
        case destinationHash = "destination_hash"
        case title, content
        case containerTimestamp = "container_timestamp"
        case transientId = "transient_id"
        case propagationPacked = "propagation_packed"
    }

    static func load() throws -> LXMFPropagationFixtures {
        let url = Bundle.module.url(forResource: "lxmf_propagation_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(LXMFPropagationFixtures.self, from: Data(contentsOf: url))
    }
}
