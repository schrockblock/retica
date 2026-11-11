import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCA
@testable import ReTiCATransport

/// A path response to OUR path request answers the question even when it does not improve the
/// route we hold. The usual source is a hub replaying its cached copy of the peer's last announce,
/// which is exactly the announce our restored path came from: same emission time, same hops, so
/// `shouldReplace` refuses it. Without `.pathLearned` here, whoever asked (LXMFRouter, parked in
/// `.awaitingPath`) never hears that a path exists and runs out its budget.

private let up = InterfaceID("up")
private let hub = Data(repeating: 0x09, count: 16)

/// Transport, plus a log of every `.pathLearned` it reports.
@Reducer
private struct PathLearnedRecorder {
    struct State: Equatable {
        var transport = Transport.State()
        var pathsLearned: [Data] = []
    }
    enum Action { case transport(Transport.Action) }
    var body: some ReducerOf<Self> {
        Scope(state: \.transport, action: \.transport) { Transport() }
        Reduce { state, action in
            if case let .transport(.delegate(.pathLearned(destinationHash, _))) = action {
                state.pathsLearned.append(destinationHash)
            }
            return .none
        }
    }
}

private struct Peer {
    let destHash: Data
    let announce: Data
    let pathResponse: Data
}

/// One announce of a peer, relayed by `hub` one hop away: as a plain announce, and as the hub's
/// path response carrying the very same payload (same random hash, so the same emission time).
private func makePeer() -> Peer {
    let peer = Identity()
    let destHash = Destination.hash(identityHash: peer.hash, appName: "test", aspects: ["held"])
    let nameHash = Destination.nameHash(appName: "test", aspects: ["held"])
    let randomHash = Announce.randomHash(now: 1, randomPrefix: Data(repeating: 0x01, count: 5))
    let payload = Announce.buildPayload(identity: peer, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash)
    func packet(_ context: PacketContext) -> Data {
        try! Packet(headerType: .header2, packetType: .announce, transportType: .transport,
                    destinationType: .single, context: context, contextFlag: false,
                    hops: 1, destinationHash: destHash, transportId: hub, payload: payload).packed()
    }
    return Peer(destHash: destHash, announce: packet(.none), pathResponse: packet(.pathResponse))
}

/// The path a previous session learned from `peer.announce`, as it comes back from disk.
@MainActor
private func learnedInAnEarlierSession(_ peer: Peer) async -> LearnedDestination {
    let earlier = TestStore(initialState: Transport.State()) { Transport() }
    earlier.exhaustivity = .off
    await earlier.send(.interfaceConnected(up))
    await earlier.send(.received(up, peer.announce))
    await earlier.skipReceivedActions(strict: false)
    return earlier.state.learned[peer.destHash]!
}

/// A relaunched Transport: the path restored, no announce heard yet this session.
@MainActor
private func relaunched(_ peer: Peer) async -> TestStoreOf<PathLearnedRecorder> {
    let restored = await learnedInAnEarlierSession(peer)
    let store = TestStore(initialState: PathLearnedRecorder.State()) { PathLearnedRecorder() }
    store.exhaustivity = .off
    await store.send(.transport(.interfaceConnected(up)))
    await store.send(.transport(.rehydrateLearnedDestinations([peer.destHash: restored])))
    #expect(store.state.transport.learned[peer.destHash] == restored)
    return store
}

@MainActor
private func receive(_ store: TestStoreOf<PathLearnedRecorder>, _ raw: Data) async {
    await store.send(.transport(.received(up, raw)))
    await store.skipReceivedActions(strict: false)
}

@Suite @MainActor struct PathResponseConfirmsHeldPathTests {
    @Test func aCachedPathResponseToOurRequestReportsTheHeldPath() async {
        let peer = makePeer()
        let store = await relaunched(peer)
        let held = store.state.transport.learned[peer.destHash]
        await store.send(.transport(.requestPath(destinationHash: peer.destHash)))
        await store.skipReceivedActions(strict: false)
        await receive(store, peer.pathResponse)
        #expect(store.state.pathsLearned == [peer.destHash])
        #expect(store.state.transport.learned[peer.destHash] == held, "the held route is reported, not replaced")
    }

    /// Nobody asked: a non-improving path response changes nothing and reports nothing.
    @Test func anUnrequestedCachedPathResponseReportsNothing() async {
        let peer = makePeer()
        let store = await relaunched(peer)
        await receive(store, peer.pathResponse)
        #expect(store.state.pathsLearned.isEmpty)
    }

    /// An ordinary announce is not an answer to a path request, even one that is outstanding.
    @Test func aPlainAnnounceDoesNotAnswerOurRequest() async {
        let peer = makePeer()
        let store = await relaunched(peer)
        await store.send(.transport(.requestPath(destinationHash: peer.destHash)))
        await store.skipReceivedActions(strict: false)
        await receive(store, peer.announce)
        #expect(store.state.pathsLearned.isEmpty)
    }
}
