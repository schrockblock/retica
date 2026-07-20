import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Build a raw HEADER_1 ANNOUNCE packet for a synthetic identity.
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

// Mock TCPConnection returning a caller-driven event stream. @MainActor because it builds a
// TestStore (which is main-actor-isolated); tests end deterministically via .disconnect.
@MainActor
private func makeStore(host: String = "node", port: UInt16 = 4242)
    -> (TestStore<Endpoint.State, Endpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
    let events = AsyncStream<TCPEvent>.makeStream()
    let store = TestStore(
        initialState: Endpoint.State(host: host, port: port, reconnectOnDrop: false)
    ) {
        Endpoint()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in events.stream }, send: { _ in }, close: { })
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return (store, events.continuation)
}

@Test @MainActor func connectWiresInterfaceOnlineToTransportInterfaceConnected() async {
    let (store, events) = makeStore()
    await store.send(.connect)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)
    #expect(store.state.transport.interfaces.contains(store.state.interfaceID))
    #expect(store.state.interface.status == .online)
    await store.send(.disconnect)
    await store.receive(\.interface.disconnect)
}

@Test @MainActor func inboundAnnounceIsLearnedAndBubblesPathLearned() async {
    let (store, events) = makeStore()
    let id = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                                     hops: 3, emitted: 1000, appData: Data("meta".utf8))
    await store.send(.connect)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    events.yield(.data(HDLC.frame(announceRaw)))
    await store.receive(\.delegate.pathLearned)
    #expect(store.state.transport.learned[destHash]?.identity.hash == id.hash)
    #expect(store.state.transport.learned[destHash]?.hops == 3)
    #expect(store.state.transport.learned[destHash]?.interfaceID == store.state.interfaceID)
    await store.send(.disconnect)
    await store.receive(\.interface.disconnect)
}

@Test @MainActor func inboundDataToLocalDestinationBubblesMessageReceived() async {
    let (store, events) = makeStore()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["inbox"],
                           identity: Identity())!
    let plaintext = Data("hello".utf8)
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: dest.hash, transportId: nil, payload: dest.encrypt(plaintext))

    await store.send(.registerLocalDestination(dest))
    await store.send(.connect)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    events.yield(.data(HDLC.frame(try! packet.packed())))
    let captured = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.messageReceived(_, p)) = action { captured.setValue(p); return true }
        return false
    }
    #expect(captured.value == plaintext)
    await store.send(.disconnect)
    await store.receive(\.interface.disconnect)
}

@Test @MainActor func outboundAnnounceReachesInterfaceSendAsValidPacket() async {
    let (store, events) = makeStore()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["me"],
                           identity: Identity())!
    await store.send(.registerLocalDestination(dest))
    await store.send(.connect)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    // Capture the raw packet bytes forwarded to the interface's .send (unframed).
    let captured = LockIsolated<Data?>(nil)
    await store.send(.announce(destinationHash: dest.hash, appData: nil))
    await store.receive { action in
        if case let .interface(.send(raw)) = action { captured.setValue(raw); return true }
        return false
    }
    let packet = Packet(raw: captured.value!)!
    #expect(packet.packetType == .announce)
    #expect(packet.destinationHash == dest.hash)
    let parsed = Announce.parse(payload: packet.payload, destinationHash: dest.hash,
                                contextFlagSet: packet.contextFlag)
    #expect(parsed?.identity.hash == dest.identity!.hash)
    await store.send(.disconnect)
    await store.receive(\.interface.disconnect)
}

@Test @MainActor func sendToUnlearnedDestinationBubblesSendFailed() async {
    let (store, events) = makeStore()
    let destHash = Data(repeating: 0x33, count: 16)
    await store.send(.connect)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    await store.send(.send(destinationHash: destHash, plaintext: Data("x".utf8)))
    await store.receive(.delegate(.sendFailed(destinationHash: destHash, reason: .notLearned)))
    await store.send(.disconnect)
    await store.receive(\.interface.disconnect)
}

@Test @MainActor func inboundLinkRequestCreatesResponderAndEmitsProof() async {
    let (store, events) = makeStore()
    let owner = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: owner)!
    await store.send(.registerLocalDestination(dest))
    await store.send(.connect)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    // Craft an inbound LINKREQUEST to our local destination.
    let initEph = Identity()
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: dest.hash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    let captured = LockIsolated<Data?>(nil)   // the LRPROOF bytes sent to the interface
    events.yield(.data(HDLC.frame(try! request.packed())))
    await store.receive(\.transport.received)
    await store.receive(\.transport.delegate.linkRequest)
    await store.receive { action in
        if case let .link(.element(_, .delegate(.transmit(_, raw)))) = action { return true }
        return false
    }
    await store.receive { action in
        if case let .interface(.send(raw)) = action { captured.setValue(raw); return true }
        return false
    }
    #expect(store.state.links.count == 1)
    #expect(Packet(raw: captured.value!)!.packetType == .proof)

    await store.send(.disconnect)
    await store.receive(\.interface.disconnect)
}

@Test @MainActor func inboundLinkPacketRoutesToHeldLink() async {
    // Build a responder link (as above) so the collection holds one link, then feed a link packet
    // addressed to its link_id and assert it is routed to that element.
    let (store, events) = makeStore()
    let owner = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: owner)!
    await store.send(.registerLocalDestination(dest))
    await store.send(.connect)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    let initEph = Identity()
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: dest.hash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    events.yield(.data(HDLC.frame(try! request.packed())))
    await store.receive(\.transport.received)
    await store.receive(\.transport.delegate.linkRequest)
    await store.receive { if case .link(.element(_, .delegate(.transmit))) = $0 { return true }; return false }
    await store.receive { if case .interface(.send) = $0 { return true }; return false }
    let linkID = store.state.links[0].linkID
    #expect(store.state.links[0].status == .handshake)

    // Feed a garbage link-data packet addressed to this link_id; it must route to the element
    // (which will fail to decrypt and stay in .handshake — the point is the routing, not the payload).
    let linkPacket = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                            destinationType: .link, context: .none, contextFlag: false, hops: 0,
                            destinationHash: linkID, transportId: nil, payload: Data(repeating: 0xEE, count: 48))
    let routed = LockIsolated(false)
    events.yield(.data(HDLC.frame(try! linkPacket.packed())))
    await store.receive(\.transport.received)
    await store.receive(\.transport.delegate.linkPacket)
    await store.receive { action in
        if case let .link(.element(_, .received(d))) = action { routed.setValue(d == (try! linkPacket.packed())); return true }
        return false
    }
    #expect(routed.value == true)

    await store.send(.disconnect)
    await store.receive(\.interface.disconnect)
}
