import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

enum RNodeMockCall: Equatable {
    case start(RNodeDriverConfig)
    case send(Data)
    case stop
}

extension Array where Element == RNodeMockCall {
    var rnodeSentPackets: [Data] {
        compactMap { call in
            if case let .send(packet) = call { return packet }
            return nil
        }
    }

    var rnodeStartCount: Int {
        filter { if case .start = $0 { return true }; return false }.count
    }
}

let rnodeTestRadio = UUID(uuidString: "0000AAAA-0000-0000-0000-00000000BEEF")!
/// 868.1 MHz, 62.5 kHz, 0 dBm, SF 8, CR 6: not a default anywhere, so a driver handed defaults is caught.
let rnodeTestParams = RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 62_500, txPowerDBm: 0,
                                      spreadingFactor: 8, codingRate: 6)
let rnodeTestConfig = RNodeDriverConfig(radio: rnodeTestRadio, params: rnodeTestParams)
let rnodeTestReport = RNodeRadioReport(firmwareMajor: 1, firmwareMinor: 86, platform: 0x80,
                                       params: rnodeTestParams)

/// Runs the real interface and logs every delegate action in REDUCE order, so a test can assert
/// that one was NOT emitted (exhaustivity is off, so `receive` alone can't).
struct RNodeDelegateRecorder: Reducer {
    typealias State = RNodeInterface.State
    typealias Action = RNodeInterface.Action
    let delegates: LockIsolated<[RNodeInterface.Action.Delegate]>

    func reduce(into state: inout State, action: Action) -> Effect<Action> {
        if case let .delegate(delegate) = action { delegates.withValue { $0.append(delegate) } }
        return RNodeInterface().reduce(into: &state, action: action)
    }
}

/// Holds every driver `send` until `open()`: the call is recorded at once, the return waits.
final class RNodeSendGate: Sendable {
    private let state = LockIsolated<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let pass = state.withValue { gate -> Bool in
                if gate.open { return true }
                gate.waiters.append(continuation)
                return false
            }
            if pass { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withValue { gate -> [CheckedContinuation<Void, Never>] in
            gate.open = true
            defer { gate.waiters = [] }
            return gate.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

@MainActor
struct RNodeInterfaceHarness {
    let store: TestStore<RNodeInterface.State, RNodeInterface.Action>
    /// One continuation per driver session: the first is made up front (so events yielded before
    /// `.start` reach the first session), every later `driver.start` appends a fresh one.
    let radios: LockIsolated<[AsyncStream<RNodeDriverEvent>.Continuation]>
    let calls: LockIsolated<[RNodeMockCall]>
    /// Every driver `send` waits on it. Open unless `holdSends`.
    let gate: RNodeSendGate
    /// Every delegate the interface emitted, in reduce order.
    let delegates: LockIsolated<[RNodeInterface.Action.Delegate]>

    /// The latest session's event stream. A `.stop` cancels the session's `for await`, which ends
    /// its stream for good, so a restarted interface needs a fresh one, as a live driver gives.
    var radio: AsyncStream<RNodeDriverEvent>.Continuation { radios.value[radios.value.count - 1] }

    var packets: [Data] {
        delegates.value.compactMap { if case let .packetReceived(packet) = $0 { return packet }; return nil }
    }

    var sent: [Data] { calls.value.rnodeSentPackets }

    /// Polls until at least `count` driver sends happened, without failing: the caller's
    /// `#expect` judges.
    func waitForSends(_ count: Int) async {
        for _ in 0..<400 where sent.count < count { await Task.megaYield() }
    }

    /// Polls until at least `count` driver starts happened, without failing.
    func waitForStarts(_ count: Int) async {
        for _ in 0..<400 where calls.value.rnodeStartCount < count { await Task.megaYield() }
    }
}

/// An RNodeInterface over a mock radio. Every `driver.start` gets its own session stream (see
/// `radios`). `sendResults` are returned by successive driver `send`s (then `true`). With
/// `holdSends`, every driver `send` is recorded at once and returns only after `gate.open()`.
/// Every `receive` waits up to 5 s.
@MainActor
func makeRNodeInterface(sendResults: [Bool] = [], holdSends: Bool = false) -> RNodeInterfaceHarness {
    let first = AsyncStream<RNodeDriverEvent>.makeStream()
    let radios = LockIsolated([first.continuation])
    let sessions = LockIsolated(0)
    let calls = LockIsolated<[RNodeMockCall]>([])
    let results = LockIsolated(sendResults)
    let gate = RNodeSendGate()
    if !holdSends { gate.open() }
    let delegates = LockIsolated<[RNodeInterface.Action.Delegate]>([])
    let store = TestStore(initialState: RNodeInterface.State(config: rnodeTestConfig)) {
        RNodeDelegateRecorder(delegates: delegates)
    } withDependencies: {
        $0.rnodeDriver = RNodeDriver(
            start: { config in
                calls.withValue { $0.append(.start(config)) }
                let index = sessions.withValue { n in defer { n += 1 }; return n }
                if index == 0 { return first.stream }
                let session = AsyncStream<RNodeDriverEvent>.makeStream()
                radios.withValue { $0.append(session.continuation) }
                return session.stream
            },
            send: { packet in
                calls.withValue { $0.append(.send(packet)) }
                await gate.wait()
                return results.withValue { $0.isEmpty ? true : $0.removeFirst() }
            },
            stop: { calls.withValue { $0.append(.stop) } }
        )
    }
    store.exhaustivity = .off
    store.timeout = .seconds(5)
    return RNodeInterfaceHarness(store: store, radios: radios, calls: calls, gate: gate,
                                 delegates: delegates)
}

/// Started and online with `report`.
@MainActor
func makeOnlineRNodeInterface(report: RNodeRadioReport = rnodeTestReport,
                              sendResults: [Bool] = [], holdSends: Bool = false) async -> RNodeInterfaceHarness {
    let h = makeRNodeInterface(sendResults: sendResults, holdSends: holdSends)
    await h.store.send(.start)
    h.radio.yield(.connected(report))
    await h.store.receive { if case .delegate(.online) = $0 { return true }; return false }
    return h
}

@MainActor
func stopRNodeInterface(_ h: RNodeInterfaceHarness) async {
    await h.store.send(.stop)
    await h.store.skipReceivedActions(strict: false)
}
