# Announce Re-broadcast Retries + Grace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend 4b-3b-1's single jittered announce re-broadcast into RNS's bounded retry lifecycle — up to `LOCAL_REBROADCASTS_MAX = 2` total sends per fresh announce, spaced `PATHFINDER_G = 5s` grace + jitter.

**Architecture:** One production file changes: `Sources/ReTiCATransport/Transport.swift`. `PendingAnnounce` gains a `rebroadcasts` counter; the `.announceRetransmitDue` handler becomes a bounded retry loop that re-broadcasts the same held bytes, increments the counter, and either re-schedules the next retry (`grace + jitter`) or removes the entry at the cap. A superseding fresh announce still resets the lifecycle via the existing `cancelInFlight` re-arm. Because each relay re-broadcast now emits two transmits, existing relay tests that observe a re-broadcast are updated to drain the second (identical) one.

**Tech Stack:** Swift, The Composable Architecture (~1.26): `@Dependency(\.continuousClock)`, `TestClock`/`ImmediateClock`, `.cancellable(id:cancelInFlight:)`, `@Dependency(\.randomBytes)`. Constants cross-validated against genuine Python-RNS 1.3.8.

## Global Constraints

- Wire-compatible with Python-RNS 1.3.8. Core `Sources/ReTiCA/*` stays zero-dep and **untouched** — changes only in `Sources/ReTiCATransport/*` and `Tests/*`.
- Commit **directly to `main`** — no feature branch. Every commit leaves the FULL suite green (production + all test migration land together).
- **No compound shell commands** — one command per shell call (a single `|` pipeline or `>` redirect allowed). Run `swift build`, `swift test`, `git add`, `git commit` separately. Never inline a script into an interpreter; write it to a file under `/tmp/ReTiCA/` and run the file.
- Temp files under `/tmp/ReTiCA/`.
- **Mutation-testing verification** for every new/changed test: run pass → batch-mutate production so they should fail → confirm fail → revert → confirm pass. If two mutations interact (one masks another), verify those independently.
- Reference RNS at `/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/RNS/`; run its python by absolute path `/Users/ell/opt/anaconda3/envs/rns/bin/python`. Build gotcha: signal-11/SIGILL → `swift package clean` then retry.
- Commit trailers (exact, both lines, every commit):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```

Spec: `docs/superpowers/specs/2026-07-25-announce-retries-design.md`.

## Grounding facts (verified — do not re-derive)

- Current `PendingAnnounce` (`Transport.swift:23-29`): `{ var raw: Data; var arrivalInterface: InterfaceID; init(raw:arrivalInterface:) }`. Constructed once at `Transport.swift:195` as `State.PendingAnnounce(raw: rebroadcastRaw, arrivalInterface: interfaceID)`.
- Current `.announceRetransmitDue` handler (`Transport.swift:240-246`): pops the entry, fans out `.delegate(.transmit)` to interfaces except `entry.arrivalInterface`, returns `.merge(sends)`.
- Existing constants/deps on `Transport`: `static let announceRebroadcastWindow = 0.5`; `static func announceJitter(_ byte: UInt8) -> Double` = `byte/256 * announceRebroadcastWindow`; `@Dependency(\.continuousClock) var clock`; `@Dependency(\.randomBytes) var randomBytes`; `private enum CancelID: Hashable { case announceRetransmit(Data) }`; the `Reduce` closure captures `[clock, randomBytes]`.
- The `.announce` scheduling block (`Transport.swift:184-203`) builds the HEADER_2 re-broadcast bytes, stores the `PendingAnnounce`, and schedules the first timer with `announceJitter(...)`. It stays unchanged except the `PendingAnnounce` initializer now defaults `rebroadcasts: 0`.
- Test helper `makeTimedRelayStore(_ relay:_ clock:jitterByte:)` (TransportTests.swift, added in 4b-3b-1) builds a 2-interface relay store with a `TestClock` and `randomBytes` fixed to `jitterByte` (so jitter is deterministic; retry jitter uses the same byte).
- RNS values (Transport.py): `LOCAL_REBROADCASTS_MAX = 2` (line 77), `PATHFINDER_G = 5` (line 69), `PATHFINDER_R = 1` (line 68), `PATHFINDER_RW = 0.5` (line 70). Completion at `retries >= LOCAL_REBROADCASTS_MAX` (line 595) — 2 total sends.
- **Double-transmit migration fact:** under `ImmediateClock` the grace collapses to 0, so a fresh relay announce fires BOTH sends immediately (transmit#1 then transmit#2, identical bytes), then the entry pops (no lingering effect). Any test that observes the re-broadcast must drain BOTH before a subsequent `.on` assertion or a later same-interface transmit-predicate receive (which would otherwise match the leftover retry).

---

### Task 1: Bounded retry lifecycle (+ migrate affected tests)

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift`.
- Test: `Tests/ReTiCATransportTests/TransportTests.swift` (new retry tests + 5 migrations), `Tests/ReTiCATransportTests/Vectors/RelayCrossValidationTests.swift` (1 migration), `Tests/ReTiCANodeTests/EndpointTests.swift` (1 migration).

**Interfaces:**
- Produces: `PendingAnnounce.rebroadcasts: Int`, `static let Transport.announceMaxRebroadcasts = 2`, `static let Transport.announceRetryGrace = 5.0` — read by Task 2.

- [ ] **Step 1: Add the counter and constants**

In `Transport.State.PendingAnnounce`, add the field and default it in the initializer:

```swift
        public struct PendingAnnounce: Equatable, Sendable {
            public var raw: Data
            public var arrivalInterface: InterfaceID
            public var rebroadcasts: Int
            public init(raw: Data, arrivalInterface: InterfaceID, rebroadcasts: Int = 0) {
                self.raw = raw; self.arrivalInterface = arrivalInterface; self.rebroadcasts = rebroadcasts
            }
        }
```

In `Transport` at type scope (next to `announceRebroadcastWindow`):

```swift
    /// RNS LOCAL_REBROADCASTS_MAX (Transport.py:77): total local re-broadcasts of one announce.
    static let announceMaxRebroadcasts = 2
    /// RNS PATHFINDER_G (Transport.py:69): grace between announce re-broadcast retries, seconds.
    static let announceRetryGrace = 5.0
```

The `.announce` scheduling site at `Transport.swift:195` needs no change — `State.PendingAnnounce(raw:arrivalInterface:)` now uses the defaulted `rebroadcasts: 0`.

- [ ] **Step 2: Make `.announceRetransmitDue` a bounded retry loop**

Replace the handler (`Transport.swift:240-246`) with:

```swift
            case let .announceRetransmitDue(destinationHash):
                guard var entry = state.announceTable[destinationHash] else { return .none }
                let sends = state.interfaces
                    .filter { $0 != entry.arrivalInterface }
                    .map { Effect<Action>.send(.delegate(.transmit($0, entry.raw))) }
                entry.rebroadcasts += 1
                if entry.rebroadcasts >= Transport.announceMaxRebroadcasts {
                    state.announceTable[destinationHash] = nil          // lifecycle complete
                    return sends.isEmpty ? .none : .merge(sends)
                }
                state.announceTable[destinationHash] = entry            // keep for the next retry
                let delay = Transport.announceRetryGrace
                    + Transport.announceJitter(randomBytes(1).first ?? 0)
                let retry = Effect<Action>.run { send in
                    try await clock.sleep(for: .seconds(delay))
                    await send(.announceRetransmitDue(destinationHash: destinationHash))
                }.cancellable(id: CancelID.announceRetransmit(destinationHash), cancelInFlight: true)
                return .merge(sends + [retry])
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: compiles. (Editor "No such module 'ComposableArchitecture'" is a known false positive.)

- [ ] **Step 4: Migrate the affected existing tests (drain the retry transmit)**

Each relay announce now emits two transmits under `ImmediateClock`. Add a drain of the second wherever a re-broadcast is observed. The drain line is:

```swift
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false } // retry re-broadcast
```

Apply at these exact sites (store name matches the local variable in each test):

1. `TransportTests.swift` `relayRebroadcastsAnnounceWithHeader2AndOurTransportId`: after the existing `store.receive { … transmit … }` that captures the re-broadcast, add one drain line.
2. `exactReplayAnnounceIsDroppedAndNotRebroadcast` (line ~1160): after `await store.receive { … } // first re-broadcast`, add one drain line — BEFORE the replay send and `store.exhaustivity = .on`.
3. `forgeReplayWithMutatedAppDataIsDropped` (line ~1182): after the transmit receive, add one drain line — before the forged send and `.on`.
4. `nonImprovingFreshAnnounceIsStillRebroadcast` (lines ~1203, ~1207): add a drain after the `newer` transmit receive (line ~1203); and after the `older` capture receive (lines ~1207-1210), add a drain for the `older` retry. So each of the two announces drains its own retry.
5. `threeNodeRelayDeliversMessageEndToEnd` (line ~953): after the `rRebroadcastRaw` capture receive (`ifID == ifAR`), add: `await storeR.receive { if case .delegate(.transmit) = $0 { return true }; return false }`.
6. `Vectors/RelayCrossValidationTests.swift` `relayRebroadcastsGenuineRnsAnnounceCorrectly` (line ~39): after the `captured` re-broadcast receive, add: `await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }`.
7. `EndpointTests.swift` `threeNodeRelayLinkEstablishesAndCarriesData` (after the `rRebroadcastRaw` capture, ~line 1476): add: `await storeR.receive { if case .delegate(.transmit) = $0 { return true }; return false }`. (Critical here: the leftover retry goes to `ifAR`, and a later LRPROOF-forward receive also matches `ifAR` — draining now prevents it matching the retry.)

- [ ] **Step 5: Run the migrated suite**

Run: `swift test`
Expected: all pass. If a relay test still fails with an unexpected/leftover transmit, it observes a re-broadcast without draining the retry — add the drain line at that site and re-run.

- [ ] **Step 6: Add the new retry unit tests**

Append to `Tests/ReTiCATransportTests/TransportTests.swift`:

```swift
// MARK: - 4b-3b-2 announce re-broadcast retries + grace

/// A fresh announce is re-broadcast twice (initial after jitter, one retry after grace+jitter),
/// with identical bytes, then the lifecycle completes and no third send occurs.
@Test @MainActor func announceRebroadcastRetriesTwiceThenStops() async {
    let relay = Identity()
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeTimedRelayStore(relay, clock, jitterByte: 128)   // jitter 0.25; retry 5.25
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.announceTable[destHash]?.rebroadcasts == 0)

    await clock.advance(by: .seconds(0.25))                    // fire send #1
    let first = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(_, d)) = action { first.setValue(d); return true }
        return false
    }
    #expect(store.state.announceTable[destHash]?.rebroadcasts == 1)   // retained, one send done

    await clock.advance(by: .seconds(5.25))                    // grace(5) + jitter(0.25) → send #2
    let second = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(_, d)) = action { second.setValue(d); return true }
        return false
    }
    #expect(second.value == first.value)                       // identical held bytes
    #expect(store.state.announceTable[destHash] == nil)        // lifecycle complete at the cap

    await clock.advance(by: .seconds(5.25))                    // no third send scheduled
    #expect(store.state.announceTable[destHash] == nil)
}

/// A superseding fresh announce during the grace window resets the retry lifecycle: the pending
/// retry is cancelled and a new single-then-retry chain starts for the newer announce.
@Test @MainActor func supersedingAnnounceResetsRetryLifecycle() async {
    let id = Identity()
    let clock = TestClock()
    let (a1, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["s"], hops: 2,
                                            emitted: 1000, appData: Data("AAA".utf8),
                                            randomPrefix: Data([1, 0, 0, 0, 0]))
    let (a2, _)        = makeAnnouncePacket(identity: id, appName: "app", aspects: ["s"], hops: 2,
                                            emitted: 2000, appData: Data("BBB".utf8),
                                            randomPrefix: Data([2, 0, 0, 0, 0]))
    let store = await makeTimedRelayStore(id, clock, jitterByte: 128)
    await store.send(.received(InterfaceID("i0"), a1))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await clock.advance(by: .seconds(0.25))                    // a1 send #1
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.announceTable[destHash]?.rebroadcasts == 1)

    // Supersede during the grace window (before a1's retry at +5.25).
    await store.send(.received(InterfaceID("i0"), a2))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.announceTable[destHash]?.rebroadcasts == 0)          // reset by supersede

    await clock.advance(by: .seconds(0.25))                    // a2 send #1
    let out = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(_, d)) = action { out.setValue(d); return true }
        return false
    }
    #expect(Packet(raw: out.value!)!.payload == Packet(raw: a2)!.payload)    // newer announce won
    await clock.advance(by: .seconds(5.25))                    // a2 retry
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.announceTable[destHash] == nil)
}
```

- [ ] **Step 7: Run the new tests**

Run: `swift test --filter TransportTests`
Expected: all pass.

- [ ] **Step 8: Mutation verification**

Apply and confirm the mapped test fails; verify independently if any pair interacts:
1. Never retry — pop the entry unconditionally after the first send (revert the handler to the 4b-3b-1 single-send form) → `announceRebroadcastRetriesTwiceThenStops` fails (no second send: the `announceTable[destHash]?.rebroadcasts == 1` retained-state assertion and the second `receive { transmit }` both fail) and `supersedingAnnounceResetsRetryLifecycle` fails.
2. Never stop — remove the cap check (`if entry.rebroadcasts >= …`) so it always re-schedules → `announceRebroadcastRetriesTwiceThenStops` fails (the entry is not removed after send #2: `announceTable[destHash] == nil` fails, and a third send fires on the final advance).

(The retry *grace value* itself is guarded by Task 2's `PATHFINDER_G` parity — a `TestClock` advance of `grace + jitter` cannot cleanly falsify a jitter-only vs grace+jitter delay, so it is not a unit mutation here.)

Run: `swift test --filter TransportTests`. Then revert all and re-run — expect all pass.

- [ ] **Step 9: Full suite**

Run: `swift test`
Expected: all pass (baseline before this slice: 334 pass / 1 skip; +2 new tests → ~336 / 1 skip).

- [ ] **Step 10: Commit**

Write the message to `/tmp/ReTiCA/commit-t1.txt`, `git add` the changed files, `git commit -F`.

```
feat: re-broadcast held announces up to LOCAL_REBROADCASTS_MAX with grace

Extend the single jittered re-broadcast into RNS's bounded retry lifecycle:
PendingAnnounce gains a rebroadcasts counter; .announceRetransmitDue re-sends
the same held bytes, increments the counter, and either re-schedules the next
retry (PATHFINDER_G grace + fresh jitter) or removes the entry at the cap
(announceMaxRebroadcasts = 2). A superseding fresh announce resets the
lifecycle via the existing cancelInFlight re-arm. Existing relay tests drain
the now-second (identical) re-broadcast. Core untouched. RNS Transport.py:592-649.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

### Task 2: Cross-validate the retry constants against genuine RNS

**Files:**
- Modify: `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py`, `.../transport_fixtures.json` (regenerated), `.../TransportVectorFixtures.swift`, `.../TransportCrossValidationTests.swift`.

**Interfaces:**
- Consumes: `Transport.announceMaxRebroadcasts`, `Transport.announceRetryGrace` (from Task 1).

- [ ] **Step 1: Emit RNS's constants into the fixture**

In `generate_transport_fixtures.py`, add two keys to the `json.dumps({...})` dict:

```python
    "local_rebroadcasts_max": RNS.Transport.LOCAL_REBROADCASTS_MAX,
    "pathfinder_g": RNS.Transport.PATHFINDER_G,
```

- [ ] **Step 2: Regenerate the fixture**

Run (single command, `>` redirect): `/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATransportTests/Vectors/transport_fixtures.json`
Confirm: `grep -c local_rebroadcasts_max /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATransportTests/Vectors/transport_fixtures.json` → `1`. (Regeneration re-rolls the other fixture values — expected; siblings read from the JSON, so the suite stays green.)

- [ ] **Step 3: Decode the new fields**

In `TransportVectorFixtures.swift`, add properties and CodingKeys:

```swift
    let localRebroadcastsMax: Int
    let pathfinderG: Double
```
```swift
        case localRebroadcastsMax = "local_rebroadcasts_max"
        case pathfinderG = "pathfinder_g"
```

- [ ] **Step 4: Add the parity test**

Append to `TransportCrossValidationTests.swift`:

```swift
/// Our announce retry constants match RNS's LOCAL_REBROADCASTS_MAX and PATHFINDER_G.
@Test func announceRetryConstantsMatchRns() throws {
    let f = try TransportVectorFixtures.load()
    #expect(Transport.announceMaxRebroadcasts == f.localRebroadcastsMax)
    #expect(Transport.announceRetryGrace == f.pathfinderG)
}
```

- [ ] **Step 5: Run it, confirm pass**

Run: `swift test --filter announceRetryConstantsMatchRns`
Expected: pass.

- [ ] **Step 6: Mutation verification**

Change `Transport.announceMaxRebroadcasts` to `3` → run the test → the first `#expect` fails (RNS is 2). Revert → pass. Then change `Transport.announceRetryGrace` to `4.0` → the second `#expect` fails (RNS is 5) → revert → pass. (Transient production mutations for verification only; commit no Sources change.)

- [ ] **Step 7: Full suite**

Run: `swift test`
Expected: all pass.

- [ ] **Step 8: Commit**

Write the message to `/tmp/ReTiCA/commit-t2.txt`; `git add` the generator, JSON, fixture struct, and cross-val test; `git commit -F`.

```
test: cross-validate announce retry constants against RNS

Read RNS Transport.LOCAL_REBROADCASTS_MAX and PATHFINDER_G into the transport
fixture and assert announceMaxRebroadcasts and announceRetryGrace equal them.
Pins the retry cap and grace to genuine RNS.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Notes for the executor

- After both tasks, this slice (4b-3b-2) is done. A final whole-slice review is warranted (retry lifecycle in shared inbound handling), then the full `swift test` gate on `main` and updating the `transport-relaying` memory (4b-3b-2 merged; collaborative suppression + 4b-3c expiry remain).
- Do NOT touch `Sources/ReTiCA/*`. A completed retry lifecycle removes its own `announceTable` entry; longer-lived GC / cancel-on-disconnect is 4b-3c.
- Under `ImmediateClock`, both sends fire immediately; under a `TestClock` the retry waits `grace + jitter`. New timing tests use a `TestClock`; migrated tests use `ImmediateClock` and drain both sends.
