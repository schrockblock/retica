import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

@Test @MainActor func transportLearnsFromReferenceAnnouncePacket() async throws {
    let f = try TransportVectorFixtures.load()
    let destHash = Data(hexString: f.announceDestHash)!
    let ifID = InterfaceID("tcp-1")

    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.received(ifID, Data(hexString: f.announcePacket)!))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash,
                                               hops: UInt8(f.announceHops))))

    let entry = store.state.learned[destHash]
    #expect(entry?.identity.hexHash == f.announceIdentityHash)
    #expect(entry?.appData == Data(hexString: f.announceAppData))
    #expect(entry?.hops == UInt8(f.announceHops))
    #expect(entry?.interfaceID == ifID)
}

/// The announce random-blob our parser extracts must byte-equal the random_blob RNS keys its
/// dedup on (Transport.py:1807), and our per-destination dedup sequence (accept / replay-drop /
/// accept) must match RNS's `not random_blob in random_blobs` decision.
@Test @MainActor func announceRandomBlobMatchesRnsAndDedupSequence() async throws {
    let f = try TransportVectorFixtures.load()
    let ann1 = Data(hexString: f.rbAnnounce1)!
    let ann2 = Data(hexString: f.rbAnnounce2)!
    let blob1 = Data(hexString: f.rbBlob1)!
    let blob2 = Data(hexString: f.rbBlob2)!
    let destHash = Data(hexString: f.announceDestHash)!

    // 1. Blob-key byte parity vs genuine RNS.
    let p1 = Packet(raw: ann1)!
    let parsed1 = Announce.parse(payload: p1.payload, destinationHash: p1.destinationHash,
                                 contextFlagSet: p1.contextFlag)!
    #expect(parsed1.randomHash == blob1)
    let p2 = Packet(raw: ann2)!
    let parsed2 = Announce.parse(payload: p2.payload, destinationHash: p2.destinationHash,
                                 contextFlagSet: p2.contextFlag)!
    #expect(parsed2.randomHash == blob2)

    // 2. Dedup sequence parity: ann1 accepted, exact replay dropped, ann2 (fresh, newer) accepted.
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.received(InterfaceID("i"), ann1))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    await store.send(.received(InterfaceID("i"), ann1))   // replay → dropped
    await store.send(.received(InterfaceID("i"), ann2))   // fresh, newer emission → accepted
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    #expect(store.state.announceBlobs[destHash]?.contains(blob1) == true)
    #expect(store.state.announceBlobs[destHash]?.contains(blob2) == true)
}
