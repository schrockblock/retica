import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
@testable import ReTiCAInterfaces
@testable import FCBComposable

// MARK: - Spec delegate for RBTP directory reads

/// Answers characteristic reads with the canned RBTP directory values.
final class RBTPSpecDelegate: CBMPeripheralSpecDelegate, @unchecked Sendable {
    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveReadRequestFor characteristic: CBMCharacteristicMock) -> Result<Data, any Error> {
        switch characteristic.uuid {
        case versionCharUUID: return .success(Data([2]))
        case psmCharUUID:     return .success(Data([0x81, 0x00]))
        default:              return .failure(CBATTError(.attributeNotFound))
        }
    }
}

// MARK: - CBM integration suite

/// CBM simulation is process-global; keep this in its own serialized suite.
@Suite(.serialized) @MainActor
struct FCBDriverAdapterCBMTests {
    @Test func realCentralDrivesDirectoryReadThenChannelFailsOnMock() async throws {
        CBMCentralManagerMock.tearDownSimulation()
        CBMCentralManagerMock.simulateInitialState(.poweredOn)

        let id = UUID()
        // A peripheral serving the RBTP directory: version=2, PSM=0x0081 (LE bytes 81 00).
        // CBMCharacteristicMock does not take a value at init; reads are answered by the
        // spec delegate (CBMPeripheralSpecDelegate.didReceiveReadRequestFor).
        let versionChar = CBMCharacteristicMock(type: versionCharUUID, properties: [.read])
        let psmChar = CBMCharacteristicMock(type: psmCharUUID, properties: [.read])
        let service = CBMServiceMock(type: serviceUUID, primary: true, characteristics: versionChar, psmChar)
        let specDelegate = RBTPSpecDelegate()
        let spec = CBMPeripheralSpec
            .simulatePeripheral(identifier: id, proximity: .near)
            .advertising(advertisementData: [
                CBMAdvertisementDataServiceUUIDsKey: [serviceUUID],
                CBMAdvertisementDataIsConnectable: true as NSNumber,
            ], withInterval: 0.05)
            .connectable(name: "RBTPNode", services: [service], delegate: specDelegate, connectionInterval: 0.01)
            .build()
        CBMCentralManagerMock.simulatePeripherals([spec])

        // Real FCB central actor (mocked manager) + a no-op peripheral client:
        // we only exercise the central/discovery/directory path here.
        let driver = BLEDriver.fcb(central: .mocked(), peripheral: noopPeripheralClient())
        let events = driver.start(BLEDriverConfig(version: 2, pairingMode: .open))

        // A single pump task owns the (non-Sendable) iterator and appends every
        // event to a lock-isolated buffer the test polls. No iterator crosses a
        // task boundary, so there is no Sendable problem.
        let buffer = LockIsolated<[BLEDriverEvent]>([])
        let pump = Task { for await e in events { buffer.withValue { $0.append(e) } } }
        defer { pump.cancel() }

        func waitFor(_ match: @Sendable @escaping (BLEDriverEvent) -> Bool) async -> BLEDriverEvent? {
            for _ in 0..<300 {
                if let hit = buffer.withValue({ $0.first(where: match) }) { return hit }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return nil
        }

        let discovered = await waitFor { if case .peerDiscovered = $0 { return true }; return false }
        guard case let .peerDiscovered(handle)? = discovered else {
            Issue.record("no peerDiscovered"); await driver.stop(); return
        }

        await driver.readDirectory(handle)
        let read = await waitFor { if case .directoryRead = $0 { return true }; if case .directoryFailed = $0 { return true }; return false }
        #expect(read == .directoryRead(handle, version: 2, psm: 0x0081))

        // openChannel on the mocked central → CBM can't open L2CAP → .channelFailed.
        await driver.openChannel(handle, 0x0081)
        let failed = await waitFor { if case .channelFailed = $0 { return true }; return false }
        #expect(failed != nil)
        await driver.stop()
    }
}

/// A peripheral client that never powers on (peripheral role unused in this test),
/// so the adapter's `.ready` waits only on the central side is irrelevant here —
/// we drive directory flow directly via readDirectory without needing .ready.
@MainActor
func noopPeripheralClient() -> BluetoothPeripheralClient {
    var client = BluetoothPeripheralClient.testValue
    client.state = { AsyncStream { $0.finish() } }
    client.publishL2CAPChannel = { _ in 0 }
    client.add = { s in Service(id: s.id, peripheralID: UUID(), isPrimary: true) }
    client.startAdvertising = { _ in }
    client.stopAdvertising = { }
    client.removeAll = { }
    client.unpublishL2CAPChannel = { _ in }
    client.l2capConnections = { AsyncStream { $0.finish() } }
    return client
}
