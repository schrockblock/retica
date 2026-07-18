import Testing
import Foundation
@testable import ReTiCA

@Test func swiftIdentityHashMatchesReference() throws {
    let f = try VectorFixtures.load()
    let id = Identity(publicKey: Data(hexString: f.identityPublicKey)!)!
    #expect(id.hexHash == f.identityHash)
    #expect(Data(hexString: f.identityPublicKey) == id.publicKey)
}

@Test func swiftValidatesReferenceSignature() throws {
    let f = try VectorFixtures.load()
    let id = Identity(publicKey: Data(hexString: f.identityPublicKey)!)!
    #expect(id.validate(signature: Data(hexString: f.signature)!,
                        message: Data(hexString: f.signMessage)!))
}

@Test func swiftDecryptsReferenceIdentityToken() throws {
    let f = try VectorFixtures.load()
    let id = Identity(privateKey: Data(hexString: f.identityPrivateKey)!)!
    let decrypted = id.decrypt(Data(hexString: f.encryptToken)!)
    #expect(decrypted == Data(hexString: f.encryptPlaintext))
}

@Test func swiftDecryptsReferenceToken() throws {
    let f = try VectorFixtures.load()
    let token = try Token(key: Data(hexString: f.tokenKey)!)
    let decrypted = try token.decrypt(Data(hexString: f.tokenCiphertext)!)
    #expect(decrypted == Data(hexString: f.tokenPlaintext))
}
