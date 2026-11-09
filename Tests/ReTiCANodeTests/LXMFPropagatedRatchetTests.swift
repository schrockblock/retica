import Testing
import Foundation
import CryptoKit
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// A propagated copy is encrypted to the recipient's ratchet when one is known and fresh, as reference
// packs it through `destination.encrypt` (LXMessage.py:437), which takes the recipient's ratchet
// (Destination.py:694-708). Both places a copy is packed: `.sendViaPropagation` and the fallback copy
// of a `.sendMessage(fallbackToPropagation: true)`.

private let dest = Data(repeating: 0xD6, count: 16)
private let pn = Data(repeating: 0xBC, count: 16)
private let now = Date(timeIntervalSince1970: 1700000000.5)
private let cheapCost: Double = 2

private struct Recipient {
    let identity = Identity()
    let ratchetPrivate: Data
    let ratchetPublic: Data
    init() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        ratchetPrivate = key.rawRepresentation
        ratchetPublic = key.publicKey.rawRepresentation
    }
}

@MainActor
private func node(_ recipient: Recipient, ratchetReceived: Date?,
                  clock: TestClock<Duration> = TestClock()) -> TestStore<LXMFNode.State, LXMFNode.Action> {
    var state = LXMFNode.State(identity: Identity(),
                               endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    state.endpoint.transport.learned[dest] = LearnedDestination(
        identity: recipient.identity, appData: nil, interfaceID: InterfaceID("tcp"),
        hops: 1, nextHop: nil, announceEmitted: 0)
    state.endpoint.transport.knownDestinations[dest] = KnownDestination(
        identity: Identity(publicKey: recipient.identity.publicKey)!, appData: nil, lastHeard: now,
        ratchet: ratchetReceived == nil ? nil : recipient.ratchetPublic, ratchetReceived: ratchetReceived)
    state.endpoint.transport.learned[pn] = LearnedDestination(
        identity: Identity(),
        appData: PNAnnounce(timebase: 0, nodeState: true, perTransferLimit: 0, perSyncLimit: 0,
                            targetStampCost: cheapCost, stampCostFlexibility: 0, peeringCost: 0).packed,
        interfaceID: InterfaceID("tcp"), hops: 1, nextHop: nil, announceEmitted: 0)
    state.router.outboundPropagationNode = pn
    state.router.knownPaths.insert(dest)
    let store = TestStore(initialState: state) { LXMFNode() } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(now)
        $0.transportDate = .constant(now)
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

/// The single entry of the container the node hands the router for `hash` (any message when nil).
@MainActor
private func propagatedEntry(_ store: TestStore<LXMFNode.State, LXMFNode.Action>, of hash: Data? = nil)
    async throws -> Data {
    let packed = LockIsolated<Data?>(nil)
    await store.receive({ action in
        guard case let .router(.sendViaPropagation(sent, bytes)) = action, hash == nil || sent.hash == hash
        else { return false }
        packed.setValue(bytes)
        return true
    }, timeout: .seconds(30))
    let bytes = try #require(packed.value)
    return try #require(LXMFPropagation.parseContainer(bytes)?.entries.first)
}

/// The entry's message, decrypted with the ratchet's private key (the recipient's own decrypt order:
/// ratchets first), or nil.
private func openWithRatchet(_ entry: Data, _ recipient: Recipient) -> LXMessage? {
    let core = LXMFPropagation.strippedCore(lxmfData: entry)
    let tail = Data(core.dropFirst(LXMessage.destinationLength))
    guard let plain = recipient.identity.decrypt(tail, ratchets: [recipient.ratchetPrivate]) else { return nil }
    return LXMessage.unpack(Data(core.prefix(LXMessage.destinationLength)) + plain)
}

@Suite @MainActor struct LXMFPropagatedRatchetTests {
    @Test func sendViaPropagationEncryptsToTheRecipientsRatchet() async throws {
        let recipient = Recipient()
        let store = node(recipient, ratchetReceived: now.addingTimeInterval(-60))
        await store.send(.sendViaPropagation(destinationHash: dest, title: Data("t".utf8), content: Data("c".utf8)))
        let entry = try await propagatedEntry(store)
        #expect(LXMFPropagation.open(lxmfData: entry, recipientIdentity: recipient.identity) == nil,
                "the identity key alone must not open it")
        #expect(openWithRatchet(entry, recipient)?.content == Data("c".utf8))
    }

    @Test func sendViaPropagationUsesTheIdentityKeyOnceTheRatchetExpired() async throws {
        let recipient = Recipient()
        let store = node(recipient, ratchetReceived: now.addingTimeInterval(-Transport.ratchetExpiry - 1))
        await store.send(.sendViaPropagation(destinationHash: dest, title: Data("t".utf8), content: Data("c".utf8)))
        let entry = try await propagatedEntry(store)
        #expect(LXMFPropagation.open(lxmfData: entry, recipientIdentity: recipient.identity)?.content
                == Data("c".utf8))
    }

    @Test func aFallbackCopyEncryptsToTheRecipientsRatchet() async throws {
        let clock = TestClock()
        let recipient = Recipient()
        let store = node(recipient, ratchetReceived: now.addingTimeInterval(-60), clock: clock)
        let m = LXMessage.create(source: Identity(), destinationHash: dest, timestamp: 1700000000.5,
                                 title: Data("t".utf8), content: Data("fallback".utf8))
        await store.send(.sendMessage(message: m, fallbackToPropagation: true))
        for _ in 0..<(LXMFDelivery.propagationFallbackAfterAttempts - 1) {
            await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
        }
        await store.receive(.router(.delegate(.propagationFallbackDue(messageHash: m.hash))))
        let entry = try await propagatedEntry(store, of: m.hash)
        #expect(LXMFPropagation.open(lxmfData: entry, recipientIdentity: recipient.identity) == nil,
                "the identity key alone must not open it")
        #expect(openWithRatchet(entry, recipient)?.hash == m.hash)
    }
}
