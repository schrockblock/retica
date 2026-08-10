import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// End-to-end through the LXMFNode composition: node A delivers a large LXMF message to node B directly
/// over a Link (as a Resource), and B's LXMFNode surfaces the reconstructed, signature-validated message.
/// Then B's RESOURCE_PRF is bridged back to A so A's resourceConcluded fires, which LXMFNode maps through
/// to deliveryConfirmed — proving the full round-trip.
///
/// Key sequencing note (vs. the brief's skeleton): TCA processes the entire chain
/// LRRTT-transmit → link.established → LXMFNode.linkEstablished → router.drain → sendDirect →
/// endpoint.sendResourceOverLink → RESOURCE_ADV within a single `await a.receive(isInterfaceSend)`
/// call for LRRTT. So both sentA[lrrttIdx] and sentA[lrrttIdx+1] are written before that receive
/// returns. Byte bridging uses explicit index arithmetic rather than `sentA.value.last!`.
@Test @MainActor func lxmfNodeDirectDeliversResourceAndConfirms() async {
    let clock = TestClock()
    let aIdentity = Identity()
    let bIdentity = Identity()
    let bDeliveryHash = LXMessage.deliveryHash(identityHash: bIdentity.hash)

    func make(_ host: String, _ identity: Identity, _ sent: LockIsolated<[Data]>)
        -> (TestStore<LXMFNode.State, LXMFNode.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: LXMFNode.State(
            identity: identity, endpoint: TCPEndpoint.State(host: host, port: 4242, reconnectOnDrop: false))
        ) {
            LXMFNode()
        } withDependencies: {
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

    // Predicate helpers for the .off store (everything is wrapped under .endpoint(...)).
    func isInterfaceSend(_ a: LXMFNode.Action) -> Bool {
        if case .endpoint(.tcp(.interface(.send))) = a { return true }; return false
    }

    let sentA = LockIsolated<[Data]>([]); let sentB = LockIsolated<[Data]>([])
    let (a, eventsA) = make("a", aIdentity, sentA)
    let (b, eventsB) = make("b", bIdentity, sentB)

    await a.send(.endpoint(.start)); eventsA.yield(.connected)
    await b.send(.endpoint(.start)); eventsB.yield(.connected)

    // Both register + announce; bridge announces so A learns B (path + identity for signing/validation)
    // and B learns A (identity — B validates A's signature).
    await a.send(.registerDelivery)
    await a.receive(isInterfaceSend)
    await b.send(.registerDelivery)
    await b.receive(isInterfaceSend)
    eventsA.yield(.data(sentB.value.last!))                 // B's announce → A learns B
    await a.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!))                 // A's announce → B learns A
    await b.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // A sends a LARGE message to B via .direct → router establishes a link (path already known),
    // then sends the message as a Resource. First: the LINKREQUEST goes out.
    let bigContent = Data((0..<800).map { UInt8($0 & 0xff) })
    // Recover the deterministic message hash by rebuilding with the same params (timestamp from the fixed date).
    let sentMessageHash = LXMessage.create(
        source: aIdentity, destinationHash: bDeliveryHash,
        timestamp: 1700000000.5, title: Data("big".utf8), content: bigContent).hash
    await a.send(.send(destinationHash: bDeliveryHash, title: Data("big".utf8), content: bigContent, method: .direct))
    await a.receive(isInterfaceSend)                        // LINKREQUEST out

    // Link handshake (mirrors LXMFDirectDeliveryTests steps 2–4, wrapped through LXMFNode).
    //
    // Step 2: LINKREQUEST → B; B sends LRPROOF.
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(isInterfaceSend)                        // LRPROOF out
    let lrproofBytes = sentB.value.last!                    // capture LRPROOF

    // Step 3: LRPROOF → A; A sends LRRTT AND (via the linkEstablished chain) RESOURCE_ADV in the
    // same receive call. Capture LRRTT by index before the receive so we know its position.
    let lrrttIdx = sentA.value.count                        // LRRTT will land at this index
    eventsA.yield(.data(lrproofBytes))
    await a.receive(isInterfaceSend)                        // LRRTT out (RESOURCE_ADV also fires here)
    let lrrttBytes = sentA.value[lrrttIdx]                  // LRRTT bytes (not last! which is RESOURCE_ADV)
    let resourceAdvBytes = sentA.value[lrrttIdx + 1]        // RESOURCE_ADV bytes (second send of this chain)

    // Step 4: LRRTT → B; B becomes active.
    eventsB.yield(.data(lrrttBytes))
    await a.receive { if case .endpoint(.delegate(.linkEstablished)) = $0 { return true }; return false }
    await b.receive { if case .endpoint(.delegate(.linkEstablished)) = $0 { return true }; return false }

    // Link is active on both ends; router already drained → RESOURCE_ADV was emitted in step 3.
    await a.receive(isInterfaceSend)                        // RESOURCE_ADV (already queued in store)

    // ADV → B: B spawns a receiver, emits RESOURCE_REQ.
    eventsB.yield(.data(resourceAdvBytes))
    await b.receive(isInterfaceSend)                        // RESOURCE_REQ out
    let resourceReqBytes = sentB.value.last!               // capture RESOURCE_REQ bytes

    // REQ → A: A serves its parts.
    eventsA.yield(.data(resourceReqBytes))
    let partCount = a.state.endpoint.links[0].transfers[0].parts.count
    for _ in 0..<partCount { await a.receive(isInterfaceSend) }

    // Deliver every part frame A emitted (the last `partCount` frames in sentA) to B.
    let parts = Array(sentA.value.suffix(partCount))
    let gotContent = LockIsolated<Data?>(nil)
    let gotTitle = LockIsolated<Data?>(nil)
    let gotSrcHash = LockIsolated<Data?>(nil)
    let gotValidated = LockIsolated<Bool>(false)
    let resourcePrfBytes = LockIsolated<Data?>(nil)
    for (i, frame) in parts.enumerated() {
        eventsB.yield(.data(frame))
        if i == partCount - 1 {
            await b.receive(isInterfaceSend)               // RESOURCE_PRF out
            resourcePrfBytes.setValue(sentB.value.last!)   // capture RESOURCE_PRF before messageReceived
            await b.receive { action in
                if case let .delegate(.messageReceived(m, v)) = action {
                    gotContent.setValue(m.content)
                    gotTitle.setValue(m.title)
                    gotSrcHash.setValue(m.sourceHash)
                    gotValidated.setValue(v)
                    return true
                }
                return false
            }
        }
    }

    #expect(gotContent.value == bigContent)
    #expect(gotTitle.value == Data("big".utf8))
    #expect(gotSrcHash.value == LXMessage.deliveryHash(identityHash: aIdentity.hash))
    #expect(gotValidated.value == true)                    // B learned A's identity → signature validates

    // B's RESOURCE_PRF → A: A concludes the resource, which LXMFNode maps
    // resourceConcluded → router.resourceDeliveredOnLink → deliveryConfirmed.
    let gotConfirmed = LockIsolated<Data?>(nil)
    eventsA.yield(.data(resourcePrfBytes.value!))
    await a.receive { action in
        if case let .delegate(.deliveryConfirmed(hash)) = action { gotConfirmed.setValue(hash); return true }
        return false
    }
    #expect(gotConfirmed.value == sentMessageHash)         // the hash of the message A sent

    await a.send(.endpoint(.stop)); await b.send(.endpoint(.stop))
}

/// An establishment timeout must reach the router and route as a PATH-shaped failure. Before
/// this change (Task 1), LinkSession emitted `.closed(.timedOut)` → `linkClosed(linkID:)`, which
/// died at the LXMFNode reverse-map, leaving the destination wedged. That was fixed by emitting
/// `.establishmentFailed(.timedOut)`.
///
/// This test (updated for Task 2) verifies the new routing: an establishment timeout is
/// PATH-shaped — the peer never responded, so the most likely cause is that our route is wrong.
/// Routing to a path request is cheaper than burning 5 × 15s against a dead route. The shared
/// `establishAttempts` budget bounds the whole saga (path parks + link attempts together).
///
/// Flow: 1 timeout → pathLost + linkClosed → establish → awaitingPath park → requestPath.
/// Park timer fires (maxAttempts - 1) more times, then giveUp → deliveryFailed.
@Test @MainActor func establishmentTimeoutReachesRouterAndDoesNotWedgeDestination() async {
    let clock = TestClock()
    let aIdentity = Identity()
    let bIdentity = Identity()
    let bDeliveryHash = LXMessage.deliveryHash(identityHash: bIdentity.hash)

    func make(_ host: String, _ identity: Identity, _ sent: LockIsolated<[Data]>)
        -> (TestStore<LXMFNode.State, LXMFNode.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: LXMFNode.State(
            identity: identity, endpoint: TCPEndpoint.State(host: host, port: 4242, reconnectOnDrop: false))
        ) {
            LXMFNode()
        } withDependencies: {
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

    func isInterfaceSend(_ a: LXMFNode.Action) -> Bool {
        if case .endpoint(.tcp(.interface(.send))) = a { return true }; return false
    }

    let sentA = LockIsolated<[Data]>([]); let sentB = LockIsolated<[Data]>([])
    let (a, eventsA) = make("a", aIdentity, sentA)
    let (b, eventsB) = make("b", bIdentity, sentB)

    // Start both nodes and register delivery so B announces itself.
    await a.send(.endpoint(.start)); eventsA.yield(.connected)
    await b.send(.endpoint(.start)); eventsB.yield(.connected)

    await a.send(.registerDelivery)
    await a.receive(isInterfaceSend)                          // A's announce out
    await b.send(.registerDelivery)
    await b.receive(isInterfaceSend)                          // B's announce out
    // Bridge B's announce to A so A learns B's path + identity (needed for openLink to proceed).
    eventsA.yield(.data(sentB.value.last!))
    await a.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // A sends a direct message to B. Because A has a learned path, openLink proceeds and
    // a LINKREQUEST goes out. B never replies — simulating a peer that does not answer.
    let wedgedHash = LXMessage.create(
        source: aIdentity, destinationHash: bDeliveryHash,
        timestamp: 1700000000.5, title: Data("x".utf8), content: Data("y".utf8)).hash
    await a.send(.send(destinationHash: bDeliveryHash, title: Data("x".utf8), content: Data("y".utf8), method: .direct))
    await a.receive(isInterfaceSend)                          // LINKREQUEST #1 (establishAttempts = 1)

    // After 15s the link times out with .establishmentTimedOut.
    // Task 2 routing: .establishmentTimedOut is PATH-shaped →
    //   pathLost (clear knownPaths) + linkClosed → establish() → .awaitingPath park + requestPath.
    // establishAttempts is still 1 (the awaitingPath branch of establish() does not increment it;
    // only pathRequestDeadline does, starting from the first park-timer fire).
    await clock.advance(by: .seconds(15))
    await a.receive { if case .router(.delegate(.requestPath)) = $0 { return true }; return false }
    #expect(a.state.router.directLinks[bDeliveryHash] == .awaitingPath)
    #expect(!a.state.router.knownPaths.contains(bDeliveryHash), "path cleared by pathLost")

    // Each pathRequestWaitSeconds advance fires one pathRequestDeadline → re-request path.
    // pathRequestDeadline increments from 1: 1→2, 2→3, 3→4, 4→5 → requestPath (4 fires).
    // Then 5→6 > maxAttempts(5) → giveUp. So 4 requestPath re-fires from pathRequestDeadline.
    for _ in 1...(LXMFDelivery.maxAttempts - 1) {
        await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
        await a.receive { if case .router(.delegate(.requestPath)) = $0 { return true }; return false }
    }

    // The (maxAttempts+1)-th deadline drives giveUp: deliveryFailed is emitted.
    let failedHash = LockIsolated<Data?>(nil)
    await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
    await a.receive { action in
        if case let .delegate(.deliveryFailed(hash)) = action { failedHash.setValue(hash); return true }
        return false
    }
    #expect(failedHash.value == wedgedHash)
    // giveUp clears all state.
    #expect(a.state.router.outboundQueue[bDeliveryHash]?.isEmpty ?? true)
    #expect(a.state.router.establishAttempts[bDeliveryHash] == nil)

    await a.send(.endpoint(.stop)); await b.send(.endpoint(.stop))
}

/// A path-shaped link failure must make the router request a PATH, not retry the LINK. Before
/// this fix, `knownPaths` still claimed a path existed after a `.pathStale` (or `.noPath` /
/// `.establishmentTimedOut`) failure, so `establish` took the `requestLink` branch every time and
/// burned the whole budget against a route already known to be dead.
///
/// Checks all three path-shaped reasons.
///
/// Absence strategy: a trailing `.on` is NOT used, because the `.awaitingPath` park arms
/// `pathRequestTimer` and teardown under `.on` fails on the in-flight effect. State carries the
/// absence claim instead. Note carefully WHICH piece of state does the work:
///
///  • `requestPath` arriving, `knownPaths` cleared, and `directLinks[dest] == .awaitingPath` are
///    all necessary but NOT sufficient — a reversed `pathLost`/`linkClosed` ordering reaches every
///    one of them one cycle later, after `openLink` bounces `linkFailed(.noPath)` back. Those
///    three assertions alone pass under the reversed mutation.
///  • `establishAttempts[dest] == nil` is the discriminator: the reversed order spends a link
///    attempt first (counter := 1) and only then parks. See the comment at that assertion.
@Test @MainActor func stalePathLinkFailureRequestsAPathInsteadOfRetryingTheLink() async {
    let dest = LXMessage.deliveryHash(identityHash: Identity().hash)

    for reason in [LinkFailure.pathStale, .noPath, .establishmentTimedOut] {
        let clock = TestClock()
        let aIdentity = Identity()
        var initial = LXMFNode.State(
            identity: aIdentity,
            endpoint: TCPEndpoint.State(host: "a", port: 4242, reconnectOnDrop: false))
        // Seed the router with a known path so that without the fix `establish` would emit
        // `requestLink`. We also need a queued message so `linkClosed` has work and calls `establish`.
        initial.router.knownPaths.insert(dest)
        let msg = LXMessage.create(source: aIdentity, destinationHash: dest,
                                   timestamp: 1700000000.5, title: Data("t".utf8),
                                   content: Data("c".utf8))
        initial.router.outboundQueue[dest] = [msg]

        let store = TestStore(initialState: initial) {
            LXMFNode()
        } withDependencies: {
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
            $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } },
                                             send: { _ in },
                                             close: { })
        }
        store.exhaustivity = .off

        // Inject a path-shaped link failure. The fix:
        //   1. pathLost(dest)  → knownPaths.remove(dest)
        //   2. linkClosed(dest) → establish() sees no path → .awaitingPath + requestPath
        // Without the fix: knownPaths still contains dest → establish() → requestLink.
        await store.send(.endpoint(.delegate(.linkFailed(destinationHash: dest, reason: reason))))

        // Assert: a path request is emitted (awaitingPath park), NOT a link request.
        await store.receive { action in
            if case .router(.delegate(.requestPath(let d))) = action { return d == dest }
            return false
        }

        // State confirms the routing: .awaitingPath means requestPath was emitted.
        // knownPaths must be cleared so the NEXT establish() also takes the path-request branch.
        #expect(!store.state.router.knownPaths.contains(dest),
                "knownPaths must be cleared by pathLost for reason \(reason)")
        #expect(store.state.router.directLinks[dest] == .awaitingPath,
                "destination must be parked in .awaitingPath for reason \(reason)")

        // THE ORDERING DISCRIMINATOR. `establish` increments `establishAttempts` ONLY on its
        // `knownPaths.contains(dest)` branch (LXMFRouter.swift:200); the else-branch that parks
        // in `.awaitingPath` returns requestPath + pathRequestTimer without touching the counter.
        //
        // Under the CORRECT order (pathLost first) the very first `establish` sees an empty
        // knownPaths, takes the else-branch, and spends NOTHING — the budget stays nil.
        //
        // Under REVERSED order `linkClosed` reaches `establish` while the stale entry is still
        // present, so it spends one link attempt (counter := 1) and emits requestLink; only the
        // NEXT cycle — after `openLink` bounces back `linkFailed(.noPath)` — parks and produces
        // requestPath. Both orders therefore end at `.awaitingPath` with knownPaths cleared, and
        // both eventually emit requestPath. The difference is ENTIRELY in the budget, which is
        // why the assertions above cannot pin the ordering and this one can.
        #expect(store.state.router.establishAttempts[dest] == nil,
                "no link attempt may be spent for reason \(reason) — the path branch is free")

        // The queued message is healthy and still parked, not failed or dropped.
        #expect(store.state.router.outboundQueue[dest]?.count == 1,
                "the queued message must survive the park for reason \(reason)")
    }
}

/// An establishment failure that is NOT path-shaped (`.handshakeRejected`) must still retry the
/// link, not request a path. The path demonstrably works — the peer replied but the proof was bad.
/// This is the regression guard against over-routing: we must not park `.handshakeRejected` in
/// `.awaitingPath`, because the path is fine and a path request would waste the budget.
@Test @MainActor func handshakeRejectedLinkFailureStillRetriesTheLinkNotAPath() async {
    let dest = LXMessage.deliveryHash(identityHash: Identity().hash)
    let clock = TestClock()
    let aIdentity = Identity()
    var initial = LXMFNode.State(
        identity: aIdentity,
        endpoint: TCPEndpoint.State(host: "a", port: 4242, reconnectOnDrop: false))
    initial.router.knownPaths.insert(dest)
    let msg = LXMessage.create(source: aIdentity, destinationHash: dest,
                               timestamp: 1700000000.5, title: Data("t".utf8),
                               content: Data("c".utf8))
    initial.router.outboundQueue[dest] = [msg]

    let store = TestStore(initialState: initial) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } },
                                         send: { _ in },
                                         close: { })
    }
    store.exhaustivity = .off

    await store.send(.endpoint(.delegate(.linkFailed(destinationHash: dest, reason: .handshakeRejected))))

    // Assert: a link request is emitted (re-establish), NOT a path request.
    await store.receive { action in
        if case .router(.delegate(.requestLink(let d))) = action { return d == dest }
        return false
    }

    // knownPaths must still contain dest (path not cleared for peer-shaped failure).
    #expect(store.state.router.knownPaths.contains(dest),
            "knownPaths must not be cleared for .handshakeRejected")
    #expect(store.state.router.directLinks[dest] == .establishing,
            "destination must be .establishing (link retry), not .awaitingPath")

    // The MIRROR of the budget assertion in the path-shaped test, and the reason the two tests
    // reinforce each other: here spending a link attempt is the CORRECT behaviour, so the counter
    // must be 1. Each test's expected budget is the other's failure mode — routing a peer-shaped
    // failure into the free path branch would show up here as nil, and routing a path-shaped
    // failure into the link branch shows up there as 1.
    #expect(store.state.router.establishAttempts[dest] == 1,
            "a link retry must spend exactly one attempt from the bounded budget")
}

