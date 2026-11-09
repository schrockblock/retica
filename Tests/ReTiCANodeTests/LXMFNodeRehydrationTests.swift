import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// `learnedPeers` rehydration and stamp-cost expiry (Task 2, 2026-08-17 durability slice).
///
/// After a cold start `learnedPeers` is empty, so `deliverySend` finds no cost and sends
/// **unstamped to every peer** until each announce is re-heard. Any peer running
/// `enforce_stamps()` drops those messages — the failure the delivery-stamp slice closed for a
/// live session, re-opened by every restart. Reference persists `outbound_stamp_costs` to disk
/// (`save_outbound_stamp_costs`, LXMRouter.py:1287-1296, LXMF 1.1.0) and sweeps entries older
/// than `STAMP_COST_EXPIRY = 45 * 24 * 60 * 60` (LXMRouter.py:39) in `clean_outbound_stamp_costs`
/// (LXMRouter.py:1272-1285) — **once per startup, immediately after loading** (LXMRouter.py:276-277).
/// Reference runs no periodic sweep; the launch is the sweep. `.rehydrateLearnedPeers` is both
/// halves: it restores the table and drops expired entries in the same pass.

private let peerDestHash = Data(repeating: 0xA1, count: 16)

private let day: TimeInterval = 24 * 60 * 60

/// A fixed, deliberately PAST clock. Load-bearing for `nodeRehydrationKeepsPeersYoungerThanExpiry`:
/// an entry 40 days before this instant is **well over a year** old against wall-clock time — and
/// the gap only widens — so an implementation that swept with `Date()` instead of the `\.date`
/// dependency would drop it and fail that test. (An earlier version of this comment said
/// "~700 days", which was true when written and is not now; a fixed date's age is not a constant.)
private let injectedNow = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
private func makeRehydrationStore() -> TestStore<LXMFNode.State, LXMFNode.Action> {
    let ep = TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false)
    let node = LXMFNode.State(identity: Identity(), endpoint: ep)
    let store = TestStore(initialState: node) { LXMFNode() } withDependencies: {
        $0.date = .constant(injectedNow)
        $0.continuousClock = TestClock()
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

private func peer(stampCost: Double?, learnedAt: Date) -> LXMFNode.LearnedPeer {
    LXMFNode.LearnedPeer(displayName: nil, stampCost: stampCost, supportsCompression: true,
                         learnedAt: learnedAt)
}

// MARK: - Rehydrated cost is spent (the whole point)

/// A peer rehydrated via `.rehydrateLearnedPeers` has its stamp cost spent by `deliverySend`:
/// the send is stamped at the rehydrated cost, instead of going out unstamped.
///
/// Vacuity check: would this fail if rehydration did nothing? YES — with an empty `learnedPeers`
/// the cost lookup in `deliveryStampCost(_:destinationHash:)` returns nil and the router receives
/// an unstamped message, so both stamp assertions fail.
@MainActor @Test func nodeRehydratedPeerStampCostIsSpentByDeliverySend() async throws {
    // Cost 8, not 1: at cost 1 a single random draw validates with p = 1/2, so `validateStamp`
    // passing would be weak evidence that any search happened. At 8 it is p = 1/256 while the
    // expected search is ~256 rounds (~0.1 s) — same rationale as
    // `lxmfNodeAttachesStampWhenCostIsWithinCeiling`.
    let cost: Double = 8
    let store = makeRehydrationStore()

    // Cold start: the table is empty, so a send right now would go out unstamped.
    #expect(store.state.learnedPeers.isEmpty)
    await store.send(.rehydrateLearnedPeers([peerDestHash: peer(stampCost: cost, learnedAt: injectedNow)]))
    #expect(store.state.learnedPeers[peerDestHash]?.stampCost == cost)

    let capturedMessage = LockIsolated<LXMessage?>(nil)
    await store.send(.send(destinationHash: peerDestHash, title: Data("t".utf8),
                           content: Data("c".utf8), method: .opportunistic))
    // Explicit timeout: the stamp search is CPU-bound and can outlast TestStore's 1 s default on a
    // loaded machine (it did, under the parallel full suite).
    await store.receive({ action in
        if case let .router(.send(m, _)) = action {
            capturedMessage.setValue(m)
            return true
        }
        return false
    }, timeout: .seconds(10))
    let msg = try #require(capturedMessage.value)
    #expect(msg.stamp != nil, "rehydrated cost must drive stamp generation")
    #expect(msg.validateStamp(targetCost: cost))
}

// MARK: - Expiry sweep at rehydration

/// Entries older than `stampCostExpiry` are dropped when `.rehydrateLearnedPeers` restores the
/// table — reference's `clean_outbound_stamp_costs`, run at startup (LXMRouter.py:276-277).
///
/// The constant assertion pins reference parity exactly (`STAMP_COST_EXPIRY = 45 * 24 * 60 * 60`,
/// LXMRouter.py:39); the sweep assertions pin that the cleanup actually runs.
///
/// Vacuity check: would this fail if rehydration never swept? YES — both entries would be
/// restored and `learnedPeers` would not be empty.
@MainActor @Test func nodeRehydrationSweepsPeersOlderThanExpiry() async {
    #expect(LXMFNode.stampCostExpiry == 45 * day)
    let store = makeRehydrationStore()

    await store.send(.rehydrateLearnedPeers([
        Data(repeating: 0x11, count: 16): peer(stampCost: 8, learnedAt: injectedNow.addingTimeInterval(-46 * day)),
        Data(repeating: 0x22, count: 16): peer(stampCost: nil, learnedAt: injectedNow.addingTimeInterval(-100 * day)),
    ]))
    #expect(store.state.learnedPeers.isEmpty, "both entries are past the 45-day expiry")
}

/// Entries younger than `stampCostExpiry` survive rehydration, including one exactly one expiry
/// old — reference's sweep is a strict inequality (`time.time() > entry[0] + STAMP_COST_EXPIRY`,
/// LXMRouter.py:1278), so an entry at exactly the boundary is kept.
///
/// **This test pins that the sweep reads the `\.date` dependency, not wall-clock time.**
/// `injectedNow` is November 2023: the 40-day-old entry is ~700 days old against real wall-clock
/// time, so an implementation sweeping with `Date()` would drop it and fail here.
///
/// Vacuity check: would this fail if the sweep dropped everything? YES — all three assertions on
/// `learnedPeers` would fail. Would it fail if the boundary comparison were non-strict? YES —
/// the exactly-expiry-old entry would be swept and the count would be 2.
@MainActor @Test func nodeRehydrationKeepsPeersYoungerThanExpiry() async {
    let store = makeRehydrationStore()

    let youngOneDay = Data(repeating: 0x33, count: 16)
    let youngFortyDays = Data(repeating: 0x44, count: 16)
    let exactlyExpiryOld = Data(repeating: 0x55, count: 16)
    await store.send(.rehydrateLearnedPeers([
        youngOneDay: peer(stampCost: 8, learnedAt: injectedNow.addingTimeInterval(-1 * day)),
        youngFortyDays: peer(stampCost: nil, learnedAt: injectedNow.addingTimeInterval(-40 * day)),
        exactlyExpiryOld: peer(stampCost: 8, learnedAt: injectedNow.addingTimeInterval(-LXMFNode.stampCostExpiry)),
    ]))
    #expect(store.state.learnedPeers.count == 3, "no entry is past the expiry")
    #expect(store.state.learnedPeers[youngOneDay] != nil)
    #expect(store.state.learnedPeers[youngFortyDays] != nil, "40 days < 45-day expiry; also the injected-clock pin")
    #expect(store.state.learnedPeers[exactlyExpiryOld] != nil, "boundary is kept: reference's sweep is strict")
}

/// A restored entry must not overwrite a **fresher live** one.
///
/// Rehydration is not guaranteed to land before the network does. `AppFeature.onLaunch` merges
/// `.endpoint(.start)` with an async database read, so an announce can populate `learnedPeers`
/// first — and an unconditional restore would then move `learnedAt` backwards and reinstate a
/// superseded stamp cost. That is the exact failure this slice exists to prevent: stamping at an
/// outdated price, where UNDER-paying gets us dropped by an enforcing peer. Reference never faces
/// this because it loads `outbound_stamp_costs` synchronously in `__init__`, before any network.
///
/// Anti-vacuity: the persisted entry is deliberately **unexpired** (30 days < 45), so the sweep
/// would keep it. Only the freshness comparison can reject it. Asserting the cost — not merely
/// that some entry exists — is what distinguishes "kept the live one" from "restored either one".
@MainActor @Test func nodeRehydrationDoesNotClobberAFresherLiveEntry() async {
    let store = makeRehydrationStore()

    // Live entry: heard just now, cost 3.
    let live = peer(stampCost: 3, learnedAt: injectedNow)
    await store.send(.rehydrateLearnedPeers([peerDestHash: live]))
    #expect(store.state.learnedPeers[peerDestHash]?.stampCost == 3)

    // Persisted entry: older than the live one but well inside the expiry window, cost 9.
    let stale = peer(stampCost: 9, learnedAt: injectedNow.addingTimeInterval(-30 * day))
    await store.send(.rehydrateLearnedPeers([peerDestHash: stale]))

    #expect(store.state.learnedPeers[peerDestHash]?.stampCost == 3, "the fresher live cost survives")
    #expect(store.state.learnedPeers[peerDestHash]?.learnedAt == injectedNow, "learnedAt must not move backwards")
}

/// A malformed `learnedAt` is swept, not made immortal.
///
/// Rows come from our own database, but a corrupted or hand-edited store must degrade rather than
/// persist forever. `Date + TimeInterval` is `Double` arithmetic, so it saturates instead of
/// trapping — there is no crash to catch here, which is exactly why this needs a test rather than
/// a guard. The sharp case is **NaN, which fails OPEN**: `now <= nan` desugars to `!(nan < now)`
/// = `true`, so an unclamped sweep keeps it forever. A future-dated row is the realistic one — a
/// device with a skewed clock writes `learnedAt: date.now` into 2040, and after the clock corrects
/// that entry can never expire.
@MainActor @Test func nodeRehydrationSweepsMalformedTimestamps() async {
    let store = makeRehydrationStore()

    let futureDated = Data(repeating: 0x66, count: 16)
    let notANumber = Data(repeating: 0x77, count: 16)
    let infinite = Data(repeating: 0x88, count: 16)
    let sane = Data(repeating: 0x99, count: 16)

    await store.send(.rehydrateLearnedPeers([
        futureDated: peer(stampCost: 8, learnedAt: injectedNow.addingTimeInterval(100 * 365 * day)),
        notANumber: peer(stampCost: 8, learnedAt: Date(timeIntervalSinceReferenceDate: .nan)),
        infinite: peer(stampCost: 8, learnedAt: Date(timeIntervalSinceReferenceDate: .infinity)),
        sane: peer(stampCost: 8, learnedAt: injectedNow.addingTimeInterval(-1 * day)),
    ]))

    // Dropped, NOT clamped. A first attempt at this clamped `learnedAt` to `now`, which makes a
    // future row look maximally FRESH — kept, and re-clamped against every later `now`, so
    // immortal. This assertion is what caught that.
    #expect(store.state.learnedPeers[futureDated] == nil, "a future-dated row is dropped, not made immortal")
    #expect(store.state.learnedPeers[notANumber] == nil, "NaN must fail CLOSED, not open")
    #expect(store.state.learnedPeers[infinite] == nil, "non-finite is treated as always-expired")
    #expect(store.state.learnedPeers[sane] != nil, "the well-formed row is unaffected — the sweep is not just dropping everything")
}
