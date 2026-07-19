import Testing
import Foundation
@testable import ReTiCA

@Test func hexRoundTripsLowercaseNoDelimiters() {
    let data = Data([0x00, 0x0f, 0xa1, 0xff])
    #expect(data.hexString == "000fa1ff")
    #expect(Data(hexString: "000fa1ff") == data)
}

@Test func hexParsingRejectsOddLength() {
    #expect(Data(hexString: "abc") == nil)
}

@Test func hexParsingRejectsNonHex() {
    #expect(Data(hexString: "zz") == nil)
}

@Test func secureRandomReturnsRequestedLengthAndVaries() {
    let a = SecureRandom.bytes(32)
    let b = SecureRandom.bytes(32)
    #expect(a.count == 32)
    #expect(b.count == 32)
    #expect(a != b)
}
