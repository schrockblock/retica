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
    }

    private var stored: [Data: Entry] = [:]
    private var nextSequence: Int = 0
    /// Total-storage cap in bytes; nil = unbounded (RNS default). Sum of stored lxmf_data sizes.
    public var storageLimitBytes: Int?

    public init(storageLimitBytes: Int? = nil) {
        self.storageLimitBytes = storageLimitBytes
    }

    public var count: Int { stored.count }
    public var sizeBytes: Int { stored.values.reduce(0) { $0 + $1.lxmfData.count } }

    public func contains(transientId: Data) -> Bool { stored[transientId] != nil }

    @discardableResult
    public mutating func ingest(container: Data) -> [Data] {
        guard let (_, lxmfDatas) = LXMFPropagation.parseContainer(container) else { return [] }
        var added: [Data] = []
        for lxmfData in lxmfDatas {
            guard let dest = LXMFPropagation.destinationHash(lxmfData: lxmfData) else { continue }
            // Strip the trailing propagation stamp (32 bytes) to compute the canonical transient_id over the
            // pure lxmf_data. Real entries always have an encrypted tail of ≥ 60 bytes, so stamped entries are
            // always > destHash(16) + stamp(32) = 48 bytes; test-only short helpers are ≤ 48 → no strip.
            // The original lxmfData (possibly stamped) is stored so that PN→PN sync re-delivers stamped
            // entries, letting the receiving PN strip identically and arrive at the same transient_id.
            let lxmfCore = lxmfData.count > LXMessage.destinationLength + LXStamper.stampSize
                ? Data(lxmfData.dropLast(LXStamper.stampSize))
                : lxmfData
            let tid = LXMFPropagation.transientId(lxmfData: lxmfCore)
            if stored[tid] != nil { continue }   // dedup by transient_id
            stored[tid] = Entry(transientId: tid, destinationHash: dest, lxmfData: lxmfData, sequence: nextSequence)
            nextSequence += 1
            added.append(tid)
        }
        evictOverLimit()
        return added.filter { stored[$0] != nil }
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

    private mutating func evictOverLimit() {
        guard let limit = storageLimitBytes else { return }
        while sizeBytes > limit, let oldest = stored.values.min(by: { $0.sequence < $1.sequence }) {
            stored[oldest.transientId] = nil
        }
    }
}
