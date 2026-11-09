import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
import FCBComposable
import RNodeKit
import RNodeMock
import ReTiCAInterfaces

/// Sideband's defaults at 868.1 MHz, with values no mutation's fixed config shares (preflight L6):
/// 62.5 kHz, 0 dBm (within the mock's 22 dBm maximum), SF 8, CR 6.
let rnodeLiveParams = RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 62_500, txPowerDBm: 0,
                                      spreadingFactor: 8, codingRate: 6)

/// One simulated RNode plus the LIVE FCB client that drives it through CBM.
struct LiveRNodeRadio {
    let id: UUID
    let device: MockRNodeDevice
    let spec: CBMPeripheralSpec
    let central: BluetoothCentralClient

    func config(_ params: RNodeLoRaParams = rnodeLiveParams) -> RNodeDriverConfig {
        RNodeDriverConfig(radio: id, params: params)
    }

    /// Every frequency, bandwidth, TX power, SF and CR frame the radio has received, in order.
    var setterFrames: [KISSFrame] {
        device.receivedFrames.filter { (RNodeCommand.frequency...RNodeCommand.codingRate).contains($0.command) }
    }

    /// The DATA frames the radio has received.
    var dataFrames: Int {
        device.receivedFrames.filter { $0.command == RNodeCommand.data }.count
    }
}

/// The five setter frames the session writes for `params`, as the radio decodes them.
func rnodeSetterFrames(_ params: RNodeLoRaParams) -> [KISSFrame] {
    func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    return [
        KISSFrame(command: RNodeCommand.frequency, payload: bigEndian(params.frequencyHz)),
        KISSFrame(command: RNodeCommand.bandwidth, payload: bigEndian(params.bandwidthHz)),
        KISSFrame(command: RNodeCommand.txPower, payload: Data([params.txPowerDBm])),
        KISSFrame(command: RNodeCommand.spreadingFactor, payload: Data([params.spreadingFactor])),
        KISSFrame(command: RNodeCommand.codingRate, payload: Data([params.codingRate])),
    ]
}

/// Resets the CBM simulation and stands up one mock RNode.
@MainActor
func makeLiveRNodeRadio(firmware: (major: UInt8, minor: UInt8) = (1, 0x56), maxTXPower: UInt8 = 22,
                        initialState: CBMManagerState = .poweredOn) async -> LiveRNodeRadio {
    CBMCentralManagerMock.tearDownSimulation()
    CBMCentralManagerMock.simulateInitialState(initialState)
    let id = UUID()
    let device = MockRNodeDevice(firmware: firmware, maxTXPower: maxTXPower)
    let spec = device.makeSpec(identifier: id)
    CBMCentralManagerMock.simulatePeripherals([spec])
    let central = BluetoothCentralClient.mocked()
    if initialState == .poweredOn { #expect(await liveWaitUntilPoweredOn(central), "precondition: powered on") }
    return LiveRNodeRadio(id: id, device: device, spec: spec, central: central)
}

/// The session's CURRENT connection state is `state` (the hub replays it to a new subscriber).
func liveRNodeSessionIs(_ session: RNodeSession, _ state: RNodeConnectionState,
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

/// An RNode driver stream consumed in the background.
final class LiveRNodeDriverRun: Sendable {
    let events = LockIsolated<[RNodeDriverEvent]>([])
    /// The stream ended (the adapter finished it).
    let finished = LockIsolated(false)
    private let task = LockIsolated<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<RNodeDriverEvent>) {
        let events = self.events
        let finished = self.finished
        task.setValue(Task {
            for await event in stream { events.withValue { $0.append(event) } }
            finished.setValue(true)
        })
    }

    func cancel() { task.value?.cancel() }

    func waitFor(timeout: Duration = .seconds(10),
                 _ match: @escaping @Sendable (RNodeDriverEvent) -> Bool) async -> Bool {
        await liveWaitUntil(timeout: timeout) { self.events.value.contains(where: match) }
    }

    func count(_ match: @Sendable (RNodeDriverEvent) -> Bool) -> Int {
        events.value.filter(match).count
    }
}

func isLiveRNodeConnected(_ event: RNodeDriverEvent) -> Bool {
    if case .connected = event { return true }
    return false
}

func isLiveRNodeUnavailable(_ event: RNodeDriverEvent) -> Bool {
    if case .unavailable = event { return true }
    return false
}
