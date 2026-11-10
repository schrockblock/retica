import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

/// Every call the reducer makes on the mock `AutoInterfaceDriver`, in call order.
enum AutoCall: Equatable {
    case run([AutoBinding])
    case rebind(AutoBinding)
    case unbind(String)
    case multicast(nic: String, token: Data, port: UInt16)
    case unicast(addr: String, index: UInt32, port: UInt16, datagram: Data)
    case stop
}

let autoEn0 = AutoNIC(name: "en0", index: 4, linkLocals: ["fe80::1"])
let autoEn1 = AutoNIC(name: "en1", index: 5, linkLocals: ["fe80::2"])
let autoGroup = AutoInterfaceWire.groupAddress(groupID: AutoInterfaceWire.defaultGroupID, scope: .link, type: .temporary)

func autoToken(_ addr: String, group: Data = AutoInterfaceWire.defaultGroupID) -> Data {
    AutoInterfaceWire.discoveryToken(groupID: group, linkLocal: addr)
}

func autoBinding(_ nic: String, _ index: UInt32, _ ll: String, config: AutoInterfaceConfig = AutoInterfaceConfig()) -> AutoBinding {
    AutoBinding(nic: nic, index: index, linkLocal: ll,
                group: AutoInterfaceWire.groupAddress(groupID: config.groupID, scope: config.scope, type: config.addressType),
                linkScope: config.scope == .link, discoveryPort: config.discoveryPort, dataPort: config.dataPort)
}

/// `AutoInterface`, then a reducer that logs every delegate it emitted.
struct DelegateRecordingAuto: Reducer {
    let log: LockIsolated<[AutoInterface.Action.Delegate]>
    var body: some ReducerOf<AutoInterface> {
        AutoInterface()
        Reduce { _, action in
            if case let .delegate(d) = action { log.withValue { $0.append(d) } }
            return .none
        }
    }
}

/// A mock driver, a `TestClock` whose offset is also the `\.date` (base + offset), and a log of
/// every delegate the reducer emits, recorded by a reducer that runs after `AutoInterface` on every
/// action. The log catches a stray delegate, which an `.off` TestStore's `receive` cannot.
@MainActor
final class AutoHarness {
    typealias Store = TestStore<AutoInterface.State, AutoInterface.Action>
    let store: Store
    let clock: TestClock<Duration>
    let start: TestClock<Duration>.Instant
    let nics: LockIsolated<[AutoNIC]>
    let calls = LockIsolated<[AutoCall]>([])
    let delegates = LockIsolated<[AutoInterface.Action.Delegate]>([])
    let sessions = LockIsolated<[AsyncStream<AutoSocketEvent>.Continuation]>([])
    let ended = LockIsolated(0)
    let multicastResult = LockIsolated<AutoSendResult>(.sent)
    let unicastResult = LockIsolated<AutoSendResult>(.sent)
    /// While true, `driver.stop()` does not return.
    let holdStop = LockIsolated(false)
    static let base = Date(timeIntervalSince1970: 1_000_000)

    init(nics: [AutoNIC] = [autoEn0, autoEn1], config: AutoInterfaceConfig = AutoInterfaceConfig()) {
        let clock = TestClock<Duration>()
        let start = clock.now
        self.clock = clock
        self.start = start
        let nicsBox = LockIsolated(nics)
        self.nics = nicsBox
        let calls = self.calls, delegates = self.delegates, sessions = self.sessions, ended = self.ended
        let mres = self.multicastResult, ures = self.unicastResult, hold = self.holdStop
        store = TestStore(initialState: AutoInterface.State(config: config)) {
            DelegateRecordingAuto(log: delegates)
        } withDependencies: {
            $0.autoInterfaceDriver = AutoInterfaceDriver(
                interfaces: { nicsBox.value },
                run: { bindings in
                    calls.withValue { $0.append(.run(bindings)) }
                    let s = AsyncStream<AutoSocketEvent>.makeStream()
                    s.continuation.onTermination = { _ in ended.withValue { $0 += 1 } }
                    sessions.withValue { $0.append(s.continuation) }
                    return s.stream
                },
                rebind: { b in calls.withValue { $0.append(.rebind(b)) } },
                unbind: { n in calls.withValue { $0.append(.unbind(n)) } },
                sendMulticast: { nic, token, port in
                    calls.withValue { $0.append(.multicast(nic: nic, token: token, port: port)) }
                    return mres.value
                },
                sendUnicast: { addr, index, port, d in
                    calls.withValue { $0.append(.unicast(addr: addr, index: index, port: port, datagram: d)) }
                    return ures.value
                },
                stop: {
                    while hold.value { await Task.yield() }
                    sessions.value.last?.finish()
                    calls.withValue { $0.append(.stop) }
                })
            $0.continuousClock = clock
            $0.date = DateGenerator {
                let d = start.duration(to: clock.now).components
                return AutoHarness.base.addingTimeInterval(Double(d.seconds) + Double(d.attoseconds) / 1e18)
            }
        }
        store.exhaustivity = .off
    }

    func at(_ seconds: Double) -> Date { Self.base.addingTimeInterval(seconds) }

    var multicasts: [AutoCall] { calls.value.filter { if case .multicast = $0 { true } else { false } } }
    var unicasts: [AutoCall] { calls.value.filter { if case .unicast = $0 { true } else { false } } }
    var rebinds: [AutoCall] { calls.value.filter { if case .rebind = $0 { true } else { false } } }

    /// Lets `.run` effects reach the mock, then folds every action they sent into `store.state`
    /// (which an `.off` TestStore advances only on an assertion: without this a state read after a
    /// timer fired would see the state from before it).
    func settle() async {
        for _ in 0..<30 { await Task.megaYield() }
        await store.skipReceivedActions(strict: false)
    }

    /// Advances the clock to `seconds` after the start (absolute, so offsets stay exact).
    func advance(to seconds: Double) async {
        await clock.advance(to: start.advanced(by: .seconds(seconds)))
        await settle()
    }

    func startAndAccept() async {
        await store.send(.start)
        await settle()
        await advance(to: AutoInterfaceWire.initialPeeringWait)
        #expect(store.state.accepting)
    }

    func discovery(_ nic: AutoNIC, from src: String, scope: UInt32? = nil, payload: Data? = nil,
                   plane: AutoPlane = .multicastDiscovery) async {
        await store.send(.socketEvent(.datagram(
            nic: nic.name, plane: plane, source: src, sourceScope: scope ?? nic.index,
            payload: payload ?? autoToken(src))))
        await settle()
    }

    func data(_ nic: AutoNIC, from src: String, _ payload: Data) async {
        await store.send(.socketEvent(.datagram(
            nic: nic.name, plane: .data, source: src, sourceScope: nic.index, payload: payload)))
        await settle()
    }

    /// Stops the interface so no timer outlives the test.
    func finish() async {
        holdStop.setValue(false)
        await store.send(.stop)
        for _ in 0..<200 where !store.state.isIdle { await Task.megaYield() }
        await store.skipReceivedActions(strict: false)
    }
}

func blob(_ label: String, _ n: Int = 40) -> Data {
    var out = Data()
    var i = 0
    while out.count < n {
        out += AutoInterfaceWire.discoveryToken(groupID: Data(label.utf8), linkLocal: "\(i)")
        i += 1
    }
    return out.prefix(n)
}
