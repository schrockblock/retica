# Meshtastic Lane D (ReTiCaMsgr UI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give ReTiCaMsgr everything a Meshtastic radio needs on the app side except the live wiring: persisted settings, a `RadioScanner` dependency, a radio-picker sheet that pauses BLE while it scans, a Settings section, and a Diagnostics layer. Lane E later plugs in the live scanner and driver.

**Architecture:** All of it lives in the ReTiCaMsgr app repo. `ReTiCaMsgrCore` gains `RadioScanner` (a TCA dependency client with a loud stub `liveValue`), a self-contained `RadioPickerFeature` reducer, three `@Shared(.appStorage)` keys next to `bleEnabled`, a presented `radioPicker` on `AppFeature.State` handled by a new `MeshtasticSettingsReducer` (the same split-out pattern as `ContactLinksReducer`/`BlockingReducer`), a plain `MeshtasticStatus` struct, and a `meshtasticLayer` in `DiagnosticsSnapshot`. The app target gains a Settings section and `RadioPickerView`. FCB runs one scan per process, so opening the picker sends the existing `.node(.client(.endpoint(.ble(.stop))))` when the BLE interface is running, and every way of closing it (swipe, Cancel, a pick) arrives as `.radioPicker(.dismiss)`, which sends `.ble(.start)` again.

**Tech Stack:** Swift 6 (tools 6.0), SwiftUI, TCA 1.26.1 (`@Reducer`, `@Presents`/`PresentationAction`, `@Dependency(\.dismiss)`, `TestStore`), swift-sharing 2.9.1 (`@Shared(.appStorage)`, `UserDefaults.inMemory`), Swift Testing.

**Spec:** `/Users/ell/development/ios/pods/ReTiCA/docs/superpowers/specs/2026-10-16-meshtastic-interface-design.md`. This plan implements **Lane D only** (§7 "Lane D", the lane D rows of §6, the D line of §8). The spec is the authority; read §2 (FCB single scan), §6 (file ownership) and §7 before Task 1.

## Global Constraints

- **Where:** all work happens ONLY in the app worktree `/Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic` on branch `meshtastic-ui`, cut from app `main` in Task 0. Below, `WT` means that path, `CORE` means `WT/ReTiCaMsgrCore`, `MAIN` means the main checkout `/Users/ell/development/ios/apps/ReTiCAMsgr`. The worktree MUST be a sibling of the app directory: `CORE/Package.swift` depends on `../../../pods/ReTiCA` and `../../../pods/ReTiCAPush`, which only resolve from `apps/<dir>/ReTiCaMsgrCore`. After Task 0, never build, test or edit in `MAIN` (Task 6 only fast-forwards it).
- **Lane D boundaries (spec §6):** touch ReTiCaMsgr files only. Never edit anything under `/Users/ell/development/ios/pods/`. Never reference a new ReTiCA symbol: no `TransportEndpoint.State.meshtastic`, no `MeshtasticEndpoint`, no `MeshtasticDriver`, no `InterfaceProfile.meshtastic`. Never import or depend on MeshtasticKit (it does not exist yet). Do NOT add a meshtastic slot to `syncEndpointNodes`, a restart to `redialDownNodes`, or a meshtastic term to the "will something dial" checks: that is lane E. The ONE allowed edit in `redialDownNodes` is Task 3's BLE-pause guard (an existing BLE line). Existing BLE symbols (`BLEEndpoint`, `BLEInterfaceStatus`, `BLEAdapterUnavailable`, `.ble(.start)`, `.ble(.stop)`) are allowed.
- **Shell:** one command per Bash call. No `|`, `&&`, `||`, `;`, `$(...)`, backticks, `xargs`, and no inline interpreters (`python -c`, `node -e`, `bash -c`, heredocs into an interpreter). Scripts go in files under `/tmp/ReTiCAMsgr-meshtastic/`. Redirecting one command's output to a file (`cmd > /tmp/ReTiCAMsgr-meshtastic/x.log 2>&1`) is allowed. Read logs with the Read tool or a single `grep`/`tail`.
- **Commits:** on `meshtastic-ui` only, one per task. Stage explicit paths (`git -C WT add <path> ...`, never `-A` or `.`). Never stage `ReTiCaMsgr.xcodeproj/xcuserdata/**`, `ReTiCaMsgrCore/.swiftpm/**`, `Package.resolved`. Write each message with the Write tool to `/tmp/ReTiCAMsgr-meshtastic/msg-task-N.txt`, then `git -C WT commit -F /tmp/ReTiCAMsgr-meshtastic/msg-task-N.txt`. Message = `feat:`/`fix:`/`test:`/`docs:` subject line, blank line, body, blank line, then exactly these two lines, starting at column 0 (no indentation, nothing after them):
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
  ```
  No semicolons anywhere in a commit message. After each commit, verify with `git -C WT log -1 --format='%(trailers:key=Claude-Session)'`: it must print the session URL. If it prints nothing, the trailers are malformed: fix with `git -C WT commit --amend -F <file>`.
- **Tests:** core tests run with `swift test --package-path CORE --filter <prefix> > /tmp/ReTiCAMsgr-meshtastic/<name>.log 2>&1`, the full core suite without `--filter`. Several `--filter` flags OR together. Swift Testing prints `Test run with N tests ... passed` or `... failed` at the end of the log. Filtering still compiles every target, so the whole package must compile at the end of every task. Never run `swift test` and `xcodebuild` at the same time. Known flake (from earlier app plans): `deliveryFailedMarksFailedAndReloads` can fail when run ALONE via `--filter`. It passes in a full run. Every new test name starts with its task's prefix: `radioPicker` (T1), `meshSettings` (T2), `meshPickerFlow` (T3), `meshDiag` (T4). No existing test name contains `radioPicker`, `meshSettings`, `meshPickerFlow`, `meshDiag`, `Meshtastic` or `RadioScanner` (checked 2026-10-16 with a grep over `ReTiCaMsgrCore`, `ReTiCaMsgr` and `ReTiCaMsgrTests`: none).
- **Mutation verification is mandatory for every task with new or changed tests**, in this order: (a) run the task's filter, every listed test GREEN. (b) Apply the task's whole mutation table to production code in ONE batch, run the filter ONCE, confirm EVERY listed test is RED. The tables are built so that no mutation masks another test's own mutation. If a test stays green, it is not testing what it claims: fix the test, revert, restart at (a). (c) Revert every mutation BY HAND with the Edit tool (never `git checkout -- <file>`), confirm `git -C WT diff` shows only the task's intended changes, run again, all GREEN. Only then commit. If anything goes unexpectedly at any step, stop and diagnose. Do not paper over it.
- **TCA TestStore facts these tests rely on:** under `exhaustivity = .off`, `store.state` reflects effect-delivered actions only after `receive` or `await store.skipReceivedActions(strict: false)`. Every `send` clears not-yet-received actions, so a `receive` for something an earlier `send` produced comes before the next `send`. A non-exhaustive `receive { predicate }` skips non-matching actions and times out (1 s default) when nothing matches. `.off` does NOT catch stray actions: a test whose claim is "nothing is reported" must be exhaustive (T1 `radioPickerCancelReportsNoRadio`). A compound test name ("A and B") is a coverage claim per clause: this plan splits such claims into one test per clause. A presented `@Presents` child keeps a never-ending presentation effect in flight, so never call `store.finish()` on an `AppFeature` store while the picker is presented. `.off` stores tolerate in-flight effects at teardown. `Effect.cancel(id:)` is EAGER: constructing it cancels. Never hold `.cancel(id:)` in a `let` or `var`. This plan never needs `.cancel`: the presentation reducer cancels the picker's effects on dismiss.
- **Test style** (match `AppFeatureTests.swift`): free `@MainActor @Test func` functions, `TestStore` with `exhaustivity = .off` unless a test says otherwise, `#expect` with literals. Tests that read or write the Meshtastic `@Shared(.appStorage)` keys build `AppFeature.State` inside `withDependencies { $0.defaultAppStorage = defaults }` with a fresh `UserDefaults.inMemory`, so no test shares a suite with another.
- **App target:** new SwiftUI files go in `WT/ReTiCaMsgr/` (synchronized root groups: no `project.pbxproj` edit). App build: `xcodebuild -project WT/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination "generic/platform=iOS Simulator" build`. The active Xcode only offers iOS-Simulator 26.4 run destinations. If a build dies with ENOSPC, delete `~/Library/Developer/Xcode/DerivedData` (regenerable) and retry once.
- **Tappable rows:** every custom tappable row's Button label ends with `.frame(maxWidth: .infinity, alignment: .leading)` then `.contentShape(Rectangle())`. Without this, a `.plain` button hit-tests only its glyphs.
- **Copy (verbatim):** Settings section header `Meshtastic`. Toggle `Connect through a Meshtastic radio`. Row label `Radio`, value `meshtasticRadioLabel` (`None` when no radio is chosen). Button `Choose radio…` (U+2026). Footer: `Sends and receives messages over LoRa through a Meshtastic radio paired with this device over Bluetooth. Set the radio to a Short preset (ShortTurbo or ShortFast): longer presets are too slow for most messages. The radio must not be connected to another app, such as the Meshtastic app, at the same time. Choosing a radio pauses Bluetooth connections to nearby devices until the list closes. Off by default. Takes effect on the next Connect.` Picker title `Choose Radio`, scanning footer `Scanning for Meshtastic radios… Make sure the radio is on and not connected to another app.`, ended-with-results footer `Scanning stopped.`, ended-empty footer `RadioPickerFeature.scanEndedEmptyMessage` = `Scanning stopped before any radio was found. Meshtastic support may not be installed in this build, or Bluetooth may be off or not allowed.` Unnamed radio `Unnamed radio`. Channel 0 and hop limit 1 are fixed in v1 (spec §7) and get NO setting.
- **Persisted keys (verbatim):** `meshtasticEnabled` (Bool, default false), `meshtasticRadioID` (String?, UUID string, default nil), `meshtasticRadioName` (String?, default nil). The third key is a lane D addition (see the plan's report): the Settings row needs a name after relaunch.

## Review Focus

Inputs the spec implies but its own text does not exercise, most likely to bite first. Each one is pinned by a named test in the owning task.

1. **The app is foregrounded (or woken by push) while the picker is open.** `redialDownNodes` sends `.ble(.start)` (`AppFeature.swift:2935-2937`), which would restart BLE scanning under the picker and take the one FCB scan. Expected: BLE stays paused until the picker closes. Test: T3 `meshPickerFlowForegroundWhileOpenKeepsBLEPaused`.
2. **The picker is opened while BLE is stopped (after Disconnect), terminally unavailable, or has no slot yet (toggled on but never connected).** Expected: closing the picker never starts BLE, and the app never sends a BLE action to a missing slot (TransportEndpoint's `ifLet` reports an issue for that, `AppFeatureTests.swift:257-258`). Tests: T3 `meshPickerFlowLeavesStoppedBLEStopped`, `meshPickerFlowWithoutBLESlotSendsNoBLEAction`.
3. **A radio's advertised name is unauthenticated text from the air:** missing, blank, or carrying newlines. Expected: a fallback label (`Unnamed radio` in the picker, the UUID in Settings), and no forged lines in the diagnostics export. Tests: T1 `radioPickerUnnamedRadioShowsAFallbackName`, T2 `meshSettingsRadioLabelFallsBackToTheIDForABlankName`, T4 `meshDiagAHostileRadioNameCannotForgeLines`.
4. **A stored `meshtasticRadioID` that is not a UUID** (hand-edited defaults, an older build). Expected: it reads as "no radio". Lane E will dial `meshtasticRadioUUID`, never the raw string. Test: T2 `meshSettingsNonUUIDRadioIDCountsAsNoRadio`.
5. **The sheet's `onAppear` fires twice, or the scan ends on its own** (the lane D stub, or later an adapter that goes away). Expected: only one scan runs at a time, and the picker shows a loud ended message instead of spinning forever. Tests: T1 `radioPickerSecondAppearReplacesTheFirstScan`, `radioPickerUninstalledLiveScannerEndsTheScan`.

---

### Task 0: Worktree and baseline

**Files:** none changed.

- [ ] **Step 1: Create the worktree from app main**

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr worktree add /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic -b meshtastic-ui main`
Expected: a new worktree at `WT` on `meshtastic-ui`. Git records the main checkout as `/Users/ell/development/ios/apps/ReTiCaMsgr` (lowercase `a`): the filesystem is case-insensitive, so both spellings name the same directory.

- [ ] **Step 2: Temp directory**

Run: `mkdir -p /tmp/ReTiCAMsgr-meshtastic`

- [ ] **Step 3: Baseline core suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic/ReTiCaMsgrCore > /tmp/ReTiCAMsgr-meshtastic/t0-core.log 2>&1`
Expected: the log ends with `Test run with N tests ... passed`. Write `N` to `/tmp/ReTiCAMsgr-meshtastic/baseline.txt` with the Write tool. If anything fails, stop: the baseline must be green before Task 1.

- [ ] **Step 4: Baseline app build**

Run: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination "generic/platform=iOS Simulator" build > /tmp/ReTiCAMsgr-meshtastic/t0-build.log 2>&1`
Expected: `** BUILD SUCCEEDED **` near the end of the log.

- [ ] **Step 5: Restore any files Xcode rewrote**

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic status --short`
Expected: empty. If `xcschememanagement.plist` files show as modified, restore them with `git -C WT checkout -- <path>`. This is the ONLY `git checkout --` allowed in this plan, only here and in Task 6. Nothing to commit.

---

### Task 1: `RadioScanner` dependency and `RadioPickerFeature` reducer

**Files:**
- Create: `CORE/Sources/ReTiCaMsgrCore/RadioScanner.swift`
- Create: `CORE/Sources/ReTiCaMsgrCore/RadioPickerFeature.swift`
- Create: `CORE/Tests/ReTiCaMsgrCoreTests/RadioPickerFeatureTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces (later tasks rely on these exact names):
  - `public struct RadioScanResult: Equatable, Sendable, Identifiable { public var id: UUID; public var name: String?; public var rssi: Int; public init(id: UUID, name: String?, rssi: Int); public var displayName: String }`
  - `public struct RadioScanner: Sendable { public var scan: @Sendable () -> AsyncStream<RadioScanResult>; public init(scan:) }`, `extension RadioScanner: DependencyKey` (`liveValue`, `testValue`, `previewValue`), `DependencyValues.radioScanner`
  - `@Reducer public struct RadioPickerFeature` with `State { radios: IdentifiedArrayOf<RadioScanResult>; scanEnded: Bool; selectedID: UUID?; init(selectedID: UUID? = nil) }`, `Action { onAppear, radioFound(RadioScanResult), scanFinished, radioTapped(UUID), cancelTapped, delegate(Delegate) }`, `Action.Delegate { selected(RadioScanResult) }`, `public static let scanEndedEmptyMessage: String`
  - Test helper (internal, in `RadioPickerFeatureTests.swift`): `func waitUntil(timeout: Duration = .seconds(2), _ condition: @Sendable () -> Bool) async -> Bool`. T3 uses it.

**Live value decision:** the spec's driver rule is "loud, never a silent no-op" (Contract 2). The `RadioScanner` contract is only `scan() -> AsyncStream<RadioScanResult>`, with no availability flag. So "the stream finished" is the loud signal: the stub `liveValue` finishes at once, the picker records `scanEnded`, and the sheet shows `scanEndedEmptyMessage` instead of a spinner that never resolves. `radioPickerUninstalledLiveScannerEndsTheScan` pins this. Lane E must keep the semantics: its mapped stream finishes only when scanning has stopped for good.

- [ ] **Step 1: Write the failing tests**

Create `CORE/Tests/ReTiCaMsgrCoreTests/RadioPickerFeatureTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCaMsgrCore

// MARK: - Fixtures

private let alpha = UUID(uuidString: "A1A1A1A1-0000-4000-8000-000000000001")!
private let bravo = UUID(uuidString: "B2B2B2B2-0000-4000-8000-000000000002")!
private let alphaRadio = RadioScanResult(id: alpha, name: "Alpha", rssi: -70)
private let bravoRadio = RadioScanResult(id: bravo, name: "Bravo", rssi: -65)

/// Polls `condition` until it holds or `timeout` passes. Real time, not a TestClock: stream
/// termination runs on the cancelled effect's task, outside the store. Used by T3 too.
func waitUntil(timeout: Duration = .seconds(2), _ condition: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A picker store with a scanner that never emits unless one is given, and a dismiss that only
/// records that it ran (the default `\.dismiss` reports an issue outside a presentation).
@MainActor
private func pickerStore(scanner: RadioScanner = RadioScanner(scan: { AsyncStream { _ in } }),
                         dismissed: LockIsolated<Bool> = LockIsolated(false)) -> TestStoreOf<RadioPickerFeature> {
    let store = TestStore(initialState: RadioPickerFeature.State()) {
        RadioPickerFeature()
    } withDependencies: {
        $0.radioScanner = scanner
        $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }
    store.exhaustivity = .off
    return store
}

// MARK: - Results

@MainActor @Test func radioPickerShowsRadiosTheScanReports() async {
    let (stream, continuation) = AsyncStream.makeStream(of: RadioScanResult.self)
    let store = pickerStore(scanner: RadioScanner(scan: { stream }))
    await store.send(.onAppear)
    continuation.yield(alphaRadio)
    await store.receive { if case .radioFound = $0 { return true }; return false }
    #expect(store.state.radios.map(\.id) == [alpha])
    continuation.finish()
}

/// A radio advertises over and over: one row, at its first-seen position, with the newest RSSI.
@MainActor @Test func radioPickerRepeatedRadioUpdatesItsRowInPlace() async {
    let store = pickerStore()
    await store.send(.radioFound(RadioScanResult(id: alpha, name: "Alpha", rssi: -80)))
    await store.send(.radioFound(RadioScanResult(id: bravo, name: "Bravo", rssi: -70)))
    await store.send(.radioFound(RadioScanResult(id: alpha, name: "Alpha", rssi: -60)))
    #expect(store.state.radios.map(\.id) == [alpha, bravo])
    #expect(store.state.radios[id: alpha]?.rssi == -60)
}

/// Not every advertisement carries the local name (a scan response may be missing): a repeat
/// without one must not blank the name already shown.
@MainActor @Test func radioPickerRepeatWithoutNameKeepsTheKnownName() async {
    let store = pickerStore()
    await store.send(.radioFound(RadioScanResult(id: alpha, name: "Alpha", rssi: -80)))
    await store.send(.radioFound(RadioScanResult(id: alpha, name: nil, rssi: -60)))
    #expect(store.state.radios[id: alpha]?.name == "Alpha")
}

/// Review Focus 3: the advertised name is unauthenticated free text.
@Test func radioPickerUnnamedRadioShowsAFallbackName() {
    #expect(RadioScanResult(id: alpha, name: nil, rssi: -50).displayName == "Unnamed radio")
    #expect(RadioScanResult(id: alpha, name: "  \n", rssi: -50).displayName == "Unnamed radio")
    #expect(RadioScanResult(id: alpha, name: " Base camp ", rssi: -50).displayName == "Base camp")
}

// MARK: - Scan lifecycle

@MainActor @Test func radioPickerScanEndingMarksTheScanEnded() async {
    let store = pickerStore(scanner: RadioScanner(scan: { AsyncStream { $0.finish() } }))
    await store.send(.onAppear)
    await store.receive { if case .scanFinished = $0 { return true }; return false }
    #expect(store.state.scanEnded)
}

/// Review Focus 5 and the loud-stub decision: until lane E installs the MeshtasticKit scanner,
/// the LIVE value must end the scan (so the sheet says why it found nothing) rather than spin.
/// Asserts only the action, so the `scanFinished` arm's own mutation cannot mask this one.
@MainActor @Test func radioPickerUninstalledLiveScannerEndsTheScan() async {
    let store = pickerStore(scanner: RadioScanner.liveValue)
    await store.send(.onAppear)
    await store.receive { if case .scanFinished = $0 { return true }; return false }
}

/// Review Focus 5: FCB has ONE scan per process and a new scan supersedes the old (spec §2). A
/// second appear (SwiftUI may fire onAppear again) must replace the first scan, not run beside it.
@MainActor @Test func radioPickerSecondAppearReplacesTheFirstScan() async {
    let started = LockIsolated(0)
    let ended = LockIsolated<Set<Int>>([])
    let scanner = RadioScanner(scan: {
        let n = started.withValue { count in
            count += 1
            return count
        }
        return AsyncStream { continuation in
            continuation.onTermination = { _ in ended.withValue { _ = $0.insert(n) } }
        }
    })
    let store = pickerStore(scanner: scanner)
    await store.send(.onAppear)
    #expect(await waitUntil { started.value == 1 })
    await store.send(.onAppear)
    #expect(await waitUntil { started.value == 2 })
    #expect(await waitUntil { ended.value.contains(1) })
    #expect(!ended.value.contains(2))
}

// MARK: - Pick and cancel

@MainActor @Test func radioPickerTapReportsTheTappedRadio() async {
    let store = pickerStore()
    await store.send(.radioFound(alphaRadio))
    await store.send(.radioFound(bravoRadio))
    await store.send(.radioTapped(bravo))
    await store.receive {
        if case let .delegate(.selected(radio)) = $0 { return radio.id == bravo }
        return false
    }
}

@MainActor @Test func radioPickerTapDismisses() async {
    let dismissed = LockIsolated(false)
    let store = pickerStore(dismissed: dismissed)
    await store.send(.radioFound(alphaRadio))
    await store.send(.radioTapped(alpha))
    await store.finish()
    #expect(dismissed.value)
}

@MainActor @Test func radioPickerCancelDismisses() async {
    let dismissed = LockIsolated(false)
    let store = pickerStore(dismissed: dismissed)
    await store.send(.radioFound(alphaRadio))
    await store.send(.cancelTapped)
    await store.finish()
    #expect(dismissed.value)
}

/// EXHAUSTIVE on purpose: the claim is that Cancel reports NOTHING, and `.off` cannot see a
/// stray action. Any `.delegate` received here fails the test at `finish()`.
@MainActor @Test func radioPickerCancelReportsNoRadio() async {
    let store = TestStore(initialState: RadioPickerFeature.State()) {
        RadioPickerFeature()
    } withDependencies: {
        $0.radioScanner = RadioScanner(scan: { AsyncStream { _ in } })
        $0.dismiss = DismissEffect { }
    }
    await store.send(.radioFound(alphaRadio)) { $0.radios = [alphaRadio] }
    await store.send(.cancelTapped)
    await store.finish()
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic/ReTiCaMsgrCore --filter radioPicker > /tmp/ReTiCAMsgr-meshtastic/t1-red.log 2>&1`
Expected: compile errors naming `RadioScanResult`, `RadioScanner`, `RadioPickerFeature`.

- [ ] **Step 3: Write `RadioScanner.swift`**

Create `CORE/Sources/ReTiCaMsgrCore/RadioScanner.swift`:

```swift
import Foundation
import ComposableArchitecture

/// One Meshtastic radio heard advertising during a scan (spec 2026-10-16 §7 lane D). Mirrors
/// MeshtasticKit's `DiscoveredRadio` (spec Contract 1) field for field, so lane E's live value is
/// a plain map. `id` is the CoreBluetooth peripheral UUID, the value `meshtasticRadioID` stores.
///
/// `name` is the radio's advertised Bluetooth name: UNAUTHENTICATED text from the air. Show it
/// through `displayName`, and never put it in a diagnostics reason (rows are escaped, reasons
/// are not).
public struct RadioScanResult: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String?
    public var rssi: Int

    public init(id: UUID, name: String?, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }

    /// The advertised name trimmed, or "Unnamed radio" when it is missing or blank.
    public var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unnamed radio" : trimmed
    }
}

/// Scanning for Meshtastic radios over Bluetooth.
///
/// `scan` reports each radio again on every advertisement, with a fresh `rssi`. The stream
/// FINISHES only when scanning has stopped for good (no scanner installed, adapter gone).
/// Cancelling the consuming task stops the scan. FCB runs one scan per process (spec §2), so the
/// app pauses its BLE interface while a scan runs (see `MeshtasticSettingsReducer`).
public struct RadioScanner: Sendable {
    public var scan: @Sendable () -> AsyncStream<RadioScanResult>

    public init(scan: @escaping @Sendable () -> AsyncStream<RadioScanResult>) {
        self.scan = scan
    }
}

extension RadioScanner: DependencyKey {
    /// LOUD stub until lane E installs the MeshtasticKit-backed scanner (a map over
    /// `MeshtasticScanner.scan(central:)`, installed in `AppRuntime` with
    /// `$0.radioScanner = …` or by replacing this value). It is not a silent no-op: the stream
    /// finishes at once, so the picker reaches `scanEnded` and shows
    /// `RadioPickerFeature.scanEndedEmptyMessage` instead of a spinner that never resolves.
    /// `radioPickerUninstalledLiveScannerEndsTheScan` pins this.
    public static let liveValue = RadioScanner(scan: { AsyncStream<RadioScanResult> { $0.finish() } })

    public static let testValue = RadioScanner(
        scan: unimplemented("RadioScanner.scan", placeholder: AsyncStream<RadioScanResult> { $0.finish() }))

    /// Three fake radios, then an open stream (a scan in progress), for SwiftUI previews.
    public static let previewValue = RadioScanner(scan: {
        AsyncStream<RadioScanResult> { continuation in
            continuation.yield(RadioScanResult(
                id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000001")!, name: "Meshtastic_1a2b", rssi: -52))
            continuation.yield(RadioScanResult(
                id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000002")!, name: "Base camp T-Beam", rssi: -71))
            continuation.yield(RadioScanResult(
                id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000003")!, name: nil, rssi: -88))
        }
    })
}

extension DependencyValues {
    public var radioScanner: RadioScanner {
        get { self[RadioScanner.self] }
        set { self[RadioScanner.self] = newValue }
    }
}
```

- [ ] **Step 4: Write `RadioPickerFeature.swift`**

Create `CORE/Sources/ReTiCaMsgrCore/RadioPickerFeature.swift`:

```swift
import Foundation
import ComposableArchitecture

/// The "Choose radio" sheet (spec 2026-10-16 §7 lane D). It scans while it is on screen, lists
/// what it hears (one row per radio, first-seen order, newest RSSI), and either reports a pick
/// and dismisses, or dismisses on Cancel. Presented from `AppFeature.State.radioPicker`. The
/// presentation reducer cancels the scan on dismiss, and `AppFeature` pauses and resumes BLE
/// around it (`MeshtasticSettingsReducer`).
@Reducer
public struct RadioPickerFeature {
    /// Shown when the scan ended without finding anything. With the lane D stub scanner this is
    /// the "not installed" case, and later it can mean Bluetooth is off or not allowed.
    public static let scanEndedEmptyMessage =
        "Scanning stopped before any radio was found. Meshtastic support may not be installed in "
        + "this build, or Bluetooth may be off or not allowed."

    @ObservableState
    public struct State: Equatable {
        public var radios: IdentifiedArrayOf<RadioScanResult> = []
        /// The scanner's stream finished. A live scanner only finishes when scanning stopped for
        /// good, so the sheet stops showing a spinner and says why.
        public var scanEnded = false
        /// The radio Settings currently holds (a checkmark), then the one just tapped.
        public var selectedID: UUID?

        public init(selectedID: UUID? = nil) {
            self.selectedID = selectedID
        }
    }

    public enum Action: Equatable {
        /// The sheet appeared: start (or restart) the scan.
        case onAppear
        case radioFound(RadioScanResult)
        case scanFinished
        case radioTapped(UUID)
        case cancelTapped
        case delegate(Delegate)

        public enum Delegate: Equatable {
            /// The user picked this radio. The parent stores it. The picker then dismisses itself.
            case selected(RadioScanResult)
        }
    }

    private enum CancelID: Hashable { case scan }

    @Dependency(\.radioScanner) var radioScanner
    @Dependency(\.dismiss) var dismiss

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                state.scanEnded = false
                // `cancelInFlight`: SwiftUI can fire onAppear twice, and FCB's one process-wide scan
                // means a second concurrent scan would supersede the first (Review Focus 5).
                return .run { [radioScanner] send in
                    for await radio in radioScanner.scan() {
                        await send(.radioFound(radio))
                    }
                    // A cancelled scan (dismiss, a second appear) ended on purpose: not "stopped".
                    guard !Task.isCancelled else { return }
                    await send(.scanFinished)
                }
                .cancellable(id: CancelID.scan, cancelInFlight: true)

            case let .radioFound(radio):
                // A repeat without a name keeps the one already heard. The id subscript replaces
                // the row in place (first-seen order) or appends a new one.
                var merged = radio
                if merged.name == nil { merged.name = state.radios[id: radio.id]?.name }
                state.radios[id: radio.id] = merged
                return .none

            case .scanFinished:
                state.scanEnded = true
                return .none

            case let .radioTapped(id):
                guard let radio = state.radios[id: id] else { return .none }
                state.selectedID = id
                return .concatenate(
                    .send(.delegate(.selected(radio))),
                    .run { [dismiss] _ in await dismiss() }
                )

            case .cancelTapped:
                return .run { [dismiss] _ in await dismiss() }

            case .delegate:
                return .none
            }
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic/ReTiCaMsgrCore --filter radioPicker > /tmp/ReTiCAMsgr-meshtastic/t1-green.log 2>&1`
Expected: 11 tests passed.

- [ ] **Step 6: Mutation batch (one run)**

Apply ALL of these to production code, then run the Step 5 command once, logging to `/tmp/ReTiCAMsgr-meshtastic/t1-mut.log`. Expected: all 11 tests FAIL.

| # | File | Mutation | Test that must fail |
|---|---|---|---|
| J | RadioPickerFeature.swift | `.onAppear` loop body becomes empty: `for await _ in radioScanner.scan() {}` | `radioPickerShowsRadiosTheScanReports` |
| A | RadioPickerFeature.swift | `.radioFound`: replace `state.radios[id: radio.id] = merged` with `state.radios.remove(id: radio.id)` then `state.radios.append(merged)` on the next line | `radioPickerRepeatedRadioUpdatesItsRowInPlace` |
| B | RadioPickerFeature.swift | delete the line `if merged.name == nil { merged.name = state.radios[id: radio.id]?.name }` | `radioPickerRepeatWithoutNameKeepsTheKnownName` |
| C | RadioScanner.swift | `displayName` body becomes `name ?? "Unnamed radio"` | `radioPickerUnnamedRadioShowsAFallbackName` |
| D | RadioPickerFeature.swift | `.scanFinished` arm: delete `state.scanEnded = true` | `radioPickerScanEndingMarksTheScanEnded` |
| E | RadioScanner.swift | `liveValue` becomes `RadioScanner(scan: { AsyncStream<RadioScanResult> { _ in } })` | `radioPickerUninstalledLiveScannerEndsTheScan` |
| I | RadioPickerFeature.swift | `.cancellable(id: CancelID.scan, cancelInFlight: true)` becomes `.cancellable(id: CancelID.scan)` | `radioPickerSecondAppearReplacesTheFirstScan` |
| F | RadioPickerFeature.swift | `.radioTapped`: delete the `.send(.delegate(.selected(radio))),` line from the `.concatenate` | `radioPickerTapReportsTheTappedRadio` |
| G | RadioPickerFeature.swift | `.radioTapped`: delete the `.run { [dismiss] _ in await dismiss() }` line from the `.concatenate` (and the trailing comma left behind) | `radioPickerTapDismisses` |
| H | RadioPickerFeature.swift | `.cancelTapped` returns `state.radios.first.map { .send(.delegate(.selected($0))) } ?? .none` (Cancel acting as Done, and no dismiss) | `radioPickerCancelDismisses`, `radioPickerCancelReportsNoRadio` |

The mutated `.radioTapped` after F and G is `.concatenate()` (empty), which compiles. `radioPickerSecondAppearReplacesTheFirstScan` and `radioPickerTapDismisses` fail by assertion after a short wait, not by hanging: `waitUntil` gives up after 2 s.

- [ ] **Step 7: Revert by hand and re-run**

Revert every mutation with the Edit tool. Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic diff --stat`. Expected: only the three new files (as untracked, so the diff is empty, and `git -C WT status --short` lists the three paths). Run the Step 5 command again, logging to `t1-green2.log`: 11 passed.

- [ ] **Step 8: Commit**

```bash
git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/RadioScanner.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/RadioPickerFeature.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/RadioPickerFeatureTests.swift
```

Message file `/tmp/ReTiCAMsgr-meshtastic/msg-task-1.txt`:

```
feat: RadioScanner dependency and the radio picker reducer

Meshtastic lane D (spec 2026-10-16 section 7). RadioScanResult mirrors
MeshtasticKit's DiscoveredRadio so lane E's live value is a map. The live
value is a loud stub: its stream finishes at once so the picker shows why it
found nothing. The picker dedupes by id in first-seen order, keeps the newest
RSSI and a known name, restarts rather than doubles the scan on a second
appear, reports a pick through a delegate and dismisses.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic commit -F /tmp/ReTiCAMsgr-meshtastic/msg-task-1.txt`
Then: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic log -1 --format='%(trailers:key=Claude-Session)'`. Expected: the session URL.

---

### Task 2: Persisted Meshtastic settings

**Files:**
- Modify: `CORE/Sources/ReTiCaMsgrCore/AppFeature.swift` (three `@Shared` properties directly after `bleEnabled`, currently line 267)
- Create: `CORE/Sources/ReTiCaMsgrCore/AppFeature+Meshtastic.swift`
- Create: `CORE/Tests/ReTiCaMsgrCoreTests/MeshtasticSettingsTests.swift`

**Interfaces:**
- Consumes: `RadioScanner`, `RadioScanResult` (Task 1).
- Produces:
  - `AppFeature.State.meshtasticEnabled: Bool` (`@Shared(.appStorage("meshtasticEnabled"))`, default false)
  - `AppFeature.State.meshtasticRadioID: String?` (`@Shared(.appStorage("meshtasticRadioID"))`, default nil)
  - `AppFeature.State.meshtasticRadioName: String?` (`@Shared(.appStorage("meshtasticRadioName"))`, default nil)
  - `extension AppFeature.State { public var meshtasticRadioUUID: UUID? ; public var meshtasticRadioLabel: String }`
  - Test helpers in `MeshtasticSettingsTests.swift` (private, T3 appends to the same file): `meshStore(defaults:scanner:configure:) -> TestStoreOf<AppFeature>`, `radioA: RadioScanResult`

Settings follow `bleEnabled`/`listenEnabled` exactly: `@Shared(.appStorage(...))` on `AppFeature.State`, written by the view's `$store.<key>` binding through `BindingReducer` (`SettingsView.swift:117, 130`), read at connect time by lane E. There is no existing persistence test for those keys (no `@Shared(.appStorage` in the test folder), so these tests read the key back from a dedicated `UserDefaults` suite. That proves the key string, not just the in-memory value.

- [ ] **Step 1: Write the failing tests**

Create `CORE/Tests/ReTiCaMsgrCoreTests/MeshtasticSettingsTests.swift`:

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

// MARK: - Helpers

private let radioA = RadioScanResult(id: UUID(uuidString: "A1A1A1A1-0000-4000-8000-0000000000A1")!,
                                     name: "Alpha", rssi: -61)

/// An AppFeature store whose `@Shared(.appStorage)` keys live in `defaults` and whose node list is
/// in an in-memory file store, so no test shares either with another. The State is built INSIDE
/// `withDependencies`: an `@Shared` key binds its store when the property is initialised.
/// Hermetic TCP, listener, BLE and push dependencies mirror `AppFeatureTests.makeStore`.
@MainActor
private func meshStore(defaults: UserDefaults = .inMemory,
                       scanner: RadioScanner = RadioScanner(scan: { AsyncStream { _ in } }),
                       configure: ((inout AppFeature.State) -> Void)? = nil) -> TestStoreOf<AppFeature> {
    var initial = withDependencies {
        $0.defaultAppStorage = defaults
        $0.defaultFileStorage = .inMemory
    } operation: {
        AppFeature.State(identity: Identity())
    }
    configure?(&initial)
    let db = try! AppDatabase.makeInMemory()
    let store = TestStore(initialState: initial) {
        AppFeature()
    } withDependencies: {
        $0.defaultAppStorage = defaults
        $0.defaultDatabase = db
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.tcpListener = TCPListener(listen: { _ in AsyncStream { _ in } }, send: { _, _ in },
                                     close: { _ in }, stop: { })
        $0.bleDriver = BLEDriver(start: { _ in AsyncStream { _ in } }, readIdentity: { _ in },
                                 openChannel: { _ in }, send: { _, _ in }, closeChannel: { _ in }, stop: { })
        $0.pushPlatform = PushPlatform(requestAuthorization: { true }, registerForRemoteNotifications: {},
                                       unregisterForRemoteNotifications: {})
        $0.radioScanner = scanner
    }
    store.exhaustivity = .off
    return store
}

// MARK: - Settings keys (T2)

@MainActor @Test func meshSettingsDefaultsAreOffWithNoRadio() async {
    let store = meshStore()
    #expect(store.state.meshtasticEnabled == false)
    #expect(store.state.meshtasticRadioID == nil)
    #expect(store.state.meshtasticRadioLabel == "None")
}

/// The toggle goes through the same path as Settings' `$store.meshtasticEnabled` binding, and the
/// value must land under the spec's key.
@MainActor @Test func meshSettingsToggleWritesTheMeshtasticEnabledKey() async {
    let defaults = UserDefaults.inMemory
    let store = meshStore(defaults: defaults)
    await store.send(.binding(.set(\.meshtasticEnabled, true)))
    #expect(defaults.bool(forKey: "meshtasticEnabled") == true)
}

/// A radio chosen in an earlier launch is read back from the spec's key.
@MainActor @Test func meshSettingsReadsAPersistedRadioID() async {
    let defaults = UserDefaults.inMemory
    defaults.set(radioA.id.uuidString, forKey: "meshtasticRadioID")
    let store = meshStore(defaults: defaults)
    #expect(store.state.meshtasticRadioUUID == radioA.id)
}

@MainActor @Test func meshSettingsRadioLabelShowsTheName() async {
    let store = meshStore { state in
        state.$meshtasticRadioID.withLock { $0 = radioA.id.uuidString }
        state.$meshtasticRadioName.withLock { $0 = "Base camp" }
    }
    #expect(store.state.meshtasticRadioLabel == "Base camp")
}

/// Review Focus 3: a blank advertised name is no name.
@MainActor @Test func meshSettingsRadioLabelFallsBackToTheIDForABlankName() async {
    let store = meshStore { state in
        state.$meshtasticRadioID.withLock { $0 = radioA.id.uuidString }
        state.$meshtasticRadioName.withLock { $0 = "  " }
    }
    #expect(store.state.meshtasticRadioLabel == radioA.id.uuidString)
}

/// Review Focus 4: a stored ID that is not a UUID reads as no radio, name or not.
@MainActor @Test func meshSettingsNonUUIDRadioIDCountsAsNoRadio() async {
    let store = meshStore { state in
        state.$meshtasticRadioID.withLock { $0 = "not-a-uuid" }
        state.$meshtasticRadioName.withLock { $0 = "Ghost" }
    }
    #expect(store.state.meshtasticRadioUUID == nil)
    #expect(store.state.meshtasticRadioLabel == "None")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic/ReTiCaMsgrCore --filter meshSettings > /tmp/ReTiCAMsgr-meshtastic/t2-red.log 2>&1`
Expected: compile errors naming `meshtasticEnabled`, `meshtasticRadioID`, `meshtasticRadioName`, `meshtasticRadioUUID`, `meshtasticRadioLabel`.

- [ ] **Step 3: Add the three keys to `AppFeature.State`**

In `CORE/Sources/ReTiCaMsgrCore/AppFeature.swift`, directly after the line `@Shared(.appStorage("bleEnabled")) public var bleEnabled: Bool = false` (currently line 267), insert:

```swift
        /// Opt-in: also reach Reticulum through a Meshtastic radio paired over Bluetooth (spec
        /// 2026-10-16 §7). OFF by default. Like `bleEnabled`, it is read at connect time, and the
        /// endpoint slot itself is wired by lane E (`syncEndpointNodes`): this build stores the
        /// choice and shows it in Settings and Diagnostics.
        @Shared(.appStorage("meshtasticEnabled")) public var meshtasticEnabled: Bool = false
        /// The chosen radio's CoreBluetooth peripheral UUID as a string, nil when none is chosen.
        /// Read it through `meshtasticRadioUUID`, which treats a non-UUID string as no radio.
        @Shared(.appStorage("meshtasticRadioID")) public var meshtasticRadioID: String? = nil
        /// The chosen radio's advertised name when it was picked, for the Settings row only.
        /// Unauthenticated text from the air: never put it in a diagnostics reason.
        @Shared(.appStorage("meshtasticRadioName")) public var meshtasticRadioName: String? = nil
```

- [ ] **Step 4: Create `AppFeature+Meshtastic.swift`**

Create `CORE/Sources/ReTiCaMsgrCore/AppFeature+Meshtastic.swift`:

```swift
import Foundation
import ComposableArchitecture

// Meshtastic settings (spec 2026-10-16 §7 lane D). Lane E reads `meshtasticEnabled` and
// `meshtasticRadioUUID` at connect time to build the endpoint slot.

extension AppFeature.State {
    /// The chosen radio, or nil when none is chosen OR the stored string is not a UUID (Review
    /// Focus 4): a hand-edited or corrupted default must read as "no radio", never as a radio to dial.
    public var meshtasticRadioUUID: UUID? {
        meshtasticRadioID.flatMap(UUID.init(uuidString:))
    }

    /// The Settings radio row: the name the radio advertised when it was picked, else its UUID,
    /// else "None".
    public var meshtasticRadioLabel: String {
        guard let id = meshtasticRadioUUID else { return "None" }
        let name = meshtasticRadioName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? id.uuidString : name
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic/ReTiCaMsgrCore --filter meshSettings > /tmp/ReTiCAMsgr-meshtastic/t2-green.log 2>&1`
Expected: 6 tests passed.

- [ ] **Step 6: Mutation batch (one run)**

Apply ALL, run the Step 5 command once (log `t2-mut.log`). Expected: all 6 FAIL. The label tests seed through `withLock`, not the defaults key, so S3 cannot mask them. S4 and S5 are chosen so that each label test fails under the pair together.

| # | File | Mutation | Test that must fail |
|---|---|---|---|
| S1 | AppFeature.swift | `meshtasticEnabled: Bool = false` becomes `= true` | `meshSettingsDefaultsAreOffWithNoRadio` |
| S2 | AppFeature.swift | key `"meshtasticEnabled"` becomes `"meshtasticOn"` | `meshSettingsToggleWritesTheMeshtasticEnabledKey` |
| S3 | AppFeature.swift | key `"meshtasticRadioID"` becomes `"meshtasticRadio"` | `meshSettingsReadsAPersistedRadioID` |
| S4 | AppFeature+Meshtastic.swift | `let name = meshtasticRadioName?.trimming…` becomes `let name = ""` | `meshSettingsRadioLabelShowsTheName` |
| S5 | AppFeature+Meshtastic.swift | `return name.isEmpty ? id.uuidString : name` becomes `return name.isEmpty ? "None" : name` | `meshSettingsRadioLabelFallsBackToTheIDForABlankName` |
| S6 | AppFeature+Meshtastic.swift | `guard let id = meshtasticRadioUUID else { return "None" }` becomes `guard let id = meshtasticRadioUUID else { return meshtasticRadioID ?? "None" }` | `meshSettingsNonUUIDRadioIDCountsAsNoRadio` |

- [ ] **Step 7: Revert by hand and re-run**

Revert with the Edit tool. `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic diff` must show only Step 3's insertion. Re-run the Step 5 command (log `t2-green2.log`): 6 passed.

- [ ] **Step 8: Commit**

```bash
git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature+Meshtastic.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/MeshtasticSettingsTests.swift
```

Message file `/tmp/ReTiCAMsgr-meshtastic/msg-task-2.txt`:

```
feat: persisted Meshtastic settings beside bleEnabled

meshtasticEnabled (off by default), meshtasticRadioID and meshtasticRadioName
in app storage, plus meshtasticRadioUUID (a non-UUID string reads as no radio)
and the Settings row label (name, else UUID, else None). Tests read the keys
back from a dedicated UserDefaults suite.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

Run the commit and the trailer check as in Task 1 Step 8.

---

### Task 3: Present the picker, pause and resume BLE around it

**Files:**
- Modify: `CORE/Sources/ReTiCaMsgrCore/AppFeature.swift`: State (after Task 2's three keys), Action (before `case node(LXMFServiceNode.Action)`, currently line 583), the main `Reduce`'s no-op arms (after the blocking arm, currently lines 2271-2273), `body` (after `BlockingReducer()`, currently line 2386), `redialDownNodes` (the BLE `.start` line, currently 2935-2937)
- Modify: `CORE/Sources/ReTiCaMsgrCore/AppFeature+Meshtastic.swift` (append the reducer and `bleIsRunning`)
- Modify: `CORE/Tests/ReTiCaMsgrCoreTests/MeshtasticSettingsTests.swift` (append)

**Interfaces:**
- Consumes: `RadioPickerFeature` (State, Action, `Delegate.selected`) and `waitUntil` (Task 1). `meshtasticRadioID`, `meshtasticRadioName`, `meshtasticRadioUUID`, `meshStore`, `radioA` (Task 2). Existing: `.node(.client(.endpoint(.ble(.start))))`, `.node(.client(.endpoint(.ble(.stop))))` (`BLEEndpoint.swift:51-53, 76-77`), `state.node.client.endpoint.ble?.ble.status: BLEInterfaceStatus`.
- Produces:
  - `AppFeature.State.radioPicker: RadioPickerFeature.State?` (`@Presents`), `AppFeature.State.blePausedForRadioScan: Bool`
  - `AppFeature.Action.chooseRadioTapped`, `AppFeature.Action.radioPicker(PresentationAction<RadioPickerFeature.Action>)`
  - `struct MeshtasticSettingsReducer: Reducer` (body `some ReducerOf<AppFeature>`)
  - `extension AppFeature.State { var bleIsRunning: Bool }` (internal)

**Why the slot status, not `bleEnabled`:** the spec says "while the picker is presented and `bleEnabled` is on". But `bleEnabled` is applied only at Connect (`syncEndpointNodes`, `AppFeature.swift:2801-2809`): a slot can be running with the flag already off (toggled off since the last Connect), and the flag can be on with no slot (never connected). A `.ble` action sent to a missing slot trips TransportEndpoint's `ifLet` (`AppFeatureTests.swift:257-258`). Restarting a BLE interface the user had stopped (Disconnect) would be a regression. So the pause keys on the live slot status. `BLEInterface` accepts `.start` only from `.stopped` or terminally `.unavailable` (`BLEInterface.swift:113-116`), and `.stop` from any state.

**Why every exit goes through `.radioPicker(.dismiss)`:** SwiftUI's `sheet(item: $store.scope(...))` sends `.dismiss` on a swipe, and the child's `@Dependency(\.dismiss)` (Cancel, a pick) also arrives as `.dismiss`. TCA's presentation reducer runs the parent arm while the child state is still present, then nils it and cancels the child's effects, which includes the scan (`PresentationReducer.swift:476-483, 546-557`). Setting `state.radioPicker = nil` directly would skip `.dismiss` and leave BLE paused, so nothing does that.

- [ ] **Step 1: Write the failing tests**

Append to `CORE/Tests/ReTiCaMsgrCoreTests/MeshtasticSettingsTests.swift`:

```swift
// MARK: - Picker presentation and BLE pause (T3)

/// A BLE slot as a Connect with `bleEnabled` on builds it, with its interface in `status`.
private func withBLE(_ state: inout AppFeature.State, _ status: BLEInterfaceStatus) {
    state.$bleEnabled.withLock { $0 = true }
    var ble = BLEEndpoint.State(localIdentity: state.identity.hash)
    ble.ble.status = status
    state.node.client.endpoint.ble = ble
}

private func isBLEStop(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.ble(.stop)))) = action { return true }
    return false
}

private func isBLEStart(_ action: AppFeature.Action) -> Bool {
    if case .node(.client(.endpoint(.ble(.start)))) = action { return true }
    return false
}

private func isPickerDismiss(_ action: AppFeature.Action) -> Bool {
    if case .radioPicker(.dismiss) = action { return true }
    return false
}

private func isPickerSelection(_ action: AppFeature.Action) -> Bool {
    if case .radioPicker(.presented(.delegate(.selected))) = action { return true }
    return false
}

enum PickerExit: String, CaseIterable, Sendable { case swipe, cancel, pick }

@MainActor @Test func meshPickerFlowChooseRadioOpensThePickerOnTheStoredRadio() async {
    let store = meshStore { $0.$meshtasticRadioID.withLock { $0 = radioA.id.uuidString } }
    await store.send(.chooseRadioTapped)
    #expect(store.state.radioPicker?.selectedID == radioA.id)
}

/// FCB has one scan per process (spec §2): a running BLE interface is stopped while the picker
/// scans.
@MainActor @Test func meshPickerFlowPausesRunningBLE() async {
    let store = meshStore { withBLE(&$0, .online) }
    await store.send(.chooseRadioTapped)
    await store.receive(isBLEStop)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .stopped)
    #expect(store.state.blePausedForRadioScan)
}

/// Swipe (what the sheet binding sends), Cancel and a pick all restart the BLE the picker paused.
@MainActor @Test(arguments: PickerExit.allCases)
func meshPickerFlowEveryExitResumesPausedBLE(_ exit: PickerExit) async {
    let store = meshStore { withBLE(&$0, .online) }
    await store.send(.chooseRadioTapped)
    await store.receive(isBLEStop)
    switch exit {
    case .swipe:
        await store.send(.radioPicker(.dismiss))
    case .cancel:
        await store.send(.radioPicker(.presented(.cancelTapped)))
        await store.receive(isPickerDismiss)
    case .pick:
        await store.send(.radioPicker(.presented(.radioFound(radioA))))
        await store.send(.radioPicker(.presented(.radioTapped(radioA.id))))
        await store.receive(isPickerDismiss)
    }
    await store.receive(isBLEStart)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .starting)
    #expect(!store.state.blePausedForRadioScan)
}

/// Review Focus 2: BLE the user stopped (Disconnect) is not "paused" by the picker, so closing it
/// must not start BLE.
@MainActor @Test func meshPickerFlowLeavesStoppedBLEStopped() async {
    let store = meshStore { withBLE(&$0, .stopped) }
    await store.send(.chooseRadioTapped)
    #expect(!store.state.blePausedForRadioScan)
    await store.send(.radioPicker(.dismiss))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.ble?.ble.status == .stopped)
}

/// Review Focus 2: BLE toggled on but never connected has no slot. A `.ble` action to the missing
/// slot would trip TransportEndpoint's ifLet (a reported issue fails this test).
@MainActor @Test func meshPickerFlowWithoutBLESlotSendsNoBLEAction() async {
    let store = meshStore { $0.$bleEnabled.withLock { $0 = true } }
    await store.send(.chooseRadioTapped)
    await store.skipReceivedActions(strict: false)
    #expect(!store.state.blePausedForRadioScan)
    await store.send(.radioPicker(.dismiss))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.node.client.endpoint.ble == nil)
}

@MainActor @Test func meshPickerFlowSelectingStoresTheRadioID() async {
    let defaults = UserDefaults.inMemory
    let store = meshStore(defaults: defaults)
    await store.send(.chooseRadioTapped)
    await store.send(.radioPicker(.presented(.radioFound(radioA))))
    await store.send(.radioPicker(.presented(.radioTapped(radioA.id))))
    await store.receive(isPickerSelection)
    #expect(defaults.string(forKey: "meshtasticRadioID") == radioA.id.uuidString)
}

@MainActor @Test func meshPickerFlowSelectingStoresTheRadioName() async {
    let defaults = UserDefaults.inMemory
    let store = meshStore(defaults: defaults)
    await store.send(.chooseRadioTapped)
    await store.send(.radioPicker(.presented(.radioFound(radioA))))
    await store.send(.radioPicker(.presented(.radioTapped(radioA.id))))
    await store.receive(isPickerSelection)
    #expect(defaults.string(forKey: "meshtasticRadioName") == "Alpha")
}

@MainActor @Test func meshPickerFlowSelectingClosesThePicker() async {
    let store = meshStore()
    await store.send(.chooseRadioTapped)
    await store.send(.radioPicker(.presented(.radioFound(radioA))))
    await store.send(.radioPicker(.presented(.radioTapped(radioA.id))))
    await store.receive(isPickerDismiss)
    #expect(store.state.radioPicker == nil)
}

/// The scan must not outlive the sheet: closing it ends the scanner's stream.
@MainActor @Test func meshPickerFlowDismissStopsTheScan() async {
    let started = LockIsolated(false)
    let terminated = LockIsolated(false)
    let scanner = RadioScanner(scan: {
        started.setValue(true)
        return AsyncStream { continuation in
            continuation.onTermination = { _ in terminated.setValue(true) }
        }
    })
    let store = meshStore(scanner: scanner)
    await store.send(.chooseRadioTapped)
    await store.send(.radioPicker(.presented(.onAppear)))
    // Precondition: the scan really started, so termination below is the dismiss's doing.
    #expect(await waitUntil { started.value })
    #expect(!terminated.value)
    await store.send(.radioPicker(.dismiss))
    #expect(await waitUntil { terminated.value })
}

/// Review Focus 1. SEEDED, not driven, on purpose: the pause itself is proven by
/// `meshPickerFlowPausesRunningBLE`, and seeding keeps this test's only failure mode the
/// `redialDownNodes` guard (the one-batch mutation rule in Step 6). An empty node list means no
/// TCP slots, which is the case where `redialDownNodes` always reaches the BLE restart.
@MainActor @Test func meshPickerFlowForegroundWhileOpenKeepsBLEPaused() async {
    let store = meshStore { state in
        withBLE(&state, .stopped)
        state.radioPicker = RadioPickerFeature.State()
        state.blePausedForRadioScan = true
    }
    await store.send(.foregrounded)
    // `redialDownNodes` concatenates removals, then the dials (BLE start among them), then the push
    // re-point, whose first action is `.push(.hubChanged)`. Once that is received, a BLE start
    // would already have been processed.
    await store.receive { if case .push(.hubChanged) = $0 { return true }; return false }
    #expect(store.state.node.client.endpoint.ble?.ble.status == .stopped)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic/ReTiCaMsgrCore --filter meshPickerFlow > /tmp/ReTiCAMsgr-meshtastic/t3-red.log 2>&1`
Expected: compile errors naming `chooseRadioTapped`, `radioPicker`, `blePausedForRadioScan`.

- [ ] **Step 3: State and Action**

In `AppFeature.swift`, directly after Task 2's `meshtasticRadioName` property, insert:

```swift
        /// The radio picker sheet (spec 2026-10-16 §7), nil when closed. Closed ONLY through
        /// `.radioPicker(.dismiss)` (swipe, Cancel, or a pick), which is where paused BLE resumes:
        /// never set this to nil directly.
        @Presents public var radioPicker: RadioPickerFeature.State?
        /// The picker stopped a running BLE interface so its scan owns FCB's one scan (spec §2),
        /// and `.radioPicker(.dismiss)` restarts it and clears this. `redialDownNodes` leaves BLE
        /// alone while it is set. Session-only.
        public var blePausedForRadioScan = false
```

In `AppFeature.Action`, directly before `case node(LXMFServiceNode.Action)`, insert:

```swift
        /// "Choose radio…" in Settings (spec 2026-10-16 §7): opens the radio picker and pauses a
        /// running BLE interface. Handled in `MeshtasticSettingsReducer`.
        case chooseRadioTapped
        case radioPicker(PresentationAction<RadioPickerFeature.Action>)
```

- [ ] **Step 4: No-op arm, composition, redial guard**

In the main `Reduce`'s switch, directly after the arm `case .blockPeer, .unblockPeer, .blockedPeersLoaded, .reportPeer, .reportDraftReady, .reportDismissed:` / `return .none` (currently lines 2271-2273), insert:

```swift
            // The Meshtastic picker arms live in `MeshtasticSettingsReducer` (AppFeature+Meshtastic.swift).
            case .chooseRadioTapped, .radioPicker:
                return .none
```

In `body`, change

```swift
        ContactLinksReducer()
        BlockingReducer()
    }
```

to

```swift
        ContactLinksReducer()
        BlockingReducer()
        MeshtasticSettingsReducer()
    }
```

In `redialDownNodes`, change

```swift
    if state.node.client.endpoint.ble != nil {
        dials.append(.send(.node(.client(.endpoint(.ble(.start))))))
    }
```

to

```swift
    // Not while the radio picker holds BLE paused (spec 2026-10-16 §7, Review Focus 1): a restart
    // here would take FCB's one scan from the picker. Its dismiss restarts BLE.
    if state.node.client.endpoint.ble != nil, !state.blePausedForRadioScan {
        dials.append(.send(.node(.client(.endpoint(.ble(.start))))))
    }
```

This is a BLE-only guard: no meshtastic slot or restart is added to `redialDownNodes` (lane E owns that).

- [ ] **Step 5: The reducer**

Append to `CORE/Sources/ReTiCaMsgrCore/AppFeature+Meshtastic.swift`:

```swift
extension AppFeature.State {
    /// A BLE slot exists and its interface is up or coming up: `starting`, `online`, or waiting out
    /// an adapter retry (whose timer would restart scanning). `stopped` (Disconnect) and a terminal
    /// `unavailable` are not running: "pausing" them would make the picker's dismiss START them.
    /// Keyed on the live slot, not `bleEnabled`, which only takes effect at the next Connect.
    var bleIsRunning: Bool {
        guard let status = node.client.endpoint.ble?.ble.status else { return false }
        switch status {
        case .starting, .online, .waitingForAdapter: return true
        case .stopped, .unavailable:                 return false
        }
    }
}

/// The Meshtastic Settings arms of `AppFeature` (spec 2026-10-16 §7 lane D), composed into
/// `AppFeature.body` after `BlockingReducer`. The main reducer treats these actions as no-ops.
/// It owns the radio picker's presentation and the BLE pause around it.
struct MeshtasticSettingsReducer: Reducer {
    var body: some ReducerOf<AppFeature> {
        Reduce { state, action in
            switch action {
            case .chooseRadioTapped:
                guard state.radioPicker == nil else { return .none }
                let selected = state.meshtasticRadioUUID
                state.radioPicker = RadioPickerFeature.State(selectedID: selected)
                // FCB runs ONE scan per process and a new scan silently supersedes the old (spec
                // §2), so a running BLE interface and the picker would steal each other's scan.
                // Pause BLE while the picker is up. A stopped or unavailable interface, or a
                // missing slot, is left alone (see `bleIsRunning`).
                guard state.bleIsRunning else { return .none }
                state.blePausedForRadioScan = true
                return .send(.node(.client(.endpoint(.ble(.stop)))))

            case let .radioPicker(.presented(.delegate(.selected(radio)))):
                state.$meshtasticRadioID.withLock { $0 = radio.id.uuidString }
                state.$meshtasticRadioName.withLock { $0 = radio.name }
                return .none

            case .radioPicker(.dismiss):
                // Every way out arrives here: the sheet's swipe, Cancel and a pick (the child's
                // `dismiss()`). The presentation reducer cancels the scan right after this arm.
                // Restart only what was paused, and only if its slot is still there.
                guard state.blePausedForRadioScan else { return .none }
                state.blePausedForRadioScan = false
                guard state.node.client.endpoint.ble != nil else { return .none }
                return .send(.node(.client(.endpoint(.ble(.start)))))

            default:
                return .none
            }
        }
        .ifLet(\.$radioPicker, action: \.radioPicker) {
            RadioPickerFeature()
        }
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic/ReTiCaMsgrCore --filter meshPickerFlow > /tmp/ReTiCAMsgr-meshtastic/t3-green.log 2>&1`
Expected: 10 tests passed (`meshPickerFlowEveryExitResumesPausedBLE` runs 3 cases).

Then the whole core suite, to catch an `ifLet` or exhaustive-switch regression elsewhere:
Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic/ReTiCaMsgrCore > /tmp/ReTiCAMsgr-meshtastic/t3-full.log 2>&1`
Expected: baseline + 27 passed, no failures (`AppFeatureTests` never opens the picker, so `RadioScanner.testValue` is never called).

- [ ] **Step 7: Mutation batch (one run)**

Apply ALL, run the Step 6 filtered command once (log `t3-mut.log`). Expected: every `meshPickerFlow` test FAILS, including all 3 cases of the parameterized one. M2 cannot mask the foreground test (that test is seeded). The two "left alone" tests assert the pause flag, so M3 cannot mask M4.

| # | File | Mutation | Test that must fail |
|---|---|---|---|
| M1 | AppFeature+Meshtastic.swift | `RadioPickerFeature.State(selectedID: selected)` becomes `RadioPickerFeature.State()` | `meshPickerFlowChooseRadioOpensThePickerOnTheStoredRadio` |
| M2 | AppFeature+Meshtastic.swift | `.chooseRadioTapped`: `return .send(.node(.client(.endpoint(.ble(.stop)))))` becomes `return .none` (the flag is still set) | `meshPickerFlowPausesRunningBLE` |
| M3 | AppFeature+Meshtastic.swift | `.radioPicker(.dismiss)`: `return .send(.node(.client(.endpoint(.ble(.start)))))` becomes `return .none` | `meshPickerFlowEveryExitResumesPausedBLE` (all 3) |
| M4 | AppFeature+Meshtastic.swift | `bleIsRunning`'s whole body becomes `bleEnabled` | `meshPickerFlowLeavesStoppedBLEStopped`, `meshPickerFlowWithoutBLESlotSendsNoBLEAction` |
| M5 | AppFeature+Meshtastic.swift | delete `state.$meshtasticRadioID.withLock { $0 = radio.id.uuidString }` | `meshPickerFlowSelectingStoresTheRadioID` |
| M6 | AppFeature+Meshtastic.swift | delete `state.$meshtasticRadioName.withLock { $0 = radio.name }` | `meshPickerFlowSelectingStoresTheRadioName` |
| M7 | RadioPickerFeature.swift | `.radioTapped`: delete the `.run { [dismiss] _ in await dismiss() }` line from the `.concatenate` | `meshPickerFlowSelectingClosesThePicker` |
| M8 | RadioPickerFeature.swift | `.onAppear`'s run body becomes `Task { for await radio in radioScanner.scan() { await send(.radioFound(radio)) } }` (an unstructured task escapes cancellation) | `meshPickerFlowDismissStopsTheScan` |
| M9 | AppFeature.swift | `redialDownNodes`: `if state.node.client.endpoint.ble != nil, !state.blePausedForRadioScan {` becomes `if state.node.client.endpoint.ble != nil {` | `meshPickerFlowForegroundWhileOpenKeepsBLEPaused` |

M8 leaves the closure without its `guard`/`scanFinished` lines. That is intended, and it compiles.

- [ ] **Step 8: Revert by hand and re-run**

Revert with the Edit tool. `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic diff` must show only Steps 3-5 and the appended tests. Re-run the Step 6 filtered command (log `t3-green2.log`): 10 passed.

- [ ] **Step 9: Commit**

```bash
git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature+Meshtastic.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/MeshtasticSettingsTests.swift
```

Message file `/tmp/ReTiCAMsgr-meshtastic/msg-task-3.txt`:

```
feat: radio picker presentation pauses BLE while it scans

FCB has one scan per process, so Choose radio stops a running BLE interface
and every way out of the picker (swipe, Cancel, a pick) restarts it through
radioPicker dismiss. The pause keys on the live slot status rather than
bleEnabled, so stopped BLE, unavailable BLE and a missing slot are left alone.
A foreground or push wake while the picker is open no longer restarts BLE.
A pick stores the radio id and name.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

Run the commit and the trailer check as in Task 1 Step 8.

---

### Task 4: `MeshtasticStatus` and the Diagnostics layer

**Files:**
- Create: `CORE/Sources/ReTiCaMsgrCore/MeshtasticStatus.swift`
- Modify: `CORE/Sources/ReTiCaMsgrCore/AppFeature.swift` (one State property after `blePausedForRadioScan`)
- Modify: `CORE/Sources/ReTiCaMsgrCore/DiagnosticsSnapshot.swift` (layer list at lines 56-64, and a new `// MARK: - Meshtastic` extension after the Bluetooth extension, which ends at line 214)
- Modify: `CORE/Tests/ReTiCaMsgrCoreTests/DiagnosticsSnapshotTests.swift` (`snapshotHasAllLayersInOrder` at lines 438-442, and append)

**Interfaces:**
- Consumes: `meshtasticEnabled`, `meshtasticRadioUUID`, `meshtasticRadioLabel`, `meshtasticRadioName` (Task 2). Existing `DiagnosticsSnapshot.Layer`/`Row`/`text`/`escaped`, `BLEAdapterUnavailable` (`ReTiCAInterfaces/BLEDriver.swift:30-34`).
- Produces (lane E populates these):
  - `public struct MeshtasticStatus: Equatable, Sendable { online: Bool; modemPreset: Int?; myNodeNum: UInt32?; offlineReason: String?; adapterUnavailable: BLEAdapterUnavailable?; counters: Counters }`, `MeshtasticStatus.Counters { malformed, evicted, timedOut, oversize, completed, queueFull, sendFailed: Int }`, memberwise `init` with defaults
  - `AppFeature.State.meshtasticStatus: MeshtasticStatus` (session-only)
  - `DiagnosticsSnapshot.meshtasticLayer(_:) -> Layer`, title `"Meshtastic"`, placed after `"Bluetooth"`

`offlineReason` and `adapterUnavailable` go beyond the fields the spec lists ("online, preset, node number, counters"). Contract 3's `.radioOffline(reason:)` and `.adapterUnavailable(BLEAdapterUnavailable)` delegates carry them. Without them, Contract 2's loud stub (`.unavailable(.other("ReTiCAMeshtasticLive not installed"))`) would never reach a person. So, unlike `bleLayer`'s `describe(_ cause:)` (`DiagnosticsSnapshot.swift:206-213`), this layer renders the `.other` payload, in a ROW (rows are escaped by `text`, reasons are not). The radio's advertised name also only ever appears in a row.

- [ ] **Step 1: Write the failing tests**

In `DiagnosticsSnapshotTests.swift`, change `snapshotHasAllLayersInOrder`'s expectation (lines 440-441) to:

```swift
    #expect(snapshot.layers.map(\.title)
            == ["Socket", "Bluetooth", "Meshtastic", "Identity", "Paths", "Peers", "Links", "Delivery"])
```

Append to the end of `DiagnosticsSnapshotTests.swift`:

```swift
// MARK: - Meshtastic (spec 2026-10-16 §7 lane D)

private let meshRadio = UUID(uuidString: "6A1B2C3D-0000-4000-8000-00000000AB01")!

/// Non-fatal lookup: a missing layer fails the assertion instead of crashing the suite.
private func meshLayer(_ snap: DiagnosticsSnapshot) -> DiagnosticsSnapshot.Layer? {
    snap.layers.first { $0.title == "Meshtastic" }
}

private func meshRow(_ layer: DiagnosticsSnapshot.Layer?, _ label: String) -> String? {
    layer?.rows.first { $0.label == label }?.value
}

/// A healthy state with the Meshtastic settings set, its `@Shared(.appStorage)` keys in a fresh
/// suite so no test sees another's.
@MainActor
private func meshState(enabled: Bool = true, radio: UUID? = meshRadio, name: String? = "Base camp",
                       status: MeshtasticStatus = MeshtasticStatus()) -> AppFeature.State {
    var state = withDependencies { $0.defaultAppStorage = .inMemory } operation: { healthyState() }
    state.$meshtasticEnabled.withLock { $0 = enabled }
    state.$meshtasticRadioID.withLock { $0 = radio?.uuidString }
    state.$meshtasticRadioName.withLock { $0 = name }
    state.meshtasticStatus = status
    return state
}

/// Off by choice is not a fault, like Bluetooth.
@MainActor @Test func meshDiagIsOffAndOkWhenDisabled() {
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(enabled: false), at: fixedDate))
    #expect(layer?.health == .ok)
    #expect(meshRow(layer, "meshtastic") == "off")
}

@MainActor @Test func meshDiagWarnsWhenNoRadioIsChosen() {
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(radio: nil), at: fixedDate))
    #expect(layer?.health == .warn)
    #expect(layer?.reason?.contains("no radio") == true)
}

@MainActor @Test func meshDiagWarnsWhileTheRadioIsOffline() {
    let status = MeshtasticStatus(online: false, offlineReason: "link lost")
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(status: status), at: fixedDate))
    #expect(layer?.health == .warn)
    #expect(layer?.reason == "radio not connected")
    #expect(meshRow(layer, "offline reason") == "link lost")
}

@MainActor @Test func meshDiagIsOkWhenOnline() {
    let status = MeshtasticStatus(online: true, modemPreset: 6, myNodeNum: 0xABCD)
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(status: status), at: fixedDate))
    #expect(layer?.health == .ok)
    #expect(layer?.reason == nil)
}

/// Meshtastic names nodes `!` + 8 lowercase hex digits. Matching it lets a reader find the same
/// node in the Meshtastic app.
@MainActor @Test func meshDiagShowsTheNodeNumberInMeshtasticForm() {
    let status = MeshtasticStatus(online: true, myNodeNum: 0x0000_ABCD)
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(status: status), at: fixedDate))
    #expect(meshRow(layer, "node") == "!0000abcd")
}

@MainActor @Test func meshDiagNamesThePreset() {
    let status = MeshtasticStatus(online: true, modemPreset: 6)
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(status: status), at: fixedDate))
    #expect(meshRow(layer, "preset") == "ShortFast (6)")
}

/// A preset newer than this build still shows its raw value, never a guess.
@MainActor @Test func meshDiagShowsAnUnknownPresetRaw() {
    let status = MeshtasticStatus(online: true, modemPreset: 9)
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(status: status), at: fixedDate))
    #expect(meshRow(layer, "preset") == "unknown (9)")
}

@MainActor @Test func meshDiagAdapterUnavailableIsAProblem() {
    let status = MeshtasticStatus(online: false, adapterUnavailable: .unauthorized)
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(status: status), at: fixedDate))
    #expect(layer?.health == .problem)
}

/// Contract 2's liveValue is loud on purpose: its message must reach the screen.
@MainActor @Test func meshDiagShowsTheUninstalledDriverMessage() {
    let status = MeshtasticStatus(online: false, adapterUnavailable: .other("ReTiCAMeshtasticLive not installed"))
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(status: status), at: fixedDate))
    #expect(meshRow(layer, "adapter") == "other: ReTiCAMeshtasticLive not installed")
}

@MainActor @Test func meshDiagRendersEveryCounter() {
    let counters = MeshtasticStatus.Counters(malformed: 1, evicted: 2, timedOut: 3, oversize: 4,
                                             completed: 5, queueFull: 6, sendFailed: 7)
    let layer = meshLayer(DiagnosticsSnapshot(from: meshState(status: MeshtasticStatus(counters: counters)),
                                              at: fixedDate))
    #expect(meshRow(layer, "malformed") == "1")
    #expect(meshRow(layer, "evicted") == "2")
    #expect(meshRow(layer, "timed out") == "3")
    #expect(meshRow(layer, "oversize") == "4")
    #expect(meshRow(layer, "reassembled") == "5")
    #expect(meshRow(layer, "queue full") == "6")
    #expect(meshRow(layer, "send failed") == "7")
}

/// Review Focus 3: the advertised name is attacker-controlled. Rows are escaped by `text`, the
/// reason is not, so the name must never reach a reason. Same shape as
/// `aHostilePeerDisplayNameCannotForgeLinesInTheExport`.
@MainActor @Test func meshDiagAHostileRadioNameCannotForgeLines() {
    let forged = "SOCKET  [ok] all good"
    let hostile = meshState(name: "Mallory\n  \(forged)")
    let benign = meshState(name: "Mallory")
    // Precondition: the hostile name really reached a row.
    #expect(meshLayer(DiagnosticsSnapshot(from: hostile, at: fixedDate))?
        .rows.contains { $0.value.contains("\n") } == true)
    let text = DiagnosticsSnapshot(from: hostile, at: fixedDate).text
    let control = DiagnosticsSnapshot(from: benign, at: fixedDate).text
    #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count
            == control.split(separator: "\n", omittingEmptySubsequences: false).count)
    #expect(!text.contains("\n  \(forged)"))
    #expect(text.contains("Mallory\\n"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic/ReTiCaMsgrCore --filter meshDiag --filter snapshotHasAllLayersInOrder > /tmp/ReTiCAMsgr-meshtastic/t4-red.log 2>&1`
Expected: compile errors naming `MeshtasticStatus` and `meshtasticStatus`.

- [ ] **Step 3: Create `MeshtasticStatus.swift`**

```swift
import Foundation
import ReTiCAInterfaces

/// What Diagnostics shows about the Meshtastic radio (spec 2026-10-16 §7 lane D): plain,
/// session-only app state. Lane D only renders it. Lane E fills it from the Meshtastic endpoint's
/// delegates (`.radioOnline(myNodeNum:modemPreset:)`, `.radioOffline(reason:)`,
/// `.adapterUnavailable`, spec Contract 3) and from the interface's reassembler and sender
/// counters (spec §5.2, §5.3).
public struct MeshtasticStatus: Equatable, Sendable {
    /// Cumulative since launch.
    public struct Counters: Equatable, Sendable {
        /// Reassembler (spec §5.2).
        public var malformed: Int
        public var evicted: Int
        public var timedOut: Int
        public var oversize: Int
        public var completed: Int
        /// Sender (spec §5.3).
        public var queueFull: Int
        public var sendFailed: Int

        public init(malformed: Int = 0, evicted: Int = 0, timedOut: Int = 0, oversize: Int = 0,
                    completed: Int = 0, queueFull: Int = 0, sendFailed: Int = 0) {
            self.malformed = malformed
            self.evicted = evicted
            self.timedOut = timedOut
            self.oversize = oversize
            self.completed = completed
            self.queueFull = queueFull
            self.sendFailed = sendFailed
        }
    }

    public var online: Bool
    /// Raw `Config.LoRaConfig.ModemPreset` value from the radio, nil until it is known.
    public var modemPreset: Int?
    public var myNodeNum: UInt32?
    /// The last disconnect's reason, if the radio gave one.
    public var offlineReason: String?
    /// Set while the Bluetooth path to the radio is unavailable (including Contract 2's
    /// "ReTiCAMeshtasticLive not installed" stub).
    public var adapterUnavailable: BLEAdapterUnavailable?
    public var counters: Counters

    public init(online: Bool = false, modemPreset: Int? = nil, myNodeNum: UInt32? = nil,
                offlineReason: String? = nil, adapterUnavailable: BLEAdapterUnavailable? = nil,
                counters: Counters = Counters()) {
        self.online = online
        self.modemPreset = modemPreset
        self.myNodeNum = myNodeNum
        self.offlineReason = offlineReason
        self.adapterUnavailable = adapterUnavailable
        self.counters = counters
    }
}
```

- [ ] **Step 4: State property**

In `AppFeature.swift`, directly after `public var blePausedForRadioScan = false`, insert:

```swift
        /// The radio's state for Diagnostics. Session-only. Lane E fills it from the Meshtastic
        /// endpoint's delegates. This build leaves it at its defaults (offline).
        public var meshtasticStatus = MeshtasticStatus()
```

- [ ] **Step 5: The layer**

In `DiagnosticsSnapshot.swift` `init(from:at:)`, change

```swift
            Self.bleLayer(state),
            Self.identityLayer(state),
```

to

```swift
            Self.bleLayer(state),
            Self.meshtasticLayer(state),
            Self.identityLayer(state),
```

After the Bluetooth extension's closing brace (the line after `describe(_ cause: BLEAdapterUnavailable)`'s closing brace, currently line 214), insert:

```swift
// MARK: - Meshtastic

extension DiagnosticsSnapshot {
    /// The Meshtastic radio (spec 2026-10-16 §7 lane D), fed from `AppFeature.State.meshtasticStatus`.
    ///
    /// UNTRUSTED TEXT: the radio's advertised name (`meshtasticRadioLabel`) and the `.other`
    /// adapter payload are rendered in ROWS only, which `text` escapes. Never in `reason`, which
    /// it does not (`meshDiagAHostileRadioNameCannotForgeLines`). Unlike `bleLayer`, the `.other`
    /// payload IS shown: Contract 2's loud "ReTiCAMeshtasticLive not installed" lives there.
    static func meshtasticLayer(_ state: AppFeature.State) -> Layer {
        let title = "Meshtastic"
        let enabled = state.meshtasticEnabled
        var rows = [Row("meshtastic", enabled ? "on" : "off")]
        guard enabled else {
            // Off by choice is not a fault.
            return Layer(title: title, health: .ok, reason: nil, rows: rows)
        }

        let status = state.meshtasticStatus
        let radio = state.meshtasticRadioUUID
        rows.append(Row("radio", radio == nil ? "(none chosen)" : state.meshtasticRadioLabel))
        if let radio { rows.append(Row("radio id", radio.uuidString)) }
        rows.append(Row("status", status.online ? "online" : "offline"))
        if let reason = status.offlineReason { rows.append(Row("offline reason", reason)) }
        if let cause = status.adapterUnavailable { rows.append(Row("adapter", describeMeshtastic(cause))) }
        if let node = status.myNodeNum { rows.append(Row("node", meshtasticNodeName(node))) }
        rows.append(Row("preset", meshtasticPresetName(status.modemPreset)))
        let counters = status.counters
        rows.append(contentsOf: [
            Row("reassembled", String(counters.completed)),
            Row("malformed", String(counters.malformed)),
            Row("evicted", String(counters.evicted)),
            Row("timed out", String(counters.timedOut)),
            Row("oversize", String(counters.oversize)),
            Row("queue full", String(counters.queueFull)),
            Row("send failed", String(counters.sendFailed)),
        ])

        guard radio != nil else {
            return Layer(title: title, health: .warn,
                         reason: "no radio chosen — choose one in Settings", rows: rows)
        }
        if status.adapterUnavailable != nil {
            return Layer(title: title, health: .problem,
                         reason: "the Bluetooth path to the radio is unavailable", rows: rows)
        }
        guard status.online else {
            return Layer(title: title, health: .warn, reason: "radio not connected", rows: rows)
        }
        return Layer(title: title, health: .ok, reason: nil, rows: rows)
    }

    /// The cause name, and for `.other` its payload too (see `meshtasticLayer`).
    static func describeMeshtastic(_ cause: BLEAdapterUnavailable) -> String {
        switch cause {
        case .poweredOff:          return "powered off"
        case .unauthorized:        return "unauthorized"
        case .unsupported:         return "unsupported"
        case let .other(detail):   return detail.map { "other: \($0)" } ?? "other"
        }
    }

    /// Meshtastic's own node naming: `!` and 8 lowercase hex digits.
    static func meshtasticNodeName(_ num: UInt32) -> String {
        String(format: "!%08x", num)
    }

    /// The preset's name and raw value. Raw values from spec Contract 3's table
    /// (`Config.LoRaConfig.ModemPreset`). A value this build does not know shows raw.
    static func meshtasticPresetName(_ raw: Int?) -> String {
        guard let raw else { return "unknown" }
        let names = [0: "LongFast", 1: "LongSlow", 3: "MediumSlow", 4: "MediumFast",
                     5: "ShortSlow", 6: "ShortFast", 7: "LongModerate", 8: "ShortTurbo"]
        return names[raw].map { "\($0) (\(raw))" } ?? "unknown (\(raw))"
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic/ReTiCaMsgrCore --filter meshDiag --filter snapshotHasAllLayersInOrder > /tmp/ReTiCAMsgr-meshtastic/t4-green.log 2>&1`
Expected: 12 tests passed (11 new plus the updated order test).

Then the full core suite: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic/ReTiCaMsgrCore > /tmp/ReTiCAMsgr-meshtastic/t4-full.log 2>&1`. Expected: baseline + 38 passed, no failures. `textCarriesNoKeyMaterialFromAnyLayer` must still pass: the new layer renders no key material.

- [ ] **Step 7: Mutation batch (one run)**

Apply ALL, run the Step 6 filtered command once (log `t4-mut.log`). Expected: all 12 FAIL. Node and preset rows are not gated on `online`, so D4 cannot mask D5-D7. The offline reason is matched exactly, so D3 fails the offline test as well as the hostile one. Nothing in the batch can mask D3 in the hostile test (its state is offline, and D4 only touches the online check).

| # | Mutation (all in DiagnosticsSnapshot.swift) | Test that must fail |
|---|---|---|
| D1 | delete the `guard enabled else { … }` block (the disabled early return) | `meshDiagIsOffAndOkWhenDisabled` |
| D2 | delete the `guard radio != nil else { … }` block | `meshDiagWarnsWhenNoRadioIsChosen` |
| D3 | offline reason `"radio not connected"` becomes `"radio \(state.meshtasticRadioLabel) not connected"` | `meshDiagWarnsWhileTheRadioIsOffline`, `meshDiagAHostileRadioNameCannotForgeLines` |
| D4 | `guard status.online else {` becomes `guard false else {` | `meshDiagIsOkWhenOnline` |
| D5 | `String(format: "!%08x", num)` becomes `String(num)` | `meshDiagShowsTheNodeNumberInMeshtasticForm` |
| D6 | `6: "ShortFast"` becomes `6: "ShortSlow"` | `meshDiagNamesThePreset` |
| D7 | `?? "unknown (\(raw))"` becomes `?? "unknown"` | `meshDiagShowsAnUnknownPresetRaw` |
| D8 | delete the `if status.adapterUnavailable != nil { … }` block | `meshDiagAdapterUnavailableIsAProblem` |
| D9 | `case let .other(detail): return detail.map { "other: \($0)" } ?? "other"` becomes `case .other: return "other"` | `meshDiagShowsTheUninstalledDriverMessage` |
| D10 | delete `Row("send failed", String(counters.sendFailed)),` | `meshDiagRendersEveryCounter` |
| D11 | in `init(from:at:)`, move `Self.meshtasticLayer(state),` to after `Self.identityLayer(state),` | `snapshotHasAllLayersInOrder` |

D4 produces a "will never be executed" warning. That is expected for the mutation run.

- [ ] **Step 8: Revert by hand and re-run**

Revert with the Edit tool. `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic diff` must show only this task's intended changes. Re-run the Step 6 filtered command (log `t4-green2.log`): 12 passed.

- [ ] **Step 9: Commit**

```bash
git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/MeshtasticStatus.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/DiagnosticsSnapshot.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/DiagnosticsSnapshotTests.swift
```

Message file `/tmp/ReTiCAMsgr-meshtastic/msg-task-4.txt`:

```
feat: Meshtastic diagnostics layer over a plain status struct

MeshtasticStatus holds online, preset, node number, offline reason, adapter
cause and the reassembler and sender counters for lane E to fill. The new
layer sits after Bluetooth. It is ok when off, warns with no radio or offline,
and is a problem when the Bluetooth path is unavailable. It shows the
uninstalled driver message and keeps the advertised radio name out of the
unescaped reason.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

Run the commit and the trailer check as in Task 1 Step 8.

---

### Task 5: Settings section and the radio picker sheet (app target)

**Files:**
- Create: `WT/ReTiCaMsgr/RadioPickerView.swift`
- Modify: `WT/ReTiCaMsgr/SettingsView.swift` (new section after the Bluetooth section, which ends at line 154, and one `.sheet` after `.sheet(item: $editingNode)`, currently lines 296-298)

**Interfaces:**
- Consumes: `RadioPickerFeature` (State `radios`, `scanEnded`, `selectedID`, actions `onAppear`, `radioTapped`, `cancelTapped`, `scanEndedEmptyMessage`), `RadioScanResult.displayName` (Task 1). `meshtasticEnabled`, `meshtasticRadioLabel` (Task 2). `radioPicker`, `.chooseRadioTapped` (Task 3).
- Produces: `struct RadioPickerView: View { let store: StoreOf<RadioPickerFeature> }`.

No unit tests: SwiftUI views are checked by the app build and a simulator run (Step 5). All behaviour behind them is tested in Tasks 1-4. No test is new or changed, so the mutation rule does not apply to this task.

- [ ] **Step 1: Create `RadioPickerView.swift`**

```swift
//
//  RadioPickerView.swift
//  ReTiCaMsgr
//

import SwiftUI
import ComposableArchitecture
import ReTiCaMsgrCore

/// The "Choose radio" sheet (spec 2026-10-16 §7). All behaviour is in `RadioPickerFeature`. This
/// file renders. Every way out (swipe, Cancel, a pick) reaches `AppFeature` as
/// `.radioPicker(.dismiss)`, where paused Bluetooth resumes.
struct RadioPickerView: View {
    let store: StoreOf<RadioPickerFeature>

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.radios) { radio in
                        Button {
                            store.send(.radioTapped(radio.id))
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(radio.displayName)
                                    Text(radio.id.uuidString)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(radio.rssi) dBm")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if radio.id == store.selectedID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            // A `.plain` button hit-tests only its glyphs: make the whole row the target.
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    statusFooter
                }
            }
            .navigationTitle("Choose Radio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.send(.cancelTapped) }
                }
            }
            .onAppear { store.send(.onAppear) }
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        if !store.scanEnded {
            HStack(spacing: 8) {
                ProgressView()
                Text("Scanning for Meshtastic radios… Make sure the radio is on and not connected "
                     + "to another app.")
            }
        } else if store.radios.isEmpty {
            Text(RadioPickerFeature.scanEndedEmptyMessage)
                .foregroundStyle(.red)
        } else {
            Text("Scanning stopped.")
        }
    }
}

#Preview {
    // `\.radioScanner`'s previewValue lists three fake radios on an open scan.
    RadioPickerView(store: Store(initialState: RadioPickerFeature.State()) { RadioPickerFeature() })
}
```

- [ ] **Step 2: Settings section**

In `SettingsView.swift`, directly after the Bluetooth section's closing brace (the `}` closing `Section("Bluetooth") {`, currently line 154) and before `Section("Relay") {`, insert:

```swift
                Section {
                    // Standard Toggle in a Form row: the whole row is already hittable.
                    Toggle("Connect through a Meshtastic radio", isOn: $store.meshtasticEnabled)
                    LabeledContent("Radio", value: store.meshtasticRadioLabel)
                    // A standard Form button row is hittable across its width already.
                    Button("Choose radio…") { store.send(.chooseRadioTapped) }
                } header: {
                    Text("Meshtastic")
                } footer: {
                    Text("Sends and receives messages over LoRa through a Meshtastic radio paired with "
                         + "this device over Bluetooth. Set the radio to a Short preset (ShortTurbo or "
                         + "ShortFast): longer presets are too slow for most messages. The radio must not "
                         + "be connected to another app, such as the Meshtastic app, at the same time. "
                         + "Choosing a radio pauses Bluetooth connections to nearby devices until the list "
                         + "closes. Off by default. Takes effect on the next Connect.")
                }
```

After the modifier

```swift
            .sheet(item: $editingNode) { node in
                NodeFormView(store: store, existing: node)
            }
```

insert:

```swift
            // Driven by state: a swipe sends `.radioPicker(.dismiss)`, like Cancel and a pick.
            .sheet(item: $store.scope(state: \.radioPicker, action: \.radioPicker)) { pickerStore in
                RadioPickerView(store: pickerStore)
            }
```

- [ ] **Step 3: Build the app**

Run: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination "generic/platform=iOS Simulator" build > /tmp/ReTiCAMsgr-meshtastic/t5-build.log 2>&1`
Expected: `** BUILD SUCCEEDED **`. If it fails, `grep -n "error:" /tmp/ReTiCAMsgr-meshtastic/t5-build.log` and fix.

- [ ] **Step 4: Restore files Xcode rewrote**

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic status --short`. Expected: only `ReTiCaMsgr/RadioPickerView.swift` (untracked) and `ReTiCaMsgr/SettingsView.swift` (modified). Leave any `xcschememanagement.plist` change unstaged.

- [ ] **Step 5: Simulator check**

Load the `xcodebuildmcp-cli` skill. Boot an iOS 26.4 simulator (only 26.4 run destinations are valid with the active Xcode), then build and run `ReTiCaMsgr` from `WT/ReTiCaMsgr.xcodeproj` on it. Confirm and note what you see:
1. Settings shows a **Meshtastic** section after **Bluetooth** with the toggle, `Radio` / `None`, `Choose radio…`, and the footer copy.
2. The toggle survives a relaunch of the app (it is app storage).
3. `Choose radio…` opens **Choose Radio**. With the lane D stub scanner, the footer shows the red `Scanning stopped before any radio was found…` message (no endless spinner).
4. `Cancel` closes the sheet. Reopen it and swipe it down: it closes again, and reopening still works (proves the swipe sent `.dismiss` and the state was cleared).
The simulator has no Bluetooth LE, so BLE is never running there and the pause is not observable: it is covered by Task 3's tests. If no simulator can be booted, say so in the commit body instead of claiming the check.

- [ ] **Step 6: Commit**

```bash
git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic add ReTiCaMsgr/RadioPickerView.swift ReTiCaMsgr/SettingsView.swift
```

Message file `/tmp/ReTiCAMsgr-meshtastic/msg-task-5.txt` (replace the bracketed line with what Step 5 observed, as a plain sentence):

```
feat: Meshtastic section in Settings and the Choose Radio sheet

Toggle, the chosen radio's name or UUID, and Choose radio opening a
state-driven sheet whose rows are tappable across their full width. The
footer recommends ShortTurbo or ShortFast and says the radio must not be
connected to another app.

[Simulator check: what Step 5 showed, or why it could not run.]

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

Run the commit and the trailer check as in Task 1 Step 8.

---

### Task 6: Full verification, rebase onto app main, fast-forward main

**Files:** none changed (unless the rebase conflicts. Then stop, see Step 5).

- [ ] **Step 1: Full core suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic/ReTiCaMsgrCore > /tmp/ReTiCAMsgr-meshtastic/t6-core.log 2>&1`
Expected: baseline + 38 tests passed, no failures (11 T1 + 6 T2 + 10 T3 + 11 T4, plus the changed order test already in the baseline).

- [ ] **Step 2: App build**

Run: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination "generic/platform=iOS Simulator" build > /tmp/ReTiCAMsgr-meshtastic/t6-build.log 2>&1`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Hosted app tests**

Run: `xcodebuild test -project /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination "platform=iOS Simulator,name=iPhone 17" -only-testing:ReTiCaMsgrTests > /tmp/ReTiCAMsgr-meshtastic/t6-hosted.log 2>&1`
If no simulator named `iPhone 17` exists, run `xcrun simctl list devices available` once and use any iOS 26.4 iPhone's name. Expected: `** TEST SUCCEEDED **`. `TestHostScanTests` scans app sources for `launchEnvironment`, `RETICAMSGR_TEST_HOST` and `XCUIApplication(`. The new files contain none of them.

- [ ] **Step 4: Clean tree**

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic status --short`. Expected: empty, or only `xcschememanagement.plist` files, which you restore with `git -C WT checkout -- <path>`.

- [ ] **Step 5: Rebase onto app main**

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic rebase main`
Expected: `Successfully rebased` or `Current branch meshtastic-ui is up to date.` On a conflict, run `git -C WT rebase --abort` and STOP: report the conflicting files. Lane D owns only ReTiCaMsgr files, but other app work can touch `AppFeature.swift`, `SettingsView.swift` or `DiagnosticsSnapshot.swift`.

- [ ] **Step 6: Re-verify if main moved**

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic log --oneline main..meshtastic-ui`. Expected: exactly the five task commits. If Step 5 replayed them onto a newer main (its output said `Successfully rebased`), repeat Steps 1 and 2 on the rebased branch before going on, comparing against the new baseline. Running `swift test --package-path WT/ReTiCaMsgrCore` on `main`'s tip first gives that baseline.

- [ ] **Step 7: Main checkout is clean**

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr status --short`. If it lists modified tracked files, STOP and report: a fast-forward must not run over someone's uncommitted work.

- [ ] **Step 8: Fast-forward main**

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr merge --ff-only meshtastic-ui`
Expected: `Fast-forward`. If git refuses (`Not possible to fast-forward`), main moved after Step 5: go back to Step 5.

- [ ] **Step 9: Confirm**

Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr log --oneline -6`. Expected: the five task commits on top.
Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr log -5 --format='%(trailers:key=Claude-Session)'`. Expected: the session URL for each of the five commits.

Leave the worktree in place. Lane E rebases onto main, not onto this branch.

---

## Self-review (done at planning time)

- **Spec coverage (§7 lane D, §8 D):** `@Shared(.appStorage)` `meshtasticEnabled`/`meshtasticRadioID` next to `bleEnabled` (T2). Settings section after Bluetooth with toggle, radio row, "Choose radio…" (T5). Channel and hop limit fixed, so no setting (Global Constraints). `RadioScanner` client in ReTiCaMsgrCore with testValue, previewValue and a loud stub live value (T1). Full-width tappable rows (T5). Scan ownership, BLE stop on open and restart on dismiss, including swipe (T3). Diagnostics layer modelled on `bleLayer`, fed from a plain struct lane E populates (T4). TCA tests for toggle persistence (T2), picker selection (T1, T3), BLE pause/resume (T3). Pass, mutate, revert on every test task. No new ReTiCA symbol, no MeshtasticKit, no `syncEndpointNodes` wiring.
- **Placeholders:** none. The one bracketed line is in Task 5's commit message and is filled from the Step 5 observation.
- **Type consistency:** `RadioScanResult(id:name:rssi:)`, `RadioScanner(scan:)`, `RadioPickerFeature.State(selectedID:)`, `.radioFound`, `.radioTapped(UUID)`, `.cancelTapped`, `.onAppear`, `.scanFinished`, `.delegate(.selected(RadioScanResult))`, `scanEndedEmptyMessage`, `meshtasticRadioUUID`, `meshtasticRadioLabel`, `radioPicker`, `blePausedForRadioScan`, `bleIsRunning`, `MeshtasticSettingsReducer`, `MeshtasticStatus(online:modemPreset:myNodeNum:offlineReason:adapterUnavailable:counters:)`, `MeshtasticStatus.Counters(malformed:evicted:timedOut:oversize:completed:queueFull:sendFailed:)`, `meshtasticStatus`, `meshtasticLayer`. Each is used with the same spelling in every task that names it.
- **Review Focus:** each of the five lines names its pinning test in its owning task.
