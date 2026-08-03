import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// A framed HELLO carrying `token` (the wire form the peer sends first on a channel).
private func framedHello(_ token: Data) -> Data {
    try! BLEFraming.frame(BLEHello.pack(version: BLEInterface.protocolVersion, token: token))
}

// Build a raw HEADER_1 ANNOUNCE packet for a synthetic identity (copied from EndpointTests).
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

private let ownToken  = Data(repeating: 0x5A, count: 16)   // the node's own session token
private let peerToken = Data(repeating: 0xC7, count: 16)   // the connected peer's token (≠ own)
private let channel   = BLEChannelID(id: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!)
private let handle    = BLEPeerHandle(id: UUID(uuidString: "22222222-0000-0000-0000-000000000002")!)

/// A single BLEEndpoint store with a controllable mock driver.
@MainActor
private func makeNode() -> (TestStore<BLEEndpoint.State, BLEEndpoint.Action>,
                            AsyncStream<BLEDriverEvent>.Continuation) {
    let events = AsyncStream<BLEDriverEvent>.makeStream()
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
            send: { _, _ in }, closeChannel: { _ in }, stop: { }
        )
    }
    store.exhaustivity = .off
    return (store, events.continuation)
}

/// Start the node and bring one inbound peer (token `peerToken`) online through the
/// real BLEInterface handshake. `.off` receive fast-forwards through the intermediate
/// driverEvent/delegate actions to the endpoint-level `interfaceConnected`.
///
/// Compile-driven adjustment: BLEInterface guards `channelOpened` on `state.status == .online`,
/// which requires `.ready` to be received first (`.start` puts it in `.starting`, not `.online`).
/// The brief's code omitted this step; we yield `.ready` before `.channelOpened`.
@MainActor
private func bringPeerOnline(_ store: TestStore<BLEEndpoint.State, BLEEndpoint.Action>,
                            _ events: AsyncStream<BLEDriverEvent>.Continuation) async {
    await store.send(.start)
    events.yield(.ready)
    events.yield(.channelOpened(channel, handle, direction: .inbound))
    events.yield(.channelData(channel, framedHello(peerToken)))
    await store.receive { if case .transport(.interfaceConnected) = $0 { return true }; return false }
    #expect(store.state.transport.interfaces.contains(bleInterfaceID(peerToken)))
}

/// Cancel the driver stream + maintenance: `.stop` emits `peerOffline`, whose cascade
/// reaches `stopMaintenance`; fast-forward to it.
@MainActor
private func teardown(_ store: TestStore<BLEEndpoint.State, BLEEndpoint.Action>) async {
    await store.send(.stop)
    await store.receive { if case .transport(.stopMaintenance) = $0 { return true }; return false }
}

@Test @MainActor func inboundDataPacketOverBLESurfacesMessageReceived() async {
    let (store, events) = makeNode()
    await bringPeerOnline(store, events)

    // A local destination we own, and a data packet encrypted to it.
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["inbox"],
                           identity: Identity())!
    let plaintext = Data("hello over ble".utf8)
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: dest.hash, transportId: nil, payload: dest.encrypt(plaintext))
    await store.send(.registerLocalDestination(dest))

    // Deliver the crafted packet as framed channel data on the peer's channel.
    events.yield(.channelData(channel, try! BLEFraming.frame(try! packet.packed())))
    let got = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.messageReceived(_, p)) = action { got.setValue(p); return true }
        return false
    }
    #expect(got.value == plaintext)

    await teardown(store)
}

@Test @MainActor func outboundOpportunisticSendRoutesThroughBLEToThePeer() async {
    let (store, events) = makeNode()
    await bringPeerOnline(store, events)

    // Learn a destination from a crafted announce delivered over the peer channel.
    let remote = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: remote, appName: "app",
                                                     aspects: ["svc"], hops: 2, emitted: 1000)
    events.yield(.channelData(channel, try! BLEFraming.frame(announceRaw)))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    #expect(store.state.transport.learned[destHash]?.identity.hash == remote.hash)
    #expect(store.state.transport.learned[destHash]?.interfaceID == bleInterfaceID(peerToken))

    // Opportunistic send → routes through Transport → transmit → ble.send for THIS peer.
    let captured = LockIsolated<(Data, Data)?>(nil)   // (peerToken, raw packet)
    await store.send(.send(destinationHash: destHash, plaintext: Data("ping".utf8)))
    await store.receive { action in
        if case let .ble(.send(peer, packet)) = action { captured.setValue((peer, packet)); return true }
        return false
    }
    #expect(captured.value?.0 == peerToken)
    let outPacket = Packet(raw: captured.value!.1)
    #expect(outPacket?.packetType == .data)
    #expect(outPacket?.destinationHash == destHash)

    await teardown(store)
}
