import Testing
import Foundation
@testable import ReTiCA

/// Build a propagation container entry: destHash(16) ‖ arbitrary opaque tail (the store treats the
/// encrypted tail as opaque, so the tail content is irrelevant to store behavior).
private func entry(dest: UInt8, tail: String) -> Data {
    Data(repeating: dest, count: LXMessage.destinationLength) + Data(tail.utf8)
}
private func container(_ entries: [Data]) -> Data {
    LXMFPropagation.container(timestamp: 1700000000.5, entries: entries)
}

@Test func propagationStoreIngestsAndDedups() throws {
    var store = PropagationStore(minStampCost: 0)
    let e = entry(dest: 0xAA, tail: "one")
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let firstAdded = store.ingest(container: container([e]))
    #expect(firstAdded == [tid])
    #expect(store.count == 1)
    #expect(store.contains(transientId: tid))
    // Re-ingesting the identical container is a no-op (dedup by transient_id).
    let secondAdded = store.ingest(container: container([e]))
    #expect(secondAdded.isEmpty)
    #expect(store.count == 1)
}

@Test func propagationStoreQueriesByDestination() throws {
    var store = PropagationStore(minStampCost: 0)
    let a1 = entry(dest: 0xAA, tail: "a1"), a2 = entry(dest: 0xAA, tail: "a2")
    let b1 = entry(dest: 0xBB, tail: "b1")
    store.ingest(container: container([a1, b1, a2]))
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    let forA = store.entries(forDestination: destA)
    #expect(forA.count == 2)
    #expect(forA.allSatisfy { $0.destinationHash == destA })
    #expect(forA.map { $0.lxmfData } == [a1, a2])   // oldest-first by insertion
    let destB = Data(repeating: 0xBB, count: LXMessage.destinationLength)
    #expect(store.entries(forDestination: destB).count == 1)
}

@Test func propagationStoreRemoves() throws {
    var store = PropagationStore(minStampCost: 0)
    let e = entry(dest: 0xAA, tail: "x")
    let tid = LXMFPropagation.transientId(lxmfData: e)
    store.ingest(container: container([e]))
    store.remove(transientId: tid)
    #expect(store.count == 0)
    #expect(!store.contains(transientId: tid))
}

@Test func propagationStoreEvictsOldestOverLimit() throws {
    // Each entry is 16 + 4 = 20 bytes; a 45-byte limit holds at most 2.
    var store = PropagationStore(storageLimitBytes: 45, minStampCost: 0)
    let e1 = entry(dest: 0xAA, tail: "aaaa")
    let e2 = entry(dest: 0xAA, tail: "bbbb")
    let e3 = entry(dest: 0xAA, tail: "cccc")
    store.ingest(container: container([e1]))
    store.ingest(container: container([e2]))
    store.ingest(container: container([e3]))   // pushes over the limit → evict oldest (e1)
    #expect(store.sizeBytes <= 45)
    #expect(store.count == 2)
    #expect(!store.contains(transientId: LXMFPropagation.transientId(lxmfData: e1)))   // oldest evicted
    #expect(store.contains(transientId: LXMFPropagation.transientId(lxmfData: e3)))    // newest retained
}

@Test func propagationStoreSkipsMalformedEntries() throws {
    var store = PropagationStore(minStampCost: 0)
    // Short entry (< 16 bytes) is skipped; the well-formed one is stored.
    let shortEntry = Data([0x01, 0x02, 0x03])
    let good = entry(dest: 0xAA, tail: "ok")
    let added = store.ingest(container: container([shortEntry, good]))
    #expect(added == [LXMFPropagation.transientId(lxmfData: good)])
    #expect(store.count == 1)
    // A non-container blob ingests to nothing.
    #expect(store.ingest(container: Data([0xFF, 0xFF])).isEmpty)
    #expect(store.count == 1)
}

@Test func propagationStoreOffersAllTransientIdsOldestFirst() throws {
    var store = PropagationStore(minStampCost: 0)
    let e1 = entry(dest: 0xAA, tail: "e1"), e2 = entry(dest: 0xAA, tail: "e2"), e3 = entry(dest: 0xBB, tail: "e3")
    store.ingest(container: container([e1, e2, e3]))
    #expect(store.transientIds == [e1, e2, e3].map { LXMFPropagation.transientId(lxmfData: $0) })
}

@Test func propagationStoreWantedReturnsMissingInOfferedOrder() throws {
    var store = PropagationStore(minStampCost: 0)
    let e1 = entry(dest: 0xAA, tail: "e1"), e2 = entry(dest: 0xAA, tail: "e2")
    let x = entry(dest: 0xAA, tail: "xx"), y = entry(dest: 0xAA, tail: "yy")
    store.ingest(container: container([e1, e2]))
    let offered = [e1, e2, x, y].map { LXMFPropagation.transientId(lxmfData: $0) }
    #expect(store.wanted(fromOffered: offered) == [x, y].map { LXMFPropagation.transientId(lxmfData: $0) })
}

@Test func propagationStoreWantedDedupsWithinOffer() throws {
    let store = PropagationStore(minStampCost: 0)   // empty
    let x = entry(dest: 0xAA, tail: "xx"), y = entry(dest: 0xAA, tail: "yy")
    let tx = LXMFPropagation.transientId(lxmfData: x), ty = LXMFPropagation.transientId(lxmfData: y)
    #expect(store.wanted(fromOffered: [tx, tx, ty]) == [tx, ty])
}

@Test func propagationStoreWantedEmptyWhenAllPresent() throws {
    var store = PropagationStore(minStampCost: 0)
    let e1 = entry(dest: 0xAA, tail: "e1"), e2 = entry(dest: 0xAA, tail: "e2")
    store.ingest(container: container([e1, e2]))
    let offered = [e1, e2].map { LXMFPropagation.transientId(lxmfData: $0) }
    #expect(store.wanted(fromOffered: offered).isEmpty)
}

@Test func propagationStoreGathersEntriesByTransientIdInOrder() {
    // Three distinct entries addressed to any destinations.
    let d1 = LXMFPropagation.lxmfData(destinationHash: Data(repeating: 0xA1, count: LXMessage.destinationLength),
                                      encryptedData: Data("one".utf8))
    let d2 = LXMFPropagation.lxmfData(destinationHash: Data(repeating: 0xA2, count: LXMessage.destinationLength),
                                      encryptedData: Data("two".utf8))
    let d3 = LXMFPropagation.lxmfData(destinationHash: Data(repeating: 0xA3, count: LXMessage.destinationLength),
                                      encryptedData: Data("three".utf8))
    let tid1 = LXMFPropagation.transientId(lxmfData: d1)
    _ = LXMFPropagation.transientId(lxmfData: d2)   // d2 intentionally excluded from the query
    let tid3 = LXMFPropagation.transientId(lxmfData: d3)
    let absent = Data(repeating: 0xFF, count: 32)

    var store = PropagationStore(minStampCost: 0)
    _ = store.ingest(container: LXMFPropagation.container(timestamp: 1700000000.5, entries: [d1, d2, d3]))

    // Requested order [tid3, absent, tid1] → [d3, d1]: order preserved, absent skipped, tid2 excluded.
    let got = store.entries(forTransientIds: [tid3, absent, tid1]).map(\.lxmfData)
    #expect(got == [d3, d1])
    #expect(store.entries(forTransientIds: []).isEmpty)
}

/// Ingest rejects an entry whose stamp is absent or under the min cost; accepts one with a valid stamp.
/// Cost 4 keeps the PoW search fast (avg ~16 hash iterations over the 1000-round PN workblock).
@Test func ingestRejectsUnderCostStamp() {
    var store = PropagationStore(minStampCost: 4)
    let dest = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    // Valid entry: destHash ‖ ciphertext ‖ generatePnStamp(transientId, targetCost: 4).
    // transientId is computed over the stampless core (dest ‖ ciphertext), matching validatePnStamp.
    let validCore = dest + Data("valid-ciphertext".utf8)
    let validTid = LXMFPropagation.transientId(lxmfData: validCore)
    let validStamp = LXStamper.generatePnStamp(transientId: validTid, targetCost: 4)
    let validEntry = validCore + validStamp
    // Bad entry: destHash ‖ ciphertext ‖ 32 zero bytes — the zero stamp is not a valid cost-4 PN stamp
    // (full_hash(workblock ‖ zeros) overwhelmingly lacks 4 leading zero bits), so it must be rejected.
    let badCore = dest + Data("bad-ciphertext".utf8)
    let badEntry = badCore + Data(repeating: 0x00, count: LXStamper.stampSize)
    store.ingest(container: container([validEntry]))
    store.ingest(container: container([badEntry]))
    #expect(store.transientIds.count == 1)   // only the validEntry was accepted
}
