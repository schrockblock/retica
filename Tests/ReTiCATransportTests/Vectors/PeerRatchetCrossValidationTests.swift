import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

/// Genuine RNS 1.6.0 / LXMF 1.3.0 output: a ratcheted announce and the PROPAGATED lxmf_data a reference
/// sender builds for that recipient, encrypted to the announced ratchet with a pinned ephemeral key and
/// IV. See Vectors/generate_peer_ratchet_fixtures.py, which also checks that the reference decrypts
/// these bytes with the ratchet's private key and not with the identity key alone.
private struct Fixture: Decodable {
    let recipient_private_key: String
    let destination_hash: String
    let announce_raw: String
    let ratchet_public: String
    let ratchet_private: String
    let message_packed: String
    let ephemeral_private: String
    let iv: String
    let lxmf_data: String
    let transient_id: String

    static func load() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "peer_ratchet_fixtures", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
}

private func hex(_ s: String) -> Data { Data(hexString: s)! }

/// From the reference announce to the propagated payload: Transport takes the ratchet from the
/// announce, `recallRatchet` hands it out, and `LXMFPropagation` encrypts to it — byte for byte what
/// LXMF 1.3.0 produces with the same ephemeral key and IV, so the reference decrypts what we send.
@Test @MainActor func aPropagatedPayloadToARatchetMatchesReferenceLXMF() async throws {
    let f = try Fixture.load()
    let destination = hex(f.destination_hash)
    let heard = Date(timeIntervalSince1970: 1_700_000_000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
        $0.transportDate = .constant(heard)
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.received(InterfaceID("i0"), hex(f.announce_raw)))

    let ratchet = try #require(store.state.recallRatchet(destinationHash: destination, now: heard))
    #expect(ratchet == hex(f.ratchet_public))
    let recipient = try #require(store.state.recall(destinationHash: destination))
    let message = try #require(LXMessage.unpack(hex(f.message_packed)))

    let entry = LXMFPropagation.stamplessEntry(message: message, recipientIdentity: recipient, ratchet: ratchet,
                                               ephemeralPrivateKey: hex(f.ephemeral_private), iv: hex(f.iv))
    #expect(entry == hex(f.lxmf_data))
    #expect(LXMFPropagation.transientId(lxmfData: entry) == hex(f.transient_id))

    // And our own decrypt agrees: the ratchet's private key opens it, the identity key alone does not.
    let recipientPrivate = try #require(Identity(privateKey: hex(f.recipient_private_key)))
    let encrypted = Data(entry.dropFirst(LXMessage.destinationLength))
    let tail = Data(hex(f.message_packed).dropFirst(LXMessage.destinationLength))
    #expect(recipientPrivate.decrypt(encrypted, ratchets: [hex(f.ratchet_private)]) == tail)
    #expect(recipientPrivate.decrypt(encrypted) == nil)
}
