import Testing
import Foundation
import CryptoKit
@testable import ReTiCA

// RNS 1.6.0 network-stamp arithmetic (RNS/Stamps.py) against the reference itself.
//
// Fixtures come from generate_network_stamp_fixtures.py, which calls the genuine cost_to_fp,
// target_from_fp, stamp_value, stamp_valid, generate_stamp and generate_stamped_key. Nothing here is
// hand-computed. Stamps the reference generated are the only ones guaranteed valid at a real cost,
// so validity and value are checked against those plus random and near-boundary stamps.

private struct FPCase: Decodable {
    let cost: Double
    let fp: Int
    let target_hex: String
    let target_saturated: Bool
}

private struct GridTarget: Decodable {
    let target_hex: String
    let target_saturated: Bool
}

private struct StampCase: Decodable {
    let material: String
    let stamp: String
    let cost: Double
    let value: Double
    let valid: Bool
}

private struct KeyCase: Decodable {
    let material: String
    let `private`: String
    let `public`: String
    let cost: Double
    let value: Double
    let valid: Bool
}

private struct Fixtures: Decodable {
    let tab: [Int]
    let tab_digest: String
    let stamp_length: Int
    let stamp_cost_cap: Int
    let fp_cases: [FPCase]
    let grid_targets: [String: GridTarget]
    let value_cases: [StampCase]
    let generated_cases: [StampCase]
    let low_value_cases: [StampCase]
    let boundary_cases: [StampCase]
    let edge_validity_cases: [StampCase]
    let key_cases: [KeyCase]

    var allStampCases: [StampCase] {
        value_cases + generated_cases + low_value_cases + boundary_cases + edge_validity_cases
    }

    static func load() throws -> Fixtures {
        let url = Bundle.module.url(forResource: "network_stamp_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }
}

private let saturated = Data(repeating: 0xFF, count: 32)

private func expectedTarget(hex: String, saturated isSaturated: Bool) -> Data {
    isSaturated ? saturated : Data(hexString: hex)!
}

@Test func networkStampConstantsMatchReference() throws {
    let f = try Fixtures.load()
    #expect(NetworkStamp.stampLength == f.stamp_length)
    #expect(NetworkStamp.stampLength == 14)
    #expect(NetworkStamp.extensionMarker == 0xC1)
    #expect(NetworkStamp.stampCostCap == f.stamp_cost_cap)
    #expect(NetworkStamp.defaultDestinationCost == 23.5)
    #expect(NetworkStamp.defaultDestinationValue == 25.0)
    #expect(NetworkStamp.defaultPathRequestCost == 15.8)
    #expect(NetworkStamp.defaultPathRequestValue == 15.8)
    #expect(NetworkStamp.defaultLinkRequestCost == 12.5)
    #expect(NetworkStamp.linkCostCap == 40)
    #expect(NetworkStamp.stampCostCap == 100)
    #expect(NetworkStamp.linkStampTimeout == 15)
    #expect(NetworkStamp.pathStampTimeout == 15)
}

@Test func networkStampTableMatchesReferenceDigest() throws {
    let f = try Fixtures.load()
    #expect(NetworkStamp.tab.count == 256)
    #expect(NetworkStamp.tab.map { Int($0) } == f.tab)
    // Same digest RNS asserts at import: sha256 of the decimal entries joined with commas.
    let joined = NetworkStamp.tab.map { String($0) }.joined(separator: ",")
    let digest = Crypto.fullHash(Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(digest == f.tab_digest)
}

@Test func networkStampFixedPointMatchesReference() throws {
    for c in try Fixtures.load().fp_cases {
        #expect(NetworkStamp.fixedPoint(cost: c.cost) == c.fp, "cost \(c.cost)")
    }
}

@Test func networkStampFixedPointClampsHostileCosts() {
    let cap = 100 * 256
    #expect(NetworkStamp.fixedPoint(cost: .nan) == 0)
    #expect(NetworkStamp.fixedPoint(cost: .infinity) == cap)
    #expect(NetworkStamp.fixedPoint(cost: -.infinity) == 0)
    #expect(NetworkStamp.fixedPoint(cost: .greatestFiniteMagnitude) == cap)
    #expect(NetworkStamp.fixedPoint(cost: -.greatestFiniteMagnitude) == 0)
    #expect(NetworkStamp.fixedPoint(cost: 1e300) == cap)
    #expect(NetworkStamp.fixedPoint(cost: Double(Int.max)) == cap)
    #expect(NetworkStamp.fixedPoint(cost: -0.0) == 0)
}

@Test func networkStampTargetMatchesReference() throws {
    let f = try Fixtures.load()
    for c in f.fp_cases {
        #expect(NetworkStamp.target(fixedPoint: c.fp) == expectedTarget(hex: c.target_hex, saturated: c.target_saturated),
                "fp \(c.fp)")
    }
    for (key, g) in f.grid_targets {
        let fp = try #require(Int(key))
        #expect(NetworkStamp.target(fixedPoint: fp) == expectedTarget(hex: g.target_hex, saturated: g.target_saturated),
                "fp \(fp)")
    }
}

@Test func networkStampTargetClampsOutOfRangeFixedPoint() {
    #expect(NetworkStamp.target(fixedPoint: -1) == NetworkStamp.target(fixedPoint: 0))
    #expect(NetworkStamp.target(fixedPoint: Int.min) == NetworkStamp.target(fixedPoint: 0))
    #expect(NetworkStamp.target(fixedPoint: 100 * 256 + 1) == NetworkStamp.target(fixedPoint: 100 * 256))
    #expect(NetworkStamp.target(fixedPoint: Int.max) == NetworkStamp.target(fixedPoint: 100 * 256))
    // Cost 0 accepts every hash, the reference target there is 2^256 and does not fit 32 bytes.
    #expect(NetworkStamp.target(fixedPoint: 0) == saturated)
    #expect(NetworkStamp.target(fixedPoint: 0).count == 32)
}

@Test func networkStampValueMatchesReference() throws {
    let f = try Fixtures.load()
    let cases = f.allStampCases
    #expect(cases.count > 30)
    for c in cases {
        let v = NetworkStamp.value(stamp: Data(hexString: c.stamp)!, material: Data(hexString: c.material)!)
        #expect(v == c.value, "material \(c.material) stamp \(c.stamp)")
    }
    for k in f.key_cases {
        #expect(NetworkStamp.value(stamp: Data(hexString: k.public)!, material: Data(hexString: k.material)!) == k.value)
    }
}

@Test func networkStampValidityMatchesReference() throws {
    let f = try Fixtures.load()
    // The reference's own generated stamps at the default announce cost and value, 23.5 and 25.
    for cost in [23.5, 25.0] {
        let generated = f.generated_cases.filter { $0.cost == cost }
        #expect(!generated.isEmpty, "no generated case at cost \(cost)")
        for c in generated {
            #expect(c.valid)
            #expect(c.value >= cost - 1.0 / 256)
            #expect(NetworkStamp.isValid(stamp: Data(hexString: c.stamp)!, cost: c.cost,
                                         material: Data(hexString: c.material)!))
            #expect(NetworkStamp.value(stamp: Data(hexString: c.stamp)!,
                                       material: Data(hexString: c.material)!) == c.value)
        }
    }
    let cases = f.allStampCases
    #expect(cases.contains { $0.valid } && cases.contains { !$0.valid })
    for c in cases {
        let ok = NetworkStamp.isValid(stamp: Data(hexString: c.stamp)!, cost: c.cost, material: Data(hexString: c.material)!)
        #expect(ok == c.valid, "material \(c.material) stamp \(c.stamp) cost \(c.cost)")
    }
    for k in f.key_cases {
        #expect(NetworkStamp.isValid(stamp: Data(hexString: k.public)!, cost: k.cost, material: Data(hexString: k.material)!) == k.valid)
    }
}

@Test func networkStampValidityIsExactlyHashAtOrBelowTarget() throws {
    // Recomputes validity from the raw hash and the target (big-endian hash <= target) and compares it
    // with isValid and with the reference's verdict, on stamps the reference found just under and just
    // over the target. None of these hashes EQUALS the target, so this does not exercise the equality
    // case; NetworkStampBoundaryTests pins that.
    for c in try Fixtures.load().edge_validity_cases {
        let material = Data(hexString: c.material)!
        let stamp = Data(hexString: c.stamp)!
        let hash = Crypto.fullHash(material + stamp)
        let target = NetworkStamp.target(fixedPoint: NetworkStamp.fixedPoint(cost: c.cost))
        let atOrBelow = !target.lexicographicallyPrecedes(hash)   // big-endian: hash <= target
        #expect(NetworkStamp.isValid(stamp: stamp, cost: c.cost, material: material) == atOrBelow)
        #expect(atOrBelow == c.valid)
    }
}

@Test(.timeLimit(.minutes(1)))
func generatedStampIsValidAndCarriesItsValue() async throws {
    // Cost >= 8 so a random 14-byte string passing by luck is a 1-in-256 event, not a coin flip.
    for cost in [8.0, 8.5, 10.25] {
        let material = SecureRandom.bytes(32)
        let result = try #require(await NetworkStamp.generate(material: material, cost: cost))
        #expect(result.stamp.count == NetworkStamp.stampLength)
        #expect(NetworkStamp.isValid(stamp: result.stamp, cost: cost, material: material))
        #expect(result.value == NetworkStamp.value(stamp: result.stamp, material: material))
        #expect(result.value >= cost - 1.0 / 256)
        // The same stamp is far too weak for a much higher cost. Probabilistic: it fails if the random
        // stamp happens to carry 16 more leading zero bits than asked, about 1 in 65,000 per cost.
        #expect(!NetworkStamp.isValid(stamp: result.stamp, cost: cost + 16, material: material))
    }
}

@Test(.timeLimit(.minutes(1)))
func generatedKeyMeetsCost() async throws {
    for cost in [8.0, 8.5] {
        let material = SecureRandom.bytes(32)
        let result = try #require(await NetworkStamp.generateKey(material: material, cost: cost))
        #expect(result.privateKey.count == 32)
        #expect(result.publicKey.count == 32)
        let derived = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: result.privateKey).publicKey.rawRepresentation
        #expect(derived == result.publicKey)
        #expect(NetworkStamp.isValid(stamp: result.publicKey, cost: cost, material: material))
        #expect(result.value == NetworkStamp.value(stamp: result.publicKey, material: material))
    }
}

@Test(.timeLimit(.minutes(1)))
func cancelledSearchReturnsNil() async throws {
    // Cost 100 is unreachable, so the only way out of either search is cancellation.
    let material = SecureRandom.bytes(32)
    let stampTask = Task { await NetworkStamp.generate(material: material, cost: 100) }
    let keyTask = Task { await NetworkStamp.generateKey(material: material, cost: 100) }
    try await Task.sleep(for: .milliseconds(150))
    stampTask.cancel()
    keyTask.cancel()
    #expect(await stampTask.value == nil)
    #expect(await keyTask.value == nil)

    // Cancelled before it ever started.
    let early = Task { () -> (Data, Double)? in
        withUnsafeCurrentTask { $0?.cancel() }
        return await NetworkStamp.generate(material: material, cost: 100).map { ($0.stamp, $0.value) }
    }
    #expect(await early.value == nil)
}
