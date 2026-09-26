import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

private let proofIfID = InterfaceID("tcp-1")

/// Our packet hash for the reference DATA packet equals RNS's `packet_hash` — the value a proof
/// signs, and whose first 16 bytes address the proof.
@Test func proofVectorDataPacketHashMatchesReference() throws {
    let f = try ProofVectorFixtures.load()
    let packet = try #require(Packet(raw: f.dataPacketBytes))
    #expect(packet.packetHash == f.dataPacketHashBytes)
}

/// `.proveSingle` emits, on the requested interface, a PROOF whose flags, hops, proof destination
/// (`packetHash[:16]`) and context bytes are identical to reference `Identity.prove` (implicit form),
/// and whose 64-byte signature validates over the packet hash with the prover's PUBLIC identity.
///
/// Byte-identity of the signature itself is NOT asserted and cannot be: `Identity.sign` is
/// CryptoKit, whose Ed25519 is hedged (randomised — see DeterministicSigner.swift), while RNS signs
/// deterministically (RFC 8032). Both are valid signatures of the same message, and receivers only
/// verify, never compare.
@Test @MainActor func proofVectorProveSingleMatchesReferenceImplicitProof() async throws {
    let f = try ProofVectorFixtures.load()
    var initial = Transport.State()
    initial.interfaces[proofIfID] = .default
    let store = TestStore(initialState: initial) { Transport() }   // exhaustive: exactly one transmit

    await store.send(.proveSingle(packetHash: f.dataPacketHashBytes, interfaceID: proofIfID,
                                  identity: f.identity))
    let sent = LockIsolated<Data?>(nil)
    await store.receive { action in
        guard case let .delegate(.transmit(id, raw)) = action, id == proofIfID else { return false }
        sent.setValue(raw)
        return true
    }

    let raw = try #require(sent.value)
    let reference = f.implicitProofPacketBytes
    #expect(raw.count == reference.count)                 // 19 header bytes + 64-byte signature
    #expect(raw.prefix(19) == reference.prefix(19))       // flags, hops, hash[:16], context
    let proof = try #require(Packet(raw: raw))
    #expect(proof.packetType == .proof)
    #expect(proof.destinationType == .single)
    #expect(proof.destinationHash == f.dataPacketHashBytes.prefix(16))
    #expect(f.publicIdentity.validate(signature: proof.payload, message: f.dataPacketHashBytes))
}

/// An identity that cannot sign (public key only) proves nothing — and must not trap in `sign`.
@Test @MainActor func proofVectorProveSingleNeedsAPrivateKey() async throws {
    let f = try ProofVectorFixtures.load()
    var initial = Transport.State()
    initial.interfaces[proofIfID] = .default
    let store = TestStore(initialState: initial) { Transport() }   // exhaustive: a transmit fails
    await store.send(.proveSingle(packetHash: f.dataPacketHashBytes, interfaceID: proofIfID,
                                  identity: f.publicIdentity))
}

/// A proof for an interface that is not (or no longer) connected is dropped, not sent into nothing.
@Test @MainActor func proofVectorProveSingleNeedsAConnectedInterface() async throws {
    let f = try ProofVectorFixtures.load()
    let store = TestStore(initialState: Transport.State()) { Transport() }   // no interfaces
    await store.send(.proveSingle(packetHash: f.dataPacketHashBytes, interfaceID: proofIfID,
                                  identity: f.identity))
}

/// A single DATA packet decrypted for a local destination surfaces its full 32-byte packet hash —
/// the reference `packet_hash` a proof must sign — and the interface it arrived on.
@Test @MainActor func inboundProvingReceivedCarriesReferencePacketHashAndArrivalInterface() async throws {
    let f = try ProofVectorFixtures.load()
    let local = try #require(Destination(kind: .single, direction: .in, appName: "lxmf",
                                         aspects: ["delivery"], identity: f.identity))
    #expect(local.hash == f.destinationHashBytes)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(local))
    await store.send(.received(proofIfID, f.dataPacketBytes))
    await store.receive(.delegate(.received(destinationHash: f.destinationHashBytes,
                                            plaintext: f.plaintextBytes,
                                            packetHash: f.dataPacketHashBytes,
                                            interfaceID: proofIfID)))
}
