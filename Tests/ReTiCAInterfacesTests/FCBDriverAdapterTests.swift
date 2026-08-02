import Testing
import Foundation
@preconcurrency import CoreBluetooth
import ComposableArchitecture
@testable import ReTiCAInterfaces
@testable import FCBComposable

let serviceUUID = CBUUID(string: "99872ed7-eba8-4c07-bf35-ab464a957f80")
let versionCharUUID = CBUUID(string: "50870e44-2fd6-4cbc-9f1f-11a0fcf85265")
let psmCharUUID = CBUUID(string: "1cfe213f-4ea4-48f9-9344-dde18cc729ef")

/// Records the FCB commands the adapter invokes, so tests can assert the mechanism.
actor AdapterCalls {
    var addedServices: [MutableService] = []
    var advertised: [AdvertisementData?] = []
    var publishedEncryption: [Bool] = []
    var scanned = 0
    var stopScanned = 0
    var stoppedAdvertising = 0
    var removedAll = 0
    var connected: [UUID] = []
    var discoveredServices: [UUID] = []
    var discoveredChars: [(UUID, CBUUID)] = []
    var readValues: [(UUID, CBUUID)] = []
    var openedL2CAP: [(UUID, UInt16)] = []
    var unpublished: [UInt16] = []

    func addService(_ s: MutableService) { addedServices.append(s) }
    func advertise(_ d: AdvertisementData?) { advertised.append(d) }
    func publish(_ e: Bool) { publishedEncryption.append(e) }
    func scan() { scanned += 1 }
    func stopScan() { stopScanned += 1 }
    func stopAdvertising() { stoppedAdvertising += 1 }
    func removeAll() { removedAll += 1 }
    func connect(_ id: UUID) { connected.append(id) }
    func discoverServices(_ id: UUID) { discoveredServices.append(id) }
    func discoverChars(_ id: UUID, _ s: CBUUID) { discoveredChars.append((id, s)) }
    func read(_ id: UUID, _ c: CBUUID) { readValues.append((id, c)) }
    func openL2CAP(_ id: UUID, _ psm: UInt16) { openedL2CAP.append((id, psm)) }
    func unpublish(_ psm: UInt16) { unpublished.append(psm) }
}

/// Everything a test needs to drive the adapter through stubbed FCB clients.
@MainActor
struct AdapterStubs {
    var central: BluetoothCentralClient
    var peripheral: BluetoothPeripheralClient
    let calls: AdapterCalls
    // Continuations the test drives to feed the adapter.
    let centralState: AsyncStream<CBManagerState>.Continuation
    let peripheralState: AsyncStream<CBManagerState>.Continuation
    let scanCont: AsyncStream<DiscoveredPeripheral>.Continuation
    let centralEvents: AsyncStream<CentralEvent>.Continuation
    let inboundL2CAP: AsyncStream<L2CAPConnection>.Continuation
    // Configurable results for the throwing central ops (Tasks 3–4 use these).
    let directoryResult: LockIsolated<(version: UInt8, psm: UInt16)?>  // nil → throw
    let openResult: LockIsolated<L2CAPConnection?>                     // nil → throw l2capNotSupported
    let publishPSM: LockIsolated<UInt16>
}

@MainActor
func makeStubs() -> AdapterStubs {
    let calls = AdapterCalls()
    let cState = AsyncStream<CBManagerState>.makeStream()
    let pState = AsyncStream<CBManagerState>.makeStream()
    let scan = AsyncStream<DiscoveredPeripheral>.makeStream()
    let cEvents = AsyncStream<CentralEvent>.makeStream()
    let inbound = AsyncStream<L2CAPConnection>.makeStream()
    let directoryResult = LockIsolated<(version: UInt8, psm: UInt16)?>((version: 2, psm: 0x0081))
    let openResult = LockIsolated<L2CAPConnection?>(nil)
    let publishPSM = LockIsolated<UInt16>(0x0081)

    let central = BluetoothCentralClient(
        state: { cState.stream },
        authorization: { .allowedAlways },
        scan: { _, _ in Task { await calls.scan() }; return scan.stream },
        stopScan: { await calls.stopScan() },
        connect: { id, _ in await calls.connect(id); return Peripheral(id: id, name: nil, state: .connected) },
        disconnect: { _ in },
        retrievePeripherals: { _ in [] },
        retrieveConnected: { _ in [] },
        discoverServices: { id, _ in await calls.discoverServices(id); return [Service(id: serviceUUID, peripheralID: id, isPrimary: true)] },
        discoverCharacteristics: { id, s, _ in
            await calls.discoverChars(id, s)
            return [Characteristic(id: versionCharUUID, serviceID: serviceUUID, peripheralID: id, properties: .read, value: nil, isNotifying: false),
                    Characteristic(id: psmCharUUID, serviceID: serviceUUID, peripheralID: id, properties: .read, value: nil, isNotifying: false)]
        },
        readValue: { id, c in
            await calls.read(id, c)
            guard let r = directoryResult.value else { throw BluetoothError.operationCancelled }
            if c == versionCharUUID { return Data([r.version]) }
            return Data([UInt8(r.psm & 0xFF), UInt8(r.psm >> 8)])
        },
        writeValue: { _, _, _, _ in },
        setNotify: { _, _, _ in },
        maximumWriteValueLength: { _, _ in 512 },
        notifications: { _, _ in .finished() },
        openL2CAPChannel: { id, psm in
            await calls.openL2CAP(id, psm)
            guard let conn = openResult.value else { throw BluetoothError.l2capNotSupported }
            return conn
        },
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
        respond: { _, _ in },
        updateValue: { _, _, _ in },
        publishL2CAPChannel: { e in await calls.publish(e); return publishPSM.value },
        unpublishL2CAPChannel: { psm in await calls.unpublish(psm) },
        l2capConnections: { inbound.stream },
        readRequests: { .finished },
        writeRequests: { .finished },
        subscriptions: { .finished },
        events: { .finished }
    )

    // NOTE: both client initializers are @DependencyClient memberwise inits —
    // the argument order above MUST match each client's property DECLARATION
    // order in FCBComposable (verified against the merged FCB source). If FCB
    // reorders its properties, update these stubs to match.

    return AdapterStubs(
        central: central, peripheral: peripheral, calls: calls,
        centralState: cState.continuation, peripheralState: pState.continuation,
        scanCont: scan.continuation, centralEvents: cEvents.continuation,
        inboundL2CAP: inbound.continuation,
        directoryResult: directoryResult, openResult: openResult, publishPSM: publishPSM)
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
        group.addTask {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return []
        }
        out = await group.next() ?? []
        group.cancelAll()
    }
    return out
}

@Test @MainActor func startupPublishesDirectoryAdvertisesScansThenReady() async {
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral)
    let events = adapter.start(BLEDriverConfig(version: 2, pairingMode: .open))
    // Both managers power on → adapter should publish L2CAP, add the directory
    // service, advertise, start scan, and emit exactly one .ready.
    stubs.peripheralState.yield(.poweredOn)
    stubs.centralState.yield(.poweredOn)
    let collected = await collect(events, count: 1)
    #expect(collected == [.ready])

    let added = await stubs.calls.addedServices
    #expect(added.count == 1)
    let svc = added[0]
    #expect(svc.id == serviceUUID)
    #expect(svc.characteristics.contains { $0.id == versionCharUUID && $0.value == Data([2]) })
    #expect(svc.characteristics.contains { $0.id == psmCharUUID && $0.value == Data([0x81, 0x00]) })
    #expect(await stubs.calls.publishedEncryption == [false])
    #expect(await stubs.calls.advertised.count == 1)
    #expect(await stubs.calls.scanned == 1)
    await adapter.stop()
}

@Test @MainActor func pairedModePublishesWithEncryptionAndEncryptedReadPerms() async {
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral)
    _ = adapter.start(BLEDriverConfig(version: 2, pairingMode: .paired))
    stubs.peripheralState.yield(.poweredOn)
    stubs.centralState.yield(.poweredOn)
    // Give the startup effects time to run.
    try? await Task.sleep(nanoseconds: 200_000_000)
    #expect(await stubs.calls.publishedEncryption == [true])
    let svc = await stubs.calls.addedServices.first
    #expect(svc?.characteristics.allSatisfy { $0.permissions == .readEncryptionRequired } == true)
    await adapter.stop()
}

@Test @MainActor func poweredOffEmitsUnavailableOnce() async {
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral)
    let events = adapter.start(BLEDriverConfig(version: 2, pairingMode: .open))
    stubs.centralState.yield(.poweredOff)
    let collected = await collect(events, count: 1)
    #expect(collected == [.unavailable(reason: "central poweredOff")])
    await adapter.stop()
}

/// Brings the adapter online, drains the .ready event, and returns (adapter, stubs, events).
@MainActor
func onlineAdapter() async -> (FCBDriverAdapter, AdapterStubs, AsyncStream<BLEDriverEvent>) {
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral)
    let events = adapter.start(BLEDriverConfig(version: 2, pairingMode: .open))
    stubs.peripheralState.yield(.poweredOn)
    stubs.centralState.yield(.poweredOn)
    _ = await collect(events, count: 1)  // consume .ready so tests see only their events
    return (adapter, stubs, events)
}

func peer(_ b: UInt8) -> BLEPeerHandle { BLEPeerHandle(id: UUID(uuidString: "0000000\(b)-0000-0000-0000-000000000000")!) }

/// A minimal in-memory L2CAPConnection for tests: `incoming` replays scripted
/// chunks then finishes; `send`/`close` record.
@MainActor
func fakeConnection(peerID: UUID, psm: UInt16, inbound: [Data] = [],
                    sent: LockIsolated<[Data]>? = nil, closed: LockIsolated<Bool>? = nil,
                    finishAfterInbound: Bool = true) -> L2CAPConnection {
    L2CAPConnection(
        id: UUID(), peerID: peerID, psm: psm,
        incoming: {
            AsyncStream { cont in
                for c in inbound { cont.yield(c) }
                if finishAfterInbound { cont.finish() }
            }
        },
        send: { d in sent?.withValue { $0.append(d) } },
        close: { closed?.setValue(true) }
    )
}

@Test @MainActor func discoveryDedupsAndEmitsPeerDiscovered() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p1 = peer(1)
    let p2 = peer(7)
    stubs.scanCont.yield(DiscoveredPeripheral(
        peripheral: Peripheral(id: p1.id, name: nil, state: .disconnected),
        advertisementData: AdvertisementData(serviceUUIDs: [serviceUUID]), rssi: -50))
    stubs.scanCont.yield(DiscoveredPeripheral(  // duplicate — must be ignored
        peripheral: Peripheral(id: p1.id, name: nil, state: .disconnected),
        advertisementData: AdvertisementData(serviceUUIDs: [serviceUUID]), rssi: -51))
    stubs.scanCont.yield(DiscoveredPeripheral(  // distinct peer as sentinel
        peripheral: Peripheral(id: p2.id, name: nil, state: .disconnected),
        advertisementData: AdvertisementData(serviceUUIDs: [serviceUUID]), rssi: -52))
    // With dedup: [p1, p2]. Without dedup: [p1, p1] (p2 never reached in count: 2).
    let collected = await collect(events, count: 2)
    #expect(collected == [.peerDiscovered(p1), .peerDiscovered(p2)])
    await adapter.stop()
}

@Test @MainActor func readDirectoryHappyPathEmitsDirectoryRead() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(2)
    stubs.directoryResult.setValue((version: 2, psm: 0x0192))
    await adapter.readDirectory(p)
    let collected = await collect(events, count: 1)
    #expect(collected == [.directoryRead(p, version: 2, psm: 0x0192)])
    #expect(await stubs.calls.connected == [p.id])
    #expect(await stubs.calls.readValues.map(\.1) == [versionCharUUID, psmCharUUID])
    await adapter.stop()
}

@Test @MainActor func readDirectoryFailureEmitsDirectoryFailedAndForgets() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(3)
    stubs.directoryResult.setValue(nil)  // readValue throws
    await adapter.readDirectory(p)
    let collected = await collect(events, count: 1)
    guard case .directoryFailed(p, _)? = collected.first else {
        Issue.record("expected directoryFailed, got \(collected)"); await adapter.stop(); return
    }
    // Forgotten: a re-discovery re-emits peerDiscovered.
    stubs.scanCont.yield(DiscoveredPeripheral(
        peripheral: Peripheral(id: p.id, name: nil, state: .disconnected),
        advertisementData: AdvertisementData(serviceUUIDs: [serviceUUID]), rssi: -50))
    let after = await collect(events, count: 1)
    #expect(after == [.peerDiscovered(p)])
    await adapter.stop()
}

@Test @MainActor func openChannelSuccessEmitsChannelOpenedOutboundThenDataAndClose() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(4)
    let conn = fakeConnection(peerID: p.id, psm: 0x0081, inbound: [Data([0xAB, 0xCD])])
    stubs.openResult.setValue(conn)
    await adapter.openChannel(p, psm: 0x0081)
    // Expect: channelOpened(.outbound), channelData, channelClosed (stream finished).
    let collected = await collect(events, count: 3)
    guard collected.count == 3,
          case let .channelOpened(cid, hp, dir) = collected[0],
          case let .channelData(cid2, data) = collected[1],
          case let .channelClosed(cid3, _) = collected[2]
    else { Issue.record("unexpected: \(collected)"); await adapter.stop(); return }
    #expect(hp == p)
    #expect(dir == .outbound)
    #expect(data == Data([0xAB, 0xCD]))
    #expect(cid == cid2 && cid2 == cid3)
    await adapter.stop()
}

@Test @MainActor func openChannelFailureEmitsChannelFailedAndForgets() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(5)
    stubs.openResult.setValue(nil)  // throws l2capNotSupported
    await adapter.openChannel(p, psm: 0x0081)
    let collected = await collect(events, count: 1)
    guard case .channelFailed(p, _)? = collected.first else {
        Issue.record("expected channelFailed, got \(collected)"); await adapter.stop(); return
    }
    await adapter.stop()
}

@Test @MainActor func disconnectEventForgetsPeer() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(6)
    stubs.scanCont.yield(DiscoveredPeripheral(
        peripheral: Peripheral(id: p.id, name: nil, state: .disconnected),
        advertisementData: AdvertisementData(serviceUUIDs: [serviceUUID]), rssi: -50))
    _ = await collect(events, count: 1)  // consume the first peerDiscovered
    stubs.centralEvents.yield(.didDisconnect(Peripheral(id: p.id, name: nil, state: .disconnected), nil))
    try? await Task.sleep(nanoseconds: 100_000_000)
    // Re-discovery now re-emits (forgotten on disconnect).
    stubs.scanCont.yield(DiscoveredPeripheral(
        peripheral: Peripheral(id: p.id, name: nil, state: .disconnected),
        advertisementData: AdvertisementData(serviceUUIDs: [serviceUUID]), rssi: -50))
    let after = await collect(events, count: 1)
    #expect(after == [.peerDiscovered(p)])
    await adapter.stop()
}

@Test @MainActor func inboundConnectionEmitsChannelOpenedInboundAndData() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(7)
    let conn = fakeConnection(peerID: p.id, psm: 0x0081, inbound: [Data([0x42])])
    stubs.inboundL2CAP.yield(conn)
    let collected = await collect(events, count: 3)  // opened, data, closed
    guard collected.count >= 2,
          case let .channelOpened(_, hp, dir) = collected[0],
          case let .channelData(_, data) = collected[1]
    else { Issue.record("unexpected: \(collected)"); await adapter.stop(); return }
    #expect(hp == p)
    #expect(dir == .inbound)
    #expect(data == Data([0x42]))
    await adapter.stop()
}

@Test @MainActor func sendForwardsToTheChannelConnection() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(8)
    let sent = LockIsolated<[Data]>([])
    // Keep the connection open (don't finish incoming) so the channel stays registered.
    let conn = fakeConnection(peerID: p.id, psm: 0x0081, inbound: [], sent: sent, finishAfterInbound: false)
    stubs.openResult.setValue(conn)
    await adapter.openChannel(p, psm: 0x0081)
    let opened = await collect(events, count: 1)
    guard case let .channelOpened(cid, _, _)? = opened.first else {
        Issue.record("no channelOpened"); await adapter.stop(); return
    }
    await adapter.send(cid, data: Data([0x01, 0x02]))
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(sent.value == [Data([0x01, 0x02])])
    await adapter.stop()
}

@Test @MainActor func closeChannelIsSilentNoChannelClosedEcho() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(9)
    let closed = LockIsolated<Bool>(false)
    let conn = fakeConnection(peerID: p.id, psm: 0x0081, inbound: [], closed: closed, finishAfterInbound: false)
    stubs.openResult.setValue(conn)
    await adapter.openChannel(p, psm: 0x0081)
    let opened = await collect(events, count: 1)
    guard case let .channelOpened(cid, _, _)? = opened.first else {
        Issue.record("no channelOpened"); await adapter.stop(); return
    }
    await adapter.closeChannel(cid)
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(closed.value == true)  // underlying connection closed
    // No channelClosed event should have been emitted for a reducer-initiated close.
    // Drain briefly: the only remaining event before stop() must NOT be channelClosed(cid).
    await adapter.stop()
    let tail = await collect(events, count: 5)
    #expect(!tail.contains { if case .channelClosed(cid, _) = $0 { return true }; return false })
}

@Test @MainActor func sendToUnknownChannelIsDropped() async {
    let (adapter, _, _) = await onlineAdapter()
    // No such channel — must not crash.
    await adapter.send(BLEChannelID(id: UUID()), data: Data([0x01]))
    await adapter.stop()
}

@Test @MainActor func readyWaitsForAdvertisingNotJustScanning() async {
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral)
    let events = adapter.start(BLEDriverConfig(version: 2, pairingMode: .open))
    // Drain the whole session with ONE iterator (the stream is single-consumer),
    // recording every event with the order it arrived.
    let recorded = LockIsolated<[BLEDriverEvent]>([])
    let drain = Task {
        for await e in events { recorded.withValue { $0.append(e) } }
    }
    // Only the central powers on: scanning goes up, advertising stays down.
    // .ready MUST NOT fire yet (the GATT directory isn't published).
    stubs.centralState.yield(.poweredOn)
    try? await Task.sleep(nanoseconds: 400_000_000)
    #expect(recorded.value == [])           // correct: nothing; mutation 2: [.ready]
    // Now the peripheral powers on → advertising up → .ready fires exactly once.
    stubs.peripheralState.yield(.poweredOn)
    try? await Task.sleep(nanoseconds: 400_000_000)
    #expect(recorded.value == [.ready])
    await adapter.stop()
    drain.cancel()
}
