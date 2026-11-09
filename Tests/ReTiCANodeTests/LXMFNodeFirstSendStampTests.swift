import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

// A first message to someone we have never heard from.
//
// The cost a peer requires arrives in the same announce that gives us a path to it. Reading the cost
// at send time, before that announce, means sending unstamped to a peer that may enforce stamps, and
// MeshChatX enforces by default. The peer proves the packet before checking the stamp
// (LXMRouter.py:2263, LXMF 1.3.0), so we would report it delivered as well.
//
// Reference has this gap: `handle_outbound` reads the cost once (LXMRouter.py:2080-2084). Deliberate
// divergence: we wait for the path first. Observed live against a reference LXMF 1.3.0 router.

private let iface = InterfaceID("first-send-iface")
private let sentAt: TimeInterval = 1700000000.5
/// MeshChatX's default. A real search stays quick, and random bytes pass only 1 time in 256.
private let cheapCost: Double = 8

/// Counted in a reducer: with exhaustivity off, `store.send` skips actions before a later `receive`
/// predicate could see them.
private struct PathRequestCountingNode: Reducer {
    typealias State = LXMFNode.State
    typealias Action = LXMFNode.Action
    let pathRequests: LockIsolated<Int>
    let transmitted: Transmitted

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            if case .endpoint(.requestPath) = action { pathRequests.withValue { $0 += 1 } }
            // Transport drops a send to a destination it has not learned (`sendFailed(.notLearned)`),
            // so only one it has learned can reach the wire.
            if case let .endpoint(.send(dest, plaintext, _)) = action, state.endpoint.learned[dest] != nil {
                transmitted.opportunistic.withValue { $0.append(plaintext) }
            }
            if case .cancelDeliveryStamps = action { transmitted.handOvers.withValue { $0.append(nil) } }
            if case let .router(.send(m, _)) = action, m.stamp != nil {
                transmitted.handOvers.withValue { $0.append(m.hash) }
            }
            if case let .router(.delegate(.sendDirect(_, data, _))) = action {
                transmitted.overLink.withValue { $0.append(data) }
            }
            if case let .delegate(outcome) = action {
                switch outcome {
                case .deliveryFailed, .deliveryConfirmed, .propagationAccepted, .deliveryRejected, .deliveryCancelled:
                    let described = String(describing: outcome)
                    transmitted.terminals.withValue { $0.append(described) }
                default: break
                }
            }
            return .none
        }
        LXMFNode()
    }
}

/// What could actually leave the node: opportunistic payloads sent to a learned destination, and
/// packed messages sent over a link. Also every terminal outcome reported to the app.
private struct Transmitted {
    let opportunistic = LockIsolated<[Data]>([])
    let overLink = LockIsolated<[Data]>([])
    /// Described, because `LXMFNode.Action.Delegate` is not `Sendable`.
    let terminals = LockIsolated<[String]>([])
    /// Each stamped message handed to the router, in order, with nil where `.cancelDeliveryStamps` came.
    let handOvers = LockIsolated<[Data?]>([])
}

private func described(_ outcome: LXMFNode.Action.Delegate) -> String { String(describing: outcome) }

/// High enough that the search is still running when the test cancels it (about 8 minutes on a
/// Mac, see `maxDeliveryStampCost`), and within the ceiling, so it does start.
private let slowCost = LXMFNode.maxDeliveryStampCost
/// A few seconds of search on a Mac: long enough that a search just started is still running when
/// the test acts on it, short enough that one the test failed to stop finishes, and shows, within
/// the test's wait.
private let quickButNotInstantCost: Double = 14

@MainActor
private func makeNode(_ identity: Identity, _ clock: TestClock<Duration>,
                      countingPathRequestsIn pathRequests: LockIsolated<Int> = LockIsolated(0),
                      recordingIn transmitted: Transmitted = Transmitted(),
                      seed: (inout LXMFNode.State) -> Void = { _ in }) async -> TestStoreOf<LXMFNode> {
    var initial = LXMFNode.State(identity: identity, endpoint: TransportEndpoint.State())
    seed(&initial)
    let store = TestStore(initialState: initial) {
        PathRequestCountingNode(pathRequests: pathRequests, transmitted: transmitted)
    } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: sentAt))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.endpoint(.transport(.interfaceConnected(iface, .tcp))))
    return store
}

private func deliveryAnnounce(of peer: Identity, stampCost: Double?) -> Data {
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

/// The next message handed to the router. The assertions are on this, not on state, so a stamp
/// computed and then dropped on the way cannot pass.
@MainActor
private func nextHandedToRouter(_ store: TestStoreOf<LXMFNode>) async -> LXMessage? {
    let captured = LockIsolated<LXMessage?>(nil)
    await store.receive({ action in
        guard case let .router(.send(m, _)) = action else { return false }
        captured.setValue(m)
        return true
    }, timeout: .seconds(30))
    return captured.value
}

@MainActor
private func isHandedOver(_ store: TestStoreOf<LXMFNode>, _ m: LXMessage) async -> Bool {
    await store.skipReceivedActions(strict: false)
    return store.state.router.hasOutboundState(for: m.hash)
}

@Suite @MainActor struct LXMFNodeFirstSendStampTests {
    @Test func aFirstSendWaitsForThePeersCostAndCarriesAValidStamp() async throws {
        let me = Identity(), peer = Identity()
        let store = await makeNode(me, TestClock())
        let m = message(from: me, to: peer)

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        #expect(await isHandedOver(store, m) == false, "no stamp exists yet, so it must not go out")

        await store.send(.endpoint(.transport(.received(iface, deliveryAnnounce(of: peer, stampCost: cheapCost)))))
        let handed = try #require(await nextHandedToRouter(store))
        #expect(handed.hash == m.hash)
        #expect(handed.stamp != nil)
        #expect(handed.validateStamp(targetCost: cheapCost))
    }

    @Test func aFirstSendRequestsAPathWhileItWaits() async {
        let me = Identity(), peer = Identity()
        let store = await makeNode(me, TestClock())
        await store.send(.sendMessage(message: message(from: me, to: peer), fallbackToPropagation: false))
        let dest = LXMessage.deliveryHash(identityHash: peer.hash)
        await store.receive { action in
            if case .endpoint(.requestPath(destinationHash: dest)) = action { return true }
            return false
        }
    }

    @Test func aFirstSendToAPeerWithNoCostGoesOutUnstampedWhenThePathArrives() async throws {
        let me = Identity(), peer = Identity()
        let store = await makeNode(me, TestClock())
        let m = message(from: me, to: peer)

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        #expect(await isHandedOver(store, m) == false)

        await store.send(.endpoint(.transport(.received(iface, deliveryAnnounce(of: peer, stampCost: nil)))))
        let handed = try #require(await nextHandedToRouter(store))
        #expect(handed.hash == m.hash)
        #expect(handed.stamp == nil)
    }

    /// Everything waiting on that peer goes out, on one path request.
    @Test func severalFirstSendsShareOnePathRequestAndAllGetStamped() async throws {
        let me = Identity(), peer = Identity()
        let requests = LockIsolated(0)
        let store = await makeNode(me, TestClock(), countingPathRequestsIn: requests)
        let one = message(from: me, to: peer, "one"), two = message(from: me, to: peer, "two")

        await store.send(.sendMessage(message: one, fallbackToPropagation: false))
        await store.send(.sendMessage(message: two, fallbackToPropagation: false))
        await store.send(.endpoint(.transport(.received(iface, deliveryAnnounce(of: peer, stampCost: cheapCost)))))

        let handed = LockIsolated<[Data: LXMessage]>([:])
        for _ in 0..<2 {
            await store.receive({ action in
                if case let .router(.send(m, _)) = action {
                    handed.withValue { $0[m.hash] = m }
                    return true
                }
                return false
            }, timeout: .seconds(30))
        }
        #expect(handed.value[one.hash]?.validateStamp(targetCost: cheapCost) == true)
        #expect(handed.value[two.hash]?.validateStamp(targetCost: cheapCost) == true)
        #expect(requests.value == 1)
    }

    /// The wait is bounded: with no path at all, the router's own path budget takes over. Three
    /// requests, seven seconds apart.
    @Test func aFirstSendIsHandedOverUnstampedWhenNoPathArrives() async throws {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let requests = LockIsolated(0)
        let store = await makeNode(me, clock, countingPathRequestsIn: requests)
        let m = message(from: me, to: peer)

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        await clock.advance(by: .seconds(20))
        #expect(await isHandedOver(store, m) == false, "still inside the wait")
        #expect(requests.value == 3)

        await clock.advance(by: .seconds(1))
        let handed = try #require(await nextHandedToRouter(store))
        #expect(handed.hash == m.hash)
        #expect(handed.stamp == nil)
    }

    /// Suspended, nothing can answer a path request, so time spent held must not use up the wait.
    /// Otherwise the message goes out unstamped as soon as the app comes back.
    @Test func timeSpentHeldDoesNotUseUpTheWait() async throws {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let store = await makeNode(me, clock)
        let m = message(from: me, to: peer)

        await store.send(.holdOutbound(true))
        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        // Stepped, because each elapsed interval arms the next timer only once it has been received.
        for _ in 0..<8 {
            await clock.advance(by: .seconds(7))
            await store.skipReceivedActions(strict: false)
        }
        #expect(await isHandedOver(store, m) == false, "held: the wait must not have run out")

        await store.send(.holdOutbound(false))
        await store.send(.endpoint(.transport(.received(iface, deliveryAnnounce(of: peer, stampCost: cheapCost)))))
        let handed = try #require(await nextHandedToRouter(store))
        #expect(handed.validateStamp(targetCost: cheapCost))
    }

    @Test func cancellingAWaitingSendReportsCancelledAndNeverSendsIt() async {
        let me = Identity(), peer = Identity()
        let store = await makeNode(me, TestClock())
        let m = message(from: me, to: peer)

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        await store.send(.cancelOutbound(messageHash: m.hash))
        await store.receive(.delegate(.deliveryCancelled(messageHash: m.hash)))
        // Checked here because the router also refuses a cancelled message, which would hide a leak.
        #expect(store.state.waitingForPeerCost.isEmpty)

        await store.send(.endpoint(.transport(.received(iface, deliveryAnnounce(of: peer, stampCost: nil)))))
        #expect(await isHandedOver(store, m) == false)
        #expect(store.state.inFlightDeliveryStamps.isEmpty)
    }

    @Test func cancelDeliveryStampsFailsAWaitingSendAndNeverSendsIt() async {
        let me = Identity(), peer = Identity()
        let store = await makeNode(me, TestClock())
        let m = message(from: me, to: peer)

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        await store.send(.cancelDeliveryStamps)
        await store.receive(.delegate(.deliveryFailed(messageHash: m.hash)))

        await store.send(.endpoint(.transport(.received(iface, deliveryAnnounce(of: peer, stampCost: nil)))))
        #expect(await isHandedOver(store, m) == false)
    }

    /// A cost restored from a previous session needs no path to be known, so nothing waits.
    @Test func aPersistedCostSkipsTheWait() async throws {
        let me = Identity(), peer = Identity()
        let store = await makeNode(me, TestClock())
        let m = message(from: me, to: peer)
        await store.send(.rehydrateLearnedPeers([m.destinationHash: LXMFNode.LearnedPeer(
            displayName: nil, stampCost: cheapCost, supportsCompression: true, learnedAt: Date(timeIntervalSince1970: sentAt))]))

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        let handed = try #require(await nextHandedToRouter(store))
        #expect(handed.validateStamp(targetCost: cheapCost))
    }

    /// The peer's phone is off for longer than the wait. The router then holds the message unstamped,
    /// and nothing has gone out: there was no path. The announce that finally brings the path brings
    /// the cost, so what goes out must carry a stamp at that cost. Before the fix the router's next
    /// retry sent the unstamped copy, and an enforcing peer proved it and dropped it.
    @Test func aSendHandedOverAfterTheWaitIsStampedWhenTheCostArrivesLater() async throws {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let transmitted = Transmitted()
        let store = await makeNode(me, clock, recordingIn: transmitted)
        let m = message(from: me, to: peer)

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        await waitOutTheCostWait(store, clock)
        #expect(await isHandedOver(store, m), "the wait ran out, so the router holds it")
        #expect(transmitted.opportunistic.value.isEmpty, "no path yet, so nothing can have gone out")

        await clock.advance(by: .seconds(9))     // 30 s in; the router's first retry is due at 31 s
        await store.skipReceivedActions(strict: false)
        await hearAnnounce(store, of: peer, stampCost: cheapCost)
        await waitForStampedHandOver(store)
        for _ in 0..<4 {
            await clock.advance(by: .seconds(10))
            await store.skipReceivedActions(strict: false)
        }

        #expect(!transmitted.opportunistic.value.isEmpty, "once the path is known the message must go out")
        for payload in transmitted.opportunistic.value {
            let copy = LXMessage.fromOpportunistic(destinationHash: m.destinationHash, payload: payload)
            #expect(copy?.hash == m.hash)
            #expect(copy?.validateStamp(targetCost: cheapCost) == true, "every copy on the wire must be stamped")
        }
    }

    /// The same for a message too big for one packet: the router queues it behind a link it cannot
    /// open without a path, and drains the queue when the link comes up.
    @Test func aLinkSendHandedOverAfterTheWaitIsStampedWhenTheCostArrivesLater() async throws {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let transmitted = Transmitted()
        let store = await makeNode(me, clock, recordingIn: transmitted)
        let m = message(from: me, to: peer, "large " + String(repeating: "x", count: 1000))
        #expect(!m.opportunisticFits)

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        await waitOutTheCostWait(store, clock)
        #expect(await isHandedOver(store, m))

        await clock.advance(by: .seconds(9))
        await store.skipReceivedActions(strict: false)
        await hearAnnounce(store, of: peer, stampCost: cheapCost)
        await waitForStampedHandOver(store)
        await store.skipReceivedActions(strict: false)
        await store.send(.endpoint(.delegate(.linkEstablished(linkID: Data(repeating: 0x4C, count: 16),
                                                               destinationHash: m.destinationHash))))
        await store.skipReceivedActions(strict: false)

        #expect(!transmitted.overLink.value.isEmpty, "the link drains the queue")
        for data in transmitted.overLink.value {
            let copy = LXMessage.unpack(data)
            #expect(copy?.hash == m.hash)
            #expect(copy?.validateStamp(targetCost: cheapCost) == true, "every copy on the wire must be stamped")
        }
    }

    /// Cancelled while its copy is back in a stamp search: one `deliveryCancelled`, and nothing sent.
    @Test func cancellingASendWhileItIsReStampedReportsCancelledOnceAndSendsNothing() async {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let transmitted = Transmitted()
        let store = await makeNode(me, clock, recordingIn: transmitted)
        let m = message(from: me, to: peer)
        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        await waitOutTheCostWait(store, clock)
        await hearAnnounce(store, of: peer, stampCost: slowCost)
        #expect(store.state.inFlightDeliveryStamps == [m.hash], "the copy is back in a stamp search")

        await store.send(.cancelOutbound(messageHash: m.hash))
        for _ in 0..<(2 * LXMFDelivery.maxAttempts) {
            await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
            await store.skipReceivedActions(strict: false)
        }
        #expect(transmitted.terminals.value == [described(.deliveryCancelled(messageHash: m.hash))])
        #expect(transmitted.opportunistic.value.isEmpty)
        #expect(!store.state.router.hasOutboundState(for: m.hash))
    }

    /// `.cancelDeliveryStamps` fails a send whose copy is back in a stamp search, once, and the router
    /// stops counting the copy.
    @Test func cancelDeliveryStampsFailsASendWhileItIsReStampedOnce() async {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let transmitted = Transmitted()
        let store = await makeNode(me, clock, recordingIn: transmitted)
        let m = message(from: me, to: peer)
        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        await waitOutTheCostWait(store, clock)
        await hearAnnounce(store, of: peer, stampCost: slowCost)
        #expect(store.state.inFlightDeliveryStamps == [m.hash], "the copy is back in a stamp search")

        await store.send(.cancelDeliveryStamps)
        for _ in 0..<(2 * LXMFDelivery.maxAttempts) {
            await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
            await store.skipReceivedActions(strict: false)
        }
        #expect(transmitted.terminals.value == [described(.deliveryFailed(messageHash: m.hash))])
        #expect(transmitted.opportunistic.value.isEmpty)
        #expect(!store.state.router.hasOutboundState(for: m.hash), "the router must stop counting the copy")
    }

    /// A second send to the same peer waits for its cost while the first, handed over unstamped
    /// after the wait, is re-stamped at the announce. `.cancelDeliveryStamps` fails both, and neither
    /// may go out afterwards. The second search used to be chained after the first, so it started
    /// after the cancel, out of its reach, and the message was handed over after its failure.
    @Test func cancelDeliveryStampsDuringAReStampAlsoStopsASendThatWasWaiting() async throws {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let transmitted = Transmitted()
        let store = await makeNode(me, clock, recordingIn: transmitted)
        let first = message(from: me, to: peer, "first")
        await store.send(.sendMessage(message: first, fallbackToPropagation: false))
        await waitOutTheCostWait(store, clock)
        let second = message(from: me, to: peer, "second")
        await store.send(.sendMessage(message: second, fallbackToPropagation: false))
        #expect(store.state.waitingForPeerCost[second.destinationHash]?.count == 1)

        await hearAnnounce(store, of: peer, stampCost: quickButNotInstantCost)
        await store.send(.cancelDeliveryStamps)
        // A search the cancel missed finishes within this, and hands its message over.
        try await Task.sleep(for: .seconds(20))
        await store.skipReceivedActions(strict: false)

        // Under load a search can finish before the cancel; that message is simply sent. What the
        // cancel caught must be failed once, and nothing may be handed over after it.
        let log = transmitted.handOvers.value
        let cancelAt = try #require(log.firstIndex(of: nil))
        let handedBefore = Set(log[..<cancelAt].compactMap { $0 })
        #expect(log[(cancelAt + 1)...].isEmpty, "handed over after the cancel")
        let caught = [first, second].filter { !handedBefore.contains($0.hash) }
        // Both searches beat the cancel (heavy load): no race this run, and nothing to check.
        guard !caught.isEmpty else { return }
        #expect(transmitted.terminals.value.sorted() == caught.map { described(.deliveryFailed(messageHash: $0.hash)) }.sorted())
        for m in caught {
            #expect(!store.state.router.hasOutboundState(for: m.hash), "a failed message must not be handed over")
        }
    }

    /// A message ends once. If a copy already succeeded, abandoning its delivery-stamp search
    /// reports nothing more; if a propagated copy is still out, that copy decides the outcome.
    /// Neither combination is reachable from the public actions today (a send that waits for its
    /// cost is never fallback-eligible), so the router state is constructed.
    @Test func cancelDeliveryStampsLeavesTheOutcomeToTheMessagesOtherCopy() async throws {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let transmitted = Transmitted()
        let succeeded = message(from: me, to: peer, "succeeded")
        let stillOut = message(from: me, to: peer, "still out")
        let store = await makeNode(me, clock, recordingIn: transmitted) { state in
            state.router.succeededMessages.insert(succeeded.hash)
            state.router.pendingPropagatedCopies.insert(stillOut.hash)
        }
        await store.send(.sendMessage(message: succeeded, fallbackToPropagation: false))
        await store.send(.sendMessage(message: stillOut, fallbackToPropagation: false))
        #expect(Set(store.state.inFlightDeliveryStamps) == [succeeded.hash, stillOut.hash])

        await store.send(.cancelDeliveryStamps)
        await store.skipReceivedActions(strict: false)
        #expect(transmitted.terminals.value.isEmpty, "the other copy decides")

        // A stamped delivery copy a search hands over after the cancel is refused.
        await store.send(.router(.send(message: stillOut, desiredMethod: .opportunistic)))
        #expect(store.state.router.pendingDeliveries[.delivery(stillOut.hash)] == nil)

        await store.send(.router(.propagatedCopyFailed(messageHash: stillOut.hash)))
        await store.skipReceivedActions(strict: false)
        #expect(transmitted.terminals.value == [described(.deliveryFailed(messageHash: stillOut.hash))])
    }
}

/// Run the first-send wait out: three path requests, seven seconds apart. Stepped, because each
/// elapsed interval arms the next timer only once it has been received.
@MainActor
private func waitOutTheCostWait(_ store: TestStoreOf<LXMFNode>, _ clock: TestClock<Duration>) async {
    for _ in 0..<LXMFNode.peerCostPathRequests {
        await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
        await store.skipReceivedActions(strict: false)
    }
    #expect(store.state.waitingForPeerCost.isEmpty, "the wait must have run out")
    #expect(!store.state.unstampedHandOvers.isEmpty, "handed over unstamped, with the cost still unknown")
}

/// Deliver the peer's announce and wait until Transport has learned its path: the announce is
/// checked in an effect, so the state does not show it when `send` returns.
@MainActor
private func hearAnnounce(_ store: TestStoreOf<LXMFNode>, of peer: Identity, stampCost: Double?) async {
    await store.send(.endpoint(.transport(.received(iface, deliveryAnnounce(of: peer, stampCost: stampCost)))))
    await store.receive({ action in
        if case .endpoint(.delegate(.pathLearned)) = action { return true }
        return false
    }, timeout: .seconds(5))
}

/// A real search runs in real time, outside the test clock. Waits for its stamped hand-over, which
/// fails the test if it never comes. (Polling `store.state` does not work: the TestStore delivers an
/// effect's actions while it is awaited.)
@MainActor
private func waitForStampedHandOver(_ store: TestStoreOf<LXMFNode>) async {
    await store.receive({ action in
        if case let .router(.send(m, _)) = action, m.stamp != nil { return true }
        return false
    }, timeout: .seconds(10))
}
