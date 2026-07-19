import Foundation

struct TransportVectorFixtures: Decodable {
    let announceDestHash: String
    let announceIdentityHash: String
    let announceAppData: String
    let announceHops: Int
    let announcePacket: String

    enum CodingKeys: String, CodingKey {
        case announceDestHash = "announce_dest_hash"
        case announceIdentityHash = "announce_identity_hash"
        case announceAppData = "announce_app_data"
        case announceHops = "announce_hops"
        case announcePacket = "announce_packet"
    }

    static func load() throws -> TransportVectorFixtures {
        let url = Bundle.module.url(forResource: "transport_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(TransportVectorFixtures.self, from: Data(contentsOf: url))
    }
}
