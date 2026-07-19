# Link Establishment State Machine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the Reticulum Link establishment handshake as a standalone TCA `LinkSession` reducer that drives both initiator and responder through PENDING→HANDSHAKE→ACTIVE via the three-packet handshake (LINKREQUEST → LRPROOF → LRRTT), ending with an equal derived session key.

**Architecture:** One `LinkSession` `@Reducer` in the `ReTiCATransport` target with a `role` discriminator and a unified `received(Data)` entry point dispatched by packet type/context; interface-agnostic (raw packet bytes in, `delegate(.transmit)` out). Builds on the merged pure `Link` primitives. Adds a minimal double-only `msgpack` codec to the pure core for the LRRTT payload.

**Tech Stack:** Swift 6, The Composable Architecture (~1.26), Swift Testing, CryptoKit. Cross-validation against Python-RNS 1.3.8.

## Global Constraints

- Full wire compatibility with reference RNS 1.3.8; cross-validation is the proof, and fixtures MUST drive genuine reference code paths (never hand-rolled reimplementations).
- The `ReTiCA` core target has ZERO external dependencies (the `msgpack` codec uses only the Swift stdlib). TCA stays confined to `ReTiCATransport`/other non-core targets.
- Swift 6 strict concurrency; `LinkSession.State` is `Equatable`; `Identity` is already `Equatable, Sendable`.
- Platform floor iOS 16 / macOS 13 / tvOS 16 / watchOS 9 / macCatalyst 16.
- Establish-only scope: NO application data flow, NO close/teardown, NO keepalive/watchdog/timeouts, NO identify/requests/resources/channels, NO MTU negotiation, NO `Transport`/`Endpoint` integration.
- Wire constants (already in `Sources/ReTiCA/Packet/PacketConstants.swift`): `PacketType.linkRequest` (2), `.proof` (3), `.data` (0); `PacketContext.linkRequestProof` (0xFF = RNS LRPROOF), `.linkRequestRTT` (0xFE = RNS LRRTT), `.none` (0x00); `DestinationType.single` (0), `.link` (3).
- The fixed signalling bytes are `0x2001f4` (from 5-links-a), exposed as `Link.signallingBytes`.
- Reference RNS lives in the conda env `rns`; run the fixture generator with its interpreter: `/Users/ell/opt/anaconda3/envs/rns/bin/python`.
- Follow the user's global rules: temp files under `/tmp/ReTiCA/`; NO compound shell commands (no `|`/`&&`/`;`/command-substitution feeding another command); write scripts to a file and run them; mutation-testing three-step verification for every new/changed test.

---

## File Structure

- `Sources/ReTiCA/Support/MsgPack.swift` (new) — minimal double-only MessagePack codec (pure core).
- `Sources/ReTiCA/Link/Link.swift` (modify) — make `signallingBytes` public.
- `Sources/ReTiCATransport/LinkSession.swift` (new) — the establishment reducer.
- `Tests/ReTiCATests/Support/MsgPackTests.swift` (new) — codec unit tests.
- `Tests/ReTiCATests/Vectors/generate_fixtures.py` (modify) — add RTT/msgpack vectors.
- `Tests/ReTiCATests/Vectors/fixtures.json` (regenerate) — add `link_rtt*` fields.
- `Tests/ReTiCATests/Vectors/VectorFixtures.swift` (modify) — decode new fields.
- `Tests/ReTiCATests/Vectors/LinkCrossValidationTests.swift` (modify) — msgpack + RTT decrypt vectors.
- `Tests/ReTiCATransportTests/LinkSessionTests.swift` (new) — TestStore unit + end-to-end tests.
- `README.md` (modify) — Link establishment subsection.

---

### Task 1: MsgPack double codec (pure core)

**Files:**
- Create: `Sources/ReTiCA/Support/MsgPack.swift`
- Test: `Tests/ReTiCATests/Support/MsgPackTests.swift`

**Interfaces:**
- Consumes: nothing (pure stdlib).
- Produces:
  - `public enum MsgPack`
  - `public static func encode(_ value: Double) -> Data` — 9 bytes: `0xCB ‖ bigEndian(value.bitPattern)`.
  - `public static func decodeDouble(_ data: Data) -> Double?` — nil unless exactly `0xCB` tag + 8 bytes.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCATests/Support/MsgPackTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func msgPackEncodesFloat64WithTag() {
    // umsgpack.packb(0.125) == cb 3f c0 00 00 00 00 00 00 (verified vs RNS.vendor.umsgpack)
    #expect(MsgPack.encode(0.125) == Data([0xCB, 0x3F, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
}

@Test func msgPackDoubleRoundTrips() {
    for v in [0.0, 0.125, -1.5, 3.141592653589793, 1234.5] {
        #expect(MsgPack.decodeDouble(MsgPack.encode(v)) == v)
    }
}

@Test func msgPackDecodeRejectsMalformed() {
    #expect(MsgPack.decodeDouble(Data([0x00, 0x01])) == nil)                                   // wrong length
    #expect(MsgPack.decodeDouble(Data([0xCA]) + Data(repeating: 0, count: 8)) == nil)          // float32 tag, right length
    #expect(MsgPack.decodeDouble(Data()) == nil)                                                // empty
    #expect(MsgPack.decodeDouble(Data([0xCB]) + Data(repeating: 0, count: 7)) == nil)          // too short
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter MsgPack`
Expected: FAIL — `cannot find 'MsgPack' in scope`.

- [ ] **Step 3: Implement the codec**

Create `Sources/ReTiCA/Support/MsgPack.swift`:

```swift
import Foundation

/// Minimal MessagePack codec — only the float64 form (`0xCB`) used by Reticulum link RTT
/// packets. `umsgpack.packb(<python float>)` always emits this form. Other MessagePack types
/// are intentionally unimplemented (YAGNI).
public enum MsgPack {
    static let float64Tag: UInt8 = 0xCB

    /// Encode a `Double` as MessagePack float64: `0xCB ‖ big-endian IEEE-754 bits` (9 bytes).
    public static func encode(_ value: Double) -> Data {
        var data = Data([float64Tag])
        var be = value.bitPattern.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        return data
    }

    /// Decode a MessagePack float64. Returns nil unless the input is exactly the 9-byte
    /// `0xCB`-tagged form.
    public static func decodeDouble(_ data: Data) -> Double? {
        let bytes = Data(data) // normalize to 0-based indices
        guard bytes.count == 9, bytes[bytes.startIndex] == float64Tag else { return nil }
        let bits = bytes.dropFirst().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Double(bitPattern: bits)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter MsgPack`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```
git add Sources/ReTiCA/Support/MsgPack.swift Tests/ReTiCATests/Support/MsgPackTests.swift
git commit -m "feat: minimal double-only msgpack codec for link RTT"
```

---

### Task 2: MsgPack + LRRTT cross-validation vs Python-RNS

**Files:**
- Modify: `Tests/ReTiCATests/Vectors/generate_fixtures.py`
- Regenerate: `Tests/ReTiCATests/Vectors/fixtures.json`
- Modify: `Tests/ReTiCATests/Vectors/VectorFixtures.swift`
- Modify: `Tests/ReTiCATests/Vectors/LinkCrossValidationTests.swift`

**Interfaces:**
- Consumes: `MsgPack.encode`, `MsgPack.decodeDouble`, `Link.decrypt` (from Task 1 + merged primitives); existing fixture field `link_derived_key`.
- Produces: fixture fields `link_rtt` (Double), `link_rtt_msgpack` (hex), `link_rtt_packet_ciphertext` (hex); `VectorFixtures` properties `linkRtt`, `linkRttMsgpack`, `linkRttPacketCiphertext`.

**Gotcha (observed 3× on this project):** an external linter/editor can revert `generate_fixtures.py`/`fixtures.json` so a subagent's commit silently drops them. After regenerating, VERIFY the working tree still contains the changes, and confirm the commit captured them via `git show HEAD:Tests/ReTiCATests/Vectors/fixtures.json` before proceeding.

- [ ] **Step 1: Add RTT vectors to the generator**

In `Tests/ReTiCATests/Vectors/generate_fixtures.py`, the Link section already imports `from RNS.Cryptography import Token as LinkToken` and computes `link_derived_key`. Immediately AFTER `link_ciphertext = LinkToken(link_derived_key).encrypt(link_plaintext)`, add:

```python
# --- Link RTT packet (LRRTT) vector: msgpack(rtt) encrypted under the session key ---
import RNS.vendor.umsgpack as umsgpack
link_rtt = 0.125                                    # deterministic fixed RTT
link_rtt_msgpack = umsgpack.packb(link_rtt)         # genuine reference float64 encoding
link_rtt_packet_ciphertext = LinkToken(link_derived_key).encrypt(link_rtt_msgpack)
```

Then, inside the `json.dumps({...})` dictionary, after the `"link_ciphertext": link_ciphertext.hex(),` entry, add:

```python
    "link_rtt": link_rtt,
    "link_rtt_msgpack": link_rtt_msgpack.hex(),
    "link_rtt_packet_ciphertext": link_rtt_packet_ciphertext.hex(),
```

- [ ] **Step 2: Regenerate the fixtures**

Run: `/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/generate_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/fixtures.json`
(single command, one output redirect — no compound shell.)

Then verify the new fields are present:
Run: `grep -n "link_rtt" /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/fixtures.json`
Expected: three lines — `link_rtt`, `link_rtt_msgpack` (starts `cb3fc0000000000000`), `link_rtt_packet_ciphertext`.

- [ ] **Step 3: Decode the new fields in VectorFixtures**

In `Tests/ReTiCATests/Vectors/VectorFixtures.swift`, add three properties to the fixtures struct alongside the existing `link*` properties (matching the file's existing `let` + `CodingKeys` style):

```swift
    let linkRtt: Double
    let linkRttMsgpack: String
    let linkRttPacketCiphertext: String
```

And in the struct's explicit `enum CodingKeys: String, CodingKey` (which is exhaustive — every property needs a case), add:

```swift
        case linkRtt = "link_rtt"
        case linkRttMsgpack = "link_rtt_msgpack"
        case linkRttPacketCiphertext = "link_rtt_packet_ciphertext"
```

- [ ] **Step 4: Write the cross-validation tests**

In `Tests/ReTiCATests/Vectors/LinkCrossValidationTests.swift`, add:

```swift
@Test func swiftMsgPackEncodesRTTLikeReference() throws {
    let f = try VectorFixtures.load()
    #expect(MsgPack.encode(f.linkRtt) == Data(hexString: f.linkRttMsgpack))
}

@Test func swiftDecryptsAndDecodesReferenceRTTPacket() throws {
    let f = try VectorFixtures.load()
    let key = Data(hexString: f.linkDerivedKey)!
    let plain = Link.decrypt(Data(hexString: f.linkRttPacketCiphertext)!, sessionKey: key)
    #expect(plain == Data(hexString: f.linkRttMsgpack))     // decrypts to the reference msgpack bytes
    #expect(MsgPack.decodeDouble(plain ?? Data()) == f.linkRtt)  // and decodes back to the RTT
}
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter LinkCrossValidation`
Expected: PASS, including the two new tests plus the existing link vectors.

- [ ] **Step 6: Commit (controller must verify fixtures captured)**

```
git add Tests/ReTiCATests/Vectors/generate_fixtures.py Tests/ReTiCATests/Vectors/fixtures.json Tests/ReTiCATests/Vectors/VectorFixtures.swift Tests/ReTiCATests/Vectors/LinkCrossValidationTests.swift
git commit -m "test: cross-validate link RTT msgpack + LRRTT decrypt vs Python-RNS"
```

After committing, verify: `git show HEAD:Tests/ReTiCATests/Vectors/fixtures.json` contains `link_rtt_msgpack`. If not, re-stage and amend.

---

### Task 3: LinkSession establishment reducer

**Files:**
- Modify: `Sources/ReTiCA/Link/Link.swift` (make `signallingBytes` public)
- Create: `Sources/ReTiCATransport/LinkSession.swift`
- Test: `Tests/ReTiCATransportTests/LinkSessionTests.swift`

**Interfaces:**
- Consumes: `Link.linkID(requestPacket:)`, `Link.sessionKey(ephemeralPrivateX25519:peerPublicX25519:linkID:)`, `Link.buildProof(linkID:responderEphemeral:destinationIdentity:)`, `Link.validateProof(proofData:linkID:destinationIdentity:) -> Data?`, `Link.encrypt(_:sessionKey:)`, `Link.decrypt(_:sessionKey:)`, `Link.signallingBytes` (now public); `Identity` (`.publicKey` 64B, `.privateKey` 64B optional); `Packet` (memberwise init, `init?(raw:)`, `.packed()`, `.packetType`, `.context`, `.destinationHash`, `.payload`); `MsgPack.encode`/`decodeDouble`; `InterfaceID`.
- Produces:
  - `LinkSession.State(initiatorTo:destinationHash:interfaceID:ephemeral:)` and `LinkSession.State(responderFor:destinationHash:interfaceID:ephemeral:)`
  - Actions `.establish`, `.acceptRequest(Data)`, `.received(Data)`, `.delegate(.transmit(InterfaceID, Data) | .established(linkID: Data, sessionKey: Data) | .establishmentFailed)`
  - `State.status: Status` (`.pending`/`.handshake`/`.active`), `State.sessionKey: Data`, `State.linkID: Data`.

- [ ] **Step 1: Make the signalling constant public**

In `Sources/ReTiCA/Link/Link.swift`, change:

```swift
    static let signallingBytes = Data([0x20, 0x01, 0xf4])
```

to:

```swift
    public static let signallingBytes = Data([0x20, 0x01, 0xf4])
```

- [ ] **Step 2: Write the failing unit tests**

Create `Tests/ReTiCATransportTests/LinkSessionTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

private let epoch = Date(timeIntervalSince1970: 0)

// Capture the raw bytes from the next delegate(.transmit(...)) emission.
@MainActor
private func captureTransmit(_ store: TestStore<LinkSession.State, LinkSession.Action>) async -> Data {
    let captured = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }
    return captured.value!
}

@Test @MainActor func initiatorEstablishEmitsLinkRequestAndGoesPending() async {
    let dest = Identity()
    let destHash = Data(repeating: 0x55, count: 16)
    let store = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: dest.publicKey)!,
                                        destinationHash: destHash, interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch) }
    store.exhaustivity = .off

    await store.send(.establish)
    let raw = await captureTransmit(store)
    let packet = Packet(raw: raw)!
    #expect(packet.packetType == .linkRequest)
    #expect(packet.destinationHash == destHash)
    #expect(packet.payload.count == 67)                          // ephemeral pub (64) + signalling (3)
    #expect(store.state.status == .pending)
    #expect(store.state.linkID == Link.linkID(requestPacket: packet))
}

@Test @MainActor func responderAcceptRequestEmitsProofAndGoesHandshake() async {
    let owner = Identity()
    let initEph = Identity()
    let destHash = Data(repeating: 0x66, count: 16)
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: destHash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    let requestRaw = try! request.packed()

    let store = TestStore(
        initialState: LinkSession.State(responderFor: owner, destinationHash: destHash,
                                        interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch) }
    store.exhaustivity = .off

    await store.send(.acceptRequest(requestRaw))
    let raw = await captureTransmit(store)
    let packet = Packet(raw: raw)!
    #expect(packet.packetType == .proof)
    #expect(packet.context == .linkRequestProof)
    #expect(packet.destinationHash == Link.linkID(requestPacket: request))
    #expect(store.state.status == .handshake)
    #expect(store.state.sessionKey.count == 64)
}

@Test @MainActor func initiatorRejectsTamperedProof() async {
    let dest = Identity()
    let store = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: dest.publicKey)!,
                                        destinationHash: Data(repeating: 0x55, count: 16),
                                        interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch) }
    store.exhaustivity = .off

    await store.send(.establish)
    _ = await captureTransmit(store)
    let linkID = store.state.linkID
    // A structurally valid but wrongly-signed proof (signed by a different identity).
    var proof = Link.buildProof(linkID: linkID, responderEphemeral: Identity(),
                                destinationIdentity: Identity())
    let proofPacket = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                             destinationType: .link, context: .linkRequestProof, contextFlag: false,
                             hops: 0, destinationHash: linkID, transportId: nil, payload: proof)
    await store.send(.received(try! proofPacket.packed()))
    await store.receive(.delegate(.establishmentFailed))
    #expect(store.state.status == .pending)                      // no transition on failure
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --filter LinkSession`
Expected: FAIL — `cannot find 'LinkSession' in scope`.

- [ ] **Step 4: Implement the reducer**

Create `Sources/ReTiCATransport/LinkSession.swift`:

```swift
import Foundation
import ComposableArchitecture
import ReTiCA

/// The Reticulum Link establishment handshake as a TCA feature (one instance per link).
/// Drives the initiator and responder roles through PENDING→HANDSHAKE→ACTIVE via the
/// three-packet handshake (LINKREQUEST → LRPROOF → LRRTT). Interface-agnostic: raw packet
/// bytes arrive via `received`/`acceptRequest`; outbound bytes leave via `delegate(.transmit)`.
/// Establishment only — no data flow, close, or timers.
@Reducer
public struct LinkSession {
    public enum Role: Equatable, Sendable { case initiator, responder }
    public enum Status: Equatable, Sendable { case pending, handshake, active }

    @ObservableState
    public struct State: Equatable {
        public var role: Role
        public var status: Status
        public var interfaceID: InterfaceID
        public var linkID: Data
        public var ephemeral: Identity
        public var destinationHash: Data
        public var destinationIdentity: Identity?   // initiator: peer identity that signs the proof
        public var owningIdentity: Identity?         // responder: local identity owning the destination
        public var peerX25519Pub: Data?
        public var sessionKey: Data
        public var requestedAt: Double?
        public var rtt: Double?

        /// Initiator: link to a known destination identity.
        public init(initiatorTo destinationIdentity: Identity, destinationHash: Data,
                    interfaceID: InterfaceID, ephemeral: Identity = Identity()) {
            self.role = .initiator
            self.status = .pending
            self.interfaceID = interfaceID
            self.linkID = Data()
            self.ephemeral = ephemeral
            self.destinationHash = destinationHash
            self.destinationIdentity = destinationIdentity
            self.owningIdentity = nil
            self.peerX25519Pub = nil
            self.sessionKey = Data()
            self.requestedAt = nil
            self.rtt = nil
        }

        /// Responder: accept links for a destination owned by `owningIdentity`.
        public init(responderFor owningIdentity: Identity, destinationHash: Data,
                    interfaceID: InterfaceID, ephemeral: Identity = Identity()) {
            self.role = .responder
            self.status = .pending
            self.interfaceID = interfaceID
            self.linkID = Data()
            self.ephemeral = ephemeral
            self.destinationHash = destinationHash
            self.destinationIdentity = nil
            self.owningIdentity = owningIdentity
            self.peerX25519Pub = nil
            self.sessionKey = Data()
            self.requestedAt = nil
            self.rtt = nil
        }
    }

    public enum Action: Equatable {
        case establish
        case acceptRequest(Data)
        case received(Data)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case transmit(InterfaceID, Data)
            case established(linkID: Data, sessionKey: Data)
            case establishmentFailed
        }
    }

    @Dependency(\.date) var date

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .establish:
                guard state.role == .initiator, state.status == .pending, state.linkID.isEmpty
                else { return .none }
                let payload = state.ephemeral.publicKey + Link.signallingBytes
                let packet = Packet(headerType: .header1, packetType: .linkRequest,
                                    transportType: .broadcast, destinationType: .single,
                                    context: .none, contextFlag: false, hops: 0,
                                    destinationHash: state.destinationHash, transportId: nil,
                                    payload: payload)
                state.linkID = Link.linkID(requestPacket: packet)
                state.requestedAt = date.now.timeIntervalSince1970
                guard let raw = try? packet.packed() else { return .none }
                let id = state.interfaceID
                return .send(.delegate(.transmit(id, raw)))

            case let .acceptRequest(data):
                guard state.role == .responder, state.status == .pending,
                      let packet = Packet(raw: data), packet.packetType == .linkRequest,
                      packet.payload.count >= 64, let owner = state.owningIdentity
                else { return .none }
                let linkID = Link.linkID(requestPacket: packet)
                let peerPub = Data(packet.payload.prefix(32))
                let ourPriv = Data((state.ephemeral.privateKey ?? Data()).prefix(32))
                let key = Link.sessionKey(ephemeralPrivateX25519: ourPriv,
                                          peerPublicX25519: peerPub, linkID: linkID)
                guard !key.isEmpty else { return .send(.delegate(.establishmentFailed)) }
                state.linkID = linkID
                state.peerX25519Pub = peerPub
                state.sessionKey = key
                state.status = .handshake
                let proof = Link.buildProof(linkID: linkID, responderEphemeral: state.ephemeral,
                                            destinationIdentity: owner)
                let packetOut = Packet(headerType: .header1, packetType: .proof,
                                       transportType: .broadcast, destinationType: .link,
                                       context: .linkRequestProof, contextFlag: false, hops: 0,
                                       destinationHash: linkID, transportId: nil, payload: proof)
                guard let raw = try? packetOut.packed() else { return .none }
                let id = state.interfaceID
                return .send(.delegate(.transmit(id, raw)))

            case let .received(data):
                guard let packet = Packet(raw: data), packet.destinationHash == state.linkID
                else { return .none }
                switch (state.role, state.status, packet.packetType, packet.context) {
                case (.initiator, .pending, .proof, .linkRequestProof):
                    guard let destID = state.destinationIdentity,
                          let peerPub = Link.validateProof(proofData: packet.payload,
                                                           linkID: state.linkID,
                                                           destinationIdentity: destID)
                    else { return .send(.delegate(.establishmentFailed)) }
                    let ourPriv = Data((state.ephemeral.privateKey ?? Data()).prefix(32))
                    let key = Link.sessionKey(ephemeralPrivateX25519: ourPriv,
                                              peerPublicX25519: peerPub, linkID: state.linkID)
                    guard !key.isEmpty else { return .send(.delegate(.establishmentFailed)) }
                    state.peerX25519Pub = peerPub
                    state.sessionKey = key
                    state.status = .active
                    let now = date.now.timeIntervalSince1970
                    let rtt = now - (state.requestedAt ?? now)
                    state.rtt = rtt
                    let cipher = Link.encrypt(MsgPack.encode(rtt), sessionKey: key)
                    let rttPacket = Packet(headerType: .header1, packetType: .data,
                                           transportType: .broadcast, destinationType: .link,
                                           context: .linkRequestRTT, contextFlag: false, hops: 0,
                                           destinationHash: state.linkID, transportId: nil,
                                           payload: cipher)
                    let id = state.interfaceID
                    let established = Action.delegate(.established(linkID: state.linkID,
                                                                  sessionKey: key))
                    guard let raw = try? rttPacket.packed() else { return .send(established) }
                    return .merge(.send(.delegate(.transmit(id, raw))), .send(established))

                case (.responder, .handshake, .data, .linkRequestRTT):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          let rtt = MsgPack.decodeDouble(plain)
                    else { return .send(.delegate(.establishmentFailed)) }
                    state.rtt = rtt
                    state.status = .active
                    return .send(.delegate(.established(linkID: state.linkID,
                                                        sessionKey: state.sessionKey)))

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

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter LinkSession`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCA/Link/Link.swift Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionTests.swift
git commit -m "feat: LinkSession establishment reducer (initiator + responder)"
```

---

### Task 4: End-to-end handshake, full-suite gate, mutation sweep, README

**Files:**
- Modify: `Tests/ReTiCATransportTests/LinkSessionTests.swift` (add the two-store end-to-end test)
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: no new production API.

- [ ] **Step 1: Write the end-to-end handshake test**

Append to `Tests/ReTiCATransportTests/LinkSessionTests.swift`:

```swift
@Test @MainActor func initiatorAndResponderReachActiveWithEqualSessionKey() async {
    let owner = Identity()                                  // responder owns this destination identity
    let destHash = Data(repeating: 0x77, count: 16)

    let initiator = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: owner.publicKey)!,
                                        destinationHash: destHash, interfaceID: InterfaceID("a"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch) }
    initiator.exhaustivity = .off

    let responder = TestStore(
        initialState: LinkSession.State(responderFor: owner, destinationHash: destHash,
                                        interfaceID: InterfaceID("b"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch) }
    responder.exhaustivity = .off

    // 1. Initiator → LINKREQUEST
    await initiator.send(.establish)
    let linkRequest = await captureTransmit(initiator)

    // 2. Responder accepts request → LRPROOF
    await responder.send(.acceptRequest(linkRequest))
    let proof = await captureTransmit(responder)
    #expect(responder.state.status == .handshake)

    // 3. Initiator validates proof → ACTIVE, emits LRRTT + established
    await initiator.send(.received(proof))
    let rttPacket = await captureTransmit(initiator)
    await initiator.receive { if case .delegate(.established) = $0 { return true }; return false }
    #expect(initiator.state.status == .active)

    // 4. Responder receives LRRTT → ACTIVE, established
    await responder.send(.received(rttPacket))
    await responder.receive { if case .delegate(.established) = $0 { return true }; return false }
    #expect(responder.state.status == .active)

    // Both sides derived the same non-empty session key.
    #expect(initiator.state.sessionKey.count == 64)
    #expect(initiator.state.sessionKey == responder.state.sessionKey)
}
```

- [ ] **Step 2: Run the end-to-end test**

Run: `swift test --filter LinkSession`
Expected: PASS (4 tests).

- [ ] **Step 3: Run the full suite**

Run: `swift test`
Expected: PASS — all prior tests plus the new MsgPack, cross-validation, and LinkSession tests.

- [ ] **Step 4: Mutation-testing sweep**

Follow the project's three-step discipline on the tests added in Tasks 1–4. Apply each mutation, run the relevant `--filter`, confirm the intended test fails, then revert and confirm green. Suggested mutations (each reverted before the next):
- `MsgPack.encode`: change `float64Tag` to `0xCA` → `msgPackEncodesFloat64WithTag` and `swiftMsgPackEncodesRTTLikeReference` fail.
- `MsgPack.decodeDouble`: drop the `bytes.count == 9` guard (e.g. `bytes.count >= 9`) → `msgPackDecodeRejectsMalformed` fails.
- `LinkSession.establish`: append `Data()` instead of `Link.signallingBytes` → `initiatorEstablishEmitsLinkRequestAndGoesPending` (payload.count == 67) fails.
- `LinkSession` initiator proof branch: return `.establishmentFailed` unconditionally (skip the guard success path) → the end-to-end test fails.
- `LinkSession` responder RTT branch: skip `state.status = .active` → end-to-end responder `.active` assertion fails.
- `LinkSession` initiator proof branch: replace `peerPub` fed to `sessionKey` with `state.ephemeral.publicKey.prefix(32)` → end-to-end equal-session-key assertion fails.

Confirm every mutation is caught; if any test still passes, strengthen it, then re-verify. Finally revert all mutations and run `swift test` → all pass.

- [ ] **Step 5: Update the README**

In `README.md`, under the Link section (after the "Link handshake primitives" subsection), add a new subsection:

```markdown
### Link establishment (`LinkSession`)

`LinkSession` (in `ReTiCATransport`) drives the Link establishment handshake as a TCA
reducer — one instance per link, for either role:

- **Initiator:** `establish` builds and emits the LINKREQUEST, then validates the returned
  LRPROOF, derives the session key, emits the LRRTT packet, and reaches `active`.
- **Responder:** `acceptRequest` parses an inbound LINKREQUEST, derives the session key,
  emits the LRPROOF, then validates the LRRTT and reaches `active`.

Both sides progress `pending → handshake → active` and finish holding an equal derived
session key (`delegate(.established(linkID:sessionKey:))`). The reducer is interface-agnostic
(raw packet bytes in, `delegate(.transmit)` out). The LRRTT payload is `msgpack(rtt)`
encrypted under the session key; a minimal double-only `MsgPack` codec lives in the pure core.

This slice is **establishment only**: application data flow, link close/teardown,
keepalive/watchdog/timeouts, identify, requests, and resources are future slices, as is
wiring `LinkSession` into `Transport`/`Endpoint`. The msgpack encoding and the encrypted
LRRTT packet are cross-validated against Python-RNS 1.3.8.
```

Also, if the "Not Yet Implemented" section lists "Link establishment" as pending, narrow it to note that the establishment handshake is now implemented and the stateful data/keepalive/close layers remain future work.

- [ ] **Step 6: Commit**

```
git add Tests/ReTiCATransportTests/LinkSessionTests.swift README.md
git commit -m "test: end-to-end link establishment handshake; docs: LinkSession"
```

---

## Self-Review

**Spec coverage:**
- Establish-only initiator+responder state machine → Task 3. ✓
- 3-packet handshake (LINKREQUEST/LRPROOF/LRRTT) with correct framing → Task 3 (verified against wire table). ✓
- Equal session key on both sides → Task 4 end-to-end test. ✓
- msgpack double codec in pure core → Task 1. ✓
- Cross-validation (msgpack byte-exact + LRRTT decrypt, driving genuine RNS) → Task 2. ✓
- Reuse 5-links-a link_id/derived_key/proof vectors → Task 2 (they remain in fixtures.json). ✓
- Error handling (establishmentFailed on bad proof / undecryptable RTT; ignore mismatched packets) → Task 3 reducer + Task 3 tampered-proof test. ✓
- No Transport/Endpoint changes, no timers, no data/close → confirmed; only new files + `Link.signallingBytes` visibility + fixture/README edits. ✓
- Mutation discipline → Task 4 Step 4. ✓

**Placeholder scan:** No TBD/TODO; every code step contains complete code. `VectorFixtures` was confirmed to use an explicit exhaustive `CodingKeys` enum, so Task 2's fixture-decoding edit is exact.

**Type consistency:** `LinkSession.State` initializers, `Action`/`Delegate` cases, `Status` values, and the `Link`/`MsgPack`/`Packet` signatures are used identically across Tasks 3–4. Fixture field names (`link_rtt`, `link_rtt_msgpack`, `link_rtt_packet_ciphertext`) and their Swift properties (`linkRtt`, `linkRttMsgpack`, `linkRttPacketCiphertext`) match between Task 2 producer and consumer. `Link.signallingBytes` made public in Task 3 Step 1 before first use in Task 3 Step 4.
