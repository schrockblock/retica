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
        /// The entry's propagation stamp value, on the 1/256 grid, recorded when `ingest` validated it
        /// (reference stores `quantize_cost` of the validated value, LXMRouter.py:2582/2768, and reads
        /// it back with `get_stamp_value` when filtering a peer offer, LXMPeer.py:345). nil when the
        /// store accepted the entry without validation (`targetStampCost == 0`); an offer counts nil as
        /// 0. Not persisted by hosts: rehydration re-runs `ingest`, which recomputes it.
        public internal(set) var stampValue: Double?
        var sequence: Int

        /// Public construction for hosts mirroring the store (persistence, tests). `sequence` is the
        /// store's internal ordering and is not part of a host's contract, so it defaults to 0 —
        /// entries built this way are values to persist/compare, not to insert into a store.
        public init(transientId: Data, destinationHash: Data, lxmfData: Data) {
            self.transientId = transientId
            self.destinationHash = destinationHash
            self.lxmfData = lxmfData
            self.stampValue = nil
            self.sequence = 0
        }

        /// Internal construction used by the store itself, preserving the insertion-order sequence.
        init(transientId: Data, destinationHash: Data, lxmfData: Data, stampValue: Double?, sequence: Int) {
            self.transientId = transientId
            self.destinationHash = destinationHash
            self.lxmfData = lxmfData
            self.stampValue = stampValue
            self.sequence = sequence
        }
    }

    private var stored: [Data: Entry] = [:]
    private var nextSequence: Int = 0
    /// Total-storage cap in bytes; nil = unbounded (RNS default). Sum of stored lxmf_data sizes.
    public var storageLimitBytes: Int?
    /// The propagation stamp cost this node asks for and advertises (LXMF 1.3.0
    /// `propagation_stamp_cost`, default 16.0). Entries are validated at `minAcceptedStampCost`, which
    /// subtracts `stampCostFlexibility` from this.
    ///
    /// 0 turns stamp validation off entirely: entries are accepted unstamped (tests using synthetic
    /// entries). Reference has no such switch; it floors a configured cost at
    /// `PROPAGATION_COST_MIN = 13` (LXMRouter.py:165), which we do not, so tests can use cheap costs.
    ///
    /// **Sanitized on every write**, because `PNAnnounce.packed` and `LXStamper` both read it: a value
    /// that is not in 0..<100 (negative, 100 or more, NaN, an infinity) is refused and the previous
    /// value kept, as reference's `set_inbound_stamp_cost` keeps its cost on a refused one
    /// (LXMRouter.py:454). At `init` a refused value falls back to the default.
    public var targetStampCost: Double {
        didSet { targetStampCost = Self.sanitizedTarget(targetStampCost, otherwise: oldValue) }
    }

    /// How far below `targetStampCost` an entry's stamp may fall and still be accepted (LXMF 1.3.0
    /// `propagation_stamp_cost_flexibility`; reference's default is 3.0, ours 0, which keeps the
    /// acceptance cost equal to the advertised one unless a host opts in).
    ///
    /// Sanitized on every write: a negative value becomes 0, as lxmd clamps it (lxmd.py:195-196); NaN,
    /// +infinity and 100 or more are refused and the previous value kept (0 at `init`).
    public var stampCostFlexibility: Double {
        didSet { stampCostFlexibility = Self.sanitizedNonNegative(stampCostFlexibility, otherwise: oldValue) }
    }

    /// The cost each inbound entry's stamp is validated at: `max(0, cost - flex)`, reference's
    /// `min_accepted_cost` (LXMRouter.py:2577, :2740). Fractional.
    public var minAcceptedStampCost: Double { max(0, targetStampCost - stampCostFlexibility) }

    public init(storageLimitBytes: Int? = nil,
                targetStampCost: Double = LXMFPropagation.defaultPropagationStampCost,
                stampCostFlexibility: Double = 0) {
        self.storageLimitBytes = storageLimitBytes
        self.targetStampCost = Self.sanitizedTarget(targetStampCost,
                                                    otherwise: LXMFPropagation.defaultPropagationStampCost)
        self.stampCostFlexibility = Self.sanitizedNonNegative(stampCostFlexibility, otherwise: 0)
    }

    /// `value` when it is in 0..<100, else `otherwise`. False comparisons make NaN fall through.
    static func sanitizedTarget(_ value: Double, otherwise: Double) -> Double {
        value >= 0 && value < Double(NetworkStamp.stampCostCap) ? value : otherwise
    }

    /// `value` in 0..<100; a negative value (including -infinity) is 0; NaN, +infinity and 100 or
    /// more give `otherwise`. The rule for a configured flexibility or peering cost.
    public static func sanitizedNonNegative(_ value: Double, otherwise: Double) -> Double {
        if value < 0 { return 0 }
        return value < Double(NetworkStamp.stampCostCap) ? value : otherwise
    }

    public var count: Int { stored.count }
    public var sizeBytes: Int { stored.values.reduce(0) { $0 + $1.lxmfData.count } }

    public func contains(transientId: Data) -> Bool { stored[transientId] != nil }

    /// The dedup key a stamped container entry (`lxmf_data ‖ stamp[32]`) would get, computed WITHOUT
    /// deriving a stamp workblock — the cheap half of `ingest`'s admission test. nil when the entry is
    /// too short for `validatePnStamp`, which refuses 144 bytes or fewer
    /// (`LXStamper.minimumStampedEntryLength`, reference LXStamper.py:33) — the same rule, so the
    /// dedup key exists exactly when validation can run.
    ///
    /// Public because a caller that pre-screens a container before handing it to `ingest`
    /// (`LXMFServiceNode`'s packet path) has to apply the SAME rule, and a second hand-written copy of
    /// "strip the trailing 32 bytes, hash the rest" is the thing that drifts.
    public func preflightTransientId(ofStampedEntry transientData: Data) -> Data? {
        guard transientData.count >= LXStamper.minimumStampedEntryLength else { return nil }
        return LXMFPropagation.transientId(lxmfData: Data(transientData.dropLast(LXStamper.stampSize)))
    }

    /// True iff this exact stamped entry — core AND stamp bytes — is already stored: a byte-identical
    /// replay of something this store already accepted, and therefore already validated.
    ///
    /// Strict on purpose. The looser test (stampless-core transient_id alone, which is what `ingest`
    /// uses) also matches an entry pairing a stored core with a DIFFERENT 32-byte tail — a genuinely
    /// invalid stamp. A caller whose observable behaviour depends on stamp validity (ERROR_INVALID_STAMP
    /// plus link teardown) must still validate that one. `ingest` can use the looser test because there
    /// the only consequence is skipping work on an entry it was going to skip anyway.
    public func containsIdenticalStampedEntry(_ transientData: Data) -> Bool {
        guard let tid = preflightTransientId(ofStampedEntry: transientData) else { return false }
        return stored[tid]?.lxmfData == transientData
    }

    /// Ingest a propagation container. Returns `(added, evicted)` where:
    /// - `added` are transient_ids newly accepted and retained after eviction,
    /// - `evicted` are transient_ids accepted then immediately evicted to stay under `storageLimitBytes`.
    ///
    /// Entries whose stamp is absent or below `minAcceptedStampCost` are silently skipped (not counted).
    /// A **duplicate** entry (already-stored transient_id) is also silently skipped — it contributes
    /// nothing to `added`.
    ///
    /// The host must persist `added` AND delete `evicted` so its mirror stays in sync with the in-memory store.
    @discardableResult
    public mutating func ingest(container: Data) -> (added: [Data], evicted: [Data]) {
        guard let (_, lxmfDatas) = LXMFPropagation.parseContainer(container) else { return ([], []) }
        var added: [Data] = []
        for lxmfData in lxmfDatas {
            let tid: Data
            let destData: Data
            var stampValue: Double? = nil
            if targetStampCost > 0 {
                // Cheap pre-filter: compute transient_id without PoW and reject duplicates before
                // spending any effort. Entries of 144 bytes or fewer are skipped here — they
                // would be rejected by validatePnStamp regardless.
                //
                // WHAT THIS CLOSES, AND WHAT IT DOES NOT. It closes a REPLAY flood: re-offering
                // entries we already hold no longer costs a workblock each. It does NOT close the
                // junk flood the task was originally scoped to, and cannot: the check skips only
                // when `stored[preflightTid] != nil`, which requires a previously ACCEPTED — hence
                // validly stamped — entry. An attacker who never produces a valid stamp is never
                // stored, never deduped, and pays the full workblock every time. Measured 21.98 ms
                // per entry, on 33-byte entries; entries of 144 bytes or fewer are now refused on
                // length first, so the cheapest such entry is 145 bytes (~6.4 KiB/s of container
                // bytes, by the same measurement, still saturates one core). That
                // residue is filed for admission control (docs/wire-narrowing-inventory.md,
                // "Task 5, precisely: a replay flood is closed, the junk flood is not");
                // reference's defence is not a cheaper check but a THROTTLE — an offer is postponed
                // while a stamp batch is validating (LXMF 1.1.0 LXMRouter.py:2274, :2398) — which we
                // do not have. Note reference dedups AFTER validating too (LXMRouter.py:2496), so
                // this preflight is an addition to reference, not parity with it.
                //
                // NOT detectable by Scripts/check-wire-narrowing.swift — a work-ordering issue, not a
                // narrowing conversion. Guarded by PropagationStoreTests.duplicateIngestDerivesNoStamp-
                // Workblock, which counts workblock derivations because every OUTCOME here is
                // identical with and without this preflight; and, for the packet path that reaches
                // ingest through LXMFServiceNode, by
                // LXMFServiceNodeTests.serviceNodeDoesNotRederiveWorkblockForStoredPacketOfferReplay.
                guard let preflightTid = preflightTransientId(ofStampedEntry: lxmfData) else { continue }
                if stored[preflightTid] != nil { continue }   // duplicate: skip before PoW

                // Require a valid PN stamp at minAcceptedStampCost (max(0, cost - flex), as reference).
                // validatePnStamp strips the trailing
                // 32-byte stamp and returns transient_id = full_hash(stampless_entry) — the canonical dedup
                // key matching the sender (LXMFPropagation.pack) and peer re-sync. Entries with an absent
                // or under-cost stamp are silently skipped. With flexibility at least the target the
                // acceptance cost is 0: every stamp is valid, but the length rule still applies, as in
                // reference.
                guard let validated = LXStamper.validatePnStamp(transientData: lxmfData,
                                                                targetCost: minAcceptedStampCost) else {
                    continue
                }
                guard let dest = LXMFPropagation.destinationHash(lxmfData: validated.lxmfData) else {
                    continue
                }
                tid = validated.transientId
                destData = dest
                stampValue = validated.value
            } else {
                // targetStampCost == 0: accept without stamp validation (backward-compat / test helper path).
                // Strip the trailing stamp if present (> destHash(16) + stamp(32) bytes), otherwise use as-is.
                guard let dest = LXMFPropagation.destinationHash(lxmfData: lxmfData) else { continue }
                let lxmfCore = LXMFPropagation.strippedCore(lxmfData: lxmfData)
                tid = LXMFPropagation.transientId(lxmfData: lxmfCore)
                destData = dest
            }
            if stored[tid] != nil { continue }   // dedup by transient_id
            // Store the full stamped bytes (lxmfData) so PN→PN sync re-delivers the stamped entry,
            // letting the receiving PN validate and arrive at the same transient_id.
            stored[tid] = Entry(transientId: tid, destinationHash: destData, lxmfData: lxmfData,
                                stampValue: stampValue, sequence: nextSequence)
            nextSequence += 1
            added.append(tid)
        }
        let evicted = evictOverLimit()
        let evictedSet = Set(evicted)
        return (added: added.filter { !evictedSet.contains($0) }, evicted: evicted)
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

    /// Test seam: overwrite a stored entry's `stampValue`. Offer-filter tests need entries worth 13 to
    /// 25, which no test can afford to mine for real (each step of 1 doubles the work over a 256 KB
    /// workblock); the real values `ingest` records are tested separately.
    mutating func setStampValue(_ value: Double?, forTransientId transientId: Data) {
        stored[transientId]?.stampValue = value
    }

    /// All stored transient_ids, oldest-first. NOT an offer set: a peer refuses entries below its own
    /// acceptance cost, so an offer goes through `transientIds(acceptedAt:)`.
    public var transientIds: [Data] {
        stored.values.sorted { $0.sequence < $1.sequence }.map { $0.transientId }
    }

    /// The stored transient_ids a peer accepting at `minimum` will take, oldest-first: those whose
    /// `stampValue` (nil counts as 0) is at least `minimum`. Reference drops every entry with
    /// `get_stamp_value(tid) < min_accepted_cost` from a peer's offer (LXMPeer.py:343-361), because a
    /// receiving reference node tears the link down and throttles the sender on any entry it finds
    /// invalid (LXMRouter.py:2786-2793). `minimum` comes from `LXMFPropagation.peerMinimumAcceptedCost`;
    /// +infinity keeps nothing.
    public func transientIds(acceptedAt minimum: Double) -> [Data] {
        stored.values.filter { ($0.stampValue ?? 0) >= minimum }
            .sorted { $0.sequence < $1.sequence }.map { $0.transientId }
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
