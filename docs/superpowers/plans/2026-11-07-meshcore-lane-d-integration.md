# MeshCore Lane D (Live Adapter and App Wiring) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## Contract issues

None is unworkable. These are gaps in Contracts 1–3 and how this plan fills them. Lane A's and B's plans (`2026-11-07-meshcore-lane-a-meshcorekit.md`, `-lane-b-interface.md`, read 2026-11-07) already agree on 2, 3 and 5.

1. **The channel secret would sit in reducer state.** `MeshCoreInterface.State` holds `config`, so `config.channelSecret` would appear in every state dump. This plan keeps `channelSecret: Data()` in state, and the app's driver wrapper (Task 6) fills the key and retired list at `driver.start`, so `.live` still receives 16 bytes. **Lane B must not validate `channelSecret`.** Its plan doesn't; if the merged code does, stop and raise it.
2. **Which of Contract 3's additions this plan uses.** It uses `.removeChannel`, `.channelRemoved` and `.setCanRoute`. The `.retiredChannelsCleared` delegate goes unused: only the wrapper knows which keys that start carried (Review Focus 3).
3. **`.connected` lacks `name`, `firmwareCode` and the channel slot**, which §6 wants in Diagnostics. `.live(session:details:)` takes a defaulted sink outside the `MeshCoreDriver` struct, so `.live(session:)` still works as §3 names it. It records `MeshCoreRadioDetails` before yielding `.connected`, and the app reads it at `.radioOnline`.
4. **Retired keys are forgotten after one radio's check.** `.retiredChannelsCleared` carries no radio identity, so after a radio change, a retired key's slot on the *first* radio can be stranded. The current key's slot is also left behind when the radio is changed with the feature on: §4 defines removal only for turn-off and key change. Spec behaviour, not changed. A person can remove it in the MeshCore app, and Settings says so (lane C's `radioChangeNotice`).
5. **`firmwareCode < 3`.** Contract 1 gives no channel for `.firmwareTooOld` at connect. Lane A's plan uses the fixed reason `MeshCoreSession.firmwareTooOldReason`; Task 1's mapper turns it into Contract 2's message.

**Goal:** Put ReTiCAMsgr on the air through a MeshCore radio: add `MeshCoreDriver.live` with the channel slot policy, prove it against `MockMeshCoreDevice` and beside BLE and Meshtastic on one FCB central, and wire a second radio slot through the app.

**Architecture:** Part 1 (ReTiCA) adds `ReTiCAMeshCoreLive`, the only ReTiCA code importing MeshCoreKit: a pure event mapper, a pure slot plan, and an adapter over one `MeshCoreSession`. Part 2 (ReTiCAMsgr) adds the MeshCore slot beside Meshtastic's with its own swap state machine, wraps the live driver so the key enters only at `start`, and removes our channel on turn-off.

**Tech Stack:** Swift 6, TCA (`TestStore`), Swift Testing, CoreBluetoothMock, MeshCoreKit + MeshCoreMock, FCB, MeshtasticKit + MeshtasticMock, `ReTiCAKeychain`.

**Spec:** `/Users/ell/development/ios/pods/ReTiCA-worktrees/meshcore-interface/docs/superpowers/specs/2026-11-07-meshcore-interface-design.md`: Contract 2's live value and slot policy, §6 "App" for lane D, §7's "nothing starts" half, §8's D line. Follows `/Users/ell/development/ios/pods/ReTiCA/docs/superpowers/plans/2026-10-16-meshtastic-lane-e-integration.md`. Lane C: `2026-11-07-meshcore-lane-c-app-ui.md`.

## Merge order

App work only sees **merged** ReTiCA code, because `ReTiCAMsgrCore/Package.swift:13` resolves `../../../pods/ReTiCA`, the main checkout.

- **Prerequisite:** `fix/meshtastic-message-loss-warning` → `apps/ReTiCAMsgr` `main`, any time before step 5. Task 11 checks it.

1. Lane A → `pods/MeshCoreKit` `main`: a person merges branch `meshcorekit` to `main`. Lane A itself leaves `main` at the empty root, so only this merge counts, and Task 1 gates that `main` contains it.
2. Lane B → `pods/ReTiCA` `main`.
3. Lane C → `apps/ReTiCAMsgr` `main`.
4. **Part 1** → `pods/ReTiCA` `main` (needs 1, 2).
5. **Part 2** → `apps/ReTiCAMsgr` `main` (needs 1–4).

**A person approves every merge. Commit to branches only, never push, never merge.** Tasks 5 and 11 stop and report; Tasks 1 and 6 start with a gate.

## Global Constraints

- **Paths.** `R` = `/Users/ell/development/ios/pods/ReTiCA-worktrees/meshcore-live`, branch `feat/meshcore-live`. `A` = `/Users/ell/development/ios/apps/ReTiCAMsgr-meshcore`, branch `feat/meshcore-wiring`. `CORE` = `A/ReTiCAMsgrCore`. Temp files: `/tmp/ReTiCaMsgr/lane-d/`. Expand shorthand in every command. From `R`, `../FCB`, `../MeshtasticKit` and `../MeshCoreKit` must exist in `pods/ReTiCA-worktrees/`. `A` must be a sibling of the app directory.
- **Ownership.** Never edit `pods/FCB`, `pods/MeshtasticKit`, `pods/MeshCoreKit`, or lane B's `ReTiCAInterfaces/MeshCore/*` and `TransportEndpoint.swift`. A defect there means stop and report.
- **Shell.** One command per line, per Bash call. No `|`, `&&`, `||`, `;`, `$(...)`, backticks, `xargs`, heredocs into interpreters or inline scripts. Scripts go in files under the temp folder. Redirecting one command's output to a log is allowed.
- **Test commands.** ReTiCA: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshcore-live --filter <Suite> > /tmp/ReTiCaMsgr/lane-d/<name>.log 2>&1`, timeout 600000 ms; if a whole-package run outlives that, use `run_in_background: true`. App: the same with `--package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshcore/ReTiCAMsgrCore`. The log ends `Test run with N tests ... passed` or `... failed`. Never run `swift test` and `xcodebuild` together. Known flake: `deliveryFailedMarksFailedAndReloads` alone under `--filter`. Signal 10/11 or spurious `LinkSessionRequestTests` failures: `swift package --package-path <pkg> clean`, retry. ENOSPC: delete `~/Library/Developer/Xcode/DerivedData`, retry once.
- **Test verification (user rule), every task with tests:** (a) run the set, all pass. (b) `cp` each production file a mutation touches to `/tmp/ReTiCaMsgr/lane-d/<name>.orig`, apply the **whole batch**, run the set **once**, confirm **every** new test fails. If one passes, fix it and restart at (a). A second batch appears only where mutations share a line or mask each other. (c) Restore with `cp`, `git -C <worktree> diff --stat` lists only intended files, run the set, all pass. Only then commit. If anything is unexpected, stop and diagnose.
- **Commits.** Explicit paths only. Message via the Write tool to `/tmp/ReTiCaMsgr/lane-d/msg-tN.txt`, then `git -C <worktree> commit -F <file>`. End with the attribution lines from the executing session's system reminder, at column zero. Never stage `xcuserdata/**` or `.swiftpm/**`. Stage `Package.resolved` files only in Tasks 1 and 6, only if changed.
- **Spec values (verbatim).** `channelName` `"RNSTunnel"`. `dataType` `0xFFFF`. Secret 16 bytes. Clear = `setChannel` with `""` and 16 zero bytes. Empty slot = all-zero secret **and** empty name. Datagrams ≤ 162 B. `No free channel slot on this radio`. `This radio's firmware is too old; update to v1.15 or later`. Below firmware code 11: no channel data. Interface id `meshcore:<uuid>`.
- **Secret rule.** Keys never enter `AppFeature.State`, `MeshCoreInterface.State`, an action or a log. They exist in the Keychain, in `MeshCoreSecrets` inside the wrapper's closure, in the adapter's config, and, per lane C's Tasks 4 and 7, as `MeshCoreKeyText` in Settings' view `@State` while a sheet is up. Key changes reach the reducer only as `.meshCoreKeyDidChange(MeshCoreKeyChangeResult)`, which carries no key. Never in `DiagnosticsSnapshot`, a `reason` or an `.unavailable` string.
- **SwiftUI.** No new rows here. Any added custom row ends with `.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())`.

**Fixes inherited from Meshtastic's lane E**, each pinned by a test below:

- Subscribe before connecting, and drop every event before this subscription's first `.connection(.connecting)`: the kit replays state (`MeshtasticDriver+Live.swift:66-86`).
- A terminal end that isn't an adapter cause → `.unavailable(.other(reason))`; `unauthorized` and `unsupported` map to nothing, since a following `.disconnected` would wedge the interface (`:39-46`).
- `pendingConnects` is a counter and `stop` disconnects until none is outstanding (`:91-150`).
- CBM suites are `extension FCBDriverAdapterCBMTests { @Suite @MainActor struct … }` in `ReTiCAInterfacesTests`, never a second `.serialized` suite.
- A session always gets the real `ContinuousClock`: its 30 s handshake timeout sleeps on it.
- `scanRadios` finishes on `.unauthorized` or `.unsupported` (`MeshtasticLive.swift:24-41`).
- One app-owned session, a lazy static, never dropped; no CoreBluetooth until a slot starts (`MeshtasticLiveWiring.swift:11`).
- Removal is `.stop`, wait for `.radioOffline`, then replace. A slot not idle at offline has a restart queued, so stop again (`AppFeature+MeshtasticRadio.swift:60-75`). Unlike Meshtastic, which replaces on any `config` change, replace a MeshCore slot only for a different radio (or an IFAC change, since `profile` is a `let`): a new slot resets the §5.5 limiter budgets and 600 s stamps, `nextPacketID`, the reassembler's dedupe keys and `lastBindSent`. A key change is `.stop`, `.radioOffline`, then `.start` on the same slot. Relay is `.setCanRoute`. The state's `config` keeps `channelSecret: Data()` and `retiredChannelSecrets: []` (lane B hand-off).
- Read `@Shared` into locals before mutating `state.node…`. After a swap with nothing connected, show `.connecting`, not after a Disconnect. Retired counters carry across swaps. `redialDownNodes` never restarts a slot being replaced. Connect is dropped under a picker; radios aren't deferred behind it, since sessions never scan.
- TCA: `\.date` has no usable `testValue`, use `.constant`; `Transport` reads `\.transportDate`. A test that seeds state proves nothing about reachability, so drive real actions. To assert nothing happened, inspect the harness log. No `store.finish()` under a presented picker.

## Review Focus

1. **The radio is full, the user frees a slot in the MeshCore app, and comes back.** The radio has one BLE client, so if we stayed connected the user could never free one, and we'd keep draining its message queue. Expected: report, disconnect, no automatic restart, and the next Connect succeeds. Tests: T2 `liveCoreNoFreeSlotReleasesTheRadio`, T3 `liveInterfaceRestartAfterAFreedSlotComesOnline`, T8 `mcRedialPolicyFailureIsNotRestartedByForegrounding`, `mcRedialConnectRetriesAPolicyFailure`.
2. **The link drops between `channels()` and `setChannel`.** Expected: no `.connected` for the dead link, the policy reruns once on reconnect, a slot is added at most once. Tests: T2 `liveCoreLinkLostDuringThePolicyReportsNoConnected`, `liveCoreReconnectReusesTheSlotItAdded`.
3. **The key changes again before the cleared event arrives.** Start carries retired [K1], the user retires K2, then `.retiredChannelsCleared` arrives. Expected: only K1 is forgotten. Test: T6 `mcSecretsForgetOnlyWhatThatStartCarried`.
4. **Turn-off, turn-on and Disconnect race.** Expected: never two driver starts without a stop between them, and the slot ends matching the latest setting. Tests: T7 `mcSlotBackOnDuringRemovalEndsRunning`, `mcSlotConnectDuringRemovalNeverOverlaps`, `mcSlotDisconnectDuringRemovalStillFinishes`.
5. **Both radios enabled, and one misbehaves.** One radio's swap, stop, `.unavailable` or link loss must not touch the other, and `connection` stays `.connected` while either is up. Tests: T4 suite, T7 `mcSlotSwappingOneRadioLeavesTheOtherRunning`, T8 `mcRedialRestartsEachRadioIndependently`, T10 `mcSliceConnectionStaysUpWhileEitherRadioIs`.

## Decisions recorded

- **Key path.** Keychain → `MeshCoreKeyStore.secrets()` → `MeshCoreDriver.resolvingSecrets` closure at `driver.start` → a local config copy → `MeshCoreLiveAdapter`. State holds `MeshCoreDriverConfig(radio:, channelSecret: Data(), canRoute:)`.
- **Slot identity.** `MeshCoreSlotIdentity { radio, keyGeneration }` decides whether a slot must be restarted, not `config ==`: the reducer never sees the key, and `retiredChannelSecrets` change without needing a restart. Only a different `radio` replaces the slot. A new `keyGeneration` on the same radio stops and restarts the existing slot, because replacing it would reset the airtime caps (lane B hand-off, §5.5).
- **Relay while connected.** Checked: `.setRelayMode` applies to Transport at once (`AppFeature.swift:2430-2450`), not at next Connect. So the bit follows at once too, through lane B's `.setCanRoute`, with no restart. A slot being swapped reads `relayEnabled` at install.
- **Turn-off acts at once.** Other radio settings wait for Connect (`SettingsView.swift:329`), but if turn-off waited too, then toggle-off → Disconnect → Connect would never have the radio connected at sync, and the slot would stay. `.binding(\.meshCoreEnabled)` going false runs `syncMeshCoreSlot`. Turning on, and radio or key changes, wait for Connect, with one exception: turning back on while a swap is in flight also syncs, because that swap is already replacing the slot and would otherwise end with `next` nil and the feature on.
- **A turn-off that can't reach the radio tells the user.** With an idle slot (after a Disconnect), `channelLeftOnRadio` is set. With no slot this session we can't know, so nothing is claimed, and lane C's `meshCoreTurnOffNoticeVisible` shows `turnOffNotice`, which says "may".
- **Disconnect isn't turn-off.** With the feature on, it stops the radio and keeps our slot.
- **A policy failure disconnects and finishes the stream** (old firmware, no free slot, a failed write). Staying connected holds the only BLE link and destroys queued messages (§2). `finish()` also stops a following `.disconnected` flipping the interface to `.connecting`.
- **The three policy failures (`MeshCoreLiveMessage.noFreeSlot`, `.firmwareTooOld`, `.channelSetupFailed`) stop automatic restarts.** Each attempt's handshake drains the radio's queue (§2) and can't succeed until the user acts, so `meshCorePolicyFailed` keeps foreground and push-wake re-dials away (Task 8). Only an explicit Connect retries, or installing a different radio or key. **An explicit Connect does drain the queue**, which Settings' `requiredWarning` covers. The flag is session-only, so a fresh launch tries once.
- **`.retiredChannelsCleared`** is emitted only when the list was non-empty and every matching clear succeeded, before `.connected`, including when no slot matched.

---

## Files

**Part 1, `R`.** Modify `Package.swift`. Create in `Sources/ReTiCAMeshCoreLive/`: `MeshCoreChannelPolicy.swift`, `MeshCoreDriver+Live.swift` (`.live`, mapper, adapter, details), `MeshCoreLive.swift`. Create in `Tests/ReTiCAInterfacesTests/`: `MeshCoreChannelPolicyTests`, `MeshCoreLiveMappingTests`, `MeshCoreLiveTestSupport`, `MeshCoreLiveDriverTests`, `MeshCoreLiveInterfaceTests`, `MeshCoreLiveScanTests`, `MeshCoreCoexistenceTests`.

**Part 2, `A`.** Modify `ReTiCAMsgrCore/Package.swift`, `AppFeature.swift`, `AppFeature+MeshtasticRadio.swift:27`, `MeshtasticLiveWiring.swift:24-26`, `RadioScanner.swift`, `MeshCoreStatus.swift`, `A/ReTiCAMsgr/AppRuntime.swift:131-136`, `A/ReTiCAMsgr/AppDelegate.swift:115` (comment). Create `MeshCoreLiveWiring.swift`, `AppFeature+MeshCoreRadio.swift`; tests `MeshCoreRadioTestSupport`, `MeshCoreLiveWiringTests`, `MeshCoreRadioSlotTests`, `MeshCoreRedialTests`, `MeshCoreStatusTests`, `MeshCoreWholeSliceTests`.

### `AppFeature.swift` touch points (main at `2ee1398`)

Lane C will have shifted these lines; re-find each by its text. The same goes for `AppRuntime.swift`, which lane C's Tasks 3 and 4 edit: `:131-136` above and in Task 6 are pre-lane-C numbers for the `MeshtasticLiveWiring.install…` calls. Lines owned by lane C (settings keys `311-321`, `meshCoreStatus` at `335`, actions `737-739`, no-op arm `2877-2879`) are in its plan.

| Line(s) | What | Change | Task |
|---|---|---|---|
| 282-286 | `profilePhotoMayRide` excludes `meshtastic:` | also `meshcore:` | 9 |
| 322-330 | `radioPicker`, `blePausedForRadioScan` | none, shared | — |
| 337-342 | swap, retired counters | add `meshCoreSwap`, `meshCoreRetiredCounters`, `meshCoreSlotIdentity` (7), `meshCorePolicyFailed` (8) | 7, 8 |
| 809-816 | `radioDownAnnounceTargets` | also `meshcore:` | 9 |
| 844, 1186, 3789 | will-dial (`AppFeature+MeshtasticRadio.swift:27`) | add `meshCoreWillDial` | 7 |
| 859, 1191, 3705, 3785, 3809 | `sync.meshtastic` | `sync.radios` | 7 |
| 1183 | Connect blocked under a picker | none; after this guard, clear `meshCorePolicyFailed` | 8 |
| 1198 | Disconnect clears swap's `startNext` | also `meshCoreSwap?.startNext = false` | 8 |
| 1201-1289 | `interfaceConnected` re-announce, relay re-apply | none, generic by id | 9 proves it |
| 1291-1312 | `interfaceDisconnected` | via 809-816 | 9 |
| 2430-2450 | `.setRelayMode` | also `.meshCore(.setCanRoute(enabled))` when a slot exists | 7 |
| 2994-2996 | composition | add `MeshCoreRadioReducer()` after `MeshtasticRadioReducer()` | 7 |
| 3592-3593, 3646-3654 | `syncEndpointNodes` | returns `(removals:, added:, radios:)`; `radios = .merge(syncMeshtasticSlot(&state), syncMeshCoreSlot(&state))` | 7 |
| 3772-3782, 3809 | `radioRestart` | add MeshCore's, gated on `!meshCorePolicyFailed` | 8 |
| 3797-3808 | BLE deferred under a picker | none | 8 proves it |

---

# Part 1: ReTiCA (`R`)

### Task 1: Gate, target, pure mapper and pure plan

**Interfaces:**
- Consumes: Contract 1 types, Contract 2 `MeshCoreDriverEvent`, `MeshCoreLinkParams`.
- Produces:

```swift
struct MeshCoreChannelPlan: Equatable {
    var clears: [UInt8]; var outcome: Outcome
    enum Outcome: Equatable { case use(UInt8), write(UInt8), noFreeSlot }
}
enum MeshCoreChannelPolicy {
    static let clearedSecret: Data       // 16 zero bytes
    static func isEmpty(_ channel: MeshCoreChannel) -> Bool
    static func plan(channels: [MeshCoreChannel], secret: Data, retired: [Data]) -> MeshCoreChannelPlan
}
enum MeshCoreLiveStep: Equatable { case ignore, emit(MeshCoreDriverEvent), configure(MeshCoreRadioInfo) }
struct MeshCoreEventMapper: Equatable {
    init(dataType: UInt16)
    mutating func map(_ event: MeshCoreEvent) -> MeshCoreLiveStep
    mutating func slotReady(_ index: UInt8)
    static func connected(_ info: MeshCoreRadioInfo) -> MeshCoreDriverEvent
}
public enum MeshCoreLiveMessage {
    public static let noFreeSlot: String       // Contract 2's text
    public static let firmwareTooOld: String   // Contract 2's text
    public static let channelSetupFailed: String   // "Couldn't set up the channel on this radio"
    public static func isPolicyFailure(_ text: String) -> Bool   // exactly those three; Task 8 reads it
}
```

**Plan rules.** `retired` minus `secret` decides `clears`, every matching slot in index order. Slots being cleared count as empty for `.write`. `.use` is the first slot holding `secret`.

**Mapper rules.** Before the first `.connection(.connecting)`: `.ignore`. `.configured` → `.configure`, forgetting the slot. `.channelData(i, t, p)` → `.emit(.datagram(p))` only when `i == slot && t == dataType`. `.rawData(p)` → `.emit(.datagram(p))` once a slot is ready. `.reconnecting` and `.disconnected(nil)` → `.emit(.disconnected(reason: nil))`, forgetting the slot. `.disconnected(reason)`: `unauthorized`, `unsupported` → `.ignore`; `MeshCoreSession.firmwareTooOldReason` → `.unavailable(.other(MeshCoreLiveMessage.firmwareTooOld))`; else `.unavailable(.other(reason))`. `.adapterUnavailable(c)` → `.unavailable(mapped)`. `.frame`, `.connecting`, `.configuring`, `.connected` → `.ignore`.

- [ ] **Step 1: Gate.** Stop and report if a prerequisite is missing.
  - `ls /Users/ell/development/ios/pods/MeshCoreKit/Sources/MeshCoreKit/MeshCoreScanner.swift`, which lane A's last kit task adds
  - `git -C /Users/ell/development/ios/pods/MeshCoreKit status --short`, expect no output
  - `git -C /Users/ell/development/ios/pods/MeshCoreKit merge-base --is-ancestor meshcorekit main`, expect exit 0: `main` contains lane A
  - `ls /Users/ell/development/ios/pods/ReTiCA/Sources/ReTiCAInterfaces/MeshCore`
  - `grep -c "setCanRoute" /Users/ell/development/ios/pods/ReTiCA/Sources/ReTiCANode/MeshCoreEndpoint.swift`, expect at least 1 (Contract issue 2)
- [ ] **Step 2: Format drift check (§9).** `git -C /tmp/ReTiCaMsgr/research/scotmesh/repo fetch` (re-clone `ScotMesh/RNS_Over_Meshcore` there first if it's gone), then `git -C /tmp/ReTiCaMsgr/research/scotmesh/repo log --oneline 2167780..origin/main -- Interface/MeshCore_Raw_Interface.py`. If a commit changes the wire format, stop and report.
- [ ] **Step 3: Worktree, symlink, baseline.**
  - `git -C /Users/ell/development/ios/pods/ReTiCA worktree add ../ReTiCA-worktrees/meshcore-live -b feat/meshcore-live main`
  - `ln -s /Users/ell/development/ios/pods/MeshCoreKit /Users/ell/development/ios/pods/ReTiCA-worktrees/MeshCoreKit`
  - `mkdir -p /tmp/ReTiCaMsgr/lane-d`
  - ReTiCA test command, no filter, log `t1-baseline.log`. Passes; record N.
- [ ] **Step 4: Package.** `R/Package.swift`: `.library(name: "ReTiCAMeshCoreLive", targets: ["ReTiCAMeshCoreLive"])`, commented as the only ReTiCA code importing MeshCoreKit; `.package(path: "../MeshCoreKit")`; the target, depending on `ReTiCAInterfaces`, `MeshCoreKit`, `FCBComposable`, `ComposableArchitecture`; `ReTiCAInterfacesTests` gains `ReTiCAMeshCoreLive`, `MeshCoreKit`, `MeshCoreMock`. Run `swift package --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshcore-live resolve > /tmp/ReTiCaMsgr/lane-d/t1-resolve.log 2>&1`. A conflicting-identity error means the symlink layout broke: stop and report.
- [ ] **Step 5: Write the failing tests.**

```swift
// MeshCoreChannelPolicyTests. key K, other O, retired R.
anExistingSlotWithOurKeyIsUsed              // [Public, slot(1,"x",K)] → clears [], .use(1)
theFirstOfTwoMatchingSlotsIsUsed            // K in 2 and 4 → .use(2)
theFirstEmptySlotIsWritten                  // [Public, empty1, empty2] → .write(1)
noSlotsMeansNoFreeSlot                      // [] → .noFreeSlot
aFullRadioHasNoFreeSlot
aNamedSlotWithAZeroSecretIsNotEmpty         // slot(1,"Friends",zero), slot(2,"",zero) → .write(2)
aBlankNamedSlotWithASecretIsNotEmpty        // slot(1,"",O) → .noFreeSlot
aSameNamedSlotWithAnotherSecretIsNotOurs    // slot(1,"RNSTunnel",O) → .noFreeSlot, clears []
everyRetiredSlotIsCleared                   // R in 1 and 3 → clears [1,3]
aClearedSlotCanTakeTheNewKey                // full radio, slot 2 holds R → clears [2], .write(2)
aRetiredKeyEqualToTheCurrentKeyIsNotCleared // retired [K], K in 1 → clears [], .use(1)
@Test(arguments: every fixture) nothingButRetiredSlotsIsEverCleared
   // clears ⊆ indices whose secret ∈ retired−K; a .write index was empty or cleared

// MeshCoreLiveMappingTests
aReplayedStaleTerminalEndIsDropped          // first event .disconnected("radio not found") → .ignore
eventsAfterConnectingMapNormally
configuredAsksForThePolicy
connectedCarriesPrefixKeyAndParams          // selfPrefix == key.prefix(4), publicKey == key, SF/BW/CR
channelDataFromOurSlotAndTypeIsADatagram
channelDataFromAnotherSlotIsDropped
channelDataOfAnotherTypeIsDropped
channelDataBeforeASlotIsReadyIsDropped
rawDataIsADatagramOnceConnected
rawDataBeforeASlotIsReadyIsDropped
aDropForgetsTheSlot                         // slotReady, .reconnecting, channelData → .ignore
reconnectingIsADisconnect
aTerminalEndIsUnavailableWithItsReason
@Test(arguments: ["unauthorized", "unsupported"]) anAdapterEndIsIgnored
tooOldFirmwareEndUsesTheContractMessage
@Test(arguments: all causes) adapterCausesMap
framesAreIgnored                            // Contract 1: frame OR typed
policyFailureIsExactlyTheThreePolicyMessages  // noFreeSlot, firmwareTooOld, channelSetupFailed: true; "radio not found", "": false
```

- [ ] **Step 6: Run to see them fail.** `--filter MeshCoreChannelPolicyTests --filter MeshCoreLiveMappingTests`, log `t1-red.log`.
- [ ] **Step 7: Implement**, then run to green, log `t1-green.log`.
- [ ] **Step 8: Mutation batches.** Batch 1:

| # | Mutation | Must fail |
|---|---|---|
| A1 | `plan` removes the `.use` search | `anExistingSlotWithOurKeyIsUsed`, `theFirstOfTwoMatchingSlotsIsUsed`, `aRetiredKeyEqualToTheCurrentKeyIsNotCleared` |
| A2 | `isEmpty` checks only the secret | `aNamedSlotWithAZeroSecretIsNotEmpty` |
| A3 | nothing empty → write slot 0 (ScotMesh's behaviour) | `noSlotsMeansNoFreeSlot`, `aFullRadioHasNoFreeSlot`, `aBlankNamedSlotWithASecretIsNotEmpty`, `aSameNamedSlotWithAnotherSecretIsNotOurs` |
| A4 | `clears` also takes slots named `RNSTunnel` | `nothingButRetiredSlotsIsEverCleared` |
| A5 | `clears` stops after the first match | `everyRetiredSlotIsCleared` |
| A6 | cleared slots don't count as empty | `aClearedSlotCanTakeTheNewKey` |
| B1 | drop the replay guard | `aReplayedStaleTerminalEndIsDropped` |
| B2 | always `.ignore` after the guard | `eventsAfterConnectingMapNormally`, `configuredAsksForThePolicy`, `reconnectingIsADisconnect`, `aTerminalEndIsUnavailableWithItsReason`, `tooOldFirmwareEndUsesTheContractMessage`, `adapterCausesMap`, `channelDataFromOurSlotAndTypeIsADatagram`, `rawDataIsADatagramOnceConnected` |
| B3 | `connected` uses `key.prefix(8)` | `connectedCarriesPrefixKeyAndParams` |

Batch 2 (restore first), hidden by A2 or B2:

| # | Mutation | Must fail |
|---|---|---|
| A7 | `.write` picks the last empty slot | `theFirstEmptySlotIsWritten` |
| B4 | filter ignores slot | `channelDataFromAnotherSlotIsDropped`, `channelDataBeforeASlotIsReadyIsDropped`, `aDropForgetsTheSlot` |
| B5 | filter ignores type | `channelDataOfAnotherTypeIsDropped` |
| B6 | `rawData` always passes | `rawDataBeforeASlotIsReadyIsDropped` |
| B7 | adapter ends map to `.disconnected` | `anAdapterEndIsIgnored` |
| B8 | `.frame` decodes a `0x1B` into `.datagram` | `framesAreIgnored` |
| B9 | `isPolicyFailure` returns true for any text | `policyFailureIsExactlyTheThreePolicyMessages` |

- [ ] **Step 9: Restore, re-run, all pass.**
- [ ] **Step 10: Commit** `Package.swift`, `Package.resolved` if changed, sources, tests. Subject: `feat: ReTiCAMeshCoreLive target with the channel slot plan and event mapper`.

---

### Task 2: Live adapter and loopback

**Interfaces:**
- Consumes: Task 1, `MeshCoreSession`, `MockMeshCoreDevice` (`channelSlots`, `fwVer`, `receivedFrames`, `silentCommands`, `errorReplies`, `injectChannelData`, `injectRawData`, `makeSpec`).
- Produces:

```swift
public struct MeshCoreRadioDetails: Equatable, Sendable { public var name: String; firmwareCode: UInt8; channelSlot: UInt8 }
extension MeshCoreDriver {
    public static func live(session: MeshCoreSession,
                            details: @escaping @Sendable (MeshCoreRadioDetails?) -> Void = { _ in }) -> MeshCoreDriver
}
final class MeshCoreLiveAdapter: Sendable   // internal, shaped like MeshtasticLiveAdapter
```
Test support: `LiveCoreRadio`, `makeLiveCoreRadio(channels:fwVer:initialState:)`, `LiveCoreDriverRun`, `setChannelFrames(_:)` (decodes `0x20` frames from `receivedFrames`). Reuses `liveWaitUntil`, `returnsWithin`.

**Adapter flow.** `start` keeps the config, subscribes **before** connecting, counts `pendingConnects`, connects from a `Task`, pumps on a `Task` cancelled at termination. `config.canRoute` is ignored; `MeshCoreInterface` builds the header. On `.configure(info)` the pump runs:

1. `info.firmwareCode < 11` → report and release with Contract 2's text. `channelSecret` not 16 non-zero bytes → report and release with `The channel key is missing`, and no `setChannel`.
2. `channels()`, then `plan(...)`. Run each clear, checking `Task.isCancelled` before every write. A clear the radio refuses throws, and ends the pass as below.
3. If `retired` is non-empty, yield `.retiredChannelsCleared`: reaching this step means no clear failed.
4. `.use(i)`: remember it. `.write(i)`: `setChannel(i, config.channelName, secret)`. `.noFreeSlot`: report and release with Contract 2's text.
5. `mapper.slotReady(i)`, `details(…)`, then yield `MeshCoreEventMapper.connected(info)`.

A thrown `.notConnected` ends the pass quietly: the session will reconnect and re-configure. Other thrown errors, including a refused clear or `setChannel`, report and release with `Couldn't set up the channel on this radio`, with no `.connected` (spec Contract 2: a policy failure disconnects). **Report and release** = yield `.unavailable(.other(text))`, `continuation.finish()`, `await session.disconnect()`, `details(nil)`.

`send`: no slot → false; else `sendChannelData(channelIndex: slot, dataType: config.dataType, payload:)`, true on return, false on any throw. `removeChannel`: `channels()`, then clear every slot whose secret equals the config's key; re-read rather than trust the remembered index. True if every clear succeeded or none matched; false on any throw or no config. Bounded by the session's command timeouts. `stop`: clear config and slot, `details(nil)`, disconnect, loop while `pendingConnects > 0`, as `MeshtasticLiveAdapter.stop`.

- [ ] **Step 1: Write the failing tests** in `extension FCBDriverAdapterCBMTests { @Suite @MainActor struct MeshCoreLiveDriverTests }`:

```swift
// Handshake and traffic
liveCoreConnectsWithPrefixKeyAndParams        // selfPrefix == selfKey.prefix(4); params from the mock
liveCoreRecordsDetailsBeforeConnected         // sink has name, firmware, slot when .connected is seen
liveCoreDeliversChannelDataFromOurSlot        // injectChannelData on our slot: .datagram(payload)
liveCoreDropsChannelDataFromOtherSlots        // and other data types
liveCoreDeliversARawPush
liveCoreDeliversOneDatagramPerFrame           // proves .frame isn't also mapped
liveCoreSendsTheChannelDataBytes              // receivedFrames.last == 3E slot FF FF FF + payload
liveCoreSendOfTheLargestDatagramSucceeds      // 162 B → true
liveCoreSendOfAnOversizedFrameReturnsFalse    // 169 B → false, nothing written
liveCoreSendBeforeConnectedReturnsFalse
liveCoreSendRefusedByTheRadioReturnsFalse     // errorReplies[0x3E] = TABLE_FULL
// Policy: all three outcomes
liveCorePolicyReusesASlotHoldingOurKey        // setChannelFrames == []; sends use that index
liveCorePolicyWritesTheFirstEmptySlot         // setChannelFrames == [(1, "RNSTunnel", K)]; sends use 1
liveCoreNoFreeSlotReportsTheContractMessage   // exact text; no .connected; setChannelFrames == []
liveCoreNoFreeSlotReleasesTheRadio            // session disconnected in 5 s; a later push draws no 0x0A write
@Test(arguments: [match, empty, full]) liveCoreNeverClearsAnotherSecret
   // Public at 0, slot(1,"RNSTunnel",O), slot(2,"Friends",zero): byte-identical after; indices exclude 0, 1, 2
// Retired keys
liveCoreClearsARetiredSlot                    // frame (i, "", zero16); slot now empty
liveCoreReportsRetiredClearedBeforeConnected  // order
liveCoreReportsNothingWithNoRetiredKeys
liveCoreReportsClearedWhenNoSlotHeldARetiredKey
liveCoreARefusedClearReportsAndReleases       // errorReplies[0x20], retired key in a slot: no .retiredChannelsCleared; .unavailable(.other("Couldn't set up the channel on this radio")); no .connected; session disconnected in 5 s
liveCoreClearingARetiredSlotMakesRoomForTheNewKey // full radio, one retired: .connected, new key there
liveCoreRetiredKeyEqualToTheCurrentKeyStays
// Firmware and bad keys
liveCoreFirmwareBelow11ReportsTheContractMessage  // fwVer 10; radio released
liveCoreFirmwareBelow3ReportsTheContractMessage   // fwVer 2
@Test(arguments: [Data(), 15 B, 17 B, 16 zero B]) liveCoreABadSecretIsRefusedLoudly
// Reconnect
liveCoreReconnectReusesTheSlotItAdded         // .disconnected, .connected; setChannelFrames count stays 1
liveCoreLinkLostDuringThePolicyReportsNoConnected // silentCommands holds 0x20, link drops: no .connected; later attempt connects; slot added once
liveCoreComesBackAfterABluetoothPowerCycle
// Removal
liveCoreRemoveChannelClearsOurSlot            // true; slot empty
liveCoreRemoveChannelClearsNothingElse
liveCoreRemoveChannelRereadsTheRadio          // key moved in channelSlots first: clears the moved slot, not the old index
liveCoreRemoveChannelBeforeConnectedReturnsFalse
liveCoreRemoveChannelRefusedReturnsFalse
liveCoreRemoveChannelReturnsWhenTheRadioIsSilent // silentCommands: false within the command timeout
// Stop and retry
liveCoreStopReturnsWhileTheHandshakeIsStuck   // returnsWithin(5 s)
liveCoreStopReturnsWhileTheRadioIsOutOfRange
liveCoreStopRightAfterStartLeavesTheSessionDisconnected
liveCoreUnknownRadioIsUnavailable
liveCoreRetryOfAnUnknownRadioReportsOnlyItsOwnEnd
liveCoreReportsAPoweredOffAdapter
```

- [ ] **Step 2: Run to see them fail.** `--filter MeshCoreLiveDriverTests`, log `t2-red.log`.
- [ ] **Step 3: Implement.** A failure inside FCB or MeshCoreKit: stop and report.
- [ ] **Step 4: Run to green,** log `t2-green.log`. Real-time; tens of seconds.
- [ ] **Step 5: Mutation batches.** Batch 1:

| # | Mutation | Must fail |
|---|---|---|
| C1 | plan ignored: always `setChannel(0, name, secret)`, use slot 0 | `liveCorePolicy…` (both), `liveCoreNoFreeSlot…` (both), `liveCoreNeverClearsAnotherSecret`, `liveCoreClearingARetiredSlotMakesRoomForTheNewKey`, `liveCoreSendsTheChannelDataBytes` |
| C2 | `removeChannel` clears the remembered slot with no re-read, returns true | `liveCoreRemoveChannelRereadsTheRadio`, `…BeforeConnectedReturnsFalse`, `…RefusedReturnsFalse`, `…ReturnsWhenTheRadioIsSilent` |
| C3 | `send` ignores throws and the slot check, returns true | `liveCoreSendRefusedByTheRadioReturnsFalse`, `…OversizedFrameReturnsFalse`, `…BeforeConnectedReturnsFalse` |
| C5 | details sink never called | `liveCoreRecordsDetailsBeforeConnected` |
| C6 | `.retiredChannelsCleared` yields after `.connected` | `liveCoreReportsRetiredClearedBeforeConnected` |
| C7 | yields it regardless of failures or an empty list | `liveCoreReportsNothingWithNoRetiredKeys`, `liveCoreARefusedClearReportsAndReleases` |
| C8 | remove the firmware check | `liveCoreFirmwareBelow11ReportsTheContractMessage` |
| C9 | remove the secret check | `liveCoreABadSecretIsRefusedLoudly` |
| C10 | `stop` makes one `disconnect()`, no drain loop | `liveCoreStopRightAfterStartLeavesTheSessionDisconnected` |
| C11 | subscribe **after** connecting, no replay guard | `liveCoreRetryOfAnUnknownRadioReportsOnlyItsOwnEnd` |
| C12 | a thrown `.notConnected` during the pass reports and releases | `liveCoreLinkLostDuringThePolicyReportsNoConnected` |
| C13 | `slotReady` isn't called | `liveCoreDeliversChannelDataFromOurSlot`, `liveCoreDeliversARawPush`, `liveCoreDeliversOneDatagramPerFrame` |
| C20 | `.configure` handled only on the first connection | `liveCoreReconnectReusesTheSlotItAdded` |
| C23 | pump drops `.adapterUnavailable` and terminal ends | `liveCoreUnknownRadioIsUnavailable`, `liveCoreReportsAPoweredOffAdapter` |
| C24 | `send` rejects over 161 B | `liveCoreSendOfTheLargestDatagramSucceeds` |
| C25 | no cleared event when no clear ran | `liveCoreReportsClearedWhenNoSlotHeldARetiredKey` |
| C26 | mapper passes the firmware reason through | `liveCoreFirmwareBelow3ReportsTheContractMessage` |

Batch 2 (restore first), hidden by Batch 1 or on the same lines:

| # | Mutation | Must fail |
|---|---|---|
| C4 | report and release doesn't disconnect or finish | `liveCoreNoFreeSlotReleasesTheRadio` |
| C14 | `connected` yields `selfPrefix: Data()` | `liveCoreConnectsWithPrefixKeyAndParams` |
| C15 | channel filter off | `liveCoreDropsChannelDataFromOtherSlots` |
| C16 | `removeChannel` also clears slot 0 | `liveCoreRemoveChannelClearsNothingElse` |
| C17 | `removeChannel` is a no-op returning true | `liveCoreRemoveChannelClearsOurSlot` |
| C18 | clears write the name `RNSTunnel` | `liveCoreClearsARetiredSlot` |
| C19 | `plan` called with unfiltered retired, clearing even the current key | `liveCoreRetiredKeyEqualToTheCurrentKeyStays` |
| C22 | `stop` waits on `pendingConnects` without calling `disconnect`; `returnsWithin` bounds the hang | `liveCoreStopReturnsWhileTheHandshakeIsStuck`, `…OutOfRange` |
| C27 | pump finishes the stream at the first `.reconnecting` | `liveCoreComesBackAfterABluetoothPowerCycle` |
| C28 | a refused clear is skipped and the pass continues to `.connected` | `liveCoreARefusedClearReportsAndReleases` |

- [ ] **Step 6: Restore, re-run, all pass.**
- [ ] **Step 7: Commit.** Subject: `feat: live MeshCore driver with the channel slot policy`.

---

### Task 3: Session factory, scan, interface over the live driver

**Interfaces:**
- Consumes: Task 2, `MeshCoreInterface`, `MeshCoreScanner.scan(central:)`.
- Produces: `public enum MeshCoreLive { public static func makeSession(appName: String) -> MeshCoreSession; public static func scanRadios() -> AsyncStream<DiscoveredMeshCoreRadio>; public static func scanRadios(central: BluetoothCentralClient) -> AsyncStream<DiscoveredMeshCoreRadio> }`, shaped like `MeshtasticLive.swift`. `makeSession` uses FCB's `.liveValue` and never passes a clock.

- [ ] **Step 1: Write the failing tests.**

```swift
// MeshCoreLiveScanTests, fake central as in MeshtasticLiveScanTests
scanYieldsWhatTheScannerFinds
scanFinishesOnAnUnauthorizedAdapter     // ends within 2 s
scanFinishesOnAnUnsupportedAdapter
scanCancellingTheConsumerEndsTheFCBScan
scanWaitsOutPoweredOff
// MeshCoreLiveInterfaceTests, nested CBM suite, real MeshCoreInterface + live driver. The test store overrides
// $0.meshCoreClock = ImmediateClock() and $0.meshCoreDate = DateGenerator { Date(timeIntervalSince1970: 1_700_000_000) },
// as MeshtasticRadioTestSupport.swift:135-136 does; the session keeps its own ContinuousClock
liveInterfaceComesOnlineWithRadioParams
liveInterfaceReassemblesAPacketFromThePeer // two ScotMesh frames via injectChannelData: .packetReceived(body)
liveInterfaceSendsFramedDatagrams       // 3E slot FF FF FF 52 … with dst 0
liveInterfaceRestartAfterAFreedSlotComesOnline // full: .unavailable; free a slot; .start: online
liveInterfaceStopReportsOfflineOnlyAfterTheSessionIsDown
liveInterfaceReconnectDeliversAgain     // a packet arrives after the reconnect
liveInterfaceRemovalClearsTheSlotThenStops // .removeChannel, .channelRemoved(true), .stop: slot empty, offline
```

- [ ] **Step 2: Run to see them fail,** `--filter MeshCoreLiveScanTests --filter MeshCoreLiveInterfaceTests`, log `t3-red.log`. **Step 3: Implement.** **Step 4: Green,** log `t3-green.log`.
- [ ] **Step 5: Mutation batch.**

| # | Mutation | Must fail |
|---|---|---|
| E1 | drop the watch task | `scanFinishesOnAnUnauthorizedAdapter`, `scanFinishesOnAnUnsupportedAdapter` |
| E2 | watch also finishes on `.poweredOff` | `scanWaitsOutPoweredOff` |
| E3 | `onTermination` doesn't cancel | `scanCancellingTheConsumerEndsTheFCBScan` |
| E4 | scan task's yield removed | `scanYieldsWhatTheScannerFinds` |
| E5 | `.connected` carries nil params | `liveInterfaceComesOnlineWithRadioParams` |
| E6 | mapper drops `.channelData` | `liveInterfaceReassemblesAPacketFromThePeer`, `liveInterfaceReconnectDeliversAgain` |
| E7 | `send` writes on slot 0 | `liveInterfaceSendsFramedDatagrams` |
| E8 | `start` after a release is refused | `liveInterfaceRestartAfterAFreedSlotComesOnline` |
| E9 | `stop` spawns its disconnect and returns | `liveInterfaceStopReportsOfflineOnlyAfterTheSessionIsDown` |
| E10 | `removeChannel` is a no-op returning true | `liveInterfaceRemovalClearsTheSlotThenStops` |

- [ ] **Step 6: Restore, re-run, all pass. Step 7: Commit.** Subject: `feat: MeshCoreLive session factory and terminal-aware scan`.

---

### Task 4: Coexistence on one FCB central

**Interfaces:** Consumes Tasks 2–3; `BLEDriver.fcb(central:peripheral:)`, `MeshtasticDriver.live(session:)`, `MockMeshtasticDevice`, `V22SpecDelegate`, `DriverEventLog`, `noopPeripheralClient()`, `returns(within:)`. The rig in `MeshtasticCoexistenceTests.swift:18-65` is `private`, so add a private `TwoRadioRig` in `MeshCoreCoexistenceTests.swift`: one `BluetoothCentralClient.makeClient(actor: CentralActor(manager:))`, a ble-reticulum peer, a Meshtastic radio, a MeshCore radio, an out-of-range MeshCore radio. Nested in `FCBDriverAdapterCBMTests`.

- [ ] **Step 1: Write the tests.** Every driver call is bounded by `returns(within: 6)`.

```swift
bothRadiosConnectBesideABLEPeer
aMeshCoreLinkDropLeavesMeshtasticConnected      // no .disconnected for it; send → true
aMeshtasticLinkDropLeavesMeshCoreConnected
aBLEPeerDropLeavesBothRadiosConnected
stoppingMeshCoreLeavesMeshtasticSending
stoppingMeshtasticLeavesMeshCoreSending
stoppingBLELeavesBothRadiosSending
bothRadiosComeBackAfterABluetoothPowerCycle     // no action taken
aMeshCoreScanDoesNotDisconnectEitherRadio
aMeshCoreScanFindsOnlyMeshCoreRadios            // the Meshtastic radio's id isn't listed
aSlowBLEStopDoesNotEndTheMeshCorePickersScan
theBLEScanRestartsAfterTheMeshCorePickerCloses  // peer discovered within 3 s
```

- [ ] **Step 2: Run.** `--filter MeshCoreCoexistenceTests`, log `t4-first.log`. This probes code already written, so a first-run pass is possible, and Step 3 is what proves the tests. A disconnect-filtering or scan failure is an FCB or kit defect: stop and report. No `withKnownIssue`.
- [ ] **Step 3: Mutation batches,** in `MeshCoreDriver+Live.swift` and `MeshCoreLive.swift` only:

| # | Mutation | Must fail |
|---|---|---|
| G1 | `send` always false | `aMeshtasticLinkDropLeavesMeshCoreConnected`, `stoppingMeshtasticLeavesMeshCoreSending`, `stoppingBLELeavesBothRadiosSending`, `aMeshCoreScanDoesNotDisconnectEitherRadio` |
| G2 | pump finishes at the first `.reconnecting` | `bothRadiosComeBackAfterABluetoothPowerCycle` |
| G3 | `start` never connects | `bothRadiosConnectBesideABLEPeer`, `aMeshCoreLinkDropLeavesMeshtasticConnected`, `aBLEPeerDropLeavesBothRadiosConnected`, `stoppingMeshCoreLeavesMeshtasticSending` |
| G4 | `scanRadios(central:)` finishes at once | `aMeshCoreScanFindsOnlyMeshCoreRadios`, `aSlowBLEStopDoesNotEndTheMeshCorePickersScan` |

Batch 2 (restore first), because G4 finishes the scan: G5, `onTermination` does nothing, so the scan stays alive. `theBLEScanRestartsAfterTheMeshCorePickerCloses` must fail.

- [ ] **Step 4: Restore, re-run, all pass. Step 5: Commit** the test file. Subject: `test: BLE and two radios coexist on one FCB central`.

---

### Task 5: Part 1 hand-off

- [ ] **Step 1: Full suite.** No filter, log `t5-full.log`. Passes; count = baseline + Part 1. Existing Meshtastic suites unedited.
- [ ] **Step 2: Rebase check.** `git -C /Users/ell/development/ios/pods/ReTiCA log --oneline -5 main`. If it moved: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshcore-live rebase main`, rerun Step 1.
- [ ] **Step 3: Stop and report** commits and counts, and that merging makes `pods/MeshCoreKit` a required sibling for everything resolving `pods/ReTiCA`. **Do not merge or push.**

---

# Part 2: ReTiCAMsgr (`A`), after Part 1 and lane C are merged

### Task 6: Branch, dependencies, secret wrapper, live wiring

**Interfaces:**
- Consumes: Part 1; lane C's `MeshCoreKeyStore`, `MeshCoreSecrets`, `RadioScanner.scanMeshCore`, `Environment.meshCoreKeyStore`.
- Produces:
  - `extension MeshCoreDriver { static func resolvingSecrets(base: MeshCoreDriver, keyStore: MeshCoreKeyStore) -> MeshCoreDriver }`
  - `DependencyValues.meshCoreRadioDetails: @Sendable () -> MeshCoreRadioDetails?`, testValue `{ nil }`
  - `extension RadioScanner { static func meshCoreResults(_ radios: @escaping @Sendable () -> AsyncStream<DiscoveredMeshCoreRadio>) -> @Sendable () -> AsyncStream<RadioScanResult> }`
  - `public enum MeshCoreLiveWiring { static func installDriver(into: inout DependencyValues, keyStore: MeshCoreKeyStore); static func installDetails(into:); static func installScanner(into:) }`. Lazy private statics: one session from `MeshCoreLive.makeSession(appName: "ReTiCAMsgr")` (a radio-side label, not UI copy), one `.live`, details in a `LockIsolated`.
  - Test support: `MeshCoreRadioHarness` with `calls: [McRadioCall]` (`enum McRadioCall { case start(UUID, canRoute: Bool, secretBytes: Int), stop, removeChannel }`), `holdStops`, `holdRemovals`, `removalResult`, `yieldToLatest`, `waitForCalls`, `waitForStarts`, `sent`; `mcRadioStore(radio:enabled:radioHarness:meshtastic:tcp:configure:)`, built like `meshRadioStore` (`MeshtasticRadioTestSupport.swift:102`), with an in-memory key store holding a key, `$0.meshCoreDriver = radioHarness.driver`, and, following its `:135-136`, `$0.meshCoreClock = ImmediateClock()` and `$0.meshCoreDate = DateGenerator { Date(timeIntervalSince1970: 1_700_000_000) }`; `mcBringRadioOnline`, `mcNoOverlappingStarts`, `mcRadioIDA/B`, `mcSlotIDA/B`.

`resolvingSecrets.start(config)`: `guard let secrets = keyStore.secrets()`, else a stream that yields `.unavailable(.other("The channel key can't be read"))` and finishes (non-terminal, so a foreground retries). Copy the config with `channelSecret = secrets.current`, `retiredChannelSecrets = secrets.retired`, and forward. On `.retiredChannelsCleared`, call `keyStore.forgetRetired(secrets.retired)` before forwarding. `send`, `removeChannel`, `stop` forward. `MeshtasticLiveWiring.installScanner` becomes `values.radioScanner.scan = RadioScanner.meshtastic { MeshtasticLive.scanRadios() }.scan`, so install order can't matter.

- [ ] **Step 1: Gate.** Stop and report if either is missing: `ls /Users/ell/development/ios/pods/ReTiCA/Sources/ReTiCAMeshCoreLive`; `grep -c "scanMeshCore" /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/RadioScanner.swift` (lane C merged).
- [ ] **Step 2: Branch and baseline.** `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshcore switch -c feat/meshcore-wiring main`. If lane C's worktree has been removed, use this instead: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr worktree add /Users/ell/development/ios/apps/ReTiCAMsgr-meshcore -b feat/meshcore-wiring main`. App test command, no filter, log `t6-baseline.log`. Record N.
- [ ] **Step 3: Dependencies.** In `CORE/Package.swift` after `:17`: `.package(path: "../../../pods/MeshCoreKit")`, commented as the same checkout ReTiCA's `../MeshCoreKit` resolves to. Add `ReTiCAMeshCoreLive` and `MeshCoreKit` products to the target, `MeshCoreKit` to the tests. `swift package --package-path /Users/ell/development/ios/apps/ReTiCAMsgr-meshcore/ReTiCAMsgrCore resolve > /tmp/ReTiCaMsgr/lane-d/t6-resolve.log 2>&1`.
- [ ] **Step 4: Write the failing tests.**

```swift
mcSecretsStartFillsTheKeyAndRetiredList    // base config: channelSecret == A, retired == [B]
mcSecretsKeepsTheOtherConfigFields         // radio, canRoute, channelName, dataType
mcSecretsMissingKeyIsReportedNotStarted    // exact text; base starts == 0; stream finishes
mcSecretsForgetsWhenTheDriverReportsCleared
mcSecretsForgetOnlyWhatThatStartCarried    // start retired [K1]; store gains K2; cleared: retired == [K2]
mcSecretsForwardsTheClearedEvent
mcSecretsKeepsRetiredWithoutTheEvent
mcSecretsForwardsSendRemoveAndStop
mcLiveScanMapsEachRadio                    // id, name, rssi
mcLiveScanFinishesWhenTheSourceFinishes
mcLiveScanCancellingEndsTheSource
mcLiveScanInstallsDoNotOverwriteEachOther  // both orders; give each installScanner an internal overload taking its source, so no CoreBluetooth starts
```

- [ ] **Step 5: Run to see them fail,** `--filter mcSecrets --filter mcLiveScan`, log `t6-red.log`.
- [ ] **Step 6: Implement.** In `AppRuntime.build()` after `:136` add the three installs. They stay outside `#if DEBUG`: they build nothing until a slot starts, and Release can't start one.
- [ ] **Step 7: Green,** adding `--filter meshLiveScan`, log `t6-green.log`.
- [ ] **Step 8: Mutation batches.** Batch 1:

| # | Mutation | Must fail |
|---|---|---|
| H1 | `start` forwards the config unchanged | `mcSecretsStartFillsTheKeyAndRetiredList` |
| H3 | missing key forwards to the base | `mcSecretsMissingKeyIsReportedNotStarted` |
| H4 | cleared event doesn't call `forgetRetired` | `mcSecretsForgetsWhenTheDriverReportsCleared`, `mcSecretsForgetOnlyWhatThatStartCarried` |
| H5 | swallows the cleared event | `mcSecretsForwardsTheClearedEvent` |
| H7 | `stop`, `send`, `removeChannel` become no-ops | `mcSecretsForwardsSendRemoveAndStop` |
| H8 | scanner map drops the name | `mcLiveScanMapsEachRadio` |
| H9 | no `continuation.finish()` | `mcLiveScanFinishesWhenTheSourceFinishes` |
| H10 | no `onTermination` cancel | `mcLiveScanCancellingEndsTheSource` |
| H11 | Meshtastic `installScanner` assigns the whole struct | `mcLiveScanInstallsDoNotOverwriteEachOther` |

Batch 2 (restore first), hidden by H1 and H4:

| # | Mutation | Must fail |
|---|---|---|
| H2 | builds a fresh config from just radio and secret | `mcSecretsKeepsTheOtherConfigFields` |
| H6 | `forgetRetired` also runs at `start` | `mcSecretsKeepsRetiredWithoutTheEvent` |
| H12 | forgets the store's whole retired list | `mcSecretsForgetOnlyWhatThatStartCarried` |

- [ ] **Step 9: Restore, re-run, all pass.**
- [ ] **Step 10: Build.** `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-meshcore/ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -destination "generic/platform=iOS Simulator" build > /tmp/ReTiCaMsgr/lane-d/t6-build.log 2>&1`. Then `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshcore status --short`; restore any rewritten scheme plist.
- [ ] **Step 11: Commit,** with `CORE/Package.resolved` and `A/ReTiCAMsgr.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` if changed. Subject: `feat: live MeshCore wiring that fills the key only at driver start`.

---

### Task 7: The MeshCore slot, swap and removal

**Interfaces:**
- Consumes: T6, Contract 3 plus lane B's `.removeChannel`, `.setCanRoute`, `.channelRemoved`; lane C's `meshCoreWillDial`, `meshCoreRadioUUID`, `meshCoreKeyGeneration`, `meshCoreKeyPresence`, `meshCoreStatus` (including `channelLeftOnRadio`, `channelRemoved`), `meshCoreTurnOffNoticeVisible`.
- Produces:

```swift
public struct MeshCoreSlotIdentity: Equatable, Sendable { public var radio: UUID; public var keyGeneration: Int }
public struct MeshCoreSlotSwap: Equatable, Sendable {
    public var next: MeshCoreSlotIdentity?; public var startNext: Bool; public var removingChannel: Bool
}
// AppFeature.State: meshCoreSwap, meshCoreSlotIdentity, meshCoreRetiredCounters
func syncMeshCoreSlot(_ state: inout AppFeature.State) -> Effect<AppFeature.Action>
func finishMeshCoreSwap(_ state: inout AppFeature.State) -> Effect<AppFeature.Action>
func installMeshCoreSlot(_ state: inout AppFeature.State, _ identity: MeshCoreSlotIdentity?, start: Bool) -> Effect<AppFeature.Action>
struct MeshCoreRadioReducer: Reducer
```

Below, `.meshCore(x)` means `.node(.client(.endpoint(.meshCore(x))))`.

**`syncMeshCoreSlot`,** first match wins. First set `state.meshCoreKeyPresence = keyStore.presence()` through `@Dependency(\.meshCoreKeyStore)`, so a foreground recovers an `.unreadable`. Compute `wanted` from `meshCoreWillDial`.
1. Swap in flight → retarget its `next`, `startNext = true`, leave `removingChannel`; `.none`.
2. `meshCoreSlotIdentity == wanted` → `.none`.
3. No slot, or slot `isIdle` → if `wanted == nil` and a slot exists, set `channelLeftOnRadio = true`, since an idle slot can't reach the radio; then, if `wanted?.radio == meshCoreSlotIdentity?.radio` (an idle slot whose key changed), set `meshCoreSlotIdentity = wanted` and send `.meshCore(.start)` to the slot as it is; otherwise `installMeshCoreSlot(&state, wanted, start: true)`.
4. `wanted == nil`, slot online → swap with `removingChannel: true`, send `.meshCore(.removeChannel)`.
5. `wanted == nil`, slot not online → `channelLeftOnRadio = true`, swap, send `.meshCore(.stop)`.
6. Otherwise → swap, send `.meshCore(.stop)`.

**`.meshCore(.delegate(.channelRemoved(ok)))`:** `channelLeftOnRadio = !ok`, `channelRemoved = ok`; if `meshCoreSwap?.removingChannel == true`, clear the flag and send `.meshCore(.stop)`. Lane B's interface holds any `.stop` until a removal finishes, so a Disconnect meanwhile is safe.

**`finishMeshCoreSwap`** at `.radioOffline`: mirror `finishMeshtasticSwap`: not idle → `.stop` again and wait for the next `.radioOffline`. Idle and `next?.radio == meshCoreSlotIdentity?.radio` (a key change, or turned back on during a removal) → keep the slot: set `meshCoreSlotIdentity = next`, clear the swap, and send `.meshCore(.start)` if `startNext`. The wrapper reads the new key at `driver.start`, and the limiter, packet ID, dedupe keys and `BIND` stamp carry over. Otherwise install. Either way, show `.connecting` if nothing's connected and `startNext && next != nil`.

**`installMeshCoreSlot`** (no slot, a different radio, or `nil`): carry counters into `meshCoreRetiredCounters`; `endpoint.meshCore = identity.map { MeshCoreEndpoint.State(config: MeshCoreDriverConfig(radio: $0.radio, channelSecret: Data(), canRoute: relayEnabled), profile: .meshCore(params: nil)) }`, reading `relayEnabled` into a local first; set `meshCoreSlotIdentity`; reset `meshCoreStatus`, keeping counters, and keeping `channelLeftOnRadio` and `channelRemoved` unless the identity is non-nil; `.start` if wanted.

**`MeshCoreRadioReducer`:** `.binding(\.meshCoreEnabled)` going false, or going true while `meshCoreSwap != nil` → `syncMeshCoreSlot`, whose rule 1 retargets the swap. If that going-true sync runs after a Disconnect (`connection == .disconnected`), it then sets `meshCoreSwap?.startNext = false`, so turning on still doesn't start a radio without a Connect. `.radioOffline` → `finishMeshCoreSwap`. Other delegates in Task 9. **`.setRelayMode`** also sends `.meshCore(.setCanRoute(enabled))` when `endpoint.meshCore != nil`.

- [ ] **Step 1: Write the failing tests** (`MeshCoreRadioSlotTests.swift`):

```swift
mcSlotConnectStartsTheChosenRadio           // calls[0] == .start(A, canRoute: false, secretBytes: 0)
mcSlotConfigInStateHoldsNoKey               // interface.config.channelSecret == Data()
mcSlotConnectWithMeshCoreOffBuildsNoSlot
mcSlotConnectWithoutARadioBuildsNoSlotAndDialsNothing
mcSlotConnectWithoutAKeyBuildsNoSlot        // connection stays .disconnected
mcSlotAKeySetLaterStartsAtTheNextConnect
mcSlotConnectWithOnlyARadioShowsConnecting
mcSlotTurningOffWhileOnlineRemovesTheChannelThenStops // no Connect: calls end [.removeChannel, .stop]; slot nil
mcSlotARemovedChannelIsRecorded             // result true: channelRemoved; !meshCoreTurnOffNoticeVisible
mcSlotARestartClearsTheRemovedRecord        // removed, on, Connect: !channelRemoved; meshCoreTurnOffNoticeVisible
mcSlotTurningOffWhileOnlineStopsOnlyAfterTheRemovalReturns // hold: no .stop; release: .stop
mcSlotFailedRemovalIsRecorded               // result false: channelLeftOnRadio; still .stop, slot nil
mcSlotTurningOffWhileConnectingOnlyStops    // no .removeChannel; channelLeftOnRadio
mcSlotTurningOffWithNoSlotDoesNothing       // radio chosen, no Connect: calls == []; !channelLeftOnRadio; meshCoreTurnOffNoticeVisible, since we can't know
mcSlotTurningOffAfterDisconnectIsRecorded   // online, Disconnect, idle, off: no .removeChannel; channelLeftOnRadio; slot nil
mcSlotTurningOnWithNoSwapWaitsForConnect    // off with no swap, on: calls unchanged until Connect
mcSlotDisconnectDuringRemovalStillFinishes  // hold; disconnect; no .stop yet; release: .removeChannel, .stop; slot nil, no .start
mcSlotBackOnDuringRemovalEndsRunning        // off, on during hold, release: final .start; mcNoOverlappingStarts
mcSlotBackOnAfterDisconnectDuringRemovalStaysStopped // off, Disconnect, on during hold, release: no .start until Connect
mcSlotConnectDuringRemovalNeverOverlaps
mcSlotDisconnectDoesNotRemoveTheChannel
mcSlotChangingTheRadioStopsWithoutRemoving  // [.start(A), .stop, .start(B)]
mcSlotChangingTheRadioWhileConnectingWaitsForItsStop
mcSlotAnIdleOldSlotIsReplacedAtOnce
mcSlotAKeyChangeRestartsAtTheNextConnect    // no stop until Connect; then start, stop, start
mcSlotAKeyChangeDoesNotRemoveTheChannel
mcSlotAKeyChangeKeepsTheSlotState           // limiter stamp + nextPacketID set before; after stop/start they're unchanged
mcSlotAKeyChangeOnAnIdleSlotKeepsItsState   // Disconnect, key change, Connect: same limiter state, calls end [.stop, .start(A)]
mcSlotRetiredKeysAloneDoNotRestart          // forgetRetired while online; Connect: calls unchanged
mcSlotRelayOnSetsCanRoute                   // .start(A, canRoute: true, …)
mcSlotRelayChangeUpdatesTheRunningSlot      // .setRelayMode(true): config.canRoute true
mcSlotRelayChangeDoesNotRestartTheRadio     // no .stop; a Connect later: calls unchanged
mcSlotRelayChangeWithNoSlotSendsNothing     // an action to the missing slot would trip ifLet
mcSlotSwapInstallUsesTheCurrentRelaySetting // relay toggled during a swap: new .start has it
mcSlotConnectDuringASwapNeverStartsTwiceWithoutAStop
mcSlotBothRadiosStartAtConnect
mcSlotSwappingOneRadioLeavesTheOtherRunning // change MeshCore radio: Meshtastic harness calls unchanged
mcSlotChangingMeshtasticLeavesMeshCoreRunning
mcSlotKeyReadFailureIsNotANoKey             // failRead: .unreadable, no slot; foreground after clearFailures: slot
```

- [ ] **Step 2: Run to see them fail,** `--filter mcSlot`, log `t7-red.log`.
- [ ] **Step 3: Implement,** including `sync.radios` at the five sites and `somethingWillDial` gaining `|| meshCoreWillDial`.
- [ ] **Step 4: Green,** adding `--filter meshSlot --filter meshRedial --filter meshSlice`, log `t7-green.log`.
- [ ] **Step 5: Mutation batches** (`--filter mcSlot`). Batch 1:

| # | Mutation | Must fail |
|---|---|---|
| J1 | `installMeshCoreSlot` never sends `.start` | `mcSlotConnectStartsTheChosenRadio`, `mcSlotAKeySetLaterStartsAtTheNextConnect`, `mcSlotBothRadiosStartAtConnect`, `mcSlotKeyReadFailureIsNotANoKey`, `mcSlotSwapInstallUsesTheCurrentRelaySetting` |
| J2 | config gets 16 random bytes | `mcSlotConfigInStateHoldsNoKey` |
| J3 | `wanted` uses `meshCoreEnabled` and a forced radio, not `meshCoreWillDial` | `mcSlotConnectWithMeshCoreOffBuildsNoSlot`, `…WithoutARadio…`, `…WithoutAKey…` |
| J4 | `somethingWillDial` drops MeshCore | `mcSlotConnectWithOnlyARadioShowsConnecting` |
| J5 | no binding arm | `mcSlotTurningOffWhileOnlineRemovesTheChannelThenStops`, `…StopsOnlyAfterTheRemovalReturns`, `mcSlotFailedRemovalIsRecorded`, `mcSlotTurningOffWhileConnectingOnlyStops`, `mcSlotDisconnectDuringRemovalStillFinishes`, `mcSlotBackOnDuringRemovalEndsRunning`, `mcSlotConnectDuringRemovalNeverOverlaps` |
| J7 | rule 2 treats any existing identity as equal | `mcSlotChangingTheRadioStopsWithoutRemoving`, `…WhileConnectingWaitsForItsStop`, `mcSlotAnIdleOldSlotIsReplacedAtOnce`, `mcSlotSwappingOneRadioLeavesTheOtherRunning`, `mcSlotAKeyChangeRestartsAtTheNextConnect` |
| J13 | `.setRelayMode` sends no `.setCanRoute` | `mcSlotRelayChangeUpdatesTheRunningSlot` |
| J14 | rule 1 removed | `mcSlotConnectDuringASwapNeverStartsTwiceWithoutAStop` |
| J15 | `radios` drops the Meshtastic effect | `mcSlotChangingMeshtasticLeavesMeshCoreRunning` |

Batch 2 (restore first), hidden by J1, J5 and J7:

| # | Mutation | Must fail |
|---|---|---|
| J6 | any nil-wanted sync sets `channelLeftOnRadio` first | `mcSlotTurningOffWithNoSlotDoesNothing` |
| J10 | rule 6 also sends `.removeChannel` | `mcSlotAKeyChangeDoesNotRemoveTheChannel` |
| J11 | identity gains the count from `keyStore.secrets()?.retired` | `mcSlotRetiredKeysAloneDoNotRestart` |
| J12 | install hard-codes `canRoute: false` | `mcSlotRelayOnSetsCanRoute`, `mcSlotSwapInstallUsesTheCurrentRelaySetting` |
| J16 | `.setRelayMode` also sends `.stop` | `mcSlotRelayChangeDoesNotRestartTheRadio` |
| J17 | `.setRelayMode` drops its slot check | `mcSlotRelayChangeWithNoSlotSendsNothing` |
| J19 | `.channelRemoved` ignores `ok` | `mcSlotFailedRemovalIsRecorded` |
| J20 | not-online turn-off also sends `.removeChannel` | `mcSlotTurningOffWhileConnectingOnlyStops` |
| J21 | `.channelRemoved` also sends `.start` | `mcSlotConnectDuringRemovalNeverOverlaps`, `mcSlotDisconnectDuringRemovalStillFinishes` |
| J22 | `.disconnectTapped` also sends `.removeChannel` | `mcSlotDisconnectDoesNotRemoveTheChannel` |
| J23 | retargeting during removal keeps `next` nil | `mcSlotBackOnDuringRemovalEndsRunning` |
| J24 | rule 3 doesn't set `channelLeftOnRadio` | `mcSlotTurningOffAfterDisconnectIsRecorded` |
| J25 | `.channelRemoved` doesn't set `channelRemoved` | `mcSlotARemovedChannelIsRecorded` |
| J26 | the binding arm syncs on every change | `mcSlotTurningOnWithNoSwapWaitsForConnect` |
| J29 | `finishMeshCoreSwap` and rule 3 drop the same-radio check and always install | `mcSlotAKeyChangeKeepsTheSlotState`, `mcSlotAKeyChangeOnAnIdleSlotKeepsItsState` |

Batch 3 (restore first), hidden by J23 and J25:

| # | Mutation | Must fail |
|---|---|---|
| J27 | the going-true sync leaves `startNext` as rule 1 set it | `mcSlotBackOnAfterDisconnectDuringRemovalStaysStopped` |
| J28 | install keeps `channelRemoved` for a non-nil identity | `mcSlotARestartClearsTheRemovedRecord` |

- [ ] **Step 6: Restore, re-run, all pass. Step 7: Commit.** Subject: `feat: MeshCore radio slot with channel removal on turn-off`.

---

### Task 8: Re-dial, Disconnect, picker guards

**Interfaces:** Consumes T7, `MeshCoreLiveMessage.isPolicyFailure` (T1). `redialDownNodes` adds `meshCoreRestart` beside `radioRestart`, gated on `meshCoreSwap == nil && endpoint.meshCore != nil && !meshCorePolicyFailed`; the early return at `:3785` runs both. `.disconnectTapped` adds `state.meshCoreSwap?.startNext = false`.

**Policy failures.** `AppFeature.State.meshCorePolicyFailed: Bool`, false and session-only. `MeshCoreRadioReducer` sets it on `.meshCore(.delegate(.adapterUnavailable(.other(text))))` when `isPolicyFailure(text)`. `.connectTapped` clears it after its picker guard, and its existing `.endpoint(.start)` then retries the radio, draining the queue, which Settings' `requiredWarning` covers. `installMeshCoreSlot` clears it for a non-nil identity, since a different radio or key may succeed. Foreground and push wake both go through `redialDownNodes`, so that one gate covers them.

- [ ] **Step 1: Write the failing tests** (`MeshCoreRedialTests.swift`):

```swift
mcRedialForegroundRestartsAStoppedRadio
mcRedialForegroundLeavesAnOnlineRadioAlone
mcRedialRestartsAnUnavailableRadio                 // every TCP node up, .other("radio not found"), not a policy failure: .start
@Test(arguments: [MeshCoreLiveMessage.noFreeSlot, MeshCoreLiveMessage.firmwareTooOld])
mcRedialPolicyFailureIsNotRestartedByForegrounding // .other(text), foreground: no new .start
@Test(arguments: the same two)
mcRedialPolicyFailureIsNotRestartedByAPushWake     // .other(text), push wake: no new .start
@Test(arguments: the same two)
mcRedialConnectRetriesAPolicyFailure               // .other(text), foreground: no .start; Connect: .start; !meshCorePolicyFailed
mcRedialANewRadioIsNotHeldByTheOldFailure          // no free slot on A, choose B, foreground: B starts; !meshCorePolicyFailed
mcRedialPushWakeRestartsAStoppedRadio
mcRedialNeverRestartsTheSlotASwapIsReplacing
mcRedialRestartsEachRadioIndependently             // MeshCore stopped, Meshtastic online, then the reverse
mcRedialIsNotDeferredByThePicker                   // picker open, radio stopped: .start goes out; BLE stays paused
mcRedialConnectUnderAMeshCorePickerIsDropped
mcRedialDisconnectDuringASwapLeavesTheNewRadioStopped
mcRedialDisconnectStopsBothRadios
mcRedialShowsConnectingWhenOnlyMeshCoreWillDial
```

- [ ] **Step 2: Fail,** `--filter mcRedial`, log `t8-red.log`. **Step 3: Implement. Step 4: Green,** adding `--filter meshRedial --filter meshPickerFlow`, log `t8-green.log`.
- [ ] **Step 5: Mutation batches.** Batch 1:

| # | Mutation | Must fail |
|---|---|---|
| R1 | `meshCoreRestart` always `.none` | `mcRedialForegroundRestartsAStoppedRadio`, `mcRedialRestartsAnUnavailableRadio`, `mcRedialPushWakeRestartsAStoppedRadio`, `mcRedialRestartsEachRadioIndependently`, `mcRedialIsNotDeferredByThePicker` |
| R3 | `.disconnectTapped` doesn't clear `startNext` | `mcRedialDisconnectDuringASwapLeavesTheNewRadioStopped` |
| R4 | `.connectTapped` loses its picker guard | `mcRedialConnectUnderAMeshCorePickerIsDropped` |
| R5 | `somethingWillDial` drops MeshCore | `mcRedialShowsConnectingWhenOnlyMeshCoreWillDial` |

Batch 2 (restore first), which R1 hides: R2, the gate drops `meshCoreSwap == nil` (`mcRedialNeverRestartsTheSlotASwapIsReplacing`); R6, sends `.meshCore(.stop)` before `.start` even when online (`mcRedialForegroundLeavesAnOnlineRadioAlone`); R7, `.disconnectTapped` returns `.none` (`mcRedialDisconnectStopsBothRadios`); R8, the gate drops `!meshCorePolicyFailed` (`mcRedialPolicyFailureIsNotRestartedByForegrounding`, `mcRedialPolicyFailureIsNotRestartedByAPushWake`).

Batch 3 (restore first), which R8 hides: R9, `.connectTapped` doesn't clear the flag (`mcRedialConnectRetriesAPolicyFailure`); R10, the flag is set for every `.other` (`mcRedialRestartsAnUnavailableRadio`); R11, install doesn't clear the flag (`mcRedialANewRadioIsNotHeldByTheOldFailure`).

- [ ] **Step 6: Restore, re-run, all pass. Step 7: Commit.** Subject: `feat: re-dial the MeshCore radio and stop it on Disconnect`.

---

### Task 9: Delegates, status, announces, photo gate

**Interfaces:** Consumes Contract 3 delegates, `MeshCoreCounters`, `MeshCoreLinkParams`, `\.meshCoreRadioDetails`. Produces `MeshCoreStatus.Counters.init(_: MeshCoreCounters)`, `MeshCoreStatus.LoRaParams.init(_: MeshCoreLinkParams)`, `static func AppFeature.isLoRaRadio(_ id: InterfaceID) -> Bool` (`meshtastic:` or `meshcore:`), used at `:285` and `:811`.

Arms, as `AppFeature+MeshtasticRadio.swift:94-125`: `.radioOnline(_, params)` → online, params, `radioName`, `firmwareCode`, `channelSlot` from `meshCoreRadioDetails()`, clear offline reason and adapter. `.radioOffline(reason)` → offline, reason, `finishMeshCoreSwap`. `.adapterUnavailable(cause)` → offline, cause. Every `.meshCore` action refreshes counters as retired + live. `.retiredChannelsCleared`: ignored, see Contract issue 2.

- [ ] **Step 1: Write the failing tests** (`MeshCoreStatusTests.swift`):

```swift
mcStatusRadioOnlineFillsTheStatus
mcStatusRadioOnlineReadsTheDetails                 // ("Base", 11, slot 3)
mcStatusRadioOfflineRecordsTheReason
mcStatusAdapterUnavailableIsShown                  // userMessage == "No free channel slot on this radio"
mcStatusRadioOnlineClearsAnAdapterFault
mcStatusCountersFollowTheLiveSlot                  // every Contract 3 counter to its field
mcStatusCountersSurviveARadioChange
mcStatusBothRadiosKeepSeparateStatus
mcAnnounceAFurtherInterfaceUpAnnouncesOnThatInterface // announceDeliveryOnInterface(meshcore id)
mcAnnounceFirstInterfaceRegistersDelivery
mcAnnounceRelayIsReappliedOnMeshCoreUp
mcAnnounceRadioDownTargetsEveryTCPInterfaceAndNothingElse // departing meshcore; connected tcp, tcpserver, ble, meshtastic
mcAnnounceRadioDownIsThrottled
mcAnnounceARadioGoingDownAnnouncesOverTCP
mcPhotoDoesNotRideOnlyAMeshCoreRadio
mcPhotoDoesNotRideTwoRadios
mcPhotoRidesWithTCPUp
```

- [ ] **Step 2: Fail,** `--filter mcStatus --filter mcAnnounce --filter mcPhoto`, log `t9-red.log`. **Step 3: Implement. Step 4: Green,** adding `--filter meshStatus --filter meshAnnounce`, log `t9-green.log`.
- [ ] **Step 5: Mutation batches.** Batch 1:

| # | Mutation | Must fail |
|---|---|---|
| Q1 | `.radioOnline` arm does nothing | `mcStatusRadioOnlineFillsTheStatus`, `mcStatusRadioOnlineReadsTheDetails`, `mcStatusRadioOnlineClearsAnAdapterFault` |
| Q2 | `.radioOffline` drops `reason` | `mcStatusRadioOfflineRecordsTheReason` |
| Q3 | `.adapterUnavailable` arm does nothing | `mcStatusAdapterUnavailableIsShown` |
| Q4 | `Counters.init` swaps `announcesLimited` and `pathRequestsLimited` | `mcStatusCountersFollowTheLiveSlot` |
| Q5 | install doesn't add to retired | `mcStatusCountersSurviveARadioChange` |
| Q6 | MeshCore arm also sets `meshtasticStatus.online` | `mcStatusBothRadiosKeepSeparateStatus` |
| Q7 | `isLoRaRadio` matches only `meshtastic:` | `mcAnnounceRadioDownTargetsEveryTCPInterfaceAndNothingElse`, `mcAnnounceRadioDownIsThrottled` (it first asserts a non-empty list), `mcAnnounceARadioGoingDownAnnouncesOverTCP`, `mcPhotoDoesNotRideOnlyAMeshCoreRadio`, `mcPhotoDoesNotRideTwoRadios` |

Batch 2 (restore first), on generic code: Q8, `profilePhotoMayRide` always false (`mcPhotoRidesWithTCPUp`); Q9, `:1233-1235` always `.registerDelivery` (`mcAnnounceAFurtherInterfaceUpAnnouncesOnThatInterface`); Q10, remove `if state.relayEnabled` at `:1285-1288` (`mcAnnounceRelayIsReappliedOnMeshCoreUp`). Batch 3, Q9's line again: Q11, `alreadyRegistered` forced true (`mcAnnounceFirstInterfaceRegistersDelivery`).

- [ ] **Step 6: Restore, re-run, all pass. Step 7: Commit.** Subject: `feat: MeshCore status, announces and the slow-radio photo rule`.

---

### Task 10: Whole slice and the Release gate

**Interfaces:** Consumes everything above. Real `LXMFServiceNode` → `LXMFNode` → `TransportEndpoint`, harness drivers. Parse on-air bytes with lane B's `ScotMeshRawCodec`.

- [ ] **Step 1: Write the tests** (`MeshCoreWholeSliceTests.swift`):

```swift
mcSliceARadioComingUpAnnouncesOnTheRadioOnly       // TCP up first; TCP sends unchanged
mcSliceEachRadioAnnouncesOnlyOnItself              // both up after TCP
mcSliceAPacketFromTheRadioRegistersItsPath         // a peer announce's fragments: learned entry names the meshcore id
mcSliceConnectionStaysUpWhileEitherRadioIs         // both up, MeshCore drops: .connected; both down: .disconnected
mcSliceARadioChangeDuringConnectEndsOnTheNewRadio  // mcNoOverlappingStarts
mcSliceTurnOffEndToEndLeavesNoInterface            // interfaces and connectedInterfaces lack the id
mcGateStaleDefaultsStartNoSlot                     // meshCoreAvailable false, enabled + radio + key: onLaunch, Connect, foreground: slot nil, calls == []
mcGateStaleDefaultsDoNotShowConnecting             // nothing else on: .disconnected
mcGateStaleDefaultsNeverTouchTheDriver             // \.meshCoreDriver left unimplemented: no issue
```

- [ ] **Step 2: Run,** `--filter mcSlice --filter mcGate`, log `t10-first.log`. Tasks 7–9 already built most of this, so a first-run pass is possible; Step 3 proves them. A production fix needs a test in the owning task's file.
- [ ] **Step 3: Mutation batch.**

| # | Mutation | Must fail |
|---|---|---|
| W1 | interface-up always `.registerDelivery` | `mcSliceARadioComingUpAnnouncesOnTheRadioOnly`, `mcSliceEachRadioAnnouncesOnlyOnItself` |
| W2 | `installMeshCoreSlot` never sends `.start` | `mcSliceARadioChangeDuringConnectEndsOnTheNewRadio`, `mcSliceAPacketFromTheRadioRegistersItsPath` |
| W3 | `finishMeshCoreSwap` never drops the slot | `mcSliceTurnOffEndToEndLeavesNoInterface` |
| W4 | `meshCoreWillDial` drops `meshCoreAvailable` | all three `mcGate…` |
| W5 | `interfaceDisconnected` always `.disconnected` | `mcSliceConnectionStaysUpWhileEitherRadioIs` |

- [ ] **Step 4: Restore, re-run, all pass. Step 5: Commit.** Subject: `test: MeshCore whole-slice probe and the Release gate`.

---

### Task 11: Part 2 hand-off

- [ ] **Step 1: Full suite.** No filter, log `t11-full.log`. Passes. `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshcore diff main --stat`: no existing `Meshtastic*`, `RadioPicker*` or `DiagnosticsSnapshot*` test file edited.
- [ ] **Step 2: Debug and Mac builds.** `xcodebuild -project /Users/ell/development/ios/apps/ReTiCAMsgr-meshcore/ReTiCAMsgr.xcodeproj -scheme ReTiCAMsgr -configuration Debug -destination "generic/platform=iOS Simulator" -derivedDataPath /tmp/ReTiCaMsgr/lane-d/dd build > /tmp/ReTiCaMsgr/lane-d/t11-debug.log 2>&1`. The same with `-destination "platform=macOS"`, log `t11-mac.log`.
- [ ] **Step 3: Release build.** Step 2's iOS command with `-configuration Release`, log `t11-release.log`. `** BUILD SUCCEEDED **`.
- [ ] **Step 4: No section or key sheets in Release.** Expect `0` for each:
  - `grep -c "Connect through a MeshCore radio" /tmp/ReTiCaMsgr/lane-d/dd/Build/Products/Release-iphonesimulator/ReTiCAMsgr.app/ReTiCAMsgr`
  - `grep -c "Paste Channel Key" /tmp/ReTiCaMsgr/lane-d/dd/Build/Products/Release-iphonesimulator/ReTiCAMsgr.app/ReTiCAMsgr`
  - `grep -c "Anyone with this key can read and send on this tunnel" /tmp/ReTiCaMsgr/lane-d/dd/Build/Products/Release-iphonesimulator/ReTiCAMsgr.app/ReTiCAMsgr`

  Control, Debug build, expect at least 1 for each:
  - `grep -c "Connect through a MeshCore radio" /tmp/ReTiCaMsgr/lane-d/dd/Build/Products/Debug-iphonesimulator/ReTiCAMsgr.app/ReTiCAMsgr.debug.dylib`
  - `grep -c "Paste Channel Key" /tmp/ReTiCaMsgr/lane-d/dd/Build/Products/Debug-iphonesimulator/ReTiCAMsgr.app/ReTiCAMsgr.debug.dylib`
  - `grep -c "Anyone with this key can read and send on this tunnel" /tmp/ReTiCaMsgr/lane-d/dd/Build/Products/Debug-iphonesimulator/ReTiCAMsgr.app/ReTiCAMsgr.debug.dylib`
- [ ] **Step 5: The Meshtastic warning landed.** `grep -c "may not reach the Meshtastic app" /Users/ell/development/ios/apps/ReTiCAMsgr-meshcore/ReTiCAMsgr/SettingsView.swift`, expect at least 1. `0` means the merge order's prerequisite hasn't merged: stop and report.
- [ ] **Step 6: Simulator smoke.** Load `xcodebuildmcp-cli`. Run Debug.
  - [ ] Generate a key, toggle on. Diagnostics: `MeshCore`, `channel key set`, `no radio chosen — choose one in Settings`. Its text has no key.
  - [ ] Both radio types' `Choose radio…` open and cancel; empty lists are expected.
  - [ ] Toggle off. No crash.
  If it crashes, stop and report. No simulator-only code.
- [ ] **Step 7: Rebase check.** `git -C /Users/ell/development/ios/apps/ReTiCAMsgr log --oneline -5 main`. If it moved: `git -C /Users/ell/development/ios/apps/ReTiCAMsgr-meshcore rebase main`, rerun Steps 1–3.
- [ ] **Step 8: Stop and report** commits, counts and smoke results, and that everything below `MeshCoreSession` is still unverified on hardware. **Do not merge or push.** Lane E then runs §8's checklist, and its last commit removes lane C's four `#if DEBUG` sites.

---

## Self-review

1. **Spec coverage.** Contract 2 live value → T2. Slot policy 0–3 → T1, T2 (all three outcomes, never clears). Removal: on turn-off → T7, not connected → T7 plus lane C's copy, key changed → T6 and lane C's store, clearing shape → T2. Firmware → T1, T2. §3 sole importer → T1. Both radios → T4, T7, T8, T10. Diagnostics fill → T9. Symlink → T1. Merges → Merge order, T5, T11. §7 → T7 via `meshCoreWillDial`, T10, T11. §8 D → T2, T4. Relay → T7. §9 drift → T1.
2. **Step scan.** Signatures, names and assertions. Prose only for flows tests don't determine.
3. **Type consistency.** `MeshCoreRadioDetails` T2 → T6, T9. `MeshCoreSlotIdentity`, `MeshCoreSlotSwap` T7 → T8, T9. `sync.radios` T7 → T8. Names checked against lane C's plan (`MeshCoreKeyStore.secrets`, `forgetRetired`, `presence`, `meshCoreKeyGeneration`, `meshCoreAvailable`, `meshCoreWillDial`, `channelLeftOnRadio`, `channelRemoved`, `meshCoreTurnOffNoticeVisible`, `scanMeshCore`) and lane B's (`.removeChannel`, `.setCanRoute`, `.channelRemoved`, `isIdle`, `State(config:profile:)`) and lane A's (`MockMeshCoreDevice` members, `MeshCoreSession.firmwareTooOldReason`, `DiscoveredMeshCoreRadio`).
4. **Review Focus.** All five have named tests.
5. **Proportion.** Signatures, assertions and mutation tables; no function bodies.
