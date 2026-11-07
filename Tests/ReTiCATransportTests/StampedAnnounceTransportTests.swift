import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// Transport ingest of RNS 1.6.0 stamped announces. Fixtures: the same real Destination._announce
// packets as ReTiCATests/Destination/StampedAnnounceTests (one generator writes both copies, see
// ReTiCATests/Vectors/generate_stamped_announce_packet_fixtures.py).

private struct StampedCase: Decodable {
    let destination_hash: String
    let context_flag: Bool
    let payload: String
    let app_data: String?
    let stamp_value: Double?
    let lr_cost: Double?

    var destinationHash: Data { Data(hexString: destination_hash)! }
    var payloadBytes: Data { Data(hexString: payload)! }

    /// The announce as heard directly (HEADER_1) at `hops`.
    func raw(hops: UInt8 = 1) -> Data {
        try! Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                    destinationType: .single, context: .none, contextFlag: context_flag, hops: hops,
                    destinationHash: destinationHash, transportId: nil, payload: payloadBytes).packed()
    }
}

private struct StampedFixtures: Decodable {
    let msgpack: String
    let cases: [String: StampedCase]

    subscript(_ name: String) -> StampedCase { cases[name]! }

    static func load() throws -> StampedFixtures {
        let url = Bundle.module.url(forResource: "stamped_announce_packet_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(StampedFixtures.self, from: Data(contentsOf: url))
    }
}

@Test @MainActor func aPathLearnedRecordsTheLinkCost() async throws {
    let f = try StampedFixtures.load()
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off

    let stamped = f["stripped"]
    await store.send(.received(InterfaceID("i0"), stamped.raw(hops: 2)))
    await store.receive(.delegate(.pathLearned(destinationHash: stamped.destinationHash, hops: 2)))
    let entry = try #require(store.state.learned[stamped.destinationHash])
    #expect(entry.linkCost == 3.25)
    #expect(entry.stampValue == stamped.stamp_value)
    #expect(entry.appData == Data(hexString: f.msgpack)!)
    #expect(store.state.knownDestinations[stamped.destinationHash]?.appData == Data(hexString: f.msgpack)!)

    // Below the cost: path learned all the same, no link cost, the extension left in app data.
    let low = f["below_cost"]
    await store.send(.received(InterfaceID("i0"), low.raw(hops: 2)))
    await store.receive(.delegate(.pathLearned(destinationHash: low.destinationHash, hops: 2)))
    let lowEntry = try #require(store.state.learned[low.destinationHash])
    #expect(lowEntry.linkCost == nil)
    #expect(lowEntry.stampValue == low.stamp_value)
    #expect(lowEntry.appData == Data(hexString: low.app_data!)!)
}

@Test @MainActor func aRehydratedPathKeepsItsLinkCost() async {
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1_000))
    }
    store.exhaustivity = .off
    let hash = Data(repeating: 0x11, count: 16)
    let entry = LearnedDestination(identity: Identity(), appData: nil, ratchet: nil,
                                   interfaceID: InterfaceID("i"), hops: 1, nextHop: hash, announceEmitted: 0,
                                   learnedAt: Date(timeIntervalSince1970: 900), linkCost: 7.5, stampValue: 24)
    await store.send(.rehydrateLearnedDestinations([hash: entry]))
    #expect(store.state.learned[hash] != nil)
    #expect(store.state.learned[hash]?.linkCost == 7.5)
    #expect(store.state.learned[hash]?.stampValue == 24)
}

@Test @MainActor func aRelayForwardsTheOriginalBytes() async throws {
    let f = try StampedFixtures.load()
    let relay = Identity()
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setTransportIdentity(relay))

    let c = f["stripped"]
    await store.send(.received(InterfaceID("i0"), c.raw(hops: 2)))
    await store.receive(.delegate(.pathLearned(destinationHash: c.destinationHash, hops: 2)))
    let rebroadcast = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { rebroadcast.setValue(raw); return true }
        return false
    }

    // We read the stripped app data, but the cache a path response replays and the re-broadcast
    // carry the signed bytes as heard, extension included.
    #expect(store.state.learned[c.destinationHash]?.appData == Data(hexString: f.msgpack)!)
    #expect(store.state.announceCache[c.destinationHash]?.payload == c.payloadBytes)
    let rb = try #require(rebroadcast.value.flatMap { Packet(raw: $0) })
    #expect(rb.payload == c.payloadBytes)
    #expect(Announce.parse(payload: rb.payload, destinationHash: c.destinationHash,
                           contextFlagSet: false)?.linkCost == 3.25)
    await store.skipReceivedActions()
}
