import Foundation

struct LXMFPeeringFixtures: Decodable {
    let workblockExpandRoundsPeering: Int
    let workblockExpandRoundsPN: Int
    let peeringId: String
    let peeringCost: Int
    let peeringKey: String
    let peeringWorkblockHash: String
    let lxmfData: String
    let pnCost: Int
    let pnStamp: String
    let transientData: String
    let transientId: String
    let pnValue: Int
    let pnWorkblockHash: String

    enum CodingKeys: String, CodingKey {
        case workblockExpandRoundsPeering = "workblock_expand_rounds_peering"
        case workblockExpandRoundsPN = "workblock_expand_rounds_pn"
        case peeringId = "peering_id"
        case peeringCost = "peering_cost"
        case peeringKey = "peering_key"
        case peeringWorkblockHash = "peering_workblock_hash"
        case lxmfData = "lxmf_data"
        case pnCost = "pn_cost"
        case pnStamp = "pn_stamp"
        case transientData = "transient_data"
        case transientId = "transient_id"
        case pnValue = "pn_value"
        case pnWorkblockHash = "pn_workblock_hash"
    }

    static func load() throws -> LXMFPeeringFixtures {
        let url = Bundle.module.url(forResource: "lxmf_peering_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(LXMFPeeringFixtures.self, from: Data(contentsOf: url))
    }
}
