import Testing
import Foundation
@testable import ReTiCA

private func x25519Priv(_ id: Identity) -> Data { Data(id.privateKey!.prefix(32)) }
private func x25519Pub(_ id: Identity) -> Data { Data(id.publicKey.prefix(32)) }

@Test func bothSidesDeriveSameSessionKey() {
    let initEph = Identity()
    let respEph = Identity()
    let linkID = Data(repeating: 0x11, count: 16)
    let initKey = Link.sessionKey(ephemeralPrivateX25519: x25519Priv(initEph),
                                  peerPublicX25519: x25519Pub(respEph), linkID: linkID)
    let respKey = Link.sessionKey(ephemeralPrivateX25519: x25519Priv(respEph),
                                  peerPublicX25519: x25519Pub(initEph), linkID: linkID)
    #expect(initKey == respKey)
    #expect(initKey.count == 64)
}

@Test func sessionKeyDependsOnLinkIDSalt() {
    let a = Identity(); let b = Identity()
    let k1 = Link.sessionKey(ephemeralPrivateX25519: x25519Priv(a), peerPublicX25519: x25519Pub(b),
                             linkID: Data(repeating: 0x01, count: 16))
    let k2 = Link.sessionKey(ephemeralPrivateX25519: x25519Priv(a), peerPublicX25519: x25519Pub(b),
                             linkID: Data(repeating: 0x02, count: 16))
    #expect(k1 != k2) // salt (link_id) changes the derived key
}

@Test func proofBuildValidateRoundTrip() {
    let dest = Identity()          // destination identity (holds private key)
    let respEph = Identity()
    let linkID = Data(repeating: 0x22, count: 16)
    let proof = Link.buildProof(linkID: linkID, responderEphemeral: respEph, destinationIdentity: dest)
    #expect(proof.count == 64 + 32)
    let peerPub = Link.validateProof(proofData: proof, linkID: linkID,
                                     destinationIdentity: Identity(publicKey: dest.publicKey)!)
    #expect(peerPub == x25519Pub(respEph))
}

@Test func proofRejectsTamperAndWrongInputs() {
    let dest = Identity()
    let respEph = Identity()
    let linkID = Data(repeating: 0x22, count: 16)
    let destPub = Identity(publicKey: dest.publicKey)!
    var proof = Link.buildProof(linkID: linkID, responderEphemeral: respEph, destinationIdentity: dest)
    proof[0] ^= 0xFF // corrupt the signature
    #expect(Link.validateProof(proofData: proof, linkID: linkID, destinationIdentity: destPub) == nil)

    let good = Link.buildProof(linkID: linkID, responderEphemeral: respEph, destinationIdentity: dest)
    #expect(Link.validateProof(proofData: good, linkID: Data(repeating: 0x99, count: 16),
                               destinationIdentity: destPub) == nil) // wrong link id
    #expect(Link.validateProof(proofData: good, linkID: linkID,
                               destinationIdentity: Identity(publicKey: Identity().publicKey)!) == nil) // wrong dest
    #expect(Link.validateProof(proofData: Data(repeating: 0, count: 10), linkID: linkID,
                               destinationIdentity: destPub) == nil) // too short
}

@Test func linkIDIsTruncatedHashOfHashablePart() {
    let eph = Identity()
    let packet = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: Data(repeating: 0x33, count: 16), transportId: nil,
                        payload: eph.publicKey)
    let id = Link.linkID(requestPacket: packet)
    #expect(id.count == 16)
    #expect(id == Crypto.truncatedHash(packet.hashablePart))
}

@Test func linkEncryptDecryptRoundTrips() {
    let a = Identity(); let b = Identity()
    let linkID = Data(repeating: 0x44, count: 16)
    let key = Link.sessionKey(ephemeralPrivateX25519: x25519Priv(a), peerPublicX25519: x25519Pub(b),
                              linkID: linkID)
    let pt = Data("link payload".utf8)
    #expect(Link.decrypt(Link.encrypt(pt, sessionKey: key), sessionKey: key) == pt)
    #expect(Link.decrypt(Data(repeating: 0xAB, count: 80), sessionKey: key) == nil) // garbage
}

@Test func fullHandshakeSimulationEstablishesSharedKeyAndDataFlows() {
    let dest = Identity()          // destination (responder owns it)
    let initEph = Identity()
    // Initiator builds the link-request packet, both sides derive link_id from it.
    let reqPacket = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                           destinationType: .single, context: .none, contextFlag: false, hops: 0,
                           destinationHash: Data(repeating: 0x55, count: 16), transportId: nil,
                           payload: initEph.publicKey)
    let linkID = Link.linkID(requestPacket: reqPacket)

    // Responder derives the session key and builds the proof.
    let respEph = Identity()
    let respKey = Link.sessionKey(ephemeralPrivateX25519: x25519Priv(respEph),
                                  peerPublicX25519: x25519Pub(initEph), linkID: linkID)
    let proof = Link.buildProof(linkID: linkID, responderEphemeral: respEph, destinationIdentity: dest)

    // Initiator validates the proof and derives the same key.
    let peerPub = Link.validateProof(proofData: proof, linkID: linkID,
                                     destinationIdentity: Identity(publicKey: dest.publicKey)!)!
    let initKey = Link.sessionKey(ephemeralPrivateX25519: x25519Priv(initEph),
                                  peerPublicX25519: peerPub, linkID: linkID)
    #expect(initKey == respKey)

    // Data flows over the established link.
    let pt = Data("secure link message".utf8)
    #expect(Link.decrypt(Link.encrypt(pt, sessionKey: initKey), sessionKey: respKey) == pt)
}
