import Testing
import Foundation
@testable import ReTiCA

@Test func swiftResourceHashMatchesReference() throws {
    let f = try VectorFixtures.load()
    #expect(Resource.resourceHash(data: Data(hexString: f.resourceData)!,
                                  randomHash: Data(hexString: f.resourceRandomHash)!)
            == Data(hexString: f.resourceHash))
}

@Test func swiftAssemblesReferenceResourceStream() throws {
    let f = try VectorFixtures.load()
    let key = Data(hexString: f.resourceTokenKey)!
    let parts = Resource.parts(stream: Data(hexString: f.resourceStream)!, sdu: f.resourceSdu)
    #expect(Resource.assemble(parts: parts, sessionKey: key) == Data(hexString: f.resourceData))
    // map hash of the first part matches the reference
    #expect(Resource.mapHash(chunk: parts[0], randomHash: Data(hexString: f.resourceRandomHash)!)
            == Data(hexString: f.resourceMapHash0))
}

@Test func swiftResourceProofMatchesReference() throws {
    let f = try VectorFixtures.load()
    let data = Data(hexString: f.resourceData)!
    let h = Data(hexString: f.resourceHash)!
    #expect(Resource.expectedProof(data: data, hash: h) == Data(hexString: f.resourceProof))
    #expect(Resource.proofData(data: data, hash: h).suffix(32) == Data(hexString: f.resourceProof))
}

@Test func swiftAdvertisementPackMatchesReference() throws {
    let f = try VectorFixtures.load()
    let stream = Data(hexString: f.resourceStream)!
    let parts = Resource.parts(stream: stream, sdu: f.resourceSdu)
    let r = Data(hexString: f.resourceRandomHash)!
    let h = Data(hexString: f.resourceHash)!
    let adv = ResourceAdvertisement(
        transferSize: UInt64(stream.count), dataSize: UInt64(Data(hexString: f.resourceData)!.count),
        numberOfParts: UInt64(parts.count), hash: h, randomHash: r, originalHash: h,
        segmentIndex: 0, totalSegments: 1, requestID: nil, flags: 0x01,
        hashmap: Resource.hashmap(parts: parts, randomHash: r))
    #expect(adv.pack() == Data(hexString: f.resourceAdvMsgpack))
}

@Test func endToEndResourcePrimitiveRoundTrip() {
    // Sender builds; receiver assembles + verifies + proves; sender validates. No fixtures.
    let key = Data(repeating: 0x07, count: 64)
    let data = Data("the quick brown fox jumps over the lazy dog, twice for good measure".utf8)
    let r = Data([0x01, 0x02, 0x03, 0x04])
    let prefix = Data([0x0A, 0x0B, 0x0C, 0x0D])
    let stream = Resource.buildStream(data: data, prefix: prefix, sessionKey: key)
    let parts = Resource.parts(stream: stream, sdu: 24)
    let h = Resource.resourceHash(data: data, randomHash: r)
    let expected = Resource.expectedProof(data: data, hash: h)
    let adv = ResourceAdvertisement(
        transferSize: UInt64(stream.count), dataSize: UInt64(data.count), numberOfParts: UInt64(parts.count),
        hash: h, randomHash: r, originalHash: h, segmentIndex: 0, totalSegments: 1,
        requestID: nil, flags: 0x01, hashmap: Resource.hashmap(parts: parts, randomHash: r))

    // Receiver
    let recvAdv = ResourceAdvertisement.unpack(adv.pack())!
    let assembled = Resource.assemble(parts: parts, sessionKey: key)!
    #expect(assembled == data)
    #expect(Resource.verify(data: assembled, randomHash: recvAdv.randomHash, hash: recvAdv.hash))
    let proof = Resource.proofData(data: assembled, hash: recvAdv.hash)

    // Sender validates
    #expect(Resource.validateProof(proofData: proof, expectedProof: expected))
}
