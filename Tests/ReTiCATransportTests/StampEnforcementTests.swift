import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// RNS 1.6.0 network stamp enforcement (`[stamps] enforce_stamps`), off by default. With it on, an
// announce below `destination_cost` is neither learned nor relayed (Identity.py:883-889,
// Transport.py:2046-2049), a path request without a stamp meeting `pr_cost` is dropped
// (Transport.py:2128-2129), and a link request whose key falls short of the owner's link cost is
// ignored (Link.py:195).
//
// Every stamped input is genuine RNS 1.6.0 output:
//   * announces: Vectors/stamped_announce_packet_fixtures.json (stamped) and transport_fixtures.json
//     (an ordinary, unstamped announce);
//   * path requests: Vectors/path_request_fixtures.json;
//   * link requests: Vectors/link_request_stamp_fixtures.json, two LINKREQUESTs from RNS.Link that
//     the reference's own `Link.validate_request` accepts and refuses with enforcement on.

/// Everything the store emits that the tests count, recorded in a wrapping reducer: a `receive`
/// predicate cannot count what an earlier `send` skipped.
private final class Recorder: Sendable {
    let transmits = LockIsolated<[(InterfaceID, Data)]>([])
    let linkRequests = LockIsolated<[Data]>([])
    let pathsLearned = LockIsolated<[Data]>([])

    func transmitted(to destination: Data) -> [Packet] {
        transmits.value.compactMap { Packet(raw: $0.1) }.filter { $0.destinationHash == destination }
    }
    func pathResponses(for destination: Data) -> [Packet] {
        transmitted(to: destination).filter { $0.packetType == .announce && $0.context == .pathResponse }
    }
    /// Path requests transmitted for `destination` (forwarded by a relay).
    func pathRequests(for destination: Data) -> [Packet] {
        transmitted(to: Transport.pathRequestDestinationHash).filter { $0.payload.prefix(16) == destination }
    }
}

@MainActor
private func makeStore(enforce: Bool, configure: (inout Transport.State) -> Void = { _ in },
                       recorder: Recorder) -> TestStore<Transport.State, Transport.Action> {
    var initial = Transport.State()
    initial.enforceStamps = enforce
    configure(&initial)
    let store = TestStore(initialState: initial) {
        CombineReducers {
            Reduce<Transport.State, Transport.Action> { _, action in
                switch action {
                case let .delegate(.transmit(id, raw)): recorder.transmits.withValue { $0.append((id, raw)) }
                case let .delegate(.linkRequest(hash, _, _)): recorder.linkRequests.withValue { $0.append(hash) }
                case let .delegate(.pathLearned(hash, _)): recorder.pathsLearned.withValue { $0.append(hash) }
                default: break
                }
                return .none
            }
            Transport()
        }
    } withDependencies: {
        $0.continuousClock = ImmediateClock()
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1000))
        $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
    store.exhaustivity = .off
    return store
}

/// A relay with two interfaces, so a learned announce is re-broadcast on the other one.
@MainActor
private func makeRelay(_ store: TestStore<Transport.State, Transport.Action>) async {
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setTransportIdentity(Identity()))
    await store.send(.setRecursivePathRequests(true))
}

// MARK: Fixtures

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

/// A genuine RNS announce with no stamp extension at all.
private struct UnstampedAnnounce {
    let destinationHash: Data
    let raw: Data
    static func load() throws -> UnstampedAnnounce {
        let f = try TransportVectorFixtures.load()
        return UnstampedAnnounce(destinationHash: Data(hexString: f.announceDestHash)!,
                                 raw: Data(hexString: f.announcePacket)!)
    }
}

private struct PathRequestFixture: Decodable {
    let identity_private_key: String
    let app_name: String
    let aspects: [String]
    let destination_hash: String
    let tag: String
    let stamped_raw: String
    let unstamped_raw: String

    var destinationHash: Data { Data(hexString: destination_hash)! }
    var requestTag: Data { Data(hexString: tag)! }
    var stampedRaw: Data { Data(hexString: stamped_raw)! }
    var unstampedRaw: Data { Data(hexString: unstamped_raw)! }

    static func load() throws -> PathRequestFixture {
        let url = try #require(Bundle.module.url(forResource: "path_request_fixtures", withExtension: "json"))
        return try JSONDecoder().decode(PathRequestFixture.self, from: Data(contentsOf: url))
    }
    func destination() throws -> Destination {
        let identity = try #require(Identity(privateKey: Data(hexString: identity_private_key)!))
        let dest = try #require(Destination(kind: .single, direction: .in, appName: app_name, aspects: aspects,
                                            identity: identity))
        try #require(dest.hash == destinationHash)
        return dest
    }
}

private struct LinkRequestFixture: Decodable {
    let identity_private_key: String
    let app_name: String
    let aspects: [String]
    let destination_hash: String
    let lr_cost: Double
    let stamped_raw: String
    let stamped_value: Double
    let unstamped_raw: String
    let unstamped_value: Double

    var destinationHash: Data { Data(hexString: destination_hash)! }
    var stampedRaw: Data { Data(hexString: stamped_raw)! }
    var unstampedRaw: Data { Data(hexString: unstamped_raw)! }

    static func load() throws -> LinkRequestFixture {
        let url = try #require(Bundle.module.url(forResource: "link_request_stamp_fixtures", withExtension: "json"))
        return try JSONDecoder().decode(LinkRequestFixture.self, from: Data(contentsOf: url))
    }
    func destination() throws -> Destination {
        let identity = try #require(Identity(privateKey: Data(hexString: identity_private_key)!))
        let dest = try #require(Destination(kind: .single, direction: .in, appName: app_name, aspects: aspects,
                                            identity: identity))
        try #require(dest.hash == destinationHash)
        return dest
    }
}

/// A path request packet carrying `payload`.
private func pathRequest(_ payload: Data) -> Data {
    try! Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                payload: payload).packed()
}

// MARK: Tests

@Suite @MainActor struct StampEnforcementTests {
    @Test func theDefaultsAreReference160s() {
        let state = Transport.State()
        #expect(state.enforceStamps == false, "1.6.0 does not enforce by default")
        #expect(state.destinationCost == 23.5)
        #expect(state.pathRequestCost == 15.8)
    }

    @Test func withEnforcementAnUnstampedAnnounceIsNotLearnedOrRelayed() async throws {
        let unstamped = try UnstampedAnnounce.load()
        let stamped = try StampedAnnounce.load("stripped")
        try #require((stamped.stamp_value ?? 0) >= 23.5)
        let recorder = Recorder()
        let store = makeStore(enforce: true, recorder: recorder)
        await makeRelay(store)

        await store.send(.received(InterfaceID("i0"), unstamped.raw))
        // A stamp the reference accepts, through the same relay: learned and re-broadcast, so a
        // re-broadcast of the unstamped one would have shown up too.
        await store.send(.received(InterfaceID("i0"), stamped.raw()))
        await store.skipReceivedActions(strict: false)

        #expect(store.state.learned[unstamped.destinationHash] == nil, "not learned")
        #expect(store.state.knownDestinations[unstamped.destinationHash] == nil, "not remembered for recall")
        #expect(store.state.announceTable[unstamped.destinationHash] == nil, "not held for a re-broadcast")
        #expect(store.state.announceArrivals[InterfaceID("i0")]?.count == 1,
                "not counted by ingress control: the reference returns before received_announce")
        #expect(recorder.transmitted(to: unstamped.destinationHash).isEmpty, "not relayed")
        #expect(!recorder.pathsLearned.value.contains(unstamped.destinationHash))

        #expect(store.state.learned[stamped.destinationHash] != nil, "a stamped announce is still learned")
        #expect(!recorder.transmitted(to: stamped.destinationHash).isEmpty, "and relayed")
    }

    /// Enforcing checks the stamp first, but the signature is still checked after it: the stamp is over
    /// wire bytes the signature has not vouched for yet.
    @Test func withEnforcementAStampedAnnounceStillNeedsItsSignature() async throws {
        let stamped = try StampedAnnounce.load("stripped")
        var payload = [UInt8](Data(hexString: stamped.payload)!)
        let signatureStart = 64 + 10 + 10                     // key, name hash, random hash; no ratchet
        payload[signatureStart + 5] ^= 0x01
        let forged = try Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                                destinationType: .single, context: .none, contextFlag: false, hops: 1,
                                destinationHash: stamped.destinationHash, transportId: nil,
                                payload: Data(payload)).packed()
        let store = makeStore(enforce: true, recorder: Recorder())
        await store.send(.received(InterfaceID("i0"), forged))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.learned[stamped.destinationHash] == nil)
        #expect(store.state.knownDestinations[stamped.destinationHash] == nil)
        // The same bytes with the signature intact are learned.
        await store.send(.received(InterfaceID("i0"), stamped.raw()))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.learned[stamped.destinationHash] != nil)
    }

    @Test func withEnforcementALowValueStampIsNotLearned() async throws {
        let low = try StampedAnnounce.load("below_cost")          // value 9.09
        let high = try StampedAnnounce.load("stripped")           // value 26.31
        let recorder = Recorder()
        let store = makeStore(enforce: true, recorder: recorder)
        await makeRelay(store)
        await store.send(.received(InterfaceID("i0"), low.raw()))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.learned[low.destinationHash] == nil)
        #expect(store.state.knownDestinations[low.destinationHash] == nil)
        #expect(recorder.transmitted(to: low.destinationHash).isEmpty)

        // The cost is `destinationCost`, not the 23.5 default: above the high stamp's value, it is
        // refused too ...
        let strict = Recorder()
        let strictStore = makeStore(enforce: true, configure: { $0.destinationCost = 27 }, recorder: strict)
        await strictStore.send(.received(InterfaceID("i0"), high.raw()))
        await strictStore.skipReceivedActions(strict: false)
        #expect(strictStore.state.learned[high.destinationHash] == nil, "26.31 is below a cost of 27")

        // ... and below the low stamp's value, the low one is learned, its link cost read.
        let lenient = Recorder()
        let lenientStore = makeStore(enforce: true, configure: { $0.destinationCost = 9 }, recorder: lenient)
        await lenientStore.send(.received(InterfaceID("i0"), low.raw()))
        await lenientStore.skipReceivedActions(strict: false)
        #expect(lenientStore.state.learned[low.destinationHash] != nil, "9.09 meets a cost of 9")
        #expect(lenientStore.state.knownDestinations[low.destinationHash]?.linkCost != nil)
    }

    @Test func withEnforcementAnUnstampedPathRequestIsIgnored() async throws {
        let f = try PathRequestFixture.load()
        let dest = try f.destination()

        // Owned destination: the unstamped request, a request carrying the lenient mark of a stamping
        // relay (0xC1 0xFF, 14 zero bytes), and a legacy 32-byte request all go unanswered.
        let recorder = Recorder()
        let store = makeStore(enforce: true, recorder: recorder)
        await store.send(.registerLocalDestination(dest))
        await store.send(.received(InterfaceID("in"), f.unstampedRaw))
        let lenient = f.destinationHash + Data(repeating: 1, count: 16) + Data(repeating: 2, count: 16)
            + Transport.lenientPathRequestExtension
        await store.send(.received(InterfaceID("in"), pathRequest(lenient)))
        await store.send(.received(InterfaceID("in"), pathRequest(f.destinationHash + Data(repeating: 3, count: 16))))
        await store.skipReceivedActions(strict: false)
        #expect(recorder.pathResponses(for: dest.hash).isEmpty)

        // The genuine stamped request is answered.
        let stamped = Recorder()
        let stampedStore = makeStore(enforce: true, recorder: stamped)
        await stampedStore.send(.registerLocalDestination(dest))
        await stampedStore.send(.received(InterfaceID("in"), f.stampedRaw))
        await stampedStore.skipReceivedActions(strict: false)
        #expect(stamped.pathResponses(for: dest.hash).count == 1)

        // The cost is `pathRequestCost`: at 100 the same genuine stamp is refused.
        let costly = Recorder()
        let costlyStore = makeStore(enforce: true, configure: { $0.pathRequestCost = 100 }, recorder: costly)
        await costlyStore.send(.registerLocalDestination(dest))
        await costlyStore.send(.received(InterfaceID("in"), f.stampedRaw))
        await costlyStore.skipReceivedActions(strict: false)
        #expect(costly.pathResponses(for: dest.hash).isEmpty)

        // A relay searching onward forwards the stamped request and not the unstamped one.
        let relayUnstamped = Recorder()
        let relayStore = makeStore(enforce: true, recorder: relayUnstamped)
        await makeRelay(relayStore)
        await relayStore.send(.received(InterfaceID("i0"), f.unstampedRaw))
        await relayStore.skipReceivedActions(strict: false)
        #expect(relayUnstamped.pathRequests(for: f.destinationHash).isEmpty, "unstamped: not forwarded")
        #expect(relayStore.state.discoveryPathRequests[f.destinationHash] == nil)

        let relayStamped = Recorder()
        let relayStampedStore = makeStore(enforce: true, recorder: relayStamped)
        await makeRelay(relayStampedStore)
        await relayStampedStore.send(.received(InterfaceID("i0"), f.stampedRaw))
        await relayStampedStore.skipReceivedActions(strict: false)
        #expect(relayStamped.pathRequests(for: f.destinationHash).count == 1, "stamped: forwarded")
    }

    @Test func withEnforcementALinkRequestBelowTheCostIsNotAnswered() async throws {
        let f = try LinkRequestFixture.load()
        let dest = try f.destination()
        try #require(f.lr_cost == NetworkStamp.defaultLinkRequestCost)
        try #require(f.stamped_value >= f.lr_cost && f.unstamped_value < f.lr_cost)

        // No link cost registered: the destination's cost is LR_COST, 12.5, as reference's.
        let recorder = Recorder()
        let store = makeStore(enforce: true, recorder: recorder)
        await store.send(.registerLocalDestination(dest))
        await store.send(.received(InterfaceID("in"), f.unstampedRaw))
        await store.skipReceivedActions(strict: false)
        #expect(recorder.linkRequests.value.isEmpty, "never handed to the link plane, so never answered")
        await store.send(.received(InterfaceID("in"), f.stampedRaw))
        await store.skipReceivedActions(strict: false)
        #expect(recorder.linkRequests.value == [dest.hash], "the genuine stamped request is")

        // The 64-byte form (keys only, no MTU signalling): the stamp material is the destination hash and
        // bytes 32..<64 of the payload, so the first 64 bytes of the 67-byte fixture carry the same stamp.
        func keysOnly(_ raw: Data) throws -> Data {
            var packet = try #require(Packet(raw: raw))
            try #require(packet.payload.count == 67)
            packet.payload = Data(packet.payload.prefix(64))
            return try packet.packed()
        }
        let keysRecorder = Recorder()
        let keysStore = makeStore(enforce: true, recorder: keysRecorder)
        await keysStore.send(.registerLocalDestination(dest))
        await keysStore.send(.received(InterfaceID("in"), try keysOnly(f.unstampedRaw)))
        await keysStore.skipReceivedActions(strict: false)
        #expect(keysRecorder.linkRequests.value.isEmpty, "an unstamped 64-byte request is refused")
        await keysStore.send(.received(InterfaceID("in"), try keysOnly(f.stampedRaw)))
        await keysStore.skipReceivedActions(strict: false)
        #expect(keysRecorder.linkRequests.value == [dest.hash], "a stamped 64-byte request is accepted")

        // The cost is the destination's own: above the stamp's value (13.375), it is refused too.
        let strict = Recorder()
        let strictStore = makeStore(enforce: true, recorder: strict)
        await strictStore.send(.registerLocalDestination(dest, linkCost: 14))
        await strictStore.send(.received(InterfaceID("in"), f.stampedRaw))
        await strictStore.skipReceivedActions(strict: false)
        #expect(strict.linkRequests.value.isEmpty, "13.375 is below a link cost of 14")

        // A truncated request cannot carry a stamp, and must not trap.
        let short = try Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                               destinationType: .single, context: .none, contextFlag: false, hops: 0,
                               destinationHash: dest.hash, transportId: nil,
                               payload: Data(repeating: 0, count: 40)).packed()
        await store.send(.received(InterfaceID("in"), short))
        await store.skipReceivedActions(strict: false)
        #expect(recorder.linkRequests.value == [dest.hash])
    }

    // MARK: Per-interface costs (reference Interface.py:350-358, Identity.py:794, Transport.py:2103)

    /// An announce is checked against the cost of the interface it ARRIVED on: an override there wins
    /// over `destinationCost`, in both directions, and an interface without one uses `destinationCost`.
    @Test func anAnnounceIsCheckedAgainstTheReceivingInterfacesDestinationCost() async throws {
        let low = try StampedAnnounce.load("below_cost")          // value 9.09
        let high = try StampedAnnounce.load("stripped")           // value 26.31
        func learned(_ announce: StampedAnnounce, on id: String, cost: Double?) async -> Bool {
            let store = makeStore(enforce: true, recorder: Recorder())   // destinationCost 23.5
            await store.send(.interfaceConnected(InterfaceID("lo"),
                                                 InterfaceProfile(name: "lo", bitrate: 62_500, destinationCost: cost)))
            await store.send(.interfaceConnected(InterfaceID("plain")))
            await store.send(.received(InterfaceID(id), announce.raw()))
            await store.skipReceivedActions(strict: false)
            return store.state.learned[announce.destinationHash] != nil
        }
        #expect(await learned(low, on: "lo", cost: 9), "9.09 meets the interface's 9")
        #expect(!(await learned(low, on: "plain", cost: 9)), "but not the 23.5 of an interface without one")
        #expect(!(await learned(high, on: "lo", cost: 27)), "26.31 is below the interface's 27")
        #expect(await learned(high, on: "plain", cost: 27), "and meets 23.5 elsewhere")
        #expect(await learned(high, on: "lo", cost: nil), "nil is the Transport-wide cost")
        #expect(!(await learned(low, on: "lo", cost: nil)))
    }

    /// Unenforced, the receiving interface's cost still decides whether a stamp's link cost is believed.
    @Test func unenforcedTheReceivingInterfacesCostDecidesTheLinkCost() async throws {
        let low = try StampedAnnounce.load("below_cost")          // value 9.09
        let store = makeStore(enforce: false, recorder: Recorder())
        await store.send(.interfaceConnected(InterfaceID("lo"),
                                             InterfaceProfile(name: "lo", bitrate: 62_500, destinationCost: 9)))
        await store.send(.received(InterfaceID("lo"), low.raw()))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.knownDestinations[low.destinationHash]?.linkCost != nil)
    }

    /// A per-interface cost of 0 accepts any stamp, but, enforcing, an announce with NO stamp is still
    /// refused: reference returns "no_stamp" before looking at the cost (Identity.py:883-886).
    @Test func aZeroInterfaceCostAcceptsAnyStampButNotNone() async throws {
        let unstamped = try UnstampedAnnounce.load()
        let low = try StampedAnnounce.load("below_cost")
        let store = makeStore(enforce: true, configure: { $0.destinationCost = 50 }, recorder: Recorder())
        await store.send(.interfaceConnected(InterfaceID("free"),
                                             InterfaceProfile(name: "free", bitrate: 62_500, destinationCost: 0)))
        await store.send(.received(InterfaceID("free"), low.raw()))
        await store.send(.received(InterfaceID("free"), unstamped.raw))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.learned[low.destinationHash] != nil, "9.09 meets 0, where the global 50 would refuse it")
        #expect(store.state.learned[unstamped.destinationHash] == nil, "no stamp is refused at any cost")
    }

    /// A path request is checked against the cost of the interface it arrived on.
    @Test func aPathRequestIsCheckedAgainstTheReceivingInterfacesCost() async throws {
        let f = try PathRequestFixture.load()
        let dest = try f.destination()
        func answered(on id: String, cost: Double?) async -> Bool {
            let recorder = Recorder()
            let store = makeStore(enforce: true, configure: { $0.pathRequestCost = 100 }, recorder: recorder)
            await store.send(.interfaceConnected(InterfaceID("cheap"),
                                                 InterfaceProfile(name: "cheap", bitrate: 62_500, pathRequestCost: cost)))
            await store.send(.interfaceConnected(InterfaceID("plain")))
            await store.send(.registerLocalDestination(dest))
            await store.send(.received(InterfaceID(id), f.stampedRaw))
            await store.skipReceivedActions(strict: false)
            return !recorder.pathResponses(for: dest.hash).isEmpty
        }
        #expect(await answered(on: "cheap", cost: NetworkStamp.defaultPathRequestCost),
                "the genuine stamp meets the interface's 15.8")
        #expect(!(await answered(on: "plain", cost: NetworkStamp.defaultPathRequestCost)),
                "but not the global 100 on an interface without one")
        #expect(!(await answered(on: "cheap", cost: nil)), "nil is the Transport-wide cost")

        // Enforcing, an unstamped request is refused even at an interface cost of 0, as reference
        // finds no stamp to validate (Transport.py:2099-2105).
        let recorder = Recorder()
        let store = makeStore(enforce: true, recorder: recorder)
        await store.send(.interfaceConnected(InterfaceID("free"),
                                             InterfaceProfile(name: "free", bitrate: 62_500, pathRequestCost: 0)))
        await store.send(.registerLocalDestination(dest))
        await store.send(.received(InterfaceID("free"), f.unstampedRaw))
        await store.skipReceivedActions(strict: false)
        #expect(recorder.pathResponses(for: dest.hash).isEmpty)
    }

    /// Clamped to 0...STAMP_COST_CAP as reference's config parser does (Reticulum.py:963-971), at
    /// construction and when set.
    @Test func interfaceCostsAreClampedLikeReferenceConfig() {
        var profile = InterfaceProfile(name: "x", bitrate: 62_500, destinationCost: 1000, pathRequestCost: -3)
        #expect(profile.destinationCost == 100)
        #expect(profile.pathRequestCost == 0)
        profile.destinationCost = .nan
        profile.pathRequestCost = 250
        #expect(profile.destinationCost == 0)
        #expect(profile.pathRequestCost == 100)
        profile.destinationCost = 23.5
        profile.pathRequestCost = nil
        #expect(profile.destinationCost == 23.5)
        #expect(profile.pathRequestCost == nil)
        #expect(InterfaceProfile.tcp.destinationCost == nil && InterfaceProfile.tcp.pathRequestCost == nil)
    }

    @Test func withoutEnforcementAllOfThoseStillWork() async throws {
        let unstamped = try UnstampedAnnounce.load()
        let low = try StampedAnnounce.load("below_cost")
        let pr = try PathRequestFixture.load()
        let lr = try LinkRequestFixture.load()
        let prDest = try pr.destination()
        let lrDest = try lr.destination()

        let recorder = Recorder()
        let store = makeStore(enforce: false, recorder: recorder)
        await makeRelay(store)
        await store.send(.registerLocalDestination(prDest))
        await store.send(.registerLocalDestination(lrDest))

        await store.send(.received(InterfaceID("i0"), unstamped.raw))
        await store.send(.received(InterfaceID("i0"), low.raw()))
        await store.send(.received(InterfaceID("i0"), pr.unstampedRaw))
        await store.send(.received(InterfaceID("i0"), lr.unstampedRaw))
        await store.skipReceivedActions(strict: false)

        #expect(store.state.learned[unstamped.destinationHash] != nil, "an unstamped announce is learned")
        #expect(!recorder.transmitted(to: unstamped.destinationHash).isEmpty, "and relayed")
        #expect(store.state.learned[low.destinationHash] != nil, "a low-value stamp too")
        #expect(store.state.knownDestinations[low.destinationHash]?.linkCost == nil,
                "though its link cost is not believed")
        #expect(!recorder.transmitted(to: low.destinationHash).isEmpty)
        #expect(recorder.pathResponses(for: prDest.hash).count == 1, "an unstamped path request is answered")
        #expect(recorder.linkRequests.value == [lrDest.hash], "an unstamped link request goes to the link plane")

        // And a relay forwards an unstamped path request for a destination it does not know.
        let relay = Recorder()
        let relayStore = makeStore(enforce: false, recorder: relay)
        await makeRelay(relayStore)
        await relayStore.send(.received(InterfaceID("i0"), pr.unstampedRaw))
        await relayStore.skipReceivedActions(strict: false)
        #expect(relay.pathRequests(for: pr.destinationHash).count == 1)
    }
}
