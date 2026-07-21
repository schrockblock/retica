import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

private let resKey = Data(repeating: 0x01, count: 64)
private let resLinkID = Data(repeating: 0xAB, count: 16)

@MainActor
private func activeLinkStore(_ clock: TestClock<Duration>) -> TestStore<LinkSession.State, LinkSession.Action> {
    var s = LinkSession.State(responderFor: Identity(),
                              destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"))
    s.status = .active
    s.sessionKey = resKey
    s.linkID = resLinkID
    s.rtt = 1.0
    let store = TestStore(initialState: s) { LinkSession() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = clock
        $0.uuid = .incrementing
        // randomBytes uses its deterministic testValue by default
    }
    store.exhaustivity = .off
    return store
}

// A sender ResourceTransfer over the same link/key, used to synthesize inbound packets.
private func senderFor(_ data: Data, sdu: Int = 24) -> ResourceTransfer.State {
    ResourceTransfer.State(sending: data, linkID: resLinkID, sessionKey: resKey,
                           interfaceID: InterfaceID("i"), prefix: Data([0, 1, 2, 3]),
                           randomHash: Data([4, 5, 6, 7]), sdu: sdu)
}

private func advPacket(_ s: ResourceTransfer.State) -> Data {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .resourceAdvertisement, contextFlag: false, hops: 0,
                   destinationHash: resLinkID, transportId: nil,
                   payload: Link.encrypt(s.advertisement!.pack(), sessionKey: resKey))
    return try! p.packed()
}

private func partPacket(_ chunk: Data) -> Data {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .resource, contextFlag: false, hops: 0,
                   destinationHash: resLinkID, transportId: nil, payload: chunk)
    return try! p.packed()
}

@Test @MainActor func inboundAdvertisementSpawnsReceiverAndRequests() async {
    let clock = TestClock<Duration>()
    let store = activeLinkStore(clock)
    let sender = senderFor(Data(repeating: 0x33, count: 100))
    await store.send(.received(advPacket(sender)))
    #expect(store.state.transfers.count == 1)
    #expect(store.state.transfers[0].resourceHash == sender.resourceHash)   // set at spawn
    await store.receive { if case .transfer(.element(_, .accept)) = $0 { return true }; return false }
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action, Packet(raw: raw)?.context == .resourceRequest { return true }
        return false
    }
    // Cleanup: cancel the spawned transfer (cancels its watchdog).
    let tid = store.state.transfers[0].id
    await store.send(.transfer(.element(id: tid, action: .cancel)))
}

@Test @MainActor func duplicateAdvertisementDoesNotSpawnSecondTransfer() async {
    let clock = TestClock<Duration>()
    let store = activeLinkStore(clock)
    let sender = senderFor(Data(repeating: 0x33, count: 100))
    await store.send(.received(advPacket(sender)))
    #expect(store.state.transfers.count == 1)
    await store.send(.received(advPacket(sender)))       // sender re-advertise
    #expect(store.state.transfers.count == 1)            // NOT 2
    let tid = store.state.transfers[0].id
    await store.send(.transfer(.element(id: tid, action: .cancel)))
}

@Test @MainActor func inboundPartRoutesToReceiverAndSurfacesResourceReceived() async {
    let clock = TestClock<Duration>()
    let store = activeLinkStore(clock)
    let data = Data("link routes each resource part to the hosted receiver transfer".utf8)
    let sender = senderFor(data)
    await store.send(.received(advPacket(sender)))
    _ = await store.receive { if case .transfer(.element(_, .accept)) = $0 { return true }; return false }
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action, Packet(raw: raw)?.context == .resourceRequest { return true }
        return false
    }
    let got = LockIsolated<Data?>(nil)
    for chunk in sender.parts {
        await store.send(.received(partPacket(chunk)))
    }
    // Once all parts arrive, the receiver assembles and the link surfaces resourceReceived.
    await store.receive { action in
        if case let .delegate(.resourceReceived(d)) = action { got.setValue(d); return true }
        return false
    }
    #expect(got.value == data)
    #expect(store.state.transfers[0].status == .complete)
}

@Test @MainActor func sendResourceSpawnsSenderAndEmitsEncryptedAdvertisement() async {
    let clock = TestClock<Duration>()
    let store = activeLinkStore(clock)
    let data = Data("a resource sent out over the link".utf8)
    await store.send(.sendResource(data))
    #expect(store.state.transfers.count == 1)
    #expect(store.state.transfers[0].role == .sender)
    await store.receive { if case .transfer(.element(_, .advertise)) = $0 { return true }; return false }
    let advOut = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action, Packet(raw: raw)?.context == .resourceAdvertisement {
            advOut.setValue(raw); return true
        }
        return false
    }
    // The advertisement is encrypted with the link key and unpacks to the sender's advertisement.
    let packet = Packet(raw: advOut.value!)!
    let plain = Link.decrypt(packet.payload, sessionKey: resKey)!
    let adv = ResourceAdvertisement.unpack(plain)!
    #expect(adv.hash == store.state.transfers[0].resourceHash)
    // Cleanup: cancel the sender transfer (cancels its advertise watchdog).
    let tid = store.state.transfers[0].id
    await store.send(.transfer(.element(id: tid, action: .cancel)))
}

@Test @MainActor func sendResourceOnInactiveLinkDoesNothing() async {
    let clock = TestClock<Duration>()
    var s = LinkSession.State(responderFor: Identity(),
                              destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"))
    s.status = .pending                                     // not active
    let store = TestStore(initialState: s) { LinkSession() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0)); $0.continuousClock = clock; $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.sendResource(Data("nope".utf8)))
    #expect(store.state.transfers.isEmpty)
}
