# Meshtastic Interface (Lane B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give ReTiCA a Reticulum-over-Meshtastic interface: a byte-exact landandair fragment codec, a bounded reassembler, a paced sender with REQ answering, a `MeshtasticDriver` dependency contract (mock-driven here; the live adapter is lane E's), and a `TransportEndpoint.meshtastic` slot. A whole-slice probe delivers an LXMF opportunistic message between two endpoints joined by an in-memory radio.

**Architecture:** Pure value types (`LandandairCodec`, `MeshtasticReassembler`) sit under a `MeshtasticInterface` TCA reducer in `ReTiCAInterfaces/Meshtastic/`. That reducer talks to the radio only through the closure-struct `MeshtasticDriver` dependency, and its pacing runs on an injected clock. `MeshtasticEndpoint` in `ReTiCANode` wraps the interface. `TransportEndpoint` gives it ONE `InterfaceID` per radio with the TCP-client lifecycle, IFAC-masks outbound packets centrally, and drives shared maintenance off the shared interface count.

**Tech Stack:** Swift 6 language mode, swift-composable-architecture ≥ 1.15 (TestStore, TestClock, ImmediateClock), Swift Testing, Python 3 in conda env `rns` for cross-validation fixtures.

**Spec:** `docs/superpowers/specs/2026-10-16-meshtastic-interface-design.md`. This plan implements Lane B: Contract 2 (define and mock), Contract 3, all of §5, and the lane-B rows of §6 and §8. Executors read both documents.

## Global Constraints

- **Worktree:** all work happens in `/Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface` on branch `meshtastic-interface`. Task 1 creates it. `../FCB` resolves through the existing symlink `pods/ReTiCA-worktrees/FCB`. In this plan, `WT` means that absolute path. Always write it out in full in commands.
- **One shell command per Bash call.** No `|`, `&&`, `||`, `;`, no `$(...)`, no `xargs`. Never inline a script into an interpreter (`python -c`, `bash -c`, heredocs into an interpreter). Write scripts to files and run each file as one command. Do not `cd`: use `swift ... --package-path WT` and `git -C WT ...`.
- **Temp files** (commit messages, scratch) go under `/tmp/meshtastic-interface/`, named after the worktree's basename. Create it with `mkdir -p /tmp/meshtastic-interface` once.
- **Test verification rule, mandatory for every task that adds or changes tests:**
  - (a) Run the task's suites and confirm every test passes.
  - (b) Apply the task's listed production-code mutations **in one batch**, run the same suites once, and confirm **every** new non-trap test fails. Read each failure message and confirm it is the targeted assertion failing.
  - (c) Revert every mutation and run again. Every test must pass.
  - Revert with the Edit tool, undoing exactly the mutation edits. Never use `git checkout`, `git restore` or `git stash` on uncommitted work: new files would be lost or left mutated.
  - If a test still passes under its mutation, the test is not testing what it claims. Fix it and restart at (a). Only commit after (c).
- **Trap-class tests (planned exception to the single batch):** a few tests pin "must not trap" behaviour: `Int8.min` positions and non-zero-based `Data` slices. Their only meaningful mutation is the trapping code, and a trap aborts the whole test process, so it would mask every other result in the batch. Verify each one in step (b′): apply only its mutation, run only that test by its unique name (`--filter <testName>`), confirm the run fails (trap or assertion), then revert. The tasks list these explicitly.
- **Commits:** write the message with the Write tool to `/tmp/meshtastic-interface/commit-task-N.txt`, then run `git -C WT commit -F /tmp/meshtastic-interface/commit-task-N.txt`. The message ends with these two trailer lines, at column zero (no indentation), as one final paragraph:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
  ```
  After each commit, check that the trailers parsed: `git -C WT log -1 "--format=%(trailers:key=Claude-Session,valueonly)"` must print the session URL.
- **Tests:** `swift test --package-path WT --filter <SuiteName>` with the exact suite names given. Every new test lives in a `@Suite struct`, and the suite name is the filter. The first build in a fresh worktree is slow: use a 600000 ms timeout.
- **File ownership (spec §6):** lane B owns `Sources/ReTiCAInterfaces/Meshtastic/*` (new), `Sources/ReTiCANode/MeshtasticEndpoint.swift` (new), `Sources/ReTiCANode/TransportEndpoint.swift`, new test files and fixtures, and the `ReTiCAInterfacesTests` `resources:` line of `Package.swift`. **Do not touch** `LinkSession.swift`, `LinkPlane.swift`, `Transport.swift`, `LXMFRouter.swift`, `LXMFDelivery.swift` or `LXMFNode.swift` (lane C). No other `Package.swift` change: no new dependency, no new target. No ReTiCA code imports MeshtasticKit or any protobuf.
- **`InterfaceProfile.swift` is not modified.** `InterfaceProfile.meshtastic(modemPreset:)` is defined as an extension in `Sources/ReTiCANode/MeshtasticEndpoint.swift`, with exactly the Contract 3 signature. Reason: the preset→delay table must be shared with `MeshtasticInterface` (in `ReTiCAInterfaces`), and `ReTiCATransport` and `ReTiCAInterfaces` do not depend on each other (`Package.swift:27-34, 50-58`). Contract-issue report item 1.
- **Contract constants, verbatim from the spec:**
  - Port 76 belongs to the live adapter, not lane B.
  - Fragment body bound 200 (split `n = len/200 + 1`, `size = len/n + 1`).
  - Max frame 233 bytes (Meshtastic `DATA_PAYLOAD_LEN`). REQ = ASCII `"REQ"` + `[index][pos]`, exactly 5 bytes.
  - Reassembly: 30 s inactivity, ≤ 8 buffers per sender, ≤ 64 total, packets > 508 B dropped.
  - Sender: FIFO cap 256, all-or-nothing enqueue, REQ cache of the last 16 packets, never emit REQ.
  - Delays in ms: preset 8 → 400, 6 → 1000, 5 → 3000, 4 → 4000, 3 → 6000, 0 → 8000, 7 → 12000, 1 → 15000, anything else or nil → 7000.
  - Bitrate `= 202·8·1000 / delayMs` (integer division): 4040 / 1616 / 538 / 404 / 269 / 202 / 134 / 107 / 230.
  - Profile: name `"meshtastic"`, `hwMTU` 500, mode = the `.tcp` default (`.full`), IFAC size 8.
  - Interface id `"meshtastic:<UUID>"` using `UUID.uuidString`.
  - The live value is LOUD: it emits exactly `.unavailable(.other("ReTiCAMeshtasticLive not installed"))` and finishes.
- **TCA rules in this repo:**
  - `Effect.cancel(id:)` cancels at construction (`TCA Effect.cancel is eager`). Only ever build it inside the `return` of the arm that means it, never in a stored `let`.
  - Prefer non-exhaustive (`exhaustivity = .off`) TestStores that assert outcomes.
  - `\.date`/`\.continuousClock` testValues are unimplemented. This plan adds custom keys `\.meshtasticDate` and `\.meshtasticClock`.
  - Transport/LXMF timers in tests use a `TestClock` that is never advanced, unless the test is about them.
  - After large changes, a signal-11 or stale-link test failure means `swift package clean --package-path WT`, then rerun.
- **Test-name discipline:** a test name states ONE claim, and that claim is what its assertions and mutation target. No "X and Y" names.
- **Test-module name collisions:** `ReTiCAInterfacesTests` already has top-level `MockDriverCall`, `localIdentity`, `makeStore`, `frags`, `channel1`…  (`Tests/ReTiCAInterfacesTests/BLEInterfaceTests.swift:6-33`). Every new top-level test helper is either `private` or prefixed `mesh`/`Mesh`.
- **Relayed facts:** citations in this plan were read on 2026-10-16 against `main` at `91a80b5`. If a cited line does not say what the plan claims, stop and report it. Do not adapt silently.

## Review Focus

1. **A pos byte of `0x80` (`Int8.min`, −128)** from a buggy or hostile radio peer must not trap anywhere: not in parse, not in reassembly, not in REQ answering. `abs(Int8.min)` overflows. Pinned by `parseReadsInt8MinPosition` (Task 2), `int8MinPositionDoesNotTrap` (Task 3) and `requestWithPositionInt8MinIsIgnored` (Task 6).
2. **Frames delivered as non-zero-based `Data` slices** (a driver that slices a protobuf payload) must parse and split exactly like fresh `Data`. Pinned by `parseHandlesANonZeroBasedSlice` and `splitHandlesANonZeroBasedSlice` (Task 2).
3. **A burst of identical REQs** must not grow the send queue without bound. Any peer can broadcast REQs, and landandair re-REQs on every unexpected fragment (Meshtastic_Interface.py:251-258). A fragment is queued at most once. Pinned by `repeatedRequestQueuesTheFragmentOnce` (Task 6).
4. **A REQ naming an index we never sent, or a position past that packet's last fragment,** must be ignored, not indexed out of range. Pinned by `requestForAnIndexNeverSentIsIgnored` and `requestPastThePacketsLastFragmentIsIgnored` (Task 6).
5. **The packet index wraps from 255 to 0 without trapping, and a REQ after the wrap is answered from the newest packet with that index**, not a stale one. Pinned by `packetIndexWrapsFrom255To0` and `requestAfterTheWrapIsAnsweredFromTheNewestPacket` (Task 6).

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/ReTiCAInterfaces/Meshtastic/MeshtasticDriver.swift` (new) | Contract 2: `MeshtasticDriverConfig`, `MeshtasticDriverEvent`, `MeshtasticDriver`, DependencyKey (loud live, unimplemented test), `\.meshtasticDriver`, `\.meshtasticDate`, `\.meshtasticClock` |
| `Sources/ReTiCAInterfaces/Meshtastic/MeshtasticModemPreset.swift` (new) | The one preset → fragment-delay table (landandair `speed_to_delay`) and the derived paced bitrate |
| `Sources/ReTiCAInterfaces/Meshtastic/MeshtasticFragmentCodec.swift` (new) | `MeshtasticFragmentCodec` protocol, `MeshtasticFrame`, `LandandairCodec`, `MeshtasticFraming` (the swappable seam) |
| `Sources/ReTiCAInterfaces/Meshtastic/MeshtasticReassembler.swift` (new) | Pure, bounded reassembly keyed by (sender, index), with counters |
| `Sources/ReTiCAInterfaces/Meshtastic/MeshtasticInterface.swift` (new) | TCA reducer: driver lifecycle, inbound reassembly, paced sender, REQ answering |
| `Sources/ReTiCANode/MeshtasticEndpoint.swift` (new) | `meshtasticInterfaceID(radio:)`, `InterfaceProfile.meshtastic(modemPreset:)`, `MeshtasticEndpoint` driver wrapper, IFAC-8 helper |
| `Sources/ReTiCANode/TransportEndpoint.swift` (modify) | `meshtastic` slot, action, start/stop, lifecycle arms, transmit routing, `.interfaceUnavailable` guard, `.ifLet` |
| `Package.swift:48` (modify) | `ReTiCAInterfacesTests` resources: add the two Meshtastic fixture JSONs |
| `Tests/ReTiCAInterfacesTests/Vectors/landandair_Meshtastic_Interface.py` (new, copied verbatim) | The genuine reference implementation the generator drives |
| `Tests/ReTiCAInterfacesTests/Vectors/generate_meshtastic_fixtures.py` (new) | Drives landandair's `PacketHandler`/`MeshtasticInterface` both directions → `meshtastic_fixtures.json` |
| `Tests/ReTiCAInterfacesTests/Vectors/meshtastic_our_split.json` (new, generated by Swift) | Our codec's split, fed to the reference by the generator |
| `Tests/ReTiCAInterfacesTests/Vectors/meshtastic_fixtures.json` (new, generated by Python) | Reference outputs |
| `Tests/ReTiCAInterfacesTests/MeshtasticDriverTests.swift` | Suite `MeshtasticDriverTests` |
| `Tests/ReTiCAInterfacesTests/MeshtasticCodecTests.swift` | Suite `MeshtasticCodecTests` |
| `Tests/ReTiCAInterfacesTests/MeshtasticReassemblerTests.swift` | Suite `MeshtasticReassemblerTests` |
| `Tests/ReTiCAInterfacesTests/MeshtasticFixtureSupport.swift` | Hex helpers, the shared packet pattern, fixture decoders |
| `Tests/ReTiCAInterfacesTests/MeshtasticCrossValidationTests.swift` | Suites `MeshtasticCrossValidationTests`, `MeshtasticOurSplitEmitter` |
| `Tests/ReTiCAInterfacesTests/MeshtasticInterfaceTestSupport.swift` | Mock driver harness for the reducer |
| `Tests/ReTiCAInterfacesTests/MeshtasticInterfaceLifecycleTests.swift` | Suite `MeshtasticInterfaceLifecycleTests` |
| `Tests/ReTiCAInterfacesTests/MeshtasticInterfaceSenderTests.swift` | Suite `MeshtasticInterfaceSenderTests` |
| `Tests/ReTiCANodeTests/MeshtasticEndpointTests.swift` | Suite `MeshtasticEndpointTests` |
| `Tests/ReTiCANodeTests/TransportEndpointMeshtasticTests.swift` | Suites `TransportEndpointMeshtasticTests`, `TransportEndpointMeshtasticMaintenanceTests` |
| `Tests/ReTiCANodeTests/MeshtasticWholeSliceTests.swift` | Suite `MeshtasticWholeSliceTests` |

---

### Task 1: Worktree, driver contract, preset table

**Files:**
- Create: `Sources/ReTiCAInterfaces/Meshtastic/MeshtasticDriver.swift`
- Create: `Sources/ReTiCAInterfaces/Meshtastic/MeshtasticModemPreset.swift`
- Test: `Tests/ReTiCAInterfacesTests/MeshtasticDriverTests.swift`

**Interfaces:**
- Consumes: `BLEAdapterUnavailable` (`Sources/ReTiCAInterfaces/BLEDriver.swift:30-42`); `DateGenerator`, `UnimplementedClock`, `unimplemented` (re-exported by ComposableArchitecture).
- Produces:
  - `public struct MeshtasticDriverConfig: Equatable, Sendable { radio: UUID; channel: UInt32 = 0; hopLimit: UInt32 = 1; init(radio:channel:hopLimit:) }`
  - `public enum MeshtasticDriverEvent: Equatable, Sendable { connected(myNodeNum: UInt32, modemPreset: Int?), disconnected(reason: String?), fragment(from: UInt32, Data), unavailable(BLEAdapterUnavailable) }`
  - `public struct MeshtasticDriver: Sendable { start: @Sendable (MeshtasticDriverConfig) -> AsyncStream<MeshtasticDriverEvent>; send: @Sendable (Data) async -> Bool; stop: @Sendable () async -> Void; init(start:send:stop:) }`
  - `MeshtasticDriver.liveAdapterMissing: String`
  - `DependencyValues.meshtasticDriver`, `.meshtasticDate: DateGenerator`, `.meshtasticClock: any Clock<Duration>`
  - `public enum MeshtasticModemPreset { static func fragmentDelayMilliseconds(_: Int?) -> Int; static func fragmentDelay(_: Int?) -> Duration; static func pacedBitrate(_: Int?) -> Int }`

- [ ] **Step 1: Create the worktree**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA worktree add ../ReTiCA-worktrees/meshtastic-interface -b meshtastic-interface`
Expected: `Preparing worktree (new branch 'meshtastic-interface')`.

Run: `mkdir -p /tmp/meshtastic-interface`

Run (timeout 600000): `swift build --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface`
Expected: `Build complete!`. This proves `../FCB` resolves from the worktree.

- [ ] **Step 2: Write the failing test**

Create `Tests/ReTiCAInterfacesTests/MeshtasticDriverTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

@Suite struct MeshtasticDriverTests {
    /// Contract 2: an app that forgot to install `ReTiCAMeshtasticLive` must hear about it, not
    /// get a radio that silently never connects.
    @Test func liveValueReportsTheMissingLiveAdapterLoudly() async {
        var events: [MeshtasticDriverEvent] = []
        for await event in MeshtasticDriver.liveValue.start(MeshtasticDriverConfig(radio: UUID())) {
            events.append(event)
        }
        #expect(events == [.unavailable(.other("ReTiCAMeshtasticLive not installed"))])
    }

    @Test func liveValueSendReportsFailure() async {
        #expect(await MeshtasticDriver.liveValue.send(Data([0x01])) == false)
    }

    /// landandair `speed_to_delay` verbatim, including its fallback of 7 s
    /// (Meshtastic_Interface.py:31-39, 281).
    @Test func fragmentDelayIsLandandairsSpeedToDelay() {
        let rows: [(Int?, Duration)] = [
            (8, .milliseconds(400)), (6, .seconds(1)), (5, .seconds(3)), (7, .seconds(12)),
            (4, .seconds(4)), (3, .seconds(6)), (1, .seconds(15)), (0, .seconds(8)),
            (2, .seconds(7)), (99, .seconds(7)), (nil, .seconds(7)),
        ]
        for (preset, delay) in rows {
            #expect(MeshtasticModemPreset.fragmentDelay(preset) == delay,
                    "preset \(String(describing: preset))")
        }
    }

    /// Contract 3's bitrate column: `Int(202 * 8 / fragmentDelay(preset))`.
    @Test func pacedBitrateMatchesTheContractTable() {
        let rows: [(Int?, Int)] = [
            (8, 4040), (6, 1616), (5, 538), (4, 404), (3, 269),
            (0, 202), (7, 134), (1, 107), (2, 230), (nil, 230),
        ]
        for (preset, bitrate) in rows {
            #expect(MeshtasticModemPreset.pacedBitrate(preset) == bitrate,
                    "preset \(String(describing: preset))")
        }
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter MeshtasticDriverTests`
Expected: build FAILS with `cannot find 'MeshtasticDriver' in scope`.

- [ ] **Step 4: Write the driver contract**

Create `Sources/ReTiCAInterfaces/Meshtastic/MeshtasticDriver.swift`:

```swift
import Foundation
import ComposableArchitecture

/// What the live adapter needs to talk to ONE radio. Channel 0 and hop limit 1 are landandair's
/// defaults (Meshtastic_Interface.py:95, 302).
public struct MeshtasticDriverConfig: Equatable, Sendable {
    public var radio: UUID
    public var channel: UInt32 = 0
    public var hopLimit: UInt32 = 1

    public init(radio: UUID, channel: UInt32 = 0, hopLimit: UInt32 = 1) {
        self.radio = radio
        self.channel = channel
        self.hopLimit = hopLimit
    }
}

public enum MeshtasticDriverEvent: Equatable, Sendable {
    /// The radio finished its configuration handshake. Emitted again after every reconnect.
    /// `modemPreset` is the raw `Config.LoRaConfig.ModemPreset` value, nil when unknown.
    case connected(myNodeNum: UInt32, modemPreset: Int?)
    case disconnected(reason: String?)
    /// A port-76 payload from another node. The live adapter has already dropped from == myNodeNum.
    case fragment(from: UInt32, Data)
    case unavailable(BLEAdapterUnavailable)
}

/// Meshtastic radio dependency (spec Contract 2). Mechanism only: no fragmentation, no pacing,
/// no retries — reconnecting is MeshtasticKit's job, so the interface just sees repeated
/// `connected`/`disconnected`. The live value lives in the `ReTiCAMeshtasticLive` target (lane E),
/// installed by the app with `$0.meshtasticDriver = .live(session:)`.
public struct MeshtasticDriver: Sendable {
    public var start: @Sendable (MeshtasticDriverConfig) -> AsyncStream<MeshtasticDriverEvent>
    /// One already-framed fragment, sent on port 76 to broadcast with the config's channel/hopLimit,
    /// wantAck false. Returns false if the radio is not connected or the write failed.
    public var send: @Sendable (Data) async -> Bool
    public var stop: @Sendable () async -> Void

    public init(start: @escaping @Sendable (MeshtasticDriverConfig) -> AsyncStream<MeshtasticDriverEvent>,
                send: @escaping @Sendable (Data) async -> Bool,
                stop: @escaping @Sendable () async -> Void) {
        self.start = start
        self.send = send
        self.stop = stop
    }
}

extension MeshtasticDriver: DependencyKey {
    /// The cause the default live value reports. Not a silent no-op: an app that never installed
    /// the live adapter sees `.adapterUnavailable(.other(liveAdapterMissing))` on the first start.
    public static let liveAdapterMissing = "ReTiCAMeshtasticLive not installed"

    public static var liveValue: MeshtasticDriver {
        MeshtasticDriver(
            start: { _ in
                AsyncStream { continuation in
                    continuation.yield(.unavailable(.other(liveAdapterMissing)))
                    continuation.finish()
                }
            },
            send: { _ in false },
            stop: {}
        )
    }

    public static let testValue = MeshtasticDriver(
        start: unimplemented("MeshtasticDriver.start", placeholder: AsyncStream { $0.finish() }),
        send: unimplemented("MeshtasticDriver.send", placeholder: false),
        stop: unimplemented("MeshtasticDriver.stop")
    )
}

extension DependencyValues {
    public var meshtasticDriver: MeshtasticDriver {
        get { self[MeshtasticDriver.self] }
        set { self[MeshtasticDriver.self] = newValue }
    }
}

// "now" for reassembly inactivity. \.date's testValue is unimplemented in this TCA version, so a
// custom key — the \.bleDate pattern (BLEDriver.swift:136-148).
private enum MeshtasticDateKey: DependencyKey {
    static let liveValue = DateGenerator { Date() }
    static let testValue = DateGenerator { Date(timeIntervalSince1970: 0) }
    static let previewValue = liveValue
}

// The sender's pacing clock. Separate from \.continuousClock on purpose: a test can pace fragments
// on an ImmediateClock while Transport's maintenance loop and LXMF's retry timers sit on a
// TestClock that is never advanced (an ImmediateClock under the maintenance loop spins it hot).
private enum MeshtasticClockKey: DependencyKey {
    static var liveValue: any Clock<Duration> { ContinuousClock() }
    static var testValue: any Clock<Duration> { UnimplementedClock(name: "meshtasticClock") }
}

extension DependencyValues {
    public var meshtasticDate: DateGenerator {
        get { self[MeshtasticDateKey.self] }
        set { self[MeshtasticDateKey.self] = newValue }
    }

    public var meshtasticClock: any Clock<Duration> {
        get { self[MeshtasticClockKey.self] }
        set { self[MeshtasticClockKey.self] = newValue }
    }
}
```

- [ ] **Step 5: Write the preset table**

Create `Sources/ReTiCAInterfaces/Meshtastic/MeshtasticModemPreset.swift`:

```swift
import Foundation

/// The ONE source of truth for how fast a Meshtastic radio may be fed, keyed by the raw
/// `Config.LoRaConfig.ModemPreset` value. Both the sender's pacing (`MeshtasticInterface`) and the
/// interface's declared bitrate (`InterfaceProfile.meshtastic(modemPreset:)`) derive from it.
public enum MeshtasticModemPreset {
    /// landandair `speed_to_delay` verbatim (Meshtastic_Interface.py:31-39), in milliseconds so
    /// the bitrate arithmetic below is exact integer division.
    static let delayTable: [Int: Int] = [
        8: 400,      // ShortTurbo
        6: 1_000,    // ShortFast
        5: 3_000,    // ShortSlow
        7: 12_000,   // LongModerate
        4: 4_000,    // MediumFast
        3: 6_000,    // MediumSlow
        1: 15_000,   // LongSlow
        0: 8_000,    // LongFast
    ]
    /// landandair's fallback for an unlisted preset (`... else 7`, Meshtastic_Interface.py:281).
    static let fallbackDelayMilliseconds = 7_000
    /// Bytes per paced fragment in the bitrate formula: a 200-byte body plus the 2-byte header.
    static let pacedFrameBytes = 202

    public static func fragmentDelayMilliseconds(_ preset: Int?) -> Int {
        preset.flatMap { delayTable[$0] } ?? fallbackDelayMilliseconds
    }

    public static func fragmentDelay(_ preset: Int?) -> Duration {
        .milliseconds(fragmentDelayMilliseconds(preset))
    }

    /// Effective paced bitrate, `Int(202 * 8 / delaySeconds)` (spec Contract 3).
    public static func pacedBitrate(_ preset: Int?) -> Int {
        pacedFrameBytes * 8 * 1_000 / fragmentDelayMilliseconds(preset)
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass (rule step a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter MeshtasticDriverTests`
Expected: 4 tests pass.

- [ ] **Step 7: Mutate in one batch (rule step b)**

Apply all four mutations, then run the same command. Expected: all 4 tests FAIL.

| Mutation (file) | Breaks |
|---|---|
| `MeshtasticDriver.swift`: `liveAdapterMissing = "ReTiCAMeshtasticLive missing"` | `liveValueReportsTheMissingLiveAdapterLoudly` |
| `MeshtasticDriver.swift`: liveValue `send: { _ in true }` | `liveValueSendReportsFailure` |
| `MeshtasticModemPreset.swift`: `fallbackDelayMilliseconds = 8_000` | `fragmentDelayIsLandandairsSpeedToDelay` (rows 2/99/nil) |
| `MeshtasticModemPreset.swift`: `pacedFrameBytes = 200` | `pacedBitrateMatchesTheContractTable` |

- [ ] **Step 8: Revert and re-run (rule step c)**

Revert the four edits with the Edit tool, run the same command. Expected: 4 pass.

- [ ] **Step 9: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface add Sources/ReTiCAInterfaces/Meshtastic/MeshtasticDriver.swift Sources/ReTiCAInterfaces/Meshtastic/MeshtasticModemPreset.swift Tests/ReTiCAInterfacesTests/MeshtasticDriverTests.swift`

Write `/tmp/meshtastic-interface/commit-task-1.txt`:

```
feat: Meshtastic driver contract and modem-preset pacing table

MeshtasticDriver (spec Contract 2) with a loud live value that reports
"ReTiCAMeshtasticLive not installed" instead of silently never connecting,
custom \.meshtasticDate / \.meshtasticClock keys, and landandair's
speed_to_delay table as the single source for pacing and paced bitrate.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface commit -F /tmp/meshtastic-interface/commit-task-1.txt`
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface log -1 "--format=%(trailers:key=Claude-Session,valueonly)"`
Expected: `https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm`.

---

### Task 2: Fragment codec (`LandandairCodec`)

**Files:**
- Create: `Sources/ReTiCAInterfaces/Meshtastic/MeshtasticFragmentCodec.swift`
- Test: `Tests/ReTiCAInterfacesTests/MeshtasticCodecTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `public protocol MeshtasticFragmentCodec: Sendable { func split(_ packet: Data, index: UInt8) -> [Data]; func parse(_ frame: Data) -> MeshtasticFrame? }`
  - `public enum MeshtasticFrame: Equatable, Sendable { case data(index: UInt8, pos: Int8, body: Data); case request(index: UInt8, pos: Int8) }`
  - `public struct LandandairCodec: MeshtasticFragmentCodec, Equatable { init(); static let maxBody = 200; static let maxFrameLength = 233; static let maxFragments = 128; static let requestPrefix: Data }`
  - `public enum MeshtasticFraming: Equatable, Sendable { case landandair; var codec: any MeshtasticFragmentCodec }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCAInterfacesTests/MeshtasticCodecTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCAInterfaces

private func ramp(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }) }

@Suite struct MeshtasticCodecTests {
    private let codec = LandandairCodec()

    /// Spec §5.1: n = len/200 + 1; size = len/n + 1; chunks stepping by size.
    @Test func splitBodySizesFollowLandandairsArithmetic() {
        let rows: [(Int, [Int])] = [
            (1, [1]), (199, [199]), (200, [101, 99]), (201, [101, 100]),
            (400, [134, 134, 132]), (500, [167, 167, 166]), (508, [170, 170, 168]),
        ]
        for (length, sizes) in rows {
            #expect(codec.split(ramp(length), index: 0).map { $0.count - 2 } == sizes, "length \(length)")
        }
    }

    @Test func splitBodiesConcatenateToThePacket() {
        for length in [1, 199, 200, 201, 400, 500, 508] {
            let packet = ramp(length)
            let joined = codec.split(packet, index: 0).reduce(into: Data()) { $0.append($1.dropFirst(2)) }
            #expect(joined == packet, "length \(length)")
        }
    }

    @Test func splitHeadersCarryTheIndexAndOneBasedPositionsWithTheLastNegated() {
        let headers = codec.split(ramp(500), index: 9).map { Array($0.prefix(2)) }
        #expect(headers == [[9, 1], [9, 2], [9, 0xFD]])
    }

    @Test func singleFragmentPacketCarriesPositionMinusOne() {
        #expect(codec.split(ramp(199), index: 4).map { Array($0.prefix(2)) } == [[4, 0xFF]])
    }

    /// 128 fragments is the most a signed pos byte can number (1...127, last −128).
    @Test func splitRefusesMoreThan128Fragments() {
        let largest = codec.split(ramp(25_400), index: 0)
        #expect(largest.count == 128)
        #expect(largest.last?.dropFirst().first == 0x80)
        #expect(codec.split(ramp(25_600), index: 0).isEmpty)
    }

    @Test func parseReadsADataFrame() {
        #expect(codec.parse(Data([7, 0xFE, 1, 2, 3])) == .data(index: 7, pos: -2, body: Data([1, 2, 3])))
    }

    @Test func parseReadsARequestFrame() {
        #expect(codec.parse(Data("REQ".utf8) + Data([3, 2])) == .request(index: 3, pos: 2))
    }

    /// Spec §5.1: only a 5-byte frame with a "REQ" prefix is a request.
    @Test func requestPrefixOfAnyOtherLengthIsData() {
        let frame = Data("REQ".utf8) + Data([3, 2, 9])
        #expect(codec.parse(frame) == .data(index: 0x52, pos: 0x45, body: Data("Q".utf8) + Data([3, 2, 9])))
    }

    @Test func parseRejectsFramesShorterThanThreeBytes() {
        #expect(codec.parse(Data()) == nil)
        #expect(codec.parse(Data([1])) == nil)
        #expect(codec.parse(Data([1, 0xFF])) == nil)
    }

    @Test func parseRejectsPositionZero() {
        #expect(codec.parse(Data([1, 0, 5])) == nil)
        #expect(codec.parse(Data("REQ".utf8) + Data([1, 0])) == nil)
    }

    @Test func parseRejectsFramesOver233Bytes() {
        #expect(codec.parse(Data([1, 0xFF]) + Data(repeating: 0xAB, count: 232)) == nil)   // 234
        #expect(codec.parse(Data([1, 0xFF]) + Data(repeating: 0xAB, count: 231)) != nil)   // 233
    }

    // Review Focus 1 — trap-class (step b′).
    @Test func parseReadsInt8MinPosition() {
        #expect(codec.parse(Data([1, 0x80, 9])) == .data(index: 1, pos: .min, body: Data([9])))
    }

    // Review Focus 2 — trap-class (step b′).
    @Test func parseHandlesANonZeroBasedSlice() {
        let backing = Data([0xAA, 0xBB, 7, 0xFF, 1, 2])
        #expect(codec.parse(backing.dropFirst(2)) == .data(index: 7, pos: -1, body: Data([1, 2])))
        let request = Data([0xAA, 0xBB]) + Data("REQ".utf8) + Data([3, 2])
        #expect(codec.parse(request.dropFirst(2)) == .request(index: 3, pos: 2))
    }

    // Review Focus 2 — trap-class (step b′).
    @Test func splitHandlesANonZeroBasedSlice() {
        let backing = ramp(350)
        #expect(codec.split(backing.dropFirst(50), index: 3) == codec.split(Data(backing.dropFirst(50)), index: 3))
    }

    @Test func landandairFramingVendsTheLandandairCodec() {
        #expect(MeshtasticFraming.landandair.codec.split(ramp(300), index: 1) == codec.split(ramp(300), index: 1))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter MeshtasticCodecTests`
Expected: build FAILS with `cannot find 'LandandairCodec' in scope`.

- [ ] **Step 3: Implement the codec**

Create `Sources/ReTiCAInterfaces/Meshtastic/MeshtasticFragmentCodec.swift`:

```swift
import Foundation

/// The seam between the interface and an on-air fragment format (spec §5.1). v1 ships one
/// implementation, `LandandairCodec`; a sturdier format can be added as another conformer without
/// touching the reassembler or the sender.
public protocol MeshtasticFragmentCodec: Sendable {
    /// Framed fragments for one packet, in send order. Empty when the packet cannot be framed.
    func split(_ packet: Data, index: UInt8) -> [Data]
    /// nil = malformed.
    func parse(_ frame: Data) -> MeshtasticFrame?
}

public enum MeshtasticFrame: Equatable, Sendable {
    case data(index: UInt8, pos: Int8, body: Data)
    case request(index: UInt8, pos: Int8)
}

/// Which codec an interface speaks. An enum (not an existential) so interface state stays Equatable.
public enum MeshtasticFraming: Equatable, Sendable {
    case landandair

    public var codec: any MeshtasticFragmentCodec {
        switch self {
        case .landandair: return LandandairCodec()
        }
    }
}

/// landandair/RNS_Over_Meshtastic's format, byte-exact (`PacketHandler`, Meshtastic_Interface.py:
/// 332-416). Data frame `[index: UInt8][pos: Int8][body]`, `pos` 1-based with the LAST negated
/// (a single fragment is −1). Request frame: ASCII "REQ" + `[index][pos]`.
public struct LandandairCodec: MeshtasticFragmentCodec, Equatable {
    /// `max_payload` (Meshtastic_Interface.py:335).
    public static let maxBody = 200
    /// Meshtastic `DATA_PAYLOAD_LEN`.
    public static let maxFrameLength = 233
    /// A signed pos byte numbers at most 1...127 plus a final −128.
    public static let maxFragments = 128
    public static let requestPrefix = Data("REQ".utf8)

    public init() {}

    public func split(_ packet: Data, index: UInt8) -> [Data] {
        let data = Data(packet)   // 0-based: a caller's slice must not shift our indices
        let length = data.count
        let count = length / Self.maxBody + 1
        let size = length / count + 1
        let starts = Array(stride(from: 0, to: length, by: size))
        guard starts.count <= Self.maxFragments else { return [] }
        return starts.enumerated().map { offset, start in
            let pos = offset + 1
            let signed = pos == starts.count ? -pos : pos
            var frame = Data([index, UInt8(bitPattern: Int8(signed))])
            frame.append(data[start ..< min(start + size, length)])
            return frame
        }
    }

    public func parse(_ frameInput: Data) -> MeshtasticFrame? {
        let frame = Data(frameInput)   // 0-based: drivers may hand over a slice
        guard frame.count >= 3, frame.count <= Self.maxFrameLength else { return nil }
        // A data frame can only start "REQ" with index 0x52 and pos 0x45 (= 69 fragments), which
        // no packet ≤ 508 B produces — so the 5-byte length check is what disambiguates.
        if frame.count == 5, frame.prefix(3) == Self.requestPrefix {
            let pos = Int8(bitPattern: frame[4])
            guard pos != 0 else { return nil }
            return .request(index: frame[3], pos: pos)
        }
        let pos = Int8(bitPattern: frame[1])
        guard pos != 0 else { return nil }
        return .data(index: frame[0], pos: pos, body: Data(frame.dropFirst(2)))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass (rule step a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter MeshtasticCodecTests`
Expected: 15 tests pass.

- [ ] **Step 5: Mutate in one batch (rule step b)**

Apply all of these together, run the same command, and confirm every listed test FAILS:

| Mutation in `MeshtasticFragmentCodec.swift` | Breaks |
|---|---|
| `split`: `let size = length / count + 2` | `splitBodySizesFollowLandandairsArithmetic` |
| `split`: body slice `data[start ..< min(start + size, length - 1)]` | `splitBodiesConcatenateToThePacket` |
| `split`: `let signed = pos` (last not negated) | `splitHeadersCarryTheIndexAndOneBasedPositionsWithTheLastNegated`, `singleFragmentPacketCarriesPositionMinusOne` |
| `split`: `guard starts.count <= 127` | `splitRefusesMoreThan128Fragments` |
| `parse`: `if frame.count == 6, ...` | `parseReadsARequestFrame`, `requestPrefixOfAnyOtherLengthIsData` |
| `parse`: `guard frame.count >= 2, ...` | `parseRejectsFramesShorterThanThreeBytes` |
| `parse`: delete both `guard pos != 0 else { return nil }` lines | `parseRejectsPositionZero` |
| `parse`: `frame.count <= Self.maxFrameLength + 1` | `parseRejectsFramesOver233Bytes` |
| `MeshtasticFraming.codec`: `return LandandairCodec()` → return a private `struct Wrong: MeshtasticFragmentCodec { func split(_ p: Data, index: UInt8) -> [Data] { [] }; func parse(_ f: Data) -> MeshtasticFrame? { nil } }` instance | `landandairFramingVendsTheLandandairCodec` |
| `parse` data branch: `body: Data(frame.dropFirst(1))` | `parseReadsADataFrame` |

The trap-class tests (`parseReadsInt8MinPosition`, `parseHandlesANonZeroBasedSlice`, `splitHandlesANonZeroBasedSlice`) may also fail under these rows. That is fine: their own verification is step 6.

- [ ] **Step 6: Trap-class mutations, one at a time (rule step b′)**

For each row: apply the mutation alone, run `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter <testName>`, confirm the run FAILS (crash or assertion), then revert.

| Test | Mutation alone |
|---|---|
| `parseReadsInt8MinPosition` | `parse` data branch: `let pos = Int8(frame[1])` (traps on any byte ≥ 0x80) |
| `parseHandlesANonZeroBasedSlice` | `parse`: `let frame = frameInput` |
| `splitHandlesANonZeroBasedSlice` | `split`: `let data = packet` |

- [ ] **Step 7: Revert and re-run (rule step c)**

Revert all step-5 mutations. Run the step-4 command. Expected: 15 pass.

- [ ] **Step 8: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface add Sources/ReTiCAInterfaces/Meshtastic/MeshtasticFragmentCodec.swift Tests/ReTiCAInterfacesTests/MeshtasticCodecTests.swift`

Write `/tmp/meshtastic-interface/commit-task-2.txt`:

```
feat: landandair Meshtastic fragment codec behind a swappable seam

Byte-exact [index][pos][body] split/parse with the REQ frame recognised
only at exactly 5 bytes; malformed frames (short, pos 0, > 233 B) parse
to nil, and slices and Int8.min positions never trap.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface commit -F /tmp/meshtastic-interface/commit-task-2.txt`
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface log -1 "--format=%(trailers:key=Claude-Session,valueonly)"`

---

### Task 3: Reassembler (`MeshtasticReassembler`)

**Files:**
- Create: `Sources/ReTiCAInterfaces/Meshtastic/MeshtasticReassembler.swift`
- Test: `Tests/ReTiCAInterfacesTests/MeshtasticReassemblerTests.swift`

**Interfaces:**
- Consumes: `LandandairCodec` (Task 2), used by tests only.
- Produces:
  ```swift
  public struct MeshtasticReassembler: Equatable, Sendable {
      public static let inactivityTimeout: TimeInterval   // 30
      public static let maxBuffersPerSender: Int          // 8
      public static let maxBuffersTotal: Int              // 64
      public static let maxPacketLength: Int              // 508
      public struct Counters: Equatable, Sendable { malformed, evicted, timedOut, oversize, completed: Int }
      public private(set) var counters: Counters
      public var bufferCount: Int { get }
      public init()
      @discardableResult
      public mutating func receive(from: UInt32, index: UInt8, pos: Int8, body: Data, now: Date) -> Data?
      public mutating func recordMalformed()
      public mutating func reset()   // drops buffers, keeps counters
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCAInterfacesTests/MeshtasticReassemblerTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCAInterfaces

private struct Part { let index: UInt8; let pos: Int8; let body: Data }

private func ramp(_ count: Int, seed: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ seed) })
}

private func parts(_ packet: Data, index: UInt8) -> [Part] {
    let codec = LandandairCodec()
    var out: [Part] = []
    for frame in codec.split(packet, index: index) {
        if case let .data(i, p, b)? = codec.parse(frame) { out.append(Part(index: i, pos: p, body: b)) }
    }
    return out
}

private let t0 = Date(timeIntervalSince1970: 1_000)

extension MeshtasticReassembler {
    @discardableResult
    fileprivate mutating func feed(_ part: Part, from: UInt32 = 1, at now: Date = t0) -> Data? {
        receive(from: from, index: part.index, pos: part.pos, body: part.body, now: now)
    }
}

@Suite struct MeshtasticReassemblerTests {
    @Test func inOrderFragmentsCompleteOnTheLast() {
        var r = MeshtasticReassembler()
        let packet = ramp(500, seed: 1)
        let ps = parts(packet, index: 0)
        #expect(r.feed(ps[0]) == nil)
        #expect(r.feed(ps[1]) == nil)
        #expect(r.feed(ps[2]) == packet)
    }

    @Test func singleFragmentPacketCompletesAtOnce() {
        var r = MeshtasticReassembler()
        let packet = ramp(100, seed: 2)
        #expect(r.feed(parts(packet, index: 0)[0]) == packet)
    }

    /// The reference only assembles when the arriving fragment is the last (process_packet,
    /// Meshtastic_Interface.py:380-387); we also complete on a late middle fragment (spec §5.2).
    @Test func lateMiddleFragmentCompletesThePacket() {
        var r = MeshtasticReassembler()
        let packet = ramp(500, seed: 3)
        let ps = parts(packet, index: 0)
        r.feed(ps[0])
        r.feed(ps[2])
        #expect(r.feed(ps[1]) == packet)
    }

    @Test func lastFragmentFirstStillCompletes() {
        var r = MeshtasticReassembler()
        let packet = ramp(500, seed: 4)
        let ps = parts(packet, index: 0)
        #expect(r.feed(ps[2]) == nil)
        #expect(r.feed(ps[0]) == nil)
        #expect(r.feed(ps[1]) == packet)
    }

    @Test func interleavedSendersReassembleIndependently() {
        var r = MeshtasticReassembler()
        let a = ramp(500, seed: 5), b = ramp(500, seed: 6)
        let pa = parts(a, index: 0), pb = parts(b, index: 0)
        r.feed(pa[0], from: 1); r.feed(pb[0], from: 2)
        r.feed(pa[1], from: 1); r.feed(pb[1], from: 2)
        #expect(r.feed(pa[2], from: 1) == a)
        #expect(r.feed(pb[2], from: 2) == b)
    }

    @Test func interleavedIndicesFromOneSenderReassembleIndependently() {
        var r = MeshtasticReassembler()
        let a = ramp(500, seed: 7), b = ramp(500, seed: 8)
        let pa = parts(a, index: 0), pb = parts(b, index: 1)
        r.feed(pa[0]); r.feed(pb[0]); r.feed(pa[1]); r.feed(pb[1])
        #expect(r.feed(pa[2]) == a)
        #expect(r.feed(pb[2]) == b)
    }

    @Test func duplicateFragmentDoesNotDisturbReassembly() {
        var r = MeshtasticReassembler()
        let packet = ramp(500, seed: 9)
        let ps = parts(packet, index: 0)
        r.feed(ps[0]); r.feed(ps[0]); r.feed(ps[1])
        #expect(r.feed(ps[2]) == packet)
        #expect(r.counters.completed == 1)
    }

    /// x1, x2, then y1 conflicts at position 1 → the buffer restarts holding only y1, so x's last
    /// fragment cannot complete a y1+x2+x3 chimera.
    @Test func conflictingBodyRestartsTheBufferWithOnlyTheNewFragment() {
        var r = MeshtasticReassembler()
        let px = parts(ramp(500, seed: 10), index: 0), py = parts(ramp(500, seed: 11), index: 0)
        r.feed(px[0]); r.feed(px[1]); r.feed(py[0])
        #expect(r.feed(px[2]) == nil)
    }

    @Test func bufferIdleUnder30SecondsStillCompletes() {
        var r = MeshtasticReassembler()
        let packet = ramp(500, seed: 12)
        let ps = parts(packet, index: 0)
        r.feed(ps[0], at: t0); r.feed(ps[1], at: t0)
        #expect(r.feed(ps[2], at: t0.addingTimeInterval(29.9)) == packet)
    }

    @Test func bufferIdle30SecondsIsPurged() {
        var r = MeshtasticReassembler()
        let ps = parts(ramp(500, seed: 13), index: 0)
        r.feed(ps[0], at: t0); r.feed(ps[1], at: t0)
        #expect(r.feed(ps[2], at: t0.addingTimeInterval(30)) == nil)
        #expect(r.counters.timedOut == 1)
    }

    @Test func ninthBufferFromOneSenderEvictsItsOldest() {
        var r = MeshtasticReassembler()
        let packets = (0..<9).map { ramp(500, seed: 20 + $0) }
        let ps = packets.enumerated().map { parts($0.element, index: UInt8($0.offset)) }
        for i in 0..<9 { r.feed(ps[i][0], at: t0.addingTimeInterval(Double(i))) }
        #expect(r.bufferCount == 8)
        #expect(r.counters.evicted == 1)
        let later = t0.addingTimeInterval(10)
        r.feed(ps[0][1], at: later)
        #expect(r.feed(ps[0][2], at: later) == nil, "index 0 was the oldest and must have been evicted")
        r.feed(ps[8][1], at: later)
        #expect(r.feed(ps[8][2], at: later) == packets[8])
    }

    @Test func sixtyFifthBufferEvictsTheOldestOverall() {
        var r = MeshtasticReassembler()
        for sender in 1...65 {
            r.feed(parts(ramp(500, seed: sender), index: 0)[0], from: UInt32(sender),
                   at: t0.addingTimeInterval(Double(sender)))
        }
        #expect(r.bufferCount == 64)
        #expect(r.counters.evicted == 1)
    }

    @Test func packetOf508BytesCompletes() {
        var r = MeshtasticReassembler()
        let packet = ramp(508, seed: 30)
        var out: Data?
        for p in parts(packet, index: 0) { out = r.feed(p) }
        #expect(out == packet)
    }

    @Test func packetOver508BytesIsDroppedAsOversize() {
        var r = MeshtasticReassembler()
        var out: Data?
        for p in parts(ramp(509, seed: 31), index: 0) { out = r.feed(p) }
        #expect(out == nil)
        #expect(r.counters.oversize == 1)
    }

    @Test func completedCountsEachReassembledPacket() {
        var r = MeshtasticReassembler()
        r.feed(parts(ramp(100, seed: 40), index: 0)[0])
        r.feed(parts(ramp(100, seed: 41), index: 1)[0])
        #expect(r.counters.completed == 2)
    }

    @Test func positionZeroIsMalformed() {
        var r = MeshtasticReassembler()
        #expect(r.receive(from: 1, index: 0, pos: 0, body: Data([1]), now: t0) == nil)
        #expect(r.counters.malformed == 1)
    }

    @Test func emptyBodyIsMalformed() {
        var r = MeshtasticReassembler()
        #expect(r.receive(from: 1, index: 0, pos: -1, body: Data(), now: t0) == nil)
        #expect(r.counters.malformed == 1)
    }

    @Test func resetDropsEveryBuffer() {
        var r = MeshtasticReassembler()
        r.feed(parts(ramp(500, seed: 50), index: 0)[0])
        r.reset()
        #expect(r.bufferCount == 0)
    }

    @Test func resetKeepsCounters() {
        var r = MeshtasticReassembler()
        r.recordMalformed()
        r.reset()
        #expect(r.counters.malformed == 1)
    }

    // Review Focus 1 — trap-class (step b′).
    @Test func int8MinPositionDoesNotTrap() {
        var r = MeshtasticReassembler()
        #expect(r.receive(from: 1, index: 0, pos: .min, body: Data([1]), now: t0) == nil)
        #expect(r.bufferCount == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter MeshtasticReassemblerTests`
Expected: build FAILS with `cannot find 'MeshtasticReassembler' in scope`.

- [ ] **Step 3: Implement the reassembler**

Create `Sources/ReTiCAInterfaces/Meshtastic/MeshtasticReassembler.swift`:

```swift
import Foundation

/// Bounded reassembly of landandair fragments (spec §5.2). Pure value type. NOT `BLEReassembler`:
/// that keys buffers by fragment count only, so two interleaved packets from one sender with
/// equal counts corrupt each other.
///
/// Buffers are keyed by (sending node, packet index). Positions are stored by magnitude; the
/// negative (last) position records the packet's fragment count. A packet completes as soon as
/// positions 1...count are all present — whichever fragment arrives last. That is deliberately
/// STRONGER than the reference, which only assembles when the arriving fragment is the negative one
/// (`process_packet`, Meshtastic_Interface.py:380-387): a late middle fragment completes here and
/// is lost there (fixture `reorder`). A completed packet's buffer is dropped, so a late duplicate
/// of a single-fragment packet re-emits it; Transport's packet-hash dedup absorbs that.
public struct MeshtasticReassembler: Equatable, Sendable {
    public static let inactivityTimeout: TimeInterval = 30
    public static let maxBuffersPerSender = 8
    public static let maxBuffersTotal = 64
    /// `Packet.mtu` (500) + an 8-byte IFAC — landandair's DEFAULT_IFAC_SIZE (L30).
    public static let maxPacketLength = 508

    public struct Counters: Equatable, Sendable {
        public var malformed = 0
        public var evicted = 0
        public var timedOut = 0
        public var oversize = 0
        public var completed = 0
        public init() {}
    }

    struct Key: Hashable, Sendable {
        let from: UInt32
        let index: UInt8
    }

    struct Buffer: Equatable, Sendable {
        var bodies: [Int: Data] = [:]
        /// The fragment count, known once the negative position arrived.
        var total: Int?
        var byteCount = 0
        var lastActivity: Date
        /// Insertion/touch order, so eviction is deterministic when dates tie.
        var touch: UInt64
    }

    public private(set) var counters = Counters()
    var buffers: [Key: Buffer] = [:]
    private var touchCounter: UInt64 = 0

    public var bufferCount: Int { buffers.count }

    public init() {}

    public mutating func recordMalformed() { counters.malformed += 1 }

    /// Drop every partial packet (radio disconnect). Counters are diagnostics and survive.
    public mutating func reset() { buffers = [:] }

    /// Insert one data fragment. Returns the reassembled packet when this completes one.
    @discardableResult
    public mutating func receive(from: UInt32, index: UInt8, pos: Int8, body: Data, now: Date) -> Data? {
        purgeInactive(now: now)
        guard pos != 0, !body.isEmpty else {
            counters.malformed += 1
            return nil
        }
        let key = Key(from: from, index: index)
        // `magnitude`, never `abs`: abs(Int8.min) traps.
        let slot = Int(pos.magnitude)
        let isLast = pos < 0
        let body = Data(body)
        touchCounter &+= 1

        var buffer = buffers[key] ?? Buffer(lastActivity: now, touch: touchCounter)
        if conflicts(buffer, slot: slot, isLast: isLast, body: body) {
            buffer = Buffer(lastActivity: now, touch: touchCounter)
        }
        if buffer.bodies[slot] == nil { buffer.byteCount += body.count }
        buffer.bodies[slot] = body
        if isLast { buffer.total = slot }
        buffer.lastActivity = now
        buffer.touch = touchCounter

        if buffer.byteCount > Self.maxPacketLength {
            buffers[key] = nil
            counters.oversize += 1
            return nil
        }
        if let total = buffer.total, buffer.bodies.count == total {
            let ordered = (1...total).compactMap { buffer.bodies[$0] }
            if ordered.count == total {
                buffers[key] = nil
                counters.completed += 1
                return ordered.reduce(into: Data()) { $0.append($1) }
            }
        }
        buffers[key] = buffer
        enforceBounds(sender: from)
        return nil
    }

    /// A fragment that cannot belong to the packet already buffered under its key: a different
    /// body at a position we hold, a last position that disagrees with the known count, or a
    /// position at/after a known last one.
    private func conflicts(_ buffer: Buffer, slot: Int, isLast: Bool, body: Data) -> Bool {
        if let existing = buffer.bodies[slot], existing != body { return true }
        if let total = buffer.total {
            return isLast ? slot != total : slot >= total
        }
        if isLast, let highest = buffer.bodies.keys.max(), highest > slot { return true }
        return false
    }

    private mutating func purgeInactive(now: Date) {
        let stale = buffers.filter { now.timeIntervalSince($0.value.lastActivity) >= Self.inactivityTimeout }
        for key in stale.keys { buffers[key] = nil }
        counters.timedOut += stale.count
    }

    private mutating func enforceBounds(sender: UInt32) {
        while buffers.keys.filter({ $0.from == sender }).count > Self.maxBuffersPerSender {
            evictOldest { $0.from == sender }
        }
        while buffers.count > Self.maxBuffersTotal {
            evictOldest { _ in true }
        }
    }

    private mutating func evictOldest(where include: (Key) -> Bool) {
        let victim = buffers
            .filter { include($0.key) }
            .min { ($0.value.lastActivity, $0.value.touch) < ($1.value.lastActivity, $1.value.touch) }?
            .key
        guard let victim else { return }
        buffers[victim] = nil
        counters.evicted += 1
    }
}
```

- [ ] **Step 4: Run tests to verify they pass (rule step a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter MeshtasticReassemblerTests`
Expected: 20 tests pass.

- [ ] **Step 5: Mutate in one batch (rule step b)**

Apply all of these in `MeshtasticReassembler.swift` together, run once, and confirm every non-trap test fails:

| Mutation | Breaks |
|---|---|
| `let key = Key(from: 0, index: 0)` | `interleavedSendersReassembleIndependently`, `interleavedIndicesFromOneSenderReassembleIndependently`, `ninthBufferFromOneSenderEvictsItsOldest`, `sixtyFifthBufferEvictsTheOldestOverall` |
| completion: `if isLast, let total = buffer.total, buffer.bodies.count == total, total > 1 {` | `lateMiddleFragmentCompletesThePacket`, `lastFragmentFirstStillCompletes`, `singleFragmentPacketCompletesAtOnce` |
| completion: `(1...total).reversed().compactMap { ... }` | `inOrderFragmentsCompleteOnTheLast`, `packetOf508BytesCompletes` |
| `conflicts`: delete the line `if let existing = buffer.bodies[slot], existing != body { return true }` | `conflictingBodyRestartsTheBufferWithOnlyTheNewFragment` |
| `purgeInactive`: `<` in place of `>=` | `bufferIdleUnder30SecondsStillCompletes`, `bufferIdle30SecondsIsPurged` |
| oversize: `if buffer.byteCount == Self.maxPacketLength {` | `packetOf508BytesCompletes`, `packetOver508BytesIsDroppedAsOversize` |
| delete `counters.completed += 1` | `completedCountsEachReassembledPacket`, `duplicateFragmentDoesNotDisturbReassembly` |
| `guard pos != 0, !body.isEmpty` → `guard true` | `positionZeroIsMalformed`, `emptyBodyIsMalformed` |
| `reset()`: body `counters = Counters()` | `resetDropsEveryBuffer`, `resetKeepsCounters` |

Some tests will also fail under rows aimed at others; that is expected. Every test except `int8MinPositionDoesNotTrap` must fail at least once.

- [ ] **Step 6: Trap-class mutation (rule step b′)**

Apply alone: `let slot = Int(abs(pos))`. Run `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter int8MinPositionDoesNotTrap`. Expected: the run FAILS (crash). Revert.

- [ ] **Step 7: Revert and re-run (rule step c)**

Revert every step-5 mutation, run the step-4 command. Expected: 20 pass.

- [ ] **Step 8: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface add Sources/ReTiCAInterfaces/Meshtastic/MeshtasticReassembler.swift Tests/ReTiCAInterfacesTests/MeshtasticReassemblerTests.swift`

Write `/tmp/meshtastic-interface/commit-task-3.txt`:

```
feat: bounded Meshtastic reassembler keyed by sender and index

Completes on whichever fragment arrives last (stronger than landandair,
which only assembles on the negative position), restarts on a conflicting
body, purges after 30 s idle, caps 8 buffers per sender / 64 total, drops
packets over 508 B, and keeps diagnostic counters across reset.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface commit -F /tmp/meshtastic-interface/commit-task-3.txt`
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface log -1 "--format=%(trailers:key=Claude-Session,valueonly)"`

---

### Task 4: Cross-validation against landandair's genuine code

The generator drives landandair's real `PacketHandler` and `MeshtasticInterface` receive and outgoing paths, imported by file path. Only one thing is stubbed: the `meshtastic` package, which `process_outgoing` imports inside the method solely for `BROADCAST_ADDR`. Nothing is hand-rolled. Both directions are covered:
- Their split → fixture → our codec must match byte-for-byte, and our reassembler must rebuild it.
- Our split → `meshtastic_our_split.json` (written by Swift) → their `process_message` must reassemble it → fixture records the result. A Swift test pins the committed file to the codec as it is today, so a stale file fails.

This approach was probed before the plan was written, and the reference behaved as follows. Running `conda run -n rns python -I -B` on a probe script that loads the file by path:
- 200 B → frames of 103 and 101 bytes.
- 500 B → 169 / 169 / 168.
- `process_outgoing` queue `[(0, 1), (0, -2), (1, -1)]`.
- A skipped index produces `b'REQ\x01\x01'`.

**Files:**
- Create (downloaded at pinned commit `e5eb5d23a619958ae0556c88fcbc4bf1d867ab0a`, unmodified): `Tests/ReTiCAInterfacesTests/Vectors/landandair_Meshtastic_Interface.py`
- Create: `Tests/ReTiCAInterfacesTests/Vectors/generate_meshtastic_fixtures.py`
- Create (generated): `Tests/ReTiCAInterfacesTests/Vectors/meshtastic_our_split.json`, `Tests/ReTiCAInterfacesTests/Vectors/meshtastic_fixtures.json`
- Create: `Tests/ReTiCAInterfacesTests/MeshtasticFixtureSupport.swift`, `Tests/ReTiCAInterfacesTests/MeshtasticCrossValidationTests.swift`
- Modify: `Package.swift:48` (the `ReTiCAInterfacesTests` `resources:` line only)

**Interfaces:**
- Consumes: `LandandairCodec` (Task 2), `MeshtasticReassembler` (Task 3).
- Produces (test module, used by Tasks 5-6):
  - `func meshData(hex: String) -> Data`
  - `extension Data { var meshHex: String }`
  - `func meshPattern(_ count: Int, seed: Int) -> Data`, where byte i = (7i + seed) mod 256, the same as the generator's `pattern`
  - `struct MeshtasticFixtures: Decodable { theirSplit, ourSplitReassembled, outgoing: Outgoing { packets, frames }, requests, requestAnswers: [RequestAnswer { request, answer }], reorder; static func load() throws -> MeshtasticFixtures }`
  - `struct MeshtasticOurSplitFile: Codable, Equatable { cases; static func current() -> Self; static func load() throws -> Self; func encoded() throws -> Data }`

- [ ] **Step 1: Download the reference at its pinned commit and verify it is the reviewed file**

Run: `curl -fsSL -o /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface/Tests/ReTiCAInterfacesTests/Vectors/landandair_Meshtastic_Interface.py https://raw.githubusercontent.com/landandair/RNS_Over_Meshtastic/e5eb5d23a619958ae0556c88fcbc4bf1d867ab0a/Interface/Meshtastic_Interface.py`

Run: `shasum -a 256 /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface/Tests/ReTiCAInterfacesTests/Vectors/landandair_Meshtastic_Interface.py`
Expected: `8b71aa8efc7624dba05202c5eb356a10a48c31bee783cd4c9295038370b394ab`. This was verified on 2026-10-16 against this exact URL. If the download fails or the hash differs, STOP and report: the generator must drive the reviewed file.

The copy is committed in Step 11, so regenerating fixtures later needs no network.

- [ ] **Step 2: Write the fixture support file**

Create `Tests/ReTiCAInterfacesTests/MeshtasticFixtureSupport.swift`:

```swift
import Foundation
@testable import ReTiCAInterfaces

func meshData(hex: String) -> Data {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return data
}

extension Data {
    var meshHex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Byte i = (7i + seed) mod 256 — identical to `pattern` in generate_meshtastic_fixtures.py.
func meshPattern(_ count: Int, seed: Int) -> Data {
    Data((0..<count).map { UInt8((($0 * 7) + seed) % 256) })
}

struct MeshFixtureMissing: Error { let name: String }

/// The reference's outputs (generate_meshtastic_fixtures.py → meshtastic_fixtures.json).
struct MeshtasticFixtures: Decodable {
    struct Split: Decodable { let length: Int; let index: Int; let packet: String; let fragments: [String] }
    struct Reassembled: Decodable { let index: Int; let packet: String; let reassembled: String }
    struct Outgoing: Decodable { let packets: [String]; let frames: [String] }
    struct Request: Decodable { let frame: String; let index: Int; let pos: Int }
    struct RequestAnswer: Decodable { let request: String; let answer: String }
    struct Reorder: Decodable { let packet: String; let fragments: [String]; let referenceCompletes: Bool }

    let theirSplit: [Split]
    let ourSplitReassembled: [Reassembled]
    let outgoing: Outgoing
    let requests: [Request]
    let requestAnswers: [RequestAnswer]
    let reorder: [Reorder]

    static func load() throws -> MeshtasticFixtures {
        guard let url = Bundle.module.url(forResource: "meshtastic_fixtures", withExtension: "json") else {
            throw MeshFixtureMissing(name: "meshtastic_fixtures.json")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(MeshtasticFixtures.self, from: Data(contentsOf: url))
    }
}

/// OUR codec's split of a fixed packet set. Written by `MeshtasticOurSplitEmitter`, read by the
/// generator (which feeds it to the reference), and pinned to the current codec by
/// `referenceReassemblesWhatOurCodecEmitsToday`.
struct MeshtasticOurSplitFile: Codable, Equatable {
    struct Case: Codable, Equatable { let index: Int; let packet: String; let fragments: [String] }
    let cases: [Case]

    static let lengths = [1, 2, 3, 199, 200, 201, 400, 500, 508]
    static let indices = [0, 255]

    static func current() -> MeshtasticOurSplitFile {
        let codec = LandandairCodec()
        return MeshtasticOurSplitFile(cases: lengths.flatMap { length in
            indices.map { index in
                let packet = meshPattern(length, seed: 5)
                return Case(index: index, packet: packet.meshHex,
                            fragments: codec.split(packet, index: UInt8(index)).map(\.meshHex))
            }
        })
    }

    static func load() throws -> MeshtasticOurSplitFile {
        guard let url = Bundle.module.url(forResource: "meshtastic_our_split", withExtension: "json") else {
            throw MeshFixtureMissing(name: "meshtastic_our_split.json")
        }
        return try JSONDecoder().decode(MeshtasticOurSplitFile.self, from: Data(contentsOf: url))
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
```

- [ ] **Step 3: Write the emitter (a tool, not a test: exempt from the mutation rule)**

Create `Tests/ReTiCAInterfacesTests/MeshtasticCrossValidationTests.swift` with ONLY the emitter for now:

```swift
import Testing
import Foundation
@testable import ReTiCAInterfaces

/// Writes Vectors/meshtastic_our_split.json for generate_meshtastic_fixtures.py. Disabled unless
/// RETICA_EMIT_MESHTASTIC_SPLIT=1, so an ordinary `swift test` never rewrites a committed file.
@Suite struct MeshtasticOurSplitEmitter {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RETICA_EMIT_MESHTASTIC_SPLIT"] == "1"))
    func writeOurSplitForTheReferenceGenerator() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Vectors/meshtastic_our_split.json")
        try MeshtasticOurSplitFile.current().encoded().write(to: url, options: .atomic)
    }
}
```

Run: `env RETICA_EMIT_MESHTASTIC_SPLIT=1 swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter MeshtasticOurSplitEmitter`
Expected: 1 test passes, and `Tests/ReTiCAInterfacesTests/Vectors/meshtastic_our_split.json` now exists with 18 cases. Check with the Read tool.

- [ ] **Step 4: Write the generator**

Create `Tests/ReTiCAInterfacesTests/Vectors/generate_meshtastic_fixtures.py`:

```python
#!/usr/bin/env python
# Cross-validation fixtures for ReTiCA's LandandairCodec / MeshtasticReassembler / sender, made by
# driving landandair's GENUINE code — not a re-implementation.
#
# Run in the conda `rns` env (the reference imports RNS at module top), by absolute path:
#   conda run -n rns python -I -B <repo>/Tests/ReTiCAInterfacesTests/Vectors/generate_meshtastic_fixtures.py
# Reads meshtastic_our_split.json (written by the Swift MeshtasticOurSplitEmitter suite) and writes
# meshtastic_fixtures.json, both next to this script.
#
# Reference: landandair_Meshtastic_Interface.py, an UNMODIFIED copy of
# https://github.com/landandair/RNS_Over_Meshtastic  Interface/Meshtastic_Interface.py at commit
# e5eb5d23a619958ae0556c88fcbc4bf1d867ab0a (sha256 pinned below). The one stub: the `meshtastic` package, which
# process_outgoing imports inside the method only for BROADCAST_ADDR. MeshtasticInterface.__init__
# needs a radio, so instances are made with __new__ and given exactly the attributes the driven
# methods touch; every byte below comes from their PacketHandler / process_message /
# process_outgoing code paths.
import hashlib
import importlib.util
import json
import os
import struct
import sys
import types

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, "landandair_Meshtastic_Interface.py")
OUR_SPLIT = os.path.join(HERE, "meshtastic_our_split.json")
OUT = os.path.join(HERE, "meshtastic_fixtures.json")
EXPECTED_SHA256 = "8b71aa8efc7624dba05202c5eb356a10a48c31bee783cd4c9295038370b394ab"

with open(REF, "rb") as f:
    digest = hashlib.sha256(f.read()).hexdigest()
assert digest == EXPECTED_SHA256, "reference copy changed: " + digest

stub = types.ModuleType("meshtastic")
stub.BROADCAST_ADDR = "^all"
sys.modules["meshtastic"] = stub

spec = importlib.util.spec_from_file_location("landandair_meshtastic_interface", REF)
ref = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref)


def pattern(n, seed):
    return bytes((i * 7 + seed) % 256 for i in range(n))


def radio_less_interface():
    iface = ref.MeshtasticInterface.__new__(ref.MeshtasticInterface)
    iface.packet_i_queue = []
    iface.outgoing_packet_storage = {}
    iface.packet_index = 0
    iface.dest_to_node_dict = {}
    iface.expected_index = {}
    iface.requested_index = {}
    iface.assembly_dict = {}
    iface.rxb = 0
    iface.txb = 0
    inbound = []

    class Owner:
        def inbound(self, data, interface):
            inbound.append(bytes(data))

    iface.owner = Owner()
    return iface, inbound


def deliver(iface, payload, sender=0x1234):
    iface.process_message({"from": sender,
                           "decoded": {"portnum": "RETICULUM_TUNNEL_APP", "payload": payload}}, None)


# 1. Their split, and their own reassembly of it (sanity).
their_split = []
for n in [1, 2, 3, 199, 200, 201, 400, 500, 508]:
    for index in [0, 1, 82, 127, 128, 255]:
        packet = pattern(n, 3)
        frames = list(ref.PacketHandler(packet, index).data_dict.values())   # send order: 1, 2, ..., -n
        check = ref.PacketHandler()
        out = None
        for fr in frames:
            out = check.process_packet(fr)
        assert out == packet, "reference round trip failed"
        their_split.append({"length": n, "index": index, "packet": packet.hex(),
                            "fragments": [x.hex() for x in frames]})

# 2. OUR split through THEIR full receive path (process_message → owner.inbound).
if not os.path.exists(OUR_SPLIT):
    sys.exit("meshtastic_our_split.json missing: run the MeshtasticOurSplitEmitter suite first")
with open(OUR_SPLIT) as f:
    ours = json.load(f)["cases"]
our_split_reassembled = []
for case in ours:
    iface, inbound = radio_less_interface()
    for fr in case["fragments"]:
        deliver(iface, bytes.fromhex(fr))
    assert inbound == [bytes.fromhex(case["packet"])], "reference failed to reassemble our split"
    our_split_reassembled.append({"index": case["index"], "packet": case["packet"],
                                  "reassembled": inbound[0].hex()})

# 3. Their outgoing path: index counter from 0, queue order.
sender, _ = radio_less_interface()
outgoing_packets = [pattern(250, 11), pattern(10, 13), pattern(508, 17)]
for p in outgoing_packets:
    sender.process_outgoing(p)
outgoing_frames = [sender.outgoing_packet_storage[i][pos] for (i, pos) in sender.packet_i_queue]
outgoing = {"packets": [p.hex() for p in outgoing_packets], "frames": [x.hex() for x in outgoing_frames]}

# 4. Their answer to a REQ: which stored frame goes to the queue front.
request_answers = []
for (index, pos) in [(0, 2), (2, 3), (1, 1), (2, 1)]:
    req = b"REQ" + struct.pack(ref.PacketHandler.struct_format, index, pos)
    sender.packet_i_queue = []
    deliver(sender, req, sender=0x9999)
    qi, qp = sender.packet_i_queue[0]
    request_answers.append({"request": req.hex(), "answer": sender.outgoing_packet_storage[qi][qp].hex()})

# 5. REQ frames exactly as their receiver emits them on a skipped index (incl. the 255 → 0 wrap).
requests = []
for (first, second) in [(0, 2), (255, 1)]:
    iface, _ = radio_less_interface()
    deliver(iface, ref.PacketHandler(pattern(5, 1), first).data_dict[-1])
    deliver(iface, ref.PacketHandler(pattern(5, 2), second).data_dict[-1])
    frame = iface.outgoing_packet_storage[-1][0]
    r_index, r_pos = ref.PacketHandler().get_metadata(frame[3:])
    requests.append({"frame": frame.hex(), "index": r_index, "pos": r_pos})
assert [(r["index"], r["pos"]) for r in requests] == [(1, 1), (0, 1)]

# 6. Reordered delivery: where the reference does and does not complete.
reorder = []
packet = pattern(500, 23)
frames3 = list(ref.PacketHandler(packet, 9).data_dict.values())   # pos 1, 2, -3
for order in [[1, 0, 2], [2, 0, 1]]:                               # (2, 1, -3) and (-3, 1, 2)
    h = ref.PacketHandler()
    done = None
    for k in order:
        r = h.process_packet(frames3[k])
        if r is not None:
            done = r
    reorder.append({"packet": packet.hex(), "fragments": [frames3[k].hex() for k in order],
                    "reference_completes": done == packet})
assert [r["reference_completes"] for r in reorder] == [True, False]

fixtures = {
    "source": {"file": "landandair_Meshtastic_Interface.py", "sha256": EXPECTED_SHA256,
               "upstream": "https://raw.githubusercontent.com/landandair/RNS_Over_Meshtastic/e5eb5d23a619958ae0556c88fcbc4bf1d867ab0a/Interface/Meshtastic_Interface.py"},
    "their_split": their_split,
    "our_split_reassembled": our_split_reassembled,
    "outgoing": outgoing,
    "request_answers": request_answers,
    "requests": requests,
    "reorder": reorder,
}
with open(OUT, "w") as f:
    json.dump(fixtures, f, indent=1, sort_keys=True)
    f.write("\n")
print("wrote", OUT)
```

- [ ] **Step 5: Run the generator**

Run (timeout 300000): `conda run -n rns python -I -B /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface/Tests/ReTiCAInterfacesTests/Vectors/generate_meshtastic_fixtures.py`
Expected: `wrote .../meshtastic_fixtures.json` and no assertion error. An assertion error means the reference disagrees with our codec, or with a premise of this plan. STOP and report it. Do not edit the assertion.

- [ ] **Step 6: Declare the fixtures as resources**

Edit `Package.swift`. Replace

```swift
            resources: [.process("Vectors/ble_fixtures.json")]
```

with

```swift
            resources: [.process("Vectors/ble_fixtures.json"), .process("Vectors/meshtastic_fixtures.json"), .process("Vectors/meshtastic_our_split.json")]
```

The two `.py` files stay undeclared, following the `generate_ble_fixtures.py` precedent.

- [ ] **Step 7: Write the cross-validation tests**

Append to `Tests/ReTiCAInterfacesTests/MeshtasticCrossValidationTests.swift`:

```swift
private func reassemble(_ frames: [Data], from sender: UInt32 = 1) -> [Data?] {
    let codec = LandandairCodec()
    var reassembler = MeshtasticReassembler()
    var results: [Data?] = []
    for frame in frames {
        guard case let .data(index, pos, body)? = codec.parse(frame) else {
            results.append(nil)
            continue
        }
        results.append(reassembler.receive(from: sender, index: index, pos: pos, body: body,
                                           now: Date(timeIntervalSince1970: 0)))
    }
    return results
}

@Suite struct MeshtasticCrossValidationTests {
    @Test func ourSplitMatchesTheReferenceSplitByteForByte() throws {
        let fixtures = try MeshtasticFixtures.load()
        #expect(fixtures.theirSplit.count == 54)   // 9 lengths × 6 indices
        for c in fixtures.theirSplit {
            let got = LandandairCodec().split(meshData(hex: c.packet), index: UInt8(c.index))
            #expect(got == c.fragments.map(meshData(hex:)), "length \(c.length) index \(c.index)")
        }
    }

    @Test func ourReassemblerRebuildsReferenceFragments() throws {
        let fixtures = try MeshtasticFixtures.load()
        for c in fixtures.theirSplit {
            let results = reassemble(c.fragments.map(meshData(hex:)))
            #expect(results.dropLast().allSatisfy { $0 == nil }, "length \(c.length) completed early")
            #expect(results.last == meshData(hex: c.packet), "length \(c.length) index \(c.index)")
        }
    }

    /// Our split, run through the reference's receive path by the generator, came back intact —
    /// and the committed split file is what our codec emits TODAY (a codec change without
    /// regenerating fails here).
    @Test func referenceReassemblesWhatOurCodecEmitsToday() throws {
        let committed = try MeshtasticOurSplitFile.load()
        #expect(committed == MeshtasticOurSplitFile.current(), "regenerate: emitter, then generator")
        let fixtures = try MeshtasticFixtures.load()
        #expect(fixtures.ourSplitReassembled.map(\.packet) == committed.cases.map(\.packet))
        #expect(fixtures.ourSplitReassembled.count == 18)
        for c in fixtures.ourSplitReassembled { #expect(c.reassembled == c.packet, "index \(c.index)") }
    }

    @Test func referenceRequestFramesParseAsRequests() throws {
        let fixtures = try MeshtasticFixtures.load()
        #expect(fixtures.requests.count == 2)
        for r in fixtures.requests {
            #expect(LandandairCodec().parse(meshData(hex: r.frame)) == .request(index: UInt8(r.index), pos: Int8(r.pos)))
        }
    }

    /// Spec §5.2 deviation, pinned against the reference: the reference completes (2, 1, −3) but
    /// NOT (−3, 1, 2); we complete both.
    @Test func lateMiddleFragmentCompletesWhereTheReferenceDoesNot() throws {
        let fixtures = try MeshtasticFixtures.load()
        #expect(fixtures.reorder.map(\.referenceCompletes) == [true, false])
        for c in fixtures.reorder {
            #expect(reassemble(c.fragments.map(meshData(hex:))).last == meshData(hex: c.packet))
        }
    }
}
```

- [ ] **Step 8: Run the tests (rule step a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter MeshtasticCrossValidationTests`
Expected: 5 tests pass. This task validates code that already exists, so its red phase is step 9.

- [ ] **Step 9: Mutate in one batch (rule step b)**

Apply together, run once, and confirm all 5 tests FAIL:

| Mutation | Breaks |
|---|---|
| `MeshtasticFragmentCodec.swift` `split`: `let size = length / count + 2` | `ourSplitMatchesTheReferenceSplitByteForByte`, `referenceReassemblesWhatOurCodecEmitsToday` |
| `MeshtasticReassembler.swift` completion: `(1...total).reversed().compactMap` | `ourReassemblerRebuildsReferenceFragments` |
| `MeshtasticFragmentCodec.swift` `parse`: `if frame.count == 6, ...` | `referenceRequestFramesParseAsRequests` |
| `MeshtasticReassembler.swift` completion: `if isLast, let total = buffer.total, ...` | `lateMiddleFragmentCompletesWhereTheReferenceDoesNot` |

- [ ] **Step 10: Revert and re-run (rule step c)**

Revert, run the step-8 command. Expected: 5 pass.

- [ ] **Step 11: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface add Package.swift Tests/ReTiCAInterfacesTests/Vectors/landandair_Meshtastic_Interface.py Tests/ReTiCAInterfacesTests/Vectors/generate_meshtastic_fixtures.py Tests/ReTiCAInterfacesTests/Vectors/meshtastic_our_split.json Tests/ReTiCAInterfacesTests/Vectors/meshtastic_fixtures.json Tests/ReTiCAInterfacesTests/MeshtasticFixtureSupport.swift Tests/ReTiCAInterfacesTests/MeshtasticCrossValidationTests.swift`

Write `/tmp/meshtastic-interface/commit-task-4.txt`:

```
test: cross-validate the Meshtastic codec against landandair's real code

The generator imports an unmodified, hash-pinned copy of landandair's
Meshtastic_Interface.py and drives PacketHandler, process_message and
process_outgoing both ways: their split must match ours byte for byte and
reassemble in ours; our split (emitted by Swift, pinned to today's codec)
must reassemble through their receive path. Also records their REQ frames,
REQ answers, outgoing index order, and the reorder case where they drop a
packet we complete.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface commit -F /tmp/meshtastic-interface/commit-task-4.txt`
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface log -1 "--format=%(trailers:key=Claude-Session,valueonly)"`

---

### Task 5: `MeshtasticInterface` — lifecycle and inbound path

**Files:**
- Create: `Sources/ReTiCAInterfaces/Meshtastic/MeshtasticInterface.swift`
- Create: `Tests/ReTiCAInterfacesTests/MeshtasticInterfaceTestSupport.swift`
- Test: `Tests/ReTiCAInterfacesTests/MeshtasticInterfaceLifecycleTests.swift`

**Interfaces:**
- Consumes: `MeshtasticDriver*`, `\.meshtasticDriver`, `\.meshtasticDate`, `\.meshtasticClock` (Task 1); `MeshtasticFraming` (Task 2); `MeshtasticReassembler` (Task 3); `meshPattern` (Task 4).
- Produces:
  - `public enum MeshtasticInterfaceStatus: Equatable, Sendable { stopped, connecting, online(myNodeNum: UInt32, modemPreset: Int?), unavailable(BLEAdapterUnavailable) }`
  - `MeshtasticInterface.State(config: MeshtasticDriverConfig, framing: MeshtasticFraming = .landandair)` with `config`, `framing`, `status`, `reassembler`, `isOnline`, `modemPreset`
  - `MeshtasticInterface.Action`: `.start`, `.stop`, `.driverEvent(MeshtasticDriverEvent)`, `.delegate(.online(myNodeNum:modemPreset:) | .offline(reason:) | .packetReceived(Data) | .adapterUnavailable(BLEAdapterUnavailable))`
  - Test helpers: `MeshMockCall`, `meshTestConfig`, `meshOwnNode`, `meshPeerNode`, `MeshInterfaceHarness`, `makeMeshInterface(initial:sendResults:)`, `makeOnlineMeshInterface(modemPreset:initial:sendResults:)`, `stopMeshInterface(_:)`

- [ ] **Step 1: Write the test harness**

Create `Tests/ReTiCAInterfacesTests/MeshtasticInterfaceTestSupport.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

enum MeshMockCall: Equatable {
    case start(MeshtasticDriverConfig)
    case send(Data)
    case stop
}

extension Array where Element == MeshMockCall {
    var sentFrames: [Data] {
        compactMap { call in
            if case let .send(frame) = call { return frame }
            return nil
        }
    }
}

let meshTestRadio = UUID(uuidString: "0000AAAA-0000-0000-0000-00000000BEEF")!
let meshTestConfig = MeshtasticDriverConfig(radio: meshTestRadio, channel: 2, hopLimit: 3)
let meshOwnNode: UInt32 = 0x0A0A_0A0A
let meshPeerNode: UInt32 = 0x0B0B_0B0B

@MainActor
struct MeshInterfaceHarness {
    let store: TestStore<MeshtasticInterface.State, MeshtasticInterface.Action>
    let radio: AsyncStream<MeshtasticDriverEvent>.Continuation
    let calls: LockIsolated<[MeshMockCall]>
    let clock: TestClock<Duration>
    let now: LockIsolated<Date>
}

/// A MeshtasticInterface over a mock radio. `sendResults` are returned by successive driver
/// `send`s (then `true`).
@MainActor
func makeMeshInterface(initial: MeshtasticInterface.State = MeshtasticInterface.State(config: meshTestConfig),
                       sendResults: [Bool] = []) -> MeshInterfaceHarness {
    let radio = AsyncStream<MeshtasticDriverEvent>.makeStream()
    let calls = LockIsolated<[MeshMockCall]>([])
    let results = LockIsolated(sendResults)
    let clock = TestClock<Duration>()
    let now = LockIsolated(Date(timeIntervalSince1970: 1_000))
    let store = TestStore(initialState: initial) {
        MeshtasticInterface()
    } withDependencies: {
        $0.meshtasticDriver = MeshtasticDriver(
            start: { config in
                calls.withValue { $0.append(.start(config)) }
                return radio.stream
            },
            send: { frame in
                calls.withValue { $0.append(.send(frame)) }
                return results.withValue { $0.isEmpty ? true : $0.removeFirst() }
            },
            stop: { calls.withValue { $0.append(.stop) } }
        )
        $0.meshtasticClock = clock
        $0.meshtasticDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    return MeshInterfaceHarness(store: store, radio: radio.continuation, calls: calls, clock: clock, now: now)
}

/// Started and online with `modemPreset`.
@MainActor
func makeOnlineMeshInterface(modemPreset: Int? = 0,
                             initial: MeshtasticInterface.State = MeshtasticInterface.State(config: meshTestConfig),
                             sendResults: [Bool] = []) async -> MeshInterfaceHarness {
    let h = makeMeshInterface(initial: initial, sendResults: sendResults)
    await h.store.send(.start)
    h.radio.yield(.connected(myNodeNum: meshOwnNode, modemPreset: modemPreset))
    await h.store.receive { if case .delegate(.online) = $0 { return true }; return false }
    return h
}

@MainActor
func stopMeshInterface(_ h: MeshInterfaceHarness) async {
    await h.store.send(.stop)
    await h.store.skipReceivedActions(strict: false)
}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/ReTiCAInterfacesTests/MeshtasticInterfaceLifecycleTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

@MainActor @Suite struct MeshtasticInterfaceLifecycleTests {
    @Test func startHandsTheConfigToTheDriver() async {
        let h = await makeOnlineMeshInterface()
        #expect(h.calls.value.first == .start(meshTestConfig))
        await stopMeshInterface(h)
    }

    @Test func connectedEventReportsOnlineWithItsPreset() async {
        let h = makeMeshInterface()
        await h.store.send(.start)
        h.radio.yield(.connected(myNodeNum: meshOwnNode, modemPreset: 8))
        await h.store.receive { $0 == .delegate(.online(myNodeNum: meshOwnNode, modemPreset: 8)) }
        await stopMeshInterface(h)
    }

    @Test func fragmentsFromAPeerReassembleIntoOnePacket() async {
        let h = await makeOnlineMeshInterface()
        let packet = meshPattern(400, seed: 9)
        for frame in LandandairCodec().split(packet, index: 4) {
            h.radio.yield(.fragment(from: meshPeerNode, frame))
        }
        await h.store.receive { $0 == .delegate(.packetReceived(packet)) }
        await stopMeshInterface(h)
    }

    @Test func malformedFrameIncrementsTheMalformedCounter() async {
        let h = await makeOnlineMeshInterface()
        h.radio.yield(.fragment(from: meshPeerNode, Data([0x01])))
        await h.store.receive { if case .driverEvent(.fragment) = $0 { return true }; return false }
        #expect(h.store.state.reassembler.counters.malformed == 1)
        await stopMeshInterface(h)
    }

    @Test func fragmentsBeforeTheRadioIsOnlineAreDropped() async {
        let h = makeMeshInterface()
        await h.store.send(.start)
        let frames = LandandairCodec().split(meshPattern(300, seed: 1), index: 0)
        h.radio.yield(.fragment(from: meshPeerNode, frames[0]))
        h.radio.yield(.connected(myNodeNum: meshOwnNode, modemPreset: 0))
        h.radio.yield(.fragment(from: meshPeerNode, frames[1]))
        await h.store.receive { if case let .driverEvent(.fragment(_, f)) = $0 { return f == frames[1] }; return false }
        #expect(h.store.state.reassembler.counters.completed == 0)
        await stopMeshInterface(h)
    }

    @Test func disconnectReportsOfflineWithTheReason() async {
        let h = await makeOnlineMeshInterface()
        h.radio.yield(.disconnected(reason: "link lost"))
        await h.store.receive { $0 == .delegate(.offline(reason: "link lost")) }
        await stopMeshInterface(h)
    }

    @Test func disconnectDiscardsPartialReassembly() async {
        let h = await makeOnlineMeshInterface()
        let frames = LandandairCodec().split(meshPattern(300, seed: 2), index: 0)
        h.radio.yield(.fragment(from: meshPeerNode, frames[0]))
        h.radio.yield(.disconnected(reason: nil))
        h.radio.yield(.connected(myNodeNum: meshOwnNode, modemPreset: 0))
        h.radio.yield(.fragment(from: meshPeerNode, frames[1]))
        await h.store.receive { if case let .driverEvent(.fragment(_, f)) = $0 { return f == frames[1] }; return false }
        #expect(h.store.state.reassembler.counters.completed == 0)
        await stopMeshInterface(h)
    }

    @Test func unavailableSurfacesTheCause() async {
        let h = makeMeshInterface()
        await h.store.send(.start)
        h.radio.yield(.unavailable(.poweredOff))
        await h.store.receive { $0 == .delegate(.adapterUnavailable(.poweredOff)) }
        await stopMeshInterface(h)
    }

    @Test func unavailableWhileOnlineReportsOffline() async {
        let h = await makeOnlineMeshInterface()
        h.radio.yield(.unavailable(.unauthorized))
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await stopMeshInterface(h)
    }

    @Test func stopWhileOnlineReportsOffline() async {
        let h = await makeOnlineMeshInterface()
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
    }

    @Test func stopStopsTheDriver() async {
        let h = await makeOnlineMeshInterface()
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await Task.megaYield()
        #expect(h.calls.value.contains(.stop))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter MeshtasticInterfaceLifecycleTests`
Expected: build FAILS with `cannot find 'MeshtasticInterface' in scope`.

- [ ] **Step 4: Implement the lifecycle and inbound reducer**

Create `Sources/ReTiCAInterfaces/Meshtastic/MeshtasticInterface.swift`:

```swift
import Foundation
import ComposableArchitecture

/// Where a `MeshtasticInterface` is in its radio lifecycle.
public enum MeshtasticInterfaceStatus: Equatable, Sendable {
    /// Not started, or stopped by `.stop`.
    case stopped
    /// Started, waiting for the driver's `.connected` (first connect, or after a drop —
    /// reconnecting is MeshtasticKit's job; the interface only waits).
    case connecting
    /// The radio finished its handshake. `modemPreset` is the raw `Config.LoRaConfig.ModemPreset`.
    case online(myNodeNum: UInt32, modemPreset: Int?)
    /// The driver reported the adapter unavailable. A fresh `.start` leaves this state.
    case unavailable(BLEAdapterUnavailable)
}

/// Reticulum over ONE Meshtastic radio, in landandair/RNS_Over_Meshtastic's fragment format
/// (spec 2026-10-16 §5): driver lifecycle and inbound reassembly keyed by sending node.
@Reducer
public struct MeshtasticInterface {
    @ObservableState
    public struct State: Equatable {
        public let config: MeshtasticDriverConfig
        public let framing: MeshtasticFraming
        public internal(set) var status: MeshtasticInterfaceStatus = .stopped
        public internal(set) var reassembler = MeshtasticReassembler()

        public init(config: MeshtasticDriverConfig, framing: MeshtasticFraming = .landandair) {
            self.config = config
            self.framing = framing
        }

        public var isOnline: Bool {
            if case .online = status { return true }
            return false
        }

        public var modemPreset: Int? {
            if case let .online(_, preset) = status { return preset }
            return nil
        }
    }

    public enum Action: Equatable {
        case start
        case stop
        case driverEvent(MeshtasticDriverEvent)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case online(myNodeNum: UInt32, modemPreset: Int?)
            case offline(reason: String?)
            case packetReceived(Data)
            case adapterUnavailable(BLEAdapterUnavailable)
        }
    }

    @Dependency(\.meshtasticDriver) var driver
    @Dependency(\.meshtasticDate) var date

    private enum CancelID: Hashable { case driver }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .start:
                switch state.status {
                case .stopped, .unavailable: break
                case .connecting, .online: return .none
                }
                state.status = .connecting
                let config = state.config
                return .run { [driver] send in
                    for await event in driver.start(config) {
                        await send(.driverEvent(event))
                    }
                }
                .cancellable(id: CancelID.driver, cancelInFlight: true)

            case .stop:
                guard state.status != .stopped else { return .none }
                let wasOnline = state.isOnline
                state.status = .stopped
                state.reassembler.reset()
                var effects: [Effect<Action>] = [.cancel(id: CancelID.driver),
                                                 .run { [driver] _ in await driver.stop() }]
                if wasOnline { effects.append(.send(.delegate(.offline(reason: nil)))) }
                return .merge(effects)

            case let .driverEvent(.connected(myNodeNum, modemPreset)):
                guard state.status != .stopped else { return .none }
                state.status = .online(myNodeNum: myNodeNum, modemPreset: modemPreset)
                return .send(.delegate(.online(myNodeNum: myNodeNum, modemPreset: modemPreset)))

            case let .driverEvent(.disconnected(reason)):
                guard state.status != .stopped else { return .none }
                let wasOnline = state.isOnline
                state.status = .connecting
                state.reassembler.reset()
                return wasOnline ? .send(.delegate(.offline(reason: reason))) : .none

            case let .driverEvent(.unavailable(cause)):
                guard state.status != .stopped else { return .none }
                let wasOnline = state.isOnline
                state.status = .unavailable(cause)
                state.reassembler.reset()
                var effects: [Effect<Action>] = []
                if wasOnline { effects.append(.send(.delegate(.offline(reason: nil)))) }
                effects.append(.send(.delegate(.adapterUnavailable(cause))))
                return .merge(effects)

            case let .driverEvent(.fragment(from, frame)):
                guard state.isOnline else { return .none }
                switch state.framing.codec.parse(frame) {
                case nil:
                    state.reassembler.recordMalformed()
                    return .none
                case let .data(index, pos, body):
                    guard let packet = state.reassembler.receive(from: from, index: index, pos: pos,
                                                                 body: body, now: date())
                    else { return .none }
                    return .send(.delegate(.packetReceived(packet)))
                case .request:
                    return .none
                }

            case .delegate:
                return .none
            }
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass (rule step a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter MeshtasticInterfaceLifecycleTests`
Expected: 11 tests pass.

- [ ] **Step 6: Mutate in one batch (rule step b)**

Apply together in `MeshtasticInterface.swift`, run once, and confirm all 11 FAIL:

| Mutation | Breaks |
|---|---|
| `.start`: `let config = MeshtasticDriverConfig(radio: UUID())` | `startHandsTheConfigToTheDriver` |
| `.connected`: delegate `.online(myNodeNum: myNodeNum, modemPreset: nil)` | `connectedEventReportsOnlineWithItsPreset` |
| `.data` branch: `return .none` in place of `.send(.delegate(.packetReceived(packet)))` | `fragmentsFromAPeerReassembleIntoOnePacket` |
| `nil` branch: delete `state.reassembler.recordMalformed()` | `malformedFrameIncrementsTheMalformedCounter` |
| `.fragment`: delete `guard state.isOnline else { return .none }` | `fragmentsBeforeTheRadioIsOnlineAreDropped` |
| `.disconnected`: `return .none` (no offline delegate), and delete its `state.reassembler.reset()` | `disconnectReportsOfflineWithTheReason`, `disconnectDiscardsPartialReassembly` |
| `.unavailable`: delete both `effects.append(...)` lines | `unavailableSurfacesTheCause`, `unavailableWhileOnlineReportsOffline` |
| `.stop`: delete `if wasOnline { effects.append(...) }` | `stopWhileOnlineReportsOffline`, `stopStopsTheDriver` (times out on the offline receive) |
| `.stop`: delete the `.run { [driver] _ in await driver.stop() }` element | `stopStopsTheDriver` |

- [ ] **Step 7: Revert and re-run (rule step c)**

Revert, run the step-5 command. Expected: 11 pass.

- [ ] **Step 8: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface add Sources/ReTiCAInterfaces/Meshtastic/MeshtasticInterface.swift Tests/ReTiCAInterfacesTests/MeshtasticInterfaceTestSupport.swift Tests/ReTiCAInterfacesTests/MeshtasticInterfaceLifecycleTests.swift`

Write `/tmp/meshtastic-interface/commit-task-5.txt`:

```
feat: MeshtasticInterface lifecycle and inbound reassembly

Drives the MeshtasticDriver stream, reports online (with the radio's
preset) / offline / adapter-unavailable, reassembles port-76 fragments per
sending node only while online, and discards partial packets on a drop.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface commit -F /tmp/meshtastic-interface/commit-task-5.txt`
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface log -1 "--format=%(trailers:key=Claude-Session,valueonly)"`

---

### Task 6: `MeshtasticInterface` — paced sender and REQ answering

**Files:**
- Modify (full replacement): `Sources/ReTiCAInterfaces/Meshtastic/MeshtasticInterface.swift`
- Modify (append): `Tests/ReTiCAInterfacesTests/MeshtasticInterfaceTestSupport.swift`
- Test: `Tests/ReTiCAInterfacesTests/MeshtasticInterfaceSenderTests.swift`

**Interfaces:**
- Consumes: everything from Task 5; `MeshtasticModemPreset.fragmentDelay` (Task 1); `MeshtasticFixtures` (`outgoing`, `requestAnswers`), `meshData(hex:)` (Task 4).
- Produces:
  - `MeshtasticInterface.queueCapacity == 256`, `.requestCacheSize == 16`
  - `MeshtasticInterface.Counters { queueFull, sendFailed, requestsAnswered }`
  - `public struct MeshtasticCounters: Equatable, Sendable { malformed, evicted, timedOut, oversize, completed, queueFull, sendFailed: Int }` (exactly these 7; spec amendment)
  - `State.diagnostics: MeshtasticCounters` (computed from `reassembler.counters` + `counters`)
  - `State.counters`, `State.queuedFragmentCount`; internal `queue: [QueuedFragment]`, `nextIndex: UInt8`, `sentCache: [SentPacket]`, `pacing: Bool`
  - Actions `.send(Data)`, `.fragmentSent(ok: Bool)`, `.pacingElapsed`
  - Test helper `drainMeshFrames(_:every:count:)`

- [ ] **Step 1: Append the drain helper to the harness**

Append to `Tests/ReTiCAInterfacesTests/MeshtasticInterfaceTestSupport.swift`:

```swift
/// Advance the pacing clock `count` times by `delay`, waiting for each resulting driver send.
@MainActor
func drainMeshFrames(_ h: MeshInterfaceHarness, every delay: Duration, count: Int) async {
    for _ in 0..<count {
        await h.clock.advance(by: delay)
        await h.store.receive { if case .fragmentSent = $0 { return true }; return false }
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/ReTiCAInterfacesTests/MeshtasticInterfaceSenderTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

private func request(_ index: UInt8, _ pos: UInt8) -> Data { Data("REQ".utf8) + Data([index, pos]) }
private let codec = LandandairCodec()
private let longFast = 0      // 8 s per fragment
private let shortTurbo = 8    // 0.4 s per fragment

@MainActor
private func receiveSent(_ h: MeshInterfaceHarness) async {
    await h.store.receive { if case .fragmentSent = $0 { return true }; return false }
}

@MainActor
private func receiveFragmentEvent(_ h: MeshInterfaceHarness) async {
    await h.store.receive { if case .driverEvent(.fragment) = $0 { return true }; return false }
}

@MainActor @Suite struct MeshtasticInterfaceSenderTests {
    @Test func firstFragmentGoesOutImmediately() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        let packet = meshPattern(500, seed: 1)
        await h.store.send(.send(packet))
        await receiveSent(h)
        #expect(h.calls.value.sentFrames == [codec.split(packet, index: 0)[0]])
        await stopMeshInterface(h)
    }

    @Test func nextFragmentWaitsTheFullLongFastDelay() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        let packet = meshPattern(500, seed: 1)
        await h.store.send(.send(packet))
        await receiveSent(h)
        await h.clock.advance(by: .milliseconds(7_999))
        await Task.megaYield()
        #expect(h.calls.value.sentFrames.count == 1)
        await h.clock.advance(by: .milliseconds(1))
        await receiveSent(h)
        #expect(h.calls.value.sentFrames == Array(codec.split(packet, index: 0).prefix(2)))
        await stopMeshInterface(h)
    }

    @Test func shortTurboPacesFragmentsAt400Milliseconds() async {
        let h = await makeOnlineMeshInterface(modemPreset: shortTurbo)
        await h.store.send(.send(meshPattern(500, seed: 2)))
        await receiveSent(h)
        await h.clock.advance(by: .milliseconds(399))
        await Task.megaYield()
        #expect(h.calls.value.sentFrames.count == 1)
        await h.clock.advance(by: .milliseconds(1))
        await receiveSent(h)
        #expect(h.calls.value.sentFrames.count == 2)
        await stopMeshInterface(h)
    }

    /// 85 three-fragment packets: one fragment in flight, 254 queued. An 86th (3 more → 257 > 256)
    /// is dropped whole.
    @Test func packetThatDoesNotFitIsDroppedWhole() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        for seed in 0..<85 { await h.store.send(.send(meshPattern(500, seed: seed))) }
        #expect(h.store.state.queuedFragmentCount == 254)
        await h.store.send(.send(meshPattern(500, seed: 99)))
        #expect(h.store.state.queuedFragmentCount == 254)
        #expect(h.store.state.counters.queueFull == 1)
        await stopMeshInterface(h)
    }

    @Test func droppedPacketDoesNotConsumeAnIndex() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        for seed in 0..<85 { await h.store.send(.send(meshPattern(500, seed: seed))) }
        await h.store.send(.send(meshPattern(500, seed: 99)))     // dropped
        await h.store.send(.send(meshPattern(10, seed: 98)))      // 255 ≤ 256: fits
        #expect(h.store.state.queue.last?.frame.first == 85)
        await stopMeshInterface(h)
    }

    @Test func failedDriverSendIncrementsSendFailed() async {
        let h = await makeOnlineMeshInterface(modemPreset: shortTurbo, sendResults: [false])
        await h.store.send(.send(meshPattern(10, seed: 1)))
        await h.store.receive { $0 == .fragmentSent(ok: false) }
        #expect(h.store.state.counters.sendFailed == 1)
        await stopMeshInterface(h)
    }

    @Test func pacingContinuesAfterAFailedSend() async {
        let h = await makeOnlineMeshInterface(modemPreset: shortTurbo, sendResults: [false])
        let packet = meshPattern(300, seed: 4)
        await h.store.send(.send(packet))
        await h.store.receive { $0 == .fragmentSent(ok: false) }
        await h.clock.advance(by: .milliseconds(400))
        await h.store.receive { $0 == .fragmentSent(ok: true) }
        #expect(h.calls.value.sentFrames == codec.split(packet, index: 0))
        await stopMeshInterface(h)
    }

    @Test func requestedFragmentJumpsTheQueue() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        let a = codec.split(meshPattern(500, seed: 1), index: 0)
        await h.store.send(.send(meshPattern(500, seed: 1)))
        await h.store.send(.send(meshPattern(500, seed: 2)))
        await receiveSent(h)
        h.radio.yield(.fragment(from: meshPeerNode, request(0, 1)))
        await receiveFragmentEvent(h)
        #expect(h.store.state.queue.first == .init(frame: a[0], isRetransmit: true))
        await h.clock.advance(by: .seconds(8))
        await receiveSent(h)
        #expect(h.calls.value.sentFrames == [a[0], a[0]])
        await stopMeshInterface(h)
    }

    // Review Focus 4.
    @Test func requestForAnIndexNeverSentIsIgnored() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        await h.store.send(.send(meshPattern(500, seed: 1)))
        await receiveSent(h)
        let before = h.store.state.queue
        h.radio.yield(.fragment(from: meshPeerNode, request(7, 1)))
        await receiveFragmentEvent(h)
        #expect(h.store.state.queue == before)
        #expect(h.store.state.counters.requestsAnswered == 0)
        await stopMeshInterface(h)
    }

    // Review Focus 4.
    @Test func requestPastThePacketsLastFragmentIsIgnored() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        await h.store.send(.send(meshPattern(500, seed: 1)))      // 3 fragments
        await receiveSent(h)
        h.radio.yield(.fragment(from: meshPeerNode, request(0, 4)))
        await receiveFragmentEvent(h)
        #expect(h.store.state.counters.requestsAnswered == 0)
        await stopMeshInterface(h)
    }

    // Review Focus 1 — trap-class (step b′).
    @Test func requestWithPositionInt8MinIsIgnored() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        await h.store.send(.send(meshPattern(500, seed: 1)))
        await receiveSent(h)
        h.radio.yield(.fragment(from: meshPeerNode, request(0, 0x80)))
        await receiveFragmentEvent(h)
        #expect(h.store.state.counters.requestsAnswered == 0)
        await stopMeshInterface(h)
    }

    // Review Focus 3.
    @Test func repeatedRequestQueuesTheFragmentOnce() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        await h.store.send(.send(meshPattern(500, seed: 1)))
        await receiveSent(h)                                       // queue: [a2, a3]
        for _ in 0..<3 {
            h.radio.yield(.fragment(from: meshPeerNode, request(0, 1)))
            await receiveFragmentEvent(h)
        }
        #expect(h.store.state.queuedFragmentCount == 3)
        #expect(h.store.state.counters.requestsAnswered == 1)
        await stopMeshInterface(h)
    }

    @Test func requestCacheKeepsOnlyTheLast16Packets() async {
        let h = await makeOnlineMeshInterface(modemPreset: shortTurbo)
        for seed in 0..<17 { await h.store.send(.send(meshPattern(10, seed: seed))) }
        await receiveSent(h)
        await drainMeshFrames(h, every: .milliseconds(400), count: 16)
        await h.clock.advance(by: .milliseconds(400))
        await h.store.receive { $0 == .pacingElapsed }
        h.radio.yield(.fragment(from: meshPeerNode, request(0, 1)))     // evicted: index 0 is the 17th-newest
        await receiveFragmentEvent(h)
        h.radio.yield(.fragment(from: meshPeerNode, request(1, 1)))     // retained
        await receiveSent(h)
        #expect(h.store.state.counters.requestsAnswered == 1)
        await stopMeshInterface(h)
    }

    // Review Focus 5.
    @Test func packetIndexWrapsFrom255To0() async {
        var initial = MeshtasticInterface.State(config: meshTestConfig)
        initial.nextIndex = 255
        let h = await makeOnlineMeshInterface(modemPreset: longFast, initial: initial)
        await h.store.send(.send(meshPattern(10, seed: 1)))
        await h.store.send(.send(meshPattern(10, seed: 2)))
        await receiveSent(h)
        #expect(h.calls.value.sentFrames.first?.first == 255)
        #expect(h.store.state.queue.first?.frame.first == 0)
        await stopMeshInterface(h)
    }

    // Review Focus 5.
    @Test func requestAfterTheWrapIsAnsweredFromTheNewestPacket() async {
        var initial = MeshtasticInterface.State(config: meshTestConfig)
        initial.nextIndex = 255
        initial.sentCache = [.init(index: 0, fragments: [Data([0, 0xFF, 0xEE])])]   // a stale index 0
        let h = await makeOnlineMeshInterface(modemPreset: shortTurbo, initial: initial)
        await h.store.send(.send(meshPattern(10, seed: 1)))       // index 255
        await h.store.send(.send(meshPattern(10, seed: 2)))       // index 0 (wrapped)
        await receiveSent(h)
        await drainMeshFrames(h, every: .milliseconds(400), count: 1)
        await h.clock.advance(by: .milliseconds(400))
        await h.store.receive { $0 == .pacingElapsed }
        h.radio.yield(.fragment(from: meshPeerNode, request(0, 1)))
        await receiveSent(h)
        #expect(h.calls.value.sentFrames.last == codec.split(meshPattern(10, seed: 2), index: 0)[0])
        await stopMeshInterface(h)
    }

    @Test func disconnectEmptiesTheSendQueue() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        await h.store.send(.send(meshPattern(500, seed: 1)))
        await receiveSent(h)
        h.radio.yield(.disconnected(reason: nil))
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        #expect(h.store.state.queuedFragmentCount == 0)
        await stopMeshInterface(h)
    }

    @Test func firstSendAfterReconnectGoesOutImmediately() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        await h.store.send(.send(meshPattern(500, seed: 1)))
        await receiveSent(h)
        h.radio.yield(.disconnected(reason: nil))
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        h.radio.yield(.connected(myNodeNum: meshOwnNode, modemPreset: longFast))
        await h.store.receive { if case .delegate(.online) = $0 { return true }; return false }
        await h.store.send(.send(meshPattern(10, seed: 3)))
        await receiveSent(h)
        #expect(h.calls.value.sentFrames.last == codec.split(meshPattern(10, seed: 3), index: 1)[0])
        await stopMeshInterface(h)
    }

    @Test func requestCacheSurvivesADisconnect() async {
        let h = await makeOnlineMeshInterface(modemPreset: shortTurbo)
        let frame = codec.split(meshPattern(10, seed: 1), index: 0)[0]
        await h.store.send(.send(meshPattern(10, seed: 1)))
        await receiveSent(h)
        await h.clock.advance(by: .milliseconds(400))
        await h.store.receive { $0 == .pacingElapsed }
        h.radio.yield(.disconnected(reason: nil))
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        h.radio.yield(.connected(myNodeNum: meshOwnNode, modemPreset: shortTurbo))
        await h.store.receive { if case .delegate(.online) = $0 { return true }; return false }
        h.radio.yield(.fragment(from: meshPeerNode, request(0, 1)))
        await receiveSent(h)
        #expect(h.calls.value.sentFrames == [frame, frame])
        await stopMeshInterface(h)
    }

    @Test func repeatedConnectedEventAdoptsTheNewPresetDelay() async {
        let h = await makeOnlineMeshInterface(modemPreset: longFast)
        h.radio.yield(.connected(myNodeNum: meshOwnNode, modemPreset: shortTurbo))
        await h.store.receive { $0 == .delegate(.online(myNodeNum: meshOwnNode, modemPreset: shortTurbo)) }
        await h.store.send(.send(meshPattern(300, seed: 5)))
        await receiveSent(h)
        await h.clock.advance(by: .milliseconds(400))
        await receiveSent(h)
        #expect(h.calls.value.sentFrames.count == 2)
        await stopMeshInterface(h)
    }

    /// landandair's process_outgoing for the same three packets: index from 0, queue order.
    @Test func outgoingFramesMatchTheReferenceSender() async throws {
        let fixtures = try MeshtasticFixtures.load()
        let h = await makeOnlineMeshInterface(modemPreset: shortTurbo)
        for packet in fixtures.outgoing.packets { await h.store.send(.send(meshData(hex: packet))) }
        await receiveSent(h)
        await drainMeshFrames(h, every: .milliseconds(400), count: fixtures.outgoing.frames.count - 1)
        #expect(h.calls.value.sentFrames == fixtures.outgoing.frames.map(meshData(hex:)))
        await stopMeshInterface(h)
    }

    /// landandair's answer to each REQ, after the same three packets.
    @Test func requestAnswersMatchTheReferenceSender() async throws {
        let fixtures = try MeshtasticFixtures.load()
        let h = await makeOnlineMeshInterface(modemPreset: shortTurbo)
        for packet in fixtures.outgoing.packets { await h.store.send(.send(meshData(hex: packet))) }
        await receiveSent(h)
        await drainMeshFrames(h, every: .milliseconds(400), count: fixtures.outgoing.frames.count - 1)
        await h.clock.advance(by: .milliseconds(400))
        await h.store.receive { $0 == .pacingElapsed }
        #expect(fixtures.requestAnswers.count == 4)
        for answer in fixtures.requestAnswers {
            h.radio.yield(.fragment(from: meshPeerNode, meshData(hex: answer.request)))
            await receiveSent(h)
            #expect(h.calls.value.sentFrames.last == meshData(hex: answer.answer), "request \(answer.request)")
            await h.clock.advance(by: .milliseconds(400))
            await h.store.receive { $0 == .pacingElapsed }
        }
        await stopMeshInterface(h)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter MeshtasticInterfaceSenderTests`
Expected: build FAILS (`type 'MeshtasticInterface.Action' has no member 'send'`, `no member 'queue'`).

- [ ] **Step 4: Replace the reducer with the full version**

Replace the entire contents of `Sources/ReTiCAInterfaces/Meshtastic/MeshtasticInterface.swift` with:

```swift
import Foundation
import ComposableArchitecture

/// Where a `MeshtasticInterface` is in its radio lifecycle.
public enum MeshtasticInterfaceStatus: Equatable, Sendable {
    /// Not started, or stopped by `.stop`.
    case stopped
    /// Started, waiting for the driver's `.connected` (first connect, or after a drop —
    /// reconnecting is MeshtasticKit's job; the interface only waits).
    case connecting
    /// The radio finished its handshake. `modemPreset` is the raw `Config.LoRaConfig.ModemPreset`.
    case online(myNodeNum: UInt32, modemPreset: Int?)
    /// The driver reported the adapter unavailable. A fresh `.start` leaves this state.
    case unavailable(BLEAdapterUnavailable)
}

/// The radio's diagnostics, publicly readable for the app (spec amendment, 2026-10-16): the
/// reassembler's five counters plus the sender's two. Exposed as `MeshtasticEndpoint.State.counters`.
public struct MeshtasticCounters: Equatable, Sendable {
    public var malformed: Int
    public var evicted: Int
    public var timedOut: Int
    public var oversize: Int
    public var completed: Int
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

/// Reticulum over ONE Meshtastic radio, in landandair/RNS_Over_Meshtastic's fragment format
/// (spec 2026-10-16 §5). Owns the driver lifecycle, inbound reassembly keyed by sending node, and
/// the paced sender: a FIFO of framed fragments, one per `fragmentDelay(preset)` on an injected
/// clock (the first immediately), with REQ answering from a cache of the last 16 packets. It never
/// emits REQ.
@Reducer
public struct MeshtasticInterface {
    /// landandair's queue cap (`process_outgoing`, Meshtastic_Interface.py:212).
    public static let queueCapacity = 256
    /// Packets whose fragments are retained to answer REQ frames.
    public static let requestCacheSize = 16

    public struct Counters: Equatable, Sendable {
        /// Packets dropped whole because their fragments did not fit the queue.
        public var queueFull = 0
        /// Fragments the driver reported as not sent (radio not connected, or the write failed).
        public var sendFailed = 0
        /// REQ frames that re-queued a cached fragment.
        public var requestsAnswered = 0
        public init() {}
    }

    struct QueuedFragment: Equatable, Sendable {
        var frame: Data
        /// A REQ answer: queued at the front and not counted against `queueCapacity`.
        var isRetransmit: Bool
    }

    struct SentPacket: Equatable, Sendable {
        var index: UInt8
        var fragments: [Data]
    }

    @ObservableState
    public struct State: Equatable {
        public let config: MeshtasticDriverConfig
        public let framing: MeshtasticFraming
        public internal(set) var status: MeshtasticInterfaceStatus = .stopped
        public internal(set) var counters = Counters()
        public internal(set) var reassembler = MeshtasticReassembler()
        var queue: [QueuedFragment] = []
        /// landandair's per-interface packet index: starts at 0 (Meshtastic_Interface.py:128) and
        /// wraps at 256 (`calc_index`, L419-420). Advanced only when a packet is actually queued.
        var nextIndex: UInt8 = 0
        /// Oldest first, at most `requestCacheSize`, at most one entry per index (the newest).
        var sentCache: [SentPacket] = []
        /// A fragment went out and its pacing delay has not yet elapsed.
        var pacing = false

        public init(config: MeshtasticDriverConfig, framing: MeshtasticFraming = .landandair) {
            self.config = config
            self.framing = framing
        }

        public var isOnline: Bool {
            if case .online = status { return true }
            return false
        }

        public var modemPreset: Int? {
            if case let .online(_, preset) = status { return preset }
            return nil
        }

        public var queuedFragmentCount: Int { queue.count }

        /// Reassembler and sender counters in one public value (read by `MeshtasticEndpoint`).
        public var diagnostics: MeshtasticCounters {
            let r = reassembler.counters
            return MeshtasticCounters(malformed: r.malformed, evicted: r.evicted, timedOut: r.timedOut,
                                      oversize: r.oversize, completed: r.completed,
                                      queueFull: counters.queueFull, sendFailed: counters.sendFailed)
        }
    }

    public enum Action: Equatable {
        case start
        case stop
        /// One Reticulum packet (already IFAC-masked by the endpoint) to fragment and send.
        case send(Data)
        case driverEvent(MeshtasticDriverEvent)
        case fragmentSent(ok: Bool)
        case pacingElapsed
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case online(myNodeNum: UInt32, modemPreset: Int?)
            case offline(reason: String?)
            case packetReceived(Data)
            case adapterUnavailable(BLEAdapterUnavailable)
        }
    }

    @Dependency(\.meshtasticDriver) var driver
    @Dependency(\.meshtasticClock) var clock
    @Dependency(\.meshtasticDate) var date

    private enum CancelID: Hashable { case driver, pacing }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .start:
                switch state.status {
                case .stopped, .unavailable: break
                case .connecting, .online: return .none
                }
                state.status = .connecting
                let config = state.config
                return .run { [driver] send in
                    for await event in driver.start(config) {
                        await send(.driverEvent(event))
                    }
                }
                .cancellable(id: CancelID.driver, cancelInFlight: true)

            case .stop:
                guard state.status != .stopped else { return .none }
                let wasOnline = state.isOnline
                state.status = .stopped
                clearTraffic(&state)
                var effects: [Effect<Action>] = [.cancel(id: CancelID.driver),
                                                 .cancel(id: CancelID.pacing),
                                                 .run { [driver] _ in await driver.stop() }]
                if wasOnline { effects.append(.send(.delegate(.offline(reason: nil)))) }
                return .merge(effects)

            case let .driverEvent(.connected(myNodeNum, modemPreset)):
                guard state.status != .stopped else { return .none }
                state.status = .online(myNodeNum: myNodeNum, modemPreset: modemPreset)
                return .merge(.send(.delegate(.online(myNodeNum: myNodeNum, modemPreset: modemPreset))),
                              pump(&state))

            case let .driverEvent(.disconnected(reason)):
                guard state.status != .stopped else { return .none }
                let wasOnline = state.isOnline
                state.status = .connecting
                clearTraffic(&state)
                var effects: [Effect<Action>] = [.cancel(id: CancelID.pacing)]
                if wasOnline { effects.append(.send(.delegate(.offline(reason: reason)))) }
                return .merge(effects)

            case let .driverEvent(.unavailable(cause)):
                guard state.status != .stopped else { return .none }
                let wasOnline = state.isOnline
                state.status = .unavailable(cause)
                clearTraffic(&state)
                var effects: [Effect<Action>] = [.cancel(id: CancelID.pacing)]
                if wasOnline { effects.append(.send(.delegate(.offline(reason: nil)))) }
                effects.append(.send(.delegate(.adapterUnavailable(cause))))
                return .merge(effects)

            case let .driverEvent(.fragment(from, frame)):
                guard state.isOnline else { return .none }
                switch state.framing.codec.parse(frame) {
                case nil:
                    state.reassembler.recordMalformed()
                    return .none
                case let .data(index, pos, body):
                    guard let packet = state.reassembler.receive(from: from, index: index, pos: pos,
                                                                 body: body, now: date())
                    else { return .none }
                    return .send(.delegate(.packetReceived(packet)))
                case let .request(index, pos):
                    return answerRequest(&state, index: index, pos: pos)
                }

            case let .send(packet):
                guard state.isOnline else { return .none }
                let index = state.nextIndex
                let fragments = state.framing.codec.split(packet, index: index)
                guard !fragments.isEmpty else { return .none }
                let pending = state.queue.lazy.filter { !$0.isRetransmit }.count
                guard pending + fragments.count <= Self.queueCapacity else {
                    state.counters.queueFull += 1
                    return .none
                }
                state.queue.append(contentsOf: fragments.map { QueuedFragment(frame: $0, isRetransmit: false) })
                state.sentCache.removeAll { $0.index == index }
                state.sentCache.append(SentPacket(index: index, fragments: fragments))
                if state.sentCache.count > Self.requestCacheSize {
                    state.sentCache.removeFirst(state.sentCache.count - Self.requestCacheSize)
                }
                state.nextIndex &+= 1
                return pump(&state)

            case let .fragmentSent(ok):
                if !ok { state.counters.sendFailed += 1 }
                return .none

            case .pacingElapsed:
                state.pacing = false
                return pump(&state)

            case .delegate:
                return .none
            }
        }
    }

    /// Send the queue head now if the radio is online and no pacing window is open. landandair
    /// sleeps after EVERY send (L304); we do the same but never delay the first.
    private func pump(_ state: inout State) -> Effect<Action> {
        guard state.isOnline, !state.pacing, !state.queue.isEmpty else { return .none }
        let frame = state.queue.removeFirst().frame
        state.pacing = true
        let delay = MeshtasticModemPreset.fragmentDelay(state.modemPreset)
        return .run { [driver, clock] send in
            let ok = await driver.send(frame)
            await send(.fragmentSent(ok: ok))
            try await clock.sleep(for: delay)
            await send(.pacingElapsed)
        }
        .cancellable(id: CancelID.pacing, cancelInFlight: true)
    }

    /// A REQ for (index, |pos|) re-queues that cached fragment at the FRONT. Unknown index or
    /// out-of-range position: ignored. A fragment already queued is not queued again — any peer
    /// can broadcast REQs, so without that the front of the queue would grow without bound.
    private func answerRequest(_ state: inout State, index: UInt8, pos: Int8) -> Effect<Action> {
        let slot = Int(pos.magnitude)   // never abs(): abs(Int8.min) traps
        guard let packet = state.sentCache.last(where: { $0.index == index }),
              (1...packet.fragments.count).contains(slot)
        else { return .none }
        let frame = packet.fragments[slot - 1]
        guard !state.queue.contains(where: { $0.frame == frame }) else { return .none }
        state.queue.insert(QueuedFragment(frame: frame, isRetransmit: true), at: 0)
        state.counters.requestsAnswered += 1
        return pump(&state)
    }

    /// A drop: forget queued fragments, partial packets and the pacing window. The REQ cache and
    /// the index survive — a peer may still ask for a fragment it missed before the drop.
    private func clearTraffic(_ state: inout State) {
        state.queue = []
        state.pacing = false
        state.reassembler.reset()
    }
}
```

- [ ] **Step 5: Run both interface suites (rule step a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter MeshtasticInterfaceSenderTests`
Expected: 20 tests pass.

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter MeshtasticInterfaceLifecycleTests`
Expected: 11 tests pass (regression).

- [ ] **Step 6: Mutate in one batch (rule step b)**

Apply together in `MeshtasticInterface.swift`, run `MeshtasticInterfaceSenderTests` once, and confirm all 19 non-trap tests FAIL:

| ID | Mutation | Breaks |
|---|---|---|
| P1 | `pump` effect: move `try await clock.sleep(for: delay)` above `let ok = await driver.send(frame)` | `firstFragmentGoesOutImmediately` |
| P2 | `pump`: `let delay = MeshtasticModemPreset.fragmentDelay(nil)` | `nextFragmentWaitsTheFullLongFastDelay`, `shortTurboPacesFragmentsAt400Milliseconds`, `repeatedConnectedEventAdoptsTheNewPresetDelay` |
| P3 | `.send`: delete the whole `guard pending + fragments.count <= ...` block | `packetThatDoesNotFitIsDroppedWhole`, `droppedPacketDoesNotConsumeAnIndex` |
| P4 | `.fragmentSent`: body `if !ok { state.queue = [] }` (drops the counter, empties the queue) | `failedDriverSendIncrementsSendFailed`, `pacingContinuesAfterAFailedSend` |
| P5 | `answerRequest`: `state.queue.append(QueuedFragment(frame: frame, isRetransmit: true))` in place of the `insert(..., at: 0)` | `requestedFragmentJumpsTheQueue` |
| P6 | `answerRequest`: `guard let packet = state.sentCache.last,` (ignores index) | `requestForAnIndexNeverSentIsIgnored`, `requestCacheKeepsOnlyTheLast16Packets` |
| P7 | `answerRequest`: replace the range check with `true` and use `let frame = packet.fragments[min(slot, packet.fragments.count) - 1]` | `requestPastThePacketsLastFragmentIsIgnored` |
| P8 | `answerRequest`: delete the `guard !state.queue.contains(...)` line | `repeatedRequestQueuesTheFragmentOnce` |
| P9 | `requestCacheSize = 17` | `requestCacheKeepsOnlyTheLast16Packets` |
| P10 | `.send`: `state.nextIndex = state.nextIndex == 255 ? 1 : state.nextIndex + 1` | `packetIndexWrapsFrom255To0` |
| P11 | `.send`: delete `state.sentCache.removeAll { $0.index == index }`, and in `answerRequest` use `state.sentCache.first(where:)` | `requestAfterTheWrapIsAnsweredFromTheNewestPacket` |
| P12 | `clearTraffic`: body only `state.reassembler.reset()`; `.disconnected`: `var effects: [Effect<Action>] = []` | `disconnectEmptiesTheSendQueue`, `firstSendAfterReconnectGoesOutImmediately` |
| P13 | `clearTraffic`: add `state.sentCache = []` | `requestCacheSurvivesADisconnect` |
| P14 | `pump`: `state.queue.removeLast().frame` | `outgoingFramesMatchTheReferenceSender`, `requestAnswersMatchTheReferenceSender` |

`requestWithPositionInt8MinIsIgnored` is trap-class (next step). It may also fail under P7, which is acceptable.

- [ ] **Step 7: Trap-class mutation (rule step b′)**

Apply alone: in `answerRequest`, `let slot = Int(abs(pos))`. Run `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter requestWithPositionInt8MinIsIgnored`. Expected: the run FAILS (crash). Revert.

- [ ] **Step 8: Revert and re-run (rule step c)**

Revert P1–P14. Run both step-5 commands. Expected: 20 + 11 pass.

- [ ] **Step 9: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface add Sources/ReTiCAInterfaces/Meshtastic/MeshtasticInterface.swift Tests/ReTiCAInterfacesTests/MeshtasticInterfaceTestSupport.swift Tests/ReTiCAInterfacesTests/MeshtasticInterfaceSenderTests.swift`

Write `/tmp/meshtastic-interface/commit-task-6.txt`:

```
feat: paced Meshtastic sender with REQ answering

One fragment per landandair speed_to_delay on an injected clock (first
immediately), all-or-nothing enqueue into a 256-fragment FIFO, REQ frames
answered from the last 16 packets at the queue front (each fragment queued
at most once), index wrapping 255 -> 0. A drop clears the queue, the
pacing window and partial packets, and keeps the REQ cache. Outgoing order
and REQ answers match landandair's process_outgoing / write_loop.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface commit -F /tmp/meshtastic-interface/commit-task-6.txt`
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface log -1 "--format=%(trailers:key=Claude-Session,valueonly)"`

---

### Task 7: `MeshtasticEndpoint`, interface id, profile

**Files:**
- Create: `Sources/ReTiCANode/MeshtasticEndpoint.swift`
- Test: `Tests/ReTiCANodeTests/MeshtasticEndpointTests.swift`

**Interfaces:**
- Consumes: `MeshtasticInterface` (Tasks 5-6), `MeshtasticModemPreset.pacedBitrate` (Task 1), `InterfaceProfile`/`InterfaceID`/`IFAC` (`ReTiCATransport`).
- Produces:
  - `public func meshtasticInterfaceID(radio: UUID) -> InterfaceID`, giving `"meshtastic:" + radio.uuidString`
  - `extension InterfaceProfile { public static func meshtastic(modemPreset: Int?) -> InterfaceProfile }`
  - `MeshtasticEndpoint.ifacSize == 8`, `MeshtasticEndpoint.ifac(networkName:passphrase:) -> IFAC?`
  - `MeshtasticEndpoint.State(config: MeshtasticDriverConfig, profile: InterfaceProfile = .meshtastic(modemPreset: nil))` with `interface`, `profile`, `interfaceID`, `registeredProfile(modemPreset:) -> InterfaceProfile`, and `public var counters: MeshtasticCounters { get }` (spec amendment: lane E feeds the app's diagnostics from it)
  - `MeshtasticEndpoint.Action`: `.interface(MeshtasticInterface.Action)`, `.start`, `.stop`, `.delegate(.radioOnline(myNodeNum:modemPreset:) | .radioOffline(reason:) | .adapterUnavailable(BLEAdapterUnavailable))`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/MeshtasticEndpointTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let radio = UUID(uuidString: "0000AAAA-0000-0000-0000-00000000BEEF")!

@MainActor @Suite struct MeshtasticEndpointTests {
    @Test func profileBitrateIsThePacedRateOfThePreset() {
        let rows: [(Int?, Int)] = [(8, 4040), (6, 1616), (5, 538), (4, 404), (3, 269),
                                   (0, 202), (7, 134), (1, 107), (2, 230), (nil, 230)]
        for (preset, bitrate) in rows {
            #expect(InterfaceProfile.meshtastic(modemPreset: preset).bitrate == bitrate,
                    "preset \(String(describing: preset))")
        }
    }

    @Test func profileIsNamedMeshtastic() {
        #expect(InterfaceProfile.meshtastic(modemPreset: 0).name == "meshtastic")
    }

    @Test func profileDeclaresAHardwareMTUOf500() {
        #expect(InterfaceProfile.meshtastic(modemPreset: 0).hwMTU == 500)
    }

    @Test func profileModeIsTheTCPDefault() {
        #expect(InterfaceProfile.meshtastic(modemPreset: 0).mode == InterfaceProfile.tcp.mode)
    }

    @Test func registeredProfileTakesIFACFromTheEndpointProfile() {
        var profile = InterfaceProfile.meshtastic(modemPreset: nil)
        profile.ifac = MeshtasticEndpoint.ifac(networkName: "mesh", passphrase: "pw")
        let state = MeshtasticEndpoint.State(config: MeshtasticDriverConfig(radio: radio), profile: profile)
        #expect(state.registeredProfile(modemPreset: 8).ifac == profile.ifac)
    }

    @Test func registeredProfileTakesModeFromTheEndpointProfile() {
        var profile = InterfaceProfile.meshtastic(modemPreset: nil)
        profile.mode = .roaming
        let state = MeshtasticEndpoint.State(config: MeshtasticDriverConfig(radio: radio), profile: profile)
        #expect(state.registeredProfile(modemPreset: 8).mode == .roaming)
    }

    /// The endpoint's own profile bitrate is ignored: the radio's preset decides it at `.connected`.
    @Test func registeredProfileTakesBitrateFromThePreset() {
        let profile = InterfaceProfile(name: "meshtastic", bitrate: 999, hwMTU: 500)
        let state = MeshtasticEndpoint.State(config: MeshtasticDriverConfig(radio: radio), profile: profile)
        #expect(state.registeredProfile(modemPreset: 8).bitrate == 4040)
    }

    @Test func interfaceIDIsMeshtasticColonTheRadioUUID() {
        #expect(meshtasticInterfaceID(radio: radio) == InterfaceID("meshtastic:0000AAAA-0000-0000-0000-00000000BEEF"))
    }

    @Test func ifacHelperUsesEightByteAccessCodes() {
        #expect(MeshtasticEndpoint.ifac(networkName: "n", passphrase: "p") == IFAC(networkName: "n", passphrase: "p", size: 8))
    }

    @Test func endpointStartStartsTheRadioDriver() async {
        let config = MeshtasticDriverConfig(radio: radio, channel: 1, hopLimit: 2)
        let started = LockIsolated<[MeshtasticDriverConfig]>([])
        let stream = AsyncStream<MeshtasticDriverEvent>.makeStream()
        let store = TestStore(initialState: MeshtasticEndpoint.State(config: config)) {
            MeshtasticEndpoint()
        } withDependencies: {
            $0.meshtasticDriver = MeshtasticDriver(
                start: { cfg in
                    started.withValue { $0.append(cfg) }
                    return stream.stream
                },
                send: { _ in true },
                stop: {})
            $0.meshtasticClock = ImmediateClock()
        }
        store.exhaustivity = .off
        await store.send(.start)
        stream.continuation.yield(.connected(myNodeNum: 1, modemPreset: 8))
        await store.receive { if case .interface(.delegate(.online)) = $0 { return true }; return false }
        #expect(started.value == [config])
        await store.send(.stop)
        await store.skipReceivedActions(strict: false)
    }

    @Test func malformedFragmentShowsInTheEndpointCounters() async {
        let (store, radioEvents) = await makeOnlineEndpoint()
        radioEvents.yield(.fragment(from: 7, Data([0x01])))
        await store.receive { if case .interface(.driverEvent(.fragment)) = $0 { return true }; return false }
        #expect(store.state.counters.malformed == 1)
        await store.send(.stop)
        await store.skipReceivedActions(strict: false)
    }

    /// 85 three-fragment packets fill the queue (1 in flight + 254 queued, pacing clock never
    /// advanced); the 86th is dropped whole.
    @Test func queueFullDropShowsInTheEndpointCounters() async {
        let (store, _) = await makeOnlineEndpoint()
        let packet = Data(repeating: 0x5A, count: 500)
        for _ in 0..<86 { await store.send(.interface(.send(packet))) }
        #expect(store.state.counters.queueFull == 1)
        await store.send(.stop)
        await store.skipReceivedActions(strict: false)
    }
}

/// A MeshtasticEndpoint whose radio is online at LongFast, pacing on a TestClock that is never advanced.
@MainActor
private func makeOnlineEndpoint() async
    -> (TestStore<MeshtasticEndpoint.State, MeshtasticEndpoint.Action>, AsyncStream<MeshtasticDriverEvent>.Continuation) {
    let stream = AsyncStream<MeshtasticDriverEvent>.makeStream()
    let store = TestStore(initialState: MeshtasticEndpoint.State(config: MeshtasticDriverConfig(radio: radio))) {
        MeshtasticEndpoint()
    } withDependencies: {
        $0.meshtasticDriver = MeshtasticDriver(start: { _ in stream.stream }, send: { _ in true }, stop: {})
        $0.meshtasticClock = TestClock<Duration>()
        $0.meshtasticDate = DateGenerator { Date(timeIntervalSince1970: 0) }
    }
    store.exhaustivity = .off
    await store.send(.start)
    stream.continuation.yield(.connected(myNodeNum: 1, modemPreset: 0))
    await store.receive { if case .interface(.delegate(.online)) = $0 { return true }; return false }
    return (store, stream.continuation)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter MeshtasticEndpointTests`
Expected: build FAILS (`cannot find 'MeshtasticEndpoint' in scope`).

- [ ] **Step 3: Implement the endpoint**

Create `Sources/ReTiCANode/MeshtasticEndpoint.swift`:

```swift
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport

/// Transport `InterfaceID` for a Meshtastic radio: ONE id per radio (spec Contract 3). The radio is
/// a broadcast medium, so unlike BLE there is no per-peer interface; the id follows the TCP-client
/// lifecycle — registered at the radio's `.connected`, deregistered at `.disconnected`.
public func meshtasticInterfaceID(radio: UUID) -> InterfaceID {
    InterfaceID("meshtastic:" + radio.uuidString)
}

extension InterfaceProfile {
    /// Contract 3: name "meshtastic", hwMTU 500, the `.tcp` default mode, and the EFFECTIVE paced
    /// bitrate of the preset (`Int(202 * 8 / fragmentDelay(preset))`) — what the sender can
    /// actually put on the air, not the LoRa symbol rate.
    ///
    /// Lives here, not in `InterfaceProfile.swift`: the preset table is shared with
    /// `MeshtasticInterface` in `ReTiCAInterfaces`, which `ReTiCATransport` does not depend on.
    public static func meshtastic(modemPreset: Int?) -> InterfaceProfile {
        InterfaceProfile(name: "meshtastic", bitrate: MeshtasticModemPreset.pacedBitrate(modemPreset), hwMTU: 500)
    }
}

/// A Meshtastic DRIVER: the `MeshtasticInterface` plus the endpoint profile the shared router
/// needs. Like the other drivers it owns no `Transport` or `LinkPlane`; `TransportEndpoint` does
/// all the wiring against `interfaceID`.
@Reducer
public struct MeshtasticEndpoint {
    /// landandair's `DEFAULT_IFAC_SIZE` (Meshtastic_Interface.py:30). A peer configured with a
    /// different size cannot interoperate.
    public static let ifacSize = 8

    /// The IFAC to put in a Meshtastic endpoint's profile: always 8-byte access codes.
    public static func ifac(networkName: String?, passphrase: String?) -> IFAC? {
        IFAC(networkName: networkName, passphrase: passphrase, size: ifacSize)
    }

    @ObservableState
    public struct State: Equatable {
        public var interface: MeshtasticInterface.State
        /// Supplies ONLY the IFAC and the mode. The bitrate is the radio's, known at `.connected`.
        public let profile: InterfaceProfile

        public var interfaceID: InterfaceID { meshtasticInterfaceID(radio: interface.config.radio) }

        /// The radio's diagnostics (reassembly + sender), read-only, for the app's diagnostics view.
        public var counters: MeshtasticCounters { interface.diagnostics }

        public init(config: MeshtasticDriverConfig, profile: InterfaceProfile = .meshtastic(modemPreset: nil)) {
            self.interface = MeshtasticInterface.State(config: config)
            self.profile = profile
        }

        /// The profile registered with the shared router when the radio comes online.
        public func registeredProfile(modemPreset: Int?) -> InterfaceProfile {
            var registered = InterfaceProfile.meshtastic(modemPreset: modemPreset)
            registered.mode = profile.mode
            registered.ifac = profile.ifac
            return registered
        }
    }

    public enum Action: Equatable {
        case interface(MeshtasticInterface.Action)
        case start
        case stop
        case delegate(Delegate)

        /// Meshtastic-only — observe via `TransportEndpoint`'s `.meshtastic(.delegate(...))` hatch;
        /// deliberately absent from the unified surface (LXMF has no use for them).
        @CasePathable
        public enum Delegate: Equatable {
            case radioOnline(myNodeNum: UInt32, modemPreset: Int?)
            case radioOffline(reason: String?)
            case adapterUnavailable(BLEAdapterUnavailable)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.interface, action: \.interface) { MeshtasticInterface() }
        Reduce { _, action in
            switch action {
            case .start:                return .send(.interface(.start))
            case .stop:                 return .send(.interface(.stop))
            case .interface, .delegate: return .none
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass (rule step a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter MeshtasticEndpointTests`
Expected: 12 tests pass.

- [ ] **Step 5: Mutate in one batch (rule step b)**

Apply together, run once, and confirm all 12 FAIL. All rows are in `MeshtasticEndpoint.swift` except the two `diagnostics` rows, which are in `MeshtasticInterface.swift`:

| Mutation | Breaks |
|---|---|
| `meshtastic(modemPreset:)`: `bitrate: MeshtasticModemPreset.pacedBitrate(nil)` | `profileBitrateIsThePacedRateOfThePreset`, `registeredProfileTakesBitrateFromThePreset` |
| `name: "mesh"` | `profileIsNamedMeshtastic` |
| `hwMTU: 564` | `profileDeclaresAHardwareMTUOf500` |
| add `mode: .gateway,` to that initializer | `profileModeIsTheTCPDefault` |
| `registeredProfile`: delete `registered.ifac = profile.ifac` | `registeredProfileTakesIFACFromTheEndpointProfile` |
| `registeredProfile`: delete `registered.mode = profile.mode` | `registeredProfileTakesModeFromTheEndpointProfile` (the gateway row also breaks it) |
| `meshtasticInterfaceID`: `radio.uuidString.lowercased()` | `interfaceIDIsMeshtasticColonTheRadioUUID` |
| `ifacSize = 16` | `ifacHelperUsesEightByteAccessCodes` |
| `.start: return .none` | `endpointStartStartsTheRadioDriver`, and both counters tests (their setup never comes online) |
| `MeshtasticInterface.swift` `diagnostics`: `malformed: 0` | `malformedFragmentShowsInTheEndpointCounters` |
| `MeshtasticInterface.swift` `diagnostics`: `queueFull: 0` | `queueFullDropShowsInTheEndpointCounters` |

The `.start` row already breaks the counters tests through their setup. To prove each counters test reads its own field, run once more with ONLY the two `diagnostics` rows applied. Expected: exactly those two tests fail.

- [ ] **Step 6: Revert and re-run (rule step c)**

Revert, run the step-4 command. Expected: 12 pass.

- [ ] **Step 7: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface add Sources/ReTiCANode/MeshtasticEndpoint.swift Tests/ReTiCANodeTests/MeshtasticEndpointTests.swift`

Write `/tmp/meshtastic-interface/commit-task-7.txt`:

```
feat: MeshtasticEndpoint driver wrapper and Meshtastic interface profile

One interface id per radio (meshtastic:<UUID>), InterfaceProfile.meshtastic
(modemPreset:) with the effective paced bitrate, a registered profile that
takes IFAC and mode from the endpoint but bitrate from the radio's preset,
an IFAC helper fixed at landandair's 8-byte access codes, and public
read-only MeshtasticCounters on the endpoint state for app diagnostics.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface commit -F /tmp/meshtastic-interface/commit-task-7.txt`
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface log -1 "--format=%(trailers:key=Claude-Session,valueonly)"`

---

### Task 8: `TransportEndpoint` wiring

**Files:**
- Modify: `Sources/ReTiCANode/TransportEndpoint.swift`. The touch points, at the current line numbers:
  - state slot :38-39 and init :55-65
  - factory :77-80
  - action :91
  - start/stop :155-162
  - new arms before :288
  - catch-all :362
  - `.ifLet` :371
  - transmit :417-424
- Test: `Tests/ReTiCANodeTests/TransportEndpointMeshtasticTests.swift`

**Interfaces:**
- Consumes: `MeshtasticEndpoint`, `meshtasticInterfaceID`, `InterfaceProfile.meshtastic` (Task 7); `MeshtasticInterface.Action.send`, `.fragmentSent`, `State.isOnline` (Task 6); `LandandairCodec` (Task 2).
- Produces:
  - `TransportEndpoint.State.meshtastic: MeshtasticEndpoint.State?`, `State.init(..., meshtastic:)`, `State.meshtastic(_:)` factory
  - `TransportEndpoint.Action.meshtastic(MeshtasticEndpoint.Action)`
  - `.start`/`.stop` reach the radio
  - `.meshtastic(.delegate(.radioOnline/.radioOffline/.adapterUnavailable))` on the hatch

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/TransportEndpointMeshtasticTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let radioUUID = UUID(uuidString: "0000AAAA-0000-0000-0000-00000000BEEF")!
private let radioID = meshtasticInterfaceID(radio: radioUUID)
private let tcpID = InterfaceID("tcp")
private let ownNode: UInt32 = 0x0A0A_0A0A
private let peerNode: UInt32 = 0x0B0B_0B0B

/// Records every maintenance start/stop the wrapped reducer processes, exactly once each.
private struct MeshMaintenanceRecorder<Wrapped: Reducer>: Reducer
where Wrapped.State == TransportEndpoint.State, Wrapped.Action == TransportEndpoint.Action {
    let log: LockIsolated<[String]>
    let wrapped: Wrapped
    init(log: LockIsolated<[String]>, @ReducerBuilder<State, Action> _ wrapped: () -> Wrapped) {
        self.log = log
        self.wrapped = wrapped()
    }
    func reduce(into state: inout TransportEndpoint.State, action: TransportEndpoint.Action)
        -> Effect<TransportEndpoint.Action> {
        if case .transport(.startMaintenance) = action { log.withValue { $0.append("start") } }
        if case .transport(.stopMaintenance) = action { log.withValue { $0.append("stop") } }
        return wrapped.reduce(into: &state, action: action)
    }
}

@MainActor
private struct MeshEndpointHarness {
    let store: TestStore<TransportEndpoint.State, TransportEndpoint.Action>
    let radio: AsyncStream<MeshtasticDriverEvent>.Continuation
    let onAir: LockIsolated<[Data]>
    let tcp: AsyncStream<TCPEvent>.Continuation
    let now: LockIsolated<Date>
    let clock: TestClock<Duration>
    let maintenance: LockIsolated<[String]>
}

@MainActor
private func makeMeshEndpoint(profile: InterfaceProfile = .meshtastic(modemPreset: nil),
                              withTCPClient: Bool = false,
                              liveDriver: Bool = false) -> MeshEndpointHarness {
    let radio = AsyncStream<MeshtasticDriverEvent>.makeStream()
    let tcp = AsyncStream<TCPEvent>.makeStream()
    let onAir = LockIsolated<[Data]>([])
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let clock = TestClock<Duration>()
    let log = LockIsolated<[String]>([])
    let initial = TransportEndpoint.State(
        tcpClients: withTCPClient ? [TCPEndpoint.State(host: "peer", port: 4242, reconnectOnDrop: false)] : [],
        meshtastic: MeshtasticEndpoint.State(config: MeshtasticDriverConfig(radio: radioUUID), profile: profile))
    let mock = MeshtasticDriver(
        start: { _ in radio.stream },
        send: { frame in
            onAir.withValue { $0.append(frame) }
            return true
        },
        stop: {})
    let store = TestStore(initialState: initial) {
        MeshMaintenanceRecorder(log: log) { TransportEndpoint() }
    } withDependencies: {
        $0.meshtasticDriver = liveDriver ? MeshtasticDriver.liveValue : mock
        $0.meshtasticClock = ImmediateClock()
        $0.meshtasticDate = DateGenerator { Date(timeIntervalSince1970: 0) }
        $0.tcpConnection = TCPConnection(open: { _, _ in tcp.stream }, send: { _ in }, close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.transportDate = DateGenerator { now.value }
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return MeshEndpointHarness(store: store, radio: radio.continuation, onAir: onAir, tcp: tcp.continuation,
                               now: now, clock: clock, maintenance: log)
}

@MainActor
private func bringRadioOnline(_ h: MeshEndpointHarness, preset: Int? = 8, start: Bool = true) async {
    if start { await h.store.send(.start) }
    h.radio.yield(.connected(myNodeNum: ownNode, modemPreset: preset))
    await h.store.receive { if case .transport(.interfaceConnected(radioID, _)) = $0 { return true }; return false }
}

@MainActor
private func stopEndpoint(_ h: MeshEndpointHarness) async {
    await h.store.send(.stop)
    await h.store.skipReceivedActions(strict: false)
}

private func makeAnnounce(hops: UInt8 = 0, emitted: UInt64 = 1000) -> (raw: Data, destinationHash: Data) {
    let identity = Identity()
    let nameHash = Destination.nameHash(appName: "app", aspects: ["svc"])
    let destHash = Destination.hash(identityHash: identity.hash, appName: "app", aspects: ["svc"])
    let randomHash = Announce.randomHash(now: emitted, randomPrefix: Data(repeating: 0xA5, count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, appData: nil)
    let packet = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: hops,
                        destinationHash: destHash, transportId: nil, payload: payload)
    return (try! packet.packed(), destHash)
}

@MainActor @Suite struct TransportEndpointMeshtasticTests {
    @Test func radioOnlineRegistersItsInterfaceWithThePresetProfile() async {
        let h = makeMeshEndpoint()
        await bringRadioOnline(h, preset: 8)
        #expect(h.store.state.interfaces[radioID] == InterfaceProfile.meshtastic(modemPreset: 8))
        await stopEndpoint(h)
    }

    @Test func newPresetWhileOnlineReRegistersWithItsBitrate() async {
        let h = makeMeshEndpoint()
        await bringRadioOnline(h, preset: 8)
        h.radio.yield(.connected(myNodeNum: ownNode, modemPreset: 4))
        await h.store.receive { action in
            if case let .transport(.interfaceConnected(id, profile)) = action { return id == radioID && profile.bitrate == 404 }
            return false
        }
        #expect(h.store.state.interfaces[radioID]?.bitrate == 404)
        await stopEndpoint(h)
    }

    @Test func radioOnlineSurfacesOnTheMeshtasticHatch() async {
        let h = makeMeshEndpoint()
        await h.store.send(.start)
        h.radio.yield(.connected(myNodeNum: ownNode, modemPreset: 8))
        await h.store.receive { $0 == .meshtastic(.delegate(.radioOnline(myNodeNum: ownNode, modemPreset: 8))) }
        await stopEndpoint(h)
    }

    @Test func radioDropDeregistersItsInterface() async {
        let h = makeMeshEndpoint()
        await bringRadioOnline(h)
        h.radio.yield(.disconnected(reason: "gone"))
        await h.store.receive { $0 == .transport(.interfaceDisconnected(radioID)) }
        #expect(h.store.state.interfaces[radioID] == nil)
        await stopEndpoint(h)
    }

    @Test func radioDropSurfacesOnTheMeshtasticHatch() async {
        let h = makeMeshEndpoint()
        await bringRadioOnline(h)
        h.radio.yield(.disconnected(reason: "gone"))
        await h.store.receive { $0 == .meshtastic(.delegate(.radioOffline(reason: "gone"))) }
        await stopEndpoint(h)
    }

    @Test func endpointStopDeregistersTheRadio() async {
        let h = makeMeshEndpoint()
        await bringRadioOnline(h)
        await h.store.send(.stop)
        await h.store.receive { $0 == .transport(.interfaceDisconnected(radioID)) }
        #expect(h.store.state.interfaces[radioID] == nil)
        await h.store.skipReceivedActions(strict: false)
    }

    @Test func inboundFragmentsReachTheRouterTaggedWithTheRadioID() async {
        let h = makeMeshEndpoint()
        await bringRadioOnline(h)
        let (raw, dest) = makeAnnounce()
        for frame in LandandairCodec().split(raw, index: 3) { h.radio.yield(.fragment(from: peerNode, frame)) }
        await h.store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
        #expect(h.store.state.learned[dest]?.interfaceID == radioID)
        await stopEndpoint(h)
    }

    @Test func transmitToTheRadioIDPutsThePacketOnTheAir() async {
        let h = makeMeshEndpoint()
        await bringRadioOnline(h)
        let (raw, _) = makeAnnounce()
        let expected = LandandairCodec().split(raw, index: 0)
        await h.store.send(.transport(.delegate(.transmit(radioID, raw))))
        for _ in expected {
            await h.store.receive { if case .meshtastic(.interface(.fragmentSent)) = $0 { return true }; return false }
        }
        #expect(h.onAir.value == expected)
        await stopEndpoint(h)
    }

    @Test func transmitOverAnIFACRadioMasksBeforeFragmenting() async {
        var profile = InterfaceProfile.meshtastic(modemPreset: nil)
        profile.ifac = MeshtasticEndpoint.ifac(networkName: "mesh", passphrase: "pw")
        let h = makeMeshEndpoint(profile: profile)
        await bringRadioOnline(h)
        let (raw, _) = makeAnnounce()
        let expected = LandandairCodec().split(profile.ifac!.protect(raw), index: 0)
        await h.store.send(.transport(.delegate(.transmit(radioID, raw))))
        for _ in expected {
            await h.store.receive { if case .meshtastic(.interface(.fragmentSent)) = $0 { return true }; return false }
        }
        #expect(h.onAir.value == expected)
        await stopEndpoint(h)
    }

    @Test func transmitWhileTheRadioIsOfflineReportsInterfaceUnavailable() async {
        let h = makeMeshEndpoint()
        await h.store.send(.start)                       // started, never connected
        let (raw, dest) = makeAnnounce()
        await h.store.send(.transport(.delegate(.transmit(radioID, raw))))
        await h.store.receive { $0 == .delegate(.sendFailed(destinationHash: dest, reason: .interfaceUnavailable)) }
        await stopEndpoint(h)
    }

    @Test func missingLiveAdapterSurfacesOnTheMeshtasticHatch() async {
        let h = makeMeshEndpoint(liveDriver: true)
        await h.store.send(.start)
        await h.store.receive {
            $0 == .meshtastic(.delegate(.adapterUnavailable(.other(MeshtasticDriver.liveAdapterMissing))))
        }
        await stopEndpoint(h)
    }
}

/// Shared maintenance must follow the SHARED interface count, never the radio slot's own state
/// (memory: multi-interface lesson; TransportEndpoint.swift:374-401).
@MainActor @Suite struct TransportEndpointMeshtasticMaintenanceTests {
    @Test func radioDropKeepsSharedMaintenanceAliveForTheTCPClient() async {
        let h = makeMeshEndpoint(withTCPClient: true)
        await h.store.send(.start)
        h.tcp.yield(.connected)
        await h.store.receive { $0 == .transport(.interfaceConnected(tcpID, .tcp)) }
        await bringRadioOnline(h, start: false)
        let (raw, dest) = makeAnnounce(hops: 3)
        h.tcp.yield(.data(HDLC.frame(raw)))
        await h.store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
        #expect(h.store.state.learned[dest]?.interfaceID == tcpID)

        h.radio.yield(.disconnected(reason: nil))
        await h.store.receive { $0 == .transport(.interfaceDisconnected(radioID)) }
        await h.store.skipReceivedActions(strict: false)
        #expect(h.store.state.interfaces.count == 1)

        h.now.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))
        await h.clock.advance(by: .seconds(Transport.maintenanceTickInterval))
        await h.store.skipReceivedActions(strict: false)
        #expect(h.store.state.learned[dest] == nil, "maintenance must survive the radio dropping while TCP is up")
        await stopEndpoint(h)
    }

    @Test func radioAsTheLastInterfaceToDropStopsSharedMaintenance() async {
        let h = makeMeshEndpoint(withTCPClient: true)
        await h.store.send(.start)
        h.tcp.yield(.connected)
        await h.store.receive { $0 == .transport(.interfaceConnected(tcpID, .tcp)) }
        await bringRadioOnline(h, start: false)
        let (raw, dest) = makeAnnounce(hops: 3)
        h.tcp.yield(.data(HDLC.frame(raw)))
        await h.store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }

        h.tcp.yield(.disconnected(reason: nil))           // TCP first: 2 → 1
        await h.store.receive { $0 == .transport(.interfaceDisconnected(tcpID)) }
        h.radio.yield(.disconnected(reason: nil))         // the radio last: 1 → 0
        await h.store.receive { $0 == .transport(.interfaceDisconnected(radioID)) }
        await h.store.skipReceivedActions(strict: false)
        #expect(h.store.state.interfaces.isEmpty)

        h.now.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))
        await h.clock.advance(by: .seconds(Transport.maintenanceTickInterval))
        await h.store.skipReceivedActions(strict: false)
        #expect(h.store.state.learned[dest] != nil, "with every interface gone no tick may sweep")
        await stopEndpoint(h)
    }

    @Test func radioLifecycleWithALiveTCPClientArmsMaintenanceOnce() async {
        let h = makeMeshEndpoint(withTCPClient: true)
        await h.store.send(.start)
        h.tcp.yield(.connected)
        await h.store.receive { $0 == .transport(.interfaceConnected(tcpID, .tcp)) }
        await bringRadioOnline(h, preset: 8, start: false)
        await bringRadioOnline(h, preset: 4, start: false)     // preset change, no drop
        h.radio.yield(.disconnected(reason: nil))
        await h.store.receive { $0 == .transport(.interfaceDisconnected(radioID)) }
        await bringRadioOnline(h, preset: 8, start: false)     // reconnect
        await h.store.skipReceivedActions(strict: false)
        let starts = h.maintenance.value.filter { $0 == "start" }.count
        #expect(starts == 1, "only the node's 0 → 1 transition arms maintenance; saw \(starts)")
        await stopEndpoint(h)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter TransportEndpointMeshtasticTests`
Expected: build FAILS (`extra argument 'meshtastic' in call`).

- [ ] **Step 3: Wire the slot into `TransportEndpoint.swift`**

Make these nine edits with the Edit tool. Each old string is unique in the file.

Edit 1 (state slot). Replace:

```swift
        /// The BLE driver slot.
        public var ble: BLEEndpoint.State?
```

with:

```swift
        /// The BLE driver slot.
        public var ble: BLEEndpoint.State?
        /// The Meshtastic radio slot: at most one radio, with ONE `InterfaceID`
        /// (`meshtastic:<UUID>`) and the TCP-client lifecycle — registered when the radio comes
        /// online, deregistered when it drops. A broadcast medium has no per-peer interfaces.
        public var meshtastic: MeshtasticEndpoint.State?
```

Edit 2 (init). Replace:

```swift
                    ble: BLEEndpoint.State? = nil) {
            self.transport = transport
            self.linkPlane = linkPlane
            self.tcpClients = tcpClients
            self.tcpServer = tcpServer
            self.ble = ble
        }
```

with:

```swift
                    ble: BLEEndpoint.State? = nil,
                    meshtastic: MeshtasticEndpoint.State? = nil) {
            self.transport = transport
            self.linkPlane = linkPlane
            self.tcpClients = tcpClients
            self.tcpServer = tcpServer
            self.ble = ble
            self.meshtastic = meshtastic
        }
```

Edit 3 (factory). Replace:

```swift
        public static func ble(_ driver: BLEEndpoint.State) -> State {
            State(ble: driver)
        }
```

with:

```swift
        public static func ble(_ driver: BLEEndpoint.State) -> State {
            State(ble: driver)
        }

        /// Convenience factory: an endpoint running over one Meshtastic radio.
        public static func meshtastic(_ driver: MeshtasticEndpoint.State) -> State {
            State(meshtastic: driver)
        }
```

Edit 4 (action). Replace:

```swift
        case ble(BLEEndpoint.Action)
        case transport(Transport.Action)
```

with:

```swift
        case ble(BLEEndpoint.Action)
        case meshtastic(MeshtasticEndpoint.Action)
        case transport(Transport.Action)
```

Edit 5 (start/stop). Replace:

```swift
                              + [state.tcpServer != nil ? .send(.tcpServer(.start)) : .none,
                                 state.ble != nil ? .send(.ble(.start)) : .none])
```

with:

```swift
                              + [state.tcpServer != nil ? .send(.tcpServer(.start)) : .none,
                                 state.ble != nil ? .send(.ble(.start)) : .none,
                                 state.meshtastic != nil ? .send(.meshtastic(.start)) : .none])
```

and replace:

```swift
                              + [state.tcpServer != nil ? .send(.tcpServer(.stop)) : .none,
                                 state.ble != nil ? .send(.ble(.stop)) : .none])
```

with:

```swift
                              + [state.tcpServer != nil ? .send(.tcpServer(.stop)) : .none,
                                 state.ble != nil ? .send(.ble(.stop)) : .none,
                                 state.meshtastic != nil ? .send(.meshtastic(.stop)) : .none])
```

Edit 6 (lifecycle arms). Replace:

```swift
            // --- shared router delegates → interface / unified delegate ---
```

with:

```swift
            // --- Meshtastic radio lifecycle → shared router interface set (+ maintenance) ---
            // ONE InterfaceID per radio, the TCP-client shape. The preset — hence the paced
            // bitrate — is only known once the radio is configured, so the profile is computed
            // here. A repeated `.online` (preset changed, or a reconnect the driver reported
            // without a drop) re-registers with the new profile; maintenance is not re-armed
            // because the shared interface set is not empty.
            case let .meshtastic(.interface(.delegate(.online(myNodeNum, modemPreset)))):
                guard let mesh = state.meshtastic else { return .none }
                let id = mesh.interfaceID
                let startEffects = maintenanceStartEffect(state)
                return .merge([.send(.transport(.interfaceConnected(id, mesh.registeredProfile(modemPreset: modemPreset))))]
                              + startEffects
                              + [.send(.meshtastic(.delegate(.radioOnline(myNodeNum: myNodeNum,
                                                                           modemPreset: modemPreset))))])

            case let .meshtastic(.interface(.delegate(.offline(reason)))):
                guard let mesh = state.meshtastic else { return .none }
                let id = mesh.interfaceID
                var effects: [Effect<Action>] = []
                if state.transport.interfaces[id] != nil {
                    effects.append(.send(.transport(.interfaceDisconnected(id))))
                    effects.append(.send(.linkPlane(.interfaceDisconnected(id))))
                    effects.append(contentsOf: maintenanceStopEffect(state, departing: id))
                }
                effects.append(.send(.meshtastic(.delegate(.radioOffline(reason: reason)))))
                return .merge(effects)

            case let .meshtastic(.interface(.delegate(.packetReceived(packet)))):
                guard let mesh = state.meshtastic else { return .none }
                return .send(.transport(.received(mesh.interfaceID, packet)))

            // Like BLE's (S6), adapter unavailability is Meshtastic-hatch-only; the app consumes it.
            case let .meshtastic(.interface(.delegate(.adapterUnavailable(cause)))):
                return .send(.meshtastic(.delegate(.adapterUnavailable(cause))))

            // --- shared router delegates → interface / unified delegate ---
```

Edit 7 (catch-all). Replace:

```swift
            case .tcpClients, .tcpServer, .ble, .transport, .linkPlane, .link, .delegate,
```

with:

```swift
            case .tcpClients, .tcpServer, .ble, .meshtastic, .transport, .linkPlane, .link, .delegate,
```

Edit 8 (`.ifLet`). Replace:

```swift
        .ifLet(\.ble, action: \.ble) { BLEEndpoint() }
```

with:

```swift
        .ifLet(\.ble, action: \.ble) { BLEEndpoint() }
        .ifLet(\.meshtastic, action: \.meshtastic) { MeshtasticEndpoint() }
```

Edit 9 (transmit routing and the unavailable guard). Replace:

```swift
        if let peerToken = state.ble?.peerInterfaces[txID] {
            return .send(.ble(.ble(.send(peer: peerToken, packet: masked))))
        }
```

with:

```swift
        if let peerToken = state.ble?.peerInterfaces[txID] {
            return .send(.ble(.ble(.send(peer: peerToken, packet: masked))))
        }
        // The radio's ONE id, while the radio is online. Between a drop and the reconnect learned
        // paths still name it, so a send then falls through to `.interfaceUnavailable` below.
        let meshOwnsID = state.meshtastic?.interfaceID == txID
        if meshOwnsID, state.meshtastic?.interface.isOnline == true {
            return .send(.meshtastic(.interface(.send(masked))))
        }
```

and replace:

```swift
        guard state.ble != nil, let destHash = Packet(raw: unmasked)?.destinationHash else { return .none }
```

with:

```swift
        guard state.ble != nil || meshOwnsID, let destHash = Packet(raw: unmasked)?.destinationHash else { return .none }
```

- [ ] **Step 4: Run tests to verify they pass (rule step a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter TransportEndpointMeshtasticTests`
Expected: 11 pass.

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter TransportEndpointMeshtasticMaintenanceTests`
Expected: 3 pass.

Run (regression for every existing endpoint suite): `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter ReTiCANodeTests`
Expected: all pass. A signal-11 or stale-link failure means `swift package clean --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface`, then rerun.

- [ ] **Step 5: Mutate in one batch (rule step b)**

Apply together in `TransportEndpoint.swift`, run both new suites once, and confirm all 14 FAIL:

| ID | Mutation | Breaks |
|---|---|---|
| M1 | online arm: register `mesh.profile` in place of `mesh.registeredProfile(modemPreset: modemPreset)` | `radioOnlineRegistersItsInterfaceWithThePresetProfile`, `newPresetWhileOnlineReRegistersWithItsBitrate` |
| M2 | offline arm: delete `effects.append(.send(.transport(.interfaceDisconnected(id))))` | `radioDropDeregistersItsInterface`, `endpointStopDeregistersTheRadio` |
| M3 | packetReceived arm: `return .none` | `inboundFragmentsReachTheRouterTaggedWithTheRadioID` |
| M4 | transmit: delete the `if meshOwnsID, ... { return .send(.meshtastic(...)) }` block | `transmitToTheRadioIDPutsThePacketOnTheAir`, `transmitOverAnIFACRadioMasksBeforeFragmenting` |
| M5 | transmit guard back to `guard state.ble != nil, let destHash = ...` | `transmitWhileTheRadioIsOfflineReportsInterfaceUnavailable` |
| M6 | adapterUnavailable arm: `return .none` | `missingLiveAdapterSurfacesOnTheMeshtasticHatch` |
| M7 | offline arm: replace `maintenanceStopEffect(state, departing: id)` with `(state.transport.interfaces.count > 1 ? [.send(.transport(.stopMaintenance))] : [])` (inverted predicate) | `radioDropKeepsSharedMaintenanceAliveForTheTCPClient`, `radioAsTheLastInterfaceToDropStopsSharedMaintenance` |
| M8 | online arm: `let startEffects: [Effect<Action>] = [.send(.transport(.startMaintenance))]` | `radioLifecycleWithALiveTCPClientArmsMaintenanceOnce` |
| M9 | online arm: drop the `+ [.send(.meshtastic(.delegate(.radioOnline(...))))]` term | `radioOnlineSurfacesOnTheMeshtasticHatch` |
| M10 | offline arm: delete `effects.append(.send(.meshtastic(.delegate(.radioOffline(reason: reason)))))` | `radioDropSurfacesOnTheMeshtasticHatch` |

- [ ] **Step 6: Revert and re-run (rule step c)**

Revert M1–M10. Run the three step-4 commands. Expected: all pass.

- [ ] **Step 7: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface add Sources/ReTiCANode/TransportEndpoint.swift Tests/ReTiCANodeTests/TransportEndpointMeshtasticTests.swift`

Write `/tmp/meshtastic-interface/commit-task-8.txt`:

```
feat: TransportEndpoint.meshtastic slot

One shared-router interface per radio, registered with the preset's
profile when the radio comes online and deregistered when it drops or the
endpoint stops; inbound packets tagged with the radio's id; outbound
IFAC-masked centrally then routed to the radio only while it is online,
otherwise .sendFailed(.interfaceUnavailable). Shared maintenance follows
the shared interface count, proven against a TCP client on the same node.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface commit -F /tmp/meshtastic-interface/commit-task-8.txt`
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface log -1 "--format=%(trailers:key=Claude-Session,valueonly)"`

---

### Task 9: Whole-slice probe — two nodes, one in-memory radio channel

Two `LXMFNode`s each run a `TransportEndpoint.meshtastic` slot. Each mock driver's `send` yields the frame into the OTHER node's driver stream as `.fragment(from: senderNodeNum, frame)`, which makes the pair one broadcast medium without self-echo (the live adapter drops self-echo, per Contract 2). Pacing runs on `ImmediateClock` (`\.meshtasticClock`). Transport and LXMF timers sit on a never-advanced `TestClock`. This follows the shape of `Tests/ReTiCANodeTests/LXMFNodeBLETests.swift:20-45`.

**Files:**
- Test: `Tests/ReTiCANodeTests/MeshtasticWholeSliceTests.swift`

**Interfaces:**
- Consumes: everything above; `LXMFNode.State(identity:endpoint: TransportEndpoint.State)` (`Sources/ReTiCANode/LXMFNode.swift:183`); `LXMFNode.Action.registerDelivery`, `.send(destinationHash:title:content:method:)`, `.delegate(.messageReceived(message:signatureValidated:method:))` (`LXMFNode.swift:226-271`); `LXMessage.deliveryHash(identityHash:)`.
- Produces: nothing (probe).

- [ ] **Step 1: Write the probe**

Create `Tests/ReTiCANodeTests/MeshtasticWholeSliceTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let radioA = UUID(uuidString: "0000AAAA-0000-0000-0000-0000000000A1")!
private let radioB = UUID(uuidString: "0000BBBB-0000-0000-0000-0000000000B2")!
private let nodeA: UInt32 = 0xA1A1_A1A1
private let nodeB: UInt32 = 0xB2B2_B2B2
private let hop: Duration = .seconds(5)

private typealias MeshRadioStream = (stream: AsyncStream<MeshtasticDriverEvent>,
                                     continuation: AsyncStream<MeshtasticDriverEvent>.Continuation)

/// An LXMFNode on a Meshtastic radio whose every sent frame is heard by `peer` as node `nodeNum`.
@MainActor
private func makeMeshNode(identity: Identity, radio: UUID, nodeNum: UInt32, own: MeshRadioStream,
                          peer: AsyncStream<MeshtasticDriverEvent>.Continuation,
                          onAir: LockIsolated<[Data]>, ifac: IFAC?)
    -> TestStore<LXMFNode.State, LXMFNode.Action> {
    var profile = InterfaceProfile.meshtastic(modemPreset: nil)
    profile.ifac = ifac
    let endpoint = TransportEndpoint.State.meshtastic(
        MeshtasticEndpoint.State(config: MeshtasticDriverConfig(radio: radio), profile: profile))
    let store = TestStore(initialState: LXMFNode.State(identity: identity, endpoint: endpoint)) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000.5))
        $0.uuid = .incrementing
        $0.meshtasticClock = ImmediateClock()
        $0.meshtasticDriver = MeshtasticDriver(
            start: { _ in own.stream },
            send: { frame in
                onAir.withValue { $0.append(frame) }
                peer.yield(.fragment(from: nodeNum, frame))
                return true
            },
            stop: {})
    }
    store.exhaustivity = .off
    return store
}

private struct ProbeResult {
    var content: Data?
    var aOnAir: [Data]
}

/// A and B come online, both register (each announce crosses the channel and teaches the other a
/// path), then A sends B an opportunistic message.
@MainActor
private func runMeshProbe(ifac: IFAC?) async -> ProbeResult {
    let aIdentity = Identity(), bIdentity = Identity()
    let aRadio = AsyncStream<MeshtasticDriverEvent>.makeStream()
    let bRadio = AsyncStream<MeshtasticDriverEvent>.makeStream()
    let aOnAir = LockIsolated<[Data]>([]), bOnAir = LockIsolated<[Data]>([])
    let a = makeMeshNode(identity: aIdentity, radio: radioA, nodeNum: nodeA, own: aRadio,
                         peer: bRadio.continuation, onAir: aOnAir, ifac: ifac)
    let b = makeMeshNode(identity: bIdentity, radio: radioB, nodeNum: nodeB, own: bRadio,
                         peer: aRadio.continuation, onAir: bOnAir, ifac: ifac)

    await a.send(.endpoint(.start))
    await b.send(.endpoint(.start))
    aRadio.continuation.yield(.connected(myNodeNum: nodeA, modemPreset: 8))
    bRadio.continuation.yield(.connected(myNodeNum: nodeB, modemPreset: 8))
    await a.receive({ if case .endpoint(.transport(.interfaceConnected)) = $0 { return true }; return false }, timeout: hop)
    await b.receive({ if case .endpoint(.transport(.interfaceConnected)) = $0 { return true }; return false }, timeout: hop)

    await a.send(.registerDelivery)
    await b.send(.registerDelivery)
    await a.receive({ if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }, timeout: hop)
    await b.receive({ if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }, timeout: hop)

    let bDelivery = LXMessage.deliveryHash(identityHash: bIdentity.hash)
    await a.send(.send(destinationHash: bDelivery, title: Data("hi".utf8),
                       content: Data("hello over meshtastic".utf8), method: .opportunistic))
    let received = LockIsolated<Data?>(nil)
    await b.receive({ action in
        if case let .delegate(.messageReceived(message, _, _)) = action {
            received.setValue(message.content)
            return true
        }
        return false
    }, timeout: hop)

    await a.send(.endpoint(.stop))
    await b.send(.endpoint(.stop))
    await a.skipReceivedActions(strict: false)
    await b.skipReceivedActions(strict: false)
    return ProbeResult(content: received.value, aOnAir: aOnAir.value)
}

/// What a listener on the channel reassembles from A's frames.
private func reassembledOnAir(_ frames: [Data], from node: UInt32) -> [Data] {
    let codec = LandandairCodec()
    var reassembler = MeshtasticReassembler()
    var packets: [Data] = []
    for frame in frames {
        guard case let .data(index, pos, body)? = codec.parse(frame) else { continue }
        if let packet = reassembler.receive(from: node, index: index, pos: pos, body: body,
                                            now: Date(timeIntervalSince1970: 0)) {
            packets.append(packet)
        }
    }
    return packets
}

@MainActor @Suite struct MeshtasticWholeSliceTests {
    @Test func opportunisticMessageCrossesAnOpenMeshtasticChannel() async {
        let result = await runMeshProbe(ifac: nil)
        #expect(result.content == Data("hello over meshtastic".utf8))
    }

    @Test func opportunisticMessageCrossesAnIFACProtectedMeshtasticChannel() async {
        let result = await runMeshProbe(ifac: MeshtasticEndpoint.ifac(networkName: "mesh-probe", passphrase: "probe-pass"))
        #expect(result.content == Data("hello over meshtastic".utf8))
    }

    @Test func ifacProtectedChannelCarriesOnlyIFACFlaggedPackets() async {
        let result = await runMeshProbe(ifac: MeshtasticEndpoint.ifac(networkName: "mesh-probe", passphrase: "probe-pass"))
        let packets = reassembledOnAir(result.aOnAir, from: nodeA)
        #expect(!packets.isEmpty, "A put nothing reassemblable on the air")
        #expect(packets.allSatisfy { ($0.first ?? 0) & 0x80 == 0x80 }, "an unmasked packet went on the air")
    }
}
```

- [ ] **Step 2: Run the probe (rule step a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface --filter MeshtasticWholeSliceTests`
Expected: 3 pass. This probe exercises code from Tasks 1–8, so it should pass the first time. If it does not, the failure is a seam defect between tasks. Use superpowers:systematic-debugging, and do not weaken the probe.

- [ ] **Step 3: Mutate in one batch (rule step b)**

Apply together in `TransportEndpoint.swift`, run once, and confirm all 3 FAIL:

| Mutation | Breaks |
|---|---|
| transmit mesh branch: `.send(.meshtastic(.interface(.send(unmasked))))` | `opportunisticMessageCrossesAnIFACProtectedMeshtasticChannel` (B's IFAC rejects it), `ifacProtectedChannelCarriesOnlyIFACFlaggedPackets` |
| packetReceived arm: `return .none` | `opportunisticMessageCrossesAnOpenMeshtasticChannel` (and the others) |

For the per-clause check, also run with ONLY the first row applied. Expected: the open-channel test passes and both IFAC tests fail. This shows the third test discriminates masking specifically.

- [ ] **Step 4: Revert and re-run (rule step c)**

Revert, run the step-2 command. Expected: 3 pass.

- [ ] **Step 5: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface add Tests/ReTiCANodeTests/MeshtasticWholeSliceTests.swift`

Write `/tmp/meshtastic-interface/commit-task-9.txt`:

```
test: whole-slice probe of LXMF over an in-memory Meshtastic channel

Two LXMFNodes on TransportEndpoint.meshtastic slots, their mock drivers
cross-wired as one broadcast medium: announces teach each other paths and
an opportunistic message is delivered, on an open channel and on an
IFAC-8 channel whose on-air packets are all IFAC-flagged.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface commit -F /tmp/meshtastic-interface/commit-task-9.txt`
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface log -1 "--format=%(trailers:key=Claude-Session,valueonly)"`

---

### Task 10: Full suite, rebase, fast-forward main

**Files:** none changed (unless the rebase conflicts).

- [ ] **Step 1: Full test suite on the branch**

Run (timeout 600000; if it exceeds that, rerun it with `run_in_background` and wait for completion): `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface`
Expected: every suite passes. A signal-11 or stale-link failure means `swift package clean --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface`, then rerun. Any other failure: STOP and debug. Do not proceed.

- [ ] **Step 2: Confirm a clean tree**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface status --short`
Expected: no output.

- [ ] **Step 3: Rebase onto main**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface rebase main`
Expected: `Successfully rebased` or `Current branch meshtastic-interface is up to date.`

If it conflicts, it will be in `TransportEndpoint.swift`: lane C may touch its linkPlane-wiring region (spec §6). Resolve by keeping both sides. Lane B's edits are the nine listed in Task 8. Then run `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface add Sources/ReTiCANode/TransportEndpoint.swift` and `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface rebase --continue`.

- [ ] **Step 4: Re-run the full suite if the rebase moved the base**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface log --oneline main..HEAD`
Expected: exactly the 9 lane-B commits.

If `main` gained commits since Task 1, repeat Step 1 on the rebased branch. Expected: all pass.

- [ ] **Step 5: Verify every commit's trailers**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/meshtastic-interface log "--format=%h %(trailers:key=Claude-Session,valueonly)" main..HEAD`
Expected: 9 lines, each ending in `https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm`.

- [ ] **Step 6: Fast-forward main**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA merge --ff-only meshtastic-interface`
Expected: `Fast-forward`. If git refuses (main moved again), go back to Step 3.

Run: `git -C /Users/ell/development/ios/pods/ReTiCA log --oneline -10`
Expected: the 9 lane-B commits on top of main.

---

## Self-Review (done while writing; recorded for the executor)

- **Spec coverage:**
  - Contract 2 → Task 1.
  - Contract 3: slot/action/start-stop/interface id/registration lifecycle/delegates → Tasks 7-8; profile table → Tasks 1 + 7.
  - §5.1 → Task 2; §5.2 → Task 3; §5.3 → Tasks 5-6; §5.4 (every listed touch point, plus shared maintenance) → Task 8.
  - §8 lane B:
    - codec sizes 1/199/200/201/400/500/508, REQ parse, malformed → Task 2
    - cross-validation both directions → Task 4, extended into the sender in Task 6
    - reassembler properties → Task 3
    - reducer pacing on TestClock, REQ jumps the queue, queue-full, disconnect clears → Task 6
    - whole-slice probe → Task 9
  - Coordinator amendment (public `MeshtasticCounters`, exactly 7 fields, on `MeshtasticEndpoint.State.counters`) → type in Task 6, property and tests (malformed, queue-full) in Task 7.
  - §6 ownership: honoured; the `InterfaceProfile.swift` exception is explained in Global Constraints.
- **Placeholder scan:** every code step carries complete code. Mutations name exact edits.
- **Type consistency:** these names are used identically across tasks: `MeshtasticFraming.codec`, `State.framing`, `queuedFragmentCount`, `QueuedFragment(frame:isRetransmit:)`, `SentPacket(index:fragments:)`, `.fragmentSent(ok:)`, `.pacingElapsed`, `registeredProfile(modemPreset:)`, `meshtasticInterfaceID(radio:)`, `MeshtasticDriver.liveAdapterMissing`, `meshPattern(_:seed:)`, `meshData(hex:)`, `MeshtasticFixtures.outgoing/.requestAnswers`.
- **Review Focus:** five items, each with a named test in its owning task.
