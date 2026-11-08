import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// Reference RNS 1.6.0's announce verdict caches (Identity.py:682-791): announce bytes judged once are
// not parsed again. A refused announce is dropped unparsed (a low stamp is re-validated once the cost
// falls to its value); a valid one skips the parse but still refreshes the known destination, meets the
// replay check and the path logic. Each cache holds 128 entries and evicts the oldest.
//
// Parses are counted with the task-local `Announce.parseProbe`.

private struct StampedAnnounce: Decodable {
    let destination_hash: String
    let context_flag: Bool
    let payload: String
    let stamp_value: Double?

    var destinationHash: Data { Data(hexString: destination_hash)! }
    func raw(hops: UInt8 = 1) -> Data {
        try! Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                    destinationType: .single, context: .none, contextFlag: context_flag, hops: hops,
                    destinationHash: destinationHash, transportId: nil,
                    payload: Data(hexString: payload)!).packed()
    }

    static func load(_ name: String) throws -> StampedAnnounce {
        struct File: Decodable { let cases: [String: StampedAnnounce] }
        let url = try #require(Bundle.module.url(forResource: "stamped_announce_packet_fixtures", withExtension: "json"))
        return try #require(try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases[name])
    }
}

/// A signed, unstamped announce from a fresh identity: (raw, destination hash).
private func makeAnnounce(hops: UInt8 = 1, emitted: UInt64 = 1000, contextFlag: Bool = false) -> (Data, Data) {
    let identity = Identity()
    let nameHash = Destination.nameHash(appName: "cache", aspects: ["test"])
    let destHash = Destination.hash(identityHash: identity.hash, appName: "cache", aspects: ["test"])
    let randomHash = Announce.randomHash(now: emitted, randomPrefix: Data(repeating: 0x5A, count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash, nameHash: nameHash,
                                        randomHash: randomHash, appData: Data("meta".utf8))
    let packet = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: contextFlag, hops: hops,
                        destinationHash: destHash, transportId: nil, payload: payload)
    return (try! packet.packed(), destHash)
}

/// `raw` with one signature byte flipped: the same destination, refused for its signature.
private func forged(_ raw: Data) -> Data {
    var packet = Packet(raw: raw)!
    var payload = [UInt8](packet.payload)
    payload[64 + 10 + 10 + 3] ^= 0x01                         // key, name hash, random hash; no ratchet
    packet.payload = Data(payload)
    return try! packet.packed()
}

/// `raw` re-sent by a relay: HEADER_2 with `hops` and a transport ID. Same packet hash.
private func relayed(_ raw: Data, hops: UInt8, via transportID: Data) -> Data {
    let p = Packet(raw: raw)!
    return try! Packet(headerType: .header2, packetType: .announce, transportType: .transport,
                       destinationType: p.destinationType, context: p.context, contextFlag: p.contextFlag,
                       hops: hops, destinationHash: p.destinationHash, transportId: transportID,
                       payload: p.payload).packed()
}

@MainActor
private func makeStore(enforce: Bool = false, now: LockIsolated<Date> = LockIsolated(Date(timeIntervalSince1970: 1000)),
                       clock: any Clock<Duration> = ImmediateClock(),
                       configure: (inout Transport.State) -> Void = { _ in })
    -> TestStore<Transport.State, Transport.Action> {
    var initial = Transport.State()
    initial.enforceStamps = enforce
    configure(&initial)
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
        $0.date = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    return store
}

/// Sends `raw` on `id` and drains, counting the announce parses it caused.
@MainActor
private func parses(_ store: TestStore<Transport.State, Transport.Action>, _ id: String, _ raw: Data) async -> Int {
    let counter = Identity.LockedCounter()
    await Announce.$parseProbe.withValue(counter) {
        await store.send(.received(InterfaceID(id), raw))
        await store.skipReceivedActions(strict: false)
    }
    return counter.value
}

@Suite @MainActor struct AnnounceVerdictCacheTests {
    @Test func aReplayedInvalidAnnounceIsNotParsedAgain() async throws {
        let (raw, dest) = makeAnnounce()
        let bad = forged(raw)
        let store = makeStore()
        #expect(await parses(store, "i0", bad) == 1, "parsed once and refused")
        #expect(await parses(store, "i0", bad) == 0, "the same bytes again: dropped unparsed")
        #expect(await parses(store, "i1", relayed(bad, hops: 3, via: Data(repeating: 7, count: 16))) == 0,
                "a relayed copy has the same packet hash")
        #expect(store.state.knownDestinations[dest] == nil)
        // A refused announce does not shadow a valid one from the same destination: other bytes, other hash.
        #expect(await parses(store, "i0", raw) == 1)
        #expect(store.state.learned[dest] != nil)
    }

    /// Enforcing, a missing stamp is cached too, and dropped unparsed.
    @Test func enforcingAnUnstampedAnnounceIsNotParsedAgain() async throws {
        let (raw, dest) = makeAnnounce()
        let store = makeStore(enforce: true)
        #expect(await parses(store, "i0", raw) == 1)
        #expect(await parses(store, "i0", raw) == 0)
        #expect(store.state.knownDestinations[dest] == nil)
    }

    /// The packet hash leaves the context flag out but the parse depends on it. A flag-flipped copy of a
    /// valid announce, heard first, is refused, and must not get the genuine announce dropped unparsed.
    @Test func aFlagFlippedCopyHeardFirstDoesNotShadowTheGenuineAnnounce() async throws {
        let (raw, dest) = makeAnnounce()
        var flipped = try #require(Packet(raw: raw))
        flipped.contextFlag = true
        try #require(flipped.packetHash == Packet(raw: raw)!.packetHash)
        let store = makeStore()
        #expect(await parses(store, "i0", try flipped.packed()) == 1)
        #expect(store.state.knownDestinations[dest] == nil, "the flipped copy is refused")
        #expect(await parses(store, "i0", raw) == 1, "the genuine one is parsed")
        #expect(store.state.learned[dest] != nil, "and learned")

        // Enforcing, with a genuine stamped announce: the flipped copy still carries a stamp that meets
        // the cost at its tail, and is refused for its signature.
        let stamped = try StampedAnnounce.load("stripped")
        try #require(stamped.context_flag == false && (stamped.stamp_value ?? 0) >= 23.5)
        var stampedFlip = try #require(Packet(raw: stamped.raw()))
        stampedFlip.contextFlag = true
        let enforcing = makeStore(enforce: true)
        #expect(await parses(enforcing, "i0", try stampedFlip.packed()) == 1)
        #expect(enforcing.state.knownDestinations[stamped.destinationHash] == nil)
        #expect(await parses(enforcing, "i0", stamped.raw()) == 1)
        #expect(enforcing.state.learned[stamped.destinationHash] != nil)
    }

    @Test func aStampRejectedAtOneCostIsAcceptedOnceTheCostIsLowered() async throws {
        let low = try StampedAnnounce.load("below_cost")                     // value 9.09
        let value = try #require(low.stamp_value)
        try #require(value >= 9 && value < 10)
        let store = makeStore(enforce: true)
        func connect(cost: Double) async {
            await store.send(.interfaceConnected(InterfaceID("lo"),
                                                 InterfaceProfile(name: "lo", bitrate: 62_500, destinationCost: cost)))
        }
        await connect(cost: 23.5)
        #expect(await parses(store, "lo", low.raw()) == 1)
        #expect(store.state.knownDestinations[low.destinationHash] == nil, "9.09 is below 23.5")
        await connect(cost: 10)
        #expect(await parses(store, "lo", low.raw()) == 0, "still above the cached value: dropped unparsed")
        #expect(store.state.knownDestinations[low.destinationHash] == nil)
        await connect(cost: 9)
        #expect(await parses(store, "lo", low.raw()) == 1, "at or below the cached value: validated again")
        #expect(store.state.learned[low.destinationHash] != nil, "and accepted")
        #expect(store.state.knownDestinations[low.destinationHash]?.linkCost != nil)
    }

    /// A stamped announce cached valid at one cost is judged again at another: enforcing, refused where
    /// its stamp falls short; unenforced, its link cost is that of the interface it arrived on now.
    @Test func aCachedValidStampedAnnounceIsJudgedAtTheReceivingInterfacesCost() async throws {
        let low = try StampedAnnounce.load("below_cost")                     // value 9.09
        let now = LockIsolated(Date(timeIntervalSince1970: 1000))
        let enforcing = makeStore(enforce: true, now: now)
        await enforcing.send(.interfaceConnected(InterfaceID("lo"),
                                                 InterfaceProfile(name: "lo", bitrate: 62_500, destinationCost: 9)))
        await enforcing.send(.interfaceConnected(InterfaceID("plain")))      // 23.5
        _ = await parses(enforcing, "lo", low.raw())
        try #require(enforcing.state.knownDestinations[low.destinationHash] != nil)
        now.setValue(Date(timeIntervalSince1970: 2000))
        _ = await parses(enforcing, "plain", low.raw(hops: 2))
        #expect(enforcing.state.knownDestinations[low.destinationHash]?.lastHeard == Date(timeIntervalSince1970: 1000),
                "refused on the interface whose cost it does not meet")

        let lenient = makeStore(enforce: false)
        await lenient.send(.interfaceConnected(InterfaceID("lo"),
                                               InterfaceProfile(name: "lo", bitrate: 62_500, destinationCost: 9)))
        await lenient.send(.interfaceConnected(InterfaceID("plain")))
        _ = await parses(lenient, "plain", low.raw())
        try #require(lenient.state.knownDestinations[low.destinationHash] != nil)
        #expect(lenient.state.knownDestinations[low.destinationHash]?.linkCost == nil, "9.09 is below 23.5")
        _ = await parses(lenient, "lo", low.raw(hops: 2))
        #expect(lenient.state.knownDestinations[low.destinationHash]?.linkCost != nil, "and meets the 9 of lo")
    }

    @Test func the129thEntryEvictsTheOldest() async throws {
        let store = makeStore()
        let bad = (0...128).map { _ in forged(makeAnnounce().0) }
        for raw in bad { #expect(await parses(store, "i0", raw) == 1) }
        #expect(store.state.announceVerdicts.invalid.count == 128)
        #expect(await parses(store, "i0", bad[1]) == 0, "the second is still cached")
        #expect(await parses(store, "i0", bad[0]) == 1, "the first was evicted, so it is parsed again")

        let good = (0...128).map { i in makeAnnounce(emitted: 1000 + UInt64(i)).0 }
        for raw in good { _ = await parses(store, "i0", raw) }
        let valid = store.state.announceVerdicts.valid
        #expect(valid.count == 128)
        #expect(valid.keys.first == AnnounceVerdictCache.Key(Packet(raw: good[1])!), "the first valid one was evicted")
        #expect(valid.keys.last == AnnounceVerdictCache.Key(Packet(raw: good[128])!))
    }

    @Test func aCachedValidAnnounceStillRefreshesTheKnownDestination() async throws {
        let (raw, dest) = makeAnnounce()
        let now = LockIsolated(Date(timeIntervalSince1970: 1000))
        let store = makeStore(now: now)
        #expect(await parses(store, "i0", raw) == 1)
        #expect(store.state.knownDestinations[dest]?.lastHeard == Date(timeIntervalSince1970: 1000))
        now.setValue(Date(timeIntervalSince1970: 2000))
        #expect(await parses(store, "i0", relayed(raw, hops: 2, via: Data(repeating: 9, count: 16))) == 0,
                "not parsed again")
        #expect(store.state.knownDestinations[dest]?.lastHeard == Date(timeIntervalSince1970: 2000),
                "but the known destination is refreshed")
    }

    /// A cached-valid announce meets the replay check as before: a peer's re-broadcast of an announce a
    /// relay is holding is counted toward suppressing the relay's retry.
    @Test func aCachedValidAnnounceStillMeetsTheReplayCheck() async throws {
        let (raw, dest) = makeAnnounce()
        let store = makeStore(clock: TestClock())
        await store.send(.interfaceConnected(InterfaceID("i0")))
        await store.send(.interfaceConnected(InterfaceID("i1")))
        await store.send(.setTransportIdentity(Identity()))
        #expect(await parses(store, "i0", raw) == 1)
        let held = try #require(store.state.announceTable[dest])
        try #require(held.localRebroadcasts == 0)
        let peerCopy = relayed(raw, hops: held.rebroadcastHops, via: Data(repeating: 3, count: 16))
        #expect(await parses(store, "i1", peerCopy) == 0)
        #expect(store.state.announceTable[dest]?.localRebroadcasts == 1, "counted as a peer's re-broadcast")
        #expect(store.state.learned[dest]?.interfaceID == InterfaceID("i0"), "and not adopted as a new path")
    }

    /// A cached-valid announce still reaches the path logic: heard again on a live interface after its
    /// route's interface is gone, it moves the path there.
    @Test func aCachedValidAnnounceStillReachesThePathLogic() async throws {
        let (raw, dest) = makeAnnounce()
        let store = makeStore()
        await store.send(.interfaceConnected(InterfaceID("radio")))
        await store.send(.interfaceConnected(InterfaceID("tcp")))
        #expect(await parses(store, "radio", raw) == 1)
        #expect(store.state.learned[dest]?.interfaceID == InterfaceID("radio"))
        await store.send(.interfaceDisconnected(InterfaceID("radio")))
        #expect(await parses(store, "tcp", relayed(raw, hops: 2, via: Data(repeating: 4, count: 16))) == 0)
        #expect(store.state.learned[dest]?.interfaceID == InterfaceID("tcp"), "the stranded route is replaced")
    }
}
