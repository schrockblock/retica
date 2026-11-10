import Testing
import Foundation
@testable import ReTiCA

// `PropagationStore.offerCandidates`: reference `LXMPeer.sync`'s offer selection (LXMPeer.py:339-384,
// LXMRouter.get_weight :1188-1199). The same rule against a real LXMPeer is in
// PNOfferLimitsCrossValidationTests; the per-peer handled set around it is in PNNodeOfferLimitsTests.

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private let day: TimeInterval = 60 * 60 * 24

/// A store holding entries of exactly `sizes[i]` bytes, received `ages[i]` seconds before `t0`, in
/// that order, all valued 16. Returns the store and the ids in the same order.
private func store(sizes: [Int], ages: [TimeInterval]? = nil) -> (PropagationStore, [Data]) {
    var store = PropagationStore(targetStampCost: 0)
    var ids: [Data] = []
    for (i, size) in sizes.enumerated() {
        let tag = Data("entry-\(i)-".utf8)
        let data = Data(repeating: 0xAB, count: 16) + tag + Data(repeating: 0x5A, count: size - 16 - tag.count)
        let added = store.ingest(container: LXMFPropagation.container(timestamp: 0, entries: [data]),
                                 now: t0.addingTimeInterval(-(ages?[i] ?? 0))).added
        precondition(added.count == 1 && data.count == size)
        store.setStampValue(16, forTransientId: added[0])
        ids.append(added[0])
    }
    return (store, ids)
}

private func select(_ store: PropagationStore, transferKB: Int? = nil, syncKB: Int? = nil,
                    minimum: Double = 0, excluding: Set<Data> = [])
    -> (offer: [Data], oversized: [Data], lowValue: [Data]) {
    store.offerCandidates(acceptedAt: minimum, transferLimitKB: transferKB, syncLimitKB: syncKB,
                          excluding: excluding, now: t0)
}

@Test func ingestRecordsReceivedAtFromNow() {
    let (s, ids) = store(sizes: [100, 100], ages: [0, 3 * day])
    #expect(s.entries(forTransientIds: ids).map(\.receivedAt) == [t0, t0.addingTimeInterval(-3 * day)])
}

/// Review Focus 1: a peer announcing 256 KB is never offered an entry whose transfer size (size + 16)
/// exceeds 256 * 1000: 255984 bytes is offered, 255985 is reported oversized.
@Test func offerSkipsAndReportsEntriesOverThePeerTransferLimit() {
    let (s, ids) = store(sizes: [255_985, 255_984, 300_000])
    let got = select(s, transferKB: 256, syncKB: 10240)
    #expect(got.offer == [ids[1]])
    #expect(got.oversized == [ids[0], ids[2]])
    #expect(got.lowValue.isEmpty)
}

/// Review Focus 2: a sync limit smaller than the first entry (in weight order) skips that entry and
/// still offers the later, smaller ones that fit — skip, not stop. The skipped one is NOT oversized:
/// it fits the transfer limit and may go in a later sync.
@Test func offerSkipsAnEntryOverTheSyncLimitAndKeepsGoing() {
    // 3000 B new (weight 3000), 900 B 30 days old (6750), 1000 B 40 days old (10000).
    let (s, ids) = store(sizes: [3000, 1000, 900], ages: [0, 40 * day, 30 * day])
    // The premise, without a sync limit: the 3000 B entry is first in weight order.
    #expect(select(s, transferKB: 256).offer == [ids[0], ids[2], ids[1]])
    let got = select(s, transferKB: 256, syncKB: 2)
    #expect(got.offer == [ids[2], ids[1]])          // 24 + 916 = 940, then 940 + 1016 = 1956 < 2000
    #expect(got.oversized.isEmpty)
}

/// The sync limit refuses a running total EQUAL to it (`>=`), and the starting total is 24.
@Test func offerSyncLimitRefusesATotalEqualToTheLimit() {
    let (exact, _) = store(sizes: [960])                        // 24 + 976 = 1000
    #expect(select(exact, syncKB: 1).offer.isEmpty)
    let (under, ids) = store(sizes: [959])                      // 24 + 975 = 999
    #expect(select(under, syncKB: 1).offer == ids)
}

/// Weight = max(1, age/4 days) * size, ascending: of equal size, an older entry (past 4 days) sorts
/// after a newer one; a smaller entry sorts first; equal weights keep ingest order.
@Test func offerIsInReferenceWeightOrder() {
    // Ingest order: 100 B 10 days (250), 200 B new (200), 100 B 5 days (125), 150 B new (150),
    // 100 B new (100), 100 B 2 days (100: under 4 days the factor is 1).
    let (s, ids) = store(sizes: [100, 200, 100, 150, 100, 100], ages: [10 * day, 0, 5 * day, 0, 0, 2 * day])
    #expect(select(s).offer == [ids[4], ids[5], ids[2], ids[3], ids[1], ids[0]])
}

@Test func offerLeavesOutHandledIdsAndReportsLowValueOnes() {
    let (base, ids) = store(sizes: [100, 101, 102, 5000])
    var s = base
    s.setStampValue(12.99609375, forTransientId: ids[1])
    let got = select(s, transferKB: 1, minimum: 13, excluding: [ids[0], ids[3]])
    #expect(got.offer == [ids[2]])
    #expect(got.lowValue == [ids[1]])
    #expect(got.oversized.isEmpty)                  // the 5000 B one is handled, so not even reported
}

/// No limits offers everything; a limit of 0 offers nothing (16 + size > 0); a limit whose * 1000
/// overflows does not trap and limits nothing.
@Test func offerLimitEdges() {
    let (s, ids) = store(sizes: [100, 200])
    #expect(select(s).offer == ids)
    let zero = select(s, transferKB: 0, syncKB: 0)
    #expect(zero.offer.isEmpty && zero.oversized == ids)
    #expect(select(s, transferKB: Int.max, syncKB: Int.max).offer == ids)
}
