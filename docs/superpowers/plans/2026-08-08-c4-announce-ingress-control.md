# C4 — Announce Ingress Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Under an announce burst, an interface stops admitting announces for *unknown* destinations and holds them instead, releasing one at a time as the rate subsides — RNS `Interface.py:152-255` + `Transport.py:1748-1766`.

**Architecture:** Pure frequency + burst-decision primitives (Task 1); receive-side gate that holds instead of admitting (Task 2); the release timer that re-injects held announces (Task 3). Receive-side and disjoint from C3's egress pacing state.

**Tech Stack:** Swift 6 / TCA / swift-testing. Repo: `/Users/ell/development/ios/pods/ReTiCA`.

## Global Constraints

- Commit directly to `main`. No branches, merges, rebases, resets.
- **You are the implementer, NOT the controller. Do NOT invoke the `superpowers:subagent-driven-development` skill or run any of its scripts** — an implementer that loaded it executed the skill's finish step and deleted a plan workspace. Follow only your dispatch.
- The user commits CONCURRENTLY. `git add` ONLY the files each task names — never `-A`, never `.`.
- One command per Bash invocation — no `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, no inline interpreter scripts. Multi-step work = a script under `/tmp/ReTiCA/`.
- Commit trailers MUST start at column 0:
```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
```
- Mutation discipline every task, **mutations failing through DISJOINT observation points** (this project has had batched mutations mask each other twice). Each task's mutations are specified — apply them exactly.
- Baseline: 679/679 green. Classify any `PNNode*`/`LXMFNodeSync*`/`twoEndpointsTransferMultiSegment*` failure by isolated `--filter` re-run; report real numbers, never "pre-existing failures".
- GOTCHA: after editing `Transport.swift`, incremental builds can stale-link into a spurious SIGABRT in `LXMFNodeSyncTests`. Run `swift package clean` once and re-run; report if it happens.
- Reference constants, verbatim from `Interface.py:58-92` — not negotiable:
  `IA_FREQ_SAMPLES = 48`, `AR_FREQ_DECAY = 10` (= 1/AR_MINFREQ_HZ, 0.1 Hz), `MAX_HELD_ANNOUNCES = 256`, `IC_NEW_TIME = 7200`, `IC_BURST_FREQ_NEW = 3`, `IC_BURST_FREQ = 10`, `IC_BURST_HOLD = 15`, `IC_BURST_PENALTY = 15`, `IC_HELD_RELEASE_INTERVAL = 5`, `IC_DEQUE_MIN_SAMPLE = 2`, `PATHFINDER_M = 128` (hold drops at `hops >= 127`).

## The gate is narrower than "limit announces" — read this before Task 2

`Transport.py:1748-1766` applies ingress limiting **only** to announces for destinations we do NOT already have a path to, and **skips** it when a path request for that destination is outstanding:

```python
elif interface != None: interface.received_announce()          # deque updated for EVERY valid announce
announced_destination_known = packet.destination_hash in Transport.path_table
if not announced_destination_known:
    if packet.destination_hash in Transport.path_requests or packet.destination_hash in Transport.discovery_path_requests:
        pass                                                   # we asked for this — never hold it
    elif interface.should_ingress_limit():
        interface.hold_announce(packet)
        return
```

So: known destination → never held (normal announce rate limiting governs it). Unknown + we're waiting on it → never held. Unknown + burst active → held. The frequency deque is updated for every signature-valid announce regardless, and *before* the decision, so the current announce counts toward its own threshold check.

**Placement in ReTiCA is load-bearing.** The gate goes AFTER `Announce.parse` succeeds (`Transport.swift:241`) and BEFORE the blob-ring insert (`Transport.swift:249`). Holding after the ring insert would make the later re-injection look like a replay and it would be dropped — reference avoids this by returning before its own blob dedup.

## Scope decisions (recorded)

- **Path-request ingress limiting (`should_ingress_limit_pr`, `Transport.py:3001-3005, 3115`) is OUT of scope** — announces only. C4's sibling PR-limiting is a separate concern with its own burst state.
- **`ingress_control` is always on.** Reference exposes it as an interface config flag; ReTiCA has no config surface for it and no caller needs it off. Do not add a knob.
- **Interface age** drives the 3 Hz vs 10 Hz threshold, so C4 records `connectedAt` per interface. A node younger than 2 h uses the stricter 3 Hz — which for a phone is essentially always.

---

### Task 1: Pure frequency + burst-decision primitives

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (constants near `announceQueueLimit`; functions near `announcePacingWait`)
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`

**Interfaces:**
- Consumes: nothing (pure).
- Produces: `Transport.IngressBurst` (struct: `active: Bool`, `activatedAt: Date`, `heldRelease: Date`), `Transport.announceFrequency(samples:now:) -> Double`, `Transport.ingressBurstThreshold(interfaceAge:) -> Double`, `Transport.shouldIngressLimit(samples:now:interfaceAge:burst:) -> (limit: Bool, burst: IngressBurst)`, and the constants. Tasks 2–3 use these exact names.

- [ ] **Step 1: Write the failing tests**

```swift
/// Ingress constants are the reference values (RNS Interface.py:58-92).
@Test func ingressControlConstantsMatchReference() {
    #expect(Transport.iaFreqSamples == 48)
    #expect(Transport.arFreqDecay == 10)
    #expect(Transport.maxHeldAnnounces == 256)
    #expect(Transport.icNewTime == 7200)
    #expect(Transport.icBurstFreqNew == 3)
    #expect(Transport.icBurstFreq == 10)
    #expect(Transport.icBurstHold == 15)
    #expect(Transport.icBurstPenalty == 15)
    #expect(Transport.icHeldReleaseInterval == 5)
    #expect(Transport.icDequeMinSample == 2)
}

/// Frequency is samples/span, and is 0 until MORE THAN icDequeMinSample samples exist
/// (RNS `if not n > IC_DEQUE_MIN_SAMPLE: return 0`, Interface.py:277-278) — so 2 samples
/// still yields 0 and cannot trip a burst.
@Test func announceFrequencyNeedsMoreThanMinimumSamples() {
    let t0 = Date(timeIntervalSince1970: 100)
    #expect(Transport.announceFrequency(samples: [], now: t0) == 0)
    #expect(Transport.announceFrequency(samples: [t0, t0], now: t0.addingTimeInterval(1)) == 0)
    // 3 samples spanning 1 s → 3 Hz.
    let s = [t0, t0.addingTimeInterval(0.5), t0.addingTimeInterval(0.9)]
    #expect(Transport.announceFrequency(samples: s, now: t0.addingTimeInterval(1)) == 3.0)
}

/// A non-positive span yields 0 rather than dividing by zero (Interface.py:281).
@Test func announceFrequencyGuardsNonPositiveSpan() {
    let t0 = Date(timeIntervalSince1970: 100)
    #expect(Transport.announceFrequency(samples: [t0, t0, t0], now: t0) == 0)
}

/// A young interface is held to the stricter threshold (RNS ic_burst_freq_new for
/// age < IC_NEW_TIME, Interface.py:154).
@Test func burstThresholdIsStricterForYoungInterfaces() {
    #expect(Transport.ingressBurstThreshold(interfaceAge: 60) == 3)
    #expect(Transport.ingressBurstThreshold(interfaceAge: 7199) == 3)
    #expect(Transport.ingressBurstThreshold(interfaceAge: 7200) == 10)
    #expect(Transport.ingressBurstThreshold(interfaceAge: 100_000) == 10)
}

/// Crossing the threshold activates the burst, stamps activatedAt, and pushes heldRelease
/// out by the penalty (Interface.py:163-168).
@Test func exceedingThresholdActivatesBurstAndSetsPenalty() {
    let t0 = Date(timeIntervalSince1970: 1000)
    // 5 samples over 1 s = 5 Hz > 3 Hz young threshold.
    let s = (0..<5).map { t0.addingTimeInterval(Double($0) * 0.2) }
    let idle = Transport.IngressBurst()
    let r = Transport.shouldIngressLimit(samples: s, now: t0.addingTimeInterval(1),
                                         interfaceAge: 60, burst: idle)
    #expect(r.limit == true)
    #expect(r.burst.active == true)
    #expect(r.burst.activatedAt == t0.addingTimeInterval(1))
    #expect(r.burst.heldRelease == t0.addingTimeInterval(1 + Transport.icBurstPenalty))
}

/// Below the threshold with no active burst, nothing is limited and no state changes.
@Test func belowThresholdDoesNotLimit() {
    let t0 = Date(timeIntervalSince1970: 1000)
    let s = (0..<3).map { t0.addingTimeInterval(Double($0) * 5) }   // 3 samples / 10 s = 0.3 Hz
    let idle = Transport.IngressBurst()
    let r = Transport.shouldIngressLimit(samples: s, now: t0.addingTimeInterval(10),
                                         interfaceAge: 60, burst: idle)
    #expect(r.limit == false)
    #expect(r.burst.active == false)
}

/// An active burst keeps limiting until BOTH the rate has fallen below the threshold AND
/// icBurstHold has elapsed since activation. Crucially, the call that DEACTIVATES still
/// returns limit == true (RNS returns True on that path, Interface.py:157-161) — the
/// announce that ends the burst is itself still held.
@Test func activeBurstDeactivatesOnlyAfterHoldElapsesAndStillLimitsThatCall() {
    let t0 = Date(timeIntervalSince1970: 1000)
    let quiet = [t0, t0.addingTimeInterval(4), t0.addingTimeInterval(8)]   // 3/9 s = 0.33 Hz
    let active = Transport.IngressBurst(active: true, activatedAt: t0,
                                        heldRelease: t0.addingTimeInterval(15))
    // Rate is low but the hold window has NOT elapsed → stays active.
    let early = Transport.shouldIngressLimit(samples: quiet, now: t0.addingTimeInterval(9),
                                             interfaceAge: 60, burst: active)
    #expect(early.limit == true)
    #expect(early.burst.active == true)
    // Past the hold window with a low rate → deactivates, but THIS call still limits.
    let late = Transport.shouldIngressLimit(samples: quiet, now: t0.addingTimeInterval(16),
                                            interfaceAge: 60, burst: active)
    #expect(late.limit == true)
    #expect(late.burst.active == false)
}

/// A still-hot rate keeps an active burst active past the hold window.
@Test func activeBurstStaysActiveWhileRateRemainsHigh() {
    let t0 = Date(timeIntervalSince1970: 1000)
    let hot = (0..<10).map { t0.addingTimeInterval(Double($0) * 0.1) }    // 10/1 s = 10 Hz
    let active = Transport.IngressBurst(active: true, activatedAt: t0,
                                        heldRelease: t0.addingTimeInterval(15))
    let r = Transport.shouldIngressLimit(samples: hot, now: t0.addingTimeInterval(20),
                                         interfaceAge: 60, burst: active)
    #expect(r.limit == true)
    #expect(r.burst.active == true)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ingressControlConstantsMatchReference`
Expected: FAIL to compile — none of the symbols exist.

- [ ] **Step 3: Implement**

In `Sources/ReTiCATransport/Transport.swift`, beside the other announce constants:

```swift
// MARK: - C4 ingress control (RNS Interface.py:58-92, 152-255)

/// Rolling window of announce arrival times used for the rate estimate (RNS IA_FREQ_SAMPLES).
static let iaFreqSamples = 48
/// Samples older than this decay out of the window (RNS AR_FREQ_DECAY = 1/AR_MINFREQ_HZ).
static let arFreqDecay: TimeInterval = 10
/// Per-interface cap on held announces (RNS MAX_HELD_ANNOUNCES).
static let maxHeldAnnounces = 256
/// Interfaces younger than this use the stricter burst threshold (RNS IC_NEW_TIME).
static let icNewTime: TimeInterval = 7200
/// Burst thresholds in Hz for young / established interfaces (RNS IC_BURST_FREQ_NEW / IC_BURST_FREQ).
static let icBurstFreqNew: Double = 3
static let icBurstFreq: Double = 10
/// Minimum time a burst stays active once triggered (RNS IC_BURST_HOLD), seconds.
static let icBurstHold: TimeInterval = 15
/// Delay before the first held announce may be released (RNS IC_BURST_PENALTY), seconds.
static let icBurstPenalty: TimeInterval = 15
/// Spacing between held-announce releases (RNS IC_HELD_RELEASE_INTERVAL), seconds.
static let icHeldReleaseInterval: TimeInterval = 5
/// The rate estimate needs MORE than this many samples to be meaningful (RNS IC_DEQUE_MIN_SAMPLE).
static let icDequeMinSample = 2
/// RNS PATHFINDER_M: an announce at or past `maxHops - 1` is never held (it is dropped).
static let ingressHoldHopLimit = Int(Packet.maxHops) - 1

/// Per-interface announce burst state (RNS ic_burst_active / ic_burst_activated / ic_held_release).
public struct IngressBurst: Equatable, Sendable {
    public var active: Bool
    public var activatedAt: Date
    public var heldRelease: Date
    public init(active: Bool = false,
                activatedAt: Date = .distantPast,
                heldRelease: Date = .distantPast) {
        self.active = active
        self.activatedAt = activatedAt
        self.heldRelease = heldRelease
    }
}

/// Announce arrival rate in Hz over the sample window (RNS incoming_announce_frequency,
/// Interface.py:276-285). Returns 0 until more than `icDequeMinSample` samples exist, and
/// on a non-positive span.
static func announceFrequency(samples: [Date], now: Date) -> Double {
    let n = samples.count
    guard n > icDequeMinSample, let oldest = samples.first else { return 0 }
    let span = now.timeIntervalSince(oldest)
    guard span > 0 else { return 0 }
    return Double(n) / span
}

/// Burst threshold for an interface of the given age (RNS Interface.py:154).
static func ingressBurstThreshold(interfaceAge: TimeInterval) -> Double {
    interfaceAge < icNewTime ? icBurstFreqNew : icBurstFreq
}

/// Whether this announce should be held, plus the updated burst state
/// (RNS should_ingress_limit, Interface.py:152-172).
///
/// Note the asymmetry, faithful to reference: the call that DEACTIVATES a burst still
/// returns `limit == true`, so the announce that ends a burst is itself held.
static func shouldIngressLimit(samples: [Date], now: Date, interfaceAge: TimeInterval,
                               burst: IngressBurst) -> (limit: Bool, burst: IngressBurst) {
    let threshold = ingressBurstThreshold(interfaceAge: interfaceAge)
    let freq = announceFrequency(samples: samples, now: now)
    var next = burst
    if burst.active {
        if freq < threshold, now > burst.activatedAt.addingTimeInterval(icBurstHold),
           samples.count >= icDequeMinSample {
            next.active = false
        }
        return (true, next)
    }
    if freq > threshold {
        next.active = true
        next.activatedAt = now
        next.heldRelease = now.addingTimeInterval(icBurstPenalty)
        return (true, next)
    }
    return (false, next)
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter TransportTests`
Expected: the 7 new tests pass; nothing else changes.

- [ ] **Step 5: Mutation verification (batch — four disjoint tests)**

Apply all at once: (1) `icBurstFreqNew` → `10`; (2) in `announceFrequency`, change `n > icDequeMinSample` to `n >= icDequeMinSample`; (3) in `shouldIngressLimit`'s deactivation branch, `return (false, next)` instead of `(true, next)`.
Run: `swift test --filter TransportTests`
Expected: (1) fails `ingressControlConstantsMatchReference` AND `burstThresholdIsStricterForYoungInterfaces`; (2) fails `announceFrequencyNeedsMoreThanMinimumSamples`; (3) fails `activeBurstDeactivatesOnlyAfterHoldElapsesAndStillLimitsThatCall`. Different tests each — none can mask another. Revert; re-run; pass.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCA/c4-task1-msg.txt` (subject `feat: announce ingress-control primitives (burst detection)`), then:

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -F /tmp/ReTiCA/c4-task1-msg.txt
```

---

### Task 2: Receive-side gate — track arrivals and hold instead of admitting

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (State; `interfaceConnected`/`interfaceDisconnected`; the `.announce` receive path between `Transport.swift:241` and `:249`)
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`

**Interfaces:**
- Consumes: Task 1's primitives and constants.
- Produces: `State.HeldAnnounce` (`raw: Data`, `hops: UInt8`), `State.announceArrivals: [InterfaceID: [Date]]`, `State.ingressBursts: [InterfaceID: IngressBurst]`, `State.heldAnnounces: [InterfaceID: [Data: HeldAnnounce]]`, `State.interfaceConnectedAt: [InterfaceID: Date]`. Task 3 drains `heldAnnounces`.

- [ ] **Step 1: Write the failing tests**

```swift
/// Under a burst, an announce for an UNKNOWN destination is held rather than admitted:
/// no path is learned and no blob is recorded, so the later release is not a replay.
@Test @MainActor func burstHoldsAnnounceForUnknownDestination() async {
    let now = LockIsolated(Date(timeIntervalSince1970: 1000))
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    let i0 = InterfaceID("i0")
    await store.send(.interfaceConnected(i0, .default))
    // Drive the arrival rate over the 3 Hz young-interface threshold with distinct announces.
    for k in 0..<6 {
        now.setValue(Date(timeIntervalSince1970: 1000 + Double(k) * 0.1))
        let (raw, _) = makeAnnouncePacket(hops: 2, emitted: UInt64(1000 + k),
                                          randomPrefix: Data([UInt8(k + 1), 0, 0, 0, 0]))
        await store.send(.received(i0, raw))
    }
    #expect(store.state.ingressBursts[i0]?.active == true)
    #expect((store.state.heldAnnounces[i0]?.count ?? 0) > 0)
    // A held announce must not have been admitted: no path, and its blob is unrecorded.
    let heldDest = store.state.heldAnnounces[i0]!.keys.first!
    #expect(store.state.learned[heldDest] == nil)
    #expect(store.state.announceBlobs[heldDest] == nil)
}

/// An announce for a destination we ALREADY have a path to is never held, even mid-burst
/// (RNS limits only unknown destinations — known ones are governed by announce rate limiting).
@Test @MainActor func burstDoesNotHoldAnnounceForKnownDestination() async {
    let now = LockIsolated(Date(timeIntervalSince1970: 1000))
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    let i0 = InterfaceID("i0")
    await store.send(.interfaceConnected(i0, .default))
    // Learn a path for this identity BEFORE the burst.
    let known = Identity()
    let (first, knownDest) = makeAnnouncePacket(identity: known, appName: "app", aspects: ["s"],
                                                hops: 2, emitted: 1,
                                                randomPrefix: Data([9, 0, 0, 0, 0]))
    await store.send(.received(i0, first))
    #expect(store.state.learned[knownDest] != nil)
    // Now drive a burst with OTHER destinations.
    for k in 0..<6 {
        now.setValue(Date(timeIntervalSince1970: 1000 + Double(k) * 0.1))
        let (raw, _) = makeAnnouncePacket(hops: 2, emitted: UInt64(2000 + k),
                                          randomPrefix: Data([UInt8(k + 1), 0, 0, 0, 0]))
        await store.send(.received(i0, raw))
    }
    #expect(store.state.ingressBursts[i0]?.active == true)
    // A fresh announce for the KNOWN destination is still admitted, not held.
    now.setValue(Date(timeIntervalSince1970: 1002))
    let (again, _) = makeAnnouncePacket(identity: known, appName: "app", aspects: ["s"],
                                        hops: 1, emitted: 5000,
                                        randomPrefix: Data([8, 0, 0, 0, 0]))
    await store.send(.received(i0, again))
    #expect(store.state.heldAnnounces[i0]?[knownDest] == nil)
    #expect(store.state.learned[knownDest]?.hops == 1)          // the better path was adopted
}

/// An announce for a destination we have an outstanding path request for is never held —
/// we asked for it (RNS skips the ingress check for pending path requests).
@Test @MainActor func pendingPathRequestExemptsAnnounceFromHolding() async {
    let now = LockIsolated(Date(timeIntervalSince1970: 1000))
    var initial = Transport.State()
    let i0 = InterfaceID("i0")
    let wanted = Identity()
    let (raw, wantedDest) = makeAnnouncePacket(identity: wanted, appName: "app", aspects: ["s"],
                                               hops: 2, emitted: 7000,
                                               randomPrefix: Data([7, 0, 0, 0, 0]))
    initial.discoveryPathRequests[wantedDest] = Date(timeIntervalSince1970: 999)
    // Pre-arm an active burst so the gate would otherwise hold.
    initial.ingressBursts[i0] = Transport.IngressBurst(
        active: true, activatedAt: Date(timeIntervalSince1970: 999),
        heldRelease: Date(timeIntervalSince1970: 1014))
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(i0, .default))
    await store.send(.received(i0, raw))
    #expect(store.state.heldAnnounces[i0]?[wantedDest] == nil)   // exempt
    #expect(store.state.learned[wantedDest] != nil)              // admitted normally
}

/// Holding replaces an existing entry for the same destination and never exceeds the cap;
/// an announce at the hop limit is dropped rather than held (RNS hold_announce).
@Test @MainActor func holdReplacesPerDestinationAndRespectsCapAndHopLimit() async {
    var initial = Transport.State()
    let i0 = InterfaceID("i0")
    initial.interfaces[i0] = .default
    initial.interfaceConnectedAt[i0] = Date(timeIntervalSince1970: 0)
    initial.ingressBursts[i0] = Transport.IngressBurst(
        active: true, activatedAt: Date(timeIntervalSince1970: 0),
        heldRelease: Date(timeIntervalSince1970: 15))
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
        $0.transportDate = DateGenerator { Date(timeIntervalSince1970: 1) }
    }
    store.exhaustivity = .off
    let id = Identity()
    let (a1, dest) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["s"],
                                        hops: 4, emitted: 1, randomPrefix: Data([1, 0, 0, 0, 0]))
    let (a2, _)    = makeAnnouncePacket(identity: id, appName: "app", aspects: ["s"],
                                        hops: 2, emitted: 2, randomPrefix: Data([2, 0, 0, 0, 0]))
    await store.send(.received(i0, a1))
    await store.send(.received(i0, a2))
    #expect(store.state.heldAnnounces[i0]?.count == 1)           // replaced, not appended
    #expect(store.state.heldAnnounces[i0]?[dest]?.hops == 2)     // newest wins

    // An announce at the hop limit is dropped outright, not held.
    let (far, farDest) = makeAnnouncePacket(hops: UInt8(Transport.ingressHoldHopLimit),
                                            emitted: 3, randomPrefix: Data([3, 0, 0, 0, 0]))
    await store.send(.received(i0, far))
    #expect(store.state.heldAnnounces[i0]?[farDest] == nil)
}

/// Disconnecting an interface drops all of its ingress state.
@Test @MainActor func disconnectClearsIngressState() async {
    var initial = Transport.State()
    let i0 = InterfaceID("i0")
    initial.interfaces[i0] = .default
    initial.interfaceConnectedAt[i0] = Date(timeIntervalSince1970: 0)
    initial.announceArrivals[i0] = [Date(timeIntervalSince1970: 1)]
    initial.ingressBursts[i0] = Transport.IngressBurst(active: true)
    initial.heldAnnounces[i0] = [Data([0xAB]): .init(raw: Data([0xCD]), hops: 1)]
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    await store.send(.interfaceDisconnected(i0))
    #expect(store.state.announceArrivals[i0] == nil)
    #expect(store.state.ingressBursts[i0] == nil)
    #expect(store.state.heldAnnounces[i0] == nil)
    #expect(store.state.interfaceConnectedAt[i0] == nil)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TransportTests`
Expected: all five FAIL to compile (the new state fields don't exist).

- [ ] **Step 3: Implement**

**State** — add beside the C3 pacing fields:

```swift
/// An announce held by ingress control until the burst subsides (RNS held_announces).
public struct HeldAnnounce: Equatable, Sendable {
    public var raw: Data
    public var hops: UInt8
    public init(raw: Data, hops: UInt8) { self.raw = raw; self.hops = hops }
}
/// Arrival times of recent signature-valid announces per interface (RNS ia_freq_deque).
public var announceArrivals: [InterfaceID: [Date]] = [:]
/// Per-interface announce burst state (RNS ic_burst_*).
public var ingressBursts: [InterfaceID: Transport.IngressBurst] = [:]
/// Held announces per interface, keyed by destination (RNS held_announces).
public var heldAnnounces: [InterfaceID: [Data: HeldAnnounce]] = [:]
/// When each interface connected — drives the young/established burst threshold (RNS age()).
public var interfaceConnectedAt: [InterfaceID: Date] = [:]
```

**`interfaceConnected`** — stamp the connection time (it already stores the profile):

```swift
case let .interfaceConnected(id, profile):
    state.interfaces[id] = profile
    state.interfaceConnectedAt[id] = date.now
    return .none
```

**`interfaceDisconnected`** — extend the existing clears (keep the C3 clears and the drain cancel):

```swift
state.announceArrivals[id] = nil
state.ingressBursts[id] = nil
state.heldAnnounces[id] = nil
state.interfaceConnectedAt[id] = nil
```

**The gate** — in the `.announce` case, immediately AFTER the `guard let parsed = Announce.parse(...)` at `Transport.swift:238-241` and BEFORE the `var ring = state.announceBlobs[...]` at `:249`:

```swift
// C4 ingress control (RNS Transport.py:1748-1766). Record the arrival first — the deque
// counts every signature-valid announce, including this one, before the decision.
let icNow = date.now
var arrivals = state.announceArrivals[interfaceID] ?? []
arrivals.append(icNow)
// Decay: drop samples older than the window, then cap the deque length.
arrivals.removeAll { icNow.timeIntervalSince($0) > Transport.arFreqDecay }
if arrivals.count > Transport.iaFreqSamples {
    arrivals.removeFirst(arrivals.count - Transport.iaFreqSamples)
}
state.announceArrivals[interfaceID] = arrivals

// Limiting applies ONLY to destinations we have no path to, and never to one we have an
// outstanding path request for. Holding must happen BEFORE the blob ring records this
// announce, or the later release would look like a replay and be dropped.
let destinationKnown = state.learned[packet.destinationHash] != nil
let awaitingPath = state.discoveryPathRequests[packet.destinationHash] != nil
if !destinationKnown, !awaitingPath {
    let age = icNow.timeIntervalSince(state.interfaceConnectedAt[interfaceID] ?? icNow)
    let decision = Transport.shouldIngressLimit(
        samples: arrivals, now: icNow, interfaceAge: age,
        burst: state.ingressBursts[interfaceID] ?? Transport.IngressBurst())
    state.ingressBursts[interfaceID] = decision.burst
    if decision.limit {
        // hold_announce (Interface.py:223-229): too-far announces are dropped, an existing
        // entry for this destination is replaced, otherwise held while under the cap.
        if Int(packet.hops) < Transport.ingressHoldHopLimit {
            var held = state.heldAnnounces[interfaceID] ?? [:]
            if held[packet.destinationHash] != nil || held.count < Transport.maxHeldAnnounces {
                held[packet.destinationHash] = State.HeldAnnounce(raw: data, hops: packet.hops)
                state.heldAnnounces[interfaceID] = held
            }
        }
        return .none
    }
}
```

`data` is the raw bytes bound by `case let .received(interfaceID, data)` — hold the ORIGINAL bytes so the release re-injects an identical packet.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter TransportTests`
Expected: the five new tests pass and every pre-existing test still passes. Pre-existing announce tests use few announces at a frozen or slowly-advancing date, so they stay under the threshold — if one now fails, do NOT adjust it; report, because it means the gate is firing where it should not.

- [ ] **Step 5: Full suite**

Run: `swift test`
Expected: 691/691 (679 + 7 from Task 1 + 5 here).

- [ ] **Step 6: Mutation verification (batch — disjoint observation points)**

Apply all three at once:
1. Drop the `!destinationKnown` condition (limit regardless) → `burstDoesNotHoldAnnounceForKnownDestination` fails (the known destination gets held / its better path is not adopted).
2. Drop the `!awaitingPath` condition → `pendingPathRequestExemptsAnnounceFromHolding` fails.
3. In the hold block, always insert regardless of the hop limit → `holdReplacesPerDestinationAndRespectsCapAndHopLimit` fails on the far-announce assertion.
Each is asserted by a different test with no shared state. Report each failure verbatim, labelled. Also confirm `burstHoldsAnnounceForUnknownDestination` stays green under all three (it exercises the plain path). Revert; re-run; green.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/c4-task2-msg.txt` (subject `feat: hold announces for unknown destinations under an ingress burst`), then:

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -F /tmp/ReTiCA/c4-task2-msg.txt
```

---

### Task 3: Release held announces as the burst subsides

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (Action; CancelID; the hold block; a new release handler)
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces: `Action.heldAnnounceReleaseDue(InterfaceID)`, `CancelID.ingressRelease(InterfaceID)`. Nothing downstream (C4 complete).

- [ ] **Step 1: Write the failing tests**

```swift
/// Once the rate subsides and the penalty has elapsed, the release timer re-injects the
/// FEWEST-HOP held announce, which is then admitted normally (path learned).
@Test @MainActor func heldAnnounceIsReleasedFewestHopsFirstAndAdmitted() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 1000))
    var initial = Transport.State()
    let i0 = InterfaceID("i0")
    initial.interfaces[i0] = .default
    initial.interfaceConnectedAt[i0] = Date(timeIntervalSince1970: 0)
    initial.ingressBursts[i0] = Transport.IngressBurst(
        active: true, activatedAt: Date(timeIntervalSince1970: 900),
        heldRelease: Date(timeIntervalSince1970: 1000))
    let far = Identity(), near = Identity()
    let (farRaw, farDest)   = makeAnnouncePacket(identity: far, appName: "app", aspects: ["s"],
                                                 hops: 5, emitted: 1,
                                                 randomPrefix: Data([1, 0, 0, 0, 0]))
    let (nearRaw, nearDest) = makeAnnouncePacket(identity: near, appName: "app", aspects: ["s"],
                                                 hops: 1, emitted: 2,
                                                 randomPrefix: Data([2, 0, 0, 0, 0]))
    initial.heldAnnounces[i0] = [farDest:  .init(raw: farRaw,  hops: 5),
                                 nearDest: .init(raw: nearRaw, hops: 1)]
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    now.setValue(Date(timeIntervalSince1970: 1001))          // past heldRelease, rate is 0
    await store.send(.heldAnnounceReleaseDue(i0))
    #expect(store.state.learned[nearDest] != nil)            // fewest hops released first
    #expect(store.state.learned[farDest] == nil)             // still held
    #expect(store.state.heldAnnounces[i0]?.count == 1)
}

/// A release is not attempted before the penalty elapses (RNS gates on ic_held_release).
@Test @MainActor func releaseWaitsForThePenaltyToElapse() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 1000))
    var initial = Transport.State()
    let i0 = InterfaceID("i0")
    initial.interfaces[i0] = .default
    initial.interfaceConnectedAt[i0] = Date(timeIntervalSince1970: 0)
    initial.ingressBursts[i0] = Transport.IngressBurst(
        active: true, activatedAt: Date(timeIntervalSince1970: 990),
        heldRelease: Date(timeIntervalSince1970: 1015))       // penalty not yet elapsed
    let (raw, dest) = makeAnnouncePacket(hops: 1, emitted: 1, randomPrefix: Data([1, 0, 0, 0, 0]))
    initial.heldAnnounces[i0] = [dest: .init(raw: raw, hops: 1)]
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    await store.send(.heldAnnounceReleaseDue(i0))
    #expect(store.state.heldAnnounces[i0]?.count == 1)        // still held
    #expect(store.state.learned[dest] == nil)
}

/// While the arrival rate is still above the threshold, releases stay blocked even past
/// the penalty (RNS re-checks the frequency inside process_held_announces).
@Test @MainActor func releaseIsBlockedWhileRateStaysHot() async {
    let clock = TestClock()
    let t0 = Date(timeIntervalSince1970: 1000)
    let now = LockIsolated(t0.addingTimeInterval(1))
    var initial = Transport.State()
    let i0 = InterfaceID("i0")
    initial.interfaces[i0] = .default
    initial.interfaceConnectedAt[i0] = Date(timeIntervalSince1970: 0)
    initial.ingressBursts[i0] = Transport.IngressBurst(
        active: true, activatedAt: t0, heldRelease: t0)
    initial.announceArrivals[i0] = (0..<10).map { t0.addingTimeInterval(Double($0) * 0.1) }
    let (raw, dest) = makeAnnouncePacket(hops: 1, emitted: 1, randomPrefix: Data([1, 0, 0, 0, 0]))
    initial.heldAnnounces[i0] = [dest: .init(raw: raw, hops: 1)]
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    await store.send(.heldAnnounceReleaseDue(i0))
    #expect(store.state.heldAnnounces[i0]?.count == 1)        // rate still ~10 Hz → blocked
    #expect(store.state.learned[dest] == nil)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TransportTests`
Expected: FAIL to compile — `heldAnnounceReleaseDue` does not exist.

- [ ] **Step 3: Implement**

**Action** — beside `announceQueueDrainDue`:

```swift
case heldAnnounceReleaseDue(InterfaceID)
```

**CancelID** — add `case ingressRelease(InterfaceID)`.

**Schedule a release when holding** — inside the hold block in the `.announce` gate, after storing the held announce, arm the timer:

```swift
let releaseIn = max(0, (state.ingressBursts[interfaceID]?.heldRelease ?? icNow)
                          .timeIntervalSince(icNow))
return .run { send in
    try await clock.sleep(for: .seconds(releaseIn))
    await send(.heldAnnounceReleaseDue(interfaceID))
}.cancellable(id: CancelID.ingressRelease(interfaceID), cancelInFlight: true)
```
(replacing the bare `return .none` in the limited branch; the drop-by-hop-limit path still returns `.none`.)

**Cancel on disconnect** — `interfaceDisconnected` currently returns `.cancel(id: CancelID.announceDrain(id))`; it must now cancel both:

```swift
return .merge(.cancel(id: CancelID.announceDrain(id)),
              .cancel(id: CancelID.ingressRelease(id)))
```

**Release handler** — after the `announceQueueDrainDue` case (RNS process_held_announces, Interface.py:231-253):

```swift
case let .heldAnnounceReleaseDue(id):
    guard let held = state.heldAnnounces[id], !held.isEmpty else { return .none }
    let now = date.now
    let burst = state.ingressBursts[id] ?? Transport.IngressBurst()
    // Not yet past the penalty, or the rate is still hot: try again later.
    let age = now.timeIntervalSince(state.interfaceConnectedAt[id] ?? now)
    let threshold = Transport.ingressBurstThreshold(interfaceAge: age)
    let freq = Transport.announceFrequency(samples: state.announceArrivals[id] ?? [], now: now)
    guard now > burst.heldRelease, freq < threshold else {
        return .run { send in
            try await clock.sleep(for: .seconds(Transport.icHeldReleaseInterval))
            await send(.heldAnnounceReleaseDue(id))
        }.cancellable(id: CancelID.ingressRelease(id), cancelInFlight: true)
    }
    // Release the fewest-hop announce, then space the next release.
    guard let pick = held.min(by: { $0.value.hops < $1.value.hops }) else { return .none }
    var remaining = held
    remaining[pick.key] = nil
    state.heldAnnounces[id] = remaining.isEmpty ? nil : remaining
    var next = burst
    next.heldRelease = now.addingTimeInterval(Transport.icHeldReleaseInterval)
    state.ingressBursts[id] = next
    var effects: [Effect<Action>] = [.send(.received(id, pick.value.raw))]
    if !remaining.isEmpty {
        effects.append(.run { send in
            try await clock.sleep(for: .seconds(Transport.icHeldReleaseInterval))
            await send(.heldAnnounceReleaseDue(id))
        }.cancellable(id: CancelID.ingressRelease(id), cancelInFlight: true))
    }
    return .merge(effects)
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter TransportTests`
Expected: all pass.

- [ ] **Step 5: Full suite**

Run: `swift test`
Expected: 694/694 (691 + 3).

- [ ] **Step 6: Mutation verification (batch — three disjoint tests)**

Apply all three at once:
1. In the release handler, pick the LARGEST hops (`>` instead of `<`) → `heldAnnounceIsReleasedFewestHopsFirstAndAdmitted` fails (far released first).
2. Drop the `now > burst.heldRelease` condition → `releaseWaitsForThePenaltyToElapse` fails.
3. Drop the `freq < threshold` condition → `releaseIsBlockedWhileRateStaysHot` fails.
Each is asserted by a different test. Report each failure verbatim, labelled. Revert; green.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/c4-task3-msg.txt` (subject `feat: release held announces as the ingress burst subsides`), then:

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -F /tmp/ReTiCA/c4-task3-msg.txt
```

---

## Final verification (after Task 3)

- [ ] `swift test` — full suite green; report the exact count (expected 694).
- [ ] `grep -n "shouldIngressLimit\|heldAnnounces\[" Sources/ReTiCATransport/Transport.swift` — the gate, the release handler, and the disconnect clear; no other call sites.
- [ ] Confirm by reading the `.announce` case that the gate sits BETWEEN `Announce.parse` and the blob-ring insert (a released announce must not be seen as a replay).
- [ ] `grep -n "ingressRelease" Sources/ReTiCATransport/Transport.swift` — the CancelID case, the disconnect cancel, and the three schedule sites.
- [ ] `git log --format='%(trailers:key=Claude-Session)' -3` — all three task commits' trailers parse.
- [ ] `git diff <plan-base> HEAD --stat` — only `Transport.swift` and `TransportTests.swift` (plus this plan file).
