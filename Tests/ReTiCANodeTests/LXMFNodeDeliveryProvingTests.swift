import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// MARK: - Helpers

@MainActor
private func makeLXMFNodeStore(_ identity: Identity) -> TestStore<LXMFNode.State, LXMFNode.Action> {
    let store = TestStore(
        initialState: LXMFNode.State(
            identity: identity,
            endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    ) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

// MARK: - Positive test

/// An inbound link data packet on a link established to OUR delivery destination must produce BOTH
/// `provePacketOverLink` AND `router(.received)` — mirroring reference `LXMRouter.delivery_packet`
/// (LXMRouter.py:1925-1927) which calls `packet.prove()` before handing the packet to the LXMF layer.
///
/// Without the prove a reference LXMF client's packet-receipt timer fires → `LXMessage.__link_packet_timed_out`
/// (LXMessage.py:616-619) tears the link down and the message is never marked sent.
///
/// Assertion order is load-bearing (see comment below): prove first, then delivery. Under `.off`,
/// `receive` SKIPS non-matching actions, so asserting the FURTHER-HOP action first would silently
/// swallow the NEARER-HOP action and make the test vacuous.
@MainActor @Test func lxmfNodeProvesInboundDeliveryLinkPacket() async {
    let identity = Identity()
    let store = makeLXMFNodeStore(identity)

    // Derive the delivery destination hash exactly as registerDelivery does.
    let deliveryDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                   aspects: LXMessage.deliveryAspects, identity: identity)!
    let linkID = Data(repeating: 0xA1, count: 16)
    let packetHash = Data(repeating: 0xF1, count: 32)
    let payload = Data("hello-direct".utf8)

    // registerDelivery sets deliveryDestinationHash.
    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)    // drain register + announce effects
    #expect(store.state.deliveryDestinationHash == deliveryDest.hash)

    // Simulate an inbound link established to OUR delivery destination (responder role).
    await store.send(.endpoint(.delegate(.linkEstablished(linkID: linkID,
                                                          destinationHash: deliveryDest.hash))))
    await store.skipReceivedActions(strict: false)    // drain linkEstablished router effect

    // Now simulate the sender's data packet arriving.
    await store.send(.endpoint(.delegate(.linkDataReceived(linkID: linkID, data: payload,
                                                           packetHash: packetHash))))

    // 1. Prove MUST come out first (one hop away: linkDataReceived → provePacketOverLink).
    //    Asserting this before the router delivery action is CRITICAL — under .off, receive skips
    //    non-matching actions, so asserting router(.received) first would silently swallow the prove.
    await store.receive { action in
        if case let .endpoint(.provePacketOverLink(lid, h)) = action {
            #expect(lid == linkID)
            #expect(h == packetHash)
            return true
        }
        return false
    }

    // 2. Delivery MUST also happen — proving must not replace delivery.
    await store.receive { action in
        if case let .router(.received(method, _, data)) = action {
            #expect(method == .direct)
            #expect(data == payload)
            return true
        }
        return false
    }
}

// MARK: - Negative tests

/// NEGATIVE 1 — Propagation link: a data packet on the served `lxmf.propagation` link must NOT be
/// proved by `LXMFNode`. `LXMFServiceNode` handles proving there; `LXMFNode` must return early so
/// there is no double-prove and no spurious delivery to the router.
///
/// Strategy: arm `propagationDestinationHash` AND `deliveryDestinationHash` (full positive conditions
/// for each separately) so only the propagation-link guard stands between this packet and proves.
/// Flip exhaustivity to `.on` before the send under test; a stray `provePacketOverLink` or
/// `router(.received)` fails teardown.
@MainActor @Test func lxmfNodeDoesNotProvePacketOnPropagationLink() async {
    let identity = Identity()
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let deliveryDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                   aspects: LXMessage.deliveryAspects, identity: identity)!
    let propLinkID = Data(repeating: 0xB1, count: 16)
    let packetHash = Data(repeating: 0xF2, count: 32)

    // Pre-populate state so isPropagationLink(propLinkID) == true AND deliveryDestinationHash is set.
    var initial = LXMFNode.State(
        identity: identity,
        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    initial.propagationDestinationHash = propDest.hash
    initial.deliveryDestinationHash = deliveryDest.hash
    initial.linkDestinations[propLinkID] = propDest.hash   // terminates on OUR propagation dest

    let store = TestStore(initialState: initial) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }

    // .on so a stray provePacketOverLink or router(.received) fails teardown.
    store.exhaustivity = .on
    await store.send(.endpoint(.delegate(.linkDataReceived(linkID: propLinkID,
                                                           data: Data("offer".utf8),
                                                           packetHash: packetHash))))
    // No actions expected — the propagation guard returns early.
}

/// NEGATIVE 2 — Non-delivery link: a data packet on a link to some other destination (e.g., our
/// outbound sync link to a remote propagation node) must NOT be proved.
///
/// The outbound PN sync link has `linkDestinations[linkID] == remotePNHash`, which is NOT our
/// `deliveryDestinationHash`, so the isDeliveryLink check fails. The packet is still delivered to
/// the router (existing behaviour), but no prove is emitted.
///
/// Strategy: set `deliveryDestinationHash` so the nil-check doesn't shield us, set linkDestinations
/// to a DIFFERENT hash, flip to `.on` to catch any stray prove.
@MainActor @Test func lxmfNodeDoesNotProvePacketOnNonDeliveryLink() async {
    let identity = Identity()
    let deliveryDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                   aspects: LXMessage.deliveryAspects, identity: identity)!
    let remotePNHash = Data(repeating: 0xCC, count: 16)   // some remote destination, NOT our delivery
    let outboundLinkID = Data(repeating: 0xB2, count: 16)
    let packetHash = Data(repeating: 0xF3, count: 32)
    let payload = Data("sync-response".utf8)

    var initial = LXMFNode.State(
        identity: identity,
        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    initial.deliveryDestinationHash = deliveryDest.hash
    initial.linkDestinations[outboundLinkID] = remotePNHash   // terminates on REMOTE destination

    let store = TestStore(initialState: initial) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off

    await store.send(.endpoint(.delegate(.linkDataReceived(linkID: outboundLinkID, data: payload,
                                                           packetHash: packetHash))))

    // Delivery still happens (non-propagation link), but NO prove.
    // Drain to confirm router(.received) arrives — then flip .on so any stray prove at teardown fails.
    await store.receive { action in
        if case .router(.received) = action { return true }; return false
    }

    // Flip to .on: a stray provePacketOverLink would be left in the queue and fail teardown here.
    store.exhaustivity = .on
}

/// NEGATIVE 3 — `registerDelivery` was never called: `deliveryDestinationHash` is nil, so NO link can
/// be classified as a delivery link → no prove is emitted, even if the packet arrives on a link whose
/// destination coincidentally matches what a delivery hash would be.
///
/// Strategy: set linkDestinations to the delivery hash manually WITHOUT setting deliveryDestinationHash
/// (simulating a node that received a link before registering). Flip to `.on` to catch any stray prove.
@MainActor @Test func lxmfNodeDoesNotProvePacketWhenDeliveryNotRegistered() async {
    let identity = Identity()
    // Derive the hash as registerDelivery would — but DON'T call registerDelivery.
    let deliveryDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                   aspects: LXMessage.deliveryAspects, identity: identity)!
    let linkID = Data(repeating: 0xB3, count: 16)
    let packetHash = Data(repeating: 0xF4, count: 32)

    var initial = LXMFNode.State(
        identity: identity,
        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    // deliveryDestinationHash intentionally left nil
    initial.linkDestinations[linkID] = deliveryDest.hash   // would match IF registration had happened

    let store = TestStore(initialState: initial) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off

    await store.send(.endpoint(.delegate(.linkDataReceived(linkID: linkID, data: Data("msg".utf8),
                                                           packetHash: packetHash))))
    // Delivery still happens (not a propagation link), but NO prove.
    await store.receive { action in
        if case .router(.received) = action { return true }; return false
    }

    // Flip to .on: any stray provePacketOverLink would fail teardown.
    store.exhaustivity = .on
}
