import Testing
import Foundation
@testable import ReTiCA

@Test func swiftLinkIDMatchesReference() throws {
    let f = try VectorFixtures.load()
    let packet = try #require(Packet(raw: Data(hexString: f.linkRequestRaw)!))
    #expect(Link.linkID(requestPacket: packet) == Data(hexString: f.linkID))
}

@Test func swiftLinkSessionKeyMatchesReference() throws {
    let f = try VectorFixtures.load()
    let initPriv = Data(Data(hexString: f.linkInitEphPrivateKey)!.prefix(32))
    let respPub = Data(Data(hexString: f.linkRespEphPublicKey)!.prefix(32))
    let key = Link.sessionKey(ephemeralPrivateX25519: initPriv, peerPublicX25519: respPub,
                              linkID: Data(hexString: f.linkID)!)
    #expect(key == Data(hexString: f.linkDerivedKey))
}

@Test func swiftValidatesReferenceLinkProof() throws {
    let f = try VectorFixtures.load()
    let dest = Identity(publicKey: Data(hexString: f.linkDestIdentityPublic)!)!
    let peerPub = Link.validateProof(proofData: Data(hexString: f.linkProof)!,
                                     linkID: Data(hexString: f.linkID)!, destinationIdentity: dest)
    #expect(peerPub == Data(Data(hexString: f.linkRespEphPublicKey)!.prefix(32)))
}

@Test func swiftDecryptsReferenceLinkData() throws {
    let f = try VectorFixtures.load()
    let key = Data(hexString: f.linkDerivedKey)!
    #expect(Link.decrypt(Data(hexString: f.linkCiphertext)!, sessionKey: key)
            == Data(hexString: f.linkPlaintext))
}
