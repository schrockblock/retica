import Testing
import Foundation
import CryptoKit
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// LXMFNode and our own ratchets: a propagated message downloaded for our delivery destination is
// decrypted with its ring first and dropped under enforcement when only the identity key opens it, as
// reference decrypts it through `delivery_destination.decrypt` (Destination.py:720-752); and the
// delivery announce's name is cut to the smaller budget once the destination announces a ratchet.

private let now = Date(timeIntervalSince1970: 1700000000.5)

/// LXMFNode, recording the propagated messages it hands its router and the app data it announces.
private struct ObservedNode: Reducer {
    typealias State = LXMFNode.State
    typealias Action = LXMFNode.Action
    let propagated: LockIsolated<[Data]>
    let announced: LockIsolated<[Data?]>

    var body: some Reducer<State, Action> {
        Reduce<State, Action> { _, action in
            switch action {
            case let .router(.received(method: .propagated, destinationHash: _, data: data)):
                propagated.withValue { $0.append(data) }
            case let .endpoint(.announce(destinationHash: _, appData: appData)):
                announced.withValue { $0.append(appData) }
            default: break
            }
            return .none
        }
        LXMFNode()
    }
}

@MainActor
private func node(_ state: LXMFNode.State, propagated: LockIsolated<[Data]> = LockIsolated([]),
                  announced: LockIsolated<[Data?]> = LockIsolated([])) -> TestStore<LXMFNode.State, LXMFNode.Action> {
    let store = TestStore(initialState: state) {
        ObservedNode(propagated: propagated, announced: announced)
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(now)
        $0.transportDate = .constant(now)
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

private func newRatchetPrivate() -> Data { Curve25519.KeyAgreement.PrivateKey().rawRepresentation }

/// A propagation-node download entry for a message to `me`, its tail encrypted to `ratchetPublic` (or
/// the identity key when nil), and the message.
private func downloadEntry(to me: Identity, ratchetPublic: Data?, content: String) -> (Data, LXMessage) {
    let msg = LXMessage.create(source: Identity(), destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data(content.utf8))
    let tail = Data(msg.packed.dropFirst(LXMessage.destinationLength))
    let entry = LXMFPropagation.lxmfData(destinationHash: msg.destinationHash,
                                         encryptedData: me.encrypt(tail, ratchet: ratchetPublic))
    return (entry, msg)
}

@MainActor
private func download(_ store: TestStore<LXMFNode.State, LXMFNode.Action>, _ entries: [Data]) async {
    let linkID = Data(repeating: 0xA7, count: 16)
    await store.send(.endpoint(.delegate(.responseReceived(linkID: linkID, requestID: Data(repeating: 1, count: 16),
                                                           data: MsgPack.encode(.array(entries.map { .bin($0) }))))))
    await store.skipReceivedActions(strict: false)
}

@Suite @MainActor struct OwnRatchetNodeTests {
    @Test func aDownloadedMessageToOurRatchetIsDecryptedWithTheRing() async {
        let me = Identity()
        let ring = [newRatchetPrivate(), newRatchetPrivate()]
        let (toOld, oldMsg) = downloadEntry(to: me, ratchetPublic: Identity.ratchetPublicKey(privateKey: ring[1]),
                                            content: "to an older ratchet")
        let (toIdentity, identityMsg) = downloadEntry(to: me, ratchetPublic: nil, content: "to the identity")
        var state = LXMFNode.State(identity: me, endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
        let delivery = LXMessage.deliveryHash(identityHash: me.hash)
        state.deliveryDestinationHash = delivery
        state.endpoint.transport.ownRatchets[delivery] = .init(ring: ring)
        state.syncPhase[Data(repeating: 0xA7, count: 16)] = .awaitingMessages
        let propagated = LockIsolated<[Data]>([])
        let store = node(state, propagated: propagated)
        await download(store, [toOld, toIdentity])
        #expect(propagated.value == [oldMsg.packed, identityMsg.packed])
    }

    @Test func underEnforcementADownloadedMessageToTheIdentityKeyIsDropped() async {
        let me = Identity()
        let ring = [newRatchetPrivate()]
        let (toRatchet, ratchetMsg) = downloadEntry(to: me, ratchetPublic: Identity.ratchetPublicKey(privateKey: ring[0]),
                                                    content: "to the ratchet")
        let (toIdentity, _) = downloadEntry(to: me, ratchetPublic: nil, content: "to the identity")
        var state = LXMFNode.State(identity: me, endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
        let delivery = LXMessage.deliveryHash(identityHash: me.hash)
        state.deliveryDestinationHash = delivery
        state.endpoint.transport.ownRatchets[delivery] = .init(ring: ring, enforce: true)
        state.syncPhase[Data(repeating: 0xA7, count: 16)] = .awaitingMessages
        let propagated = LockIsolated<[Data]>([])
        let store = node(state, propagated: propagated)
        await download(store, [toIdentity, toRatchet])
        #expect(propagated.value == [ratchetMsg.packed])
    }

    /// A download with a full ring: the entry to our newest ratchet costs one key agreement, and an entry
    /// addressed to another destination costs none (reference decrypts only entries for its delivery
    /// destinations, LXMRouter.py:2855). Both transient ids are still acknowledged.
    @Test func aDownloadCostsOneAgreementForOurEntryAndNoneForAForeignOne() async throws {
        let me = Identity()
        let ring = (0..<512).map { _ in newRatchetPrivate() }
        let (ours, ourMsg) = downloadEntry(to: me, ratchetPublic: Identity.ratchetPublicKey(privateKey: ring[0]),
                                           content: "ours")
        let (foreign, _) = downloadEntry(to: Identity(), ratchetPublic: nil, content: "someone else's")
        var state = LXMFNode.State(identity: me, endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
        let delivery = LXMessage.deliveryHash(identityHash: me.hash)
        state.deliveryDestinationHash = delivery
        state.endpoint.transport.ownRatchets[delivery] = .init(ring: ring)
        let linkID = Data(repeating: 0xA7, count: 16)
        state.syncPhase[linkID] = .awaitingMessages
        let propagated = LockIsolated<[Data]>([])
        let store = node(state, propagated: propagated)
        let counter = Identity.LockedCounter()
        await Identity.$decryptAgreementProbe.withValue(counter) {
            await store.send(.endpoint(.delegate(.responseReceived(
                linkID: linkID, requestID: Data(repeating: 1, count: 16),
                data: MsgPack.encode(.array([.bin(foreign), .bin(ours)]))))))
        }
        await store.receive(.router(.messagesDownloaded(transientIds: [
            LXMFPropagation.transientId(lxmfData: foreign), LXMFPropagation.transientId(lxmfData: ours)])))
        await store.skipReceivedActions(strict: false)
        #expect(propagated.value == [ourMsg.packed])
        #expect(counter.value == 1)
    }

    /// The host-facing forms on TransportEndpoint reach Transport, and a rotation comes back as an
    /// endpoint delegate (the paths an LXMFServiceNode host such as ReTiCAMsgr wraps in `.client`).
    @Test func theEndpointMirrorsEnableEnforceAndTheRotationReport() async throws {
        let me = Identity()
        let state = LXMFNode.State(identity: me, endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
        let delivery = LXMessage.deliveryHash(identityHash: me.hash)
        let store = node(state)
        let restored = [newRatchetPrivate()]
        await store.send(.endpoint(.enableRatchets(destinationHash: delivery, ring: restored)))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.endpoint.transport.ownRatchets[delivery]?.ring == restored)
        await store.send(.endpoint(.setEnforceRatchets(destinationHash: delivery, true)))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.endpoint.transport.ownRatchets[delivery]?.enforce == true)

        // `.registerDelivery` announces, which rotates.
        await store.send(.registerDelivery)
        let reported = LockIsolated<[Data]?>(nil)
        await store.receive({ action in
            guard case let .endpoint(.delegate(.ratchetsChanged(hash, ring))) = action, hash == delivery else { return false }
            reported.setValue(ring)
            return true
        }, timeout: .seconds(5))
        let ring = try #require(reported.value)
        #expect(ring.count == 2 && ring.last == restored[0])
        #expect(store.state.endpoint.transport.ownRatchets[delivery]?.ring == ring)
    }

    @Test func theDeliveryAnnounceUsesTheRatchetBudgetOnceRatchetsAreEnabled() async {
        let me = Identity()
        var state = LXMFNode.State(identity: me, endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
        state.displayName = String(repeating: "N", count: 400)
        let delivery = LXMessage.deliveryHash(identityHash: me.hash)
        state.deliveryDestinationHash = delivery
        let announced = LockIsolated<[Data?]>([])
        let store = node(state, announced: announced)
        await store.send(.announceDelivery)
        await store.send(.endpoint(.transport(.enableRatchets(destinationHash: delivery, ring: []))))
        await store.send(.announceDelivery)
        await store.skipReceivedActions(strict: false)
        // 315 and 283: the budgets with and without the 32-byte ratchet (see LXMFAnnounceData).
        #expect(announced.value.map { $0?.count } == [315, 315 - 32])
    }
}
