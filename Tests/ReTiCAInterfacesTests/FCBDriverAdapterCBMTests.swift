import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
@testable import ReTiCAInterfaces
@testable import FCBComposable

/// Simulated ble-reticulum peripheral: answers the Identity read, accepts the RX handshake write,
/// and records what was written.
final class V22SpecDelegate: CBMPeripheralSpecDelegate, @unchecked Sendable {
    let identity = Data(repeating: 0xEE, count: 16)
    let writes = LockIsolated<[Data]>([])

    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveReadRequestFor characteristic: CBMCharacteristicMock) -> Result<Data, any Error> {
        characteristic.uuid == identityCharUUID ? .success(identity) : .failure(CBATTError(.attributeNotFound))
    }
    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveWriteRequestFor characteristic: CBMCharacteristicMock, data: Data) -> Result<Void, any Error> {
        writes.withValue { $0.append(data) }
        return .success(())
    }
    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveWriteCommandFor characteristic: CBMCharacteristicMock, data: Data) {
        writes.withValue { $0.append(data) }
    }
    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveSetNotifyRequest enabled: Bool, for characteristic: CBMCharacteristicMock) -> Result<Void, any Error> {
        .success(())
    }
}

@MainActor
func noopPeripheralClient() -> BluetoothPeripheralClient {
    var client = BluetoothPeripheralClient.testValue
    client.state = { AsyncStream { $0.finish() } }
    client.add = { s in Service(id: s.id, peripheralID: UUID(), isPrimary: true) }
    client.startAdvertising = { _ in }
    client.stopAdvertising = { }
    client.removeAll = { }
    client.respond = { _, _ in }
    client.subscriptions = { .finished }
    client.writeRequests = { .finished }
    client.readRequests = { .finished }
    client.events = { .finished }
    return client
}

/// CBM simulation is process-global; keep this in its own serialized suite.
@Suite(.serialized) @MainActor
struct FCBDriverAdapterCBMTests {
    @Test func realCentralReadsIdentitySubscribesAndHandshakesAgainstMock() async throws {
        CBMCentralManagerMock.tearDownSimulation()
        CBMCentralManagerMock.simulateInitialState(.poweredOn)

        let id = UUID()
        let tx = CBMCharacteristicMock(type: txCharUUID, properties: [.read, .notify])
        let rx = CBMCharacteristicMock(type: rxCharUUID, properties: [.write, .writeWithoutResponse])
        let ident = CBMCharacteristicMock(type: identityCharUUID, properties: [.read])
        let service = CBMServiceMock(type: serviceUUID, primary: true, characteristics: tx, rx, ident)
        let delegate = V22SpecDelegate()
        let spec = CBMPeripheralSpec
            .simulatePeripheral(identifier: id, proximity: .near)
            .advertising(advertisementData: [CBMAdvertisementDataServiceUUIDsKey: [serviceUUID],
                                             CBMAdvertisementDataIsConnectable: true as NSNumber],
                         withInterval: 0.05)
            .connectable(name: "rns-pi", services: [service], delegate: delegate, connectionInterval: 0.01)
            .build()
        CBMCentralManagerMock.simulatePeripherals([spec])

        let driver = BLEDriver.fcb(central: .mocked(), peripheral: noopPeripheralClient())
        let events = driver.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
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

        guard case let .peerDiscovered(handle)? = await waitFor({ if case .peerDiscovered = $0 { return true }; return false })
        else { Issue.record("no peerDiscovered"); await driver.stop(); return }

        await driver.readIdentity(handle)
        let read = await waitFor { if case .identityRead = $0 { return true }; if case .identityFailed = $0 { return true }; return false }
        #expect(read == .identityRead(handle, identity: delegate.identity))

        await driver.openChannel(handle)
        let opened = await waitFor { if case .channelOpened = $0 { return true }; if case .channelFailed = $0 { return true }; return false }
        guard case let .channelOpened(cid, h, dir, mtu)? = opened else { Issue.record("expected channelOpened, got \(String(describing: opened))"); await driver.stop(); return }
        #expect(h == handle && dir == .outbound && mtu >= BLEFragmenter.minimumMTU)
        #expect(delegate.writes.value.first == adapterLocalIdentity)   // the handshake reached the peripheral

        // A notification from the mock peripheral surfaces as channelData.
        spec.simulateValueUpdate(Data([0x01, 0x00, 0x00, 0x00, 0x01, 0x42]), for: tx)
        let data = await waitFor { if case .channelData = $0 { return true }; return false }
        #expect(data == .channelData(cid, Data([0x01, 0x00, 0x00, 0x00, 0x01, 0x42])))

        await driver.stop()
    }
}
