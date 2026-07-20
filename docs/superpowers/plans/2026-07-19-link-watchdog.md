# Link Watchdog (Timers + Keepalive) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the time-driven robustness layer to `LinkSession` — establishment timeout, keepalive, and inactivity teardown — so a link times out hung handshakes, stays alive under keepalive, and tears down when the peer goes silent.

**Architecture:** Extend the `LinkSession` `@Reducer` (`Sources/ReTiCATransport/LinkSession.swift`) with `@Dependency(\.continuousClock)` and three cancellable "sleep-then-fire" timer effects (establishment, inactivity, keepalive), keyed by a private `CancelID`. Modeled on the existing `TCPClientInterface` reconnect pattern. Tests use `TestClock`.

**Tech Stack:** Swift 6, The Composable Architecture (~1.26, `continuousClock`/`TestClock`), Swift Testing.

## Global Constraints

- Full wire compatibility with reference RNS 1.3.8 for the keepalive packet: `packetType .data`, `context .keepalive` (0xFA), `destinationType .link`, destHash = link_id, payload = a single **unencrypted** byte `0xFF` (initiator) or `0xFE` (responder reply).
- Timer *durations* are local policy (not wire-visible): `establishmentTimeout` default 15s, `keepaliveInterval` default 30s, `staleTime = keepaliveInterval * 2` (60s). Configurable via the State initializers.
- The `ReTiCA` core stays dependency-free; TCA (incl. `continuousClock`) confined to `ReTiCATransport`.
- Swift 6 strict concurrency; `LinkSession.State` remains `Equatable`; `Identity` is `Sendable`.
- Platform floor iOS 16 / macOS 13 / tvOS 16 / watchOS 9 / macCatalyst 16.
- Scope: establishment timeout + inactivity teardown + keepalive ONLY. NO RTT-adaptive intervals, NO distinct STALE state (collapsed into inactivity), NO phy-stats/identify/requests/resources, NO Transport/Endpoint wiring.
- Simplification (note, don't "fix"): inactivity is reset only by inbound **keepalive** packets (and close transitions), NOT by data packets. This is sound because the initiator sends keepalives unconditionally every `keepaliveInterval < staleTime`, so a healthy link is always kept fresh; data resets would be redundant. This keeps the 5-links-c data unit tests unaffected by timers.
- All timers are cancelled on any `.closed` transition. Tests must leave no in-flight effects (TestStore fails on lingering effects) — drive each timer to a terminal state or close the link.
- User global rules: temp files under `/tmp/ReTiCA/`; NO compound shell commands; one command per invocation; mutation-testing three-step verification for every new/changed test.

---

## File Structure

- `Sources/ReTiCATransport/LinkSession.swift` (modify) — clock dependency, timer helpers, `CloseReason.timedOut`, `.closed` timer fields, three deadline actions, timer wiring in establish/acceptRequest/active/close, keepalive handling.
- `Tests/ReTiCATransportTests/LinkSessionTests.swift` (modify) — inject `TestClock` into the establishment/active-driving tests and clean up their timers; add timer/keepalive unit tests and the end-to-end test.
- `README.md` (modify) — LinkSession subsection: add the watchdog behaviors.

**Reference the existing TestClock idiom** in `Tests/ReTiCAInterfacesTests/TCPClientInterfaceTests.swift`: `let clock = TestClock()`, inject `$0.continuousClock = clock`, `await clock.advance(by: .seconds(N))`, then `await store.receive(.someAction)`.

---

### Task 1: Establishment timeout + inactivity teardown (clock infrastructure)

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift`
- Test: `Tests/ReTiCATransportTests/LinkSessionTests.swift`

**Interfaces:**
- Consumes: `@Dependency(\.continuousClock)`, `Link.encrypt`, `Packet`, existing `LinkSession` establishment/data/close logic.
- Produces:
  - `CloseReason.timedOut`.
  - State fields `activatedAt: Double?`, `lastInbound: Double?`, `establishmentTimeout: TimeInterval`, `keepaliveInterval: TimeInterval`, computed `staleTime`.
  - Actions `.establishmentDeadline`, `.inactivityDeadline` (and `.keepaliveDeadline`, added now so the enum is stable for Task 2).
  - Behavior: hung `.pending`/`.handshake` → `.closed(.timedOut)`; a silent `.active` link → LINKCLOSE + `.closed(.timedOut)` after `staleTime`.

- [ ] **Step 1: Update the existing establishment/active tests to inject a TestClock and clean up timers, and write the new failing timer tests**

The existing tests that dispatch `.establish`, `.acceptRequest`, or drive a handshake to `.active` will now start timer effects and must (a) provide a `TestClock` and (b) end in a state with no in-flight effect. Apply these edits in `Tests/ReTiCATransportTests/LinkSessionTests.swift`:

Add a clock helper and a single-store "reach active" helper near the top of the file (after the existing `epoch` constant). **Prefer single-store timer tests** — craft the inbound proof/LRRTT by hand so one reducer reaches `.active` with real running timers, instead of two `TestStore`s sharing a clock (a shared `TestClock.advance` fires BOTH stores' timers and forces fragile cross-store choreography):

```swift
private func testClock() -> TestClock<Duration> { TestClock() }

// A single initiator store driven to .active by feeding a proof crafted from `owner`'s identity.
// Timers (inactivity, and — after Task 2 — keepalive) are running; the caller must close the link
// (which cancels them) to end the test cleanly.
@MainActor
private func activeInitiatorStore(owner: Identity, clock: TestClock<Duration>)
    async -> TestStore<LinkSession.State, LinkSession.Action>
{
    let store = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: owner.publicKey)!,
                                        destinationHash: Data(repeating: 0x55, count: 16),
                                        interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch); $0.continuousClock = clock }
    store.exhaustivity = .off
    await store.send(.establish)
    _ = await captureTransmit(store)                                   // LINKREQUEST
    let proof = Link.buildProof(linkID: store.state.linkID, responderEphemeral: Identity(),
                                destinationIdentity: owner)             // signed by owner → initiator accepts
    let proofPacket = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                             destinationType: .link, context: .linkRequestProof, contextFlag: false,
                             hops: 0, destinationHash: store.state.linkID, transportId: nil, payload: proof)
    await store.send(.received(try! proofPacket.packed()))
    _ = await captureTransmit(store)                                   // LRRTT
    await store.receive { if case .delegate(.established) = $0 { return true }; return false }
    return store
}

// A single responder store driven to .active by feeding a crafted LRRTT (encrypted with the
// responder's own derived session key). The responder runs only the inactivity timer (no keepalive).
@MainActor
private func activeResponderStore(clock: TestClock<Duration>)
    async -> TestStore<LinkSession.State, LinkSession.Action>
{
    let owner = Identity()
    let initEph = Identity()
    let destHash = Data(repeating: 0x66, count: 16)
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: destHash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    let store = TestStore(
        initialState: LinkSession.State(responderFor: owner, destinationHash: destHash,
                                        interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch); $0.continuousClock = clock }
    store.exhaustivity = .off
    await store.send(.acceptRequest(try! request.packed()))
    _ = await captureTransmit(store)                                   // LRPROOF
    let rttCipher = Link.encrypt(MsgPack.encode(0.0), sessionKey: store.state.sessionKey)
    let rttPacket = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                           destinationType: .link, context: .linkRequestRTT, contextFlag: false, hops: 0,
                           destinationHash: store.state.linkID, transportId: nil, payload: rttCipher)
    await store.send(.received(try! rttPacket.packed()))
    await store.receive { if case .delegate(.established) = $0 { return true }; return false }
    return store
}
```

For each test below, add `let clock = testClock()`, inject `$0.continuousClock = clock` in the store's `withDependencies`, and append the cleanup shown:

1. `initiatorEstablishEmitsLinkRequestAndGoesPending` — after its existing assertions, drive the establishment timer to fire so no effect lingers:
```swift
    await clock.advance(by: .seconds(store.state.establishmentTimeout))
    await store.receive(.establishmentDeadline)
    await store.receive(.delegate(.closed(.timedOut))) { $0.status = .closed }
```
2. `responderAcceptRequestEmitsProofAndGoesHandshake` — same cleanup (advance `establishmentTimeout`, receive `.establishmentDeadline`, receive `.delegate(.closed(.timedOut))`, `$0.status = .closed`).
3. `initiatorRejectsTamperedProof` — the link stays `.pending` after the failed proof, so the establishment timer is still running; append the same cleanup (advance + `.establishmentDeadline` + `.closed(.timedOut)`).
4. `initiatorReceivesLinkCloseAndGetsDestinationClosed`, `responderReceivesLinkCloseAndGoesClosed`, `initiatorCloseEmitsLinkCloseAndGoesClosed`, `activeLinkSendEmitsEncryptedDataPacket`, `activeLinkReceivesDataAndBubblesDataReceived`, `corruptInboundDataIsIgnoredAndLinkStaysActive`, `acceptRequestRejectsWrongLengthRequest` — these construct `activeState`/reject paths that do NOT start a timer in this task (data/close/send don't start timers; reject returns before the timer). Add `$0.continuousClock = testClock()` to each store's dependencies for consistency (harmless), but no cleanup change is required. EXCEPTION: `corruptInboundDataIsIgnoredAndLinkStaysActive` currently runs exhaustively and asserts the link stays active with no emitted action — keep it as is; it still emits nothing.
5. `initiatorAndResponderReachActiveWithEqualSessionKey` — both stores reach `.active`, which now starts an inactivity timer on each. Inject a shared clock into both stores and, at the end, close both links to cancel the timers:
```swift
    await initiator.send(.close)
    _ = await captureTransmit(initiator)
    await initiator.receive(.delegate(.closed(.initiatorClosed))) { $0.status = .closed }
    await responder.send(.close)
    _ = await captureTransmit(responder)
    await responder.receive(.delegate(.closed(.destinationClosed))) { $0.status = .closed }
```

Now add the NEW timer tests:

```swift
@Test @MainActor func establishmentTimesOutWhenNoProofArrives() async {
    let clock = TestClock()
    let store = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: Identity().publicKey)!,
                                        destinationHash: Data(repeating: 0x55, count: 16),
                                        interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: {
        $0.date = .constant(epoch)
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.establish)
    _ = await captureTransmit(store)                  // the LINKREQUEST
    await clock.advance(by: .seconds(store.state.establishmentTimeout))
    await store.receive(.establishmentDeadline)
    await store.receive(.delegate(.closed(.timedOut)))
    #expect(store.state.status == .closed)
}

@Test @MainActor func establishmentTimerIsCancelledOnceActive() async {
    // Reach .active, then advance past establishmentTimeout (< keepaliveInterval < staleTime) —
    // nothing fires because the establishment timer was cancelled at .active.
    let clock = TestClock()
    let store = await activeInitiatorStore(owner: Identity(), clock: clock)
    #expect(store.state.status == .active)
    await clock.advance(by: .seconds(store.state.establishmentTimeout))
    #expect(store.state.status == .active)
    // Clean up the running inactivity/keepalive timers.
    await store.send(.close); _ = await captureTransmit(store)
    await store.receive(.delegate(.closed(.initiatorClosed)))
}

@Test @MainActor func silentActiveLinkTimesOutAfterStaleTime() async {
    // A responder (no keepalive timer of its own) that hears nothing for staleTime tears down.
    let clock = TestClock()
    let store = await activeResponderStore(clock: clock)
    #expect(store.state.status == .active)
    await clock.advance(by: .seconds(store.state.keepaliveInterval * 2))
    await store.receive(.inactivityDeadline)
    let close = await captureTransmit(store)                 // LINKCLOSE teardown
    await store.receive(.delegate(.closed(.timedOut)))
    #expect(store.state.status == .closed)
    #expect(Packet(raw: close)!.context == .linkClose)
}
```

- [ ] **Step 2: Run to verify the new tests fail (compile errors)**

Run: `swift test --filter LinkSession`
Expected: FAIL — `.establishmentDeadline`/`.inactivityDeadline`/`.timedOut`/`continuousClock` usage don't exist yet.

- [ ] **Step 3: Extend the reducer**

In `Sources/ReTiCATransport/LinkSession.swift`, apply:

(a) Add `.timedOut` to `CloseReason`:
```swift
    public enum CloseReason: Equatable, Sendable { case initiatorClosed, destinationClosed, timedOut }
```

(b) After the `Status`/`CloseReason` enums, add the keepalive byte constants (used in Task 2, declared now):
```swift
    static let keepaliveByte: UInt8 = 0xFF
    static let keepaliveReplyByte: UInt8 = 0xFE
```

(c) Add State fields (after `rtt`), and initializer params. In `State`:
```swift
        public var activatedAt: Double?
        public var lastInbound: Double?
        public var establishmentTimeout: TimeInterval
        public var keepaliveInterval: TimeInterval
        var staleTime: TimeInterval { keepaliveInterval * 2 }
```
In BOTH initializers, add parameters `establishmentTimeout: TimeInterval = 15, keepaliveInterval: TimeInterval = 30` and assign them, plus `self.activatedAt = nil` and `self.lastInbound = nil`.

(d) Add the deadline actions to `Action` (after `.close`):
```swift
        case establishmentDeadline
        case keepaliveDeadline
        case inactivityDeadline
```

(e) Add the clock dependency and cancel ids (after `@Dependency(\.date) var date`):
```swift
    @Dependency(\.continuousClock) var clock

    private enum CancelID: Hashable { case establishment, keepalive, inactivity }
```

(f) Change the reducer closure to capture `[date, clock]` and add timer helpers at the top of the closure. Replace `Reduce { state, action in` with:
```swift
        Reduce { [date, clock] state, action in
            func establishmentTimer(_ t: TimeInterval) -> Effect<Action> {
                .run { send in try await clock.sleep(for: .seconds(t)); await send(.establishmentDeadline) }
                    .cancellable(id: CancelID.establishment, cancelInFlight: true)
            }
            func inactivityTimer(_ t: TimeInterval) -> Effect<Action> {
                .run { send in try await clock.sleep(for: .seconds(t)); await send(.inactivityDeadline) }
                    .cancellable(id: CancelID.inactivity, cancelInFlight: true)
            }
            let cancelAll = Effect<Action>.merge(.cancel(id: CancelID.establishment),
                                                 .cancel(id: CancelID.keepalive),
                                                 .cancel(id: CancelID.inactivity))
            func linkPacket(_ linkID: Data, _ context: PacketContext, _ payload: Data) -> Data? {
                let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                               destinationType: .link, context: context, contextFlag: false, hops: 0,
                               destinationHash: linkID, transportId: nil, payload: payload)
                return try? p.packed()
            }
```
(All existing `date.now` references now use the captured `date` — no other change to those lines.)

(g) In `.establish`, change the final `return .send(.delegate(.transmit(id, raw)))` to:
```swift
                return .merge(.send(.delegate(.transmit(id, raw))), establishmentTimer(state.establishmentTimeout))
```

(h) In `.acceptRequest`, change the final `return .send(.delegate(.transmit(id, raw)))` to:
```swift
                return .merge(.send(.delegate(.transmit(id, raw))), establishmentTimer(state.establishmentTimeout))
```

(i) In the initiator LRPROOF case (`(.initiator, .pending, .proof, .linkRequestProof)`), after `state.status = .active` add `state.activatedAt = now; state.lastInbound = now` (add `let now = date.now.timeIntervalSince1970` at the very start of the `.received` case if not already present — it is used below for rtt). Replace the two return branches so the active transition cancels establishment and starts the inactivity timer:
```swift
                    let established = Action.delegate(.established(linkID: state.linkID, sessionKey: key))
                    let extra = Effect<Action>.merge(.cancel(id: CancelID.establishment),
                                                     inactivityTimer(state.staleTime))
                    guard let raw = linkPacket(state.linkID, .linkRequestRTT, cipher) else {
                        return .merge(.send(established), extra)
                    }
                    return .merge(.send(.delegate(.transmit(state.interfaceID, raw))), .send(established), extra)
```
(Remove the old `let rttPacket = Packet(...)` / `try? rttPacket.packed()` construction; use `linkPacket(...)`.)

(j) In the responder LRRTT case (`(.responder, .handshake, .data, .linkRequestRTT)`), after `state.status = .active` add `state.activatedAt = now; state.lastInbound = now` and change the return to:
```swift
                    return .merge(.send(.delegate(.established(linkID: state.linkID, sessionKey: state.sessionKey))),
                                  .cancel(id: CancelID.establishment), inactivityTimer(state.staleTime))
```

(k) In `.close`, after `state.status = .closed`, change the returns to cancel all timers. Replace the existing `.merge(...)`/fallback with:
```swift
                let closedAction = Action.delegate(.closed(reason))
                guard let raw = linkPacket(state.linkID, .linkClose, cipher) else {
                    return .merge(.send(closedAction), cancelAll)
                }
                return .merge(.send(.delegate(.transmit(state.interfaceID, raw))), .send(closedAction), cancelAll)
```
(Use the existing `cipher = Link.encrypt(state.linkID, ...)`.)

(l) In the inbound LINKCLOSE case (`(_, .active, .data, .linkClose)`), change the return to also cancel timers:
```swift
                    state.status = .closed
                    let reason: CloseReason = state.role == .initiator ? .destinationClosed : .initiatorClosed
                    return .merge(.send(.delegate(.closed(reason))), cancelAll)
```

(m) Add the two deadline cases to the OUTER switch (before `case .delegate:`):
```swift
            case .establishmentDeadline:
                guard state.status == .pending || state.status == .handshake else { return .none }
                state.status = .closed
                return .merge(.send(.delegate(.closed(.timedOut))), cancelAll)

            case .keepaliveDeadline:
                return .none   // implemented in Task 2

            case .inactivityDeadline:
                guard state.status == .active else { return .none }
                let cipher = Link.encrypt(state.linkID, sessionKey: state.sessionKey)
                state.status = .closed
                let closedAction = Action.delegate(.closed(.timedOut))
                guard let raw = linkPacket(state.linkID, .linkClose, cipher) else {
                    return .merge(.send(closedAction), cancelAll)
                }
                return .merge(.send(.delegate(.transmit(state.interfaceID, raw))), .send(closedAction), cancelAll)
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter LinkSession`
Expected: PASS — updated establishment/active tests plus the 3 new timer tests.

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter LinkSession`, confirm the named test fails, revert; final green:
- In `.establishmentDeadline`, change the guard to `state.status == .active` (never true when pending) → `establishmentTimesOutWhenNoProofArrives` fails.
- In the initiator/responder active transitions, drop `.cancel(id: CancelID.establishment)` → `establishmentTimerIsCancelledOnceActive` fails (a stray `.establishmentDeadline`/timeout fires while active or the effect lingers).
- In `.inactivityDeadline`, change `state.status = .closed` to leave status → `silentActiveLinkTimesOutAfterStaleTime` fails.
- In the active transitions, drop `inactivityTimer(state.staleTime)` → `silentActiveLinkTimesOutAfterStaleTime` fails (no timeout / no effect).

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionTests.swift
git commit -m "feat: link establishment timeout + inactivity teardown (clock watchdog)"
```

---

### Task 2: Keepalive (send + reply + inactivity reset)

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift`
- Test: `Tests/ReTiCATransportTests/LinkSessionTests.swift`

**Interfaces:**
- Consumes: everything from Task 1 (`clock`, timer helpers, `CancelID`, `keepaliveByte`/`keepaliveReplyByte`, `linkPacket`).
- Produces: a repeating keepalive timer on the active initiator; `.keepaliveDeadline` emits a `0xFF` keepalive; a responder replies `0xFE` to an inbound `0xFF`; inbound keepalive resets the inactivity timer.

- [ ] **Step 1: Write the failing keepalive tests**

Append to `Tests/ReTiCATransportTests/LinkSessionTests.swift`:

```swift
@Test @MainActor func activeInitiatorEmitsKeepaliveEveryInterval() async {
    let clock = TestClock()
    let store = await activeInitiatorStore(owner: Identity(), clock: clock)   // now starts a keepalive timer
    await clock.advance(by: .seconds(store.state.keepaliveInterval))
    await store.receive(.keepaliveDeadline)
    let ka = await captureTransmit(store)
    let packet = Packet(raw: ka)!
    #expect(packet.context == .keepalive)
    #expect(packet.payload == Data([0xFF]))                    // unencrypted sentinel
    #expect(packet.destinationHash == store.state.linkID)
    // Clean up (cancels the keepalive + inactivity timers).
    await store.send(.close); _ = await captureTransmit(store)
    await store.receive(.delegate(.closed(.initiatorClosed)))
}

@Test @MainActor func responderRepliesToKeepaliveWith0xFE() async {
    var s = LinkSession.State(responderFor: Identity(), destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"))
    s.status = .active
    s.sessionKey = Data(repeating: 0x01, count: 64)
    s.linkID = Data(repeating: 0xAB, count: 16)
    let clock = TestClock()
    let store = TestStore(initialState: s) { LinkSession() }
        withDependencies: { $0.date = .constant(epoch); $0.continuousClock = clock }
    store.exhaustivity = .off

    // Inbound 0xFF keepalive → 0xFE reply.
    let ka = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                    destinationType: .link, context: .keepalive, contextFlag: false, hops: 0,
                    destinationHash: s.linkID, transportId: nil, payload: Data([0xFF]))
    await store.send(.received(try! ka.packed()))
    let reply = await captureTransmit(store)
    let packet = Packet(raw: reply)!
    #expect(packet.context == .keepalive)
    #expect(packet.payload == Data([0xFE]))

    await store.send(.close); _ = await captureTransmit(store)
    await store.receive(.delegate(.closed(.destinationClosed)))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter LinkSession`
Expected: FAIL — no keepalive emission/reply yet (`.keepaliveDeadline` is a no-op; no keepalive case in `.received`).

- [ ] **Step 3: Implement keepalive in the reducer**

In `Sources/ReTiCATransport/LinkSession.swift`:

(a) Start the keepalive timer on the initiator's active transition. Add a `keepaliveTimer` helper next to the others at the top of the Reduce closure:
```swift
            func keepaliveTimer(_ t: TimeInterval) -> Effect<Action> {
                .run { send in while true { try await clock.sleep(for: .seconds(t)); await send(.keepaliveDeadline) } }
                    .cancellable(id: CancelID.keepalive, cancelInFlight: true)
            }
```
In the initiator LRPROOF case, change `extra` to also start the keepalive timer:
```swift
                    let extra = Effect<Action>.merge(.cancel(id: CancelID.establishment),
                                                     inactivityTimer(state.staleTime),
                                                     keepaliveTimer(state.keepaliveInterval))
```
(The responder does NOT start a keepalive timer.)

(b) Implement `.keepaliveDeadline` (replace the Task-1 no-op):
```swift
            case .keepaliveDeadline:
                guard state.status == .active, state.role == .initiator else { return .none }
                guard let raw = linkPacket(state.linkID, .keepalive, Data([LinkSession.keepaliveByte]))
                else { return .none }
                return .send(.delegate(.transmit(state.interfaceID, raw)))
```

(c) Add the two keepalive cases to the inner `switch (state.role, state.status, packet.packetType, packet.context)` (before `default:`):
```swift
                case (.responder, .active, .data, .keepalive):
                    state.lastInbound = now
                    var effects: [Effect<Action>] = [inactivityTimer(state.staleTime)]
                    if packet.payload == Data([LinkSession.keepaliveByte]),
                       let raw = linkPacket(state.linkID, .keepalive, Data([LinkSession.keepaliveReplyByte])) {
                        effects.append(.send(.delegate(.transmit(state.interfaceID, raw))))
                    }
                    return .merge(effects)

                case (.initiator, .active, .data, .keepalive):
                    guard packet.payload != Data([LinkSession.keepaliveByte]) else { return .none } // ignore own 0xFF loopback
                    state.lastInbound = now
                    return inactivityTimer(state.staleTime)                                          // 0xFE reply resets inactivity
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter LinkSession`
Expected: PASS — including the two new keepalive tests and all Task-1 tests.

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter LinkSession`, confirm the named test fails, revert; final green:
- In `.keepaliveDeadline`, change the payload to `Data([LinkSession.keepaliveReplyByte])` (0xFE) → `activeInitiatorEmitsKeepaliveEveryInterval` fails (expects 0xFF).
- In the initiator active transition, drop `keepaliveTimer(state.keepaliveInterval)` → `activeInitiatorEmitsKeepaliveEveryInterval` fails (no keepalive fires).
- In the `(.responder, .active, .data, .keepalive)` case, remove the reply append → `responderRepliesToKeepaliveWith0xFE` fails.

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionTests.swift
git commit -m "feat: link keepalive (0xFF send, 0xFE reply, inactivity reset)"
```

---

### Task 3: End-to-end watchdog, full-suite gate, README

**Files:**
- Modify: `Tests/ReTiCATransportTests/LinkSessionTests.swift` (end-to-end test)
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–2.
- Produces: no new production API.

- [ ] **Step 1: Write the end-to-end watchdog test**

Append to `Tests/ReTiCATransportTests/LinkSessionTests.swift`:

```swift
@Test @MainActor func keepaliveKeepsLinkAliveThenStarvedSideTimesOut() async {
    let owner = Identity()
    let destHash = Data(repeating: 0xC0, count: 16)
    let clock = TestClock()
    let initiator = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: owner.publicKey)!,
                                        destinationHash: destHash, interfaceID: InterfaceID("a"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch); $0.continuousClock = clock }
    initiator.exhaustivity = .off
    let responder = TestStore(
        initialState: LinkSession.State(responderFor: owner, destinationHash: destHash,
                                        interfaceID: InterfaceID("b"))
    ) { LinkSession() } withDependencies: { $0.date = .constant(epoch); $0.continuousClock = clock }
    responder.exhaustivity = .off

    // Establish.
    await initiator.send(.establish)
    let req = await captureTransmit(initiator)
    await responder.send(.acceptRequest(req))
    let proof = await captureTransmit(responder)
    await initiator.send(.received(proof))
    let rtt = await captureTransmit(initiator)
    await initiator.receive { if case .delegate(.established) = $0 { return true }; return false }
    await responder.send(.received(rtt))
    await responder.receive { if case .delegate(.established) = $0 { return true }; return false }

    // Two keepalive cycles delivered across → both stay active (each side's inactivity keeps
    // getting reset by the other's keepalive traffic). `keepaliveInterval` (30) < `staleTime` (60),
    // so no inactivity deadline is reached while pings flow.
    for _ in 0..<2 {
        await clock.advance(by: .seconds(initiator.state.keepaliveInterval))
        await initiator.receive(.keepaliveDeadline)
        let ping = await captureTransmit(initiator)                 // 0xFF
        await responder.send(.received(ping))                       // responder resets inactivity, replies 0xFE
        let pong = await captureTransmit(responder)
        await initiator.send(.received(pong))                       // initiator resets inactivity
    }
    #expect(initiator.state.status == .active)
    #expect(responder.state.status == .active)

    // Stop the pings: close the initiator (cancels its timers) so ONLY the responder is left. Its
    // inactivity timer was last reset at the loop's final ping; advancing a full staleTime with no
    // further inbound reaches its deadline → self-teardown.
    await initiator.send(.close); _ = await captureTransmit(initiator)
    await initiator.receive(.delegate(.closed(.initiatorClosed)))

    await clock.advance(by: .seconds(responder.state.keepaliveInterval * 2))
    await responder.receive(.inactivityDeadline)
    _ = await captureTransmit(responder)                            // LINKCLOSE
    await responder.receive(.delegate(.closed(.timedOut)))
    #expect(responder.state.status == .closed)
}

// NOTE (shared TestClock choreography): both stores share one `TestClock`, so each `advance`
// fires timers on BOTH. The advances above are sized (keepaliveInterval=30 < staleTime=60) so only
// the intended timer fires each step; with `exhaustivity = .off`, any incidental extra action is
// tolerated, but in-flight effects must still be cancelled by a close before the test ends. If the
// exact advance amounts don't land on a deadline in practice, adjust them (or split into two
// clocks) to keep the suite green without changing the asserted behavior.
```

Note: with `exhaustivity = .off`, unconsumed initiator `.keepaliveDeadline`/transmit actions produced during the final `advance` are ignored; the assertions target the responder's timeout. If the test framework still flags leftover initiator effects, close the initiator BEFORE the final `advance` (it does not affect the responder's independent timeout). Prefer whichever leaves the suite green.

- [ ] **Step 2: Run the end-to-end test**

Run: `swift test --filter LinkSession`
Expected: PASS.

- [ ] **Step 3: Run the full suite**

Run: `swift test`
Expected: PASS — all prior tests plus the watchdog tests.

- [ ] **Step 4: Mutation sweep on the end-to-end test**

Confirm it genuinely exercises keep-alive + starvation (revert each before the next):
- In the `(.responder, .active, .data, .keepalive)` case, drop the `inactivityTimer(...)` reset → the responder times out during the "kept alive" phase → `keepaliveKeepsLinkAliveThenStarvedSideTimesOut` fails (times out too early).
- In `.inactivityDeadline`, guard on `state.role == .initiator` (so a responder never times out) → the starvation phase never fires → the test's `await responder.receive(.inactivityDeadline)` fails.
Run `swift test` after reverting → green.

- [ ] **Step 5: Update the README**

In `README.md`, in the "Link establishment, data flow, and close (`LinkSession`)" subsection, append a paragraph after the data/close description:

```markdown
A `LinkSession` is self-maintaining once it has a clock (`@Dependency(\.continuousClock)`): a
hung handshake times out (`.pending`/`.handshake` past `establishmentTimeout` → `.closed` with
`CloseReason.timedOut`); the initiator sends an unencrypted `0xFF` keepalive every
`keepaliveInterval` and the responder replies `0xFE`, which keeps both sides' inactivity timers
fresh; and a link that hears nothing for `staleTime` (`2 × keepaliveInterval`) tears itself down
(LINKCLOSE + `.closed(.timedOut)`). Durations are local policy (simplified from RNS's per-hop
computation, which needs Transport); only the keepalive packet (`context .keepalive`,
unencrypted `0xFF`/`0xFE`) is wire-visible and matches RNS 1.3.8.
```

Update the deferred-items note in that subsection (and any "Not Yet Implemented" mention) so keepalive/watchdog/timeouts are no longer listed as future; keep identify, requests, resources, RTT-adaptive intervals, and Transport/Endpoint wiring listed as future.

- [ ] **Step 6: Commit**

```
git add Tests/ReTiCATransportTests/LinkSessionTests.swift README.md
git commit -m "test: end-to-end link watchdog; docs: LinkSession keepalive/timeouts"
```

---

## Self-Review

**Spec coverage:**
- Establishment timeout → Task 1 (`.establishmentDeadline`, establishment timer, cancel-on-active). ✓
- Inactivity teardown → Task 1 (`.inactivityDeadline`, inactivity timer, LINKCLOSE + `.closed(.timedOut)`). ✓
- Keepalive send (initiator 0xFF) + responder 0xFE reply + inactivity reset on keepalive → Task 2. ✓
- `CloseReason.timedOut` → Task 1. ✓
- Unencrypted keepalive framing (context 0xFA, 0xFF/0xFE) → Task 2 tests assert `packet.payload == Data([0xFF/0xFE])` on the raw packet. ✓
- Timers cancelled on all close paths (`.close`, inbound LINKCLOSE, establishment/inactivity deadlines) → Task 1 (`cancelAll`). ✓
- Configurable durations with defaults 15/30 (stale 60) → Task 1 State/init. ✓
- Reset-on-keepalive-only simplification (data doesn't touch timers) → documented; 5-links-c data tests only get a harmless clock injection. ✓
- End-to-end keep-alive + starvation → Task 3. ✓
- Mutation discipline → Task 1/2/3 sweeps. ✓
- Scope: only LinkSession + tests + README; no Transport wiring, no RTT-adaptive, no STALE state. ✓

**Placeholder scan:** No TBD/TODO. The Task-3 Step-1 note about draining leftover effects gives a concrete either/or with a green-suite tie-breaker — an explicit instruction, not a placeholder. The Task-1 `establishmentTimerIsCancelledOnceActive` cleanup drives the responder (still `.handshake`) to its establishment timeout, which is a real terminal path.

**Type consistency:** `CloseReason.timedOut`, actions `.establishmentDeadline`/`.keepaliveDeadline`/`.inactivityDeadline`, State fields `establishmentTimeout`/`keepaliveInterval`/`staleTime`/`activatedAt`/`lastInbound`, constants `keepaliveByte`/`keepaliveReplyByte`, helper `linkPacket(_:_:_:)`, and `CancelID` cases are declared in Task 1 and reused unchanged in Task 2/3. Keepalive framing (`.data`/`.keepalive`/`.link`/payload `0xFF`/`0xFE`) is identical between production (`linkPacket`) and the test assertions.
