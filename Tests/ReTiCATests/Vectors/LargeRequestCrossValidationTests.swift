import Testing
import Foundation
@testable import ReTiCA

@Test func swiftRequestAdvertisementMatchesRns() throws {
    let f = try VectorFixtures.load()
    let adv = ResourceAdvertisement(
        transferSize: 96, dataSize: 40, numberOfParts: 4,
        hash: Data(hexString: f.rrResHash)!, randomHash: Data(hexString: f.rrResRandomHash)!,
        originalHash: Data(hexString: f.rrResHash)!, segmentIndex: 1, totalSegments: 1,
        requestID: Data(hexString: f.rrRequestId)!, flags: 0x09,   // e=1 (0x01), u=1 (0x08): is_request
        hashmap: Data(hexString: f.rrResHashmap4)!)
    #expect(adv.pack() == Data(hexString: f.rrReqAdv))
}

@Test func swiftResponseAdvertisementMatchesRns() throws {
    let f = try VectorFixtures.load()
    let adv = ResourceAdvertisement(
        transferSize: 96, dataSize: 40, numberOfParts: 4,
        hash: Data(hexString: f.rrResHash)!, randomHash: Data(hexString: f.rrResRandomHash)!,
        originalHash: Data(hexString: f.rrResHash)!, segmentIndex: 1, totalSegments: 1,
        requestID: Data(hexString: f.rrRequestId)!, flags: 0x11,   // e=1 (0x01), p=1 (0x10): is_response
        hashmap: Data(hexString: f.rrResHashmap4)!)
    #expect(adv.pack() == Data(hexString: f.rrRespAdv))
}
