import Testing
import Foundation
@testable import ReTiCA

/// Our LXStamper reproduces genuine lxmf 1.1.0 LXStamper: the deterministic workblock (pinned via its
/// full_hash), stamp validity, and stamp value; and our own generateStamp produces valid stamps.
@Test func lxStamperWorkblockAndValidateMatchReference() throws {
    let f = try LXMFStampFixtures.load()
    let messageId = Data(hexString: f.messageId)!
    let stamp = Data(hexString: f.stamp)!
    let wb = LXStamper.stampWorkblock(material: messageId)
    #expect(Crypto.fullHash(wb) == Data(hexString: f.workblockHash)!)          // workblock byte-parity
    #expect(LXStamper.stampValid(stamp: stamp, targetCost: f.stampCost, workblock: wb) == true)
    // lxmf 1.1.0 reported the leading-zero count; the 1.3.0 value adds a fraction on top of it.
    #expect(Int(LXStamper.stampValue(workblock: wb, stamp: stamp).rounded(.down)) == f.stampValue)
}

@Test func lxStamperGeneratesValidStamp() async throws {
    // Low cost keeps the search + 768 KB workblock cheap.
    let messageId = Crypto.fullHash(Data("stamp-gen-material".utf8))
    let cost = 4
    let stamp = await LXStamper.generateStamp(messageId: messageId, targetCost: cost)!
    #expect(stamp.count == LXStamper.stampSize)
    let wb = LXStamper.stampWorkblock(material: messageId)
    #expect(LXStamper.stampValid(stamp: stamp, targetCost: cost, workblock: wb) == true)
}

@Test func generatePnStampRoundTripsValidatePnStamp() async {
    let lxmData = Data("pn-stamp-gen-material".utf8)
    let transientId = Crypto.fullHash(lxmData)
    let stamp = await LXStamper.generatePnStamp(transientId: transientId, targetCost: 4)!
    #expect(stamp.count == LXStamper.stampSize)
    let result = LXStamper.validatePnStamp(transientData: lxmData + stamp, targetCost: 4)
    #expect(result != nil)
    #expect(result?.transientId == transientId)
}
