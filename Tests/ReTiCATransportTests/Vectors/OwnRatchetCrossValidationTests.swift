import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

/// Genuine RNS 1.6.0 / LXMF 1.3.0 output for OUR own ratchets: a fixed test identity and ring, the
/// announce a reference destination with that ring emits, DATA packets a reference sender encrypts to
/// that destination (to its identity key, to ring[0] learned from the announce, to the older ring[2]),
/// and PROPAGATED LXMF entries to its delivery destination (identity key, ring[1]). See
/// Vectors/generate_own_ratchet_fixtures.py, which also checks the reference's own decrypt of each with
/// and without enforcement. The keys are fixture keys, not a real identity's.
private struct Fixture: Decodable {
    let identity_private_key: String
    let ring: [String]
    let ring_public: [String]
    let destination_hash: String
    let delivery_destination_hash: String
    let announce_raw: String
    let plaintext: String
    let packet_identity: String
    let packet_ratchet0: String
    let packet_ratchet2: String
    let propagated_identity: String
    let propagated_identity_packed: String
    let propagated_ratchet1: String
    let propagated_ratchet1_packed: String

    static func load() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "own_ratchet_fixtures", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
}

private func hex(_ s: String) -> Data { Data(hexString: s)! }
private let i0 = InterfaceID("i0")
private let heard = Date(timeIntervalSince1970: 1_700_000_000)

private enum Logged: Equatable, Sendable {
    case transmit(Data)
    case received(Data)
    case other
}

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
            default: entry = .other
            }
            log.withValue { $0.append(entry) }
            return .none
        }
        Transport()
    }
}

private func delivered(_ log: DelegateLog) -> [Data] {
    log.value.compactMap {
        guard case let .received(plaintext) = $0 else { return nil }
        return plaintext
    }
}

private func firstTransmit(_ log: DelegateLog) -> Data? {
    log.value.lazy.compactMap { entry -> Data? in
        guard case let .transmit(raw) = entry else { return nil }
        return raw
    }.first
}

/// The fixture's destination registered on a store, with one interface connected.
@MainActor
private func fixtureStore(_ f: Fixture, _ log: DelegateLog,
                          initial: Transport.State = Transport.State()) async throws -> (TestStoreOf<Transport>, Destination) {
    let identity = try #require(Identity(privateKey: hex(f.identity_private_key)))
    let dest = try #require(Destination(kind: .single, direction: .in, appName: "retica", aspects: ["ownratchet"],
                                        identity: identity))
    #expect(dest.hash == hex(f.destination_hash))
    let store = TestStore(initialState: initial) { ObservedTransport(log: log) } withDependencies: {
        $0.continuousClock = ImmediateClock()
        $0.transportDate = .constant(heard)
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(i0, .default))
    await store.send(.registerLocalDestination(dest))
    return (store, dest)
}

@Suite @MainActor struct OwnRatchetCrossValidationTests {
    /// Packets a reference sender encrypted to our ratchets (learned from the reference announce, and an
    /// older one) decrypt with the ring; one to the identity key decrypts too, unless ratchets are enforced.
    @Test func referencePacketsToOurRatchetsDecryptWithTheRing() async throws {
        let f = try Fixture.load()
        let log = DelegateLog([])
        let (store, dest) = try await fixtureStore(f, log)
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: f.ring.map(hex)))
        await store.send(.received(i0, hex(f.packet_ratchet0)))
        await store.send(.received(i0, hex(f.packet_ratchet2)))
        await store.send(.received(i0, hex(f.packet_identity)))
        await store.skipReceivedActions(strict: false)
        #expect(delivered(log) == Array(repeating: hex(f.plaintext), count: 3))

        // Without the ring, the ratchet packets do not decrypt at all.
        let plainLog = DelegateLog([])
        let (plain, _) = try await fixtureStore(f, plainLog)
        await plain.send(.received(i0, hex(f.packet_ratchet0)))
        await plain.send(.received(i0, hex(f.packet_ratchet2)))
        await plain.skipReceivedActions(strict: false)
        #expect(delivered(plainLog).isEmpty)
    }

    @Test func withEnforcementOnlyTheReferenceRatchetPacketsDecrypt() async throws {
        let f = try Fixture.load()
        let log = DelegateLog([])
        let (store, dest) = try await fixtureStore(f, log)
        await store.send(.enableRatchets(destinationHash: dest.hash, ring: f.ring.map(hex)))
        await store.send(.setEnforceRatchets(destinationHash: dest.hash, true))
        // The packets carry the same plaintext, so each is checked on its own.
        await store.send(.received(i0, hex(f.packet_identity)))
        await store.skipReceivedActions(strict: false)
        #expect(delivered(log).isEmpty, "the identity-key packet is dropped")
        await store.send(.received(i0, hex(f.packet_ratchet2)))
        await store.skipReceivedActions(strict: false)
        #expect(delivered(log) == [hex(f.plaintext)], "the ratchet packet decrypts")
    }

    /// Propagated LXMF a reference sender encrypted to our delivery destination's ratchet opens with the
    /// ring; the identity-key one opens unless enforced.
    @Test func referencePropagatedEntriesOpenWithTheRing() throws {
        let f = try Fixture.load()
        let identity = try #require(Identity(privateKey: hex(f.identity_private_key)))
        let ring = f.ring.map(hex)
        let toRatchet = hex(f.propagated_ratchet1), toIdentity = hex(f.propagated_identity)
        #expect(LXMFPropagation.recoverPacked(lxmfData: toRatchet, recipientIdentity: identity, ratchets: ring)
                == hex(f.propagated_ratchet1_packed))
        #expect(LXMFPropagation.recoverPacked(lxmfData: toRatchet, recipientIdentity: identity) == nil)
        #expect(LXMFPropagation.recoverPacked(lxmfData: toIdentity, recipientIdentity: identity, ratchets: ring)
                == hex(f.propagated_identity_packed))
        #expect(LXMFPropagation.recoverPacked(lxmfData: toRatchet, recipientIdentity: identity, ratchets: ring,
                                              enforceRatchets: true) == hex(f.propagated_ratchet1_packed))
        #expect(LXMFPropagation.recoverPacked(lxmfData: toIdentity, recipientIdentity: identity, ratchets: ring,
                                              enforceRatchets: true) == nil)
    }

    /// Our announce with the fixture ring (rotation held off, so it carries ring[0]) has the reference's
    /// layout: same length, flags, destination, public key, name hash and ratchet bytes at the same
    /// offset. The random hash and the (hedged) signature differ, so those are validated by our parser.
    @Test func ourRatchetedAnnounceHasTheReferenceLayout() async throws {
        let f = try Fixture.load()
        let log = DelegateLog([])
        var initial = Transport.State()
        initial.ownRatchets[hex(f.destination_hash)] = .init(ring: f.ring.map(hex), lastRotation: heard)
        let (store, dest) = try await fixtureStore(f, log, initial: initial)
        await store.send(.announce(destinationHash: dest.hash, appData: nil))
        await store.skipReceivedActions(strict: false)
        let ours = try #require(firstTransmit(log))
        let reference = hex(f.announce_raw)
        #expect(ours.count == reference.count)
        let header = 2 + 16 + 1                        // flags, hops, destination hash, context
        #expect(ours.prefix(header) == reference.prefix(header))
        let keyAndName = header..<(header + 64 + 10)
        #expect(ours[keyAndName] == reference[keyAndName])
        let ratchetRange = (header + 64 + 10 + 10)..<(header + 64 + 10 + 10 + 32)
        #expect(ours[ratchetRange] == reference[ratchetRange])
        #expect(ours[ratchetRange] == hex(f.ring_public[0]))
        let packet = try #require(Packet(raw: ours))
        let parsed = try #require(Announce.parse(payload: packet.payload, destinationHash: dest.hash,
                                                 contextFlagSet: packet.contextFlag))
        #expect(parsed.ratchet == hex(f.ring_public[0]))
    }
}

// MARK: - Live round trip through the reference (gated)

private let referencePython = ProcessInfo.processInfo.environment["RETICA_REFERENCE_PYTHON"]
    ?? ProcessInfo.processInfo.environment["RETICA_LIVE_STAMP_PYTHON"]
private let generatorScript = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("generate_own_ratchet_fixtures.py")

private struct ReferenceVerdict: Decodable {
    let context_flag: Bool
    let valid: Bool
    let ratchet: String?
    let packet: String?
}

/// Runs the generator's validate mode on `announce` and returns its verdict.
private func referenceVerdict(on announce: Data, plaintext: Data) throws -> ReferenceVerdict {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("retica-own-ratchet-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("announce.hex")
    try announce.hexString.write(to: input, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: referencePython!)
    process.arguments = [generatorScript.path, "--validate", input.path, plaintext.hexString]
    process.currentDirectoryURL = dir
    let out = Pipe()
    process.standardOutput = out
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    let line = try #require(text.split(separator: "\n").last(where: { $0.hasPrefix("RESULT ") }),
                            "reference output: \(text)")
    return try JSONDecoder().decode(ReferenceVerdict.self, from: Data(line.dropFirst("RESULT ".count).utf8))
}

/// The reference validates the ratcheted announce ReTiCA builds (signature, ratchet, context flag), takes
/// its ratchet, encrypts a packet to it through `RNS.Packet` → `Destination.encrypt`, and ReTiCA decrypts
/// that packet with the ring. Run with RETICA_REFERENCE_PYTHON (or RETICA_LIVE_STAMP_PYTHON) set to the
/// rns-latest interpreter.
@Test(.enabled(if: referencePython != nil), .timeLimit(.minutes(2)))
@MainActor func theReferenceValidatesOurRatchetedAnnounceAndWeDecryptWhatItEncryptsToIt() async throws {
    let f = try Fixture.load()
    let log = DelegateLog([])
    let (store, dest) = try await fixtureStore(f, log)
    await store.send(.enableRatchets(destinationHash: dest.hash, ring: f.ring.map(hex)))
    await store.send(.announce(destinationHash: dest.hash, appData: nil))
    await store.skipReceivedActions(strict: false)
    let announce = try #require(firstTransmit(log))
    let ring = try #require(store.state.ownRatchets[dest.hash]?.ring)
    try #require(ring.count == 4, "the first announce rotated")

    let plaintext = Data("from the reference to our ratchet".utf8)
    let verdict = try referenceVerdict(on: announce, plaintext: plaintext)
    #expect(verdict.valid)
    #expect(verdict.context_flag)
    #expect(verdict.ratchet == Identity.ratchetPublicKey(privateKey: ring[0])?.hexString)
    let packet = try #require(verdict.packet.map(hex))

    // It is encrypted to the ratchet: the identity key alone does not open it.
    let identity = try #require(Identity(privateKey: hex(f.identity_private_key)))
    #expect(identity.decrypt(try #require(Packet(raw: packet)).payload) == nil)
    await store.send(.received(i0, packet))
    await store.skipReceivedActions(strict: false)
    #expect(delivered(log) == [plaintext])
}
