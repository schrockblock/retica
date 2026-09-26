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
    /// The session ended (stop()/restart) while an operation was in flight; the operation aborts
    /// silently instead of reporting a false failure.
    case sessionEnded
    /// The peer disconnected while `openChannel` was mid-handshake; the link is already down, so
    /// no further disconnect is issued, but this is reported as a real failure (not silent).
    case peerDisconnected
    var description: String {
        switch self {
        case let .missingCharacteristic(name): return "peer lacks \(name) characteristic"
        case let .shortIdentity(n): return "identity read returned \(n) bytes"
        case .sessionEnded: return "session ended"
        case .peerDisconnected: return "peer disconnected during open"
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
    // Channels currently mid-openChannel (registered in `opening` before the maps exist) and any
    // notification chunks that arrive for them before they're fully registered.
    private var opening: Set<BLEChannelID> = []
    private var earlyChunks: [BLEChannelID: [Data]] = [:]
    // Per-channel send FIFOs (both roles) and the set of channels a drain loop is emptying.
    static let sendQueueCap = 256
    private var sendQueues: [BLEChannelID: [Data]] = [:]
    private var draining: Set<BLEChannelID> = []
    // Central role backpressure: peripheral ids whose write-without-response queue is full
    // (parked until isReadyToSendWriteWithoutResponse), and a per-peer count of those ready
    // events so a check that sees one land while in flight re-checks instead of parking.
    private var writeParked: Set<UUID> = []
    private var writeReadyGeneration: [UUID: Int] = [:]
    // Peripheral role: inbound channels (one per subscribed central). Their send FIFOs are the
    // shared `sendQueues` above.
    static let heldWriteWindow: TimeInterval = 2
    private var inbound: [BLEChannelID: Central] = [:]
    private var inboundByCentral: [UUID: BLEChannelID] = [:]
    private var notifyParked = false
    // Bumped by every isReadyToUpdateSubscribers. A notify attempt that sees it change while in
    // flight retries instead of parking: the ready that would have unparked it is already consumed.
    private var readyGeneration = 0
    private var heldWrites: [UUID: (data: Data, at: Date)] = [:]

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
        // resetSession bumps the epoch first; any other bump while it is suspended means a stop()
        // (or a newer start) arrived mid-begin, and this session must never come up.
        let myEpoch = epoch + 1
        await resetSession()
        guard epoch == myEpoch else { continuation.finish(); return }
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
        // Every step re-checks the epoch: a stop()/restart while this is suspended must not
        // publish, advertise or announce anything for the session that just ended.
        let myEpoch = epoch
        // A repeat poweredOn (Bluetooth toggled off→on) must not publish a second copy of the
        // service or hit alreadyAdvertising: tear down whatever an earlier bring-up left behind.
        await peripheral.stopAdvertising()
        guard epoch == myEpoch else { return }
        await peripheral.removeAll()
        guard epoch == myEpoch else { return }
        do {
            _ = try await peripheral.add(bleV22Service(localIdentity: config.localIdentity))
            guard epoch == myEpoch else { return }
            try await peripheral.startAdvertising(AdvertisementData(serviceUUIDs: [bleV22ServiceUUID]))
            guard epoch == myEpoch else { return }
            advertising = true
            checkReady()
        } catch {
            guard epoch == myEpoch else { return }
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
        for p in pumps.values { p.cancel() }
        pumps = [:]
        // Snapshot and clear BEFORE any await: a cancelled pump's trailing outboundDidClose call
        // must find its channel already gone (a no-op), not race a second concurrent disconnect
        // for the same peer against the one this loop is about to issue.
        let peers = Array(outbound.values)
        outbound = [:]
        outboundByPeer = [:]
        sendQueues = [:]
        draining = []
        writeParked = []
        writeReadyGeneration = [:]
        pendingOpens = []
        abortedOpens = []
        opening = []
        earlyChunks = [:]
        advertising = false
        scanning = false
        resetPeripheralSession()
        for peerID in peers { try? await central.disconnect(peerID) }
        // A restart without stop() (the reducer's adapter retry) must leave the managers clean
        // for the next bring-up: no scan, no advertisement, no published service.
        await central.stopScan()
        await peripheral.stopAdvertising()
        await peripheral.removeAll()
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
        switch event {
        case let .didDisconnect(p, _):
            forget(p.id)
            // A park belongs to the link that just dropped; a reconnect starts with an empty queue.
            writeParked.remove(p.id)
            writeReadyGeneration[p.id] = nil
            if pendingOpens.contains(p.id) { abortedOpens.insert(p.id) }
            // The link is already down — no redundant disconnect (would await on the only event loop).
            if let cid = outboundByPeer[p.id] { await outboundDidClose(cid, reason: "disconnected", disconnect: false) }
        case let .isReadyToSendWriteWithoutResponse(p):
            writeReadyGeneration[p.id, default: 0] += 1
            writeParked.remove(p.id)
            if let channel = outboundByPeer[p.id], sendQueues[channel] != nil { await drain(channel) }
        default:
            break
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
        // Registered before the maps exist, so a notification racing ahead of registration is
        // buffered (see emitChannelData) instead of dropped.
        opening.insert(channelID)
        defer { opening.remove(channelID) }
        // Create the notification stream BEFORE enabling notifications so nothing is missed.
        let stream = central.notifications(peer.id, bleV22TXCharUUID)
        let pump = Task { [stream] in
            do { for try await chunk in stream { self.emitChannelData(channelID, chunk) } } catch {}
            await self.outboundDidClose(channelID, reason: "notifications ended", disconnect: true)
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
            guard epoch == myEpoch else { throw FCBAdapterError.sessionEnded }
            guard !abortedOpens.contains(peer.id) else { throw FCBAdapterError.peerDisconnected }
            // No suspension from here to the yield: the maps are live before any event can race them.
            outbound[channelID] = peer.id
            outboundByPeer[peer.id] = channelID
            pumps[channelID] = pump
            continuation?.yield(.channelOpened(channelID, peer, direction: .outbound, mtu: mtu))
            for chunk in earlyChunks.removeValue(forKey: channelID) ?? [] {
                continuation?.yield(.channelData(channelID, chunk))
            }
        } catch {
            pump.cancel()
            // A peer disconnect during the window already dropped the GATT link — no redundant
            // disconnect (would await on the only central event loop).
            let wasAbortedByDisconnect = abortedOpens.contains(peer.id)
            abortedOpens.remove(peer.id)
            forget(peer.id)
            earlyChunks[channelID] = nil
            if !wasAbortedByDisconnect { try? await central.disconnect(peer.id) }
            if epoch == myEpoch { continuation?.yield(.channelFailed(peer, reason: "\(error)")) }
        }
    }

    private func emitChannelData(_ id: BLEChannelID, _ data: Data) {
        if outbound[id] != nil || isInbound(id) {
            continuation?.yield(.channelData(id, data))
        } else if opening.contains(id) {
            // Arrived before openChannel finished registering the channel: hold it, openChannel
            // flushes this buffer right after yielding .channelOpened.
            earlyChunks[id, default: []].append(data)
        }
    }

    /// Every adapter-initiated outbound close drops the GATT link too (spec §3.4) — UNLESS the
    /// caller already knows it's down (`disconnect: false`), in which case awaiting a redundant
    /// disconnect could wedge the only event loop for no benefit.
    private func outboundDidClose(_ id: BLEChannelID, reason: String?, disconnect: Bool) async {
        guard let peerID = outbound.removeValue(forKey: id) else { return }
        outboundByPeer[peerID] = nil
        sendQueues[id] = nil
        pumps.removeValue(forKey: id)?.cancel()
        continuation?.yield(.channelClosed(id, reason: reason))
        if disconnect { try? await central.disconnect(peerID) }
    }

    // MARK: - BLEDriver verbs

    /// One packet's fragments (or one keepalive): appended atomically to the channel's FIFO and
    /// drained by a single per-channel loop, so fragments of different packets never interleave.
    func send(_ channel: BLEChannelID, fragments: [Data]) async {
        guard outbound[channel] != nil || isInbound(channel) else { return }
        sendQueues[channel, default: []].append(contentsOf: fragments)
        if sendQueues[channel]!.count > Self.sendQueueCap {
            if outbound[channel] != nil { await outboundDidClose(channel, reason: "send backlog", disconnect: true) }
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
                guard await writeOutbound(channel, peerID, next) else { return }   // parked or closed
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

    /// One write-without-response attempt for the drain loop (mirrors `notifyInbound`). true =
    /// written, dequeue it; false = leave it queued (the peripheral's queue is full → parked until
    /// isReadyToSendWriteWithoutResponse) or the channel closed.
    private func writeOutbound(_ channel: BLEChannelID, _ peerID: UUID, _ fragment: Data) async -> Bool {
        while true {
            guard !writeParked.contains(peerID), outbound[channel] != nil else { return false }
            let generation = writeReadyGeneration[peerID, default: 0]
            let myEpoch = epoch
            let canSend = await central.canSendWriteWithoutResponse(peerID)
            // Before either branch touches state: the session and THIS channel must still be live.
            // FCB forgets a peripheral before emitting .didDisconnect, so a check in flight across
            // a disconnect answers `false` — parking on it would outlive the .didDisconnect clear
            // and mute the next link to the same (stable) peripheral id. A stale `true` must not
            // write an old channel's fragment onto a new link either.
            guard epoch == myEpoch, outbound[channel] == peerID else { return false }
            guard canSend else {
                // A ready event landed while this check was in flight: it was meant for us, re-check now.
                if generation != writeReadyGeneration[peerID, default: 0] { continue }
                writeParked.insert(peerID)
                return false
            }
            do {
                try await central.writeValue(fragment, peerID, bleV22RXCharUUID, .withoutResponse)
                guard epoch == myEpoch, outbound[channel] == peerID else { return false }
                return true
            } catch {
                await outboundDidClose(channel, reason: "write failed: \(error)", disconnect: true)
                return false
            }
        }
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

    // TODO(Task 4): replace with a real L2CAP CoC open + handshake write.
    func openL2CAPChannel(_ peer: BLEPeerHandle, psm: UInt16) async {
        continuation?.yield(.channelFailed(peer, reason: "L2CAP not implemented yet"))
    }

    func stop() async {
        await resetSession()   // also stops scanning/advertising and removes the service
    }

    // MARK: - Peripheral role

    private func subscribePeripheralStreams() {
        tasks.append(Task { [peripheral] in
            for await event in peripheral.subscriptions() { self.handleSubscription(event) }
        })
        tasks.append(Task { [peripheral] in
            for await batch in peripheral.writeRequests() { await self.handleWrites(batch) }
        })
        tasks.append(Task { [peripheral] in
            for await request in peripheral.readRequests() { await peripheral.respond(request.id, .success) }
        })
        tasks.append(Task { [peripheral] in
            for await event in peripheral.events() {
                if case .isReadyToUpdateSubscribers = event { await self.notifyReady() }
            }
        })
    }

    private func resetPeripheralSession() {
        inbound = [:]
        inboundByCentral = [:]
        notifyParked = false
        readyGeneration = 0
        heldWrites = [:]
    }

    private func isInbound(_ id: BLEChannelID) -> Bool { inbound[id] != nil }

    private func handleSubscription(_ event: SubscriptionEvent) {
        switch event {
        case let .subscribed(central, characteristic):
            guard characteristic.id == bleV22TXCharUUID else { return }
            if let old = inboundByCentral[central.id] { inboundDidClose(old, reason: "resubscribed") }
            let channelID = BLEChannelID(id: UUID())
            inbound[channelID] = central
            inboundByCentral[central.id] = channelID
            continuation?.yield(.channelOpened(channelID, BLEPeerHandle(id: central.id), direction: .inbound,
                                               mtu: central.maximumUpdateValueLength))
            if let held = heldWrites.removeValue(forKey: central.id),
               now().timeIntervalSince(held.at) <= Self.heldWriteWindow {
                continuation?.yield(.channelData(channelID, held.data))
            }
        case let .unsubscribed(central, characteristic):
            guard characteristic.id == bleV22TXCharUUID, let cid = inboundByCentral[central.id] else { return }
            inboundDidClose(cid, reason: "unsubscribed")
        }
    }

    private func handleWrites(_ batch: [WriteRequest]) async {
        // CoreBluetooth wants ONE respond per batch (the first request); a without-response
        // write's respond is a harmless no-op.
        let myEpoch = epoch
        if let first = batch.first { await peripheral.respond(first.id, .success) }
        guard epoch == myEpoch else { return }   // session ended mid-respond: drop, don't leak into the next
        for request in batch where request.characteristic.id == bleV22RXCharUUID {
            guard let value = request.value else { continue }
            if let cid = inboundByCentral[request.central.id] {
                continuation?.yield(.channelData(cid, Data(value)))
            } else {
                let t = now()
                heldWrites = heldWrites.filter { t.timeIntervalSince($0.value.at) <= Self.heldWriteWindow }
                heldWrites[request.central.id] = (Data(value), t)
            }
        }
    }

    /// One notify attempt for the drain loop. true = sent, dequeue it; false = leave it queued
    /// (CoreBluetooth's queue is full → parked until isReadyToUpdateSubscribers) or the channel closed.
    private func notifyInbound(_ channel: BLEChannelID, _ fragment: Data) async -> Bool {
        while true {
            guard !notifyParked, let central = inbound[channel] else { return false }
            let generation = readyGeneration
            let myEpoch = epoch
            do {
                let ok = try await peripheral.updateValue(fragment, bleV22TXCharUUID, [central.id])
                guard epoch == myEpoch else { return false }   // a session reset mid-notify must not touch the next session
                if ok { return true }
                // A ready event landed while this attempt was in flight: it was meant for us, retry now.
                if generation != readyGeneration { continue }
                notifyParked = true
                return false
            } catch {
                inboundDidClose(channel, reason: "notify failed: \(error)")
                return false
            }
        }
    }

    private func notifyReady() async {
        readyGeneration += 1
        notifyParked = false
        for channel in inbound.keys.sorted(by: { $0.id.uuidString < $1.id.uuidString }) where sendQueues[channel] != nil {
            await drain(channel)
        }
    }

    private func closeInbound(_ channel: BLEChannelID) {
        guard let central = inbound.removeValue(forKey: channel) else { return }
        inboundByCentral[central.id] = nil
        sendQueues[channel] = nil
    }

    private func inboundDidClose(_ channel: BLEChannelID, reason: String?) {
        guard let central = inbound.removeValue(forKey: channel) else { return }
        inboundByCentral[central.id] = nil
        sendQueues[channel] = nil
        // A reducer-initiated close removed the mapping in `closeInbound`, so it never reaches here.
        continuation?.yield(.channelClosed(channel, reason: reason))
    }
}

extension BLEDriver {
    /// Composes FCB's clients into the BLEDriver contract.
    public static func fcb(central: BluetoothCentralClient, peripheral: BluetoothPeripheralClient) -> BLEDriver {
        let adapter = FCBDriverAdapter(central: central, peripheral: peripheral)
        return BLEDriver(
            start: { config in adapter.start(config) },
            readIdentity: { peer in await adapter.readIdentity(peer) },
            openChannel: { peer in await adapter.openChannel(peer) },
            openL2CAPChannel: { peer, psm in await adapter.openL2CAPChannel(peer, psm: psm) },
            send: { channel, fragments in await adapter.send(channel, fragments: fragments) },
            closeChannel: { channel in await adapter.closeChannel(channel) },
            disconnect: { peer in await adapter.disconnect(peer) },
            stop: { await adapter.stop() }
        )
    }
}
