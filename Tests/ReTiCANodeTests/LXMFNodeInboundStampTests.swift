import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// Inbound stamp validation in `LXMFNode` (Task 2, 2026-08-16 delivery-stamps slice).
///
/// When we receive a message and our node has a `deliveryStampCost` configured, we validate the
/// sender's stamp against that cost. The reference logic is in `LXMRouter.lxmf_delivery`
/// (LXMRouter.py:1861-1880, LXMF 1.1.0):
///
///     required_stamp_cost = self.delivery_destinations[message.destination_hash].stamp_cost
///     if required_stamp_cost != None:
///         if message.validate_stamp(required_stamp_cost, tickets=...):
///             message.stamp_valid = True
///             message.stamp_checked = True
///         else:
///             message.stamp_valid = False
///             message.stamp_checked = True
///         if not message.stamp_valid:
///             if no_stamp_enforcement: ... allow anyway ...
///             else:
///                 if self._enforce_stamps:
///                     return False   # dropped
///                 else: ... allow anyway ...
///
/// Key reference parity points (verified in reference source):
///
/// - `enforce_stamps` **defaults to False** (`LXMRouter.__init__`, LXMRouter.py:99). An invalid
///   stamp with enforcement off is DELIVERED, not dropped.
/// - Validation is **O(1)** in the cost: `stamp_workblock` + `stamp_valid` is one workblock
///   derivation and one leading-zero-bit check (LXMessage.py:288-289). There is no ceiling needed here.
/// - A nil `deliveryStampCost` means "no cost configured" — no validation is attempted.
///
/// **Delegate signature kept unchanged.** Reference sets both `stamp_valid` and `stamp_checked` but
/// `LXMFNode.Delegate.messageReceived(message:signatureValidated:)` carries one flag already consumed
/// by `ReTiCaMsgr/AppFeature.swift:170` as `validated` for persisted Message rows. Adding a stamp
/// parameter is a **breaking change** that requires updating the sibling project. Since stamp
/// enforcement is handled entirely inside `LXMFNode` (drop on enforcement; deliver on lax), the app
/// does not need per-message stamp status surfaced through the delegate to render correctly. This can
/// be evolved if the app later needs to distinguish "checked and valid" from "never checked".
///
/// **Ticket divergence (documented, not implemented):** Reference `validate_stamp`
/// (LXMessage.py:273-283) accepts a stamp equal to `truncated_hash(ticket + message_id)` regardless
/// of cost. ReTiCA has no tickets (Tier 3, unticketed). When `enforceDeliveryStamps = true`, a
/// ticket-holding peer that reference would accept, we reject. This divergence is harmless with
/// enforcement off (the default) — such messages are delivered. Whoever enables enforcement should
/// be aware that `LXMessage.py:273-283` covers a wider acceptance set than `LXMessage.validateStamp`.
///
/// **Anti-vacuity standard.** Every test asserts on whether `.delegate(.messageReceived)` arrives or
/// not. A test that passes when the validate path never runs, or when a dropped message is silently
/// delivered, would be vacuous. The structure used here:
///
/// - "delivered" tests: `await store.receive` with a closure that captures the message hash and
///   `signatureValidated`; a `LockIsolated<Bool>` flag records whether the action was seen.
/// - "dropped" tests: `store.exhaustivity = .on` + `finish` confirms no `.delegate(.messageReceived)`
///   action is emitted.

// MARK: - Helpers

/// A message with a genuine stamp valid at `cost`. Fast because cost 1 has p=1/2 per candidate.
private func messageWithValidStamp(cost: Int = 1) async -> LXMessage {
    let sender = Identity()
    let recipientDeliveryHash = Data(repeating: 0xBB, count: 16)
    let base = LXMessage.create(source: sender, destinationHash: recipientDeliveryHash,
                                timestamp: 1700000000, title: Data("t".utf8), content: Data("c".utf8))
    // generateStamp at cost 1 is sub-millisecond; force-unwrap is safe: only returns nil when cancelled.
    let stamp = await LXStamper.generateStamp(messageId: base.hash, targetCost: cost)!
    return base.withStamp(stamp)
}

/// A message with NO stamp (stamp == nil).
private func messageWithNoStamp() -> LXMessage {
    let sender = Identity()
    let recipientDeliveryHash = Data(repeating: 0xBB, count: 16)
    return LXMessage.create(source: sender, destinationHash: recipientDeliveryHash,
                            timestamp: 1700000000, title: Data("t".utf8), content: Data("c".utf8))
}

/// A message with a stamp that will fail validation (all-0xFF bytes, astronomically unlikely to be valid
/// at any realistic cost).
private func messageWithInvalidStamp() -> LXMessage {
    let base = messageWithNoStamp()
    return base.withStamp(Data(repeating: 0xFF, count: LXStamper.stampSize))
}

@MainActor
private func makeInboundStampStore(
    deliveryStampCost: Int?,
    enforceDeliveryStamps: Bool = false
) -> TestStore<LXMFNode.State, LXMFNode.Action> {
    var node = LXMFNode.State(
        identity: Identity(),
        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false)
    )
    node.deliveryStampCost = deliveryStampCost
    node.enforceDeliveryStamps = enforceDeliveryStamps
    let store = TestStore(initialState: node) { LXMFNode() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.continuousClock = TestClock()
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

// MARK: - No cost configured → no validation, always delivered

/// When `deliveryStampCost == nil`, no validation is attempted and every message is delivered
/// regardless of whether it carries a stamp. This is the "never checked" case from reference:
/// `if required_stamp_cost != None:` (LXMRouter.py:1862) gates the entire validation block.
///
/// Anti-vacuity: `received` (not `skipReceivedActions`) is used so the test FAILS if the action
/// is never emitted. The `LockIsolated<Bool>` flag records that the matching closure actually ran.
@MainActor @Test func inboundStamp_noCostConfigured_messageIsDelivered() async {
    let store = makeInboundStampStore(deliveryStampCost: nil)
    let message = messageWithNoStamp()
    let deliveredHash = LockIsolated<Data?>(nil)
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: false))))
    await store.receive { action in
        if case let .delegate(.messageReceived(m, _)) = action {
            deliveredHash.setValue(m.hash)
            return true
        }
        return false
    }
    #expect(deliveredHash.value == message.hash)
}

/// Even a message with a valid stamp and no cost configured is delivered (stamp is irrelevant
/// when no cost is set).
@MainActor @Test func inboundStamp_noCostConfigured_stampedMessageIsDelivered() async {
    let store = makeInboundStampStore(deliveryStampCost: nil)
    let message = await messageWithValidStamp(cost: 1)
    let deliveredHash = LockIsolated<Data?>(nil)
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: false))))
    await store.receive { action in
        if case let .delegate(.messageReceived(m, _)) = action {
            deliveredHash.setValue(m.hash)
            return true
        }
        return false
    }
    #expect(deliveredHash.value == message.hash)
}

// MARK: - Cost configured + valid stamp → delivered

/// With a configured cost, a message carrying a valid stamp is delivered. This is the happy path.
///
/// Anti-vacuity: the matching closure runs only when `.delegate(.messageReceived)` is emitted;
/// `deliveredHash` stays nil if the message is dropped, causing the `#expect` to fail.
@MainActor @Test func inboundStamp_costConfigured_validStamp_messageIsDelivered() async {
    let cost = 1
    let store = makeInboundStampStore(deliveryStampCost: cost, enforceDeliveryStamps: false)
    let message = await messageWithValidStamp(cost: cost)
    let deliveredHash = LockIsolated<Data?>(nil)
    let deliveredValidated = LockIsolated<Bool?>(nil)
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: true))))
    await store.receive { action in
        if case let .delegate(.messageReceived(m, v)) = action {
            deliveredHash.setValue(m.hash)
            deliveredValidated.setValue(v)
            return true
        }
        return false
    }
    #expect(deliveredHash.value == message.hash)
    #expect(deliveredValidated.value == true)   // signatureValidated threads through unchanged
}

// MARK: - Cost configured + invalid stamp + enforcement OFF → still delivered

/// **This is the reference behaviour most likely to be inverted.** With a cost configured and
/// an invalid (or absent) stamp, but enforcement OFF (the default), the message is still delivered.
///
/// Reference (LXMRouter.py:1871-1879):
///
///     if not message.stamp_valid:
///         if no_stamp_enforcement: ...allow
///         else:
///             if self._enforce_stamps:
///                 return False          # dropped
///             else: ...allow anyway, with a log
///
/// An `enforceDeliveryStamps = false` guard that drops instead of delivers is the wrong inversion.
///
/// Anti-vacuity: the test ONLY passes if `.delegate(.messageReceived)` is emitted. If the code
/// dropped the message, `store.receive` would time out or the `#expect` would fail.
@MainActor @Test func inboundStamp_costConfigured_invalidStamp_enforcementOff_messageIsDelivered() async {
    let store = makeInboundStampStore(deliveryStampCost: 8, enforceDeliveryStamps: false)
    let message = messageWithInvalidStamp()
    let delivered = LockIsolated<Bool>(false)
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: false))))
    await store.receive { action in
        if case .delegate(.messageReceived) = action {
            delivered.setValue(true)
            return true
        }
        return false
    }
    #expect(delivered.value == true)
}

/// Same as above but with a nil stamp (absent, not just wrong bytes). Reference `validate_stamp`
/// returns False immediately when `self.stamp == None` (LXMessage.py:285-286), so the absent-stamp
/// path must not accidentally bypass the enforcement check in a way that drops the message.
@MainActor @Test func inboundStamp_costConfigured_noStamp_enforcementOff_messageIsDelivered() async {
    let store = makeInboundStampStore(deliveryStampCost: 8, enforceDeliveryStamps: false)
    let message = messageWithNoStamp()
    let delivered = LockIsolated<Bool>(false)
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: false))))
    await store.receive { action in
        if case .delegate(.messageReceived) = action {
            delivered.setValue(true)
            return true
        }
        return false
    }
    #expect(delivered.value == true)
}

// MARK: - Cost configured + invalid stamp + enforcement ON → dropped

/// With a cost configured, an invalid stamp, and enforcement ON, the message is dropped and
/// the app receives NOTHING. Mirrors `return False` in reference (LXMRouter.py:1877).
///
/// Anti-vacuity: `store.exhaustivity = .on` before `finish` is what catches a spurious
/// `.delegate(.messageReceived)`. Under `.off`, stray actions are silently swallowed. The
/// exhaustivity flip is the key assertion — it fails if the message was delivered when it should
/// have been dropped.
///
/// **This also mutation-catches the "enforcement off → deliver" test above:** changing
/// `enforceDeliveryStamps: true` → `false` in the store setup would make the message deliver,
/// and the exhaustivity check would fire. So the two tests are each other's mutation catchers.
@MainActor @Test func inboundStamp_costConfigured_invalidStamp_enforcementOn_messageIsDropped() async {
    let store = makeInboundStampStore(deliveryStampCost: 8, enforceDeliveryStamps: true)
    let message = messageWithInvalidStamp()
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: false))))
    store.exhaustivity = .on
    await store.finish(timeout: .seconds(2))
}

/// Enforcement on + nil stamp (absent) → also dropped. A nil stamp fails `validateStamp`
/// (which returns false immediately when `stamp == nil`), so the same drop path fires.
@MainActor @Test func inboundStamp_costConfigured_noStamp_enforcementOn_messageIsDropped() async {
    let store = makeInboundStampStore(deliveryStampCost: 8, enforceDeliveryStamps: true)
    let message = messageWithNoStamp()
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: false))))
    store.exhaustivity = .on
    await store.finish(timeout: .seconds(2))
}

// MARK: - Enforcement on + valid stamp → delivered (not dropped)

/// With enforcement on and a VALID stamp, the message is delivered normally. This is the cross
/// of "enforcement on" and "valid stamp" — it would be dropped by a naive "enforce means always
/// drop" implementation.
///
/// Anti-vacuity: same as other delivered tests — `deliveredHash` stays nil if dropped, failing `#expect`.
@MainActor @Test func inboundStamp_costConfigured_validStamp_enforcementOn_messageIsDelivered() async {
    let cost = 1
    let store = makeInboundStampStore(deliveryStampCost: cost, enforceDeliveryStamps: true)
    let message = await messageWithValidStamp(cost: cost)
    let deliveredHash = LockIsolated<Data?>(nil)
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: false))))
    await store.receive { action in
        if case let .delegate(.messageReceived(m, _)) = action {
            deliveredHash.setValue(m.hash)
            return true
        }
        return false
    }
    #expect(deliveredHash.value == message.hash)
}
