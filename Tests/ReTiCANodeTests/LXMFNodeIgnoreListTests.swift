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
    let old = Data(repeating: 0x01, count: 16)
    let new1 = Data(repeating: 0x02, count: 16)
    let new2 = Data(repeating: 0x03, count: 16)
    let store = makeIgnoreListStore(ignored: [old])
    store.exhaustivity = .on
    await store.send(.rehydrateIgnoredDestinations([new1, new2])) {
        $0.ignoredDestinations = [new1, new2]
    }
}

@MainActor @Test func ignoreList_rehydrateEmpty_clears() async {
    let old = Data(repeating: 0x01, count: 16)
    let store = makeIgnoreListStore(ignored: [old])
    store.exhaustivity = .on
    await store.send(.rehydrateIgnoredDestinations([])) {
        $0.ignoredDestinations = []
    }
}
