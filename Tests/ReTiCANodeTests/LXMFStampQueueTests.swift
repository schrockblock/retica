import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// One LXMF stamp search at a time, oldest first (reference `process_deferred_stamps` under
// `stamp_gen_lock`, LXMRouter.py:2944-3033, LXMF 1.3.0). Every search here is held open by a
// `StampGate` until the test ends it, so the order searches start and end in is the test's choice,
// never a real search's luck.

private let sentAt: TimeInterval = 1_700_000_000.5
private let propagationNodeHash = Data(repeating: 0xC0, count: 16)
private let propagationRecipient = Data(repeating: 0xA1, count: 16)
/// Peers that advertised a delivery stamp cost.
private let costlyPeer = Data(repeating: 0xD1, count: 16)
/// A peer whose path we hold and who advertised no cost.
private let freePeer = Data(repeating: 0xD2, count: 16)
/// A peer that gave us a ticket (and advertised a cost).
private let ticketPeer = Data(repeating: 0xD3, count: 16)

/// Holds each search open until `end(_:found:)` names it. Keyed by the message hash.
private final class StampGate: @unchecked Sendable {
    private let lock = NSLock()
    private var startedKeys: [Data] = []
    private var waiters: [Data: CheckedContinuation<Bool, Never>] = [:]
    private var ended: [Data: Bool] = [:]

    /// True when the test ended the search with a stamp; false when it ended it with none, or the
    /// search was cancelled.
    func search(_ key: Data) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                lock.withLock {
                    startedKeys.append(key)
                    if let found = ended[key] { c.resume(returning: found); return }
                    if Task.isCancelled { c.resume(returning: false); return }
                    waiters[key] = c
                }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: key)?.resume(returning: false) }
        }
    }

    /// End `key`'s search, now or (if it has not started) the moment it starts.
    func end(_ key: Data, found: Bool = true) {
        lock.withLock {
            ended[key] = found
            waiters.removeValue(forKey: key)?.resume(returning: found)
        }
    }

    var started: [Data] { lock.withLock { startedKeys } }

    func waitUntilStarted(_ key: Data) async {
        for _ in 0..<2000 {
            if started.contains(key) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("search for \(key.prefix(4).map { String(format: "%02x", $0) }.joined()) never started")
    }
}

private struct Recorded: Equatable {
    let hash: Data
    let phase: LXMFNode.PreparingPhase
}

/// Counted in a reducer: with exhaustivity off, a `receive` cannot see what an earlier `send` skipped.
private struct RecordingNode: Reducer {
    typealias State = LXMFNode.State
    typealias Action = LXMFNode.Action
    let phases = LockIsolated<[Recorded]>([])
    let handOvers = LockIsolated<[Data]>([])
    let propagatedHandOvers = LockIsolated<[Data]>([])
    let failures = LockIsolated<[Data]>([])
    let cancellations = LockIsolated<[Data]>([])

    var body: some Reducer<State, Action> {
        Reduce { _, action in
            switch action {
            case let .delegate(.deliveryPreparing(hash, phase)):
                phases.withValue { $0.append(Recorded(hash: hash, phase: phase)) }
            case let .router(.send(m, _)): handOvers.withValue { $0.append(m.hash) }
            case let .router(.sendViaPropagation(m, _)): propagatedHandOvers.withValue { $0.append(m.hash) }
            case let .delegate(.deliveryFailed(hash)): failures.withValue { $0.append(hash) }
            case let .delegate(.deliveryCancelled(hash)): cancellations.withValue { $0.append(hash) }
            default: break
            }
            return .none
        }
        LXMFNode()
    }

    func phases(of hash: Data) -> [LXMFNode.PreparingPhase] { phases.value.filter { $0.hash == hash }.map(\.phase) }
}

private func learned(_ identity: Identity = Identity(), appData: Data? = nil) -> LearnedDestination {
    LearnedDestination(identity: identity, appData: appData, ratchet: nil, interfaceID: InterfaceID("tcp"),
                       hops: 1, nextHop: nil, announceEmitted: 0)
}

/// A node whose delivery searches wait on `delivery` and propagated packs on `propagation`.
@MainActor
private func makeNode(_ recorder: RecordingNode, delivery: StampGate, propagation: StampGate,
                      me: Identity) -> TestStoreOf<RecordingNode> {
    var ep = TransportEndpoint.State.tcp(TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    ep.transport.learned[propagationRecipient] = learned()
    ep.transport.learned[freePeer] = learned()
    ep.transport.learned[propagationNodeHash] = learned(appData:
        PNAnnounce(timebase: 0, nodeState: true, perTransferLimit: 0, perSyncLimit: 0,
                   targetStampCost: 8, stampCostFlexibility: 0, peeringCost: 0).packed)
    var node = LXMFNode.State(identity: me, endpoint: ep)
    node.router.outboundPropagationNode = propagationNodeHash
    for peer in [costlyPeer, ticketPeer] {
        node.learnedPeers[peer] = LXMFNode.LearnedPeer(displayName: nil, stampCost: 8, supportsCompression: false,
                                                       learnedAt: Date(timeIntervalSince1970: sentAt))
    }
    node.outboundTickets[ticketPeer] = LXMFNode.Ticket(ticket: Data(repeating: 0x7E, count: LXMessage.ticketLength),
                                                       expires: Date(timeIntervalSince1970: sentAt + 86_400))
    let store = TestStore(initialState: node) { recorder } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: sentAt))
        $0.continuousClock = TestClock()
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.lxmfStampGenerator = LXMFStampGenerator(
            deliveryStamp: { messageID, _ in
                await delivery.search(messageID) ? Data(repeating: 0x5A, count: LXStamper.stampSize) : nil
            },
            propagationPack: { message, _, _, _, _ in
                await propagation.search(message.hash) ? Data("packed".utf8) : nil
            })
    }
    store.exhaustivity = .off
    return store
}

private func message(from me: Identity, to dest: Data, _ text: String) -> LXMessage {
    LXMessage.create(source: me, destinationHash: dest, timestamp: sentAt, title: Data(), content: Data(text.utf8))
}

@MainActor
private func send(_ store: TestStoreOf<RecordingNode>, _ m: LXMessage) async {
    await store.send(.sendMessage(message: m, fallbackToPropagation: false))
}

@MainActor
private func waitForHandOver(_ store: TestStoreOf<RecordingNode>, _ recorder: RecordingNode, _ hash: Data) async {
    for _ in 0..<2000 {
        await store.skipReceivedActions(strict: false)
        if recorder.handOvers.value.contains(hash) { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("never handed over")
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct LXMFStampQueueTests {
    /// Review Focus 4: three sends, their searches ended newest first, still reach the router in
    /// send order, and only one search runs at a time.
    @Test func threeQueuedSendsAreHandedOverInSendOrder() async {
        let me = Identity(), recorder = RecordingNode(), delivery = StampGate()
        let store = makeNode(recorder, delivery: delivery, propagation: StampGate(), me: me)
        let a = message(from: me, to: costlyPeer, "a"), b = message(from: me, to: costlyPeer, "b"),
            c = message(from: me, to: costlyPeer, "c")
        await send(store, a)
        await send(store, b)
        await send(store, c)
        await delivery.waitUntilStarted(a.hash)

        delivery.end(c.hash)
        delivery.end(b.hash)
        try? await Task.sleep(for: .milliseconds(100))
        await store.skipReceivedActions(strict: false)
        #expect(recorder.handOvers.value.isEmpty, "nothing reaches the router before the oldest search ends")
        #expect(delivery.started == [a.hash], "one search at a time")
        #expect(store.state.stampQueue.map(\.message.hash) == [b.hash, c.hash])

        delivery.end(a.hash)
        await waitForHandOver(store, recorder, c.hash)
        #expect(recorder.handOvers.value == [a.hash, b.hash, c.hash])
        #expect(delivery.started == [a.hash, b.hash, c.hash])
        #expect(store.state.runningStampJob == nil && store.state.stampQueue.isEmpty)
    }

    /// The second send's phases: queued behind the first, stamping when its own search starts,
    /// handed over when it reaches the router.
    @Test func aSecondSendReportsQueuedThenStampingThenHandedOver() async {
        let me = Identity(), recorder = RecordingNode(), delivery = StampGate()
        let store = makeNode(recorder, delivery: delivery, propagation: StampGate(), me: me)
        let first = message(from: me, to: costlyPeer, "first"), second = message(from: me, to: costlyPeer, "second")
        await send(store, first)
        await send(store, second)
        #expect(recorder.phases(of: first.hash) == [.stamping])
        #expect(recorder.phases(of: second.hash) == [.queued])

        delivery.end(first.hash)
        await waitForHandOver(store, recorder, first.hash)
        #expect(recorder.phases(of: second.hash) == [.queued, .stamping])

        delivery.end(second.hash)
        await waitForHandOver(store, recorder, second.hash)
        #expect(recorder.phases(of: first.hash) == [.stamping, .handedOver])
        #expect(recorder.phases(of: second.hash) == [.queued, .stamping, .handedOver])
        #expect(store.state.preparingPhases.isEmpty)
    }

    /// Review Focus 1: a queued send that is cancelled leaves the queue without its search ever
    /// starting, and gets exactly one terminal outcome.
    @Test func aCancelledQueuedSendNeverStartsItsSearchAndEndsOnce() async {
        let me = Identity(), recorder = RecordingNode(), delivery = StampGate()
        let store = makeNode(recorder, delivery: delivery, propagation: StampGate(), me: me)
        let a = message(from: me, to: costlyPeer, "a"), b = message(from: me, to: costlyPeer, "b"),
            c = message(from: me, to: costlyPeer, "c")
        await send(store, a)
        await send(store, b)
        await send(store, c)

        await store.send(.cancelOutbound(messageHash: b.hash))
        await store.skipReceivedActions(strict: false)
        #expect(recorder.cancellations.value == [b.hash])
        #expect(store.state.stampQueue.map(\.message.hash) == [c.hash])

        delivery.end(b.hash)        // were its search to start anyway, it would hand over
        delivery.end(a.hash)
        delivery.end(c.hash)
        await waitForHandOver(store, recorder, c.hash)
        #expect(delivery.started == [a.hash, c.hash], "b's search never started")
        #expect(recorder.handOvers.value == [a.hash, c.hash])
        #expect(recorder.cancellations.value == [b.hash])
        #expect(recorder.failures.value.isEmpty)
    }

    /// Review Focus 1, by `.cancelDeliveryStamps`: running and queued sends are each failed once,
    /// and the queued one's search never starts.
    @Test func cancellingDeliveryStampsFailsAQueuedSendOnceWithoutStartingIt() async {
        let me = Identity(), recorder = RecordingNode(), delivery = StampGate()
        let store = makeNode(recorder, delivery: delivery, propagation: StampGate(), me: me)
        let a = message(from: me, to: costlyPeer, "a"), b = message(from: me, to: costlyPeer, "b")
        await send(store, a)
        await send(store, b)
        await delivery.waitUntilStarted(a.hash)

        await store.send(.cancelDeliveryStamps)
        await store.send(.cancelDeliveryStamps)       // nothing left to fail
        delivery.end(b.hash)
        try? await Task.sleep(for: .milliseconds(100))
        await store.skipReceivedActions(strict: false)
        #expect(recorder.failures.value.sorted { $0.lexicographicallyPrecedes($1) }
                == [a.hash, b.hash].sorted { $0.lexicographicallyPrecedes($1) })
        #expect(delivery.started == [a.hash])
        #expect(recorder.handOvers.value.isEmpty)
        #expect(store.state.runningStampJob == nil && store.state.stampQueue.isEmpty)
    }

    /// Review Focus 2: cancelling the running search starts the next queued one.
    @Test func cancellingTheRunningSearchStartsTheNext() async {
        let me = Identity(), recorder = RecordingNode(), delivery = StampGate()
        let store = makeNode(recorder, delivery: delivery, propagation: StampGate(), me: me)
        let a = message(from: me, to: costlyPeer, "a"), b = message(from: me, to: costlyPeer, "b")
        await send(store, a)
        await send(store, b)
        await delivery.waitUntilStarted(a.hash)
        #expect(delivery.started == [a.hash])

        await store.send(.cancelOutbound(messageHash: a.hash))
        await delivery.waitUntilStarted(b.hash)
        #expect(store.state.runningStampJob?.message.hash == b.hash)
        #expect(recorder.phases(of: b.hash) == [.queued, .stamping])

        delivery.end(b.hash)
        await waitForHandOver(store, recorder, b.hash)
        #expect(recorder.handOvers.value == [b.hash])
        #expect(recorder.cancellations.value == [a.hash])
    }

    /// Cancelling a running explicit propagated send starts the delivery search queued behind it.
    @Test func cancellingPropagationStampsStartsTheQueuedDeliverySearch() async {
        let me = Identity(), recorder = RecordingNode(), delivery = StampGate(), propagation = StampGate()
        let store = makeNode(recorder, delivery: delivery, propagation: propagation, me: me)
        await store.send(.sendViaPropagation(destinationHash: propagationRecipient, title: Data(), content: Data("p".utf8)))
        guard let explicit = store.state.runningStampJob?.message.hash else {
            Issue.record("the explicit send is not running"); return
        }
        let d = message(from: me, to: costlyPeer, "d")
        await send(store, d)
        await propagation.waitUntilStarted(explicit)
        #expect(recorder.phases(of: d.hash) == [.queued])

        await store.send(.cancelPropagationStamps)
        await delivery.waitUntilStarted(d.hash)
        delivery.end(d.hash)
        await waitForHandOver(store, recorder, d.hash)
        #expect(recorder.failures.value == [explicit])
        #expect(recorder.propagatedHandOvers.value.isEmpty)
        #expect(recorder.phases(of: d.hash) == [.queued, .stamping, .handedOver])
    }

    /// Review Focus 1 for explicit propagated sends: `.cancelPropagationStamps` fails the running
    /// one and the queued one once each, and the queued one's search never starts.
    @Test func cancellingPropagationStampsFailsAQueuedExplicitSendOnceWithoutStartingIt() async {
        let me = Identity(), recorder = RecordingNode(), propagation = StampGate()
        let store = makeNode(recorder, delivery: StampGate(), propagation: propagation, me: me)
        await store.send(.sendViaPropagation(destinationHash: propagationRecipient, title: Data(), content: Data("1".utf8)))
        await store.send(.sendViaPropagation(destinationHash: propagationRecipient, title: Data(), content: Data("2".utf8)))
        guard let running = store.state.runningStampJob?.message.hash,
              let queued = store.state.stampQueue.first?.message.hash else {
            Issue.record("expected one running and one queued explicit send"); return
        }
        await propagation.waitUntilStarted(running)
        #expect(recorder.phases(of: queued) == [.queued])

        await store.send(.cancelPropagationStamps)
        await store.send(.cancelPropagationStamps)       // nothing left to fail
        propagation.end(queued)
        try? await Task.sleep(for: .milliseconds(100))
        await store.skipReceivedActions(strict: false)
        #expect(Set(recorder.failures.value) == [running, queued] && recorder.failures.value.count == 2)
        #expect(propagation.started == [running])
        #expect(recorder.propagatedHandOvers.value.isEmpty)
        #expect(store.state.runningStampJob == nil && store.state.stampQueue.isEmpty)
        #expect(store.state.preparingPhases.isEmpty)
    }

    /// Review Focus 3: a ticketed send and a send to a peer with no cost go to the router at once,
    /// while another message's search is still running.
    @Test func ticketedAndCostlessSendsNeverWaitBehindTheQueue() async {
        let me = Identity(), recorder = RecordingNode(), delivery = StampGate()
        let store = makeNode(recorder, delivery: delivery, propagation: StampGate(), me: me)
        let held = message(from: me, to: costlyPeer, "held")
        await send(store, held)
        await delivery.waitUntilStarted(held.hash)

        let ticketed = message(from: me, to: ticketPeer, "ticketed"), free = message(from: me, to: freePeer, "free")
        await send(store, ticketed)
        await send(store, free)
        await store.skipReceivedActions(strict: false)
        #expect(recorder.handOvers.value == [ticketed.hash, free.hash])
        #expect(delivery.started == [held.hash])
        #expect(recorder.phases(of: ticketed.hash).isEmpty && recorder.phases(of: free.hash).isEmpty)
        await store.send(.cancelDeliveryStamps)
    }

    /// A search that ends without a stamp, uncancelled, fails its message once (reference
    /// `fail_message`, for that message) and starts the next search.
    @Test func aSearchThatFindsNothingFailsItsMessageAndStartsTheNext() async {
        let me = Identity(), recorder = RecordingNode(), delivery = StampGate()
        let store = makeNode(recorder, delivery: delivery, propagation: StampGate(), me: me)
        let a = message(from: me, to: costlyPeer, "a"), b = message(from: me, to: costlyPeer, "b")
        await send(store, a)
        await send(store, b)
        await delivery.waitUntilStarted(a.hash)
        #expect(delivery.started == [a.hash])

        delivery.end(a.hash, found: false)
        await delivery.waitUntilStarted(b.hash)
        delivery.end(b.hash)
        await waitForHandOver(store, recorder, b.hash)
        #expect(recorder.failures.value == [a.hash])
        #expect(recorder.handOvers.value == [b.hash])
        #expect(!store.state.inFlightDeliveryStamps.contains(a.hash))
    }
}
