import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let ownToken   = Data(repeating: 0x5A, count: 16)
private let peerToken  = Data(repeating: 0xC7, count: 16)
private let peerTokenB = Data(repeating: 0xD4, count: 16)   // second session token for reconnect test
private let channel    = BLEChannelID(id: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!)
private let handle     = BLEPeerHandle(id: UUID(uuidString: "22222222-0000-0000-0000-000000000002")!)
private let channel2   = BLEChannelID(id: UUID(uuidString: "11111111-0000-0000-0000-000000000003")!)
private let handle2    = BLEPeerHandle(id: UUID(uuidString: "22222222-0000-0000-0000-000000000004")!)
private let bleMTU = 512
/// One fragment (payload 507 ≥ any test packet) with the 5-byte v2.2 header.
private func bleFrag(_ packet: Data) -> Data { try! BLEFragmenter(mtu: bleMTU).fragment(packet)[0] }

/// An LXMFNode running over BLE, with a controllable mock driver.
@MainActor
private func makeBLENode(_ identity: Identity)
    -> (TestStore<LXMFNode.State, LXMFNode.Action>,
        AsyncStream<BLEDriverEvent>.Continuation,
        LockIsolated<[Data]>) {
    let events = AsyncStream<BLEDriverEvent>.makeStream()
    let sent = LockIsolated<[Data]>([])          // framed bytes handed to the driver
    let store = TestStore(
        initialState: LXMFNode.State(identity: identity, endpoint: BLEEndpoint.State(localIdentity: ownToken))
    ) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.bleDriver = BLEDriver(
            start: { _ in events.stream },
            readIdentity: { _ in }, openChannel: { _ in },
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
    await bringPeerOnlineWith(store, events, token: peerToken, channelID: channel,
                              peerHandle: handle, startFirst: true)
}

/// Parameterized peer-online helper. Pass `startFirst: false` when the node is already running
/// (e.g. the second peer in a reconnect test).
@MainActor
private func bringPeerOnlineWith(_ store: TestStore<LXMFNode.State, LXMFNode.Action>,
                                 _ events: AsyncStream<BLEDriverEvent>.Continuation,
                                 token: Data,
                                 channelID: BLEChannelID,
                                 peerHandle: BLEPeerHandle,
                                 startFirst: Bool) async {
    if startFirst {
        await store.send(.endpoint(.start))
        events.yield(.ready)              // BLEInterface gates channelOpened on .online
    }
    events.yield(.channelOpened(channelID, peerHandle, direction: .inbound, mtu: bleMTU))
    events.yield(.channelData(channelID, token))
    await store.receive { action in
        if case .endpoint(.transport(.interfaceConnected)) = action { return true }
        return false
    }
}

/// Build a raw HEADER_1 ANNOUNCE packet for a synthetic identity (lxmf.delivery destination).
/// Returns (framedBytes, deliveryDestinationHash).
private func makeLXMFAnnouncePacket(identity: Identity, emitted: UInt64) -> (Data, Data) {
    let nameHash = Destination.nameHash(appName: LXMessage.appName, aspects: LXMessage.deliveryAspects)
    let destHash = Destination.hash(identityHash: identity.hash,
                                    appName: LXMessage.appName, aspects: LXMessage.deliveryAspects)
    let randomHash = Announce.randomHash(now: emitted, randomPrefix: Data(repeating: 0xA5, count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, appData: nil)
    let packet = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: destHash, transportId: nil, payload: payload)
    return (bleFrag(try! packet.packed()), destHash)
}

@MainActor
private func teardown(_ store: TestStore<LXMFNode.State, LXMFNode.Action>) async {
    await store.send(.endpoint(.stop))
    await store.receive { action in
        if case .endpoint(.transport(.stopMaintenance)) = action { return true }
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
    events.yield(.channelData(channel, bleFrag(try! packet.packed())))

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
    let bDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                            aspects: LXMessage.deliveryAspects, identity: bIdentity)!
    let nameHash = Destination.nameHash(appName: LXMessage.appName, aspects: LXMessage.deliveryAspects)
    let randomHash = Announce.randomHash(now: 1_700_000_000, randomPrefix: Data(repeating: 0xA5, count: 5))
    let payload = Announce.buildPayload(identity: bIdentity, destinationHash: bDest.hash,
                                        nameHash: nameHash, randomHash: randomHash, appData: nil)
    let announce = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                          destinationType: .single, context: .none, contextFlag: false, hops: 1,
                          destinationHash: bDest.hash, transportId: nil, payload: payload)
    events.yield(.channelData(channel, bleFrag(try! announce.packed())))
    await store.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // Send an opportunistic LXMF message; it must reach the peer as a framed DATA packet.
    let before = sent.value.count
    await store.send(.send(destinationHash: bDest.hash, title: Data("hi".utf8),
                           content: Data("ping".utf8), method: .opportunistic))
    // Synchronize on the DEEPEST hop — the BLEInterface-level send that actually calls the
    // driver — not `.ble(.send)`, which is the first of four-plus hops and leaves `sent`
    // written only by a later effect. Unambiguous here: this node never calls
    // `.registerDelivery`, so the DATA packet is the only BLEInterface send after `.send`.
    await store.receive { if case .endpoint(.ble(.ble(.send))) = $0 { return true }; return false }
    #expect(sent.value.count > before)
    // The driver receives FRAMED bytes; drop the 2-byte framing header to get the raw packet.
    // Non-trapping: #expect does not abort, so an empty `sent` must record an issue and return
    // rather than force-unwrap nil (Swift Testing has no per-test crash isolation).
    guard let framed = sent.value.last else {
        Issue.record("nothing reached the BLE driver")
        return
    }
    let raw = Data(framed.dropFirst(BLEFragmenter.headerLength))
    let outPacket = Packet(raw: raw)
    #expect(outPacket?.packetType == .data)
    #expect(outPacket?.destinationHash == bDest.hash)

    await teardown(store)
}

/// The whole point of this slice: a BLE peer that drops and reconnects is deliverable again on
/// the NEXT message, rather than after the full establishment budget and a failed one. (Before this
/// slice that shape burned `maxAttempts` × the establishment timeout against a dead interface; the
/// exact figure is deliberately not restated here, having gone stale three times — the clock
/// advances below are the executable version.) Drives the real chain — announce learned on
/// interface A, A disconnects, message queued (which trips the stale-path gate immediately),
/// peer returns as interface B with a genuinely different InterfaceID (new HELLO token), B
/// announces, path re-learned on B, router exits the awaitingPath park and opens a link on B.
///
/// Budget assertion: `establishAttempts[dest] == 1` after the .pathStale bounce. ONE attempt is
/// correct and is the whole point — the first `establish` legitimately charges it while
/// `knownPaths` still holds the dest (that is the call that emits the `requestLink` which the gate
/// then rejects); the park that follows is free, because only the `knownPaths.contains` branch of
/// `establish` increments and the `.awaitingPath` branch never does. So the assertion pins "the
/// stale binding costs exactly one attempt, not the whole budget" — the pre-fix cascade reached
/// `maxAttempts` here.
///
/// It is NOT an ordering catcher: under a clear/close reversal this value is still 1. The ordering
/// discriminator lives in `stalePathLinkFailureRequestsAPathInsteadOfRetryingTheLink`, where no
/// attempt is charged at all because the failure is injected directly rather than following a
/// genuine `requestLink`.
///
/// Harness extension: added `peerTokenB`, `channel2`, `handle2` file-level constants and a
/// parameterized `bringPeerOnlineWith` helper (the original `bringPeerOnline` now delegates to it).
@Test @MainActor func bleReconnectedPeerIsDeliverableOnTheNextMessage() async {
    let clock = TestClock()
    let aIdentity = Identity()      // us (the sender node)
    let bIdentity = Identity()      // the remote peer (reconnects under a new token)
    let bDeliveryHash = LXMessage.deliveryHash(identityHash: bIdentity.hash)

    let events = AsyncStream<BLEDriverEvent>.makeStream()
    let sent = LockIsolated<[Data]>([])
    let store = TestStore(
        initialState: LXMFNode.State(identity: aIdentity, endpoint: BLEEndpoint.State(localIdentity: ownToken))
    ) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.bleDriver = BLEDriver(
            start: { _ in events.stream },
            readIdentity: { _ in }, openChannel: { _ in },
            send: { _, data in sent.withValue { $0.append(data) } },
            closeChannel: { _ in }, stop: { }
        )
    }
    store.exhaustivity = .off

    // ── Phase 1: peer connects as tokenA; announce delivers its lxmf.delivery destination ──────
    await bringPeerOnlineWith(store, events.continuation, token: peerToken,
                              channelID: channel, peerHandle: handle, startFirst: true)

    let (announceFramedA, _) = makeLXMFAnnouncePacket(identity: bIdentity, emitted: 1_700_000_000)
    events.continuation.yield(.channelData(channel, announceFramedA))
    await store.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // Path and identity are now known: learned[bDeliveryHash] exists, knownPaths contains it.
    #expect(store.state.endpoint.learned[bDeliveryHash] != nil)

    // ── Phase 2: peer goes offline — interface A is removed; learned entry survives ─────────────
    events.continuation.yield(.channelClosed(channel, reason: nil))
    await store.receive { if case .endpoint(.ble(.delegate(.peerOffline))) = $0 { return true }; return false }
    // Drain stopMaintenance (emitted when the last peer disconnects).
    await store.receive { if case .endpoint(.transport(.stopMaintenance)) = $0 { return true }; return false }

    // Sanity: learned entry survives; bleInterfaceID(peerToken) is gone.
    #expect(store.state.endpoint.learned[bDeliveryHash] != nil)

    // ── Phase 3: send a direct message — hits the stale-path gate immediately ─────────────────
    // `establish` sees knownPaths.contains(dest) → emits requestLink → BLEEndpoint.openLink.
    // openLink: reachableLearned returns nil (interface gone) → linkFailed(.pathStale).
    // LXMFNode.linkFailed(.pathStale): pathLostAndClosed → establish sees no known path →
    //   awaitingPath park + requestPath delegate.
    //
    // The gate makes the failure synchronous and zero-delay: no LINKREQUEST is ever transmitted.
    // Without the gate, openLink would succeed, a LINKREQUEST would reach the driver, and the
    // establishment timeout (15s on the TestClock) would be the only exit — meaning `requestPath`
    // below would never arrive (TestClock not advanced), and the test would time out.
    let sentCountBeforeSend = sent.value.count
    await store.send(.send(destinationHash: bDeliveryHash,
                           title: Data("hi".utf8), content: Data("hello".utf8), method: .direct))

    // The park emits requestPath immediately (via LXMFNode → endpoint(.requestPath)).
    // Without the gate this action never arrives (link was minted, TestClock not advanced).
    await store.receive { if case .router(.delegate(.requestPath)) = $0 { return true }; return false }

    // State assertions: park is in effect.
    #expect(store.state.router.directLinks[bDeliveryHash] == .awaitingPath,
            "must be parked in awaitingPath — no live interface to open a link on")
    #expect(!store.state.router.knownPaths.contains(bDeliveryHash),
            "pathLostAndClosed must have cleared the stale route belief")
    // Exactly ONE attempt: charged by the establish() that emitted the requestLink the gate then
    // rejected. The park that followed is free. Pre-fix, this bounce consumed the whole budget.
    #expect(store.state.router.establishAttempts[bDeliveryHash] == 1,
            "a stale binding must cost exactly one attempt, not the budget")
    // Corroborating assertion: no bytes reached the driver during Phase 3.
    //
    // The gate short-circuits openLink before any packet is emitted. Without the gate, openLink
    // proceeds to mint a link and emits a LINKREQUEST — but since the peer interface is already
    // gone, the transmit hits the `peerInterfaces[txID] == nil` guard in BLEEndpoint and fires
    // `.sendFailed` instead of calling the driver. So `sent` is unchanged in both cases and
    // this assertion alone is not the discriminator.
    //
    // THE PRIMARY DISCRIMINATOR is the `requestPath` receive above: with the gate,
    // `.pathStale` fires synchronously and the park is entered immediately. Without the gate,
    // the link times out after 15s (TestClock not advanced), so `requestPath` never arrives
    // and the receive times out — exactly the failure seen in the mutation run.
    #expect(sent.value.count == sentCountBeforeSend,
            "no bytes may reach the driver on a stale-path bounce")
    // The queued message is still parked, not failed.
    #expect(store.state.router.outboundQueue[bDeliveryHash]?.count == 1,
            "message must be queued in outboundQueue while parked")

    // ── Phase 4: peer reconnects as tokenB (a DIFFERENT InterfaceID by construction) ─────────
    // bringPeerOnlineWith does not yield .ready when startFirst is false; the node is running.
    await bringPeerOnlineWith(store, events.continuation, token: peerTokenB,
                              channelID: channel2, peerHandle: handle2, startFirst: false)

    // Peer B announces its delivery destination. The announce must arrive with a FRESH timestamp
    // so Transport's shouldReplace accepts it (later timestamp wins).
    let (announceFramedB, _) = makeLXMFAnnouncePacket(identity: bIdentity, emitted: 1_700_000_001)
    let beforeLinkReq = sent.value.count
    events.continuation.yield(.channelData(channel2, announceFramedB))

    // learnedPath → router(.learnedPath) → directLinks[dest] == .awaitingPath → establish() →
    //   requestLink → BLEEndpoint.openLink → LINKREQUEST emitted on interface B.
    // Wait for the deepest send — the BLEInterface-level driver call — so we know the
    // LINKREQUEST actually reached the driver before asserting on `sent`.
    await store.receive { if case .endpoint(.ble(.ble(.send))) = $0 { return true }; return false }

    // A LINKREQUEST was emitted toward tokenB — the re-discovered peer.
    #expect(sent.value.count > beforeLinkReq, "a LINKREQUEST must reach the BLE driver after path re-learn")
    guard let lastSent = sent.value.last else {
        Issue.record("nothing reached the BLE driver after reconnect")
        return
    }
    let rawPkt = Data(lastSent.dropFirst(BLEFragmenter.headerLength))
    #expect(Packet(raw: rawPkt)?.packetType == .linkRequest,
            "the packet emitted after path re-learn must be a LINKREQUEST")

    // Confirm the router exited the park: directLinks should now be .establishing.
    #expect(store.state.router.directLinks[bDeliveryHash] == .establishing,
            "router must transition from .awaitingPath to .establishing after path re-learn")

    // Teardown: the node is still running (one active peer: tokenB).
    await store.send(.endpoint(.stop))
    await store.receive { if case .endpoint(.transport(.stopMaintenance)) = $0 { return true }; return false }
}
