import Testing
import Foundation
@testable import ReTiCA

// Fractional (LXMF 1.3.0) costs in announce app data and in propagation-node acceptance, against
// genuine reference code. Fixtures: lxmf_fractional_cost_app_data_fixtures.json, from
// generate_lxmf_fractional_cost_app_data_fixtures.py (rns 1.6.0 / lxmf 1.3.0), which drives a real
// LXMRouter's get_announce_app_data, set_inbound_stamp_cost, get_propagation_node_app_data,
// get_outbound_propagation_cost and propagation_packet, and reads blobs back with
// stamp_cost_from_app_data / pn_announce_data_is_valid / pn_stamp_cost_from_app_data.
//
// Emitted bytes are compared byte for byte with reference's own emission, so reference's helpers read
// ours exactly as they read its own (their readings are in the fixture).

/// A number as the generator writes it: a JSON number, a string for NaN / +-infinity, an object for
/// anything that is not a number (`{"repr": "'x'"}`), or null.
private enum Num: Decodable, Equatable {
    case number(Double)
    case other(String)
    case none

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .none; return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) {
            switch s {
            case "nan": self = .number(.nan)
            case "inf": self = .number(.infinity)
            case "-inf": self = .number(-.infinity)
            default: self = .other(s)
            }
            return
        }
        self = .other(try c.decode([String: String].self)["repr"] ?? "?")
    }

    var double: Double? { if case let .number(d) = self { return d } else { return nil } }
}

private struct DeliveryEmit: Decodable { let cost: Num; let packed: String; let read_back: Num }
private struct DeliveryParse: Decodable { let packed: String; let read_back: Num }
private struct PNEmit: Decodable {
    let cost: Double; let flexibility: Double; let peering_cost: Double
    let timebase: Int; let packed: String; let valid: Bool; let stamp_cost: Num
}
private struct PNParse: Decodable { let packed: String; let valid: Bool; let stamp_cost: Num; let outbound_cost: Num }
private struct PNIngest: Decodable {
    let cost: Double; let flexibility: Double; let hash: String; let value: Double; let accepted: Bool
}
private struct PNLength: Decodable { let length: Int; let accepted: Bool }
private struct PeerOffer: Decodable { let packed: String; let values: [Double]; let offered: [Double]? }

private struct Fixtures: Decodable {
    let delivery_emit: [DeliveryEmit]
    let delivery_parse: [DeliveryParse]
    let pn_emit: [PNEmit]
    let pn_parse: [PNParse]
    let pn_ingest: [PNIngest]
    let pn_length: [PNLength]
    let peer_offer: [PeerOffer]

    static func load() throws -> Fixtures {
        let url = try #require(Bundle.module.url(forResource: "lxmf_fractional_cost_app_data_fixtures",
                                                 withExtension: "json"))
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }
}

private func hex(_ s: String) -> Data { Data(hexString: s)! }

/// What our delivery parse surfaces for a value reference read back: the same number when it is
/// inside the gate `0 < cost < 100`, else nil (our documented narrowing, see `LXMFAnnounceData.stampCost`).
private func gated(_ n: Num) -> Double? {
    guard let d = n.double, LXStamper.costInRange(d) else { return nil }
    return d
}

private func sameNumber(_ a: Double, _ b: Double) -> Bool { a == b || (a.isNaN && b.isNaN) }

// MARK: - Delivery announce app data

/// Our `pack` writes the bytes reference's `get_announce_app_data` writes, for every cost: integer,
/// fractional, off-grid (13.3 → 13.30078125), rounding up to 100 (99.999), quantizing to 0 (0.001:
/// null ceiling, 0.0 in [3]), and every value outside the gate (null in both).
@Test func deliveryAppDataEmissionMatchesReference() throws {
    let f = try Fixtures.load()
    #expect(f.delivery_emit.count == 15)
    for c in f.delivery_emit {
        let cost: Double? = c.cost.double
        #expect(LXMFAnnounceData.pack(displayName: "Alice", stampCost: cost) == hex(c.packed), "cost \(c.cost)")
    }
}

/// Reading reference's emission back: inside the gate we surface exactly what
/// `stamp_cost_from_app_data` reads (including the quantized 13.30078125 and 100.0's absence); the
/// 0.001 case, which reference reads as 0.0, we read as nil.
@Test func deliveryAppDataParseOfReferenceEmissionMatchesReference() throws {
    for c in try Fixtures.load().delivery_emit {
        #expect(LXMFAnnounceData.parse(hex(c.packed))?.stampCost == gated(c.read_back), "cost \(c.cost)")
    }
}

/// Hostile and odd blobs: we pick the same element reference picks ([3] when it is an int or float,
/// else [1]; a bool in [3] is neither) and then apply the gate.
@Test func deliveryAppDataParseOfHostileBlobsChoosesTheElementReferenceChooses() throws {
    let cases = try Fixtures.load().delivery_parse
    #expect(cases.count == 20)
    for c in cases {
        let parsed = try #require(LXMFAnnounceData.parse(hex(c.packed)))
        #expect(parsed.stampCost == gated(c.read_back), "\(c.packed) read back as \(c.read_back)")
    }
    // The cases that show element choice, not just the gate: reference falls back to [1] = 9.
    let fallback = cases.filter { $0.read_back == .number(9) }
    #expect(fallback.count == 3)
    for c in fallback { #expect(LXMFAnnounceData.parse(hex(c.packed))?.stampCost == 9) }
}

// MARK: - Propagation node announce app data

/// Our `PNAnnounce.packed` writes the bytes reference's `get_propagation_node_app_data` writes:
/// [5] the ceilings, [7] the exact costs as float64. Timebase and metadata are taken from reference's
/// blob (they are a clock reading and lxmd's own name/version), the costs from the configuration.
@Test func pnAppDataEmissionMatchesReference() throws {
    let cases = try Fixtures.load().pn_emit
    #expect(cases.count == 5)
    for c in cases {
        guard case let .array(items)? = MsgPack.decodeValue(hex(c.packed)) else {
            Issue.record("undecodable reference blob"); continue
        }
        // The integer-configured case (16, 3, 18) is written by reference with ints in [7]; ours are
        // always float64 (lxmd configures floats), so only the float-configured cases are byte-compared.
        let floatConfigured = items.count == 8 && { if case .array(let e) = items[7], case .double = e[0] { return true }; return false }()
        let ours = PNAnnounce(timebase: c.timebase, nodeState: true,
                              perTransferLimit: LXMFPropagation.defaultPropagationTransferLimitKB,
                              perSyncLimit: LXMFPropagation.defaultPropagationSyncLimitKB,
                              targetStampCost: c.cost, stampCostFlexibility: c.flexibility,
                              peeringCost: c.peering_cost, metadata: items[6])
        if floatConfigured {
            #expect(ours.packed == hex(c.packed), "costs \(c.cost) \(c.flexibility) \(c.peering_cost)")
        }
        #expect(c.valid)
        let parsed = try #require(PNAnnounce.parse(hex(c.packed)))
        #expect(parsed.targetStampCost == c.stamp_cost.double)
        #expect(parsed.targetStampCost == c.cost)
        #expect(parsed.stampCostFlexibility == c.flexibility)
        #expect(parsed.peeringCost == c.peering_cost)
    }
    #expect(cases.filter { $0.cost != $0.cost.rounded() }.count == 3)   // fractional cases were compared
}

/// Validity and the cost read back agree with `pn_announce_data_is_valid` /
/// `pn_stamp_cost_from_app_data` for every hostile blob: a NaN, negative, infinite or huge cost is a
/// VALID announce there, and is here, surfaced as-is.
@Test func pnAppDataParseOfHostileBlobsMatchesReference() throws {
    let cases = try Fixtures.load().pn_parse
    #expect(cases.count == 13)
    for c in cases {
        let parsed = PNAnnounce.parse(hex(c.packed))
        #expect((parsed != nil) == c.valid, "\(c.packed)")
        if let parsed, let expected = c.stamp_cost.double {
            #expect(sameNumber(parsed.targetStampCost, expected), "\(c.packed): \(parsed.targetStampCost)")
        }
    }
}

/// The client's clamp, reference `get_outbound_propagation_cost` (LXMRouter.py:494-519): NaN,
/// negatives and -infinity give 0; +infinity and huge give 100. `LXMFNode.propagationStampCost`
/// applies the same clamp and then refuses above 20; its node-level tests use these same values.
/// Here the clamp itself is checked against reference's outputs.
@Test func pnOutboundCostClampMatchesReference() throws {
    for c in try Fixtures.load().pn_parse where c.valid {
        let raw = try #require(PNAnnounce.parse(hex(c.packed))).targetStampCost
        let ours = raw.isNaN ? 0 : min(max(raw, 0), Double(NetworkStamp.stampCostCap))
        #expect(ours == c.outbound_cost.double, "\(c.packed): raw \(raw)")
    }
}

// MARK: - Propagation node acceptance: max(0, cost - flex)

/// Review Focus 5, exactly, against reference's own ingest decision. Reference's propagation_packet
/// computed `min_accepted_cost = max(0, cost - flex)` itself and proved (or refused) an offer whose
/// final hash was the constructed one; we check that our store's acceptance cost and validity rule
/// give the same verdict on the same hash, and that the hash's value is reference's.
///
/// At 16 - 3: the hash worth exactly 13.0 is accepted and the first hash above the target (worth
/// 12.99609375) is refused. At 16.5 - 3.25 the same at 13.25. At 13 - 15 the acceptance cost is 0
/// and the largest possible hash is accepted.
@Test func pnAcceptanceAtCostMinusFlexMatchesReferenceOnConstructedHashes() throws {
    let cases = try Fixtures.load().pn_ingest
    #expect(cases.count == 7)
    for c in cases {
        let store = PropagationStore(targetStampCost: c.cost, stampCostFlexibility: c.flexibility)
        let hash = hex(c.hash)
        #expect(NetworkStamp.value(hash: hash) == c.value, "\(c.cost)-\(c.flexibility) \(c.hash)")
        #expect(LXStamper.hashValid(hash, targetCost: store.minAcceptedStampCost) == c.accepted,
                "\(c.cost)-\(c.flexibility) \(c.hash)")
    }
    let at13 = cases.filter { $0.cost == 16 }
    #expect(at13.map(\.accepted) == [true, true, false])
    #expect(at13.first?.value == 13.0)
    #expect(at13.last.map { $0.value < 13 } == true)
}

// MARK: - Peer offer filter: max(0, cost - flex) of the PEER's announce

/// I1, against a real `LXMPeer.sync`: for each announce blob (fractional, NaN, ±infinity, infinity minus
/// infinity, flexibility above the cost, a seven-element integer announce), the stamp values reference
/// offers are exactly those at or above our `peerMinimumAcceptedCost` of the parsed announce, and where
/// reference sends no offer ours keeps nothing. The same rule run through a store
/// (`offerCandidates(acceptedAt:…)`) is in PropagationStoreTests and PNNodeOfferFilterTests.
///
/// Anti-vacuity: the cases include an all-offered, a none-offered and several partial sets, so a
/// formula that ignored the flexibility, clamped NaN to anything but 0, or let +infinity through fails.
@Test func peerOfferFilterMatchesReferenceSync() throws {
    let cases = try Fixtures.load().peer_offer
    #expect(cases.count == 12)
    for c in cases {
        let announce = try #require(PNAnnounce.parse(hex(c.packed)), "\(c.packed)")
        let minimum = LXMFPropagation.peerMinimumAcceptedCost(announce)
        let ours = c.values.filter { $0 >= minimum }
        #expect(ours == (c.offered ?? []), "\(c.packed): minimum \(minimum)")
    }
    #expect(cases.contains { $0.offered == nil })
    #expect(cases.contains { $0.offered == $0.values })
    #expect(cases.contains { ($0.offered?.count ?? 0) > 0 && $0.offered != $0.values })
}

/// Reference's length rule on its own (cost 0, so any stamp is valid): 143 and 144 bytes refused,
/// 145 and 146 accepted. The cost-8 version with real stamps is in PropagationStoreTests.
@Test func pnLengthRuleMatchesReference() throws {
    let cases = try Fixtures.load().pn_length
    #expect(cases.map(\.length) == [143, 144, 145, 146])
    for c in cases {
        let transientData = Data((0..<(c.length - LXStamper.stampSize)).map { UInt8($0 % 256) })
            + Data(count: LXStamper.stampSize)
        #expect((LXStamper.validatePnStamp(transientData: transientData, targetCost: 0) != nil) == c.accepted,
                "\(c.length) bytes")
        #expect((PropagationStore().preflightTransientId(ofStampedEntry: transientData) != nil) == c.accepted)
    }
}
