import ComposableArchitecture

/// Orders an interface's `driver.start()` against its `.stop`, which TCA's cancellation cannot.
///
/// `.cancellable` on a `.run` registers its cancel id only once the effect's task starts, while
/// `.cancel(id:)` runs eagerly when the reducer builds it. A `.stop` reduced in the same burst as
/// the action that launched a start effect therefore cancels nothing, and the start's task then
/// calls `driver.start()` AFTER the stop: a session nothing ever ends.
///
/// The interface captures `value` when it builds the start effect and bumps it when it reduces a
/// `.stop`; the effect calls `driver.start()` only under the lock and only if `value` is still the
/// captured one. What that guarantees, on its own, is interface-level CALL order: the synchronous
/// `driver.start()` call either returns before the stop's bump (so it precedes the stop's
/// `driver.stop()` call) or never happens.
///
/// It does not order any work the driver's `start` spawns. A driver whose `start` only launches
/// a task must itself make a `stop()` CALLED after `start()` win over that task, however the two
/// reach it: `FCBDriverAdapter` does this with start/stop tickets, and the Meshtastic live adapter
/// with `pendingConnects` (its `stop()` disconnects until no connect is outstanding).
///
/// A reference type so the effect sees bumps made after it was built. Equality is identity: a copy
/// of the state shares its epoch and compares equal; a freshly made state (a replaced slot) has its
/// own, so a stale start captured from the old slot is never re-armed by the new slot's epoch.
final class DriverEpoch: Sendable, Equatable {
    let value = LockIsolated(0)

    init() {}

    /// Called by `.stop` at reduce time: every start effect built before now becomes stale.
    func invalidate() { value.withValue { $0 += 1 } }

    /// The generation a start effect built now must still match when it runs.
    var current: Int { value.value }

    /// Runs `start` under the lock iff no `.stop` was reduced since `generation` was read.
    func start<T: Sendable>(ifCurrent generation: Int, _ start: @Sendable () -> T) -> T? {
        value.withValue { $0 == generation ? start() : nil }
    }

    static func == (lhs: DriverEpoch, rhs: DriverEpoch) -> Bool { lhs === rhs }
}
