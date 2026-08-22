import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Build a raw HEADER_1 ANNOUNCE packet for a synthetic identity (mirrors TCPEndpointTests).
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

/// A `TransportEndpoint.State` running a single TCP-server (listener) driver.
private func tcpServerDriverEndpoint(port: UInt16 = 4242,
                                     profile: InterfaceProfile = .tcp) -> TransportEndpoint.State {
    .tcpServer(TCPServerEndpoint.State(port: port, profile: profile))
}

// MARK: - E2E: a listening endpoint and a dialling endpoint peer over IP, no hub.

/// The payoff of the slice: one `TransportEndpoint` LISTENS (tcpServer slot), another DIALS
/// (tcpClient slot). Bytes the server writes are fed into the client's connection stream and vice
/// versa, so a packet routes end to end through the SHARED router on each side — server announces,
/// client learns the path, client opens a link, and the LINKREQUEST reaches the server.
@Test @MainActor func listeningAndDiallingEndpointsPeerEndToEnd() async throws {
    let clock = TestClock()
    let serverIdentity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: serverIdentity)!

    // Server side: TCPListener mock. Bytes it "sends" to a connection are captured.
    let sentByServer = LockIsolated<[Data]>([])
    let serverEvents = AsyncStream<TCPListenerEvent>.makeStream()
    let server = TestStore(initialState: tcpServerDriverEndpoint()) {
        TransportEndpoint()
    } withDependencies: {
        $0.tcpListener = TCPListener(
            listen: { _ in serverEvents.stream },
            send: { _, d in sentByServer.withValue { $0.append(d) } },
            close: { _ in },
            stop: { }
        )
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    server.exhaustivity = .off

    // Client side: TCPConnection mock. Bytes it "sends" are captured.
    let sentByClient = LockIsolated<[Data]>([])
    let clientEvents = AsyncStream<TCPEvent>.makeStream()
    let client = TestStore(initialState: tcpDriverEndpoint(host: "server", port: 4242, reconnectOnDrop: false)) {
        TransportEndpoint()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in clientEvents.stream },
                                         send: { d in sentByClient.withValue { $0.append(d) } },
                                         close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    client.exhaustivity = .off

    let conn = TCPConnID(1)

    // Bring both up. Server listens; client dials and connects; server accepts the connection.
    await server.send(.start)
    serverEvents.continuation.yield(.started)
    await server.send(.registerLocalDestination(dest))

    await client.send(.start)
    clientEvents.continuation.yield(.connected)
    await client.receive(\.transport.interfaceConnected)

    serverEvents.continuation.yield(.accepted(conn))
    await server.receive(\.transport.interfaceConnected)
    let serverIfID = tcpServerInterfaceID(conn)
    #expect(server.state.transport.interfaces[serverIfID] == .tcp)

    // 1. Server announces its destination. The framed announce is written to the connection.
    await server.send(.announce(destinationHash: dest.hash, appData: nil))
    let announceFrame = try #require(sentByServer.value.last)

    // 2. That frame arrives at the client → client learns the path over its tcpClient interface.
    clientEvents.continuation.yield(.data(announceFrame))
    await client.receive(\.transport.received)
    await client.receive(\.delegate.pathLearned)

    // 3. Client opens a link → LINKREQUEST written out the client socket.
    await client.send(.openLink(destinationHash: dest.hash))
    await client.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await client.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    let linkRequestFrame = try #require(sentByClient.value.last)

    // 4. That LINKREQUEST arrives at the SERVER over its accepted connection → server routes it,
    //    recognises the local destination, and writes an LRPROOF back out the connection.
    serverEvents.continuation.yield(.data(conn, linkRequestFrame))
    await server.receive(\.transport.received)
    await server.receive(\.transport.delegate.linkRequest)
    await server.receive { if case .tcpServer(.interface(.send)) = $0 { return true }; return false }
    // The proof left over the server's connection: end-to-end routing proven.
    #expect(sentByServer.value.count >= 2)

    await client.send(.stop)
    await server.send(.stop)
}

// MARK: - A second accepted connection is independent of the first.

/// Two connections accepted on ONE server get distinct InterfaceIDs and distinct deframers. A
/// partial (never-closing) frame on connection 1 must not corrupt a complete frame delivered on
/// connection 2 — the per-connection HDLCDeframer keeps them separate.
@Test @MainActor func secondAcceptedConnectionIsIndependentOfTheFirst() async {
    let clock = TestClock()
    let serverEvents = AsyncStream<TCPListenerEvent>.makeStream()
    let server = TestStore(initialState: tcpServerDriverEndpoint()) {
        TransportEndpoint()
    } withDependencies: {
        $0.tcpListener = TCPListener(listen: { _ in serverEvents.stream },
                                     send: { _, _ in }, close: { _ in }, stop: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    server.exhaustivity = .off

    let conn1 = TCPConnID(1)
    let conn2 = TCPConnID(2)

    await server.send(.start)
    serverEvents.continuation.yield(.started)

    // Two connections accepted → two distinct interfaces registered.
    serverEvents.continuation.yield(.accepted(conn1))
    await server.receive(\.transport.interfaceConnected)
    serverEvents.continuation.yield(.accepted(conn2))
    await server.receive(\.transport.interfaceConnected)

    let if1 = tcpServerInterfaceID(conn1)
    let if2 = tcpServerInterfaceID(conn2)
    #expect(if1 != if2)
    #expect(server.state.transport.interfaces[if1] == .tcp)
    #expect(server.state.transport.interfaces[if2] == .tcp)
    #expect(server.state.tcpServer?.connInterfaces[if1] == conn1)
    #expect(server.state.tcpServer?.connInterfaces[if2] == conn2)

    // Two DIFFERENT valid announces, so a corrupted cross-connection deliver is byte-detectable.
    let id1 = Identity()
    let id2 = Identity()
    let (announce1, _) = makeAnnouncePacket(identity: id1, appName: "app", aspects: ["one"],
                                            hops: 3, emitted: 1000)
    let (announce2, _) = makeAnnouncePacket(identity: id2, appName: "app", aspects: ["two"],
                                            hops: 4, emitted: 2000)
    #expect(announce1 != announce2)
    let frame1 = HDLC.frame(announce1)
    let head1 = frame1.prefix(frame1.count / 2)   // opening FLAG + partial body, NO closing FLAG
    let tail1 = frame1.suffix(frame1.count - head1.count)

    // Feed a PARTIAL (open) frame to conn1: nothing deframes yet — it must sit in conn1's OWN
    // buffer. With a shared deframer these bytes would poison the next connection's frame.
    serverEvents.continuation.yield(.data(conn1, Data(head1)))

    // Feed the WHOLE announce2 frame to conn2: with separate deframers it deframes to EXACTLY
    // announce2 on IF2. With a shared deframer conn1's dangling head corrupts this parse.
    let rx2 = LockIsolated<Data?>(nil)
    serverEvents.continuation.yield(.data(conn2, HDLC.frame(announce2)))
    await server.receive { action in
        if case let .transport(.received(rxID, data)) = action, rxID == if2 {
            rx2.setValue(data); return true
        }
        return false
    }
    #expect(rx2.value == announce2)   // byte-exact: conn2 uncorrupted by conn1's partial

    // Now complete conn1's frame with its tail: it deframes to EXACTLY announce1 on IF1.
    let rx1 = LockIsolated<Data?>(nil)
    serverEvents.continuation.yield(.data(conn1, Data(tail1)))
    await server.receive { action in
        if case let .transport(.received(rxID, data)) = action, rxID == if1 {
            rx1.setValue(data); return true
        }
        return false
    }
    #expect(rx1.value == announce1)   // byte-exact: conn1's own buffer reassembled correctly

    await server.send(.stop)
}

// MARK: - Disconnect cleans up without disturbing the other connection.

/// Closing connection 1 removes its InterfaceID from the shared router, fans the disconnect out to
/// the link plane, and drops its deframer — while connection 2's interface, mapping and deframer
/// stay intact and usable.
@Test @MainActor func connectionDisconnectCleansUpWithoutDisturbingTheOther() async {
    let clock = TestClock()
    let serverEvents = AsyncStream<TCPListenerEvent>.makeStream()
    let server = TestStore(initialState: tcpServerDriverEndpoint()) {
        TransportEndpoint()
    } withDependencies: {
        $0.tcpListener = TCPListener(listen: { _ in serverEvents.stream },
                                     send: { _, _ in }, close: { _ in }, stop: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    server.exhaustivity = .off

    let conn1 = TCPConnID(1)
    let conn2 = TCPConnID(2)
    let if1 = tcpServerInterfaceID(conn1)
    let if2 = tcpServerInterfaceID(conn2)

    await server.send(.start)
    serverEvents.continuation.yield(.started)
    serverEvents.continuation.yield(.accepted(conn1))
    await server.receive(\.transport.interfaceConnected)
    serverEvents.continuation.yield(.accepted(conn2))
    await server.receive(\.transport.interfaceConnected)

    #expect(server.state.transport.interfaces[if1] == .tcp)
    #expect(server.state.transport.interfaces[if2] == .tcp)

    // Close connection 1. The disconnect must fan out to the link plane keyed on IF1 (and NOT
    // IF2) — this predicate receive fails if no such action arrives.
    serverEvents.continuation.yield(.closed(conn1, reason: nil))
    await server.receive { action in
        if case let .linkPlane(.interfaceDisconnected(id)) = action { return id == if1 }
        return false
    }

    // IF1 is gone from the router, its mapping and deframer dropped; IF2 fully intact.
    #expect(server.state.transport.interfaces[if1] == nil)
    #expect(server.state.tcpServer?.connInterfaces[if1] == nil)
    #expect(server.state.tcpServer?.interface.deframers[conn1] == nil)
    #expect(server.state.transport.interfaces[if2] == .tcp)
    #expect(server.state.tcpServer?.connInterfaces[if2] == conn2)
    #expect(server.state.tcpServer?.interface.deframers[conn2] != nil)

    // Connection 2 still delivers inbound data after connection 1's teardown.
    let id = Identity()
    let (announceRaw, _) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                              hops: 3, emitted: 1000)
    serverEvents.continuation.yield(.data(conn2, HDLC.frame(announceRaw)))
    await server.receive { action in
        if case let .transport(.received(rxID, _)) = action { return rxID == if2 }
        return false
    }

    await server.send(.stop)
}
