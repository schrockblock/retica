import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

enum MockDriverCall: Equatable {
    case start
    case stop
    case readDirectory(BLEPeerHandle)
    case openChannel(BLEPeerHandle, UInt16)
    case send(BLEChannelID, Data)
    case closeChannel(BLEChannelID)
}

// Deterministic fixtures shared by all reducer tests.
let localToken = Data(repeating: 0x11, count: 16)   // what bleRandomBytes yields below
let peerHandleA = BLEPeerHandle(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
let peerHandleB = BLEPeerHandle(id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!)
let channel1 = BLEChannelID(id: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!)
let channel2 = BLEChannelID(id: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000002")!)
let tokenLow = Data(repeating: 0x01, count: 16)     // sorts below localToken
let tokenHigh = Data(repeating: 0xEE, count: 16)    // sorts above localToken

func framedHello(token: Data) -> Data {
    try! BLEFraming.frame(BLEHello.pack(version: BLEInterface.protocolVersion, token: token))
}

/// Pre-creates `streams` driver event streams; the mock's start() hands them out in
/// order (yields buffer until consumed, so tests can yield any time after start).
@MainActor
func makeStore(maxPeers: Int = BLEInterface.defaultMaxPeers, streams: Int = 1)
    -> (store: TestStore<BLEInterface.State, BLEInterface.Action>,
        events: [AsyncStream<BLEDriverEvent>.Continuation],
        calls: LockIsolated<[MockDriverCall]>,
        clock: TestClock<Duration>,
        now: LockIsolated<Date>)
{
    let made = (0..<streams).map { _ in AsyncStream<BLEDriverEvent>.makeStream() }
    let startCount = LockIsolated(0)
    let calls = LockIsolated<[MockDriverCall]>([])
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 1_000))
    let store = TestStore(initialState: BLEInterface.State(maxPeers: maxPeers)) {
        BLEInterface()
    } withDependencies: {
        $0.bleDriver = BLEDriver(
            start: { _ in
                calls.withValue { $0.append(.start) }
                let n = startCount.withValue { $0 += 1; return $0 }
                return n <= made.count ? made[n - 1].stream : AsyncStream { _ in }
            },
            readDirectory: { h in calls.withValue { $0.append(.readDirectory(h)) } },
            openChannel: { h, psm in calls.withValue { $0.append(.openChannel(h, psm)) } },
            send: { c, d in calls.withValue { $0.append(.send(c, d)) } },
            closeChannel: { c in calls.withValue { $0.append(.closeChannel(c)) } },
            stop: { calls.withValue { $0.append(.stop) } }
        )
        $0.continuousClock = clock
        $0.bleDate = DateGenerator { now.value }
        $0.bleRandomBytes = BLERandomBytesGenerator { count in Data(repeating: 0x11, count: count) }
    }
    store.exhaustivity = .off
    return (store, made.map { $0.continuation }, calls, clock, now)
}

// MARK: - Lifecycle

@Test @MainActor func startGeneratesTokenAndComesOnlineOnReady() async {
    let (store, events, calls, _, _) = makeStore()
    await store.send(.start) {
        $0.status = .starting
        $0.sessionToken = localToken
    }
    #expect(calls.value == [.start])
    events[0].yield(.ready)
    await store.receive(.driverEvent(.ready)) { $0.status = .online }
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func startWhileRunningIsIgnored() async {
    let (store, events, calls, _, _) = makeStore()
    await store.send(.start) {
        $0.status = .starting
        $0.sessionToken = localToken
    }
    events[0].yield(.ready)
    await store.receive(.driverEvent(.ready)) { $0.status = .online }
    await store.send(.start)  // no state change, no second driver start
    #expect(calls.value.filter { $0 == .start }.count == 1)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func stopCallsDriverStopAndClearsToken() async {
    let (store, events, calls, _, _) = makeStore()
    await store.send(.start) { $0.status = .starting }
    events[0].yield(.ready)
    await store.receive(.driverEvent(.ready)) { $0.status = .online }
    await store.send(.stop) {
        $0.status = .stopped
        $0.sessionToken = nil
    }
    #expect(calls.value.contains(.stop))
}

// MARK: - Discovery / establishment

/// Brings a store online and returns it ready for discovery events.
@MainActor
func makeOnlineStore(maxPeers: Int = BLEInterface.defaultMaxPeers, streams: Int = 1)
    async -> (store: TestStore<BLEInterface.State, BLEInterface.Action>,
              events: [AsyncStream<BLEDriverEvent>.Continuation],
              calls: LockIsolated<[MockDriverCall]>,
              clock: TestClock<Duration>,
              now: LockIsolated<Date>)
{
    let (store, events, calls, clock, now) = makeStore(maxPeers: maxPeers, streams: streams)
    await store.send(.start) { $0.status = .starting }
    events[0].yield(.ready)
    await store.receive(.driverEvent(.ready)) { $0.status = .online }
    return (store, events, calls, clock, now)
}

@Test @MainActor func discoveryReadsDirectoryThenOpensChannel() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA))) {
        $0.pendingPeers = [peerHandleA]
    }
    #expect(calls.value.contains(.readDirectory(peerHandleA)))
    events[0].yield(.directoryRead(peerHandleA, version: 2, psm: 0x0081))
    await store.receive(.driverEvent(.directoryRead(peerHandleA, version: 2, psm: 0x0081)))
    #expect(calls.value.contains(.openChannel(peerHandleA, 0x0081)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func versionMismatchRefusesAndGreylists() async {
    let (store, events, calls, _, now) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.directoryRead(peerHandleA, version: 1, psm: 0x0081))
    await store.receive(.driverEvent(.directoryRead(peerHandleA, version: 1, psm: 0x0081))) {
        $0.pendingPeers = []
    }
    #expect(!calls.value.contains(.openChannel(peerHandleA, 0x0081)))
    // Greylisted: an immediate rediscovery is ignored (no second readDirectory).
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readDirectory(peerHandleA) }.count == 1)
    // After the 5 s backoff expires (strictly after — inclusive boundary), retry is allowed.
    now.setValue(now.value.addingTimeInterval(5.01))
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readDirectory(peerHandleA) }.count == 2)
    // The re-discoveries above re-armed establish timers; .stop's per-pending
    // cancel loop (CancelID.establish per handle) drains them here.
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func directoryFailureStrikesAndPendingPeerIsNotRediscovered() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    // While pending, duplicate discovery is ignored.
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readDirectory(peerHandleA) }.count == 1)
    events[0].yield(.directoryFailed(peerHandleA, reason: "gatt error"))
    await store.receive(.driverEvent(.directoryFailed(peerHandleA, reason: "gatt error"))) {
        $0.pendingPeers = []
    }
    // Strike recorded: immediate rediscovery ignored.
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readDirectory(peerHandleA) }.count == 1)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func establishDeadlineAbandonsAndStrikes() async {
    let (store, events, calls, clock, _) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    await clock.advance(by: BLEInterface.establishTimeout)
    await store.receive(.establishDeadline(peerHandleA)) { $0.pendingPeers = [] }
    // Late directoryRead for a no-longer-pending peer is ignored (no openChannel).
    events[0].yield(.directoryRead(peerHandleA, version: 2, psm: 0x0081))
    await store.receive(.driverEvent(.directoryRead(peerHandleA, version: 2, psm: 0x0081)))
    #expect(!calls.value.contains(.openChannel(peerHandleA, 0x0081)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func discoveryIsIgnoredAtPeerCap() async {
    let (store, events, calls, _, _) = await makeOnlineStore(maxPeers: 1)
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    // A pending establishment counts against the cap (Python: spawned + pending >= max).
    events[0].yield(.peerDiscovered(peerHandleB))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleB)))
    #expect(calls.value.filter {
        if case .readDirectory = $0 { return true } else { return false }
    }.count == 1)
    await store.send(.stop) { $0.status = .stopped }
}

// MARK: - HELLO / data plane

/// Drives one peer to established: discovery → directory → channelOpened → peer HELLO.
@MainActor
func establishPeer(
    _ store: TestStore<BLEInterface.State, BLEInterface.Action>,
    _ events: AsyncStream<BLEDriverEvent>.Continuation,
    handle: BLEPeerHandle, channel: BLEChannelID, peerToken: Data
) async {
    events.yield(.peerDiscovered(handle))
    await store.receive(.driverEvent(.peerDiscovered(handle)))
    events.yield(.directoryRead(handle, version: 2, psm: 0x0081))
    await store.receive(.driverEvent(.directoryRead(handle, version: 2, psm: 0x0081)))
    events.yield(.channelOpened(channel, handle, direction: .outbound))
    await store.receive(.driverEvent(.channelOpened(channel, handle, direction: .outbound)))
    events.yield(.channelData(channel, framedHello(token: peerToken)))
    await store.receive(.driverEvent(.channelData(channel, framedHello(token: peerToken))))
    await store.receive(.delegate(.peerOnline(peerToken)))
}

@Test @MainActor func establishmentSendsHelloAndReportsPeerOnline() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    await establishPeer(store, events[0], handle: peerHandleA, channel: channel1, peerToken: tokenHigh)
    // Our HELLO went out on the channel, framed.
    #expect(calls.value.contains(.send(channel1, framedHello(token: localToken))))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func inboundChannelFollowsSameHelloPath() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound)))
    #expect(calls.value.contains(.send(channel1, framedHello(token: localToken))))
    events[0].yield(.channelData(channel1, framedHello(token: tokenHigh)))
    await store.receive(.driverEvent(.channelData(channel1, framedHello(token: tokenHigh))))
    await store.receive(.delegate(.peerOnline(tokenHigh)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func packetsFlowBothWaysAfterHello() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    await establishPeer(store, events[0], handle: peerHandleA, channel: channel1, peerToken: tokenHigh)
    // Inbound: a framed packet after HELLO surfaces as packetReceived.
    let packet = Data(repeating: 0xAB, count: 40)
    events[0].yield(.channelData(channel1, try! BLEFraming.frame(packet)))
    await store.receive(.driverEvent(.channelData(channel1, try! BLEFraming.frame(packet))))
    await store.receive(.delegate(.packetReceived(peer: tokenHigh, packet: packet)))
    // Outbound: .send frames and forwards to the driver.
    let outbound = Data(repeating: 0xCD, count: 21)
    await store.send(.send(peer: tokenHigh, packet: outbound))
    #expect(calls.value.contains(.send(channel1, try! BLEFraming.frame(outbound))))
    // Sending to an unknown peer is silently dropped.
    let before = calls.value.count
    await store.send(.send(peer: tokenLow, packet: outbound))
    #expect(calls.value.count == before)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func helloAndPacketInOneDeliveryBothProcessed() async {
    let (store, events, _, _, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound)))
    let packet = Data([0x01, 0x02, 0x03])
    let combined = framedHello(token: tokenHigh) + (try! BLEFraming.frame(packet))
    events[0].yield(.channelData(channel1, combined))
    await store.receive(.driverEvent(.channelData(channel1, combined)))
    await store.receive(.delegate(.peerOnline(tokenHigh)))
    await store.receive(.delegate(.packetReceived(peer: tokenHigh, packet: packet)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func invalidFirstFrameDropsChannelAndStrikes() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound)))
    // A validly-framed 20-byte frame that is NOT a HELLO (wrong magic).
    let bogus = try! BLEFraming.frame(Data(repeating: 0x51, count: 20))
    events[0].yield(.channelData(channel1, bogus))
    await store.receive(.driverEvent(.channelData(channel1, bogus)))
    #expect(calls.value.contains(.closeChannel(channel1)))
    // Strike recorded: discovery of the same handle is now ignored.
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(!calls.value.contains(.readDirectory(peerHandleA)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func helloEchoingOurOwnTokenIsRejected() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound)))
    events[0].yield(.channelData(channel1, framedHello(token: localToken)))
    await store.receive(.driverEvent(.channelData(channel1, framedHello(token: localToken))))
    #expect(calls.value.contains(.closeChannel(channel1)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func malformedFramingDropsChannel() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    await establishPeer(store, events[0], handle: peerHandleA, channel: channel1, peerToken: tokenHigh)
    events[0].yield(.channelData(channel1, Data([0x00, 0x00])))  // len == 0: unrecoverable
    await store.receive(.driverEvent(.channelData(channel1, Data([0x00, 0x00]))))
    await store.receive(.delegate(.peerOffline(tokenHigh)))
    #expect(calls.value.contains(.closeChannel(channel1)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func helloTimeoutDropsChannelAndStrikes() async {
    let (store, events, calls, clock, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound)))
    await clock.advance(by: BLEInterface.helloTimeout)
    await store.receive(.helloDeadline(channel1))
    #expect(calls.value.contains(.closeChannel(channel1)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func inboundChannelRefusedAtPeerCap() async {
    let (store, events, calls, _, _) = await makeOnlineStore(maxPeers: 1)
    await establishPeer(store, events[0], handle: peerHandleA, channel: channel1, peerToken: tokenHigh)
    events[0].yield(.channelOpened(channel2, peerHandleB, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel2, peerHandleB, direction: .inbound)))
    #expect(calls.value.contains(.closeChannel(channel2)))
    // The refused channel never got our HELLO.
    #expect(!calls.value.contains(.send(channel2, framedHello(token: localToken))))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func inboundOpenClearsPendingOutboundEstablishment() async {
    // Regression: if an inbound channel arrives while we have a pending outbound establishment
    // to the same handle, a later outbound failure (directoryFailed, channelFailed, or
    // establishDeadline) must NOT record a greylist strike against an already-online peer.
    let (store, events, calls, _, now) = await makeOnlineStore()
    // Kick off outbound establishment.
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA))) {
        $0.pendingPeers = [peerHandleA]
    }
    // Inbound channel arrives (cross-connect) before the outbound leg completes.
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound))) {
        $0.pendingPeers = []   // must be cleared for BOTH directions
    }
    // Complete the HELLO so the peer is fully online.
    events[0].yield(.channelData(channel1, framedHello(token: tokenHigh)))
    await store.receive(.driverEvent(.channelData(channel1, framedHello(token: tokenHigh))))
    await store.receive(.delegate(.peerOnline(tokenHigh)))
    // The outbound leg reports a late failure — this must NOT strike since pendingPeers is empty.
    events[0].yield(.directoryFailed(peerHandleA, reason: "late failure"))
    await store.receive(.driverEvent(.directoryFailed(peerHandleA, reason: "late failure"))) {
        $0.pendingPeers = []   // still empty — guard fires, no strike
    }
    // Advance time past the churn threshold so the subsequent channel close is NOT a strike.
    now.setValue(now.value.addingTimeInterval(BLEInterface.churnMinLifetime + 1))
    // Close the inbound channel.
    events[0].yield(.channelClosed(channel1, reason: nil))
    await store.receive(.driverEvent(.channelClosed(channel1, reason: nil)))
    await store.receive(.delegate(.peerOffline(tokenHigh)))
    // Re-discover: if no strike was recorded the handle passes the greylist gate,
    // producing a second readDirectory call.
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readDirectory(peerHandleA) }.count == 2)
    await store.send(.stop) { $0.status = .stopped }
}

// MARK: - Send failure paths

/// A send to a peer with no channel is a lifecycle race and drops quietly.
/// The bad send is LAST (after teardown) so no subsequent send clears the queue;
/// with .on exhaustivity teardown catches any stray delegate action that was emitted.
@Test @MainActor func sendToUnknownPeerDropsQuietly() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    await establishPeer(store, events[0], handle: peerHandleA, channel: channel1, peerToken: tokenHigh)

    // Teardown first — state.peers is now empty after .stop.
    await store.send(.stop) { $0.status = .stopped }
    // .stop emits .delegate(.peerOffline(tokenHigh)); tolerate it under .off so we
    // don't have to enumerate all teardown actions, then flip .on for the critical check.
    await store.receive(.delegate(.peerOffline(tokenHigh)))

    // Send to tokenLow — a token that has no established channel.
    // This is the last send; .on exhaustivity ensures teardown catches any stray delegate.
    let before = calls.value.count
    store.exhaustivity = .on
    await store.send(.send(peer: tokenLow, packet: Data(repeating: 0xAB, count: 10)))
    // No driver send (queue count unchanged).
    #expect(calls.value.count == before)
}

/// An oversized packet is a programmer error, not a lifecycle race: it must be
/// distinguishable rather than silently identical to a departed peer.
@Test @MainActor func sendOfUnframablePacketIsDistinguishedFromAbsentChannel() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    await establishPeer(store, events[0], handle: peerHandleA, channel: channel1, peerToken: tokenHigh)
    // Send a packet that exceeds BLEFraming.maxFrameLength to a LIVE peer.
    let oversized = Data(repeating: 0xFF, count: BLEFraming.maxFrameLength + 1)
    let before = calls.value.count
    await store.send(.send(peer: tokenHigh, packet: oversized))
    // No driver send.
    #expect(calls.value.count == before)
    // The sendFailed delegate action must be emitted, distinguishing this from a silent drop.
    await store.receive(.delegate(.sendFailed(peer: tokenHigh, reason: .unframable)))
    await store.send(.stop) { $0.status = .stopped }
}

// MARK: - Dedup

@Test @MainActor func crossConnectKeepsLowerInitiatorsChannelFromBothPerspectives() async {
    // Our token 0x11... vs peer 0x01...: PEER is lower, so the peer-initiated
    // (inbound-at-us) channel must survive regardless of arrival order.
    // Order 1: our outbound established first, then peer's inbound HELLOs.
    var (store, events, calls, _, _) = await makeOnlineStore()
    await establishPeer(store, events[0], handle: peerHandleA, channel: channel1, peerToken: tokenLow)
    events[0].yield(.channelOpened(channel2, peerHandleA, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel2, peerHandleA, direction: .inbound)))
    events[0].yield(.channelData(channel2, framedHello(token: tokenLow)))
    await store.receive(.driverEvent(.channelData(channel2, framedHello(token: tokenLow))))
    #expect(calls.value.contains(.closeChannel(channel1)))   // outbound (ours) loses
    #expect(!calls.value.contains(.closeChannel(channel2)))  // inbound (peer's) survives
    // The peer stayed online through the swap: traffic flows on the survivor.
    let packet = Data([0x0A, 0x0B, 0x0C])
    await store.send(.send(peer: tokenLow, packet: packet))
    #expect(calls.value.contains(.send(channel2, try! BLEFraming.frame(packet))))
    await store.send(.stop) { $0.status = .stopped }

    // Order 2: peer's inbound established first, then our outbound HELLOs back.
    (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel2, peerHandleA, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel2, peerHandleA, direction: .inbound)))
    events[0].yield(.channelData(channel2, framedHello(token: tokenLow)))
    await store.receive(.driverEvent(.channelData(channel2, framedHello(token: tokenLow))))
    await store.receive(.delegate(.peerOnline(tokenLow)))
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .outbound))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .outbound)))
    events[0].yield(.channelData(channel1, framedHello(token: tokenLow)))
    await store.receive(.driverEvent(.channelData(channel1, framedHello(token: tokenLow))))
    #expect(calls.value.contains(.closeChannel(channel1)))   // ours still loses
    // Traffic flows on the surviving inbound channel.
    await store.send(.send(peer: tokenLow, packet: Data([0x0D])))
    #expect(calls.value.contains(.send(channel2, try! BLEFraming.frame(Data([0x0D])))))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func sameDirectionHelloReplacesStaleChannelWithoutOfflineBlip() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound)))
    events[0].yield(.channelData(channel1, framedHello(token: tokenHigh)))
    await store.receive(.driverEvent(.channelData(channel1, framedHello(token: tokenHigh))))
    await store.receive(.delegate(.peerOnline(tokenHigh)))
    // Peer silently dropped and re-dialed: new inbound channel, same token.
    events[0].yield(.channelOpened(channel2, peerHandleA, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel2, peerHandleA, direction: .inbound)))
    events[0].yield(.channelData(channel2, framedHello(token: tokenHigh)))
    await store.receive(.driverEvent(.channelData(channel2, framedHello(token: tokenHigh))))
    #expect(calls.value.contains(.closeChannel(channel1)))  // stale channel closed
    // No peerOffline/second peerOnline was emitted; traffic now rides channel2.
    let packet = Data([0x01])
    await store.send(.send(peer: tokenHigh, packet: packet))
    #expect(calls.value.contains(.send(channel2, try! BLEFraming.frame(packet))))
    await store.send(.stop) { $0.status = .stopped }
}

// MARK: - Close policy / churn / adapter loss

@Test @MainActor func channelClosedTakesPeerOfflineWithoutChurnStrike() async {
    let (store, events, calls, _, now) = await makeOnlineStore()
    await establishPeer(store, events[0], handle: peerHandleA, channel: channel1, peerToken: tokenHigh)
    // Lives >= 10 s: no strike.
    now.setValue(now.value.addingTimeInterval(BLEInterface.churnMinLifetime))
    events[0].yield(.channelClosed(channel1, reason: "supervision timeout"))
    await store.receive(.driverEvent(.channelClosed(channel1, reason: "supervision timeout")))
    await store.receive(.delegate(.peerOffline(tokenHigh)))
    // No strike: rediscovery proceeds straight to a directory read.
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readDirectory(peerHandleA) }.count == 2)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func shortLivedChannelEarnsChurnStrike() async {
    let (store, events, calls, _, now) = await makeOnlineStore()
    await establishPeer(store, events[0], handle: peerHandleA, channel: channel1, peerToken: tokenHigh)
    // Lives < 10 s: strike.
    now.setValue(now.value.addingTimeInterval(BLEInterface.churnMinLifetime - 0.5))
    events[0].yield(.channelClosed(channel1, reason: nil))
    await store.receive(.driverEvent(.channelClosed(channel1, reason: nil)))
    await store.receive(.delegate(.peerOffline(tokenHigh)))
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readDirectory(peerHandleA) }.count == 1)  // blocked
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func closedChannelUnknownToStateIsIgnored() async {
    let (store, events, _, _, _) = await makeOnlineStore()
    events[0].yield(.channelClosed(channel2, reason: nil))
    await store.receive(.driverEvent(.channelClosed(channel2, reason: nil)))  // no crash, no delegate
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func adapterLossTakesPeersOfflineThenRecoversWithBackoff() async {
    let (store, events, calls, clock, _) = await makeOnlineStore(streams: 2)
    await establishPeer(store, events[0], handle: peerHandleA, channel: channel1, peerToken: tokenHigh)
    events[0].yield(.unavailable(.poweredOff))
    await store.receive(.driverEvent(.unavailable(.poweredOff))) {
        $0.status = .waitingForAdapter
        $0.channels = [:]
        $0.peers = [:]
        $0.pendingPeers = []
    }
    await store.receive(.delegate(.peerOffline(tokenHigh)))
    // First retry after 5 s.
    await clock.advance(by: BLEInterface.adapterRetryMin)
    await store.receive(.adapterRetry) { $0.status = .starting }
    #expect(calls.value.filter { $0 == .start }.count == 2)
    // Recovery: second stream reports ready; backoff delay resets.
    events[1].yield(.ready)
    await store.receive(.driverEvent(.ready)) {
        $0.status = .online
        $0.adapterRetryDelay = BLEInterface.adapterRetryMin
    }
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func adapterRetryDelayDoublesUpToCap() async {
    let (store, events, _, clock, _) = await makeOnlineStore(streams: 2)
    events[0].yield(.unavailable(.other(nil)))
    await store.receive(.driverEvent(.unavailable(.other(nil)))) {
        $0.status = .waitingForAdapter
        $0.adapterRetryDelay = .seconds(10)  // doubled after scheduling the 5 s retry
    }
    await clock.advance(by: BLEInterface.adapterRetryMin)
    await store.receive(.adapterRetry) { $0.status = .starting }
    // Second loss: the scheduled retry now uses 10 s, and the stored delay doubles to 20 s.
    events[1].yield(.unavailable(.other(nil)))
    await store.receive(.driverEvent(.unavailable(.other(nil)))) {
        $0.status = .waitingForAdapter
        $0.adapterRetryDelay = .seconds(20)
    }
    await clock.advance(by: .seconds(5))
    // 5 s is no longer enough — no retry yet.
    await clock.advance(by: .seconds(5))
    await store.receive(.adapterRetry) { $0.status = .starting }
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func stopWhileWaitingForAdapterCancelsRetry() async {
    let (store, events, calls, clock, _) = await makeOnlineStore()
    events[0].yield(.unavailable(.other(nil)))
    await store.receive(.driverEvent(.unavailable(.other(nil)))) { $0.status = .waitingForAdapter }
    await store.send(.stop) { $0.status = .stopped }
    let startsBefore = calls.value.filter { $0 == .start }.count
    await clock.advance(by: BLEInterface.adapterRetryMax)
    #expect(calls.value.filter { $0 == .start }.count == startsBefore)  // no retry fired
}

// MARK: - Terminal adapter unavailability (S6)

/// `unauthorized` (Bluetooth permission denied) is TERMINAL: unlike `poweredOff`, no amount of
/// retrying can resolve it, so the interface must stop the backoff loop, land in a terminal status,
/// take live peers offline, and SURFACE the cause via `adapterUnavailable` — the signal the app
/// turns into a "permission denied — open Settings" prompt (A5). Before S6 every `.unavailable`
/// folded into `waitingForAdapter` and re-probed forever, invisibly.
@Test @MainActor func unauthorizedIsTerminalStopsRetryingAndSurfaces() async {
    let (store, events, calls, clock, _) = await makeOnlineStore(streams: 2)
    await establishPeer(store, events[0], handle: peerHandleA, channel: channel1, peerToken: tokenHigh)
    events[0].yield(.unavailable(.unauthorized))
    await store.receive(.driverEvent(.unavailable(.unauthorized))) {
        $0.status = .unavailable(.unauthorized)
        $0.channels = [:]
        $0.peers = [:]
        $0.pendingPeers = []
    }
    await store.receive(.delegate(.peerOffline(tokenHigh)))
    await store.receive(.delegate(.adapterUnavailable(.unauthorized)))
    // Terminal: NO retry is scheduled. Advancing well past the max backoff must not re-start the
    // driver (the mutation that keeps the old waitingForAdapter+retry path fires a second .start).
    let startsBefore = calls.value.filter { $0 == .start }.count
    await clock.advance(by: BLEInterface.adapterRetryMax)
    #expect(calls.value.filter { $0 == .start }.count == startsBefore, "terminal state must not retry")
    await store.send(.stop) { $0.status = .stopped }
}

/// `unsupported` (no BLE LE radio, e.g. a Mac without the hardware) is likewise terminal and
/// surfaces its own cause.
@Test @MainActor func unsupportedIsTerminalAndSurfaces() async {
    let (store, events, calls, clock, _) = await makeOnlineStore()
    events[0].yield(.unavailable(.unsupported))
    await store.receive(.driverEvent(.unavailable(.unsupported))) {
        $0.status = .unavailable(.unsupported)
    }
    await store.receive(.delegate(.adapterUnavailable(.unsupported)))
    let startsBefore = calls.value.filter { $0 == .start }.count
    await clock.advance(by: BLEInterface.adapterRetryMax)
    #expect(calls.value.filter { $0 == .start }.count == startsBefore)
    await store.send(.stop) { $0.status = .stopped }
}

/// A terminal state is not a dead end: a fresh `.start` (the user granted permission and reconnected
/// / foregrounded) restarts the driver, rather than leaving the interface wedged. `poweredOff`'s
/// recovery already runs through the retry loop; terminal states have no loop, so `.start` is the
/// only way back — and it must be honoured.
@Test @MainActor func startRestartsFromTerminalUnavailable() async {
    let (store, events, calls, _, _) = await makeOnlineStore(streams: 2)
    events[0].yield(.unavailable(.unauthorized))
    await store.receive(.driverEvent(.unavailable(.unauthorized))) {
        $0.status = .unavailable(.unauthorized)
    }
    await store.receive(.delegate(.adapterUnavailable(.unauthorized)))
    let startsBefore = calls.value.filter { $0 == .start }.count
    await store.send(.start) { $0.status = .starting }
    #expect(calls.value.filter { $0 == .start }.count == startsBefore + 1,
            "start must restart the driver from a terminal state")
    await store.send(.stop) { $0.status = .stopped }
}
