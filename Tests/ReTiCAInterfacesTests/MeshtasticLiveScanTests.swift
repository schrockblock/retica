import Testing
import Foundation
@preconcurrency import CoreBluetooth
import ComposableArchitecture
import FCBComposable
import MeshtasticKit
import ReTiCAMeshtasticLive

private struct FakeCentral {
    let client: BluetoothCentralClient
    let scanEnded: LockIsolated<Bool>
    /// Set when the scanner reaches `client.scan` (it first waits for `.poweredOn`).
    let scanStarted: LockIsolated<Bool>
}

/// A closure central (no CBM): `state()` replays `states` and stays open; `scan` yields `found`.
private func fakeCentral(states: [CBManagerState], found: [DiscoveredPeripheral] = []) -> FakeCentral {
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
    return FakeCentral(client: client, scanEnded: scanEnded, scanStarted: scanStarted)
}

private final class ScanRun: Sendable {
    let radios = LockIsolated<[DiscoveredRadio]>([])
    let finished = LockIsolated(false)
    private let task = LockIsolated<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<DiscoveredRadio>) {
        let radios = self.radios
        let finished = self.finished
        task.setValue(Task {
            for await radio in stream { radios.withValue { $0.append(radio) } }
            finished.setValue(true)
        })
    }

    func cancel() { task.value?.cancel() }
}

private let scanRadioID = UUID(uuidString: "5CA40000-0000-4000-8000-000000000001")!

@Suite struct MeshtasticLiveScanTests {
    @Test func scanRadiosYieldsTheScannersRadios() async {
        let found = DiscoveredPeripheral(peripheral: Peripheral(id: scanRadioID, name: "P", state: .disconnected),
                                         advertisementData: AdvertisementData(localName: "Meshtastic_1a2b"), rssi: -50)
        let fake = fakeCentral(states: [.poweredOn], found: [found])
        let run = ScanRun(MeshtasticLive.scanRadios(central: fake.client))
        let started = await liveWaitUntil { fake.scanStarted.value }
        #expect(started, "the scanner never called central.scan")
        let saw = await liveWaitUntil { !run.radios.value.isEmpty }
        #expect(saw)
        #expect(run.radios.value.first == DiscoveredRadio(id: scanRadioID, name: "Meshtastic_1a2b", rssi: -50))
        run.cancel()
    }

    @Test func scanRadiosFinishesWhenTheAdapterIsUnsupported() async {
        let fake = fakeCentral(states: [.unsupported])
        let run = ScanRun(MeshtasticLive.scanRadios(central: fake.client))
        let ended = await liveWaitUntil(timeout: .seconds(2)) { run.finished.value }
        #expect(ended)
        #expect(!fake.scanStarted.value)
    }

    @Test func scanRadiosFinishesWhenTheAdapterIsUnauthorized() async {
        let fake = fakeCentral(states: [.unauthorized])
        let run = ScanRun(MeshtasticLive.scanRadios(central: fake.client))
        let ended = await liveWaitUntil(timeout: .seconds(2)) { run.finished.value }
        #expect(ended)
        #expect(!fake.scanStarted.value)
    }

    /// Powered off is not "stopped for good": the user can turn Bluetooth on.
    @Test func scanRadiosKeepsWaitingWhilePoweredOff() async {
        let fake = fakeCentral(states: [.poweredOff])
        let run = ScanRun(MeshtasticLive.scanRadios(central: fake.client))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!run.finished.value)
        #expect(!fake.scanStarted.value)
        run.cancel()
    }

    @Test func cancellingTheConsumerEndsTheUnderlyingScan() async {
        let fake = fakeCentral(states: [.poweredOn])
        let run = ScanRun(MeshtasticLive.scanRadios(central: fake.client))
        let started = await liveWaitUntil { fake.scanStarted.value }
        #expect(started, "the scanner never called central.scan")
        run.cancel()
        let ended = await liveWaitUntil(timeout: .seconds(2)) { fake.scanEnded.value }
        #expect(ended)
    }
}
