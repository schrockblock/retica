import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Transfer-aware delivery end to end: two LXMFNodes over mocked TCP (the harness of
// LXMFNodeSinglePacketProofEndToEndTests), with a pump that forwards every frame either node writes.

/// SHA-256-derived bytes: bzip2 cannot shrink them, so a 3 MB payload really is three segments.
private func transferIncompressible(count: Int) -> Data {
    var result = Data()
    result.reserveCapacity(count)
    var i = 0
    while result.count < count {
        let chunk = Crypto.fullHash(Data([0x3E, UInt8(i & 0xff), UInt8((i >> 8) & 0xff), UInt8((i >> 16) & 0xff)]))
        result.append(contentsOf: chunk.prefix(min(chunk.count, count - result.count)))
        i += 1
    }
    return result
}

@MainActor
private func nextFrame(_ sent: LockIsolated<[Data]>, after count: Int) async -> Data {
    for _ in 0..<1_000 where sent.value.count <= count { await Task.yield() }
    #expect(sent.value.count == count + 1, "expected exactly one new frame")
    return sent.value.last ?? Data()
}

private func isTCPSend(_ action: LXMFNode.Action) -> Bool {
    if case .endpoint(.tcpClient(.interface(.send))) = action { return true }
    return false
}

@MainActor
private final class TransferPair {
    let clock = TestClock()
    let aIdentity = Identity()
    let bIdentity = Identity()
    let sentA = LockIsolated<[Data]>([])
    let sentB = LockIsolated<[Data]>([])
    var a: TestStore<LXMFNode.State, LXMFNode.Action>!
    var b: TestStore<LXMFNode.State, LXMFNode.Action>!
    var eventsA: AsyncStream<TCPEvent>.Continuation!
    var eventsB: AsyncStream<TCPEvent>.Continuation!
    /// How many frames of each node's output the pump has delivered to the other.
    var forwardedA = 0
    var forwardedB = 0

    var bDeliveryHash: Data { LXMessage.deliveryHash(identityHash: bIdentity.hash) }

    init(configureA: (inout LXMFNode.State) -> Void = { _ in }) {
        let nodeA = TransferPair.makeNode("a", aIdentity, sentA, clock, configureA)
        a = nodeA.0
        eventsA = nodeA.1
        let nodeB = TransferPair.makeNode("b", bIdentity, sentB, clock, { _ in })
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
            // Wall time follows the test clock, so a link's measured RTT is test-clock time.
            $0.date = DateGenerator {
                let (seconds, attoseconds) = TestClock<Duration>.Instant().duration(to: clock.now).components
                return Date(timeIntervalSince1970: 1700000000.5 + Double(seconds) + Double(attoseconds) / 1e18)
            }
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
        forwardedA = sentA.value.count
        forwardedB = sentB.value.count
    }

    /// A message from A to B carrying `bytes` as a file-attachment field (LXMF field 5).
    func attachmentMessage(bytes: Data) -> LXMessage {
        LXMessage.create(source: aIdentity, destinationHash: bDeliveryHash, timestamp: 1700000000.5,
                         title: Data("file".utf8), content: Data("see attachment".utf8),
                         fields: [.init(5, .array([.array([.string("blob.bin"), .bin(bytes)])]))])
    }

    /// Deliver every frame either node has written to the other, oldest first, until `done()` holds.
    /// `bToADelay` is advanced on the shared clock before each B→A frame (B's requests and proofs),
    /// so every request round costs that much test-clock time. Returns false if nothing moved for
    /// 200 idle rounds (a stalled transfer), true once `done()` holds.
    func pump(bToADelay: Duration = .zero,
              keepA: () -> Bool = { false }, keepB: () -> Bool = { false },
              skipEvery: Int = 50,
              sample: () -> Void = {}, until done: () -> Bool) async -> Bool {
        var idle = 0
        var rounds = 0
        while !done() {
            var moved = false
            while forwardedA < sentA.value.count {
                let frame = sentA.value[forwardedA]
                forwardedA += 1
                eventsB.yield(.data(frame))
                moved = true
                await Task.megaYield()
            }
            while forwardedB < sentB.value.count {
                let frame = sentB.value[forwardedB]
                forwardedB += 1
                if bToADelay > .zero { await clock.advance(by: bToADelay) }
                eventsA.yield(.data(frame))
                moved = true
                await Task.megaYield()
            }
            sample()
            rounds += 1
            // `p.a.state`/`p.b.state` are TestStore snapshots: they only advance when explicitly
            // synced (`.receive()` or `skipReceivedActions()`), so `until`/`sample` see a snapshot up
            // to `skipEvery` rounds stale between syncs. That is fine for a transfer spanning
            // thousands of rounds (the 3 MB / slow-link tests): 50-round staleness is a rounding
            // error against the whole. It is NOT fine for a small, fast transfer (this file's cancel
            // test, ~200 KB) whose entire run can finish inside one 50-round window — the snapshot
            // would jump straight from "just started" to "already fully delivered", overshooting a
            // threshold like "progress >= 0.4" without ever observing it. Callers with a
            // fast-finishing pump pass a smaller `skipEvery` to keep the snapshot's staleness small
            // relative to the whole transfer.
            if rounds % skipEvery == 0 {
                if !keepA() { await a.skipReceivedActions(strict: false) }
                if !keepB() { await b.skipReceivedActions(strict: false) }
            }
            if moved {
                idle = 0
            } else {
                idle += 1
                if idle > 200 { return false }
                await Task.megaYield()
            }
        }
        return true
    }

    func stop() async {
        await a.send(.endpoint(.stop))
        await b.send(.endpoint(.stop))
    }
}

@Test(.timeLimit(.minutes(10))) @MainActor func transferEndToEndThreeMegabytesConfirmWithMonotonicProgress() async {
    let p = TransferPair()
    await p.connectAndIntroduce()
    let msg = p.attachmentMessage(bytes: transferIncompressible(count: 3_000_000))
    #expect(msg.packed.count > 2 * LinkSession.maxEfficientSize)          // three segments
    let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
    await p.a.send(.sendMessage(message: msg, alsoViaPropagation: false))
    var outbound: [Double] = []
    var inbound: [Double] = []
    var attempts = 0
    // `pendingDeliveries[key]` does not exist yet right after `.send(.sendMessage(...))`: TestStore
    // applies only the top-level action synchronously, and the router's own `.send`/`establish`/link
    // handshake (which arms the entry once a direct link comes up) runs as later effects. So
    // "== nil" is ambiguous between "not started" and "done" — it is true on BOTH sides of the
    // transfer. `armed` disambiguates it for `until` AND for `keepA`: until it flips, `keepA()`
    // must NOT read as "done" (that would stop `skipReceivedActions` from ever draining A's queue,
    // and NOTHING else drives the link handshake's effect chain forward — freezing the pump dead).
    var armed = false
    let finished = await p.pump(
        keepA: { armed && p.a.state.router.pendingDeliveries[key] == nil },
        keepB: { p.b.state.router.seen.contains(msg.hash) },
        sample: {
            if p.a.state.router.pendingDeliveries[key] != nil { armed = true }
            if let f = p.a.state.transferProgress[key], f != outbound.last { outbound.append(f) }
            if let f = p.b.state.inboundProgress.values.first, f != inbound.last { inbound.append(f) }
            attempts = max(attempts, p.a.state.router.pendingDeliveries[key]?.attempts ?? 0)
        },
        until: { armed && p.a.state.router.pendingDeliveries[key] == nil })
    #expect(finished, "the transfer stalled before an outcome")
    await p.b.receive { action in
        guard case let .delegate(.messageReceived(m, validated, method)) = action else { return false }
        return m.hash == msg.hash && m.fields == msg.fields && validated && method == .direct
    }
    // DEVIATION (documented in the task report): the brief asserts
    // `await p.a.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))` here. That is not
    // reliable for a transfer this large: `skipReceivedActions` both refreshes the TestStore's state
    // snapshot AND clears its whole received-actions log in one non-separable step (there is no API
    // to do one without the other), and `until()` here can only become true once some periodic skip
    // call has ALREADY refreshed state to reflect completion — the SAME call that, in the same
    // stroke, discards the completion cascade's own terminal `.delegate(.deliveryConfirmed(...))`
    // action from the log before the test ever gets to `.receive()` it. This reproduced
    // deterministically for this exact payload/round-count, not as an occasional flake, so a longer
    // `.receive()` timeout does not help (verified: still absent after 10s). `succeededMessages`
    // below proves the same outcome the brief's receive would have (Ruling P8: success is proven by
    // the outcome).
    #expect(p.a.state.router.succeededMessages.contains(msg.hash))
    #expect(attempts == 1, "the message was resent mid-transfer")
    #expect(outbound.count > 10)
    #expect(outbound == outbound.sorted())
    #expect((outbound.first ?? 0) >= LXMFNode.linkActiveProgress)
    #expect(inbound.count > 10)
    #expect(inbound == inbound.sorted())
    await p.stop()
}

/// The old router resent a Resource copy every 10 s and failed it at 50 s. Ruling P3: a 1_100_000-byte
/// payload (still two 1 MB segments) with a 250 ms B→A delay spans ~250+ request rounds × 0.25 s ≈ 64 s
/// of test-clock time — past the 50 s at which the old router failed a Resource copy — while each round
/// stays inside the receiver watchdog (≥ 0.45 s). It must be sent once and confirmed.
@Test(.timeLimit(.minutes(10))) @MainActor func transferEndToEndSlowLinkOutlastsTheOldRetrySaga() async {
    let p = TransferPair()
    await p.connectAndIntroduce()
    let msg = p.attachmentMessage(bytes: transferIncompressible(count: 1_100_000))
    let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
    await p.a.send(.sendMessage(message: msg, alsoViaPropagation: false))
    var outbound: [Double] = []
    var attempts = 0
    // See the monotonic-progress test: `pendingDeliveries[key]` is nil both before the direct link
    // comes up and after the copy succeeds, so `armed` disambiguates "not started" from "done".
    var armed = false
    let finished = await p.pump(
        bToADelay: .milliseconds(250),
        keepA: { armed && p.a.state.router.pendingDeliveries[key] == nil },
        sample: {
            if p.a.state.router.pendingDeliveries[key] != nil { armed = true }
            if let f = p.a.state.transferProgress[key], f != outbound.last { outbound.append(f) }
            attempts = max(attempts, p.a.state.router.pendingDeliveries[key]?.attempts ?? 0)
        },
        until: { armed && p.a.state.router.pendingDeliveries[key] == nil })
    #expect(finished, "the transfer stalled before an outcome")
    // DEVIATION (documented in the task report, same reason as the monotonic-progress test): the
    // brief's `await p.a.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))` is not
    // reliable here — `until()` can only become true once a periodic `skipReceivedActions` call has
    // already refreshed state to reflect completion, and that same call discards the completion
    // cascade's own terminal delegate action from the log first. Reproduced deterministically.
    // `succeededMessages` proves the same outcome (Ruling P8).
    #expect(p.a.state.router.succeededMessages.contains(msg.hash))
    let elapsed = TestClock<Duration>.Instant().duration(to: p.clock.now)
    #expect(elapsed > .seconds(50), "the harness did not slow the transfer enough to matter")
    #expect(attempts == 1, "the message was resent mid-transfer")
    #expect(outbound == outbound.sorted())
    await p.stop()
}

@Test(.timeLimit(.minutes(5))) @MainActor func transferEndToEndCancelMidTransferFailsThePeersTransfer() async {
    let p = TransferPair()
    await p.connectAndIntroduce()
    let msg = p.attachmentMessage(bytes: transferIncompressible(count: 200_000))
    let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
    await p.a.send(.sendMessage(message: msg, alsoViaPropagation: false))
    // DEVIATION (documented in the task report): the brief's `p.pump(until: ...)` calls below use
    // the harness's default `skipEvery: 50`. Empirically that is too coarse for this 200 KB
    // transfer: `p.a.state`/`p.b.state` only advance when a periodic `skipReceivedActions` syncs
    // them, and this transfer's entire run (start to full delivery) can complete inside one
    // 50-round window. Verified directly: at round 50 (the very first sync point) the snapshot
    // still showed no progress at all, and the very same sync immediately revealed the transfer
    // already fully delivered to B — the "progress >= 0.4" threshold was never observed because the
    // snapshot jumped straight from "not started" to "already done". `skipEvery: 5` keeps the
    // snapshot's staleness small relative to this transfer's much shorter overall length.
    let halfway = await p.pump(skipEvery: 5, until: { (p.a.state.transferProgress[key] ?? 0) >= 0.4 })
    #expect(halfway, "the transfer stalled before it was worth cancelling")
    #expect(p.b.state.endpoint.links.contains { !$0.transfers.isEmpty }, "B is mid-transfer")
    await p.a.send(.cancelOutbound(messageHash: msg.hash))
    await p.a.receive(.delegate(.deliveryCancelled(messageHash: msg.hash)))
    // DEVIATION (documented in the task report): `cancelOutbound`'s reducer merges TWO sibling
    // effects — the `.deliveryCancelled` delegate above, and a separate `.cancelResource` delegate
    // that is what actually clears the link's `transfers` entry a few hops later. Receiving the
    // former does not guarantee the latter's cascade has also been synced into this snapshot yet.
    // One more explicit sync (harmless here — nothing else is being asserted by action identity at
    // this exact point) settles it before checking `transfers.isEmpty`.
    await p.a.skipReceivedActions(strict: false)
    #expect(p.a.state.router.pendingDeliveries[key] == nil)
    #expect(p.a.state.endpoint.links.allSatisfy { $0.transfers.isEmpty })
    // Deliver the RESOURCE_ICL (and whatever was already in flight) until B's transfer is gone.
    let peerFailed = await p.pump(skipEvery: 5, until: { p.b.state.endpoint.links.allSatisfy { $0.transfers.isEmpty } })
    #expect(peerFailed, "the cancel never reached B")
    #expect(!p.b.state.router.seen.contains(msg.hash))
    #expect(p.b.state.inboundProgress.isEmpty)
    #expect(!p.a.state.router.succeededMessages.contains(msg.hash))
    await p.stop()
}

/// With a propagation node configured, both copies report their own success and nothing reports a
/// failure. The node's side of its transfer is played by the delegates the endpoint would emit.
@Test(.timeLimit(.minutes(5))) @MainActor func transferEndToEndWithAPropagationNodeBothCopiesSucceed() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let pnLink = Data(repeating: 0xC0, count: 16)
    let p = TransferPair(configureA: { state in
        state.router.outboundPropagationNode = pn
        state.router.directLinks[pn] = .active(linkID: pnLink)
        state.directLinks[pn] = pnLink
        state.endpoint.transport.learned[pn] = LearnedDestination(
            identity: Identity(),
            appData: PNAnnounce(timebase: 0, nodeState: true, perTransferLimit: 1000, perSyncLimit: 1000,
                                targetStampCost: 4, stampCostFlexibility: 0, peeringCost: 0).packed,
            ratchet: nil, interfaceID: InterfaceID("pn"), hops: 1, nextHop: nil, announceEmitted: 0)
    })
    await p.connectAndIntroduce()
    let msg = p.attachmentMessage(bytes: transferIncompressible(count: 100_000))
    #expect(msg.packed.count < 1000 * 1000)                                 // under the node's limit
    let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
    await p.a.send(.sendMessage(message: msg, alsoViaPropagation: true))
    #expect(p.a.state.router.pendingPropagatedCopies.contains(msg.hash))
    await p.a.receive { if case let .router(.sendViaPropagation(m, _)) = $0 { return m.hash == msg.hash }; return false }
    #expect(p.a.state.router.linkResourceInFlight[pnLink] == .propagated(msg.hash))
    let pnResource = Data(repeating: 0x9C, count: 32)
    await p.a.send(.endpoint(.delegate(.resourceProgress(linkID: pnLink, resourceHash: pnResource, role: .sender,
                                                         bytesDone: 0, bytesTotal: 10, segment: 1, segments: 1))))
    await p.a.send(.endpoint(.delegate(.resourceConcluded(linkID: pnLink, resourceHash: pnResource))))
    await p.a.receive(.delegate(.propagationAccepted(messageHash: msg.hash)))
    // See the monotonic-progress test: `armed` disambiguates "the direct copy has not been armed
    // yet" from "it armed and then finished", both of which read as `pendingDeliveries[key] == nil`.
    // DEVIATION (documented in the task report): also passes `skipEvery: 5` — see the cancel test's
    // note; this 100 KB direct copy is small enough to finish inside a single default 50-round
    // staleness window, which lost the `armed` transition entirely (verified: without this, the
    // pump reports a stall rather than a false success).
    var armed = p.a.state.router.pendingDeliveries[key] != nil
    let finished = await p.pump(keepA: { armed && p.a.state.router.pendingDeliveries[key] == nil },
                                skipEvery: 5,
                                sample: { if p.a.state.router.pendingDeliveries[key] != nil { armed = true } },
                                until: { armed && p.a.state.router.pendingDeliveries[key] == nil })
    #expect(finished, "the direct transfer stalled before an outcome")
    // DEVIATION (documented in the task report, same reason as the monotonic-progress test): the
    // completion cascade's terminal delegate action is deterministically gone by the time `until()`
    // can see the transfer as done — the same `skipReceivedActions` call that refreshes state to
    // reveal completion also discards the log entry the brief's `.receive()` would find. Verified
    // via state instead (Ruling P8).
    #expect(p.a.state.router.succeededMessages.contains(msg.hash))
    #expect(p.a.state.router.pendingDeliveries.isEmpty)
    #expect(p.a.state.router.pendingPropagatedCopies.isEmpty)
    await p.stop()
}
