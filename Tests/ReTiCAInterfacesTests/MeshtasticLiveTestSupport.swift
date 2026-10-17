import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
import FCBComposable
import MeshProto
import MeshtasticKit
import MeshtasticMock
import ReTiCAInterfaces

/// One simulated Meshtastic radio plus the LIVE FCB client that drives it through CBM.
struct LiveRadio {
    let id: UUID
    let device: MockMeshtasticDevice
    let spec: CBMPeripheralSpec
    let central: BluetoothCentralClient

    /// Non-default channel and hop limit, so a send that ignored the config is caught.
    var config: MeshtasticDriverConfig { MeshtasticDriverConfig(radio: id, channel: 2, hopLimit: 3) }
}

/// Resets the CBM simulation and stands up one mock radio (plus `extra` specs).
@MainActor
func makeLiveRadio(preset: Config.LoRaConfig.ModemPreset? = .shortFast,
                   initialState: CBMManagerState = .poweredOn,
                   extra: [CBMPeripheralSpec] = []) async -> LiveRadio {
    CBMCentralManagerMock.tearDownSimulation()
    CBMCentralManagerMock.simulateInitialState(initialState)
    let id = UUID()
    let device = MockMeshtasticDevice(now: { Date(timeIntervalSince1970: 2_000_000_000) }, modemPreset: preset)
    let spec = device.makeSpec(identifier: id)
    CBMCentralManagerMock.simulatePeripherals([spec] + extra)
    let central = BluetoothCentralClient.mocked()
    if initialState == .poweredOn { await liveWaitUntilPoweredOn(central) }
    return LiveRadio(id: id, device: device, spec: spec, central: central)
}

/// Polls FCB's replaying state stream until the mock manager reports power-on.
func liveWaitUntilPoweredOn(_ central: BluetoothCentralClient) async {
    for _ in 0..<200 {
        var iterator = central.state().makeAsyncIterator()
        if await iterator.next() == .poweredOn { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Polls `condition` every 10 ms until true or `timeout` (real time).
func liveWaitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Whether `work` returns within `limit`. Unstructured on purpose: a hung `work` must not hang
/// the test (a task group would wait for it).
func returnsWithin(_ limit: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
    let done = LockIsolated(false)
    Task {
        await work()
        done.setValue(true)
    }
    return await liveWaitUntil(timeout: limit) { done.value }
}

/// The session's CURRENT connection state is `state` (MeshtasticKit replays it to a new subscriber).
func liveSessionIs(_ session: MeshtasticSession, _ state: MeshtasticConnectionState,
                   timeout: Duration = .seconds(5)) async -> Bool {
    let seen = LockIsolated(false)
    let stream = session.events()
    let watcher = Task {
        for await event in stream where event == .connection(state) {
            seen.setValue(true)
            return
        }
    }
    defer { watcher.cancel() }
    return await liveWaitUntil(timeout: timeout) { seen.value }
}

/// A driver stream consumed in the background.
final class LiveDriverRun: Sendable {
    let events = LockIsolated<[MeshtasticDriverEvent]>([])
    private let task = LockIsolated<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<MeshtasticDriverEvent>) {
        let events = self.events
        task.setValue(Task {
            for await event in stream { events.withValue { $0.append(event) } }
        })
    }

    func cancel() { task.value?.cancel() }

    func waitFor(timeout: Duration = .seconds(10),
                 _ match: @escaping @Sendable (MeshtasticDriverEvent) -> Bool) async -> Bool {
        await liveWaitUntil(timeout: timeout) { self.events.value.contains(where: match) }
    }

    func count(_ match: @Sendable (MeshtasticDriverEvent) -> Bool) -> Int {
        events.value.filter(match).count
    }
}

let livePeer: UInt32 = MockMeshtasticDevice.nodeNums[0]
let liveConnected = MeshtasticDriverEvent.connected(myNodeNum: MockMeshtasticDevice.selfNodeNum,
                                                   modemPreset: Config.LoRaConfig.ModemPreset.shortFast.rawValue)

func isLiveConnected(_ event: MeshtasticDriverEvent) -> Bool {
    if case .connected = event { return true }
    return false
}
