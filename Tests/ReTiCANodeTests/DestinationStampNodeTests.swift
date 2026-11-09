import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Host-facing wiring for RNS 1.6.0 destination stamps: the endpoint's stop cancels a search, the
// generated stamp reaches the host so it can persist it, and LXMF registers its destinations with
// LXMF 1.3.0's link cost of 3.25 (LXMRouter.py:53-54, 422, 634).

@Suite @MainActor struct DestinationStampNodeTests {
    @Test func stoppingTheEndpointCancelsADestinationStampSearch() async {
        let dest = Destination(kind: .single, direction: .in, appName: "retica", aspects: ["stop"], identity: Identity())!
        var initial = TransportEndpoint.State()
        initial.transport.stampDestinations = true
        initial.transport.destinationValue = 100      // cannot finish here
        let store = TestStore(initialState: initial) { TransportEndpoint() } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 0))
        }
        store.exhaustivity = .off
        await store.send(.registerLocalDestination(dest))
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.transport.stampingDestinations == [dest.hash])
        await store.send(.stop)
        await store.skipReceivedActions(strict: false)
        #expect(store.state.transport.stampingDestinations.isEmpty)
        #expect(store.state.transport.pendingStampedAnnounces.isEmpty)
        // A search still running (value 100) would keep its effect alive past `finish`.
        store.exhaustivity = .on
        await store.finish()
    }

    /// The network stamp worker: one search running (X's path-request stamp, held open), the
    /// announces of A and B and a path request for Y queued. The stop cancels the running search and
    /// empties both queues, and starts nothing that was queued.
    @Test func stoppingTheEndpointCancelsTheRunningNetworkStampSearchAndEmptiesBothQueues() async {
        let a = Destination(kind: .single, direction: .in, appName: "retica", aspects: ["a"], identity: Identity())!
        let b = Destination(kind: .single, direction: .in, appName: "retica", aspects: ["b"], identity: Identity())!
        let x = Data(repeating: 0x22, count: 16)
        let y = Data(repeating: 0x33, count: 16)
        let started = LockIsolated<[Data]>([])
        // Held open until cancelled, so the search is certainly running at the stop.
        let held: @Sendable (Data) async -> Void = { material in
            started.withValue { $0.append(material) }
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
        }
        var initial = TransportEndpoint.State()
        initial.transport.stampDestinations = true
        initial.transport.stampPathRequests = true
        initial.transport.destinationValue = 100
        let store = TestStore(initialState: initial) { TransportEndpoint() } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.destinationStampGenerator = DestinationStampGenerator { material, _ in await held(material); return nil }
            $0.pathRequestStampGenerator = PathRequestStampGenerator { material, _ in await held(material); return nil }
        }
        store.exhaustivity = .off
        await store.send(.transport(.interfaceConnected(InterfaceID("i0"), .default)))
        await store.send(.registerLocalDestination(a))
        await store.send(.registerLocalDestination(b))
        await store.send(.announce(destinationHash: a.hash, appData: nil))
        await store.send(.announce(destinationHash: b.hash, appData: nil))
        // X preempts A's search and runs; Y queues behind it.
        await store.send(.requestPath(destinationHash: x))
        await store.send(.requestPath(destinationHash: y))
        await store.skipReceivedActions(strict: false)
        #expect(Set(store.state.transport.stampingPathRequests.keys) == [x])
        #expect(store.state.transport.queuedPathRequestStamps.map(\.destinationHash) == [y])
        #expect(store.state.transport.pendingStampedAnnounces.map(\.destinationHash) == [a.hash, b.hash])

        await store.send(.stop)
        await store.skipReceivedActions(strict: false)
        #expect(store.state.transport.stampingDestinations.isEmpty)
        #expect(store.state.transport.stampingPathRequests.isEmpty)
        #expect(store.state.transport.queuedPathRequestStamps.isEmpty)
        #expect(store.state.transport.pendingStampedAnnounces.isEmpty)
        // The held search returns only when cancelled: one still running would outlive `finish`.
        store.exhaustivity = .on
        await store.finish()
        #expect(!started.value.contains { $0.prefix(16) == y }, "the queued path request never started")
        #expect(!started.value.dropFirst(2).contains { $0 == started.value.first }, "nor A's search again")
    }

    @Test func theGeneratedStampReachesTheHostAndARehydratedOneIsUsed() async throws {
        let dest = Destination(kind: .single, direction: .in, appName: "retica", aspects: ["host"], identity: Identity())!
        var initial = TransportEndpoint.State()
        initial.transport.stampDestinations = true
        initial.transport.destinationValue = 8
        let store = TestStore(initialState: initial) { TransportEndpoint() } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 0))
        }
        store.exhaustivity = .off
        await store.send(.registerLocalDestination(dest))
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        let reported = LockIsolated<(Data, Data, Double)?>(nil)
        await store.receive({ action in
            guard case let .delegate(.destinationStampGenerated(h, s, v)) = action else { return false }
            reported.setValue((h, s, v))
            return true
        }, timeout: .seconds(20))
        let (hash, stamp, value) = try #require(reported.value)
        #expect(hash == dest.hash)
        #expect(value >= 8)

        // A fresh endpoint given that stamp through the unified action uses it with no search.
        let second = TestStore(initialState: initial) { TransportEndpoint() } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 0))
        }
        second.exhaustivity = .off
        await second.send(.registerLocalDestination(dest))
        await second.send(.rehydrateDestinationStamp(destinationHash: hash, stamp: stamp))
        await second.skipReceivedActions(strict: false)
        #expect(second.state.transport.destinationStamps[dest.hash] == stamp)
        await second.send(.announce(destinationHash: dest.hash, appData: nil))
        await second.skipReceivedActions(strict: false)
        #expect(second.state.transport.stampingDestinations.isEmpty)
    }

    @Test func lxmfRegistersItsDeliveryDestinationWithTheReferenceLinkCost() async throws {
        #expect(LXMFDelivery.deliveryLinkCost == 3.25)
        let identity = Identity()
        let store = TestStore(initialState: LXMFNode.State(
            identity: identity, endpoint: TCPEndpoint.State(host: "h", port: 1, reconnectOnDrop: false))
        ) { LXMFNode() } withDependencies: {
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        await store.send(.registerDelivery)
        await store.skipReceivedActions(strict: false)
        let hash = try #require(store.state.deliveryDestinationHash)
        #expect(store.state.endpoint.transport.localLinkCosts[hash] == 3.25)
    }

    @Test func propagationDestinationsAreRegisteredWithTheReferenceLinkCost() async throws {
        #expect(LXMFPropagation.propagationLinkCost == 3.25)
        let pn = TestStore(initialState: PNNode.State(
            identity: Identity(), endpoint: TCPEndpoint.State(host: "pn", port: 4242, reconnectOnDrop: false),
            targetStampCost: 4, peeringCost: 0)
        ) { PNNode() } withDependencies: {
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
            $0.uuid = .incrementing
        }
        pn.exhaustivity = .off
        await pn.send(.registerPropagation)
        await pn.skipReceivedActions(strict: false)
        let pnHashes = Array(pn.state.endpoint.transport.localDestinations.keys)
        try #require(pnHashes.count == 1)
        #expect(pn.state.endpoint.transport.localLinkCosts[pnHashes[0]] == 3.25)

        var initial = LXMFServiceNode.State(
            identity: Identity(), endpoint: tcpDriverEndpoint(host: "h", port: 4242, reconnectOnDrop: false),
            targetStampCost: 12)
        initial.nodeModeEnabled = true
        let service = TestStore(initialState: initial) { LXMFServiceNode() } withDependencies: {
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
            $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        }
        service.exhaustivity = .off
        await service.send(.registerPropagation)
        await service.skipReceivedActions(strict: false)
        let served = try #require(service.state.client.propagationDestinationHash)
        #expect(service.state.client.endpoint.transport.localLinkCosts[served] == 3.25)
    }
}
