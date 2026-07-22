import Testing
import Foundation
@testable import ReTiCANode
import ReTiCA

@Suite struct RequestPolicyTests {
    let idA = Identity()          // fresh keypair; .hash = truncatedHash(publicKey), 16 bytes
    let idB = Identity()

    @Test func noneRejectsEverything() {
        #expect(isAllowed(.none, idA) == false)
        #expect(isAllowed(.none, nil) == false)
    }

    @Test func allAcceptsWithAndWithoutIdentity() {
        #expect(isAllowed(.all, idA) == true)
        #expect(isAllowed(.all, nil) == true)
    }

    @Test func listAcceptsOnlyListedIdentity() {
        #expect(isAllowed(.list([idA.hash]), idA) == true)
        #expect(isAllowed(.list([idA.hash]), idB) == false)
        #expect(isAllowed(.list([idA.hash]), nil) == false)
        #expect(isAllowed(.list([]), idA) == false)
    }

    @Test func responderTestValueDeclines() async {
        let r = RequestResponder.testValue
        #expect(await r("svc/x", Data(), idA) == nil)
    }

    @Test func customResponderDispatchesByPath() async {
        let r = RequestResponder { path, data, _ in path == "echo" ? data : nil }
        #expect(await r("echo", Data([1, 2, 3]), nil) == Data([1, 2, 3]))
        #expect(await r("other", Data([1, 2, 3]), nil) == nil)
    }
}
