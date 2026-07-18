import Testing
import Foundation
@testable import ReTiCA

@Test func padAddsBytesEqualToPadCount() {
    let padded = PKCS7.pad(Data([0x01, 0x02, 0x03])) // 3 bytes -> +13
    #expect(padded.count == 16)
    #expect(Array(padded.suffix(13)) == Array(repeating: 13, count: 13))
}

@Test func padFullBlockAddsWholeBlock() {
    let padded = PKCS7.pad(Data(repeating: 0xaa, count: 16))
    #expect(padded.count == 32)
    #expect(Array(padded.suffix(16)) == Array(repeating: 16, count: 16))
}

@Test func unpadReversesPad() throws {
    let original = Data([0x09, 0x08, 0x07, 0x06, 0x05])
    let restored = try PKCS7.unpad(PKCS7.pad(original))
    #expect(restored == original)
}

@Test func unpadRejectsPaddingLongerThanBlock() {
    #expect(throws: PKCS7Error.self) {
        _ = try PKCS7.unpad(Data(repeating: 0x11, count: 16)) // last byte 0x11 = 17 > 16
    }
}
