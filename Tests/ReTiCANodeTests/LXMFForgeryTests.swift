import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Forgery checks in `LXMFRouter` `.received` (spec 2026-10-28): a `.direct` or `.propagated` message
// must be addressed to our delivery destination, and a message from a KNOWN sender must carry a
// valid signature. Both drops happen before `seen`, so a forged copy cannot block the genuine one.

private let alice = Identity()      // us
private let bob = Identity()        // the sender
private let carol = Identity()      // someone else
private let aliceDelivery = LXMessage.deliveryHash(identityHash: alice.hash)
private let carolDelivery = LXMessage.deliveryHash(identityHash: carol.hash)

/// A message signed by Bob to `destinationHash`.
private func bobMessage(to destinationHash: Data, content: String = "hello") -> LXMessage {
    LXMessage.create(source: bob, destinationHash: destinationHash,
                     timestamp: 1700000000.5, title: Data("t".utf8), content: Data(content.utf8))
}

/// `message.packed` with its signature replaced by 64 random bytes: it still claims Bob as sender
/// and keeps the same message hash (the hash excludes the signature).
private func forgedSignature(_ message: LXMessage) -> Data {
    var bytes = message.packed
    let start = 2 * LXMessage.destinationLength
    let random = Data((0..<LXMessage.signatureLength).map { _ in UInt8.random(in: 0...255) })
    bytes.replaceSubrange(start..<(start + LXMessage.signatureLength), with: random)
    return bytes
}

@MainActor
private func makeRouter(knowingBob: Bool) async -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    if knowingBob {
        let bobDelivery = LXMessage.deliveryHash(identityHash: bob.hash)
        await store.send(.learnedIdentity(destinationHash: bobDelivery, identity: bob))
    }
    return store
}

@MainActor
private func expectRejected(_ store: TestStore<LXMFRouter.State, LXMFRouter.Action>, _ msg: LXMessage,
                            _ reason: LXMFRouter.RejectReason) async {
    await store.receive(.delegate(.messageRejected(hash: msg.hash, reason: reason)))
    store.exhaustivity = .on   // a stray `.messageDelivered` fails teardown
}

@MainActor
private func expectDelivered(_ store: TestStore<LXMFRouter.State, LXMFRouter.Action>, _ msg: LXMessage,
                             validated expected: Bool) async {
    await store.receive { action in
        guard case let .delegate(.messageDelivered(m, validated, _)) = action else { return false }
        #expect(m.hash == msg.hash)
        #expect(validated == expected)
        return true
    }
}

// MARK: - Router: addressed to us

@Test @MainActor func directMessageForAnotherRecipientIsDropped() async {
    let msg = bobMessage(to: carolDelivery)
    let store = await makeRouter(knowingBob: true)
    await store.send(.received(method: .direct, destinationHash: aliceDelivery, data: msg.packed))
    await expectRejected(store, msg, .notAddressedToUs)
}

@Test @MainActor func propagatedMessageForAnotherRecipientIsDropped() async {
    let msg = bobMessage(to: carolDelivery)
    let store = await makeRouter(knowingBob: true)
    await store.send(.received(method: .propagated, destinationHash: aliceDelivery, data: msg.packed))
    await expectRejected(store, msg, .notAddressedToUs)
}

@Test @MainActor func directMessageToUsIsDelivered() async {
    let msg = bobMessage(to: aliceDelivery)
    let store = await makeRouter(knowingBob: true)
    await store.send(.received(method: .direct, destinationHash: aliceDelivery, data: msg.packed))
    await expectDelivered(store, msg, validated: true)
}

/// No delivery destination registered: nothing on a link or from a propagation node is ours.
@Test @MainActor func receivedWithoutRegistrationDropsDirect() async {
    let msg = bobMessage(to: aliceDelivery)
    let store = await makeRouter(knowingBob: true)
    await store.send(.received(method: .direct, destinationHash: Data(), data: msg.packed))
    await expectRejected(store, msg, .notAddressedToUs)
}

// MARK: - Router: known-sender signature

@Test @MainActor func knownSenderBadSignatureIsDropped() async {
    let msg = bobMessage(to: aliceDelivery)
    let store = await makeRouter(knowingBob: true)
    await store.send(.received(method: .direct, destinationHash: aliceDelivery, data: forgedSignature(msg)))
    await expectRejected(store, msg, .badSignature)
}

/// A forged copy arriving first must not block the genuine message through `seen`.
@Test @MainActor func knownSenderBadSignatureIsNotMarkedSeen() async {
    let msg = bobMessage(to: aliceDelivery)
    let store = await makeRouter(knowingBob: true)
    await store.send(.received(method: .direct, destinationHash: aliceDelivery, data: forgedSignature(msg)))
    await store.receive(.delegate(.messageRejected(hash: msg.hash, reason: .badSignature)))
    await store.send(.received(method: .direct, destinationHash: aliceDelivery, data: msg.packed))
    await expectDelivered(store, msg, validated: true)
    store.exhaustivity = .on   // a stray `.duplicateDropped` fails teardown
}

/// Without the sender's identity nothing can be checked: delivered unvalidated, and still marked seen.
@Test @MainActor func unknownSenderIsDeliveredUnvalidated() async {
    let msg = bobMessage(to: aliceDelivery)
    let store = await makeRouter(knowingBob: false)
    await store.send(.received(method: .direct, destinationHash: aliceDelivery, data: msg.packed))
    await expectDelivered(store, msg, validated: false)
    await store.send(.received(method: .direct, destinationHash: aliceDelivery, data: msg.packed))
    await store.receive(.delegate(.duplicateDropped(hash: msg.hash)))
}

// MARK: - LXMFNode call sites

@MainActor
private func makeNode(_ state: LXMFNode.State) -> TestStore<LXMFNode.State, LXMFNode.Action> {
    let store = TestStore(initialState: state) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

private func aliceNodeState() -> LXMFNode.State {
    LXMFNode.State(identity: alice, endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
}

/// A propagation entry for `msg`, encrypted to Alice whatever its destination hash says.
private func propagationEntry(_ msg: LXMessage) -> Data {
    LXMFPropagation.lxmfData(destinationHash: msg.destinationHash,
                             encryptedData: alice.encrypt(Data(msg.packed.dropFirst(LXMessage.destinationLength))))
}

private func getResponse(_ entries: [Data]) -> Data {
    MsgPack.encode(.array(entries.map { .bin($0) }))
}

/// Spec settled detail 5: a dropped propagated message is still marked downloaded, so the node
/// does not offer it again.
@Test @MainActor func rejectedPropagatedStillMarkedDownloaded() async {
    let msg = bobMessage(to: carolDelivery)
    let entry = propagationEntry(msg)
    let tid = LXMFPropagation.transientId(lxmfData: entry)
    let linkID = Data(repeating: 0xA7, count: 16)
    var state = aliceNodeState()
    state.deliveryDestinationHash = aliceDelivery
    state.syncPhase[linkID] = .awaitingMessages
    let store = makeNode(state)
    await store.send(.endpoint(.delegate(.responseReceived(linkID: linkID, requestID: Data(repeating: 1, count: 16),
                                                           data: getResponse([entry])))))
    await store.receive(.router(.messagesDownloaded(transientIds: [tid])))
    await store.receive(.router(.delegate(.messageRejected(hash: msg.hash, reason: .notAddressedToUs))))
    #expect(store.state.router.downloadedTransientIds.contains(tid))
}

@Test @MainActor func nodePassesDeliveryHashForPropagatedAndDirect() async {
    let propagated = bobMessage(to: aliceDelivery, content: "via propagation")
    let direct = bobMessage(to: aliceDelivery, content: "via link")
    let syncLink = Data(repeating: 0xA7, count: 16)
    let otherLink = Data(repeating: 0xB2, count: 16)
    var state = aliceNodeState()
    state.syncPhase[syncLink] = .awaitingMessages
    state.linkDestinations[otherLink] = Data(repeating: 0xCC, count: 16)   // not our delivery destination
    let store = makeNode(state)
    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.deliveryDestinationHash == aliceDelivery)

    await store.send(.endpoint(.delegate(.responseReceived(linkID: syncLink, requestID: Data(repeating: 1, count: 16),
                                                           data: getResponse([propagationEntry(propagated)])))))
    await store.receive { action in
        guard case let .delegate(.messageReceived(m, _, method)) = action else { return false }
        return m.hash == propagated.hash && method == .propagated
    }

    await store.send(.endpoint(.delegate(.linkDataReceived(linkID: otherLink, data: direct.packed,
                                                           packetHash: Data(repeating: 0xF3, count: 32)))))
    await store.receive { action in
        guard case let .delegate(.messageReceived(m, _, method)) = action else { return false }
        return m.hash == direct.hash && method == .direct
    }
}
