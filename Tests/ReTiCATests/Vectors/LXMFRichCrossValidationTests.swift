import Testing
import Foundation
@testable import ReTiCA

/// Our LXMessage reproduces genuine lxmf 1.1.0's DETERMINISTIC wire bytes for a message WITH integer-
/// keyed fields (payload region + message hash), and unpacks a genuine rich message back to its fields.
/// The signature is hedged/randomized → validated, not byte-compared.
private func referenceFields(_ f: LXMFRichFixtures) -> [MsgPackValue.IntPair] {
    [.init(0x0C, .bin(Data(hexString: f.fieldTicket)!)), .init(0x0F, .uint(UInt64(f.fieldRenderer)))]
}

@Test func richMessageMatchesReferenceLXMF() throws {
    let f = try LXMFRichFixtures.load()
    let source = Identity(privateKey: Data(hexString: f.sourcePrivateKey)!)!
    let refPacked = Data(hexString: f.packed)!
    let msg = LXMessage.create(source: source, destinationHash: Data(hexString: f.destinationHash)!,
                               timestamp: f.timestamp, title: Data(hexString: f.title)!,
                               content: Data(hexString: f.content)!, fields: referenceFields(f))
    #expect(msg.hash == Data(hexString: f.hash)!)                                   // hash byte-parity
    #expect(Data(msg.packed.dropFirst(96)) == Data(refPacked.dropFirst(96)))        // payload byte-parity
    #expect(msg.validateSignature(source: source) == true)
}

@Test func richMessageUnpackRecoversFields() throws {
    let f = try LXMFRichFixtures.load()
    let source = Identity(privateKey: Data(hexString: f.sourcePrivateKey)!)!
    let unpacked = LXMessage.unpack(Data(hexString: f.packed)!)
    #expect(unpacked != nil)
    #expect(unpacked?.fields == referenceFields(f))
    #expect(unpacked?.content == Data(hexString: f.content)!)
    #expect(unpacked?.hash == Data(hexString: f.hash)!)
    #expect(unpacked?.validateSignature(source: source) == true)
}

@Test func emptyFieldsMessageUnchanged() throws {
    // Regression: a message created with no fields still packs the empty-map payload and round-trips to [].
    let source = Identity()
    let msg = LXMessage.create(source: source, destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("c".utf8))
    #expect(msg.fields.isEmpty)
    #expect(LXMessage.unpack(msg.packed)?.fields == [])
}
