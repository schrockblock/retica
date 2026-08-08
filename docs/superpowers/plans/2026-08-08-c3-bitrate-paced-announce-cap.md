# C3 — Bitrate-Paced Announce Cap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Relayed announces consume at most `announceCap` (2%) of an interface's bandwidth — over-cap announces queue per interface and drain hop-count-first, per RNS `Transport.py:1277-1321` / `Interface.py:322-345`.

**Architecture:** A pure wait function (Task 1); per-interface `allowedAt` + queue with a drain timer wired into the C2 fan-out (Task 2); queue discipline — hop ordering, depth cap, lifetime GC (Task 3). Pacing applies to RELAY re-broadcast only, at the same fan-out C2 gated.

**Tech Stack:** Swift 6 / TCA / swift-testing. Repo: `/Users/ell/development/ios/pods/ReTiCA`.

## Global Constraints

- Commit directly to `main`. No branches, merges, rebases, resets.
- **You are the implementer, NOT the controller. Do NOT invoke the `superpowers:subagent-driven-development` skill or run its scripts** — a prior implementer that loaded it executed the skill's finish step and deleted the plan workspace. Follow only your dispatch.
- The user commits CONCURRENTLY. `git add` ONLY the files each task names.
- One command per Bash invocation — no `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, no inline interpreter scripts. Multi-step work = a script under `/tmp/ReTiCA/`.
- Commit trailers MUST start at column 0:
```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
```
- Mutation discipline every task. **Mutations must fail through DISJOINT observation points** (this project has twice had batched mutations mask each other via shared state). Each task's mutations are designed accordingly — apply them exactly, do not substitute.
- Baseline: 668/668 green. Classify any `PNNode*`/`LXMFNodeSync*`/`twoEndpointsTransferMultiSegment*` failure by isolated `--filter` re-run; report real numbers, never "pre-existing failures".
- Reference values, not negotiable: `announceCap` default 0.02 (fraction); `wait = (bytes × 8 / bitrate) / announceCap`; `MAX_QUEUED_ANNOUNCES = 16384`; `QUEUED_ANNOUNCE_LIFE = 86400 s`; queue ordered by hop count, then age.

## Scope decision (recorded)

C3 paces **relay re-broadcasts only** — the `announceRetransmitDue` fan-out. Locally-originated announces (`case .announce`) and path requests stay immediate and unpaced, consistent with C2's gating scope: the cap exists to stop relay floods, and an app announcing its own destination expects immediate emission. This is a deliberate simplification against reference (which paces the outbound announce path more broadly); revisit if a real deployment shows local-announce floods. C2's pinning test `locallyOriginatedAnnounceStillFansOutToAccessPointInterfaces` must stay green as written.

---

### Task 1: Pure pacing arithmetic + constants

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (add beside `mayRelayAnnounce`, ≈:531-538)
- Test: `Tests/ReTiCATransportTests/TransportTests.swift` (add beside `mayRelayAnnounceMatchesReferenceTable`)

**Interfaces:**
- Consumes: nothing (pure).
- Produces: `Transport.announcePacingWait(byteCount:bitrate:announceCap:) -> TimeInterval`, `Transport.announceQueueLimit: Int`, `Transport.queuedAnnounceLife: TimeInterval`. Tasks 2–3 use these exact names.

- [ ] **Step 1: Write the failing test**

Expected numbers are derived from the reference formula independently of the implementation (hand-computed), so this is an oracle, not a tautology.

```swift
/// Pacing wait = transmit-time / announce_cap (RNS Transport.py:1282-1285). Values are
/// hand-derived from the reference formula: a 150-byte announce is 1200 bits; at BLE's
/// 80 kbps that is 0.015 s of air time, and at a 2% cap the interface must then stay quiet
/// for 0.015 / 0.02 = 0.75 s. The same announce on TCP's 10 Mbps costs 0.006 s — the 125×
/// spread that makes pacing matter on a slow radio and vanish on a socket.
@Test func announcePacingWaitMatchesReferenceFormula() {
    #expect(Transport.announcePacingWait(byteCount: 150, bitrate: 80_000, announceCap: 0.02)
            == 0.75)
    #expect(Transport.announcePacingWait(byteCount: 150, bitrate: 10_000_000, announceCap: 0.02)
            == 0.006)
    // Doubling the payload doubles the wait; doubling the cap halves it.
    #expect(Transport.announcePacingWait(byteCount: 300, bitrate: 80_000, announceCap: 0.02)
            == 1.5)
    #expect(Transport.announcePacingWait(byteCount: 150, bitrate: 80_000, announceCap: 0.04)
            == 0.375)
    // A full-rate cap (1.0) still yields exactly the air time.
    #expect(Transport.announcePacingWait(byteCount: 150, bitrate: 80_000, announceCap: 1.0)
            == 0.015)
}

/// Queue bounds are the reference constants (RNS Transport.py MAX_QUEUED_ANNOUNCES /
/// QUEUED_ANNOUNCE_LIFE).
@Test func announceQueueBoundsMatchReference() {
    #expect(Transport.announceQueueLimit == 16384)
    #expect(Transport.queuedAnnounceLife == 86_400)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter announcePacingWaitMatchesReferenceFormula`
Expected: FAIL to compile — `announcePacingWait` not defined.

- [ ] **Step 3: Implement**

In `Sources/ReTiCATransport/Transport.swift`, immediately after `mayRelayAnnounce`:

```swift
/// How long an interface must stay quiet after emitting a relayed announce of `byteCount`
/// bytes, so relayed announces consume at most `announceCap` of its bandwidth
/// (RNS Transport.py:1282-1285: tx_time = bits/bitrate; wait = tx_time / announce_cap).
/// `bitrate` is guaranteed > 0 and `announceCap` ∈ (0, 1] by `InterfaceProfile`'s
/// preconditions, so this needs no zero guard.
static func announcePacingWait(byteCount: Int, bitrate: Int,
                               announceCap: Double) -> TimeInterval {
    let txTime = (Double(byteCount) * 8.0) / Double(bitrate)
    return txTime / announceCap
}

/// RNS MAX_QUEUED_ANNOUNCES: per-interface cap on announces awaiting their pacing slot.
static let announceQueueLimit = 16384
/// RNS QUEUED_ANNOUNCE_LIFE: a queued announce older than this is dropped, seconds.
static let queuedAnnounceLife: TimeInterval = 86_400
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter TransportTests`
Expected: both new tests pass; suite otherwise unchanged.

- [ ] **Step 5: Mutation verification (batch — disjoint tests)**

Apply both at once: (1) in `announcePacingWait`, drop the `/ announceCap` (return `txTime`); (2) change `announceQueueLimit` to `1024`.
Run: `swift test --filter TransportTests`
Expected: `announcePacingWaitMatchesReferenceFormula` fails (mutation 1) AND `announceQueueBoundsMatchReference` fails (mutation 2) — separate tests, neither can mask the other. Revert both; re-run; pass.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCA/c3-task1-msg.txt` (subject `feat: announce pacing arithmetic + queue bounds (RNS announce cap)`), then:

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -F /tmp/ReTiCA/c3-task1-msg.txt
```

---

### Task 2: Pace the relay fan-out — send now or queue, with a drain timer

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (State ≈:30-72; Action ≈:99; CancelID :120; `interfaceDisconnected` ≈:150; fan-out ≈:429-449)
- Test: `Tests/ReTiCATransportTests/TransportTests.swift` (helper change + 4 new tests)

**Interfaces:**
- Consumes: `announcePacingWait(byteCount:bitrate:announceCap:)` (Task 1); `mayRelayAnnounce(to:arrivalMode:)` (C2); `InterfaceProfile.bitrate`/`.announceCap` (C1).
- Produces: `Transport.State.QueuedAnnounce` (`raw: Data`, `hops: UInt8`, `queuedAt: Date`), `State.announceAllowedAt: [InterfaceID: Date]`, `State.announceQueues: [InterfaceID: [QueuedAnnounce]]`, `Action.announceQueueDrainDue(InterfaceID)`. Task 3 refines the drain's selection and adds GC.

- [ ] **Step 1: The test-substrate change (do this first — it unblocks everything)**

Pacing compares `date.now` against a per-interface `allowedAt`. Transport's `\.transportDate` `testValue` is FROZEN at epoch 0, while the relay tests advance a `TestClock`. Left alone, every second announce would queue forever and ~16 existing tests would fail for a reason that has nothing to do with pacing.

Fix the substrate, not the tests: make the date TRACK the test clock. Add near the other private helpers in `Tests/ReTiCATransportTests/TransportTests.swift`:

```swift
/// A simulated wall clock that tracks a `TestClock`, so `clock.advance(by:)` remains the single
/// time control in relay tests. C3 pacing compares `date.now` against a per-interface
/// `allowedAt`; with the default frozen epoch-0 `transportDate`, every announce after the first
/// would queue forever. `TestClock.Instant.offset` is fileprivate, so elapsed time is recovered
/// via the public `Instant()` (offset .zero) + `duration(to:)`.
private func clockTrackingDate(_ clock: TestClock<Duration>) -> DateGenerator {
    DateGenerator {
        let elapsed = TestClock<Duration>.Instant().duration(to: clock.now)
        let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) * 1e-18
        return Date(timeIntervalSince1970: seconds)
    }
}
```

Then ADD one line to each of the two existing private relay-store helpers — `makeTimedRelayStore` (≈:1310) and `makeModedRelayStore` (≈:1435) — inside their `withDependencies` blocks:

```swift
$0.transportDate = clockTrackingDate(clock)
```

Do NOT remove their existing `$0.date = .constant(...)` line (it is vestigial for Transport, which reads `\.transportDate`, but other constructors may use `\.date` — leave it). This one-line-per-helper change covers all 16 existing call sites.

- [ ] **Step 2: Write the failing tests**

```swift
/// A slow interface relays the first announce immediately, then QUEUES the next one that
/// arrives inside its pacing window rather than transmitting it.
@Test @MainActor func secondAnnounceInsidePacingWindowIsQueuedNotSent() async {
    let clock = TestClock()
    let slow = InterfaceProfile(name: "slow", bitrate: 8_000, mode: .full)   // 1000 B/s
    let (a1, d1) = makeAnnouncePacket(hops: 2, emitted: 1000,
                                      randomPrefix: Data([1, 0, 0, 0, 0]))
    let (a2, d2) = makeAnnouncePacket(hops: 2, emitted: 2000,
                                      randomPrefix: Data([2, 0, 0, 0, 0]))
    let store = await makeModedRelayStore(Identity(), clock, interfaces: [
        (InterfaceID("i0"),    .default),      // arrival
        (InterfaceID("iSlow"), slow),
    ])
    await store.send(.received(InterfaceID("i0"), a1))
    await store.receive(.delegate(.pathLearned(destinationHash: d1, hops: 2)))
    await clock.advance(by: .seconds(0.25))                 // jitter → send #1 goes out
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.announceQueues[InterfaceID("iSlow")] == nil)   // nothing queued yet
    #expect(store.state.announceAllowedAt[InterfaceID("iSlow")] != nil)

    // A second announce arrives well inside the pacing window (183 B at 8 kbps / 0.02 ≈ 9 s).
    await store.send(.received(InterfaceID("i0"), a2))
    await store.receive(.delegate(.pathLearned(destinationHash: d2, hops: 2)))
    await clock.advance(by: .seconds(0.25))                 // its jitter elapses
    #expect(store.state.announceQueues[InterfaceID("iSlow")]?.count == 1)  // QUEUED, not sent
    await store.send(.stopMaintenance)                      // quiesce
}

/// A queued announce is transmitted when the pacing window expires — the drain timer fires
/// on its own, without another announce arriving.
@Test @MainActor func queuedAnnounceIsDrainedWhenPacingWindowExpires() async {
    let clock = TestClock()
    let slow = InterfaceProfile(name: "slow", bitrate: 8_000, mode: .full)
    let (a1, d1) = makeAnnouncePacket(hops: 2, emitted: 1000,
                                      randomPrefix: Data([1, 0, 0, 0, 0]))
    let (a2, d2) = makeAnnouncePacket(hops: 2, emitted: 2000,
                                      randomPrefix: Data([2, 0, 0, 0, 0]))
    let store = await makeModedRelayStore(Identity(), clock, interfaces: [
        (InterfaceID("i0"),    .default),
        (InterfaceID("iSlow"), slow),
    ])
    await store.send(.received(InterfaceID("i0"), a1))
    await store.receive(.delegate(.pathLearned(destinationHash: d1, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    await store.send(.received(InterfaceID("i0"), a2))
    await store.receive(.delegate(.pathLearned(destinationHash: d2, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    #expect(store.state.announceQueues[InterfaceID("iSlow")]?.count == 1)

    // Advance past the pacing window: the drain fires and emits the held announce.
    let drained = LockIsolated<Data?>(nil)
    await clock.advance(by: .seconds(12))
    await store.receive { action in
        if case let .delegate(.transmit(i, d)) = action, i == InterfaceID("iSlow") {
            drained.setValue(d); return true
        }
        return false
    }
    #expect(drained.value != nil)
    #expect(store.state.announceQueues[InterfaceID("iSlow")] == nil)   // queue emptied
    await store.send(.stopMaintenance)
}

/// A fast interface never queues: its pacing window is far shorter than the retransmit grace,
/// so back-to-back announces both go out immediately.
@Test @MainActor func fastInterfaceNeverQueuesAnnounces() async {
    let clock = TestClock()
    let (a1, d1) = makeAnnouncePacket(hops: 2, emitted: 1000,
                                      randomPrefix: Data([1, 0, 0, 0, 0]))
    let (a2, d2) = makeAnnouncePacket(hops: 2, emitted: 2000,
                                      randomPrefix: Data([2, 0, 0, 0, 0]))
    let store = await makeModedRelayStore(Identity(), clock, interfaces: [
        (InterfaceID("i0"),    .default),
        (InterfaceID("iFast"), .tcp),          // 10 Mbps → ~0.0001 s window
    ])
    await store.send(.received(InterfaceID("i0"), a1))
    await store.receive(.delegate(.pathLearned(destinationHash: d1, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    await store.send(.received(InterfaceID("i0"), a2))
    await store.receive(.delegate(.pathLearned(destinationHash: d2, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.announceQueues[InterfaceID("iFast")] == nil)   // never queued
    await store.send(.stopMaintenance)
}

/// Disconnecting an interface drops its pacing state and queued announces — no residue, and
/// no drain timer left running for an interface that is gone.
@Test @MainActor func disconnectClearsPacingStateAndQueue() async {
    let clock = TestClock()
    let slow = InterfaceProfile(name: "slow", bitrate: 8_000, mode: .full)
    let (a1, d1) = makeAnnouncePacket(hops: 2, emitted: 1000,
                                      randomPrefix: Data([1, 0, 0, 0, 0]))
    let (a2, d2) = makeAnnouncePacket(hops: 2, emitted: 2000,
                                      randomPrefix: Data([2, 0, 0, 0, 0]))
    let store = await makeModedRelayStore(Identity(), clock, interfaces: [
        (InterfaceID("i0"),    .default),
        (InterfaceID("iSlow"), slow),
    ])
    await store.send(.received(InterfaceID("i0"), a1))
    await store.receive(.delegate(.pathLearned(destinationHash: d1, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    await store.send(.received(InterfaceID("i0"), a2))
    await store.receive(.delegate(.pathLearned(destinationHash: d2, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    #expect(store.state.announceQueues[InterfaceID("iSlow")]?.count == 1)

    await store.send(.interfaceDisconnected(InterfaceID("iSlow")))
    #expect(store.state.announceQueues[InterfaceID("iSlow")] == nil)
    #expect(store.state.announceAllowedAt[InterfaceID("iSlow")] == nil)
    await store.send(.stopMaintenance)
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --filter TransportTests`
Expected: the four new tests FAIL to compile (`announceQueues`/`announceAllowedAt` undefined). The 16 existing relay tests must still PASS after Step 1's substrate change — if any regressed, the `clockTrackingDate` helper is wrong; fix it before continuing.

- [ ] **Step 4: Implement**

**State** — add beside `announceTable` (≈:71):

```swift
/// An announce held for an interface until its pacing window opens (RNS announce_queue).
public struct QueuedAnnounce: Equatable, Sendable {
    public var raw: Data
    public var hops: UInt8
    public var queuedAt: Date
    public init(raw: Data, hops: UInt8, queuedAt: Date) {
        self.raw = raw; self.hops = hops; self.queuedAt = queuedAt
    }
}
/// Earliest time each interface may emit its next RELAYED announce (RNS announce_allowed_at).
public var announceAllowedAt: [InterfaceID: Date] = [:]
/// Per-interface announces awaiting their pacing slot (RNS announce_queue).
public var announceQueues: [InterfaceID: [QueuedAnnounce]] = [:]
```

**Action** — add beside `announceRetransmitDue` (≈:99):

```swift
case announceQueueDrainDue(InterfaceID)
```

**CancelID** (:120) becomes:

```swift
private enum CancelID: Hashable {
    case announceRetransmit(Data); case maintenance; case announceDrain(InterfaceID)
}
```

**`interfaceDisconnected`** (≈:150) becomes:

```swift
case let .interfaceDisconnected(id):
    state.interfaces[id] = nil
    state.announceAllowedAt[id] = nil
    state.announceQueues[id] = nil
    return .cancel(id: CancelID.announceDrain(id))
```

**Fan-out** — replace the `sends` construction in `announceRetransmitDue` (≈:431-435). The eligibility filter is C2's, unchanged; each eligible interface now either transmits now or queues:

```swift
let arrivalMode = state.interfaces[entry.arrivalInterface]?.mode
let now = date.now
let eligible = state.interfaces
    .filter { $0.key != entry.arrivalInterface
        && Transport.mayRelayAnnounce(to: $0.value.mode, arrivalMode: arrivalMode) }
var sends: [Effect<Action>] = []
for (id, profile) in eligible {
    let wait = Transport.announcePacingWait(byteCount: entry.raw.count,
                                            bitrate: profile.bitrate,
                                            announceCap: profile.announceCap)
    if (state.announceAllowedAt[id] ?? .distantPast) <= now {
        sends.append(.send(.delegate(.transmit(id, entry.raw))))
        state.announceAllowedAt[id] = now.addingTimeInterval(wait)
    } else {
        state.announceQueues[id, default: []].append(
            State.QueuedAnnounce(raw: entry.raw, hops: entry.rebroadcastHops, queuedAt: now))
        let opensIn = max(0, state.announceAllowedAt[id]!.timeIntervalSince(now))
        sends.append(.run { send in
            try await clock.sleep(for: .seconds(opensIn))
            await send(.announceQueueDrainDue(id))
        }.cancellable(id: CancelID.announceDrain(id), cancelInFlight: true))
    }
}
```

The rest of the case (the `rebroadcasts` increment, the cap check, the retry effect) is UNCHANGED — `sends` still feeds both `return` paths.

**Drain handler** — add immediately after the `announceRetransmitDue` case:

```swift
case let .announceQueueDrainDue(id):
    guard let profile = state.interfaces[id] else {
        state.announceQueues[id] = nil        // interface vanished; drop its backlog
        return .none
    }
    guard var queue = state.announceQueues[id], !queue.isEmpty else { return .none }
    let item = queue.removeFirst()            // Task 3 refines the selection order
    state.announceQueues[id] = queue.isEmpty ? nil : queue
    let now = date.now
    let wait = Transport.announcePacingWait(byteCount: item.raw.count,
                                            bitrate: profile.bitrate,
                                            announceCap: profile.announceCap)
    state.announceAllowedAt[id] = now.addingTimeInterval(wait)
    var effects: [Effect<Action>] = [.send(.delegate(.transmit(id, item.raw)))]
    if !queue.isEmpty {
        effects.append(.run { send in
            try await clock.sleep(for: .seconds(wait))
            await send(.announceQueueDrainDue(id))
        }.cancellable(id: CancelID.announceDrain(id), cancelInFlight: true))
    }
    return .merge(effects)
```

- [ ] **Step 5: Run to verify all pass**

Run: `swift test --filter TransportTests`
Expected: the four new tests pass and every pre-existing relay test still passes.

- [ ] **Step 6: Full suite**

Run: `swift test`
Expected: 674/674 (668 + 2 from Task 1 + 4 here).

- [ ] **Step 7: Mutation verification (batch — disjoint observation points)**

Apply both at once:
1. In the fan-out, always take the send branch (delete the `else` and its queueing, transmitting unconditionally). Observed via QUEUE STATE: `secondAnnounceInsidePacingWindowIsQueuedNotSent` fails (`announceQueues[iSlow]` is nil, not 1).
2. In `interfaceDisconnected`, drop the two clearing lines (keep `state.interfaces[id] = nil` and the cancel). Observed via POST-DISCONNECT STATE: `disconnectClearsPacingStateAndQueue` fails on the residue assertions.
Mutation 1 cannot mask 2 (the disconnect test asserts state AFTER an explicit disconnect, and under mutation 1 its queue would be empty — so it fails on `announceAllowedAt` residue instead, still failing). Mutation 2 cannot mask 1 (no disconnect occurs in the queueing test).
Report both failures verbatim, labelled. Also confirm `fastInterfaceNeverQueuesAnnounces` and the pre-existing relay suite stay green under both — if a pre-existing test fails, the mutation was mis-applied. Revert; re-run; green.

- [ ] **Step 8: Commit**

Write `/tmp/ReTiCA/c3-task2-msg.txt` (subject `feat: pace relayed announces per interface with a drain queue`), then:

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -F /tmp/ReTiCA/c3-task2-msg.txt
```

---

### Task 3: Queue discipline — hop ordering, depth cap, lifetime GC

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (drain selection; enqueue cap; `maintenanceTick` ≈:408-427)
- Test: `Tests/ReTiCATransportTests/TransportTests.swift` (3 new tests)

**Interfaces:**
- Consumes: everything from Tasks 1–2.
- Produces: nothing downstream (C3 complete).

- [ ] **Step 1: Write the failing tests**

The first two drive the reducer directly through seeded state rather than the full announce lifecycle — the behaviours under test are queue disciplines, and seeding keeps them focused.

```swift
/// The drain emits the FEWEST-HOP announce first, then the older of equal-hop entries
/// (RNS orders the announce queue by hops, then timestamp).
@Test @MainActor func drainEmitsFewestHopAnnounceFirst() async {
    var initial = Transport.State()
    let id = InterfaceID("i0")
    initial.interfaces[id] = .default
    initial.announceQueues[id] = [
        .init(raw: Data("far".utf8),   hops: 5, queuedAt: Date(timeIntervalSince1970: 10)),
        .init(raw: Data("near".utf8),  hops: 1, queuedAt: Date(timeIntervalSince1970: 30)),
        .init(raw: Data("near2".utf8), hops: 1, queuedAt: Date(timeIntervalSince1970: 20)),
    ]
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    let out = LockIsolated<Data?>(nil)
    await store.send(.announceQueueDrainDue(id))
    await store.receive { action in
        if case let .delegate(.transmit(_, d)) = action { out.setValue(d); return true }
        return false
    }
    // hops 1 beats hops 5; between the two hops-1 entries the OLDER (t=20) wins.
    #expect(out.value == Data("near2".utf8))
    #expect(store.state.announceQueues[id]?.count == 2)
}

/// A full queue drops further announces rather than growing without bound.
@Test @MainActor func announceQueueDropsWhenAtCapacity() async {
    var initial = Transport.State()
    let id = InterfaceID("iSlow")
    initial.interfaces[id] = InterfaceProfile(name: "slow", bitrate: 8_000, mode: .full)
    initial.interfaces[InterfaceID("i0")] = .default
    initial.transportIdentity = Identity()
    // Saturate the queue and close the pacing window so the next announce must queue.
    initial.announceQueues[id] = Array(
        repeating: .init(raw: Data([0xAA]), hops: 3,
                         queuedAt: Date(timeIntervalSince1970: 0)),
        count: Transport.announceQueueLimit)
    initial.announceAllowedAt[id] = Date(timeIntervalSince1970: 9_999)
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
        $0.transportDate = DateGenerator { Date(timeIntervalSince1970: 0) }
        $0.randomBytes = RandomBytesGenerator { _ in Data([0]) }
    }
    store.exhaustivity = .off
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await store.receive(.announceRetransmitDue(destinationHash: destHash))
    #expect(store.state.announceQueues[id]?.count == Transport.announceQueueLimit)  // no growth
}

/// maintenanceTick drops queued announces older than QUEUED_ANNOUNCE_LIFE and removes the
/// queue entry entirely once empty.
@Test @MainActor func maintenanceTickExpiresStaleQueuedAnnounces() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    var initial = Transport.State()
    let id = InterfaceID("i0")
    initial.interfaces[id] = .default
    initial.announceQueues[id] = [
        .init(raw: Data("old".utf8),   hops: 1, queuedAt: Date(timeIntervalSince1970: 0)),
        .init(raw: Data("fresh".utf8), hops: 1, queuedAt: Date(timeIntervalSince1970: 80_000)),
    ]
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    await store.send(.startMaintenance)
    now.setValue(Date(timeIntervalSince1970: Transport.queuedAnnounceLife + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.announceQueues[id]?.count == 1)          // only "old" expired
    // Push past the fresh one's lifetime too: the queue entry disappears entirely.
    now.setValue(Date(timeIntervalSince1970: 80_000 + Transport.queuedAnnounceLife + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.announceQueues[id] == nil)
    await store.send(.stopMaintenance)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TransportTests`
Expected: `drainEmitsFewestHopAnnounceFirst` fails (FIFO emits "far"), `announceQueueDropsWhenAtCapacity` fails (count grows past the limit), `maintenanceTickExpiresStaleQueuedAnnounces` fails (nothing expires).

- [ ] **Step 3: Implement**

**Drain selection** — in `announceQueueDrainDue`, replace `let item = queue.removeFirst()` with:

```swift
// Fewest hops first, older first among equals (RNS orders by hops, then timestamp).
let pick = queue.indices.min { a, b in
    queue[a].hops != queue[b].hops ? queue[a].hops < queue[b].hops
                                   : queue[a].queuedAt < queue[b].queuedAt
}!
let item = queue.remove(at: pick)
```

**Enqueue cap** — in the fan-out's `else` branch, guard before appending:

```swift
} else {
    if state.announceQueues[id, default: []].count < Transport.announceQueueLimit {
        state.announceQueues[id, default: []].append(
            State.QueuedAnnounce(raw: entry.raw, hops: entry.rebroadcastHops, queuedAt: now))
    }
    let opensIn = max(0, state.announceAllowedAt[id]!.timeIntervalSince(now))
    ...
```
(the drain-scheduling effect stays outside the `if`, so a full queue still gets drained.)

**Lifetime GC** — in `maintenanceTick`, after the existing `discoveryPathRequests` loop (≈:420-423):

```swift
for (id, queue) in state.announceQueues {
    let live = queue.filter { now.timeIntervalSince($0.queuedAt) <= Transport.queuedAnnounceLife }
    state.announceQueues[id] = live.isEmpty ? nil : live
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter TransportTests`
Expected: all pass.

- [ ] **Step 5: Full suite**

Run: `swift test`
Expected: 677/677 (674 + 3).

- [ ] **Step 6: Mutation verification (batch — three disjoint tests)**

Apply all three at once:
1. Drain selection: revert to `queue.removeFirst()` → `drainEmitsFewestHopAnnounceFirst` fails (emits "far").
2. Enqueue cap: remove the `< announceQueueLimit` guard → `announceQueueDropsWhenAtCapacity` fails (count = limit + 1).
3. GC: change the filter's `<=` to `>=` → `maintenanceTickExpiresStaleQueuedAnnounces` fails (the wrong entry survives).
Each is asserted by a different test with no shared state between them. Report each failure verbatim, labelled. Revert all; re-run; green.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/c3-task3-msg.txt` (subject `feat: announce queue discipline — hop ordering, depth cap, lifetime GC`), then:

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -F /tmp/ReTiCA/c3-task3-msg.txt
```

---

## Final verification (after Task 3)

- [ ] `swift test` — full suite green; report the exact count (expected 677).
- [ ] `grep -n "announcePacingWait" Sources/ReTiCATransport/Transport.swift` — exactly 3 hits: definition + fan-out + drain.
- [ ] Confirm by reading `case .announce` and `case .requestPath` that neither gained pacing (the recorded scope decision).
- [ ] `grep -n "announceDrain" Sources/ReTiCATransport/Transport.swift` — the CancelID case, the disconnect cancel, and the two schedule sites.
- [ ] `git log --format='%(trailers:key=Claude-Session)' -3` — all three task commits' trailers parse.
- [ ] `git diff <plan-base> HEAD --stat` — only `Transport.swift` and `TransportTests.swift` (plus this plan file).
