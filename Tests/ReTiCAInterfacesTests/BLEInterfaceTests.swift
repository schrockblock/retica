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
