import Testing
import Foundation
@testable import ReTiCA

/// Our LXMessage reproduces genuine lxmf 1.1.0's DETERMINISTIC wire bytes (destination/source hashes,
/// payload) and message-ID, produces a valid signature, and unpacks + validates a genuine reference
/// message. The signature bytes are NOT compared (ReTiCA's Ed25519 is hedged/randomized) — they are
/// validated instead.
@Test func lxMessageMatchesReferenceLXMF() throws {
    let f = try LXMFVectorFixtures.load()
    let source = Identity(privateKey: Data(hexString: f.sourcePrivateKey)!)!
    let destHash = Data(hexString: f.destinationHash)!
    let refPacked = Data(hexString: f.packed)!

    let msg = LXMessage.create(source: source, destinationHash: destHash,
                               timestamp: f.timestamp, title: Data(hexString: f.title)!,
                               content: Data(hexString: f.content)!)
    // Our derived lxmf.delivery source hash matches genuine LXMF's (also proves the private key
    // loaded into the same identity).
    #expect(msg.sourceHash == Data(hexString: f.sourceHash)!)
    #expect(msg.hash == Data(hexString: f.hash)!)              // SHA-256 message-ID byte-parity
    // Deterministic wire regions match byte-for-byte: destHash‖sourceHash (bytes 0..<32) and the
    // msgpack payload (bytes 96..). The 64-byte signature region (32..<96) is randomized → validated,
    // not compared.
    let ourPacked = msg.packed
    #expect(ourPacked.prefix(32) == refPacked.prefix(32))
    #expect(Data(ourPacked.dropFirst(96)) == Data(refPacked.dropFirst(96)))
    #expect(msg.validateSignature(source: source) == true)     // our signature is valid

    // Our unpack recovers a genuine reference message and validates its (deterministic) signature.
    let unpacked = LXMessage.unpack(refPacked)
    #expect(unpacked != nil)
    #expect(unpacked?.content == Data(hexString: f.content)!)
    #expect(unpacked?.hash == Data(hexString: f.hash)!)
    #expect(unpacked?.validateSignature(source: source) == true)
}

/// Our Link.mdu equals genuine RNS Link.MDU — the threshold LXMF uses to choose a link packet vs a
/// Resource for DIRECT delivery.
@Test func linkMduMatchesRns() throws {
    let f = try LXMFVectorFixtures.load()
    #expect(Link.mdu == f.linkMdu)
}

/// Our encryptedPacketMDU equals genuine RNS/LXMF ENCRYPTED_PACKET_MDU — the opportunistic→direct
/// size-fallback threshold.
@Test func encryptedPacketMduMatchesRns() throws {
    let f = try LXMFVectorFixtures.load()
    #expect(LXMessage.encryptedPacketMDU == f.encryptedPacketMdu)
}

/// Our LXMF delivery timing constants match genuine RNS LXMRouter.
@Test func lxmfDeliveryConstantsMatchRns() throws {
    let f = try LXMFVectorFixtures.load()
    #expect(LXMFDelivery.retryWaitSeconds == f.deliveryRetryWait)
    #expect(LXMFDelivery.maxAttempts == f.maxDeliveryAttempts)
}

/// Our LXMF path-request wait matches genuine RNS LXMRouter.PATH_REQUEST_WAIT.
@Test func pathRequestWaitMatchesRns() throws {
    let f = try LXMFVectorFixtures.load()
    #expect(LXMFDelivery.pathRequestWaitSeconds == f.pathRequestWait)
}

/// Our LXMF idle-link teardown threshold matches genuine RNS LXMRouter.LINK_MAX_INACTIVITY.
@Test func linkMaxInactivityMatchesRns() throws {
    let f = try LXMFVectorFixtures.load()
    #expect(LXMFDelivery.linkMaxInactivitySeconds == f.linkMaxInactivity)
}

/// A genuine LXMF opportunistic payload is `packed[16:]`; reconstructing it with our
/// `fromOpportunistic` (prepending the delivery destination hash) recovers the genuine reference
/// message and validates its signature.
@Test func fromOpportunisticReconstructsReferenceMessage() throws {
    let f = try LXMFVectorFixtures.load()
    let refPacked = Data(hexString: f.packed)!
    let destHash = Data(hexString: f.destinationHash)!
    let source = Identity(privateKey: Data(hexString: f.sourcePrivateKey)!)!
    let opportunistic = Data(refPacked.dropFirst(16))          // what RNS.Packet carries as payload
    let recovered = LXMessage.fromOpportunistic(destinationHash: destHash, payload: opportunistic)
    #expect(recovered != nil)
    #expect(recovered?.hash == Data(hexString: f.hash)!)
    #expect(recovered?.content == Data(hexString: f.content)!)
    #expect(recovered?.validateSignature(source: source) == true)
}
