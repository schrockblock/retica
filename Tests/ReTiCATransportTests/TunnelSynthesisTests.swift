import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// RNS 1.6.0 tunnel synthesis, client half (Transport.py:3043-3064): on every connect of a client
// interface the node sends one DATA packet to PLAIN "rnstransport.tunnel.synthesize" carrying
// `public_key(64) + interface_hash(32) + random_hash(16)` and an Ed25519 signature over those 112
// bytes (176 in all). The hub's `tunnel_synthesize_handler` (Transport.py:3067-3089) validates it and
// files the tunnel under `full_hash(public_key + interface_hash)`. Vectors come from the genuine
// reference code: Vectors/generate_tunnel_synthesis_fixtures.py. ReTiCA's Ed25519 is hedged, so the
// signature is validated, never byte-compared.

/// The reference capture: see Vectors/generate_tunnel_synthesis_fixtures.py.
private struct Fixture: Decodable {
    let identity_private_key: String
    let identity_public_key: String
    let interface_name: String
    let interface_hash: String
    let random_hash: String
    let tunnel_id: String
    let handler_tunnel_id: String
    let tunnel_synthesize_destination_hash: String
    let payload: String
    let raw: String
    let flags: UInt8
    let hops: UInt8
    let context: UInt8

    var identity: Identity { Identity(privateKey: Data(hexString: identity_private_key)!)! }
    var interfaceHash: Data { Data(hexString: interface_hash)! }
    var randomHash: Data { Data(hexString: random_hash)! }
    var payloadBytes: Data { Data(hexString: payload)! }
    var rawBytes: Data { Data(hexString: raw)! }

    static func load() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "tunnel_synthesis_fixtures", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
}

/// The interface id whose Ruling 9c' hash is the reference capture's: its stub interface is named
/// "TCPInterface[tcp]".
private let fixtureInterfaceID = InterfaceID("tcp")

/// A TCP-client profile as `TCPEndpoint` registers it.
private func tunnelProfile(_ name: String = "tcp") -> InterfaceProfile {
    var profile = InterfaceProfile(name: name, bitrate: 10_000_000, hwMTU: 262_144)
    profile.wantsTunnel = true
    return profile
}

/// Every `.delegate(.transmit)` the store processes, recorded in a wrapping reducer.
private final class Recorder: Sendable {
    let transmits = LockIsolated<[(InterfaceID, Data)]>([])

    /// The synthesis packets sent so far, with the interface each went out on.
    var syntheses: [(InterfaceID, Packet)] {
        transmits.value.compactMap { id, raw in
            guard let packet = Packet(raw: raw),
                  packet.destinationHash == Transport.tunnelSynthesizeDestinationHash else { return nil }
            return (id, packet)
        }
    }
}

@MainActor
private func makeStore(_ initial: Transport.State = Transport.State(), recorder: Recorder,
                       randomBytes: RandomBytesGenerator = RandomBytesGenerator { Data(repeating: 0x5A, count: $0) })
    -> TestStore<Transport.State, Transport.Action> {
    let store = TestStore(initialState: initial) {
        CombineReducers {
            Reduce<Transport.State, Transport.Action> { _, action in
                if case let .delegate(.transmit(id, raw)) = action { recorder.transmits.withValue { $0.append((id, raw)) } }
                return .none
            }
            Transport()
        }
    } withDependencies: {
        $0.randomBytes = randomBytes
        $0.continuousClock = TestClock()
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1000))
    }
    store.exhaustivity = .off
    return store
}

@Suite @MainActor struct TunnelSynthesisTests {
    @Test func payloadPrefixMatchesReference() throws {
        let f = try Fixture.load()
        #expect(Transport.tunnelInterfaceHash(interfaceID: fixtureInterfaceID) == f.interfaceHash,
                "Ruling 9c': full_hash of \"TCPInterface[<interface id>]\", as the capture's stub interface hashed it")
        let ours = Transport.tunnelSynthesisPayload(identity: f.identity, interfaceHash: f.interfaceHash,
                                                    randomHash: f.randomHash)
        #expect(ours.count == 176)
        #expect(f.payloadBytes.count == 176)
        #expect(Data(ours.prefix(112)) == Data(f.payloadBytes.prefix(112)),
                "public key + interface hash + random hash, as reference lays them out")
        // The signature is hedged: validate ours, and the reference's, over the same 112 bytes.
        let publicOnly = try #require(Identity(publicKey: Data(hexString: f.identity_public_key)!))
        #expect(publicOnly.validate(signature: Data(ours.suffix(64)), message: Data(ours.prefix(112))))
        #expect(publicOnly.validate(signature: Data(f.payloadBytes.suffix(64)), message: Data(f.payloadBytes.prefix(112))))
    }

    @Test func rawPacketHeaderMatchesReference() async throws {
        let f = try Fixture.load()
        #expect(Transport.tunnelSynthesizeDestinationHash == Data(hexString: f.tunnel_synthesize_destination_hash)!)
        let recorder = Recorder()
        var initial = Transport.State()
        initial.tunnelIdentity = f.identity
        let store = makeStore(initial, recorder: recorder, randomBytes: RandomBytesGenerator { _ in f.randomHash })
        await store.send(.interfaceConnected(fixtureInterfaceID, tunnelProfile()))
        await store.skipReceivedActions(strict: false)

        let raw = try #require(recorder.transmits.value.first?.1)
        #expect(recorder.transmits.value.count == 1)
        // Header: flags, hops, the 16-byte destination hash, context — 19 bytes, byte for byte.
        #expect(raw[raw.startIndex] == f.flags)
        #expect(raw[raw.startIndex + 1] == f.hops)
        #expect(Data(raw.prefix(19)) == Data(f.rawBytes.prefix(19)))
        #expect(raw[raw.startIndex + 18] == f.context)
        // Everything but the hedged signature is identical, and the signature validates.
        #expect(raw.count == f.rawBytes.count)
        #expect(Data(raw.dropLast(64)) == Data(f.rawBytes.dropLast(64)))
        let packet = try #require(Packet(raw: raw))
        #expect(packet.packetType == .data && packet.headerType == .header1
                && packet.transportType == .broadcast && packet.destinationType == .plain && packet.context == .none)
        #expect(f.identity.validate(signature: Data(packet.payload.suffix(64)), message: Data(packet.payload.prefix(112))))
    }

    @Test func tunnelIDMatchesReference() throws {
        let f = try Fixture.load()
        let expected = Data(hexString: f.tunnel_id)!
        #expect(Data(hexString: f.handler_tunnel_id)! == expected, "the id the reference handler filed the tunnel under")
        #expect(Transport.tunnelID(publicKey: f.identity.publicKey, interfaceHash: f.interfaceHash) == expected)
        #expect(Transport.tunnelID(publicKey: f.identity.publicKey,
                                   interfaceHash: Transport.tunnelInterfaceHash(interfaceID: fixtureInterfaceID)) == expected)
    }

    @Test func synthesisSentOnEveryConnectOfTunnelInterfaceOnly() async throws {
        let tunnel = Identity()
        let recorder = Recorder()
        var initial = Transport.State()
        initial.tunnelIdentity = tunnel
        let store = makeStore(initial, recorder: recorder)
        let hubA = InterfaceID("tcp:a:4242"), hubB = InterfaceID("tcp:b:4242")
        let ble = InterfaceID("ble:peer"), auto = InterfaceID("auto:peer"), server = InterfaceID("tcpserver:1")

        // Other interfaces are up first, so a broadcast would show on them.
        await store.send(.interfaceConnected(ble, .ble))
        await store.send(.interfaceConnected(auto, .auto))
        await store.send(.interfaceConnected(server, .tcp))
        await store.send(.interfaceConnected(hubB, tunnelProfile()))
        await store.send(.interfaceConnected(hubA, tunnelProfile()))
        await store.skipReceivedActions(strict: false)
        #expect(recorder.syntheses.map(\.0) == [hubB, hubA], "one per tunnel interface, on that interface only")
        #expect(recorder.transmits.value.count == 2, "nothing on BLE, Auto or an accepted server connection")

        // A reconnect under the same id sends again, on that id only.
        await store.send(.interfaceDisconnected(hubA))
        await store.send(.interfaceConnected(hubA, tunnelProfile()))
        await store.skipReceivedActions(strict: false)
        #expect(recorder.syntheses.map(\.0) == [hubB, hubA, hubA])
        // Ruling 9c': each interface synthesizes under its own id's hash, so the two hubs get two
        // tunnels, and a reconnect of one keeps its tunnel id.
        #expect(Transport.tunnelInterfaceHash(interfaceID: hubA) != Transport.tunnelInterfaceHash(interfaceID: hubB))
        for (id, packet) in recorder.syntheses {
            #expect(packet.payload.count == 176)
            #expect(Data(packet.payload.dropFirst(64).prefix(32)) == Transport.tunnelInterfaceHash(interfaceID: id))
            #expect(Data(packet.payload.prefix(64)) == tunnel.publicKey)
            #expect(tunnel.validate(signature: Data(packet.payload.suffix(64)), message: Data(packet.payload.prefix(112))))
        }
    }

    @Test func noTunnelIdentityNoPacket() async throws {
        let recorder = Recorder()
        let store = makeStore(recorder: recorder)
        await store.send(.interfaceConnected(InterfaceID("tcp:a:4242"), tunnelProfile()))
        // A public-only identity cannot sign: stored, never used.
        await store.send(.setTunnelIdentity(Identity(publicKey: Identity().publicKey)))
        #expect(store.state.tunnelIdentity != nil)
        await store.send(.interfaceConnected(InterfaceID("tcp:b:4242"), tunnelProfile()))
        await store.skipReceivedActions(strict: false)
        #expect(recorder.transmits.value.isEmpty)
        // Cleared again: still nothing.
        await store.send(.setTunnelIdentity(nil))
        await store.send(.interfaceConnected(InterfaceID("tcp:c:4242"), tunnelProfile()))
        await store.skipReceivedActions(strict: false)
        #expect(recorder.transmits.value.isEmpty)
    }

    /// Ruling 9b: the tunnel identity is not a transport identity. A leaf that holds one stays a leaf:
    /// no `transportIdentity`, and its path requests carry a random sender ID, not the tunnel
    /// identity's hash.
    @Test func aTunnelIdentityLeavesTheNodeALeaf() async throws {
        let tunnel = Identity()
        let recorder = Recorder()
        let senderID = Data(repeating: 0x77, count: 16)
        let draws = LockIsolated(0)
        let store = makeStore(recorder: recorder, randomBytes: RandomBytesGenerator { n in
            draws.withValue { $0 += 1; return $0 == 2 ? senderID : Data(repeating: 0x11, count: n) }
        })
        await store.send(.interfaceConnected(InterfaceID("i0")))
        await store.send(.setTunnelIdentity(tunnel))
        #expect(store.state.tunnelIdentity == tunnel)
        #expect(store.state.transportIdentity == nil, "setting the tunnel identity must not turn relaying on")
        await store.send(.requestPath(destinationHash: Data(repeating: 0x22, count: 16)))
        await store.skipReceivedActions(strict: false)
        let request = try #require(recorder.transmits.value.compactMap { Packet(raw: $0.1) }
            .first { $0.destinationHash == Transport.pathRequestDestinationHash })
        #expect(Data(request.payload.dropFirst(16).prefix(16)) == senderID)
        #expect(Data(request.payload.dropFirst(16).prefix(16)) != tunnel.hash)
    }
}
