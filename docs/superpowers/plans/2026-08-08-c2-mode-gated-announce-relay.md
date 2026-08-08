# C2 — Mode-Gated Announce Relay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Announce relay respects interface modes — access-point interfaces never relay, roaming/boundary interfaces damp each other — per RNS `Transport.py:1224-1270` (spec: `docs/superpowers/specs/2026-08-04-rns-interface-conformance-design.md`, C2 section).

**Architecture:** One pure policy function `Transport.mayRelayAnnounce(to:arrivalMode:)` (Task 1), wired into exactly two sites (Task 2): the relay scheduling gate and the `announceRetransmitDue` fan-out. Locally-originated announces and path-request fan-outs are deliberately untouched.

**Tech Stack:** Swift 6 / TCA / swift-testing. Repo: `/Users/ell/development/ios/pods/ReTiCA`.

## Global Constraints

- Commit directly to `main`. No branches, merges, rebases, or resets.
- The user commits CONCURRENTLY. `git add` ONLY the files each task names.
- One command per Bash invocation — no `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, no inline interpreter scripts. Multi-step processing = script under `/tmp/ReTiCA/`.
- Commit trailers MUST start at column 0:
```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
```
- Mutation discipline every task. **Mutations must fail through DISJOINT observation points** — this project has twice had batched mutations mask each other when they met at shared state. Each task's mutations below are designed accordingly; apply them exactly.
- Clean full run: 661/661 green, NO pre-existing failures. `PNNode*`/`LXMFNodeSync*`/`twoEndpointsTransferMultiSegmentResource*` have flaked under parallelism — classify by isolated `--filter` re-run; report real numbers.
- The reference table (RNS `Transport.py:1224-1270`) is not negotiable:
  - `.accessPoint` OUT: never relays a received announce (originates only).
  - `.roaming` OUT: blocked when the announce ARRIVED on `.roaming` or `.boundary`.
  - `.boundary` OUT: blocked when the announce ARRIVED on `.roaming`.
  - `.full` / `.pointToPoint` / `.gateway` OUT: always permitted.
  - `.interfaceInternal`: treated as `.full` in C2 (spec defers its `announces_to_internal` rule; no ReTiCA composition uses it) — document with a comment.
  - `nil` arrival mode (arrival interface disconnected during the jitter window): PERMISSIVE — treat as `.full`-like (nil is not `.roaming`/`.boundary`). Reference cannot exhibit this case; permissive preserves current behaviour and matches C1's nil-fallback philosophy.
- Recorded spec decision: the existing ~30 relay tests stay green because every profile defaults to `.full` — that greenness is meaningless as C2 evidence. C2's proof is the NEW mode-specific tests, which must fail under unconditional fan-out.

---

### Task 1: The pure relay-policy function

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (add next to `pathExpiry(forMode:)`, ≈:510-519)
- Test: `Tests/ReTiCATransportTests/TransportTests.swift` (add near `announceJitterMapsByteToWindowFraction`, ≈:1435)

**Interfaces:**
- Consumes: `InterfaceMode` (C1).
- Produces: `static func mayRelayAnnounce(to outMode: InterfaceMode, arrivalMode: InterfaceMode?) -> Bool` on `Transport`. Task 2 calls it at both gate sites.

- [ ] **Step 1: Write the failing test**

The expected values are DATA — the 11 blocked pairs enumerated from the reference — not a re-statement of the implementation's switch, so the test cannot be a tautology.

```swift
/// The complete mode-gating table from RNS Transport.py:1224-1270. The blocked set is
/// enumerated as data; every combination not listed must relay. nil arrival = the arrival
/// interface disconnected mid-window — permissive by decision (C2 spec).
@Test func mayRelayAnnounceMatchesReferenceTable() {
    let blocked: [(InterfaceMode, InterfaceMode?)] = [
        // accessPoint out: never relays, regardless of arrival (incl. disconnected).
        (.accessPoint, nil), (.accessPoint, .full), (.accessPoint, .pointToPoint),
        (.accessPoint, .accessPoint), (.accessPoint, .roaming), (.accessPoint, .boundary),
        (.accessPoint, .gateway), (.accessPoint, .interfaceInternal),
        // roaming out: no re-advertising what came from roaming/boundary peers.
        (.roaming, .roaming), (.roaming, .boundary),
        // boundary out: no re-advertising what came from roaming peers.
        (.boundary, .roaming),
    ]
    let all: [InterfaceMode] = [.full, .pointToPoint, .accessPoint, .roaming,
                                .boundary, .gateway, .interfaceInternal]
    let arrivals: [InterfaceMode?] = all.map { $0 } + [nil]
    for out in all {
        for arrival in arrivals {
            let expected = !blocked.contains { $0.0 == out && $0.1 == arrival }
            #expect(Transport.mayRelayAnnounce(to: out, arrivalMode: arrival) == expected,
                    "out=\(out) arrival=\(String(describing: arrival))")
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter mayRelayAnnounceMatchesReferenceTable`
Expected: FAIL to compile — `mayRelayAnnounce` not defined.

- [ ] **Step 3: Implement**

In `Sources/ReTiCATransport/Transport.swift`, immediately after `pathExpiry(forMode:)`:

```swift
/// Whether a RECEIVED announce may be relayed out an interface of mode `outMode`, given the
/// mode of the interface it arrived on (RNS Transport.py:1224-1270). Applies ONLY to relay
/// re-broadcast — locally-originated announces go everywhere (an access point "originates
/// only"). nil arrivalMode = the arrival interface has disconnected since; permissive by
/// C2 spec decision. `.interfaceInternal` is treated as `.full` (its announces_to_internal
/// rule is deferred; no ReTiCA composition uses internal-mode interfaces).
static func mayRelayAnnounce(to outMode: InterfaceMode, arrivalMode: InterfaceMode?) -> Bool {
    switch outMode {
    case .accessPoint: return false
    case .roaming:     return arrivalMode != .roaming && arrivalMode != .boundary
    case .boundary:    return arrivalMode != .roaming
    case .full, .pointToPoint, .gateway, .interfaceInternal: return true
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter mayRelayAnnounceMatchesReferenceTable`
Expected: PASS (56 combinations checked).

- [ ] **Step 5: Mutation verification (batch, same observation point, disjoint combos)**

Apply both at once: (1) `case .accessPoint: return true`; (2) swap the `.roaming` and `.boundary` arms' bodies.
Run: `swift test --filter mayRelayAnnounceMatchesReferenceTable`
Expected: FAIL. The report must show the failing combos include BOTH accessPoint rows (mutation 1) AND roaming/boundary rows (mutation 2) — each mutation flips different table entries, so both are independently visible in one run. Revert; re-run; PASS.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCA/c2-task1-msg.txt` (subject `feat: announce relay mode-gating policy (RNS Transport.py:1224-1270 table)`), then:

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -F /tmp/ReTiCA/c2-task1-msg.txt
```

---

### Task 2: Wire the gates + mode-specific relay tests

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (scheduling gate ≈:268-270; fan-out ≈:429-431 — find by quoted code, lines are anchors)
- Test: `Tests/ReTiCATransportTests/TransportTests.swift` (new helper + 6 tests, add after `singleInterfaceRelayDoesNotSchedule` ≈:1430)

**Interfaces:**
- Consumes: `Transport.mayRelayAnnounce(to:arrivalMode:)` (Task 1); `InterfaceProfile(name:bitrate:mode:)` (C1); existing helpers `makeAnnouncePacket(hops:emitted:)`, and the store pattern of `makeTimedRelayStore` (TransportTests.swift:1310-1322).
- Produces: nothing downstream (C2 is complete after this task).

- [ ] **Step 1: Write the failing tests**

First a helper, modeled on `makeTimedRelayStore` (:1310) but taking profiled interfaces:

```swift
private func makeModedRelayStore(_ relay: Identity, _ clock: TestClock<Duration>,
                                 interfaces: [(InterfaceID, InterfaceProfile)],
                                 jitterByte: UInt8 = 128)
    async -> TestStore<Transport.State, Transport.Action> {
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = clock
        $0.randomBytes = RandomBytesGenerator { _ in Data([jitterByte]) }
    }
    store.exhaustivity = .off
    for (id, profile) in interfaces {
        await store.send(.interfaceConnected(id, profile))
    }
    await store.send(.setTransportIdentity(relay))
    return store
}

private let apProfile      = InterfaceProfile(name: "ap",    bitrate: 62_500, mode: .accessPoint)
private let roamingProfile = InterfaceProfile(name: "roam",  bitrate: 62_500, mode: .roaming)
private let boundaryProfile = InterfaceProfile(name: "bound", bitrate: 62_500, mode: .boundary)
```

Then the exclusion tests. Each drives the relay lifecycle TO COMPLETION (initial jittered send at 0.25 s, then the capped retry at +5.5 s — after which `announceTable` is nil and NO effect is in flight), captures every matched transmit target in a set, asserts the set, and flips `store.exhaustivity = .on` as the LAST statement so TestStore teardown fails on any transmit the `.off` phase skipped. This flip-`.on`-last idiom is this codebase's established absence-assertion pattern — without it, a stray transmit to the excluded interface would be silently skipped.

```swift
/// An access-point interface is excluded from announce relay while a full interface still
/// receives it (RNS: AP never retransmits announces from the network).
@Test @MainActor func accessPointInterfaceIsExcludedFromAnnounceRelay() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeModedRelayStore(Identity(), clock, interfaces: [
        (InterfaceID("i0"),    .default),        // arrival, mode .full
        (InterfaceID("iAP"),   apProfile),
        (InterfaceID("iFull"), .default),
    ])
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    let sent = LockIsolated<Set<InterfaceID>>([])
    await clock.advance(by: .seconds(0.25))                 // jittered send #1
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    await clock.advance(by: .seconds(5.5))                  // capped retry (send #2, lifecycle ends)
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    #expect(sent.value == [InterfaceID("iFull")])           // iAP excluded both rounds
    #expect(store.state.announceTable[destHash] == nil)     // lifecycle complete, no timer in flight
    store.exhaustivity = .on   // teardown now fails on any skipped transmit (e.g. one to iAP)
}

/// A roaming interface does not re-advertise an announce that arrived from another roaming
/// interface; a full interface alongside it still relays.
@Test @MainActor func roamingDoesNotRelayAnnouncesArrivingFromRoaming() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeModedRelayStore(Identity(), clock, interfaces: [
        (InterfaceID("i0"),    roamingProfile),  // arrival is ROAMING
        (InterfaceID("iRoam"), roamingProfile),
        (InterfaceID("iFull"), .default),
    ])
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    let sent = LockIsolated<Set<InterfaceID>>([])
    await clock.advance(by: .seconds(0.25))
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    await clock.advance(by: .seconds(5.5))
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    #expect(sent.value == [InterfaceID("iFull")])
    #expect(store.state.announceTable[destHash] == nil)
    store.exhaustivity = .on
}

/// A roaming interface also does not re-advertise announces arriving from a BOUNDARY interface.
@Test @MainActor func roamingDoesNotRelayAnnouncesArrivingFromBoundary() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeModedRelayStore(Identity(), clock, interfaces: [
        (InterfaceID("i0"),    boundaryProfile), // arrival is BOUNDARY
        (InterfaceID("iRoam"), roamingProfile),
        (InterfaceID("iFull"), .default),
    ])
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    let sent = LockIsolated<Set<InterfaceID>>([])
    await clock.advance(by: .seconds(0.25))
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    await clock.advance(by: .seconds(5.5))
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    #expect(sent.value == [InterfaceID("iFull")])
    #expect(store.state.announceTable[destHash] == nil)
    store.exhaustivity = .on
}

/// A boundary interface does not re-advertise announces arriving from a ROAMING interface —
/// and the full interface alongside proves full-out DOES relay from a roaming arrival.
@Test @MainActor func boundaryDoesNotRelayAnnouncesArrivingFromRoaming() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeModedRelayStore(Identity(), clock, interfaces: [
        (InterfaceID("i0"),     roamingProfile), // arrival is ROAMING
        (InterfaceID("iBound"), boundaryProfile),
        (InterfaceID("iFull"),  .default),
    ])
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    let sent = LockIsolated<Set<InterfaceID>>([])
    await clock.advance(by: .seconds(0.25))
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    await clock.advance(by: .seconds(5.5))
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    #expect(sent.value == [InterfaceID("iFull")])
    #expect(store.state.announceTable[destHash] == nil)
    store.exhaustivity = .on
}

/// A relay whose only other interface cannot relay (access point) schedules nothing — the
/// scheduling gate, not just the fan-out, consults eligibility. Modeled on
/// singleInterfaceRelayDoesNotSchedule (:1418).
@Test @MainActor func relayWithOnlyIneligibleTargetsDoesNotSchedule() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0)); $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0"), .default))
    await store.send(.interfaceConnected(InterfaceID("iAP"), apProfile))
    await store.send(.setTransportIdentity(Identity()))
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.announceTable[destHash] == nil)   // nowhere eligible → not held
}

/// LOCALLY-ORIGINATED announces are ungated: an access point "originates only", so its own
/// announce still goes out every interface including AP-mode ones. Modeled on
/// announceFansOutToAllInterfaces (:524).
@Test @MainActor func locallyOriginatedAnnounceStillFansOutToAccessPointInterfaces() async {
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
        $0.transportDate = DateGenerator { Date(timeIntervalSince1970: 1_700_000_000) }
    }
    store.exhaustivity = .off
    let dest = Destination(kind: .single, direction: .in, appName: "app",
                           aspects: ["s"], identity: Identity())!
    await store.send(.registerLocalDestination(dest))
    await store.send(.interfaceConnected(InterfaceID("iAP"), apProfile))
    await store.send(.interfaceConnected(InterfaceID("iFull"), .default))
    let sent = LockIsolated<Set<InterfaceID>>([])
    await store.send(.announce(destinationHash: dest.hash, appData: nil))
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    await store.receive { action in
        if case let .delegate(.transmit(i, _)) = action { sent.withValue { _ = $0.insert(i) }; return true }
        return false
    }
    #expect(sent.value == [InterfaceID("iAP"), InterfaceID("iFull")])   // BOTH — no gate here
}
```

**If any constructor differs from the real API** (`Destination(kind:direction:appName:aspects:identity:)`, the `.announce` action shape, `makeAnnouncePacket` labels), consult the named model tests — `announceFansOutToAllInterfaces` (:524), `freshAnnounceRebroadcastIsDeferredUntilJitterElapses` (:1326), `singleInterfaceRelayDoesNotSchedule` (:1418) — and adjust minimally, documenting each deviation.

- [ ] **Step 2: Run to verify the exclusion tests fail**

Run: `swift test --filter TransportTests`
Expected: the four exclusion tests FAIL (the excluded interface still receives a transmit under ungated code, so `sent` has 2 elements — or teardown flags the stray) and `relayWithOnlyIneligibleTargetsDoesNotSchedule` FAILS (`announceTable` non-nil). `locallyOriginatedAnnounceStillFansOutToAccessPointInterfaces` should already PASS (it pins existing behaviour so the gates don't over-reach).

- [ ] **Step 3: Implement the two gates**

In `Sources/ReTiCATransport/Transport.swift`.

Scheduling gate — the condition at ≈:268-270 currently reads:
```swift
if let relayID = state.transportIdentity,
   Int(packet.hops) + 1 < Int(Packet.maxHops),
   state.interfaces.keys.contains(where: { $0 != interfaceID }) {
```
becomes:
```swift
let arrivalMode = state.interfaces[interfaceID]?.mode
if let relayID = state.transportIdentity,
   Int(packet.hops) + 1 < Int(Packet.maxHops),
   state.interfaces.contains(where: { $0.key != interfaceID
       && Transport.mayRelayAnnounce(to: $0.value.mode, arrivalMode: arrivalMode) }) {
```

Fan-out — at ≈:429-431 currently:
```swift
let sends = state.interfaces.keys
    .filter { $0 != entry.arrivalInterface }
    .map { Effect<Action>.send(.delegate(.transmit($0, entry.raw))) }
```
becomes:
```swift
let arrivalMode = state.interfaces[entry.arrivalInterface]?.mode
let sends = state.interfaces
    .filter { $0.key != entry.arrivalInterface
        && Transport.mayRelayAnnounce(to: $0.value.mode, arrivalMode: arrivalMode) }
    .map { Effect<Action>.send(.delegate(.transmit($0.key, entry.raw))) }
```

Touch NOTHING else: the locally-originated fan-out (`state.interfaces.keys.map` in `case .announce`), the path-request fan-outs (`:356`, `case .requestPath`), and the collaborative-suppression/replay logic stay exactly as they are.

- [ ] **Step 4: Run to verify all pass**

Run: `swift test --filter TransportTests`
Expected: all pass, including the six new tests and every pre-existing relay test (their interfaces are all `.default` = `.full`, which the table permits — their passing is expected, and is exactly why they are NOT the evidence; the new tests are).

- [ ] **Step 5: Full suite**

Run: `swift test`
Expected: 667/667 (661 + 6).

- [ ] **Step 6: Mutation verification (batch — disjoint observation points, function untouched)**

Apply both at once — these mutate the CALL SITES, not the Task 1 function, so Task 1's table test stays green and cannot mask anything:
1. Fan-out site: remove the `mayRelayAnnounce` clause from the filter (restore `.keys.filter { $0 != entry.arrivalInterface }` + matching `.map`). Observed via TRANSMIT EFFECTS: the four exclusion tests fail (stray transmit to the excluded interface — the `sent` set or the `.on` teardown catches it).
2. Scheduling site: restore `state.interfaces.keys.contains(where: { $0 != interfaceID })`. Observed via HELD-TABLE STATE: `relayWithOnlyIneligibleTargetsDoesNotSchedule` fails (`announceTable` non-nil). This test never reaches fan-out, so mutation 1 cannot influence it; the exclusion tests all have an eligible target, so mutation 2 does not change their scheduling — the two observation points are independent.
Also expected: `locallyOriginatedAnnounceStillFansOutToAccessPointInterfaces` and the whole pre-existing relay suite stay GREEN under both mutations (they assert `.full` behaviour, which gating does not change — if any of them fails, the mutation was mis-applied).
Run: `swift test --filter TransportTests`. Report each failure verbatim, labelled with which mutation it proves. Revert both; re-run; green.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/c2-task2-msg.txt` (subject `feat: mode-gate announce relay at scheduling + fan-out (C2)`), then:

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -F /tmp/ReTiCA/c2-task2-msg.txt
```

---

## Final verification (after Task 2)

- [ ] `swift test` — full suite green; report the exact count (expected 667).
- [ ] `grep -n "mayRelayAnnounce" Sources/ReTiCATransport/Transport.swift` — exactly 3 hits: the definition + the two call sites.
- [ ] Confirm by reading `case .announce` (locally-originated, ≈:480) and `case .requestPath` (≈:493) that neither gained a gate.
- [ ] `git log --format='%(trailers:key=Claude-Session)' -2` — both task commits' trailers parse.
- [ ] `git diff <plan-base> HEAD --stat` — only `Transport.swift`, `TransportTests.swift` (plus this plan file).
