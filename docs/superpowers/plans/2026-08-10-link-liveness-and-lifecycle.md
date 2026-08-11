# Link Liveness and Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `LinkSession` tearing down healthy links mid-transfer, and close two adjacent lifecycle defects (silently-vanishing resource transfers on close; large requests failing before they finish uploading).

**Architecture:** All six tasks are confined to `Sources/ReTiCATransport/LinkSession.swift`. Task 1 hoists the inactivity re-arm above the inbound-packet switch so every inbound packet counts as proof of life — structurally preventing the "new context, forgot to re-arm" recurrence. Tasks 2-4 then make the liveness model faithful to reference `RNS/Link.py`: an outbound timestamp, silence-gated keepalives, and a STALE grace state. Tasks 5-6 are independent one-branch fixes.

**Tech Stack:** Swift 6, The Composable Architecture (`@Reducer`, `TestStore`), `swift-testing` (`@Test`/`#expect`), `TestClock` for deterministic timers.

## Global Constraints

- Platform floor: iOS 16 / macOS 13 (package-wide; do not raise).
- `ReTiCATransport` is interface-agnostic — no Network.framework, no CoreBluetooth.
- Wire compatibility with Python-RNS 1.4.1/1.4.2 is mandatory. No task here changes any byte on the wire except *when* packets are emitted; if a task's diff changes a packet's bytes, stop and escalate.
- Tests use `swift-testing` (`import Testing`, `@Test @MainActor func …`, `#expect`), not XCTest.
- `store.exhaustivity = .off` is the house style for `LinkSession` tests. When a test must prove a packet was NOT sent, send in `.off` and flip `.on` **last** — teardown reads exhaustivity at call time and will catch a stray transmit.
- Timers are `TestClock<Duration>`; never use real sleeps.
- Verify tests per the three-step process: (a) run and confirm pass, (b) batch-mutate the production code so they should fail and confirm every one fails, (c) revert and confirm pass again.
- Commit after each task. Trailers must start at column 0:

```
Co-Authored-By: Claude <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

### Task 1: Any inbound packet on an active link re-arms the inactivity timer

**Why:** `inactivityTimer` is currently re-armed at only four sites — activation (`LinkSession.swift:351, 367`) and inbound KEEPALIVE (`:384, 394`). Inbound DATA, RESOURCE, REQUEST, RESPONSE and LINKIDENTIFY do not re-arm. Reference stamps `last_inbound` on *every* inbound link packet (`RNS/Link.py:935-936`). Because reference peers suppress keepalives while traffic flows (`Link.py:749` initiator, `Link.py:1125` responder), any transfer longer than `staleTime` (60 s) is currently torn down mid-flight in both roles.

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift:326-474` (the `.received` case)
- Test: `Tests/ReTiCATransportTests/LinkSessionTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `State.lastInbound` becomes a *read* value (it is currently write-only dead state). No signature changes.

- [ ] **Step 1: Write the failing test**

Append to `Tests/ReTiCATransportTests/LinkSessionTests.swift`:

```swift
// An active link carrying only DATA (no keepalives) must NOT time out. Reference peers
// suppress keepalives while traffic flows (RNS/Link.py:749, :1125), so inbound data is the
// only proof of life available during a transfer.
@Test @MainActor func inboundDataKeepsLinkAlive() async {
    let clock = testClock()
    let owner = Identity()
    let store = await activeInitiatorStore(owner: owner, clock: clock)
    let key = store.state.sessionKey
    let linkID = store.state.linkID

    // Three rounds of: advance just under staleTime, then deliver one DATA packet.
    for i in 0..<3 {
        await clock.advance(by: .seconds(store.state.staleTime - 1))
        let cipher = Link.encrypt(Data([UInt8(i)]), sessionKey: key)
        let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                            destinationType: .link, context: .none, contextFlag: false, hops: 0,
                            destinationHash: linkID, transportId: nil, payload: cipher)
        await store.send(.received(try! packet.packed()))
        await store.receive { if case .delegate(.dataReceived) = $0 { return true }; return false }
    }

    // Cumulative elapsed time is ~3x staleTime, but each DATA packet reset the timer.
    #expect(store.state.status == .active)

    await store.send(.close)
    _ = await captureTransmit(store)
    await store.receive { if case .delegate(.closed) = $0 { return true }; return false }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter inboundDataKeepsLinkAlive`
Expected: FAIL — the link closes with `.timedOut` on the first `clock.advance`, so `status` is `.closed` and the test receives an unexpected `.closed` delegate before the loop finishes.

- [ ] **Step 3: Hoist the re-arm above the switch**

In `Sources/ReTiCATransport/LinkSession.swift`, replace lines 326-330:

```swift
            case let .received(data):
                guard let packet = Packet(raw: data), packet.destinationHash == state.linkID
                else { return .none }
                let now = date.now.timeIntervalSince1970
                switch (state.role, state.status, packet.packetType, packet.context) {
```

with:

```swift
            case let .received(data):
                guard let packet = Packet(raw: data), packet.destinationHash == state.linkID
                else { return .none }
                let now = date.now.timeIntervalSince1970
                // Every inbound packet on an ACTIVE link is proof of life (RNS/Link.py:935-936
                // stamps `last_inbound` unconditionally). Hoisted above the switch deliberately:
                // re-arming per-branch is how the 60s mid-transfer teardown got in — DATA,
                // RESOURCE, REQUEST, RESPONSE and LINKIDENTIFY each silently omitted it. Adding a
                // new context must not require remembering this.
                func dispatch(_ state: inout State) -> Effect<Action> {
                switch (state.role, state.status, packet.packetType, packet.context) {
```

Then find the end of that switch — line 473-474, currently:

```swift
                default:
                    return .none
                }
```

and replace it with:

```swift
                default:
                    return .none
                }
                }
                let effect = dispatch(&state)
                // Re-arm only if the link is still active AFTER dispatch: the LINKCLOSE branch
                // sets .closed and cancels its timers, and must not have one re-armed behind it.
                guard state.status == .active else { return effect }
                state.lastInbound = now
                return .merge(effect, inactivityTimer(state.staleTime))
```

The switch body itself is moved verbatim — do not edit any case. `inactivityTimer` uses `cancelInFlight: true`, so the four branches that already re-arm stay correct and simply re-arm twice, idempotently.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter inboundDataKeepsLinkAlive`
Expected: PASS

- [ ] **Step 5: Run the full LinkSession suite**

Run: `swift test --filter LinkSession`
Expected: all pass. If `keepaliveKeepsLinkAliveThenStarvedSideTimesOut` (`LinkSessionTests.swift:553`) fails, read it before changing it — it asserts the starved side *does* time out, which must still hold since that side receives nothing at all.

- [ ] **Step 6: Commit**

```bash
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionTests.swift
git commit -m "fix: any inbound packet on an active link re-arms the inactivity timer"
```

---

### Task 2: Track outbound activity and gate the initiator keepalive on silence

**Why:** ReTiCA's keepalive is an unconditional `while true` loop (`LinkSession.swift:194-197, 628-632`). Reference sends one only when inbound *or* outbound has been silent for `keepalive`, and additionally throttles on `last_keepalive` (`RNS/Link.py:749-751`). Without an outbound timestamp the gate cannot be expressed, and ReTiCA emits keepalives during active transfers — worst on LoRa, the medium least able to carry them.

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift` — `State` (add `lastOutbound`), both `init`s, `.keepaliveDeadline` (`:628-632`), and every outbound emission site
- Test: `Tests/ReTiCATransportTests/LinkSessionTests.swift`

**Interfaces:**
- Consumes: `State.lastInbound` (now live, from Task 1).
- Produces: `public var lastOutbound: Double?` on `State`, defaulting to `nil` in both initialisers. Later tasks read it.

- [ ] **Step 1: Write the failing test**

```swift
// Reference gates the initiator keepalive on silence (RNS/Link.py:749): while traffic is
// flowing in either direction, no keepalive is emitted.
@Test @MainActor func keepaliveSuppressedWhileTrafficFlows() async {
    let clock = testClock()
    let owner = Identity()
    let store = await activeInitiatorStore(owner: owner, clock: clock)
    let key = store.state.sessionKey
    let linkID = store.state.linkID

    // Keep the link busy: inbound DATA just under the keepalive interval.
    await clock.advance(by: .seconds(store.state.keepaliveInterval - 1))
    let cipher = Link.encrypt(Data([0x01]), sessionKey: key)
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .link, context: .none, contextFlag: false, hops: 0,
                        destinationHash: linkID, transportId: nil, payload: cipher)
    await store.send(.received(try! packet.packed()))
    await store.receive { if case .delegate(.dataReceived) = $0 { return true }; return false }

    // The keepalive timer fires, but inbound is fresh — nothing should go out.
    await clock.advance(by: .seconds(1))
    await store.receive(.keepaliveDeadline)

    // Flip exhaustivity ON last so teardown catches a stray transmit.
    store.exhaustivity = .on
    await store.send(.close)
    _ = await captureTransmit(store)
    await store.receive { if case .delegate(.closed) = $0 { return true }; return false }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter keepaliveSuppressedWhileTrafficFlows`
Expected: FAIL — an unexpected `delegate(.transmit)` carrying the 0xFF keepalive is received after `.keepaliveDeadline`.

- [ ] **Step 3: Add `lastOutbound` to State**

In `Sources/ReTiCATransport/LinkSession.swift`, after `public var lastInbound: Double?` (line 52) add:

```swift
        /// Timestamp of the last packet WE emitted on this link. Reference `Link.last_outbound`
        /// (RNS/Link.py:246), refreshed by every link packet send (RNS/Packet.py:294). Read by the
        /// keepalive gate: reference suppresses keepalives while either direction is busy.
        public var lastOutbound: Double?
```

In the initiator `init` after `self.lastInbound = nil` (line 94) add `self.lastOutbound = nil`.
In the responder `init` after `self.lastInbound = nil` (line 120) add `self.lastOutbound = nil`.

- [ ] **Step 4: Stamp `lastOutbound` at every outbound emission**

Add this helper inside the `Reduce` closure, immediately after the `linkPacket` helper (after line 211):

```swift
            /// Record an outbound emission and return the transmit effect. Every link packet we
            /// send must go through this — the keepalive gate reads `lastOutbound`.
            func transmit(_ state: inout State, _ raw: Data) -> Effect<Action> {
                state.lastOutbound = date.now.timeIntervalSince1970
                return .send(.delegate(.transmit(state.interfaceID, raw)))
            }
```

Then replace each `.send(.delegate(.transmit(state.interfaceID, raw)))` (and the `let id = state.interfaceID` / `.send(.delegate(.transmit(id, raw)))` variants) with `transmit(&state, raw)` at these sites:

| Line | Case |
|---|---|
| 324 | `.acceptRequest` LRPROOF |
| 356 | initiator LRRTT |
| 387 | responder 0xFE keepalive reply |
| 518 | `.identify` |
| 536 | `.sendRequest` inline |
| 567 | `.sendResponse` inline |
| 589 | `.send` |
| 601 | `.close` LINKCLOSE |
| 632 | `.keepaliveDeadline` 0xFF |
| 643 | `.inactivityDeadline` LINKCLOSE |
| 661 | `.sendWithReceipt` |
| 686 | `.provePacket` |
| 694 | `.transfer` transmit forward — **leave as-is**; it re-emits a child's `transmit(ifID, raw)` where `ifID` comes from the transfer, and resource part-packets flooding `lastOutbound` is exactly what reference does too (`Packet.py:294`). Change it to `state.lastOutbound = date.now.timeIntervalSince1970; return .send(...)` keeping the child's `ifID`. |

For the establishment sites (324, 356) the link is not yet `.active`; stamping is still correct and harmless.

- [ ] **Step 5: Gate the keepalive**

Replace `.keepaliveDeadline` (lines 628-632):

```swift
            case .keepaliveDeadline:
                guard state.status == .active, state.role == .initiator else { return .none }
                guard let raw = linkPacket(state.linkID, .keepalive, Data([LinkSession.keepaliveByte]))
                else { return .none }
                return .send(.delegate(.transmit(state.interfaceID, raw)))
```

with:

```swift
            case .keepaliveDeadline:
                guard state.status == .active, state.role == .initiator else { return .none }
                // RNS/Link.py:749 — emit only when BOTH directions have been silent for at least
                // one keepalive interval. During a transfer the link is self-evidently alive and a
                // keepalive is pure overhead (and on LoRa, harmful overhead).
                let now = date.now.timeIntervalSince1970
                let lastInbound = max(state.lastInbound ?? 0, state.activatedAt ?? 0)
                let quietInbound = now >= lastInbound + state.keepaliveInterval
                let quietOutbound = now >= (state.lastOutbound ?? 0) + state.keepaliveInterval
                guard quietInbound || quietOutbound else { return .none }
                guard let raw = linkPacket(state.linkID, .keepalive, Data([LinkSession.keepaliveByte]))
                else { return .none }
                return transmit(&state, raw)
```

- [ ] **Step 6: Run the tests**

Run: `swift test --filter LinkSession`
Expected: all pass, including `keepaliveSuppressedWhileTrafficFlows` and the existing `keepaliveDeadline` test at `LinkSessionTests.swift:515` (that one advances the clock with no traffic, so both directions are quiet and the keepalive still goes out).

- [ ] **Step 7: Commit**

```bash
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionTests.swift
git commit -m "fix: gate the initiator keepalive on bidirectional silence"
```

---

### Task 3: Gate the responder's 0xFE reply on outbound silence

**Why:** ReTiCA always answers an inbound `0xFF` with `0xFE` (`LinkSession.swift:382-389`). Reference replies only if it has itself been outbound-silent for `keepalive` (`RNS/Link.py:1124-1125`), because a responder that is actively sending has already proven liveness.

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift:382-389`
- Test: `Tests/ReTiCATransportTests/LinkSessionTests.swift`

**Interfaces:**
- Consumes: `State.lastOutbound` and the `transmit(_:_:)` helper from Task 2.
- Produces: no new symbols.

- [ ] **Step 1: Write the failing test**

```swift
// RNS/Link.py:1125 — a responder that has recently sent something does not answer 0xFF,
// because its own traffic already proved the link is alive.
@Test @MainActor func responderSkipsKeepaliveReplyWhenRecentlyOutbound() async {
    let clock = testClock()
    let store = await activeResponderStore(clock: clock)
    let linkID = store.state.linkID

    // Responder sends application data → lastOutbound is fresh.
    await store.send(.send(Data([0xAA])))
    _ = await captureTransmit(store)

    // An inbound 0xFF arrives immediately after. No 0xFE should be emitted.
    let ping = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                      destinationType: .link, context: .keepalive, contextFlag: false, hops: 0,
                      destinationHash: linkID, transportId: nil,
                      payload: Data([LinkSession.keepaliveByte]))
    store.exhaustivity = .on
    await store.send(.received(try! ping.packed()))

    await store.send(.close)
    _ = await captureTransmit(store)
    await store.receive { if case .delegate(.closed) = $0 { return true }; return false }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter responderSkipsKeepaliveReplyWhenRecentlyOutbound`
Expected: FAIL — an unexpected `delegate(.transmit)` carrying 0xFE is emitted.

- [ ] **Step 3: Add the gate**

Replace lines 382-389:

```swift
                case (.responder, .active, .data, .keepalive):
                    state.lastInbound = now
                    var effects: [Effect<Action>] = [inactivityTimer(state.staleTime)]
                    if packet.payload == Data([LinkSession.keepaliveByte]),
                       let raw = linkPacket(state.linkID, .keepalive, Data([LinkSession.keepaliveReplyByte])) {
                        effects.append(.send(.delegate(.transmit(state.interfaceID, raw))))
                    }
                    return .merge(effects)
```

with:

```swift
                case (.responder, .active, .data, .keepalive):
                    // Task 1 hoisted the lastInbound stamp and inactivity re-arm above this switch.
                    // RNS/Link.py:1125 — reply only if we have been outbound-silent for a full
                    // keepalive interval; our own recent traffic already proved liveness.
                    guard packet.payload == Data([LinkSession.keepaliveByte]),
                          now >= (state.lastOutbound ?? 0) + state.keepaliveInterval,
                          let raw = linkPacket(state.linkID, .keepalive,
                                               Data([LinkSession.keepaliveReplyByte]))
                    else { return .none }
                    return transmit(&state, raw)
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter LinkSession`
Expected: all pass. `keepaliveKeepsLinkAliveThenStarvedSideTimesOut` (`:553`) drives synthetic pings into a responder that never sends — `lastOutbound` stays `nil`, so `0 + keepaliveInterval` is exceeded and the reply still goes out.

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionTests.swift
git commit -m "fix: responder answers 0xFF only after a full keepalive of outbound silence"
```

---

### Task 4: Add the STALE grace state before teardown

**Why:** Reference goes ACTIVE → STALE, sends one final keepalive, and allows `rtt * KEEPALIVE_TIMEOUT_FACTOR + STALE_GRACE` = `rtt*4 + 5` seconds of grace before tearing down, recovering to ACTIVE if anything arrives (`RNS/Link.py:753-766`, `:939`; constants at `:84, :88`). ReTiCA's `Status` has no STALE and jumps straight to `.closed` with zero grace, so one dropped keepalive on a lossy link kills a healthy session.

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift` — `Status` enum (`:16`), `.inactivityDeadline` (`:634-643`), the Task-1 hoist guard, and add a `.staleDeadline` action
- Test: `Tests/ReTiCATransportTests/LinkSessionTests.swift`

**Interfaces:**
- Consumes: the Task-1 hoist (`guard state.status == .active`), `transmit(_:_:)` from Task 2.
- Produces: `Status.stale` case; `Action.staleDeadline`; `CancelID.stale`.

- [ ] **Step 1: Write the failing tests**

```swift
// A silent link enters STALE (not CLOSED) and recovers if traffic arrives during the grace.
@Test @MainActor func staleLinkRecoversOnInboundDuringGrace() async {
    let clock = testClock()
    let owner = Identity()
    let store = await activeInitiatorStore(owner: owner, clock: clock)
    let key = store.state.sessionKey
    let linkID = store.state.linkID

    await clock.advance(by: .seconds(store.state.staleTime))
    await store.receive(.inactivityDeadline)
    #expect(store.state.status == .stale)

    // Traffic during the grace window restores ACTIVE.
    let cipher = Link.encrypt(Data([0x02]), sessionKey: key)
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .link, context: .none, contextFlag: false, hops: 0,
                        destinationHash: linkID, transportId: nil, payload: cipher)
    await store.send(.received(try! packet.packed()))
    await store.receive { if case .delegate(.dataReceived) = $0 { return true }; return false }
    #expect(store.state.status == .active)

    await store.send(.close)
    _ = await captureTransmit(store)
    await store.receive { if case .delegate(.closed) = $0 { return true }; return false }
}

// If nothing arrives during the grace, the link tears down as before.
@Test @MainActor func staleLinkTearsDownAfterGrace() async {
    let clock = testClock()
    let owner = Identity()
    let store = await activeInitiatorStore(owner: owner, clock: clock)
    let rtt = store.state.rtt ?? 0

    await clock.advance(by: .seconds(store.state.staleTime))
    await store.receive(.inactivityDeadline)
    #expect(store.state.status == .stale)

    await clock.advance(by: .seconds(rtt * 4 + 5))
    await store.receive(.staleDeadline)
    _ = await captureTransmit(store)                       // LINKCLOSE
    await store.receive { if case .delegate(.closed(.timedOut)) = $0 { return true }; return false }
    #expect(store.state.status == .closed)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter staleLink`
Expected: FAIL to compile — `Status.stale` and `Action.staleDeadline` do not exist.

- [ ] **Step 3: Add the STALE state**

Change the `Status` enum (line 16):

```swift
    public enum Status: Equatable, Sendable { case pending, handshake, active, stale, closed }
```

Add to `Action` (after `case inactivityDeadline`, line 137):

```swift
        case staleDeadline
```

Add to `CancelID` (line 180):

```swift
    private enum CancelID: Hashable {
        case establishment, keepalive, inactivity, stale, request(Data), receipt(Data)
    }
```

Add a `staleTimer` helper after `keepaliveTimer` (line 197):

```swift
            func staleTimer(_ t: TimeInterval) -> Effect<Action> {
                .run { send in try await clock.sleep(for: .seconds(t)); await send(.staleDeadline) }
                    .cancellable(id: CancelID.stale, cancelInFlight: true)
            }
```

Add `.cancel(id: CancelID.stale)` to `cancelAll` (line 198-200):

```swift
            let cancelAll = Effect<Action>.merge(.cancel(id: CancelID.establishment),
                                                 .cancel(id: CancelID.keepalive),
                                                 .cancel(id: CancelID.inactivity),
                                                 .cancel(id: CancelID.stale))
```

- [ ] **Step 4: Make `.inactivityDeadline` enter STALE instead of closing**

Replace lines 634-643:

```swift
            case .inactivityDeadline:
                guard state.status == .active else { return .none }
                let cipher = Link.encrypt(state.linkID, sessionKey: state.sessionKey)
                state.status = .closed
                let closedAction = Action.delegate(.closed(.timedOut))
                let pending = cancelPending(&state)
                guard let raw = linkPacket(state.linkID, .linkClose, cipher) else {
                    return .merge(.send(closedAction), cancelAll, pending)
                }
                return .merge(.send(.delegate(.transmit(state.interfaceID, raw))), .send(closedAction), cancelAll, pending)
```

with:

```swift
            case .inactivityDeadline:
                guard state.status == .active else { return .none }
                // RNS/Link.py:753-766 — go STALE, send one last keepalive, and allow
                // rtt*KEEPALIVE_TIMEOUT_FACTOR + STALE_GRACE (4 and 5, RNS/Link.py:84,88) before
                // tearing down. Any inbound packet during the grace restores ACTIVE.
                state.status = .stale
                let grace = (state.rtt ?? 0) * 4 + 5
                var effects: [Effect<Action>] = [staleTimer(grace)]
                if state.role == .initiator,
                   let raw = linkPacket(state.linkID, .keepalive, Data([LinkSession.keepaliveByte])) {
                    effects.append(transmit(&state, raw))
                }
                return .merge(effects)

            case .staleDeadline:
                guard state.status == .stale else { return .none }
                let cipher = Link.encrypt(state.linkID, sessionKey: state.sessionKey)
                state.status = .closed
                let closedAction = Action.delegate(.closed(.timedOut))
                let pending = cancelPending(&state)
                guard let raw = linkPacket(state.linkID, .linkClose, cipher) else {
                    return .merge(.send(closedAction), cancelAll, pending)
                }
                return .merge(transmit(&state, raw), .send(closedAction), cancelAll, pending)
```

- [ ] **Step 5: Recover to ACTIVE on inbound during the grace**

In the Task-1 hoist at the end of `.received`, replace:

```swift
                let effect = dispatch(&state)
                guard state.status == .active else { return effect }
                state.lastInbound = now
                return .merge(effect, inactivityTimer(state.staleTime))
```

with:

```swift
                let effect = dispatch(&state)
                // RNS/Link.py:939 — a STALE link that hears anything is alive again.
                if state.status == .stale { state.status = .active }
                guard state.status == .active else { return effect }
                state.lastInbound = now
                return .merge(effect, .cancel(id: CancelID.stale), inactivityTimer(state.staleTime))
```

Note the `dispatch` switch matches on `state.status`, so while STALE none of the `.active` cases fire and `effect` is `.none`. That is intentional for this task: the packet revives the link but is not processed. If a later slice needs STALE packets processed, add `.stale` to the relevant case patterns — do not reorder this block.

- [ ] **Step 6: Run the tests**

Run: `swift test --filter LinkSession`
Expected: all pass. Existing tests that assert teardown after `staleTime` (e.g. `LinkSessionTests.swift:501`, `:604`) now need an extra `clock.advance(by: .seconds(rtt * 4 + 5))` and a `store.receive(.staleDeadline)` before the close assertions — update them, and note in each why (the STALE grace is new, reference-faithful behaviour).

- [ ] **Step 7: Commit**

```bash
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionTests.swift
git commit -m "feat: add the STALE grace state before link teardown"
```

---

### Task 5: Cancel hosted resource transfers when the link closes

**Why:** `cancelPending` (`LinkSession.swift:201-205`) cancels only request timers; `cancelAll` cancels only establishment/keepalive/inactivity. Hosted `state.transfers` are never cancelled on `.close`, `.staleDeadline`, or a peer-initiated LINKCLOSE. `LinkPlane` then removes the whole element (`LinkPlane.swift:209`), cancelling every child effect — so an in-flight resource vanishes with no `.failed` delegate and a caller awaiting conclusion hangs forever. Reference explicitly cancels both directions in `link_closed()` (`RNS/Link.py:685-687`).

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift` — add a `failTransfers` helper, call it from all three close paths
- Test: `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift`

**Interfaces:**
- Consumes: `State.transfers` (`IdentifiedArrayOf<ResourceTransfer.State>`), `Action.Delegate.resourceFailed(Data)`.
- Produces: `func failTransfers(_ state: inout State) -> Effect<Action>` (local to the `Reduce` closure).

- [ ] **Step 1: Write the failing test**

Append to `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift`:

```swift
// Closing a link with an in-flight resource must surface resourceFailed for it. Without this
// the transfer is silently cancelled when LinkPlane removes the element, and any caller
// awaiting conclusion waits forever.
@Test @MainActor func closingLinkFailsInFlightTransfers() async {
    let clock = testClock()
    let owner = Identity()
    let store = await activeInitiatorStore(owner: owner, clock: clock)

    await store.send(.sendResource(Data(repeating: 0x7A, count: 4096)))
    await store.receive { if case .transfer = $0 { return true }; return false }
    _ = await captureTransmit(store)                       // RESOURCE_ADV
    #expect(store.state.transfers.count == 1)
    let hash = store.state.transfers.first!.resourceHash

    let failed = LockIsolated<Data?>(nil)
    await store.send(.close)
    _ = await captureTransmit(store)                       // LINKCLOSE
    await store.receive { action in
        if case let .delegate(.resourceFailed(h)) = action { failed.setValue(h); return true }
        return false
    }
    await store.receive { if case .delegate(.closed) = $0 { return true }; return false }

    #expect(failed.value == hash)
    #expect(store.state.transfers.isEmpty)
}
```

If `activeInitiatorStore` and `captureTransmit` are `private` to `LinkSessionTests.swift`, copy them into `LinkSessionResourceTests.swift` rather than widening their access — the file already has its own helpers; follow whatever it does.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter closingLinkFailsInFlightTransfers`
Expected: FAIL — no `resourceFailed` delegate is ever received; the `store.receive` times out.

- [ ] **Step 3: Add the helper**

After `cancelPending` (line 201-205) add:

```swift
            /// Fail every hosted transfer and clear them. Reference `Link.link_closed()` cancels
            /// both incoming and outgoing resources (RNS/Link.py:685-687). Without this the
            /// element removal in LinkPlane silently cancels the child effects and no terminal
            /// delegate ever reaches the caller.
            func failTransfers(_ state: inout State) -> Effect<Action> {
                let hashes = state.transfers.map(\.resourceHash)
                state.transfers.removeAll()
                state.segmentedSend = nil
                state.incomingSegments.removeAll()
                return .merge(hashes.map { .send(.delegate(.resourceFailed($0))) })
            }
```

- [ ] **Step 4: Call it from all three close paths**

In `.close` (line 591-601), after `let pending = cancelPending(&state)` add `let failed = failTransfers(&state)`, and add `failed` to both `.merge(...)` return statements.

In `.staleDeadline` (added in Task 4), do the same.

In the peer-initiated LINKCLOSE branch (line 374-380), replace:

```swift
                    return .merge(.send(.delegate(.closed(reason))), cancelAll, cancelPending(&state))
```

with:

```swift
                    let pending = cancelPending(&state)
                    let failed = failTransfers(&state)
                    return .merge(.send(.delegate(.closed(reason))), cancelAll, pending, failed)
```

Bind the two `inout` calls to locals rather than nesting both in the `.merge` argument list — sequential `&state` accesses in one argument list are legal, but binding them separately keeps the exclusivity obvious and matches how `.close` already reads.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter LinkSession`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionResourceTests.swift
git commit -m "fix: surface resourceFailed for in-flight transfers when a link closes"
```

---

### Task 6: Start the large-request response timer when the upload concludes

**Why:** `LinkSession.swift:553-557` arms `requestDeadline` the moment a large request-Resource is *advertised*. The upload itself can legitimately take far longer than `rtt*6 + 11.25 s`, so `requestFailed` fires while the request is still transferring. Reference skips `started_at` for the resource case and starts the clock only in `request_resource_concluded` (`RNS/Link.py:1331-1333, 1368`).

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift:540-558` (large-request branch) and the transfer-concluded handler around `:693-760`
- Test: `Tests/ReTiCATransportTests/LinkSessionRequestTests.swift`

**Interfaces:**
- Consumes: `State.pendingRequests`, `CancelID.request(Data)`, `ResourceTransfer.State.requestID`.
- Produces: no new public symbols.

- [ ] **Step 1: Write the failing test**

```swift
// A large request must not time out while it is still uploading. Reference starts the
// response clock only once the request-Resource concludes (RNS/Link.py:1368).
@Test @MainActor func largeRequestTimerStartsAfterUpload() async {
    let clock = testClock()
    let owner = Identity()
    let store = await activeInitiatorStore(owner: owner, clock: clock)
    let timeout = (store.state.rtt ?? 0.5) * 6 + 11.25

    // Payload well over requestMDU (431) forces the resource path.
    await store.send(.sendRequest(path: "/big", data: Data(repeating: 0x5A, count: 8192)))
    await store.receive { if case .transfer = $0 { return true }; return false }
    _ = await captureTransmit(store)                       // RESOURCE_ADV
    #expect(store.state.pendingRequests.count == 1)

    // Advance well past the response timeout while the upload is still in flight.
    await clock.advance(by: .seconds(timeout * 3))
    #expect(store.state.pendingRequests.count == 1)        // must NOT have failed yet

    store.exhaustivity = .on
    await store.send(.close)
    _ = await captureTransmit(store)
    await store.receive { if case .delegate(.resourceFailed) = $0 { return true }; return false }
    await store.receive { if case .delegate(.closed) = $0 { return true }; return false }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter largeRequestTimerStartsAfterUpload`
Expected: FAIL — `requestDeadline` fires during the advance, `pendingRequests` empties, and an unexpected `requestFailed` delegate arrives.

- [ ] **Step 3: Remove the premature timer**

In the large-request branch (lines 540-558), replace:

```swift
                    return .merge(
                        .send(.transfer(.element(id: newID, action: .advertise))),
                        .run { send in
                            try await clock.sleep(for: .seconds(timeout)); await send(.requestDeadline(requestID))
                        }.cancellable(id: CancelID.request(requestID), cancelInFlight: true))
```

with:

```swift
                    // No response timer yet: RNS/Link.py:1331-1333 skips `started_at` for a
                    // request sent as a Resource and starts the clock in
                    // `request_resource_concluded` (RNS/Link.py:1368). Arming it here would time
                    // out the request while it is still uploading.
                    return .send(.transfer(.element(id: newID, action: .advertise)))
```

- [ ] **Step 4: Arm it when the sender transfer concludes**

The `.concluded` handler is at `LinkSession.swift:727-757`. `.concluded` is the **sender-side** terminal (proof validated); a receiver's inbound request-resource completes via `.delegate(.received)` at `:695` instead. So `.concluded` with `isRequest == true` means precisely "our outbound request finished uploading" — the exact moment reference starts the clock.

Replace line 731:

```swift
                if adv?.isRequest == true || adv?.isResponse == true { return .none }   // internal req/resp delivery
```

with:

```swift
                if adv?.isRequest == true {
                    // Our outbound REQUEST-resource finished uploading, so the response clock
                    // starts NOW. RNS/Link.py:1331-1333 deliberately skips `started_at` for the
                    // resource case and RNS/Link.py:1368 arms it in `request_resource_concluded`.
                    // Arming at advertise time (which is what we used to do) fails the request
                    // while it is still uploading, because the upload can far exceed rtt*6+11.25.
                    guard let rid = adv?.requestID, state.pendingRequests.contains(rid)
                    else { return .none }
                    let timeout = (state.rtt ?? 0.5) * 6 + 11.25
                    return .run { send in
                        try await clock.sleep(for: .seconds(timeout))
                        await send(.requestDeadline(rid))
                    }.cancellable(id: CancelID.request(rid), cancelInFlight: true)
                }
                if adv?.isResponse == true { return .none }   // internal response delivery
```

`adv` is already bound at line 728 and `ResourceAdvertisement.requestID` is already read elsewhere in this file (`:402`, `:411`), so no access changes are needed.

Note the interaction with Task 5: `failTransfers` clears `state.transfers` but does **not** clear `pendingRequests` — `cancelPending` does that, and both are called from every close path, so a request whose upload is killed by a close still gets its timer cancelled.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter LinkSession`
Expected: all pass, including the existing large-request round-trip in `LinkSessionRequestTests.swift`.

- [ ] **Step 6: Verify the test set per the three-step process**

(a) `swift test --filter LinkSession` — all pass.
(b) Batch-mutate: in Task 1's hoist change `guard state.status == .active` to `guard false`; in Task 2's gate change `guard quietInbound || quietOutbound` to `guard true`; in Task 3 drop the `lastOutbound` condition; in Task 4 make `.inactivityDeadline` set `.closed` again; in Task 5 make `failTransfers` return `.none`; in Task 6 re-add the premature timer. Run once — every new test must fail.
(c) Revert all mutations, run again — all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionRequestTests.swift
git commit -m "fix: start the large-request response timer at upload conclusion"
```

---

## Self-review notes

- **Coverage:** §1.1 → Tasks 1-4; §1.7 → Task 5; §1.8 → Task 6. RTT-derived keepalive intervals are explicitly **out of scope** (deferred with §5 of the gap analysis, because `rtt_packet` is peer-controllable — `LinkSession.swift:358-365` takes the peer's reported value verbatim where reference takes `max(measured, reported)`; that must be hardened before `rtt` drives teardown timing).
- **Type consistency:** `transmit(_ state: inout State, _ raw: Data) -> Effect<Action>` (Task 2) is used by Tasks 3-5. `failTransfers(_ state: inout State) -> Effect<Action>` (Task 5) is used by Task 4's `.staleDeadline` — Task 5 must therefore land after Task 4, or its Step 4 edit to `.staleDeadline` will have nothing to patch.
- **Ordering:** Tasks are strictly sequential. Task 1's hoist is the substrate for Task 4's STALE recovery; Task 2's `transmit` helper is the substrate for Tasks 3-5.
- **Known ripple:** Task 4 changes the observable teardown timeline, so existing tests at `LinkSessionTests.swift:501` and `:604` need updating. That is called out in Task 4 Step 6 rather than hidden.
