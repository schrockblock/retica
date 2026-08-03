# BLEEndpoint Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the FCB-backed `BLEInterface` into `Transport` via a new `BLEEndpoint` reducer that maps each connected BLE peer (16-byte session token) to its own Transport `InterfaceID`, so a node runs BLE end-to-end (announces flood across peers; opportunistic packets route per peer).

**Architecture:** A new `@Reducer BLEEndpoint` in `ReTiCANode` composes `BLEInterface` + `Transport` (packet plane only — no `LinkSession`). Four wiring edges connect the two: BLE peer online/offline → Transport interface set (+ maintenance lifecycle); BLE `packetReceived` → `transport.received`; Transport `transmit` → `ble.send` for the mapped peer. The TCP `Endpoint`, `BLEInterface`, `Transport`, and `FCBDriverAdapter` are untouched.

**Tech Stack:** Swift 6, ComposableArchitecture (TCA), Swift Testing (`@Test`/`#expect`), `ReTiCA`/`ReTiCAInterfaces`/`ReTiCATransport`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-02-ble-endpoint-wiring-design.md`.
- New code lives in `Sources/ReTiCANode/BLEEndpoint.swift` + `Tests/ReTiCANodeTests/`. `ReTiCANode` already depends on `ReTiCA`, `ReTiCAInterfaces`, `ReTiCATransport` — no `Package.swift` change.
- **Do not modify** `Endpoint.swift`, `BLEInterface.swift`, `Transport.swift`, `FCBDriverAdapter.swift`, or any existing test. Do NOT touch anything under `Sources/ReTiCA/LXMF`, `Support`, `ReTiCATests` — the user has concurrent uncommitted WIP there; never `git add` those files.
- Exact upstream signatures the code must use (verbatim, verified against source):
  - `BLEInterface.Action`: `.start`, `.stop`, `.send(peer: Data, packet: Data)`, `.driverEvent(BLEDriverEvent)`, `.delegate(BLEInterface.Action.Delegate)`. Delegate cases: `.peerOnline(Data)`, `.peerOffline(Data)`, `.packetReceived(peer: Data, packet: Data)`. State init: `BLEInterface.State(maxPeers: Int = BLEInterface.defaultMaxPeers, pairingMode: BLEPairingMode = .open)`. `BLEInterface.protocolVersion: UInt8` (== 2). Peer tokens are plain `Data` (there is NO `BLEPeerID` typealias — use `Data`).
  - `Transport.Action`: `.interfaceConnected(InterfaceID)`, `.interfaceDisconnected(InterfaceID)`, `.received(InterfaceID, Data)`, `.registerLocalDestination(Destination)`, `.announce(destinationHash: Data, appData: Data?)`, `.send(destinationHash: Data, plaintext: Data)`, `.setTransportIdentity(Identity?)`, `.startMaintenance`, `.stopMaintenance`. Delegate cases: `.transmit(InterfaceID, Data)`, `.received(destinationHash: Data, plaintext: Data)`, `.pathLearned(destinationHash: Data, hops: UInt8)`, `.sendFailed(destinationHash: Data, reason: Transport.SendFailure)`. `Transport.State()` default init. `Transport.SendFailure: Equatable, Sendable`.
  - `InterfaceID(_ rawValue: String)`; `Data.hexString: String` (lowercase hex, exists in `ReTiCA/Support/Data+Hex.swift`).
  - Driver-event constructors (integration test): `BLEDriverEvent.channelOpened(BLEChannelID, BLEPeerHandle, direction: BLEChannelDirection)`, `.channelData(BLEChannelID, Data)`, `.ready`. `BLEChannelID(id: UUID)`, `BLEPeerHandle(id: UUID)`, `BLEChannelDirection.inbound`/`.outbound`. `BLEHello.pack(version: UInt8, token: Data) -> Data`, `BLEFraming.frame(_ packet: Data) throws -> Data`. `BLEDriver.init(start:readDirectory:openChannel:send:closeChannel:stop:)` where `start: @Sendable (BLEDriverConfig) -> AsyncStream<BLEDriverEvent>`, `send: @Sendable (BLEChannelID, Data) async -> Void`, etc.
- TCA test discipline: `store.exhaustivity = .off`; assert outcomes/behavior. A TestStore with an in-flight effect at end-of-test fails — every test that triggers `startMaintenance` (a long-running clock effect) or `.ble(.start)` (a long-running driver-stream effect) MUST end by cancelling those effects (drive peer count to 0 → `stopMaintenance`, and/or `.stop`).
- Mutation verification is mandatory for every test-bearing task: (a) tests pass; (b) apply the listed mutations in one batch, run, named tests FAIL; (c) revert, run, pass. Commit only after (c) is green.
- Never chain shell commands (no `&&`, `|`, `;`, `$(...)`, xargs, inline interpreters). One command per Bash invocation. Commit messages via a file under `/tmp/ReTiCA/` (Write tool) + `git commit -F <file>`. Every message ends with these two trailer lines at column 0 (no indent), exactly:

```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
```

After committing verify: `git log -1 --format='%(trailers:key=Claude-Session)'` prints the line. Because the user commits to `main` concurrently, use `<commit>^` (not a pre-recorded base) when reasoning about your own diff.
- Test iteration: `swift test --filter BLEEndpointTests` / `--filter BLEEndpointIntegrationTests`. Run full `swift test` before each commit; failures ONLY in LXMF/core/ReTiCATests files are the user's concurrent WIP — report as an observation, do not fix, and confirm your own filter is green.

---

### Task 1: `BLEEndpoint` reducer + wiring unit tests

**Files:**
- Create: `Sources/ReTiCANode/BLEEndpoint.swift`
- Test: `Tests/ReTiCANodeTests/BLEEndpointTests.swift`

**Interfaces:**
- Consumes: `BLEInterface`, `BLEDriver`, `BLEPairingMode` (from `ReTiCAInterfaces`); `Transport`, `InterfaceID` (from `ReTiCATransport`); `Destination`, `Identity`, `Data.hexString` (from `ReTiCA`).
- Produces (used by Task 2): `BLEEndpoint` reducer; `BLEEndpoint.State(maxPeers:pairingMode:)`; `BLEEndpoint.Action` (`.ble`, `.transport`, `.start`, `.stop`, `.registerLocalDestination`, `.announce`, `.send`, `.enableRelay`, `.delegate`); `BLEEndpoint.Action.Delegate` (`.messageReceived`, `.pathLearned`, `.sendFailed`, `.peerOnline(Data)`, `.peerOffline(Data)`); the free function `bleInterfaceID(_ token: Data) -> InterfaceID`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/BLEEndpointTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport

private let tokenA = Data(repeating: 0xA1, count: 16)
private let tokenB = Data(repeating: 0xB2, count: 16)

@MainActor
private func makeStore() -> TestStore<BLEEndpoint.State, BLEEndpoint.Action> {
    let store = TestStore(initialState: BLEEndpoint.State()) {
        BLEEndpoint()
    } withDependencies: {
        $0.continuousClock = TestClock()
        // Benign driver so `.start`/`.stop` forwarding runs without hitting the
        // unimplemented testValue; the wiring tests inject `.ble(.delegate(...))`
        // directly and never rely on the driver.
        $0.bleDriver = BLEDriver(
            start: { _ in AsyncStream { $0.finish() } },
            readDirectory: { _ in }, openChannel: { _, _ in },
            send: { _, _ in }, closeChannel: { _ in }, stop: { }
        )
    }
    store.exhaustivity = .off
    return store
}

@Test @MainActor func peerOnlineRegistersInterfaceAndStartsMaintenanceOnFirstPeer() async {
    let store = makeStore()
    let idA = bleInterfaceID(tokenA)

    store.send(.ble(.delegate(.peerOnline(tokenA))))
    await store.receive(.transport(.interfaceConnected(idA))) {
        $0.transport.interfaces.insert(idA)
    }
    await store.receive(.delegate(.peerOnline(tokenA)))
    await store.receive(.transport(.startMaintenance))
    #expect(store.state.peerInterfaces[idA] == tokenA)

    // A second peer connects: interfaceConnected fires, but NOT a second startMaintenance.
    let idB = bleInterfaceID(tokenB)
    store.send(.ble(.delegate(.peerOnline(tokenB))))
    await store.receive(.transport(.interfaceConnected(idB))) {
        $0.transport.interfaces.insert(idB)
    }
    await store.receive(.delegate(.peerOnline(tokenB)))
    // (no .startMaintenance here — .off exhaustivity tolerates its absence)

    // Drive both peers offline to cancel the maintenance effect cleanly.
    store.send(.ble(.delegate(.peerOffline(tokenA))))
    await store.receive(.transport(.interfaceDisconnected(idA))) {
        $0.transport.interfaces.remove(idA)
    }
    await store.receive(.delegate(.peerOffline(tokenA)))
    store.send(.ble(.delegate(.peerOffline(tokenB))))
    await store.receive(.transport(.interfaceDisconnected(idB))) {
        $0.transport.interfaces.remove(idB)
    }
    await store.receive(.delegate(.peerOffline(tokenB)))
    await store.receive(.transport(.stopMaintenance))
    #expect(store.state.peerInterfaces.isEmpty)
}

@Test @MainActor func lastPeerOfflineStopsMaintenance() async {
    let store = makeStore()
    let idA = bleInterfaceID(tokenA)
    store.send(.ble(.delegate(.peerOnline(tokenA))))
    await store.receive(.transport(.interfaceConnected(idA))) { $0.transport.interfaces.insert(idA) }
    await store.receive(.delegate(.peerOnline(tokenA)))
    await store.receive(.transport(.startMaintenance))

    store.send(.ble(.delegate(.peerOffline(tokenA))))
    await store.receive(.transport(.interfaceDisconnected(idA))) { $0.transport.interfaces.remove(idA) }
    await store.receive(.delegate(.peerOffline(tokenA)))
    await store.receive(.transport(.stopMaintenance))
}

@Test @MainActor func packetReceivedRoutesToTransportForThatPeersInterface() async {
    let store = makeStore()
    let idA = bleInterfaceID(tokenA)
    // Bring the peer online first (so maintenance can be cancelled at the end).
    store.send(.ble(.delegate(.peerOnline(tokenA))))
    await store.receive(.transport(.interfaceConnected(idA))) { $0.transport.interfaces.insert(idA) }
    await store.receive(.delegate(.peerOnline(tokenA)))
    await store.receive(.transport(.startMaintenance))

    let packet = Data([0x01, 0x02, 0x03])
    store.send(.ble(.delegate(.packetReceived(peer: tokenA, packet: packet))))
    await store.receive(.transport(.received(idA, packet)))

    store.send(.ble(.delegate(.peerOffline(tokenA))))
    await store.receive(.transport(.interfaceDisconnected(idA))) { $0.transport.interfaces.remove(idA) }
    await store.receive(.delegate(.peerOffline(tokenA)))
    await store.receive(.transport(.stopMaintenance))
}

@Test @MainActor func transmitForLivePeerRoutesToBLESendWithRightToken() async {
    let store = makeStore()
    let idA = bleInterfaceID(tokenA)
    store.send(.ble(.delegate(.peerOnline(tokenA))))
    await store.receive(.transport(.interfaceConnected(idA))) { $0.transport.interfaces.insert(idA) }
    await store.receive(.delegate(.peerOnline(tokenA)))
    await store.receive(.transport(.startMaintenance))

    let raw = Data([0xAB, 0xCD])
    store.send(.transport(.delegate(.transmit(idA, raw))))
    await store.receive(.ble(.send(peer: tokenA, packet: raw)))

    store.send(.ble(.delegate(.peerOffline(tokenA))))
    await store.receive(.transport(.interfaceDisconnected(idA))) { $0.transport.interfaces.remove(idA) }
    await store.receive(.delegate(.peerOffline(tokenA)))
    await store.receive(.transport(.stopMaintenance))
}

@Test @MainActor func transmitForUnknownInterfaceIsDropped() async {
    let store = makeStore()
    // No peers online → no peerInterfaces entry. A stray transmit must not route.
    let strayID = InterfaceID("ble:deadbeef")
    store.send(.transport(.delegate(.transmit(strayID, Data([0x01])))))
    // .off tolerates no follow-up; assert no ble.send was produced by finishing clean.
    await store.finish()
}

@Test @MainActor func transportDelegatesForwardToEndpointDelegates() async {
    let store = makeStore()
    let h = Data(repeating: 0x11, count: 16)
    store.send(.transport(.delegate(.pathLearned(destinationHash: h, hops: 3))))
    await store.receive(.delegate(.pathLearned(destinationHash: h, hops: 3)))

    store.send(.transport(.delegate(.received(destinationHash: h, plaintext: Data([0x09])))))
    await store.receive(.delegate(.messageReceived(destinationHash: h, plaintext: Data([0x09]))))

    store.send(.transport(.delegate(.sendFailed(destinationHash: h, reason: .notLearned))))
    await store.receive(.delegate(.sendFailed(destinationHash: h, reason: .notLearned)))
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter BLEEndpointTests`
Expected: compile FAILURE (`BLEEndpoint` not defined).

- [ ] **Step 3: Write `BLEEndpoint.swift`**

Create `Sources/ReTiCANode/BLEEndpoint.swift`:

```swift
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport

/// Deterministic Transport `InterfaceID` for a BLE peer, keyed by its 16-byte session token.
/// Node-local: each node derives IDs from the tokens IT observes, so no cross-node
/// coordination is needed — Transport only requires locally-distinct interface IDs.
public func bleInterfaceID(_ token: Data) -> InterfaceID {
    InterfaceID("ble:" + token.hexString)
}

/// Composes the FCB-backed `BLEInterface` with `Transport`, mapping each connected BLE peer
/// (16-byte session token) to its own Transport `InterfaceID`. Packet plane only: announces,
/// path learning, opportunistic send/receive. Links/resources/requests are follow-ons.
@Reducer
public struct BLEEndpoint {
    @ObservableState
    public struct State: Equatable {
        public var ble: BLEInterface.State
        public var transport: Transport.State
        var peerInterfaces: [InterfaceID: Data] = [:]   // InterfaceID → 16-byte peer token

        public init(maxPeers: Int = BLEInterface.defaultMaxPeers,
                    pairingMode: BLEPairingMode = .open) {
            self.ble = BLEInterface.State(maxPeers: maxPeers, pairingMode: pairingMode)
            self.transport = Transport.State()
        }
    }

    public enum Action: Equatable {
        case ble(BLEInterface.Action)
        case transport(Transport.Action)

        case start
        case stop
        case registerLocalDestination(Destination)
        case announce(destinationHash: Data, appData: Data?)
        case send(destinationHash: Data, plaintext: Data)
        case enableRelay(Identity)

        case delegate(Delegate)
        @CasePathable
        public enum Delegate: Equatable {
            case messageReceived(destinationHash: Data, plaintext: Data)
            case pathLearned(destinationHash: Data, hops: UInt8)
            case sendFailed(destinationHash: Data, reason: Transport.SendFailure)
            case peerOnline(Data)
            case peerOffline(Data)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.ble, action: \.ble) { BLEInterface() }
        Scope(state: \.transport, action: \.transport) { Transport() }
        Reduce { state, action in
            switch action {
            case .start:                            return .send(.ble(.start))
            case .stop:                             return .send(.ble(.stop))
            case let .registerLocalDestination(d):  return .send(.transport(.registerLocalDestination(d)))
            case let .announce(h, a):               return .send(.transport(.announce(destinationHash: h, appData: a)))
            case let .send(h, p):                   return .send(.transport(.send(destinationHash: h, plaintext: p)))
            case let .enableRelay(identity):        return .send(.transport(.setTransportIdentity(identity)))

            // --- BLE peer lifecycle → Transport interface set (+ maintenance) ---
            case let .ble(.delegate(.peerOnline(token))):
                let id = bleInterfaceID(token)
                let wasEmpty = state.peerInterfaces.isEmpty
                state.peerInterfaces[id] = token
                var effects: [Effect<Action>] = [
                    .send(.transport(.interfaceConnected(id))),
                    .send(.delegate(.peerOnline(token))),
                ]
                if wasEmpty { effects.append(.send(.transport(.startMaintenance))) }
                return .merge(effects)

            case let .ble(.delegate(.peerOffline(token))):
                let id = bleInterfaceID(token)
                state.peerInterfaces[id] = nil
                var effects: [Effect<Action>] = [
                    .send(.transport(.interfaceDisconnected(id))),
                    .send(.delegate(.peerOffline(token))),
                ]
                if state.peerInterfaces.isEmpty { effects.append(.send(.transport(.stopMaintenance))) }
                return .merge(effects)

            case let .ble(.delegate(.packetReceived(token, packet))):
                return .send(.transport(.received(bleInterfaceID(token), packet)))

            // --- Transport → BLE ---
            case let .transport(.delegate(.transmit(txID, raw))):
                guard let token = state.peerInterfaces[txID] else { return .none }
                return .send(.ble(.send(peer: token, packet: raw)))

            case let .transport(.delegate(.received(h, p))):
                return .send(.delegate(.messageReceived(destinationHash: h, plaintext: p)))
            case let .transport(.delegate(.pathLearned(h, hops))):
                return .send(.delegate(.pathLearned(destinationHash: h, hops: hops)))
            case let .transport(.delegate(.sendFailed(h, r))):
                return .send(.delegate(.sendFailed(destinationHash: h, reason: r)))

            case .ble, .transport, .delegate:
                return .none
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BLEEndpointTests`
Expected: all 6 PASS. (If a test hangs or fails on an in-flight effect, confirm every peerOnline is matched by a peerOffline to cancel maintenance.)

- [ ] **Step 5: Mutation verification (batch)**

Apply all four mutations at once to `BLEEndpoint.swift`:
1. In `.peerOnline`, change `let wasEmpty = state.peerInterfaces.isEmpty` to `let wasEmpty = false` (never starts maintenance).
2. In `.peerOffline`, change the trailing `if state.peerInterfaces.isEmpty` to `if false` (never stops maintenance).
3. In `.packetReceived`, change `bleInterfaceID(token)` to `InterfaceID("wrong")`.
4. In `.transmit`, delete the `guard let token = ... else { return .none }` and hardcode `return .send(.ble(.send(peer: Data(), packet: raw)))`.

Run: `swift test --filter BLEEndpointTests`
Expected: `peerOnlineRegistersInterface...`/`lastPeerOfflineStopsMaintenance` (1,2), `packetReceivedRoutes...` (3), `transmitForLivePeer...` + `transmitForUnknownInterfaceIsDropped` (4) FAIL. If any of those still passes, fix the test. Revert all four; re-run — all PASS. Then `swift test` — full suite green (BLEEndpoint tests + existing; LXMF/core WIP failures are the user's, note but don't fix).

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCA/task1-msg.txt` (subject `feat: BLEEndpoint wiring BLEInterface to Transport with per-peer InterfaceID`), then:

```bash
git add Sources/ReTiCANode/BLEEndpoint.swift Tests/ReTiCANodeTests/BLEEndpointTests.swift
git commit -F /tmp/ReTiCA/task1-msg.txt
```

---

### Task 2: Directional integration tests over the BLE seam

**Files:**
- Test: `Tests/ReTiCANodeTests/BLEEndpointIntegrationTests.swift`

**Interfaces:**
- Consumes: `BLEEndpoint` + `bleInterfaceID` (Task 1); `BLEInterface.protocolVersion`, `BLEDriver`, `BLEDriverEvent`, `BLEChannelID`, `BLEPeerHandle`, `BLEChannelDirection`, `BLEHello`, `BLEFraming` (from `ReTiCAInterfaces`); `Identity`, `Destination`, `Packet`, `Announce` (from `ReTiCA`).
- Produces: nothing (tests only).

**Why two single-store directional tests (not one 2-node bridge):** what is NEW in `BLEEndpoint` is the BLE seam — framing/deframing across the driver boundary and per-peer `InterfaceID` routing. Cross-node crypto interop is interface-agnostic and already proven by the TCP 2-node `EndpointTests`. Two single-store tests with crafted packets exercise the seam deterministically without a fragile double-node bridge.

- [ ] **Step 1: Write the tests**

Create `Tests/ReTiCANodeTests/BLEEndpointIntegrationTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// A framed HELLO carrying `token` (the wire form the peer sends first on a channel).
private func framedHello(_ token: Data) -> Data {
    try! BLEFraming.frame(BLEHello.pack(version: BLEInterface.protocolVersion, token: token))
}

// Build a raw HEADER_1 ANNOUNCE packet for a synthetic identity (copied from EndpointTests).
private func makeAnnouncePacket(identity: Identity, appName: String, aspects: [String],
                                hops: UInt8, emitted: UInt64, appData: Data? = nil) -> (Data, Data) {
    let nameHash = Destination.nameHash(appName: appName, aspects: aspects)
    let destHash = Destination.hash(identityHash: identity.hash, appName: appName, aspects: aspects)
    let randomHash = Announce.randomHash(now: emitted, randomPrefix: Data(repeating: 0xA5, count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, appData: appData)
    let packet = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: hops,
                        destinationHash: destHash, transportId: nil, payload: payload)
    return (try! packet.packed(), destHash)
}

private let ownToken  = Data(repeating: 0x5A, count: 16)   // the node's own session token
private let peerToken = Data(repeating: 0xC7, count: 16)   // the connected peer's token (≠ own)
private let channel   = BLEChannelID(id: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!)
private let handle    = BLEPeerHandle(id: UUID(uuidString: "22222222-0000-0000-0000-000000000002")!)

/// A single BLEEndpoint store with a controllable mock driver.
@MainActor
private func makeNode() -> (TestStore<BLEEndpoint.State, BLEEndpoint.Action>,
                            AsyncStream<BLEDriverEvent>.Continuation) {
    let events = AsyncStream<BLEDriverEvent>.makeStream()
    let store = TestStore(initialState: BLEEndpoint.State()) {
        BLEEndpoint()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
        $0.bleRandomBytes = BLERandomBytesGenerator { _ in ownToken }
        $0.bleDriver = BLEDriver(
            start: { _ in events.stream },
            readDirectory: { _ in }, openChannel: { _, _ in },
            send: { _, _ in }, closeChannel: { _ in }, stop: { }
        )
    }
    store.exhaustivity = .off
    return (store, events.continuation)
}

/// Start the node and bring one inbound peer (token `peerToken`) online through the
/// real BLEInterface handshake. `.off` receive fast-forwards through the intermediate
/// driverEvent/delegate actions to the endpoint-level `interfaceConnected`.
@MainActor
private func bringPeerOnline(_ store: TestStore<BLEEndpoint.State, BLEEndpoint.Action>,
                            _ events: AsyncStream<BLEDriverEvent>.Continuation) async {
    await store.send(.start)
    events.yield(.channelOpened(channel, handle, direction: .inbound))
    events.yield(.channelData(channel, framedHello(peerToken)))
    await store.receive { if case .transport(.interfaceConnected) = $0 { return true }; return false }
    #expect(store.state.transport.interfaces.contains(bleInterfaceID(peerToken)))
}

/// Cancel the driver stream + maintenance: `.stop` emits `peerOffline`, whose cascade
/// reaches `stopMaintenance`; fast-forward to it.
@MainActor
private func teardown(_ store: TestStore<BLEEndpoint.State, BLEEndpoint.Action>) async {
    await store.send(.stop)
    await store.receive { if case .transport(.stopMaintenance) = $0 { return true }; return false }
}

@Test @MainActor func inboundDataPacketOverBLESurfacesMessageReceived() async {
    let (store, events) = makeNode()
    await bringPeerOnline(store, events)

    // A local destination we own, and a data packet encrypted to it.
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["inbox"],
                           identity: Identity())!
    let plaintext = Data("hello over ble".utf8)
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: dest.hash, transportId: nil, payload: dest.encrypt(plaintext))
    await store.send(.registerLocalDestination(dest))

    // Deliver the crafted packet as framed channel data on the peer's channel.
    events.yield(.channelData(channel, try! BLEFraming.frame(try! packet.packed())))
    let got = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.messageReceived(_, p)) = action { got.setValue(p); return true }
        return false
    }
    #expect(got.value == plaintext)

    await teardown(store)
}

@Test @MainActor func outboundOpportunisticSendRoutesThroughBLEToThePeer() async {
    let (store, events) = makeNode()
    await bringPeerOnline(store, events)

    // Learn a destination from a crafted announce delivered over the peer channel.
    let remote = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: remote, appName: "app",
                                                     aspects: ["svc"], hops: 2, emitted: 1000)
    events.yield(.channelData(channel, try! BLEFraming.frame(announceRaw)))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    #expect(store.state.transport.learned[destHash]?.identity.hash == remote.hash)
    #expect(store.state.transport.learned[destHash]?.interfaceID == bleInterfaceID(peerToken))

    // Opportunistic send → routes through Transport → transmit → ble.send for THIS peer.
    let captured = LockIsolated<(Data, Data)?>(nil)   // (peerToken, raw packet)
    await store.send(.send(destinationHash: destHash, plaintext: Data("ping".utf8)))
    await store.receive { action in
        if case let .ble(.send(peer, packet)) = action { captured.setValue((peer, packet)); return true }
        return false
    }
    #expect(captured.value?.0 == peerToken)
    let outPacket = Packet(raw: captured.value!.1)
    #expect(outPacket?.packetType == .data)
    #expect(outPacket?.destinationHash == destHash)

    await teardown(store)
}
```

- [ ] **Step 2: Run to verify they pass**

Run: `swift test --filter BLEEndpointIntegrationTests`
Expected: both PASS. (If a test fails on an in-flight effect at teardown, confirm `.stop`'s `peerOffline` cascade reaches `stopMaintenance` — the fast-forward `receive` must reduce it. If the driver-handshake `receive` can't find `interfaceConnected`, confirm `BLERandomBytesGenerator` yields `ownToken` so the injected HELLO's `peerToken` differs from the node's own token and is accepted.)

- [ ] **Step 3: Mutation verification (batch)**

Apply both mutations at once to `Sources/ReTiCANode/BLEEndpoint.swift`:
1. In the `.ble(.delegate(.packetReceived))` edge, replace the body with `return .none` (inbound packets never reach Transport).
2. In the `.transport(.delegate(.transmit))` edge, replace the body with `return .send(.ble(.send(peer: Data(), packet: raw)))` (route every transmit to an empty/wrong peer).

Run: `swift test --filter BLEEndpointIntegrationTests`
Expected: `inboundDataPacketOverBLESurfacesMessageReceived` FAILS (mutation 1 — no `packetReceived` forwarding, so no `messageReceived`); `outboundOpportunisticSendRoutesThroughBLEToThePeer` FAILS (mutation 1 — the crafted announce never reaches Transport, so no `pathLearned`; and independently mutation 2 — the captured peer is `Data()`, not `peerToken`). If either still passes, the test isn't exercising that edge — fix it. Revert both; re-run — both PASS. Then `swift test` — full suite green (LXMF/core WIP failures are the user's; note, don't fix).

- [ ] **Step 4: Commit**

Write `/tmp/ReTiCA/task2-msg.txt` (subject `test: BLEEndpoint directional integration tests over the BLE seam`), then:

```bash
git add Tests/ReTiCANodeTests/BLEEndpointIntegrationTests.swift
git commit -F /tmp/ReTiCA/task2-msg.txt
```

---

## Final verification (after Task 2)

- [ ] `swift test --filter BLEEndpoint` — all `BLEEndpointTests` + `BLEEndpointIntegrationTests` green.
- [ ] `swift test` — full suite green except any pre-existing LXMF/core WIP failures (the user's concurrent work; confirm none are in `ReTiCANode`/`ReTiCAInterfaces`/`ReTiCATransport` code you touched).
- [ ] `git log --format='%(trailers:key=Claude-Session)' -2` — both task commits' trailers parse.
- [ ] Confirm no changes leaked outside `Sources/ReTiCANode/BLEEndpoint.swift` and `Tests/ReTiCANodeTests/BLEEndpoint*.swift`.

