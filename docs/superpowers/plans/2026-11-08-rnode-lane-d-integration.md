# RNode Lane D (Live Adapter and App Wiring) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## Contract issues

None is unworkable. Gaps and how this plan fills them; lanes A–C's plans (`2026-11-08-rnode-lane-{a-rnodekit,b-interface,c-app-ui}.md`) already agree on each.

1. **Contract 2's messages need the mismatch list,** which the session reports as `.configurationRejected` just before its terminal `.disconnected`. The event mapper remembers the last list and formats it when the terminal end arrives (Task 1).
2. **`RNodeLiveMessage` lives in `ReTiCARNodeLive`,** because formatting takes kit types. The app reads `RNodeLiveMessage.needsUserAction(_:)` from there for its re-dial gate (Task 8), as MeshCore's app reads `MeshCoreLiveMessage.isPolicyFailure`.
3. **App-local settings to ReTiCA params.** Lane C's `RNodeRadioSettings` holds `Int`s; Task 7 maps a complete one to `RNodeLoRaParams` with checked `UInt32`/`UInt8` conversions. An incomplete one never reaches a slot, because `rnodeWillDial` requires it complete.

**Goal:** Put ReTiCAMsgr on the air through an RNode: add `RNodeDriver.live` over one `RNodeSession`, prove it against `MockRNodeDevice` and beside BLE, Meshtastic and MeshCore on one FCB central, and wire a third radio slot through the app.

**Architecture:** Part 1 (ReTiCA) adds `ReTiCARNodeLive`, the only ReTiCA code importing RNodeKit: a pure event mapper, the user-readable messages, and an adapter over one session shaped like `MeshtasticLiveAdapter`. Part 2 (ReTiCAMsgr) adds the RNode slot beside the other two radios with Meshtastic's replace-on-change swap, a re-dial gate for failures only the user can fix, status and telemetry, and the live wiring.

**Tech Stack:** Swift 6, TCA (`TestStore`), Swift Testing, CoreBluetoothMock, RNodeKit + RNodeMock, MeshCoreKit + MeshCoreMock, MeshtasticKit + MeshtasticMock, FCB.

**Spec:** `/Users/ell/development/ios/pods/ReTiCA-worktrees/meshcore-interface/docs/superpowers/specs/2026-11-08-rnode-ble-interface-design.md`: Contract 2's live value and messages, §5.5's app half, §6 "App" (lane D), §7's "nothing starts" half, §8 D. Precedent: `2026-11-07-meshcore-lane-d-integration.md` in this `plans/` directory.

## Merge order

App work sees only **merged** ReTiCA code (`ReTiCAMsgrCore/Package.swift:13` resolves `../../../pods/ReTiCA`, the main checkout). Spec §6:

1. MeshCore lane B → ReTiCA `main`.
2. RNode lane A → `pods/RNodeKit` `main` (a person merges `rnodekit`).
3. RNode lane B → ReTiCA `main`.
4. MeshCore lane D Part 1 → ReTiCA `main`; Part 2 → `apps/ReTiCAMsgr` `main`.
5. RNode lane C → `apps/ReTiCAMsgr` `main`.
6. **Part 1** → ReTiCA `main` (needs 2, 3, 4).
7. **Part 2** → `apps/ReTiCAMsgr` `main` (needs 5, 6).

**A person approves every merge. Commit to branches only, never push, never merge.** Tasks 1 and 6 start with a gate; Tasks 5 and 11 stop and report.

## Global Constraints

- **Paths.** `R` = `/Users/ell/development/ios/pods/ReTiCA-worktrees/rnode-live`, branch `feat/rnode-live`. `A` = `/Users/ell/development/ios/apps/ReTiCAMsgr-rnode`, branch `feat/rnode-wiring`. `CORE` = `A/ReTiCAMsgrCore`. Temp files: `/tmp/ReTiCaMsgr/lane-rnode-d/`. Expand shorthand in every command. From `R`, `../FCB`, `../MeshtasticKit`, `../MeshCoreKit` and `../RNodeKit` must exist in `pods/ReTiCA-worktrees/`. `A` must be a sibling of the app directory.
- **Ownership.** Never edit `pods/FCB`, `pods/MeshtasticKit`, `pods/MeshCoreKit`, `pods/RNodeKit`, lane B's `ReTiCAInterfaces/RNode/*`, `RNodeEndpoint.swift` or `TransportEndpoint.swift`, or MeshCore's live target. A defect there: stop and report.
- **Shell (user rule).** One command per line, per Bash call. No `|`, `&&`, `||`, `;`, `$(...)`, backticks, `xargs`, heredocs into interpreters or inline scripts. Scripts in files under the temp folder. Redirecting one command's output to a log is allowed.
- **Test commands.** ReTiCA: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/rnode-live --filter <Suite> > /tmp/ReTiCaMsgr/lane-rnode-d/<name>.log 2>&1`, timeout 600000 ms; a whole-package run that outlives it uses `run_in_background: true`. App: the same with `--package-path /Users/ell/development/ios/apps/ReTiCAMsgr-rnode/ReTiCAMsgrCore`. Logs end `Test run with N tests ... passed` or `... failed`. Never run `swift test` and `xcodebuild` together. Known flakes and fixes: `deliveryFailedMarksFailedAndReloads` alone under `--filter`; `nonImprovingFreshAnnounceIsStillRebroadcast` under parallel load; signal 10/11 or spurious `LinkSessionRequestTests` failures → `swift package --package-path <pkg> clean`, retry; ENOSPC → delete `~/Library/Developer/Xcode/DerivedData`, retry once.
- **Test verification (user rule), every task with tests:** (a) run the set, all pass. (b) `cp` each production file a mutation touches to `/tmp/ReTiCaMsgr/lane-rnode-d/<name>.orig`, apply the **whole batch**, run **once**, confirm **every** new test fails. A second batch only where mutations share a line or mask each other. If one passes, fix it and restart at (a). (c) Restore with `cp`, `git -C <worktree> diff --stat` lists only intended files, run, all pass. Then commit. Stop and diagnose anything unexpected.
- **Commits.** Explicit paths. Message via the Write tool to `/tmp/ReTiCaMsgr/lane-rnode-d/msg-tN.txt`, then `git -C <worktree> commit -F <file>`, ending with the attribution lines from the executing session's system reminder at column zero. Never stage `xcuserdata/**` or `.swiftpm/**`. Stage `Package.resolved` files only in Tasks 1 and 6, only if changed.
- **Spec values (verbatim).** Interface id `rnode:<uuid>`. Live-adapter-missing text `ReTiCARNodeLive not installed`. Messages: `This RNode's firmware is too old. Update it to 1.52 or later.` / `Pairing didn't finish. Hold the RNode's button for 5 to 10 seconds until it shows a PIN, then Connect and enter that PIN.` / `This RNode no longer recognises this device. Forget the RNode in this device's Bluetooth settings, then pair again.` / `The radio didn't accept these settings: ` + clauses joined by `, ` + `. Change them in Settings, then Connect.` Clauses: `frequency 868.125 MHz (asked for 868.1 MHz)`, `bandwidth 125 kHz (asked for 62.5 kHz)`, `TX power 22 dBm (asked for 30 dBm)`, `spreading factor 12 (asked for 13)`, `coding rate 8 (asked for 9)`, `the radio didn't turn on`, and for a missing echo `<field> no reply (asked for …)`.
- **SwiftUI.** No new rows here. Any added custom row ends with `.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())`.

**Fixes inherited from Meshtastic's lane E and MeshCore's lane D**, each pinned by a test below:

- Subscribe before connecting, and drop every event before this subscription's first `.connection(.connecting)`: the kit replays state (`MeshtasticDriver+Live.swift:66-86`). → T1 `aReplayedStaleTerminalEndIsDropped`, T2 `liveRetryOfAnUnknownRadioReportsOnlyItsOwnEnd`.
- A terminal end that isn't an adapter cause → `.unavailable(.other(message))` and the stream finishes; `unauthorized` and `unsupported` map to nothing, since a following `.disconnected` would wedge the interface (`:39-46`). → T1 `anAdapterEndIsIgnored`, T2 `liveTerminalEndFinishesTheStream`.
- `pendingConnects` is a counter and `stop` disconnects until none is outstanding (`:91-150`). → T2 `liveStopRightAfterStartLeavesTheSessionDisconnected`.
- CBM suites are `extension FCBDriverAdapterCBMTests { @Suite @MainActor struct … }` in `ReTiCAInterfacesTests`, never a second `.serialized` suite.
- A session always gets the real `ContinuousClock`: its 30 s handshake and 60 s subscribe bounds sleep on it.
- `scanRadios` finishes on `.unauthorized` or `.unsupported` (`MeshtasticLive.swift:24-41`). → T3 `scanFinishesOnAnUnauthorizedAdapter`.
- One app-owned session, a lazy static, never dropped; no CoreBluetooth until a slot starts (`MeshtasticLiveWiring.swift:11`).
- Removal is `.stop`, wait for `.radioOffline`, then replace; a slot not idle at offline has a restart queued, so stop again (`AppFeature+MeshtasticRadio.swift:55-75`). The RNode slot follows **Meshtastic's** rule: replace on any `config` change (radio or parameters). → T7 `rnSlotAParameterChangeReplacesTheSlotAtConnect`.
- Read `@Shared` into locals before mutating `state.node…`. After a swap with nothing connected, show `.connecting`, not after a Disconnect. Retired counters carry across swaps. `redialDownNodes` never restarts a slot being replaced. Connect is dropped under a picker; radios aren't deferred behind it, since sessions never scan.
- A failure only the user can fix stops foreground and push-wake re-dials; Connect retries; a new config clears it (MeshCore lane D's `meshCorePolicyFailed`). → T8.
- TCA: `\.date` has no usable `testValue`, use `.constant`; `Transport` reads `\.transportDate`. Drive real actions, don't seed state. To assert nothing happened, inspect the harness log. No `store.finish()` under a presented picker.

## Review Focus

1. **The radio clamps TX power and the user fixes it.** Expected: the Contract 2 message naming both values, no re-dial on foreground, and after the user lowers TX power the next Connect starts a new slot and comes online. Tests: T2 `liveClampedTXPowerReportsBothValues`, T8 `rnRedialUserActionFailureIsNotRestartedByForegrounding`, `rnRedialAParameterChangeClearsTheFailure`.
2. **First-ever connect: pairing, then the firmware's drop.** Expected: the slot stays `.connecting` or flips offline-online once, never shows a pairing error, and ends online. Tests: T2 `liveThePostPairingDropComesBackOnline`, T3 `liveInterfacePostPairingDropEndsOnline`.
3. **The RNode and a MeshCore radio are both near, sharing one service UUID.** Expected: each picker lists only its own; each session talks only to its own peripheral; dropping one leaves the other sending. Tests: T4 `anRNodeScanFindsOnlyRNodes`, `aMeshCoreScanFindsNoRNode`, `anRNodeLinkDropLeavesMeshCoreSending`.
4. **Parameters changed while connected, then Disconnect before Connect.** Expected: nothing restarts at the edit, Disconnect stops the old radio, the next Connect starts the new config once. Tests: T7 `rnSlotEditingWhileOnlineDoesNotRestart`, T8 `rnRedialDisconnectDuringASwapLeavesTheNewConfigStopped`.
5. **All three radios enabled, one misbehaves.** Expected: its swap, stop, `.unavailable` or drop leaves the others alone, and `connection` stays `.connected` while any is up. Tests: T4 suite, T7 `rnSlotSwappingTheRNodeLeavesTheOtherRadiosRunning`, T8 `rnRedialRestartsEachRadioIndependently`, T10 `rnSliceConnectionStaysUpWhileAnyRadioIs`.

---

## Files

**Part 1, `R`.** Modify `Package.swift`. Create in `Sources/ReTiCARNodeLive/`: `RNodeLiveMessage.swift`, `RNodeDriver+Live.swift` (`.live`, mapper, adapter), `RNodeLive.swift`. Create in `Tests/ReTiCAInterfacesTests/`: `RNodeLiveMappingTests`, `RNodeLiveTestSupport`, `RNodeLiveDriverTests`, `RNodeLiveInterfaceTests`, `RNodeLiveScanTests`, `RNodeCoexistenceTests`.

**Part 2, `A`.** Modify `ReTiCAMsgrCore/Package.swift`, `AppFeature.swift`, `AppFeature+MeshtasticRadio.swift` (`somethingWillDial`), `RadioScanner.swift`, `RNodeStatus.swift`, `A/ReTiCAMsgr/AppRuntime.swift` (installs after the MeshCore ones). Create `RNodeLiveWiring.swift`, `AppFeature+RNodeRadio.swift`; tests `RNodeRadioTestSupport`, `RNodeLiveWiringTests`, `RNodeRadioSlotTests`, `RNodeRedialTests`, `RNodeStatusTests`, `RNodeWholeSliceTests`.

### `AppFeature.swift` touch points

Line numbers move with MeshCore lane D and RNode lane C; find each by its text.

| Find | Change | Task |
|---|---|---|
| `static func isLoRaRadio` | also `rnode:` | 9 |
| `meshCoreSwap`, `meshCoreRetiredCounters`, `meshCorePolicyFailed` declarations | add `rnodeSwap`, `rnodeRetiredCounters` (7), `rnodeNeedsUserAction` (8) | 7, 8 |
| `somethingWillDial` (`AppFeature+MeshtasticRadio.swift`) | `\|\| rnodeWillDial` | 7 |
| `syncEndpointNodes`'s `radios = .merge(…)` | add `syncRNodeSlot(&state)` | 7 |
| `.connectTapped` after its picker guard (where `meshCorePolicyFailed` is cleared) | also clear `rnodeNeedsUserAction` | 8 |
| `.disconnectTapped` (where `meshCoreSwap?.startNext = false`) | also `rnodeSwap?.startNext = false` | 8 |
| `redialDownNodes` (`meshCoreRestart`) | add `rnodeRestart` | 8 |
| composition (`MeshCoreRadioReducer()`) | add `RNodeRadioReducer()` after it | 7 |
| `interfaceConnected` re-announce and relay re-apply | none; generic by id | 9 proves it |

---

# Part 1: ReTiCA (`R`)

### Task 1: Gate, target, mapper, messages

**Interfaces:**
- Consumes: Contract 1 types; Contract 2 `RNodeDriverEvent`, `RNodeRadioReport`, `RNodeLoRaParams`, `RNodeChannelLoad`.
- Produces:

```swift
public enum RNodeLiveMessage {
    public static let firmwareTooOld: String
    public static let pairingRequired: String
    public static let pairingRemoved: String
    public static let configurationRejectedPrefix = "The radio didn't accept these settings: "
    public static func configurationRejected(_ mismatches: [RNodeParameterMismatch]) -> String
    /// Exactly the four Contract 2 user-action failures (the last by prefix). Task 8 reads it.
    public static func needsUserAction(_ text: String) -> Bool
}
enum RNodeLiveStep: Equatable { case ignore, emit(RNodeDriverEvent), finish(RNodeDriverEvent) }
struct RNodeEventMapper: Equatable {
    mutating func map(_ event: RNodeEvent) -> RNodeLiveStep
    static func report(_ info: RNodeRadioInfo) -> RNodeRadioReport
    static func load(_ stats: RNodeChannelStats) -> RNodeChannelLoad
}
extension RNodeRadioConfig { init(_ params: RNodeLoRaParams) }
```

**Mapper rules.** Before the first `.connection(.connecting)`: `.ignore`. `.configured(info)` → `.emit(.connected(report(info)))`. `.packet(p, r, s)` → `.emit(.packet(p, rssi: r, snr: s))`. `.channelStats` → `.emit(.channelLoad(load(…)))`, dropping `currentRSSI`. `.radioError(c)` → `.emit(.hardwareError(c))`. `.configurationRejected(list)` → remember, `.ignore`. `.reconnecting` and `.disconnected(nil)` → `.emit(.disconnected(reason: nil))`. `.disconnected(reason)`: `"unauthorized"`, `"unsupported"` → `.ignore`; the four session constants → `.finish(.unavailable(.other(message)))` (rejection formats the remembered list); any other → `.finish(.unavailable(.other(reason)))`. `.adapterUnavailable(c)` → `.emit(.unavailable(mapped))`. `.connecting`, `.configuring`, `.connected` → `.ignore`. MHz and kHz print with trailing zeros dropped (868_100_000 → `868.1`, 62_500 → `62.5`).

- [ ] **Step 1: Gate.** Stop and report if any fails:
  - `git -C /Users/ell/development/ios/pods/RNodeKit merge-base --is-ancestor rnodekit main`, exit 0
  - `git -C /Users/ell/development/ios/pods/RNodeKit status --short`, no output
  - `ls /Users/ell/development/ios/pods/ReTiCA/Sources/ReTiCAInterfaces/RNode/RNodeDriver.swift` (lane B merged)
  - `ls /Users/ell/development/ios/pods/ReTiCA/Sources/ReTiCAMeshCoreLive` (MeshCore lane D Part 1 merged)
- [ ] **Step 2: Firmware drift check (spec §9).** `git -C /tmp/ReTiCaMsgr/rnode-pins/RNode_Firmware fetch`, then `git -C /tmp/ReTiCaMsgr/rnode-pins/RNode_Firmware log --oneline <pinned SHA from pods/RNodeKit/scripts/SOURCES.md>..origin/master -- RNode_Firmware.ino Utilities.h Framing.h`. Re-clone into a new empty directory if gone. A commit that changes the serial callback, the parameter echoes or `kiss_indicate_*`: stop and report.
- [ ] **Step 3: Worktree, symlink, baseline.**
  - `git -C /Users/ell/development/ios/pods/ReTiCA worktree add /Users/ell/development/ios/pods/ReTiCA-worktrees/rnode-live -b feat/rnode-live main`
  - `ln -s /Users/ell/development/ios/pods/RNodeKit /Users/ell/development/ios/pods/ReTiCA-worktrees/RNodeKit`
  - `mkdir -p /tmp/ReTiCaMsgr/lane-rnode-d`
  - ReTiCA test command, no filter, log `t1-baseline.log`. Passes; record N.
- [ ] **Step 4: Package.** `R/Package.swift`: `.library(name: "ReTiCARNodeLive", targets: ["ReTiCARNodeLive"])`, commented as the only ReTiCA code importing RNodeKit; `.package(path: "../RNodeKit")`; the target, depending on `ReTiCAInterfaces`, `RNodeKit`, `FCBComposable`, `ComposableArchitecture`; `ReTiCAInterfacesTests` gains `ReTiCARNodeLive`, `RNodeKit`, `RNodeMock`. `swift package --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/rnode-live resolve > /tmp/ReTiCaMsgr/lane-rnode-d/t1-resolve.log 2>&1`. A conflicting-identity error means the symlink layout broke: stop and report.
- [ ] **Step 5: Write the failing tests** (`RNodeLiveMappingTests`):

```swift
aReplayedStaleTerminalEndIsDropped              // first event .disconnected("radio not found") → .ignore
eventsAfterConnectingMapNormally
configuredBecomesConnectedWithTheReport         // name, firmware 1/86, platform, mcu, params == echoes
packetsKeepTheirSignal
channelStatsBecomeChannelLoad                   // every field but currentRSSI
radioErrorsBecomeHardwareErrors
reconnectingIsADisconnect
@Test(arguments: ["unauthorized", "unsupported"]) anAdapterEndIsIgnored
firmwareTooOldFinishesWithItsMessage            // .finish(.unavailable(.other(firmwareTooOld)))
pairingRequiredFinishesWithItsMessage
pairingRemovedFinishesWithItsMessage
rejectionFinishesWithTheRememberedMismatches    // .configurationRejected([txPower 30→22]) then the terminal end
rejectionMessageFormatsEveryField               // the six clauses in Global Constraints, exactly
rejectionMessageForAMissingEcho                 // [codingRate, 6, nil] → "...: coding rate no reply (asked for 6). Change them in Settings, then Connect."
anUnknownTerminalEndPassesItsReason             // "radio not found" → .finish(.unavailable(.other("radio not found")))
@Test(arguments: all causes) adapterCausesMap
needsUserActionIsExactlyTheFourMessages         // the four (a rejection by prefix): true; "radio not found", "": false
configFromParamsKeepsEveryValue                 // RNodeRadioConfig(params) field for field
```

- [ ] **Step 6: Fail,** `--filter RNodeLiveMappingTests`, log `t1-red.log`. **Step 7: Implement, green,** log `t1-green.log`.
- [ ] **Step 8: Mutation batches.** Batch 1:

| # | Mutation | Must fail |
|---|---|---|
| A1 | drop the replay guard | `aReplayedStaleTerminalEndIsDropped` |
| A2 | always `.ignore` after the guard | `eventsAfterConnectingMapNormally`, `configuredBecomesConnectedWithTheReport`, `packetsKeepTheirSignal`, `reconnectingIsADisconnect`, `adapterCausesMap` |
| A3 | terminal ends `.emit` instead of `.finish` | the four `…FinishesWith…` tests, `anUnknownTerminalEndPassesItsReason` |
| A4 | rejection list not remembered (empty clauses) | `rejectionFinishesWithTheRememberedMismatches` |
| A5 | MHz printed with six decimals | `rejectionMessageFormatsEveryField` |
| A6 | `needsUserAction` true for any text | `needsUserActionIsExactlyTheFourMessages` |
| A7 | `report` drops the MCU | `configuredBecomesConnectedWithTheReport` |

Batch 2 (restore first), hidden by A2: A8, adapter ends map to `.disconnected` (`anAdapterEndIsIgnored`); A9, `.channelStats` ignored (`channelStatsBecomeChannelLoad`); A10, `.radioError` ignored (`radioErrorsBecomeHardwareErrors`); A11, missing echo prints `nil` (`rejectionMessageForAMissingEcho`); A12, `RNodeRadioConfig(params)` swaps SF and CR (`configFromParamsKeepsEveryValue`).
- [ ] **Step 9: Restore, re-run, all pass. Step 10: Commit** `Package.swift`, `Package.resolved` if changed, sources, tests. Subject: `feat: ReTiCARNodeLive target with the event mapper and user-readable messages`.

---

### Task 2: Live adapter and loopback

**Interfaces:**
- Consumes: Task 1; `RNodeSession`; `MockRNodeDevice` (lane A's members: `receivedPackets`, `receivedFrames`, `injectPacket`, `injectChannelStats`, `injectError`, `maxTXPower`, `firmware`, `setNotifyErrors`, `disconnectAfterSubscribe`, `silentCommands`, `makeSpec`).
- Produces: `extension RNodeDriver { public static func live(session: RNodeSession) -> RNodeDriver }`; internal `final class RNodeLiveAdapter: Sendable`, shaped like `MeshtasticLiveAdapter`. Test support: `LiveRNodeRadio`, `makeLiveRNodeRadio(firmware:maxTXPower:)`, `LiveRNodeDriverRun`, `rnodeLiveParams` (Sideband defaults at 868.1 MHz). Reuses `liveWaitUntil`, `returnsWithin`.

**Adapter flow.** `start(config)` subscribes **before** connecting, counts `pendingConnects`, calls `session.connect(radio:config: RNodeRadioConfig(config.params))` from a `Task`, and pumps mapper steps on a `Task` cancelled at termination; `.finish(e)` yields `e` and finishes. `send(p)`: `try await session.send(p)`, true on return, false on any throw. `stop`: disconnect, loop while `pendingConnects > 0`, as `MeshtasticLiveAdapter.stop`.

- [ ] **Step 1: Write the failing tests** in `extension FCBDriverAdapterCBMTests { @Suite @MainActor struct RNodeLiveDriverTests }`:

```swift
liveConnectsWithTheEchoedParams                 // .connected(report): report.params == rnodeLiveParams
liveWritesTheConfigOnEveryConnect               // two connects: setter frames twice, equal
liveDeliversAPacketWithItsSignal                // injectPacket: .packet(p, rssi: -67, snr: 6.0)
liveSendsAPacket                                // send(p) true; device.receivedPackets.last == p
liveSendOf508BytesSucceeds
liveSendOf509BytesReturnsFalse                  // nothing written
liveSendBeforeConnectedReturnsFalse
liveReportsChannelLoad
liveReportsHardwareErrors                       // injectError(5): .hardwareError(5), still connected
liveClampedTXPowerReportsBothValues             // ask 30, max 22: .unavailable(.other("The radio didn't accept these settings: TX power 22 dBm (asked for 30 dBm). Change them in Settings, then Connect.")); radio never on
liveOldFirmwareReportsTheContractMessage        // firmware (1, 51)
liveRepeatedPairingFailureReportsTheContractMessage  // setNotifyErrors two × insufficientEncryption
livePeerRemovedPairingReportsTheContractMessage
liveThePostPairingDropComesBackOnline           // disconnectAfterSubscribe: .connected, .disconnected(nil), .connected; no .unavailable
liveTerminalEndFinishesTheStream                // after the rejection, the stream ends
liveRestartAfterARejectionConnectsWithTheNewConfig  // stop, start with 17 dBm: .connected
liveComesBackAfterABluetoothPowerCycle
liveStopReturnsWhileTheHandshakeIsStuck         // silentCommands [0x08]: returnsWithin(5 s)
liveStopReturnsWhileTheRadioIsOutOfRange
liveStopRightAfterStartLeavesTheSessionDisconnected
liveUnknownRadioIsUnavailable                   // .unavailable(.other("radio not found"))
liveRetryOfAnUnknownRadioReportsOnlyItsOwnEnd
liveReportsAPoweredOffAdapter
```

- [ ] **Step 2: Fail,** `--filter RNodeLiveDriverTests`, log `t2-red.log`. **Step 3: Implement.** A failure inside FCB or RNodeKit: stop and report. **Step 4: Green,** log `t2-green.log`. Real time; tens of seconds.
- [ ] **Step 5: Mutation batches.** Batch 1:

| # | Mutation | Must fail |
|---|---|---|
| C1 | `start` connects with a fixed default config | `liveConnectsWithTheEchoedParams`, `liveClampedTXPowerReportsBothValues`, `liveRestartAfterARejectionConnectsWithTheNewConfig` |
| C2 | `send` ignores throws, returns true | `liveSendOf509BytesReturnsFalse`, `liveSendBeforeConnectedReturnsFalse` |
| C3 | pump drops `.finish` steps | `liveClampedTXPowerReportsBothValues`, `liveOldFirmwareReportsTheContractMessage`, `liveRepeatedPairingFailureReportsTheContractMessage`, `livePeerRemovedPairingReportsTheContractMessage`, `liveTerminalEndFinishesTheStream`, `liveUnknownRadioIsUnavailable` |
| C4 | `stop` makes one `disconnect()`, no drain loop | `liveStopRightAfterStartLeavesTheSessionDisconnected` |
| C5 | subscribe **after** connecting, no replay guard | `liveRetryOfAnUnknownRadioReportsOnlyItsOwnEnd` |
| C6 | pump finishes at the first `.reconnecting` | `liveThePostPairingDropComesBackOnline`, `liveComesBackAfterABluetoothPowerCycle` |
| C7 | pump drops `.adapterUnavailable` | `liveReportsAPoweredOffAdapter` |

Batch 2 (restore first): C8, `send` rejects over 507 B (`liveSendOf508BytesSucceeds`); C9, pump drops `.packet` (`liveDeliversAPacketWithItsSignal`); C10, pump drops `.channelLoad` and `.hardwareError` (`liveReportsChannelLoad`, `liveReportsHardwareErrors`); C11, `stop` spawns its disconnect and returns, with `returnsWithin` bounding (`liveStopReturnsWhileTheHandshakeIsStuck`, `…OutOfRange`); C12, the driver keeps one `RNodeRadioConfig` from the first start (`liveWritesTheConfigOnEveryConnect` with a changed second config).
- [ ] **Step 6: Restore, re-run, all pass. Step 7: Commit.** Subject: `feat: live RNode driver over one RNodeSession`.

---

### Task 3: Session factory, scan, interface over the live driver

**Interfaces:**
- Consumes: Task 2, lane B's `RNodeInterface`, `RNodeScanner.scan(central:)`.
- Produces: `public enum RNodeLive { public static func makeSession() -> RNodeSession; public static func scanRadios() -> AsyncStream<DiscoveredRNode>; public static func scanRadios(central: BluetoothCentralClient) -> AsyncStream<DiscoveredRNode> }`, shaped like `MeshtasticLive.swift`. `makeSession` uses FCB's `.liveValue` and never passes a clock.

- [ ] **Step 1: Write the failing tests.**

```swift
// RNodeLiveScanTests, fake central as in MeshtasticLiveScanTests
scanYieldsWhatTheScannerFinds
scanFinishesOnAnUnauthorizedAdapter             // ends within 2 s
scanFinishesOnAnUnsupportedAdapter
scanCancellingTheConsumerEndsTheFCBScan
scanWaitsOutPoweredOff
// RNodeLiveInterfaceTests, nested CBM suite, real RNodeInterface + live driver
liveInterfaceComesOnlineWithTheReport
liveInterfaceDeliversAPacketFromTheRadio         // .packetReceived(p); telemetry.lastRSSI == -67
liveInterfaceSendsQueuedPacketsInOrder           // 5 sends: device.receivedPackets == the 5
liveInterfaceRejectedConfigIsUnavailableWithTheMessage
liveInterfaceRestartAfterARejectionComesOnline   // stop, new slot with 17 dBm, start: online
liveInterfacePostPairingDropEndsOnline
liveInterfaceStopReportsOfflineOnlyAfterTheSessionIsDown
liveInterfaceReconnectDeliversAgain
```

- [ ] **Step 2: Fail,** `--filter RNodeLiveScanTests --filter RNodeLiveInterfaceTests`, log `t3-red.log`. **Step 3: Implement. Step 4: Green,** log `t3-green.log`.
- [ ] **Step 5: Mutation batch.** Drop the watch task (both adapter-finish scan tests); the watch also finishes on `.poweredOff` (`scanWaitsOutPoweredOff`); `onTermination` doesn't cancel (`scanCancellingTheConsumerEndsTheFCBScan`); the scan task's yield removed (`scanYieldsWhatTheScannerFinds`); mapper drops `.packet` (`liveInterfaceDeliversAPacketFromTheRadio`, `liveInterfaceReconnectDeliversAgain`); `send` returns true without writing (`liveInterfaceSendsQueuedPacketsInOrder`); pump finishes at the first `.reconnecting` (`liveInterfacePostPairingDropEndsOnline`); `stop` spawns its disconnect (`liveInterfaceStopReportsOfflineOnlyAfterTheSessionIsDown`); `.finish` steps dropped (`liveInterfaceRejectedConfigIsUnavailableWithTheMessage`, `liveInterfaceRestartAfterARejectionComesOnline`).
- [ ] **Step 6: Restore, re-run, all pass. Step 7: Commit.** Subject: `feat: RNodeLive session factory and terminal-aware scan`.

---

### Task 4: Coexistence on one FCB central

**Interfaces:** Consumes Tasks 2–3; `BLEDriver.fcb(central:peripheral:)`, `MeshtasticDriver.live(session:)`, `MeshCoreDriver.live(session:)`, `MockMeshtasticDevice`, `MockMeshCoreDevice`, `MockRNodeDevice`, `MeshCoreLive.scanRadios(central:)`, `DriverEventLog`, `noopPeripheralClient()`, `returns(within:)`. The rigs in `MeshtasticCoexistenceTests.swift` and `MeshCoreCoexistenceTests.swift` are `private`, so add a private `ThreeRadioRig` in `RNodeCoexistenceTests.swift`: one `BluetoothCentralClient.makeClient(actor: CentralActor(manager:))`, a ble-reticulum peer, a Meshtastic radio, a MeshCore radio, an RNode, an out-of-range RNode. Nested in `FCBDriverAdapterCBMTests`.

- [ ] **Step 1: Write the tests.** Every driver call is bounded by `returns(within: 6)`.

```swift
allThreeRadiosConnectBesideABLEPeer
anRNodeLinkDropLeavesMeshCoreSending             // MeshCore send → true; no .disconnected for it
anRNodeLinkDropLeavesMeshtasticConnected
aMeshCoreLinkDropLeavesTheRNodeSending
aBLEPeerDropLeavesEveryRadioConnected
stoppingTheRNodeLeavesTheOtherRadiosSending
packetsReachOnlyTheirOwnSession                  // inject on the RNode: no MeshCore datagram; inject on MeshCore: no RNode packet
everyRadioComesBackAfterABluetoothPowerCycle
anRNodeScanFindsOnlyRNodes                       // MeshCore and Meshtastic ids absent
aMeshCoreScanFindsNoRNode
anRNodeScanDoesNotDisconnectAnyRadio
theBLEScanRestartsAfterTheRNodePickerCloses      // peer discovered within 3 s
```

- [ ] **Step 2: Run,** `--filter RNodeCoexistenceTests`, log `t4-first.log`. These probe written code, so a first-run pass is possible; Step 3 proves them. A disconnect-filtering or scan failure in FCB or a kit: stop and report. No `withKnownIssue`.
- [ ] **Step 3: Mutation batches,** in `RNodeDriver+Live.swift` and `RNodeLive.swift` only. Batch 1: `send` always false (`aMeshCoreLinkDropLeavesTheRNodeSending`, `aBLEPeerDropLeavesEveryRadioConnected`, `anRNodeScanDoesNotDisconnectAnyRadio`); pump finishes at the first `.reconnecting` (`everyRadioComesBackAfterABluetoothPowerCycle`); `start` never connects (`allThreeRadiosConnectBesideABLEPeer`, `stoppingTheRNodeLeavesTheOtherRadiosSending`, `packetsReachOnlyTheirOwnSession`); `scanRadios(central:)` uses `MeshCoreScanner` (`anRNodeScanFindsOnlyRNodes`). Batch 2 (restore first): `onTermination` does nothing (`theBLEScanRestartsAfterTheRNodePickerCloses`). **Exception to step (b):** `aMeshCoreScanFindsNoRNode`, `anRNodeLinkDropLeavesMeshCoreSending` and `anRNodeLinkDropLeavesMeshtasticConnected` exercise MeshCoreKit, MeshtasticKit and FCB, which this lane may not edit, so no mutation in this lane's files can break them. Keep them as coexistence probes (as MeshCore lane D's Task 4 does), and name them in Task 5's report so the user can see which tests weren't mutation-checked.
- [ ] **Step 4: Restore, re-run, all pass. Step 5: Commit** the test file. Subject: `test: BLE and three radios coexist on one FCB central`.

---

### Task 5: Part 1 hand-off

- [ ] **Step 1: Full suite,** no filter, log `t5-full.log`. Passes; count = baseline + Part 1. Existing Meshtastic and MeshCore suites unedited: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/rnode-live diff main --stat -- Tests/ReTiCAInterfacesTests/Meshtastic* Tests/ReTiCAInterfacesTests/MeshCore*` is empty.
- [ ] **Step 2: No leakage.** `grep -rln "import RNodeKit" /Users/ell/development/ios/pods/ReTiCA-worktrees/rnode-live/Sources`. Expected: only files under `Sources/ReTiCARNodeLive/`.
- [ ] **Step 3: Rebase check.** `git -C /Users/ell/development/ios/pods/ReTiCA log --oneline -5 main`. If it moved: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/rnode-live rebase main`, rerun Step 1.
- [ ] **Step 4: Stop and report** commits and counts, the three Task 4 probes that weren't mutation-checked, and that merging makes `pods/RNodeKit` a required sibling for everything resolving `pods/ReTiCA`. **Do not merge or push.**

---

# Part 2: ReTiCAMsgr (`A`), after Part 1 and lane C are merged

### Task 6: Branch, dependencies, live wiring

**Interfaces:**
- Consumes: Part 1; lane C's `RadioScanner.scanRNode`.
- Produces:
  - `extension RadioScanner { static func rnodeResults(_ radios: @escaping @Sendable () -> AsyncStream<DiscoveredRNode>) -> @Sendable () -> AsyncStream<RadioScanResult> }`
  - `public enum RNodeLiveWiring { static func installDriver(into: inout DependencyValues); static func installScanner(into: inout DependencyValues) }`, with an internal `installScanner(into:source:)` overload so tests start no CoreBluetooth. Lazy private statics: one session from `RNodeLive.makeSession()`, one `.live(session:)`. `installScanner` assigns only `values.radioScanner.scanRNode`.
  - Test support (`RNodeRadioTestSupport.swift`): `RNodeRadioHarness` with `calls: [RnRadioCall]` (`enum RnRadioCall: Equatable { case start(RNodeDriverConfig), stop }`), `holdStops`, `yieldToLatest`, `waitForCalls`, `waitForStarts`, `sent`; `rnRadioStore(radio:enabled:settings:radioHarness:meshtastic:meshCore:tcp:configure:)`, built like `mcRadioStore`, with `$0.rnodeDriver = radioHarness.driver`; `rnBringRadioOnline(_:report:)`, `rnNoOverlappingStarts`, `rnRadioIDA/B`, `rnSlotIDA/B`, `rnCompleteSettings` (868_100_000, 62_500, 8, 6, 0).

- [ ] **Step 1: Gate.** Stop and report if either is missing: `ls /Users/ell/development/ios/pods/ReTiCA/Sources/ReTiCARNodeLive`; `grep -c "scanRNode" /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/RadioScanner.swift`, at least 1.
- [ ] **Step 2: Branch and baseline.** `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-rnode switch -c feat/rnode-wiring main`; if lane C's worktree is gone, `git -C /Users/ell/development/ios/apps/ReTiCAMsgr worktree add /Users/ell/development/ios/apps/ReTiCAMsgr-rnode -b feat/rnode-wiring main`. App test command, no filter, log `t6-baseline.log`. Record N.
- [ ] **Step 3: Dependencies.** In `CORE/Package.swift`, after the MeshCoreKit line: `.package(path: "../../../pods/RNodeKit")`, commented as the checkout ReTiCA's `../RNodeKit` resolves to. Add `ReTiCARNodeLive` and `RNodeKit` products to the target, `RNodeKit` to the tests. `swift package --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-rnode/ReTiCAMsgrCore resolve > /tmp/ReTiCaMsgr/lane-rnode-d/t6-resolve.log 2>&1`.
- [ ] **Step 4: Write the failing tests** (`RNodeLiveWiringTests`):

```swift
rnLiveScanMapsEachRadio                    // id, name, rssi
rnLiveScanFinishesWhenTheSourceFinishes
rnLiveScanCancellingEndsTheSource
rnLiveScanInstallsDoNotOverwriteEachOther  // all three installScanner orders: scan, scanMeshCore, scanRNode each reach their own source
```

- [ ] **Step 5: Fail,** `--filter rnLive`, log `t6-red.log`. **Step 6: Implement.** In `AppRuntime.build()` after the MeshCore installs, add `RNodeLiveWiring.installScanner(into: &$0)` and `installDriver(into: &$0)`, outside `#if DEBUG`: they build nothing until a slot starts, and Release can't start one. **Step 7: Green,** adding `--filter mcLiveScan --filter meshLiveScan`, log `t6-green.log`.
- [ ] **Step 8: Mutation batch.** Map drops the name (`rnLiveScanMapsEachRadio`); no `continuation.finish()` (`…FinishesWhenTheSourceFinishes`); no `onTermination` cancel (`…CancellingEndsTheSource`); `installScanner` assigns a whole `RadioScanner` (`rnLiveScanInstallsDoNotOverwriteEachOther`).
- [ ] **Step 9: Restore, re-run, all pass. Step 10: iOS build** as lane C's command with `A`, log `t6-build.log`; restore any scheme plist. **Step 11: Commit,** with `CORE/Package.resolved` and the Xcode project's `Package.resolved` if changed. Subject: `feat: live RNode wiring`.

---

### Task 7: The RNode slot and swap

**Interfaces:**
- Consumes: T6; Contract 3; lane C's `rnodeWillDial`, `rnodeRadioUUID`, `rnodeSettings`, `rnodeStatus`.
- Produces:

```swift
public struct RNodeSlotSwap: Equatable, Sendable { public var next: RNodeDriverConfig?; public var startNext: Bool }
// AppFeature.State: rnodeSwap: RNodeSlotSwap?, rnodeRetiredCounters: RNodeStatus.Counters
extension RNodeLoRaParams { init?(_ settings: RNodeRadioSettings) }   // nil unless frequency set and every value fits its type
extension AppFeature.State { var rnodeWantedConfig: RNodeDriverConfig? }   // rnodeWillDial ? radio + params : nil
func syncRNodeSlot(_ state: inout AppFeature.State) -> Effect<AppFeature.Action>
func finishRNodeSwap(_ state: inout AppFeature.State) -> Effect<AppFeature.Action>
func installRNodeSlot(_ state: inout AppFeature.State, _ config: RNodeDriverConfig?, start: Bool) -> Effect<AppFeature.Action>
struct RNodeRadioReducer: Reducer
```

`syncRNodeSlot`, `finishRNodeSwap` and `installRNodeSlot` copy `syncMeshtasticSlot`, `finishMeshtasticSwap` and `installMeshtasticSlot` (`AppFeature+MeshtasticRadio.swift:32-88`) with RNode names, comparing `interface.config` to `rnodeWantedConfig`. Install builds `RNodeEndpoint.State(config:)` with the default profile (no IFAC, spec §5.8) and carries counters into `rnodeRetiredCounters`. `RNodeRadioReducer`: `.radioOffline` → `finishRNodeSwap`; other delegates in Task 9. There is no immediate turn-off arm: like Meshtastic, every change waits for Connect. `.setRelayMode` needs nothing: relay is global (spec §5.8).

- [ ] **Step 1: Write the failing tests** (`RNodeRadioSlotTests`):

```swift
rnSlotConnectStartsTheChosenRadioWithItsParams  // calls[0] == .start(RNodeDriverConfig(radio: A, params: 868.1/62.5/8/6/0))
rnSlotConnectWithRNodeOffBuildsNoSlot
rnSlotConnectWithoutARadioBuildsNoSlot
rnSlotConnectWithIncompleteSettingsBuildsNoSlot // no frequency: no slot, connection stays .disconnected
rnSlotConnectWithOnlyAnRNodeShowsConnecting
rnSlotSettingsCompletedLaterStartAtTheNextConnect
rnSlotEditingWhileOnlineDoesNotRestart          // change frequency: calls unchanged until Connect
rnSlotAParameterChangeReplacesTheSlotAtConnect  // [.start(f1), .stop, .start(f2)]
rnSlotChangingTheRadioReplacesTheSlotAtConnect
rnSlotTurningOffStopsAtTheNextConnect           // off, Connect: [.start, .stop]; slot nil
rnSlotAnIdleOldSlotIsReplacedAtOnce             // Disconnect, change, Connect: [.start(f1), .stop, .start(f2)] with no second stop
rnSlotChangeWhileConnectingWaitsForItsStop
rnSlotConnectDuringASwapNeverStartsTwiceWithoutAStop
rnSlotSlotProfileHasNoIFAC                      // endpoint.rnode?.profile.ifac == nil
rnSlotRelayChangeDoesNotTouchTheRNode           // .setRelayMode(true): calls unchanged
rnSlotCountersSurviveAReplacement               // oversize 1 before; after the swap rnodeRetiredCounters.oversize == 1
rnSlotAllThreeRadiosStartAtConnect
rnSlotSwappingTheRNodeLeavesTheOtherRadiosRunning   // Meshtastic and MeshCore harness calls unchanged
rnSlotChangingMeshCoreLeavesTheRNodeRunning
@Test(arguments: [(frequency: 5_000_000_000, …), (spreadingFactor: 300, …)]) rnSlotParamsThatDoNotFitTheirTypeBuildNoSlot   // init? returns nil; no start
```

- [ ] **Step 2: Fail,** `--filter rnSlot`, log `t7-red.log`. **Step 3: Implement,** including `syncRNodeSlot` in `radios` and `|| rnodeWillDial` in `somethingWillDial`. **Step 4: Green,** adding `--filter meshSlot --filter mcSlot`, log `t7-green.log`.
- [ ] **Step 5: Mutation batches.** Batch 1:

| # | Mutation | Must fail |
|---|---|---|
| J1 | install never sends `.start` | `rnSlotConnectStartsTheChosenRadioWithItsParams`, `rnSlotSettingsCompletedLaterStartAtTheNextConnect`, `rnSlotAllThreeRadiosStartAtConnect` |
| J2 | wanted ignores `rnodeWillDial` (uses `rnodeEnabled` and a forced radio) | `rnSlotConnectWithRNodeOffBuildsNoSlot`, `…WithoutARadio…`, `…WithIncompleteSettings…` |
| J3 | `somethingWillDial` drops the RNode | `rnSlotConnectWithOnlyAnRNodeShowsConnecting` |
| J4 | config comparison only on `radio` | `rnSlotAParameterChangeReplacesTheSlotAtConnect` |
| J5 | a binding arm syncs on every settings change | `rnSlotEditingWhileOnlineDoesNotRestart` |
| J6 | swap-in-flight retarget removed | `rnSlotConnectDuringASwapNeverStartsTwiceWithoutAStop` |
| J7 | `radios` drops the MeshCore effect | `rnSlotChangingMeshCoreLeavesTheRNodeRunning` |
| J8 | `init?(settings)` traps instead of returning nil | `rnSlotParamsThatDoNotFitTheirTypeBuildNoSlot` (run that test alone, it traps) |

Batch 2 (restore first), hidden by J1 and J4: J9, install passes `RNodeEndpoint.ifac(networkName: "x", passphrase: "y")` (`rnSlotSlotProfileHasNoIFAC`); J10, install doesn't add to retired (`rnSlotCountersSurviveAReplacement`); J11, `.setRelayMode` also sends `.rnode(.stop)` (`rnSlotRelayChangeDoesNotTouchTheRNode`); J12, `finishRNodeSwap` installs even when the slot isn't idle (`rnSlotChangeWhileConnectingWaitsForItsStop`); J13, the idle check removed so an idle slot also waits for `.radioOffline` (`rnSlotAnIdleOldSlotIsReplacedAtOnce`).
- [ ] **Step 6: Restore, re-run, all pass. Step 7: Commit.** Subject: `feat: RNode radio slot that follows the settings at Connect`.

---

### Task 8: Re-dial, Disconnect, the user-action gate

**Interfaces:** Consumes T7, `RNodeLiveMessage.needsUserAction` (T1). `redialDownNodes` adds `rnodeRestart` beside the other radios', gated on `rnodeSwap == nil && endpoint.rnode != nil && !rnodeNeedsUserAction`; the early return runs all three. `.disconnectTapped` adds `state.rnodeSwap?.startNext = false`.

**User-action failures.** `AppFeature.State.rnodeNeedsUserAction: Bool`, false and session-only. `RNodeRadioReducer` sets it on `.rnode(.delegate(.adapterUnavailable(.other(text))))` when `needsUserAction(text)`. `.connectTapped` clears it after its picker guard, and its existing endpoint start then retries. `installRNodeSlot` clears it for a non-nil config, since a different radio or new parameters may succeed.

- [ ] **Step 1: Write the failing tests** (`RNodeRedialTests`):

```swift
rnRedialForegroundRestartsAStoppedRadio
rnRedialForegroundLeavesAnOnlineRadioAlone
rnRedialRestartsAnUnavailableRadio                       // .other("radio not found"): .start on foreground
@Test(arguments: [firmwareTooOld, pairingRequired, pairingRemoved, configurationRejected([txPower 30→22])])
rnRedialUserActionFailureIsNotRestartedByForegrounding
@Test(arguments: the same four) rnRedialUserActionFailureIsNotRestartedByAPushWake
@Test(arguments: the same four) rnRedialConnectRetriesAUserActionFailure   // Connect: .start; !rnodeNeedsUserAction
rnRedialAParameterChangeClearsTheFailure                 // rejected; lower TX power; Connect: new slot starts; flag false
rnRedialANewRadioIsNotHeldByTheOldFailure
rnRedialPushWakeRestartsAStoppedRadio
rnRedialNeverRestartsTheSlotASwapIsReplacing
rnRedialRestartsEachRadioIndependently                   // RNode stopped, the others online; then the reverse
rnRedialIsNotDeferredByThePicker                         // picker open, radio stopped: .start goes out; BLE stays paused
rnRedialConnectUnderAnRNodePickerIsDropped
rnRedialDisconnectDuringASwapLeavesTheNewConfigStopped
rnRedialDisconnectStopsAllThreeRadios
```

- [ ] **Step 2: Fail,** `--filter rnRedial`, log `t8-red.log`. **Step 3: Implement. Step 4: Green,** adding `--filter meshRedial --filter mcRedial`, log `t8-green.log`.
- [ ] **Step 5: Mutation batches.** Batch 1: `rnodeRestart` always `.none` (`…RestartsAStoppedRadio` (2), `rnRedialRestartsAnUnavailableRadio`, `rnRedialRestartsEachRadioIndependently`, `rnRedialIsNotDeferredByThePicker`); `.disconnectTapped` doesn't clear `startNext` (`rnRedialDisconnectDuringASwapLeavesTheNewConfigStopped`); `.connectTapped` loses its picker guard (`rnRedialConnectUnderAnRNodePickerIsDropped`). Batch 2 (restore first), hidden by the first: the gate drops `rnodeSwap == nil` (`rnRedialNeverRestartsTheSlotASwapIsReplacing`); sends `.rnode(.stop)` before `.start` even when online (`rnRedialForegroundLeavesAnOnlineRadioAlone`); the gate drops `!rnodeNeedsUserAction` (both `…IsNotRestartedBy…` tests); `.disconnectTapped` returns `.none` (`rnRedialDisconnectStopsAllThreeRadios`). Batch 3 (restore first), hidden by the gate mutation: `.connectTapped` doesn't clear the flag (`rnRedialConnectRetriesAUserActionFailure`); the flag set for every `.other` (`rnRedialRestartsAnUnavailableRadio`); install doesn't clear it (`rnRedialAParameterChangeClearsTheFailure`, `rnRedialANewRadioIsNotHeldByTheOldFailure`).
- [ ] **Step 6: Restore, re-run, all pass. Step 7: Commit.** Subject: `feat: re-dial the RNode unless only the user can fix its failure`.

---

### Task 9: Delegates, status, telemetry, announces, photo gate

**Interfaces:** Consumes Contract 3 delegates, `RNodeCounters`, `RNodeTelemetry`, `RNodeRadioReport`. Produces `RNodeStatus.Counters.init(_: RNodeCounters)`, `RNodeStatus.Params.init(_: RNodeLoRaParams)`, and `isLoRaRadio` matching `meshtastic:`, `meshcore:` or `rnode:`.

Arms, as `AppFeature+MeshtasticRadio.swift:94-125`: `.radioOnline(report)` → online, `radioName`, `firmware` (`"\(major).\(String(format: "%02d", minor))"`), `platform`, `reported`, `bitrate` (`report.params.bitrate`), clear offline reason and adapter. `.radioOffline(reason)` → offline, reason, `finishRNodeSwap`. `.adapterUnavailable(cause)` → offline, cause, and the T8 flag. Every `.rnode` action refreshes counters (retired + live) and copies telemetry (`lastRSSI`, `lastSNR`, `channelLoad` → the four percentages and `noiseFloor`, `lastHardwareError`) from `endpoint.rnode`, writing only on change.

- [ ] **Step 1: Write the failing tests** (`RNodeStatusTests`):

```swift
rnStatusRadioOnlineFillsTheStatus                // firmware "1.86", platform 0x80, reported, bitrate 1302
rnStatusFirmwareMinorIsTwoDigits                 // (1, 5) → "1.05"
rnStatusRadioOfflineRecordsTheReason
rnStatusAdapterUnavailableIsShown                // userMessage == the rejection message
rnStatusRadioOnlineClearsAnAdapterFault
rnStatusCountersFollowTheLiveSlot                // every Contract 3 counter to its field
rnStatusTelemetryFollowsTheLiveSlot              // -97, 6.25, load, noise floor, last error
rnStatusCountersSurviveAParameterChange
rnStatusRadiosKeepSeparateStatus                 // RNode online leaves meshtasticStatus and meshCoreStatus alone
rnAnnounceAFurtherInterfaceUpAnnouncesOnThatInterface   // announceDeliveryOnInterface(rnode id)
rnAnnounceRelayIsReappliedOnRNodeUp
rnAnnounceRadioDownTargetsEveryTCPInterfaceAndNothingElse // departing rnode; connected tcp, tcpserver, ble, meshtastic, meshcore
rnAnnounceARadioGoingDownAnnouncesOverTCP
rnPhotoDoesNotRideOnlyAnRNode
rnPhotoDoesNotRideThreeRadios
rnPhotoRidesWithTCPUp
```

- [ ] **Step 2: Fail,** `--filter rnStatus --filter rnAnnounce --filter rnPhoto`, log `t9-red.log`. **Step 3: Implement. Step 4: Green,** adding `--filter meshStatus --filter mcStatus --filter meshAnnounce --filter mcAnnounce`, log `t9-green.log`.
- [ ] **Step 5: Mutation batch.** `.radioOnline` arm does nothing; firmware minor unpadded; `.radioOffline` drops `reason`; `Counters.init` swaps `sent` and `received`; telemetry not copied; install doesn't add to retired; RNode arm sets `meshCoreStatus.online`; `isLoRaRadio` drops `rnode:`. Each named test fails. Batch 2 on generic code, as MeshCore's Q8–Q10: `profilePhotoMayRide` always false (`rnPhotoRidesWithTCPUp`); interface-up always `.registerDelivery` (`rnAnnounceAFurtherInterfaceUpAnnouncesOnThatInterface`); relay re-apply removed (`rnAnnounceRelayIsReappliedOnRNodeUp`).
- [ ] **Step 6: Restore, re-run, all pass. Step 7: Commit.** Subject: `feat: RNode status, telemetry, announces and the slow-radio photo rule`.

---

### Task 10: Whole slice and the Release gate

**Interfaces:** Consumes everything above. Real `LXMFServiceNode` → `LXMFNode` → `TransportEndpoint`, harness drivers whose `send` yields `.packet` to a peer.

- [ ] **Step 1: Write the tests** (`RNodeWholeSliceTests`):

```swift
rnSliceARadioComingUpAnnouncesOnTheRadioOnly       // TCP up first; TCP sends unchanged
rnSliceEachRadioAnnouncesOnlyOnItself              // all three up after TCP
rnSliceAPacketFromTheRadioRegistersItsPath         // a peer announce: learned entry names the rnode id
rnSliceConnectionStaysUpWhileAnyRadioIs            // all up, RNode drops: .connected; all down: .disconnected
rnSliceAParameterChangeDuringConnectEndsOnTheNewConfig   // rnNoOverlappingStarts
rnSliceTurnOffEndToEndLeavesNoInterface            // after Connect: interfaces and connectedInterfaces lack the id
rnGateStaleDefaultsStartNoSlot                     // rnodeAvailable false, enabled + radio + settings: onLaunch, Connect, foreground: slot nil, calls == []
rnGateStaleDefaultsDoNotShowConnecting
rnGateStaleDefaultsNeverTouchTheDriver             // \.rnodeDriver left unimplemented: no issue
```

- [ ] **Step 2: Run,** `--filter rnSlice --filter rnGate`, log `t10-first.log`. Tasks 7–9 built most of this, so a first-run pass is possible; Step 3 proves them. A production fix needs a test in the owning task's file.
- [ ] **Step 3: Mutation batch.** Interface-up always `.registerDelivery` (the two announce slice tests); install never sends `.start` (`…ParameterChangeDuringConnect…`, `…RegistersItsPath`); `finishRNodeSwap` never drops the slot (`rnSliceTurnOffEndToEndLeavesNoInterface`); `rnodeWillDial` drops `rnodeAvailable` (all three `rnGate…`); `interfaceDisconnected` always `.disconnected` (`rnSliceConnectionStaysUpWhileAnyRadioIs`).
- [ ] **Step 4: Restore, re-run, all pass. Step 5: Commit.** Subject: `test: RNode whole-slice probe and the Release gate`.

---

### Task 11: Part 2 hand-off

- [ ] **Step 1: Full suite,** no filter, log `t11-full.log`. Passes. `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-rnode diff main --stat`: no existing `Meshtastic*`, `MeshCore*`, `RadioPicker*` or `DiagnosticsSnapshot*` test file edited.
- [ ] **Step 2: Debug and Mac builds.** `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-rnode/ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -configuration Debug -destination "generic/platform=iOS Simulator" -derivedDataPath /tmp/ReTiCaMsgr/lane-rnode-d/dd build > /tmp/ReTiCaMsgr/lane-rnode-d/t11-debug.log 2>&1`; the same with `-destination "platform=macOS"`, log `t11-mac.log`.
- [ ] **Step 3: Release build.** Step 2's iOS command with `-configuration Release`, log `t11-release.log`: `** BUILD SUCCEEDED **`.
- [ ] **Step 4: No section in Release.** Expect `0` for each (the live messages in `ReTiCARNodeLive` are ungated by design, so grep only lane C's section copy):
  - `grep -c "Connect through an RNode" /tmp/ReTiCaMsgr/lane-rnode-d/dd/Build/Products/Release-iphonesimulator/ReTiCAMsgr.app/ReTiCAMsgr`
  - `grep -c "To pair, hold the RNode" /tmp/ReTiCaMsgr/lane-rnode-d/dd/Build/Products/Release-iphonesimulator/ReTiCAMsgr.app/ReTiCAMsgr`

  Control, Debug, expect at least 1 for each, in `/tmp/ReTiCaMsgr/lane-rnode-d/dd/Build/Products/Debug-iphonesimulator/ReTiCAMsgr.app/ReTiCAMsgr.debug.dylib`.
- [ ] **Step 5: Simulator smoke.** Load `xcodebuildmcp-cli`. Run Debug. Enter 868.1 MHz, toggle on: Diagnostics shows `RNode`, the settings row, `no radio chosen — choose one in Settings`. Each radio type's `Choose radio…` opens and cancels (empty lists expected). Toggle off. No crash; stop and report one. No simulator-only code.
- [ ] **Step 6: Rebase check.** `git -C /Users/ell/development/ios/apps/ReTiCAMsgr log --oneline -5 main`. If it moved: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-rnode rebase main`, rerun Steps 1–3.
- [ ] **Step 7: Stop and report** commits, counts and smoke results, and that everything below `RNodeSession` is still unverified on hardware. **Do not merge or push.** Lane E then runs spec §8's checklist; its last commit removes lane C's four `#if DEBUG` sites.

---

## Self-review

1. **Spec coverage.** Contract 2 live value → T2; messages → T1 (exact text), T2 (each from a real session end). §5.5 app half: post-pairing drop → T2, T3; pairing messages → T1, T2; no loop → lane A plus T8's gate. §5.8 IFAC none → T7 `rnSlotSlotProfileHasNoIFAC`; relay global → T7, T9. §6: coexistence → T4, T7, T8, T10; scanners split by name → T4; next-Connect rule → T7; replace on any change → T7; user-action gate → T8; diagnostics fill → T9; symlink → T1; merges → Merge order, T5, T11. §7 → T10, T11. §8 D → T2, T4, T7–T10. §9 firmware drift → T1.
2. **Step scan.** Signatures, names, assertions and mutation tables; prose only for flows the tests don't determine.
3. **Type consistency.** Checked against lane A (`RNodeSession` reasons, `RNodeParameterMismatch.Field`, `MockRNodeDevice` members, `DiscoveredRNode`), lane B (`RNodeDriverConfig`, `RNodeLoRaParams.bitrate`, `RNodeRadioReport`, `RNodeChannelLoad`, `RNodeCounters`, `RNodeTelemetry`, `RNodeEndpoint.State(config:)`, `isIdle`), lane C (`RNodeRadioSettings`, `RNodeStatus` fields, `rnodeWillDial`, `rnodeAvailable`, `scanRNode`, `chooseRNodeRadioTapped`).
4. **Review Focus.** Five items, each with named tests.
5. **Proportion.** Signatures, assertions and mutation tables; no function bodies.
