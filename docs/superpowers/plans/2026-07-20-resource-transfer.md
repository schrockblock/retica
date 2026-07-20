# Resource Transfer State Machine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a minimal single-segment Reticulum Resource transfer as a `ResourceTransfer` TCA reducer (sender + receiver roles) driven over a link session key, wire-compatible with reference RNS 1.3.8.

**Architecture:** A standalone `ResourceTransfer` `@Reducer` (in `ReTiCATransport`), one per resource, `role`-discriminated, interface-agnostic (raw resource-packet bytes in via actions, `delegate(.transmit)` out). Built on the 6a `Resource`/`ResourceAdvertisement` primitives + `Link.encrypt`/`Link.decrypt`. Mirrors how `LinkSession` began.

**Tech Stack:** Swift 6, The Composable Architecture (~1.26), Swift Testing.

## Global Constraints

- Full wire compatibility with RNS 1.3.8 for the control-packet formats and encryption status (verified vs `Packet.py`): RESOURCE_ADV (`.data`/`.resourceAdvertisement` 0x02) and RESOURCE_REQ (`.data`/`.resourceRequest` 0x03) are ENCRYPTED under the link Token; RESOURCE parts (`.data`/`.resource` 0x01) and RESOURCE_PRF (`.proof`/`.resourceProof` 0x05) are RAW. All addressed to the LINK (`.link` destType, destHash = link_id).
- Request plaintext = `0x00 ‖ resource_hash(32) ‖ requested_map_hashes` (0x00 = hashmap not exhausted). RESOURCE_PRF payload = `resource_hash ‖ full_hash(data ‖ hash)` (64 bytes).
- TCA confined to `ReTiCATransport`; the `ReTiCA` core stays dependency-free (unchanged — the reducer consumes the existing core primitives).
- Swift 6 strict concurrency; `ResourceTransfer.State` `Equatable` + `Identifiable` (`id: UUID`).
- Platform floor iOS 16 / macOS 13 / tvOS 16 / watchOS 9 / macCatalyst 16.
- Scope: single-segment, single-window ONLY (request all parts at once). NO windowing, retransmission, part timeouts, watchdog, RESOURCE_HMU, cancel/reject, multi-segment, compression, or Link/Endpoint integration.
- User global rules: temp files under `/tmp/ReTiCA/`; NO compound shell commands (no `|`/`&&`/`;`/command-substitution feeding another command); one command per invocation; mutation-testing three-step verification for every new/changed test.

## Consumed interfaces (already in the core)

- `Resource.buildStream(data:prefix:sessionKey:) -> Data`, `Resource.parts(stream:sdu:) -> [Data]`, `Resource.mapHash(chunk:randomHash:) -> Data`, `Resource.resourceHash(data:randomHash:) -> Data`, `Resource.expectedProof(data:hash:) -> Data`, `Resource.assemble(parts:sessionKey:) -> Data?`, `Resource.verify(data:randomHash:hash:) -> Bool`, `Resource.proofData(data:hash:) -> Data`, `Resource.validateProof(proofData:expectedProof:) -> Bool`.
- `ResourceAdvertisement(transferSize:dataSize:numberOfParts:hash:randomHash:originalHash:segmentIndex:totalSegments:requestID:flags:hashmap:)`, `.pack() -> Data`, `static unpack(_:) -> ResourceAdvertisement?`.
- `Link.encrypt(_:sessionKey:) -> Data`, `Link.decrypt(_:sessionKey:) -> Data?`.
- `Packet` memberwise init + `init?(raw:)` + `.packed()` + `.packetType`/`.context`/`.destinationHash`/`.payload`; `PacketType.data`/`.proof`; `PacketContext.resource`/`.resourceAdvertisement`/`.resourceRequest`/`.resourceProof`; `DestinationType.link`; `InterfaceID`.

---

## File Structure

- `Sources/ReTiCATransport/ResourceTransfer.swift` (new) — the reducer.
- `Tests/ReTiCATransportTests/ResourceTransferTests.swift` (new) — sender + receiver + end-to-end tests.
- `Tests/ReTiCATests/Vectors/generate_fixtures.py` / `fixtures.json` / `VectorFixtures.swift` / `ResourceTransferCrossValidationTests.swift` — the request-format cross-validation.
- `README.md` (modify).

---

### Task 1: ResourceTransfer state + sender

**Files:**
- Create: `Sources/ReTiCATransport/ResourceTransfer.swift`
- Test: `Tests/ReTiCATransportTests/ResourceTransferTests.swift`

**Interfaces:**
- Produces: `ResourceTransfer` reducer; `State` with both initializers; `Action` (`.advertise`/`.accept(Data)`/`.received(Data)`/`.delegate(...)`); `Delegate` (`.transmit(InterfaceID,Data)`/`.received(Data)`/`.concluded`/`.failed`); `Role`/`Status`. Sender behavior only in this task (`.accept` and the receiver part-path are placeholders returning `.none`, implemented in Task 2).

- [ ] **Step 1: Write the failing sender tests**

Create `Tests/ReTiCATransportTests/ResourceTransferTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

private let key = Data(repeating: 0x01, count: 64)
private let linkID = Data(repeating: 0xAB, count: 16)
private let prefix = Data([0x0A, 0x0B, 0x0C, 0x0D])
private let r = Data([0x01, 0x02, 0x03, 0x04])

private func senderState(_ data: Data, sdu: Int = 24) -> ResourceTransfer.State {
    ResourceTransfer.State(sending: data, linkID: linkID, sessionKey: key, interfaceID: InterfaceID("s"),
                           prefix: prefix, randomHash: r, sdu: sdu)
}

@MainActor
private func captureTransmits(_ store: TestStore<ResourceTransfer.State, ResourceTransfer.Action>,
                              count: Int) async -> [Data] {
    let captured = LockIsolated<[Data]>([])
    for _ in 0..<count {
        await store.receive { action in
            if case let .delegate(.transmit(_, raw)) = action { captured.withValue { $0.append(raw) }; return true }
            return false
        }
    }
    return captured.value
}

// Build a RESOURCE_REQ packet asking for all parts of `s`.
private func resourceRequestPacket(_ s: ResourceTransfer.State) -> Data {
    let req = Data([0x00]) + s.resourceHash + s.advertisement!.hashmap
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .resourceRequest, contextFlag: false, hops: 0,
                   destinationHash: linkID, transportId: nil, payload: Link.encrypt(req, sessionKey: key))
    return try! p.packed()
}

@Test @MainActor func senderAdvertiseEmitsResourceAdvertisement() async {
    let data = Data("a small resource to send".utf8)
    let s = senderState(data)
    let store = TestStore(initialState: s) { ResourceTransfer() }
    store.exhaustivity = .off
    await store.send(.advertise) { $0.status = .advertised }
    let raw = (await captureTransmits(store, count: 1))[0]
    let packet = Packet(raw: raw)!
    #expect(packet.context == .resourceAdvertisement)
    let plain = Link.decrypt(packet.payload, sessionKey: key)!
    let adv = ResourceAdvertisement.unpack(plain)!
    #expect(adv.hash == s.resourceHash)
    #expect(adv.numberOfParts == UInt64(s.parts.count))
    #expect(adv.flags == 0x01)
}

@Test @MainActor func senderRespondsToRequestWithAllParts() async {
    let data = Data(repeating: 0x7A, count: 200)   // several parts at sdu 24
    let s = senderState(data)
    let store = TestStore(initialState: s) { ResourceTransfer() }
    store.exhaustivity = .off
    await store.send(.received(resourceRequestPacket(s))) { $0.status = .transferring }
    let raws = await captureTransmits(store, count: s.parts.count)
    // Every emitted part is a raw RESOURCE packet carrying one of the ciphertext chunks.
    let sentChunks = raws.map { Packet(raw: $0)!.payload }
    #expect(raws.allSatisfy { Packet(raw: $0)!.context == .resource })
    #expect(Set(sentChunks) == Set(s.parts))
}

@Test @MainActor func senderConcludesOnValidProofFailsOnBad() async {
    let data = Data("prove it".utf8)
    let s = senderState(data)
    let store = TestStore(initialState: s) { ResourceTransfer() }
    store.exhaustivity = .off

    func proofPacket(_ payload: Data) -> Data {
        let p = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                       destinationType: .link, context: .resourceProof, contextFlag: false, hops: 0,
                       destinationHash: linkID, transportId: nil, payload: payload)
        return try! p.packed()
    }
    let goodProof = Resource.proofData(data: data, hash: s.resourceHash)   // hash ‖ full_hash(data ‖ hash)
    await store.send(.received(proofPacket(goodProof)))
    await store.receive(.delegate(.concluded)) { $0.status = .complete }

    let store2 = TestStore(initialState: senderState(data)) { ResourceTransfer() }
    store2.exhaustivity = .off
    await store2.send(.received(proofPacket(s.resourceHash + Data(repeating: 0x00, count: 32))))
    await store2.receive(.delegate(.failed)) { $0.status = .failed }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ResourceTransfer`
Expected: FAIL — `ResourceTransfer` doesn't exist.

- [ ] **Step 3: Implement the reducer (state + inits + sender)**

Create `Sources/ReTiCATransport/ResourceTransfer.swift`:

```swift
import Foundation
import ComposableArchitecture
import ReTiCA

/// A single-segment Reticulum Resource transfer (one instance per resource) as a TCA feature.
/// Interface-agnostic: raw resource-packet bytes arrive via `advertise`/`accept`/`received`;
/// outbound bytes leave via `delegate(.transmit)`. Uses the pure `Resource` primitives + the
/// link's session key. Single-window: the receiver requests all parts at once.
@Reducer
public struct ResourceTransfer {
    public enum Role: Equatable, Sendable { case sender, receiver }
    public enum Status: Equatable, Sendable { case idle, advertised, requesting, transferring, complete, failed }

    @ObservableState
    public struct State: Equatable, Identifiable {
        public let id: UUID
        public var role: Role
        public var status: Status
        public var interfaceID: InterfaceID
        public var linkID: Data
        public var sessionKey: Data
        public var resourceHash: Data
        // sender
        public var parts: [Data]
        public var partMapHashes: [Data]
        public var advertisement: ResourceAdvertisement?
        public var expectedProof: Data
        // receiver
        public var randomHash: Data
        public var expectedParts: UInt64
        public var receivedParts: [Int: Data]

        /// Sender: build the resource from `data` over the link's session key.
        public init(sending data: Data, linkID: Data, sessionKey: Data, interfaceID: InterfaceID,
                    prefix: Data, randomHash: Data, sdu: Int, id: UUID = UUID()) {
            self.id = id
            self.role = .sender
            self.status = .idle
            self.interfaceID = interfaceID
            self.linkID = linkID
            self.sessionKey = sessionKey
            self.randomHash = randomHash
            let stream = Resource.buildStream(data: data, prefix: prefix, sessionKey: sessionKey)
            let chunks = Resource.parts(stream: stream, sdu: sdu)
            let mapHashes = chunks.map { Resource.mapHash(chunk: $0, randomHash: randomHash) }
            let h = Resource.resourceHash(data: data, randomHash: randomHash)
            self.parts = chunks
            self.partMapHashes = mapHashes
            self.resourceHash = h
            self.expectedProof = Resource.expectedProof(data: data, hash: h)
            self.expectedParts = UInt64(chunks.count)
            self.receivedParts = [:]
            self.advertisement = ResourceAdvertisement(
                transferSize: UInt64(stream.count), dataSize: UInt64(data.count),
                numberOfParts: UInt64(chunks.count), hash: h, randomHash: randomHash, originalHash: h,
                segmentIndex: 0, totalSegments: 1, requestID: nil, flags: 0x01,
                hashmap: mapHashes.reduce(Data()) { $0 + $1 })
        }

        /// Receiver: accept an inbound resource on the given link.
        public init(receivingOn linkID: Data, sessionKey: Data, interfaceID: InterfaceID, id: UUID = UUID()) {
            self.id = id
            self.role = .receiver
            self.status = .idle
            self.interfaceID = interfaceID
            self.linkID = linkID
            self.sessionKey = sessionKey
            self.resourceHash = Data()
            self.parts = []
            self.partMapHashes = []
            self.advertisement = nil
            self.expectedProof = Data()
            self.randomHash = Data()
            self.expectedParts = 0
            self.receivedParts = [:]
        }
    }

    public enum Action: Equatable {
        case advertise
        case accept(Data)
        case received(Data)
        case delegate(Delegate)
        public enum Delegate: Equatable {
            case transmit(InterfaceID, Data)
            case received(Data)
            case concluded
            case failed
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            func linkPacket(_ type: PacketType, _ context: PacketContext, _ payload: Data) -> Data? {
                let p = Packet(headerType: .header1, packetType: type, transportType: .broadcast,
                               destinationType: .link, context: context, contextFlag: false, hops: 0,
                               destinationHash: state.linkID, transportId: nil, payload: payload)
                return try? p.packed()
            }

            switch action {
            case .advertise:
                guard state.role == .sender, state.status == .idle, let adv = state.advertisement,
                      let raw = linkPacket(.data, .resourceAdvertisement,
                                           Link.encrypt(adv.pack(), sessionKey: state.sessionKey))
                else { return .none }
                state.status = .advertised
                return .send(.delegate(.transmit(state.interfaceID, raw)))

            case .accept:
                return .none   // receiver: implemented in Task 2

            case let .received(data):
                guard let packet = Packet(raw: data), packet.destinationHash == state.linkID
                else { return .none }
                switch (state.role, packet.packetType, packet.context) {
                case (.sender, .data, .resourceRequest):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey) else { return .none }
                    let p = Data(plain)
                    guard p.count >= 33, p.first == 0x00,
                          Data(p[(p.startIndex + 1)..<(p.startIndex + 33)]) == state.resourceHash
                    else { return .none }
                    state.status = .transferring
                    let reqHashes = Data(p.dropFirst(33))
                    var effects: [Effect<Action>] = []
                    var i = reqHashes.startIndex
                    while i + 4 <= reqHashes.endIndex {
                        let mh = Data(reqHashes[i..<(i + 4)])
                        if let idx = state.partMapHashes.firstIndex(of: mh),
                           let raw = linkPacket(.data, .resource, state.parts[idx]) {
                            effects.append(.send(.delegate(.transmit(state.interfaceID, raw))))
                        }
                        i += 4
                    }
                    return .merge(effects)

                case (.sender, .proof, .resourceProof):
                    if Resource.validateProof(proofData: packet.payload, expectedProof: state.expectedProof) {
                        state.status = .complete
                        return .send(.delegate(.concluded))
                    }
                    state.status = .failed
                    return .send(.delegate(.failed))

                default:
                    return .none
                }

            case .delegate:
                return .none
            }
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ResourceTransfer`
Expected: PASS (3 sender tests).

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter ResourceTransfer`, confirm the named test fails, revert; final green:
- In `.advertise`, use `context .resource` instead of `.resourceAdvertisement` → `senderAdvertiseEmitsResourceAdvertisement` fails.
- In the request case, change `state.partMapHashes.firstIndex(of: mh)` to always `0` (send `parts[0]` for every request) → `senderRespondsToRequestWithAllParts` fails (`Set(sentChunks) != Set(parts)` for a multi-part resource).
- In the proof case, invert the `validateProof` branch (concluded↔failed) → `senderConcludesOnValidProofFailsOnBad` fails.

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCATransport/ResourceTransfer.swift Tests/ReTiCATransportTests/ResourceTransferTests.swift
git commit -m "feat: ResourceTransfer sender (advertise, serve parts, validate proof)"
```

---

### Task 2: ResourceTransfer receiver

**Files:**
- Modify: `Sources/ReTiCATransport/ResourceTransfer.swift`
- Test: `Tests/ReTiCATransportTests/ResourceTransferTests.swift`

**Interfaces:**
- Consumes: Task 1's state/actions.
- Produces: receiver behavior — `.accept(advRaw)` (decrypt+unpack the advertisement, emit a RESOURCE_REQ for all parts) and the receiver `.data`/`.resource` part handling (place by map-hash, assemble+verify+prove when complete).

- [ ] **Step 1: Write the failing receiver tests**

Append to `Tests/ReTiCATransportTests/ResourceTransferTests.swift`:

```swift
private func receiverState() -> ResourceTransfer.State {
    ResourceTransfer.State(receivingOn: linkID, sessionKey: key, interfaceID: InterfaceID("r"))
}
private func advertisementPacket(_ s: ResourceTransfer.State) -> Data {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .resourceAdvertisement, contextFlag: false, hops: 0,
                   destinationHash: linkID, transportId: nil,
                   payload: Link.encrypt(s.advertisement!.pack(), sessionKey: key))
    return try! p.packed()
}
private func partPacket(_ chunk: Data) -> Data {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .resource, contextFlag: false, hops: 0,
                   destinationHash: linkID, transportId: nil, payload: chunk)
    return try! p.packed()
}

@Test @MainActor func receiverAcceptEmitsRequestForAllParts() async {
    let data = Data(repeating: 0x33, count: 120)
    let sender = senderState(data)
    let store = TestStore(initialState: receiverState()) { ResourceTransfer() }
    store.exhaustivity = .off
    await store.send(.accept(advertisementPacket(sender))) { $0.status = .requesting }
    let raw = (await captureTransmits(store, count: 1))[0]
    let packet = Packet(raw: raw)!
    #expect(packet.context == .resourceRequest)
    let plain = Link.decrypt(packet.payload, sessionKey: key)!
    #expect(plain == Data([0x00]) + sender.resourceHash + sender.advertisement!.hashmap)
    #expect(store.state.expectedParts == UInt64(sender.parts.count))
}

@Test @MainActor func receiverAssemblesPartsAndProves() async {
    let data = Data("the receiver reconstructs this exact payload from parts".utf8)
    let sender = senderState(data)
    let store = TestStore(initialState: receiverState()) { ResourceTransfer() }
    store.exhaustivity = .off
    await store.send(.accept(advertisementPacket(sender)))
    _ = await captureTransmits(store, count: 1)   // the request

    // Feed every part (in reverse to prove order-independence); the last completes the transfer.
    let got = LockIsolated<Data?>(nil)
    for (n, chunk) in sender.parts.enumerated().reversed() {
        await store.send(.received(partPacket(chunk)))
        if n == 0 {   // after the final missing part arrives
            await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }   // the RESOURCE_PRF
            await store.receive { action in
                if case let .delegate(.received(d)) = action { got.setValue(d); return true }
                return false
            }
        }
    }
    #expect(got.value == data)
    #expect(store.state.status == .complete)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ResourceTransfer`
Expected: FAIL — `.accept` is a no-op and the receiver part path is unhandled.

- [ ] **Step 3: Implement the receiver**

In `Sources/ReTiCATransport/ResourceTransfer.swift`, replace the `case .accept: return .none` line with:

```swift
            case let .accept(data):
                guard state.role == .receiver, state.status == .idle,
                      let packet = Packet(raw: data), packet.packetType == .data,
                      packet.context == .resourceAdvertisement,
                      let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                      let adv = ResourceAdvertisement.unpack(plain)
                else { return .none }
                state.resourceHash = adv.hash
                state.randomHash = adv.randomHash
                state.expectedParts = adv.numberOfParts
                state.advertisement = adv
                state.status = .requesting
                let request = Data([0x00]) + adv.hash + adv.hashmap
                guard let raw = linkPacket(.data, .resourceRequest,
                                           Link.encrypt(request, sessionKey: state.sessionKey))
                else { return .none }
                return .send(.delegate(.transmit(state.interfaceID, raw)))
```

And add a receiver case to the `.received` inner switch, BEFORE the `default:`:

```swift
                case (.receiver, .data, .resource):
                    guard state.status == .requesting || state.status == .transferring,
                          let adv = state.advertisement else { return .none }
                    let chunk = packet.payload
                    let mh = Resource.mapHash(chunk: chunk, randomHash: state.randomHash)
                    let m = Data(adv.hashmap)
                    var index: Int? = nil
                    var gi = 0
                    var j = m.startIndex
                    while j + 4 <= m.endIndex {
                        if Data(m[j..<(j + 4)]) == mh { index = gi; break }
                        gi += 1; j += 4
                    }
                    guard let idx = index, state.receivedParts[idx] == nil else { return .none }
                    state.receivedParts[idx] = chunk
                    state.status = .transferring
                    guard state.receivedParts.count == Int(state.expectedParts) else { return .none }
                    let ordered = (0..<Int(state.expectedParts)).compactMap { state.receivedParts[$0] }
                    guard ordered.count == Int(state.expectedParts),
                          let out = Resource.assemble(parts: ordered, sessionKey: state.sessionKey),
                          Resource.verify(data: out, randomHash: state.randomHash, hash: state.resourceHash)
                    else { state.status = .failed; return .send(.delegate(.failed)) }
                    state.status = .complete
                    let proof = Resource.proofData(data: out, hash: state.resourceHash)
                    guard let praw = linkPacket(.proof, .resourceProof, proof)
                    else { return .send(.delegate(.received(out))) }
                    return .merge(.send(.delegate(.transmit(state.interfaceID, praw))),
                                  .send(.delegate(.received(out))))
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ResourceTransfer`
Expected: PASS (sender + receiver tests).

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter ResourceTransfer`, confirm the named test fails, revert; final green:
- In `.accept`, build the request with `Data([0xFF])` instead of `Data([0x00])` (wrong flag) → `receiverAcceptEmitsRequestForAllParts` fails (plaintext mismatch).
- In the receiver part case, pass `ordered.reversed()` to `Resource.assemble` → `receiverAssemblesPartsAndProves` fails (chunks reassembled out of order → wrong data, no `.received(data)`).
- In the receiver part case, change the completion guard to `state.receivedParts.count == 1` → the transfer "completes" after one part → `receiverAssemblesPartsAndProves` fails (assembling one chunk ≠ the data, so `.failed` instead of `.received(data)`).

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCATransport/ResourceTransfer.swift Tests/ReTiCATransportTests/ResourceTransferTests.swift
git commit -m "feat: ResourceTransfer receiver (accept, request all, assemble, prove)"
```

---

### Task 3: End-to-end transfer, request-format cross-validation, gate, README

**Files:**
- Modify: `Tests/ReTiCATransportTests/ResourceTransferTests.swift` (end-to-end)
- Modify: `Tests/ReTiCATests/Vectors/generate_fixtures.py`, regenerate `fixtures.json`, `VectorFixtures.swift`
- Create: `Tests/ReTiCATests/Vectors/ResourceTransferCrossValidationTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–2 and the 6a fixtures.
- Produces: fixture field `resource_request_plaintext`; a `VectorFixtures.resourceRequestPlaintext` property.

**Gotcha (bit this workflow before):** an external linter can revert `generate_fixtures.py`/`fixtures.json`. After regenerating AND after committing, verify `git show HEAD:Tests/ReTiCATests/Vectors/fixtures.json` contains `resource_request_plaintext`; if missing, re-stage and `git commit --amend --no-edit`, then re-verify.

- [ ] **Step 1: Write the end-to-end two-reducer transfer test**

Append to `Tests/ReTiCATransportTests/ResourceTransferTests.swift`:

```swift
@Test @MainActor func endToEndTwoReducerResourceTransfer() async {
    let data = Data("End-to-end resource: sender advertises, receiver requests, parts flow, proof concludes.".utf8)
    let sender = TestStore(initialState: senderState(data)) { ResourceTransfer() }
    sender.exhaustivity = .off
    let receiver = TestStore(initialState: receiverState()) { ResourceTransfer() }
    receiver.exhaustivity = .off

    // 1. Sender advertises → receiver accepts → requests all parts.
    await sender.send(.advertise)
    let adv = (await captureTransmits(sender, count: 1))[0]
    await receiver.send(.accept(adv))
    let req = (await captureTransmits(receiver, count: 1))[0]

    // 2. Sender serves parts → receiver ingests them; the last yields a proof + the data.
    await sender.send(.received(req))
    let partCount = sender.state.parts.count
    let parts = await captureTransmits(sender, count: partCount)
    let got = LockIsolated<Data?>(nil)
    for (n, part) in parts.enumerated() {
        await receiver.send(.received(part))
        if n == partCount - 1 {
            let proofOut = LockIsolated<Data?>(nil)
            await receiver.receive { action in
                if case let .delegate(.transmit(_, raw)) = action { proofOut.setValue(raw); return true }
                return false
            }
            await receiver.receive { action in
                if case let .delegate(.received(d)) = action { got.setValue(d); return true }
                return false
            }
            // 3. Proof → sender concludes.
            await sender.send(.received(proofOut.value!))
            await sender.receive(.delegate(.concluded))
        }
    }
    #expect(got.value == data)                       // receiver reconstructed the ORIGINAL data
    #expect(receiver.state.status == .complete)
    #expect(sender.state.status == .complete)
}
```

- [ ] **Step 2: Add the request-format cross-validation vector**

In `Tests/ReTiCATests/Vectors/generate_fixtures.py`, after the existing resource block (which defines `res_hash` and `res_hashmap`), add:

```python
# --- Resource request plaintext (single-window, hashmap not exhausted): 0x00 ‖ hash ‖ hashmap ---
res_request_plaintext = bytes([0x00]) + res_hash + res_hashmap
```

Then in the `json.dumps({...})` dict, after `"resource_adv_msgpack": res_adv_msgpack.hex(),` add:

```python
    "resource_request_plaintext": res_request_plaintext.hex(),
```

Regenerate: `/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/generate_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/fixtures.json`

Verify: `grep -n "resource_request_plaintext" /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/fixtures.json`
Expected: one line.

- [ ] **Step 3: Decode the new field in VectorFixtures**

In `Tests/ReTiCATests/Vectors/VectorFixtures.swift`, add the property and the CodingKeys case:

```swift
    let resourceRequestPlaintext: String
```
```swift
        case resourceRequestPlaintext = "resource_request_plaintext"
```

- [ ] **Step 4: Write the cross-validation test**

Create `Tests/ReTiCATests/Vectors/ResourceTransferCrossValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func swiftResourceRequestPlaintextMatchesReference() throws {
    let f = try VectorFixtures.load()
    // The single-window request the receiver builds: 0x00 ‖ resource_hash ‖ full hashmap.
    let built = Data([0x00]) + Data(hexString: f.resourceHash)! + referenceHashmap(f)
    #expect(built == Data(hexString: f.resourceRequestPlaintext))
}

// The full hashmap for the reference stream: map hash of each SDU-sized ciphertext chunk.
private func referenceHashmap(_ f: VectorFixtures) -> Data {
    let stream = Data(hexString: f.resourceStream)!
    let r = Data(hexString: f.resourceRandomHash)!
    var m = Data()
    var i = stream.startIndex
    while i < stream.endIndex {
        let end = stream.index(i, offsetBy: f.resourceSdu, limitedBy: stream.endIndex) ?? stream.endIndex
        m.append(Resource.mapHash(chunk: Data(stream[i..<end]), randomHash: r))
        i = end
    }
    return m
}
```

- [ ] **Step 5: Run the cross-validation + full suite**

Run: `swift test --filter Resource`
Expected: PASS (ResourceTransfer + the cross-validation).

Run: `swift test`
Expected: PASS — all prior tests plus the resource-transfer tests.

- [ ] **Step 6: Commit (verify fixtures captured)**

```
git add Tests/ReTiCATransportTests/ResourceTransferTests.swift Tests/ReTiCATests/Vectors/generate_fixtures.py Tests/ReTiCATests/Vectors/fixtures.json Tests/ReTiCATests/Vectors/VectorFixtures.swift Tests/ReTiCATests/Vectors/ResourceTransferCrossValidationTests.swift
git commit -m "test: end-to-end resource transfer + request-format cross-validation vs Python-RNS"
```

After committing, run `git show HEAD:Tests/ReTiCATests/Vectors/fixtures.json` and confirm `resource_request_plaintext` is present; if not, re-stage and `git commit --amend --no-edit`, then re-verify.

- [ ] **Step 7: Mutation sweep**

Apply each production mutation, run the named filter, confirm the named test fails, revert; final `swift test` green. (Both mutate core `Resource` — they also break some 6a tests, which is expected; the point is the named Task-3 test is load-bearing.)
- In `Resource.mapHash` (core), change `.prefix(4)` to `.prefix(8)` → `swiftResourceRequestPlaintextMatchesReference` fails (the built hashmap no longer matches the reference request plaintext). Run `swift test --filter Resource`.
- In `Resource.assemble` (core), drop the `.dropFirst(randomHashSize)` prefix strip → `endToEndTwoReducerResourceTransfer` fails (`got.value != data`). Run `swift test --filter ResourceTransfer`.
Run `swift test` after reverting both → green.

- [ ] **Step 8: Update the README**

In `README.md`, add a subsection near the Resource primitives / Link sections:

```markdown
### Resource transfer (`ResourceTransfer`)

`ResourceTransfer` (in `ReTiCATransport`) drives a single-segment Reticulum resource transfer over
a link's session key, as a TCA reducer with a sender and a receiver role:

- **Sender:** `advertise` emits a `RESOURCE_ADV` (the encrypted `ResourceAdvertisement`); on a
  `RESOURCE_REQ` it sends the requested `RESOURCE` part-packets (raw ciphertext chunks); on the
  `RESOURCE_PRF` proof it validates and reaches `.complete` (`delegate(.concluded)`).
- **Receiver:** `accept` decrypts+unpacks the advertisement and requests all parts in one
  `RESOURCE_REQ` (`0x00 ‖ hash ‖ hashmap`); as `RESOURCE` parts arrive it places each by map-hash,
  and when all are in, reassembles + verifies the data, emits the `RESOURCE_PRF` proof, and surfaces
  the reconstructed data via `delegate(.received(_:))`.

Two `ResourceTransfer` reducers sharing a session key complete a transfer end-to-end. The
control-packet formats and their encryption status (`RESOURCE_ADV`/`RESOURCE_REQ` encrypted;
`RESOURCE` parts and `RESOURCE_PRF` raw) are wire-compatible with Python-RNS 1.3.8. Windowing,
retransmission, hashmap-update, cancel/reject, multi-segment, compression, and wiring
`ResourceTransfer` into `LinkSession`/`Endpoint` are future slices.
```

- [ ] **Step 9: Commit**

```
git add README.md
git commit -m "docs: ResourceTransfer"
```

---

## Self-Review

**Spec coverage:**
- `ResourceTransfer` reducer (role, state, both inits) → Task 1. ✓
- Sender: advertise / serve parts on REQ / validate PRF → Task 1. ✓
- Receiver: accept+request-all / receive parts / assemble+verify+prove → Task 2. ✓
- Wire formats + encryption status (ADV/REQ encrypted, parts/PRF raw, dest .link) → Tasks 1–2 (`linkPacket` + `Link.encrypt`/`decrypt`). ✓
- End-to-end two-reducer transfer → Task 3. ✓
- Cross-validation of the request plaintext format (reusing genuine 6a hash/hashmap vectors) → Task 3. ✓
- Error handling (mismatched packets ignored; bad proof → failed; assembly/verify failure → failed; idempotent parts) → Tasks 1–2 reducer guards. ✓
- Mutation discipline → each task. ✓
- Scope: single-segment/single-window; no windowing/retransmission/HMU/cancel/multi-segment/compression/integration → confirmed; only `ResourceTransfer` + tests + one fixture + README touched. ✓

**Placeholder scan:** No TBD/TODO; complete code in every step. Task-1's `.accept: return .none` is an explicit, intentional placeholder replaced in Task 2 (called out in both tasks), not a plan gap.

**Type consistency:** `ResourceTransfer.State` initializers, `Action`/`Delegate` cases, `Status`/`Role` values, and the `Resource`/`ResourceAdvertisement`/`Link`/`Packet` calls are used identically across Tasks 1–3. `partMapHashes` (sender) vs `advertisement.hashmap` (concatenated) are consistent: the receiver splits `advertisement.hashmap` into 4-byte groups; the sender matches requested 4-byte hashes against `partMapHashes`. The fixture field `resource_request_plaintext` ↔ `VectorFixtures.resourceRequestPlaintext` match between the Task-3 generator and consumer.
