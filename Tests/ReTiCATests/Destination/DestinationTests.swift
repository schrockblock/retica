import Testing
import Foundation
@testable import ReTiCA

@Test func expandNameBuildsDottedNameWithIdentityHex() {
    let n = Destination.expandName(appName: "app", aspects: ["a", "b"], identityHexHash: "deadbeef")
    #expect(n == "app.a.b.deadbeef")
    #expect(Destination.expandName(appName: "app", aspects: [], identityHexHash: nil) == "app")
}

@Test func nameHashIsTenBytesOfNameWithoutIdentity() {
    let nh = Destination.nameHash(appName: "app", aspects: ["a"])
    #expect(nh.count == 10)
    #expect(nh == Crypto.fullHash(Data("app.a".utf8)).prefix(10))
}

@Test func destinationHashMatchesConstruction() {
    let idHash = Data(repeating: 0x44, count: 16)
    let expected = Crypto.fullHash(Crypto.fullHash(Data("app.a".utf8)).prefix(10) + idHash).prefix(16)
    #expect(Destination.hash(identityHash: idHash, appName: "app", aspects: ["a"]) == expected)
}

@Test func plainDestinationHashHasNoIdentityMaterial() {
    let expected = Crypto.fullHash(Crypto.fullHash(Data("app".utf8)).prefix(10)).prefix(16)
    #expect(Destination.hash(identityHash: nil, appName: "app", aspects: []) == expected)
}

@Test func initRejectsDotsAndBadTypeCombos() {
    let id = Identity()
    #expect(Destination(kind: .single, direction: .out, appName: "a.b", aspects: [],
                        identity: id, groupKey: nil) == nil)
    #expect(Destination(kind: .single, direction: .out, appName: "app", aspects: ["x.y"],
                        identity: id, groupKey: nil) == nil)
    #expect(Destination(kind: .single, direction: .out, appName: "app", aspects: [],
                        identity: nil, groupKey: nil) == nil) // SINGLE needs identity
    #expect(Destination(kind: .plain, direction: .out, appName: "app", aspects: [],
                        identity: id, groupKey: nil) == nil) // PLAIN forbids identity
    #expect(Destination(kind: .group, direction: .out, appName: "app", aspects: [],
                        identity: nil, groupKey: nil) == nil) // GROUP needs key
}

@Test func singleDestinationEncryptDecryptRoundTrips() {
    let id = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: id, groupKey: nil)!
    #expect(dest.hash == Destination.hash(identityHash: id.hash, appName: "app", aspects: ["svc"]))
    let pt = Data("single secret".utf8)
    #expect(dest.decrypt(dest.encrypt(pt)) == pt)
}

@Test func groupDestinationUsesTokenKey() {
    let key = Data(repeating: 0x5A, count: 64)
    let dest = Destination(kind: .group, direction: .in, appName: "app", aspects: [],
                           identity: nil, groupKey: key)!
    let pt = Data("group secret".utf8)
    #expect(dest.decrypt(dest.encrypt(pt)) == pt)
}

// A GROUP destination whose key Token cannot use must not be constructible — otherwise
// encrypt() falls through and emits CLEARTEXT (Destination.swift:78), where reference raises
// (RNS/Destination.py:620).
@Test func groupDestinationRejectsUnusableKey() {
    for badLength in [0, 15, 16, 24, 33, 63, 65] {
        let d = Destination(kind: .group, direction: .in, appName: "t", aspects: ["g"],
                            groupKey: Data(repeating: 0x11, count: badLength))
        #expect(d == nil, "group key of \(badLength) bytes must be rejected")
    }
    for goodLength in [32, 64] {
        let d = Destination(kind: .group, direction: .in, appName: "t", aspects: ["g"],
                            groupKey: Data(repeating: 0x11, count: goodLength))
        #expect(d != nil)
        // And it must actually encrypt, not pass through.
        let plaintext = Data([0xDE, 0xAD])
        #expect(d!.encrypt(plaintext) != plaintext)
    }
}

@Test func plainDestinationIsPassthrough() {
    let dest = Destination(kind: .plain, direction: .out, appName: "app", aspects: [],
                           identity: nil, groupKey: nil)!
    let pt = Data("clear".utf8)
    #expect(dest.encrypt(pt) == pt)
    #expect(dest.decrypt(pt) == pt)
}
