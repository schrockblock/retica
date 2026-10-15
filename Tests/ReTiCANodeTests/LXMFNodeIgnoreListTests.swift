import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// A node store with nothing on the wire. Exhaustivity off: the endpoint scope emits its own
/// actions on construction and these tests only care about `ignoredDestinations` and delivery.
@MainActor
func makeIgnoreListStore(
    deliveryStampCost: Int? = nil,
    enforceDeliveryStamps: Bool = false,
    ignored: Set<Data> = []
) -> TestStore<LXMFNode.State, LXMFNode.Action> {
    var node = LXMFNode.State(
        identity: Identity(),
        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false)
    )
    node.deliveryStampCost = deliveryStampCost
    node.enforceDeliveryStamps = enforceDeliveryStamps
    node.ignoredDestinations = ignored
    let store = TestStore(initialState: node) { LXMFNode() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.continuousClock = TestClock()
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

/// An unstamped message from `sender` to a fixed recipient hash.
func ignoreListMessage(from sender: Identity) -> LXMessage {
    LXMessage.create(source: sender, destinationHash: Data(repeating: 0xBB, count: 16),
                     timestamp: 1700000000, title: Data("t".utf8), content: Data("c".utf8))
}

/// The key the ignore list uses for `sender`: its lxmf.delivery hash, which is what
/// `LXMessage.sourceHash` carries.
func ignoreListKey(_ sender: Identity) -> Data {
    LXMessage.deliveryHash(identityHash: sender.hash)
}

@MainActor @Test func ignoreList_startsEmpty() {
    let node = LXMFNode.State(identity: Identity(),
                              endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    #expect(node.ignoredDestinations.isEmpty)
}

@MainActor @Test func ignoreList_ignoreDestination_insertsAndEmitsNothing() async {
    let store = makeIgnoreListStore()
    let key = Data(repeating: 0x01, count: 16)
    store.exhaustivity = .on
    await store.send(.ignoreDestination(key)) {
        $0.ignoredDestinations = [key]
    }
}

@MainActor @Test func ignoreList_ignoreDestination_twiceIsANoOp() async {
    let key = Data(repeating: 0x01, count: 16)
    let store = makeIgnoreListStore(ignored: [key])
    store.exhaustivity = .on
    await store.send(.ignoreDestination(key))
    #expect(store.state.ignoredDestinations == [key])
}

@MainActor @Test func ignoreList_unignoreDestination_removes() async {
    let a = Data(repeating: 0x01, count: 16)
    let b = Data(repeating: 0x02, count: 16)
    let store = makeIgnoreListStore(ignored: [a, b])
    store.exhaustivity = .on
    await store.send(.unignoreDestination(a)) {
        $0.ignoredDestinations = [b]
    }
}

@MainActor @Test func ignoreList_unignoreDestination_absentIsANoOp() async {
    let a = Data(repeating: 0x01, count: 16)
    let store = makeIgnoreListStore(ignored: [a])
    store.exhaustivity = .on
    await store.send(.unignoreDestination(Data(repeating: 0x09, count: 16)))
    #expect(store.state.ignoredDestinations == [a])
}

@MainActor @Test func ignoreList_rehydrate_replacesRatherThanMerges() async {
    let sender = Identity()
    let new1 = Data(repeating: 0x02, count: 16)
    let new2 = Data(repeating: 0x03, count: 16)
    let store = makeIgnoreListStore(ignored: [ignoreListKey(sender)])
    store.exhaustivity = .on
    await store.send(.rehydrateIgnoredDestinations([new1, new2])) {
        $0.ignoredDestinations = [new1, new2]
    }
    store.exhaustivity = .off
    let hash = await deliveredHash(store, ignoreListMessage(from: sender))
    #expect(hash != nil)
}

@MainActor @Test func ignoreList_rehydrateEmpty_clears() async {
    let old = Data(repeating: 0x01, count: 16)
    let store = makeIgnoreListStore(ignored: [old])
    store.exhaustivity = .on
    await store.send(.rehydrateIgnoredDestinations([])) {
        $0.ignoredDestinations = []
    }
}

/// Drives one delivery through the node and returns the hash of the message the app would have received, or nil when nothing was emitted within one second.
@MainActor
func deliveredHash(_ store: TestStore<LXMFNode.State, LXMFNode.Action>,
                   _ message: LXMessage, validated: Bool = false,
                   method: LXMFRouter.DeliveryMethod = .opportunistic) async -> Data? {
    let got = LockIsolated<Data?>(nil)
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: validated,
                                                         method: method))))
    await store.receive({ action in
        if case let .delegate(.messageReceived(m, _, _)) = action {
            got.setValue(m.hash)
            return true
        }
        return false
    }, timeout: .seconds(1))
    return got.value
}

@MainActor @Test func ignoreList_ignoredSource_emitsNothing() async {
    let sender = Identity()
    let store = makeIgnoreListStore(ignored: [ignoreListKey(sender)])
    let message = ignoreListMessage(from: sender)
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: false,
                                                         method: .opportunistic))))
    store.exhaustivity = .on
    await store.finish(timeout: .seconds(2))
}

@MainActor @Test func ignoreList_ignoredSource_validatedSignatureStillDropped() async {
    let sender = Identity()
    let store = makeIgnoreListStore(ignored: [ignoreListKey(sender)])
    let message = ignoreListMessage(from: sender)
    await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: true,
                                                         method: .opportunistic))))
    store.exhaustivity = .on
    await store.finish(timeout: .seconds(2))
}

@MainActor @Test func ignoreList_ignoredSource_droppedForEveryMethod() async {
    let sender = Identity()
    for method in [LXMFRouter.DeliveryMethod.direct, .propagated] {
        let store = makeIgnoreListStore(ignored: [ignoreListKey(sender)])
        let message = ignoreListMessage(from: sender)
        await store.send(.router(.delegate(.messageDelivered(message: message, signatureValidated: false,
                                                             method: method))))
        store.exhaustivity = .on
        await store.finish(timeout: .seconds(2))
    }
}

@MainActor @Test func ignoreList_otherSource_stillDelivered() async {
    let ignoredSender = Identity()
    let sender = Identity()
    let store = makeIgnoreListStore(ignored: [ignoreListKey(ignoredSender)])
    let message = ignoreListMessage(from: sender)
    let hash = await deliveredHash(store, message)
    #expect(hash == message.hash)
}

@MainActor @Test func ignoreList_unignore_restoresDelivery() async {
    let sender = Identity()
    let store = makeIgnoreListStore(ignored: [ignoreListKey(sender)])
    await store.send(.unignoreDestination(ignoreListKey(sender)))
    let message = ignoreListMessage(from: sender)
    let hash = await deliveredHash(store, message)
    #expect(hash == message.hash)
}

/// With a cost configured, enforcement off and an invalid stamp, the stamp path alone DELIVERS
/// (flagged invalid), so the only way this message can be dropped is the ignore guard. The same
/// setup for a non-ignored sender proves the stamp path still runs when the set is non-empty.
/// (That the guard sits before the stamp work is a cost property, not observable here.)
@MainActor @Test func ignoreList_ignoredSource_droppedEvenWhenStampPathWouldDeliver() async {
    let cost = 8
    let seed = Data(repeating: 0x11, count: 32) + Data(repeating: 0x22, count: 32)
    let sender = Identity(privateKey: seed)!
    let base = ignoreListMessage(from: sender)
    let invalid = base.withStamp(Data(repeating: 0xFF, count: LXStamper.stampSize))
    #expect(!invalid.validateStamp(targetCost: cost), "fixture stamp is no longer invalid at \(cost)")

    let ignoring = makeIgnoreListStore(deliveryStampCost: cost, enforceDeliveryStamps: false,
                                       ignored: [ignoreListKey(sender)])
    await ignoring.send(.router(.delegate(.messageDelivered(message: invalid, signatureValidated: false,
                                                            method: .opportunistic))))
    ignoring.exhaustivity = .on
    await ignoring.finish(timeout: .seconds(2))

    let other = makeIgnoreListStore(deliveryStampCost: cost, enforceDeliveryStamps: false,
                                    ignored: [Data(repeating: 0x42, count: 16)])
    let got = LockIsolated<(checked: Bool, valid: Bool)?>(nil)
    await other.send(.router(.delegate(.messageDelivered(message: invalid, signatureValidated: false,
                                                         method: .opportunistic))))
    await other.receive({ action in
        if case let .delegate(.messageReceived(m, _, _)) = action {
            got.setValue((m.stampChecked, m.stampValid))
            return true
        }
        return false
    }, timeout: .seconds(1))
    #expect(got.value?.checked == true)
    #expect(got.value?.valid == false)
}
