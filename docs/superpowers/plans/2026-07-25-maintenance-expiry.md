# Maintenance Tick + Path/Link/Blob Expiry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A standing periodic maintenance tick (started by an explicit `.startMaintenance`) that sweeps expired learned paths (and their random-blob rings) and stale `linkTable` entries, bounding table growth.

**Architecture:** Changes in `Sources/ReTiCATransport/Transport.swift` and `Sources/ReTiCATransport/LearnedDestination.swift`. `LearnedDestination` gains `learnedAt`, `LinkTableEntry` gains `refreshedAt` (refreshed on link-packet forward). New actions `startMaintenance` / `stopMaintenance` / `maintenanceTick`; the tick self-reschedules via a `while`-loop and sweeps by `date.now` vs the timestamps. Trigger is explicit (not auto) because the test-default `continuousClock` is unimplemented — so no existing test starts the tick and migration is near-zero.

**Tech Stack:** Swift, The Composable Architecture (~1.26): `@Dependency(\.date)`, `@Dependency(\.continuousClock)`, `TestClock`, `DateGenerator`, `LockIsolated`, `.cancellable`/`.cancel(id:)`.

## Global Constraints

- Wire-compatible with Python-RNS 1.3.8. Core `Sources/ReTiCA/*` stays zero-dep and **untouched** — changes only in `Sources/ReTiCATransport/*` and `Tests/*`.
- Commit **directly to `main`** — no feature branch. Every commit leaves the FULL suite green.
- **No compound shell commands** — one command per shell call (a single `|` pipeline or `>` redirect allowed). Run `swift build`, `swift test`, `git add`, `git commit` separately. Never inline a script into an interpreter; write it to a file under `/tmp/ReTiCA/` and run the file.
- Temp files under `/tmp/ReTiCA/`.
- **Mutation-testing verification** for every new/changed test: run pass → batch-mutate → confirm fail → revert → confirm pass. Verify interacting mutations independently.
- Reference RNS at `/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/RNS/`. Build gotcha: signal-11/SIGILL → `swift package clean` then retry.
- Commit trailers (exact, both lines):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```

Spec: `docs/superpowers/specs/2026-07-25-maintenance-expiry-design.md`.

## Grounding facts (verified — do not re-derive)

- `LearnedDestination` (`Sources/ReTiCATransport/LearnedDestination.swift`): fields `identity, appData, ratchet, interfaceID, hops, nextHop, announceEmitted`; memberwise `init(identity:appData:ratchet:interfaceID:hops:nextHop:announceEmitted:)`.
- `Transport.State.LinkTableEntry` (`Transport.swift:40-47`): `{ rcvdIf: InterfaceID; nhIf: InterfaceID; init(rcvdIf:nhIf:) }`.
- The `.announce` candidate is built at `Transport.swift:198-201` (`LearnedDestination(identity:…announceEmitted: emitted)`).
- The `linkTable` entry is created at `Transport.swift:260` (`state.linkTable[linkID] = State.LinkTableEntry(rcvdIf: interfaceID, nhIf: entry.interfaceID)`).
- The pre-dedup link-forward branch is `Transport.swift:125-140`; a valid forward path is lines 128-137 (after `outIf` is chosen at 130-133, before `var fwd` at 134).
- `Transport` already has `@Dependency(\.date) var date` (`:74`), `@Dependency(\.continuousClock) var clock` (`:75`); the `Reduce` closure captures `[date, clock, randomBytes]`; `private enum CancelID: Hashable { case announceRetransmit(Data) }`.
- **Harness facts (from diagnostics):** a `.off` TestStore tolerates an in-flight standing timer at deinit; a bare TestStore's default `continuousClock` is **unimplemented** (fails on use). Hence the explicit trigger — no existing test is touched.
- Test date wiring for a mutable clock-synced date: `let d = LockIsolated(Date(timeIntervalSince1970: 0)); $0.date = DateGenerator { d.value }` — then `d.setValue(Date(timeIntervalSince1970: X))` mid-test; the sweep reads `date.now == d.value`.
- Existing helpers: `makeAnnouncePacket(hops:emitted:)`, `makeHeader2LinkRequestPacket(transportId:destHash:hops:payload:)`, `Link.linkID(requestPacket:)`, `RandomBytesGenerator`.

---

### Task 1: Maintenance tick + expiry sweep + refresh-on-use

**Files:**
- Modify: `Sources/ReTiCATransport/LearnedDestination.swift`, `Sources/ReTiCATransport/Transport.swift`.
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`.

**Interfaces:**
- Produces: `LearnedDestination.learnedAt: Date`; `Transport.State.LinkTableEntry.refreshedAt: Date`; `static let Transport.pathExpiry: TimeInterval`, `Transport.linkTableExpiry: TimeInterval`, `Transport.maintenanceTickInterval: TimeInterval`; actions `Transport.Action.startMaintenance`, `.stopMaintenance`, `.maintenanceTick` — read by Task 2.

- [ ] **Step 1: Add `learnedAt` to `LearnedDestination` (defaulted)**

In `LearnedDestination.swift`, add the field and default it in the init:

```swift
    public var announceEmitted: UInt64
    public var learnedAt: Date

    public init(identity: Identity, appData: Data?, ratchet: Data?, interfaceID: InterfaceID,
                hops: UInt8, nextHop: Data?, announceEmitted: UInt64,
                learnedAt: Date = Date(timeIntervalSince1970: 0)) {
        self.identity = identity
        self.appData = appData
        self.ratchet = ratchet
        self.interfaceID = interfaceID
        self.hops = hops
        self.nextHop = nextHop
        self.announceEmitted = announceEmitted
        self.learnedAt = learnedAt
    }
```

- [ ] **Step 2: Add `refreshedAt` to `LinkTableEntry` (defaulted)**

Replace `Transport.State.LinkTableEntry` (`Transport.swift:40-47`) with:

```swift
        public struct LinkTableEntry: Equatable, Sendable {
            public var rcvdIf: InterfaceID
            public var nhIf: InterfaceID
            public var refreshedAt: Date
            public init(rcvdIf: InterfaceID, nhIf: InterfaceID,
                        refreshedAt: Date = Date(timeIntervalSince1970: 0)) {
                self.rcvdIf = rcvdIf
                self.nhIf = nhIf
                self.refreshedAt = refreshedAt
            }
        }
```

- [ ] **Step 3: Add the constants and the `CancelID.maintenance` case**

Near the other `static let`s (e.g. next to `announceRetryGrace`):

```swift
    /// RNS DESTINATION_TIMEOUT (Transport.py:91): learned paths expire after one week unused, seconds.
    static let pathExpiry: TimeInterval = 60 * 60 * 24 * 7      // 604800
    /// RNS LINK_TIMEOUT (Transport.py:89 = Link.STALE_TIME * 1.25 = (STALE_FACTOR*KEEPALIVE)*1.25).
    static let linkTableExpiry: TimeInterval = 900              // 720 * 1.25
    /// Sweep cadence — a local tuning constant (NOT wire-visible, NOT cross-validated).
    static let maintenanceTickInterval: TimeInterval = 60
```

In `private enum CancelID`, add `case maintenance`:

```swift
    private enum CancelID: Hashable { case announceRetransmit(Data); case maintenance }
```

- [ ] **Step 4: Add the three actions**

In `Transport.Action` (after the existing cases, e.g. after `announceRetransmitDue`):

```swift
        case startMaintenance
        case stopMaintenance
        case maintenanceTick
```

- [ ] **Step 5: Handle the three actions**

Add these cases to the top-level `switch action` (e.g. near `announceRetransmitDue`):

```swift
            case .startMaintenance:
                return .run { send in
                    while true {
                        try await clock.sleep(for: .seconds(Transport.maintenanceTickInterval))
                        await send(.maintenanceTick)
                    }
                }.cancellable(id: CancelID.maintenance, cancelInFlight: true)

            case .stopMaintenance:
                return .cancel(id: CancelID.maintenance)

            case .maintenanceTick:
                let now = date.now
                for (dest, entry) in state.learned
                where now.timeIntervalSince(entry.learnedAt) > Transport.pathExpiry {
                    state.learned[dest] = nil
                    state.announceBlobs[dest] = nil          // blob GC piggybacks on path expiry
                }
                for (link, entry) in state.linkTable
                where now.timeIntervalSince(entry.refreshedAt) > Transport.linkTableExpiry {
                    state.linkTable[link] = nil
                }
                return .none
```

- [ ] **Step 6: Stamp `learnedAt` on the learned candidate**

At `Transport.swift:198-201`, add `learnedAt: date.now` to the candidate:

```swift
                    let candidate = LearnedDestination(
                        identity: parsed.identity, appData: parsed.appData, ratchet: parsed.ratchet,
                        interfaceID: interfaceID, hops: packet.hops, nextHop: nextHop,
                        announceEmitted: emitted, learnedAt: date.now)
```

- [ ] **Step 7: Stamp `refreshedAt` on link-table creation, and refresh on forward**

At the `linkTable` create site (`Transport.swift:260`):

```swift
                        state.linkTable[linkID] = State.LinkTableEntry(
                            rcvdIf: interfaceID, nhIf: entry.interfaceID, refreshedAt: date.now)
```

In the link-forward branch, refresh the entry's timestamp on a valid forward — insert right after the `else { return .none }` that closes the direction choice (`Transport.swift:133`), before `var fwd = packet`:

```swift
                        else { return .none }
                        state.linkTable[packet.destinationHash]?.refreshedAt = date.now   // keep active links alive
                        var fwd = packet
```

- [ ] **Step 8: Build**

Run: `swift build`
Expected: compiles. (Editor "No such module 'ComposableArchitecture'" is a known false positive.)

- [ ] **Step 9: Run the full suite (no migration expected)**

Run: `swift test`
Expected: all pass unchanged (baseline 342 pass / 1 skip). No existing test sends `.startMaintenance`, so none starts the tick; the defaulted timestamp fields keep existing constructors compiling. If anything fails, STOP and report — the explicit-trigger design predicts zero existing-test impact.

- [ ] **Step 10: Add the expiry tests**

Append to `Tests/ReTiCATransportTests/TransportTests.swift`:

```swift
// MARK: - 4b-3c-1 maintenance tick + expiry

/// An aged-out learned path (and its random-blob ring) is swept once now − learnedAt > pathExpiry;
/// a not-yet-expired path survives an earlier tick.
@Test @MainActor func expiredPathAndBlobsAreSweptByMaintenanceTick() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.date = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.learned[destHash] != nil)
    #expect(store.state.announceBlobs[destHash] != nil)

    await store.send(.startMaintenance)
    // Not yet expired: a tick within the window sweeps nothing.
    now.setValue(Date(timeIntervalSince1970: 100))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.learned[destHash] != nil)
    // Past the expiry: the next tick sweeps the path and its blob ring.
    now.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.learned[destHash] == nil)
    #expect(store.state.announceBlobs[destHash] == nil)
    await store.send(.stopMaintenance)
}

/// A stale relay linkTable entry is swept; an entry refreshed by a link-packet forward survives.
@Test @MainActor func staleLinkEntrySweptButRefreshedSurvives() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let relay = Identity(), remote = Identity()
    let outIf = InterfaceID("i-out")
    let (announceRaw, destHash) = makeAnnouncePacket(identity: remote, appName: "app",
                                                     aspects: ["d"], hops: 1, emitted: 2000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.date = DateGenerator { now.value }
        $0.randomBytes = RandomBytesGenerator { _ in Data([0]) }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(outIf))          // one interface → announce won't re-broadcast
    await store.send(.setTransportIdentity(relay))
    await store.send(.received(outIf, announceRaw))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    // Create a linkTable entry (refreshedAt = 0) via a HEADER_2 LINKREQUEST arriving on "in".
    let payload = Data(repeating: 0x11, count: 64) + Data([0, 0, 0])
    let lr = makeHeader2LinkRequestPacket(transportId: relay.hash, destHash: destHash, hops: 0, payload: payload)
    let linkID = Link.linkID(requestPacket: Packet(raw: lr)!)
    await store.send(.received(InterfaceID("in"), lr))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.linkTable[linkID] != nil)

    // Refresh the entry by forwarding a link packet arriving on rcvdIf ("in") at t = 10.
    now.setValue(Date(timeIntervalSince1970: 10))
    let linkPacket = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                            destinationType: .link, context: .none, contextFlag: false, hops: 0,
                            destinationHash: linkID, transportId: nil, payload: Data([9]))
    await store.send(.received(InterfaceID("in"), try! linkPacket.packed()))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.linkTable[linkID]?.refreshedAt == Date(timeIntervalSince1970: 10))

    await store.send(.startMaintenance)
    // now = expiry+1 (901): age since CREATION(0) = 901 > 900, but age since REFRESH(10) = 891 < 900.
    // So the entry survives ONLY because it was refreshed — the refresh discriminator.
    now.setValue(Date(timeIntervalSince1970: Transport.linkTableExpiry + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.linkTable[linkID] != nil)          // survived: refreshed at 10
    // now = 10 + expiry + 1 (911): age since refresh(10) = 901 > 900 → swept.
    now.setValue(Date(timeIntervalSince1970: 10 + Transport.linkTableExpiry + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.linkTable[linkID] == nil)
    await store.send(.stopMaintenance)
}

/// stopMaintenance cancels the tick — no further sweeps fire.
@Test @MainActor func stopMaintenanceCancelsTheTick() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.date = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    await store.send(.startMaintenance)
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)                  // one tick fired
    await store.send(.stopMaintenance)
    store.exhaustivity = .on                               // any further emitted action now fails at cleanup
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval * 3))  // no tick → cancelled
}
```

> If `Packet`'s initializer labels differ from the above, match the exact construction used elsewhere in this test file. Do NOT invent Packet API. `DateGenerator` and `LockIsolated` come with the existing `import ComposableArchitecture`.

- [ ] **Step 11: Run the new tests**

Run: `swift test --filter TransportTests`
Expected: all pass.

- [ ] **Step 12: Mutation verification**

Apply and confirm the mapped test fails; verify interacting ones independently:
1. Sweep does nothing — comment out the two `state.learned[dest] = nil` / `state.linkTable[link] = nil` removals in `.maintenanceTick` → `expiredPathAndBlobsAreSweptByMaintenanceTick` and `staleLinkEntrySweptButRefreshedSurvives` fail.
2. Blob GC missing — remove only `state.announceBlobs[dest] = nil` → `expiredPathAndBlobsAreSweptByMaintenanceTick` fails on the `announceBlobs[destHash] == nil` assertion.
3. Refresh missing — delete the `state.linkTable[...].refreshedAt = date.now` in the forward branch → `staleLinkEntrySweptButRefreshedSurvives` fails (the entry is swept at the earlier tick because it was never refreshed).
4. stopMaintenance no-op — change `.stopMaintenance` to `return .none` → `stopMaintenanceCancelsTheTick` fails (a tick fires after stop; the `.on` cleanup flags the un-received `.maintenanceTick`).

Run: `swift test --filter TransportTests`. Then revert all and re-run — expect all pass.

- [ ] **Step 13: Full suite**

Run: `swift test`
Expected: all pass (baseline 342 + ~3 new → ~345 / 1 skip).

- [ ] **Step 14: Commit**

Write the message to `/tmp/ReTiCA/commit-t1.txt`, `git add` the changed files, `git commit -F`.

```
feat: maintenance tick sweeps expired paths, blobs, and link entries

Add an explicit .startMaintenance/.stopMaintenance action pair driving a
self-rescheduling .maintenanceTick that removes learned paths (and their
announceBlobs) older than pathExpiry (RNS DESTINATION_TIMEOUT) and linkTable
entries older than linkTableExpiry (RNS LINK_TIMEOUT). LearnedDestination gains
learnedAt (stamped on learn), LinkTableEntry gains refreshedAt (stamped on
create, refreshed on link-packet forward so active links survive). Explicit
trigger keeps existing tests untouched. Core untouched. RNS Transport.py jobs loop.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

### Task 2: Cross-validate the expiry constants against genuine RNS

**Files:**
- Modify: `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py`, `.../transport_fixtures.json` (regenerated), `.../TransportVectorFixtures.swift`, `.../TransportCrossValidationTests.swift`.

**Interfaces:**
- Consumes: `Transport.pathExpiry`, `Transport.linkTableExpiry` (from Task 1).

- [ ] **Step 1: Emit RNS's constants into the fixture**

In `generate_transport_fixtures.py`, add two keys to the `json.dumps({...})` dict:

```python
    "destination_timeout": RNS.Transport.DESTINATION_TIMEOUT,
    "link_timeout": RNS.Transport.LINK_TIMEOUT,
```

- [ ] **Step 2: Regenerate the fixture**

Run (single command, `>` redirect): `/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATransportTests/Vectors/transport_fixtures.json`
Confirm: `grep -c destination_timeout /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATransportTests/Vectors/transport_fixtures.json` → `1`. (Regeneration re-rolls the other fixture values — expected; siblings read from the JSON, so the suite stays green.)

- [ ] **Step 3: Decode the new fields**

In `TransportVectorFixtures.swift`, add properties and CodingKeys:

```swift
    let destinationTimeout: Double
    let linkTimeout: Double
```
```swift
        case destinationTimeout = "destination_timeout"
        case linkTimeout = "link_timeout"
```

- [ ] **Step 4: Add the parity test**

Append to `TransportCrossValidationTests.swift`:

```swift
/// Our path/link expiry constants match RNS's DESTINATION_TIMEOUT and LINK_TIMEOUT.
@Test func expiryConstantsMatchRns() throws {
    let f = try TransportVectorFixtures.load()
    #expect(Transport.pathExpiry == f.destinationTimeout)
    #expect(Transport.linkTableExpiry == f.linkTimeout)
}
```

- [ ] **Step 5: Run it, confirm pass**

Run: `swift test --filter expiryConstantsMatchRns`
Expected: pass. (`DESTINATION_TIMEOUT = 604800`, `LINK_TIMEOUT = 900.0`; both exactly representable, so `==` is safe.)

- [ ] **Step 6: Mutation verification**

Change `Transport.pathExpiry` to `1000` → the first `#expect` fails; revert → pass. Change `Transport.linkTableExpiry` to `1000` → the second `#expect` fails; revert → pass. (Transient production mutations for verification only; commit no Sources change.)

- [ ] **Step 7: Full suite**

Run: `swift test`
Expected: all pass.

- [ ] **Step 8: Commit**

Write the message to `/tmp/ReTiCA/commit-t2.txt`; `git add` the generator, JSON, fixture struct, and cross-val test; `git commit -F`.

```
test: cross-validate expiry constants against RNS

Read RNS Transport.DESTINATION_TIMEOUT and LINK_TIMEOUT into the transport
fixture and assert pathExpiry and linkTableExpiry equal them. Pins the two
load-bearing expiry constants to genuine RNS.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Notes for the executor

- After both tasks, this slice (4b-3c-1) is done. A final whole-slice review is warranted (new standing-timer machinery + shared inbound handling touch for the link refresh), then the full `swift test` gate on `main` and updating the `transport-relaying` memory (4b-3c-1 merged; remaining 4b-3c: cancel announce/retry timers on interface-disconnect/identity-clear + production wiring of `.startMaintenance`; then #4c path requests).
- Do NOT touch `Sources/ReTiCA/*`. The tick is opt-in; nothing auto-starts it in this slice (production wiring — the Node/Endpoint layer sending `.startMaintenance` — is a tracked follow-up, out of scope here).
- `maintenanceTickInterval` (60 s) is a tuning constant and is deliberately NOT cross-validated.
