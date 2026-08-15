import Foundation

/// LXMF proof-of-work stamps (LXMF-5b). A stamp is a 32-byte value whose full_hash(workblock ‖ stamp)
/// has at least `targetCost` leading zero bits, where the workblock is deterministically expanded from
/// the material (message_id). Validation is deterministic; generation is a brute-force search. Mirrors
/// lxmf 1.1.0 LXStamper (stamp_workblock / stamp_valid / stamp_value / generate_stamp).
public enum LXStamper {
    public static let workblockExpandRounds = 3000     // RNS WORKBLOCK_EXPAND_ROUNDS
    public static let stampSize = 32                   // RNS STAMP_SIZE (HASHLENGTH/8)

    /// Deterministic ~256*expandRounds-byte workblock: concat of hkdf(256, ikm=material,
    /// salt=full_hash(material ‖ msgpack(n))) for n in 0..<expandRounds.
    public static func stampWorkblock(material: Data, expandRounds: Int = workblockExpandRounds) -> Data {
        var wb = Data()
        for n in 0..<expandRounds {
            let salt = Crypto.fullHash(material + MsgPack.encode(.uint(UInt64(n))))
            wb += Crypto.hkdf(length: 256, derivedFrom: material, salt: salt, context: nil)
        }
        return wb
    }

    /// True iff full_hash(workblock ‖ stamp) has >= targetCost leading zero bits.
    public static func stampValid(stamp: Data, targetCost: Int, workblock: Data) -> Bool {
        stampValue(workblock: workblock, stamp: stamp) >= targetCost
    }

    /// Count of leading zero bits of full_hash(workblock ‖ stamp).
    public static func stampValue(workblock: Data, stamp: Data) -> Int {
        let digest = Crypto.fullHash(workblock + stamp)
        var value = 0
        for byte in digest {
            if byte == 0 { value += 8; continue }
            value += byte.leadingZeroBitCount
            break
        }
        return value
    }

    /// Search random 32-byte stamps until one is valid for `targetCost` over `messageId`'s workblock.
    /// Nil if the enclosing `Task` was cancelled before a valid stamp was found — see `search`.
    ///
    /// NOTE: this generator has **no production caller** today (delivery stamps are unwired — see the
    /// Tier 3 "no delivery-announce app data" item in `docs/reference-parity-checklist.md`). It is made
    /// cancellable here so that wiring delivery stamps later cannot reintroduce an unkillable loop. When
    /// that wiring lands, the *cost* must also be bounded at the point the peer's advertised
    /// `stamp_cost` is read — cancellability alone does not stop a hostile peer pinning a core.
    public static func generateStamp(messageId: Data, targetCost: Int) async -> Data? {
        await search(workblock: stampWorkblock(material: messageId), targetCost: targetCost)
    }

    /// Rounds between yields in `search`. Bounds how long the search can hold its executor thread
    /// before a cancellation (or anything else queued behind it) gets a turn: at most 32 rounds, which
    /// is ~6 ms on the 256 KB propagation workblock and microseconds on the 6.4 KB peering one. Small
    /// enough to be responsive, large enough that the yield is lost in the hashing cost.
    private static let searchYieldInterval = 32

    /// Brute-force search shared by all three generators: draw random 32-byte stamps until one is valid,
    /// abandoning the search and returning nil as soon as the enclosing `Task` is cancelled.
    ///
    /// The search is unbounded — expected ~2^targetCost rounds — so it MUST be abandonable, and a bare
    /// `while true` inside a `.run` effect is not. Mirrors reference `LXStamper.job_simple`
    /// (lxmf 1.1.0 LXStamper.py:199-206), whose loop re-tests `active_jobs[message_id]` every round and
    /// returns `None` once `cancel_work` (LXStamper.py:146-175) sets it.
    ///
    /// Two things are required, and each is useless alone:
    ///
    /// * **`Task.isCancelled`** — attaching a TCA `CancelID` to the effect stops the result being
    ///   *delivered*, but a loop that never reads the cancellation flag keeps burning a core forever.
    /// * **`Task.yield()`** — a minutes-long loop that never suspends occupies a cooperative-pool
    ///   thread outright (and, under a serial executor, the entire executor), so the cancellation can
    ///   never be *delivered* to it in the first place. Measured: a cost-26 peering search inside a
    ///   `TestStore` effect ran to completion in 267 s despite an explicit cancel, because the cancel
    ///   could not be scheduled. On a 2-core phone two concurrent searches would starve the pool the
    ///   transport itself runs on. Reference sidesteps this by running generation in separate
    ///   threads/processes (`LXStamper.job_linux_managed` / `job_simple`); yielding is the equivalent
    ///   under structured concurrency.
    private static func search(workblock: Data, targetCost: Int) async -> Data? {
        var round = 0
        while !Task.isCancelled {
            let s = SecureRandom.bytes(stampSize)
            if stampValid(stamp: s, targetCost: targetCost, workblock: workblock) { return s }
            round += 1
            if round % searchYieldInterval == 0 { await Task.yield() }
        }
        return nil
    }

    public static let workblockExpandRoundsPeering = 25     // RNS WORKBLOCK_EXPAND_ROUNDS_PEERING
    public static let workblockExpandRoundsPN = 1000        // RNS WORKBLOCK_EXPAND_ROUNDS_PN

    /// Validate a peering key: a stamp over `peeringId` with the short (25-round) workblock
    /// (RNS LXStamper.validate_peering_key).
    public static func validatePeeringKey(peeringId: Data, peeringKey: Data, targetCost: Int) -> Bool {
        stampValid(stamp: peeringKey, targetCost: targetCost,
                   workblock: stampWorkblock(material: peeringId, expandRounds: workblockExpandRoundsPeering))
    }

    /// Generate a peering key: search random 32-byte stamps until one is valid for `targetCost` over
    /// `peeringId`'s short (25-round) peering workblock — the initiator's counterpart to
    /// `validatePeeringKey` (RNS LXMPeer.generate_peering_key). Mirrors `generateStamp`. Cost averages
    /// ~2^targetCost hash iterations.
    /// Nil if the enclosing `Task` was cancelled before a valid key was found — see `search`.
    public static func generatePeeringKey(peeringId: Data, targetCost: Int) async -> Data? {
        await search(workblock: stampWorkblock(material: peeringId, expandRounds: workblockExpandRoundsPeering),
                     targetCost: targetCost)
    }

    /// Generate a propagation-node stamp: search random 32-byte stamps until one is valid for `targetCost`
    /// over `transientId`'s medium (1000-round) workblock — the client counterpart to `validatePnStamp`
    /// (RNS LXStamper.generate_stamp with WORKBLOCK_EXPAND_ROUNDS_PN). `transientId` = full_hash(lxm_data).
    /// Nil if the enclosing `Task` was cancelled before a valid stamp was found — see `search`.
    public static func generatePnStamp(transientId: Data, targetCost: Int) async -> Data? {
        await search(workblock: stampWorkblock(material: transientId, expandRounds: workblockExpandRoundsPN),
                     targetCost: targetCost)
    }

    /// Validate a propagation-node stamp appended to lxmf_data (`transientData = lxmf_data ‖ stamp[32]`):
    /// strip the trailing 32-byte stamp, recompute `transient_id = full_hash(lxm_data)`, and validate over
    /// the medium (1000-round) workblock. Returns (transientId, lxmfData, value, stamp) or nil
    /// (RNS LXStamper.validate_pn_stamp).
    public static func validatePnStamp(transientData: Data, targetCost: Int)
        -> (transientId: Data, lxmfData: Data, value: Int, stamp: Data)? {
        guard transientData.count > stampSize else { return nil }
        let lxmfData = Data(transientData.dropLast(stampSize))
        let stamp = Data(transientData.suffix(stampSize))
        let transientId = Crypto.fullHash(lxmfData)
        let wb = stampWorkblock(material: transientId, expandRounds: workblockExpandRoundsPN)
        guard stampValid(stamp: stamp, targetCost: targetCost, workblock: wb) else { return nil }
        return (transientId, lxmfData, stampValue(workblock: wb, stamp: stamp), stamp)
    }
}
