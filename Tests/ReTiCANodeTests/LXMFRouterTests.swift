import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA

/// Helper: a signed LXMessage from `source` to a recipient delivery hash.
private func makeMessage(source: Identity, recipientIdentityHash: Data = Identity().hash,
                         content: String = "hello router") -> LXMessage {
    LXMessage.create(source: source,
                     destinationHash: LXMessage.deliveryHash(identityHash: recipientIdentityHash),
                     timestamp: 1700000000.5, title: Data("t".utf8), content: Data(content.utf8))
}

@Test @MainActor func routerDeliversOpportunisticMessageValidatedWhenSourceKnown() async {
    let sender = Identity()
    let msg = makeMessage(source: sender)
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.learnedIdentity(destinationHash: msg.sourceHash, identity: sender))
    await store.send(.received(method: .opportunistic, destinationHash: msg.destinationHash,
                               data: msg.opportunisticPayload))
    await store.receive { action in
        if case let .delegate(.messageDelivered(m, validated, _)) = action {
            #expect(m.hash == msg.hash)
            #expect(m.content == Data("hello router".utf8))
            #expect(validated == true)
            return true
        }
        return false
    }
}

@Test @MainActor func routerDeliversDirectMessage() async {
    let sender = Identity()
    let msg = makeMessage(source: sender)
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.learnedIdentity(destinationHash: msg.sourceHash, identity: sender))
    await store.send(.received(method: .direct, destinationHash: msg.destinationHash, data: msg.packed))
    await store.receive { action in
        if case let .delegate(.messageDelivered(m, validated, _)) = action {
            #expect(m.hash == msg.hash); #expect(validated == true); return true
        }
        return false
    }
}

@Test @MainActor func routerDeliversUnknownSourceUnvalidated() async {
    let msg = makeMessage(source: Identity())
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    // No .learnedIdentity for the sender.
    await store.send(.received(method: .direct, destinationHash: msg.destinationHash, data: msg.packed))
    await store.receive { action in
        if case let .delegate(.messageDelivered(m, validated, _)) = action {
            #expect(m.hash == msg.hash); #expect(validated == false); return true
        }
        return false
    }
}

@Test @MainActor func routerDropsMalformedData() async {
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.received(method: .direct, destinationHash: Data(), data: Data(count: 20)))
    store.exhaustivity = .on   // no delegate emitted — a stray one fails teardown
}

@Test @MainActor func routerDropsDuplicateSameMethod() async {
    let sender = Identity()
    let msg = makeMessage(source: sender)
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.learnedIdentity(destinationHash: msg.sourceHash, identity: sender))
    await store.send(.received(method: .direct, destinationHash: msg.destinationHash, data: msg.packed))
    await store.receive { if case .delegate(.messageDelivered) = $0 { return true }; return false }
    await store.send(.received(method: .direct, destinationHash: msg.destinationHash, data: msg.packed))   // dup
    await store.receive { action in
        if case let .delegate(.duplicateDropped(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
}

/// The headline: the SAME message arriving via two different methods (opportunistic then direct)
/// reconstructs to the same message.hash and is delivered exactly once.
@Test @MainActor func routerDedupsAcrossArrivalMethods() async {
    let sender = Identity()
    let msg = makeMessage(source: sender)
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.learnedIdentity(destinationHash: msg.sourceHash, identity: sender))
    await store.send(.received(method: .opportunistic, destinationHash: msg.destinationHash,
                               data: msg.opportunisticPayload))
    await store.receive { action in
        if case let .delegate(.messageDelivered(m, _, _)) = action { #expect(m.hash == msg.hash); return true }
        return false
    }
    await store.send(.received(method: .direct, destinationHash: msg.destinationHash, data: msg.packed))   // same msg, other path
    await store.receive { action in
        if case let .delegate(.duplicateDropped(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
}

/// A tampered payload (byte flipped in the content region) still parses but fails signature validation
/// against the known sender identity → dropped as `.badSignature`, never delivered (spec 2026-10-28;
/// this test used to expect delivery with signatureValidated == false).
@Test @MainActor func routerDropsTamperedMessageFromKnownSender() async {
    let sender = Identity()
    let msg = makeMessage(source: sender, content: "hello world")
    var bytes = Array(msg.packed)
    bytes[bytes.count - 2] ^= 0x01     // flip last content byte (before the trailing empty-map 0x80)
    let tampered = LXMessage.unpack(Data(bytes))!   // flipping content changes the hash
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.learnedIdentity(destinationHash: msg.sourceHash, identity: sender))
    await store.send(.received(method: .direct, destinationHash: msg.destinationHash, data: Data(bytes)))
    await store.receive(.delegate(.messageRejected(hash: tampered.hash, reason: .badSignature)))
    store.exhaustivity = .on   // a stray `.messageDelivered` fails teardown
}

// MARK: - LXMF-4b outbound

@Test @MainActor func routerSendsSmallMessageOpportunistically() async {
    let msg = makeMessage(source: Identity(), content: "small")
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.receive { action in
        if case let .delegate(.sendOpportunistic(dest, payload, _)) = action {
            #expect(dest == msg.destinationHash); #expect(payload == msg.opportunisticPayload); return true
        }
        return false
    }
}

@Test @MainActor func routerFallsBackToDirectWhenOpportunisticTooLarge() async {
    let big = makeMessage(source: Identity(), content: String(repeating: "x", count: 1000))
    #expect(big.opportunisticFits == false)
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(big.destinationHash)   // path known → establishes directly
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.send(message: big, desiredMethod: .opportunistic))   // desired opportunistic, too big
    await store.receive { action in                                        // → treated as direct → requestLink
        if case let .delegate(.requestLink(dest)) = action { #expect(dest == big.destinationHash); return true }
        return false
    }
    #expect(store.state.directLinks[big.destinationHash] == .establishing)
}

/// The field report's message: wire size 402 B. It fits reference LXMF's opportunistic limit but no
/// relay header, so the router opens a link instead of sending a packet every retry would fail.
@Test @MainActor func routerSendsAWireSize402MessageDirect() async {
    let probe = makeMessage(source: Identity(), content: String(repeating: "x", count: 300))
    let source = Identity()
    let msg = makeMessage(source: source, content: String(repeating: "x", count: 300 + 402 - probe.packed.count))
    #expect(msg.packed.count == 402)
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(msg.destinationHash)
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.receive { action in
        if case let .delegate(.requestLink(dest)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    #expect(store.state.directLinks[msg.destinationHash] == .establishing)
}

@Test @MainActor func routerDirectWithNoLinkRequestsAndQueues() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(msg.destinationHash)   // path known → establishes directly
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { action in
        if case let .delegate(.requestLink(dest)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    #expect(store.state.directLinks[msg.destinationHash] == .establishing)
}

@Test @MainActor func routerLinkEstablishedDrainsQueueAsSendDirect() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let bigMsg = makeMessage(source: Identity(), content: String(repeating: "y", count: 2000))
    let linkID = Data(repeating: 0xCD, count: 16)
    var initial1 = LXMFRouter.State()
    initial1.knownPaths.insert(msg.destinationHash)   // path known → establishes directly
    let store = TestStore(initialState: initial1) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    // Enqueue a resource-sized message to the same destination to make asResource load-bearing
    var initial2 = LXMFRouter.State()
    initial2.directLinks[bigMsg.destinationHash] = .establishing
    initial2.outboundQueue[bigMsg.destinationHash] = [bigMsg]
    #expect(bigMsg.directRepresentation == .resource)
    let store2 = TestStore(initialState: initial2) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store2.exhaustivity = .off
    await store2.send(.linkEstablished(destinationHash: bigMsg.destinationHash, linkID: linkID))
    await store2.receive { action in
        if case let .delegate(.sendDirect(lid, data, asResource)) = action {
            #expect(lid == linkID); #expect(data == bigMsg.packed)
            #expect(asResource == true); return true
        }
        return false
    }
    #expect(store2.state.directLinks[bigMsg.destinationHash] == .active(linkID: linkID))
    // Also verify the packet-sized drain
    await store.send(.linkEstablished(destinationHash: msg.destinationHash, linkID: linkID))
    await store.receive { action in
        if case let .delegate(.sendDirect(lid, data, asResource)) = action {
            #expect(lid == linkID); #expect(data == msg.packed)
            #expect(asResource == (msg.directRepresentation == .resource)); return true
        }
        return false
    }
    #expect(store.state.directLinks[msg.destinationHash] == .active(linkID: linkID))
}

@Test @MainActor func routerDirectWithActiveLinkSendsImmediately() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let linkID = Data(repeating: 0xAB, count: 16)
    var initial = LXMFRouter.State()
    initial.directLinks[msg.destinationHash] = .active(linkID: linkID)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { action in
        if case let .delegate(.sendDirect(lid, data, _)) = action {
            #expect(lid == linkID); #expect(data == msg.packed); return true
        }
        return false
    }
}

/// Establish-once: a second direct send to a still-establishing destination is queued but does NOT
/// emit a second requestLink. (Removing the `directLinks[dest] == nil` guard would fire a second
/// requestLink — an un-received delegate caught by the exhaustive teardown.)
@Test @MainActor func routerEstablishesLinkOnceForConcurrentSends() async {
    let sender = Identity()
    let recipient = Identity().hash
    let m1 = makeMessage(source: sender, recipientIdentityHash: recipient, content: "one")
    let m2 = makeMessage(source: sender, recipientIdentityHash: recipient, content: "two")
    #expect(m1.destinationHash == m2.destinationHash)   // same recipient delivery destination
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(m1.destinationHash)   // path known → establishes directly
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.send(message: m1, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    #expect(store.state.directLinks[m1.destinationHash] == .establishing)
    // Second send to the same still-establishing destination → enqueued, no second requestLink.
    await store.send(.send(message: m2, desiredMethod: .direct))
    #expect(store.state.outboundQueue[m1.destinationHash]?.count == 2)   // both queued
    store.exhaustivity = .on   // a stray second requestLink would fail teardown
}

/// learnedIdentity flips a message from unvalidated to validated: the same sender's message is
/// signatureValidated == false before the identity is learned and true after.
@Test @MainActor func routerValidationDependsOnLearnedIdentity() async {
    let sender = Identity()
    let before = makeMessage(source: sender, content: "before")
    let after = makeMessage(source: sender, content: "after")   // distinct hash → not a dup
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.received(method: .direct, destinationHash: before.destinationHash, data: before.packed))
    await store.receive { action in
        if case let .delegate(.messageDelivered(_, v, _)) = action { #expect(v == false); return true }; return false
    }
    // Both messages are from `sender`, so before.sourceHash == after.sourceHash.
    await store.send(.learnedIdentity(destinationHash: after.sourceHash, identity: sender))
    await store.send(.received(method: .direct, destinationHash: after.destinationHash, data: after.packed))
    await store.receive { action in
        if case let .delegate(.messageDelivered(_, v, _)) = action { #expect(v == true); return true }; return false
    }
}

// MARK: - LXMF-4c-2 path request on no-path

@Test @MainActor func routerDirectWithNoPathRequestsPath() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))   // no known path
    await store.receive { action in
        if case let .delegate(.requestPath(dest)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    #expect(store.state.directLinks[msg.destinationHash] == .awaitingPath)
    #expect(store.state.outboundQueue[msg.destinationHash]?.count == 1)   // message parked
    // A stray requestLink (asking for a link with no path) must not be emitted. That is an
    // absence assertion, vacuous under .off — enforce it with flip-then-send, which unlike a
    // trailing `.on` does not also assert that the armed park timer has completed.
    store.exhaustivity = .on
    await store.send(.offeredMessageList(transientIds: []))   // no-op send; forces the stray check
    store.exhaustivity = .off
}

/// After requesting a path, learning it transitions awaitingPath → establishing (emits requestLink);
/// the queued message then drains as sendDirect once the link establishes.
@Test @MainActor func routerLearnedPathTriggersLinkThenDrains() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let linkID = Data(repeating: 0xEE, count: 16)
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestPath) = $0 { return true }; return false }
    #expect(store.state.directLinks[msg.destinationHash] == .awaitingPath)
    await store.send(.learnedPath(destinationHash: msg.destinationHash))
    await store.receive { action in
        if case let .delegate(.requestLink(dest)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    #expect(store.state.directLinks[msg.destinationHash] == .establishing)
    #expect(store.state.knownPaths.contains(msg.destinationHash))
    await store.send(.linkEstablished(destinationHash: msg.destinationHash, linkID: linkID))
    await store.receive { action in
        if case let .delegate(.sendDirect(lid, data, _)) = action {
            #expect(lid == linkID); #expect(data == msg.packed); return true
        }
        return false
    }
}

/// Request-path-once: a second direct send to a still-awaitingPath destination is queued but does NOT
/// emit a second requestPath. (Loosening the `directLinks[dest] == nil` guard to also admit
/// `.awaitingPath` fires a second requestPath — an un-received delegate caught by the
/// flip-then-send stray check at the end of this test.)
@Test @MainActor func routerRequestsPathOnceWhileAwaitingPath() async {
    let sender = Identity()
    let recipient = Identity().hash
    let m1 = makeMessage(source: sender, recipientIdentityHash: recipient, content: "one")
    let m2 = makeMessage(source: sender, recipientIdentityHash: recipient, content: "two")
    #expect(m1.destinationHash == m2.destinationHash)   // same recipient delivery destination
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.send(message: m1, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestPath) = $0 { return true }; return false }
    #expect(store.state.directLinks[m1.destinationHash] == .awaitingPath)
    await store.send(.send(message: m2, desiredMethod: .direct))   // still awaitingPath → enqueue only
    #expect(store.state.outboundQueue[m1.destinationHash]?.count == 2)   // both queued
    // The once-ness claim is an ABSENCE assertion, and under .off it is vacuous. Enforce it with
    // the flip-then-send idiom: `send` checks "must handle N received actions" BEFORE processing
    // the new action, and that check is not gated on in-flight effects — so it works even though
    // the park timer is armed. (A trailing `.on` would also catch the stray at teardown, but
    // teardown under `.on` additionally asserts no in-flight effects, which the armed park timer
    // would trip for an unrelated reason.) Flip back to .off so teardown tolerates that timer.
    store.exhaustivity = .on
    await store.send(.offeredMessageList(transientIds: []))   // no-op send; forces the stray check
    store.exhaustivity = .off
}

/// A queued message parked in .awaitingPath must not wait forever. Before this change,
/// establish's else-branch emitted requestPath and parked with NO timer, NO attempt count and
/// NO deliveryFailed — so a destination whose path response never arrives stalled indefinitely.
/// After this fix each park tick counts against establishAttempts, re-emits requestPath, and
/// after maxAttempts the queued message gets deliveryFailed and the park is cleared.
@Test @MainActor func routerBoundsTheAwaitingPathPark() async {
    let msg = makeMessage(source: Identity(), content: "bound-park")
    let clock = TestClock()
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off

    // No known path → establish() parks in .awaitingPath, arms the park timer, and emits requestPath.
    // establishAttempts is NOT incremented yet (it counts link-establish calls, not the initial park).
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { action in
        if case let .delegate(.requestPath(dest)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    #expect(store.state.directLinks[msg.destinationHash] == .awaitingPath)
    #expect(store.state.outboundQueue[msg.destinationHash]?.count == 1)

    // Each park-timer tick: .pathRequestDeadline increments establishAttempts and re-emits requestPath.
    // Ticks 1..maxAttempts set establishAttempts and re-emit; tick (maxAttempts+1) exceeds the ceiling
    // → deliveryFailed. (attempts > maxAttempts means the first give-up fires at maxAttempts+1.)
    for expected in 1...LXMFDelivery.maxAttempts {
        await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
        await store.receive { action in
            if case let .delegate(.requestPath(dest)) = action { #expect(dest == msg.destinationHash); return true }
            return false
        }
        #expect(store.state.establishAttempts[msg.destinationHash] == expected)
    }

    // One final tick pushes attempts to maxAttempts+1 > maxAttempts → give up.
    await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
    await store.receive { action in
        if case let .delegate(.deliveryFailed(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
    #expect(store.state.outboundQueue[msg.destinationHash] == nil)
    #expect(store.state.directLinks[msg.destinationHash] == nil)
    #expect(store.state.establishAttempts[msg.destinationHash] == nil)
    #expect(store.state.knownPaths.contains(msg.destinationHash) == false)

    // The park is genuinely over: flip to .on so teardown catches a stray requestPath/requestLink.
    // No timers remain in flight after the give-up.
    store.exhaustivity = .on
}

/// Learning a path cancels the park timer — a destination that recovers must not later be
/// failed by a stale deadline.
@Test @MainActor func routerLearnedPathCancelsTheAwaitingPathTimer() async {
    let msg = makeMessage(source: Identity(), content: "cancel-park")
    let clock = TestClock()
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off

    // Park in .awaitingPath (arms the path-request timer).
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestPath) = $0 { return true }; return false }
    #expect(store.state.directLinks[msg.destinationHash] == .awaitingPath)

    // A path arrives → transitions to .establishing AND cancels the park timer.
    await store.send(.learnedPath(destinationHash: msg.destinationHash))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    #expect(store.state.directLinks[msg.destinationHash] == .establishing)
    #expect(store.state.establishAttempts[msg.destinationHash] == 1)

    // Advance the clock well past pathRequestWaitSeconds. If the park timer was NOT cancelled,
    // the stale .pathRequestDeadline fires and lands in TCA's received-actions queue.
    // Flip to .on FIRST so the next send (below) triggers the "must handle received actions
    // before sending" check — TCA reports any unhandled received actions at that point.
    store.exhaustivity = .on
    await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds * 3))
    // Send a state-preserving no-op while still in .on mode. TCA checks the received-actions
    // queue before processing a new send. If a stale pathRequestDeadline landed, this send
    // fails with "must handle N received actions before sending". The empty-offer action is
    // a genuine no-op (guard !offered.isEmpty returns immediately with no state change).
    await store.send(.offeredMessageList(transientIds: []))

    // OK: no stale timer fired. Now drain the open link-establishment (burn remaining budget).
    store.exhaustivity = .off
    for _ in 2...LXMFDelivery.maxAttempts {
        await store.send(.linkClosed(destinationHash: msg.destinationHash))
        await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    }
    await store.send(.linkClosed(destinationHash: msg.destinationHash))
    await store.receive { action in
        if case let .delegate(.deliveryFailed(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
}

/// learnedPath for a destination with no awaitingPath entry records the path but starts no link
/// machinery (no requestLink, no directLinks entry).
@Test @MainActor func routerUnrelatedLearnedPathIsInert() async {
    let other = LXMessage.deliveryHash(identityHash: Identity().hash)
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.learnedPath(destinationHash: other))
    #expect(store.state.knownPaths.contains(other))   // recorded
    #expect(store.state.directLinks[other] == nil)    // but no link/path machinery started
    store.exhaustivity = .on   // a stray requestLink would fail teardown
}

// MARK: - LXMF-4c-1 outbound retry

@Test @MainActor func routerArmsRetryTimerOnOpportunisticSend() async {
    let msg = makeMessage(source: Identity(), content: "small")
    let clock = TestClock()
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.receive { if case .delegate(.sendOpportunistic) = $0 { return true }; return false }
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)]?.attempts == 1)
    await store.send(.delivered(messageHash: msg.hash, leg: .delivery))   // clean up the pending timer before teardown
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
}

@Test @MainActor func routerDeliveredConfirmsAndCancelsRetry() async {
    let msg = makeMessage(source: Identity(), content: "small")
    let clock = TestClock()
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.receive { if case .delegate(.sendOpportunistic) = $0 { return true }; return false }
    await store.send(.delivered(messageHash: msg.hash, leg: .delivery))
    await store.receive { action in
        if case let .delegate(.deliveryConfirmed(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)] == nil)
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))   // retry timer was cancelled → no retryDue
    store.exhaustivity = .on
}

@Test @MainActor func routerRetriesThenFailsAtMaxAttempts() async {
    let msg = makeMessage(source: Identity(), content: "small")
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(msg.destinationHash)   // path known → retries resend (not requestPath)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.receive { if case .delegate(.sendOpportunistic) = $0 { return true }; return false }
    // 4 retries re-emit the send (attempts 2..5); the 5th advance (attempts → 6 > max) fails.
    for _ in 0..<(LXMFDelivery.maxAttempts - 1) {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
        await store.receive { if case .delegate(.sendOpportunistic) = $0 { return true }; return false }   // re-emit
    }
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { action in
        if case let .delegate(.deliveryFailed(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)] == nil)
}

// MARK: - LXMF-4c-2 opportunistic pathless-retry

@Test @MainActor func routerOpportunisticPathlessRetryRequestsPath() async {
    let msg = makeMessage(source: Identity(), content: "small")
    let clock = TestClock()
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.receive { if case .delegate(.sendOpportunistic) = $0 { return true }; return false }   // best-effort try #1
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)]?.attempts == 1)
    // No known path → the first retry requests a path instead of resending.
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { action in
        if case let .delegate(.requestPath(dest)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)]?.attempts == 2)
    // The post-request wait is pathRequestWaitSeconds (7): advancing it fires the next retry (another requestPath).
    await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
    await store.receive { if case .delegate(.requestPath) = $0 { return true }; return false }
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)]?.attempts == 3)
    await store.send(.delivered(messageHash: msg.hash, leg: .delivery))   // cancel the pending timer before teardown
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    store.exhaustivity = .on
}

/// Learning a path mid-flight lets the next opportunistic retry resume sending (not another requestPath).
@Test @MainActor func routerOpportunisticResumesSendingAfterLearnedPath() async {
    let msg = makeMessage(source: Identity(), content: "small")
    let clock = TestClock()
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.receive { if case .delegate(.sendOpportunistic) = $0 { return true }; return false }
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { if case .delegate(.requestPath) = $0 { return true }; return false }   // pathless retry
    await store.send(.learnedPath(destinationHash: msg.destinationHash))
    // Path now known → next retry resends opportunistically instead of requesting a path again.
    await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
    await store.receive { action in
        if case let .delegate(.sendOpportunistic(dest, _, _)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    await store.send(.delivered(messageHash: msg.hash, leg: .delivery))
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    store.exhaustivity = .on
}

/// Known path from the start → opportunistic retries resend at retryWaitSeconds, never requestPath.
@Test @MainActor func routerOpportunisticWithKnownPathResendsNotRequestsPath() async {
    let msg = makeMessage(source: Identity(), content: "small")
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(msg.destinationHash)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.receive { if case .delegate(.sendOpportunistic) = $0 { return true }; return false }
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { if case .delegate(.sendOpportunistic) = $0 { return true }; return false }   // resend, not requestPath
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)]?.attempts == 2)
    await store.send(.delivered(messageHash: msg.hash, leg: .delivery))
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    store.exhaustivity = .on
}

/// A DIRECT pending delivery retries over its link even with no known path — pathless-retry is
/// opportunistic-only.
@Test @MainActor func routerDirectRetryUnaffectedByMissingPath() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let linkID = Data(repeating: 0x9A, count: 16)
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.directLinks[msg.destinationHash] = .active(linkID: linkID)   // active link, but no knownPaths entry
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.sendDirect) = $0 { return true }; return false }
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)]?.attempts == 1)
    // Direct retry resends over the link despite no known path (would be requestPath if pathless-retry leaked in).
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { action in
        if case let .delegate(.sendDirect(lid, _, _)) = action { #expect(lid == linkID); return true }
        return false
    }
    await store.send(.delivered(messageHash: msg.hash, leg: .delivery))
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
}

// MARK: - LXMF-4c-3a link-CLOSED recovery

@Test @MainActor func routerRecoversPendingOnNewLinkAfterClose() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let oldLinkID = Data(repeating: 0x01, count: 16)
    let newLinkID = Data(repeating: 0x02, count: 16)
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.directLinks[msg.destinationHash] = .active(linkID: oldLinkID)
    initial.knownPaths.insert(msg.destinationHash)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.sendDirect) = $0 { return true }; return false }   // sent on old link
    await store.send(.linkClosed(destinationHash: msg.destinationHash))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }   // re-establish
    await store.send(.linkEstablished(destinationHash: msg.destinationHash, linkID: newLinkID))
    // The pending message resends on its retry tick — over the NEW link, never the dead one.
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { action in
        if case let .delegate(.sendDirect(lid, data, _)) = action {
            #expect(lid == newLinkID); #expect(data == msg.packed); return true
        }
        return false
    }
    await store.send(.delivered(messageHash: msg.hash, leg: .delivery))
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
}

/// Closing a link that has an in-flight (pending) direct message re-establishes and retains the pending.
@Test @MainActor func routerLinkClosedWithPendingReestablishes() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let oldLinkID = Data(repeating: 0x01, count: 16)
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.directLinks[msg.destinationHash] = .active(linkID: oldLinkID)
    initial.knownPaths.insert(msg.destinationHash)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.sendDirect) = $0 { return true }; return false }
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)]?.attempts == 1)
    await store.send(.linkClosed(destinationHash: msg.destinationHash))
    await store.receive { action in
        if case let .delegate(.requestLink(dest)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    #expect(store.state.directLinks[msg.destinationHash] == .establishing)
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)] != nil)   // pending retained across the close
    await store.send(.delivered(messageHash: msg.hash, leg: .delivery))       // cancel the pending timer before teardown
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
}

/// If the link never returns, a pending direct delivery ticks (link down → no send) until the attempt
/// cap trips and it fails — bounded recovery.
@Test @MainActor func routerDirectDeliveryBoundedWhenLinkNeverReturns() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let oldLinkID = Data(repeating: 0x01, count: 16)
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.directLinks[msg.destinationHash] = .active(linkID: oldLinkID)
    initial.knownPaths.insert(msg.destinationHash)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.sendDirect) = $0 { return true }; return false }
    await store.send(.linkClosed(destinationHash: msg.destinationHash))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    // Link never re-establishes; each retry tick finds no active link (no send) but still counts.
    for _ in 0..<(LXMFDelivery.maxAttempts - 1) {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    }
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { action in
        if case let .delegate(.deliveryFailed(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)] == nil)
}

/// A finished establishment saga must not leave its budget behind to truncate the NEXT delivery.
///
/// The message retry saga (maxAttempts × retryWaitSeconds = 50s) can finish before the
/// establishment saga does, so the final `linkClosed` for a dead peer arrives with the pending
/// delivery already self-cleared — i.e. with NO work. That is the one exit from the saga that does
/// not run `giveUp`, so before this fix `establishAttempts` was stranded there permanently and the
/// next message to that peer inherited a spent budget.
///
/// NOTE ON THE DRIVE: this test sends five consecutive `linkClosed`s with the route still in
/// `knownPaths`, driving the MAXIMAL strand — exactly `maxAttempts`, the zero-attempt worst case.
/// The repeated-charge driver that makes this faithful is `.handshakeRejected`: it is the one
/// LinkFailure that keeps the route (the peer answered, so the path demonstrably works) and is
/// therefore forwarded by `LXMFNode` as a bare `linkClosed`, re-entering the charging branch of
/// `establish` each time.
///
/// It is deliberately NOT the `.noPath` / `.pathStale` hot spin this note used to cite — that
/// driver no longer exists at the composition. Path-shaped failures now arrive as
/// `.pathLostAndClosed`, which clears `knownPaths` first, so they take the free park branch and
/// cannot charge twice for one route. Driving them here would strand a budget of 1, not 5.
@Test @MainActor func routerStaleEstablishBudgetDoesNotTruncateTheNextMessage() async {
    let recipientHash = Identity().hash
    let msg = makeMessage(source: Identity(), recipientIdentityHash: recipientHash, content: "first")
    let msg2 = makeMessage(source: Identity(), recipientIdentityHash: recipientHash, content: "second")
    #expect(msg.destinationHash == msg2.destinationHash)
    let dest = msg.destinationHash
    let linkID = Data(repeating: 0x01, count: 16)
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.directLinks[dest] = .active(linkID: linkID)
    initial.knownPaths.insert(dest)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off

    // Send over the live link: arms the retry saga (pendingDeliveries.attempts == 1).
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.sendDirect) = $0 { return true }; return false }

    // The peer dies. Burn the establishment budget to the ceiling WITHOUT tripping it: each
    // linkClosed still sees the pending delivery, so each one re-establishes and counts.
    for expected in 1...LXMFDelivery.maxAttempts {
        await store.send(.linkClosed(destinationHash: dest))
        await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
        #expect(store.state.establishAttempts[dest] == expected)
    }

    // Now the retry saga completes first (the real-world 50s-before-75s ordering). Each tick finds
    // no active link so it only re-arms; the last one trips the cap and fails the message.
    for _ in 1...LXMFDelivery.maxAttempts {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    }
    await store.receive { action in
        if case let .delegate(.deliveryFailed(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
    #expect(store.state.pendingDeliveries.isEmpty)          // work is gone
    #expect(store.state.establishAttempts[dest] == LXMFDelivery.maxAttempts)   // budget fully spent

    // The final establishment failure arrives with nothing left to do. This is the no-work exit —
    // the saga is over, so the budget must end with it.
    await store.send(.linkClosed(destinationHash: dest))
    #expect(store.state.establishAttempts[dest] == nil)     // ← the fix
    #expect(store.state.knownPaths.contains(dest))          // path never falsified, still believed

    // A brand-new message to the same peer must get a REAL establishment attempt, not an instant
    // give-up inherited from the previous saga.
    await store.send(.send(message: msg2, desiredMethod: .direct))
    await store.receive { action in
        if case let .delegate(.requestLink(d)) = action { #expect(d == dest); return true }
        return false
    }
    #expect(store.state.establishAttempts[dest] == 1)       // a full fresh budget
    #expect(store.state.outboundQueue[dest]?.count == 1)    // queued, NOT failed
    #expect(store.state.knownPaths.contains(dest))

    // And no deliveryFailed rode along with that requestLink — absence, so flip-then-send.
    store.exhaustivity = .on
    await store.send(.offeredMessageList(transientIds: []))   // no-op send; forces the stray check
    store.exhaustivity = .off
}

// MARK: - Bound link-establishment saga

/// A queued direct message to a peer whose link never establishes gives up after maxAttempts
/// instead of re-establishing forever. Before this change the establish cycle
/// (linkClosed → hasQueued → establish → requestLink → openLink → linkFailed → linkClosed)
/// had no attempt counter at all — pendingDeliveries.attempts bounds only the retryDue timer
/// path, and a QUEUED message is never armed with a retry timer.
@Test @MainActor func routerQueuedDirectSendStopsEstablishingAfterMaxAttempts() async {
    let msg = makeMessage(source: Identity(), content: "queued-direct")
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(msg.destinationHash)   // path known → establish() goes to requestLink branch
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off

    // .send() with no active link → queues the message and calls establish() → first .requestLink.
    // establishAttempts[dest] is now 1.
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    #expect(store.state.establishAttempts[msg.destinationHash] == 1)

    // Drive linkClosed cycles. Each one hits establish() again and increments the counter.
    // After maxAttempts total the ceiling trips and deliveryFailed is emitted instead.
    for expected in 2...LXMFDelivery.maxAttempts {
        await store.send(.linkClosed(destinationHash: msg.destinationHash))
        await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
        #expect(store.state.establishAttempts[msg.destinationHash] == expected)
    }

    // One more linkClosed: attempts would be maxAttempts+1 > maxAttempts → give up.
    await store.send(.linkClosed(destinationHash: msg.destinationHash))
    await store.receive { action in
        if case let .delegate(.deliveryFailed(h)) = action { #expect(h == msg.hash); return true }
        return false
    }

    // After ceiling: queue cleared, path forgotten, counter cleared.
    #expect(store.state.outboundQueue[msg.destinationHash] == nil)
    #expect(store.state.knownPaths.contains(msg.destinationHash) == false)
    #expect(store.state.establishAttempts[msg.destinationHash] == nil)

    // And the cycle is genuinely over: a further linkClosed emits NOTHING. Under `.off` an
    // absence assertion is vacuous, so flip to `.on` — teardown then fails on a stray
    // requestLink/requestPath. Safe here: a queued send arms no timers, so nothing is in flight.
    store.exhaustivity = .on
    await store.send(.linkClosed(destinationHash: msg.destinationHash))
}

/// A successful establishment resets the counter — a peer that flaps and recovers gets a
/// full budget again rather than inheriting a nearly-exhausted one.
@Test @MainActor func routerEstablishAttemptsResetOnLinkEstablished() async {
    // Two messages to the SAME destination: deliveryHash is a pure function of the recipient
    // identity hash, so reusing it keeps both on one destination and one saga.
    let recipientHash = Identity().hash
    let msg = makeMessage(source: Identity(), recipientIdentityHash: recipientHash,
                          content: "queued-reset-link")
    let msg2 = makeMessage(source: Identity(), recipientIdentityHash: recipientHash,
                           content: "queued-reset-link-2")
    #expect(msg2.destinationHash == msg.destinationHash)
    let dest = msg.destinationHash
    let linkID = Data(repeating: 0xAB, count: 16)
    // Pre-seed the attempt counter to maxAttempts: WITHOUT a reset the next establish() would
    // immediately trip the ceiling. Everything after linkEstablished is reducer-driven.
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(dest)
    initial.outboundQueue[dest] = [msg]
    initial.directLinks[dest] = .establishing
    initial.establishAttempts[dest] = LXMFDelivery.maxAttempts
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    // Link establishes — must reset the counter.
    await store.send(.linkEstablished(destinationHash: dest, linkID: linkID))
    await store.receive { if case .delegate(.sendDirect) = $0 { return true }; return false }
    await store.send(.delivered(messageHash: msg.hash, leg: .delivery))
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    #expect(store.state.establishAttempts[dest] == nil)   // reset confirmed

    // The link later drops with nothing pending or queued → cleared, no re-establish.
    await store.send(.linkClosed(destinationHash: dest))
    #expect(store.state.directLinks[dest] == nil)

    // A second message to the same peer now queues and re-enters the establish cycle. Because
    // the counter was reset, the FULL budget is available: maxAttempts requestLinks, then give up.
    // Without the reset the counter would still sit at maxAttempts and this first call would fail.
    await store.send(.send(message: msg2, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    #expect(store.state.establishAttempts[dest] == 1)

    for expected in 2...LXMFDelivery.maxAttempts {
        await store.send(.linkClosed(destinationHash: dest))
        await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
        #expect(store.state.establishAttempts[dest] == expected)
    }
    await store.send(.linkClosed(destinationHash: dest))
    await store.receive { action in
        if case let .delegate(.deliveryFailed(h)) = action { #expect(h == msg2.hash); return true }
        return false
    }
    #expect(store.state.establishAttempts[dest] == nil)   // cleared on give-up
}

/// Learning a GENUINELY NEW path resets the counter: after a ceiling trip the path is forgotten,
/// so a later path learn is real new information and earns a full fresh budget. It also proves
/// the learnedPath emit is routed through establish() — the requestLink it fires is COUNTED
/// (attempts becomes 1), not an uncounted second emitter.
@Test @MainActor func routerEstablishAttemptsResetOnLearnedPath() async {
    let recipientHash = Identity().hash
    let msg = makeMessage(source: Identity(), recipientIdentityHash: recipientHash,
                          content: "queued-reset-path")
    let msg2 = makeMessage(source: Identity(), recipientIdentityHash: recipientHash,
                           content: "queued-reset-path-2")
    let dest = msg.destinationHash
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(dest)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    // Burn the whole budget to the ceiling. That clears knownPaths — the path belief is falsified.
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    for expected in 2...LXMFDelivery.maxAttempts {
        await store.send(.linkClosed(destinationHash: dest))
        await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
        #expect(store.state.establishAttempts[dest] == expected)
    }
    await store.send(.linkClosed(destinationHash: dest))
    await store.receive { action in
        if case let .delegate(.deliveryFailed(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
    #expect(store.state.knownPaths.contains(dest) == false)   // path forgotten by the ceiling
    #expect(store.state.establishAttempts[dest] == nil)

    // With no path, the next send asks for one and parks.
    await store.send(.send(message: msg2, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestPath) = $0 { return true }; return false }
    #expect(store.state.directLinks[dest] == .awaitingPath)

    // A genuinely new path arrives → budget reset AND the establishment is counted (== 1),
    // because learnedPath routes its emit through establish() rather than emitting inline.
    await store.send(.learnedPath(destinationHash: dest))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    #expect(store.state.directLinks[dest] == .establishing)
    #expect(store.state.establishAttempts[dest] == 1)

    // Full fresh budget: maxAttempts in total, then give up again.
    for expected in 2...LXMFDelivery.maxAttempts {
        await store.send(.linkClosed(destinationHash: dest))
        await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
        #expect(store.state.establishAttempts[dest] == expected)
    }
    await store.send(.linkClosed(destinationHash: dest))
    await store.receive { action in
        if case let .delegate(.deliveryFailed(h)) = action { #expect(h == msg2.hash); return true }
        return false
    }
    #expect(store.state.establishAttempts[dest] == nil)
}

/// After the ceiling fires — `knownPaths[dest]` is cleared — the NEXT `.send(.direct)` to that
/// destination must ask for a fresh path (`.requestPath`) rather than retrying a link to a peer
/// whose route has been empirically falsified. This is the recovery the reverted openLink
/// fast-fail slice was aiming at: a path request refreshes `learned` with the live interface
/// (Transport.swift:486-495 builds a FRESH announce), after which a link can be established
/// normally.
@Test @MainActor func routerRequestsPathOnTheNextSendAfterGivingUpOnLinks() async {
    let recipientHash = Identity().hash
    let msg = makeMessage(source: Identity(), recipientIdentityHash: recipientHash,
                          content: "give-up-then-recover")
    let msg2 = makeMessage(source: Identity(), recipientIdentityHash: recipientHash,
                           content: "next-send-after-give-up")
    #expect(msg.destinationHash == msg2.destinationHash)
    let dest = msg.destinationHash
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(dest)   // path known → establish() takes the requestLink branch
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    // Burn the whole establishment budget to the ceiling. That clears knownPaths — the path
    // belief is empirically falsified.
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    for _ in 2...LXMFDelivery.maxAttempts {
        await store.send(.linkClosed(destinationHash: dest))
        await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    }
    await store.send(.linkClosed(destinationHash: dest))
    await store.receive { action in
        if case let .delegate(.deliveryFailed(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
    // Ceiling confirmed: path is forgotten.
    #expect(store.state.knownPaths.contains(dest) == false)
    #expect(store.state.establishAttempts[dest] == nil)
    #expect(store.state.outboundQueue[dest] == nil)

    // The next send to the same destination must request a path, NOT a link.
    await store.send(.send(message: msg2, desiredMethod: .direct))
    await store.receive { action in
        if case let .delegate(.requestPath(d)) = action { #expect(d == dest); return true }
        return false
    }
    #expect(store.state.directLinks[dest] == .awaitingPath)
    #expect(store.state.outboundQueue[dest]?.count == 1)
    // "requestPath, NOT requestLink" is half positive (asserted above) and half absence. Enforce
    // the absence half with flip-then-send; a trailing `.on` would also catch a stray but would
    // additionally trip on the now-armed park timer for an unrelated reason.
    store.exhaustivity = .on
    await store.send(.offeredMessageList(transientIds: []))   // no-op send; forces the stray check
    store.exhaustivity = .off
}

/// A re-announce of an ALREADY-KNOWN path is not new information and must NOT refresh the budget.
/// `Transport.shouldReplace` accepts any fresher announce, so a live peer re-announcing on its
/// normal period reaches `.learnedPath` repeatedly; resetting on those would let it refresh the
/// budget forever and re-open the unbounded establish cycle this bound exists to close.
@Test @MainActor func routerRepeatedPathAnnounceDoesNotResetEstablishAttempts() async {
    let msg = makeMessage(source: Identity(), content: "known-path-reannounce")
    let dest = msg.destinationHash
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(dest)   // path ALREADY known → a later learnedPath is a re-announce
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    // Burn to one attempt short of the ceiling.
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    for expected in 2...(LXMFDelivery.maxAttempts - 1) {
        await store.send(.linkClosed(destinationHash: dest))
        await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
        #expect(store.state.establishAttempts[dest] == expected)
    }
    #expect(store.state.establishAttempts[dest] == LXMFDelivery.maxAttempts - 1)

    // The peer re-announces the path we already know. Nothing new → counter untouched.
    await store.send(.learnedPath(destinationHash: dest))
    #expect(store.state.establishAttempts[dest] == LXMFDelivery.maxAttempts - 1)

    // So the budget continues where it left off: one more attempt, then give up.
    await store.send(.linkClosed(destinationHash: dest))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    #expect(store.state.establishAttempts[dest] == LXMFDelivery.maxAttempts)
    await store.send(.linkClosed(destinationHash: dest))
    await store.receive { action in
        if case let .delegate(.deliveryFailed(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
    #expect(store.state.establishAttempts[dest] == nil)
}

/// Closing a link with nothing pending/queued clears it and does NOT re-establish.
@Test @MainActor func routerLinkClosedWithNothingPendingClears() async {
    let dest = LXMessage.deliveryHash(identityHash: Identity().hash)
    var initial = LXMFRouter.State()
    initial.directLinks[dest] = .active(linkID: Data(repeating: 0x07, count: 16))
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.linkClosed(destinationHash: dest))
    #expect(store.state.directLinks[dest] == nil)   // cleared, no re-establish
    store.exhaustivity = .on   // a stray requestLink/requestPath would fail teardown
}

// MARK: - LXMF-4c-3b idle-link teardown

@Test @MainActor func routerTearsDownIdleLink() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let linkID = Data(repeating: 0x33, count: 16)
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(msg.destinationHash)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    await store.send(.linkEstablished(destinationHash: msg.destinationHash, linkID: linkID))
    await store.receive { if case .delegate(.sendDirect) = $0 { return true }; return false }   // drain arms idle timer
    await store.send(.delivered(messageHash: msg.hash, leg: .delivery))   // clear pending + its retry timer; idle timer remains
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    #expect(store.state.directLinks[msg.destinationHash] == .active(linkID: linkID))
    // No further activity for the inactivity window → the link is torn down.
    await clock.advance(by: .seconds(LXMFDelivery.linkMaxInactivitySeconds))
    await store.receive { action in
        if case let .delegate(.closeLink(dest)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    #expect(store.state.directLinks[msg.destinationHash] == nil)
}

/// New activity on an active link restarts the idle timer, so teardown is deferred to the last send.
@Test @MainActor func routerActivityRestartsIdleTimer() async {
    let sender = Identity()
    let recipient = Identity().hash
    let msg = makeMessage(source: sender, recipientIdentityHash: recipient, content: "one")
    let msg2 = makeMessage(source: sender, recipientIdentityHash: recipient, content: "two")
    #expect(msg.destinationHash == msg2.destinationHash)   // same recipient delivery destination
    let linkID = Data(repeating: 0x44, count: 16)
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.directLinks[msg.destinationHash] = .active(linkID: linkID)
    initial.knownPaths.insert(msg.destinationHash)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    // First send arms the idle timer.
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.sendDirect) = $0 { return true }; return false }
    await store.send(.delivered(messageHash: msg.hash, leg: .delivery))
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    // Almost to the deadline — not torn down yet.
    await clock.advance(by: .seconds(LXMFDelivery.linkMaxInactivitySeconds - 1))
    #expect(store.state.directLinks[msg.destinationHash] == .active(linkID: linkID))
    // A second send restarts the idle timer.
    await store.send(.send(message: msg2, desiredMethod: .direct))
    await store.receive { if case .delegate(.sendDirect) = $0 { return true }; return false }
    await store.send(.delivered(messageHash: msg2.hash, leg: .delivery))
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    // Past the ORIGINAL deadline but before the restarted one → still active (proves the restart).
    await clock.advance(by: .seconds(LXMFDelivery.linkMaxInactivitySeconds - 1))
    #expect(store.state.directLinks[msg.destinationHash] == .active(linkID: linkID))
    // The remainder of the restarted window elapses → torn down.
    await clock.advance(by: .seconds(1))
    await store.receive { action in
        if case let .delegate(.closeLink(dest)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    #expect(store.state.directLinks[msg.destinationHash] == nil)
}

/// Idle teardown of a link with an in-flight Resource must reap the linkResourceInFlight entry (F7).
@Test @MainActor func idleTeardownReapsLinkResourceInFlight() async {
    // A Resource-sized message (directRepresentation == .resource) sets linkResourceInFlight on send.
    // When the idle timer tears the link down, that entry must be reaped — not leaked (F7).
    let bigMsg = makeMessage(source: Identity(), content: String(repeating: "y", count: 2000))
    #expect(bigMsg.directRepresentation == .resource)
    let linkID = Data(repeating: 0x37, count: 16)
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(bigMsg.destinationHash)     // path known → establishes directly
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.send(message: bigMsg, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    await store.send(.linkEstablished(destinationHash: bigMsg.destinationHash, linkID: linkID))
    await store.receive { action in                        // drain arms the idle timer; sets in-flight
        if case let .delegate(.sendDirect(lid, _, asResource)) = action {
            #expect(lid == linkID); #expect(asResource == true); return true
        }
        return false
    }
    #expect(store.state.linkResourceInFlight[linkID] == LXMFRouter.DeliveryKey.delivery(bigMsg.hash))

    // A Resource copy arms no retry timer, so nothing needs resolving first: the in-flight entry and
    // the idle timer are all that is running.
    #expect(store.state.pendingDeliveries[.delivery(bigMsg.hash)]?.phase == .transferring)
    #expect(store.state.directLinks[bigMsg.destinationHash] == .active(linkID: linkID))

    // Idle window elapses → the link is torn down. The in-flight entry MUST be reaped.
    await clock.advance(by: .seconds(LXMFDelivery.linkMaxInactivitySeconds))
    await store.receive { action in
        if case let .delegate(.closeLink(dest)) = action { #expect(dest == bigMsg.destinationHash); return true }
        return false
    }
    #expect(store.state.linkResourceInFlight[linkID] == nil,
            "idle teardown must reap the in-flight Resource entry — F7 leak")
    #expect(store.state.directLinks[bigMsg.destinationHash] == nil)
    #expect(store.state.pendingDeliveries[.delivery(bigMsg.hash)]?.phase == .retrying,
            "the transfer died with the link, so the copy goes back to retrying")
}

// MARK: - LXMF-4d-2b PROPAGATED outbound

@Test @MainActor func routerPropagationFailsWithNoNode() async {
    let msg = makeMessage(source: Identity(), content: "prop")
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.sendViaPropagation(message: msg, propagationPacked: Data("container".utf8)))
    await store.receive { action in
        if case let .delegate(.deliveryFailed(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
}

@Test @MainActor func routerPropagationEstablishesLinkToNode() async {
    let msg = makeMessage(source: Identity(), content: "prop")
    let packed = Data("container".utf8)
    let pn = Data(repeating: 0xBB, count: 16)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.knownPaths.insert(pn)   // path known → establishes directly
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.sendViaPropagation(message: msg, propagationPacked: packed))
    await store.receive { action in
        if case let .delegate(.requestLink(d)) = action { #expect(d == pn); return true }
        return false
    }
    #expect(store.state.directLinks[pn] == .establishing)
    #expect(store.state.propagationQueue[pn]?.count == 1)
    store.exhaustivity = .on   // no sendPropagated yet (no active link); no timer armed → a stray fails teardown
}

@Test @MainActor func routerPropagationDrainsOnLinkEstablished() async {
    let msg = makeMessage(source: Identity(), content: "prop")
    // Use a large container (> Link.mdu = 431 bytes) so this test stays on the Resource path.
    let packed = Data(repeating: 0xAA, count: 432)
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.knownPaths.insert(pn)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.sendViaPropagation(message: msg, propagationPacked: packed))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    await store.send(.linkEstablished(destinationHash: pn, linkID: linkID))
    await store.receive { action in
        if case let .delegate(.sendPropagated(lid, p)) = action {
            #expect(lid == linkID); #expect(p == packed); return true
        }
        return false
    }
    #expect(store.state.pendingDeliveries[.propagated(msg.hash)]?.attempts == 1)
}

@Test @MainActor func routerPropagationSendsImmediatelyWithActiveLink() async {
    let msg = makeMessage(source: Identity(), content: "prop")
    // Use a large container (> Link.mdu = 431 bytes) so this test stays on the Resource path.
    let packed = Data(repeating: 0xAA, count: 432)
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.directLinks[pn] = .active(linkID: linkID)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.sendViaPropagation(message: msg, propagationPacked: packed))
    await store.receive { action in
        if case let .delegate(.sendPropagated(lid, p)) = action {
            #expect(lid == linkID); #expect(p == packed); return true
        }
        return false
    }
    #expect(store.state.pendingDeliveries[.propagated(msg.hash)]?.attempts == 1)
}

// MARK: - Task-2: propagation small-packet + genuine propagationAccepted

/// With an active PN link, a small propagation container (<= Link.mdu = 431 bytes) is sent as a
/// proof-requesting link packet (sendPropagatedPacket), and a matching packetDelivered via
/// .delivered(messageHash:leg: .propagated) resolves to propagationAccepted for that message.hash.
@Test @MainActor func propagationSmallSendsPacketAndAcceptsOnProof() async {
    let msg = makeMessage(source: Identity(), content: "small prop")
    // Small container: <= 431 bytes (Link.mdu) → should take the packet route.
    let smallPacked = Data("small-container".utf8)
    #expect(smallPacked.count <= 431)
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.directLinks[pn] = .active(linkID: linkID)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    // Small container → sendPropagatedPacket delegate (token = message.hash), NOT sendPropagated.
    await store.send(.sendViaPropagation(message: msg, propagationPacked: smallPacked))
    await store.receive { action in
        if case let .delegate(.sendPropagatedPacket(lid, packed, token)) = action {
            #expect(lid == linkID)
            #expect(packed == smallPacked)
            #expect(token == msg.hash)   // token correlates the proof to this message
            return true
        }
        return false
    }
    #expect(store.state.pendingDeliveries[.propagated(msg.hash)]?.attempts == 1)
    // linkResourceInFlight is NOT set for the packet route (no Resource in flight).
    #expect(store.state.linkResourceInFlight[linkID] == nil)

    // packetDelivered (token = message.hash) → .delivered(messageHash:) → propagationAccepted.
    // (In production, LXMFNode maps TCPEndpoint.delegate(.packetDelivered(token)) → router(.delivered(messageHash: token, leg: .propagated)).)
    await store.send(.delivered(messageHash: msg.hash, leg: .propagated))
    await store.receive { action in
        if case let .delegate(.propagationAccepted(hash)) = action {
            #expect(hash == msg.hash)
            return true
        }
        return false
    }
    #expect(store.state.pendingDeliveries[.propagated(msg.hash)] == nil)   // pending cleared
}

// MARK: - LXMF-4d-4 client inbound sync

@Test @MainActor func routerSyncActiveLinkRequestsDownload() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.directLinks[pn] = .active(linkID: linkID)
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.syncFromPropagationNode)
    await store.receive { action in
        if case let .delegate(.requestMessageList(lid)) = action { #expect(lid == linkID); return true }
        return false
    }
    #expect(store.state.pendingDownloadFromPN == false)
}

@Test @MainActor func routerSyncNoNodeIsNoOp() async {
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.syncFromPropagationNode)
    #expect(store.state.pendingDownloadFromPN == false)
    store.exhaustivity = .on   // no PN → no requestLink / requestMessageList; a stray fails teardown
}

@Test @MainActor func routerSyncEstablishesThenRequestsOnLinkEstablished() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.knownPaths.insert(pn)   // path known → establishes directly
    // F5.2: always-arm means .linkEstablished now arms an idle timer; TestClock is required so the
    // clock.sleep in idleTimer doesn't hit the unimplemented system continuousClock.
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.syncFromPropagationNode)
    await store.receive { action in
        if case let .delegate(.requestLink(d)) = action { #expect(d == pn); return true }
        return false
    }
    #expect(store.state.pendingDownloadFromPN == true)
    await store.send(.linkEstablished(destinationHash: pn, linkID: linkID))
    await store.receive { action in
        if case let .delegate(.requestMessageList(lid)) = action { #expect(lid == linkID); return true }
        return false
    }
    #expect(store.state.pendingDownloadFromPN == false)
}

@Test @MainActor func routerSyncFlagClearedNoDoubleRequest() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.knownPaths.insert(pn)
    // F5.2: always-arm means .linkEstablished now arms an idle timer; TestClock is required so the
    // clock.sleep in idleTimer doesn't hit the unimplemented system continuousClock.
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.syncFromPropagationNode)
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    await store.send(.linkEstablished(destinationHash: pn, linkID: linkID))
    await store.receive { if case .delegate(.requestMessageList) = $0 { return true }; return false }
    // A second establish (e.g. link re-open) must NOT re-request the download — the flag was cleared.
    await store.send(.linkEstablished(destinationHash: pn, linkID: linkID))
    #expect(store.state.pendingDownloadFromPN == false)
    // The `#expect` above only catches a resurrection that ALSO sets the flag; a `requestMessageList`
    // decoupled from the flag would slip past it. Assert its ABSENCE with a flip-then-send AFTER the
    // second establish: flip .on, send a genuine no-op (empty offer → router returns .none) so TCA
    // runs the "must handle received actions" check and fails on any stray requestMessageList queued
    // by that establish, then flip back to .off so teardown tolerates the F5.2 idle timer.
    store.exhaustivity = .on
    await store.send(.offeredMessageList(transientIds: []))   // no-op; forces the stray check
    store.exhaustivity = .off
}

/// A sync whose PN link dies before it establishes must retry. An outstanding
/// `pendingDownloadFromPN` is work in its own right: a bare `syncFromPropagationNode` queues no
/// message and arms no retry timer, so if `linkClosed` does not re-establish for it, the sync is
/// silently abandoned — the link un-wedges but nothing ever asks the PN for messages again.
@Test @MainActor func routerSyncReEstablishesWhenPNLinkClosesWithNothingQueued() async {
    let pn = Data(repeating: 0xBB, count: 16)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.knownPaths.insert(pn)
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off

    // Drive to the precondition rather than seeding it: a sync request with no message send.
    await store.send(.syncFromPropagationNode)
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    #expect(store.state.pendingDownloadFromPN == true)
    // The gap this covers: nothing is pending or queued for the PN, so the old
    // `hasPending || hasQueued` condition was false and linkClosed returned .none.
    #expect(store.state.pendingDeliveries.isEmpty)
    #expect(store.state.outboundQueue[pn] == nil)
    #expect(store.state.propagationQueue[pn] == nil)

    // The PN never answers; the establishment timeout arrives here as linkClosed for the PN hash.
    await store.send(.linkClosed(destinationHash: pn))
    await store.receive { action in
        if case let .delegate(.requestLink(d)) = action { #expect(d == pn); return true }
        return false
    }
    // The flag must survive so the sync actually happens once a link is finally established.
    #expect(store.state.pendingDownloadFromPN == true)
    #expect(store.state.directLinks[pn] == .establishing)
}

/// A sync that exhausts the establishment budget must be explicitly TERMINATED, not left pending.
/// `pendingDownloadFromPN` is otherwise cleared only when `.linkEstablished` drains it, so without a
/// clear in the give-up branch an abandoned sync stays "outstanding" forever: every later
/// `linkClosed(pn)` re-enters establish, and an unrelated future PN link (e.g. from a propagated
/// send) resurrects it with a surprise `requestMessageList`.
@Test @MainActor func routerSyncExhaustingBudgetClearsPendingDownloadFlag() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.knownPaths.insert(pn)
    // F5.2: always-arm means .linkEstablished now arms an idle timer; TestClock is required so the
    // clock.sleep in idleTimer doesn't hit the unimplemented system continuousClock.
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    // Drive to the precondition rather than seeding it: a sync with nothing queued (attempt 1).
    await store.send(.syncFromPropagationNode)
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    #expect(store.state.pendingDownloadFromPN == true)

    // Burn the rest of the budget: each close re-establishes (attempts 2...maxAttempts).
    for _ in 2...LXMFDelivery.maxAttempts {
        await store.send(.linkClosed(destinationHash: pn))
        await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
        #expect(store.state.pendingDownloadFromPN == true)   // still outstanding while retrying
    }

    // One more close pushes establish() past the ceiling → give up.
    await store.send(.linkClosed(destinationHash: pn))
    #expect(store.state.pendingDownloadFromPN == false)      // the sync has a terminus
    #expect(store.state.knownPaths.contains(pn) == false)    // and the path is forgotten

    // A later PN link must NOT resurrect the abandoned sync. Run the resurrection trigger first
    // (still .off), then assert the absence of a stray requestMessageList with a flip-then-send
    // AFTER it: the no-op send under .on forces TCA's "must handle received actions" check and fails
    // on any requestMessageList that establish queued (whether or not it also touched the flag).
    // The block must come AFTER .linkEstablished — placing it before would leave the trigger
    // unguarded. Flip back to .off so teardown tolerates the F5.2 idle timer that establish armed.
    await store.send(.linkEstablished(destinationHash: pn, linkID: linkID))
    #expect(store.state.directLinks[pn] == .active(linkID: linkID))
    #expect(store.state.pendingDownloadFromPN == false)   // not resurrected
    store.exhaustivity = .on
    await store.send(.offeredMessageList(transientIds: []))   // no-op; forces the stray check
    store.exhaustivity = .off
}

// MARK: - Resource-direct delivery confirmation

/// Resource-direct confirmation: a resource-sized message sent over an active link records its hash in
/// linkResourceInFlight; resourceDeliveredOnLink(linkID) resolves it to deliveryConfirmed and clears both
/// the pending delivery and the in-flight entry. (This is what stops the direct retry-storm on success.)
@Test @MainActor func routerConfirmsResourceDirectOnResourceDelivered() async {
    let bigMsg = makeMessage(source: Identity(), content: String(repeating: "y", count: 2000))
    #expect(bigMsg.directRepresentation == .resource)
    let linkID = Data(repeating: 0xEF, count: 16)
    var initial = LXMFRouter.State()
    initial.directLinks[bigMsg.destinationHash] = .active(linkID: linkID)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    await store.send(.send(message: bigMsg, desiredMethod: .direct))
    await store.receive { action in
        if case let .delegate(.sendDirect(lid, _, asResource)) = action {
            #expect(lid == linkID); #expect(asResource == true); return true
        }
        return false
    }
    #expect(store.state.linkResourceInFlight[linkID] == LXMFRouter.DeliveryKey.delivery(bigMsg.hash))     // recorded on send
    #expect(store.state.pendingDeliveries[.delivery(bigMsg.hash)] != nil)           // awaiting outcome

    await store.send(.resourceDeliveredOnLink(linkID: linkID))
    await store.receive { action in
        if case let .delegate(.deliveryConfirmed(hash)) = action { #expect(hash == bigMsg.hash); return true }
        return false
    }
    #expect(store.state.pendingDeliveries[.delivery(bigMsg.hash)] == nil)           // resolved → retry can't resend
    #expect(store.state.linkResourceInFlight[linkID] == nil)            // in-flight entry cleared
}

// MARK: - Propagation download two-phase offer/get (P2a)

/// Phase-2: an offered list with nothing yet downloaded → request all of them as `wants`, no `haves`.
@Test @MainActor func routerOfferedListRequestsAllWantsWhenNoneHeld() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    let id1 = Data(repeating: 0x11, count: 32); let id2 = Data(repeating: 0x22, count: 32)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.directLinks[pn] = .active(linkID: linkID)
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.offeredMessageList(transientIds: [id1, id2]))
    await store.receive { action in
        if case let .delegate(.requestMessages(lid, wants, haves)) = action {
            #expect(lid == linkID); #expect(wants == [id1, id2]); #expect(haves == []); return true
        }
        return false
    }
}

/// Phase-2 with a have-set: a previously downloaded id moves from `wants` to `haves` (for PN purge).
@Test @MainActor func routerOfferedListSplitsWantsAndHaves() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    let id1 = Data(repeating: 0x11, count: 32); let id2 = Data(repeating: 0x22, count: 32)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.directLinks[pn] = .active(linkID: linkID)
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.messagesDownloaded(transientIds: [id1]))
    #expect(store.state.downloadedTransientIds.contains(id1))
    await store.send(.offeredMessageList(transientIds: [id1, id2]))
    await store.receive { action in
        if case let .delegate(.requestMessages(_, wants, haves)) = action {
            #expect(wants == [id2]); #expect(haves == [id1]); return true
        }
        return false
    }
}

/// An empty offer → sync done, no phase-2 request.
@Test @MainActor func routerEmptyOfferedListRequestsNothing() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.directLinks[pn] = .active(linkID: linkID)
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.offeredMessageList(transientIds: []))
    store.exhaustivity = .on   // a stray requestMessages would fail teardown
}

/// No active PN link (offer arrived after the link dropped) → abort, no phase-2 request.
@Test @MainActor func routerOfferedListWithoutActiveLinkAborts() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let id1 = Data(repeating: 0x11, count: 32)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn                 // configured, but no active link
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.offeredMessageList(transientIds: [id1]))
    store.exhaustivity = .on   // a stray requestMessages would fail teardown
}

// MARK: - Propagation-accept confirmation (P3c)

/// Propagation-accept via Resource: a LARGE propagation container (> Link.mdu) over an active PN link
/// records linkResourceInFlight; when the PN concludes the resource, resourceDeliveredOnLink resolves it
/// to propagationAccepted (NOT deliveryConfirmed) and clears the pending delivery.
@Test @MainActor func routerConfirmsPropagationAcceptOnResourceDelivered() async {
    let msg = makeMessage(source: Identity(), content: "via pn")
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.directLinks[pn] = .active(linkID: linkID)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    // Large container (> 431 bytes) → Resource path, linkResourceInFlight is recorded.
    let largePacked = Data(repeating: 0xAA, count: 432)
    await store.send(.sendViaPropagation(message: msg, propagationPacked: largePacked))
    await store.receive { action in
        if case let .delegate(.sendPropagated(lid, _)) = action { #expect(lid == linkID); return true }
        return false
    }
    #expect(store.state.linkResourceInFlight[linkID] == LXMFRouter.DeliveryKey.propagated(msg.hash))      // recorded on propagation send
    #expect(store.state.pendingDeliveries[.propagated(msg.hash)] != nil)

    await store.send(.resourceDeliveredOnLink(linkID: linkID))
    await store.receive { action in
        if case let .delegate(.propagationAccepted(hash)) = action { #expect(hash == msg.hash); return true }
        return false
    }
    #expect(store.state.pendingDeliveries[.propagated(msg.hash)] == nil)           // resolved → retry cancelled
    #expect(store.state.linkResourceInFlight[linkID] == nil)
}

// MARK: - Dedup rehydration (Task 1: LXMFRouter dedup survives restart)

/// A hash rehydrated via `.rehydrateDedup` is treated as already-seen: when a message with that hash
/// arrives it is DROPPED as a duplicate (delegating `.duplicateDropped`), not delivered again.
/// Vacuity check: would this assertion fail if rehydration did nothing? YES — without rehydration
/// the message would be delivered and we would receive `.messageDelivered`, not `.duplicateDropped`.
@Test @MainActor func routerRehydratedHashDropsAsDuplicate() async {
    let sender = Identity()
    let msg = makeMessage(source: sender)
    // Rehydrate: supply msg.hash as a previously-seen delivery. The hash is the raw 32-byte ID
    // as stored by the app, not a pre-digested form — rehydration inserts through the same RingSet
    // path as a live receive.
    var initial = LXMFRouter.State()
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.rehydrateDedup(seenHashes: [msg.hash], downloadedTransientIds: []))
    // Now "receive" the same message. It should be dropped as a duplicate, not delivered.
    await store.send(.received(method: .opportunistic, destinationHash: msg.destinationHash,
                               data: msg.opportunisticPayload))
    await store.receive { action in
        if case let .delegate(.duplicateDropped(h)) = action {
            #expect(h == msg.hash)
            return true
        }
        return false
    }
    // Sanity: a different message through the same store IS delivered (the ring is not universally full).
    let other = makeMessage(source: sender, content: "other message")
    await store.send(.received(method: .opportunistic, destinationHash: other.destinationHash,
                               data: other.opportunisticPayload))
    await store.receive { if case .delegate(.messageDelivered) = $0 { return true }; return false }
}

/// A transient ID rehydrated via `.rehydrateDedup` appears in the `haves` set on the next PN offer,
/// NOT in `wants` — so the PN is told to purge it rather than the client re-downloading it.
/// Vacuity check: would this assertion fail if rehydration did nothing? YES — without rehydration
/// `downloadedTransientIds` stays empty and the ID would appear in `wants`, not `haves`.
@Test @MainActor func routerRehydratedTransientIdIsNotRerequested() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let linkID = Data(repeating: 0xC0, count: 16)
    let alreadyHeld = Data(repeating: 0x44, count: 32)
    let newId = Data(repeating: 0x55, count: 32)
    var initial = LXMFRouter.State()
    initial.outboundPropagationNode = pn
    initial.directLinks[pn] = .active(linkID: linkID)
    let store = TestStore(initialState: initial) { LXMFRouter() }
    store.exhaustivity = .off
    // Rehydrate: alreadyHeld was downloaded in a previous session.
    await store.send(.rehydrateDedup(seenHashes: [], downloadedTransientIds: [alreadyHeld]))
    // PN offers alreadyHeld + a new ID.
    await store.send(.offeredMessageList(transientIds: [alreadyHeld, newId]))
    await store.receive { action in
        if case let .delegate(.requestMessages(lid, wants, haves)) = action {
            #expect(lid == linkID)
            // alreadyHeld must appear in haves (tell PN to purge), not wants (re-download).
            #expect(haves == [alreadyHeld], "rehydrated ID must be in haves, not wants")
            #expect(wants == [newId], "only genuinely new IDs should be wanted")
            return true
        }
        return false
    }
}

// MARK: - F5.2 idle-timer stale-teardown fix

// F5.2 (stamp): a stale idle deadline carrying an OLD linkID must not close the link that has since
// re-established on the same destination with a NEW linkID.
@Test @MainActor func staleIdleDeadlineDoesNotCloseANewerLink() async {
    let dest = Data(repeating: 0x51, count: 16)
    let oldLinkID = Data(repeating: 0xA1, count: 16)
    let newLinkID = Data(repeating: 0xB2, count: 16)
    var initial = LXMFRouter.State()
    initial.directLinks[dest] = .active(linkID: newLinkID)
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.idleDeadline(destinationHash: dest, linkID: oldLinkID))
    #expect(store.state.directLinks[dest] == .active(linkID: newLinkID),
            "a stale idle deadline (old linkID) must not close the current link")
}

// F5.2 (always-arm): a link established with NOTHING queued (the retry / PN-sync re-establish shape)
// must still get its own idle timer, so it idle-closes instead of lingering forever.
@Test @MainActor func linkEstablishedWithEmptyQueueStillArmsAnIdleTimer() async {
    let dest = Data(repeating: 0x52, count: 16)
    let linkID = Data(repeating: 0xC3, count: 16)
    let clock = TestClock()
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.linkEstablished(destinationHash: dest, linkID: linkID))
    #expect(store.state.directLinks[dest] == .active(linkID: linkID))
    await clock.advance(by: .seconds(LXMFDelivery.linkMaxInactivitySeconds))
    await store.receive { action in
        if case let .delegate(.closeLink(d)) = action { #expect(d == dest); return true }
        return false
    }
    #expect(store.state.directLinks[dest] == nil,
            "an empty-queue re-established link must still idle-close on its own timer")
}

/// Rehydrating MORE than RingSet's capacity (10 000) keeps the NEWEST hashes and evicts the oldest,
/// matching the live insert order. The newest hash must be seen (duplicate suppressed); the oldest
/// hash must be gone (treated as new and delivered).
///
/// Caller contract: supply hashes oldest-first (ascending storedAt, matching ORDER BY in the app's
/// query), so that eviction during rehydration is deterministic across launches.
///
/// Vacuity check for the eviction assertion: if rehydration kept all hashes (no eviction), the old
/// hash would also be suppressed, and the delivery assertion would fail.
/// Vacuity check for the newest-kept assertion: if rehydration did nothing, the newest hash would
/// NOT be suppressed, and the duplicateDropped assertion would fail.
@Test @MainActor func routerRehydratingOverCapacityKeepsNewestEvictsOldest() async {
    let capacity = 10_000
    // The two boundary hashes have to belong to REAL messages, because the only way to observe
    // whether a hash is in `seen` is to receive that message and watch for duplicateDropped vs
    // messageDelivered — `seen` is not public. So the batch is built around two real messages with
    // synthetic fillers between them, rather than from synthetic hashes alone.
    let sender = Identity()
    let newestMsg = makeMessage(source: sender, content: "newest")
    let oldestMsg = makeMessage(source: sender, content: "oldest")

    // Over-capacity batch: oldestMsg.hash first, then capacity-1 fillers, then newestMsg.hash last.
    var batch: [Data] = [oldestMsg.hash]
    batch += (0..<(capacity - 1)).map { i in
        var d = Data(count: 32)
        d[0] = 0xFF; d[1] = UInt8((i >> 16) & 0xFF); d[2] = UInt8((i >> 8) & 0xFF); d[3] = UInt8(i & 0xFF)
        return d
    }
    batch.append(newestMsg.hash)
    #expect(batch.count == capacity + 1)

    let store2 = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store2.exhaustivity = .off
    await store2.send(.rehydrateDedup(seenHashes: batch, downloadedTransientIds: []))

    // newestMsg.hash was at the tail — it survives eviction — receiving it must drop as duplicate.
    await store2.send(.received(method: .opportunistic, destinationHash: newestMsg.destinationHash,
                                data: newestMsg.opportunisticPayload))
    await store2.receive { action in
        if case let .delegate(.duplicateDropped(h)) = action {
            #expect(h == newestMsg.hash, "newest hash must survive the over-capacity rehydration")
            return true
        }
        return false
    }

    // oldestMsg.hash was at the head — it was evicted — receiving it must deliver as new.
    await store2.send(.received(method: .opportunistic, destinationHash: oldestMsg.destinationHash,
                                data: oldestMsg.opportunisticPayload))
    await store2.receive { action in
        if case .delegate(.messageDelivered) = action {
            return true
        }
        return false
    }
}
