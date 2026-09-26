import Foundation
@preconcurrency import CoreBluetooth
import ComposableArchitecture
import FCBComposable

let bleV22ServiceUUID = CBUUID(string: BLEProtocol.serviceUUID)
let bleV22TXCharUUID = CBUUID(string: BLEProtocol.txCharUUID)
let bleV22RXCharUUID = CBUUID(string: BLEProtocol.rxCharUUID)
let bleV22IdentityCharUUID = CBUUID(string: BLEProtocol.identityCharUUID)

/// The ble-reticulum v2.2 GATT service: TX (read+notify), RX (write+WWR), Identity (read, static).
func bleV22Service(localIdentity: Data) -> MutableService {
    MutableService(id: bleV22ServiceUUID, isPrimary: true, characteristics: [
        MutableCharacteristic(id: bleV22TXCharUUID, properties: [.read, .notify], permissions: .readable, value: nil),
        MutableCharacteristic(id: bleV22RXCharUUID, properties: [.write, .writeWithoutResponse], permissions: .writeable, value: nil),
        MutableCharacteristic(id: bleV22IdentityCharUUID, properties: .read, permissions: .readable, value: localIdentity),
    ])
}

enum FCBAdapterError: Error, CustomStringConvertible {
    case missingCharacteristic(String)
    case shortIdentity(Int)
    /// The session ended (stop()/restart, or the peer disconnected) while an operation was
    /// in flight; the operation aborts silently instead of reporting a false failure.
    case sessionEnded
    var description: String {
        switch self {
        case let .missingCharacteristic(name): return "peer lacks \(name) characteristic"
        case let .shortIdentity(n): return "identity read returned \(n) bytes"
        case .sessionEnded: return "session ended"
        }
    }
}

/// Mechanism-only adapter mapping FCB's two clients onto the BLEDriver contract.
/// No policy, no retries, no fragmentation — the BLEInterface reducer owns all of that.
actor FCBDriverAdapter {
    private let central: BluetoothCentralClient
    private let peripheral: BluetoothPeripheralClient
    private let now: @Sendable () -> Date

    /// Re-offer a seen peer after this long (discovery is a heartbeat the reducer re-evaluates).
    static let discoveryCooldown: TimeInterval = 5

    private var continuation: AsyncStream<BLEDriverEvent>.Continuation?
    private var config = BLEDriverConfig(localIdentity: Data(repeating: 0, count: BLEProtocol.identityLength))
    private var tasks: [Task<Void, Never>] = []

    /// Bumped at the start of every resetSession (stop()/restart). Operations capture it on entry
    /// and check it after every suspension point; a mismatch means "this session is gone" and the
    /// operation aborts silently (no event into whatever session is now live).
    private var epoch = 0

    private var advertising = false
    private var scanning = false
    private var announcedReady = false
    private var announcedUnavailable = false

    private var seenPeers: [UUID: Date] = [:]
    // Central role: outbound channels.
    private var outbound: [BLEChannelID: UUID] = [:]      // channel → peripheral id
    private var outboundByPeer: [UUID: BLEChannelID] = [:]
    // Notification pumps, one per open outbound channel, so closes can cancel them.
    private var pumps: [BLEChannelID: Task<Void, Never>] = [:]
    // openChannel bookkeeping: peers mid-handshake, and ones that disconnected during that window.
    private var pendingOpens: Set<UUID> = []
    private var abortedOpens: Set<UUID> = []
    // Per-channel send FIFOs (both roles) and the set of channels a drain loop is emptying.
    static let sendQueueCap = 256
    private var sendQueues: [BLEChannelID: [Data]] = [:]
    private var draining: Set<BLEChannelID> = []

    init(central: BluetoothCentralClient, peripheral: BluetoothPeripheralClient,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.central = central
        self.peripheral = peripheral
        self.now = now
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
        announcedReady = false
        announcedUnavailable = false
        seenPeers = [:]
        tasks.append(Task { [peripheral] in
            for await state in peripheral.state() { await self.handlePeripheralState(state) }
        })
        tasks.append(Task { [central] in
            for await state in central.state() { await self.handleCentralState(state) }
        })
        subscribeCentralEvents()
        subscribePeripheralStreams()
    }

    // MARK: - Bring-up

    private func handlePeripheralState(_ state: CBManagerState) async {
        switch state {
        case .poweredOn: await bringUpPeripheral()
        case .poweredOff, .unauthorized, .unsupported: fireUnavailable(Self.cause(state))
        default: break
        }
    }

    private func handleCentralState(_ state: CBManagerState) async {
        switch state {
        case .poweredOn: bringUpCentral()
        case .poweredOff, .unauthorized, .unsupported: fireUnavailable(Self.cause(state))
        default: break
        }
    }

    private func bringUpPeripheral() async {
        do {
            _ = try await peripheral.add(bleV22Service(localIdentity: config.localIdentity))
            try await peripheral.startAdvertising(AdvertisementData(serviceUUIDs: [bleV22ServiceUUID]))
            advertising = true
            checkReady()
        } catch {
            fireUnavailable(.other("peripheral setup failed: \(error)"))
        }
    }

    private func bringUpCentral() {
        tasks.append(Task { [central] in
            for await discovered in central.scan([bleV22ServiceUUID], ScanOptions(allowDuplicates: true)) {
                self.handleDiscovered(discovered)
            }
        })
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

    static func cause(_ s: CBManagerState) -> BLEAdapterUnavailable {
        switch s {
        case .poweredOff:   return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported:  return .unsupported
        default:            return .other(nil)
        }
    }

    private func resetSession() async {
        epoch += 1   // first: invalidate any operation still in flight from the outgoing session
        for t in tasks { t.cancel() }
        tasks = []
        for pump in pumps.values { pump.cancel() }
        pumps = [:]
        advertising = false
        scanning = false
        for peerID in outbound.values { try? await central.disconnect(peerID) }
        outbound = [:]
        outboundByPeer = [:]
        sendQueues = [:]
        draining = []
        resetPeripheralSession()
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Discovery

    private func subscribeCentralEvents() {
        tasks.append(Task { [central] in
            for await event in central.events() { await self.handleCentralEvent(event) }
        })
    }

    private func handleCentralEvent(_ event: CentralEvent) async {
        if case let .didDisconnect(p, _) = event {
            forget(p.id)
            if pendingOpens.contains(p.id) { abortedOpens.insert(p.id) }
            if let cid = outboundByPeer[p.id] { await outboundDidClose(cid, reason: "disconnected") }
        }
    }

    private func handleDiscovered(_ discovered: DiscoveredPeripheral) {
        let id = discovered.peripheral.id
        let t = now()
        if let last = seenPeers[id], t.timeIntervalSince(last) < Self.discoveryCooldown { return }
        seenPeers[id] = t
        continuation?.yield(.peerDiscovered(BLEPeerHandle(id: id)))
    }

    private func forget(_ id: UUID) { seenPeers[id] = nil }

    // MARK: - Central role

    func readIdentity(_ peer: BLEPeerHandle) async {
        let myEpoch = epoch
        do {
            _ = try await central.connect(peer.id, nil)
            guard epoch == myEpoch else { try? await central.disconnect(peer.id); return }
            _ = try await central.discoverServices(peer.id, [bleV22ServiceUUID])
            guard epoch == myEpoch else { try? await central.disconnect(peer.id); return }
            let chars = try await central.discoverCharacteristics(
                peer.id, bleV22ServiceUUID, [bleV22TXCharUUID, bleV22RXCharUUID, bleV22IdentityCharUUID])
            guard epoch == myEpoch else { try? await central.disconnect(peer.id); return }
            guard chars.contains(where: { $0.id == bleV22IdentityCharUUID }) else {
                throw FCBAdapterError.missingCharacteristic("Identity")
            }
            let identity = try await central.readValue(peer.id, bleV22IdentityCharUUID)
            guard epoch == myEpoch else { try? await central.disconnect(peer.id); return }
            guard identity.count == BLEProtocol.identityLength else { throw FCBAdapterError.shortIdentity(identity.count) }
            continuation?.yield(.identityRead(peer, identity: Data(identity)))
        } catch {
            forget(peer.id)
            try? await central.disconnect(peer.id)
            if epoch == myEpoch { continuation?.yield(.identityFailed(peer, reason: "\(error)")) }
        }
    }

    func openChannel(_ peer: BLEPeerHandle) async {
        let myEpoch = epoch
        let channelID = BLEChannelID(id: UUID())
        // Create the notification stream BEFORE enabling notifications so nothing is missed.
        let stream = central.notifications(peer.id, bleV22TXCharUUID)
        let pump = Task { [stream] in
            do { for try await chunk in stream { self.emitChannelData(channelID, chunk) } } catch {}
            await self.outboundDidClose(channelID, reason: "notifications ended")
        }
        pendingOpens.insert(peer.id)
        abortedOpens.remove(peer.id)
        defer { pendingOpens.remove(peer.id) }
        do {
            try await central.setNotify(true, peer.id, bleV22TXCharUUID)
            guard epoch == myEpoch else { throw FCBAdapterError.sessionEnded }
            // MTU first: the handshake write is the last suspension before we register the
            // channel, so nothing can race the maps once it returns.
            let mtu = await central.maximumWriteValueLength(peer.id, .withoutResponse)
            guard epoch == myEpoch else { throw FCBAdapterError.sessionEnded }
            try await central.writeValue(config.localIdentity, peer.id, bleV22RXCharUUID, .withResponse)
            guard epoch == myEpoch, !abortedOpens.contains(peer.id) else { throw FCBAdapterError.sessionEnded }
            // No suspension from here to the yield: the maps are live before any event can race them.
            outbound[channelID] = peer.id
            outboundByPeer[peer.id] = channelID
            pumps[channelID] = pump
            continuation?.yield(.channelOpened(channelID, peer, direction: .outbound, mtu: mtu))
        } catch {
            pump.cancel()
            abortedOpens.remove(peer.id)
            forget(peer.id)
            try? await central.disconnect(peer.id)
            if epoch == myEpoch { continuation?.yield(.channelFailed(peer, reason: "\(error)")) }
        }
    }

    private func emitChannelData(_ id: BLEChannelID, _ data: Data) {
        guard outbound[id] != nil || isInbound(id) else { return }
        continuation?.yield(.channelData(id, data))
    }

    /// Every adapter-initiated outbound close drops the GATT link too (spec §3.4): a redundant
    /// disconnect on an already-dropped link is harmless.
    private func outboundDidClose(_ id: BLEChannelID, reason: String?) async {
        guard let peerID = outbound.removeValue(forKey: id) else { return }
        outboundByPeer[peerID] = nil
        sendQueues[id] = nil
        pumps.removeValue(forKey: id)?.cancel()
        continuation?.yield(.channelClosed(id, reason: reason))
        try? await central.disconnect(peerID)
    }

    // MARK: - BLEDriver verbs

    /// One packet's fragments (or one keepalive): appended atomically to the channel's FIFO and
    /// drained by a single per-channel loop, so fragments of different packets never interleave.
    func send(_ channel: BLEChannelID, fragments: [Data]) async {
        guard outbound[channel] != nil || isInbound(channel) else { return }
        sendQueues[channel, default: []].append(contentsOf: fragments)
        if sendQueues[channel]!.count > Self.sendQueueCap {
            if outbound[channel] != nil { await outboundDidClose(channel, reason: "send backlog") }
            else { inboundDidClose(channel, reason: "notify backlog") }
            return
        }
        await drain(channel)
    }

    /// Empties one channel's FIFO in order. Re-entrant calls return at once: the loop that is
    /// already running will pick up anything appended meanwhile.
    private func drain(_ channel: BLEChannelID) async {
        guard !draining.contains(channel) else { return }
        draining.insert(channel)
        defer { draining.remove(channel) }
        while let next = sendQueues[channel]?.first {
            if let peerID = outbound[channel] {
                do { try await central.writeValue(next, peerID, bleV22RXCharUUID, .withoutResponse) }
                catch { await outboundDidClose(channel, reason: "write failed: \(error)"); return }
            } else if isInbound(channel) {
                guard await notifyInbound(channel, next) else { return }   // parked or closed
            } else {
                sendQueues[channel] = nil
                return
            }
            sendQueues[channel]?.removeFirst()
        }
        sendQueues[channel] = nil
    }

    func closeChannel(_ channel: BLEChannelID) async {
        if let peerID = outbound[channel] {
            pumps.removeValue(forKey: channel)?.cancel()
            outbound[channel] = nil
            outboundByPeer[peerID] = nil
            sendQueues[channel] = nil
            try? await central.disconnect(peerID)
            return
        }
        closeInbound(channel)
    }

    func disconnect(_ peer: BLEPeerHandle) async {
        try? await central.disconnect(peer.id)
    }

    func stop() async {
        await resetSession()
        await central.stopScan()
        await peripheral.stopAdvertising()
        await peripheral.removeAll()
    }

    // MARK: - Peripheral role (Task 7 fills these in)

    private func subscribePeripheralStreams() {}
    private func resetPeripheralSession() {}
    private func isInbound(_ id: BLEChannelID) -> Bool { false }
    /// One notify attempt for the drain loop: true = sent, dequeue; false = leave queued (parked or closed).
    private func notifyInbound(_ channel: BLEChannelID, _ fragment: Data) async -> Bool { false }
    private func inboundDidClose(_ channel: BLEChannelID, reason: String?) {}
    private func closeInbound(_ channel: BLEChannelID) {}
}

extension BLEDriver {
    /// Composes FCB's clients into the BLEDriver contract.
    public static func fcb(central: BluetoothCentralClient, peripheral: BluetoothPeripheralClient) -> BLEDriver {
        let adapter = FCBDriverAdapter(central: central, peripheral: peripheral)
        return BLEDriver(
            start: { config in adapter.start(config) },
            readIdentity: { peer in await adapter.readIdentity(peer) },
            openChannel: { peer in await adapter.openChannel(peer) },
            send: { channel, fragments in await adapter.send(channel, fragments: fragments) },
            closeChannel: { channel in await adapter.closeChannel(channel) },
            disconnect: { peer in await adapter.disconnect(peer) },
            stop: { await adapter.stop() }
        )
    }
}
