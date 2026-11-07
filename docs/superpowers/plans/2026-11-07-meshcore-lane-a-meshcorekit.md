# MeshCore Lane A: MeshCoreKit and Meshtastified Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Meshtastified's MeshCore BLE stack into a new `pods/MeshCoreKit` package that exposes exactly Contract 1, fix `SELF_INFO` and the other frames that disagree with firmware, and put Meshtastified on the kit with its existing MeshCore tests still passing through an adapter.

**Architecture:** `MeshCoreKit` is transport only: `MeshCoreSession` (actor ported from `MeshtasticSession`: epoch guard, one-command-at-a-time slot, powered-on gate, reconnect), `MeshCoreScanner`, `MeshCoreGATT`, `MeshCoreFrame`, `MeshCoreCommand`. `MeshCoreMock` is a CoreBluetoothMock radio rebuilt from firmware source and cross-checked with `meshcore_py`'s parser. Meshtastified's `MeshCoreSessionActor` becomes a thin adapter over `session.request` and `.frame`, and keeps contacts, DMs, `name: body` parsing, public-channel filtering and the 133-character limit. `SharedScanner` keeps its one combined scan.

**Tech Stack:** Swift 6.3 tools / Swift 6 language mode, FCB (`FCBComposable.BluetoothCentralClient`), CoreBluetoothMock, swift-composable-architecture (test-only in the kit: `TestClock`, `LockIsolated`), Swift Testing, Python 3 with `-I` for the dev-time parser cross-check.

**Spec:** `/Users/ell/development/ios/pods/ReTiCA-worktrees/meshcore-interface/docs/superpowers/specs/2026-11-07-meshcore-interface-design.md`, Contract 1, §6 lane A, §8 A. Read `/Users/ell/development/ios/pods/ReTiCA/docs/superpowers/plans/2026-10-16-meshtastic-lane-a-meshtastickit.md` only where a task points at it.

**Precedent mapping:** Meshtastic lane A tasks 1–11 map to tasks 1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 here. Tasks 2 and 3 are new: they fix frames that the Meshtastic work had no equivalent of.

## Contract issues

No contract is unworkable, and nothing below diverges from one. Each item records where the contract text needed interpreting, or where reading firmware turned up something the spec does not know. The spec owner should amend the text or overrule the plan.

1. **The contract's handshake drains before contacts exist.** Old order was contacts, channels, then drain. In Contract 1 the session drains queued messages before `.configured`, and the adapter can only fetch contacts after it. Unbuffered, every DM queued on the radio would be dropped as "unknown sender" and every queued channel text as "not the public slot", which breaks `offlineQueueDrainsOnConnect`. Workable: the adapter holds message frames until its fetch ends, and holds `.connectionState(.connected)` until then too (tasks 11, 12).
2. **`.firmwareTooOld` has no channel at connect.** `connect(radio:)` returns `Void` and states carry `reason: String?`, while `MeshCoreSessionError` is only thrown by calls. The plan uses a fixed reason, the public constant `MeshCoreSession.firmwareTooOldReason` (task 5). Meshtastified's adapter maps it back to `MeshCoreError.firmwareTooOld(_:)`, and lane D's event mapper consumes the same constant.
3. **`request(timeout:)` is unspecified for bursts and errors.** The plan treats `timeout` as silence since the last collected frame, which matches the old 5 s per contact frame, and a fixed total would fail on long contact lists. `01` is not special: callers list `0x01` in `until` and inspect it. Only the typed methods turn it into `.radioError`.
4. **Name filter.** Contract 1 says names starting `"MeshCore"`; the moved constant is `"MeshCore-"`. The plan sets `MeshCoreGATT.namePrefix = "MeshCore"`, one constant for the scanner and `SharedScanner`. Firmware's only value is `"MeshCore-"` (`MyMesh.h:65-66`, no variant overrides it), so no real radio's result changes.
5. **Public API beyond the contract's listing.** `MeshCoreFrame` and `MeshCoreContact` are public because `.frame` exposes them, `MeshCoreCommand` because `request` callers need the bytes. `MeshCoreFrameError.decodeFailed` is new: the moved `MeshCoreError` is app policy and stays in the app. `.selfInfo` gains LoRa fields and `.error` gains its code, as Contract 1's `MeshCoreRadioInfo` and `.radioError(code:)` require. `MeshCoreSession.firmwareTooOldReason` is public because Meshtastified and lane D match on it.

**Two moved-code bugs, fixed here.** Spec §2 lists both as approved exceptions to §6's "current behaviour". Neither has ever been seen working on a radio.

- **A. Every DM is corrupted on a real radio.** `MeshCoreCommand.sendDirectText` writes the 32-byte key. Firmware reads a **6-byte** prefix at byte 7 and takes text from byte 13 (`MyMesh.cpp:1139-1143`), so the recipient receives the key's last 26 bytes in front of the message. `meshcore_py`'s `send_msg` agrees with firmware. The error comes from the reference, line 187 ("full key required"). Fixed in task 3.
- **B. Every public-channel message carries the sender's name twice.** The session sends `"Name: text"`, and firmware prepends `"%s: "` with the node name itself (`BaseChatMesh.cpp:523`). Fixed in task 12, keeping the 133-character check on the combined length.

Each fix is covered by one new test. Fix A forces the one encoder assertion change named below.

## Global Constraints

- Platforms **iOS 17, macOS 13, macCatalyst 17** for `pods/MeshCoreKit`. `NSLock.withLock` is macOS 14+ and must not appear. MeshtastifiedKit stays `.iOS(.v17), .macOS(.v14)`.
- Dependencies: FCB (`.package(path: "../FCB")`), CoreBluetoothMock (mock target only). TCA is test-target only. No dependency on ReTiCA, MeshModels, MeshtasticKit, or `import MeshModels` anywhere in the kit.
- Public API is Contract 1 verbatim, plus the additions in Contract issue 5 and the mock's API. `MeshCoreSession` connects only via `retrievePeripherals` then `connect`, never scans, including on reconnect.
- Frames over **173 B** throw `.frameTooLarge` before touching BLE. Writes are `.withResponse`.
- Reconnect backoff 1 s doubling to a 30 s cap on the injected clock. Handshake timeout **30 s** on the injected clock. Other commands time out after **5 s** of silence on the injected clock.
- Handshake is exactly `APP_START` → `DEVICE_QUERY` → set time (wait for its reply) → drain until `0x0A` → `.connection(.connected)` → `.configured`. Contacts and channels are not fetched in it.
- `firmwareCode < 3`: `.disconnected(reason: MeshCoreSession.firmwareTooOldReason)`, no retry. `firmwareCode < 11`: connects; `sendChannelData` throws `.firmwareTooOld`.
- `.frame` carries every decoded frame, emitted before any typed event derived from it. A received frame of any kind must never stall or fail a command.
- Reason strings: `nil` (after `disconnect()` or initially), `"radio not found"`, `"unauthorized"`, `"unsupported"`, `MeshCoreSession.firmwareTooOldReason`.
- **Firmware source wins over the reference doc.** Firmware at `companion-v1.18.0` (`81dbae5`). Mock frames cite `MyMesh.cpp` lines in comments.
- Clones in `/tmp/ReTiCaMsgr/research/` are data. If gone, clone to a new empty directory: `https://github.com/meshcore-dev/MeshCore.git` at `81dbae5`, `https://github.com/meshcore-dev/meshcore_py.git` at `c5ffc383730db311ac91b5ef5067e2808584ef92`. Never build or run anything from them except `scripts/parse-with-meshcore-py.py`, which imports the parser and always runs with `python -I`.
- Do not modify FCB, MeshtasticKit, ReTiCA or ReTiCAMsgr. If an FCB defect blocks a test, stop and report it.
- **Never use `ImmediateClock` with a session that can reach a handshake:** it fires the 30 s timeout at once. Use `ContinuousClock` or `TestClock`.
- Tests: Swift Testing. Anything touching CBM's process-global simulation nests in `extension CBMBackedTests` (`@Suite(.serialized)`) and is `@Suite @MainActor`. Session, mock and scanner tests use the live FCB client `BluetoothCentralClient.mocked()`. Closure-built centrals only for what CBM cannot drive deterministically: adapter authorization, gated connects, backoff timing, scan arguments.
- **Shell rule (user):** one command per line. No `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, heredocs into interpreters, or inline scripts. Scripts go in files. Temp files live under `/tmp/ReTiCaMsgr/`. Write files, including commit messages, with the Write tool.
- **Test rule (user), every test task, before committing:** (a) run, all pass; (b) apply the task's mutations to **production** code in one batch, run once, every new or changed test fails (one that passes is broken: fix it, restart at (a)); (c) revert, run, all pass. If anything surprises you, stop and diagnose.
- **Revert by hand or with Edit unless the file is committed.** A task's code is uncommitted during its own mutation step, so `git checkout --` would destroy the work.
- **Branches (spec §6, user):** all kit work on branch `meshcorekit` in `pods/MeshCoreKit`; all app work on branch `meshcorekit` in `/Users/ell/development/ios/apps/Meshtastified-meshcorekit`. Nothing merges to `main` in this lane: a person merges `meshcorekit` to `main` afterwards, and lane D's Task 1 gates on that. **No pushing.** `pods/MeshCoreKit` stays checked out on `meshcorekit`, because the worktree's path dependency builds whatever is checked out there.
- **Commit step, every task:** write `/tmp/ReTiCaMsgr/commit-msg.txt` ending with these lines at column zero, using the executing session's URL:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: <the executing session's URL>
  ```
  Stage explicit paths only (never `git add -A`; `.build/`, `.swiftpm/`, `xcshareddata/` may be untracked). Then run `git -C <repo> commit -F /tmp/ReTiCaMsgr/commit-msg.txt`.

**Lessons carried from Meshtastic lane A:**

| Lesson | Rule here | Test |
|---|---|---|
| FCB holds one write continuation per characteristic and a second overwrites it (`BluetoothCentralClient+Live.swift:322-334`) | All writes go through one FIFO command slot, including set time and sync | task 7 `concurrentSendsAllComplete` |
| Commands before `.poweredOn` are dropped and `retrievePeripherals` returns `[]` | Powered-on gate before retrieve | task 5 `connectWhilePoweredOffWaitsThenConnects` |
| iOS and CBM report a power cycle as a state change only, with no `didDisconnect` | Disconnect watch treats non-`.poweredOn` as link loss | task 8 `powerCycleWhileConnectedReconnectsAndReportsAdapter` |
| FCB continuations ignore cancellation, and FCB events are global | Epoch check after every await; filter on own peripheral | task 8 `attemptResolvingAfterDisconnectStaysDisconnected`, `anotherPeripheralsDisconnectIsIgnored` |
| An FCB op may never resume after power-off | Attempt and in-flight command outcomes are session-owned, stale results ignored by sequence number | task 8 `commandInFlightAtLinkLossThrowsNotConnected` |
| Actor-hop subscription loses a connect's first events | `EventHub` registers synchronously and replays connection state | task 5 `eventsReplayDisconnectedBeforeAnyConnect` |

## Review Focus

1. **A reply notification arrives before FCB's write call returns.** Normal on BLE. If the command ends on the reply alone, the next command's write overwrites FCB's pending continuation and the first write hangs. Expected: the slot is held until both the reply and the write have finished. → task 7 `replyBeforeWriteCompletionHoldsTheSlotUntilTheWriteReturns`.
2. **The radio's clock is ahead of the phone's.** Set time answers `ERR 6`. Expected: connects normally. → task 5 `radioClockAheadStillConfigures`.
3. **A truncated message frame comes back from a sync.** It cannot decode, so a match on decoded frames would stall 5 s and lose the rest of the queue. Expected: the drain counts it as answered and continues. → task 6 `malformedMessageFrameDuringDrainDoesNotStall`.
4. **Messages waiting on the radio at connect, then a reconnect.** Expected: delivered with the right sender after the contact fetch, every time, not dropped for arriving first. → task 11 `messagesBeforeFetchFinishAreHeldThenDeliveredInOrder`, `beginLinkHoldsAgainButKeepsContacts`; task 12 `queuedChannelTextIsNotDroppedBeforeSlotsLoad`.
5. **A push lands in the middle of a contact burst.** Today's gate releases between contact frames, so a drain can consume or lose them. Expected: every contact arrives, then the drain runs. → task 7 `msgWaitingDuringContactBurstLosesNothing`.

## Assertion changes to existing tests (complete list)

The 21 tests that stay in Meshtastified (`MeshCoreSessionTests` 6, `MeshCoreSendTests` 10, `MeshCoreReconnectTests` 1, `MeshCoreRouterTests` 4) get **clock setup edits only, no assertion changes, and no exceptions**. If one fails, fix the adapter.

Of the 35 tests that leave the app, 34 move to the kit and `mtuAccommodatesDirectFrameOverTwentyBytes` is retired (task 4 says why; task 7 replaces it with a test that can fail). Among the moved tests, these change, and only these:

| Test | Change | Why | Task |
|---|---|---|---|
| `emptyFrameThrowsDecodeFailed`, `truncatedSelfInfoThrows`, `truncatedContactThrows`, `truncatedDeviceInfoV3Throws` | `MeshCoreError.decodeFailed` → `MeshCoreFrameError.decodeFailed` | Error type move | 1 |
| `decodesSelfInfoKeyAndName` | Replaced by the real layout | The bug | 2 |
| `decodesSingleByteFrames` | `.error` → `.error(code: nil)` | `ERR` carries a code | 3 |
| `sendDirectTextEncodesFullFrame` | Expected bytes use a 6-byte prefix, count 15 | Bug A | 3 |
| `appStartYieldsSelfInfo` | Expects the new `.selfInfo` fields | Same bug | 4 |

## Source map (verified 2026-11-07)

- `apps/Meshtastified/MeshtastifiedKit/Sources/MeshDeviceClient/MeshCore/MeshCoreSessionActor.swift`: `:172-219` init sequence, `:189` set time bypasses the gate, `:221-235` contact drain releases the gate per frame, `:247-258` `syncDrain` waits only for `0x0A`, `0x10`, `0x11`, `:106-125` `scanStream` has no callers, `:479-516` `sendText`.
- `…/MeshCore/MeshCoreFrame.swift:88-92` the `SELF_INFO` bug. `…/Mock/MockMeshCoreDevice.swift:83` the mock shares it.
- `…/MeshDeviceClient+Live.swift:82-145` `SharedScanner`, `:112` and `:134` use `MeshCoreGATT`. `…/Exports.swift:4` the re-export pattern.
- `Meshtastified/MeshtastifiedApp.swift:96-140` reaches `MockMeshCoreDevice`, `.aliceKey`, `injectChannelText`, `enqueueDirectMessage`, `injectMsgWaiting` through `import MeshDeviceClient`. Keep those names.
- `pods/MeshtasticKit/Sources/MeshtasticKit/MeshtasticSession.swift`: the structure to port. `:190-236` `runAttempt`/abort, `:241-265` attempt power watch, `:340-363` powered-on gate, `:374-444` session-owned write slot, `:558-585` disconnect watch, `:598-623` backoff, `:631-647` handshake timeout. `EventHub.swift` and `MeshtasticScanner.swift` port almost line for line.
- Firmware `examples/companion_radio/MyMesh.cpp`: DEVICE_INFO `:1060-1075`; SELF_INFO `:1085-1117`; DM `:1132-1177`; channel text `:1178-1197`; channel data `:1198-1237`; contacts `:1238-1258`, `:171-192`, `:2392-2409`; set time `:1287-1296`; sync `:1415-1423`; battery `:1517-1527`; get channel `:1752-1766`; set channel `:1767-1780`; unsupported `:2060`; `0x10` `:440-473`; `0x11` `:558-589`; `0x1B` `:601-633`; `0x84` `:832-846`; `0x82` `:426-430`. `MAX_GROUP_DATA_LENGTH` is 165 (`MeshCore.h:20-21`, `:14`). `DATA_TYPE_RESERVED` 0x0000 and `DATA_TYPE_DEV` 0xFFFF (`TxtDataHelpers.h:11-12`). Firmware code is 14 at v1.18.0 and 11 at `companion-v1.15.0`.

## File structure

**New repo `/Users/ell/development/ios/pods/MeshCoreKit`:** `Sources/MeshCoreKit/` holds `MeshCoreGATT.swift`, `MeshCoreFrame.swift` (commands, contact, frame, decode error), `MeshCoreTypes.swift` (tasks 1–3), `EventHub.swift`, `MeshCoreSession.swift` (5–8), `MeshCoreScanner.swift` (9). `Sources/MeshCoreMock/MockMeshCoreDevice.swift` and `scripts/parse-with-meshcore-py.py` (4). `Tests/MeshCoreKitTests/` holds `PublicTypesTests`, `MeshCoreFrameTests` (1–3), `MockRadioTests`, `ParserCrossCheckTests`, `Fixtures/`, `Support/CBMSupport.swift` (4), `Support/SessionSupport.swift`, `SessionConnectTests` (5), `SessionReceiveTests` (6), `SessionCommandTests` (7), `SessionReconnectTests` (8), `ScannerTests` (9).

**Worktree `/Users/ell/development/ios/apps/Meshtastified-meshcorekit` (branch `meshcorekit`), under `MeshtastifiedKit/`:** `Package.swift` (1, 10). Task 10 deletes `Sources/MeshDeviceClient/MeshCore/MeshCoreFrame.swift`, `MeshCoreGATT.swift`, `Mock/MockMeshCoreDevice.swift`, `Tests/MeshDeviceClientTests/MeshCoreFrameTests.swift`, `MeshCoreMockTransportTests.swift`, and edits `Exports.swift`, `MeshCoreError.swift`, `MeshDeviceClient+Live.swift`, `RouterDispatchTests.swift`. Task 11 adds `MeshCore/MeshCoreEventMapper.swift` and its tests. Task 12 rewrites `MeshCore/MeshCoreSessionActor.swift`, adds `MeshCoreAdapterTests.swift`, and makes clock setup edits in four test files.

---

### Task 1: MeshCoreKit repo, Meshtastified worktree, GATT, frames moved as they are, public value types

**Files:**
- Create: `pods/MeshCoreKit/Package.swift`, `.gitignore`, `Sources/MeshCoreKit/MeshCoreGATT.swift`, `MeshCoreFrame.swift`, `MeshCoreTypes.swift`, a placeholder `Sources/MeshCoreMock/MockMeshCoreDevice.swift`
- Test: `Tests/MeshCoreKitTests/PublicTypesTests.swift`, `Tests/MeshCoreKitTests/MeshCoreFrameTests.swift`
- Modify (worktree): `MeshtastifiedKit/Package.swift`
**Interfaces:**
- Consumes: nothing.
- Produces: Contract 1's `MeshCoreRadioInfo`, `MeshCoreChannel`, `MeshCoreConnectionState`, `MeshCoreSessionError`, `MeshCoreEvent`, all `Equatable, Sendable` with public memberwise inits, plus:
  ```swift
  public enum MeshCoreAdapterUnavailable: Equatable, Sendable {
      case poweredOff, unauthorized, unsupported, other(String?)
      public var isTerminal: Bool   // unauthorized, unsupported
  }
  public struct DiscoveredMeshCoreRadio: Equatable, Sendable, Identifiable {
      public var id: UUID; public var name: String?; public var rssi: Int
      public init(id: UUID, name: String?, rssi: Int)
  }
  public enum MeshCoreFrameError: Error, Equatable, Sendable { case decodeFailed }
  public enum MeshCoreGATT { public static let serviceUUID, rxUUID, txUUID: CBUUID
      public static let namePrefix = "MeshCore"; public static let publicChannelSecret: Data }
  ```
  `MeshCoreCommand`, `MeshCoreContact`, `MeshCoreFrame` as in the old file.
- [ ] **Step 1: Create the repo, with work on a branch from the start**
Run: `mkdir -p /Users/ell/development/ios/pods/MeshCoreKit`
Run: `git init -b main /Users/ell/development/ios/pods/MeshCoreKit`
Write `/tmp/ReTiCaMsgr/commit-msg.txt` with subject `chore: empty root commit`, then:
Run: `git -C /Users/ell/development/ios/pods/MeshCoreKit commit --allow-empty -F /tmp/ReTiCaMsgr/commit-msg.txt`
Run: `git -C /Users/ell/development/ios/pods/MeshCoreKit switch -c meshcorekit`
Expected: `Switched to a new branch 'meshcorekit'`. `main` holds only the empty root, so the user can later merge the branch or review it as one diff. This repo has no remote; do not add one.
- [ ] **Step 2: Write `Package.swift` and `.gitignore`**
Copy `pods/MeshtasticKit/Package.swift` with these differences: name `MeshCoreKit`; products `MeshCoreKit`, `MeshCoreMock`; no `MeshProto` target; no swift-protobuf. Targets: `MeshCoreKit` (FCBComposable), `MeshCoreMock` (`MeshCoreKit`, CoreBluetoothMock), `MeshCoreKitTests` (both, FCBComposable, CoreBluetoothMock, ComposableArchitecture). Same platforms and `swiftLanguageModes: [.v6]`. `.gitignore` as in MeshtasticKit: `.build/`, `.swiftpm/`, `Package.resolved`, `.DS_Store`.
- [ ] **Step 3: Move the code**
Copy `MeshCoreGATT.swift` and `MeshCoreFrame.swift` from `apps/Meshtastified/MeshtastifiedKit/Sources/MeshDeviceClient/MeshCore/`. In the frame file, add `MeshCoreFrameError` and throw it for `MeshCoreError.decodeFailed`. Change no decoding logic in this task, including the `SELF_INFO` bug. Set `namePrefix = "MeshCore"` (Contract issue 4). The placeholder mock file holds only `import MeshCoreKit`.

Copy `Tests/MeshDeviceClientTests/MeshCoreFrameTests.swift` to the kit with `@testable import MeshCoreKit` and the `decodeFailed` change from the table.
- [ ] **Step 4: Write `PublicTypesTests`**
```swift
@Test func onlyUnauthorizedAndUnsupportedAreTerminal()   // true for those two; false for .poweredOff, .other(nil)
@Test func meshCoreGATTUUIDsMatchFirmware()   // 6E400001 / 6E400002 / 6E400003-B5A3-F393-E0A9-E50E24DCCA9E; namePrefix == "MeshCore"
@Test func publicChannelSecretMatchesFirmware()   // first byte 0x8b, last 0x72, count 16
@Test func radioInfoInitStoresEveryField()   // all eight fields read back
@Test func channelInitStoresEveryField()     // index, name, secret
@Test func discoveredRadioInitStoresEveryField()   // id, name, rssi
```
- [ ] **Step 5: Run (step a)**
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshCoreKit`
Expected: 34 tests passed (28 moved, 6 new).
- [ ] **Step 6: Mutate in one batch (step b)**
In `MeshCoreTypes.swift` make `isTerminal` always `false` and swap two fields in each of the three inits. In `MeshCoreGATT.swift` swap the RX and TX UUIDs and change the first PSK byte. In `MeshCoreFrame.swift` add at the top of `decode`: `return .unknown(code: 0xEE)`, and change the opcode byte in all 8 `MeshCoreCommand` encoders to `0xEE`.
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshCoreKit`
Expected: all 34 FAIL.
- [ ] **Step 7: Revert and re-run (step c)**
Expected: 34 passed.
- [ ] **Step 8: Commit the kit**
Subject `feat: MeshCoreKit package with frames moved from Meshtastified and Contract 1 types`. Paths: `Package.swift .gitignore Sources Tests`.
- [ ] **Step 9: Create the Meshtastified worktree and record the baseline**
Run: `git -C /Users/ell/development/ios/apps/Meshtastified worktree add /Users/ell/development/ios/apps/Meshtastified-meshcorekit -b meshcorekit`
Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshcorekit/MeshtastifiedKit`
Expected: green. Note the total as **BASELINE**. If it is not green before any change, stop and report.
- [ ] **Step 10: Resolve the kit from the worktree**
`MeshtastifiedKit/Package.swift` uses paths relative to itself, so from `apps/Meshtastified-meshcorekit/MeshtastifiedKit`, `../` is the worktree, `../../` is `apps`, and `../../../pods/MeshCoreKit` is `ios/pods/MeshCoreKit`. That works only because the worktree is a sibling of `apps/Meshtastified`; do not create it anywhere deeper. Both FCB paths land on `ios/pods/FCB`, so SwiftPM sees one FCB.

Add after the MeshtasticKit line: `.package(path: "../../../pods/MeshCoreKit"),`
Run: `swift package --package-path /Users/ell/development/ios/apps/Meshtastified-meshcorekit/MeshtastifiedKit show-dependencies`
Expected: a line naming `/Users/ell/development/ios/pods/MeshCoreKit`, one FCB. A warning that the dependency is unused is expected until task 10.
- [ ] **Step 11: Commit in the worktree**
Subject `chore: resolve pods/MeshCoreKit`. Path: `MeshtastifiedKit/Package.swift`.

### Task 2: Fix `SELF_INFO`

**This bug means Meshtastified's identity is wrong on every real radio.** `MeshCoreFrame.swift:88-92` reads the key from bytes 1–32 and everything after as the name. Firmware has `code adv_type tx max_tx` first, so the "key" is three header bytes plus 29 bytes of the real key, and the "name" starts in the last 3 key bytes and runs into coordinates and LoRa fields. `.myIdentity` therefore reports a key no other node knows, and the session's `selfName` is garbage. The old mock and tests share the assumption, which is why they pass. Lanes B and D also need this: peers address us by the key's first 4 bytes (spec §5.2).

**Files:**
- Modify: `Sources/MeshCoreKit/MeshCoreFrame.swift`
- Test: `Tests/MeshCoreKitTests/MeshCoreFrameTests.swift`
**Interfaces:**
- Consumes: `MeshCoreFrame` (task 1).
- Produces: `case selfInfo(publicKey: Data, name: String, frequencyKHz: UInt32, bandwidthHz: UInt32, spreadingFactor: UInt8, codingRate: UInt8)`.
- [ ] **Step 1: Write the failing test, built from the firmware layout, against the current case shape**
```swift
/// MyMesh.cpp:1085-1116, companion-v1.18.0. Coordinates are non-zero so a wrong offset shows.
static let firmwareSelfInfo: Data = {
    var b: [UInt8] = [0x05, 0x01, 22, 22]           // code, ADV_TYPE_CHAT, tx, max_tx
    b += (0..<32).map { UInt8(0x40 + $0) }          // pub_key at 4
    b += [0xC0, 0xE1, 0x4F, 0x02]                   // lat at 36
    b += [0x80, 0x1A, 0xB8, 0xF8]                   // lon at 40
    b += [1, 0, 0, 0]                               // multi_acks, loc_policy, telemetry, manual_add
    b += [0x38, 0xF6, 0x0D, 0x00]                   // freq_khz 915000 at 48
    b += [0x90, 0xD0, 0x03, 0x00]                   // bw_hz 250000 at 52
    b += [10, 5]                                    // sf at 56, cr at 57
    b += Array("Ell's T-Deck".utf8)                 // name from 58, no terminator
    return Data(b)
}()

@Test func selfInfoReadsTheKeyAtByteFourAndTheNameAtByteFiftyEight() throws {
    guard case .selfInfo(let key, let name) = try MeshCoreFrame.decode(Self.firmwareSelfInfo)
    else { Issue.record("not selfInfo"); return }
    #expect(key == Data((0..<32).map { UInt8(0x40 + $0) }))
    #expect(name == "Ell's T-Deck")
}
```
- [ ] **Step 2: Run to verify it fails, and that it fails for the right reason**
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshCoreKit --filter selfInfoReadsTheKey`
Expected: FAIL. `key` begins `01 16 16 40`, and `name` is not `Ell's T-Deck`. That output is the bug, seen in a test.
- [ ] **Step 3: Fix the decoder in `MeshCoreFrame.swift`**
Require `count >= 58`; key `b[4..<36]`; `frequencyKHz` LE32 at 48; `bandwidthHz` LE32 at 52; `spreadingFactor` `b[56]`; `codingRate` `b[57]`; name `decodeString(b[58...])`. Extend the new test's pattern to the new shape and add its LoRa assertions. Replace `decodesSelfInfoKeyAndName` with the two boundary tests below. `truncatedSelfInfoThrows` stays.

```swift
@Test func selfInfoReadsTheLoRaParameters() // 915_000, 250_000, 10, 5
@Test func selfInfoOfFiftyEightBytesHasAnEmptyName()   // firmwareSelfInfo.prefix(58): name == "", key correct
@Test func selfInfoOfFiftySevenBytesThrows()   // prefix(57) throws MeshCoreFrameError.decodeFailed
```
- [ ] **Step 4: Run (step a)**
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshCoreKit --filter MeshCoreFrameTests`
Expected: all pass.
- [ ] **Step 5: Mutate in one batch (step b)**
In the `0x05` case: key `b[5..<37]`; name from 59; `frequencyKHz` read at 44; the guard to `count >= 57`, with a clamp so 57 bytes yields an empty name.
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshCoreKit --filter "selfInfo"`
Expected: `selfInfoReadsTheKey…`, `selfInfoReadsTheLoRa…`, `selfInfoOfFiftyEight…`, `selfInfoOfFiftySeven…` all FAIL.
- [ ] **Step 6: Revert and re-run (step c)**
Expected: all pass.
- [ ] **Step 7: Commit**
Subject `fix: decode SELF_INFO at the firmware layout; identity and name were wrong on real radios`. Paths: `Sources/MeshCoreKit/MeshCoreFrame.swift Tests/MeshCoreKitTests/MeshCoreFrameTests.swift`.

### Task 3: The other frames: DM prefix, `ERR` code, `0x1B`, `0x84`, channel commands

**Files:**
- Modify: `Sources/MeshCoreKit/MeshCoreFrame.swift`
- Test: `Tests/MeshCoreKitTests/MeshCoreFrameTests.swift`
**Interfaces:**
- Consumes: task 1 frames.
- Produces:
  ```swift
  case error(code: UInt8?)            // replaces .error
  case channelDataRecv(channelIndex: UInt8, dataType: UInt16, payload: Data)
  case rawData(payload: Data)
  extension MeshCoreCommand {
      static func sendChannelData(channelIndex: UInt8, dataType: UInt16, payload: Data) -> Data
      static func setChannel(index: UInt8, name: String, secret: Data) -> Data
  }
  ```
  `sendDirectText(destKey:timestamp:text:)` keeps its signature and writes `destKey.prefix(6)`.
- [ ] **Step 1: Write the failing tests**
```swift
// Changed, per the assertion table:
@Test func sendDirectTextEncodesFullFrame()
//   key 0..<32, ts 0x11223344, "hi" == [02,00,00,44,33,22,11, 00,01,02,03,04,05, 68,69]; count == 15
@Test func decodesSingleByteFrames()   // Data([0x01]) == .error(code: nil); the others unchanged
// New:
@Test func decodesErrorCode()   // [01,03] == .error(code: 3)
@Test func sendChannelDataEncodesAFloodFrame()
//   (channelIndex: 2, dataType: 0x1234, payload: [AA,BB]) == [3E,02,FF,34,12,AA,BB]
@Test func setChannelEncodesFiftyBytes()
//   count == 50; [0]==0x20; [1]==index; name at 2, zero padded to 34; secret at 34..<50
@Test func setChannelKeepsLongNamesToThirtyOneBytesOnACharacterBoundary()
//   name of 30 ASCII + "é" (32 bytes): bytes 2..<33 are the 30 ASCII + 0, valid UTF-8; [33] == 0
@Test func decodesChannelDataRecv()
//   [1B,F0,00,00,03,FF,FF,FF,02,AB,CD] == .channelDataRecv(channelIndex: 3, dataType: 0xFFFF, payload: [AB,CD])
@Test func channelDataRecvWithZeroLengthHasAnEmptyPayload()
@Test func channelDataRecvShorterThanItsHeaderThrows()   // 8 bytes
@Test func channelDataRecvLengthBeyondTheFrameThrows()   // len byte 5, 1 byte of payload
@Test func decodesRawData()   // [84,F0,C4,FF,01,02] == .rawData(payload: [01,02])
@Test func rawDataShorterThanItsHeaderThrows()   // 3 bytes
```
- [ ] **Step 2: Run to verify failure**
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshCoreKit --filter MeshCoreFrameTests`
Expected: compile failure on `.error(code:)` and `.channelDataRecv`.
- [ ] **Step 3: Implement in `MeshCoreFrame.swift`**
`0x1B` per `MyMesh.cpp:610-626`: code, snr, 2 reserved, chan at 4, path at 5, type LE at 6, len at 8, payload `9..<9+len`. `0x84` per `:838-842`: payload from 4. `decodeFixed` and `Data.appendLE` stay private to the file. Leave the reference doc in Meshtastified alone.
- [ ] **Step 4: Run (step a)**
Expected: all `MeshCoreFrameTests` pass.
- [ ] **Step 5: Mutate in one batch (step b)**
DM writes the full `destKey`; `ERR` decodes as `.error(code: nil)` always, and `decodesSingleByteFrames` is broken by decoding `0x0A` as `.ok`; `sendChannelData` opcode `0x3F`; `setChannel` secret offset 33 and no name truncation; `0x1B` payload offset 8 and length guard removed so an over-long frame returns the slice it has; `0x1B` minimum header 7; `0x84` payload offset 3 and minimum 1.
Expected: every test named in Step 1 FAILS.
- [ ] **Step 6: Revert and re-run (step c)**. Expected: all pass.
- [ ] **Step 7: Commit**
Subject `fix: send DMs with the 6-byte prefix firmware reads; decode ERR codes, 0x1B and 0x84`. Same two paths as task 2.

### Task 4: MeshCoreMock rebuilt from firmware, cross-checked with `meshcore_py`

The old mock shared its assumptions with the decoder, so it could not catch decoder bugs. Every builder here cites `MyMesh.cpp` lines in a comment.

**Files:**
- Modify: `Sources/MeshCoreMock/MockMeshCoreDevice.swift`, `Package.swift` (test target `exclude: ["Fixtures"]`)
- Create: `scripts/parse-with-meshcore-py.py`, `Tests/MeshCoreKitTests/Fixtures/mock-frames.json`, `mock-frames-parsed.json`, `Tests/MeshCoreKitTests/Support/CBMSupport.swift`, `MockRadioTests.swift`, `ParserCrossCheckTests.swift`
**Interfaces:**
- Consumes: `MeshCoreCommand`, `MeshCoreFrame`, `MeshCoreGATT`.
- Produces (keeps every name existing tests and the simulator bootstrap use):
  ```swift
  public final class MockMeshCoreDevice: @unchecked Sendable {
      public static let selfKey, aliceKey, unreachableKey: Data     // 0xA0, 0xB0, 0xC0 × 32
      public struct QueuedMessage: Sendable {
          public enum Kind: Sendable { case direct(prefix: Data), channel(index: UInt8),
              channelData(index: UInt8, dataType: UInt16, payload: Data), rawReply(Data) }
          public init(kind: Kind, text: String = "")
      }
      public init(now: @escaping () -> Date = Date.init, fwVer: UInt8 = 13,
                  queuedMessages: [QueuedMessage] = [], name: String = "MockCore",
                  frequencyKHz: UInt32 = 915_000, bandwidthHz: UInt32 = 250_000,
                  spreadingFactor: UInt8 = 10, codingRate: UInt8 = 5)
      public var fwVer: UInt8 { get set }                     // and each LoRa field: read on the next query
      public func makeSpec(identifier: UUID) -> CBMPeripheralSpec
      public func injectChannelText(_ text: String, channelIndex: UInt8 = 0)
      public func injectMsgWaiting()
      public func enqueueDirectMessage(fromPrefix: Data, text: String)
      public func enqueueChannelMessageForTest(_ text: String, channelIndex: UInt8)
      public func injectChannelData(_ payload: Data, channelIndex: UInt8, dataType: UInt16 = 0xFFFF)  // queues 0x1B, pushes 0x83
      public func enqueueChannelData(_ payload: Data, channelIndex: UInt8, dataType: UInt16 = 0xFFFF) // no push
      public func enqueueRawReply(_ bytes: Data)     // served as a sync reply as is
      public func injectRawData(_ payload: Data)     // pushes 0x84
      public func injectRawFrame(_ bytes: Data)      // notifies bytes as is
      public var receivedFrames: [Data] { get }      // every write, in order
      public var receivedDirectTexts: [String] { get }
      public var receivedChannelTexts: [String] { get }
      public var channelSlots: [MeshCoreChannel] { get set }  // 8 slots; 0 is Public, the rest empty
      public var silentCommands: Set<UInt8> { get set }       // no reply to these opcodes
      public var errorReplies: [UInt8: UInt8] { get set }     // opcode -> err code
      public var rtcSeconds: UInt32 { get set }               // 0: set time always OK
      public var confirmDelay: Duration { get set }           // default 50 ms
      public var pushMsgWaitingDuringContacts: Bool { get set }
      public var onWrite: (@Sendable (Data) -> Void)? { get set }
      public static func catalogue() -> [(name: String, bytes: Data)]   // same builders the delegate uses
  }
  ```
  Default `fwVer` 13 and version string `"1.16.0"` stay, so `deviceQueryYieldsDeviceInfoV13` and `connectRunsInitAndEmitsOrderedEvents` keep their assertions. `fwVer < 3` still answers `[0x0D, fwVer]`: this is what the old tests pin, and v1.18.0 firmware cannot produce it, so the comment says it comes from the old reference, not firmware. LoRa defaults are firmware's (`MyMesh.h`, BW 250, SF 10, CR 5). Offline-queue eviction at 16 is not modelled: nothing in the kit depends on it.

Behaviour per opcode: `0x01` SELF_INFO; `0x16` DEVICE_INFO with the v10+ tail; `0x06` `OK`, or `01 06` if earlier than `rtcSeconds`; `0x02` under 14 bytes `01 01`, unknown 6-byte prefix `01 02`, else `0x06` with ack = LE of the prefix's first 4 bytes, recorded text from byte 13, and `0x82` after `confirmDelay` unless the prefix is `unreachableKey`'s; `0x03` `OK`, record text; `0x3E` per `:1198-1237`: under 4 bytes `01 06`, bad slot `01 02`, type 0 `01 06`, over 165 `01 06`, else `OK`; `0x04` start, 3 contacts, end with 4-byte lastmod; `0x0A` next queued or `0x0A`; `0x14` 11-byte reply; `0x1F` slot or `01 02`; `0x20` 66+ bytes `01 01`, 50+ store then `OK`, bad slot `01 02`; anything else `01 01`.
- [ ] **Step 1: Port `CBMSupport.swift`**
From MeshtasticKit's file: `CBMBackedTests`, `MockRadio`, `makeMockRadio`, `waitUntilPoweredOn`. Add raw helpers `rawConnect(_:)` (subscribes TX, returns the notifications stream), `rawWrite(_:_:)`, `rawCollect(_:count:)`.
- [ ] **Step 2: Write the failing tests**
Move `MeshCoreMockTransportTests` to `MockRadioTests` with assertions as in the table, except `mtuAccommodatesDirectFrameOverTwentyBytes`, which is not moved: it only reads CBM's constant 512 for `.withResponse`, so no change to our code can fail it, and task 7's `frameLargerThanTheLinkMaximumThrows` replaces it. `appStartYieldsSelfInfo` expects `.selfInfo(publicKey: selfKey, name: "MockCore", frequencyKHz: 915_000, bandwidthHz: 250_000, spreadingFactor: 10, codingRate: 5)`. New, all byte-level:

```swift
@Test func selfInfoIsAtTheFirmwareLayout()
//   raw[0]==0x05; raw[4..<36]==selfKey; LE32(raw,48)==915000; LE32(raw,52)==250000; raw[56]==10; raw[57]==5;
//   raw[58...]=="MockCore"; raw.count==66
@Test func setTimeRepliesOkOrIllegalArgWhenTheClockIsAhead()   // [00] at rtcSeconds 0; [01,06] with rtcSeconds above the time sent
@Test func sendChannelDataRepliesOkAndIsRecorded()             // [00]; receivedFrames.last == frame
@Test func sendChannelDataOverOneSixtyFiveIsIllegal()          // 165 -> [00]; 166 -> [01,06]
@Test func sendChannelDataTypeZeroIsIllegal()                  // [01,06]
@Test func sendChannelDataToABadSlotIsNotFound()               // index 200 -> [01,02]
@Test func setChannelThenGetChannelRoundTrips()                // name + secret back in 0x12
@Test func getChannelPastTheLastSlotIsNotFound()               // index 8 -> [01,02]
@Test func injectedChannelDataPushesThenSyncServesThenEnds()   // 83; sync -> 1B frame; sync -> 0A
@Test func injectedRawDataPushesEightyFour()                   // [84,_,_,FF,payload]
@Test func directTextIsReadAfterTheSixBytePrefix()             // receivedDirectTexts.last == "hi"
@Test func directTextToAnUnknownPrefixIsNotFound()             // [01,02]
@Test func unknownCommandIsUnsupported()                       // 0x7E -> [01,01]
@Test func silentCommandGetsNoReply()                          // nothing within 300 ms; next command answered
```

`ParserCrossCheckTests` (no BLE):
```swift
@Test func fixtureFileMatchesTheMock()
//   catalogue() == mock-frames.json, comparing name and hex. With UPDATE_MESHCORE_FIXTURES=1 in the
//   environment it rewrites the file instead (located via #filePath) and fails with a reminder.
@Test func decoderAgreesWithMeshCorePy()
//   for each entry in mock-frames-parsed.json, MeshCoreFrame.decode(hex) matches the fields in the table
```

`catalogue()` covers these, with this field mapping for `decoderAgreesWithMeshCorePy`:

| Frame | `meshcore_py` event and fields | Swift value |
|---|---|---|
| `selfInfo` | `SELF_INFO`: `public_key`, `name`, `radio_freq`×1000, `radio_bw`×1000, `radio_sf`, `radio_cr` | `.selfInfo` |
| `deviceInfo` | `DEVICE_INFO`: `fw ver`, `max_channels`, `ver` | `.deviceInfo` |
| `contact` | `NEXT_CONTACT`: `public_key`, `type`, `adv_name`, `last_advert` | `.contact` |
| `newAdvert` | `NEW_CONTACT`: same | `.newAdvert` |
| `channelInfo` | `CHANNEL_INFO`: `channel_idx`, `channel_name`, `channel_secret` | `.channelInfo` |
| `msgSent` | `MSG_SENT`: `type`, `expected_ack` (raw LE bytes), `suggested_timeout` | `.msgSent` |
| `contactMsgV3` | `CONTACT_MSG_RECV`: `pubkey_prefix`, `txt_type`, `sender_timestamp`, `text` | `.contactMsgRecvV3` |
| `channelMsgV3` | `CHANNEL_MSG_RECV`: `channel_idx`, `txt_type`, `sender_timestamp`, `text` | `.channelMsgRecvV3` |
| `channelData` | `CHANNEL_DATA_RECV`: `channel_idx`, `data_type`, `payload` | `.channelDataRecv` |
| `rawData` | `RAW_DATA`: `payload` | `.rawData` |
| `sendConfirmed` | `ACK`: `code` | `.sendConfirmed` |
| `battery` | `BATTERY`: `level` | `.battery` |
| `ok`, `error` | `OK`; `ERROR`: `error_code` | `.ok`, `.error(code:)` |

All names were read from `reader.py`; only `SELF_INFO`, `CHANNEL_DATA_RECV` and `RAW_DATA` were actually run during planning.
- [ ] **Step 3: Run to verify failure**
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshCoreKit --filter "MockRadioTests|ParserCrossCheckTests"`
Expected: compile failure, `MockMeshCoreDevice` not found.
- [ ] **Step 4: Implement `MockMeshCoreDevice.swift`**
Start from the old file. Replace `lock.withLock` (`:248`) with explicit lock/unlock. Keep `mtu: 512`.
- [ ] **Step 5: Write `scripts/parse-with-meshcore-py.py`**
Signature: `parse-with-meshcore-py.py <meshcore_py src dir> <frames.json> <parsed.json>`. Header comment: dev-time only, pinned to `c5ffc38`, meshcore_py is never linked or copied, run with `python -I`, read the clone as data. It inserts the first argument into `sys.path`, builds `EventDispatcher` and `MessageReader`, subscribes each event type in the table, `await reader.handle_rx(bytearray(frame))` per frame, and writes `{name, event, fields}` with bytes as hex. It fails non-zero if a frame produces no event. `/tmp/ReTiCaMsgr/lane-a-py-probe.py`, if still there, shows the driving code working.
- [ ] **Step 6: Generate the fixtures**
Run: `git -C /tmp/ReTiCaMsgr/research/meshcore-py rev-parse HEAD`
Expected: `c5ffc383730db311ac91b5ef5067e2808584ef92`. If not, or the clone is gone, re-clone to a new empty directory at that commit.
Run: `UPDATE_MESHCORE_FIXTURES=1 swift test --package-path /Users/ell/development/ios/pods/MeshCoreKit --filter fixtureFileMatchesTheMock`
Expected: this run fails with the "fixture rewritten" reminder, and `mock-frames.json` exists.
Run (once, if the venv is gone): `/Users/ell/opt/anaconda3/envs/rns/bin/python -I -m venv /tmp/ReTiCaMsgr/mcpy-venv`
Run (once): `/tmp/ReTiCaMsgr/mcpy-venv/bin/python -I -m pip install --only-binary :all: pycayennelpp pycryptodome pyserial-asyncio-fast`
(`bleak` is optional at import. The conda `rns` env lacks `Crypto`, so it needs this venv.)
Run: `/tmp/ReTiCaMsgr/mcpy-venv/bin/python -I /Users/ell/development/ios/pods/MeshCoreKit/scripts/parse-with-meshcore-py.py /tmp/ReTiCaMsgr/research/meshcore-py/src /Users/ell/development/ios/pods/MeshCoreKit/Tests/MeshCoreKitTests/Fixtures/mock-frames.json /Users/ell/development/ios/pods/MeshCoreKit/Tests/MeshCoreKitTests/Fixtures/mock-frames-parsed.json`
Expected: exit 0. Read the parsed JSON's `selfInfo` entry by eye: `radio_freq` 915.0, `name` `MockCore`. A disagreement means firmware, parser and code must be re-read; do not edit the fixture by hand.
- [ ] **Step 7: Run (step a)**
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshCoreKit --filter "MockRadioTests|ParserCrossCheckTests"`
Expected: all pass.
- [ ] **Step 8: Mutate in one batch (step b)**
In the mock: self-info name offset by adding one extra byte before the name; set time always `OK`; `0x3E` limit 166 and type 0 accepted, bad slot `OK`; `injectChannelData` no `0x83`; `0x84` reserved byte omitted; `0x20` store nothing; `0x1F` out of range answers a slot; DM key read as 32 bytes and text from 39, unknown prefix answered with `0x06`; unknown opcode silent; `silentCommands` ignored; for the moved tests, `deviceInfo` max channels 4, the short `fwVer < 3` reply reports `fwVer + 1`, `getChannel(0)` wrong secret, contact count 2, `sendConfirmed` ack + 1. In `MeshCoreFrame.swift`: `0x1B` type read big-endian, for `decoderAgreesWithMeshCorePy`.
Run: same filter.
Expected: every test in `MockRadioTests` and both `ParserCrossCheckTests` FAIL.
- [ ] **Step 9: Revert and re-run (step c)**. Expected: all pass.
- [ ] **Step 10: Commit**
Subject `feat: MeshCoreMock from firmware source, frames checked against meshcore_py's parser`. Paths: `Package.swift Sources/MeshCoreMock scripts Tests/MeshCoreKitTests/Fixtures Tests/MeshCoreKitTests/Support/CBMSupport.swift Tests/MeshCoreKitTests/MockRadioTests.swift Tests/MeshCoreKitTests/ParserCrossCheckTests.swift`, and `Sources/MeshCoreKit/MeshCoreFrame.swift` only if the cross-check changed it.

### Task 5: `MeshCoreSession`: event hub, retrieve-only connect, handshake, `.configured`, terminal causes, disconnect

**Files:**
- Create: `Sources/MeshCoreKit/EventHub.swift`, `Sources/MeshCoreKit/MeshCoreSession.swift`, `Tests/MeshCoreKitTests/Support/SessionSupport.swift`, `Tests/MeshCoreKitTests/SessionConnectTests.swift`
**Interfaces:**
- Consumes: `MockMeshCoreDevice`, frame and value types.
- Produces: `MeshCoreSession.init(central:clock:appName:)`, `connect(radio:) async`, `disconnect() async`, `nonisolated events()`, `public static let firmwareTooOldReason = "firmware too old"` (the literal's only definition: the session, the tests, Meshtastified's adapter and lane D's mapper all use the constant), and the internal primitive every later command uses:
  ```swift
  /// Takes the FIFO slot, writes `frame`, ends on a reply whose first byte is in `until`.
  /// `timeout` nil: bounded only by the 30 s handshake timer.
  private func exchange(_ frame: Data, collecting: Set<UInt8>, until: Set<UInt8>,
                        timeout: Duration?) async throws -> [MeshCoreFrame]
  ```

**The slot's rules:** port `acquireWriteSlot`, `releaseWriteSlot`, `resetWriteSlot`, `inFlightWrite` from `MeshtasticSession.swift:374-444`, widened so the slot covers write **and** reply. Install the in-flight record before writing, so a fast reply is caught. The exchange ends only when both the write has returned and a terminating reply has been seen (Review Focus 1). Teardown fails the in-flight exchange and every waiter with `.notConnected` and bumps the generation.

**Reply routing, in `handleNotification(_ data: Data)`, in this order:** empty data is ignored. Decode; on failure log, and if the first byte is `0x10`, `0x11` or `0x1B` and a sync is in flight, end that sync step (task 6). Emit `.frame`. Code ≥ `0x80` is a push (task 6). Otherwise offer it to the in-flight exchange; anything unasked for is dropped.
- [ ] **Step 1: Port `SessionSupport.swift`**
From MeshtasticKit's: `connectionState`, `isConfigured`, `collect`, `waitUntil`, `recording`, `fakeCentral`, `SleepRecordingClock`, `AsyncGate`, `makeSessionHarness(id:clock:fwVer:initialState:extra:)` with `ContinuousClock` as the default and `appName: "test"`.
- [ ] **Step 2: Write the failing tests**
```swift
@Test func eventsReplayDisconnectedBeforeAnyConnect()   // first event == .connection(.disconnected(reason: nil))
@Test func unauthorizedAdapterIsTerminalAndNeverConnects()
//   fake .unauthorized: .adapterUnavailable(.unauthorized), .disconnected(reason: "unauthorized"), no "connect" logged
// nested in CBMBackedTests:
@Test func connectRunsTheHandshakeInOrderAndEmitsConfigured()
//   states: .connecting, .configuring, .connected, then .configured(info)
//   info == MeshCoreRadioInfo(publicKey: selfKey, name: "MockCore", frequencyKHz: 915_000, bandwidthHz: 250_000,
//           spreadingFactor: 10, codingRate: 5, firmwareCode: 13, maxChannels: 8)
//   device.receivedFrames.map(\.first) starts [0x01, 0x16, 0x06, 0x0A]
@Test func appStartCarriesTheAppName()   // receivedFrames[0] == MeshCoreCommand.appStart(appName: "test")
@Test func handshakeFetchesNeitherContactsNorChannels()   // no 0x04, no 0x1F written
@Test func setTimeWaitsForItsReplyBeforeTheDrain()
//   silentCommands [0x06] with TestClock: reaches .configuring, no 0x0A written after 300 ms real time
@Test func setTimeSendsTheCurrentTime()   // LE32 in the 0x06 frame within 5 s of Date()
@Test func radioClockAheadStillConfigures()   // rtcSeconds = .max: .configured arrives
@Test func connectRetrievesThePeripheralFirstAndNeverScans()   // log first "retrievePeripherals", no "scan"
@Test func connectToAnUnknownRadioEndsDisconnectedRadioNotFound()
@Test func connectWhilePoweredOffWaitsThenConnects()
//   .adapterUnavailable(.poweredOff) once; after power on .configured
@Test func disconnectDropsTheLinkAndReportsDisconnectedWithNilReason()
@Test func firmwareBelowThreeEndsDisconnectedAndDoesNotRetry()
//   fwVer 2: .disconnected(reason: MeshCoreSession.firmwareTooOldReason); after 1.5 s real time retrievePeripherals logged once
@Test func firmwareTenStillConfigures()    // fwVer 10: .configured with firmwareCode 10
@Test func errorReplyToAppStartIsRetryable()   // errorReplies[0x01] = 1: .reconnecting(attempt: 1)
```
- [ ] **Step 3: Run to verify failure**
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshCoreKit --filter SessionConnectTests`
Expected: compile failure, `MeshCoreSession` not found.
- [ ] **Step 4: Implement**
`EventHub` is `pods/MeshtasticKit/Sources/MeshtasticKit/EventHub.swift` with the type names swapped. In `MeshCoreSession`, port `connect`, `disconnect`, `tearDownLink`, `runAttempt`, `resolveAttempt`, `abortAttempt`, the attempt power watch, `check`, `waitForPoweredOn` from `MeshtasticSession.swift` unchanged in shape, including `TerminalFailure`. `attemptConnect` differs from `:271-335` after characteristic discovery: take `central.notifications(radio, MeshCoreGATT.txUUID)`, `setNotify(true, …)`, start the notification loop, `.configuring`, handshake timeout, then the handshake with `timeout: nil`. Handshake `until` sets: `[0x05, 0x01]`, `[0x0D, 0x01]`, `[0x00, 0x01]`, and for sync `[0x0A, 0x10, 0x11, 0x1B]`. `01` to `APP_START` or `DEVICE_QUERY` throws retryable; `01` to set time logs and continues. Below firmware 3, throw `TerminalFailure(reason: Self.firmwareTooOldReason)`. Before writing a frame, if its length exceeds 20 B and `maximumWriteValueLength` is below it, throw `.frameTooLarge`. The old connect-time floor of 41 B goes, because it existed only for the 41-byte DM frame that bug A removes.
- [ ] **Step 5: Run (step a)**. Expected: all pass.
- [ ] **Step 6: Mutate in one batch (step b)**
In `EventHub.swift`: initial replayed state `.connecting`. In `MeshCoreSession.swift`: `.configured` emitted before `.connected`; handshake skips `DEVICE_QUERY`; `appName` ignored; add a `0x04` write after the drain; set time without waiting; set time writes 0; `01` to set time throws; retrieve replaced by `connect` first; `"radio not found"` becomes `"lost"`; remove the powered-on gate; `disconnect` reason `"bye"`; firmware floor changed to `< 2` so firmware 2 retries; `firmwareCode` reported as 11; `01` to `APP_START` treated as terminal; unauthorized check removed.
Expected: all 15 FAIL.
- [ ] **Step 7: Revert and re-run (step c)**. Expected: all pass.
- [ ] **Step 8: Commit**
Subject `feat: MeshCoreSession connect, handshake, configured and terminal causes`. Paths: the files listed above.

### Task 6: Receive: sync drain, `0x1B`, `0x84`, `.frame`, hostile input

**Files:**
- Modify: `Sources/MeshCoreKit/MeshCoreSession.swift`
- Test: `Tests/MeshCoreKitTests/SessionReceiveTests.swift`
**Interfaces:**
- Consumes: `exchange`, `handleNotification` (task 5); mock inject and enqueue methods.
- Produces: `.channelData(channelIndex:dataType:payload:)`, `.rawData(payload:)`, after their `.frame`. Direct and channel text arrive only as `.frame`.
- [ ] **Step 1: Write the failing tests** (nested in `CBMBackedTests`)
```swift
@Test func queuedMessagesDrainBeforeConfigured()
//   queued DM + channel text: their .frame events come before .configured; 0x0A written 3 times
@Test func queuedChannelDataDoesNotStallTheHandshake()
//   THE audit bug. TestClock that never advances, queued .channelData: .configured within 5 s real time;
//   .channelData(channelIndex: 3, dataType: 0xFFFF, payload: p) seen
@Test func msgWaitingPushDrainsUntilNoMoreMessages()
//   3 enqueued, one injectMsgWaiting: 3 .frame messages, then 4 0x0A writes total for that drain
@Test func channelDataPushEmitsFrameThenChannelData()
@Test func rawDataPushEmitsFrameThenRawDataAndNoSync()   // no 0x0A written for it
@Test func textMessagesAreFrameOnly()   // no .channelData, no .rawData for 0x10 / 0x11
@Test func otherPushesEmitFrameAndNothingElse()   // injectRawFrame [0x88,…] == .frame(.unknown(code: 0x88))
@Test func garbageFrameIsSkippedAndTheDrainContinues()   // injectRawFrame [0x03,0x01], then a real push delivered
@Test func malformedMessageFrameDuringDrainDoesNotStall()
//   enqueueRawReply([1B,0,0,0]) then valid data, push, TestClock not advanced: the valid frame arrives
@Test func msgWaitingDuringADrainIsNotDropped()
//   a second message enqueued and pushed from onWrite during the first drain's first sync: it arrives
@Test func msgWaitingDuringHandshakeIsDrainedAfterConfigured()
//   from onWrite on the handshake's last 0x0A: enqueue, push; it arrives after .configured
@Test func emptyNotificationIsIgnored()   // injectRawFrame(Data()) then a real push delivered
```
- [ ] **Step 2: Run to verify failure**
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshCoreKit --filter SessionReceiveTests`
Expected: tests that need `.channelData`, `.rawData` or the push handler fail by bounded timeout. `queuedMessagesDrainBeforeConfigured` and `textMessagesAreFrameOnly` may pass on task 5's work: note which, and they are still mutation-checked.
- [ ] **Step 3: Implement**
Port the drain lock from `MeshtasticSession.swift:487-522`: `isDraining`, `drainRequested`, `drainGeneration`. On `0x83`: `drainSteady(radio:epoch:)`. A step is one `exchange(syncNextMessage, collecting: [], until: [0x0A, 0x10, 0x11, 0x1B], timeout: 5 s)`, and the slot is released between steps, so a long queue cannot starve a send. Stop on `0x0A` unless `drainRequested`, on a timeout (log; leave `drainRequested` as set), or on epoch change. After `.configured`, run one more drain as the precedent does at `:334`.
- [ ] **Step 4: Run (step a)**. Expected: all pass.
- [ ] **Step 5: Mutate in one batch (step b)**
Remove `0x1B` from the sync `until` set (the original bug); drain stops after one message; ignore `0x83`; emit `.channelData` before `.frame`, and `.rawData` before `.frame` while also syncing on `0x84`; emit a typed `.channelData` for `0x11` too; drop `.frame` for code `0x88`; handshake skips its drain; drop `drainRequested` handling and the drain after `.configured`; end-of-step on malformed frames removed; empty data force-unwrapped (`data.first!`); a malformed frame ends the notification loop.
Expected: all 12 FAIL.
- [ ] **Step 6: Revert and re-run (step c)**. Expected: all pass.
- [ ] **Step 7: Commit**
Subject `feat: MeshCoreSession owns the sync drain; 0x1B and 0x84 reach events`. Paths: `Sources/MeshCoreKit/MeshCoreSession.swift Tests/MeshCoreKitTests/SessionReceiveTests.swift`.

### Task 7: Commands: `request`, `sendChannelData`, `channels`, `setChannel`, frame limit, one at a time

**Files:**
- Modify: `Sources/MeshCoreKit/MeshCoreSession.swift`, `Tests/MeshCoreKitTests/Support/SessionSupport.swift`
- Test: `Tests/MeshCoreKitTests/SessionCommandTests.swift`
**Interfaces:**
- Consumes: `exchange`.
- Produces: Contract 1's `request(_:collecting:until:timeout:)`, `sendChannelData(channelIndex:dataType:payload:)`, `channels()`, `setChannel(index:name:secret:)`. Internal `static let maxFrameLength = 173`, `static let commandTimeout: Duration = .seconds(5)`.

Semantics: `request` removes `0x10`, `0x11`, `0x1B` from both sets. `timeout` is silence since the last collected frame. Check order for every call: not connected, then firmware (only `sendChannelData`), then frame size. Typed methods use `until: [0x00, 0x01]` or `[0x12, 0x01]`, and map `01` to `.radioError(code:)`. `setChannel` with a secret that isn't 16 bytes throws `.radioError(code: nil)` without writing.
- [ ] **Step 1: Add `gatedWrites(_ base:, code: UInt8, gate: AsyncGate) -> BluetoothCentralClient` to `SessionSupport.swift`**
It wraps the live central: a write whose first byte is `code` reaches the mock at once, so the reply arrives, but the wrapper does not return until `gate` opens.
- [ ] **Step 2: Write the failing tests**
```swift
@Test func requestBeforeConnectThrowsNotConnected()
// nested in CBMBackedTests:
@Test func requestReturnsCollectedFramesEndingWithUntil()
//   getContacts, collecting [0x02,0x03], until [0x04]: .contactStart(3), 3 contacts, .contactEnd
@Test func requestOmitsFramesItWasNotAskedFor()   // collecting [], until [0x04]: only .contactEnd
@Test func requestListsAnErrorWhenAskedFor()   // errorReplies[0x14]=4, until [0x0C,0x01]: [.error(code: 4)]
@Test func requestTimesOutAfterSilence()   // TestClock, silentCommands [0x14]: pending at 4.9 s; .timedOut by 5.1 s
@Test func requestTimeoutRestartsOnEveryCollectedFrame()
//   collecting [0x7D], until [0x7C], timeout 5 s: inject 0x7D at 4 s and 8 s; pending at 8.9; .timedOut by 13.1
@Test func messageFramesNeverSatisfyARequest()
//   until [0x1B,0x10,0x11]: inject each: .frame events seen; request still ends .timedOut
@Test func channelDataArrivingDuringACommandDoesNotStallIt()
//   silentCommands [0x14], in-flight request, injectRawFrame(1B…), then injectRawFrame([0x0C,…]): request returns; .channelData seen
@Test func msgWaitingDuringContactBurstLosesNothing()
//   pushMsgWaitingDuringContacts, 1 queued DM: 3 contacts returned; DM .frame arrives; first 0x0A is after the 0x04 exchange
@Test func replyBeforeWriteCompletionHoldsTheSlotUntilTheWriteReturns()
//   gatedWrites on 0x14: request A's reply arrives, A still pending; B's frame not in receivedFrames;
//   open the gate: A returns, then B is written and returns
@Test func concurrentSendsAllComplete()   // 8 concurrent sendChannelData: all return within 10 s; 8 distinct frames recorded in order
@Test func frameOfOneSeventyThreeBytesIsWritten()   // request of 173 B: receivedFrames.last.count == 173
@Test func frameOfOneSeventyFourBytesThrowsAndWritesNothing()   // .frameTooLarge; onWrite never called
@Test func frameLargerThanTheLinkMaximumThrows()   // wrapper central reports maximumWriteValueLength 20: 21 B throws .frameTooLarge, no write
@Test func disconnectMidRequestThrowsNotConnectedPromptly()   // within 3 s, 30 s timeout requested
@Test func sendChannelDataWritesExactBytes()   // (2, 0xFFFF, [AA]) == [3E,02,FF,FF,FF,AA]
@Test func sendChannelDataMapsTheRadioErrorCode()   // errorReplies[0x3E]=3: .radioError(code: 3)
@Test func sendChannelDataAtTheFirmwareLimits()   // 165 ok; 166 .radioError(code: 6); 169 .frameTooLarge (174 B)
@Test func sendChannelDataBelowFirmwareElevenThrowsWithoutWriting()   // fwVer 10: .firmwareTooOld, no 0x3E; fwVer 11: ok
@Test func sendChannelDataBeforeConnectThrowsNotConnected()
@Test func channelsReturnsEverySlot()   // count 8; [0] Public + publicChannelSecret; [1] name "" and 16 zero bytes
@Test func setChannelThenChannelsRoundTrips()
@Test func clearingASlotWritesEmptyNameAndZeroSecret()   // frame == MeshCoreCommand.setChannel(index: 2, name: "", secret: zeros); slot empty
@Test func setChannelRejectsAWrongSecretLengthWithoutWriting()   // 32 bytes: .radioError(code: nil), no 0x20
```
- [ ] **Step 3: Run to verify failure**
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshCoreKit --filter SessionCommandTests`
Expected: compile failure, no `request`.
- [ ] **Step 4: Implement**, in `MeshCoreSession.swift`
The silence timer is one task per exchange on the injected clock, restarted when a frame is collected and identified by a sequence number so a stale timer does nothing.
- [ ] **Step 5: Run (step a)**. Expected: all pass.
- [ ] **Step 6: Mutate in one batch (step b)**
- Connected check removed from `request` and `sendChannelData`.
- `exchange` ends on the first collected frame, and drops the terminating frame from the result.
- Collected list keeps every frame.
- `01` to the typed methods reads `code: nil`; `channels()` returns only the first slot; `setChannel` no-op; secret-length guard removed.
- Timer not restarted on a collected frame; timer doubled.
- `request` doesn't strip message codes.
- Slot released on the reply alone. **This is the tricky one:** it must break `replyBeforeWriteCompletion…` and may hang `concurrentSends…`, which is why that test has a 10 s bound.
- Exchange bypasses the slot while the drain runs, so the drain interleaves with contacts: breaks `msgWaitingDuringContactBurst…`.
- `.frame` handling stops on message frames with no in-flight sync: breaks `channelDataArriving…`.
- Size check becomes `count == 173 || count > 174`, which breaks the 173, 174 and 169-payload tests with one edit. The link-maximum check is removed.
- Teardown no longer fails the in-flight exchange.
- `sendChannelData` writes path byte `0x00`; firmware gate at `< 10`; firmware check after the write.

Expected: all 24 FAIL. If a test survives, fix the test or the mutation and restart at (a).
- [ ] **Step 7: Revert and re-run (step c)**. Expected: all pass.
- [ ] **Step 8: Commit**
Subject `feat: request, sendChannelData and channel slots through one command slot`. Paths: as listed.

### Task 8: Reconnect: per-peripheral watch, power state, backoff, first-connect retry, epoch races, 30 s timeout

**Files:**
- Modify: `Sources/MeshCoreKit/MeshCoreSession.swift`
- Test: `Tests/MeshCoreKitTests/SessionReconnectTests.swift`
**Interfaces:**
- Consumes: tasks 5–7.
- Produces: `.reconnecting(attempt:)`; `static let maxBackoff: Duration = .seconds(30)`, `static let handshakeTimeout: Duration = .seconds(30)`; `.configured` again after each reconnect.
- [ ] **Step 1: Write the failing tests**
Port from `pods/MeshtasticKit/Tests/MeshtasticKitTests/SessionReconnectTests.swift`:

```swift
@Test func firstAttemptFailureEntersBackoffInsteadOfStopping()     // fake connect throws: .reconnecting(attempt: 1)
@Test func backoffDoublesFromOneSecondAndCapsAtThirty()            // SleepRecordingClock: 1,2,4,8,16,30,30
@Test func reconnectingCountsAttemptsUpFromOne()
@Test func attemptResolvingAfterDisconnectStaysDisconnected()      // gated connect, disconnect, open: no .reconnecting, no .connected
// nested in CBMBackedTests:
@Test func unexpectedDisconnectReconnectsViaRetrieveAndNeverScans()
@Test func reconnectReemitsConfiguredWithTheRadiosCurrentParameters()   // new LoRa params on the mock's next link
@Test func anotherPeripheralsDisconnectIsIgnored()                 // second mock drops: no .reconnecting
@Test func disconnectDuringBackoffStaysDisconnected()              // TestClock
@Test func powerCycleWhileConnectedReconnectsAndReportsAdapter()
//   .reconnecting(attempt: 1), .adapterUnavailable(.poweredOff), then .configured after power on
@Test func handshakeWithoutAReplyTimesOutAtThirtySecondsIntoBackoff()
//   silentCommands [0x01], TestClock: .configuring at 29.9 s; .reconnecting(attempt: 1) by 30.1 s
@Test func commandInFlightAtLinkLossThrowsNotConnected()           // silent command, simulateDisconnection: throws within 3 s
@Test func commandQueuedAtLinkLossThrowsNotConnected()             // a waiter behind it too
@Test func staleWriteResultFromAnOldLinkIsIgnored()                // gatedWrites, drop, reconnect, open gate: new link's next command still completes
@Test func firmwareBelowThreeDiscoveredOnReconnectStops()          // mock fwVer set to 2 before the drop: .disconnected(reason: MeshCoreSession.firmwareTooOldReason), no more attempts
```
- [ ] **Step 2: Run to verify failure**
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshCoreKit --filter SessionReconnectTests`
Expected: fail. `attemptResolvingAfterDisconnect…` and `commandInFlight…`-style tests may already pass on task 5's guards; they are still mutation-checked.
- [ ] **Step 3: Implement**
Port `startDisconnectWatch`, `handleLinkLost`, `scheduleReconnect`, `reconnectLoop`, `startHandshakeTimeout`, `handshakeTimedOut` from `MeshtasticSession.swift:558-647`. Link loss also cancels the notification loop and resets the slot and drain state.
- [ ] **Step 4: Run (step a)**. Expected: all pass.
- [ ] **Step 5: Mutate in one batch (step b)**
- `disconnect` no longer bumps `epoch`, so stale work resurrects state.
- First-attempt `.retryable` ends in `.disconnected`.
- `maxBackoff` 60; attempt counter stuck at 1.
- Watch: `peripheral.id == radio` filter removed; `.didUpdateState` case removed; link-loss uses `central.scan` first (drives the never-scans test).
- `reconnectLoop` loses its epoch guard.
- `handshakeTimeout` 20 s.
- Link loss no longer resets the slot, breaking both `command…` tests.
- `finishWrite` drops its sequence check.
- Terminal outcome in the reconnect loop treated as retryable.
- `.configured` emitted only for the first link.
- Mock radio params aren't re-read: mutate session to cache `MeshCoreRadioInfo` from the first handshake.

Expected: all 14 FAIL.
- [ ] **Step 6: Revert and re-run (step c)**. Expected: all pass.
- [ ] **Step 7: Commit**
Subject `feat: MeshCoreSession reconnect with Meshtastic's reliability behaviours`. Paths: `Sources/MeshCoreKit/MeshCoreSession.swift Tests/MeshCoreKitTests/SessionReconnectTests.swift`.

### Task 9: `MeshCoreScanner`, platform builds

**Files:**
- Create: `Sources/MeshCoreKit/MeshCoreScanner.swift`
- Test: `Tests/MeshCoreKitTests/ScannerTests.swift`
**Interfaces:**
- Consumes: `MeshCoreGATT`, `DiscoveredMeshCoreRadio`.
- Produces: `MeshCoreScanner.scan(central:) -> AsyncStream<DiscoveredMeshCoreRadio>`. Only lane D uses it; Meshtastified does not. `SharedScanner` keeps its one combined scan because FCB runs one scan per central.
- [ ] **Step 1: Write the failing tests**
```swift
@Test func scanFiltersOnTheServiceUUID()   // captured scan services == [MeshCoreGATT.serviceUUID]
@Test func scanKeepsOnlyNamesStartingMeshCore()   // "MeshCore-Ell" yes; "NUS-Thermometer" no; nil no
@Test func nameFallsBackToThePeripheralNameWhenNotAdvertised()
@Test func cancellingTheConsumerEndsTheUnderlyingScan()
// nested in CBMBackedTests:
@Test func scanWaitsForPoweredOnThenYieldsTheMockRadio()   // id, name "MeshCore-Mock"
```
- [ ] **Step 2: Run to verify failure**
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshCoreKit --filter ScannerTests`
Expected: compile failure.
- [ ] **Step 3: Implement**
Port `MeshtasticScanner.swift` with the name filter added: `guard (name ?? "").hasPrefix(MeshCoreGATT.namePrefix) else { continue }`.
- [ ] **Step 4: Run (step a), then the whole kit**
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshCoreKit`
Expected: all pass. Note the total as **KIT**.
- [ ] **Step 5: Mutate in one batch (step b)**
Scan with `[]` services; drop the name guard, and for the fallback test use only `advertisementData.localName`; stop passing cancellation to the task (remove `onTermination`); remove `waitForPoweredOn`, and map `name` to `nil` so the mock test's name assertion fails even if CBM's scan works.
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshCoreKit --filter ScannerTests`
Expected: all 5 FAIL.
- [ ] **Step 6: Revert and re-run (step c)**. Expected: all pass.
- [ ] **Step 7: Build for the other platforms, from the kit directory**
Write `/tmp/ReTiCaMsgr/kit-build.sh` containing `cd /Users/ell/development/ios/pods/MeshCoreKit` then `xcodebuild -scheme MeshCoreKit-Package -destination "$1" build` on separate lines.
Run: `bash /tmp/ReTiCaMsgr/kit-build.sh "generic/platform=iOS Simulator"`
Run: `bash /tmp/ReTiCaMsgr/kit-build.sh "generic/platform=macOS,variant=Mac Catalyst"`
Expected: `** BUILD SUCCEEDED **` for each.
- [ ] **Step 8: Commit**
Subject `feat: MeshCoreScanner`. Paths: `Sources/MeshCoreKit/MeshCoreScanner.swift Tests/MeshCoreKitTests/ScannerTests.swift`.

### Task 10: Worktree: frames, GATT and mock come from MeshCoreKit (old actor logic unchanged)

**Files (under `apps/Meshtastified-meshcorekit/MeshtastifiedKit`):**
- Modify: `Package.swift`, `Sources/MeshDeviceClient/Exports.swift`, `MeshDeviceClient+Live.swift`, `MeshCore/MeshCoreSessionActor.swift`, `MeshCore/MeshCoreError.swift`, `Tests/MeshDeviceClientTests/RouterDispatchTests.swift`
- Delete: the five paths in the file structure table
**Interfaces:**
- Consumes: products `MeshCoreKit`, `MeshCoreMock`.
- Produces: `import MeshDeviceClient` reaches `MockMeshCoreDevice`, via `@_exported import MeshCoreMock`. The app has `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`, so a typealias would not do. `RadioRouter` and `SharedScanner` keep their shape.
- [ ] **Step 1: Edit `Package.swift`**
Add `.product(name: "MeshCoreKit", package: "MeshCoreKit")` and `.product(name: "MeshCoreMock", package: "MeshCoreKit")` to the `MeshDeviceClient` target and `MeshDeviceClientTests`.
- [ ] **Step 2: Delete the moved code**
Run: `git -C /Users/ell/development/ios/apps/Meshtastified-meshcorekit rm MeshtastifiedKit/Sources/MeshDeviceClient/MeshCore/MeshCoreFrame.swift MeshtastifiedKit/Sources/MeshDeviceClient/MeshCore/MeshCoreGATT.swift MeshtastifiedKit/Sources/MeshDeviceClient/Mock/MockMeshCoreDevice.swift MeshtastifiedKit/Tests/MeshDeviceClientTests/MeshCoreFrameTests.swift MeshtastifiedKit/Tests/MeshDeviceClientTests/MeshCoreMockTransportTests.swift`
- [ ] **Step 3: Re-export and import**
Append to `Exports.swift`: `@_exported import MeshCoreMock`, with its comment extended to name both mocks. Add `import MeshCoreKit` to `MeshCoreSessionActor.swift`, `MeshDeviceClient+Live.swift`, `RouterDispatchTests.swift`. In `MeshCoreSessionActor.swift`, change only the `selfInfo` pattern at `:175` to `.selfInfo(let key, let name, _, _, _, _)` and keep the rest. Remove `decodeFailed` from `MeshCoreError`.
- [ ] **Step 4: Run the suite (step a)**
Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshcorekit/MeshtastifiedKit`
Expected: **BASELINE − 35** passed (28 frame + 7 mock transport tests left the app), no failures. The old actor ignores the new `OK` to set time: it lands in `responseBuffer` and the next write clears it (`:312`).
- [ ] **Step 5: Mutate in one batch (step b)**, proving the re-pointed tests exercise the moved code
- In the worktree's `SharedScanner.dispatch` (`MeshDeviceClient+Live.swift:134`): replace `MeshCoreGATT.namePrefix` with `"X"`.
- In `pods/MeshCoreKit/Sources/MeshCoreMock/MockMeshCoreDevice.swift`, in the self-info builder, write `selfKey` with its first byte changed.
- In `pods/MeshCoreKit/Sources/MeshCoreKit/MeshCoreFrame.swift`, in `sendDirectText`, write an empty prefix, so the mock answers with an error instead of `0x06`.

Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshcorekit/MeshtastifiedKit --filter "RouterDispatchTests|MeshCoreRouterTests|MeshCoreSessionTests|MeshCoreSendTests"`
Expected: FAIL in `nusScanDropsDeviceWithoutMeshCoreNamePrefix`, `typedConnectMeshcoreDispatchesToMeshcoreSession`, `connectRunsInitAndEmitsOrderedEvents`, `directSendReturnsAckPacketIDAndRoutesAck`.
- [ ] **Step 6: Revert and re-run (step c)**
Run: `git -C /Users/ell/development/ios/pods/MeshCoreKit checkout -- Sources/MeshCoreMock/MockMeshCoreDevice.swift Sources/MeshCoreKit/MeshCoreFrame.swift`
Revert the `SharedScanner` edit by hand.
Run: `git -C /Users/ell/development/ios/pods/MeshCoreKit status --short`
Expected: no output.
Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshcorekit/MeshtastifiedKit`
Expected: BASELINE − 35.
- [ ] **Step 7: Build the app**
Run: `xcodebuild -project /Users/ell/development/ios/apps/Meshtastified-meshcorekit/Meshtastified.xcodeproj -scheme Meshtastified -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`. This proves `MeshtastifiedApp.swift:96-140` still finds the mock.
- [ ] **Step 8: Commit in the worktree**
Subject `refactor: MeshCore frames, GATT and the mock radio now come from MeshCoreKit`. Stage `Package.swift`, `Exports.swift`, `MeshDeviceClient+Live.swift`, `MeshCoreSessionActor.swift`, `MeshCoreError.swift` and `RouterDispatchTests.swift`; the deletions are staged from Step 2.

### Task 11: `MeshCoreEventMapper` (pure, not wired yet)

**Files (worktree):**
- Create: `MeshtastifiedKit/Sources/MeshDeviceClient/MeshCore/MeshCoreEventMapper.swift`
- Test: `MeshtastifiedKit/Tests/MeshDeviceClientTests/MeshCoreEventMapperTests.swift`
**Interfaces:**
- Consumes: `MeshCoreFrame`, `MeshCoreContact`, `MeshCoreConnectionState`, `MeshCoreGATT.publicChannelSecret`, MeshModels.
- Produces:
  ```swift
  struct MeshCoreEventMapper {
      init(now: @escaping @Sendable () -> Date, nextPacketID: @escaping @Sendable () -> PacketID)
      private(set) var identity: MeshIdentity          // .meshcore(zeros) initially
      private(set) var selfName: String
      private(set) var publicSlotIndex: UInt8?
      private(set) var firmwareCode: UInt8
      /// A new link: hold message frames until `finishFetch`. Contacts stay.
      mutating func beginLink()
      /// `.frame` mapping. Reply-only frames, including .contact, .channelInfo, .battery, .ok: [].
      mutating func map(_ frame: MeshCoreFrame) -> [MeshEvent]
      mutating func applyFetchedContact(_ contact: MeshCoreContact) -> MeshEvent
      mutating func applyFetchedChannel(index: UInt8, secret: Data)
      mutating func finishFetch() -> [MeshEvent]
      /// Ack tracked from `.msgSent` seen on the same ordered stream as `.sendConfirmed`.
      mutating func expireAck(_ ack: UInt32)
      /// nil for `.connected`: the adapter emits that when its fetch ends.
      static func connectionState(_ state: MeshCoreConnectionState) -> MeshModels.ConnectionState?
  }
  ```

The mapping bodies move from `MeshCoreSessionActor.swift:237-245` (`upsertContact`) and `:262-290`. Keep them as they are, including `Message(id: nextPacketID(), …)`, the all-zero sentinel sender and `ts == 0` meaning `now()`. Tracking the ack from `.msgSent` closes a race: `sendText` resumes after the frame event, so an ack registered there could lose to a fast `0x82`.
- [ ] **Step 1: Write the failing tests** (no BLE)
```swift
@Test func selfInfoEmitsMyIdentityAndStoresTheName()
@Test func deviceInfoEmitsMetadataAtFirmwareThreeOrAbove()   // fw 2: []; firmwareCode still recorded
@Test func contactFallsBackToHexNamesAndNilLastHeard()   // empty adv name: longName == 12-char hex; lastAdvert 0: nil
@Test func newAdvertEmitsANode()
@Test func directMessageFromAKnownContactMaps()   // from .meshcore(key), .direct, .incoming
@Test func directMessageFromAnUnknownPrefixIsDropped()
@Test func zeroTimestampUsesNow()
@Test func channelMessageOnThePublicSlotStripsAKnownName()
@Test func channelMessageWithAnUnknownNameKeepsTextAndZeroSender()
@Test func channelMessageOnAnotherSlotIsDropped()
@Test func fetchedChannelWithThePublicSecretSetsTheSlot()
@Test func messagesBeforeFetchFinishAreHeldThenDeliveredInOrder()
//   beginLink, map DM -> [], map channel -> [], contact + channel applied, finishFetch: two messages in order
@Test func beginLinkHoldsAgainButKeepsContacts()
//   after a finished link: beginLink, DM -> []; finishFetch resolves it with no re-fetch
@Test func msgSentThenSendConfirmedRoutesAnAck()   // .routing(packetID: ack, result: .ack)
@Test func sendConfirmedWithoutMsgSentIsSilent()
@Test func expiredAckIsSilent()
@Test func replyOnlyFramesMapToNothing()   // .ok, .error(code: 1), .contact, .contactStart, .contactEnd, .channelInfo, .battery, .noMoreMsgs
@Test func datagramFramesMapToNothing()   // .channelDataRecv, .rawData: a neighbour's tunnel traffic is not a text message
@Test func connectionStatesMapExceptConnected()   // .connected: nil; the other four mapped
```
- [ ] **Step 2: Run to verify failure**
Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshcorekit/MeshtastifiedKit --filter MeshCoreEventMapperTests`
Expected: compile failure, `MeshCoreEventMapper` not found.
- [ ] **Step 3: Implement** in `MeshCoreEventMapper.swift`.
- [ ] **Step 4: Run (step a)**. Expected: 19 passed.
- [ ] **Step 5: Mutate in one batch (step b)**
No `.myIdentity`, name not stored; metadata regardless of firmware (also: not recording the code, so that test's second assertion fails); hex fallback removed; `lastAdvert` 0 maps to epoch; `.newAdvert` ignored; DMs use a `.publicChannel` conversation; unknown prefix uses a sentinel sender rather than dropping; `ts == 0` uses epoch; name strip removed; sentinel is `identity`; public-slot guard removed; `applyFetchedChannel` ignores the secret, leaving `publicSlotIndex` as last index; `finishFetch` reverses and then drops the second; `beginLink` clears contacts; `.msgSent` doesn't track, and `.sendConfirmed` routes anything (this pair fails three ack tests; `expireAck` no-op covers the third); `.contact` emits a node (also `.channelDataRecv` emits a message); `.connected` maps to `.connected`.
Expected: all 19 FAIL.
- [ ] **Step 6: Revert and re-run (step c)**. Expected: 19 passed.
- [ ] **Step 7: Commit in the worktree**
Subject `feat: MeshCoreEventMapper maps MeshCoreKit frames onto MeshEvent`. Paths: the two files above.

### Task 12: `MeshCoreSessionActor` becomes an adapter over `MeshCoreSession`

**Files (under `apps/Meshtastified-meshcorekit/MeshtastifiedKit`):**
- Modify (rewrite): `Sources/MeshDeviceClient/MeshCore/MeshCoreSessionActor.swift`
- Modify (clock setup only): `Tests/MeshDeviceClientTests/MeshCoreSessionTests.swift:16`, `MeshCoreSendTests.swift:16,70-71`, `MeshCoreReconnectTests.swift:32`, `MeshCoreRouterTests.swift:38`
- Test: `Tests/MeshDeviceClientTests/MeshCoreAdapterTests.swift`
**Interfaces:**
- Consumes: `MeshCoreSession` (tasks 5–8), `MeshCoreEventMapper` (task 11), `MeshEventRelay`, `MeshConnectError` (existing).
- Produces the unchanged surface `RadioRouter`, `MeshDeviceClient.make` and the 21 tests use:
  - `init(bluetooth:clock:now:nextPacketID:)`, `eventStream()`, `connectedDevices()`, `connect(id:) async throws`, `disconnect()`, `sendText(_:conversation:)`, the `RadioSession` conformance, `Data.hexString`.
  - Test seams, keeping their names: `setCommandTimeoutForTest(_:)`, `sendUnansweredCommandForTest()`, `sendUnansweredCommandCatchingForTest()`.
  - `scanStream` is deleted. No caller (the `scanStream` local in `ScanPoweredOnTests.swift:60` is unrelated). `connectedDevices` keeps using the FCB central directly, per Contract 1.

Adapter rules:

- `MeshCoreSession(central: bluetooth, clock: clock, appName: "mccli")`, with `commandTimeout` default 5 s, used as every `request` timeout.
- One pump, started by the first `connect(id:)`, iterates `session.events()` and awaits each event's handling, so events stay ordered and those arriving during the fetch wait in the stream. Only `.connection`, `.configured` and `.frame` are consumed. Typed `.channelData` and `.rawData` are ignored, as Contract 1's "either, never both" requires.
- `.connection(.connecting)` calls `mapper.beginLink()`. `.connection` is otherwise mapped; `nil` emits nothing.
- `.configured`: the fetch, in the old order. `request(getContacts, collecting: [0x02, 0x03], until: [0x04, 0x01])`; `getChannel(i)` for `0..<maxChannels`, `until: [0x12, 0x01]`; `getBattery`, `until: [0x0C, 0x01]`. Emit nodes, then `.deviceMetrics(identity:…, nil, nil, nil)`, then `finishFetch()`'s messages, then `.connectionState(.connected)`. An `01` on a channel index leaves that slot unset and continues.
- Fetch failure while the link is up (timeout, `01` on contacts): emit `.reconnecting`, and a spawned retry task sleeps on the injected clock (1 s doubling to 30 s, reset on success) and calls `session.connect(radio:)`. It must not be inline in the pump: `connect` waits for events only the pump handles. `.notConnected` from a lost link is not a failure; the session is already reconnecting. `disconnect()` cancels the retry.
- `connect(id:)`: subscribe to the **relay** before `session.connect`, mirror `MeshSessionActor.connect(id:)`'s `sawConnecting` watch (`MeshSessionActor.swift:78-101`). `.disconnected(reason: MeshCoreSession.firmwareTooOldReason)` throws `MeshCoreError.firmwareTooOld(Int(mapper.firmwareCode))`; other failures throw `MeshConnectError(reason:)`. The first attempt failing keeps retrying in the background, as Meshtastic's adapter does.
- `sendText`: keep `:479-516`'s structure over `request`. DM `until: [0x06, 0x01]`; `01` throws `.deviceError`. Channel `until: [0x00, 0x01]`; `.ok` emits `.routing(.ack)`, `.error` emits `.routing(.nak("channel send rejected"))`. Check `"\(selfName): \(text)".count <= 133`, then **send `text` alone** (bug B). Map kit errors: `.notConnected` → `.deviceError`; `.timedOut` → `.commandTimeout(expecting: until.min)`; `.frameTooLarge` → `.frameTooLarge`.
- When the pump sees `.msgSent`, schedule the ack expiry: `min(suggestedTimeoutMs, 30_000)` on `ContinuousClock`, calling `mapper.expireAck`. Silent on expiry, as today.
- [ ] **Step 1: Write the failing tests** `MeshCoreAdapterTests.swift`, nested in `CBMBackedTests`, using the same harness pattern as `MeshtasticAdapterTests.swift`
```swift
@Test func directSendCarriesOnlyTheTextAfterTheSixBytePrefix()   // bug A: device.receivedDirectTexts.last == "hi"
@Test func channelSendDoesNotPrependTheNodeNameBecauseFirmwareDoes()   // bug B: receivedChannelTexts.last == "hello"
@Test func connectedWaitsForContactsChannelsAndBattery()
//   receivedFrames first bytes: 01,16,06,0A,04, 1F×8, 14, and .connectionState(.connected) is after the last node and .deviceMetrics
@Test func connectToAnUnknownRadioThrows()   // MeshConnectError(reason: "radio not found")
@Test func queuedChannelTextIsNotDroppedBeforeSlotsLoad()   // queued "Alice: hi": .message text "hi" from Alice
@Test func neighboursChannelDataDoesNotStallConnectOrBecomeAMessage()
//   queued 0x1B, then pushed 0x1B: connect returns; no .message; a later text still arrives
@Test func fetchFailureRetriesInTheBackgroundThenConnects()
//   silentCommands [0x04], 80 ms timeout: connect throws MeshConnectError, relay .reconnecting; clear silentCommands: .connected
@Test func disconnectCancelsTheFetchRetry()   // same setup, disconnect: no further 0x01 written within 1.5 s
@Test func publicChannelMissingThrowsNoPublicChannel()   // slot 0 emptied: MeshCoreError.noPublicChannel
@Test func channelSendRejectedEmitsANak()   // errorReplies[0x03]=2: .routing(_, .nak("channel send rejected"))
@Test func directSendRadioErrorThrowsDeviceError()   // errorReplies[0x02]=3: .deviceError, promptly (under 1 s)
@Test func ackArrivingAtOnceAfterMsgSentIsRouted()   // confirmDelay .zero: .routing(ack, .ack)
@Test func identityIsTheRadiosRealKey()   // .myIdentity(.meshcore(selfKey)), through the firmware-layout mock frame
```
- [ ] **Step 2: Run to verify failure**
Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshcorekit/MeshtastifiedKit --filter MeshCoreAdapterTests`
Expected: at least `channelSendDoesNotPrepend…`, `neighboursChannelData…`, `fetchFailure…` and `directSendRadioError…` fail on the old actor. Note any that pass; they are mutation-checked below.
- [ ] **Step 3: Rewrite `MeshCoreSessionActor.swift`**
- [ ] **Step 4: Clock setup edits, nothing else**
`MeshCoreSessionTests.swift:16` and `MeshCoreSendTests.swift:16`: default `ContinuousClock()`. `MeshCoreSendTests.swift:70-71`: `let clock = ContinuousClock()`. `MeshCoreReconnectTests.swift:32`: `clock: ContinuousClock()`. `MeshCoreRouterTests.swift:38`: `clock: ContinuousClock()`. Reconnect now waits 1 s of real backoff, inside its 10 s cap.
- [ ] **Step 5: Run (step a)**
Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshcorekit/MeshtastifiedKit`
Expected: BASELINE − 35 + 19 + 13 passed. The 21 existing tests pass with **no assertion changed**. If one fails, diagnose the adapter. Do not edit the assertion.
- [ ] **Step 6: Mutate in one batch (step b)**
All 13 new tests and all 21 clock-edited tests must fail in this run. The clock-edited tests get their own mutations because the setup edit touched them. In `MeshCoreSessionActor.swift` unless noted:

| Mutation | Breaks |
|---|---|
| `radioType` returns `.meshtastic` | `reportsMeshcoreType` |
| Pump emits nothing for `.frame(.selfInfo)` | `connectRunsInitAndEmitsOrderedEvents`, `typedConnectMeshcoreDispatches…`, `connectWhileConnectedSwitchesSessions`, `identityIsTheRadiosRealKey` |
| `.connected` emitted at `.configured`, before the fetch | `connectedWaitsFor…` |
| `finishFetch()`'s events discarded | `offlineQueueDrainsOnConnect`, `queuedChannelTextIsNot…` |
| The `firmwareTooOldReason` end throws `MeshConnectError` | `firmwareTooOldFailsConnectAndSuppressesReconnect` |
| In `pods/MeshCoreKit` session: `0x83` ignored | `msgWaitingPushTriggersDrain` |
| `radioType` guard in `sendText` removed; meshtastic conversations return 1 | `sendTextThrowsMismatchForMeshtasticConversation`, `meshtasticConversationThrowsRadioMismatch`, `sendMeshtasticConversationOnMeshcoreSessionThrowsMismatch` |
| DM returns `expectedAck &+ 1` | `directSendReturnsAck…`, `msgWaitingDuringInFlightCommandDoesNotCorrupt` |
| Expiry emits `.routing(ack, .nak("timeout"))` | `directSendToUnreachableTimesOutAndEmitsNothing` |
| Channel `.ok` emits no routing | `channelSendOkSynthesizesRoutingAck` |
| 133 check removed | `channelSendTooLongThrows` |
| In mapper: name strip removed | `channelReceiveNameStripsKnownContact` |
| In mapper: sentinel is `identity` | `channelReceiveUnknownNameKeepsVerbatimWithSentinel` |
| `.timedOut` maps to `.deviceError` | `commandTimesOutWhenDeviceNeverAnswers` |
| In `pods/MeshCoreKit` session: teardown leaves the in-flight exchange | `disconnectMidCommandThrowsPromptly` |
| In `pods/MeshCoreKit` session: first backoff 60 s | `reconnectReRunsInitAndResumesEvents` |
| `MeshDeviceClient+Live.swift` `RadioRouter.connect`: `.meshtastic` case calls `meshcore.connect` | `typedConnectMeshtasticDispatches…` |
| In `pods/MeshCoreKit` frame: DM writes full key | `directSendCarriesOnly…` |
| Send `"\(selfName): \(text)"` | `channelSendDoesNotPrepend…` |
| `connect` uses `_ = await outcome.value` | `connectToAnUnknownRadioThrows` |
| In `pods/MeshCoreKit` session: `0x1B` removed from sync `until` | `neighboursChannelData…` |
| Fetch failure emits `.disconnected`, no retry | `fetchFailureRetries…` |
| `disconnect()` leaves the retry running | `disconnectCancelsTheFetchRetry` |
| `noPublicChannel` check sends to slot 0 instead | `publicChannelMissing…` |
| `.error` routes as `.ack` | `channelSendRejected…` |
| DM `until` loses `0x01` | `directSendRadioError…` |
| Ack registered by `sendText` after `request` returns, not from `.msgSent` | `ackArrivingAtOnce…` |

Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshcorekit/MeshtastifiedKit --filter "MeshCoreAdapterTests|MeshCoreSessionTests|MeshCoreSendTests|MeshCoreReconnectTests|MeshCoreRouterTests"`
Expected: all 34 FAIL. Some bounded tests take their full cap: allow a few minutes.
- [ ] **Step 7: Revert and re-run (step c)**
Run: `git -C /Users/ell/development/ios/pods/MeshCoreKit checkout -- Sources/MeshCoreKit/MeshCoreSession.swift Sources/MeshCoreKit/MeshCoreFrame.swift`
Revert the worktree edits by hand; the actor and mapper are uncommitted or changed in this task.
Run: `git -C /Users/ell/development/ios/pods/MeshCoreKit status --short`
Expected: no output.
Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshcorekit/MeshtastifiedKit`
Expected: BASELINE − 35 + 32.
- [ ] **Step 8: Build the app**
Run: `xcodebuild -project /Users/ell/development/ios/apps/Meshtastified-meshcorekit/Meshtastified.xcodeproj -scheme Meshtastified -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`
- [ ] **Step 9: Commit in the worktree**
Subject `refactor: MeshCoreSessionActor is an adapter over MeshCoreKit's MeshCoreSession`. Body names: `SELF_INFO` now correct on real radios, the DM frame, channel name no longer doubled, `0x1B` no longer stalls connect, contacts no longer race a drain, set time goes through the slot, initial failures retry in the background. Paths: the actor, the mapper only if changed, the four clock-edited tests, `MeshCoreAdapterTests.swift`.

### Task 13: Verify on the branches, and stop

**Files:** none changed. Nothing merges: spec §6 says lanes merge only when the user says so. The worktree stays, because lanes C and D and the user need it.
- [ ] **Step 1: Confirm branches and clean state**
Run: `git -C /Users/ell/development/ios/pods/MeshCoreKit branch --show-current`
Run: `git -C /Users/ell/development/ios/apps/Meshtastified-meshcorekit branch --show-current`
Expected: `meshcorekit` for both.
Run: `git -C /Users/ell/development/ios/pods/MeshCoreKit status --short`
Expected: no output.
Run: `git -C /Users/ell/development/ios/apps/Meshtastified-meshcorekit status --short`
Expected: only untracked build artefacts.
- [ ] **Step 2: Whole suites**
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshCoreKit`
Expected: KIT passed.
Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshcorekit/MeshtastifiedKit`
Expected: BASELINE − 35 + 32.
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit`
Expected: green. This lane did not touch it, and spec §1 requires Meshtastic behaviour unchanged.
- [ ] **Step 3: Confirm nothing landed on `main`, nothing was pushed, and every commit has its trailer**
Run: `git -C /Users/ell/development/ios/apps/Meshtastified log -1 --format=%h main`
Expected: the commit the worktree started from (`64a928d` at planning time).
Run: `git -C /Users/ell/development/ios/pods/MeshCoreKit log --oneline main`
Expected: one line, the empty root.
Run: `git -C /Users/ell/development/ios/pods/MeshCoreKit remote`
Expected: no output.
Run: `git -C /Users/ell/development/ios/pods/MeshCoreKit log --format='%h %(trailers:key=Claude-Session,valueonly)' meshcorekit`
Run: `git -C /Users/ell/development/ios/apps/Meshtastified-meshcorekit log -4 --format='%h %(trailers:key=Claude-Session,valueonly)'`
Expected: each line ends with the session URL.
- [ ] **Step 4: Report**
Give KIT, BASELINE and the final app total; both branch names; any test or mutation that surprised you; and hardware item 8 of spec §8 E as still open: nothing here has run on a radio.

## Self-review (done while writing)

**Spec coverage:** repo, package, floors, worktree: task 1. `SELF_INFO`: task 2. Contract 1: tasks 1, 5–9. Reliability parity: lessons table, tasks 5, 7, 8. 173 B limit, `request`, `sendChannelData`, slots: task 7. Drain and "never stall": tasks 6, 7. Handshake and both firmware floors: tasks 5, 7, 8. §6 keep list and transport-only kit: tasks 11, 12. `SharedScanner`: unchanged, mutated and re-tested in task 10. Mock re-export: task 10. §8 A, including the `meshcore_py` check: tasks 1–4, 6, 7. Established defects: `syncDrain` stall (6), `setDeviceTime` bypass (5), contact race (7), dead `scanStream` (12).

**Type consistency checked:** `.selfInfo(publicKey:name:frequencyKHz:bandwidthHz:spreadingFactor:codingRate:)`, `.error(code:)`, `.channelDataRecv(channelIndex:dataType:payload:)`, `.rawData(payload:)`, `MeshCoreFrameError.decodeFailed`, the `MockMeshCoreDevice` members, `exchange(_:collecting:until:timeout:)`, `MeshCoreEventMapper`'s members.

**Not verified while planning:** nothing was compiled. Test counts assume the lists above; adjust the expected totals if a task legitimately adds one. Only three frame types were actually driven through the parser; the rest of the field table comes from reading `reader.py`. Bugs A and B come from reading firmware, and have not been seen on a radio.
