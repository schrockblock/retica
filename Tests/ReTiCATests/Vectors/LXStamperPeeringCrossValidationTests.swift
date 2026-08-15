import Testing
import Foundation
@testable import ReTiCA

@Test func peeringStampConstantsMatchReference() throws {
    let f = try LXMFPeeringFixtures.load()
    #expect(LXStamper.workblockExpandRoundsPeering == f.workblockExpandRoundsPeering)
    #expect(LXStamper.workblockExpandRoundsPN == f.workblockExpandRoundsPN)
}

@Test func validatePeeringKeyMatchesReference() throws {
    let f = try LXMFPeeringFixtures.load()
    let peeringId = Data(hexString: f.peeringId)!
    let key = Data(hexString: f.peeringKey)!
    #expect(LXStamper.validatePeeringKey(peeringId: peeringId, peeringKey: key, targetCost: f.peeringCost) == true)
    // Workblock byte-parity (short 25-round).
    let wb = LXStamper.stampWorkblock(material: peeringId, expandRounds: LXStamper.workblockExpandRoundsPeering)
    #expect(Crypto.fullHash(wb) == Data(hexString: f.peeringWorkblockHash)!)
    // A tampered key does not validate.
    var bad = Array(key); bad[0] ^= 0x01
    #expect(LXStamper.validatePeeringKey(peeringId: peeringId, peeringKey: Data(bad), targetCost: f.peeringCost) == false)
}

@Test func validatePnStampMatchesReference() throws {
    let f = try LXMFPeeringFixtures.load()
    let transientData = Data(hexString: f.transientData)!
    let result = LXStamper.validatePnStamp(transientData: transientData, targetCost: f.pnCost)
    #expect(result != nil)
    #expect(result?.transientId == Data(hexString: f.transientId)!)
    #expect(result?.lxmfData == Data(hexString: f.lxmfData)!)
    #expect(result?.value == f.pnValue)
    // Workblock byte-parity (medium 1000-round), keyed on the recovered transient_id.
    let wb = LXStamper.stampWorkblock(material: Data(hexString: f.transientId)!,
                                      expandRounds: LXStamper.workblockExpandRoundsPN)
    #expect(Crypto.fullHash(wb) == Data(hexString: f.pnWorkblockHash)!)
    // Too-short data → nil; tampered stamp → nil.
    #expect(LXStamper.validatePnStamp(transientData: Data(repeating: 0, count: 10), targetCost: f.pnCost) == nil)
    var tampered = Array(transientData); tampered[tampered.count - 1] ^= 0x01
    #expect(LXStamper.validatePnStamp(transientData: Data(tampered), targetCost: f.pnCost) == nil)
}

@Test func lxStamperGeneratePeeringKeyValidatesAtTargetCost() async {
    let peeringId = Data((0..<32).map { UInt8($0) })
    let key = await LXStamper.generatePeeringKey(peeringId: peeringId, targetCost: 16)!   // fast sub-second search
    #expect(LXStamper.validatePeeringKey(peeringId: peeringId, peeringKey: key, targetCost: 16))
    // Cost 0: any generated key validates trivially.
    let key0 = await LXStamper.generatePeeringKey(peeringId: peeringId, targetCost: 0)!
    #expect(LXStamper.validatePeeringKey(peeringId: peeringId, peeringKey: key0, targetCost: 0))
}
