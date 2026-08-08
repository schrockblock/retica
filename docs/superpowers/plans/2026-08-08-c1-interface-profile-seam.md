# C1 — Interface Profile Seam Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every ReTiCA interface an `InterfaceProfile` (name / bitrate / mode / HW_MTU), carry it into `Transport`, and make path expiry mode-dependent — the first slice of RNS interface conformance (spec: `docs/superpowers/specs/2026-08-04-rns-interface-conformance-design.md`).

**Architecture:** A pure `InterfaceProfile` model in `ReTiCATransport`; `Transport.State.interfaces` becomes `[InterfaceID: InterfaceProfile]` and `.interfaceConnected` carries the profile; the two endpoints thread a defaulted profile from their `State`; `maintenanceTick`'s path-expiry sweep branches on the learned path's interface mode. No relay-behaviour change (that is C2), no pacing (C3).

**Tech Stack:** Swift 6 / TCA (swift-composable-architecture) / swift-testing. Repo: `/Users/ell/development/ios/pods/ReTiCA`.

## Global Constraints

- Commit directly to `main`. No branches, merges, rebases, or resets.
- The user commits to this repo CONCURRENTLY. `git add` ONLY the files your task names — never `-A`, never `.`, never a file you did not create or the task does not list.
- Never chain shell commands: one command per Bash invocation — no `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, no `python -c`/`bash -c`/heredoc-into-interpreter. Multi-step processing = write a script under `/tmp/ReTiCA/` and run it as one command.
- Commit trailers MUST start at column 0:
```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
```
- Mutation discipline on every task: tests pass → apply the task's mutations → confirm the EXPECTED tests fail (and note where they fail) → revert → confirm pass. Mutations are designed below to not mask one another; apply them exactly as specified.
- A clean full run is currently ~660 tests, all green. There are NO pre-existing failures. `PNNode*`/`LXMFNodeSync*` have shown transient parallelism flakes — re-run in isolation with `--filter` to classify, and report actual numbers.
- Spec values are copied from reference RNS and are not negotiable: mode raw values 0x01–0x07 (`Interface.py:45-51`); presets tcp = 10_000_000 bps / HW_MTU 262_144, ble = 80_000 / 1196, default = 62_500 / nil; `announceCap` default 0.02 (a FRACTION, never a percent); expiries AP = 86_400 s, roaming = 21_600 s, otherwise `Transport.pathExpiry` = 604_800 s.
- If the build behaves inexplicably after edits (signal 11 / stale symbols), run `swift package clean` once and rebuild.

---

### Task 1: InterfaceProfile model

**Files:**
- Create: `Sources/ReTiCATransport/InterfaceProfile.swift`
- Test: `Tests/ReTiCATransportTests/InterfaceProfileTests.swift` (new)

**Interfaces:**
- Consumes: nothing (pure model).
- Produces: `InterfaceMode` (enum, `UInt8` raw values 0x01–0x07, cases `full`, `pointToPoint`, `accessPoint`, `roaming`, `boundary`, `gateway`, `interfaceInternal`) and `InterfaceProfile` (struct: `name: String`, `bitrate: Int`, `mode: InterfaceMode`, `hwMTU: Int?`, `announceCap: Double`; presets `.tcp`, `.ble`, `.default`). Tasks 2–3 use these exact names.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCATransportTests/InterfaceProfileTests.swift`:

```swift
import Testing
@testable import ReTiCATransport

/// Mode raw values are the RNS wire constants (Interface.py:45-51) so the enum can cross a
/// wire format later without a translation table.
@Test func interfaceModeRawValuesMatchReference() {
    #expect(InterfaceMode.full.rawValue == 0x01)
    #expect(InterfaceMode.pointToPoint.rawValue == 0x02)
    #expect(InterfaceMode.accessPoint.rawValue == 0x03)
    #expect(InterfaceMode.roaming.rawValue == 0x04)
    #expect(InterfaceMode.boundary.rawValue == 0x05)
    #expect(InterfaceMode.gateway.rawValue == 0x06)
    #expect(InterfaceMode.interfaceInternal.rawValue == 0x07)
}

/// Preset values are copied verbatim from reference (TCPInterface.py:76,42 / BLEInterface.py:40,41
/// / Interface.py:104-105). announceCap is the FRACTION 0.02 (Reticulum.py:835), never a percent.
@Test func presetsMatchReferenceDeclaredValues() {
    #expect(InterfaceProfile.tcp.bitrate == 10_000_000)
    #expect(InterfaceProfile.tcp.hwMTU == 262_144)
    #expect(InterfaceProfile.tcp.mode == .full)
    #expect(InterfaceProfile.ble.bitrate == 80_000)
    #expect(InterfaceProfile.ble.hwMTU == 1196)
    #expect(InterfaceProfile.ble.mode == .full)
    #expect(InterfaceProfile.default.bitrate == 62_500)
    #expect(InterfaceProfile.default.hwMTU == nil)
    #expect(InterfaceProfile.default.mode == .full)
    for p in [InterfaceProfile.tcp, .ble, .default] {
        #expect(p.announceCap == 0.02)
    }
}

/// The memberwise init defaults mode to .full and announceCap to 0.02, mirroring how every
/// shipped reference interface declares MODE_FULL and inherits the global cap.
@Test func initDefaultsMatchReferenceConventions() {
    let p = InterfaceProfile(name: "x", bitrate: 1200)
    #expect(p.mode == .full)
    #expect(p.hwMTU == nil)
    #expect(p.announceCap == 0.02)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter InterfaceProfileTests`
Expected: FAIL to compile — `InterfaceMode`/`InterfaceProfile` not found.

- [ ] **Step 3: Implement**

Create `Sources/ReTiCATransport/InterfaceProfile.swift`:

```swift
import Foundation

/// RNS interface operating mode. Raw values are the reference wire constants
/// (RNS Interface.py:45-51). `internal` is a Swift keyword, hence `interfaceInternal`.
public enum InterfaceMode: UInt8, Equatable, Sendable {
    case full              = 0x01
    case pointToPoint      = 0x02
    case accessPoint       = 0x03
    case roaming           = 0x04
    case boundary          = 0x05
    case gateway           = 0x06
    case interfaceInternal = 0x07
}

/// Per-interface metadata an endpoint declares when registering an interface with Transport.
/// Mode is CONFIGURATION, not an interface property — every shipped reference interface
/// hardcodes MODE_FULL and config overwrites it (Reticulum.py:736,911) — so the profile is
/// supplied at registration, keeping interface reducers mechanism-only.
public struct InterfaceProfile: Equatable, Sendable {
    public var name: String
    /// Bits per second. Zero/negative is a programmer error, not "unknown": reference RNS
    /// silently hard-blocks all announce relay on a nil/0 bitrate (Transport.py:1282).
    public var bitrate: Int
    public var mode: InterfaceMode
    public var hwMTU: Int?
    /// Fraction of bandwidth for relayed announces — 0.02 = 2%, NEVER a percent. Reference has
    /// a lazy-init bug storing the raw `2` (Interface.py:322-323); we store the fraction once.
    public var announceCap: Double

    public init(name: String, bitrate: Int, mode: InterfaceMode = .full,
                hwMTU: Int? = nil, announceCap: Double = 0.02) {
        precondition(bitrate > 0, "InterfaceProfile.bitrate must be > 0")
        precondition(announceCap > 0 && announceCap <= 1,
                     "announceCap is a fraction in (0, 1], e.g. 0.02 — not a percent")
        self.name = name
        self.bitrate = bitrate
        self.mode = mode
        self.hwMTU = hwMTU
        self.announceCap = announceCap
    }

    /// Reference TCPInterface declared values (TCPInterface.py:76, 42).
    public static let tcp = InterfaceProfile(name: "tcp", bitrate: 10_000_000, hwMTU: 262_144)
    /// Reference (fork) BLEInterface declared values (BLEInterface.py:40, 41).
    public static let ble = InterfaceProfile(name: "ble", bitrate: 80_000, hwMTU: 1196)
    /// Reference base-class defaults (Interface.py:104-105).
    public static let `default` = InterfaceProfile(name: "default", bitrate: 62_500)
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter InterfaceProfileTests`
Expected: 3 PASS.

- [ ] **Step 5: Mutation verification (batch)**

Apply both at once: (1) change `.tcp`'s bitrate to `62_500`; (2) change `InterfaceMode.roaming`'s raw value to `0x05` and `boundary` to `0x04` (swap).
Run: `swift test --filter InterfaceProfileTests`
Expected: `presetsMatchReferenceDeclaredValues` fails (mutation 1) AND `interfaceModeRawValuesMatchReference` fails (mutation 2) — they exercise disjoint code, so neither can mask the other. Revert both; re-run; 3 PASS.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCA/c1-task1-msg.txt` (subject `feat: InterfaceProfile model (RNS per-interface metadata)`), then:

```bash
git add Sources/ReTiCATransport/InterfaceProfile.swift Tests/ReTiCATransportTests/InterfaceProfileTests.swift
git commit -F /tmp/ReTiCA/c1-task1-msg.txt
```

---

### Task 2: The seam — Transport carries profiles, endpoints supply them

This task is one atomic compile unit: changing the action shape breaks the endpoints' send sites, so production and the enumerated test edits land together. It is mechanical; every site is listed. **No behaviour changes** — the suite must end exactly as green as it started.

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (state :30, action :90, handlers :146-151, reads :270, :356, :428-429, :481, :494)
- Modify: `Sources/ReTiCANode/TCPEndpoint.swift` (State + init :35-41, send site :112)
- Modify: `Sources/ReTiCANode/BLEEndpoint.swift` (State + init :42-46, send site :121)
- Test (modify): `Tests/ReTiCATransportTests/TransportTests.swift`, `Tests/ReTiCANodeTests/BLEEndpointTests.swift`, `Tests/ReTiCANodeTests/TCPEndpointTests.swift`, `Tests/ReTiCANodeTests/BLEEndpointIntegrationTests.swift`

**Interfaces:**
- Consumes: `InterfaceProfile` / `InterfaceMode` from Task 1 (`.tcp`, `.ble`, `.default` presets).
- Produces: `Transport.State.interfaces: [InterfaceID: InterfaceProfile]`; `Transport.Action.interfaceConnected(InterfaceID, InterfaceProfile)`; `TCPEndpoint.State.profile` / `BLEEndpoint.State.profile`. Task 3 reads `state.interfaces[entry.interfaceID]?.mode`.

- [ ] **Step 1: Transport production changes**

In `Sources/ReTiCATransport/Transport.swift`:

State (line 30):
```swift
public var interfaces: [InterfaceID: InterfaceProfile] = [:]
```

Action (line 90):
```swift
case interfaceConnected(InterfaceID, InterfaceProfile)
```
(`interfaceDisconnected(InterfaceID)` is unchanged.)

Handlers (lines 146-151):
```swift
case let .interfaceConnected(id, profile):
    state.interfaces[id] = profile
    return .none

case let .interfaceDisconnected(id):
    state.interfaces[id] = nil
    return .none
```

Read-site migrations (each is exact; find by the quoted original):

| original | replacement |
|---|---|
| `state.interfaces.contains(where: { $0 != interfaceID })` (≈:270) | `state.interfaces.keys.contains(where: { $0 != interfaceID })` |
| `let sends = state.interfaces.filter { $0 != interfaceID }` (≈:356) | `let sends = state.interfaces.keys.filter { $0 != interfaceID }` |
| `let sends = state.interfaces` / `.filter { $0 != entry.arrivalInterface }` (≈:428-429) | insert `.keys` before `.filter` |
| `state.interfaces.map { .send(.delegate(.transmit($0, raw))) }` (≈:481) | `state.interfaces.keys.map { .send(.delegate(.transmit($0, raw))) }` |
| `let sends = state.interfaces.map { Effect<Action>.send(.delegate(.transmit($0, raw))) }` (≈:494) | insert `.keys` before `.map` |

There are exactly five read sites plus the two handlers; a final `grep -n "state.interfaces" Sources/ReTiCATransport/Transport.swift` must show only the declaration, the two handlers, and five `.keys` uses.

- [ ] **Step 2: Endpoint production changes**

`Sources/ReTiCANode/TCPEndpoint.swift` — add to `State` (after `public let interfaceID: InterfaceID`, line 22):
```swift
/// Metadata registered with Transport for this interface (C1). Mode/bitrate are
/// configuration — override at init to declare e.g. a roaming node.
public let profile: InterfaceProfile
```
Extend the init (lines 35-41):
```swift
public init(host: String, port: UInt16, reconnectOnDrop: Bool = true,
            interfaceID: InterfaceID = InterfaceID("tcp"),
            profile: InterfaceProfile = .tcp) {
    self.interface = TCPClientInterface.State(host: host, port: port,
                                              reconnectOnDrop: reconnectOnDrop)
    self.transport = Transport.State()
    self.interfaceID = interfaceID
    self.profile = profile
}
```
Send site (line 112): `.send(.transport(.interfaceConnected(id)))` → `.send(.transport(.interfaceConnected(id, state.profile)))`.
Check whether `id` is captured as `let id = state.interfaceID` before the switch — if the closure captures only `id`, reference `state.profile` directly in the case (the reducer closure has `state` in scope).

`Sources/ReTiCANode/BLEEndpoint.swift` — add to `State` (after `var peerInterfaces`, line 29):
```swift
/// Profile registered for EVERY peer interface (C1). BLE registers one InterfaceID per
/// peer; all share the endpoint's profile — per-peer variation is a spec non-goal
/// (BLEHello carries no such field).
public let profile: InterfaceProfile
```
Extend the init (lines 42-46):
```swift
public init(maxPeers: Int = BLEInterface.defaultMaxPeers,
            pairingMode: BLEPairingMode = .open,
            profile: InterfaceProfile = .ble) {
    self.ble = BLEInterface.State(maxPeers: maxPeers, pairingMode: pairingMode)
    self.transport = Transport.State()
    self.profile = profile
}
```
Send site (line 121): `.send(.transport(.interfaceConnected(id)))` → `.send(.transport(.interfaceConnected(id, state.profile)))`.

Downstream consumers (`TransportEndpoint`, `LXMFNode`, `PNNode`, `LXMFServiceNode`) need ZERO changes — the profile defaults inside the endpoint inits and none of them constructs `interfaceConnected` values. Do not touch them.

- [ ] **Step 3: Test-target shim (ReTiCATransportTests only)**

At the top of `Tests/ReTiCATransportTests/TransportTests.swift` (after the imports):

```swift
// C1 shim: the case gained a profile payload; ~54 construction sites in this module
// (including Vectors/RelayCrossValidationTests) predate it and don't care which profile.
// A static func with the case's base name resolves the one-argument spelling.
// TESTS ONLY — production must always pass a profile explicitly.
extension Transport.Action {
    static func interfaceConnected(_ id: InterfaceID) -> Self {
        .interfaceConnected(id, .default)
    }
}
```

- [ ] **Step 4: Enumerated test edits**

`Tests/ReTiCATransportTests/TransportTests.swift` (state-mutation assertions — construction sites are covered by the shim):
- `:51` — `$0.interfaces = [InterfaceID("i1")]` → `$0.interfaces = [InterfaceID("i1"): .default]`
- `:57` — `$0.interfaces = []` → `$0.interfaces = [:]`
- `:192` — closure → `{ $0.interfaces = [InterfaceID("i1"): .default] }`
- `:521` — closure → `{ $0.interfaces = [InterfaceID("i1"): .default] }`
- `:522` — closure → `{ $0.interfaces = [InterfaceID("i1"): .default, InterfaceID("i2"): .default] }`
- `:1041` — `initialState.interfaces = [InterfaceID(rcvdIf), InterfaceID(nhIf)]` → `= [InterfaceID(rcvdIf): .default, InterfaceID(nhIf): .default]`
- `:2201` — `initial.interfaces = [InterfaceID("i0"), InterfaceID("i1")]` → `= [InterfaceID("i0"): .default, InterfaceID("i1"): .default]`

`Tests/ReTiCANodeTests/BLEEndpointTests.swift` — these use FULL-EQUALITY receives, so they now assert the endpoint threads its profile (a genuine coverage gain, not churn):
- `:39-40`, `:49-50`, `:74`, `:89`, `:107` — `store.receive(.transport(.interfaceConnected(idX)))` → `store.receive(.transport(.interfaceConnected(idX, .ble)))`; their closures `$0.transport.interfaces.insert(idX)` → `$0.transport.interfaces[idX] = .ble`
- `:57-58`, `:62-63`, `:79`, `:98`, `:116` — disconnect receives keep their shape; closures `$0.transport.interfaces.remove(idX)` → `$0.transport.interfaces[idX] = nil`

`Tests/ReTiCANodeTests/TCPEndpointTests.swift`:
- `:48` — `#expect(store.state.transport.interfaces.contains(store.state.interfaceID))` → `#expect(store.state.transport.interfaces[store.state.interfaceID] == .tcp)` (upgraded from membership to profile equality — this is what catches a TCP endpoint threading the wrong profile)

`Tests/ReTiCANodeTests/BLEEndpointIntegrationTests.swift`:
- `:70` — `.contains(bleInterfaceID(peerToken))` → `#expect(store.state.transport.interfaces[bleInterfaceID(peerToken)] == .ble)`

No other file changes: `TCPEndpointTests`' ~32 remaining sites and all `LXMF*`/`BLEEndpointLink*` sites use key-path (`\.transport.interfaceConnected`) or case-only predicates, which match any payload.

- [ ] **Step 5: Full suite**

Run: `swift test`
Expected: everything green, same count as before the task (no new tests in this task; the assertion upgrades replace existing ones 1:1). Classify any `PNNode*`/`LXMFNodeSync*` failure by isolated re-run before believing it.

- [ ] **Step 6: Mutation verification (batch — designed non-masking)**

Apply all three at once; each is caught by a different test file, none prevents the others' tests from running:
1. `Transport.swift` `interfaceConnected` handler: store `state.interfaces[id] = .default` ignoring the payload → `BLEEndpointTests` profile-equality closures fail (`.ble` ≠ `.default`) while everything else still passes.
2. `TCPEndpoint.swift` send site: pass `.ble` instead of `state.profile` → `TCPEndpointTests:48` profile-equality fails.
3. `Transport.swift` `interfaceDisconnected` handler: `return .none` without removing → `BLEEndpointTests` disconnect closures fail (state diff shows the lingering entry).

Run: `swift test --filter BLEEndpointTests`, then `swift test --filter TCPEndpointTests`.
Expected: the named failures, and ONLY those. Revert all three; re-run both filters green; then full `swift test` green.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/c1-task2-msg.txt` (subject `feat: Transport carries per-interface profiles; endpoints supply them`), then:

```bash
git add Sources/ReTiCATransport/Transport.swift Sources/ReTiCANode/TCPEndpoint.swift Sources/ReTiCANode/BLEEndpoint.swift Tests/ReTiCATransportTests/TransportTests.swift Tests/ReTiCANodeTests/BLEEndpointTests.swift Tests/ReTiCANodeTests/TCPEndpointTests.swift Tests/ReTiCANodeTests/BLEEndpointIntegrationTests.swift
git commit -F /tmp/ReTiCA/c1-task2-msg.txt
```

---

### Task 3: Mode-based path expiry

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (constants ≈:504; `maintenanceTick` sweep ≈:408-415)
- Test: `Tests/ReTiCATransportTests/TransportTests.swift` (add tests near the existing expiry test at :1620)

**Interfaces:**
- Consumes: `state.interfaces[entry.interfaceID]?.mode` (Task 2); `LearnedDestination.interfaceID` / `.learnedAt` (existing); the existing test pattern from `expiredPathAndBlobsAreSweptByMaintenanceTick` (TransportTests.swift:1620-1649): `TestClock` + `$0.transportDate = DateGenerator { now.value }` + `makeAnnouncePacket(hops:emitted:)`.
- Produces: `Transport.apPathExpiry`, `Transport.roamingPathExpiry`, `Transport.pathExpiry(forMode:)`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ReTiCATransportTests/TransportTests.swift`, after the existing test at :1649. Model each on `expiredPathAndBlobsAreSweptByMaintenanceTick` (:1620-1649) — same store setup, same clock/date pattern. The one addition: connect the arrival interface with a mode-bearing profile BEFORE delivering the announce, so the learned path's `interfaceID` has a profile to consult.

```swift
/// A path learned on an ACCESS-POINT interface expires after 1 day (RNS AP_PATH_TIME,
/// Transport.py:787-792), not the 7-day default.
@Test @MainActor func accessPointPathExpiresAfterOneDay() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    let ap = InterfaceProfile(name: "ap", bitrate: 62_500, mode: .accessPoint)
    await store.send(.interfaceConnected(InterfaceID("i0"), ap))
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))

    await store.send(.startMaintenance)
    // Just inside the AP window: survives.
    now.setValue(Date(timeIntervalSince1970: Transport.apPathExpiry - 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.learned[destHash] != nil)
    // Just past it: swept — days before the 7-day default would fire.
    now.setValue(Date(timeIntervalSince1970: Transport.apPathExpiry + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.learned[destHash] == nil)
    #expect(store.state.announceBlobs[destHash] == nil)   // blob GC piggybacks (spec)
    #expect(store.state.announceCache[destHash] == nil)
    await store.send(.stopMaintenance)
}

/// A path learned on a ROAMING interface expires after 6 hours (RNS ROAMING_PATH_TIME).
@Test @MainActor func roamingPathExpiresAfterSixHours() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    let roaming = InterfaceProfile(name: "cell", bitrate: 80_000, mode: .roaming)
    await store.send(.interfaceConnected(InterfaceID("i0"), roaming))
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))

    await store.send(.startMaintenance)
    now.setValue(Date(timeIntervalSince1970: Transport.roamingPathExpiry - 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.learned[destHash] != nil)
    now.setValue(Date(timeIntervalSince1970: Transport.roamingPathExpiry + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.learned[destHash] == nil)
    await store.send(.stopMaintenance)
}

/// A path on a FULL-mode interface is NOT shortened: it survives past both the AP and roaming
/// windows and holds to the 7-day default. Proves the sweep branches per-path rather than
/// globally shortening.
@Test @MainActor func fullModePathSurvivesShortWindows() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0"), .default))   // mode .full
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))

    await store.send(.startMaintenance)
    now.setValue(Date(timeIntervalSince1970: Transport.apPathExpiry + 1))       // past AP window
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.learned[destHash] != nil)
    now.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))         // past 7 days
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.learned[destHash] == nil)
    await store.send(.stopMaintenance)
}
```

The disconnected-interface fallback is already covered: `expiredPathAndBlobsAreSweptByMaintenanceTick` (:1620) learns its path on `InterfaceID("i0")` WITHOUT ever connecting it, and asserts survival at t=100 and sweep at `pathExpiry + 1` — exactly the "no profile → 7-day default" branch. Do not duplicate it; add this comment above that test's `@Test` line:

```swift
/// (C1) Also covers the mode-fallback branch: i0 is never connected, so the sweep finds no
/// profile and must use the 7-day default rather than expiring early.
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TransportTests`
Expected: FAIL to compile — `Transport.apPathExpiry` / `Transport.roamingPathExpiry` not defined.

- [ ] **Step 3: Implement**

In `Sources/ReTiCATransport/Transport.swift`, next to `pathExpiry` (≈:504):

```swift
/// Mode-dependent path lifetimes (RNS Transport.py:787-792).
static let apPathExpiry: TimeInterval = 60 * 60 * 24       // AP_PATH_TIME, 1 day
static let roamingPathExpiry: TimeInterval = 60 * 60 * 6   // ROAMING_PATH_TIME, 6 hours

/// Path lifetime for a path learned on an interface of the given mode. nil mode = the
/// interface has disconnected since; fall back to the 7-day default rather than expiring
/// early (a cycling BLE peer must not silently drop paths).
static func pathExpiry(forMode mode: InterfaceMode?) -> TimeInterval {
    switch mode {
    case .accessPoint: return apPathExpiry
    case .roaming:     return roamingPathExpiry
    default:           return pathExpiry
    }
}
```

Rewrite the sweep in `maintenanceTick` (≈:408-415):

```swift
case .maintenanceTick:
    let now = date.now
    for (dest, entry) in state.learned
    where now.timeIntervalSince(entry.learnedAt)
        > Self.pathExpiry(forMode: state.interfaces[entry.interfaceID]?.mode) {
        state.learned[dest] = nil
        state.announceBlobs[dest] = nil          // blob GC piggybacks on path expiry
        state.announceCache[dest] = nil          // cached announce GC piggybacks too
    }
```
(the linkTable and discoveryPathRequests loops below it are untouched.)

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter TransportTests`
Expected: all pass, including the three new tests and the untouched :1620 test.

- [ ] **Step 5: Full suite**

Run: `swift test`
Expected: green, +3 tests over Task 2's count.

- [ ] **Step 6: Mutation verification (batch — designed non-masking)**

Apply both at once:
1. In `pathExpiry(forMode:)`, swap the two short returns (`.accessPoint` → `roamingPathExpiry`, `.roaming` → `apPathExpiry`).
2. In the sweep, replace the per-entry threshold with the constant `Transport.pathExpiry` — BUT since mutation 1 lives inside the function mutation 2 bypasses, apply them to be independently visible: mutation 2 is expressed as changing `state.interfaces[entry.interfaceID]?.mode` to `nil` (force the fallback), which keeps calling the (mutated) function. With both applied, every mode lookup yields nil → the fallback 7-day constant.

Expected with both applied: `accessPointPathExpiresAfterOneDay` FAILS (survives at `apPathExpiry + 1`) and `roamingPathExpiresAfterSixHours` FAILS (survives at `roamingPathExpiry + 1`), while `fullModePathSurvivesShortWindows` and :1620 still pass (fallback = their correct behaviour — they cannot mask the failures because they assert different tests).
Then revert ONLY mutation 2 (restore the mode lookup, keep the swapped returns): `accessPointPathExpiresAfterOneDay` still FAILS (AP now expires at 6 h — swept "just inside" its 1-day window at `apPathExpiry - 1`) and `roamingPathExpiresAfterSixHours` still FAILS (roaming survives to `roamingPathExpiry + 1` under the 1-day threshold) — proving the swap is caught independently of the lookup.
Revert everything; run `swift test --filter TransportTests`; all pass.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/c1-task3-msg.txt` (subject `feat: mode-based path expiry (AP 1 day / roaming 6 h / default 7 days)`), then:

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -F /tmp/ReTiCA/c1-task3-msg.txt
```

---

## Final verification (after Task 3)

- [ ] `swift test` — full suite green; report the exact count.
- [ ] `grep -rn "Set<InterfaceID>" Sources Tests` — NO output.
- [ ] `grep -n "state.interfaces" Sources/ReTiCATransport/Transport.swift` — only: the declaration, the two connect/disconnect handlers, five `.keys` read sites, and the Task 3 mode lookup.
- [ ] `grep -rn "interfaceConnected(id))" Sources` — NO output (every production send passes a profile).
- [ ] `git log --format='%(trailers:key=Claude-Session)' -3` — all three task commits' trailers parse.
- [ ] `git diff <plan-base> HEAD --stat` — only the files named in the three tasks (plus this plan file).
