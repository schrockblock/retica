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

    private func begin(config: BLEDriverConfig, continuation: AsyncStream<BLEDriverEvent>.Continuation) async {
        await resetSession()
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
            fireUnavailable(Self.cause(state))
        default:
            break
        }
    }

    private func handleCentralState(_ state: CBManagerState) async {
        switch state {
        case .poweredOn:
            await bringUpCentral()
        case .poweredOff, .unauthorized, .unsupported:
            fireUnavailable(Self.cause(state))
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
            fireUnavailable(.other("peripheral setup failed: \(error)"))
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

    private func fireUnavailable(_ cause: BLEAdapterUnavailable) {
        guard !announcedUnavailable else { return }
        announcedUnavailable = true
        continuation?.yield(.unavailable(cause))
    }

    /// Maps a `CBManagerState` onto the structured cause. Only the three unavailable states are
    /// mapped here (the call sites gate on them); anything else falls back to `.other` rather than
    /// pretending to be a permission or hardware signal.
    static func cause(_ s: CBManagerState) -> BLEAdapterUnavailable {
        switch s {
        case .poweredOff:   return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported:  return .unsupported
        default:            return .other(nil)
        }
    }

    /// Cancels tasks, closes+clears connections, unpublishes our PSM, and finishes
    /// the previous event stream — so a start() that was NOT preceded by stop()
    /// (the reducer's adapter-retry path) still begins from a clean slate.
    private func resetSession() async {
        for t in tasks { t.cancel() }
        tasks = []
        advertising = false
        scanning = false
        for (_, conn) in connections { await conn.close() }
        connections = [:]
        reducerClosed = []
        if let psm = publishedPSM {
            await peripheral.unpublishL2CAPChannel(psm)
            publishedPSM = nil
        }
        continuation?.finish()
        continuation = nil
    }

    // Issues central.scan() and pumps discoveries to handleDiscovered.
    private func restartScan() {
        tasks.append(Task { [central] in
            for await discovered in central.scan([rbtpServiceUUID], ScanOptions(allowDuplicates: true)) {
                await self.handleDiscovered(discovered)
            }
        })
    }

    private func subscribeCentralEvents() {
        tasks.append(Task { [central] in
            for await event in central.events() {
                await self.handleCentralEvent(event)
            }
        })
    }

    private func handleCentralEvent(_ event: CentralEvent) async {
        if case let .didDisconnect(peripheral, _) = event {
            forget(peripheral.id)
        }
    }

    private func handleDiscovered(_ discovered: DiscoveredPeripheral) async {
        let id = discovered.peripheral.id
        guard !seenPeers.contains(id) else { return }
        seenPeers.insert(id)
        continuation?.yield(.peerDiscovered(BLEPeerHandle(id: id)))
    }

    private func forget(_ id: UUID) { seenPeers.remove(id) }

    /// Wraps a live L2CAPConnection: mints a channel ID, emits channelOpened,
    /// and pumps incoming() → channelData, with channelClosed on stream end
    /// unless the reducer closed it (silent close, no echo).
    private func register(_ conn: L2CAPConnection, direction: BLEChannelDirection) {
        let channelID = BLEChannelID(id: UUID())
        connections[channelID] = conn
        continuation?.yield(.channelOpened(channelID, BLEPeerHandle(id: conn.peerID), direction: direction))
        tasks.append(Task { [conn] in
            for await chunk in conn.incoming() {
                await self.emitChannelData(channelID, chunk)
            }
            await self.channelDidClose(channelID)
        })
    }

    private func emitChannelData(_ id: BLEChannelID, _ data: Data) {
        guard connections[id] != nil else { return }
        continuation?.yield(.channelData(id, data))
    }

    private func channelDidClose(_ id: BLEChannelID) {
        guard connections.removeValue(forKey: id) != nil else { return }
        let reducerInitiated = reducerClosed.remove(id) != nil
        if !reducerInitiated {
            continuation?.yield(.channelClosed(id, reason: nil))
        }
    }

    func readDirectory(_ peer: BLEPeerHandle) async {
        do {
            _ = try await central.connect(peer.id, nil)
            _ = try await central.discoverServices(peer.id, [rbtpServiceUUID])
            _ = try await central.discoverCharacteristics(peer.id, rbtpServiceUUID, [rbtpVersionCharUUID, rbtpPSMCharUUID])
            let versionData = try await central.readValue(peer.id, rbtpVersionCharUUID)
            let psmData = try await central.readValue(peer.id, rbtpPSMCharUUID)
            guard versionData.count >= 1, psmData.count >= 2 else {
                forget(peer.id)
                try? await central.disconnect(peer.id)
                continuation?.yield(.directoryFailed(peer, reason: "short directory read"))
                return
            }
            let version = versionData[versionData.startIndex]
            let lo = UInt16(psmData[psmData.startIndex])
            let hi = UInt16(psmData[psmData.startIndex + 1])
            continuation?.yield(.directoryRead(peer, version: version, psm: lo | (hi << 8)))
        } catch {
            forget(peer.id)
            try? await central.disconnect(peer.id)
            continuation?.yield(.directoryFailed(peer, reason: "\(error)"))
        }
    }

    func openChannel(_ peer: BLEPeerHandle, psm: UInt16) async {
        do {
            let conn = try await central.openL2CAPChannel(peer.id, psm)
            register(conn, direction: .outbound)
        } catch {
            forget(peer.id)
            continuation?.yield(.channelFailed(peer, reason: "\(error)"))
        }
    }

    private func subscribeInboundL2CAP() {
        tasks.append(Task { [peripheral] in
            for await conn in peripheral.l2capConnections() {
                await self.registerInbound(conn)
            }
        })
    }

    private func registerInbound(_ conn: L2CAPConnection) {
        register(conn, direction: .inbound)
    }

    func send(_ channel: BLEChannelID, data: Data) async {
        guard let conn = connections[channel] else { return }
        try? await conn.send(data)
    }

    func closeChannel(_ channel: BLEChannelID) async {
        guard let conn = connections[channel] else { return }
        reducerClosed.insert(channel)   // suppress the channelClosed echo
        await conn.close()
    }

    func stop() async {
        await resetSession()
        await central.stopScan()
        await peripheral.stopAdvertising()
        await peripheral.removeAll()
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
