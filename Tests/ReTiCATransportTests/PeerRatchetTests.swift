import Testing
import Foundation
import CryptoKit
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// A peer's ratchet lives on its KNOWN destination (reference `Identity.known_ratchets`), not on the
// path: every valid announce carrying one refreshes it whether or not the announce wins the path, an
// announce without one leaves it, and it expires 30 days after it was first heard
// (RNS 1.6.0 Identity.py:535-675, 726; Destination.py:694-708).

private let i0 = InterfaceID("i0")
private let start = Date(timeIntervalSince1970: 1_700_000_000)

/// A peer: one identity announcing one destination.
private struct Peer {
    let identity: Identity
    init(identity: Identity = Identity()) { self.identity = identity }
    var destinationHash: Data {
        Destination.hash(identityHash: identity.hash, appName: "ratchet", aspects: ["peer"])
    }

    /// A HEADER_1 announce emitted at `emitted` (whole seconds) with the random prefix `prefix`
    /// (a different prefix is a different random blob, so a fresh announce), carrying `ratchet`
    /// (context flag set) or none.
    func announce(emitted: UInt64, prefix: UInt8, hops: UInt8 = 1, ratchet: Data?) -> Data {
        let nameHash = Destination.nameHash(appName: "ratchet", aspects: ["peer"])
        let randomHash = Announce.randomHash(now: emitted, randomPrefix: Data(repeating: prefix, count: 5))
        let payload = Announce.buildPayload(identity: identity, destinationHash: destinationHash,
                                            nameHash: nameHash, randomHash: randomHash, ratchet: ratchet)
        return try! Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                           destinationType: .single, context: .none, contextFlag: ratchet != nil, hops: hops,
                           destinationHash: destinationHash, transportId: nil, payload: payload).packed()
    }
}

/// A fresh ratchet: the private key (which only the peer would hold) and the public key it announces.
private func newRatchet() -> (privateKey: Data, publicKey: Data) {
    let key = Curve25519.KeyAgreement.PrivateKey()
    return (key.rawRepresentation, key.publicKey.rawRepresentation)
}

@MainActor
private func makeStore(_ initial: Transport.State = Transport.State(),
                       clock now: LockIsolated<Date>) -> TestStore<Transport.State, Transport.Action> {
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    return store
}

@MainActor
private func connected(_ now: LockIsolated<Date>) async -> TestStore<Transport.State, Transport.Action> {
    let store = makeStore(clock: now)
    await store.send(.interfaceConnected(i0))
    return store
}

/// Sends `plaintext` opportunistically to `dest` and returns the transmitted packet's payload.
@MainActor
private func sendAndCapturePayload(_ store: TestStore<Transport.State, Transport.Action>, to dest: Data,
                                   _ plaintext: Data) async throws -> Data {
    let sent = LockIsolated<Data?>(nil)
    await store.send(.send(destinationHash: dest, plaintext: plaintext, receiptToken: nil))
    await store.receive { action in
        guard case let .delegate(.transmit(_, raw)) = action else { return false }
        sent.setValue(raw)
        return true
    }
    let raw = try #require(sent.value)
    return try #require(Packet(raw: raw)).payload
}

@Suite @MainActor struct PeerRatchetTests {
    // MARK: Review Focus 1

    @Test func aRatchetlessAnnounceDoesNotClearTheKnownRatchet() async {
        let now = LockIsolated(start)
        let store = await connected(now)
        let peer = Peer()
        let r1 = newRatchet()

        await store.send(.received(i0, peer.announce(emitted: 1000, prefix: 0x01, ratchet: r1.publicKey)))
        #expect(store.state.knownDestinations[peer.destinationHash]?.ratchet == r1.publicKey)
        #expect(store.state.knownDestinations[peer.destinationHash]?.ratchetReceived == start)

        // A newer announce without a ratchet WINS the path (newer emission) ...
        now.setValue(start.addingTimeInterval(60))
        await store.send(.received(i0, peer.announce(emitted: 2000, prefix: 0x02, ratchet: nil)))
        #expect(store.state.learned[peer.destinationHash]?.announceEmitted == 2000, "precondition: it won the path")
        #expect(store.state.knownDestinations[peer.destinationHash]?.lastHeard == now.value,
                "precondition: it refreshed the known destination")
        // ... and leaves the ratchet, with its first receive time.
        #expect(store.state.knownDestinations[peer.destinationHash]?.ratchet == r1.publicKey)
        #expect(store.state.knownDestinations[peer.destinationHash]?.ratchetReceived == start)
        #expect(store.state.recallRatchet(destinationHash: peer.destinationHash, now: now.value) == r1.publicKey)
    }

    @Test func aFreshAnnounceThatLosesThePathStillRefreshesTheRatchet() async {
        let now = LockIsolated(start)
        let store = await connected(now)
        let peer = Peer()
        let r1 = newRatchet(), r2 = newRatchet()

        await store.send(.received(i0, peer.announce(emitted: 1000, prefix: 0x01, hops: 1, ratchet: r1.publicKey)))
        // Same emission second, a new random blob, more hops: it does not replace the path.
        now.setValue(start.addingTimeInterval(5))
        await store.send(.received(i0, peer.announce(emitted: 1000, prefix: 0x02, hops: 4, ratchet: r2.publicKey)))
        #expect(store.state.learned[peer.destinationHash]?.hops == 1, "precondition: the path did not change")
        #expect(store.state.knownDestinations[peer.destinationHash]?.ratchet == r2.publicKey)
        #expect(store.state.knownDestinations[peer.destinationHash]?.ratchetReceived == now.value)
    }

    @Test func aReplayedOlderAnnounceDoesNotPutItsRatchetBack() async {
        let now = LockIsolated(start)
        let store = await connected(now)
        let peer = Peer()
        let r1 = newRatchet(), r2 = newRatchet()
        let old = peer.announce(emitted: 1000, prefix: 0x01, ratchet: r1.publicKey)

        await store.send(.received(i0, old))
        await store.send(.received(i0, peer.announce(emitted: 2000, prefix: 0x02, ratchet: r2.publicKey)))
        #expect(store.state.knownDestinations[peer.destinationHash]?.ratchet == r2.publicKey)
        now.setValue(start.addingTimeInterval(30))
        await store.send(.received(i0, old))     // same bytes: a replay, answered from the verdict cache
        #expect(store.state.knownDestinations[peer.destinationHash]?.lastHeard == now.value,
                "precondition: the replay was accepted as valid and refreshed the known destination")
        #expect(store.state.knownDestinations[peer.destinationHash]?.ratchet == r2.publicKey)
    }

    @Test func theSameRatchetHeardAgainKeepsItsFirstReceiveTime() async {
        let now = LockIsolated(start)
        let store = await connected(now)
        let peer = Peer()
        let r1 = newRatchet()

        await store.send(.received(i0, peer.announce(emitted: 1000, prefix: 0x01, ratchet: r1.publicKey)))
        now.setValue(start.addingTimeInterval(3600))
        await store.send(.received(i0, peer.announce(emitted: 4600, prefix: 0x02, ratchet: r1.publicKey)))
        #expect(store.state.knownDestinations[peer.destinationHash]?.lastHeard == now.value)
        #expect(store.state.knownDestinations[peer.destinationHash]?.ratchetReceived == start)
    }

    @Test func anUnusableAnnouncedRatchetIsNotRemembered() async {
        let now = LockIsolated(start)
        let store = await connected(now)
        let peer = Peer()
        let r1 = newRatchet()
        await store.send(.received(i0, peer.announce(emitted: 1000, prefix: 0x01, ratchet: r1.publicKey)))
        // A low-order point: the announce is kept, its ratchet dropped by Announce.parse.
        await store.send(.received(i0, peer.announce(emitted: 2000, prefix: 0x02,
                                                     ratchet: Data(repeating: 0, count: 32))))
        #expect(store.state.learned[peer.destinationHash]?.announceEmitted == 2000)
        #expect(store.state.knownDestinations[peer.destinationHash]?.ratchet == r1.publicKey)
    }

    // MARK: Expiry

    @Test func recallRatchetAnswersNilPastThirtyDays() {
        var state = Transport.State()
        let dest = Data(repeating: 0xD1, count: 16)
        let r = newRatchet()
        state.knownDestinations[dest] = KnownDestination(identity: Identity(), appData: nil, lastHeard: start,
                                                         ratchet: r.publicKey, ratchetReceived: start)
        #expect(Transport.ratchetExpiry == 60 * 60 * 24 * 30)
        #expect(state.recallRatchet(destinationHash: dest, now: start.addingTimeInterval(Transport.ratchetExpiry))
                == r.publicKey)
        #expect(state.recallRatchet(destinationHash: dest,
                                    now: start.addingTimeInterval(Transport.ratchetExpiry + 1)) == nil)
        // No receive time: treated as expired.
        state.knownDestinations[dest]?.ratchetReceived = nil
        #expect(state.recallRatchet(destinationHash: dest, now: start) == nil)
    }

    @Test func maintenanceClearsAnExpiredRatchetAndKeepsTheDestination() async {
        let fresh = Data(repeating: 0xA1, count: 16), stale = Data(repeating: 0xA2, count: 16)
        let rFresh = newRatchet(), rStale = newRatchet()
        let now = start.addingTimeInterval(Transport.ratchetExpiry + 10)
        var state = Transport.State()
        state.knownDestinations[fresh] = KnownDestination(
            identity: Identity(), appData: nil, lastHeard: now,
            ratchet: rFresh.publicKey, ratchetReceived: now.addingTimeInterval(-10))
        state.knownDestinations[stale] = KnownDestination(
            identity: Identity(), appData: nil, lastHeard: now,
            ratchet: rStale.publicKey, ratchetReceived: start)
        let store = makeStore(state, clock: LockIsolated(now))
        await store.send(.maintenanceTick)
        #expect(store.state.knownDestinations[stale] != nil, "the destination itself is heard recently")
        #expect(store.state.knownDestinations[stale]?.ratchet == nil)
        #expect(store.state.knownDestinations[stale]?.ratchetReceived == nil)
        #expect(store.state.knownDestinations[fresh]?.ratchet == rFresh.publicKey)
    }

    // MARK: Opportunistic encryption

    @Test func anOpportunisticPacketIsEncryptedToTheRecalledRatchet() async throws {
        let now = LockIsolated(start)
        let store = await connected(now)
        let peerIdentity = Identity()      // holds the private key, standing in for the peer
        let peer = Peer(identity: peerIdentity)
        let r = newRatchet()
        await store.send(.received(i0, peer.announce(emitted: 1000, prefix: 0x01, ratchet: r.publicKey)))
        await store.send(.received(i0, peer.announce(emitted: 2000, prefix: 0x02, ratchet: nil)))

        let plaintext = Data("to the ratchet".utf8)
        let payload = try await sendAndCapturePayload(store, to: peer.destinationHash, plaintext)
        #expect(peerIdentity.decrypt(payload) == nil, "the identity key alone must not open it")
        #expect(peerIdentity.decrypt(payload, ratchets: [r.privateKey]) == plaintext)
    }

    @Test func anOpportunisticPacketGoesToTheIdentityKeyOnceTheRatchetExpired() async throws {
        let now = LockIsolated(start)
        let store = await connected(now)
        let peerIdentity = Identity()
        let peer = Peer(identity: peerIdentity)
        let r = newRatchet()
        await store.send(.received(i0, peer.announce(emitted: 1000, prefix: 0x01, ratchet: r.publicKey)))
        now.setValue(start.addingTimeInterval(Transport.ratchetExpiry + 1))
        // No maintenance has run: the path and the stale ratchet are both still in state.
        #expect(store.state.knownDestinations[peer.destinationHash]?.ratchet == r.publicKey)
        let plaintext = Data("to the identity".utf8)
        let payload = try await sendAndCapturePayload(store, to: peer.destinationHash, plaintext)
        #expect(peerIdentity.decrypt(payload) == plaintext)
    }

    @Test func aRatchetHostsStillStoreOnThePathEntryIsIgnored() async throws {
        let peerIdentity = Identity()
        let dest = Data(repeating: 0xD1, count: 16)
        let legacy = newRatchet()
        var state = Transport.State()
        state.interfaces[i0] = .default
        state.learned[dest] = LearnedDestination(identity: peerIdentity, appData: nil, ratchet: legacy.publicKey,
                                                 interfaceID: i0, hops: 0, nextHop: nil, announceEmitted: 0,
                                                 learnedAt: start)
        let store = makeStore(state, clock: LockIsolated(start))
        let plaintext = Data("legacy".utf8)
        let payload = try await sendAndCapturePayload(store, to: dest, plaintext)
        #expect(peerIdentity.decrypt(payload) == plaintext)
    }

    // MARK: Rehydration

    @Test func rehydrateCarriesTheRatchetAndItsReceiveTime() async {
        let dest = Data(repeating: 0xB1, count: 16)
        let r = newRatchet()
        let received = start.addingTimeInterval(-3600)
        let store = makeStore(clock: LockIsolated(start))
        await store.send(.rehydrateKnownDestinations([dest: KnownDestination(
            identity: Identity(), appData: nil, lastHeard: received,
            ratchet: r.publicKey, ratchetReceived: received)]))
        #expect(store.state.knownDestinations[dest]?.ratchet == r.publicKey)
        #expect(store.state.knownDestinations[dest]?.ratchetReceived == received)
        #expect(store.state.recallRatchet(destinationHash: dest, now: start) == r.publicKey)
    }

    @Test func rehydrateDropsAnUnusableOrStaleRatchetAndKeepsTheRow() async {
        let r = newRatchet()
        let lowOrder = Data(hexString: "0000000000000000000000000000000000000000000000000000000000000000")!
        let cases: [(String, Data, Date?)] = [
            ("low-order point", lowOrder, start.addingTimeInterval(-60)),
            ("wrong length", Data(r.publicKey.prefix(31)), start.addingTimeInterval(-60)),
            ("no receive time", r.publicKey, nil),
            ("received in the future", r.publicKey, start.addingTimeInterval(60)),
            ("expired", r.publicKey, start.addingTimeInterval(-Transport.ratchetExpiry - 1)),
            ("non-finite", r.publicKey, Date(timeIntervalSinceReferenceDate: .nan)),
        ]
        var rows: [Data: KnownDestination] = [:]
        for (index, (_, ratchet, received)) in cases.enumerated() {
            rows[Data(repeating: UInt8(index + 1), count: 16)] = KnownDestination(
                identity: Identity(), appData: nil, lastHeard: start.addingTimeInterval(-60),
                ratchet: ratchet, ratchetReceived: received)
        }
        let store = makeStore(clock: LockIsolated(start))
        await store.send(.rehydrateKnownDestinations(rows))
        for (index, (name, _, _)) in cases.enumerated() {
            let hash = Data(repeating: UInt8(index + 1), count: 16)
            #expect(store.state.knownDestinations[hash] != nil, "\(name): the row is restored")
            #expect(store.state.knownDestinations[hash]?.ratchet == nil, "\(name): its ratchet is not")
            #expect(store.state.knownDestinations[hash]?.ratchetReceived == nil, "\(name)")
        }
    }

    @Test func aFresherLiveEntryWithoutARatchetTakesTheRestoredOne() async {
        let now = LockIsolated(start)
        let store = await connected(now)
        let peer = Peer()
        let r = newRatchet()
        await store.send(.received(i0, peer.announce(emitted: 1000, prefix: 0x01, ratchet: nil)))
        let received = start.addingTimeInterval(-3600)
        await store.send(.rehydrateKnownDestinations([peer.destinationHash: KnownDestination(
            identity: peer.identity, appData: Data([0x01]), lastHeard: received,
            ratchet: r.publicKey, ratchetReceived: received)]))
        #expect(store.state.knownDestinations[peer.destinationHash]?.lastHeard == start, "the live entry wins")
        #expect(store.state.knownDestinations[peer.destinationHash]?.appData == nil)
        #expect(store.state.knownDestinations[peer.destinationHash]?.ratchet == r.publicKey)
        #expect(store.state.knownDestinations[peer.destinationHash]?.ratchetReceived == received)
    }

    /// A restored row heard more recently than the live entry wins the entry, but not the ratchet:
    /// the ratchet received later is kept, whichever entry it came with.
    @Test func aNewerRestoredRowKeepsTheFresherRatchet() async {
        let now = LockIsolated(start)
        let store = await connected(now)
        let noRatchet = Peer(), olderRatchet = Peer(), newerRatchet = Peer()
        let live = [noRatchet, olderRatchet, newerRatchet].map { _ in newRatchet() }
        for (peer, r) in zip([noRatchet, olderRatchet, newerRatchet], live) {
            await store.send(.received(i0, peer.announce(emitted: 1000, prefix: 0x01, ratchet: r.publicKey)))
        }
        now.setValue(start.addingTimeInterval(60))
        let rowHeard = start.addingTimeInterval(30)
        let restoredOlder = newRatchet(), restoredNewer = newRatchet()
        await store.send(.rehydrateKnownDestinations([
            noRatchet.destinationHash: KnownDestination(
                identity: noRatchet.identity, appData: Data([0x01]), lastHeard: rowHeard),
            olderRatchet.destinationHash: KnownDestination(
                identity: olderRatchet.identity, appData: Data([0x02]), lastHeard: rowHeard,
                ratchet: restoredOlder.publicKey, ratchetReceived: start.addingTimeInterval(-3600)),
            newerRatchet.destinationHash: KnownDestination(
                identity: newerRatchet.identity, appData: Data([0x03]), lastHeard: rowHeard,
                ratchet: restoredNewer.publicKey, ratchetReceived: start.addingTimeInterval(20)),
        ]))
        let known = store.state.knownDestinations
        for (peer, appData) in [(noRatchet, 0x01), (olderRatchet, 0x02), (newerRatchet, 0x03)] {
            #expect(known[peer.destinationHash]?.lastHeard == rowHeard, "precondition: the row won the entry")
            #expect(known[peer.destinationHash]?.appData == Data([UInt8(appData)]))
        }
        #expect(known[noRatchet.destinationHash]?.ratchet == live[0].publicKey, "a row without one keeps the live ratchet")
        #expect(known[noRatchet.destinationHash]?.ratchetReceived == start)
        #expect(known[olderRatchet.destinationHash]?.ratchet == live[1].publicKey, "an older restored ratchet loses")
        #expect(known[olderRatchet.destinationHash]?.ratchetReceived == start)
        #expect(known[newerRatchet.destinationHash]?.ratchet == restoredNewer.publicKey, "a newer one wins")
        #expect(known[newerRatchet.destinationHash]?.ratchetReceived == start.addingTimeInterval(20))
    }

    /// The live entry wins (heard last) but its ratchet is older than the restored one: the restored
    /// ratchet is taken.
    @Test func aWinningLiveEntryTakesANewerRestoredRatchet() async {
        let now = LockIsolated(start)
        let store = await connected(now)
        let peer = Peer()
        let rLive = newRatchet(), rRestored = newRatchet()
        await store.send(.received(i0, peer.announce(emitted: 1000, prefix: 0x01, ratchet: rLive.publicKey)))
        now.setValue(start.addingTimeInterval(120))
        await store.send(.received(i0, peer.announce(emitted: 2000, prefix: 0x02, ratchet: nil)))
        await store.send(.rehydrateKnownDestinations([peer.destinationHash: KnownDestination(
            identity: peer.identity, appData: Data([0x09]), lastHeard: start.addingTimeInterval(60),
            ratchet: rRestored.publicKey, ratchetReceived: start.addingTimeInterval(60))]))
        #expect(store.state.knownDestinations[peer.destinationHash]?.lastHeard == now.value, "the live entry wins")
        #expect(store.state.knownDestinations[peer.destinationHash]?.ratchet == rRestored.publicKey)
        #expect(store.state.knownDestinations[peer.destinationHash]?.ratchetReceived == start.addingTimeInterval(60))
    }
}
