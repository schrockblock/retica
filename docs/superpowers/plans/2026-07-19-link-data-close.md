# Link Data Flow + Explicit Close Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the `LinkSession` reducer so an established link can carry encrypted application data in both directions and be explicitly closed (LINKCLOSE), wire-compatible with reference RNS 1.3.8.

**Architecture:** Extend the existing `LinkSession` `@Reducer` (`Sources/ReTiCATransport/LinkSession.swift`) — no new source files. Add a `.closed` status and `CloseReason`, `send(Data)`/`close` actions, `dataReceived(Data)`/`closed(CloseReason)` delegates, and the corresponding reducer cases. Reuse the existing `Link.encrypt`/`Link.decrypt` (which wrap `Token(sessionKey)`).

**Tech Stack:** Swift 6, The Composable Architecture (~1.26), Swift Testing, CryptoKit. Cross-validation against Python-RNS 1.3.8.

## Global Constraints

- Full wire compatibility with reference RNS 1.3.8; cross-validation drives GENUINE reference code (never a reimplementation).
- The `ReTiCA` core stays dependency-free; TCA is confined to `ReTiCATransport`.
- Swift 6 strict concurrency; `LinkSession.State` remains `Equatable`; `Identity` is already `Equatable, Sendable`.
- Platform floor iOS 16 / macOS 13 / tvOS 16 / watchOS 9 / macCatalyst 16.
- Scope: data flow + explicit close ONLY. NO keepalive/watchdog/STALE/timeouts, NO identify/requests/resources/channels, NO Transport/Endpoint wiring, NO MTU negotiation.
- Wire framing (constants already in `Sources/ReTiCA/Packet/PacketConstants.swift`): app data = `packetType .data`, `context .none`; LINKCLOSE = `packetType .data`, `context .linkClose` (0xFC); both `destinationType .link`, destHash = link_id, payload encrypted under the session key. `Link.encrypt`/`Link.decrypt` are the cipher.
- Reference RNS lives in the conda env `rns`; run the fixture generator with `/Users/ell/opt/anaconda3/envs/rns/bin/python`.
- User global rules: temp files under `/tmp/ReTiCA/`; NO compound shell commands (no `|`/`&&`/`;`/command-substitution feeding another command); one command per invocation; write scripts to a file; mutation-testing three-step verification for every new/changed test.

---

## File Structure

- `Sources/ReTiCATransport/LinkSession.swift` (modify) — add `.closed` status, `CloseReason`, `send`/`close` actions, `dataReceived`/`closed` delegates, reducer cases; tighten `acceptRequest` length check.
- `Tests/ReTiCATransportTests/LinkSessionTests.swift` (modify) — unit tests for send/receive-data/close + the length-fix test; the end-to-end data+close test.
- `Tests/ReTiCATests/Vectors/generate_fixtures.py` (modify) — add `link_close_ciphertext`.
- `Tests/ReTiCATests/Vectors/fixtures.json` (regenerate).
- `Tests/ReTiCATests/Vectors/VectorFixtures.swift` (modify) — decode `link_close_ciphertext`.
- `Tests/ReTiCATests/Vectors/LinkCrossValidationTests.swift` (modify) — LINKCLOSE decrypt vector.
- `README.md` (modify) — update the LinkSession subsection.

---

### Task 1: Data send/receive + close in LinkSession

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift`
- Test: `Tests/ReTiCATransportTests/LinkSessionTests.swift`

**Interfaces:**
- Consumes: `Link.encrypt(_:sessionKey:) -> Data`, `Link.decrypt(_:sessionKey:) -> Data?`, `Packet` memberwise init + `init?(raw:)` + `.packed()`, `PacketContext.none/.linkClose`, `PacketType.data`, `DestinationType.link`, `InterfaceID`.
- Produces:
  - `LinkSession.Status` gains `.closed`.
  - `LinkSession.CloseReason` (`.initiatorClosed`/`.destinationClosed`).
  - Actions `.send(Data)`, `.close`.
  - Delegates `.dataReceived(Data)`, `.closed(CloseReason)`.

- [ ] **Step 1: Write the failing unit tests**

Append to `Tests/ReTiCATransportTests/LinkSessionTests.swift` (the file already defines `captureTransmit` and `epoch`; reuse them). Add these helpers and tests:

```swift
private let sampleKey = Data(repeating: 0x01, count: 64)   // valid AES-256 Token key
private let sampleLinkID = Data(repeating: 0xAB, count: 16)

private func activeState(role: LinkSession.Role) -> LinkSession.State {
    var s: LinkSession.State
    switch role {
    case .initiator:
        s = LinkSession.State(initiatorTo: Identity(), destinationHash: Data(repeating: 0x01, count: 16),
                              interfaceID: InterfaceID("i"))
    case .responder:
        s = LinkSession.State(responderFor: Identity(), destinationHash: Data(repeating: 0x01, count: 16),
                              interfaceID: InterfaceID("i"))
    }
    s.status = .active
    s.sessionKey = sampleKey
    s.linkID = sampleLinkID
    return s
}

private func linkPacket(context: PacketContext, payload: Data) -> Data {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: context, contextFlag: false, hops: 0,
                   destinationHash: sampleLinkID, transportId: nil, payload: payload)
    return try! p.packed()
}

@Test @MainActor func activeLinkSendEmitsEncryptedDataPacket() async {
    let store = TestStore(initialState: activeState(role: .initiator)) { LinkSession() }
        withDependencies: { $0.date = .constant(epoch) }
    store.exhaustivity = .off
    let plaintext = Data("hello link".utf8)
    await store.send(.send(plaintext))
    let raw = await captureTransmit(store)
    let packet = Packet(raw: raw)!
    #expect(packet.packetType == .data)
    #expect(packet.context == .none)
    #expect(packet.destinationHash == sampleLinkID)
    #expect(Link.decrypt(packet.payload, sessionKey: sampleKey) == plaintext)
}

@Test @MainActor func activeLinkReceivesDataAndBubblesDataReceived() async {
    let store = TestStore(initialState: activeState(role: .responder)) { LinkSession() }
        withDependencies: { $0.date = .constant(epoch) }
    store.exhaustivity = .off
    let plaintext = Data("inbound".utf8)
    let cipher = Link.encrypt(plaintext, sessionKey: sampleKey)
    let captured = LockIsolated<Data?>(nil)
    await store.send(.received(linkPacket(context: .none, payload: cipher)))
    await store.receive { action in
        if case let .delegate(.dataReceived(p)) = action { captured.setValue(p); return true }
        return false
    }
    #expect(captured.value == plaintext)
    #expect(store.state.status == .active)
}

@Test @MainActor func corruptInboundDataIsIgnoredAndLinkStaysActive() async {
    let store = TestStore(initialState: activeState(role: .responder)) { LinkSession() }
        withDependencies: { $0.date = .constant(epoch) }
    store.exhaustivity = .off
    await store.send(.received(linkPacket(context: .none, payload: Data(repeating: 0xFF, count: 80))))
    #expect(store.state.status == .active)   // no teardown, no dataReceived
}

@Test @MainActor func initiatorCloseEmitsLinkCloseAndGoesClosed() async {
    let store = TestStore(initialState: activeState(role: .initiator)) { LinkSession() }
        withDependencies: { $0.date = .constant(epoch) }
    store.exhaustivity = .off
    await store.send(.close)
    #expect(store.state.status == .closed)
    let raw = await captureTransmit(store)
    let packet = Packet(raw: raw)!
    #expect(packet.context == .linkClose)
    #expect(packet.destinationHash == sampleLinkID)
    #expect(Link.decrypt(packet.payload, sessionKey: sampleKey) == sampleLinkID)  // payload = encrypt(link_id)
    await store.receive(.delegate(.closed(.initiatorClosed)))
}

@Test @MainActor func responderReceivesLinkCloseAndGoesClosed() async {
    let store = TestStore(initialState: activeState(role: .responder)) { LinkSession() }
        withDependencies: { $0.date = .constant(epoch) }
    store.exhaustivity = .off
    let closeCipher = Link.encrypt(sampleLinkID, sessionKey: sampleKey)
    await store.send(.received(linkPacket(context: .linkClose, payload: closeCipher)))
    #expect(store.state.status == .closed)
    await store.receive(.delegate(.closed(.initiatorClosed)))  // responder observing peer close → initiatorClosed
}

@Test @MainActor func acceptRequestRejectsWrongLengthRequest() async {
    // The tightened check accepts only 64 or 67 byte payloads (RNS-exact). 65 must be rejected.
    let owner = Identity()
    let store = TestStore(
        initialState: LinkSession.State(responderFor: owner, destinationHash: Data(repeating: 0x02, count: 16),
                                        interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch) }
    store.exhaustivity = .off
    let badRequest = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                            destinationType: .single, context: .none, contextFlag: false, hops: 0,
                            destinationHash: Data(repeating: 0x02, count: 16), transportId: nil,
                            payload: Data(repeating: 0x33, count: 65))
    await store.send(.acceptRequest(try! badRequest.packed()))
    #expect(store.state.status == .pending)   // rejected, no handshake
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter LinkSession`
Expected: FAIL — the new cases (`.send`, `.close`, `.dataReceived`, `.closed`, `.closed` status) don't exist; compile errors.

- [ ] **Step 3: Extend the reducer**

In `Sources/ReTiCATransport/LinkSession.swift`, make the following changes.

(a) Update the type doc comment (lines 5-9) — replace `/// Establishment only — no data flow, close, or timers.` with:

```swift
/// After establishment the link can carry encrypted application data (DATA/NONE) and be
/// explicitly closed (LINKCLOSE). Timers/keepalive are a separate slice.
```

(b) Add `.closed` to `Status` and add `CloseReason` (replace the `Status` line):

```swift
    public enum Role: Equatable, Sendable { case initiator, responder }
    public enum Status: Equatable, Sendable { case pending, handshake, active, closed }
    public enum CloseReason: Equatable, Sendable { case initiatorClosed, destinationClosed }
```

(c) Add the new actions and delegates (replace the `Action` enum):

```swift
    public enum Action: Equatable {
        case establish
        case acceptRequest(Data)
        case received(Data)
        case send(Data)
        case close
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case transmit(InterfaceID, Data)
            case established(linkID: Data, sessionKey: Data)
            case establishmentFailed
            case dataReceived(Data)
            case closed(CloseReason)
        }
    }
```

(d) Tighten the `acceptRequest` length check — replace `packet.payload.count >= 64` with:

```swift
                      (packet.payload.count == 64 || packet.payload.count == 67),
```

(e) Add the two inbound cases to the `switch (state.role, state.status, packet.packetType, packet.context)` — insert BEFORE the `default:` line:

```swift
                case (_, .active, .data, .none):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey)
                    else { return .none }   // corrupt/foreign data is ignored, link stays active
                    return .send(.delegate(.dataReceived(plain)))

                case (_, .active, .data, .linkClose):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          plain == state.linkID
                    else { return .none }
                    state.status = .closed
                    let reason: CloseReason = state.role == .initiator ? .destinationClosed : .initiatorClosed
                    return .send(.delegate(.closed(reason)))
```

(f) Add the `.send` and `.close` action cases to the OUTER switch — insert BEFORE `case .delegate:`:

```swift
            case let .send(plaintext):
                guard state.status == .active else { return .none }
                let cipher = Link.encrypt(plaintext, sessionKey: state.sessionKey)
                let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                                    destinationType: .link, context: .none, contextFlag: false, hops: 0,
                                    destinationHash: state.linkID, transportId: nil, payload: cipher)
                guard let raw = try? packet.packed() else { return .none }
                let id = state.interfaceID
                return .send(.delegate(.transmit(id, raw)))

            case .close:
                guard state.status == .active else { return .none }
                let cipher = Link.encrypt(state.linkID, sessionKey: state.sessionKey)
                let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                                    destinationType: .link, context: .linkClose, contextFlag: false, hops: 0,
                                    destinationHash: state.linkID, transportId: nil, payload: cipher)
                state.status = .closed
                let reason: CloseReason = state.role == .initiator ? .initiatorClosed : .destinationClosed
                let closedAction = Action.delegate(.closed(reason))
                guard let raw = try? packet.packed() else { return .send(closedAction) }
                let id = state.interfaceID
                return .merge(.send(.delegate(.transmit(id, raw))), .send(closedAction))
```

(Note: `.send(...)` in a `return` position is `Effect.send`; the `.send(Data)` action case is distinguished by argument type and the `case`/`return` positions — this compiles cleanly, matching how `Transport` names a `.send` action alongside `Effect.send`.)

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter LinkSession`
Expected: PASS — the 3 pre-existing establishment tests plus the 6 new tests (send, receive-data, corrupt-ignored, initiator-close, responder-receives-close, wrong-length-reject).

- [ ] **Step 5: Mutation sweep**

Apply each mutation, run `swift test --filter LinkSession`, confirm the named test fails, then revert (one at a time or small batches; final state must be reverted + green):
- In `.send`, change `context: .none` to `context: .linkClose` → `activeLinkSendEmitsEncryptedDataPacket` fails (context assertion).
- In the `(_, .active, .data, .linkClose)` case, drop the `plain == state.linkID` guard (accept any decrypt) — still fine for the valid test, so instead change `state.status = .closed` to leave status → `responderReceivesLinkCloseAndGoesClosed` fails.
- In `.close`, change `reason` for initiator to `.destinationClosed` → `initiatorCloseEmitsLinkCloseAndGoesClosed` fails (`.initiatorClosed` expected).
- In the `(_, .active, .data, .none)` case, return `.none` instead of `.dataReceived` → `activeLinkReceivesDataAndBubblesDataReceived` fails.
- Revert the `acceptRequest` fix (`== 64 || == 67` back to `>= 64`) → `acceptRequestRejectsWrongLengthRequest` fails.
Finally revert all and run `swift test --filter LinkSession` → green.

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionTests.swift
git commit -m "feat: link data flow + explicit close in LinkSession"
```

---

### Task 2: LINKCLOSE cross-validation vs Python-RNS

**Files:**
- Modify: `Tests/ReTiCATests/Vectors/generate_fixtures.py`
- Regenerate: `Tests/ReTiCATests/Vectors/fixtures.json`
- Modify: `Tests/ReTiCATests/Vectors/VectorFixtures.swift`
- Modify: `Tests/ReTiCATests/Vectors/LinkCrossValidationTests.swift`

**Interfaces:**
- Consumes: `Link.decrypt`, existing fixture fields `link_derived_key`, `link_id`.
- Produces: fixture field `link_close_ciphertext` (hex); `VectorFixtures.linkCloseCiphertext: String`.

**Gotcha (bit this workflow 3× historically):** an external linter can revert `generate_fixtures.py`/`fixtures.json`. After regenerating AND after committing, verify the committed blob via `git show HEAD:Tests/ReTiCATests/Vectors/fixtures.json` contains `link_close_ciphertext`; if missing, re-stage and `git commit --amend --no-edit`, then re-verify.

- [ ] **Step 1: Add the LINKCLOSE vector to the generator**

In `Tests/ReTiCATests/Vectors/generate_fixtures.py`, immediately AFTER the RTT block (the line `link_rtt_packet_ciphertext = LinkToken(link_derived_key).encrypt(link_rtt_msgpack)`), add:

```python
# --- Link close packet (LINKCLOSE) vector: encrypt(link_id) under the session key ---
link_close_ciphertext = LinkToken(link_derived_key).encrypt(link_id)
```

Then in the `json.dumps({...})` dict, after the `"link_rtt_packet_ciphertext": link_rtt_packet_ciphertext.hex(),` entry, add:

```python
    "link_close_ciphertext": link_close_ciphertext.hex(),
```

- [ ] **Step 2: Regenerate the fixtures**

Run: `/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/generate_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/fixtures.json`

Verify: `grep -n "link_close_ciphertext" /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/fixtures.json`
Expected: one line present.

- [ ] **Step 3: Decode the field in VectorFixtures**

In `Tests/ReTiCATests/Vectors/VectorFixtures.swift`, add a property alongside the other `link*` properties:

```swift
    let linkCloseCiphertext: String
```

And add to the explicit exhaustive `enum CodingKeys`:

```swift
        case linkCloseCiphertext = "link_close_ciphertext"
```

- [ ] **Step 4: Write the cross-validation test**

In `Tests/ReTiCATests/Vectors/LinkCrossValidationTests.swift`, add:

```swift
@Test func swiftDecryptsReferenceLinkClosePacket() throws {
    let f = try VectorFixtures.load()
    let key = Data(hexString: f.linkDerivedKey)!
    // RNS LINKCLOSE payload is encrypt(link_id); decrypting must recover the link_id exactly.
    #expect(Link.decrypt(Data(hexString: f.linkCloseCiphertext)!, sessionKey: key)
            == Data(hexString: f.linkID))
}
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter LinkCrossValidation`
Expected: PASS, including the new LINKCLOSE vector.

- [ ] **Step 6: Commit (verify fixtures captured)**

```
git add Tests/ReTiCATests/Vectors/generate_fixtures.py Tests/ReTiCATests/Vectors/fixtures.json Tests/ReTiCATests/Vectors/VectorFixtures.swift Tests/ReTiCATests/Vectors/LinkCrossValidationTests.swift
git commit -m "test: cross-validate link close packet (encrypt(link_id)) vs Python-RNS"
```

After committing, run `git show HEAD:Tests/ReTiCATests/Vectors/fixtures.json` and confirm `link_close_ciphertext` is present; if not, re-stage and `git commit --amend --no-edit`, then re-verify.

---

### Task 3: End-to-end data+close, full-suite gate, README

**Files:**
- Modify: `Tests/ReTiCATransportTests/LinkSessionTests.swift` (end-to-end data+close test)
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–2 and the existing establishment flow.
- Produces: no new production API.

- [ ] **Step 1: Write the end-to-end data+close test**

Append to `Tests/ReTiCATransportTests/LinkSessionTests.swift`:

```swift
@Test @MainActor func establishedLinkExchangesDataThenCloses() async {
    let owner = Identity()
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

    // Establish (LINKREQUEST → LRPROOF → LRRTT).
    await initiator.send(.establish)
    let linkRequest = await captureTransmit(initiator)
    await responder.send(.acceptRequest(linkRequest))
    let proof = await captureTransmit(responder)
    await initiator.send(.received(proof))
    let rttPacket = await captureTransmit(initiator)
    await initiator.receive { if case .delegate(.established) = $0 { return true }; return false }
    await responder.send(.received(rttPacket))
    await responder.receive { if case .delegate(.established) = $0 { return true }; return false }
    #expect(initiator.state.status == .active)
    #expect(responder.state.status == .active)

    // Initiator → responder application data.
    let up = Data("ping".utf8)
    await initiator.send(.send(up))
    let dataToResp = await captureTransmit(initiator)
    let gotUp = LockIsolated<Data?>(nil)
    await responder.send(.received(dataToResp))
    await responder.receive { action in
        if case let .delegate(.dataReceived(p)) = action { gotUp.setValue(p); return true }
        return false
    }
    #expect(gotUp.value == up)

    // Responder → initiator application data.
    let down = Data("pong".utf8)
    await responder.send(.send(down))
    let dataToInit = await captureTransmit(responder)
    let gotDown = LockIsolated<Data?>(nil)
    await initiator.send(.received(dataToInit))
    await initiator.receive { action in
        if case let .delegate(.dataReceived(p)) = action { gotDown.setValue(p); return true }
        return false
    }
    #expect(gotDown.value == down)

    // Initiator closes; responder observes the close.
    await initiator.send(.close)
    let closePacket = await captureTransmit(initiator)
    await initiator.receive(.delegate(.closed(.initiatorClosed)))
    #expect(initiator.state.status == .closed)
    await responder.send(.received(closePacket))
    await responder.receive(.delegate(.closed(.initiatorClosed)))
    #expect(responder.state.status == .closed)
}
```

- [ ] **Step 2: Run the end-to-end test**

Run: `swift test --filter LinkSession`
Expected: PASS (all establishment + data/close unit tests + this end-to-end test).

- [ ] **Step 3: Run the full suite**

Run: `swift test`
Expected: PASS — all prior tests plus the new data/close and cross-validation tests.

- [ ] **Step 4: Mutation sweep on the end-to-end test**

Confirm the end-to-end test genuinely exercises interop (revert each before the next):
- In `.send` (production), encrypt with a fixed wrong key (e.g. `Link.encrypt(plaintext, sessionKey: Data(repeating: 0, count: 64))`) → the peer's `dataReceived` value mismatches → `establishedLinkExchangesDataThenCloses` fails (or the peer ignores it, leaving the `receive` unmatched → the test's `receive` times out and fails). Revert.
- In the `(_, .active, .data, .linkClose)` case, skip `state.status = .closed` → the responder's `#expect(responder.state.status == .closed)` fails. Revert.
Run `swift test` after reverting → all green.

- [ ] **Step 5: Update the README**

In `README.md`, in the "Link establishment (`LinkSession`)" subsection, replace the paragraph that begins "This slice is **establishment only**:" with:

```markdown
An established link can then carry encrypted application data in both directions (`send(_:)` →
a DATA/NONE packet; inbound data surfaces via `delegate(.dataReceived(_:))`) and be explicitly
closed (`close` → a LINKCLOSE packet carrying `encrypt(link_id)`; either side reaching
`.closed` emits `delegate(.closed(_:))` with the RNS-faithful reason). Data payloads and the
close packet are encrypted under the session key; the close packet and its `encrypt(link_id)`
format are cross-validated against Python-RNS 1.3.8.

Still deferred to later slices: the time-driven layer (keepalive, watchdog, STALE detection,
establishment/inactivity timeouts), plus identify, requests, resources, and wiring
`LinkSession` into `Transport`/`Endpoint`.
```

If the README's title/intro for the subsection still says "establishment" exclusively, adjust the one-line description so it reads as "establishment, data flow, and close" while keeping the deferred-items note accurate.

- [ ] **Step 6: Commit**

```
git add Tests/ReTiCATransportTests/LinkSessionTests.swift README.md
git commit -m "test: end-to-end link data + close; docs: LinkSession data/close"
```

---

## Self-Review

**Spec coverage:**
- `send(Data)` + DATA/NONE framing + encryption → Task 1 (case (f), unit test). ✓
- Inbound DATA/NONE → `dataReceived`; decrypt-fail ignored → Task 1 (case (e), two unit tests). ✓
- `close` + LINKCLOSE (`encrypt(link_id)`) + `.closed` + reason → Task 1 (case (f), unit test). ✓
- Inbound LINKCLOSE → `.closed` + reason mapping → Task 1 (case (e), unit test). ✓
- CloseReason mirrors RNS teardown_reason (both directions) → Task 1 reason expressions + tests assert `.initiatorClosed` on both local-initiator-close and responder-observes-close. ✓
- `.closed` terminal (further packets ignored) → falls to `default: .none` (status no longer `.active`). ✓
- acceptRequest exact-length fix → Task 1 (case (d) + reject test). ✓
- LINKCLOSE cross-validation (genuine RNS) → Task 2. ✓
- End-to-end data both directions + close propagation → Task 3. ✓
- Mutation discipline → Task 1 Step 5, Task 3 Step 4. ✓
- Scope: no timers/keepalive/identify/requests/resources/Transport-wiring; only LinkSession + fixtures + README touched. ✓

**Placeholder scan:** No TBD/TODO; every code step has complete code. The README Step-5 conditional ("if the subsection title still says establishment") is a concrete, resolvable instruction against real text, not a placeholder.

**Type consistency:** `Status.closed`, `CloseReason.initiatorClosed/.destinationClosed`, actions `.send(Data)`/`.close`, delegates `.dataReceived(Data)`/`.closed(CloseReason)` are used identically across Tasks 1 and 3. Reason mapping matches the spec table: local initiator-close → `.initiatorClosed`; responder observing a peer close → `.initiatorClosed`. Fixture field `link_close_ciphertext` ↔ `VectorFixtures.linkCloseCiphertext` match between Task 2 producer and consumer.
