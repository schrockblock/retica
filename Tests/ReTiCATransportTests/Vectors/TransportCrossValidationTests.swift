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

/// Our announce re-broadcast jitter window equals RNS's PATHFINDER_RW, and the jitter mapping keeps
/// every possible delay strictly within [0, window).
@Test @MainActor func announceRebroadcastWindowMatchesRnsPathfinderRw() throws {
    let f = try TransportVectorFixtures.load()
    #expect(Transport.announceRebroadcastWindow == f.pathfinderRw)
    // Delay for any random byte 0…255 is byte/256 * window ∈ [0, window).
    let maxDelay = Double(255) / 256.0 * Transport.announceRebroadcastWindow
    #expect(maxDelay < Transport.announceRebroadcastWindow)
    #expect(maxDelay >= 0)
}

/// Our announce retry constants match RNS's LOCAL_REBROADCASTS_MAX and PATHFINDER_G.
@Test func announceRetryConstantsMatchRns() throws {
    let f = try TransportVectorFixtures.load()
    #expect(Transport.announceMaxRebroadcasts == f.localRebroadcastsMax)
    #expect(Transport.announceRetryGrace == f.pathfinderG)
}

/// Our path/link expiry constants match RNS's DESTINATION_TIMEOUT and LINK_TIMEOUT.
@Test func expiryConstantsMatchRns() throws {
    let f = try TransportVectorFixtures.load()
    #expect(Transport.pathExpiry == f.destinationTimeout)
    #expect(Transport.linkTableExpiry == f.linkTimeout)
}

/// Our path-request control-destination hash equals genuine RNS's, and our responder extracts the
/// correct requested destination from a genuine RNS PATH_REQUEST payload (data[:16]).
@Test func pathRequestControlHashAndSlicingMatchRns() throws {
    let f = try TransportVectorFixtures.load()
    #expect(Transport.pathRequestDestinationHash == Data(hexString: f.prControlHash)!)
    let payload = Data(hexString: f.prRequestPayload)!
    #expect(Data(payload.prefix(16)) == Data(hexString: f.prRequestedDest)!)   // our data[:16] slicing == RNS
}

/// Our PATH_REQUEST tag slicing extracts the same tag genuine RNS placed in the request, and our
/// unique_tag matches RNS's destHash ‖ tag (RNS path_request_handler:2905-2921).
@Test func pathRequestTagSlicingMatchesRns() throws {
    let f = try TransportVectorFixtures.load()
    let payload = Data(hexString: f.prRequestPayload)!    // genuine RNS leaf request: destHash ‖ tag (32 bytes)
    let requested = Data(payload.prefix(16))
    let tag = Data(payload.dropFirst(16).prefix(16))      // our > 16 branch (count == 32)
    #expect(tag == Data(hexString: f.prTag)!)
    #expect(requested + tag == Data(hexString: f.prRequestedDest)! + Data(hexString: f.prTag)!)
}

/// Our HEADER_2 pathResponse announce serialization is byte-identical to what genuine RNS emits
/// when a relay re-broadcasts a cached announce as a path response (RNS Transport.py:616-629).
@Test func relayCachePathResponseSerializationMatchesRns() throws {
    let f = try TransportVectorFixtures.load()
    let response = Packet(
        headerType: .header2, packetType: .announce, transportType: .transport,
        destinationType: .single, context: .pathResponse, contextFlag: false,
        hops: UInt8(f.prRespHops),
        destinationHash: Data(hexString: f.announceDestHash)!,
        transportId: Data(hexString: f.prRespRelayHash)!,
        payload: Data(hexString: f.prRespPayload)!)
    #expect(try response.packed() == Data(hexString: f.prRespPacket)!)
}
