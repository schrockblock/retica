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
