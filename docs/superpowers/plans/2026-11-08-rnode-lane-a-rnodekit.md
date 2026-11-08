# RNode Lane A: RNodeKit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `pods/RNodeKit`, a new package exposing exactly Contract 1: a KISS codec and streaming decoder, the RNode command set, an `RNodeSession` actor over FCB that detects, configures and validates the radio, sends and receives whole packets and survives pairing, a name-filtering scanner, and `MockRNodeDevice`, a CoreBluetoothMock radio rebuilt from firmware source and checked against RNS's own parser.

**Architecture:** `RNodeKit` is transport only. `KISS`/`KISSDecoder` are pure; `RNodeSession` is MeshCoreKit's session shape (epoch guard, one write slot, powered-on gate, retrieve-only reconnect, `EventHub`) with the KISS handshake of spec §5.2 and the pairing rules of §5.5. `RNodeMock` reproduces the firmware's serial callback over NUS. A dev-time generator drives RNS's `RNodeInterface` to produce byte fixtures in both directions.

**Tech Stack:** Swift 6.3 tools / Swift 6 language mode, FCB (`FCBComposable.BluetoothCentralClient`), CoreBluetoothMock, swift-composable-architecture (test-only: `TestClock`, `LockIsolated`), Swift Testing, Python 3 in conda env `rns` with `-I` for the fixture generator.

**Spec:** `/Users/ell/development/ios/pods/ReTiCA-worktrees/meshcore-interface/docs/superpowers/specs/2026-11-08-rnode-ble-interface-design.md`: Contract 1, §2, §5.1–§5.5, §8 A. The shape to port is MeshCoreKit (`/Users/ell/development/ios/pods/MeshCoreKit`, branch `meshcorekit` at `4e40514`); its plan is `2026-11-07-meshcore-lane-a-meshcorekit.md` in the same `plans/` directory.

## Contract issues

None is unworkable.

1. **FCB already surfaces pairing errors** (spec §2), so this lane plans no FCB change. If a test in Task 7 shows CoreBluetoothMock or FCB rewriting an injected `CBATTError`/`CBError` into something the classifier can't recognise, **stop and ask** before touching FCB. Don't work around it by matching error text.
2. **`RNodeRadioInfo.name`** comes from FCB's `Peripheral.name` after `retrievePeripherals`. It may be nil on a radio iOS has never scanned; the contract already makes it optional.
3. **Public API beyond Contract 1's listing:** `RNodeCommand`'s byte constants, `KISSFrame`, and the mock's API. `RNodeSession.handshakeTimeout`, `.replyTimeout`, `.notifyTimeout`, `.partialFrameTimeout` are `static let` and internal.

## Global Constraints

- **Paths.** `K` = `/Users/ell/development/ios/pods/RNodeKit` (new repo). Temp files: `/tmp/ReTiCaMsgr/lane-rnode-a/`. Pinned sources: `/tmp/ReTiCaMsgr/rnode-pins/`. Expand shorthand to full paths in every command. Don't `cd`; use `--package-path` and `git -C`.
- **Platforms** `.iOS(.v17), .macOS(.v13), .macCatalyst(.v17)`. `NSLock.withLock` (macOS 14+) must not appear.
- **Dependencies:** `.package(path: "../FCB")`, CoreBluetoothMock (mock target and tests only), TCA (test target only). No dependency on ReTiCA, MeshCoreKit or MeshtasticKit.
- **Public API** is Contract 1 verbatim plus Contract issue 3. Sessions connect only via `retrievePeripherals` then `connect`, never scan.
- **Spec values (verbatim).** Service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`, RX `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`, TX `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`. Name prefix `"RNode "`. FEND `C0`, FESC `DB`, TFEND `DC`, TFESC `DD`. Detect query `C0 08 73 C0 50 00 C0 48 00 C0 49 00 C0`. Leave `C0 0A FF C0`. HW MTU 508. Firmware floor 1.52. Frequency tolerance ±100 Hz. RSSI = byte − 157. SNR = Int8 × 0.25. Timeouts: reply 5 s, handshake 30 s (from `setNotify` returning), `setNotify` 60 s, partial frame 1250 ms, leave ≤ 1 s. Retry delays: first 0 s, then 1, 2, 4 … capped 30 s. Chunk size `min(maximumWriteValueLength(.withoutResponse), 512)`, at least 20.
- **Reason strings:** `nil`, `"radio not found"`, `"unauthorized"`, `"unsupported"`, `RNodeSession.firmwareTooOldReason` (`"firmware too old"`), `.pairingRequiredReason` (`"pairing required"`), `.pairingRemovedReason` (`"pairing removed"`), `.configurationRejectedReason` (`"configuration rejected"`).
- **Firmware source wins** over RNS where they differ on what the radio sends; RNS wins on what the host sends. Mock builders cite `FW/<file>:<line>` from the pinned commit in comments. No firmware or RNS code is copied, only behaviour.
- **Never** use `ImmediateClock` with a session that can reach a handshake: it fires the 30 s timeout at once. Use `ContinuousClock` or `TestClock`.
- **Tests:** Swift Testing. Anything touching CBM's process-global simulation nests in `extension CBMBackedTests` (`@Suite(.serialized)`) as `@Suite @MainActor`, as MeshCoreKit's `Tests/MeshCoreKitTests/Support/CBMSupport.swift` does. Session, mock and scanner tests use the live FCB client over CBM (`BluetoothCentralClient.mocked()`); closure-built centrals only for adapter authorization, gated connects, backoff timing and error injection CBM can't do.
- **Ownership.** Never edit FCB, MeshCoreKit, MeshtasticKit, ReTiCA or ReTiCAMsgr. An FCB defect: stop and ask.
- **Shell (user rule).** One command per line, per Bash call. No `|`, `&&`, `||`, `;`, `$(...)`, backticks, `xargs`, heredocs into interpreters, or inline scripts. Scripts go in files. Redirecting one command's output to a log is allowed. Write files, including commit messages, with the Write tool.
- **Test command.** `swift test --package-path /Users/ell/development/ios/pods/RNodeKit --filter <Suite> > /tmp/ReTiCaMsgr/lane-rnode-a/<name>.log 2>&1`, timeout 600000 ms. The log ends `Test run with N tests ... passed` or `... failed`.
- **Test verification (user rule), every task with tests:** (a) run the task's suites, all pass. (b) `cp` each production file the mutation table touches to `/tmp/ReTiCaMsgr/lane-rnode-a/<name>.orig`, apply the **whole batch**, run once, and confirm **every** new test fails. A second batch appears only where mutations mask each other. Any test the table doesn't name gets the obvious mutation (delete the guard, change the pinned constant) in the same batch. If a test survives, fix it and restart at (a). (c) Restore with `cp`, `git -C /Users/ell/development/ios/pods/RNodeKit diff --stat` lists only intended files, run again, all pass. Only then commit. Never `git checkout --` uncommitted work.
- **Branches.** All work on branch `rnodekit`. `main` holds only an empty root commit; a person merges `rnodekit` to `main` later (lane D gates on it). No remote, no pushing.
- **Commits.** Message via the Write tool to `/tmp/ReTiCaMsgr/lane-rnode-a/msg-tN.txt`, then `git -C /Users/ell/development/ios/pods/RNodeKit commit -F <file>`. End with the attribution lines from the executing session's system reminder, at column zero. Stage explicit paths only; never `.build/`, `.swiftpm/`, `Package.resolved`.

**Lessons carried from MeshCoreKit and MeshtasticKit**, each pinned by a test below:

| Lesson | Rule here | Test |
|---|---|---|
| FCB holds one write continuation per characteristic; a second overwrites it | One FIFO write slot for every chunk of every frame | T6 `concurrentSendsAllComplete` |
| Commands before `.poweredOn` are dropped; `retrievePeripherals` returns `[]` | Powered-on gate before retrieve | T5 `connectWhilePoweredOffWaitsThenConnects` |
| iOS reports a power cycle as a state change only | Disconnect watch treats non-`.poweredOn` as link loss | T7 `powerCycleWhileConnectedReconnects` |
| FCB continuations ignore cancellation; FCB events are global | Epoch check after every await; filter on own peripheral | T7 `anotherPeripheralsDisconnectIsIgnored`, `disconnectDuringHandshakeStaysDisconnected` |
| Actor-hop subscription loses a connect's first events | `EventHub` registers synchronously and replays state | T5 `eventsReplayDisconnectedBeforeAnyConnect` |

## Review Focus

1. **A KISS frame is split across notifications at an escape byte** (`DB` in one notification, `DC` in the next), or two frames arrive in one notification. Expected: frames decode exactly once, in order. → T2 `everySplitOfAFrameSequenceDecodesTheSame`, `escapeSplitAcrossFeedsDecodes`.
2. **The radio clamps TX power** (user asks 30 dBm, SX1262 sets 22). Expected: no radio-on, a `.configurationRejected` naming 30 and 22, terminal reason, and no retry loop. → T5 `clampedTXPowerIsRejectedBeforeTheRadioTurnsOn`, `aRejectedConfigurationDoesNotRetry`.
3. **The user doesn't put the RNode in pairing mode.** Expected: one automatic retry, then terminal `pairingRequiredReason`, never a third subscribe. → T7 `aSecondPairingFailureIsTerminal`, `pairingFailuresNeverSubscribeAThirdTime`.
4. **The firmware drops the link right after a successful pairing**, either mid-handshake or just after `.connected`. Expected: reconnect with no delay, configured again. → T7 `firstLinkLossMidHandshakeRetriesAtOnce`, `firstLinkLossAfterConnectedRetriesAtOnce`.
5. **A packet's stats arrive, but the data frame is lost** (link drop between them). Expected: the next packet after reconnect carries no stale RSSI/SNR. → T6 `staleSignalIsNotAttachedAfterAReconnect`.

## File structure

**New repo `K`:** `Package.swift`, `.gitignore`, `scripts/SOURCES.md`, `scripts/rns-fixtures.py`. `Sources/RNodeKit/`: `RNodeGATT.swift`, `KISS.swift` (escape, frame, `KISSFrame`, `KISSDecoder`), `RNodeCommand.swift`, `RNodeTypes.swift` (Contract 1 value types), `EventHub.swift`, `RNodeSession.swift`, `RNodeSession+Handshake.swift`, `RNodeSession+Link.swift` (reconnect, pairing classification), `RNodeScanner.swift`. `Sources/RNodeMock/MockRNodeDevice.swift`. `Tests/RNodeKitTests/`: `PublicTypesTests`, `KISSTests`, `KISSDecoderTests`, `RNSCrossCheckTests`, `Fixtures/`, `Support/CBMSupport.swift`, `Support/SessionSupport.swift`, `MockRadioTests`, `SessionHandshakeTests`, `SessionTrafficTests`, `SessionLinkTests`, `ScannerTests`.

---

### Task 1: Repo, pinned sources, GATT, KISS encoder, commands, public types

**Files:**
- Create: `K/Package.swift`, `K/.gitignore`, `K/scripts/SOURCES.md`, `Sources/RNodeKit/RNodeGATT.swift`, `KISS.swift` (encoder half), `RNodeCommand.swift`, `RNodeTypes.swift`, placeholder `Sources/RNodeMock/MockRNodeDevice.swift`
- Test: `Tests/RNodeKitTests/PublicTypesTests.swift`, `Tests/RNodeKitTests/KISSTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: Contract 1's `RNodeGATT`, `KISS` (`escape`, `frame`), `KISSFrame`, `RNodeCommand` (builders and constants), `RNodeRadioConfig`, `RNodeRadioInfo`, `RNodeChannelStats`, `RNodeParameterMismatch`, `RNodeConnectionState`, `RNodeAdapterUnavailable`, `RNodeSessionError`, `RNodeEvent`, `DiscoveredRNode`, each `Equatable, Sendable` with a public memberwise `init`. `RNodeCommand` constants: `data 0x00, frequency 0x01, bandwidth 0x02, txPower 0x03, spreadingFactor 0x04, codingRate 0x05, radioState 0x06, detect 0x08, leaveCommand 0x0A, statRSSI 0x23, statSNR 0x24, statChannel 0x25, platform 0x48, mcu 0x49, firmwareVersion 0x50, reset 0x55, error 0x90, detectRequest 0x73, detectResponse 0x46, resetByte 0xF8`.

- [ ] **Step 1: Repo on a branch from the start.**
  - `mkdir -p /Users/ell/development/ios/pods/RNodeKit`
  - `mkdir -p /tmp/ReTiCaMsgr/lane-rnode-a`
  - `git init -b main /Users/ell/development/ios/pods/RNodeKit`
  - Write `msg-t1a.txt` with subject `chore: empty root commit`; `git -C /Users/ell/development/ios/pods/RNodeKit commit --allow-empty -F /tmp/ReTiCaMsgr/lane-rnode-a/msg-t1a.txt`
  - `git -C /Users/ell/development/ios/pods/RNodeKit switch -c rnodekit`
- [ ] **Step 2: Pin the sources (spec §2).**
  - `mkdir -p /tmp/ReTiCaMsgr/rnode-pins`
  - `git clone https://github.com/markqvist/Reticulum /tmp/ReTiCaMsgr/rnode-pins/Reticulum`
  - `git clone https://github.com/markqvist/RNode_Firmware /tmp/ReTiCaMsgr/rnode-pins/RNode_Firmware`
  - `git -C /tmp/ReTiCaMsgr/rnode-pins/Reticulum rev-parse HEAD`, and the same for the firmware.
  - `shasum -a 256 /tmp/ReTiCaMsgr/rnode-pins/Reticulum/RNS/Interfaces/RNodeInterface.py`
  - Check each spec §2 citation against the clones with Read (`PY:41-44, 102-106, 112-113, 119-120, 309-325, 388, 491-499, 668-705, 712-728, 761-784, 1077-1098`; `FW/RNode_Firmware.ino:450-459, 508-557, 712, 716-751, 765-1008`; `FW/Utilities.h:837-1216`; `FW/Bluetooth.h:44, 139, 260, 274-290, 435-460`; `FW/BLESerial.cpp:153-160`; `FW/Config.h:22-23, 59-60`). If a line moved, record the new line. If behaviour changed, stop and report.
  - Write `K/scripts/SOURCES.md`: both URLs, both SHAs, the `RNodeInterface.py` sha256, the firmware version from `Config.h`, the date, and the corrected line map.
- [ ] **Step 3: `Package.swift`, `.gitignore`.** Copy `pods/MeshCoreKit/Package.swift` with: name `RNodeKit`; products `RNodeKit`, `RNodeMock`; targets `RNodeKit` (FCBComposable), `RNodeMock` (`RNodeKit`, CoreBluetoothMock), `RNodeKitTests` (both, FCBComposable, CoreBluetoothMock, ComposableArchitecture, `exclude: ["Fixtures"]`). `.gitignore`: `.build/`, `.swiftpm/`, `Package.resolved`, `.DS_Store`.
- [ ] **Step 4: Write the failing tests.**

```swift
// PublicTypesTests
onlyUnauthorizedAndUnsupportedAreTerminal   // true for those two; false for .poweredOff, .other(nil)
gattUUIDsMatchTheFirmware                   // the three UUIDs above; namePrefix == "RNode "
everyValueTypeInitStoresEveryField          // RNodeRadioConfig, RNodeRadioInfo, RNodeChannelStats, RNodeParameterMismatch, DiscoveredRNode
reasonConstantsAreTheSpecStrings            // the four constants verbatim

// KISSTests (bytes as hex)
escapeLeavesPlainBytesAlone                 // 01 02 03 → 01 02 03
escapeReplacesFESCBeforeFEND                // C0 DB → DB DC DB DD
frameWrapsCommandAndEscapedPayload          // frame(0x00, C0 01) == C0 00 DB DC 01 C0
detectQueryIsRNSsSingleWrite                // == C0 08 73 C0 50 00 C0 48 00 C0 49 00 C0
setFrequencyIsBigEndianAndEscaped           // 868_100_000 == C0 01 33 BE 27 A0 C0; 0xC0DB0001 == C0 01 DB DC DB DD 00 01 C0
setBandwidthIsBigEndianAndEscaped           // 62_500 == C0 02 00 00 F4 24 C0
singleByteSettersAreUnescapedLikeRNS        // setTXPower(17) == C0 03 11 C0; setSpreadingFactor(8) == C0 04 08 C0; setCodingRate(6) == C0 05 06 C0
radioStateFrames                            // on: C0 06 01 C0; off: C0 06 00 C0
leaveFrame                                  // C0 0A FF C0
dataFrameEscapesThePacket                   // data(DB C0 00) == C0 00 DB DD DB DC 00 C0
```

- [ ] **Step 5: Run to see them fail.** Test command, `--filter PublicTypesTests --filter KISSTests`, log `t1-red.log`. Expected: compile errors.
- [ ] **Step 6: Implement.** `setTXPower`, `setSpreadingFactor`, `setCodingRate` and `setRadioState` write their byte raw, as RNS does (`PY:599-618, 644-647`); frequency, bandwidth and data escape.
- [ ] **Step 7: Green,** log `t1-green.log`.
- [ ] **Step 8: Mutation batch.**

| # | Mutation | Must fail |
|---|---|---|
| A1 | `escape` replaces FEND before FESC | `escapeReplacesFESCBeforeFEND`, `setFrequencyIsBigEndianAndEscaped`, `dataFrameEscapesThePacket` |
| A2 | `frame` omits the trailing FEND | `frameWrapsCommandAndEscapedPayload`, `radioStateFrames`, `leaveFrame` |
| A3 | frequency little-endian | `setFrequencyIsBigEndianAndEscaped` |
| A4 | bandwidth uses the frequency command byte | `setBandwidthIsBigEndianAndEscaped` |
| A5 | detect query drops the MCU query | `detectQueryIsRNSsSingleWrite` |
| A6 | `isTerminal` always false; swap two fields in each init; swap RX and TX UUIDs; `pairingRemovedReason = "pairing required"` | the four `PublicTypesTests` |
| A7 | single-byte setters escape their byte and TX power uses `0x04` | `singleByteSettersAreUnescapedLikeRNS` |

- [ ] **Step 9: Restore, re-run, all pass. Step 10: Commit** `Package.swift .gitignore scripts/SOURCES.md Sources Tests`. Subject: `feat: RNodeKit package with KISS framing, RNode commands and Contract 1 types`.

---

### Task 2: Streaming KISS decoder

**Files:**
- Modify: `Sources/RNodeKit/KISS.swift`
- Test: `Tests/RNodeKitTests/KISSDecoderTests.swift`

**Interfaces:**
- Consumes: `KISS`, `KISSFrame` (T1).
- Produces: `KISSDecoder` per Contract 1 and spec §5.1: `maxPayload = 508`, `feed(_:) -> [KISSFrame]`, `hasPartialFrame`, `discardPartialFrame()`, `oversizeDropped`.

- [ ] **Step 1: Write the failing tests.** `seq` = `frame(0x23, [0x5A]) + frame(0x24, [0x18]) + data(DB C0 01 … 200 B) + frame(0x06, [0x01])`.

```swift
decodesOneFrame                                  // feed(C0 06 01 C0) == [KISSFrame(0x06, [01])]
decodesTwoFramesFromOneFeed                      // two frames, in order
everySplitOfAFrameSequenceDecodesTheSame         // @Test(arguments: 1...seq.count-1) split at i into two feeds: same 4 frames
byteAtATimeDecodesTheSame                        // seq fed one byte per feed: same 4 frames
escapeSplitAcrossFeedsDecodes                    // feed(C0 00 DB), feed(DC 01 C0) == [(0x00, [C0 01])]
unescapesEveryCommandsPayload                    // frame(0x01, 0xC0DB0001 BE) → payload C0 DB 00 01
backToBackFENDsYieldNothing                      // C0 C0 C0 06 01 C0 == [(0x06, [01])]
leadingNoiseBeforeTheFirstFENDIsIgnored          // 11 22 C0 06 01 C0 == [(0x06, [01])]
fescFollowedByAnotherByteKeepsThatByte           // C0 00 DB 41 C0 == [(0x00, [41])]   (RNS behaviour)
aPayloadOf508BytesIsDelivered                    // data of 508 B: one frame, count 508
aPayloadOver508BytesIsDroppedWhole               // data of 509 B: [], oversizeDropped == 1
theFrameAfterAnOversizeOneDecodes                // 509 B frame then C0 06 01 C0: [(0x06, [01])]
partialFrameIsReported                           // feed(C0 00 01): hasPartialFrame
discardingAPartialFrameDropsItsBytes             // feed(C0 00 01), discard, feed(02 C0) == []; then a full frame decodes
completedFramesLeaveNoPartial                    // after seq: !hasPartialFrame
emptyDataFrameIsReturned                         // C0 00 C0 == [(0x00, [])]   (the session drops it, spec §5.1)
```

- [ ] **Step 2: Fail,** `--filter KISSDecoderTests`, log `t2-red.log`. **Step 3: Implement** RNS's state machine (`PY:761-784`) with spec §5.1's two differences. Escape state survives across `feed` calls; the oversize flag resets at the next FEND. **Step 4: Green,** log `t2-green.log`.
- [ ] **Step 5: Mutation batch.**

| # | Mutation | Must fail |
|---|---|---|
| B1 | escape state reset at the start of each `feed` | `escapeSplitAcrossFeedsDecodes`, `everySplitOfAFrameSequenceDecodesTheSame`, `byteAtATimeDecodesTheSame` |
| B2 | only command `0x00` is unescaped | `unescapesEveryCommandsPayload` |
| B3 | oversize truncates to 508 and delivers (RNS behaviour) | `aPayloadOver508BytesIsDroppedWhole` |
| B4 | limit `>= 508` treated as oversize | `aPayloadOf508BytesIsDelivered` |
| B5 | oversize flag not reset at the next FEND | `theFrameAfterAnOversizeOneDecodes` |
| B6 | FEND with no command byte emits an empty frame with command `0xFE` | `backToBackFENDsYieldNothing` |
| B7 | `discardPartialFrame` does nothing | `discardingAPartialFrameDropsItsBytes` |
| B8 | FESC + other byte drops the byte | `fescFollowedByAnotherByteKeepsThatByte` |

- [ ] **Step 6: Restore, re-run, all pass. Step 7: Commit.** Subject: `feat: streaming KISS decoder that drops oversize frames whole`.

---

### Task 3: Outbound cross-check against RNS

**Files:**
- Create: `K/scripts/rns-fixtures.py`, `Tests/RNodeKitTests/Fixtures/rns-outbound.json`, `Tests/RNodeKitTests/RNSCrossCheckTests.swift`

**Interfaces:**
- Consumes: T1 builders.
- Produces: `RNSFixtures.load(_ name: String) -> [String: Any]` test helper (`Bundle.module` is unavailable because `Fixtures` is excluded; read via `#filePath`, as MeshCoreKit's `ParserCrossCheckTests` does).

**The generator** takes the pinned `RNodeInterface.py` path as its first argument, checks its sha256 against `scripts/SOURCES.md`, and loads it with `importlib.util.spec_from_file_location` (RNS's other modules come from the conda env; record `RNS.__version__` in the output). Its header comment states the URL, the SHA, that it runs Reticulum-licensed code at dev time only, and that the repo holds none of that code. Subcommand `outbound` writes `rns-outbound.json`: `KISS.escape` for `[]`, `[C0]`, `[DB]`, `[DB C0]`, `[C0 DB C0 DB]`, 0–255 in order; and, from a radio-less `RNodeInterface.__new__(RNodeInterface)` whose `serial` records writes (`write` returns `len`), the bytes of `detect()`, `leave()`, `setFrequency()` for 137_000_000, 433_775_000, 868_100_000, 915_000_000, 3_000_000_000 and 0xC0DB0001, `setBandwidth()` for 7_800, 62_500, 125_000, 1_625_000, `setTXPower()` for 0, 17, 22, 37, `setSpreadingFactor()` 5…12, `setCodingRate()` 5…8, `setRadioState(1)`, `setRadioState(0)`, and `process_outgoing()` (with `online`, `interface_ready` true, `flow_control` false, `id_callsign` None, `first_tx` None, `txb` 0) for packets of 1, 254, 255, 500, 508 bytes of a fixed pattern including `C0` and `DB`. `AttributeError` on first run means set that attribute; never edit RNS.

- [ ] **Step 1: Write the generator.** Run (timeout 300000): `conda run -n rns python -I -B /Users/ell/development/ios/pods/RNodeKit/scripts/rns-fixtures.py /tmp/ReTiCaMsgr/rnode-pins/Reticulum/RNS/Interfaces/RNodeInterface.py outbound /Users/ell/development/ios/pods/RNodeKit/Tests/RNodeKitTests/Fixtures/rns-outbound.json`. If env `rns` is missing, stop and report.
- [ ] **Step 2: Write the tests.**

```swift
escapeMatchesRNSForEveryCase               // each row: KISS.escape(input) == rns
detectAndLeaveMatchRNS
setFrequencyMatchesRNSForEveryRow
setBandwidthMatchesRNSForEveryRow
singleByteSettersMatchRNSForEveryRow       // TX power, SF, CR, radio state
dataFramesMatchRNSForEverySize             // RNodeCommand.data(p) == process_outgoing bytes
fixtureRecordsThePinnedSource              // json["sha256"] equals the value in scripts/SOURCES.md
```

- [ ] **Step 3: Verify (a), (b), (c).** Don't regenerate under mutation. Mutations: escape order swapped; frequency little-endian; data frame command `0x01`; TX power escaped. Each named test fails; `fixtureRecordsThePinnedSource` fails when the expected sha in the test is edited by one character.
- [ ] **Step 4: Commit** the script, fixture and test. Subject: `test: KISS and command bytes match RNS's RNodeInterface`.

---

### Task 4: `MockRNodeDevice` from firmware source, checked by RNS's parser

**Files:**
- Modify: `Sources/RNodeMock/MockRNodeDevice.swift`, `K/scripts/rns-fixtures.py` (subcommand `parse`)
- Create: `Tests/RNodeKitTests/Support/CBMSupport.swift`, `MockRadioTests.swift`, `Fixtures/mock-replies.json`, `Fixtures/mock-replies-parsed.json`

**Interfaces:**
- Consumes: T1, T2.
- Produces:

```swift
public final class MockRNodeDevice: @unchecked Sendable {
    public init(name: String = "RNode 1A2B", firmware: (major: UInt8, minor: UInt8) = (1, 0x56),
                platform: UInt8 = 0x80, mcu: UInt8 = 0x81, maxTXPower: UInt8 = 22,
                rxProperties: CBCharacteristicProperties = [.write])
    public func makeSpec(identifier: UUID) -> CBMPeripheralSpec
    // Radio state, as the firmware holds it
    public var frequencyHz: UInt32 { get }; var bandwidthHz: UInt32 { get }; var txPowerDBm: UInt8 { get }
    public var spreadingFactor: UInt8 { get }; var codingRate: UInt8 { get }; var radioOnline: Bool { get }
    public var frequencyOffsetHz: Int32 { get set }      // added to the frequency echo
    public var radioStartFails: Bool { get set }          // RADIO_STATE 01 → ERROR 01 and state 00 (FW:512-518)
    public var doubleRadioStateEcho: Bool { get set }     // default true (FW:537, 929-930)
    public var silentCommands: Set<UInt8> { get set }     // no echo for these
    public var notificationChunk: Int { get set }         // split outgoing bytes into notifications of this size; default 512
    // Traffic
    public var receivedWrites: [Data] { get }             // raw, in order
    public var receivedFrames: [KISSFrame] { get }        // decoded host frames
    public var receivedPackets: [Data] { get }            // DATA payloads
    public var lastWriteTypes: [CBCharacteristicWriteType] { get }
    public func injectPacket(_ packet: Data, rssiByte: UInt8? = 0x5A, snrByte: UInt8? = 0x18)   // RSSI, SNR, DATA (FW:450-459)
    public func injectChannelStats(_ payload: Data)       // 11 bytes, CHTM (FW/Utilities.h:959-983)
    public func injectError(_ code: UInt8)
    public func injectReset()                             // 55 F8
    public func injectRawBytes(_ bytes: Data)
    // Link and security
    public var setNotifyErrors: [any Error] { get set }   // popped one per subscribe attempt; empty → success
    public var subscribeCount: Int { get }
    public var disconnectAfterSubscribe: Duration? { get set }   // one-shot: post-pairing drop
    public var disconnectAfterDetect: Bool { get set }    // one-shot: drop after answering detect
    public var simulateDisconnect: (_ error: (any Error)?) -> Void { get }
}
```

**Behaviour, citing firmware lines in comments:** decode host writes with `KISSDecoder`; `DETECT 73` → `C0 08 46 C0`; `FW_VERSION`, `PLATFORM`, `MCU` → their single-byte replies (`FW/Utilities.h:1182-1216`); frequency and bandwidth: 4 escaped bytes, 0 queries, else set and echo (`FW/RNode_Firmware.ino:811-856`); TX power clamped to `maxTXPower` (`:857-881`); SF clamped 5–12, CR 5–8 (`:882-905`); `RADIO_STATE` `00`/`01`/`FF` (`:918-931`) with `doubleRadioStateEcho`; `LEAVE FF` records and does nothing else; `DATA` recorded. Single-byte echoes unescaped, multi-byte escaped, as the firmware writes them. Replies go out through `notificationChunk`-sized notifications.

- [ ] **Step 1: Emitter and generator `parse`.** `MockReplyEmitter.writeRepliesForTheReferenceParser`, enabled only when `RETICA_EMIT_RNODE_REPLIES == "1"`, drives a mock (no BLE: call its internal `reply(to:)` directly, which `@testable` reaches) with the detect query, every setter row from T3, a 508-byte injected packet with stats, a CHTM payload `00 64 00 32 03 E8 01 F4 3C 28 FF`, and `injectError(0x02)`, and writes the concatenated reply bytes to `Fixtures/mock-replies.json`. Run: `env RETICA_EMIT_RNODE_REPLIES=1 swift test --package-path /Users/ell/development/ios/pods/RNodeKit --filter MockReplyEmitter`. The generator's `parse` subcommand feeds those bytes to RNS's own `readLoop` through a fake serial (`is_open` false after the last byte, `in_waiting`, `read(1)`) on a radio-less instance with `detached = True`, `use_tcp = False`, `id_interval = None`, an owner whose `inbound(data, iface)` records packets, catching the `IOError` the TXFAILED error raises, and writes `r_frequency`, `r_bandwidth`, `r_txpower`, `r_sf`, `r_cr`, `r_state`, `detected`, `maj_version`, `min_version`, `platform`, `mcu`, `r_stat_rssi`, `r_stat_snr`, the CHTM fields RNS stores, and the delivered packets to `mock-replies-parsed.json`. Run: `conda run -n rns python -I -B /Users/ell/development/ios/pods/RNodeKit/scripts/rns-fixtures.py /tmp/ReTiCaMsgr/rnode-pins/Reticulum/RNS/Interfaces/RNodeInterface.py parse /Users/ell/development/ios/pods/RNodeKit/Tests/RNodeKitTests/Fixtures/mock-replies.json /Users/ell/development/ios/pods/RNodeKit/Tests/RNodeKitTests/Fixtures/mock-replies-parsed.json`. If `readLoop` needs anything beyond attributes, stop and report.
- [ ] **Step 2: Write the failing tests** (`MockRadioTests`, nested CBM suite; parse tests are plain):

```swift
rnsParsesTheMockDetectReply                   // detected, version 1.86, platform 0x80, mcu 0x81
rnsParsesEveryMockParameterEcho               // r_* equal the clamped values for every T3 row
rnsReadsTheMockPacketAndItsSignal             // packet delivered, r_stat_rssi == 0x5A - 157, r_stat_snr == 6.0
rnsReadsTheMockChannelStats
committedRepliesAreWhatTheMockEmitsToday      // load() == current(), message "regenerate: emitter, then generator"
mockClampsTXPowerToItsMaximum                 // setTXPower(30) → echo 22
mockClampsSpreadingFactorAndCodingRate        // SF 13 → 12, CR 4 → 5
mockAddsItsFrequencyOffset                    // offset 150: echo == requested + 150
mockAnswersRadioOnTwice                       // two RADIO_STATE 01 frames
mockFailingRadioReportsInitErrorAndStateOff   // ERROR 01, then RADIO_STATE 00
mockSplitsNotificationsAtItsChunkSize         // notificationChunk 3: a 7-byte reply arrives as 3 notifications
mockRecordsDataPackets                        // receivedPackets == [p]
mockSetNotifyErrorIsDeliveredToTheCentral     // setNotifyErrors [CBATTError(.insufficientEncryption)]: FCB throws .att(.insufficientEncryption)
```

- [ ] **Step 3: Fail, implement, green,** `--filter MockRadioTests`, logs `t4-red.log`, `t4-green.log`. If `mockSetNotifyErrorIsDeliveredToTheCentral` shows FCB rewriting the error, **stop and ask** (Contract issue 1).
- [ ] **Step 4: Mutation batch.** No clamp; SF clamp 5–11; offset ignored; single echo; failed start reports state 01; whole reply in one notification; `setNotifyErrors` ignored; detect reply `0x47`. Every named test fails except the parse rows, which use the committed fixture: also mutate the emitter to drop the MCU query, which must fail `committedRepliesAreWhatTheMockEmitsToday`.
- [ ] **Step 5: Restore, re-run, all pass. Step 6: Commit.** Subject: `feat: MockRNodeDevice from firmware source, replies checked by RNS's parser`.

---

### Task 5: Session connect, handshake and validation

**Files:**
- Create: `Sources/RNodeKit/EventHub.swift` (port MeshCoreKit's), `RNodeSession.swift`, `RNodeSession+Handshake.swift`, `Tests/RNodeKitTests/Support/SessionSupport.swift`, `SessionHandshakeTests.swift`

**Interfaces:**
- Consumes: T1–T4.
- Produces: `RNodeSession.init`, `connect(radio:config:)`, `disconnect()`, `events()`; the handshake of spec §5.2. Test support: `makeRadio(_:)`, `ConnectedRig { session, device, events }`, `sessionWaitUntil(timeout:_:)`, `returnsWithin(_:_:)`, `sidebandConfig` (868_100_000, 62_500, 0 dBm, SF8, CR6).

Port from `MeshCoreSession.swift:140-410`: epoch, `runAttempt`/`abortAttempt`, attempt power watch, powered-on gate, `retrievePeripherals` (unknown → terminal `"radio not found"`), discover, take notifications before `setNotify`, then the handshake under a `startHandshakeTimeout` on the injected clock. Each step waits on a per-command reply waiter fed by the notification loop through the decoder.

- [ ] **Step 1: Write the failing tests** (nested CBM suite unless noted):

```swift
eventsReplayDisconnectedBeforeAnyConnect             // first event .connection(.disconnected(reason: nil))
connectWritesDetectThenTheFiveSettersThenRadioOn     // receivedFrames commands == [08,50,48,49, 01,02,03,04,05, 06]; values as sidebandConfig
connectEndsConnectedThenConfigured                   // ... .connecting, .configuring, .connected, .configured(info)
configuredInfoCarriesTheEchoes                       // info.reported == sidebandConfig; firmware 1, 86; platform 0x80; mcu 0x81; name "RNode 1A2B"
aSetterIsNotWrittenBeforeThePreviousEcho             // silentCommands [0x01]: no 0x02 frame for 4.9 s (TestClock), then a mismatch with reported nil
missingDetectIsRetryable                             // silentCommands [0x08]: .reconnecting(attempt: 1), not .disconnected
firmware151IsTerminal                                // firmware (1, 51): .disconnected(reason: firmwareTooOldReason); no setter frames
firmware152Connects
frequencyWithin100HzIsAccepted                       // offset 100: .connected
frequencyOff101HzIsRejected                          // offset 101: .configurationRejected([frequency, 868_100_000, 868_100_101])
clampedTXPowerIsRejectedBeforeTheRadioTurnsOn        // ask 30, max 22: rejected [txPower 30 → 22]; frames end [.., 06 00, 0A FF]; device.radioOnline == false
aMissingEchoIsAMismatchWithNoReply                   // silentCommands [0x05]: [codingRate, 6, nil]
everyMismatchIsListed                                // offset 500 and TX 30: two entries, frequency then txPower
aRejectedConfigurationDoesNotRetry                   // after the terminal end, 60 s on TestClock: no new connect
rejectionIsReportedBeforeTheTerminalEnd              // order: .configurationRejected, then .disconnected(reason: configurationRejectedReason)
aRadioThatWillNotStartIsRejected                     // radioStartFails: [radioState, 1, 0]; also .radioError(code: 1)
aDuplicateRadioStateEchoIsIgnored                    // doubleRadioStateEcho: one .configured, no error
statsDuringTheHandshakeDoNotFailAStep                // inject CHTM between echoes: .connected; .channelStats emitted
handshakeTimeoutStartsAfterSubscribe                 // closure central, setNotify held on a gate: TestClock +45 s, no .reconnecting; open the gate: the handshake runs
handshakeTimesOutAfter30Seconds                      // silent after detect: TestClock +30 s → .reconnecting
connectWhilePoweredOffWaitsThenConnects              // closure central gated on power
unknownRadioIsTerminal                               // "radio not found"
disconnectWritesLeaveFirst                           // last frame before the BLE disconnect is 0A FF
disconnectReturnsWhenLeaveIsNotAcknowledged          // the write never returns: disconnect returns within 1.5 s
disconnectEndsDisconnectedNil
```

- [ ] **Step 2: Fail,** `--filter SessionHandshakeTests`, log `t5-red.log`. **Step 3: Implement.** **Step 4: Green,** log `t5-green.log`.
- [ ] **Step 5: Mutation batch.**

| # | Mutation | Must fail |
|---|---|---|
| C1 | write all five setters without waiting for echoes | `aSetterIsNotWrittenBeforeThePreviousEcho` |
| C2 | radio on before validation (RNS order) | `clampedTXPowerIsRejectedBeforeTheRadioTurnsOn` |
| C3 | tolerance `> 101` | `frequencyOff101HzIsRejected` |
| C4 | tolerance `>= 100` | `frequencyWithin100HzIsAccepted` |
| C5 | firmware floor (1, 51) | `firmware151IsTerminal` |
| C6 | rejection is retryable | `aRejectedConfigurationDoesNotRetry` |
| C7 | missing echo throws a retryable failure | `aMissingEchoIsAMismatchWithNoReply` |
| C8 | validation stops at the first mismatch | `everyMismatchIsListed` |
| C9 | `.configurationRejected` emitted after the terminal state | `rejectionIsReportedBeforeTheTerminalEnd` |
| C10 | handshake timer starts before `setNotify` | `handshakeTimeoutStartsAfterSubscribe` |
| C11 | a non-awaited frame during a step throws | `statsDuringTheHandshakeDoNotFailAStep` |
| C12 | `disconnect` skips LEAVE | `disconnectWritesLeaveFirst` |
| C13 | LEAVE awaited with no bound | `disconnectReturnsWhenLeaveIsNotAcknowledged` |
| C14 | second radio-state echo treated as a new reply to the next step | `aDuplicateRadioStateEchoIsIgnored` |

- [ ] **Step 6: Restore, re-run, all pass. Step 7: Commit.** Subject: `feat: RNodeSession detects, configures and validates before the radio turns on`.

---

### Task 6: Sending, receiving, telemetry

**Files:**
- Modify: `Sources/RNodeKit/RNodeSession.swift`
- Test: `Tests/RNodeKitTests/SessionTrafficTests.swift`

**Interfaces:**
- Consumes: T5.
- Produces: `send(_:)` per spec §5.3; receive rules of §5.4; the 1250 ms partial-frame discard of §5.1.

- [ ] **Step 1: Write the failing tests:**

```swift
sendWritesOneDataFrame                         // device.receivedPackets.last == p
sendOf508BytesSucceeds
sendOf509BytesThrowsBeforeTouchingBLE          // .packetTooLarge; receivedWrites count unchanged
sendOfZeroBytesThrows                          // .emptyPacket
sendBeforeConnectedThrowsNotConnected
writesUseWithResponseWhenRXAdvertisesWrite     // rxProperties [.write, .writeWithoutResponse]: every type .withResponse
writesUseWithoutResponseOnlyWithoutWrite       // rxProperties [.writeWithoutResponse]: .withoutResponse
chunksNeverExceedTheWithoutResponseLength      // closure central maximumWriteValueLength 20: every write ≤ 20; reassembled == the frame
chunksAreCappedAt512                           // length 600: every write ≤ 512
concurrentSendsAllComplete                     // 10 sends at once: all return; receivedPackets == the 10, each whole
chunksOfTwoFramesNeverInterleave               // two 300 B sends at once, chunk 20: receivedFrames are the two packets, intact
receivedPacketCarriesItsSignal                 // injectPacket(p, 0x5A, 0x18): .packet(p, rssi: -67, snr: 6.0)
signalIsClearedAfterEachPacket                 // second inject with nil stats: .packet(p2, rssi: nil, snr: nil)
negativeSNRIsSigned                            // snrByte 0xF0: snr == -4.0
staleSignalIsNotAttachedAfterAReconnect        // inject stats only, drop, reconnect, inject packet with nil stats: rssi nil
packetSplitAcrossNotificationsArrivesWhole     // notificationChunk 7, 508 B packet: one .packet, intact
emptyDataFrameIsDropped                        // injectRawBytes(C0 00 C0): no .packet
oversizeFrameIsDropped                         // injectRawBytes of a 509 B data frame: no .packet
channelStatsAreDecoded                         // 00 64 00 32 03 E8 01 F4 3C 28 FF → 1.0, 0.5, 10.0, 5.0, -97, -117, nil
channelStatsWithInterferenceCarryIt            // last byte 0x50 → interferenceRSSI -77
wrongLengthChannelStatsAreIgnored              // 10 bytes: no event
radioErrorIsReported                           // injectError(0x05): .radioError(code: 5); stays connected
initRadioErrorReconnects                       // 0x01: .radioError(1), then .reconnecting(attempt: 1)
txFailedErrorReconnects                        // 0x02
resetWhileConnectedReconnects                  // injectReset: .reconnecting
stalledPartialFrameIsDiscardedAfter1250ms      // injectRawBytes(C0 00 01 02), TestClock +1250 ms, then a full packet: only that packet
partialFrameWithinTheTimeoutIsKept             // C0 00 01, +1249 ms, 02 C0: .packet([01 02])
```

- [ ] **Step 2: Fail,** `--filter SessionTrafficTests`, log `t6-red.log`. **Step 3: Implement.** Write type is read from the discovered RX `Characteristic.properties` at each handshake. **Step 4: Green,** log `t6-green.log`.
- [ ] **Step 5: Mutation batch.**

| # | Mutation | Must fail |
|---|---|---|
| D1 | always `.withoutResponse` | `writesUseWithResponseWhenRXAdvertisesWrite` |
| D2 | chunk = `maximumWriteValueLength(.withResponse)` | `chunksNeverExceedTheWithoutResponseLength` |
| D3 | no 512 cap | `chunksAreCappedAt512` |
| D4 | the write slot is taken per chunk, not per frame | `chunksOfTwoFramesNeverInterleave` |
| D5 | size guard `> 509` | `sendOf509BytesThrowsBeforeTouchingBLE` |
| D6 | signal not cleared after a packet | `signalIsClearedAfterEachPacket` |
| D7 | signal survives a link loss | `staleSignalIsNotAttachedAfterAReconnect` |
| D8 | SNR read unsigned | `negativeSNRIsSigned` |
| D9 | CHTM RSSI offset 156 | `channelStatsAreDecoded` |
| D10 | `0xFF` interference kept as −2 | `channelStatsAreDecoded`, `channelStatsWithInterferenceCarryIt` |
| D11 | errors 01/02 events only | `initRadioErrorReconnects`, `txFailedErrorReconnects` |
| D12 | reset ignored | `resetWhileConnectedReconnects` |
| D13 | partial timeout 1249 ms | `partialFrameWithinTheTimeoutIsKept` |
| D14 | no partial timer | `stalledPartialFrameIsDiscardedAfter1250ms` |
| D15 | empty data frames delivered | `emptyDataFrameIsDropped` |

- [ ] **Step 6: Restore, re-run, all pass. Step 7: Commit.** Subject: `feat: RNodeSession sends whole packets in chunks and reports packets with their signal`.

---

### Task 7: Pairing, reconnect, power cycle

**Files:**
- Create: `Sources/RNodeKit/RNodeSession+Link.swift`
- Test: `Tests/RNodeKitTests/SessionLinkTests.swift`

**Interfaces:**
- Consumes: T5, T6.
- Produces: spec §5.5: `static func classify(_ error: any Error) -> LinkFailureClass` (internal: `.pairing`, `.pairingRemoved`, `.other`), the disconnect watch (port `MeshCoreSession.swift:769-801`), backoff with a first retry of 0 s, the one-retry pairing rule, the 60 s `setNotify` bound.

- [ ] **Step 1: Write the failing tests.** Error constructors: `CBATTError(.insufficientAuthentication)`, `CBATTError(.insufficientEncryption)`, `CBATTError(.insufficientEncryptionKeySize)`, `NSError(domain: CBErrorDomain, code: 15)`, `NSError(domain: CBErrorDomain, code: 14)`.

```swift
@Test(arguments: [insufficientAuthentication, insufficientEncryption, insufficientEncryptionKeySize, encryptionTimedOut])
classifiesPairingErrors                         // classify(BluetoothError(e)) == .pairing   (plain test)
classifiesPeerRemovedPairing                    // code 14 → .pairingRemoved, also wrapped in .disconnected(underlying:)
classifiesOtherErrorsAsOther                    // .att(.readNotPermitted), CBError code 7 → .other
aFirstPairingFailureRetriesAtOnce               // setNotifyErrors [insufficientEncryption]: .reconnecting(1) and a second subscribe with TestClock unadvanced; then .connected
aSecondPairingFailureIsTerminal                 // two errors: .disconnected(reason: pairingRequiredReason)
pairingFailuresNeverSubscribeAThirdTime         // three queued errors: exactly 2 subscribe attempts after 120 s
aCompletedHandshakeResetsThePairingCount        // fail, connect, drop, fail: still retries (not terminal)
peerRemovedPairingIsTerminalAtOnce              // setNotifyErrors [code 14]: .disconnected(reason: pairingRemovedReason), 1 attempt
peerRemovedOnADisconnectIsTerminal              // connected, simulateDisconnect(code 14): pairingRemovedReason, no reconnect
setNotifyThatNeverReturnsIsAPairingFailure      // closure central, setNotify never returns: TestClock +60 s → .reconnecting(1); +60 s again → pairingRequiredReason
setNotifyAt59SecondsIsStillWaiting              // same central, +59.999 s: no state change
firstLinkLossMidHandshakeRetriesAtOnce          // disconnectAfterDetect: second attempt with TestClock unadvanced, then .connected
firstLinkLossAfterConnectedRetriesAtOnce        // disconnectAfterSubscribe 0 s after .connected: reconnects with TestClock unadvanced
laterRetriesBackOffFrom1To30Seconds             // radio unreachable after first drop: retry delays 0, 1, 2, 4, 8, 16, 30, 30
reconnectNeverScans                             // closure central: scan never called across 3 reconnects
reconnectWritesTheConfigAgain                   // second handshake's setter frames == the first's
powerCycleWhileConnectedReconnects              // CBM power off/on: .reconnecting, then .configured again; .adapterUnavailable(.poweredOff) between
anotherPeripheralsDisconnectIsIgnored           // a second mock disconnects: no state change
disconnectDuringHandshakeStaysDisconnected      // disconnect() while waiting for an echo, then the echo: stays .disconnected(nil)
connectSupersedesAnInFlightConnect              // connect(A), connect(B): only B configures
unauthorizedIsTerminal                          // .disconnected(reason: "unauthorized"), .adapterUnavailable(.unauthorized)
```

- [ ] **Step 2: Fail,** `--filter SessionLinkTests`, log `t7-red.log`. **Step 3: Implement.** If CBM can't simulate a disconnect carrying an `NSError`, use a closure central for those two tests; if FCB drops the error, **stop and ask**. **Step 4: Green,** log `t7-green.log`. Real-time CBM tests may take tens of seconds.
- [ ] **Step 5: Mutation batch.**

| # | Mutation | Must fail |
|---|---|---|
| E1 | `classify` returns `.other` for ATT errors | `classifiesPairingErrors`, `aFirstPairingFailureRetriesAtOnce`, `aSecondPairingFailureIsTerminal` |
| E2 | pairing failures always retryable | `aSecondPairingFailureIsTerminal`, `pairingFailuresNeverSubscribeAThirdTime` |
| E3 | pairing count never resets | `aCompletedHandshakeResetsThePairingCount` |
| E4 | code 14 classified `.pairing` | `peerRemovedPairingIsTerminalAtOnce`, `peerRemovedOnADisconnectIsTerminal` |
| E5 | no `setNotify` bound | `setNotifyThatNeverReturnsIsAPairingFailure` |
| E6 | bound 59 s | `setNotifyAt59SecondsIsStillWaiting` |
| E7 | first retry waits 1 s | `firstLinkLossMidHandshakeRetriesAtOnce`, `firstLinkLossAfterConnectedRetriesAtOnce`, `aFirstPairingFailureRetriesAtOnce` |
| E8 | cap 60 s | `laterRetriesBackOffFrom1To30Seconds` |
| E9 | reconnect re-handshakes without setters | `reconnectWritesTheConfigAgain` |
| E10 | disconnect watch ignores non-`.poweredOn` | `powerCycleWhileConnectedReconnects` |
| E11 | watch doesn't filter by peripheral | `anotherPeripheralsDisconnectIsIgnored` |
| E12 | no epoch check after the echo await | `disconnectDuringHandshakeStaysDisconnected`, `connectSupersedesAnInFlightConnect` |

- [ ] **Step 6: Restore, re-run, all pass. Step 7: Commit.** Subject: `feat: RNodeSession survives pairing with one retry and reconnects at once after the post-pairing drop`.

---

### Task 8: Scanner

**Files:**
- Create: `Sources/RNodeKit/RNodeScanner.swift`, `Tests/RNodeKitTests/ScannerTests.swift`

**Interfaces:**
- Consumes: `RNodeGATT`, `DiscoveredRNode`, `MockRNodeDevice`, and, test-only, a NUS peripheral spec named `MeshCore-ABCD` built inline in the test (no MeshCoreKit dependency).
- Produces: `RNodeScanner.scan(central:) -> AsyncStream<DiscoveredRNode>`, a port of `MeshCoreScanner.swift:14-51` with `RNodeGATT` and the `"RNode "` prefix, using the advertised local name, else the peripheral name.

- [ ] **Step 1: Write the failing tests** (nested CBM suite):

```swift
scanFindsAnRNode                                   // id, name "RNode 1A2B", rssi
scanDropsAMeshCoreRadioOnTheSameService            // both present: only the RNode
scanDropsAnUnnamedRadio
scanDropsANameWithoutTheTrailingSpace              // "RNodeX": dropped
scanUsesTheNUSServiceUUID                          // closure central records the services argument == [serviceUUID]
scanWaitsForPoweredOn
scanFinishesWhenSupersededWhileOn                  // a second scan on the same central: the first stream finishes
cancellingTheConsumerEndsTheFCBScan
```

- [ ] **Step 2: Fail, implement, green,** `--filter ScannerTests`, logs `t8-red.log`, `t8-green.log`.
- [ ] **Step 3: Mutation batch.** Prefix `"RNode"`; prefix check removed; services `nil`; no powered-on wait; superseded loop restarts; `onTermination` does nothing. Each named test fails.
- [ ] **Step 4: Restore, re-run, all pass.** Then the whole package with no filter, log `t8-full.log`: all pass.
- [ ] **Step 5: Commit.** Subject: `feat: RNodeScanner keeps only RNode-named radios on the shared NUS service`.
- [ ] **Step 6: Stop and report** commits, test count, the pinned SHAs, and that `rnodekit` is ready for a person to merge to `main`. **Do not merge or push.**

---

## Self-review

1. **Spec coverage.** Contract 1 → T1 (types), T2 (decoder), T5–T7 (session), T8 (scanner). §2 pins → T1 Step 2. §5.1 → T2, T6 (partial timer, empty frames). §5.2 → T5 (every step and mismatch). §5.3 → T6. §5.4 → T6. §5.5 → T7. §8 A → T3, T4 (RNS cross-checks both directions), T5–T8. FCB stop-and-ask → Contract issue 1, T4 Step 3, T7 Step 3.
2. **Step scan.** Signatures, test names, assertions with spec values; no bodies except the generator's inputs, which the plan must fix.
3. **Type consistency.** `RNodeRadioConfig`, `RNodeRadioInfo`, `RNodeChannelStats`, `RNodeParameterMismatch.Field`, the four reason constants, `MockRNodeDevice` members, `sidebandConfig` are the same in every task and in lane D's plan.
4. **Review Focus.** Five items, each with named tests in its owning task.
5. **Proportion.** Signatures, assertions and mutation tables.
