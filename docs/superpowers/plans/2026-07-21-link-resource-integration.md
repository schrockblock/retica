# Link ↔ Resource Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make resource transfers usable end-to-end through the public `Endpoint` API by hosting `ResourceTransfer` instances inside `LinkSession`, routing inbound RESOURCE_* packets to them, and surfacing send/receive/conclude/fail through the Endpoint.

**Architecture:** `LinkSession` gains a `transfers: IdentifiedArrayOf<ResourceTransfer.State>` child collection (`.forEach`), routes inbound RESOURCE_* packets (spawn a receiver on ADV deduped by resource hash; broadcast others to the hosted transfers), and re-surfaces new delegate cases that `Endpoint` re-exposes. A new `RandomBytes` dependency supplies the sender's random prefix/randomHash. Routing/lifecycle only — no new wire formats.

**Tech Stack:** Swift 6, The Composable Architecture ~1.26 (`@Reducer`, `IdentifiedArrayOf`, `IdentifiedActionOf`, `.forEach`, `TestStore`, `TestClock`, `@Dependency`), `swift-dependencies` `DependencyKey`, CryptoKit/Security.

## Global Constraints

- **Wire encryption (unchanged from 6a–6c):** RESOURCE parts (0x01) and RESOURCE_PRF (0x05) plaintext; RESOURCE_ADV (0x02), RESOURCE_REQ (0x03), RESOURCE_ICL (0x06), RESOURCE_RCL (0x07) encrypted with the link session key. All resource packets `destinationType == .link`, `destinationHash == linkID`. **This slice adds NO new wire format.**
- **Transfers live in `LinkSession`** (link-scoped), hosted via `.forEach(\.transfers, action: \.transfer)`. `Endpoint` re-surfaces the new link delegates; outbound resource transmits reuse LinkSession's existing `.delegate(.transmit)` path (no new Endpoint outbound handling).
- **Dedup receiver spawn by resource hash, race-free:** on an inbound RESOURCE_ADV, if a transfer with `resourceHash == adv.hash` exists, ignore (sender re-advertising); else spawn and **set the spawned transfer's `resourceHash` synchronously at spawn** (not deferred to the async `.accept` effect).
- **`resourceConcluded`/`resourceFailed` are keyed by resource hash** at the delegate boundary; `resourceReceived` carries the assembled `Data`.
- **Determinism:** `RandomBytes` has a deterministic `testValue`; the sender's prefix/randomHash come from `randomBytes(8)`. Constant SDU (`resourceSDU = 464`); MTU negotiation deferred.
- **Data-slice index safety:** any `Data` from `randomBytes`/`Link.decrypt`/subscript may have a non-zero `startIndex`; materialize `Data(...)` and stride via `startIndex`.
- **Two-layer purity:** the `ReTiCA` core stays dependency-free; TCA/dependency code lives in `ReTiCATransport`/`ReTiCANode`. `State`s stay `Equatable` (LinkSession) / `Equatable`+`Identifiable`.
- **No compound shell commands** (one per invocation; multi-line commit messages via `git commit -F <file>` under `/tmp/ReTiCA/`).
- **Mutation-test discipline** for every new/changed test: run-pass → batch-mutate to force fail → revert to green, before commit.
- **Commit trailers:** `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.

## File Structure

- `Sources/ReTiCATransport/RandomBytesDependency.swift` (**create**, Task 1) — the `RandomBytes` dependency.
- `Sources/ReTiCATransport/LinkSession.swift` (**modify**, Tasks 2–3) — host transfers, route RESOURCE_*, `sendResource`, new delegates.
- `Sources/ReTiCANode/Endpoint.swift` (**modify**, Task 4) — `sendResourceOverLink` + re-surfaced delegates.
- `Tests/ReTiCATransportTests/RandomBytesDependencyTests.swift` (**create**, Task 1).
- `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift` (**create**, Tasks 2–3) — LinkSession resource routing tests.
- `Tests/ReTiCANodeTests/EndpointTests.swift` (**modify**, Tasks 4–5) — Endpoint-level + E2E tests.
- `README.md` (**modify**, Task 5).

---

### Task 1: `RandomBytes` dependency

**Files:**
- Create: `Sources/ReTiCATransport/RandomBytesDependency.swift`
- Test: `Tests/ReTiCATransportTests/RandomBytesDependencyTests.swift`

**Interfaces:**
- Produces: `RandomBytesGenerator` (`Sendable`, `callAsFunction(_ count: Int) -> Data`), `DependencyValues.randomBytes`. `liveValue` = `SecRandomCopyBytes`-backed; `testValue` = `Data((0..<count).map { UInt8($0 & 0xff) })`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCATransportTests/RandomBytesDependencyTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCATransport

@Test func randomBytesTestValueIsDeterministic() {
    let g = RandomBytesGenerator.testValue
    #expect(g(4) == Data([0, 1, 2, 3]))
    #expect(g(8) == Data([0, 1, 2, 3, 4, 5, 6, 7]))
}

@Test func randomBytesLiveReturnsRequestedCount() {
    let g = RandomBytesGenerator.liveValue
    #expect(g(4).count == 4)
    #expect(g(16).count == 16)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter RandomBytes`
Expected: FAIL (no such type `RandomBytesGenerator`).

- [ ] **Step 3: Implement the dependency**

Create `Sources/ReTiCATransport/RandomBytesDependency.swift`:

```swift
import Foundation
import Security
import ComposableArchitecture

/// A dependency that produces `count` random bytes. Live is CSPRNG-backed
/// (`SecRandomCopyBytes`); test/preview is a deterministic ramp so spawned resource
/// hashes are reproducible. The specific bytes never affect wire compatibility.
public struct RandomBytesGenerator: Sendable {
    public var generate: @Sendable (Int) -> Data
    public init(generate: @escaping @Sendable (Int) -> Data) { self.generate = generate }
    public func callAsFunction(_ count: Int) -> Data { generate(count) }
}

extension RandomBytesGenerator: DependencyKey {
    public static let liveValue = RandomBytesGenerator { count in
        var bytes = [UInt8](repeating: 0, count: count)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return Data(bytes)
    }
    public static let testValue = RandomBytesGenerator { count in
        Data((0..<count).map { UInt8($0 & 0xff) })
    }
    public static let previewValue = testValue
}

extension DependencyValues {
    public var randomBytes: RandomBytesGenerator {
        get { self[RandomBytesGenerator.self] }
        set { self[RandomBytesGenerator.self] = newValue }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter RandomBytes`
Expected: PASS (2 tests).

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter RandomBytes`, confirm the named test fails, revert; final green:
- In `testValue`, change the ramp to `UInt8(0)` for all → `randomBytesTestValueIsDeterministic` fails.
- In `liveValue`, change `count: count` (the array size) to `count: count + 1` → `randomBytesLiveReturnsRequestedCount` fails.

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCATransport/RandomBytesDependency.swift Tests/ReTiCATransportTests/RandomBytesDependencyTests.swift
git commit -F /tmp/ReTiCA/commit-t1.txt
```
(`/tmp/ReTiCA/commit-t1.txt` first line: `feat: RandomBytes dependency (live SecRandomCopyBytes, deterministic test)`, blank line, trailers.)

---

### Task 2: LinkSession hosts transfers + receiver inbound routing

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift`
- Test: `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift` (create)

**Interfaces:**
- Consumes: `ResourceTransfer` (`init(receivingOn:sessionKey:interfaceID:rtt:id:)`, `.accept(Data)`/`.received(Data)`/`.delegate(.transmit/.received/.concluded/.failed)`), `Link.decrypt`, `ResourceAdvertisement.unpack`, `@Dependency(\.uuid)`.
- Produces: `LinkSession.State.transfers: IdentifiedArrayOf<ResourceTransfer.State>`; `LinkSession.Action.transfer(IdentifiedActionOf<ResourceTransfer>)`; `LinkSession.Action.Delegate` cases `resourceReceived(Data)`/`resourceConcluded(Data)`/`resourceFailed(Data)`; inbound RESOURCE_* routing. (`sendResource` is Task 3.)

- [ ] **Step 1: Add State field, dependency, `.forEach`, and Action cases**

In `Sources/ReTiCATransport/LinkSession.swift`:

Add to `State` (after the last stored property, before the initializers):
```swift
        public var transfers: IdentifiedArrayOf<ResourceTransfer.State> = []
```

Add the uuid dependency next to the existing ones (after `@Dependency(\.continuousClock) var clock`):
```swift
    @Dependency(\.uuid) var uuid
```

Add to `Action` (after `case delegate(Delegate)` — actually add before it):
```swift
        case transfer(IdentifiedActionOf<ResourceTransfer>)
```

Add to `Action.Delegate` (after `case dataReceived(Data)`):
```swift
            case resourceReceived(Data)
            case resourceConcluded(Data)
            case resourceFailed(Data)
```

Change the `Reduce` capture list from `[date, clock]` to `[date, clock, uuid]`:
```swift
        Reduce { [date, clock, uuid] state, action in
```

Attach the child reducer: change the `body` so the `Reduce { ... }` is followed by `.forEach`. The closing of `body` currently is:
```swift
        }
    }
}
```
Change it to:
```swift
        }
        .forEach(\.transfers, action: \.transfer) { ResourceTransfer() }
    }
}
```

- [ ] **Step 2: Add inbound RESOURCE_* routing**

Inside `case let .received(data):`, in the `switch (state.role, state.status, packet.packetType, packet.context)`, add these cases immediately BEFORE `default:`:

```swift
                case (_, .active, .data, .resourceAdvertisement):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          let adv = ResourceAdvertisement.unpack(plain) else { return .none }
                    if state.transfers.contains(where: { $0.resourceHash == adv.hash }) { return .none }
                    let newID = uuid()
                    let transferRTT: Duration = .seconds(state.rtt ?? 1)
                    state.transfers.append(ResourceTransfer.State(
                        receivingOn: state.linkID, sessionKey: state.sessionKey,
                        interfaceID: state.interfaceID, rtt: transferRTT, id: newID))
                    state.transfers[id: newID]?.resourceHash = adv.hash   // set now → dedup is race-free vs async .accept
                    return .send(.transfer(.element(id: newID, action: .accept(data))))

                case (_, .active, .data, .resource),
                     (_, .active, .data, .resourceRequest),
                     (_, .active, .data, .resourceProof),
                     (_, .active, .data, .resourceInitiatorCancel),
                     (_, .active, .data, .resourceReceiverCancel):
                    return .merge(state.transfers.ids.map {
                        .send(.transfer(.element(id: $0, action: .received(data))))
                    })
```

- [ ] **Step 3: Add child-delegate interception**

In the OUTER `switch action`, add these cases immediately BEFORE `case .delegate:`:

```swift
            case let .transfer(.element(_, .delegate(.transmit(ifID, raw)))):
                return .send(.delegate(.transmit(ifID, raw)))
            case let .transfer(.element(_, .delegate(.received(payload)))):
                return .send(.delegate(.resourceReceived(payload)))
            case let .transfer(.element(elementID, .delegate(.concluded))):
                guard let hash = state.transfers[id: elementID]?.resourceHash else { return .none }
                return .send(.delegate(.resourceConcluded(hash)))
            case let .transfer(.element(elementID, .delegate(.failed))):
                guard let hash = state.transfers[id: elementID]?.resourceHash else { return .none }
                return .send(.delegate(.resourceFailed(hash)))
            case .transfer:
                return .none
```

- [ ] **Step 4: Write the receiver-side tests**

Create `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

private let resKey = Data(repeating: 0x01, count: 64)
private let resLinkID = Data(repeating: 0xAB, count: 16)

@MainActor
private func activeLinkStore(_ clock: TestClock<Duration>) -> TestStore<LinkSession.State, LinkSession.Action> {
    var s = LinkSession.State(responderFor: Identity(),
                              destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"))
    s.status = .active
    s.sessionKey = resKey
    s.linkID = resLinkID
    s.rtt = 1.0
    let store = TestStore(initialState: s) { LinkSession() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = clock
        $0.uuid = .incrementing
        // randomBytes uses its deterministic testValue by default
    }
    store.exhaustivity = .off
    return store
}

// A sender ResourceTransfer over the same link/key, used to synthesize inbound packets.
private func senderFor(_ data: Data, sdu: Int = 24) -> ResourceTransfer.State {
    ResourceTransfer.State(sending: data, linkID: resLinkID, sessionKey: resKey,
                           interfaceID: InterfaceID("i"), prefix: Data([0, 1, 2, 3]),
                           randomHash: Data([4, 5, 6, 7]), sdu: sdu)
}

private func advPacket(_ s: ResourceTransfer.State) -> Data {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .resourceAdvertisement, contextFlag: false, hops: 0,
                   destinationHash: resLinkID, transportId: nil,
                   payload: Link.encrypt(s.advertisement!.pack(), sessionKey: resKey))
    return try! p.packed()
}

private func partPacket(_ chunk: Data) -> Data {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .resource, contextFlag: false, hops: 0,
                   destinationHash: resLinkID, transportId: nil, payload: chunk)
    return try! p.packed()
}

@Test @MainActor func inboundAdvertisementSpawnsReceiverAndRequests() async {
    let clock = TestClock<Duration>()
    let store = activeLinkStore(clock)
    let sender = senderFor(Data(repeating: 0x33, count: 100))
    await store.send(.received(advPacket(sender)))
    #expect(store.state.transfers.count == 1)
    #expect(store.state.transfers[0].resourceHash == sender.resourceHash)   // set at spawn
    await store.receive { if case .transfer(.element(_, .accept)) = $0 { return true }; return false }
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action, Packet(raw: raw)?.context == .resourceRequest { return true }
        return false
    }
    // Cleanup: cancel the spawned transfer (cancels its watchdog).
    let tid = store.state.transfers[0].id
    await store.send(.transfer(.element(id: tid, action: .cancel)))
}

@Test @MainActor func duplicateAdvertisementDoesNotSpawnSecondTransfer() async {
    let clock = TestClock<Duration>()
    let store = activeLinkStore(clock)
    let sender = senderFor(Data(repeating: 0x33, count: 100))
    await store.send(.received(advPacket(sender)))
    #expect(store.state.transfers.count == 1)
    await store.send(.received(advPacket(sender)))       // sender re-advertise
    #expect(store.state.transfers.count == 1)            // NOT 2
    let tid = store.state.transfers[0].id
    await store.send(.transfer(.element(id: tid, action: .cancel)))
}

@Test @MainActor func inboundPartRoutesToReceiverAndSurfacesResourceReceived() async {
    let clock = TestClock<Duration>()
    let store = activeLinkStore(clock)
    let data = Data("link routes each resource part to the hosted receiver transfer".utf8)
    let sender = senderFor(data)
    await store.send(.received(advPacket(sender)))
    _ = await store.receive { if case .transfer(.element(_, .accept)) = $0 { return true }; return false }
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action, Packet(raw: raw)?.context == .resourceRequest { return true }
        return false
    }
    let got = LockIsolated<Data?>(nil)
    for chunk in sender.parts {
        await store.send(.received(partPacket(chunk)))
    }
    // Once all parts arrive, the receiver assembles and the link surfaces resourceReceived.
    await store.receive { action in
        if case let .delegate(.resourceReceived(d)) = action { got.setValue(d); return true }
        return false
    }
    #expect(got.value == data)
    #expect(store.state.transfers[0].status == .complete)
}
```

> Note: `inboundPartRoutesToReceiverAndSurfacesResourceReceived` completes the transfer (status `.complete`), which cancels the receiver watchdog — so no explicit cleanup is needed there. The first two tests cancel the transfer explicitly.

- [ ] **Step 5: Run to verify**

Run: `swift test --filter LinkSessionResource`
Expected: PASS (3 tests). Also run `swift test --filter LinkSession` to confirm the existing LinkSession tests still pass (the `.forEach` + new cases are additive).

- [ ] **Step 6: Mutation sweep**

Apply each, run `swift test --filter LinkSessionResource`, confirm the named test fails, revert; final green:
- In the `resourceAdvertisement` case, delete the line `state.transfers[id: newID]?.resourceHash = adv.hash` → `inboundAdvertisementSpawnsReceiverAndRequests` fails (`resourceHash` assertion) AND `duplicateAdvertisementDoesNotSpawnSecondTransfer` fails (dedup can't match → count 2).
- In the `resource`/part broadcast case, change `.merge(...)` to `return .none` → `inboundPartRoutesToReceiverAndSurfacesResourceReceived` fails (parts never reach the receiver).
- In the transfer-`received` delegate interception, change `.resourceReceived(payload)` to `.dataReceived(payload)` → `inboundPartRoutesToReceiverAndSurfacesResourceReceived` fails (no `resourceReceived` surfaces).

- [ ] **Step 7: Commit**

```
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionResourceTests.swift
git commit -F /tmp/ReTiCA/commit-t2.txt
```
(First line: `feat: LinkSession hosts ResourceTransfers + inbound RESOURCE_* routing`, blank line, trailers.)

---

### Task 3: LinkSession sender path (`sendResource`)

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift`
- Test: `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift`

**Interfaces:**
- Consumes: Task 2's `transfers`/`.forEach`/`.transfer`; `ResourceTransfer.init(sending:linkID:sessionKey:interfaceID:prefix:randomHash:sdu:rtt:id:)`; `@Dependency(\.randomBytes)`.
- Produces: `LinkSession.Action.sendResource(Data)`; `LinkSession.resourceSDU`.

- [ ] **Step 1: Add the SDU constant, randomBytes dependency, and the action**

In `Sources/ReTiCATransport/LinkSession.swift`:

Add the constant next to `keepaliveByte`/`keepaliveReplyByte`:
```swift
    static let resourceSDU = 464
```

Add the dependency next to `@Dependency(\.uuid) var uuid`:
```swift
    @Dependency(\.randomBytes) var randomBytes
```

Extend the `Reduce` capture list to include `randomBytes`:
```swift
        Reduce { [date, clock, uuid, randomBytes] state, action in
```

Add to `Action` (next to `case transfer(...)`):
```swift
        case sendResource(Data)
```

- [ ] **Step 2: Add the `sendResource` case**

In the OUTER `switch action`, add (e.g. after the `case .send(plaintext):` block):

```swift
            case let .sendResource(data):
                guard state.status == .active else { return .none }
                let r = Data(randomBytes(8))
                let prefix = Data(r[r.startIndex ..< r.startIndex + 4])
                let randomHash = Data(r[r.startIndex + 4 ..< r.startIndex + 8])
                let newID = uuid()
                state.transfers.append(ResourceTransfer.State(
                    sending: data, linkID: state.linkID, sessionKey: state.sessionKey,
                    interfaceID: state.interfaceID, prefix: prefix, randomHash: randomHash,
                    sdu: Self.resourceSDU, rtt: .seconds(state.rtt ?? 1), id: newID))
                return .send(.transfer(.element(id: newID, action: .advertise)))
```

- [ ] **Step 3: Write the sender-side test**

Append to `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift`:

```swift
@Test @MainActor func sendResourceSpawnsSenderAndEmitsEncryptedAdvertisement() async {
    let clock = TestClock<Duration>()
    let store = activeLinkStore(clock)
    let data = Data("a resource sent out over the link".utf8)
    await store.send(.sendResource(data))
    #expect(store.state.transfers.count == 1)
    #expect(store.state.transfers[0].role == .sender)
    await store.receive { if case .transfer(.element(_, .advertise)) = $0 { return true }; return false }
    let advOut = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action, Packet(raw: raw)?.context == .resourceAdvertisement {
            advOut.setValue(raw); return true
        }
        return false
    }
    // The advertisement is encrypted with the link key and unpacks to the sender's advertisement.
    let packet = Packet(raw: advOut.value!)!
    let plain = Link.decrypt(packet.payload, sessionKey: resKey)!
    let adv = ResourceAdvertisement.unpack(plain)!
    #expect(adv.hash == store.state.transfers[0].resourceHash)
    // Cleanup: cancel the sender transfer (cancels its advertise watchdog).
    let tid = store.state.transfers[0].id
    await store.send(.transfer(.element(id: tid, action: .cancel)))
}

@Test @MainActor func sendResourceOnInactiveLinkDoesNothing() async {
    let clock = TestClock<Duration>()
    var s = LinkSession.State(responderFor: Identity(),
                              destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"))
    s.status = .pending                                     // not active
    let store = TestStore(initialState: s) { LinkSession() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0)); $0.continuousClock = clock; $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.sendResource(Data("nope".utf8)))
    #expect(store.state.transfers.isEmpty)
}
```

- [ ] **Step 4: Run to verify**

Run: `swift test --filter LinkSessionResource`
Expected: PASS (5 tests — 3 from Task 2 + 2 new).

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter LinkSessionResource`, confirm the named test fails, revert; final green:
- In `sendResource`, change `guard state.status == .active` to `guard state.status != .active` → `sendResourceOnInactiveLinkDoesNothing` fails (a transfer is created) and `sendResourceSpawnsSenderAndEmitsEncryptedAdvertisement` fails (no transfer on the active link).
- In `sendResource`, change the returned action `.advertise` to `.cancel` → `sendResourceSpawnsSenderAndEmitsEncryptedAdvertisement` fails (no RESOURCE_ADV is emitted).

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionResourceTests.swift
git commit -F /tmp/ReTiCA/commit-t3.txt
```
(First line: `feat: LinkSession.sendResource spawns a sender transfer + advertises`, blank line, trailers.)

---

### Task 4: Endpoint public API + delegate re-surfacing

**Files:**
- Modify: `Sources/ReTiCANode/Endpoint.swift`
- Test: `Tests/ReTiCANodeTests/EndpointTests.swift`

**Interfaces:**
- Consumes: `LinkSession.Action.sendResource(Data)` (Task 3); `LinkSession.Action.Delegate.resourceReceived/resourceConcluded/resourceFailed` (Task 2).
- Produces: `Endpoint.Action.sendResourceOverLink(linkID:data:)`; `Endpoint.Action.Delegate` cases `resourceReceived(linkID:data:)`/`resourceConcluded(linkID:resourceHash:)`/`resourceFailed(linkID:resourceHash:)`.

- [ ] **Step 1: Add the action and delegate cases**

In `Sources/ReTiCANode/Endpoint.swift`:

Add to `Action` (next to `case sendOverLink(linkID:data:)`):
```swift
        case sendResourceOverLink(linkID: Data, data: Data)
```

Add to `Action.Delegate` (after `case linkDataReceived(...)`):
```swift
        case resourceReceived(linkID: Data, data: Data)
        case resourceConcluded(linkID: Data, resourceHash: Data)
        case resourceFailed(linkID: Data, resourceHash: Data)
```

- [ ] **Step 2: Add the reducer cases**

In the `Reduce`, add the send-dispatch case next to `.sendOverLink` (after the `.sendOverLink` case):
```swift
            case let .sendResourceOverLink(linkID, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .sendResource(data))))
```

Add the three delegate-interception cases immediately BEFORE the final catch-all `case .interface, .transport, .delegate, .link:`:
```swift
            case let .link(.element(elementID, .delegate(.resourceReceived(data)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.resourceReceived(linkID: linkID, data: data)))
            case let .link(.element(elementID, .delegate(.resourceConcluded(hash)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.resourceConcluded(linkID: linkID, resourceHash: hash)))
            case let .link(.element(elementID, .delegate(.resourceFailed(hash)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.resourceFailed(linkID: linkID, resourceHash: hash)))
```

- [ ] **Step 3: Write the Endpoint-level tests**

Append to `Tests/ReTiCANodeTests/EndpointTests.swift` (reuse the existing `makeStore`/helpers; these tests drive a single Endpoint with a hand-built active link element):

```swift
@Test @MainActor func sendResourceOverLinkDispatchesToTheMatchingLink() async {
    let clock = TestClock()
    let store = TestStore(initialState: {
        var s = Endpoint.State(host: "n", port: 4242, reconnectOnDrop: false)
        var link = LinkSession.State(id: UUID(0), responderFor: Identity(),
                                     destinationHash: Data(repeating: 0x02, count: 16),
                                     interfaceID: InterfaceID("tcp"))
        link.status = .active
        link.sessionKey = Data(repeating: 0x01, count: 64)
        link.linkID = Data(repeating: 0xAB, count: 16)
        link.rtt = 1.0
        s.links.append(link)
        return s
    }()) { Endpoint() } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.sendResourceOverLink(linkID: Data(repeating: 0xAB, count: 16), data: Data("hi".utf8)))
    await store.receive { if case .link(.element(_, .sendResource)) = $0 { return true }; return false }
    #expect(store.state.links[0].transfers.count == 1)
    // Cleanup: cancel the spawned transfer.
    let tid = store.state.links[0].transfers[0].id
    await store.send(.link(.element(id: UUID(0), action: .transfer(.element(id: tid, action: .cancel)))))
}

@Test @MainActor func resourceReceivedDelegateSurfacesWithLinkID() async {
    let clock = TestClock()
    let linkID = Data(repeating: 0xAB, count: 16)
    let store = TestStore(initialState: {
        var s = Endpoint.State(host: "n", port: 4242, reconnectOnDrop: false)
        var link = LinkSession.State(id: UUID(0), responderFor: Identity(),
                                     destinationHash: Data(repeating: 0x02, count: 16),
                                     interfaceID: InterfaceID("tcp"))
        link.status = .active; link.sessionKey = Data(repeating: 0x01, count: 64); link.linkID = linkID; link.rtt = 1.0
        s.links.append(link)
        return s
    }()) { Endpoint() } withDependencies: {
        $0.continuousClock = clock; $0.date = .constant(Date(timeIntervalSince1970: 0)); $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    // Simulate the hosted link emitting a resourceReceived delegate.
    let payload = Data("assembled".utf8)
    let got = LockIsolated<(Data, Data)?>(nil)
    await store.send(.link(.element(id: UUID(0), action: .delegate(.resourceReceived(payload)))))
    await store.receive { action in
        if case let .delegate(.resourceReceived(lid, d)) = action { got.setValue((lid, d)); return true }
        return false
    }
    #expect(got.value?.0 == linkID)
    #expect(got.value?.1 == payload)
}
```

> Note: `UUID(0)` is the deterministic UUID helper used across the TCA test-suite (`.incrementing` starts at `00000000-0000-0000-0000-000000000000`). If the codebase uses a different zero-UUID spelling, match the existing `EndpointTests` convention.

- [ ] **Step 4: Run to verify**

Run: `swift test --filter Endpoint`
Expected: PASS — the two new tests plus the existing Endpoint tests.

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter Endpoint`, confirm the named test fails, revert; final green:
- In `.sendResourceOverLink`, change the lookup predicate to `{ $0.linkID == Data() }` → `sendResourceOverLinkDispatchesToTheMatchingLink` fails (no dispatch).
- In the `.resourceReceived` interception, change `linkID: linkID` to `linkID: Data()` → `resourceReceivedDelegateSurfacesWithLinkID` fails (wrong linkID surfaced).

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCANode/Endpoint.swift Tests/ReTiCANodeTests/EndpointTests.swift
git commit -F /tmp/ReTiCA/commit-t4.txt
```
(First line: `feat: Endpoint sendResourceOverLink + resource delegates`, blank line, trailers.)

---

### Task 5: End-to-end two-Endpoint resource transfer, gate, README

**Files:**
- Modify: `Tests/ReTiCANodeTests/EndpointTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–4.

- [ ] **Step 1: Write the end-to-end resource-transfer test**

Append to `Tests/ReTiCANodeTests/EndpointTests.swift`. Model it on `twoEndpointsEstablishLinkExchangeDataAndClose` (lines 252–336): the two-store `make(...)` helper, `.connect`/announce/openLink handshake through both sides reaching `.active`. Then transfer a resource. Use a payload that fits in a SINGLE window (≤4 parts at SDU 464) so the pump is linear — e.g. ~600 bytes → 2 parts.

```swift
@Test @MainActor func twoEndpointsTransferAResourceOverALink() async {
    let clock = TestClock()
    let bIdentity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: bIdentity)!

    func make(_ host: String, _ sent: LockIsolated<[Data]>) -> (TestStore<Endpoint.State, Endpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: Endpoint.State(host: host, port: 4242, reconnectOnDrop: false)) {
            Endpoint()
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } },
                                             close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    let sentA = LockIsolated<[Data]>([]); let sentB = LockIsolated<[Data]>([])
    let (a, eventsA) = make("a", sentA)
    let (b, eventsB) = make("b", sentB)

    // --- Establish the link (mirrors twoEndpointsEstablishLinkExchangeDataAndClose steps 1–4) ---
    await a.send(.connect); eventsA.yield(.connected); await a.receive(\.transport.interfaceConnected)
    await b.send(.registerLocalDestination(dest))
    await b.send(.connect); eventsB.yield(.connected); await b.receive(\.transport.interfaceConnected)
    await b.send(.announce(destinationHash: dest.hash, appData: nil))
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received); await a.receive(\.delegate.pathLearned)
    await a.send(.openLink(destinationHash: dest.hash))
    await a.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await a.receive { if case .interface(.send) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received); await b.receive(\.transport.delegate.linkRequest)
    await b.receive { if case .interface(.send) = $0 { return true }; return false }
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    await a.receive { if case .interface(.send) = $0 { return true }; return false }
    await a.receive(\.delegate.linkEstablished)
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received); await b.receive(\.delegate.linkEstablished)
    let linkID = a.state.links[0].linkID
    #expect(a.state.links[0].status == .active && b.state.links[0].status == .active)

    // --- A sends a 2-part resource to B; B assembles it; A concludes. ---
    let payload = Data((0..<600).map { UInt8($0 & 0xff) })     // > 1 part at SDU 464, ≤ 4 parts → one window
    await a.send(.sendResourceOverLink(linkID: linkID, data: payload))
    await a.receive { if case .interface(.send) = $0 { return true }; return false }   // RESOURCE_ADV out
    // ADV → B: spawns a receiver, emits RESOURCE_REQ.
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    await b.receive { if case .interface(.send) = $0 { return true }; return false }   // RESOURCE_REQ out
    // REQ → A: A serves its parts.
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    let partCount = a.state.links[0].transfers[0].parts.count
    for _ in 0..<partCount {
        await a.receive { if case .interface(.send) = $0 { return true }; return false }
    }
    // Deliver every part frame A emitted (the last `partCount` frames in sentA) to B.
    let parts = Array(sentA.value.suffix(partCount))
    let got = LockIsolated<Data?>(nil)
    for (i, frame) in parts.enumerated() {
        eventsB.yield(.data(frame))
        await b.receive(\.transport.received)
        if i == partCount - 1 {
            await b.receive { if case .interface(.send) = $0 { return true }; return false }   // RESOURCE_PRF out
            await b.receive { action in
                if case let .delegate(.resourceReceived(lid, d)) = action, lid == linkID { got.setValue(d); return true }
                return false
            }
        }
    }
    #expect(got.value == payload)
    // PRF → A: A validates and concludes.
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    await a.receive { action in
        if case let .delegate(.resourceConcluded(lid, _)) = action, lid == linkID { return true }
        return false
    }
    #expect(a.state.links[0].transfers[0].status == .complete)

    // Close the link to cancel the link timers, then disconnect.
    await a.send(.closeLink(linkID: linkID))
    await a.receive { if case .interface(.send) = $0 { return true }; return false }
    await a.receive(\.delegate.linkClosed)
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received); await b.receive(\.delegate.linkClosed)
    await a.send(.disconnect); await b.send(.disconnect)
}
```

> Implementer note: this test drives packet routing directly and never calls `clock.advance`, so neither the link keepalive/inactivity timers nor the resource watchdogs fire — the transfer completes deterministically and its watchdog is cancelled on completion. If TCA effect-ordering requires a small adjustment (e.g. an extra `.receive` for an intermediate action, or reordering a deliver), make it while keeping ALL assertions (`got.value == payload`, both `.complete`, the linkID-keyed delegates) intact. Do NOT weaken an assertion to force a pass. If the 2-part assumption doesn't hold for the 600-byte payload at SDU 464, adjust the payload size (keep it >1 and ≤4 parts) rather than the assertions.

- [ ] **Step 2: Run the filtered suite**

Run: `swift test --filter Endpoint`
Expected: PASS.

- [ ] **Step 3: Run the full suite (gate)**

Run: `swift test`
Expected: PASS — all prior suites plus the new dependency/LinkSession/Endpoint tests.

- [ ] **Step 4: Mutation sweep (cross-cutting)**

Apply each, run the named filter, confirm the expected failure, revert; final full `swift test` green:
- In `LinkSession`'s `resourceAdvertisement` case, change `.accept(data)` to `.received(data)` → `twoEndpointsTransferAResourceOverALink` fails (receiver never accepts the ad, so no REQ/parts flow and `got.value != payload`); run `swift test --filter Endpoint`.
- In `Endpoint`'s `.resourceConcluded` interception, change `linkID: linkID` to `linkID: Data()` → `twoEndpointsTransferAResourceOverALink` fails (the `resourceConcluded` linkID no longer matches, so the final `.receive` predicate never fires); run `swift test --filter Endpoint`.
Run `swift test` after reverting both → green.

- [ ] **Step 5: Update the README**

In `README.md`, add a subsection after the resource-transfer sections:

```markdown
### Sending resources over a link (`Endpoint`)

Once a link is established, a resource is sent end-to-end through the public API:

- `Endpoint.sendResourceOverLink(linkID:data:)` hands the bytes to that link's `LinkSession`, which
  spawns a sender `ResourceTransfer` (its random prefix/hash come from the `RandomBytes` dependency) and
  advertises it.
- The peer `LinkSession` recognises the inbound `RESOURCE_ADV`, spawns a receiver transfer (deduping
  re-advertisements by resource hash), and drives the windowed request/serve/assemble/prove exchange —
  all resource packets ride the link's existing transmit path.
- Completion surfaces as `Endpoint` delegates: `resourceReceived(linkID:data:)` on the receiver, and
  `resourceConcluded(linkID:resourceHash:)` / `resourceFailed(linkID:resourceHash:)` on either side.

`ResourceTransfer` instances live inside their `LinkSession` (link-scoped). Terminal transfers are
retained (no GC yet); MTU/SDU negotiation, multi-segment, and compression remain future slices.
```

- [ ] **Step 6: Commit**

```
git add Tests/ReTiCANodeTests/EndpointTests.swift README.md
git commit -F /tmp/ReTiCA/commit-t5.txt
```
(First line: `test: end-to-end two-Endpoint resource transfer; docs`, blank line, trailers.)

---

## Self-Review

**Spec coverage:**
- `RandomBytes` dependency (live/test) → Task 1. ✓
- Transfers hosted in LinkSession via `.forEach` → Task 2. ✓
- Inbound ADV spawn + race-free dedup + broadcast routing → Task 2. ✓
- New LinkSession delegates + interception → Task 2 (received/failed) & used by Task 3 (concluded). ✓
- `sendResource` sender path → Task 3. ✓
- Endpoint `sendResourceOverLink` + re-surfaced delegates → Task 4. ✓
- Two-Endpoint E2E + gate + README → Task 5. ✓
- Deferred (GC, MTU negotiation, multi-segment, compression) → untouched. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. The two implementer notes (UUID spelling in Task 4, E2E part-count/effect-ordering in Task 5) are guidance for matching existing conventions, not missing implementation.

**Type consistency:** `transfers`/`.transfer(IdentifiedActionOf<ResourceTransfer>)`/`resourceReceived(Data)`/`resourceConcluded(Data)`/`resourceFailed(Data)` (LinkSession) and `sendResourceOverLink(linkID:data:)`/`resourceReceived(linkID:data:)`/`resourceConcluded(linkID:resourceHash:)`/`resourceFailed(linkID:resourceHash:)` (Endpoint) are used identically across Tasks 2–5. `RandomBytesGenerator`/`randomBytes` names match between Task 1 and Task 3. `resourceSDU = 464` defined in Task 3 and referenced only there. The `ResourceTransfer` init signatures match the merged 6c code (`receivingOn:sessionKey:interfaceID:rtt:id:` and `sending:linkID:sessionKey:interfaceID:prefix:randomHash:sdu:rtt:id:`).
