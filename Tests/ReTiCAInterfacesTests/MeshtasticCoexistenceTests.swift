import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
@testable import FCBComposable
import MeshProto
import MeshtasticKit
import MeshtasticMock
@testable import ReTiCAInterfaces
import ReTiCAMeshtasticLive

/// One live central shared by an RBTP BLE driver (with one ble-reticulum peer) and a Meshtastic
/// radio session, as ReTiCAMsgr runs them (`BLEDriver.liveValue` and `MeshtasticLive.makeSession()`
/// both use FCB's `liveValue`). Built like FCB's `mocked()`, but keeping the manager so a probe can
/// read whether the radio is still scanning.
@MainActor
private struct CoexistenceRig {
    let central: BluetoothCentralClient
    let manager: CBMCentralManager
    let radioID: UUID
    let radio: MockMeshtasticDevice
    let radioSpec: CBMPeripheralSpec
    let radio2ID: UUID
    let radio2Spec: CBMPeripheralSpec
    let peerSpec: CBMPeripheralSpec
    let peerDelegate: V22SpecDelegate
    let ble: BLEDriver
    let mesh: MeshtasticDriver
}

@MainActor
private func makeCoexistenceRig() async -> CoexistenceRig {
    CBMCentralManagerMock.tearDownSimulation()
    CBMCentralManagerMock.simulateInitialState(.poweredOn)
    let radioID = UUID()
    let radio = MockMeshtasticDevice(now: { Date(timeIntervalSince1970: 2_000_000_000) }, modemPreset: .shortFast)
    let radioSpec = radio.makeSpec(identifier: radioID)
    let radio2ID = UUID()
    let radio2Spec = MockMeshtasticDevice().makeSpec(identifier: radio2ID)
    let tx = CBMCharacteristicMock(type: txCharUUID, properties: [.read, .notify])
    let rx = CBMCharacteristicMock(type: rxCharUUID, properties: [.write, .writeWithoutResponse])
    let ident = CBMCharacteristicMock(type: identityCharUUID, properties: [.read])
    let service = CBMServiceMock(type: serviceUUID, primary: true, characteristics: tx, rx, ident)
    let peerDelegate = V22SpecDelegate()
    let peerSpec = CBMPeripheralSpec
        .simulatePeripheral(identifier: UUID(), proximity: .near)
        .advertising(advertisementData: [CBMAdvertisementDataServiceUUIDsKey: [serviceUUID],
                                         CBMAdvertisementDataIsConnectable: true as NSNumber],
                     withInterval: 0.05)
        .connectable(name: "rns-peer", services: [service], delegate: peerDelegate, connectionInterval: 0.01)
        .build()
    CBMCentralManagerMock.simulatePeripherals([radioSpec, radio2Spec, peerSpec])
    // The second radio starts out of range; the open-side probe brings it in to test that the
    // radio scan still yields.
    radio2Spec.simulateProximityChange(.outOfRange)
    let manager = CBMCentralManagerFactory.instance(forceMock: true)
    let central = BluetoothCentralClient.makeClient(actor: CentralActor(manager: manager))
    #expect(await liveWaitUntilPoweredOn(central), "precondition: powered on")
    return CoexistenceRig(central: central, manager: manager, radioID: radioID, radio: radio,
                          radioSpec: radioSpec, radio2ID: radio2ID, radio2Spec: radio2Spec,
                          peerSpec: peerSpec, peerDelegate: peerDelegate,
                          ble: BLEDriver.fcb(central: central, peripheral: noopPeripheralClient()),
                          mesh: MeshtasticDriver.live(session: MeshtasticSession(central: central)))
}

/// Drains a `MeshtasticScanner` stream (the radio picker's role), keeping what it found.
private final class RadioScanRun: Sendable {
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

    func saw(_ id: UUID) -> Bool { radios.value.contains { $0.id == id } }
}

private let isChannelClosed: @Sendable (BLEDriverEvent) -> Bool = { if case .channelClosed = $0 { return true }; return false }
private let scanSuperseded = BLEDriverEvent.unavailable(.other("scan superseded by another scanner"))

/// Discovers the ble-reticulum peer, reads its identity and opens an outbound GATT channel.
/// Every driver call is bounded (a hung FCB continuation fails the test, never hangs the run).
@MainActor
private func openBLEChannel(_ rig: CoexistenceRig, _ log: DriverEventLog) async -> BLEChannelID? {
    guard case let .peerDiscovered(handle)? = await log.first(isPeerDiscovered) else { return nil }
    guard await returns(within: 6, { await rig.ble.readIdentity(handle) }) else { return nil }
    guard case .identityRead? = await log.first(isIdentityOutcome) else { return nil }
    guard await returns(within: 6, { await rig.ble.openChannel(handle) }) else { return nil }
    guard case let .channelOpened(cid, _, _, _, _)? = await log.first(isChannelOutcome) else { return nil }
    return cid
}

/// Stops both drivers (bounded) and drops their streams.
@MainActor
private func tearDown(_ rig: CoexistenceRig, ble: DriverEventLog?, mesh: LiveDriverRun?) async {
    if let ble {
        #expect(await returns(within: 6) { await rig.ble.stop() }, "BLE stop did not return")
        ble.cancel()
    }
    if let mesh {
        #expect(await returns(within: 6) { await rig.mesh.stop() }, "radio stop did not return")
        mesh.cancel()
    }
}

private let coexistFrame = Data([0x01, 0x00, 0x00, 0x00, 0x01, 0x42])

/// Spec §7 E.2: the RBTP BLE driver (live FCB adapter) and a live Meshtastic session on ONE live
/// FCB central over CoreBluetoothMock.
extension FCBDriverAdapterCBMTests {
    @Suite @MainActor
    struct MeshtasticCoexistenceTests {
        @Test func aBLEPeerDroppingLeavesTheRadioConnected() async {
            let rig = await makeCoexistenceRig()
            let mesh = LiveDriverRun(rig.mesh.start(MeshtasticDriverConfig(radio: rig.radioID)))
            #expect(await mesh.waitFor(isLiveConnected), "precondition: radio connected")
            let ble = DriverEventLog(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
            let channel = await openBLEChannel(rig, ble)
            #expect(channel != nil, "precondition: BLE channel open, events \(ble.events.value)")
            rig.peerSpec.simulateDisconnection()
            #expect(await ble.first(isChannelClosed) != nil, "precondition: the BLE peer dropped")
            try? await Task.sleep(for: .milliseconds(500))
            #expect(mesh.count { $0 == .disconnected(reason: nil) } == 0, "the radio saw the BLE peer's drop: \(mesh.events.value)")
            let before = rig.radio.receivedPackets.count
            #expect(await rig.mesh.send(Data([0x00, 0xFF, 0x01])))
            #expect(rig.radio.receivedPackets.count == before + 1)
            await tearDown(rig, ble: ble, mesh: mesh)
        }

        @Test func theRadioDroppingLeavesTheBLEChannelOpen() async {
            let rig = await makeCoexistenceRig()
            let mesh = LiveDriverRun(rig.mesh.start(MeshtasticDriverConfig(radio: rig.radioID)))
            #expect(await mesh.waitFor(isLiveConnected), "precondition: radio connected")
            let ble = DriverEventLog(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
            guard let channel = await openBLEChannel(rig, ble) else {
                Issue.record("precondition: BLE channel open, events \(ble.events.value)")
                await tearDown(rig, ble: ble, mesh: mesh)
                return
            }
            rig.radioSpec.simulateDisconnection()
            #expect(await mesh.waitFor { $0 == .disconnected(reason: nil) }, "precondition: the radio dropped")
            try? await Task.sleep(for: .milliseconds(500))
            #expect(!ble.events.value.contains(where: isChannelClosed),
                    "the BLE channel closed with the radio: \(ble.events.value)")
            #expect(await returns(within: 3) { await rig.ble.send(channel, [coexistFrame]) }, "BLE send did not return")
            #expect(await liveWaitUntil(timeout: .seconds(3)) { rig.peerDelegate.writes.value.contains(coexistFrame) },
                    "the BLE peer did not receive the frame")
            await tearDown(rig, ble: ble, mesh: mesh)
        }

        @Test func stoppingBLELeavesTheRadioConnected() async {
            let rig = await makeCoexistenceRig()
            let mesh = LiveDriverRun(rig.mesh.start(MeshtasticDriverConfig(radio: rig.radioID)))
            #expect(await mesh.waitFor(isLiveConnected), "precondition: radio connected")
            let ble = DriverEventLog(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
            #expect(await openBLEChannel(rig, ble) != nil, "precondition: BLE channel open")
            #expect(await returns(within: 6) { await rig.ble.stop() }, "BLE stop did not return")
            ble.cancel()
            try? await Task.sleep(for: .milliseconds(500))
            #expect(mesh.count { $0 == .disconnected(reason: nil) } == 0, "events: \(mesh.events.value)")
            let before = rig.radio.receivedPackets.count
            #expect(await rig.mesh.send(Data([0x00, 0xFF, 0x02])))
            #expect(rig.radio.receivedPackets.count == before + 1)
            await tearDown(rig, ble: nil, mesh: mesh)
        }

        @Test func stoppingTheRadioLeavesTheBLEChannelOpen() async {
            let rig = await makeCoexistenceRig()
            let mesh = LiveDriverRun(rig.mesh.start(MeshtasticDriverConfig(radio: rig.radioID)))
            #expect(await mesh.waitFor(isLiveConnected), "precondition: radio connected")
            let ble = DriverEventLog(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
            guard let channel = await openBLEChannel(rig, ble) else {
                Issue.record("precondition: BLE channel open, events \(ble.events.value)")
                await tearDown(rig, ble: ble, mesh: mesh)
                return
            }
            #expect(await returns(within: 6) { await rig.mesh.stop() }, "radio stop did not return")
            mesh.cancel()
            try? await Task.sleep(for: .milliseconds(500))
            #expect(!ble.events.value.contains(where: isChannelClosed),
                    "the BLE channel closed with the radio's stop: \(ble.events.value)")
            #expect(await returns(within: 3) { await rig.ble.send(channel, [coexistFrame]) }, "BLE send did not return")
            #expect(await liveWaitUntil(timeout: .seconds(3)) { rig.peerDelegate.writes.value.contains(coexistFrame) },
                    "the BLE peer did not receive the frame")
            await tearDown(rig, ble: ble, mesh: nil)
        }

        /// Open side (spec §7 F.1(a)): the picker's radio scan is running when the BLE driver's
        /// stop runs. Before lane F the adapter's teardown called FCB's global `stopScan()`, which
        /// ended WHATEVER scan was current, so the picker stopped seeing radios. Lane F made
        /// `stopScan()` a no-op and the adapter's teardown ends only its own (token-scoped) scan.
        /// The radio scan superseding BLE's also finishes BLE's stream, and the adapter reports
        /// `.unavailable(.other("scan superseded by another scanner"))` on `ble` — expected, and
        /// deliberately not asserted either way: the claim is only that the radio scan survives
        /// BLE's stop.
        @Test func aBLEStopAfterTheRadioScanStartedDoesNotEndIt() async {
            let rig = await makeCoexistenceRig()
            let ble = DriverEventLog(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
            #expect(await ble.first(isPeerDiscovered) != nil, "precondition: BLE is scanning")
            let scan = RadioScanRun(MeshtasticScanner.scan(central: rig.central))
            #expect(await liveWaitUntil { scan.saw(rig.radioID) }, "precondition: the radio scan saw the first radio")
            #expect(!scan.saw(rig.radio2ID), "precondition: the second radio is out of range")
            #expect(await returns(within: 6) { await rig.ble.stop() }, "BLE stop did not return")
            ble.cancel()
            rig.radio2Spec.simulateProximityChange(.near)
            let secondFound = await liveWaitUntil(timeout: .seconds(3)) { scan.saw(rig.radio2ID) }
            #expect(secondFound, "the radio scan stopped yielding after BLE stopped (finished: \(scan.finished.value))")
            #expect(!scan.finished.value, "the radio scan finished after BLE stopped")
            scan.cancel()
        }

        /// Dismiss side, settled: the radio scan has fully ended before BLE restarts. Also the live
        /// proof of the scanner's own cleanup (Task 5 proved it only by fake): cancelling the
        /// consumer ends the scanner's inner FCB scan, so the radio stops scanning.
        @Test func aRadioScanThatEndedBeforeBLERestartedLeavesBLEDiscovering() async {
            let rig = await makeCoexistenceRig()
            let scan = RadioScanRun(MeshtasticScanner.scan(central: rig.central))
            #expect(await liveWaitUntil { scan.saw(rig.radioID) }, "precondition: the radio scan saw the radio")
            scan.cancel()
            #expect(await liveWaitUntil(timeout: .seconds(2)) { scan.finished.value }, "the cancelled radio scan did not finish")
            let manager = rig.manager
            #expect(await liveWaitUntil(timeout: .seconds(2)) { !manager.isScanning },
                    "cancelling the radio scan left its FCB scan running")
            let ble = DriverEventLog(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
            #expect(await ble.first(isPeerDiscovered) != nil, "BLE online but not discovering: \(ble.events.value)")
            await tearDown(rig, ble: ble, mesh: nil)
        }

        /// Dismiss side, racing (spec §7 F.1(b)): FCB starts a scan through an unordered task, so
        /// before lane F a radio scan whose start ran late superseded BLE's newer one and BLE stayed
        /// "online" but never discovered. The picker closes just as its scan starts and BLE
        /// restarts at once. After lane F a stream terminated before its own start never starts
        /// the radio, so BLE discovers; and if a supersession still happened it is no longer
        /// silent — the adapter reports `.unavailable(.other("scan superseded by another
        /// scanner"))`, which BLEInterface retries after its 5–120 s backoff (not waited for here).
        /// Each round waits at most 3 s for whichever comes first: a supersession fails the round
        /// with a message, and so does silence. Swept over ten cancel delays.
        @Test func aRadioScanCancelledAsBLERestartsLeavesBLEDiscovering() async {
            for round in 0..<10 {
                let rig = await makeCoexistenceRig()
                let scan = RadioScanRun(MeshtasticScanner.scan(central: rig.central))
                try? await Task.sleep(for: .milliseconds(round))
                scan.cancel()
                let ble = DriverEventLog(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
                let outcome = await ble.first(within: 3) { isPeerDiscovered($0) || $0 == scanSuperseded }
                if outcome == scanSuperseded {
                    Issue.record("round \(round): the cancelled radio scan superseded BLE's restarted scan")
                } else {
                    #expect(outcome != nil, "round \(round): BLE online but not discovering: \(ble.events.value)")
                }
                await tearDown(rig, ble: ble, mesh: nil)
            }
        }
    }
}
