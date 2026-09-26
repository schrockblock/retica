import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// MARK: - Characterization tests at the unified TransportEndpoint surface (Task 1a)
//
// These tests pin BEHAVIOUR — not structure — so they survive Task 1b's restructuring of
// `TransportEndpoint.State` from a sum (.tcp/.ble) into a product (shared Transport/LinkPlane +
// a collection of drivers). To achieve that, every `@Test` body below obeys these rules:
//
//   * Input is driven ONLY through the UNIFIED verbs on `TransportEndpoint.Action`
//     (`.start`, `.stop`, `.send`, `.announce`, `.openLink`, `.requestPath`,
//     `.registerLocalDestination`, …) — never a `.tcp(...)`/`.ble(...)` action.
//   * Inbound bytes are injected ONLY through the DEPENDENCY (the `TCPConnection` open
//     closure's `AsyncStream` continuation, or the `BLEDriver` event stream) — never a
//     `.tcp(.transport(...))` action.
//   * Outbound bytes are captured ONLY through the DEPENDENCY (`TCPConnection.send` or
//     `BLEDriver.send`).
//   * Outputs are asserted ONLY through the UNIFIED `.delegate(...)` cases and the UNIFIED
//     state accessors `store.state.learned`, `.interfaces`, `.links`, `.registrations`.
//   * No `.tcp(...)`/`.ble(...)` ACTION paths, no `\.transport.*` key-paths, no
//     `store.state.transport`/`store.state.interface` reads appear in a `@Test` body.
//
// Per the controller's reconciliation of Task 1b Step 3: what must survive 1b VERBATIM is every
// `@Test` function BODY (the assertions ARE the proof). What 1b is allowed to touch is exactly
// ONE private construction helper per transport — the two below (`makeTCP`, `makeBLE`), whose
// `TransportEndpoint.State` construction necessarily changes when the state's shape changes.

// ─────────────────────────────────────────────────────────────────────────────
// The ONE construction helper per transport that Task 1b may edit.
// Everything a test needs to drive input / capture output is returned here so the
// bodies below never construct state or dependencies directly.
// ─────────────────────────────────────────────────────────────────────────────

/// A unified TransportEndpoint over TCP, plus:
///   * the TCP event continuation (inject inbound: `.yield(.connected)`, `.yield(.data(...))`,
///     `.yield(.disconnected(...))`),
///   * `sent` — every buffer handed to `TCPConnection.send` (HDLC-framed outbound bytes),
///   * `now` — the wall clock the maintenance GC reads (advance to age learned paths),
///   * `clock` — the `TestClock` the maintenance tick sleeps on.
@MainActor
private func makeTCP(profile: InterfaceProfile? = nil)
    -> (TestStore<TransportEndpoint.State, TransportEndpoint.Action>,
        AsyncStream<TCPEvent>.Continuation,
        LockIsolated<[Data]>,
        LockIsolated<Date>,
        TestClock<Duration>) {
    let events = AsyncStream<TCPEvent>.makeStream()
    let sent = LockIsolated<[Data]>([])
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let clock = TestClock<Duration>()
    let tcpState: TCPEndpoint.State = {
        if let profile {
            return TCPEndpoint.State(host: "node", port: 4242, reconnectOnDrop: false, profile: profile)
        }
        return TCPEndpoint.State(host: "node", port: 4242, reconnectOnDrop: false)
    }()
    let store = TestStore(initialState: TransportEndpoint.State.tcp(tcpState)) {
        TransportEndpoint()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(
            open: { _, _ in events.stream },
            send: { d in sent.withValue { $0.append(d) } },
            close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.transportDate = DateGenerator { now.value }
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return (store, events.continuation, sent, now, clock)
}

/// A unified TransportEndpoint over BLE, plus:
///   * the BLE driver event continuation (inject inbound: `.ready`, `.channelOpened(...)`,
///     `.channelData(...)`, `.channelClosed(...)`),
///   * `sent` — every `(peerToken, packet)` pair handed to `BLEDriver.send`. The stub resolves
///     the driver's `BLEChannelID` back to the peer token via `tokenForChannel`; an unmapped
///     channel yields empty `Data()` so a mis-routed send can never accidentally match a token.
@MainActor
private func makeBLE(tokenForChannel: [BLEChannelID: Data], ownToken: Data)
    -> (TestStore<TransportEndpoint.State, TransportEndpoint.Action>,
        AsyncStream<BLEDriverEvent>.Continuation,
        LockIsolated<[(Data, Data)]>) {
    let events = AsyncStream<BLEDriverEvent>.makeStream()
    let sent = LockIsolated<[(Data, Data)]>([])
    let store = TestStore(initialState: .ble(BLEEndpoint.State(localIdentity: ownToken))) {
        TransportEndpoint()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
        $0.bleDriver = BLEDriver(
            start: { _ in events.stream },
            readIdentity: { _ in }, openChannel: { _ in },
            send: { chan, fragments in sent.withValue { for f in fragments { $0.append((tokenForChannel[chan] ?? Data(), f)) } } },
            closeChannel: { _ in }, stop: { })
    }
    store.exhaustivity = .off
    return (store, events.continuation, sent)
}

// MARK: - Shared packet builders (pure; not construction helpers)

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

private let bleMTU = 512
/// One fragment (payload 507 ≥ any test packet) with the 5-byte v2.2 header.
private func bleFrag(_ packet: Data) -> Data { try! BLEFragmenter(mtu: bleMTU).fragment(packet)[0] }

// ═════════════════════════════════════════════════════════════════════════════
// 1. F8 stale-path gate (TCP)
//
// `learned` is deliberately non-destructive: losing the interface does NOT purge the path, so a
// learned entry can outlive the interface that named it. `openLink` must gate on
// `reachableLearned` — an entry whose interface is gone is NOT reachable — and fail fast as
// `.pathStale`, minting no LinkSession, rather than transmitting into a dead socket and exiting
// only via the 15s establishment deadline (which would misreport a dead SOCKET as a dead ROUTE).
// ═════════════════════════════════════════════════════════════════════════════

@Test @MainActor func openLinkOverALostInterfaceFailsFastAsPathStaleUnified() async throws {
    let (store, events, _, _, _) = makeTCP()
    let id = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                                     hops: 1, emitted: 1000)
    await store.send(.start)
    events.yield(.connected)
    // Learn the path.
    events.yield(.data(HDLC.frame(announceRaw)))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    let learnedIF = try #require(store.state.learned[destHash]?.interfaceID)
    #expect(store.state.interfaces[learnedIF] != nil, "interface must be up while connected")

    // The socket drops. The learned entry survives by design — that is the trap.
    events.yield(.disconnected(reason: "socket closed"))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.learned[destHash] != nil, "learned must survive the disconnect (non-destructive)")
    #expect(store.state.interfaces[learnedIF] == nil, "the interface that named the path must be gone")

    // openLink must fail fast as .pathStale and mint no link.
    await store.send(.openLink(destinationHash: destHash))
    await store.receive(.delegate(.linkFailed(destinationHash: destHash, reason: .pathStale)))
    #expect(store.state.links.isEmpty, "no LinkSession may be minted against a dead interface")

    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

// A learned & reachable destination (interface still up) opens a link — the positive control that
// proves `.pathStale` above is the GATE firing, not openLink being universally broken.
@Test @MainActor func openLinkToReachableDestinationMintsALinkUnified() async throws {
    let (store, events, _, _, _) = makeTCP()
    let id = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                                     hops: 1, emitted: 1000)
    await store.send(.start)
    events.yield(.connected)
    events.yield(.data(HDLC.frame(announceRaw)))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    let learnedIF = try #require(store.state.learned[destHash]?.interfaceID)
    #expect(store.state.interfaces[learnedIF] != nil)

    await store.send(.openLink(destinationHash: destHash))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.links.count == 1, "a reachable destination mints exactly one link")

    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

// openLink to a destination never learned at all fails as `.noPath` (distinct from `.pathStale`).
@Test @MainActor func openLinkToUnlearnedDestinationFailsAsNoPathUnified() async {
    let (store, events, _, _, _) = makeTCP()
    let unknown = Data(repeating: 0x44, count: 16)
    await store.send(.start)
    events.yield(.connected)
    await store.skipReceivedActions(strict: false)
    await store.send(.openLink(destinationHash: unknown))
    await store.receive(.delegate(.linkFailed(destinationHash: unknown, reason: .noPath)))
    #expect(store.state.links.isEmpty)
    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

// ═════════════════════════════════════════════════════════════════════════════
// 2. IFAC outbound masking (TCP)
//
// On an IFAC-configured endpoint every outbound packet reaches the wire MASKED: the IFAC flag
// (bit 7 of byte 0) is set, and the content round-trips back to a valid packet via
// `IFAC.unprotect`. Captured through the `TCPConnection.send` dependency, deframed from HDLC.
// ═════════════════════════════════════════════════════════════════════════════

@Test @MainActor func outboundPacketsAreIFACProtectedUnified() async throws {
    let ifac = IFAC(networkName: "xnet", passphrase: nil, size: 16)!
    var profile = InterfaceProfile.tcp
    profile.ifac = ifac
    let (store, events, sent, _, _) = makeTCP(profile: profile)

    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["me"],
                           identity: Identity())!
    await store.send(.registerLocalDestination(dest))
    await store.send(.start)
    events.yield(.connected)
    await store.skipReceivedActions(strict: false)

    await store.send(.announce(destinationHash: dest.hash, appData: nil))
    await store.skipReceivedActions(strict: false)

    let framed = try #require(sent.value.last, "an announce must have been transmitted")
    // Deframe the single HDLC frame captured at the send boundary.
    var df = HDLCDeframer()
    let wire = try #require(df.ingest(framed).first, "the transmitted buffer must be a single frame")

    // IFAC flag set (bit 7 of byte 0), and the masked content unprotects to a valid announce.
    #expect(wire[wire.startIndex] & 0x80 == 0x80, "IFAC flag must be set on the masked wire bytes")
    let unmasked = try #require(ifac.unprotect(wire), "IFAC.unprotect must recover the packet")
    let packet = try #require(Packet(raw: unmasked), "unmasked bytes must parse as a packet")
    #expect(packet.packetType == .announce)
    #expect(packet.destinationHash == dest.hash)

    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

// Control: with NO IFAC configured, the same announce reaches the wire UNMASKED (flag clear) and
// parses directly. Proves the flag above is IFAC doing work, not an always-set bit.
@Test @MainActor func outboundPacketsAreUnmaskedWithoutIFACUnified() async throws {
    let (store, events, sent, _, _) = makeTCP()  // default profile: no IFAC
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["me"],
                           identity: Identity())!
    await store.send(.registerLocalDestination(dest))
    await store.send(.start)
    events.yield(.connected)
    await store.skipReceivedActions(strict: false)

    await store.send(.announce(destinationHash: dest.hash, appData: nil))
    await store.skipReceivedActions(strict: false)

    let framed = try #require(sent.value.last)
    var df = HDLCDeframer()
    let wire = try #require(df.ingest(framed).first)
    #expect(wire[wire.startIndex] & 0x80 == 0x00, "no IFAC configured ⇒ flag must be clear")
    let packet = try #require(Packet(raw: wire), "unmasked wire must parse directly as a packet")
    #expect(packet.packetType == .announce)
    #expect(packet.destinationHash == dest.hash)

    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

// ═════════════════════════════════════════════════════════════════════════════
// 3. Maintenance-tick pairing (TCP)
//
// Connecting the endpoint auto-starts the maintenance GC. A learned path that ages past its
// expiry is swept when the tick fires. Observed entirely through `store.state.learned`:
// present after learning, absent after aging + one tick interval.
// ═════════════════════════════════════════════════════════════════════════════

@Test @MainActor func connectStartsGcAndSweepsExpiredPathUnified() async {
    let (store, events, _, now, clock) = makeTCP()
    let id = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                                     hops: 3, emitted: 1000)
    await store.send(.start)
    events.yield(.connected)                                   // → starts maintenance tick
    events.yield(.data(HDLC.frame(announceRaw)))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    #expect(store.state.learned[destHash] != nil, "path is learned and present")

    // Age the wall clock past expiry, then fire one tick interval.
    now.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.learned[destHash] == nil, "expired path must be swept by the maintenance tick")

    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

// Control for the tick TIMING: before the interval elapses, an expired path is NOT swept — the
// sweep is the tick firing, not learning-time or send-time pruning.
@Test @MainActor func expiredPathSurvivesUntilTheTickFiresUnified() async {
    let (store, events, _, now, clock) = makeTCP()
    let id = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                                     hops: 3, emitted: 1000)
    await store.send(.start)
    events.yield(.connected)
    events.yield(.data(HDLC.frame(announceRaw)))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }

    // Age the clock, but advance LESS than one tick interval: no sweep yet.
    now.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval - 1))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.learned[destHash] != nil, "path must persist until the tick actually fires")

    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

// ═════════════════════════════════════════════════════════════════════════════
// 4. Disconnect fan-out (TCP): interface loss grants links on that interface one re-home.
//
// When the interface drops, the endpoint must fan the disconnect out to the link plane so that
// links bound to the lost interface get `rehomePermitted == true` (one unauthenticated re-home).
// Observed through `store.state.links` — `rehomePermitted` is public on `LinkSession.State`.
// A real inbound LINKREQUEST creates the responder link, so it is genuinely bound to the
// endpoint's interface (not seeded), then the disconnect must flip the flag.
// ═════════════════════════════════════════════════════════════════════════════

@Test @MainActor func disconnectFansOutAndGrantsRehomeOnLinksForThatInterfaceUnified() async throws {
    let owner = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["rehome-test"],
                           identity: owner)!
    let (store, events, _, _, _) = makeTCP()
    await store.send(.registerLocalDestination(dest))
    await store.send(.start)
    events.yield(.connected)
    await store.skipReceivedActions(strict: false)

    // Feed a real LINKREQUEST to our local destination: creates a responder link bound to the
    // endpoint's interface.
    let initEph = Identity()
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: dest.hash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    events.yield(.data(HDLC.frame(try! request.packed())))
    await store.skipReceivedActions(strict: false)

    let link = try #require(store.state.links.first, "an inbound LINKREQUEST must create a responder link")
    let boundInterface = link.interfaceID
    #expect(store.state.interfaces[boundInterface] != nil, "the link is bound to a live interface")
    #expect(link.rehomePermitted == false, "before disconnect: no re-home granted")

    // The interface drops. This must fan out to the link plane.
    events.yield(.disconnected(reason: nil))
    await store.skipReceivedActions(strict: false)

    let after = try #require(store.state.links[id: link.id])
    #expect(after.rehomePermitted == true,
            "disconnect must fan out interfaceDisconnected so the bound link's rehomePermitted is set")

    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

// ═════════════════════════════════════════════════════════════════════════════
// 5. Per-peer / correct-interface transmit routing (BLE)
//
// With two live BLE peers, an opportunistic `.send` to a destination learned on peer A's
// interface must transmit to peer A's channel (peer A's token), NOT peer B's. Observed through
// the `BLEDriver.send` dependency, which records the resolved peer token per transmit.
// ═════════════════════════════════════════════════════════════════════════════

@Test @MainActor func opportunisticSendRoutesToTheCorrectPeersInterfaceUnified() async throws {
    let ownToken = Data(repeating: 0x5A, count: 16)
    let tokenA = Data(repeating: 0xC7, count: 16)
    let tokenB = Data(repeating: 0xD4, count: 16)
    let channelA = BLEChannelID(id: UUID(uuidString: "11111111-0000-0000-0000-0000000000A1")!)
    let channelB = BLEChannelID(id: UUID(uuidString: "11111111-0000-0000-0000-0000000000B2")!)
    let handleA = BLEPeerHandle(id: UUID(uuidString: "22222222-0000-0000-0000-0000000000A1")!)
    let handleB = BLEPeerHandle(id: UUID(uuidString: "22222222-0000-0000-0000-0000000000B2")!)

    let (store, events, sent) = makeBLE(tokenForChannel: [channelA: tokenA, channelB: tokenB],
                                        ownToken: ownToken)

    // Bring BOTH peers online through the real BLEInterface handshake (driver dependency only).
    await store.send(.start)
    events.yield(.ready)
    events.yield(.channelOpened(channelA, handleA, direction: .inbound, mtu: bleMTU))
    events.yield(.channelData(channelA, tokenA))
    events.yield(.channelOpened(channelB, handleB, direction: .inbound, mtu: bleMTU))
    events.yield(.channelData(channelB, tokenB))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.interfaces[bleInterfaceID(tokenA)] != nil, "peer A interface must be up")
    #expect(store.state.interfaces[bleInterfaceID(tokenB)] != nil, "peer B interface must be up")

    // Learn a destination on peer A's channel — so its learned entry names peer A's interface.
    let remote = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: remote, appName: "app",
                                                     aspects: ["svc"], hops: 1, emitted: 1000)
    events.yield(.channelData(channelA, bleFrag(announceRaw)))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    #expect(store.state.learned[destHash]?.interfaceID == bleInterfaceID(tokenA),
            "the destination must be learned on peer A's interface")

    // Opportunistic send → the driver.send dependency must resolve to peer A's token, not B's.
    let sentBefore = sent.value.count
    await store.send(.send(destinationHash: destHash, plaintext: Data("ping".utf8)))
    await store.skipReceivedActions(strict: false)

    let transmits = Array(sent.value.dropFirst(sentBefore))
    let dataTransmit = try #require(transmits.last, "the opportunistic send must reach the driver")
    #expect(dataTransmit.0 == tokenA, "must transmit to peer A (the learned interface), not peer B")
    // Every transmit for this send routed to A, never B — no leakage to the wrong peer.
    #expect(transmits.allSatisfy { $0.0 == tokenA },
            "no transmit for this send may reach peer B")
    let outPacket = try #require(Packet(raw: Data(dataTransmit.1.dropFirst(BLEFragmenter.headerLength))))
    #expect(outPacket.packetType == .data)
    #expect(outPacket.destinationHash == destHash)

    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

// ═════════════════════════════════════════════════════════════════════════════
// 6. Decision 2 (RESOLVED): BLE peer lifecycle stays OFF the unified delegate surface.
//
// A BLE peer connecting / disconnecting is BLE-specific; `TransportEndpoint.unify` maps
// `peerOnline`/`peerOffline` to nil, so they never surface as a unified `.delegate(...)`.
// Two independent guards:
//   * STRUCTURAL: the unified `Delegate` enum has no peerOnline/peerOffline case, so it cannot
//     even be named — enforced at compile time.
//   * BEHAVIOURAL (pinned here, non-vacuously): across a full peer online→offline cycle the ONLY
//     unified `.delegate` observed is the `pathLearned` we deliberately cause by injecting an
//     announce. The peer transitions themselves add NO unified delegate. The recorder captures
//     EVERY unified `.delegate` a scanning `receive` is offered (the predicate runs per action,
//     even when it returns false), and the scan's sentinel is that deliberate `pathLearned` —
//     so any spurious delegate emitted by the peer transitions before it would be recorded too.
// ═════════════════════════════════════════════════════════════════════════════

@Test @MainActor func blePeerLifecycleDoesNotSurfaceOnTheUnifiedDelegateUnified() async {
    let ownToken = Data(repeating: 0x5A, count: 16)
    let tokenA = Data(repeating: 0xC7, count: 16)     // stays online — carries the sentinel
    let tokenB = Data(repeating: 0xD4, count: 16)     // the peer whose online→offline is under test
    let channelA = BLEChannelID(id: UUID(uuidString: "11111111-0000-0000-0000-0000000000A1")!)
    let channelB = BLEChannelID(id: UUID(uuidString: "11111111-0000-0000-0000-0000000000B2")!)
    let handleA = BLEPeerHandle(id: UUID(uuidString: "22222222-0000-0000-0000-0000000000A1")!)
    let handleB = BLEPeerHandle(id: UUID(uuidString: "22222222-0000-0000-0000-0000000000B2")!)

    let (store, events, _) = makeBLE(tokenForChannel: [channelA: tokenA, channelB: tokenB],
                                     ownToken: ownToken)

    // Record the CasePath name of every UNIFIED top-level `.delegate` the store surfaces.
    // Using the case-key-path string keeps the closure @Sendable (no non-Sendable capture).
    let unifiedDelegates = LockIsolated<[String]>([])

    // Bring BOTH peers ONLINE via the driver.
    await store.send(.start)
    events.yield(.ready)
    events.yield(.channelOpened(channelA, handleA, direction: .inbound, mtu: bleMTU))
    events.yield(.channelData(channelA, tokenA))
    events.yield(.channelOpened(channelB, handleB, direction: .inbound, mtu: bleMTU))
    events.yield(.channelData(channelB, tokenB))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.interfaces[bleInterfaceID(tokenA)] != nil, "peer A must be online")
    #expect(store.state.interfaces[bleInterfaceID(tokenB)] != nil, "peer B must be online")

    // Peer B goes OFFLINE (the transition under test), THEN peer A carries an announce whose
    // `pathLearned` is the scan sentinel. Ordering matters: the sentinel must come LAST so the
    // scan below is offered — and records — every action B's offline transition produces before
    // it stops. If any of those were a unified `.delegate`, it lands in `unifiedDelegates`.
    events.yield(.channelClosed(channelB, reason: nil))
    let remote = Identity()
    let (announceRaw, _) = makeAnnouncePacket(identity: remote, appName: "app", aspects: ["svc"],
                                              hops: 1, emitted: 1000)
    events.yield(.channelData(channelA, bleFrag(announceRaw)))

    await store.receive { action in
        if case let .delegate(d) = action {
            let name: String
            switch d {
            case .pathLearned: name = "pathLearned"
            case .messageReceived: name = "messageReceived"
            case .linkEstablished: name = "linkEstablished"
            case .linkFailed: name = "linkFailed"
            case .sendFailed: name = "sendFailed"
            default: name = "other"
            }
            unifiedDelegates.withValue { $0.append(name) }
        }
        if case .delegate(.pathLearned) = action { return true }
        return false
    }
    await store.skipReceivedActions(strict: false)

    #expect(store.state.interfaces[bleInterfaceID(tokenB)] == nil, "peer B must be offline")
    #expect(store.state.interfaces[bleInterfaceID(tokenA)] != nil, "peer A must still be online")
    // The ONLY KIND of unified delegate across B's online→offline transition is the deliberate
    // pathLearned from peer A; the peer transitions themselves contributed none. (The scan
    // predicate may be offered pathLearned more than once during fast-forward, so assert on the
    // distinct KINDS observed, not the count.)
    #expect(Set(unifiedDelegates.value) == ["pathLearned"],
            "peer lifecycle must add no unified delegate other than the deliberate pathLearned; saw \(unifiedDelegates.value)")
    #expect(!unifiedDelegates.value.isEmpty, "the scan must have observed the sentinel pathLearned")
}

/// S6 surfacing chain: a terminal `unavailable` from the driver becomes a BLEInterface
/// `adapterUnavailable` delegate, which the container translates and re-emits on the BLE-only hatch
/// — `.ble(.delegate(.adapterUnavailable(_)))` — carrying the cause unchanged. This is the seam the
/// app (A5) consumes; it is deliberately NOT on the unified delegate (LXMF has no use for it),
/// mirroring peerOnline/peerOffline.
@Test @MainActor func bleAdapterUnauthorizedSurfacesOnTheBLEHatchUnified() async {
    let (store, events, _) = makeBLE(tokenForChannel: [:], ownToken: Data(repeating: 0x11, count: 16))
    await store.send(.start)
    events.yield(.ready)
    await store.skipReceivedActions(strict: false)

    events.yield(.unavailable(.unauthorized))
    await store.receive { action in
        if case .ble(.delegate(.adapterUnavailable(.unauthorized))) = action { return true }
        return false
    }
    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}
