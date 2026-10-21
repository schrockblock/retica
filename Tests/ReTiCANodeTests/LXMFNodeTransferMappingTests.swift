import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Transfer-aware delivery, Task 6: LXMFNode maps transfer events onto messages. The endpoint's
// delegates are injected directly; the router is seeded with a live link to `dest`, and the
// endpoint has no link element, so `sendResourceOverLink` / `cancelResource` go nowhere.

private let dest = Data(repeating: 0xD5, count: 16)
private let link = Data(repeating: 0xEF, count: 16)
private let pn = Data(repeating: 0xBB, count: 16)
private let pnLink = Data(repeating: 0xC0, count: 16)
private let inboundLink = Data(repeating: 0x7A, count: 16)
private let ours = Data(repeating: 0x0D, count: 16)          // our delivery destination, in these tests
private let h1 = Data(repeating: 0x11, count: 32)
private let h2 = Data(repeating: 0x22, count: 32)
/// An exhaustive no-op: a conclusion on a link we have no transfer on changes nothing.
@MainActor
private let probe = LXMFNode.Action.endpoint(.delegate(.resourceConcluded(linkID: Data(repeating: 0x99, count: 16),
                                                                          resourceHash: h1)))

@MainActor
private func mappingNode(clock: TestClock<Duration> = TestClock(),
                         _ configure: (inout LXMFNode.State) -> Void = { _ in })
    -> TestStore<LXMFNode.State, LXMFNode.Action> {
    var state = LXMFNode.State(identity: Identity(),
                               endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    state.router.directLinks[dest] = .active(linkID: link)
    state.router.knownPaths.insert(dest)
    state.directLinks[dest] = link
    state.linkDestinations[link] = dest
    configure(&state)
    let store = TestStore(initialState: state) { LXMFNode() } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

private func bigMessage(_ fill: String = "y") -> LXMessage {
    LXMessage.create(source: Identity(), destinationHash: dest, timestamp: 1700000000.5,
                     title: Data("t".utf8), content: Data(String(repeating: fill, count: 2000).utf8))
}

private func sent(_ hash: Data, done: Int, total: Int, on linkID: Data = link) -> LXMFNode.Action {
    .endpoint(.delegate(.resourceProgress(linkID: linkID, resourceHash: hash, role: .sender,
                                          bytesDone: done, bytesTotal: total, segment: 1, segments: 1)))
}

private func received(_ hash: Data, done: Int, total: Int, on linkID: Data) -> LXMFNode.Action {
    .endpoint(.delegate(.resourceProgress(linkID: linkID, resourceHash: hash, role: .receiver,
                                          bytesDone: done, bytesTotal: total, segment: 1, segments: 1)))
}

@Test func nodeTransferFractionsFollowTheReferenceFormula() {
    // Reference `LXMessage.__update_transfer_progress` (LXMessage.py:623-624): 0.10 + 0.90 × progress.
    #expect(abs(LXMFNode.outboundFraction(bytesDone: 0, bytesTotal: 10, segment: 1, segments: 1) - 0.10) < 1e-12)
    #expect(abs(LXMFNode.outboundFraction(bytesDone: 5, bytesTotal: 10, segment: 1, segments: 1) - 0.55) < 1e-12)
    // Capped below 1.0: every part served is not a confirmation (only `finishProgress` reports 1.0).
    #expect(LXMFNode.outboundFraction(bytesDone: 10, bytesTotal: 10, segment: 1, segments: 1) == 0.99)
    #expect(LXMFNode.outboundFraction(bytesDone: 999, bytesTotal: 1000, segment: 1, segments: 1) == 0.99)
    // A split Resource counts its finished segments: segment 3 of 4, half done → 2.5 / 4.
    #expect(abs(LXMFNode.transferFraction(bytesDone: 5, bytesTotal: 10, segment: 3, segments: 4) - 0.625) < 1e-12)
    #expect(LXMFNode.transferFraction(bytesDone: 5, bytesTotal: 0, segment: 1, segments: 1) == 0)
}

@Test @MainActor func nodeTransferProgressFollowsTheReferenceScale() async {
    let m = bigMessage()
    let store = mappingNode()
    await store.send(.router(.send(message: m, desiredMethod: .direct)))
    await store.receive(.delegate(.deliveryProgress(messageHash: m.hash, fraction: LXMFNode.linkActiveProgress)))
    await store.send(sent(h1, done: 0, total: 1000))
    await store.receive(.delegate(.deliveryProgress(messageHash: m.hash, fraction: LXMFNode.transferStartProgress)))
    await store.send(sent(h1, done: 500, total: 1000))
    await store.receive(.delegate(.deliveryProgress(
        messageHash: m.hash,
        fraction: LXMFNode.outboundFraction(bytesDone: 500, bytesTotal: 1000, segment: 1, segments: 1))))
    // Every part served: the top of the transfer phase, not yet 1.0 — that waits for the proof.
    await store.send(sent(h1, done: 1000, total: 1000))
    await store.receive(.delegate(.deliveryProgress(messageHash: m.hash, fraction: 0.99)))
    await store.send(.endpoint(.delegate(.resourceConcluded(linkID: link, resourceHash: h1))))
    await store.receive(.delegate(.deliveryProgress(messageHash: m.hash, fraction: 1.0)))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: m.hash)))
    #expect(store.state.transferProgress[.delivery(m.hash)] == nil)
    #expect(store.state.outboundTransfers[link] == nil)
}

@Test @MainActor func nodeTransferProgressIsMonotonicPerCopy() async {
    let m = bigMessage()
    let key = LXMFRouter.DeliveryKey.delivery(m.hash)
    let clock = TestClock()
    let store = mappingNode(clock: clock)
    let halfway = LXMFNode.outboundFraction(bytesDone: 500, bytesTotal: 1000, segment: 1, segments: 1)
    await store.send(.router(.send(message: m, desiredMethod: .direct)))
    await store.send(sent(h1, done: 0, total: 1000))
    await store.send(sent(h1, done: 500, total: 1000))
    #expect(store.state.transferProgress[key] == halfway)
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(sent(h1, done: 200, total: 1000))                     // lower: not reported
    await store.receive(.router(.linkActivity(linkID: link)))              // but it is still link activity
    await store.send(probe)
    store.exhaustivity = .off
    // The transfer fails and is retried on a fresh link: the wire restarts at 0.05 / 0.10, the copy
    // does not go backwards.
    await store.send(.endpoint(.delegate(.resourceFailed(linkID: link, resourceHash: h1, rejected: false))))
    let fresh = Data(repeating: 0xF0, count: 16)
    await store.send(.router(.linkEstablished(destinationHash: dest, linkID: fresh)))
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive(.router(.delegate(.sendDirect(linkID: fresh, data: m.packed, asResource: true))))
    await store.send(sent(h2, done: 0, total: 1000, on: fresh))
    #expect(store.state.transferProgress[key] == halfway)
    await store.send(sent(h2, done: 900, total: 1000, on: fresh))
    await store.receive(.delegate(.deliveryProgress(
        messageHash: m.hash,
        fraction: LXMFNode.outboundFraction(bytesDone: 900, bytesTotal: 1000, segment: 1, segments: 1))))
}

@Test @MainActor func nodeTransferPropagatedCopyReportsPropagationProgress() async {
    let m = bigMessage()
    let store = mappingNode { state in
        state.router.outboundPropagationNode = pn
        state.router.directLinks[pn] = .active(linkID: pnLink)
        state.directLinks[pn] = pnLink
    }
    await store.send(.router(.sendViaPropagation(message: m, propagationPacked: Data(repeating: 0xAA, count: 432))))
    await store.receive(.delegate(.propagationProgress(messageHash: m.hash, fraction: LXMFNode.linkActiveProgress)))
    await store.send(sent(h1, done: 0, total: 432, on: pnLink))
    await store.receive(.delegate(.propagationProgress(messageHash: m.hash, fraction: LXMFNode.transferStartProgress)))
    #expect(store.state.transferProgress[.delivery(m.hash)] == nil)
}

@Test @MainActor func nodeTransferInboundProgressIsKeyedByTheLinkDestination() async {
    let store = mappingNode { state in
        state.deliveryDestinationHash = ours
        state.linkDestinations[inboundLink] = ours             // a peer linked to OUR delivery destination
    }
    // On a link we opened, the far end is known.
    await store.send(received(h1, done: 250, total: 1000, on: link))
    await store.receive(.delegate(.inboundTransferProgress(sourceHash: dest, linkID: link, fraction: 0.25)))
    // On a link a peer opened to us, the sender is not known until the message is unpacked.
    await store.send(received(h2, done: 250, total: 1000, on: inboundLink))
    await store.receive(.delegate(.inboundTransferProgress(sourceHash: nil, linkID: inboundLink, fraction: 0.25)))
}

/// Review Focus 1: a conclusion naming a hash that is not our transfer on that link (a cancelled
/// transfer landing late, or anything else) must not confirm the copy now in flight there.
@Test @MainActor func nodeTransferStaleConclusionForAnotherResourceIsIgnored() async {
    let m = bigMessage()
    let store = mappingNode()
    await store.send(.router(.send(message: m, desiredMethod: .direct)))
    await store.send(sent(h1, done: 0, total: 1000))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.endpoint(.delegate(.resourceConcluded(linkID: link, resourceHash: h2))))
    await store.send(probe)
    store.exhaustivity = .off
    #expect(store.state.router.pendingDeliveries[.delivery(m.hash)] != nil)
}

/// Review Focus 1: `LinkSession` reports an INBOUND transfer's failure the same way; it must not
/// fail our outbound copy on the same link.
@Test @MainActor func nodeTransferInboundFailureDoesNotFailTheOutboundCopy() async {
    let m = bigMessage()
    let store = mappingNode()
    await store.send(.router(.send(message: m, desiredMethod: .direct)))
    await store.send(sent(h1, done: 0, total: 1000))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.endpoint(.delegate(.resourceFailed(linkID: link, resourceHash: h2, rejected: true))))
    await store.send(probe)
    store.exhaustivity = .off
    #expect(store.state.router.pendingDeliveries[.delivery(m.hash)]?.phase == .transferring)
}

@Test @MainActor func nodeTransferOutboundFailureReachesTheRouter() async {
    let m = bigMessage()
    let store = mappingNode()
    await store.send(.router(.send(message: m, desiredMethod: .direct)))
    await store.send(sent(h1, done: 0, total: 1000))
    await store.send(.endpoint(.delegate(.resourceFailed(linkID: link, resourceHash: h1, rejected: true))))
    await store.receive(.router(.resourceFailedOnLink(linkID: link, rejected: true)))
    await store.receive(.delegate(.deliveryRejected(messageHash: m.hash)))
    #expect(store.state.outboundTransfers[link] == nil)
    #expect(store.state.transferProgress[.delivery(m.hash)] == nil)
}

@Test @MainActor func nodeTransferCancelOutboundCancelsTheResourceByHash() async {
    let m = bigMessage()
    let store = mappingNode()
    await store.send(.router(.send(message: m, desiredMethod: .direct)))
    await store.send(sent(h1, done: 0, total: 1000))
    await store.send(.cancelOutbound(messageHash: m.hash))
    await store.receive(.router(.cancelOutbound(messageHash: m.hash)))
    await store.receive(.endpoint(.cancelResource(linkID: link, hash: h1)))
    await store.receive(.delegate(.deliveryCancelled(messageHash: m.hash)))
    #expect(store.state.outboundTransfers[link] == nil)
}

/// Review Focus 6: the router holds nothing for a message still in its delivery stamp search, so
/// the node reports the cancel — once — and the search stops (cost 20 would run for minutes).
@Test(.timeLimit(.minutes(1))) @MainActor func nodeTransferCancelOutboundDuringADeliveryStampSearchReportsCancelled() async {
    let store = mappingNode { state in
        state.learnedPeers[dest] = LXMFNode.LearnedPeer(displayName: nil, stampCost: LXMFNode.maxDeliveryStampCost,
                                                        supportsCompression: false,
                                                        learnedAt: Date(timeIntervalSince1970: 1700000000))
    }
    let m = LXMessage.create(source: Identity(), destinationHash: dest, timestamp: 1700000000.5,
                             title: Data(), content: Data("x".utf8))
    await store.send(.sendMessage(message: m, fallbackToPropagation: false))
    #expect(store.state.inFlightDeliveryStamps == [m.hash])
    await store.send(.cancelOutbound(messageHash: m.hash))
    #expect(store.state.inFlightDeliveryStamps.isEmpty)
    // Exhaustive from here, with nothing drained first: a second `deliveryCancelled` (the router
    // reporting as well as the node) is left unreceived and fails the probe.
    store.exhaustivity = .on
    await store.receive(.router(.cancelOutbound(messageHash: m.hash)))
    await store.receive(.delegate(.deliveryCancelled(messageHash: m.hash)))
    await store.send(probe)
    await store.finish(timeout: .seconds(10))
}

/// Round 2 (F1, node side): a message one of whose copies already succeeded (here its propagated
/// copy was accepted) has had its terminal outcome. Cancelling it while its delivery stamp is still
/// searched stops the search and forwards the cancel, but reports nothing.
@Test(.timeLimit(.minutes(1))) @MainActor func nodeTransferCancelAfterASuccessIsSilent() async {
    let m = LXMessage.create(source: Identity(), destinationHash: dest, timestamp: 1700000000.5,
                             title: Data(), content: Data("x".utf8))
    let store = mappingNode { state in
        state.learnedPeers[dest] = LXMFNode.LearnedPeer(displayName: nil, stampCost: LXMFNode.maxDeliveryStampCost,
                                                        supportsCompression: false,
                                                        learnedAt: Date(timeIntervalSince1970: 1700000000))
        state.router.succeededMessages.insert(m.hash)          // the propagated copy was accepted
    }
    await store.send(.sendMessage(message: m, fallbackToPropagation: false))
    #expect(store.state.inFlightDeliveryStamps == [m.hash])
    #expect(store.state.router.succeededMessages.contains(m.hash))
    store.exhaustivity = .on
    await store.send(.cancelOutbound(messageHash: m.hash)) {
        $0.inFlightDeliveryStamps = []
    }
    await store.receive(.router(.cancelOutbound(messageHash: m.hash)))
    await store.send(probe)                                    // no deliveryCancelled after the success
    await store.finish(timeout: .seconds(10))                  // the stamp search was stopped
}

@Test(.timeLimit(.minutes(1))) @MainActor func nodeTransferCancelOutboundStopsThePropagationStampSearch() async {
    let recipient = Identity()
    let clock = TestClock()
    let store = mappingNode(clock: clock) { state in
        state.router.outboundPropagationNode = pn
        state.endpoint.transport.learned[dest] = LearnedDestination(
            identity: recipient, appData: nil, ratchet: nil, interfaceID: InterfaceID("tcp"),
            hops: 1, nextHop: nil, announceEmitted: 0)
        state.endpoint.transport.learned[pn] = LearnedDestination(
            identity: Identity(),
            appData: PNAnnounce(timebase: 0, nodeState: true, perTransferLimit: 0, perSyncLimit: 0,
                                targetStampCost: LXMFPropagation.maxPropagationStampCost,
                                stampCostFlexibility: 0, peeringCost: 0).packed,
            ratchet: nil, interfaceID: InterfaceID("tcp"), hops: 1, nextHop: nil, announceEmitted: 0)
    }
    let m = LXMessage.create(source: Identity(), destinationHash: dest, timestamp: 1700000000.5,
                             title: Data(), content: Data("x".utf8))
    await store.send(.sendMessage(message: m, fallbackToPropagation: true))
    // The delivery copy stalls, so the propagated copy's stamp search starts.
    for _ in 0..<(LXMFDelivery.propagationFallbackAfterAttempts - 1) {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    }
    await store.receive(.router(.delegate(.propagationFallbackDue(messageHash: m.hash))))
    #expect(store.state.pendingFallbacks.isEmpty)              // taken up: its stamp search is running
    await store.skipReceivedActions(strict: false)
    await store.send(.cancelOutbound(messageHash: m.hash))
    // Exhaustive from here, with nothing drained first: the router reports the cancel (it holds the
    // delivery copy and the marker), and a second `deliveryCancelled` would fail the probe.
    store.exhaustivity = .on
    await store.receive(.router(.cancelOutbound(messageHash: m.hash))) {
        $0.router.pendingDeliveries = [:]
        $0.router.pendingPropagatedCopies = []
    }
    await store.receive(.router(.delegate(.deliveryCancelled(messageHash: m.hash))))
    await store.receive(.delegate(.deliveryCancelled(messageHash: m.hash)))
    await store.send(probe)
    await store.finish(timeout: .seconds(10))                  // only possible if the search was cancelled
}

/// A copy that failed while the other was outstanding got no delegate, so its progress entry was
/// never cleared. The message's terminal outcome drops both copies' entries — unless the other copy
/// is still outstanding, whose progress must stay monotonic.
@Test @MainActor func nodeTransferTerminalOutcomeClearsBothLegsProgress() async {
    let confirmed = Data(repeating: 0x31, count: 32)
    let accepted = Data(repeating: 0x32, count: 32)
    let stillSending = bigMessage("z")
    let store = mappingNode { state in
        for hash in [confirmed, accepted, stillSending.hash] {
            state.transferProgress[.delivery(hash)] = 0.4
            state.transferProgress[.propagated(hash)] = 0.6
        }
    }
    await store.send(.router(.delegate(.deliveryConfirmed(messageHash: confirmed))))
    #expect(store.state.transferProgress[.delivery(confirmed)] == nil)
    #expect(store.state.transferProgress[.propagated(confirmed)] == nil)
    await store.send(.router(.delegate(.propagationAccepted(messageHash: accepted))))
    #expect(store.state.transferProgress[.propagated(accepted)] == nil)
    #expect(store.state.transferProgress[.delivery(accepted)] == nil)
    // The delivery copy of this one is still pending: its entry survives the propagated success.
    await store.send(.router(.send(message: stillSending, desiredMethod: .direct)))
    await store.send(.router(.delegate(.propagationAccepted(messageHash: stillSending.hash))))
    #expect(store.state.transferProgress[.propagated(stillSending.hash)] == nil)
    #expect(store.state.transferProgress[.delivery(stillSending.hash)] == 0.4)
}

@Test @MainActor func nodeTransferLinkActivityReArmsTheIdleTimer() async {
    let clock = TestClock()
    var state = LXMFRouter.State()
    state.directLinks[dest] = .active(linkID: link)
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    await store.send(.linkEstablished(destinationHash: dest, linkID: link))       // arms the idle timer
    await clock.advance(by: .seconds(LXMFDelivery.linkMaxInactivitySeconds - 1))
    await store.send(.linkActivity(linkID: link))
    await clock.advance(by: .seconds(2))
    // Without draining, `store.state` reflects only what the last `send`/`receive` observed, not
    // any effect-cascaded action the clock advance triggered in the background (TestStore state
    // visibility under `.off` — see Lessons).
    await store.skipReceivedActions(strict: false)
    #expect(store.state.directLinks[dest] == .active(linkID: link))
    await clock.advance(by: .seconds(LXMFDelivery.linkMaxInactivitySeconds))
    await store.receive(.delegate(.closeLink(destinationHash: dest)))
}
