import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Two LXMFNodes over mocked TCP — the harness of LXMFNodeOpportunisticTests. A frame one node
// "sends" reaches the other only when the test yields it into that node's TCP event stream, so a
// test can deliver, drop, or reorder proofs.
//
// Depth order on the receiving node B (breadth-first `.send` processing): for an inbound DATA packet,
// `.endpoint(.proveSinglePacket)` and `.router(.received)` share a depth; the router's
// `.router(.delegate(...))` comes next, then `.delegate(.messageReceived)`, and the proof's
// `.endpoint(.tcpClient(.interface(.send)))` comes LAST. The receives below follow that order.

/// Nonisolated on purpose: it is passed as `receive`'s matcher.
private func isTCPSend(_ action: LXMFNode.Action) -> Bool {
    if case .endpoint(.tcpClient(.interface(.send))) = action { return true }
    return false
}

/// The TCP driver writes each frame from a `.run` effect, so a frame can land a moment after its
/// `.interface(.send)` action is received. Wait for exactly one new frame and return it.
@MainActor
private func nextFrame(_ sent: LockIsolated<[Data]>, after count: Int) async -> Data {
    for _ in 0..<1_000 where sent.value.count <= count { await Task.yield() }
    #expect(sent.value.count == count + 1, "expected exactly one new frame")
    return sent.value.last ?? Data()
}

@MainActor
private final class Pair {
    let clock = TestClock()
    let aIdentity = Identity()
    let bIdentity = Identity()
    let sentA = LockIsolated<[Data]>([])
    let sentB = LockIsolated<[Data]>([])
    var a: TestStore<LXMFNode.State, LXMFNode.Action>!
    var b: TestStore<LXMFNode.State, LXMFNode.Action>!
    var eventsA: AsyncStream<TCPEvent>.Continuation!
    var eventsB: AsyncStream<TCPEvent>.Continuation!

    var bDeliveryHash: Data { LXMessage.deliveryHash(identityHash: bIdentity.hash) }

    init(configureA: (inout LXMFNode.State) -> Void = { _ in }) {
        let nodeA = Pair.makeNode("a", aIdentity, sentA, clock, configureA)
        a = nodeA.0
        eventsA = nodeA.1
        let nodeB = Pair.makeNode("b", bIdentity, sentB, clock, { _ in })
        b = nodeB.0
        eventsB = nodeB.1
    }

    private static func makeNode(_ host: String, _ identity: Identity, _ sent: LockIsolated<[Data]>,
                                 _ clock: TestClock<Duration>, _ configure: (inout LXMFNode.State) -> Void)
        -> (TestStore<LXMFNode.State, LXMFNode.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        var state = LXMFNode.State(identity: identity,
                                   endpoint: TCPEndpoint.State(host: host, port: 4242, reconnectOnDrop: false))
        configure(&state)
        let store = TestStore(initialState: state) { LXMFNode() } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } },
                                             close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    /// Start both nodes, register both delivery destinations, and hand each announce to the other.
    func connectAndIntroduce() async {
        await a.send(.endpoint(.start)); eventsA.yield(.connected)
        await b.send(.endpoint(.start)); eventsB.yield(.connected)
        await a.send(.registerDelivery)
        await a.receive(isTCPSend)
        let aAnnounce = await nextFrame(sentA, after: 0)
        await b.send(.registerDelivery)
        await b.receive(isTCPSend)
        let bAnnounce = await nextFrame(sentB, after: 0)
        eventsA.yield(.data(bAnnounce))
        await a.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }
        eventsB.yield(.data(aAnnounce))
        await b.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }
    }

    func message(_ content: String) -> LXMessage {
        LXMessage.create(source: aIdentity, destinationHash: bDeliveryHash, timestamp: 1700000000.5,
                         title: Data("t".utf8), content: Data(content.utf8))
    }

    /// Nothing more may happen on A for the whole retry saga: no resend, no deliveryFailed. The
    /// advance stays under the 60 s maintenance tick, so any action here is a leftover retry.
    func expectANeverRetriesAgain() async {
        await a.skipReceivedActions(strict: false)
        a.exhaustivity = .on
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds * LXMFDelivery.maxAttempts))
        await a.send(.cancelPropagationStamps)   // an exhaustive send fails if the advance produced ANY action
        a.exhaustivity = .off
    }

    func stop() async {
        await a.send(.endpoint(.stop))
        await b.send(.endpoint(.stop))
    }
}

@Test @MainActor func proofEndToEndOpportunisticSendIsConfirmedAndNeverFails() async {
    let p = Pair()
    await p.connectAndIntroduce()
    let msg = p.message("prove me")

    let aFrames = p.sentA.value.count
    await p.a.send(.sendMessage(message: msg, alsoViaPropagation: false))
    await p.a.receive(isTCPSend)
    let data = await nextFrame(p.sentA, after: aFrames)
    #expect(p.a.state.endpoint.transport.pendingReceipts.count == 1)

    // B proves the packet on its arrival interface and delivers the message.
    let bFrames = p.sentB.value.count
    p.eventsB.yield(.data(data))
    await p.b.receive { if case .endpoint(.proveSinglePacket) = $0 { return true }; return false }
    await p.b.receive { action in
        guard case let .delegate(.messageReceived(m, _, method)) = action else { return false }
        return m.hash == msg.hash && method == .opportunistic
    }
    await p.b.receive(isTCPSend)
    let proof = await nextFrame(p.sentB, after: bFrames)

    // The proof confirms the message on A and retires every retry.
    p.eventsA.yield(.data(proof))
    await p.a.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    // No-op-send probe: a stray action left queued (e.g. a spurious deliveryFailed emitted
    // alongside the confirmation) makes this exhaustive send fail on unasserted received actions.
    p.a.exhaustivity = .on
    await p.a.send(.cancelPropagationStamps)
    p.a.exhaustivity = .off
    #expect(p.a.state.router.pendingDeliveries.isEmpty)
    #expect(p.a.state.endpoint.transport.pendingReceipts.isEmpty)
    await p.expectANeverRetriesAgain()
    await p.stop()
}

@Test @MainActor func proofEndToEndALostProofIsRecoveredByTheResend() async {
    let p = Pair()
    await p.connectAndIntroduce()
    let msg = p.message("resend me")

    var aFrames = p.sentA.value.count
    await p.a.send(.sendMessage(message: msg, alsoViaPropagation: false))
    await p.a.receive(isTCPSend)
    let first = await nextFrame(p.sentA, after: aFrames)

    // B proves the first copy, but that proof is lost on the way back.
    var bFrames = p.sentB.value.count
    p.eventsB.yield(.data(first))
    let firstProved = LockIsolated<Data?>(nil)
    await p.b.receive { action in
        guard case let .endpoint(.proveSinglePacket(hash, _, _)) = action else { return false }
        firstProved.setValue(hash)
        return true
    }
    await p.b.receive(isTCPSend)
    _ = await nextFrame(p.sentB, after: bFrames)   // dropped: never handed to A

    // A's retry sends a NEW packet with a new receipt under the same token.
    aFrames = p.sentA.value.count
    await p.clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await p.a.receive(isTCPSend)
    let resend = await nextFrame(p.sentA, after: aFrames)
    #expect(p.a.state.endpoint.transport.pendingReceipts.count == 2)

    // B's router has already seen this message and drops it — but B proves the resend anyway.
    bFrames = p.sentB.value.count
    p.eventsB.yield(.data(resend))
    let secondProved = LockIsolated<Data?>(nil)
    await p.b.receive { action in
        guard case let .endpoint(.proveSinglePacket(hash, _, _)) = action else { return false }
        secondProved.setValue(hash)
        return true
    }
    await p.b.receive(.router(.delegate(.duplicateDropped(hash: msg.hash))))
    await p.b.receive(isTCPSend)
    let proof = await nextFrame(p.sentB, after: bFrames)
    #expect(firstProved.value != nil)
    #expect(secondProved.value != nil)
    #expect(firstProved.value != secondProved.value)

    p.eventsA.yield(.data(proof))
    await p.a.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    #expect(p.a.state.router.pendingDeliveries.isEmpty)
    await p.stop()
}

/// With a propagation node, both copies report their own outcome and there is no false failure.
/// The propagated copy is handed to the router directly, exactly as `sendMessage(alsoViaPropagation:)`
/// does once its stamp search finishes; the PN's link receipt is injected as `packetDelivered`.
@Test @MainActor func proofEndToEndBothCopiesReportTheirOwnOutcomeWithNoFalseFailure() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let pnLink = Data(repeating: 0xC0, count: 16)
    let p = Pair(configureA: { state in
        state.router.outboundPropagationNode = pn
        state.router.directLinks[pn] = .active(linkID: pnLink)
    })
    await p.connectAndIntroduce()
    let msg = p.message("both ways")

    let aFrames = p.sentA.value.count
    await p.a.send(.sendMessage(message: msg, alsoViaPropagation: false))     // the delivery copy
    await p.a.receive(isTCPSend)
    let data = await nextFrame(p.sentA, after: aFrames)
    await p.a.send(.router(.sendViaPropagation(message: msg, propagationPacked: Data("small-container".utf8))))
    #expect(p.a.state.router.pendingDeliveries.count == 2)

    // The PN accepts first.
    await p.a.send(.endpoint(.delegate(.packetDelivered(token: msg.hash))))
    await p.a.receive(.delegate(.propagationAccepted(messageHash: msg.hash)))

    // Then the recipient's proof arrives: still reported as deliveryConfirmed. Exhaustive from here
    // through deliveryConfirmed, so a stray deliveryFailed alongside/before it fails the test.
    p.a.exhaustivity = .on
    let bFrames = p.sentB.value.count
    p.eventsB.yield(.data(data))
    await p.b.receive { if case .endpoint(.proveSinglePacket) = $0 { return true }; return false }
    await p.b.receive(isTCPSend)
    let proof = await nextFrame(p.sentB, after: bFrames)
    p.eventsA.yield(.data(proof))
    await p.a.receive(.endpoint(.tcpClient(.interface(.connectionEvent(.data(proof))))))
    await p.a.receive { if case .endpoint(.tcpClient(.interface(.delegate(.packetReceived)))) = $0 { return true }; return false }
    await p.a.receive({ if case .endpoint(.transport(.received)) = $0 { return true }; return false }) {
        $0.endpoint.transport.pendingReceipts = [:]
    }
    await p.a.receive(.endpoint(.transport(.delegate(.singlePacketDelivered(token: msg.hash)))))
    await p.a.receive(.endpoint(.delegate(.singlePacketDelivered(token: msg.hash))))
    await p.a.receive(.router(.opportunisticDelivered(messageHash: msg.hash))) {
        $0.router.pendingDeliveries[.delivery(msg.hash)] = nil
        $0.router.succeededMessages.insert(msg.hash)
    }
    await p.a.receive(.router(.delegate(.deliveryConfirmed(messageHash: msg.hash))))
    await p.a.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    p.a.exhaustivity = .off
    #expect(p.a.state.router.pendingDeliveries.isEmpty)
    await p.expectANeverRetriesAgain()
    await p.stop()
}
