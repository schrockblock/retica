import Testing
import Foundation
@testable import ReTiCA

private func sampleAdvertisement() -> ResourceAdvertisement {
    ResourceAdvertisement(
        transferSize: 40, dataSize: 20, numberOfParts: 1,
        hash: Data(repeating: 0x11, count: 32), randomHash: Data(repeating: 0x22, count: 4),
        originalHash: Data(repeating: 0x11, count: 32), segmentIndex: 1, totalSegments: 1,
        requestID: nil, flags: 0x01, hashmap: Data(repeating: 0x33, count: 4))
}

@Test func advertisementPacksToReferenceBytes() {
    // umsgpack.packb of {t:40,d:20,n:1,h:0x11*32,r:0x22*4,o:0x11*32,i:1,l:1,q:None,f:1,m:0x33*4}
    let expected = Data(hexString:
        "8ba17428a16414a16e01a168c420" + String(repeating: "11", count: 32) +
        "a172c40422222222a16fc420" + String(repeating: "11", count: 32) +
        "a16901a16c01a171c0a16601a16dc40433333333")!
    #expect(sampleAdvertisement().pack() == expected)
}

@Test func advertisementRoundTrips() {
    let adv = sampleAdvertisement()
    #expect(ResourceAdvertisement.unpack(adv.pack()) == adv)
}

@Test func advertisementFlagAccessors() {
    var adv = sampleAdvertisement()
    #expect(adv.isEncrypted == true && adv.isCompressed == false && adv.isRequest == false)
    adv.flags = 0b0011_1110   // meta+response+request+split+compressed, not encrypted
    #expect(adv.hasMetadata && adv.isResponse && adv.isRequest && adv.isSplit && adv.isCompressed)
    #expect(adv.isEncrypted == false)
}

@Test func advertisementUnpackWithRequestID() {
    var adv = sampleAdvertisement()
    adv.requestID = Data(repeating: 0x9A, count: 16)
    #expect(ResourceAdvertisement.unpack(adv.pack())?.requestID == adv.requestID)
}

@Test func advertisementUnpackRejectsMalformed() {
    #expect(ResourceAdvertisement.unpack(Data([0x01, 0x02])) == nil)          // not a msgpack map
    #expect(ResourceAdvertisement.unpack(MsgPack.encode(.uint(5))) == nil)    // valid msgpack, not a map
    // A map missing a required key (only "t") must be rejected.
    #expect(ResourceAdvertisement.unpack(MsgPack.encode(.map([.init("t", .uint(1))]))) == nil)
}

// Reference rejects adv.t > MAX_EFFICIENT_SIZE*3 at unpack (RNS/Resource.py:1366).
// We mirror that: an advertisement declaring a transfer size above maxAdvertisedTransferSize is hostile.
@Test func advertisementUnpackRejectsOversizedTransferSize() {
    // Build a structurally-valid advertisement with a hostile transferSize.
    var adv = sampleAdvertisement()
    adv.transferSize = UInt64(Resource.maxAdvertisedTransferSize) + 1
    #expect(ResourceAdvertisement.unpack(adv.pack()) == nil)
}

@Test func advertisementUnpackAcceptsLegitimateTransferSize() {
    // A transfer size right at the ceiling must still be accepted.
    var adv = sampleAdvertisement()
    adv.transferSize = UInt64(Resource.maxAdvertisedTransferSize)
    #expect(ResourceAdvertisement.unpack(adv.pack()) != nil)
}
