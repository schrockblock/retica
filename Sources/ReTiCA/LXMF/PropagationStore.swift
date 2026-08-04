import Foundation

/// A propagation node's store-and-forward message store (LXMF-4d-3). Ingests propagation containers
/// (msgpack([timestamp, [lxmf_data…]])), dedups entries by transient_id, evicts oldest under an optional
/// storage limit, and serves entries by recipient destination. Pure value type — a propagation node (or
/// its future reducer) holds one. Mirrors lxmf 1.1.0 LXMRouter message storage (propagation_resource_
/// concluded / clean_message_store); peering, stamps, and persistence are out of scope.
public struct PropagationStore: Equatable {
    public struct Entry: Equatable {
        public var transientId: Data
        public var destinationHash: Data
        public var lxmfData: Data
        var sequence: Int

        /// Public construction for hosts mirroring the store (persistence, tests). `sequence` is the
        /// store's internal ordering and is not part of a host's contract, so it defaults to 0 —
        /// entries built this way are values to persist/compare, not to insert into a store.
        public init(transientId: Data, destinationHash: Data, lxmfData: Data) {
            self.transientId = transientId
            self.destinationHash = destinationHash
            self.lxmfData = lxmfData
            self.sequence = 0
        }

        /// Internal construction used by the store itself, preserving the insertion-order sequence.
        init(transientId: Data, destinationHash: Data, lxmfData: Data, sequence: Int) {
            self.transientId = transientId
            self.destinationHash = destinationHash
            self.lxmfData = lxmfData
            self.sequence = sequence
        }
    }

    private var stored: [Data: Entry] = [:]
    private var nextSequence: Int = 0
    /// Total-storage cap in bytes; nil = unbounded (RNS default). Sum of stored lxmf_data sizes.
    public var storageLimitBytes: Int?
    /// Minimum PoW stamp cost required on each inbound propagation entry (RNS PROPAGATION_COST = 16).
    /// Entries whose stamp is absent or below this cost are silently rejected. Set to 0 to accept all
    /// entries regardless of stamp (e.g. in tests using synthetic unstamped entries).
    public var minStampCost: Int

    public init(storageLimitBytes: Int? = nil,
                minStampCost: Int = LXMFPropagation.defaultPropagationStampCost) {
        self.storageLimitBytes = storageLimitBytes
        self.minStampCost = minStampCost
    }

    public var count: Int { stored.count }
    public var sizeBytes: Int { stored.values.reduce(0) { $0 + $1.lxmfData.count } }

    public func contains(transientId: Data) -> Bool { stored[transientId] != nil }

    /// Ingest a propagation container. Returns `(added, evicted, rejected)` where:
    /// - `added` are transient_ids newly accepted and retained after eviction,
    /// - `evicted` are transient_ids accepted then immediately evicted to stay under `storageLimitBytes`,
    /// - `rejected` is the count of entries that failed stamp validation (absent or below `minStampCost`).
    ///
    /// A **duplicate** entry (already-stored transient_id) is NOT counted as rejected — it simply
    /// contributes neither to `added` nor to `rejected`. The caller must distinguish "all new entries
    /// passed policy" (`rejected == 0`) from "nothing was newly stored" (could be all-duplicates).
    ///
    /// The host must persist `added` AND delete `evicted` so its mirror stays in sync with the in-memory store.
    @discardableResult
    public mutating func ingest(container: Data) -> (added: [Data], evicted: [Data], rejected: Int) {
        guard let (_, lxmfDatas) = LXMFPropagation.parseContainer(container) else { return ([], [], 0) }
        var added: [Data] = []
        var rejected = 0
        for lxmfData in lxmfDatas {
            let tid: Data
            let destData: Data
            if minStampCost > 0 {
                // Require a valid PN stamp at or above minStampCost. validatePnStamp strips the trailing
                // 32-byte stamp and returns transient_id = full_hash(stampless_entry) — the canonical dedup
                // key matching the sender (LXMFPropagation.pack) and peer re-sync. Entries with an absent
                // or under-cost stamp are policy-rejected (counted for the caller's prove decision).
                guard let validated = LXStamper.validatePnStamp(transientData: lxmfData, targetCost: minStampCost) else {
                    rejected += 1
                    continue
                }
                guard let dest = LXMFPropagation.destinationHash(lxmfData: validated.lxmfData) else {
                    rejected += 1
                    continue
                }
                tid = validated.transientId
                destData = dest
            } else {
                // minStampCost == 0: accept without stamp validation (backward-compat / test helper path).
                // Strip the trailing stamp if present (> destHash(16) + stamp(32) bytes), otherwise use as-is.
                guard let dest = LXMFPropagation.destinationHash(lxmfData: lxmfData) else { continue }
                let lxmfCore = LXMFPropagation.strippedCore(lxmfData: lxmfData)
                tid = LXMFPropagation.transientId(lxmfData: lxmfCore)
                destData = dest
            }
            if stored[tid] != nil { continue }   // dedup by transient_id — NOT a rejection
            // Store the full stamped bytes (lxmfData) so PN→PN sync re-delivers the stamped entry,
            // letting the receiving PN validate and arrive at the same transient_id.
            stored[tid] = Entry(transientId: tid, destinationHash: destData, lxmfData: lxmfData, sequence: nextSequence)
            nextSequence += 1
            added.append(tid)
        }
        let evicted = evictOverLimit()
        let evictedSet = Set(evicted)
        return (added: added.filter { !evictedSet.contains($0) }, evicted: evicted, rejected: rejected)
    }

    public func entries(forDestination destinationHash: Data) -> [Entry] {
        stored.values.filter { $0.destinationHash == destinationHash }.sorted { $0.sequence < $1.sequence }
    }

    /// The entries this store holds for a set of transient_ids — used to build a peer-sync transfer of the
    /// messages a peer requested (`/offer` wanted list). Preserves the requested order; silently skips ids
    /// not present (a peer may want an id we have since evicted).
    public func entries(forTransientIds ids: [Data]) -> [Entry] {
        ids.compactMap { stored[$0] }
    }

    public mutating func remove(transientId: Data) {
        stored[transientId] = nil
    }

    /// All stored transient_ids, oldest-first — a propagation node's "offer" set to a peer.
    public var transientIds: [Data] {
        stored.values.sorted { $0.sequence < $1.sequence }.map { $0.transientId }
    }

    /// Of a peer's offered transient_ids, the ones this store is missing (and would pull). Preserves the
    /// offered order and de-duplicates repeated ids within the offer. Mirrors LXMRouter.offer_request
    /// wanted_ids — the dedup heart of PN↔PN gossip (convergence rests on transient_id, LXMF-4d-1).
    public func wanted(fromOffered offered: [Data]) -> [Data] {
        var seen = Set<Data>()
        return offered.filter { !contains(transientId: $0) && seen.insert($0).inserted }
    }

    /// Evicts oldest entries until `sizeBytes <= storageLimitBytes`. Returns the evicted transient_ids
    /// so the caller can surface them for host-mirror cleanup.
    @discardableResult
    private mutating func evictOverLimit() -> [Data] {
        guard let limit = storageLimitBytes else { return [] }
        var evicted: [Data] = []
        while sizeBytes > limit, let oldest = stored.values.min(by: { $0.sequence < $1.sequence }) {
            stored[oldest.transientId] = nil
            evicted.append(oldest.transientId)
        }
        return evicted
    }
}
