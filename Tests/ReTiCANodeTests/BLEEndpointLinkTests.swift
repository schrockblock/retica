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

private let ownToken   = Data(repeating: 0x5A, count: 16)
private let peerToken  = Data(repeating: 0xC7, count: 16)
private let peerTokenB = Data(repeating: 0xD4, count: 16)   // second session token for peer-cycle test
private let channel    = BLEChannelID(id: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!)
private let handle     = BLEPeerHandle(id: UUID(uuidString: "22222222-0000-0000-0000-000000000002")!)
private let channel2   = BLEChannelID(id: UUID(uuidString: "11111111-0000-0000-0000-000000000003")!)
private let handle2    = BLEPeerHandle(id: UUID(uuidString: "22222222-0000-0000-0000-000000000004")!)

/// The driver is handed a `BLEChannelID`, not a token, so the stub resolves the channel back to
/// the peer it belongs to. An unmapped channel yields an empty token — deliberately a value no
/// assertion can match by accident, so a mis-routed send fails loudly rather than silently
/// reading as the default peer.
private let tokenForChannel: [BLEChannelID: Data] = [channel: peerToken, channel2: peerTokenB]

@MainActor
private func makeNode() -> (TestStore<BLEEndpoint.State, BLEEndpoint.Action>,
                            AsyncStream<BLEDriverEvent>.Continuation,
                            LockIsolated<[(Data, Data)]>) {
    let events = AsyncStream<BLEDriverEvent>.makeStream()
    let sent = LockIsolated<[(Data, Data)]>([])   // (peerToken the send actually went to, packet)
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
            send: { chan, data in
                sent.withValue { $0.append((tokenForChannel[chan] ?? Data(), data)) }
            },
            closeChannel: { _ in }, stop: { }
        )
    }
    store.exhaustivity = .off
    return (store, events.continuation, sent)
}

/// Bring one inbound peer online through the real BLEInterface handshake.
/// Parameters default to the file-level constants so existing call sites need no changes.
/// Pass `startFirst: false` when the node is already running (e.g. second peer in a peer-cycle).
@MainActor
private func bringPeerOnline(_ store: TestStore<BLEEndpoint.State, BLEEndpoint.Action>,
                             _ events: AsyncStream<BLEDriverEvent>.Continuation,
                             token: Data = peerToken,
                             channelID: BLEChannelID = channel,
                             peerHandle: BLEPeerHandle = handle,
                             startFirst: Bool = true) async {
    if startFirst {
        await store.send(.start)
        events.yield(.ready)                   // BLEInterface gates channelOpened on .online
    }
    events.yield(.channelOpened(channelID, peerHandle, direction: .inbound))
    events.yield(.channelData(channelID, framedHello(token)))
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

/// Opening a link to a destination learned on a departed interface fails IMMEDIATELY rather
/// than minting a link on a dead interface and waiting ~15s for establishmentDeadline.
/// The fast failure is what lets LXMFRouter request a path and recover (LXMFRouter.swift:311-313).
@Test @MainActor func openLinkToADepartedInterfaceFailsImmediately() async {
    let (store, events, _) = makeNode()
    // Bring the peer online under its normal token/channel.
    await bringPeerOnline(store, events)

    // Learn a path to a remote destination via an announce from that peer.
    let remote = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: remote, appName: "app",
                                                     aspects: ["svc"], hops: 0, emitted: 1000)
    events.yield(.channelData(channel, try! BLEFraming.frame(announceRaw)))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }

    // Take the peer offline — the learned entry survives but its interface is gone.
    // When the last peer departs, BLEEndpoint also emits .transport(.stopMaintenance) as part of
    // the same peerOffline handling; consume it here so teardown's stopMaintenance receive works.
    events.yield(.channelClosed(channel, reason: nil))
    await store.receive { if case .delegate(.peerOffline) = $0 { return true }; return false }
    await store.receive { if case .transport(.stopMaintenance) = $0 { return true }; return false }

    // openLink must fail immediately — no link is minted on the dead interface.
    // Do NOT advance the clock: the whole claim is that this does not wait for a timeout.
    await store.send(.openLink(destinationHash: destHash))
    await store.receive { if case .delegate(.linkFailed(let hash)) = $0 { return hash == destHash }; return false }
    #expect(store.state.links.isEmpty)

    await store.send(.stop)
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

/// End-to-end: a link survives its peer reconnecting under a NEW session token.
///
/// Before the re-homing fix, this was the half-alive case: inbound kept working (Transport
/// routes by linkID, which is unchanged) while every outbound transmit hit a dead InterfaceID
/// because `LinkSession.interfaceID` still pointed to tokenA's now-gone BLE interface. The link
/// would silently stall until the ~60 s watchdog fired.
///
/// ABSENCE ASSERTION — `sendFailed(reason: .interfaceUnavailable)` must NOT fire after
/// re-homing. The mechanism: `store.send(.sendOverLink)` is the LAST `store.send` in this test.
/// If re-homing failed, the stale interfaceID lookup in `BLEEndpoint.peerInterfaces` returns
/// nil → `sendFailed` is dispatched instead of `ble(.send)`. The subsequent `store.receive`
/// predicate matches ONLY `ble(.send(peer: peerTokenB, _))`, so it will never match a
/// `sendFailed` action — the test fails with "no matching action received". This cannot be
/// vacuously wiped: no later `store.send` follows to flush the action queue.
@Test @MainActor func linkSurvivesPeerReconnectUnderANewToken() async {
    // We own `initEph` so we can derive the session key after seeing the LRPROOF.
    let initEph = Identity()
    let owner   = Identity()

    let (store, events, sent) = makeNode()

    // ── Phase 1: tokenA online; establish a link ────────────────────────────────────────────
    await bringPeerOnline(store, events)

    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: owner)!
    await store.send(.registerLocalDestination(dest))

    // Send LINKREQUEST from initEph → our local destination over tokenA's channel.
    let request = Packet(headerType: .header1, packetType: .linkRequest,
                         transportType: .broadcast, destinationType: .single,
                         context: .none, contextFlag: false, hops: 0,
                         destinationHash: dest.hash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    events.yield(.channelData(channel, try! BLEFraming.frame(try! request.packed())))

    // Responder creates a link and sends LRPROOF back to tokenA.
    await store.receive { if case .ble(.send) = $0 { return true }; return false }
    #expect(store.state.links.count == 1)
    let linkID = store.state.links[0].linkID

    // Extract the responder's X25519 pub from the LRPROOF (signature‖X25519pub‖signalling).
    // `sent` captures (peerToken, framedBytes); unframe to reach the Packet payload.
    let proofFramed   = sent.value.last!.1
    let proofUnframed = Data(proofFramed.dropFirst(BLEFraming.headerLength))
    let proofPayload  = Packet(raw: proofUnframed)!.payload      // 99 bytes
    let responderX25519Pub = Data(proofPayload[64..<96])

    // Derive session key (initiator side): ECDH(initEph.x25519Private, responderX25519Pub, linkID).
    let sessionKey = Link.sessionKey(
        ephemeralPrivateX25519: Data(initEph.privateKey!.prefix(32)),
        peerPublicX25519: responderX25519Pub,
        linkID: linkID)

    // Complete handshake: initiator sends the RTT packet → responder transitions to .active.
    let rttPayload = Link.encrypt(MsgPack.encode(1.0), sessionKey: sessionKey)
    let rttPkt = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .link, context: .linkRequestRTT, contextFlag: false,
                        hops: 0, destinationHash: linkID, transportId: nil, payload: rttPayload)
    events.yield(.channelData(channel, try! BLEFraming.frame(try! rttPkt.packed())))
    await store.receive { if case .delegate(.linkEstablished) = $0 { return true }; return false }
    #expect(store.state.links[0].interfaceID == bleInterfaceID(peerToken))

    // ── Phase 2: tokenA goes offline ────────────────────────────────────────────────────────
    // The link's stored interfaceID is now stale: tokenA is gone from peerInterfaces, so any
    // outbound link transmit would hit a dead lookup and fire sendFailed.
    events.yield(.channelClosed(channel, reason: nil))
    await store.receive { if case .delegate(.peerOffline) = $0 { return true }; return false }

    // ── Phase 3: peer reconnects under tokenB (a DIFFERENT InterfaceID) ─────────────────────
    await bringPeerOnline(store, events, token: peerTokenB, channelID: channel2,
                          peerHandle: handle2, startFirst: false)

    // ── Phase 4: inbound link packet over tokenB → re-homes the session ─────────────────────
    // Any link-addressed packet arriving on tokenB's channel triggers routeLinkPacket with
    // bleInterfaceID(peerTokenB), which re-homes state.links[0].interfaceID to tokenB.
    let pingPayload = Link.encrypt(Data("ping".utf8), sessionKey: sessionKey)
    let pingPkt = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                         destinationType: .link, context: .none, contextFlag: false,
                         hops: 0, destinationHash: linkID, transportId: nil, payload: pingPayload)
    events.yield(.channelData(channel2, try! BLEFraming.frame(try! pingPkt.packed())))
    // linkDataReceived confirms both re-homing AND that tokenB's interface carried the packet.
    await store.receive { if case .delegate(.linkDataReceived) = $0 { return true }; return false }

    // Positive state assertion: link is now homed to tokenB.
    #expect(store.state.links[0].interfaceID == bleInterfaceID(peerTokenB))

    // ── Phase 5: outbound traffic must reach tokenB — the last store.send in this test ───────
    // If re-homing failed, peerInterfaces lookup for the stale tokenA interfaceID returns nil
    // → sendFailed fires instead of ble(.send) → the receive below never matches → test FAILS.
    await store.send(.sendOverLink(linkID: linkID, data: Data("pong".utf8)))
    await store.receive { action in
        if case .ble(.send(peer: let peer, packet: _)) = action { return peer == peerTokenB }
        return false
    }
    // And the packet reached the DRIVER on tokenB's channel, not tokenA's — the action assertion
    // above proves the endpoint addressed tokenB; this proves BLEInterface resolved that token to
    // channel2 and actually transmitted there.
    #expect(sent.value.last?.0 == peerTokenB)

    await teardown(store)
}
