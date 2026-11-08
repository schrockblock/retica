# RNode Lane C (ReTiCAMsgr UI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## Contract issues

Lane C references no RNode symbol from lanes A, B or D: Contracts 1–3 don't constrain it directly, and it can merge before RNode lane B is on ReTiCA `main`. Two consequences, recorded so nobody reads them as divergence:

1. **The app validates radio parameters with its own type.** `RNodeRadioSettings` holds the user's values and RNS's input ranges (spec §6). Lane D maps it into ReTiCA's `RNodeLoRaParams`; neither ReTiCA nor the kit range-checks (spec §10 item 29).
2. **`RNodeStatus` uses app-local value types** (`RNodeStatus.Params`, `RNodeStatus.Counters`) rather than `RNodeRadioReport`, `RNodeCounters` or `RNodeTelemetry`. Lane D's Task 9 maps them.

**Goal:** Give ReTiCAMsgr everything an RNode needs on the app side except the live wiring: a third radio-picker kind, persisted and validated radio parameters, a Settings section with board and pairing guidance, a Diagnostics layer, and the Release gate.

**Architecture:** All in the ReTiCAMsgr app repo, after MeshCore lane D. `RadioKind` gains `.rnode` and `RadioScanner` a third closure whose default finishes at once, so existing tests compile unchanged. Settings live in `@Shared(.appStorage)`; `RNodeRadioSettings` turns them into a value with a list of problems. Everything gated reads `AppFeature.State.rnodeAvailable`, plus `#if DEBUG` around the view section and its copy, the `MeshCoreReleaseGate` pattern.

**Tech Stack:** Swift 6 (tools 6.0), SwiftUI, TCA (`@Reducer`, `@Presents`, `TestStore`), swift-sharing (`@Shared(.appStorage)`, `UserDefaults.inMemory`), Swift Testing.

**Spec:** `/Users/ell/development/ios/pods/ReTiCA-worktrees/meshcore-interface/docs/superpowers/specs/2026-11-08-rnode-ble-interface-design.md`: §6 "App" (lane C's half), §7, §8 C. Precedent: `2026-11-07-meshcore-lane-c-app-ui.md` in this `plans/` directory, and the MeshCore code it produced on `apps/ReTiCAMsgr` `main` (`MeshCoreReleaseGate.swift`, `AppFeature+MeshCore.swift`, `MeshCoreStatus.swift`, `MeshCoreCopy.swift`, `DiagnosticsSnapshot.swift:312-390`, `SettingsView.swift:506-563`).

## Global Constraints

- **Paths.** `A` = `/Users/ell/development/ios/apps/ReTiCAMsgr-rnode`, branch `feat/rnode-ui`. `CORE` = `A/ReTiCAMsgrCore`. `MAIN` = `/Users/ell/development/ios/apps/ReTiCAMsgr`. The worktree must be a sibling of the app directory (`CORE/Package.swift` resolves `../../../pods/...`). Temp files: `/tmp/ReTiCaMsgr/lane-rnode-c/`. Expand shorthand in every command.
- **Starts only after MeshCore lane D Part 2 is on `main`** (spec §6). Task 0 gates it.
- **Boundaries.** ReTiCAMsgr files only. Never edit anything under `pods/`. Never reference `TransportEndpoint.State.rnode`, `RNodeEndpoint`, `RNodeDriver`, `RNodeInterface`, `RNodeLoRaParams`, `RNodeCounters`, `RNodeTelemetry` or `rnodeInterfaceID`, and never import RNodeKit or `ReTiCARNodeLive`. Don't touch `syncEndpointNodes`, `redialDownNodes`, `somethingWillDial`, `isLoRaRadio`, `profilePhotoMayRide` or `radioDownAnnounceTargets`: lane D owns them. Don't edit Meshtastic or MeshCore code beyond the shared picker sites named in Tasks 1 and 3.
- **Commits and merges.** One commit per task on `feat/rnode-ui`. No pushing, no merging; a person approves the merge (spec §6, step 5). Stage explicit paths; never `xcuserdata/**`, `.swiftpm/**`, `default.profraw` or `Package.resolved`. Message via the Write tool to `/tmp/ReTiCaMsgr/lane-rnode-c/msg-tN.txt`, `git -C <A> commit -F <file>`, attribution lines from the executing session's system reminder at column zero.
- **Shell (user rule).** One command per line, per Bash call. No `|`, `&&`, `||`, `;`, `$(...)`, backticks, `xargs`, heredocs into interpreters or inline scripts. Scripts in files under the temp folder. Redirecting one command's output to a log is allowed.
- **Core test command.** `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-rnode/ReTiCAMsgrCore --filter <prefix> > /tmp/ReTiCaMsgr/lane-rnode-c/<name>.log 2>&1`, timeout 600000 ms. The log ends `Test run with N tests ... passed` or `... failed`. Never run `swift test` and `xcodebuild` at once. Known flake: `deliveryFailedMarksFailedAndReloads` alone under `--filter`. Signal 10/11 or stale links: `swift package --package-path <CORE> clean`, retry. ENOSPC: delete `~/Library/Developer/Xcode/DerivedData`, retry once.
- **App build commands.** iOS: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-rnode/ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -destination "generic/platform=iOS Simulator" build > /tmp/ReTiCaMsgr/lane-rnode-c/<name>.log 2>&1`. Mac: `-destination "platform=macOS"`. Expected `** BUILD SUCCEEDED **`. Then `git -C <A> status --short`; restore a rewritten `xcschememanagement.plist` with `git -C <A> checkout -- <path>` (the only `git checkout --` allowed).
- **Test verification (user rule), every task with tests:** (a) run the filter, all pass. (b) `cp` each production file in the mutation table to `/tmp/ReTiCaMsgr/lane-rnode-c/<name>.orig`, apply the **whole table in one batch**, run once, confirm **every** new test fails. A second batch only where the table says a mutation masks another. If one passes, fix it and restart at (a). (c) Restore with `cp`, `git -C <A> diff --stat` lists only intended files, run, all pass. Then commit. Stop and diagnose anything unexpected.
- **TCA test rules.** Free `@MainActor @Test func`s; `exhaustivity = .off` unless a test claims "nothing happens". Tests touching `@Shared(.appStorage)` build state inside `withDependencies { $0.defaultAppStorage = defaults }` with a fresh `UserDefaults.inMemory`. Read `@Shared` values into locals before mutating `state.node…`. No `store.finish()` while a picker is presented.
- **Test names** start with their task's prefix: `rnPicker` (T1), `rnSettings` (T2), `rnFlow` (T3), `rnDiag` (T4), `rnCopy` (T5). No existing test matches `func rn[A-Z]` (checked 2026-11-08). Existing tests stay untouched, except `snapshotHasAllLayersInOrder` (T4, one expected-list line).
- **Tappable rows.** Any custom tappable row's label ends with `.frame(maxWidth: .infinity, alignment: .leading)` then `.contentShape(Rectangle())`. `RadioPickerView` rows keep theirs.
- **Copy says "this app"** and "this device", never the app's name.
- **Spec values (verbatim).** Keys and defaults: `rnodeEnabled` false, `rnodeRadioID` nil, `rnodeRadioName` nil, `rnodeFrequencyHz` nil, `rnodeBandwidthHz` 62500, `rnodeSpreadingFactor` 8, `rnodeCodingRate` 6, `rnodeTXPowerDBm` 0. Ranges: frequency 137_000_000...3_000_000_000 Hz, bandwidth 7_800...1_625_000 Hz, SF 5...12, CR 5...8, TX power 0...37 dBm.

**Release gate: `#if DEBUG`,** four sites, as MeshCore's: `RNodeReleaseGate.isCompiledIn`, the `SettingsView` section, `enum RNodeCopy`, and the section's private views. Lane E's last commit removes them.

## Review Focus

1. **Frequency typed with a comma, a unit or stray spaces** (`868,1`, `868.1 MHz`, ` 868.1 `, `868.1000001`, `1e9`). Expected: surrounding whitespace is fine, the rest reads as unreadable with a message, and nothing dials. → T2 `rnSettingsFrequencyTextRejects` (parameterised), `rnSettingsFrequencyTextAcceptsSurroundingWhitespace`.
2. **Defaults restored from a backup or left by a Debug build** (`rnodeEnabled` true, no frequency, or SF 13 in defaults). Expected: nothing dials, the toggle can still be turned off. → T2 `rnSettingsStaleDefaultsWithoutAFrequencyWillNotDial`, `rnSettingsOutOfRangeStoredValueWillNotDial`.
3. **An RNode pick written to MeshCore's keys or the reverse** (they share a service UUID). → T3 `rnFlowPickLeavesTheMeshCoreRadioAlone`, `rnFlowMeshCorePickLeavesTheRNodeAlone`.
4. **A hostile advertised name** (`RNode \n[ok]`) forging Diagnostics lines. Expected: escaped in rows, never in a reason. → T4 `rnDiagAHostileRadioNameCannotForgeLines`.
5. **Settings edited while connected.** Expected: nothing reaches the running radio until the next Connect (lane D swaps then). Lane C proves its half: editing only writes defaults and sends no endpoint action. → T2 `rnSettingsEditingSendsNoEndpointAction` (exhaustive).

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `CORE/Sources/ReTiCAMsgrCore/RadioScanner.swift` | modify | `RadioKind.rnode`, `scanRNode`, `stream(for:)` |
| `CORE/Sources/ReTiCAMsgrCore/RadioPickerFeature.swift` | modify | RNode footer messages |
| `CORE/Sources/ReTiCAMsgrCore/RNodeReleaseGate.swift` | create | the one `#if DEBUG` value logic reads |
| `CORE/Sources/ReTiCAMsgrCore/RNodeRadioSettings.swift` | create | value, ranges, problems, text parsing and formatting |
| `CORE/Sources/ReTiCAMsgrCore/AppFeature+RNode.swift` | create | state helpers, `RNodeSettingsReducer` |
| `CORE/Sources/ReTiCAMsgrCore/AppFeature.swift` | modify | settings keys, `rnodeAvailable`, `rnodeStatus`, text problems, actions, composition |
| `CORE/Sources/ReTiCAMsgrCore/AppFeature+Meshtastic.swift` | modify | picker arms for `.rnode` |
| `CORE/Sources/ReTiCAMsgrCore/RNodeStatus.swift` | create | plain status for Diagnostics and Settings |
| `CORE/Sources/ReTiCAMsgrCore/DiagnosticsSnapshot.swift` | modify | `rnodeLayer` |
| `CORE/Sources/ReTiCAMsgrCore/RNodeCopy.swift` | create | verbatim copy, `#if DEBUG` |
| `A/ReTiCAMsgr/SettingsView.swift` | modify | RNode section |
| `A/ReTiCAMsgr/RadioPickerView.swift` | modify | an RNode `#Preview` |
| `CORE/Tests/ReTiCAMsgrCoreTests/RNodeTestSupport.swift` | create | `rnStore`, fixtures |
| `CORE/Tests/ReTiCAMsgrCoreTests/RNodeSettingsTests.swift` | create | T1, T2 |
| `CORE/Tests/ReTiCAMsgrCoreTests/RNodePickerFlowTests.swift` | create | T3 |
| `CORE/Tests/ReTiCAMsgrCoreTests/DiagnosticsSnapshotTests.swift` | modify | T4 |
| `CORE/Tests/ReTiCAMsgrCoreTests/RNodeCopyTests.swift` | create | T5 |

`AppFeature.swift` line numbers move with MeshCore lane D; re-find each site by text: the MeshCore `@Shared` settings block (`meshCoreEnabled`), `meshCoreAvailable`, `meshCoreStatus`, `case chooseMeshCoreRadioTapped`, the no-op arm listing `.chooseMeshCoreRadioTapped`, and the composition list (`MeshCoreSettingsReducer()`).

---

### Task 0: Gate, worktree, baseline

**Files:** none changed.

- [ ] **Step 1: Gate.** Stop and report if either count is 0:
  - `grep -c "MeshCoreRadioReducer" /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift`
  - `grep -c "meshCoreResults" /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/RadioScanner.swift`
- [ ] **Step 2: Worktree.** `git -C /Users/ell/development/ios/apps/ReTiCAMsgr worktree add /Users/ell/development/ios/apps/ReTiCAMsgr-rnode -b feat/rnode-ui main`
- [ ] **Step 3:** `mkdir -p /tmp/ReTiCaMsgr/lane-rnode-c`
- [ ] **Step 4: Baselines.** Core test command, no filter, log `t0-core.log`, record N in `/tmp/ReTiCaMsgr/lane-rnode-c/baseline.txt`. iOS build `t0-ios.log`, Mac build `t0-mac.log`. Any failure: stop.
- [ ] **Step 5:** `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-rnode status --short`: empty after restoring any scheme plist.

---

### Task 1: A third radio kind

**Files:**
- Modify: `CORE/Sources/ReTiCAMsgrCore/RadioScanner.swift`, `RadioPickerFeature.swift`, `A/ReTiCAMsgr/RadioPickerView.swift`
- Create: `CORE/Tests/ReTiCAMsgrCoreTests/RNodeTestSupport.swift`, `RNodeSettingsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `RadioKind.rnode` (raw value `"rnode"`).
  - `RadioScanner.scanRNode: @Sendable () -> AsyncStream<RadioScanResult>`, an `init` parameter defaulting to a stream that finishes at once, placed after `scanMeshCore` so existing call sites compile; `stream(for: .rnode)` returns it. `testValue`: `unimplemented("RadioScanner.scanRNode", …)`. `previewValue`: radios `RNode 1A2B`, `RNode C3D4`, one unnamed.
  - `RadioPickerFeature.State` messages for `.rnode` (below).
  - Test support: `rnRadioA: RadioScanResult` (`RNode 1A2B`), `rnStore(defaults:scanner:configure:) -> TestStoreOf<AppFeature>`, built like `mcStore` in `MeshCoreTestSupport.swift`.

- [ ] **Step 1: Write the failing tests** in `RNodeSettingsTests.swift`:

```swift
@MainActor @Test func rnPickerRNodeScanUsesScanRNode()
  // counts per closure; .onAppear on State(kind: .rnode): rnodeScans == 1, meshCoreScans == 0, meshtasticScans == 0
@MainActor @Test func rnPickerUninstalledRNodeScannerEndsTheScan()   // RadioScanner.liveValue, kind .rnode: receive .scanFinished
@Test func rnPickerRNodeMessagesNameTheBoards()
  // State(kind: .rnode).scanningMessage == "Scanning for RNodes… Only RNodes with Bluetooth LE appear. Make sure the radio is on, its Bluetooth is on, and it isn't connected to another app."
  // State(kind: .rnode).scanEndedEmptyMessage == "Scanning stopped before any radio was found. RNode support may not be installed in this build, or Bluetooth may be off or not allowed."
@Test func rnPickerOtherKindsMessagesAreUnchanged()   // .meshtastic and .meshCore strings equal today's
```

- [ ] **Step 2: Fail,** `--filter rnPicker`, log `t1-red.log`. Expected: compile errors naming `.rnode`, `scanRNode`.
- [ ] **Step 3: Implement.** Switch `scanningMessage` to a `switch kind`, keeping the two existing strings byte for byte. Add a third `#Preview` with `State(kind: .rnode)`.
- [ ] **Step 4: Green with the old picker tests:** `--filter rnPicker --filter mcPicker --filter radioPicker --filter meshPickerFlow --filter meshLiveScan --filter mcLiveScan`, log `t1-green.log`, no edits to existing test files.
- [ ] **Step 5: Mutation batch.** `stream(for: .rnode)` returns `scanMeshCore()`; the RNode scanning string drops "Only RNodes with Bluetooth LE appear."; the MeshCore branch returns the RNode string. Batch 2: `liveValue`'s `scanRNode` never finishes → `rnPickerUninstalledRNodeScannerEndsTheScan` fails.
- [ ] **Step 6: Restore, re-run Step 4, all pass. Step 7: Commit.** Subject: `feat: radio picker gains an RNode kind`.

---

### Task 2: Persisted radio settings, validation, the gate value

**Files:**
- Create: `CORE/Sources/ReTiCAMsgrCore/RNodeReleaseGate.swift`, `RNodeRadioSettings.swift`, `AppFeature+RNode.swift`
- Modify: `CORE/Sources/ReTiCAMsgrCore/AppFeature.swift`, `CORE/Tests/ReTiCAMsgrCoreTests/RNodeSettingsTests.swift`

**Interfaces:**
- Consumes: nothing from T1.
- Produces:

```swift
public enum RNodeReleaseGate { public static var isCompiledIn: Bool }   // true under #if DEBUG
public enum RNodeSettingsProblem: Equatable, Sendable {
    case frequencyMissing, frequencyUnreadable, frequencyOutOfRange
    case bandwidthUnreadable, bandwidthOutOfRange
    case spreadingFactorOutOfRange, codingRateOutOfRange, txPowerOutOfRange
}
public struct RNodeRadioSettings: Equatable, Sendable {
    public var frequencyHz: Int?; public var bandwidthHz: Int
    public var spreadingFactor: Int; public var codingRate: Int; public var txPowerDBm: Int
    public static let frequencyRange: ClosedRange<Int>, bandwidthRange, spreadingFactorRange, codingRateRange, txPowerRange
    public var problems: [RNodeSettingsProblem] { get }     // range problems, in field order
    public static func parseMegahertz(_ text: String) -> Int?   // trims whitespace; digits, optional "." and ≤ 6 decimals
    public static func parseKilohertz(_ text: String) -> Int?   // the same, ≤ 3 decimals
    public static func megahertzText(_ hz: Int) -> String       // 868_100_000 → "868.1"; trailing zeros dropped
    public static func kilohertzText(_ hz: Int) -> String       // 62_500 → "62.5"; 125_000 → "125"
}
// AppFeature.State
@Shared(.appStorage("rnodeEnabled")) var rnodeEnabled: Bool = false
@Shared(.appStorage("rnodeRadioID")) var rnodeRadioID: String?
@Shared(.appStorage("rnodeRadioName")) var rnodeRadioName: String?
@Shared(.appStorage("rnodeFrequencyHz")) var rnodeFrequencyHz: Int?
@Shared(.appStorage("rnodeBandwidthHz")) var rnodeBandwidthHz: Int = 62_500
@Shared(.appStorage("rnodeSpreadingFactor")) var rnodeSpreadingFactor: Int = 8
@Shared(.appStorage("rnodeCodingRate")) var rnodeCodingRate: Int = 6
@Shared(.appStorage("rnodeTXPowerDBm")) var rnodeTXPowerDBm: Int = 0
public var rnodeAvailable = RNodeReleaseGate.isCompiledIn
public var rnodeTextProblems: [RNodeSettingsProblem] = []        // session-only: unreadable text
// AppFeature.Action
case rnodeFrequencyTextChanged(String), rnodeBandwidthTextChanged(String)
case rnodeSpreadingFactorChanged(Int), rnodeCodingRateChanged(Int), rnodeTXPowerChanged(Int)
extension AppFeature.State {
    public var rnodeRadioUUID: UUID? { get }
    public var rnodeRadioLabel: String { get }               // name, else UUID, else "None"
    public var rnodeSettings: RNodeRadioSettings { get }
    public var rnodeSettingsProblems: [RNodeSettingsProblem] { get }   // text problems first, then range problems
    var rnodeWillDial: Bool { get }   // rnodeAvailable && rnodeEnabled && rnodeRadioUUID != nil && rnodeSettingsProblems.isEmpty
}
struct RNodeSettingsReducer: Reducer   // composed after MeshCoreSettingsReducer
```

**Reducer rules.** `rnodeFrequencyTextChanged(t)`: `parseMegahertz(t)` → store it and drop the frequency text problem; nil and `t` blank → store nil and drop it (the `.frequencyMissing` range problem then shows); nil otherwise → store nil and add `.frequencyUnreadable`. Bandwidth the same, except unreadable keeps the stored value and adds `.bandwidthUnreadable`; blank also counts as unreadable. The three integer actions store their value as given (the view's steppers bound them; stale values are caught by `problems`). `problems` reports `.frequencyMissing` when `frequencyHz == nil`. No arm returns an effect.

- [ ] **Step 1: Write the failing tests:**

```swift
rnSettingsDefaultsAreSidebands                     // frequency nil, 62_500, 8, 6, 0; enabled false
rnSettingsEachValuePersists                        // each action → value read back from a fresh state on the same defaults
rnSettingsDefaultsAreMissingOnlyTheFrequency       // problems == [.frequencyMissing]
@Test(arguments: [(136_999_999, true), (137_000_000, false), (3_000_000_000, false), (3_000_000_001, true)])
rnSettingsFrequencyBoundaries                      // .frequencyOutOfRange present iff flagged
@Test(arguments: [(7_799, true), (7_800, false), (1_625_000, false), (1_625_001, true)]) rnSettingsBandwidthBoundaries
@Test(arguments: [(4, true), (5, false), (12, false), (13, true)]) rnSettingsSpreadingFactorBoundaries
@Test(arguments: [(4, true), (5, false), (8, false), (9, true)]) rnSettingsCodingRateBoundaries
@Test(arguments: [(-1, true), (0, false), (37, false), (38, true)]) rnSettingsTXPowerBoundaries
rnSettingsProblemsAreInFieldOrder                  // all bad: [frequencyOutOfRange, bandwidthOutOfRange, spreadingFactor…, codingRate…, txPower…]
rnSettingsFrequencyTextParses                      // "868.1" → 868_100_000; "433.775" → 433_775_000; "915" → 915_000_000; "868.000001" → 868_000_001
rnSettingsFrequencyTextAcceptsSurroundingWhitespace   // " 868.1\n" → 868_100_000
@Test(arguments: ["868,1", "868.1 MHz", "868.1000001", "1e9", "-868", "", ".", "868."]) rnSettingsFrequencyTextRejects   // parseMegahertz == nil
rnSettingsBandwidthTextParses                      // "62.5" → 62_500; "7.8" → 7_800; "125" → 125_000; "31.25" → 31_250
rnSettingsTextFormatsRoundTrip                     // megahertzText(868_100_000) == "868.1"; kilohertzText(62_500) == "62.5"; kilohertzText(125_000) == "125"
@MainActor rnSettingsUnreadableFrequencyIsReported // send .rnodeFrequencyTextChanged("abc"): rnodeSettingsProblems.first == .frequencyUnreadable; rnodeFrequencyHz == nil
@MainActor rnSettingsBlankFrequencyIsMissingNotUnreadable   // "" → [.frequencyMissing]
@MainActor rnSettingsUnreadableBandwidthKeepsTheStoredValue // "x": rnodeBandwidthHz == 62_500, problems contain .bandwidthUnreadable
@MainActor rnSettingsAGoodEntryClearsTheTextProblem         // "abc" then "868.1": rnodeSettingsProblems == []
@MainActor rnSettingsWillDialNeedsEveryCondition   // table: gate off / disabled / no radio / no frequency / a problem → false; all set → true
@MainActor rnSettingsStaleDefaultsWithoutAFrequencyWillNotDial   // defaults: enabled true, radio set, no frequency → !rnodeWillDial
@MainActor rnSettingsOutOfRangeStoredValueWillNotDial            // defaults SF 13 → !rnodeWillDial
@MainActor rnSettingsBadRadioIDReadsAsNoRadio      // rnodeRadioID "not-a-uuid" → rnodeRadioUUID nil, label "None"
@MainActor rnSettingsEditingSendsNoEndpointAction  // exhaustive store: each of the five actions changes state only; no received actions
@Test func rnSettingsGateIsOnInDebug               // RNodeReleaseGate.isCompiledIn == true
```

- [ ] **Step 2: Fail,** `--filter rnSettings`, log `t2-red.log`. **Step 3: Implement.** **Step 4: Green,** with `--filter mcSettings --filter meshSettings`, log `t2-green.log`.
- [ ] **Step 5: Mutation batch.**

| # | Mutation | Must fail |
|---|---|---|
| S1 | frequency range upper bound `2_999_999_999` | `rnSettingsFrequencyBoundaries` |
| S2 | bandwidth lower bound `7_801` | `rnSettingsBandwidthBoundaries` |
| S3 | SF range `5...11`; CR range `4...8`; TX `0...36` | the three boundary tests |
| S4 | `parseMegahertz` doesn't trim | `rnSettingsFrequencyTextAcceptsSurroundingWhitespace` |
| S5 | `parseMegahertz` accepts "," and up to 7 decimals | `rnSettingsFrequencyTextRejects` |
| S6 | Hz computed through `Double` multiplication without rounding (868.1 → 868_099_999) | `rnSettingsFrequencyTextParses` |
| S7 | unreadable text stores nothing and adds no problem | `rnSettingsUnreadableFrequencyIsReported`, `rnSettingsUnreadableBandwidthKeepsTheStoredValue` |
| S8 | blank frequency adds `.frequencyUnreadable` | `rnSettingsBlankFrequencyIsMissingNotUnreadable` |
| S9 | text problem never cleared | `rnSettingsAGoodEntryClearsTheTextProblem` |
| S10 | `rnodeWillDial` drops `rnodeAvailable`; then drops the problems check | `rnSettingsWillDialNeedsEveryCondition`, `rnSettingsStaleDefaultsWithoutAFrequencyWillNotDial`, `rnSettingsOutOfRangeStoredValueWillNotDial` |
| S11 | `problems` omits `.frequencyMissing` | `rnSettingsDefaultsAreMissingOnlyTheFrequency` |
| S12 | default SF 7 | `rnSettingsDefaultsAreSidebands` |
| S13 | an action arm returns `.send(.connectTapped)` | `rnSettingsEditingSendsNoEndpointAction` |

- [ ] **Step 6: Restore, re-run, all pass. Step 7: Commit.** Subject: `feat: persisted RNode radio settings with RNS's input ranges and the Release gate value`.

---

### Task 3: Picker flow for RNode

**Files:**
- Modify: `CORE/Sources/ReTiCAMsgrCore/AppFeature+Meshtastic.swift` (the `MeshtasticSettingsReducer` picker arms), `AppFeature.swift` (action, no-op arm)
- Create: `CORE/Tests/ReTiCAMsgrCoreTests/RNodePickerFlowTests.swift`

**Interfaces:**
- Consumes: T1, T2; `openRadioPicker(_:kind:selected:)`.
- Produces: `AppFeature.Action.chooseRNodeRadioTapped`, handled beside `.chooseMeshCoreRadioTapped`: `guard state.rnodeAvailable`, then `openRadioPicker(&state, kind: .rnode, selected: state.rnodeRadioUUID)`. The `.selected` arm gains `case .rnode:` writing `rnodeRadioID` and `rnodeRadioName`.

- [ ] **Step 1: Write the failing tests:**

```swift
rnFlowChooseOpensTheRNodePicker              // radioPicker?.kind == .rnode, selectedID == stored radio
rnFlowChooseDoesNothingWithTheGateOff        // rnodeAvailable false: radioPicker nil
rnFlowPickStoresTheRNode                     // rnodeRadioID == rnRadioA.id.uuidString, name "RNode 1A2B"
rnFlowPickLeavesTheMeshCoreRadioAlone        // MeshCore keys unchanged
rnFlowMeshCorePickLeavesTheRNodeAlone
rnFlowPickLeavesTheMeshtasticRadioAlone
rnFlowChoosePausesARunningBLE                // .ble(.stop) sent, blePausedForRadioScan
rnFlowDismissResumesBLE
rnFlowForegroundWhileOpenKeepsBLEPaused
rnFlowSecondChooseWhileOpenDoesNothing
```

- [ ] **Step 2: Fail,** `--filter rnFlow`, log `t3-red.log`. **Step 3: Implement. Step 4: Green,** with `--filter mcFlow --filter meshPickerFlow`, log `t3-green.log`.
- [ ] **Step 5: Mutation batch.** No gate check; kind `.meshCore`; the `.rnode` case writes MeshCore's keys; `openRadioPicker` bypassed (no BLE pause). Each named test fails.
- [ ] **Step 6: Restore, re-run, all pass. Step 7: Commit.** Subject: `feat: open the radio picker for RNodes, pausing BLE as the other radios do`.

---

### Task 4: `RNodeStatus` and the Diagnostics layer

**Files:**
- Create: `CORE/Sources/ReTiCAMsgrCore/RNodeStatus.swift`
- Modify: `AppFeature.swift` (`rnodeStatus`), `DiagnosticsSnapshot.swift`, `CORE/Tests/ReTiCAMsgrCoreTests/DiagnosticsSnapshotTests.swift`

**Interfaces:**
- Produces:

```swift
public struct RNodeStatus: Equatable, Sendable {
    public struct Params: Equatable, Sendable { public var frequencyHz, bandwidthHz, spreadingFactor, codingRate, txPowerDBm: Int }
    public struct Counters: Equatable, Sendable { public var received, sent, oversize, queueFull, sendFailed, hardwareErrors: Int }  // + and +=
    public var online: Bool
    public var radioName: String?          // unauthenticated: rows only
    public var firmware: String?           // "1.86"
    public var platform: UInt8?
    public var reported: Params?
    public var bitrate: Int?
    public var offlineReason: String?
    public var adapterUnavailable: BLEAdapterUnavailable?
    public var lastRSSI: Int?; public var lastSNR: Double?
    public var channelLoadShort: Double?; public var channelLoadLong: Double?
    public var airtimeShort: Double?; public var airtimeLong: Double?
    public var noiseFloor: Int?; public var lastHardwareError: UInt8?
    public var counters: Counters
    public var userMessage: String? { get }   // MeshCoreStatus.userMessage's wording for each cause
}
// AppFeature.State: public var rnodeStatus = RNodeStatus()
static func DiagnosticsSnapshot.rnodeLayer(_ state: AppFeature.State) -> Layer
```

**Layer rows,** in order, title `RNode`: `rnode` on/off. Off: return `.ok`, no reason. On: `settings` (`describe(settings)`, or `incomplete`), `radio` (label or `(none chosen)`), `radio id`, `status` online/offline, `radio name` (or `unknown`), `firmware` (or `unknown`), `platform` (`ESP32` for 0x80, `nRF52` for 0x70, `unknown (0xNN)`, or `unknown`), `reported` (`describe(params)` or `unknown`), `bitrate` (`1302 bps` or `unknown`), `last RSSI` (`-97 dBm`), `last SNR` (`6.25 dB`), `channel load` (`2.15% / 0.80%` short / long), `airtime` (same format), `noise floor` (`-117 dBm`); each of the last six `unknown` when nil; `offline reason` and `adapter` only when set; `last hardware error` only when set (`01` radio init failed, `02` transmit failed, `03` EEPROM locked, `04` queue full, `05` memory low, `06` modem timeout, else `code 0xNN`); then `received`, `sent`, `oversize`, `queue full`, `send failed`, `hardware errors`. `describe(params)` = `868.1 MHz / 62.5 kHz / SF8 / CR6 / 0 dBm`, using T2's text formatters. Health, first match: settings problems → `.warn`, reason `radio settings incomplete — set them in Settings`; then the shared `radioLinkLayer`. The layer is added after MeshCore's, only when `rnodeAvailable`.

- [ ] **Step 1: Write the failing tests** (append to `DiagnosticsSnapshotTests.swift`; change only the expected list in `snapshotHasAllLayersInOrder` to add `RNode` after `MeshCore`):

```swift
rnDiagOffIsOkWithOneRow
rnDiagIncompleteSettingsWarn                    // no frequency: .warn, reason "radio settings incomplete — set them in Settings"
rnDiagNoRadioWarns                              // complete settings, no radio: "no radio chosen — choose one in Settings"
rnDiagOfflineWarns                              // "radio not connected"
rnDiagAdapterUnavailableIsAProblem
rnDiagOnlineIsOk
rnDiagRowsShowTheSettingsAndTheReport           // settings and reported rows equal "868.1 MHz / 62.5 kHz / SF8 / CR6 / 0 dBm"
rnDiagRowsShowTelemetry                         // -97 dBm, 6.25 dB, "2.15% / 0.80%", -117 dBm, "1302 bps"
rnDiagPlatformNames                             // 0x80 ESP32, 0x70 nRF52, 0x90 "unknown (0x90)"
rnDiagHardwareErrorNames                        // 0x02 "transmit failed", 0x42 "code 0x42"
rnDiagCountersAreListed                         // all six
rnDiagLayerIsAbsentWithTheGateOff
rnDiagAHostileRadioNameCannotForgeLines         // radio name "RNode \n[ok] x": text has no line starting "[ok] x"
rnDiagUserMessageForEachCause                   // .poweredOff, .unauthorized, .unsupported, .other("x") → the MeshCoreStatus sentences / "x"
```

- [ ] **Step 2: Fail,** `--filter rnDiag --filter snapshotHasAllLayersInOrder`, log `t4-red.log`. **Step 3: Implement. Step 4: Green,** with `--filter mcDiag --filter meshDiag`, log `t4-green.log`.
- [ ] **Step 5: Mutation batch.** Settings check removed from health; layer added without the gate check; platform 0x70 named `ESP32`; percent format with one decimal; RSSI rendered without the sign; radio name put in the reason; `userMessage` returns nil for `.other`. Each named test fails.
- [ ] **Step 6: Restore, re-run, all pass. Step 7: Commit.** Subject: `feat: RNode status and Diagnostics layer`.

---

### Task 5: Settings section and copy

**Files:**
- Create: `CORE/Sources/ReTiCAMsgrCore/RNodeCopy.swift`, `CORE/Tests/ReTiCAMsgrCoreTests/RNodeCopyTests.swift`
- Modify: `A/ReTiCAMsgr/SettingsView.swift` (an `#if DEBUG rnodeSection #endif` after `meshCoreSection`), `AppFeature.swift` composition (add `RNodeSettingsReducer()` after `MeshCoreSettingsReducer()` if Task 2 didn't)

**Interfaces:**
- Consumes: T2–T4.
- Produces: `public enum RNodeCopy` under `#if DEBUG`, every string below verbatim, plus `all: [String]` and `func problemMessage(_ p: RNodeSettingsProblem) -> String`.

| Constant | Text |
|---|---|
| `header` | `RNode` |
| `toggle` | `Connect through an RNode` |
| `radioRow`, `chooseRadio` | `Radio`; `Choose radio…` |
| `frequencyRow`, `frequencyPrompt` | `Frequency (MHz)`; `Required, e.g. 868.1` |
| `bandwidthRow` | `Bandwidth (kHz)` |
| `spreadingFactorRow`, `codingRateRow`, `txPowerRow` | `Spreading factor`; `Coding rate`; `TX power (dBm)` |
| `incompleteNotice` | `Enter a frequency to turn this on.` |
| problem messages | frequencyMissing: `Enter a frequency.` frequencyUnreadable: `Enter the frequency in MHz, like 868.1.` frequencyOutOfRange: `Enter a frequency between 137 and 3000 MHz.` bandwidthUnreadable: `Enter the bandwidth in kHz, like 62.5.` bandwidthOutOfRange: `Enter a bandwidth between 7.8 and 1625 kHz.` spreadingFactorOutOfRange: `Use a spreading factor from 5 to 12.` codingRateOutOfRange: `Use a coding rate from 5 to 8.` txPowerOutOfRange: `Use a TX power from 0 to 37 dBm. Your radio may allow less.` |
| `boardsNotice` | `Works with RNodes that have Bluetooth LE: Heltec V3 and V4, LilyGO T3S3, T-Deck and T-Beam Supreme, Seeed XIAO S3, RAK4631, LilyGO T-Echo and Heltec T114. RNodes with only Classic Bluetooth, such as the original T-Beam, LoRa32, Heltec V2 and RNode NG, can't connect to this device.` |
| `pairingNotice` | `To pair, hold the RNode's button for 5 to 10 seconds until it shows a PIN, then tap Connect and enter that PIN when asked. The RNode drops the connection once after pairing, and this app reconnects by itself. An RNode without a screen can't show its PIN here.` |
| `footer` | `Sends and receives messages over LoRa through an RNode paired with this device over Bluetooth. This app sets the radio's frequency, bandwidth, spreading factor, coding rate and TX power every time it connects. Everyone you want to reach must use the same frequency, bandwidth, spreading factor and coding rate. You're responsible for using settings that are legal where you are. The radio must not be connected to another app, such as Sideband, at the same time. Choosing a radio pauses Bluetooth connections to nearby devices until the list closes. Off by default. Changes take effect on the next Connect.` |

**Section layout** (rows in order): toggle, disabled while off and `rnodeSettingsProblems` isn't empty (stays enabled while on, so stale defaults can be turned off); `incompleteNotice` when the frequency is missing; `rnodeStatus.userMessage` in red when set; radio row; Choose radio (sends `.chooseRNodeRadioTapped`); frequency `TextField` with a view `@State` string seeded from `megahertzText`, sending `.rnodeFrequencyTextChanged` on change; bandwidth likewise; `Stepper` rows for SF (5…12), CR (5…8) and TX power (0…37) showing their value; each problem's message in red under the section's fields; `boardsNotice`; `pairingNotice`. Header `header`, footer `footer`. Standard `Toggle`, `TextField`, `Stepper` and `Button` Form rows are hittable across their width; any custom row follows the tappable-rows rule.

- [ ] **Step 1: Write the failing tests:**

```swift
rnCopyNoStringNamesTheApp                // no RNodeCopy.all entry contains "ReTiCAMsgr" or "ReticaMsgr"
rnCopyEveryProblemHasAMessage            // each RNodeSettingsProblem case → non-empty, distinct
rnCopyBoardsNoticeNamesEveryBLEBoard     // contains each of the eight board names in spec §6
rnCopyPairingNoticeSaysTheAppReconnects  // contains "reconnects by itself"
rnCopyFooterSaysChangesWaitForConnect    // hasSuffix "Changes take effect on the next Connect."
```

- [ ] **Step 2: Fail,** `--filter rnCopy`, log `t5-red.log`. **Step 3: Implement** the copy and the section. **Step 4: Green,** log `t5-green.log`.
- [ ] **Step 5: Mutation batch.** Add `"ReTiCAMsgr"` to `footer`; `problemMessage` returns the same text for two cases; drop `"T-Echo"`; change "reconnects by itself" to "reconnects"; drop the footer's last sentence. Each named test fails.
- [ ] **Step 6: Restore, re-run, all pass.**
- [ ] **Step 7: Builds.** iOS build, log `t5-ios.log`; Mac build, log `t5-mac.log`; then a Release build: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-rnode/ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -configuration Release -destination "generic/platform=iOS Simulator" -derivedDataPath /tmp/ReTiCaMsgr/lane-rnode-c/dd build > /tmp/ReTiCaMsgr/lane-rnode-c/t5-release.log 2>&1`, and expect `0` from each of:
  - `grep -c "Connect through an RNode" /tmp/ReTiCaMsgr/lane-rnode-c/dd/Build/Products/Release-iphonesimulator/ReTiCAMsgr.app/ReTiCAMsgr`
  - `grep -c "To pair, hold the RNode" /tmp/ReTiCaMsgr/lane-rnode-c/dd/Build/Products/Release-iphonesimulator/ReTiCAMsgr.app/ReTiCAMsgr`
  Restore any scheme plist.
- [ ] **Step 8: Full core suite,** no filter, log `t5-full.log`: baseline + this lane, all pass. `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-rnode diff main --stat`: no existing test file changed except `DiagnosticsSnapshotTests.swift`.
- [ ] **Step 9: Simulator smoke.** Load `xcodebuildmcp-cli`; run Debug. Settings shows the RNode section; the toggle is disabled until a frequency is typed; typing `868,1` shows the unreadable message; `Choose radio…` opens and cancels (empty list expected). Diagnostics shows `RNode` with `radio settings incomplete`. Stop and report a crash.
- [ ] **Step 10: Commit.** Subject: `feat: RNode Settings section with board and pairing guidance`. Then stop and report; don't merge.

---

## Self-review

1. **Spec coverage.** §6 Settings fields and defaults → T2, T5. Validation and messages → T2, T5. Persistence keys → T2. Board copy → T5. Pairing guidance → T5. Picker kind and copy → T1, T3. BLE pause → T3. Diagnostics → T4. Release gate (§7) → T2 (`rnodeAvailable`, `rnodeWillDial`), T3 (choose guard), T4 (layer gate), T5 (section, Release grep). §8 C → T1–T5. Next-Connect rule → T2 `rnSettingsEditingSendsNoEndpointAction`, footer copy.
2. **Step scan.** Signatures, test names and assertions; copy given verbatim because the spec fixes it here.
3. **Type consistency.** `RNodeRadioSettings`, `RNodeSettingsProblem`, `RNodeStatus` (`Params`, `Counters`, fields), `rnodeWillDial`, `rnodeAvailable`, `rnodeRadioUUID`, `rnodeSettingsProblems`, `chooseRNodeRadioTapped`, `RadioKind.rnode`, `scanRNode` match lane D's plan.
4. **Review Focus.** Five items, each with named tests.
5. **Proportion.** Signatures, assertions, copy and mutation lists.
