import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// The photo that ended "failed" (2026-10-21): a Resource-sized message sent with
// `fallbackToPropagation`, to a recipient that never answers link requests, with a reachable
// propagation node. Its propagated copy must reach the node — and the app re-applying the SAME
// propagation node on every `interfaceConnected` (a listener client, the loopback slot, a TCP
// redial) must not abandon the copy while its stamp is searched.

private let dest = Data(repeating: 0xD5, count: 16)
private let pn = Data(repeating: 0xBB, count: 16)
private let pnLink = Data(repeating: 0xC0, count: 16)

/// An exhaustive no-op: a conclusion on a link we have no transfer on changes nothing.
@MainActor
private let probe = LXMFNode.Action.endpoint(.delegate(.resourceConcluded(linkID: Data(repeating: 0x99, count: 16),
                                                                          resourceHash: Data(repeating: 0x11, count: 32))))

/// About the size of the failed photo (a 144,690-byte JPEG): far above Link MDU, so both copies
/// travel as Resources over links.
private func photo() -> LXMessage {
    LXMessage.create(source: Identity(), destinationHash: dest, timestamp: 1700000000.5,
                     title: Data(), content: Data(repeating: 0x4A, count: 144_690))
}

/// The recipient's identity is known and the router believes it has a path, but no interface is up
/// for it, so every link request fails and the delivery copy parks for a path that never answers —
/// a recipient that never answers link requests. The propagation node announces a 256 KB limit.
/// With `pnLinkUp`, a link to the node is already active (the app's sync on connect opened it).
@MainActor
private func photoNode(stampCost: Double, pnLinkUp: Bool, clock: TestClock<Duration>)
    -> TestStore<LXMFNode.State, LXMFNode.Action> {
    var state = LXMFNode.State(identity: Identity(),
                               endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    state.endpoint.transport.learned[dest] = LearnedDestination(
        identity: Identity(), appData: nil, ratchet: nil, interfaceID: InterfaceID("tcp"),
        hops: 1, nextHop: nil, announceEmitted: 0)
    state.endpoint.transport.learned[pn] = LearnedDestination(
        identity: Identity(),
        appData: PNAnnounce(timebase: 0, nodeState: true, perTransferLimit: 256, perSyncLimit: 256,
                            targetStampCost: stampCost, stampCostFlexibility: 0, peeringCost: 0).packed,
        ratchet: nil, interfaceID: InterfaceID("tcp"), hops: 1, nextHop: nil, announceEmitted: 0)
    state.router.outboundPropagationNode = pn
    state.router.knownPaths.insert(dest)
    if pnLinkUp {
        state.router.directLinks[pn] = .active(linkID: pnLink)
        state.directLinks[pn] = pnLink
        state.linkDestinations[pnLink] = pn
    }
    let store = TestStore(initialState: state) { LXMFNode() } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

/// Send the photo and let its delivery copy stall until the router asks for the propagated copy:
/// the first link request fails at once, then every path-request park charges one attempt.
@MainActor
private func sendAndStall(_ store: TestStore<LXMFNode.State, LXMFNode.Action>,
                          _ clock: TestClock<Duration>, _ m: LXMessage) async {
    #expect(m.directRepresentation == .resource)
    await store.send(.sendMessage(message: m, fallbackToPropagation: true))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.router.fallbackEligible == [m.hash])                 // H3: eligibility is marked
    for _ in 0..<(LXMFDelivery.propagationFallbackAfterAttempts - 1) {
        await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
    }
    await store.receive(.router(.delegate(.propagationFallbackDue(messageHash: m.hash))))
}

/// The stamp search for the propagated copy (cost 4) ends and the copy is handed to the router.
@MainActor
private func receiveTheHandOver(_ store: TestStore<LXMFNode.State, LXMFNode.Action>, _ m: LXMessage) async {
    let isHandOver: (LXMFNode.Action) -> Bool = {
        if case let .router(.sendViaPropagation(sent, _)) = $0 { return sent.hash == m.hash }
        return false
    }
    await store.receive(isHandOver, timeout: .seconds(30))
}

/// Run the delivery copy out of attempts. The LAST park is checked exhaustively: it gives up on the
/// recipient, and that must report nothing while the propagated copy can still succeed.
@MainActor
private func exhaustTheDeliveryCopy(_ store: TestStore<LXMFNode.State, LXMFNode.Action>,
                                    _ clock: TestClock<Duration>, _ m: LXMessage) async {
    while (store.state.router.establishAttempts[dest] ?? 0) < LXMFDelivery.maxAttempts {
        await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
        await store.skipReceivedActions(strict: false)
    }
    store.exhaustivity = .on
    await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
    await store.receive(.router(.pathRequestDeadline(destinationHash: dest))) {
        $0.router.establishAttempts[dest] = nil
        $0.router.directLinks[dest] = nil
        $0.router.outboundQueue[dest] = nil
    }
    await store.send(probe)                                                  // a deliveryFailed fails here
    store.exhaustivity = .off
    #expect(store.state.router.hasOutboundState(for: m.hash))               // the message is still alive
}

/// H1 is SUFFICIENT, not just possible: with nothing re-applying the node, the photo's propagated
/// copy is packed, goes out as a Resource on the node's link, outlives the delivery copy's give-up,
/// and is accepted. (Also rules out H2 and H3 for this path.)
@Test(.timeLimit(.minutes(1))) @MainActor func photoFallbackReachesThePropagationNode() async {
    let clock = TestClock()
    let store = photoNode(stampCost: 4, pnLinkUp: true, clock: clock)
    let m = photo()
    await sendAndStall(store, clock, m)
    await receiveTheHandOver(store, m)
    #expect(store.state.router.pendingDeliveries[.propagated(m.hash)] != nil)
    #expect(store.state.router.linkResourceInFlight[pnLink] != nil)        // a Resource on the node's link
    await exhaustTheDeliveryCopy(store, clock, m)
    await store.send(.router(.resourceDeliveredOnLink(linkID: pnLink)))
    await store.receive(.delegate(.propagationAccepted(messageHash: m.hash)))
}

/// H2, queued variant (router level, so the node's link establishment is in the test's hands): no
/// link to the node yet when the copy is handed over, so it waits behind that link's establishment
/// while the recipient's parked delivery copy gives up — and still goes out once the link is up.
@Test @MainActor func photoFallbackQueuedBehindTheNodesLinkSurvivesTheGiveUp() async {
    let clock = TestClock()
    let m = photo()
    var state = LXMFRouter.State()
    state.outboundPropagationNode = pn
    state.knownPaths.insert(pn)                    // the recipient has none: its copy parks for a path
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    await store.send(.markFallbackEligible(messageHash: m.hash))
    await store.send(.send(message: m, desiredMethod: .opportunistic))
    for _ in 0..<LXMFDelivery.propagationFallbackAfterAttempts {
        await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
    }
    await store.receive(.delegate(.propagationFallbackDue(messageHash: m.hash)))
    await store.send(.sendViaPropagation(message: m, propagationPacked: Data(repeating: 0x50, count: 150_000)))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.propagationQueue[pn]?.count == 1)
    #expect(store.state.directLinks[pn] == .establishing)
    while (store.state.establishAttempts[dest] ?? 0) < LXMFDelivery.maxAttempts {
        await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
        await store.skipReceivedActions(strict: false)
    }
    store.exhaustivity = .on
    await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
    await store.receive(.pathRequestDeadline(destinationHash: dest)) {     // gives up on the recipient
        $0.establishAttempts[dest] = nil
        $0.directLinks[dest] = nil
        $0.outboundQueue[dest] = nil
    }
    await store.send(.retryDue(messageHash: Data(repeating: 0x77, count: 32), leg: .delivery))  // probe: no deliveryFailed
    store.exhaustivity = .off
    await store.send(.linkEstablished(destinationHash: pn, linkID: pnLink))
    #expect(store.state.linkResourceInFlight[pnLink] == .propagated(m.hash))
    await store.send(.resourceDeliveredOnLink(linkID: pnLink))
    await store.receive(.delegate(.propagationAccepted(messageHash: m.hash)))
}

/// H1, the bug: the app sends `.setPropagationNode` with the node already set on every
/// `interfaceConnected`. Arriving while the fallback's stamp is searched, it cancelled the search
/// and abandoned the copy, so the delivery copy's give-up reported `deliveryFailed` and nothing
/// ever reached the node. Re-applying the same node must change nothing. At cost 20 the search
/// cannot finish during the test, so it is deterministically in flight; its hand-over is then
/// played by sending the `.router(.sendViaPropagation)` it would deliver.
@Test(.timeLimit(.minutes(1))) @MainActor func photoFallbackSurvivesReapplyingTheSameNodeDuringItsStampSearch() async {
    let clock = TestClock()
    let store = photoNode(stampCost: LXMFPropagation.maxPropagationStampCost, pnLinkUp: true, clock: clock)
    let m = photo()
    await sendAndStall(store, clock, m)
    #expect(store.state.router.pendingPropagatedCopies == [m.hash])        // its stamp is being searched
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.setPropagationNode(destinationHash: pn))              // the same node: a no-op
    await store.send(probe)                                                  // an abandon fails here
    store.exhaustivity = .off
    #expect(store.state.router.pendingPropagatedCopies == [m.hash])
    await exhaustTheDeliveryCopy(store, clock, m)
    await store.send(.router(.sendViaPropagation(message: m,
                                                 propagationPacked: Data(repeating: 0x50, count: 150_000))))
    #expect(store.state.router.linkResourceInFlight[pnLink] != nil)
    await store.send(.router(.resourceDeliveredOnLink(linkID: pnLink)))
    await store.receive(.delegate(.propagationAccepted(messageHash: m.hash)))
    await store.send(.cancelPropagationStamps)                              // stop the real search
}
