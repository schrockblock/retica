import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

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
private let bleMTU = 512
/// One fragment (payload 507 ≥ any test packet) with the 5-byte v2.2 header.
private func bleFrag(_ packet: Data) -> Data { try! BLEFragmenter(mtu: bleMTU).fragment(packet)[0] }

@MainActor
private func makeNode() -> (TestStore<TransportEndpoint.State, TransportEndpoint.Action>,
                            AsyncStream<BLEDriverEvent>.Continuation,
                            LockIsolated<[(Data, Data)]>) {
    let events = AsyncStream<BLEDriverEvent>.makeStream()
    let sent = LockIsolated<[(Data, Data)]>([])   // (peerToken the send actually went to, packet)
    let store = TestStore(initialState: bleDriverEndpoint()) {
        TransportEndpoint()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
        $0.bleDriver = BLEDriver(
            start: { _ in events.stream },
            readIdentity: { _ in }, openChannel: { _ in },
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
private func bringPeerOnline(_ store: TestStore<TransportEndpoint.State, TransportEndpoint.Action>,
                             _ events: AsyncStream<BLEDriverEvent>.Continuation,
                             token: Data = peerToken,
                             channelID: BLEChannelID = channel,
                             peerHandle: BLEPeerHandle = handle,
                             startFirst: Bool = true) async {
    if startFirst {
        await store.send(.start)
        events.yield(.ready)                   // BLEInterface gates channelOpened on .online
    }
    events.yield(.channelOpened(channelID, peerHandle, direction: .inbound, mtu: bleMTU))
    events.yield(.channelData(channelID, token))
    await store.receive { if case .transport(.interfaceConnected) = $0 { return true }; return false }
}

@MainActor
private func teardown(_ store: TestStore<TransportEndpoint.State, TransportEndpoint.Action>) async {
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
    events.yield(.channelData(channel, bleFrag(try! request.packed())))

    // A responder link is created on the arrival peer's interface, and the LRPROOF goes back to that peer.
    await store.receive { if case .ble(.ble(.send)) = $0 { return true }; return false }
    #expect(store.state.links.count == 1)
    #expect(store.state.links[0].interfaceID == bleInterfaceID(peerToken))
    let last = sent.value.last
    #expect(last?.0 == peerToken)
    // BLEInterface.send frames packets (2-byte big-endian length prefix); unframe before parsing.
    let unframed = last.map { Data($0.1.dropFirst(BLEFragmenter.headerLength)) }
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
    events.yield(.channelData(channel, bleFrag(announceRaw)))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }

    // openLink must pick the peer's BLE interface from the learned entry.
    await store.send(.openLink(destinationHash: destHash))
    // A LINKREQUEST is emitted as the link begins establishing; wait for the transmit so we
    // know LinkPlane has processed .openLink and state is settled.
    await store.receive { if case .ble(.ble(.send)) = $0 { return true }; return false }

    // (a) link shim: state.links forwards to linkPlane.links
    #expect(store.state.links.count == 1)
    // (b) the link rides the BLE interface for this peer
    #expect(store.state.links[0].interfaceID == bleInterfaceID(peerToken))
    // (c) the driver received a LINKREQUEST for this peer
    let lastSent = sent.value.last
    #expect(lastSent?.0 == peerToken)
    let unframed = lastSent.map { Data($0.1.dropFirst(BLEFragmenter.headerLength)) }
    #expect(Packet(raw: unframed!)?.packetType == .linkRequest)

    await store.send(.closeLink(linkID: store.state.links[0].linkID))
    await teardown(store)
}

@Test @MainActor func openLinkToUnlearnedDestinationFailsOverBLE() async {
    let (store, events, _) = makeNode()
    await bringPeerOnline(store, events)

    let unknownDest = Data(repeating: 0x42, count: 16)
    await store.send(.openLink(destinationHash: unknownDest))
    await store.receive { if case .delegate(.linkFailed(let hash, .noPath)) = $0 { return hash == unknownDest }; return false }
    #expect(store.state.links.isEmpty)

    await teardown(store)
}

/// A BLE peer that reconnects gets a NEW InterfaceID by construction, so a learned entry from
/// before the reconnect names an interface that is gone. Opening a link on it mints a session
/// bound to a dead interface: every transmit yields .sendFailed (which nothing consumes), so the
/// 15s establishment deadline is the only exit — ~75s across the budget, against a peer that is
/// physically connected. Gate on reachableLearned instead, and say WHY it failed.
@Test @MainActor func bleOpenLinkOnStaleInterfaceFailsImmediatelyAsPathStale() async {
    // Drive: interface connects, announce learned on it, interface DISCONNECTS
    // (so transport.interfaces loses the ID while transport.learned keeps the entry),
    // then .openLink(dest).
    // Assert: .delegate(.linkFailed(destinationHash: dest, reason: .pathStale)) immediately,
    //         and NO .linkPlane(.openLink) — nothing was minted.
    // Drive the disconnect through the real action; do not seed transport.interfaces.
    let (store, events, _) = makeNode()
    await bringPeerOnline(store, events)

    // Learn a destination via a crafted announce on the peer's channel.
    let remote = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: remote, appName: "app",
                                                     aspects: ["svc"], hops: 0, emitted: 1000)
    events.yield(.channelData(channel, bleFrag(announceRaw)))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }

    // Transport has learned[destHash] = … with interfaceID = bleInterfaceID(peerToken).
    #expect(store.state.transport.learned[destHash] != nil)

    // Peer goes OFFLINE: interfaceDisconnected removes bleInterfaceID(peerToken) from
    // transport.interfaces, so reachableLearned(destHash) will return nil even though
    // learned[destHash] still exists.
    events.yield(.channelClosed(channel, reason: nil))
    await store.receive { if case .ble(.delegate(.peerOffline)) = $0 { return true }; return false }
    // That was the last peer, so maintenance also stops. Drain it here, while exhaustivity is
    // still .off, so the .on window below sees only what `.openLink` itself produces.
    await store.receive { if case .transport(.stopMaintenance) = $0 { return true }; return false }

    // Sanity: learned entry survives (non-destructive by design), interface is gone.
    #expect(store.state.transport.learned[destHash] != nil)
    #expect(store.state.transport.interfaces[bleInterfaceID(peerToken)] == nil)

    // openLink must fail immediately with .pathStale — and NOTHING may be minted.
    //
    // Exhaustivity is flipped to .on for this send. Under .off a stray `.linkPlane(.openLink)`
    // is silently drained and never applied, so `store.state.links` reads empty whether or not a
    // link was minted — an `isEmpty` check there is vacuous. Under .on the mint surfaces as an
    // unasserted received action and fails crisply with a diff against the expected delegate,
    // instead of via a 1-second receive timeout.
    store.exhaustivity = .on
    await store.send(.openLink(destinationHash: destHash))
    await store.receive(.delegate(.linkFailed(destinationHash: destHash, reason: .pathStale)))
    store.exhaustivity = .off
    #expect(store.state.links.isEmpty)

    await store.send(.stop)
}

/// Pins the LinkPlane→BLEEndpoint `linkFailed` forwarder: the reason must be carried through,
/// not recomputed or hardcoded. `.handshakeRejected` is deliberately a reason BLE's own
/// `openLink` can never produce, so a hardcoded forwarder cannot pass by coincidence.
@Test @MainActor func bleForwardsLinkPlaneLinkFailedReasonUnchanged() async {
    let (store, events, _) = makeNode()
    await bringPeerOnline(store, events)

    let destHash = Data(repeating: 0x77, count: 16)
    for reason in [LinkFailure.handshakeRejected, .establishmentTimedOut, .noPath, .pathStale] {
        await store.send(.linkPlane(.delegate(.linkFailed(destinationHash: destHash, reason: reason))))
        await store.receive { action in
            if case .delegate(.linkFailed(let h, let r)) = action { return h == destHash && r == reason }
            return false
        }
    }

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
    events.yield(.channelData(channel, bleFrag(try! request.packed())))

    // Responder creates a link and sends LRPROOF back to tokenA.
    await store.receive { if case .ble(.ble(.send)) = $0 { return true }; return false }
    #expect(store.state.links.count == 1)
    let linkID = store.state.links[0].linkID

    // Extract the responder's X25519 pub from the LRPROOF (signature‖X25519pub‖signalling).
    // `sent` captures (peerToken, framedBytes); unframe to reach the Packet payload.
    let proofFramed   = sent.value.last!.1
    let proofUnframed = Data(proofFramed.dropFirst(BLEFragmenter.headerLength))
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
    events.yield(.channelData(channel, bleFrag(try! rttPkt.packed())))
    await store.receive { if case .delegate(.linkEstablished) = $0 { return true }; return false }
    #expect(store.state.links[0].interfaceID == bleInterfaceID(peerToken))

    // ── Phase 2: tokenA goes offline ────────────────────────────────────────────────────────
    // The link's stored interfaceID is now stale: tokenA is gone from peerInterfaces, so any
    // outbound link transmit would hit a dead lookup and fire sendFailed.
    events.yield(.channelClosed(channel, reason: nil))
    await store.receive { if case .ble(.delegate(.peerOffline)) = $0 { return true }; return false }

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
    events.yield(.channelData(channel2, bleFrag(try! pingPkt.packed())))
    // linkDataReceived confirms both re-homing AND that tokenB's interface carried the packet.
    await store.receive { if case .delegate(.linkDataReceived) = $0 { return true }; return false }

    // Positive state assertion: link is now homed to tokenB.
    #expect(store.state.links[0].interfaceID == bleInterfaceID(peerTokenB))

    // ── Phase 5: outbound traffic must reach tokenB — the last store.send in this test ───────
    // If re-homing failed, peerInterfaces lookup for the stale tokenA interfaceID returns nil
    // → sendFailed fires instead of ble(.send) → the receive below never matches → test FAILS.
    await store.send(.sendOverLink(linkID: linkID, data: Data("pong".utf8)))
    await store.receive { action in
        if case .ble(.ble(.send(peer: let peer, packet: _))) = action { return peer == peerTokenB }
        return false
    }
    // And the packet reached the DRIVER on tokenB's channel, not tokenA's — the action assertion
    // above proves the endpoint addressed tokenB; this proves BLEInterface resolved that token to
    // channel2 and actually transmitted there.
    #expect(sent.value.last?.0 == peerTokenB)

    await teardown(store)
}

/// BLE peerOffline must fan out `.interfaceDisconnected` to `LinkPlane`, granting links bound to
/// that interface one unauthenticated re-home. This pins the production wiring: if the
/// `.linkPlane(.interfaceDisconnected(id))` fan-out is removed from the `peerOffline` handler,
/// `rehomePermitted` stays false — the mechanism exists in `LinkPlane` but is never triggered
/// from the real endpoint.
///
/// The setup drives a real LINKREQUEST from the peer's channel so the link is created via the
/// normal code path rather than seeded state. This guarantees it is bound to
/// `bleInterfaceID(peerToken)`, the same interface the disconnect will signal.
@Test @MainActor func blePeerOfflineSetsRehomePermittedOnLinksForThatInterface() async {
    let (store, events, _) = makeNode()
    await bringPeerOnline(store, events)

    // Feed a real LINKREQUEST from the peer so an inbound responder link is created on peerToken's
    // BLE interface. (No need to complete the handshake — the test only cares about interfaceID
    // and rehomePermitted, both of which are set at creation time.)
    let owner = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["rehome-test"],
                           identity: owner)!
    await store.send(.registerLocalDestination(dest))

    let initEph = Identity()
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: dest.hash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    events.yield(.channelData(channel, bleFrag(try! request.packed())))
    // Drain the LRPROOF so the link element is fully created before we read state.
    await store.receive { if case .ble(.ble(.send)) = $0 { return true }; return false }

    guard let element = store.state.linkPlane.links.first(where: { $0.interfaceID == bleInterfaceID(peerToken) }) else {
        Issue.record("Expected a responder link bound to peerToken's interface")
        return
    }
    let elementID = element.id

    // Before disconnect: rehomePermitted must be false.
    #expect(store.state.linkPlane.links[id: elementID]?.rehomePermitted == false)

    // Peer goes offline. This must fan out .interfaceDisconnected to LinkPlane.
    events.yield(.channelClosed(channel, reason: nil))
    await store.receive { if case .ble(.delegate(.peerOffline)) = $0 { return true }; return false }

    // After disconnect: rehomePermitted must be true for the link bound to that interface.
    // If the fan-out is missing, rehomePermitted stays false and this assertion fails.
    #expect(store.state.linkPlane.links[id: elementID]?.rehomePermitted == true,
            "peerOffline must fan-out interfaceDisconnected to LinkPlane so rehomePermitted is set")

    await store.send(.stop)
}
