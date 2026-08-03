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

// Build a raw HEADER_1 ANNOUNCE packet for a synthetic identity.
// (Mirrors makeAnnouncePacket in BLEEndpointIntegrationTests; private helpers cannot cross files.)
private func makeAnnouncePacket(identity: Identity, appName: String, aspects: [String],
                                hops: UInt8, emitted: UInt64, appData: Data? = nil) -> (Data, Data) {
    let nameHash = Destination.nameHash(appName: appName, aspects: aspects)
    let destHash = Destination.hash(identityHash: identity.hash, appName: appName, aspects: aspects)
    let randomHash = Announce.randomHash(now: emitted, randomPrefix: Data(repeating: 0xA5, count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, appData: appData)
    let packet = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: hops,
                        destinationHash: destHash, transportId: nil, payload: payload)
    return (try! packet.packed(), destHash)
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
    #expect(store.state.links.count == 1)
    #expect(store.state.links[0].interfaceID == bleInterfaceID(peerToken))
    let last = sent.value.last
    #expect(last?.0 == peerToken)
    // BLEInterface.send frames packets (2-byte big-endian length prefix); unframe before parsing.
    let unframed = last.map { Data($0.1.dropFirst(BLEFraming.headerLength)) }
    #expect(Packet(raw: unframed!)?.packetType == .proof)

    await teardown(store)
}

@Test @MainActor func outboundOpenLinkRidesTheLearnedPeersInterface() async {
    let (store, events, sent) = makeNode()
    await bringPeerOnline(store, events)

    // Learn a destination via a crafted announce delivered on the peer's channel.
    let remote = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: remote, appName: "app",
                                                     aspects: ["svc"], hops: 0, emitted: 1000)
    events.yield(.channelData(channel, try! BLEFraming.frame(announceRaw)))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }

    // openLink must pick the peer's BLE interface from the learned entry.
    await store.send(.openLink(destinationHash: destHash))
    // A LINKREQUEST is emitted as the link begins establishing; wait for the transmit so we
    // know LinkPlane has processed .openLink and state is settled.
    await store.receive { if case .ble(.send) = $0 { return true }; return false }

    // (a) link shim: state.links forwards to linkPlane.links
    #expect(store.state.links.count == 1)
    // (b) the link rides the BLE interface for this peer
    #expect(store.state.links[0].interfaceID == bleInterfaceID(peerToken))
    // (c) the driver received a LINKREQUEST for this peer
    let lastSent = sent.value.last
    #expect(lastSent?.0 == peerToken)
    let unframed = lastSent.map { Data($0.1.dropFirst(BLEFraming.headerLength)) }
    #expect(Packet(raw: unframed!)?.packetType == .linkRequest)

    await store.send(.closeLink(linkID: store.state.links[0].linkID))
    await teardown(store)
}

@Test @MainActor func openLinkToUnlearnedDestinationFailsOverBLE() async {
    let (store, events, _) = makeNode()
    await bringPeerOnline(store, events)

    let unknownDest = Data(repeating: 0x42, count: 16)
    await store.send(.openLink(destinationHash: unknownDest))
    await store.receive { if case .delegate(.linkFailed(let hash)) = $0 { return hash == unknownDest }; return false }
    #expect(store.state.links.isEmpty)

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
