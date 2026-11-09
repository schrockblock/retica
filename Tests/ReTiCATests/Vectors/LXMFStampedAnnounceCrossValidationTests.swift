import Testing
import Foundation
@testable import ReTiCA

// Parsing announce app-data as RNS 1.6.0 / LXMF 1.3.0 put it on the wire.
//
// Fixtures come from generate_lxmf_stamped_announce_fixtures.py, which drives a real LXMRouter and
// Destination.announce(send=False), then records what the reference's own helpers read back.
//
// The costs: reference reports a fractional cost (8.5), and so do we, exactly (`stampCost` and
// `targetStampCost` are Doubles). Every cost in these fixtures is inside reference's emit gate
// (0 < cost < 100), so the delivery parse's narrowing to that gate does not apply here; the
// hostile cases are in LXMFFractionalCostAppDataCrossValidationTests.

private struct DeliveryCase: Decodable {
    let packed: String
    let display_name: String?
    let stamp_cost: Double?
    let supports_compression: Bool
}

private struct PNCase: Decodable {
    let packed: String
    let valid: Bool
    let stamp_cost: Double?
    let transfer_limit: Int?
    let sync_limit: Int?
}

private struct Fixtures: Decodable {
    let delivery_integer_cost: DeliveryCase
    let delivery_fractional_cost: DeliveryCase
    let delivery_no_cost: DeliveryCase
    let delivery_stamp_only: DeliveryCase
    let delivery_post_1_6_2: DeliveryCase
    let pn_fractional_cost: PNCase
    let pn_float_limits: PNCase
    let pn_post_1_6_2: PNCase
    let pn_bad_fractional_element: PNCase
    let delivery_element_3_wins: DeliveryCase
    let delivery_element_3_not_a_number: DeliveryCase
    let pn_element_7_wins: PNCase
    let pn_bad_whole_costs_good_fractional: PNCase

    static func load() throws -> Fixtures {
        let url = Bundle.module.url(forResource: "lxmf_stamped_announce_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }
}

private func expectMatchesReference(_ c: DeliveryCase, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let parsed = try #require(LXMFAnnounceData.parse(Data(hexString: c.packed)!), sourceLocation: sourceLocation)
    #expect(parsed.displayName == c.display_name, sourceLocation: sourceLocation)
    #expect(parsed.stampCost == c.stamp_cost, sourceLocation: sourceLocation)
    #expect(parsed.supportsCompression == c.supports_compression, sourceLocation: sourceLocation)
}

private func expectMatchesReference(_ c: PNCase, sourceLocation: SourceLocation = #_sourceLocation) throws {
    #expect(c.valid, "fixture must be one reference accepts", sourceLocation: sourceLocation)
    let parsed = try #require(PNAnnounce.parse(Data(hexString: c.packed)!), sourceLocation: sourceLocation)
    #expect(parsed.targetStampCost == c.stamp_cost, sourceLocation: sourceLocation)
    #expect(parsed.perTransferLimit == c.transfer_limit, sourceLocation: sourceLocation)
    #expect(parsed.perSyncLimit == c.sync_limit, sourceLocation: sourceLocation)
}

@Test func stampedDeliveryAnnounceParsesLikeReference() throws {
    try expectMatchesReference(Fixtures.load().delivery_integer_cost)
}

@Test func stampedDeliveryAnnounceWithFractionalCostSurfacesExactCost() throws {
    let c = try Fixtures.load().delivery_fractional_cost
    #expect(c.stamp_cost == 8.5)
    try expectMatchesReference(c)
}

@Test func stampedDeliveryAnnounceWithoutCostParsesLikeReference() throws {
    try expectMatchesReference(Fixtures.load().delivery_no_cost)
}

/// No display name means the announce's app_data is the stamp extension alone. `0xC1` is outside
/// the msgpack gate, so this takes the legacy path, and it is invalid UTF-8.
@Test func deliveryAnnounceThatIsOnlyAStampHasNoName() throws {
    let parsed = try #require(LXMFAnnounceData.parse(Data(hexString: Fixtures.load().delivery_stamp_only.packed)!))
    #expect(parsed.displayName == nil)
    #expect(parsed.stampCost == nil)
}

/// The shape LXMF announces after the transition: a float in the integer's slot, no element [3].
@Test func deliveryAnnounceWithFloatInCostSlotParsesLikeReference() throws {
    try expectMatchesReference(Fixtures.load().delivery_post_1_6_2)
}

@Test func stampedPropagationAnnounceParsesLikeReference() throws {
    try expectMatchesReference(Fixtures.load().pn_fractional_cost)
}

/// MeshChatX computes these limits as `bytes / 1000`, so they are floats on the wire.
@Test func propagationAnnounceWithFloatLimitsParsesLikeReference() throws {
    try expectMatchesReference(Fixtures.load().pn_float_limits)
}

@Test func propagationAnnounceWithFloatCostsParsesLikeReference() throws {
    try expectMatchesReference(Fixtures.load().pn_post_1_6_2)
}

/// Reference rejects the whole announce when element [7] is present but malformed.
@Test func propagationAnnounceWithMalformedFractionalElementIsRejected() throws {
    let c = try Fixtures.load().pn_bad_fractional_element
    #expect(c.valid == false)
    #expect(PNAnnounce.parse(Data(hexString: c.packed)!) == nil)
}

/// Reference validates [5] even when [7] supplies the values it will use (LXMF.py:252-258).
@Test func propagationAnnounceWithMalformedWholeCostsIsRejectedEvenWithGoodFractionalCosts() throws {
    let c = try Fixtures.load().pn_bad_whole_costs_good_fractional
    #expect(c.valid == false)
    #expect(PNAnnounce.parse(Data(hexString: c.packed)!) == nil)
}

@Test func deliveryCostComesFromElement3WhenItIsANumber() throws {
    let c = try Fixtures.load().delivery_element_3_wins
    #expect(c.stamp_cost == 7)
    try expectMatchesReference(c)
}

@Test func deliveryCostFallsBackToElement1WhenElement3IsNotANumber() throws {
    let c = try Fixtures.load().delivery_element_3_not_a_number
    #expect(c.stamp_cost == 9)
    try expectMatchesReference(c)
}

@Test func propagationCostComesFromElement7WhenPresent() throws {
    let c = try Fixtures.load().pn_element_7_wins
    #expect(c.stamp_cost == 16.5)
    try expectMatchesReference(c)
}

// MARK: - Hostile values. These floats come from unauthenticated announces.

@Test(arguments: [Double.nan, .infinity, -.infinity, -1, 1e300])
func hostileFloatStampCostIsNotSurfaced(_ cost: Double) {
    let raw = MsgPack.encode(.array([.bin(Data("x".utf8)), .double(cost), .array([.uint(0)])]))
    #expect(LXMFAnnounceData.parse(raw)?.stampCost == nil)
}

/// A hostile COST does not invalidate the announce: reference's validity test only asks `float()` to
/// accept it (LXMF.py:252-258), which it does for all of these (cross-validated case by case in
/// LXMFFractionalCostAppDataCrossValidationTests). The value is surfaced as-is, never trapping, and
/// its consumers gate it. A hostile LIMIT still rejects the announce (a pre-existing narrowing:
/// reference's `int()` accepts -1 and 1e300 there).
@Test(arguments: [Double.nan, .infinity, -.infinity, -1, 1e300])
func hostileFloatPropagationValuesDoNotTrap(_ value: Double) throws {
    let costs = MsgPack.encode(.array([.bool(false), .uint(1), .bool(true), .uint(256), .uint(10240),
                                       .array([.double(value), .uint(3), .uint(18)]), .map([])]))
    let parsed = try #require(PNAnnounce.parse(costs))
    #expect(parsed.targetStampCost == value || (value.isNaN && parsed.targetStampCost.isNaN))
    _ = parsed.packed                                           // re-packing a hostile cost must not trap
    let limit = MsgPack.encode(.array([.bool(false), .uint(1), .bool(true), .double(value), .uint(10240),
                                       .array([.uint(16), .uint(3), .uint(18)]), .map([])]))
    #expect(PNAnnounce.parse(limit) == nil)
}

// MARK: - The strict decoder stays strict for everyone else

@Test func strictDecodeStillRejectsTrailingBytes() {
    let raw = MsgPack.encode(.array([.uint(1)])) + Data([0xC1])
    #expect(MsgPack.decodeValue(raw) == nil)
    #expect(MsgPack.decodeLeadingValue(raw) == .array([.uint(1)]))
}
