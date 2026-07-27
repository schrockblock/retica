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
