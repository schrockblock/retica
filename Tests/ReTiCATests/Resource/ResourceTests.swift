import Testing
import Foundation
@testable import ReTiCA

private let key = Data(repeating: 0x01, count: 64)   // valid AES-256 Token key
private let r = Data([0xAA, 0xBB, 0xCC, 0xDD])       // 4-byte resource random hash
private let prefix = Data([0x01, 0x02, 0x03, 0x04])  // 4-byte stream prefix

@Test func resourceHashIsFullHashOfDataAndRandom() {
    let data = Data("resource payload".utf8)
    #expect(Resource.resourceHash(data: data, randomHash: r) == Crypto.fullHash(data + r))
}

@Test func mapHashIsFirst4OfFullHashChunkAndRandom() {
    let chunk = Data(repeating: 0x5A, count: 40)
    #expect(Resource.mapHash(chunk: chunk, randomHash: r) == Data(Crypto.fullHash(chunk + r).prefix(4)))
}

@Test func buildStreamAssembleRoundTrips() {
    let data = Data("some resource bytes to transfer".utf8)
    let stream = Resource.buildStream(data: data, prefix: prefix, sessionKey: key)
    #expect(!stream.isEmpty)
    let parts = Resource.parts(stream: stream, sdu: 16)
    #expect(parts.count == Int(ceil(Double(stream.count) / 16.0)))
    #expect(Resource.assemble(parts: parts, sessionKey: key) == data)   // decrypt + strip prefix
}

@Test func hashmapLengthIsFourPerPart() {
    let stream = Resource.buildStream(data: Data(repeating: 0x11, count: 100), prefix: prefix, sessionKey: key)
    let parts = Resource.parts(stream: stream, sdu: 16)
    #expect(Resource.hashmap(parts: parts, randomHash: r).count == parts.count * 4)
}

@Test func verifyAcceptsCorrectHashRejectsTamper() {
    let data = Data("verify me".utf8)
    let h = Resource.resourceHash(data: data, randomHash: r)
    #expect(Resource.verify(data: data, randomHash: r, hash: h) == true)
    #expect(Resource.verify(data: data + Data([0x00]), randomHash: r, hash: h) == false)
}

@Test func proofRoundTrips() {
    let data = Data("prove me".utf8)
    let h = Resource.resourceHash(data: data, randomHash: r)
    let expected = Resource.expectedProof(data: data, hash: h)
    let proof = Resource.proofData(data: data, hash: h)
    #expect(proof.count == 64)
    #expect(proof.prefix(32) == h)
    #expect(Resource.validateProof(proofData: proof, expectedProof: expected) == true)
    #expect(Resource.validateProof(proofData: proof, expectedProof: Data(repeating: 0, count: 32)) == false)
    #expect(Resource.validateProof(proofData: Data(repeating: 0, count: 10), expectedProof: expected) == false)
}

@Test func buildStreamReturnsEmptyOnBadKey() {
    #expect(Resource.buildStream(data: Data([0x01]), prefix: prefix, sessionKey: Data([0x01, 0x02])).isEmpty)
    #expect(Resource.assemble(parts: [Data([0x01])], sessionKey: Data([0x01, 0x02])) == nil)
}

@Test func nextWindowRequestSelectsFirstWindowOfMissingParts() {
    // 8 parts, 4-byte map hashes 0x00000000, 0x01010101, ... 0x07070707.
    var hashmap = Data()
    for i in 0..<8 { hashmap += Data(repeating: UInt8(i), count: 4) }
    let req = Resource.nextWindowRequest(receivedIndices: [], hashmap: hashmap,
                                         height: -1, window: 4, partCount: 8)
    #expect(req.indices == [0, 1, 2, 3])
    #expect(req.mapHashes == Data([0,0,0,0, 1,1,1,1, 2,2,2,2, 3,3,3,3]))
}

@Test func nextWindowRequestSkipsAlreadyReceivedSlots() {
    var hashmap = Data()
    for i in 0..<8 { hashmap += Data(repeating: UInt8(i), count: 4) }
    // height 1 (0,1 done); within slots 2..5, slot 3 already received.
    let req = Resource.nextWindowRequest(receivedIndices: [0, 1, 3], hashmap: hashmap,
                                         height: 1, window: 4, partCount: 8)
    #expect(req.indices == [2, 4, 5])                       // slot 3 skipped; 4 slots scanned (2,3,4,5)
    #expect(req.mapHashes == Data([2,2,2,2, 4,4,4,4, 5,5,5,5]))
}

@Test func nextWindowRequestClampsToPartCount() {
    var hashmap = Data()
    for i in 0..<3 { hashmap += Data(repeating: UInt8(i), count: 4) }
    let req = Resource.nextWindowRequest(receivedIndices: [], hashmap: hashmap,
                                         height: -1, window: 4, partCount: 3)
    #expect(req.indices == [0, 1, 2])                      // only 3 parts exist
    #expect(req.mapHashes.count == 12)
}

@Test func nextWindowRequestEmptyWhenAllReceived() {
    var hashmap = Data()
    for i in 0..<3 { hashmap += Data(repeating: UInt8(i), count: 4) }
    let req = Resource.nextWindowRequest(receivedIndices: [0, 1, 2], hashmap: hashmap,
                                         height: 2, window: 4, partCount: 3)
    #expect(req.indices.isEmpty)
    #expect(req.mapHashes.isEmpty)
}
