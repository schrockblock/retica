import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
@testable import ReTiCAInterfaces
@testable import FCBComposable

/// The Meshtastic service UUID, so the second scanner here looks like the radio picker's.
let coexistRadioServiceUUID = CBMUUID(string: "6BA1B218-15A8-461F-9FA8-5DCAE273EAFD")

private struct CoexistAcceptingDelegate: CBMPeripheralSpecDelegate {}

/// A ble-reticulum v2.2 peer whose next Identity read can power Bluetooth off while that read is
/// in flight at the peripheral (CBM calls this synchronously from `readValue`).
final class PowerCycleV22Delegate: CBMPeripheralSpecDelegate, @unchecked Sendable {
    let identity = Data(repeating: 0xEE, count: 16)
    let powerOffOnNextIdentityRead = LockIsolated(false)

    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveReadRequestFor characteristic: CBMCharacteristicMock) -> Result<Data, any Error> {
        guard characteristic.uuid == identityCharUUID else { return .failure(CBATTError(.attributeNotFound)) }
        let powerOff = powerOffOnNextIdentityRead.withValue { armed -> Bool in defer { armed = false }; return armed }
        if powerOff { CBMCentralManagerMock.simulatePowerOff() }
        return .success(identity)
    }
    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveWriteRequestFor characteristic: CBMCharacteristicMock, data: Data) -> Result<Void, any Error> {
        .success(())
    }
    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveWriteCommandFor characteristic: CBMCharacteristicMock, data: Data) {}
    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveSetNotifyRequest enabled: Bool, for characteristic: CBMCharacteristicMock) -> Result<Void, any Error> {
        .success(())
    }
}

/// One live FCB central (the app has exactly one) shared by the BLE driver and a second scanner,
/// over a CBM world with a v2.2 peer and a Meshtastic-looking radio. `bleInterval` is the peer's
/// connection interval: every GATT response and the disconnect take that long, which is what
/// makes a BLE stop with an open channel "slow".
struct CoexistRig {
    let central: BluetoothCentralClient
    let manager: CBMCentralManager
    let peerDelegate: PowerCycleV22Delegate
}

@MainActor
func makeCoexistRig(bleInterval: TimeInterval) async -> CoexistRig {
    CBMCentralManagerMock.tearDownSimulation()
    CBMCentralManagerMock.simulateInitialState(.poweredOn)
    let tx = CBMCharacteristicMock(type: txCharUUID, properties: [.read, .notify])
    let rx = CBMCharacteristicMock(type: rxCharUUID, properties: [.write, .writeWithoutResponse])
    let ident = CBMCharacteristicMock(type: identityCharUUID, properties: [.read])
    let service = CBMServiceMock(type: serviceUUID, primary: true, characteristics: tx, rx, ident)
    let peerDelegate = PowerCycleV22Delegate()
    let blePeer = CBMPeripheralSpec
        .simulatePeripheral(identifier: UUID(), proximity: .near)
        .advertising(advertisementData: [CBMAdvertisementDataServiceUUIDsKey: [serviceUUID],
                                         CBMAdvertisementDataIsConnectable: true as NSNumber], withInterval: 0.05)
        .connectable(name: "rns-pi", services: [service], delegate: peerDelegate, connectionInterval: bleInterval)
        .allowForRetrieval()
        .build()
    let radio = CBMPeripheralSpec
        .simulatePeripheral(identifier: UUID(), proximity: .near)
        .advertising(advertisementData: [CBMAdvertisementDataServiceUUIDsKey: [coexistRadioServiceUUID],
                                         CBMAdvertisementDataLocalNameKey: "Meshtastic_COEX",
                                         CBMAdvertisementDataIsConnectable: true as NSNumber], withInterval: 0.05)
        .connectable(name: "Meshtastic_COEX", services: [], delegate: CoexistAcceptingDelegate(), connectionInterval: 0.01)
        .build()
    CBMCentralManagerMock.simulatePeripherals([blePeer, radio])
    let manager = CBMCentralManagerFactory.instance(forceMock: true)
    for _ in 0..<200 where manager.state != .poweredOn { try? await Task.sleep(nanoseconds: 10_000_000) }
    let central = BluetoothCentralClient.makeClient(actor: CentralActor(manager: manager))
    return CoexistRig(central: central, manager: manager, peerDelegate: peerDelegate)
}

/// Records a driver session's events and whether its stream ended.
final class DriverEventLog: @unchecked Sendable {
    let events = LockIsolated<[BLEDriverEvent]>([])
    let ended = LockIsolated(false)
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<BLEDriverEvent>) {
        let events = events
        let ended = ended
        task = Task {
            for await event in stream { events.withValue { $0.append(event) } }
            ended.setValue(true)
        }
    }

    var count: Int { events.value.count }
    func cancel() { task?.cancel() }

    /// The first event at index ≥ `index` matching `match`, waiting at most `seconds`.
    func first(after index: Int = 0, within seconds: Double = 6,
               _ match: @escaping @Sendable (BLEDriverEvent) -> Bool) async -> BLEDriverEvent? {
        for _ in 0..<Int(seconds * 50) {
            if let hit = events.withValue({ Array($0.dropFirst(index)).first(where: match) }) { return hit }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }
}

/// Drains a raw FCB scan stream (the radio picker's role), counting discoveries.
final class RadioScanLog: @unchecked Sendable {
    let discoveries = LockIsolated(0)
    let ended = LockIsolated(false)
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<DiscoveredPeripheral>) {
        let discoveries = discoveries
        let ended = ended
        task = Task {
            for await _ in stream { discoveries.withValue { $0 += 1 } }
            ended.setValue(true)
        }
    }

    func cancel() { task?.cancel() }
}

func poll(within seconds: Double, _ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<Int(seconds * 100) {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// Whether `operation` returned within `seconds` (a hung FCB continuation must FAIL the test,
/// not hang the run).
func returns(within seconds: Double, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
    let done = LockIsolated(false)
    let task = Task { await operation(); done.setValue(true) }
    let returned = await poll(within: seconds) { done.value }
    if !returned { task.cancel() }
    return returned
}

let isPeerDiscovered: @Sendable (BLEDriverEvent) -> Bool = { if case .peerDiscovered = $0 { return true }; return false }
let isIdentityOutcome: @Sendable (BLEDriverEvent) -> Bool = {
    if case .identityRead = $0 { return true }
    if case .identityFailed = $0 { return true }
    return false
}
let isChannelOutcome: @Sendable (BLEDriverEvent) -> Bool = {
    if case .channelOpened = $0 { return true }
    if case .channelFailed = $0 { return true }
    return false
}

extension FCBDriverAdapterCBMTests {
    /// BLE up on `rig.central` with one outbound channel open, so `stop()` has a disconnect to
    /// wait out (one `bleInterval`).
    func bleOnlineWithOpenChannel(_ rig: CoexistRig) async -> (BLEDriver, DriverEventLog)? {
        let driver = BLEDriver.fcb(central: rig.central, peripheral: noopPeripheralClient())
        let log = DriverEventLog(driver.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
        guard case let .peerDiscovered(handle)? = await log.first(isPeerDiscovered) else {
            Issue.record("no peerDiscovered"); return nil
        }
        guard await returns(within: 6, { await driver.readIdentity(handle) }) else {
            Issue.record("readIdentity did not return"); return nil
        }
        guard case .identityRead? = await log.first(isIdentityOutcome) else { Issue.record("identity read failed"); return nil }
        guard await returns(within: 6, { await driver.openChannel(handle) }) else {
            Issue.record("openChannel did not return"); return nil
        }
        guard case .channelOpened? = await log.first(isChannelOutcome) else { Issue.record("channel did not open"); return nil }
        return (driver, log)
    }

    /// Another owner's scan supersedes BLE's while Bluetooth stays on (FCB runs one radio scan per
    /// central). BLE must not stay "online" without discovering: the driver reports a transient
    /// adapter problem, so the interface leaves `.online` and its retry restarts the driver.
    @Test func aSupersededBLEScanIsReportedAsATransientAdapterProblem() async {
        let rig = await makeCoexistRig(bleInterval: 0.01)
        let driver = BLEDriver.fcb(central: rig.central, peripheral: noopPeripheralClient())
        let log = DriverEventLog(driver.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
        #expect(await log.first(isPeerDiscovered) != nil)
        let other = RadioScanLog(rig.central.scan([coexistRadioServiceUUID], ScanOptions(allowDuplicates: true)))
        let lost = await log.first(within: 2) { if case .unavailable(.other) = $0 { return true }; return false }
        #expect(lost != nil, "a superseded BLE scan went unreported")
        other.cancel()
        log.cancel()
        #expect(await returns(within: 6) { await driver.stop() }, "stop did not return")
    }

    /// An off immediately followed by on reaches FCB (and the adapter) as two `.poweredOn` states
    /// (CoreBluetooth reads `state` at callback time), so the adapter brings its central up twice.
    /// Its second scan replaces its OWN first one: that is not a scan lost to another owner.
    @Test func aRepeatPoweredOnReplacingOurOwnScanIsNotALostScan() async {
        let rig = await makeCoexistRig(bleInterval: 0.01)
        let driver = BLEDriver.fcb(central: rig.central, peripheral: noopPeripheralClient())
        let log = DriverEventLog(driver.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
        #expect(await log.first(isPeerDiscovered) != nil)
        CBMCentralManagerMock.simulatePowerOff()
        CBMCentralManagerMock.simulatePowerOn()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(!log.events.value.contains { if case .unavailable = $0 { return true }; return false })
        #expect(rig.manager.isScanning)
        log.cancel()
        #expect(await returns(within: 6) { await driver.stop() }, "stop did not return")
    }

    /// Picker DISMISS: the app restarts BLE while the stop it sent at open is still disconnecting.
    /// When that old teardown resumes, the new session must keep its event stream.
    @Test func aRestartDuringASlowStopKeepsTheNewSessionsEventStream() async {
        let rig = await makeCoexistRig(bleInterval: 0.4)
        guard let (driver, log) = await bleOnlineWithOpenChannel(rig) else { return }
        let stop = Task { await driver.stop() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let restarted = DriverEventLog(driver.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
        #expect(await returns(within: 6) { await stop.value }, "stop did not return")
        try? await Task.sleep(nanoseconds: 500_000_000)

        #expect(!restarted.ended.value, "the old session's teardown finished the new session's stream")
        restarted.cancel()
        log.cancel()
        #expect(await returns(within: 6) { await driver.stop() }, "final stop did not return")
    }
}
