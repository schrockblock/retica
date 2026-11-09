import Testing
import Foundation
@testable import ReTiCA

/// LXMF stamps at fractional costs against genuine LXMF 1.3.0 / RNS 1.6.0
/// (generate_lxmf_fractional_stamp_fixtures.py). Every expected verdict and value below came out of the
/// reference: LXStamper.generate_stamp / validate_pn_stamp / validate_peering_key, RNS.Stamps.stamp_valid /
/// stamp_value, LXMessage.validate_stamp.

private struct Probe: Decodable {
    let cost: Double
    let valid: Bool
}

private struct GeneratedCase: Decodable {
    let kind: String
    let rounds: Int
    let cost: Double
    let material: String
    let workblock_hash: String
    let stamp: String
    let value: Double
    let probes: [Probe]
    let lxm_data: String?
    let validate_pn_stamp_value: Double?
    let validate_pn_stamp_above_value: Bool?
    let validate_peering_key: Bool?
    let validate_peering_key_above_value: Bool?
}

private struct SliceCase: Decodable {
    let lower: Double
    let upper: Double
    let stamp: String
    let value: Double
    let probes: [Probe]
}

private struct HashCase: Decodable {
    let label: String
    let hash: String
    let value: Double
    let probes: [Probe]
}

private struct MessageCase: Decodable {
    let packed: String
    let hash: String
    let stamp: String
    let cost: Double
    let value: Double
    let validate_stamp: [Probe]
}

private struct Fixtures: Decodable {
    let generated_cases: [GeneratedCase]
    let slice_material: String
    let slice_cases: [SliceCase]
    let hash_cases: [HashCase]
    let message: MessageCase

    static func load() throws -> Fixtures {
        let url = Bundle.module.url(forResource: "lxmf_fractional_stamp_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }
}

private func hex(_ s: String) -> Data { Data(hexString: s)! }

private let step = 1.0 / 256

/// Reference-generated stamps over the three real workblocks at costs 8, 8.5 and 13.25: same workblock,
/// same value, same verdict at every probe cost (including value and value + 1/256), and the PN and
/// peering wrappers agree.
@Test func referenceGeneratedFractionalStampsValidateAndValueAsReference() throws {
    let f = try Fixtures.load()
    #expect(f.generated_cases.count == 9)
    #expect(Set(f.generated_cases.map(\.cost)) == [8, 8.5, 13.25])
    for c in f.generated_cases {
        let material = hex(c.material)
        let stamp = hex(c.stamp)
        let wb = LXStamper.stampWorkblock(material: material, expandRounds: c.rounds)
        #expect(Crypto.fullHash(wb) == hex(c.workblock_hash), "\(c.kind) \(c.cost) workblock")
        #expect(LXStamper.stampValue(workblock: wb, stamp: stamp) == c.value, "\(c.kind) \(c.cost) value")
        for p in c.probes {
            #expect(LXStamper.stampValid(stamp: stamp, targetCost: p.cost, workblock: wb) == p.valid,
                    "\(c.kind) generated at \(c.cost), probed at \(p.cost)")
        }
        switch c.kind {
        case "pn":
            let transient = hex(try #require(c.lxm_data)) + stamp
            let validated = LXStamper.validatePnStamp(transientData: transient, targetCost: c.cost)
            #expect(validated?.transientId == material)
            #expect(validated?.value == c.validate_pn_stamp_value)
            let above = LXStamper.validatePnStamp(transientData: transient, targetCost: c.value + step)
            #expect((above != nil) == c.validate_pn_stamp_above_value)
        case "peering":
            #expect(LXStamper.validatePeeringKey(peeringId: material, peeringKey: stamp, targetCost: c.cost)
                    == c.validate_peering_key)
            #expect(LXStamper.validatePeeringKey(peeringId: material, peeringKey: stamp, targetCost: c.value + step)
                    == c.validate_peering_key_above_value)
        default:
            #expect(c.kind == "delivery")
            #expect(c.rounds == LXStamper.workblockExpandRounds)
        }
    }
}

/// Random stamps the reference found landing between two adjacent targets: valid at the lower cost and
/// not at the upper, where the two differ only in the fraction (8.5 vs 8.5 + 1/256, 8 vs 8.5, 8.5 vs 9,
/// 13.25 - 1/256 vs 13.25). A cost rounded to an integer, or to any coarser grid, gets some of these wrong.
@Test func sliceStampsAreDecidedByTheFractionAsInReference() throws {
    let f = try Fixtures.load()
    let wb = LXStamper.stampWorkblock(material: hex(f.slice_material),
                                      expandRounds: LXStamper.workblockExpandRoundsPeering)
    #expect(f.slice_cases.count >= 7)
    for c in f.slice_cases {
        let stamp = hex(c.stamp)
        #expect(LXStamper.stampValid(stamp: stamp, targetCost: c.lower, workblock: wb))
        #expect(!LXStamper.stampValid(stamp: stamp, targetCost: c.upper, workblock: wb))
        #expect(LXStamper.stampValue(workblock: wb, stamp: stamp) == c.value)
        for p in c.probes {
            #expect(LXStamper.stampValid(stamp: stamp, targetCost: p.cost, workblock: wb) == p.valid,
                    "slice \(c.lower)..<\(c.upper), probed at \(p.cost)")
        }
    }
}

/// Constructed hashes at target, target - 1 and target + 1 for costs 8, 8.5 and 13.25: the exact
/// boundary of the validity rule, and the value reference gives each hash. The reference side fed these
/// exact hashes to the real stamp_valid / stamp_value.
@Test func constructedHashesAtFractionalTargetsMatchReference() throws {
    let f = try Fixtures.load()
    #expect(f.hash_cases.count == 9)
    for c in f.hash_cases {
        let h = hex(c.hash)
        #expect(NetworkStamp.value(hash: h) == c.value, "\(c.label) value")
        for p in c.probes {
            #expect(LXStamper.hashValid(h, targetCost: p.cost) == p.valid, "\(c.label) at \(p.cost)")
        }
    }
    // target(8.5) itself is accepted at 8.5 and one more is refused: the fraction is not rounded away.
    let at85 = try #require(f.hash_cases.first { $0.label == "target(8.5)+0" })
    #expect(hex(at85.hash) == NetworkStamp.target(fixedPoint: NetworkStamp.fixedPoint(cost: 8.5)))
    #expect(LXStamper.hashValid(hex(at85.hash), targetCost: 8.5))
    let over85 = try #require(f.hash_cases.first { $0.label == "target(8.5)+1" })
    #expect(!LXStamper.hashValid(hex(over85.hash), targetCost: 8.5))
}

/// A real LXMF 1.3.0 message stamped at cost 8.5: unpacks to the same hash, and `validateStamp` gives
/// reference's `validate_stamp` verdict at each probe cost, with and without (non-matching) tickets.
@Test func referenceMessageStampedAtFractionalCostValidatesAsReference() throws {
    let m = try Fixtures.load().message
    let message = try #require(LXMessage.unpack(hex(m.packed)))
    #expect(message.hash == hex(m.hash))
    #expect(message.stamp == hex(m.stamp))
    #expect(LXStamper.stampValue(workblock: LXStamper.stampWorkblock(material: message.hash),
                                 stamp: hex(m.stamp)) == m.value)
    #expect(m.validate_stamp.contains { $0.cost == m.cost && $0.valid })
    #expect(m.validate_stamp.contains { !$0.valid })
    for p in m.validate_stamp {
        #expect(message.validateStamp(targetCost: p.cost) == p.valid, "message at \(p.cost)")
        #expect(message.validateStamp(targetCost: p.cost, tickets: [Data(repeating: 1, count: 16)]) == p.valid)
    }
}

// MARK: - Integer costs keep the legacy rule

private func leadingZeros(_ h: Data) -> Int {
    var n = 0
    for byte in h {
        if byte == 0 { n += 8; continue }
        return n + byte.leadingZeroBitCount
    }
    return n
}

/// 2^e as 32 big-endian bytes, plus `delta` (-1, 0 or +1).
private func powerOfTwo(_ e: Int, plus delta: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    bytes[31 - e / 8] = UInt8(1) << UInt8(e % 8)
    if delta == -1 {
        // 2^e - 1: every bit below e set.
        bytes = [UInt8](repeating: 0, count: 32)
        for b in 0..<e { bytes[31 - b / 8] |= UInt8(1) << UInt8(b % 8) }
    } else if delta == 1 {
        bytes[31] |= 1
    }
    return Data(bytes)
}

/// At every integer cost 1...99 the fixed-point rule is the lxmf 1.1.0 "leading zeros >= cost" rule,
/// checked on both sides of the boundary, except the single hash 2^(256-c): it has c-1 leading zeros and
/// is valid, as reference's `hash <= 2^(256-c)` says (pinned for c = 8 by the reference hash cases).
@Test func integerCostsKeepTheLegacyLeadingZeroRuleExceptTheExactTarget() {
    for c in 1...99 {
        let e = 256 - c
        let below = powerOfTwo(e, plus: -1)     // c leading zeros: the largest legacy-valid hash
        let exact = powerOfTwo(e, plus: 0)      // c - 1 leading zeros
        let above = powerOfTwo(e, plus: 1)
        #expect(leadingZeros(below) == c && leadingZeros(exact) == c - 1)
        #expect(LXStamper.hashValid(below, targetCost: Double(c)), "cost \(c), 2^\(e)-1")
        #expect(LXStamper.hashValid(exact, targetCost: Double(c)), "cost \(c), 2^\(e)")
        #expect(!LXStamper.hashValid(above, targetCost: Double(c)), "cost \(c), 2^\(e)+1")
    }
}

/// The integer part of the new value is the leading-zero count lxmf 1.1.0 reported, on the committed
/// 1.1.0 fixtures and on constructed hashes across the whole range.
@Test func valueFloorIsTheLegacyLeadingZeroCount() throws {
    let legacy = try LXMFStampFixtures.load()
    let wb = LXStamper.stampWorkblock(material: hex(legacy.messageId))
    let value = LXStamper.stampValue(workblock: wb, stamp: hex(legacy.stamp))
    #expect(Int(value.rounded(.down)) == legacy.stampValue)
    #expect(value >= Double(legacy.stampCost))
    for e in stride(from: 1, through: 255, by: 7) {
        for delta in [-1, 0, 1] {
            let h = powerOfTwo(e, plus: delta)
            #expect(Int(NetworkStamp.value(hash: h).rounded(.down)) == leadingZeros(h), "2^\(e)\(delta)")
        }
    }
}

// MARK: - Our own fractional stamps

/// Stamps we generate at fractional costs are valid at that cost (and their value is at least it, up to
/// the exact-target case where the value floors 1/256 below).
@Test func ourFractionalStampsValidateAtTheirCost() async throws {
    let material = Crypto.fullHash(Data("retica-fractional-own".utf8))
    let delivery = try #require(await LXStamper.generateStamp(messageId: material, targetCost: 8.5))
    let wb = LXStamper.stampWorkblock(material: material)
    #expect(LXStamper.stampValid(stamp: delivery, targetCost: 8.5, workblock: wb))
    #expect(LXStamper.stampValue(workblock: wb, stamp: delivery) >= 8.5 - step)

    let key = try #require(await LXStamper.generatePeeringKey(peeringId: material, targetCost: 13.25))
    #expect(LXStamper.validatePeeringKey(peeringId: material, peeringKey: key, targetCost: 13.25))

    let lxmData = Data(repeating: 0x42, count: 160)
    let tid = Crypto.fullHash(lxmData)
    let pn = try #require(await LXStamper.generatePnStamp(transientId: tid, targetCost: 8.25))
    let validated = try #require(LXStamper.validatePnStamp(transientData: lxmData + pn, targetCost: 8.25))
    #expect(validated.value >= 8.25 - step)
}

/// Costs off the wire are untrusted: NaN, infinities, negatives and huge values never trap.
/// Finite costs clamp: anything <= 0 accepts every stamp (fixed point 0), huge values clamp to cost
/// 100. A non-finite cost (NaN, +/-infinity) validates nothing and generates nothing, where reference's
/// `cost_to_fp` raises (`math.floor` of NaN or infinity) and the stamp is not accepted.
@Test func hostileCostsClampWithoutTrapping() async {
    let material = Crypto.fullHash(Data("hostile".utf8))
    let wb = LXStamper.stampWorkblock(material: material, expandRounds: LXStamper.workblockExpandRoundsPeering)
    let stamp = Data(repeating: 0xFF, count: LXStamper.stampSize)
    for cost: Double in [-1, -1e300, 0] {
        #expect(LXStamper.stampValid(stamp: stamp, targetCost: cost, workblock: wb), "\(cost)")
    }
    for cost in [Double.nan, .infinity, -.infinity, 1e300, 100, 255] {
        #expect(!LXStamper.stampValid(stamp: stamp, targetCost: cost, workblock: wb), "\(cost)")
        #expect(!LXStamper.validatePeeringKey(peeringId: material, peeringKey: stamp, targetCost: cost))
    }
    for cost in [Double.nan, .infinity, -.infinity] {
        #expect(LXStamper.validatePnStamp(transientData: Data(repeating: 1, count: 200), targetCost: cost) == nil)
        #expect(await LXStamper.generatePeeringKey(peeringId: material, targetCost: cost) == nil, "\(cost)")
    }
    // A finite cost <= 0 still validates (every stamp meets it), so the non-finite refusal is not a
    // blanket refusal of the entry.
    #expect(LXStamper.validatePnStamp(transientData: Data(repeating: 1, count: 200), targetCost: -1) != nil)
}

// MARK: - Reverse direction: the reference validates OUR fractional stamps (gated)

private let referencePython = ProcessInfo.processInfo.environment["RETICA_REFERENCE_PYTHON"]
    ?? ProcessInfo.processInfo.environment["RETICA_LIVE_STAMP_PYTHON"]
private let generatorScript = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("generate_lxmf_fractional_stamp_fixtures.py")

private struct ReverseCase: Codable {
    let material: String
    let rounds: Int
    let stamp: String
    let cost: Double
}

private struct ReferenceVerdict: Decodable {
    let valid: Bool
    let value: Double
}

private func referenceVerdicts(on cases: [ReverseCase]) throws -> [ReferenceVerdict] {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("retica-fractional-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("cases.json")
    try JSONEncoder().encode(cases).write(to: input)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: referencePython!)
    process.arguments = [generatorScript.path, "--validate", input.path]
    process.currentDirectoryURL = dir
    let out = Pipe()
    process.standardOutput = out
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    let line = try #require(text.split(separator: "\n").last(where: { $0.hasPrefix("RESULT ") }),
                            "reference output: \(text)")
    return try JSONDecoder().decode([ReferenceVerdict].self, from: Data(line.dropFirst("RESULT ".count).utf8))
}

/// ReTiCA generates delivery, PN and peering stamps at fractional costs over fixed materials (so the
/// workblocks are deterministic; the stamps are random), and reference RNS 1.6.0 `stamp_valid` accepts
/// each one at its cost and computes the value we compute. Each is also checked at value + 1/256, where
/// both sides must refuse it. Run with RETICA_REFERENCE_PYTHON (or RETICA_LIVE_STAMP_PYTHON) set to the
/// rns-latest interpreter.
@Test(.enabled(if: referencePython != nil), .timeLimit(.minutes(5)))
func theReferenceValidatesOurFractionalStamps() async throws {
    let material = Crypto.fullHash(Data("retica-fractional-reverse".utf8))
    var cases: [ReverseCase] = []
    let delivery = try #require(await LXStamper.generateStamp(messageId: material, targetCost: 8.5))
    let pn = try #require(await LXStamper.generatePnStamp(transientId: material, targetCost: 13.25))
    let peering = try #require(await LXStamper.generatePeeringKey(peeringId: material, targetCost: 13.25))
    for (stamp, rounds, cost) in [(delivery, LXStamper.workblockExpandRounds, 8.5),
                                  (pn, LXStamper.workblockExpandRoundsPN, 13.25),
                                  (peering, LXStamper.workblockExpandRoundsPeering, 13.25)] {
        let value = LXStamper.stampValue(workblock: LXStamper.stampWorkblock(material: material, expandRounds: rounds),
                                         stamp: stamp)
        cases.append(ReverseCase(material: material.hexString, rounds: rounds, stamp: stamp.hexString, cost: cost))
        cases.append(ReverseCase(material: material.hexString, rounds: rounds, stamp: stamp.hexString,
                                 cost: value + step))
    }
    let verdicts = try referenceVerdicts(on: cases)
    try #require(verdicts.count == cases.count)
    for (i, c) in cases.enumerated() {
        let wb = LXStamper.stampWorkblock(material: material, expandRounds: c.rounds)
        let stamp = hex(c.stamp)
        #expect(verdicts[i].value == LXStamper.stampValue(workblock: wb, stamp: stamp), "case \(i) value")
        #expect(verdicts[i].valid == LXStamper.stampValid(stamp: stamp, targetCost: c.cost, workblock: wb),
                "case \(i) verdict")
        #expect(verdicts[i].valid == (i % 2 == 0), "case \(i): valid at its cost, refused at value + 1/256")
    }
}
