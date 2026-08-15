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
    let (firstAdded, firstEvicted) = store.ingest(container: container([e]))
    #expect(firstAdded == [tid])
    #expect(firstEvicted.isEmpty)
    #expect(store.count == 1)
    #expect(store.contains(transientId: tid))
    // Re-ingesting the identical container is a no-op (dedup by transient_id).
    let (secondAdded, secondEvicted) = store.ingest(container: container([e]))
    #expect(secondAdded.isEmpty)
    #expect(secondEvicted.isEmpty)
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

/// When the storage limit is hit, `ingest` reports the evicted transient_ids separately from the
/// accepted ones so a host's mirror can delete them. Without this signal the mirror grows without
/// bound across relaunches (Important-1).
@Test func propagationStoreIngestReturnsEvictedIds() throws {
    // 16-byte dest + 4-byte tail = 20 bytes per entry; cap at 25 bytes → each ingest of a new entry
    // evicts the previous one.
    var store = PropagationStore(storageLimitBytes: 25, minStampCost: 0)
    let e1 = entry(dest: 0xAA, tail: "aaaa")
    let e2 = entry(dest: 0xAA, tail: "bbbb")
    let tid1 = LXMFPropagation.transientId(lxmfData: e1)
    let tid2 = LXMFPropagation.transientId(lxmfData: e2)

    let (added1, evicted1) = store.ingest(container: container([e1]))
    #expect(added1 == [tid1])
    #expect(evicted1.isEmpty)   // nothing to evict yet — e1 fits alone

    // e2 pushes over the cap → e1 is evicted; added contains only the survivors.
    let (added2, evicted2) = store.ingest(container: container([e2]))
    #expect(evicted2 == [tid1])   // oldest evicted
    #expect(added2 == [tid2])     // e2 survived (net-new after eviction)
    #expect(!store.contains(transientId: tid1))
    #expect(store.contains(transientId: tid2))
}

@Test func propagationStoreSkipsMalformedEntries() throws {
    var store = PropagationStore(minStampCost: 0)
    // Short entry (< 16 bytes) is skipped; the well-formed one is stored.
    let shortEntry = Data([0x01, 0x02, 0x03])
    let good = entry(dest: 0xAA, tail: "ok")
    let (added, evicted) = store.ingest(container: container([shortEntry, good]))
    #expect(added == [LXMFPropagation.transientId(lxmfData: good)])
    #expect(evicted.isEmpty)
    #expect(store.count == 1)
    // A non-container blob ingests to nothing.
    #expect(store.ingest(container: Data([0xFF, 0xFF])).added.isEmpty)
    #expect(store.count == 1)
}

@Test func propagationStoreOffersAllTransientIdsOldestFirst() throws {
    var store = PropagationStore(minStampCost: 0)
    let e1 = entry(dest: 0xAA, tail: "e1"), e2 = entry(dest: 0xAA, tail: "e2"), e3 = entry(dest: 0xBB, tail: "e3")
    store.ingest(container: container([e1, e2, e3]))
    #expect(store.transientIds == [e1, e2, e3].map { LXMFPropagation.transientId(lxmfData: $0) })
}

/// Entries that fail stamp validation (absent or below minStampCost) are silently skipped and
/// must not be added to the store.
@Test func propagationStoreSkipsUnderCostStampEntries() throws {
    var store = PropagationStore(minStampCost: 4)
    // An unstamped entry: 16-byte dest + payload, no PN stamp → stamp cost effectively 0 < 4.
    let bad = entry(dest: 0xAA, tail: "no-stamp")
    let (added, _) = store.ingest(container: container([bad]))
    #expect(added.isEmpty, "unstamped entry must not be added")
    #expect(store.count == 0, "store must remain empty after rejecting under-cost entry")
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

// MARK: - Task 5: cheap-before-expensive ordering

/// Structural guard for the Task-5 ordering fix: re-ingesting a stored duplicate must derive ZERO
/// stamp workblocks — the cheap transient_id dedup has to run BEFORE the proof-of-work, not after.
///
/// This asserts on WORK DONE, and it has to. Every outcome of ingesting a duplicate is identical
/// with and without the preflight (nothing is added, the count does not move), so a test that
/// asserts outcomes passes with the entire preflight deleted — which is exactly what the guard this
/// replaces did.
///
/// That predecessor claimed a missing preflight would make the call "hang indefinitely" at
/// `minStampCost = 255`. The premise was false: `LXStamper.validatePnStamp` VALIDATES rather than
/// SEARCHES — one workblock plus one hash, O(1) in `targetCost` (LXStamper.swift:validatePnStamp) —
/// so cost 255 costs exactly what cost 1 costs, about 21 ms. Nothing hangs, and nothing failed:
/// measured in the fix round, deleting the preflight is caught by exactly two tests out of 907, this
/// one and `LXMFServiceNodeTests.serviceNodeDoesNotRederiveWorkblockForStoredPacketOfferReplay`. Both
/// are new. No outcome-based test in the suite notices at all.
///
/// The first (novel) ingest is asserted to derive AT LEAST ONE workblock. That half is not padding:
/// without it, a counting seam that silently observed nothing would make the zero-assertion pass for
/// the wrong reason, reproducing the vacuity this test exists to remove.
@Test func duplicateIngestDerivesNoStampWorkblock() async {
    let dest = Data(repeating: 0xAB, count: LXMessage.destinationLength)
    let core = dest + Data("dedup-test-payload".utf8)
    let tid = LXMFPropagation.transientId(lxmfData: core)
    let stamp = await LXStamper.generatePnStamp(transientId: tid, targetCost: 4)!
    let stamped = core + stamp
    var store = PropagationStore(minStampCost: 4)

    // Novel entry: the stamp is unknown, so it MUST be validated — proving the seam is live.
    let onFirstIngest = LXStamper.WorkblockCounter()
    LXStamper.$workblockCounter.withValue(onFirstIngest) {
        store.ingest(container: container([stamped]))
    }
    #expect(store.contains(transientId: tid), "setup: the entry must be accepted and stored")
    #expect(onFirstIngest.count >= 1,
            "seam liveness: validating a novel entry must derive at least one workblock")

    // Byte-identical replay: recognised by transient_id before any PoW is spent on it.
    let onReplay = LXStamper.WorkblockCounter()
    let (added, _) = LXStamper.$workblockCounter.withValue(onReplay) {
        store.ingest(container: container([stamped]))
    }
    #expect(onReplay.count == 0,
            "a stored duplicate must be skipped before any stamp workblock is derived")
    #expect(added.isEmpty, "duplicate must not be re-added")
    #expect(store.count == 1, "store count unchanged after duplicate ingest")
}

/// Acceptance-parity test: a known-good stamped container is accepted identically regardless
/// of the ordering of cheap vs expensive checks. Demonstrates that the Task-5 reordering
/// changes *when* effort is spent, not *what* is accepted.
@Test func stampedContainerAcceptanceIsUnchangedByOrdering() async {
    let dest = Data(repeating: 0xCC, count: LXMessage.destinationLength)
    let cores = (1...3).map { i in dest + Data("parity-payload-\(i)".utf8) }
    var entries: [Data] = []
    for core in cores {
        let tid = LXMFPropagation.transientId(lxmfData: core)
        let stamp = await LXStamper.generatePnStamp(transientId: tid, targetCost: 4)!
        entries.append(core + stamp)
    }
    var store = PropagationStore(minStampCost: 4)
    let (added, evicted) = store.ingest(container: container(entries))
    // All three valid entries must be accepted; no eviction (no storage cap set).
    #expect(added.count == 3, "all valid stamped entries must be accepted")
    #expect(evicted.isEmpty, "no eviction expected without a storage cap")
    // Each accepted transient_id must match the canonical value for the stampless core.
    let expectedTids = cores.map { LXMFPropagation.transientId(lxmfData: $0) }
    #expect(Set(added) == Set(expectedTids), "transient_ids must match canonical full_hash(stampless core)")
    // Re-ingesting the same container is still a no-op.
    let (addedAgain, _) = store.ingest(container: container(entries))
    #expect(addedAgain.isEmpty, "re-ingest of accepted container must be a no-op")
}

/// Ingest rejects an entry whose stamp is absent or under the min cost; accepts one with a valid stamp.
/// Cost 4 keeps the PoW search fast (avg ~16 hash iterations over the 1000-round PN workblock).
@Test func ingestRejectsUnderCostStamp() async {
    var store = PropagationStore(minStampCost: 4)
    let dest = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    // Valid entry: destHash ‖ ciphertext ‖ generatePnStamp(transientId, targetCost: 4).
    // transientId is computed over the stampless core (dest ‖ ciphertext), matching validatePnStamp.
    let validCore = dest + Data("valid-ciphertext".utf8)
    let validTid = LXMFPropagation.transientId(lxmfData: validCore)
    let validStamp = await LXStamper.generatePnStamp(transientId: validTid, targetCost: 4)!
    let validEntry = validCore + validStamp
    // Bad entry: destHash ‖ ciphertext ‖ 32 zero bytes — the zero stamp is not a valid cost-4 PN stamp
    // (full_hash(workblock ‖ zeros) overwhelmingly lacks 4 leading zero bits), so it must be rejected.
    let badCore = dest + Data("bad-ciphertext".utf8)
    let badEntry = badCore + Data(repeating: 0x00, count: LXStamper.stampSize)
    store.ingest(container: container([validEntry]))
    store.ingest(container: container([badEntry]))
    #expect(store.transientIds.count == 1)   // only the validEntry was accepted
}
