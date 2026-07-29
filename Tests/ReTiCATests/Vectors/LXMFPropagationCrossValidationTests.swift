import Testing
import Foundation
@testable import ReTiCA

/// Our LXMFPropagation reproduces genuine lxmf 1.1.0's DETERMINISTIC propagation-container wire bytes:
/// transient_id = full_hash(lxmf_data), and the msgpack([timestamp, [lxmf_data]]) container. The
/// destination-encrypted tail inside lxmf_data is hedged/ephemeral, so it is opaque reference input —
/// never byte-produced or byte-compared here.
@Test func propagationContainerMatchesReferenceLXMF() throws {
    let f = try LXMFPropagationFixtures.load()
    let refPacked = Data(hexString: f.propagationPacked)!

    // 1. Parse the genuine container.
    let parsed = LXMFPropagation.parseContainer(refPacked)
    #expect(parsed != nil)
    #expect(parsed?.timestamp == f.containerTimestamp)
    #expect(parsed?.entries.count == 1)
    let lxmfData = parsed!.entries[0]

    // 2. transient_id byte-parity (full_hash of the given lxmf_data).
    #expect(LXMFPropagation.transientId(lxmfData: lxmfData) == Data(hexString: f.transientId)!)

    // 3. destination hash split byte-parity.
    #expect(LXMFPropagation.destinationHash(lxmfData: lxmfData) == Data(hexString: f.destinationHash)!)

    // 4. Our container re-encode of the same values is byte-identical to genuine LXMF's.
    #expect(LXMFPropagation.container(timestamp: parsed!.timestamp, entries: [lxmfData]) == refPacked)

    // 5. The assemble helper reconstructs the exact entry from its destHash + encrypted tail.
    let destHash = Data(lxmfData.prefix(LXMessage.destinationLength))
    let encrypted = Data(lxmfData.dropFirst(LXMessage.destinationLength))
    let reassembled = LXMFPropagation.lxmfData(destinationHash: destHash, encryptedData: encrypted)
    #expect(reassembled == lxmfData)
    #expect(LXMFPropagation.transientId(lxmfData: reassembled) == Data(hexString: f.transientId)!)
}

/// open() recovers the genuine reference PROPAGATED message: decrypting the reference lxmf_data tail
/// with the recipient identity yields a message whose content/destination match and whose signature
/// validates against the source identity — proving our decrypt matches genuine LXMF's encrypt.
@Test func propagationOpenRecoversReferenceMessage() throws {
    let f = try LXMFPropagationFixtures.load()
    let recipient = Identity(privateKey: Data(hexString: f.recipientPrivateKey)!)!
    let source = Identity(privateKey: Data(hexString: f.sourcePrivateKey)!)!
    let parsed = LXMFPropagation.parseContainer(Data(hexString: f.propagationPacked)!)!
    let recovered = LXMFPropagation.open(lxmfData: parsed.entries[0], recipientIdentity: recipient)
    #expect(recovered != nil)
    #expect(recovered?.content == Data(hexString: f.content)!)
    #expect(recovered?.destinationHash == Data(hexString: f.destinationHash)!)
    #expect(recovered?.validateSignature(source: source) == true)
}

/// pack() then open() round-trips one of our own messages through hedged recipient encryption.
@Test func propagationPackOpenRoundTrips() throws {
    let f = try LXMFPropagationFixtures.load()
    let recipient = Identity(privateKey: Data(hexString: f.recipientPrivateKey)!)!
    let source = Identity(privateKey: Data(hexString: f.sourcePrivateKey)!)!
    let msg = LXMessage.create(source: source, destinationHash: Data(hexString: f.destinationHash)!,
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("round trip".utf8))
    let (packed, transientId) = LXMFPropagation.pack(message: msg, recipientIdentity: recipient,
                                                     timestamp: 1700000000.5)
    let parsed = LXMFPropagation.parseContainer(packed)!
    #expect(parsed.entries.count == 1)
    #expect(transientId == LXMFPropagation.transientId(lxmfData: parsed.entries[0]))   // returned id self-consistent
    let recovered = LXMFPropagation.open(lxmfData: parsed.entries[0], recipientIdentity: recipient)
    #expect(recovered?.hash == msg.hash)
    #expect(recovered?.content == Data("round trip".utf8))
    #expect(recovered?.validateSignature(source: source) == true)
}
