import Testing
import Foundation
@testable import ReTiCA

// A propagation node's sync offer to a peer, against a real `LXMPeer.sync` (LXMF 1.3.0). Fixtures:
// lxmf_pn_offer_limits_fixtures.json, from generate_lxmf_pn_offer_limits_fixtures.py, which peers a
// real LXMRouter with a peer made from an announce carrying the limits and runs the real sync over
// entries of chosen size, age and stamp value. See the generator's header for what is replaced.

private struct LimitEntry: Decodable { let size: Int; let age: Double; let value: Double; let handled: Bool }
private struct LimitCase: Decodable {
    let transfer_limit_kb: Int; let sync_limit_kb: Int; let cost: Double; let flexibility: Double
    let entries: [LimitEntry]; let offered: [Int]; let handled_after: [Int]; let unhandled_after: [Int]
}
private struct LimitFixtures: Decodable {
    let cases: [LimitCase]
    static func load() throws -> LimitFixtures {
        let url = try #require(Bundle.module.url(forResource: "lxmf_pn_offer_limits_fixtures", withExtension: "json"))
        return try JSONDecoder().decode(LimitFixtures.self, from: Data(contentsOf: url))
    }
}

/// For each case: the same entries, ingested in the same order at `now - age`, give the same offer in
/// the same order; our `oversized` is exactly the entries the sync marked handled; our `lowValue` is
/// exactly the entries it dropped from the peer's unhandled list without marking them.
///
/// Anti-vacuity: the cases between them offer a strict, reordered subset (weight order differs from
/// ingest order), skip an entry that does not fit the sync limit and offer later ones (skip, not
/// stop), hit both limit boundaries, exclude already-handled entries, and offer nothing at limit 0.
@Test func pnOfferSelectionMatchesReferenceSync() throws {
    let cases = try LimitFixtures.load().cases
    #expect(cases.count == 5)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    for (index, c) in cases.enumerated() {
        var store = PropagationStore(targetStampCost: 0)
        var ids: [Data] = []
        for (i, entry) in c.entries.enumerated() {
            // destination hash, then a unique filler up to exactly `size` bytes.
            let tag = Data("case-\(index)-entry-\(i)-".utf8)
            let data = Data(repeating: 0xAB, count: 16) + tag + Data(repeating: 0x5A, count: entry.size - 16 - tag.count)
            #expect(data.count == entry.size)
            let added = store.ingest(container: LXMFPropagation.container(timestamp: 0, entries: [data]),
                                     now: now.addingTimeInterval(-entry.age)).added
            try #require(added.count == 1, "case \(index) entry \(i)")
            store.setStampValue(entry.value, forTransientId: added[0])
            ids.append(added[0])
        }
        let handled = Set(c.entries.indices.filter { c.entries[$0].handled }.map { ids[$0] })
        let minimum = max(0, c.cost - c.flexibility)
        let got = store.offerCandidates(acceptedAt: minimum, transferLimitKB: c.transfer_limit_kb,
                                        syncLimitKB: c.sync_limit_kb, excluding: handled, now: now)
        #expect(got.offer == c.offered.map { ids[$0] }, "case \(index)")

        let initiallyHandled = Set(c.entries.indices.filter { c.entries[$0].handled })
        let referenceOversized = Set(c.handled_after).subtracting(initiallyHandled)
        let referenceLowValue = Set(c.entries.indices).subtracting(initiallyHandled)
            .subtracting(c.unhandled_after).subtracting(c.handled_after)
        #expect(Set(got.oversized) == Set(referenceOversized.map { ids[$0] }), "case \(index)")
        #expect(Set(got.lowValue) == Set(referenceLowValue.map { ids[$0] }), "case \(index)")
    }
    #expect(cases.contains { $0.offered.count > 1 && $0.offered != $0.offered.sorted() })
    #expect(cases.contains { !$0.offered.isEmpty && $0.offered.first! > 0 && $0.handled_after.isEmpty })
}
