import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// RNS 1.6.0 path requests (Transport.py:3685-3722, 3975-4050). A request is always
// `destination + sender ID + tag` (48 bytes); with stamping on it also carries the 16-byte extension
// `0xC1, flags, stamp` (64 bytes), the stamp mined over `destination + tag`. A relay forwards the
// extension it received, and while stamping marks an unstamped request with `0xC1 0xFF` and 14 zero
// bytes (Transport.py:3935-3936, 3955-3956).

private let tag = Data(repeating: 0xAB, count: 16)
private let destHash = Data(repeating: 0x22, count: 16)

/// Every `.delegate(.transmit)` the store sees, and every finished stamp search, counted in a
/// wrapping reducer: a `receive` predicate cannot count what an earlier `send` skipped.
private final class Recorder: Sendable {
    let transmits = LockIsolated<[(InterfaceID, Data)]>([])
    let searchesEnded = LockIsolated(0)

    var payloads: [Data] { transmits.value.compactMap { Packet(raw: $0.1)?.payload } }
}

@MainActor
private func makeStore(_ initial: Transport.State = Transport.State(), clock: TestClock<Duration> = TestClock(),
                       recorder: Recorder = Recorder()) -> TestStore<Transport.State, Transport.Action> {
    let store = TestStore(initialState: initial) {
        CombineReducers {
            Reduce<Transport.State, Transport.Action> { _, action in
                if case let .delegate(.transmit(id, raw)) = action { recorder.transmits.withValue { $0.append((id, raw)) } }
                if case .pathRequestStampSearchEnded = action { recorder.searchesEnded.withValue { $0 += 1 } }
                return .none
            }
            Transport()
        }
    } withDependencies: {
        $0.randomBytes = RandomBytesGenerator { _ in tag }
        $0.continuousClock = clock
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1000))
    }
    store.exhaustivity = .off
    return store
}

/// The next path request the store transmits.
@MainActor
private func nextPathRequest(_ store: TestStore<Transport.State, Transport.Action>) async -> Packet? {
    let captured = LockIsolated<Data?>(nil)
    await store.receive({ action in
        guard case let .delegate(.transmit(_, raw)) = action,
              Packet(raw: raw)?.destinationHash == Transport.pathRequestDestinationHash else { return false }
        captured.setValue(raw)
        return true
    }, timeout: .seconds(10))
    return captured.value.flatMap { Packet(raw: $0) }
}

private func pathRequest(_ payload: Data) -> Data {
    try! Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                payload: payload).packed()
}

/// A real RNS 1.6.0 path request pair: see Vectors/generate_path_request_fixtures.py.
private struct Fixture: Decodable {
    let identity_private_key: String
    let app_name: String
    let aspects: [String]
    let destination_hash: String
    let transport_id: String
    let tag: String
    let ext_payload: String
    let pr_cost: Double
    let path_request_destination_hash: String
    let stamped_raw: String
    let unstamped_raw: String

    var destinationHash: Data { Data(hexString: destination_hash)! }
    var requestTag: Data { Data(hexString: tag)! }
    var ext: Data { Data(hexString: ext_payload)! }
    var stampedRaw: Data { Data(hexString: stamped_raw)! }
    var unstampedRaw: Data { Data(hexString: unstamped_raw)! }

    static func load() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "path_request_fixtures", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func destination() throws -> Destination {
        let identity = try #require(Identity(privateKey: Data(hexString: identity_private_key)!))
        let dest = try #require(Destination(kind: .single, direction: .in, appName: app_name, aspects: aspects,
                                            identity: identity))
        try #require(dest.hash == destinationHash)
        return dest
    }
}

/// A local destination of our own, and path requests for it of any payload length.
private func ownedDestination() -> Destination {
    Destination(kind: .single, direction: .in, appName: "retica", aspects: ["owned"], identity: Identity())!
}

private func isPathResponse(_ raw: Data, for dest: Data) -> Bool {
    guard let p = Packet(raw: raw) else { return false }
    return p.packetType == .announce && p.context == .pathResponse && p.destinationHash == dest
}

@Suite @MainActor struct PathRequestStampTests {
    @Test func aPathRequestAlwaysCarriesASenderID() async throws {
        #expect(Transport.State().stampPathRequests == false, "1.6.0 does not stamp by default")
        #expect(Transport.State().pathRequestSenderID.count == 16)
        #expect(Transport.State().pathRequestSenderID != Transport.State().pathRequestSenderID,
                "random per instance")
        let store = makeStore()
        await store.send(.interfaceConnected(InterfaceID("i0")))
        await store.send(.requestPath(destinationHash: destHash))
        let request = try #require(await nextPathRequest(store))
        #expect(request.payload.count == 48)
        #expect(Data(request.payload.prefix(16)) == destHash)
        #expect(Data(request.payload.dropFirst(16).prefix(16)) == store.state.pathRequestSenderID,
                "a leaf has no transport identity, so it sends its per-instance sender ID")
        #expect(Data(request.payload.dropFirst(32)) == tag)
    }

    @Test func aStampedPathRequestIs64BytesAndValidates() async throws {
        var initial = Transport.State()
        initial.stampPathRequests = true
        #expect(initial.pathRequestValue == 15.8)
        let store = makeStore(initial)
        await store.send(.interfaceConnected(InterfaceID("i0")))
        await store.send(.requestPath(destinationHash: destHash))
        let request = try #require(await nextPathRequest(store))
        let payload = request.payload
        try #require(payload.count == 64)
        #expect(Data(payload.prefix(16)) == destHash)
        #expect(Data(payload.dropFirst(16).prefix(16)) == store.state.pathRequestSenderID)
        #expect(Data(payload.dropFirst(32).prefix(16)) == tag)
        #expect(payload[payload.startIndex + 48] == 0xC1)
        #expect(payload[payload.startIndex + 49] == 0x00, "flags 0x00 mark a real stamp")
        let stamp = Data(payload.dropFirst(50))
        #expect(stamp.count == 14)
        // A random 14 bytes meet 15.8 about one time in 57,000.
        #expect(NetworkStamp.isValid(stamp: stamp, cost: 15.8, material: destHash + tag))
        #expect(store.state.stampingPathRequests.isEmpty)
    }

    @Test func anUnansweredStampSearchGivesUpAfter15SecondsAndSendsNothing() async {
        let clock = TestClock()
        let recorder = Recorder()
        var initial = Transport.State()
        initial.stampPathRequests = true
        initial.pathRequestValue = 100        // about 2^100 rounds: it cannot finish here
        let store = makeStore(initial, clock: clock, recorder: recorder)
        await store.send(.interfaceConnected(InterfaceID("i0")))
        await store.send(.requestPath(destinationHash: destHash))
        #expect(store.state.pathRequests[destHash] != nil,
                "set before the search, so the answering announce is exempt from ingress holding")
        #expect(store.state.stampingPathRequests == [destHash])
        await clock.advance(by: .seconds(14.9))
        #expect(store.state.stampingPathRequests == [destHash], "still searching before the timeout")
        await clock.advance(by: .seconds(0.1))
        await store.receive({ if case .pathRequestStampSearchEnded = $0 { return true }; return false },
                            timeout: .seconds(5))
        #expect(store.state.stampingPathRequests.isEmpty)
        #expect(recorder.transmits.value.isEmpty, "a search that runs out sends nothing")
        store.exhaustivity = .on
        await store.finish()
    }

    @Test func aSecondRequestWhileSearchingDoesNotStartAnotherSearch() async {
        let clock = TestClock()
        let recorder = Recorder()
        var initial = Transport.State()
        initial.stampPathRequests = true
        initial.pathRequestValue = 100
        let store = makeStore(initial, clock: clock, recorder: recorder)
        await store.send(.interfaceConnected(InterfaceID("i0")))
        await store.send(.requestPath(destinationHash: destHash))
        await store.send(.requestPath(destinationHash: destHash))
        await clock.advance(by: .seconds(15))
        await store.receive({ if case .pathRequestStampSearchEnded = $0 { return true }; return false },
                            timeout: .seconds(5))
        await clock.advance(by: .seconds(15))
        store.exhaustivity = .on
        await store.finish()
        #expect(recorder.searchesEnded.value == 1)
    }

    @Test func cancellingStopsTheSearchAndSendsNothing() async {
        let recorder = Recorder()
        var initial = Transport.State()
        initial.stampPathRequests = true
        initial.pathRequestValue = 100
        let store = makeStore(initial, recorder: recorder)
        await store.send(.interfaceConnected(InterfaceID("i0")))
        await store.send(.requestPath(destinationHash: destHash))
        #expect(store.state.stampingPathRequests == [destHash])
        await store.send(.cancelPathRequestStamps)
        #expect(store.state.stampingPathRequests.isEmpty)
        // A search still running (cost 100) would keep its effect alive past `finish`.
        store.exhaustivity = .on
        await store.finish()
        #expect(recorder.transmits.value.isEmpty)
    }

    @Test func aStampedInboundRequestIsAnsweredWithTheRightTag() async throws {
        let f = try Fixture.load()
        #expect(Transport.pathRequestDestinationHash == Data(hexString: f.path_request_destination_hash)!)
        // Our validator agrees with the reference's on the reference's stamp.
        #expect(NetworkStamp.isValid(stamp: Data(f.ext.dropFirst(2)), cost: f.pr_cost,
                                     material: f.destinationHash + f.requestTag))
        let dest = try f.destination()
        let recorder = Recorder()
        let store = makeStore(recorder: recorder)
        await store.send(.registerLocalDestination(dest))
        await store.send(.received(InterfaceID("in"), f.stampedRaw))
        // The tag is bytes 32..<48, not everything after the sender ID: the unstamped request with
        // the same tag is a duplicate and goes unanswered.
        await store.send(.received(InterfaceID("in"), f.unstampedRaw))
        // A fresh tag is answered, so any answer to the duplicate would already have been seen.
        await store.send(.received(InterfaceID("in"), pathRequest(f.destinationHash + Data(repeating: 1, count: 32))))
        await store.skipReceivedActions(strict: false)
        let answers = recorder.transmits.value.filter { isPathResponse($0.1, for: dest.hash) }
        #expect(answers.count == 2)
        #expect(answers.allSatisfy { $0.0 == InterfaceID("in") })
    }

    @Test func aRelayForwardsTheExtensionUnchanged() async throws {
        let f = try Fixture.load()
        for stamping in [false, true] {
            let relay = Identity()
            let recorder = Recorder()
            var initial = Transport.State()
            initial.stampPathRequests = stamping
            let store = makeStore(initial, recorder: recorder)
            await store.send(.interfaceConnected(InterfaceID("i0")))
            await store.send(.interfaceConnected(InterfaceID("i1")))
            await store.send(.setTransportIdentity(relay))
            await store.send(.setRecursivePathRequests(true))
            await store.send(.received(InterfaceID("i0"), f.stampedRaw))
            await store.skipReceivedActions(strict: false)
            let forwarded = recorder.transmits.value
            #expect(forwarded.count == 1, "stamping \(stamping)")
            #expect(forwarded.first?.0 == InterfaceID("i1"))
            let payload = forwarded.first.flatMap { Packet(raw: $0.1)?.payload }
            #expect(payload == f.destinationHash + relay.hash + f.requestTag + f.ext,
                    "stamping \(stamping): the received extension, byte for byte")
        }
    }

    @Test func aRelayMarksAnUnstampedRequestLenientlyOnlyWhenStamping() async throws {
        let f = try Fixture.load()
        for stamping in [false, true] {
            let relay = Identity()
            let recorder = Recorder()
            var initial = Transport.State()
            initial.stampPathRequests = stamping
            let store = makeStore(initial, recorder: recorder)
            await store.send(.interfaceConnected(InterfaceID("i0")))
            await store.send(.interfaceConnected(InterfaceID("i1")))
            await store.send(.setTransportIdentity(relay))
            await store.send(.setRecursivePathRequests(true))
            await store.send(.received(InterfaceID("i0"), f.unstampedRaw))
            await store.skipReceivedActions(strict: false)
            let payloads = recorder.payloads
            #expect(payloads.count == 1, "stamping \(stamping)")
            let expected = f.destinationHash + relay.hash + f.requestTag
                + (stamping ? Data([0xC1, 0xFF]) + Data(repeating: 0, count: 14) : Data())
            #expect(payloads.first == expected, "stamping \(stamping)")
        }
    }

    @Test func oversizedPathRequestsAreIgnored() async {
        let dest = ownedDestination()
        let recorder = Recorder()
        let store = makeStore(recorder: recorder)
        await store.send(.registerLocalDestination(dest))
        for (n, size) in [65, 80, 400].enumerated() {
            let payload = dest.hash + Data(repeating: UInt8(n + 1), count: size - 16)
            await store.send(.received(InterfaceID("in"), pathRequest(payload)))
        }
        // The largest valid size is answered, so an answer to any oversized one would already be seen.
        await store.send(.received(InterfaceID("in"), pathRequest(dest.hash + Data(repeating: 0x77, count: 48))))
        await store.skipReceivedActions(strict: false)
        #expect(recorder.transmits.value.filter { isPathResponse($0.1, for: dest.hash) }.count == 1)
    }

    @Test func pathRequestsOfAnInvalidSizeAreIgnored() async {
        // Transport.py:2091-2093: only 32 (legacy), 48 and 64 bytes.
        let dest = ownedDestination()
        let recorder = Recorder()
        let store = makeStore(recorder: recorder)
        await store.send(.registerLocalDestination(dest))
        for (n, size) in [17, 31, 33, 47, 49, 63].enumerated() {
            await store.send(.received(InterfaceID("in"), pathRequest(dest.hash + Data(repeating: UInt8(n + 1), count: size - 16))))
        }
        for (n, size) in [32, 48, 64].enumerated() {
            await store.send(.received(InterfaceID("in"), pathRequest(dest.hash + Data(repeating: UInt8(n + 0x40), count: size - 16))))
        }
        await store.skipReceivedActions(strict: false)
        #expect(recorder.transmits.value.filter { isPathResponse($0.1, for: dest.hash) }.count == 3)
    }
}
