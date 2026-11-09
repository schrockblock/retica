import Testing
import Foundation
@preconcurrency import CoreBluetooth
import ComposableArchitecture
import FCBComposable
import RNodeKit
import ReTiCARNodeLive

private struct FakeRNodeCentral {
    let client: BluetoothCentralClient
    let scanEnded: LockIsolated<Bool>
    /// Set when the scanner reaches `client.scan` (it first waits for `.poweredOn`).
    let scanStarted: LockIsolated<Bool>
}

/// A closure central (no CBM): `state()` replays `states` and stays open; `scan` yields `found`.
private func fakeRNodeCentral(states: [CBManagerState], found: [DiscoveredPeripheral] = []) -> FakeRNodeCentral {
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
    return FakeRNodeCentral(client: client, scanEnded: scanEnded, scanStarted: scanStarted)
}

private final class RNodeScanRun: Sendable {
    let radios = LockIsolated<[DiscoveredRNode]>([])
    let finished = LockIsolated(false)
    private let task = LockIsolated<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<DiscoveredRNode>) {
        let radios = self.radios
        let finished = self.finished
        task.setValue(Task {
            for await radio in stream { radios.withValue { $0.append(radio) } }
            finished.setValue(true)
        })
    }

    func cancel() { task.value?.cancel() }
}

private let rnodeScanRadioID = UUID(uuidString: "5CA40000-0000-4000-8000-0000000000D1")!

@Suite struct RNodeLiveScanTests {
    /// The advertised name must start with "RNode ": the scanner filters on it as well as the UUID.
    @Test func scanYieldsWhatTheScannerFinds() async {
        let found = DiscoveredPeripheral(peripheral: Peripheral(id: rnodeScanRadioID, name: "P", state: .disconnected),
                                         advertisementData: AdvertisementData(localName: "RNode 1A2B"), rssi: -50)
        let fake = fakeRNodeCentral(states: [.poweredOn], found: [found])
        let run = RNodeScanRun(RNodeLive.scanRadios(central: fake.client))
        let started = await liveWaitUntil { fake.scanStarted.value }
        #expect(started, "the scanner never called central.scan")
        let saw = await liveWaitUntil { !run.radios.value.isEmpty }
        #expect(saw)
        #expect(run.radios.value.first == DiscoveredRNode(id: rnodeScanRadioID, name: "RNode 1A2B", rssi: -50))
        run.cancel()
    }

    /// RNodeScanner waits for `.poweredOn` forever; the picker must not spin on an adapter that can't scan.
    @Test func scanFinishesOnAnUnauthorizedAdapter() async {
        let fake = fakeRNodeCentral(states: [.unauthorized])
        let run = RNodeScanRun(RNodeLive.scanRadios(central: fake.client))
        let ended = await liveWaitUntil(timeout: .seconds(2)) { run.finished.value }
        #expect(ended, "the scan ends within 2 s")
        #expect(!fake.scanStarted.value)
        run.cancel()
    }

    @Test func scanFinishesOnAnUnsupportedAdapter() async {
        let fake = fakeRNodeCentral(states: [.unsupported])
        let run = RNodeScanRun(RNodeLive.scanRadios(central: fake.client))
        let ended = await liveWaitUntil(timeout: .seconds(2)) { run.finished.value }
        #expect(ended, "the scan ends within 2 s")
        #expect(!fake.scanStarted.value)
        run.cancel()
    }

    @Test func scanCancellingTheConsumerEndsTheFCBScan() async {
        let fake = fakeRNodeCentral(states: [.poweredOn])
        let run = RNodeScanRun(RNodeLive.scanRadios(central: fake.client))
        let started = await liveWaitUntil { fake.scanStarted.value }
        #expect(started, "the scanner never called central.scan")
        run.cancel()
        let ended = await liveWaitUntil(timeout: .seconds(2)) { fake.scanEnded.value }
        #expect(ended)
    }

    /// Powered off is not "stopped for good": the user can turn Bluetooth on.
    @Test func scanWaitsOutPoweredOff() async {
        let fake = fakeRNodeCentral(states: [.poweredOff])
        let run = RNodeScanRun(RNodeLive.scanRadios(central: fake.client))
        // Bounded wait for something that must not happen.
        let ended = await liveWaitUntil(timeout: .milliseconds(300)) { run.finished.value }
        #expect(!ended, "the scan must not end on a powered-off adapter")
        #expect(!fake.scanStarted.value)
        run.cancel()
    }
}
