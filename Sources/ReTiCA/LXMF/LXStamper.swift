import Foundation

/// LXMF proof-of-work stamps (LXMF-5b). A stamp is a 32-byte value whose full_hash(workblock ‖ stamp),
/// read as a big-endian 256-bit integer, is at or below the fixed-point target for `targetCost`, where
/// the workblock is deterministically expanded from the material (message_id). Validation is
/// deterministic; generation is a brute-force search. Mirrors lxmf 1.3.0 LXStamper, which takes
/// stamp_valid / stamp_value from RNS 1.6.0 RNS/Stamps.py: costs are fractional, on a 1/256 grid,
/// through the same `NetworkStamp.fixedPoint(cost:)` / `NetworkStamp.target(fixedPoint:)` the network
/// stamps use.
///
/// For an integer cost c the target is exactly 2^(256-c), so validity is the legacy (lxmf 1.1.0)
/// "at least c leading zero bits" rule except for the single hash equal to 2^(256-c), which has c-1
/// leading zeros and is now valid, as in reference.
///
/// Costs clamp as `NetworkStamp.fixedPoint(cost:)` does: NaN and anything at or below zero mean "every
/// stamp is valid", anything at or above 100 means cost 100. Reference raises on NaN and infinities
/// (and `generate_stamp` refuses costs outside 0...100); callers bound a wire cost before it gets here.
public enum LXStamper {
    public static let workblockExpandRounds = 3000     // RNS WORKBLOCK_EXPAND_ROUNDS
    public static let stampSize = 32                   // RNS STAMP_SIZE (HASHLENGTH/8)

    /// Counts `stampWorkblock` derivations within a task-local scope (`$workblockCounter`).
    ///
    /// **Why this seam is in production code.** Every cheap-before-expensive fix in the propagation
    /// path is invisible in every OUTCOME it produces: a duplicate entry is skipped whether or not a
    /// dedup check ran before the proof-of-work, so `added`, `count` and the actions emitted are
    /// byte-identical either way. The only difference is work done. Task 5's original guard asserted
    /// the outcomes and was therefore vacuous — deleting the entire preflight left the whole suite
    /// green — so the work itself has to be observable, and observable as a BINARY property (zero
    /// derivations, or not) rather than as a wall-clock measurement that would flake.
    ///
    /// `stampWorkblock` is the right thing to count: it is the whole cost of stamp **validation**
    /// (1000 HKDF rounds producing 256 KB for a PN stamp, ~21 ms measured), and counting it
    /// here catches PoW reached by ANY route, including a future caller that bypasses
    /// `PropagationStore.ingest` — which is precisely how the first version of the Task 5 fix was
    /// defeated.
    ///
    /// It is NOT a general measure of stamp work: for *generation* the `search` loop below dominates
    /// (~2^targetCost rounds) and is not counted here. Counting derivations is the right guard for
    /// the ingest path, where validation is all that runs, and would understate a generation path.
    /// An earlier draft of this comment called it "the expensive half of every stamp operation",
    /// which is true of validation and false of generation.
    public final class WorkblockCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var derivations = 0
        public init() {}
        public var count: Int { lock.lock(); defer { lock.unlock() }; return derivations }
        fileprivate func record() { lock.lock(); derivations += 1; lock.unlock() }
    }

    /// Unbound (nil) in production: one task-local read per derivation, lost in the ~21 ms the
    /// derivation costs. Tests bind a `WorkblockCounter` around the call they are measuring.
    @TaskLocal public static var workblockCounter: WorkblockCounter?

    /// Deterministic ~256*expandRounds-byte workblock: concat of hkdf(256, ikm=material,
    /// salt=full_hash(material ‖ msgpack(n))) for n in 0..<expandRounds.
    public static func stampWorkblock(material: Data, expandRounds: Int = workblockExpandRounds) -> Data {
        workblockCounter?.record()
        var wb = Data()
        for n in 0..<expandRounds {
            let salt = Crypto.fullHash(material + MsgPack.encode(.uint(UInt64(n))))
            wb += Crypto.hkdf(length: 256, derivedFrom: material, salt: salt, context: nil)
        }
        return wb
    }

    /// True iff full_hash(workblock ‖ stamp) is at or below the target for `targetCost`
    /// (RNS stamp_valid, which LXMF 1.3.0 uses).
    public static func stampValid(stamp: Data, targetCost: Double, workblock: Data) -> Bool {
        hashValid(Crypto.fullHash(workblock + stamp), targetCost: targetCost)
    }

    /// `stampValid` at an integer cost: the same as passing `Double(targetCost)`.
    @_disfavoredOverload
    public static func stampValid(stamp: Data, targetCost: Int, workblock: Data) -> Bool {
        stampValid(stamp: stamp, targetCost: Double(targetCost), workblock: workblock)
    }

    /// The validity rule on a hash already in hand: `hash <= target(fixedPoint(targetCost))`.
    static func hashValid(_ hash: Data, targetCost: Double) -> Bool {
        NetworkStamp.hashMeets(hash, target: target(cost: targetCost))
    }

    private static func target(cost: Double) -> [UInt8] {
        [UInt8](NetworkStamp.target(fixedPoint: NetworkStamp.fixedPoint(cost: cost)))
    }

    /// Value of the stamp on the 1/256 grid (RNS stamp_value): the leading-zero count of
    /// full_hash(workblock ‖ stamp) plus a fraction from its mantissa, floored onto the grid. Its
    /// integer part is the leading-zero count lxmf 1.1.0 reported.
    public static func stampValue(workblock: Data, stamp: Data) -> Double {
        NetworkStamp.value(hash: Crypto.fullHash(workblock + stamp))
    }

    /// Search random 32-byte stamps until one is valid for `targetCost` over `messageId`'s workblock.
    /// Nil if the enclosing `Task` was cancelled before a valid stamp was found — see `search`.
    ///
    /// **Production caller: `LXMFNode.deliverySend`**, reached from both `.send` and `.sendMessage`.
    /// (This note previously read "no production caller today"; that held until delivery stamps were
    /// wired.) The two requirements it anticipated are now met at that call site, and both remain
    /// load-bearing:
    ///   * the effect is registered `.cancellable` (by its stamp job's serial, `LXMFNode.CancelID`), so
    ///     the `search` loop below can be reclaimed; and
    ///   * the cost is bounded by `LXMFNode.maxDeliveryStampCost` **before** the search starts, at the
    ///     point the peer's unauthenticated advertised `stamp_cost` is read
    ///     (`LXMFNode.deliveryStampCost`) — cancellability alone does not stop a hostile peer
    ///     pinning a core.
    public static func generateStamp(messageId: Data, targetCost: Double) async -> Data? {
        await search(workblock: stampWorkblock(material: messageId), targetCost: targetCost)
    }

    /// `generateStamp` at an integer cost: the same as passing `Double(targetCost)`.
    @_disfavoredOverload
    public static func generateStamp(messageId: Data, targetCost: Int) async -> Data? {
        await generateStamp(messageId: messageId, targetCost: Double(targetCost))
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
    private static func search(workblock: Data, targetCost: Double) async -> Data? {
        let target = target(cost: targetCost)
        var round = 0
        while !Task.isCancelled {
            let s = SecureRandom.bytes(stampSize)
            if NetworkStamp.hashMeets(Crypto.fullHash(workblock + s), target: target) { return s }
            round += 1
            if round % searchYieldInterval == 0 { await Task.yield() }
        }
        return nil
    }

    public static let workblockExpandRoundsPeering = 25     // RNS WORKBLOCK_EXPAND_ROUNDS_PEERING
    public static let workblockExpandRoundsPN = 1000        // RNS WORKBLOCK_EXPAND_ROUNDS_PN

    /// Validate a peering key: a stamp over `peeringId` with the short (25-round) workblock
    /// (RNS LXStamper.validate_peering_key).
    public static func validatePeeringKey(peeringId: Data, peeringKey: Data, targetCost: Double) -> Bool {
        stampValid(stamp: peeringKey, targetCost: targetCost,
                   workblock: stampWorkblock(material: peeringId, expandRounds: workblockExpandRoundsPeering))
    }

    /// `validatePeeringKey` at an integer cost: the same as passing `Double(targetCost)`.
    @_disfavoredOverload
    public static func validatePeeringKey(peeringId: Data, peeringKey: Data, targetCost: Int) -> Bool {
        validatePeeringKey(peeringId: peeringId, peeringKey: peeringKey, targetCost: Double(targetCost))
    }

    /// Generate a peering key: search random 32-byte stamps until one is valid for `targetCost` over
    /// `peeringId`'s short (25-round) peering workblock — the initiator's counterpart to
    /// `validatePeeringKey` (RNS LXMPeer.generate_peering_key). Mirrors `generateStamp`. Cost averages
    /// ~2^targetCost hash iterations.
    /// Nil if the enclosing `Task` was cancelled before a valid key was found — see `search`.
    public static func generatePeeringKey(peeringId: Data, targetCost: Double) async -> Data? {
        await search(workblock: stampWorkblock(material: peeringId, expandRounds: workblockExpandRoundsPeering),
                     targetCost: targetCost)
    }

    /// `generatePeeringKey` at an integer cost: the same as passing `Double(targetCost)`.
    @_disfavoredOverload
    public static func generatePeeringKey(peeringId: Data, targetCost: Int) async -> Data? {
        await generatePeeringKey(peeringId: peeringId, targetCost: Double(targetCost))
    }

    /// Generate a propagation-node stamp: search random 32-byte stamps until one is valid for `targetCost`
    /// over `transientId`'s medium (1000-round) workblock — the client counterpart to `validatePnStamp`
    /// (RNS LXStamper.generate_stamp with WORKBLOCK_EXPAND_ROUNDS_PN). `transientId` = full_hash(lxm_data).
    /// Nil if the enclosing `Task` was cancelled before a valid stamp was found — see `search`.
    public static func generatePnStamp(transientId: Data, targetCost: Double) async -> Data? {
        await search(workblock: stampWorkblock(material: transientId, expandRounds: workblockExpandRoundsPN),
                     targetCost: targetCost)
    }

    /// `generatePnStamp` at an integer cost: the same as passing `Double(targetCost)`.
    @_disfavoredOverload
    public static func generatePnStamp(transientId: Data, targetCost: Int) async -> Data? {
        await generatePnStamp(transientId: transientId, targetCost: Double(targetCost))
    }

    /// Validate a propagation-node stamp appended to lxmf_data (`transientData = lxmf_data ‖ stamp[32]`):
    /// strip the trailing 32-byte stamp, recompute `transient_id = full_hash(lxm_data)`, and validate over
    /// the medium (1000-round) workblock. Returns (transientId, lxmfData, value, stamp) or nil
    /// (RNS LXStamper.validate_pn_stamp). `value` is `stampValue`, on the 1/256 grid.
    public static func validatePnStamp(transientData: Data, targetCost: Double)
        -> (transientId: Data, lxmfData: Data, value: Double, stamp: Data)? {
        guard transientData.count > stampSize else { return nil }
        let lxmfData = Data(transientData.dropLast(stampSize))
        let stamp = Data(transientData.suffix(stampSize))
        let transientId = Crypto.fullHash(lxmfData)
        let wb = stampWorkblock(material: transientId, expandRounds: workblockExpandRoundsPN)
        guard stampValid(stamp: stamp, targetCost: targetCost, workblock: wb) else { return nil }
        return (transientId, lxmfData, stampValue(workblock: wb, stamp: stamp), stamp)
    }

    /// `validatePnStamp` at an integer cost: the same as passing `Double(targetCost)`.
    @_disfavoredOverload
    public static func validatePnStamp(transientData: Data, targetCost: Int)
        -> (transientId: Data, lxmfData: Data, value: Double, stamp: Data)? {
        validatePnStamp(transientData: transientData, targetCost: Double(targetCost))
    }
}
