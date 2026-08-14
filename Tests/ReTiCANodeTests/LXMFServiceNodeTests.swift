import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// Link classification: data arriving on the link that terminates on OUR served lxmf.propagation
/// destination is a propagation offer, not a direct message — the client must NOT try to deliver it.
/// Data on any other link keeps the existing direct-message behavior.
///
/// Verification strategy: send the propagation-link data while exhaustivity is .off, then flip to .on
/// before the otherLink send. Any stray .router(.received) that leaked from the propagation-link send
/// remains in the queue and causes a failure at the next send (unhandled effect in .on mode) or at
/// teardown. The positive assertion (otherLink receive) proves the guard is not simply disabling everything.
@MainActor @Test func clientIgnoresLinkDataOnServedPropagationLink() async {
    let identity = Identity()
    let servedPropHash = Data(repeating: 0x9A, count: 16)
    let otherHash = Data(repeating: 0x5B, count: 16)
    let servedLink = Data(repeating: 0xC1, count: 16)
    let otherLink = Data(repeating: 0xC2, count: 16)

    var initial = LXMFNode.State(identity: identity,
                                 endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    initial.propagationDestinationHash = servedPropHash

    let store = TestStore(initialState: initial) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off

    // Both links establish (setup, .off absorbs .router(.linkEstablished) effects).
    await store.send(.endpoint(.delegate(.linkEstablished(linkID: servedLink, destinationHash: servedPropHash))))
    await store.send(.endpoint(.delegate(.linkEstablished(linkID: otherLink, destinationHash: otherHash))))
    #expect(store.state.linkDestinations[servedLink] == servedPropHash)
    #expect(store.state.linkDestinations[otherLink] == otherHash)

    // linkDataReceived on the served propagation link must NOT reach the router.
    // A stray .router(.received) from the propagation link would survive as an unhandled effect and
    // fail teardown (or the next send in .on mode).
    await store.send(.endpoint(.delegate(.linkDataReceived(linkID: servedLink, data: Data("container".utf8),
                                                           packetHash: Data(repeating: 0xE1, count: 32)))))
    // resourceReceived on the served propagation link must ALSO not reach the router (Minor-1).
    // Both guards must block — deleting either one leaves a stray .router(.received) in the queue
    // that causes teardown to fail when exhaustivity is flipped to .on.
    await store.send(.endpoint(.delegate(.resourceReceived(linkID: servedLink, data: Data("resource".utf8)))))
    store.exhaustivity = .on   // any stray .router(.received) from either send above now fails teardown

    // Data on any other link keeps the existing direct-message path.
    // This also proves the guard is not simply disabling everything.
    await store.send(.endpoint(.delegate(.linkDataReceived(linkID: otherLink, data: Data("msg".utf8),
                                                           packetHash: Data(repeating: 0xE2, count: 32)))))
    await store.receive { if case .router(.received) = $0 { return true }; return false }
}

/// Builds a non-exhaustive TestStore over an arbitrary LXMFServiceNode.State.
@MainActor private func makeServiceNodeStore(_ initial: LXMFServiceNode.State)
    -> TestStore<LXMFServiceNode.State, LXMFServiceNode.Action> {
    let store = TestStore(initialState: initial) { LXMFServiceNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

@MainActor private func makeServiceNode(_ identity: Identity, nodeMode: Bool)
    -> TestStore<LXMFServiceNode.State, LXMFServiceNode.Action> {
    var initial = LXMFServiceNode.State(
        identity: identity,
        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false),
        minStampCost: 0)                       // 0 → accept synthetic unstamped test entries
    initial.nodeModeEnabled = nodeMode
    return makeServiceNodeStore(initial)
}

/// The service node's announce must carry propagation limits a peer can act on, for the same reason
/// PNNode's must: reference stores field [3] on the `LXMPeer` record for US (Handlers.py:61 →
/// LXMRouter.py:2025) and the SENDER filters its outbound offer against it (LXMPeer.py:370). With 0,
/// `lxm_transfer_size > 0` always holds, so every message is removed AND marked handled — permanent,
/// unretried, silent loss. Parsed back out of the emitted wire bytes, not read off state.
@MainActor @Test func serviceNodeAdvertisesActionablePropagationLimits() async {
    let identity = Identity()
    var initial = LXMFServiceNode.State(
        identity: identity,
        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false),
        minStampCost: 12)
    initial.nodeModeEnabled = true
    let store = TestStore(initialState: initial) { LXMFServiceNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off

    let captured = LockIsolated<Data?>(nil)
    await store.send(.registerPropagation)
    await store.receive { action in
        if case let .client(.endpoint(.announce(_, appData))) = action { captured.setValue(appData); return true }
        return false
    }

    #expect(captured.value != nil)
    if let appData = captured.value {
        #expect(PNAnnounce.isValid(appData))
        let announced = PNAnnounce.parse(appData)
        #expect(announced != nil)
        if let announced {
            #expect(announced.perTransferLimit != 0)
            #expect(announced.perSyncLimit != 0)
            #expect(announced.perTransferLimit == LXMFPropagation.defaultPropagationTransferLimitKB)
            #expect(announced.perSyncLimit == LXMFPropagation.defaultPropagationSyncLimitKB)
            // Reference clamps sync >= transfer (LXMRouter.py:156-157); never advertise the inverse.
            #expect(announced.perSyncLimit >= announced.perTransferLimit)
            // No OTHER announce field may change as a side effect of this fix.
            #expect(announced.timebase == 1700000000)
            #expect(announced.nodeState == true)
            #expect(announced.targetStampCost == 12)
            #expect(announced.stampCostFlexibility == 0)
            #expect(announced.peeringCost == 0)
            #expect(announced.metadata == .map([]))
        }
    }
}

/// registerPropagation registers lxmf.propagation, announces it, and the announce advertises exactly
/// the stamp cost the store enforces (advertised == enforced).
@MainActor @Test func serviceNodeRegistersPropagationAndAdvertisesEnforcedCost() async {
    let identity = Identity()
    var initial = LXMFServiceNode.State(
        identity: identity,
        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false),
        minStampCost: 12)
    initial.nodeModeEnabled = true
    let store = TestStore(initialState: initial) { LXMFServiceNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off

    let expected = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    await store.send(.registerPropagation)
    await store.receive { action in
        if case let .client(.endpoint(.registerLocalDestination(d))) = action {
            #expect(d.hash == expected.hash); return true
        }
        return false
    }
    await store.receive { action in
        if case let .client(.endpoint(.announce(hash, appData))) = action {
            #expect(hash == expected.hash)
            let parsed = PNAnnounce.parse(appData ?? Data())
            #expect(parsed?.targetStampCost == 12)      // advertised == enforced
            #expect(parsed?.nodeState == true)
            return true
        }
        return false
    }
    // The client learns which destination it serves, so it stops treating that link's data as messages.
    #expect(store.state.client.propagationDestinationHash == expected.hash)
}

/// The announced stamp cost must track the store's enforced cost even if only the store is mutated
/// after construction. This is a regression guard against re-introducing a mirrored copy of minStampCost
/// in LXMFServiceNode.State that can drift from the store's enforced value — the exact bug that
/// PNNode had before Task 1 removed its mirror.
@Test @MainActor func serviceNodeAnnouncesStoreEnforcedCostAfterMutation() async {
    let identity = Identity()
    var initial = LXMFServiceNode.State(identity: identity,
                                        endpoint: TCPEndpoint.State(host: "h", port: 1),
                                        minStampCost: 16)
    initial.nodeModeEnabled = true
    initial.pn.store.minStampCost = 21                    // mutate ONLY the store

    let store = TestStore(initialState: initial) { LXMFServiceNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off

    let captured = LockIsolated<Data?>(nil)
    await store.send(.registerPropagation)
    await store.receive { action in
        if case let .client(.endpoint(.announce(_, appData))) = action { captured.setValue(appData); return true }
        return false
    }

    #expect(PNAnnounce.parse(captured.value!)?.targetStampCost == 21)
}

/// A client's offer arriving on the served propagation link is ingested and surfaced for persistence.
@MainActor @Test func serviceNodeIngestsOfferOnPropagationLink() async {
    let identity = Identity()
    let store = makeServiceNode(identity, nodeMode: true)
    let e = Data(repeating: 0xAA, count: LXMessage.destinationLength) + Data("offered".utf8)
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let container = LXMFPropagation.container(timestamp: 1700000000.5, entries: [e])
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let linkID = Data(repeating: 0xC1, count: 16)

    await store.send(.registerPropagation)
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: propDest.hash)))))
    await store.send(.client(.endpoint(.delegate(.resourceReceived(linkID: linkID, data: container)))))

    await store.receive { action in
        if case let .delegate(.messagesStored(entries)) = action {
            #expect(entries.map(\.transientId) == [tid]); return true
        }
        return false
    }
    #expect(store.state.pn.store.contains(transientId: tid))
}

/// Node-mode is the master switch: with it OFF nothing is ingested, bookkept, or served — EVEN when
/// every other precondition for serving is already satisfied.
///
/// The initial state is deliberately ARMED (propagationDestinationHash set, the link registered as
/// terminating on it, and the client already IDENTIFY'd) so that `isPropagationLink` and the IDENTIFY
/// lookup both PASS. That isolates `state.nodeModeEnabled` as the only thing standing between these
/// delegates and the propagation machinery — deleting it from the `resourceReceived` /
/// `linkDataReceived` / `requestReceived` / `linkIdentified` guards makes this test fail. (An
/// un-armed store cannot distinguish "node mode is off" from "propagation was never registered",
/// because the other guards would independently block everything.)
@MainActor @Test func serviceNodeDoesNotServeWhenNodeModeOff() async {
    let identity = Identity()
    let client = Identity()
    let clientHash = LXMessage.deliveryHash(identityHash: client.hash)
    let e = clientHash + Data("ignored".utf8)
    let container = LXMFPropagation.container(timestamp: 1700000000.5, entries: [e])
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let linkID = Data(repeating: 0xC1, count: 16)
    let otherLink = Data(repeating: 0xC2, count: 16)

    // Fully armed EXCEPT the master switch.
    var initial = LXMFServiceNode.State(
        identity: identity,
        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false),
        minStampCost: 0)
    initial.nodeModeEnabled = false
    initial.client.propagationDestinationHash = propDest.hash   // isPropagationLink would pass…
    initial.client.linkDestinations[linkID] = propDest.hash     // …for this link
    initial.clientIdentities[linkID] = client                   // IDENTIFY lookup would pass
    let store = makeServiceNodeStore(initial)

    // Offers on the (otherwise valid) propagation link: both framings must be ignored.
    await store.send(.client(.endpoint(.delegate(.resourceReceived(linkID: linkID, data: container)))))
    await store.send(.client(.endpoint(.delegate(.linkDataReceived(linkID: linkID, data: container,
                                                                   packetHash: Data(repeating: 0xE3, count: 32))))))
    // A fresh IDENTIFY must not be recorded either.
    await store.send(.client(.endpoint(.delegate(.linkIdentified(linkID: otherLink, remoteIdentity: Identity())))))
    // …and a /get from the already-IDENTIFY'd client must not be answered. Sent LAST so a stray
    // .sendResponseOverLink survives in receivedActions until the .on teardown below.
    await store.send(.client(.endpoint(.delegate(.requestReceived(
        linkID: linkID, requestID: Data([1]),
        pathHash: Crypto.truncatedHash(Data("/get".utf8)),
        data: MsgPack.encode(.array([.null, .null])))))))

    store.exhaustivity = .on   // a stray .client(.endpoint(.sendResponseOverLink)) now fails teardown

    #expect(store.state.pn.store.count == 0)               // nothing ingested by either framing
    #expect(store.state.clientIdentities[otherLink] == nil) // no new serve bookkeeping
    #expect(store.state.pendingGet.isEmpty)                // the /get was never accepted
}

/// `.setNodeMode` arms (registers + announces the propagation destination) and disarms (drops the
/// served destination and all serve bookkeeping so the client resumes normal handling).
@MainActor @Test func serviceNodeSetNodeModeArmsThenDisarms() async {
    let identity = Identity()
    let client = Identity()
    let store = makeServiceNode(identity, nodeMode: false)
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let linkID = Data(repeating: 0xC1, count: 16)

    // Arm.
    await store.send(.setNodeMode(true))
    await store.receive { if case .registerPropagation = $0 { return true }; return false }
    #expect(store.state.nodeModeEnabled)
    #expect(store.state.client.propagationDestinationHash == propDest.hash)

    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: propDest.hash)))))
    await store.send(.client(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: client)))))
    #expect(store.state.clientIdentities[linkID] == client)

    // Disarm: every serve-side table is cleared. propagationDestinationHash is intentionally KEPT —
    // the destination cannot be unregistered, so links to it are still accepted; retaining the hint
    // ensures arriving data is classified and dropped rather than misrouted as a direct message.
    await store.send(.setNodeMode(false))
    #expect(store.state.nodeModeEnabled == false)
    #expect(store.state.client.propagationDestinationHash == propDest.hash)   // retained (Important-4)
    #expect(store.state.clientIdentities.isEmpty)
    #expect(store.state.pendingGet.isEmpty)
}

/// Link routing: with node-mode ON, data arriving on a link that does NOT terminate on the
/// propagation destination we serve is NOT an offer — it is the client's own inbound traffic and must
/// never reach the propagation store. Covers BOTH framings the production code guards
/// (`resourceReceived` and `linkDataReceived`).
///
/// This is the mirror image of Task 2's `clientIgnoresLinkDataOnServedPropagationLink`, which asserts
/// the LXMFNode side (the client stops delivering on the SERVED link). Here we assert the service-node
/// side: the propagation store stays empty for the NON-served link.
@MainActor @Test func serviceNodeIgnoresDataOnNonPropagationLink() async {
    let identity = Identity()
    let store = makeServiceNode(identity, nodeMode: true)
    let e = Data(repeating: 0xAA, count: LXMessage.destinationLength) + Data("not-an-offer".utf8)
    let container = LXMFPropagation.container(timestamp: 1700000000.5, entries: [e])
    let otherHash = Data(repeating: 0x5B, count: 16)     // some correspondent, NOT our propagation dest
    let otherLink = Data(repeating: 0xC2, count: 16)

    await store.send(.registerPropagation)               // we ARE serving — but not on this link
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: otherLink, destinationHash: otherHash)))))

    // NOTE: in a `.off` TestStore, state produced by an effect-emitted action is not visible via
    // `store.state` until those actions are drained, so each leg is flushed with
    // `skipReceivedActions` before asserting. Without the flush the assertion reads pre-effect state
    // and would pass even when the container WAS ingested.

    // Framing 1: a concluded resource on the non-propagation link.
    await store.send(.client(.endpoint(.delegate(.resourceReceived(linkID: otherLink, data: container)))))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.pn.store.count == 0)

    // Framing 2: the same bytes as plain link data on the non-propagation link.
    await store.send(.client(.endpoint(.delegate(.linkDataReceived(linkID: otherLink, data: container,
                                                                   packetHash: Data(repeating: 0xE4, count: 32))))))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.pn.store.count == 0)
    #expect(store.state.pn.store.contains(transientId: LXMFPropagation.transientId(lxmfData: e)) == false)
}

/// IDENTIFY gate: a /get on a link that never IDENTIFY'd must be answered with `ERROR_NO_IDENTITY`
/// (0xF0) as the response BODY — not silently dropped.
///
/// Reference: `LXMRouter.message_get_request` returns `LXMPeer.ERROR_NO_IDENTITY` when
/// `remote_identity == None` (LXMRouter.py:1483; the constant is LXMPeer.py:24). Reference clients
/// compare the decoded response to that integer (LXMRouter.py:1563 / :1608) to tear the link down
/// immediately and set `PR_NO_IDENTITY_RCVD`. Dropping instead makes them wait out the full request
/// timeout. The encoding must be the reference's: `umsgpack.packb(0xf0)` → uint8 `CC F0`.
///
/// Also asserts the request is NOT queued: an error response ends the exchange, so a `pendingGet`
/// entry would be an orphan that only a link close could clear.
@MainActor @Test func serviceNodeAnswersErrorNoIdentityWhenNotIdentified() async {
    let identity = Identity()
    let store = makeServiceNode(identity, nodeMode: true)
    let client = Identity()
    let clientHash = LXMessage.deliveryHash(identityHash: client.hash)
    let e = clientHash + Data("for-drop".utf8)
    let container = LXMFPropagation.container(timestamp: 1700000000.5, entries: [e])
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let linkID = Data(repeating: 0xC1, count: 16)

    await store.send(.registerPropagation)
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: propDest.hash)))))
    await store.send(.client(.endpoint(.delegate(.resourceReceived(linkID: linkID, data: container)))))
    await store.receive { if case .delegate(.messagesStored) = $0 { return true }; return false }

    // No IDENTIFY → the reference error, back on the same link/request.
    await store.send(.client(.endpoint(.delegate(.requestReceived(
        linkID: linkID, requestID: Data([9]),
        pathHash: Crypto.truncatedHash(Data("/get".utf8)),
        data: MsgPack.encode(.array([.null, .null])))))))

    await store.receive { action in
        if case let .client(.endpoint(.sendResponseOverLink(lid, rid, data))) = action {
            #expect(lid == linkID)
            #expect(rid == Data([9]))
            // Value the reference client compares against…
            #expect(MsgPack.decodeValue(data) == .uint(0xF0))
            // …and the exact bytes `umsgpack.packb(0xf0)` produces.
            #expect(data == Data([0xCC, 0xF0]))
            return true
        }
        return false
    }
    // The failed request must not be left queued.
    #expect(store.state.pendingGet.isEmpty)
}

/// Two-phase /get. Only IDENTIFY'd clients are served (reference LXMRouter.py:1483 ERROR_NO_IDENTITY).
@MainActor @Test func serviceNodeServesTwoPhaseGetForIdentifiedClient() async {
    let identity = Identity()
    let store = makeServiceNode(identity, nodeMode: true)
    let client = Identity()
    let clientHash = LXMessage.deliveryHash(identityHash: client.hash)
    let e = clientHash + Data("for-client".utf8)
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let container = LXMFPropagation.container(timestamp: 1700000000.5, entries: [e])
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let linkID = Data(repeating: 0xC1, count: 16)
    let getPath = Crypto.truncatedHash(Data("/get".utf8))

    await store.send(.registerPropagation)
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: propDest.hash)))))
    await store.send(.client(.endpoint(.delegate(.resourceReceived(linkID: linkID, data: container)))))
    await store.receive { if case .delegate(.messagesStored) = $0 { return true }; return false }

    // IDENTIFY, then phase-1 → id list.
    await store.send(.client(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: client)))))
    await store.send(.client(.endpoint(.delegate(.requestReceived(
        linkID: linkID, requestID: Data([1]), pathHash: getPath,
        data: MsgPack.encode(.array([.null, .null])))))))
    await store.receive { action in
        if case let .client(.endpoint(.sendResponseOverLink(lid, rid, data))) = action {
            #expect(lid == linkID); #expect(rid == Data([1]))
            #expect(MsgPack.decodeValue(data) == .array([.bin(tid)])); return true
        }
        return false
    }

    // Phase-2 → the blob (served stampless; this synthetic entry is already stampless).
    await store.send(.client(.endpoint(.delegate(.requestReceived(
        linkID: linkID, requestID: Data([2]), pathHash: getPath,
        data: MsgPack.encode(.array([.array([.bin(tid)]), .array([])])))))))
    await store.receive { action in
        if case let .client(.endpoint(.sendResponseOverLink(_, rid, data))) = action {
            #expect(rid == Data([2]))
            #expect(MsgPack.decodeValue(data) == .array([.bin(e)])); return true
        }
        return false
    }
}

/// End-to-end over a REAL link: client C offers a stamped container to an LXMFServiceNode in node-mode
/// (ingested + persisted-signal), then IDENTIFYs and runs the two-phase /get; the node serves C's id list
/// and blob, and C opens the blob to the original signature-valid message.
@Test @MainActor func serviceNodeIngestsAndServesOverRealLink() async {
    let clock = TestClock()
    let nodeIdentity = Identity()
    let cIdentity = Identity()      // the client AND the recipient of the stored message
    let sIdentity = Identity()      // the original sender
    let cDeliveryHash = LXMessage.deliveryHash(identityHash: cIdentity.hash)

    // A real stamped container at the cost the node enforces.
    let msg = LXMessage.create(source: sIdentity, destinationHash: cDeliveryHash,
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("hi C".utf8))
    let (container, tid) = LXMFPropagation.pack(message: msg, recipientIdentity: cIdentity,
                                                timestamp: 1700000000.5, stampCost: 4)

    func makeNode(_ host: String, _ sent: LockIsolated<[Data]>)
        -> (TestStore<LXMFServiceNode.State, LXMFServiceNode.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        var initial = LXMFServiceNode.State(
            identity: nodeIdentity,
            endpoint: TCPEndpoint.State(host: host, port: 4242, reconnectOnDrop: false),
            minStampCost: 4)
        initial.nodeModeEnabled = true
        let store = TestStore(initialState: initial) { LXMFServiceNode() } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } }, close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    func makeClient(_ host: String, _ sent: LockIsolated<[Data]>)
        -> (TestStore<TCPEndpoint.State, TCPEndpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: TCPEndpoint.State(host: host, port: 4242, reconnectOnDrop: false)) {
            TCPEndpoint()
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } }, close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    func nodeSend(_ act: LXMFServiceNode.Action) -> Bool {
        if case .client(.endpoint(.tcp(.interface(.send)))) = act { return true }; return false
    }
    func cSend(_ act: TCPEndpoint.Action) -> Bool { if case .interface(.send) = act { return true }; return false }

    let sentNode = LockIsolated<[Data]>([])
    let sentC = LockIsolated<[Data]>([])
    let (node, eventsNode) = makeNode("node", sentNode)
    let (c, eventsC) = makeClient("c", sentC)

    await node.send(.client(.endpoint(.tcp(.connect)))); eventsNode.yield(.connected)
    await c.send(.connect); eventsC.yield(.connected)

    // Node registers + announces lxmf.propagation; bridge the announce so C learns its path + identity.
    await node.send(.registerPropagation)
    await node.receive { if case .client(.endpoint(.registerLocalDestination)) = $0 { return true }; return false }
    await node.receive(nodeSend)   // announce frame out
    eventsC.yield(.data(sentNode.value.last!))
    await c.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }

    // C opens a link to the node's propagation destination.
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: nodeIdentity)!
    await c.send(.openLink(destinationHash: propDest.hash))
    await c.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await c.receive(cSend)         // LINKREQUEST out

    // Handshake: LINKREQUEST → node (LRPROOF out); LRPROOF → C (LRRTT out); LRRTT → node (both active).
    eventsNode.yield(.data(sentC.value.last!))
    await node.receive(nodeSend)   // LRPROOF out
    let lrrttIdx = sentC.value.count
    eventsC.yield(.data(sentNode.value.last!))
    await c.receive(cSend)         // LRRTT out
    let lrrttBytes = sentC.value[lrrttIdx]
    eventsNode.yield(.data(lrrttBytes))
    await c.receive { if case .delegate(.linkEstablished) = $0 { return true }; return false }
    await node.receive { if case .client(.endpoint(.delegate(.linkEstablished))) = $0 { return true }; return false }

    let linkID = c.state.links[0].linkID

    // C offers the container as a Resource.
    await c.send(.sendResourceOverLink(linkID: linkID, data: container))
    await c.receive(cSend)         // RESOURCE_ADV out
    eventsNode.yield(.data(sentC.value.last!))
    await node.receive(nodeSend)   // RESOURCE_REQ out
    eventsC.yield(.data(sentNode.value.last!))
    let partCount = c.state.links[0].transfers[0].parts.count
    for _ in 0..<partCount { await c.receive(cSend) }

    let parts = Array(sentC.value.suffix(partCount))
    for (i, frame) in parts.enumerated() {
        eventsNode.yield(.data(frame))
        if i == partCount - 1 {
            await node.receive(nodeSend)   // RESOURCE_PRF out
            await node.receive { action in
                if case let .delegate(.messagesStored(entries)) = action {
                    #expect(entries.map(\.transientId) == [tid]); return true
                }
                return false
            }
        }
    }

    // C identifies.
    await c.send(.identifyOverLink(linkID: linkID, identity: cIdentity))
    await c.receive(cSend)
    eventsNode.yield(.data(sentC.value.last!))
    await node.receive { if case .client(.endpoint(.delegate(.linkIdentified))) = $0 { return true }; return false }

    // Phase-1 /get → id list.
    await c.send(.sendRequestOverLink(linkID: linkID, path: "/get",
                                      data: MsgPack.encode(.array([.null, .null]))))
    await c.receive(cSend)
    eventsNode.yield(.data(sentC.value.last!))
    await node.receive { if case .client(.endpoint(.delegate(.requestReceived))) = $0 { return true }; return false }
    await node.receive(nodeSend)   // response frame out
    let gotList = LockIsolated<Data?>(nil)
    eventsC.yield(.data(sentNode.value.last!))
    await c.receive { action in
        if case let .delegate(.responseReceived(_, _, d)) = action { gotList.setValue(d); return true }
        return false
    }
    #expect(MsgPack.decodeValue(gotList.value!) == .array([.bin(tid)]))

    // Phase-2 /get → the blob, served STAMPLESS (reference LXMRouter.py:1551).
    await c.send(.sendRequestOverLink(linkID: linkID, path: "/get",
                                      data: MsgPack.encode(.array([.array([.bin(tid)]), .array([])]))))
    await c.receive(cSend)
    eventsNode.yield(.data(sentC.value.last!))
    await node.receive { if case .client(.endpoint(.delegate(.requestReceived))) = $0 { return true }; return false }
    await node.receive(nodeSend)   // response frame out
    let gotBlob = LockIsolated<Data?>(nil)
    eventsC.yield(.data(sentNode.value.last!))
    await c.receive { action in
        if case let .delegate(.responseReceived(_, _, d)) = action { gotBlob.setValue(d); return true }
        return false
    }

    // The served blob opens to the original signature-valid message, and its full_hash == the stored key
    // (so a reference client's phase-3 purge would match — the invariant the live purge bug violated).
    guard case let .array(items)? = MsgPack.decodeValue(gotBlob.value!), case let .bin(served)? = items.first
    else { Issue.record("phase-2 response was not [bin]"); return }
    #expect(LXMFPropagation.transientId(lxmfData: served) == tid)
    let recovered = LXMFPropagation.open(lxmfData: served, recipientIdentity: cIdentity)
    #expect(recovered?.content == Data("hi C".utf8))
    #expect(recovered?.validateSignature(source: sIdentity) == true)

    await node.send(.client(.endpoint(.tcp(.disconnect)))); await c.send(.disconnect)
}

// MARK: - Inbound packet proving (reference LXMRouter.py:2255 `packet.prove()`)

/// A PACKET-framed offer on the served propagation link is ingested AND proved.
///
/// Reference `LXMRouter.propagation_packet` calls `packet.prove()` after ingesting
/// (LXMRouter.py:2255). Reference clients take that PACKET path whenever the packed propagation
/// payload fits the link MDU (LXMessage.py:426-444) — the ordinary chat-sized case — and block on
/// the resulting packet receipt, so without the proof the message is stored but never marked sent.
@MainActor @Test func serviceNodeProvesPacketOfferOnPropagationLink() async {
    let identity = Identity()
    let store = makeServiceNode(identity, nodeMode: true)
    let e = Data(repeating: 0xAA, count: LXMessage.destinationLength) + Data("packet-offer".utf8)
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let container = LXMFPropagation.container(timestamp: 1700000000.5, entries: [e])
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let linkID = Data(repeating: 0xC1, count: 16)
    let packetHash = Data(repeating: 0xF7, count: 32)

    await store.send(.registerPropagation)
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: propDest.hash)))))
    await store.send(.client(.endpoint(.delegate(.linkDataReceived(linkID: linkID, data: container,
                                                                   packetHash: packetHash)))))

    // Proved, on the SAME link, for exactly the packet that carried the offer.
    // (Asserted before `messagesStored`: in a `.off` store `receive` SKIPS non-matching actions, and
    // the prove is one hop from `linkDataReceived` while `messagesStored` is three — asserting the
    // store signal first would silently swallow the prove and make this test vacuous.)
    await store.receive { action in
        if case let .client(.endpoint(.provePacketOverLink(lid, h))) = action {
            #expect(lid == linkID)
            #expect(h == packetHash)
            return true
        }
        return false
    }
    // …and ingested.
    await store.receive { action in
        if case let .delegate(.messagesStored(entries)) = action {
            #expect(entries.map(\.transientId) == [tid]); return true
        }
        return false
    }
    #expect(store.state.pn.store.contains(transientId: tid))
}

/// NEGATIVE 1 — a data packet on a NON-propagation link must NOT be proved. RNS does not blanket-prove
/// inbound data packets (`proof_strategy`, default `PROVE_NONE`); ReTiCA stays an RNS-faithful
/// non-proving client everywhere except the propagation offers it serves.
///
/// The store is armed for serving (node-mode on, propagation registered) so only the
/// `isPropagationLink` classification stands between this packet and a proof.
@MainActor @Test func serviceNodeDoesNotProvePacketOnNonPropagationLink() async {
    let identity = Identity()
    let store = makeServiceNode(identity, nodeMode: true)
    let otherHash = Data(repeating: 0x5B, count: 16)     // some correspondent, NOT our propagation dest
    let otherLink = Data(repeating: 0xC2, count: 16)

    await store.send(.registerPropagation)               // we ARE serving — but not on this link
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: otherLink, destinationHash: otherHash)))))
    await store.skipReceivedActions(strict: false)       // drain setup effects

    // A `.off` store alone would NOT catch a stray provePacketOverLink at teardown, so flip to .on
    // for the send under test: the stray action then fails teardown.
    store.exhaustivity = .on
    await store.send(.client(.endpoint(.delegate(.linkDataReceived(linkID: otherLink, data: Data("msg".utf8),
                                                                   packetHash: Data(repeating: 0xF8, count: 32))))))
    await store.receive { if case .client(.router(.received)) = $0 { return true }; return false }
}

/// NEGATIVE 2 — with node-mode OFF, a packet on the (otherwise fully armed) propagation link must not
/// be proved either. Deliberately armed so `isPropagationLink` PASSES and `nodeModeEnabled` is the
/// only thing left standing between the packet and a proof.
@MainActor @Test func serviceNodeDoesNotProvePacketWhenNodeModeOff() async {
    let identity = Identity()
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let linkID = Data(repeating: 0xC1, count: 16)

    var initial = LXMFServiceNode.State(
        identity: identity,
        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false),
        minStampCost: 0)
    initial.nodeModeEnabled = false
    initial.client.propagationDestinationHash = propDest.hash   // isPropagationLink would pass…
    initial.client.linkDestinations[linkID] = propDest.hash     // …for this link
    let store = makeServiceNodeStore(initial)

    store.exhaustivity = .on   // a stray provePacketOverLink now fails teardown
    await store.send(.client(.endpoint(.delegate(.linkDataReceived(linkID: linkID, data: Data("offer".utf8),
                                                                   packetHash: Data(repeating: 0xF9, count: 32))))))
}

// MARK: - Wire-level transfer limit of 0 means "serve nothing"

/// A client-sent per-transfer limit of 0 is a 0-BYTE CAP, not "unlimited". The reference computes
/// `client_transfer_limit = float(data[2])*1000` (LXMRouter.py:1526-1529) and then skips every message
/// whose cumulative size would exceed it (LXMRouter.py:1547) — with a cap of 0 that is every message.
///
/// This drives the /get through `LXMFServiceNode` so the msgpack PARSE path is exercised: the existing
/// `propagationNodeZeroTransferLimitServesNothing` test calls `PropagationNode` directly with
/// `transferLimitBytes: 0` and therefore could not catch a `kb > 0` guard turning wire-0 into nil.
@MainActor @Test func serviceNodeParsesWireZeroTransferLimitAsServeNothing() async {
    let identity = Identity()
    let store = makeServiceNode(identity, nodeMode: true)
    let client = Identity()
    let clientHash = LXMessage.deliveryHash(identityHash: client.hash)
    let e = clientHash + Data("too-big-for-a-zero-cap".utf8)
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let container = LXMFPropagation.container(timestamp: 1700000000.5, entries: [e])
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let linkID = Data(repeating: 0xC1, count: 16)
    let getPath = Crypto.truncatedHash(Data("/get".utf8))

    await store.send(.registerPropagation)
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: propDest.hash)))))
    await store.send(.client(.endpoint(.delegate(.resourceReceived(linkID: linkID, data: container)))))
    await store.receive { if case .delegate(.messagesStored) = $0 { return true }; return false }
    await store.send(.client(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: client)))))

    // Phase-2 /get WITH an explicit wire-level limit of 0 in data[2].
    await store.send(.client(.endpoint(.delegate(.requestReceived(
        linkID: linkID, requestID: Data([7]), pathHash: getPath,
        data: MsgPack.encode(.array([.array([.bin(tid)]), .array([]), .uint(0)])))))))

    // The parsed limit must be a 0-byte cap, not nil.
    await store.receive { action in
        if case let .pn(.messagesRequested(_, _, _, limit)) = action {
            #expect(limit == 0, "wire-level 0 must parse to a 0-byte cap, not nil (unlimited)")
            return true
        }
        return false
    }
    // …so nothing is served.
    await store.receive { action in
        if case let .client(.endpoint(.sendResponseOverLink(_, rid, data))) = action {
            #expect(rid == Data([7]))
            #expect(MsgPack.decodeValue(data) == .array([]), "a 0-byte cap must serve nothing")
            return true
        }
        return false
    }
    #expect(store.state.pn.store.contains(transientId: tid))   // still stored, just not served
}

// MARK: - Important-4: propagationDestinationHash retained on disarm

/// On `setNodeMode(false)`, `propagationDestinationHash` MUST be kept (not cleared) so data arriving
/// on the still-open lxmf.propagation link is classified and dropped rather than misrouted as a
/// direct delivery message. Every serve behaviour is independently gated on `nodeModeEnabled`, so the
/// hint's retention is safe and necessary.
@MainActor @Test func serviceNodeRetainsPropDestHashAfterDisarm() async {
    let identity = Identity()
    let store = makeServiceNode(identity, nodeMode: false)
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!

    await store.send(.setNodeMode(true))
    await store.receive { if case .registerPropagation = $0 { return true }; return false }
    #expect(store.state.client.propagationDestinationHash == propDest.hash)

    await store.send(.setNodeMode(false))
    // propagationDestinationHash must NOT be cleared — the lxmf.propagation destination still
    // accepts incoming links; clearing the hint would misroute their data as direct messages.
    #expect(store.state.client.propagationDestinationHash == propDest.hash)
    // Serve-side tables ARE cleared.
    #expect(store.state.clientIdentities.isEmpty)
    #expect(store.state.pendingGet.isEmpty)

    // And with node-mode off, data on the propagation link IS still suppressed (not misrouted).
    let linkID = Data(repeating: 0xC1, count: 16)
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: propDest.hash)))))
    await store.send(.client(.endpoint(.delegate(.linkDataReceived(linkID: linkID, data: Data("offer".utf8),
                                                                   packetHash: Data(repeating: 0xE5, count: 32))))))
    store.exhaustivity = .on   // no stray .router(.received) from the disabled-but-still-open link
}

// MARK: - Minor-4: requestReceived gated on propagation link

/// A /get request arriving on a NON-propagation link (e.g. the delivery link) must be silently dropped.
/// Without this guard a delivery-link peer could trigger the /get handler (Important-3 compounds this
/// since no ownership check on haves = cross-destination eviction).
@MainActor @Test func serviceNodeDropsGetRequestOnNonPropagationLink() async {
    let identity = Identity()
    let client = Identity()
    let otherHash = Data(repeating: 0x5B, count: 16)   // some correspondent, NOT our propagation dest
    let deliveryLink = Data(repeating: 0xD1, count: 16)

    // Pre-arm: seed clientIdentities directly so only the isPropagationLink guard on requestReceived
    // stands between the /get and a response. Without this, the IDENTIFY guard also blocks it and the
    // test cannot distinguish which guard is effective.
    var initial = LXMFServiceNode.State(
        identity: identity,
        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false),
        minStampCost: 0)
    initial.nodeModeEnabled = true
    initial.clientIdentities[deliveryLink] = client    // bypass the IDENTIFY guard — only isPropagationLink matters
    let store = makeServiceNodeStore(initial)

    await store.send(.registerPropagation)
    // The delivery link terminates on a different destination.
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: deliveryLink, destinationHash: otherHash)))))

    // A /get on the non-propagation link must be dropped even though the client is IDENTIFY'd.
    // Without the isPropagationLink guard, a stray .sendResponseOverLink would appear here.
    await store.send(.client(.endpoint(.delegate(.requestReceived(
        linkID: deliveryLink, requestID: Data([99]),
        pathHash: Crypto.truncatedHash(Data("/get".utf8)),
        data: MsgPack.encode(.array([.null, .null])))))))

    store.exhaustivity = .on   // a stray .sendResponseOverLink would fail teardown
    #expect(store.state.pendingGet.isEmpty)
}

/// linkIdentified on a non-propagation link must NOT be recorded in `clientIdentities`.
/// Without this guard a delivery-link peer's identity leaks into the serve bookkeeping and could be
/// misused by a subsequent /get gating check.
@MainActor @Test func serviceNodeIgnoresLinkIdentifiedOnNonPropagationLink() async {
    let identity = Identity()
    let client = Identity()
    let store = makeServiceNode(identity, nodeMode: true)
    let otherHash = Data(repeating: 0x5B, count: 16)
    let deliveryLink = Data(repeating: 0xD1, count: 16)

    await store.send(.registerPropagation)
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: deliveryLink, destinationHash: otherHash)))))
    await store.send(.client(.endpoint(.delegate(.linkIdentified(linkID: deliveryLink, remoteIdentity: client)))))

    #expect(store.state.clientIdentities[deliveryLink] == nil)   // must not have been recorded
}

// MARK: - Minor-3: concurrent /get queue

/// Two concurrent /get requests from the same identity (e.g. a client retry before the first
/// response arrives) must be served in FIFO order. The second request must NOT silently overwrite
/// the first (which would leave the first's linkID orphaned with no response).
///
/// Verification strategy: pre-seed ONE pending /get (req1, linkID1) in the initial state, then
/// send requestReceived for req2 on linkID2. With the fix (append), the queue grows to [req1, req2].
/// With the scalar mutation (overwrite), the queue becomes [req2] and req1 is lost. We then check
/// that the response to the first deliverMessageList goes to linkID1 (FIFO) — with the mutation it
/// would go to linkID2 (the overwritten entry), failing the assertion.
@MainActor @Test func serviceNodeQueuesConcurrentGets() async {
    let identity = Identity()
    let client = Identity()
    let clientHash = LXMessage.deliveryHash(identityHash: client.hash)
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let linkID1 = Data(repeating: 0xC1, count: 16)
    let linkID2 = Data(repeating: 0xC2, count: 16)
    let reqID1 = Data([1])
    let reqID2 = Data([2])
    let getPath = Crypto.truncatedHash(Data("/get".utf8))

    // Pre-seed the initial state with req1 already in the queue and both links set up.
    var initial = LXMFServiceNode.State(
        identity: identity,
        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false),
        minStampCost: 0)
    initial.nodeModeEnabled = true
    initial.client.propagationDestinationHash = propDest.hash
    initial.client.linkDestinations[linkID1] = propDest.hash
    initial.client.linkDestinations[linkID2] = propDest.hash
    initial.clientIdentities[linkID2] = client    // only linkID2 needs IDENTIFY (req1 is pre-seeded)
    // req1 is already in the queue — simulates it arriving before req2 was sent.
    initial.pendingGet[clientHash] = [LXMFServiceNode.PendingGet(linkID: linkID1, requestID: reqID1)]
    let store = makeServiceNodeStore(initial)

    // req2 arrives on linkID2. With the fix, this APPENDS; with the mutation, this OVERWRITES req1.
    await store.send(.client(.endpoint(.delegate(.requestReceived(
        linkID: linkID2, requestID: reqID2, pathHash: getPath,
        data: MsgPack.encode(.array([.null, .null])))))))
    // NOTE: This also triggers a messageListRequested effect which produces a deliverMessageList
    // which pops from the queue. With the fix (queue=[req1,req2]) the pop returns req1 → responds
    // to linkID1. With the mutation (queue=[req2]) the pop returns req2 → responds to linkID2.
    await store.receive { action in
        if case let .client(.endpoint(.sendResponseOverLink(lid, rid, _))) = action {
            // The FIRST response must be to req1/linkID1 (the pre-existing entry, FIFO order).
            // With the scalar mutation this would be req2/linkID2 → test FAILS.
            #expect(lid == linkID1, "FIFO: pre-existing req1 must be answered before the new req2")
            #expect(rid == reqID1)
            return true
        }
        return false
    }
    // req2 must still be in the queue (req1 was answered, req2 is next).
    #expect((store.state.pendingGet[clientHash] ?? []).count == 1)
}

// MARK: - Minor-2: syncPhase leak on link close

/// `syncPhase` must be cleared when a link closes (Minor-2). Without this, a sync that dies
/// mid-phase (e.g. network drop) leaves a stale entry in `syncPhase` for the closed linkID
/// permanently — it can never be GC'd because no other code path touches it.
@MainActor @Test func lxmfNodeClearsSyncPhaseOnLinkClose() async {
    let identity = Identity()
    var initial = LXMFNode.State(identity: identity,
                                  endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    let linkID = Data(repeating: 0xC1, count: 16)
    // Simulate a mid-phase sync that is interrupted: plant syncPhase state directly.
    initial.syncPhase[linkID] = .awaitingMessages
    initial.linkDestinations[linkID] = Data(repeating: 0xAB, count: 16)

    let store = TestStore(initialState: initial) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off

    await store.send(.endpoint(.delegate(.linkClosed(linkID: linkID, reason: .initiatorClosed))))
    await store.skipReceivedActions(strict: false)

    #expect(store.state.syncPhase[linkID] == nil)   // must have been cleared
}

// MARK: - Phase-3 purge

/// Phase-3 purge: the client's `haves` evict from the store and surface for the host's mirror.
@MainActor @Test func serviceNodePurgesOnHavesAndSurfacesIt() async {
    let identity = Identity()
    let store = makeServiceNode(identity, nodeMode: true)
    let client = Identity()
    let clientHash = LXMessage.deliveryHash(identityHash: client.hash)
    let e = clientHash + Data("purge-me".utf8)
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let container = LXMFPropagation.container(timestamp: 1700000000.5, entries: [e])
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let linkID = Data(repeating: 0xC1, count: 16)

    await store.send(.registerPropagation)
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: propDest.hash)))))
    await store.send(.client(.endpoint(.delegate(.resourceReceived(linkID: linkID, data: container)))))
    await store.receive { if case .delegate(.messagesStored) = $0 { return true }; return false }
    await store.send(.client(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: client)))))

    await store.send(.client(.endpoint(.delegate(.requestReceived(
        linkID: linkID, requestID: Data([3]), pathHash: Crypto.truncatedHash(Data("/get".utf8)),
        data: MsgPack.encode(.array([.null, .array([.bin(tid)])])))))))

    await store.receive { action in
        if case let .delegate(.messagesPurged(ids)) = action { #expect(ids == [tid]); return true }
        return false
    }
    #expect(store.state.pn.store.contains(transientId: tid) == false)
}

// MARK: - FIX 1 + FIX 6: transfer limit parse — clamp and float support

/// A wire-level UInt64.max in data[2] must NOT trap. The reference reads the limit via `float(data[2])`
/// (LXMRouter.py:1528), which saturates rather than trapping. Our clamp caps to Int.max.
/// UInt64.max * 1000 would overflow Int; with the fix it clamps to Int.max (effectively unlimited).
///
/// The crash was: `Fatal error: Not enough bits to represent the passed value` at `Int(kb) * 1000`.
@MainActor @Test func serviceNodeClampsUInt64MaxTransferLimit() async {
    let identity = Identity()
    let store = makeServiceNode(identity, nodeMode: true)
    let client = Identity()
    let clientHash = LXMessage.deliveryHash(identityHash: client.hash)
    let e = clientHash + Data("any".utf8)
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let container = LXMFPropagation.container(timestamp: 1700000000.5, entries: [e])
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let linkID = Data(repeating: 0xC1, count: 16)
    let getPath = Crypto.truncatedHash(Data("/get".utf8))

    await store.send(.registerPropagation)
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: propDest.hash)))))
    await store.send(.client(.endpoint(.delegate(.resourceReceived(linkID: linkID, data: container)))))
    await store.receive { if case .delegate(.messagesStored) = $0 { return true }; return false }
    await store.send(.client(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: client)))))

    // data[2] = UInt64.max — previously trapped with "Not enough bits to represent the passed value".
    // With the clamp fix this must not crash and must parse as Int.max (effectively unlimited),
    // so the message IS served (no transfer limit cap reached).
    await store.send(.client(.endpoint(.delegate(.requestReceived(
        linkID: linkID, requestID: Data([8]), pathHash: getPath,
        data: MsgPack.encode(.array([.array([.bin(tid)]), .array([]), .uint(UInt64.max)])))))))

    // Must succeed: the clamped limit is Int.max, so the message fits and is served.
    await store.receive { action in
        if case let .pn(.messagesRequested(_, _, _, limit)) = action {
            #expect(limit == Int.max, "UInt64.max must clamp to Int.max, not trap")
            return true
        }
        return false
    }
}

/// A float-valued data[2] (e.g. from a reference client that sends `float(kb)`) must be accepted and
/// parsed. Without the `.double` arm a float limit silently becomes nil (unlimited), hiding the cap.
@MainActor @Test func serviceNodeParsesFloatTransferLimit() async {
    let identity = Identity()
    let store = makeServiceNode(identity, nodeMode: true)
    let client = Identity()
    let clientHash = LXMessage.deliveryHash(identityHash: client.hash)
    let e = clientHash + Data("any".utf8)
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let container = LXMFPropagation.container(timestamp: 1700000000.5, entries: [e])
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let linkID = Data(repeating: 0xC1, count: 16)
    let getPath = Crypto.truncatedHash(Data("/get".utf8))

    await store.send(.registerPropagation)
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: propDest.hash)))))
    await store.send(.client(.endpoint(.delegate(.resourceReceived(linkID: linkID, data: container)))))
    await store.receive { if case .delegate(.messagesStored) = $0 { return true }; return false }
    await store.send(.client(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: client)))))

    // data[2] = 500.0 (float) → transferLimitBytes should be 500000.
    await store.send(.client(.endpoint(.delegate(.requestReceived(
        linkID: linkID, requestID: Data([9]), pathHash: getPath,
        data: MsgPack.encode(.array([.array([.bin(tid)]), .array([]), .double(500.0)])))))))

    await store.receive { action in
        if case let .pn(.messagesRequested(_, _, _, limit)) = action {
            #expect(limit == 500_000, "float 500.0 must parse to 500000 bytes, not nil")
            return true
        }
        return false
    }
}

// MARK: - FIX 6: Task 6 — float64 NaN / negative / infinite transfer limit must not abort

/// Helper: sends a /get phase-2 request with the given data[2] value and returns the transferLimitBytes
/// the reducer forwards to PropagationNode. Used by all Task-6 trap tests to avoid boilerplate.
@MainActor private func getTransferLimit(
    limitElement: MsgPackValue,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> Int?? {
    let identity = Identity()
    let store = makeServiceNode(identity, nodeMode: true)
    let client = Identity()
    let clientHash = LXMessage.deliveryHash(identityHash: client.hash)
    let e = clientHash + Data("limit-test".utf8)
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let container = LXMFPropagation.container(timestamp: 1700000000.5, entries: [e])
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let linkID = Data(repeating: 0xC1, count: 16)
    let getPath = Crypto.truncatedHash(Data("/get".utf8))

    await store.send(.registerPropagation)
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: propDest.hash)))))
    await store.send(.client(.endpoint(.delegate(.resourceReceived(linkID: linkID, data: container)))))
    await store.receive { if case .delegate(.messagesStored) = $0 { return true }; return false }
    await store.send(.client(.endpoint(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: client)))))

    await store.send(.client(.endpoint(.delegate(.requestReceived(
        linkID: linkID, requestID: Data([42]), pathHash: getPath,
        data: MsgPack.encode(.array([.array([.bin(tid)]), .array([]), limitElement])))))))

    let captured = LockIsolated<Int??>(nil)
    await store.receive { action in
        if case let .pn(.messagesRequested(_, _, _, limit)) = action {
            captured.setValue(limit)
            return true
        }
        return false
    }
    return captured.value
}

/// `float64(NaN)` in data[2] must not trap. The previous partial guard (`raw >= Double(Int.max)`)
/// evaluated to false for NaN, falling straight through to `Int(NaN)` and aborting the process.
///
/// The value we choose is a DELIBERATE DIVERGENCE from reference, and the only one in this switch.
/// Reference keeps the cap as a float (`LXMRouter.py:1528`) and skips a message only when
/// `next_size > client_transfer_limit`; against NaN that comparison is FALSE, so reference serves
/// EVERYTHING — a NaN cap silently disables the cap the client just asked for. We serve NOTHING (0).
/// Rationale: the permissive reading lets any client opt out of its own limit, and no legitimate
/// client sends NaN, so the restrictive direction costs no interop. Verified by modelling
/// `LXMRouter.py:1525-1547`; do not "restore parity" here without re-reading that reasoning.
@MainActor @Test func serviceNodeParsesNaNTransferLimitAsZero() async {
    let result = await getTransferLimit(limitElement: .double(Double.nan))
    // result is Int?? — outer optional means "the action fired at all"; inner is the parsed limit.
    #expect(result != nil, "messagesRequested must fire (process must not crash)")
    if let outerResult = result {
        #expect(outerResult == 0, "float64(NaN) limit must parse as 0 (serve nothing), not nil or trap")
    }
}

/// `float64(-inf)` in data[2] must not trap. Reference computes `float('-inf')*1000 = -inf` and keeps
/// it as a float; `next_size > -inf` is true, so it skips every message and serves nothing
/// (`LXMRouter.py:1547`). We treat it as 0 (serve nothing) — genuine parity.
@MainActor @Test func serviceNodeParsesNegInfTransferLimitAsZero() async {
    let result = await getTransferLimit(limitElement: .double(-Double.infinity))
    #expect(result != nil, "messagesRequested must fire (process must not crash)")
    if let outerResult = result {
        #expect(outerResult == 0, "float64(-inf) limit must parse as 0 (serve nothing), not nil or trap")
    }
}

/// A large negative float64 in data[2] must not trap or silently become nil.
/// Reference: `float(-1e18)*1000 = -1e21`, kept as a float; `next_size > -1e21` is true, so every
/// message is skipped and nothing is served. We treat it as 0 (serve nothing) — genuine parity.
@MainActor @Test func serviceNodeParsesLargeNegativeFloatTransferLimitAsZero() async {
    let result = await getTransferLimit(limitElement: .double(-1e18))
    #expect(result != nil, "messagesRequested must fire (process must not crash)")
    if let outerResult = result {
        #expect(outerResult == 0, "large-negative float limit must parse as 0 (serve nothing), not nil or trap")
    }
}

/// A wire-decoded negative int64 in data[2] (e.g. `int8(-1)` = 0xFF) must not fall through to nil.
/// Before the decoder widening (`177da8c`) this failed the msgpack parse entirely; now it decodes as
/// `.int`. Reference: `float(-1)*1000 = -1000` — less than any message size → serves nothing.
/// We treat it as 0 (serve nothing) rather than nil (unlimited).
@MainActor @Test func serviceNodeParsesNegativeIntTransferLimitAsZero() async {
    let result = await getTransferLimit(limitElement: .int(-1))
    #expect(result != nil, "messagesRequested must fire (process must not crash)")
    if let outerResult = result {
        #expect(outerResult == 0, "int64(-1) limit must parse as 0 (serve nothing), not nil (unlimited)")
    }
}

/// `float64(+inf)` in data[2] clamps to `Int.max` (effectively unlimited) and must not trap.
///
/// This is genuine PARITY, reached by a different route. Reference never converts the cap to an int
/// (`LXMRouter.py:1528` keeps it a float); it tests `next_size > client_transfer_limit`, and
/// `next_size > inf` is false, so reference takes the else branch and serves everything. We saturate
/// the cap to `Int.max` and also serve everything. Verified by modelling `LXMRouter.py:1525-1547`
/// against the installed LXMF 1.1.0 source — an earlier draft of this test asserted the opposite on
/// the assumption that reference called `int(float('inf'))` and raised `OverflowError`. It does not.
@MainActor @Test func serviceNodeParsesPosInfTransferLimitAsUnlimited() async {
    let result = await getTransferLimit(limitElement: .double(Double.infinity))
    #expect(result != nil, "messagesRequested must fire (process must not crash)")
    if let outerResult = result {
        #expect(outerResult == Int.max,
                "float64(+inf) must clamp to Int.max — a known divergence from reference, which errors")
    }
}

/// `float64(-0.0)` must parse as a 0-byte cap, NOT be swept into the negative arm and NOT become nil.
///
/// It reaches the right answer by a route worth pinning: `-0.0 * 1000 == -0.0`, and IEEE 754 defines
/// `-0.0 == 0.0`, so `-0.0 < 0` is FALSE — the value falls past the negative guard to `Int(-0.0) == 0`.
/// Reference's `int(-0.0)` is likewise `0`, so unlike the `+inf` case this one is genuine parity.
@MainActor @Test func serviceNodeParsesNegativeZeroTransferLimitAsZero() async {
    let result = await getTransferLimit(limitElement: .double(-0.0))
    #expect(result != nil, "messagesRequested must fire")
    if let outerResult = result {
        #expect(outerResult == 0, "float64(-0.0) must parse as a 0-byte cap, not nil (unlimited)")
    }
}

/// A wire-decoded positive int64 in data[2] (e.g. `int8(256)`) must parse to the correct byte count.
/// This confirms the `.int` case is not a dead stub but actually works.
@MainActor @Test func serviceNodeParsesPositiveIntTransferLimit() async {
    let result = await getTransferLimit(limitElement: .int(200))
    #expect(result != nil, "messagesRequested must fire")
    if let outerResult = result {
        #expect(outerResult == 200_000, "int64(200) limit must parse to 200000 bytes")
    }
}

// MARK: - FIX 2: stamp rejection — ERROR_INVALID_STAMP on under-cost packet offer

/// A PACKET-framed offer whose stamp fails validation (absent or below minStampCost) must NOT be
/// proved. Instead the node sends ERROR_INVALID_STAMP (LXMPeer.ERROR_INVALID_STAMP = 0xF5,
/// LXMRouter.py:2258) as a plain data packet on the link, then tears it down. Without this fix the
/// node proved the packet, giving the sender a false delivery confirmation while storing nothing.
///
/// Uses minStampCost: 4 and an unstamped entry (effectively cost 0 — would be rejected by the store).
@MainActor @Test func serviceNodeRejectsPacketOfferWithInvalidStamp() async {
    let identity = Identity()
    var initial = LXMFServiceNode.State(
        identity: identity,
        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false),
        minStampCost: 4)   // enforce: any un-/under-stamped entry is invalid
    initial.nodeModeEnabled = true
    let store = makeServiceNodeStore(initial)

    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let linkID = Data(repeating: 0xC1, count: 16)
    let packetHash = Data(repeating: 0xF7, count: 32)
    // Unstamped entry: 16-byte dest prefix + payload — stamp cost is effectively 0 < minStampCost=4.
    let badEntry = Data(repeating: 0xAA, count: LXMessage.destinationLength) + Data("bad-stamp".utf8)
    let container = LXMFPropagation.container(timestamp: 1700000000.5, entries: [badEntry])

    await store.send(.registerPropagation)
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: propDest.hash)))))
    await store.send(.client(.endpoint(.delegate(.linkDataReceived(linkID: linkID, data: container,
                                                                   packetHash: packetHash)))))

    // Must send ERROR_INVALID_STAMP (0xF5) as a plain data packet on the link (sendOverLink),
    // NOT provePacketOverLink. The action bubbles through TransportEndpoint → TCPEndpoint, so
    // it appears as .client(.endpoint(.tcp(.sendOverLink(...)))).
    // Order: the error is emitted before the close (both in the same merge).
    await store.receive { action in
        if case let .client(.endpoint(.tcp(.sendOverLink(lid, data)))) = action {
            #expect(lid == linkID)
            #expect(MsgPack.decodeValue(data) == .array([.uint(LXMFPropagation.errorInvalidStamp)]),
                    "must send msgpack([0xF5]) per LXMPeer.ERROR_INVALID_STAMP / LXMRouter.py:2258")
            return true
        }
        return false
    }
    await store.receive { action in
        if case let .client(.endpoint(.tcp(.closeLink(lid)))) = action {
            #expect(lid == linkID)
            return true
        }
        return false
    }
    // Nothing must have been stored.
    #expect(store.state.pn.store.count == 0, "invalid-stamp offer must not be stored")

    // Prove must NOT have been sent (flip to .on so any stray prove fails teardown).
    store.exhaustivity = .on
}

/// A PACKET-framed offer whose container is unparseable (malformed msgpack) must neither prove nor
/// ingest — reference LXMRouter.py:2262 `except` block skips the prove on parse error.
@MainActor @Test func serviceNodeDoesNotProveOrIngestOnUnparseableContainer() async {
    let identity = Identity()
    var initial = LXMFServiceNode.State(
        identity: identity,
        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false),
        minStampCost: 0)
    initial.nodeModeEnabled = true
    let store = makeServiceNodeStore(initial)

    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let linkID = Data(repeating: 0xC1, count: 16)
    let packetHash = Data(repeating: 0xF7, count: 32)
    let garbage = Data([0xFF, 0xFE, 0xFD])   // not a valid msgpack propagation container

    await store.send(.registerPropagation)
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: propDest.hash)))))
    // Drain setup effects (linkEstablished → router.linkEstablished) before flipping to .on.
    await store.skipReceivedActions(strict: false)

    // An unparseable container must produce NO actions (no prove, no error packet, no ingest).
    // Flip to .on so any stray action causes teardown to fail.
    store.exhaustivity = .on
    await store.send(.client(.endpoint(.delegate(.linkDataReceived(linkID: linkID, data: garbage,
                                                                   packetHash: packetHash)))))
    #expect(store.state.pn.store.count == 0)
}

/// A DUPLICATE (already-stored) valid offer must STILL be proved. The duplicate contributes 0 to
/// `rejected` (it is not a stamp failure), so the prove path is taken. Without this, a re-offered
/// duplicate would be silently dropped while the client waited for a receipt that never comes.
@MainActor @Test func serviceNodeProvesDuplicatePacketOffer() async {
    let identity = Identity()
    let store = makeServiceNode(identity, nodeMode: true)   // minStampCost: 0 → accept any entry
    let e = Data(repeating: 0xAA, count: LXMessage.destinationLength) + Data("dup-offer".utf8)
    let container = LXMFPropagation.container(timestamp: 1700000000.5, entries: [e])
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: identity)!
    let linkID = Data(repeating: 0xC1, count: 16)
    let packetHash1 = Data(repeating: 0xF7, count: 32)
    let packetHash2 = Data(repeating: 0xF8, count: 32)

    await store.send(.registerPropagation)
    await store.send(.client(.endpoint(.delegate(.linkEstablished(linkID: linkID, destinationHash: propDest.hash)))))

    // First offer: ingested and proved.
    await store.send(.client(.endpoint(.delegate(.linkDataReceived(linkID: linkID, data: container,
                                                                   packetHash: packetHash1)))))
    await store.receive { if case .client(.endpoint(.provePacketOverLink)) = $0 { return true }; return false }

    // Second offer (duplicate): NOT newly stored, but MUST still be proved.
    await store.send(.client(.endpoint(.delegate(.linkDataReceived(linkID: linkID, data: container,
                                                                   packetHash: packetHash2)))))
    await store.receive { action in
        if case let .client(.endpoint(.provePacketOverLink(lid, h))) = action {
            #expect(lid == linkID)
            #expect(h == packetHash2, "duplicate offer must be proved with the new packet's hash")
            return true
        }
        return false
    }
    #expect(store.state.pn.store.count == 1, "store must still contain exactly one entry")
}

// MARK: - FIX 4: awaitingList handles ERROR_NO_IDENTITY from reference PN

/// When the phase-1 /get response is `LXMPeer.ERROR_NO_IDENTITY` (0xF0) — sent by a reference PN
/// that never received an IDENTIFY — `LXMFNode` must clear `syncPhase[linkID]` and close the link
/// (reference LXMRouter.py:1563-1567: set PR_NO_IDENTITY_RCVD + teardown). Without the fix,
/// `syncPhase[linkID]` stays `.awaitingList` forever (stuck sync, link never closed).
@MainActor @Test func lxmfNodeHandlesNoIdentityErrorOnAwaitingList() async {
    let identity = Identity()
    var initial = LXMFNode.State(
        identity: identity,
        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    let linkID = Data(repeating: 0xC1, count: 16)
    initial.syncPhase[linkID] = .awaitingList   // simulate: we sent a phase-1 /get, waiting for list
    initial.linkDestinations[linkID] = Data(repeating: 0xAB, count: 16)

    let store = TestStore(initialState: initial) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off

    // The reference PN responds with ERROR_NO_IDENTITY (uint 0xF0) — not an array.
    let errorData = MsgPack.encode(.uint(LXMFPropagation.errorNoIdentity))
    await store.send(.endpoint(.delegate(.responseReceived(linkID: linkID, requestID: Data([1]),
                                                           data: errorData))))

    // The link must be closed. Receive this BEFORE skipReceivedActions — in a .off store receive
    // skips non-matching actions, so asserting state first and then receiving would drain the close.
    // closeLink is routed through TransportEndpoint → TCPEndpoint, so appears as .endpoint(.tcp(.closeLink(...))).
    await store.receive { action in
        if case let .endpoint(.tcp(.closeLink(lid))) = action {
            #expect(lid == linkID)
            return true
        }
        return false
    }

    // syncPhase must be cleared (no longer stuck at awaitingList).
    // drain any remaining actions before checking state.
    await store.skipReceivedActions(strict: false)
    #expect(store.state.syncPhase[linkID] == nil, "syncPhase must be cleared on ERROR_NO_IDENTITY")
}

// MARK: - FIX 5: packet-path prove crosses the real link stack

/// The existing `serviceNodeIngestsAndServesOverRealLink` exercises the Resource path. This test
/// verifies that the PACKET path (used by ordinary chat-sized offers — `LXMessage.py:426-444`) also
/// crosses `TransportEndpoint → TCPEndpoint → LinkPlane → LinkSession` correctly: the node receives
/// the packet, ingest it, and sends a DATA_PROOF back over the real link.
///
/// Without this test a plumbing regression between those layers would go uncaught — the unit-level
/// `serviceNodeProvesPacketOfferOnPropagationLink` only exercises the TCA action path, not the wire.
@Test @MainActor func serviceNodeProvesPacketOfferOverRealLink() async {
    let clock = TestClock()
    let nodeIdentity = Identity()
    let cIdentity = Identity()
    let cDeliveryHash = LXMessage.deliveryHash(identityHash: cIdentity.hash)
    // Unstamped container (minStampCost:0 on node), small enough to go as a packet.
    let e = cDeliveryHash + Data("hello-packet".utf8)
    let container = LXMFPropagation.container(timestamp: 1700000000.5, entries: [e])

    func makeNode(_ host: String, _ sent: LockIsolated<[Data]>)
        -> (TestStore<LXMFServiceNode.State, LXMFServiceNode.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        var initial = LXMFServiceNode.State(
            identity: nodeIdentity,
            endpoint: TCPEndpoint.State(host: host, port: 4242, reconnectOnDrop: false),
            minStampCost: 0)   // accept unstamped entries
        initial.nodeModeEnabled = true
        let store = TestStore(initialState: initial) { LXMFServiceNode() } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } }, close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    func makeClient(_ host: String, _ sent: LockIsolated<[Data]>)
        -> (TestStore<TCPEndpoint.State, TCPEndpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: TCPEndpoint.State(host: host, port: 4242, reconnectOnDrop: false)) {
            TCPEndpoint()
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } }, close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    func nodeSend(_ act: LXMFServiceNode.Action) -> Bool {
        if case .client(.endpoint(.tcp(.interface(.send)))) = act { return true }; return false
    }
    func cSend(_ act: TCPEndpoint.Action) -> Bool { if case .interface(.send) = act { return true }; return false }

    let sentNode = LockIsolated<[Data]>([])
    let sentC    = LockIsolated<[Data]>([])
    let (node, eventsNode) = makeNode("node", sentNode)
    let (c, eventsC) = makeClient("c", sentC)

    await node.send(.client(.endpoint(.tcp(.connect)))); eventsNode.yield(.connected)
    await c.send(.connect); eventsC.yield(.connected)

    // Node registers + announces lxmf.propagation; bridge the announce so C learns the path.
    await node.send(.registerPropagation)
    await node.receive { if case .client(.endpoint(.registerLocalDestination)) = $0 { return true }; return false }
    await node.receive(nodeSend)   // announce frame out
    eventsC.yield(.data(sentNode.value.last!))
    await c.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }

    // C opens a link to the node's propagation destination.
    let propDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                               aspects: ["propagation"], identity: nodeIdentity)!
    await c.send(.openLink(destinationHash: propDest.hash))
    await c.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await c.receive(cSend)         // LINKREQUEST out

    // Handshake: LINKREQUEST → node; LRPROOF → C; LRRTT → node.
    eventsNode.yield(.data(sentC.value.last!))
    await node.receive(nodeSend)   // LRPROOF out
    eventsC.yield(.data(sentNode.value.last!))
    await c.receive(cSend)         // LRRTT out
    eventsNode.yield(.data(sentC.value.last!))
    await c.receive { if case .delegate(.linkEstablished) = $0 { return true }; return false }
    await node.receive { if case .client(.endpoint(.delegate(.linkEstablished))) = $0 { return true }; return false }

    let linkID = c.state.links[0].linkID

    // C sends the container as a PACKET (sendWithReceiptOverLink — the packet path).
    let token = Data(repeating: 0xBB, count: 32)   // stands in for messageHash
    await c.send(.sendWithReceiptOverLink(linkID: linkID, data: container, token: token))
    await c.receive(cSend)         // DATA packet out

    // Bridge the packet to the node → node ingests + emits provePacketOverLink → DATA_PROOF out.
    eventsNode.yield(.data(sentC.value.last!))
    await node.receive { if case .client(.endpoint(.delegate(.linkDataReceived))) = $0 { return true }; return false }
    await node.receive(nodeSend)   // DATA_PROOF frame out

    // Bridge the DATA_PROOF back to C → C surfaces .delegate(.packetDelivered(token:)).
    eventsC.yield(.data(sentNode.value.last!))
    await c.receive { action in
        if case let .delegate(.packetDelivered(t)) = action {
            #expect(t == token, "proof must be for the correct token")
            return true
        }
        return false
    }

    await node.send(.client(.endpoint(.tcp(.disconnect)))); await c.send(.disconnect)
}
