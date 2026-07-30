import Foundation

struct LXMFPNAnnounceFixtures: Decodable {
    let timebase: Int
    let nodeState: Bool
    let perTransferLimit: Int
    let perSyncLimit: Int
    let targetStampCost: Int
    let stampCostFlexibility: Int
    let peeringCost: Int
    let packed: String
    let invalidPacked: String

    enum CodingKeys: String, CodingKey {
        case timebase
        case nodeState = "node_state"
        case perTransferLimit = "per_transfer_limit"
        case perSyncLimit = "per_sync_limit"
        case targetStampCost = "target_stamp_cost"
        case stampCostFlexibility = "stamp_cost_flexibility"
        case peeringCost = "peering_cost"
        case packed
        case invalidPacked = "invalid_packed"
    }

    static func load() throws -> LXMFPNAnnounceFixtures {
        let url = Bundle.module.url(forResource: "lxmf_pn_announce_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(LXMFPNAnnounceFixtures.self, from: Data(contentsOf: url))
    }
}
