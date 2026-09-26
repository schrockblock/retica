import Testing
import Foundation
@preconcurrency import CoreBluetooth
import ComposableArchitecture
@testable import ReTiCAInterfaces
@testable import FCBComposable

let serviceUUID = CBUUID(string: BLEProtocol.serviceUUID)
let txCharUUID = CBUUID(string: BLEProtocol.txCharUUID)
let rxCharUUID = CBUUID(string: BLEProtocol.rxCharUUID)
let identityCharUUID = CBUUID(string: BLEProtocol.identityCharUUID)
let adapterLocalIdentity = Data(repeating: 0x11, count: 16)
let adapterPeerIdentity = Data(repeating: 0xEE, count: 16)

/// Records the FCB commands the adapter invokes.
actor AdapterCalls {
    var addedServices: [MutableService] = []
    var advertised: [AdvertisementData?] = []
    var scanned = 0
    var stopScanned = 0
    var stoppedAdvertising = 0
    var removedAll = 0
    var connected: [UUID] = []
    var disconnected: [UUID] = []
    var discoveredServices: [UUID] = []
    var discoveredChars: [(UUID, CBUUID)] = []
    var readValues: [(UUID, CBUUID)] = []
    var setNotify: [(Bool, UUID, CBUUID)] = []
    var writes: [(Data, UUID, CBUUID, CBCharacteristicWriteType)] = []
    var responded: [(UUID, CBATTError.Code)] = []
    var updates: [(Data, CBUUID, [UUID]?)] = []

    func addService(_ s: MutableService) { addedServices.append(s) }
    func advertise(_ d: AdvertisementData?) { advertised.append(d) }
    func scan() { scanned += 1 }
    func stopScan() { stopScanned += 1 }
    func stopAdvertising() { stoppedAdvertising += 1 }
    func removeAll() { removedAll += 1 }
    func connect(_ id: UUID) { connected.append(id) }
    func disconnect(_ id: UUID) { disconnected.append(id) }
    func discoverServices(_ id: UUID) { discoveredServices.append(id) }
    func discoverChars(_ id: UUID, _ s: CBUUID) { discoveredChars.append((id, s)) }
    func read(_ id: UUID, _ c: CBUUID) { readValues.append((id, c)) }
    func notify(_ on: Bool, _ id: UUID, _ c: CBUUID) { setNotify.append((on, id, c)) }
    func write(_ d: Data, _ id: UUID, _ c: CBUUID, _ t: CBCharacteristicWriteType) { writes.append((d, id, c, t)) }
    func respond(_ id: UUID, _ code: CBATTError.Code) { responded.append((id, code)) }
    func update(_ d: Data, _ c: CBUUID, _ ids: [UUID]?) { updates.append((d, c, ids)) }
}

@MainActor
struct AdapterStubs {
    var central: BluetoothCentralClient
    var peripheral: BluetoothPeripheralClient
    let calls: AdapterCalls
    let centralState: AsyncStream<CBManagerState>.Continuation
    let peripheralState: AsyncStream<CBManagerState>.Continuation
    let scanCont: AsyncStream<DiscoveredPeripheral>.Continuation
    let centralEvents: AsyncStream<CentralEvent>.Continuation
    let writeRequests: AsyncStream<[WriteRequest]>.Continuation
    let subscriptions: AsyncStream<SubscriptionEvent>.Continuation
    let peripheralEvents: AsyncStream<PeripheralManagerEvent>.Continuation
    // Configurable behaviour.
    let identityResult: LockIsolated<Data?>            // nil → readValue throws
    let charsResult: LockIsolated<[CBUUID]>            // characteristics "discovered"
    let writeShouldThrow: LockIsolated<Bool>
    let mtu: LockIsolated<Int>
    let updateResult: LockIsolated<Bool>               // peripheral.updateValue return
    /// Notification continuations per peripheral id, minted when the adapter subscribes.
    let notifications: LockIsolated<[UUID: AsyncThrowingStream<Data, any Error>.Continuation]>
}

@MainActor
func makeStubs() -> AdapterStubs {
    let calls = AdapterCalls()
    let cState = AsyncStream<CBManagerState>.makeStream()
    let pState = AsyncStream<CBManagerState>.makeStream()
    let scan = AsyncStream<DiscoveredPeripheral>.makeStream()
    let cEvents = AsyncStream<CentralEvent>.makeStream()
    let writes = AsyncStream<[WriteRequest]>.makeStream()
    let subs = AsyncStream<SubscriptionEvent>.makeStream()
    let pEvents = AsyncStream<PeripheralManagerEvent>.makeStream()
    let identityResult = LockIsolated<Data?>(adapterPeerIdentity)
    let charsResult = LockIsolated<[CBUUID]>([txCharUUID, rxCharUUID, identityCharUUID])
    let writeShouldThrow = LockIsolated(false)
    let mtu = LockIsolated(512)
    let updateResult = LockIsolated(true)
    let notifications = LockIsolated<[UUID: AsyncThrowingStream<Data, any Error>.Continuation]>([:])

    let central = BluetoothCentralClient(
        state: { cState.stream },
        authorization: { .allowedAlways },
        scan: { _, _ in Task { await calls.scan() }; return scan.stream },
        stopScan: { await calls.stopScan() },
        connect: { id, _ in await calls.connect(id); return Peripheral(id: id, name: nil, state: .connected) },
        disconnect: { id in await calls.disconnect(id) },
        retrievePeripherals: { _ in [] },
        retrieveConnected: { _ in [] },
        discoverServices: { id, _ in await calls.discoverServices(id); return [Service(id: serviceUUID, peripheralID: id, isPrimary: true)] },
        discoverCharacteristics: { id, s, _ in
            await calls.discoverChars(id, s)
            return charsResult.value.map {
                Characteristic(id: $0, serviceID: serviceUUID, peripheralID: id, properties: .read, value: nil, isNotifying: false)
            }
        },
        readValue: { id, c in
            await calls.read(id, c)
            guard let r = identityResult.value else { throw BluetoothError.operationCancelled }
            return r
        },
        writeValue: { d, id, c, t in
            // A real suspension point wide enough that two concurrent drain loops actually
            // overlap here (a bare actor hop resolves too fast to force interleaving reliably).
            try? await Task.sleep(nanoseconds: 5_000_000)
            await calls.write(d, id, c, t)
            if writeShouldThrow.value { throw BluetoothError.disconnected(peripheralID: id, underlying: nil) }
        },
        setNotify: { on, id, c in await calls.notify(on, id, c) },
        maximumWriteValueLength: { _, _ in mtu.value },
        notifications: { id, _ in
            AsyncThrowingStream { cont in notifications.withValue { $0[id] = cont } }
        },
        openL2CAPChannel: { _, _ in throw BluetoothError.l2capNotSupported },
        events: { cEvents.stream }
    )

    let peripheral = BluetoothPeripheralClient(
        state: { pState.stream },
        authorization: { .allowedAlways },
        add: { s in await calls.addService(s); return Service(id: s.id, peripheralID: UUID(), isPrimary: true) },
        remove: { _ in },
        removeAll: { await calls.removeAll() },
        startAdvertising: { d in await calls.advertise(d) },
        stopAdvertising: { await calls.stopAdvertising() },
        isAdvertising: { true },
        respond: { id, code in await calls.respond(id, code) },
        updateValue: { d, c, ids in await calls.update(d, c, ids); return updateResult.value },
        publishL2CAPChannel: { _ in 0 },
        unpublishL2CAPChannel: { _ in },
        l2capConnections: { .finished },
        readRequests: { .finished },
        writeRequests: { writes.stream },
        subscriptions: { subs.stream },
        events: { pEvents.stream }
    )
    // NOTE: both initialisers are @DependencyClient memberwise inits — argument order MUST match
    // each client's property declaration order in FCBComposable.

    return AdapterStubs(
        central: central, peripheral: peripheral, calls: calls,
        centralState: cState.continuation, peripheralState: pState.continuation,
        scanCont: scan.continuation, centralEvents: cEvents.continuation,
        writeRequests: writes.continuation, subscriptions: subs.continuation,
        peripheralEvents: pEvents.continuation,
        identityResult: identityResult, charsResult: charsResult, writeShouldThrow: writeShouldThrow,
        mtu: mtu, updateResult: updateResult, notifications: notifications)
}

/// Collect up to `count` events (or until the stream ends) with a bounded wait.
func collect(_ stream: AsyncStream<BLEDriverEvent>, count: Int) async -> [BLEDriverEvent] {
    var out: [BLEDriverEvent] = []
    await withTaskGroup(of: [BLEDriverEvent].self) { group in
        group.addTask {
            var acc: [BLEDriverEvent] = []
            for await e in stream { acc.append(e); if acc.count >= count { break } }
            return acc
        }
        group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000); return [] }
        out = await group.next() ?? []
        group.cancelAll()
    }
    return out
}

func peer(_ b: UInt8) -> BLEPeerHandle { BLEPeerHandle(id: UUID(uuidString: "0000000\(b)-0000-0000-0000-000000000000")!) }

func disc(_ h: BLEPeerHandle) -> DiscoveredPeripheral {
    DiscoveredPeripheral(peripheral: Peripheral(id: h.id, name: nil, state: .disconnected),
                         advertisementData: AdvertisementData(serviceUUIDs: [serviceUUID]), rssi: -50)
}

@MainActor
func onlineAdapter() async -> (FCBDriverAdapter, AdapterStubs, AsyncStream<BLEDriverEvent>) {
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral)
    let events = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    stubs.peripheralState.yield(.poweredOn)
    stubs.centralState.yield(.poweredOn)
    _ = await collect(events, count: 1)   // .ready
    return (adapter, stubs, events)
}

/// Drives readIdentity + openChannel for `p`; returns the outbound channel id.
@MainActor
func openOutbound(_ adapter: FCBDriverAdapter, _ stubs: AdapterStubs, _ events: AsyncStream<BLEDriverEvent>,
                  _ p: BLEPeerHandle) async -> BLEChannelID? {
    await adapter.readIdentity(p)
    _ = await collect(events, count: 1)   // identityRead
    await adapter.openChannel(p)
    let opened = await collect(events, count: 1)
    guard case let .channelOpened(cid, _, _, _)? = opened.first else { Issue.record("no channelOpened: \(opened)"); return nil }
    return cid
}

// MARK: - Bring-up

@Test @MainActor func startupPublishesV22ServiceAdvertisesScansThenReady() async {
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral)
    let events = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    stubs.peripheralState.yield(.poweredOn)
    stubs.centralState.yield(.poweredOn)
    #expect(await collect(events, count: 1) == [.ready])
    let added = await stubs.calls.addedServices
    #expect(added.count == 1)
    let svc = added[0]
    #expect(svc.id == serviceUUID && svc.isPrimary)
    #expect(svc.characteristics.contains { $0.id == txCharUUID && $0.properties == [.read, .notify] && $0.value == nil })
    #expect(svc.characteristics.contains { $0.id == rxCharUUID && $0.properties == [.write, .writeWithoutResponse] && $0.permissions == .writeable })
    #expect(svc.characteristics.contains { $0.id == identityCharUUID && $0.properties == .read && $0.value == adapterLocalIdentity })
    #expect(await stubs.calls.advertised.first??.serviceUUIDs == [serviceUUID])
    #expect(await stubs.calls.scanned == 1)
    await adapter.stop()
}

@Test @MainActor func poweredOffEmitsUnavailableOnce() async {
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral)
    let events = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    stubs.centralState.yield(.poweredOff)
    stubs.peripheralState.yield(.poweredOff)
    #expect(await collect(events, count: 1) == [.unavailable(.poweredOff)])
    await adapter.stop()
}

@Test @MainActor func readyWaitsForAdvertisingNotJustScanning() async {
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral)
    let events = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    let recorded = LockIsolated<[BLEDriverEvent]>([])
    let drain = Task { for await e in events { recorded.withValue { $0.append(e) } } }
    stubs.centralState.yield(.poweredOn)
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(recorded.value == [])
    stubs.peripheralState.yield(.poweredOn)
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(recorded.value == [.ready])
    await adapter.stop()
    drain.cancel()
}

@Test @MainActor func adapterRetryStartWithoutStopFinishesPriorStream() async {
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral)
    let events1 = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    stubs.peripheralState.yield(.poweredOn)
    stubs.centralState.yield(.poweredOn)
    #expect(await collect(events1, count: 1) == [.ready])
    _ = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    #expect(await collect(events1, count: 1) == [])   // finished, not hung
    await adapter.stop()
}

// MARK: - Discovery

@Test @MainActor func discoveryDedupsWithinCooldownAndReOffersAfter() async {
    let now = LockIsolated(Date(timeIntervalSince1970: 1000))
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral, now: { now.value })
    let events = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    stubs.peripheralState.yield(.poweredOn)
    stubs.centralState.yield(.poweredOn)
    _ = await collect(events, count: 1)
    let p1 = peer(1), p2 = peer(7)
    stubs.scanCont.yield(disc(p1)); stubs.scanCont.yield(disc(p1)); stubs.scanCont.yield(disc(p2))
    #expect(await collect(events, count: 2) == [.peerDiscovered(p1), .peerDiscovered(p2)])
    now.withValue { $0 = $0.addingTimeInterval(FCBDriverAdapter.discoveryCooldown + 1) }
    stubs.scanCont.yield(disc(p1))
    #expect(await collect(events, count: 1) == [.peerDiscovered(p1)])
    await adapter.stop()
}

// MARK: - Central role

@Test @MainActor func readIdentityHappyPath() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(2)
    await adapter.readIdentity(p)
    #expect(await collect(events, count: 1) == [.identityRead(p, identity: adapterPeerIdentity)])
    #expect(await stubs.calls.connected == [p.id])
    #expect(await stubs.calls.discoveredChars.map(\.1) == [serviceUUID])
    #expect(await stubs.calls.readValues.map(\.1) == [identityCharUUID])
    await adapter.stop()
}

@Test @MainActor func missingIdentityCharacteristicFailsAndDisconnects() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(3)
    stubs.charsResult.setValue([txCharUUID, rxCharUUID])
    await adapter.readIdentity(p)
    let got = await collect(events, count: 1)
    guard case .identityFailed(p, _)? = got.first else { Issue.record("expected identityFailed, got \(got)"); await adapter.stop(); return }
    #expect(await stubs.calls.disconnected.contains(p.id))
    #expect(await stubs.calls.readValues.isEmpty)
    await adapter.stop()
}

@Test @MainActor func shortIdentityReadFails() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(4)
    stubs.identityResult.setValue(Data(repeating: 1, count: 8))
    await adapter.readIdentity(p)
    guard case .identityFailed(p, _)? = (await collect(events, count: 1)).first else { Issue.record("expected identityFailed"); await adapter.stop(); return }
    #expect(await stubs.calls.disconnected.contains(p.id))
    await adapter.stop()
}

@Test @MainActor func readThrowFailsForgetsAndDisconnects() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(5)
    stubs.identityResult.setValue(nil)
    await adapter.readIdentity(p)
    guard case .identityFailed(p, _)? = (await collect(events, count: 1)).first else { Issue.record("expected identityFailed"); await adapter.stop(); return }
    #expect(await stubs.calls.disconnected.contains(p.id))
    stubs.scanCont.yield(disc(p))
    #expect(await collect(events, count: 1) == [.peerDiscovered(p)])   // forgotten → re-offered
    await adapter.stop()
}

@Test @MainActor func openChannelSubscribesWritesHandshakeAndReportsMTU() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(6)
    stubs.mtu.setValue(185)
    await adapter.readIdentity(p)
    _ = await collect(events, count: 1)
    await adapter.openChannel(p)
    let opened = await collect(events, count: 1)
    guard case let .channelOpened(_, hp, dir, mtu)? = opened.first else { Issue.record("no channelOpened: \(opened)"); await adapter.stop(); return }
    #expect(hp == p && dir == .outbound && mtu == 185)
    let notify = await stubs.calls.setNotify
    #expect(notify.count == 1)
    #expect(notify[0].0 == true)
    #expect(notify[0].2 == txCharUUID)
    let writes = await stubs.calls.writes
    #expect(writes.count == 1)
    #expect(writes[0].0 == adapterLocalIdentity)
    #expect(writes[0].2 == rxCharUUID)
    #expect(writes[0].3 == .withResponse)
    await adapter.stop()
}

@Test @MainActor func handshakeWriteFailureEmitsChannelFailedAndForgets() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(7)
    stubs.writeShouldThrow.setValue(true)
    await adapter.readIdentity(p)
    _ = await collect(events, count: 1)
    await adapter.openChannel(p)
    guard case .channelFailed(p, _)? = (await collect(events, count: 1)).first else { Issue.record("expected channelFailed"); await adapter.stop(); return }
    #expect(await stubs.calls.disconnected.contains(p.id))
    await adapter.stop()
}

@Test @MainActor func notificationsSurfaceAsChannelDataAndStreamEndCloses() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(8)
    guard let cid = await openOutbound(adapter, stubs, events, p) else { await adapter.stop(); return }
    let cont = stubs.notifications.value[p.id]
    cont?.yield(Data([0xAB, 0xCD]))
    #expect(await collect(events, count: 1) == [.channelData(cid, Data([0xAB, 0xCD]))])
    cont?.finish()
    guard case .channelClosed(cid, _)? = (await collect(events, count: 1)).first else { Issue.record("expected channelClosed"); await adapter.stop(); return }
    await adapter.stop()
}

@Test @MainActor func sendOnOutboundChannelWritesWithoutResponse() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(9)
    guard let cid = await openOutbound(adapter, stubs, events, p) else { await adapter.stop(); return }
    await adapter.send(cid, fragments: [Data([1, 2, 3]), Data([4])])
    let writes = await stubs.calls.writes
    #expect(writes.suffix(2).map(\.0) == [Data([1, 2, 3]), Data([4])])
    #expect(writes.last?.2 == rxCharUUID)
    #expect(writes.last?.3 == .withoutResponse)
    await adapter.stop()
}

@Test @MainActor func sendFailureClosesOutboundChannel() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(1)
    guard let cid = await openOutbound(adapter, stubs, events, p) else { await adapter.stop(); return }
    stubs.writeShouldThrow.setValue(true)
    await adapter.send(cid, fragments: [Data([1])])
    guard case .channelClosed(cid, _)? = (await collect(events, count: 1)).first else { Issue.record("expected channelClosed"); await adapter.stop(); return }
    await adapter.stop()
}

@Test @MainActor func closeChannelDisconnectsSilently() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(2)
    guard let cid = await openOutbound(adapter, stubs, events, p) else { await adapter.stop(); return }
    await adapter.closeChannel(cid)
    #expect(await stubs.calls.disconnected.contains(p.id))
    stubs.notifications.value[p.id]?.finish()
    await adapter.stop()
    let tail = await collect(events, count: 5)
    #expect(!tail.contains { if case .channelClosed(cid, _) = $0 { return true }; return false })
}

@Test @MainActor func centralDisconnectEventClosesOutboundChannelAndForgets() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(3)
    guard let cid = await openOutbound(adapter, stubs, events, p) else { await adapter.stop(); return }
    stubs.centralEvents.yield(.didDisconnect(Peripheral(id: p.id, name: nil, state: .disconnected), nil))
    guard case .channelClosed(cid, _)? = (await collect(events, count: 1)).first else { Issue.record("expected channelClosed"); await adapter.stop(); return }
    stubs.scanCont.yield(disc(p))
    #expect(await collect(events, count: 1) == [.peerDiscovered(p)])
    await adapter.stop()
}

@Test @MainActor func disconnectVerbDropsTheGattConnection() async {
    let (adapter, stubs, _) = await onlineAdapter()
    await adapter.disconnect(peer(4))
    #expect(await stubs.calls.disconnected.contains(peer(4).id))
    await adapter.stop()
}

@Test @MainActor func sendToUnknownChannelIsDropped() async {
    let (adapter, _, _) = await onlineAdapter()
    await adapter.send(BLEChannelID(id: UUID()), fragments: [Data([1])])
    await adapter.stop()
}

@Test @MainActor func sendKeepsFragmentOrderAcrossConcurrentCalls() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(9)
    guard let cid = await openOutbound(adapter, stubs, events, p) else { await adapter.stop(); return }
    let before = await stubs.calls.writes.count
    async let a: Void = adapter.send(cid, fragments: [Data([1]), Data([2]), Data([3])])
    async let b: Void = adapter.send(cid, fragments: [Data([9]), Data([8])])
    _ = await (a, b)
    let writes = await stubs.calls.writes
    // Compare the exact tail added by these two calls (not just the last 5) so a reentrant
    // drain that duplicates or drops a fragment is caught rather than trimmed away.
    let payload = writes[before...].map(\.0)
    #expect(payload.count == 5)
    #expect(payload == [Data([1]), Data([2]), Data([3]), Data([9]), Data([8])]
            || payload == [Data([9]), Data([8]), Data([1]), Data([2]), Data([3])])
    await adapter.stop()
}
