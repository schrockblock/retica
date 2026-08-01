#if canImport(CoreBluetooth) && (os(iOS) || os(macOS))
import Foundation
@preconcurrency import CoreBluetooth

private let serviceUUID = CBUUID(string: "99872ed7-eba8-4c07-bf35-ab464a957f80")
private let versionUUID = CBUUID(string: "50870e44-2fd6-4cbc-9f1f-11a0fcf85265")
private let psmUUID = CBUUID(string: "1cfe213f-4ea4-48f9-9344-dde18cc729ef")

/// Live CoreBluetooth implementation of the BLEDriver contract. Mechanism only:
/// advertises + serves the GATT directory + publishes the L2CAP listener
/// (peripheral role) while scanning + reading directories + dialing channels
/// (central role). All policy lives in the BLEInterface reducer.
final class CoreBluetoothDriver: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "retica.ble.driver")
    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var continuation: AsyncStream<BLEDriverEvent>.Continuation?
    private var config = BLEDriverConfig(version: 0, pairingMode: .open)

    private var advertising = false
    private var scanning = false
    private var announcedReady = false
    private var announcedUnavailable = false

    private var peripherals: [UUID: CBPeripheral] = [:]
    private var seenPeers: Set<UUID> = []
    private var directoryReads: [UUID: (version: UInt8?, psm: UInt16?)] = [:]
    private var channels: [BLEChannelID: ChannelIO] = [:]

    // MARK: BLEDriver contract (each hops onto the driver queue)

    func start(_ config: BLEDriverConfig) -> AsyncStream<BLEDriverEvent> {
        AsyncStream { continuation in
            self.queue.async {
                self.teardownLocked()
                self.config = config
                self.continuation = continuation
                self.announcedReady = false
                self.announcedUnavailable = false
                self.central = CBCentralManager(delegate: self, queue: self.queue)
                self.peripheralManager = CBPeripheralManager(delegate: self, queue: self.queue)
            }
        }
    }

    func readDirectory(_ peer: BLEPeerHandle) {
        queue.async {
            guard let central = self.central, let peripheral = self.peripherals[peer.id] else {
                self.emit(.directoryFailed(peer, reason: "unknown peripheral"))
                return
            }
            self.directoryReads[peer.id] = (nil, nil)
            peripheral.delegate = self
            central.connect(peripheral)
        }
    }

    func openChannel(_ peer: BLEPeerHandle, psm: UInt16) {
        queue.async {
            guard let peripheral = self.peripherals[peer.id], peripheral.state == .connected else {
                self.forget(peer.id)
                self.emit(.channelFailed(peer, reason: "not connected"))
                return
            }
            peripheral.openL2CAPChannel(CBL2CAPPSM(psm))
        }
    }

    func send(_ channelID: BLEChannelID, data: Data) {
        queue.async { self.channels[channelID]?.send(data) }
    }

    func closeChannel(_ channelID: BLEChannelID) {
        queue.async { self.channels.removeValue(forKey: channelID)?.close() }
    }

    func stop() {
        queue.async { self.teardownLocked() }
    }

    // MARK: Internals (always on queue)

    private func teardownLocked() {
        for (_, io) in channels { io.close() }
        channels = [:]
        directoryReads = [:]
        seenPeers = []
        if let central {
            if central.isScanning { central.stopScan() }
            for (_, p) in peripherals where p.state != .disconnected {
                central.cancelPeripheralConnection(p)
            }
        }
        peripherals = [:]
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        central = nil
        peripheralManager = nil
        advertising = false
        scanning = false
        continuation?.finish()
        continuation = nil
    }

    private func emit(_ event: BLEDriverEvent) {
        continuation?.yield(event)
    }

    private func checkReady() {
        guard advertising, scanning, !announcedReady else { return }
        announcedReady = true
        emit(.ready)
    }

    private func fireUnavailable(_ reason: String) {
        guard !announcedUnavailable else { return }
        announcedUnavailable = true
        emit(.unavailable(reason: reason))
    }

    /// Allows a peer to be re-discovered after a failure or disconnect.
    private func forget(_ id: UUID) {
        seenPeers.remove(id)
        directoryReads[id] = nil
    }

    private func makeChannel(_ cbChannel: CBL2CAPChannel, peer: UUID, direction: BLEChannelDirection) {
        let channelID = BLEChannelID(id: UUID())
        let io = ChannelIO(channel: cbChannel, queue: queue) { [weak self] data in
            self?.emit(.channelData(channelID, data))
        } onClosed: { [weak self] reason in
            guard let self else { return }
            self.channels[channelID] = nil
            self.forget(peer)
            self.emit(.channelClosed(channelID, reason: reason))
        }
        channels[channelID] = io
        io.open()
        emit(.channelOpened(channelID, BLEPeerHandle(id: peer), direction: direction))
    }

    private func finishDirectoryReadIfComplete(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        guard let read = directoryReads[id], let version = read.version, let psm = read.psm else { return }
        directoryReads[id] = nil
        emit(.directoryRead(BLEPeerHandle(id: id), version: version, psm: psm))
    }

    private func failDirectoryRead(_ id: UUID, reason: String?) {
        guard directoryReads[id] != nil else { return }
        directoryReads[id] = nil
        forget(id)
        emit(.directoryFailed(BLEPeerHandle(id: id), reason: reason))
    }
}

// MARK: - Central role

extension CoreBluetoothDriver: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(
                withServices: [serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            scanning = true
            checkReady()
        case .poweredOff, .unauthorized, .unsupported:
            fireUnavailable("central \(central.state.rawValue)")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        guard !seenPeers.contains(id) else { return }
        seenPeers.insert(id)
        peripherals[id] = peripheral
        emit(.peerDiscovered(BLEPeerHandle(id: id)))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        failDirectoryRead(peripheral.identifier, reason: error?.localizedDescription ?? "connect failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        failDirectoryRead(peripheral.identifier, reason: error?.localizedDescription ?? "disconnected")
        forget(peripheral.identifier)
        // Any open channel's streams will error and report channelClosed themselves.
    }
}

// MARK: - Peripheral (remote) GATT + outbound channel

extension CoreBluetoothDriver: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceUUID })
        else {
            failDirectoryRead(peripheral.identifier,
                              reason: error?.localizedDescription ?? "service not found")
            return
        }
        peripheral.discoverCharacteristics([versionUUID, psmUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else {
            failDirectoryRead(peripheral.identifier,
                              reason: error?.localizedDescription ?? "characteristics not found")
            return
        }
        var found = 0
        for characteristic in characteristics
        where characteristic.uuid == versionUUID || characteristic.uuid == psmUUID {
            peripheral.readValue(for: characteristic)
            found += 1
        }
        if found < 2 {
            failDirectoryRead(peripheral.identifier, reason: "directory characteristics missing")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        guard error == nil, let value = characteristic.value, directoryReads[id] != nil else {
            failDirectoryRead(id, reason: error?.localizedDescription ?? "read failed")
            return
        }
        if characteristic.uuid == versionUUID, value.count >= 1 {
            directoryReads[id]?.version = value[value.startIndex]
        } else if characteristic.uuid == psmUUID, value.count >= 2 {
            let rebased = Data(value)
            directoryReads[id]?.psm = UInt16(rebased[0]) | (UInt16(rebased[1]) << 8)  // little-endian
        } else {
            failDirectoryRead(id, reason: "malformed characteristic value")
            return
        }
        finishDirectoryReadIfComplete(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        let id = peripheral.identifier
        guard error == nil, let channel else {
            forget(id)
            emit(.channelFailed(BLEPeerHandle(id: id),
                                reason: error?.localizedDescription ?? "L2CAP open failed"))
            return
        }
        makeChannel(channel, peer: id, direction: .outbound)
    }
}

// MARK: - Peripheral (local) role: advertise, GATT directory, L2CAP listener

extension CoreBluetoothDriver: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            peripheral.publishL2CAPChannel(withEncryption: config.pairingMode == .paired)
        case .poweredOff, .unauthorized, .unsupported:
            fireUnavailable("peripheral \(peripheral.state.rawValue)")
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        guard error == nil else {
            fireUnavailable("publishL2CAPChannel: \(error!.localizedDescription)")
            return
        }
        let permissions: CBAttributePermissions =
            config.pairingMode == .paired ? .readEncryptionRequired : .readable
        let versionCharacteristic = CBMutableCharacteristic(
            type: versionUUID, properties: .read,
            value: Data([config.version]), permissions: permissions)
        var psmValue = Data(count: 2)
        psmValue[0] = UInt8(PSM & 0xFF)
        psmValue[1] = UInt8(PSM >> 8)  // little-endian per spec
        let psmCharacteristic = CBMutableCharacteristic(
            type: psmUUID, properties: .read, value: psmValue, permissions: permissions)
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [versionCharacteristic, psmCharacteristic]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService,
                           error: Error?) {
        guard error == nil else {
            fireUnavailable("add service: \(error!.localizedDescription)")
            return
        }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID]])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard error == nil else {
            fireUnavailable("advertising: \(error!.localizedDescription)")
            return
        }
        advertising = true
        checkReady()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?,
                           error: Error?) {
        guard error == nil, let channel else { return }
        makeChannel(channel, peer: channel.peer.identifier, direction: .inbound)
    }
}

// MARK: - L2CAP channel stream pump

/// Owns one CBL2CAPChannel's stream pair. Confined to the driver queue via
/// CFStream dispatch-queue scheduling; buffers writes until space is available.
private final class ChannelIO: NSObject, StreamDelegate {
    private let channel: CBL2CAPChannel
    private let queue: DispatchQueue
    private let onData: (Data) -> Void
    private let onClosed: (String?) -> Void
    private var outBuffer = Data()
    private var finished = false

    init(channel: CBL2CAPChannel, queue: DispatchQueue,
         onData: @escaping (Data) -> Void, onClosed: @escaping (String?) -> Void) {
        self.channel = channel
        self.queue = queue
        self.onData = onData
        self.onClosed = onClosed
    }

    func open() {
        guard let input = channel.inputStream, let output = channel.outputStream else {
            finish(reason: "missing streams")
            return
        }
        input.delegate = self
        output.delegate = self
        CFReadStreamSetDispatchQueue(input as CFReadStream, queue)
        CFWriteStreamSetDispatchQueue(output as CFWriteStream, queue)
        input.open()
        output.open()
    }

    func send(_ data: Data) {
        outBuffer.append(data)
        drain()
    }

    /// Silent close (no onClosed callback) — used when the reducer asked for it.
    func close() {
        finished = true
        teardownStreams()
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            readAvailable()
        case .hasSpaceAvailable:
            drain()
        case .errorOccurred:
            finish(reason: aStream.streamError?.localizedDescription ?? "stream error")
        case .endEncountered:
            finish(reason: nil)
        default:
            break
        }
    }

    private func drain() {
        guard !finished, let output = channel.outputStream else { return }
        while output.hasSpaceAvailable, !outBuffer.isEmpty {
            let written = outBuffer.withUnsafeBytes { raw in
                output.write(raw.bindMemory(to: UInt8.self).baseAddress!, maxLength: outBuffer.count)
            }
            if written <= 0 { break }
            outBuffer.removeFirst(written)
        }
    }

    private func readAvailable() {
        guard !finished, let input = channel.inputStream else { return }
        var scratch = [UInt8](repeating: 0, count: 4096)
        while input.hasBytesAvailable {
            let count = input.read(&scratch, maxLength: scratch.count)
            if count > 0 {
                onData(Data(scratch[0..<count]))
            } else if count < 0 {
                finish(reason: input.streamError?.localizedDescription ?? "read error")
                return
            } else {
                break
            }
        }
    }

    private func finish(reason: String?) {
        guard !finished else { return }
        finished = true
        teardownStreams()
        onClosed(reason)
    }

    private func teardownStreams() {
        if let input = channel.inputStream {
            input.close()
            CFReadStreamSetDispatchQueue(input as CFReadStream, nil)
        }
        if let output = channel.outputStream {
            output.close()
            CFWriteStreamSetDispatchQueue(output as CFWriteStream, nil)
        }
    }
}
#endif
