import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

enum MeshCoreMockCall: Equatable {
    case start(MeshCoreDriverConfig)
    case send(Data)
    case removeChannel
    case stop
}

extension Array where Element == MeshCoreMockCall {
    var meshCoreSentDatagrams: [Data] {
        compactMap { call in
            if case let .send(datagram) = call { return datagram }
            return nil
        }
    }

    var meshCoreStartCount: Int {
        filter { if case .start = $0 { return true }; return false }.count
    }
}

let meshCoreTestRadio = UUID(uuidString: "0000CCCC-0000-0000-0000-00000000BEEF")!
/// Non-default secret, retired list and `canRoute`, so a driver handed defaults is caught.
let meshCoreTestConfig = MeshCoreDriverConfig(
    radio: meshCoreTestRadio,
    channelSecret: Data(repeating: 0x5C, count: 16),
    retiredChannelSecrets: [Data(repeating: 0x0D, count: 16)],
    canRoute: true)
let meshCoreOwnKey = Data((0..<32).map { UInt8(0xA0 &+ $0) })
let meshCoreOwnPrefix = Data(meshCoreOwnKey.prefix(4))
let meshCorePeerPrefix = Data([0xB1, 0xB2, 0xB3, 0xB4])
/// SF 10, 250 kHz, CR 5: a valid MeshCore preset.
let meshCoreTestParams = MeshCoreLinkParams(spreadingFactor: 10, bandwidthHz: 250_000, codingRate: 5)

/// ScotMesh Raw datagrams for `packet`, from `src` to `dst` (broadcast by default).
func meshCoreDatagrams(_ packet: Data, type: MeshCoreFrameType = .rnsFragment,
                       src: Data = meshCorePeerPrefix, dst: Data = ScotMeshRawCodec.broadcast,
                       packetID: UInt16 = 0x2000) -> [Data] {
    ScotMeshRawCodec().split(packet, type: type, src: src, dst: dst, packetID: packetID, canRoute: false)
}

/// Runs the real interface and logs every delegate action in REDUCE order, so a test can assert
/// that one was NOT emitted (exhaustivity is off, so `receive` alone can't).
struct MeshCoreDelegateRecorder: Reducer {
    typealias State = MeshCoreInterface.State
    typealias Action = MeshCoreInterface.Action
    let delegates: LockIsolated<[MeshCoreInterface.Action.Delegate]>

    func reduce(into state: inout State, action: Action) -> Effect<Action> {
        if case let .delegate(delegate) = action { delegates.withValue { $0.append(delegate) } }
        return MeshCoreInterface().reduce(into: &state, action: action)
    }
}

/// The packet `flush` sends: a broadcast single-fragment packet from the peer.
let meshCoreSentinelPacket = meshCorePattern(20, seed: 0x5E)

@MainActor
struct MeshCoreInterfaceHarness {
    let store: TestStore<MeshCoreInterface.State, MeshCoreInterface.Action>
    let radio: AsyncStream<MeshCoreDriverEvent>.Continuation
    let calls: LockIsolated<[MeshCoreMockCall]>
    let clock: TestClock<Duration>
    let now: LockIsolated<Date>
    /// Every delegate the interface emitted, in reduce order.
    let delegates: LockIsolated<[MeshCoreInterface.Action.Delegate]>

    var packets: [Data] {
        delegates.value.compactMap { if case let .packetReceived(packet) = $0 { return packet }; return nil }
    }

    /// Yields `meshCoreSentinelPacket` and waits for its delivery: every datagram yielded before
    /// it has been reduced. Requires an online interface.
    func flush() async {
        for datagram in meshCoreDatagrams(meshCoreSentinelPacket, packetID: 0x7FFF) {
            radio.yield(.datagram(datagram))
        }
        await store.receive { $0 == .delegate(.packetReceived(meshCoreSentinelPacket)) }
    }
}

/// A MeshCoreInterface over a mock radio. `sendResults` are returned by successive driver
/// `send`s (then `true`); `removeChannel` returns `removeResult`. Every `receive` waits up to 5 s.
@MainActor
func makeMeshCoreInterface(initial: MeshCoreInterface.State = MeshCoreInterface.State(config: meshCoreTestConfig),
                           sendResults: [Bool] = [],
                           removeResult: Bool = true,
                           bindDelay: Duration = .seconds(3)) -> MeshCoreInterfaceHarness {
    let radio = AsyncStream<MeshCoreDriverEvent>.makeStream()
    let calls = LockIsolated<[MeshCoreMockCall]>([])
    let results = LockIsolated(sendResults)
    let clock = TestClock<Duration>()
    let now = LockIsolated(Date(timeIntervalSince1970: 1_000))
    let delegates = LockIsolated<[MeshCoreInterface.Action.Delegate]>([])
    let store = TestStore(initialState: initial) {
        MeshCoreDelegateRecorder(delegates: delegates)
    } withDependencies: {
        $0.meshCoreDriver = MeshCoreDriver(
            start: { config in
                calls.withValue { $0.append(.start(config)) }
                return radio.stream
            },
            send: { datagram in
                calls.withValue { $0.append(.send(datagram)) }
                return results.withValue { $0.isEmpty ? true : $0.removeFirst() }
            },
            removeChannel: {
                calls.withValue { $0.append(.removeChannel) }
                return removeResult
            },
            stop: { calls.withValue { $0.append(.stop) } }
        )
        $0.meshCoreClock = clock
        $0.meshCoreDate = DateGenerator { now.value }
        $0.meshCoreRandom = MeshCoreRandom(packetID: { 0x1000 }, bindDelay: { bindDelay })
    }
    store.exhaustivity = .off
    store.timeout = .seconds(5)
    return MeshCoreInterfaceHarness(store: store, radio: radio.continuation, calls: calls, clock: clock,
                                    now: now, delegates: delegates)
}

/// Started and online as `meshCoreOwnKey` with `params`.
@MainActor
func makeOnlineMeshCoreInterface(params: MeshCoreLinkParams? = meshCoreTestParams,
                                 initial: MeshCoreInterface.State = MeshCoreInterface.State(config: meshCoreTestConfig),
                                 sendResults: [Bool] = []) async -> MeshCoreInterfaceHarness {
    let h = makeMeshCoreInterface(initial: initial, sendResults: sendResults)
    await h.store.send(.start)
    h.radio.yield(.connected(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey, params: params))
    await h.store.receive { if case .delegate(.online) = $0 { return true }; return false }
    return h
}

@MainActor
func stopMeshCoreInterface(_ h: MeshCoreInterfaceHarness) async {
    await h.store.send(.stop)
    await h.store.skipReceivedActions(strict: false)
}
