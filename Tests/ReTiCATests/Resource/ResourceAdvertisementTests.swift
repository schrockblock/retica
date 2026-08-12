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
    // Both ends of the accepted range: zero and exactly the ceiling.
    var atZero = sampleAdvertisement()
    atZero.transferSize = 0
    #expect(ResourceAdvertisement.unpack(atZero.pack()) != nil)

    var atCeiling = sampleAdvertisement()
    atCeiling.transferSize = UInt64(Resource.maxAdvertisedTransferSize)
    #expect(ResourceAdvertisement.unpack(atCeiling.pack()) != nil)
}

/// Reference can afford `MAX_EFFICIENT_SIZE*3` because `Resource.__init__` splits EVERY resource
/// at MAX_EFFICIENT_SIZE (RNS/Resource.py:274-310). ReTiCA does not split requests/responses —
/// `LinkSession.sendResponse` hands the whole payload to one `ResourceTransfer` — so a propagation
/// -node mailbox download (`LXMFServiceNode` default store limit: 32 MiB) legitimately advertises a
/// `t` many times the reference bound. Adopting reference's number made our own receiver reject
/// our own senders.
@Test func advertisementUnpackAcceptsPropagationScaleTransferSize() {
    // A 32 MiB mailbox download — the default per-node propagation store limit, i.e. the largest
    // response `LXMFServiceNode` can legitimately serve in one un-split resource.
    var adv = sampleAdvertisement()
    adv.transferSize = 32 * 1024 * 1024
    let round = ResourceAdvertisement.unpack(adv.pack())
    #expect(round != nil)
    if let round { #expect(round.transferSize == 32 * 1024 * 1024) }
}

/// `d` is deliberately NOT bounded at unpack: for a split resource it is legitimately the whole
/// object's size, which exceeds any per-transfer bound. The decompress call site is therefore what
/// must survive an absurd `d` — it must not convert to `Int` before clamping.
@Test func advertisementUnpackLeavesDataSizeUnbounded() {
    var adv = sampleAdvertisement()
    adv.dataSize = UInt64(Int.max) + 1
    #expect(ResourceAdvertisement.unpack(adv.pack())?.dataSize == UInt64(Int.max) + 1)
}
