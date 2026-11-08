# RNode Interface (Lane B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give ReTiCA a Reticulum-over-RNode interface: the `RNodeDriver` contract (mock-driven; the live adapter is lane D's), an `RNodeInterface` reducer with Meshtastic's stop semantics, a whole-packet FIFO and radio telemetry, an `RNodeEndpoint` with its interface id and profile, and a `TransportEndpoint.rnode` slot. Probes deliver LXMF between two endpoints over an in-memory RNode channel, with and without IFAC, and between RNode and TCP through a relay.

**Architecture:** No codec here: RNodeKit owns KISS, so the driver carries whole packets. `RNodeInterface` in `ReTiCAInterfaces/RNode/` reaches the radio only through the `RNodeDriver` closure struct; `RNodeEndpoint` in `ReTiCANode` wraps it; `TransportEndpoint` gives it one `InterfaceID` per radio with the TCP-client lifecycle and masks with IFAC before handing packets down. Stop semantics are ported from `MeshCoreInterface`, the newest copy of Meshtastic's, minus channel removal.

**Tech Stack:** Swift 6 language mode, swift-composable-architecture ≥ 1.15 (`TestStore`, `TestClock`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-08-rnode-ble-interface-design.md` (this worktree's `docs/`): Contracts 2 and 3, §5.6–§5.8, §8 B. The MeshCore spec and lane B plan (`2026-11-07-meshcore-interface-design.md`, `plans/2026-11-07-meshcore-lane-b-interface.md`) are the precedent; executors read the RNode spec first.

## Contract issues

None. One placement, recorded so nobody reads it as a divergence: `RNodeTelemetry` lives on `RNodeInterface.State` (Contract 3 says "read-only on the slot"), and the endpoint exposes it as `telemetry`. Lane D's app code reads it there, the way it reads counters.

## Global Constraints

- **Worktree.** `W` = `/Users/ell/development/ios/pods/ReTiCA-worktrees/rnode-interface`, branch `feat/rnode-interface`, created in Task 1 from `feat/meshcore-interface` (spec §6). Commands write `W` for brevity; substitute the absolute path. Don't `cd`. `BASE` = the commit Task 1 records.
- **Branch only.** Commit to `feat/rnode-interface`. No pushing, no merging. Merging waits until MeshCore lane B is on `main` (spec §6, merge order 3).
- **Shell (user rule).** One command per line, per Bash call. No `|`, `&&`, `||`, `;`, `$(...)`, backticks, `xargs`, heredocs into interpreters, or inline scripts. Pass several test filters as repeated `--filter`. Temp files under `/tmp/ReTiCaMsgr/lane-rnode-b/`. Redirecting one command's output to a log is allowed.
- **Tests.** `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/rnode-interface --filter <Suite> > /tmp/ReTiCaMsgr/lane-rnode-b/<name>.log 2>&1`, timeout 600000 ms. Every new test is in a `@Suite struct` with the listed name. A signal 11 or stale-link failure after large changes: `swift package clean --package-path <W>`, rerun.
- **Known baseline failure:** `nonImprovingFreshAnnounceIsStillRebroadcast` hits TCA's 1 s receive timeout under parallel load and passes alone. Full runs use `--skip nonImprovingFreshAnnounceIsStillRebroadcast`, then run it alone once (Task 8). New cross-store tests pass `timeout:` on every `receive`, or poll.
- **Test verification (user rule), every task with tests:** (a) run the task's suites, all pass. (b) Apply the task's mutations to production code **in one batch**, run once, confirm every new test fails on its targeted assertion. Tests the table doesn't name get the obvious mutation in the same batch. Boundary pairs use a boundary swap (`limit − 1` behaves as past, `limit` as under), as MeshCore lane B's constraints define. If a test survives, fix it and restart at (a). (c) Revert with the Edit tool, run again, all pass. Never `git checkout`, `git restore` or `git stash` uncommitted work. Commit only after (c).
- **Commits.** Message via the Write tool to `/tmp/ReTiCaMsgr/lane-rnode-b/msg-tN.txt`, then `git -C <W> commit -F <file>`, ending with the attribution lines the executing session's system reminder gives. Explicit paths only.
- **File ownership (spec §6).** This lane owns `Sources/ReTiCAInterfaces/RNode/*`, `Sources/ReTiCANode/RNodeEndpoint.swift`, the RNode arms of `Sources/ReTiCANode/TransportEndpoint.swift`, and new tests. **No `Package.swift` change** (no fixtures here; `ReTiCARNodeLive` is lane D's). No file imports RNodeKit.
- **Don't edit Meshtastic or MeshCore code.** Reusing the internal `DriverEpoch` as is, is fine. `InterfaceProfile.swift` and `Transport.swift` aren't modified. In `TransportEndpoint.swift`, only add RNode arms and add `rnodeOwnsID` to the shared not-deliverable guard.
- **Spec values (verbatim).** Interface id `"rnode:" + uuid.uuidString`. Profile name `"rnode"`, `hwMTU` 508, mode `.full`, unknown-params bitrate 183. IFAC size 8. FIFO cap 64 packets. Max packet 508 bytes. Live-value message exactly `"ReTiCARNodeLive not installed"`. Bitrate `Int((SF · (4/CR) / (2^SF / (BW/1000)) · 1000).rounded())`, at least 1.
- **TCA rules in this repo.** `Effect.cancel(id:)` cancels at construction, so build it only inside the `return` of the arm that means it. `exhaustivity = .off`. `.cancellable` registers its id only when the task starts, which is why `DriverEpoch` exists.
- **Test names** state one claim. **Helper names:** every new top-level test helper is `private` or prefixed `rnode`/`RNode`.

## Review Focus

1. **A send result arrives after `.stop`** (the driver's write returns late). It must not dequeue or send the next packet into a stopped or restarted driver. Pinned by `aLateSendResultAfterStopSendsNothing` (Task 3).
2. **The radio reconnects with different reported params** (the user changed nothing, but the firmware clamped differently after a reset). Expected: Transport re-registers with the new bitrate, no maintenance double-arm. Pinned by `reconnectWithNewParamsReRegistersWithTheirBitrate` (Task 5).
3. **A 500-byte packet with IFAC on** reaches the driver as 508 bytes and isn't counted oversize; a 509-byte packet would be. Pinned by `aFullSizePacketWithIFACIsSent` (Task 5), `aPacketOf509BytesIsOversize` (Task 3).
4. **A radio's hardware error flood** (TXFAILED repeatedly before the session drops). Counters climb, nothing traps, and the interface status follows the driver's `.disconnected`, not the error. Pinned by `hardwareErrorsAreCountedWithoutChangingStatus` (Task 3).
5. **Meshtastic, MeshCore and RNode slots all present.** Each registers its own interface; an RNode drop deregisters only `rnode:`. Pinned by `threeRadioSlotsRegisterSeparateInterfaces`, `anRNodeDropLeavesTheOtherRadiosRegistered` (Task 5).

## File Structure

| File | Responsibility |
|---|---|
| `Sources/ReTiCAInterfaces/RNode/RNodeDriver.swift` | Contract 2 types, `RNodeLoRaParams.bitrate`, DependencyKey, `\.rnodeDriver` |
| `Sources/ReTiCAInterfaces/RNode/RNodeInterface.swift` | Reducer: lifecycle, stop semantics, FIFO, telemetry, counters |
| `Sources/ReTiCANode/RNodeEndpoint.swift` | Interface id, `InterfaceProfile.rnode(params:)`, endpoint wrapper, IFAC-8 helper |
| `Sources/ReTiCANode/TransportEndpoint.swift` (modify) | Slot, action, start/stop fan-out, lifecycle arms, transmit branch, `.ifLet` |
| `Tests/ReTiCAInterfacesTests/RNode*Tests.swift`, `RNodeInterfaceTestSupport.swift` | Suites named in Tasks 1–3 |
| `Tests/ReTiCANodeTests/RNodeEndpointTests.swift`, `TransportEndpointRNodeTests.swift`, `RNodeSlotReplacementTests.swift`, `RNodeWholeSliceTests.swift`, `RNodeRelayProbeTests.swift` | Suites named in Tasks 4–7 |

---

### Task 1: Worktree, driver contract, bitrate

**Files:**
- Create: `Sources/ReTiCAInterfaces/RNode/RNodeDriver.swift`
- Test: `Tests/ReTiCAInterfacesTests/RNodeDriverTests.swift`

**Interfaces:**
- Consumes: `BLEAdapterUnavailable` (`Sources/ReTiCAInterfaces/BLEDriver.swift:30`).
- Produces: Contract 2 verbatim (`RNodeLoRaParams`, `RNodeDriverConfig`, `RNodeRadioReport`, `RNodeChannelLoad`, `RNodeDriverEvent`, `RNodeDriver`), each with a public memberwise `init`; `RNodeDriver.liveAdapterMissing: String`; `DependencyValues.rnodeDriver`. Test value unimplemented, shaped like `MeshCoreDriver.swift:87-92`.

- [ ] **Step 0: Prerequisite and worktree.** A person commits the RNode spec and all four RNode plans on `feat/meshcore-interface` first; the executor doesn't.
  - `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshcore-interface ls-files docs/superpowers/plans/2026-11-08-rnode-lane-b-interface.md`. Expected: that path. Otherwise stop.
  - `git -C /Users/ell/development/ios/pods/ReTiCA worktree add /Users/ell/development/ios/pods/ReTiCA-worktrees/rnode-interface -b feat/rnode-interface feat/meshcore-interface`
  - `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/rnode-interface rev-parse --short HEAD`. Write it to `/tmp/ReTiCaMsgr/lane-rnode-b/base.txt` with the Write tool; this is `BASE`.
  - `mkdir -p /tmp/ReTiCaMsgr/lane-rnode-b`
- [ ] **Step 1: Baseline.** Run (timeout 600000): `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/rnode-interface --skip nonImprovingFreshAnnounceIsStillRebroadcast > /tmp/ReTiCaMsgr/lane-rnode-b/t1-baseline.log 2>&1`. Passes; record N.
- [ ] **Step 2: Write the failing tests**, suites `RNodeDriverTests`, `RNodeBitrateTests`. Rows `(SF, bandwidth Hz, CR)`.

| Test | Assertions |
|---|---|
| `liveValueReportsTheMissingLiveAdapter` | events == `[.unavailable(.other("ReTiCARNodeLive not installed"))]`, stream finishes |
| `liveValueSendReportsFailure` | false |
| `bitrateMatchesTheSpecTable` | (7, 125000, 5) 5469; (8, 125000, 5) 3125; (8, 62500, 6) 1302; (9, 125000, 5) 1758; (10, 250000, 5) 1953; (12, 125000, 8) 183; (12, 7800, 8) 11; (5, 1625000, 5) 203125 |
| `bitrateRoundsToTheNearestBit` | (7, 125000, 5) is 5468.75 → 5469, not 5468 |
| `bitrateIsNeverBelowOne` | (12, 7800, 8) with bandwidth 1 Hz → 1; SF 0, CR 0, bandwidth 0 → 1, no trap |
| `everyAppRangeCombinationHasAPositiveBitrate` | SF 5...12 × CR 5...8 × bandwidth {7800, 62500, 1625000}: `> 0` |

- [ ] **Step 3: Run; the build fails.** `--filter RNodeDriverTests --filter RNodeBitrateTests`, log `t1-red.log`.
- [ ] **Step 4: Implement.** `bitrate` guards CR, SF and bandwidth of 0 before dividing and returns `max(1, …)`. DependencyKey shape: `MeshCoreDriver.swift:68-93`.
- [ ] **Step 5: Verify (a), (b), (c).** Mutations: truncate instead of round; `4/CR` computed in integer arithmetic; `max(0, …)`; live value message `"ReTiCARNodeLive missing"`; live `send` returns true.
- [ ] **Step 6: Commit** `feat: RNode driver contract and bitrate`.

---

### Task 2: `RNodeInterface` lifecycle and stop semantics

**Files:** Create `Sources/ReTiCAInterfaces/RNode/RNodeInterface.swift`. Test in `Tests/ReTiCAInterfacesTests/`: `RNodeInterfaceTestSupport.swift`, `RNodeInterfaceLifecycleTests.swift`, `RNodeInterfaceStopTests.swift`, `RNodeInterfaceStartEpochTests.swift`.

**Interfaces:**
- Consumes: Task 1; internal `DriverEpoch`.
- Produces (Task 3 adds the sender and telemetry arms):

```swift
public enum RNodeInterfaceStatus: Equatable, Sendable {
    case stopped, connecting, online(RNodeRadioReport), unavailable(BLEAdapterUnavailable)
}
public struct RNodeCounters: Equatable, Sendable {   // Contract 3
    public var received, sent, oversize, queueFull, sendFailed, hardwareErrors: Int
    public init(received: Int = 0, sent: Int = 0, oversize: Int = 0, queueFull: Int = 0, sendFailed: Int = 0, hardwareErrors: Int = 0)
}
public struct RNodeTelemetry: Equatable, Sendable {  // Contract 3
    public var lastRSSI: Int?; public var lastSNR: Double?; public var channelLoad: RNodeChannelLoad?; public var lastHardwareError: UInt8?
    public init(...)  // all nil
}
@Reducer public struct RNodeInterface {
    public static let queueCapacity = 64
    public static let maxPacketSize = 508
    @ObservableState public struct State: Equatable {
        public let config: RNodeDriverConfig
        public internal(set) var status: RNodeInterfaceStatus
        public internal(set) var telemetry: RNodeTelemetry
        var counters: RNodeCounters
        public init(config: RNodeDriverConfig)
        public var isOnline: Bool { get }
        public var report: RNodeRadioReport? { get }
        public var isIdle: Bool { get }                 // .stopped and no driver.stop() in flight
        public var diagnostics: RNodeCounters { get }
        public var queuedPacketCount: Int { get }
    }
    public enum Action: Equatable {
        case start, stop, send(Data)
        case driverEvent(RNodeDriverEvent)
        case packetSent(ok: Bool, epoch: Int)
        case driverStopped, restartDeferred
        case delegate(Delegate)
        public enum Delegate: Equatable {
            case online(RNodeRadioReport)
            case offline(reason: String?)
            case packetReceived(Data)
            case adapterUnavailable(BLEAdapterUnavailable)
        }
    }
}
```

- Test support, shaped like `MeshCoreInterfaceTestSupport.swift`: `RNodeMockCall { start(RNodeDriverConfig), send(Data), stop }`, `rnodeTestParams` (868_100_000, 62_500, 0, 8, 6), `rnodeTestConfig`, `rnodeTestReport` (firmware 1.86, platform 0x80, params = `rnodeTestParams`), `RNodeInterfaceHarness { store, radio, calls }`, `makeRNodeInterface(sendResults:holdSends:)`, `makeOnlineRNodeInterface(report:sendResults:)`, `stopRNodeInterface(_:)`.

**Stop semantics, right from the start.** Port from `MeshCoreInterface.swift`, not from a plan: `stopping`, `restartPending`, `restartQueued`, `epoch`, `.restartDeferred` and the hop through a task, and the fix in `fe6f775` that ignores a stale send result. `.stop` bumps the epoch at reduce time; a stop's offline is emitted only from `.driverStopped`; `.stop` to an idle interface answers offline at once; `isIdle = status == .stopped && !stopping`. Leave out everything about channel removal. Copy the comments that say why.

- [ ] **Step 1: Write the failing tests.** Suite `RNodeInterfaceLifecycleTests`. These mirror the same-named tests in `MeshCoreInterfaceLifecycleTests.swift`, changing only the event types: `unavailableSurfacesTheCause`, `aReconnectAttemptAfterUnavailableIsConnectingAndBlocksStart`, `unavailableWhileOnlineReportsOffline`, `stopStopsTheDriver`, `stopWhileConnectingReportsOffline`, `startDuringASlowStopReachesTheDriverAfterTheStop`, `startDuringASlowStopBringsTheRadioOnline`, `stopCancelsAStartDeferredBehindASlowStop`, `disconnectReportsOfflineWithTheReason`, `eventsAfterStopAreIgnored`.

| New test | Assertions |
|---|---|
| `startHandsTheConfigToTheDriver` | `calls == [.start(rnodeTestConfig)]` |
| `connectedEventReportsOnlineWithItsReport` | delegate `.online(rnodeTestReport)`; `state.report == rnodeTestReport` |
| `aSecondConnectedReportsOnlineAgain` | two `.connected` with different params: two `.online` delegates, the second's params |
| `userActionMessagesSurfaceVerbatim` | `.unavailable(.other("This RNode's firmware is too old. Update it to 1.52 or later."))` reaches the delegate unchanged |
| `packetBeforeOnlineIsDropped` | `.packet` while `.connecting`: no delegate, `received == 0` |
| `packetWhileOnlineIsDelivered` | `.packetReceived(p)`, `received == 1` |
| `diagnosticsCarryEveryCounter` | seeded state: all six fields |

Suite `RNodeInterfaceStopTests`: the eight tests of `MeshCoreInterfaceStopTests.swift`, same names (`offlineWaitsForTheDriverStopToReturn`, `stopOnANeverStartedInterfaceReportsOfflineAtOnce`, `stopAfterACompletedStopReportsOfflineAgain`, `aSecondStopDuringAStopReportsOfflineOnceTheDriverStops`, `stopCancellingADeferredStartWaitsForTheInFlightStop`, `aStartDuringAStopReportsOfflineBeforeTheDriverRestarts`, `isIdleOnlyOnceTheDriverStopReturned`, `aStopAnsweringTheRestartOfflineWinsOverTheDeferredStart`), same recorder and fresh-stream harness. Suite `RNodeInterfaceStartEpochTests`: `aStopInTheDeferredRestartsBurstKeepsTheRestartOffTheDriver`, `aStopInTheStartsBurstFromStoppedKeepsTheStartOffTheDriver`, same burst host, 5 runs each.

- [ ] **Step 2: Run; the build fails.** `--filter RNodeInterfaceLifecycleTests --filter RNodeInterfaceStopTests --filter RNodeInterfaceStartEpochTests`, log `t2-red.log`.
- [ ] **Step 3: Implement.** **Step 4: Green,** log `t2-green.log`.
- [ ] **Step 5: Verify (a), (b), (c).** Mutations, one batch:

| Mutation | Breaks |
|---|---|
| `.unavailable` maps every cause to `.other(nil)` | `unavailableSurfacesTheCause`, `userActionMessagesSurfaceVerbatim` |
| `.stop` never calls `driver.stop()` and emits offline at once | `stopStopsTheDriver`, `startDuringASlowStop…` (2), `stopCancelsAStartDeferredBehindASlowStop`, `offlineWaitsForTheDriverStopToReturn`, `isIdleOnlyOnceTheDriverStopReturned` |
| `.stop` to a stopped interface, or from `.connecting`, returns `.none` | `stopOnANeverStartedInterfaceReportsOfflineAtOnce`, `stopAfterACompletedStopReportsOfflineAgain`, `stopWhileConnectingReportsOffline` |
| remove `state.epoch.invalidate()` | `aStopInTheStartsBurstFromStoppedKeepsTheStartOffTheDriver` |
| `.restartDeferred` ignores `restartQueued` | `aStopAnsweringTheRestartOfflineWinsOverTheDeferredStart`, `aStopInTheDeferredRestartsBurstKeepsTheRestartOffTheDriver` |
| `.packet` delivered in any status | `packetBeforeOnlineIsDropped` |
| a repeated `.connected` while online is ignored | `aSecondConnectedReportsOnlineAgain` |

- [ ] **Step 6: Commit** `feat: RNodeInterface lifecycle and stop semantics`.

---

### Task 3: `RNodeInterface` FIFO, telemetry, counters

**Files:** Modify `Sources/ReTiCAInterfaces/RNode/RNodeInterface.swift`. Test `Tests/ReTiCAInterfacesTests/RNodeInterfaceSenderTests.swift`, `RNodeInterfaceTelemetryTests.swift`.

**Interfaces (produces):** the `.send`, `.packetSent`, telemetry and counter arms of spec §5.6. The sender's effect is one `.run` per packet, cancellable on `CancelID.sending`: `driver.send(packet)`, then `.packetSent(ok:epoch:)`. No sleep. A result whose epoch isn't current is ignored.

- [ ] **Step 1: Write the failing tests.**

Suite `RNodeInterfaceSenderTests`:

| Test | Assertions |
|---|---|
| `sendPassesThePacketUnchanged` | `calls.last == .send(p)` for a 200 B `p` |
| `firstPacketGoesOutAtOnce` | one send, no clock involved (store has no clock dependency) |
| `nextPacketWaitsForTheDriverToReturn` | `holdSends`: 3 queued, one call; release: the second goes out at once, then the third |
| `everyPacketGoesOutExactlyOnceInOrder` | 10 packets: `sent == the 10`, in order |
| `sentCountsEachAcceptedPacket` | `sent == 10` |
| `sendFailureCountsSendFailed`, `sendFailureDropsThePacketAndContinues` | `[false, true]`: `sendFailed == 1`; the second call is packet 2 |
| `queueHoldsAtMost64Packets` | `holdSends`, 66 packets: one in flight, `queuedPacketCount == 64`, `queueFull == 1` |
| `aPacketOf508BytesIsSent` | one call with 508 B |
| `aPacketOf509BytesIsOversize` | no call, `oversize == 1`, `queueFull == 0` |
| `sendWhileOfflineIsDropped` | no call, no counter changes |
| `disconnectClearsTheQueue` | 5 queued, `.disconnected`: `queuedPacketCount == 0`; reconnect, one new packet: exactly one call |
| `aLateSendResultAfterStopSendsNothing` | `holdSends`, 2 queued, `.stop`, release the held send: no second `.send` call |
| `stopAndStartDoesNotResendTheOldQueue` | 3 queued, stop, start, `.connected`: no call until a new `.send` |

Suite `RNodeInterfaceTelemetryTests`:

| Test | Assertions |
|---|---|
| `packetSignalUpdatesTelemetry` | `.packet(p, rssi: -97, snr: 6.25)`: `lastRSSI == -97`, `lastSNR == 6.25` |
| `aPacketWithoutSignalKeepsTheLastValues` | then `.packet(q, rssi: nil, snr: nil)`: still −97, 6.25 |
| `channelLoadIsRecorded` | `.channelLoad(c)`: `telemetry.channelLoad == c` |
| `hardwareErrorsAreCountedWithoutChangingStatus` | 5 × `.hardwareError(2)`: `hardwareErrors == 5`, `lastHardwareError == 2`, status still `.online` |
| `telemetrySurvivesADisconnect` | values unchanged after `.disconnected` |
| `telemetryEventsAfterStopAreIgnored` | `.channelLoad` after `.stop`: nil |

- [ ] **Step 2: Run; the build fails.** `--filter RNodeInterfaceSenderTests --filter RNodeInterfaceTelemetryTests`, log `t3-red.log`.
- [ ] **Step 3: Implement.** Extend the disconnect and stop arms: empty the queue, clear the in-flight flag, and add the `.sending` cancel inside each arm's `return`. **Step 4: Green,** with Task 2's suites too, log `t3-green.log`.
- [ ] **Step 5: Verify (a), (b), (c).** Mutations, one batch:

| Mutation | Breaks |
|---|---|
| spawn `driver.send` detached and dequeue at once | `nextPacketWaitsForTheDriverToReturn` |
| requeue on failure | `sendFailureDropsThePacketAndContinues`, `everyPacketGoesOutExactlyOnceInOrder` |
| `queueCapacity = 65` | `queueHoldsAtMost64Packets` |
| size check `> 507` | `aPacketOf508BytesIsSent` |
| size check removed | `aPacketOf509BytesIsOversize` |
| `.send` not gated on online | `sendWhileOfflineIsDropped` |
| `.disconnected` keeps the queue | `disconnectClearsTheQueue`, `stopAndStartDoesNotResendTheOldQueue` |
| `.packetSent` ignores its epoch | `aLateSendResultAfterStopSendsNothing` |
| nil signal overwrites the last values | `aPacketWithoutSignalKeepsTheLastValues` |
| `.hardwareError` sets status `.unavailable(.other(nil))` | `hardwareErrorsAreCountedWithoutChangingStatus` |
| telemetry reset on `.disconnected` | `telemetrySurvivesADisconnect` |
| `sent` incremented on failure too | `sentCountsEachAcceptedPacket` |

- [ ] **Step 6: Commit** `feat: RNodeInterface whole-packet FIFO and radio telemetry`.

---

### Task 4: `RNodeEndpoint`, interface id, profile

**Files:** Create `Sources/ReTiCANode/RNodeEndpoint.swift`. Test `Tests/ReTiCANodeTests/RNodeEndpointTests.swift`.

**Interfaces (produces):**

```swift
public func rnodeInterfaceID(radio: UUID) -> InterfaceID
extension InterfaceProfile { public static func rnode(params: RNodeLoRaParams?) -> InterfaceProfile }
@Reducer public struct RNodeEndpoint {
    public static let ifacSize = 8
    public static let unknownBitrate = 183
    public static func ifac(networkName: String?, passphrase: String?) -> IFAC?
    @ObservableState public struct State: Equatable {
        public var interface: RNodeInterface.State
        public let profile: InterfaceProfile                 // IFAC and mode only
        public var interfaceID: InterfaceID { get }
        public var counters: RNodeCounters { get }
        public var telemetry: RNodeTelemetry { get }
        public init(config: RNodeDriverConfig, profile: InterfaceProfile = .rnode(params: nil))
        public func registeredProfile(params: RNodeLoRaParams) -> InterfaceProfile
    }
    public enum Action: Equatable {
        case interface(RNodeInterface.Action)
        case start, stop
        case delegate(Delegate)
        @CasePathable public enum Delegate: Equatable {
            case radioOnline(RNodeRadioReport)
            case radioOffline(reason: String?)
            case adapterUnavailable(BLEAdapterUnavailable)
        }
    }
}
```

The `InterfaceProfile` extension lives here for the reason at `MeshtasticEndpoint.swift:19-20`. `TransportEndpoint` translates all three delegates.

- [ ] **Step 1: Write the failing tests**, suite `RNodeEndpointTests`:

| Test | Assertions |
|---|---|
| `profileBitrateFollowsTheParams` | Sideband defaults → 1302; (12, 125000, 8) → 183 |
| `profileForNilParamsUsesTheUnknownBitrate` | 183 |
| `profileIsNamedRNode`, `profileDeclaresAHardwareMTUOf508`, `profileModeIsFull` | `"rnode"`; 508; `.full` |
| `registeredProfileTakesIFACFromTheEndpointProfile`, `…ModeFromTheEndpointProfile`, `…BitrateFromTheReportedParams` | as named; reported (10, 250000, 5) → 1953 |
| `interfaceIDIsRNodeColonTheRadioUUID` | `InterfaceID("rnode:" + uuid.uuidString)` |
| `ifacHelperUsesEightByteAccessCodes` | `protect(raw).count == raw.count + 8` |
| `endpointStartStartsTheDriver`, `endpointStopStopsTheDriver` | one `.start`; one `.stop` after online |
| `countersShowAnOversizePacket`, `telemetryShowsTheLastRSSI` | 1; −97 |

- [ ] **Step 2: Run; the build fails.** `--filter RNodeEndpointTests`, log `t4-red.log`. **Step 3: Implement.** Shape: `MeshtasticEndpoint.swift`. **Step 4: Green.**
- [ ] **Step 5: Verify (a), (b), (c).** Mutations: bitrate fixed at 1302; unknown bitrate 236; name `"RNode"`; `hwMTU` 500; mode `.gateway`; `registeredProfile` drops `ifac` and `mode`; id prefix `"rnode-"`; `ifacSize = 16`; `.start`/`.stop` return `.none`; `counters` and `telemetry` return `.init()`.
- [ ] **Step 6: Commit** `feat: RNodeEndpoint, interface id and profile`.

---

### Task 5: `TransportEndpoint` slot

**Files:** Modify `Sources/ReTiCANode/TransportEndpoint.swift`. Test `Tests/ReTiCANodeTests/TransportEndpointRNodeTests.swift`, `RNodeSlotReplacementTests.swift`.

**Interfaces:**
- Consumes: Task 4.
- Produces: `TransportEndpoint.State.rnode: RNodeEndpoint.State?` (new last `init` parameter, default nil), `.rnode(_:)` factory, `Action.rnode(RNodeEndpoint.Action)`.

Touch points at `BASE` (`b34d0cc` lines; re-find each by its text):

| Line | Change |
|---|---|
| 46-48, 82-95, 119-120, 134 | slot after `meshCore`, `init` parameter, factory, action |
| 220-221, 226-227 | start and stop fan-out: `state.rnode != nil ? .send(.rnode(.start)) : .none`, and stop |
| after 458 | `.rnode(.interface(.delegate(...)))` arms copying the Meshtastic ones at 382-409: `.online(report)` registers `registeredProfile(params: report.params)` with `maintenanceStartEffect`, then `.radioOnline(report)`; `.offline` deregisters from Transport and LinkPlane with `maintenanceStopEffect` only if registered, then `.radioOffline`; `.packetReceived` → `.transport(.received(id, packet))`; `.adapterUnavailable` → the hatch |
| 543 | add `.rnode` to the catch-all |
| 554 | `.ifLet(\.rnode, action: \.rnode) { RNodeEndpoint() }` |
| 616-625 | after the MeshCore branch: `rnodeOwnsID`, and while online `.send(.rnode(.interface(.send(masked))))`; the not-deliverable guard becomes `state.ble != nil \|\| meshOwnsID \|\| coreOwnsID \|\| rnodeOwnsID` |

- [ ] **Step 1: Write the failing tests.** Harness: private `makeRNodeEndpoint(profile:withTCPClient:withMeshtastic:withMeshCore:)` built like `TransportEndpointMeshCoreTests.swift`'s, minus the limiter date. Mock drivers for each slot.

Suite `TransportEndpointRNodeTests`, the claims of the Meshtastic suite: `radioOnlineRegistersItsInterfaceWithTheReportedProfile`, `reconnectWithNewParamsReRegistersWithTheirBitrate`, `radioOnlineSurfacesOnTheRNodeHatch`, `radioDropDeregistersItsInterface`, `radioDropSurfacesOnTheRNodeHatch`, `endpointStopDeregistersTheRadio`, `endpointStopBeforeTheRadioConnectsSurfacesRadioOffline`, `endpointStopAfterARadioDropDeregistersTheRadioOnce`, `inboundPacketsReachTheRouterTaggedWithTheRadioID`, `transmitToTheRadioIDPutsThePacketOnTheDriver`, `transmitWhileTheRadioIsOfflineReportsInterfaceUnavailable`, `missingLiveAdapterSurfacesOnTheRNodeHatch`. New:

| Test | Assertions |
|---|---|
| `transmitOverAnIFACRadioMasksThePacket` | driver gets `count == raw.count + 8`, `first & 0x80 == 0x80` |
| `aFullSizePacketWithIFACIsSent` | 500 B raw, IFAC: driver gets 508 B; `oversize == 0` |
| `threeRadioSlotsRegisterSeparateInterfaces` | Meshtastic, MeshCore, RNode online: three ids in `transport.interfaces` |
| `anRNodeDropLeavesTheOtherRadiosRegistered` | RNode `.disconnected`: only `rnode:` deregistered |
| `transmitToAnotherRadiosIDNeverReachesTheRNode` | transmit to the Meshtastic id: no RNode `.send` call |

Suite `TransportEndpointRNodeMaintenanceTests`: `radioDropKeepsSharedMaintenanceAliveForTheTCPClient`, `radioAsTheLastInterfaceToDropStopsSharedMaintenance`, `radioLifecycleWithALiveTCPClientArmsMaintenanceOnce`.

Suite `RNodeSlotReplacementTests`, mirroring `MeshtasticSlotReplacementTests.swift` with an `RNodeRadioSlotHost`: `aReplacedSlotStartsOnlyAfterTheOldDriverStopped` (`[start A, stop, start B]`), `stopToANeverStartedSlotReportsRadioOfflineAtOnce`, `aStartReachingTheOldSlotMidStopNeverOverlapsTheNewRadiosStart`, and new `aParameterChangeReplacesTheSlotTheSameWay` (same radio, new frequency: `[start f1, stop, start f2]`).

- [ ] **Step 2: Run; the build fails.** `--filter TransportEndpointRNodeTests --filter TransportEndpointRNodeMaintenanceTests --filter RNodeSlotReplacementTests`, log `t5-red.log`.
- [ ] **Step 3: Implement** per the table. Afterwards `--filter TransportEndpointMeshtastic --filter TransportEndpointMeshCore --filter MeshtasticSlotReplacementTests --filter MeshCoreSlotReplacementTests` stays green, log `t5-neighbours.log`.
- [ ] **Step 4: Verify (a), (b), (c).** Mutations, one batch:

| Mutation | Breaks |
|---|---|
| `.send(unmasked)` to the interface | `transmitOverAnIFACRadioMasksThePacket`, `aFullSizePacketWithIFACIsSent` |
| `.online` registers `.rnode(params: nil)` | `radioOnlineRegistersItsInterfaceWithTheReportedProfile`, `reconnectWithNewParamsReRegistersWithTheirBitrate` |
| guard omits `rnodeOwnsID` | `transmitWhileTheRadioIsOfflineReportsInterfaceUnavailable` |
| `.offline` deregisters every radio id | `anRNodeDropLeavesTheOtherRadiosRegistered` |
| RNode branch checks `isOnline` only, not the id | `transmitToAnotherRadiosIDNeverReachesTheRNode` |
| `maintenanceStopEffect` omitted; start always arms | the maintenance suite |
| `RNodeInterface.stop` emits offline before `driver.stop()` returns | the slot replacement suite |
| no `.rnode` in the start fan-out | `endpointStopBeforeTheRadioConnectsSurfacesRadioOffline`, `radioOnline…` |

- [ ] **Step 5: Commit** `feat: TransportEndpoint RNode slot`.

---

### Task 6: Whole-slice probe

**Files:** Test `Tests/ReTiCANodeTests/RNodeWholeSliceTests.swift`. Shape: `MeshCoreWholeSliceTests.swift`, simpler: no codec.

Two `LXMFNode`s; A's `driver.send(p)` yields `.packet(p, rssi: nil, snr: nil)` on B's stream and vice versa, returning true. `$0.continuousClock = TestClock()` (never advanced), `$0.date`, `$0.uuid = .incrementing`. Every `receive` passes `timeout: .seconds(5)`.

- [ ] **Step 1: Write the tests**, suite `RNodeWholeSliceTests`. `runRNodeProbe(ifac:)` returns `(content, aOnAir: [Data])`.

| Test | Assertions |
|---|---|
| `opportunisticMessageCrossesAnOpenRNodeLink` | `content == Data("hello over rnode".utf8)` |
| `opportunisticMessageCrossesAnIFACProtectedRNodeLink` | same, both endpoints with `RNodeEndpoint.ifac(networkName: "testnet", passphrase: "secret")` |
| `ifacProtectedLinkCarriesOnlyIFACFlaggedPackets` | `aOnAir` non-empty, each `first & 0x80 == 0x80` |
| `everyPacketOnTheAirFitsTheHardwareMTU` | each `1...508` bytes |
| `aMismatchedIFACDeliversNothing` | A `"secret"`, B `"other"`: no content within 5 s, and B learns no path to A |

- [ ] **Step 2: Verify (a), (b), (c)** with `--filter RNodeWholeSliceTests`. The code exists, so "fail first" happens at (b). If a probe fails at (a), debug it; don't relax it. Mutations: the `.packetReceived` arm returns `.none`; `TransportEndpoint` sends `unmasked`; `maxPacketSize = 300` (a 400-byte LXMF packet then drops).
- [ ] **Step 3: Commit** `test: LXMF whole-slice probe over an in-memory RNode link`.

---

### Task 7: Relay probe

**Files:** Test `Tests/ReTiCANodeTests/RNodeRelayProbeTests.swift`. Harness: `MeshCoreRelayProbeTests.swift`, with the radio legs swapped for RNode and no limiter.

```
A: LXMFNode, RNode slot  <-- packets -->  R: TransportEndpoint, RNode slot + TCP client, relay on  <-- HDLC bytes -->  B: LXMFNode, TCP client
```

R: `$0.continuousClock = rClock` (a `TestClock`), `\.transportDate` from a `LockIsolated<Date>`, `.enableRelay(rIdentity)` before the interfaces come up, reported params Sideband defaults (1302 bps). R rebroadcasts after jitter (≤ 0.5 s, `Transport.swift:789-793`): `await rClock.advance(by: .seconds(1))`. Poll a private `rnodeWaitUntil(timeout: .seconds(10))` between clock moves, with `await Task.megaYield()`.

- [ ] **Step 1: Write the tests**, suite `RNodeRelayProbeTests`:

| Test | Assertions |
|---|---|
| `messageFromRNodeReachesTCPThroughTheRelay` | both register delivery; each learns the other via R; A opportunistic to B: content equal |
| `messageFromTCPReachesRNodeThroughTheRelay` | same, B to A |
| `aTCPAnnounceIsRelayedOntoTheRadio` | a TCP announce at hops 2: after `rClock` +1 s, one announce on the RNode leg at hops 3 (no MeshCore-style cap: spec §5.8) |
| `relayOffForwardsNothing` | without `.enableRelay`: no TCP announce on the radio leg after +1 s and +200 s |

- [ ] **Step 2: Verify (a), (b), (c)** with `--filter RNodeRelayProbeTests`. First check flakes: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/rnode-interface --filter RNodeRelayProbeTests --maximum-repetitions 5 --repeat-until fail > /tmp/ReTiCaMsgr/lane-rnode-b/t7-flake.log 2>&1`; fix any flake at its cause by polling, never by a longer sleep. Mutations: the RNode `.packetReceived` arm returns `.none` (both message tests); the RNode `transmit` branch returns `.none` (`messageFromTCPReachesRNodeThroughTheRelay`, `aTCPAnnounceIsRelayedOntoTheRadio`); `.enableRelay` sent in the relay-off test's setup (`relayOffForwardsNothing`).
- [ ] **Step 3: Commit** `test: RNode to TCP relay probe, both directions`.

---

### Task 8: Whole-lane verification

**Files:** none changed unless something fails.

- [ ] **Step 1: Full suite.** `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/rnode-interface --skip nonImprovingFreshAnnounceIsStillRebroadcast > /tmp/ReTiCaMsgr/lane-rnode-b/t8-full.log 2>&1`. Passes; count = baseline + this lane. Then `--filter nonImprovingFreshAnnounceIsStillRebroadcast` alone: passes.
- [ ] **Step 2: Other radios untouched.** Expected empty for each, with `BASE` from `/tmp/ReTiCaMsgr/lane-rnode-b/base.txt`:
  - `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/rnode-interface diff --stat BASE -- Sources/ReTiCAInterfaces/Meshtastic Sources/ReTiCAInterfaces/MeshCore Sources/ReTiCANode/MeshtasticEndpoint.swift Sources/ReTiCANode/MeshCoreEndpoint.swift Sources/ReTiCAMeshtasticLive Sources/ReTiCATransport Package.swift`
  - `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/rnode-interface diff --stat BASE -- Tests/ReTiCAInterfacesTests/Meshtastic* Tests/ReTiCAInterfacesTests/MeshCore* Tests/ReTiCANodeTests/Meshtastic* Tests/ReTiCANodeTests/MeshCore* Tests/ReTiCANodeTests/TransportEndpointMeshtasticTests.swift Tests/ReTiCANodeTests/TransportEndpointMeshCoreTests.swift`
- [ ] **Step 3: No kit leakage.** `grep -rln "import RNodeKit" /Users/ell/development/ios/pods/ReTiCA-worktrees/rnode-interface/Sources /Users/ell/development/ios/pods/ReTiCA-worktrees/rnode-interface/Tests`. Expected: no output.
- [ ] **Step 4: Branch state.** `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/rnode-interface status --short --branch`: on `feat/rnode-interface`, clean. Stop and report. Don't push or merge.

---

## Lane D hand-off

- `RNodeDriver.live(session:)` must map Contract 1 to Contract 2: `.configured(info)` → `.connected(RNodeRadioReport(info))`, `.packet` → `.packet`, `.channelStats` → `.channelLoad` (dropping `currentRSSI`), `.radioError(code)` → `.hardwareError(code)`, the session's terminal reasons → Contract 2's messages. `send` returns true only when `session.send` returns.
- The interface never validates `RNodeLoRaParams`; the app does. A slot is replaced on any `RNodeDriverConfig` change (spec §6); replacing one resets counters and telemetry, which the app carries in its own retired counters.
- `RNodeTelemetry` and `RNodeCounters` are read from `TransportEndpoint.State.rnode?.telemetry` and `.counters`; nothing reaches a delegate except the three in Contract 3.

## Self-Review

- **Spec coverage:** Contract 2 → Task 1. Contract 3 → Tasks 2–5 (counters, telemetry, id, profile, delegates, slot, ifac helper). §5.6 → Task 3. §5.7 → Tasks 1, 4. §5.8 IFAC → Tasks 5, 6; relay → Task 7. §8 B → Tasks 1–7; untouched neighbours → Task 8.
- **Step scan:** signatures, test names, assertions with spec values; one touch-point table instead of code.
- **Type consistency:** `RNodeLoRaParams`, `RNodeRadioReport`, `RNodeChannelLoad`, `RNodeDriverEvent` cases, `RNodeCounters` fields, `RNodeTelemetry` fields, `rnodeInterfaceID(radio:)`, `registeredProfile(params:)`, `.packetSent(ok:epoch:)` match across tasks and lane D's plan.
- **Review Focus:** five items, each with named tests in its owning task.
- **Proportion:** shorter than the MeshCore lane B plan, as the interface has no codec, reassembler or limiter.
