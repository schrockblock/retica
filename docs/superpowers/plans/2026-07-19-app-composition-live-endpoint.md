# App Composition (ReTiCANode) + Live Endpoint Proof Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `ReTiCANode` target with an `Endpoint` reducer that composes `TCPClientInterface` (#3) and `Transport` (#4) into one working endpoint, plus a deterministic `TestStore` wiring suite and an off-by-default live integration test against a real Reticulum node.

**Architecture:** `Endpoint` is a `@Reducer` that `Scope`s the interface and transport child reducers and adds a parent `Reduce` that wires their delegates bidirectionally: interface `packetReceived` → `transport.received`, `connectionEvent(.connected/.disconnected)` → `transport.interfaceConnected/Disconnected`, `transport.delegate(.transmit)` → `interface.send`, and transport delivery/pathLearned/sendFailed bubble up as `Endpoint.delegate`. Single TCP interface this slice.

**Tech Stack:** Swift 6.3 / Swift 6 language mode, Swift Testing + TCA `TestStore`, The Composable Architecture (~1.26), building on `ReTiCAInterfaces` + `ReTiCATransport`.

## Global Constraints

- **Toolchain:** swift-tools-version 6.3; `swiftLanguageModes: [.v6]`.
- **Test framework:** Swift Testing; TCA reducer tests use `TestStore` (`@MainActor`, non-exhaustive where child internals are incidental). Run with `swift test`.
- **`ReTiCA` core stays dependency-free.** TCA remains only in non-core targets. `ReTiCANode` depends on `ReTiCAInterfaces` + `ReTiCATransport` (+ core + TCA).
- **Single TCP interface** this slice (multi-interface deferred).
- **The live test is OFF by default** — gated on `RETICA_LIVE_HOST`; never a CI gate.
- **Platform floor iOS 16 / macOS 13 / tvOS 16 / watchOS 9 / Mac Catalyst 16.**
- **Value semantics;** the reducer is a `struct @Reducer`. No shared mutable global state.
- **Mutation-testing discipline** after each task.

---

## File Structure

```
Package.swift (modified in Task 1)
Sources/ReTiCANode/Endpoint.swift            (Task 1) — @Reducer composition
Tests/ReTiCANodeTests/EndpointTests.swift    (Task 1) — deterministic TestStore wiring tests
Tests/ReTiCANodeTests/LiveEndpointTests.swift (Task 2) — off-by-default live integration test
README.md (Task 3)
```

---

### Task 1: ReTiCANode target + Endpoint reducer + wiring tests

**Files:**
- Modify: `Package.swift`
- Create: `Sources/ReTiCANode/Endpoint.swift`
- Test: `Tests/ReTiCANodeTests/EndpointTests.swift`

**Interfaces:**
- Consumes: `TCPClientInterface` (`.State(host:port:reconnectOnDrop:)`, `.Action` incl. `.connect`/`.disconnect`/`.connectionEvent(TCPEvent)`/`.send(Data)`/`.delegate(.packetReceived(Data))`), `Transport` (`.State()`, `.Action` incl. `.interfaceConnected`/`.received`/`.announce`/`.send`/`.delegate(...)`, `.SendFailure`), `InterfaceID`, `TCPConnection`/`TCPEvent`, `HDLC`, `Announce`/`Destination`/`Packet`/`Identity`/`Crypto` (core), ComposableArchitecture.
- Produces: `@Reducer struct Endpoint` with `State(host:port:reconnectOnDrop:interfaceID:)`, `Action` (`.interface`/`.transport`/`.connect`/`.disconnect`/`.registerLocalDestination`/`.announce`/`.send`/`.delegate`), `Delegate` (`.messageReceived`/`.pathLearned`/`.sendFailed`).

- [ ] **Step 1: Modify Package.swift**

Add the product, target, and test target (keep everything else). New `products` entry (after the `ReTiCATransport` library):

```swift
        .library(name: "ReTiCANode", targets: ["ReTiCANode"]),
```

New `targets` entries (after the `ReTiCATransport` target and its test target):

```swift
        .target(
            name: "ReTiCANode",
            dependencies: [
                "ReTiCAInterfaces",
                "ReTiCATransport",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .testTarget(
            name: "ReTiCANodeTests",
            dependencies: [
                "ReTiCANode",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
```

- [ ] **Step 2: Write the failing tests**

`Tests/ReTiCANodeTests/EndpointTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Build a raw HEADER_1 ANNOUNCE packet for a synthetic identity.
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

// Mock TCPConnection returning a caller-driven event stream; ends cleanly via continuation.finish().
private func makeStore(host: String = "node", port: UInt16 = 4242)
    -> (TestStore<Endpoint.State, Endpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
    let events = AsyncStream<TCPEvent>.makeStream()
    let store = TestStore(
        initialState: Endpoint.State(host: host, port: port, reconnectOnDrop: false)
    ) {
        Endpoint()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in events.stream }, send: { _ in }, close: { })
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    return (store, events.continuation)
}

@Test @MainActor func connectWiresInterfaceOnlineToTransportInterfaceConnected() async {
    let (store, events) = makeStore()
    await store.send(.connect)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)
    #expect(store.state.transport.interfaces.contains(store.state.interfaceID))
    #expect(store.state.interface.status == .online)
    await store.send(.disconnect)
    await store.receive(\.interface.disconnect)
}

@Test @MainActor func inboundAnnounceIsLearnedAndBubblesPathLearned() async {
    let (store, events) = makeStore()
    let id = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                                     hops: 3, emitted: 1000, appData: Data("meta".utf8))
    await store.send(.connect)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    events.yield(.data(HDLC.frame(announceRaw)))
    await store.receive(\.delegate.pathLearned)
    #expect(store.state.transport.learned[destHash]?.identity.hash == id.hash)
    #expect(store.state.transport.learned[destHash]?.hops == 3)
    #expect(store.state.transport.learned[destHash]?.interfaceID == store.state.interfaceID)
    await store.send(.disconnect)
    await store.receive(\.interface.disconnect)
}

@Test @MainActor func inboundDataToLocalDestinationBubblesMessageReceived() async {
    let (store, events) = makeStore()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["inbox"],
                           identity: Identity())!
    let plaintext = Data("hello".utf8)
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: dest.hash, transportId: nil, payload: dest.encrypt(plaintext))

    await store.send(.registerLocalDestination(dest))
    await store.send(.connect)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    events.yield(.data(HDLC.frame(try! packet.packed())))
    let captured = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.messageReceived(_, p)) = action { captured.setValue(p); return true }
        return false
    }
    #expect(captured.value == plaintext)
    await store.send(.disconnect)
    await store.receive(\.interface.disconnect)
}

@Test @MainActor func outboundAnnounceReachesInterfaceSendAsValidPacket() async {
    let (store, events) = makeStore()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["me"],
                           identity: Identity())!
    await store.send(.registerLocalDestination(dest))
    await store.send(.connect)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    // Capture the raw packet bytes forwarded to the interface's .send (unframed).
    let captured = LockIsolated<Data?>(nil)
    await store.send(.announce(destinationHash: dest.hash, appData: nil))
    await store.receive { action in
        if case let .interface(.send(raw)) = action { captured.setValue(raw); return true }
        return false
    }
    let packet = Packet(raw: captured.value!)!
    #expect(packet.packetType == .announce)
    #expect(packet.destinationHash == dest.hash)
    let parsed = Announce.parse(payload: packet.payload, destinationHash: dest.hash,
                                contextFlagSet: packet.contextFlag)
    #expect(parsed?.identity.hash == dest.identity!.hash)
    await store.send(.disconnect)
    await store.receive(\.interface.disconnect)
}

@Test @MainActor func sendToUnlearnedDestinationBubblesSendFailed() async {
    let (store, events) = makeStore()
    let destHash = Data(repeating: 0x33, count: 16)
    await store.send(.connect)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    await store.send(.send(destinationHash: destHash, plaintext: Data("x".utf8)))
    await store.receive(.delegate(.sendFailed(destinationHash: destHash, reason: .notLearned)))
    await store.send(.disconnect)
    await store.receive(\.interface.disconnect)
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter EndpointTests`
Expected: FAIL — `Endpoint` / `ReTiCANode` not defined.

- [ ] **Step 4: Write minimal implementation**

`Sources/ReTiCANode/Endpoint.swift`:

```swift
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport

/// Composes a `TCPClientInterface` and a `Transport` into a single runnable Reticulum
/// endpoint, wiring their delegates bidirectionally. Single TCP interface this slice.
@Reducer
public struct Endpoint {
    @ObservableState
    public struct State: Equatable {
        public var interface: TCPClientInterface.State
        public var transport: Transport.State
        public let interfaceID: InterfaceID

        public init(host: String, port: UInt16, reconnectOnDrop: Bool = true,
                    interfaceID: InterfaceID = InterfaceID("tcp")) {
            self.interface = TCPClientInterface.State(host: host, port: port,
                                                      reconnectOnDrop: reconnectOnDrop)
            self.transport = Transport.State()
            self.interfaceID = interfaceID
        }
    }

    public enum Action: Equatable {
        case interface(TCPClientInterface.Action)
        case transport(Transport.Action)

        case connect
        case disconnect
        case registerLocalDestination(Destination)
        case announce(destinationHash: Data, appData: Data?)
        case send(destinationHash: Data, plaintext: Data)

        case delegate(Delegate)
        @CasePathable
        public enum Delegate: Equatable {
            case messageReceived(destinationHash: Data, plaintext: Data)
            case pathLearned(destinationHash: Data, hops: UInt8)
            case sendFailed(destinationHash: Data, reason: Transport.SendFailure)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.interface, action: \.interface) { TCPClientInterface() }
        Scope(state: \.transport, action: \.transport) { Transport() }
        Reduce { state, action in
            let id = state.interfaceID
            switch action {
            case .connect:                          return .send(.interface(.connect))
            case .disconnect:                       return .send(.interface(.disconnect))
            case let .registerLocalDestination(d):  return .send(.transport(.registerLocalDestination(d)))
            case let .announce(h, a):               return .send(.transport(.announce(destinationHash: h, appData: a)))
            case let .send(h, p):                   return .send(.transport(.send(destinationHash: h, plaintext: p)))

            case let .interface(.delegate(.packetReceived(data))):
                return .send(.transport(.received(id, data)))
            case .interface(.connectionEvent(.connected)):
                return .send(.transport(.interfaceConnected(id)))
            case .interface(.connectionEvent(.disconnected)):
                return .send(.transport(.interfaceDisconnected(id)))

            case let .transport(.delegate(.transmit(txID, raw))):
                guard txID == id else { return .none }
                return .send(.interface(.send(raw)))
            case let .transport(.delegate(.received(h, p))):
                return .send(.delegate(.messageReceived(destinationHash: h, plaintext: p)))
            case let .transport(.delegate(.pathLearned(h, hops))):
                return .send(.delegate(.pathLearned(destinationHash: h, hops: hops)))
            case let .transport(.delegate(.sendFailed(h, r))):
                return .send(.delegate(.sendFailed(destinationHash: h, reason: r)))

            case .interface, .transport, .delegate:
                return .none
            }
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter EndpointTests`
Expected: PASS (5 tests). First build links ReTiCAInterfaces + ReTiCATransport.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/ReTiCANode Tests/ReTiCANodeTests/EndpointTests.swift
git commit -m "feat: ReTiCANode Endpoint reducer composing interface + transport"
```

---

### Task 2: Live integration test (off by default)

**Files:**
- Create: `Tests/ReTiCANodeTests/LiveEndpointTests.swift`

**Interfaces:**
- Consumes: `Endpoint` (live dependencies), a real `Store`.
- Produces: one opt-in test gated on `RETICA_LIVE_HOST`.

- [ ] **Step 1: Write the test**

`Tests/ReTiCANodeTests/LiveEndpointTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCATransport

/// End-to-end proof against a real Reticulum TCP node. OFF by default; runs only when
/// RETICA_LIVE_HOST is set. Point it at a local `rnsd` running a TCPServerInterface, or a
/// public testnet node:
///   RETICA_LIVE_HOST=127.0.0.1 RETICA_LIVE_PORT=4242 swift test --filter LiveEndpoint
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["RETICA_LIVE_HOST"] != nil))
func liveEndpointLearnsAnnouncesFromRealNode() async throws {
    let host = ProcessInfo.processInfo.environment["RETICA_LIVE_HOST"]!
    let port = UInt16(ProcessInfo.processInfo.environment["RETICA_LIVE_PORT"] ?? "4242") ?? 4242

    let store = Store(initialState: Endpoint.State(host: host, port: port, reconnectOnDrop: true)) {
        Endpoint()
    }
    store.send(.connect)

    // Real Reticulum nodes announce periodically; wait a bounded window for the path table to fill.
    try await Task.sleep(for: .seconds(10))

    #expect(!store.state.transport.learned.isEmpty,
            "Expected to learn at least one announce from \(host):\(port) within 10s")
    store.send(.disconnect)
}
```

- [ ] **Step 2: Verify it is skipped by default**

Run: `swift test --filter LiveEndpoint`
Expected: the test is SKIPPED (no `RETICA_LIVE_HOST` in the environment) — reported as skipped, not failed. The suite stays green.

- [ ] **Step 3: (Optional, manual) run it against a real node**

If a Reticulum TCP node is reachable:
Run: `RETICA_LIVE_HOST=<host> RETICA_LIVE_PORT=<port> swift test --filter LiveEndpoint`
Expected: PASS — `transport.learned` is non-empty (real announces learned). This step is manual and not part of the automated gate.

- [ ] **Step 4: Commit**

```bash
git add Tests/ReTiCANodeTests/LiveEndpointTests.swift
git commit -m "test: off-by-default live endpoint integration against a real node"
```

---

### Task 3: Full suite + mutation gate + README

**Files:** `README.md` (modify); no new source.

- [ ] **Step 1: Run the full suite**

Run: `swift test`
Expected: PASS — all targets (core, interfaces, transport, node); the live test is skipped; pristine output.

- [ ] **Step 2: Mutation sweep (project convention)**

Batch-mutate one production line per wiring path in `Endpoint.swift`, run `swift test` once, confirm the covering tests fail, then revert all and confirm green. Commit nothing with mutations. Suggested mutations:
- `.interface(.connectionEvent(.connected))` wiring: return `.none` instead of `.send(.transport(.interfaceConnected(id)))` (breaks `connectWiresInterfaceOnlineToTransportInterfaceConnected`).
- `.interface(.delegate(.packetReceived))` wiring: return `.none` (breaks `inboundAnnounceIsLearnedAndBubblesPathLearned`).
- `.transport(.delegate(.transmit))` guard: change `txID == id` to `txID != id` (breaks `outboundAnnounceReachesInterfaceSendAsValidPacket`).
- `.transport(.delegate(.received))` bubble-up: return `.none` (breaks `inboundDataToLocalDestinationBubblesMessageReceived`).
- `.transport(.delegate(.sendFailed))` bubble-up: return `.none` (breaks `sendToUnlearnedDestinationBubblesSendFailed`).
Record which tests fail per mutation. If any mutation is not caught, add a covering test. Revert all; confirm green.

- [ ] **Step 3: Update the README**

Add a "Sub-project #5: App composition (ReTiCANode)" section:

```markdown
## App composition: `ReTiCANode`

`ReTiCANode` assembles the stack into a working endpoint. The `Endpoint` reducer composes `TCPClientInterface` (interfaces) and `Transport` (routing), wiring them bidirectionally:

- inbound: interface deframes → `Transport.received` → learn / deliver → `Endpoint.delegate(.messageReceived / .pathLearned)`
- outbound: `Endpoint.send`/`.announce` → `Transport` → `.transmit` → `interface.send` → socket
- lifecycle: `.connect` → `interfaceConnected`

This is the first target that runs the whole stack. A `Store<Endpoint>` connected to a real Reticulum TCP node populates its path table from real network announces.

### Live endpoint test (opt-in)

`LiveEndpointTests` is skipped unless `RETICA_LIVE_HOST` is set. To run it against a real node (e.g. a local `rnsd` with a `TCPServerInterface`, or a testnet node):

```
RETICA_LIVE_HOST=127.0.0.1 RETICA_LIVE_PORT=4242 swift test --filter LiveEndpoint
```

### Products
- **`ReTiCA`** — pure Swift core (crypto, Identity, Packet, Destination, Announce, HDLC). Zero third-party dependencies.
- **`ReTiCAInterfaces`** — TCA TCP-client interface (Network.framework).
- **`ReTiCATransport`** — TCA endpoint-core Transport (interface-agnostic).
- **`ReTiCANode`** — composition of interface + transport into a working endpoint.
```

Update "Not Yet Implemented" to keep transport-node relaying, path requests, links, and resources; note multi-interface composition as future.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document ReTiCANode app composition and live endpoint test"
```

---

## Self-Review

**Spec coverage:**
- New `ReTiCANode` target depending on interfaces + transport → Task 1.
- `Endpoint` reducer: state (interface/transport/interfaceID), app-sugar actions, bidirectional wiring, delegate bubble-up → Task 1.
- Deterministic `TestStore` wiring tests (connect→interfaceConnected, inbound announce→learn+pathLearned, inbound data→messageReceived, outbound announce→interface.send valid packet, send-unlearned→sendFailed) → Task 1.
- Off-by-default live integration test gated on `RETICA_LIVE_HOST` → Task 2.
- Full-suite + mutation gate + README (incl. live-test instructions + products) → Task 3.
- Deferred (multi-interface, relaying, path requests, links, resources) → not built, per scope.

**Placeholder scan:** No TBD/TODO; every code step has complete code; every command has expected output.

**Type consistency:** `Endpoint.State(host:port:reconnectOnDrop:interfaceID:)`, `Endpoint.Action`/`.Delegate`, and the child action case-paths (`\.interface.…`, `\.transport.…`) are consistent across Tasks 1–2; `TCPClientInterface.State/Action`, `TCPEvent`, `TCPConnection(open:send:close:)`, `Transport.State/Action/.SendFailure`, `InterfaceID`, `HDLC.frame`, `Announce.buildPayload/parse/randomHash`, `Destination.hash/nameHash/encrypt`, `Packet.init/init?(raw:)/packed()`, `Identity.hash/encrypt` match the merged APIs; `Store<Endpoint>` live usage in Task 2 matches the `Endpoint.State` init.

**Decisions recorded:** single TCP interface (multi deferred); parent `Reduce` after child `Scope`s so children process first; tests use non-exhaustive `TestStore` with `reconnectOnDrop: false` and end by finishing the mock stream; `Endpoint.Action`/`.Delegate` are `Equatable` (+ `@CasePathable` on `Delegate`) for clean `TestStore` receives; live test uses a real `Store` with live dependencies, gated on `RETICA_LIVE_HOST`.
