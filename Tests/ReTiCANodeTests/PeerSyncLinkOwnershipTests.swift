import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport
@testable import ReTiCAInterfaces

// Link ownership (Task 6 fix round 1). A link opened with `.openOwnedLink` reports its establishment
// and every failure before it only to its owner, and the router's abandon never touches its key search
// (I3). A response is matched to the request that asked it (C1, defence in depth).

private let dest = Data(repeating: 0x5A, count: 16)
private let iface = InterfaceID("own-iface")

@MainActor
private func makePlane() -> TestStoreOf<LinkPlane> {
    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    return store
}

/// I3: the router abandoning its establishment to a destination (`abandonStampSearches`) drops only its
/// own (plain) key search. An owned search to the same destination keeps running, and when the
/// endpoint stops, it ends with `ownedLinkFailed` to its owner, never a plain `linkFailed`.
@MainActor @Test func abandoningPlainSearchesLeavesTheOwnedOneAndItsFailureReachesTheOwner() async {
    let store = makePlane()
    let peer = Identity()
    // Cost 20: the search runs far longer than this test, so only an outside action ends it.
    await store.send(.openOwnedLink(owner: .propagationPeerSync, initiatorTo: peer, destinationHash: dest,
                                    interfaceID: iface, relayNextHop: nil, linkCost: 20))
    await store.send(.openLink(initiatorTo: peer, destinationHash: dest, interfaceID: iface, relayNextHop: nil,
                               linkCost: 20))
    #expect(store.state.stampingLinks.count == 2)
    let owned = store.state.stampingLinks.first { store.state.linkOwners[$0.id] == .propagationPeerSync }
    #expect(owned != nil)

    await store.send(.abandonStampSearches(destinationHash: dest))
    #expect(store.state.stampingLinks.map(\.id) == [owned?.id].compactMap { $0 })

    await store.send(.cancelStampSearches)
    await store.receive(.delegate(.ownedLinkFailed(owner: .propagationPeerSync, destinationHash: dest,
                                                   reason: .pathStale)))
    #expect(store.state.stampingLinks.isEmpty)
    #expect(store.state.linkOwners.isEmpty)
}

/// A link that cannot be opened at all (a cost over the ceiling) fails to its owner too.
@MainActor @Test func anOwnedLinkThatCannotStartFailsToItsOwner() async {
    let store = makePlane()
    await store.send(.openOwnedLink(owner: .propagationPeerSync, initiatorTo: Identity(), destinationHash: dest,
                                    interfaceID: iface, relayNextHop: nil, linkCost: LinkPlane.maxLinkStampCost + 1))
    await store.receive(.delegate(.ownedLinkFailed(owner: .propagationPeerSync, destinationHash: dest,
                                                   reason: .stampFailure)))
    #expect(store.state.linkOwners.isEmpty)
}

/// Counts the `.router(.linkClosed(dest))` an `LXMFNode` processes.
private struct RouterLinkClosedCounter: Reducer {
    typealias State = LXMFNode.State
    typealias Action = LXMFNode.Action
    let count: LockIsolated<Int>
    var body: some ReducerOf<Self> {
        Reduce { _, action in
            if case .router(.linkClosed(destinationHash: dest)) = action { count.withValue { $0 += 1 } }
            return .none
        }
        LXMFNode()
    }
}

/// Task 6 N1: the router abandoning its establishment to a node counts only ITS OWN key searches. With
/// only a propagation peer-sync search (owned) to that node, the router's link was already minted and
/// is still establishing, so the router must not be told it is gone, and the owned search keeps
/// running. With a plain search there too, that one is abandoned and the router told.
@MainActor @Test func routerAbandonIgnoresAnOwnedStampSearch() async {
    var state = LXMFNode.State(identity: Identity(),
                               endpoint: tcpDriverEndpoint(host: "h", port: 4242, reconnectOnDrop: false))
    state.router.directLinks[dest] = .establishing
    let told = LockIsolated(0)
    let store = TestStore(initialState: state) { RouterLinkClosedCounter(count: told) } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    let peer = Identity()
    // Cost 20: the search runs far longer than this test.
    await store.send(.endpoint(.linkPlane(.openOwnedLink(owner: .propagationPeerSync, initiatorTo: peer,
                                                         destinationHash: dest, interfaceID: iface,
                                                         relayNextHop: nil, linkCost: 20))))
    #expect(store.state.endpoint.linkPlane.stampingLinks.count == 1)
    func routerTold() -> Bool { told.value > 0 }

    await store.send(.router(.delegate(.abandonLink(destinationHash: dest))))
    await store.skipReceivedActions(strict: false)
    #expect(!routerTold(), "an owned search is not the router's")
    #expect(store.state.endpoint.linkPlane.stampingLinks.count == 1)

    await store.send(.endpoint(.linkPlane(.openLink(initiatorTo: peer, destinationHash: dest, interfaceID: iface,
                                                    relayNextHop: nil, linkCost: 20))))
    await store.send(.router(.delegate(.abandonLink(destinationHash: dest))))
    await store.skipReceivedActions(strict: false)
    #expect(routerTold())
    #expect(store.state.endpoint.linkPlane.stampingLinks.count == 1, "the owned search still runs")
    await store.send(.endpoint(.linkPlane(.cancelStampSearches)))
    await store.skipReceivedActions(strict: false)
}

/// Counts the links an `LXMFNode` closes.
private struct CloseCounter: Reducer {
    typealias State = LXMFNode.State
    typealias Action = LXMFNode.Action
    let closes: LockIsolated<Int>
    var body: some ReducerOf<Self> {
        Reduce { _, action in
            if case .endpoint(.closeLink) = action { closes.withValue { $0 += 1 } }
            return .none
        }
        LXMFNode()
    }
}

/// Probe A2: a client sync waiting for its `/get` list on a link ignores an answer to another request
/// on that link (here an `/offer`'s `True`), instead of ending the sync as invalid and closing the
/// link; its own answer is still taken.
@MainActor @Test func syncIgnoresAResponseToAnotherRequestOnItsLink() async {
    let link = Data(repeating: 0x11, count: 16)
    var state = LXMFNode.State(identity: Identity(),
                               endpoint: tcpDriverEndpoint(host: "h", port: 4242, reconnectOnDrop: false))
    state.syncPhase[link] = .awaitingList
    let closes = LockIsolated(0)
    let store = TestStore(initialState: state) { CloseCounter(closes: closes) } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    let getID = Data(repeating: 0x0A, count: 16), offerID = Data(repeating: 0x0B, count: 16)
    await store.send(.endpoint(.delegate(.requestSent(linkID: link, requestID: getID, path: "/get"))))
    #expect(store.state.syncRequestIDs[link] == getID)

    await store.send(.endpoint(.delegate(.responseReceived(linkID: link, requestID: offerID,
                                                           data: MsgPack.encode(.bool(true))))))
    await store.skipReceivedActions(strict: false)
    #expect(closes.value == 0)
    #expect(store.state.syncPhase[link] == .awaitingList)
    await store.send(.endpoint(.delegate(.requestFailed(linkID: link, requestID: offerID))))
    #expect(store.state.syncPhase[link] == .awaitingList)

    // Its own answer reaches the router as the offered list.
    let tid = Data(repeating: 0x7E, count: 32)
    await store.send(.endpoint(.delegate(.responseReceived(linkID: link, requestID: getID,
                                                           data: MsgPack.encode(.array([.bin(tid)]))))))
    await store.receive { if case .router(.offeredMessageList([tid])) = $0 { return true }; return false }
}
