import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

/// Feeds the genuine Python-RNS 1.3.8 announce fixture into a relay Transport and asserts the
/// re-broadcast is a wire-faithful HEADER_2 relayed announce: correct header rewrite, hops+1,
/// our transport_id, payload byte-identical to the original, and the original signature still
/// validates (proving the re-broadcast preserves the genuine RNS payload).
@Test @MainActor func relayRebroadcastsGenuineRnsAnnounceCorrectly() async throws {
    let f = try TransportVectorFixtures.load()
    let announceRaw = Data(hexString: f.announcePacket)!
    let relay = Identity()

    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.interfaceConnected(InterfaceID("a")))
    await store.send(.interfaceConnected(InterfaceID("b")))
    await store.send(.setTransportIdentity(relay))

    await store.send(.received(InterfaceID("a"), announceRaw))

    // Drain the pathLearned delegate (direct match by destHash from fixture).
    let destHash = Data(hexString: f.announceDestHash)!
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: UInt8(f.announceHops))))

    // Drain the single re-broadcast transmit (to interface "b", not the received-from "a").
    let captured = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action, ifID == InterfaceID("b") {
            captured.setValue(raw)
            return true
        }
        return false
    }

    // --- Shape assertions: correct HEADER_2 rewrite ---
    let rb = Packet(raw: captured.value!)!
    #expect(rb.headerType == .header2)
    #expect(rb.transportType == .transport)
    #expect(rb.transportId == relay.hash)
    #expect(Int(rb.hops) == f.announceHops + 1)

    // --- Payload byte-identity: the original genuine-RNS payload survived the relay verbatim ---
    let orig = Packet(raw: announceRaw)!
    #expect(rb.payload == orig.payload)

    // --- Signature integrity: re-parsing the re-broadcast recovers the genuine identity ---
    // This proves the relay did NOT corrupt the payload; the Ed25519 signature from Python-RNS
    // 1.3.8 still validates, and we recover the same identity hash as the fixture records.
    let parsed = Announce.parse(payload: rb.payload, destinationHash: rb.destinationHash,
                                contextFlagSet: rb.contextFlag)
    #expect(parsed != nil)
    #expect(parsed?.identity.hash == Data(hexString: f.announceIdentityHash)!)
}
