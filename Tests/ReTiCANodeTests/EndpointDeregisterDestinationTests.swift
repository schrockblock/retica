import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// `TransportEndpoint`, counting the `linkEstablished` delegates it surfaces.
private struct CountingEndpoint: Reducer {
    typealias State = TransportEndpoint.State
    typealias Action = TransportEndpoint.Action
    let established: LockIsolated<Int>

    var body: some Reducer<State, Action> {
        Reduce<State, Action> { _, action in
            if case .delegate(.linkEstablished) = action {
                established.withValue { $0 += 1 }
            }
            return .none
        }
        TransportEndpoint()
    }
}

/// Two TCP endpoints wired by hand (as in `TCPEndpointTests.twoEndpointsEstablishLinkExchangeDataAndClose`):
/// B owns `dest`, announces it, and A learns it. `bEstablished` counts B's surfaced `linkEstablished`.
@MainActor
private final class Pair {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: Identity())!
    let sentA: LockIsolated<[Data]>
    let sentB: LockIsolated<[Data]>
    let bEstablished: LockIsolated<Int>
    let a: TestStoreOf<TransportEndpoint>
    let b: TestStoreOf<TransportEndpoint>
    let eventsA: AsyncStream<TCPEvent>.Continuation
    let eventsB: AsyncStream<TCPEvent>.Continuation

    init() {
        let clock = TestClock()
        let sentA = LockIsolated<[Data]>([]), sentB = LockIsolated<[Data]>([]), bEstablished = LockIsolated(0)
        self.sentA = sentA; self.sentB = sentB; self.bEstablished = bEstablished
        (a, eventsA) = Pair.make("a", sentA, LockIsolated(0), clock)
        (b, eventsB) = Pair.make("b", sentB, bEstablished, clock)
    }

    private static func make(_ host: String, _ sent: LockIsolated<[Data]>, _ established: LockIsolated<Int>,
                             _ clock: TestClock<Duration>)
            -> (TestStoreOf<TransportEndpoint>, AsyncStream<TCPEvent>.Continuation) {
            let events = AsyncStream<TCPEvent>.makeStream()
            let store = TestStore(initialState: tcpDriverEndpoint(host: host, port: 4242, reconnectOnDrop: false)) {
                CountingEndpoint(established: established)
            } withDependencies: {
                $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                                 send: { d in sent.withValue { $0.append(d) } },
                                                 close: { })
                $0.continuousClock = clock
                $0.date = .constant(Date(timeIntervalSince1970: 0))
                $0.uuid = .incrementing
            }
            store.exhaustivity = .off
            return (store, events.continuation)
    }

    func connectAndLearn() async {
        await a.send(.start); eventsA.yield(.connected); await a.receive(\.transport.interfaceConnected)
        await b.send(.registerLocalDestination(dest))
        await b.send(.start); eventsB.yield(.connected); await b.receive(\.transport.interfaceConnected)
        await b.send(.announce(destinationHash: dest.hash, appData: nil))
        eventsA.yield(.data(sentB.value.last!))
        await a.receive(\.transport.received)
        await a.receive(\.delegate.pathLearned)
    }

    /// A opens a link; B answers the LINKREQUEST with its LRPROOF; A goes active and emits its LRRTT
    /// (NOT yet delivered to B — B's link is still half-open).
    func handshakeUpToLRRTT() async {
        await a.send(.openLink(destinationHash: dest.hash))
        await a.receive { if case .tcpClients(.element(id: _, action: .interface(.send))) = $0 { return true }; return false }
        eventsB.yield(.data(sentA.value.last!))                    // LINKREQUEST → B
        await b.receive(\.transport.received)
        await b.receive(\.transport.delegate.linkRequest)
        await b.receive { if case .tcpClients(.element(id: _, action: .interface(.send))) = $0 { return true }; return false }
        eventsA.yield(.data(sentB.value.last!))                    // LRPROOF → A
        await a.receive(\.transport.received)
        await a.receive(\.delegate.linkEstablished)
    }

    func deliverLRRTTToB() async {
        eventsB.yield(.data(sentA.value.last!))
        await b.receive(\.transport.received)
    }
}

@Suite struct EndpointDeregisterDestinationTests {

/// An established inbound link on the destination is closed (the peer is told), and a new
/// LINKREQUEST for it is no longer accepted.
@Test @MainActor func deregisteringClosesItsLinksAndRefusesNewOnes() async {
    let p = Pair()
    await p.connectAndLearn()
    await p.handshakeUpToLRRTT()
    await p.deliverLRRTTToB()
    await p.b.receive(\.delegate.linkEstablished)
    #expect(p.b.state.links.count == 1)

    let sentBefore = p.sentB.value.count
    await p.b.send(.deregisterLocalDestination(destinationHash: p.dest.hash))
    await p.b.receive(\.delegate.linkClosed)
    await p.b.skipReceivedActions(strict: false)
    #expect(p.b.state.links.isEmpty)
    #expect(p.b.state.transport.localDestinations[p.dest.hash] == nil)
    #expect(p.sentB.value.count > sentBefore)                        // a LINKCLOSE went out …
    p.eventsA.yield(.data(p.sentB.value.last!))
    await p.a.receive(\.transport.received)
    await p.a.receive(\.delegate.linkClosed)                          // … and A saw it

    // A new link attempt: B creates no link for the deregistered destination.
    await p.a.send(.openLink(destinationHash: p.dest.hash))
    await p.a.receive { if case .tcpClients(.element(id: _, action: .interface(.send))) = $0 { return true }; return false }
    p.eventsB.yield(.data(p.sentA.value.last!))
    await p.b.receive(\.transport.received)
    await p.b.skipReceivedActions(strict: false)
    #expect(p.b.state.links.isEmpty)

    await p.a.send(.stop); await p.b.send(.stop)
    await p.a.skipReceivedActions(strict: false); await p.b.skipReceivedActions(strict: false)
}

/// A link still in its handshake when the destination is deregistered never surfaces as
/// established on B: it is closed as soon as it would go active.
@Test @MainActor func aHalfOpenLinkCompletingAfterDeregistrationIsClosedNotSurfaced() async {
    let p = Pair()
    await p.connectAndLearn()
    await p.handshakeUpToLRRTT()
    #expect(p.b.state.links.count == 1)
    #expect(p.b.state.links[0].status != .active)

    await p.b.send(.deregisterLocalDestination(destinationHash: p.dest.hash))
    await p.deliverLRRTTToB()
    await p.b.receive(\.delegate.linkClosed)
    await p.b.skipReceivedActions(strict: false)
    #expect(p.bEstablished.value == 0)
    #expect(p.b.state.links.isEmpty)

    await p.a.send(.stop); await p.b.send(.stop)
    await p.a.skipReceivedActions(strict: false); await p.b.skipReceivedActions(strict: false)
}

}
