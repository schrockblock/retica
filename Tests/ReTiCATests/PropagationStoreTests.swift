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
    var store = PropagationStore(targetStampCost: 0)
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
    var store = PropagationStore(targetStampCost: 0)
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
    var store = PropagationStore(targetStampCost: 0)
    let e = entry(dest: 0xAA, tail: "x")
    let tid = LXMFPropagation.transientId(lxmfData: e)
    store.ingest(container: container([e]))
    store.remove(transientId: tid)
    #expect(store.count == 0)
    #expect(!store.contains(transientId: tid))
}

@Test func propagationStoreEvictsOldestOverLimit() throws {
    // Each entry is 16 + 4 = 20 bytes; a 45-byte limit holds at most 2.
    var store = PropagationStore(storageLimitBytes: 45, targetStampCost: 0)
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
    var store = PropagationStore(storageLimitBytes: 25, targetStampCost: 0)
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
    var store = PropagationStore(targetStampCost: 0)
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
    var store = PropagationStore(targetStampCost: 0)
    let e1 = entry(dest: 0xAA, tail: "e1"), e2 = entry(dest: 0xAA, tail: "e2"), e3 = entry(dest: 0xBB, tail: "e3")
    store.ingest(container: container([e1, e2, e3]))
    #expect(store.transientIds == [e1, e2, e3].map { LXMFPropagation.transientId(lxmfData: $0) })
}

/// Entries that fail stamp validation (absent or below targetStampCost) are silently skipped and
/// must not be added to the store.
@Test func propagationStoreSkipsUnderCostStampEntries() throws {
    var store = PropagationStore(targetStampCost: 4)
    // An unstamped entry: 16-byte dest + payload, no PN stamp → stamp cost effectively 0 < 4.
    let bad = entry(dest: 0xAA, tail: "no-stamp")
    let (added, _) = store.ingest(container: container([bad]))
    #expect(added.isEmpty, "unstamped entry must not be added")
    #expect(store.count == 0, "store must remain empty after rejecting under-cost entry")
}

@Test func propagationStoreWantedReturnsMissingInOfferedOrder() throws {
    var store = PropagationStore(targetStampCost: 0)
    let e1 = entry(dest: 0xAA, tail: "e1"), e2 = entry(dest: 0xAA, tail: "e2")
    let x = entry(dest: 0xAA, tail: "xx"), y = entry(dest: 0xAA, tail: "yy")
    store.ingest(container: container([e1, e2]))
    let offered = [e1, e2, x, y].map { LXMFPropagation.transientId(lxmfData: $0) }
    #expect(store.wanted(fromOffered: offered) == [x, y].map { LXMFPropagation.transientId(lxmfData: $0) })
}

@Test func propagationStoreWantedDedupsWithinOffer() throws {
    let store = PropagationStore(targetStampCost: 0)   // empty
    let x = entry(dest: 0xAA, tail: "xx"), y = entry(dest: 0xAA, tail: "yy")
    let tx = LXMFPropagation.transientId(lxmfData: x), ty = LXMFPropagation.transientId(lxmfData: y)
    #expect(store.wanted(fromOffered: [tx, tx, ty]) == [tx, ty])
}

@Test func propagationStoreWantedEmptyWhenAllPresent() throws {
    var store = PropagationStore(targetStampCost: 0)
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

    var store = PropagationStore(targetStampCost: 0)
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
/// `targetStampCost = 255`. The premise was false: `LXStamper.validatePnStamp` VALIDATES rather than
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
    let core = dest + Data("dedup-test-payload".utf8) + pastLengthRule
    let tid = LXMFPropagation.transientId(lxmfData: core)
    let stamp = await LXStamper.generatePnStamp(transientId: tid, targetCost: 4)!
    let stamped = core + stamp
    var store = PropagationStore(targetStampCost: 4)

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
    let cores = (1...3).map { i in dest + Data("parity-payload-\(i)".utf8) + pastLengthRule }
    var entries: [Data] = []
    for core in cores {
        let tid = LXMFPropagation.transientId(lxmfData: core)
        let stamp = await LXStamper.generatePnStamp(transientId: tid, targetCost: 4)!
        entries.append(core + stamp)
    }
    var store = PropagationStore(targetStampCost: 4)
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
    var store = PropagationStore(targetStampCost: 4)
    let dest = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    // Valid entry: destHash ‖ ciphertext ‖ generatePnStamp(transientId, targetCost: 4).
    // transientId is computed over the stampless core (dest ‖ ciphertext), matching validatePnStamp.
    let validCore = dest + Data("valid-ciphertext".utf8) + pastLengthRule
    let validTid = LXMFPropagation.transientId(lxmfData: validCore)
    let validStamp = await LXStamper.generatePnStamp(transientId: validTid, targetCost: 4)!
    let validEntry = validCore + validStamp
    // Bad entry: destHash ‖ ciphertext ‖ 32 zero bytes — the zero stamp is not a valid cost-4 PN stamp
    // (full_hash(workblock ‖ zeros) overwhelmingly lacks 4 leading zero bits), so it must be rejected.
    let badCore = dest + Data("bad-ciphertext".utf8) + pastLengthRule
    let badEntry = badCore + Data(repeating: 0x00, count: LXStamper.stampSize)
    store.ingest(container: container([validEntry]))
    store.ingest(container: container([badEntry]))
    #expect(store.transientIds.count == 1)   // only the validEntry was accepted
}

/// Pads a stampless core past reference's length rule: a stamped entry must be longer than
/// LXMF_OVERHEAD (112) + STAMP_SIZE (32) bytes (`LXStamper.minimumStampedEntryLength`).
private let pastLengthRule = Data(repeating: 0x5E, count: LXMessage.lxmfOverhead)

// MARK: - Reference's length rule (F1)

/// Reference refuses a stamped propagation entry of 144 bytes or fewer before validating anything
/// (`validate_pn_stamp`: `len(transient_data) <= LXMF_OVERHEAD + STAMP_SIZE`, LXStamper.py:33;
/// cross-validated at cost 0 in LXMFFractionalCostAppDataCrossValidationTests, `pn_length`). We
/// used to accept anything over 32 bytes, so a short junk entry with a valid stamp was stored and
/// gossiped, and a reference peer would throttle us for passing it on.
///
/// Anti-vacuity: both entries carry a REAL stamp valid at cost 8 over their own transient id, so the
/// 144-byte refusal can only be the length rule, and the 145-byte acceptance shows the rule is not
/// refusing everything. Asserted at all three sites that apply it: the validator, the store's cheap
/// preflight, and ingest.
@Test func propagationEntryOf144BytesIsRefusedAnd145Accepted() async throws {
    for (coreLength, accepted) in [(112, false), (113, true)] {
        let core = Data(repeating: 0xAB, count: LXMessage.destinationLength)
            + Data(repeating: 0x33, count: coreLength - LXMessage.destinationLength)
        let tid = LXMFPropagation.transientId(lxmfData: core)
        let stamp = try #require(await LXStamper.generatePnStamp(transientId: tid, targetCost: 8))
        let stamped = core + stamp
        #expect(stamped.count == coreLength + LXStamper.stampSize)
        let wb = LXStamper.stampWorkblock(material: tid, expandRounds: LXStamper.workblockExpandRoundsPN)
        #expect(LXStamper.stampValid(stamp: stamp, targetCost: 8, workblock: wb), "setup: the stamp is valid")
        #expect((LXStamper.validatePnStamp(transientData: stamped, targetCost: 8) != nil) == accepted,
                "\(stamped.count) bytes")
        var store = PropagationStore(targetStampCost: 8)
        #expect((store.preflightTransientId(ofStampedEntry: stamped) != nil) == accepted, "\(stamped.count) bytes")
        #expect(store.ingest(container: container([stamped])).added.count == (accepted ? 1 : 0),
                "\(stamped.count) bytes")
    }
}

// MARK: - Fractional acceptance cost: max(0, cost - flex)

/// A stamp whose value lies in `range`, found by generating at `range.lowerBound` and keeping the
/// first stamp whose value is below the upper bound. Selecting on the computed value makes the test
/// deterministic (no luck in which side of a boundary a stamp lands).
private func stampedEntry(valueIn range: Range<Double>, label: String = "flex") async throws -> (entry: Data, value: Double) {
    for attempt in 0..<64 {
        let core = Data(repeating: 0xEE, count: LXMessage.destinationLength)
            + Data("\(label)-\(attempt)".utf8) + pastLengthRule
        let tid = LXMFPropagation.transientId(lxmfData: core)
        let stamp = try #require(await LXStamper.generatePnStamp(transientId: tid, targetCost: range.lowerBound))
        let validated = try #require(LXStamper.validatePnStamp(transientData: core + stamp,
                                                               targetCost: range.lowerBound))
        if range.contains(validated.value) { return (core + stamp, validated.value) }
    }
    Issue.record("no stamp with a value in \(range) in 64 attempts")
    return (Data(), 0)
}

/// Review Focus 5 at the store, with real stamps: a node asking 12.5 with flexibility 3.25 accepts
/// at 9.25 (reference `min_accepted_cost = max(0, cost - flex)`, LXMRouter.py:2577 / :2740), so a
/// stamp worth between 9.25 and 12.5 is stored by it and refused by the same node without the
/// flexibility. The exact boundary (13.0 accepted, 12.996 refused at 16 - 3) is pinned with
/// reference-constructed hashes in LXMFFractionalCostAppDataCrossValidationTests.
///
/// Anti-vacuity: the stamp's value is asserted below 12.5, so the strict store's refusal is real,
/// and at or above 9.25, so the flexible store's acceptance is the flexibility at work. Validating at
/// `targetStampCost` instead of `minAcceptedStampCost` fails the first ingest.
@Test func storeAcceptsAStampWithinItsFlexibilityAndRefusesItWithout() async throws {
    let (stamped, value) = try await stampedEntry(valueIn: 9.25..<12.5)
    #expect(value >= 9.25 && value < 12.5)

    var flexible = PropagationStore(targetStampCost: 12.5, stampCostFlexibility: 3.25)
    #expect(flexible.minAcceptedStampCost == 9.25)
    #expect(flexible.ingest(container: container([stamped])).added.count == 1)

    var strict = PropagationStore(targetStampCost: 12.5)
    #expect(strict.minAcceptedStampCost == 12.5)
    #expect(strict.ingest(container: container([stamped])).added.isEmpty)
}

/// I1: `ingest` records each validated entry's real stamp value, and the offer set for a peer keeps an
/// entry exactly when that value meets the peer's minimum (reference drops `get_stamp_value(tid) <
/// min_accepted_cost`, LXMPeer.py:345). Two real stamps with different values: at the higher value only
/// that entry is offered, one 1/256 step above it neither is, at the lower value both are.
///
/// Anti-vacuity: the values are asserted distinct and recorded from validation, so a store that did not
/// record them (nil, counted as 0) offers nothing at the lower value, and one that ignored `minimum`
/// offers both at the higher.
@Test func offerSetKeepsEntriesWhoseRecordedStampValueMeetsThePeerMinimum() async throws {
    let low = try await stampedEntry(valueIn: 8..<10, label: "offer-low")
    let high = try await stampedEntry(valueIn: 10..<64, label: "offer-high")
    #expect(low.value < high.value)
    var store = PropagationStore(targetStampCost: 8)
    let added = store.ingest(container: container([low.entry, high.entry])).added
    #expect(added.count == 2)
    let lowId = try #require(store.preflightTransientId(ofStampedEntry: low.entry))
    let highId = try #require(store.preflightTransientId(ofStampedEntry: high.entry))
    #expect(store.entries(forTransientIds: [lowId, highId]).map(\.stampValue) == [low.value, high.value])

    #expect(store.transientIds(acceptedAt: high.value) == [highId])
    #expect(store.transientIds(acceptedAt: high.value + 1.0 / 256).isEmpty)
    #expect(store.transientIds(acceptedAt: low.value) == [lowId, highId])           // oldest-first
    #expect(store.transientIds(acceptedAt: .infinity).isEmpty)
}

/// Flexibility at or above the target gives an acceptance cost of 0 (reference's `max(0, …)`), not a
/// negative one, and the store still validates (it does not fall into the cost-0 "no validation"
/// path, which is keyed on the TARGET): an entry under the length rule is still refused.
@Test func flexibilityAboveTheTargetFloorsAtZeroAndStillValidates() async throws {
    var store = PropagationStore(targetStampCost: 8, stampCostFlexibility: 12)
    #expect(store.minAcceptedStampCost == 0)
    let short = Data(repeating: 0xAB, count: LXMessage.destinationLength) + Data(repeating: 0x01, count: 96)
        + Data(repeating: 0xFF, count: LXStamper.stampSize)          // 144 bytes
    #expect(store.ingest(container: container([short])).added.isEmpty)
}

// MARK: - Configured costs are sanitized

/// The configured target, flexibility (and, in PNNode, peering cost) are read by `PNAnnounce.packed`
/// and by `LXStamper`, so a NaN, infinity, negative or 100-plus value must never get in. The target
/// keeps its previous value on a refused write (at init: the default 16), as reference's
/// `set_inbound_stamp_cost` keeps a refused cost; a negative flexibility becomes 0, as lxmd clamps it
/// (lxmd.py:195-196); NaN, +infinity and 100 or more keep the previous flexibility.
///
/// Anti-vacuity: every refused write is preceded by a known fractional value, so "kept" is
/// distinguishable from "reset", and the fractional values themselves show the setter does not round.
@Test func configuredPropagationCostsAreSanitized() {
    let atInit = PropagationStore(targetStampCost: .nan, stampCostFlexibility: -2)
    #expect(atInit.targetStampCost == LXMFPropagation.defaultPropagationStampCost)
    #expect(atInit.stampCostFlexibility == 0)
    #expect(PropagationStore(targetStampCost: 100).targetStampCost == LXMFPropagation.defaultPropagationStampCost)
    #expect(PropagationStore(stampCostFlexibility: .infinity).stampCostFlexibility == 0)

    var store = PropagationStore(targetStampCost: 13.5, stampCostFlexibility: 2.5)
    for bad in [Double.nan, .infinity, -.infinity, -1, 100, 1e300] {
        store.targetStampCost = bad
        #expect(store.targetStampCost == 13.5, "target \(bad)")
    }
    store.targetStampCost = 0                                 // 0 is allowed: validation off
    #expect(store.targetStampCost == 0)
    for bad in [Double.nan, .infinity, 100] {
        store.stampCostFlexibility = bad
        #expect(store.stampCostFlexibility == 2.5, "flex \(bad)")
    }
    for negative in [-1, -Double.infinity] {
        store.stampCostFlexibility = 2.5
        store.stampCostFlexibility = negative
        #expect(store.stampCostFlexibility == 0, "flex \(negative)")
    }
}
