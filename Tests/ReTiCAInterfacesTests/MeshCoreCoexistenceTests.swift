import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
@testable import FCBComposable
import MeshCoreKit
import MeshCoreMock
import MeshtasticKit
import MeshtasticMock
@testable import ReTiCAInterfaces
import ReTiCAMeshCoreLive
import ReTiCAMeshtasticLive

/// One live central shared by an RBTP BLE driver (with one ble-reticulum peer), a Meshtastic radio
/// session and a MeshCore radio session, as ReTiCAMsgr runs them (all three use FCB's `liveValue`).
/// Built like `MeshtasticCoexistenceTests`'s rig, with a second, out-of-range MeshCore radio so a
/// picker scan can be shown to keep yielding.
@MainActor
private struct TwoRadioRig {
    let central: BluetoothCentralClient
    let manager: CBMCentralManager
    let meshtasticID: UUID
    let meshtastic: MockMeshtasticDevice
    let meshtasticSpec: CBMPeripheralSpec
    let coreID: UUID
    let core: MockMeshCoreDevice
    let coreSpec: CBMPeripheralSpec
    let core2ID: UUID
    let core2Spec: CBMPeripheralSpec
    let peerSpec: CBMPeripheralSpec
    let peerDelegate: V22SpecDelegate
    let ble: BLEDriver
    let mesh: MeshtasticDriver
    let mc: MeshCoreDriver

    var coreConfig: MeshCoreDriverConfig {
        MeshCoreDriverConfig(radio: coreID, channelSecret: liveCoreKey)
    }
}

/// `peerInterval` is the ble-reticulum peer's connection interval: every GATT response and its
/// disconnect take that long, which is what makes a BLE stop with an open channel "slow".
@MainActor
private func makeTwoRadioRig(peerInterval: TimeInterval = 0.01) async -> TwoRadioRig {
    CBMCentralManagerMock.tearDownSimulation()
    CBMCentralManagerMock.simulateInitialState(.poweredOn)
    let meshtasticID = UUID()
    let meshtastic = MockMeshtasticDevice(now: { Date(timeIntervalSince1970: 2_000_000_000) }, modemPreset: .shortFast)
    let meshtasticSpec = meshtastic.makeSpec(identifier: meshtasticID)
    let coreID = UUID()
    let core = MockMeshCoreDevice(now: { Date(timeIntervalSince1970: 2_000_000_000) })
    let coreSpec = core.makeSpec(identifier: coreID)
    let core2ID = UUID()
    let core2Spec = MockMeshCoreDevice().makeSpec(identifier: core2ID)
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
        .connectable(name: "rns-peer", services: [service], delegate: peerDelegate, connectionInterval: peerInterval)
        .build()
    CBMCentralManagerMock.simulatePeripherals([meshtasticSpec, coreSpec, core2Spec, peerSpec])
    core2Spec.simulateProximityChange(.outOfRange)
    let manager = CBMCentralManagerFactory.instance(forceMock: true)
    let central = BluetoothCentralClient.makeClient(actor: CentralActor(manager: manager))
    #expect(await liveWaitUntilPoweredOn(central), "precondition: powered on")
    return TwoRadioRig(central: central, manager: manager,
                       meshtasticID: meshtasticID, meshtastic: meshtastic, meshtasticSpec: meshtasticSpec,
                       coreID: coreID, core: core, coreSpec: coreSpec,
                       core2ID: core2ID, core2Spec: core2Spec,
                       peerSpec: peerSpec, peerDelegate: peerDelegate,
                       ble: BLEDriver.fcb(central: central, peripheral: noopPeripheralClient()),
                       mesh: MeshtasticDriver.live(session: MeshtasticSession(central: central)),
                       mc: MeshCoreDriver.live(session: MeshCoreSession(central: central, appName: "ReTiCATests")))
}

/// Drains a `MeshCoreLive.scanRadios` stream (the radio picker's role), keeping what it found.
private final class MeshCoreScanRun: Sendable {
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

    func saw(_ id: UUID) -> Bool { radios.value.contains { $0.id == id } }
}

private let isBLEChannelClosed: @Sendable (BLEDriverEvent) -> Bool = { if case .channelClosed = $0 { return true }; return false }

/// A running rig: the three drivers' event logs.
@MainActor
private struct Running {
    let rig: TwoRadioRig
    let mesh: LiveDriverRun
    let core: LiveCoreDriverRun
    let ble: DriverEventLog
    let channel: BLEChannelID
}

/// Discovers the ble-reticulum peer, reads its identity and opens an outbound GATT channel.
@MainActor
private func openBLEChannel(_ rig: TwoRadioRig, _ log: DriverEventLog) async -> BLEChannelID? {
    guard case let .peerDiscovered(handle)? = await log.first(isPeerDiscovered) else { return nil }
    guard await returns(within: 6, { await rig.ble.readIdentity(handle) }) else { return nil }
    guard case .identityRead? = await log.first(isIdentityOutcome) else { return nil }
    guard await returns(within: 6, { await rig.ble.openChannel(handle) }) else { return nil }
    guard case let .channelOpened(cid, _, _, _, _)? = await log.first(isChannelOutcome) else { return nil }
    return cid
}

/// BLE (with one open channel) and both radios connected. Records an issue and returns nil if
/// any part doesn't come up, after tearing down what did.
@MainActor
private func startEverything(_ rig: TwoRadioRig) async -> Running? {
    let mesh = LiveDriverRun(rig.mesh.start(MeshtasticDriverConfig(radio: rig.meshtasticID)))
    let core = LiveCoreDriverRun(rig.mc.start(rig.coreConfig))
    let ble = DriverEventLog(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
    let meshUp = await mesh.waitFor(isLiveConnected)
    let coreUp = await core.waitFor(isLiveCoreConnected)
    let channel = await openBLEChannel(rig, ble)
    guard meshUp, coreUp, let channel else {
        Issue.record("precondition: meshtastic \(meshUp) events \(mesh.events.value); meshcore \(coreUp) events \(core.events.value); BLE channel \(channel != nil) events \(ble.events.value)")
        await tearDown(rig, ble: ble, mesh: mesh, core: core)
        return nil
    }
    return Running(rig: rig, mesh: mesh, core: core, ble: ble, channel: channel)
}

/// Stops the given drivers (bounded) and drops their streams.
@MainActor
private func tearDown(_ rig: TwoRadioRig, ble: DriverEventLog?, mesh: LiveDriverRun?, core: LiveCoreDriverRun?) async {
    if let ble {
        #expect(await returns(within: 6) { await rig.ble.stop() }, "BLE stop did not return")
        ble.cancel()
    }
    if let mesh {
        #expect(await returns(within: 6) { await rig.mesh.stop() }, "Meshtastic stop did not return")
        mesh.cancel()
    }
    if let core {
        #expect(await returns(within: 6) { await rig.mc.stop() }, "MeshCore stop did not return")
        core.cancel()
    }
}

@MainActor
private func tearDown(_ running: Running) async {
    await tearDown(running.rig, ble: running.ble, mesh: running.mesh, core: running.core)
}

/// The Meshtastic radio's send returned `true` within 6 s and reached the radio.
@MainActor
private func meshtasticSendReaches(_ rig: TwoRadioRig, _ data: Data) async -> Bool {
    let sent = LockIsolated(false)
    let mesh = rig.mesh
    let before = rig.meshtastic.receivedPackets.count
    let returned = await returns(within: 6) {
        let ok = await mesh.send(data)
        sent.setValue(ok)
    }
    return returned && sent.value && rig.meshtastic.receivedPackets.count == before + 1
}

/// The MeshCore radio's send returned `true` within 6 s and the radio received one more
/// `CMD_SEND_CHANNEL_DATA`.
@MainActor
private func meshCoreSendReaches(_ rig: TwoRadioRig, _ data: Data) async -> Bool {
    let sent = LockIsolated(false)
    let mc = rig.mc
    let before = rig.core.receivedFrames.filter { $0.first == 0x3E }.count
    let returned = await returns(within: 6) {
        let ok = await mc.send(data)
        sent.setValue(ok)
    }
    return returned && sent.value && rig.core.receivedFrames.filter { $0.first == 0x3E }.count == before + 1
}

private func meshtasticDrops(_ run: LiveDriverRun) -> Int { run.count { $0 == .disconnected(reason: nil) } }
private func meshCoreDrops(_ run: LiveCoreDriverRun) -> Int { run.count { $0 == .disconnected(reason: nil) } }

private let coexistFrame = Data([0x01, 0x00, 0x00, 0x00, 0x01, 0x42])
private let meshtasticPayload = Data([0x00, 0xFF, 0x01])
private let meshCorePayload = Data([0x52, 0x01, 0x02])

/// Spec §7: the RBTP BLE driver, a live Meshtastic session and a live MeshCore session on ONE
/// live FCB central over CoreBluetoothMock.
extension FCBDriverAdapterCBMTests {
    @Suite @MainActor
    struct MeshCoreCoexistenceTests {
        // MARK: Both radios beside a BLE peer

        @Test func bothRadiosConnectBesideABLEPeer() async {
            let rig = await makeTwoRadioRig()
            guard let running = await startEverything(rig) else { return }
            #expect(await meshtasticSendReaches(rig, meshtasticPayload), "the Meshtastic send failed or did not return")
            #expect(await meshCoreSendReaches(rig, meshCorePayload), "the MeshCore send failed or did not return")
            await tearDown(running)
        }

        @Test func aMeshCoreLinkDropLeavesMeshtasticConnected() async {
            let rig = await makeTwoRadioRig()
            guard let running = await startEverything(rig) else { return }
            rig.coreSpec.simulateDisconnection()
            #expect(await running.core.waitFor { $0 == .disconnected(reason: nil) }, "precondition: the MeshCore link dropped")
            #expect(await liveWaitUntil(timeout: .seconds(15)) { running.core.count(isLiveCoreConnected) == 2 },
                    "precondition: MeshCore came back: \(running.core.events.value)")
            #expect(meshtasticDrops(running.mesh) == 0, "Meshtastic saw the MeshCore drop: \(running.mesh.events.value)")
            #expect(await meshtasticSendReaches(rig, meshtasticPayload), "the Meshtastic send failed or did not return")
            await tearDown(running)
        }

        @Test func aMeshtasticLinkDropLeavesMeshCoreConnected() async {
            let rig = await makeTwoRadioRig()
            guard let running = await startEverything(rig) else { return }
            rig.meshtasticSpec.simulateDisconnection()
            #expect(await running.mesh.waitFor { $0 == .disconnected(reason: nil) }, "precondition: the Meshtastic link dropped")
            #expect(await liveWaitUntil(timeout: .seconds(15)) { running.mesh.count(isLiveConnected) == 2 },
                    "precondition: Meshtastic came back: \(running.mesh.events.value)")
            #expect(meshCoreDrops(running.core) == 0, "MeshCore saw the Meshtastic drop: \(running.core.events.value)")
            #expect(await meshCoreSendReaches(rig, meshCorePayload), "the MeshCore send failed or did not return")
            await tearDown(running)
        }

        @Test func aBLEPeerDropLeavesBothRadiosConnected() async {
            let rig = await makeTwoRadioRig()
            guard let running = await startEverything(rig) else { return }
            rig.peerSpec.simulateDisconnection()
            #expect(await running.ble.first(isBLEChannelClosed) != nil, "precondition: the BLE peer dropped")
            #expect(await meshtasticSendReaches(rig, meshtasticPayload), "the Meshtastic send failed or did not return")
            #expect(await meshCoreSendReaches(rig, meshCorePayload), "the MeshCore send failed or did not return")
            #expect(meshtasticDrops(running.mesh) == 0, "Meshtastic saw the BLE drop: \(running.mesh.events.value)")
            #expect(meshCoreDrops(running.core) == 0, "MeshCore saw the BLE drop: \(running.core.events.value)")
            await tearDown(running)
        }

        // MARK: Stopping one leaves the others sending

        @Test func stoppingMeshCoreLeavesMeshtasticSending() async {
            let rig = await makeTwoRadioRig()
            guard let running = await startEverything(rig) else { return }
            #expect(await returns(within: 6) { await rig.mc.stop() }, "MeshCore stop did not return")
            running.core.cancel()
            #expect(meshtasticDrops(running.mesh) == 0, "events: \(running.mesh.events.value)")
            #expect(await meshtasticSendReaches(rig, meshtasticPayload), "the Meshtastic send failed or did not return")
            #expect(!running.ble.events.value.contains(where: isBLEChannelClosed), "the BLE channel closed with the MeshCore stop")
            await tearDown(rig, ble: running.ble, mesh: running.mesh, core: nil)
        }

        @Test func stoppingMeshtasticLeavesMeshCoreSending() async {
            let rig = await makeTwoRadioRig()
            guard let running = await startEverything(rig) else { return }
            #expect(await returns(within: 6) { await rig.mesh.stop() }, "Meshtastic stop did not return")
            running.mesh.cancel()
            #expect(meshCoreDrops(running.core) == 0, "events: \(running.core.events.value)")
            #expect(await meshCoreSendReaches(rig, meshCorePayload), "the MeshCore send failed or did not return")
            #expect(!running.ble.events.value.contains(where: isBLEChannelClosed), "the BLE channel closed with the Meshtastic stop")
            await tearDown(rig, ble: running.ble, mesh: nil, core: running.core)
        }

        @Test func stoppingBLELeavesBothRadiosSending() async {
            let rig = await makeTwoRadioRig()
            guard let running = await startEverything(rig) else { return }
            #expect(await returns(within: 6) { await rig.ble.stop() }, "BLE stop did not return")
            running.ble.cancel()
            #expect(await meshtasticSendReaches(rig, meshtasticPayload), "the Meshtastic send failed or did not return")
            #expect(await meshCoreSendReaches(rig, meshCorePayload), "the MeshCore send failed or did not return")
            #expect(meshtasticDrops(running.mesh) == 0, "events: \(running.mesh.events.value)")
            #expect(meshCoreDrops(running.core) == 0, "events: \(running.core.events.value)")
            await tearDown(rig, ble: nil, mesh: running.mesh, core: running.core)
        }

        // MARK: Bluetooth power cycle

        /// No action is taken after the power cycle: both sessions reconnect on their own.
        @Test func bothRadiosComeBackAfterABluetoothPowerCycle() async {
            let rig = await makeTwoRadioRig()
            let mesh = LiveDriverRun(rig.mesh.start(MeshtasticDriverConfig(radio: rig.meshtasticID)))
            let core = LiveCoreDriverRun(rig.mc.start(rig.coreConfig))
            #expect(await mesh.waitFor(isLiveConnected), "precondition: Meshtastic connected")
            #expect(await core.waitFor(isLiveCoreConnected), "precondition: MeshCore connected")
            CBMCentralManagerMock.simulatePowerOff()
            #expect(await mesh.waitFor(timeout: .seconds(10)) { $0 == .disconnected(reason: nil) }, "Meshtastic events: \(mesh.events.value)")
            #expect(await core.waitFor(timeout: .seconds(10)) { $0 == .disconnected(reason: nil) }, "MeshCore events: \(core.events.value)")
            CBMCentralManagerMock.simulatePowerOn()
            #expect(await liveWaitUntil(timeout: .seconds(15)) { mesh.count(isLiveConnected) == 2 },
                    "Meshtastic did not come back: \(mesh.events.value)")
            #expect(await liveWaitUntil(timeout: .seconds(15)) { core.count(isLiveCoreConnected) == 2 },
                    "MeshCore did not come back: \(core.events.value)")
            #expect(await meshtasticSendReaches(rig, meshtasticPayload), "the Meshtastic send failed or did not return")
            #expect(await meshCoreSendReaches(rig, meshCorePayload), "the MeshCore send failed or did not return")
            await tearDown(rig, ble: nil, mesh: mesh, core: core)
        }

        // MARK: The MeshCore picker's scan

        /// The picker's scan runs while both radios are connected: neither is disturbed.
        @Test func aMeshCoreScanDoesNotDisconnectEitherRadio() async {
            let rig = await makeTwoRadioRig()
            let mesh = LiveDriverRun(rig.mesh.start(MeshtasticDriverConfig(radio: rig.meshtasticID)))
            let core = LiveCoreDriverRun(rig.mc.start(rig.coreConfig))
            #expect(await mesh.waitFor(isLiveConnected), "precondition: Meshtastic connected")
            #expect(await core.waitFor(isLiveCoreConnected), "precondition: MeshCore connected")
            let scan = MeshCoreScanRun(MeshCoreLive.scanRadios(central: rig.central))
            rig.core2Spec.simulateProximityChange(.near)
            #expect(await liveWaitUntil { scan.saw(rig.core2ID) }, "precondition: the scan is running and saw the second radio")
            #expect(await meshtasticSendReaches(rig, meshtasticPayload), "the Meshtastic send failed or did not return")
            #expect(await meshCoreSendReaches(rig, meshCorePayload), "the MeshCore send failed or did not return")
            #expect(meshtasticDrops(mesh) == 0, "Meshtastic events: \(mesh.events.value)")
            #expect(meshCoreDrops(core) == 0, "MeshCore events: \(core.events.value)")
            scan.cancel()
            await tearDown(rig, ble: nil, mesh: mesh, core: core)
        }

        @Test func aMeshCoreScanFindsOnlyMeshCoreRadios() async {
            let rig = await makeTwoRadioRig()
            let scan = MeshCoreScanRun(MeshCoreLive.scanRadios(central: rig.central))
            #expect(await liveWaitUntil { scan.saw(rig.coreID) }, "the scan did not see the MeshCore radio (finished: \(scan.finished.value))")
            rig.core2Spec.simulateProximityChange(.near)
            #expect(await liveWaitUntil { scan.saw(rig.core2ID) }, "the scan did not see the second MeshCore radio (finished: \(scan.finished.value))")
            #expect(!scan.saw(rig.meshtasticID), "the Meshtastic radio was listed: \(scan.radios.value)")
            #expect(!scan.saw(rig.peerSpec.identifier), "the BLE peer was listed: \(scan.radios.value)")
            scan.cancel()
        }

        /// Picker OPEN: the app stops BLE and the picker starts its scan at once; BLE's stop is still
        /// disconnecting when the picker's scan begins. Its late teardown must not end that scan.
        @Test func aSlowBLEStopDoesNotEndTheMeshCorePickersScan() async {
            let rig = await makeTwoRadioRig(peerInterval: 0.4)
            let ble = DriverEventLog(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
            guard await openBLEChannel(rig, ble) != nil else {
                Issue.record("precondition: BLE channel open, events \(ble.events.value)")
                await tearDown(rig, ble: ble, mesh: nil, core: nil)
                return
            }
            let stop = Task { await rig.ble.stop() }
            let scan = MeshCoreScanRun(MeshCoreLive.scanRadios(central: rig.central))
            #expect(await liveWaitUntil { scan.saw(rig.coreID) }, "precondition: the scan saw the MeshCore radio")
            #expect(!scan.saw(rig.core2ID), "precondition: the second radio is out of range")
            #expect(await returns(within: 6) { await stop.value }, "BLE stop did not return")
            ble.cancel()
            rig.core2Spec.simulateProximityChange(.near)
            let secondFound = await liveWaitUntil(timeout: .seconds(3)) { scan.saw(rig.core2ID) }
            #expect(secondFound, "the scan stopped yielding after BLE stopped (finished: \(scan.finished.value))")
            #expect(!scan.finished.value, "the scan finished after BLE stopped")
            scan.cancel()
        }

        /// Picker DISMISS: the picker's scan has fully ended before BLE restarts. Cancelling the
        /// consumer ends the scanner's own FCB scan, so BLE's new scan is the only one and discovers.
        @Test func theBLEScanRestartsAfterTheMeshCorePickerCloses() async {
            let rig = await makeTwoRadioRig()
            let first = DriverEventLog(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
            #expect(await first.first(isPeerDiscovered) != nil, "precondition: BLE is scanning")
            #expect(await returns(within: 6) { await rig.ble.stop() }, "BLE stop did not return")
            first.cancel()
            let scan = MeshCoreScanRun(MeshCoreLive.scanRadios(central: rig.central))
            #expect(await liveWaitUntil { scan.saw(rig.coreID) }, "precondition: the scan saw the radio")
            scan.cancel()
            #expect(await liveWaitUntil(timeout: .seconds(2)) { scan.finished.value }, "the cancelled scan did not finish")
            let manager = rig.manager
            #expect(await liveWaitUntil(timeout: .seconds(2)) { !manager.isScanning },
                    "cancelling the scan left its FCB scan running")
            let ble = DriverEventLog(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
            #expect(await ble.first(within: 3, isPeerDiscovered) != nil, "BLE online but not discovering: \(ble.events.value)")
            await tearDown(rig, ble: ble, mesh: nil, core: nil)
        }

        // MARK: Kit scanner behaviour the picker relies on (ported from MeshtasticKit's ScannerTests)

        /// FCB runs one radio scan per central: a newer scan by another owner supersedes this one,
        /// and the scanner's stream finishes (for good) instead of silently going quiet.
        @Test func aNewerScanEndsTheMeshCoreScan() async {
            let radio = await makeLiveCoreRadio()
            let found = LockIsolated(0)
            let ended = LockIsolated(false)
            let consumer = Task {
                for await _ in MeshCoreScanner.scan(central: radio.central) { found.withValue { $0 += 1 } }
                ended.setValue(true)
            }
            #expect(await liveWaitUntil { found.value > 0 })
            let other = Task { for await _ in radio.central.scan([CBUUID]?.none, ScanOptions?.none) {} }
            let finished = await liveWaitUntil(timeout: .seconds(2)) { ended.value }
            #expect(finished, "the superseded scanner stream must finish, not go quiet")
            other.cancel()
            consumer.cancel()
        }

        /// Bluetooth power-cycled mid-scan: CoreBluetooth stops the radio scan and never resumes it,
        /// and FCB ends the scan stream. The scanner waits for power and scans again; its stream
        /// does not finish.
        @Test func theMeshCoreScanResumesAfterAPowerCycle() async {
            let radio = await makeLiveCoreRadio()
            let found = LockIsolated(0)
            let ended = LockIsolated(false)
            let consumer = Task {
                for await _ in MeshCoreScanner.scan(central: radio.central) { found.withValue { $0 += 1 } }
                ended.setValue(true)
            }
            #expect(await liveWaitUntil { found.value > 0 })
            CBMCentralManagerMock.simulatePowerOff()
            try? await Task.sleep(for: .milliseconds(200))
            let beforePowerOn = found.value
            CBMCentralManagerMock.simulatePowerOn()
            let rescanned = await liveWaitUntil(timeout: .seconds(5)) { found.value > beforePowerOn }
            #expect(rescanned, "the scanner must scan again once Bluetooth is back on")
            #expect(!ended.value)
            consumer.cancel()
        }
    }
}
