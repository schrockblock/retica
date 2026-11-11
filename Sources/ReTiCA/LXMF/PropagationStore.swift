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
        /// When `ingest` accepted the entry: its `now` argument. A peer offer weights entries by age
        /// from this (reference `lxm_rcvd`, `propagation_entries[tid][2]`, LXMRouter.py:1190, set at
        /// :2881). Not persisted by hosts: rehydration re-runs `ingest`, so a relaunch resets every
        /// entry's age to 0 where reference keeps `lxm_rcvd` in the stored file name (:2877). The cost
        /// is only offer order (an old entry is offered earlier after a relaunch than it would be).
        public internal(set) var receivedAt: Date
        var sequence: Int

        /// Public construction for hosts mirroring the store (persistence, tests). `sequence` is the
        /// store's internal ordering and is not part of a host's contract, so it defaults to 0 —
        /// entries built this way are values to persist/compare, not to insert into a store.
        /// `receivedAt` defaults to the 1970 epoch for the same reason.
        public init(transientId: Data, destinationHash: Data, lxmfData: Data,
                    receivedAt: Date = Date(timeIntervalSince1970: 0)) {
            self.transientId = transientId
            self.destinationHash = destinationHash
            self.lxmfData = lxmfData
            self.stampValue = nil
            self.receivedAt = receivedAt
            self.sequence = 0
        }

        /// Internal construction used by the store itself, preserving the insertion-order sequence.
        init(transientId: Data, destinationHash: Data, lxmfData: Data, stampValue: Double?,
             receivedAt: Date, sequence: Int) {
            self.transientId = transientId
            self.destinationHash = destinationHash
            self.lxmfData = lxmfData
            self.stampValue = stampValue
            self.receivedAt = receivedAt
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
    ///
    /// `now` becomes each added entry's `receivedAt` (reference stamps `time.time()`, LXMRouter.py:2881).
    @discardableResult
    public mutating func ingest(container: Data, now: Date) -> (added: [Data], evicted: [Data]) {
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
                                stampValue: stampValue, receivedAt: now, sequence: nextSequence)
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
    /// acceptance cost and above its limits, so an offer goes through `offerCandidates`.
    public var transientIds: [Data] {
        stored.values.sorted { $0.sequence < $1.sequence }.map { $0.transientId }
    }

    /// The offer a sync sends a peer: reference's `LXMPeer.sync` selection (LXMPeer.py:339-384), over
    /// the stored entries not in `handled` (the peer's handled set; everything else stands in for
    /// reference's per-peer unhandled list).
    ///
    /// - `lowValue`: entries whose `stampValue` (nil as 0) is below `minimum`, the peer's
    ///   `max(0, cost - flex)`. Reference removes these from the peer's unhandled list
    ///   (LXMPeer.py:345, :359-361), so it never offers them to that peer again; a caller matches that
    ///   by adding them to the peer's handled set. Offering one would be worse than useless: a
    ///   receiving reference node tears the link down and throttles the sender on any entry it finds
    ///   invalid (LXMRouter.py:2786-2793). `minimum` comes from
    ///   `LXMFPropagation.peerMinimumAcceptedCost`; +infinity keeps nothing.
    /// - The rest are sorted by weight ascending (LXMPeer.py:363), ties in ingest order as Python's
    ///   stable sort over `propagation_entries` order leaves them. Weight is reference's `get_weight`
    ///   (LXMRouter.py:1188-1199): `priority_weight * max(1, age_seconds/60/60/24/4) * size`.
    ///   `priority_weight` is always 1.0 here: reference uses 0.1 for destinations on its
    ///   `prioritised_list`, and ReTiCA has no such list. `size` is the stored stamped bytes, as
    ///   reference's `propagation_entries[tid][3]` is `len(stamped_data)` (LXMRouter.py:2875, :2881).
    /// - Then, in that order, with `per_message_overhead = 16` and `cumulative_size` starting at 24
    ///   (LXMPeer.py:364-365): an entry whose `size + 16` exceeds `transferLimitKB * 1000` is
    ///   `oversized` (reference removes it from unhandled AND marks it handled, :375-378); one that
    ///   would bring the running total to `syncLimitKB * 1000` or more is skipped for this sync only,
    ///   and the loop goes on to the next, smaller ones (`continue`, :380-381); every other entry is
    ///   offered and counted. nil limit = no limit (reference's `!= None` tests).
    ///
    /// A limit whose `* 1000` overflows Int saturates (a huge limit is no limit) instead of trapping.
    ///
    /// `candidates`, when given, is the peer's explicit unhandled set (`PNPeerTable.Peer.unhandled`,
    /// reference's per-peer list): only stored entries in it are considered, and ids in it that the
    /// store no longer holds are simply absent (reference drops those as purged, LXMPeer.py:353-357).
    /// nil considers every stored entry, which is `PNNode`'s whole-store-minus-handled behaviour.
    public func offerCandidates(acceptedAt minimum: Double, transferLimitKB: Int?, syncLimitKB: Int?,
                                among candidates: Set<Data>? = nil,
                                excluding handled: Set<Data>,
                                now: Date) -> (offer: [Data], oversized: [Data], lowValue: [Data]) {
        var lowValue: [Data] = []
        var weighted: [(entry: Entry, weight: Double)] = []
        for entry in stored.values.sorted(by: { $0.sequence < $1.sequence })
        where !handled.contains(entry.transientId) && candidates?.contains(entry.transientId) ?? true {
            if (entry.stampValue ?? 0) < minimum { lowValue.append(entry.transientId); continue }
            weighted.append((entry, Self.offerWeight(entry, now: now)))
        }
        // Ascending; equal weights keep ingest order, as Python's stable sort does.
        weighted.sort { $0.weight != $1.weight ? $0.weight < $1.weight : $0.entry.sequence < $1.entry.sequence }

        let perMessageOverhead = 16                 // LXMPeer.py:364
        var cumulativeSize = 24                     // LXMPeer.py:365
        let transferLimit = transferLimitKB.map(Self.kilobytesAsBytes)
        let syncLimit = syncLimitKB.map(Self.kilobytesAsBytes)
        var offer: [Data] = []
        var oversized: [Data] = []
        for (entry, _) in weighted {
            let transferSize = entry.lxmfData.count + perMessageOverhead
            let nextSize = cumulativeSize + transferSize
            if let transferLimit, transferSize > transferLimit {         // LXMPeer.py:375-378
                oversized.append(entry.transientId)
                continue
            }
            if let syncLimit, nextSize >= syncLimit { continue }         // LXMPeer.py:380-381: skip, not stop
            cumulativeSize = nextSize
            offer.append(entry.transientId)
        }
        return (offer, oversized, lowValue)
    }

    /// Reference `get_weight` (LXMRouter.py:1188-1199) with `priority_weight` 1.0 (no prioritised
    /// list here): `max(1, age_seconds/60/60/24/4) * size`, divided in reference's order. An entry
    /// "received" in the future (clock moved back) has a negative age, so its factor is 1.
    static func offerWeight(_ entry: Entry, now: Date) -> Double {
        let priorityWeight = 1.0
        let ageWeight = max(1, now.timeIntervalSince(entry.receivedAt) / 60 / 60 / 24 / 4)
        return priorityWeight * ageWeight * Double(entry.lxmfData.count)
    }

    /// `kb * 1000`, saturating instead of trapping: a peer's announced limit is any non-negative Int
    /// (`PNAnnounce.parse`), and past Int.max / 1000 it limits nothing anyway.
    static func kilobytesAsBytes(_ kb: Int) -> Int {
        let (bytes, overflow) = kb.multipliedReportingOverflow(by: 1000)
        return overflow ? (kb < 0 ? Int.min : Int.max) : bytes
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
