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
    -> (TestStore<TransportEndpoint.State, TransportEndpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
    let events = AsyncStream<TCPEvent>.makeStream()
    let store = TestStore(
        initialState: tcpDriverEndpoint(host: host, port: port, reconnectOnDrop: false)
    ) {
        TransportEndpoint()
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
    await store.send(.start)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)
    #expect(store.state.transport.interfaces[store.state.tcpClient!.interfaceID] == .tcp)
    #expect(store.state.tcpClient!.interface.status == .online)
    await store.send(.stop)
    await store.receive(\.tcpClient.interface.disconnect)
}

@Test @MainActor func inboundAnnounceIsLearnedAndBubblesPathLearned() async {
    let (store, events) = makeStore()
    let id = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                                     hops: 3, emitted: 1000, appData: Data("meta".utf8))
    await store.send(.start)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    events.yield(.data(HDLC.frame(announceRaw)))
    await store.receive(\.delegate.pathLearned)
    #expect(store.state.transport.learned[destHash]?.identity.hash == id.hash)
    #expect(store.state.transport.learned[destHash]?.hops == 3)
    #expect(store.state.transport.learned[destHash]?.interfaceID == store.state.tcpClient!.interfaceID)
    await store.send(.stop)
    await store.receive(\.tcpClient.interface.disconnect)
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
    await store.send(.start)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    events.yield(.data(HDLC.frame(try! packet.packed())))
    let captured = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.messageReceived(_, p, _, _)) = action { captured.setValue(p); return true }
        return false
    }
    #expect(captured.value == plaintext)
    await store.send(.stop)
    await store.receive(\.tcpClient.interface.disconnect)
}

@Test @MainActor func outboundAnnounceReachesInterfaceSendAsValidPacket() async {
    let (store, events) = makeStore()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["me"],
                           identity: Identity())!
    await store.send(.registerLocalDestination(dest))
    await store.send(.start)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    // Capture the raw packet bytes forwarded to the interface's .send (unframed).
    let captured = LockIsolated<Data?>(nil)
    await store.send(.announce(destinationHash: dest.hash, appData: nil))
    await store.receive { action in
        if case let .tcpClient(.interface(.send(raw))) = action { captured.setValue(raw); return true }
        return false
    }
    let packet = Packet(raw: captured.value!)!
    #expect(packet.packetType == .announce)
    #expect(packet.destinationHash == dest.hash)
    let parsed = Announce.parse(payload: packet.payload, destinationHash: dest.hash,
                                contextFlagSet: packet.contextFlag)
    #expect(parsed?.identity.hash == dest.identity!.hash)
    await store.send(.stop)
    await store.receive(\.tcpClient.interface.disconnect)
}

@Test @MainActor func sendToUnlearnedDestinationBubblesSendFailed() async {
    let (store, events) = makeStore()
    let destHash = Data(repeating: 0x33, count: 16)
    await store.send(.start)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    await store.send(.send(destinationHash: destHash, plaintext: Data("x".utf8)))
    await store.receive(.delegate(.sendFailed(destinationHash: destHash, reason: .notLearned)))
    await store.send(.stop)
    await store.receive(\.tcpClient.interface.disconnect)
}

@Test @MainActor func inboundLinkRequestCreatesResponderAndEmitsProof() async {
    let (store, events) = makeStore()
    let owner = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: owner)!
    await store.send(.registerLocalDestination(dest))
    await store.send(.start)
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
        if case .link(.element(_, .delegate(.transmit))) = action { return true }
        return false
    }
    await store.receive { action in
        if case let .tcpClient(.interface(.send(raw))) = action { captured.setValue(raw); return true }
        return false
    }
    #expect(store.state.links.count == 1)
    #expect(Packet(raw: captured.value!)!.packetType == .proof)

    await store.send(.stop)
    await store.receive(\.tcpClient.interface.disconnect)
}

@Test @MainActor func openLinkToLearnedDestinationEmitsLinkRequest() async {
    let (store, events) = makeStore()
    let id = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                                     hops: 1, emitted: 1000)
    await store.send(.start)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)
    events.yield(.data(HDLC.frame(announceRaw)))
    await store.receive(\.transport.received)
    await store.receive(\.delegate.pathLearned)         // destination learned

    let captured = LockIsolated<Data?>(nil)
    await store.send(.openLink(destinationHash: destHash))
    await store.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await store.receive { if case .link(.element(_, .delegate(.transmit))) = $0 { return true }; return false }
    await store.receive { action in
        if case let .tcpClient(.interface(.send(raw))) = action { captured.setValue(raw); return true }
        return false
    }
    #expect(store.state.links.count == 1)
    #expect(Packet(raw: captured.value!)!.packetType == .linkRequest)

    await store.send(.stop)
    await store.receive(\.tcpClient.interface.disconnect)
}

// F8. `learned` is deliberately NON-destructive: losing the interface does not purge the path,
// so an entry can outlive the interface it names. `Transport.send` already gates on this
// (`reachableLearned`) and `BLEEndpoint.openLink` does too — `TCPEndpoint.openLink` did not, so it
// minted a LinkSession that transmitted into a dead interface and exited only via the 15s
// establishment deadline.
//
// That is not just a slow failure, it is a MISLEADING one: `.establishmentTimedOut` is classified
// PATH-shaped and routes to `pathLostAndClosed`, so a dead SOCKET was being reported as a dead
// ROUTE. On device this looked like "tapping a peer always fails after 15 seconds" whenever the
// connection had dropped.
@Test @MainActor func openLinkOverALostInterfaceFailsFastAsPathStale() async {
    let (store, events) = makeStore()
    let id = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                                     hops: 1, emitted: 1000)
    await store.send(.start)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)
    events.yield(.data(HDLC.frame(announceRaw)))
    await store.receive(\.transport.received)
    await store.receive(\.delegate.pathLearned)

    // The socket drops. The learned entry survives by design — that is the trap.
    events.yield(.disconnected(reason: "socket closed"))
    await store.receive(\.tcpClient.interface.connectionEvent)
    await store.receive(\.transport.interfaceDisconnected)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.transport.learned[destHash] != nil, "learned must survive; the gate is the fix")

    await store.send(.openLink(destinationHash: destHash))
    await store.receive(.delegate(.linkFailed(destinationHash: destHash, reason: .pathStale)))
    #expect(store.state.links.isEmpty, "no LinkSession may be minted against a dead interface")

    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

@Test @MainActor func openLinkToUnlearnedDestinationFails() async {
    let (store, events) = makeStore()
    await store.send(.start)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)
    await store.send(.openLink(destinationHash: Data(repeating: 0x44, count: 16)))
    await store.receive(.delegate(.linkFailed(destinationHash: Data(repeating: 0x44, count: 16), reason: .noPath)))
    #expect(store.state.links.isEmpty)
    await store.send(.stop)
    await store.receive(\.tcpClient.interface.disconnect)
}

@Test @MainActor func inboundLinkPacketRoutesToHeldLink() async {
    // Build a responder link (as above) so the collection holds one link, then feed a link packet
    // addressed to its link_id and assert it is routed to that element.
    let (store, events) = makeStore()
    let owner = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: owner)!
    await store.send(.registerLocalDestination(dest))
    await store.send(.start)
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
    await store.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
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
        if case let .link(.element(_, .received(d, _))) = action { routed.setValue(d == (try! linkPacket.packed())); return true }
        return false
    }
    #expect(routed.value == true)

    await store.send(.stop)
    await store.receive(\.tcpClient.interface.disconnect)
}

@Test @MainActor func twoEndpointsEstablishLinkExchangeDataAndClose() async {
    // TCPEndpoint B owns a destination and announces it; TCPEndpoint A learns it and opens a link.
    let clock = TestClock()
    let bIdentity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: bIdentity)!

    func make(_ host: String, _ sent: LockIsolated<[Data]>) -> (TestStore<TransportEndpoint.State, TransportEndpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: tcpDriverEndpoint(host: host, port: 4242, reconnectOnDrop: false)) {
            TransportEndpoint()
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } },
                                             close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    let sentA = LockIsolated<[Data]>([]); let sentB = LockIsolated<[Data]>([])
    let (a, eventsA) = make("a", sentA)
    let (b, eventsB) = make("b", sentB)

    await a.send(.start); eventsA.yield(.connected); await a.receive(\.transport.interfaceConnected)
    await b.send(.registerLocalDestination(dest))
    await b.send(.start); eventsB.yield(.connected); await b.receive(\.transport.interfaceConnected)

    // 1. B announces; A learns it.
    await b.send(.announce(destinationHash: dest.hash, appData: nil))
    let announceFrame = sentB.value.last!
    eventsA.yield(.data(announceFrame))
    await a.receive(\.transport.received)
    await a.receive(\.delegate.pathLearned)

    // 2. A opens the link → LINKREQUEST out to B.
    await a.send(.openLink(destinationHash: dest.hash))
    await a.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!))                 // LINKREQUEST → B
    await b.receive(\.transport.received)
    await b.receive(\.transport.delegate.linkRequest)
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }  // LRPROOF out

    // 3. B's LRPROOF → A → A active, emits LRRTT.
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }  // LRRTT out
    await a.receive(\.delegate.linkEstablished)
    #expect(a.state.links[0].status == .active)

    // 4. A's LRRTT → B → B active.
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    await b.receive(\.delegate.linkEstablished)
    #expect(b.state.links[0].status == .active)
    #expect(a.state.links[0].linkID == b.state.links[0].linkID)

    // 5. A sends data over the link → B receives it.
    let payload = Data("hello over link".utf8)
    await a.send(.sendOverLink(linkID: a.state.links[0].linkID, data: payload))
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    let gotData = LockIsolated<Data?>(nil)
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    await b.receive { action in
        if case let .delegate(.linkDataReceived(_, d, _)) = action { gotData.setValue(d); return true }
        return false
    }
    #expect(gotData.value == payload)

    // 6. A closes the link → B observes the close.
    await a.send(.closeLink(linkID: a.state.links[0].linkID))
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    await a.receive(\.delegate.linkClosed)
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    await b.receive(\.delegate.linkClosed)
    #expect(a.state.links.isEmpty)      // closed link is removed from the collection
    #expect(b.state.links.isEmpty)      // closed link is removed from the collection

    await a.send(.stop); await b.send(.stop)
}

@Test @MainActor func sendResourceOverLinkDispatchesToTheMatchingLink() async {
    let clock = TestClock()
    let store = TestStore(initialState: {
        var s = tcpDriverEndpoint(host: "n", port: 4242, reconnectOnDrop: false)
        var link = LinkSession.State(id: UUID(0), responderFor: Identity(),
                                     destinationHash: Data(repeating: 0x02, count: 16),
                                     interfaceID: InterfaceID("tcp"))
        link.status = .active
        link.sessionKey = Data(repeating: 0x01, count: 64)
        link.linkID = Data(repeating: 0xAB, count: 16)
        link.rtt = 1.0
        s.linkPlane.links.append(link)
        return s
    }()) { TransportEndpoint() } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    await store.send(.sendResourceOverLink(linkID: Data(repeating: 0xAB, count: 16), data: Data("hi".utf8)))
    await store.receive { if case .link(.element(_, .sendResource)) = $0 { return true }; return false }
    #expect(store.state.links[0].transfers.count == 1)
    // Cleanup: cancel the spawned transfer.
    let tid = store.state.links[0].transfers[0].id
    await store.send(.link(.element(id: UUID(0), action: .transfer(.element(id: tid, action: .cancel)))))
}

@Test @MainActor func resourceReceivedDelegateSurfacesWithLinkID() async {
    let clock = TestClock()
    let linkID = Data(repeating: 0xAB, count: 16)
    let store = TestStore(initialState: {
        var s = tcpDriverEndpoint(host: "n", port: 4242, reconnectOnDrop: false)
        var link = LinkSession.State(id: UUID(0), responderFor: Identity(),
                                     destinationHash: Data(repeating: 0x02, count: 16),
                                     interfaceID: InterfaceID("tcp"))
        link.status = .active; link.sessionKey = Data(repeating: 0x01, count: 64); link.linkID = linkID; link.rtt = 1.0
        s.linkPlane.links.append(link)
        return s
    }()) { TransportEndpoint() } withDependencies: {
        $0.continuousClock = clock; $0.date = .constant(Date(timeIntervalSince1970: 0)); $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    // Simulate the hosted link emitting a resourceReceived delegate.
    let payload = Data("assembled".utf8)
    let got = LockIsolated<(Data, Data)?>(nil)
    await store.send(.link(.element(id: UUID(0), action: .delegate(.resourceReceived(payload)))))
    await store.receive { action in
        if case let .delegate(.resourceReceived(lid, d)) = action { got.setValue((lid, d)); return true }
        return false
    }
    #expect(got.value?.0 == linkID)
    #expect(got.value?.1 == payload)
}

@Test @MainActor func twoEndpointsTransferAResourceOverALink() async {
    let clock = TestClock()
    let bIdentity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: bIdentity)!

    func make(_ host: String, _ sent: LockIsolated<[Data]>) -> (TestStore<TransportEndpoint.State, TransportEndpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: tcpDriverEndpoint(host: host, port: 4242, reconnectOnDrop: false)) {
            TransportEndpoint()
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } },
                                             close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    let sentA = LockIsolated<[Data]>([]); let sentB = LockIsolated<[Data]>([])
    let (a, eventsA) = make("a", sentA)
    let (b, eventsB) = make("b", sentB)

    // --- Establish the link (mirrors twoEndpointsEstablishLinkExchangeDataAndClose steps 1–4) ---
    await a.send(.start); eventsA.yield(.connected); await a.receive(\.transport.interfaceConnected)
    await b.send(.registerLocalDestination(dest))
    await b.send(.start); eventsB.yield(.connected); await b.receive(\.transport.interfaceConnected)
    await b.send(.announce(destinationHash: dest.hash, appData: nil))
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received); await a.receive(\.delegate.pathLearned)
    await a.send(.openLink(destinationHash: dest.hash))
    await a.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received); await b.receive(\.transport.delegate.linkRequest)
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    await a.receive(\.delegate.linkEstablished)
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received); await b.receive(\.delegate.linkEstablished)
    let linkID = a.state.links[0].linkID
    #expect(a.state.links[0].status == .active && b.state.links[0].status == .active)

    // --- A sends a 2-part resource to B; B assembles it; A concludes. ---
    let payload = Data((0..<600).map { UInt8($0 & 0xff) })     // > 1 part at SDU 464, ≤ 4 parts → one window
    await a.send(.sendResourceOverLink(linkID: linkID, data: payload))
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }   // RESOURCE_ADV out
    // ADV → B: spawns a receiver, emits RESOURCE_REQ.
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }   // RESOURCE_REQ out
    // REQ → A: A serves its parts.
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    let partCount = a.state.links[0].transfers[0].parts.count
    for _ in 0..<partCount {
        await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    }
    // Deliver every part frame A emitted (the last `partCount` frames in sentA) to B.
    let parts = Array(sentA.value.suffix(partCount))
    let got = LockIsolated<Data?>(nil)
    for (i, frame) in parts.enumerated() {
        eventsB.yield(.data(frame))
        await b.receive(\.transport.received)
        if i == partCount - 1 {
            await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }   // RESOURCE_PRF out
            await b.receive { action in
                if case let .delegate(.resourceReceived(lid, d)) = action, lid == linkID { got.setValue(d); return true }
                return false
            }
        }
    }
    #expect(got.value == payload)
    #expect(b.state.links[0].transfers.filter { $0.role == .receiver }.isEmpty)  // receiver GC'd on .received
    // PRF → A: A validates and concludes.
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    await a.receive { action in
        if case let .delegate(.resourceConcluded(lid, _)) = action, lid == linkID { return true }
        return false
    }
    #expect(a.state.links[0].transfers.isEmpty)   // sender transfer removed on conclude (GC)

    // Close the link to cancel the link timers, then disconnect.
    await a.send(.closeLink(linkID: linkID))
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    await a.receive(\.delegate.linkClosed)
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received); await b.receive(\.delegate.linkClosed)
    await a.send(.stop); await b.send(.stop)
}

@Test @MainActor func identifyOverLinkDispatchesToTheMatchingLink() async {
    let clock = TestClock()
    let linkID = Data(repeating: 0xAB, count: 16)
    let store = TestStore(initialState: {
        var s = tcpDriverEndpoint(host: "n", port: 4242, reconnectOnDrop: false)
        var link = LinkSession.State(id: UUID(0), initiatorTo: Identity(),
                                     destinationHash: Data(repeating: 0x02, count: 16), interfaceID: InterfaceID("tcp"))
        link.status = .active; link.sessionKey = Data(repeating: 0x01, count: 64); link.linkID = linkID; link.rtt = 1.0
        s.linkPlane.links.append(link)
        return s
    }()) { TransportEndpoint() } withDependencies: {
        $0.continuousClock = clock; $0.date = .constant(Date(timeIntervalSince1970: 0)); $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    await store.send(.identifyOverLink(linkID: linkID, identity: Identity()))
    await store.receive { if case .link(.element(_, .identify)) = $0 { return true }; return false }
}

@Test @MainActor func requestReceivedDelegateSurfacesWithLinkID() async {
    let clock = TestClock()
    let linkID = Data(repeating: 0xAB, count: 16)
    let store = TestStore(initialState: {
        var s = tcpDriverEndpoint(host: "n", port: 4242, reconnectOnDrop: false)
        var link = LinkSession.State(id: UUID(0), responderFor: Identity(),
                                     destinationHash: Data(repeating: 0x02, count: 16), interfaceID: InterfaceID("tcp"))
        link.status = .active; link.sessionKey = Data(repeating: 0x01, count: 64); link.linkID = linkID; link.rtt = 1.0
        s.linkPlane.links.append(link)
        return s
    }()) { TransportEndpoint() } withDependencies: {
        $0.continuousClock = clock; $0.date = .constant(Date(timeIntervalSince1970: 0)); $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    let rid = Data(repeating: 0x11, count: 16); let ph = Data(repeating: 0x22, count: 16)
    let got = LockIsolated<(Data, Data)?>(nil)
    await store.send(.link(.element(id: UUID(0), action: .delegate(.requestReceived(requestID: rid, pathHash: ph, data: Data("x".utf8))))))
    await store.receive { action in
        if case let .delegate(.requestReceived(lid, gotRid, _, _)) = action { got.setValue((lid, gotRid)); return true }
        return false
    }
    #expect(got.value?.0 == linkID)
    #expect(got.value?.1 == rid)
}

@Test @MainActor func twoEndpointsRoundTripALargeRequestAndResponse() async {
    let clock = TestClock()
    let bIdentity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: bIdentity)!

    func make(_ host: String, _ sent: LockIsolated<[Data]>) -> (TestStore<TransportEndpoint.State, TransportEndpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: tcpDriverEndpoint(host: host, port: 4242, reconnectOnDrop: false)) {
            TransportEndpoint()
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } }, close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    let sentA = LockIsolated<[Data]>([]); let sentB = LockIsolated<[Data]>([])
    let (a, eventsA) = make("a", sentA)
    let (b, eventsB) = make("b", sentB)

    // --- Establish the link (same steps as twoEndpointsTransferAResourceOverALink) ---
    await a.send(.start); eventsA.yield(.connected); await a.receive(\.transport.interfaceConnected)
    await b.send(.registerLocalDestination(dest))
    await b.send(.start); eventsB.yield(.connected); await b.receive(\.transport.interfaceConnected)
    await b.send(.announce(destinationHash: dest.hash, appData: nil))
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received); await a.receive(\.delegate.pathLearned)
    await a.send(.openLink(destinationHash: dest.hash))
    await a.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received); await b.receive(\.transport.delegate.linkRequest)
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    await a.receive(\.delegate.linkEstablished)
    eventsB.yield(.data(sentA.value.last!)); await b.receive(\.transport.received); await b.receive(\.delegate.linkEstablished)
    let linkID = a.state.links[0].linkID
    #expect(a.state.links[0].status == .active && b.state.links[0].status == .active)

    // --- A sends a large (>431 packed) request; it rides a Resource. ---
    // reqData/respData: msgpack-encoded binary blobs of sequential bytes. When embedded inline in the
    // wire array the decoded .bin value re-encodes to ~453 bytes, pushing payload > 431 MDU. Using
    // sequential bytes keeps the data moderately incompressible so Bzip2 doesn't reduce stream < SDU.
    let reqData = MsgPack.encode(.bin(Data((0..<450).map { UInt8($0 & 0xff) })))
    let respData = MsgPack.encode(.bin(Data((0..<450).map { UInt8($0 & 0xff) })))

    await a.send(.sendRequestOverLink(linkID: linkID, path: "svc/echo", data: reqData))
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }   // REQ_RESOURCE_ADV out

    // ADV → B: spawns a receiver, emits RESOURCE_REQ.
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }   // RESOURCE_REQ out

    // REQ → A: A serves its parts.
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    let reqPartCount = a.state.links[0].transfers[0].parts.count
    for _ in 0..<reqPartCount {
        await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    }

    // Deliver every part frame A emitted (the last `reqPartCount` frames in sentA) to B.
    let reqParts = Array(sentA.value.suffix(reqPartCount))
    let gotReqID = LockIsolated<Data?>(nil)
    let gotReqData = LockIsolated<Data?>(nil)
    for (i, frame) in reqParts.enumerated() {
        eventsB.yield(.data(frame))
        await b.receive(\.transport.received)
        if i == reqPartCount - 1 {
            // Last part: B sends PRF, then surfaces requestReceived.
            await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }   // RESOURCE_PRF out
            await b.receive { action in
                if case let .delegate(.requestReceived(_, rid, _, d)) = action {
                    gotReqID.setValue(rid); gotReqData.setValue(d); return true
                }
                return false
            }
        }
    }
    #expect(gotReqData.value == reqData)

    // PRF → A: A validates but does NOT emit resourceConcluded at TCPEndpoint level (req/resp suppressed).
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)

    // --- B replies with a large response; it rides a Resource. ---
    await b.send(.sendResponseOverLink(linkID: linkID, requestID: gotReqID.value!, data: respData))
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }   // RESP_RESOURCE_ADV out

    // ADV → A: A's pendingRequests has the requestID, so it accepts the response resource.
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }   // RESOURCE_REQ out

    // REQ → B: B serves its parts.
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    let respPartCount = b.state.links[0].transfers.first(where: { $0.role == .sender && $0.advertisement?.isResponse == true })!.parts.count
    for _ in 0..<respPartCount {
        await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    }

    // Deliver every part frame B emitted (the last `respPartCount` frames in sentB) to A.
    let respParts = Array(sentB.value.suffix(respPartCount))
    let gotRespData = LockIsolated<Data?>(nil)
    for (i, frame) in respParts.enumerated() {
        eventsA.yield(.data(frame))
        await a.receive(\.transport.received)
        if i == respPartCount - 1 {
            // Last part: A sends PRF, then surfaces responseReceived.
            await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }   // RESOURCE_PRF out
            await a.receive { action in
                if case let .delegate(.responseReceived(_, rid, d)) = action, rid == gotReqID.value! {
                    gotRespData.setValue(d); return true
                }
                return false
            }
        }
    }
    #expect(gotRespData.value == respData)

    // PRF → B: B validates but does NOT emit resourceConcluded at TCPEndpoint level (req/resp suppressed).
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)

    await a.send(.stop); await b.send(.stop)
}

@Test @MainActor func twoEndpointsIdentifyAndRoundTripARequest() async {
    let clock = TestClock()
    let aIdentity = Identity()
    let bIdentity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: bIdentity)!

    func make(_ host: String, _ sent: LockIsolated<[Data]>) -> (TestStore<TransportEndpoint.State, TransportEndpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: tcpDriverEndpoint(host: host, port: 4242, reconnectOnDrop: false)) {
            TransportEndpoint()
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } }, close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    let sentA = LockIsolated<[Data]>([]); let sentB = LockIsolated<[Data]>([])
    let (a, eventsA) = make("a", sentA)
    let (b, eventsB) = make("b", sentB)

    // Establish (identical to twoEndpointsEstablishLinkExchangeDataAndClose steps 1–4).
    await a.send(.start); eventsA.yield(.connected); await a.receive(\.transport.interfaceConnected)
    await b.send(.registerLocalDestination(dest))
    await b.send(.start); eventsB.yield(.connected); await b.receive(\.transport.interfaceConnected)
    await b.send(.announce(destinationHash: dest.hash, appData: nil))
    eventsA.yield(.data(sentB.value.last!)); await a.receive(\.transport.received); await a.receive(\.delegate.pathLearned)
    await a.send(.openLink(destinationHash: dest.hash))
    await a.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!)); await b.receive(\.transport.received); await b.receive(\.transport.delegate.linkRequest)
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    eventsA.yield(.data(sentB.value.last!)); await a.receive(\.transport.received)
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    await a.receive(\.delegate.linkEstablished)
    eventsB.yield(.data(sentA.value.last!)); await b.receive(\.transport.received); await b.receive(\.delegate.linkEstablished)
    let linkID = a.state.links[0].linkID

    // A identifies → B surfaces linkIdentified with A's identity.
    await a.send(.identifyOverLink(linkID: linkID, identity: aIdentity))
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    let idHash = LockIsolated<Data?>(nil)
    eventsB.yield(.data(sentA.value.last!)); await b.receive(\.transport.received)
    await b.receive { action in
        if case let .delegate(.linkIdentified(_, id)) = action { idHash.setValue(id.hash); return true }
        return false
    }
    #expect(idHash.value == aIdentity.hash)

    // A requests → B surfaces requestReceived → B responds → A surfaces responseReceived.
    // data must be valid msgpack so it can be embedded inline on the wire.
    let pingData = MsgPack.encode(.string("ping"))
    let pongData = MsgPack.encode(.string("pong"))
    await a.send(.sendRequestOverLink(linkID: linkID, path: "svc/echo", data: pingData))
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    let reqID = LockIsolated<Data?>(nil)
    eventsB.yield(.data(sentA.value.last!)); await b.receive(\.transport.received)
    await b.receive { action in
        if case let .delegate(.requestReceived(_, rid, _, d)) = action, d == pingData { reqID.setValue(rid); return true }
        return false
    }
    await b.send(.sendResponseOverLink(linkID: linkID, requestID: reqID.value!, data: pongData))
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    let respData = LockIsolated<Data?>(nil)
    eventsA.yield(.data(sentB.value.last!)); await a.receive(\.transport.received)
    await a.receive { action in
        if case let .delegate(.responseReceived(_, rid, d)) = action, rid == reqID.value! { respData.setValue(d); return true }
        return false
    }
    #expect(respData.value == pongData)

    await a.send(.stop); await b.send(.stop)
}

// MARK: – Request handler registry + allow-gated auto-response tests

// Build an TCPEndpoint store holding one active link (so requestReceived can be routed), with the given
// registrations and responder. `remoteIdentity` is optional (nil = un-identified peer).
@MainActor
private func endpointWithActiveLink(
    linkID: Data,
    remoteIdentity: Identity?,
    registrations: [Data: RequestRegistration],
    responder: RequestResponder,
    _ clock: TestClock<Duration>
) -> (TestStore<TransportEndpoint.State, TransportEndpoint.Action>, UUID) {
    var s = tcpDriverEndpoint(host: "h", port: 4242, reconnectOnDrop: false)
    let elementID = UUID(0)
    var link = LinkSession.State(id: elementID, responderFor: Identity(),
                                 destinationHash: Data(repeating: 0x02, count: 16), interfaceID: InterfaceID("tcp"))
    link.status = .active
    link.sessionKey = Data(repeating: 0x09, count: 64)
    link.linkID = linkID
    link.remoteIdentity = remoteIdentity
    s.linkPlane.links.append(link)
    s.linkPlane.registrations = registrations
    let store = TestStore(initialState: s) { TransportEndpoint() } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
        $0.requestResponder = responder
    }
    store.exhaustivity = .off
    return (store, elementID)
}

/// A store holding one INITIATOR link still in `.pending` — the shape that establishment
/// failures actually arise from, and the one whose `destinationHash` names a REMOTE peer.
private func endpointWithInitiatorLink(_ clock: TestClock<Duration>)
    -> (TestStore<TransportEndpoint.State, TransportEndpoint.Action>, UUID) {
    var s = tcpDriverEndpoint(host: "h", port: 4242, reconnectOnDrop: false)
    let elementID = UUID(0)
    let link = LinkSession.State(id: elementID, initiatorTo: Identity(),
                                 destinationHash: Data(repeating: 0x03, count: 16),
                                 interfaceID: InterfaceID("tcp"), relayNextHop: nil)
    s.linkPlane.links.append(link)
    let store = TestStore(initialState: s) { TransportEndpoint() } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return (store, elementID)
}

private func pathHash(_ p: String) -> Data { Crypto.truncatedHash(Data(p.utf8)) }

@Test @MainActor func registerThenDeregisterMutatesRegistrations() async {
    let clock = TestClock()
    let store = TestStore(initialState: tcpDriverEndpoint(host: "h", port: 1)) { TransportEndpoint() } withDependencies: {
        $0.continuousClock = clock; $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.registerRequestHandler(path: "svc/echo", policy: .all))
    #expect(store.state.registrations[pathHash("svc/echo")]?.policy == .all)
    #expect(store.state.registrations[pathHash("svc/echo")]?.path == "svc/echo")
    await store.send(.deregisterRequestHandler(path: "svc/echo"))
    #expect(store.state.registrations[pathHash("svc/echo")] == nil)
}

@Test @MainActor func unregisteredRequestForwardsToApp() async {
    let clock = TestClock()
    let called = LockIsolated(false)
    let responder = RequestResponder { _, _, _ in called.setValue(true); return Data() }
    let linkID = Data(repeating: 0xAB, count: 16)
    let (store, _) = endpointWithActiveLink(linkID: linkID, remoteIdentity: nil,
                                            registrations: [:], responder: responder, clock)
    await store.send(.link(.element(id: UUID(0),
        action: .delegate(.requestReceived(requestID: Data([1]), pathHash: pathHash("svc/x"), data: Data([9]))))))
    await store.receive { action in
        if case let .delegate(.requestReceived(lid, rid, ph, d)) = action {
            return lid == linkID && rid == Data([1]) && ph == pathHash("svc/x") && d == Data([9])
        }
        return false
    }
    #expect(called.value == false)     // responder never consulted for an unregistered path
}

@Test @MainActor func allowedRequestAutoRespondsAndDoesNotSurface() async {
    let clock = TestClock()
    let called = LockIsolated(false)
    let responder = RequestResponder { path, data, _ in
        called.setValue(true); return path == "svc/echo" ? data : nil
    }
    let linkID = Data(repeating: 0xAB, count: 16)
    let (store, _) = endpointWithActiveLink(linkID: linkID, remoteIdentity: nil,
        registrations: [pathHash("svc/echo"): RequestRegistration(path: "svc/echo", policy: .all)],
        responder: responder, clock)
    await store.send(.link(.element(id: UUID(0),
        action: .delegate(.requestReceived(requestID: Data([7]), pathHash: pathHash("svc/echo"), data: Data([4, 2]))))))
    await store.receive { action in
        if case let .sendResponseOverLink(lid, rid, d) = action {
            return lid == linkID && rid == Data([7]) && d == Data([4, 2])   // echoed payload
        }
        return false
    }
    #expect(called.value == true)
}

@Test @MainActor func deniedRequestDropsWithoutRespondingOrSurfacing() async {
    let clock = TestClock()
    let called = LockIsolated(false)
    let responder = RequestResponder { _, _, _ in called.setValue(true); return Data([0]) }
    let linkID = Data(repeating: 0xAB, count: 16)
    let (store, _) = endpointWithActiveLink(linkID: linkID, remoteIdentity: nil,
        registrations: [pathHash("svc/secret"): RequestRegistration(path: "svc/secret", policy: .none)],
        responder: responder, clock)
    await store.send(.link(.element(id: UUID(0),
        action: .delegate(.requestReceived(requestID: Data([1]), pathHash: pathHash("svc/secret"), data: Data([9]))))))
    #expect(called.value == false)     // gate blocks before the responder; nothing sent, nothing surfaced
}

@Test @MainActor func listPolicyGatesOnRemoteIdentity() async {
    let clock = TestClock()
    let allowed = Identity()
    let called = LockIsolated(false)
    let responder = RequestResponder { _, data, _ in called.setValue(true); return data }
    let linkID = Data(repeating: 0xAB, count: 16)
    // Peer identity is NOT on the allowed list → denied.
    let (store, _) = endpointWithActiveLink(linkID: linkID, remoteIdentity: Identity(),
        registrations: [pathHash("svc/p"): RequestRegistration(path: "svc/p", policy: .list([allowed.hash]))],
        responder: responder, clock)
    await store.send(.link(.element(id: UUID(0),
        action: .delegate(.requestReceived(requestID: Data([1]), pathHash: pathHash("svc/p"), data: Data([9]))))))
    #expect(called.value == false)
}

// MARK: – E2E auto-answer tests (two live TCPEndpoint stores)

@Test @MainActor func handlerAutoAnswersInlineRequestWithoutSurfacing() async {
    let clock = TestClock()
    let bIdentity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: bIdentity)!

    let sentA = LockIsolated<[Data]>([]); let sentB = LockIsolated<[Data]>([])

    // Build A (initiator): standard make.
    let eventsA_stream = AsyncStream<TCPEvent>.makeStream()
    let a = TestStore(initialState: tcpDriverEndpoint(host: "a", port: 4242, reconnectOnDrop: false)) {
        TransportEndpoint()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in eventsA_stream.stream },
                                         send: { d in sentA.withValue { $0.append(d) } }, close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    a.exhaustivity = .off
    let eventsA = eventsA_stream.continuation

    // Build B (responder): same, plus the echo requestResponder.
    let eventsB_stream = AsyncStream<TCPEvent>.makeStream()
    let b = TestStore(initialState: tcpDriverEndpoint(host: "b", port: 4242, reconnectOnDrop: false)) {
        TransportEndpoint()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in eventsB_stream.stream },
                                         send: { d in sentB.withValue { $0.append(d) } }, close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
        $0.requestResponder = RequestResponder { path, data, _ in path == "svc/echo" ? data : nil }
    }
    b.exhaustivity = .off
    let eventsB = eventsB_stream.continuation

    // Establish link (same as twoEndpointsIdentifyAndRoundTripARequest steps 1–4).
    await a.send(.start); eventsA.yield(.connected); await a.receive(\.transport.interfaceConnected)
    await b.send(.registerLocalDestination(dest))
    await b.send(.start); eventsB.yield(.connected); await b.receive(\.transport.interfaceConnected)
    await b.send(.announce(destinationHash: dest.hash, appData: nil))
    eventsA.yield(.data(sentB.value.last!)); await a.receive(\.transport.received); await a.receive(\.delegate.pathLearned)
    await a.send(.openLink(destinationHash: dest.hash))
    await a.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!)); await b.receive(\.transport.received); await b.receive(\.transport.delegate.linkRequest)
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    eventsA.yield(.data(sentB.value.last!)); await a.receive(\.transport.received)
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    await a.receive(\.delegate.linkEstablished)
    eventsB.yield(.data(sentA.value.last!)); await b.receive(\.transport.received); await b.receive(\.delegate.linkEstablished)
    let linkID = a.state.links[0].linkID

    // Register the handler on B.
    await b.send(.registerRequestHandler(path: "svc/echo", policy: .all))

    // Track whether B ever surfaces delegate.requestReceived.
    let bSurfaced = LockIsolated(false)

    // A sends a small inline request. Must be valid msgpack to survive the wire round-trip.
    let reqPayload = MsgPack.encode(.string("ping"))
    await a.send(.sendRequestOverLink(linkID: linkID, path: "svc/echo", data: reqPayload))
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }

    // Request frame → B: B auto-answers, never surfaces requestReceived.
    // bSurfaced is checked in EVERY B-side predicate so a delegate.requestReceived emitted in any
    // dispatch cycle is caught, not just the one that waits for interface(.send).
    eventsB.yield(.data(sentA.value.last!))
    await b.receive { action in
        if case .delegate(.requestReceived) = action { bSurfaced.setValue(true) }
        if case .transport(.received) = action { return true }
        return false
    }
    // The auto-responder runs as an async .run effect; B emits sendResponseOverLink which routes
    // through link → interface(.send). This scan (plus the transport.received scan above) drains all
    // intervening B actions through the flag-checking predicate, so a requestReceived in any B cycle
    // is caught. Require no requestReceived.
    await b.receive { action in
        if case .delegate(.requestReceived) = action { bSurfaced.setValue(true) }
        if case .tcpClient(.interface(.send)) = action { return true }
        return false
    }
    #expect(bSurfaced.value == false, "B must NOT surface delegate.requestReceived for a registered+allowed path")

    // Response frame → A: A surfaces responseReceived with the echoed payload.
    let gotRespData = LockIsolated<Data?>(nil)
    let gotRespID = LockIsolated<Data?>(nil)
    eventsA.yield(.data(sentB.value.last!)); await a.receive(\.transport.received)
    await a.receive { action in
        if case let .delegate(.responseReceived(_, rid, d)) = action { gotRespID.setValue(rid); gotRespData.setValue(d); return true }
        return false
    }
    #expect(gotRespData.value == reqPayload, "A must receive the exact echoed bytes")

    await a.send(.stop); await b.send(.stop)
}

@Test @MainActor func handlerAutoAnswersWithLargeResourceResponse() async {
    let clock = TestClock()
    let bIdentity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: bIdentity)!

    let sentA = LockIsolated<[Data]>([]); let sentB = LockIsolated<[Data]>([])

    // B's responder returns a >431-byte payload so the response rides a Resource.
    // Must be valid msgpack so it embeds inline on the wire and still exceeds the MDU.
    // A bin(600B) of sequential bytes is moderately incompressible; 603 bytes inline keeps
    // the encrypted stream large enough for 2+ ResourceTransfer parts.
    let largeResponse = MsgPack.encode(.bin(Data((0..<600).map { UInt8($0 & 0xff) })))

    // Build A (initiator).
    let eventsA_stream = AsyncStream<TCPEvent>.makeStream()
    let a = TestStore(initialState: tcpDriverEndpoint(host: "a", port: 4242, reconnectOnDrop: false)) {
        TransportEndpoint()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in eventsA_stream.stream },
                                         send: { d in sentA.withValue { $0.append(d) } }, close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    a.exhaustivity = .off
    let eventsA = eventsA_stream.continuation

    // Build B (responder) with large-response responder.
    let eventsB_stream = AsyncStream<TCPEvent>.makeStream()
    let b = TestStore(initialState: tcpDriverEndpoint(host: "b", port: 4242, reconnectOnDrop: false)) {
        TransportEndpoint()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in eventsB_stream.stream },
                                         send: { d in sentB.withValue { $0.append(d) } }, close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
        $0.requestResponder = RequestResponder { path, _, _ in path == "svc/echo" ? largeResponse : nil }
    }
    b.exhaustivity = .off
    let eventsB = eventsB_stream.continuation

    // Establish link (same steps as above).
    await a.send(.start); eventsA.yield(.connected); await a.receive(\.transport.interfaceConnected)
    await b.send(.registerLocalDestination(dest))
    await b.send(.start); eventsB.yield(.connected); await b.receive(\.transport.interfaceConnected)
    await b.send(.announce(destinationHash: dest.hash, appData: nil))
    eventsA.yield(.data(sentB.value.last!)); await a.receive(\.transport.received); await a.receive(\.delegate.pathLearned)
    await a.send(.openLink(destinationHash: dest.hash))
    await a.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!)); await b.receive(\.transport.received); await b.receive(\.transport.delegate.linkRequest)
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    eventsA.yield(.data(sentB.value.last!)); await a.receive(\.transport.received)
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    await a.receive(\.delegate.linkEstablished)
    eventsB.yield(.data(sentA.value.last!)); await b.receive(\.transport.received); await b.receive(\.delegate.linkEstablished)
    let linkID = a.state.links[0].linkID

    // Register the handler on B.
    await b.send(.registerRequestHandler(path: "svc/echo", policy: .all))

    // A sends a small inline request (only the RESPONSE is large). Must be valid msgpack.
    await a.send(.sendRequestOverLink(linkID: linkID, path: "svc/echo", data: MsgPack.encode(.string("ping"))))
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }

    // Request frame → B: B auto-answers with the large response, which rides a Resource.
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    // B emits RESOURCE_ADV for the large response (not an interface(.send) from inline).
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }   // RESP_RESOURCE_ADV out

    // ADV → A: A's pendingRequests has the requestID, so it accepts the response resource and emits RESOURCE_REQ.
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }   // RESOURCE_REQ out

    // REQ → B: B serves its parts.
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    let respPartCount = b.state.links[0].transfers.first(where: { $0.role == .sender && $0.advertisement?.isResponse == true })!.parts.count
    #expect(respPartCount > 1, "Large auto-response must ride a genuinely multi-part Resource")
    for _ in 0..<respPartCount {
        await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    }

    // Deliver every part frame B emitted (last `respPartCount` frames in sentB) to A.
    let respParts = Array(sentB.value.suffix(respPartCount))
    let gotRespData = LockIsolated<Data?>(nil)
    for (i, frame) in respParts.enumerated() {
        eventsA.yield(.data(frame))
        await a.receive(\.transport.received)
        if i == respPartCount - 1 {
            // Last part: A sends PRF then surfaces responseReceived.
            await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }   // RESOURCE_PRF out
            await a.receive { action in
                if case let .delegate(.responseReceived(_, _, d)) = action { gotRespData.setValue(d); return true }
                return false
            }
        }
    }
    #expect(gotRespData.value == largeResponse, "A must receive the exact large bytes from the in-library handler")
    #expect(largeResponse.count > 431, "Response payload must exceed 431 bytes to verify the Resource path")

    // PRF → B: B validates.
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)

    await a.send(.stop); await b.send(.stop)
}

// MARK: – Multi-segment (>maxEfficientSize) end-to-end round-trip

/// SHA256-derived incompressible bytes for the multi-segment E2E test: bzip2 cannot shrink them,
/// so the payload genuinely exceeds maxEfficientSize post-compression and stays 2 segments.
private func incompressibleData(count: Int) -> Data {
    var result = Data()
    var i = 0
    while result.count < count {
        let chunk = Crypto.fullHash(Data([UInt8(i & 0xff), UInt8((i >> 8) & 0xff), UInt8((i >> 16) & 0xff), 0x7A]))
        result.append(contentsOf: chunk.prefix(min(chunk.count, count - result.count)))
        i += 1
    }
    return result
}

/// Given an HDLC-framed RESOURCE_REQ packet (as stored in sentA/sentB after
/// `await Task.yield()` has flushed the async tcpConnection.send write) and the link session key,
/// returns how many frames the sender will emit: one per requested map-hash, plus one RESOURCE_HMU
/// if the request is exhausted (0xFF flag).
private func countExpectedSenderFrames(reqFrame: Data, sessionKey: Data) -> Int {
    var deframer = HDLCDeframer()
    let frames = deframer.ingest(reqFrame)
    guard let rawPacket = frames.first,
          let packet = Packet(raw: rawPacket),
          let plain = Link.decrypt(packet.payload, sessionKey: sessionKey)
    else { return 0 }
    let p = Data(plain)
    guard let flag = p.first else { return 0 }
    let exhausted = flag == 0xFF
    let pad = exhausted ? 5 : 1
    let reqBytes = max(0, p.count - pad - 32)
    let parts = reqBytes / 4
    return parts + (exhausted ? 1 : 0)
}

@Test @MainActor func twoEndpointsTransferMultiSegmentResourceOverALink() async {
    let clock = TestClock()
    let bIdentity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: bIdentity)!

    func make(_ host: String, _ sent: LockIsolated<[Data]>) -> (TestStore<TransportEndpoint.State, TransportEndpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: tcpDriverEndpoint(host: host, port: 4242, reconnectOnDrop: false)) {
            TransportEndpoint()
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } },
                                             close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    let sentA = LockIsolated<[Data]>([]); let sentB = LockIsolated<[Data]>([])
    let (a, eventsA) = make("a", sentA)
    let (b, eventsB) = make("b", sentB)

    // --- Establish the link (mirrors twoEndpointsTransferAResourceOverALink steps 1–4) ---
    await a.send(.start); eventsA.yield(.connected); await a.receive(\.transport.interfaceConnected)
    await b.send(.registerLocalDestination(dest))
    await b.send(.start); eventsB.yield(.connected); await b.receive(\.transport.interfaceConnected)
    await b.send(.announce(destinationHash: dest.hash, appData: nil))
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received); await a.receive(\.delegate.pathLearned)
    await a.send(.openLink(destinationHash: dest.hash))
    await a.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received); await b.receive(\.transport.delegate.linkRequest)
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    await a.receive(\.delegate.linkEstablished)
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received); await b.receive(\.delegate.linkEstablished)
    let linkID = a.state.links[0].linkID
    let sessionKey = a.state.links[0].sessionKey
    #expect(a.state.links[0].status == .active && b.state.links[0].status == .active)

    // --- A sends a 2-segment resource (> maxEfficientSize) to B ---
    // Use incompressible data so the payload stays above the threshold post-compression.
    // K = 400 bytes → segment 2 encodes to 1 part at SDU 464; one REQ/serve round for seg2.
    let k = 400
    let payload = incompressibleData(count: LinkSession.maxEfficientSize + k)
    #expect(payload.count == LinkSession.maxEfficientSize + k)

    await a.send(.sendResourceOverLink(linkID: linkID, data: payload))
    // A emits ADV for segment 1 immediately.
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    // Task.yield() lets the async .run { tcpConnection.send(framed) } task write sentA.value.last.
    await Task.yield()
    #expect(a.state.links[0].transfers.count == 1)
    let seg1Adv = a.state.links[0].transfers[0].advertisement!
    #expect(seg1Adv.segmentIndex == 1)
    #expect(seg1Adv.totalSegments == 2)
    #expect(seg1Adv.isSplit == true)
    #expect(seg1Adv.dataSize == UInt64(payload.count))

    // --- Pump segment 1 (≈2261 parts at SDU 464, windowed + HMU rounds) ---
    // Deliver seg1 ADV to B.
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    // B spawns a receiver and emits RESOURCE_REQ for the first window.
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    await Task.yield()   // flush tcpConnection.send for the REQ

    // Windowed pump loop: each iteration delivers one window of parts to B.
    // Loops until B's receiver transfer reaches .complete OR countExpectedSenderFrames returns 0
    // (which happens when the PRF is captured in sentB.value.last instead of a REQ).
    // In either case, sentB.value.last! holds the PRF when the loop exits.
    var seg1GuardCount = 0
    while seg1GuardCount < 3000 {
        seg1GuardCount += 1
        let reqFrame = sentB.value.last!
        let n = countExpectedSenderFrames(reqFrame: reqFrame, sessionKey: sessionKey)
        guard n > 0 else { break }   // sentB.value.last! is the PRF — loop is done
        // Deliver the REQ to A; A serves N frames (parts + optional HMU).
        eventsA.yield(.data(reqFrame))
        await a.receive(\.transport.received)
        for _ in 0..<n {
            await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
        }
        // After n interface.send awaits, each .run { tcpConnection.send } has had time to run.
        let frames = Array(sentA.value.suffix(n))
        // Deliver each of A's N frames to B.
        for frame in frames {
            eventsB.yield(.data(frame))
            await b.receive(\.transport.received)
        }
        // Check if seg1 receiver is complete: if so, capture PRF and break.
        let bSeg1 = b.state.links.first?.transfers.first(where: { $0.role == .receiver })
        if bSeg1?.status == .complete {
            // B has already emitted PRF as part of completion. Capture it.
            await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
            await Task.yield()   // flush tcpConnection.send for the PRF
            break
        }
        // B emits the next REQ; flush the async write before reading sentB.value.last.
        await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
        await Task.yield()
    }

    // sentB.value.last! is now the PRF frame (either captured in loop via status check,
    // or via countExpectedSenderFrames returning 0 on the PRF bytes).
    // Deliver it to A so A concludes seg1 and advances to seg2.
    await Task.yield()   // ensure the PRF frame write is flushed
    let prf1Frame = sentB.value.last!
    eventsA.yield(.data(prf1Frame))
    await a.receive(\.transport.received)
    // A concludes segment 1 → segmentedSend advances → emits ADV for segment 2.
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    await Task.yield()

    // --- Pump segment 2 (K = 400 bytes → 1 part at SDU 464, fits in 1 window, no HMU) ---
    eventsB.yield(.data(sentA.value.last!))  // seg2 ADV → B
    await b.receive(\.transport.received)
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }   // REQ out
    await Task.yield()

    let got = LockIsolated<Data?>(nil)
    // Pump seg2 in a windowed loop identical to seg1, but smaller (K=400 → ~1 part).
    // Exit paths:
    //   (a) countExpectedSenderFrames returns 0 → sentB.value.last! is the PRF; break.
    //   (b) receiver transfer is nil (GC'd after .received) → PRF already in queue; break.
    // After the loop, resourceReceived is awaited unconditionally (both paths need it).
    var seg2GuardCount = 0
    while seg2GuardCount < 100 {
        seg2GuardCount += 1
        let seg2ReqFrame = sentB.value.last!
        let seg2n = countExpectedSenderFrames(reqFrame: seg2ReqFrame, sessionKey: sessionKey)
        guard seg2n > 0 else { break }   // sentB.value.last! is a PRF → done
        eventsA.yield(.data(seg2ReqFrame))
        await a.receive(\.transport.received)
        for _ in 0..<seg2n {
            await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
        }
        let seg2Parts = Array(sentA.value.suffix(seg2n))
        for frame in seg2Parts {
            eventsB.yield(.data(frame))
            await b.receive(\.transport.received)
        }
        // Check if receiver transfer is gone (GC'd on .received) or still completing.
        let bSeg2 = b.state.links.first?.transfers.first(where: { $0.role == .receiver })
        if bSeg2 == nil || bSeg2?.status == .complete {
            // Seg2 complete: PRF already in queue or about to be emitted.
            // Await the PRF interface.send so sentB.value.last! becomes the PRF frame.
            await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }   // PRF
            await Task.yield()   // flush tcpConnection.send for PRF
            break
        }
        // Not done yet; B emits next REQ.
        await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
        await Task.yield()
    }
    // resourceReceived fires as B's next delegate action after PRF (split assembly completes).
    await b.receive { action in
        if case let .delegate(.resourceReceived(lid, d)) = action, lid == linkID {
            got.setValue(d); return true
        }
        return false
    }
    #expect(got.value == payload, "B must receive the exact original payload (both segments concatenated)")
    #expect(b.state.links[0].transfers.filter { $0.role == .receiver }.isEmpty,
            "B must have no lingering receiver transfers after multi-segment assembly")

    // PRF for seg2 → A concludes seg2 → surfaces resourceConcluded.
    await Task.yield()   // flush .run { tcpConnection.send(prf2_framed) } from the PRF above
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    await a.receive { action in
        if case .delegate(.resourceConcluded) = action { return true }
        return false
    }
    #expect(a.state.links[0].segmentedSend == nil)

    await a.send(.stop); await b.send(.stop)
}

// MARK: – GC: closed/failed links are removed from the collection

@Test @MainActor func closedLinkIsRemovedFromEndpoint() async {
    let clock = TestClock()
    let linkID = Data(repeating: 0xAB, count: 16)
    let (store, elementID) = endpointWithActiveLink(linkID: linkID, remoteIdentity: nil,
                                                    registrations: [:], responder: .testValue, clock)
    await store.send(.link(.element(id: elementID, action: .delegate(.closed(.initiatorClosed)))))
    await store.receive { action in
        if case let .delegate(.linkClosed(lid, reason)) = action { return lid == linkID && reason == .initiatorClosed }
        return false
    }
    #expect(store.state.links[id: elementID] == nil)           // removed
}

/// A RESPONDER's establishmentFailed removes the element but must NOT surface `linkFailed`.
///
/// For a responder, `destinationHash` is the destination WE serve, not a remote peer, so a
/// `linkFailed` for it would tell the delivery layer that a peer it never contacted is
/// unreachable. The removal still happens — that half is leak prevention and is unconditional.
///
/// ABSENCE ASSERTION — flip-then-send, and the trailing `.off` flip comes AFTER a second send.
/// Teardown reads exhaustivity at CALL time, so flipping back to `.off` before the test ends
/// would tolerate the stray action and make this vacuous (verified: the role-gate mutation
/// passed against exactly that shape). The second `store.send` while still `.on` is what forces
/// the check — it fails with "Must handle 1 received action before sending an action" if the
/// gate let a `linkFailed` through. `.closeLink` on an unknown linkID is the probe: `LinkPlane`
/// guards on a matching link and returns `.none`, so it mutates nothing and starts no effect.
@Test @MainActor func responderEstablishmentFailedRemovesLinkWithoutReportingLinkFailed() async {
    let clock = TestClock()
    let linkID = Data(repeating: 0xAB, count: 16)
    let (store, elementID) = endpointWithActiveLink(linkID: linkID, remoteIdentity: nil,
                                                    registrations: [:], responder: .testValue, clock)
    #expect(store.state.links[id: elementID]?.role == .responder)   // the helper seeds a responder
    store.exhaustivity = .on
    await store.send(.link(.element(id: elementID, action: .delegate(.establishmentFailed(.timedOut))))) {
        $0.linkPlane.links.remove(id: elementID)
    }
    #expect(store.state.links[id: elementID] == nil)           // removed regardless of role
    // F13 Task 2: establishmentFailed now emits localLinkClosed + unregisterLocalLink.
    // Receive them here so the probe send below still fails only if linkFailed leaks.
    await store.receive { if case .linkPlane(.delegate(.localLinkClosed)) = $0 { return true }; return false }
    await store.receive { if case .transport(.unregisterLocalLink) = $0 { return true }; return false }
    await store.send(.closeLink(linkID: Data(repeating: 0xEE, count: 16)))   // probe: no-op
    store.exhaustivity = .off
}

/// An INITIATOR's establishmentFailed names a REMOTE peer, so it does surface `linkFailed`,
/// carrying the kind: a timeout is path-shaped, a rejected handshake is peer-shaped.
@Test @MainActor func initiatorEstablishmentFailedReportsLinkFailedWithKind() async {
    for (kind, expected) in [(LinkSession.EstablishmentFailure.timedOut, LinkFailure.establishmentTimedOut),
                             (.handshakeRejected, .handshakeRejected)] {
        let clock = TestClock()
        let (store, elementID) = endpointWithInitiatorLink(clock)
        let destHash = store.state.links[id: elementID]!.destinationHash
        await store.send(.link(.element(id: elementID, action: .delegate(.establishmentFailed(kind)))))
        await store.receive { action in
            if case let .delegate(.linkFailed(dh, reason)) = action { return dh == destHash && reason == expected }
            return false
        }
        #expect(store.state.links[id: elementID] == nil)       // removed
    }
}

@Test @MainActor func enableRelaySetsTransportIdentity() async {
    let (store, _) = makeStore()
    store.exhaustivity = .off
    let id = Identity()
    await store.send(.enableRelay(id))
    await store.receive(\.transport.setTransportIdentity)
    #expect(store.state.transport.transportIdentity == id)
}

// MARK: – HEADER_2 LINKREQUEST (via-relay) TCPEndpoint wiring

/// Build a raw HEADER_2 ANNOUNCE for `identity`, carrying `transportId` as the relay next hop.
private func makeRelayAnnouncePacket(identity: Identity, appName: String, aspects: [String],
                                     hops: UInt8, emitted: UInt64, transportId: Data) -> (Data, Data) {
    let nameHash = Destination.nameHash(appName: appName, aspects: aspects)
    let destHash = Destination.hash(identityHash: identity.hash, appName: appName, aspects: aspects)
    let randomHash = Announce.randomHash(now: emitted, randomPrefix: Data(repeating: 0xC7, count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, appData: nil)
    let packet = Packet(headerType: .header2, packetType: .announce, transportType: .transport,
                        destinationType: .single, context: .none, contextFlag: false, hops: hops,
                        destinationHash: destHash, transportId: transportId, payload: payload)
    return (try! packet.packed(), destHash)
}

@Test @MainActor func openLinkToRelayedDestinationEmitsHeader2LinkRequest() async {
    // Seed a learned path via a relay: drive a HEADER_2 announce so that
    // learned[dest].nextHop == relayHash (not == destHash).
    // Then openLink → assert the LINKREQUEST emitted is HEADER_2 with transportId == relayHash.
    let (store, events) = makeStore()
    let remoteIdentity = Identity()
    let relayHash = Data(repeating: 0x5A, count: 16)
    let (announceRaw, destHash) = makeRelayAnnouncePacket(identity: remoteIdentity,
                                                          appName: "app", aspects: ["relay-svc"],
                                                          hops: 2, emitted: 2000,
                                                          transportId: relayHash)
    await store.send(.start)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    // Feed the HEADER_2 announce so the path is learned with nextHop == relayHash.
    events.yield(.data(HDLC.frame(announceRaw)))
    await store.receive(\.transport.received)
    await store.receive(\.delegate.pathLearned)
    #expect(store.state.transport.learned[destHash]?.nextHop == relayHash)

    // openLink → LINKREQUEST
    let captured = LockIsolated<Data?>(nil)
    await store.send(.openLink(destinationHash: destHash))
    await store.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await store.receive { if case .link(.element(_, .delegate(.transmit))) = $0 { return true }; return false }
    await store.receive { action in
        if case let .tcpClient(.interface(.send(raw))) = action { captured.setValue(raw); return true }
        return false
    }
    #expect(store.state.links.count == 1)
    let p = Packet(raw: captured.value!)!
    #expect(p.packetType == .linkRequest)
    #expect(p.headerType == .header2)
    #expect(p.transportId == relayHash)
    // Link id parity: the id stored in state == Link.linkID of the packet.
    #expect(store.state.links[0].linkID == Link.linkID(requestPacket: p))

    await store.send(.stop)
    await store.receive(\.tcpClient.interface.disconnect)
}

// MARK: - 3-node A—R—B link end-to-end (Task 4b-2b)

/// Deframe a single packet from an HDLC-framed buffer (as produced by TCPClientInterface.send).
private func deframeOne(_ hdlcFramed: Data) -> Data {
    var df = HDLCDeframer()
    let frames = df.ingest(hdlcFramed)
    return frames[0]
}

@Test @MainActor func threeNodeRelayLinkEstablishesAndCarriesData() async {
    // THE PAYOFF: A (TCPEndpoint/"ar") ↔ R (relay Transport/"ar"+"rb") ↔ B (TCPEndpoint/"rb").
    // Proves that a Reticulum Link establishes end-to-end through a relay (HEADER_2→HEADER_1
    // rewrite) and carries bidirectional encrypted data.
    //
    // Frame relay idiom: Endpoints exchange HDLC-framed data via sentX arrays and event
    // continuations; the relay Transport receives/emits raw (unframed) packets.
    // Bridge: deframe sentX.value.last! before handing to R; HDLC.frame(R's raw transmit)
    // before yielding to A/B events.
    //
    // Required assertions (NOT weakened):
    //   1. Both A and B surface linkEstablished for the SAME link_id.
    //   2. A→B link data arrives at B with the EXACT plaintext.
    //   3. B→A link data arrives at A with the EXACT plaintext.

    let clock = TestClock()
    let rIdentity = Identity()
    let ifAR = InterfaceID("ar")
    let ifRB = InterfaceID("rb")
    let bIdentity = Identity()
    let destB = Destination(kind: .single, direction: .in, appName: "relay", aspects: ["link3"],
                            identity: bIdentity)!

    // Helper: build an TCPEndpoint store with a given interfaceID (not the default "tcp").
    func makeEndpoint(_ host: String, _ ifID: InterfaceID, _ sent: LockIsolated<[Data]>)
        -> (TestStore<TransportEndpoint.State, TransportEndpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
        let evStream = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(
            initialState: tcpDriverEndpoint(host: host, port: 4242, reconnectOnDrop: false,
                                         interfaceID: ifID)
        ) { TransportEndpoint() } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in evStream.stream },
                                             send: { d in sent.withValue { $0.append(d) } },
                                             close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, evStream.continuation)
    }

    let sentA = LockIsolated<[Data]>([])
    let sentB = LockIsolated<[Data]>([])
    let (a, eventsA) = makeEndpoint("node-a", ifAR, sentA)
    let (b, eventsB) = makeEndpoint("node-b", ifRB, sentB)

    // Node R: relay Transport with both interfaces.
    let storeR = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = ImmediateClock()
    }
    storeR.exhaustivity = .off
    await storeR.send(.interfaceConnected(ifAR, .default))
    await storeR.send(.interfaceConnected(ifRB, .default))
    await storeR.send(.setTransportIdentity(rIdentity))

    // Connect A and B.
    await b.send(.registerLocalDestination(destB))
    await a.send(.start)
    eventsA.yield(.connected)
    await a.receive(\.transport.interfaceConnected)
    await b.send(.start)
    eventsB.yield(.connected)
    await b.receive(\.transport.interfaceConnected)

    // ── Step 1: B announces D → R rebroadcasts → A learns D via R ────────────────────────────
    await b.send(.announce(destinationHash: destB.hash, appData: nil))
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    let bAnnounceRaw = deframeOne(sentB.value.last!)

    // R receives B's HEADER_1 announce on "rb", rebroadcasts as HEADER_2 on "ar".
    let rRebroadcastRaw = LockIsolated<Data?>(nil)
    await storeR.send(.received(ifRB, bAnnounceRaw))
    await storeR.receive { action in
        if case .delegate(.pathLearned) = action { return true }
        return false
    }
    await storeR.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action, ifID == ifAR {
            rRebroadcastRaw.setValue(raw)
            return true
        }
        return false
    }
    await storeR.receive { if case .delegate(.transmit) = $0 { return true }; return false } // retry re-broadcast

    // A receives R's rebroadcast and learns D with nextHop == rIdentity.hash.
    eventsA.yield(.data(HDLC.frame(rRebroadcastRaw.value!)))
    await a.receive(\.transport.received)
    await a.receive(\.delegate.pathLearned)
    #expect(a.state.transport.learned[destB.hash]?.nextHop == rIdentity.hash)

    // ── Step 2: A opens a link → HEADER_2 LINKREQUEST → R → B ────────────────────────────────
    await a.send(.openLink(destinationHash: destB.hash))
    await a.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await a.receive { if case .link(.element(_, .delegate(.transmit))) = $0 { return true }; return false }
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    let aLinkRequestRaw = deframeOne(sentA.value.last!)
    let lrPacket = Packet(raw: aLinkRequestRaw)!
    #expect(lrPacket.headerType == .header2)
    #expect(lrPacket.transportId == rIdentity.hash)

    // R receives HEADER_2 LINKREQUEST on "ar"; records linkTable; forwards HEADER_1 to B on "rb".
    let rToB_LR = LockIsolated<Data?>(nil)
    await storeR.send(.received(ifAR, aLinkRequestRaw))
    await storeR.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action, ifID == ifRB {
            rToB_LR.setValue(raw)
            return true
        }
        return false
    }
    let fwdLR = Packet(raw: rToB_LR.value!)!
    #expect(fwdLR.headerType == .header1)
    #expect(fwdLR.destinationHash == destB.hash)
    // linkTable must be populated with the link_id.
    let linkID = Link.linkID(requestPacket: lrPacket)
    #expect(storeR.state.linkTable[linkID] != nil)

    // B receives HEADER_1 LINKREQUEST → creates responder LinkSession → emits LRPROOF.
    eventsB.yield(.data(HDLC.frame(rToB_LR.value!)))
    await b.receive(\.transport.received)
    await b.receive(\.transport.delegate.linkRequest)
    await b.receive { if case .link(.element(_, .delegate(.transmit))) = $0 { return true }; return false }
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    let bProofRaw = deframeOne(sentB.value.last!)
    let proofPkt = Packet(raw: bProofRaw)!
    #expect(proofPkt.destinationType == .link)
    #expect(proofPkt.destinationHash == linkID)

    // ── Step 3: LRPROOF B→R→A → A active, emits LRRTT ───────────────────────────────────────
    let rToA_Proof = LockIsolated<Data?>(nil)
    await storeR.send(.received(ifRB, bProofRaw))
    await storeR.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action, ifID == ifAR {
            rToA_Proof.setValue(raw)
            return true
        }
        return false
    }

    eventsA.yield(.data(HDLC.frame(rToA_Proof.value!)))
    await a.receive(\.transport.received)
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }  // LRRTT out
    await a.receive(\.delegate.linkEstablished)
    #expect(a.state.links[0].status == .active)
    let aLinkID = a.state.links[0].linkID
    let aRTTRaw = deframeOne(sentA.value.last!)

    // ── Step 4: LRRTT A→R→B → B active ──────────────────────────────────────────────────────
    let rToB_RTT = LockIsolated<Data?>(nil)
    await storeR.send(.received(ifAR, aRTTRaw))
    await storeR.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action, ifID == ifRB {
            rToB_RTT.setValue(raw)
            return true
        }
        return false
    }

    eventsB.yield(.data(HDLC.frame(rToB_RTT.value!)))
    await b.receive(\.transport.received)
    await b.receive(\.delegate.linkEstablished)
    #expect(b.state.links[0].status == .active)
    let bLinkID = b.state.links[0].linkID

    // REQUIRED: both sides agree on the same link_id.
    #expect(aLinkID == bLinkID)

    // ── Step 5: A sends data over link → relay → B ───────────────────────────────────────────
    let atobPayload = Data("hello from A via relay".utf8)
    await a.send(.sendOverLink(linkID: aLinkID, data: atobPayload))
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    let aDataRaw = deframeOne(sentA.value.last!)

    let rToB_Data = LockIsolated<Data?>(nil)
    await storeR.send(.received(ifAR, aDataRaw))
    await storeR.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action, ifID == ifRB {
            rToB_Data.setValue(raw)
            return true
        }
        return false
    }

    let gotAtoBData = LockIsolated<Data?>(nil)
    eventsB.yield(.data(HDLC.frame(rToB_Data.value!)))
    await b.receive(\.transport.received)
    await b.receive { action in
        if case let .delegate(.linkDataReceived(lid, d, _)) = action, lid == bLinkID {
            gotAtoBData.setValue(d)
            return true
        }
        return false
    }
    // REQUIRED: A→B data arrives at B with the EXACT plaintext.
    #expect(gotAtoBData.value == atobPayload)

    // ── Step 6: B sends data over link → relay → A ───────────────────────────────────────────
    let btoaPayload = Data("hello from B via relay".utf8)
    await b.send(.sendOverLink(linkID: bLinkID, data: btoaPayload))
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    let bDataRaw = deframeOne(sentB.value.last!)

    let rToA_Data = LockIsolated<Data?>(nil)
    await storeR.send(.received(ifRB, bDataRaw))
    await storeR.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action, ifID == ifAR {
            rToA_Data.setValue(raw)
            return true
        }
        return false
    }

    let gotBtoAData = LockIsolated<Data?>(nil)
    eventsA.yield(.data(HDLC.frame(rToA_Data.value!)))
    await a.receive(\.transport.received)
    await a.receive { action in
        if case let .delegate(.linkDataReceived(lid, d, _)) = action, lid == aLinkID {
            gotBtoAData.setValue(d)
            return true
        }
        return false
    }
    // REQUIRED: B→A data arrives at A with the EXACT plaintext.
    #expect(gotBtoAData.value == btoaPayload)

    await a.send(.stop)
    await b.send(.stop)
}

// MARK: - 4b-3c-2 maintenance lifecycle

/// Connecting an TCPEndpoint starts the maintenance tick: a learned path is swept once it ages past
/// pathExpiry and the tick fires. (End-to-end proof the TCPEndpoint auto-started GC.)
@Test @MainActor func endpointStartsGcOnConnectAndSweepsExpiredPath() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let events = AsyncStream<TCPEvent>.makeStream()
    let store = TestStore(initialState: tcpDriverEndpoint(host: "h", port: 4242, reconnectOnDrop: false)) {
        TransportEndpoint()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in events.stream }, send: { _ in }, close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.transportDate = DateGenerator { now.value }
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    let id = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                                     hops: 3, emitted: 1000)
    await store.send(.start)
    events.continuation.yield(.connected)               // → interfaceConnected + startMaintenance
    await store.receive(\.transport.interfaceConnected)
    events.continuation.yield(.data(HDLC.frame(announceRaw)))
    await store.receive(\.delegate.pathLearned)
    #expect(store.state.transport.learned[destHash] != nil)
    // Age past pathExpiry and fire the tick → path swept.
    now.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(\.transport.maintenanceTick)
    #expect(store.state.transport.learned[destHash] == nil)
}

/// Disconnecting an TCPEndpoint stops the maintenance tick (the TCPEndpoint forwards .stopMaintenance).
@Test @MainActor func endpointStopsMaintenanceOnDisconnect() async {
    let (store, events) = makeStore()
    await store.send(.start)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)
    events.yield(.disconnected(reason: nil))              // → interfaceDisconnected + stopMaintenance
    await store.receive(\.transport.stopMaintenance)
}

@Test @MainActor func endpointRequestPathForwardsToTransport() async {
    let clock = TestClock()
    let events = AsyncStream<TCPEvent>.makeStream()
    let sent = LockIsolated<[Data]>([])
    let store = TestStore(initialState: tcpDriverEndpoint(host: "a", port: 4242, reconnectOnDrop: false)) {
        TransportEndpoint()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                         send: { d in sent.withValue { $0.append(d) } },
                                         close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.start); events.continuation.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    let dest = Data((0..<16).map { UInt8($0) })
    await store.send(.requestPath(destinationHash: dest))
    await store.receive(\.transport.requestPath)                 // forwarder reaches Transport
    await store.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    #expect(!sent.value.isEmpty)                                 // a path-request packet went out

    await store.send(.stop)
}

// MARK: - #C5 IFAC outbound masking

/// Outbound packets on an IFAC-configured endpoint reach the interface MASKED — the IFAC
/// flag is set and the bytes are longer by the code size. The unprotected content is also
/// verifiable via IFAC.unprotect.
@Test @MainActor func outboundPacketsAreIFACProtected() async {
    let ifac = IFAC(networkName: "xnet", passphrase: nil, size: 16)!
    var profile = InterfaceProfile.tcp
    profile.ifac = ifac

    let events = AsyncStream<TCPEvent>.makeStream()
    let captured = LockIsolated<Data?>(nil)
    let store = TestStore(
        initialState: tcpDriverEndpoint(host: "node", port: 4242, reconnectOnDrop: false, profile: profile)
    ) {
        TransportEndpoint()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                         send: { _ in }, close: { })
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["me"],
                           identity: Identity())!
    await store.send(.registerLocalDestination(dest))
    await store.send(.start)
    events.continuation.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    await store.send(.announce(destinationHash: dest.hash, appData: nil))
    await store.receive { action in
        if case let .tcpClient(.interface(.send(raw))) = action { captured.setValue(raw); return true }
        return false
    }

    let wire = captured.value!
    // IFAC flag must be set in the masked wire bytes (bit 7 of byte 0).
    #expect(wire[0] & 0x80 == 0x80)
    // The wire is longer than a plain announce by the code size.
    // Verify by round-tripping through unprotect and parsing as a valid announce packet.
    let unmasked = ifac.unprotect(wire)
    #expect(unmasked != nil)
    let packet = unmasked.flatMap { Packet(raw: $0) }
    #expect(packet?.packetType == .announce)
    #expect(packet?.destinationHash == dest.hash)

    await store.send(.stop)
    await store.receive(\.tcpClient.interface.disconnect)
}

/// TCP disconnected must fan out `.interfaceDisconnected` to `LinkPlane`, granting links on that
/// interface one unauthenticated re-home. This pins the production wiring: if the
/// `.linkPlane(.interfaceDisconnected(id))` fan-out is removed from the `disconnected` handler,
/// `rehomePermitted` stays false — the mechanism exists in `LinkPlane` but is never triggered
/// from the real endpoint.
///
/// The setup drives a real LINKREQUEST through the TCP data path so the link is created on
/// the endpoint's fixed `interfaceID` — the same interface the disconnect will signal.
@Test @MainActor func tcpDisconnectedSetsRehomePermittedOnLinksForThatInterface() async {
    let owner = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["rehome-test"],
                           identity: owner)!
    let (store, events) = makeStore()
    await store.send(.registerLocalDestination(dest))
    await store.send(.start)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    // Feed a real LINKREQUEST to our local destination over the TCP interface. This creates a
    // responder link bound to the endpoint's fixed InterfaceID.
    let initEph = Identity()
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: dest.hash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    events.yield(.data(HDLC.frame(try! request.packed())))
    await store.receive(\.transport.received)
    await store.receive(\.transport.delegate.linkRequest)
    // Drain the LRPROOF transmit so the responder element is fully created.
    await store.receive { if case .link(.element(_, .delegate(.transmit))) = $0 { return true }; return false }

    guard let element = store.state.linkPlane.links.first(where: { $0.interfaceID == store.state.tcpClient!.interfaceID }) else {
        Issue.record("Expected a responder link bound to the TCP interfaceID")
        return
    }
    let elementID = element.id

    // Before disconnect: rehomePermitted must be false.
    #expect(store.state.linkPlane.links[id: elementID]?.rehomePermitted == false)

    // TCP interface disconnects. This must fan out .interfaceDisconnected to LinkPlane.
    events.yield(.disconnected(reason: nil))
    await store.receive { if case .transport(.interfaceDisconnected) = $0 { return true }; return false }
    // Drain the linkPlane fan-out so the state update is visible before we read rehomePermitted.
    await store.receive { if case .linkPlane(.interfaceDisconnected) = $0 { return true }; return false }

    // After disconnect: rehomePermitted must be true for the link on that interface.
    // If the fan-out is missing, rehomePermitted stays false and this assertion fails.
    #expect(store.state.linkPlane.links[id: elementID]?.rehomePermitted == true,
            "TCP disconnected must fan-out interfaceDisconnected to LinkPlane so rehomePermitted is set")

    await store.send(.stop)
    await store.receive(\.tcpClient.interface.disconnect)
}

// MARK: - Explicit stop deregisters the TCP interface

/// An EXPLICIT `.stop` (a host closing the socket when it goes to the background) must deregister
/// the TCP interface exactly as a dropped socket does. `TCPClientInterface.disconnect` cancels the
/// connection stream silently and emits no `.disconnected` event, so before this arm existed the
/// router kept the interface registered: `interfaces` still held it, links on it never learned the
/// interface was gone, and a host keying "is TCP up?" on `interfaceDisconnected` never re-dialled.
///
/// Mutation: remove the `.tcpClient(.disconnect)` arm from `TransportEndpoint` → no
/// `interfaceDisconnected` is ever emitted → the `receive` below times out and the test fails.
@Test @MainActor func explicitStopDeregistersTheTCPInterface() async {
    let (store, events) = makeStore()
    await store.send(.start)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)
    let id = store.state.tcpClient!.interfaceID
    #expect(store.state.transport.interfaces[id] == .tcp)

    await store.send(.stop)
    await store.receive { if case .transport(.interfaceDisconnected(id)) = $0 { return true }; return false }
    #expect(store.state.transport.interfaces[id] == nil,
            "an explicit stop must deregister the TCP interface like a dropped socket does")
    await store.receive { if case .linkPlane(.interfaceDisconnected(id)) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
}

/// A `.stop` while still CONNECTING (no `interfaceConnected` yet) has nothing to deregister and
/// must not emit a spurious `interfaceDisconnected` — the router never registered the id.
///
/// Mutation: drop the `state.transport.interfaces[id] != nil` guard from the new arm →
/// `interfaceDisconnected` is emitted for an unregistered id → it is still queued when the
/// exhaustive probe is sent, and the probe send fails.
@Test @MainActor func stopWhileConnectingEmitsNoInterfaceDisconnected() async {
    let (store, _) = makeStore()
    await store.send(.start)
    #expect(store.state.transport.interfaces.isEmpty, "nothing is registered before the socket is up")

    await store.send(.stop)
    await store.receive(\.tcpClient.interface.disconnect)
    await store.finish()
    // Exhaustive no-op probe: with exhaustivity on, a send fails if any received action is still
    // pending, so a spurious `interfaceDisconnected` would surface here.
    store.exhaustivity = .on
    await store.send(.delegate(.pathLearned(destinationHash: Data(repeating: 0, count: 16), hops: 0)))
}
