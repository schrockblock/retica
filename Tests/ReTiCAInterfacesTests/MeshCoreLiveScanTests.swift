import Testing
import Foundation
@preconcurrency import CoreBluetooth
import ComposableArchitecture
import FCBComposable
import MeshCoreKit
import ReTiCAMeshCoreLive

private struct FakeCoreCentral {
    let client: BluetoothCentralClient
    let scanEnded: LockIsolated<Bool>
    /// Set when the scanner reaches `client.scan` (it first waits for `.poweredOn`).
    let scanStarted: LockIsolated<Bool>
}

/// A closure central (no CBM): `state()` replays `states` and stays open; `scan` yields `found`.
private func fakeCoreCentral(states: [CBManagerState], found: [DiscoveredPeripheral] = []) -> FakeCoreCentral {
    let scanEnded = LockIsolated(false)
    let scanStarted = LockIsolated(false)
    var client = BluetoothCentralClient.testValue
    client.state = {
        AsyncStream { continuation in
            for state in states { continuation.yield(state) }
        }
    }
    client.scan = { _, _ in
        scanStarted.setValue(true)
        return AsyncStream { continuation in
            for peripheral in found { continuation.yield(peripheral) }
            continuation.onTermination = { _ in scanEnded.setValue(true) }
        }
    }
    return FakeCoreCentral(client: client, scanEnded: scanEnded, scanStarted: scanStarted)
}

private final class CoreScanRun: Sendable {
    let radios = LockIsolated<[DiscoveredMeshCoreRadio]>([])
    let finished = LockIsolated(false)
    private let task = LockIsolated<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<DiscoveredMeshCoreRadio>) {
        let radios = self.radios
        let finished = self.finished
        task.setValue(Task {
            for await radio in stream { radios.withValue { $0.append(radio) } }
            finished.setValue(true)
        })
    }

    func cancel() { task.value?.cancel() }
}

private let coreScanRadioID = UUID(uuidString: "5CA40000-0000-4000-8000-0000000000C1")!

@Suite struct MeshCoreLiveScanTests {
    /// The advertised name must start with "MeshCore": the scanner filters on it as well as the UUID.
    @Test func scanYieldsWhatTheScannerFinds() async {
        let found = DiscoveredPeripheral(peripheral: Peripheral(id: coreScanRadioID, name: "P", state: .disconnected),
                                         advertisementData: AdvertisementData(localName: "MeshCore-1a2b"), rssi: -50)
        let fake = fakeCoreCentral(states: [.poweredOn], found: [found])
        let run = CoreScanRun(MeshCoreLive.scanRadios(central: fake.client))
        let started = await liveWaitUntil { fake.scanStarted.value }
        #expect(started, "the scanner never called central.scan")
        let saw = await liveWaitUntil { !run.radios.value.isEmpty }
        #expect(saw)
        #expect(run.radios.value.first == DiscoveredMeshCoreRadio(id: coreScanRadioID, name: "MeshCore-1a2b", rssi: -50))
        run.cancel()
    }

    @Test func scanFinishesOnAnUnauthorizedAdapter() async {
        let fake = fakeCoreCentral(states: [.unauthorized])
        let run = CoreScanRun(MeshCoreLive.scanRadios(central: fake.client))
        let ended = await liveWaitUntil(timeout: .seconds(2)) { run.finished.value }
        #expect(ended)
        #expect(!fake.scanStarted.value)
    }

    @Test func scanFinishesOnAnUnsupportedAdapter() async {
        let fake = fakeCoreCentral(states: [.unsupported])
        let run = CoreScanRun(MeshCoreLive.scanRadios(central: fake.client))
        let ended = await liveWaitUntil(timeout: .seconds(2)) { run.finished.value }
        #expect(ended)
        #expect(!fake.scanStarted.value)
    }

    @Test func scanCancellingTheConsumerEndsTheFCBScan() async {
        let fake = fakeCoreCentral(states: [.poweredOn])
        let run = CoreScanRun(MeshCoreLive.scanRadios(central: fake.client))
        let started = await liveWaitUntil { fake.scanStarted.value }
        #expect(started, "the scanner never called central.scan")
        run.cancel()
        let ended = await liveWaitUntil(timeout: .seconds(2)) { fake.scanEnded.value }
        #expect(ended)
    }

    /// Powered off is not "stopped for good": the user can turn Bluetooth on.
    @Test func scanWaitsOutPoweredOff() async {
        let fake = fakeCoreCentral(states: [.poweredOff])
        let run = CoreScanRun(MeshCoreLive.scanRadios(central: fake.client))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!run.finished.value)
        #expect(!fake.scanStarted.value)
        run.cancel()
    }
}
