import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

enum MeshMockCall: Equatable {
    case start(MeshtasticDriverConfig)
    case send(Data)
    case stop
}

extension Array where Element == MeshMockCall {
    var sentFrames: [Data] {
        compactMap { call in
            if case let .send(frame) = call { return frame }
            return nil
        }
    }
}

let meshTestRadio = UUID(uuidString: "0000AAAA-0000-0000-0000-00000000BEEF")!
let meshTestConfig = MeshtasticDriverConfig(radio: meshTestRadio, channel: 2, hopLimit: 3)
let meshOwnNode: UInt32 = 0x0A0A_0A0A
let meshPeerNode: UInt32 = 0x0B0B_0B0B

@MainActor
struct MeshInterfaceHarness {
    let store: TestStore<MeshtasticInterface.State, MeshtasticInterface.Action>
    let radio: AsyncStream<MeshtasticDriverEvent>.Continuation
    let calls: LockIsolated<[MeshMockCall]>
    let clock: TestClock<Duration>
    let now: LockIsolated<Date>
}

/// A MeshtasticInterface over a mock radio. `sendResults` are returned by successive driver
/// `send`s (then `true`).
@MainActor
func makeMeshInterface(initial: MeshtasticInterface.State = MeshtasticInterface.State(config: meshTestConfig),
                       sendResults: [Bool] = []) -> MeshInterfaceHarness {
    let radio = AsyncStream<MeshtasticDriverEvent>.makeStream()
    let calls = LockIsolated<[MeshMockCall]>([])
    let results = LockIsolated(sendResults)
    let clock = TestClock<Duration>()
    let now = LockIsolated(Date(timeIntervalSince1970: 1_000))
    let store = TestStore(initialState: initial) {
        MeshtasticInterface()
    } withDependencies: {
        $0.meshtasticDriver = MeshtasticDriver(
            start: { config in
                calls.withValue { $0.append(.start(config)) }
                return radio.stream
            },
            send: { frame in
                calls.withValue { $0.append(.send(frame)) }
                return results.withValue { $0.isEmpty ? true : $0.removeFirst() }
            },
            stop: { calls.withValue { $0.append(.stop) } }
        )
        $0.meshtasticClock = clock
        $0.meshtasticDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    return MeshInterfaceHarness(store: store, radio: radio.continuation, calls: calls, clock: clock, now: now)
}

/// Started and online with `modemPreset`.
@MainActor
func makeOnlineMeshInterface(modemPreset: Int? = 0,
                             initial: MeshtasticInterface.State = MeshtasticInterface.State(config: meshTestConfig),
                             sendResults: [Bool] = []) async -> MeshInterfaceHarness {
    let h = makeMeshInterface(initial: initial, sendResults: sendResults)
    await h.store.send(.start)
    h.radio.yield(.connected(myNodeNum: meshOwnNode, modemPreset: modemPreset))
    await h.store.receive { if case .delegate(.online) = $0 { return true }; return false }
    return h
}

@MainActor
func stopMeshInterface(_ h: MeshInterfaceHarness) async {
    await h.store.send(.stop)
    await h.store.skipReceivedActions(strict: false)
}

/// Advance the pacing clock `count` times by `delay`, waiting for each resulting driver send.
@MainActor
func drainMeshFrames(_ h: MeshInterfaceHarness, every delay: Duration, count: Int) async {
    for _ in 0..<count {
        await h.clock.advance(by: delay)
        await h.store.receive { if case .fragmentSent = $0 { return true }; return false }
    }
}
