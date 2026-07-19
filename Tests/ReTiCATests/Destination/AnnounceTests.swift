import Testing
import Foundation
@testable import ReTiCA

private func announceDestHash(_ id: Identity, nameHash: Data) -> Data {
    Crypto.fullHash(nameHash + id.hash).prefix(16)
}

@Test func buildAndParseRoundTripNoRatchetNoAppData() {
    let id = Identity()
    let nameHash = Destination.nameHash(appName: "app", aspects: ["svc"])
    let destHash = announceDestHash(id, nameHash: nameHash)
    let randomHash = Announce.randomHash(now: 1_700_000_000, randomPrefix: Data(repeating: 0xAB, count: 5))
    let payload = Announce.buildPayload(identity: id, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash)
    let parsed = Announce.parse(payload: payload, destinationHash: destHash, contextFlagSet: false)
    #expect(parsed != nil)
    #expect(parsed?.publicKey == id.publicKey)
    #expect(parsed?.nameHash == nameHash)
    #expect(parsed?.randomHash == randomHash)
    #expect(parsed?.ratchet == nil)
    #expect(parsed?.appData == nil)
    #expect(parsed?.identity.hash == id.hash)
}

@Test func buildAndParseRoundTripWithRatchetAndAppData() {
    let id = Identity()
    let nameHash = Destination.nameHash(appName: "app", aspects: [])
    let destHash = announceDestHash(id, nameHash: nameHash)
    let randomHash = Announce.randomHash(now: 1, randomPrefix: Data(repeating: 0x01, count: 5))
    let ratchet = Data(repeating: 0x2C, count: 32)
    let appData = Data("hello-app".utf8)
    let payload = Announce.buildPayload(identity: id, destinationHash: destHash, nameHash: nameHash,
                                        randomHash: randomHash, ratchet: ratchet, appData: appData)
    let parsed = Announce.parse(payload: payload, destinationHash: destHash, contextFlagSet: true)
    #expect(parsed?.ratchet == ratchet)
    #expect(parsed?.appData == appData)
}

@Test func parseRejectsTamperedSignature() {
    let id = Identity()
    let nameHash = Destination.nameHash(appName: "app", aspects: [])
    let destHash = announceDestHash(id, nameHash: nameHash)
    let randomHash = Announce.randomHash(now: 5, randomPrefix: Data(repeating: 0x00, count: 5))
    var payload = Announce.buildPayload(identity: id, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash)
    payload[payload.count - 1] ^= 0xFF // corrupt the signature (last field, no app_data)
    #expect(Announce.parse(payload: payload, destinationHash: destHash, contextFlagSet: false) == nil)
}

@Test func parseRejectsDestinationHashMismatch() {
    let id = Identity()
    let nameHash = Destination.nameHash(appName: "app", aspects: [])
    let destHash = announceDestHash(id, nameHash: nameHash)
    let randomHash = Announce.randomHash(now: 5, randomPrefix: Data(repeating: 0x00, count: 5))
    let payload = Announce.buildPayload(identity: id, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash)
    let wrongHash = Data(repeating: 0xEE, count: 16)
    #expect(Announce.parse(payload: payload, destinationHash: wrongHash, contextFlagSet: false) == nil)
}

@Test func randomHashIsPrefixPlusBigEndianTime() {
    let rh = Announce.randomHash(now: 0x0102030405, randomPrefix: Data([1, 2, 3, 4, 5, 6, 7]))
    #expect(rh.count == 10)
    #expect(rh.prefix(5) == Data([1, 2, 3, 4, 5]))              // prefix truncated to 5
    #expect(rh.suffix(5) == Data([0x01, 0x02, 0x03, 0x04, 0x05])) // 5-byte big-endian time
}
