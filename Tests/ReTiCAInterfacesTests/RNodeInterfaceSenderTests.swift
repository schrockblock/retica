import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

/// `count` bytes, distinct per `seed`.
private func packet(_ count: Int, seed: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &+ seed &* 31) })
}

private extension RNodeInterfaceHarness {
    /// Lets every effect that can run, run: the caller then asserts what did NOT happen.
    func settle() async {
        for _ in 0..<50 { await Task.megaYield() }
    }

    /// Polls until `condition` holds on the store's state, without failing: the caller's
    /// `#expect` judges. `store.state` moves only on a `send` or a `receive`/skip, so each poll
    /// first takes in the actions the effects sent.
    func waitUntil(_ condition: (RNodeInterface.State) -> Bool) async {
        for _ in 0..<400 {
            await store.skipReceivedActions(strict: false)
            if condition(store.state) { return }
            await Task.megaYield()
        }
    }

    func receiveSent() async {
        await store.receive { if case .packetSent = $0 { return true }; return false }
    }
}

/// A host around the real interface that reduces a `.send` and a second action in ONE burst,
/// before the sender's task has started and registered its cancel id: the send escapes the
/// second action's `.cancel(id: .sending)`.
private struct RNodeSendBurstHost: Reducer {
    struct State: Equatable { var rnode: RNodeInterface.State }

    @CasePathable
    enum Action: Equatable {
        case rnode(RNodeInterface.Action)
        /// `.concatenate(.send(.send(packet)), .send(next))`.
        case sendThen(Data, RNodeInterface.Action)
    }

    var body: some ReducerOf<Self> {
        Reduce { _, action in
            guard case let .sendThen(packet, next) = action else { return .none }
            return .concatenate(.send(.rnode(.send(packet))), .send(.rnode(next)))
        }
        Scope(state: \.rnode, action: \.rnode) { RNodeInterface() }
    }
}

@MainActor
private struct RNodeSendBurstHarness {
    let store: TestStore<RNodeSendBurstHost.State, RNodeSendBurstHost.Action>
    let calls: LockIsolated<[RNodeMockCall]>
    /// `gates[i]` holds the driver's (i+1)-th `send`; later sends return at once.
    let gates: [RNodeSendGate]

    var sent: [Data] { calls.value.rnodeSentPackets }
    var counters: RNodeCounters { store.state.rnode.counters }

    func waitForSends(_ count: Int) async {
        for _ in 0..<400 where sent.count < count { await Task.megaYield() }
    }

    func settle() async {
        for _ in 0..<50 { await Task.megaYield() }
    }

    func connect() async {
        await store.send(.rnode(.driverEvent(.connected(rnodeTestReport))))
    }

    func shutdown() async {
        for gate in gates { gate.open() }
        await store.send(.rnode(.stop))
        await store.skipReceivedActions(strict: false)
    }
}

/// Events are delivered with `store.send`; every driver session's stream ends at once.
/// `sendResults` are returned by successive driver sends (then `true`). The first `heldSends`
/// driver sends each wait for their own gate.
@MainActor
private func makeRNodeSendBurstHarness(sendResults: [Bool] = [], heldSends: Int = 0) -> RNodeSendBurstHarness {
    let calls = LockIsolated<[RNodeMockCall]>([])
    let results = LockIsolated(sendResults)
    let gates = (0..<heldSends).map { _ in RNodeSendGate() }
    let store = TestStore(
        initialState: RNodeSendBurstHost.State(rnode: RNodeInterface.State(config: rnodeTestConfig))
    ) {
        RNodeSendBurstHost()
    } withDependencies: {
        $0.rnodeDriver = RNodeDriver(
            start: { config in
                calls.withValue { $0.append(.start(config)) }
                return AsyncStream { $0.finish() }
            },
            send: { packet in
                let index = calls.withValue { calls -> Int in
                    calls.append(.send(packet))
                    return calls.rnodeSentPackets.count - 1
                }
                if index < gates.count { await gates[index].wait() }
                return results.withValue { $0.isEmpty ? true : $0.removeFirst() }
            },
            stop: { calls.withValue { $0.append(.stop) } })
    }
    store.exhaustivity = .off
    store.timeout = .seconds(5)
    return RNodeSendBurstHarness(store: store, calls: calls, gates: gates)
}

@MainActor @Suite struct RNodeInterfaceSenderTests {
    @Test func sendPassesThePacketUnchanged() async {
        let h = await makeOnlineRNodeInterface()
        let p = packet(200, seed: 1)
        await h.store.send(.send(p))
        await h.receiveSent()
        #expect(h.calls.value.last == .send(p))
        await stopRNodeInterface(h)
    }

    /// The store has no clock dependency: nothing can delay the first packet.
    @Test func firstPacketGoesOutAtOnce() async {
        let h = await makeOnlineRNodeInterface(holdSends: true)
        let p = packet(100, seed: 1)
        await h.store.send(.send(p))
        await h.waitForSends(1)
        #expect(h.sent == [p])
        h.gate.open()
        await stopRNodeInterface(h)
    }

    /// Stop-and-wait (§5.6): while the driver's `send` hasn't returned, nothing else goes out.
    @Test func nextPacketWaitsForTheDriverToReturn() async {
        let h = await makeOnlineRNodeInterface(holdSends: true)
        let packets = (1...3).map { packet(100, seed: $0) }
        for p in packets { await h.store.send(.send(p)) }
        await h.waitForSends(1)
        await h.settle()
        #expect(h.sent == [packets[0]])
        #expect(h.store.state.queuedPacketCount == 2)
        h.gate.open()
        await h.waitForSends(3)
        #expect(h.sent == packets)
        await stopRNodeInterface(h)
    }

    /// One failed send among them: still each packet once, in order.
    @Test func everyPacketGoesOutExactlyOnceInOrder() async {
        let h = await makeOnlineRNodeInterface(sendResults: [true, false])
        let packets = (1...10).map { packet(150, seed: $0) }
        for p in packets { await h.store.send(.send(p)) }
        await h.waitUntil { $0.counters.sent + $0.counters.sendFailed >= 10 }
        await h.settle()
        #expect(h.sent == packets)
        await stopRNodeInterface(h)
    }

    /// Eleven packets, the second failing: `sent` counts the ten the driver accepted.
    @Test func sentCountsEachAcceptedPacket() async {
        let h = await makeOnlineRNodeInterface(sendResults: [true, false])
        for seed in 1...11 { await h.store.send(.send(packet(150, seed: seed))) }
        await h.waitUntil { $0.counters.sent + $0.counters.sendFailed >= 11 }
        await h.settle()
        await h.store.skipReceivedActions(strict: false)
        #expect(h.store.state.counters.sent == 10)
        await stopRNodeInterface(h)
    }

    @Test func sendFailureCountsSendFailed() async {
        let h = await makeOnlineRNodeInterface(sendResults: [false, true])
        await h.store.send(.send(packet(100, seed: 1)))
        await h.store.send(.send(packet(100, seed: 2)))
        await h.waitUntil { $0.counters.sent + $0.counters.sendFailed >= 2 }
        #expect(h.store.state.counters.sendFailed == 1)
        await stopRNodeInterface(h)
    }

    @Test func sendFailureDropsThePacketAndContinues() async {
        let h = await makeOnlineRNodeInterface(sendResults: [false, true])
        let p1 = packet(100, seed: 1)
        let p2 = packet(100, seed: 2)
        await h.store.send(.send(p1))
        await h.store.send(.send(p2))
        await h.waitForSends(2)
        await h.settle()
        #expect(h.sent == [p1, p2])
        await stopRNodeInterface(h)
    }

    /// One in flight, 64 queued, the 66th dropped.
    @Test func queueHoldsAtMost64Packets() async {
        let h = await makeOnlineRNodeInterface(holdSends: true)
        for seed in 0..<66 { await h.store.send(.send(packet(100, seed: seed))) }
        await h.waitForSends(1)
        #expect(h.sent.count == 1)
        #expect(h.store.state.queuedPacketCount == 64)
        #expect(h.store.state.counters.queueFull == 1)
        h.gate.open()
        await stopRNodeInterface(h)
    }

    @Test func aPacketOf508BytesIsSent() async {
        let h = await makeOnlineRNodeInterface()
        let p = packet(508, seed: 1)
        await h.store.send(.send(p))
        await h.waitForSends(1)
        #expect(h.sent == [p])
        await stopRNodeInterface(h)
    }

    @Test func aPacketOf509BytesIsOversize() async {
        let h = await makeOnlineRNodeInterface()
        await h.store.send(.send(packet(509, seed: 1)))
        await h.settle()
        #expect(h.sent.isEmpty)
        #expect(h.store.state.counters.oversize == 1)
        #expect(h.store.state.counters.queueFull == 0)
        await stopRNodeInterface(h)
    }

    @Test func sendWhileOfflineIsDropped() async {
        let h = makeRNodeInterface()
        await h.store.send(.start)
        await h.store.send(.send(packet(100, seed: 1)))
        await h.settle()
        #expect(h.sent.isEmpty)
        #expect(h.store.state.queuedPacketCount == 0)
        #expect(h.store.state.counters == RNodeCounters())
        await stopRNodeInterface(h)
    }

    /// One in flight and five queued when the radio drops. After the reconnect only the new
    /// packet goes out, even once the driver returns (a kept queue would drain behind it).
    @Test func disconnectClearsTheQueue() async {
        let h = await makeOnlineRNodeInterface(holdSends: true)
        for seed in 1...6 { await h.store.send(.send(packet(100, seed: seed))) }
        await h.waitForSends(1)
        #expect(h.store.state.queuedPacketCount == 5)
        h.radio.yield(.disconnected(reason: nil))
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        #expect(h.store.state.queuedPacketCount == 0)
        h.radio.yield(.connected(rnodeTestReport))
        await h.store.receive { if case .delegate(.online) = $0 { return true }; return false }
        let before = h.sent.count
        let n = packet(100, seed: 99)
        await h.store.send(.send(n))
        h.gate.open()
        await h.waitUntil { $0.counters.sent >= 1 }
        await h.settle()
        #expect(Array(h.sent[before...]) == [n])
        await stopRNodeInterface(h)
    }

    /// The `.sending` cancel and the cleared queue inside `.unavailable`'s return: a restarted
    /// radio sends only what the host sends it now.
    @Test func unavailableClearsTheQueue() async {
        let h = await makeOnlineRNodeInterface(holdSends: true)
        for seed in 1...6 { await h.store.send(.send(packet(100, seed: seed))) }
        await h.waitForSends(1)
        h.radio.yield(.unavailable(.poweredOff))
        await h.store.receive { $0 == .delegate(.adapterUnavailable(.poweredOff)) }
        #expect(h.store.state.queuedPacketCount == 0)
        await h.store.send(.start)
        await h.waitForStarts(2)
        h.radio.yield(.connected(rnodeTestReport))
        await h.store.receive { if case .delegate(.online) = $0 { return true }; return false }
        let before = h.sent.count
        let n = packet(100, seed: 99)
        await h.store.send(.send(n))
        h.gate.open()
        await h.waitForSends(before + 1)
        await h.settle()
        #expect(Array(h.sent[before...]) == [n])
        await stopRNodeInterface(h)
    }

    /// One in flight and three queued at `.stop`. The restarted radio sends nothing until a new
    /// `.send`, and then only that packet.
    @Test func stopAndStartDoesNotResendTheOldQueue() async {
        let h = await makeOnlineRNodeInterface(holdSends: true)
        for seed in 1...4 { await h.store.send(.send(packet(100, seed: seed))) }
        await h.waitForSends(1)
        #expect(h.store.state.queuedPacketCount == 3)
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await h.store.send(.start)
        await h.waitForStarts(2)
        h.radio.yield(.connected(rnodeTestReport))
        await h.store.receive { if case .delegate(.online) = $0 { return true }; return false }
        let before = h.sent.count
        h.gate.open()
        await h.settle()
        #expect(h.sent.count == before, "sent before any new .send: \(h.sent.count - before)")
        let n = packet(100, seed: 99)
        await h.store.send(.send(n))
        await h.waitForSends(before + 1)
        await h.receiveSent()
        await h.settle()
        #expect(Array(h.sent[before...]) == [n])
        await stopRNodeInterface(h)
    }

    // Review Focus 1.
    /// A `.stop` in the send's burst misses the sender's cancel id, so the send effect escapes.
    /// It must not reach the driver after the stop (the pre-send epoch guard), so the slot is
    /// idle with nothing in flight. A restarted radio sends only the new packet.
    @Test func aLateSendResultAfterStopSendsNothing() async {
        let a = packet(100, seed: 1)
        let b = packet(200, seed: 2)
        for run in 0..<5 {
            let h = makeRNodeSendBurstHarness()
            await h.store.send(.rnode(.start))
            await h.connect()
            await h.store.send(.sendThen(a, .stop))
            await h.store.receive { $0 == .rnode(.delegate(.offline(reason: nil))) }
            #expect(!h.store.state.rnode.isOnline, "run \(run)")
            #expect(h.store.state.rnode.isIdle, "run \(run)")
            await h.settle()
            #expect(h.sent.isEmpty, "run \(run): the escaped send reached the driver after the stop")
            await h.store.send(.rnode(.start))
            await h.connect()
            await h.store.send(.rnode(.send(b)))
            await h.waitForSends(1)
            await h.store.receive { if case .rnode(.packetSent) = $0 { return true }; return false }
            await h.settle()
            #expect(h.sent == [b], "run \(run)")
            await h.shutdown()
        }
    }

    // Review Focus 1.
    /// A drop in the send's burst: the send escapes, reaches the driver (a drop doesn't move the
    /// driver epoch) and returns a failure only after the reconnect, while the new session's own
    /// packet is in flight. That stale result must not release the next packet (two in flight
    /// would break stop-and-wait) nor count anything: the drop already discarded its packet.
    @Test func aStaleSendResultAfterADropReleasesNothing() async {
        let a = packet(100, seed: 1)
        let b = packet(100, seed: 2)
        let c = packet(100, seed: 3)
        for run in 0..<5 {
            let h = makeRNodeSendBurstHarness(sendResults: [false], heldSends: 2)
            await h.store.send(.rnode(.start))
            await h.connect()
            await h.store.send(.sendThen(a, .driverEvent(.disconnected(reason: nil))))
            await h.store.receive { $0 == .rnode(.delegate(.offline(reason: nil))) }
            await h.waitForSends(1)
            #expect(h.sent == [a], "run \(run): the send did not escape")
            await h.connect()
            await h.store.send(.rnode(.send(b)))
            await h.waitForSends(2)
            await h.store.send(.rnode(.send(c)))
            #expect(h.sent == [a, b], "run \(run)")
            // `a` returns (a failure) while `b` is still in flight.
            h.gates[0].open()
            await h.store.receive { if case .rnode(.packetSent(ok: false, _)) = $0 { return true }; return false }
            await h.settle()
            #expect(h.sent == [a, b], "run \(run): c went out while b was in flight")
            #expect(h.store.state.rnode.queuedPacketCount == 1, "run \(run)")
            #expect(h.counters.sent == 0, "run \(run)")
            #expect(h.counters.sendFailed == 0, "run \(run)")
            // `b` returns: now, and only now, `c` goes out.
            h.gates[1].open()
            await h.waitForSends(3)
            #expect(h.sent == [a, b, c], "run \(run)")
            for _ in 0..<400 where h.counters.sent < 2 {
                await h.store.skipReceivedActions(strict: false)
                await Task.megaYield()
            }
            #expect(h.counters.sent == 2, "run \(run)")
            #expect(h.counters.sendFailed == 0, "run \(run)")
            await h.shutdown()
        }
    }
}
