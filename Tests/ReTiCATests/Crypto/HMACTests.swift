import Testing
import Foundation
@testable import ReTiCA

// RFC 4231 Test Case 2: key="Jefe", data="what do ya want for nothing?"
@Test func hmacSHA256MatchesRFC4231Case2() {
    let mac = Crypto.hmacSHA256(key: Data("Jefe".utf8),
                                Data("what do ya want for nothing?".utf8))
    #expect(mac.hexString == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    #expect(mac.count == 32)
}
