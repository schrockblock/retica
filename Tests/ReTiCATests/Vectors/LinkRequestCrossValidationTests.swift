import Testing
import Foundation
@testable import ReTiCA

@Test func swiftVerifiesGenuineRnsIdentifyPayload() throws {
    let f = try VectorFixtures.load()
    let payload = Data(hexString: f.identifyPayload)!
    let linkID = Data(hexString: f.identifyLinkId)!
    // Our identity from the same private seed reproduces the public key deterministically.
    let identity = Identity(privateKey: Data(hexString: f.identifyPrv)!)!
    #expect(identity.publicKey == Data(hexString: f.identifyPub)!)
    #expect(Data(payload.prefix(64)) == identity.publicKey)          // pubkey half is byte-exact
    // Our verifier accepts RNS's Ed25519 signature over linkID ‖ publicKey (interop, no determinism assumption).
    let signature = Data(payload.suffix(64))
    #expect(identity.validate(signature: signature, message: linkID + identity.publicKey))
}

@Test func swiftPathHashMatchesRns() throws {
    let f = try VectorFixtures.load()
    #expect(Crypto.truncatedHash(Data("svc/echo".utf8)) == Data(hexString: f.reqPathHash))
}

@Test func swiftRequestResponseMsgpackMatchUmsgpack() throws {
    let f = try VectorFixtures.load()
    let req = MsgPack.encode(.array([.double(1.5), .bin(Data(hexString: f.reqPathHash)!), .bin(Data("ping".utf8))]))
    #expect(req == Data(hexString: f.reqMsgpack))
    let resp = MsgPack.encode(.array([.bin(Data(repeating: 0xCD, count: 16)), .bin(Data("pong".utf8))]))
    #expect(resp == Data(hexString: f.respMsgpack))
}
