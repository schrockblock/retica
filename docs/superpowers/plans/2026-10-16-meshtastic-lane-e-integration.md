# Meshtastic Lane E (Integration) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put ReTiCAMsgr on the air through a real Meshtastic radio: fix the two inherited ReTiCA seams (stop semantics, ingress-window reset), add the live `MeshtasticDriver` over MeshtasticKit, prove BLE and the radio coexist on one FCB central, wire the radio slot into the app with the amended stop protocol, and hand the user a hardware checklist.

**Architecture:** Part 1 (ReTiCA) changes `MeshtasticInterface`'s stop path so a stop-initiated offline is reported only after `driver.stop()` returns, makes `Transport` keep an interface's first connect time across re-registration and reconnects, and adds a new `ReTiCAMeshtasticLive` target (the only ReTiCA code importing MeshtasticKit) with `MeshtasticDriver.live(session:)`, a live-session factory and a terminal-aware radio scan. Live tests drive `MeshtasticSession` over FCB's real `BluetoothCentralClient.mocked()` against `MeshtasticMock`. Part 2 (ReTiCAMsgr) adds the radio slot to `syncEndpointNodes` through a small swap state machine (`.stop`, wait for `.radioOffline`, then replace), restarts it in `redialDownNodes`, feeds `MeshtasticStatus`, and switches the interface-up announce to `announceDeliveryOnInterface`. Part 3 is the user's two-radio hardware run.

**Tech Stack:** Swift 6 packages (swift-tools 6.3 / 6.0), The Composable Architecture (TestStore, TestClock, ImmediateClock), Swift Testing (`@Suite`, `@Test`, `#expect`, `withKnownIssue`), CoreBluetoothMock, MeshtasticKit + MeshtasticMock, FCB, conda env `rns` (stock `rns` 1.4.2, `lxmf` 1.1.0) for the hardware run.

**Spec:** `/Users/ell/development/ios/pods/ReTiCA/docs/superpowers/specs/2026-10-16-meshtastic-interface-design.md`. This plan implements **Lane E only** (§7 "Lane E" items 0–4, Contract 2's live value, Contract 3's amended "Stop semantics", §6's lane E ownership and the E-vs-F gate). Lane F (FCB scan ownership + power-off pending ops) is a separate plan: nothing here fixes FCB. Read Contract 3 and §7 before starting any task.

**Spec item → task map:** §7 E.0(a) stop semantics → Task 1. E.0(b) `interfaceConnectedAt` → Task 2. E.1 live adapter + loopback → Tasks 3–5. E.2 coexistence probe → Task 6. E.3 app wiring → Tasks 9–13. E.4 hardware → Tasks 7 (tooling) and 15 (the run). Full suites and fast-forwards → Tasks 8 and 14.

## Global Constraints

- **Paths.** `R` = `/Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration` (ReTiCA worktree, branch `meshtastic-integration`, Part 1). `RMAIN` = `/Users/ell/development/ios/pods/ReTiCA` (ReTiCA main checkout). `A` = `/Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live` (app worktree, branch `meshtastic-live`, Part 2). `AMAIN` = `/Users/ell/development/ios/apps/ReTiCAMsgr`. `CORE` = `A/ReTiCaMsgrCore`. Write every path in full in commands; the letters are only shorthand in this document.
- **Worktree depth.** ReTiCA resolves `../FCB` and (after Task 3) `../MeshtasticKit`, so from `R` both must exist as symlinks in `/Users/ell/development/ios/pods/ReTiCA-worktrees/` (`FCB` already does; Task 1 adds `MeshtasticKit`). A throwaway SPM probe (2026-10-16, `/tmp/ReTiCA/spmprobe`) confirmed two symlinked path packages that both depend on a third path package build with no identity conflict. `CORE/Package.swift` resolves `../../../pods/...`, so `A` must be a sibling of `AMAIN`. Part 2 sees only ReTiCA code that is on `RMAIN`'s `main`.
- **One shell command per Bash call.** No `|`, `&&`, `||`, `;`, no `$(...)` feeding another command, no backticks, no `xargs`, no inline interpreters (`python -c`, `bash -c`, `node -e`, heredocs into an interpreter). Any script is a file. Redirecting ONE command's output to a file (`cmd > /tmp/<dir>/x.log 2>&1`) is allowed; read logs with the Read tool or one `grep`/`tail`. Temp files: Part 1 under `/tmp/meshtastic-integration/`, Part 2 under `/tmp/ReTiCAMsgr-meshtastic-live/` (basenames of the worktrees). Create each with `mkdir -p` first.
- **Running ReTiCA tests:** `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration --filter <SuiteName> > /tmp/meshtastic-integration/<name>.log 2>&1`, with a 600000 ms timeout; the whole package without `--filter` (if it outlives 600000 ms, rerun with `run_in_background: true` and wait for the notice). Swift Testing ends the log with `Test run with N tests ... passed` / `... failed`.
- **Running app core tests:** `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live/ReTiCaMsgrCore --filter <prefix> > /tmp/ReTiCAMsgr-meshtastic-live/<name>.log 2>&1`. Several `--filter` flags OR together. Never run `swift test` and `xcodebuild` at the same time. Known app flake: `deliveryFailedMarksFailedAndReloads` can fail alone under `--filter`; it passes in a full run.
- **Build flakes:** signal 11 / signal 10, or a stale-link failure (spurious `LinkSessionRequestTests` failures), → `swift package --package-path <pkg> clean`, rerun. If an Xcode build dies with ENOSPC, delete `~/Library/Developer/Xcode/DerivedData` (regenerable cache) and retry once.
- **Test verification, for EVERY new or changed test set, before committing (user rule):**
  (a) Run the set; every test passes. If any fails, fix whichever side is wrong first.
  (b) Back up each production file the task names with `cp <file> /tmp/<dir>/<name>.orig`. Apply the task's **combined mutation batch** with the Edit tool, run the set ONCE, and confirm EVERY test in it fails. (Where two mutations edit the same line, or one would hang tests it is not aimed at, the task splits the combined batch into the fewest runs that together cover every test once, and says so.) Then, because batches mask each other (lane A's lesson), apply each **per-clause batch** alone (restore from the `.orig` between batches) and confirm the test(s) it names fail. If any test still passes a mutation meant to break it, the test is not testing what it claims: fix the test and restart at (a).
  (c) Restore every file with `cp /tmp/<dir>/<name>.orig <file>`, confirm `git -C <worktree> diff --stat` lists only the task's files, run the set, all pass. Only then commit. If anything is unexpected at any step, stop and diagnose; never paper over it.
- **Commits.** Stage explicit paths only (never `-A` or `.`). Write the message with the Write tool to `/tmp/<dir>/commit-taskN.txt`, then `git -C <worktree> commit -F /tmp/<dir>/commit-taskN.txt`. No semicolons in messages. Subject `feat:`/`fix:`/`test:`/`docs:`, blank line, body, blank line, then exactly these two lines at **column zero**:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
  ```
  Verify each commit with `git -C <worktree> log -1 "--format=%(trailers:key=Claude-Session)"` (format argument quoted). It must print the session line; if not, `git -C <worktree> commit --amend -F <file>`.
- **Merging.** Commit straight to each repo's `main` by fast-forward at the end of each Part (Task 8 for ReTiCA, Task 14 for the app). No PRs, no merge commits. Leave the worktrees in place.
- **`Package.resolved`.** Task 3 adds swift-protobuf to ReTiCA's graph and Task 9 to the app's: stage `R/Package.resolved` (Task 3), `CORE/Package.resolved` and `A/ReTiCaMsgr.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (Task 9, after an Xcode build has updated it). Stage them in no other task. Never stage `xcuserdata/**` or `.swiftpm/**`.
- **Platforms.** ReTiCA and MeshtasticKit: iOS 17, macOS 13, macCatalyst 17 (spec Contract 1). ReTiCaMsgrCore: iOS 17, macOS 14 (unchanged).
- **Ownership (spec §6).** E owns `R/Package.swift`'s MeshtasticKit dependency and the `ReTiCAMeshtasticLive` target, and inherits item 0's fixes in `MeshtasticInterface.swift`, `TransportEndpoint.swift` (one comment) and `Transport.swift`. In the app E owns `syncEndpointNodes`, `redialDownNodes`, the "will something dial" checks and the `interfaceConnected` re-announce. Never edit anything under `/Users/ell/development/ios/pods/FCB` or `/Users/ell/development/ios/pods/MeshtasticKit` (lanes F and A own them). If a test here exposes a defect there, STOP and report it.
- **E-vs-F gate (spec §6).** Part 1 needs nothing from lane F; its scan-interference probes are written as `withKnownIssue` until F lands. Task 13 (live radio scanner, the only thing that opens the picker alongside a running BLE slot) is gated: it begins with a STOP step on FCB's log.
- **TCA test rules.** Inject clocks; never a live clock in a reducer test. Transport timers: `$0.continuousClock = TestClock()` (an ImmediateClock spins the maintenance loop hot). Interface pacing: `$0.meshtasticClock = ImmediateClock()` or `TestClock()`. `\.date` has no usable testValue: set `$0.date = .constant(...)`; Transport reads `\.transportDate`, the reassembler `\.meshtasticDate`. **A `MeshtasticSession` always gets the real `ContinuousClock`** (its default): its 30 s want_config timeout sleeps on that clock, so an ImmediateClock kills every handshake. Prefer `exhaustivity = .off` stores asserting outcomes. To assert that something is NOT sent, send under `.off`, then set `exhaustivity = .on` LAST (teardown catches the stray). Under `.off`, `store.state` shows effect-delivered actions only after `receive` or `skipReceivedActions(strict: false)`, and `receive { predicate }` skips non-matching actions. `Effect.cancel(id:)` is EAGER: never hold one in a `let`/`var`. A test that SEEDS state proves nothing about reachability: drive real actions where the claim is about reachability. A compound test name is a claim per clause: assert and mutate each clause.
- **CoreBluetoothMock is process-global and Swift Testing runs every test target in ONE process in parallel.** Every CBM-backed suite this lane adds is declared as `extension FCBDriverAdapterCBMTests { @Suite @MainActor struct … }` — a nested suite of the existing `.serialized` suite (`Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMTests.swift:58-59`), so it inherits the serialization. This is lane F's rule too (its plan line 68): never add a second `@Suite(.serialized)` CBM suite (two serialized suites still run concurrently with each other) and never rename or re-nest `FCBDriverAdapterCBMTests` (lane F extends it from a new file). That is also why the live tests live in `ReTiCAInterfacesTests` rather than a new test target: a second target's suites could not share the serialization.
- **Live values end to end.** At least one test per Part drives LIVE values through production wiring: Task 4 (`MeshtasticSession` over FCB `mocked()` into `MeshtasticInterface`), Task 6 (BLE + radio on one live central), Task 12 (app reducer + real `TransportEndpoint` + driver).
- **SwiftUI.** No new tappable rows are planned. If one is added, its label ends with `.frame(maxWidth: .infinity, alignment: .leading)` then `.contentShape(Rectangle())`.
- **Hardware tooling** runs in conda env `rns` with `python` (not `python3`); the env's binaries are `/Users/ell/opt/anaconda3/envs/rns/bin/{python,rnsd,rnstatus}`.

## Review Focus

1. **A persisted radio CoreBluetooth no longer knows** (app reinstalled, Bluetooth reset, radio forgotten). MeshtasticKit ends the session `.disconnected(reason: "radio not found")`, and `MeshtasticInterface` emits no delegate for a drop of a never-online radio, so Diagnostics would sit on a silent "radio not connected". Expected: Diagnostics names the cause. The live adapter maps a terminal session end that is not an adapter cause to `.unavailable(.other(reason))` (Contract 3: non-terminal by `isTerminal`). Pinned: Task 3 `aTerminalSessionEndIsReportedAsUnavailableWithItsReason`, Task 4 `liveDriverReportsAnUnknownRadioAsUnavailable`.
2. **Bluetooth is power-cycled while the radio is online.** Expected: `.disconnected`, then back to `.connected` with no user action (MeshtasticKit's backoff), never a wedge. Pinned: Task 4 `liveDriverComesBackAfterABluetoothPowerCycle`.
3. **The user changes or disables the radio while the old one is still connecting or out of range** (CoreBluetooth connects never time out). Expected: `driver.stop()` still returns, the swap completes, and no new driver starts before the old stop returned. Pinned: Task 4 `liveDriverStopReturnsWhileTheRadioIsOutOfRange`, Task 9 `meshSlotChangingTheRadioWhileTheOldOneIsStillConnectingWaitsForItsStop`.
4. **Our own rebroadcast packets, and other apps' traffic on other ports, arrive from the radio.** Expected: dropped before reassembly. Pinned: Task 3 `aPacketFromOurOwnNodeIsDropped`, `otherPortsAreDropped`; Task 4 `liveDriverDropsItsOwnNodesPackets`, `liveDriverDropsOtherPorts`.
5. **Connect or foreground fires again while a swap's stop is in flight.** Expected: never two driver starts without a stop between them, and the swap still ends on the new radio. Pinned: Task 9 `meshSlotConnectDuringASwapNeverStartsTwiceWithoutAStop`, Task 10 `meshRedialNeverRestartsTheSlotASwapIsReplacing`, Task 12 `meshSliceARadioChangeDuringConnectEndsOnTheNewRadioWithNoDriverOverlap`.

## Decisions recorded

- **Stop semantics (Contract 3, amended) — one refinement.** "A `.stop` to an interface that is already stopped emits `.radioOffline(reason: nil)` immediately" holds only when no `driver.stop()` is in flight. A `.stop` arriving while one is (status `.stopped`, `stopping == true`) emits nothing; the in-flight stop's `.driverStopped` reports offline once for both. Otherwise "offline" would again mean "not yet down" and a waiter could nil the slot mid-stop (the very defect being fixed). A stop that lands while a deferred start is pending still reports offline at `.driverStopped`, BEFORE the deferred start runs, so `TransportEndpoint` deregisters the interface before the restarted driver re-registers it; the app treats a `.radioOffline` whose interface is not idle as "someone restarted it" and stops again (Task 9).
- **`interfaceConnectedAt` across disconnect → reconnect of the same id: KEEP the original time.** Reference: `Interface.created` is set once in `Interface.__init__` (`RNS/Interfaces/Interface.py:101`), `age()` is `time.time() - self.created` (`:221-222`), and a reconnect reuses the same object (`TCPInterface.py:270-297` loops `connect()` on `self`), so a persistent interface keeps its age across every reconnect. Meshtastic is such an interface: `MeshtasticSession` reconnects the same radio, and the live adapter reports every reconnect as `.disconnected` → `.connected`, i.e. `interfaceDisconnected` then `interfaceConnected` — which today nils the time (`Transport.swift:360`). The repeated-`.interfaceConnected` fix alone would therefore NOT fix radio reconnects. Mechanism: `interfaceDisconnected` moves the id's connect time into a bounded `departedInterfaceAges` (oldest departure evicted past 64 entries), and `interfaceConnected` restores it. Recorded deviations: (1) the reference creates a NEW object (age 0) for spawned interfaces; ReTiCA's BLE peer ids (`ble:<identity>`) can repeat, so a BLE peer reconnecting with the same identity resumes its age — looser than reference, but it grants nothing a peer could not get by staying connected; TCP-server connection ids are fresh per connection and never match. (2) Ids churned past the cap return as new: stricter, never looser. (3) Retained entries never expire by time, as reference persistent interfaces never do.
- **`hopLimit: nil` (spec §7 E.4).** `MeshtasticDriverConfig.hopLimit` is a non-optional `UInt32 = 1` (Contract 2), so ReTiCA can never send `nil`. Task 15 checks MeshtasticKit's `nil` path through Meshtastified, whose text send omits it (`MeshtastifiedKit/Sources/MeshDeviceClient/MeshSessionActor.swift:123-129`).
- **Live scan end.** `MeshtasticScanner.scan` waits for `.poweredOn` forever, so on an unauthorized or unsupported adapter it never finishes; ReTiCaMsgr's `RadioScanner` contract says the stream finishes when scanning has stopped for good. `MeshtasticLive.scanRadios` adds that end (Task 5).
- **Where the live session is built.** ReTiCaMsgrCore depends on MeshtasticKit (spec §7 E.3) but naming FCB's `BluetoothCentralClient` would also need FCB as a direct package dependency. `ReTiCAMeshtasticLive` therefore exposes `MeshtasticLive.makeSession()` and `MeshtasticLive.scanRadios()` over FCB's process-wide `liveValue` (the same central `BLEDriver.liveValue` uses). The app's one session is a lazily built static that lives for the process, so it is never dropped and the "disconnect before dropping" rule holds by construction; every slot stop disconnects it.
- **Interface-up announce (Contract 4).** The app's `interfaceConnected` arm sends `.registerDelivery` (which announces on EVERY interface) only while no delivery destination exists; every later interface-up sends `.announceDeliveryOnInterface(id)`.

---

## File Structure

**Part 1 — ReTiCA (`R`)**

| File | Change | Responsibility |
|---|---|---|
| `Sources/ReTiCAInterfaces/Meshtastic/MeshtasticInterface.swift` | modify | `.stop` / `.driverStopped` per amended Contract 3; public `isIdle` |
| `Sources/ReTiCATransport/Transport.swift` | modify | keep first connect time; bounded `departedInterfaceAges` |
| `Sources/ReTiCANode/TransportEndpoint.swift` | modify (comment only) | the meshtastic `.online` arm's note about re-registration |
| `Package.swift` | modify | `../MeshtasticKit` dependency, `ReTiCAMeshtasticLive` product + target, test-target deps |
| `Sources/ReTiCAMeshtasticLive/MeshtasticDriver+Live.swift` | create | `MeshtasticDriver.live(session:)`, the pure event mapping, the adapter |
| `Sources/ReTiCAMeshtasticLive/MeshtasticLive.swift` | create | `makeSession()`, `scanRadios()` / `scanRadios(central:)` |
| `Tests/ReTiCAInterfacesTests/MeshtasticInterfaceStopTests.swift` | create | interface-level stop ordering |
| `Tests/ReTiCANodeTests/MeshtasticSlotReplacementTests.swift` | create | nil-the-slot-then-start-a-new-one through `TransportEndpoint` |
| `Tests/ReTiCATransportTests/InterfaceAgeTests.swift` | create | ingress age across re-register / reconnect, the cap |
| `Tests/ReTiCAInterfacesTests/MeshtasticLiveMappingTests.swift` | create | pure mapping (no CBM) |
| `Tests/ReTiCAInterfacesTests/MeshtasticLiveTestSupport.swift` | create | CBM radio rig, event runs, waits |
| `Tests/ReTiCAInterfacesTests/MeshtasticLiveDriverTests.swift` | create | adapter loopback over the live FCB client |
| `Tests/ReTiCAInterfacesTests/MeshtasticLiveInterfaceTests.swift` | create | `MeshtasticInterface` reducer over the live driver |
| `Tests/ReTiCAInterfacesTests/MeshtasticLiveScanTests.swift` | create | `scanRadios(central:)` over a fake central |
| `Tests/ReTiCAInterfacesTests/MeshtasticCoexistenceTests.swift` | create | BLE driver + radio on one live central |
| `Scripts/meshtastic-hardware/lxmf_probe.py` | create | Mac-side LXMF receiver/sender for the hardware run |
| `docs/superpowers/plans/2026-10-16-meshtastic-hardware-checklist.md` | create | the user's checklist and results sheet |

**Part 2 — ReTiCAMsgr (`A`)**

| File | Change | Responsibility |
|---|---|---|
| `ReTiCaMsgrCore/Package.swift` | modify | MeshtasticKit + `ReTiCAMeshtasticLive` |
| `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/MeshtasticLiveWiring.swift` | create | installs the live driver (Task 9) and scanner (Task 13) |
| `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature+MeshtasticRadio.swift` | create | swap state, `syncMeshtasticSlot`, `MeshtasticRadioReducer` |
| `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift` | modify | state fields, `syncEndpointNodes`, `redialDownNodes`, Connect/Disconnect, `interfaceConnected`, body |
| `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/MeshtasticStatus.swift` | modify | counters from `MeshtasticCounters`, `+` |
| `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/RadioScanner.swift` | modify (Task 13) | `RadioScanner.meshtastic(_:)` |
| `ReTiCaMsgr/AppRuntime.swift` | modify | install the live driver; later the live scanner |
| `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/MeshtasticRadioTestSupport.swift` | create | radio/TCP harnesses, store builder |
| `.../MeshtasticRadioSlotTests.swift` | create | `meshSlot…` (Task 9) |
| `.../MeshtasticRedialTests.swift` | create | `meshRedial…` (Task 10) |
| `.../MeshtasticStatusTests.swift` | create | `meshStatus…`, `meshAnnounce…` (Task 11) |
| `.../MeshtasticWholeSliceProbeTests.swift` | create | `meshSlice…` (Task 12) |
| `.../MeshtasticLiveScannerTests.swift` | create | `meshLiveScan…` (Task 13) |

---

# Part 1 — ReTiCA (`R`)

### Task 1: Worktree, symlink, and the amended stop semantics (spec §7 E.0(a))

**Files:**
- Modify: `R/Sources/ReTiCAInterfaces/Meshtastic/MeshtasticInterface.swift:100-118` (add `isIdle`), `:135-138` (delegate doc), `:167-189` (`.stop`, `.driverStopped`)
- Create: `R/Tests/ReTiCAInterfacesTests/MeshtasticInterfaceStopTests.swift`
- Create: `R/Tests/ReTiCANodeTests/MeshtasticSlotReplacementTests.swift`

**Interfaces:**
- Consumes: `MeshtasticInterface` (lane B), `MeshMockCall`, `meshTestConfig`, `meshOwnNode` (`Tests/ReTiCAInterfacesTests/MeshtasticInterfaceTestSupport.swift:6-24`), `TransportEndpoint`, `MeshtasticEndpoint`, `meshtasticInterfaceID(radio:)`.
- Produces: `MeshtasticInterface.State.isIdle: Bool` (public) — `status == .stopped && !stopping`; the app (Task 9) reads it as `endpoint.meshtastic?.interface.isIdle`. Behaviour: a stop-initiated `.delegate(.offline(reason: nil))` is reduced only after `.driverStopped`; a `.stop` on a stopped interface with no stop in flight emits offline at once.

- [ ] **Step 1: Create the worktree and the MeshtasticKit symlink**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA worktree add ../ReTiCA-worktrees/meshtastic-integration -b meshtastic-integration`
Expected: `Preparing worktree (new branch 'meshtastic-integration')`.

Run: `ls -la /Users/ell/development/ios/pods/ReTiCA-worktrees`
Expected: `FCB -> /Users/ell/development/ios/pods/FCB` is listed. If `MeshtasticKit` is NOT listed, run:
`ln -s /Users/ell/development/ios/pods/MeshtasticKit /Users/ell/development/ios/pods/ReTiCA-worktrees/MeshtasticKit`

Run: `mkdir -p /tmp/meshtastic-integration`

- [ ] **Step 2: Baseline**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration > /tmp/meshtastic-integration/t1-baseline.log 2>&1` (background if needed)
Expected: `Test run with N tests ... passed`. Record N in the Task 8 notes. If anything fails on a clean tree, STOP and report.

- [ ] **Step 3: Write the interface-level stop tests**

Create `R/Tests/ReTiCAInterfacesTests/MeshtasticInterfaceStopTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

/// Runs the real interface and logs, in REDUCE order, every `.driverStopped` and every
/// `.delegate(.offline)` — the latter tagged with how many driver starts had happened by then.
private struct StopOrderRecorder: Reducer {
    typealias State = MeshtasticInterface.State
    typealias Action = MeshtasticInterface.Action
    let log: LockIsolated<[String]>
    let calls: LockIsolated<[MeshMockCall]>

    func reduce(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
        case .driverStopped:
            log.withValue { $0.append("driverStopped") }
        case .delegate(.offline):
            let starts = calls.value.filter { if case .start = $0 { return true }; return false }.count
            log.withValue { $0.append("offline@\(starts)") }
        default:
            break
        }
        return MeshtasticInterface().reduce(into: &state, action: action)
    }
}

@MainActor
private struct StopHarness {
    let store: TestStore<MeshtasticInterface.State, MeshtasticInterface.Action>
    let log: LockIsolated<[String]>
    let calls: LockIsolated<[MeshMockCall]>
    let held: LockIsolated<Bool>

    var offlineCount: Int { log.value.filter { $0.hasPrefix("offline") }.count }
    var startCount: Int { calls.value.filter { if case .start = $0 { return true }; return false }.count }

    func releaseStop() { held.setValue(false) }

    func waitForStarts(_ count: Int) async {
        for _ in 0..<200 where startCount < count { await Task.megaYield() }
    }

    func shutdown() async {
        held.setValue(false)
        await store.send(.stop)
        await Task.megaYield()
        await store.skipReceivedActions(strict: false)
    }
}

/// A mock radio shaped like the live adapter: every `start` opens a FRESH session stream, and
/// `stop` blocks while `held` is true and records `.stop` only when it RETURNS.
@MainActor
private func makeStopHarness(online: Bool, holdStops: Bool = true) async -> StopHarness {
    let log = LockIsolated<[String]>([])
    let calls = LockIsolated<[MeshMockCall]>([])
    let held = LockIsolated(holdStops)
    let sessions = LockIsolated<[AsyncStream<MeshtasticDriverEvent>.Continuation]>([])
    let store = TestStore(initialState: MeshtasticInterface.State(config: meshTestConfig)) {
        StopOrderRecorder(log: log, calls: calls)
    } withDependencies: {
        $0.meshtasticDriver = MeshtasticDriver(
            start: { config in
                let session = AsyncStream<MeshtasticDriverEvent>.makeStream()
                calls.withValue { $0.append(.start(config)) }
                sessions.withValue { $0.append(session.continuation) }
                return session.stream
            },
            send: { _ in true },
            stop: {
                while held.value { await Task.yield() }
                sessions.value.last?.finish()
                calls.withValue { $0.append(.stop) }
            })
        $0.meshtasticClock = TestClock<Duration>()
        $0.meshtasticDate = DateGenerator { Date(timeIntervalSince1970: 1_000) }
    }
    store.exhaustivity = .off
    if online {
        await store.send(.start)
        for _ in 0..<200 where sessions.value.isEmpty { await Task.megaYield() }
        sessions.value.last?.yield(.connected(myNodeNum: meshOwnNode, modemPreset: 0))
        await store.receive { if case .delegate(.online) = $0 { return true }; return false }
    }
    return StopHarness(store: store, log: log, calls: calls, held: held)
}

/// Contract 3 (amended 2026-10-16): offline means "the driver is fully down".
@MainActor @Suite struct MeshtasticInterfaceStopTests {
    @Test func offlineWaitsForTheDriverStopToReturn() async {
        let h = await makeStopHarness(online: true)
        await h.store.send(.stop)
        await Task.megaYield()
        #expect(h.offlineCount == 0, "offline before driver.stop() returned: \(h.log.value)")
        h.releaseStop()
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        #expect(h.log.value == ["driverStopped", "offline@1"])
    }

    @Test func stopOnANeverStartedInterfaceReportsOfflineAtOnce() async {
        let h = await makeStopHarness(online: false)
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        #expect(h.calls.value.isEmpty)
    }

    @Test func stopAfterACompletedStopReportsOfflineAgain() async {
        let h = await makeStopHarness(online: true, holdStops: false)
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        #expect(h.offlineCount == 2)
    }

    @Test func aSecondStopDuringAStopReportsOfflineOnceTheDriverStops() async {
        let h = await makeStopHarness(online: true)
        await h.store.send(.stop)
        await h.store.send(.stop)
        await Task.megaYield()
        #expect(h.offlineCount == 0, "offline while driver.stop() is still in flight: \(h.log.value)")
        h.releaseStop()
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await Task.megaYield()
        #expect(h.offlineCount == 1)
    }

    @Test func stopCancellingADeferredStartWaitsForTheInFlightStop() async {
        let h = await makeStopHarness(online: true)
        await h.store.send(.stop)
        await h.store.send(.start)
        await h.store.send(.stop)
        await Task.megaYield()
        #expect(h.offlineCount == 0, "offline before the in-flight driver.stop() returned: \(h.log.value)")
        h.releaseStop()
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        #expect(h.store.state.status == .stopped)
        #expect(h.startCount == 1)
    }

    @Test func aStartDuringAStopReportsOfflineBeforeTheDriverRestarts() async {
        let h = await makeStopHarness(online: true)
        await h.store.send(.stop)
        await h.store.send(.start)
        h.releaseStop()
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await h.waitForStarts(2)
        #expect(h.log.value == ["driverStopped", "offline@1"])
        #expect(h.calls.value == [.start(meshTestConfig), .stop, .start(meshTestConfig)])
        await h.shutdown()
    }

    @Test func isIdleOnlyOnceTheDriverStopReturned() async {
        let h = await makeStopHarness(online: true)
        await h.store.send(.stop)
        #expect(h.store.state.status == .stopped)
        #expect(!h.store.state.isIdle)
        h.releaseStop()
        await h.store.receive { $0 == .driverStopped }
        #expect(h.store.state.isIdle)
    }
}
```

- [ ] **Step 4: Write the endpoint-level replacement test**

Create `R/Tests/ReTiCANodeTests/MeshtasticSlotReplacementTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let slotRadioA = UUID(uuidString: "0000AAAA-0000-0000-0000-0000000000A1")!
private let slotRadioB = UUID(uuidString: "0000BBBB-0000-0000-0000-0000000000B2")!

private enum SlotRadioCall: Equatable { case start(UUID), stop }

/// Contract 3's slot-removal protocol exactly as lane E's app runs it: `.replaceRadio` sends
/// `.meshtastic(.stop)`, and the slot is replaced (nil'd, then a new one started) only at
/// `.radioOffline`.
@Reducer
struct MeshtasticRadioSlotHost {
    struct State: Equatable {
        var endpoint: TransportEndpoint.State
        var next: MeshtasticDriverConfig?
    }

    enum Action: Equatable {
        case endpoint(TransportEndpoint.Action)
        case replaceRadio(MeshtasticDriverConfig)
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.endpoint, action: \.endpoint) { TransportEndpoint() }
        Reduce { state, action in
            switch action {
            case let .replaceRadio(config):
                state.next = config
                return .send(.endpoint(.meshtastic(.stop)))
            case .endpoint(.meshtastic(.delegate(.radioOffline))):
                guard let next = state.next else { return .none }
                state.next = nil
                state.endpoint.meshtastic = MeshtasticEndpoint.State(config: next)
                return .send(.endpoint(.meshtastic(.start)))
            case .endpoint, .replaceRadio:
                return .none
            }
        }
    }
}

@MainActor
private struct SlotHostHarness {
    let store: TestStoreOf<MeshtasticRadioSlotHost>
    let calls: LockIsolated<[SlotRadioCall]>
    let sessions: LockIsolated<[AsyncStream<MeshtasticDriverEvent>.Continuation]>
    let held: LockIsolated<Bool>

    var startCount: Int { calls.value.filter { if case .start = $0 { return true }; return false }.count }

    func waitForStarts(_ count: Int) async {
        for _ in 0..<200 where startCount < count { await Task.megaYield() }
    }

    func yieldToLatest(_ event: MeshtasticDriverEvent) { sessions.value.last?.yield(event) }

    func shutdown() async {
        held.setValue(false)
        await store.send(.endpoint(.stop))
        await Task.megaYield()
        await store.skipReceivedActions(strict: false)
    }
}

@MainActor
private func makeSlotHost(holdStops: Bool) -> SlotHostHarness {
    let calls = LockIsolated<[SlotRadioCall]>([])
    let sessions = LockIsolated<[AsyncStream<MeshtasticDriverEvent>.Continuation]>([])
    let held = LockIsolated(holdStops)
    let initial = MeshtasticRadioSlotHost.State(
        endpoint: TransportEndpoint.State(
            meshtastic: MeshtasticEndpoint.State(config: MeshtasticDriverConfig(radio: slotRadioA))),
        next: nil)
    let store = TestStore(initialState: initial) { MeshtasticRadioSlotHost() } withDependencies: {
        $0.meshtasticDriver = MeshtasticDriver(
            start: { config in
                let session = AsyncStream<MeshtasticDriverEvent>.makeStream()
                calls.withValue { $0.append(.start(config.radio)) }
                sessions.withValue { $0.append(session.continuation) }
                return session.stream
            },
            send: { _ in true },
            stop: {
                while held.value { await Task.yield() }
                sessions.value.last?.finish()
                calls.withValue { $0.append(.stop) }
            })
        $0.meshtasticClock = ImmediateClock()
        $0.meshtasticDate = DateGenerator { Date(timeIntervalSince1970: 0) }
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.transportDate = DateGenerator { Date(timeIntervalSince1970: 0) }
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return SlotHostHarness(store: store, calls: calls, sessions: sessions, held: held)
}

@MainActor @Suite struct MeshtasticSlotReplacementTests {
    /// Spec §7 E.0(a): nil the slot at `.radioOffline`, start a new slot — driver calls must be
    /// `start, stop, start`, never `start, start, stop`.
    @Test func aReplacedSlotStartsOnlyAfterTheOldDriverStopped() async {
        let h = makeSlotHost(holdStops: true)
        await h.store.send(.endpoint(.start))
        await h.waitForStarts(1)
        h.yieldToLatest(.connected(myNodeNum: 0x0A0A_0A0A, modemPreset: 8))
        await h.store.receive { if case .endpoint(.meshtastic(.delegate(.radioOnline))) = $0 { return true }; return false }
        await h.store.send(.replaceRadio(MeshtasticDriverConfig(radio: slotRadioB)))
        await Task.megaYield()
        #expect(h.calls.value == [.start(slotRadioA)], "a driver call happened while the old stop was in flight")
        h.held.setValue(false)
        await h.store.receive { $0 == .endpoint(.meshtastic(.delegate(.radioOffline(reason: nil)))) }
        await h.waitForStarts(2)
        #expect(h.calls.value == [.start(slotRadioA), .stop, .start(slotRadioB)])
        await h.shutdown()
    }

    @Test func stopToANeverStartedSlotReportsRadioOfflineAtOnce() async {
        let h = makeSlotHost(holdStops: false)
        await h.store.send(.endpoint(.meshtastic(.stop)))
        await h.store.receive { $0 == .endpoint(.meshtastic(.delegate(.radioOffline(reason: nil)))) }
        #expect(h.calls.value.isEmpty)
    }
}
```

- [ ] **Step 5: Run the new tests to see them fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration --filter MeshtasticInterfaceStopTests --filter MeshtasticSlotReplacementTests > /tmp/meshtastic-integration/t1-red.log 2>&1`
Expected: build error `value of type 'MeshtasticInterface.State' has no member 'isIdle'`. (Once Step 6's first edit is in, the run fails `offlineWaitsForTheDriverStopToReturn`, `stopOnANeverStartedInterfaceReportsOfflineAtOnce`, `stopAfterACompletedStopReportsOfflineAgain`, `aSecondStopDuringAStopReportsOfflineOnceTheDriverStops`, `stopCancellingADeferredStartWaitsForTheInFlightStop`, `aStartDuringAStopReportsOfflineBeforeTheDriverRestarts`, `aReplacedSlotStartsOnlyAfterTheOldDriverStopped`, `stopToANeverStartedSlotReportsRadioOfflineAtOnce`.)

- [ ] **Step 6: Implement**

In `MeshtasticInterface.swift`, after `public var queuedFragmentCount: Int { queue.count }` add:

```swift
        /// Stopped with no `driver.stop()` still in flight: nothing of this interface runs, so a
        /// host may drop its state now (spec Contract 3). `.stopped` alone is not enough: a
        /// `driver.stop()` is still in flight, and what dropping the state does to it depends on
        /// WHO drops it. An `ifLet` cancels the child's effects only when its own parent reducer
        /// nils the state; a host outside that reducer (as with `TransportEndpoint.meshtastic`,
        /// which nothing inside `TransportEndpoint` drops) leaves the stop running, and its
        /// `.driverStopped` then reaches an `ifLet` with no state (TCA's runtime warning). Either
        /// way the next slot's start could race the old stop.
        public var isIdle: Bool { status == .stopped && !stopping }
```

Replace the `.offline` delegate doc (the three comment lines above `case offline(reason: String?)`):

```swift
            /// The radio is no longer usable. Reported on a drop or unavailability of an ONLINE
            /// radio, and for every `.stop` — only once `driver.stop()` has returned, so "offline"
            /// means "fully down, the slot may be dropped" (spec Contract 3, amended 2026-10-16).
            /// A `.stop` to an interface that is already idle reports it at once.
            case offline(reason: String?)
```

Replace the `.stop` and `.driverStopped` arms (today `:167-189`) with:

```swift
            case .stop:
                guard state.status != .stopped else {
                    // A host that sends `.stop` waits for offline (Contract 3), so an already idle
                    // interface answers at once. With a `driver.stop()` still in flight, its
                    // `.driverStopped` answers for this stop too: offline must mean "fully down".
                    return state.stopping ? .none : .send(.delegate(.offline(reason: nil)))
                }
                state.status = .stopped
                if state.restartPending {
                    // The deferred start never reached the driver. The stop already in flight
                    // covers this one, and its `.driverStopped` reports offline.
                    state.restartPending = false
                    return .none
                }
                state.stopping = true
                clearTraffic(&state)
                return .merge(.cancel(id: CancelID.driver),
                              .cancel(id: CancelID.pacing),
                              .run { [driver] send in
                                  await driver.stop()
                                  await send(.driverStopped)
                              })

            case .driverStopped:
                state.stopping = false
                // Contract 3 (amended): the stop-initiated offline, now that `driver.stop()` has
                // returned. Also when a deferred `.start` runs next, and BEFORE it, so the host
                // deregisters the radio's interface before the restarted driver re-registers it.
                guard state.restartPending else { return .send(.delegate(.offline(reason: nil))) }
                state.restartPending = false
                return .concatenate(.send(.delegate(.offline(reason: nil))), startDriver(state))
```

- [ ] **Step 7: Run to green (verification a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration --filter MeshtasticInterfaceStopTests --filter MeshtasticSlotReplacementTests --filter MeshtasticInterfaceLifecycleTests --filter TransportEndpointMeshtasticTests --filter MeshtasticEndpointTests > /tmp/meshtastic-integration/t1-green.log 2>&1`
Expected: all pass, including lane B's existing lifecycle/endpoint suites.

- [ ] **Step 8: Mutation verification (b), then (c)**

Back up: `cp /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration/Sources/ReTiCAInterfaces/Meshtastic/MeshtasticInterface.swift /tmp/meshtastic-integration/MeshtasticInterface.swift.orig`

Mutations (each is an Edit on `MeshtasticInterface.swift`):
- **M1** (offline concurrent with stop, lane B's shipped semantics): in `.stop`'s final `.merge(...)` add `, .send(.delegate(.offline(reason: nil)))` after the `.run`; in `.driverStopped` change the `guard ... else { return .send(.delegate(.offline(reason: nil))) }` to `else { return .none }`.
- **M2** (nothing for an already-stopped interface): `return state.stopping ? .none : .send(.delegate(.offline(reason: nil)))` → `return .none`.
- **M3** (immediate offline even with a stop in flight): same line → `return .send(.delegate(.offline(reason: nil)))`.
- **M4** (a stop cancelling a deferred start reports at once): in the `if state.restartPending` block, `return .none` → `return .send(.delegate(.offline(reason: nil)))`.
- **M5** (no offline before a deferred restart): `return .concatenate(.send(.delegate(.offline(reason: nil))), startDriver(state))` → `return startDriver(state)`.
- **M6**: `public var isIdle: Bool { status == .stopped && !stopping }` → `public var isIdle: Bool { status == .stopped }`.

Combined batch: **M1, M2, M4, M5, M6** (M3 edits the same line as M2, so it runs in its own batch below). Run the two new suites once: EVERY test in `MeshtasticInterfaceStopTests` and `MeshtasticSlotReplacementTests` fails (`aSecondStopDuringAStopReportsOfflineOnceTheDriverStops` through M1: the first stop's offline is immediate). Restore from `.orig`.

Per-clause batches (restore between each; run the two new suites):
- M1 alone → `offlineWaitsForTheDriverStopToReturn`, `aReplacedSlotStartsOnlyAfterTheOldDriverStopped` fail.
- M2 alone → `stopOnANeverStartedInterfaceReportsOfflineAtOnce`, `stopAfterACompletedStopReportsOfflineAgain`, `stopToANeverStartedSlotReportsRadioOfflineAtOnce` fail.
- M3 alone → `aSecondStopDuringAStopReportsOfflineOnceTheDriverStops` fails.
- M4 alone → `stopCancellingADeferredStartWaitsForTheInFlightStop` fails.
- M5 alone → `aStartDuringAStopReportsOfflineBeforeTheDriverRestarts` fails.
- M6 alone → `isIdleOnlyOnceTheDriverStopReturned` fails.

Restore: `cp /tmp/meshtastic-integration/MeshtasticInterface.swift.orig /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration/Sources/ReTiCAInterfaces/Meshtastic/MeshtasticInterface.swift`, run the Step 7 command, all pass. `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration diff --stat` lists only `MeshtasticInterface.swift`.

- [ ] **Step 9: Commit**

```
git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration add Sources/ReTiCAInterfaces/Meshtastic/MeshtasticInterface.swift Tests/ReTiCAInterfacesTests/MeshtasticInterfaceStopTests.swift Tests/ReTiCANodeTests/MeshtasticSlotReplacementTests.swift
```
Message file `/tmp/meshtastic-integration/commit-task1.txt`:
```
fix: Meshtastic stop reports offline only once driver.stop() returned

Contract 3 (amended 2026-10-16). A stop-initiated offline now comes from the
driverStopped arm, so a host that nils the slot at radioOffline can no longer
cancel an in-flight stop and race the next slot's start (start, start, stop).
A stop to an idle interface reports offline at once, and a stop arriving while
a driver.stop() is in flight is answered by that stop. isIdle tells a host the
interface may be dropped now.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration commit -F /tmp/meshtastic-integration/commit-task1.txt`
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration log -1 "--format=%(trailers:key=Claude-Session)"` → the session line.

---

### Task 2: Keep an interface's first connect time (spec §7 E.0(b))

**Files:**
- Modify: `R/Sources/ReTiCATransport/Transport.swift:149-150` (state), `:348-362` (two arms), and the constants block near `:1189` (`icNewTime`)
- Modify (comment only): `R/Sources/ReTiCANode/TransportEndpoint.swift:314-322`
- Create: `R/Tests/ReTiCATransportTests/InterfaceAgeTests.swift`

**Interfaces:**
- Consumes: `Transport.Action.interfaceConnected(InterfaceID, InterfaceProfile)` / `.interfaceDisconnected(InterfaceID)` / `.received(InterfaceID, Data)`; `Transport.State.heldAnnounces`, `.learned`, `.interfaceConnectedAt`.
- Produces: `public struct Transport.DepartedInterfaceAge: Equatable, Sendable { public var id: InterfaceID; public var connectedAt: Date }`, `Transport.State.departedInterfaceAges: [Transport.DepartedInterfaceAge]` (oldest departure first), `static let Transport.maxDepartedInterfaceAges = 64`. Behaviour: an id that is registered, or that departed and is still in `departedInterfaceAges`, keeps its original connect time.

- [ ] **Step 1: Write the failing tests**

Create `R/Tests/ReTiCATransportTests/InterfaceAgeTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCA
@testable import ReTiCATransport

private func ageAnnounce(emitted: UInt64, prefix: UInt8) -> (raw: Data, destinationHash: Data) {
    let identity = Identity()
    let nameHash = Destination.nameHash(appName: "age", aspects: ["probe"])
    let destHash = Destination.hash(identityHash: identity.hash, appName: "age", aspects: ["probe"])
    let randomHash = Announce.randomHash(now: emitted, randomPrefix: Data([prefix, 0, 0, 0, 0]))
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, appData: nil)
    let packet = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 1,
                        destinationHash: destHash, transportId: nil, payload: payload)
    return (try! packet.packed(), destHash)
}

@MainActor
private func makeAgeStore(now: LockIsolated<Date>) -> TestStore<Transport.State, Transport.Action> {
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = TestClock()            // held-announce releases never fire
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    return store
}

/// Three signature-valid announces for unknown destinations, 0.2 s apart from `start`. The third
/// arrives at 7.5 Hz: above a NEW interface's 3 Hz burst threshold (`icBurstFreqNew`), below an
/// ESTABLISHED one's 10 Hz (`icBurstFreq`). Returns their destination hashes.
@MainActor
private func feed(_ store: TestStore<Transport.State, Transport.Action>, on id: InterfaceID,
                  now: LockIsolated<Date>, start: TimeInterval, prefix: UInt8) async -> [Data] {
    var dests: [Data] = []
    for k in 0..<3 {
        now.setValue(Date(timeIntervalSince1970: start + 0.2 * Double(k)))
        let (raw, dest) = ageAnnounce(emitted: UInt64(start) + UInt64(k), prefix: prefix &+ UInt8(k))
        dests.append(dest)
        await store.send(.received(id, raw))
    }
    return dests
}

@MainActor @Suite struct InterfaceAgeTests {
    /// Spec §7 E.0(b): a repeated `.interfaceConnected` for a registered id (a radio preset change)
    /// must not reopen the 2 h new-interface ingress window.
    @Test func aRepeatedConnectKeepsAnEstablishedInterfaceEstablished() async {
        let now = LockIsolated(Date(timeIntervalSince1970: 0))
        let store = makeAgeStore(now: now)
        let radio = InterfaceID("radio")
        let fresh = InterfaceID("fresh")
        await store.send(.interfaceConnected(radio, .default))
        now.setValue(Date(timeIntervalSince1970: 7_300))       // past icNewTime (7 200 s)
        await store.send(.interfaceConnected(radio, .default))   // re-registered without a drop
        await store.send(.interfaceConnected(fresh, .default))   // control: genuinely new
        let young = await feed(store, on: fresh, now: now, start: 7_300, prefix: 0x10)
        #expect(store.state.heldAnnounces[fresh]?[young[2]] != nil,
                "precondition: a NEW interface holds a 7.5 Hz burst")
        let established = await feed(store, on: radio, now: now, start: 7_301, prefix: 0x20)
        #expect(store.state.heldAnnounces[radio]?.isEmpty ?? true)
        #expect(established.allSatisfy { store.state.learned[$0] != nil })
    }

    /// Decision recorded in the plan: a disconnect → reconnect of the same id keeps the original
    /// time (reference `Interface.created`, Interface.py:101, survives TCPInterface.reconnect).
    @Test func aReconnectResumesTheConnectTimeOfTheFirstConnect() async {
        let now = LockIsolated(Date(timeIntervalSince1970: 0))
        let store = makeAgeStore(now: now)
        let radio = InterfaceID("radio")
        let fresh = InterfaceID("fresh")
        await store.send(.interfaceConnected(radio, .default))
        now.setValue(Date(timeIntervalSince1970: 7_250))
        await store.send(.interfaceDisconnected(radio))
        now.setValue(Date(timeIntervalSince1970: 7_300))
        await store.send(.interfaceConnected(radio, .default))
        await store.send(.interfaceConnected(fresh, .default))
        let young = await feed(store, on: fresh, now: now, start: 7_300, prefix: 0x30)
        #expect(store.state.heldAnnounces[fresh]?[young[2]] != nil,
                "precondition: a NEW interface holds a 7.5 Hz burst")
        let resumed = await feed(store, on: radio, now: now, start: 7_301, prefix: 0x40)
        #expect(store.state.heldAnnounces[radio]?.isEmpty ?? true)
        #expect(resumed.allSatisfy { store.state.learned[$0] != nil })
    }

    @Test func departedAgesAreCappedSoChurnedIDsCannotGrowState() async {
        let now = LockIsolated(Date(timeIntervalSince1970: 0))
        let store = makeAgeStore(now: now)
        let ids = (0...Transport.maxDepartedInterfaceAges).map { InterfaceID("churn-\($0)") }
        for id in ids {
            await store.send(.interfaceConnected(id, .default))
            await store.send(.interfaceDisconnected(id))
        }
        #expect(store.state.departedInterfaceAges.count == Transport.maxDepartedInterfaceAges)
        #expect(store.state.departedInterfaceAges.first?.id == ids[1], "the OLDEST departure is evicted")
    }
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration --filter InterfaceAgeTests > /tmp/meshtastic-integration/t2-red.log 2>&1`
Expected: build error — no `maxDepartedInterfaceAges` / `departedInterfaceAges`.

- [ ] **Step 3: Implement**

In `Transport.swift`, directly after `public var interfaceConnectedAt: [InterfaceID: Date] = [:]` (`:150`) add:

```swift
        /// Connect times of interfaces that have DISCONNECTED, oldest departure first, so a
        /// reconnect of the same id resumes its age: reference `Interface.created` is set once
        /// per Interface object (Interface.py:101) and a reconnect reuses the object
        /// (TCPInterface.py:270-297). At most `Transport.maxDepartedInterfaceAges`; an id evicted
        /// from here returns as a new interface (stricter, never looser).
        public var departedInterfaceAges: [Transport.DepartedInterfaceAge] = []
```

Directly after `static let icNewTime: TimeInterval = 7200` add:

```swift
    /// Bound on `State.departedInterfaceAges`: remote churn (TCP-server connections, BLE peers)
    /// mints ids, so the record of departed ones must not grow without limit.
    static let maxDepartedInterfaceAges = 64

    /// A departed interface's original connect time (see `State.departedInterfaceAges`).
    public struct DepartedInterfaceAge: Equatable, Sendable {
        public var id: InterfaceID
        public var connectedAt: Date
        public init(id: InterfaceID, connectedAt: Date) {
            self.id = id
            self.connectedAt = connectedAt
        }
    }
```

Replace the two arms (`:348-362`) with:

```swift
            case let .interfaceConnected(id, profile):
                state.interfaces[id] = profile
                // Spec 2026-10-16 §7 E.0(b): a repeated connect for a registered id (a radio preset
                // change) keeps its time, and a reconnect resumes the time of its first connect, so
                // neither reopens the 2 h new-interface ingress window (`icNewTime`).
                if state.interfaceConnectedAt[id] == nil {
                    if let departed = state.departedInterfaceAges.firstIndex(where: { $0.id == id }) {
                        state.interfaceConnectedAt[id] = state.departedInterfaceAges.remove(at: departed).connectedAt
                    } else {
                        state.interfaceConnectedAt[id] = date.now
                    }
                }
                return .none

            case let .interfaceDisconnected(id):
                state.interfaces[id] = nil
                state.announceAllowedAt[id] = nil
                state.announceQueues[id] = nil
                state.announceArrivals[id] = nil
                state.ingressBursts[id] = nil
                state.heldAnnounces[id] = nil
                if let connectedAt = state.interfaceConnectedAt[id] {
                    state.departedInterfaceAges.removeAll { $0.id == id }
                    state.departedInterfaceAges.append(Transport.DepartedInterfaceAge(id: id, connectedAt: connectedAt))
                    let excess = state.departedInterfaceAges.count - Transport.maxDepartedInterfaceAges
                    if excess > 0 { state.departedInterfaceAges.removeFirst(excess) }
                }
                state.interfaceConnectedAt[id] = nil
                return .merge(.cancel(id: CancelID.announceDrain(id)),
                              .cancel(id: CancelID.ingressRelease(id)))
```

In `TransportEndpoint.swift`, replace the comment block at `:314-322` (from `// ONE InterfaceID per radio` through `// timestamp across a re-register belongs in Transport.swift (lane C), not here.`) with:

```swift
            // ONE InterfaceID per radio, the TCP-client shape. The preset — hence the paced
            // bitrate — is only known once the radio is configured, so the profile is computed
            // here. A repeated `.online` (preset changed, or a reconnect the driver reported
            // without a drop) re-registers with the new profile; maintenance is not re-armed
            // because the shared interface set is not empty. Transport keeps the id's first
            // connect time across re-registration and reconnects (`.interfaceConnected`), so
            // neither reopens the new-interface ingress window.
```

- [ ] **Step 4: Run to green (a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration --filter InterfaceAgeTests --filter TransportTests --filter TransportEndpointMeshtasticTests > /tmp/meshtastic-integration/t2-green.log 2>&1`
Expected: all pass (the existing `disconnectClearsIngressState` still sees `interfaceConnectedAt[i0] == nil`).

- [ ] **Step 5: Mutation verification (b), then (c)**

Back up: `cp /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration/Sources/ReTiCATransport/Transport.swift /tmp/meshtastic-integration/Transport.swift.orig`

- **M1a**: `if state.interfaceConnectedAt[id] == nil {` → `if true {`.
- **M1b**: delete the line `state.departedInterfaceAges.append(Transport.DepartedInterfaceAge(id: id, connectedAt: connectedAt))`.
- **M2**: `if excess > 0 { state.departedInterfaceAges.removeFirst(excess) }` → `if excess > 1_000_000 { state.departedInterfaceAges.removeFirst(excess) }`.

Combined batch M1a + M1b + M2: all three `InterfaceAgeTests` fail. Per-clause: M1a alone → `aRepeatedConnectKeepsAnEstablishedInterfaceEstablished` fails; M1b alone → `aReconnectResumesTheConnectTimeOfTheFirstConnect` fails; M2 alone → `departedAgesAreCappedSoChurnedIDsCannotGrowState` fails. Restore from `.orig`, rerun Step 4: all pass. `diff --stat` lists `Transport.swift` and `TransportEndpoint.swift` only.

- [ ] **Step 6: Commit**

Stage `Sources/ReTiCATransport/Transport.swift Sources/ReTiCANode/TransportEndpoint.swift Tests/ReTiCATransportTests/InterfaceAgeTests.swift`. Message `/tmp/meshtastic-integration/commit-task2.txt`:
```
fix: an interface keeps its first connect time across re-register and reconnect

Spec 2026-10-16 section 7 E.0(b). A repeated interfaceConnected for a
registered id no longer resets interfaceConnectedAt, and a disconnect then
reconnect of the same id resumes its original time, as reference
Interface.created survives a reconnect (Interface.py:101). Radio reconnects
arrive as disconnected then connected, so both halves are needed to keep the
2 h new-interface ingress window shut. Departed ages are capped at 64.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Commit with `-F`, verify the trailer.

---

### Task 3: `ReTiCAMeshtasticLive` target and the live driver (spec §7 E.1, Contract 2)

**Files:**
- Modify: `R/Package.swift` (full replacement below)
- Create: `R/Sources/ReTiCAMeshtasticLive/MeshtasticDriver+Live.swift`
- Create: `R/Tests/ReTiCAInterfacesTests/MeshtasticLiveMappingTests.swift`
- Modify: `R/Package.resolved` (by `swift package resolve`)

**Interfaces:**
- Consumes: MeshtasticKit (Contract 1, `pods/MeshtasticKit` main `11ea646`): `MeshtasticSession` (`connect(radio:)`, `disconnect()`, `send(_:) throws -> UInt32`, `events()`), `MeshtasticEvent`, `MeshtasticConnectionState`, `MeshtasticAdapterUnavailable`, `MeshtasticOutbound`. ReTiCA: `MeshtasticDriver`, `MeshtasticDriverConfig`, `MeshtasticDriverEvent`, `BLEAdapterUnavailable`.
- Produces:
  - `public static let MeshtasticDriver.reticulumTunnelPort: UInt32` (= 76)
  - `public static func MeshtasticDriver.live(session: MeshtasticSession) -> MeshtasticDriver`
  - `static func MeshtasticDriver.driverEvent(for: MeshtasticEvent, ownNode: UInt32?) -> MeshtasticDriverEvent?` (internal, `@testable`)
  - library product `ReTiCAMeshtasticLive` (Task 9 depends on it).

- [ ] **Step 1: Replace `R/Package.swift`**

```swift
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ReTiCA",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
        .macCatalyst(.v17),
    ],
    products: [
        .library(name: "ReTiCA", targets: ["ReTiCA"]),
        .library(name: "ReTiCAInterfaces", targets: ["ReTiCAInterfaces"]),
        .library(name: "ReTiCATransport", targets: ["ReTiCATransport"]),
        .library(name: "ReTiCANode", targets: ["ReTiCANode"]),
        .library(name: "ReTiCAKeychain", targets: ["ReTiCAKeychain"]),
        // The live Meshtastic driver (spec 2026-10-16 Contract 2). The ONLY ReTiCA code that
        // imports MeshtasticKit.
        .library(name: "ReTiCAMeshtasticLive", targets: ["ReTiCAMeshtasticLive"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.15.0"),
        .package(path: "../FCB"),
        .package(path: "../MeshtasticKit"),
        .package(url: "https://github.com/NordicSemiconductor/IOS-CoreBluetooth-Mock.git", from: "1.0.0"),
        .package(url: "https://github.com/leif-ibsen/SwiftEdDSA", exact: "4.1.0"),
    ],
    targets: [
        .target(name: "ReTiCA"),
        .target(name: "Cbzip2"),
        .target(
            name: "ReTiCAInterfaces",
            dependencies: [
                "ReTiCA",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FCBComposable", package: "FCB"),
            ]
        ),
        .target(
            name: "ReTiCAMeshtasticLive",
            dependencies: [
                "ReTiCAInterfaces",
                .product(name: "MeshtasticKit", package: "MeshtasticKit"),
                .product(name: "FCBComposable", package: "FCB"),
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .testTarget(
            name: "ReTiCATests",
            dependencies: ["ReTiCA"],
            resources: [.process("Vectors/fixtures.json"), .process("Vectors/lxmf_fixtures.json"), .process("Vectors/lxmf_propagation_fixtures.json"), .process("Vectors/lxmf_rich_fixtures.json"), .process("Vectors/lxmf_stamp_fixtures.json"), .process("Vectors/lxmf_peering_fixtures.json"), .process("Vectors/lxmf_pn_announce_fixtures.json"), .process("Vectors/msgpack_signed_fixtures.json"), .process("Vectors/lxmf_signed_fixtures.json"), .process("Vectors/lxmf_announce_fixtures.json")]
        ),
        .testTarget(
            name: "ReTiCAInterfacesTests",
            dependencies: [
                "ReTiCAInterfaces",
                // The live Meshtastic tests drive CoreBluetoothMock, which is process-global: they
                // live in THIS target, nested in the serialized `FCBDriverAdapterCBMTests`, so they
                // never overlap the BLE adapter's CBM tests.
                "ReTiCAMeshtasticLive",
                .product(name: "MeshtasticKit", package: "MeshtasticKit"),
                .product(name: "MeshtasticMock", package: "MeshtasticKit"),
                .product(name: "MeshProto", package: "MeshtasticKit"),
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FCBComposable", package: "FCB"),
                .product(name: "CoreBluetoothMock", package: "IOS-CoreBluetooth-Mock"),
            ],
            resources: [.process("Vectors/ble_fixtures.json"), .process("Vectors/meshtastic_fixtures.json"), .process("Vectors/meshtastic_our_split.json")]
        ),
        .target(
            name: "ReTiCATransport",
            dependencies: [
                "ReTiCA",
                "Cbzip2",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SwiftEdDSA", package: "SwiftEdDSA"),
            ]
        ),
        .testTarget(
            name: "ReTiCATransportTests",
            dependencies: [
                "ReTiCATransport",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            resources: [.process("Vectors/transport_fixtures.json"), .process("Vectors/proof_fixtures.json")]
        ),
        .target(
            name: "ReTiCANode",
            dependencies: [
                "ReTiCAInterfaces",
                "ReTiCATransport",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .testTarget(
            name: "ReTiCANodeTests",
            dependencies: [
                "ReTiCANode",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        // Shared per-device identity storage (Keychain access group). Depends only on the
        // dependency-free core so any app can adopt it without pulling in TCA or transports.
        .target(
            name: "ReTiCAKeychain",
            dependencies: ["ReTiCA"]
        ),
        .testTarget(
            name: "ReTiCAKeychainTests",
            dependencies: ["ReTiCAKeychain", "ReTiCA"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

Run: `swift package --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration resolve > /tmp/meshtastic-integration/t3-resolve.log 2>&1`
Expected: exit 0; `Package.resolved` gains `swift-protobuf`. A "conflicting identity" warning or error for `fcb` or `meshtastickit` means the symlink layout broke: STOP and report.

- [ ] **Step 2: Write the failing mapping tests**

Create `R/Tests/ReTiCAInterfacesTests/MeshtasticLiveMappingTests.swift`:

```swift
import Testing
import Foundation
import MeshProto
import MeshtasticKit
import ReTiCAInterfaces
@testable import ReTiCAMeshtasticLive

private let mappingOwn: UInt32 = 0x0000_A0A0
private let mappingPeer: UInt32 = 0x0000_B001

private func mapped(_ event: MeshtasticEvent, ownNode: UInt32? = mappingOwn) -> MeshtasticDriverEvent? {
    MeshtasticDriver.driverEvent(for: event, ownNode: ownNode)
}

private func port76(from: UInt32, _ payload: Data) -> MeshtasticEvent {
    .packet(from: from, to: 0xFFFF_FFFF, channel: 0, portnum: 76, payload: payload, id: 9)
}

/// Contract 2's live mapping: `.configured` → `.connected`, a lost link → `.disconnected`,
/// `.packet(portnum 76, from ≠ myNodeNum)` → `.fragment`, adapter → `.unavailable`. The adapter
/// maps `.packet`, never `.frame` (Contract 1).
@Suite struct MeshtasticLiveMappingTests {
    @Test func configuredMapsToConnectedWithTheNodeAndPreset() {
        #expect(mapped(.configured(myNodeNum: mappingOwn, modemPreset: 6))
                == .connected(myNodeNum: mappingOwn, modemPreset: 6))
    }

    @Test func aPeersPort76PacketMapsToAFragment() {
        let payload = Data([0x01, 0xFF, 0xAB])
        #expect(mapped(port76(from: mappingPeer, payload)) == .fragment(from: mappingPeer, payload))
    }

    @Test func aPacketFromOurOwnNodeIsDropped() {
        #expect(mapped(port76(from: mappingOwn, Data([0x01, 0xFF, 0xAB]))) == nil)
    }

    /// Before the first `.configured` the node number is unknown: nothing is dropped as "own".
    @Test func aPacketBeforeTheNodeIsKnownIsKept() {
        let payload = Data([0x02, 0xFF, 0xCD])
        #expect(mapped(port76(from: mappingPeer, payload), ownNode: nil) == .fragment(from: mappingPeer, payload))
    }

    @Test(arguments: [UInt32(1), 3, 5, 75, 77, 256])
    func otherPortsAreDropped(port: UInt32) {
        let event = MeshtasticEvent.packet(from: mappingPeer, to: 0xFFFF_FFFF, channel: 0, portnum: port,
                                           payload: Data([0x01, 0xFF, 0xAB]), id: 3)
        #expect(mapped(event) == nil)
    }

    @Test(arguments: [1, 4])
    func aLostLinkMapsToDisconnected(attempt: Int) {
        #expect(mapped(.connection(.reconnecting(attempt: attempt))) == .disconnected(reason: nil))
    }

    @Test func anExplicitDisconnectMapsToDisconnected() {
        #expect(mapped(.connection(.disconnected(reason: nil))) == .disconnected(reason: nil))
    }

    /// Review Focus 1: "radio not found" must reach Diagnostics, and an interface emits no delegate
    /// for a drop of a radio that never came online.
    @Test func aTerminalSessionEndIsReportedAsUnavailableWithItsReason() {
        #expect(mapped(.connection(.disconnected(reason: "radio not found"))) == .unavailable(.other("radio not found")))
    }

    /// MeshtasticKit emits `.adapterUnavailable` before ending with these, so they stay plain drops.
    @Test(arguments: ["unauthorized", "unsupported"])
    func anAdapterTerminalEndStaysDisconnected(reason: String) {
        #expect(mapped(.connection(.disconnected(reason: reason))) == .disconnected(reason: reason))
    }

    @Test(arguments: [MeshtasticConnectionState.connecting, .configuring, .connected])
    func connectionProgressIsIgnored(state: MeshtasticConnectionState) {
        #expect(mapped(.connection(state)) == nil)
    }

    @Test func routingAndFramesAreIgnored() {
        #expect(mapped(.routing(packetID: 7, ok: true)) == nil)
        #expect(mapped(.frame(FromRadio())) == nil)
    }

    @Test(arguments: zip([MeshtasticAdapterUnavailable.poweredOff, .unauthorized, .unsupported, .other("x")],
                         [BLEAdapterUnavailable.poweredOff, .unauthorized, .unsupported, .other("x")]))
    func adapterCausesMapOneToOne(kit: MeshtasticAdapterUnavailable, ble: BLEAdapterUnavailable) {
        #expect(mapped(.adapterUnavailable(kit)) == .unavailable(ble))
    }
}
```

- [ ] **Step 3: Run to see them fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration --filter MeshtasticLiveMappingTests > /tmp/meshtastic-integration/t3-red.log 2>&1`
Expected: build error — no module `ReTiCAMeshtasticLive` sources / no `driverEvent`.

- [ ] **Step 4: Implement the live driver**

Create `R/Sources/ReTiCAMeshtasticLive/MeshtasticDriver+Live.swift`:

```swift
import Foundation
import ComposableArchitecture
import MeshtasticKit
import ReTiCAInterfaces

extension MeshtasticDriver {
    /// landandair's `RETICULUM_TUNNEL_APP` (Meshtastic_Interface.py:65; MeshProto portnums.pb.swift:233).
    public static let reticulumTunnelPort: UInt32 = 76

    /// Contract 2's live value over ONE `MeshtasticSession`. `start` subscribes to the session's
    /// events, then connects to `config.radio` (retrieve-only — the session never scans); `send`
    /// writes one frame on port 76 to broadcast with the config's channel and hop limit, wantAck
    /// false; `stop` disconnects and always returns. Reconnecting is MeshtasticKit's: the
    /// interface just sees repeated `.connected` / `.disconnected`. The session outlives every
    /// start/stop; its owner must `disconnect()` it before dropping it (its reconnect loop retains it).
    public static func live(session: MeshtasticSession) -> MeshtasticDriver {
        let adapter = MeshtasticLiveAdapter(session: session)
        return MeshtasticDriver(start: { adapter.start($0) },
                                send: { await adapter.send($0) },
                                stop: { await adapter.stop() })
    }

    /// Session end reasons that follow an `.adapterUnavailable` event (MeshtasticKit
    /// `waitForPoweredOn`), so they stay plain drops.
    static let adapterEndReasons: Set<String> = ["unauthorized", "unsupported"]

    /// The pure event mapping. `ownNode` is the radio's node number once configured (nil before):
    /// packets it sent itself (our own rebroadcasts) are dropped. Maps `.packet`, never `.frame`.
    static func driverEvent(for event: MeshtasticEvent, ownNode: UInt32?) -> MeshtasticDriverEvent? {
        switch event {
        case let .configured(myNodeNum, modemPreset):
            return .connected(myNodeNum: myNodeNum, modemPreset: modemPreset)
        case let .packet(from, _, _, portnum, payload, _):
            guard portnum == reticulumTunnelPort, from != ownNode else { return nil }
            return .fragment(from: from, payload)
        case .connection(.reconnecting):
            return .disconnected(reason: nil)
        case let .connection(.disconnected(reason)):
            // A terminal end that is not an adapter cause ("radio not found") would otherwise be
            // invisible: the interface reports no delegate for a drop of a never-online radio.
            if let reason, !adapterEndReasons.contains(reason) { return .unavailable(.other(reason)) }
            return .disconnected(reason: reason)
        case .connection(.connecting), .connection(.configuring), .connection(.connected):
            return nil
        case let .adapterUnavailable(cause):
            return .unavailable(bleCause(cause))
        case .routing, .frame:
            return nil
        }
    }

    static func bleCause(_ cause: MeshtasticAdapterUnavailable) -> BLEAdapterUnavailable {
        switch cause {
        case .poweredOff:          return .poweredOff
        case .unauthorized:        return .unauthorized
        case .unsupported:         return .unsupported
        case let .other(detail):   return .other(detail)
        }
    }
}

/// The state behind `MeshtasticDriver.live(session:)`.
final class MeshtasticLiveAdapter: Sendable {
    let session: MeshtasticSession
    /// The current start's config, read by `send` (Contract 2's `send` takes only the frame).
    private let config = LockIsolated<MeshtasticDriverConfig?>(nil)
    /// `connect(radio:)` calls launched by `start` that have not returned yet.
    private let pendingConnects = LockIsolated(0)

    init(session: MeshtasticSession) {
        self.session = session
    }

    func start(_ newConfig: MeshtasticDriverConfig) -> AsyncStream<MeshtasticDriverEvent> {
        config.setValue(newConfig)
        // Subscribe BEFORE connecting: MeshtasticKit registers a subscriber synchronously, so this
        // stream sees every event of the connect below (the current state is replayed first).
        let events = session.events()
        let session = self.session
        let pendingConnects = self.pendingConnects
        pendingConnects.withValue { $0 += 1 }
        // CoreBluetooth connects never time out: connect from a task (Contract 1).
        Task {
            await session.connect(radio: newConfig.radio)
            pendingConnects.withValue { $0 -= 1 }
        }
        return AsyncStream { continuation in
            let pump = Task {
                var ownNode: UInt32?
                for await event in events {
                    if case let .configured(myNodeNum, _) = event { ownNode = myNodeNum }
                    if let mapped = MeshtasticDriver.driverEvent(for: event, ownNode: ownNode) {
                        continuation.yield(mapped)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    func send(_ frame: Data) async -> Bool {
        guard let config = config.value else { return false }
        do {
            _ = try await session.send(MeshtasticOutbound(portnum: MeshtasticDriver.reticulumTunnelPort,
                                                         payload: frame, channel: config.channel,
                                                         wantAck: false, hopLimit: config.hopLimit))
            return true
        } catch {
            return false
        }
    }

    /// Always returns (Contract 3). A connect launched by `start` is an unstructured hop onto the
    /// session actor and may reach it AFTER this disconnect — it would then bring the radio up with
    /// nobody listening. A connect returns promptly once a later disconnect supersedes it, so
    /// disconnect again until none is outstanding.
    func stop() async {
        config.setValue(nil)
        await session.disconnect()
        while pendingConnects.value > 0 {
            await Task.yield()
            await session.disconnect()
        }
    }
}
```

- [ ] **Step 5: Run to green (a)**

Run the Step 3 command. Expected: all `MeshtasticLiveMappingTests` pass.

- [ ] **Step 6: Mutation verification (b), then (c)**

Back up `Sources/ReTiCAMeshtasticLive/MeshtasticDriver+Live.swift` to `/tmp/meshtastic-integration/MeshtasticDriverLive.swift.orig`.

- **N1**: `return .connected(myNodeNum: myNodeNum, modemPreset: modemPreset)` → `return .connected(myNodeNum: myNodeNum, modemPreset: nil)`.
- **N2**: `guard portnum == reticulumTunnelPort, from != ownNode else { return nil }` → `guard portnum == reticulumTunnelPort, let ownNode, from == ownNode else { return nil }` (breaks both the own-drop and the unknown-node clauses).
- **N3**: `portnum == reticulumTunnelPort` → `portnum != 0` (in the same guard — apply after restoring N2's line, see per-clause).
- **N4**: `case .connection(.reconnecting):\n            return .disconnected(reason: nil)` → `case .connection(.reconnecting):\n            return nil`.
- **N5**: `if let reason, !adapterEndReasons.contains(reason) { return .unavailable(.other(reason)) }` → delete the line.
- **N6**: `static let adapterEndReasons: Set<String> = ["unauthorized", "unsupported"]` → `static let adapterEndReasons: Set<String> = []`.
- **N7**: `case .connection(.connecting), .connection(.configuring), .connection(.connected):\n            return nil` → `... return .disconnected(reason: "progress")`.
- **N8**: `case .routing, .frame:\n            return nil` → `return .disconnected(reason: "noise")`.
- **N9**: `case .poweredOff:          return .poweredOff` → `case .poweredOff:          return .other(nil)`.

Combined batch (N3 cannot share N2's line): N1, N2, N4, N5 (N6 then has no effect — so leave N6 for its own batch), N7, N8, N9 → every test fails EXCEPT `otherPortsAreDropped` and `anAdapterTerminalEndStaysDisconnected`, which are covered by the next two batches; record that, then:
- N3 alone → `otherPortsAreDropped` (all arguments) fails.
- N6 alone → `anAdapterTerminalEndStaysDisconnected` (both arguments) fails.
- N2 alone → `aPacketFromOurOwnNodeIsDropped`, `aPacketBeforeTheNodeIsKnownIsKept` fail.
- N5 alone → `aTerminalSessionEndIsReportedAsUnavailableWithItsReason` fails.
- N4 alone → `aLostLinkMapsToDisconnected` fails.

Restore, rerun, all pass.

- [ ] **Step 7: Commit**

Stage `Package.swift Package.resolved Sources/ReTiCAMeshtasticLive/MeshtasticDriver+Live.swift Tests/ReTiCAInterfacesTests/MeshtasticLiveMappingTests.swift`. Message `/tmp/meshtastic-integration/commit-task3.txt`:
```
feat: ReTiCAMeshtasticLive, the live MeshtasticDriver over MeshtasticKit

Contract 2's live value. MeshtasticDriver.live(session:) maps configured to
connected, a lost link to disconnected, a port-76 packet from another node to
a fragment and adapter causes to unavailable. A terminal session end that is
not an adapter cause (radio not found) is reported as unavailable so the app
can show it. send writes port 76 to broadcast with the config's channel and
hop limit, and stop disconnects until no connect it launched is outstanding.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

---

### Task 4: Live loopback over FCB `mocked()` against MeshtasticMock (spec §7 E.1)

**Files:**
- Create: `R/Tests/ReTiCAInterfacesTests/MeshtasticLiveTestSupport.swift`
- Create: `R/Tests/ReTiCAInterfacesTests/MeshtasticLiveDriverTests.swift`
- Create: `R/Tests/ReTiCAInterfacesTests/MeshtasticLiveInterfaceTests.swift`

**Interfaces:**
- Consumes: Task 3's `MeshtasticDriver.live(session:)`; MeshtasticMock's `MockMeshtasticDevice` (`selfNodeNum = 0xA0A0`, `nodeNums`, `makeSpec(identifier:)`, `injectIncomingPacket(portnum:payload:from:...)`, `receivedPackets`, `answersWantConfig`); FCB `BluetoothCentralClient.mocked()`; CBM `simulateDisconnection()`, `simulateProximityChange(_:)`, `CBMCentralManagerMock.simulatePowerOff()/simulatePowerOn()`.
- Consumes (unchanged, NOT edited by this lane): the serialized suite `FCBDriverAdapterCBMTests` (`FCBDriverAdapterCBMTests.swift:58-59`), which lane F also extends from its new `FCBDriverAdapterCBMCoexistenceTests.swift`. Its name and nesting must stay exactly as they are.
- Produces (test support, used by Tasks 5–6): `LiveRadio`, `makeLiveRadio(preset:initialState:extra:)`, `liveWaitUntilPoweredOn(_:)`, `liveWaitUntil(timeout:_:)`, `returnsWithin(_:_:)`, `liveSessionIs(_:_:)`, `LiveDriverRun`.

- [ ] **Step 1: Check the serialized parent and lane F's names**

Run: `grep -n "Suite(.serialized)" /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration/Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMTests.swift`
Expected: one hit, the `FCBDriverAdapterCBMTests` declaration. Do NOT edit that file. Every new CBM suite below is `extension FCBDriverAdapterCBMTests { @Suite @MainActor struct … }`; nested suites inherit `.serialized`.
Lane F adds `FCBDriverAdapterCBMCoexistenceTests.swift` to the same target (now, if it is already on ReTiCA main, or at Task 8's rebase). Its internal helpers are `CoexistRig`, `makeCoexistRig`, `DriverEventLog`, `RadioScanLog`, `poll(within:_:)`, `returns(within:_:)`, `isPeerDiscovered`, `isIdentityOutcome`, `isChannelOutcome`, `coexistRadioServiceUUID` and `FCBDriverAdapterCBMTests.bleOnlineWithOpenChannel(_:)`. This lane's internal names (`LiveRadio`, `LiveDriverRun`, `liveWaitUntil`, `returnsWithin`, `liveSessionIs`, `makeLiveRadio`, …) and its `private` ones do not collide with them; keep it that way if a name is added.

- [ ] **Step 2: Test support**

Create `R/Tests/ReTiCAInterfacesTests/MeshtasticLiveTestSupport.swift`:

```swift
import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
import FCBComposable
import MeshProto
import MeshtasticKit
import MeshtasticMock
import ReTiCAInterfaces

/// One simulated Meshtastic radio plus the LIVE FCB client that drives it through CBM.
struct LiveRadio {
    let id: UUID
    let device: MockMeshtasticDevice
    let spec: CBMPeripheralSpec
    let central: BluetoothCentralClient

    /// Non-default channel and hop limit, so a send that ignored the config is caught.
    var config: MeshtasticDriverConfig { MeshtasticDriverConfig(radio: id, channel: 2, hopLimit: 3) }
}

/// Resets the CBM simulation and stands up one mock radio (plus `extra` specs).
@MainActor
func makeLiveRadio(preset: Config.LoRaConfig.ModemPreset? = .shortFast,
                   initialState: CBMManagerState = .poweredOn,
                   extra: [CBMPeripheralSpec] = []) async -> LiveRadio {
    CBMCentralManagerMock.tearDownSimulation()
    CBMCentralManagerMock.simulateInitialState(initialState)
    let id = UUID()
    let device = MockMeshtasticDevice(now: { Date(timeIntervalSince1970: 2_000_000_000) }, modemPreset: preset)
    let spec = device.makeSpec(identifier: id)
    CBMCentralManagerMock.simulatePeripherals([spec] + extra)
    let central = BluetoothCentralClient.mocked()
    if initialState == .poweredOn { await liveWaitUntilPoweredOn(central) }
    return LiveRadio(id: id, device: device, spec: spec, central: central)
}

/// Polls FCB's replaying state stream until the mock manager reports power-on.
func liveWaitUntilPoweredOn(_ central: BluetoothCentralClient) async {
    for _ in 0..<200 {
        var iterator = central.state().makeAsyncIterator()
        if await iterator.next() == .poweredOn { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Polls `condition` every 10 ms until true or `timeout` (real time).
func liveWaitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Whether `work` returns within `limit`. Unstructured on purpose: a hung `work` must not hang
/// the test (a task group would wait for it).
func returnsWithin(_ limit: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
    let done = LockIsolated(false)
    Task {
        await work()
        done.setValue(true)
    }
    return await liveWaitUntil(timeout: limit) { done.value }
}

/// The session's CURRENT connection state is `state` (MeshtasticKit replays it to a new subscriber).
func liveSessionIs(_ session: MeshtasticSession, _ state: MeshtasticConnectionState,
                   timeout: Duration = .seconds(5)) async -> Bool {
    let seen = LockIsolated(false)
    let stream = session.events()
    let watcher = Task {
        for await event in stream where event == .connection(state) {
            seen.setValue(true)
            return
        }
    }
    defer { watcher.cancel() }
    return await liveWaitUntil(timeout: timeout) { seen.value }
}

/// A driver stream consumed in the background.
final class LiveDriverRun: Sendable {
    let events = LockIsolated<[MeshtasticDriverEvent]>([])
    private let task = LockIsolated<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<MeshtasticDriverEvent>) {
        let events = self.events
        task.setValue(Task {
            for await event in stream { events.withValue { $0.append(event) } }
        })
    }

    func cancel() { task.value?.cancel() }

    func waitFor(timeout: Duration = .seconds(10),
                 _ match: @escaping @Sendable (MeshtasticDriverEvent) -> Bool) async -> Bool {
        await liveWaitUntil(timeout: timeout) { self.events.value.contains(where: match) }
    }

    func count(_ match: @Sendable (MeshtasticDriverEvent) -> Bool) -> Int {
        events.value.filter(match).count
    }
}

let livePeer: UInt32 = MockMeshtasticDevice.nodeNums[0]
let liveConnected = MeshtasticDriverEvent.connected(myNodeNum: MockMeshtasticDevice.selfNodeNum,
                                                   modemPreset: Config.LoRaConfig.ModemPreset.shortFast.rawValue)

func isLiveConnected(_ event: MeshtasticDriverEvent) -> Bool {
    if case .connected = event { return true }
    return false
}
```

- [ ] **Step 3: The adapter loopback tests**

Create `R/Tests/ReTiCAInterfacesTests/MeshtasticLiveDriverTests.swift`:

```swift
import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
import FCBComposable
import MeshProto
import MeshtasticKit
import MeshtasticMock
import ReTiCAInterfaces
@testable import ReTiCAMeshtasticLive

/// `MeshtasticDriver.live(session:)` over a REAL `MeshtasticSession` over FCB's LIVE client
/// (`mocked()`) against `MeshtasticMock` — not a hand mock (mocked-boundaries lesson). Sessions use
/// their default ContinuousClock: the 30 s handshake timeout would fire at once on an ImmediateClock.
extension FCBDriverAdapterCBMTests {
    @Suite @MainActor
    struct MeshtasticLiveDriverTests {
        @Test func liveDriverConnectsWithTheRadiosNodeAndPreset() async {
            let radio = await makeLiveRadio(preset: .shortFast)
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            let saw = await run.waitFor { $0 == liveConnected }
            #expect(saw, "events: \(run.events.value)")
            await driver.stop()
            run.cancel()
        }

        @Test func liveDriverDeliversAPeersPort76Payload() async {
            let radio = await makeLiveRadio()
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            _ = await run.waitFor(isLiveConnected)
            let frame = Data([0x04, 0xFF]) + Data(repeating: 0x33, count: 40)
            radio.device.injectIncomingPacket(portnum: .reticulumTunnelApp, payload: frame, from: livePeer)
            let saw = await run.waitFor { $0 == .fragment(from: livePeer, frame) }
            #expect(saw, "events: \(run.events.value)")
            await driver.stop()
            run.cancel()
        }

        /// Review Focus 4. Injected in order, so the own frame is drained before the peer's.
        @Test func liveDriverDropsItsOwnNodesPackets() async {
            let radio = await makeLiveRadio()
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            _ = await run.waitFor(isLiveConnected)
            let own = Data([0x05, 0xFF, 0x01])
            let peer = Data([0x06, 0xFF, 0x02])
            radio.device.injectIncomingPacket(portnum: .reticulumTunnelApp, payload: own, from: MockMeshtasticDevice.selfNodeNum)
            radio.device.injectIncomingPacket(portnum: .reticulumTunnelApp, payload: peer, from: livePeer)
            #expect(await run.waitFor { $0 == .fragment(from: livePeer, peer) }, "precondition: the peer's frame arrived")
            #expect(run.count { if case .fragment(MockMeshtasticDevice.selfNodeNum, _) = $0 { return true }; return false } == 0)
            await driver.stop()
            run.cancel()
        }

        /// Review Focus 4. The mock also routing-acks every write, on port 5.
        @Test func liveDriverDropsOtherPorts() async {
            let radio = await makeLiveRadio()
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            _ = await run.waitFor(isLiveConnected)
            let marker = Data([0x07, 0xFF, 0x03])
            radio.device.injectIncomingPacket(portnum: .textMessageApp, payload: Data("hi".utf8), from: livePeer)
            radio.device.injectIncomingPacket(portnum: .positionApp, payload: Data([0x01]), from: livePeer)
            radio.device.injectIncomingPacket(portnum: .reticulumTunnelApp, payload: marker, from: livePeer)
            _ = await run.waitFor { $0 == .fragment(from: livePeer, marker) }
            #expect(run.count { if case .fragment = $0 { return true }; return false } == 1)
            await driver.stop()
            run.cancel()
        }

        @Test func liveDriverSendsOnPort76ToBroadcastWithTheConfigsChannelAndHopLimit() async {
            let radio = await makeLiveRadio()
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            _ = await run.waitFor(isLiveConnected)
            let frame = Data([0x08, 0xFF]) + Data(repeating: 0x5A, count: 150)
            let ok = await driver.send(frame)
            #expect(ok)
            let written = radio.device.receivedPackets.last
            #expect(written?.decoded.portnum == .reticulumTunnelApp)
            #expect(written?.decoded.payload == frame)
            #expect(written?.to == 0xFFFF_FFFF)
            #expect(written?.channel == 2)
            #expect(written?.hopLimit == 3)
            #expect(written?.wantAck == false)
            await driver.stop()
            run.cancel()
        }

        @Test func liveDriverSendBeforeTheRadioIsConnectedReturnsFalse() async {
            let radio = await makeLiveRadio()
            radio.device.answersWantConfig = false
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            let ok = await driver.send(Data([0x09, 0xFF, 0x01]))
            #expect(!ok)
            await driver.stop()
            run.cancel()
        }

        @Test func liveDriverSendOfAnOversizedFrameReturnsFalse() async {
            let radio = await makeLiveRadio()
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            _ = await run.waitFor(isLiveConnected)
            let ok = await driver.send(Data(repeating: 0x01, count: 234))
            #expect(!ok)
            await driver.stop()
            run.cancel()
        }

        @Test func liveDriverReportsALostLinkAsDisconnectedThenReconnects() async {
            let radio = await makeLiveRadio()
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            _ = await run.waitFor(isLiveConnected)
            radio.spec.simulateDisconnection()
            let dropped = await run.waitFor { $0 == .disconnected(reason: nil) }
            #expect(dropped, "events: \(run.events.value)")
            let back = await liveWaitUntil(timeout: .seconds(10)) { run.count(isLiveConnected) == 2 }
            #expect(back, "events: \(run.events.value)")
            await driver.stop()
            run.cancel()
        }

        /// Review Focus 2.
        @Test func liveDriverComesBackAfterABluetoothPowerCycle() async {
            let radio = await makeLiveRadio()
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            _ = await run.waitFor(isLiveConnected)
            CBMCentralManagerMock.simulatePowerOff()
            let dropped = await run.waitFor { $0 == .disconnected(reason: nil) }
            #expect(dropped, "events: \(run.events.value)")
            CBMCentralManagerMock.simulatePowerOn()
            let back = await liveWaitUntil(timeout: .seconds(15)) { run.count(isLiveConnected) == 2 }
            #expect(back, "events: \(run.events.value)")
            await driver.stop()
            run.cancel()
        }

        /// Review Focus 1.
        @Test func liveDriverReportsAnUnknownRadioAsUnavailable() async {
            let radio = await makeLiveRadio()
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(MeshtasticDriverConfig(radio: UUID())))
            let saw = await run.waitFor { $0 == .unavailable(.other("radio not found")) }
            #expect(saw, "events: \(run.events.value)")
            await driver.stop()
            run.cancel()
        }

        @Test func liveDriverReportsAPoweredOffAdapterAsUnavailable() async {
            let radio = await makeLiveRadio(initialState: .poweredOff)
            let driver = MeshtasticDriver.live(session: MeshtasticSession(central: radio.central))
            let run = LiveDriverRun(driver.start(radio.config))
            let saw = await run.waitFor { $0 == .unavailable(.poweredOff) }
            #expect(saw, "events: \(run.events.value)")
            await driver.stop()
            run.cancel()
        }

        @Test func liveDriverStopReturnsWhileTheHandshakeIsStuck() async {
            let radio = await makeLiveRadio()
            radio.device.answersWantConfig = false
            let session = MeshtasticSession(central: radio.central)
            let driver = MeshtasticDriver.live(session: session)
            let run = LiveDriverRun(driver.start(radio.config))
            let configuring = await liveSessionIs(session, .configuring)
            #expect(configuring, "precondition: the handshake started")
            let returned = await returnsWithin(.seconds(5)) { await driver.stop() }
            #expect(returned)
            run.cancel()
        }

        /// Review Focus 3: CoreBluetooth connects never time out.
        @Test func liveDriverStopReturnsWhileTheRadioIsOutOfRange() async {
            let radio = await makeLiveRadio()
            radio.spec.simulateProximityChange(.outOfRange)
            let session = MeshtasticSession(central: radio.central)
            let driver = MeshtasticDriver.live(session: session)
            let run = LiveDriverRun(driver.start(radio.config))
            let connecting = await liveSessionIs(session, .connecting)
            #expect(connecting, "precondition: the connect is pending")
            try? await Task.sleep(for: .milliseconds(300))
            let returned = await returnsWithin(.seconds(5)) { await driver.stop() }
            #expect(returned)
            run.cancel()
        }

        @Test func liveDriverStopLeavesTheSessionDisconnected() async {
            let radio = await makeLiveRadio()
            let session = MeshtasticSession(central: radio.central)
            let driver = MeshtasticDriver.live(session: session)
            let run = LiveDriverRun(driver.start(radio.config))
            _ = await run.waitFor(isLiveConnected)
            await driver.stop()
            try? await Task.sleep(for: .milliseconds(500))
            let down = await liveSessionIs(session, .disconnected(reason: nil), timeout: .milliseconds(300))
            #expect(down)
            run.cancel()
        }

        /// The adapter's connect is an unstructured hop onto the session actor; a stop issued at
        /// once must still leave nothing connected.
        @Test func liveDriverStopRightAfterStartLeavesTheSessionDisconnected() async {
            let radio = await makeLiveRadio()
            let session = MeshtasticSession(central: radio.central)
            let driver = MeshtasticDriver.live(session: session)
            let run = LiveDriverRun(driver.start(radio.config))
            await driver.stop()
            try? await Task.sleep(for: .milliseconds(800))
            let down = await liveSessionIs(session, .disconnected(reason: nil), timeout: .milliseconds(300))
            #expect(down)
            #expect(run.count(isLiveConnected) == 0, "events: \(run.events.value)")
            run.cancel()
        }
    }
}
```

- [ ] **Step 4: The reducer-over-live-driver tests**

Create `R/Tests/ReTiCAInterfacesTests/MeshtasticLiveInterfaceTests.swift`:

```swift
import Testing
import Foundation
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
import MeshProto
import MeshtasticKit
import MeshtasticMock
@testable import ReTiCAInterfaces
import ReTiCAMeshtasticLive

/// LIVE values end to end: the `MeshtasticInterface` reducer over `MeshtasticDriver.live` over a
/// real session over FCB `mocked()` over MeshtasticMock. Pacing on an ImmediateClock is fine — the
/// session keeps its own ContinuousClock.
@MainActor
private func makeLiveInterface(_ radio: LiveRadio) -> TestStore<MeshtasticInterface.State, MeshtasticInterface.Action> {
    let session = MeshtasticSession(central: radio.central)
    let store = TestStore(initialState: MeshtasticInterface.State(config: radio.config)) {
        MeshtasticInterface()
    } withDependencies: {
        $0.meshtasticDriver = .live(session: session)
        $0.meshtasticClock = ImmediateClock()
        $0.meshtasticDate = DateGenerator { Date(timeIntervalSince1970: 1_000) }
    }
    store.exhaustivity = .off
    return store
}

@MainActor
private func goOnline(_ store: TestStore<MeshtasticInterface.State, MeshtasticInterface.Action>) async {
    await store.send(.start)
    await store.receive({ $0 == .delegate(.online(myNodeNum: MockMeshtasticDevice.selfNodeNum,
                                                  modemPreset: Config.LoRaConfig.ModemPreset.shortFast.rawValue)) },
                        timeout: .seconds(10))
}

private func livePattern(_ count: Int, seed: UInt8) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0) &+ seed })
}

extension FCBDriverAdapterCBMTests {
    @Suite @MainActor
    struct MeshtasticLiveInterfaceTests {
        @Test func liveRadioPutsAPacketsFragmentsOnPort76() async {
            let radio = await makeLiveRadio()
            let store = makeLiveInterface(radio)
            await goOnline(store)
            let packet = livePattern(300, seed: 3)
            await store.send(.send(packet))
            let expected = LandandairCodec().split(packet, index: 0)
            let sent = await liveWaitUntil(timeout: .seconds(10)) {
                radio.device.receivedPackets.filter { $0.decoded.portnum == .reticulumTunnelApp }.count == expected.count
            }
            #expect(sent)
            #expect(radio.device.receivedPackets.filter { $0.decoded.portnum == .reticulumTunnelApp }.map(\.decoded.payload) == expected)
            await store.send(.stop)
            await store.skipReceivedActions(strict: false)
        }

        @Test func liveRadioReassemblesAPeersFragments() async {
            let radio = await makeLiveRadio()
            let store = makeLiveInterface(radio)
            await goOnline(store)
            let packet = livePattern(400, seed: 9)
            for frame in LandandairCodec().split(packet, index: 12) {
                radio.device.injectIncomingPacket(portnum: .reticulumTunnelApp, payload: frame, from: livePeer)
            }
            await store.receive({ $0 == .delegate(.packetReceived(packet)) }, timeout: .seconds(10))
            await store.send(.stop)
            await store.skipReceivedActions(strict: false)
        }

        /// Contract 3 with the LIVE driver: `driver.stop()` returns, and offline follows it.
        @Test func liveRadioStopReportsOfflineAfterTheDriverStops() async {
            let radio = await makeLiveRadio()
            let store = makeLiveInterface(radio)
            await goOnline(store)
            await store.send(.stop)
            await store.receive({ $0 == .driverStopped }, timeout: .seconds(10))
            await store.receive({ $0 == .delegate(.offline(reason: nil)) }, timeout: .seconds(2))
        }
    }
}
```

- [ ] **Step 5: Run (a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration --filter MeshtasticLiveDriverTests --filter MeshtasticLiveInterfaceTests --filter FCBDriverAdapterCBMTests > /tmp/meshtastic-integration/t4-green.log 2>&1`
Expected: all pass. These are real-time tests (backoff is 1 s); expect a few tens of seconds. If `liveDriverComesBackAfterABluetoothPowerCycle` fails inside FCB (a stale pending read after power-off — lane F's defect 2), STOP and report: do not patch FCB or MeshtasticKit here.

- [ ] **Step 6: Mutation verification (b), then (c)**

Back up `MeshtasticDriver+Live.swift` again to `/tmp/meshtastic-integration/MeshtasticDriverLive.swift.orig`.

- **L1**: in `send`, `portnum: MeshtasticDriver.reticulumTunnelPort` → `portnum: 1`.
- **L2**: `channel: config.channel` → `channel: 0`.
- **L3**: `hopLimit: config.hopLimit` → `hopLimit: nil`.
- **L4**: `wantAck: false` → `wantAck: true`.
- **L5**: in `send`'s `catch`, `return false` → `return true`.
- **L6**: in `start`'s pump, delete `if case let .configured(myNodeNum, _) = event { ownNode = myNodeNum }`.
- **L7**: in `driverEvent`, `guard portnum == reticulumTunnelPort, from != ownNode` → `guard from != ownNode`.
- **L8**: in `driverEvent`, `case .connection(.reconnecting):\n            return .disconnected(reason: nil)` → `return nil`.
- **L9**: in `driverEvent`, delete `if let reason, !adapterEndReasons.contains(reason) { return .unavailable(.other(reason)) }`.
- **L10**: in `driverEvent`, `case .packet` arm returns `nil` unconditionally (replace the arm body with `return nil`).
- **L11** (stop never disconnects but still returns): replace the body of `stop()` with `config.setValue(nil)`.
- **L12** (stop hangs): replace the body of `stop()` with `config.setValue(nil)\n        while pendingConnects.value >= 0 { await Task.yield() }`.
- **L13**: in `driverEvent`, `case let .configured(myNodeNum, modemPreset):\n            return .connected(myNodeNum: myNodeNum, modemPreset: modemPreset)` → `return .connected(myNodeNum: 0, modemPreset: modemPreset)`.
- **L14**: in `driverEvent`, `case let .adapterUnavailable(cause):\n            return .unavailable(bleCause(cause))` → `return nil`.

Some mutations cannot share a run: L7 and L10 edit the same arm, L11 and L12 replace the same body, and under L12 every test that ends with `await driver.stop()` hangs. So the "one batch" is three runs that together cover every test exactly once:
- **Batch A** — L1, L5, L6, L8, L9, L11, L13, L14; run the whole Step 5 set. Fail: `liveDriverConnectsWithTheRadiosNodeAndPreset` (L13), `liveDriverDropsItsOwnNodesPackets` (L6), `liveDriverSendsOnPort76ToBroadcastWithTheConfigsChannelAndHopLimit` (L1), `liveDriverSendBeforeTheRadioIsConnectedReturnsFalse` and `liveDriverSendOfAnOversizedFrameReturnsFalse` (L5), `liveDriverReportsALostLinkAsDisconnectedThenReconnects` and `liveDriverComesBackAfterABluetoothPowerCycle` (L8), `liveDriverReportsAnUnknownRadioAsUnavailable` (L9), `liveDriverReportsAPoweredOffAdapterAsUnavailable` (L14), `liveDriverStopLeavesTheSessionDisconnected` and `liveDriverStopRightAfterStartLeavesTheSessionDisconnected` (L11), and all three `MeshtasticLiveInterfaceTests` (L13: `goOnline` expects the radio's exact node). Not expected to fail here: the four tests of batches B and C.
- **Batch B** — L10 alone; `--filter liveDriverDeliversAPeersPort76Payload --filter liveDriverDropsOtherPorts`: both fail (no fragment ever arrives).
- **Batch C** — L12 alone; `--filter liveDriverStopReturnsWhileTheHandshakeIsStuck --filter liveDriverStopReturnsWhileTheRadioIsOutOfRange --filter liveRadioStopReportsOfflineAfterTheDriverStops` (ONLY these: the others would hang on their final stop): all three fail. L12 leaks hung tasks; expected under the mutation.

Per-clause batches (restore between each):
- L2 alone, L3 alone, L4 alone → `liveDriverSendsOnPort76ToBroadcastWithTheConfigsChannelAndHopLimit` fails each time.
- L7 alone → `liveDriverDropsOtherPorts` fails.
- L6 alone → `liveDriverDropsItsOwnNodesPackets` fails.
- L8 alone → `liveDriverReportsALostLinkAsDisconnectedThenReconnects`, `liveDriverComesBackAfterABluetoothPowerCycle` fail.
- L9 alone → `liveDriverReportsAnUnknownRadioAsUnavailable` fails.
- L13 alone → `liveDriverConnectsWithTheRadiosNodeAndPreset` fails.

The adapter's stop LOOP (disconnect until no connect is outstanding) has no deterministic mutation: whether a connect reaches the session after the first disconnect depends on executor ordering. Record that in the commit body; `liveDriverStopRightAfterStartLeavesTheSessionDisconnected` exercises the path but cannot force the interleaving. Restore, rerun Step 5, all pass. `git -C … status` shows only the three new test files (`FCBDriverAdapterCBMTests.swift` untouched).

- [ ] **Step 7: Commit**

Stage the three new test files of this task (`MeshtasticLiveTestSupport.swift`, `MeshtasticLiveDriverTests.swift`, `MeshtasticLiveInterfaceTests.swift`). Message `/tmp/meshtastic-integration/commit-task4.txt`:
```
test: live Meshtastic driver loopback over FCB mocked() and MeshtasticMock

MeshtasticDriver.live over a real MeshtasticSession over FCB's live client
against MeshtasticMock: connect with node and preset, port-76 delivery,
own-echo and port filtering, send fields, a lost link, a power cycle, an
unknown radio, and stop returning while stuck in the handshake or out of
range. MeshtasticInterface over the live driver puts fragments on port 76,
reassembles a peer's, and reports offline after the live stop returns. The
new CBM suites nest in the serialized FCBDriverAdapterCBMTests. The stop
loop's late-connect branch has no deterministic mutation (executor ordering).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

---

### Task 5: `MeshtasticLive` — the live session factory and a terminal-aware radio scan

**Files:**
- Create: `R/Sources/ReTiCAMeshtasticLive/MeshtasticLive.swift`
- Create: `R/Tests/ReTiCAInterfacesTests/MeshtasticLiveScanTests.swift`

**Interfaces:**
- Consumes: `MeshtasticScanner.scan(central:) -> AsyncStream<DiscoveredRadio>` (Contract 1), `BluetoothCentralClient.state()`, `.liveValue`.
- Produces (Task 9 and Task 13 call these from the app):
  - `public static func MeshtasticLive.makeSession() -> MeshtasticSession`
  - `public static func MeshtasticLive.scanRadios() -> AsyncStream<DiscoveredRadio>`
  - `public static func MeshtasticLive.scanRadios(central: BluetoothCentralClient) -> AsyncStream<DiscoveredRadio>` — yields the scanner's radios; FINISHES when the scanner finishes or the adapter reports `.unauthorized` / `.unsupported`; cancelling the consumer ends the FCB scan.

- [ ] **Step 1: Write the failing tests**

Create `R/Tests/ReTiCAInterfacesTests/MeshtasticLiveScanTests.swift`:

```swift
import Testing
import Foundation
@preconcurrency import CoreBluetooth
import ComposableArchitecture
import FCBComposable
import MeshtasticKit
import ReTiCAMeshtasticLive

private struct FakeCentral {
    let client: BluetoothCentralClient
    let scanEnded: LockIsolated<Bool>
}

/// A closure central (no CBM): `state()` replays `states` and stays open; `scan` yields `found`.
private func fakeCentral(states: [CBManagerState], found: [DiscoveredPeripheral] = []) -> FakeCentral {
    let scanEnded = LockIsolated(false)
    var client = BluetoothCentralClient.testValue
    client.state = {
        AsyncStream { continuation in
            for state in states { continuation.yield(state) }
        }
    }
    client.scan = { _, _ in
        AsyncStream { continuation in
            for peripheral in found { continuation.yield(peripheral) }
            continuation.onTermination = { _ in scanEnded.setValue(true) }
        }
    }
    return FakeCentral(client: client, scanEnded: scanEnded)
}

private final class ScanRun: Sendable {
    let radios = LockIsolated<[DiscoveredRadio]>([])
    let finished = LockIsolated(false)
    private let task = LockIsolated<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<DiscoveredRadio>) {
        let radios = self.radios
        let finished = self.finished
        task.setValue(Task {
            for await radio in stream { radios.withValue { $0.append(radio) } }
            finished.setValue(true)
        })
    }

    func cancel() { task.value?.cancel() }
}

private let scanRadioID = UUID(uuidString: "5CA40000-0000-4000-8000-000000000001")!

@Suite struct MeshtasticLiveScanTests {
    @Test func scanRadiosYieldsTheScannersRadios() async {
        let found = DiscoveredPeripheral(peripheral: Peripheral(id: scanRadioID, name: "P", state: .disconnected),
                                         advertisementData: AdvertisementData(localName: "Meshtastic_1a2b"), rssi: -50)
        let fake = fakeCentral(states: [.poweredOn], found: [found])
        let run = ScanRun(MeshtasticLive.scanRadios(central: fake.client))
        let saw = await liveWaitUntil { !run.radios.value.isEmpty }
        #expect(saw)
        #expect(run.radios.value.first == DiscoveredRadio(id: scanRadioID, name: "Meshtastic_1a2b", rssi: -50))
        run.cancel()
    }

    @Test func scanRadiosFinishesWhenTheAdapterIsUnsupported() async {
        let fake = fakeCentral(states: [.unsupported])
        let run = ScanRun(MeshtasticLive.scanRadios(central: fake.client))
        let ended = await liveWaitUntil(timeout: .seconds(2)) { run.finished.value }
        #expect(ended)
    }

    @Test func scanRadiosFinishesWhenTheAdapterIsUnauthorized() async {
        let fake = fakeCentral(states: [.unauthorized])
        let run = ScanRun(MeshtasticLive.scanRadios(central: fake.client))
        let ended = await liveWaitUntil(timeout: .seconds(2)) { run.finished.value }
        #expect(ended)
    }

    /// Powered off is not "stopped for good": the user can turn Bluetooth on.
    @Test func scanRadiosKeepsWaitingWhilePoweredOff() async {
        let fake = fakeCentral(states: [.poweredOff])
        let run = ScanRun(MeshtasticLive.scanRadios(central: fake.client))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!run.finished.value)
        run.cancel()
    }

    @Test func cancellingTheConsumerEndsTheUnderlyingScan() async {
        let fake = fakeCentral(states: [.poweredOn])
        let run = ScanRun(MeshtasticLive.scanRadios(central: fake.client))
        try? await Task.sleep(for: .milliseconds(100))
        run.cancel()
        let ended = await liveWaitUntil(timeout: .seconds(2)) { fake.scanEnded.value }
        #expect(ended)
    }
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration --filter MeshtasticLiveScanTests > /tmp/meshtastic-integration/t5-red.log 2>&1` → build error: no `MeshtasticLive`.

- [ ] **Step 3: Implement**

Create `R/Sources/ReTiCAMeshtasticLive/MeshtasticLive.swift`:

```swift
import Foundation
@preconcurrency import CoreBluetooth
import FCBComposable
import MeshtasticKit

/// What an app needs to run Meshtastic live, without naming FCB itself.
public enum MeshtasticLive {
    /// A session over FCB's process-wide live central — the same `BluetoothCentralClient.liveValue`
    /// `BLEDriver.liveValue` uses, so BLE and the radio share the ONE central (spec §2). The caller
    /// owns it and must `disconnect()` it before dropping it (its reconnect loop retains it).
    public static func makeSession() -> MeshtasticSession {
        MeshtasticSession(central: .liveValue)
    }

    /// `scanRadios(central:)` over the live central.
    public static func scanRadios() -> AsyncStream<DiscoveredRadio> {
        scanRadios(central: .liveValue)
    }

    /// `MeshtasticScanner.scan(central:)`, plus the end it lacks: the stream FINISHES when the
    /// adapter is unauthorized or unsupported (MeshtasticScanner waits for `.poweredOn` forever),
    /// so a radio picker never spins on an adapter that cannot scan. It also finishes when the
    /// scanner does. Cancelling the consumer ends the FCB scan.
    public static func scanRadios(central: BluetoothCentralClient) -> AsyncStream<DiscoveredRadio> {
        AsyncStream { continuation in
            let scan = Task {
                for await radio in MeshtasticScanner.scan(central: central) { continuation.yield(radio) }
                continuation.finish()
            }
            let watch = Task {
                for await state in central.state() where state == .unauthorized || state == .unsupported {
                    continuation.finish()
                    return
                }
            }
            continuation.onTermination = { _ in
                scan.cancel()
                watch.cancel()
            }
        }
    }
}
```

- [ ] **Step 4: Run to green (a)** — Step 2's command, all pass.

- [ ] **Step 5: Mutation verification (b), then (c)**

Back up `MeshtasticLive.swift` to `/tmp/meshtastic-integration/MeshtasticLive.swift.orig`.
- **S1**: `where state == .unauthorized || state == .unsupported` → `where state == .unauthorized`.
- **S2**: same clause → `where state == .unsupported`.
- **S3**: `for await radio in MeshtasticScanner.scan(central: central) { continuation.yield(radio) }` → `for await _ in MeshtasticScanner.scan(central: central) {}`.
- **S4**: delete `scan.cancel()` in `onTermination`.
- **S5**: add `|| state == .poweredOff` to the watch's `where`.

Combined batch S1 + S3 + S4 + S5 → `scanRadiosFinishesWhenTheAdapterIsUnsupported`, `scanRadiosYieldsTheScannersRadios`, `cancellingTheConsumerEndsTheUnderlyingScan`, `scanRadiosKeepsWaitingWhilePoweredOff` fail; then S2 alone → `scanRadiosFinishesWhenTheAdapterIsUnauthorized` fails; then each of S1, S3, S4, S5 alone → its test fails. Restore, rerun, pass.

- [ ] **Step 6: Commit**

Stage `Sources/ReTiCAMeshtasticLive/MeshtasticLive.swift Tests/ReTiCAInterfacesTests/MeshtasticLiveScanTests.swift`. Message `/tmp/meshtastic-integration/commit-task5.txt`:
```
feat: MeshtasticLive builds the live session and a scan that ends for good

makeSession() builds a MeshtasticSession over FCB's process-wide live central,
the one BLEDriver.liveValue uses. scanRadios(central:) wraps MeshtasticScanner
and finishes when the adapter is unauthorized or unsupported, which the
scanner alone never does, so a picker cannot spin forever. An app gets both
without depending on FCB.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

---

### Task 6: Coexistence probe — RBTP `BLEDriver` and the radio on ONE live central (spec §7 E.2)

**Files:**
- Create: `R/Tests/ReTiCAInterfacesTests/MeshtasticCoexistenceTests.swift`

**Interfaces:**
- Consumes: `BLEDriver.fcb(central:peripheral:)` (`FCBDriverAdapter.swift:769`), `noopPeripheralClient()`, `V22SpecDelegate` (`FCBDriverAdapterCBMTests.swift:11-55`), `txCharUUID`/`rxCharUUID`/`identityCharUUID`/`serviceUUID`/`adapterLocalIdentity` (`FCBDriverAdapterTests.swift:8-13`), `MeshtasticDriver.live`, `MeshtasticScanner.scan`, Task 4's support.
- Produces: the probe. Disconnect-filtering tests must pass NOW. The two scan-interference tests are `withKnownIssue` until lane F; Task 13 flips them.

- [ ] **Step 1: Write the probe**

Create `R/Tests/ReTiCAInterfacesTests/MeshtasticCoexistenceTests.swift`:

```swift
import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
import FCBComposable
import MeshProto
import MeshtasticKit
import MeshtasticMock
@testable import ReTiCAInterfaces
import ReTiCAMeshtasticLive

/// One live central shared by an RBTP BLE driver (with one ble-reticulum peer) and a Meshtastic
/// radio session, as ReTiCAMsgr runs them (`BLEDriver.liveValue` and `MeshtasticLive.makeSession()`
/// both use FCB's `liveValue`).
@MainActor
private struct CoexistenceRig {
    let central: BluetoothCentralClient
    let radioID: UUID
    let radio: MockMeshtasticDevice
    let radioSpec: CBMPeripheralSpec
    let radio2ID: UUID
    let radio2Spec: CBMPeripheralSpec
    let peerSpec: CBMPeripheralSpec
    let peerDelegate: V22SpecDelegate
    let ble: BLEDriver
    let mesh: MeshtasticDriver
}

@MainActor
private func makeCoexistenceRig() async -> CoexistenceRig {
    CBMCentralManagerMock.tearDownSimulation()
    CBMCentralManagerMock.simulateInitialState(.poweredOn)
    let radioID = UUID()
    let radio = MockMeshtasticDevice(now: { Date(timeIntervalSince1970: 2_000_000_000) }, modemPreset: .shortFast)
    let radioSpec = radio.makeSpec(identifier: radioID)
    let radio2ID = UUID()
    let radio2Spec = MockMeshtasticDevice().makeSpec(identifier: radio2ID)
    let tx = CBMCharacteristicMock(type: txCharUUID, properties: [.read, .notify])
    let rx = CBMCharacteristicMock(type: rxCharUUID, properties: [.write, .writeWithoutResponse])
    let ident = CBMCharacteristicMock(type: identityCharUUID, properties: [.read])
    let service = CBMServiceMock(type: serviceUUID, primary: true, characteristics: tx, rx, ident)
    let peerDelegate = V22SpecDelegate()
    let peerSpec = CBMPeripheralSpec
        .simulatePeripheral(identifier: UUID(), proximity: .near)
        .advertising(advertisementData: [CBMAdvertisementDataServiceUUIDsKey: [serviceUUID],
                                         CBMAdvertisementDataIsConnectable: true as NSNumber],
                     withInterval: 0.05)
        .connectable(name: "rns-peer", services: [service], delegate: peerDelegate, connectionInterval: 0.01)
        .build()
    CBMCentralManagerMock.simulatePeripherals([radioSpec, radio2Spec, peerSpec])
    // The second radio starts out of range; a probe brings it in to test a scan still yields.
    // If CBM rejects a proximity change before a manager exists, move this line after `mocked()`.
    radio2Spec.simulateProximityChange(.outOfRange)
    let central = BluetoothCentralClient.mocked()
    await liveWaitUntilPoweredOn(central)
    return CoexistenceRig(central: central, radioID: radioID, radio: radio, radioSpec: radioSpec,
                          radio2ID: radio2ID, radio2Spec: radio2Spec, peerSpec: peerSpec,
                          peerDelegate: peerDelegate,
                          ble: BLEDriver.fcb(central: central, peripheral: noopPeripheralClient()),
                          mesh: MeshtasticDriver.live(session: MeshtasticSession(central: central)))
}

private final class BLERun: Sendable {
    let events = LockIsolated<[BLEDriverEvent]>([])
    private let task = LockIsolated<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<BLEDriverEvent>) {
        let events = self.events
        task.setValue(Task { for await event in stream { events.withValue { $0.append(event) } } })
    }

    func cancel() { task.value?.cancel() }

    func first(timeout: Duration = .seconds(6), _ match: @escaping @Sendable (BLEDriverEvent) -> Bool) async -> BLEDriverEvent? {
        _ = await liveWaitUntil(timeout: timeout) { self.events.value.contains(where: match) }
        return events.value.first(where: match)
    }
}

private final class RadioScanRun: Sendable {
    let radios = LockIsolated<[DiscoveredRadio]>([])
    let finished = LockIsolated(false)
    private let task = LockIsolated<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<DiscoveredRadio>) {
        let radios = self.radios
        let finished = self.finished
        task.setValue(Task {
            for await radio in stream { radios.withValue { $0.append(radio) } }
            finished.setValue(true)
        })
    }

    func cancel() { task.value?.cancel() }
}

/// Discovers the ble-reticulum peer, reads its identity and opens an outbound GATT channel.
@MainActor
private func openBLEChannel(_ rig: CoexistenceRig, _ run: BLERun) async -> BLEChannelID? {
    guard case let .peerDiscovered(handle)? = await run.first(where: { if case .peerDiscovered = $0 { return true }; return false })
    else { return nil }
    await rig.ble.readIdentity(handle)
    guard await run.first(where: { if case .identityRead = $0 { return true }; return false }) != nil else { return nil }
    await rig.ble.openChannel(handle)
    guard case let .channelOpened(cid, _, _, _, _)? = await run.first(where: { if case .channelOpened = $0 { return true }; return false })
    else { return nil }
    return cid
}

private let coexistFrame = Data([0x01, 0x00, 0x00, 0x00, 0x01, 0x42])

extension FCBDriverAdapterCBMTests {
    @Suite @MainActor
    struct MeshtasticCoexistenceTests {
        @Test func aBLEPeerDroppingLeavesTheRadioConnected() async {
            let rig = await makeCoexistenceRig()
            let mesh = LiveDriverRun(rig.mesh.start(MeshtasticDriverConfig(radio: rig.radioID)))
            #expect(await mesh.waitFor(isLiveConnected))
            let ble = BLERun(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
            let channel = await openBLEChannel(rig, ble)
            #expect(channel != nil, "precondition: BLE channel open, events \(ble.events.value)")
            rig.peerSpec.simulateDisconnection()
            let closed = await ble.first { if case .channelClosed = $0 { return true }; return false }
            #expect(closed != nil, "precondition: the BLE peer dropped")
            try? await Task.sleep(for: .milliseconds(500))
            #expect(mesh.count { $0 == .disconnected(reason: nil) } == 0, "the radio saw the BLE peer's drop: \(mesh.events.value)")
            let before = rig.radio.receivedPackets.count
            #expect(await rig.mesh.send(Data([0x00, 0xFF, 0x01])))
            #expect(rig.radio.receivedPackets.count == before + 1)
            await rig.ble.stop(); ble.cancel()
            await rig.mesh.stop(); mesh.cancel()
        }

        @Test func theRadioDroppingLeavesTheBLEChannelOpen() async {
            let rig = await makeCoexistenceRig()
            let mesh = LiveDriverRun(rig.mesh.start(MeshtasticDriverConfig(radio: rig.radioID)))
            #expect(await mesh.waitFor(isLiveConnected))
            let ble = BLERun(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
            guard let channel = await openBLEChannel(rig, ble) else {
                Issue.record("precondition: BLE channel open, events \(ble.events.value)")
                return
            }
            rig.radioSpec.simulateDisconnection()
            #expect(await mesh.waitFor { $0 == .disconnected(reason: nil) })
            try? await Task.sleep(for: .milliseconds(500))
            #expect(ble.events.value.allSatisfy { if case .channelClosed = $0 { return false }; return true },
                    "the BLE channel closed with the radio: \(ble.events.value)")
            await rig.ble.send(channel, [coexistFrame])
            #expect(await liveWaitUntil(timeout: .seconds(3)) { rig.peerDelegate.writes.value.contains(coexistFrame) })
            await rig.ble.stop(); ble.cancel()
            await rig.mesh.stop(); mesh.cancel()
        }

        @Test func stoppingBLELeavesTheRadioConnected() async {
            let rig = await makeCoexistenceRig()
            let mesh = LiveDriverRun(rig.mesh.start(MeshtasticDriverConfig(radio: rig.radioID)))
            #expect(await mesh.waitFor(isLiveConnected))
            let ble = BLERun(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
            #expect(await openBLEChannel(rig, ble) != nil)
            await rig.ble.stop()
            ble.cancel()
            try? await Task.sleep(for: .milliseconds(500))
            #expect(mesh.count { $0 == .disconnected(reason: nil) } == 0, "events: \(mesh.events.value)")
            let before = rig.radio.receivedPackets.count
            #expect(await rig.mesh.send(Data([0x00, 0xFF, 0x02])))
            #expect(rig.radio.receivedPackets.count == before + 1)
            await rig.mesh.stop(); mesh.cancel()
        }

        @Test func stoppingTheRadioLeavesTheBLEChannelOpen() async {
            let rig = await makeCoexistenceRig()
            let mesh = LiveDriverRun(rig.mesh.start(MeshtasticDriverConfig(radio: rig.radioID)))
            #expect(await mesh.waitFor(isLiveConnected))
            let ble = BLERun(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
            guard let channel = await openBLEChannel(rig, ble) else {
                Issue.record("precondition: BLE channel open")
                return
            }
            await rig.mesh.stop()
            mesh.cancel()
            try? await Task.sleep(for: .milliseconds(500))
            #expect(ble.events.value.allSatisfy { if case .channelClosed = $0 { return false }; return true })
            await rig.ble.send(channel, [coexistFrame])
            #expect(await liveWaitUntil(timeout: .seconds(3)) { rig.peerDelegate.writes.value.contains(coexistFrame) })
            await rig.ble.stop(); ble.cancel()
        }

        /// Open side (spec §7 F.1(a)): the picker's radio scan is running when the paused BLE
        /// driver's stop runs its `central.stopScan()` (FCBDriverAdapter.swift:276). FCB's live
        /// `stopScan()` ends WHATEVER scan is current (BluetoothCentralClient+Live.swift:228-231),
        /// so the picker stops seeing radios. Deterministic. Known issue until lane F, after which
        /// `stopScan()` is a no-op and the adapter no longer calls it. (After lane F the radio scan
        /// superseding BLE's scan also FINISHES BLE's stream, and the adapter reports
        /// `.unavailable(.other("scan superseded by another scanner"))` on `ble` — expected, and not
        /// asserted here: the claim is only that the radio scan survives BLE's stop.)
        @Test func aBLEStopAfterTheRadioScanStartedDoesNotEndIt() async {
            let rig = await makeCoexistenceRig()
            let ble = BLERun(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
            _ = await ble.first { if case .peerDiscovered = $0 { return true }; return false }   // BLE is scanning
            let scan = RadioScanRun(MeshtasticScanner.scan(central: rig.central))
            #expect(await liveWaitUntil { scan.radios.value.contains { $0.id == rig.radioID } },
                    "precondition: the radio scan saw the first radio")
            await rig.ble.stop()
            ble.cancel()
            rig.radio2Spec.simulateProximityChange(.near)
            await withKnownIssue("Lane F (spec §7 F.1a): BLE's stopScan ends the picker's scan. Remove this wrapper when lane F lands (plan Task 13).") {
                let secondFound = await liveWaitUntil(timeout: .seconds(3)) { scan.radios.value.contains { $0.id == rig.radio2ID } }
                #expect(secondFound, "the radio scan stopped yielding after BLE stopped (finished: \(scan.finished.value))")
                #expect(!scan.finished.value)
            }
            scan.cancel()
        }

        /// Dismiss side, settled: the radio scan has fully ended before BLE restarts. FCB's
        /// stream-termination stop is token-scoped (BluetoothCentralClient+Live.swift:475-479), so
        /// this is expected to pass today. If it fails, STOP and report: that is a defect beyond
        /// lane F's described scope.
        @Test func aRadioScanThatEndedBeforeBLERestartedLeavesBLEDiscovering() async {
            let rig = await makeCoexistenceRig()
            let scan = RadioScanRun(MeshtasticScanner.scan(central: rig.central))
            #expect(await liveWaitUntil { scan.radios.value.contains { $0.id == rig.radioID } })
            scan.cancel()
            #expect(await liveWaitUntil(timeout: .seconds(2)) { scan.finished.value })
            try? await Task.sleep(for: .milliseconds(200))
            let ble = BLERun(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
            let discovered = await ble.first { if case .peerDiscovered = $0 { return true }; return false }
            #expect(discovered != nil, "BLE online but not discovering: \(ble.events.value)")
            await rig.ble.stop(); ble.cancel()
        }

        /// Dismiss side, racing (spec §7 F.1(b), mechanism corrected by lane F's plan: FCB starts a
        /// scan through an unordered task, so a scan whose start runs late supersedes the newer one).
        /// The picker closes just as its scan starts and BLE restarts at once. Before lane F a late
        /// radio-scan start silently orphans BLE's scan: BLE stays "online" but never discovers.
        /// After lane F a stream terminated before its own start never starts the radio, so BLE
        /// discovers at once; and IF a supersession still happened it is no longer silent — the
        /// adapter reports `.unavailable(.other("scan superseded by another scanner"))` (BLEInterface
        /// would then retry after its 5–120 s backoff, which this driver-level probe does not wait
        /// for). The probe waits for whichever comes first, bounded at 3 s, and fails on either
        /// "superseded" or silence. Swept over ten rounds; an INTERMITTENT known issue until lane F.
        @Test func aRadioScanCancelledAsBLERestartsLeavesBLEDiscovering() async {
            await withKnownIssue("Lane F (spec §7 F.1b): a late radio-scan start supersedes BLE's restarted scan. Remove this wrapper when lane F lands (plan Task 13).",
                                 isIntermittent: true) {
                for round in 0..<10 {
                    let rig = await makeCoexistenceRig()
                    let scan = RadioScanRun(MeshtasticScanner.scan(central: rig.central))
                    try? await Task.sleep(for: .milliseconds(round))
                    scan.cancel()
                    let ble = BLERun(rig.ble.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
                    let superseded = BLEDriverEvent.unavailable(.other("scan superseded by another scanner"))
                    let outcome = await ble.first(timeout: .seconds(3)) { event in
                        if case .peerDiscovered = event { return true }
                        return event == superseded
                    }
                    if outcome == superseded {
                        Issue.record("round \(round): the cancelled radio scan superseded BLE's restarted scan")
                    } else {
                        #expect(outcome != nil, "round \(round): BLE online but not discovering")
                    }
                    await rig.ble.stop(); ble.cancel()
                }
            }
        }
    }
}
```

- [ ] **Step 2: Run (a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration --filter MeshtasticCoexistenceTests > /tmp/meshtastic-integration/t6.log 2>&1`
Expected: the four disconnect/stop tests and `aRadioScanThatEndedBeforeBLERestartedLeavesBLEDiscovering` PASS. `aBLEStopAfterTheRadioScanStartedDoesNotEndIt` passes AS A KNOWN ISSUE (the log shows the issue recorded as known). `aRadioScanCancelledAsBLERestartsLeavesBLEDiscovering` passes whether or not the race hits; note in Task 8's summary whether a known issue was recorded. If a disconnect-filtering test FAILS, that is an FCB or MeshtasticKit defect: STOP and report it with the log; do not patch either repo.
If `aBLEStopAfterTheRadioScanStartedDoesNotEndIt` reports "Known issue was not recorded", lane F has already landed: remove its wrapper now and record that in the commit.

- [ ] **Step 3: Mutation verification (b), then (c)**

The code under probe is mostly FCB's (per-peripheral disconnect, scan ownership) and MeshtasticKit's (the session's disconnect watch filters on its own radio, `MeshtasticSession.swift:545-563`), which this lane must not edit. In-repo mutations exist for the BLE side only (`FCBDriverAdapter.swift`, back it up first):
- **C1** (`handleCentralEvent`): replace the body of the `case let .didDisconnect(p, _):` arm with `forget(p.id)` followed by `for cid in Array(outboundByPeer.values) { await outboundDidClose(cid, reason: "disconnected", disconnect: false) }` — every peripheral's disconnect closes every BLE channel → `theRadioDroppingLeavesTheBLEChannelOpen` and `stoppingTheRadioLeavesTheBLEChannelOpen` fail (the radio's stop disconnects the radio's peripheral).
- **C2** (`resetSession`): after `for peerID in peers { try? await central.disconnect(peerID) }` add `for p in await central.retrieveConnected([CBUUID(string: "6ba1b218-15a8-461f-9fa8-5dcae273eafd")]) { try? await central.disconnect(p.id) }` — BLE's stop also drops the connected Meshtastic radio → `stoppingBLELeavesTheRadioConnected` fails. If CBM's `retrieveConnected` returns nothing here (the mutation then changes nothing), record "C2 unreachable under CBM" in the commit. (If lane F has already reshaped `resetSession`, put the line directly after its peer-disconnect loop, wherever that now is.)
- `aBLEPeerDroppingLeavesTheRadioConnected` has NO in-repo mutation: its filter lives in MeshtasticKit. Record that.
Apply C1 + C2 together, run the suite once (the three named tests fail), then each alone, restore, rerun Step 2. The two scan probes' red state is the recorded known issue itself; they flip only when lane F lands (Task 13).

- [ ] **Step 4: Commit**

Stage `Tests/ReTiCAInterfacesTests/MeshtasticCoexistenceTests.swift`. Message `/tmp/meshtastic-integration/commit-task6.txt`:
```
test: coexistence probe for RBTP BLE and a Meshtastic radio on one central

Spec section 7 E.2. One live FCB central runs the BLE driver and a live
Meshtastic session. A BLE peer's drop and BLE's stop leave the radio up, and
the radio's drop and stop leave the BLE channel open. The two scan
interference cases are pinned as known issues until lane F lands: BLE's
stopScan ends the picker's scan (deterministic), and a superseding scan's
teardown can end BLE's restarted scan (intermittent). The radio-side
filtering lives in MeshtasticKit and has no in-repo mutation.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

---

### Task 7: Hardware tooling — the Mac LXMF probe and the checklist sheet (spec §7 E.4 prep)

**Files:**
- Create: `R/Scripts/meshtastic-hardware/lxmf_probe.py`
- Create: `R/docs/superpowers/plans/2026-10-16-meshtastic-hardware-checklist.md`

**Interfaces:**
- Consumes: conda env `rns` (`rns` 1.4.2, `lxmf` 1.1.0): `RNS.Reticulum`, `RNS.Identity`, `RNS.Destination`, `RNS.Transport.has_path/request_path/register_announce_handler`, `LXMF.LXMRouter(identity=, storagepath=)`, `register_delivery_identity(identity, display_name=)`, `register_delivery_callback`, `announce(hash)`, `handle_outbound`, `LXMF.LXMessage(destination, source, content, title, desired_method=)`, `LXMF.display_name_from_app_data`.
- Produces: the script Task 15 runs, and the results sheet Task 15 fills.

- [ ] **Step 1: Write the probe**

Create `R/Scripts/meshtastic-hardware/lxmf_probe.py`:

```python
#!/usr/bin/env python
"""LXMF probe for the Meshtastic hardware run (spec 2026-10-16 section 1 criterion 3, lane E).

Runs as a client of the Mac's shared rnsd instance (default config dir) or, with --config,
as its own Reticulum instance. Prints its LXMF address, announces it, prints every LXMF
delivery announce it hears (so the iPhone's address can be read off), prints every message
it receives, and with --send sends one message to a destination.

Run in the conda env `rns` with `python` (not python3):
  /Users/ell/opt/anaconda3/envs/rns/bin/python -u <path>/lxmf_probe.py --name "Mac probe"
"""
import argparse
import os
import sys
import time

import RNS
import LXMF


class DeliveryAnnounceLogger:
    aspect_filter = "lxmf.delivery"

    def received_announce(self, destination_hash, announced_identity, app_data):
        name = LXMF.display_name_from_app_data(app_data)
        print(f"[{time.strftime('%H:%M:%S')}] ANNOUNCE {RNS.hexrep(destination_hash, delimit=False)} name={name!r}",
              flush=True)


def load_identity(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.isfile(path):
        return RNS.Identity.from_file(path)
    identity = RNS.Identity()
    identity.to_file(path)
    return identity


def send(router, source, args):
    destination_hash = bytes.fromhex(args.send)
    if not RNS.Transport.has_path(destination_hash):
        RNS.Transport.request_path(destination_hash)
        deadline = time.time() + args.path_timeout
        while not RNS.Transport.has_path(destination_hash) and time.time() < deadline:
            time.sleep(0.5)
    recipient_identity = RNS.Identity.recall(destination_hash)
    if recipient_identity is None:
        print(f"no path or identity for {args.send} after {args.path_timeout} s", flush=True)
        sys.exit(2)
    recipient = RNS.Destination(recipient_identity, RNS.Destination.OUT, RNS.Destination.SINGLE,
                                "lxmf", "delivery")
    method = LXMF.LXMessage.DIRECT if args.method == "direct" else LXMF.LXMessage.OPPORTUNISTIC
    message = LXMF.LXMessage(recipient, source, args.text, "hw probe", desired_method=method)
    started = time.time()
    message.register_delivery_callback(
        lambda m: print(f"DELIVERED after {time.time() - started:.1f} s", flush=True))
    message.register_failed_callback(
        lambda m: print(f"FAILED after {time.time() - started:.1f} s", flush=True))
    router.handle_outbound(message)
    print(f"queued {args.method} message to {args.send}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", default=None, help="Reticulum config dir (default: the shared instance)")
    parser.add_argument("--identity", default=os.path.expanduser("~/.reticulum-lxmf-probe/identity"))
    parser.add_argument("--name", default="ReTiCA hw probe")
    parser.add_argument("--send", metavar="DEST_HEX", help="LXMF delivery address to send one message to")
    parser.add_argument("--text", default="hello from the Mac over Meshtastic")
    parser.add_argument("--method", choices=["opportunistic", "direct"], default="opportunistic")
    parser.add_argument("--path-timeout", type=float, default=180.0)
    parser.add_argument("--announce-every", type=float, default=600.0)
    args = parser.parse_args()

    RNS.Reticulum(args.config)
    identity = load_identity(args.identity)
    router = LXMF.LXMRouter(identity=identity, storagepath=os.path.join(os.path.dirname(args.identity), "lxmf"))
    source = router.register_delivery_identity(identity, display_name=args.name)

    def on_message(message):
        print(f"[{time.strftime('%H:%M:%S')}] RECEIVED from {RNS.hexrep(message.source_hash, delimit=False)} "
              f"method={message.method} signature_validated={message.signature_validated} "
              f"title={message.title_as_string()!r} content={message.content_as_string()!r}", flush=True)

    router.register_delivery_callback(on_message)
    RNS.Transport.register_announce_handler(DeliveryAnnounceLogger())
    print(f"LXMF address: {RNS.hexrep(source.hash, delimit=False)}", flush=True)
    router.announce(source.hash)
    if args.send:
        send(router, source, args)
    last_announce = time.time()
    while True:
        time.sleep(1)
        if time.time() - last_announce >= args.announce_every:
            router.announce(source.hash)
            last_announce = time.time()


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Check it compiles and parses its arguments**

Run: `/Users/ell/opt/anaconda3/envs/rns/bin/python -m py_compile /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration/Scripts/meshtastic-hardware/lxmf_probe.py`
Expected: no output, exit 0.
Run: `/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration/Scripts/meshtastic-hardware/lxmf_probe.py --help`
Expected: the usage text (the `import RNS` / `import LXMF` lines succeed). No tests are written for this tool; it is exercised by Task 15.

- [ ] **Step 3: Write the checklist sheet**

Create `R/docs/superpowers/plans/2026-10-16-meshtastic-hardware-checklist.md` with exactly this content:

````markdown
# Meshtastic (lane E) — Hardware Verification Checklist and Results

Spec: `docs/superpowers/specs/2026-10-16-meshtastic-interface-design.md` §1 criterion 3, §7 lane E
item 4, §9. Performed by the user with two physical Meshtastic radios; nothing here is automated.
Every shell line below is ONE command.

## Equipment (fill in first)

| | Radio A (iPhone side) | Radio B (Mac / second iPhone side) |
|---|---|---|
| model | | |
| firmware version (`meshtastic --port <port> --info`, or the Meshtastic app) | | |
| region | | |
| modem preset (name and raw value, e.g. ShortFast 6) | | |
| LoRa hop limit | | |
| primary channel name and PSK identical on both? | | |

| | value |
|---|---|
| iPhone model(s), iOS version(s) | |
| ReTiCAMsgr build (app `main` commit) | |
| ReTiCA `main` commit | |
| Mac `meshtastic` python package version (`conda run -n rns python -m pip show meshtastic`) | |

Both radios: same region, same preset, same primary channel (index 0, same name and PSK).
Prefer ShortTurbo or ShortFast (spec §1 "Expectation setting").

## Mac setup (once)

1. `conda run -n rns python -m pip install meshtastic`
2. `mkdir -p ~/.reticulum/interfaces`
3. `cp /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCAInterfacesTests/Vectors/landandair_Meshtastic_Interface.py ~/.reticulum/interfaces/Meshtastic_Interface.py`
4. `shasum -a 256 ~/.reticulum/interfaces/Meshtastic_Interface.py` → must print
   `8b71aa8efc7624dba05202c5eb356a10a48c31bee783cd4c9295038370b394ab` (landandair commit
   e5eb5d23a619958ae0556c88fcbc4bf1d867ab0a, unmodified).
5. Plug radio B into the Mac by USB. `ls /dev/cu.*` → note its port (e.g. `/dev/cu.usbserial-0001`
   or `/dev/cu.usbmodem…`). USB, not BLE: the Mac's Bluetooth should stay out of the experiment.
6. If `~/.reticulum/config` exists: `cp ~/.reticulum/config ~/.reticulum/config.pre-meshtastic`.
   Add this stanza under `[interfaces]` (the file name above makes `type = Meshtastic_Interface`
   load it; keys from landandair L88-92):
   ```
     [[Meshtastic Interface]]
       type = Meshtastic_Interface
       enabled = true
       port = /dev/cu.usbserial-0001
       data_speed = 6
       hop_limit = 1
   ```
   `port` is radio B's serial port (alternatives: `ble_port = <radio name or address>`,
   `tcp_port = <host[:port]>` for a WiFi radio — set exactly one). `data_speed` MUST be radio A's
   preset raw value (8 ShortTurbo, 6 ShortFast, 5 ShortSlow, 4 MediumFast, 3 MediumSlow,
   0 LongFast, 7 LongModerate, 1 LongSlow): landandair REWRITES radio B's preset to it on connect
   (L170-176; the radio reboots once and the interface reconnects after ~10 s) and paces by it.
   `hop_limit = 1` matches ReTiCA's fixed hop limit. No IFAC: ReTiCAMsgr v1 has no Meshtastic
   IFAC setting.
7. Start rnsd in its own terminal: `/Users/ell/opt/anaconda3/envs/rns/bin/rnsd -v`
8. In another terminal: `/Users/ell/opt/anaconda3/envs/rns/bin/rnstatus` → `MeshtasticInterface[Meshtastic Interface]` is `Up`.
9. Start the probe in a third terminal:
   `/Users/ell/opt/anaconda3/envs/rns/bin/python -u /Users/ell/development/ios/pods/ReTiCA/Scripts/meshtastic-hardware/lxmf_probe.py --name "Mac probe"`
   → prints `LXMF address: <hex>`. Record it.

## iPhone setup

- [ ] Radio A is NOT connected to the Meshtastic app or Meshtastified (one BLE client per radio).
- [ ] ReTiCAMsgr → Settings → Meshtastic: toggle on, Choose radio… → pick radio A, then Connect.
- [ ] Diagnostics → Meshtastic: status `online`, preset = radio A's, node `!xxxxxxxx`, no adapter row.

## (a) iPhone → radio A → air → radio B → Mac rnsd + landandair, and back

- [ ] The Mac probe prints `ANNOUNCE <iPhone address> name=<your display name>` (the iPhone's
      interface-up announce, targeted at the radio). Record seconds from Connect to the line.
- [ ] In ReTiCAMsgr the "Mac probe" appears in the announce list (tap Announce on the iPhone if
      needed; announces cross the radio slowly).
- [ ] iPhone → Mac: send "hello mac" to Mac probe. The probe prints `RECEIVED … content='hello mac'`
      with `signature_validated=True`. Record seconds from tap to line, and `method`.
- [ ] Mac → iPhone: stop the probe (Ctrl-C) and rerun it with
      `--send <iPhone address> --text "hello iphone"` → `DELIVERED after N s`; the message shows on
      the iPhone. Record N.
- [ ] Long message (≈1 000 characters) iPhone → Mac: it either arrives (slow, link/resource) or the
      iPhone marks it failed cleanly. No crash, no wedge; record which and how long.
- [ ] Diagnostics counters after the run: reassembled, malformed, evicted, timed out, oversize,
      queue full, send failed.

## (b) iPhone ↔ iPhone

Two iPhones, each paired with its own radio (A and B; unplug B from the Mac, stop rnsd).
- [ ] Each sees the other's announce. Messages both ways arrive; record latency each way.
- [ ] With the receiving app backgrounded: a message still arrives or arrives on foreground; no
      crash (spec §9 background risk).
- [ ] Walk one radio out of range and back: Diagnostics shows offline then online without
      touching the app.

## (c) radio → ReTiCA gateway → TCP responder

Topology: Mac probe (instance 1, radio B via rnsd) —air— radio A —BLE— iPhone gateway (ReTiCAMsgr,
Meshtastic on, Relay on, TCP node = Mac hub) —TCP— Mac hub (instance 2) —TCP— responder = ReTiCAMsgr
in an iOS Simulator (node 127.0.0.1:4242). The responder is a ReTiCA node reached over TCP, so its
link responder timeout is the fixed 15 s (spec Contract 4 choice, unverified) while the initiator
sits behind the slow radio.
1. `mkdir -p /tmp/ReTiCA-hw/tcp-hub`
2. Write `/tmp/ReTiCA-hw/tcp-hub/config`:
   ```
   [reticulum]
     enable_transport = True
     share_instance = No

   [interfaces]
     [[TCP Hub]]
       type = TCPServerInterface
       enabled = true
       listen_ip = 0.0.0.0
       listen_port = 4242
   ```
3. `/Users/ell/opt/anaconda3/envs/rns/bin/rnsd --config /tmp/ReTiCA-hw/tcp-hub -v`
4. Simulator ReTiCAMsgr: node 127.0.0.1:4242, Connect, note its LXMF address.
5. Gateway iPhone: node `<Mac LAN IP>:4242`, Meshtastic radio A on, Settings → Relay on, Connect.
- [ ] The Mac probe (instance 1) prints the simulator's ANNOUNCE (relayed by the gateway onto the radio).
- [ ] Probe rerun with `--send <simulator address> --method direct --text "via gateway"`:
      record DELIVERED / FAILED and the time, for the current preset. If it fails, retry at
      ShortTurbo. This is the measurement for the responder's 15 s choice.
- [ ] Opportunistic the same way (`--method opportunistic`): record.

## (d) hopLimit nil → firmware default

ReTiCA always sends hop limit 1 (Contract 2's config is not optional), so the `nil` path is
MeshtasticKit's, exercised through Meshtastified (its text send omits `hop_limit`,
`MeshSessionActor.swift:123-129`).
1. Stop rnsd (it holds radio B's serial port).
2. `conda run --no-capture-output -n rns meshtastic --port /dev/cu.usbserial-0001 --listen`
   (if `--listen` is unknown in the installed version, use `--debug` instead and read the packet lines).
3. Meshtastified on the iPhone, connected to radio A (ReTiCAMsgr disconnected from it): send a text
   on the public channel.
- [ ] Record the received packet's `hopStart` and `hopLimit`. Expected: `hopStart` = radio A's LoRa
      hop limit (firmware default 3 unless changed).
4. Disconnect Meshtastified, connect ReTiCAMsgr to radio A, tap Announce.
- [ ] Record the port-76 packet's `hopStart` (expected 1).

## Results

| test | preset | result | latency | notes |
|---|---|---|---|---|
| (a) announce iPhone → Mac | | | | |
| (a) iPhone → Mac message | | | | |
| (a) Mac → iPhone message | | | | |
| (a) long message | | | | |
| (b) A → B | | | | |
| (b) B → A | | | | |
| (b) background | | | | |
| (c) direct via gateway | | | | |
| (c) opportunistic via gateway | | | | |
| (d) Meshtastified hopStart | | | | |
| (d) ReTiCA hopStart | | | | |

Diagnostics counters after (a):
````

- [ ] **Step 4: Commit**

Stage both files. Message `/tmp/meshtastic-integration/commit-task7.txt`:
```
docs: Meshtastic hardware checklist and a Mac-side LXMF probe

The lane E hardware run (spec section 1 criterion 3): equipment sheet, the
landandair interface stanza for rnsd, iPhone to Mac and back, iPhone to
iPhone, radio to ReTiCA gateway to a TCP responder, and the hopLimit nil
check through Meshtastified. lxmf_probe.py prints its address, heard delivery
announces and received messages, and sends one message on request.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

---

### Task 8: Full ReTiCA suite, rebase, fast-forward ReTiCA `main`

**Files:** none changed (unless the rebase needs a fix).

- [ ] **Step 1: Full suite on the branch**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration > /tmp/meshtastic-integration/t8-full.log 2>&1` (background if > 600 s)
Expected: `Test run with N' tests ... passed`, N' = Task 1's N plus this Part's new tests. Known issues are reported as such, not failures.

- [ ] **Step 2: Rebase onto main**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA log --oneline -5 main`
If `main` moved since Task 1 (lane F may have landed ReTiCA's `FCBDriverAdapter` change):
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration rebase main`
Resolve any conflict by keeping both sides' intent, then rerun Step 1. If lane F landed and `aBLEStopAfterTheRadioScanStartedDoesNotEndIt` now reports "Known issue was not recorded", do Task 13's ReTiCA flip steps here instead and note it.

- [ ] **Step 3: Verify every commit's trailers**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-integration log main..meshtastic-integration "--format=%h %s | %(trailers:key=Claude-Session,valueonly)"`
Expected: every line ends with the session URL.

- [ ] **Step 4: Fast-forward main**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA merge --ff-only meshtastic-integration`
Expected: `Fast-forward`. (The main checkout's untracked `AUTOINTERFACE.md` is unaffected.)
Run: `git -C /Users/ell/development/ios/pods/ReTiCA log --oneline -9` → the seven lane E commits on top.

---

# Part 2 — ReTiCAMsgr (`A`), only after Part 1 is on ReTiCA `main`

### Task 9: App worktree, dependencies, live driver, and the radio slot (spec §7 E.3)

**Files:**
- Modify: `CORE/Package.swift`
- Create: `CORE/Sources/ReTiCaMsgrCore/MeshtasticLiveWiring.swift`
- Create: `CORE/Sources/ReTiCaMsgrCore/AppFeature+MeshtasticRadio.swift`
- Modify: `CORE/Sources/ReTiCaMsgrCore/AppFeature.swift` — state (after `public var meshtasticStatus = MeshtasticStatus()`, `:290`), onLaunch (`:688-702`), connectTapped (`:910-920`), `syncEndpointNodes` (`:2798-2851`), `nodeChangeEffects(_:)` (`:2894-2897`), `redialDownNodes` (`:2951-2980`), body (`:2416-2418`)
- Modify: `A/ReTiCaMsgr/AppRuntime.swift:100-124`
- Create: `CORE/Tests/ReTiCaMsgrCoreTests/MeshtasticRadioTestSupport.swift`, `CORE/Tests/ReTiCaMsgrCoreTests/MeshtasticRadioSlotTests.swift`

**Interfaces:**
- Consumes: Part 1 on ReTiCA `main`: `MeshtasticDriver.live(session:)`, `MeshtasticLive.makeSession()`, `MeshtasticInterface.State.isIdle`, Contract 3 (`TransportEndpoint.State.meshtastic`, `.meshtastic(.start/.stop)`, `.meshtastic(.delegate(.radioOffline))`, `meshtasticInterfaceID(radio:)`), `MeshtasticDriverConfig(radio:)`. Lane D: `meshtasticEnabled`, `meshtasticRadioUUID`, `radioPicker`, `blePausedForRadioScan`.
- Produces:
  - `public struct MeshtasticSlotSwap: Equatable, Sendable { var next: MeshtasticDriverConfig?; var startNext: Bool }`, `AppFeature.State.meshtasticSwap: MeshtasticSlotSwap?`
  - `AppFeature.State.meshtasticWillDial: Bool`, `.somethingWillDial: Bool` (internal)
  - `func syncMeshtasticSlot(_:) -> Effect<AppFeature.Action>`, `func finishMeshtasticSwap(_:) -> Effect`, `func installMeshtasticSlot(_:_:start:) -> Effect` (internal, `AppFeature+MeshtasticRadio.swift`)
  - `struct MeshtasticRadioReducer: Reducer` (body of `AppFeature`)
  - `syncEndpointNodes` returns `(removals:, added:, meshtastic: Effect<AppFeature.Action>)`
  - `public enum MeshtasticLiveWiring { public static func installDriver(into: inout DependencyValues) }`
  - Test support: `MeshRadioHarness`, `MeshRadioCall`, `MeshTCPHarness`, `meshRadioStore(...)`, `meshSlotRadioA/B`, `meshSlotIDA/B`, `meshBringRadioOnline`, `isInterfaceConnected`, `isRadioOffline`, `meshWaitUntil`.

- [ ] **Step 1: Gate — Part 1 is on ReTiCA main**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA log --oneline -10`
Expected: the lane E commits from Tasks 1–7. Run: `ls /Users/ell/development/ios/pods/ReTiCA/Sources/ReTiCAMeshtasticLive` → both Swift files. If not, STOP.

- [ ] **Step 2: Worktree, temp dir, baseline**

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr worktree add ../ReTiCAMsgr-meshtastic-live -b meshtastic-live`
Run: `mkdir -p /tmp/ReTiCAMsgr-meshtastic-live`
Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live/ReTiCaMsgrCore > /tmp/ReTiCAMsgr-meshtastic-live/t9-baseline.log 2>&1` → passes (lane D recorded 714). Record the count. This build already includes Part 1's ReTiCA changes (`syncEndpointNodes` does not touch the radio yet, so nothing changes).
Run: `grep -rn "meshSlot\|meshRedial\|meshStatus\|meshAnnounce\|meshSlice\|meshLiveScan" /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live/ReTiCaMsgrCore/Tests` → no matches (the prefixes are free).

- [ ] **Step 3: Dependencies**

In `CORE/Package.swift`, after `.package(path: "../../../pods/ReTiCAPush"),` add:
```swift
        // Meshtastic radio support (spec 2026-10-16 §7 lane E): the app builds the session and the
        // scanner. Same checkout ReTiCA's `../MeshtasticKit` resolves to.
        .package(path: "../../../pods/MeshtasticKit"),
```
In the `ReTiCaMsgrCore` target's dependencies, after `.product(name: "ReTiCAKeychain", package: "ReTiCA"),` add:
```swift
                .product(name: "ReTiCAMeshtasticLive", package: "ReTiCA"),
                .product(name: "MeshtasticKit", package: "MeshtasticKit"),
```
In the `ReTiCaMsgrCoreTests` target's dependencies add `.product(name: "MeshtasticKit", package: "MeshtasticKit"),`.
Run: `swift package --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live/ReTiCaMsgrCore resolve > /tmp/ReTiCAMsgr-meshtastic-live/t9-resolve.log 2>&1` → exit 0.

- [ ] **Step 4: Write the test support**

Create `CORE/Tests/ReTiCaMsgrCoreTests/MeshtasticRadioTestSupport.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
import SQLiteData
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
import ReTiCAPush
@testable import ReTiCaMsgrCore

let meshSlotRadioA = UUID(uuidString: "A0A0A0A0-0000-4000-8000-0000000000A1")!
let meshSlotRadioB = UUID(uuidString: "B0B0B0B0-0000-4000-8000-0000000000B2")!
let meshSlotIDA = meshtasticInterfaceID(radio: meshSlotRadioA)
let meshSlotIDB = meshtasticInterfaceID(radio: meshSlotRadioB)
let meshSlotOwnNode: UInt32 = 0x0A0A_0A0A
let meshSlotPeerNode: UInt32 = 0x0B0B_0B0B

enum MeshRadioCall: Equatable { case start(UUID), stop }

struct MeshSentFrame: Equatable, Sendable {
    var session: Int
    var frame: Data
}

/// A mock Meshtastic driver shaped like the live adapter: every `start` opens a FRESH session
/// stream; `stop` blocks while stops are held and records `.stop` only when it RETURNS.
final class MeshRadioHarness: Sendable {
    let calls = LockIsolated<[MeshRadioCall]>([])
    let sessions = LockIsolated<[AsyncStream<MeshtasticDriverEvent>.Continuation]>([])
    let sent = LockIsolated<[MeshSentFrame]>([])
    private let held = LockIsolated(false)

    var driver: MeshtasticDriver {
        MeshtasticDriver(
            start: { [self] config in
                let session = AsyncStream<MeshtasticDriverEvent>.makeStream()
                calls.withValue { $0.append(.start(config.radio)) }
                sessions.withValue { $0.append(session.continuation) }
                return session.stream
            },
            send: { [self] frame in
                let index = sessions.value.count - 1
                sent.withValue { $0.append(MeshSentFrame(session: index, frame: frame)) }
                return true
            },
            stop: { [self] in
                while held.value { await Task.yield() }
                sessions.value.last?.finish()
                calls.withValue { $0.append(.stop) }
            })
    }

    var startCount: Int { calls.value.filter { if case .start = $0 { return true }; return false }.count }

    func holdStops() { held.setValue(true) }
    func releaseStops() { held.setValue(false) }
    func yieldToLatest(_ event: MeshtasticDriverEvent) { sessions.value.last?.yield(event) }

    func waitForCalls(_ count: Int) async {
        for _ in 0..<300 where calls.value.count < count { await Task.megaYield() }
    }

    func waitForStarts(_ count: Int) async {
        for _ in 0..<300 where startCount < count { await Task.megaYield() }
    }

    /// Complete packets put on the air in `session`, reassembled from their landandair frames.
    func reassembled(session: Int) -> [Data] {
        var bodies: [UInt8: [Int: Data]] = [:]
        var counts: [UInt8: Int] = [:]
        for item in sent.value where item.session == session {
            guard case let .data(index, pos, body)? = LandandairCodec().parse(item.frame) else { continue }
            let slot = Int(pos.magnitude)
            bodies[index, default: [:]][slot] = body
            if pos < 0 { counts[index] = slot }
        }
        return counts.keys.sorted().compactMap { index in
            guard let n = counts[index], let parts = bodies[index], (1...n).allSatisfy({ parts[$0] != nil })
            else { return nil }
            return (1...n).reduce(into: Data()) { $0.append(parts[$1]!) }
        }
    }
}

/// A hermetic TCP socket the test drives: `events` feeds the client, `sends` records writes.
final class MeshTCPHarness: Sendable {
    let stream = AsyncStream<TCPEvent>.makeStream()
    let sends = LockIsolated<[Data]>([])

    var connection: TCPConnection {
        TCPConnection(open: { [self] _, _ in stream.stream },
                      send: { [self] data in sends.withValue { $0.append(data) } },
                      close: { })
    }
}

/// An AppFeature store with Meshtastic on (when `radio` is non-nil and `enabled`), the radio
/// harness as the driver, and every other dependency hermetic (mirrors `meshStore` in
/// MeshtasticSettingsTests). Real child reducers: `LXMFServiceNode` → `LXMFNode` → `TransportEndpoint`.
@MainActor
func meshRadioStore(radio: UUID?, enabled: Bool = true, harness: MeshRadioHarness,
                    tcp: MeshTCPHarness = MeshTCPHarness(),
                    configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    let defaults = UserDefaults.inMemory
    var initial = withDependencies {
        $0.defaultAppStorage = defaults
        $0.defaultFileStorage = .inMemory
    } operation: {
        AppFeature.State(identity: Identity())
    }
    initial.$meshtasticEnabled.withLock { $0 = enabled }
    initial.$meshtasticRadioID.withLock { $0 = radio?.uuidString }
    configure?(&initial)
    let db = try! AppDatabase.makeInMemory()
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.defaultAppStorage = defaults
        $0.defaultDatabase = db
        $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1_700_000_000))
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.tcpConnection = tcp.connection
        $0.tcpListener = TCPListener(listen: { _ in AsyncStream { _ in } }, send: { _, _ in },
                                     close: { _ in }, stop: { })
        $0.bleDriver = BLEDriver(start: { _ in AsyncStream { _ in } }, readIdentity: { _ in },
                                 openChannel: { _ in }, send: { _, _ in }, closeChannel: { _ in }, stop: { })
        $0.pushPlatform = PushPlatform(requestAuthorization: { true }, registerForRemoteNotifications: {},
                                       unregisterForRemoteNotifications: {})
        $0.radioScanner = RadioScanner(scan: { AsyncStream { _ in } })
        $0.meshtasticDriver = harness.driver
        $0.meshtasticClock = ImmediateClock()
        $0.meshtasticDate = DateGenerator { Date(timeIntervalSince1970: 1_700_000_000) }
    }
    store.exhaustivity = .off
    return store
}

func isInterfaceConnected(_ action: AppFeature.Action, _ id: InterfaceID) -> Bool {
    if case let .node(.client(.endpoint(.transport(.interfaceConnected(connected, _))))) = action { return connected == id }
    return false
}

func isRadioOffline(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.meshtastic(.delegate(.radioOffline))))) = action { return true }
    return false
}

/// Brings the newest driver session online and waits for its interface to register.
@MainActor
func meshBringRadioOnline(_ store: TestStoreOf<AppFeature>, _ radio: MeshRadioHarness, id: InterfaceID,
                          starts: Int = 1, preset: Int? = 8) async {
    await radio.waitForStarts(starts)
    radio.yieldToLatest(.connected(myNodeNum: meshSlotOwnNode, modemPreset: preset))
    await store.receive({ isInterfaceConnected($0, id) }, timeout: .seconds(2))
}

func meshWaitUntil(timeout: Duration = .seconds(2), _ condition: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// True when no `.start` follows a `.start` without a `.stop` between them.
func meshNoOverlappingStarts(_ calls: [MeshRadioCall]) -> Bool {
    zip(calls, calls.dropFirst()).allSatisfy { pair in
        if case .start = pair.0, case .start = pair.1 { return false }
        return true
    }
}
```

- [ ] **Step 5: Write the failing slot tests**

Create `CORE/Tests/ReTiCaMsgrCoreTests/MeshtasticRadioSlotTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode
@testable import ReTiCaMsgrCore

@MainActor @Test func meshSlotConnectStartsTheChosenRadio() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await radio.waitForStarts(1)
    #expect(radio.calls.value == [.start(meshSlotRadioA)])
    #expect(store.state.node.client.endpoint.meshtastic?.interface.config.radio == meshSlotRadioA)
}

@MainActor @Test func meshSlotConnectWithMeshtasticOffBuildsNoSlot() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, enabled: false, harness: radio)
    await store.send(.connectTapped)
    await Task.megaYield()
    #expect(store.state.node.client.endpoint.meshtastic == nil)
    #expect(radio.calls.value.isEmpty)
}

@MainActor @Test func meshSlotConnectWithoutARadioBuildsNoSlotAndDialsNothing() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: nil, harness: radio)
    await store.send(.connectTapped)
    await Task.megaYield()
    #expect(store.state.node.client.endpoint.meshtastic == nil)
    #expect(store.state.connection == .disconnected, "nothing will dial: Connecting… would never resolve")
}

/// Amendment A10 ("will something dial") gains the radio.
@MainActor @Test func meshSlotConnectWithOnlyARadioShowsConnecting() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    #expect(store.state.connection == .connecting)
}

/// Contract 3: `.stop`, wait for `.radioOffline`, THEN nil — an online slot nil'd at once would
/// leave its interface registered in Transport.
@MainActor @Test func meshSlotDisablingStopsTheRadioBeforeDroppingTheSlot() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    radio.holdStops()
    await store.send(.binding(.set(\.meshtasticEnabled, false)))
    await store.send(.foregrounded)
    await Task.megaYield()
    #expect(store.state.node.client.endpoint.meshtastic != nil, "dropped before its driver stopped")
    radio.releaseStops()
    await store.receive({ isRadioOffline($0) }, timeout: .seconds(2))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.meshtastic == nil)
    #expect(store.state.node.client.endpoint.interfaces[meshSlotIDA] == nil)
    #expect(radio.calls.value == [.start(meshSlotRadioA), .stop])
}

@MainActor @Test func meshSlotChangingTheRadioStartsTheNewRadioOnlyAfterTheOldStopped() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    radio.holdStops()
    await store.send(.binding(.set(\.meshtasticRadioID, meshSlotRadioB.uuidString)))
    await store.send(.foregrounded)
    await Task.megaYield()
    #expect(radio.calls.value == [.start(meshSlotRadioA)], "a driver call during the old stop")
    radio.releaseStops()
    await store.receive({ isRadioOffline($0) }, timeout: .seconds(2))
    await radio.waitForStarts(2)
    #expect(radio.calls.value == [.start(meshSlotRadioA), .stop, .start(meshSlotRadioB)])
}

/// Review Focus 3: not online yet (connecting), still not idle — the swap waits for its stop.
@MainActor @Test func meshSlotChangingTheRadioWhileTheOldOneIsStillConnectingWaitsForItsStop() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await radio.waitForStarts(1)                     // never connected: status .connecting
    radio.holdStops()
    await store.send(.binding(.set(\.meshtasticRadioID, meshSlotRadioB.uuidString)))
    await store.send(.foregrounded)
    await Task.megaYield()
    #expect(radio.calls.value == [.start(meshSlotRadioA)])
    #expect(store.state.node.client.endpoint.meshtastic?.interface.config.radio == meshSlotRadioA)
    radio.releaseStops()
    await store.receive({ isRadioOffline($0) }, timeout: .seconds(2))
    await radio.waitForStarts(2)
    #expect(radio.calls.value == [.start(meshSlotRadioA), .stop, .start(meshSlotRadioB)])
}

/// After Disconnect the old slot is idle (stopped, its stop returned): replaced in the same action.
@MainActor @Test func meshSlotAnIdleOldSlotIsReplacedAtOnce() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    await store.send(.disconnectTapped)
    await store.receive({ isRadioOffline($0) }, timeout: .seconds(2))
    await store.send(.binding(.set(\.meshtasticRadioID, meshSlotRadioB.uuidString)))
    await store.send(.connectTapped)
    #expect(store.state.node.client.endpoint.meshtastic?.interface.config.radio == meshSlotRadioB)
    #expect(store.state.meshtasticSwap == nil)
    await radio.waitForStarts(2)
    #expect(radio.calls.value == [.start(meshSlotRadioA), .stop, .start(meshSlotRadioB)])
}

/// Review Focus 5. Connect's `.endpoint(.start)` reaches the old slot mid-stop; the interface
/// restarts it after its stop returns and reports offline first, so the app sees a NON-idle slot
/// at `.radioOffline` and stops it again.
@MainActor @Test func meshSlotConnectDuringASwapNeverStartsTwiceWithoutAStop() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    radio.holdStops()
    await store.send(.binding(.set(\.meshtasticRadioID, meshSlotRadioB.uuidString)))
    await store.send(.connectTapped)
    radio.releaseStops()
    let ended = await meshWaitUntil(timeout: .seconds(3)) {
        radio.calls.value.last == .start(meshSlotRadioB)
    }
    #expect(ended, "calls: \(radio.calls.value)")
    #expect(meshNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.meshtastic?.interface.config.radio == meshSlotRadioB)
    #expect(store.state.meshtasticSwap == nil)
}
```

- [ ] **Step 6: Run to see them fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live/ReTiCaMsgrCore --filter meshSlot > /tmp/ReTiCAMsgr-meshtastic-live/t9-red.log 2>&1`
Expected: build error — no `meshtasticSwap`.

- [ ] **Step 7: Implement the swap state machine**

Create `CORE/Sources/ReTiCaMsgrCore/AppFeature+MeshtasticRadio.swift`:

```swift
import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode

/// A radio slot replacement in flight (spec 2026-10-16 Contract 3, amended): the old slot was
/// sent `.stop` and is dropped only at its `.radioOffline`, which the interface reports once
/// `driver.stop()` has returned. Then `next` (nil: no radio) is installed.
public struct MeshtasticSlotSwap: Equatable, Sendable {
    public var next: MeshtasticDriverConfig?
    /// Start `next` once installed. Disconnect clears it, so a swap finishing after a Disconnect
    /// leaves the new radio stopped until the next Connect.
    public var startNext: Bool

    public init(next: MeshtasticDriverConfig?, startNext: Bool) {
        self.next = next
        self.startNext = startNext
    }
}

extension AppFeature.State {
    /// A Meshtastic radio will dial at Connect / foreground: the setting is on AND a radio is chosen.
    var meshtasticWillDial: Bool { meshtasticEnabled && meshtasticRadioUUID != nil }

    /// Amendment A10 ("only show Connecting… when something will actually dial"), now including
    /// the radio. The single definition behind onLaunch, Connect and the foreground re-dial.
    var somethingWillDial: Bool { !enabledNodes.isEmpty || listenEnabled || bleEnabled || meshtasticWillDial }
}

/// Makes the radio slot follow `meshtasticEnabled` + `meshtasticRadioUUID` (spec §7 lane E).
/// Called from `syncEndpointNodes`; the caller runs the returned effect before any dial.
func syncMeshtasticSlot(_ state: inout AppFeature.State) -> Effect<AppFeature.Action> {
    // Read the @Shared settings into locals first: mutating `state.node…` while reading a shared
    // value in the same statement is an exclusive-access violation.
    let willDial = state.meshtasticWillDial
    let radio = state.meshtasticRadioUUID
    let wanted: MeshtasticDriverConfig? = willDial ? radio.map { MeshtasticDriverConfig(radio: $0) } : nil
    if state.meshtasticSwap != nil {
        // A stop is already in flight: only retarget what replaces the old slot. Another `.stop`
        // or a `.start` now would race the in-flight `driver.stop()`.
        state.meshtasticSwap = MeshtasticSlotSwap(next: wanted, startNext: true)
        return .none
    }
    let current = state.node.client.endpoint.meshtastic
    guard current?.interface.config != wanted else { return .none }
    guard let current, !current.interface.isIdle else {
        // No slot, or one with nothing running (never started, or stopped and its `driver.stop()`
        // returned): replace it now.
        return installMeshtasticSlot(&state, wanted, start: true)
    }
    state.meshtasticSwap = MeshtasticSlotSwap(next: wanted, startNext: true)
    return .send(.node(.client(.endpoint(.meshtastic(.stop)))))
}

/// At `.radioOffline`: completes a pending swap once the old slot is idle. A slot that is NOT idle
/// was restarted after the stop (a `.start` reached it mid-stop and ran when the stop returned —
/// the interface reports offline before that restart): stop it again; the swap completes at the
/// next `.radioOffline`.
func finishMeshtasticSwap(_ state: inout AppFeature.State) -> Effect<AppFeature.Action> {
    guard let swap = state.meshtasticSwap else { return .none }
    if let slot = state.node.client.endpoint.meshtastic, !slot.interface.isIdle {
        return .send(.node(.client(.endpoint(.meshtastic(.stop)))))
    }
    state.meshtasticSwap = nil
    return installMeshtasticSlot(&state, swap.next, start: swap.startNext)
}

/// Replaces the radio slot. Callers guarantee the current slot is absent or idle.
func installMeshtasticSlot(_ state: inout AppFeature.State, _ config: MeshtasticDriverConfig?,
                           start: Bool) -> Effect<AppFeature.Action> {
    state.node.client.endpoint.meshtastic = config.map { MeshtasticEndpoint.State(config: $0) }
    guard config != nil, start else { return .none }
    return .send(.node(.client(.endpoint(.meshtastic(.start)))))
}

/// The radio's delegates (spec Contract 3), composed into `AppFeature.body` after
/// `MeshtasticSettingsReducer`.
struct MeshtasticRadioReducer: Reducer {
    var body: some ReducerOf<AppFeature> {
        Reduce { state, action in
            guard isRadioOfflineAction(action) else { return .none }
            return finishMeshtasticSwap(&state)
        }
    }

    private func isRadioOfflineAction(_ action: AppFeature.Action) -> Bool {
        if case .node(.client(.endpoint(.meshtastic(.delegate(.radioOffline))))) = action { return true }
        return false
    }
}
```

Create `CORE/Sources/ReTiCaMsgrCore/MeshtasticLiveWiring.swift`:

```swift
import ComposableArchitecture
import MeshtasticKit
import ReTiCAInterfaces
import ReTiCAMeshtasticLive

/// The app's live Meshtastic dependencies (spec 2026-10-16 §7 lane E, Contract 2).
public enum MeshtasticLiveWiring {
    /// The ONE app-owned session's driver, built on first use (so no CoreBluetooth manager exists
    /// until a radio slot starts) and kept for the process lifetime. Never dropped, so the
    /// "disconnect before dropping" rule holds by construction; every slot stop disconnects it.
    private static let driver: MeshtasticDriver = .live(session: MeshtasticLive.makeSession())

    /// `$0.meshtasticDriver = .live(session:)` over the app-owned session, forwarding lazily.
    public static func installDriver(into values: inout DependencyValues) {
        values.meshtasticDriver = MeshtasticDriver(
            start: { driver.start($0) },
            send: { await driver.send($0) },
            stop: { await driver.stop() })
    }
}
```

In `AppFeature.swift`:

(a) After `public var meshtasticStatus = MeshtasticStatus()` add:
```swift
        /// A radio slot replacement in flight (spec Contract 3): the old slot was sent `.stop` and is
        /// dropped at its `.radioOffline`. Session-only.
        public var meshtasticSwap: MeshtasticSlotSwap? = nil
```

(b) onLaunch: replace
```swift
                if !state.enabledNodes.isEmpty || state.listenEnabled || state.bleEnabled {
                    state.connection = .connecting
                }
                let sync = syncEndpointNodes(&state)
                return .concatenate(
```
with
```swift
                if state.somethingWillDial {
                    state.connection = .connecting
                }
                let sync = syncEndpointNodes(&state)
                return .concatenate(
```
and, in the same arm, replace `.concatenate(sync.removals, .send(.node(.client(.endpoint(.start))))),\n                    pushSyncEffects(state),` with `.concatenate(sync.removals, sync.meshtastic, .send(.node(.client(.endpoint(.start))))),\n                    pushSyncEffects(state),`.

(c) connectTapped: replace its body with
```swift
            case .connectTapped:
                // Amendment A10 (final-review M1): only show "Connecting…" when something will
                // actually dial.
                if state.somethingWillDial {
                    state.connection = .connecting
                }
                let sync = syncEndpointNodes(&state)
                return .merge(
                    .concatenate(sync.removals, sync.meshtastic, .send(.node(.client(.endpoint(.start))))),
                    heldPushSyncEffects(state)
                )
```

(d) `syncEndpointNodes`: change the signature to
```swift
private func syncEndpointNodes(_ state: inout AppFeature.State)
    -> (removals: Effect<AppFeature.Action>, added: [InterfaceID], meshtastic: Effect<AppFeature.Action>) {
```
insert before `let removals: Effect<AppFeature.Action> = .merge(stale.map {`:
```swift
    // The Meshtastic radio slot follows `meshtasticEnabled` + `meshtasticRadioUUID` (spec 2026-10-16
    // §7 lane E). Dropping a running slot is the amended Contract 3 protocol — `.stop`, wait for
    // `.radioOffline`, then replace — so it is an effect the caller runs, never a direct `= nil`.
    let meshtastic = syncMeshtasticSlot(&state)
```
and change `return (removals, added)` to `return (removals, added, meshtastic)`. Update the doc comment's last sentence to "Returns the removal effects (callers `.concatenate` them before any dial), the ids of the slots added, and the radio slot's effect (run with the removals)."

(e) `nodeChangeEffects(_ state:)`: `return .concatenate(sync.removals, connectEffects(sync.added), heldPushSyncEffects(state))` → `return .concatenate(sync.removals, sync.meshtastic, connectEffects(sync.added), heldPushSyncEffects(state))`.

(f) `redialDownNodes`: replace
```swift
    guard !down.isEmpty || noClientSlots else { return sync.removals }
    // Final-review M1: "nothing is up" alone is not enough — with no enabled node, no listener
    // and no BLE, nothing here is going to dial, and `.connecting` would never resolve.
    if state.connectedInterfaces.isEmpty,
       !state.enabledNodes.isEmpty || state.listenEnabled || state.bleEnabled {
        state.connection = .connecting
    }
```
with
```swift
    guard !down.isEmpty || noClientSlots else { return .concatenate(sync.removals, sync.meshtastic) }
    // Final-review M1: "nothing is up" alone is not enough — with no enabled node, no listener, no
    // BLE and no Meshtastic radio, nothing here is going to dial, and `.connecting` would never
    // resolve.
    if state.connectedInterfaces.isEmpty, state.somethingWillDial {
        state.connection = .connecting
    }
```
and its last line `return .concatenate(sync.removals, .merge(dials), heldPushSyncEffects(state))` → `return .concatenate(sync.removals, sync.meshtastic, .merge(dials), heldPushSyncEffects(state))`.

(g) body: after `MeshtasticSettingsReducer()` add `MeshtasticRadioReducer()`.

In `A/ReTiCaMsgr/AppRuntime.swift`, inside `withDependencies`, after the `$0.radioScanner = .liveValue` line add:
```swift
            // The live Meshtastic driver over the app's ONE MeshtasticSession (spec 2026-10-16 §7
            // lane E). Lazy: no CoreBluetooth work until a radio slot starts.
            MeshtasticLiveWiring.installDriver(into: &$0)
```

- [ ] **Step 8: Run to green (a)**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live/ReTiCaMsgrCore --filter meshSlot --filter meshPickerFlow --filter meshSettings --filter meshDiag > /tmp/ReTiCAMsgr-meshtastic-live/t9-green.log 2>&1`
Expected: all pass (lane D's suites unaffected).

- [ ] **Step 9: Mutation verification (b), then (c)**

Back up `AppFeature+MeshtasticRadio.swift` and `AppFeature.swift` to `/tmp/ReTiCAMsgr-meshtastic-live/*.orig`.
- **P1** (`syncMeshtasticSlot`): replace everything after `guard current?.interface.config != wanted else { return .none }` with `return installMeshtasticSlot(&state, wanted, start: true)` (always replace at once, running or not).
- **P2** (`finishMeshtasticSwap`): delete the `if let slot … { return .send(…stop…) }` block.
- **P3** (`somethingWillDial`): drop `|| meshtasticWillDial`.
- **P4** (`meshtasticWillDial`): `meshtasticEnabled && meshtasticRadioUUID != nil` → `meshtasticEnabled`.
- **P5** (`syncMeshtasticSlot`): `let wanted: MeshtasticDriverConfig? = willDial ? radio.map …` → `let wanted: MeshtasticDriverConfig? = radio.map { MeshtasticDriverConfig(radio: $0) }`.
- **P6** (`syncMeshtasticSlot`): replace `guard let current, !current.interface.isIdle else {` with `guard current == nil else {` keeps install-at-once only for an absent slot (an idle slot then goes through a swap).

Combined batch P1 + P3 + P5: `meshSlotConnectWithMeshtasticOffBuildsNoSlot` (P5), `meshSlotConnectWithOnlyARadioShowsConnecting` (P3), `meshSlotDisablingStopsTheRadioBeforeDroppingTheSlot`, `meshSlotChangingTheRadioStartsTheNewRadioOnlyAfterTheOldStopped`, `meshSlotChangingTheRadioWhileTheOldOneIsStillConnectingWaitsForItsStop`, `meshSlotConnectDuringASwapNeverStartsTwiceWithoutAStop` (P1) fail; `meshSlotConnectStartsTheChosenRadio`, `meshSlotConnectWithoutARadioBuildsNoSlotAndDialsNothing`, `meshSlotAnIdleOldSlotIsReplacedAtOnce` are covered per clause. Per-clause:
- P2 alone → `meshSlotConnectDuringASwapNeverStartsTwiceWithoutAStop` fails.
- P4 alone → `meshSlotConnectWithoutARadioBuildsNoSlotAndDialsNothing` fails (Connecting… with nothing to dial).
- P6 alone → `meshSlotAnIdleOldSlotIsReplacedAtOnce` fails (slot still A right after Connect; a swap is pending).
- Replace the body of `installMeshtasticSlot` with `return .none` alone → `meshSlotConnectStartsTheChosenRadio` fails.
Restore both files, rerun Step 8, all pass.

- [ ] **Step 10: App build and Xcode's resolved file**

Run: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination "generic/platform=iOS Simulator" build > /tmp/ReTiCAMsgr-meshtastic-live/t9-build.log 2>&1`
Expected: `** BUILD SUCCEEDED **`; the xcworkspace `Package.resolved` now lists swift-protobuf and MeshtasticKit.

- [ ] **Step 11: Commit**

Stage `ReTiCaMsgrCore/Package.swift ReTiCaMsgrCore/Package.resolved ReTiCaMsgr.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature+MeshtasticRadio.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/MeshtasticLiveWiring.swift ReTiCaMsgr/AppRuntime.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/MeshtasticRadioTestSupport.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/MeshtasticRadioSlotTests.swift`. Message `/tmp/ReTiCAMsgr-meshtastic-live/commit-task9.txt`:
```
feat: the Meshtastic radio slot follows the settings through the stop protocol

Spec 2026-10-16 section 7 lane E. syncEndpointNodes builds the radio slot when
Meshtastic is on and a radio is chosen. A running slot is replaced by the
amended Contract 3 protocol (stop, wait for radioOffline, then install), an
idle one at once, and a slot restarted mid-stop is stopped again, so a driver
never starts twice without a stop between. Will-something-dial counts the
radio. The app installs the live driver over one lazily built session.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

---

### Task 10: Re-dial the radio, guard Connect under the picker, Disconnect during a swap

**Files:**
- Modify: `CORE/Sources/ReTiCaMsgrCore/AppFeature.swift` — `redialDownNodes`, `connectTapped`, `disconnectTapped` (`:922-924`)
- Create: `CORE/Tests/ReTiCaMsgrCoreTests/MeshtasticRedialTests.swift`

**Interfaces:**
- Consumes: Task 9's harness, `meshtasticSwap`, `syncEndpointNodes`'s new tuple; lane D's `chooseRadioTapped`, `blePausedForRadioScan`, `BLEEndpoint.State`.
- Produces: `redialDownNodes` restarts a stopped/unavailable radio (never a slot being swapped; not deferred under the picker — the session never scans); `connectTapped` is ignored while `radioPicker != nil`; `disconnectTapped` sets `meshtasticSwap?.startNext = false`.

- [ ] **Step 1: Write the failing tests**

Create `CORE/Tests/ReTiCaMsgrCoreTests/MeshtasticRedialTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode
@testable import ReTiCaMsgrCore

@MainActor @Test func meshRedialForegroundRestartsAStoppedRadio() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    await store.send(.disconnectTapped)
    await store.receive({ isRadioOffline($0) }, timeout: .seconds(2))
    await store.send(.foregrounded)
    await radio.waitForStarts(2)
    #expect(radio.calls.value == [.start(meshSlotRadioA), .stop, .start(meshSlotRadioA)])
}

@MainActor @Test func meshRedialForegroundLeavesAnOnlineRadioAlone() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    await store.send(.foregrounded)
    await Task.megaYield()
    await store.skipReceivedActions(strict: false)
    #expect(radio.calls.value == [.start(meshSlotRadioA)])
    #expect(store.state.node.client.endpoint.interfaces[meshSlotIDA] != nil)
}

/// `redialDownNodes` returns early when every TCP node is up; the radio restart must not be skipped.
@MainActor @Test func meshRedialForegroundRestartsAnUnavailableRadioEvenWhenEveryNodeIsUp() async {
    let radio = MeshRadioHarness()
    let tcp = MeshTCPHarness()
    let node = NodeEntry(id: UUID(), name: "hub", host: "hub.example", port: 4242)
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio, tcp: tcp) { state in
        state.$nodes.withLock { $0 = [node] }
    }
    await store.send(.connectTapped)
    tcp.stream.continuation.yield(.connected)
    await store.receive({ isInterfaceConnected($0, node.interfaceID) }, timeout: .seconds(2))
    await radio.waitForStarts(1)
    radio.yieldToLatest(.unavailable(.poweredOff))
    await store.receive({ if case .node(.client(.endpoint(.meshtastic(.delegate(.adapterUnavailable))))) = $0 { return true }; return false },
                        timeout: .seconds(2))
    await store.send(.foregrounded)
    await radio.waitForStarts(2)
    #expect(radio.startCount == 2, "calls: \(radio.calls.value)")
}

/// Review Focus 5: a foreground during a swap must not `.start` the slot being replaced.
@MainActor @Test func meshRedialNeverRestartsTheSlotASwapIsReplacing() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    radio.holdStops()
    await store.send(.binding(.set(\.meshtasticRadioID, meshSlotRadioB.uuidString)))
    await store.send(.foregrounded)
    await store.send(.foregrounded)
    await Task.megaYield()
    #expect(radio.calls.value == [.start(meshSlotRadioA)])
    radio.releaseStops()
    await store.receive({ isRadioOffline($0) }, timeout: .seconds(2))
    await radio.waitForStarts(2)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(radio.calls.value == [.start(meshSlotRadioA), .stop, .start(meshSlotRadioB)])
}

/// Lane D's note: Connect while the picker is open would `.start` the BLE the picker paused,
/// taking FCB's one scan from the picker.
@MainActor @Test func meshRedialConnectWhileThePickerIsOpenLeavesPausedBLEStopped() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: nil, harness: radio) { state in
        state.$bleEnabled.withLock { $0 = true }
        var ble = BLEEndpoint.State(localIdentity: state.identity.hash)
        ble.ble.status = .online
        state.node.client.endpoint.ble = ble
    }
    await store.send(.chooseRadioTapped)
    await store.receive { if case .node(.client(.endpoint(.ble(.ble(.stop))))) = $0 { return true }; return false }
    await store.send(.connectTapped)
    await Task.megaYield()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .stopped)
    #expect(store.state.blePausedForRadioScan)
}

@MainActor @Test func meshRedialDisconnectDuringASwapLeavesTheNewRadioStopped() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    radio.holdStops()
    await store.send(.binding(.set(\.meshtasticRadioID, meshSlotRadioB.uuidString)))
    await store.send(.foregrounded)
    await store.send(.disconnectTapped)
    radio.releaseStops()
    await store.receive({ isRadioOffline($0) }, timeout: .seconds(2))
    try? await Task.sleep(for: .milliseconds(100))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.meshtastic?.interface.config.radio == meshSlotRadioB)
    #expect(store.state.node.client.endpoint.meshtastic?.interface.status == .stopped)
    #expect(radio.calls.value == [.start(meshSlotRadioA), .stop])
}
```

The BLE test SEEDS an online BLE slot: its claim is about the Connect guard, not about BLE reaching `.online` (lane D's tests and BLE's own suite cover that).

- [ ] **Step 2: Run to see them fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live/ReTiCaMsgrCore --filter meshRedial > /tmp/ReTiCAMsgr-meshtastic-live/t10-red.log 2>&1`
Expected: `meshRedialForegroundRestartsAStoppedRadio`, `meshRedialForegroundRestartsAnUnavailableRadioEvenWhenEveryNodeIsUp`, `meshRedialConnectWhileThePickerIsOpenLeavesPausedBLEStopped`, `meshRedialDisconnectDuringASwapLeavesTheNewRadioStopped` fail. (`meshRedialForegroundLeavesAnOnlineRadioAlone` and `meshRedialNeverRestartsTheSlotASwapIsReplacing` pass already: they guard the restart added below.)

- [ ] **Step 3: Implement**

`redialDownNodes`: directly after `let sync = syncEndpointNodes(&state)` add:
```swift
    // Restart a stopped or unavailable radio (spec 2026-10-16 §7 lane E). `.start` is ignored by a
    // connecting or online interface, and MeshtasticKit reconnects a dropped radio itself. Never
    // the slot a swap is replacing: a `.start` reaching it during its `driver.stop()` would restart
    // the old radio. Unlike BLE it is not deferred while the picker is open: a MeshtasticSession
    // connects by retrieval and never scans.
    let radioRestart: Effect<AppFeature.Action> =
        state.meshtasticSwap == nil && state.node.client.endpoint.meshtastic != nil
            ? .send(.node(.client(.endpoint(.meshtastic(.start))))) : .none
```
and change both returns: `return .concatenate(sync.removals, sync.meshtastic)` → `return .concatenate(sync.removals, sync.meshtastic, radioRestart)`; the final one → `return .concatenate(sync.removals, sync.meshtastic, .merge(dials + [radioRestart]), heldPushSyncEffects(state))`.

`connectTapped`: first line of the arm:
```swift
                // Never while the radio picker is open (spec 2026-10-16 §7 lane E): `.endpoint(.start)`
                // would restart a BLE interface the picker paused and take FCB's one scan from it.
                // The Connect button sits behind the sheet; the tap is dropped, not deferred.
                guard state.radioPicker == nil else { return .none }
```

`disconnectTapped`:
```swift
            case .disconnectTapped:
                state.connection = .disconnected
                // A radio swap that finishes after this leaves the new radio stopped.
                state.meshtasticSwap?.startNext = false
                return .send(.node(.client(.endpoint(.stop))))
```

- [ ] **Step 4: Run to green (a)**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live/ReTiCaMsgrCore --filter meshRedial --filter meshSlot --filter meshPickerFlow > /tmp/ReTiCAMsgr-meshtastic-live/t10-green.log 2>&1` → all pass.

- [ ] **Step 5: Mutation verification (b), then (c)**

Back up `AppFeature.swift`.
- **Q1**: `let radioRestart … = state.meshtasticSwap == nil && state.node.client.endpoint.meshtastic != nil ? … : .none` → `let radioRestart: Effect<AppFeature.Action> = .none`.
- **Q2**: in the early return, `return .concatenate(sync.removals, sync.meshtastic, radioRestart)` → `return .concatenate(sync.removals, sync.meshtastic)`.
- **Q3**: `state.meshtasticSwap == nil && ` → delete (restart even mid-swap).
- **Q4**: delete the `guard state.radioPicker == nil else { return .none }` line.
- **Q5**: delete `state.meshtasticSwap?.startNext = false`.
- **Q6**: `radioRestart` → `.merge(.send(.node(.client(.endpoint(.meshtastic(.stop))))), .send(.node(.client(.endpoint(.meshtastic(.start))))))` when non-nil (stop-and-start an online radio).

Combined batch Q1 + Q4 + Q5: `meshRedialForegroundRestartsAStoppedRadio`, `meshRedialForegroundRestartsAnUnavailableRadioEvenWhenEveryNodeIsUp`, `meshRedialConnectWhileThePickerIsOpenLeavesPausedBLEStopped`, `meshRedialDisconnectDuringASwapLeavesTheNewRadioStopped` fail. Per-clause: Q2 alone → `meshRedialForegroundRestartsAnUnavailableRadioEvenWhenEveryNodeIsUp` fails; Q3 alone → `meshRedialNeverRestartsTheSlotASwapIsReplacing` fails; Q6 alone → `meshRedialForegroundLeavesAnOnlineRadioAlone` fails. Restore, rerun, pass.

- [ ] **Step 6: Commit**

Stage `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/MeshtasticRedialTests.swift`. Message `/tmp/ReTiCAMsgr-meshtastic-live/commit-task10.txt`:
```
feat: foreground restarts a stopped radio and Connect waits for the picker

redialDownNodes restarts a stopped or unavailable radio slot, including when
every TCP node is up, but never the slot a swap is replacing. Connect is
dropped while the radio picker is open, so it cannot restart the BLE the
picker paused. A Disconnect during a swap leaves the new radio stopped.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

---

### Task 11: Delegates and counters → `MeshtasticStatus`; targeted interface-up announce

**Files:**
- Modify: `CORE/Sources/ReTiCaMsgrCore/AppFeature+MeshtasticRadio.swift` (`installMeshtasticSlot`, `MeshtasticRadioReducer`)
- Modify: `CORE/Sources/ReTiCaMsgrCore/MeshtasticStatus.swift` (append)
- Modify: `CORE/Sources/ReTiCaMsgrCore/AppFeature.swift` — state (after `meshtasticSwap`), the `interfaceConnected` arm (`:926-956`), the `meshtasticStatus` doc comment (`:288-290`)
- Create: `CORE/Tests/ReTiCaMsgrCoreTests/MeshtasticStatusTests.swift`

**Interfaces:**
- Consumes: Contract 3 delegates `.radioOnline(myNodeNum:modemPreset:)`, `.radioOffline(reason:)`, `.adapterUnavailable(_)`; `MeshtasticEndpoint.State.counters: MeshtasticCounters`; Contract 4 `LXMFNode.Action.announceDeliveryOnInterface(InterfaceID)` (`LXMFNode.swift:248`); `LXMFNode.State.deliveryDestinationHash`.
- Produces: `MeshtasticStatus.Counters.init(_ c: MeshtasticCounters)`, `static func +`, `static func +=`; `AppFeature.State.meshtasticRetiredCounters`; status kept current on every `.node(.client(.endpoint(.meshtastic(…))))` action.

- [ ] **Step 1: Write the failing tests**

Create `CORE/Tests/ReTiCaMsgrCoreTests/MeshtasticStatusTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
@testable import ReTiCaMsgrCore

@MainActor @Test func meshStatusRadioOnlineFillsTheStatus() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA, preset: 6)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.meshtasticStatus.online)
    #expect(store.state.meshtasticStatus.modemPreset == 6)
    #expect(store.state.meshtasticStatus.myNodeNum == meshSlotOwnNode)
}

@MainActor @Test func meshStatusRadioOfflineRecordsTheReason() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    radio.yieldToLatest(.disconnected(reason: "link lost"))
    await store.receive({ isRadioOffline($0) }, timeout: .seconds(2))
    #expect(!store.state.meshtasticStatus.online)
    #expect(store.state.meshtasticStatus.offlineReason == "link lost")
}

@MainActor @Test func meshStatusAdapterUnavailableIsShown() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await radio.waitForStarts(1)
    radio.yieldToLatest(.unavailable(.other("radio not found")))
    await store.receive({ if case .node(.client(.endpoint(.meshtastic(.delegate(.adapterUnavailable))))) = $0 { return true }; return false },
                        timeout: .seconds(2))
    #expect(store.state.meshtasticStatus.adapterUnavailable == .other("radio not found"))
}

@MainActor @Test func meshStatusRadioOnlineClearsAnAdapterFault() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await radio.waitForStarts(1)
    radio.yieldToLatest(.unavailable(.poweredOff))
    await store.receive({ if case .node(.client(.endpoint(.meshtastic(.delegate(.adapterUnavailable))))) = $0 { return true }; return false },
                        timeout: .seconds(2))
    radio.yieldToLatest(.connected(myNodeNum: meshSlotOwnNode, modemPreset: 8))
    await store.receive({ isInterfaceConnected($0, meshSlotIDA) }, timeout: .seconds(2))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.meshtasticStatus.adapterUnavailable == nil)
    #expect(store.state.meshtasticStatus.online)
}

@MainActor @Test func meshStatusCountersFollowTheLiveSlot() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    for frame in LandandairCodec().split(Data(repeating: 0x42, count: 300), index: 7) {
        radio.yieldToLatest(.fragment(from: meshSlotPeerNode, frame))
    }
    await store.receive({ if case .node(.client(.endpoint(.meshtastic(.interface(.delegate(.packetReceived)))))) = $0 { return true }; return false },
                        timeout: .seconds(2))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.meshtasticStatus.counters.completed == 1)
}

/// `MeshtasticStatus.Counters` are cumulative since launch; the endpoint's reset with each slot.
@MainActor @Test func meshStatusCountersSurviveARadioChange() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    for frame in LandandairCodec().split(Data(repeating: 0x42, count: 300), index: 7) {
        radio.yieldToLatest(.fragment(from: meshSlotPeerNode, frame))
    }
    await store.receive({ if case .node(.client(.endpoint(.meshtastic(.interface(.delegate(.packetReceived)))))) = $0 { return true }; return false },
                        timeout: .seconds(2))
    await store.send(.binding(.set(\.meshtasticRadioID, meshSlotRadioB.uuidString)))
    await store.send(.foregrounded)
    await store.receive({ isRadioOffline($0) }, timeout: .seconds(2))
    await radio.waitForStarts(2)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.meshtastic?.interface.config.radio == meshSlotRadioB)
    #expect(store.state.meshtasticStatus.counters.completed == 1)
}

/// Contract 4: only the FIRST interface-up registers (and announces everywhere); later ones
/// announce on THAT interface only.
@MainActor @Test func meshAnnounceAFurtherInterfaceUpAnnouncesOnThatInterface() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: nil, harness: radio)
    let first = InterfaceID("tcp:first:4242")
    let second = InterfaceID("tcp:second:4242")
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(first, .tcp))))))
    await store.receive { if case .node(.client(.registerDelivery)) = $0 { return true }; return false }
    await store.send(.node(.client(.endpoint(.transport(.interfaceConnected(second, .tcp))))))
    await store.receive { $0 == .node(.client(.announceDeliveryOnInterface(second))) }
    await store.skipReceivedActions(strict: false)
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live/ReTiCaMsgrCore --filter meshStatus --filter meshAnnounce > /tmp/ReTiCAMsgr-meshtastic-live/t11-red.log 2>&1`
Expected: every new test fails (status stays at defaults; the second interface gets `.registerDelivery`).

- [ ] **Step 3: Implement**

Append to `MeshtasticStatus.swift`:
```swift
extension MeshtasticStatus.Counters {
    /// The endpoint's public counters (spec Contract 3), field for field.
    public init(_ counters: MeshtasticCounters) {
        self.init(malformed: counters.malformed, evicted: counters.evicted, timedOut: counters.timedOut,
                  oversize: counters.oversize, completed: counters.completed,
                  queueFull: counters.queueFull, sendFailed: counters.sendFailed)
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(malformed: lhs.malformed + rhs.malformed, evicted: lhs.evicted + rhs.evicted,
             timedOut: lhs.timedOut + rhs.timedOut, oversize: lhs.oversize + rhs.oversize,
             completed: lhs.completed + rhs.completed, queueFull: lhs.queueFull + rhs.queueFull,
             sendFailed: lhs.sendFailed + rhs.sendFailed)
    }

    public static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }
}
```

In `AppFeature.swift` state, after `meshtasticSwap` add:
```swift
        /// Counters of radio slots already replaced, so Diagnostics stays cumulative since launch
        /// (`MeshtasticStatus.Counters`) across a radio change. Session-only.
        public var meshtasticRetiredCounters = MeshtasticStatus.Counters()
```
and replace the `meshtasticStatus` doc comment with `/// The radio's state for Diagnostics, from the Meshtastic endpoint's delegates and counters (MeshtasticRadioReducer). Session-only.`

In `AppFeature+MeshtasticRadio.swift`, replace `installMeshtasticSlot` and `MeshtasticRadioReducer` with:
```swift
/// Replaces the radio slot. Callers guarantee the current slot is absent or idle. The old slot's
/// counters are carried, and the per-radio status fields reset.
func installMeshtasticSlot(_ state: inout AppFeature.State, _ config: MeshtasticDriverConfig?,
                           start: Bool) -> Effect<AppFeature.Action> {
    if let old = state.node.client.endpoint.meshtastic {
        state.meshtasticRetiredCounters += MeshtasticStatus.Counters(old.counters)
    }
    state.node.client.endpoint.meshtastic = config.map { MeshtasticEndpoint.State(config: $0) }
    state.meshtasticStatus = MeshtasticStatus(counters: state.meshtasticRetiredCounters)
    guard config != nil, start else { return .none }
    return .send(.node(.client(.endpoint(.meshtastic(.start)))))
}

/// The radio's delegates (spec Contract 3) → `MeshtasticStatus`, swap completion at
/// `.radioOffline`, and the counters refreshed on EVERY radio action (they change with each
/// fragment, and no delegate reports them). Composed into `AppFeature.body` after
/// `MeshtasticSettingsReducer`.
struct MeshtasticRadioReducer: Reducer {
    var body: some ReducerOf<AppFeature> {
        Reduce { state, action in
            guard case let .node(.client(.endpoint(.meshtastic(radioAction)))) = action else { return .none }
            var effect: Effect<AppFeature.Action> = .none
            switch radioAction {
            case let .delegate(.radioOnline(myNodeNum, modemPreset)):
                state.meshtasticStatus.online = true
                state.meshtasticStatus.myNodeNum = myNodeNum
                state.meshtasticStatus.modemPreset = modemPreset
                state.meshtasticStatus.offlineReason = nil
                state.meshtasticStatus.adapterUnavailable = nil
            case let .delegate(.radioOffline(reason)):
                state.meshtasticStatus.online = false
                state.meshtasticStatus.offlineReason = reason
                effect = finishMeshtasticSwap(&state)
            case let .delegate(.adapterUnavailable(cause)):
                state.meshtasticStatus.online = false
                state.meshtasticStatus.adapterUnavailable = cause
            default:
                break
            }
            let live = state.node.client.endpoint.meshtastic.map { MeshtasticStatus.Counters($0.counters) }
                ?? MeshtasticStatus.Counters()
            state.meshtasticStatus.counters = state.meshtasticRetiredCounters + live
            return effect
        }
    }
}
```

In the `interfaceConnected` arm, before `var effects: [Effect<Action>] = [` add
```swift
                let alreadyRegistered = state.node.client.deliveryDestinationHash != nil
```
and replace `.send(.node(.client(.registerDelivery))),` (the second element) with
```swift
                    // Contract 4 (spec 2026-10-16): only the FIRST interface registers the delivery
                    // destination, which announces on whatever is up then. Every later interface-up
                    // re-announces on THAT interface only, so a radio coming up never re-broadcasts
                    // on every other interface and a TCP reconnect never puts an announce on the radio.
                    alreadyRegistered
                        ? .send(.node(.client(.announceDeliveryOnInterface(interfaceID))))
                        : .send(.node(.client(.registerDelivery))),
```

- [ ] **Step 4: Run to green (a)**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live/ReTiCaMsgrCore --filter meshStatus --filter meshAnnounce --filter meshSlot --filter meshRedial --filter meshDiag --filter interfaceConnected > /tmp/ReTiCAMsgr-meshtastic-live/t11-green.log 2>&1`
Expected: all pass, including the existing `interfaceConnected…` tests (each starts from a fresh store, so they still see `.registerDelivery`).

- [ ] **Step 5: Mutation verification (b), then (c)**

Back up the three production files.
- **R1**: in `.radioOnline`, delete `state.meshtasticStatus.online = true` and `state.meshtasticStatus.modemPreset = modemPreset`.
- **R2**: in `.radioOffline`, delete `state.meshtasticStatus.offlineReason = reason`.
- **R3**: in `.adapterUnavailable`, delete `state.meshtasticStatus.adapterUnavailable = cause`.
- **R4**: in `.radioOnline`, delete `state.meshtasticStatus.adapterUnavailable = nil`.
- **R5**: delete the two lines computing `live` and assigning `counters`.
- **R6**: in `installMeshtasticSlot`, delete the `if let old … { … += … }` block.
- **R7**: `alreadyRegistered ? … : …` → `.send(.node(.client(.registerDelivery))),`.

Combined batch R1 + R2 + R3 + R5 + R7: `meshStatusRadioOnlineFillsTheStatus`, `meshStatusRadioOfflineRecordsTheReason`, `meshStatusAdapterUnavailableIsShown`, `meshStatusCountersFollowTheLiveSlot`, `meshStatusCountersSurviveARadioChange`, `meshAnnounceAFurtherInterfaceUpAnnouncesOnThatInterface` fail. Per-clause: R4 alone → `meshStatusRadioOnlineClearsAnAdapterFault` fails; R6 alone → `meshStatusCountersSurviveARadioChange` fails (completed 0); R5 alone → `meshStatusCountersFollowTheLiveSlot` fails. Restore, rerun, pass.

- [ ] **Step 6: Commit**

Stage the four files. Message `/tmp/ReTiCAMsgr-meshtastic-live/commit-task11.txt`:
```
feat: Meshtastic status from the radio's delegates and targeted re-announce

MeshtasticStatus now shows online, preset, node, offline reason and adapter
faults from the radio's delegates, and its counters follow the live slot and
stay cumulative across a radio change. Contract 4: only the first
interface-up registers delivery, which announces everywhere, and every later
interface-up announces on that interface only.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

---

### Task 12: Whole-slice probe — app reducer + real `TransportEndpoint` + driver

**Files:**
- Create: `CORE/Tests/ReTiCaMsgrCoreTests/MeshtasticWholeSliceProbeTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 9–11 through production wiring (`AppFeature` → `LXMFServiceNode` → `LXMFNode` → `TransportEndpoint` → `MeshtasticEndpoint` → `MeshtasticInterface` → driver), `Packet(raw:)`, `LandandairCodec`.
- Produces: the seam probe (no production change expected; a failure here is a seam defect to fix in the owning task's code, with a new targeted test there).

- [ ] **Step 1: Write the probe**

Create `CORE/Tests/ReTiCaMsgrCoreTests/MeshtasticWholeSliceProbeTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCANode
import ReTiCATransport
@testable import ReTiCaMsgrCore

/// Contract 4 through production wiring: TCP comes up first (registration announce on TCP), then
/// the radio comes up — its announce must go out on the radio ONLY.
@MainActor @Test func meshSliceARadioComingUpAnnouncesOnTheRadioOnly() async {
    let radio = MeshRadioHarness()
    let tcp = MeshTCPHarness()
    let node = NodeEntry(id: UUID(), name: "hub", host: "hub.example", port: 4242)
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio, tcp: tcp) { state in
        state.$nodes.withLock { $0 = [node] }
    }
    await store.send(.connectTapped)
    tcp.stream.continuation.yield(.connected)
    await store.receive({ isInterfaceConnected($0, node.interfaceID) }, timeout: .seconds(2))
    await store.receive { if case .node(.client(.registerDelivery)) = $0 { return true }; return false }
    #expect(await meshWaitUntil { !tcp.sends.value.isEmpty }, "precondition: the registration announce went out on TCP")
    try? await Task.sleep(for: .milliseconds(100))
    let tcpWritesBeforeRadio = tcp.sends.value.count
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    await store.receive { $0 == .node(.client(.announceDeliveryOnInterface(meshSlotIDA))) }
    #expect(await meshWaitUntil { !radio.reassembled(session: 0).isEmpty })
    let announce = radio.reassembled(session: 0).compactMap { Packet(raw: $0) }.first { $0.packetType == .announce }
    #expect(announce?.destinationHash == store.state.node.client.deliveryDestinationHash)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(tcp.sends.value.count == tcpWritesBeforeRadio, "the radio coming up re-announced on TCP")
}

/// Review Focus 5 end to end: radio A online, the radio changed, Connect tapped while A's stop is
/// in flight. Ends on radio B — registered, announced on B — with no driver overlap, A
/// deregistered, and the counters cumulative.
@MainActor @Test func meshSliceARadioChangeDuringConnectEndsOnTheNewRadioWithNoDriverOverlap() async {
    let radio = MeshRadioHarness()
    let store = meshRadioStore(radio: meshSlotRadioA, harness: radio)
    await store.send(.connectTapped)
    await meshBringRadioOnline(store, radio, id: meshSlotIDA)
    for frame in LandandairCodec().split(Data(repeating: 0x42, count: 300), index: 7) {
        radio.yieldToLatest(.fragment(from: meshSlotPeerNode, frame))
    }
    await store.receive({ if case .node(.client(.endpoint(.meshtastic(.interface(.delegate(.packetReceived)))))) = $0 { return true }; return false },
                        timeout: .seconds(2))
    radio.holdStops()
    await store.send(.binding(.set(\.meshtasticRadioID, meshSlotRadioB.uuidString)))
    await store.send(.connectTapped)
    radio.releaseStops()
    #expect(await meshWaitUntil(timeout: .seconds(3)) { radio.calls.value.last == .start(meshSlotRadioB) },
            "calls: \(radio.calls.value)")
    #expect(meshNoOverlappingStarts(radio.calls.value), "calls: \(radio.calls.value)")
    let sessionB = radio.sessions.value.count - 1
    radio.yieldToLatest(.connected(myNodeNum: meshSlotOwnNode, modemPreset: 6))
    await store.receive({ isInterfaceConnected($0, meshSlotIDB) }, timeout: .seconds(2))
    await store.receive { $0 == .node(.client(.announceDeliveryOnInterface(meshSlotIDB))) }
    #expect(await meshWaitUntil { !radio.reassembled(session: sessionB).isEmpty }, "no announce on radio B")
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.interfaces[meshSlotIDA] == nil)
    #expect(store.state.node.client.endpoint.interfaces[meshSlotIDB] != nil)
    #expect(store.state.meshtasticStatus.online)
    #expect(store.state.meshtasticStatus.counters.completed == 1)
}
```

- [ ] **Step 2: Run (a)**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live/ReTiCaMsgrCore --filter meshSlice > /tmp/ReTiCAMsgr-meshtastic-live/t12.log 2>&1`
Expected: both pass. If either fails, it is a seam defect: diagnose (systematic-debugging), fix it in the owning task's production code, add a targeted test for it in that task's test file, and record it in the commit.

- [ ] **Step 3: Mutation verification (b), then (c)**

Back up `AppFeature.swift` and `AppFeature+MeshtasticRadio.swift`.
- **W1** (Task 11's announce): `alreadyRegistered ? … : …` → `.send(.node(.client(.registerDelivery))),` → `meshSliceARadioComingUpAnnouncesOnTheRadioOnly` fails (TCP written again).
- **W2** (Task 9's re-stop): delete `finishMeshtasticSwap`'s `if let slot … stop` block → `meshSliceARadioChangeDuringConnectEndsOnTheNewRadioWithNoDriverOverlap` fails.
- **W3** (Task 11's carry): delete `installMeshtasticSlot`'s counter carry → the swap probe fails (completed 0).
- **W4**: `.send(.node(.client(.announceDeliveryOnInterface(interfaceID))))` → `.none` → both probes fail (no targeted announce).
Combined W1 + W2 + W3: both fail. Per-clause: W1, W2, W3, W4 each alone → the named probe(s) fail. Restore, rerun, pass.

- [ ] **Step 4: Commit**

Stage `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/MeshtasticWholeSliceProbeTests.swift` (plus any seam fix and its test). Message `/tmp/ReTiCAMsgr-meshtastic-live/commit-task12.txt`:
```
test: whole-slice probe for the radio through production app wiring

AppFeature with the real LXMF node and TransportEndpoint over a driver: a
radio coming up after TCP announces on the radio only, and a radio change
during Connect ends on the new radio, registered and announced, with no
driver overlap, the old radio deregistered and counters cumulative.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

---

### Task 13: GATED ON LANE F — live radio scanner, and flip the ReTiCA scan probes

**Files:**
- ReTiCA (new worktree `/Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-scan-probes`): modify `Tests/ReTiCAInterfacesTests/MeshtasticCoexistenceTests.swift` (remove two `withKnownIssue` wrappers)
- App: modify `CORE/Sources/ReTiCaMsgrCore/RadioScanner.swift` (append), `CORE/Sources/ReTiCaMsgrCore/MeshtasticLiveWiring.swift`, `A/ReTiCaMsgr/AppRuntime.swift`; create `CORE/Tests/ReTiCaMsgrCoreTests/MeshtasticLiveScannerTests.swift`

**Interfaces:**
- Consumes: Task 5's `MeshtasticLive.scanRadios()`; MeshtasticKit's `DiscoveredRadio`; lane D's `RadioScanResult`, `RadioScanner`.
- Produces: `public static func RadioScanner.meshtastic(_ radios: @escaping @Sendable () -> AsyncStream<DiscoveredRadio>) -> RadioScanner`; `MeshtasticLiveWiring.installScanner(into:)`.

- [ ] **Step 1: STOP until FCB main contains lane F's scan-ownership fix**

Run: `git -C /Users/ell/development/ios/pods/FCB log --oneline -15`
Look for lane F's scan-ownership commit (a subject about stopScan / scan ownership / token-scoped stop). Then confirm it behaviourally on ReTiCA main:
Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter MeshtasticCoexistenceTests > /tmp/ReTiCAMsgr-meshtastic-live/t13-gate.log 2>&1`
Proceed ONLY if `aBLEStopAfterTheRadioScanStartedDoesNotEndIt` now reports "Known issue was not recorded" (the fix landed). If FCB has no such commit or the issue is still recorded, STOP: report and wait. Also check `git -C /Users/ell/development/ios/pods/ReTiCA log --oneline -10` for lane F's `FCBDriverAdapter` change; the flip below is cut from that main.

Lane F's semantics the flipped probes rely on (lane F plan, header and Task 5): FCB's `stopScan()` is a no-op and the adapter no longer calls it; a NEWER scan supersedes the current one and FINISHES the superseded stream; a stream that terminates before its own start never starts the radio; when the BLE adapter's scan stream finishes un-cancelled while Bluetooth is on, the adapter reports `.unavailable(.other("scan superseded by another scanner"))` and `BLEInterface` retries after a 5 s backoff doubling to 120 s; and `MeshtasticScanner` finishes for good when superseded. Consequences, already encoded in Task 6's probes: (1) the open-side probe asserts only that the radio scan survives BLE's stop — BLE's own stream being finished by the radio scan's supersession (with its `.unavailable`) is expected and not asserted; (2) the dismiss-side probe expects BLE to discover at once (the cancelled radio scan never started), and treats a visible `.unavailable(.other("scan superseded by another scanner"))` as a failure of that round, bounded at 3 s — it never waits out the 5–120 s backoff, and never hangs.

- [ ] **Step 2: Flip the ReTiCA probes**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA worktree add ../ReTiCA-worktrees/meshtastic-scan-probes -b meshtastic-scan-probes`
Run: `mkdir -p /tmp/meshtastic-scan-probes`
In `MeshtasticCoexistenceTests.swift`: in `aBLEStopAfterTheRadioScanStartedDoesNotEndIt`, replace the `await withKnownIssue("Lane F (spec §7 F.1a)…") {` line and its closing `}` so the two `#expect`s and `let secondFound` run unwrapped; in `aRadioScanCancelledAsBLERestartsLeavesBLEDiscovering`, likewise unwrap the `for round in 0..<10 { … }` loop. Update both doc comments: "Lane F fixed FCB's scan ownership (FCB `<commit>`); this pins it."
Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-scan-probes --filter MeshtasticCoexistenceTests > /tmp/meshtastic-scan-probes/flip.log 2>&1` → all pass, ten rounds included. Run it twice more (the dismiss probe is timing-dependent); all three runs green.
Mutation step: these probes' production code is lane F's in FCB, which this lane must not edit, and its red run is Task 6's recorded known issue. If lane F's change added a ReTiCA-side guard in `FCBDriverAdapter` (e.g. stopping only its own scan), mutate that guard back to the old global stop, confirm `aBLEStopAfterTheRadioScanStartedDoesNotEndIt` fails, restore, rerun green. Otherwise record "red run = Task 6's known issue; no in-repo mutation" in the commit.
Commit (stage the one test file; message `/tmp/meshtastic-scan-probes/commit.txt`):
```
test: scan interference probes now pin lane F's scan ownership fix

The coexistence probe's two scan cases ran as known issues until FCB's scan
ownership fix landed. Unwrapped, they pin it: BLE's stop no longer ends the
picker's radio scan, and a radio scan cancelled as BLE restarts leaves BLE
discovering, over ten timing rounds.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-scan-probes commit -F /tmp/meshtastic-scan-probes/commit.txt`, verify the trailer, then `git -C /Users/ell/development/ios/pods/ReTiCA merge --ff-only meshtastic-scan-probes`.

- [ ] **Step 3: Write the failing scanner tests (app)**

Create `CORE/Tests/ReTiCaMsgrCoreTests/MeshtasticLiveScannerTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
import MeshtasticKit
@testable import ReTiCaMsgrCore

private let liveScanID = UUID(uuidString: "5CA40000-0000-4000-8000-0000000000AA")!

@MainActor @Test func meshLiveScanMapsEachRadio() async {
    let upstream = AsyncStream<DiscoveredRadio>.makeStream()
    let scanner = RadioScanner.meshtastic { upstream.stream }
    let seen = LockIsolated<[RadioScanResult]>([])
    let consumer = Task { for await result in scanner.scan() { seen.withValue { $0.append(result) } } }
    upstream.continuation.yield(DiscoveredRadio(id: liveScanID, name: "Alpha", rssi: -40))
    #expect(await meshWaitUntil { seen.value.count == 1 })
    #expect(seen.value == [RadioScanResult(id: liveScanID, name: "Alpha", rssi: -40)])
    consumer.cancel()
}

@MainActor @Test func meshLiveScanFinishesWhenTheSourceFinishes() async {
    let upstream = AsyncStream<DiscoveredRadio>.makeStream()
    let scanner = RadioScanner.meshtastic { upstream.stream }
    let finished = LockIsolated(false)
    let consumer = Task {
        for await _ in scanner.scan() {}
        finished.setValue(true)
    }
    upstream.continuation.finish()
    #expect(await meshWaitUntil { finished.value })
    consumer.cancel()
}

@MainActor @Test func meshLiveScanCancellingEndsTheSource() async {
    let ended = LockIsolated(false)
    let scanner = RadioScanner.meshtastic {
        AsyncStream { continuation in continuation.onTermination = { _ in ended.setValue(true) } }
    }
    let consumer = Task { for await _ in scanner.scan() {} }
    try? await Task.sleep(for: .milliseconds(50))
    consumer.cancel()
    #expect(await meshWaitUntil { ended.value })
}
```

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live/ReTiCaMsgrCore --filter meshLiveScan > /tmp/ReTiCAMsgr-meshtastic-live/t13-red.log 2>&1` → build error (no `RadioScanner.meshtastic`).

- [ ] **Step 4: Implement**

Append to `RadioScanner.swift` (add `import MeshtasticKit` at the top):
```swift
extension RadioScanner {
    /// The live scanner (spec 2026-10-16 §7 lane E): each MeshtasticKit `DiscoveredRadio` from
    /// `radios()` as a `RadioScanResult`, field for field. Finishes when the source does — the
    /// live source (`MeshtasticLive.scanRadios()`) only when scanning stopped for good — and
    /// cancelling the consumer ends the source's scan.
    public static func meshtastic(_ radios: @escaping @Sendable () -> AsyncStream<DiscoveredRadio>) -> RadioScanner {
        RadioScanner(scan: {
            let upstream = radios()
            return AsyncStream { continuation in
                let task = Task {
                    for await radio in upstream {
                        continuation.yield(RadioScanResult(id: radio.id, name: radio.name, rssi: radio.rssi))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        })
    }
}
```
Update `liveValue`'s doc comment: "LOUD stub for hosts that install no scanner (previews, tests). The app installs `MeshtasticLiveWiring.installScanner(into:)`." (The stub itself and `radioPickerUninstalledLiveScannerEndsTheScan` stay.)

Append to `MeshtasticLiveWiring`:
```swift
    /// The live radio picker scan: MeshtasticKit's scanner over FCB's live central, finishing only
    /// when scanning stopped for good (`MeshtasticLive.scanRadios()`). Gated on lane F: FCB has
    /// one scan per process, and before lane F a BLE stop could end it.
    public static func installScanner(into values: inout DependencyValues) {
        values.radioScanner = .meshtastic { MeshtasticLive.scanRadios() }
    }
```
In `AppRuntime.swift` replace
```swift
            // Explicit for the same hosted-XCTest reason as `\.date`: its testValue is unimplemented.
            $0.radioScanner = .liveValue
```
with
```swift
            // Explicit for the same hosted-XCTest reason as `\.date` (its testValue is unimplemented):
            // the live radio scan over MeshtasticKit (spec 2026-10-16 §7 lane E).
            MeshtasticLiveWiring.installScanner(into: &$0)
```

- [ ] **Step 5: Run to green (a)**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live/ReTiCaMsgrCore --filter meshLiveScan --filter radioPicker --filter meshPickerFlow > /tmp/ReTiCAMsgr-meshtastic-live/t13-green.log 2>&1` → all pass.

- [ ] **Step 6: Mutation verification (b), then (c)**

Back up `RadioScanner.swift`.
- **T1**: `RadioScanResult(id: radio.id, name: radio.name, rssi: radio.rssi)` → `RadioScanResult(id: radio.id, name: nil, rssi: radio.rssi)`.
- **T2**: delete `continuation.finish()` in the task.
- **T3**: `continuation.onTermination = { _ in task.cancel() }` → delete.
Combined T1 + T2 + T3 → all three `meshLiveScan…` fail; each alone → its test fails. Restore, rerun, pass.

- [ ] **Step 7: Commit**

Stage `RadioScanner.swift MeshtasticLiveWiring.swift AppRuntime.swift MeshtasticLiveScannerTests.swift` (full repo-relative paths). Message `/tmp/ReTiCAMsgr-meshtastic-live/commit-task13.txt`:
```
feat: the radio picker scans for real Meshtastic radios

Lane F has made FCB's scan ownership safe, so the app now installs the live
RadioScanner over MeshtasticKit's scanner through MeshtasticLive.scanRadios,
which finishes only when scanning stopped for good. Each DiscoveredRadio maps
field for field to a RadioScanResult and cancelling the picker ends the scan.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

---

### Task 14: Full app suite, simulator smoke, rebase, fast-forward app `main`

**Files:** none changed (unless the smoke finds a defect).

- [ ] **Step 1: Full core suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live/ReTiCaMsgrCore > /tmp/ReTiCAMsgr-meshtastic-live/t14-full.log 2>&1` → passes; count = Task 9 baseline + this Part's tests.

- [ ] **Step 2: App build**

Run: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination "generic/platform=iOS Simulator" build > /tmp/ReTiCAMsgr-meshtastic-live/t14-build.log 2>&1` → `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Simulator smoke (xcodebuildmcp)**

Load the `xcodebuildmcp-cli` skill first and follow its CLI syntax. Only iOS-Simulator **26.4** devices are valid destinations.
Run: `xcrun simctl list devices available` → pick an iOS 26.4 device id.
Boot it and build-and-run the `ReTiCaMsgr` scheme from `/Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live/ReTiCaMsgr.xcodeproj` with the skill's `simulator build-and-run` command. Then with `ui-automation snapshot-ui` / `tap` (re-snapshot before every tap; refs expire):
- [ ] Settings shows the "Meshtastic" section with the toggle, the Radio row ("None") and "Choose radio…".
- [ ] Toggle on. Diagnostics shows the Meshtastic layer: `meshtastic on`, `radio (none chosen)`, reason "no radio chosen — choose one in Settings".
- [ ] Choose radio… opens "Choose Radio"; close it (Cancel). On the simulator CoreBluetooth is CoreBluetoothMock with no simulated radios, so an empty list is expected.
- [ ] Take a screenshot of Diagnostics for the record.
If the app crashes on any of these, STOP and report (do not add simulator-only code).

- [ ] **Step 4: Rebase, trailers, fast-forward**

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr log --oneline -5 main`; if `main` moved, `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live rebase main` and rerun Steps 1–2.
Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-live log main..meshtastic-live "--format=%h %s | %(trailers:key=Claude-Session,valueonly)"` → every line has the session URL.
Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr merge --ff-only meshtastic-live` → `Fast-forward`.

- [ ] **Step 5: Record lane E's status**

Update `/Users/ell/.claude/projects/-Users-ell-development-ios-pods-ReTiCA/memory/meshtastic-lanes.md` with a Lane E section: commits on both mains, test counts, whether Task 13 ran (lane F gate), the stop-semantics refinement, the `interfaceConnectedAt` decision, and what is still unverified (everything in Task 15).

---

# Part 3 — Hardware verification (the user performs it)

### Task 15: Two-radio hardware run (spec §1 criterion 3, §7 E.4)

**Files:**
- Modify: `RMAIN/docs/superpowers/plans/2026-10-16-meshtastic-hardware-checklist.md` (the user's results)
- Modify: `RMAIN/docs/superpowers/specs/2026-10-16-meshtastic-interface-design.md` §1 (criterion 3 status) and §9 (measured throughput)

**Interfaces:**
- Consumes: Task 7's checklist and probe; ReTiCAMsgr from app `main` (Task 14) on one or two iPhones; two radios; the Mac with conda env `rns`.
- Produces: filled Equipment and Results tables; spec §1/§9 updated with what was measured.

- [ ] **Step 1: Hand the checklist to the user**

Point the user at `/Users/ell/development/ios/pods/ReTiCA/docs/superpowers/plans/2026-10-16-meshtastic-hardware-checklist.md`. The plan cannot automate it. The user fills the Equipment table first (radio models, firmware versions, region, preset, hop limit), then runs sections (a)–(d) and fills the Results table.

- [ ] **Step 2: Record the results**

When the user returns the filled sheet, commit it on ReTiCA main (one commit, explicit path, message via `-F`, trailers at column zero, trailer check). In the spec: §1 criterion 3 gets a dated line per direction tested (pass/fail, preset, firmware); §9 "Real-world throughput" gets the measured latencies and whether link-based delivery (c) worked at which preset. If (c) failed at a preset where opportunistic worked, add it to §9 as a measured risk against Contract 4's fixed 15 s TCP-responder timeout — do not change the formula without a spec amendment. Commit the spec edit separately with the same procedure.

---

## Self-review (run against the spec, recorded)

1. **Spec coverage.** §7 E.0(a) → Task 1 (interface + endpoint-level tests incl. `start, stop, start` ordering and `.stop` on a stopped interface). E.0(b) → Task 2 with the reconnect rule decided from reference behaviour. E.1 → Tasks 3–4 (mapping, `send`, own-echo drop, port filter, `stop()` returns, loopback over the live FCB client against MeshtasticMock) and Task 5 (live session + scanner end). E.2 → Task 6 (per-peripheral disconnect filtering passing now; scan interference both directions as known issues) and Task 13 Step 2 (flip). E.3 → Task 9 (dependency, app-owned session, live driver, slot add/remove via the amended protocol, will-dial), Task 10 (re-dial keeping D's deferred-BLE semantics untouched, Connect guard), Task 11 (delegates + counters → `MeshtasticStatus`, targeted announce), Task 12 (whole-slice), Task 13 (live `RadioScanner`, gated on F), Task 14 (simulator smoke). E.4 → Tasks 7 and 15. Contract 2 `liveValue`/`testValue` are unchanged (lane B). §6 ownership respected: no FCB/MeshtasticKit edits.
2. **Placeholder scan.** No TBD/TODO. Two contingency notes are explicit instructions, not gaps: Task 6's "if CBM rejects a proximity change before a manager exists, move the line" and Task 6 C2's fallback wording for an unreachable mutation.
3. **Type consistency.** `isIdle` (Task 1) is read in Task 9 as `interface.isIdle`. `MeshtasticDriver.live(session:)` / `driverEvent(for:ownNode:)` / `reticulumTunnelPort` (Task 3) match Tasks 4, 6, 9. `MeshtasticLive.makeSession()` / `scanRadios()` / `scanRadios(central:)` (Task 5) match Tasks 9 and 13. `syncEndpointNodes` returns `(removals:, added:, meshtastic:)` at all four call sites. `MeshtasticSlotSwap(next:startNext:)` matches Tasks 9–12. `MeshtasticStatus.Counters.init(_:)`, `+`, `+=` (Task 11) are used in `installMeshtasticSlot` and the reducer.
4. **Cross-plan (lane F, revised 2026-10-16).** No new `@Suite(.serialized)` suite and no edit to `FCBDriverAdapterCBMTests.swift`: the three CBM suites (`MeshtasticLiveDriverTests`, `MeshtasticLiveInterfaceTests`, `MeshtasticCoexistenceTests`) are `extension FCBDriverAdapterCBMTests` members, as lane F's are, so either lane can merge second. Internal test-helper names checked against lane F's (Task 4 Step 1). Task 6's probes and Task 13's flip match lane F's post-fix semantics (no-op `stopScan`, a superseded stream finishes and the BLE adapter reports `.unavailable(.other("scan superseded by another scanner"))`, a stream ended before its start never starts the radio); the dismiss probe is bounded at 3 s and never waits out BLEInterface's 5–120 s backoff.
5. **Review Focus.** Each of the five lines has a named test in its owning task (listed in the section). Not covered and accepted: landandair's interface returns `False` from `should_ingress_limit` (Meshtastic_Interface.py:321-323), so the reference never ingress-limits a Meshtastic interface while ReTiCA does — reported, not changed (no spec mandate).
