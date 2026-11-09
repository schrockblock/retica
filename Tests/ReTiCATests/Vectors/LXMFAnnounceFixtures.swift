import Foundation

struct LXMFAnnounceFixture: Decodable {
    let displayName: String?
    let stampCost: Double?
    let supportsCompression: Bool
    let packed: String

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case stampCost = "stamp_cost"
        case supportsCompression = "supports_compression"
        case packed
    }
}

struct LXMFAnnounceFixtures: Decodable {
    let nameCost: LXMFAnnounceFixture
    let bothNil: LXMFAnnounceFixture
    let nameOnly: LXMFAnnounceFixture
    let costOnly: LXMFAnnounceFixture
    let legacy: LXMFAnnounceFixture

    enum CodingKeys: String, CodingKey {
        case nameCost = "name_cost"
        case bothNil = "both_nil"
        case nameOnly = "name_only"
        case costOnly = "cost_only"
        case legacy
    }

    static func load() throws -> LXMFAnnounceFixtures {
        let url = Bundle.module.url(forResource: "lxmf_announce_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(LXMFAnnounceFixtures.self, from: Data(contentsOf: url))
    }
}
