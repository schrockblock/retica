# MeshCore Lane C (ReTiCAMsgr UI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## Contract issues

Lane C references no MeshCore symbol from lanes A or B, so Contracts 1–3 do not constrain it directly. Two things it does on lane D's behalf, recorded so nobody reads them as divergence:

1. **The key never reaches reducer state.** `MeshCoreDriverConfig.channelSecret` would otherwise sit in `MeshCoreInterface.State`. Lane C builds the store this needs: `MeshCoreKeyStore.secrets()` is read only by lane D's driver wrapper at `driver.start`. See the lane D plan's "Contract issues", item 1.
2. **`MeshCoreStatus` has `firmwareCode`, `channelSlot` and `radioName`, which Contract 2's `.connected` and Contract 3's `.radioOnline` don't carry.** §6 requires them in Diagnostics. Lane C renders them as optional, showing `unknown` when nil; lane D's item 3 says how they get filled.

**Goal:** Give ReTiCAMsgr everything a MeshCore radio needs on the app side except the live wiring: a radio picker generalised to a radio kind, persisted settings, a Keychain-held channel key with a retired list, a Settings section with the required warnings, a Diagnostics layer, and the Release gate.

**Architecture:** All of it is in the ReTiCAMsgr app repo. `RadioPickerFeature` gains a `RadioKind`; `RadioScanner` gains a second closure so every existing Meshtastic test compiles unchanged. The channel key lives only in a `MeshCoreKeyStore` dependency over `KeychainOps`. It never crosses TCA: no `AppFeature` state or action carries it, in any form. Settings' paste and share sheets hold it in view `@State`, inside `MeshCoreKeyText`, a wrapper that prints as `<redacted>`, and talk to the store directly; the reducer hears only a result signal, `.meshCoreKeyDidChange`. Everything gated sits behind one value, `AppFeature.State.meshCoreAvailable`, plus `#if DEBUG` around the view section and its copy.

**Tech Stack:** Swift 6 (tools 6.0), SwiftUI, TCA (`@Reducer`, `@Presents`, `TestStore`), swift-sharing (`@Shared(.appStorage)`, `UserDefaults.inMemory`), Swift Testing, `ReTiCAKeychain` (`KeychainOps`, `InMemoryKeychain`).

**Spec:** `/Users/ell/development/ios/pods/ReTiCA-worktrees/meshcore-interface/docs/superpowers/specs/2026-11-07-meshcore-interface-design.md`. This plan implements §6 "App" for lane C, §7 and §8's C line. It follows `/Users/ell/development/ios/pods/ReTiCA/docs/superpowers/plans/2026-10-16-meshtastic-lane-d-retica-msgr-ui.md`.

## Global Constraints

- **Paths.** `WT` = `/Users/ell/development/ios/apps/ReTiCAMsgr-meshcore`, branch `feat/meshcore-ui`. `CORE` = `WT/ReTiCAMsgrCore`. `MAIN` = `/Users/ell/development/ios/apps/ReTiCAMsgr`. The worktree must be a sibling of the app directory: `CORE/Package.swift` resolves `../../../pods/...`. Temp files go in `/tmp/ReTiCaMsgr/lane-c/`. Expand the shorthand to full paths in every command.
- **Boundaries.** ReTiCAMsgr files only. Never edit anything under `pods/`. Never reference `TransportEndpoint.State.meshCore`, `MeshCoreEndpoint`, `MeshCoreDriver`, `MeshCoreInterface`, `MeshCoreCounters`, `MeshCoreLinkParams` or `meshCoreInterfaceID`, and never import MeshCoreKit: none exists on a merged branch. Do not touch `syncEndpointNodes`, `redialDownNodes`, `somethingWillDial`, `profilePhotoMayRide` or `radioDownAnnounceTargets`: lane D owns them.
- **Not in this plan.** The Meshtastic message-loss warning is on `fix/meshtastic-message-loss-warning` in `/Users/ell/development/ios/apps/ReTiCAMsgr-meshtastic-warning`. Do not add it. That branch's commit touches only `SettingsView.swift`, in the footer at `:398-403`; if it reaches `main` first, rebase in Task 8 and keep its lines.
- **Commits and merges.** Commit only to `feat/meshcore-ui`, one commit per task. **No pushing, no merging.** A person approves the merge (spec §6), and lane C has no merge dependency on other lanes. Stage explicit paths, never `-A` or `.`. Never stage `xcuserdata/**`, `.swiftpm/**`, `default.profraw` or `Package.resolved`. Write each message with the Write tool to `/tmp/ReTiCaMsgr/lane-c/msg-tN.txt` and commit with `git -C WT commit -F <file>`. End messages with the attribution lines the executing session's system reminder gives, at column zero, and verify them with `git -C WT log -1`.
- **Shell.** One command per line, per Bash call. No `|`, `&&`, `||`, `;`, `$(...)`, backticks, `xargs`, heredocs into interpreters, or inline scripts (`python -c`, `bash -c`, `node -e`). Scripts go in files under `/tmp/ReTiCaMsgr/lane-c/`. Redirecting one command's output to a log is allowed; read logs with Read or one `grep`/`tail`.
- **Core test command.** `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshcore/ReTiCAMsgrCore --filter <prefix> > /tmp/ReTiCaMsgr/lane-c/<name>.log 2>&1`, timeout 600000 ms. Without `--filter` it runs everything. The log ends with `Test run with N tests ... passed` or `... failed`. Filtering still compiles the package, so it must compile at the end of each task. Never run `swift test` and `xcodebuild` at once. Known flake: `deliveryFailedMarksFailedAndReloads` can fail alone under `--filter`, and passes in a full run. Build flakes: signal 10/11 or stale-link failures, run `swift package --package-path <CORE> clean` and retry. ENOSPC, delete `~/Library/Developer/Xcode/DerivedData` and retry once.
- **App build commands.** iOS: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-meshcore/ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -destination "generic/platform=iOS Simulator" build > /tmp/ReTiCaMsgr/lane-c/<name>.log 2>&1`. Mac: the same with `-destination "platform=macOS"`. Expected: `** BUILD SUCCEEDED **`. New view files go in `WT/ReTiCAMsgr/` (synchronized groups, no `project.pbxproj` edit). After any Xcode build, `git -C WT status --short`; restore a rewritten `xcschememanagement.plist` with `git -C WT checkout -- <path>` (the only `git checkout --` allowed).
- **Test verification (user rule), every task with new or changed tests:**
  (a) Run the task's filter; all pass. Fix whichever side is wrong first.
  (b) Back up each production file named in the task's mutation table with `cp <file> /tmp/ReTiCaMsgr/lane-c/<name>.orig`. Apply the **whole table in one batch**, run the filter **once**, confirm **every** new test fails. If one passes, it isn't testing what it claims: fix it and restart at (a). Where a mutation would mask another test's failure, the table says so and adds a second batch.
  (c) Restore with `cp <orig> <file>`, confirm `git -C WT diff --stat` lists only intended files, run the filter, all pass. Only then commit. If anything is unexpected at any step, stop and diagnose.
- **TCA test rules (from the Meshtastic lanes).** Free `@MainActor @Test func` functions; `exhaustivity = .off` unless a test claims "nothing is reported", which must be exhaustive. Under `.off`, `store.state` shows effect-delivered actions only after `receive` or `skipReceivedActions(strict: false)`. `send` clears unreceived actions, so `receive` first. Never `store.finish()` on an `AppFeature` store while the picker is presented. `Effect.cancel(id:)` is eager: never hold one in a `let`. A compound test name is a claim per clause: split it. Tests touching `@Shared(.appStorage)` build `AppFeature.State` inside `withDependencies { $0.defaultAppStorage = defaults }` with a fresh `UserDefaults.inMemory`. Read `@Shared` values into locals before mutating `state.node…` (exclusive access).
- **Test names.** New tests start with their task's prefix: `mcPicker` (T1), `mcSettings` (T2), `mcKeyStore` (T3), `mcKeyFlow` (T4), `mcFlow` (T5), `mcDiag` (T6), `mcCopy` (T7). No existing test matches `func mc[A-Z]` (checked 2026-11-07). Existing tests stay untouched, with one exception: `snapshotHasAllLayersInOrder` (Task 6).
- **Tappable rows.** Every custom tappable row's label ends with `.frame(maxWidth: .infinity, alignment: .leading)` then `.contentShape(Rectangle())`. `RadioPickerView` rows already do, and must keep it.
- **Copy says "this app".** New copy never says `ReTiCAMsgr` or `ReticaMsgr`; the display name is pending on a branch. Spec wording "when ReTiCAMsgr connects" becomes "when this app connects".
- **Spec values.** Key: 16 bytes, generated or pasted as 32 hex characters. No default key. Persisted keys: `meshCoreEnabled` (Bool, false), `meshCoreRadioID` (String?, UUID string), `meshCoreRadioName` (String?).
- **Secret rule (spec Contract 3).** The channel key and retired keys are never stored in `AppFeature.State` or sent in an `AppFeature.Action`, in any form including `MeshCoreKeyText`, never logged, and never rendered in `DiagnosticsSnapshot`, not even a fingerprint. Outside the store they exist only in a `MeshCoreKeyText` in view `@State` while a sheet is up, or locally inside a store-calling effect.

**Release gate decision: `#if DEBUG`.** It already works in `ReTiCAMsgrCore` (`AppFeature.swift:790`) and is set by both `swift test` and Xcode's Debug configuration, while a custom flag would need matching edits in `Package.swift` and `project.pbxproj`. Four sites: `MeshCoreReleaseGate.isCompiledIn`, the `SettingsView` section (with its `@State`), `enum MeshCoreCopy`, and all of `MeshCoreKeyViews.swift`. Removing them is lane E's last commit.

**Merging before lane D** ships a Debug-only section whose toggle only shows "radio not connected" in Diagnostics, as Meshtastic's lane D did. Accepted.

## Review Focus

1. **A pasted key is malformed or dangerous:** 31 or 33 characters, non-hex, a `0x` prefix, surrounding newline, uppercase, all zeros, MeshCore's Public secret, or the secret in ScotMesh's docs. Expected: uppercase and surrounding whitespace are fine; the rest are refused with a message and the stored key is untouched. Test: T3 `mcKeyStorePasteRejects` (parameterised), `mcKeyStorePasteAcceptsUppercaseAndSurroundingWhitespace`.
2. **The user pastes the key they already have, or returns to an old one (A → B → A).** Expected: the same key changes nothing and retires nothing. Returning to A retires B and un-retires A, otherwise lane D's slot policy would clear the slot holding the current key. Tests: T3 `mcKeyStoreRepastingTheSameKeyChangesNothing`, `mcKeyStoreReturningToARetiredKeyUnretiresIt`.
3. **The Keychain read fails, or defaults came back from a backup without the key** (`meshCoreEnabled` true, no item). Expected: nothing dials. A read failure reads as `.unreadable`, never `.absent`, and Generate refuses to overwrite a key it can't read, because that would lose the retired entry. Tests: T2 `mcSettingsRestoredDefaultsWithoutAKeyWillNotDial`, T3 `mcKeyStoreUnreadableIsNotAbsent`, `mcKeyStoreUnreadableKeyIsNotOverwritten`.
4. **The wrong radio setting changes:** a MeshCore pick written to Meshtastic's keys or the reverse, or a foreground while the MeshCore picker is open restarting BLE. Tests: T5 `mcFlowPickLeavesTheMeshtasticRadioAlone`, `mcFlowMeshtasticPickLeavesTheMeshCoreRadioAlone`, `mcFlowForegroundWhileOpenKeepsBLEPaused`.
5. **A secret reaches a log through a generic path:** `String(describing:)`, `dump`, `customDump` of any action or the whole state across a generate, paste and copy, or the Diagnostics export. Tests: T3 `mcKeyStoreKeyTextNeverPrintsTheKey`, T4 `mcKeyFlowStateDumpCarriesNoKey`, `mcKeyFlowActionDumpCarriesNoKey`, T6 `mcDiagTextCarriesNoChannelKey`.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `CORE/Sources/ReTiCAMsgrCore/RadioScanner.swift` | modify | `RadioKind`, `scanMeshCore`, `stream(for:)` |
| `CORE/Sources/ReTiCAMsgrCore/RadioPickerFeature.swift` | modify | `State.kind`, per-kind messages, scan by kind |
| `WT/ReTiCAMsgr/RadioPickerView.swift` | modify | render per-kind messages |
| `CORE/Sources/ReTiCAMsgrCore/MeshCoreReleaseGate.swift` | create | the one `#if DEBUG` constant logic reads |
| `CORE/Sources/ReTiCAMsgrCore/MeshCoreKeyStore.swift` | create | Keychain store, key rules, `MeshCoreKeyText`, `MeshCoreSecrets` |
| `CORE/Sources/ReTiCAMsgrCore/AppFeature+MeshCore.swift` | create | state helpers, `MeshCoreSettingsReducer` |
| `CORE/Sources/ReTiCAMsgrCore/AppFeature.swift` | modify | see the touch-point table |
| `CORE/Sources/ReTiCAMsgrCore/AppFeature+Meshtastic.swift` | modify | picker arms by kind |
| `CORE/Sources/ReTiCAMsgrCore/MeshCoreStatus.swift` | create | plain status for Diagnostics |
| `CORE/Sources/ReTiCAMsgrCore/DiagnosticsSnapshot.swift` | modify | `meshCoreLayer` |
| `CORE/Sources/ReTiCAMsgrCore/MeshCoreCopy.swift` | create | verbatim copy, `#if DEBUG` |
| `WT/ReTiCAMsgr/SettingsView.swift` | modify | section, picker sheet stays shared |
| `WT/ReTiCAMsgr/MeshCoreKeyViews.swift` | create | paste sheet, share sheet, all under `#if DEBUG` |
| `WT/ReTiCAMsgr/AppRuntime.swift` | modify | key store and pasteboard dependencies, `meshCoreKeyStore` for the views |
| `WT/ReTiCAMsgr/ContentView.swift` | modify | hands `SettingsView` the key store |
| `CORE/Tests/ReTiCAMsgrCoreTests/MeshCoreTestSupport.swift` | create | `mcStore`, fixtures |
| `CORE/Tests/ReTiCAMsgrCoreTests/MeshCoreSettingsTests.swift` | create | T1, T2 |
| `CORE/Tests/ReTiCAMsgrCoreTests/MeshCoreKeyStoreTests.swift` | create | T3 |
| `CORE/Tests/ReTiCAMsgrCoreTests/MeshCoreKeyFlowTests.swift` | create | T4 |
| `CORE/Tests/ReTiCAMsgrCoreTests/MeshCorePickerFlowTests.swift` | create | T5 |
| `CORE/Tests/ReTiCAMsgrCoreTests/DiagnosticsSnapshotTests.swift` | modify | T6, one expected-list line plus appended tests |

### `AppFeature.swift` touch points (main at `2ee1398`)

Every line that mentions a radio, assigned between lanes. Re-check numbers against the worktree before editing.

| Line(s) | What | Owner |
|---|---|---|
| 282-286 | `profilePhotoMayRide` excludes `meshtastic:` | D |
| 311-321 | Meshtastic `@Shared` settings | C adds MeshCore's after 321 |
| 322-325 | `radioPicker` | shared, C adds `kind` to its state only |
| 326-330 | `blePausedForRadioScan` | shared, unchanged |
| 335 | `meshtasticStatus` | C adds `meshCoreStatus` |
| 337-342 | `meshtasticSwap`, retired counters | D adds MeshCore's |
| 737-739 | `chooseRadioTapped`, `radioPicker` actions | C adds cases |
| 809-816 | `radioDownAnnounceTargets` matches `meshtastic:` | D |
| 833 | `.onLaunch` | C loads key presence |
| 844 | `.onLaunch` `somethingWillDial` (defined at `AppFeature+MeshtasticRadio.swift:27`) | D |
| 859 | `.onLaunch` runs `sync.meshtastic` | D |
| 1183 | Connect blocked while a picker is open | unchanged, works for both kinds |
| 1186, 1191 | Connect's will-dial and `sync.meshtastic` | D |
| 1198 | Disconnect clears `meshtasticSwap?.startNext` | D |
| 1201-1289 | `interfaceConnected` | generic by id, D tests it |
| 1291-1312 | `interfaceDisconnected` radio-down announce | via 809-816, D |
| 2430-2450 | `.setRelayMode` | D forwards the can-route bit |
| 2877-2879 | no-op arm for picker actions | C adds its cases |
| 2994-2996 | reducer composition | C adds `MeshCoreSettingsReducer`, D adds `MeshCoreRadioReducer` |
| 3592-3593, 3646-3654 | `syncEndpointNodes` return and radio sync | D |
| 3705 | `nodeChangeEffects` | D |
| 3772-3785, 3809 | `redialDownNodes` radio restart | D |
| 3789 | re-dial's will-dial | D |
| 3797-3808 | BLE deferred while a picker is open | unchanged, works for both kinds |

---

### Task 0: Worktree and baseline

**Files:** none changed.

- [ ] **Step 1: Create the worktree.** Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr worktree add /Users/ell/development/ios/apps/ReTiCAMsgr-meshcore -b feat/meshcore-ui main`
- [ ] **Step 2: Temp directory.** Run: `mkdir -p /tmp/ReTiCaMsgr/lane-c`
- [ ] **Step 3: Baseline core suite.** Run the core test command with no filter, log `t0-core.log`. Expected: passes. Record N in `/tmp/ReTiCaMsgr/lane-c/baseline.txt`. If anything fails, stop.
- [ ] **Step 4: Baseline iOS build.** Run the iOS build command, log `t0-ios.log`. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 5: Baseline Mac build.** Run the Mac build command, log `t0-mac.log`. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 6: Clean tree.** Run: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshcore status --short`. Expected: empty, after restoring any rewritten scheme plist.

---

### Task 1: Generalise the picker and scanner to a radio kind

**Files:**
- Modify: `CORE/Sources/ReTiCAMsgrCore/RadioScanner.swift:36-42` (struct), `:44-66` (values)
- Modify: `CORE/Sources/ReTiCAMsgrCore/RadioPickerFeature.swift:13-15, 18-29, 57-68`
- Modify: `WT/ReTiCAMsgr/RadioPickerView.swift:62-75, 78-81`
- Create: `CORE/Tests/ReTiCAMsgrCoreTests/MeshCoreTestSupport.swift`, `CORE/Tests/ReTiCAMsgrCoreTests/MeshCoreSettingsTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `public enum RadioKind: String, Equatable, Sendable { case meshtastic, meshCore }`
  - `RadioScanner`: `public var scan` keeps its type and means Meshtastic; `public var scanMeshCore: @Sendable () -> AsyncStream<RadioScanResult>`; `public init(scan:, scanMeshCore: = { finishes at once })`; `public func stream(for kind: RadioKind) -> AsyncStream<RadioScanResult>`.
  - `RadioPickerFeature.State.kind: RadioKind`, `init(kind: RadioKind = .meshtastic, selectedID: UUID? = nil)`, `var scanningMessage: String`, `var scanEndedEmptyMessage: String`.
  - Test support: `mcRadioA: RadioScanResult`, `mcStore(defaults:scanner:keyStore:configure:) -> TestStoreOf<AppFeature>`, built like `meshStore` (`MeshtasticSettingsTests.swift:22`). `keyStore` defaults to an empty in-memory store from Task 3; until Task 3 lands, omit that parameter and add it there.

**Why two closures rather than `scan(kind)`:** existing tests construct `RadioScanner(scan: { AsyncStream { _ in } })` or call `scanner.scan()` (`MeshtasticSettingsTests.swift:23`, `MeshtasticLiveScannerTests.swift:13,25,38`, `MeshtasticRadioTestSupport.swift:133`), and a parameter would make them fail to compile. `RadioPickerFeatureTests` stays green without edits, and `.onAppear` is the only caller that switches to `stream(for: state.kind)`.

- [ ] **Step 1: Write the failing tests** in `MeshCoreSettingsTests.swift`:

```swift
@Test func mcPickerDefaultsToMeshtastic() { #expect(RadioPickerFeature.State().kind == .meshtastic) }
@MainActor @Test func mcPickerMeshCoreScanUsesScanMeshCore()
  // scanner: scan counts in `meshtasticScans`, scanMeshCore in `meshCoreScans`
  // send .onAppear on State(kind: .meshCore); wait; #expect(meshCoreScans == 1); #expect(meshtasticScans == 0)
@MainActor @Test func mcPickerMeshtasticScanUsesScan()
  // same on State(kind: .meshtastic); #expect(meshtasticScans == 1); #expect(meshCoreScans == 0)
@MainActor @Test func mcPickerUninstalledMeshCoreScannerEndsTheScan()
  // scanner = RadioScanner.liveValue, kind .meshCore: receive .scanFinished
@Test func mcPickerMeshCoreMessagesNameMeshCore()
  // #expect(State(kind: .meshCore).scanningMessage == "Scanning for MeshCore radios… Make sure the radio is on and not connected to another app.")
  // #expect(State(kind: .meshCore).scanEndedEmptyMessage == "Scanning stopped before any radio was found. MeshCore support may not be installed in this build, or Bluetooth may be off or not allowed.")
@Test func mcPickerMeshtasticMessagesAreUnchanged()
  // #expect(State().scanningMessage == "Scanning for Meshtastic radios… Make sure the radio is on and not connected to another app.")
  // #expect(State().scanEndedEmptyMessage == RadioPickerFeature.scanEndedEmptyMessage)
```

- [ ] **Step 2: Run to see them fail.** Core test command, `--filter mcPicker`, log `t1-red.log`. Expected: compile errors naming `kind`, `scanMeshCore`.

- [ ] **Step 3: Implement.** Add the Interfaces above. Keep `RadioPickerFeature.scanEndedEmptyMessage` as it is; `RadioScanner.meshtastic(_:)` keeps building a scanner whose `scanMeshCore` is the default. `testValue` gets an `unimplemented` `scanMeshCore`; `previewValue` gets fake radios named `MeshCore-1a2b`, `Base camp` and one unnamed. In `RadioPickerView`, the footer reads `store.scanningMessage` and `store.scanEndedEmptyMessage`, and add a second `#Preview` with `State(kind: .meshCore)`. Row hit-testing lines stay.

- [ ] **Step 4: Run to green, with the old picker tests.** Core test command, `--filter mcPicker --filter radioPicker --filter meshPickerFlow --filter meshLiveScan`, log `t1-green.log`. Expected: all pass, with no edits to existing test files.

- [ ] **Step 5: Mutation batch (one run, `--filter mcPicker`).**

| # | File | Mutation | Must fail |
|---|---|---|---|
| P1 | RadioPickerFeature.swift | `init` body sets `self.kind = .meshCore` | `mcPickerDefaultsToMeshtastic`, `mcPickerMeshtasticScanUsesScan`, `mcPickerMeshtasticMessagesAreUnchanged` |
| P2 | RadioScanner.swift | `stream(for:)` always returns `scan()` | `mcPickerMeshCoreScanUsesScanMeshCore` |
| P3 | RadioPickerFeature.swift | MeshCore's `scanEndedEmptyMessage` branch returns the Meshtastic text | `mcPickerMeshCoreMessagesNameMeshCore` |

**Batch 2**, because `liveValue.scan` also finishes and so P2 can't break it: restore, make `liveValue`'s `scanMeshCore` never finish (`{ AsyncStream { _ in } }`), run once, and confirm `mcPickerUninstalledMeshCoreScannerEndsTheScan` fails.

- [ ] **Step 6: Restore, re-run Step 4's filter, all pass.**

- [ ] **Step 7: Commit** `RadioScanner.swift`, `RadioPickerFeature.swift`, `RadioPickerView.swift`, `MeshCoreTestSupport.swift`, `MeshCoreSettingsTests.swift`. Subject: `feat: radio picker and scanner take a radio kind`.

---

### Task 2: Persisted MeshCore settings and the Release gate value

**Files:**
- Create: `CORE/Sources/ReTiCAMsgrCore/MeshCoreReleaseGate.swift`, `CORE/Sources/ReTiCAMsgrCore/AppFeature+MeshCore.swift`
- Modify: `CORE/Sources/ReTiCAMsgrCore/AppFeature.swift` (after `:321`)
- Modify: `CORE/Tests/ReTiCAMsgrCoreTests/MeshCoreSettingsTests.swift`

**Interfaces:**
- Consumes: `MeshCoreKeyPresence` is declared here and used by Task 3's store.
- Produces:
  - `public enum MeshCoreReleaseGate { public static var isCompiledIn: Bool }`, true under `#if DEBUG`, else false.
  - `public enum MeshCoreKeyPresence: Equatable, Sendable { case absent, present, unreadable }`
  - `AppFeature.State`: `meshCoreEnabled: Bool`, `meshCoreRadioID: String?`, `meshCoreRadioName: String?` (`@Shared(.appStorage(...))`, keys verbatim above); `meshCoreKeyPresence: MeshCoreKeyPresence = .absent`; `meshCoreKeyGeneration = 0` (session-only, bumped on every key change; lane D's slot identity reads it); `public var meshCoreAvailable = MeshCoreReleaseGate.isCompiledIn`.
  - `extension AppFeature.State { public var meshCoreRadioUUID: UUID?; public var meshCoreRadioLabel: String; var meshCoreWillDial: Bool }`, where `meshCoreWillDial` is `meshCoreAvailable && meshCoreEnabled && meshCoreRadioUUID != nil && meshCoreKeyPresence == .present`.

`meshCoreAvailable` is a stored value so tests can turn it off: `swift test` always compiles `DEBUG`, so a `#if` alone could never be tested from here. Lane D reads `meshCoreWillDial`, so stale defaults cannot start a slot in Release. Lane C does not add it to `somethingWillDial` (lane D's).

- [ ] **Step 1: Write the failing tests:**

```swift
@MainActor @Test func mcSettingsDefaultsAreOffWithNoRadio()
  // #expect(!state.meshCoreEnabled); #expect(state.meshCoreRadioID == nil); #expect(state.meshCoreRadioLabel == "None")
@MainActor @Test func mcSettingsToggleWritesTheMeshCoreEnabledKey()
  // send .binding(.set(\.meshCoreEnabled, true)); #expect(defaults.bool(forKey: "meshCoreEnabled"))
@MainActor @Test func mcSettingsReadsAPersistedRadioID()
  // defaults.set(id, forKey: "meshCoreRadioID"); #expect(store.state.meshCoreRadioUUID == mcRadioA.id)
@MainActor @Test func mcSettingsRadioNameKeyIsMeshCoreRadioName()
  // defaults.set("Base camp", forKey: "meshCoreRadioName") plus the ID; #expect(label == "Base camp")
@MainActor @Test func mcSettingsRadioLabelFallsBackToTheIDForABlankName()
@MainActor @Test func mcSettingsNonUUIDRadioIDCountsAsNoRadio()
@MainActor @Test func mcSettingsMeshtasticSettingsDoNotLeakIn()
  // meshtasticEnabled and meshtasticRadioID set: #expect(!meshCoreEnabled); #expect(meshCoreRadioUUID == nil)
@Test(arguments: [(enabled, radio, presence, available, expected)…]) func mcSettingsWillDialNeedsEveryCondition
  // (true,true,.present,true)→true, each single false→false, .absent→false, .unreadable→false
@MainActor @Test func mcSettingsRestoredDefaultsWithoutAKeyWillNotDial()
  // defaults hold enabled + radio, presence .absent: #expect(!state.meshCoreWillDial)
@MainActor @Test func mcSettingsStaleDefaultsWithTheGateOffWillNotDial()
  // defaults hold enabled + radio, presence .present, meshCoreAvailable = false: #expect(!state.meshCoreWillDial)
@Test func mcSettingsGateIsOnInThisBuild() { #expect(MeshCoreReleaseGate.isCompiledIn) }
```

- [ ] **Step 2: Run to see them fail.** `--filter mcSettings`, log `t2-red.log`. Expected: compile errors.
- [ ] **Step 3: Implement** the Interfaces. Doc comments on the three `@Shared` keys say the setting is read at connect time, and name lane D.
- [ ] **Step 4: Run to green.** `--filter mcSettings`, log `t2-green.log`.
- [ ] **Step 5: Mutation batch (one run).**

| # | File | Mutation | Must fail |
|---|---|---|---|
| S1 | AppFeature.swift | `meshCoreEnabled: Bool = false` → `= true` | `mcSettingsDefaultsAreOffWithNoRadio`, `mcSettingsMeshtasticSettingsDoNotLeakIn` |
| S2 | AppFeature.swift | key `"meshCoreEnabled"` → `"meshtasticEnabled"` | `mcSettingsToggleWritesTheMeshCoreEnabledKey` |
| S3 | AppFeature.swift | key `"meshCoreRadioID"` → `"meshCoreRadio"` | `mcSettingsReadsAPersistedRadioID` |
| S4 | AppFeature.swift | key `"meshCoreRadioName"` → `"meshCoreName"` | `mcSettingsRadioNameKeyIsMeshCoreRadioName` |
| S5 | AppFeature+MeshCore.swift | label's `name.isEmpty ? id.uuidString : name` → `name.isEmpty ? "None" : name` | `mcSettingsRadioLabelFallsBackToTheIDForABlankName` |
| S6 | AppFeature+MeshCore.swift | `meshCoreRadioUUID` returns `UUID()` when the string isn't a UUID | `mcSettingsNonUUIDRadioIDCountsAsNoRadio` |
| S7 | AppFeature+MeshCore.swift | `meshCoreWillDial` → `meshCoreEnabled && meshCoreRadioUUID != nil` | `mcSettingsWillDialNeedsEveryCondition`, `mcSettingsRestoredDefaultsWithoutAKeyWillNotDial`, `mcSettingsStaleDefaultsWithTheGateOffWillNotDial` |
| S8 | MeshCoreReleaseGate.swift | `isCompiledIn` returns false | `mcSettingsGateIsOnInThisBuild` |

- [ ] **Step 6: Restore, re-run, all pass.**
- [ ] **Step 7: Commit** the four files. Subject: `feat: MeshCore settings and the Release gate value`.

---

### Task 3: `MeshCoreKeyStore`

**Files:**
- Create: `CORE/Sources/ReTiCAMsgrCore/MeshCoreKeyStore.swift`, `CORE/Tests/ReTiCAMsgrCoreTests/MeshCoreKeyStoreTests.swift`
- Modify: `WT/ReTiCAMsgr/AppRuntime.swift:19-30, 43-47, 60-64, 102-141`, `CORE/Tests/ReTiCAMsgrCoreTests/MeshCoreTestSupport.swift`

**Interfaces:**
- Consumes: `MeshCoreKeyPresence` (T2); `KeychainOps`, `IdentityKeychain.Location`, `InMemoryKeychain` (`ReTiCAKeychain`); `SharedIdentityLocation.accessGroup`.
- Produces:
  - `public struct MeshCoreKeyText: Equatable, Sendable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable { public init(_ hex: String); public func reveal() -> String; public var id: Int { 0 } }`. All three printing paths produce `<redacted>`, and its `Mirror` has no children. The constant `id` is for `.sheet(item:)`, so nothing derives from the key.
  - `public struct MeshCoreSecrets: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable { public let current: Data; public let retired: [Data] }`, redacted the same way. `retired` never contains `current`.
  - `public enum MeshCoreKeyChangeResult: Equatable, Sendable { case changed, unchanged, invalid, storageFailed }`
  - `public struct MeshCoreKeyStore: Sendable` with closures: `presence: () -> MeshCoreKeyPresence`, `generate: () -> MeshCoreKeyChangeResult`, `paste: (MeshCoreKeyText) -> MeshCoreKeyChangeResult`, `exportText: () -> MeshCoreKeyText?`, `secrets: () -> MeshCoreSecrets?`, `forgetRetired: ([Data]) -> Void`, all `@Sendable`.
  - `public static func live(ops: KeychainOps, randomKey: @escaping @Sendable () -> Data = { 16 random bytes }) -> MeshCoreKeyStore`
  - `extension MeshCoreKeyStore: DependencyKey`, `DependencyValues.meshCoreKeyStore`. `liveValue = .live(ops: .live)`. **`testValue` is a benign empty store, not `unimplemented`:** `.onLaunch` reads presence from Task 4 on, and every existing `AppFeature` test sends `.onLaunch` without knowing about this dependency.
  - `public enum MeshCoreKeyRules { public static func parse(_ text: String) -> Data?; static let refusedSecrets: Set<String> }`
  - `AppRuntime.Environment.meshCoreKeyStore`, `.live(ops: .live)` in `live()`, `.live(ops: keychain.ops)` in `testHost()`, and `$0.meshCoreKeyStore = environment.meshCoreKeyStore` in `build()`. Explicit for the same hosted-XCTest reason as `\.date`, and so a hosted run never touches the real Keychain. `AppRuntime.meshCoreKeyStore: MeshCoreKeyStore { environment.meshCoreKeyStore }` gives the Task 7 sheets the same store: a view's own `@Dependency` wouldn't see the store's override.
  - Test support: `mcKeychain() -> (InMemoryKeychain, MeshCoreKeyStore)`, `mcHexA`, `mcHexB`.

**Storage.** Two generic-password items in the access group both entitlement files already list (`SharedIdentityLocation.accessGroup`, `ReTiCAMsgr.entitlements:13`, `ReTiCAMsgr-macOS.entitlements:25`), so no entitlement change:
- `Location(service: "co.lithobyte.reticamsgr.meshcore.channel-key", accessGroup: …)`: 16 bytes.
- `Location(service: "co.lithobyte.reticamsgr.meshcore.retired-channel-keys", accessGroup: …)`: concatenated 16-byte keys, trailing partial bytes ignored.

`KeychainOps` has no update, so a write is `delete(location)` then `add`. `IdentityKeychain` probes by service, so these items can't collide with `reticulum.identity`. Items are device-local and `AfterFirstUnlock` (`KeychainOps.swift:61`). Other team apps in the group could read them; the group already holds the identity private key, which matters more.

**Change order (crash safety).** (1) Read the current key; a read failure returns `.storageFailed`. (2) Write retired list = old retired, minus the new key, plus the old key. (3) Replace the current item. A crash after (2) leaves the current key on the retired list; `secrets()` filters it out, so it's never cleared.

**Refused secrets** (`MeshCoreKeyRules.refusedSecrets`, lowercase hex), §6 "no use of Public or of the secret hard-coded in other projects":
- `00000000000000000000000000000000`: an empty slot's secret (and `MeshCore_Raw_Interface.py:898`'s default).
- `8b3387e9c5cdea6ac9e5edbaa115cd72`: MeshCore Public, `PUBLIC_GROUP_PSK` in `MyMesh.cpp:114`, base64 `izOH6cXN6mrJ5e26oRXNcg==`.
- `c4d2b6c8254e3b11200f57e95dcb1197`: the secret in ScotMesh's `MeshCore_Channel_Interface.py:77` docs.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func mcKeyStoreNewStoreHasNoKey()                 // presence == .absent; secrets() == nil; exportText() == nil
@Test func mcKeyStoreGenerateStoresSixteenBytes()       // randomKey fixed: .changed; item at location == fixed; count 16
@Test func mcKeyStoreLiveGenerateDiffersEachTime()      // default randomKey twice via two stores: keys differ, count 16
@Test func mcKeyStorePasteStoresTheBytes()              // paste(mcHexA): .changed; item == Data(hexString: mcHexA)
@Test func mcKeyStorePasteAcceptsUppercaseAndSurroundingWhitespace() // " \(A.uppercased())\n" stores A
@Test(arguments: [31 chars, 33 chars, "zz…" 32 chars, "0x" + 30 hex, "", spaces inside, all zeros, Public hex, ScotMesh hex])
func mcKeyStorePasteRejects(_ text: String)             // .invalid; presence stays .absent; addCount == 0
@Test func mcKeyStorePasteRejectsLeavesTheStoredKey()   // A stored; paste bad: .invalid; item still A; retired empty
@Test func mcKeyStoreFirstKeyRetiresNothing()           // secrets()?.retired == []
@Test func mcKeyStoreChangeRetiresTheOldKey()           // A then B: current B; retired [A]
@Test func mcKeyStoreRetiredListSurvivesANewStore()     // A, B, then .live(ops: same): retired [A]
@Test func mcKeyStoreRepastingTheSameKeyChangesNothing() // A, A: .unchanged; retired []; addCount unchanged
@Test func mcKeyStoreReturningToARetiredKeyUnretiresIt() // A,B,A: current A; retired [B]
@Test func mcKeyStoreSecretsNeverListTheCurrentKeyAsRetired() // plant retired item holding A, current A: retired == []
@Test func mcKeyStoreForgetRemovesOnlyTheNamedKeys()    // retired [A,B]; forgetRetired([A]): retired [B]
@Test func mcKeyStoreForgetLastDeletesTheItem()         // retired [A]; forgetRetired([A]): item at retired location == nil
@Test func mcKeyStoreUnreadableIsNotAbsent()            // failRead(status: errSecInteractionNotAllowed): presence == .unreadable
@Test func mcKeyStoreUnreadableKeyIsNotOverwritten()    // A stored, failRead: generate == .storageFailed; clearFailures: item still A
@Test func mcKeyStoreFailedRetiredWriteKeepsTheOldKey() // A; failAdd(retired location); paste B: .storageFailed; current still A
@Test func mcKeyStoreFailedKeyWriteReportsFailure()     // A; failAdd(key location); paste B: .storageFailed; retired contains A
@Test func mcKeyStoreKeyTextNeverPrintsTheKey()         // String(describing:), String(reflecting:), String(customDumping:), dump into a String: none contain the hex; reveal() == hex
@Test func mcKeyStoreSecretsNeverPrint()                // same four on MeshCoreSecrets: no hex of current or retired, no raw bytes form
@Test func mcKeyStoreTestValueIsEmptyAndQuiet()         // MeshCoreKeyStore.testValue.presence() == .absent; reports no issue
```

- [ ] **Step 2: Run to see them fail.** `--filter mcKeyStore`, log `t3-red.log`.
- [ ] **Step 3: Implement** per the Interfaces, Storage and Change order above. `parse` trims `.whitespacesAndNewlines`, requires exactly 32 hex characters, lowercases, and refuses `refusedSecrets`. Do not use `Data(hexString:)` alone for validation: check length and characters first. Add the `AppRuntime` lines.
- [ ] **Step 4: Run to green.** `--filter mcKeyStore`, log `t3-green.log`.
- [ ] **Step 5: Mutation batch (one run).**

| # | Mutation | Must fail |
|---|---|---|
| K1 | `presence` maps `.failed` and `.rejected` to `.absent` | `mcKeyStoreUnreadableIsNotAbsent` |
| K2 | change path ignores a read failure, treating the key as absent | `mcKeyStoreUnreadableKeyIsNotOverwritten` |
| K3 | drop the retire write | `mcKeyStoreChangeRetiresTheOldKey`, `mcKeyStoreRetiredListSurvivesANewStore`, `mcKeyStoreFailedKeyWriteReportsFailure`, `mcKeyStoreFailedRetiredWriteKeepsTheOldKey`, `mcKeyStoreForgetRemovesOnlyTheNamedKeys` |
| K5 | `secrets()` doesn't filter current from retired | `mcKeyStoreSecretsNeverListTheCurrentKeyAsRetired` |
| K6 | remove the `.unchanged` early return, and retire the same key | `mcKeyStoreRepastingTheSameKeyChangesNothing` |
| K8 | `parse` returns `Data(text.utf8)` unconditionally | `mcKeyStorePasteRejects`, `mcKeyStorePasteRejectsLeavesTheStoredKey`, `mcKeyStorePasteStoresTheBytes`, `mcKeyStorePasteAcceptsUppercaseAndSurroundingWhitespace`, `mcKeyStoreReturningToARetiredKeyUnretiresIt` |
| K9 | `MeshCoreKeyText` loses its `CustomReflectable`, and `description` returns the hex | `mcKeyStoreKeyTextNeverPrintsTheKey` |
| K10 | `MeshCoreSecrets` loses its redaction | `mcKeyStoreSecretsNeverPrint` |
| K13 | default `randomKey` returns a fixed 16 bytes | `mcKeyStoreLiveGenerateDiffersEachTime` |
| K14 | `generate` stores `randomKey().prefix(15)` | `mcKeyStoreGenerateStoresSixteenBytes` |
| K15 | `testValue` is built with `unimplemented` closures | `mcKeyStoreTestValueIsEmptyAndQuiet` |
| K16 | `presence` returns `.present` when no item exists | `mcKeyStoreNewStoreHasNoKey` |

**Batch 2** (restore first, one run), because K3 and K8 mask these:

| # | Mutation | Must fail |
|---|---|---|
| K4 | drop "minus the new key" from the retire write | `mcKeyStoreReturningToARetiredKeyUnretiresIt` |
| K7 | `parse` skips trimming and lowercasing | `mcKeyStorePasteAcceptsUppercaseAndSurroundingWhitespace` |
| K11 | `forgetRetired` deletes the whole item, regardless of its argument | `mcKeyStoreForgetRemovesOnlyTheNamedKeys` |
| K12 | `forgetRetired` writes an empty item rather than deleting | `mcKeyStoreForgetLastDeletesTheItem` |
| K18 | a first key with no old key appends 16 zero bytes to the retired list | `mcKeyStoreFirstKeyRetiresNothing` |

- [ ] **Step 6: Restore, re-run, all pass.**
- [ ] **Step 7: Commit** the store, tests, support and `AppRuntime.swift`. Subject: `feat: Keychain store for the MeshCore channel key and retired keys`.

---

### Task 4: Key actions, copy and share

**Files:**
- Modify: `CORE/Sources/ReTiCAMsgrCore/AppFeature+MeshCore.swift`, `CORE/Sources/ReTiCAMsgrCore/AppFeature.swift` (State after Task 2's fields; Action `:737-739`; no-op arm `:2877-2879`; body `:2994`; `.onLaunch` `:833`), `WT/ReTiCAMsgr/AppRuntime.swift:102-141`
- Create: `CORE/Tests/ReTiCAMsgrCoreTests/MeshCoreKeyFlowTests.swift`

**Interfaces:**
- Consumes: `MeshCoreKeyStore`, `MeshCoreKeyText`, `MeshCoreKeyChangeResult` (T3); `meshCoreKeyPresence`, `meshCoreKeyGeneration` (T2).
- Produces:
  - `AppFeature.Action`: `meshCoreGenerateKeyTapped`, `meshCoreCopyKeyTapped`, `meshCoreKeyDidChange(MeshCoreKeyChangeResult)`. None carries key material.
  - `AppFeature.State`: `meshCoreKeyMessage: String?`.
  - `struct MeshCoreSettingsReducer: Reducer` (`some ReducerOf<AppFeature>`), composed after `MeshtasticSettingsReducer`.
  - `public struct MeshCoreKeyPasteboard: Sendable { public var copy: @Sendable (MeshCoreKeyText) -> Void }`, `DependencyValues.meshCoreKeyPasteboard`. `liveValue`/`testValue` do nothing. `AppRuntime` sets `$0.meshCoreKeyPasteboard = MeshCoreKeyPasteboard { Pasteboard.copy($0.reveal()) }` (`ReTiCAMsgr/Platform/Pasteboard.swift:10`).

**How the key moves.** It never enters `AppFeature.State` or an `AppFeature.Action`. Generate and copy are effects that call the store. Paste and share are view-side (Task 7): the paste sheet calls `keyStore.paste(MeshCoreKeyText(text))`, then sends `.meshCoreKeyDidChange(result)`. The share text is view `@State`, filled from `keyStore.exportText()` when the button is tapped and dropped on dismiss, so the reducer never hears of a share. Retired keys work as before: the store retires the old key inside `generate` and `paste` (T3), and `.changed` bumps `meshCoreKeyGeneration`, which lane D's slot identity reads.

**Effects.** `.meshCoreGenerateKeyTapped`: `.run { send(.meshCoreKeyDidChange(store.generate())) }`. `.meshCoreCopyKeyTapped`: `.run { if let text = store.exportText() { pasteboard.copy(text) } }`. `.meshCoreKeyDidChange`: `state.meshCoreKeyPresence = store.presence()` in the arm, generation += 1 only on `.changed`, message per result. `.onLaunch` first line: `state.meshCoreKeyPresence = store.presence()`, read synchronously so lane D's sync in the same arm sees it. Messages (verbatim): `.invalid` → `Enter a key of 32 hex characters. A key other people already use for something else can't be used here.`, `.storageFailed` → `The key couldn't be saved. Try again.`, others → nil.

- [ ] **Step 1: Write the failing tests:**

```swift
@MainActor @Test func mcKeyFlowLaunchLoadsPresence()            // store holds a key; send .onLaunch; #expect(presence == .present)
@MainActor @Test func mcKeyFlowGenerateMakesTheKeyPresent()     // send generate; receive .meshCoreKeyDidChange(.changed); presence .present
@MainActor @Test func mcKeyFlowChangeBumpsTheGeneration()       // generation 0 → 1
@MainActor @Test func mcKeyFlowUnchangedDoesNotBumpTheGeneration() // key A; paste A: generation stays 0; message nil
@MainActor @Test func mcKeyFlowInvalidPasteShowsAMessage()      // message == the verbatim .invalid text; generation 0; presence .absent
@MainActor @Test func mcKeyFlowStorageFailureShowsAMessage()    // failAdd: message == verbatim .storageFailed text
@MainActor @Test func mcKeyFlowASuccessfulChangeClearsAnOldMessage() // invalid then valid: message nil
@MainActor @Test func mcKeyFlowCopyGivesThePasteboardTheKey()   // key A; send copy; #expect(copied.value?.reveal() == mcHexA)
@MainActor @Test func mcKeyFlowCopyWithoutAKeyCopiesNothing()   // #expect(copied.value == nil)
@MainActor @Test func mcKeyFlowPasteOverAKeyRetiresTheOldKey()  // key A; paste B: secrets()?.retired == [A]; generation 1
@MainActor @Test func mcKeyFlowGenerateOverAKeyRetiresTheOldKey() // key A; generate: secrets()?.retired == [A]; generation 1
@MainActor @Test func mcKeyFlowStateDumpCarriesNoKey()          // whole flow below: no state dump holds any key's bytes or hex
@MainActor @Test func mcKeyFlowActionDumpCarriesNoKey()         // whole flow below: no action dump holds any key's bytes or hex
```

Use `mcKeychain()`. "Paste" in a test is what the sheet does: `let result = keyStore.paste(MeshCoreKeyText(hex))`, then `store.send(.meshCoreKeyDidChange(result))`.

**The dump tests' flow.** A private store builder wraps `AppFeature()` so it records `String(customDumping:)` of every action and of the state after it. Drive generate, paste A, paste B, copy and `.onLaunch`. For every key involved, including retired ones, no record may contain its hex (upper or lower), its base64 or its decimal byte list. Positive controls, so the tests can't pass on an empty run: the records are non-empty, `exportText()?.reveal() == mcHexB`, and `secrets()?.retired` contains A.

- [ ] **Step 2: Run to see them fail.** `--filter mcKeyFlow`, log `t4-red.log`.
- [ ] **Step 3: Implement** the Interfaces. Add new cases to the no-op arm at `:2877-2879` and compose `MeshCoreSettingsReducer()` after `MeshtasticSettingsReducer()` at `:2994`.
- [ ] **Step 4: Run to green, full suite.** Core test command with no filter, log `t4-green.log`. Every existing `AppFeature` test that sends `.onLaunch` proves `testValue` stays quiet.
- [ ] **Step 5: Mutation batches (`--filter mcKeyFlow`).** Batch 1, one run:

| # | Mutation | Must fail |
|---|---|---|
| F1 | remove the presence read at `.onLaunch` | `mcKeyFlowLaunchLoadsPresence` |
| F2 | `.meshCoreKeyDidChange` doesn't re-read presence | `mcKeyFlowGenerateMakesTheKeyPresent` |
| F3 | generation += 1 on every result | `mcKeyFlowUnchangedDoesNotBumpTheGeneration` |
| F5 | `.invalid` message nil | `mcKeyFlowInvalidPasteShowsAMessage` |
| F6 | `.storageFailed` message nil | `mcKeyFlowStorageFailureShowsAMessage` |
| F8 | copy effect does nothing | `mcKeyFlowCopyGivesThePasteboardTheKey` |
| F12 | add `public var meshCoreKeyHexForDebug: String?` to State, set from `exportText()` in the `.meshCoreKeyDidChange` arm | `mcKeyFlowStateDumpCarriesNoKey` |
| F13 | add an action `.meshCoreKeyHexForDebug(String)`, sent by the generate effect with `exportText()?.reveal()` | `mcKeyFlowActionDumpCarriesNoKey` |
| F14 | `MeshCoreKeyStore.swift`: drop the retire write (T3 K3) | `mcKeyFlowPasteOverAKeyRetiresTheOldKey`, `mcKeyFlowGenerateOverAKeyRetiresTheOldKey` |

Batch 2 (restore first, one run), because F3, F5 and F8 edit the same lines or mask these:

| # | Mutation | Must fail |
|---|---|---|
| F4 | no generation bump | `mcKeyFlowChangeBumpsTheGeneration` |
| F7 | `.changed` leaves the old message | `mcKeyFlowASuccessfulChangeClearsAnOldMessage` |
| F9 | copy effect uses `MeshCoreKeyText("")` when no key | `mcKeyFlowCopyWithoutAKeyCopiesNothing` |

- [ ] **Step 6: Restore, re-run, all pass.**
- [ ] **Step 7: Commit.** Subject: `feat: MeshCore channel key actions, copy and share`.

---

### Task 5: Present the picker for MeshCore

**Files:**
- Modify: `CORE/Sources/ReTiCAMsgrCore/AppFeature+Meshtastic.swift:44-59` (shared open helper, selection by kind), `CORE/Sources/ReTiCAMsgrCore/AppFeature.swift` (Action, no-op arm)
- Create: `CORE/Tests/ReTiCAMsgrCoreTests/MeshCorePickerFlowTests.swift`

**Interfaces:**
- Consumes: `RadioPickerFeature.State(kind:selectedID:)` (T1), `meshCoreRadioUUID`, `meshCoreAvailable` (T2).
- Produces: `AppFeature.Action.chooseMeshCoreRadioTapped`; `func openRadioPicker(_ state: inout AppFeature.State, kind: RadioKind, selected: UUID?) -> Effect<AppFeature.Action>`.

Both `.chooseRadioTapped` (kept as is: 17 test sites send it, and adding an associated value would break them) and `.chooseMeshCoreRadioTapped` call the helper, which holds today's lines 45-54 unchanged. `.chooseMeshCoreRadioTapped` also guards `state.meshCoreAvailable`. The selection arm at `:56-59` switches on `state.radioPicker?.kind`; the child state is still present there, because dismiss comes after the delegate action. The dismiss arm at `:61-76` is unchanged: BLE resumes the same way for both kinds. Leave `MeshtasticSettingsReducer`'s name; a rename adds nothing and would touch lane D's context.

- [ ] **Step 1: Write the failing tests** (`mcFlow…`, helpers private to the file, mirroring `MeshtasticSettingsTests.swift:112-140`):

```swift
@MainActor @Test func mcFlowChooseOpensAMeshCorePicker()                // kind == .meshCore
@MainActor @Test func mcFlowChooseStartsOnTheStoredRadio()              // selectedID == mcRadioA.id
@MainActor @Test func mcFlowChooseWhileAMeshtasticPickerIsOpenChangesNothing() // kind stays .meshtastic
@MainActor @Test func mcFlowPausesRunningBLE()                          // receive BLE .stop; blePausedForRadioScan
@MainActor @Test(arguments: PickerExit.allCases) func mcFlowEveryExitResumesPausedBLE(_:) // receive BLE .start; status .starting; !paused
@MainActor @Test func mcFlowLeavesStoppedBLEStopped()
@MainActor @Test func mcFlowWithoutBLESlotSendsNoBLEAction()
@MainActor @Test func mcFlowPickStoresTheRadioID()                      // meshCoreRadioID == id string
@MainActor @Test func mcFlowPickStoresTheRadioName()                    // meshCoreRadioName == "Alpha"
@MainActor @Test func mcFlowPickLeavesTheMeshtasticRadioAlone()         // meshtasticRadioID and name unchanged
@MainActor @Test func mcFlowMeshtasticPickLeavesTheMeshCoreRadioAlone() // .chooseRadioTapped, pick: meshCore keys unchanged, meshtastic keys set
@MainActor @Test func mcFlowPickClosesThePicker()                       // radioPicker == nil after receive(.dismiss)
@MainActor @Test func mcFlowUsesTheMeshCoreScanner()                    // onAppear: meshCoreScans == 1, meshtasticScans == 0
@MainActor @Test func mcFlowDismissStopsTheScan()                       // stream termination seen within 2 s
@MainActor @Test func mcFlowForegroundWhileOpenKeepsBLEPaused()         // send .foregrounded: BLE status stays .stopped
@MainActor @Test func mcFlowGateOffOpensNothing()                       // meshCoreAvailable = false: radioPicker == nil, and no BLE stop
```

- [ ] **Step 2: Run to see them fail.** `--filter mcFlow`, log `t5-red.log`.
- [ ] **Step 3: Implement** the helper, the arm, the selection switch.
- [ ] **Step 4: Run to green, full suite.** Core test command with no filter, log `t5-green.log`: `BLESlotRemovalTests.swift:240,257`, `MeshtasticRedialTests.swift:81` and `MeshtasticSettingsTests.swift` all send `.chooseRadioTapped`.
- [ ] **Step 5: Mutation batches (`--filter mcFlow`).** Batch 1, one run:

| # | File | Mutation | Must fail |
|---|---|---|---|
| L1 | AppFeature+Meshtastic.swift | `.chooseMeshCoreRadioTapped` opens with `kind: .meshtastic` | `mcFlowChooseOpensAMeshCorePicker`, `mcFlowUsesTheMeshCoreScanner`, `mcFlowPickStoresTheRadioID`, `mcFlowPickStoresTheRadioName` |
| L2 | helper | ignore `selected` | `mcFlowChooseStartsOnTheStoredRadio` |
| L3 | helper | remove `guard state.radioPicker == nil` | `mcFlowChooseWhileAMeshtasticPickerIsOpenChangesNothing` |
| L5 | helper | remove `guard state.bleIsRunning` | `mcFlowLeavesStoppedBLEStopped`, `mcFlowWithoutBLESlotSendsNoBLEAction` |
| L8 | `.chooseMeshCoreRadioTapped` | remove the `meshCoreAvailable` guard | `mcFlowGateOffOpensNothing` |
| L9 | RadioPickerFeature.swift | `.onAppear`'s effect spawns the `for await` in `Task.detached`, which cancellation can't reach | `mcFlowDismissStopsTheScan` |
| L10 | RadioPickerFeature.swift | `.radioTapped` skips dismiss | `mcFlowPickClosesThePicker` |

Batch 2 (restore first, one run), because L1 and L5 hide these:

| # | File | Mutation | Must fail |
|---|---|---|---|
| L4 | helper | remove the BLE pause block | `mcFlowPausesRunningBLE`, `mcFlowEveryExitResumesPausedBLE`, `mcFlowForegroundWhileOpenKeepsBLEPaused` |
| L7 | selection arm | writes both radios' keys, whatever the kind | `mcFlowPickLeavesTheMeshtasticRadioAlone`, `mcFlowMeshtasticPickLeavesTheMeshCoreRadioAlone` |

- [ ] **Step 6: Restore, re-run Step 4's filter, all pass.**
- [ ] **Step 7: Commit.** Subject: `feat: open the radio picker for MeshCore, pausing BLE as Meshtastic does`.

---

### Task 6: `MeshCoreStatus` and the Diagnostics layer

**Files:**
- Create: `CORE/Sources/ReTiCAMsgrCore/MeshCoreStatus.swift`
- Modify: `CORE/Sources/ReTiCAMsgrCore/DiagnosticsSnapshot.swift:18-29` (deny list), `:56-65`, after `:292`; `CORE/Sources/ReTiCAMsgrCore/AppFeature.swift` (State after `:336`)
- Modify: `CORE/Tests/ReTiCAMsgrCoreTests/DiagnosticsSnapshotTests.swift:441`, plus appended tests

**Interfaces:**
- Consumes: `meshCoreEnabled`, `meshCoreRadioUUID`, `meshCoreRadioLabel`, `meshCoreKeyPresence`, `meshCoreAvailable`.
- Produces (lane D fills these):

```swift
public struct MeshCoreStatus: Equatable, Sendable {
    public struct LoRaParams: Equatable, Sendable { spreadingFactor: UInt8; bandwidthHz: UInt32; codingRate: UInt8 }
    public struct Counters: Equatable, Sendable { malformed, notAddressed, evicted, timedOut, oversize, completed,
                                                  queueFull, sendFailed, announcesLimited, pathRequestsLimited: Int }
    public var online: Bool; radioName: String?; params: LoRaParams?; firmwareCode: UInt8?; channelSlot: UInt8?
    public var offlineReason: String?; adapterUnavailable: BLEAdapterUnavailable?
    public var channelLeftOnRadio: Bool   // a turn-off couldn't remove our slot
    public var channelRemoved: Bool       // the last turn-off removed our slot
    public var counters: Counters
    /// Computed from `adapterUnavailable`, for Settings: `.other(text)` → text; unauthorized/unsupported/poweredOff → a sentence; nil otherwise.
    public var userMessage: String? { get }
    public init(…all stored properties, defaulted…)
}
```
`Counters` has `+` and `+=` as `MeshtasticStatus.Counters` does. `AppFeature.State.meshCoreStatus = MeshCoreStatus()`.

**Layer.** Title `MeshCore`, in `layers` directly after Meshtastic, present only when `state.meshCoreAvailable`. Rows in order: `meshcore` on/off, then if on: `channel key` (`set`, `not set`, `can't be read`), `radio`, `radio id`, `status`, `radio name` (from status), `LoRa` (`SF10 / 250 kHz / CR5`, or `unknown`), `firmware code` (or `unknown`), `channel slot` (or `unknown`), `offline reason`, `adapter` (use `describeMeshtastic`, generic, shows `.other` text), then `reassembled` (completed), `malformed`, `not addressed`, `evicted`, `timed out`, `oversize`, `queue full`, `send failed`, `announces limited`, `path requests limited`. When off, add `channel left on radio` = `yes` only if `channelLeftOnRadio`.

Health, first match wins: off → `.ok`. Key not present → `.warn` `no channel key — set one in Settings` (`.unreadable` → `.warn` `the channel key can't be read`). No radio → `.warn` `no radio chosen — choose one in Settings`. Adapter unavailable → `.problem` `the Bluetooth path to the radio is unavailable`. Offline → `.warn` `radio not connected`. Else `.ok`. Untrusted text (radio name, `.other` payload) goes in rows, never in `reason`.

Add to the file's DENY LIST comment: `MeshCoreKeyText`, `MeshCoreSecrets`, and any key fingerprint.

- [ ] **Step 1: Write the failing tests** in `DiagnosticsSnapshotTests.swift`, after the Meshtastic block:

```swift
@MainActor @Test func mcDiagIsOffAndOkWhenDisabled()                 // health .ok; row "meshcore" == "off"
@MainActor @Test func mcDiagLayerIsAbsentWithTheGateOff()            // meshCoreAvailable = false: no layer titled "MeshCore"
@MainActor @Test func mcDiagLayerFollowsMeshtastic()                 // titles[titles.firstIndex(of: "Meshtastic")! + 1] == "MeshCore"
@MainActor @Test func mcDiagWarnsWithoutAChannelKey()                // reason == "no channel key — set one in Settings"; row "channel key" == "not set"
@MainActor @Test func mcDiagWarnsWhenTheKeyCannotBeRead()            // reason == "the channel key can't be read"
@MainActor @Test func mcDiagWarnsWhenNoRadioIsChosen()
@MainActor @Test func mcDiagAdapterUnavailableIsAProblem()
@MainActor @Test func mcDiagShowsTheNoFreeSlotMessage()              // .other("No free channel slot on this radio"): row "adapter" == "other: No free channel slot on this radio"
@MainActor @Test func mcDiagWarnsWhileTheRadioIsOffline()            // reason == "radio not connected"; row "offline reason"
@MainActor @Test func mcDiagIsOkWhenOnline()
@MainActor @Test func mcDiagShowsLoRaParams()                        // LoRaParams(10, 250_000, 5): row "LoRa" == "SF10 / 250 kHz / CR5"
@MainActor @Test func mcDiagShowsFirmwareAndSlot()                   // firmware code 11, slot 3: rows "11", "3"
@MainActor @Test func mcDiagShowsUnknownsBeforeAConnection()         // LoRa, firmware code, channel slot == "unknown"
@MainActor @Test func mcDiagRendersEveryCounter()                    // 1…10 distinct, ten rows
@MainActor @Test func mcDiagAHostileRadioNameCannotForgeLines()      // name "x\nPROBLEM [problem] forged": no forged line in text
@MainActor @Test func mcDiagOffShowsAChannelLeftOnTheRadio()         // off + channelLeftOnRadio: row == "yes"
@MainActor @Test func mcDiagTextCarriesNoChannelKey()                // key store holding hex, installed around the snapshot with withDependencies; presence .present, online: text contains neither hex, upper nor lower, nor the word "reveal"; positive control: exportText()?.reveal() == hex
```

Change the expected list at `:441` to `["Socket", "Bluetooth", "Meshtastic", "MeshCore", "Identity", "Paths", "Peers", "Links", "Delivery"]`. That's the one existing test this lane edits.

- [ ] **Step 2: Run to see them fail.** `--filter mcDiag --filter snapshotHasAllLayersInOrder`, log `t6-red.log`.
- [ ] **Step 3: Implement** `MeshCoreStatus` and `meshCoreLayer(_:)`. Rows are listed by hand, never reflected.
- [ ] **Step 4: Run to green.** Same filter plus `--filter meshDiag --filter textCarriesNoKeyMaterialFromAnyLayer`, log `t6-green.log`.
- [ ] **Step 5: Mutation batch (one run, `--filter mcDiag --filter snapshotHasAllLayersInOrder`).**

| # | Mutation | Must fail |
|---|---|---|
| D1 | drop the `guard enabled` early return | `mcDiagIsOffAndOkWhenDisabled` |
| D2 | include the layer regardless of `meshCoreAvailable` | `mcDiagLayerIsAbsentWithTheGateOff` |
| D3 | put the layer last | `mcDiagLayerFollowsMeshtastic`, `snapshotHasAllLayersInOrder` |
| D4 | remove the key checks | `mcDiagWarnsWithoutAChannelKey`, `mcDiagWarnsWhenTheKeyCannotBeRead` |
| D5 | remove the no-radio check | `mcDiagWarnsWhenNoRadioIsChosen` |
| D6 | adapter check returns `.warn` | `mcDiagAdapterUnavailableIsAProblem` |
| D7 | `adapter` row uses `describe(_:)` (no payload) | `mcDiagShowsTheNoFreeSlotMessage` |
| D8 | offline falls through to `.ok` | `mcDiagWarnsWhileTheRadioIsOffline` |
| D9 | always-warn at the end | `mcDiagIsOkWhenOnline` |
| D10 | LoRa row prints `bandwidthHz` raw | `mcDiagShowsLoRaParams` |
| D11 | swap firmware and slot rows' values | `mcDiagShowsFirmwareAndSlot` |
| D12 | nil renders as `""` | `mcDiagShowsUnknownsBeforeAConnection` |
| D13 | `announces limited` row uses `pathRequestsLimited` | `mcDiagRendersEveryCounter` |
| D14 | put the radio name in `reason` | `mcDiagAHostileRadioNameCannotForgeLines` |
| D15 | drop the left-on-radio row | `mcDiagOffShowsAChannelLeftOnTheRadio` |
| D16 | read `@Dependency(\.meshCoreKeyStore)` in the layer and add `Row("channel key value", keyStore.exportText()?.reveal() ?? "")` | `mcDiagTextCarriesNoChannelKey` |

- [ ] **Step 6: Restore, re-run, all pass.**
- [ ] **Step 7: Commit.** Subject: `feat: MeshCore status and Diagnostics layer`.

---

### Task 7: Settings section, copy and key sheets

**Files:**
- Create: `CORE/Sources/ReTiCAMsgrCore/MeshCoreCopy.swift`, `WT/ReTiCAMsgr/MeshCoreKeyViews.swift`
- Modify: `WT/ReTiCAMsgr/SettingsView.swift` (after `:404`), `WT/ReTiCAMsgr/ContentView.swift:17`, `CORE/Sources/ReTiCAMsgrCore/AppFeature+MeshCore.swift`
- Modify: `CORE/Tests/ReTiCAMsgrCoreTests/MeshCoreSettingsTests.swift`

**Interfaces:**
- Consumes: T1–T6.
- Produces: `#if DEBUG public enum MeshCoreCopy { public static let footer: String; requiredWarning: String; turnOffNotice: String; radioChangeNotice: String; … } #endif`; `#if DEBUG struct MeshCorePasteKeySheet: View`, `struct MeshCoreShareKeySheet: View` `#endif`; `SettingsView(store:meshCoreKeyStore:)`, with `RootView` passing `runtime.meshCoreKeyStore`, its one call site; `extension AppFeature.State { public var meshCoreTurnOffNoticeVisible: Bool }`, which is `meshCoreRadioUUID != nil && !meshCoreStatus.channelRemoved && !meshCoreStatus.channelLeftOnRadio`.

**Why the notice is derived.** Whether a slot remains can't always be known: with no slot this session, or a radio never reached, the app can't tell. So the notice shows whenever a radio is chosen, unless a removal is known to have succeeded or `channelLeftNotice` already says it failed. Lane D fills `channelRemoved` and `channelLeftOnRadio`.

**Copy (verbatim).**
- Header `MeshCore`. Toggle `Connect through a MeshCore radio`. Row `Radio`, value `meshCoreRadioLabel`. Button `Choose radio…` (U+2026).
- Row `Channel key`, value `Set`, `Not set` or `Can't be read`. Buttons `Generate key`, `Paste key…`, `Copy key`, `Share key…`. Copy and Share only when presence is `.present`. `exportText()` returning nil presents nothing.
- Confirmation before Generate over an existing key: title `Replace the channel key?`, message `Everyone on the tunnel needs the new key. The old channel is removed from the radio at the next connection.`, buttons `Replace` (destructive), `Cancel`. Paste uses the same confirmation only when a key is present.
- `requiredWarning` = `Text messages waiting on the radio are removed when this app connects and won't reach the MeshCore app.`
- `footer` = `Sends and receives messages through a MeshCore radio paired with this device over Bluetooth. This adds traffic to a shared radio network, so leave it off unless you need it. Everyone on the tunnel needs the same channel key, so set one before turning this on. ` + `requiredWarning` + ` The radio must not be connected to another app, such as the MeshCore app, at the same time. Choosing a radio pauses Bluetooth connections to nearby devices until the list closes. Off by default. Turning this on, or changing the radio or key, takes effect on the next Connect.`
- `turnOffNotice` = `Turning this off removes this app's channel from the radio if it's connected. If it isn't connected, the channel may stay on the radio, and you can remove it in the MeshCore app.`
- `radioChangeNotice` = `Choosing a different radio leaves this app's channel on the old radio. You can remove it there with the MeshCore app.`
- `noKeyNotice` = `Set a channel key to turn this on.`
- `channelLeftNotice` = `This app couldn't remove its channel from the radio. You can remove it in the MeshCore app.`
- Paste sheet title `Paste Channel Key`, field prompt `32 hex characters`, buttons `Save`, `Cancel`. Share sheet title `Channel Key`, body `Anyone with this key can read and send on this tunnel. Share it only with people on the tunnel.`

The Network footer at `SettingsView.swift:328-330` stays as it is, because it's also in Release builds and must not name MeshCore.

**View structure.** The whole `Section` and its `@State` sit inside `#if DEBUG` after `:404`, and all of `MeshCoreKeyViews.swift` sits inside `#if DEBUG`. Toggle: `Toggle(..., isOn: $store.meshCoreEnabled).disabled(!store.meshCoreEnabled && store.meshCoreKeyPresence != .present)`. It stays tappable when already on, so a restored-defaults user can still turn it off. Show `noKeyNotice` when presence isn't `.present`, `store.meshCoreStatus.userMessage` in red when non-nil, `meshCoreKeyMessage` in red when non-nil, `channelLeftNotice` when `channelLeftOnRadio`, `turnOffNotice` when `meshCoreTurnOffNoticeVisible`, `radioChangeNotice` when `meshCoreRadioUUID != nil`. The section's view `@State` holds `shareText: MeshCoreKeyText?`: `Share key…` sets it from `meshCoreKeyStore.exportText()`, and a `.sheet(item: $shareText)` shows the share sheet, so dismissing drops the text and no action is sent. Paste sheet holds its field in view `@State`, clears it on Save and Cancel, sets `.textInputAutocapitalization(.never)` and `.autocorrectionDisabled()` under `#if os(iOS)` as `NodeFormView` does. Save calls `meshCoreKeyStore.paste(MeshCoreKeyText(text))`, then sends `.meshCoreKeyDidChange(result)`. Standard `Form` rows and buttons are already hittable across the width, as `SettingsView.swift:393` notes; any row built as a `.plain` button gets the two-line tap rule. Use `.macSheetFrame()` on both sheets.

- [ ] **Step 1: Write the failing tests** (`#if DEBUG` not needed, test builds are Debug):

```swift
@Test func mcCopyWarningSaysMessagesAreRemoved()
  // #expect(MeshCoreCopy.requiredWarning == "Text messages waiting on the radio are removed when this app connects and won't reach the MeshCore app.")
@Test func mcCopyFooterCarriesTheWarning()              // footer.contains(requiredWarning)
@Test func mcCopyFooterSaysThisAddsSharedTraffic()      // footer.contains("adds traffic to a shared radio network")
@Test func mcCopyFooterSaysEveryoneNeedsTheKey()        // footer.contains("Everyone on the tunnel needs the same channel key")
@Test func mcCopyTurnOffSaysWhatHappensWhenNotConnected() // turnOffNotice.contains("may stay on the radio"); .contains("MeshCore app")
@Test func mcCopyRadioChangeSaysTheOldChannelStays()    // radioChangeNotice.contains("different radio"); .contains("old radio"); .contains("MeshCore app")
@Test func mcCopyNeverNamesTheApp()                     // for every MeshCoreCopy string: !lowercased().contains("reticamsgr")
@MainActor @Test func mcSettingsUserMessageShowsDriverText() // MeshCoreStatus(adapterUnavailable: .other("x")).userMessage == "x"
@MainActor @Test func mcSettingsTurnOffNoticeShowsWithARadioChosen()     // radio set, feature on and off: visible
@MainActor @Test func mcSettingsTurnOffNoticeHidesWithNoRadio()          // no radio: not visible
@MainActor @Test func mcSettingsTurnOffNoticeHidesAfterARemoval()        // radio set, channelRemoved: not visible
@MainActor @Test func mcSettingsTurnOffNoticeGivesWayToTheLeftNotice()   // radio set, channelLeftOnRadio: not visible
```
Give `MeshCoreCopy` `static let all: [String]` for `mcCopyNeverNamesTheApp`.

- [ ] **Step 2: Run to see them fail.** `--filter mcCopy`, log `t7-red.log`.
- [ ] **Step 3: Implement** `MeshCoreCopy`, the section and the sheets.
- [ ] **Step 4: Run to green.** `--filter mcCopy --filter mcSettingsUserMessage --filter mcSettingsTurnOffNotice`, log `t7-green.log`.
- [ ] **Step 5: Mutation batch (one run).**

| # | Mutation | Must fail |
|---|---|---|
| C1 | `requiredWarning` says "may be removed" | `mcCopyWarningSaysMessagesAreRemoved` |
| C2 | `footer` omits `requiredWarning` | `mcCopyFooterCarriesTheWarning` |
| C3 | footer's traffic sentence removed | `mcCopyFooterSaysThisAddsSharedTraffic` |
| C4 | footer's key sentence removed | `mcCopyFooterSaysEveryoneNeedsTheKey` |
| C5 | `turnOffNotice` keeps only its first sentence | `mcCopyTurnOffSaysWhatHappensWhenNotConnected` |
| C6 | `noKeyNotice` says `ReTiCAMsgr` | `mcCopyNeverNamesTheApp` |
| C7 | `userMessage` returns nil for `.other` | `mcSettingsUserMessageShowsDriverText` |
| C8 | `meshCoreTurnOffNoticeVisible` tests `meshCoreRadioUUID == nil` | `mcSettingsTurnOffNoticeShowsWithARadioChosen`, `mcSettingsTurnOffNoticeHidesWithNoRadio` |
| C9 | `radioChangeNotice` says "the new radio" | `mcCopyRadioChangeSaysTheOldChannelStays` |

**Batch 2** (restore first, one run), because C8 hides these:

| # | Mutation | Must fail |
|---|---|---|
| C10 | `meshCoreTurnOffNoticeVisible` drops `!channelRemoved` | `mcSettingsTurnOffNoticeHidesAfterARemoval` |
| C11 | `meshCoreTurnOffNoticeVisible` drops `!channelLeftOnRadio` | `mcSettingsTurnOffNoticeGivesWayToTheLeftNotice` |

- [ ] **Step 6: Restore, re-run, all pass.**
- [ ] **Step 7: iOS and Mac builds.** Run both app build commands, logs `t7-ios.log`, `t7-mac.log`. Expected: `** BUILD SUCCEEDED **` each.
- [ ] **Step 8: Commit.** Subject: `feat: MeshCore Settings section with the required warning`.

---

### Task 8: Verification, gate proof, hand-off

**Files:** none changed, unless verification finds a defect.

- [ ] **Step 1: Full core suite.** Core test command, no filter, log `t8-core.log`. Expected: passes; count = baseline + this lane's tests. `MeshtasticLiveScannerTests`, `RadioPickerFeatureTests` and `MeshtasticSettingsTests` unedited: confirm with `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshcore diff main --stat`.
- [ ] **Step 2: Debug build with a fixed output path.** `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-meshcore/ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -configuration Debug -destination "generic/platform=iOS Simulator" -derivedDataPath /tmp/ReTiCaMsgr/lane-c/dd build > /tmp/ReTiCaMsgr/lane-c/t8-debug.log 2>&1`. Expected: succeeded.
- [ ] **Step 3: Positive control,** covering the section and both key sheets. If the dylib path differs, find it with `ls` and use that file. Expected for each: 1 or more, so Step 5's zeros mean something.
  - `grep -c "Connect through a MeshCore radio" /tmp/ReTiCaMsgr/lane-c/dd/Build/Products/Debug-iphonesimulator/ReTiCAMsgr.app/ReTiCAMsgr.debug.dylib`
  - `grep -c "Paste Channel Key" /tmp/ReTiCaMsgr/lane-c/dd/Build/Products/Debug-iphonesimulator/ReTiCAMsgr.app/ReTiCAMsgr.debug.dylib`
  - `grep -c "Anyone with this key can read and send on this tunnel" /tmp/ReTiCaMsgr/lane-c/dd/Build/Products/Debug-iphonesimulator/ReTiCAMsgr.app/ReTiCAMsgr.debug.dylib`
- [ ] **Step 4: Release build.** The same as Step 2 with `-configuration Release`, log `t8-release.log`. Expected: `** BUILD SUCCEEDED **`, so Release compiles without the section, the key sheets and `MeshCoreCopy`.
- [ ] **Step 5: Copy is compiled out.** Expected for each: `0` (grep exits 1, which is the pass here).
  - `grep -c "Connect through a MeshCore radio" /tmp/ReTiCaMsgr/lane-c/dd/Build/Products/Release-iphonesimulator/ReTiCAMsgr.app/ReTiCAMsgr`
  - `grep -c "Paste Channel Key" /tmp/ReTiCaMsgr/lane-c/dd/Build/Products/Release-iphonesimulator/ReTiCAMsgr.app/ReTiCAMsgr`
  - `grep -c "Anyone with this key can read and send on this tunnel" /tmp/ReTiCaMsgr/lane-c/dd/Build/Products/Release-iphonesimulator/ReTiCAMsgr.app/ReTiCAMsgr`
- [ ] **Step 6: Simulator smoke.** Load the `xcodebuildmcp-cli` skill. Build and run the Debug scheme on an available iOS simulator.
  - [ ] Settings shows the MeshCore section after Meshtastic, toggle disabled, `Channel key` `Not set`.
  - [ ] `Generate key` shows `Set`; the toggle enables. `Generate key` again asks to confirm.
  - [ ] `Paste key…` with `abc` shows the red message, key unchanged.
  - [ ] `Share key…` opens the sheet; closing it clears it.
  - [ ] `Choose radio…` opens `Choose Radio` with MeshCore's footer. With lane C's stub it shows the ended-empty MeshCore message. Tap Cancel.
  - [ ] Meshtastic's `Choose radio…` still says `Scanning for Meshtastic radios…` or its ended message.
  - [ ] Diagnostics shows the MeshCore layer. Share its text to a file or read it on screen: no key.
  If the app crashes, stop and report. Don't add simulator-only code.
- [ ] **Step 7: Rebase check.** `git -C /Users/ell/development/ios/apps/ReTiCAMsgr log --oneline -5 main`. If `main` moved (for instance the warning branch landed), `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshcore rebase main`, keep both sides' footer lines, and rerun Steps 1 and 4.
- [ ] **Step 8: Stop and report.** Report the commits, test counts and smoke results. **Do not merge or push.** A person decides when `feat/meshcore-ui` merges to app `main`. Lane D's Part 2 starts only after it has.

---

## Self-review

1. **Spec coverage.** §6 Settings section → T7. Both radio types enabled at once: settings are separate keys (T2) and T5 proves independence; separate slots are lane D. Channel key: Generate, paste 32 hex, copy/share → T3, T4, T7. No default key, no Public or hard-coded secret → T3 `mcKeyStorePasteRejects`, `mcKeyStoreNewStoreHasNoKey`. Keychain → T3. Toggle can't take effect until set → T2 `meshCoreWillDial`, T7 disabled toggle. Shared-network and everyone-needs-key copy → T7. Message-loss warning → T7. Meshtastic warning: excluded by instruction. Picker generalised, one scan, BLE pause, tap rule → T1, T5, RadioPickerView unchanged rows. Diagnostics → T6. §7 → T2 value, T7 section, T8 proof. §8 C: toggle and key persistence (T2, T3), no-key blocking (T2), retired-key persistence (T3), picker for both kinds (T1, T5), BLE pause and resume (T5). Pairing: nothing to build.
2. **Step scan.** Each test step gives names and assertions; each code step gives signatures. Bodies appear nowhere.
3. **Type consistency.** `MeshCoreKeyPresence` declared T2, used T3, T4, T6. `MeshCoreKeyText` T3, used inside the T4 effects and T7's view `@State`, never in `AppFeature` state or actions. `meshCoreKeyGeneration` T2, bumped T4. `RadioPickerFeature.State(kind:selectedID:)` T1, used T5. `MeshCoreStatus.Counters` fields match Contract 3's `MeshCoreCounters` list.
4. **Review Focus.** All five have named tests in owning tasks.
5. **Proportion.** Signatures, assertions and mutation tables only.
