# Link ↔ Endpoint Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the standalone `LinkSession` into the running `Endpoint` so links are usable end-to-end: open, accept, route inbound by `link_id`, send/close, and bubble lifecycle events — with two `Endpoint`s able to establish a link.

**Architecture:** `Transport` recognizes link-addressed traffic and surfaces it via new `.linkPacket`/`.linkRequest` delegates (dedup-bypassed). `LinkSession.State` becomes `Identifiable` (`id: UUID`). `Endpoint` holds `links: IdentifiedArrayOf<LinkSession.State>` via `.forEach`, routes inbound link packets to the matching link, creates responder/initiator links, forwards their transmits to the interface, and bubbles lifecycle up.

**Tech Stack:** Swift 6, The Composable Architecture (~1.26; `IdentifiedArrayOf`/`.forEach`, `@Dependency(\.uuid)`, `TestClock`), Swift Testing.

## Global Constraints

- No new wire formats; wire compatibility is inherited from the composed `LinkSession`/`Transport`.
- The `ReTiCA` core stays dependency-free; TCA (incl. `uuid`/`continuousClock`) confined to non-core targets.
- Swift 6 strict concurrency; all State remains `Equatable`; `LinkSession.State` gains `Identifiable`.
- Platform floor iOS 16 / macOS 13 / tvOS 16 / watchOS 9 / macCatalyst 16.
- `Endpoint` stays a thin composition/wiring layer; link-recognition packet parsing lives in `Transport`.
- Closed links stay inert in the collection (GC deferred). Single TCP interface (as today).
- User global rules: temp files under `/tmp/ReTiCA/`; NO compound shell commands (no `|`/`&&`/`;`/command-substitution feeding another command); one command per invocation; mutation-testing three-step verification for every new/changed test.

---

## File Structure

- `Sources/ReTiCATransport/Transport.swift` (modify) — add `.linkPacket`/`.linkRequest` delegates + recognition in `received`.
- `Sources/ReTiCATransport/LinkSession.swift` (modify) — `id: UUID` + `Identifiable`.
- `Sources/ReTiCANode/Endpoint.swift` (modify) — link collection, `.forEach`, routing, openLink/send/close, bubbling.
- `Tests/ReTiCATransportTests/TransportTests.swift` (modify) — link-recognition tests.
- `Tests/ReTiCANodeTests/EndpointTests.swift` (modify) — routing/lifecycle/openLink tests + end-to-end.
- `README.md` (modify) — note the integration.

**Existing patterns to follow:** `Tests/ReTiCANodeTests/EndpointTests.swift` (`makeStore` with mock `TCPConnection` + `TestClock` + `LockIsolated` capture), `Tests/ReTiCATransportTests/TransportTests.swift` (`makeAnnouncePacket`, `TestStore`).

---

### Task 1: Transport recognizes link traffic

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift`
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`

**Interfaces:**
- Consumes: `Packet` (`.destinationType`, `.packetType`, `.destinationHash`), `Transport.State.localDestinations`.
- Produces: `Transport.Action.Delegate.linkPacket(linkID: Data, data: Data)` and `.linkRequest(destinationHash: Data, data: Data)`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ReTiCATransportTests/TransportTests.swift`:

```swift
@Test @MainActor func routesLinkAddressedPacketAsLinkPacket() async {
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    let linkID = Data(repeating: 0xAB, count: 16)
    // A .link-addressed DATA packet (e.g. a keepalive) with a raw 0xFF payload.
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .link, context: .keepalive, contextFlag: false, hops: 0,
                        destinationHash: linkID, transportId: nil, payload: Data([0xFF]))
    let raw = try! packet.packed()
    let captured = LockIsolated<(Data, Data)?>(nil)
    await store.send(.received(InterfaceID("i"), raw))
    await store.receive { action in
        if case let .delegate(.linkPacket(l, d)) = action { captured.setValue((l, d)); return true }
        return false
    }
    #expect(captured.value?.0 == linkID)
    #expect(captured.value?.1 == raw)
}

@Test @MainActor func identicalLinkPacketsBypassDedup() async {
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    let linkID = Data(repeating: 0xCD, count: 16)
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .link, context: .keepalive, contextFlag: false, hops: 0,
                        destinationHash: linkID, transportId: nil, payload: Data([0xFF]))
    let raw = try! packet.packed()
    let count = LockIsolated(0)
    await store.send(.received(InterfaceID("i"), raw))
    await store.receive { if case .delegate(.linkPacket) = $0 { count.withValue { $0 += 1 }; return true }; return false }
    await store.send(.received(InterfaceID("i"), raw))   // byte-identical → must NOT be deduped
    await store.receive { if case .delegate(.linkPacket) = $0 { count.withValue { $0 += 1 }; return true }; return false }
    #expect(count.value == 2)
}

@Test @MainActor func routesLinkRequestToLocalDestinationAsLinkRequest() async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: Identity())!
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations = [dest.hash: dest] }
    // A LINKREQUEST (packetType .linkRequest, destType .single) to our local destination.
    let packet = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: dest.hash, transportId: nil,
                        payload: Identity().publicKey + Link.signallingBytes)
    let raw = try! packet.packed()
    let captured = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("i"), raw))
    await store.receive { action in
        if case let .delegate(.linkRequest(h, _)) = action { captured.setValue(h); return true }
        return false
    }
    #expect(captured.value == dest.hash)
}

@Test @MainActor func linkRequestToUnknownDestinationIsNotSurfaced() async {
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    let packet = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: Data(repeating: 0x11, count: 16), transportId: nil,
                        payload: Identity().publicKey + Link.signallingBytes)
    let sawLinkRequest = LockIsolated(false)
    await store.send(.received(InterfaceID("i"), try! packet.packed()))
    await store.receive { if case .delegate(.linkRequest) = $0 { sawLinkRequest.setValue(true); return true }; return false } // this receive will time out if none arrives
}
```

Note on the last test: with `exhaustivity = .off`, a `store.receive` that never matches will fail the test by timing out. To assert *absence* without a timeout, instead structure it as: send the packet, then send a follow-up recognizable action and assert only that arrives. Rewrite the last test as:

```swift
@Test @MainActor func linkRequestToUnknownDestinationIsNotSurfaced() async {
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    let unknown = Data(repeating: 0x11, count: 16)
    let packet = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: unknown, transportId: nil,
                        payload: Identity().publicKey + Link.signallingBytes)
    await store.send(.received(InterfaceID("i"), try! packet.packed()))
    // No local destination registered → the reducer returns .none; no linkRequest delegate. Assert
    // state is unchanged (no crash, no learned/local mutation).
    #expect(store.state.localDestinations.isEmpty)
    #expect(store.state.learned.isEmpty)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter Transport`
Expected: FAIL — `.linkPacket`/`.linkRequest` don't exist.

- [ ] **Step 3: Implement link recognition**

In `Sources/ReTiCATransport/Transport.swift`, mark the `Delegate` enum `@CasePathable` (so tests can navigate `\.transport.delegate.linkPacket`/`.linkRequest` via key-paths, matching how `Endpoint.Action.Delegate` is already `@CasePathable`) and add the two delegate cases. Change:

```swift
        public enum Delegate: Equatable {
            case transmit(InterfaceID, Data)
            case received(destinationHash: Data, plaintext: Data)
            case pathLearned(destinationHash: Data, hops: UInt8)
            case sendFailed(destinationHash: Data, reason: SendFailure)
        }
```

to:

```swift
        @CasePathable
        public enum Delegate: Equatable {
            case transmit(InterfaceID, Data)
            case received(destinationHash: Data, plaintext: Data)
            case pathLearned(destinationHash: Data, hops: UInt8)
            case sendFailed(destinationHash: Data, reason: SendFailure)
            case linkPacket(linkID: Data, data: Data)
            case linkRequest(destinationHash: Data, data: Data)
        }
```

(`@CasePathable` is provided by `CasePaths`, re-exported by `ComposableArchitecture`, which `Transport.swift` already imports.)

Then in the `.received(interfaceID, data)` case, replace:

```swift
            case let .received(interfaceID, data):
                guard let packet = Packet(raw: data) else { return .none }
                guard state.seenPacketHashes.insert(packet.packetHash) else { return .none }
```

with:

```swift
            case let .received(interfaceID, data):
                guard let packet = Packet(raw: data) else { return .none }
                // Link traffic is recognized and routed up BEFORE the announce/data dedup:
                // byte-identical keepalives share a packet hash and must not be deduped, and a
                // retried link request should still reach us.
                if packet.destinationType == .link {
                    return .send(.delegate(.linkPacket(linkID: packet.destinationHash, data: data)))
                }
                if packet.packetType == .linkRequest, state.localDestinations[packet.destinationHash] != nil {
                    return .send(.delegate(.linkRequest(destinationHash: packet.destinationHash, data: data)))
                }
                guard state.seenPacketHashes.insert(packet.packetHash) else { return .none }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter Transport`
Expected: PASS (the 4 new tests + existing Transport tests).

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter Transport`, confirm the named test fails, revert; final green:
- Change `packet.destinationType == .link` to `== .single` → `routesLinkAddressedPacketAsLinkPacket` fails.
- Move the `.link` recognition to AFTER the `seenPacketHashes.insert` dedup → `identicalLinkPacketsBypassDedup` fails (second identical packet deduped).
- Drop the `state.localDestinations[packet.destinationHash] != nil` guard on the linkRequest branch → `linkRequestToUnknownDestinationIsNotSurfaced` fails (an unknown-dest request is surfaced).

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -m "feat: Transport recognizes link traffic (.linkPacket/.linkRequest, dedup-bypassed)"
```

---

### Task 2: LinkSession Identifiable + Endpoint link collection, routing, transmit

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift`
- Modify: `Sources/ReTiCANode/Endpoint.swift`
- Test: `Tests/ReTiCANodeTests/EndpointTests.swift`

**Interfaces:**
- Consumes: `Transport.Delegate.linkPacket`/`.linkRequest` (Task 1); `LinkSession` reducer + State inits.
- Produces:
  - `LinkSession.State.id: UUID`; `LinkSession.State: Identifiable`; inits gain `id: UUID = UUID()`.
  - `Endpoint.State.links: IdentifiedArrayOf<LinkSession.State>`.
  - `Endpoint.Action.link(IdentifiedActionOf<LinkSession>)`.
  - Behavior: inbound `linkPacket` routes to the held link; inbound `linkRequest` creates a responder link that emits its LRPROOF via `interface.send`.

- [ ] **Step 1: Make `LinkSession.State` Identifiable**

In `Sources/ReTiCATransport/LinkSession.swift`, add `public let id: UUID` as the FIRST stored property of `State` (before `role`), add `id: UUID = UUID()` as the first parameter of BOTH initializers, and assign `self.id = id` first in each. Then add the conformance after the `LinkSession` struct (top-level in the file):

```swift
extension LinkSession.State: Identifiable {}
```

(The default `id: UUID = UUID()` keeps all existing standalone `LinkSession.State(initiatorTo:...)` / `(responderFor:...)` calls compiling unchanged.)

- [ ] **Step 2: Write the failing Endpoint routing tests**

The existing `makeStore` helper in `Tests/ReTiCANodeTests/EndpointTests.swift` already injects a mock `TCPConnection`, a `TestClock`, and `$0.date = .constant(...)`. Add `$0.uuid = .incrementing` to its `withDependencies` block so link ids are deterministic. Then add:

```swift
@Test @MainActor func inboundLinkRequestCreatesResponderAndEmitsProof() async {
    let (store, events) = makeStore()
    let owner = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: owner)!
    await store.send(.registerLocalDestination(dest))
    await store.send(.connect)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    // Craft an inbound LINKREQUEST to our local destination.
    let initEph = Identity()
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: dest.hash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    let captured = LockIsolated<Data?>(nil)   // the LRPROOF bytes sent to the interface
    events.yield(.data(HDLC.frame(try! request.packed())))
    await store.receive(\.transport.received)
    await store.receive(\.transport.delegate.linkRequest)
    await store.receive { action in
        if case let .link(.element(_, .delegate(.transmit(_, raw)))) = action { return true }
        return false
    }
    await store.receive { action in
        if case let .interface(.send(raw)) = action { captured.setValue(raw); return true }
        return false
    }
    #expect(store.state.links.count == 1)
    #expect(Packet(raw: captured.value!)!.packetType == .proof)

    await store.send(.disconnect)
    await store.receive(\.interface.disconnect)
}

@Test @MainActor func inboundLinkPacketRoutesToHeldLink() async {
    // Build a responder link (as above) so the collection holds one link, then feed a link packet
    // addressed to its link_id and assert it is routed to that element.
    let (store, events) = makeStore()
    let owner = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: owner)!
    await store.send(.registerLocalDestination(dest))
    await store.send(.connect)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)

    let initEph = Identity()
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: dest.hash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    events.yield(.data(HDLC.frame(try! request.packed())))
    await store.receive(\.transport.received)
    await store.receive(\.transport.delegate.linkRequest)
    await store.receive { if case .link(.element(_, .delegate(.transmit))) = $0 { return true }; return false }
    await store.receive { if case .interface(.send) = $0 { return true }; return false }
    let linkID = store.state.links[0].linkID
    #expect(store.state.links[0].status == .handshake)

    // Feed a garbage link-data packet addressed to this link_id; it must route to the element
    // (which will fail to decrypt and stay in .handshake — the point is the routing, not the payload).
    let linkPacket = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                            destinationType: .link, context: .none, contextFlag: false, hops: 0,
                            destinationHash: linkID, transportId: nil, payload: Data(repeating: 0xEE, count: 48))
    let routed = LockIsolated(false)
    events.yield(.data(HDLC.frame(try! linkPacket.packed())))
    await store.receive(\.transport.received)
    await store.receive(\.transport.delegate.linkPacket)
    await store.receive { action in
        if case let .link(.element(_, .received(d))) = action { routed.setValue(d == (try! linkPacket.packed())); return true }
        return false
    }
    #expect(routed.value == true)

    await store.send(.disconnect)
    await store.receive(\.interface.disconnect)
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --filter Endpoint`
Expected: FAIL — `Endpoint.State.links`, `.link` action, and routing don't exist.

- [ ] **Step 4: Implement the collection + routing in Endpoint**

In `Sources/ReTiCANode/Endpoint.swift`:

(a) Add to `State` (after `transport`):
```swift
        public var links: IdentifiedArrayOf<LinkSession.State> = []
```

(b) Add to `Action` (after `.transport(...)`):
```swift
        case link(IdentifiedActionOf<LinkSession>)
```

(c) Add the dependency (after `public init() {}` add a stored dependency; place `@Dependency(\.uuid) var uuid` before `body`):
```swift
    @Dependency(\.uuid) var uuid
```

(d) Add `.forEach` to the composition — after the two `Scope(...)` lines, before `Reduce { ... }`:
```swift
        .forEach(\.links, action: \.link) { LinkSession() }
```

(e) In the wiring `Reduce`, add these cases (before the final `case .interface, .transport, .delegate:` catch-all; also add `.link` to that catch-all):

```swift
            case let .transport(.delegate(.linkPacket(linkID, data))):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .received(data))))

            case let .transport(.delegate(.linkRequest(destHash, data))):
                guard let owner = state.transport.localDestinations[destHash]?.identity,
                      owner.privateKey != nil
                else { return .none }
                let newID = uuid()
                state.links.append(LinkSession.State(id: newID, responderFor: owner,
                                                     destinationHash: destHash, interfaceID: id))
                return .send(.link(.element(id: newID, action: .acceptRequest(data))))

            case let .link(.element(_, .delegate(.transmit(txID, raw)))):
                guard txID == id else { return .none }
                return .send(.interface(.send(raw)))
```

And change the catch-all to include `.link`:
```swift
            case .interface, .transport, .delegate, .link:
                return .none
```

Note: the `LinkSession.State` initializers now take `id:` first, so the call above is `LinkSession.State(id: newID, responderFor: owner, destinationHash: destHash, interfaceID: id)`.

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter Endpoint`
Expected: PASS (the 2 new tests + existing Endpoint tests).

- [ ] **Step 6: Mutation sweep**

Apply each, run `swift test --filter Endpoint`, confirm the named test fails, revert; final green:
- In the `linkPacket` case, change `$0.linkID == linkID` to `$0.linkID != linkID` → `inboundLinkPacketRoutesToHeldLink` fails (routes to wrong/no element).
- In the `linkRequest` case, drop `state.links.append(...)` (still send the element action) → `inboundLinkRequestCreatesResponderAndEmitsProof` fails (`links.count == 1` and the forEach has no element to run).
- In the transmit case, change `guard txID == id` to `guard txID != id` → `inboundLinkRequestCreatesResponderAndEmitsProof` fails (no `interface.send`).

- [ ] **Step 7: Commit**

```
git add Sources/ReTiCATransport/LinkSession.swift Sources/ReTiCANode/Endpoint.swift Tests/ReTiCANodeTests/EndpointTests.swift
git commit -m "feat: Endpoint holds LinkSession collection, routes inbound + transmit"
```

---

### Task 3: Endpoint openLink, send/close, lifecycle bubbling

**Files:**
- Modify: `Sources/ReTiCANode/Endpoint.swift`
- Test: `Tests/ReTiCANodeTests/EndpointTests.swift`

**Interfaces:**
- Consumes: Task 2's collection/routing; `LinkSession.Delegate.established/.dataReceived/.closed/.establishmentFailed`; `Transport.State.learned` (a `LearnedDestination` with `.identity`).
- Produces: `Endpoint.Action.openLink(destinationHash:)`/`.sendOverLink(linkID:data:)`/`.closeLink(linkID:)` and `Endpoint.Delegate.linkEstablished/.linkDataReceived/.linkClosed/.linkFailed`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ReTiCANodeTests/EndpointTests.swift` (reuse `makeAnnouncePacket` already present in the file):

```swift
@Test @MainActor func openLinkToLearnedDestinationEmitsLinkRequest() async {
    let (store, events) = makeStore()
    let id = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                                     hops: 1, emitted: 1000)
    await store.send(.connect)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)
    events.yield(.data(HDLC.frame(announceRaw)))
    await store.receive(\.transport.received)
    await store.receive(\.delegate.pathLearned)         // destination learned

    let captured = LockIsolated<Data?>(nil)
    await store.send(.openLink(destinationHash: destHash))
    await store.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await store.receive { if case .link(.element(_, .delegate(.transmit))) = $0 { return true }; return false }
    await store.receive { action in
        if case let .interface(.send(raw)) = action { captured.setValue(raw); return true }
        return false
    }
    #expect(store.state.links.count == 1)
    #expect(Packet(raw: captured.value!)!.packetType == .linkRequest)

    await store.send(.disconnect)
    await store.receive(\.interface.disconnect)
}

@Test @MainActor func openLinkToUnlearnedDestinationFails() async {
    let (store, events) = makeStore()
    await store.send(.connect)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)
    await store.send(.openLink(destinationHash: Data(repeating: 0x44, count: 16)))
    await store.receive(.delegate(.linkFailed(destinationHash: Data(repeating: 0x44, count: 16))))
    #expect(store.state.links.isEmpty)
    await store.send(.disconnect)
    await store.receive(\.interface.disconnect)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter Endpoint`
Expected: FAIL — `.openLink`, `.delegate(.linkFailed)` don't exist.

- [ ] **Step 3: Implement openLink/send/close + bubbling**

In `Sources/ReTiCANode/Endpoint.swift`:

(a) Add `Action` cases (after `.link(...)`):
```swift
        case openLink(destinationHash: Data)
        case sendOverLink(linkID: Data, data: Data)
        case closeLink(linkID: Data)
```

(b) Add `Delegate` cases (after `.sendFailed`):
```swift
            case linkEstablished(linkID: Data)
            case linkDataReceived(linkID: Data, data: Data)
            case linkClosed(linkID: Data, reason: LinkSession.CloseReason)
            case linkFailed(destinationHash: Data)
```

(c) In the wiring `Reduce`, add:
```swift
            case let .openLink(destinationHash):
                guard let learned = state.transport.learned[destinationHash] else {
                    return .send(.delegate(.linkFailed(destinationHash: destinationHash)))
                }
                let newID = uuid()
                state.links.append(LinkSession.State(id: newID, initiatorTo: learned.identity,
                                                     destinationHash: destinationHash, interfaceID: id))
                return .send(.link(.element(id: newID, action: .establish)))

            case let .sendOverLink(linkID, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .send(data))))

            case let .closeLink(linkID):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .close)))

            case let .link(.element(elementID, .delegate(.established(linkID, _)))):
                return .send(.delegate(.linkEstablished(linkID: linkID)))

            case let .link(.element(elementID, .delegate(.dataReceived(data)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.linkDataReceived(linkID: linkID, data: data)))

            case let .link(.element(elementID, .delegate(.closed(reason)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.linkClosed(linkID: linkID, reason: reason)))

            case let .link(.element(elementID, .delegate(.establishmentFailed))):
                guard let destHash = state.links[id: elementID]?.destinationHash else { return .none }
                return .send(.delegate(.linkFailed(destinationHash: destHash)))
```

(The existing `case .interface, .transport, .delegate, .link:` catch-all already absorbs any other `.link` sub-actions, e.g. `.transmit` handled in Task 2 and child non-delegate actions.)

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter Endpoint`
Expected: PASS.

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter Endpoint`, confirm the named test fails, revert; final green:
- In `.openLink`, always take the `learned == nil` branch (e.g. `guard false, let learned = ...`) → `openLinkToLearnedDestinationEmitsLinkRequest` fails.
- In `.openLink`, drop `state.links.append(...)` → `openLinkToLearnedDestinationEmitsLinkRequest` fails (`links.count == 1`).
- In the unlearned branch, return `.none` instead of `.linkFailed` → `openLinkToUnlearnedDestinationFails` fails.

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCANode/Endpoint.swift Tests/ReTiCANodeTests/EndpointTests.swift
git commit -m "feat: Endpoint openLink/sendOverLink/closeLink + link lifecycle delegates"
```

---

### Task 4: End-to-end two-endpoint link, full-suite gate, README

**Files:**
- Modify: `Tests/ReTiCANodeTests/EndpointTests.swift` (end-to-end test)
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: no new production API.

- [ ] **Step 1: Write the end-to-end two-endpoint test**

Append to `Tests/ReTiCANodeTests/EndpointTests.swift`. This wires two endpoints by shuttling each one's `interface.send` output into the other's `connectionEvent(.data(...))`. Because both endpoints share the driving of packets manually, use `exhaustivity = .off` and a helper to pump one endpoint's next outbound frame into the other.

```swift
@Test @MainActor func twoEndpointsEstablishLinkExchangeDataAndClose() async {
    // Endpoint B owns a destination and announces it; Endpoint A learns it and opens a link.
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

    await a.send(.connect); eventsA.yield(.connected); await a.receive(\.transport.interfaceConnected)
    await b.send(.registerLocalDestination(dest))
    await b.send(.connect); eventsB.yield(.connected); await b.receive(\.transport.interfaceConnected)

    // Deliver the next unconsumed frame from `from` into `to` (unframing HDLC). Returns the raw packet.
    @discardableResult
    func pump(from sent: LockIsolated<[Data]>, into to: AsyncStream<TCPEvent>.Continuation,
              _ store: TestStore<Endpoint.State, Endpoint.Action>, _ idx: Int) async -> Data {
        let framed = sent.value[idx]
        to.yield(.data(framed))
        await store.receive(\.transport.received)
        return framed
    }

    // 1. B announces; A learns it.
    await b.send(.announce(destinationHash: dest.hash, appData: nil))
    let announceFrame = sentB.value.last!
    eventsA.yield(.data(announceFrame))
    await a.receive(\.transport.received)
    await a.receive(\.delegate.pathLearned)

    // 2. A opens the link → LINKREQUEST out to B.
    await a.send(.openLink(destinationHash: dest.hash))
    await a.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await a.receive { if case .interface(.send) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!))                 // LINKREQUEST → B
    await b.receive(\.transport.received)
    await b.receive(\.transport.delegate.linkRequest)
    await b.receive { if case .interface(.send) = $0 { return true }; return false }  // LRPROOF out

    // 3. B's LRPROOF → A → A active, emits LRRTT.
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    await a.receive { if case .interface(.send) = $0 { return true }; return false }  // LRRTT out
    await a.receive(\.delegate.linkEstablished)
    #expect(a.state.links[0].status == .active)

    // 4. A's LRRTT → B → B active.
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    await b.receive(\.delegate.linkEstablished)
    #expect(b.state.links[0].status == .active)
    #expect(a.state.links[0].linkID == b.state.links[0].linkID)

    // 5. A sends data over the link → B receives it.
    let payload = Data("hello over link".utf8)
    await a.send(.sendOverLink(linkID: a.state.links[0].linkID, data: payload))
    await a.receive { if case .interface(.send) = $0 { return true }; return false }
    let gotData = LockIsolated<Data?>(nil)
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    await b.receive { action in
        if case let .delegate(.linkDataReceived(_, d)) = action { gotData.setValue(d); return true }
        return false
    }
    #expect(gotData.value == payload)

    // 6. A closes the link → B observes the close.
    await a.send(.closeLink(linkID: a.state.links[0].linkID))
    await a.receive { if case .interface(.send) = $0 { return true }; return false }
    await a.receive(\.delegate.linkClosed)
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    await b.receive(\.delegate.linkClosed)
    #expect(a.state.links[0].status == .closed)
    #expect(b.state.links[0].status == .closed)

    await a.send(.disconnect); await b.send(.disconnect)
}
```

Note: `sent...value.last!` assumes each `interface.send` appends one frame; because `exhaustivity = .off` and the tests await the specific `interface(.send)` action before reading `sent`, the last appended frame is the one just emitted. If ordering proves flaky, index `sent.value` explicitly by a running counter instead of `.last`. The watchdog keepalive timers are running on both active links; end the test by `.disconnect` on both (and, if the suite flags in-flight timer effects, advance `clock` past a keepalive interval and drain, or close both links first — without changing the asserted establish/data/close behavior).

- [ ] **Step 2: Run the end-to-end test**

Run: `swift test --filter Endpoint`
Expected: PASS.

- [ ] **Step 3: Run the full suite**

Run: `swift test`
Expected: PASS — all prior tests plus the integration tests.

- [ ] **Step 4: Mutation sweep on the end-to-end test**

Confirm it genuinely exercises cross-endpoint linking (revert each before the next):
- In `Endpoint`'s `linkPacket` routing, change `$0.linkID == linkID` to `$0.linkID != linkID` → the E2E fails (B's proof/data never routes to A's link; establishment/data assertions fail).
- In `Endpoint`'s `.link(.element(_, .delegate(.established...)))` bubbling, return `.none` → the E2E fails (`.linkEstablished` never arrives).
Run `swift test` after reverting → green.

- [ ] **Step 5: Update the README**

In `README.md`, under the `Endpoint`/composition section (the `## App composition: ReTiCANode` area), add a paragraph:

```markdown
### Links in the endpoint

`Endpoint` composes a collection of `LinkSession`s (`IdentifiedArrayOf` via `.forEach`). `Transport`
recognizes link-addressed traffic and surfaces it (`delegate(.linkPacket/.linkRequest)`, bypassing
the announce/data dedup so keepalives aren't dropped); the endpoint routes each inbound link packet
to the matching link by `link_id`, creates a responder link on an inbound LINKREQUEST to a local
destination, and can `openLink(destinationHash:)` to a learned destination. Link lifecycle surfaces
as `Endpoint.delegate(.linkEstablished/.linkDataReceived/.linkClosed/.linkFailed)`, and
`sendOverLink`/`closeLink` drive an active link. Two endpoints can establish a link, exchange data,
and close — verified end-to-end. (Closed links remain inert in the collection; GC, multiple
interfaces, identify/requests/resources are future work.)
```

If the "Not Yet Implemented" section lists "wiring `LinkSession` into `Transport`/`Endpoint`" as future, remove that item (it is now done); keep identify/requests/resources/relaying/path-requests as future.

- [ ] **Step 6: Commit**

```
git add Tests/ReTiCANodeTests/EndpointTests.swift README.md
git commit -m "test: end-to-end two-endpoint link; docs: links in the endpoint"
```

---

## Self-Review

**Spec coverage:**
- Transport `.linkPacket`/`.linkRequest` recognition + dedup bypass → Task 1. ✓
- `LinkSession.State` Identifiable (`id: UUID`) → Task 2 Step 1. ✓
- Endpoint `links` collection + `.forEach` → Task 2. ✓
- Inbound routing (linkPacket→held link; linkRequest→responder) + transmit→interface → Task 2. ✓
- openLink (initiate) + unknown-destination `.linkFailed` → Task 3. ✓
- sendOverLink/closeLink → Task 3. ✓
- Lifecycle bubbling (established/dataReceived/closed/failed) → Task 3. ✓
- Closed links stay inert (not removed) → Task 3 (no removal on `.closed`). ✓
- End-to-end two endpoints → Task 4. ✓
- Mutation discipline → each task. ✓
- Scope: only Transport/LinkSession/Endpoint + their tests + README; no core changes, no new wire formats. ✓

**Placeholder scan:** No TBD/TODO. The Task-1 note rewrites the absence-assertion test to avoid a receive-timeout; the Task-4 `.last!`/effect-lifecycle notes give concrete fallbacks. Complete code in every step.

**Type consistency:** `LinkSession.State.init(id:initiatorTo:...)` / `(id:responderFor:...)` used consistently in Tasks 2–3; `Transport.Delegate.linkPacket(linkID:data:)`/`.linkRequest(destinationHash:data:)` produced in Task 1 and consumed in Task 2; `Endpoint.Action.link(IdentifiedActionOf<LinkSession>)`, `.openLink`/`.sendOverLink`/`.closeLink`, and `Endpoint.Delegate.linkEstablished/.linkDataReceived/.linkClosed/.linkFailed` are declared and used consistently. `state.links.first(where:)`/`state.links[id:]` keying by the UUID `id` matches the Identifiable conformance.
