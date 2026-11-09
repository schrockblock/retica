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

// The three COST fields are different: reference reads them with `float()`, which accepts
// UInt64.max, so the announce is VALID there (lxmf_fractional_cost_app_data_fixtures.json, pn_parse:
// `valid: true`, `stamp_cost: 18446744073709551615`). They must parse, not trap, and surface the
// value for the consumer to gate.

@Test func pnAnnounceAcceptsHugeStampCostAsReferenceDoes() throws {
    // targetStampCost (10, 1B) -> CF FFFFFFFFFFFFFFFF (9B)
    let blob = Data(hexString: "97c2ce6553f100c3cd0100cd280093cfffffffffffffffff031280")!
    let parsed = try #require(PNAnnounce.parse(blob))
    #expect(parsed.targetStampCost == Double(UInt64.max))
}

@Test func pnAnnounceAcceptsHugeFlexibilityAsReferenceDoes() throws {
    // stampCostFlexibility (03, 1B) -> CF FFFFFFFFFFFFFFFF (9B)
    let blob = Data(hexString: "97c2ce6553f100c3cd0100cd28009310cfffffffffffffffff1280")!
    let parsed = try #require(PNAnnounce.parse(blob))
    #expect(parsed.stampCostFlexibility == Double(UInt64.max))
}

@Test func pnAnnounceAcceptsHugePeeringCostAsReferenceDoes() throws {
    // peeringCost (12, 1B) -> CF FFFFFFFFFFFFFFFF (9B)
    let blob = Data(hexString: "97c2ce6553f100c3cd0100cd2800931003cfffffffffffffffff80")!
    let parsed = try #require(PNAnnounce.parse(blob))
    #expect(parsed.peeringCost == Double(UInt64.max))
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

/// This fixture is LXMF 1.1.0's seven-element layout, which we still parse (above) but no longer
/// emit: we write LXMF 1.3.0's eight elements, byte-for-byte against the genuine
/// `get_propagation_node_app_data` in LXMFFractionalCostAppDataCrossValidationTests. What carries
/// over from 1.1.0 is the first seven elements, which 1.3.0 still writes the same way for integer
/// costs: [5] is the ceilings, and they are the integers themselves here.
@Test func pnAnnouncePackKeepsTheSevenElementPrefixOfReference110() throws {
    let f = try LXMFPNAnnounceFixtures.load()
    let a = PNAnnounce(timebase: f.timebase, nodeState: f.nodeState,
                       perTransferLimit: f.perTransferLimit, perSyncLimit: f.perSyncLimit,
                       targetStampCost: f.targetStampCost, stampCostFlexibility: f.stampCostFlexibility,
                       peeringCost: f.peeringCost)
    guard case let .array(ours)? = MsgPack.decodeValue(a.packed),
          case let .array(reference)? = MsgPack.decodeValue(Data(hexString: f.packed)!)
    else { Issue.record("undecodable"); return }
    #expect(ours.count == 8)
    #expect(Array(ours.prefix(7)) == reference)
}

@Test func pnAnnounceValidityMatchesReference() throws {
    let f = try LXMFPNAnnounceFixtures.load()
    #expect(PNAnnounce.isValid(Data(hexString: f.packed)!) == true)
    #expect(PNAnnounce.isValid(Data(hexString: f.invalidPacked)!) == false)   // 6-element → invalid, agrees with genuine
}
