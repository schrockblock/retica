import Testing
import Foundation
@testable import ReTiCA

/// Our LXMessage reproduces genuine lxmf 1.1.0's stamped 5-element wire form and validates its stamp.
@Test func stampedMessageUnpacksAndValidates() throws {
    let f = try LXMFStampFixtures.load()
    let source = Identity(privateKey: Data(hexString: f.sourcePrivateKey)!)!
    let unpacked = LXMessage.unpack(Data(hexString: f.packed)!)
    #expect(unpacked != nil)
    #expect(unpacked?.stamp == Data(hexString: f.stamp)!)
    #expect(unpacked?.hash == Data(hexString: f.hash)!)                    // hash over payload[:4]
    #expect(unpacked?.content == Data(hexString: f.content)!)
    #expect(unpacked?.validateSignature(source: source) == true)
    #expect(unpacked?.validateStamp(targetCost: f.stampCost) == true)
}

@Test func stampAttachmentMatchesReferenceBytes() throws {
    let f = try LXMFStampFixtures.load()
    let source = Identity(privateKey: Data(hexString: f.sourcePrivateKey)!)!
    let refPacked = Data(hexString: f.packed)!
    // Build the unstamped message, then attach the reference stamp → 5-element payload must byte-match.
    let msg = LXMessage.create(source: source, destinationHash: Data(hexString: f.destinationHash)!,
                               timestamp: f.timestamp, title: Data(hexString: f.title)!,
                               content: Data(hexString: f.content)!)
        .withStamp(Data(hexString: f.stamp)!)
    #expect(msg.hash == Data(hexString: f.hash)!)                          // stamp doesn't change the hash
    #expect(Data(msg.packed.dropFirst(96)) == Data(refPacked.dropFirst(96)))   // 5-element payload byte-parity
}

@Test func generatedStampRoundTrips() async throws {
    let source = Identity()
    let cost = 4
    let base = LXMessage.create(source: source,
                                destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                                timestamp: 1700000000.5, title: Data("t".utf8), content: Data("c".utf8))
    let stamped = base.withStamp(await LXStamper.generateStamp(messageId: base.hash, targetCost: cost)!)
    let recovered = LXMessage.unpack(stamped.packed)
    #expect(recovered?.stamp == stamped.stamp)
    #expect(recovered?.hash == base.hash)                                  // hash unchanged by stamping
    #expect(recovered?.validateStamp(targetCost: cost) == true)
    #expect(recovered?.validateSignature(source: source) == true)
}

/// Regression (carried from 5a review): unpack rejects a 4-element payload with an unrecognized 4th
/// element (a non-empty string-keyed map is not a valid LXMF fields element).
@Test func unpackRejectsUnrecognizedFieldsElement() throws {
    let header = Data(repeating: 0, count: 2 * LXMessage.destinationLength + LXMessage.signatureLength)
    let badPayload = MsgPack.encode(.array([.double(1), .bin(Data()), .bin(Data()), .map([.init("k", .uint(1))])]))
    #expect(LXMessage.unpack(header + badPayload) == nil)
}
