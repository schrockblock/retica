import Testing
import Foundation
@testable import ReTiCA

/// LXMF 1.3.0 refuses non-expanded workblock stamps (generate_lxmf_non_expanded_stamp_fixtures.py).
/// RNS.Stamps.generate_stamp(material, cost, no_expand=True, size=32) searches over the raw material
/// as the workblock; LXMessage.validate_stamp, LXStamper.validate_pn_stamp and
/// LXStamper.validate_peering_key all expand the workblock, so none of them accepts such a stamp at the
/// cost it was generated for. ReTiCA pins that rejection: accepting them would make every stamp we
/// enforce far cheaper to forge, while a reference 1.3.0 peer still rejects them. Trigger to revisit:
/// a released LXMF whose generate_stamp callers pass no_expand=True.

private struct MessageCase: Decodable {
    let packed: String
    let hash: String
    let stamp: String
    let expanded_value: Double
    let reference_validate_stamp: Bool
    let non_expanded_stamp_valid: Bool
}

private struct PNCase: Decodable {
    let lxm_data: String
    let transient_id: String
    let stamp: String
    let expanded_value: Double
    let reference_validate_pn_stamp_accepts: Bool
    let non_expanded_stamp_valid: Bool
}

private struct PeeringCase: Decodable {
    let peering_id: String
    let stamp: String
    let expanded_value: Double
    let reference_validate_peering_key: Bool
    let non_expanded_stamp_valid: Bool
}

private struct Fixtures: Decodable {
    let cost: Double
    let message: MessageCase
    let pn: PNCase
    let peering: PeeringCase

    static func load() throws -> Fixtures {
        let url = Bundle.module.url(forResource: "lxmf_non_expanded_stamp_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }
}

private func hex(_ s: String) -> Data { Data(hexString: s)! }

/// All three validators refuse the non-expanded stamp at the cost it was generated for, as LXMF 1.3.0 does.
@Test func nonExpandedStampsRejectedLikeLXMF130() throws {
    let f = try Fixtures.load()
    #expect(f.cost == 12)

    // Reference verdicts, recorded by the generator.
    #expect(!f.message.reference_validate_stamp)
    #expect(!f.pn.reference_validate_pn_stamp_accepts)
    #expect(!f.peering.reference_validate_peering_key)
    // The expanded value is below the cost, so the rejection is not an accidental expanded pass.
    #expect(f.message.expanded_value < f.cost)
    #expect(f.pn.expanded_value < f.cost)
    #expect(f.peering.expanded_value < f.cost)

    // Delivery stamp, on a message unpacked from the reference's bytes.
    let unpacked = try #require(LXMessage.unpack(hex(f.message.packed)))
    #expect(unpacked.hash == hex(f.message.hash))
    let stamped = unpacked.withStamp(hex(f.message.stamp))
    #expect(!stamped.validateStamp(targetCost: f.cost))
    #expect(!stamped.validateStamp(targetCost: f.cost, tickets: [Data(repeating: 1, count: 16)]))

    // Propagation-node stamp.
    let transient = hex(f.pn.lxm_data) + hex(f.pn.stamp)
    #expect(LXStamper.validatePnStamp(transientData: transient, targetCost: f.cost) == nil)

    // Peering key.
    #expect(!LXStamper.validatePeeringKey(peeringId: hex(f.peering.peering_id),
                                          peeringKey: hex(f.peering.stamp), targetCost: f.cost))
}

/// The same stamps ARE valid against the non-expanded workblock (the material itself) at the cost, so the
/// rejection above is about the workblock and not a malformed stamp or an unreachable cost.
@Test func fixtureStampIsValidNonExpanded() throws {
    let f = try Fixtures.load()
    #expect(f.message.non_expanded_stamp_valid && f.pn.non_expanded_stamp_valid && f.peering.non_expanded_stamp_valid)
    #expect(LXStamper.stampValid(stamp: hex(f.message.stamp), targetCost: f.cost, workblock: hex(f.message.hash)))
    #expect(LXStamper.stampValid(stamp: hex(f.pn.stamp), targetCost: f.cost, workblock: hex(f.pn.transient_id)))
    #expect(LXStamper.stampValid(stamp: hex(f.peering.stamp), targetCost: f.cost, workblock: hex(f.peering.peering_id)))
    // The PN transient id is what the validator derives from the lxm_data.
    #expect(Crypto.fullHash(hex(f.pn.lxm_data)) == hex(f.pn.transient_id))
}
