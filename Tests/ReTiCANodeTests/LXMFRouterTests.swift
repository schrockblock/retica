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
        if case let .delegate(.messageDelivered(m, validated)) = action {
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
    await store.send(.received(method: .direct, destinationHash: Data(), data: msg.packed))
    await store.receive { action in
        if case let .delegate(.messageDelivered(m, validated)) = action {
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
    await store.send(.received(method: .direct, destinationHash: Data(), data: msg.packed))
    await store.receive { action in
        if case let .delegate(.messageDelivered(m, validated)) = action {
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
    await store.send(.received(method: .direct, destinationHash: Data(), data: msg.packed))
    await store.receive { if case .delegate(.messageDelivered) = $0 { return true }; return false }
    await store.send(.received(method: .direct, destinationHash: Data(), data: msg.packed))   // dup
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
        if case let .delegate(.messageDelivered(m, _)) = action { #expect(m.hash == msg.hash); return true }
        return false
    }
    await store.send(.received(method: .direct, destinationHash: Data(), data: msg.packed))   // same msg, other path
    await store.receive { action in
        if case let .delegate(.duplicateDropped(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
}

/// A tampered payload (byte flipped in the content region) still parses but fails signature validation
/// against the known sender identity → delivered with signatureValidated == false.
@Test @MainActor func routerDeliversTamperedMessageUnvalidated() async {
    let sender = Identity()
    let msg = makeMessage(source: sender, content: "hello world")
    var bytes = Array(msg.packed)
    bytes[bytes.count - 2] ^= 0x01     // flip last content byte (before the trailing empty-map 0x80)
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.learnedIdentity(destinationHash: msg.sourceHash, identity: sender))
    await store.send(.received(method: .direct, destinationHash: Data(), data: Data(bytes)))
    await store.receive { action in
        if case let .delegate(.messageDelivered(_, validated)) = action { #expect(validated == false); return true }
        return false
    }
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
        if case let .delegate(.sendOpportunistic(dest, payload)) = action {
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
    await store.send(.received(method: .direct, destinationHash: Data(), data: before.packed))
    await store.receive { action in
        if case let .delegate(.messageDelivered(_, v)) = action { #expect(v == false); return true }; return false
    }
    // Both messages are from `sender`, so before.sourceHash == after.sourceHash.
    await store.send(.learnedIdentity(destinationHash: after.sourceHash, identity: sender))
    await store.send(.received(method: .direct, destinationHash: Data(), data: after.packed))
    await store.receive { action in
        if case let .delegate(.messageDelivered(_, v)) = action { #expect(v == true); return true }; return false
    }
}

// MARK: - LXMF-4c-2 path request on no-path

@Test @MainActor func routerDirectWithNoPathRequestsPath() async {
    let msg = makeMessage(source: Identity(), content: "direct")
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))   // no known path
    await store.receive { action in
        if case let .delegate(.requestPath(dest)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    #expect(store.state.directLinks[msg.destinationHash] == .awaitingPath)
    #expect(store.state.outboundQueue[msg.destinationHash]?.count == 1)   // message parked
    store.exhaustivity = .on   // a stray requestLink would fail teardown
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
/// emit a second requestPath. (Removing the `directLinks[dest] == nil` guard would fire a second
/// requestPath — an un-received delegate caught by the exhaustive teardown.)
@Test @MainActor func routerRequestsPathOnceWhileAwaitingPath() async {
    let sender = Identity()
    let recipient = Identity().hash
    let m1 = makeMessage(source: sender, recipientIdentityHash: recipient, content: "one")
    let m2 = makeMessage(source: sender, recipientIdentityHash: recipient, content: "two")
    #expect(m1.destinationHash == m2.destinationHash)   // same recipient delivery destination
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.send(message: m1, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestPath) = $0 { return true }; return false }
    #expect(store.state.directLinks[m1.destinationHash] == .awaitingPath)
    await store.send(.send(message: m2, desiredMethod: .direct))   // still awaitingPath → enqueue only
    #expect(store.state.outboundQueue[m1.destinationHash]?.count == 2)   // both queued
    store.exhaustivity = .on   // a stray second requestPath would fail teardown
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
    #expect(store.state.pendingDeliveries[msg.hash]?.attempts == 1)
    await store.send(.delivered(messageHash: msg.hash))   // clean up the pending timer before teardown
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
    await store.send(.delivered(messageHash: msg.hash))
    await store.receive { action in
        if case let .delegate(.deliveryConfirmed(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
    #expect(store.state.pendingDeliveries[msg.hash] == nil)
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
    #expect(store.state.pendingDeliveries[msg.hash] == nil)
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
    #expect(store.state.pendingDeliveries[msg.hash]?.attempts == 1)
    // No known path → the first retry requests a path instead of resending.
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { action in
        if case let .delegate(.requestPath(dest)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    #expect(store.state.pendingDeliveries[msg.hash]?.attempts == 2)
    // The post-request wait is pathRequestWaitSeconds (7): advancing it fires the next retry (another requestPath).
    await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
    await store.receive { if case .delegate(.requestPath) = $0 { return true }; return false }
    #expect(store.state.pendingDeliveries[msg.hash]?.attempts == 3)
    await store.send(.delivered(messageHash: msg.hash))   // cancel the pending timer before teardown
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
        if case let .delegate(.sendOpportunistic(dest, _)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    await store.send(.delivered(messageHash: msg.hash))
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
    #expect(store.state.pendingDeliveries[msg.hash]?.attempts == 2)
    await store.send(.delivered(messageHash: msg.hash))
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
    #expect(store.state.pendingDeliveries[msg.hash]?.attempts == 1)
    // Direct retry resends over the link despite no known path (would be requestPath if pathless-retry leaked in).
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { action in
        if case let .delegate(.sendDirect(lid, _, _)) = action { #expect(lid == linkID); return true }
        return false
    }
    await store.send(.delivered(messageHash: msg.hash))
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    store.exhaustivity = .on
}

@Test @MainActor func routerArmsRetryForDrainedResourceMessage() async {
    let big = makeMessage(source: Identity(), content: String(repeating: "x", count: 2000))
    #expect(big.directRepresentation == .resource)
    let clock = TestClock()
    var initial = LXMFRouter.State()
    initial.knownPaths.insert(big.destinationHash)   // path known → establishes directly
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: big, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    let linkID = Data(repeating: 0xCD, count: 16)
    await store.send(.linkEstablished(destinationHash: big.destinationHash, linkID: linkID))
    await store.receive { action in
        if case let .delegate(.sendDirect(_, _, asResource)) = action { #expect(asResource == true); return true }
        return false
    }
    #expect(store.state.pendingDeliveries[big.hash]?.attempts == 1)   // drained send armed a retry
    // A retry re-emits sendDirect with asResource preserved.
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { action in
        if case let .delegate(.sendDirect(lid, _, asResource)) = action {
            #expect(lid == linkID); #expect(asResource == true); return true
        }
        return false
    }
    await store.send(.delivered(messageHash: big.hash))
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
    await store.send(.delivered(messageHash: msg.hash))
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    store.exhaustivity = .on
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
    #expect(store.state.pendingDeliveries[msg.hash]?.attempts == 1)
    await store.send(.linkClosed(destinationHash: msg.destinationHash))
    await store.receive { action in
        if case let .delegate(.requestLink(dest)) = action { #expect(dest == msg.destinationHash); return true }
        return false
    }
    #expect(store.state.directLinks[msg.destinationHash] == .establishing)
    #expect(store.state.pendingDeliveries[msg.hash] != nil)   // pending retained across the close
    await store.send(.delivered(messageHash: msg.hash))       // cancel the pending timer before teardown
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    store.exhaustivity = .on
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
    #expect(store.state.pendingDeliveries[msg.hash] == nil)
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
