import Testing
import Foundation
@testable import ReTiCA

// Reading RNS 1.6.0 stamped announces as the reference does (Identity.py:840-873).
//
// Fixtures come from Vectors/generate_stamped_announce_packet_fixtures.py: every payload is a real
// Destination._announce(send=False) packet, and every expectation is what the reference's own
// validate_announce recorded for it (app data kept, stamp, stamp value, link cost).

private struct StampedAnnounceCase: Decodable {
    let destination_hash: String
    let context_flag: Bool
    let payload: String
    let app_data: String?
    let stamp: String?
    let stamp_value: Double?
    let lr_cost: Double?

    var destinationHash: Data { Data(hexString: destination_hash)! }
    var payloadBytes: Data { Data(hexString: payload)! }
    var appDataBytes: Data? { app_data.map { Data(hexString: $0)! } }
    var stampBytes: Data? { stamp.map { Data(hexString: $0)! } }
}

private struct CostCase: Decodable {
    let bytes: String
    let fp: Int
    let cost: Double
}

private struct Fixtures: Decodable {
    let required_value: Double
    let msgpack: String
    let cases: [String: StampedAnnounceCase]
    let cost_from_bytes: [CostCase]

    subscript(_ name: String) -> StampedAnnounceCase { cases[name]! }

    static func load() throws -> Fixtures {
        let url = Bundle.module.url(forResource: "stamped_announce_packet_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }
}

private func parse(_ c: StampedAnnounceCase,
                   requiredStampValue: Double = NetworkStamp.defaultDestinationCost) -> Announce.Parsed? {
    Announce.parse(payload: c.payloadBytes, destinationHash: c.destinationHash,
                   contextFlagSet: c.context_flag, requiredStampValue: requiredStampValue)
}

/// Every field the reference recorded for this packet.
private func expectMatchesReference(_ c: StampedAnnounceCase,
                                    sourceLocation: SourceLocation = #_sourceLocation) throws {
    let parsed = try #require(parse(c), sourceLocation: sourceLocation)
    #expect(parsed.appData == c.appDataBytes, sourceLocation: sourceLocation)
    #expect(parsed.stamp == c.stampBytes, sourceLocation: sourceLocation)
    #expect(parsed.stampValue == c.stamp_value, sourceLocation: sourceLocation)
    #expect(parsed.linkCost == c.lr_cost, sourceLocation: sourceLocation)
}

@Test func theFixturesDemandTheDefaultDestinationCost() throws {
    let f = try Fixtures.load()
    #expect(f.required_value == NetworkStamp.defaultDestinationCost)
    #expect(NetworkStamp.extensionLength == 18)
}

@Test func costFromBytesMatchesReference() throws {
    let f = try Fixtures.load()
    for c in f.cost_from_bytes {
        let bytes = Data(hexString: c.bytes)!
        #expect(NetworkStamp.cost(fromBytes: bytes) == c.cost, "\(c.bytes)")
    }
    // Only two bytes are a cost; anything else is not, rather than a trap or a guess.
    #expect(NetworkStamp.cost(fromBytes: Data()) == nil)
    #expect(NetworkStamp.cost(fromBytes: Data([0x03])) == nil)
    #expect(NetworkStamp.cost(fromBytes: Data([0x03, 0x40, 0x00])) == nil)
    // A slice that does not start at index 0 still reads its own first two bytes.
    #expect(NetworkStamp.cost(fromBytes: Data([0xFF, 0x03, 0x40]).dropFirst()) == 3.25)
}

@Test func aStampMeetingTheCostIsStrippedFromAppData() throws {
    let f = try Fixtures.load()
    let msgpack = Data(hexString: f.msgpack)!
    for name in ["stripped", "ratchet_stripped"] {
        let c = f[name]
        let parsed = try #require(parse(c), "\(name)")
        #expect(parsed.appData == msgpack, "\(name)")
        #expect(parsed.linkCost == 3.25, "\(name)")
        #expect(parsed.stamp?.count == NetworkStamp.stampLength, "\(name)")
        #expect(parsed.stampValue.map { $0 >= NetworkStamp.defaultDestinationCost } == true, "\(name)")
        try expectMatchesReference(c)
    }
    #expect(try #require(parse(f["ratchet_stripped"])).ratchet != nil)
}

@Test func anAnnounceThatIsOnlyAStampHasNilAppData() throws {
    let f = try Fixtures.load()
    let c = f["stamp_only"]
    #expect(c.payloadBytes.count == 64 + 10 + 10 + 64 + 18)
    let parsed = try #require(parse(c))
    #expect(parsed.appData == nil)
    #expect(parsed.linkCost == 3.25)
    try expectMatchesReference(c)
}

@Test func aStampBelowTheCostStaysInAppDataAndItsLinkCostIsIgnored() throws {
    let f = try Fixtures.load()
    let c = f["below_cost"]
    let parsed = try #require(parse(c))
    // The whole wire app data, extension included, is what the LXMF parsers then see.
    #expect(parsed.appData == c.payloadBytes.suffix(Data(hexString: f.msgpack)!.count + 18))
    #expect(parsed.appData?.count == 9 + 18)
    #expect(parsed.linkCost == nil)
    let value = try #require(parsed.stampValue)
    #expect(value < NetworkStamp.defaultDestinationCost)
    #expect(value == c.stamp_value)
    #expect(parsed.stamp == c.stampBytes)
    try expectMatchesReference(c)
}

@Test func appDataEndingLikeAMarkerSurvivesUntouched() throws {
    let f = try Fixtures.load()
    let c = f["marker_invalid_stamp"]
    let wireAppData = Data(c.payloadBytes.suffix(9 + 18))
    #expect(wireAppData[wireAppData.startIndex + 9] == NetworkStamp.extensionMarker)
    let parsed = try #require(parse(c))
    #expect(parsed.appData == wireAppData)
    #expect(parsed.linkCost == nil)
    try expectMatchesReference(c)
}

@Test func anExtendedFlagOrOverCapCostIsNotTreatedAsAStamp() throws {
    let f = try Fixtures.load()
    // Each of these carries the real, valid value-27 stamp; only the named property stops it.
    for name in ["extended_flag", "over_cap", "wrong_marker"] {
        let c = f[name]
        let parsed = try #require(parse(c), "\(name)")
        #expect(parsed.appData == Data(c.payloadBytes.suffix(9 + 18)), "\(name)")
        #expect(parsed.stamp == nil, "\(name)")
        #expect(parsed.stampValue == nil, "\(name)")
        #expect(parsed.linkCost == nil, "\(name)")
        try expectMatchesReference(c)
    }
    // A cost of exactly STAMP_COST_CAP is known format, and the flags byte is not read.
    let atCap = try #require(parse(f["at_cap"]))
    #expect(atCap.linkCost == Double(NetworkStamp.stampCostCap))
    #expect(atCap.appData == Data(hexString: f.msgpack)!)
    try expectMatchesReference(f["at_cap"])
    let flags = try #require(parse(f["nonzero_flags"]))
    #expect(flags.linkCost == 3.25)
    #expect(flags.appData == Data(hexString: f.msgpack)!)
    try expectMatchesReference(f["nonzero_flags"])
}

@Test func theSignatureCoversTheExtension() throws {
    let f = try Fixtures.load()
    let c = f["stripped"]
    // Stripping happens after the signature is checked over the full bytes, so it still validates.
    #expect(parse(c) != nil)
    // Every byte of the extension is signed: change any one and the announce is rejected.
    let payload = c.payloadBytes
    for offset in 1...18 {
        var tampered = payload
        let i = tampered.endIndex - offset
        tampered[i] ^= 0x01
        #expect(Announce.parse(payload: tampered, destinationHash: c.destinationHash,
                               contextFlagSet: false) == nil, "offset -\(offset)")
    }
    // Dropping the extension also breaks it: the signature is not over the stripped app data.
    #expect(Announce.parse(payload: payload.dropLast(18), destinationHash: c.destinationHash,
                           contextFlagSet: false) == nil)
}

@Test func theRequiredValueIsTheCallers() throws {
    let f = try Fixtures.load()
    let msgpack = Data(hexString: f.msgpack)!
    // A value-27.7 stamp does not meet 28: kept in app data, cost ignored, value still reported.
    let strict = try #require(parse(f["stripped"], requiredStampValue: 28))
    #expect(strict.appData == Data(f["stripped"].payloadBytes.suffix(9 + 18)))
    #expect(strict.linkCost == nil)
    #expect(strict.stampValue == f["stripped"].stamp_value)
    // A value-10.8 stamp meets 10: stripped, and the cost it carries is read.
    let lenient = try #require(parse(f["below_cost"], requiredStampValue: 10))
    #expect(lenient.appData == msgpack)
    #expect(lenient.linkCost == 12.5)
}

@Test func anUnstampedAnnounceReportsNoStamp() throws {
    let id = Identity()
    let nameHash = Destination.nameHash(appName: "app", aspects: ["svc"])
    let destHash = Data(Crypto.fullHash(nameHash + id.hash).prefix(16))
    let randomHash = Announce.randomHash(now: 1, randomPrefix: Data(repeating: 0x01, count: 5))
    // 17 bytes ending like an extension's tail is too short to be one.
    let appData = Data([NetworkStamp.extensionMarker]) + Data(repeating: 0, count: 14) + Data([0x40, 0x03])
    let payload = Announce.buildPayload(identity: id, destinationHash: destHash, nameHash: nameHash,
                                        randomHash: randomHash, appData: appData)
    let parsed = try #require(Announce.parse(payload: payload, destinationHash: destHash, contextFlagSet: false))
    #expect(parsed.appData == appData)
    #expect(parsed.stamp == nil)
    #expect(parsed.stampValue == nil)
    #expect(parsed.linkCost == nil)
}
