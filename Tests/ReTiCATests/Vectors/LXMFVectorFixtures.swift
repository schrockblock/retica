import Foundation

struct LXMFVectorFixtures: Decodable {
    let sourcePrivateKey: String
    let destinationHash: String
    let sourceHash: String
    let timestamp: Double
    let title: String
    let content: String
    let hash: String
    let signature: String
    let packed: String
    let linkMdu: Int
    let encryptedPacketMdu: Int

    enum CodingKeys: String, CodingKey {
        case sourcePrivateKey = "source_private_key"
        case destinationHash = "destination_hash"
        case sourceHash = "source_hash"
        case timestamp
        case title, content, hash, signature, packed
        case linkMdu = "link_mdu"
        case encryptedPacketMdu = "encrypted_packet_mdu"
    }

    static func load() throws -> LXMFVectorFixtures {
        let url = Bundle.module.url(forResource: "lxmf_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(LXMFVectorFixtures.self, from: Data(contentsOf: url))
    }
}
