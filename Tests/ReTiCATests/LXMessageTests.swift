import Testing
import Foundation
@testable import ReTiCA

@Test func lxMessageRoundTripsAndValidates() {
    let source = Identity()
    let destHash = Identity().hash
    let msg = LXMessage.create(source: source, destinationHash: destHash,
                               timestamp: 1700000000.5, title: Data("greeting".utf8),
                               content: Data("hello world".utf8))
    let unpacked = LXMessage.unpack(msg.packed)
    #expect(unpacked != nil)
    #expect(unpacked?.destinationHash == destHash)
    #expect(unpacked?.sourceHash == LXMessage.deliveryHash(identityHash: source.hash))
    #expect(unpacked?.timestamp == 1700000000.5)
    #expect(unpacked?.title == Data("greeting".utf8))
    #expect(unpacked?.content == Data("hello world".utf8))
    #expect(unpacked?.hash == msg.hash)
    #expect(unpacked?.validateSignature(source: source) == true)
}

@Test func lxMessageTamperFailsValidation() {
    let source = Identity()
    let msg = LXMessage.create(source: source, destinationHash: Identity().hash,
                               timestamp: 1700000000.5, title: Data("t".utf8),
                               content: Data("hello world".utf8))
    // Flip the last byte of content (packed ends with ...content‖0x80; index count-2 is the last
    // content byte). Structure stays valid → unpack succeeds, but the signature must not validate.
    var bytes = Array(msg.packed)
    bytes[bytes.count - 2] ^= 0x01
    let tampered = LXMessage.unpack(Data(bytes))
    #expect(tampered != nil)
    #expect(tampered?.validateSignature(source: source) == false)
}

@Test func lxMessageIDIsDeterministicAndContentSensitive() {
    let source = Identity()
    let destHash = Identity().hash
    let a = LXMessage.create(source: source, destinationHash: destHash,
                             timestamp: 1700000000.5, title: Data(), content: Data("x".utf8))
    let b = LXMessage.create(source: source, destinationHash: destHash,
                             timestamp: 1700000000.5, title: Data(), content: Data("x".utf8))
    let c = LXMessage.create(source: source, destinationHash: destHash,
                             timestamp: 1700000000.5, title: Data(), content: Data("y".utf8))
    #expect(a.hash == b.hash)              // deterministic message ID
    // Note: CryptoKit on macOS 26+ uses hedged (randomized) Ed25519 — signatures are not
    // byte-for-byte deterministic, but are still valid and verifiable.
    #expect(a.hash != c.hash)              // content-sensitive message ID
}

@Test func lxMessageUnpackRejectsMalformedAndRichFields() {
    // Too short (< 16+16+64).
    #expect(LXMessage.unpack(Data(count: 50)) == nil)
    // 4th payload element is a non-empty (integer-keyed) map → not LXMF-1 → rejected.
    // payload = fixarray4 [ float64(0), bin(0), bin(0), fixmap1{ uint(1): uint(1) } ]
    let payload = Data([0x94, 0xCB]) + Data(count: 8) + Data([0xC4, 0x00, 0xC4, 0x00, 0x81, 0x01, 0x01])
    let bogus = Data(count: 16) + Data(count: 16) + Data(count: 64) + payload
    #expect(LXMessage.unpack(bogus) == nil)
}
