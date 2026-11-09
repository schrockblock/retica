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
/// **The result is carried on the message, not in the delegate signature** — mirroring reference,
/// which stores `stamp_valid`/`stamp_checked` on the `LXMessage` object (LXMessage.py:157-158) and
/// assigns them in `lxmf_delivery` (LXMRouter.py:1865-1869) rather than passing them anywhere. The
/// message already reaches the app through `.delegate(.messageReceived(message:signatureValidated:))`,
/// so surfacing the tri-state needed **no** delegate change and **no** sibling-project change.
///
/// An earlier revision of this file claimed a delegate parameter would have been a *breaking change*
/// for ReTiCaMsgr and used that to justify not surfacing the result at all. That justification was
/// wrong twice over and is recorded here rather than quietly deleted: (a) reference does not use a
/// callback signature for this, so the premise was never the relevant question; (b) ReTiCaMsgr's
/// reducer ends in a wildcard `case .node, .binding: return .none` (`AppFeature.swift:276`), so an
/// additive `Delegate` case would have compiled unchanged anyway. The check that had been run was
/// whether the *existing* case is consumed, which is a different question from whether an *additive*
/// change compiles. The result of that error was a feature inert in every shipping configuration:
/// with enforcement off (the default, and the only configuration any caller produces) the reducer
/// emitted byte-identical output whether validation ran or not.
///
/// **Tickets:** a stamp equal to `truncated_hash(ticket + message_id)` for an unexpired ticket we
/// issued to the sender is also valid (reference `validate_stamp`, LXMessage.py:280-301, LXMF 1.3.0).
/// Those cases are in `LXMFNodeTicketTests`; every message here has no ticket issued to its sender.
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

/// A message carrying a stamp that is **deterministically** invalid at `cost`.
///
/// **The seeded identity is the whole point.** The first version of this helper built the message
/// from a fresh random `Identity()`, so the message hash — and therefore the stamp workblock —
/// changed every run, and "all-0xFF is invalid" was a *probabilistic* claim: at the cost 8 its
/// callers use, an all-0xFF stamp is genuinely valid with p = 2⁻⁸, i.e. one suite run in 256 would
/// have seen two tests report the opposite of their names. A fixed 64-byte private key makes
/// `LXMessage.create`'s hash fixed (`hash = fullHash(destHash ‖ sourceHash ‖ payload)`,
/// LXMessage.swift:121-124 — the hedged signature is *not* an input), so the workblock is fixed and
/// the stamp's invalidity is a settled fact rather than a 1-in-256 gamble.
///
/// The `#expect` below is the guard that keeps it settled: if anything upstream changes the hash
/// derivation, this fails loudly instead of flaking.
private func messageWithInvalidStamp(atCost cost: Int) -> LXMessage {
    // 64 fixed bytes = X25519(32) ‖ Ed25519(32); any 32 bytes are a valid raw scalar for both.
    let seed = Data(repeating: 0x11, count: 32) + Data(repeating: 0x22, count: 32)
    let sender = Identity(privateKey: seed)!
    let recipientDeliveryHash = Data(repeating: 0xBB, count: 16)
    let base = LXMessage.create(source: sender, destinationHash: recipientDeliveryHash,
                                timestamp: 1700000000, title: Data("t".utf8), content: Data("c".utf8))
    let message = base.withStamp(Data(repeating: 0xFF, count: LXStamper.stampSize))
    #expect(!message.validateStamp(targetCost: cost), "fixture stamp is no longer invalid at \(cost)")
    return message
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
/// is never emitted. The `stampChecked == false` assertion is the one that distinguishes this from
/// every other case — it fails if the cost gate is removed and validation runs unconditionally.
@MainActor @Test func inboundStamp_noCostConfigured_messageIsDeliveredNeverChecked() async {
    let store = makeInboundStampStore(deliveryStampCost: nil)
    let message = messageWithNoStamp()
    let got = LockIsolated<(hash: Data, checked: Bool, valid: Bool)?>(nil)
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: false, method: .opportunistic))))
    await store.receive { action in
        if case let .delegate(.messageReceived(m, _, _)) = action {
            got.setValue((m.hash, m.stampChecked, m.stampValid))
            return true
        }
        return false
    }
    #expect(got.value?.hash == message.hash)
    #expect(got.value?.checked == false)   // never checked — the tri-state's third leg
    #expect(got.value?.valid == false)
}

/// Even a message with a valid stamp and no cost configured is delivered, and is flagged
/// **never checked** — not "valid". We did not verify that stamp, and saying we did would be a lie
/// the app would render as a trust signal.
@MainActor @Test func inboundStamp_noCostConfigured_stampedMessageIsDeliveredNeverChecked() async {
    let store = makeInboundStampStore(deliveryStampCost: nil)
    let message = await messageWithValidStamp(cost: 1)
    let got = LockIsolated<(hash: Data, checked: Bool, valid: Bool)?>(nil)
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: false, method: .opportunistic))))
    await store.receive { action in
        if case let .delegate(.messageReceived(m, _, _)) = action {
            got.setValue((m.hash, m.stampChecked, m.stampValid))
            return true
        }
        return false
    }
    #expect(got.value?.hash == message.hash)
    #expect(got.value?.checked == false)
    #expect(got.value?.valid == false)     // a genuinely-valid stamp we chose not to check
}

// MARK: - Cost configured + valid stamp → delivered

/// With a configured cost, a message carrying a valid stamp is delivered and flagged
/// **checked-and-valid**. This is the happy path, and the `stampValid == true` assertion is what
/// makes it detect a removed or broken validation call — without it the test passed whether or not
/// `validateStamp` ever ran.
///
/// Anti-vacuity: the matching closure runs only when `.delegate(.messageReceived)` is emitted;
/// `got` stays nil if the message is dropped, causing every `#expect` to fail.
@MainActor @Test func inboundStamp_costConfigured_validStamp_messageIsDeliveredCheckedValid() async {
    let cost = 1
    let store = makeInboundStampStore(deliveryStampCost: cost, enforceDeliveryStamps: false)
    let message = await messageWithValidStamp(cost: cost)
    let got = LockIsolated<(hash: Data, sigValidated: Bool, checked: Bool, valid: Bool)?>(nil)
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: true, method: .opportunistic))))
    await store.receive { action in
        if case let .delegate(.messageReceived(m, v, _)) = action {
            got.setValue((m.hash, v, m.stampChecked, m.stampValid))
            return true
        }
        return false
    }
    #expect(got.value?.hash == message.hash)
    #expect(got.value?.sigValidated == true)   // signatureValidated threads through unchanged
    #expect(got.value?.checked == true)
    #expect(got.value?.valid == true)          // fails if validateStamp is stubbed false
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
/// The message is delivered flagged **checked-and-failed** — distinct from the never-checked case
/// above. That distinction is the whole reason reference carries two booleans rather than one.
///
/// Anti-vacuity: the test ONLY passes if `.delegate(.messageReceived)` is emitted. If the code
/// dropped the message, `store.receive` would time out or the `#expect`s would fail on nil.
@MainActor @Test func inboundStamp_costConfigured_invalidStamp_enforcementOff_messageIsDeliveredCheckedInvalid() async {
    let store = makeInboundStampStore(deliveryStampCost: 8, enforceDeliveryStamps: false)
    let message = messageWithInvalidStamp(atCost: 8)
    let got = LockIsolated<(checked: Bool, valid: Bool)?>(nil)
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: false, method: .opportunistic))))
    await store.receive { action in
        if case let .delegate(.messageReceived(m, _, _)) = action {
            got.setValue((m.stampChecked, m.stampValid))
            return true
        }
        return false
    }
    #expect(got.value?.checked == true)    // checked — NOT the never-checked state
    #expect(got.value?.valid == false)
}

/// Same as above but with a nil stamp (absent, not just wrong bytes). Reference `validate_stamp`
/// returns False immediately when `self.stamp == None` (LXMessage.py:285-286), so the absent-stamp
/// path must not accidentally bypass the enforcement check in a way that drops the message.
///
/// An absent stamp is `checked` too: we ran the check and it failed for want of a stamp. Reference
/// sets `stamp_checked = True` on this branch as well (LXMRouter.py:1868-1869).
@MainActor @Test func inboundStamp_costConfigured_noStamp_enforcementOff_messageIsDeliveredCheckedInvalid() async {
    let store = makeInboundStampStore(deliveryStampCost: 8, enforceDeliveryStamps: false)
    let message = messageWithNoStamp()
    let got = LockIsolated<(checked: Bool, valid: Bool)?>(nil)
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: false, method: .opportunistic))))
    await store.receive { action in
        if case let .delegate(.messageReceived(m, _, _)) = action {
            got.setValue((m.stampChecked, m.stampValid))
            return true
        }
        return false
    }
    #expect(got.value?.checked == true)
    #expect(got.value?.valid == false)
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
    let message = messageWithInvalidStamp(atCost: 8)
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: false, method: .opportunistic))))
    store.exhaustivity = .on
    await store.finish(timeout: .seconds(2))
}

/// Enforcement on + nil stamp (absent) → also dropped. A nil stamp fails `validateStamp`
/// (which returns false immediately when `stamp == nil`), so the same drop path fires.
@MainActor @Test func inboundStamp_costConfigured_noStamp_enforcementOn_messageIsDropped() async {
    let store = makeInboundStampStore(deliveryStampCost: 8, enforceDeliveryStamps: true)
    let message = messageWithNoStamp()
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: false, method: .opportunistic))))
    store.exhaustivity = .on
    await store.finish(timeout: .seconds(2))
}

// MARK: - Enforcement on + valid stamp → delivered (not dropped)

/// With enforcement on and a VALID stamp, the message is delivered normally. This is the cross
/// of "enforcement on" and "valid stamp" — it would be dropped by a naive "enforce means always
/// drop" implementation.
///
/// Anti-vacuity: same as other delivered tests — `got` stays nil if dropped, failing every `#expect`.
@MainActor @Test func inboundStamp_costConfigured_validStamp_enforcementOn_messageIsDelivered() async {
    let cost = 1
    let store = makeInboundStampStore(deliveryStampCost: cost, enforceDeliveryStamps: true)
    let message = await messageWithValidStamp(cost: cost)
    let got = LockIsolated<(hash: Data, checked: Bool, valid: Bool)?>(nil)
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: false, method: .opportunistic))))
    await store.receive { action in
        if case let .delegate(.messageReceived(m, _, _)) = action {
            got.setValue((m.hash, m.stampChecked, m.stampValid))
            return true
        }
        return false
    }
    #expect(got.value?.hash == message.hash)
    #expect(got.value?.checked == true)
    #expect(got.value?.valid == true)
}

// MARK: - Out-of-range configured costs never reach the validator

/// A configured cost of **0** must not enforce anything. The announce already advertises "no cost
/// required" for 0 (`LXMFAnnounceData.pack`'s `> 0 && < 255` gate, LXMFAnnounceData.swift:113), so
/// enforcing on 0 meant advertising one contract and applying another: `validateStamp` returns false
/// for an *absent* stamp at any cost, so with enforcement on we dropped every message from every
/// conforming peer — the whole inbox, silently.
///
/// Fixed at the setter, matching reference `set_inbound_stamp_cost`'s `stamp_cost < 1 → None`
/// (LXMRouter.py:385-386, LXMF 1.1.0).
///
/// **The cost must be set through the ACTION, not the state helper** — the sanitisation lives in the
/// setter, so seeding `State.deliveryStampCost` directly would test nothing.
///
/// Anti-vacuity: enforcement is ON and the message carries no stamp, so the pre-fix behaviour was a
/// drop; `store.receive` fails (rather than silently skipping) if the message never arrives.
@MainActor @Test func lxmfNodeDoesNotEnforceStampsAfterACostOfZero() async {
    let store = makeInboundStampStore(deliveryStampCost: nil, enforceDeliveryStamps: true)
    await store.send(.setDisplayName(nil, stampCost: 0))
    #expect(store.state.deliveryStampCost == nil)

    let message = messageWithNoStamp()
    let got = LockIsolated<(hash: Data, checked: Bool)?>(nil)
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: false, method: .opportunistic))))
    await store.receive { action in
        if case let .delegate(.messageReceived(m, _, _)) = action {
            got.setValue((m.hash, m.stampChecked))
            return true
        }
        return false
    }
    #expect(got.value?.hash == message.hash)     // delivered, not dropped
    #expect(got.value?.checked == false)         // and never checked — no cost is configured
}

/// A configured cost of **-1** must not make garbage validate. `LXStamper.stampValid` is
/// `stampValue >= targetCost` (LXStamper.swift:57-58) and a leading-zero-bit count is never
/// negative, so at -1 *every* stamp passes: the app was told `stampValid == true` for an all-0xFF
/// stamp. Of everything a bad cost can do, reporting a forged stamp as verified is the worst,
/// because the app renders it as a trust signal.
///
/// Fixed at the setter (`< 1 → None`, LXMRouter.py:385-386, LXMF 1.1.0), so no validation runs at
/// all and the message arrives flagged never-checked.
///
/// Anti-vacuity: asserts BOTH flags. `checked == false` fails if the sanitisation is removed
/// (validation would run), and `valid == false` fails if it is removed in the specific way that
/// matters (the forged stamp reported valid).
@MainActor @Test func lxmfNodeDoesNotReportAStampValidAfterANegativeCost() async {
    let store = makeInboundStampStore(deliveryStampCost: nil, enforceDeliveryStamps: false)
    await store.send(.setDisplayName(nil, stampCost: -1))
    #expect(store.state.deliveryStampCost == nil)

    let message = messageWithInvalidStamp(atCost: 8)
    let got = LockIsolated<(checked: Bool, valid: Bool)?>(nil)
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: false, method: .opportunistic))))
    await store.receive { action in
        if case let .delegate(.messageReceived(m, _, _)) = action {
            got.setValue((m.stampChecked, m.stampValid))
            return true
        }
        return false
    }
    #expect(got.value?.checked == false)
    #expect(got.value?.valid == false)           // the forged stamp is NOT reported verified
}

/// The positive control for the two tests above: a cost set through the same action, in range, is
/// stored and IS enforced. Without this, a sanitiser that simply cleared the field on every call
/// would satisfy both of them.
///
/// Anti-vacuity: enforcement is on and the stamp is invalid, so the assertion is a DROP — caught by
/// flipping exhaustivity `.on` before teardown, which is what makes a spurious delivery fail.
@MainActor @Test func lxmfNodeEnforcesAStampCostSetThroughTheSetter() async {
    let store = makeInboundStampStore(deliveryStampCost: nil, enforceDeliveryStamps: true)
    await store.send(.setDisplayName(nil, stampCost: 8))
    #expect(store.state.deliveryStampCost == 8)

    await store.send(.router(.delegate(.messageDelivered(message: messageWithInvalidStamp(atCost: 8),
                                                         signatureValidated: false, method: .opportunistic))))
    store.exhaustivity = .on
    await store.finish(timeout: .seconds(2))
}

// MARK: - The validation result must not disturb wire bytes or equality

/// `withStampValidation` records a local conclusion; it must not change what the message *says*.
///
/// Three properties, each of which would break something real if violated:
///  • `packed` byte-identical — the validation result is not a wire field. The cross-validation
///    vectors (`lxMessageMatchesReferenceLXMF`) byte-compare against genuine lxmf 1.1.0 output and
///    would fail if a 6th payload element or any other byte appeared.
///  • `==` unaffected — following the `receivedBytes` precedent (see the `Equatable` conformance on
///    `LXMessage`). A validated inbound message must still equal the constructed message it carries,
///    or unrelated tests comparing received-to-expected start failing.
///  • the message ID (`hash`) is untouched, so dedup and delivery correlation still work.
///
/// Anti-vacuity: the assertions compare a validated copy against the ORIGINAL, so a `withStampValidation`
/// that silently returned `self` would pass the first three but fail the last two (`checked`/`valid`).
@Test func withStampValidationChangesNoWireByteAndNoEquality() async {
    let original = await messageWithValidStamp(cost: 1)
    let validated = original.withStampValidation(valid: true)
    let failed = original.withStampValidation(valid: false)

    #expect(validated.packed == original.packed)      // no emitted byte changes
    #expect(failed.packed == original.packed)
    #expect(validated.hash == original.hash)          // message ID untouched
    #expect(validated == original)                    // excluded from `==`, per receivedBytes precedent
    #expect(failed == original)
    #expect(validated == failed)                      // differing only in an excluded field

    // ...but the flags themselves did change, so the copy is not a no-op.
    #expect(original.stampChecked == false)
    #expect(validated.stampChecked == true)
    #expect(validated.stampValid == true)
    #expect(failed.stampChecked == true)
    #expect(failed.stampValid == false)
}

/// A message that came off the wire keeps its `receivedBytes` through validation, so `packed` still
/// returns the sender's exact bytes and the signature still validates for any downstream hop.
///
/// This is the property that distinguishes `withStampValidation` from `withStamp`, which
/// deliberately drops `receivedBytes` because it changes the payload.
///
/// **The fixture must be NON-CANONICAL, and an earlier version of this test was vacuous for
/// exactly that reason.** It built the wire form with `LXMessage.create(...).packed`, so
/// `receivedBytes` held bytes *our own encoder* had produced — and dropping `receivedBytes` then
/// re-encodes to the identical bytes, because our encoder is deterministic. Both assertions held
/// whether the property was preserved or dropped. A vacuity audit proved it: under a mutation that
/// drops `receivedBytes`, the old test passed while a foreign-encoded probe failed on both
/// assertions (113 vs 114 bytes, signature invalid).
///
/// So the title is encoded `bin16` (`0xC5`) where `MsgPack.encode` emits `bin8` (`0xC4`) for a
/// length under 256 — spec-legal, decodes identically, and something our encoder provably cannot
/// reproduce. Same technique as the `receivedBytes` tests in `LXMessageReceivedBytesTests`; it is
/// re-inlined here because that helper lives in a different test target.
@Test func withStampValidationPreservesReceivedBytesSoSignatureStillValidates() async throws {
    let sender = Identity()
    let recipientDeliveryHash = Data(repeating: 0xBB, count: 16)
    let sourceHash = LXMessage.deliveryHash(identityHash: sender.hash)
    let title = Data("t".utf8)
    let content = Data("c".utf8)

    // Hand-built payload: fixarray(4) [double, bin16(title), bin(content), map()].
    var payload = Data([0x94])
    payload += MsgPack.encode(.double(1700000000))
    payload += Data([0xC5, UInt8(title.count >> 8), UInt8(title.count & 0xFF)]) + title
    payload += MsgPack.encode(.bin(content))
    payload += MsgPack.encode(.map([]))

    let hashedPart = recipientDeliveryHash + sourceHash + payload
    let signature = sender.sign(hashedPart + Crypto.fullHash(hashedPart))
    let wire = recipientDeliveryHash + sourceHash + signature + payload

    // Guard the fixture itself: if our encoder ever emitted bin16 here, the test would silently
    // revert to the vacuous shape it was written to escape.
    let canonical = LXMessage.create(source: sender, destinationHash: recipientDeliveryHash,
                                     timestamp: 1700000000, title: title, content: content)
    #expect(canonical.packed.count != wire.count, "fixture is no longer non-canonical")

    let onWire = try #require(LXMessage.unpack(wire))
    #expect(onWire.validateSignature(source: sender))          // precondition
    #expect(onWire.packed == wire)                             // precondition: receivedBytes in play

    let validated = onWire.withStampValidation(valid: false)
    #expect(validated.packed == wire)                          // sender's exact bytes retained
    #expect(validated.validateSignature(source: sender))       // still verifiable downstream
}
