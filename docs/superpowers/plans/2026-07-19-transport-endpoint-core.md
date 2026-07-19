# Transport — Endpoint Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an interface-agnostic TCA `Transport` reducer (new `ReTiCATransport` target) that ingests announces into a path/known-destination table, delivers inbound packets to local destinations, and routes outbound packets to learned destinations — the endpoint (leaf) subset of RNS Transport.

**Architecture:** `Transport` is a `@Reducer` over pure-core value types (`Packet`, `Destination`, `Announce`, `Identity`). Interfaces are referenced by an opaque `InterfaceID`; inbound bytes arrive as `.received(InterfaceID, Data)` and outbound bytes leave as `.delegate(.transmit(InterfaceID, Data))`, so a thin app layer wires Transport ↔ #3's interface reducers. State holds the learned path/identity table, local destinations, connected interfaces, and a bounded dedup set. No Network.framework dependency.

**Tech Stack:** Swift 6.3 / Swift 6 language mode, Swift Testing + TCA `TestStore`, The Composable Architecture (~1.26), building on the `ReTiCA` core.

## Global Constraints

- **Toolchain:** swift-tools-version 6.3; `swiftLanguageModes: [.v6]`.
- **Test framework:** Swift Testing (`import Testing`, `@Test`, `#expect`); TCA reducer tests use `TestStore` (`@MainActor`). Run with `swift test`.
- **`ReTiCA` core stays dependency-free.** TCA appears only in `ReTiCATransport` (+ its tests) and the existing `ReTiCAInterfaces`.
- **`ReTiCATransport` has NO Network.framework dependency** — interface-agnostic (`InterfaceID` handles).
- **Byte-exact with the reference** where applicable: path learning uses `received_from = transport_id ?? destination_hash`; `announceEmitted = bigEndian(randomHash[5..<10])`; drop packets with duplicate `packetHash`; inbound DATA delivers only to a local destination whose `kind` matches the packet's `destinationType`; leaf outbound is a HEADER_1 DATA packet on the interface that heard the announce.
- **Platform floor iOS 16 / macOS 13 / tvOS 16 / watchOS 9 / Mac Catalyst 16** (set in #3).
- **Value semantics;** the reducer is a `struct @Reducer`. No shared mutable global state.
- **Mutation-testing discipline** after each task.

---

## File Structure

```
Package.swift  (modified in Task 1)
Sources/ReTiCA/Destination/Destination.swift  (Task 1: add `: Equatable`)
Sources/ReTiCATransport/
  InterfaceID.swift          (Task 1)
  RingSet.swift              (Task 1) — bounded dedup set
  LearnedDestination.swift   (Task 1)
  Transport.swift            (Tasks 2–5) — the @Reducer
Tests/ReTiCATransportTests/
  TransportTests.swift               (Tasks 2–5)
  Vectors/
    generate_transport_fixtures.py   (Task 6)
    transport_fixtures.json          (Task 6, generated)
    TransportVectorFixtures.swift    (Task 6)
    TransportCrossValidationTests.swift (Task 6)
Tests/ReTiCATests/Framing/... (unchanged)
README.md (Task 7)
```

---

### Task 1: Package target + value types + `Destination: Equatable`

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/ReTiCA/Destination/Destination.swift` (add `Equatable`)
- Create: `Sources/ReTiCATransport/InterfaceID.swift`
- Create: `Sources/ReTiCATransport/RingSet.swift`
- Create: `Sources/ReTiCATransport/LearnedDestination.swift`
- Test: `Tests/ReTiCATransportTests/TransportTests.swift` (foundation tests)

**Interfaces:**
- Consumes: `Identity`, `Data` (core).
- Produces:
  - `struct InterfaceID: Hashable, Sendable { let rawValue: String; init(_:) }`
  - `struct RingSet: Equatable { init(capacity: Int = 1000); mutating func insert(_ item: Data) -> Bool; func contains(_ item: Data) -> Bool }`
  - `struct LearnedDestination: Equatable, Sendable { identity: Identity; appData: Data?; ratchet: Data?; interfaceID: InterfaceID; hops: UInt8; nextHop: Data?; announceEmitted: UInt64 }`
  - `Destination: Equatable`

- [ ] **Step 1: Modify Package.swift**

Add the product, target, and test target (keep everything else). New `products` entry, new `targets` entries:

```swift
        .library(name: "ReTiCATransport", targets: ["ReTiCATransport"]),
```
```swift
        .target(
            name: "ReTiCATransport",
            dependencies: [
                "ReTiCA",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .testTarget(
            name: "ReTiCATransportTests",
            dependencies: [
                "ReTiCATransport",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
```

(Insert the `.library` after the `ReTiCAInterfaces` library, and the two targets after the `ReTiCAInterfaces` target / its test target. Do not remove existing entries.)

- [ ] **Step 2: Write the failing tests**

`Tests/ReTiCATransportTests/TransportTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

@Test func ringSetInsertReportsNoveltyAndDedups() {
    var set = RingSet(capacity: 3)
    #expect(set.insert(Data([1])) == true)
    #expect(set.insert(Data([1])) == false) // duplicate
    #expect(set.contains(Data([1])) == true)
}

@Test func ringSetEvictsOldestPastCapacity() {
    var set = RingSet(capacity: 2)
    _ = set.insert(Data([1]))
    _ = set.insert(Data([2]))
    _ = set.insert(Data([3]))          // evicts Data([1])
    #expect(set.contains(Data([1])) == false)
    #expect(set.contains(Data([2])) == true)
    #expect(set.contains(Data([3])) == true)
}

@Test func interfaceIDIsHashable() {
    #expect(InterfaceID("a") == InterfaceID("a"))
    #expect(Set([InterfaceID("a"), InterfaceID("a"), InterfaceID("b")]).count == 2)
}

@Test func destinationIsEquatable() {
    let id = Identity()
    let a = Destination(kind: .single, direction: .in, appName: "app", aspects: ["x"], identity: id)
    let b = Destination(kind: .single, direction: .in, appName: "app", aspects: ["x"], identity: id)
    #expect(a == b)
}

@Test func learnedDestinationIsEquatable() {
    let id = Identity()
    let a = LearnedDestination(identity: id, appData: nil, ratchet: nil,
                               interfaceID: InterfaceID("i"), hops: 2, nextHop: nil, announceEmitted: 10)
    let b = a
    #expect(a == b)
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter TransportTests`
Expected: FAIL — `ReTiCATransport` / types not defined (and `Destination` not yet Equatable).

- [ ] **Step 4: Write minimal implementation**

Edit `Sources/ReTiCA/Destination/Destination.swift` line 5: change
`public struct Destination {` → `public struct Destination: Equatable {`

`Sources/ReTiCATransport/InterfaceID.swift`:

```swift
import Foundation

/// Opaque handle identifying an interface, so Transport stays decoupled from the
/// concrete interface type.
public struct InterfaceID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}
```

`Sources/ReTiCATransport/RingSet.swift`:

```swift
import Foundation

/// A bounded, insertion-ordered set. `insert` returns whether the item was new; once the
/// capacity is exceeded the oldest item is evicted. Used to suppress duplicate packets.
public struct RingSet: Equatable {
    private var items: Set<Data> = []
    private var order: [Data] = []
    private let capacity: Int

    public init(capacity: Int = 1000) { self.capacity = capacity }

    @discardableResult
    public mutating func insert(_ item: Data) -> Bool {
        guard !items.contains(item) else { return false }
        items.insert(item)
        order.append(item)
        if order.count > capacity {
            let evicted = order.removeFirst()
            items.remove(evicted)
        }
        return true
    }

    public func contains(_ item: Data) -> Bool { items.contains(item) }
}
```

`Sources/ReTiCATransport/LearnedDestination.swift`:

```swift
import Foundation
import ReTiCA

/// A destination learned from an announce: its identity (public), plus routing info.
public struct LearnedDestination: Equatable, Sendable {
    public var identity: Identity     // public-only, recovered from the announce
    public var appData: Data?
    public var ratchet: Data?         // received 32-byte ratchet public key, or nil
    public var interfaceID: InterfaceID
    public var hops: UInt8
    public var nextHop: Data?         // transport_id, or nil if directly heard
    public var announceEmitted: UInt64

    public init(identity: Identity, appData: Data?, ratchet: Data?, interfaceID: InterfaceID,
                hops: UInt8, nextHop: Data?, announceEmitted: UInt64) {
        self.identity = identity
        self.appData = appData
        self.ratchet = ratchet
        self.interfaceID = interfaceID
        self.hops = hops
        self.nextHop = nextHop
        self.announceEmitted = announceEmitted
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter TransportTests`
Expected: PASS (5 tests). First build compiles the new target against TCA.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/ReTiCA/Destination/Destination.swift Sources/ReTiCATransport Tests/ReTiCATransportTests/TransportTests.swift
git commit -m "feat: ReTiCATransport target, InterfaceID/RingSet/LearnedDestination, Destination Equatable"
```

---

### Task 2: Transport reducer skeleton (state + registration actions)

**Files:**
- Create: `Sources/ReTiCATransport/Transport.swift`
- Test: `Tests/ReTiCATransportTests/TransportTests.swift` (append)

**Interfaces:**
- Consumes: `Destination`, `Identity`, `Packet`, `Announce`, `Crypto` (core); TCA.
- Produces:
  - `@Reducer struct Transport` with `State` (`localDestinations: [Data: Destination]`, `learned: [Data: LearnedDestination]`, `interfaces: Set<InterfaceID>`, internal `seenPacketHashes: RingSet`), `Action` (`.interfaceConnected`/`.interfaceDisconnected`/`.registerLocalDestination`/`.received`/`.announce`/`.send`/`.delegate`), `Delegate` (`.transmit`/`.received`/`.pathLearned`/`.sendFailed`), `SendFailure` (`.notLearned`/`.tooLarge`).

- [ ] **Step 1: Write the failing test**

Append to `TransportTests.swift`:

```swift
@Test @MainActor func registersInterfacesAndLocalDestinations() async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: Identity())!
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off

    await store.send(.interfaceConnected(InterfaceID("i1"))) {
        $0.interfaces = [InterfaceID("i1")]
    }
    await store.send(.registerLocalDestination(dest)) {
        $0.localDestinations = [dest.hash: dest]
    }
    await store.send(.interfaceDisconnected(InterfaceID("i1"))) {
        $0.interfaces = []
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter registersInterfacesAndLocalDestinations`
Expected: FAIL — `Transport` not defined.

- [ ] **Step 3: Write minimal implementation**

`Sources/ReTiCATransport/Transport.swift`:

```swift
import Foundation
import ComposableArchitecture
import ReTiCA

/// The Reticulum Transport layer, endpoint (leaf) subset: learns paths from announces,
/// delivers inbound packets to local destinations, and routes outbound packets to learned
/// destinations. Interface-agnostic — interfaces are referenced by `InterfaceID`.
@Reducer
public struct Transport {
    @ObservableState
    public struct State: Equatable {
        public var localDestinations: [Data: Destination] = [:]
        public var learned: [Data: LearnedDestination] = [:]
        public var interfaces: Set<InterfaceID> = []
        var seenPacketHashes = RingSet()
        public init() {}
    }

    public enum SendFailure: Equatable, Sendable { case notLearned, tooLarge }

    public enum Action: Equatable {
        case interfaceConnected(InterfaceID)
        case interfaceDisconnected(InterfaceID)
        case registerLocalDestination(Destination)
        case received(InterfaceID, Data)
        case announce(destinationHash: Data, appData: Data?)
        case send(destinationHash: Data, plaintext: Data)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case transmit(InterfaceID, Data)
            case received(destinationHash: Data, plaintext: Data)
            case pathLearned(destinationHash: Data, hops: UInt8)
            case sendFailed(destinationHash: Data, reason: SendFailure)
        }
    }

    @Dependency(\.date) var date

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .interfaceConnected(id):
                state.interfaces.insert(id)
                return .none

            case let .interfaceDisconnected(id):
                state.interfaces.remove(id)
                return .none

            case let .registerLocalDestination(destination):
                state.localDestinations[destination.hash] = destination
                return .none

            case .received, .announce, .send, .delegate:
                return .none
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter registersInterfacesAndLocalDestinations`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -m "feat: Transport reducer skeleton and registration actions"
```

---

### Task 3: Announce ingest (dedup, learn, recency)

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (fill in `.received` for announces)
- Test: `Tests/ReTiCATransportTests/TransportTests.swift` (append)

**Interfaces:**
- Consumes: `Packet(raw:)`, `Packet.packetHash/packetType/destinationHash/payload/contextFlag/transportId/hops`, `Announce.parse`, `Destination.hash`.
- Produces: `.received` handling for `.announce` packets → learns into `state.learned` with recency + dedup, emits `.delegate(.pathLearned)`.

- [ ] **Step 1: Write the failing test**

Append to `TransportTests.swift`:

```swift
// Builds a raw ANNOUNCE packet (HEADER_1) for a synthetic identity.
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

@Test @MainActor func learnsPathFromAnnounceAndDedups() async {
    let id = Identity()
    let ifID = InterfaceID("i1")
    let (raw, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                             hops: 3, emitted: 1000, appData: Data("meta".utf8))
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off

    await store.send(.received(ifID, raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 3)))

    let entry = store.state.learned[destHash]
    #expect(entry?.identity.hash == id.hash)
    #expect(entry?.hops == 3)
    #expect(entry?.interfaceID == ifID)
    #expect(entry?.appData == Data("meta".utf8))
    #expect(entry?.announceEmitted == 1000)

    // Duplicate packet is suppressed (no second pathLearned).
    await store.send(.received(ifID, raw))
}

@Test @MainActor func recencyPrefersNewerThenShorter() async {
    let id = Identity()
    let (older, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: [], hops: 2, emitted: 100)
    let (newer, _)        = makeAnnouncePacket(identity: id, appName: "app", aspects: [], hops: 5, emitted: 200)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off

    await store.send(.received(InterfaceID("i1"), newer))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 5)))
    // Older emission must NOT replace the newer entry.
    await store.send(.received(InterfaceID("i2"), older))
    #expect(store.state.learned[destHash]?.hops == 5)
    #expect(store.state.learned[destHash]?.announceEmitted == 200)
}

@Test @MainActor func ignoresAnnounceForLocalDestination() async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["me"],
                           identity: Identity())!
    let (raw, destHash) = makeAnnouncePacket(identity: dest.identity!, appName: "app",
                                             aspects: ["me"], hops: 1, emitted: 50)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations = [dest.hash: dest] }
    await store.send(.received(InterfaceID("i1"), raw)) // announce for ourselves → ignored
    #expect(store.state.learned[destHash] == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter learnsPathFromAnnounceAndDedups`
Expected: FAIL — `.received` does not learn yet.

- [ ] **Step 3: Write minimal implementation**

In `Transport.swift`, replace `case .received, .announce, .send, .delegate: return .none` with a real `.received` case (leave `.announce`/`.send`/`.delegate` returning `.none` for now), and add helpers:

```swift
            case let .received(interfaceID, data):
                guard let packet = Packet(raw: data) else { return .none }
                guard state.seenPacketHashes.insert(packet.packetHash) else { return .none }

                switch packet.packetType {
                case .announce:
                    // Don't learn a path to one of our own destinations.
                    guard state.localDestinations[packet.destinationHash] == nil else { return .none }
                    guard let parsed = Announce.parse(payload: packet.payload,
                                                      destinationHash: packet.destinationHash,
                                                      contextFlagSet: packet.contextFlag)
                    else { return .none }
                    let emitted = Transport.announceEmitted(parsed.randomHash)
                    let candidate = LearnedDestination(
                        identity: parsed.identity, appData: parsed.appData, ratchet: parsed.ratchet,
                        interfaceID: interfaceID, hops: packet.hops, nextHop: packet.transportId,
                        announceEmitted: emitted)
                    guard Transport.shouldReplace(state.learned[packet.destinationHash], with: candidate)
                    else { return .none }
                    state.learned[packet.destinationHash] = candidate
                    return .send(.delegate(.pathLearned(destinationHash: packet.destinationHash,
                                                        hops: packet.hops)))
                default:
                    return .none
                }

            case .announce, .send, .delegate:
                return .none
```

Add these static helpers inside `Transport`:

```swift
    /// Emission time from an announce's random hash: big-endian of `randomHash[5..<10]`.
    static func announceEmitted(_ randomHash: Data) -> UInt64 {
        let bytes = randomHash.suffix(5)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// Recency rule: accept a candidate if there is no existing entry, or it is newer, or it
    /// is equally recent but reached us in fewer hops.
    static func shouldReplace(_ existing: LearnedDestination?, with candidate: LearnedDestination) -> Bool {
        guard let existing else { return true }
        if candidate.announceEmitted > existing.announceEmitted { return true }
        if candidate.announceEmitted == existing.announceEmitted && candidate.hops < existing.hops { return true }
        return false
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TransportTests`
Expected: PASS (announce tests + prior).

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -m "feat: Transport announce ingest with dedup and recency"
```

---

### Task 4: Inbound DATA delivery

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (add `.data` case to `.received`)
- Test: `Tests/ReTiCATransportTests/TransportTests.swift` (append)

**Interfaces:**
- Consumes: `Destination.decrypt`, `Destination.kind`, `Packet.destinationType/payload`.
- Produces: `.received` handling for `.data` packets addressed to a local destination → `.delegate(.received(destinationHash:plaintext:))`.

- [ ] **Step 1: Write the failing test**

Append to `TransportTests.swift`:

```swift
@Test @MainActor func deliversInboundDataToLocalDestination() async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["inbox"],
                           identity: Identity())!
    let plaintext = Data("hello endpoint".utf8)
    let ciphertext = dest.encrypt(plaintext)            // encrypt to our own destination
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: dest.hash, transportId: nil, payload: ciphertext)
    let raw = try! packet.packed()

    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations = [dest.hash: dest] }
    await store.send(.received(InterfaceID("i1"), raw))
    await store.receive(.delegate(.received(destinationHash: dest.hash, plaintext: plaintext)))
}

@Test @MainActor func dropsDataForUnknownDestination() async {
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: Data(repeating: 0x11, count: 16), transportId: nil,
                        payload: Data(repeating: 0xAB, count: 80))
    await store.send(.received(InterfaceID("i1"), try! packet.packed())) // no delegate expected
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter deliversInboundDataToLocalDestination`
Expected: FAIL — DATA packets are not delivered yet.

- [ ] **Step 3: Write minimal implementation**

In `Transport.swift`, add a `.data` case to the inner `switch packet.packetType` (before `default`):

```swift
                case .data:
                    guard let destination = state.localDestinations[packet.destinationHash],
                          destination.kind == packet.destinationType,
                          let plaintext = destination.decrypt(packet.payload)
                    else { return .none }
                    return .send(.delegate(.received(destinationHash: packet.destinationHash,
                                                     plaintext: plaintext)))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TransportTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -m "feat: Transport inbound DATA delivery to local destinations"
```

---

### Task 5: Outbound send + self-announce

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (fill in `.send` and `.announce`)
- Test: `Tests/ReTiCATransportTests/TransportTests.swift` (append)

**Interfaces:**
- Consumes: `Identity.encrypt`, `Packet.init`/`packed()`, `Packet.announce`, `Announce.buildPayload`/`randomHash`, `SecureRandom.bytes`, `@Dependency(\.date)`.
- Produces: `.send` (encrypt + route or `.sendFailed`) and `.announce` (build + transmit per interface).

- [ ] **Step 1: Write the failing test**

Append to `TransportTests.swift`. These capture the emitted `.transmit` payload via the
predicate form of `store.receive` (the encrypted bytes are non-deterministic, so we can't
assert them by value — we capture and round-trip-decrypt instead):

```swift
@Test @MainActor func sendRoutesEncryptedPacketToLearnedInterface() async {
    let remote = Identity()
    let ifID = InterfaceID("i1")
    let (raw, destHash) = makeAnnouncePacket(identity: remote, appName: "app", aspects: ["svc"],
                                             hops: 2, emitted: 500)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.received(ifID, raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))

    let plaintext = Data("outbound msg".utf8)
    let captured = LockIsolated<(InterfaceID, Data)?>(nil)
    await store.send(.send(destinationHash: destHash, plaintext: plaintext))
    await store.receive { action in
        if case let .delegate(.transmit(id, out)) = action { captured.setValue((id, out)); return true }
        return false
    }

    let (outID, outRaw) = captured.value!
    #expect(outID == ifID)
    let outPacket = Packet(raw: outRaw)!
    #expect(outPacket.destinationHash == destHash)
    #expect(remote.decrypt(outPacket.payload) == plaintext) // round-trips
}

@Test @MainActor func sendToUnknownDestinationFails() async {
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    let destHash = Data(repeating: 0x22, count: 16)
    await store.send(.send(destinationHash: destHash, plaintext: Data("x".utf8)))
    await store.receive(.delegate(.sendFailed(destinationHash: destHash, reason: .notLearned)))
}

@Test @MainActor func announceEmitsValidPayloadPerInterface() async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["me"],
                           identity: Identity())!
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i1"))) { $0.interfaces = [InterfaceID("i1")] }
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations = [dest.hash: dest] }

    let captured = LockIsolated<Data?>(nil)
    await store.send(.announce(destinationHash: dest.hash, appData: Data("name".utf8)))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }

    let packet = Packet(raw: captured.value!)!
    #expect(packet.packetType == .announce)
    let parsed = Announce.parse(payload: packet.payload, destinationHash: dest.hash,
                                contextFlagSet: packet.contextFlag)
    #expect(parsed?.identity.hash == dest.identity!.hash)
    #expect(parsed?.appData == Data("name".utf8))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter sendRoutesEncryptedPacketToLearnedInterface`
Expected: FAIL — `.send`/`.announce` do nothing yet.

- [ ] **Step 3: Write minimal implementation**

In `Transport.swift`, replace `case .announce, .send, .delegate: return .none` with:

```swift
            case let .send(destinationHash, plaintext):
                guard let entry = state.learned[destinationHash] else {
                    return .send(.delegate(.sendFailed(destinationHash: destinationHash,
                                                       reason: .notLearned)))
                }
                let ciphertext = entry.identity.encrypt(plaintext, ratchet: entry.ratchet)
                let packet = Packet(headerType: .header1, packetType: .data,
                                    transportType: .broadcast, destinationType: .single,
                                    context: .none, contextFlag: false, hops: 0,
                                    destinationHash: destinationHash, transportId: nil,
                                    payload: ciphertext)
                guard let raw = try? packet.packed() else {
                    return .send(.delegate(.sendFailed(destinationHash: destinationHash,
                                                       reason: .tooLarge)))
                }
                return .send(.delegate(.transmit(entry.interfaceID, raw)))

            case let .announce(destinationHash, appData):
                guard let dest = state.localDestinations[destinationHash],
                      let identity = dest.identity, identity.privateKey != nil
                else { return .none }
                let now = UInt64(date.now.timeIntervalSince1970)
                let randomHash = Announce.randomHash(now: now, randomPrefix: SecureRandom.bytes(5))
                let payload = Announce.buildPayload(identity: identity, destinationHash: destinationHash,
                                                    nameHash: dest.nameHash, randomHash: randomHash,
                                                    ratchet: nil, appData: appData)
                let packet = Packet.announce(from: dest, payload: payload)
                guard let raw = try? packet.packed() else { return .none }
                return .merge(state.interfaces.map { .send(.delegate(.transmit($0, raw))) })

            case .delegate:
                return .none
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TransportTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -m "feat: Transport outbound send routing and self-announce"
```

---

### Task 6: Cross-validation vs Python-RNS announce packet

**Files:**
- Create: `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py`
- Create: `Tests/ReTiCATransportTests/Vectors/transport_fixtures.json` (generated)
- Create: `Tests/ReTiCATransportTests/Vectors/TransportVectorFixtures.swift`
- Create: `Tests/ReTiCATransportTests/Vectors/TransportCrossValidationTests.swift`
- Modify: `Package.swift` (bundle the fixture in the transport test target)

**Interfaces:**
- Consumes: `Transport`, `Data(hexString:)`.
- Produces: `struct TransportVectorFixtures: Decodable`.

- [ ] **Step 1: Write the generator**

`Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py`:

```python
#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_transport_fixtures.py > transport_fixtures.json
import json, os, time
import RNS

identity = RNS.Identity()
app, aspect = "reticula", "endpoint"
app_data = b"node-name"
name_hash = RNS.Identity.full_hash(
    RNS.Destination.expand_name(None, app, aspect).encode("utf-8")
)[:RNS.Identity.NAME_HASH_LENGTH // 8]
random_hash = RNS.Identity.get_random_hash()[:5] + int(time.time()).to_bytes(5, "big")
dest_hash = RNS.Destination.hash(identity, app, aspect)
ratchet = b""
signed = dest_hash + identity.get_public_key() + name_hash + random_hash + ratchet + app_data
signature = identity.sign(signed)
payload = identity.get_public_key() + name_hash + random_hash + ratchet + signature + app_data

# HEADER_1 ANNOUNCE packet: flags = SINGLE(0)<<2 | ANNOUNCE(1) = 0x01, no context flag, hops = 3
hops = 3
flags = 0x01
announce_packet = bytes([flags, hops]) + dest_hash + bytes([0x00]) + payload

print(json.dumps({
    "announce_dest_hash": dest_hash.hex(),
    "announce_identity_hash": identity.hash.hex(),
    "announce_app_data": app_data.hex(),
    "announce_hops": hops,
    "announce_packet": announce_packet.hex(),
}, indent=2))
```

- [ ] **Step 2: Generate the fixture (controller runs this in the RNS env)**

Run: `/Users/ell/opt/anaconda3/envs/rns/bin/python Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py > Tests/ReTiCATransportTests/Vectors/transport_fixtures.json`
Expected: `transport_fixtures.json` with the 5 fields populated. Verify the committed file contains `announce_packet` (an external process may revert it — check `git show HEAD:...` after committing).

- [ ] **Step 3: Bundle the fixture in Package.swift**

Add `resources: [.process("Vectors/transport_fixtures.json")]` to the `ReTiCATransportTests` test target.

- [ ] **Step 4: Write the decoder + failing test**

`Tests/ReTiCATransportTests/Vectors/TransportVectorFixtures.swift`:

```swift
import Foundation

struct TransportVectorFixtures: Decodable {
    let announceDestHash: String
    let announceIdentityHash: String
    let announceAppData: String
    let announceHops: Int
    let announcePacket: String

    enum CodingKeys: String, CodingKey {
        case announceDestHash = "announce_dest_hash"
        case announceIdentityHash = "announce_identity_hash"
        case announceAppData = "announce_app_data"
        case announceHops = "announce_hops"
        case announcePacket = "announce_packet"
    }

    static func load() throws -> TransportVectorFixtures {
        let url = Bundle.module.url(forResource: "transport_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(TransportVectorFixtures.self, from: Data(contentsOf: url))
    }
}
```

`Tests/ReTiCATransportTests/Vectors/TransportCrossValidationTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

@Test @MainActor func transportLearnsFromReferenceAnnouncePacket() async throws {
    let f = try TransportVectorFixtures.load()
    let destHash = Data(hexString: f.announceDestHash)!
    let ifID = InterfaceID("tcp-1")

    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.received(ifID, Data(hexString: f.announcePacket)!))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash,
                                               hops: UInt8(f.announceHops))))

    let entry = store.state.learned[destHash]
    #expect(entry?.identity.hexHash == f.announceIdentityHash)
    #expect(entry?.appData == Data(hexString: f.announceAppData))
    #expect(entry?.hops == UInt8(f.announceHops))
    #expect(entry?.interfaceID == ifID)
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter TransportCrossValidation`
Expected: PASS — Transport learns the reference destination (proves Packet unpack + Announce parse + learn against Python-RNS bytes).

- [ ] **Step 6: Commit**

```bash
git add Tests/ReTiCATransportTests/Vectors Package.swift
git commit -m "test: Transport cross-validation against a Python-RNS announce packet"
```

---

### Task 7: Full suite + mutation gate + README

**Files:** `README.md` (modify); no new source.

- [ ] **Step 1: Run the full suite**

Run: `swift test`
Expected: PASS — all targets (core, interfaces, transport), pristine output.

- [ ] **Step 2: Mutation sweep (project convention)**

Batch-mutate one production line per new unit, run `swift test` once, confirm the covering tests fail, then revert all and confirm green. Commit nothing with mutations. Suggested mutations:
- `Transport.announceEmitted`: use `prefix(5)` instead of `suffix(5)` (breaks `announceEmitted == 1000` assertion).
- `Transport.shouldReplace`: return `false` unconditionally when `existing != nil` (breaks recency — newer announce wouldn't replace... actually returns false so first learn still works; instead) change `>` to `<` in the newer-wins check (breaks `recencyPrefersNewerThenShorter`).
- `.received` dedup: change `guard state.seenPacketHashes.insert(...)` to always-true (the duplicate announce would re-emit `pathLearned` → the dedup test's exhaustive-off still passes, so ALSO assert via a stricter test if needed) — if not caught, add a test asserting the duplicate does not change state a second time.
- `.received` announce self-skip: remove the `localDestinations[...] == nil` guard (breaks `ignoresAnnounceForLocalDestination`).
- `.data` delivery: drop the `destination.kind == packet.destinationType` guard (does not break current tests; if uncaught, note as a coverage gap) — primary check: change `.delegate(.received(...))` plaintext to `packet.payload` (ciphertext) → breaks `deliversInboundDataToLocalDestination`.
- `.send` route: emit `.transmit` with `plaintext` instead of the encrypted `raw` (breaks the round-trip decrypt assertion).
- `.announce`: emit for zero interfaces (drop the `.merge(...)`) → breaks `announceEmitsValidPayloadPerInterface`.

Record which tests fail per mutation. If any mutation is not caught, add a covering test. Revert all; confirm green.

- [ ] **Step 3: Update the README**

Add a "Sub-project #4: Transport (endpoint core)" section:

```markdown
## Sub-project #4: Transport (endpoint core)

| Module | Target | What it implements |
|--------|--------|--------------------|
| `Transport` | `ReTiCATransport` | TCA reducer: announce ingest → path/known-destination table (recency + dedup), inbound DATA decrypt+deliver to local destinations, outbound routing to learned paths, self-announce |
| `InterfaceID` / `LearnedDestination` | `ReTiCATransport` | Interface handle and the learned path+identity entry |

`ReTiCATransport` is interface-agnostic (no Network.framework): interfaces are referenced by `InterfaceID`, inbound bytes arrive via `.received(InterfaceID, Data)`, and outbound bytes leave via `.delegate(.transmit(InterfaceID, Data))`, so an app layer wires Transport ↔ `ReTiCAInterfaces`. This is the endpoint (leaf) subset of RNS Transport; relaying, path requests, expiry/cull jobs, persistence, and links are future slices. Announce learning is cross-validated against a Python-RNS 1.3.8 announce packet.

### Products
- **`ReTiCA`** — pure Swift core. Zero third-party dependencies.
- **`ReTiCAInterfaces`** — TCA TCP-client interface (Network.framework).
- **`ReTiCATransport`** — TCA endpoint-core Transport (no Network.framework).
```

Update "Not Yet Implemented" to keep transport-node relaying, path requests, links, and resources.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document Transport endpoint-core sub-project"
```

---

## Self-Review

**Spec coverage:**
- `ReTiCATransport` target (interface-agnostic, TCA, no Network.framework) → Task 1.
- Value types: `InterfaceID`, `LearnedDestination`, `RingSet`; `Destination: Equatable` → Task 1.
- Reducer State (localDestinations/learned/interfaces/seenPacketHashes) + registration actions → Task 2.
- Announce ingest (parse, dedup, recency, learn, pathLearned, skip-self) → Task 3.
- Inbound DATA demux + decrypt + deliver → Task 4.
- Outbound `.send` (encrypt, route, sendFailed) + `.announce` (build, transmit per interface) → Task 5.
- Delegate contract (transmit/received/pathLearned/sendFailed) → Tasks 2–5.
- Received-ratchet storage/use → Tasks 3 (store), 5 (use in `.send`).
- Cross-validation vs a Python-RNS announce packet → Task 6.
- Full-suite + mutation gate + README → Task 7.
- Deferred (relaying, path requests, jobs, persistence, links, own-ratchet rotation, proofs) → not built, per scope.

**Placeholder scan:** No TBD/TODO. The one illustrative test sketch in Task 5 is explicitly replaced by the concrete version in the same step (the instruction says to keep only the concrete version). Every production step has complete code.

**Type consistency:** `InterfaceID`, `LearnedDestination`, `Transport.Action`/`.Delegate`/`SendFailure`, and `State` fields are consistent across Tasks 1–6; `Announce.buildPayload/parse/randomHash`, `Destination.hash/nameHash/encrypt/decrypt/kind`, `Packet.init/init?(raw:)/packed()/announce`, `Identity.encrypt/hash`, `SecureRandom.bytes`, and `Data(hexString:)` match the merged core APIs; `@Dependency(\.date)` used in Task 5 impl and test.

**Decisions recorded:** interface-agnostic `InterfaceID` handles; combined path+identity `learned` table; recency = newer-then-shorter; leaf outbound = HEADER_1 on the heard interface; `SendFailure` consolidated to `.notLearned`/`.tooLarge` (no separate `.noPath`); TestStore non-exhaustive on internal `seenPacketHashes`; separate `transport_fixtures.json` bundled in the transport test target (avoids cross-target resource sharing).
