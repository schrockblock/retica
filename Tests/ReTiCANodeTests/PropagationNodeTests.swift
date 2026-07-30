import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA

private func entry(dest: UInt8, tail: String) -> Data {
    Data(repeating: dest, count: LXMessage.destinationLength) + Data(tail.utf8)
}
private func container(_ entries: [Data]) -> Data {
    LXMFPropagation.container(timestamp: 1700000000.5, entries: entries)
}

@Test @MainActor func propagationNodeIngestsAndReportsIds() async {
    let e = entry(dest: 0xAA, tail: "one")
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let store = TestStore(initialState: PropagationNode.State()) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([e])))
    await store.receive { action in
        if case let .delegate(.stored(ids)) = action { #expect(ids == [tid]); return true }
        return false
    }
    #expect(store.state.store.count == 1)
    #expect(store.state.store.contains(transientId: tid))
}

@Test @MainActor func propagationNodeDedupsOnReingest() async {
    let e = entry(dest: 0xAA, tail: "one")
    let store = TestStore(initialState: PropagationNode.State()) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([e])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    await store.send(.ingestContainer(container([e])))   // identical → dedup
    await store.receive { action in
        if case let .delegate(.stored(ids)) = action { #expect(ids.isEmpty); return true }
        return false
    }
    #expect(store.state.store.count == 1)
}

@Test @MainActor func propagationNodeServesByDestination() async {
    let a1 = entry(dest: 0xAA, tail: "a1"), a2 = entry(dest: 0xAA, tail: "a2")
    let b1 = entry(dest: 0xBB, tail: "b1")
    let store = TestStore(initialState: PropagationNode.State()) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([a1, b1, a2])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    await store.send(.messagesRequested(destinationHash: destA))
    await store.receive { action in
        if case let .delegate(.deliverMessages(dest, entries)) = action {
            #expect(dest == destA); #expect(entries == [a1, a2]); return true   // only A's, oldest-first
        }
        return false
    }
}

@Test @MainActor func propagationNodeServesEmptyWhenNoneAddressed() async {
    let store = TestStore(initialState: PropagationNode.State()) { PropagationNode() }
    store.exhaustivity = .off
    let dest = Data(repeating: 0xCC, count: LXMessage.destinationLength)
    await store.send(.messagesRequested(destinationHash: dest))
    await store.receive { action in
        if case let .delegate(.deliverMessages(d, entries)) = action {
            #expect(d == dest); #expect(entries.isEmpty); return true
        }
        return false
    }
}

@Test @MainActor func propagationNodeDropsDeliveredMessages() async {
    let e = entry(dest: 0xAA, tail: "one")
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    let store = TestStore(initialState: PropagationNode.State()) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([e])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    await store.send(.messagesDelivered(transientIds: [tid]))
    #expect(store.state.store.count == 0)
    await store.send(.messagesRequested(destinationHash: destA))
    await store.receive { action in
        if case let .delegate(.deliverMessages(_, entries)) = action { #expect(entries.isEmpty); return true }
        return false
    }
}
