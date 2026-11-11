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

/// Logs what a service node's own client delivers.
private struct ServiceRecorder: Reducer {
    typealias State = LXMFServiceNode.State
    typealias Action = LXMFServiceNode.Action
    let delivered: LockIsolated<[Data]>
    var body: some ReducerOf<Self> {
        Reduce { _, action in
            if case let .client(.delegate(.messageReceived(message, _, _))) = action {
                delivered.withValue { $0.append(message.content) }
            }
            return .none
        }
        LXMFServiceNode()
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

    let aDelivered = LockIsolated<[Data]>([])
    let a = Store(initialState: serviceState(aIdentity, TransportEndpoint.State(
        tcpServer: TCPServerEndpoint.State(port: 4242, profile: .tcp)))) {
        ServiceRecorder(delivered: aDelivered)
    } withDependencies: {
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

    // Fix round 1 (C1, probes A/A2/B): A's own client syncs from B, its propagation node, while A's
    // sync job syncs to B, its peer, at the same time. Two links from A to B, one each: neither reads
    // the other's answers, so A's client gets its message and B gets A's new one.
    let aDelivery = LXMessage.deliveryHash(identityHash: aIdentity.hash)
    a.send(.client(.registerDelivery))
    c.send(.endpoint(.transport(.rehydrateKnownDestinations([
        aDelivery: KnownDestination(identity: Identity(publicKey: aIdentity.publicKey)!, appData: nil, lastHeard: t0),
    ]))))
    let forA = Data("from C, held at B for A".utf8)
    c.send(.sendViaPropagation(destinationHash: aDelivery, title: Data("a".utf8), content: forA))
    #expect(await eventually { b.pn.store.entries(forDestination: aDelivery).count == 1 })
    let second = Data("a second one through A".utf8)
    s.send(.sendViaPropagation(destinationHash: cDelivery, title: Data("u".utf8), content: second))
    #expect(await eventually { a.pn.store.count == 2 })
    let tid2 = try #require(a.pn.store.transientIds.first { $0 != tid })
    #expect(a.peering.peers[bProp]?.unhandled == [tid2])

    a.send(.client(.setPropagationNode(destinationHash: bProp)))
    a.send(.client(.syncFromPropagationNode))
    a.send(.peerSyncTick)
    #expect(await eventually { aDelivered.value.contains(forA) })
    #expect(await eventually { b.pn.store.contains(transientId: tid2) })
    #expect(await eventually { a.peering.peers[bProp]?.handled.contains(tid2) == true })
    #expect(await eventually { a.peering.peers[bProp]?.state == .idle })
    #expect(a.client.router.propagationTransferState == .complete)

    a.send(.client(.endpoint(.stop)))
    b.send(.client(.endpoint(.stop)))
    s.send(.endpoint(.stop))
    c.send(.endpoint(.stop))
}

/// Final review I3, whole slice: S sends B's OWN client a message through A. A syncs it to B, its
/// peer, and B delivers it to its inbox (reference `lxmf_propagation`, LXMRouter.py:2852-2866)
/// instead of storing it and distributing it to its other peers. It is handled for A (so A never
/// offers it again) and nothing is left for B's other peer.
///
///   S (LXMFNode) --tcp--> A (service node, listener) <--tcp-- B (service node, its client registered)
@MainActor @Test func aPeerSyncedMessageForTheNodesOwnClientIsDeliveredNotStored() async throws {
    let w = Wire()
    let aIdentity = Identity(), bIdentity = Identity(), sIdentity = Identity()
    let aProp = propagationHash(aIdentity), bProp = propagationHash(bIdentity)
    let bDelivery = LXMessage.deliveryHash(identityHash: bIdentity.hash)
    let elsewhere = propagationHash(Identity())

    func common(_ d: inout DependencyValues) {
        d.continuousClock = TestClock()
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
    let bDelivered = LockIsolated<[Data]>([])
    let b = Store(initialState: serviceState(bIdentity, TransportEndpoint.State(
        tcpClients: [TCPEndpoint.State(host: "a", port: 4242, reconnectOnDrop: false)]))) {
        ServiceRecorder(delivered: bDelivered)
    } withDependencies: {
        common(&$0)
        $0.tcpConnection = TCPConnection(open: { _, _ in w.bClient.stream },
                                         send: { d in w.aListener.continuation.yield(.data(Wire.bAtA, d)) },
                                         close: { })
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

    a.send(.client(.endpoint(.start)))
    w.aListener.continuation.yield(.started)
    b.send(.client(.endpoint(.start)))
    w.bClient.continuation.yield(.connected)
    w.aListener.continuation.yield(.accepted(Wire.bAtA))
    s.send(.endpoint(.start))
    w.sClient.continuation.yield(.connected)
    w.aListener.continuation.yield(.accepted(Wire.sAtA))
    #expect(await eventually { a.client.endpoint.transport.interfaces.count == 2
        && b.client.endpoint.transport.interfaces.count == 1 && s.endpoint.transport.interfaces.count == 1 })

    a.send(.setNodeMode(true))
    b.send(.setNodeMode(true))
    b.send(.client(.registerDelivery))
    #expect(await eventually { a.peering.peers[bProp] != nil && b.peering.peers[aProp] != nil })
    #expect(await eventually { s.endpoint.learned[aProp] != nil })
    // B has a second peer, never reachable here: what B distributes would show in its unhandled set.
    b.send(.rehydrate(entries: [], peers: [PNPeerTable.Peer(destinationHash: elsewhere, alive: true, lastHeard: t0)]))
    #expect(b.peering.peers[elsewhere] != nil)

    // S uploads a message for B's own client to A.
    s.send(.endpoint(.transport(.rehydrateKnownDestinations([
        bDelivery: KnownDestination(identity: Identity(publicKey: bIdentity.publicKey)!, appData: nil, lastHeard: t0),
    ]))))
    s.send(.setPropagationNode(destinationHash: aProp))
    let content = Data("for B's own inbox".utf8)
    s.send(.sendViaPropagation(destinationHash: bDelivery, title: Data("t".utf8), content: content))
    #expect(await eventually { a.pn.store.count == 1 })
    let tid = try #require(a.pn.store.transientIds.first)

    // A syncs it to B: the first tick mines a key, the next one syncs.
    a.send(.peerSyncTick)
    #expect(await eventually { a.peering.peers[bProp]?.peeringKey != nil })
    a.send(.peerSyncTick)
    #expect(await eventually { bDelivered.value.contains(content) })
    #expect(await eventually { a.peering.peers[bProp]?.handled.contains(tid) == true })
    #expect(!b.pn.store.contains(transientId: tid), "not stored at B")
    #expect(b.pn.store.count == 0)
    #expect(b.peering.peers[elsewhere]?.unhandled.isEmpty == true, "not queued for B's other peer")
    #expect(b.peering.peers[aProp]?.handled.contains(tid) == true, "handled for A, the sender")
    #expect(b.client.router.downloadedTransientIds.contains(tid))
    #expect(bDelivered.value == [content])

    a.send(.client(.endpoint(.stop)))
    b.send(.client(.endpoint(.stop)))
    s.send(.endpoint(.stop))
}
