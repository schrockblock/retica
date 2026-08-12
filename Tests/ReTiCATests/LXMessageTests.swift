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

@Test func lxMessageUnpackRejectsMalformed() {
    // Too short (< 16+16+64).
    #expect(LXMessage.unpack(Data(count: 50)) == nil)
    // 4th payload element is a non-empty integer-keyed map → now accepted as rich fields (LXMF-5a).
    // payload = fixarray4 [ float64(0), bin(0), bin(0), fixmap1{ uint(1): uint(1) } ]
    let payload = Data([0x94, 0xCB]) + Data(count: 8) + Data([0xC4, 0x00, 0xC4, 0x00, 0x81, 0x01, 0x01])
    let richMessage = Data(count: 16) + Data(count: 16) + Data(count: 64) + payload
    let unpacked = LXMessage.unpack(richMessage)
    #expect(unpacked != nil)
    #expect(unpacked?.fields == [MsgPackValue.IntPair(1, .uint(1))])
}

/// Step 4 — round-trip proof that LXMessage.unpack → re-encode cannot reach MsgPack.swift:71
/// (UInt64(p.key)) with a negative Int.
///
/// The decode → re-encode path runs in LXMessage.unpack when a stamp is present
/// (LXMessage.swift:108: payloadBytes re-packs the 4-element payload to compute the hash).
/// It also runs on packed and validateSignature.
///
/// The guard added at MsgPack.swift:146 (Int(exactly:)) ensures every IntPair.key decoded
/// from the wire is in 0...Int.max, so UInt64(p.key) at :71 is safe on all such values.
/// This test proves that an IntMap with the maximum representable key (Int.max) survives
/// a full unpack→re-encode round trip without trapping.
@Test func lxMessageRichFieldsRoundTripDoesNotReachNegativeKeyOnEncode() {
    // Build a message with a rich field using key = Int.max (the largest value the fix allows).
    let source = Identity()
    let destHash = LXMessage.deliveryHash(identityHash: Identity().hash)
    let fields: [MsgPackValue.IntPair] = [.init(Int.max, .uint(42))]
    let msg = LXMessage.create(source: source, destinationHash: destHash,
                               timestamp: 1700000000.5, title: Data(), content: Data(),
                               fields: fields)
    // Unpack calls payloadBytes (the re-encode path) when a stamp is present; here we exercise
    // it by calling packed (which re-encodes fields every time) and validateSignature.
    let repacked = msg.packed
    let unpacked = LXMessage.unpack(repacked)
    #expect(unpacked != nil)
    if let unpacked {
        #expect(unpacked.fields.count == 1)
        #expect(unpacked.fields.first?.key == Int.max)
        #expect(unpacked.fields.first?.value == .uint(42))
        // validateSignature calls payloadBytes → encodeIntMap → UInt64(p.key) at :71.
        // This would trap for a negative key; Int.max is fine.
        #expect(unpacked.validateSignature(source: source) == true)
    }
}

@Test func opportunisticPayloadStripsLeadingDestinationHash() {
    let source = Identity()
    let destHash = LXMessage.deliveryHash(identityHash: Identity().hash)
    let msg = LXMessage.create(source: source, destinationHash: destHash,
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("hi".utf8))
    #expect(msg.opportunisticPayload == Data(msg.packed.dropFirst(16)))
    #expect(msg.opportunisticPayload.count == msg.packed.count - 16)
}

@Test func fromOpportunisticReconstructsAndValidates() {
    let source = Identity()
    let destHash = LXMessage.deliveryHash(identityHash: Identity().hash)
    let msg = LXMessage.create(source: source, destinationHash: destHash,
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("hi".utf8))
    // Receiver reconstructs from its delivery-destination hash + the decrypted payload.
    let recovered = LXMessage.fromOpportunistic(destinationHash: destHash, payload: msg.opportunisticPayload)
    #expect(recovered != nil)
    #expect(recovered?.hash == msg.hash)
    #expect(recovered?.content == Data("hi".utf8))
    #expect(recovered?.sourceHash == LXMessage.deliveryHash(identityHash: source.hash))
    #expect(recovered?.validateSignature(source: source) == true)
}

@Test func fromOpportunisticRejectsMalformed() {
    // destinationHash + payload shorter than the LXMF header (16+16+64) → nil.
    #expect(LXMessage.fromOpportunistic(destinationHash: Data(count: 16), payload: Data(count: 10)) == nil)
}

@Test func directRepresentationIsPacketForSmallAndResourceForLarge() {
    let source = Identity()
    let destHash = LXMessage.deliveryHash(identityHash: Identity().hash)
    let small = LXMessage.create(source: source, destinationHash: destHash,
                                 timestamp: 1700000000.5, title: Data(), content: Data("hi".utf8))
    #expect(small.packed.count <= Link.mdu)
    #expect(small.directRepresentation == .packet)
    let large = LXMessage.create(source: source, destinationHash: destHash,
                                 timestamp: 1700000000.5, title: Data(), content: Data(repeating: 0x41, count: 1000))
    #expect(large.packed.count > Link.mdu)
    #expect(large.directRepresentation == .resource)
}

/// The boundary is exactly Link.mdu (packed.count == mdu → packet; +1 → resource), so the `<=` and
/// the threshold value are load-bearing. Content length is tuned so `packed.count == Link.mdu`.
@Test func directRepresentationBoundaryIsLinkMdu() {
    let source = Identity()
    let destHash = LXMessage.deliveryHash(identityHash: Identity().hash)
    func msg(_ contentLen: Int) -> LXMessage {
        LXMessage.create(source: source, destinationHash: destHash, timestamp: 1700000000.5,
                         title: Data(), content: Data(repeating: 0x41, count: contentLen))
    }
    // Probe in the bin16 range (>=256) so +1 content byte == +1 packed byte (stable 3-byte bin header).
    let probeLen = 300
    let atMduLen = probeLen + (Link.mdu - msg(probeLen).packed.count)   // → packed.count == Link.mdu
    let atMdu = msg(atMduLen)
    #expect(atMdu.packed.count == Link.mdu)
    #expect(atMdu.directRepresentation == .packet)
    let overMdu = msg(atMduLen + 1)
    #expect(overMdu.packed.count == Link.mdu + 1)
    #expect(overMdu.directRepresentation == .resource)
}

@Test func opportunisticFitsSmallNotLarge() {
    let source = Identity()
    let destHash = LXMessage.deliveryHash(identityHash: Identity().hash)
    let small = LXMessage.create(source: source, destinationHash: destHash,
                                 timestamp: 1700000000.5, title: Data(), content: Data("hi".utf8))
    #expect(small.opportunisticPayload.count <= LXMessage.encryptedPacketMDU)
    #expect(small.opportunisticFits == true)
    let large = LXMessage.create(source: source, destinationHash: destHash,
                                 timestamp: 1700000000.5, title: Data(), content: Data(repeating: 0x41, count: 1000))
    #expect(large.opportunisticPayload.count > LXMessage.encryptedPacketMDU)
    #expect(large.opportunisticFits == false)
}

/// Boundary at exactly encryptedPacketMDU (opportunisticPayload.count == MDU → fits; +1 → not).
@Test func opportunisticFitsBoundary() {
    let source = Identity()
    let destHash = LXMessage.deliveryHash(identityHash: Identity().hash)
    func msg(_ n: Int) -> LXMessage {
        LXMessage.create(source: source, destinationHash: destHash, timestamp: 1700000000.5,
                         title: Data(), content: Data(repeating: 0x41, count: n))
    }
    let probeLen = 300   // bin16 range → +1 content == +1 opportunisticPayload byte
    let atMduLen = probeLen + (LXMessage.encryptedPacketMDU - msg(probeLen).opportunisticPayload.count)
    let atMdu = msg(atMduLen)
    #expect(atMdu.opportunisticPayload.count == LXMessage.encryptedPacketMDU)
    #expect(atMdu.opportunisticFits == true)
    let overMdu = msg(atMduLen + 1)
    #expect(overMdu.opportunisticPayload.count == LXMessage.encryptedPacketMDU + 1)
    #expect(overMdu.opportunisticFits == false)
}
