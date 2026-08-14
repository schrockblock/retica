import Testing
import Foundation
@testable import ReTiCA

// MARK: — Task 7: reject out-of-range UInt64 fields
// Each blob is the valid fixture with ONE field replaced by UInt64.max (CF FFFFFFFFFFFFFFFF).
// Before the fix, PNAnnounce.parse calls Int(UInt64.max) which traps — the process crashes.
// After the fix, each call must return nil (isValid must return false).
//
// Reference: pn_announce_data_is_valid (LXMF.py:224-250) wraps each int() in its own
// try/except that converts failure to ValueError, caught by the outer try -> return False.
// We match that shape: any single bad field fails the whole predicate.
//
// Blob layout: fixarray(7) | false | <timebase> | true | <transfer> | <sync> |
//              fixarray(3)[<cost>, <flex>, <peer>] | fixmap(0)
// Valid: 97 c2 CE6553F100 C3 CD0100 CD2800 93 10 03 12 80  (19 bytes)
// CF FFFFFFFFFFFFFFFF = uint64 UInt64.max (9 bytes); replaces the original uint for each field.

@Test func pnAnnounceRejectsOutOfRangeTimebase() {
    // timebase (CE6553F100, 5B) -> CF FFFFFFFFFFFFFFFF (9B)
    let blob = Data(hexString: "97c2cfffffffffffffffffc3cd0100cd28009310031280")!
    #expect(PNAnnounce.parse(blob) == nil)
    #expect(PNAnnounce.isValid(blob) == false)
}

@Test func pnAnnounceRejectsOutOfRangeTransfer() {
    // perTransferLimit (CD0100, 3B) -> CF FFFFFFFFFFFFFFFF (9B)
    let blob = Data(hexString: "97c2ce6553f100c3cfffffffffffffffffcd28009310031280")!
    #expect(PNAnnounce.parse(blob) == nil)
    #expect(PNAnnounce.isValid(blob) == false)
}

@Test func pnAnnounceRejectsOutOfRangeSync() {
    // perSyncLimit (CD2800, 3B) -> CF FFFFFFFFFFFFFFFF (9B)
    let blob = Data(hexString: "97c2ce6553f100c3cd0100cfffffffffffffffff9310031280")!
    #expect(PNAnnounce.parse(blob) == nil)
    #expect(PNAnnounce.isValid(blob) == false)
}

@Test func pnAnnounceRejectsOutOfRangeStampCost() {
    // targetStampCost (10, 1B) -> CF FFFFFFFFFFFFFFFF (9B)
    let blob = Data(hexString: "97c2ce6553f100c3cd0100cd280093cfffffffffffffffff031280")!
    #expect(PNAnnounce.parse(blob) == nil)
    #expect(PNAnnounce.isValid(blob) == false)
}

@Test func pnAnnounceRejectsOutOfRangeFlexibility() {
    // stampCostFlexibility (03, 1B) -> CF FFFFFFFFFFFFFFFF (9B)
    let blob = Data(hexString: "97c2ce6553f100c3cd0100cd28009310cfffffffffffffffff1280")!
    #expect(PNAnnounce.parse(blob) == nil)
    #expect(PNAnnounce.isValid(blob) == false)
}

@Test func pnAnnounceRejectsOutOfRangePeeringCost() {
    // peeringCost (12, 1B) -> CF FFFFFFFFFFFFFFFF (9B)
    let blob = Data(hexString: "97c2ce6553f100c3cd0100cd2800931003cfffffffffffffffff80")!
    #expect(PNAnnounce.parse(blob) == nil)
    #expect(PNAnnounce.isValid(blob) == false)
}

// MARK: — Cross-validation vectors

@Test func pnAnnounceParsesReference() throws {
    let f = try LXMFPNAnnounceFixtures.load()
    let a = PNAnnounce.parse(Data(hexString: f.packed)!)
    #expect(a != nil)
    if let a {
        #expect(a.timebase == f.timebase)
        #expect(a.nodeState == f.nodeState)
        #expect(a.perTransferLimit == f.perTransferLimit)
        #expect(a.perSyncLimit == f.perSyncLimit)
        #expect(a.targetStampCost == f.targetStampCost)
        #expect(a.stampCostFlexibility == f.stampCostFlexibility)
        #expect(a.peeringCost == f.peeringCost)
        #expect(a.metadata == .map([]))
    }
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
