# Jittered Delayed Announce Re-broadcast Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Defer each fresh announce's relay re-broadcast by a random delay in `[0, 0.5)`s (RNS `PATHFINDER_RW`) via a per-destination holding table + clock timer, instead of 4b-3a's immediate synchronous re-broadcast.

**Architecture:** One production file changes: `Sources/ReTiCATransport/Transport.swift`. The `.announce` fresh path keeps blob-dedup, path update, and `pathLearned` immediate, but instead of returning `transmit` effects it stores a `PendingAnnounce` in a new `State.announceTable` and returns a cancellable per-destination timer that fires a new `.announceRetransmitDue` action after a jittered delay; that action emits the (unchanged) re-broadcast to every interface except the arrival one. Reuses `LinkSession`'s clock/cancellation/random-dependency patterns. Introducing a clock breaks existing relay tests that expected a synchronous re-broadcast — they are migrated by injecting a clock (mechanical).

**Tech Stack:** Swift, The Composable Architecture (~1.26): `@Dependency(\.continuousClock)`, `ImmediateClock`/`TestClock`, `.cancellable(id:cancelInFlight:)`, the existing `@Dependency(\.randomBytes)` (`RandomBytesGenerator`). Cross-val constant read from genuine Python-RNS 1.3.8.

## Global Constraints

- Wire-compatible with Python-RNS 1.3.8. Core `Sources/ReTiCA/*` stays zero-dep and **untouched** — changes only in `Sources/ReTiCATransport/*` and `Tests/*`.
- Commit **directly to `main`** — no feature branch. Every commit must leave the FULL suite green (the production change and all test migration land together).
- **No compound shell commands** — one command per shell call (a single `|` pipeline or single `>` redirect allowed). Run `swift build`, `swift test`, `git add`, `git commit` separately. Never inline a script into an interpreter; write it to a file under `/tmp/ReTiCA/` and run the file.
- Temp files under `/tmp/ReTiCA/`.
- **Mutation-testing verification** for every new/changed test: run pass → batch-mutate production so they should fail → confirm fail → revert → confirm pass. If two mutations interact so that one masks another's expected failure, verify those independently (a known caveat).
- Reference RNS at `/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/RNS/`; run its python by absolute path `/Users/ell/opt/anaconda3/envs/rns/bin/python`. Build gotcha: signal-11/SIGILL → `swift package clean` then retry; never delete code to "fix" a crash.
- Commit trailers (exact, both lines, every commit):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```

Spec: `docs/superpowers/specs/2026-07-25-jittered-rebroadcast-design.md`.

## Grounding facts (verified — do not re-derive)

- Current `.announce` fresh re-broadcast tail is `Transport.swift:167-183`: builds a HEADER_2 packet (`transportType: .transport`, `transportId: relayID.hash`, `hops+1`, `payload` verbatim) and appends `.delegate(.transmit($0, rebroadcastRaw))` for `state.interfaces.filter { $0 != interfaceID }`, then `return effects.isEmpty ? .none : .merge(effects)`. Everything above it (own-dest guard, parse, blob-dedup, `shouldReplace` path update + `pathLearned`) stays.
- `Transport` currently has only `@Dependency(\.date) var date` (`Transport.swift:53`) and no `CancelID`. The `Reduce` closure header is `Reduce { state, action in` (`Transport.swift:58`).
- `LinkSession` establishes the exact pattern to copy: `@Dependency(\.continuousClock) var clock`, `@Dependency(\.randomBytes) var randomBytes`, `Reduce { [date, clock, uuid, randomBytes] state, action in`, `private enum CancelID: Hashable { case … }`, and `.run { send in try await clock.sleep(for: .seconds(t)); await send(.x) }.cancellable(id: CancelID.x, cancelInFlight: true)`.
- `RandomBytesGenerator` (`Sources/ReTiCATransport/RandomBytesDependency.swift`): `init(generate: @escaping @Sendable (Int) -> Data)`, `callAsFunction(_ count: Int) -> Data`. Test default is a deterministic ramp (`randomBytes(1)` → `Data([0])`). Override in tests via `$0.randomBytes = RandomBytesGenerator { _ in Data([128]) }`.
- `Action` is `public enum Action: Equatable` with `delegate(Delegate)` where `Delegate.transmit(InterfaceID, Data)`. Adding `case announceRetransmitDue(destinationHash: Data)` is Equatable-safe.
- `ImmediateClock` and `TestClock` come with the existing `import ComposableArchitecture` (already in every test file).
- Test idiom: relay stores are built `TestStore(initialState: Transport.State()) { Transport() } withDependencies: { $0.date = .constant(Date(timeIntervalSince1970: 0)) }`, `store.exhaustivity = .off`, then `.interfaceConnected(...)` ×N + `.setTransportIdentity(id)`. Predicate receives (`store.receive { if case .delegate(.transmit) = $0 { … } }`) under `.off` skip intervening actions, so they still match the transmit after a `.announceRetransmitDue` hop.

## Affected existing tests (schedule a relay re-broadcast → must inject a clock)

Only relay stores with **≥2 interfaces** receiving a **fresh, non-local, under-hop-limit** announce schedule a timer. With the "schedule only if ≥1 other interface" guard (Task 1 Step 2), 1-interface relay tests are exempt. The exact set:
1. `TransportTests.swift` `relayRebroadcastsAnnounceWithHeader2AndOurTransportId` (~line 355 store).
2. `TransportTests.swift` `makeRelayStore` helper (~line 1138) — used by `exactReplayAnnounceIsDroppedAndNotRebroadcast`, `forgeReplayWithMutatedAppDataIsDropped`, `nonImprovingFreshAnnounceIsStillRebroadcast`, `ownDestinationAnnounceIsIgnored` (last schedules nothing but the injection is harmless).
3. `TransportTests.swift` `threeNodeRelayDeliversMessageEndToEnd` (~line 908 `storeR`).
4. `Vectors/RelayCrossValidationTests.swift` `relayRebroadcastsGenuineRnsAnnounceCorrectly` (~line 16 store).
5. `ReTiCANodeTests/EndpointTests.swift` `threeNodeRelayLinkEstablishesAndCarriesData` (~line 1439 `storeR`).

Not affected (verify, do not edit): `relayDoesNotRebroadcastForLocalDestinationOrPastHopLimit` (early-return / hop-limit → no schedule), `relayLearnsNextHopFromHeader2Announce` (1 interface), the `storeWithLearnedPathViaRelay`/`relayStoreKnowingDest*` 1-interface helpers, the `.data`/`.linkRequest`/link-packet forwarding tests (no announce), `blobRingEvictsOldestAfterCapacity` (non-relay), and outbound `announce…`/`announceFansOutToAllInterfaces` (outbound action, unchanged).

---

### Task 1: Defer the re-broadcast with a jittered per-destination timer (+ migrate affected tests)

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift`.
- Test: `Tests/ReTiCATransportTests/TransportTests.swift` (new unit tests + migrate two stores + the helper), `Tests/ReTiCATransportTests/Vectors/RelayCrossValidationTests.swift` (migrate one store), `Tests/ReTiCANodeTests/EndpointTests.swift` (migrate `storeR`).

**Interfaces:**
- Produces: `Transport.State.announceTable: [Data: PendingAnnounce]` (public), `Transport.State.PendingAnnounce{raw:Data, arrivalInterface:InterfaceID}` (public), `static let Transport.announceRebroadcastWindow = 0.5`, `Transport.Action.announceRetransmitDue(destinationHash: Data)` — read by Task 2.

- [ ] **Step 1: Add state, constant, deps, and CancelID**

In `Transport.State` (after `announceBlobs`):

```swift
public struct PendingAnnounce: Equatable, Sendable {
    public var raw: Data
    public var arrivalInterface: InterfaceID
    public init(raw: Data, arrivalInterface: InterfaceID) {
        self.raw = raw; self.arrivalInterface = arrivalInterface
    }
}
/// Fresh announces held for a jittered re-broadcast, keyed by destinationHash (4b-3b-1).
public var announceTable: [Data: PendingAnnounce] = [:]
```

In `Transport` at type scope (near `announceEmitted`):

```swift
/// RNS PATHFINDER_RW (Transport.py:70): the random window for an announce re-broadcast, seconds.
static let announceRebroadcastWindow = 0.5
```

Add deps next to `@Dependency(\.date) var date`:

```swift
@Dependency(\.continuousClock) var clock
@Dependency(\.randomBytes) var randomBytes
```

Add the cancel id at type scope (like `LinkSession`):

```swift
private enum CancelID: Hashable { case announceRetransmit(Data) }
```

Change the `Reduce` header to capture the new deps:

```swift
Reduce { [date, clock, randomBytes] state, action in
```

Add the new case to `Action` (after `send`):

```swift
case announceRetransmitDue(destinationHash: Data)
```

- [ ] **Step 2: Defer the re-broadcast in the `.announce` fresh path**

Replace the current re-broadcast tail (`Transport.swift:167-182`, the `if let relayID = state.transportIdentity, …` block that appends `transmit` effects) with the scheduling block below. The `return effects.isEmpty ? .none : .merge(effects)` line at the end of the case stays.

```swift
                    // Relay mode: instead of re-broadcasting now, HOLD this fresh announce and
                    // re-broadcast it once after a jittered delay in [0, PATHFINDER_RW) — RNS
                    // Transport.py:1925. Only schedule when there is somewhere to send it.
                    if let relayID = state.transportIdentity,
                       Int(packet.hops) + 1 < Int(Packet.maxHops),
                       state.interfaces.contains(where: { $0 != interfaceID }) {
                        let rebroadcast = Packet(
                            headerType: .header2, packetType: .announce, transportType: .transport,
                            destinationType: packet.destinationType, context: packet.context,
                            contextFlag: packet.contextFlag, hops: packet.hops + 1,
                            destinationHash: packet.destinationHash, transportId: relayID.hash,
                            payload: packet.payload)
                        if let rebroadcastRaw = try? rebroadcast.packed() {
                            let destHash = packet.destinationHash
                            state.announceTable[destHash] = State.PendingAnnounce(
                                raw: rebroadcastRaw, arrivalInterface: interfaceID)
                            let jitter = Double(randomBytes(1).first ?? 0) / 256.0
                                * Transport.announceRebroadcastWindow
                            effects.append(.run { send in
                                try await clock.sleep(for: .seconds(jitter))
                                await send(.announceRetransmitDue(destinationHash: destHash))
                            }.cancellable(id: CancelID.announceRetransmit(destHash), cancelInFlight: true))
                        }
                    }
                    return effects.isEmpty ? .none : .merge(effects)
```

- [ ] **Step 3: Handle `.announceRetransmitDue`**

Add a case in the top-level `switch action` (near `.send`):

```swift
            case let .announceRetransmitDue(destinationHash):
                guard let entry = state.announceTable[destinationHash] else { return .none }
                state.announceTable[destinationHash] = nil
                let sends = state.interfaces
                    .filter { $0 != entry.arrivalInterface }
                    .map { Effect<Action>.send(.delegate(.transmit($0, entry.raw))) }
                return sends.isEmpty ? .none : .merge(sends)
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: compiles. (Editor "No such module 'ComposableArchitecture'" is a known false positive; the CLI build is the signal.)

- [ ] **Step 5: Migrate the affected existing stores (inject a clock)**

Add `$0.continuousClock = ImmediateClock()` to the `withDependencies` of each affected store (these tests do not care about jitter timing; `ImmediateClock` makes the sleep complete at once, and their `.off` predicate transmit receives skip the `.announceRetransmitDue` hop):

1. `TransportTests.swift` `relayRebroadcastsAnnounceWithHeader2AndOurTransportId` store (the `withDependencies { $0.date = .constant(Date(timeIntervalSince1970: 0)) }` block).
2. `TransportTests.swift` `makeRelayStore` helper — its `withDependencies` block.
3. `TransportTests.swift` `threeNodeRelayDeliversMessageEndToEnd` — the `storeR` `withDependencies` block.
4. `RelayCrossValidationTests.swift` `relayRebroadcastsGenuineRnsAnnounceCorrectly` — its store's `withDependencies`.
5. `EndpointTests.swift` `threeNodeRelayLinkEstablishesAndCarriesData` — the `storeR` `withDependencies` (line ~1439).

Each edit is the same shape, e.g.:

```swift
    } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = ImmediateClock()
    }
```

- [ ] **Step 6: Run the migrated suite so far**

Run: `swift test`
Expected: all pass. If any relay test now hangs or fails with an unhandled/ in-flight effect, it schedules a timer and needs the same `$0.continuousClock = ImmediateClock()` injection; add it and re-run. (Exhaustive `store.receive(.delegate(.transmit(...)))` calls that don't skip would additionally need an `await store.receive(\.announceRetransmitDue)` before the transmit — but the affected set uses `.off` predicate receives, so injection alone suffices.)

- [ ] **Step 7: Add the new unit tests**

Append to `Tests/ReTiCATransportTests/TransportTests.swift`:

```swift
// MARK: - 4b-3b-1 jittered delayed re-broadcast

/// A relay with two interfaces and a controllable clock/jitter.
@MainActor
private func makeTimedRelayStore(_ relay: Identity, _ clock: TestClock<Duration>, jitterByte: UInt8)
    async -> TestStore<Transport.State, Transport.Action> {
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = clock
        $0.randomBytes = RandomBytesGenerator { _ in Data([jitterByte]) }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setTransportIdentity(relay))
    return store
}

/// A fresh announce learns the path immediately but re-broadcasts only after the jitter elapses,
/// to every interface except the arrival one, with the 4b-1 HEADER_2 bytes.
@Test @MainActor func freshAnnounceRebroadcastIsDeferredUntilJitterElapses() async {
    let relay = Identity()
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeTimedRelayStore(relay, clock, jitterByte: 128)   // 128/256 * 0.5 = 0.25s
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    // Path learned + held, but NOT yet re-broadcast.
    #expect(store.state.learned[destHash] != nil)
    #expect(store.state.announceTable[destHash] != nil)
    await clock.advance(by: .seconds(0.24))
    #expect(store.state.announceTable[destHash] != nil)   // still holding, just before deadline
    await clock.advance(by: .seconds(0.01))               // reach 0.25s → fire
    let out = LockIsolated<(InterfaceID, Data)?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(i, d)) = action { out.setValue((i, d)); return true }
        return false
    }
    #expect(out.value?.0 == InterfaceID("i1"))            // to the OTHER interface only
    #expect(store.state.announceTable[destHash] == nil)   // entry removed after the single send
    let rb = Packet(raw: out.value!.1)!
    #expect(rb.headerType == .header2)
    #expect(rb.transportId == relay.hash)
    #expect(Int(rb.hops) == 3)
}

/// The maximum jitter byte still yields a delay strictly inside the window (< PATHFINDER_RW).
@Test @MainActor func maxJitterByteStaysWithinWindow() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeTimedRelayStore(Identity(), clock, jitterByte: 255)  // 255/256*0.5 ≈ 0.498s
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await clock.advance(by: .seconds(0.49))
    #expect(store.state.announceTable[destHash] != nil)   // not yet (~0.498s)
    await clock.advance(by: .seconds(0.01))               // 0.50s > 0.498 → fired (delay < window)
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.announceTable[destHash] == nil)
}

/// A second fresh announce for the same destination within the window supersedes the first: the
/// single re-broadcast carries the newer announce's payload.
@Test @MainActor func secondFreshAnnounceSupersedesPendingRebroadcast() async {
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
    await store.send(.received(InterfaceID("i0"), a2))    // newer → replaces the held entry, re-arms
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    let out = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(_, d)) = action { out.setValue(d); return true }
        return false
    }
    #expect(Packet(raw: out.value!)!.payload == Packet(raw: a2)!.payload)   // newer superseded
    #expect(store.state.announceTable[destHash] == nil)
}

/// A non-relay node never holds or re-broadcasts an announce.
@Test @MainActor func nonRelayNodeDoesNotScheduleRebroadcast() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0)); $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    // No setTransportIdentity → leaf.
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.announceTable.isEmpty)            // nothing held
}

/// A relay with only one interface has nowhere to re-broadcast, so it schedules nothing.
@Test @MainActor func singleInterfaceRelayDoesNotSchedule() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0)); $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("only")))
    await store.send(.setTransportIdentity(Identity()))
    await store.send(.received(InterfaceID("only"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.announceTable[destHash] == nil)  // no other interface → not held
}
```

- [ ] **Step 8: Run the new tests, confirm pass**

Run: `swift test --filter TransportTests`
Expected: all pass.

- [ ] **Step 9: Mutation verification**

Apply these mutations and confirm the mapped tests fail; if any pair masks, verify those two independently:
1. Re-broadcast immediately again — replace the whole scheduling block (Step 2) with the pre-4b-3b immediate `effects.append(contentsOf: state.interfaces.filter { $0 != interfaceID }.map { Effect<Action>.send(.delegate(.transmit($0, rebroadcastRaw))) })` → `freshAnnounceRebroadcastIsDeferredUntilJitterElapses` and `maxJitterByteStaysWithinWindow` fail (transmit arrives before the clock advance; `announceTable` never populated).
2. Drop the `state.interfaces.contains(where: { $0 != interfaceID })` guard → `singleInterfaceRelayDoesNotSchedule` fails (an entry is held).
3. Don't replace on the second announce — guard the table write with `if state.announceTable[destHash] == nil` → `secondFreshAnnounceSupersedesPendingRebroadcast` fails (re-broadcast carries `a1`'s payload).
4. Halve the jitter (`/ 512.0`) → `freshAnnounceRebroadcastIsDeferredUntilJitterElapses` fails (fires at 0.125, so still held-check or the boundary breaks).

Run: `swift test --filter TransportTests`. Then revert all and re-run — expect all pass.

- [ ] **Step 10: Full suite**

Run: `swift test`
Expected: all pass (baseline before this slice: 327 pass / 1 skip; net +6 new tests here, minus none removed → ~333 / 1 skip). If a stray relay test fails, apply the Step 5 clock injection.

- [ ] **Step 11: Commit**

Write the message to `/tmp/ReTiCA/commit-t1.txt`, `git add` the changed production + test files, `git commit -F`.

```
feat: hold fresh announces for a jittered re-broadcast (PATHFINDER_RW)

Defer each fresh relay announce's re-broadcast by a random delay in
[0, PATHFINDER_RW=0.5)s via a per-destination announceTable + a cancellable
clock timer firing .announceRetransmitDue, instead of an immediate synchronous
send. Path learning, blob-dedup, and pathLearned stay immediate; the
re-broadcast count is unchanged (one per fresh announce), only the timing.
A second fresh announce for the same destination supersedes and re-arms; a
relay with no other interface schedules nothing. Existing relay tests migrated
to inject a clock. Core untouched. RNS Transport.py:1925.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

### Task 2: Cross-validate the jitter window constant against genuine RNS

**Files:**
- Modify: `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py`, `.../transport_fixtures.json` (regenerated), `.../TransportVectorFixtures.swift`, `.../TransportCrossValidationTests.swift`.

**Interfaces:**
- Consumes: `Transport.announceRebroadcastWindow` (from Task 1).

- [ ] **Step 1: Emit RNS's constant into the fixture**

In `generate_transport_fixtures.py`, add one key to the `json.dumps({...})` dict, reading the genuine RNS constant:

```python
    "pathfinder_rw": RNS.Transport.PATHFINDER_RW,
```

- [ ] **Step 2: Regenerate the fixture**

Run (single command, `>` redirect): `/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATransportTests/Vectors/transport_fixtures.json`
Confirm: `grep -c pathfinder_rw /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATransportTests/Vectors/transport_fixtures.json` → `1`. (Regeneration re-rolls the other fixture values — expected; sibling tests read from the same JSON, so the full suite stays green.)

- [ ] **Step 3: Decode the new field**

In `TransportVectorFixtures.swift`, add a property and CodingKey:

```swift
    let pathfinderRw: Double
```
```swift
        case pathfinderRw = "pathfinder_rw"
```

- [ ] **Step 4: Add the parity test**

Append to `TransportCrossValidationTests.swift`:

```swift
/// Our announce re-broadcast jitter window equals RNS's PATHFINDER_RW, and the jitter mapping keeps
/// every possible delay strictly within [0, window).
@Test @MainActor func announceRebroadcastWindowMatchesRnsPathfinderRw() throws {
    let f = try TransportVectorFixtures.load()
    #expect(Transport.announceRebroadcastWindow == f.pathfinderRw)
    // Delay for any random byte 0…255 is byte/256 * window ∈ [0, window).
    let maxDelay = Double(255) / 256.0 * Transport.announceRebroadcastWindow
    #expect(maxDelay < Transport.announceRebroadcastWindow)
    #expect(maxDelay >= 0)
}
```

- [ ] **Step 5: Run it, confirm pass**

Run: `swift test --filter announceRebroadcastWindowMatchesRnsPathfinderRw`
Expected: pass.

- [ ] **Step 6: Mutation verification**

Change `Transport.announceRebroadcastWindow` to `0.4` → run the test → `#expect(Transport.announceRebroadcastWindow == f.pathfinderRw)` fails (RNS is 0.5). Revert → pass. (Corrupting the fixture's `pathfinder_rw` nibble is not used here — restore only by regenerating; the constant mutation is the cleaner guard.)

- [ ] **Step 7: Full suite**

Run: `swift test`
Expected: all pass.

- [ ] **Step 8: Commit**

Write the message to `/tmp/ReTiCA/commit-t2.txt`; `git add` the generator, JSON, fixture struct, and cross-val test; `git commit -F`.

```
test: cross-validate announce jitter window against RNS PATHFINDER_RW

Read RNS Transport.PATHFINDER_RW into the transport fixture and assert
announceRebroadcastWindow equals it, plus that the byte→delay mapping stays
within [0, window). Pins the jitter window to genuine RNS without pretending
to byte-match a random value.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Notes for the executor

- After both tasks, this slice (4b-3b-1) is done. A final whole-slice review is warranted (new timer machinery in shared inbound handling), then the full `swift test` gate on `main` and updating the `transport-relaying` memory (4b-3b-1 merged; 4b-3b-2 suppression + 4b-3b-3 retries + 4b-3c expiry remain).
- Do NOT touch `Sources/ReTiCA/*`. The `announceTable` holds at most one entry per destination and each entry is removed when its single re-broadcast fires or is superseded — no unbounded growth here (longer-lived GC is 4b-3c).
