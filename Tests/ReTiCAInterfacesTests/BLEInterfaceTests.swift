import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

enum MockDriverCall: Equatable {
    case start
    case stop
    case readIdentity(BLEPeerHandle)
    case openChannel(BLEPeerHandle)
    case send(BLEChannelID, [Data])
    case closeChannel(BLEChannelID)
    case disconnect(BLEPeerHandle)
}

// Deterministic fixtures shared by all reducer tests.
let localIdentity = Data(repeating: 0x11, count: 16)
let peerHandleA = BLEPeerHandle(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
let peerHandleB = BLEPeerHandle(id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!)
let channel1 = BLEChannelID(id: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!)
let channel2 = BLEChannelID(id: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000002")!)
let identityLow = Data(repeating: 0x01, count: 16)    // sorts below localIdentity
let identityHigh = Data(repeating: 0xEE, count: 16)   // sorts above localIdentity
let testMTU = 512                                     // payload 507: any ≤500 B packet is one fragment

func frags(_ packet: Data, mtu: Int = testMTU) -> [Data] { try! BLEFragmenter(mtu: mtu).fragment(packet) }

@MainActor
func makeStore(maxPeers: Int = BLEInterface.defaultMaxPeers, streams: Int = 1,
               keepalive: Duration? = BLEInterface.defaultKeepaliveInterval)
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
    let store = TestStore(initialState: BLEInterface.State(localIdentity: localIdentity, maxPeers: maxPeers,
                                                           keepaliveInterval: keepalive)) {
        BLEInterface()
    } withDependencies: {
        $0.bleDriver = BLEDriver(
            start: { _ in
                calls.withValue { $0.append(.start) }
                let n = startCount.withValue { $0 += 1; return $0 }
                return n <= made.count ? made[n - 1].stream : AsyncStream { _ in }
            },
            readIdentity: { h in calls.withValue { $0.append(.readIdentity(h)) } },
            openChannel: { h in calls.withValue { $0.append(.openChannel(h)) } },
            send: { c, d in calls.withValue { $0.append(.send(c, d)) } },
            closeChannel: { c in calls.withValue { $0.append(.closeChannel(c)) } },
            disconnect: { h in calls.withValue { $0.append(.disconnect(h)) } },
            stop: { calls.withValue { $0.append(.stop) } }
        )
        $0.continuousClock = clock
        $0.bleDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    return (store, made.map { $0.continuation }, calls, clock, now)
}

@MainActor
func makeOnlineStore(maxPeers: Int = BLEInterface.defaultMaxPeers, streams: Int = 1,
                     keepalive: Duration? = BLEInterface.defaultKeepaliveInterval)
    async -> (store: TestStore<BLEInterface.State, BLEInterface.Action>,
              events: [AsyncStream<BLEDriverEvent>.Continuation],
              calls: LockIsolated<[MockDriverCall]>,
              clock: TestClock<Duration>,
              now: LockIsolated<Date>)
{
    let (store, events, calls, clock, now) = makeStore(maxPeers: maxPeers, streams: streams, keepalive: keepalive)
    await store.send(.start) { $0.status = .starting }
    events[0].yield(.ready)
    await store.receive(.driverEvent(.ready)) { $0.status = .online }
    return (store, events, calls, clock, now)
}

/// Outbound establishment: discovery → identityRead → channelOpened(.outbound) → peerOnline.
@MainActor
func establishOutbound(
    _ store: TestStore<BLEInterface.State, BLEInterface.Action>,
    _ events: AsyncStream<BLEDriverEvent>.Continuation,
    handle: BLEPeerHandle, channel: BLEChannelID, identity: Data
) async {
    events.yield(.peerDiscovered(handle))
    await store.receive(.driverEvent(.peerDiscovered(handle)))
    events.yield(.identityRead(handle, identity: identity))
    await store.receive(.driverEvent(.identityRead(handle, identity: identity)))
    events.yield(.channelOpened(channel, handle, direction: .outbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel, handle, direction: .outbound, mtu: testMTU)))
    await store.receive(.delegate(.peerOnline(identity)))
}

/// Inbound establishment: channelOpened(.inbound) → 16-byte handshake → peerOnline.
@MainActor
func establishInbound(
    _ store: TestStore<BLEInterface.State, BLEInterface.Action>,
    _ events: AsyncStream<BLEDriverEvent>.Continuation,
    handle: BLEPeerHandle, channel: BLEChannelID, identity: Data
) async {
    events.yield(.channelOpened(channel, handle, direction: .inbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel, handle, direction: .inbound, mtu: testMTU)))
    events.yield(.channelData(channel, identity))
    await store.receive(.driverEvent(.channelData(channel, identity)))
    await store.receive(.delegate(.peerOnline(identity)))
}

// MARK: - Lifecycle

@Test @MainActor func startComesOnlineOnReady() async {
    let (store, events, calls, _, _) = makeStore()
    await store.send(.start) { $0.status = .starting }
    #expect(calls.value == [.start])
    events[0].yield(.ready)
    await store.receive(.driverEvent(.ready)) { $0.status = .online }
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func startWhileRunningIsIgnored() async {
    let (store, events, calls, _, _) = makeStore()
    await store.send(.start) { $0.status = .starting }
    events[0].yield(.ready)
    await store.receive(.driverEvent(.ready)) { $0.status = .online }
    await store.send(.start)
    #expect(calls.value.filter { $0 == .start }.count == 1)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func stopCallsDriverStop() async {
    let (store, events, calls, _, _) = makeStore()
    await store.send(.start) { $0.status = .starting }
    events[0].yield(.ready)
    await store.receive(.driverEvent(.ready)) { $0.status = .online }
    await store.send(.stop) { $0.status = .stopped }
    #expect(calls.value.contains(.stop))
}

// MARK: - Discovery / establishment (central role)

@Test @MainActor func discoveryReadsIdentityThenOpensChannel() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA))) { $0.pendingPeers = [peerHandleA] }
    #expect(calls.value.contains(.readIdentity(peerHandleA)))
    events[0].yield(.identityRead(peerHandleA, identity: identityHigh))
    await store.receive(.driverEvent(.identityRead(peerHandleA, identity: identityHigh))) {
        $0.pendingIdentities = [peerHandleA: identityHigh]
    }
    #expect(calls.value.contains(.openChannel(peerHandleA)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func ownIdentityIsRefusedDisconnectedAndGreylisted() async {
    let (store, events, calls, _, now) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.identityRead(peerHandleA, identity: localIdentity))
    await store.receive(.driverEvent(.identityRead(peerHandleA, identity: localIdentity))) { $0.pendingPeers = [] }
    await store.finish()
    #expect(!calls.value.contains(.openChannel(peerHandleA)))
    #expect(calls.value.contains(.disconnect(peerHandleA)))
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readIdentity(peerHandleA) }.count == 1)   // blocked
    now.setValue(now.value.addingTimeInterval(5.01))
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readIdentity(peerHandleA) }.count == 2)   // backoff expired
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func shortIdentityIsRefused() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.identityRead(peerHandleA, identity: Data(repeating: 1, count: 15)))
    await store.receive(.driverEvent(.identityRead(peerHandleA, identity: Data(repeating: 1, count: 15)))) { $0.pendingPeers = [] }
    #expect(!calls.value.contains(.openChannel(peerHandleA)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func identityFailureStrikesAndPendingPeerIsNotRediscovered() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.peerDiscovered(peerHandleA))                     // pending: ignored
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readIdentity(peerHandleA) }.count == 1)
    events[0].yield(.identityFailed(peerHandleA, reason: "no identity characteristic"))
    await store.receive(.driverEvent(.identityFailed(peerHandleA, reason: "no identity characteristic"))) { $0.pendingPeers = [] }
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readIdentity(peerHandleA) }.count == 1)   // strike blocks
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func establishDeadlineAbandonsStrikesAndDisconnects() async {
    let (store, events, calls, clock, _) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.identityRead(peerHandleA, identity: identityHigh))
    await store.receive(.driverEvent(.identityRead(peerHandleA, identity: identityHigh)))
    await clock.advance(by: BLEInterface.establishTimeout)
    await store.receive(.establishDeadline(peerHandleA)) {
        $0.pendingPeers = []
        $0.pendingIdentities = [:]
    }
    // A late channelOpened for the abandoned peer has no pending identity → closed, no peer.
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .outbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .outbound, mtu: testMTU)))
    await store.finish()
    #expect(calls.value.contains(.disconnect(peerHandleA)))
    #expect(calls.value.contains(.closeChannel(channel1)))
    #expect(store.state.peers.isEmpty)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func establishDeadlineForPeerEstablishedInboundClearsPendingWithoutStrikeOrDisconnect() async {
    let (store, events, calls, clock, now) = await makeOnlineStore(keepalive: nil)
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA))) { $0.pendingPeers = [peerHandleA] }
    await establishInbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    #expect(store.state.pendingPeers == [peerHandleA])            // inbound open leaves the dial alive
    await clock.advance(by: BLEInterface.establishTimeout)
    await store.receive(.establishDeadline(peerHandleA)) { $0.pendingPeers = [] }
    await store.finish()
    #expect(!calls.value.contains(.disconnect(peerHandleA)), "must not touch the live inbound link")
    #expect(!store.state.greylist.isBlocked(peerHandleA, now: now.value), "must not strike")
    #expect(store.state.peers[identityHigh] == channel1)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func discoveryIsIgnoredAtPeerCap() async {
    let (store, events, calls, _, _) = await makeOnlineStore(maxPeers: 1)
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.peerDiscovered(peerHandleB))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleB)))
    #expect(calls.value.filter { if case .readIdentity = $0 { return true } else { return false } }.count == 1)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func identityPreCheckAbandonsRedundantDial() async {
    // Peer HIGH is already connected inbound. HIGH > local, so on a cross-connect the channel
    // initiated by LOCAL (lower) would win — i.e. the rule says keepNew for an outbound dial.
    // Use LOW instead: LOW < local → the peer-initiated (inbound) channel wins → keepExisting → skip.
    let (store, events, calls, _, _) = await makeOnlineStore()
    await establishInbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityLow)
    events[0].yield(.peerDiscovered(peerHandleB))          // same device seen under a new handle
    await store.receive(.driverEvent(.peerDiscovered(peerHandleB)))
    events[0].yield(.identityRead(peerHandleB, identity: identityLow))
    await store.receive(.driverEvent(.identityRead(peerHandleB, identity: identityLow))) { $0.pendingPeers = [] }
    await store.finish()
    #expect(!calls.value.contains(.openChannel(peerHandleB)))
    #expect(calls.value.contains(.disconnect(peerHandleB)))
    // Not a strike: a fresh discovery of handle B reads its identity again.
    events[0].yield(.peerDiscovered(peerHandleB))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleB)))
    #expect(calls.value.filter { $0 == .readIdentity(peerHandleB) }.count == 2)
    await store.send(.stop) { $0.status = .stopped }
}

// MARK: - Handshake (peripheral role)

@Test @MainActor func outboundEstablishmentReportsPeerOnlineWithoutAnyHandshakeFrame() async {
    let (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    // The driver wrote the handshake itself; the reducer sends nothing at establishment.
    #expect(!calls.value.contains { if case .send = $0 { return true } else { return false } })
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func inboundHandshakeReportsPeerOnline() async {
    let (store, events, _, _, _) = await makeOnlineStore()
    await establishInbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    #expect(store.state.peers[identityHigh] == channel1)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func preHandshakeJunkIsDroppedWithoutStrike() async {
    let (store, events, calls, clock, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: testMTU)))
    let junk = frags(Data([1, 2, 3]))[0]                       // a fragment before any handshake
    events[0].yield(.channelData(channel1, junk))
    await store.receive(.driverEvent(.channelData(channel1, junk)))
    #expect(!calls.value.contains(.closeChannel(channel1)))
    // The handshake can still arrive afterwards.
    events[0].yield(.channelData(channel1, identityHigh))
    await store.receive(.driverEvent(.channelData(channel1, identityHigh)))
    await store.receive(.delegate(.peerOnline(identityHigh)))
    await clock.advance(by: BLEInterface.handshakeTimeout)   // deadline was cancelled: no teardown
    #expect(!calls.value.contains(.closeChannel(channel1)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func handshakeEchoingOurOwnIdentityIsIgnored() async {
    let (store, events, _, clock, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: testMTU)))
    events[0].yield(.channelData(channel1, localIdentity))
    await store.receive(.driverEvent(.channelData(channel1, localIdentity)))
    #expect(store.state.peers.isEmpty)
    await clock.advance(by: BLEInterface.handshakeTimeout)
    await store.receive(.handshakeDeadline(channel1))
    #expect(store.state.channels.isEmpty)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func handshakeTimeoutDropsChannelAndStrikes() async {
    let (store, events, calls, clock, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: testMTU)))
    await clock.advance(by: BLEInterface.handshakeTimeout)
    await store.receive(.handshakeDeadline(channel1))
    #expect(calls.value.contains(.closeChannel(channel1)))
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(!calls.value.contains(.readIdentity(peerHandleA)))   // struck
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func inboundChannelRefusedAtPeerCap() async {
    let (store, events, calls, _, _) = await makeOnlineStore(maxPeers: 1)
    await establishInbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    events[0].yield(.channelOpened(channel2, peerHandleB, direction: .inbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel2, peerHandleB, direction: .inbound, mtu: testMTU)))
    #expect(calls.value.contains(.closeChannel(channel2)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func inboundOpenLeavesPendingOutboundAliveAndLateFailureDoesNotStrike() async {
    let (store, events, calls, _, now) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA))) { $0.pendingPeers = [peerHandleA] }
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: testMTU))) {
        $0.pendingPeers = [peerHandleA]            // our outbound dial is still in flight
    }
    events[0].yield(.channelData(channel1, identityHigh))
    await store.receive(.driverEvent(.channelData(channel1, identityHigh)))
    await store.receive(.delegate(.peerOnline(identityHigh)))
    events[0].yield(.identityFailed(peerHandleA, reason: "late failure"))
    await store.receive(.driverEvent(.identityFailed(peerHandleA, reason: "late failure"))) { $0.pendingPeers = [] }
    #expect(!store.state.greylist.isBlocked(peerHandleA, now: now.value), "late failure for an established peer must not strike")
    now.setValue(now.value.addingTimeInterval(BLEInterface.churnMinLifetime + 1))
    events[0].yield(.channelClosed(channel1, reason: nil))
    await store.receive(.driverEvent(.channelClosed(channel1, reason: nil)))
    await store.receive(.delegate(.peerOffline(identityHigh)))
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readIdentity(peerHandleA) }.count == 2)   // no strike
    await store.send(.stop) { $0.status = .stopped }
}

// MARK: - Data plane

@Test @MainActor func packetsFlowBothWaysFragmented() async {
    let (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    // Inbound: three fragments at the peer's MTU 23 → one packetReceived.
    let packet = Data((0..<40).map { UInt8($0) })
    let inbound = frags(packet, mtu: 23)
    for f in inbound {
        events[0].yield(.channelData(channel1, f))
        await store.receive(.driverEvent(.channelData(channel1, f)))
    }
    await store.receive(.delegate(.packetReceived(peer: identityHigh, packet: packet)))
    // Outbound: .send fragments at OUR channel MTU (512) → one driver send here.
    let outbound = Data(repeating: 0xCD, count: 21)
    await store.send(.send(peer: identityHigh, packet: outbound))
    await store.finish()
    #expect(calls.value.contains(.send(channel1, frags(outbound))))
    let before = calls.value.count
    await store.send(.send(peer: identityLow, packet: outbound))   // unknown peer: dropped
    #expect(calls.value.count == before)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func outboundSendDeliversAllFragmentsInOneOrderedCall() async {
    let (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: 23))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: 23)))
    events[0].yield(.channelData(channel1, identityHigh))
    await store.receive(.driverEvent(.channelData(channel1, identityHigh)))
    await store.receive(.delegate(.peerOnline(identityHigh)))
    let packet = Data(repeating: 0xAB, count: 50)             // 3 fragments at MTU 23
    await store.send(.send(peer: identityHigh, packet: packet))
    await store.finish()
    let sends = calls.value.compactMap { if case let .send(c, d) = $0, c == channel1 { return d } else { return nil } }
    #expect(sends == [frags(packet, mtu: 23)])               // one call, three fragments, in order
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func malformedFragmentLeavesChannelUp() async {
    let (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    events[0].yield(.channelData(channel1, Data([0x07, 0, 0, 0, 1, 0xAA])))   // bad type
    await store.receive(.driverEvent(.channelData(channel1, Data([0x07, 0, 0, 0, 1, 0xAA]))))
    #expect(!calls.value.contains(.closeChannel(channel1)))
    let packet = Data([9, 9, 9])
    events[0].yield(.channelData(channel1, frags(packet)[0]))
    await store.receive(.driverEvent(.channelData(channel1, frags(packet)[0])))
    await store.receive(.delegate(.packetReceived(peer: identityHigh, packet: packet)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func keepaliveByteIsIgnoredOnReceipt() async {
    let (store, events, _, _, _) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    store.exhaustivity = .on
    events[0].yield(.channelData(channel1, BLEKeepalive.frame))
    await store.receive(.driverEvent(.channelData(channel1, BLEKeepalive.frame)))   // no delegate
    store.exhaustivity = .off
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func sixteenByteFragmentAfterHandshakeIsData() async {
    // Review Focus 1: once the identity is known, a 16-byte write is a fragment, not a handshake.
    let (store, events, _, _, _) = await makeOnlineStore(keepalive: nil)
    await establishInbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    let packet = Data(repeating: 0x42, count: 11)              // 5 header + 11 = 16 bytes on the wire
    let f = frags(packet)[0]
    #expect(f.count == 16)
    events[0].yield(.channelData(channel1, f))
    await store.receive(.driverEvent(.channelData(channel1, f)))
    await store.receive(.delegate(.packetReceived(peer: identityHigh, packet: packet)))
    #expect(store.state.peers.count == 1)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func lateEventsForTornDownChannelAreIgnored() async {
    // Review Focus 2.
    let (store, events, calls, _, now) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    now.setValue(now.value.addingTimeInterval(BLEInterface.churnMinLifetime + 1))
    events[0].yield(.channelClosed(channel1, reason: nil))
    await store.receive(.driverEvent(.channelClosed(channel1, reason: nil)))
    await store.receive(.delegate(.peerOffline(identityHigh)))
    store.exhaustivity = .on
    events[0].yield(.channelData(channel1, frags(Data([1]))[0]))
    await store.receive(.driverEvent(.channelData(channel1, frags(Data([1]))[0])))
    events[0].yield(.channelClosed(channel1, reason: nil))
    await store.receive(.driverEvent(.channelClosed(channel1, reason: nil)))
    store.exhaustivity = .off
    // No strike from the duplicate close: rediscovery reads identity again.
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readIdentity(peerHandleA) }.count == 2)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func sendOfUnfragmentablePacketIsDistinguishedFromAbsentChannel() async {
    let (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    let before = calls.value.count
    await store.send(.send(peer: identityHigh, packet: Data()))
    #expect(calls.value.count == before)
    await store.receive(.delegate(.sendFailed(peer: identityHigh, reason: .unfragmentable)))
    await store.send(.stop) { $0.status = .stopped }
}

// MARK: - Keepalive

@Test @MainActor func keepaliveFiresOnOutboundChannelsEveryIntervalAndStopsOnClose() async {
    let (store, events, calls, clock, now) = await makeOnlineStore()
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    await clock.advance(by: BLEInterface.defaultKeepaliveInterval)
    await store.receive(.keepalive(channel1))
    await clock.advance(by: BLEInterface.defaultKeepaliveInterval)
    await store.receive(.keepalive(channel1))
    await store.finish()
    #expect(calls.value.filter { $0 == .send(channel1, [BLEKeepalive.frame]) }.count == 2)
    now.setValue(now.value.addingTimeInterval(BLEInterface.churnMinLifetime + 1))
    events[0].yield(.channelClosed(channel1, reason: nil))
    await store.receive(.driverEvent(.channelClosed(channel1, reason: nil)))
    await store.receive(.delegate(.peerOffline(identityHigh)))
    await clock.advance(by: BLEInterface.defaultKeepaliveInterval * 2)
    #expect(calls.value.filter { $0 == .send(channel1, [BLEKeepalive.frame]) }.count == 2)   // stopped
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func keepaliveNeverRunsOnInboundChannels() async {
    let (store, events, calls, clock, _) = await makeOnlineStore()
    await establishInbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    await clock.advance(by: BLEInterface.defaultKeepaliveInterval * 2)
    #expect(!calls.value.contains(.send(channel1, [BLEKeepalive.frame])))
    // No timer is armed for inbound, so also drive a stray tick directly: the reducer refuses it.
    await store.send(.keepalive(channel1))
    await store.finish()
    #expect(!calls.value.contains(.send(channel1, [BLEKeepalive.frame])))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func keepaliveCanBeDisabled() async {
    let (store, events, calls, clock, _) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    await clock.advance(by: BLEInterface.defaultKeepaliveInterval * 2)
    #expect(!calls.value.contains(.send(channel1, [BLEKeepalive.frame])))
    await store.send(.stop) { $0.status = .stopped }
}

// MARK: - Duplicate resolution

@Test @MainActor func crossConnectKeepsLowerInitiatorsChannelFromBothPerspectives() async {
    // Peer LOW < local: the peer-initiated (inbound-at-us) channel survives regardless of order.
    var (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityLow)
    events[0].yield(.channelOpened(channel2, peerHandleA, direction: .inbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel2, peerHandleA, direction: .inbound, mtu: testMTU)))
    events[0].yield(.channelData(channel2, identityLow))
    await store.receive(.driverEvent(.channelData(channel2, identityLow)))
    await store.finish()
    #expect(calls.value.contains(.closeChannel(channel1)))
    #expect(!calls.value.contains(.closeChannel(channel2)))
    let packet = Data([0x0A, 0x0B, 0x0C])
    await store.send(.send(peer: identityLow, packet: packet))
    await store.finish()
    #expect(calls.value.contains(.send(channel2, frags(packet))))
    await store.send(.stop) { $0.status = .stopped }

    // Order 2: inbound first, then our outbound completes → ours still loses.
    (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishInbound(store, events[0], handle: peerHandleA, channel: channel2, identity: identityLow)
    events[0].yield(.peerDiscovered(peerHandleB))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleB)))
    events[0].yield(.identityRead(peerHandleB, identity: identityLow))
    await store.receive(.driverEvent(.identityRead(peerHandleB, identity: identityLow)))
    await store.finish()
    #expect(!calls.value.contains(.openChannel(peerHandleB)))   // pre-check: never dialed
    await store.send(.send(peer: identityLow, packet: Data([0x0D])))
    await store.finish()
    #expect(calls.value.contains(.send(channel2, frags(Data([0x0D])))))
    await store.send(.stop) { $0.status = .stopped }

    // Peer HIGH > local: OUR outbound channel survives a later inbound.
    (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    events[0].yield(.channelOpened(channel2, peerHandleA, direction: .inbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel2, peerHandleA, direction: .inbound, mtu: testMTU)))
    events[0].yield(.channelData(channel2, identityHigh))
    await store.receive(.driverEvent(.channelData(channel2, identityHigh)))
    await store.finish()
    #expect(calls.value.contains(.closeChannel(channel2)))
    #expect(!calls.value.contains(.closeChannel(channel1)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func sameDirectionHandshakeReplacesStaleChannelWithoutOfflineBlip() async {
    // Review Focus 4 (reducer half).
    let (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishInbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    store.exhaustivity = .on
    events[0].yield(.channelOpened(channel2, peerHandleA, direction: .inbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel2, peerHandleA, direction: .inbound, mtu: testMTU))) {
        $0.channels[channel2] = BLEInterface.ChannelState(
            peer: peerHandleA, direction: .inbound, fragmenter: BLEFragmenter(mtu: testMTU),
            reassembler: BLEReassembler(), peerIdentity: nil, openedAt: Date(timeIntervalSince1970: 1_000))
    }
    events[0].yield(.channelData(channel2, identityHigh))
    await store.receive(.driverEvent(.channelData(channel2, identityHigh))) {
        $0.channels[channel1] = nil
        $0.channels[channel2]?.peerIdentity = identityHigh
        $0.peers[identityHigh] = channel2
    }
    store.exhaustivity = .off
    await store.finish()
    #expect(calls.value.contains(.closeChannel(channel1)))
    await store.send(.send(peer: identityHigh, packet: Data([0x01])))
    await store.finish()
    #expect(calls.value.contains(.send(channel2, frags(Data([0x01])))))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func crossConnectWithInFlightOutboundKeepsExactlyOneChannel() async {
    // (i) Peer LOW < local: our dial is in flight when the peer's inbound channel arrives and
    // completes its handshake; our outbound channel then opens and loses — the inbound survives.
    var (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.identityRead(peerHandleA, identity: identityLow))
    await store.receive(.driverEvent(.identityRead(peerHandleA, identity: identityLow))) {
        $0.pendingIdentities = [peerHandleA: identityLow]
    }
    await store.finish()
    #expect(calls.value.contains(.openChannel(peerHandleA)))
    await establishInbound(store, events[0], handle: peerHandleA, channel: channel2, identity: identityLow)
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .outbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .outbound, mtu: testMTU)))
    await store.finish()
    #expect(calls.value.contains(.closeChannel(channel1)))
    #expect(!calls.value.contains(.closeChannel(channel2)))
    #expect(store.state.peers[identityLow] == channel2)
    #expect(store.state.channels.count == 1)
    await store.send(.send(peer: identityLow, packet: Data([0x0E])))
    await store.finish()
    #expect(calls.value.contains(.send(channel2, frags(Data([0x0E])))))
    await store.send(.stop) { $0.status = .stopped }

    // (ii) Peer HIGH > local: same ordering, but OUR outbound channel wins and replaces the
    // inbound one under the peer without an offline blip.
    (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.identityRead(peerHandleA, identity: identityHigh))
    await store.receive(.driverEvent(.identityRead(peerHandleA, identity: identityHigh))) {
        $0.pendingIdentities = [peerHandleA: identityHigh]
    }
    await establishInbound(store, events[0], handle: peerHandleA, channel: channel2, identity: identityHigh)
    store.exhaustivity = .on
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .outbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .outbound, mtu: testMTU))) {
        $0.pendingPeers = []
        $0.pendingIdentities = [:]
        $0.channels[channel2] = nil
        $0.channels[channel1] = BLEInterface.ChannelState(
            peer: peerHandleA, direction: .outbound, fragmenter: BLEFragmenter(mtu: testMTU),
            reassembler: BLEReassembler(), peerIdentity: identityHigh, openedAt: Date(timeIntervalSince1970: 1_000))
        $0.peers[identityHigh] = channel1
    }
    // Still exhaustive: a send emits no actions, so any queued peerOffline/peerOnline from the
    // swap would be reported as unhandled here.
    await store.send(.send(peer: identityHigh, packet: Data([0x0D])))
    store.exhaustivity = .off
    await store.finish()
    #expect(calls.value.contains(.closeChannel(channel2)))
    #expect(!calls.value.contains(.closeChannel(channel1)))
    #expect(store.state.peers[identityHigh] == channel1)
    #expect(store.state.channels.count == 1)
    #expect(calls.value.contains(.send(channel1, frags(Data([0x0D])))))
    await store.send(.stop) { $0.status = .stopped }
}

// MARK: - Close policy / churn / adapter loss

@Test @MainActor func channelClosedTakesPeerOfflineWithoutChurnStrike() async {
    let (store, events, calls, _, now) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    now.setValue(now.value.addingTimeInterval(BLEInterface.churnMinLifetime))
    events[0].yield(.channelClosed(channel1, reason: "supervision timeout"))
    await store.receive(.driverEvent(.channelClosed(channel1, reason: "supervision timeout")))
    await store.receive(.delegate(.peerOffline(identityHigh)))
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readIdentity(peerHandleA) }.count == 2)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func shortLivedChannelEarnsChurnStrike() async {
    let (store, events, calls, _, now) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    now.setValue(now.value.addingTimeInterval(BLEInterface.churnMinLifetime - 0.5))
    events[0].yield(.channelClosed(channel1, reason: nil))
    await store.receive(.driverEvent(.channelClosed(channel1, reason: nil)))
    await store.receive(.delegate(.peerOffline(identityHigh)))
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readIdentity(peerHandleA) }.count == 1)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func closedChannelUnknownToStateIsIgnored() async {
    let (store, events, _, _, _) = await makeOnlineStore()
    events[0].yield(.channelClosed(channel2, reason: nil))
    await store.receive(.driverEvent(.channelClosed(channel2, reason: nil)))  // no crash, no delegate
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func adapterLossTakesPeersOfflineThenRecoversWithBackoff() async {
    let (store, events, calls, clock, _) = await makeOnlineStore(streams: 2, keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    events[0].yield(.unavailable(.poweredOff))
    await store.receive(.driverEvent(.unavailable(.poweredOff))) {
        $0.status = .waitingForAdapter
        $0.channels = [:]
        $0.peers = [:]
        $0.pendingPeers = []
    }
    await store.receive(.delegate(.peerOffline(identityHigh)))
    await clock.advance(by: BLEInterface.adapterRetryMin)
    await store.receive(.adapterRetry) { $0.status = .starting }
    #expect(calls.value.filter { $0 == .start }.count == 2)
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
        $0.adapterRetryDelay = .seconds(10)
    }
    await clock.advance(by: BLEInterface.adapterRetryMin)
    await store.receive(.adapterRetry) { $0.status = .starting }
    events[1].yield(.unavailable(.other(nil)))
    await store.receive(.driverEvent(.unavailable(.other(nil)))) {
        $0.status = .waitingForAdapter
        $0.adapterRetryDelay = .seconds(20)
    }
    await clock.advance(by: .seconds(5))
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

@Test @MainActor func unauthorizedIsTerminalStopsRetryingAndSurfaces() async {
    let (store, events, calls, clock, _) = await makeOnlineStore(streams: 2, keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    events[0].yield(.unavailable(.unauthorized))
    await store.receive(.driverEvent(.unavailable(.unauthorized))) {
        $0.status = .unavailable(.unauthorized)
        $0.channels = [:]
        $0.peers = [:]
        $0.pendingPeers = []
    }
    await store.receive(.delegate(.peerOffline(identityHigh)))
    await store.receive(.delegate(.adapterUnavailable(.unauthorized)))
    let startsBefore = calls.value.filter { $0 == .start }.count
    await clock.advance(by: BLEInterface.adapterRetryMax)
    #expect(calls.value.filter { $0 == .start }.count == startsBefore)
    await store.send(.start) { $0.status = .starting }
    #expect(calls.value.filter { $0 == .start }.count == startsBefore + 1)
    await store.send(.stop) { $0.status = .stopped }
}

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
