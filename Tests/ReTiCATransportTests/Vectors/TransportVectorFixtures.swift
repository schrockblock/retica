import Foundation

struct TransportVectorFixtures: Decodable {
    let announceDestHash: String
    let announceIdentityHash: String
    let announceAppData: String
    let announceHops: Int
    let announcePacket: String
    let bz2Original: String
    let bz2Compressed: String
    let bz2OriginalLen: Int
    // Multi-segment resource cross-validation fields
    let msMaxEfficientSize: Int
    let msTotalSize: Int
    let msSeg1Adv: String
    let msSeg2Adv: String
    let msSeg1I: Int
    let msSeg1L: Int
    let msSeg1O: String
    let msSeg1D: Int
    let msSeg1F: Int
    let msSeg2I: Int
    let msSeg2O: String
    let msSeg2F: Int
    let rbAnnounce1: String
    let rbBlob1: String
    let rbAnnounce2: String
    let rbBlob2: String
    let pathfinderRw: Double
    let localRebroadcastsMax: Int
    let pathfinderG: Double
    let destinationTimeout: Double
    let linkTimeout: Double
    let prControlHash: String
    let prRequestedDest: String
    let prRequestPayload: String
    let prTag: String
    let prRecursiveRelayHash: String
    let prRecursivePayload: String
    let prRespRelayHash: String
    let prRespPayload: String
    let prRespHops: Int
    let prRespPacket: String

    enum CodingKeys: String, CodingKey {
        case announceDestHash = "announce_dest_hash"
        case announceIdentityHash = "announce_identity_hash"
        case announceAppData = "announce_app_data"
        case announceHops = "announce_hops"
        case announcePacket = "announce_packet"
        case bz2Original = "bz2_original"
        case bz2Compressed = "bz2_compressed"
        case bz2OriginalLen = "bz2_original_len"
        case msMaxEfficientSize = "ms_max_efficient_size"
        case msTotalSize = "ms_total_size"
        case msSeg1Adv = "ms_seg1_adv"
        case msSeg2Adv = "ms_seg2_adv"
        case msSeg1I = "ms_seg1_i"
        case msSeg1L = "ms_seg1_l"
        case msSeg1O = "ms_seg1_o"
        case msSeg1D = "ms_seg1_d"
        case msSeg1F = "ms_seg1_f"
        case msSeg2I = "ms_seg2_i"
        case msSeg2O = "ms_seg2_o"
        case msSeg2F = "ms_seg2_f"
        case rbAnnounce1 = "rb_announce1"
        case rbBlob1 = "rb_blob1"
        case rbAnnounce2 = "rb_announce2"
        case rbBlob2 = "rb_blob2"
        case pathfinderRw = "pathfinder_rw"
        case localRebroadcastsMax = "local_rebroadcasts_max"
        case pathfinderG = "pathfinder_g"
        case destinationTimeout = "destination_timeout"
        case linkTimeout = "link_timeout"
        case prControlHash = "pr_control_hash"
        case prRequestedDest = "pr_requested_dest"
        case prRequestPayload = "pr_request_payload"
        case prTag = "pr_tag"
        case prRecursiveRelayHash = "pr_recursive_relay_hash"
        case prRecursivePayload = "pr_recursive_payload"
        case prRespRelayHash = "pr_resp_relay_hash"
        case prRespPayload = "pr_resp_payload"
        case prRespHops = "pr_resp_hops"
        case prRespPacket = "pr_resp_packet"
    }

    static func load() throws -> TransportVectorFixtures {
        let url = Bundle.module.url(forResource: "transport_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(TransportVectorFixtures.self, from: Data(contentsOf: url))
    }
}
