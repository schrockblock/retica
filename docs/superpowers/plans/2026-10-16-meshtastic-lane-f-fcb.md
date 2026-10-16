# Meshtastic Lane F — FCB Scan Ownership + Power-Off Pending Operations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the two FCB defects that every FCB consumer shares: (1) a scan's owner can stop only ITS OWN scan, and a superseded scan's stream ends instead of going quiet; (2) Bluetooth leaving `.poweredOn` fails every pending central operation instead of leaking it, and a second call for an occupied slot fails the first instead of overwriting it. Then make ReTiCA's `FCBDriverAdapter` and MeshtasticKit's `MeshtasticScanner` own their scans correctly on top of that.

**Architecture:** All FCB changes live in `CentralActor` (`Sources/FCBComposable/BluetoothCentralClient+Live.swift`). Scan streams carry tokens. A newer scan *retires* the current one and finishes its stream. A termination that reaches the actor before its own start is remembered, so that start never happens. `stopScan` becomes a source-compatible no-op, which makes stream termination the only stop. A state change away from `.poweredOn` runs `adapterWentDown(with:)`. It drains every pending-continuation map with an error mapped from the state, finishes the notification and scan streams, and forgets peripherals and characteristics: CoreBluetooth invalidates all peripheral objects at a power-off. ReTiCA's adapter stops calling `stopScan`. Its `resetSession` finishes only the stream it captured and skips manager-wide teardown once a newer session has begun. When its scan stream ends without the adapter cancelling it while Bluetooth is still on, another owner has superseded it. The adapter then reports a transient `.unavailable(.other(…))`, so BLE leaves `.online` and the interface's existing retry restarts it, instead of BLE staying "online" without discovering. MeshtasticKit's scanner re-waits for power and scans again when FCB ended its scan because Bluetooth went off, and finishes for good when another owner superseded it.

**Tech Stack:** Swift 6.3 tools / Swift 6 language mode, FCB (`FCBComposable`), CoreBluetoothMock 1.0.6 (Nordic), swift-composable-architecture (`LockIsolated`), Swift Testing.

**Spec:** `/Users/ell/development/ios/pods/ReTiCA/docs/superpowers/specs/2026-10-16-meshtastic-interface-design.md`. This plan implements **Lane F** (§7 "Lane F (FCB)" items 1 and 2; the §6 lanes table row F). Lane E's app tasks that open the radio picker alongside a running BLE slot are gated on this plan's Part 1 + Part 2 merging.

## Where this plan departs from the spec (read first)

Each departure was probe-confirmed against the live FCB client over CoreBluetoothMock (see "Probe evidence"). They are also listed in the lane report.

1. **The dismiss-side mechanism in spec §7 F.1(b) is wrong (the coordinator confirmed this; the spec will be amended).** The spec says "the picker scanner's teardown ends BLE's freshly restarted scan". `MeshtasticScanner` never calls `stopScan`. It only cancels its task (`MeshtasticKit/Sources/MeshtasticKit/MeshtasticScanner.swift:11-26`), which reaches FCB's token-scoped `endScan` (`FCB/…/BluetoothCentralClient+Live.swift:212-213, 475-480`). Probe R3 tore down a scanner after BLE restarted, and BLE kept scanning. F.1 really covers three mechanisms, and this plan fixes all three:
   - **(a) The global `stopScan()` kills another caller's scan.** In ReTiCA it is reached from `resetSession` (`FCBDriverAdapter.swift:276`) on the STOP path and also on the START path (`begin` `:137` → `resetSession` → `:276`). Fix: FCB Task 1 (no-op `stopScan`) and ReTiCA Task 4 (removes the call).
   - **(b) Supersession silently orphans the previous scan.** `scan()` starts through an unordered `Task { await self.startScan(…) }` (`:211`), and `startScan` unconditionally replaces `scanContinuation`/`currentScanToken` (`:466-470`). A scan whose start task runs late takes the radio, and the scan it replaced never yields again and never finishes. BLE then looks "online" but is not discovering. The same unordered start/end tasks also let a stream that terminated before its own start leave an ownerless radio scan running (probe C). Fix: FCB Task 1. The superseded stream FINISHES, and an end that arrives before its start prevents that start. ReTiCA Task 5: the adapter reacts to its scan stream finishing unexpectedly. MeshtasticKit Task 7: the scanner reacts.
   - **(c) The adapter's stale teardown wipes the new session.** The app sends `.stop` when the picker opens and `.start` when it closes. `BLEInterface` runs the stop as an un-ordered effect (`BLEInterface.swift:132`). If that stop is still disconnecting a peer, the new session comes up first. The old `resetSession` then resumes and runs `central.stopScan()` (`:276`), `peripheral.stopAdvertising()`/`removeAll()` (`:277-278`) and `continuation?.finish()` (`:283`) against the NEW session. Probe R2 showed the new session's scan killed and its event stream finished. `BLEInterface.startDriver` (`BLEInterface.swift:399-406`) ignores a finished driver stream, so BLE stays "online" and dead. Fix: Task 4, in `FCBDriverAdapter`, which is lane F's file.
2. **`stopScan` is kept as a no-op rather than removed or token-scoped.** FCB's main lands first and is shared through relative paths. ReTiCA main, lane E's concurrent worktree, MultiRouter, and four older ReTiCA worktrees all call or stub `stopScan`, so removing it would break their builds until each is migrated. Deprecating it is not possible either. `@available(*, deprecated)` on a `@DependencyClient` property raises a warning inside FCB's own macro expansion (`macro expansion @DependencyClient:24:10`) that no consumer can silence. A no-op satisfies "a caller can only stop its own scan" for every caller. Probe K confirmed that a consumer which `break`s out of its scan loop still ends its scan once it drops the stream.
3. **The power-off fix also forgets FCB's peripheral cache.** The spec did not mention this. Probe F1: after a power cycle, `connect(id)` re-used the cached `CBMPeripheral`, which CBM had forgotten (`CBMCentralManagerMock.swift:80-94`), and the connect hung forever. Apple's `centralManagerDidUpdateState` contract says the same holds on iOS: every peripheral object becomes invalid. The characteristic cache goes too. A read through a stale characteristic after reconnecting without rediscovery also hung under mutation.
4. **"A new pending op for an occupied slot fails the old one" applies to the five slots that overwrote:** connect, discoverServices, discoverCharacteristics, write-with-response, setNotify. `readValue` and `openL2CAPChannel` already reject the NEW call with `operationCancelled` (`Live.swift:313-315`, `:365-367`). They never leaked, so they stay as they are and are documented. The stale-read symptom came from power-off, which item 2 fixes.
5. **Superseded streams FINISH; FCB does not multiplex scans (decision).** Multiplexing (one radio scan with the union of service filters, fanned out per stream) would let BLE and the picker scan together, but it costs more than it saves:
   - `allowDuplicates` must be unioned. BLE needs duplicates and the picker does not, so FCB would need per-stream de-duplication.
   - iOS background scanning needs a non-nil service filter, and a union with any nil filter turns background scanning off for every owner.
   - Per-stream filtering must match the advertised and the overflow-area service UUIDs, and CBM cannot exercise the overflow area.
   - Lane D's design already serialises ownership: the app stops BLE while the picker is open.

   FCB therefore keeps its documented contract, "one radio scan per central". Finishing the superseded stream makes losing the radio observable, and each owner decides what to do:
   - **ReTiCA `FCBDriverAdapter` (Task 5):** if the stream ends un-cancelled while Bluetooth is still `.poweredOn`, the adapter fires `.unavailable(.other("scan superseded by another scanner"))`. The cause is transient (`BLEDriver.swift:36-41`). `BLEInterface` (`:354-381`) therefore leaves `.online` for `.waitingForAdapter`, retries after 5 s with doubling backoff up to 120 s, and the restart scans again. If Bluetooth went off instead, it does nothing: `handleCentralState` reports `.poweredOff`, and the next `.poweredOn` scans again (`:165-170`). A repeat `.poweredOn` first cancels the adapter's own previous scan task, so replacing its own scan never reads as a loss.
   - **MeshtasticKit `MeshtasticScanner` (Task 7):** off → wait for power and scan again. On → finish for good. ReTiCaMsgr's picker shows "scan ended".

   Interaction to note for lane E: if the app ever leaves BLE running while the picker scans, BLE's retry takes the radio back after its backoff, and the picker's scan ends visibly. Both outcomes are observable, and neither is silent.
6. **Added (not in the spec):** a scan requested while Bluetooth is not `.poweredOn` finishes at once. CoreBluetooth drops such a scan, so the stream used to stay open and silent. When Bluetooth leaves `.poweredOn`, the current scan stream finishes too.

## Global Constraints

- **Repos and order (no exceptions):** Part 1 FCB, in worktree `/Users/ell/development/ios/pods/FCB-scan-ownership` on branch `scan-ownership`. Then fast-forward FCB `main`. Part 2 ReTiCA, in worktree `/Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership` on branch `fcb-scan-ownership`. Then fast-forward ReTiCA `main`. Part 3 MeshtasticKit, committed straight to its `main` (it has no worktree convention; lane A committed to main). Part 4 runs every consumer suite. ReTiCA, MeshtasticKit and MeshtastifiedKit reach FCB by relative path, and so does ReTiCaMsgrCore through ReTiCA. `pods/ReTiCA-worktrees/FCB` is a **symlink to the FCB main checkout**. Consumer work therefore only sees FCB changes after FCB `main` is fast-forwarded.
- **File ownership in ReTiCA:** lane E is working concurrently in `pods/ReTiCA-worktrees/meshtastic-integration` and owns `Meshtastic*`, `Transport.swift` and `Package.swift`. This plan touches only:
  - `Sources/ReTiCAInterfaces/FCBDriverAdapter.swift`
  - `Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift`
  - the new `Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMCoexistenceTests.swift`

  It edits `Package.swift` only as a temporary, reverted mutation in Task 6 and never commits that edit.
- **FCB main checkout has the user's uncommitted Example changes** (`Example/…` modified/untracked). Never stage, stash, reset or check out anything under `Example/` in `/Users/ell/development/ios/pods/FCB`. `git merge --ff-only` is safe because this plan touches no file under `Example/`. Never mutate files in the FCB main checkout. Task 6's FCB mutations happen in a throwaway copy under `/tmp/fcb-scan-ownership/mut/`, because lane E builds against FCB main concurrently.
- **Shell rule (user):** exactly ONE command per Bash call. No `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, heredocs, `python -c`/`bash -c`/`node -e`. Anything multi-step goes in a script file run as one command. Temp files go under `/tmp/<worktree-basename>/`:
  - `/tmp/FCB-scan-ownership/` for Part 1
  - `/tmp/fcb-scan-ownership/` for Part 2
  - `/tmp/MeshtasticKit/` for Part 3
  - `/tmp/ReTiCA/` for Part 4

  Create each with `mkdir -p` once. Write files (including commit messages) with the Write tool, never `echo >`/`cat >`. Redirecting a real command's output to a file (`swift test … > /tmp/x/log.txt 2>&1`) is allowed, and so is `cp`/`rsync`.
- **Test-verification rule (user), for every new or changed test set, before committing:**
  - (a) Run the tests. All must pass.
  - (b) Apply the task's listed production-code mutations and run. Every new test must fail.
  - (c) Revert every mutation and run. All must pass.

  Only then commit. Each task lists its mutation batches and, per test, which mutation must fail it. Read the failure messages and confirm each test failed **for its own clause** (lane A's lesson: batches mask each other). When two clauses would mask each other, the task splits them into separate batches and says why. If a test still passes under its mutation, it is broken: fix it and restart at (a). If anything surprises you, stop and diagnose.
- **Bounded waits:** every "must not hang" assertion goes through a bounded helper, so a regression fails instead of hanging the run:
  - FCB: `outcome(within:)`, `eventually(within:)`.
  - ReTiCA: `returns(within:)`, `poll(within:)`, `DriverEventLog.first(within:)`.
  - MeshtasticKit: `waitUntil(timeout:)`.

  Never `await` an FCB operation bare in a new test.
- **CBM is process-global:**
  - FCB: every CBM-touching suite nests in `extension CBMBackedTests` (`Tests/FCBComposableTests/CBMBackedTests.swift`) as `@Suite @MainActor`, and starts with `CBMCentralManagerMock.tearDownSimulation()` (the rigs do this).
  - ReTiCA: new CBM tests are members of `extension FCBDriverAdapterCBMTests` (`Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMTests.swift:58`, a `.serialized` suite). Never add a second `@Suite(.serialized)` CBM suite there: two serialized suites still run concurrently with each other, and a probe interfered exactly that way.
  - MeshtasticKit: inside `extension CBMBackedTests` (`Tests/MeshtasticKitTests/Support/CBMSupport.swift:14`).
- **Power cycles in tests:**
  - CBM and CoreBluetooth both read `central.state` when the delegate callback runs. `simulatePowerOff()` immediately followed by `simulatePowerOn()` is therefore delivered as two `.poweredOn` callbacks, and FCB never sees the power-off.
  - Always wait for FCB itself to report `.poweredOff` before powering on. Use FCB's `powerCycle(_:)` helper, or MeshtasticKit's/ReTiCA's sleep plus `waitUntil`.
  - Power-off is reported only as a state change; there is no `didDisconnect`.
  - `retrievePeripherals` returns `[]` unless powered on.
- **Commits:**
  - Stage explicit paths only, never `git add -A`/`.`: every repo has untracked `.build/`, `.swiftpm/`, and FCB has user files.
  - Commit with `git -C <repo-or-worktree> commit -F /tmp/<dir>/commit-msg.txt`. The message file ends with these two lines **at column zero**:
    ```
    Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
    Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
    ```
  - After every commit run `git -C <repo-or-worktree> log -1 "--format=%(trailers:key=Claude-Session)"`. It must print the session URL.
- **Fast-forward each repo's main at the end of its part** with `git -C <main checkout> merge --ff-only <branch>`. If ReTiCA main moved (lane E), rebase the branch onto main in the worktree, re-run the full ReTiCA suite, then fast-forward.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`), matching each repo's existing style. Every `swift test` command below uses an absolute `--package-path`, exactly as written.

## Review Focus

1. **A GATT channel is open when the user switches Bluetooth off.** This is the most common real-world power-off. FCB must end that channel's notification stream with `.poweredOff`. The adapter must then report `channelClosed`, and a later `stop()` must return. → Task 6 `anOpenChannelClosesWhenBluetoothPowersOff`.
2. **A scan is requested while Bluetooth is off or `.unknown`.** CoreBluetooth drops it, so the stream used to stay open and silent forever. Expected: the stream finishes at once, so its owner can wait for power and retry. → Task 1 `aScanRequestedWhileBluetoothIsOffFinishesAtOnce`.
3. **A consumer `break`s out of its scan loop and relies on `stopScan()`** (MultiRouter `LiveMeshtasticOps.swift:59-66`). `stopScan` is now a no-op. Expected: the radio still stops once the stream is dropped. → Task 1 `breakingOutOfTheScanLoopAndDroppingTheStreamStopsTheRadio`.
4. **Two concurrent write-with-response calls to one characteristic** (an unserialised consumer). Expected: nothing hangs. The first throws `operationCancelled` and the second completes. Note that the second may complete on the first write's ack (the slot is per characteristic). That is documented in CLAUDE.md, not hidden. → Task 3 `aSecondWriteWithResponseFailsTheFirstInsteadOfLeakingIt`.
5. **An L2CAP open is pending when Bluetooth powers off** (native only: CBM cannot open L2CAP, `Live.swift:360-364`). Expected: it throws `.poweredOff`. No CBM test can reach this. The reviewer of Task 2 must confirm by reading that `adapterWentDown` drains `pendingOpenL2CAP`. ReTiCA's adapter also bounds the open at 10 s itself (`FCBDriverAdapter.swift:544-582`).

---

## Probe evidence (2026-10-16, live FCB client over CoreBluetoothMock, scratch copies under `/tmp/FCB/`)

| # | Probe | Before the fix | After the fix |
|---|---|---|---|
| A | A newer scan supersedes an older one | older stream never finishes | finishes |
| B | Another owner's `stopScan()` while a second owner scans | second owner's scan ends (`isScanning=false`) | keeps yielding |
| C | Stream terminated before its `startScan` ran | 6/100 random; **10/10** with the deterministic actor-hold test | 0/10 |
| D | Scan stream across a power-off | never finishes, never yields again | finishes |
| E/G/H/H2/H3 | Read / notification stream / write / connect / discoverServices pending at power-off | all **hung** (2 s bound) | all throw `.poweredOff` |
| F1 | `connect` after a power cycle without a retrieve | **hung** (stale cached peripheral) | succeeds |
| F3 | First read after a power cycle + reconnect | threw `operationCancelled` (stale `pendingReads`) | succeeds |
| I/J | Second connect / discoverServices on an occupied slot | first caller **hung** | first throws `operationCancelled` |
| K | `break` out of the scan loop + drop the stream | radio stops | radio stops (no-op `stopScan` is safe) |
| R1 | ReTiCA BLE stop (slow disconnect) while the picker starts its scan | picker scan killed | survives |
| R2 | ReTiCA BLE restart during a slow stop | new session's scan killed **and** its event stream finished | both survive (needs Task 4) |
| R3 | Scanner-style teardown after BLE restarted | BLE kept scanning (spec mechanism disproved) | — |
| R4 | `readIdentity` with a power-off mid-read, then power on | hung, then `identityFailed("operationCancelled")` | `identityFailed("poweredOff")`, then `identityRead` |

With FCB fixed, MeshtasticKit (64→66 with Task 7), MeshtastifiedKit (283) and ReTiCAInterfacesTests (272→281 with Tasks 4-6) were all green in scratch copies.

## Source map (all line numbers verified 2026-10-16)

- **FCB** `Sources/FCBComposable/BluetoothCentralClient+Live.swift`:
  - `:19` live `stopScan` wiring.
  - `:69-72` `scanContinuation`/`currentScanToken`.
  - `:76-85` pending maps.
  - `:200-216` `scan()` spawns `startScan` and `onTermination → endScan` as two separate Tasks.
  - `:228-233` global `stopScan()`.
  - `:246` `pendingConnect[id] = cont` (overwrite).
  - `:289` and `:304` discovery overwrites.
  - `:313-315` read rejects a new call.
  - `:331` and `:341` write/notify overwrites.
  - `:365-367` L2CAP rejects a new call.
  - `:399-407` `preflightCheck` (BluetoothError for each state).
  - `:466-470` `startScan`.
  - `:475-480` `endScan(token:)`.
  - `:488-492` `handleDidUpdateState` (never fails anything).
  - `:549-572` `failPending(for:with:)` (disconnect only, from b554062).
- **FCB** `Sources/FCBComposable/BluetoothCentralClient.swift:10-11`: `scan`/`stopScan` properties.
- **FCB** `Sources/FCBComposable/Errors/BluetoothError.swift:6`: `.poweredOff` **already exists**. `:14` `.operationCancelled`. No new error case is needed.
- **FCB** `CLAUDE.md:42`: the "Disconnect semantics" bullet. New bullets go after it.
- **FCB tests:**
  - `Tests/FCBComposableTests/CentralDisconnectFailsPendingTests.swift` holds the helpers `outcome(within:)` `:24`, `expectDisconnected` `:55`, `PendingOpsSpecDelegate` `:94`, `CountingCentralManagerMock` `:122`, `expectCompleted` `:181`, `expectThrows` `:197`, `PendingOpsRig` `:212` and `makePendingOpsRig` `:243`, plus `pendingOpsResponseLatency = 0.5` `:82`.
  - `BluetoothCentralClientTests.swift:20-21` defines `cbmBatteryServiceUUID`/`cbmBatteryLevelUUID`, and `:80-87` defines `makeEmptyMockActor`.
  - `FCBMDelegateTests.swift:10` defines `waitForManagerState`.
  - `ScanRaceTests.swift` holds the existing token-guard test (stays green).
- **CBM** `.build/checkouts/IOS-CoreBluetooth-Mock/CoreBluetoothMock/CBMCentralManagerMock.swift`:
  - `:80-104` a state change away from `.poweredOn` stops scanning, closes and forgets all peripherals, and only calls `centralManagerDidUpdateState`.
  - `:717-720` `connect` ignores a peripheral object the manager no longer holds.
  - `:772` `retrievePeripherals` needs `.poweredOn`.
- **ReTiCA** `Sources/ReTiCAInterfaces/FCBDriverAdapter.swift`:
  - `:214-222` `bringUpCentral` iterates `central.scan` inside a `tasks` Task.
  - `:245-285` `resetSession`: `:247` cancels `tasks` (which terminates the scan stream), `:273` awaits peer disconnects (the slow part), `:276` `central.stopScan()`, `:277-282` peripheral teardown, `:283-284` `continuation?.finish(); continuation = nil`.
  - `:629-631` `stop()`.
- **ReTiCA** `Sources/ReTiCAInterfaces/BLEInterface.swift:118-134` `.stop` (`:132` un-ordered `bleDriver.stop()`). `:399-406` `startDriver` ignores the driver stream ending.
- **ReTiCA tests:**
  - `Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift`: `AdapterCalls.stopScanned` `:66,86`. `AdapterStubs` `:112-153` (last field `openL2CAPHeld` `:152`). Stub `stopScan` `:194`. Stub `disconnect` `:195-203`. `AdapterStubs(...)` init call `:315-329`. `collect` `:361`, `waitUntil(within:)` `:381`, `peer` `:390`, `disc` `:392`, `onlineAdapter` `:398`, `openOutbound` `:411`. `restartRemovesServicesAndStopsAdvertisingBeforeReAdding` `:486-501`, which asserts `stopScanned >= 1` at `:498`.
  - `FCBDriverAdapterCBMTests.swift`: `V22SpecDelegate` `:11`, `noopPeripheralClient()` `:39`, serialized suite `:58-59`.
- **MeshtasticKit:**
  - `Sources/MeshtasticKit/MeshtasticScanner.swift:5-29`.
  - `Sources/MeshtasticKit/MeshtasticSession.swift`: comments at `:37-39`, `:52-53`, `:57-58`, `:181-182` and `:615-617` that describe the FCB defects.
  - Tests: `Tests/MeshtasticKitTests/ScannerTests.swift:66-110` (CBM `ScannerTests`). `Support/SessionSupport.swift:71` `waitUntil(timeout:_:)`. `Support/CBMSupport.swift:29-42` `makeMockRadio`. Defect-describing comments at `SessionSendTests.swift:116-118`, `SessionReconnectTests.swift:77-80`, `:293-296` and `:335-342`.

## Consumer inventory (grep of `stopScan(` and `.scan(` on `BluetoothCentralClient`, across `pods/` and `apps/`)

| Consumer | Scan use | `stopScan` use | Behaviour after this plan | Change |
|---|---|---|---|---|
| FCB `BluetoothCentralClient+Live.swift:19`, `+Preview.swift:24` | — | wiring | no-op | Task 1 |
| FCB `Example/FCBDemoFeatures/.../CentralFeature.swift:74-87` (+ tests `:40,59`) | `.cancellable(id: .scan)` | `stopScan` + `.cancel(id: scan)` | the cancel ends the scan | none (Example is user-dirty, separate package) |
| ReTiCA `FCBDriverAdapter.swift:216` / `:276` | task-iterated | after the slow disconnects | a superseded scan ends its stream → reported as transient `.unavailable(.other)` | **Task 4** (remove the call; owned teardown), **Task 5** (lost-scan reaction) |
| ReTiCA `FCBDriverAdapterTests.swift:86,194,498` | stub | stub counter | asserts `== 0`; stub scan becomes a per-call `ScanFeed` | **Tasks 4, 5** |
| ReTiCA worktrees `default-nodes`, `ignore-list`, `meshtastic-interface`, `node-followups` (same lines) | same | same | compile unchanged (no-op) | none |
| MeshtasticKit `MeshtasticScanner.swift:17` | task-iterated, cancel to stop | **none** | finishes when superseded, rescans after a power cycle | **Task 7** |
| MeshtasticKit `Tests/.../Support/SessionSupport.swift:122` | — | stub `stopScan: {}` | compiles | none |
| MeshtastifiedKit `MeshDeviceClient+Live.swift:120` (`SharedScanner`), `MeshCore/MeshCoreSessionActor.swift:114` | task-iterated | none | a superseded or powered-off scan now *finishes*. SharedScanner then stalls with `scanTask != nil`, exactly as it stalled silently before | none (283 green in a scratch run) |
| MultiRouter `MultiRouterBLE/Internal/LiveCentralOps.swift:69` / `:156` | task-cancelled | after cancelling its task | the cancel ends the scan | none |
| MultiRouter `MultiRouterMeshtastic/Internal/LiveMeshtasticOps.swift:59` / `:66` | `for await … { break }` | after the break | dropping the stream ends the scan (probe K, Review Focus 3) | none |
| MultiRouter tests (~20 `client.stopScan = {}`) | stubs | stubs | compile | none |
| ReTiCaMsgrCore `RadioScanner.swift`/`RadioPickerFeature.swift` | its own client (lane D stub) | none | lane E wires `MeshtasticScanner` | none |
| `pods/core/.../CDLBTListener.swift`, `apps/ux-prototype/.../BLEManager.swift`, `apps/CharCount/.../GameDetectorReducer.swift` | raw CoreBluetooth `CBCentralManager.stopScan()`, not FCB | — | — | none |

## File structure

| File | Repo | Responsibility | Task |
|---|---|---|---|
| `Sources/FCBComposable/BluetoothCentralClient+Live.swift` | FCB | scan retire/early-end/powered-on guard, `stopScan` no-op; `adapterDownError` + `adapterWentDown`; slot supersede | 1, 2, 3 |
| `Sources/FCBComposable/BluetoothCentralClient.swift` | FCB | doc comments for `scan`/`stopScan` | 1 |
| `CLAUDE.md` | FCB | scan-ownership, power-off and occupied-slot semantics | 1, 2, 3 |
| `Tests/FCBComposableTests/ScanOwnershipTests.swift` (new) | FCB | scan rig + 5 tests | 1 |
| `Tests/FCBComposableTests/CentralPowerOffFailsPendingTests.swift` (new) | FCB | power-cycle rig + 13 tests | 2 |
| `Tests/FCBComposableTests/CentralOccupiedSlotTests.swift` (new) | FCB | 5 tests | 3 |
| `Sources/ReTiCAInterfaces/FCBDriverAdapter.swift` | ReTiCA | `resetSession` owns only its session; reports a scan lost to another owner | 4, 5 |
| `Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift` | ReTiCA | `disconnectHeld` stub knob; 2 new stub tests; 1 assertion flipped; per-call `ScanFeed` | 4, 5 |
| `Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMCoexistenceTests.swift` (new) | ReTiCA | shared-central rig + 7 CBM tests (in `FCBDriverAdapterCBMTests`) | 4, 5, 6 |
| `Sources/MeshtasticKit/MeshtasticScanner.swift` | MeshtasticKit | rescan after a power cycle, finish when superseded | 7 |
| `Sources/MeshtasticKit/MeshtasticSession.swift`, `Tests/.../SessionSendTests.swift`, `Tests/.../SessionReconnectTests.swift` | MeshtasticKit | comments only (FCB-defect claims now false) | 7 |
| `Tests/MeshtasticKitTests/ScannerTests.swift` | MeshtasticKit | 2 new CBM tests | 7 |

---

# Part 1 — FCB (worktree `/Users/ell/development/ios/pods/FCB-scan-ownership`)

### Task 1: Scan ownership in FCB

**Files:**
- Modify: `/Users/ell/development/ios/pods/FCB-scan-ownership/Sources/FCBComposable/BluetoothCentralClient+Live.swift` (`:19`, `:69-72`, `:228-233`, `:466-480`)
- Modify: `/Users/ell/development/ios/pods/FCB-scan-ownership/Sources/FCBComposable/BluetoothCentralClient.swift:10-11`
- Modify: `/Users/ell/development/ios/pods/FCB-scan-ownership/CLAUDE.md:42` (append a bullet after it)
- Create: `/Users/ell/development/ios/pods/FCB-scan-ownership/Tests/FCBComposableTests/ScanOwnershipTests.swift`

**Interfaces:**
- Consumes: existing test helpers `waitForManagerState(_:toReach:)`, `makeEmptyMockActor(state:)`, `cbmBatteryServiceUUID`, `cbmBatteryLevelUUID`, `CBMBackedTests`.
- Produces (later tasks rely on these exact names):
  - `CentralActor.retireCurrentScan()`: private. It finishes the current scan stream without touching the radio. Task 2 calls it from `adapterWentDown`.
  - Test helpers `ScanConsumer` (`init(_ stream: AsyncStream<DiscoveredPeripheral>)`, `discoveries: LockIsolated<Int>`, `ended: LockIsolated<Bool>`, `cancel()`), `eventually(within seconds: Double, _ condition: @Sendable () -> Bool) async -> Bool`, `struct ScanRig { actor; client; manager }`, and `@MainActor func makeScanRig() async -> ScanRig`.
  - `extension CentralActor { func occupyForTesting(seconds: Double) }` (test-only).

- [ ] **Step 1: Create the worktree, temp dir and baselines**

Run each as its own command:
```
git -C /Users/ell/development/ios/pods/FCB worktree add ../FCB-scan-ownership -b scan-ownership
mkdir -p /tmp/FCB-scan-ownership
swift test --package-path /Users/ell/development/ios/pods/FCB-scan-ownership > /tmp/FCB-scan-ownership/baseline-fcb.txt 2>&1
swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit > /tmp/FCB-scan-ownership/baseline-meshtastickit.txt 2>&1
swift test --package-path /Users/ell/development/ios/apps/Meshtastified/MeshtastifiedKit > /tmp/FCB-scan-ownership/baseline-meshtastifiedkit.txt 2>&1
swift test --package-path /Users/ell/development/ios/pods/MultiRouter > /tmp/FCB-scan-ownership/baseline-multirouter.txt 2>&1
```
Expected:
- FCB: `Test run with 122 tests in 27 suites passed … with 3 known issues`.
- MeshtasticKit: 64 passed. MeshtastifiedKit: 283 passed.
- MultiRouter: record whatever it prints. It is dormant, and its baseline is unknown. Part 4 compares against this file.

Check each with `grep -n "Test run with" <file>`. If FCB, MeshtasticKit or MeshtastifiedKit is not green before any change, STOP and report.

- [ ] **Step 2: Write the failing tests**

Create `Tests/FCBComposableTests/ScanOwnershipTests.swift`:

```swift
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
import Foundation
import Testing
@testable import FCBComposable

// MARK: - Scan rig

/// Drains one scan stream in the background, counting discoveries and noting
/// when the stream ends (finished by FCB, or cancelled by `cancel()`).
final class ScanConsumer: @unchecked Sendable {
    let discoveries = LockIsolated(0)
    let ended = LockIsolated(false)
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<DiscoveredPeripheral>) {
        let discoveries = discoveries
        let ended = ended
        task = Task {
            for await _ in stream { discoveries.withValue { $0 += 1 } }
            ended.setValue(true)
        }
    }

    func cancel() { task?.cancel() }
}

/// Polls `condition` every 10 ms for at most `seconds`.
func eventually(within seconds: Double, _ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<Int(seconds * 100) {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

struct ScanRig {
    let actor: CentralActor
    let client: BluetoothCentralClient
    let manager: CBMCentralManager
}

/// One battery-service peripheral advertising every 50 ms behind a fresh mock
/// manager wrapped in the live client.
@MainActor
func makeScanRig() async -> ScanRig {
    CBMCentralManagerMock.tearDownSimulation()
    CBMCentralManagerMock.simulateInitialState(.poweredOn)
    let characteristic = CBMCharacteristicMock(type: cbmBatteryLevelUUID, properties: [.read])
    let service = CBMServiceMock(type: cbmBatteryServiceUUID, primary: true, characteristics: characteristic)
    let spec = CBMPeripheralSpec
        .simulatePeripheral(identifier: UUID(), proximity: .near)
        .advertising(advertisementData: [
            CBMAdvertisementDataLocalNameKey: "ScanDev",
            CBMAdvertisementDataServiceUUIDsKey: [cbmBatteryServiceUUID],
            CBMAdvertisementDataIsConnectable: NSNumber(value: true),
        ], withInterval: 0.05)
        .connectable(name: "ScanDev", services: [service], delegate: nil, connectionInterval: 0.01)
        .allowForRetrieval()
        .build()
    CBMCentralManagerMock.simulatePeripherals([spec])
    let manager = CBMCentralManagerFactory.instance(forceMock: true)
    await waitForManagerState(manager, toReach: .poweredOn)
    let actor = CentralActor(manager: manager)
    return ScanRig(actor: actor, client: BluetoothCentralClient.makeClient(actor: actor), manager: manager)
}

extension CentralActor {
    /// Test-only: blocks this actor's executor, so jobs enqueued meanwhile
    /// queue up behind it and then run in priority order.
    func occupyForTesting(seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }
}

// MARK: - Tests

extension CBMBackedTests {
    @Suite @MainActor
    struct ScanOwnershipTests {
        /// Open side of the radio-picker race: a slow owner's late `stopScan()`
        /// used to end whatever scan was current — the picker's.
        @Test func stopScanDoesNotEndAnotherOwnersScan() async {
            let rig = await makeScanRig()
            let options = ScanOptions(allowDuplicates: true)
            let first = ScanConsumer(rig.client.scan([cbmBatteryServiceUUID], options))
            #expect(await eventually(within: 2) { first.discoveries.value > 0 })
            let second = ScanConsumer(rig.client.scan([cbmBatteryServiceUUID], options))
            #expect(await eventually(within: 2) { second.discoveries.value > 0 })

            await rig.client.stopScan()   // the first owner's late, global stop
            try? await Task.sleep(nanoseconds: 100_000_000)

            let before = second.discoveries.value
            #expect(await eventually(within: 1) { second.discoveries.value > before },
                    "the second owner's scan must keep yielding")
            #expect(!second.ended.value)
            #expect(rig.manager.isScanning)
            first.cancel()
            second.cancel()
        }

        /// A newer scan supersedes the radio; the older stream FINISHES so its
        /// owner can tell it lost the scan (it used to go quiet forever).
        @Test func aNewerScanFinishesTheSupersededStream() async {
            let rig = await makeScanRig()
            let options = ScanOptions(allowDuplicates: true)
            let older = ScanConsumer(rig.client.scan([cbmBatteryServiceUUID], options))
            #expect(await eventually(within: 2) { older.discoveries.value > 0 })
            let newer = ScanConsumer(rig.client.scan([cbmBatteryServiceUUID], options))
            #expect(await eventually(within: 2) { newer.discoveries.value > 0 })

            #expect(await eventually(within: 1) { older.ended.value },
                    "the superseded stream must finish")
            let before = newer.discoveries.value
            #expect(await eventually(within: 1) { newer.discoveries.value > before },
                    "the superseded stream's termination must not stop the newer scan")
            older.cancel()
            newer.cancel()
        }

        /// `scan()` starts the radio and its stream's termination stops it in two
        /// separate tasks. When the termination reaches the actor first, the
        /// start must not run a radio scan nobody owns. Deterministic: the actor
        /// is held busy while both jobs queue, the end at a higher priority.
        @Test func aStreamEndedBeforeItsScanStartedNeverStartsTheRadio() async {
            let rig = await makeScanRig()
            let actor = rig.actor
            var ownerlessScans = 0
            for _ in 0..<10 {
                let hold = Task.detached(priority: .high) { await actor.occupyForTesting(seconds: 0.2) }
                try? await Task.sleep(nanoseconds: 50_000_000)
                let stream = await Task.detached(priority: .background) {
                    actor.scan(services: [cbmBatteryServiceUUID], options: nil)
                }.value
                let consumer = Task(priority: .high) { for await _ in stream {} }
                try? await Task.sleep(nanoseconds: 10_000_000)
                consumer.cancel()
                _ = await consumer.value
                await hold.value
                try? await Task.sleep(nanoseconds: 50_000_000)
                if rig.manager.isScanning { ownerlessScans += 1 }
                rig.manager.stopScan()   // reset for the next round
            }
            #expect(ownerlessScans == 0)
        }

        /// CoreBluetooth drops a scan issued while Bluetooth is not powered on;
        /// the stream used to stay open forever, yielding nothing.
        @Test func aScanRequestedWhileBluetoothIsOffFinishesAtOnce() async {
            let actor = await makeEmptyMockActor(state: .poweredOff)
            let scan = ScanConsumer(actor.scan(services: [cbmBatteryServiceUUID], options: nil))
            #expect(await eventually(within: 1) { scan.ended.value })
            scan.cancel()
        }

        /// `stopScan()` is a no-op now, so a consumer that `break`s out of its
        /// scan loop relies on dropping the stream to end its scan (MultiRouter's
        /// LiveMeshtasticOps does exactly this).
        @Test func breakingOutOfTheScanLoopAndDroppingTheStreamStopsTheRadio() async {
            let rig = await makeScanRig()
            let client = rig.client
            func firstDiscovery() async -> UUID? {
                let stream = client.scan([cbmBatteryServiceUUID], nil)
                for await discovered in stream { return discovered.peripheral.id }
                return nil
            }
            #expect(await firstDiscovery() != nil)
            #expect(await eventually(within: 1) { !rig.manager.isScanning })
        }
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/FCB-scan-ownership --filter ScanOwnershipTests > /tmp/FCB-scan-ownership/t1-red.txt 2>&1`
then `grep -n "recorded an issue\|passed after\|Test run with" /tmp/FCB-scan-ownership/t1-red.txt`.
Expected:
- FAIL: `stopScanDoesNotEndAnotherOwnersScan` (`isScanning` false), `aNewerScanFinishesTheSupersededStream`, `aStreamEndedBeforeItsScanStartedNeverStartsTheRadio` (10 ownerless scans) and `aScanRequestedWhileBluetoothIsOffFinishesAtOnce`.
- PASS: `breakingOutOfTheScanLoopAndDroppingTheStreamStopsTheRadio`. It pins existing behaviour. Its mutation is batch B in Step 6.

- [ ] **Step 4: Implement**

In `BluetoothCentralClient+Live.swift`:

(4a) `makeClient`, replace `stopScan: { await actor.stopScan() },` with:
```swift
            // Does nothing: a scan stops when ITS stream terminates (see BluetoothCentralClient.stopScan).
            stopScan: { },
```

(4b) Below `private var currentScanToken: UUID?` (`:72`), add:
```swift
    /// Scans FCB itself ended (superseded by a newer scan, or Bluetooth left
    /// `.poweredOn`) whose stream's `endScan` has not arrived yet.
    private var retiredScanTokens: Set<UUID> = []
    /// Scans whose stream terminated before their `startScan` ran (the two are
    /// separate tasks and can reach the actor in either order).
    private var scanTokensEndedBeforeStart: Set<UUID> = []
```

(4c) Delete the whole `func stopScan() async { … }` (`:228-233`).

(4d) Replace `startScan` and `endScan` (`:466-480`, including `endScan`'s doc comment) with:
```swift
    private func startScan(services: [CBUUID]?, options: ScanOptions?, continuation: AsyncStream<DiscoveredPeripheral>.Continuation, token: UUID) {
        // The consumer already let go of this stream: never start a radio scan
        // nobody owns.
        if scanTokensEndedBeforeStart.remove(token) != nil {
            continuation.finish()
            return
        }
        // CoreBluetooth drops a scan issued while not powered on; a stream that
        // can never yield ends at once instead of going quiet.
        guard manager.state == .poweredOn else {
            continuation.finish()
            return
        }
        // One radio scan per central: the newer scan supersedes, and the older
        // stream FINISHES so its owner can tell it lost the radio.
        retireCurrentScan()
        scanContinuation = continuation
        currentScanToken = token
        manager.scanForPeripherals(withServices: services, options: options?.dictionary)
    }

    /// A scan stream terminated. Stops the radio ONLY when `token` is the
    /// current scan; a superseded (retired) stream's late `endScan` is ignored,
    /// and one that arrives before its own `startScan` is remembered so that
    /// start never happens.
    private func endScan(token: UUID) {
        if currentScanToken == token {
            manager.stopScan()
            scanContinuation = nil
            currentScanToken = nil
        } else if retiredScanTokens.remove(token) == nil {
            scanTokensEndedBeforeStart.insert(token)
        }
    }

    /// Finishes the current scan's stream without touching the radio (the
    /// caller starts a newer scan, or CoreBluetooth already stopped scanning).
    private func retireCurrentScan() {
        guard let token = currentScanToken else { return }
        let outgoing = scanContinuation
        scanContinuation = nil
        currentScanToken = nil
        retiredScanTokens.insert(token)
        outgoing?.finish()   // its onTermination → endScan(token) consumes the retired token
    }
```

(4e) In `BluetoothCentralClient.swift`, replace lines `:10-11` with:
```swift
    /// Scans for peripherals advertising `services`. One radio scan per central:
    /// a newer `scan` supersedes this one and FINISHES this stream (its owner lost
    /// the radio). The stream also finishes when Bluetooth leaves `.poweredOn`
    /// (CoreBluetooth stops scanning and never resumes), and at once when the scan
    /// is requested while not powered on. Terminating the stream — cancelling the
    /// task iterating it, or dropping it — stops THIS scan only.
    public var scan: @Sendable (_ services: [CBUUID]?, _ options: ScanOptions?) -> AsyncStream<DiscoveredPeripheral> = { _, _ in .never }
    /// Does nothing; kept for source compatibility. A global stop ended whatever
    /// scan was current — another owner's included. Stop your own scan by
    /// terminating its stream (cancel the task iterating it).
    public var stopScan: @Sendable () async -> Void
```

(4f) In `CLAUDE.md`, insert after the "**Disconnect semantics:**" bullet (`:42`):
```markdown
- **Scan ownership:** one radio scan per `CentralActor` (per client value; `liveValue` is one, each `.mocked()` call is another). A newer `scan` supersedes the current one and FINISHES the superseded stream. Terminating a stream (cancel the task iterating it, or drop it) stops that scan only: a superseded stream's late termination is ignored, and a termination that reaches the actor before its own start prevents that start. A scan requested while not `.poweredOn` finishes at once. `stopScan` does nothing (kept for source compatibility) — a global stop used to end another owner's scan.
```

- [ ] **Step 5: Run the tests to verify they pass, plus the whole suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/FCB-scan-ownership > /tmp/FCB-scan-ownership/t1-green.txt 2>&1`
then `grep -n "recorded an issue\|Test run with" /tmp/FCB-scan-ownership/t1-green.txt`.
Expected: `Test run with 127 tests … passed … with 3 known issues`. The only issues should be the three pre-existing `testValue…` known issues.

- [ ] **Step 6: Mutation batches. Two batches, because M5 also breaks the early-end test and would mask M3**

**Batch A** (apply all four, then run once):
- M1: in `makeClient`, `stopScan: { },` → `stopScan: { await actor.mutationStopAll() },`, and add inside `CentralActor` (anywhere): `func mutationStopAll() { manager.stopScan(); retireCurrentScan() }`
- M2: in `startScan`, delete the line `retireCurrentScan()`.
- M3: in `startScan`, delete the `if scanTokensEndedBeforeStart.remove(token) != nil { continuation.finish(); return }` block.
- M4: in `startScan`, change `guard manager.state == .poweredOn else {` to `guard true || manager.state == .poweredOn else {`.

Run: `swift test --package-path /Users/ell/development/ios/pods/FCB-scan-ownership --filter ScanOwnershipTests > /tmp/FCB-scan-ownership/t1-mutA.txt 2>&1`, then `grep -n "recorded an issue\|passed after" /tmp/FCB-scan-ownership/t1-mutA.txt`. Expected:
- FAIL `stopScanDoesNotEndAnotherOwnersScan` (M1: "the second owner's scan must keep yielding").
- FAIL `aNewerScanFinishesTheSupersededStream` (M2: "the superseded stream must finish").
- FAIL `aStreamEndedBeforeItsScanStartedNeverStartsTheRadio` (M3: `ownerlessScans → 10`).
- FAIL `aScanRequestedWhileBluetoothIsOffFinishesAtOnce` (M4).
- PASS `breakingOutOfTheScanLoopAndDroppingTheStreamStopsTheRadio` (not targeted by batch A).

Each test is sensitive only to its own mutation by construction. If any fails with a different message, stop and diagnose.

Revert batch A exactly: restore `stopScan: { },`, delete `mutationStopAll`, re-add the `retireCurrentScan()` line, the early-end block and the guard as in Step 4d.

**Batch B:**
- M5: in `endScan`, delete `manager.stopScan()` inside `if currentScanToken == token {`.

Run: `swift test --package-path /Users/ell/development/ios/pods/FCB-scan-ownership --filter ScanOwnershipTests > /tmp/FCB-scan-ownership/t1-mutB.txt 2>&1`, then grep as above. Expected:
- FAIL `breakingOutOfTheScanLoopAndDroppingTheStreamStopsTheRadio`.
- FAIL `aStreamEndedBeforeItsScanStartedNeverStartsTheRadio` too (expected: the end no longer stops the radio).

Revert M5.

- [ ] **Step 7: Run again to confirm green after reverting**

Run: `swift test --package-path /Users/ell/development/ios/pods/FCB-scan-ownership > /tmp/FCB-scan-ownership/t1-green2.txt 2>&1`, then `grep -n "recorded an issue\|Test run with" /tmp/FCB-scan-ownership/t1-green2.txt`. Expected: 127 tests passed with 3 known issues.

- [ ] **Step 8: Commit**

Write `/tmp/FCB-scan-ownership/commit-msg.txt`:
```
fix: a scan's owner can stop only its own scan

stopScan() ended whatever scan was current, so a slow owner's late stop
killed another owner's freshly started scan (ReTiCA's BLE stop vs the
Meshtastic radio picker). Stream termination is now the only stop and
stopScan is a source-compatible no-op. A superseded scan's stream
finishes instead of going quiet, a termination that reaches the actor
before its own start prevents that start, and a scan requested while
Bluetooth is not powered on finishes at once.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run each as its own command:
```
git -C /Users/ell/development/ios/pods/FCB-scan-ownership add Sources/FCBComposable/BluetoothCentralClient+Live.swift Sources/FCBComposable/BluetoothCentralClient.swift CLAUDE.md Tests/FCBComposableTests/ScanOwnershipTests.swift
git -C /Users/ell/development/ios/pods/FCB-scan-ownership commit -F /tmp/FCB-scan-ownership/commit-msg.txt
git -C /Users/ell/development/ios/pods/FCB-scan-ownership log -1 "--format=%(trailers:key=Claude-Session)"
```
Expected: the last command prints `Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm`.

---

### Task 2: Bluetooth leaving `.poweredOn` fails every pending operation

**Files:**
- Modify: `/Users/ell/development/ios/pods/FCB-scan-ownership/Sources/FCBComposable/BluetoothCentralClient+Live.swift` (`handleDidUpdateState`, `:488-492` before Task 1's shift)
- Modify: `/Users/ell/development/ios/pods/FCB-scan-ownership/CLAUDE.md` (append a bullet after the Task 1 bullet)
- Create: `/Users/ell/development/ios/pods/FCB-scan-ownership/Tests/FCBComposableTests/CentralPowerOffFailsPendingTests.swift`

**Interfaces:**
- Consumes:
  - From Task 1: `retireCurrentScan()`, `ScanConsumer`, `eventually(within:_:)`, `makeScanRig()`.
  - Existing helpers: `outcome(within:_:)`, `expectThrows(_:_:)`, `expectCompleted(_:_:)`, `PendingOpsRig` (incl. `connectAndDiscover()`), `PendingOpsSpecDelegate` (`readRequests`, `serviceDiscoveryRequests`), `makePendingOpsRig(inRange:makeManager:)`, `CountingCentralManagerMock` (`cancelCount`, `ignoresCancel`), `pendingOpsResponseLatency`, `makeEmptyMockActor`, `waitForManagerState`.
- Produces:
  - `static func CentralActor.adapterDownError(_ state: CBMManagerState) -> BluetoothError?` (internal).
  - `private func adapterWentDown(with error: BluetoothError)`.
  - `private static func drain<Key, Value>(_ map: inout [Key: Value], _ body: (Value) -> Void)`.
  - Test helpers `@MainActor func makePowerCycleRig() async -> PendingOpsRig` and `@MainActor func powerCycle(_ client: BluetoothCentralClient) async`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FCBComposableTests/CentralPowerOffFailsPendingTests.swift`:

```swift
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
import Foundation
import Testing
@testable import FCBComposable

// MARK: - Power-cycle rig

/// A connectable, advertising, retrievable battery peripheral that answers
/// every GATT request after `pendingOpsResponseLatency`, behind a fresh mock
/// manager wrapped in the live client. Unlike `makePendingOpsRig(inRange: true)`
/// (a peripheral "connected by another app", which does not advertise), this
/// one can be found and connected again after Bluetooth comes back on.
@MainActor
func makePowerCycleRig() async -> PendingOpsRig {
    CBMCentralManagerMock.tearDownSimulation()
    CBMCentralManagerMock.simulateInitialState(.poweredOn)
    let id = UUID()
    let specDelegate = PendingOpsSpecDelegate()
    let characteristic = CBMCharacteristicMock(type: cbmBatteryLevelUUID, properties: [.read, .write, .notify])
    let service = CBMServiceMock(type: cbmBatteryServiceUUID, primary: true, characteristics: characteristic)
    let spec = CBMPeripheralSpec
        .simulatePeripheral(identifier: id, proximity: .near)
        .advertising(advertisementData: [
            CBMAdvertisementDataLocalNameKey: "PowerDev",
            CBMAdvertisementDataServiceUUIDsKey: [cbmBatteryServiceUUID],
            CBMAdvertisementDataIsConnectable: NSNumber(value: true),
        ], withInterval: 0.05)
        .connectable(name: "PowerDev", services: [service], delegate: specDelegate,
                     connectionInterval: pendingOpsResponseLatency)
        .allowForRetrieval()
        .build()
    CBMCentralManagerMock.simulatePeripherals([spec])
    let manager = CBMCentralManagerFactory.instance(forceMock: true)
    await waitForManagerState(manager, toReach: .poweredOn)
    let client = BluetoothCentralClient.makeClient(actor: CentralActor(manager: manager))
    return PendingOpsRig(client: client, manager: manager, spec: spec, specDelegate: specDelegate,
                         characteristic: characteristic, id: id)
}

/// Turns Bluetooth off, waits until FCB itself has handled `.poweredOff`, then
/// turns it on and waits for FCB's `.poweredOn`. Waiting on FCB's state stream
/// (not the manager's `state`) matters: CBM, like CoreBluetooth, reads
/// `central.state` when the delegate callback runs, so an off immediately
/// followed by on is delivered as two `.poweredOn` callbacks and FCB never
/// sees the power-off at all.
@MainActor
func powerCycle(_ client: BluetoothCentralClient) async {
    let cycled = await outcome(within: 3) {
        var states = client.state().makeAsyncIterator()
        _ = await states.next()   // the replayed current state
        CBMCentralManagerMock.simulatePowerOff()
        while let state = await states.next(), state != .poweredOff {}
        CBMCentralManagerMock.simulatePowerOn()
        while let state = await states.next(), state != .poweredOn {}
        return true
    }
    expectCompleted(cycled, "the power cycle")
}

// MARK: - Tests

struct AdapterDownErrorTests {
    @Test func everyStateButPoweredOnMapsToTheErrorPendingOperationsFailWith() {
        #expect(CentralActor.adapterDownError(.poweredOn) == nil)
        #expect(CentralActor.adapterDownError(.poweredOff) == .poweredOff)
        #expect(CentralActor.adapterDownError(.resetting) == .poweredOff)
        #expect(CentralActor.adapterDownError(.unknown) == .poweredOff)
        #expect(CentralActor.adapterDownError(.unsupported) == .unsupported)
        #expect(CentralActor.adapterDownError(.unauthorized) == .unauthorized(CBManager.authorization))
    }
}

extension CBMBackedTests {
    @Suite @MainActor
    struct CentralPowerOffFailsPendingTests {
        @Test func readPendingAtPowerOffThrowsPoweredOff() async throws {
            let rig = await makePendingOpsRig()
            try await rig.connectAndDiscover()
            let client = rig.client, id = rig.id
            let read = Task { await outcome(within: 2) { try await client.readValue(id, cbmBatteryLevelUUID) } }
            try? await Task.sleep(nanoseconds: 50_000_000)
            #expect(rig.specDelegate.readRequests == 1)   // in flight at the peripheral
            CBMCentralManagerMock.simulatePowerOff()
            expectThrows(await read.value, .poweredOff)
        }

        @Test func writePendingAtPowerOffThrowsPoweredOff() async throws {
            let rig = await makePendingOpsRig()
            try await rig.connectAndDiscover()
            let client = rig.client, id = rig.id
            let write = Task {
                await outcome(within: 2) { try await client.writeValue(Data([0x01]), id, cbmBatteryLevelUUID, .withResponse) }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            CBMCentralManagerMock.simulatePowerOff()
            expectThrows(await write.value, .poweredOff)
        }

        @Test func setNotifyPendingAtPowerOffThrowsPoweredOff() async throws {
            let rig = await makePendingOpsRig()
            try await rig.connectAndDiscover()
            let client = rig.client, id = rig.id
            let notify = Task { await outcome(within: 2) { try await client.setNotify(true, id, cbmBatteryLevelUUID) } }
            try? await Task.sleep(nanoseconds: 50_000_000)
            CBMCentralManagerMock.simulatePowerOff()
            expectThrows(await notify.value, .poweredOff)
        }

        @Test func discoverServicesPendingAtPowerOffThrowsPoweredOff() async throws {
            let rig = await makePendingOpsRig()
            _ = try await rig.client.connect(rig.id, ConnectOptions?.none)
            let client = rig.client, id = rig.id
            let discovery = Task { await outcome(within: 2) { try await client.discoverServices(id, [cbmBatteryServiceUUID]) } }
            try? await Task.sleep(nanoseconds: 50_000_000)
            #expect(rig.specDelegate.serviceDiscoveryRequests == 1)
            CBMCentralManagerMock.simulatePowerOff()
            expectThrows(await discovery.value, .poweredOff)
        }

        @Test func discoverCharacteristicsPendingAtPowerOffThrowsPoweredOff() async throws {
            let rig = await makePendingOpsRig()
            _ = try await rig.client.connect(rig.id, ConnectOptions?.none)
            _ = try await rig.client.discoverServices(rig.id, [cbmBatteryServiceUUID])
            let client = rig.client, id = rig.id
            let discovery = Task {
                await outcome(within: 2) { try await client.discoverCharacteristics(id, cbmBatteryServiceUUID, [CBUUID]?.none) }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            CBMCentralManagerMock.simulatePowerOff()
            expectThrows(await discovery.value, .poweredOff)
        }

        @Test func connectPendingAtPowerOffThrowsPoweredOff() async {
            // Out of range: CBM never completes the connect (as iOS, no timeout).
            let rig = await makePendingOpsRig(inRange: false)
            let client = rig.client, id = rig.id
            let connect = Task { await outcome(within: 2) { try await client.connect(id, ConnectOptions?.none) } }
            try? await Task.sleep(nanoseconds: 50_000_000)
            CBMCentralManagerMock.simulatePowerOff()
            expectThrows(await connect.value, .poweredOff)
        }

        @Test func notificationStreamEndsWithPoweredOffAtPowerOff() async throws {
            let rig = await makePendingOpsRig()
            try await rig.connectAndDiscover()
            try await rig.client.setNotify(true, rig.id, cbmBatteryLevelUUID)
            let stream = rig.client.notifications(rig.id, cbmBatteryLevelUUID)
            let iteration = Task { await outcome(within: 2) { for try await _ in stream {}; return true } }
            try? await Task.sleep(nanoseconds: 50_000_000)
            CBMCentralManagerMock.simulatePowerOff()
            expectThrows(await iteration.value, .poweredOff)
        }

        @Test func disconnectPendingAtPowerOffReturns() async throws {
            // The cancel is counted but never answered, so only the power-off can
            // release the waiting disconnect: the link is down, which is what it wanted.
            let rig = await makePendingOpsRig(makeManager: { CountingCentralManagerMock() })
            let manager = try #require(rig.manager as? CountingCentralManagerMock)
            _ = try await rig.client.connect(rig.id, ConnectOptions?.none)
            manager.ignoresCancel = true
            let client = rig.client, id = rig.id
            let disconnect = Task { await outcome(within: 2) { try await client.disconnect(id) } }
            try? await Task.sleep(nanoseconds: 50_000_000)
            #expect(manager.cancelCount == 1)
            CBMCentralManagerMock.simulatePowerOff()
            expectCompleted(await disconnect.value, "disconnect pending at power-off")
        }

        @Test func scanStreamFinishesAtPowerOff() async {
            let rig = await makeScanRig()
            let scan = ScanConsumer(rig.client.scan([cbmBatteryServiceUUID], ScanOptions(allowDuplicates: true)))
            #expect(await eventually(within: 2) { scan.discoveries.value > 0 })
            CBMCentralManagerMock.simulatePowerOff()
            #expect(await eventually(within: 1) { scan.ended.value },
                    "CoreBluetooth stopped the scan and never resumes it: the stream must finish")
            scan.cancel()
        }

        // MARK: After power-on

        /// A read in flight at power-off used to stay in `pendingReads`, so the
        /// first read after reconnecting threw `operationCancelled`.
        @Test func firstReadAfterAPowerCycleAndReconnectSucceeds() async throws {
            let rig = await makePowerCycleRig()
            try await rig.connectAndDiscover()
            let client = rig.client, id = rig.id
            let stranded = Task { await outcome(within: 2) { try await client.readValue(id, cbmBatteryLevelUUID) } }
            try? await Task.sleep(nanoseconds: 50_000_000)
            #expect(rig.specDelegate.readRequests == 1)
            await powerCycle(rig.client)
            _ = await stranded.value

            _ = await client.retrievePeripherals([id])   // fresh peripheral object (see connectAfterAPowerCycleNeedsNoRetrieve)
            expectCompleted(await outcome(within: 3) { try await rig.connectAndDiscover() }, "reconnect")
            let read = await outcome(within: 3) { try await client.readValue(id, cbmBatteryLevelUUID) }
            switch read {
            case .success(let value)?: #expect(value == Data([0x64]))
            case .failure(let error)?: Issue.record("first read after the power cycle threw \(error)")
            case .none: Issue.record("first read after the power cycle was still pending after 3 s")
            }
        }

        /// The characteristic cache belongs to the invalidated peripheral objects:
        /// like a disconnect, a power-off drops it, so an operation on a reconnected
        /// link that skipped rediscovery fails fast instead of using a dead object.
        @Test func aReadAfterAPowerCycleWithoutRediscoveryThrowsUnknownCharacteristic() async throws {
            let rig = await makePowerCycleRig()
            try await rig.connectAndDiscover()
            await powerCycle(rig.client)
            let client = rig.client, id = rig.id
            _ = await client.retrievePeripherals([id])
            expectCompleted(await outcome(within: 3) { _ = try await client.connect(id, ConnectOptions?.none) }, "reconnect")
            let read = await outcome(within: 2) { try await client.readValue(id, cbmBatteryLevelUUID) }
            switch read {
            case .failure(let error)?:
                guard case .unknownCharacteristic? = error as? BluetoothError else {
                    Issue.record("expected unknownCharacteristic, got \(error)"); return
                }
            case .success?: Issue.record("a read through the pre-power-off characteristic succeeded")
            case .none: Issue.record("a read through the pre-power-off characteristic hung")
            }
        }

        /// Every peripheral object is invalid after Bluetooth leaves `.poweredOn`
        /// (CBM forgets them, as iOS does). A connect that reused FCB's cached
        /// object was silently ignored by the manager and hung forever.
        @Test func connectAfterAPowerCycleNeedsNoRetrieve() async throws {
            let rig = await makePowerCycleRig()
            _ = await rig.client.retrievePeripherals([rig.id])
            _ = try await rig.client.connect(rig.id, ConnectOptions?.none)
            await powerCycle(rig.client)
            let client = rig.client, id = rig.id
            expectCompleted(await outcome(within: 3) { _ = try await client.connect(id, ConnectOptions?.none) },
                            "connect after the power cycle")
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/FCB-scan-ownership --filter "CentralPowerOffFailsPendingTests|AdapterDownErrorTests" > /tmp/FCB-scan-ownership/t2-red.txt 2>&1`, then `grep -n "error:\|recorded an issue" /tmp/FCB-scan-ownership/t2-red.txt`.
Expected: a compile error, `type 'CentralActor' has no member 'adapterDownError'`. That is the red for the mapping test. Every CBM test here also fails before the fix: the lane-F probe ran exactly these 12 against unmodified FCB, and each hung, threw `operationCancelled`, or never finished.

- [ ] **Step 3: Implement**

In `BluetoothCentralClient+Live.swift`, replace `handleDidUpdateState` with:
```swift
    private func handleDidUpdateState(_ state: CBMManagerState) {
        let bridged = CBManagerState(state)
        for cont in stateContinuations.values { cont.yield(bridged) }
        emit(.didUpdateState(bridged))
        if let error = Self.adapterDownError(state) {
            adapterWentDown(with: error)
        }
    }

    /// The error pending operations fail with when Bluetooth is in `state`, or
    /// `nil` for `.poweredOn`. `.resetting` and `.unknown` mean the stack is
    /// gone too, so they fail as `.poweredOff`.
    static func adapterDownError(_ state: CBMManagerState) -> BluetoothError? {
        switch state {
        case .poweredOn: return nil
        case .unauthorized: return .unauthorized(CBManager.authorization)
        case .unsupported: return .unsupported
        case .poweredOff, .resetting, .unknown: return .poweredOff
        }
    }

    /// Bluetooth left `.poweredOn`. CoreBluetooth reports this as a state
    /// change only — no `didDisconnect`, no operation callbacks — and every
    /// peripheral object obtained so far is invalid. Fail every pending
    /// operation with `error`, end every notification stream and the scan
    /// stream, release pending `disconnect` callers (the link is down), and
    /// forget all peripherals and characteristics (retrieval or discovery
    /// re-populates them after power-on). One line per kind of state, so each
    /// can be reasoned about (and mutation-tested) on its own.
    private func adapterWentDown(with error: BluetoothError) {
        Self.drain(&pendingConnect) { $0.resume(throwing: error) }
        Self.drain(&pendingDiscoverServices) { $0.resume(throwing: error) }
        Self.drain(&pendingDiscoverCharacteristics) { $0.resume(throwing: error) }
        Self.drain(&pendingReads) { $0.resume(throwing: error) }
        Self.drain(&pendingWrites) { $0.resume(throwing: error) }
        Self.drain(&pendingNotify) { $0.resume(throwing: error) }
        Self.drain(&pendingOpenL2CAP) { $0.resume(throwing: error) }
        Self.drain(&pendingDisconnect) { waiters in waiters.forEach { $0.resume() } }
        Self.drain(&notificationContinuations) { $0.finish(throwing: error) }
        retireCurrentScan()   // CoreBluetooth already stopped the radio scan
        peripherals = [:]
        characteristics = [:]
    }

    /// Empties `map`, then hands each removed value to `body`.
    private static func drain<Key, Value>(_ map: inout [Key: Value], _ body: (Value) -> Void) {
        let values = Array(map.values)
        map = [:]
        values.forEach(body)
    }
```

In `CLAUDE.md`, insert after the Task 1 "Scan ownership" bullet:
```markdown
- **Power-off semantics:** CoreBluetooth reports Bluetooth leaving `.poweredOn` as a state change only (no `didDisconnect`, no operation callbacks), and every peripheral object becomes invalid. `CentralActor.adapterWentDown(with:)` then fails EVERY pending operation (connect, discovery, reads, writes, set-notify, L2CAP open) with `CentralActor.adapterDownError(state)` — `.poweredOff` for off/resetting/unknown, `.unsupported`, or `.unauthorized(…)` — releases pending `disconnect` callers, finishes every `notifications` stream with that error and the scan stream, and forgets all peripherals and characteristics (`connect` re-retrieves; discovery re-populates). Tests: wait for FCB's own `.poweredOff` before powering on again — an immediate off→on reaches FCB as two `.poweredOn` callbacks (CBM and CoreBluetooth read `state` at callback time).
```

- [ ] **Step 4: Run the tests to verify they pass, plus the whole suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/FCB-scan-ownership > /tmp/FCB-scan-ownership/t2-green.txt 2>&1`, then `grep -n "recorded an issue\|Test run with" /tmp/FCB-scan-ownership/t2-green.txt`.
Expected: `Test run with 140 tests … passed … with 3 known issues`.

- [ ] **Step 5: Mutation batch. One batch: each test watches one line**

In `adapterWentDown`, comment out each of these lines with `// MUT `:
- `Self.drain(&pendingConnect) …`
- `Self.drain(&pendingDiscoverServices) …`
- `Self.drain(&pendingDiscoverCharacteristics) …`
- `Self.drain(&pendingReads) …`
- `Self.drain(&pendingWrites) …`
- `Self.drain(&pendingNotify) …`
- `Self.drain(&pendingDisconnect) …`
- `Self.drain(&notificationContinuations) …`
- `retireCurrentScan()`
- `peripherals = [:]`
- `characteristics = [:]`

Leave `pendingOpenL2CAP` alone: no CBM test can reach it (Review Focus 5). In `adapterDownError`, change `case .unsupported: return .unsupported` to `case .unsupported: return .poweredOff`.

Run: `swift test --package-path /Users/ell/development/ios/pods/FCB-scan-ownership --filter "CentralPowerOffFailsPendingTests|AdapterDownErrorTests" > /tmp/FCB-scan-ownership/t2-mut.txt 2>&1`, then `grep -n "􀄵\|failed after" /tmp/FCB-scan-ownership/t2-mut.txt`. Expected: all 13 FAIL, each for its own line:

| Test | Mutated line | Failure message |
|---|---|---|
| the mapping test | `.unsupported` case | — |
| read | `pendingReads` | "still pending after 2 s" |
| write | `pendingWrites` | "still pending after 2 s" |
| setNotify | `pendingNotify` | "still pending after 2 s" |
| discoverServices | `pendingDiscoverServices` | "still pending after 2 s" |
| discoverCharacteristics | `pendingDiscoverCharacteristics` | "still pending after 2 s" |
| connect | `pendingConnect` | "still pending after 2 s" |
| notification stream | `notificationContinuations` | "still pending after 2 s" |
| disconnect | `pendingDisconnect` | "disconnect pending at power-off was still pending" |
| scan stream | `retireCurrentScan` | "the stream must finish" |
| first read after the cycle | `pendingReads` | "threw .operationCancelled" |
| unknownCharacteristic | `characteristics` | "read … hung" |
| connect without retrieve | `peripherals` | "connect after the power cycle was still pending" |

These were confirmed in the lane-F scratch copy.

Revert every `// MUT ` and the `.unsupported` change.

- [ ] **Step 6: Run again to confirm green after reverting**

Run: `swift test --package-path /Users/ell/development/ios/pods/FCB-scan-ownership > /tmp/FCB-scan-ownership/t2-green2.txt 2>&1`, then `grep -n "recorded an issue\|Test run with" /tmp/FCB-scan-ownership/t2-green2.txt`. Expected: 140 passed, 3 known issues.

- [ ] **Step 7: Commit**

Write `/tmp/FCB-scan-ownership/commit-msg.txt`:
```
fix: Bluetooth leaving poweredOn fails every pending central operation

CoreBluetooth reports a power-off as a state change only, and
handleDidUpdateState never failed anything: every pending connect,
discovery, read, write, set-notify and disconnect leaked, notification
and scan streams went quiet, a stale pendingReads entry made the first
read after reconnecting throw operationCancelled, and a connect after
the power cycle reused a peripheral object CoreBluetooth had invalidated
and hung. adapterWentDown now fails them all with the state's error
(.poweredOff, .unsupported, .unauthorized), ends the streams and forgets
peripherals and characteristics.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run:
```
git -C /Users/ell/development/ios/pods/FCB-scan-ownership add Sources/FCBComposable/BluetoothCentralClient+Live.swift CLAUDE.md Tests/FCBComposableTests/CentralPowerOffFailsPendingTests.swift
git -C /Users/ell/development/ios/pods/FCB-scan-ownership commit -F /tmp/FCB-scan-ownership/commit-msg.txt
git -C /Users/ell/development/ios/pods/FCB-scan-ownership log -1 "--format=%(trailers:key=Claude-Session)"
```

---

### Task 3: An occupied slot fails the previous caller; fast-forward FCB main

**Files:**
- Modify: `/Users/ell/development/ios/pods/FCB-scan-ownership/Sources/FCBComposable/BluetoothCentralClient+Live.swift` (the `pending…[…] = cont` lines in `connect`, `discoverServices`, `discoverCharacteristics`, `writeValue`, `setNotify`)
- Modify: `/Users/ell/development/ios/pods/FCB-scan-ownership/CLAUDE.md` (append a bullet)
- Create: `/Users/ell/development/ios/pods/FCB-scan-ownership/Tests/FCBComposableTests/CentralOccupiedSlotTests.swift`

**Interfaces:**
- Consumes: `outcome(within:_:)`, `expectThrows`, `expectCompleted`, `expectDisconnected(_:id:)`, `makePendingOpsRig`, `PendingOpsRig.connectAndDiscover()`.
- Produces: no new symbols. The behaviour is: a second call for an occupied slot fails the first with `BluetoothError.operationCancelled`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FCBComposableTests/CentralOccupiedSlotTests.swift`:

```swift
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import Foundation
import Testing
@testable import FCBComposable

/// Each of these operations keeps ONE continuation per slot (peripheral, or
/// peripheral + attribute). A second call for an occupied slot used to
/// overwrite the first caller's continuation, which then never resumed. Now
/// the newer call supersedes: the older caller throws `operationCancelled`.
extension CBMBackedTests {
    @Suite @MainActor
    struct CentralOccupiedSlotTests {
        @Test func aSecondConnectFailsTheFirstInsteadOfLeakingIt() async {
            // Out of range: neither connect can complete on its own.
            let rig = await makePendingOpsRig(inRange: false)
            let client = rig.client, id = rig.id
            let first = Task { await outcome(within: 2) { try await client.connect(id, ConnectOptions?.none) } }
            try? await Task.sleep(nanoseconds: 50_000_000)
            let second = Task { await outcome(within: 2) { try await client.connect(id, ConnectOptions?.none) } }
            try? await Task.sleep(nanoseconds: 50_000_000)
            expectThrows(await first.value, .operationCancelled)
            _ = await outcome(within: 2) { try await client.disconnect(id) }
            expectDisconnected(await second.value, id: id)
        }

        @Test func aSecondDiscoverServicesFailsTheFirstInsteadOfLeakingIt() async throws {
            let rig = await makePendingOpsRig()
            _ = try await rig.client.connect(rig.id, ConnectOptions?.none)
            let client = rig.client, id = rig.id
            let first = Task { await outcome(within: 2) { try await client.discoverServices(id, [cbmBatteryServiceUUID]) } }
            try? await Task.sleep(nanoseconds: 50_000_000)
            let second = Task { await outcome(within: 2) { try await client.discoverServices(id, [cbmBatteryServiceUUID]) } }
            expectThrows(await first.value, .operationCancelled)
            expectCompleted(await second.value, "the superseding discoverServices")
        }

        @Test func aSecondDiscoverCharacteristicsFailsTheFirstInsteadOfLeakingIt() async throws {
            let rig = await makePendingOpsRig()
            _ = try await rig.client.connect(rig.id, ConnectOptions?.none)
            _ = try await rig.client.discoverServices(rig.id, [cbmBatteryServiceUUID])
            let client = rig.client, id = rig.id
            let first = Task {
                await outcome(within: 2) { try await client.discoverCharacteristics(id, cbmBatteryServiceUUID, [CBUUID]?.none) }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            let second = Task {
                await outcome(within: 2) { try await client.discoverCharacteristics(id, cbmBatteryServiceUUID, [CBUUID]?.none) }
            }
            expectThrows(await first.value, .operationCancelled)
            expectCompleted(await second.value, "the superseding discoverCharacteristics")
        }

        @Test func aSecondWriteWithResponseFailsTheFirstInsteadOfLeakingIt() async throws {
            let rig = await makePendingOpsRig()
            try await rig.connectAndDiscover()
            let client = rig.client, id = rig.id
            let first = Task {
                await outcome(within: 2) { try await client.writeValue(Data([0x01]), id, cbmBatteryLevelUUID, .withResponse) }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            let second = Task {
                await outcome(within: 2) { try await client.writeValue(Data([0x02]), id, cbmBatteryLevelUUID, .withResponse) }
            }
            expectThrows(await first.value, .operationCancelled)
            expectCompleted(await second.value, "the superseding write")
        }

        @Test func aSecondSetNotifyFailsTheFirstInsteadOfLeakingIt() async throws {
            let rig = await makePendingOpsRig()
            try await rig.connectAndDiscover()
            let client = rig.client, id = rig.id
            let first = Task { await outcome(within: 2) { try await client.setNotify(true, id, cbmBatteryLevelUUID) } }
            try? await Task.sleep(nanoseconds: 50_000_000)
            let second = Task { await outcome(within: 2) { try await client.setNotify(true, id, cbmBatteryLevelUUID) } }
            expectThrows(await first.value, .operationCancelled)
            expectCompleted(await second.value, "the superseding setNotify")
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/FCB-scan-ownership --filter CentralOccupiedSlotTests > /tmp/FCB-scan-ownership/t3-red.txt 2>&1`, then `grep -n "􀄵\|failed after\|passed after" /tmp/FCB-scan-ownership/t3-red.txt`.
Expected: all 5 FAIL with "operation was still pending after 2 s" (the first caller leaked).

- [ ] **Step 3: Implement**

Replace each overwrite with a supersede:
- `connect`: `pendingConnect[id] = cont` →
  ```swift
              // A retry supersedes: the caller it replaces fails instead of leaking.
              pendingConnect.updateValue(cont, forKey: id)?.resume(throwing: BluetoothError.operationCancelled)
  ```
- `discoverServices`: `pendingDiscoverServices[peripheralID] = cont` → `pendingDiscoverServices.updateValue(cont, forKey: peripheralID)?.resume(throwing: BluetoothError.operationCancelled)`
- `discoverCharacteristics`: `pendingDiscoverCharacteristics[key] = cont` → `pendingDiscoverCharacteristics.updateValue(cont, forKey: key)?.resume(throwing: BluetoothError.operationCancelled)`
- `writeValue` (with response): `pendingWrites[key] = cont` → `pendingWrites.updateValue(cont, forKey: key)?.resume(throwing: BluetoothError.operationCancelled)`
- `setNotify`: `pendingNotify[key] = cont` → `pendingNotify.updateValue(cont, forKey: key)?.resume(throwing: BluetoothError.operationCancelled)`

Leave `readValue`'s and `openL2CAPChannel`'s "reject the new call" guards unchanged.

In `CLAUDE.md`, insert after the Task 2 bullet:
```markdown
- **Occupied slots:** connect (per peripheral), discoverServices (per peripheral), discoverCharacteristics (per service), write-with-response and setNotify (per characteristic) keep one continuation per slot; a second call for an occupied slot fails the FIRST caller with `.operationCancelled` (it used to be overwritten and hang forever). The slot is not per call: the superseding call completes on the next CoreBluetooth answer for that slot, which can be the first call's. `readValue` and `openL2CAPChannel` instead reject the NEW call with `.operationCancelled` while one is pending. Consumers that need per-call outcomes serialise their own calls (MeshtasticKit's write slot).
```

- [ ] **Step 4: Run the tests to verify they pass, plus the whole suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/FCB-scan-ownership > /tmp/FCB-scan-ownership/t3-green.txt 2>&1`, then `grep -n "recorded an issue\|Test run with" /tmp/FCB-scan-ownership/t3-green.txt`.
Expected: `Test run with 145 tests … passed … with 3 known issues`.

- [ ] **Step 5: Mutation batch (one batch, disjoint: each test exercises one slot)**

Revert each of the five lines to its overwrite form (`pendingConnect[id] = cont`, etc.). Run `swift test --package-path /Users/ell/development/ios/pods/FCB-scan-ownership --filter CentralOccupiedSlotTests > /tmp/FCB-scan-ownership/t3-mut.txt 2>&1`, then grep as in Step 2. Expected: all 5 FAIL ("still pending after 2 s"). Restore the five supersede lines.

- [ ] **Step 6: Run again to confirm green after reverting**

Run: `swift test --package-path /Users/ell/development/ios/pods/FCB-scan-ownership > /tmp/FCB-scan-ownership/t3-green2.txt 2>&1`, then grep. Expected: 145 passed, 3 known issues.

- [ ] **Step 7: Commit**

Write `/tmp/FCB-scan-ownership/commit-msg.txt`:
```
fix: a second call for an occupied slot fails the first instead of leaking it

connect, discoverServices, discoverCharacteristics, write-with-response
and setNotify kept one continuation per slot and overwrote it on a
retry, so the earlier caller never resumed. The newer call now
supersedes and the earlier caller throws operationCancelled. readValue
and openL2CAPChannel already rejected the new call and are unchanged.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run:
```
git -C /Users/ell/development/ios/pods/FCB-scan-ownership add Sources/FCBComposable/BluetoothCentralClient+Live.swift CLAUDE.md Tests/FCBComposableTests/CentralOccupiedSlotTests.swift
git -C /Users/ell/development/ios/pods/FCB-scan-ownership commit -F /tmp/FCB-scan-ownership/commit-msg.txt
git -C /Users/ell/development/ios/pods/FCB-scan-ownership log -1 "--format=%(trailers:key=Claude-Session)"
```

- [ ] **Step 8: Fast-forward FCB main and run its suite there**

Run each as its own command:
```
git -C /Users/ell/development/ios/pods/FCB status --short
git -C /Users/ell/development/ios/pods/FCB merge --ff-only scan-ownership
git -C /Users/ell/development/ios/pods/FCB log --oneline -4
swift test --package-path /Users/ell/development/ios/pods/FCB > /tmp/FCB-scan-ownership/main-fcb.txt 2>&1
grep -n "recorded an issue\|Test run with" /tmp/FCB-scan-ownership/main-fcb.txt
```
Expected:
- The first `status` lists only the user's pre-existing `Example/…` entries.
- The merge reports `Fast-forward`.
- `log` shows the three lane-F commits on top of `ff01d8a`.
- 145 tests pass with 3 known issues.
- `status --short` afterwards still lists only the `Example/…` entries.

Leave the worktree in place (lane D precedent).

---

# Part 2 — ReTiCA (worktree `/Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership`)

FCB main now carries Part 1. The ReTiCA worktree resolves `../FCB` through the `ReTiCA-worktrees/FCB` symlink, so it builds against it.

### Task 4: `FCBDriverAdapter` tears down only its own session

**Files:**
- Modify: `/Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership/Sources/ReTiCAInterfaces/FCBDriverAdapter.swift:245-285` (`resetSession`)
- Modify: `/Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership/Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift`. Edits: `AdapterStubs` (append a field after `:152`), `makeStubs` (`:183` area, `:195-203`, `:315-329`), `:498`, plus two new tests after `:501`.
- Create: `/Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership/Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMCoexistenceTests.swift`

**Interfaces:**
- Consumes:
  - FCB main (Part 1): `stopScan` is a no-op, scan termination is token-scoped, `adapterWentDown`.
  - Existing tests: `makeStubs()`, `onlineAdapter()`, `openOutbound(_:_:_:_:)`, `collect(_:count:within:)`, `peer(_:)`, `disc(_:)`, `eventWait`, `V22SpecDelegate`, `noopPeripheralClient()`, `FCBDriverAdapterCBMTests`, `serviceUUID`/`txCharUUID`/`rxCharUUID`/`identityCharUUID`, `adapterLocalIdentity`.
- Produces:
  - Stub knob `AdapterStubs.disconnectHeld: LockIsolated<Bool>`.
  - CBM helpers that Tasks 5 and 6 use: `PowerCycleV22Delegate` (`identity`, `powerOffOnNextIdentityRead`), `CoexistRig { central; manager; peerDelegate }`, `@MainActor func makeCoexistRig(bleInterval: TimeInterval) async -> CoexistRig`, `DriverEventLog` (`init(_:)`, `events`, `ended`, `count`, `cancel()`, `first(after:within:_:)`), `RadioScanLog` (`discoveries`, `ended`, `cancel()`), `poll(within:_:)`, `returns(within:_:)`, `isPeerDiscovered`, `isIdentityOutcome`, `isChannelOutcome`, `coexistRadioServiceUUID`, and `FCBDriverAdapterCBMTests.bleOnlineWithOpenChannel(_:)`.

- [ ] **Step 1: Create the worktree and temp dir; confirm the build sees FCB main**

Run each as its own command:
```
git -C /Users/ell/development/ios/pods/ReTiCA worktree add ../ReTiCA-worktrees/fcb-scan-ownership -b fcb-scan-ownership
mkdir -p /tmp/fcb-scan-ownership
swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership --filter ReTiCAInterfacesTests > /tmp/fcb-scan-ownership/baseline.txt 2>&1
grep -n "recorded an issue\|Test run with" /tmp/fcb-scan-ownership/baseline.txt
```
Expected: `Test run with 272 tests … passed`. The unmodified adapter still calls `central.stopScan()`, which the stub counts, so the old `stopScanned >= 1` assertion holds; FCB's no-op never touches the stub. Any failure here means STOP.

- [ ] **Step 2: Write the failing tests**

(2a) In `FCBDriverAdapterTests.swift`, add a stub knob that keeps `central.disconnect` in flight.
- Append to `struct AdapterStubs`, after `let openL2CAPHeld: LockIsolated<Bool> …` (`:152`):
  ```swift
      let disconnectHeld: LockIsolated<Bool>             // while true, central.disconnect stays in flight (a deterministic "slow" stop)
  ```
- In `makeStubs()`, after `let openL2CAPHeld = LockIsolated(false)`:
  ```swift
      let disconnectHeld = LockIsolated(false)
  ```
- In the stub `disconnect:` closure, between `try? await Task.sleep(nanoseconds: 5_000_000)` and `await calls.disconnect(id)`:
  ```swift
              while disconnectHeld.value { try? await Task.sleep(nanoseconds: 2_000_000) }
  ```
- In the `return AdapterStubs(…)` call, change its last line `publishHeld: publishHeld, publishEncryption: publishEncryption, openL2CAPHeld: openL2CAPHeld)` to:
  ```swift
          publishHeld: publishHeld, publishEncryption: publishEncryption, openL2CAPHeld: openL2CAPHeld,
          disconnectHeld: disconnectHeld)
  ```

(2b) In `restartRemovesServicesAndStopsAdvertisingBeforeReAdding`, replace `#expect(await stubs.calls.stopScanned >= 1)` with:
```swift
    // The old session's scan ends by terminating ITS stream (its task is cancelled), never by
    // FCB's global stopScan, which would end whatever scan is current — maybe another owner's.
    #expect(await stubs.calls.stopScanned == 0)
```

(2c) Directly after that test's closing `}`, add:
```swift
@Test @MainActor func stopNeverCallsTheGlobalStopScan() async {
    let (adapter, stubs, _) = await onlineAdapter()
    await adapter.stop()
    #expect(await stubs.calls.stopScanned == 0)
}

/// The radio picker's dismiss: the app restarts BLE while the stop it sent when the picker
/// opened is still disconnecting a peer. That old teardown must not reach into the new session
/// when it resumes: no stopAdvertising/removeAll of the new session's advertisement and service,
/// and no finishing of the new session's event stream.
@Test @MainActor func aStaleStopResumingAfterARestartLeavesTheNewSessionAlone() async {
    let (adapter, stubs, events1) = await onlineAdapter()
    let p = peer(1)
    stubs.scanCont.yield(disc(p))
    _ = await collect(events1, count: 1)   // peerDiscovered
    guard await openOutbound(adapter, stubs, events1, p) != nil else { return }

    stubs.disconnectHeld.setValue(true)    // the old session's teardown parks on the peer's disconnect
    let stop = Task { await adapter.stop() }
    let calls = stubs.calls
    try? await Task.sleep(nanoseconds: 100_000_000)   // the stop is now parked in the held disconnect
    #expect(await calls.disconnected.isEmpty)

    let events2 = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    #expect(await collect(events2, count: 1) == [.ready])
    let stoppedAdvertising = await calls.stoppedAdvertising
    let removedAll = await calls.removedAll
    let ended = LockIsolated(false)
    let watcher = Task { for await _ in events2 {}; ended.setValue(true) }

    stubs.disconnectHeld.setValue(false)   // the old teardown resumes into the new session
    await stop.value
    try? await Task.sleep(nanoseconds: 100_000_000)

    #expect(await calls.stoppedAdvertising == stoppedAdvertising, "the stale stop tore down the new advertisement")
    #expect(await calls.removedAll == removedAll, "the stale stop removed the new session's service")
    #expect(!ended.value, "the stale stop finished the new session's event stream")
    watcher.cancel()
    await adapter.stop()
}
```

(2d) Create `Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMCoexistenceTests.swift`. Its tests are members of the existing serialized `FCBDriverAdapterCBMTests` suite, so they never run alongside the other CBM tests:

```swift
import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
@testable import ReTiCAInterfaces
@testable import FCBComposable

/// The Meshtastic service UUID, so the second scanner here looks like the radio picker's.
let coexistRadioServiceUUID = CBMUUID(string: "6BA1B218-15A8-461F-9FA8-5DCAE273EAFD")

private struct CoexistAcceptingDelegate: CBMPeripheralSpecDelegate {}

/// A ble-reticulum v2.2 peer whose next Identity read can power Bluetooth off while that read is
/// in flight at the peripheral (CBM calls this synchronously from `readValue`).
final class PowerCycleV22Delegate: CBMPeripheralSpecDelegate, @unchecked Sendable {
    let identity = Data(repeating: 0xEE, count: 16)
    let powerOffOnNextIdentityRead = LockIsolated(false)

    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveReadRequestFor characteristic: CBMCharacteristicMock) -> Result<Data, any Error> {
        guard characteristic.uuid == identityCharUUID else { return .failure(CBATTError(.attributeNotFound)) }
        let powerOff = powerOffOnNextIdentityRead.withValue { armed -> Bool in defer { armed = false }; return armed }
        if powerOff { CBMCentralManagerMock.simulatePowerOff() }
        return .success(identity)
    }
    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveWriteRequestFor characteristic: CBMCharacteristicMock, data: Data) -> Result<Void, any Error> {
        .success(())
    }
    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveWriteCommandFor characteristic: CBMCharacteristicMock, data: Data) {}
    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveSetNotifyRequest enabled: Bool, for characteristic: CBMCharacteristicMock) -> Result<Void, any Error> {
        .success(())
    }
}

/// One live FCB central (the app has exactly one) shared by the BLE driver and a second scanner,
/// over a CBM world with a v2.2 peer and a Meshtastic-looking radio. `bleInterval` is the peer's
/// connection interval: every GATT response and the disconnect take that long, which is what
/// makes a BLE stop with an open channel "slow".
struct CoexistRig {
    let central: BluetoothCentralClient
    let manager: CBMCentralManager
    let peerDelegate: PowerCycleV22Delegate
}

@MainActor
func makeCoexistRig(bleInterval: TimeInterval) async -> CoexistRig {
    CBMCentralManagerMock.tearDownSimulation()
    CBMCentralManagerMock.simulateInitialState(.poweredOn)
    let tx = CBMCharacteristicMock(type: txCharUUID, properties: [.read, .notify])
    let rx = CBMCharacteristicMock(type: rxCharUUID, properties: [.write, .writeWithoutResponse])
    let ident = CBMCharacteristicMock(type: identityCharUUID, properties: [.read])
    let service = CBMServiceMock(type: serviceUUID, primary: true, characteristics: tx, rx, ident)
    let peerDelegate = PowerCycleV22Delegate()
    let blePeer = CBMPeripheralSpec
        .simulatePeripheral(identifier: UUID(), proximity: .near)
        .advertising(advertisementData: [CBMAdvertisementDataServiceUUIDsKey: [serviceUUID],
                                         CBMAdvertisementDataIsConnectable: true as NSNumber], withInterval: 0.05)
        .connectable(name: "rns-pi", services: [service], delegate: peerDelegate, connectionInterval: bleInterval)
        .allowForRetrieval()
        .build()
    let radio = CBMPeripheralSpec
        .simulatePeripheral(identifier: UUID(), proximity: .near)
        .advertising(advertisementData: [CBMAdvertisementDataServiceUUIDsKey: [coexistRadioServiceUUID],
                                         CBMAdvertisementDataLocalNameKey: "Meshtastic_COEX",
                                         CBMAdvertisementDataIsConnectable: true as NSNumber], withInterval: 0.05)
        .connectable(name: "Meshtastic_COEX", services: [], delegate: CoexistAcceptingDelegate(), connectionInterval: 0.01)
        .build()
    CBMCentralManagerMock.simulatePeripherals([blePeer, radio])
    let manager = CBMCentralManagerFactory.instance(forceMock: true)
    for _ in 0..<200 where manager.state != .poweredOn { try? await Task.sleep(nanoseconds: 10_000_000) }
    let central = BluetoothCentralClient.makeClient(actor: CentralActor(manager: manager))
    return CoexistRig(central: central, manager: manager, peerDelegate: peerDelegate)
}

/// Records a driver session's events and whether its stream ended.
final class DriverEventLog: @unchecked Sendable {
    let events = LockIsolated<[BLEDriverEvent]>([])
    let ended = LockIsolated(false)
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<BLEDriverEvent>) {
        let events = events
        let ended = ended
        task = Task {
            for await event in stream { events.withValue { $0.append(event) } }
            ended.setValue(true)
        }
    }

    var count: Int { events.value.count }
    func cancel() { task?.cancel() }

    /// The first event at index ≥ `index` matching `match`, waiting at most `seconds`.
    func first(after index: Int = 0, within seconds: Double = 6,
               _ match: @escaping @Sendable (BLEDriverEvent) -> Bool) async -> BLEDriverEvent? {
        for _ in 0..<Int(seconds * 50) {
            if let hit = events.withValue({ Array($0.dropFirst(index)).first(where: match) }) { return hit }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }
}

/// Drains a raw FCB scan stream (the radio picker's role), counting discoveries.
final class RadioScanLog: @unchecked Sendable {
    let discoveries = LockIsolated(0)
    let ended = LockIsolated(false)
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<DiscoveredPeripheral>) {
        let discoveries = discoveries
        let ended = ended
        task = Task {
            for await _ in stream { discoveries.withValue { $0 += 1 } }
            ended.setValue(true)
        }
    }

    func cancel() { task?.cancel() }
}

func poll(within seconds: Double, _ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<Int(seconds * 100) {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// Whether `operation` returned within `seconds` (a hung FCB continuation must FAIL the test,
/// not hang the run).
func returns(within seconds: Double, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
    let done = LockIsolated(false)
    let task = Task { await operation(); done.setValue(true) }
    let returned = await poll(within: seconds) { done.value }
    if !returned { task.cancel() }
    return returned
}

let isPeerDiscovered: @Sendable (BLEDriverEvent) -> Bool = { if case .peerDiscovered = $0 { return true }; return false }
let isIdentityOutcome: @Sendable (BLEDriverEvent) -> Bool = {
    if case .identityRead = $0 { return true }
    if case .identityFailed = $0 { return true }
    return false
}
let isChannelOutcome: @Sendable (BLEDriverEvent) -> Bool = {
    if case .channelOpened = $0 { return true }
    if case .channelFailed = $0 { return true }
    return false
}

extension FCBDriverAdapterCBMTests {
    /// BLE up on `rig.central` with one outbound channel open, so `stop()` has a disconnect to
    /// wait out (one `bleInterval`).
    func bleOnlineWithOpenChannel(_ rig: CoexistRig) async -> (BLEDriver, DriverEventLog)? {
        let driver = BLEDriver.fcb(central: rig.central, peripheral: noopPeripheralClient())
        let log = DriverEventLog(driver.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
        guard case let .peerDiscovered(handle)? = await log.first(isPeerDiscovered) else {
            Issue.record("no peerDiscovered"); return nil
        }
        await driver.readIdentity(handle)
        guard case .identityRead? = await log.first(isIdentityOutcome) else { Issue.record("identity read failed"); return nil }
        await driver.openChannel(handle)
        guard case .channelOpened? = await log.first(isChannelOutcome) else { Issue.record("channel did not open"); return nil }
        return (driver, log)
    }

    /// Picker DISMISS: the app restarts BLE while the stop it sent at open is still disconnecting.
    /// When that old teardown resumes, the new session must keep its event stream.
    @Test func aRestartDuringASlowStopKeepsTheNewSessionsEventStream() async {
        let rig = await makeCoexistRig(bleInterval: 0.4)
        guard let (driver, log) = await bleOnlineWithOpenChannel(rig) else { return }
        let stop = Task { await driver.stop() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let restarted = DriverEventLog(driver.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
        await stop.value
        try? await Task.sleep(nanoseconds: 500_000_000)

        #expect(!restarted.ended.value, "the old session's teardown finished the new session's stream")
        restarted.cancel()
        log.cancel()
        await driver.stop()
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership --filter ReTiCAInterfacesTests > /tmp/fcb-scan-ownership/t4-red.txt 2>&1`, then `grep -n "error:\|recorded an issue\|Test run with" /tmp/fcb-scan-ownership/t4-red.txt`.
Expected (verified against FCB-fixed + the unmodified adapter): `Test run with 275 tests` failing with:
- `stopNeverCallsTheGlobalStopScan` and `restartRemovesServicesAndStopsAdvertisingBeforeReAdding` (`stopScanned == 0`).
- `aStaleStopResumingAfterARestartLeavesTheNewSessionAlone`, all three `#expect`s.
- `aRestartDuringASlowStopKeepsTheNewSessionsEventStream`.

- [ ] **Step 4: Implement**

In `FCBDriverAdapter.swift`, apply these two edits to `resetSession()`.

At the top, replace
```swift
        epoch += 1   // first: invalidate any operation still in flight from the outgoing session
        for t in tasks { t.cancel() }
```
with
```swift
        epoch += 1   // first: invalidate any operation still in flight from the outgoing session
        let myEpoch = epoch
        // Captured before any await: a newer session may begin while this teardown is suspended,
        // and its stream must not be the one finished below.
        let outgoing = continuation
        continuation = nil
        // Cancelling the scan task terminates THIS session's scan stream, which is how FCB stops
        // the radio scan — and only if it is still this session's scan.
        for t in tasks { t.cancel() }
```
and at the bottom replace
```swift
        // A restart without stop() (the reducer's adapter retry) must leave the managers clean
        // for the next bring-up: no scan, no advertisement, no published service or PSM.
        await central.stopScan()
        await peripheral.stopAdvertising()
        await peripheral.removeAll()
        if let psm = publishedPSM {
            publishedPSM = nil
            await peripheral.unpublishL2CAPChannel(psm)
        }
        continuation?.finish()
        continuation = nil
    }
```
with
```swift
        // A restart without stop() (the reducer's adapter retry) must leave the peripheral
        // manager clean for the next bring-up: no advertisement, no published service or PSM.
        // Skipped once a newer session began while this one was suspended: that session's own
        // reset already cleaned up, and its bring-up now owns the advertisement and service.
        if epoch == myEpoch {
            await peripheral.stopAdvertising()
            await peripheral.removeAll()
            if epoch == myEpoch, let psm = publishedPSM {
                publishedPSM = nil
                await peripheral.unpublishL2CAPChannel(psm)
            }
        }
        outgoing?.finish()
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership --filter ReTiCAInterfacesTests > /tmp/fcb-scan-ownership/t4-green.txt 2>&1`, then `grep -n "recorded an issue\|Test run with" /tmp/fcb-scan-ownership/t4-green.txt`.
Expected: `Test run with 275 tests in 10 suites passed`.

- [ ] **Step 6: Mutation batch b1 (adapter-only; one batch, disjoint observables)**

- M-a1: delete the line `continuation = nil` right after `let outgoing = continuation`, and replace the final `outgoing?.finish()` with `_ = outgoing` + `continuation?.finish()` + `continuation = nil` (three lines). This restores "finish whatever stream is current".
- M-a2: change `if epoch == myEpoch {` to `if true || epoch == myEpoch {`, and `if epoch == myEpoch, let psm = publishedPSM {` to `if let psm = publishedPSM {`.

Run the Step 5 command into `/tmp/fcb-scan-ownership/t4-mut.txt` and grep. Expected:
- `aStaleStopResumingAfterARestartLeavesTheNewSessionAlone` fails all three `#expect`s: the two counts by M-a2, `ended` by M-a1.
- `aRestartDuringASlowStopKeepsTheNewSessionsEventStream` fails (M-a1).
- The two `stopScanned == 0` tests still PASS. Their mutation is M-b2 in Task 6's batch, where they are re-verified.

Revert both mutations exactly to Step 4's text.

- [ ] **Step 7: Run again to confirm green after reverting**

Run Step 5's command into `/tmp/fcb-scan-ownership/t4-green2.txt`. Expected: 275 passed.

- [ ] **Step 8: Commit**

Write `/tmp/fcb-scan-ownership/commit-msg.txt`:
```
fix: BLE driver teardown touches only its own session

resetSession awaited peer disconnects and then called the global
central.stopScan(), stopAdvertising/removeAll and continuation.finish().
When the app restarted BLE while that stop was still disconnecting (the
Meshtastic radio picker's dismiss), the stale teardown ended the NEW
session's scan, advertisement, service and event stream — BLE stayed
"online" but dead. The scan now ends only by cancelling this session's
scan task (FCB's stream termination is token-scoped), the stream finished
is the one captured at entry, and peripheral teardown is skipped once a
newer session has begun.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run:
```
git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership add Sources/ReTiCAInterfaces/FCBDriverAdapter.swift Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMCoexistenceTests.swift
git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership commit -F /tmp/fcb-scan-ownership/commit-msg.txt
git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership log -1 "--format=%(trailers:key=Claude-Session)"
```

---

### Task 5: `FCBDriverAdapter` reports a scan lost to another owner

After Part 1, a superseded FCB scan stream finishes instead of going quiet. The adapter must react to that, or BLE stays "online" without discovering (spec departure 1(b), decision in departure 5).

**Files:**
- Modify: `/Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership/Sources/ReTiCAInterfaces/FCBDriverAdapter.swift`: the stored properties (`:64` `tasks`), `bringUpCentral` (`:214-222`), and `resetSession` (right after `tasks = []`).
- Modify: `/Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership/Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift`: the stub scan feed (`:118`, `:161`, `:193`, `:318` in the original numbering).
- Modify: `/Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership/Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMCoexistenceTests.swift`: append two tests to the `extension FCBDriverAdapterCBMTests`.

**Interfaces:**
- Consumes: Task 4's helpers (`makeCoexistRig`, `DriverEventLog`, `RadioScanLog`, `isPeerDiscovered`, `coexistRadioServiceUUID`, `noopPeripheralClient()`). From `BLEDriver.swift`: `BLEDriverEvent.unavailable(BLEAdapterUnavailable)` and `BLEAdapterUnavailable.other(String?)` (transient).
- Produces:
  - `FCBDriverAdapter.scanTask: Task<Void, Never>?` (private).
  - `private func scanLost(epoch:)`.
  - Event contract: `.unavailable(.other("scan superseded by another scanner"))` once per session when another owner supersedes the adapter's scan while Bluetooth is `.poweredOn`.
  - Test stub `final class ScanFeed` (`yield(_:)`, `makeStream()`). `AdapterStubs.scanCont` is now a `ScanFeed`, and existing `stubs.scanCont.yield(…)` call sites compile unchanged.

- [ ] **Step 1: Give the stub central a per-call scan stream**

The stub's `scan` returned ONE shared `AsyncStream` to every session. When the old session's scan task is cancelled on restart, that shared stream terminates, and the restarted session's iteration of it ends at once without being cancelled. Today that silently leaves the new session without a scan. With this task's reaction it would read as a lost scan. FCB gives every `scan()` call its own stream, so the stub must too.

In `FCBDriverAdapterTests.swift`, insert before `/// Records the FCB commands the adapter invokes.`:
```swift
/// The stub central's scan: every `scan()` call gets its own stream, as FCB's does, fed by
/// `yield`. A stream ends only when its consumer cancels it, so a restarted session's scan is not
/// killed by the previous session's cancellation. Values yielded while no stream is listening wait
/// for the next one, as the single shared stream this replaced buffered them.
final class ScanFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [Int: AsyncStream<DiscoveredPeripheral>.Continuation] = [:]
    private var pending: [DiscoveredPeripheral] = []
    private var nextID = 0

    func yield(_ value: DiscoveredPeripheral) {
        lock.lock()
        let all = Array(listeners.values)
        if all.isEmpty { pending.append(value) }
        lock.unlock()
        for c in all { c.yield(value) }
    }

    func makeStream() -> AsyncStream<DiscoveredPeripheral> {
        AsyncStream { continuation in
            lock.lock()
            let id = nextID
            nextID += 1
            listeners[id] = continuation
            let backlog = pending
            pending = []
            lock.unlock()
            for value in backlog { continuation.yield(value) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.listeners[id] = nil
                self.lock.unlock()
            }
        }
    }
}
```
Then make four line edits:
- In `AdapterStubs`, change `let scanCont: AsyncStream<DiscoveredPeripheral>.Continuation` to `let scanCont: ScanFeed                             // yield discoveries to every live scan() stream`.
- In `makeStubs()`, change `let scan = AsyncStream<DiscoveredPeripheral>.makeStream()` to `let scan = ScanFeed()`.
- In the stub central, change `scan: { _, _ in Task { await calls.scan() }; return scan.stream },` to `scan: { _, _ in Task { await calls.scan() }; return scan.makeStream() },`.
- In `return AdapterStubs(…)`, change `scanCont: scan.continuation, centralEvents:` to `scanCont: scan, centralEvents:`.

- [ ] **Step 2: Write the failing tests**

In `FCBDriverAdapterCBMCoexistenceTests.swift`, inside `extension FCBDriverAdapterCBMTests`, add after `bleOnlineWithOpenChannel(_:)`:
```swift
    /// Another owner's scan supersedes BLE's while Bluetooth stays on (FCB runs one radio scan per
    /// central). BLE must not stay "online" without discovering: the driver reports a transient
    /// adapter problem, so the interface leaves `.online` and its retry restarts the driver.
    @Test func aSupersededBLEScanIsReportedAsATransientAdapterProblem() async {
        let rig = await makeCoexistRig(bleInterval: 0.01)
        let driver = BLEDriver.fcb(central: rig.central, peripheral: noopPeripheralClient())
        let log = DriverEventLog(driver.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
        #expect(await log.first(isPeerDiscovered) != nil)
        let other = RadioScanLog(rig.central.scan([coexistRadioServiceUUID], ScanOptions(allowDuplicates: true)))
        let lost = await log.first(within: 2) { if case .unavailable(.other) = $0 { return true }; return false }
        #expect(lost != nil, "a superseded BLE scan went unreported")
        other.cancel()
        log.cancel()
        await driver.stop()
    }

    /// An off immediately followed by on reaches FCB (and the adapter) as two `.poweredOn` states
    /// (CoreBluetooth reads `state` at callback time), so the adapter brings its central up twice.
    /// Its second scan replaces its OWN first one: that is not a scan lost to another owner.
    @Test func aRepeatPoweredOnReplacingOurOwnScanIsNotALostScan() async {
        let rig = await makeCoexistRig(bleInterval: 0.01)
        let driver = BLEDriver.fcb(central: rig.central, peripheral: noopPeripheralClient())
        let log = DriverEventLog(driver.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
        #expect(await log.first(isPeerDiscovered) != nil)
        CBMCentralManagerMock.simulatePowerOff()
        CBMCentralManagerMock.simulatePowerOn()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(!log.events.value.contains { if case .unavailable = $0 { return true }; return false })
        #expect(rig.manager.isScanning)
        log.cancel()
        await driver.stop()
    }
```

- [ ] **Step 3: Run the tests to verify the first fails**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership --filter ReTiCAInterfacesTests > /tmp/fcb-scan-ownership/t5lost-red.txt 2>&1`, then `grep -n "error:\|recorded an issue\|Test run with" /tmp/fcb-scan-ownership/t5lost-red.txt`. Expected:
- `Test run with 277 tests`, with exactly one failure: `aSupersededBLEScanIsReportedAsATransientAdapterProblem` ("a superseded BLE scan went unreported").
- Every stub test still passes on `ScanFeed`.
- `aRepeatPoweredOnReplacingOurOwnScanIsNotALostScan` PASSES. It pins the guard added in Step 4; its mutation is M-c3.

- [ ] **Step 4: Implement**

In `FCBDriverAdapter.swift`:
- Below `private var tasks: [Task<Void, Never>] = []`, add:
  ```swift
      /// This session's scan task (also in `tasks`), replaced on a repeat poweredOn.
      private var scanTask: Task<Void, Never>?
  ```
- In `resetSession()`, right after `tasks = []`, add `scanTask = nil`.
- Replace `bringUpCentral()` with:
  ```swift
      private func bringUpCentral() {
          // A repeat poweredOn replaces this session's own scan: cancel it first, so its stream ends
          // as "cancelled" (ours, on purpose) and never reads as lost to another owner.
          scanTask?.cancel()
          let myEpoch = epoch
          let task = Task { [central] in
              for await discovered in central.scan([bleV22ServiceUUID], ScanOptions(allowDuplicates: true)) {
                  self.handleDiscovered(discovered)
              }
              // FCB ended the scan without us cancelling it. Bluetooth off: handleCentralState reports
              // that and the next poweredOn scans again. Still on: another owner's scan superseded ours.
              guard !Task.isCancelled else { return }
              var states = central.state().makeAsyncIterator()
              if await states.next() == .poweredOn { self.scanLost(epoch: myEpoch) }
          }
          scanTask = task
          tasks.append(task)
          scanning = true
          checkReady()
      }

      /// Our scan was superseded while Bluetooth stayed on: BLE is not discovering any more. Report it
      /// as a transient adapter problem, so the interface leaves `.online` and its retry restarts us.
      private func scanLost(epoch sessionEpoch: Int) {
          guard epoch == sessionEpoch else { return }
          scanning = false
          fireUnavailable(.other("scan superseded by another scanner"))
      }
  ```

- [ ] **Step 5: Run the tests to verify they pass**

Run the Step 3 command into `/tmp/fcb-scan-ownership/t5lost-green.txt` and grep. Expected: `Test run with 277 tests in 10 suites passed`.

- [ ] **Step 6: Mutations. Two batches, because M-c1 silences every alarm and would mask M-c3**

**Batch c-i:**
- M-c1: replace `if await states.next() == .poweredOn { self.scanLost(epoch: myEpoch) }` with `if await states.next() == .poweredOn { _ = myEpoch }`.

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership --filter "aSupersededBLEScan|aRepeatPoweredOn" > /tmp/fcb-scan-ownership/t5lost-mutA.txt 2>&1`, then grep `recorded an issue\|passed after`. Expected: FAIL `aSupersededBLEScanIsReportedAsATransientAdapterProblem` (`lost → nil`). Revert M-c1.

**Batch c-ii:**
- M-c3: delete the line `scanTask?.cancel()` in `bringUpCentral`.

Run the same filter into `/tmp/fcb-scan-ownership/t5lost-mutB.txt`. Expected: FAIL `aRepeatPoweredOnReplacingOurOwnScanIsNotALostScan`. The adapter's second scan supersedes its own first, and the first reads as a loss. Both of these were verified in the lane-F scratch run. Revert M-c3.

**Not mutation-testable, for the reviewer to read:** the `== .poweredOn` state check, the clause that says a power-off is not a lost scan. Replacing it with "always alarm" leaves every test green. The adapter's `announcedUnavailable` latch lets `.poweredOff` from `handleCentralState` win in practice, so no driver event distinguishes the two (a probe test was written and dropped for exactly this reason). The check matters for the cause the app shows: "scan superseded" on a power-off would mislabel Diagnostics.

- [ ] **Step 7: Run again to confirm green after reverting**

Run the Step 3 command into `/tmp/fcb-scan-ownership/t5lost-green2.txt`. Expected: 277 passed.

- [ ] **Step 8: Commit**

Write `/tmp/fcb-scan-ownership/commit-msg.txt`:
```
fix: BLE driver reports a scan lost to another owner

FCB runs one radio scan per central and now finishes a superseded scan's
stream instead of letting it go quiet. When the driver's scan stream
ends without the driver cancelling it while Bluetooth is still on,
another owner took the radio: the driver reports a transient
.unavailable(.other), so BLEInterface leaves .online and its adapter
retry restarts the driver, instead of BLE staying "online" without
discovering. A power-off is left to the state stream, and a repeat
poweredOn cancels the driver's own previous scan first so replacing it
never reads as a loss. The adapter-test stub central now gives each
scan() call its own stream, as FCB does.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run:
```
git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership add Sources/ReTiCAInterfaces/FCBDriverAdapter.swift Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMCoexistenceTests.swift
git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership commit -F /tmp/fcb-scan-ownership/commit-msg.txt
git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership log -1 "--format=%(trailers:key=Claude-Session)"
```

---

### Task 6: Coexistence and power-cycle regression pins over the live FCB client; fast-forward ReTiCA main

These tests pin FCB behaviour as the RBTP BLE driver sees it, on the one shared central. They already pass once Part 1 is on FCB main. Their mutations live in FCB, which must not be touched in the main checkout (lane E builds against it), so step (b) runs them against a mutated throwaway FCB copy.

**Files:**
- Modify: `/Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership/Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMCoexistenceTests.swift` (append four tests to the `extension FCBDriverAdapterCBMTests`)
- Temporary only (never committed): `/Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership/Package.swift:20`, `Sources/ReTiCAInterfaces/FCBDriverAdapter.swift`, and the copy `/tmp/fcb-scan-ownership/mut/FCB/`

**Interfaces:**
- Consumes: Task 4's rig and helpers, listed in its Produces.
- Produces: none.

- [ ] **Step 1: Add the tests**

Inside `extension FCBDriverAdapterCBMTests { … }`, after `aRestartDuringASlowStopKeepsTheNewSessionsEventStream`, add:

```swift
    /// Picker OPEN: the app stops BLE and the picker starts its scan at once; BLE's stop is still
    /// disconnecting when the picker's scan begins. Its late teardown must not end that scan.
    @Test func aSlowBLEStopDoesNotEndTheRadioPickersScan() async {
        let rig = await makeCoexistRig(bleInterval: 0.4)
        guard let (driver, log) = await bleOnlineWithOpenChannel(rig) else { return }
        let stop = Task { await driver.stop() }
        let picker = RadioScanLog(rig.central.scan([coexistRadioServiceUUID], ScanOptions(allowDuplicates: true)))
        #expect(await poll(within: 2) { picker.discoveries.value > 0 })
        await stop.value
        try? await Task.sleep(nanoseconds: 200_000_000)

        let before = picker.discoveries.value
        #expect(await poll(within: 1) { picker.discoveries.value > before }, "the picker's scan stopped")
        #expect(!picker.ended.value)
        picker.cancel()
        log.cancel()
    }

    /// Picker DISMISS, scan half: after the old teardown resumes, the new session still scans
    /// (BLE "online" but not discovering was the field symptom).
    @Test func aRestartDuringASlowStopKeepsTheNewSessionScanning() async {
        let rig = await makeCoexistRig(bleInterval: 0.4)
        guard let (driver, log) = await bleOnlineWithOpenChannel(rig) else { return }
        let stop = Task { await driver.stop() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let restarted = DriverEventLog(driver.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
        await stop.value
        try? await Task.sleep(nanoseconds: 500_000_000)

        #expect(rig.manager.isScanning, "the old session's teardown stopped the new session's scan")
        restarted.cancel()
        log.cancel()
        await driver.stop()
    }

    /// Bluetooth switched off with a GATT channel open: FCB ends the channel's notification stream
    /// (CoreBluetooth sends no didDisconnect), the adapter reports the channel closed, and a stop
    /// afterwards returns.
    @Test func anOpenChannelClosesWhenBluetoothPowersOff() async {
        let rig = await makeCoexistRig(bleInterval: 0.05)
        guard let (driver, log) = await bleOnlineWithOpenChannel(rig) else { return }
        let mark = log.count
        CBMCentralManagerMock.simulatePowerOff()
        let closed = await log.first(after: mark, within: 3) { if case .channelClosed = $0 { return true }; return false }
        #expect(closed != nil, "the open channel was not reported closed after the power-off")
        #expect(await returns(within: 3) { await driver.stop() }, "stop hung after the power-off")
        log.cancel()
    }

    /// Bluetooth powered off while an Identity read is in flight (CoreBluetooth reports only a
    /// state change: no didDisconnect, no read callback). `readIdentity` must return — reporting
    /// the failure — and, once power is back, the next `readIdentity` of the rediscovered peer
    /// must succeed instead of hitting a stale pending read.
    @Test func readIdentityDoesNotHangAcrossABluetoothPowerCycle() async {
        let rig = await makeCoexistRig(bleInterval: 0.2)
        let driver = BLEDriver.fcb(central: rig.central, peripheral: noopPeripheralClient())
        let log = DriverEventLog(driver.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
        guard case let .peerDiscovered(handle)? = await log.first(isPeerDiscovered) else {
            Issue.record("no peerDiscovered"); log.cancel(); await driver.stop(); return
        }

        rig.peerDelegate.powerOffOnNextIdentityRead.setValue(true)
        let returned = await returns(within: 3) { await driver.readIdentity(handle) }
        #expect(returned, "readIdentity hung across the power-off")
        #expect(!rig.peerDelegate.powerOffOnNextIdentityRead.value)   // the power-off fired mid-read
        guard case .identityFailed? = await log.first(within: 1, isIdentityOutcome) else {
            Issue.record("the read cut short by the power-off was not reported as identityFailed")
            log.cancel(); await driver.stop(); return
        }

        let mark = log.count
        CBMCentralManagerMock.simulatePowerOn()
        guard case let .peerDiscovered(again)? = await log.first(after: mark, within: 8, isPeerDiscovered) else {
            Issue.record("the peer was not rediscovered after power-on"); log.cancel(); await driver.stop(); return
        }
        let mark2 = log.count
        #expect(await returns(within: 4) { await driver.readIdentity(again) }, "readIdentity hung after power-on")
        let outcome = await log.first(after: mark2, within: 1, isIdentityOutcome)
        #expect(outcome == .identityRead(again, identity: rig.peerDelegate.identity))
        log.cancel()
        await driver.stop()
    }
```

- [ ] **Step 2: Run the tests; they pass on FCB main (pins)**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership --filter ReTiCAInterfacesTests > /tmp/fcb-scan-ownership/t5-green.txt 2>&1`, then `grep -n "recorded an issue\|Test run with" /tmp/fcb-scan-ownership/t5-green.txt`.
Expected: `Test run with 281 tests in 10 suites passed` (275 after Task 4, + 2 from Task 5, + 4 here). Against unmodified FCB, probes R1, R2, R4 and the channel case all failed: picker scan killed, scan killed, `readIdentity` hung, no `channelClosed`.

- [ ] **Step 3: Mutation batch b2 (FCB copy + adapter; one batch, disjoint)**

Run each as its own command:
```
mkdir -p /tmp/fcb-scan-ownership/mut
rsync -a --delete --exclude .build --exclude .git --exclude Example /Users/ell/development/ios/pods/FCB/ /tmp/fcb-scan-ownership/mut/FCB/
```
Apply these mutations:
- M-b1 in `/tmp/fcb-scan-ownership/mut/FCB/Sources/FCBComposable/BluetoothCentralClient+Live.swift`: `stopScan: { },` → `stopScan: { await actor.mutationStopAll() },`, and add inside `CentralActor`: `func mutationStopAll() { manager.stopScan(); retireCurrentScan() }`. This restores the global stop.
- M-b3 in the same file: in `handleDidUpdateState`, replace `adapterWentDown(with: error)` with `_ = error`.
- Point the worktree at the copy: in `/Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership/Package.swift`, change `.package(path: "../FCB"),` to `.package(path: "/tmp/fcb-scan-ownership/mut/FCB"),`. The directory is still named `FCB`, so the package identity and `package: "FCB"` product references are unchanged.
- M-b2 in the worktree's `FCBDriverAdapter.swift`: insert `await central.stopScan()` on the line before `outgoing?.finish()`.

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership --filter ReTiCAInterfacesTests > /tmp/fcb-scan-ownership/t5-mut.txt 2>&1`, then `grep -n "recorded an issue\|Test run with" /tmp/fcb-scan-ownership/t5-mut.txt`. Expected FAIL (verified in the lane-F scratch run):

| Test | Fails because of | Message |
|---|---|---|
| `aSlowBLEStopDoesNotEndTheRadioPickersScan` | M-b1 + M-b2 | "the picker's scan stopped" |
| `aRestartDuringASlowStopKeepsTheNewSessionScanning` | M-b1 + M-b2 | `isScanning → false` |
| `readIdentityDoesNotHangAcrossABluetoothPowerCycle` | M-b3 | "readIdentity hung across the power-off" |
| `anOpenChannelClosesWhenBluetoothPowersOff` | M-b3 | "was not reported closed" |
| `stopNeverCallsTheGlobalStopScan` and `restartRemovesServicesAndStopsAdvertisingBeforeReAdding` | M-b2 | `stopScanned == 0` |

Revert, each as its own command:
```
git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership checkout -- Package.swift Package.resolved Sources/ReTiCAInterfaces/FCBDriverAdapter.swift
git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership status --short
```
Expected status: only `?? …` or ` M Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMCoexistenceTests.swift` (this task's uncommitted test edits). Nothing else.

- [ ] **Step 4: Run again to confirm green after reverting**

Run Step 2's command into `/tmp/fcb-scan-ownership/t5-green2.txt`. Expected: 281 passed.

- [ ] **Step 5: Commit**

Write `/tmp/fcb-scan-ownership/commit-msg.txt`:
```
test: BLE driver coexists with the radio picker's scan and survives a Bluetooth power cycle

Pins, over the live FCB client and CoreBluetoothMock, what the RBTP BLE
driver now gets from FCB on the one shared central: a slow stop no longer
ends the picker's scan, a restart during that stop keeps scanning, an
open GATT channel closes when Bluetooth powers off, and readIdentity
returns across a power-off and succeeds after power-on.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run:
```
git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership add Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMCoexistenceTests.swift
git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership commit -F /tmp/fcb-scan-ownership/commit-msg.txt
git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership log -1 "--format=%(trailers:key=Claude-Session)"
```

- [ ] **Step 6: Full ReTiCA suite, then fast-forward ReTiCA main**

Run each as its own command:
```
swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership > /tmp/fcb-scan-ownership/full.txt 2>&1
grep -n "recorded an issue\|Test run with\|Executed" /tmp/fcb-scan-ownership/full.txt
git -C /Users/ell/development/ios/pods/ReTiCA log --oneline -1
git -C /Users/ell/development/ios/pods/ReTiCA merge --ff-only fcb-scan-ownership
```
Expected:
- The full suite passes: lane C recorded 1608 tests, so expect about 1608 plus the 9 added in Tasks 4-6, plus anything lane E landed.
- If the merge refuses because ReTiCA main has moved (lane E), run `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/fcb-scan-ownership rebase main`, re-run the full suite, then retry the `merge --ff-only`.
- The ReTiCA main checkout's untracked `AUTOINTERFACE.md` is not ours: leave it.

---

# Part 3 — MeshtasticKit (commit straight to `main` at `/Users/ell/development/ios/pods/MeshtasticKit`)

### Task 7: `MeshtasticScanner` finishes when superseded, scans again after a power cycle

**Files:**
- Modify: `/Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshtasticKit/MeshtasticScanner.swift` (whole file, 29 lines)
- Modify: `/Users/ell/development/ios/pods/MeshtasticKit/Tests/MeshtasticKitTests/ScannerTests.swift` (inside `ScannerTests`, before `nameFallsBackToThePeripheralNameWhenNotAdvertised`)
- Modify (comments only): `/Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshtasticKit/MeshtasticSession.swift:37-39, 52-53, 57-58, 181-182, 615-617`. `/Users/ell/development/ios/pods/MeshtasticKit/Tests/MeshtasticKitTests/SessionSendTests.swift:116-118`. `/Users/ell/development/ios/pods/MeshtasticKit/Tests/MeshtasticKitTests/SessionReconnectTests.swift:77-80, 293-296, 335-342`.

**Interfaces:**
- Consumes: FCB main (a superseded or powered-off scan stream finishes). Test helpers `makeMockRadio()`, `waitUntil(timeout:_:)`, `CBMBackedTests`, `MockRadio.central`.
- Produces: `MeshtasticScanner.scan(central:)` keeps its signature. Its contract is now: the stream finishes only when the consumer stops iterating, when another owner's scan superseded it while Bluetooth stayed on, or when the state stream ends. Lane E's live `RadioScanner` relies on "finishes only when scanning stopped for good".

- [ ] **Step 1: Confirm a clean tree and a green baseline on the new FCB**

Run each as its own command:
```
mkdir -p /tmp/MeshtasticKit
git -C /Users/ell/development/ios/pods/MeshtasticKit status --short
swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit > /tmp/MeshtasticKit/baseline.txt 2>&1
grep -n "recorded an issue\|Test run with" /tmp/MeshtasticKit/baseline.txt
```
Expected: status shows no tracked changes. 64 tests pass on FCB main with Part 1 (verified in a scratch copy). The session's own workaround still holds.

- [ ] **Step 2: Write the failing tests**

In `ScannerTests.swift`, inside `struct ScannerTests` (the CBM suite), before `nameFallsBackToThePeripheralNameWhenNotAdvertised`, add:

```swift
        /// FCB runs one radio scan per central: a newer scan by another owner
        /// supersedes this one, and the scanner's stream finishes (for good)
        /// instead of silently going quiet. Live FCB client against CBM.
        @Test func aNewerScanByAnotherOwnerEndsTheScannerStream() async {
            let radio = await makeMockRadio()
            let found = LockIsolated(0)
            let ended = LockIsolated(false)
            let consumer = Task {
                for await _ in MeshtasticScanner.scan(central: radio.central) { found.withValue { $0 += 1 } }
                ended.setValue(true)
            }
            #expect(await waitUntil { found.value > 0 })
            let other = Task { for await _ in radio.central.scan([CBUUID]?.none, ScanOptions?.none) {} }
            let finished = await waitUntil(timeout: .seconds(2)) { ended.value }
            #expect(finished, "the superseded scanner stream must finish, not go quiet")
            other.cancel()
            consumer.cancel()
        }

        /// Bluetooth power-cycled mid-scan: CoreBluetooth stops the radio scan and
        /// never resumes it, and FCB ends the scan stream. The scanner waits for
        /// power and scans again; its stream does not finish. Live FCB client against CBM.
        @Test func scannerScansAgainAfterAPowerCycle() async {
            let radio = await makeMockRadio()
            let found = LockIsolated(0)
            let ended = LockIsolated(false)
            let consumer = Task {
                for await _ in MeshtasticScanner.scan(central: radio.central) { found.withValue { $0 += 1 } }
                ended.setValue(true)
            }
            #expect(await waitUntil { found.value > 0 })
            CBMCentralManagerMock.simulatePowerOff()
            try? await Task.sleep(for: .milliseconds(200))
            let beforePowerOn = found.value
            CBMCentralManagerMock.simulatePowerOn()
            let rescanned = await waitUntil(timeout: .seconds(5)) { found.value > beforePowerOn }
            #expect(rescanned, "the scanner must scan again once Bluetooth is back on")
            #expect(!ended.value)
            consumer.cancel()
        }
```

- [ ] **Step 3: Run the tests to verify the power-cycle test fails**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter "aNewerScanByAnotherOwnerEndsTheScannerStream|scannerScansAgainAfterAPowerCycle" > /tmp/MeshtasticKit/t6-red.txt 2>&1`, then `grep -n "recorded an issue\|passed after" /tmp/MeshtasticKit/t6-red.txt`. Expected:
- FAIL `scannerScansAgainAfterAPowerCycle`: `rescanned` false and `!ended.value` false. FCB now finishes the scan at power-off, and the scanner finishes with it.
- PASS `aNewerScanByAnotherOwnerEndsTheScannerStream`. FCB's superseded-finish already reaches the scanner's `continuation.finish()`. This test pins the scanner's choice to finish for good rather than re-scan, and is proven by Step 6's mutation.

- [ ] **Step 4: Implement**

Replace `MeshtasticScanner.swift` entirely with:
```swift
@preconcurrency import CoreBluetooth
import FCBComposable
import Foundation

public enum MeshtasticScanner {
    /// The only scanning entry point. Waits for `.poweredOn` (CoreBluetooth silently drops an
    /// earlier scan), filters on the Meshtastic service UUID, and ends ITS OWN FCB scan when the
    /// consumer stops iterating (stream termination is FCB's only stop; it never calls `stopScan`).
    ///
    /// FCB runs one radio scan per central. When FCB ends this scan, the scanner looks at the
    /// adapter: Bluetooth left `.poweredOn` → wait for power and scan again; still `.poweredOn` →
    /// a newer scan by another owner superseded this one, so the stream finishes for good.
    public static func scan(central: BluetoothCentralClient) -> AsyncStream<DiscoveredRadio> {
        AsyncStream { continuation in
            let task = Task {
                while await waitForPoweredOn(central) {
                    for await found in central.scan([MeshGATT.serviceUUID], ScanOptions?.none) {
                        continuation.yield(DiscoveredRadio(
                            id: found.peripheral.id,
                            name: found.advertisementData.localName ?? found.peripheral.name,
                            rssi: found.rssi
                        ))
                    }
                    if Task.isCancelled { break }
                    // Superseded while Bluetooth stayed on: another owner has the radio now.
                    if await currentState(central) == .poweredOn { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `true` once the adapter reports `.poweredOn`; `false` if cancelled first or the state
    /// stream ended.
    private static func waitForPoweredOn(_ central: BluetoothCentralClient) async -> Bool {
        for await state in central.state() {
            if Task.isCancelled { return false }
            if state == .poweredOn { return true }
        }
        return false
    }

    /// The adapter's current state (FCB's state stream replays it first).
    private static func currentState(_ central: BluetoothCentralClient) async -> CBManagerState? {
        for await state in central.state() { return state }
        return nil
    }
}
```

Comment refresh: FCB fixed the defects these comments describe; each workaround stays. Apply these exact replacements.

In `MeshtasticSession.swift`:
- `:38-39` replace
  ```
      /// teardown — whichever comes first — resolves it. FCB fails no pending op on a
      /// power-off, so an attempt must never depend on FCB to end. An attempt that
  ```
  with
  ```
      /// teardown — whichever comes first — resolves it. FCB once failed no pending op
      /// on a power-off (fixed in FCB, Meshtastic lane F); an attempt still never depends
      /// on FCB to end. An attempt that
  ```
- `:52-53` replace
  ```
      /// FIFO slot for ToRadio writes: FCB holds one pending write per characteristic
      /// and overwrites it, so two in-flight writes would leak the first.
  ```
  with
  ```
      /// FIFO slot for ToRadio writes: FCB holds one pending write per characteristic,
      /// and a second write fails the first with `operationCancelled`.
  ```
- `:57-58` replace
  ```
      /// Bumped by `resetWriteSlot()` on every link teardown. FCB can leak a pending
      /// write forever (a power-off fails no pending op), so a writer that never
  ```
  with
  ```
      /// Bumped by `resetWriteSlot()` on every link teardown. Older FCB leaked a pending
      /// write forever at a power-off; the slot still never waits on FCB, so a writer that never
  ```
- `:181-182` replace
  ```
      /// The adapter left `.poweredOn` mid-attempt (iOS reports a power-off as a
      /// state change only, and FCB fails no pending op on it).
  ```
  with
  ```
      /// The adapter left `.poweredOn` mid-attempt (iOS reports a power-off as a
      /// state change only; the session ends the attempt itself instead of waiting on FCB).
  ```
- `:615-617` replace
  ```
      /// the caller enters backoff — the same path as a lost link. It must not wait
      /// for FCB: after a power-off FCB's disconnect is a no-op and nothing fails the
      /// read. Cancelled by `attemptConnect`'s defer when the handshake ends.
  ```
  with
  ```
      /// the caller enters backoff — the same path as a lost link. It does not wait
      /// for FCB to fail the read (older FCB never did after a power-off).
      /// Cancelled by `attemptConnect`'s defer when the handshake ends.
  ```

In `SessionSendTests.swift:116-118`, replace
```
        /// Power-off while FCB's write is pending: CBM drops the write response
        /// (CBMCentralManagerMock.swift:1477-1478 only responds while `.connected`) and
        /// FCB fails no pending op on a state change, so FCB never answers that write.
```
with
```
        /// Power-off while FCB's write is pending: CBM drops the write response
        /// (CBMCentralManagerMock.swift:1477-1478 only responds while `.connected`); FCB
        /// now fails that write with `.poweredOff` (older FCB never answered it).
```

In `SessionReconnectTests.swift`:
- `:77-80` replace
  ```
      /// A fake whose FromRadio read suspends until `gate` opens, ignoring
      /// cancellation and disconnect — FCB's behaviour for a read pending at a
      /// power-off (its disconnect of a `.disconnected` peripheral is a no-op). CBM
      /// cannot hold a read of a CONNECTED peripheral open, hence the fake.
  ```
  with
  ```
      /// A fake whose FromRadio read suspends until `gate` opens, ignoring
      /// cancellation and disconnect — a dependency that never answers (older FCB
      /// did this for a read pending at a power-off). CBM cannot hold a read of a
      /// CONNECTED peripheral open, hence the fake.
  ```
- `:294-296` replace
  ```
          /// state change only — no didDisconnect. If this fails inside FCB (e.g. a
          /// stale pending read/notify slot after power-off), STOP and report: do not
          /// patch FCB in this lane.
  ```
  with
  ```
          /// state change only — no didDisconnect. FCB fails pending operations at
          /// the power-off (lane F); the session must not depend on it.
  ```
- `:335-342` replace
  ```
          /// Power-off DURING the want_config handshake: no didDisconnect, FCB fails
          /// no pending op, and a disconnect of the already-`.disconnected` peripheral
          /// is a no-op — so the handshake's FromRadio read never resolves. The hook
  ```
  with
  ```
          /// Power-off DURING the want_config handshake: no didDisconnect. (Older FCB
          /// failed no pending op, so the handshake's FromRadio read never resolved;
          /// FCB now fails it with `.poweredOff` — the session copes either way.) The hook
  ```
  and replace
  ```
          /// (the first post-power-on handshake read hits FCB's stale pending read).
  ```
  with
  ```
          /// (older FCB's stale pending read cost one extra attempt; none now).
  ```

- [ ] **Step 5: Run the whole suite to verify it passes**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit > /tmp/MeshtasticKit/t6-green.txt 2>&1`, then `grep -n "recorded an issue\|Test run with" /tmp/MeshtasticKit/t6-green.txt`.
Expected: `Test run with 66 tests in 12 suites passed`.

- [ ] **Step 6: Mutation (one line fails both new tests)**

In `MeshtasticScanner.swift`, change `if await currentState(central) == .poweredOn { break }` to `if await currentState(central) != .poweredOn { break }`. Run the Step 3 command into `/tmp/MeshtasticKit/t6-mut.txt` and grep. Expected (verified in scratch):
- FAIL `aNewerScanByAnotherOwnerEndsTheScannerStream` ("must finish": the scanner re-scans and steals the radio back).
- FAIL `scannerScansAgainAfterAPowerCycle` (`rescanned` false, `ended` true).

Revert to `==`.

- [ ] **Step 7: Run again to confirm green after reverting**

Run Step 5's command into `/tmp/MeshtasticKit/t6-green2.txt`. Expected: 66 passed.

- [ ] **Step 8: Commit to MeshtasticKit main**

Write `/tmp/MeshtasticKit/commit-msg.txt`:
```
fix: MeshtasticScanner finishes when superseded and scans again after a power cycle

FCB now ends a scan stream when a newer scan supersedes it or Bluetooth
leaves poweredOn. The scanner tells the two apart by the adapter state:
off means wait for power and scan again (CoreBluetooth never resumes a
scan), still on means another owner took the radio, so the stream ends
for good. It still stops only its own scan, by stream termination.
Comments that described the old FCB power-off and write-overwrite leaks
now say they are fixed; the session's workarounds stay.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run:
```
git -C /Users/ell/development/ios/pods/MeshtasticKit add Sources/MeshtasticKit/MeshtasticScanner.swift Sources/MeshtasticKit/MeshtasticSession.swift Tests/MeshtasticKitTests/ScannerTests.swift Tests/MeshtasticKitTests/SessionSendTests.swift Tests/MeshtasticKitTests/SessionReconnectTests.swift
git -C /Users/ell/development/ios/pods/MeshtasticKit commit -F /tmp/MeshtasticKit/commit-msg.txt
git -C /Users/ell/development/ios/pods/MeshtasticKit log -1 "--format=%(trailers:key=Claude-Session)"
```
This commit is on `main` directly, so no fast-forward step is needed.

---

# Part 4 — Every consumer stays green

### Task 8: Full suites of FCB, ReTiCA, MeshtasticKit, MeshtastifiedKit, ReTiCaMsgrCore (and MultiRouter)

**Files:** none (verification only). Logs go under `/tmp/ReTiCA/`.

**Interfaces:**
- Consumes: FCB main (Part 1), ReTiCA main (Part 2), MeshtasticKit main (Part 3).
- Produces: a pass/fail line per suite for the lane report.

- [ ] **Step 1: Run every suite against the merged mains**

Run each as its own command:
```
mkdir -p /tmp/ReTiCA
swift test --package-path /Users/ell/development/ios/pods/FCB > /tmp/ReTiCA/lanef-fcb.txt 2>&1
swift test --package-path /Users/ell/development/ios/pods/ReTiCA > /tmp/ReTiCA/lanef-retica.txt 2>&1
swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit > /tmp/ReTiCA/lanef-meshtastickit.txt 2>&1
swift test --package-path /Users/ell/development/ios/apps/Meshtastified/MeshtastifiedKit > /tmp/ReTiCA/lanef-meshtastifiedkit.txt 2>&1
swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCaMsgrCore > /tmp/ReTiCA/lanef-retica-msgr-core.txt 2>&1
swift test --package-path /Users/ell/development/ios/pods/MultiRouter > /tmp/ReTiCA/lanef-multirouter.txt 2>&1
```
Then for each log: `grep -n "recorded an issue\|Test run with\|Executed\|error:" <log>`.

Expected:

| Suite | Expected result |
|---|---|
| FCB | 145 passed, 3 known issues |
| ReTiCA | the Part 2 full-suite count |
| MeshtasticKit | 66 |
| MeshtastifiedKit | 283. A scratch run on the fixed FCB + Task 7 scanner was green. |
| ReTiCaMsgrCore | the lane D count (714) plus whatever lane E landed, all green. It builds ReTiCA main. |
| MultiRouter | identical to `/tmp/FCB-scan-ownership/baseline-multirouter.txt` from Task 1 Step 1 |

- [ ] **Step 2: Diagnose any difference before reporting**

A suite that is red, or MultiRouter differing from its baseline, is a regression until proven otherwise. Read the failing test, decide whether it depends on the old `stopScan`, on the silent superseded scan, or on leaked power-off continuations, and STOP and report with the test name and `file:line`. Do not weaken a consumer test to make it pass.

- [ ] **Step 3: Report**

Report per suite: test count, pass/fail, and known issues. Also report the FCB, ReTiCA and MeshtasticKit commit hashes (`git -C <repo> log --oneline -4`).

---

## Self-review (done while writing; kept for the reviewer)

1. **Spec coverage:**

   | Spec item | Where it is handled |
   |---|---|
   | F.1 open side | FCB Task 1 (`stopScanDoesNotEndAnotherOwnersScan`); ReTiCA Task 4 (removes the call) + Task 6 (`aSlowBLEStopDoesNotEndTheRadioPickersScan`) |
   | F.1 dismiss side, as actually caused | Task 4 (`aStaleStopResumingAfterARestartLeavesTheNewSessionAlone`, `aRestartDuringASlowStopKeepsTheNewSessionsEventStream`); Task 6 (`aRestartDuringASlowStopKeepsTheNewSessionScanning`) |
   | "superseded stream should finish + consumer reactions" | Task 1 (`aNewerScanFinishesTheSupersededStream`); Task 5 (the adapter's reaction: `aSupersededBLEScanIsReportedAsATransientAdapterProblem`, `aRepeatPoweredOnReplacingOurOwnScanIsNotALostScan`); Task 7 (the scanner's reaction); the consumer table (everyone else) |
   | "FCBDriverAdapter and MeshtasticScanner stop their own scans only" | Tasks 4 and 7 |
   | "reproduce both directions as failing probes against live FCB over CBM" | probes R1/R2, plus Tasks 4-6 tests on the live client |
   | F.2 fail every pending op when the state leaves `.poweredOn` | Task 2 (12 CBM tests + mapping) |
   | Stale read | Task 2 `firstReadAfterAPowerCycleAndReconnectSucceeds` |
   | Overwritten connect/discover* | Task 3 |
   | MeshtasticKit workaround stays, suite green | Task 7 Step 1, Task 7 Step 5, Task 8 |
   | ReTiCA BLE driver no longer hangs | Task 6 `readIdentityDoesNotHangAcrossABluetoothPowerCycle` + `anOpenChannelClosesWhenBluetoothPowersOff` |
   | Distinct error | `.poweredOff` reused (it already exists) |

2. **Placeholder scan:** every code step carries complete code. "The Part 2 full-suite count" in Task 8 is a measured value, not a placeholder: lane E may land tests concurrently.
3. **Type consistency:** the names checked across tasks are `retireCurrentScan`, `adapterDownError`, `adapterWentDown`, `drain`, `ScanConsumer`, `eventually`, `makeScanRig`, `ScanRig.actor/client/manager`, `occupyForTesting(seconds:)`, `makePowerCycleRig`, `powerCycle(_ client:)`, `disconnectHeld`, `CoexistRig.central/manager/peerDelegate`, `DriverEventLog.first(after:within:_:)`, `RadioScanLog`, `poll(within:_:)`, `returns(within:_:)` and `bleOnlineWithOpenChannel(_:)`. All are defined where first used and used with the same signatures.
4. **Review Focus:** five lines. Four have tests in their owning tasks: Task 6 channel, Task 1 scan-while-off, Task 1 break-and-drop, Task 3 double write. The L2CAP line is explicitly a code-read item, because CBM cannot reach it.
