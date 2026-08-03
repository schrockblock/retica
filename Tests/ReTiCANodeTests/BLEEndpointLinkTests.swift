import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private func framedHello(_ token: Data) -> Data {
    try! BLEFraming.frame(BLEHello.pack(version: BLEInterface.protocolVersion, token: token))
}

private let ownToken  = Data(repeating: 0x5A, count: 16)
private let peerToken = Data(repeating: 0xC7, count: 16)
private let channel   = BLEChannelID(id: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!)
private let handle    = BLEPeerHandle(id: UUID(uuidString: "22222222-0000-0000-0000-000000000002")!)

@MainActor
private func makeNode() -> (TestStore<BLEEndpoint.State, BLEEndpoint.Action>,
                            AsyncStream<BLEDriverEvent>.Continuation,
                            LockIsolated<[(Data, Data)]>) {
    let events = AsyncStream<BLEDriverEvent>.makeStream()
    let sent = LockIsolated<[(Data, Data)]>([])   // (peerToken, packet)
    let store = TestStore(initialState: BLEEndpoint.State()) {
        BLEEndpoint()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
        $0.bleRandomBytes = BLERandomBytesGenerator { _ in ownToken }
        $0.bleDriver = BLEDriver(
            start: { _ in events.stream },
            readDirectory: { _ in }, openChannel: { _, _ in },
            send: { _, data in sent.withValue { $0.append((peerToken, data)) } },
            closeChannel: { _ in }, stop: { }
        )
    }
    store.exhaustivity = .off
    return (store, events.continuation, sent)
}

/// Bring one inbound peer online through the real BLEInterface handshake.
@MainActor
private func bringPeerOnline(_ store: TestStore<BLEEndpoint.State, BLEEndpoint.Action>,
                             _ events: AsyncStream<BLEDriverEvent>.Continuation) async {
    await store.send(.start)
    events.yield(.ready)                       // BLEInterface gates channelOpened on .online
    events.yield(.channelOpened(channel, handle, direction: .inbound))
    events.yield(.channelData(channel, framedHello(peerToken)))
    await store.receive { if case .transport(.interfaceConnected) = $0 { return true }; return false }
}

@MainActor
private func teardown(_ store: TestStore<BLEEndpoint.State, BLEEndpoint.Action>) async {
    await store.send(.stop)
    await store.receive { if case .transport(.stopMaintenance) = $0 { return true }; return false }
}

@Test @MainActor func inboundLinkRequestOverBLERepliesToThatPeer() async {
    let (store, events, sent) = makeNode()
    await bringPeerOnline(store, events)

    // Register a local destination we own, then feed a crafted LINKREQUEST to it over the peer's channel.
    let owner = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: owner)!
    await store.send(.registerLocalDestination(dest))

    let initEph = Identity()
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: dest.hash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    events.yield(.channelData(channel, try! BLEFraming.frame(try! request.packed())))

    // A responder link is created on the arrival peer's interface, and the LRPROOF goes back to that peer.
    await store.receive { if case .ble(.send) = $0 { return true }; return false }
    #expect(store.state.linkPlane.links.count == 1)
    #expect(store.state.linkPlane.links[0].interfaceID == bleInterfaceID(peerToken))
    let last = sent.value.last
    #expect(last?.0 == peerToken)
    // BLEInterface.send frames packets (2-byte big-endian length prefix); unframe before parsing.
    let unframed = last.map { Data($0.1.dropFirst(BLEFraming.headerLength)) }
    #expect(Packet(raw: unframed!)?.packetType == .proof)

    await teardown(store)
}

@Test @MainActor func linkPlaneTransmitToUnknownPeerIsDropped() async {
    let (store, events, sent) = makeNode()
    await bringPeerOnline(store, events)
    let before = sent.value.count
    // A transmit addressed to an interface with no live peer must not reach the driver.
    await store.send(.linkPlane(.delegate(.transmit(InterfaceID("ble:deadbeef"), Data([0x01])))))
    #expect(sent.value.count == before)
    await teardown(store)
}
