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
    let (store, events, _, clock, _) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    await clock.advance(by: BLEInterface.establishTimeout)
    await store.receive(.establishDeadline(peerHandleA)) { $0.pendingPeers = [] }
    // Late directoryRead for a no-longer-pending peer is ignored (no openChannel).
    events[0].yield(.directoryRead(peerHandleA, version: 2, psm: 0x0081))
    await store.receive(.driverEvent(.directoryRead(peerHandleA, version: 2, psm: 0x0081)))
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
