import Testing
import Foundation
@testable import ReTiCA

@Test func pnAnnounceParsesReference() throws {
    let f = try LXMFPNAnnounceFixtures.load()
    let a = PNAnnounce.parse(Data(hexString: f.packed)!)
    #expect(a != nil)
    #expect(a?.timebase == f.timebase)
    #expect(a?.nodeState == f.nodeState)
    #expect(a?.perTransferLimit == f.perTransferLimit)
    #expect(a?.perSyncLimit == f.perSyncLimit)
    #expect(a?.targetStampCost == f.targetStampCost)
    #expect(a?.stampCostFlexibility == f.stampCostFlexibility)
    #expect(a?.peeringCost == f.peeringCost)
    #expect(a?.metadata == .map([]))
}

@Test func pnAnnouncePackMatchesReference() throws {
    let f = try LXMFPNAnnounceFixtures.load()
    let a = PNAnnounce(timebase: f.timebase, nodeState: f.nodeState,
                       perTransferLimit: f.perTransferLimit, perSyncLimit: f.perSyncLimit,
                       targetStampCost: f.targetStampCost, stampCostFlexibility: f.stampCostFlexibility,
                       peeringCost: f.peeringCost)
    #expect(a.packed == Data(hexString: f.packed)!)                 // byte-parity vs genuine msgpack.packb
}

@Test func pnAnnounceValidityMatchesReference() throws {
    let f = try LXMFPNAnnounceFixtures.load()
    #expect(PNAnnounce.isValid(Data(hexString: f.packed)!) == true)
    #expect(PNAnnounce.isValid(Data(hexString: f.invalidPacked)!) == false)   // 6-element → invalid, agrees with genuine
}
