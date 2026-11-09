import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// RNS 1.6.0 destination stamps on our own announces (Destination.py:266-379, Transport.py:1441-1495).
// With `stamp_destinations` on, an announce carries the 18-byte extension `0xC1, flags, stamp, cost
// fraction byte, cost integer byte` (the cost bytes reversed, Destination.py:353-354), the stamp mined
// over `destinationHash + publicKey + nameHash`, and the signature covers it. The stamp is mined once
// per destination and kept; announces and path responses wait for it.

private let i0 = InterfaceID("i0")
private let i1 = InterfaceID("i1")

/// Every transmit, finished search and reported stamp, counted in a wrapping reducer: a `receive`
/// predicate cannot count what an earlier `send` skipped.
private final class Recorder: Sendable {
    let transmits = LockIsolated<[(InterfaceID, Data)]>([])
    let searchesEnded = LockIsolated(0)
    let generated = LockIsolated<[(Data, Data, Double)]>([])

    var announces: [(InterfaceID, Packet)] {
        transmits.value.compactMap { id, raw in
            guard let p = Packet(raw: raw), p.packetType == .announce else { return nil }
            return (id, p)
        }
    }
}

/// A stamp search that never finds anything: it returns only when cancelled, so a test can hold a
/// search open for as long as it likes, with no race against a real search.
private let neverFinds = DestinationStampGenerator { _, _ in
    try? await Task.sleep(for: .seconds(86_400))
    return nil
}

@MainActor
private func makeStore(_ initial: Transport.State = Transport.State(),
                       recorder: Recorder = Recorder(),
                       generator: DestinationStampGenerator? = nil) -> TestStore<Transport.State, Transport.Action> {
    let store = TestStore(initialState: initial) {
        CombineReducers {
            Reduce<Transport.State, Transport.Action> { _, action in
                if case let .delegate(.transmit(id, raw)) = action { recorder.transmits.withValue { $0.append((id, raw)) } }
                if case .destinationStampSearchEnded = action { recorder.searchesEnded.withValue { $0 += 1 } }
                if case let .delegate(.destinationStampGenerated(h, s, v)) = action {
                    recorder.generated.withValue { $0.append((h, s, v)) }
                }
                return .none
            }
            Transport()
        }
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1000))
        if let generator { $0.destinationStampGenerator = generator }
    }
    store.exhaustivity = .off
    return store
}

private func stamping(value: Double) -> Transport.State {
    var state = Transport.State()
    state.stampDestinations = true
    state.destinationValue = value
    return state
}

private func newDestination(_ aspect: String = "dstamp") -> Destination {
    Destination(kind: .single, direction: .in, appName: "retica", aspects: [aspect], identity: Identity())!
}

private func material(_ dest: Destination) -> Data {
    dest.hash + dest.identity!.publicKey + dest.nameHash
}

/// A stamp valid at `value` for `dest`, mined here.
private func validStamp(_ dest: Destination, value: Double) async throws -> Data {
    try #require(await NetworkStamp.generate(material: material(dest), cost: value)).stamp
}

/// A 14-byte stamp whose value is below `value` for `dest`.
private func weakStamp(_ dest: Destination, below value: Double) -> Data {
    while true {
        let candidate = SecureRandom.bytes(14)
        if !NetworkStamp.isValid(stamp: candidate, cost: value, material: material(dest)) { return candidate }
    }
}

/// The last 18 bytes of an announce payload.
private func extensionBytes(_ packet: Packet) -> [UInt8] { [UInt8](packet.payload.suffix(18)) }

private func pathRequest(for dest: Data, tag: UInt8) -> Data {
    try! Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                payload: dest + Data(repeating: 0x55, count: 16) + Data(repeating: tag, count: 16)).packed()
}

/// Waits for the next announce transmit (a real search at a low value takes well under a second).
@MainActor
private func nextAnnounce(_ store: TestStore<Transport.State, Transport.Action>) async {
    await store.receive({ action in
        guard case let .delegate(.transmit(_, raw)) = action else { return false }
        return Packet(raw: raw)?.packetType == .announce
    }, timeout: .seconds(20))
}

/// Genuine RNS 1.6.0 `Destination._announce` output: see Vectors/generate_destination_stamp_fixtures.py.
private struct Fixtures: Decodable {
    struct Case: Decodable {
        let name: String
        let identity_private_key: String
        let app_name: String
        let aspects: [String]
        let destination_hash: String
        let app_data: String?
        let link_cost: Double?
        let announced_link_cost: Double
        let stamp: String
        let payload: String
        let raw: String

        func destination() throws -> Destination {
            let identity = try #require(Identity(privateKey: Data(hexString: identity_private_key)!))
            let dest = try #require(Destination(kind: .single, direction: .in, appName: app_name, aspects: aspects,
                                                identity: identity))
            try #require(dest.hash == Data(hexString: destination_hash)!)
            return dest
        }
    }
    let destination_value: Double
    let cases: [Case]

    static func load() throws -> Fixtures {
        let url = try #require(Bundle.module.url(forResource: "destination_stamp_fixtures", withExtension: "json"))
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }
}

@Suite @MainActor struct DestinationStampTests {
    @Test func anAnnounceCarriesTheStampExtensionWhenEnabled() async throws {
        #expect(Transport.State().stampDestinations == false, "1.6.0 does not stamp by default")
        #expect(Transport.State().destinationValue == 25.0)
        let appData = Data([0x93, 0xC0, 0xC0, 0x91, 0x00])

        // Off (the default): the app data goes out exactly as given, at once, with no search.
        let plain = newDestination("plain")
        let off = Recorder()
        let offStore = makeStore(recorder: off)
        await offStore.send(.interfaceConnected(i0))
        await offStore.send(.registerLocalDestination(plain, linkCost: 3.25))
        await offStore.send(.announce(destinationHash: plain.hash, appData: appData))
        let unstamped = try #require(off.announces.first?.1)
        #expect(Announce.parse(payload: unstamped.payload, destinationHash: plain.hash,
                               contextFlagSet: false)?.appData == appData)
        #expect(unstamped.payload.count == 148 + appData.count, "no extension")
        #expect(offStore.state.stampingDestinations.isEmpty)

        // On.
        let dest = newDestination()
        let recorder = Recorder()
        let store = makeStore(stamping(value: 8), recorder: recorder)
        await store.send(.interfaceConnected(i0))
        await store.send(.registerLocalDestination(dest, linkCost: 3.25))
        await store.send(.announce(destinationHash: dest.hash, appData: appData))
        await nextAnnounce(store)
        let packet = try #require(recorder.announces.first?.1)
        let parsed = try #require(Announce.parse(payload: packet.payload, destinationHash: dest.hash,
                                                 contextFlagSet: packet.contextFlag, requiredStampValue: 8))
        #expect(parsed.appData == appData, "the extension follows the app data and is stripped on parse")
        let stamp = try #require(parsed.stamp)
        #expect((parsed.stampValue ?? 0) >= 8)
        #expect(parsed.linkCost == 3.25)
        #expect(NetworkStamp.isValid(stamp: stamp, cost: 8, material: material(dest)))
        let ext = extensionBytes(packet)
        #expect(ext[0] == 0xC1 && ext[1] == 0x00)
        #expect(Data(ext[2..<16]) == stamp)
        #expect(ext[16] == 0x40 && ext[17] == 0x03, "3.25 = 0x0340, written fraction byte first")
        #expect(packet.payload.count == 148 + appData.count + 18)
    }

    /// Byte layout against genuine `Destination._announce` output. Signatures differ (ours are
    /// hedged), so the payload length and the 18 extension bytes are what is compared.
    @Test func ourExtensionMatchesGenuineReferenceBytes() async throws {
        let fixtures = try Fixtures.load()
        for c in fixtures.cases {
            let dest = try c.destination()
            let referencePayload = Data(hexString: c.payload)!
            let appData = c.app_data.flatMap { Data(hexString: $0) }
            // Our parser reads the reference's extension.
            let reference = try #require(Packet(raw: Data(hexString: c.raw)!))
            let parsedReference = try #require(Announce.parse(payload: reference.payload, destinationHash: dest.hash,
                                                              contextFlagSet: reference.contextFlag,
                                                              requiredStampValue: fixtures.destination_value))
            #expect(parsedReference.linkCost == c.announced_link_cost, "\(c.name)")
            #expect(parsedReference.appData == appData, "\(c.name)")

            let recorder = Recorder()
            let store = makeStore(stamping(value: fixtures.destination_value), recorder: recorder)
            await store.send(.interfaceConnected(i0))
            await store.send(.registerLocalDestination(dest, linkCost: c.link_cost))
            await store.send(.rehydrateDestinationStamp(destinationHash: dest.hash, stamp: Data(hexString: c.stamp)!))
            await store.send(.announce(destinationHash: dest.hash, appData: appData))
            let ours = try #require(recorder.announces.first?.1, "\(c.name)")
            #expect(ours.payload.count == referencePayload.count, "\(c.name)")
            #expect(Data(ours.payload.suffix(18)) == Data(referencePayload.suffix(18)), "\(c.name)")
            #expect(Data(ours.payload.prefix(74)) == Data(referencePayload.prefix(74)),
                    "\(c.name): same public key and name hash")
            if let appData {
                #expect(Data(ours.payload.dropFirst(148).prefix(appData.count)) == appData, "\(c.name)")
            }
        }
    }

    @Test func linkCostAndValueAreClampedAsReferenceDoes() async throws {
        #expect(Transport.clampedDestinationValue(150) == 100)
        #expect(Transport.clampedDestinationValue(-3) == 0)
        #expect(Transport.clampedDestinationValue(.nan) == 0)
        #expect(Transport.clampedDestinationValue(.infinity) == 100)
        #expect(Transport.clampedDestinationValue(12.5) == 12.5)
        // Value 0: any 14 bytes is a valid stamp, so these run with no search.
        let cases: [(Double?, Double)] = [(nil, 12.5), (1000, 40), (-5, 0), (.nan, 0), (.infinity, 40), (7.75, 7.75)]
        for (given, announced) in cases {
            let dest = newDestination()
            let recorder = Recorder()
            let store = makeStore(stamping(value: 0), recorder: recorder)
            await store.send(.interfaceConnected(i0))
            await store.send(.registerLocalDestination(dest, linkCost: given))
            await store.send(.rehydrateDestinationStamp(destinationHash: dest.hash, stamp: Data(repeating: 1, count: 14)))
            await store.send(.announce(destinationHash: dest.hash, appData: nil))
            let packet = try #require(recorder.announces.first?.1, "\(String(describing: given))")
            let parsed = Announce.parse(payload: packet.payload, destinationHash: dest.hash,
                                        contextFlagSet: false, requiredStampValue: 0)
            #expect(parsed?.linkCost == announced, "\(String(describing: given))")
        }
    }

    /// The search is held open (`neverFinds`), so "a search started and nothing went out" is checked
    /// with no race; its result is then delivered as the search's own report.
    @Test func aLoadedStampBelowTheValueIsMinedAgain() async throws {
        let dest = newDestination()
        let weak = weakStamp(dest, below: 16)
        let mined = try await validStamp(dest, value: 16)
        let recorder = Recorder()
        let store = makeStore(stamping(value: 16), recorder: recorder, generator: neverFinds)
        await store.send(.interfaceConnected(i0))
        await store.send(.registerLocalDestination(dest))
        // The wrong length is discarded at once.
        await store.send(.rehydrateDestinationStamp(destinationHash: dest.hash, stamp: Data(repeating: 1, count: 13)))
        #expect(store.state.destinationStamps[dest.hash] == nil)
        await store.send(.rehydrateDestinationStamp(destinationHash: dest.hash, stamp: Data(repeating: 1, count: 15)))
        #expect(store.state.destinationStamps[dest.hash] == nil)
        await store.send(.rehydrateDestinationStamp(destinationHash: dest.hash, stamp: weak))
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        #expect(recorder.announces.isEmpty, "a stamp below the value is not used")
        #expect(store.state.stampingDestinations == [dest.hash], "a new search replaces it")
        await store.send(.destinationStampSearchEnded(destinationHash: dest.hash, stamp: mined,
                                                      value: NetworkStamp.value(stamp: mined, material: material(dest))))
        let packet = try #require(recorder.announces.first?.1)
        let stamp = Data(packet.payload.suffix(18).dropFirst(2).prefix(14))
        #expect(stamp == mined)
        #expect(stamp != weak)
        #expect(store.state.destinationStamps[dest.hash] == mined)
        #expect(store.state.stampingDestinations.isEmpty)
        await store.skipReceivedActions(strict: false)
        store.exhaustivity = .on
        await store.finish()
    }

    @Test func theStampIsMinedOncePerDestination() async throws {
        let dest = newDestination()
        let recorder = Recorder()
        let store = makeStore(stamping(value: 8), recorder: recorder)
        await store.send(.interfaceConnected(i0))
        await store.send(.registerLocalDestination(dest))
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        await nextAnnounce(store)
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        #expect(recorder.announces.count == 2, "the second announce goes out at once")
        #expect(recorder.searchesEnded.value == 1)
        let stamps = recorder.announces.map { Data($0.1.payload.suffix(18).dropFirst(2).prefix(14)) }
        #expect(stamps[0] == stamps[1])
        await store.skipReceivedActions(strict: false)
        store.exhaustivity = .on
        await store.finish()
    }

    @Test func aStampIsReportedForTheHostToPersist() async throws {
        let dest = newDestination()
        let recorder = Recorder()
        let store = makeStore(stamping(value: 8), recorder: recorder)
        await store.send(.interfaceConnected(i0))
        await store.send(.registerLocalDestination(dest))
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        await nextAnnounce(store)
        let reported = try #require(recorder.generated.value.first)
        #expect(recorder.generated.value.count == 1)
        #expect(reported.0 == dest.hash)
        #expect(reported.1.count == 14)
        #expect(NetworkStamp.isValid(stamp: reported.1, cost: 8, material: material(dest)))
        #expect(reported.2 == NetworkStamp.value(stamp: reported.1, material: material(dest)))
        #expect(store.state.destinationStamps[dest.hash] == reported.1)
    }

    @Test func aRehydratedStampSkipsTheSearch() async throws {
        let dest = newDestination()
        let stamp = try await validStamp(dest, value: 8)
        let recorder = Recorder()
        let store = makeStore(stamping(value: 8), recorder: recorder)
        await store.send(.interfaceConnected(i0))
        await store.send(.registerLocalDestination(dest))
        await store.send(.rehydrateDestinationStamp(destinationHash: dest.hash, stamp: stamp))
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        let packet = try #require(recorder.announces.first?.1, "sent at once")
        #expect(Data(packet.payload.suffix(18).dropFirst(2).prefix(14)) == stamp)
        #expect(store.state.stampingDestinations.isEmpty)
        await store.skipReceivedActions(strict: false)
        store.exhaustivity = .on
        await store.finish()
        #expect(recorder.searchesEnded.value == 0)
        #expect(recorder.generated.value.isEmpty, "a rehydrated stamp is not reported back")
    }

    /// The host's database read can land after the first announce started a search. The stamp it
    /// brings ends that search and releases what waited for it.
    ///
    /// The store's own search is held open (`neverFinds`), so it is certainly still running when the
    /// stamp (mined beforehand, here) arrives.
    @Test func aStampRehydratedDuringTheSearchEndsIt() async throws {
        let dest = newDestination()
        let stamp = try await validStamp(dest, value: 12)
        let weak = weakStamp(dest, below: 12)
        let recorder = Recorder()
        let store = makeStore(stamping(value: 12), recorder: recorder, generator: neverFinds)
        await store.send(.interfaceConnected(i0))
        await store.send(.registerLocalDestination(dest))
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        #expect(store.state.stampingDestinations == [dest.hash])
        // A stamp below the value changes nothing.
        await store.send(.rehydrateDestinationStamp(destinationHash: dest.hash, stamp: weak))
        #expect(store.state.stampingDestinations == [dest.hash])
        #expect(recorder.announces.isEmpty)
        // One that meets it ends the search and releases the announce.
        await store.send(.rehydrateDestinationStamp(destinationHash: dest.hash, stamp: stamp))
        #expect(store.state.stampingDestinations.isEmpty)
        #expect(store.state.pendingStampedAnnounces.isEmpty)
        let packet = try #require(recorder.announces.first?.1)
        #expect(Data(packet.payload.suffix(18).dropFirst(2).prefix(14)) == stamp)
        await store.skipReceivedActions(strict: false)
        store.exhaustivity = .on
        await store.finish()     // the cancelled search does not outlive this
        #expect(recorder.searchesEnded.value == 0)
    }

    @Test func announcesWaitForTheStampAndAllGoOutWhenItIsReady() async throws {
        let dest = newDestination()
        let recorder = Recorder()
        let store = makeStore(stamping(value: 100), recorder: recorder)   // the real search cannot finish
        await store.send(.interfaceConnected(i0))
        await store.send(.interfaceConnected(i1))
        await store.send(.registerLocalDestination(dest))
        await store.send(.announce(destinationHash: dest.hash, appData: Data([0xA1])))
        await store.send(.announce(destinationHash: dest.hash, appData: nil, interface: i1))
        #expect(recorder.transmits.value.isEmpty, "nothing goes out without the stamp")
        #expect(store.state.stampingDestinations == [dest.hash])
        #expect(store.state.pendingStampedAnnounces.count == 2)

        // The search's report, as its effect sends it (a value-100 stamp cannot be mined here).
        let stamp = Data(repeating: 7, count: 14)
        await store.send(.destinationStampSearchEnded(destinationHash: dest.hash, stamp: stamp, value: 100))
        let sent = recorder.announces
        #expect(sent.count == 3, "the broadcast on both interfaces, then the one on i1")
        #expect(sent.allSatisfy { Data($0.1.payload.suffix(18).dropFirst(2).prefix(14)) == stamp })
        let appData = sent.map { Data($0.1.payload.dropFirst(148).dropLast(18)) }
        #expect(appData.allSatisfy { $0 == Data([0xA1]) }, "the second falls back to the sticky app data")
        #expect(sent.last?.0 == i1)
        #expect(store.state.pendingStampedAnnounces.isEmpty)
        #expect(store.state.stampingDestinations.isEmpty)
        #expect(store.state.destinationStamps[dest.hash] == stamp)
        await store.skipReceivedActions(strict: false)
        store.exhaustivity = .on
        await store.finish()
    }

    /// A search takes minutes on a phone, and announces keep coming meanwhile (host calls, per-interface
    /// re-announces). Reference keeps one queued announce per destination, the newest
    /// (Transport.py:1456); here one per destination AND target, so a per-interface re-announce
    /// (Contract 4) is not lost. The burst when the stamp lands is at most interfaces + 1 per destination.
    @Test func repeatedAnnouncesDuringASearchCollapseToOnePerTarget() async throws {
        let dest = newDestination()
        let recorder = Recorder()
        let store = makeStore(stamping(value: 100), recorder: recorder, generator: neverFinds)
        await store.send(.interfaceConnected(i0))
        await store.send(.interfaceConnected(i1))
        await store.send(.registerLocalDestination(dest))
        for n in 0..<10 { await store.send(.announce(destinationHash: dest.hash, appData: Data([0xA0 + UInt8(n)]))) }
        for _ in 0..<10 { await store.send(.announce(destinationHash: dest.hash, appData: nil, interface: i1)) }
        await store.send(.announce(destinationHash: dest.hash, appData: Data([0xB4]), interface: i1))
        await store.send(.announce(destinationHash: dest.hash, appData: nil, interface: InterfaceID("gone")))
        #expect(store.state.pendingStampedAnnounces.count == 2, "one for every interface, one for i1")

        let stamp = Data(repeating: 7, count: 14)
        await store.send(.destinationStampSearchEnded(destinationHash: dest.hash, stamp: stamp, value: 100))
        let sent = recorder.announces
        try #require(sent.count == 3)
        let appData = sent.map { Data($0.1.payload.dropFirst(148).dropLast(18)) }
        #expect(Set(sent.prefix(2).map(\.0)) == [i0, i1])
        #expect(appData.prefix(2).allSatisfy { $0 == Data([0xA9]) }, "the newest app data is kept")
        #expect(sent[2].0 == i1 && appData[2] == Data([0xB4]))
        await store.skipReceivedActions(strict: false)
        store.exhaustivity = .on
        await store.finish()
    }

    @Test func oneDestinationsAnnouncesCannotCrowdOutAnothers() async throws {
        let delivery = newDestination("delivery")
        let propagation = newDestination("propagation")
        let recorder = Recorder()
        let store = makeStore(stamping(value: 100), recorder: recorder, generator: neverFinds)
        await store.send(.interfaceConnected(i0))
        await store.send(.registerLocalDestination(delivery))
        await store.send(.registerLocalDestination(propagation))
        for _ in 0..<40 {
            await store.send(.announce(destinationHash: delivery.hash, appData: nil))
            await store.send(.announce(destinationHash: delivery.hash, appData: nil, interface: i0))
        }
        await store.send(.announce(destinationHash: propagation.hash, appData: Data([0xC1, 0x0C])))
        #expect(store.state.pendingStampedAnnounces.filter { $0.destinationHash == propagation.hash }.count == 1)

        // One search at a time: delivery's runs first, then propagation's.
        let stamp = Data(repeating: 7, count: 14)
        #expect(store.state.stampingDestinations == [delivery.hash])
        await store.send(.destinationStampSearchEnded(destinationHash: delivery.hash, stamp: stamp, value: 100))
        #expect(store.state.stampingDestinations == [propagation.hash])
        let deliverySent = recorder.announces.count
        await store.send(.destinationStampSearchEnded(destinationHash: propagation.hash, stamp: stamp, value: 100))
        let sent = recorder.announces.dropFirst(deliverySent)
        #expect(sent.count == 1)
        #expect(sent.first?.1.destinationHash == propagation.hash)
        await store.send(.cancelDestinationStamps)
        await store.skipReceivedActions(strict: false)
        store.exhaustivity = .on
        await store.finish()
    }

    /// Past eight a destination's announces are dropped, newest first, as the full queue drops
    /// (reference WorkerQueues.put raises Full). Without the quota 40 interfaces would fill all 32 slots.
    @Test func oneDestinationOnManyInterfacesHoldsAtMostEightSlots() async throws {
        let busy = newDestination("busy")
        let quiet = newDestination("quiet")
        let store = makeStore(stamping(value: 100), generator: neverFinds)
        let ids = (0..<40).map { InterfaceID("many\($0)") }
        for id in ids { await store.send(.interfaceConnected(id)) }
        await store.send(.registerLocalDestination(busy))
        await store.send(.registerLocalDestination(quiet))
        for id in ids { await store.send(.announce(destinationHash: busy.hash, appData: nil, interface: id)) }
        let queued = store.state.pendingStampedAnnounces.filter { $0.destinationHash == busy.hash }
        #expect(queued.count == Transport.stampedQueuePerDestinationLimit)
        #expect(Transport.stampedQueuePerDestinationLimit == 8)
        let kept = queued.compactMap { item -> InterfaceID? in
            if case let .announce(_, interface) = item.kind { return interface }
            return nil
        }
        #expect(kept == Array(ids.prefix(8)), "the oldest eight stay, the newer ones are dropped")

        await store.send(.announce(destinationHash: quiet.hash, appData: nil))
        #expect(store.state.pendingStampedAnnounces.filter { $0.destinationHash == quiet.hash }.count == 1)

        // A replacement of a queued announce needs no new slot, so it still lands at the quota.
        await store.send(.announce(destinationHash: busy.hash, appData: Data([0xEE]), interface: ids[0]))
        let replaced = store.state.pendingStampedAnnounces.first {
            if case let .announce(_, interface) = $0.kind { return $0.destinationHash == busy.hash && interface == ids[0] }
            return false
        }
        #expect(replaced?.kind == .announce(appData: Data([0xEE]), interface: ids[0]))

        // Path responses are held to the same quota, apart from the announces.
        for tag in 1...12 { await store.send(.received(ids[0], pathRequest(for: busy.hash, tag: UInt8(tag)))) }
        #expect(store.state.pendingStampedAnnounces.filter { $0.destinationHash == busy.hash && $0.isPathResponse }.count
                == Transport.stampedQueuePerDestinationLimit)
        await store.send(.cancelDestinationStamps)
        store.exhaustivity = .on
        await store.finish()
    }

    /// Re-registering a destination (new app data, new composition) drops what waited for its stamp
    /// under the old registration, as deregistering does; only what follows is ever announced.
    @Test func reRegisteringDuringASearchDropsTheOldQueuedAnnounces() async throws {
        let dest = newDestination()
        let recorder = Recorder()
        let store = makeStore(stamping(value: 100), recorder: recorder, generator: neverFinds)
        await store.send(.interfaceConnected(i0))
        await store.send(.registerLocalDestination(dest))
        await store.send(.announce(destinationHash: dest.hash, appData: Data([0x01])))
        await store.send(.received(i0, pathRequest(for: dest.hash, tag: 1)))
        #expect(store.state.pendingStampedAnnounces.count == 2)

        await store.send(.registerLocalDestination(dest))
        #expect(store.state.pendingStampedAnnounces.isEmpty)
        await store.send(.announce(destinationHash: dest.hash, appData: Data([0x02])))

        let stamp = Data(repeating: 7, count: 14)
        await store.send(.destinationStampSearchEnded(destinationHash: dest.hash, stamp: stamp, value: 100))
        let sent = recorder.announces
        #expect(sent.count == 1)
        #expect(sent.map { Data($0.1.payload.dropFirst(148).dropLast(18)) } == [Data([0x02])])
        await store.skipReceivedActions(strict: false)
        store.exhaustivity = .on
        await store.finish()
    }

    @Test func aPathRequestDuringTheSearchIsAnsweredWhenTheStampIsReady() async throws {
        let dest = newDestination()
        let recorder = Recorder()
        let store = makeStore(stamping(value: 100), recorder: recorder)
        await store.send(.interfaceConnected(i0))
        await store.send(.interfaceConnected(InterfaceID("in")))
        await store.send(.registerLocalDestination(dest, linkCost: 3.25))
        await store.send(.announce(destinationHash: dest.hash, appData: Data([0xA1])))
        await store.send(.received(InterfaceID("in"), pathRequest(for: dest.hash, tag: 1)))
        #expect(recorder.transmits.value.isEmpty, "the path response waits for the stamp")
        #expect(store.state.stampingDestinations == [dest.hash], "one search for both")

        let stamp = Data(repeating: 7, count: 14)
        await store.send(.destinationStampSearchEnded(destinationHash: dest.hash, stamp: stamp, value: 100))
        let sent = recorder.announces
        try #require(sent.count == 3)
        // The path response first (reference queues it at a higher priority), on its own interface.
        #expect(sent[0].0 == InterfaceID("in"))
        #expect(sent[0].1.context == .pathResponse)
        #expect(sent[1...].allSatisfy { $0.1.context != .pathResponse })
        #expect(sent.allSatisfy { Data($0.1.payload.suffix(18).dropFirst(2).prefix(14)) == stamp })
        #expect(Data(sent[0].1.payload.dropFirst(148).dropLast(18)) == Data([0xA1]),
                "the response replays the app data the announce made sticky")
        #expect(extensionBytes(sent[0].1).suffix(2) == [0x40, 0x03])
        await store.skipReceivedActions(strict: false)
        store.exhaustivity = .on
        await store.finish()
    }

    @Test func withAStampAPathRequestIsAnsweredAtOnceWithTheExtension() async throws {
        let dest = newDestination()
        let stamp = try await validStamp(dest, value: 8)
        let recorder = Recorder()
        let store = makeStore(stamping(value: 8), recorder: recorder)
        await store.send(.interfaceConnected(InterfaceID("in")))
        await store.send(.registerLocalDestination(dest, linkCost: 3.25))
        await store.send(.rehydrateDestinationStamp(destinationHash: dest.hash, stamp: stamp))
        await store.send(.received(InterfaceID("in"), pathRequest(for: dest.hash, tag: 2)))
        let response = try #require(recorder.announces.first, "answered at once")
        #expect(response.0 == InterfaceID("in"))
        #expect(response.1.context == .pathResponse)
        let parsed = Announce.parse(payload: response.1.payload, destinationHash: dest.hash,
                                    contextFlagSet: false, requiredStampValue: 8)
        #expect(parsed?.stamp == stamp)
        #expect(parsed?.linkCost == 3.25)
        #expect(store.state.stampingDestinations.isEmpty)
        await store.skipReceivedActions(strict: false)
        store.exhaustivity = .on
        await store.finish()
    }

    /// A search that ends without a stamp (cancelled) drops what waited for it, as reference drops
    /// it; the next announce starts a new search.
    @Test func aCancelledSearchDropsWhatWaitedAndTheNextAnnounceSearchesAgain() async throws {
        let dest = newDestination()
        let recorder = Recorder()
        let store = makeStore(stamping(value: 100), recorder: recorder)
        await store.send(.interfaceConnected(i0))
        await store.send(.registerLocalDestination(dest))
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        await store.send(.received(i0, pathRequest(for: dest.hash, tag: 1)))
        #expect(store.state.pendingStampedAnnounces.count == 2)
        await store.send(.cancelDestinationStamps)
        #expect(store.state.stampingDestinations.isEmpty)
        #expect(store.state.pendingStampedAnnounces.isEmpty)
        store.exhaustivity = .on
        await store.finish()     // a search still running at 100 would outlive `finish`
        store.exhaustivity = .off
        #expect(recorder.transmits.value.isEmpty)

        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        #expect(store.state.stampingDestinations == [dest.hash])
        #expect(store.state.pendingStampedAnnounces.count == 1)
        await store.send(.deregisterLocalDestination(destinationHash: dest.hash))
        #expect(store.state.stampingDestinations.isEmpty, "deregistering stops its search")
        #expect(store.state.pendingStampedAnnounces.isEmpty)
        store.exhaustivity = .on
        await store.finish()
        #expect(recorder.transmits.value.isEmpty)
    }

    @Test func theWaitingQueuesAreBounded() async throws {
        let dest = newDestination()
        let store = makeStore(stamping(value: 100), generator: neverFinds)
        await store.send(.interfaceConnected(i0))
        await store.send(.registerLocalDestination(dest))
        // Forty destinations, one announce and one path request each: forty distinct keys against a
        // cap of 32 (a single destination is held to its own quota, see the next test).
        for n in 0..<40 {
            let other = newDestination("other\(n)")
            await store.send(.registerLocalDestination(other))
            await store.send(.announce(destinationHash: other.hash, appData: nil))
            await store.send(.received(i0, pathRequest(for: other.hash, tag: UInt8(n + 1))))
        }
        let pending = store.state.pendingStampedAnnounces
        #expect(pending.filter { !$0.isPathResponse }.count == Transport.stampedAnnounceQueueLimit)
        #expect(pending.filter { $0.isPathResponse }.count == Transport.stampedPathResponseQueueLimit)
        #expect(Transport.stampedAnnounceQueueLimit == 32 && Transport.stampedPathResponseQueueLimit == 32)
        await store.send(.cancelDestinationStamps)
        store.exhaustivity = .on
        await store.finish()
    }

    @Test func anOverlongNameStillFitsWithTheExtension() async throws {
        let appData = LXMFAnnounceData.pack(displayName: String(repeating: "N", count: 400), stampCost: 99)
        let dest = Destination(kind: .single, direction: .in, appName: "lxmf", aspects: ["delivery"],
                               identity: Identity())!
        var lengths: [Bool: Int] = [:]
        for on in [false, true] {
            let recorder = Recorder()
            let store = makeStore(on ? stamping(value: 0) : Transport.State(), recorder: recorder)
            await store.send(.interfaceConnected(i0))
            await store.send(.registerLocalDestination(dest, linkCost: 3.25))
            await store.send(.rehydrateDestinationStamp(destinationHash: dest.hash, stamp: Data(repeating: 1, count: 14)))
            await store.send(.announce(destinationHash: dest.hash, appData: appData))
            let raw = try #require(recorder.transmits.value.first?.1, "stamping \(on)")
            lengths[on] = raw.count
            let packet = try #require(Packet(raw: raw))
            let parsed = Announce.parse(payload: packet.payload, destinationHash: dest.hash,
                                        contextFlagSet: false, requiredStampValue: 0)
            #expect(parsed?.appData == appData, "stamping \(on): the same name either way")
            #expect(LXMFAnnounceData.parse(appData)?.displayName?.utf8.count == 299,
                    "the name budget with a cost (one-byte ceiling plus float64) is 315 - 16")
        }
        #expect(lengths[true] == Packet.mtu, "the budget is exact with the extension")
        #expect(lengths[false] == Packet.mtu - 18)
    }
}
