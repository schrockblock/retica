import Foundation

struct VectorFixtures: Decodable {
    let identityPrivateKey: String
    let identityPublicKey: String
    let identityHash: String
    let signMessage: String
    let signature: String
    let encryptPlaintext: String
    let encryptToken: String
    let tokenKey: String
    let tokenPlaintext: String
    let tokenCiphertext: String
    let plainAppName: String
    let plainAspect: String
    let plainDestHash: String
    let plainPacketPlaintext: String
    let plainPacketRaw: String
    let plainPacketHash: String
    let singleAppName: String
    let singleAspect: String
    let singleDestHash: String
    let announceAppName: String
    let announceAspect: String
    let announceDestHash: String
    let announcePayload: String
    let announceContextFlag: Bool
    let hdlcFramed: String
    let escapeInput: String
    let escapeFramed: String
    let linkDestIdentityPublic: String
    let linkInitEphPrivateKey: String
    let linkRespEphPublicKey: String
    let linkRequestRaw: String
    let linkID: String
    let linkDerivedKey: String
    let linkProof: String
    let linkPlaintext: String
    let linkCiphertext: String
    let linkRtt: Double
    let linkRttMsgpack: String
    let linkRttPacketCiphertext: String
    let linkCloseCiphertext: String
    let resourceData: String
    let resourceRandomHash: String
    let resourcePrefix: String
    let resourceTokenKey: String
    let resourceSdu: Int
    let resourceStream: String
    let resourceHash: String
    let resourceMapHash0: String
    let resourceProof: String
    let resourceAdvMsgpack: String
    let resourceRequestPlaintext: String
    let hmuMsgpack: String
    let hmuHashmap: String

    enum CodingKeys: String, CodingKey {
        case identityPrivateKey = "identity_private_key"
        case identityPublicKey = "identity_public_key"
        case identityHash = "identity_hash"
        case signMessage = "sign_message"
        case signature = "signature"
        case encryptPlaintext = "encrypt_plaintext"
        case encryptToken = "encrypt_token"
        case tokenKey = "token_key"
        case tokenPlaintext = "token_plaintext"
        case tokenCiphertext = "token_ciphertext"
        case plainAppName = "plain_app_name"
        case plainAspect = "plain_aspect"
        case plainDestHash = "plain_dest_hash"
        case plainPacketPlaintext = "plain_packet_plaintext"
        case plainPacketRaw = "plain_packet_raw"
        case plainPacketHash = "plain_packet_hash"
        case singleAppName = "single_app_name"
        case singleAspect = "single_aspect"
        case singleDestHash = "single_dest_hash"
        case announceAppName = "announce_app_name"
        case announceAspect = "announce_aspect"
        case announceDestHash = "announce_dest_hash"
        case announcePayload = "announce_payload"
        case announceContextFlag = "announce_context_flag"
        case hdlcFramed = "hdlc_framed"
        case escapeInput = "escape_input"
        case escapeFramed = "escape_framed"
        case linkDestIdentityPublic = "link_dest_identity_public"
        case linkInitEphPrivateKey = "link_init_eph_private_key"
        case linkRespEphPublicKey = "link_resp_eph_public_key"
        case linkRequestRaw = "link_request_raw"
        case linkID = "link_id"
        case linkDerivedKey = "link_derived_key"
        case linkProof = "link_proof"
        case linkPlaintext = "link_plaintext"
        case linkCiphertext = "link_ciphertext"
        case linkRtt = "link_rtt"
        case linkRttMsgpack = "link_rtt_msgpack"
        case linkRttPacketCiphertext = "link_rtt_packet_ciphertext"
        case linkCloseCiphertext = "link_close_ciphertext"
        case resourceData = "resource_data"
        case resourceRandomHash = "resource_random_hash"
        case resourcePrefix = "resource_prefix"
        case resourceTokenKey = "resource_token_key"
        case resourceSdu = "resource_sdu"
        case resourceStream = "resource_stream"
        case resourceHash = "resource_hash"
        case resourceMapHash0 = "resource_map_hash0"
        case resourceProof = "resource_proof"
        case resourceAdvMsgpack = "resource_adv_msgpack"
        case resourceRequestPlaintext = "resource_request_plaintext"
        case hmuMsgpack = "hmu_msgpack"
        case hmuHashmap = "hmu_hashmap"
    }

    static func load() throws -> VectorFixtures {
        let url = Bundle.module.url(forResource: "fixtures", withExtension: "json")!
        return try JSONDecoder().decode(VectorFixtures.self, from: Data(contentsOf: url))
    }
}
