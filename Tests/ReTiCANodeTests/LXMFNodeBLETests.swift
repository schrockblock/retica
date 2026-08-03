import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Deviation: `framedHello` is identical to BLEEndpointIntegrationTests.swift — same private helper.
private func framedHello(_ token: Data) -> Data {
    try! BLEFraming.frame(BLEHello.pack(version: BLEInterface.protocolVersion, token: token))
}

private let ownToken  = Data(repeating: 0x5A, count: 16)
private let peerToken = Data(repeating: 0xC7, count: 16)
private let channel   = BLEChannelID(id: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!)
private let handle    = BLEPeerHandle(id: UUID(uuidString: "22222222-0000-0000-0000-000000000002")!)

/// An LXMFNode running over BLE, with a controllable mock driver.
@MainActor
private func makeBLENode(_ identity: Identity)
    -> (TestStore<LXMFNode.State, LXMFNode.Action>,
        AsyncStream<BLEDriverEvent>.Continuation,
        LockIsolated<[Data]>) {
    let events = AsyncStream<BLEDriverEvent>.makeStream()
    let sent = LockIsolated<[Data]>([])          // framed bytes handed to the driver
    let store = TestStore(
        initialState: LXMFNode.State(identity: identity, endpoint: BLEEndpoint.State())
    ) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.bleRandomBytes = BLERandomBytesGenerator { _ in ownToken }
        $0.bleDriver = BLEDriver(
            start: { _ in events.stream },
            readDirectory: { _ in }, openChannel: { _, _ in },
            send: { _, data in sent.withValue { $0.append(data) } },
            closeChannel: { _ in }, stop: { }
        )
    }
    store.exhaustivity = .off
    return (store, events.continuation, sent)
}

/// Bring one inbound BLE peer online through the real BLEInterface handshake.
@MainActor
private func bringPeerOnline(_ store: TestStore<LXMFNode.State, LXMFNode.Action>,
                             _ events: AsyncStream<BLEDriverEvent>.Continuation) async {
    await store.send(.endpoint(.start))
    events.yield(.ready)                  // BLEInterface gates channelOpened on .online
    events.yield(.channelOpened(channel, handle, direction: .inbound))
    events.yield(.channelData(channel, framedHello(peerToken)))
    await store.receive { action in
        if case .endpoint(.ble(.transport(.interfaceConnected))) = action { return true }
        return false
    }
}

@MainActor
private func teardown(_ store: TestStore<LXMFNode.State, LXMFNode.Action>) async {
    await store.send(.endpoint(.stop))
    await store.receive { action in
        if case .endpoint(.ble(.transport(.stopMaintenance))) = action { return true }
        return false
    }
}

@Test @MainActor func lxmfNodeOverBLEDeliversAnInboundOpportunisticMessage() async {
    let bIdentity = Identity()                     // us (the receiver)
    let aIdentity = Identity()                     // the sender
    let (store, events, _) = makeBLENode(bIdentity)
    await bringPeerOnline(store, events)

    // We register + announce our lxmf.delivery destination.
    // Deviation: the brief expected `.endpoint(.ble(.send))` (BLEEndpoint.Action.send) but the
    // announce path never dispatches that action; it goes through `.ble(.ble(.send(...)))` (the
    // BLEInterface-level send). We wait for that instead so we know the announce packet has been
    // queued before we deliver the inbound message.
    await store.send(.registerDelivery)
    await store.receive { if case .endpoint(.ble(.ble(.send))) = $0 { return true }; return false }

    // Craft A's opportunistic LXMF message addressed to our delivery destination and deliver
    // it over the peer's channel, exactly as a real peer would.
    let bDeliveryHash = LXMessage.deliveryHash(identityHash: bIdentity.hash)
    let msg = LXMessage.create(source: aIdentity, destinationHash: bDeliveryHash,
                               timestamp: 1700000000.5,
                               title: Data("hi".utf8), content: Data("hello over ble".utf8))
    // Deviation: brief used `identityPublicKey: bIdentity.publicKey` which is not a real param.
    // The Destination init takes `identity: Identity?`. The sender only has the recipient's public
    // key, so we construct a receive-only Identity from the public key for encryption.
    let bPubOnlyIdentity = Identity(publicKey: bIdentity.publicKey)!
    let dest = Destination(kind: .single, direction: .out, appName: LXMessage.appName,
                           aspects: LXMessage.deliveryAspects, identity: bPubOnlyIdentity)!
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: bDeliveryHash, transportId: nil,
                        payload: dest.encrypt(msg.opportunisticPayload))
    events.yield(.channelData(channel, try! BLEFraming.frame(try! packet.packed())))

    let gotContent = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.messageReceived(m, _)) = action { gotContent.setValue(m.content); return true }
        return false
    }
    #expect(gotContent.value == Data("hello over ble".utf8))

    await teardown(store)
}

@Test @MainActor func lxmfNodeOverBLESendsAnOpportunisticMessageToThePeer() async {
    let aIdentity = Identity()                     // us (the sender)
    let bIdentity = Identity()                     // the recipient
    let (store, events, sent) = makeBLENode(aIdentity)
    await bringPeerOnline(store, events)

    // Learn B's delivery destination from an announce arriving over the peer channel.
    // Deviation: brief used `direction: .in` for the announce dest; real Destination for
    // announces uses `direction: .in` (inbound, the recipient registers it as inbound).
    let bDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                            aspects: LXMessage.deliveryAspects, identity: bIdentity)!
    let nameHash = Destination.nameHash(appName: LXMessage.appName, aspects: LXMessage.deliveryAspects)
    let randomHash = Announce.randomHash(now: 1_700_000_000, randomPrefix: Data(repeating: 0xA5, count: 5))
    let payload = Announce.buildPayload(identity: bIdentity, destinationHash: bDest.hash,
                                        nameHash: nameHash, randomHash: randomHash, appData: nil)
    let announce = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                          destinationType: .single, context: .none, contextFlag: false, hops: 1,
                          destinationHash: bDest.hash, transportId: nil, payload: payload)
    events.yield(.channelData(channel, try! BLEFraming.frame(try! announce.packed())))
    await store.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // Send an opportunistic LXMF message; it must reach the peer as a framed DATA packet.
    let before = sent.value.count
    await store.send(.send(destinationHash: bDest.hash, title: Data("hi".utf8),
                           content: Data("ping".utf8), method: .opportunistic))
    await store.receive { if case .endpoint(.ble(.send)) = $0 { return true }; return false }
    #expect(sent.value.count > before)
    // The driver receives FRAMED bytes; drop the 2-byte framing header to get the raw packet.
    let raw = Data(sent.value.last!.dropFirst(BLEFraming.headerLength))
    let outPacket = Packet(raw: raw)
    #expect(outPacket?.packetType == .data)
    #expect(outPacket?.destinationHash == bDest.hash)

    await teardown(store)
}
