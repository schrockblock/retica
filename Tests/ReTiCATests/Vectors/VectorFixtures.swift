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
    }

    static func load() throws -> VectorFixtures {
        let url = Bundle.module.url(forResource: "fixtures", withExtension: "json")!
        return try JSONDecoder().decode(VectorFixtures.self, from: Data(contentsOf: url))
    }
}
