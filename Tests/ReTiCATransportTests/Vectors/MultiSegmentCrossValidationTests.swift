import Testing
import Foundation
@testable import ReTiCATransport
@testable import ReTiCA

/// Cross-validates our ResourceAdvertisement unpack/re-pack against genuine multi-segment
/// advertisements produced by Python-RNS 1.3.8. The fixture generator drives a real
/// RNS.Resource with a >MAX_EFFICIENT_SIZE payload and emits two segment advertisements;
/// these tests assert that our code correctly reads the segment fields and round-trips the
/// packed bytes byte-for-byte.
@Test func genuineRnsSegmentAdvertisementsUnpackWithSegmentFields() throws {
    let f = try TransportVectorFixtures.load()
    let a1 = ResourceAdvertisement.unpack(Data(hexString: f.msSeg1Adv)!)!
    let a2 = ResourceAdvertisement.unpack(Data(hexString: f.msSeg2Adv)!)!
    #expect(a1.segmentIndex == 1)                                   // RNS 1-based
    #expect(a2.segmentIndex == 2)
    #expect(a1.totalSegments == 2 && a2.totalSegments == 2)
    #expect(a1.isSplit && a2.isSplit)                               // f bit 2
    #expect(a1.originalHash == a2.originalHash)                     // shared grouping key = seg1 hash
    #expect(a1.originalHash == a1.hash)                             // seg1's o == its own hash
    #expect(a1.dataSize == UInt64(f.msTotalSize))                   // d = whole size in every segment
    #expect(a2.dataSize == UInt64(f.msTotalSize))
}

@Test func ourPackMatchesGenuineRnsSegmentAdvertisementBytes() throws {
    let f = try TransportVectorFixtures.load()
    let genuine = Data(hexString: f.msSeg1Adv)!
    let a = ResourceAdvertisement.unpack(genuine)!                  // take genuine field values
    #expect(a.pack() == genuine)                                    // our re-pack is byte-identical
}
