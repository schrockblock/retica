import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA

private func entry(dest: UInt8, tail: String) -> Data {
    Data(repeating: dest, count: LXMessage.destinationLength) + Data(tail.utf8)
}
private func container(_ entries: [Data]) -> Data {
    LXMFPropagation.container(timestamp: 1700000000.5, entries: entries)
}

@Test @MainActor func propagationNodeIngestsAndReportsIds() async {
    let e = entry(dest: 0xAA, tail: "one")
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let store = TestStore(initialState: PropagationNode.State(targetStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([e])))
    await store.receive { action in
        if case let .delegate(.stored(ids)) = action { #expect(ids == [tid]); return true }
        return false
    }
    #expect(store.state.store.count == 1)
    #expect(store.state.store.contains(transientId: tid))
}

@Test @MainActor func propagationNodeDedupsOnReingest() async {
    let e = entry(dest: 0xAA, tail: "one")
    let store = TestStore(initialState: PropagationNode.State(targetStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([e])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    await store.send(.ingestContainer(container([e])))   // identical → dedup
    await store.receive { action in
        if case let .delegate(.stored(ids)) = action { #expect(ids.isEmpty); return true }
        return false
    }
    #expect(store.state.store.count == 1)
}

@Test @MainActor func propagationNodeServesByDestination() async {
    let a1 = entry(dest: 0xAA, tail: "a1"), a2 = entry(dest: 0xAA, tail: "a2")
    let b1 = entry(dest: 0xBB, tail: "b1")
    let store = TestStore(initialState: PropagationNode.State(targetStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([a1, b1, a2])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    let tidA1 = LXMFPropagation.transientId(lxmfData: a1)
    let tidA2 = LXMFPropagation.transientId(lxmfData: a2)
    await store.send(.messagesRequested(destinationHash: destA, wants: [tidA1, tidA2], haves: []))
    await store.receive { action in
        if case let .delegate(.deliverMessages(dest, entries)) = action {
            #expect(dest == destA); #expect(entries == [a1, a2]); return true   // only A's, oldest-first
        }
        return false
    }
}

@Test @MainActor func propagationNodeServesStamplessSoClientTransientIdMatches() async {
    // A stamped entry (destHash ‖ tail ‖ 32-byte stamp) must be served WITHOUT the stamp — reference
    // LXMRouter.py:1551 serves lxmf_data[:-STAMP_SIZE]. The client then computes transient_id =
    // full_hash(served-bytes-as-is), which must equal the node's stored key so the phase-3 purge matches.
    let dest = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    let core = dest + Data(String(repeating: "x", count: 40).utf8)             // 56-byte stampless core (> 48)
    let stamped = core + Data(repeating: 0x77, count: LXStamper.stampSize)     // 88-byte stored entry
    let tid = LXMFPropagation.transientId(lxmfData: core)                      // stored key = full_hash(stampless)

    let store = TestStore(initialState: PropagationNode.State(targetStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([stamped])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    #expect(store.state.store.contains(transientId: tid))                      // stored under the stampless key

    await store.send(.messagesRequested(destinationHash: dest, wants: [tid], haves: []))
    await store.receive { action in
        if case let .delegate(.deliverMessages(_, entries)) = action {
            #expect(entries == [core])                                         // stamp stripped on serve
            #expect(entries != [stamped])
            #expect(LXMFPropagation.transientId(lxmfData: entries[0]) == tid)  // client's purge id will match
            return true
        }
        return false
    }
}

@Test @MainActor func propagationNodeServesEmptyWhenNoneAddressed() async {
    let store = TestStore(initialState: PropagationNode.State(targetStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    let dest = Data(repeating: 0xCC, count: LXMessage.destinationLength)
    await store.send(.messagesRequested(destinationHash: dest, wants: [], haves: []))
    await store.receive { action in
        if case let .delegate(.deliverMessages(d, entries)) = action {
            #expect(d == dest); #expect(entries.isEmpty); return true
        }
        return false
    }
}

@Test @MainActor func propagationNodeDropsDeliveredMessages() async {
    let e = entry(dest: 0xAA, tail: "one")
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    let store = TestStore(initialState: PropagationNode.State(targetStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([e])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    await store.send(.messagesDelivered(transientIds: [tid]))
    #expect(store.state.store.count == 0)
    await store.send(.messagesRequested(destinationHash: destA, wants: [tid], haves: []))
    await store.receive { action in
        if case let .delegate(.deliverMessages(_, entries)) = action { #expect(entries.isEmpty); return true }
        return false
    }
}

// MARK: - LXMF-4d-5b peer sync (mesh)

@Test @MainActor func propagationNodePeerOfferedRequestsOnlyMissing() async {
    let x = entry(dest: 0xAA, tail: "x"), y = entry(dest: 0xAA, tail: "y")
    let z = entry(dest: 0xAA, tail: "z"), w = entry(dest: 0xAA, tail: "w")
    let tid: (Data) -> Data = { LXMFPropagation.transientId(lxmfData: $0) }
    let store = TestStore(initialState: PropagationNode.State(targetStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([x, y])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    let peer = Data(repeating: 0x11, count: 16)
    await store.send(.peerOffered(peerHash: peer, transientIds: [tid(x), tid(y), tid(z), tid(w)]))
    await store.receive { action in
        if case let .delegate(.requestFromPeer(p, ids)) = action {
            #expect(p == peer); #expect(ids == [tid(z), tid(w)]); return true   // only the ids we lack
        }
        return false
    }
}

@Test @MainActor func propagationNodeOffersOurTransientIds() async {
    let e1 = entry(dest: 0xAA, tail: "e1"), e2 = entry(dest: 0xBB, tail: "e2")
    let tid: (Data) -> Data = { LXMFPropagation.transientId(lxmfData: $0) }
    let store = TestStore(initialState: PropagationNode.State(targetStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([e1, e2])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    let peer = Data(repeating: 0x11, count: 16)
    await store.send(.offerToPeer(peerHash: peer, peerMinimumAcceptedCost: 0))
    await store.receive { action in
        if case let .delegate(.offerTransientIds(p, ids)) = action {
            #expect(p == peer); #expect(ids == [tid(e1), tid(e2)]); return true   // oldest-first
        }
        return false
    }
    // These entries were accepted unvalidated (cost 0), so their value counts as 0: a peer that
    // accepts at anything above 0 is offered none of them.
    await store.send(.offerToPeer(peerHash: peer, peerMinimumAcceptedCost: 1.0 / 256))
    await store.receive { action in
        if case let .delegate(.offerTransientIds(p, ids)) = action {
            #expect(p == peer); #expect(ids.isEmpty); return true
        }
        return false
    }
}

@Test @MainActor func propagationNodeValidatesPeeringKey() async {
    let peer = Data(repeating: 0x11, count: 16)
    let peeringId = Data(repeating: 0x22, count: 32)
    let key = Data(repeating: 0x33, count: LXStamper.stampSize)
    let store = TestStore(initialState: PropagationNode.State(targetStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    // cost 0 → any key validates (leading-zero-bits >= 0 always true)
    await store.send(.validatePeeringKey(peerHash: peer, peeringId: peeringId, peeringKey: key, targetCost: 0))
    await store.receive { action in
        if case let .delegate(.peerValidated(p, valid)) = action { #expect(p == peer); #expect(valid == true); return true }
        return false
    }
    // an arbitrary key cannot meet a high cost → rejected
    await store.send(.validatePeeringKey(peerHash: peer, peeringId: peeringId, peeringKey: key, targetCost: 250))
    await store.receive { action in
        if case let .delegate(.peerValidated(_, valid)) = action { #expect(valid == false); return true }
        return false
    }
}

// MARK: - P3a two-phase serve (/get)

/// Phase-1: messageListRequested returns only the destination's transient_ids, oldest-first.
@Test @MainActor func propagationNodeListsTransientIdsByDestination() async {
    let a1 = entry(dest: 0xAA, tail: "a1"), a2 = entry(dest: 0xAA, tail: "a2")
    let b1 = entry(dest: 0xBB, tail: "b1")
    let store = TestStore(initialState: PropagationNode.State(targetStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([a1, b1, a2])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    await store.send(.messageListRequested(destinationHash: destA))
    await store.receive { action in
        if case let .delegate(.deliverMessageList(dest, ids)) = action {
            #expect(dest == destA)
            #expect(ids == [LXMFPropagation.transientId(lxmfData: a1),
                            LXMFPropagation.transientId(lxmfData: a2)])   // A's only, oldest-first
            return true
        }
        return false
    }
}

/// Phase-2: only the WANTED subset is served; an unwanted entry for the same destination is withheld.
@Test @MainActor func propagationNodeServesOnlyWantedSubset() async {
    let a1 = entry(dest: 0xAA, tail: "a1"), a2 = entry(dest: 0xAA, tail: "a2")
    let store = TestStore(initialState: PropagationNode.State(targetStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([a1, a2])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    await store.send(.messagesRequested(destinationHash: destA,
                                        wants: [LXMFPropagation.transientId(lxmfData: a1)], haves: []))
    await store.receive { action in
        if case let .delegate(.deliverMessages(_, entries)) = action { #expect(entries == [a1]); return true }
        return false
    }
}

/// Phase-2: haves are purged from the store (client already has them).
@Test @MainActor func propagationNodePurgesHaves() async {
    let a1 = entry(dest: 0xAA, tail: "a1"), a2 = entry(dest: 0xAA, tail: "a2")
    let tidA1 = LXMFPropagation.transientId(lxmfData: a1)
    let tidA2 = LXMFPropagation.transientId(lxmfData: a2)
    let store = TestStore(initialState: PropagationNode.State(targetStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([a1, a2])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    await store.send(.messagesRequested(destinationHash: destA, wants: [tidA2], haves: [tidA1]))
    await store.receive { action in
        if case let .delegate(.deliverMessages(_, entries)) = action { #expect(entries == [a2]); return true }
        return false
    }
    #expect(store.state.store.contains(transientId: tidA1) == false)   // have purged
    #expect(store.state.store.contains(transientId: tidA2) == true)    // still stored (served, not delivered-acked)
}

/// Phase-2: a want for a foreign-destination or absent id is silently skipped.
@Test @MainActor func propagationNodeSkipsForeignOrAbsentWants() async {
    let a1 = entry(dest: 0xAA, tail: "a1")
    let b1 = entry(dest: 0xBB, tail: "b1")
    let store = TestStore(initialState: PropagationNode.State(targetStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([a1, b1])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    await store.send(.messagesRequested(destinationHash: destA,
                                        wants: [LXMFPropagation.transientId(lxmfData: b1),      // wrong dest
                                                Data(repeating: 0x99, count: 32)], haves: []))   // absent
    await store.receive { action in
        if case let .delegate(.deliverMessages(_, entries)) = action { #expect(entries.isEmpty); return true }
        return false
    }
}

// MARK: - Ownership check (Important-3)

/// The `haves` purge in a /get request must only remove entries owned by the requesting destination.
/// Without this check any identified client can evict entries for other destinations.
@Test @MainActor func propagationNodeDoesNotPurgeHavesOwnedByOtherDestination() async {
    let a1 = entry(dest: 0xAA, tail: "a1")   // owned by dest-AA
    let b1 = entry(dest: 0xBB, tail: "b1")   // owned by dest-BB
    let tidA1 = LXMFPropagation.transientId(lxmfData: a1)
    let tidB1 = LXMFPropagation.transientId(lxmfData: b1)
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    let store = TestStore(initialState: PropagationNode.State(targetStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([a1, b1])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }

    // Client A claims tidB1 as a have — it must NOT be purged (wrong destination).
    await store.send(.messagesRequested(destinationHash: destA, wants: [], haves: [tidB1]))
    await store.receive { action in
        if case let .delegate(.deliverMessages(_, entries)) = action { #expect(entries.isEmpty); return true }
        return false
    }
    // tidB1 must still be present — the cross-destination purge was blocked.
    #expect(store.state.store.contains(transientId: tidB1) == true)
    // tidA1 is unaffected (wasn't in haves).
    #expect(store.state.store.contains(transientId: tidA1) == true)

    store.exhaustivity = .on   // no stray .purged should remain
}

// MARK: - Transfer limit (Important-5)

/// The client's declared per-transfer limit is respected: messages that would exceed the cap are
/// skipped (not truncated, not stop-processing), matching reference LXMRouter.py:1547 `pass`.
@Test @MainActor func propagationNodeRespectsTransferLimit() async {
    // Each of a1, a2, a3 is (16 + 3) = 19 bytes stampless. overhead=16/msg, cumulative_start=24.
    // After a1: cumulative = 24 + (19+16) = 59. After a2: 59 + 35 = 94. a3 would make 129.
    // With limit 100, a3 (next_size=129 > 100) is skipped; a1 and a2 are served.
    let a1 = entry(dest: 0xAA, tail: "aa1")   // 19 bytes
    let a2 = entry(dest: 0xAA, tail: "aa2")
    let a3 = entry(dest: 0xAA, tail: "aa3")   // would push over limit
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    let tidA1 = LXMFPropagation.transientId(lxmfData: a1)
    let tidA2 = LXMFPropagation.transientId(lxmfData: a2)
    let tidA3 = LXMFPropagation.transientId(lxmfData: a3)

    let store = TestStore(initialState: PropagationNode.State(targetStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([a1, a2, a3])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }

    await store.send(.messagesRequested(destinationHash: destA, wants: [tidA1, tidA2, tidA3], haves: [],
                                        transferLimitBytes: 100))
    await store.receive { action in
        if case let .delegate(.deliverMessages(_, entries)) = action {
            #expect(entries == [a1, a2])   // a3 skipped (over limit), a1+a2 served
            #expect(entries.count == 2)
            return true
        }
        return false
    }
}

/// A zero-byte transfer limit serves nothing (not treated as unlimited — reference LXMRouter.py:1547
/// reads `float(data[2])*1000 = 0.0` which is never > 0-byte cumulative).
@Test @MainActor func propagationNodeZeroTransferLimitServesNothing() async {
    let a1 = entry(dest: 0xAA, tail: "msg")
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    let tidA1 = LXMFPropagation.transientId(lxmfData: a1)
    let store = TestStore(initialState: PropagationNode.State(targetStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([a1])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }

    await store.send(.messagesRequested(destinationHash: destA, wants: [tidA1], haves: [],
                                        transferLimitBytes: 0))
    await store.receive { action in
        if case let .delegate(.deliverMessages(_, entries)) = action { #expect(entries.isEmpty); return true }
        return false
    }
}

// MARK: - Persistence delegates

@Test @MainActor func propagationNodeEmitsStoredEntriesForPersistence() async {
    let e = entry(dest: 0xAA, tail: "persist-me")
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let store = TestStore(initialState: PropagationNode.State(targetStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([e])))
    await store.receive { action in
        if case let .delegate(.storedEntries(entries)) = action {
            #expect(entries.count == 1)
            #expect(entries[0].transientId == tid)
            #expect(entries[0].lxmfData == e)            // the bytes the host must write
            #expect(entries[0].destinationHash == Data(repeating: 0xAA, count: LXMessage.destinationLength))
            return true
        }
        return false
    }
}

/// When eviction fires during ingest (storage cap hit), the evicted ids are reported via
/// `.purged` so the host's mirror can delete them. Without this the DB grows without bound
/// across relaunches as each rehydration re-ingests then re-evicts silently (Important-1).
@Test @MainActor func propagationNodeEmitsPurgedOnEviction() async {
    // 16-byte dest + 4-byte tail = 20 bytes per entry. Limit at 25 → a second entry evicts the first.
    let e1 = entry(dest: 0xAA, tail: "aaaa")   // 20 bytes
    let e2 = entry(dest: 0xAA, tail: "bbbb")   // 20 bytes → triggers eviction of e1
    let tid1 = LXMFPropagation.transientId(lxmfData: e1)
    var initial = PropagationNode.State(storageLimitBytes: 25, targetStampCost: 0)
    let store = TestStore(initialState: initial) { PropagationNode() }
    store.exhaustivity = .off

    await store.send(.ingestContainer(container([e1])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }

    // Second ingest: e2 is accepted but e1 is evicted. A .purged must arrive for tid1.
    await store.send(.ingestContainer(container([e2])))
    // Collect all delegates from this ingest to assert .purged is present.
    var sawPurged = false
    await store.receive { action in
        if case let .delegate(.purged(ids)) = action { sawPurged = ids.contains(tid1); return true }
        return false
    }
    #expect(sawPurged)
    #expect(store.state.store.contains(transientId: tid1) == false)
}

/// Entries leave the store by two routes — the `haves` purge inside messagesRequested and the
/// messagesDelivered action. BOTH must signal, or the host's mirror drifts from the store.
@Test @MainActor func propagationNodeEmitsPurgedOnBothRemovalPaths() async {
    let a1 = entry(dest: 0xAA, tail: "a1"), a2 = entry(dest: 0xAA, tail: "a2")
    let tidA1 = LXMFPropagation.transientId(lxmfData: a1)
    let tidA2 = LXMFPropagation.transientId(lxmfData: a2)
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    let store = TestStore(initialState: PropagationNode.State(targetStampCost: 0)) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([a1, a2])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }

    // Route 1: the `haves` purge inside messagesRequested.
    await store.send(.messagesRequested(destinationHash: destA, wants: [tidA2], haves: [tidA1]))
    await store.receive { action in
        if case let .delegate(.purged(ids)) = action { #expect(ids == [tidA1]); return true }
        return false
    }
    #expect(store.state.store.contains(transientId: tidA1) == false)

    // Route 2: messagesDelivered.
    await store.send(.messagesDelivered(transientIds: [tidA2]))
    await store.receive { action in
        if case let .delegate(.purged(ids)) = action { #expect(ids == [tidA2]); return true }
        return false
    }
    #expect(store.state.store.contains(transientId: tidA2) == false)
}

