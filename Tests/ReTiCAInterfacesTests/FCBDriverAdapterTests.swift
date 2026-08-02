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
