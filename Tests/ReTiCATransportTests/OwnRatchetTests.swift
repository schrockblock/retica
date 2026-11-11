import Testing
import Foundation
import CryptoKit
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// Our own ratchet ring (reference RNS 1.6.0 Destination.py:87-94, 233-379, 575-611, 720-752): enabled by
// the host with a restored ring, rotated only when an announce or local path response is built and at
// most every 30 minutes (the first one after enabling rotates), carried in announces and path responses,
// and tried first when decrypting, with the identity key after unless enforced.

private let i0 = InterfaceID("i0")
private let start = Date(timeIntervalSince1970: 1_700_000_000)

/// The delegate actions a test looks at, in a Sendable form.
private enum Logged: Equatable, Sendable {
    case transmit(Data)
    case received(Data)
    case ratchetsChanged([Data])
    case other
}

/// Every delegate action the store emits, in order, so a test can assert one was NOT emitted.
private typealias DelegateLog = LockIsolated<[Logged]>

private struct ObservedTransport: Reducer {
    typealias State = Transport.State
    typealias Action = Transport.Action
    let log: DelegateLog

    var body: some Reducer<State, Action> {
        Reduce<State, Action> { _, action in
            guard case let .delegate(d) = action else { return .none }
            let entry: Logged
            switch d {
            case let .transmit(_, raw): entry = .transmit(raw)
            case let .received(_, plaintext, _, _): entry = .received(plaintext)
            case let .ratchetsChanged(_, ring): entry = .ratchetsChanged(ring)
            default: entry = .other
            }
            log.withValue { $0.append(entry) }
            return .none
        }
        Transport()
    }
}

/// A store with our destination registered and one interface connected, on the clock `now`.
@MainActor
private func makeStore(_ dest: Destination, _ log: DelegateLog, clock now: LockIsolated<Date>,
                       initial: Transport.State = Transport.State()) async -> TestStoreOf<Transport> {
    let store = TestStore(initialState: initial) { ObservedTransport(log: log) } withDependencies: {
        $0.continuousClock = ImmediateClock()
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(i0, .default))
    await store.send(.registerLocalDestination(dest))
    return store
}

private func ownDestination(_ identity: Identity = Identity()) -> Destination {
    Destination(kind: .single, direction: .in, appName: "retica", aspects: ["ownratchet"], identity: identity)!
}

private func newRatchetPrivate() -> Data { Curve25519.KeyAgreement.PrivateKey().rawRepresentation }

private func transmittedAnnounces(_ log: DelegateLog) -> [Packet] {
    log.value.compactMap {
        guard case let .transmit(raw) = $0, let p = Packet(raw: raw), p.packetType == .announce else { return nil }
        return p
    }
}

private func ringReports(_ log: DelegateLog) -> [[Data]] {
    log.value.compactMap {
        guard case let .ratchetsChanged(ring) = $0 else { return nil }
        return ring
    }
}

private func delivered(_ log: DelegateLog) -> [Data] {
    log.value.compactMap {
        guard case let .received(plaintext) = $0 else { return nil }
        return plaintext
    }
}

/// The ratchet `packet` (an announce of `dest`) carries, as our own parser reads it after verifying the
/// signature over it; nil if it carries none or does not verify.
private func announcedRatchet(_ packet: Packet, _ dest: Destination) -> Data? {
    Announce.parse(payload: packet.payload, destinationHash: dest.hash, contextFlagSet: packet.contextFlag)?.ratchet
}

private func pathRequest(for destHash: Data, tag: UInt8) -> Data {
    try! Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                payload: destHash + Data(repeating: tag, count: 16)).packed()
}

/// A DATA packet to `dest` encrypted to `ratchetPublic`, or to its identity key when nil.
private func dataPacket(to dest: Destination, _ plaintext: Data, ratchetPublic: Data?) -> Data {
    let recipient = Identity(publicKey: dest.identity!.publicKey)!
    return try! Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                       destinationType: .single, context: .none, contextFlag: false, hops: 0,
                       destinationHash: dest.hash, transportId: nil,
                       payload: recipient.encrypt(plaintext, ratchet: ratchetPublic)).packed()
}

/// A DATA packet to `dest` that no key of ours opens: encrypted to a ratchet we never held.
private func junk(to dest: Destination) -> Data {
    dataPacket(to: dest, Data("junk".utf8), ratchetPublic: Identity.ratchetPublicKey(privateKey: newRatchetPrivate()))
}

@Suite @MainActor struct OwnRatchetTests {
    // MARK: Review Focus 2 — rotation

    @Test func theFirstAnnounceAfterEnablingRotatesAndCarriesTheNewRatchet() async throws {
        let dest = ownDestination()
        let log = DelegateLog([])
        let now = LockIsolated(start)
        let store = await makeStore(dest, log, clock: now)
        let restored = [newRatchetPrivate(), newRatchetPrivate()]
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: restored))
        #expect(store.state.ownRatchets[dest.hash]?.ring == restored)
        #expect(ringReports(log).isEmpty, "enabling alone does not rotate")

        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        await store.skipReceivedActions(strict: false)
        let ring = try #require(store.state.ownRatchets[dest.hash]?.ring)
        try #require(ring.count == 3)
        #expect(Array(ring.dropFirst()) == restored, "the new key goes in front of the restored ones")
        #expect(store.state.ownRatchets[dest.hash]?.lastRotation == start)
        #expect(ringReports(log) == [ring], "the rotation is reported with the whole ring")

        let announce = try #require(transmittedAnnounces(log).first)
        #expect(announce.contextFlag)
        #expect(announcedRatchet(announce, dest) == Identity.ratchetPublicKey(privateKey: ring[0]))
    }

    @Test func rotationWaitsMoreThanThirtyMinutesAndHappensOnlyWhenAnnouncing() async throws {
        let dest = ownDestination()
        let log = DelegateLog([])
        let now = LockIsolated(start)
        let store = await makeStore(dest, log, clock: now)
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: []))
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        let first = try #require(store.state.ownRatchets[dest.hash]?.ring)
        try #require(first.count == 1)

        // Exactly 30 minutes later: not yet (reference rotates when now > last + interval).
        now.setValue(start.addingTimeInterval(Transport.ratchetInterval))
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        #expect(store.state.ownRatchets[dest.hash]?.ring == first)

        // Time passes with no announce: maintenance and inbound traffic do not rotate.
        now.setValue(start.addingTimeInterval(Transport.ratchetInterval * 3))
        await store.send(.maintenanceTick)
        await store.send(.received(i0, dataPacket(to: dest, Data("x".utf8), ratchetPublic: nil)))
        #expect(store.state.ownRatchets[dest.hash]?.ring == first)

        // The next announce rotates.
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        await store.skipReceivedActions(strict: false)
        let second = try #require(store.state.ownRatchets[dest.hash]?.ring)
        try #require(second.count == 2)
        #expect(second[1] == first[0])
        #expect(ringReports(log).count == 2)
        let announces = transmittedAnnounces(log)
        #expect(announces.count == 3)
        #expect(announces.map { announcedRatchet($0, dest) } == [
            Identity.ratchetPublicKey(privateKey: first[0]), Identity.ratchetPublicKey(privateKey: first[0]),
            Identity.ratchetPublicKey(privateKey: second[0])])
    }

    @Test func aLocalPathResponseCarriesTheCurrentRatchetAndRotatesWhenDue() async throws {
        let dest = ownDestination()
        let log = DelegateLog([])
        let now = LockIsolated(start)
        let store = await makeStore(dest, log, clock: now)
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: []))
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        let first = try #require(store.state.ownRatchets[dest.hash]?.ring)
        try #require(first.count == 1)

        now.setValue(start.addingTimeInterval(Transport.ratchetInterval + 1))
        await store.send(.received(i0, pathRequest(for: dest.hash, tag: 0x51)))
        await store.skipReceivedActions(strict: false)
        let ring = try #require(store.state.ownRatchets[dest.hash]?.ring)
        try #require(ring.count == 2, "the path response rotated, as reference's _announce does")
        #expect(ring[1] == first[0])
        let response = try #require(transmittedAnnounces(log).last)
        #expect(response.context == .pathResponse)
        #expect(response.contextFlag)
        #expect(announcedRatchet(response, dest) == Identity.ratchetPublicKey(privateKey: ring[0]))
    }

    @Test func theRingKeepsAtMost512() async throws {
        let dest = ownDestination()
        let log = DelegateLog([])
        let store = await makeStore(dest, log, clock: LockIsolated(start))
        let restored = (0..<520).map { _ in newRatchetPrivate() }
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: restored))
        #expect(store.state.ownRatchets[dest.hash]?.ring == Array(restored.prefix(512)))
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        let ring = try #require(store.state.ownRatchets[dest.hash]?.ring)
        #expect(Transport.ratchetCount == 512)
        #expect(ring.count == 512)
        #expect(Array(ring.dropFirst()) == Array(restored.prefix(511)), "the oldest falls off")
    }

    @Test func withoutEnablingAnnouncesCarryNoRatchet() async throws {
        let dest = ownDestination()
        let log = DelegateLog([])
        let store = await makeStore(dest, log, clock: LockIsolated(start))
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        await store.skipReceivedActions(strict: false)
        let announce = try #require(transmittedAnnounces(log).first)
        #expect(!announce.contextFlag)
        #expect(store.state.ownRatchets.isEmpty)
        #expect(ringReports(log).isEmpty)
    }

    // MARK: Review Focus 5 — a corrupted restored ring

    @Test func aCorruptedOrWrongLengthRestoredEntryIsDroppedAndNeverTried() async throws {
        let dest = ownDestination()
        let log = DelegateLog([])
        let now = LockIsolated(start)
        let store = await makeStore(dest, log, clock: now)
        let good = newRatchetPrivate()
        let restored = [Data(), Data(repeating: 0xAB, count: 31), Data(repeating: 0xCD, count: 33), good,
                        Data(repeating: 0xEF, count: 64)]
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: restored))
        #expect(store.state.ownRatchets[dest.hash]?.ring == [good])

        // Only garbage: an empty ring, enabled.
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: [Data(repeating: 1, count: 16)]))
        #expect(store.state.ownRatchets[dest.hash]?.ring == [])
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: restored))

        // The ring decrypts with the good entry, nothing traps, and the announce carries a real ratchet.
        await store.send(.received(i0, dataPacket(to: dest, Data("old".utf8),
                                                  ratchetPublic: Identity.ratchetPublicKey(privateKey: good))))
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        await store.skipReceivedActions(strict: false)
        #expect(delivered(log) == [Data("old".utf8)])
        let ring = try #require(store.state.ownRatchets[dest.hash]?.ring)
        try #require(ring.count == 2)
        #expect(ring[1] == good)
        let announce = try #require(transmittedAnnounces(log).first)
        #expect(announcedRatchet(announce, dest) == Identity.ratchetPublicKey(privateKey: ring[0]))
    }

    // MARK: Review Focus 3 — decrypting with the ring

    @Test func aPacketToAnyOf512RetainedRatchetsDecrypts() async throws {
        let dest = ownDestination()
        let log = DelegateLog([])
        let store = await makeStore(dest, log, clock: LockIsolated(start))
        let ring = (0..<512).map { _ in newRatchetPrivate() }
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: ring))
        for (index, text) in [(0, "newest"), (255, "middle"), (511, "oldest")] {
            await store.send(.received(i0, dataPacket(to: dest, Data(text.utf8),
                                                      ratchetPublic: Identity.ratchetPublicKey(privateKey: ring[index]))))
        }
        // One encrypted to a ratchet that fell off the ring decrypts with nothing.
        await store.send(.received(i0, dataPacket(to: dest, Data("gone".utf8),
                                                  ratchetPublic: Identity.ratchetPublicKey(privateKey: newRatchetPrivate()))))
        await store.skipReceivedActions(strict: false)
        #expect(delivered(log) == ["newest", "middle", "oldest"].map { Data($0.utf8) })
    }

    @Test func theIdentityKeyDecryptsUnlessRatchetsAreEnforced() async throws {
        let dest = ownDestination()
        let log = DelegateLog([])
        let store = await makeStore(dest, log, clock: LockIsolated(start))
        let r = newRatchetPrivate()
        let toRatchet = Identity.ratchetPublicKey(privateKey: r)
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: [r]))
        await store.send(.received(i0, dataPacket(to: dest, Data("identity, unenforced".utf8), ratchetPublic: nil)))

        await store.send(.setEnforceRatchets(destinationHash: dest.hash, true))
        #expect(store.state.ownRatchets[dest.hash]?.enforce == true)
        await store.send(.received(i0, dataPacket(to: dest, Data("identity, enforced".utf8), ratchetPublic: nil)))
        await store.send(.received(i0, dataPacket(to: dest, Data("ratchet, enforced".utf8), ratchetPublic: toRatchet)))

        // Enforcement survives re-enabling with a restored ring, as reference keeps it on the destination.
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: [r]))
        await store.send(.received(i0, dataPacket(to: dest, Data("identity, re-enabled".utf8), ratchetPublic: nil)))

        await store.send(.setEnforceRatchets(destinationHash: dest.hash, false))
        await store.send(.received(i0, dataPacket(to: dest, Data("identity, lifted".utf8), ratchetPublic: nil)))
        await store.skipReceivedActions(strict: false)
        #expect(delivered(log) == ["identity, unenforced", "ratchet, enforced", "identity, lifted"].map { Data($0.utf8) })
    }

    @Test func enforcementIsIgnoredUntilRatchetsAreEnabled() async {
        let dest = ownDestination()
        let log = DelegateLog([])
        let store = await makeStore(dest, log, clock: LockIsolated(start))
        await store.send(.setEnforceRatchets(destinationHash: dest.hash, true))
        #expect(store.state.ownRatchets[dest.hash] == nil)
        await store.send(.received(i0, dataPacket(to: dest, Data("plain identity".utf8), ratchetPublic: nil)))
        await store.skipReceivedActions(strict: false)
        #expect(delivered(log) == [Data("plain identity".utf8)])
    }

    /// A served (stampless) propagated entry to our newest ratchet costs ONE key agreement with a full
    /// ring: the full tail is tried first, as reference's single pass. Trying the stamp-stripped layout
    /// first scanned the whole ring (513 agreements) before every successful decrypt.
    @Test func aServedPropagatedEntryToTheNewestRatchetCostsOneAgreement() throws {
        let me = Identity()
        let ring = (0..<512).map { _ in newRatchetPrivate() }
        let msg = LXMessage.create(source: Identity(), destinationHash: LXMessage.deliveryHash(identityHash: me.hash),
                                   timestamp: 1700000000.5, title: Data("t".utf8), content: Data("served".utf8))
        let tail = Data(msg.packed.dropFirst(LXMessage.destinationLength))
        let served = LXMFPropagation.lxmfData(destinationHash: msg.destinationHash,
                                              encryptedData: me.encrypt(tail, ratchet: Identity.ratchetPublicKey(privateKey: ring[0])))
        let counter = Identity.LockedCounter()
        let recovered = Identity.$decryptAgreementProbe.withValue(counter) {
            LXMFPropagation.recoverPacked(lxmfData: served, recipientIdentity: me, ratchets: ring)
        }
        #expect(recovered == msg.packed)
        #expect(counter.value == 1)
    }

    // MARK: Parity follow-ups Task 2 — the inbound deep-scan budget (a deliberate divergence: reference
    // Destination.decrypt, Destination.py:720-752, always scans the whole ring)

    /// Review Focus: a junk flood empties the receiving interface's deep-scan budget, and a packet to our
    /// newest ratchet (or to the identity key) still decrypts, from the shallow attempt alone.
    @Test func aJunkFloodEmptiesTheBudgetButTheNewestRatchetStillDecrypts() async throws {
        let dest = ownDestination()
        let log = DelegateLog([])
        let store = await makeStore(dest, log, clock: LockIsolated(start))
        let ring = (0..<512).map { _ in newRatchetPrivate() }
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: ring))
        // Each junk packet that finds a token scans the whole ring (513 agreements). The ninth finds none.
        for n in 0..<Transport.ratchetDeepScanBurst {
            let counter = Identity.LockedCounter()
            await Identity.$decryptAgreementProbe.withValue(counter) {
                await store.send(.received(i0, junk(to: dest)))
            }
            #expect(counter.value == 513, "junk #\(n) with a token scans the whole ring and the identity key")
        }
        for _ in 0..<40 {
            let counter = Identity.LockedCounter()
            await Identity.$decryptAgreementProbe.withValue(counter) {
                await store.send(.received(i0, junk(to: dest)))
            }
            #expect(counter.value == Transport.ratchetShallowDepth + 1,
                    "with the budget empty a junk packet costs the shallow ratchets and the identity key only")
        }
        await store.send(.received(i0, dataPacket(to: dest, Data("newest".utf8),
                                                  ratchetPublic: Identity.ratchetPublicKey(privateKey: ring[0]))))
        await store.send(.received(i0, dataPacket(to: dest, Data("16th".utf8),
                                                  ratchetPublic: Identity.ratchetPublicKey(privateKey: ring[15]))))
        await store.send(.received(i0, dataPacket(to: dest, Data("identity".utf8), ratchetPublic: nil)))
        await store.skipReceivedActions(strict: false)
        #expect(delivered(log) == ["newest", "16th", "identity"].map { Data($0.utf8) })
    }

    @Test func aPacketToThe100thRatchetDecryptsWithATokenAndIsDroppedWithout() async throws {
        let dest = ownDestination()
        let log = DelegateLog([])
        let store = await makeStore(dest, log, clock: LockIsolated(start))
        let ring = (0..<512).map { _ in newRatchetPrivate() }
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: ring))
        let to100 = Identity.ratchetPublicKey(privateKey: ring[100])
        await store.send(.received(i0, dataPacket(to: dest, Data("with a token".utf8), ratchetPublic: to100)))
        for _ in 1..<Transport.ratchetDeepScanBurst { await store.send(.received(i0, junk(to: dest))) }
        await store.send(.received(i0, dataPacket(to: dest, Data("without".utf8), ratchetPublic: to100)))
        await store.skipReceivedActions(strict: false)
        #expect(delivered(log) == [Data("with a token".utf8)])
    }

    @Test func theBudgetRefillsWithTimeUpToTheBurst() async throws {
        let dest = ownDestination()
        let log = DelegateLog([])
        let now = LockIsolated(start)
        let store = await makeStore(dest, log, clock: now)
        let ring = (0..<512).map { _ in newRatchetPrivate() }
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: ring))
        let to100 = Identity.ratchetPublicKey(privateKey: ring[100])
        for _ in 0..<Transport.ratchetDeepScanBurst { await store.send(.received(i0, junk(to: dest))) }
        await store.send(.received(i0, dataPacket(to: dest, Data("empty".utf8), ratchetPublic: to100)))

        // Half a token is not a token, one second (ratchetDeepScanPerSecond = 1) is.
        now.setValue(start.addingTimeInterval(0.5))
        await store.send(.received(i0, dataPacket(to: dest, Data("half".utf8), ratchetPublic: to100)))
        now.setValue(start.addingTimeInterval(1))
        await store.send(.received(i0, dataPacket(to: dest, Data("refilled".utf8), ratchetPublic: to100)))
        await store.send(.received(i0, dataPacket(to: dest, Data("spent again".utf8), ratchetPublic: to100)))

        // A long quiet refills to the burst, no further.
        now.setValue(start.addingTimeInterval(3600))
        for n in 0...Transport.ratchetDeepScanBurst {
            await store.send(.received(i0, dataPacket(to: dest, Data("after quiet \(n)".utf8), ratchetPublic: to100)))
        }
        await store.skipReceivedActions(strict: false)
        #expect(delivered(log) == [Data("refilled".utf8)]
                + (0..<Transport.ratchetDeepScanBurst).map { Data("after quiet \($0)".utf8) })
    }

    /// A wall clock set back (here: an hour ahead, then corrected) does not freeze the bucket: the
    /// baseline moves back to the new time without refilling, and refill resumes from there.
    @Test func theBudgetRefillsAgainAfterTheClockIsSetBack() async throws {
        let dest = ownDestination()
        let log = DelegateLog([])
        let ahead = start.addingTimeInterval(3600)
        let now = LockIsolated(ahead)
        let store = await makeStore(dest, log, clock: now)
        let ring = (0..<512).map { _ in newRatchetPrivate() }
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: ring))
        let to100 = Identity.ratchetPublicKey(privateKey: ring[100])
        for _ in 0..<Transport.ratchetDeepScanBurst { await store.send(.received(i0, junk(to: dest))) }

        // Back to real time: the step back refills nothing.
        now.setValue(start)
        await store.send(.received(i0, dataPacket(to: dest, Data("set back".utf8), ratchetPublic: to100)))
        // Ten seconds later there are tokens again.
        now.setValue(start.addingTimeInterval(10))
        await store.send(.received(i0, dataPacket(to: dest, Data("10 s later".utf8), ratchetPublic: to100)))
        await store.skipReceivedActions(strict: false)
        #expect(delivered(log) == [Data("10 s later".utf8)])
        #expect(store.state.ratchetDeepScanBudgets[i0]?.updatedAt == start.addingTimeInterval(10))
    }

    @Test func enforcementRefusesTheIdentityKeyAtBothDepths() async throws {
        let dest = ownDestination()
        let log = DelegateLog([])
        let store = await makeStore(dest, log, clock: LockIsolated(start))
        let ring = (0..<512).map { _ in newRatchetPrivate() }
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: ring))
        await store.send(.setEnforceRatchets(destinationHash: dest.hash, true))
        // With tokens: the whole ring is scanned and the identity key never tried.
        let withTokens = Identity.LockedCounter()
        await Identity.$decryptAgreementProbe.withValue(withTokens) {
            await store.send(.received(i0, dataPacket(to: dest, Data("identity, deep".utf8), ratchetPublic: nil)))
        }
        #expect(withTokens.value == 512)
        await store.send(.received(i0, dataPacket(to: dest, Data("ratchet 300".utf8),
                                                  ratchetPublic: Identity.ratchetPublicKey(privateKey: ring[300]))))
        for _ in 2..<Transport.ratchetDeepScanBurst { await store.send(.received(i0, junk(to: dest))) }
        // Without: only the shallow ratchets, still not the identity key.
        let without = Identity.LockedCounter()
        await Identity.$decryptAgreementProbe.withValue(without) {
            await store.send(.received(i0, dataPacket(to: dest, Data("identity, shallow".utf8), ratchetPublic: nil)))
        }
        #expect(without.value == Transport.ratchetShallowDepth)
        await store.skipReceivedActions(strict: false)
        #expect(delivered(log) == [Data("ratchet 300".utf8)])
    }

    @Test func budgetsArePerInterfaceAndADisconnectDropsOne() async throws {
        let i1 = InterfaceID("i1")
        let dest = ownDestination()
        let log = DelegateLog([])
        let store = await makeStore(dest, log, clock: LockIsolated(start))
        await store.send(.interfaceConnected(i1, .default))
        let ring = (0..<512).map { _ in newRatchetPrivate() }
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: ring))
        let to100 = Identity.ratchetPublicKey(privateKey: ring[100])
        for _ in 0..<Transport.ratchetDeepScanBurst { await store.send(.received(i0, junk(to: dest))) }
        await store.send(.received(i0, dataPacket(to: dest, Data("i0, flooded".utf8), ratchetPublic: to100)))
        await store.send(.received(i1, dataPacket(to: dest, Data("i1".utf8), ratchetPublic: to100)))
        #expect(store.state.ratchetDeepScanBudgets.keys.sorted { $0.rawValue < $1.rawValue } == [i0, i1])

        await store.send(.interfaceDisconnected(i0))
        #expect(store.state.ratchetDeepScanBudgets[i0] == nil)
        #expect(store.state.ratchetDeepScanBudgets[i1] != nil)

        // An id that never registered gets no deep scan and mints no budget, so arbitrary ids cannot
        // grow the dictionary. The shallow attempt still runs.
        let ghost = InterfaceID("ghost")
        await store.send(.received(ghost, dataPacket(to: dest, Data("ghost, deep".utf8), ratchetPublic: to100)))
        await store.send(.received(ghost, dataPacket(to: dest, Data("ghost, newest".utf8),
                                                     ratchetPublic: Identity.ratchetPublicKey(privateKey: ring[0]))))
        #expect(store.state.ratchetDeepScanBudgets[ghost] == nil)
        await store.skipReceivedActions(strict: false)
        #expect(delivered(log) == ["i1", "ghost, newest"].map { Data($0.utf8) })
    }

    // MARK: Review Focus 4 — the announce budget and captured app data

    @Test func enablingForgetsCapturedAppDataThatNoLongerFitsAndKeepsAnnouncing() async throws {
        // Without stamping, an announce has 500 - 19 - 148 = 333 bytes for app data; a ratchet takes 32.
        let dest = ownDestination()
        let log = DelegateLog([])
        let store = await makeStore(dest, log, clock: LockIsolated(start))
        let tooLong = Data(repeating: 0x41, count: 320)
        await store.send(.announce(destinationHash: dest.hash, appData: tooLong))
        #expect(store.state.localAppData[dest.hash] == tooLong, "precondition: it fit without a ratchet")

        await store.send(.enableRatchets(destinationHash: dest.hash, ring: []))
        #expect(store.state.localAppData[dest.hash] == nil)

        // An announce without app data, and a path response, still go out, with the ratchet.
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        await store.send(.received(i0, pathRequest(for: dest.hash, tag: 0x77)))
        await store.skipReceivedActions(strict: false)
        let announces = transmittedAnnounces(log)
        #expect(announces.count == 3)
        #expect(announces.dropFirst().allSatisfy { $0.contextFlag && announcedRatchet($0, dest) != nil })

        // The same app data, offered again, does not fit any more and is not captured.
        await store.send(.announce(destinationHash: dest.hash, appData: tooLong))
        await store.skipReceivedActions(strict: false)
        #expect(transmittedAnnounces(log).count == 3)
        #expect(store.state.localAppData[dest.hash] == nil)
    }

    /// With stamping on, the LXMF name budget is exact: with a ratchet the announce of the ratchet-budget
    /// app data is exactly one MTU, and the no-ratchet budget's app data no longer fits.
    @Test func theLXMFBudgetWithARatchetIsExactWhenStamping() async throws {
        #expect(LXMFAnnounceData.maxAppDataBytesWithRatchet == LXMFAnnounceData.maxAppDataBytes - 32)
        let name = String(repeating: "N", count: 400)
        let withRatchet = LXMFAnnounceData.pack(displayName: name, stampCost: 99, ratchet: true)
        let withoutRatchet = LXMFAnnounceData.pack(displayName: name, stampCost: 99)
        #expect(withRatchet.count == LXMFAnnounceData.maxAppDataBytesWithRatchet)
        #expect(withoutRatchet.count == LXMFAnnounceData.maxAppDataBytes)
        #expect(LXMFAnnounceData.parse(withRatchet)?.displayName?.utf8.count == 299 - 32)   // with a cost

        let dest = Destination(kind: .single, direction: .in, appName: "lxmf", aspects: ["delivery"],
                               identity: Identity())!
        var stamping = Transport.State()
        stamping.stampDestinations = true
        stamping.destinationValue = 0
        for (appData, fits) in [(withRatchet, true), (withoutRatchet, false)] {
            let log = DelegateLog([])
            let store = await makeStore(dest, log, clock: LockIsolated(start), initial: stamping)
            await store.send(.rehydrateDestinationStamp(destinationHash: dest.hash, stamp: Data(repeating: 1, count: 14)))
            await store.send(.enableRatchets(destinationHash: dest.hash, ring: []))
            await store.send(.announce(destinationHash: dest.hash, appData: appData))
            await store.skipReceivedActions(strict: false)
            let announces = transmittedAnnounces(log)
            if fits {
                let announce = try #require(announces.first)
                #expect(try announce.packed().count == Packet.mtu, "the budget is exact")
                let parsed = Announce.parse(payload: announce.payload, destinationHash: dest.hash,
                                            contextFlagSet: announce.contextFlag, requiredStampValue: 0)
                #expect(parsed?.ratchet != nil)
                #expect(parsed?.appData == appData)
            } else {
                #expect(announces.isEmpty, "32 bytes over: nothing can be sent")
            }
        }
    }

    /// With stamping on, the enable-time re-check counts the 18-byte stamp extension too: 300 bytes fit
    /// beside the extension (315) but not beside the extension and a ratchet (283).
    @Test func enablingWhileStampingCountsTheStampExtensionInTheRecheck() async throws {
        let dest = ownDestination()
        let log = DelegateLog([])
        var stamping = Transport.State()
        stamping.stampDestinations = true
        stamping.destinationValue = 0
        let store = await makeStore(dest, log, clock: LockIsolated(start), initial: stamping)
        await store.send(.rehydrateDestinationStamp(destinationHash: dest.hash, stamp: Data(repeating: 1, count: 14)))
        let captured = Data(repeating: 0x43, count: 300)
        await store.send(.announce(destinationHash: dest.hash, appData: captured))
        #expect(store.state.localAppData[dest.hash] == captured, "precondition: it fit with the stamp")
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: []))
        #expect(store.state.localAppData[dest.hash] == nil)
        // And the destination still announces (without app data), stamped and ratcheted.
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        await store.skipReceivedActions(strict: false)
        let announces = transmittedAnnounces(log)
        #expect(announces.count == 2)
        #expect(announces.last.map { $0.contextFlag } == true)
    }

    @Test func enablingKeepsCapturedAppDataThatStillFits() async throws {
        let dest = ownDestination()
        let log = DelegateLog([])
        let store = await makeStore(dest, log, clock: LockIsolated(start))
        let fits = Data(repeating: 0x42, count: 333 - Transport.ratchetKeyLength)
        await store.send(.announce(destinationHash: dest.hash, appData: fits))
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: []))
        #expect(store.state.localAppData[dest.hash] == fits)
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        await store.skipReceivedActions(strict: false)
        let announce = try #require(transmittedAnnounces(log).last)
        let parsed = try #require(Announce.parse(payload: announce.payload, destinationHash: dest.hash,
                                                 contextFlagSet: announce.contextFlag))
        #expect(parsed.ratchet != nil)
        #expect(parsed.appData == fits)
    }
}
