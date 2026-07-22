import Testing
import Foundation
@testable import ReTiCA

@Test func swiftMsgpackArrayMatchesUmsgpack() throws {
    let f = try VectorFixtures.load()
    let hashmap = Data(hexString: f.hmuHashmap)!
    // Our MsgPack must encode [1, hashmap] byte-identically to genuine umsgpack.
    let built = MsgPack.encode(.array([.uint(1), .bin(hashmap)]))
    #expect(built == Data(hexString: f.hmuMsgpack))
}
