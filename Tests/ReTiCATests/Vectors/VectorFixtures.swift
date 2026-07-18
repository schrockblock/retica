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
    }

    static func load() throws -> VectorFixtures {
        let url = Bundle.module.url(forResource: "fixtures", withExtension: "json")!
        return try JSONDecoder().decode(VectorFixtures.self, from: Data(contentsOf: url))
    }
}
