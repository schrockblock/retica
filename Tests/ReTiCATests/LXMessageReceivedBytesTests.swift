import Foundation
import Testing
@testable import ReTiCA

@Suite("LXMessage validates against received bytes")
struct LXMessageReceivedBytesTests {

    /// A payload whose `title` is encoded `bin16` rather than the canonical `bin8`. Spec-legal:
    /// MessagePack permits any length prefix that can represent the length. Our encoder emits
    /// `bin8`, so this is a sender we must accept but cannot reproduce byte-for-byte.
    private func nonCanonicalPayload(timestamp: Double, title: Data, content: Data) -> Data {
        var out = Data([0x94])                                  // fixarray of 4
        out += MsgPack.encode(.double(timestamp))
        out += Data([0xC5, UInt8(title.count >> 8), UInt8(title.count & 0xFF)]) + title  // bin16
        out += MsgPack.encode(.bin(content))
        out += MsgPack.encode(.map([]))                         // empty fields
        return out
    }

    @Test("a validly-signed message in a non-canonical encoding still validates")
    func nonCanonicalEncodingValidates() {
        let source = Identity()
        let sourceHash = LXMessage.deliveryHash(identityHash: source.hash)
        let destinationHash = LXMessage.deliveryHash(identityHash: Identity().hash)
        let title = Data("hi".utf8)
        let content = Data("hello world".utf8)

        let payload = nonCanonicalPayload(timestamp: 1700000000.5, title: title, content: content)
        let hashedPart = destinationHash + sourceHash + payload
        let hash = Crypto.fullHash(hashedPart)
        let signature = source.sign(hashedPart + hash)
        let wire = destinationHash + sourceHash + signature + payload

        let msg = LXMessage.unpack(wire)
        #expect(msg != nil)
        if let msg {
            #expect(msg.title == title)
            #expect(msg.content == content)
            #expect(msg.hash == hash)
            // The defect: we re-encode the payload as bin8, so the recomputed hash differs and
            // the signature check fails against a message that is genuinely valid.
            #expect(msg.validateSignature(source: source) == true)
        }
    }

    @Test("a canonically-encoded message still validates")
    func canonicalEncodingStillValidates() {
        let source = Identity()
        let msg = LXMessage.create(source: source,
                                   destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                                   timestamp: 1700000000.5,
                                   title: Data("hi".utf8), content: Data("hello world".utf8))
        let reparsed = LXMessage.unpack(msg.packed)
        #expect(reparsed != nil)
        if let reparsed { #expect(reparsed.validateSignature(source: source) == true) }
    }

    @Test("a tampered payload still fails validation")
    func tamperedPayloadFailsValidation() {
        let source = Identity()
        let msg = LXMessage.create(source: source,
                                   destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                                   timestamp: 1700000000.5,
                                   title: Data("hi".utf8), content: Data("hello world".utf8))
        var wire = msg.packed
        wire[wire.count - 1] ^= 0xFF                 // flip a byte inside the payload
        if let tampered = LXMessage.unpack(wire) {
            #expect(tampered.validateSignature(source: source) == false)
        }
    }

    @Test("forwarding preserves the sender's exact bytes")
    func forwardingPreservesReceivedBytes() {
        let source = Identity()
        let sourceHash = LXMessage.deliveryHash(identityHash: source.hash)
        let destinationHash = LXMessage.deliveryHash(identityHash: Identity().hash)
        let title = Data("hi".utf8)
        let content = Data("hello world".utf8)

        let payload = nonCanonicalPayload(timestamp: 1700000000.5, title: title, content: content)
        let hashedPart = destinationHash + sourceHash + payload
        let signature = source.sign(hashedPart + Crypto.fullHash(hashedPart))
        let wire = destinationHash + sourceHash + signature + payload

        let msg = LXMessage.unpack(wire)
        #expect(msg != nil)
        // A relay must hand on what it received. Re-encoding would emit bin8 where the sender used
        // bin16, changing the bytes and invalidating the signature for every downstream hop.
        if let msg { #expect(msg.packed == wire) }
    }

    @Test("a locally-created message still packs from its fields")
    func locallyCreatedMessagePacksFromFields() {
        let source = Identity()
        let msg = LXMessage.create(source: source,
                                   destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                                   timestamp: 1700000000.5,
                                   title: Data("hi".utf8), content: Data("hello world".utf8))
        #expect(msg.packed.count > 0)
        #expect(LXMessage.unpack(msg.packed) != nil)
    }

    @Test("withStamp on a received message packs the stamp, not the pre-stamp bytes")
    func withStampOnReceivedMessageIncludesStamp() {
        let source = Identity()
        let sourceHash = LXMessage.deliveryHash(identityHash: source.hash)
        let destinationHash = LXMessage.deliveryHash(identityHash: Identity().hash)
        let title = Data("hi".utf8)
        let content = Data("hello world".utf8)

        let payload = nonCanonicalPayload(timestamp: 1700000000.5, title: title, content: content)
        let hashedPart = destinationHash + sourceHash + payload
        let signature = source.sign(hashedPart + Crypto.fullHash(hashedPart))
        let wire = destinationHash + sourceHash + signature + payload

        guard let msg = LXMessage.unpack(wire) else {
            Issue.record("unpack returned nil")
            return
        }

        // Generate a stamp and attach it. withStamp must NOT carry receivedBytes through — doing so
        // would return the pre-stamp bytes from packed and silently discard the stamp.
        let stamp = Data(repeating: 0xAB, count: 32)
        let stamped = msg.withStamp(stamp)

        // Round-trip: packed must decode to a message whose stamp field matches.
        guard let reparsed = LXMessage.unpack(stamped.packed) else {
            Issue.record("unpack of stamped.packed returned nil")
            return
        }
        #expect(reparsed.stamp == stamp)
    }
}
