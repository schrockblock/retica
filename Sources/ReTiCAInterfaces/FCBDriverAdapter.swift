import Foundation
@preconcurrency import CoreBluetooth
import ComposableArchitecture
import FCBComposable

private let rbtpServiceUUID = CBUUID(string: "99872ed7-eba8-4c07-bf35-ab464a957f80")
private let rbtpVersionCharUUID = CBUUID(string: "50870e44-2fd6-4cbc-9f1f-11a0fcf85265")
private let rbtpPSMCharUUID = CBUUID(string: "1cfe213f-4ea4-48f9-9344-dde18cc729ef")

/// The RBTP v2 GATT directory service: Version + PSM, both read-only.
func rbtpDirectoryService(version: UInt8, psm: UInt16, pairingMode: BLEPairingMode) -> MutableService {
    let permissions: CBAttributePermissions =
        pairingMode == .paired ? .readEncryptionRequired : .readable
    let versionChar = MutableCharacteristic(
        id: rbtpVersionCharUUID, properties: .read, permissions: permissions,
        value: Data([version]))
    let psmChar = MutableCharacteristic(
        id: rbtpPSMCharUUID, properties: .read, permissions: permissions,
        value: Data([UInt8(psm & 0xFF), UInt8(psm >> 8)]))  // little-endian
    return MutableService(id: rbtpServiceUUID, isPrimary: true, characteristics: [versionChar, psmChar])
}

/// Mechanism-only adapter mapping FCB's two clients onto the BLEDriver contract.
/// No policy, no retries, no framing — the BLEInterface reducer owns all of that.
actor FCBDriverAdapter {
    private let central: BluetoothCentralClient
    private let peripheral: BluetoothPeripheralClient

    private var continuation: AsyncStream<BLEDriverEvent>.Continuation?
    private var config = BLEDriverConfig(version: 2, pairingMode: .open)
    private var tasks: [Task<Void, Never>] = []

    private var advertising = false
    private var scanning = false
    private var announcedReady = false
    private var announcedUnavailable = false

    // Populated in later tasks.
    private var seenPeers: Set<UUID> = []
    private var connections: [BLEChannelID: L2CAPConnection] = [:]
    private var reducerClosed: Set<BLEChannelID> = []
    private var publishedPSM: UInt16?

    init(central: BluetoothCentralClient, peripheral: BluetoothPeripheralClient) {
        self.central = central
        self.peripheral = peripheral
    }

    nonisolated func start(_ config: BLEDriverConfig) -> AsyncStream<BLEDriverEvent> {
        AsyncStream<BLEDriverEvent> { continuation in
            Task { await self.begin(config: config, continuation: continuation) }
        }
    }

    private func begin(config: BLEDriverConfig, continuation: AsyncStream<BLEDriverEvent>.Continuation) {
        self.teardown()
        self.config = config
        self.continuation = continuation
        self.announcedReady = false
        self.announcedUnavailable = false
        self.seenPeers = []

        // Peripheral role: on poweredOn → publish L2CAP → add directory → advertise.
        tasks.append(Task { [peripheral] in
            for await state in peripheral.state() {
                await self.handlePeripheralState(state)
            }
        })
        // Central role: on poweredOn → scan.
        tasks.append(Task { [central] in
            for await state in central.state() {
                await self.handleCentralState(state)
            }
        })
        // Central events (disconnect → forget) and inbound L2CAP channels.
        // Scanning is issued from bringUpCentral() on central power-on via
        // restartScan(), NOT here.
        subscribeCentralEvents()
        subscribeInboundL2CAP()
    }

    private func handlePeripheralState(_ state: CBManagerState) async {
        switch state {
        case .poweredOn:
            await bringUpPeripheral()
        case .poweredOff, .unauthorized, .unsupported:
            fireUnavailable("peripheral \(stateName(state))")
        default:
            break
        }
    }

    private func handleCentralState(_ state: CBManagerState) async {
        switch state {
        case .poweredOn:
            await bringUpCentral()
        case .poweredOff, .unauthorized, .unsupported:
            fireUnavailable("central \(stateName(state))")
        default:
            break
        }
    }

    private func bringUpPeripheral() async {
        do {
            let psm = try await peripheral.publishL2CAPChannel(config.pairingMode == .paired)
            publishedPSM = psm
            _ = try await peripheral.add(rbtpDirectoryService(
                version: config.version, psm: psm, pairingMode: config.pairingMode))
            try await peripheral.startAdvertising(
                AdvertisementData(serviceUUIDs: [rbtpServiceUUID]))
            advertising = true
            checkReady()
        } catch {
            fireUnavailable("peripheral setup failed: \(error)")
        }
    }

    private func bringUpCentral() async {
        // Issuing central.scan() is what starts discovery; the scan AsyncStream
        // is created lazily by FCB when scan() is called, so issue it here on
        // power-on.
        restartScan()
        scanning = true
        checkReady()
    }

    private func checkReady() {
        guard advertising, scanning, !announcedReady else { return }
        announcedReady = true
        continuation?.yield(.ready)
    }

    private func fireUnavailable(_ reason: String) {
        guard !announcedUnavailable else { return }
        announcedUnavailable = true
        continuation?.yield(.unavailable(reason: reason))
    }

    private func stateName(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    private func teardown() {
        for t in tasks { t.cancel() }
        tasks = []
        advertising = false
        scanning = false
    }

    // Issues central.scan() and pumps discoveries to handleDiscovered.
    private func restartScan() {
        tasks.append(Task { [central] in
            for await discovered in central.scan([rbtpServiceUUID], ScanOptions(allowDuplicates: true)) {
                await self.handleDiscovered(discovered)
            }
        })
    }

    // Filled in Tasks 3–4 (bodies empty here so startup compiles & tests).
    private func subscribeCentralEvents() {}
    private func subscribeInboundL2CAP() {}
    private func handleDiscovered(_ discovered: DiscoveredPeripheral) async {}

    // Command stubs — Tasks 3–4 implement.
    func readDirectory(_ peer: BLEPeerHandle) async {}
    func openChannel(_ peer: BLEPeerHandle, psm: UInt16) async {}
    func send(_ channel: BLEChannelID, data: Data) async {}
    func closeChannel(_ channel: BLEChannelID) async {}

    func stop() async {
        teardown()
        await central.stopScan()
        await peripheral.stopAdvertising()
        await peripheral.removeAll()
        if let psm = publishedPSM { await peripheral.unpublishL2CAPChannel(psm) }
        for (_, conn) in connections { await conn.close() }
        connections = [:]
        continuation?.finish()
        continuation = nil
    }
}

extension BLEDriver {
    /// Composes FCB's clients into the BLEDriver contract.
    public static func fcb(
        central: BluetoothCentralClient,
        peripheral: BluetoothPeripheralClient
    ) -> BLEDriver {
        let adapter = FCBDriverAdapter(central: central, peripheral: peripheral)
        return BLEDriver(
            start: { config in adapter.start(config) },
            readDirectory: { peer in await adapter.readDirectory(peer) },
            openChannel: { peer, psm in await adapter.openChannel(peer, psm: psm) },
            send: { channel, data in await adapter.send(channel, data: data) },
            closeChannel: { channel in await adapter.closeChannel(channel) },
            stop: { await adapter.stop() }
        )
    }
}
