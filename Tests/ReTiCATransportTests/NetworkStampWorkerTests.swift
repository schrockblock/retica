import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// RNS 1.6.0's network stamp worker: one `stamper_job` thread draining `WorkerQueues((32, 32))`
// (Transport.py:99-130, 209-215, 1444-1493). Queue 0 holds path requests and path-response
// announces, queue 1 ordinary announces; `get` drains queue 0 first; `put` removes a queued item
// with the same key and then, if the queue is full, drops the new item. Here: one destination or
// path-request stamp search at a time, picked the same way.

private let i0 = InterfaceID("i0")
private let stamp = Data(repeating: 7, count: 14)

/// Both stamp searches, held open until the test ends one: `finish(material)` makes the search over
/// `material` return `stamp`. A search returns nil once cancelled. `started` lists the materials in
/// the order the searches began, `cancelled` the materials of searches that ended by cancellation.
private final class SearchGate: Sendable {
    let started = LockIsolated<[Data]>([])
    let cancelled = LockIsolated<[Data]>([])
    let finished = LockIsolated<Set<Data>>([])

    func finish(_ material: Data) { finished.withValue { _ = $0.insert(material) } }

    private func hold(_ material: Data) async -> Data? {
        started.withValue { $0.append(material) }
        while !Task.isCancelled {
            if finished.value.contains(material) { return stamp }
            try? await Task.sleep(for: .milliseconds(2))
        }
        cancelled.withValue { $0.append(material) }
        return nil
    }

    /// Waits (real time, bounded) until `count` searches have been cancelled.
    func waitForCancels(_ count: Int) async {
        for _ in 0..<2500 where cancelled.value.count < count { try? await Task.sleep(for: .milliseconds(2)) }
    }

    var destination: DestinationStampGenerator {
        DestinationStampGenerator { material, _ in await self.hold(material).map { ($0, 100) } }
    }
    var pathRequest: PathRequestStampGenerator {
        PathRequestStampGenerator { material, _ in await self.hold(material) }
    }

    /// Waits (real time, bounded) until `count` searches have started.
    func waitForStarts(_ count: Int) async {
        for _ in 0..<2500 where started.value.count < count { try? await Task.sleep(for: .milliseconds(2)) }
    }
}

private final class Recorder: Sendable {
    let transmits = LockIsolated<[(InterfaceID, Data)]>([])

    var packets: [Packet] { transmits.value.compactMap { Packet(raw: $0.1) } }
}

@MainActor
private func makeStore(_ gate: SearchGate, recorder: Recorder = Recorder(),
                       destinationValue: Double = 100) -> TestStore<Transport.State, Transport.Action> {
    var initial = Transport.State()
    initial.stampDestinations = true
    initial.stampPathRequests = true
    initial.destinationValue = destinationValue      // at 100 no stamp is usable by luck
    let draws = LockIsolated(0)
    let store = TestStore(initialState: initial) {
        CombineReducers {
            Reduce<Transport.State, Transport.Action> { _, action in
                if case let .delegate(.transmit(id, raw)) = action { recorder.transmits.withValue { $0.append((id, raw)) } }
                return .none
            }
            Transport()
        }
    } withDependencies: {
        $0.continuousClock = TestClock()     // never advanced: no path-request search times out
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1000))
        $0.randomBytes = RandomBytesGenerator { n in
            Data(repeating: UInt8(truncatingIfNeeded: draws.withValue { $0 += 1; return $0 }), count: n)
        }
        $0.destinationStampGenerator = gate.destination
        $0.pathRequestStampGenerator = gate.pathRequest
    }
    store.exhaustivity = .off
    return store
}

private func newDestination(_ aspect: String) -> Destination {
    Destination(kind: .single, direction: .in, appName: "retica", aspects: [aspect], identity: Identity())!
}

private func material(_ dest: Destination) -> Data {
    dest.hash + dest.identity!.publicKey + dest.nameHash
}

private func pathRequest(for dest: Data, tag: UInt8) -> Data {
    try! Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                payload: dest + Data(repeating: 0x55, count: 16) + Data(repeating: tag, count: 16)).packed()
}

@MainActor
private func receiveDestinationEnd(_ store: TestStore<Transport.State, Transport.Action>, _ hash: Data) async {
    await store.receive({ action in
        guard case let .destinationStampSearchEnded(h, _, _) = action else { return false }
        return h == hash
    }, timeout: .seconds(10))
}

@MainActor
private func receivePathRequestEnd(_ store: TestStore<Transport.State, Transport.Action>, _ hash: Data) async {
    await store.receive({ action in
        guard case let .pathRequestStampSearchEnded(h, _, _) = action else { return false }
        return h == hash
    }, timeout: .seconds(10))
}

private func queuedAnnounceOrder(_ state: Transport.State) -> [Data] {
    state.pendingStampedAnnounces.filter { !$0.isPathResponse }.map(\.destinationHash)
}

@Suite @MainActor struct NetworkStampWorkerTests {
    /// Review Focus 5, and the preemption DIVERGENCE: our path request does not wait behind a running
    /// destination stamp search. It cancels it and starts at once; the destination's announces stay
    /// queued, its search starts again after the path request, and they go out when it ends, ahead
    /// of an announce of B queued before the path request.
    @Test func aPathRequestPreemptsARunningDestinationSearchWhichResumesAfterIt() async throws {
        let gate = SearchGate()
        let recorder = Recorder()
        let store = makeStore(gate, recorder: recorder)
        let a = newDestination("a")
        let b = newDestination("b")
        let x = Data(repeating: 0x22, count: 16)
        await store.send(.interfaceConnected(i0))
        await store.send(.registerLocalDestination(a))
        await store.send(.registerLocalDestination(b))

        await store.send(.announce(destinationHash: a.hash, appData: nil))
        await store.send(.announce(destinationHash: b.hash, appData: nil))
        await gate.waitForStarts(1)
        #expect(gate.started.value == [material(a)])

        await store.send(.requestPath(destinationHash: x))
        let tag = try #require(store.state.stampingPathRequests[x], "started at once")
        #expect(store.state.stampingDestinations.isEmpty, "A's search is cancelled")
        #expect(queuedAnnounceOrder(store.state) == [a.hash, b.hash], "A's announce stays queued")
        await gate.waitForStarts(2)
        await gate.waitForCancels(1)
        #expect(gate.started.value == [material(a), x + tag])
        #expect(gate.cancelled.value == [material(a)])

        // The path request's stamp: it goes out, and A's search starts again (not B's).
        gate.finish(x + tag)
        await receivePathRequestEnd(store, x)
        await store.skipReceivedActions(strict: false)
        #expect(store.state.stampingDestinations == [a.hash])
        await gate.waitForStarts(3)
        #expect(gate.started.value == [material(a), x + tag, material(a)])
        let sentRequest = try #require(recorder.packets.last {
            $0.destinationHash == Transport.pathRequestDestinationHash
        })
        #expect(sentRequest.payload.count == Transport.pathRequestStampedLength)
        #expect(Data(sentRequest.payload.suffix(14)) == stamp)

        // A's stamp releases A's announce; then B's search starts.
        gate.finish(material(a))
        await receiveDestinationEnd(store, a.hash)
        await store.skipReceivedActions(strict: false)
        #expect(recorder.packets.filter { $0.packetType == .announce }.map(\.destinationHash) == [a.hash])
        #expect(store.state.stampingDestinations == [b.hash])

        await store.send(.cancelNetworkStamps)
        store.exhaustivity = .on
        await store.finish()
    }

    /// A path response (a request from the network) does not preempt a running destination search.
    @Test func aPathResponseDoesNotPreemptARunningDestinationSearch() async throws {
        let gate = SearchGate()
        let store = makeStore(gate)
        let a = newDestination("a")
        let b = newDestination("b")
        await store.send(.interfaceConnected(i0))
        await store.send(.registerLocalDestination(a))
        await store.send(.registerLocalDestination(b))
        await store.send(.announce(destinationHash: a.hash, appData: nil))
        await store.send(.received(i0, pathRequest(for: b.hash, tag: 1)))
        #expect(store.state.stampingDestinations == [a.hash])
        #expect(store.state.pendingStampedAnnounces.filter(\.isPathResponse).map(\.destinationHash) == [b.hash])
        await gate.waitForStarts(1)
        await store.send(.cancelNetworkStamps)
        store.exhaustivity = .on
        await store.finish()
        #expect(gate.started.value == [material(a)])
        #expect(gate.cancelled.value == [material(a)], "cancelled only by the final cancel")
    }

    /// Our path request does not preempt a destination search that answers a path response which
    /// arrived before it: queue-0 work keeps its arrival order.
    @Test func aPathRequestWaitsBehindADestinationSearchForAnEarlierPathResponse() async throws {
        let gate = SearchGate()
        let store = makeStore(gate)
        let b = newDestination("b")
        let x = Data(repeating: 0x22, count: 16)
        await store.send(.interfaceConnected(i0))
        await store.send(.registerLocalDestination(b))
        await store.send(.received(i0, pathRequest(for: b.hash, tag: 1)))
        #expect(store.state.stampingDestinations == [b.hash])
        await gate.waitForStarts(1)
        await store.send(.requestPath(destinationHash: x))
        #expect(store.state.stampingDestinations == [b.hash], "not preempted")
        #expect(store.state.queuedPathRequestStamps.map(\.destinationHash) == [x])
        await gate.waitForStarts(2)        // returns after its bound if no second search starts
        await store.send(.cancelNetworkStamps)
        store.exhaustivity = .on
        await store.finish()
        #expect(gate.started.value == [material(b)], "B's search was not cancelled and restarted")
    }

    /// Within queue 0, arrival order decides between a waiting path response and a queued path
    /// request, either way round. A running path-request search holds the worker meanwhile.
    @Test func aPathResponseAndAPathRequestStartInArrivalOrder() async throws {
        for responseFirst in [true, false] {
            let gate = SearchGate()
            let store = makeStore(gate)
            let b = newDestination("b")
            let w = Data(repeating: 0x11, count: 16)
            let x = Data(repeating: 0x22, count: 16)
            await store.send(.interfaceConnected(i0))
            await store.send(.registerLocalDestination(b))
            await store.send(.requestPath(destinationHash: w))
            let wTag = try #require(store.state.stampingPathRequests[w])
            if responseFirst {
                await store.send(.received(i0, pathRequest(for: b.hash, tag: 1)))
                await store.send(.requestPath(destinationHash: x))
            } else {
                await store.send(.requestPath(destinationHash: x))
                await store.send(.received(i0, pathRequest(for: b.hash, tag: 1)))
            }
            #expect(Set(store.state.stampingPathRequests.keys) == [w], "responseFirst \(responseFirst)")

            gate.finish(w + wTag)
            await receivePathRequestEnd(store, w)
            if responseFirst {
                #expect(store.state.stampingDestinations == [b.hash], "B's path response arrived first")
                #expect(store.state.queuedPathRequestStamps.map(\.destinationHash) == [x])
            } else {
                #expect(Set(store.state.stampingPathRequests.keys) == [x], "X arrived first")
                #expect(store.state.stampingDestinations.isEmpty)
            }
            await store.send(.cancelNetworkStamps)
            store.exhaustivity = .on
            await store.finish()
        }
    }

    /// `.cancelDestinationStamps` hands the worker to queued path-request work.
    @Test func cancellingDestinationStampsStartsTheQueuedPathRequestSearch() async throws {
        let gate = SearchGate()
        let store = makeStore(gate)
        let b = newDestination("b")
        let x = Data(repeating: 0x22, count: 16)
        await store.send(.interfaceConnected(i0))
        await store.send(.registerLocalDestination(b))
        // B's search answers an earlier path response, so X waits behind it.
        await store.send(.received(i0, pathRequest(for: b.hash, tag: 1)))
        await store.send(.requestPath(destinationHash: x))
        #expect(store.state.stampingDestinations == [b.hash])
        #expect(store.state.stampingPathRequests.isEmpty)

        await store.send(.cancelDestinationStamps)
        #expect(store.state.stampingDestinations.isEmpty)
        #expect(store.state.pendingStampedAnnounces.isEmpty)
        #expect(Set(store.state.stampingPathRequests.keys) == [x])

        await store.send(.cancelPathRequestStamps)
        #expect(!store.state.hasNetworkStampWork)
        store.exhaustivity = .on
        await store.finish()
    }

    @Test func aNewerAnnounceReplacesTheQueuedOneAndGoesToTheBack() async throws {
        let gate = SearchGate()
        let recorder = Recorder()
        let store = makeStore(gate, recorder: recorder)
        let a = newDestination("a")
        let b = newDestination("b")
        let c = newDestination("c")
        await store.send(.interfaceConnected(i0))
        for d in [a, b, c] { await store.send(.registerLocalDestination(d)) }

        await store.send(.announce(destinationHash: a.hash, appData: nil))
        await store.send(.announce(destinationHash: b.hash, appData: Data([0x01])))
        await store.send(.announce(destinationHash: c.hash, appData: nil))
        await store.send(.announce(destinationHash: b.hash, appData: Data([0x02])))
        #expect(queuedAnnounceOrder(store.state) == [a.hash, c.hash, b.hash])
        #expect(store.state.pendingStampedAnnounces.last?.kind == .announce(appData: Data([0x02]), interface: nil))

        gate.finish(material(a))
        await receiveDestinationEnd(store, a.hash)
        #expect(store.state.stampingDestinations == [c.hash], "B moved behind C")
        gate.finish(material(c))
        await receiveDestinationEnd(store, c.hash)
        #expect(store.state.stampingDestinations == [b.hash])
        gate.finish(material(b))
        await receiveDestinationEnd(store, b.hash)
        await store.skipReceivedActions(strict: false)
        let bAnnounces = recorder.packets.filter { $0.packetType == .announce && $0.destinationHash == b.hash }
        #expect(bAnnounces.count == 1, "the replaced announce is not sent")
        #expect(bAnnounces.map { Data($0.payload.dropFirst(148).dropLast(18)) } == [Data([0x02])])
        await gate.waitForStarts(3)
        #expect(gate.started.value == [material(a), material(c), material(b)])

        store.exhaustivity = .on
        await store.finish()
    }

    @Test func aNewerPathRequestReplacesTheQueuedOneWithItsTagAndGoesToTheBack() async throws {
        let gate = SearchGate()
        let recorder = Recorder()
        let store = makeStore(gate, recorder: recorder)
        let w = Data(repeating: 0x11, count: 16)
        let x = Data(repeating: 0x22, count: 16)
        let y = Data(repeating: 0x33, count: 16)
        await store.send(.interfaceConnected(i0))
        await store.send(.requestPath(destinationHash: w))       // holds the worker
        let wTag = try #require(store.state.stampingPathRequests[w])

        await store.send(.requestPath(destinationHash: x))
        let oldTag = try #require(store.state.queuedPathRequestStamps.first?.tag)
        await store.send(.requestPath(destinationHash: y))
        await store.send(.requestPath(destinationHash: x))
        #expect(store.state.queuedPathRequestStamps.map(\.destinationHash) == [y, x])
        let newTag = try #require(store.state.queuedPathRequestStamps.last?.tag)
        #expect(newTag != oldTag)

        gate.finish(w + wTag)
        await receivePathRequestEnd(store, w)
        let yTag = try #require(store.state.stampingPathRequests[y], "Y is now first")
        gate.finish(y + yTag)
        await receivePathRequestEnd(store, y)
        #expect(store.state.stampingPathRequests == [x: newTag])
        gate.finish(x + newTag)
        await receivePathRequestEnd(store, x)
        await store.skipReceivedActions(strict: false)

        let xRequests = recorder.packets.filter {
            $0.destinationHash == Transport.pathRequestDestinationHash && Data($0.payload.prefix(16)) == x
        }
        #expect(xRequests.count == 1)
        #expect(xRequests.map { Data($0.payload.dropFirst(32).prefix(16)) } == [newTag], "the newer request's tag")
        await gate.waitForStarts(3)
        #expect(gate.started.value == [w + wTag, y + yTag, x + newTag])

        store.exhaustivity = .on
        await store.finish()
    }

    /// Path requests and path responses share reference's priority-0 queue of 32; a full queue drops
    /// the NEW item, and a replacement frees its own slot. The announce queue is apart.
    @Test func theSharedPathRequestQueueIsBoundedAndDropsTheNewItem() async throws {
        let gate = SearchGate()
        let store = makeStore(gate)
        let a = newDestination("a")
        let b = newDestination("b")
        await store.send(.interfaceConnected(i0))
        await store.send(.registerLocalDestination(a))
        await store.send(.registerLocalDestination(b))
        await store.send(.announce(destinationHash: a.hash, appData: nil))

        // The first path request preempts A's search and holds the worker; 32 of the rest queue.
        let targets = (0..<41).map { Data(repeating: UInt8($0 + 1), count: 16) }
        for t in targets { await store.send(.requestPath(destinationHash: t)) }
        #expect(Transport.stampedPathResponseQueueLimit == 32)
        #expect(Set(store.state.stampingPathRequests.keys) == [targets[0]])
        #expect(store.state.queuedPathRequestStamps.map(\.destinationHash) == Array(targets[1...32]),
                "the oldest 32 stay")

        // A path response for B finds the shared queue full.
        await store.send(.received(i0, pathRequest(for: b.hash, tag: 1)))
        #expect(store.state.pendingStampedAnnounces.filter(\.isPathResponse).isEmpty)
        // An announce of B goes to the other queue.
        await store.send(.announce(destinationHash: b.hash, appData: nil))
        #expect(queuedAnnounceOrder(store.state) == [a.hash, b.hash])

        // A replacement still fits, at the back.
        await store.send(.requestPath(destinationHash: targets[1]))
        #expect(store.state.queuedPathRequestStamps.map(\.destinationHash)
                == Array(targets[2...32]) + [targets[1]])

        await store.send(.cancelNetworkStamps)
        #expect(!store.state.hasNetworkStampWork)
        store.exhaustivity = .on
        await store.finish()
    }

    /// A stamp the host hands back for a destination whose search is still queued releases what waits
    /// for it at once; the running search of another destination goes on.
    @Test func aStampRehydratedForAQueuedDestinationReleasesItWithoutASearch() async throws {
        let gate = SearchGate()
        let recorder = Recorder()
        let store = makeStore(gate, recorder: recorder, destinationValue: 8)
        let a = newDestination("a")
        let b = newDestination("b")
        let bStamp = try #require(await NetworkStamp.generate(material: material(b), cost: 8)).stamp
        await store.send(.interfaceConnected(i0))
        await store.send(.registerLocalDestination(a))
        await store.send(.registerLocalDestination(b))
        await store.send(.announce(destinationHash: a.hash, appData: nil))
        await store.send(.announce(destinationHash: b.hash, appData: nil))
        #expect(queuedAnnounceOrder(store.state) == [a.hash, b.hash])

        await store.send(.rehydrateDestinationStamp(destinationHash: b.hash, stamp: bStamp))
        await store.skipReceivedActions(strict: false)
        #expect(queuedAnnounceOrder(store.state) == [a.hash])
        #expect(store.state.stampingDestinations == [a.hash], "A's search goes on")
        let bAnnounces = recorder.packets.filter { $0.packetType == .announce && $0.destinationHash == b.hash }
        #expect(bAnnounces.map { Data($0.payload.suffix(18).dropFirst(2).prefix(14)) } == [bStamp])

        await store.send(.cancelNetworkStamps)
        store.exhaustivity = .on
        await store.finish()
        #expect(gate.started.value.allSatisfy { $0 != material(b) }, "no search for B")
    }

    /// Cancelling one kind of search lets the worker go on to the other kind.
    @Test func cancellingPathRequestStampsStartsTheQueuedDestinationSearch() async throws {
        let gate = SearchGate()
        let store = makeStore(gate)
        let a = newDestination("a")
        let x = Data(repeating: 0x22, count: 16)
        await store.send(.interfaceConnected(i0))
        await store.send(.registerLocalDestination(a))
        await store.send(.requestPath(destinationHash: x))
        await store.send(.requestPath(destinationHash: Data(repeating: 0x23, count: 16)))
        await store.send(.announce(destinationHash: a.hash, appData: nil))
        #expect(Set(store.state.stampingPathRequests.keys) == [x])
        #expect(store.state.stampingDestinations.isEmpty)

        await store.send(.cancelPathRequestStamps)
        #expect(store.state.stampingPathRequests.isEmpty)
        #expect(store.state.queuedPathRequestStamps.isEmpty)
        #expect(store.state.stampingDestinations == [a.hash])

        await store.send(.cancelDestinationStamps)
        #expect(!store.state.hasNetworkStampWork)
        store.exhaustivity = .on
        await store.finish()
    }
}
