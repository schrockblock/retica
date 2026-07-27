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
