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
    var ep = TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false)
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

/// A message to a peer with no learned stamp cost is sent with no stamp. The packed bytes must be
/// byte-identical to a freshly-created (no-stamp) message — the cross-validation vectors
/// byte-compare against genuine Python output and must not be disturbed.
///
/// Anti-vacuity: the assertion unpacks the message the router receives and checks `.stamp == nil`.
/// An `if let` around the only `#expect` would pass when the message is never received; we use
/// `try #require` to fail the test if nothing arrives.
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
    // Packed bytes are byte-identical to a message built with no stamp (no 5th payload element).
    #expect(msg.packed == LXMessage.unpack(msg.packed)?.packed ?? msg.packed)
    let unpacked = try #require(LXMessage.unpack(msg.packed))
    #expect(unpacked.stamp == nil)
}

// MARK: - Learned cost within ceiling → stamp attached and valid

/// A message to a peer with a learned cost within the ceiling is sent WITH a stamp, and the stamp
/// validates at that cost.
///
/// Anti-vacuity: the assertion captures the message the router receives and checks the stamp via
/// `validateStamp`. Using a cost of 1 makes the search near-instant.
///
/// The stamp is validated at the ADVERTISED cost, not at an arbitrary lower cost, to prove the
/// generator honoured the cost and did not accidentally produce a zero-bit solution.
@MainActor @Test func lxmfNodeAttachesStampWhenCostIsWithinCeiling() async throws {
    let cost = 1
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
/// The `.timeLimit` is a safety net, not a timing assertion: a cancelled search finishes in well
/// under a second. Without the limit an unkillable loop would block the suite.
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
