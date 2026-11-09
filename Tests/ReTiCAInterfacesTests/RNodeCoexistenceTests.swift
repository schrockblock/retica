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
import RNodeKit
import RNodeMock
@testable import ReTiCAInterfaces
import ReTiCAMeshCoreLive
import ReTiCAMeshtasticLive
import ReTiCARNodeLive

/// One live central shared by an RBTP BLE driver (with one ble-reticulum peer), a Meshtastic radio
/// session, a MeshCore radio session and an RNode session, as ReTiCAMsgr runs them. The RNode and
/// the MeshCore radio advertise the same Nordic UART service UUID; only their names tell them apart.
/// A second, out-of-range RNode lets a picker scan show it keeps yielding.
@MainActor
private struct ThreeRadioRig {
    let central: BluetoothCentralClient
    let manager: CBMCentralManager
    let meshtasticID: UUID
    let meshtastic: MockMeshtasticDevice
    let meshtasticSpec: CBMPeripheralSpec
    let coreID: UUID
    let core: MockMeshCoreDevice
    let coreSpec: CBMPeripheralSpec
    let rnodeID: UUID
    let rnode: MockRNodeDevice
    let rnodeSpec: CBMPeripheralSpec
    let rnode2ID: UUID
    let rnode2Spec: CBMPeripheralSpec
    let peerSpec: CBMPeripheralSpec
    let peerDelegate: V22SpecDelegate
    let ble: BLEDriver
    let mesh: MeshtasticDriver
    let mc: MeshCoreDriver
    let rn: RNodeDriver

    var coreConfig: MeshCoreDriverConfig {
        MeshCoreDriverConfig(radio: coreID, channelSecret: liveCoreKey)
    }

    var rnodeConfig: RNodeDriverConfig {
        RNodeDriverConfig(radio: rnodeID, params: rnodeLiveParams)
    }
}

@MainActor
private func makeThreeRadioRig() async -> ThreeRadioRig {
    CBMCentralManagerMock.tearDownSimulation()
    CBMCentralManagerMock.simulateInitialState(.poweredOn)
    let meshtasticID = UUID()
    let meshtastic = MockMeshtasticDevice(now: { Date(timeIntervalSince1970: 2_000_000_000) }, modemPreset: .shortFast)
    let meshtasticSpec = meshtastic.makeSpec(identifier: meshtasticID)
    let coreID = UUID()
    let core = MockMeshCoreDevice(now: { Date(timeIntervalSince1970: 2_000_000_000) })
    let coreSpec = core.makeSpec(identifier: coreID)
    let rnodeID = UUID()
    let rnode = MockRNodeDevice()
    let rnodeSpec = rnode.makeSpec(identifier: rnodeID)
    let rnode2ID = UUID()
    let rnode2Spec = MockRNodeDevice(name: "RNode 9F9F").makeSpec(identifier: rnode2ID)
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
    CBMCentralManagerMock.simulatePeripherals([meshtasticSpec, coreSpec, rnodeSpec, rnode2Spec, peerSpec])
    rnode2Spec.simulateProximityChange(.outOfRange)
    let manager = CBMCentralManagerFactory.instance(forceMock: true)
    let central = BluetoothCentralClient.makeClient(actor: CentralActor(manager: manager))
    #expect(await liveWaitUntilPoweredOn(central), "precondition: powered on")
    return ThreeRadioRig(central: central, manager: manager,
                         meshtasticID: meshtasticID, meshtastic: meshtastic, meshtasticSpec: meshtasticSpec,
                         coreID: coreID, core: core, coreSpec: coreSpec,
                         rnodeID: rnodeID, rnode: rnode, rnodeSpec: rnodeSpec,
                         rnode2ID: rnode2ID, rnode2Spec: rnode2Spec,
                         peerSpec: peerSpec, peerDelegate: peerDelegate,
                         ble: BLEDriver.fcb(central: central, peripheral: noopPeripheralClient()),
                         mesh: MeshtasticDriver.live(session: MeshtasticSession(central: central)),
                         mc: MeshCoreDriver.live(session: MeshCoreSession(central: central, appName: "ReTiCATests")),
                         rn: RNodeDriver.live(session: RNodeSession(central: central)))
}

/// Drains a radio picker's scan stream, keeping the ids it found.
private final class PickerScanRun<Radio: Sendable>: Sendable {
    let ids = LockIsolated<[UUID]>([])
    let finished = LockIsolated(false)
    private let task = LockIsolated<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<Radio>, id: @escaping @Sendable (Radio) -> UUID) {
        let ids = self.ids
        let finished = self.finished
        task.setValue(Task {
            for await radio in stream { ids.withValue { $0.append(id(radio)) } }
            finished.setValue(true)
        })
    }

    func cancel() { task.value?.cancel() }

    func saw(_ id: UUID) -> Bool { ids.value.contains(id) }
}

@MainActor
private func rnodeScan(_ rig: ThreeRadioRig) -> PickerScanRun<DiscoveredRNode> {
    PickerScanRun(RNodeLive.scanRadios(central: rig.central), id: { $0.id })
}

@MainActor
private func meshCoreScan(_ rig: ThreeRadioRig) -> PickerScanRun<DiscoveredMeshCoreRadio> {
    PickerScanRun(MeshCoreLive.scanRadios(central: rig.central), id: { $0.id })
}

private let isBLEChannelClosed: @Sendable (BLEDriverEvent) -> Bool = { if case .channelClosed = $0 { return true }; return false }

/// The three radio drivers' event logs.
@MainActor
private struct Radios {
    let mesh: LiveDriverRun
    let core: LiveCoreDriverRun
    let rnode: LiveRNodeDriverRun
}

/// A running rig: the radios and, when started, BLE with one open channel.
@MainActor
private struct Running {
    let rig: ThreeRadioRig
    let radios: Radios
    let ble: DriverEventLog
    let channel: BLEChannelID

    nonisolated var mesh: LiveDriverRun { radios.mesh }
    nonisolated var core: LiveCoreDriverRun { radios.core }
    nonisolated var rnode: LiveRNodeDriverRun { radios.rnode }
}

/// Discovers the ble-reticulum peer, reads its identity and opens an outbound GATT channel.
@MainActor
private func openBLEChannel(_ rig: ThreeRadioRig, _ log: DriverEventLog) async -> BLEChannelID? {
    guard case let .peerDiscovered(handle)? = await log.first(isPeerDiscovered) else { return nil }
    guard await returns(within: 6, { await rig.ble.readIdentity(handle) }) else { return nil }
    guard case .identityRead? = await log.first(isIdentityOutcome) else { return nil }
    guard await returns(within: 6, { await rig.ble.openChannel(handle) }) else { return nil }
    guard case let .channelOpened(cid, _, _, _, _)? = await log.first(isChannelOutcome) else { return nil }
    return cid
}

/// The three radios started and connected. Records an issue and returns nil, after tearing down,
/// if any doesn't come up.
@MainActor
private func startRadios(_ rig: ThreeRadioRig) async -> Radios? {
    let radios = Radios(mesh: LiveDriverRun(rig.mesh.start(MeshtasticDriverConfig(radio: rig.meshtasticID))),
                        core: LiveCoreDriverRun(rig.mc.start(rig.coreConfig)),
                        rnode: LiveRNodeDriverRun(rig.rn.start(rig.rnodeConfig)))
    let meshUp = await radios.mesh.waitFor(isLiveConnected)
    let coreUp = await radios.core.waitFor(isLiveCoreConnected)
    let rnodeUp = await radios.rnode.waitFor(isLiveRNodeConnected)
    guard meshUp, coreUp, rnodeUp else {
        Issue.record("precondition: meshtastic \(meshUp) events \(radios.mesh.events.value); meshcore \(coreUp) events \(radios.core.events.value); rnode \(rnodeUp) events \(radios.rnode.events.value)")
        await tearDown(rig, ble: nil, radios: radios)
        return nil
    }
    return radios
}

/// BLE (with one open channel) and all three radios connected.
@MainActor
private func startEverything(_ rig: ThreeRadioRig) async -> Running? {
    let ble = DriverEventLog(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
    guard let radios = await startRadios(rig) else {
        await tearDown(rig, ble: ble, radios: nil)
        return nil
    }
    guard let channel = await openBLEChannel(rig, ble) else {
        Issue.record("precondition: BLE channel open, events \(ble.events.value)")
        await tearDown(rig, ble: ble, radios: radios)
        return nil
    }
    return Running(rig: rig, radios: radios, ble: ble, channel: channel)
}

/// Stops each given driver (bounded) and drops its stream. `skipRNode` leaves an already
/// stopped RNode alone.
@MainActor
private func tearDown(_ rig: ThreeRadioRig, ble: DriverEventLog?, radios: Radios?, skipRNode: Bool = false) async {
    if let ble {
        #expect(await returns(within: 6) { await rig.ble.stop() }, "BLE stop did not return")
        ble.cancel()
    }
    guard let radios else { return }
    #expect(await returns(within: 6) { await rig.mesh.stop() }, "Meshtastic stop did not return")
    radios.mesh.cancel()
    #expect(await returns(within: 6) { await rig.mc.stop() }, "MeshCore stop did not return")
    radios.core.cancel()
    if !skipRNode {
        #expect(await returns(within: 6) { await rig.rn.stop() }, "RNode stop did not return")
        radios.rnode.cancel()
    }
}

@MainActor
private func tearDown(_ running: Running) async {
    await tearDown(running.rig, ble: running.ble, radios: running.radios)
}

/// The Meshtastic radio's send returned `true` within 6 s and reached the radio.
@MainActor
private func meshtasticSendReaches(_ rig: ThreeRadioRig, _ data: Data) async -> Bool {
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
private func meshCoreSendReaches(_ rig: ThreeRadioRig, _ data: Data) async -> Bool {
    let sent = LockIsolated(false)
    let mc = rig.mc
    let before = rig.core.receivedFrames.filter { $0.first == 0x3E }.count
    let returned = await returns(within: 6) {
        let ok = await mc.send(data)
        sent.setValue(ok)
    }
    return returned && sent.value && rig.core.receivedFrames.filter { $0.first == 0x3E }.count == before + 1
}

/// The RNode's send returned `true` within 6 s and the radio received exactly this DATA frame.
@MainActor
private func rnodeSendReaches(_ rig: ThreeRadioRig, _ data: Data) async -> Bool {
    let sent = LockIsolated(false)
    let rn = rig.rn
    let before = rig.rnode.receivedPackets.count
    let returned = await returns(within: 6) {
        let ok = await rn.send(data)
        sent.setValue(ok)
    }
    let packets = rig.rnode.receivedPackets
    return returned && sent.value && packets.count == before + 1 && packets.last == data
}

/// Any `.disconnected` or `.unavailable`, whatever its reason: a reconnect maps to `.disconnected`.
private func meshtasticDrops(_ run: LiveDriverRun) -> Int {
    run.count { if case .disconnected = $0 { return true }; return false }
}
private func meshCoreDrops(_ run: LiveCoreDriverRun) -> Int {
    run.count {
        switch $0 {
        case .disconnected, .unavailable: return true
        default: return false
        }
    }
}
private func rnodeDrops(_ run: LiveRNodeDriverRun) -> Int {
    run.count {
        switch $0 {
        case .disconnected, .unavailable: return true
        default: return false
        }
    }
}

private func isRNodePacket(_ event: RNodeDriverEvent) -> Bool {
    if case .packet = event { return true }
    return false
}

private let meshtasticPayload = Data([0x00, 0xFF, 0x01])
private let meshCorePayload = Data([0x52, 0x01, 0x02])
private let rnodePayload = Data([0x52, 0x0A]) + Data(repeating: 0x5A, count: 60)

/// Spec §7: the RBTP BLE driver and live Meshtastic, MeshCore and RNode sessions on ONE live FCB
/// central over CoreBluetoothMock. The RNode and MeshCore share the Nordic UART service UUID.
extension FCBDriverAdapterCBMTests {
    @Suite @MainActor
    struct RNodeCoexistenceTests {
        // MARK: All three radios beside a BLE peer

        @Test func allThreeRadiosConnectBesideABLEPeer() async {
            let rig = await makeThreeRadioRig()
            guard let running = await startEverything(rig) else { return }
            #expect(await rnodeSendReaches(rig, rnodePayload), "the RNode send failed or did not return")
            #expect(await meshtasticSendReaches(rig, meshtasticPayload), "the Meshtastic send failed or did not return")
            #expect(await meshCoreSendReaches(rig, meshCorePayload), "the MeshCore send failed or did not return")
            #expect(rig.core.receivedFrames.filter { $0.first == 0x3E }.count == 1, "the RNode's packet reached MeshCore")
            await tearDown(running)
        }

        // MARK: One link drops, the others carry on

        /// Probe (user-approved exception): exercises MeshCoreKit and FCB, not this lane's code.
        @Test func anRNodeLinkDropLeavesMeshCoreSending() async {
            let rig = await makeThreeRadioRig()
            guard let running = await startEverything(rig) else { return }
            rig.rnode.simulateDisconnect()
            #expect(await running.rnode.waitFor { $0 == .disconnected(reason: nil) }, "precondition: the RNode link dropped")
            #expect(await liveWaitUntil(timeout: .seconds(15)) { running.rnode.count(isLiveRNodeConnected) == 2 },
                    "precondition: the RNode came back: \(running.rnode.events.value)")
            #expect(await meshCoreSendReaches(rig, meshCorePayload), "the MeshCore send failed or did not return")
            #expect(meshCoreDrops(running.core) == 0, "MeshCore saw the RNode drop: \(running.core.events.value)")
            await tearDown(running)
        }

        /// Probe (user-approved exception): exercises MeshtasticKit and FCB, not this lane's code.
        @Test func anRNodeLinkDropLeavesMeshtasticConnected() async {
            let rig = await makeThreeRadioRig()
            guard let running = await startEverything(rig) else { return }
            rig.rnode.simulateDisconnect()
            #expect(await running.rnode.waitFor { $0 == .disconnected(reason: nil) }, "precondition: the RNode link dropped")
            #expect(await liveWaitUntil(timeout: .seconds(15)) { running.rnode.count(isLiveRNodeConnected) == 2 },
                    "precondition: the RNode came back: \(running.rnode.events.value)")
            #expect(meshtasticDrops(running.mesh) == 0, "Meshtastic saw the RNode drop: \(running.mesh.events.value)")
            #expect(await meshtasticSendReaches(rig, meshtasticPayload), "the Meshtastic send failed or did not return")
            await tearDown(running)
        }

        /// Review Focus 3: the MeshCore radio sharing the RNode's service UUID drops; the RNode
        /// neither sees it nor stops sending.
        @Test func aMeshCoreLinkDropLeavesTheRNodeSending() async {
            let rig = await makeThreeRadioRig()
            guard let running = await startEverything(rig) else { return }
            rig.coreSpec.simulateDisconnection()
            #expect(await running.core.waitFor { $0 == .disconnected(reason: nil) }, "precondition: the MeshCore link dropped")
            #expect(await liveWaitUntil(timeout: .seconds(15)) { running.core.count(isLiveCoreConnected) == 2 },
                    "precondition: MeshCore came back: \(running.core.events.value)")
            #expect(rnodeDrops(running.rnode) == 0, "the RNode saw the MeshCore drop: \(running.rnode.events.value)")
            #expect(await rnodeSendReaches(rig, rnodePayload), "the RNode send failed or did not return")
            await tearDown(running)
        }

        @Test func aBLEPeerDropLeavesEveryRadioConnected() async {
            let rig = await makeThreeRadioRig()
            guard let running = await startEverything(rig) else { return }
            rig.peerSpec.simulateDisconnection()
            #expect(await running.ble.first(isBLEChannelClosed) != nil, "precondition: the BLE peer dropped")
            #expect(await rnodeSendReaches(rig, rnodePayload), "the RNode send failed or did not return")
            #expect(await meshtasticSendReaches(rig, meshtasticPayload), "the Meshtastic send failed or did not return")
            #expect(await meshCoreSendReaches(rig, meshCorePayload), "the MeshCore send failed or did not return")
            #expect(rnodeDrops(running.rnode) == 0, "the RNode saw the BLE drop: \(running.rnode.events.value)")
            #expect(meshtasticDrops(running.mesh) == 0, "Meshtastic saw the BLE drop: \(running.mesh.events.value)")
            #expect(meshCoreDrops(running.core) == 0, "MeshCore saw the BLE drop: \(running.core.events.value)")
            await tearDown(running)
        }

        // MARK: Stopping the RNode

        @Test func stoppingTheRNodeLeavesTheOtherRadiosSending() async {
            let rig = await makeThreeRadioRig()
            guard let running = await startEverything(rig) else { return }
            #expect(await returns(within: 6) { await rig.rn.stop() }, "RNode stop did not return")
            running.rnode.cancel()
            #expect(await liveWaitUntil { rig.rnode.linkDrops == 1 }, "precondition: the RNode link closed")
            #expect(await meshtasticSendReaches(rig, meshtasticPayload), "the Meshtastic send failed or did not return")
            #expect(await meshCoreSendReaches(rig, meshCorePayload), "the MeshCore send failed or did not return")
            #expect(meshtasticDrops(running.mesh) == 0, "Meshtastic events: \(running.mesh.events.value)")
            #expect(meshCoreDrops(running.core) == 0, "MeshCore events: \(running.core.events.value)")
            #expect(!running.ble.events.value.contains(where: isBLEChannelClosed), "the BLE channel closed with the RNode stop")
            await tearDown(rig, ble: running.ble, radios: running.radios, skipRNode: true)
        }

        // MARK: Each packet reaches only its own session

        /// Review Focus 3: the two NUS radios each talk only to their own peripheral.
        @Test func packetsReachOnlyTheirOwnSession() async {
            let rig = await makeThreeRadioRig()
            guard let running = await startEverything(rig) else { return }
            let onAir = Data([0x52, 0x0B]) + Data(repeating: 0x21, count: 30)
            rig.rnode.injectPacket(onAir)
            #expect(await running.rnode.waitFor { $0 == .packet(onAir, rssi: -67, snr: 6.0) },
                    "the RNode packet did not arrive: \(running.rnode.events.value)")
            let datagram = Data([0x52, 0x0C]) + Data(repeating: 0x22, count: 30)
            rig.core.injectChannelData(datagram, channelIndex: 1)
            #expect(await running.core.waitFor { $0 == .datagram(datagram) },
                    "the MeshCore datagram did not arrive: \(running.core.events.value)")
            #expect(running.core.count(isLiveCoreDatagram) == 1, "MeshCore got the RNode's packet: \(running.core.events.value)")
            #expect(running.rnode.count(isRNodePacket) == 1, "the RNode got MeshCore's datagram: \(running.rnode.events.value)")
            await tearDown(running)
        }

        // MARK: Bluetooth power cycle

        /// No action is taken after the power cycle: every session reconnects on its own.
        @Test func everyRadioComesBackAfterABluetoothPowerCycle() async {
            let rig = await makeThreeRadioRig()
            guard let radios = await startRadios(rig) else { return }
            CBMCentralManagerMock.simulatePowerOff()
            #expect(await radios.mesh.waitFor(timeout: .seconds(10)) { $0 == .disconnected(reason: nil) },
                    "Meshtastic events: \(radios.mesh.events.value)")
            #expect(await radios.core.waitFor(timeout: .seconds(10)) { $0 == .disconnected(reason: nil) },
                    "MeshCore events: \(radios.core.events.value)")
            #expect(await liveWaitUntil(timeout: .seconds(10)) { rnodeDrops(radios.rnode) > 0 },
                    "RNode events: \(radios.rnode.events.value)")
            CBMCentralManagerMock.simulatePowerOn()
            #expect(await liveWaitUntil(timeout: .seconds(15)) { radios.rnode.count(isLiveRNodeConnected) == 2 },
                    "the RNode did not come back: \(radios.rnode.events.value)")
            #expect(await liveWaitUntil(timeout: .seconds(15)) { radios.mesh.count(isLiveConnected) == 2 },
                    "Meshtastic did not come back: \(radios.mesh.events.value)")
            #expect(await liveWaitUntil(timeout: .seconds(15)) { radios.core.count(isLiveCoreConnected) == 2 },
                    "MeshCore did not come back: \(radios.core.events.value)")
            #expect(await rnodeSendReaches(rig, rnodePayload), "the RNode send failed or did not return")
            #expect(await meshtasticSendReaches(rig, meshtasticPayload), "the Meshtastic send failed or did not return")
            #expect(await meshCoreSendReaches(rig, meshCorePayload), "the MeshCore send failed or did not return")
            await tearDown(rig, ble: nil, radios: radios)
        }

        // MARK: The pickers' scans

        /// Review Focus 3: the RNode picker lists RNodes only, though MeshCore shares the UUID.
        @Test func anRNodeScanFindsOnlyRNodes() async {
            let rig = await makeThreeRadioRig()
            let scan = rnodeScan(rig)
            #expect(await liveWaitUntil { scan.saw(rig.rnodeID) }, "the scan did not see the RNode (finished: \(scan.finished.value))")
            rig.rnode2Spec.simulateProximityChange(.near)
            #expect(await liveWaitUntil { scan.saw(rig.rnode2ID) }, "the scan did not see the second RNode (finished: \(scan.finished.value))")
            #expect(!scan.saw(rig.coreID), "the MeshCore radio was listed: \(scan.ids.value)")
            #expect(!scan.saw(rig.meshtasticID), "the Meshtastic radio was listed: \(scan.ids.value)")
            #expect(!scan.saw(rig.peerSpec.identifier), "the BLE peer was listed: \(scan.ids.value)")
            scan.cancel()
        }

        /// Probe (user-approved exception): exercises MeshCoreKit's scanner, not this lane's code.
        @Test func aMeshCoreScanFindsNoRNode() async {
            let rig = await makeThreeRadioRig()
            let scan = meshCoreScan(rig)
            #expect(await liveWaitUntil { scan.saw(rig.coreID) }, "the scan did not see the MeshCore radio (finished: \(scan.finished.value))")
            rig.rnode2Spec.simulateProximityChange(.near)
            // Bounded wait for something that must not happen; both RNodes advertise every 50 ms.
            let listed = await liveWaitUntil(timeout: .milliseconds(500)) {
                scan.saw(rig.rnodeID) || scan.saw(rig.rnode2ID)
            }
            #expect(!listed, "an RNode was listed: \(scan.ids.value)")
            scan.cancel()
        }

        /// The RNode picker's scan runs while all three radios are connected: none is disturbed.
        @Test func anRNodeScanDoesNotDisconnectAnyRadio() async {
            let rig = await makeThreeRadioRig()
            guard let radios = await startRadios(rig) else { return }
            let scan = rnodeScan(rig)
            rig.rnode2Spec.simulateProximityChange(.near)
            #expect(await liveWaitUntil { scan.saw(rig.rnode2ID) }, "precondition: the scan is running and saw the second RNode")
            #expect(await rnodeSendReaches(rig, rnodePayload), "the RNode send failed or did not return")
            #expect(await meshtasticSendReaches(rig, meshtasticPayload), "the Meshtastic send failed or did not return")
            #expect(await meshCoreSendReaches(rig, meshCorePayload), "the MeshCore send failed or did not return")
            #expect(rnodeDrops(radios.rnode) == 0, "RNode events: \(radios.rnode.events.value)")
            #expect(meshtasticDrops(radios.mesh) == 0, "Meshtastic events: \(radios.mesh.events.value)")
            #expect(meshCoreDrops(radios.core) == 0, "MeshCore events: \(radios.core.events.value)")
            scan.cancel()
            await tearDown(rig, ble: nil, radios: radios)
        }

        /// Picker DISMISS: cancelling the consumer ends the RNode scanner's own FCB scan, so BLE's
        /// new scan is the only one and discovers.
        @Test func theBLEScanRestartsAfterTheRNodePickerCloses() async {
            let rig = await makeThreeRadioRig()
            let first = DriverEventLog(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
            #expect(await first.first(isPeerDiscovered) != nil, "precondition: BLE is scanning")
            #expect(await returns(within: 6) { await rig.ble.stop() }, "BLE stop did not return")
            first.cancel()
            let scan = rnodeScan(rig)
            #expect(await liveWaitUntil { scan.saw(rig.rnodeID) }, "precondition: the scan saw the RNode")
            scan.cancel()
            #expect(await liveWaitUntil(timeout: .seconds(2)) { scan.finished.value }, "the cancelled scan did not finish")
            let manager = rig.manager
            #expect(await liveWaitUntil(timeout: .seconds(2)) { !manager.isScanning },
                    "cancelling the scan left its FCB scan running")
            let ble = DriverEventLog(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
            #expect(await ble.first(within: 3, isPeerDiscovered) != nil, "BLE online but not discovering: \(ble.events.value)")
            await tearDown(rig, ble: ble, radios: nil)
        }
    }
}
