import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// Delivery-stamp generation in `LXMFNode.send` (Task 1, 2026-08-16 delivery-stamps slice).
///
/// Any LXMF peer running `enforce_stamps()` silently drops every message that lacks a valid stamp.
/// When a peer's `lxmf.delivery` announce carries a `stamp_cost`, `LXMFNode` must generate a
/// delivery stamp before handing the message to the router — but the cost is unauthenticated and
/// exponential, so it must be bounded and the search must be cancellable.
///
/// Reference flow (`LXMRouter.handle_outbound`, LXMRouter.py:1752-1757, LXMF 1.1.0):
///
///     if lxmessage.stamp_cost == None:
///         if destination_hash in self.outbound_stamp_costs:
///             stamp_cost = self.outbound_stamp_costs[destination_hash][1]
///             lxmessage.stamp_cost = stamp_cost
///
/// Then `pack()` → `get_stamp()` (LXMessage.py:372) runs the search. Reference has no ceiling;
/// we add one (`maxDeliveryStampCost = 20`) and require cancellability.
///
/// **No-stamp path is byte-identical.** A message sent with no stamp must pack exactly as today —
/// the cross-validation vectors (which byte-compare against genuine Python output) must stay green.
///
/// **Refusing to stamp must not refuse to send.** A peer demanding more than the ceiling gets an
/// *unstamped* message. They may drop it; that is their choice.
///
/// **Structural binary tests (cost 0 / above-ceiling / cancellation).** Every "refuses" test uses
/// a cost whose search would run forever or be rejected before it starts, so the store can only
/// finish promptly if the ceiling gate or the cancellation path is taken. The `.timeLimit` on
/// cancellation tests is a safety net only: a cancelled search at `maxDeliveryStampCost` finishes
/// in well under a second; the limit exists so an unkillable loop doesn't block the suite.
///
/// **Anti-vacuity rule applied here.** Every assertion that a stamp was attached is checked
/// against the actual message the router received — not against state, which would pass even if
/// the effect payload were dropped.

// MARK: - Helpers

private let peerDestHash = Data(repeating: 0xA1, count: 16)

/// Build a store that knows `peerDestHash` with the given `advertisedStampCost`.
@MainActor
private func makeDeliveryStampStore(
    advertisedStampCost: Int?
) -> TestStore<LXMFNode.State, LXMFNode.Action> {
    let ep = TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false)
    var node = LXMFNode.State(identity: Identity(), endpoint: ep)
    if let cost = advertisedStampCost {
        node.learnedPeers[peerDestHash] = LXMFNode.LearnedPeer(
            displayName: nil, stampCost: cost, supportsCompression: true,
            learnedAt: Date(timeIntervalSince1970: 0))
    }
    let store = TestStore(initialState: node) { LXMFNode() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.continuousClock = TestClock()
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

// MARK: - No learned cost → no stamp, byte-identical packed

/// A message to a peer with no learned stamp cost is sent with no stamp, and its wire form keeps the
/// FOUR-element payload the no-stamp path has always produced.
///
/// **Byte-identity itself is pinned by `lxMessageMatchesReferenceLXMF`**
/// (`Tests/ReTiCATests/Vectors/LXMessageCrossValidationTests.swift`), which byte-compares our packed
/// payload against genuine lxmf 1.1.0 output. This test cannot re-prove that and does not try: it
/// pins the one property that, if broken here, would break those vectors — that nothing appended a
/// 5th (stamp) element to the payload on the no-cost path.
///
/// A previous version asserted `msg.packed == LXMessage.unpack(msg.packed)?.packed ?? msg.packed`,
/// which is a tautology on both branches (`??` compares the value to itself when unpack returns nil;
/// `unpack(x).packed` returns `receivedBytes == x` otherwise) and no mutation of this diff could
/// break it. Comparing against a separately-built `LXMessage.create` would ALSO be wrong: ReTiCA's
/// Ed25519 is hedged, so two `create` calls with identical inputs differ in the 64 signature bytes —
/// which is exactly why the vector test above compares around that region rather than through it.
///
/// Anti-vacuity: `try #require` fails the test if no message is ever received, so the assertions
/// cannot pass by never running.
@MainActor @Test func lxmfNodeSendsWithoutStampWhenNoCostIsKnown() async throws {
    let store = makeDeliveryStampStore(advertisedStampCost: nil)
    let capturedMessage = LockIsolated<LXMessage?>(nil)
    await store.send(.send(destinationHash: peerDestHash, title: Data("t".utf8),
                           content: Data("c".utf8), method: .opportunistic))
    await store.receive { action in
        if case let .router(.send(m, _)) = action {
            capturedMessage.setValue(m)
            return true
        }
        return false
    }
    let msg = try #require(capturedMessage.value)
    #expect(msg.stamp == nil)
    // The payload begins after destHash(16) ‖ sourceHash(16) ‖ signature(64).
    let payload = Data(msg.packed.dropFirst(2 * LXMessage.destinationLength + LXMessage.signatureLength))
    let decoded = try #require(MsgPack.decodeValue(payload))
    guard case let .array(items) = decoded else {
        Issue.record("payload is not a msgpack array: \(decoded)")
        return
    }
    #expect(items.count == 4)          // 5 would mean a stamp element was appended
    let unpacked = try #require(LXMessage.unpack(msg.packed))
    #expect(unpacked.stamp == nil)
}

// MARK: - Learned cost within ceiling → stamp attached and valid

/// A message to a peer with a learned cost within the ceiling is sent WITH a stamp, and the stamp
/// validates at that cost.
///
/// Anti-vacuity: the assertion captures the message the router receives and checks the stamp via
/// `validateStamp` at the ADVERTISED cost, proving the generator honoured the cost rather than
/// emitting arbitrary bytes.
///
/// **Cost 8, not 1.** At cost 1 a single random 32-byte draw satisfies the target with p = 1/2, so
/// `validateStamp` passing would be weak evidence that any search happened. At 8 that is p = 1/256,
/// while the expected search is only ~256 rounds (~0.1 s measured at ~2 200 rounds/s) — still
/// comfortably sub-second.
@MainActor @Test func lxmfNodeAttachesStampWhenCostIsWithinCeiling() async throws {
    let cost = 8
    let store = makeDeliveryStampStore(advertisedStampCost: cost)
    let capturedMessage = LockIsolated<LXMessage?>(nil)
    await store.send(.send(destinationHash: peerDestHash, title: Data("t".utf8),
                           content: Data("c".utf8), method: .opportunistic))
    await store.receive { action in
        if case let .router(.send(m, _)) = action {
            capturedMessage.setValue(m)
            return true
        }
        return false
    }
    let msg = try #require(capturedMessage.value)
    #expect(msg.stamp != nil)
    #expect(msg.validateStamp(targetCost: cost))
}

// MARK: - Learned cost of 0 → no stamp (0 means "no cost required")

/// A learned cost of 0 produces no stamp. Reference's own emit gate (`> 0 and < 255`,
/// LXMRouter.py:1044) never sends 0 as a meaningful cost, and `handle_outbound` calls
/// `get_stamp()` only when `stamp_cost != None` — so 0 in `outbound_stamp_costs` is treated
/// as "field absent". We map it the same way: 0 → no stamp.
///
/// Anti-vacuity: the message the router receives is inspected for `.stamp == nil`.
@MainActor @Test func lxmfNodeSendsWithoutStampWhenLearnedCostIsZero() async throws {
    let store = makeDeliveryStampStore(advertisedStampCost: 0)
    let capturedMessage = LockIsolated<LXMessage?>(nil)
    await store.send(.send(destinationHash: peerDestHash, title: Data("t".utf8),
                           content: Data("c".utf8), method: .opportunistic))
    await store.receive { action in
        if case let .router(.send(m, _)) = action {
            capturedMessage.setValue(m)
            return true
        }
        return false
    }
    let msg = try #require(capturedMessage.value)
    #expect(msg.stamp == nil)
}

// MARK: - Cost above ceiling → no stamp, message still sent

/// A peer demanding a cost above `maxDeliveryStampCost` gets an unstamped message — **not
/// nothing**. Refusing to stamp must not refuse to send.
///
/// A cost of `maxDeliveryStampCost + 1` would run ~2^21 search rounds; if the ceiling gate were
/// missing the test would block for minutes. That a `.router(.send)` is received proves the
/// message was not dropped; that no deliveryStamp effect is left in-flight after finish proves
/// the ceiling gate fired (not the cancellation path).
///
/// Anti-vacuity: the message the router receives is inspected for `.stamp == nil`.
/// `skipReceivedActions` drains the downstream router cascade (opportunistic send cascades into
/// `.endpoint(.send)` → `.sendFailed` etc.) so that flipping `.on` doesn't raise a stray-action
/// diagnostic for noise we deliberately ignore.
@MainActor @Test func lxmfNodeSendsUnstampedMessageWhenCostExceedsCeiling_doesNotRefuseToSend() async throws {
    let store = makeDeliveryStampStore(advertisedStampCost: LXMFNode.maxDeliveryStampCost + 1)
    let capturedMessage = LockIsolated<LXMessage?>(nil)
    await store.send(.send(destinationHash: peerDestHash, title: Data("t".utf8),
                           content: Data("c".utf8), method: .opportunistic))
    await store.receive { action in
        if case let .router(.send(m, _)) = action {
            capturedMessage.setValue(m)
            return true
        }
        return false
    }
    let msg = try #require(capturedMessage.value)
    #expect(msg.stamp == nil)
    // Retire the router's retry timer so the effect set drains cleanly.
    await store.send(.router(.delivered(messageHash: msg.hash)))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.finish(timeout: .seconds(2))
}

// MARK: - Absurd cost (64) → no stamp, message still sent

/// Paranoia test: a cost of 64 demands ~2^64 hash rounds — far beyond the ceiling.
/// Confirms that `maxDeliveryStampCost + 1` is not a special case: any cost above the ceiling
/// is refused, regardless of magnitude.
@MainActor @Test func lxmfNodeSendsUnstampedMessageWhenCostIsAbsurdlyHigh_doesNotRefuseToSend() async throws {
    let store = makeDeliveryStampStore(advertisedStampCost: 64)
    let capturedMessage = LockIsolated<LXMessage?>(nil)
    await store.send(.send(destinationHash: peerDestHash, title: Data("t".utf8),
                           content: Data("c".utf8), method: .opportunistic))
    await store.receive { action in
        if case let .router(.send(m, _)) = action {
            capturedMessage.setValue(m)
            return true
        }
        return false
    }
    let msg = try #require(capturedMessage.value)
    #expect(msg.stamp == nil)
    // Retire the router's retry timer so the effect set drains cleanly.
    await store.send(.router(.delivered(messageHash: msg.hash)))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.finish(timeout: .seconds(2))
}

// MARK: - Cancellable: in-flight search is abandoned when cancelled

/// A cost at `maxDeliveryStampCost` is legitimate (~2^20 rounds, minutes of CPU). The store can
/// only finish within the time limit if the in-flight effect is cancelled and the search loop
/// responds to `Task.isCancelled`. This proves cancellability without relying on timing.
///
/// The `.timeLimit` is not a timing assertion — a cancelled search finishes in well under a second.
///
/// **Nor is it the safety net an earlier version of this comment claimed.** It said "without the
/// limit an unkillable loop would block the suite", implying the limit prevents that. It does not:
/// a vacuity audit deleted `Task.yield()` from `LXStamper.search` and this test **hung for 26
/// minutes** until killed. A loop that never suspends is uninterruptible, so swift-testing cannot
/// enforce a time limit against it — the limit can only fire on a task that yields. The test still
/// *catches* a missing yield (it never passes), but it does so by hanging the run rather than
/// failing it. If you are debugging a stalled suite, this is a place to look first.
///
/// `store.exhaustivity = .on` before `finish` is load-bearing: `TestStore`'s "an effect is still
/// running" diagnostic is suppressed under `.off`, so the flip is what catches a leaked effect.
@MainActor @Test(.timeLimit(.minutes(1))) func lxmfNodeCancelsInFlightDeliveryStampGeneration() async {
    let store = makeDeliveryStampStore(advertisedStampCost: LXMFNode.maxDeliveryStampCost)
    await store.send(.send(destinationHash: peerDestHash, title: Data("t".utf8),
                           content: Data("c".utf8), method: .opportunistic))
    // Cancel via the delivery-stamp cancel action (delivery stamps use CancelID.deliveryStamp).
    await store.send(.cancelDeliveryStamps)
    store.exhaustivity = .on
    await store.finish(timeout: .seconds(10))
}

// MARK: - .sendMessage — the path the app actually calls

/// **`.sendMessage` is ReTiCaMsgr's only send call site** (`AppFeature.swift:162`), so stamping that
/// reached `.send` alone would have left the shipping app sending unstamped to every stamp-enforcing
/// peer — the exact failure this work exists to fix. This is the regression pin for that gap.
///
/// Anti-vacuity: asserts on the stamp of the message the ROUTER received, not on state — a state
/// assertion would pass even if the effect forwarded the unstamped original.
@MainActor @Test func lxmfNodeSendMessageAttachesStampWhenCostIsWithinCeiling() async throws {
    let cost = 8
    let store = makeDeliveryStampStore(advertisedStampCost: cost)
    let sender = Identity()
    let msg = LXMessage.create(source: sender, destinationHash: peerDestHash, timestamp: 1700000000,
                               title: Data("t".utf8), content: Data("c".utf8))
    #expect(msg.stamp == nil)          // precondition: create() never stamps
    let captured = LockIsolated<LXMessage?>(nil)
    await store.send(.sendMessage(message: msg, alsoViaPropagation: false))
    await store.receive { action in
        if case let .router(.send(m, _)) = action {
            captured.setValue(m)
            return true
        }
        return false
    }
    let sent = try #require(captured.value)
    #expect(sent.stamp != nil)
    #expect(sent.validateStamp(targetCost: cost))
    #expect(sent.hash == msg.hash)     // stamping must not disturb the message ID
}

/// A caller-supplied message that ALREADY carries a stamp is forwarded with that stamp intact — we
/// never re-stamp. Reference does the same: `get_stamp` returns the existing stamp untouched
/// (`elif self.stamp != None: return self.stamp`, LXMessage.py:313, LXMF 1.1.0).
///
/// This is structurally binary as well as byte-exact: the pre-attached stamp is a sentinel that
/// would not survive a re-search, and the advertised cost (`maxDeliveryStampCost`) is ~8 minutes of
/// CPU, so a re-stamping implementation could not finish inside the timeout at all.
@MainActor @Test(.timeLimit(.minutes(1))) func lxmfNodeSendMessageDoesNotOverwriteAnExistingStamp() async throws {
    let store = makeDeliveryStampStore(advertisedStampCost: LXMFNode.maxDeliveryStampCost)
    let sender = Identity()
    let sentinel = Data(repeating: 0xEE, count: LXStamper.stampSize)
    let msg = LXMessage.create(source: sender, destinationHash: peerDestHash, timestamp: 1700000000,
                               title: Data("t".utf8), content: Data("c".utf8)).withStamp(sentinel)
    let captured = LockIsolated<LXMessage?>(nil)
    await store.send(.sendMessage(message: msg, alsoViaPropagation: false))
    await store.receive { action in
        if case let .router(.send(m, _)) = action {
            captured.setValue(m)
            return true
        }
        return false
    }
    let sent = try #require(captured.value)
    #expect(sent.stamp == sentinel)    // byte-exact: not re-searched, not dropped
    // Nothing may be left running — a re-stamp would still be searching here.
    await store.send(.router(.delivered(messageHash: msg.hash)))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.finish(timeout: .seconds(2))
}
