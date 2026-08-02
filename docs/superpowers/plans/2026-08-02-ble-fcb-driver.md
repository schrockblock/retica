# BLE Driver on FCB Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ReTiCA's hand-rolled `CoreBluetoothDriver` with a thin `FCBDriverAdapter` that composes FCB's `BluetoothCentralClient` + `BluetoothPeripheralClient` (with L2CAP) into the existing `BLEDriver` contract — the `BLEInterface` reducer, `BLEDriverEvent` contract, wire protocol, and all reducer tests stay byte-identical.

**Architecture:** A mechanism-only actor `FCBDriverAdapter` (no policy, no retries, no framing) subscribes to FCB's state/scan/events streams and per-channel `incoming()` streams, mapping them to `BLEDriverEvent`s, and forwards the driver commands (`readDirectory`/`openChannel`/`send`/`closeChannel`/`stop`) to the FCB clients. Exposed via a new `BLEDriver.fcb(central:peripheral:)` factory; `BLEDriver.liveValue` becomes `.fcb(central: .liveValue, peripheral: .liveValue)`. Adapter unit tests inject hand-stubbed FCB client struct values (recording closures + `AsyncStream`s), matching ReTiCA's existing `TCPConnection` mock pattern — no CoreBluetoothMock needed for the core coverage.

**Tech Stack:** Swift 6, ComposableArchitecture, Swift Testing, FCB (`FCBComposable`, local path dep), CoreBluetoothMock (final integration test only).

## Global Constraints

- Repo: `/Users/ell/development/ios/pods/ReTiCA`. Commit directly to `main` (project convention — no feature branch).
- Spec: `docs/superpowers/specs/2026-08-01-ble-fcb-driver-design.md`. FCB L2CAP support is merged on FCB `main` at `../FCB` (sibling; no git remote — consumed via `.package(path: "../FCB")`).
- **Do not change** `Sources/ReTiCAInterfaces/BLEInterface.swift`, `Sources/ReTiCAInterfaces/BLESupport.swift`, or any existing test in `Tests/ReTiCAInterfacesTests/` (BLEInterfaceTests, BLESupportTests, BLEFixtureTests, TCPClientInterfaceTests, TCPConnectionTests). The `BLEDriverEvent`/`BLEDriver` contract in `BLEDriver.swift` stays byte-identical except the `liveValue` body and the added `fcb(...)` factory.
- RBTP v2 constants (verbatim, from the existing driver / spec): service UUID `99872ed7-eba8-4c07-bf35-ab464a957f80`, Version characteristic `50870e44-2fd6-4cbc-9f1f-11a0fcf85265` (value `Data([config.version])`), PSM characteristic `1cfe213f-4ea4-48f9-9344-dde18cc729ef` (value = PSM little-endian, 2 bytes). `paired` → `publishL2CAPChannel(withEncryption: true)` + characteristic permissions `.readEncryptionRequired`; `open` → `false` + `.readable`.
- Platforms (from spec): ReTiCA declares `.iOS(.v17)`, `.macOS(.v13)`, `.macCatalyst(.v17)`; tvOS/watchOS dropped.
- Known accepted limitation: on macOS FCB's central `openL2CAPChannel` throws `BluetoothError.l2capNotSupported` (CBM gates it) — the adapter maps that to `.channelFailed` like any other failure. Do not special-case it.
- FCB signatures the adapter consumes (exact):
  - `BluetoothCentralClient`: `state: () -> AsyncStream<CBManagerState>`, `scan: ([CBUUID]?, ScanOptions?) -> AsyncStream<DiscoveredPeripheral>`, `stopScan: () async -> Void`, `connect: (UUID, ConnectOptions?) async throws -> Peripheral`, `disconnect: (UUID) async throws -> Void`, `discoverServices: (UUID, [CBUUID]?) async throws -> [Service]`, `discoverCharacteristics: (UUID, CBUUID, [CBUUID]?) async throws -> [Characteristic]`, `readValue: (UUID, CBUUID) async throws -> Data`, `openL2CAPChannel: (UUID, UInt16) async throws -> L2CAPConnection`, `events: () -> AsyncStream<CentralEvent>`.
  - `BluetoothPeripheralClient`: `state: () -> AsyncStream<CBManagerState>`, `add: (MutableService) async throws -> Service`, `removeAll: () async -> Void`, `startAdvertising: (AdvertisementData?) async throws -> Void`, `stopAdvertising: () async -> Void`, `publishL2CAPChannel: (Bool) async throws -> UInt16`, `unpublishL2CAPChannel: (UInt16) async -> Void`, `l2capConnections: () -> AsyncStream<L2CAPConnection>`.
  - Value types: `DiscoveredPeripheral{ peripheral: Peripheral, advertisementData, rssi }`, `Peripheral{ id: UUID }`, `Service{ id: CBUUID, peripheralID: UUID }`, `Characteristic{ id: CBUUID, peripheralID: UUID }`, `MutableService(id:isPrimary:characteristics:)`, `MutableCharacteristic(id:properties:permissions:value:)`, `L2CAPConnection{ id: UUID, peerID: UUID, psm: UInt16, incoming: () -> AsyncStream<Data>, send: (Data) async throws -> Void, close: () async -> Void }`, `CentralEvent` (has `.didDisconnect(Peripheral, BluetoothError?)`), `ScanOptions(allowDuplicates:solicitedServiceUUIDs:)`.
- Never chain shell commands: no `&&`, `|`, `;`, `$(...)`, xargs, inline interpreters. One command per Bash invocation. Write commit messages to a file under `/tmp/ReTiCA/` with the Write tool and commit with `git commit -F <file>`.
- Every commit message MUST end with these two trailer lines starting at column 0 (no indentation), exactly:

```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
```

After committing, verify: `git log -1 --format='%(trailers:key=Claude-Session)'` prints the line.
- **Mutation verification is mandatory for every task that adds tests**: (a) new tests pass; (b) apply the task's listed mutations in one batch, run, the named tests FAIL; (c) revert, run, all pass. Commit only after (c) is green.
- Test iteration: `swift test --filter FCBDriverAdapterTests` for the adapter; run full `swift test` before each commit and confirm green (the existing ~560 tests must stay green).

---

### Task 1: Package.swift — FCB dependency + platforms

**Files:**
- Modify: `Package.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ReTiCAInterfaces` can `import FCBComposable`; `ReTiCAInterfacesTests` can `import FCBComposable` and (for Task 6) `import CoreBluetoothMock`.

- [ ] **Step 1: Edit `Package.swift`**

Change the `platforms` array to:

```swift
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
        .macCatalyst(.v17),
    ],
```

Add to `dependencies` (after the existing swift-composable-architecture entry):

```swift
        .package(path: "../FCB"),
        .package(url: "https://github.com/NordicSemiconductor/IOS-CoreBluetooth-Mock.git", from: "1.0.0"),
```

Add `FCBComposable` to the `ReTiCAInterfaces` target's dependencies:

```swift
        .target(
            name: "ReTiCAInterfaces",
            dependencies: [
                "ReTiCA",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FCBComposable", package: "FCB"),
            ]
        ),
```

Add both `FCBComposable` and `CoreBluetoothMock` to the `ReTiCAInterfacesTests` target:

```swift
        .testTarget(
            name: "ReTiCAInterfacesTests",
            dependencies: [
                "ReTiCAInterfaces",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FCBComposable", package: "FCB"),
                .product(name: "CoreBluetoothMock", package: "IOS-CoreBluetooth-Mock"),
            ]
        ),
```

- [ ] **Step 2: Resolve and build**

Run: `swift package resolve`
Expected: resolves FCB (path) + IOS-CoreBluetooth-Mock with no version conflict.
Run: `swift build`
Expected: clean (nothing consumes FCB yet; this just proves resolution + platform bump compile). If a platform-floor error surfaces from a dependency, report it.

- [ ] **Step 3: Full test suite still green**

Run: `swift test`
Expected: the existing suite passes unchanged (the platform bump and new deps don't touch existing code).

- [ ] **Step 4: Commit**

Write `/tmp/ReTiCA/task1-msg.txt` (subject `build: add FCB path dependency + bump platforms to iOS 17 for BLE driver`), then:

```bash
git add Package.swift Package.resolved
git commit -F /tmp/ReTiCA/task1-msg.txt
```

---

### Task 2: `FCBDriverAdapter` skeleton + startup (state → ready/unavailable, GATT directory, advertise, scan)

**Files:**
- Create: `Sources/ReTiCAInterfaces/FCBDriverAdapter.swift`
- Test: `Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift`

**Interfaces:**
- Consumes: `BLEDriver`, `BLEDriverConfig`, `BLEDriverEvent`, `BLEPeerHandle`, `BLEChannelID`, `BLEChannelDirection`, `BLEPairingMode` (existing `BLEDriver.swift`); FCB clients + models (Global Constraints).
- Produces (used by Tasks 3–6):
  - `actor FCBDriverAdapter` with `init(central: BluetoothCentralClient, peripheral: BluetoothPeripheralClient)`, `nonisolated func start(_ config: BLEDriverConfig) -> AsyncStream<BLEDriverEvent>`, and (stubs filled by later tasks) `func readDirectory(_ peer: BLEPeerHandle) async`, `func openChannel(_ peer: BLEPeerHandle, psm: UInt16) async`, `func send(_ channel: BLEChannelID, data: Data) async`, `func closeChannel(_ channel: BLEChannelID) async`, `func stop() async`.
  - `extension BLEDriver { public static func fcb(central: BluetoothCentralClient, peripheral: BluetoothPeripheralClient) -> BLEDriver }`.
  - Internal pure helper `func rbtpDirectoryService(version: UInt8, psm: UInt16, pairingMode: BLEPairingMode) -> MutableService` (the GATT directory).
  - Test helpers in `FCBDriverAdapterTests.swift`: `makeStubs()` returning recording FCB client stubs + continuations + a recorded-calls actor; `collect(_ stream:count:)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter FCBDriverAdapterTests`
Expected: compile FAILURE (`FCBDriverAdapter` not defined).

- [ ] **Step 3: Write `FCBDriverAdapter.swift` (skeleton + startup; later tasks fill the command stubs)**

Create `Sources/ReTiCAInterfaces/FCBDriverAdapter.swift`:

```swift
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
```

`restartScan()` above already issues `central.scan(...)` and pumps to the (empty)
`handleDiscovered`, so `startupPublishesDirectoryAdvertisesScansThenReady` sees
`scanned == 1`; `handleDiscovered`, `subscribeCentralEvents`, and
`subscribeInboundL2CAP` stay empty until Tasks 3–4 fill them.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FCBDriverAdapterTests`
Expected: the three tests PASS. (If the scan stream's laziness makes `scanned` count flaky, ensure `restartScan` issues `central.scan` exactly once per power-on.)

- [ ] **Step 5: Mutation verification (batch)**

1. In `rbtpDirectoryService`, change the PSM value to big-endian (`Data([UInt8(psm >> 8), UInt8(psm & 0xFF)])`).
2. In `checkReady`, drop the `advertising` requirement (`guard scanning, !announcedReady`).
3. In `bringUpPeripheral`, hardcode `publishL2CAPChannel(false)`.

Run: `swift test --filter FCBDriverAdapterTests`
Expected: `startupPublishesDirectoryAdvertisesScansThenReady` (1), `poweredOffEmitsUnavailableOnce` (2 — ready would fire before unavailable if the advertising gate is dropped, changing the first event) and `pairedModePublishesWithEncryptionAndEncryptedReadPerms` (3) FAIL. Revert; re-run; all PASS. Then `swift test` — full suite green.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCA/task2-msg.txt` (subject `feat: FCBDriverAdapter startup — GATT directory, advertise, scan, ready`), then:

```bash
git add Sources/ReTiCAInterfaces/FCBDriverAdapter.swift Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift
git commit -F /tmp/ReTiCA/task2-msg.txt
```

---

### Task 3: Discovery → directory → outbound channel (+ shared connection register)

**Files:**
- Modify: `Sources/ReTiCAInterfaces/FCBDriverAdapter.swift` (fill discovery/directory/openChannel + `register`)
- Test: `Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift` (append)

**Interfaces:**
- Consumes: Task 2 adapter + `makeStubs`/`AdapterStubs`/`collect`.
- Produces: working `readDirectory`, `openChannel`, discovery dedup, disconnect-forget, and the shared `register(_ conn: L2CAPConnection, direction: BLEChannelDirection)` helper (Task 4 reuses it for inbound); `forget(_ id: UUID)`; `channelDidClose(_ id:)` honoring `reducerClosed`.

- [ ] **Step 1: Write the failing tests**

Append to `FCBDriverAdapterTests.swift`:

```swift
/// Brings the adapter online and returns (adapter, stubs, events).
@MainActor
func onlineAdapter() async -> (FCBDriverAdapter, AdapterStubs, AsyncStream<BLEDriverEvent>) {
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral)
    let events = adapter.start(BLEDriverConfig(version: 2, pairingMode: .open))
    stubs.peripheralState.yield(.poweredOn)
    stubs.centralState.yield(.poweredOn)
    try? await Task.sleep(nanoseconds: 150_000_000)  // let startup settle
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
    let p = peer(1)
    stubs.scanCont.yield(DiscoveredPeripheral(
        peripheral: Peripheral(id: p.id, name: nil, state: .disconnected),
        advertisementData: AdvertisementData(serviceUUIDs: [serviceUUID]), rssi: -50))
    stubs.scanCont.yield(DiscoveredPeripheral(  // duplicate — must be ignored
        peripheral: Peripheral(id: p.id, name: nil, state: .disconnected),
        advertisementData: AdvertisementData(serviceUUIDs: [serviceUUID]), rssi: -51))
    let collected = await collect(events, count: 1)
    #expect(collected == [.peerDiscovered(p)])
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter FCBDriverAdapterTests`
Expected: the new tests FAIL (readDirectory/openChannel are empty stubs, discovery/events unsubscribed).

- [ ] **Step 3: Implement in `FCBDriverAdapter.swift`**

Replace the empty `subscribeCentralEvents`, `handleDiscovered`, and the `readDirectory`/`openChannel` command stubs, and add the shared helpers:

```swift
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
                continuation?.yield(.directoryFailed(peer, reason: "short directory read"))
                return
            }
            let version = versionData[versionData.startIndex]
            let lo = UInt16(psmData[psmData.startIndex])
            let hi = UInt16(psmData[psmData.startIndex + 1])
            continuation?.yield(.directoryRead(peer, version: version, psm: lo | (hi << 8)))
        } catch {
            forget(peer.id)
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FCBDriverAdapterTests`
Expected: all PASS.

- [ ] **Step 5: Mutation verification (batch)**

1. In `handleDiscovered`, delete the `guard !seenPeers.contains(id)` line (dedup gone).
2. In `readDirectory`, parse PSM big-endian (`hi | (lo << 8)`... i.e. swap: `UInt16(psmData[startIndex]) << 8 | UInt16(psmData[startIndex+1])`).
3. In `openChannel`'s catch, emit `.directoryFailed(peer, ...)` instead of `.channelFailed`.

Run: `swift test --filter FCBDriverAdapterTests`
Expected: `discoveryDedupsAndEmitsPeerDiscovered` (1), `readDirectoryHappyPathEmitsDirectoryRead` (2 — psm 0x0192 becomes 0x9201), `openChannelFailureEmitsChannelFailedAndForgets` (3) FAIL. Revert; re-run; all PASS. Then `swift test` — full suite green.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCA/task3-msg.txt` (subject `feat: FCBDriverAdapter discovery, directory read, outbound channel`), then:

```bash
git add Sources/ReTiCAInterfaces/FCBDriverAdapter.swift Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift
git commit -F /tmp/ReTiCA/task3-msg.txt
```

---

### Task 4: Inbound channels, send, silent close

**Files:**
- Modify: `Sources/ReTiCAInterfaces/FCBDriverAdapter.swift` (fill `subscribeInboundL2CAP`, `send`, `closeChannel`)
- Test: `Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift` (append)

**Interfaces:**
- Consumes: Task 3 `register`, `connections`, `reducerClosed`; the `fakeConnection` test helper.
- Produces: working inbound path, `send`, `closeChannel` (silent — no `channelClosed` echo).

- [ ] **Step 1: Write the failing tests**

Append to `FCBDriverAdapterTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter FCBDriverAdapterTests`
Expected: the new tests FAIL (`subscribeInboundL2CAP`/`send`/`closeChannel` are empty).

- [ ] **Step 3: Implement**

Replace the empty `subscribeInboundL2CAP` and the `send`/`closeChannel` command stubs:

```swift
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
```

Note: `registerInbound` is a thin wrapper so the actor-isolated `register` is called from the actor context; `subscribeInboundL2CAP`'s Task hops in via `await self.registerInbound(conn)`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FCBDriverAdapterTests`
Expected: all PASS.

- [ ] **Step 5: Mutation verification (batch)**

1. In `register`, hardcode `direction: .outbound` (ignore the parameter) — inbound test sees `.outbound`.
2. In `send`, drop the `guard let conn` and replace body with `return` (never forwards) — actually: change to send to a wrong/no connection by replacing `try? await conn.send(data)` with `()`.
3. In `closeChannel`, delete the `reducerClosed.insert(channel)` line — the silent-close test would then see a `channelClosed` echo.

Run: `swift test --filter FCBDriverAdapterTests`
Expected: `inboundConnectionEmitsChannelOpenedInboundAndData` (1), `sendForwardsToTheChannelConnection` (2), `closeChannelIsSilentNoChannelClosedEcho` (3) FAIL. Revert; re-run; all PASS. Then `swift test` — full suite green.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCA/task4-msg.txt` (subject `feat: FCBDriverAdapter inbound channels, send, silent close`), then:

```bash
git add Sources/ReTiCAInterfaces/FCBDriverAdapter.swift Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift
git commit -F /tmp/ReTiCA/task4-msg.txt
```

---

### Task 5: Delete `CoreBluetoothDriver`, rewire `liveValue`

**Files:**
- Delete: `Sources/ReTiCAInterfaces/CoreBluetoothDriver.swift`
- Modify: `Sources/ReTiCAInterfaces/BLEDriver.swift` (`liveValue` body only)

**Interfaces:**
- Consumes: `BLEDriver.fcb(central:peripheral:)` (Task 2).
- Produces: `BLEDriver.liveValue` backed by FCB; the hand-rolled driver is gone.

- [ ] **Step 1: Delete the old driver**

```bash
git rm Sources/ReTiCAInterfaces/CoreBluetoothDriver.swift
```

- [ ] **Step 2: Rewire `liveValue`**

In `Sources/ReTiCAInterfaces/BLEDriver.swift`, replace the `liveValue` computed property with:

```swift
    public static var liveValue: BLEDriver {
        #if canImport(CoreBluetooth) && (os(iOS) || os(macOS))
        return .fcb(central: .liveValue, peripheral: .liveValue)
        #else
        return BLEDriver(start: { _ in .finished }, readDirectory: { _ in },
                         openChannel: { _, _ in }, send: { _, _ in },
                         closeChannel: { _ in }, stop: {})
        #endif
    }
```

(`.liveValue` here refers to `BluetoothCentralClient.liveValue` / `BluetoothPeripheralClient.liveValue`, which FCB provides. `testValue` stays unchanged.)

- [ ] **Step 3: Build + full suite**

Run: `swift build`
Expected: clean — no remaining reference to `CoreBluetoothDriver`. If the compiler flags a leftover reference, fix it (there should be none outside the deleted file and this `liveValue`).
Run: `swift test`
Expected: entire suite green (adapter tests + the untouched BLEInterface/BLESupport/fixture/TCP tests). The reducer and its tests never referenced `CoreBluetoothDriver` directly (only `BLEDriver`), so they are unaffected.

- [ ] **Step 4: Commit**

Write `/tmp/ReTiCA/task5-msg.txt` (subject `refactor: back BLEDriver.liveValue with FCB, delete CoreBluetoothDriver`), then:

```bash
git add Sources/ReTiCAInterfaces/BLEDriver.swift Sources/ReTiCAInterfaces/CoreBluetoothDriver.swift
git commit -F /tmp/ReTiCA/task5-msg.txt
```

(`git add` of the deleted path stages the deletion.)

---

### Task 6: CoreBluetoothMock integration test (directory flow)

**Files:**
- Test: `Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMTests.swift`

**Interfaces:**
- Consumes: `BLEDriver.fcb(central:peripheral:)`, `BluetoothCentralClient.mocked()`, `BluetoothPeripheralClient.testValue` (peripheral role isn't exercised here), CoreBluetoothMock.
- Produces: an end-to-end proof that the REAL FCB central actor + the adapter drive scan → connect → discovery → reads → `.directoryRead`, and that an `openChannel` on the mocked central maps to `.channelFailed` (CBM can't open L2CAP).

**Off-ramp:** this task depends on `CoreBluetoothMock` resolving as a ReTiCAInterfacesTests dependency (Task 1) and on CBM's process-global simulation being usable from ReTiCA's suite. If the CBM wiring proves unworkable in this package (e.g. simulation-state bleed with the existing tests that cannot be contained), STOP and report — the adapter's mapping is already fully covered by Tasks 2–4's stubbed-client tests and FCB's own CBM suite, so this test is confirmatory, not load-bearing. Do not weaken or delete existing tests to make it fit.

- [ ] **Step 1: Write the test**

Create `Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMTests.swift`:

```swift
import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
@testable import ReTiCAInterfaces
@testable import FCBComposable

/// CBM simulation is process-global; keep this in its own serialized suite.
@Suite(.serialized) @MainActor
struct FCBDriverAdapterCBMTests {
    @Test func realCentralDrivesDirectoryReadThenChannelFailsOnMock() async throws {
        CBMCentralManagerMock.tearDownSimulation()
        CBMCentralManagerMock.simulateInitialState(.poweredOn)

        let id = UUID()
        // A peripheral serving the RBTP directory: version=2, PSM=0x0081 (LE bytes 81 00).
        let versionChar = CBMCharacteristicMock(type: versionCharUUID, properties: [.read], value: Data([2]))
        let psmChar = CBMCharacteristicMock(type: psmCharUUID, properties: [.read], value: Data([0x81, 0x00]))
        let service = CBMServiceMock(type: serviceUUID, primary: true, characteristics: versionChar, psmChar)
        let spec = CBMPeripheralSpec
            .simulatePeripheral(identifier: id, proximity: .near)
            .advertising(advertisementData: [
                CBMAdvertisementDataServiceUUIDsKey: [serviceUUID],
                CBMAdvertisementDataIsConnectable: true as NSNumber,
            ], withInterval: 0.05)
            .connectable(name: "RBTPNode", services: [service], delegate: nil, connectionInterval: 0.01)
            .build()
        CBMCentralManagerMock.simulatePeripherals([spec])

        // Real FCB central actor (mocked manager) + a no-op peripheral client:
        // we only exercise the central/discovery/directory path here.
        let driver = BLEDriver.fcb(central: .mocked(), peripheral: noopPeripheralClient())
        let events = driver.start(BLEDriverConfig(version: 2, pairingMode: .open))

        // A single pump task owns the (non-Sendable) iterator and appends every
        // event to a lock-isolated buffer the test polls. No iterator crosses a
        // task boundary, so there is no Sendable problem.
        let buffer = LockIsolated<[BLEDriverEvent]>([])
        let pump = Task { for await e in events { buffer.withValue { $0.append(e) } } }
        defer { pump.cancel() }

        func waitFor(_ match: @escaping (BLEDriverEvent) -> Bool) async -> BLEDriverEvent? {
            for _ in 0..<300 {
                if let hit = buffer.withValue({ $0.first(where: match) }) { return hit }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return nil
        }

        let discovered = await waitFor { if case .peerDiscovered = $0 { return true }; return false }
        guard case let .peerDiscovered(handle)? = discovered else {
            Issue.record("no peerDiscovered"); await driver.stop(); return
        }

        await driver.readDirectory(handle)
        let read = await waitFor { if case .directoryRead = $0 { return true }; if case .directoryFailed = $0 { return true }; return false }
        #expect(read == .directoryRead(handle, version: 2, psm: 0x0081))

        // openChannel on the mocked central → CBM can't open L2CAP → .channelFailed.
        await driver.openChannel(handle, psm: 0x0081)
        let failed = await waitFor { if case .channelFailed = $0 { return true }; return false }
        #expect(failed != nil)
        await driver.stop()
    }
}

/// A peripheral client that never powers on (peripheral role unused in this test),
/// so the adapter's `.ready` waits only on the central side is irrelevant here —
/// we drive directory flow directly via readDirectory without needing .ready.
@MainActor
func noopPeripheralClient() -> BluetoothPeripheralClient {
    var client = BluetoothPeripheralClient.testValue
    client.state = { AsyncStream { $0.finish() } }
    client.publishL2CAPChannel = { _ in 0 }
    client.add = { s in Service(id: s.id, peripheralID: UUID(), isPrimary: true) }
    client.startAdvertising = { _ in }
    client.stopAdvertising = { }
    client.removeAll = { }
    client.unpublishL2CAPChannel = { _ in }
    client.l2capConnections = { AsyncStream { $0.finish() } }
    return client
}

```

The pump-into-`LockIsolated`-buffer + `waitFor` polling pattern above is the whole
mechanism — there is no separate timeout helper to implement. If CBM's simulated
timing is slower than the 300×20 ms budget on a loaded machine, raise the iteration
count; do not weaken the assertions.

- [ ] **Step 2: Run the test**

Run: `swift test --filter FCBDriverAdapterCBMTests`
Expected: PASS — the real central actor discovers the simulated peripheral, reads the directory (version 2, PSM 0x0081), and `openChannel` yields `.channelFailed`. If CBM state bleeds into other suites, confirm the `.serialized` suite + `tearDownSimulation()` contains it; if not containable, invoke the off-ramp and report.

- [ ] **Step 3: Full suite**

Run: `swift test`
Expected: everything green, including the existing suites (no CBM bleed).

- [ ] **Step 4: Commit**

Write `/tmp/ReTiCA/task6-msg.txt` (subject `test: CoreBluetoothMock integration — adapter drives real FCB directory read`), then:

```bash
git add Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMTests.swift
git commit -F /tmp/ReTiCA/task6-msg.txt
```

---

## Final verification (after Task 6)

- [ ] `swift test` — full suite green (adapter unit tests + CBM integration + all existing BLEInterface/BLESupport/fixture/TCP tests unchanged).
- [ ] `git grep -n CoreBluetoothDriver Sources` — no matches (the hand-rolled driver is fully gone).
- [ ] `git log --format='%(trailers:key=Claude-Session)' -6` — every task commit's trailers parse.
- [ ] Confirm `BLEInterface.swift` and `BLESupport.swift` are byte-unchanged from before this plan (`git diff <plan-base> -- Sources/ReTiCAInterfaces/BLEInterface.swift Sources/ReTiCAInterfaces/BLESupport.swift` is empty).

