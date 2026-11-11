import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport
@testable import ReTiCAInterfaces

// Whole-slice probe for propagation-node peering. Per-task tests drive ONE service node and play the
// other side by hand; this one runs every piece for real and lets them talk: two `LXMFServiceNode`s
// with node mode on, joined by a TCP server/client pair, plus a client of each (`LXMFNode`). The
// bytes each node writes are fed straight into the other's socket stream (an in-memory "loopback":
// the listener and connection dependencies are the only stubs), so every packet crosses the real
// interface framing, `Transport`, the link plane, the command interpreter and the peer's `/offer`
// responder.
//
//   S (LXMFNode) --tcp--> A (service node, listener) <--tcp-- B (service node, listener) <--tcp-- C (LXMFNode)
//
// S sends C a message through A. A and B peered from each other's announces; A syncs the message to
// B; C downloads it from B with `/get`.

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// Logs what a client node delivers.
private struct ClientRecorder: Reducer {
    typealias State = LXMFNode.State
    typealias Action = LXMFNode.Action
    let delivered: LockIsolated<[Data]>
    var body: some ReducerOf<Self> {
        Reduce { _, action in
            if case let .delegate(.messageReceived(message, _, _)) = action {
                delivered.withValue { $0.append(message.content) }
            }
            return .none
        }
        LXMFNode()
    }
}

/// The in-memory sockets: what one side writes arrives on the other's stream.
private final class Wire: @unchecked Sendable {
    let aListener = AsyncStream<TCPListenerEvent>.makeStream()
    let bListener = AsyncStream<TCPListenerEvent>.makeStream()
    let sClient = AsyncStream<TCPEvent>.makeStream()
    let bClient = AsyncStream<TCPEvent>.makeStream()
    let cClient = AsyncStream<TCPEvent>.makeStream()
    static let sAtA = TCPConnID(1), bAtA = TCPConnID(2), cAtB = TCPConnID(3)
}

@MainActor
private func eventually(_ seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func propagationHash(_ identity: Identity) -> Data {
    Destination.hash(identityHash: identity.hash, appName: LXMessage.appName, aspects: ["propagation"])
}

/// Cheap costs throughout so every search is quick: propagation stamps at 2, peering keys at 2.
private func serviceState(_ identity: Identity, _ endpoint: TransportEndpoint.State) -> LXMFServiceNode.State {
    LXMFServiceNode.State(identity: identity, endpoint: endpoint, targetStampCost: 2,
                          peering: .init(peeringCost: 2))
}

@MainActor @Test func twoServiceNodesPeerAndSyncAClientMessageEndToEnd() async throws {
    let w = Wire()
    let aIdentity = Identity(), bIdentity = Identity(), sIdentity = Identity(), cIdentity = Identity()
    let aProp = propagationHash(aIdentity), bProp = propagationHash(bIdentity)
    let cDelivery = LXMessage.deliveryHash(identityHash: cIdentity.hash)

    func common(_ d: inout DependencyValues) {
        d.continuousClock = TestClock()          // no timer fires: the sync job is ticked by hand
        d.date = .constant(t0)
        d.transportDate = .constant(t0)
        d.uuid = .incrementing
        d.withRandomNumberGenerator = WithRandomNumberGenerator(Seeded(state: 3))
    }

    let a = Store(initialState: serviceState(aIdentity, TransportEndpoint.State(
        tcpServer: TCPServerEndpoint.State(port: 4242, profile: .tcp)))) { LXMFServiceNode() } withDependencies: {
        common(&$0)
        $0.tcpListener = TCPListener(listen: { _ in w.aListener.stream },
                                     send: { conn, d in
                                         if conn == Wire.sAtA { w.sClient.continuation.yield(.data(d)) }
                                         else { w.bClient.continuation.yield(.data(d)) }
                                     },
                                     close: { _ in }, stop: { })
    }
    let b = Store(initialState: serviceState(bIdentity, TransportEndpoint.State(
        tcpClients: [TCPEndpoint.State(host: "a", port: 4242, reconnectOnDrop: false)],
        tcpServer: TCPServerEndpoint.State(port: 4243, profile: .tcp)))) { LXMFServiceNode() } withDependencies: {
        common(&$0)
        $0.tcpConnection = TCPConnection(open: { _, _ in w.bClient.stream },
                                         send: { d in w.aListener.continuation.yield(.data(Wire.bAtA, d)) },
                                         close: { })
        $0.tcpListener = TCPListener(listen: { _ in w.bListener.stream },
                                     send: { _, d in w.cClient.continuation.yield(.data(d)) },
                                     close: { _ in }, stop: { })
    }
    let s = Store(initialState: LXMFNode.State(identity: sIdentity,
                                               endpoint: tcpDriverEndpoint(host: "a", port: 4242, reconnectOnDrop: false))) {
        LXMFNode()
    } withDependencies: {
        common(&$0)
        $0.tcpConnection = TCPConnection(open: { _, _ in w.sClient.stream },
                                         send: { d in w.aListener.continuation.yield(.data(Wire.sAtA, d)) },
                                         close: { })
    }
    let delivered = LockIsolated<[Data]>([])
    let c = Store(initialState: LXMFNode.State(identity: cIdentity,
                                               endpoint: tcpDriverEndpoint(host: "b", port: 4243, reconnectOnDrop: false))) {
        ClientRecorder(delivered: delivered)
    } withDependencies: {
        common(&$0)
        $0.tcpConnection = TCPConnection(open: { _, _ in w.cClient.stream },
                                         send: { d in w.bListener.continuation.yield(.data(Wire.cAtB, d)) },
                                         close: { })
    }

    // Bring up the sockets.
    a.send(.client(.endpoint(.start)))
    w.aListener.continuation.yield(.started)
    b.send(.client(.endpoint(.start)))
    w.bListener.continuation.yield(.started)
    w.bClient.continuation.yield(.connected)
    w.aListener.continuation.yield(.accepted(Wire.bAtA))
    s.send(.endpoint(.start))
    w.sClient.continuation.yield(.connected)
    w.aListener.continuation.yield(.accepted(Wire.sAtA))
    c.send(.endpoint(.start))
    w.cClient.continuation.yield(.connected)
    w.bListener.continuation.yield(.accepted(Wire.cAtB))
    #expect(await eventually { a.client.endpoint.transport.interfaces.count == 2 && b.client.endpoint.transport.interfaces.count == 2
        && s.endpoint.transport.interfaces.count == 1 && c.endpoint.transport.interfaces.count == 1 })

    // Node mode on: each announces, and each hears the other and auto-peers with it.
    a.send(.setNodeMode(true))
    b.send(.setNodeMode(true))
    #expect(await eventually { a.peering.peers[bProp] != nil && b.peering.peers[aProp] != nil })
    #expect(await eventually { s.endpoint.learned[aProp] != nil && c.endpoint.learned[bProp] != nil })
    c.send(.registerDelivery)

    // S uploads a message for C to A. S knows C's key the way a host restores it.
    s.send(.endpoint(.transport(.rehydrateKnownDestinations([
        cDelivery: KnownDestination(identity: Identity(publicKey: cIdentity.publicKey)!, appData: nil, lastHeard: t0),
    ]))))
    s.send(.setPropagationNode(destinationHash: aProp))
    let content = Data("through two propagation nodes".utf8)
    s.send(.sendViaPropagation(destinationHash: cDelivery, title: Data("t".utf8), content: content))
    #expect(await eventually { a.pn.store.count == 1 })
    let tid = try #require(a.pn.store.transientIds.first)
    #expect(a.peering.peers[bProp]?.unhandled == [tid])

    // A's sync job: the first tick mines a key for B, the next one syncs.
    a.send(.peerSyncTick)
    #expect(await eventually { a.peering.peers[bProp]?.peeringKey != nil })
    a.send(.peerSyncTick)
    #expect(await eventually { b.pn.store.contains(transientId: tid) })
    #expect(await eventually { a.peering.peers[bProp]?.handled.contains(tid) == true })
    #expect(a.peering.peers[bProp]?.unhandled.isEmpty == true)
    // B accounts the inbound sync: handled for A, the sender, so B never offers it back.
    #expect(b.peering.peers[aProp]?.handled.contains(tid) == true)
    #expect(b.peering.peers[aProp]?.unhandled.contains(tid) == false)
    #expect(await eventually { a.peering.peers[bProp]?.state == .idle })

    // C downloads it from B.
    c.send(.setPropagationNode(destinationHash: bProp))
    c.send(.syncFromPropagationNode)
    #expect(await eventually { delivered.value.contains(content) })

    a.send(.client(.endpoint(.stop)))
    b.send(.client(.endpoint(.stop)))
    s.send(.endpoint(.stop))
    c.send(.endpoint(.stop))
}
