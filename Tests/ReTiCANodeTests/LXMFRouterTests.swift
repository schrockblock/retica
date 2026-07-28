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
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
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
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
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
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
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
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    // Enqueue a resource-sized message to the same destination to make asResource load-bearing
    var initial2 = LXMFRouter.State()
    initial2.directLinks[bigMsg.destinationHash] = .establishing
    initial2.outboundQueue[bigMsg.destinationHash] = [bigMsg]
    #expect(bigMsg.directRepresentation == .resource)
    let store2 = TestStore(initialState: initial2) { LXMFRouter() }
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
    let store = TestStore(initialState: initial) { LXMFRouter() }
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
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
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
