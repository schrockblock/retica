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

    // Data on the served propagation link must NOT reach the router: send while .off, then flip to .on.
    // A stray .router(.received) from the propagation link would survive as an unhandled effect and
    // fail teardown (or the next send in .on mode).
    await store.send(.endpoint(.delegate(.linkDataReceived(linkID: servedLink, data: Data("container".utf8)))))
    store.exhaustivity = .on   // a stray .router(.received) from the propagation link would fail teardown

    // Data on any other link keeps the existing direct-message path.
    // This also proves the guard is not simply disabling everything.
    await store.send(.endpoint(.delegate(.linkDataReceived(linkID: otherLink, data: Data("msg".utf8)))))
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
    await store.send(.client(.endpoint(.delegate(.linkDataReceived(linkID: linkID, data: container)))))
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

    // Disarm: the served destination and every serve-side table are cleared.
    await store.send(.setNodeMode(false))
    #expect(store.state.nodeModeEnabled == false)
    #expect(store.state.client.propagationDestinationHash == nil)
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
    await store.send(.client(.endpoint(.delegate(.linkDataReceived(linkID: otherLink, data: container)))))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.pn.store.count == 0)
    #expect(store.state.pn.store.contains(transientId: LXMFPropagation.transientId(lxmfData: e)) == false)
}

/// IDENTIFY gate: a /get request arriving BEFORE the client sends IDENTIFY must be silently dropped.
///
/// Mutation-sensitivity: if the `clientIdentity` guard in the `requestReceived` case is deleted,
/// the request produces a stray `.sendResponseOverLink` which stays in `receivedActions` after the
/// only `store.send` call. Flipping exhaustivity to .on before teardown causes the store to report
/// the unexpected action → test fails. Without the mutation the guard returns .none so nothing is
/// queued → teardown is clean.
@MainActor @Test func serviceNodeDropsRequestWithoutIdentify() async {
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

    // No IDENTIFY → must be dropped. No more store.send calls after this so any stray
    // sendResponseOverLink stays in receivedActions until teardown.
    await store.send(.client(.endpoint(.delegate(.requestReceived(
        linkID: linkID, requestID: Data([9]),
        pathHash: Crypto.truncatedHash(Data("/get".utf8)),
        data: MsgPack.encode(.array([.null, .null])))))))

    // Flip to .on: if the IDENTIFY guard was deleted the stray sendResponseOverLink is still in the
    // queue and teardown reports "store received N unexpected actions" → FAIL.
    store.exhaustivity = .on
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
