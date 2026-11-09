import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// `deliveryPreparing`: the phases a send passes through before the router has it, so a host can show
// "Preparing…" instead of "Sending…". A send that needs no preparing reports nothing.

private let iface = InterfaceID("preparing-iface")
private let sentAt: TimeInterval = 1700000000.5
private let cheapCost = 8

private struct Reported: Equatable {
    let hash: Data
    let phase: LXMFNode.PreparingPhase
}

/// Counted in a reducer: with exhaustivity off, `store.send` skips actions before a later `receive`
/// could see them.
private struct PhaseRecordingNode: Reducer {
    typealias State = LXMFNode.State
    typealias Action = LXMFNode.Action
    let reports: LockIsolated<[Reported]>
    var failures: LockIsolated<[Data]> = LockIsolated([])
    var propagatedHandOvers: LockIsolated<Int> = LockIsolated(0)
    var cancellations: LockIsolated<[Data]> = LockIsolated([])

    var body: some Reducer<State, Action> {
        Reduce { _, action in
            if case let .delegate(.deliveryPreparing(hash, phase)) = action {
                reports.withValue { $0.append(Reported(hash: hash, phase: phase)) }
            }
            if case let .delegate(.deliveryFailed(hash)) = action { failures.withValue { $0.append(hash) } }
            if case let .delegate(.deliveryCancelled(hash)) = action { cancellations.withValue { $0.append(hash) } }
            if case .router(.sendViaPropagation) = action { propagatedHandOvers.withValue { $0 += 1 } }
            return .none
        }
        LXMFNode()
    }
}

@MainActor
private func makeNode(_ identity: Identity, _ clock: TestClock<Duration>,
                      reports: LockIsolated<[Reported]>,
                      seed: (inout LXMFNode.State) -> Void = { _ in }) async -> TestStoreOf<LXMFNode> {
    var initial = LXMFNode.State(identity: identity, endpoint: TransportEndpoint.State())
    seed(&initial)
    let store = TestStore(initialState: initial) {
        PhaseRecordingNode(reports: reports)
    } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: sentAt))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.endpoint(.transport(.interfaceConnected(iface, .tcp))))
    return store
}

private func deliveryAnnounce(of peer: Identity, stampCost: Int?) -> Data {
    let dest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                           aspects: LXMessage.deliveryAspects, identity: peer)!
    let randomHash = Announce.randomHash(now: 1_700_000_000, randomPrefix: Data(repeating: 0x02, count: 5))
    let payload = Announce.buildPayload(identity: peer, destinationHash: dest.hash, nameHash: dest.nameHash,
                                        randomHash: randomHash,
                                        appData: LXMFAnnounceData.pack(displayName: "Peer", stampCost: stampCost))
    return try! Packet.announce(from: dest, payload: payload).packed()
}

private func message(from me: Identity, to peer: Identity, _ text: String = "hi") -> LXMessage {
    LXMessage.create(source: me, destinationHash: LXMessage.deliveryHash(identityHash: peer.hash), timestamp: sentAt,
                     title: Data(), content: Data(text.utf8))
}

@MainActor
private func hearAnnounce(_ store: TestStoreOf<LXMFNode>, of peer: Identity, stampCost: Int?) async {
    await store.send(.endpoint(.transport(.received(iface, deliveryAnnounce(of: peer, stampCost: stampCost)))))
    await store.receive({ action in
        if case .endpoint(.delegate(.pathLearned)) = action { return true }
        return false
    }, timeout: .seconds(5))
}

/// Waits for the next message handed to the router, whatever its stamp.
@MainActor
private func waitForHandOver(_ store: TestStoreOf<LXMFNode>, stamped: Bool? = nil, skipRest: Bool = true) async {
    await store.receive({ action in
        guard case let .router(.send(m, _)) = action else { return false }
        return stamped.map { ($0) == (m.stamp != nil) } ?? true
    }, timeout: .seconds(30))
    if skipRest { await store.skipReceivedActions(strict: false) }
}

@MainActor
private func waitOutTheCostWait(_ store: TestStoreOf<LXMFNode>, _ clock: TestClock<Duration>) async {
    for _ in 0..<LXMFNode.peerCostPathRequests {
        await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
        await store.skipReceivedActions(strict: false)
    }
}

private let propagationNodeHash = Data(repeating: 0xC0, count: 16)
private let propagationRecipient = Data(repeating: 0xA1, count: 16)

/// A node with a propagation node set at `stampCost` and a recipient it can pack for.
@MainActor
private func makePropagationClient(stampCost: Int, recorder: PhaseRecordingNode) -> TestStoreOf<LXMFNode> {
    var ep = TransportEndpoint.State.tcp(TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    ep.transport.learned[propagationRecipient] = LearnedDestination(
        identity: Identity(), appData: nil, ratchet: nil, interfaceID: InterfaceID("tcp"),
        hops: 1, nextHop: nil, announceEmitted: 0)
    ep.transport.learned[propagationNodeHash] = LearnedDestination(
        identity: Identity(),
        appData: PNAnnounce(timebase: 0, nodeState: true, perTransferLimit: 0, perSyncLimit: 0,
                            targetStampCost: stampCost, stampCostFlexibility: 0, peeringCost: 0).packed,
        ratchet: nil, interfaceID: InterfaceID("tcp"), hops: 1, nextHop: nil, announceEmitted: 0)
    var node = LXMFNode.State(identity: Identity(), endpoint: ep)
    node.router.outboundPropagationNode = propagationNodeHash
    let store = TestStore(initialState: node) { recorder } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: sentAt))
        $0.continuousClock = TestClock()
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

@Suite @MainActor struct LXMFNodePreparingPhaseTests {
    @Test func aFirstSendToAPeerWithACostReportsWaitingThenStampingThenHandedOver() async {
        let me = Identity(), peer = Identity()
        let reports = LockIsolated<[Reported]>([])
        let store = await makeNode(me, TestClock(), reports: reports)
        let m = message(from: me, to: peer)

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        #expect(reports.value == [Reported(hash: m.hash, phase: .waitingForPeer)])

        await store.send(.endpoint(.transport(.received(iface, deliveryAnnounce(of: peer, stampCost: cheapCost)))))
        await waitForHandOver(store, stamped: true)
        #expect(reports.value == [Reported(hash: m.hash, phase: .waitingForPeer),
                                  Reported(hash: m.hash, phase: .stamping),
                                  Reported(hash: m.hash, phase: .handedOver)])
        #expect(store.state.preparingPhases.isEmpty)
    }

    /// Review Focus 1: path known, no cost, so the send goes straight to the router.
    @Test func aSendHandedOverWithoutWaitingOrStampingReportsNothing() async {
        let me = Identity(), peer = Identity()
        let reports = LockIsolated<[Reported]>([])
        let store = await makeNode(me, TestClock(), reports: reports)
        await hearAnnounce(store, of: peer, stampCost: nil)

        await store.send(.sendMessage(message: message(from: me, to: peer), fallbackToPropagation: false))
        await waitForHandOver(store)
        #expect(reports.value.isEmpty)
        #expect(store.state.preparingPhases.isEmpty)
    }

    @Test func aSendToAPeerWhoseCostIsKnownReportsStampingThenHandedOverWithoutWaiting() async {
        let me = Identity(), peer = Identity()
        let reports = LockIsolated<[Reported]>([])
        let store = await makeNode(me, TestClock(), reports: reports)
        await hearAnnounce(store, of: peer, stampCost: cheapCost)

        let m = message(from: me, to: peer)
        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        await waitForHandOver(store, stamped: true)
        #expect(reports.value == [Reported(hash: m.hash, phase: .stamping),
                                  Reported(hash: m.hash, phase: .handedOver)])
    }

    @Test func eachSendWaitingOnOnePeerReportsItsOwnPhasesOnce() async {
        let me = Identity(), peer = Identity()
        let reports = LockIsolated<[Reported]>([])
        let store = await makeNode(me, TestClock(), reports: reports)
        let one = message(from: me, to: peer, "one"), two = message(from: me, to: peer, "two")

        await store.send(.sendMessage(message: one, fallbackToPropagation: false))
        await store.send(.sendMessage(message: two, fallbackToPropagation: false))
        await store.send(.endpoint(.transport(.received(iface, deliveryAnnounce(of: peer, stampCost: cheapCost)))))
        await waitForHandOver(store, stamped: true, skipRest: false)
        await waitForHandOver(store, stamped: true)

        // One stamp search at a time: the second waits behind the first.
        #expect(reports.value.filter { $0.hash == one.hash }.map(\.phase) == [.waitingForPeer, .stamping, .handedOver])
        #expect(reports.value.filter { $0.hash == two.hash }.map(\.phase)
                == [.waitingForPeer, .queued, .stamping, .handedOver])
        #expect(reports.value.count == 7)
    }

    /// Review Focus 3: the wait ran out and the router holds the message unstamped; the late announce
    /// brings a cost, the copy is taken back and stamped, so it is preparing again until re-handed.
    @Test func aCopyRestampedAfterALateAnnounceReportsStampingAgainThenHandedOver() async {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let reports = LockIsolated<[Reported]>([])
        let store = await makeNode(me, clock, reports: reports)
        let m = message(from: me, to: peer)

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        await waitOutTheCostWait(store, clock)
        #expect(reports.value == [Reported(hash: m.hash, phase: .waitingForPeer),
                                  Reported(hash: m.hash, phase: .handedOver)])
        #expect(!store.state.unstampedHandOvers.isEmpty, "handed over unstamped, with the cost still unknown")

        await hearAnnounce(store, of: peer, stampCost: cheapCost)
        await waitForHandOver(store, stamped: true)
        #expect(reports.value == [Reported(hash: m.hash, phase: .waitingForPeer),
                                  Reported(hash: m.hash, phase: .handedOver),
                                  Reported(hash: m.hash, phase: .stamping),
                                  Reported(hash: m.hash, phase: .handedOver)])
        #expect(store.state.preparingPhases.isEmpty)
    }

    /// Review Focus 5: an explicit propagated send stamps (and packs) in one effect.
    @Test func anExplicitPropagatedSendReportsStampingThenHandedOver() async {
        let reports = LockIsolated<[Reported]>([])
        let store = makePropagationClient(stampCost: 4, recorder: PhaseRecordingNode(reports: reports))
        await store.send(.sendViaPropagation(destinationHash: propagationRecipient, title: Data("t".utf8), content: Data("x".utf8)))
        await store.receive({ if case .router(.sendViaPropagation) = $0 { return true }; return false }, timeout: .seconds(30))
        await store.skipReceivedActions(strict: false)

        let hash = reports.value.first?.hash
        #expect(reports.value.map(\.phase) == [.stamping, .handedOver])
        #expect(reports.value.allSatisfy { $0.hash == hash })
        #expect(store.state.preparingPhases.isEmpty)
    }

    /// The router knows nothing of an explicit propagated send until its hand-over, so the node
    /// itself must report one whose stamp work is cancelled: failed once, never handed over.
    @Test func cancellingPropagationStampsFailsAStampingExplicitSendOnce() async {
        let reports = LockIsolated<[Reported]>([])
        let recorder = PhaseRecordingNode(reports: reports)
        let store = makePropagationClient(stampCost: LXMFPropagation.maxPropagationStampCost, recorder: recorder)
        await store.send(.sendViaPropagation(destinationHash: propagationRecipient, title: Data("t".utf8), content: Data("x".utf8)))
        let hash = reports.value.first?.hash
        #expect(reports.value.map(\.phase) == [.stamping])

        await store.send(.cancelPropagationStamps)
        await store.send(.cancelPropagationStamps)     // a second cancel has nothing left to fail
        await store.skipReceivedActions(strict: false)
        #expect(recorder.failures.value == [hash].compactMap { $0 })
        #expect(recorder.propagatedHandOvers.value == 0)
        #expect(store.state.preparingPhases.isEmpty)
    }

    @Test func changingThePropagationNodeFailsAStampingExplicitSendOnce() async {
        let reports = LockIsolated<[Reported]>([])
        let recorder = PhaseRecordingNode(reports: reports)
        let store = makePropagationClient(stampCost: LXMFPropagation.maxPropagationStampCost, recorder: recorder)
        await store.send(.sendViaPropagation(destinationHash: propagationRecipient, title: Data("t".utf8), content: Data("x".utf8)))
        let hash = reports.value.first?.hash

        await store.send(.setPropagationNode(destinationHash: Data(repeating: 0xC1, count: 16)))
        await store.skipReceivedActions(strict: false)
        #expect(recorder.failures.value == [hash].compactMap { $0 })
        #expect(recorder.propagatedHandOvers.value == 0)
        #expect(store.state.preparingPhases.isEmpty)
    }

    /// `.cancelOutbound` on an explicit propagated send mid-stamp: reported cancelled once, its
    /// search stopped, never handed over, and another explicit send in flight is untouched.
    @Test(.timeLimit(.minutes(1))) func cancellingOneStampingExplicitSendReportsItCancelledAndLeavesTheOther() async {
        let reports = LockIsolated<[Reported]>([])
        let recorder = PhaseRecordingNode(reports: reports)
        let store = makePropagationClient(stampCost: LXMFPropagation.maxPropagationStampCost, recorder: recorder)
        await store.send(.sendViaPropagation(destinationHash: propagationRecipient, title: Data("t".utf8), content: Data("one".utf8)))
        await store.send(.sendViaPropagation(destinationHash: propagationRecipient, title: Data("t".utf8), content: Data("two".utf8)))
        let hashes = reports.value.map(\.hash)
        #expect(hashes.count == 2 && hashes[0] != hashes[1])
        guard hashes.count == 2 else { return }

        await store.send(.cancelOutbound(messageHash: hashes[0]))
        await store.skipReceivedActions(strict: false)
        await store.send(.cancelOutbound(messageHash: hashes[0]))     // already cancelled: reports nothing more
        await store.skipReceivedActions(strict: false)
        #expect(recorder.cancellations.value == [hashes[0]])
        #expect(recorder.failures.value.isEmpty)
        #expect(store.state.preparingPhases[hashes[0]] == nil)
        #expect(store.state.preparingPhases[hashes[1]] == .stamping, "the other send is untouched")

        await store.send(.cancelOutbound(messageHash: hashes[1]))
        await store.skipReceivedActions(strict: false)
        #expect(recorder.cancellations.value == [hashes[0], hashes[1]])
        #expect(recorder.propagatedHandOvers.value == 0)
        // Both searches are over only if each was cancelled by its own ID.
        store.exhaustivity = .on
        await store.finish(timeout: .seconds(10))
    }

    @Test func settingTheSamePropagationNodeLeavesAStampingExplicitSendRunning() async {
        let reports = LockIsolated<[Reported]>([])
        let recorder = PhaseRecordingNode(reports: reports)
        let store = makePropagationClient(stampCost: LXMFPropagation.maxPropagationStampCost, recorder: recorder)
        await store.send(.sendViaPropagation(destinationHash: propagationRecipient, title: Data("t".utf8), content: Data("x".utf8)))
        await store.send(.setPropagationNode(destinationHash: propagationNodeHash))
        #expect(recorder.failures.value.isEmpty)
        #expect(store.state.preparingPhases.count == 1)
        await store.send(.cancelPropagationStamps)       // reclaim the long search
        await store.skipReceivedActions(strict: false)
    }

    @Test func aCancelledWaitingSendReportsNoHandedOver() async {
        let me = Identity(), peer = Identity()
        let reports = LockIsolated<[Reported]>([])
        let store = await makeNode(me, TestClock(), reports: reports)
        let m = message(from: me, to: peer)

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        await store.send(.cancelOutbound(messageHash: m.hash))
        await store.receive(.delegate(.deliveryCancelled(messageHash: m.hash)))
        #expect(store.state.preparingPhases.isEmpty)

        await hearAnnounce(store, of: peer, stampCost: nil)
        await store.skipReceivedActions(strict: false)
        #expect(reports.value == [Reported(hash: m.hash, phase: .waitingForPeer)])
    }

    /// The router reports nothing for a message whose other copy already succeeded, so the phase
    /// must be cleared by the abandon itself, not by a terminal outcome.
    @Test func abandoningASendWhoseOutcomeBelongsToAnotherCopyStillClearsItsPhase() async {
        let me = Identity(), peer = Identity()
        let reports = LockIsolated<[Reported]>([])
        let m = message(from: me, to: peer)
        let store = await makeNode(me, TestClock(), reports: reports) { $0.router.succeededMessages.insert(m.hash) }

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        #expect(store.state.preparingPhases[m.hash] == .waitingForPeer)
        await store.send(.cancelDeliveryStamps)
        await store.skipReceivedActions(strict: false)
        #expect(store.state.preparingPhases.isEmpty)
    }

    @Test func abandoningWaitingSendsReportsNoHandedOver() async {
        let me = Identity(), peer = Identity()
        let reports = LockIsolated<[Reported]>([])
        let store = await makeNode(me, TestClock(), reports: reports)
        let m = message(from: me, to: peer)

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        await store.send(.cancelDeliveryStamps)
        await store.receive(.delegate(.deliveryFailed(messageHash: m.hash)))
        #expect(store.state.preparingPhases.isEmpty)

        await hearAnnounce(store, of: peer, stampCost: nil)
        await store.skipReceivedActions(strict: false)
        #expect(reports.value == [Reported(hash: m.hash, phase: .waitingForPeer)])
    }
}
