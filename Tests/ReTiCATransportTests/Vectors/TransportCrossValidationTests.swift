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
