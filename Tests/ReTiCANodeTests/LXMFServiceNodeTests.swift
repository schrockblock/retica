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
