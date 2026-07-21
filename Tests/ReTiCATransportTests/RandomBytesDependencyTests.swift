import Testing
import Foundation
@testable import ReTiCATransport

@Test func randomBytesTestValueIsDeterministic() {
    let g = RandomBytesGenerator.testValue
    #expect(g(4) == Data([0, 1, 2, 3]))
    #expect(g(8) == Data([0, 1, 2, 3, 4, 5, 6, 7]))
}

@Test func randomBytesLiveReturnsRequestedCount() {
    let g = RandomBytesGenerator.liveValue
    #expect(g(4).count == 4)
    #expect(g(16).count == 16)
}
