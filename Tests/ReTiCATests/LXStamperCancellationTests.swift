import Testing
import Foundation
@testable import ReTiCA

/// The three `LXStamper` generators are brute-force searches with **no iteration bound** — expected
/// ~2^targetCost hash rounds — and two of them are driven by a cost an unauthenticated peer chooses.
/// A TCA `CancelID` alone cannot stop them: cancelling an `Effect` cancels the enclosing `Task`, but a
/// synchronous loop that never reads `Task.isCancelled` keeps burning a core forever and only the
/// *delivery* of its result is suppressed. So the loop itself must be cooperatively cancellable.
///
/// These tests are structurally binary rather than timed, which is the only way to test "unbounded
/// work" without a wall-clock assertion: the target cost is set so high that a valid stamp will never
/// be found (2^-200 per round), so an uncancellable search can only ever hang. A cancellable one
/// returns nil promptly. There is nothing to measure — the test either completes or it does not.
///
/// Reference parity: `LXStamper.job_simple` (lxmf 1.1.0 LXStamper.py:199-206) tests
/// `active_jobs[message_id]` every round and returns `None` when `cancel_work` sets it.
private let unreachableCost = 200   // a 256-bit digest with 200 leading zero bits: never found

@Test(.timeLimit(.minutes(1))) func generatePnStampAbandonsAnUnboundedSearchWhenTheTaskIsCancelled() async {
    let task = Task.detached {
        await LXStamper.generatePnStamp(transientId: Data(repeating: 0xAB, count: 32),
                                        targetCost: unreachableCost)
    }
    task.cancel()
    #expect(await task.value == nil)
}

@Test(.timeLimit(.minutes(1))) func generatePeeringKeyAbandonsAnUnboundedSearchWhenTheTaskIsCancelled() async {
    let task = Task.detached {
        await LXStamper.generatePeeringKey(peeringId: Data(repeating: 0xCD, count: 32),
                                           targetCost: unreachableCost)
    }
    task.cancel()
    #expect(await task.value == nil)
}

/// `generateStamp` (delivery stamps) has no production caller today — delivery stamps are unwired.
/// It is covered anyway so that wiring them later cannot reintroduce the unkillable loop.
@Test(.timeLimit(.minutes(1))) func generateStampAbandonsAnUnboundedSearchWhenTheTaskIsCancelled() async {
    let task = Task.detached {
        await LXStamper.generateStamp(messageId: Data(repeating: 0xEF, count: 32),
                                      targetCost: unreachableCost)
    }
    task.cancel()
    #expect(await task.value == nil)
}

/// Cancellation is checked *per round*, not only on entry: the search is already running (it has
/// produced candidates and yielded at least once) before the cancel lands, and it still stops.
@Test(.timeLimit(.minutes(1))) func aSearchAlreadyInProgressStopsWhenCancelled() async {
    let entered = AsyncStream<Void>.makeStream()
    let task = Task.detached {
        // Computing the 1000-round workblock is itself real work, so signalling before the call
        // guarantees the cancel races the loop rather than preceding the whole function.
        entered.continuation.yield()
        return await LXStamper.generatePnStamp(transientId: Data(repeating: 0x11, count: 32),
                                               targetCost: unreachableCost)
    }
    var it = entered.stream.makeAsyncIterator()
    _ = await it.next()
    task.cancel()
    #expect(await task.value == nil)
}

// NOTE: that the search also *yields* its executor while running — without which a cancellation can
// never be delivered to it at all — is covered in `StampWorkBoundsTests`, whose `TestStore` already
// runs effects on the main serial executor and so exhibits the starvation directly.

// MARK: - the bounds must admit every cost reference can legitimately demand

/// Reference's own defaults must not be refused by our ceilings, or we would decline to talk to a
/// stock `lxmd`: `PEERING_COST = 18` (LXMRouter.py:50) and `PROPAGATION_COST = 16` +
/// `PROPAGATION_COST_FLEX = 3` (LXMRouter.py:53-54).
@Test func costCeilingsAdmitReferenceDefaults() {
    #expect(LXMFPropagation.maxPeeringCost == 26)                       // LXMRouter.MAX_PEERING_COST
    #expect(LXMFPropagation.maxPeeringCost >= 18)                       // LXMRouter.PEERING_COST
    #expect(LXMFPropagation.maxPropagationStampCost >= LXMFPropagation.defaultPropagationStampCost + 3)
}

/// A cost at each ceiling still produces a *valid* stamp — the bound refuses absurd costs, it does not
/// silently weaken the proof-of-work. Run at a low cost (the ceilings themselves take minutes); what is
/// pinned is that a bounded cost round-trips through generate → validate unchanged.
@Test func aBoundedCostStillProducesAValidStampAndPeeringKey() async {
    let material = Data((0..<32).map { UInt8($0 &* 7) })
    let stamp = await LXStamper.generatePnStamp(transientId: material, targetCost: 4)
    #expect(stamp != nil)
    if let stamp {
        #expect(LXStamper.stampValid(stamp: stamp, targetCost: 4,
                                     workblock: LXStamper.stampWorkblock(
                                        material: material, expandRounds: LXStamper.workblockExpandRoundsPN)))
    }
    let key = await LXStamper.generatePeeringKey(peeringId: material, targetCost: 8)
    #expect(key != nil)
    if let key {
        #expect(LXStamper.validatePeeringKey(peeringId: material, peeringKey: key, targetCost: 8))
    }
}
