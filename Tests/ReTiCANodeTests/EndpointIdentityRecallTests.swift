import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

@Suite struct EndpointIdentityRecallTests {

/// The endpoint surface recalls what its shared router heard, by destination or identity hash, and a
/// restored known-destination table answers before any announce arrives.
@Test @MainActor func endpointRecallsAnnouncedAndRehydratedIdentities() async {
    let store = TestStore(
        initialState: .tcp(TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    ) {
        TransportEndpoint()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    // Announced this session.
    let heard = Identity()
    let nameHash = Destination.nameHash(appName: "app", aspects: ["svc"])
    let heardDest = Destination.hash(identityHash: heard.hash, appName: "app", aspects: ["svc"])
    let payload = Announce.buildPayload(identity: heard, destinationHash: heardDest, nameHash: nameHash,
                                        randomHash: Announce.randomHash(now: 1, randomPrefix: Data(repeating: 1, count: 5)),
                                        appData: nil)
    let announce = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                          destinationType: .single, context: .none, contextFlag: false, hops: 1,
                          destinationHash: heardDest, transportId: nil, payload: payload)
    #expect(store.state.recall(destinationHash: heardDest) == nil)
    await store.send(.transport(.interfaceConnected(InterfaceID("tcp"), .default)))
    await store.send(.transport(.received(InterfaceID("tcp"), try! announce.packed())))
    #expect(store.state.recall(destinationHash: heardDest)?.publicKey == heard.publicKey)
    #expect(store.state.recall(identityHash: heard.hash)?.publicKey == heard.publicKey)

    // Heard in a previous session, restored by the host.
    let restored = Identity()
    let restoredDest = Destination.hash(identityHash: restored.hash, appName: "app", aspects: ["svc"])
    await store.send(.transport(.rehydrateKnownDestinations([
        restoredDest: KnownDestination(identity: Identity(publicKey: restored.publicKey)!, appData: nil,
                                       lastHeard: Date(timeIntervalSince1970: 0)),
    ])))
    #expect(store.state.knownDestinations[restoredDest] != nil)
    #expect(store.state.recall(destinationHash: restoredDest)?.publicKey == restored.publicKey)
    await store.skipReceivedActions(strict: false)
}

}
