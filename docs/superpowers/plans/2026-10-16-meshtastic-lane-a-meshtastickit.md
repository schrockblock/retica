# Meshtastic Lane A — MeshtasticKit + Meshtastified Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract Meshtastified's Meshtastic BLE stack into a new SPM package `pods/MeshtasticKit` that exposes exactly Contract 1 (any-port send/receive, `.configured` with the modem preset, retrieve-only connect), then move Meshtastified onto it with its suite green.

**Architecture:** MeshtasticKit has three products. `MeshProto` holds the generated protobufs, moved as-is. `MeshtasticKit` holds `MeshtasticSession`, an actor ported from `MeshSessionActor` with port-agnostic events, an epoch guard on every await, a write slot that serialises ToRadio writes, and a powered-on gate. It also holds `MeshtasticScanner`, `MeshGATT` and the public value types. `MeshtasticMock` holds the CoreBluetoothMock radio, which ACKs any port. Meshtastified keeps `MeshDeviceClient`, `RadioRouter`, `SharedScanner`, MeshCore and MeshModels. Its `MeshSessionActor` becomes a thin adapter: it maps `MeshtasticEvent.connection`/`.frame` back onto `MeshEvent` through the existing `MeshEvent.from(fromRadio:)`, and `sendText` wraps `session.send(MeshtasticOutbound(portnum: TEXT_MESSAGE_APP, wantAck: true, …))`.

**Tech Stack:** Swift 6.3 tools / Swift 6 language mode, SwiftProtobuf, FCB (`FCBComposable.BluetoothCentralClient`), CoreBluetoothMock (Nordic), swift-composable-architecture (test-only in MeshtasticKit: `ImmediateClock`, `TestClock`, `LockIsolated`), Swift Testing.

**Spec:** `/Users/ell/development/ios/pods/ReTiCA/docs/superpowers/specs/2026-10-16-meshtastic-interface-design.md` — this plan implements **Lane A**: Contract 1 (§4), the lane-A rows of §6 and §8.

## Global Constraints

- MeshtasticKit platforms **iOS 17, macOS 13, macCatalyst 17** (spec §4 Contract 1 "Requirements"). MeshtastifiedKit stays `.iOS(.v17), .macOS(.v14)`.
- MeshtasticKit library dependencies: SwiftProtobuf, FCB (`.package(path: "../FCB")`), CoreBluetoothMock (mock target only). TCA is a **test-target-only** dependency. No dependency on ReTiCA, MeshModels, Sharing, IdentifiedCollections.
- Public API = Contract 1 **verbatim, as amended** (re-read spec §4 Contract 1): `MeshtasticOutbound`, `MeshtasticConnectionState`, `MeshtasticSessionError { payloadTooLarge, notConnected }`, `MeshtasticAdapterUnavailable` (with `isTerminal`), `MeshtasticEvent: Equatable` incl. `.frame(FromRadio)` and `.adapterUnavailable(MeshtasticAdapterUnavailable)`, `MeshtasticSession`, `DiscoveredRadio`, `MeshtasticScanner`, all with public inits. The only further additions: the public `MeshGATT` UUIDs (spec §3 places MeshGATT in MeshtasticKit) and the `MockMeshtasticDevice` API in `MeshtasticMock`.
- `MeshtasticSession` connects ONLY via `central.retrievePeripherals` + `central.connect`. It NEVER calls `central.scan`, not even on reconnect. `MeshtasticScanner.scan(central:)` is the only scanning entry point.
- Payload limit: `payload.count > 233` → `MeshtasticSessionError.payloadTooLarge`, before anything is written.
- Reconnect backoff: 1 s, doubling, capped at 30 s, retried until connect or disconnect, on the injected clock (preserved from `MeshSessionActor.swift:361-385`).
- Fixed reason strings: connection `.disconnected(reason:)` uses `nil` (after `disconnect()` / initial), `"radio not found"`, `"unauthorized"`, `"unsupported"`. Adapter problems use the typed `.adapterUnavailable(MeshtasticAdapterUnavailable)` (`.poweredOff` transient; `.unauthorized`/`.unsupported` terminal; `.other(String?)` reserved).
- `MeshtasticEvent` is `Equatable` (spec-amended): tests assert events with `==`.
- want_config handshake timeout: **30 s** on the injected clock. No `config_complete` in time → drop the BLE link → the attempt fails retryable → backoff.
- Tests must NOT give a session an `ImmediateClock` while a handshake can run: the handshake timeout would fire instantly. Use the real `ContinuousClock` (the test harness default) or a `TestClock`. ImmediateClock/SleepRecordingClock are fine only with fake centrals that never reach `.configuring`.
- Do NOT modify FCB, ReTiCA, or ReTiCAMsgr — other lanes own them. If an FCB defect blocks a test, STOP and report it. Do not patch FCB.
- Meshtastified keeps MeshCore (`Sources/MeshDeviceClient/MeshCore/*`, `Mock/MockMeshCoreDevice.swift`), `RadioRouter`, `SharedScanner`, `RadioScanRegistry`, `MeshModels`, Sharing/app-group storage.
- **Shell rule (user):** exactly ONE command per Bash call. No `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, heredocs piped to interpreters, `python -c`/`bash -c`/`node -e`. Anything multi-step goes in a script file under `/tmp/ReTiCA/` (the session cwd's basename; create it with `mkdir -p /tmp/ReTiCA` once), run as one command (`bash /tmp/ReTiCA/x.sh`). Write files (including commit messages) with the Write tool, not `echo >`.
- **Test-verification rule (user), for every new/changed test set, before committing:** (a) run → all pass; (b) apply the task's listed production-code mutations **in one batch** → run once → every new test fails (a test that still passes is broken: fix it, restart at (a)); (c) revert every mutation → run → all pass. Only then commit. If anything surprises you, stop and diagnose. Never paper over it.
- **Commits:** MeshtasticKit commits go straight to its `main`. Meshtastified commits go on branch `meshtastickit` in worktree `/Users/ell/development/ios/apps/Meshtastified-meshtastickit`, fast-forwarded into Meshtastified `main` in the final task. Stage explicit paths only (never `git add -A`/`.`: both repos have untracked `.build/`, `.swiftpm/`, `xcshareddata/`). Commit with `git -C <repo> commit -F /tmp/ReTiCA/commit-msg.txt`. The message file ends with these two lines **at column zero**:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
  ```
  After every commit run `git -C <repo> log -1 --format='%(trailers:key=Claude-Session)'`. It must print the session URL.
- Tests: Swift Testing (`import Testing`, `@Test`, `#expect`), the style of `MeshtastifiedKit/Tests/MeshDeviceClientTests/*`. Every test touching CoreBluetoothMock's process-global simulation is nested in `extension CBMBackedTests` (a `@Suite(.serialized)` parent) and is `@Suite @MainActor`.
- **Live boundary (user):** the session/scanner/mock tests drive the **live FCB client** `BluetoothCentralClient.mocked()` against the CoreBluetoothMock radio. Closure-built fake centrals are allowed ONLY for paths CBM cannot drive deterministically: unauthorized adapter, failing/gated connects, backoff timing, scan-argument capture.
- TCA: this plan changes no reducer. If any AppFeature `TestStore` test must change, use a non-exhaustive (`.off`) store asserting outcomes, and remember that effects stay invisible until drained.
- Every `swift test` command below is exactly as written (absolute `--package-path`). The Meshtastified app build is `xcodebuild -project <worktree>/Meshtastified.xcodeproj -scheme Meshtastified -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build`.

## Review Focus

1. **Two sends issued concurrently** (a ReTiCA fragment plus a Meshtastified text, or a burst). FCB keeps ONE pending-write continuation per characteristic and overwrites it (`FCB/Sources/FCBComposable/BluetoothCentralClient+Live.swift:322-334`), so without serialisation the first send hangs forever. Expected: every send completes with a distinct id. → Task 5 `concurrentSendsAllCompleteWithDistinctIDs`.
2. **Connect issued while Bluetooth is still `.unknown`/`.poweredOff`** (app launch, Bluetooth off). CoreBluetooth drops commands, and `retrievePeripherals` returns `[]` unless the adapter is powered on (CBM `CBMCentralManagerMock.swift:772`). Without a gate that becomes a false terminal "radio not found". Expected: wait, emit `.adapterUnavailable(.poweredOff)`, connect once power is on. → Task 3 `connectWhilePoweredOffWaitsThenConnects`.
3. **Bluetooth power-cycled while connected.** iOS/CBM deliver only a state change and NO `didDisconnect` (CBM `CBMCentralManagerMock.swift:80-104` forgets peripherals and only calls `centralManagerDidUpdateState`), so a watch keyed on `didDisconnect` alone never notices. Expected: `.reconnecting(attempt: 1)`, then `.adapterUnavailable(.poweredOff)`, then `.configured` again after power-on. → Task 6 `powerCycleWhileConnectedReconnectsAndReportsAdapter`.
4. **`disconnect()`/`connect()` racing an attempt whose BLE call resolves later.** FCB continuations ignore task cancellation. Expected: a stale completion never resurrects state (no `.reconnecting` after `disconnect()`). → Task 6 `attemptResolvingAfterDisconnectStaysDisconnected`.
5. **Hostile or malformed radio input:** garbage bytes, a decoded packet with a negative portnum (`PortNum.UNRECOGNIZED(-1)`; `UInt32(-1)` would trap), encrypted packets. Expected: no trap, no `.packet` for the bad frame, and the drain keeps going. → Task 4 `garbageFrameIsSkippedAndTheDrainContinues`, `negativePortnumIsDroppedAndTheDrainContinues`, `encryptedPacketEmitsFrameButNoPacket`.

---

## Source map (read before starting; all line numbers verified 2026-10-16)

- `apps/Meshtastified/MeshtastifiedKit/Sources/MeshDeviceClient/MeshSessionActor.swift`
  - `:116-176` connect + handshake (isDraining/drainGeneration lock).
  - `:182-212` requestConfig + drain-until-config-complete.
  - `:216-272` steady FromNum drain.
  - `:276-287` disconnect.
  - `:294-322` `sendText`, hard-wired to `TEXT_MESSAGE_APP` / `wantAck = true`.
  - `:326-385` disconnect watch (already filters `peripheral.id == id`, `:332`) + backoff.
  - `:90-114` `scanStream` is dead code: nothing calls it, and the client's scan goes through `SharedScanner`.
- `…/Sources/MeshModels/MeshEvent.swift:22-53` FromRadio → MeshEvent. Config frames are dropped (`:35-37`), and so is every port except TEXT/ROUTING (`:50-51`).
- `…/Sources/MeshDeviceClient/Mock/MockMeshtasticDevice.swift`
  - `:240-241` ACKs text only.
  - `:278` `NSLock.withLock` is **macOS 14+**, the only macOS-14-only API in the moved code (generated protos and MeshGATT have none).
- `…/Sources/MeshDeviceClient/MeshDeviceClient+Live.swift`: `:81-144` SharedScanner (stays, uses `MeshGATT.serviceUUID`), `:148-229` RadioRouter (stays).
- `…/Package.swift:7` is `macOS(.v14)`. `:16` is FCB via `../../../pods/FCB`.
- FCB `Sources/FCBComposable/BluetoothCentralClient+Live.swift`
  - `:235-249` connect falls back to `lookupPeripheral`.
  - `:271-275` `retrievePeripherals` re-stores the peripheral object. This matters after a power cycle, when the cached one is dead.
  - `:309-320` a second concurrent read throws `operationCancelled`.
  - `:322-334` one write slot per characteristic.
  - `:466-470` one scan continuation per process.
  - `:528-542` `didDisconnect` fails pending ops.
- CBM `CBMCentralManagerMock.swift:1000-1006`: connecting to an out-of-range peripheral pends forever, with no timeout (same as iOS).
- Consumers:
  - `AppFeature/AppFeature.swift:78-82` subscribes, then calls `try? connect`.
  - `AppFeature/DeviceFeature.swift:135-158`: a failed connect shows "Could not connect. Retrying in the background…" (`:158`).
  - `AppFeature/IntentSendService.swift:62-75` races connect against 10 s, and `:81-87` subscribes before `sendText`.
  - `Meshtastified/MeshtastifiedApp.swift:12-16,105-119`: the simulator bootstrap reaches `MockMeshtasticDevice` through `import MeshDeviceClient`.
  - `Meshtastified.xcodeproj/project.pbxproj:558` (and every config) sets `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`, so a typealias is not enough and the mock module must be imported or `@_exported`.
  - pbxproj links only `AppFeature`, `MeshWidgetCore`, `MeshModels` (`:834-842`), so removing the `MeshProto` product from MeshtastifiedKit is safe.

## File structure

**New repo `/Users/ell/development/ios/pods/MeshtasticKit`**

| Path | Responsibility | Task |
|---|---|---|
| `Package.swift`, `.gitignore`, `scripts/generate-protos.sh` | package manifest; proto regeneration (OUT → this repo) | 1, 2 |
| `Sources/MeshProto/Generated/*.pb.swift` | generated protobufs, copied verbatim | 1 |
| `Sources/MeshtasticKit/MeshGATT.swift` | GATT UUIDs, copied verbatim | 1 |
| `Sources/MeshtasticKit/MeshtasticTypes.swift` | Contract 1 value types + `MeshtasticSessionError` | 1 |
| `Sources/MeshtasticMock/MockMeshtasticDevice.swift` | CBM radio: canned DB + LoRa config, ACK any port, inject/record | 2 |
| `Sources/MeshtasticKit/EventHub.swift` | lock-backed synchronous fan-out + connection replay | 3 |
| `Sources/MeshtasticKit/MeshtasticSession.swift` | the session actor | 3–6 |
| `Sources/MeshtasticKit/MeshtasticScanner.swift` | the one scanning entry point | 7 |
| `Tests/MeshtasticKitTests/PublicTypesTests.swift` | value-type defaults, GATT UUIDs, port 76 | 1 |
| `Tests/MeshtasticKitTests/Support/CBMSupport.swift` | `CBMBackedTests`, `MockRadio`, raw GATT helpers | 2 |
| `Tests/MeshtasticKitTests/MockRadioTests.swift` | mock behaviour over the raw live FCB client | 2 |
| `Tests/MeshtasticKitTests/Support/SessionSupport.swift` | event accessors, `collect`, `waitUntil`, recording/fake centrals, clocks, gate | 3, 6 |
| `Tests/MeshtasticKitTests/SessionConnectTests.swift` | connect/handshake/configured/terminal/disconnect | 3 |
| `Tests/MeshtasticKitTests/SessionReceiveTests.swift` | `.frame`/`.packet`/`.routing`, hostile input | 4 |
| `Tests/MeshtasticKitTests/SessionSendTests.swift` | send encoding, limits, ACKs, concurrency | 5 |
| `Tests/MeshtasticKitTests/SessionReconnectTests.swift` | backoff, filtering, epoch, power cycle | 6 |
| `Tests/MeshtasticKitTests/ScannerTests.swift` | scanner gate, filter, cancellation | 7 |

**Meshtastified worktree `/Users/ell/development/ios/apps/Meshtastified-meshtastickit` (branch `meshtastickit`)**

| Path | Change | Task |
|---|---|---|
| `MeshtastifiedKit/Package.swift` | depend on `../../../pods/MeshtasticKit`; drop own MeshProto target/product and swift-protobuf | 8 |
| `MeshtastifiedKit/Sources/MeshProto/` | delete | 8 |
| `MeshtastifiedKit/Sources/MeshDeviceClient/MeshGATT.swift`, `Mock/MockMeshtasticDevice.swift` | delete | 8 |
| `MeshtastifiedKit/Sources/MeshDeviceClient/Exports.swift` | `@_exported import MeshtasticMock` | 8 |
| `MeshtastifiedKit/Sources/MeshDeviceClient/MeshDeviceClient+Live.swift`, `Tests/MeshDeviceClientTests/RouterDispatchTests.swift` | `import MeshtasticKit` | 8 |
| `scripts/generate-protos.sh` | delete (moved to MeshtasticKit) | 8 |
| `MeshtastifiedKit/Sources/MeshDeviceClient/MeshEventMapper.swift`, `MeshEventRelay.swift` | new: MeshtasticEvent → MeshEvent; fan-out | 9 |
| `MeshtastifiedKit/Tests/MeshDeviceClientTests/MeshEventMapperTests.swift`, `MeshEventRelayTests.swift` | new | 9 |
| `MeshtastifiedKit/Sources/MeshDeviceClient/MeshSessionActor.swift` | rewrite as adapter over `MeshtasticSession` | 10 |
| `MeshtastifiedKit/Tests/MeshDeviceClientTests/MeshtasticAdapterTests.swift` | new | 10 |

---

### Task 1: MeshtasticKit repo, MeshProto, MeshGATT, public value types

**Files:**
- Create: `/Users/ell/development/ios/pods/MeshtasticKit/Package.swift`
- Create: `/Users/ell/development/ios/pods/MeshtasticKit/.gitignore`
- Create: `/Users/ell/development/ios/pods/MeshtasticKit/scripts/generate-protos.sh`
- Create (copy): `/Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshProto/Generated/*.pb.swift`
- Create (copy): `/Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshtasticKit/MeshGATT.swift`
- Create: `/Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshtasticKit/MeshtasticTypes.swift`
- Test: `/Users/ell/development/ios/pods/MeshtasticKit/Tests/MeshtasticKitTests/PublicTypesTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (exact public API, used by every later task and by lanes D/E):
  ```swift
  public struct MeshtasticOutbound: Equatable, Sendable {
      public var portnum: UInt32; public var payload: Data
      public var to: UInt32 = 0xFFFF_FFFF; public var channel: UInt32 = 0
      public var wantAck: Bool = false; public var hopLimit: UInt32? = nil
      public init(portnum: UInt32, payload: Data, to: UInt32 = 0xFFFF_FFFF, channel: UInt32 = 0,
                  wantAck: Bool = false, hopLimit: UInt32? = nil)
  }
  public enum MeshtasticConnectionState: Equatable, Sendable {
      case disconnected(reason: String?), connecting, configuring, connected, reconnecting(attempt: Int)
  }
  public enum MeshtasticAdapterUnavailable: Equatable, Sendable {
      case poweredOff, unauthorized, unsupported, other(String?)
      public var isTerminal: Bool   // unauthorized, unsupported
  }
  public enum MeshtasticEvent: Equatable, Sendable {
      case connection(MeshtasticConnectionState)
      case configured(myNodeNum: UInt32, modemPreset: Int?)
      case packet(from: UInt32, to: UInt32, channel: UInt32, portnum: UInt32, payload: Data, id: UInt32)
      case routing(packetID: UInt32, ok: Bool)
      case frame(FromRadio)
      case adapterUnavailable(MeshtasticAdapterUnavailable)
  }
  public struct DiscoveredRadio: Equatable, Sendable, Identifiable { public var id: UUID; public var name: String?; public var rssi: Int
      public init(id: UUID, name: String?, rssi: Int) }
  public enum MeshtasticSessionError: Error, Equatable, Sendable { case payloadTooLarge, notConnected }
  public enum MeshGATT { public static let serviceUUID, toRadioUUID, fromRadioUUID, fromNumUUID: CBUUID }
  ```
  Modules: `MeshProto` (all generated types: `FromRadio`, `ToRadio`, `MeshPacket`, `DataMessage`, `PortNum`, `Routing`, `Config`, …).

- [ ] **Step 1: Create the repo directory and git repo**

Run: `mkdir -p /Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshProto`
Run: `git init -b main /Users/ell/development/ios/pods/MeshtasticKit`
Expected: `Initialized empty Git repository in /Users/ell/development/ios/pods/MeshtasticKit/.git/`

- [ ] **Step 2: Copy the generated protobufs and MeshGATT verbatim**

Run: `cp -R /Users/ell/development/ios/apps/Meshtastified/MeshtastifiedKit/Sources/MeshProto/Generated /Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshProto/Generated`
Run: `mkdir -p /Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshtasticKit`
Run: `cp /Users/ell/development/ios/apps/Meshtastified/MeshtastifiedKit/Sources/MeshDeviceClient/MeshGATT.swift /Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshtasticKit/MeshGATT.swift`
Run: `ls /Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshProto/Generated`
Expected: `atak.pb.swift channel.pb.swift config.pb.swift device_ui.pb.swift mesh.pb.swift module_config.pb.swift portnums.pb.swift telemetry.pb.swift xmodem.pb.swift`

- [ ] **Step 3: Write `Package.swift`**

```swift
// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "MeshtasticKit",
    platforms: [.iOS(.v17), .macOS(.v13), .macCatalyst(.v17)],
    products: [
        .library(name: "MeshProto", targets: ["MeshProto"]),
        .library(name: "MeshtasticKit", targets: ["MeshtasticKit"]),
    ],
    dependencies: [
        .package(path: "../FCB"),
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.28.0"),
    ],
    targets: [
        .target(
            name: "MeshProto",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .target(
            name: "MeshtasticKit",
            dependencies: [
                "MeshProto",
                .product(name: "FCBComposable", package: "FCB"),
            ]
        ),
        .testTarget(
            name: "MeshtasticKitTests",
            dependencies: ["MeshProto", "MeshtasticKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

- [ ] **Step 4: Write `.gitignore`**

```
.build/
.swiftpm/
Package.resolved
.DS_Store
```

- [ ] **Step 5: Write `scripts/generate-protos.sh`** (moved from `apps/Meshtastified/scripts/generate-protos.sh`, OUT re-pointed)

```bash
#!/bin/bash
set -euo pipefail

# Regenerates MeshProto/Generated from the official meshtastic/protobufs at a
# pinned commit. Requires protoc + protoc-gen-swift on PATH (brew installs them
# under /opt/homebrew/bin). Run from anywhere; paths are absolute.

PROTO_COMMIT="da2fc413931c81c1d2bc9b6a838d739e2bf35bc1"
REPO="https://github.com/meshtastic/protobufs.git"
OUT="/Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshProto/Generated"
WORK="$(mktemp -d)"

export PATH="/opt/homebrew/bin:$PATH"

git clone "$REPO" "$WORK/protobufs"
git -C "$WORK/protobufs" checkout "$PROTO_COMMIT"

rm -rf "$OUT"
mkdir -p "$OUT"

# Explicit file list = import closure of mesh.proto (verified transitively).
FILES="meshtastic/mesh.proto meshtastic/channel.proto meshtastic/config.proto meshtastic/device_ui.proto meshtastic/module_config.proto meshtastic/portnums.proto meshtastic/telemetry.proto meshtastic/xmodem.proto meshtastic/atak.proto"

protoc \
  --proto_path="$WORK/protobufs" \
  --swift_out="$OUT" \
  --swift_opt=Visibility=Public \
  --swift_opt=FileNaming=DropPath \
  $FILES

rm -rf "$WORK"
echo "Generated protos into $OUT"
```
(Do not run it. The copied files are the pinned output.)

- [ ] **Step 6: Write the failing test** `Tests/MeshtasticKitTests/PublicTypesTests.swift`

```swift
import Foundation
import MeshProto
import MeshtasticKit
import Testing

struct PublicTypesTests {
    @Test func outboundDefaultsToBroadcastOnChannelZeroWithoutAckAndFirmwareHopLimit() {
        let outbound = MeshtasticOutbound(portnum: 76, payload: Data([1]))
        #expect(outbound.to == 0xFFFF_FFFF)
        #expect(outbound.channel == 0)
        #expect(outbound.wantAck == false)
        #expect(outbound.hopLimit == nil)
    }

    @Test func outboundInitStoresEveryField() {
        let outbound = MeshtasticOutbound(portnum: 76, payload: Data([9, 8]), to: 0x1234, channel: 2,
                                          wantAck: true, hopLimit: 3)
        #expect(outbound.portnum == 76)
        #expect(outbound.payload == Data([9, 8]))
        #expect(outbound.to == 0x1234)
        #expect(outbound.channel == 2)
        #expect(outbound.wantAck == true)
        #expect(outbound.hopLimit == 3)
    }

    @Test func discoveredRadioInitStoresEveryField() {
        let id = UUID()
        let radio = DiscoveredRadio(id: id, name: "Meshtastic_1234", rssi: -61)
        #expect(radio.id == id)
        #expect(radio.name == "Meshtastic_1234")
        #expect(radio.rssi == -61)
    }

    @Test func meshGATTUUIDsMatchMeshtasticFirmware() {
        #expect(MeshGATT.serviceUUID.uuidString == "6BA1B218-15A8-461F-9FA8-5DCAE273EAFD")
        #expect(MeshGATT.toRadioUUID.uuidString == "F75C76D2-129E-4DAD-A1DD-7866124401E7")
        #expect(MeshGATT.fromRadioUUID.uuidString == "2C55E69E-4993-11ED-B878-0242AC120002")
        #expect(MeshGATT.fromNumUUID.uuidString == "ED9DA18C-A800-4F66-A670-AA7547E34453")
    }

    @Test func wirePortSeventySixDecodesAsReticulumTunnel() {
        #expect(PortNum(rawValue: 76) == .reticulumTunnelApp)
    }

    @Test func onlyUnauthorizedAndUnsupportedAreTerminal() {
        #expect(MeshtasticAdapterUnavailable.unauthorized.isTerminal)
        #expect(MeshtasticAdapterUnavailable.unsupported.isTerminal)
        #expect(!MeshtasticAdapterUnavailable.poweredOff.isTerminal)
        #expect(!MeshtasticAdapterUnavailable.other("x").isTerminal)
    }
}
```

- [ ] **Step 7: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter PublicTypesTests`
Expected: compile FAILURE: `cannot find 'MeshtasticOutbound' in scope` (and `DiscoveredRadio`, `MeshtasticAdapterUnavailable`).

- [ ] **Step 8: Write `Sources/MeshtasticKit/MeshtasticTypes.swift`**

```swift
import Foundation
import MeshProto

/// One outbound Meshtastic data packet. `payload` is the DataMessage payload and
/// must be at most 233 bytes (Meshtastic's DATA_PAYLOAD_LEN); `MeshtasticSession.send`
/// throws `MeshtasticSessionError.payloadTooLarge` otherwise.
public struct MeshtasticOutbound: Equatable, Sendable {
    public var portnum: UInt32
    public var payload: Data            // ≤ 233 bytes; send throws .payloadTooLarge otherwise
    public var to: UInt32 = 0xFFFF_FFFF // broadcast
    public var channel: UInt32 = 0
    public var wantAck: Bool = false
    public var hopLimit: UInt32? = nil  // nil: firmware default

    public init(portnum: UInt32, payload: Data, to: UInt32 = 0xFFFF_FFFF, channel: UInt32 = 0,
                wantAck: Bool = false, hopLimit: UInt32? = nil) {
        self.portnum = portnum
        self.payload = payload
        self.to = to
        self.channel = channel
        self.wantAck = wantAck
        self.hopLimit = hopLimit
    }
}

/// `disconnected(reason:)` carries nil before any connect and after `disconnect()`;
/// otherwise one of the terminal causes "radio not found", "unauthorized", "unsupported".
/// `reconnecting(attempt:)` counts the attempt about to be made, starting at 1.
public enum MeshtasticConnectionState: Equatable, Sendable {
    case disconnected(reason: String?), connecting, configuring, connected, reconnecting(attempt: Int)
}

/// Why the Bluetooth adapter cannot be used. `isTerminal` separates causes retrying
/// cannot fix (`unauthorized`, `unsupported`) from transient ones.
public enum MeshtasticAdapterUnavailable: Equatable, Sendable {
    case poweredOff, unauthorized, unsupported, other(String?)

    public var isTerminal: Bool {
        switch self {
        case .unauthorized, .unsupported: return true
        case .poweredOff, .other: return false
        }
    }
}

/// Every MeshPacket also arrives as `.frame`: a consumer maps EITHER `.frame` OR
/// `.packet`/`.routing`, never both (spec §4 Contract 1).
public enum MeshtasticEvent: Equatable, Sendable {
    case connection(MeshtasticConnectionState)
    /// Emitted once per completed want_config handshake (so again after every reconnect).
    case configured(myNodeNum: UInt32, modemPreset: Int?)   // raw Config.LoRaConfig.ModemPreset value
    /// Every decoded MeshPacket, any port. Encrypted/undecodable packets are not emitted.
    case packet(from: UInt32, to: UInt32, channel: UInt32, portnum: UInt32, payload: Data, id: UInt32)
    case routing(packetID: UInt32, ok: Bool)
    /// Every decoded FromRadio frame, unfiltered — for Meshtastified's node DB / channels / text.
    case frame(FromRadio)
    /// `.poweredOff` while waiting for power; `.unauthorized` / `.unsupported` are terminal
    /// (the session then ends `.disconnected(reason: "unauthorized" / "unsupported")`).
    case adapterUnavailable(MeshtasticAdapterUnavailable)
}

public struct DiscoveredRadio: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String?
    public var rssi: Int

    public init(id: UUID, name: String?, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

public enum MeshtasticSessionError: Error, Equatable, Sendable {
    /// `MeshtasticOutbound.payload` exceeded 233 bytes; nothing was written.
    case payloadTooLarge
    /// `send` was called while the session was not `.connected`.
    case notConnected
}
```

- [ ] **Step 9: Run the tests and verify they pass (verification step a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter PublicTypesTests`
Expected: `Test run with 6 tests passed`. The first build resolves packages and builds the generated protos, which takes a few minutes. If you see any "is only available in macOS 14" error, record which API it is and replace it with a macOS-13 equivalent (none is expected in these files).

- [ ] **Step 10: Mutate in one batch (verification step b)**

In `MeshtasticTypes.swift`, inside `MeshtasticOutbound`:
- change `public init(... to: UInt32 = 0xFFFF_FFFF, channel: UInt32 = 0, wantAck: Bool = false, hopLimit: UInt32? = nil)` defaults to `to: UInt32 = 0, channel: UInt32 = 1, wantAck: Bool = true, hopLimit: UInt32? = 3`
- change `self.channel = channel` to `self.channel = 0`

Then make these edits in the other files:
- `DiscoveredRadio.init`: change `self.rssi = rssi` to `self.rssi = 0`.
- `MeshtasticAdapterUnavailable.isTerminal`: change `case .unauthorized, .unsupported: return true` to `case .unauthorized: return true` and `case .poweredOff, .other: return false` to `case .poweredOff, .other, .unsupported: return false`.
- `MeshGATT.swift`: change the last hex digit of `serviceUUID` (`…eafd` → `…eafe`).
- `Sources/MeshProto/Generated/portnums.pb.swift`, in `init?(rawValue:)`: change `case 76: self = .reticulumTunnelApp` to `case 76: self = .UNRECOGNIZED(76)`.

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter PublicTypesTests`
Expected: all 6 tests FAIL.

- [ ] **Step 11: Revert every mutation and re-run (verification step c)**

Undo each edit from Step 10 exactly. To restore the vendored file, run `cp /Users/ell/development/ios/apps/Meshtastified/MeshtastifiedKit/Sources/MeshProto/Generated/portnums.pb.swift /Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshProto/Generated/portnums.pb.swift`.
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter PublicTypesTests`
Expected: `Test run with 6 tests passed`.

- [ ] **Step 12: Build for iOS and Mac Catalyst**

Write `/tmp/ReTiCA/xcbuild-meshtastickit.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd /Users/ell/development/ios/pods/MeshtasticKit
xcodebuild -scheme MeshtasticKit-Package -destination "$1" build
```
Run: `bash /tmp/ReTiCA/xcbuild-meshtastickit.sh "generic/platform=iOS"`
Expected: `** BUILD SUCCEEDED **`
Run: `bash /tmp/ReTiCA/xcbuild-meshtastickit.sh "generic/platform=macOS,variant=Mac Catalyst"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 13: Commit**

Write `/tmp/ReTiCA/commit-msg.txt`:
```
feat: MeshtasticKit package with MeshProto, MeshGATT and Contract 1 value types

Generated protobufs and GATT UUIDs moved verbatim from MeshtastifiedKit;
platforms iOS 17 / macOS 13 / macCatalyst 17.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit add Package.swift .gitignore scripts Sources Tests`
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit commit -F /tmp/ReTiCA/commit-msg.txt`
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit log -1 --format='%(trailers:key=Claude-Session)'`
Expected: `Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm`

---

### Task 2: MeshtasticMock — CBM radio that ACKs any port, serves a LoRa config, records writes

**Files:**
- Modify: `/Users/ell/development/ios/pods/MeshtasticKit/Package.swift`
- Create: `/Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshtasticMock/MockMeshtasticDevice.swift` (port of `apps/Meshtastified/MeshtastifiedKit/Sources/MeshDeviceClient/Mock/MockMeshtasticDevice.swift`)
- Create: `/Users/ell/development/ios/pods/MeshtasticKit/Tests/MeshtasticKitTests/Support/CBMSupport.swift`
- Test: `/Users/ell/development/ios/pods/MeshtasticKit/Tests/MeshtasticKitTests/MockRadioTests.swift`

**Interfaces:**
- Consumes: `MeshGATT` (Task 1), `MeshProto`.
- Produces (public, used by Tasks 3–7, Meshtastified Tasks 8–10, and lane E):
  ```swift
  public final class MockMeshtasticDevice: @unchecked Sendable {
      public static let selfNodeNum: UInt32            // 0xA0A0
      public static let nodeNums: [UInt32]             // 0xB001…0xB006
      public enum AckBehavior: Equatable, Sendable { case ack, nak(Routing.Error), silent }
      public init(now: @escaping () -> Date = Date.init, modemPreset: Config.LoRaConfig.ModemPreset? = .longFast)
      public var modemPreset: Config.LoRaConfig.ModemPreset? { get set }   // served on the NEXT want_config
      public var ackBehavior: AckBehavior { get set }
      public var receivedPackets: [MeshPacket] { get }                    // every decoded ToRadio packet, in order
      public func makeSpec(identifier: UUID) -> CBMPeripheralSpec
      public func injectIncomingText(_ text: String, from nodeNum: UInt32, to: UInt32 = 0xFFFF_FFFF)
      public func injectIncomingPacket(portnum: PortNum, payload: Data, from nodeNum: UInt32, to: UInt32 = 0xFFFF_FFFF,
                                       channel: UInt32 = 0, id: UInt32 = UInt32.random(in: 1...UInt32.max))
      public func injectFrame(_ frame: FromRadio)                         // enqueue + FromNum notify
      public func injectRawFrame(_ bytes: Data, notify: Bool = true)      // arbitrary bytes on FromRadio
      public func startPeriodicTraffic(interval: Duration = .seconds(25)); public func stopPeriodicTraffic()
  }
  ```
  Test support (internal to the test target): `CBMBackedTests`, `MockRadio`, `makeMockRadio(...)`, `waitUntilPoweredOn(_:)`, `rawConnect`, `rawWrite`, `rawReadAll`.

- [ ] **Step 1: Replace `Package.swift`** with the full manifest (adds the mock target/product, CBM, and test-only TCA)

```swift
// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "MeshtasticKit",
    platforms: [.iOS(.v17), .macOS(.v13), .macCatalyst(.v17)],
    products: [
        .library(name: "MeshProto", targets: ["MeshProto"]),
        .library(name: "MeshtasticKit", targets: ["MeshtasticKit"]),
        .library(name: "MeshtasticMock", targets: ["MeshtasticMock"]),
    ],
    dependencies: [
        .package(path: "../FCB"),
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.28.0"),
        .package(url: "https://github.com/NordicSemiconductor/IOS-CoreBluetooth-Mock.git", from: "1.0.0"),
        // Test-only (ImmediateClock, TestClock, LockIsolated). Already in the graph via FCB.
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "MeshProto",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .target(
            name: "MeshtasticKit",
            dependencies: [
                "MeshProto",
                .product(name: "FCBComposable", package: "FCB"),
            ]
        ),
        .target(
            name: "MeshtasticMock",
            dependencies: [
                "MeshProto",
                "MeshtasticKit",
                .product(name: "CoreBluetoothMock", package: "IOS-CoreBluetooth-Mock"),
            ]
        ),
        .testTarget(
            name: "MeshtasticKitTests",
            dependencies: [
                "MeshProto",
                "MeshtasticKit",
                "MeshtasticMock",
                .product(name: "FCBComposable", package: "FCB"),
                .product(name: "CoreBluetoothMock", package: "IOS-CoreBluetooth-Mock"),
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

- [ ] **Step 2: Write the test support** `Tests/MeshtasticKitTests/Support/CBMSupport.swift`

```swift
import ComposableArchitecture
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import FCBComposable
import Foundation
import MeshProto
import MeshtasticKit
import MeshtasticMock
import Testing

/// Parent suite for ALL tests touching CoreBluetoothMock's process-global
/// simulation. `.serialized` is inherited by nested suites, so no two
/// CBM-backed tests run concurrently. Nest via `extension CBMBackedTests`.
@Suite(.serialized) struct CBMBackedTests {}

/// One simulated Meshtastic radio plus the LIVE FCB client (`mocked()`), which
/// drives it through CoreBluetoothMock — the real FCB actor, not a hand mock.
struct MockRadio {
    let id: UUID
    let device: MockMeshtasticDevice
    let spec: CBMPeripheralSpec
    let central: BluetoothCentralClient
}

/// Resets the CBM simulation and stands up one mock radio (plus `extra` specs).
/// With `initialState: .poweredOn` it waits until the central reports power-on.
@MainActor
func makeMockRadio(
    id: UUID = UUID(),
    modemPreset: Config.LoRaConfig.ModemPreset? = .shortFast,
    initialState: CBMManagerState = .poweredOn,
    extra: [CBMPeripheralSpec] = []
) async -> MockRadio {
    CBMCentralManagerMock.tearDownSimulation()
    CBMCentralManagerMock.simulateInitialState(initialState)
    let device = MockMeshtasticDevice(now: { Date(timeIntervalSince1970: 2_000_000_000) }, modemPreset: modemPreset)
    let spec = device.makeSpec(identifier: id)
    CBMCentralManagerMock.simulatePeripherals([spec] + extra)
    let central = BluetoothCentralClient.mocked()
    if initialState == .poweredOn { await waitUntilPoweredOn(central) }
    return MockRadio(id: id, device: device, spec: spec, central: central)
}

/// Polls FCB's replaying state stream until the mock manager reports power-on.
func waitUntilPoweredOn(_ central: BluetoothCentralClient) async {
    for _ in 0..<200 {
        var iterator = central.state().makeAsyncIterator()
        if await iterator.next() == .poweredOn { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Connects + discovers by hand (no MeshtasticSession) so the mock is tested alone.
func rawConnect(_ radio: MockRadio) async throws {
    _ = await radio.central.retrievePeripherals([radio.id])
    _ = try await radio.central.connect(radio.id, ConnectOptions?.none)
    _ = try await radio.central.discoverServices(radio.id, [MeshGATT.serviceUUID])
    _ = try await radio.central.discoverCharacteristics(
        radio.id, MeshGATT.serviceUUID,
        [MeshGATT.toRadioUUID, MeshGATT.fromRadioUUID, MeshGATT.fromNumUUID]
    )
}

func rawWrite(_ toRadio: ToRadio, _ radio: MockRadio) async throws {
    try await radio.central.writeValue(try toRadio.serializedData(), radio.id, MeshGATT.toRadioUUID, .withResponse)
}

/// Reads FromRadio until the radio's queue is drained (empty read). Bounded.
func rawReadAll(_ radio: MockRadio) async throws -> [FromRadio] {
    var frames: [FromRadio] = []
    for _ in 0..<200 {
        let data = try await radio.central.readValue(radio.id, MeshGATT.fromRadioUUID)
        if data.isEmpty { return frames }
        frames.append(try FromRadio(serializedBytes: data))
    }
    Issue.record("FromRadio queue did not drain within 200 reads")
    return frames
}
```

- [ ] **Step 3: Write the failing tests** `Tests/MeshtasticKitTests/MockRadioTests.swift`

```swift
import ComposableArchitecture
@preconcurrency import CoreBluetoothMock
import FCBComposable
import Foundation
import MeshProto
import MeshtasticKit
import MeshtasticMock
import Testing

private struct RoutingReply: Equatable {
    var requestID: UInt32
    var errorReason: Routing.Error
}

private func routingReply(_ frame: FromRadio) -> RoutingReply? {
    guard case .packet(let packet)? = frame.payloadVariant,
          case .decoded(let data)? = packet.payloadVariant,
          data.portnum == .routingApp,
          let routing = try? Routing(serializedBytes: data.payload) else { return nil }
    return RoutingReply(requestID: data.requestID, errorReason: routing.errorReason)
}

private func packetToRadio(portnum: PortNum, id: UInt32, payload: Data = Data([0xAB])) -> ToRadio {
    var data = DataMessage()
    data.portnum = portnum
    data.payload = payload
    var packet = MeshPacket()
    packet.to = 0xFFFF_FFFF
    packet.id = id
    packet.decoded = data
    var toRadio = ToRadio()
    toRadio.packet = packet
    return toRadio
}

private func wantConfig(_ nonce: UInt32) -> ToRadio {
    var toRadio = ToRadio()
    toRadio.wantConfigID = nonce
    return toRadio
}

private func loraPresets(_ frames: [FromRadio]) -> [Config.LoRaConfig.ModemPreset] {
    frames.compactMap { frame in
        guard case .config(let config)? = frame.payloadVariant,
              case .lora(let lora)? = config.payloadVariant else { return nil }
        return lora.modemPreset
    }
}

extension CBMBackedTests {
    @Suite @MainActor
    struct MockRadioTests {
        @Test func handshakeServesLoRaConfigWithTheConfiguredPreset() async throws {
            let radio = await makeMockRadio(modemPreset: .shortFast)
            try await rawConnect(radio)
            try await rawWrite(wantConfig(42), radio)
            let frames = try await rawReadAll(radio)
            #expect(loraPresets(frames) == [.shortFast])
            guard case .configCompleteID(let nonce)? = frames.last?.payloadVariant else {
                Issue.record("last handshake frame must be config_complete_id")
                return
            }
            #expect(nonce == 42)
        }

        @Test func handshakeOmitsLoRaConfigWhenPresetIsNil() async throws {
            let radio = await makeMockRadio(modemPreset: nil)
            try await rawConnect(radio)
            try await rawWrite(wantConfig(7), radio)
            let frames = try await rawReadAll(radio)
            #expect(loraPresets(frames).isEmpty)
            #expect(!frames.isEmpty)
        }

        @Test func presetChangeIsServedOnTheNextHandshake() async throws {
            let radio = await makeMockRadio(modemPreset: .shortFast)
            try await rawConnect(radio)
            radio.device.modemPreset = .longModerate
            try await rawWrite(wantConfig(8), radio)
            #expect(loraPresets(try await rawReadAll(radio)) == [.longModerate])
        }

        @Test func packetOnAnyPortIsRoutingAcked() async throws {
            let radio = await makeMockRadio()
            try await rawConnect(radio)
            try await rawWrite(packetToRadio(portnum: .reticulumTunnelApp, id: 0x55), radio)
            let replies = try await rawReadAll(radio).compactMap(routingReply)
            #expect(replies == [RoutingReply(requestID: 0x55, errorReason: .none)])
        }

        @Test func nakBehaviorRepliesWithItsErrorReason() async throws {
            let radio = await makeMockRadio()
            radio.device.ackBehavior = .nak(.noRoute)
            try await rawConnect(radio)
            try await rawWrite(packetToRadio(portnum: .reticulumTunnelApp, id: 0x56), radio)
            let replies = try await rawReadAll(radio).compactMap(routingReply)
            #expect(replies == [RoutingReply(requestID: 0x56, errorReason: .noRoute)])
        }

        @Test func silentBehaviorSendsNoRoutingReply() async throws {
            let radio = await makeMockRadio()
            radio.device.ackBehavior = .silent
            try await rawConnect(radio)
            try await rawWrite(packetToRadio(portnum: .reticulumTunnelApp, id: 0x57), radio)
            #expect(try await rawReadAll(radio).compactMap(routingReply).isEmpty)
        }

        @Test func everyWrittenPacketIsRecordedInOrder() async throws {
            let radio = await makeMockRadio()
            try await rawConnect(radio)
            try await rawWrite(packetToRadio(portnum: .reticulumTunnelApp, id: 1, payload: Data([1])), radio)
            try await rawWrite(packetToRadio(portnum: .textMessageApp, id: 2, payload: Data([2])), radio)
            let recorded = radio.device.receivedPackets
            #expect(recorded.map(\.id) == [1, 2])
            #expect(recorded.map(\.decoded.portnum) == [.reticulumTunnelApp, .textMessageApp])
            #expect(recorded.map(\.decoded.payload) == [Data([1]), Data([2])])
        }

        @Test func injectedPacketIsReadableWithItsFields() async throws {
            let radio = await makeMockRadio()
            try await rawConnect(radio)
            radio.device.injectIncomingPacket(portnum: .reticulumTunnelApp, payload: Data([1, 2, 3]),
                                              from: 0xB001, to: 0xFFFF_FFFF, channel: 1, id: 9)
            let packets = try await rawReadAll(radio).compactMap { frame -> MeshPacket? in
                if case .packet(let packet)? = frame.payloadVariant { return packet }
                return nil
            }
            #expect(packets.count == 1)
            #expect(packets.first?.from == 0xB001)
            #expect(packets.first?.to == 0xFFFF_FFFF)
            #expect(packets.first?.channel == 1)
            #expect(packets.first?.id == 9)
            #expect(packets.first?.decoded.portnum == .reticulumTunnelApp)
            #expect(packets.first?.decoded.payload == Data([1, 2, 3]))
        }
    }
}
```

- [ ] **Step 4: Run to verify failure**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter MockRadioTests`
Expected: build FAILURE. Either SPM reports that target `MeshtasticMock` has no sources, or the compiler reports `no such module 'MeshtasticMock'`.

- [ ] **Step 5: Write `Sources/MeshtasticMock/MockMeshtasticDevice.swift`**

```swift
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import Foundation
import MeshProto
import MeshtasticKit

/// A scripted Meshtastic radio implemented as a CoreBluetoothMock peripheral.
/// Serves a canned node DB (plus a LoRa config carrying `modemPreset`) on
/// want_config, routing-replies to every packet written to it on ANY port per
/// `ackBehavior`, and records those packets — real protobufs over the
/// FromRadio (read) / FromNum (notify) / ToRadio (write) contract.
/// Usable in integration tests and in the iOS Simulator.
public final class MockMeshtasticDevice: @unchecked Sendable {
    public static let selfNodeNum: UInt32 = 0xA0A0

    /// Canned node numbers, in emission order.
    public static let nodeNums: [UInt32] = [0xB001, 0xB002, 0xB003, 0xB004, 0xB005, 0xB006]
    /// Seconds-ago offsets for each node's last_heard (first three < 2h).
    static let lastHeardOffsets: [TimeInterval] = [60, 600, 3600, 7201, 86_400, 172_800]
    static let batteryLevels: [UInt32] = [95, 80, 60, 40, 20, 5]

    /// How the radio answers a written packet.
    public enum AckBehavior: Equatable, Sendable {
        /// Routing reply with error_reason NONE (the default).
        case ack
        /// Routing reply carrying this error reason.
        case nak(Routing.Error)
        /// No routing reply at all.
        case silent
    }

    private let delegate: Delegate

    public init(now: @escaping () -> Date = Date.init,
                modemPreset: Config.LoRaConfig.ModemPreset? = .longFast) {
        self.delegate = Delegate(now: now, modemPreset: modemPreset)
    }

    /// The preset served in the LoRa config frame of the NEXT want_config
    /// handshake; nil serves no LoRa config frame at all.
    public var modemPreset: Config.LoRaConfig.ModemPreset? {
        get { delegate.withState { $0.modemPreset } }
        set { delegate.withState { $0.modemPreset = newValue } }
    }

    public var ackBehavior: AckBehavior {
        get { delegate.withState { $0.ackBehavior } }
        set { delegate.withState { $0.ackBehavior = newValue } }
    }

    /// Every decoded MeshPacket written to ToRadio, in arrival order.
    public var receivedPackets: [MeshPacket] { delegate.withState { $0.receivedPackets } }

    public func makeSpec(identifier: UUID) -> CBMPeripheralSpec {
        let toRadio = CBMCharacteristicMock(type: CBMUUID(string: MeshGATT.toRadioUUID.uuidString), properties: [.write])
        let fromRadio = CBMCharacteristicMock(type: CBMUUID(string: MeshGATT.fromRadioUUID.uuidString), properties: [.read])
        let fromNum = CBMCharacteristicMock(type: CBMUUID(string: MeshGATT.fromNumUUID.uuidString), properties: [.notify])
        delegate.fromNumCharacteristic = fromNum
        let service = CBMServiceMock(
            type: CBMUUID(string: MeshGATT.serviceUUID.uuidString),
            primary: true,
            characteristics: toRadio, fromRadio, fromNum
        )
        let spec = CBMPeripheralSpec
            .simulatePeripheral(identifier: identifier, proximity: .near)
            .advertising(advertisementData: [
                CBMAdvertisementDataLocalNameKey: "Meshtastic_MOCK",
                CBMAdvertisementDataServiceUUIDsKey: [CBMUUID(string: MeshGATT.serviceUUID.uuidString)],
                CBMAdvertisementDataIsConnectable: true as NSNumber,
            ], withInterval: 0.05)
            .connectable(name: "Meshtastic_MOCK", services: [service], delegate: delegate, connectionInterval: 0.01)
            .allowForRetrieval()
            .build()
        delegate.spec = spec
        return spec
    }

    /// Enqueue an incoming text (broadcast by default) and fire FromNum so the client drains it.
    public func injectIncomingText(_ text: String, from nodeNum: UInt32, to: UInt32 = 0xFFFF_FFFF) {
        injectIncomingPacket(portnum: .textMessageApp, payload: Data(text.utf8), from: nodeNum, to: to)
    }

    /// Enqueue a decoded incoming packet on any port and fire FromNum.
    public func injectIncomingPacket(portnum: PortNum, payload: Data, from nodeNum: UInt32,
                                     to: UInt32 = 0xFFFF_FFFF, channel: UInt32 = 0,
                                     id: UInt32 = UInt32.random(in: 1...UInt32.max)) {
        var data = DataMessage()
        data.portnum = portnum
        data.payload = payload
        var packet = MeshPacket()
        packet.from = nodeNum
        packet.to = to
        packet.channel = channel
        packet.id = id
        packet.rxTime = delegate.rxTimeNow()
        packet.decoded = data
        var frame = FromRadio()
        frame.packet = packet
        injectFrame(frame)
    }

    /// Enqueue any FromRadio frame and fire FromNum.
    public func injectFrame(_ frame: FromRadio) {
        delegate.enqueue(frame)
        delegate.pushFromNum()
    }

    /// Enqueue arbitrary bytes as the next FromRadio read. `notify: false` queues
    /// without firing FromNum, so a following inject drains both in ONE drain.
    public func injectRawFrame(_ bytes: Data, notify: Bool = true) {
        delegate.enqueueRaw(bytes)
        if notify { delegate.pushFromNum() }
    }

    // MARK: - Periodic traffic

    private let trafficLock = NSLock()
    private var trafficTask: Task<Void, Never>?

    private static let cannedTexts: [String] = [
        "Anyone on channel?",
        "Mesh link looks good 👍",
        "Battery holding steady",
        "Copy that, over",
        "Heading to grid square 7",
    ]

    /// Spawn a retained `Task` that periodically injects a canned incoming
    /// message from one of the "online" fake nodes (0xB001–0xB003), cycling
    /// through both texts and senders. Idempotent (cancels a previous task first).
    public func startPeriodicTraffic(interval: Duration = .seconds(25)) {
        trafficLock.lock()
        trafficTask?.cancel()
        let task = Task {
            let clock = ContinuousClock()
            let onlineNodes: [UInt32] = [0xB001, 0xB002, 0xB003]
            let texts = Self.cannedTexts
            var index = 0
            while !Task.isCancelled {
                try? await clock.sleep(for: interval)
                guard !Task.isCancelled else { break }
                injectIncomingText(texts[index % texts.count], from: onlineNodes[index % onlineNodes.count])
                index += 1
            }
        }
        trafficTask = task
        trafficLock.unlock()
    }

    public func stopPeriodicTraffic() {
        trafficLock.lock()
        trafficTask?.cancel()
        trafficTask = nil
        trafficLock.unlock()
    }

    deinit {
        trafficTask?.cancel()
    }

    // MARK: - Spec delegate

    final class Delegate: CBMPeripheralSpecDelegate, @unchecked Sendable {
        struct MutableState {
            var queue: [Data] = []
            var modemPreset: Config.LoRaConfig.ModemPreset?
            var ackBehavior: AckBehavior = .ack
            var receivedPackets: [MeshPacket] = []
        }

        private let lock = NSLock()
        private var state: MutableState
        private let now: () -> Date
        var fromNumCharacteristic: CBMCharacteristicMock?
        weak var spec: CBMPeripheralSpec?

        init(now: @escaping () -> Date, modemPreset: Config.LoRaConfig.ModemPreset?) {
            self.now = now
            self.state = MutableState(modemPreset: modemPreset)
        }

        /// Explicit lock/unlock: `NSLock.withLock` is macOS 14+, and this package's floor is macOS 13.
        func withState<T>(_ body: (inout MutableState) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&state)
        }

        func enqueue(_ frame: FromRadio) {
            if let data = try? frame.serializedData() { enqueueRaw(data) }
        }

        func enqueueRaw(_ bytes: Data) {
            withState { $0.queue.append(bytes) }
        }

        func pushFromNum() {
            if let ch = fromNumCharacteristic {
                spec?.simulateValueUpdate(Data([0x01]), for: ch)
            }
        }

        func rxTimeNow() -> UInt32 { UInt32(now().timeIntervalSince1970) }

        private func selfMyInfo() -> FromRadio {
            var my = MyNodeInfo()
            my.myNodeNum = MockMeshtasticDevice.selfNodeNum
            my.nodedbCount = UInt32(MockMeshtasticDevice.nodeNums.count + 1)
            var fr = FromRadio()
            fr.myInfo = my
            return fr
        }

        private func selfNodeFrame() -> FromRadio {
            var user = User()
            user.longName = "Mesh Base"
            user.shortName = "BASE"
            var info = NodeInfo()
            info.num = MockMeshtasticDevice.selfNodeNum
            info.user = user
            info.lastHeard = UInt32(now().timeIntervalSince1970 - 30)
            var fr = FromRadio()
            fr.nodeInfo = info
            return fr
        }

        private func nodeFrame(index: Int) -> FromRadio {
            let num = MockMeshtasticDevice.nodeNums[index]
            var user = User()
            user.longName = "Node \(index + 1)"
            user.shortName = "N\(index + 1)"
            var metrics = DeviceMetrics()
            metrics.batteryLevel = MockMeshtasticDevice.batteryLevels[index]
            metrics.channelUtilization = 10
            metrics.airUtilTx = 2
            var info = NodeInfo()
            info.num = num
            info.user = user
            info.snr = 5
            info.lastHeard = UInt32(now().timeIntervalSince1970 - MockMeshtasticDevice.lastHeardOffsets[index])
            info.deviceMetrics = metrics
            var fr = FromRadio()
            fr.nodeInfo = info
            return fr
        }

        private func loraConfigFrame(_ preset: Config.LoRaConfig.ModemPreset) -> FromRadio {
            var lora = Config.LoRaConfig()
            lora.usePreset = true
            lora.modemPreset = preset
            lora.hopLimit = 3
            var config = Config()
            config.lora = lora
            var fr = FromRadio()
            fr.config = config
            return fr
        }

        private func metadataFrame() -> FromRadio {
            var meta = DeviceMetadata()
            meta.firmwareVersion = "2.5.0.mock"
            var fr = FromRadio()
            fr.metadata = meta
            return fr
        }

        private func channelFrame() -> FromRadio {
            var settings = ChannelSettings()
            settings.name = ""
            var channel = Channel()
            channel.index = 0
            channel.role = .primary
            channel.settings = settings
            var fr = FromRadio()
            fr.channel = channel
            return fr
        }

        private func routingReply(to sent: MeshPacket, behavior: AckBehavior) -> FromRadio? {
            var routing = Routing()
            switch behavior {
            case .silent: return nil
            case .ack: routing.errorReason = .none
            case .nak(let reason): routing.errorReason = reason
            }
            var ackData = DataMessage()
            ackData.portnum = .routingApp
            ackData.requestID = sent.id
            ackData.payload = (try? routing.serializedData()) ?? Data()
            var ackPacket = MeshPacket()
            ackPacket.from = MockMeshtasticDevice.selfNodeNum
            ackPacket.to = MockMeshtasticDevice.selfNodeNum
            ackPacket.decoded = ackData
            var ackFrame = FromRadio()
            ackFrame.packet = ackPacket
            return ackFrame
        }

        /// Demo value: a text DM to one of the fake nodes gets a canned reply FROM
        /// that node addressed to selfNodeNum, ~3 s later.
        private func scheduleCannedReply(from dest: UInt32) {
            let now = self.now
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                var reply = DataMessage()
                reply.portnum = .textMessageApp
                reply.payload = Data("Got your message 👋".utf8)
                var packet = MeshPacket()
                packet.from = dest
                packet.to = MockMeshtasticDevice.selfNodeNum
                packet.channel = 0
                packet.id = UInt32.random(in: 1...UInt32.max)
                packet.rxTime = UInt32(now().timeIntervalSince1970)
                packet.decoded = reply
                var fr = FromRadio()
                fr.packet = packet
                self.enqueue(fr)
                self.pushFromNum()
            }
        }

        // MARK: CBMPeripheralSpecDelegate

        func peripheral(_ peripheral: CBMPeripheralSpec,
                        didReceiveReadRequestFor characteristic: CBMCharacteristicMock) -> Result<Data, any Error> {
            guard characteristic.uuid.uuidString == MeshGATT.fromRadioUUID.uuidString else {
                return .success(Data())
            }
            let next = withState { s in s.queue.isEmpty ? Data() : s.queue.removeFirst() }
            return .success(next)
        }

        func peripheral(_ peripheral: CBMPeripheralSpec,
                        didReceiveWriteRequestFor characteristic: CBMCharacteristicMock,
                        data: Data) -> Result<Void, any Error> {
            guard characteristic.uuid.uuidString == MeshGATT.toRadioUUID.uuidString,
                  let toRadio = try? ToRadio(serializedBytes: data) else {
                return .success(())
            }
            switch toRadio.payloadVariant {
            case .wantConfigID(let nonce)?:
                let preset = withState { $0.modemPreset }
                var frames = [selfMyInfo(), selfNodeFrame()]
                frames += MockMeshtasticDevice.nodeNums.indices.map { nodeFrame(index: $0) }
                if let preset { frames.append(loraConfigFrame(preset)) }
                frames += [metadataFrame(), channelFrame()]
                var complete = FromRadio()
                complete.configCompleteID = nonce
                frames.append(complete)
                for frame in frames { enqueue(frame) }
                pushFromNum()
            case .packet(let sent)?:
                guard case .decoded(let sentData)? = sent.payloadVariant else { return .success(()) }
                let behavior = withState { s -> AckBehavior in
                    s.receivedPackets.append(sent)
                    return s.ackBehavior
                }
                if let reply = routingReply(to: sent, behavior: behavior) {
                    enqueue(reply)
                    pushFromNum()
                }
                if sentData.portnum == .textMessageApp, MockMeshtasticDevice.nodeNums.contains(sent.to) {
                    scheduleCannedReply(from: sent.to)
                }
            default:
                break
            }
            return .success(())
        }

        func peripheral(_ peripheral: CBMPeripheralSpec,
                        didReceiveSetNotifyRequest enabled: Bool,
                        for characteristic: CBMCharacteristicMock) -> Result<Void, any Error> {
            .success(())
        }
    }
}
```

- [ ] **Step 6: Run and verify all pass (step a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter MockRadioTests`
Expected: `Test run with 8 tests passed`.

- [ ] **Step 7: Mutate in one batch (step b)**, all in `MockMeshtasticDevice.swift`:
- In the `.wantConfigID` branch, replace `if let preset { frames.append(loraConfigFrame(preset)) }` with `frames.append(loraConfigFrame(.longFast))`. This breaks `handshakeServes…` (expects `.shortFast`), `handshakeOmits…` (expects none) and `presetChange…` (expects `.longModerate`).
- In `routingReply`:
  - change `ackData.requestID = sent.id` to `ackData.requestID = 0`. This breaks `packetOnAnyPort…` and `nak…`.
  - change `case .silent: return nil` to `case .silent: routing.errorReason = .none`. This breaks `silent…`.
- In the `.packet` branch, change `s.receivedPackets.append(sent)` to `_ = sent`. This breaks `everyWrittenPacket…`.
- In `injectIncomingPacket`, change `packet.channel = channel` to `packet.channel = 0`. This breaks `injectedPacket…`.

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter MockRadioTests`
Expected: all 8 tests FAIL.

- [ ] **Step 8: Revert every mutation and re-run (step c)**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter MockRadioTests`
Expected: `Test run with 8 tests passed`.

- [ ] **Step 9: Commit**

Write `/tmp/ReTiCA/commit-msg.txt`:
```
feat: MeshtasticMock radio ACKs any port, serves a LoRa config, records writes

Moved from MeshtastifiedKit; NSLock.withLock (macOS 14) replaced so the
package builds at its macOS 13 floor.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit add Package.swift Sources/MeshtasticMock Tests/MeshtasticKitTests/Support/CBMSupport.swift Tests/MeshtasticKitTests/MockRadioTests.swift`
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit commit -F /tmp/ReTiCA/commit-msg.txt`
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit log -1 --format='%(trailers:key=Claude-Session)'`
Expected: the session URL.

---

### Task 3: MeshtasticSession — event hub, retrieve-only connect, handshake, `.configured`, terminal causes, disconnect

**Files:**
- Create: `/Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshtasticKit/EventHub.swift`
- Create: `/Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshtasticKit/MeshtasticSession.swift`
- Create: `/Users/ell/development/ios/pods/MeshtasticKit/Tests/MeshtasticKitTests/Support/SessionSupport.swift`
- Test: `/Users/ell/development/ios/pods/MeshtasticKit/Tests/MeshtasticKitTests/SessionConnectTests.swift`

**Interfaces:**
- Consumes: Task 1 types, Task 2 `MockMeshtasticDevice` + `makeMockRadio`.
- Produces:
  ```swift
  public actor MeshtasticSession {
      public init(central: BluetoothCentralClient, clock: any Clock<Duration> = ContinuousClock(),
                  packetID: @Sendable @escaping () -> UInt32 = { UInt32.random(in: 1 ... .max) })
      public func connect(radio: UUID) async        // returns once the FIRST attempt resolves
      public func disconnect() async
      public nonisolated func events() -> AsyncStream<MeshtasticEvent>
  }
  ```
  Internal names that later tasks edit:
  - `epoch: UInt64`, `check(_:)`
  - `runAttempt(radio:epoch:) -> AttemptOutcome` (`.connected / .superseded / .terminal(String) / .retryable(String)`)
  - `attemptConnect(radio:epoch:)`, `tearDownLink()`
  - `process(_ frame: FromRadio)`, `writeToRadio(_:radio:)`
  - `waitForPoweredOn(epoch:)`, `TerminalFailure`

  Test support:
  - event predicates `.connectionState`, `.isConfigured`, `.packetID`, `.isRouting`, `.frameValue`, `.isAdapterUnavailable` (assert with `==`; `MeshtasticEvent` is Equatable)
  - `collect(_:timeout:until:)`, `waitUntil(timeout:_:)`
  - `recording(_:into:)`, `fakeCentral(radio:state:log:connect:)`
  - `makeCounter(start:)`, `makeSessionHarness(...)`, `SessionHarness`

Semantics locked here (later tasks rely on them):
- Every `connect(radio:)` emits `.connecting` first, before anything else. Meshtastified's adapter keys its outcome on this.
- Within a handshake, `.connection(.connected)` is emitted, then `.configured`, both before `connect` returns.
- In this task a non-terminal first-attempt failure ends `.disconnected(reason: <error description>)`. Task 6 replaces this with backoff.

- [ ] **Step 1: Write the test support** `Tests/MeshtasticKitTests/Support/SessionSupport.swift`

```swift
import ComposableArchitecture
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import FCBComposable
import Foundation
import MeshProto
import MeshtasticKit
import MeshtasticMock
import Testing

// MARK: Event predicates (MeshtasticEvent is Equatable — assert with `==`; these only
// pick events out of a stream)

extension MeshtasticEvent {
    var connectionState: MeshtasticConnectionState? {
        if case .connection(let state) = self { return state }
        return nil
    }
    var isConfigured: Bool {
        if case .configured = self { return true }
        return false
    }
    /// The id of a `.packet` event (nil for every other case).
    var packetID: UInt32? {
        if case .packet(_, _, _, _, _, let id) = self { return id }
        return nil
    }
    var isRouting: Bool {
        if case .routing = self { return true }
        return false
    }
    var frameValue: FromRadio? {
        if case .frame(let frame) = self { return frame }
        return nil
    }
    var isAdapterUnavailable: Bool {
        if case .adapterUnavailable = self { return true }
        return false
    }
}

// MARK: Collection

/// Iterates `stream` until `stop` matches (inclusive) or `timeout` (real time)
/// passes. Returns everything seen and whether `stop` matched. CONSUMES the
/// stream: a later collect needs a fresh `session.events()` created BEFORE the
/// action whose events it should see.
func collect(_ stream: AsyncStream<MeshtasticEvent>, timeout: Duration = .seconds(5),
             until stop: @escaping @Sendable (MeshtasticEvent) -> Bool) async -> (events: [MeshtasticEvent], matched: Bool) {
    let box = LockIsolated<[MeshtasticEvent]>([])
    let matched = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await event in stream {
                box.withValue { $0.append(event) }
                if stop(event) { return true }
            }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
    return (box.value, matched)
}

/// Polls `condition` every 10 ms until true or `timeout` (real time).
func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Sequential packet ids starting at `start`.
func makeCounter(start: UInt32 = 0x100) -> @Sendable () -> UInt32 {
    let next = LockIsolated(start)
    return { next.withValue { value in defer { value &+= 1 }; return value } }
}

// MARK: Centrals

/// Wraps a LIVE central, logging "scan" / "retrievePeripherals" / "connect" calls
/// in order; every call still reaches the real FCB actor.
func recording(_ base: BluetoothCentralClient, into log: LockIsolated<[String]>) -> BluetoothCentralClient {
    var client = base
    client.scan = { services, options in
        log.withValue { $0.append("scan") }
        return base.scan(services, options)
    }
    client.retrievePeripherals = { ids in
        log.withValue { $0.append("retrievePeripherals") }
        return await base.retrievePeripherals(ids)
    }
    client.connect = { id, options in
        log.withValue { $0.append("connect") }
        return try await base.connect(id, options)
    }
    return client
}

/// A closure-backed central for paths CoreBluetoothMock cannot drive
/// deterministically (adapter authorization, failing or gated connects, backoff
/// timing). Every endpoint the session can touch is set. It NEVER completes a
/// handshake (reads are empty), so use it only for paths that end before
/// `.configuring` completes.
func fakeCentral(radio: UUID, state: CBManagerState = .poweredOn, log: LockIsolated<[String]>,
                 connect: @escaping @Sendable () async throws -> Void) -> BluetoothCentralClient {
    BluetoothCentralClient(
        state: { AsyncStream { $0.yield(state) } },
        authorization: { .allowedAlways },
        scan: { _, _ in
            log.withValue { $0.append("scan") }
            return .never
        },
        stopScan: {},
        connect: { id, _ in
            log.withValue { $0.append("connect") }
            try await connect()
            return Peripheral(id: id, name: "Fake", state: .connected)
        },
        disconnect: { _ in log.withValue { $0.append("disconnect") } },
        retrievePeripherals: { ids in
            log.withValue { $0.append("retrievePeripherals") }
            return ids.filter { $0 == radio }.map { Peripheral(id: $0, name: "Fake", state: .disconnected) }
        },
        retrieveConnected: { _ in [] },
        discoverServices: { _, _ in [] },
        discoverCharacteristics: { _, _, _ in [] },
        readValue: { _, _ in Data() },
        writeValue: { _, _, _, _ in },
        setNotify: { _, _, _ in },
        maximumWriteValueLength: { _, _ in 512 },
        notifications: { _, _ in AsyncThrowingStream { _ in } },
        openL2CAPChannel: { _, _ in throw BluetoothError.l2capNotSupported },
        events: { AsyncStream { _ in } },
        canSendWriteWithoutResponse: { _ in true }
    )
}

// MARK: Harness

/// A mock radio + a MeshtasticSession over the LIVE FCB mocked client, with call logging.
struct SessionHarness {
    let radio: MockRadio
    let session: MeshtasticSession
    let log: LockIsolated<[String]>
}

/// Default clock is the REAL `ContinuousClock`, never `ImmediateClock`: the session's
/// 30 s want_config timeout sleeps on the injected clock, and an ImmediateClock would
/// fire it at once and kill every handshake. Backoff then costs 1 s of real time in
/// reconnect tests; pass a `TestClock` to step time explicitly.
@MainActor
func makeSessionHarness(
    id: UUID = UUID(),
    clock: any Clock<Duration> = ContinuousClock(),
    modemPreset: Config.LoRaConfig.ModemPreset? = .shortFast,
    initialState: CBMManagerState = .poweredOn,
    extra: [CBMPeripheralSpec] = [],
    packetID: @escaping @Sendable () -> UInt32 = makeCounter()
) async -> SessionHarness {
    let radio = await makeMockRadio(id: id, modemPreset: modemPreset, initialState: initialState, extra: extra)
    let log = LockIsolated<[String]>([])
    let session = MeshtasticSession(central: recording(radio.central, into: log), clock: clock, packetID: packetID)
    return SessionHarness(radio: radio, session: session, log: log)
}
```

- [ ] **Step 2: Write the failing tests** `Tests/MeshtasticKitTests/SessionConnectTests.swift`

```swift
import ComposableArchitecture
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import FCBComposable
import Foundation
import MeshProto
import MeshtasticKit
import MeshtasticMock
import Testing

struct SessionReplayTests {
    @Test func eventsReplayDisconnectedBeforeAnyConnect() async {
        let session = MeshtasticSession(central: .testValue)
        let (events, matched) = await collect(session.events(), timeout: .seconds(2)) { _ in true }
        #expect(matched)
        #expect(events.first?.connectionState == .disconnected(reason: nil))
    }

    @Test func unauthorizedAdapterIsTerminalAndNeverConnects() async {
        let id = UUID()
        let log = LockIsolated<[String]>([])
        let session = MeshtasticSession(central: fakeCentral(radio: id, state: .unauthorized, log: log, connect: {}),
                                        clock: ImmediateClock())
        let events = session.events()
        let connecting = Task { await session.connect(radio: id) }
        let (seen, matched) = await collect(events) { $0.connectionState == .disconnected(reason: "unauthorized") }
        #expect(matched)
        #expect(seen.filter(\.isAdapterUnavailable) == [.adapterUnavailable(.unauthorized)])
        #expect(!log.value.contains("connect"))
        await session.disconnect()
        connecting.cancel()
    }
}

extension CBMBackedTests {
    @Suite @MainActor
    struct SessionConnectTests {
        @Test func connectRunsHandshakeAndEmitsConfiguredWithThePreset() async {
            let h = await makeSessionHarness(modemPreset: .shortFast)
            let events = h.session.events()
            await h.session.connect(radio: h.radio.id)
            let (seen, matched) = await collect(events) { $0.isConfigured }
            #expect(matched)
            #expect(seen.compactMap(\.connectionState) == [.disconnected(reason: nil), .connecting, .configuring, .connected])
            #expect(seen.last == .configured(myNodeNum: MockMeshtasticDevice.selfNodeNum,
                                             modemPreset: Config.LoRaConfig.ModemPreset.shortFast.rawValue))
            let nodeFrames = seen.compactMap(\.frameValue).filter {
                if case .nodeInfo? = $0.payloadVariant { return true }
                return false
            }
            #expect(nodeFrames.count == 7)
        }

        @Test func configuredReportsNilPresetWhenTheRadioSendsNoLoRaConfig() async {
            let h = await makeSessionHarness(modemPreset: nil)
            let events = h.session.events()
            await h.session.connect(radio: h.radio.id)
            let (seen, _) = await collect(events) { $0.isConfigured }
            #expect(seen.last == .configured(myNodeNum: MockMeshtasticDevice.selfNodeNum, modemPreset: nil))
        }

        @Test func connectRetrievesThePeripheralFirstAndNeverScans() async {
            let h = await makeSessionHarness()
            await h.session.connect(radio: h.radio.id)
            #expect(h.log.value == ["retrievePeripherals", "connect"])
        }

        @Test func connectToAnUnknownRadioEndsDisconnectedRadioNotFound() async {
            let h = await makeSessionHarness()
            let stranger = UUID()
            let events = h.session.events()
            await h.session.connect(radio: stranger)
            let (seen, matched) = await collect(events) { $0.connectionState == .disconnected(reason: "radio not found") }
            #expect(matched)
            #expect(seen.compactMap(\.connectionState) == [.disconnected(reason: nil), .connecting, .disconnected(reason: "radio not found")])
            #expect(!h.log.value.contains("connect"))
        }

        @Test func connectWhilePoweredOffWaitsThenConnects() async {
            let h = await makeSessionHarness(initialState: .poweredOff)
            let events = h.session.events()
            let connecting = Task { await h.session.connect(radio: h.radio.id) }
            let (seenOff, sawUnavailable) = await collect(events) { $0.isAdapterUnavailable }
            #expect(sawUnavailable)
            #expect(seenOff.filter(\.isAdapterUnavailable) == [.adapterUnavailable(.poweredOff)])
            let after = h.session.events()
            CBMCentralManagerMock.simulatePowerOn()
            let (_, configured) = await collect(after, timeout: .seconds(10)) { $0.isConfigured }
            #expect(configured)
            await connecting.value
        }

        @Test func disconnectDropsTheLinkAndReportsDisconnectedWithNilReason() async {
            let h = await makeSessionHarness()
            await h.session.connect(radio: h.radio.id)
            await h.session.disconnect()
            let (seen, _) = await collect(h.session.events(), timeout: .seconds(1)) { _ in true }
            #expect(seen.first?.connectionState == .disconnected(reason: nil))
            let stillConnected = await h.radio.central.retrieveConnected([MeshGATT.serviceUUID])
            #expect(!stillConnected.map(\.id).contains(h.radio.id))
        }
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter "SessionReplayTests|SessionConnectTests"`
Expected: compile FAILURE `cannot find 'MeshtasticSession' in scope`.

- [ ] **Step 4: Write `Sources/MeshtasticKit/EventHub.swift`**

```swift
import Foundation
import os

/// Lock-backed fan-out behind `MeshtasticSession.events()`. Registration and the
/// connection-state replay happen synchronously inside `subscribe()`, so a
/// subscriber created before `connect` cannot miss that connect's first events
/// (an actor-hop registration, as in Meshtastified's old session, could land
/// after them).
final class EventHub: Sendable {
    private struct State: Sendable {
        var continuations: [UUID: AsyncStream<MeshtasticEvent>.Continuation] = [:]
        var connection: MeshtasticConnectionState = .disconnected(reason: nil)
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var connection: MeshtasticConnectionState { state.withLock { $0.connection } }

    func subscribe() -> AsyncStream<MeshtasticEvent> {
        let token = UUID()
        return AsyncStream { continuation in
            state.withLock { s in
                s.continuations[token] = continuation
                continuation.yield(.connection(s.connection))
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.state.withLock { $0.continuations.removeValue(forKey: token) }
            }
        }
    }

    func emit(_ event: MeshtasticEvent) {
        state.withLock { s in
            for continuation in s.continuations.values { continuation.yield(event) }
        }
    }

    /// Stores and emits atomically, so the replayed value and the stream never disagree.
    func setConnection(_ connection: MeshtasticConnectionState) {
        state.withLock { s in
            s.connection = connection
            for continuation in s.continuations.values { continuation.yield(.connection(connection)) }
        }
    }
}
```

- [ ] **Step 5: Write `Sources/MeshtasticKit/MeshtasticSession.swift`**

```swift
@preconcurrency import CoreBluetooth
import FCBComposable
import Foundation
import MeshProto
import os

/// One Meshtastic radio over BLE: want_config handshake, FromRadio drain, ToRadio
/// send, reconnect. Ported from Meshtastified's MeshSessionActor, made port-agnostic.
/// Connects ONLY via `retrievePeripherals` — it never scans (FCB has one scan per
/// process; scanning belongs to `MeshtasticScanner`).
public actor MeshtasticSession {
    static let maxPayloadLength = 233

    private let central: BluetoothCentralClient
    private let clock: any Clock<Duration>
    private let packetID: @Sendable () -> UInt32
    private let logger = Logger(subsystem: "MeshtasticKit", category: "MeshtasticSession")
    private nonisolated let hub = EventHub()

    /// Bumped by every `connect`/`disconnect`. Attempts, drains and the reconnect
    /// loop re-check it after every await (FCB continuations ignore task
    /// cancellation), so work begun for a superseded link can never emit state or
    /// touch BLE for the current one.
    private var epoch: UInt64 = 0
    private var radioID: UUID?
    private var myNodeNum: UInt32?
    private var modemPreset: Int?
    private var configNonce: UInt32 = 0
    /// Held across the handshake so a FromNum notify mid-handshake cannot start a
    /// steady drain racing it on FCB's single read slot per characteristic.
    private var isDraining = false
    private var drainGeneration: UInt64 = 0
    private var attemptTask: Task<Void, any Error>?
    private var fromNumTask: Task<Void, Never>?

    public init(central: BluetoothCentralClient,
                clock: any Clock<Duration> = ContinuousClock(),
                packetID: @Sendable @escaping () -> UInt32 = { UInt32.random(in: 1 ... .max) }) {
        self.central = central
        self.clock = clock
        self.packetID = packetID
    }

    // MARK: - Events

    /// Multi-subscriber. Registration is synchronous, so a stream created before
    /// `connect` sees every event of that connect. The current connection state
    /// is replayed first; nothing else is buffered for late subscribers.
    public nonisolated func events() -> AsyncStream<MeshtasticEvent> { hub.subscribe() }

    private var connectionState: MeshtasticConnectionState { hub.connection }
    private func setState(_ state: MeshtasticConnectionState) { hub.setConnection(state) }
    private func emit(_ event: MeshtasticEvent) { hub.emit(event) }

    // MARK: - Connect / disconnect

    /// Connects via `retrievePeripherals` — never scans, including on reconnect —
    /// superseding any current link. Always emits `.connecting` first. Returns once
    /// the first attempt resolves: `.connected` + `.configured` emitted, or a
    /// failure state emitted. CoreBluetooth connects do not time out, so for an
    /// out-of-range radio this suspends until it appears or `disconnect()` is called.
    public func connect(radio: UUID) async {
        epoch &+= 1
        let myEpoch = epoch
        await tearDownLink()
        guard myEpoch == epoch else { return }
        radioID = radio
        let outcome = await runAttempt(radio: radio, epoch: myEpoch)
        guard myEpoch == epoch else { return }
        switch outcome {
        case .connected, .superseded:
            return
        case .terminal(let reason), .retryable(let reason):
            radioID = nil
            setState(.disconnected(reason: reason))
        }
    }

    public func disconnect() async {
        epoch &+= 1
        let myEpoch = epoch
        await tearDownLink()
        guard myEpoch == epoch else { return }
        setState(.disconnected(reason: nil))
    }

    /// Cancels the current link's tasks and drops its BLE connection. Callers bump
    /// `epoch` first, so nothing cancelled here can emit afterwards.
    private func tearDownLink() async {
        attemptTask?.cancel()
        attemptTask = nil
        fromNumTask?.cancel()
        fromNumTask = nil
        let old = radioID
        radioID = nil
        if let old { try? await central.disconnect(old) }
    }

    private enum AttemptOutcome {
        case connected, superseded, terminal(String), retryable(String)
    }

    /// A cause retrying cannot fix: the session ends `.disconnected(reason:)`.
    private struct TerminalFailure: Error {
        let reason: String
    }

    /// Runs one attempt in its own task, so `disconnect()` can cancel the parts
    /// that do honor cancellation (the powered-on wait).
    private func runAttempt(radio: UUID, epoch myEpoch: UInt64) async -> AttemptOutcome {
        let task = Task { try await self.attemptConnect(radio: radio, epoch: myEpoch) }
        attemptTask = task
        let result = await task.result
        if attemptTask == task { attemptTask = nil }
        switch result {
        case .success:
            return .connected
        case .failure(let error):
            guard myEpoch == epoch, !(error is CancellationError) else { return .superseded }
            if let terminal = error as? TerminalFailure { return .terminal(terminal.reason) }
            fromNumTask?.cancel()
            fromNumTask = nil
            try? await central.disconnect(radio)
            return myEpoch == epoch ? .retryable(String(describing: error)) : .superseded
        }
    }

    private func check(_ myEpoch: UInt64) throws {
        if myEpoch != epoch || Task.isCancelled { throw CancellationError() }
    }

    private func attemptConnect(radio: UUID, epoch myEpoch: UInt64) async throws {
        try check(myEpoch)
        myNodeNum = nil
        modemPreset = nil
        setState(.connecting)
        try await waitForPoweredOn(epoch: myEpoch)
        // retrievePeripherals (not scan) is the only way this session finds a radio. It also
        // re-stores the live peripheral object in FCB, replacing one CoreBluetooth invalidated
        // in a power cycle (FCB BluetoothCentralClient+Live.swift:271-275).
        let known = await central.retrievePeripherals([radio])
        try check(myEpoch)
        guard known.contains(where: { $0.id == radio }) else {
            throw TerminalFailure(reason: "radio not found")
        }
        _ = try await central.connect(radio, ConnectOptions?.none)
        try check(myEpoch)
        _ = try await central.discoverServices(radio, [MeshGATT.serviceUUID])
        try check(myEpoch)
        _ = try await central.discoverCharacteristics(
            radio, MeshGATT.serviceUUID,
            [MeshGATT.toRadioUUID, MeshGATT.fromRadioUUID, MeshGATT.fromNumUUID]
        )
        try check(myEpoch)
        // Subscribe to FromNum BEFORE want_config so no notify is lost.
        try await central.setNotify(true, radio, MeshGATT.fromNumUUID)
        try check(myEpoch)
        startFromNumLoop(radio: radio, epoch: myEpoch)

        isDraining = true
        drainGeneration &+= 1
        let claimed = drainGeneration
        setState(.configuring)
        do {
            try await requestConfig(radio: radio)
            try await drainUntilConfigComplete(radio: radio, epoch: myEpoch)
            try check(myEpoch)
        } catch {
            if drainGeneration == claimed { isDraining = false }
            throw error
        }
        isDraining = false
        setState(.connected)
        emit(.configured(myNodeNum: myNodeNum ?? 0, modemPreset: modemPreset))
    }

    /// CoreBluetooth silently drops commands issued before `.poweredOn`, and
    /// `retrievePeripherals` returns [] until then — so wait. FCB's state stream
    /// replays the current state, so this returns at once when already on.
    private func waitForPoweredOn(epoch myEpoch: UInt64) async throws {
        var reportedOff = false
        for await state in central.state() {
            try check(myEpoch)
            switch state {
            case .poweredOn:
                return
            case .poweredOff:
                if !reportedOff {
                    reportedOff = true
                    emit(.adapterUnavailable(.poweredOff))
                }
            case .unauthorized:
                emit(.adapterUnavailable(.unauthorized))
                throw TerminalFailure(reason: "unauthorized")
            case .unsupported:
                emit(.adapterUnavailable(.unsupported))
                throw TerminalFailure(reason: "unsupported")
            default:
                continue   // .unknown / .resetting: CoreBluetooth is still settling
            }
        }
        throw CancellationError()   // the stream only ends when this task is cancelled
    }

    private func requestConfig(radio: UUID) async throws {
        var nonce = packetID()
        if nonce == 0 { nonce = 1 }
        configNonce = nonce
        var toRadio = ToRadio()
        toRadio.wantConfigID = nonce
        try await writeToRadio(try toRadio.serializedData(), radio: radio)
    }

    private func writeToRadio(_ bytes: Data, radio: UUID) async throws {
        try await central.writeValue(bytes, radio, MeshGATT.toRadioUUID, .withResponse)
    }

    /// Reads FromRadio until config_complete_id == nonce. Empty reads are a
    /// transient gap during the handshake and are retried; malformed frames skipped.
    private func drainUntilConfigComplete(radio: UUID, epoch myEpoch: UInt64) async throws {
        while true {
            let data = try await central.readValue(radio, MeshGATT.fromRadioUUID)
            try check(myEpoch)
            if data.isEmpty { continue }
            guard let frame = try? FromRadio(serializedBytes: data) else {
                logger.error("skipping malformed FromRadio frame during handshake")
                continue
            }
            process(frame)
            if case .configCompleteID(let completed)? = frame.payloadVariant, completed == configNonce {
                return
            }
        }
    }

    // MARK: - Steady-state drain

    private func startFromNumLoop(radio: UUID, epoch myEpoch: UInt64) {
        fromNumTask?.cancel()
        let notifications = central.notifications(radio, MeshGATT.fromNumUUID)
        fromNumTask = Task { [weak self] in
            do {
                for try await _ in notifications {
                    await self?.drainSteady(radio: radio, epoch: myEpoch)
                }
            } catch {
                await self?.logDrainEnd(error)
            }
        }
    }

    private func logDrainEnd(_ error: any Error) {
        logger.error("FromNum notification stream ended: \(String(describing: error))")
    }

    /// Drains FromRadio until an empty read. A stale drain (older epoch, or one
    /// resuming after a newer handshake claimed the lock) exits without emitting
    /// and without releasing the newer claim.
    private func drainSteady(radio: UUID, epoch myEpoch: UInt64) async {
        guard myEpoch == epoch, !Task.isCancelled, !isDraining else { return }
        isDraining = true
        drainGeneration &+= 1
        let claimed = drainGeneration
        defer { if drainGeneration == claimed { isDraining = false } }
        while myEpoch == epoch, !Task.isCancelled {
            let data: Data
            do {
                data = try await central.readValue(radio, MeshGATT.fromRadioUUID)
            } catch {
                logger.error("FromRadio read failed during drain: \(String(describing: error))")
                return
            }
            guard myEpoch == epoch else { return }
            if data.isEmpty { return }
            guard let frame = try? FromRadio(serializedBytes: data) else {
                logger.error("skipping malformed FromRadio frame during drain")
                continue
            }
            process(frame)
        }
    }

    /// Every decoded frame goes out as `.frame` first; derived events follow.
    private func process(_ frame: FromRadio) {
        emit(.frame(frame))
        switch frame.payloadVariant {
        case .myInfo(let info)?:
            myNodeNum = info.myNodeNum
        case .config(let config)?:
            if case .lora(let lora)? = config.payloadVariant {
                modemPreset = lora.modemPreset.rawValue
            }
        default:
            break
        }
    }
}
```

- [ ] **Step 6: Run and verify all pass (step a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter "SessionReplayTests|SessionConnectTests"`
Expected: `Test run with 8 tests passed`.

- [ ] **Step 7: Mutate in one batch (step b)**

In `EventHub.swift`:
- change `var connection: MeshtasticConnectionState = .disconnected(reason: nil)` to `= .connecting`. This breaks the replay test, the handshake sequence and the unknown-radio sequence.

In `MeshtasticSession.swift`:
- in `waitForPoweredOn`, replace the bodies of `case .poweredOff:` and `case .unauthorized:` each with just `continue`. The unauthorized test then hangs until its bounded collect fails, and the powered-off test sees no `.adapterUnavailable`.
- in `process(_:)`, delete the `case .config(let config)?:` arm (breaks the handshake test's preset).
- in `attemptConnect`, change `modemPreset: modemPreset))` in the `.configured` emit to `modemPreset: modemPreset ?? 0))` (breaks the nil-preset test).
- in `attemptConnect`, delete the `let known = await central.retrievePeripherals([radio])` line, the following `try check(myEpoch)`, and the `guard known.contains…` block. FCB's connect falls back to its own lookup, so the connect still works, but the log becomes `["connect"]` and the unknown radio fails with a non-"radio not found" reason.
- in `tearDownLink()`, delete `if let old { try? await central.disconnect(old) }` (the disconnect test).

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter "SessionReplayTests|SessionConnectTests"`
Expected: all 8 tests FAIL. The unauthorized and powered-off tests fail by bounded timeout, in roughly 5 s each.

- [ ] **Step 8: Revert every mutation and re-run (step c)**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter "SessionReplayTests|SessionConnectTests"`
Expected: `Test run with 8 tests passed`.

- [ ] **Step 9: Run the whole package suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit`
Expected: 22 tests passed (6 + 8 + 8).

- [ ] **Step 10: Commit**

Write `/tmp/ReTiCA/commit-msg.txt`:
```
feat: MeshtasticSession connects via retrievePeripherals and emits configured with the preset

Synchronous event hub, powered-on gate, epoch-guarded attempts, terminal
causes (radio not found / unauthorized / unsupported).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit add Sources/MeshtasticKit/EventHub.swift Sources/MeshtasticKit/MeshtasticSession.swift Tests/MeshtasticKitTests/Support/SessionSupport.swift Tests/MeshtasticKitTests/SessionConnectTests.swift`
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit commit -F /tmp/ReTiCA/commit-msg.txt`
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit log -1 --format='%(trailers:key=Claude-Session)'`
Expected: the session URL.

---

### Task 4: Receive path — `.packet` for any port, `.routing`, hostile input

**Files:**
- Modify: `/Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshtasticKit/MeshtasticSession.swift` (`process(_:)` + new `emitPacketEvents(_:)`)
- Test: `/Users/ell/development/ios/pods/MeshtasticKit/Tests/MeshtasticKitTests/SessionReceiveTests.swift`

**Interfaces:**
- Consumes: Task 3 session + harness; Task 2 `injectIncomingPacket`, `injectFrame`, `injectRawFrame(_:notify:)`.
- Produces: `.packet(from:to:channel:portnum:payload:id:)` for every decoded MeshPacket whose portnum is non-negative. It is followed by `.routing(packetID: requestID, ok: errorReason == .none)` when the port is ROUTING_APP. Lane E consumes `.packet(portnum: 76, …)`.

- [ ] **Step 1: Write the failing tests** `Tests/MeshtasticKitTests/SessionReceiveTests.swift`

```swift
import ComposableArchitecture
@preconcurrency import CoreBluetoothMock
import FCBComposable
import Foundation
import MeshProto
import MeshtasticKit
import MeshtasticMock
import Testing

private func routingFrame(requestID: UInt32, reason: Routing.Error) throws -> FromRadio {
    var routing = Routing()
    routing.errorReason = reason
    var data = DataMessage()
    data.portnum = .routingApp
    data.requestID = requestID
    data.payload = try routing.serializedData()
    var packet = MeshPacket()
    packet.from = MockMeshtasticDevice.selfNodeNum
    packet.decoded = data
    var frame = FromRadio()
    frame.packet = packet
    return frame
}

extension CBMBackedTests {
    @Suite @MainActor
    struct SessionReceiveTests {
        @Test func incomingPort76PacketEmitsPacketWithEveryField() async {
            let h = await makeSessionHarness()
            await h.session.connect(radio: h.radio.id)
            let events = h.session.events()
            h.radio.device.injectIncomingPacket(portnum: .reticulumTunnelApp, payload: Data([1, 2, 3]),
                                                from: 0xB001, to: 0xFFFF_FFFF, channel: 2, id: 0x1234)
            let (seen, matched) = await collect(events) { $0.packetID != nil }
            #expect(matched)
            #expect(seen.last == .packet(from: 0xB001, to: 0xFFFF_FFFF, channel: 2, portnum: 76,
                                                           payload: Data([1, 2, 3]), id: 0x1234))
        }

        @Test func frameForAPacketPrecedesItsPacketEvent() async {
            let h = await makeSessionHarness()
            await h.session.connect(radio: h.radio.id)
            let events = h.session.events()
            h.radio.device.injectIncomingPacket(portnum: .reticulumTunnelApp, payload: Data([7]), from: 0xB002, id: 0x77)
            let (seen, _) = await collect(events) { $0.packetID != nil }
            let tail = Array(seen.suffix(2))
            #expect(tail.count == 2)
            guard case .packet(let packet)? = tail.first?.frameValue?.payloadVariant else {
                Issue.record("the event before .packet must be its .frame")
                return
            }
            #expect(packet.id == 0x77)
        }

        @Test func nonPacketFrameIsEmittedAsFrame() async {
            let h = await makeSessionHarness()
            await h.session.connect(radio: h.radio.id)
            let events = h.session.events()
            var frame = FromRadio()
            frame.rebooted = true
            h.radio.device.injectFrame(frame)
            let (_, matched) = await collect(events) {
                if case .rebooted(true)? = $0.frameValue?.payloadVariant { return true }
                return false
            }
            #expect(matched)
        }

        @Test func steadyStateConfigFrameDoesNotReemitConfigured() async {
            let h = await makeSessionHarness()
            await h.session.connect(radio: h.radio.id)
            let events = h.session.events()
            var lora = Config.LoRaConfig()
            lora.modemPreset = .longSlow
            var config = Config()
            config.lora = lora
            var frame = FromRadio()
            frame.config = config
            h.radio.device.injectFrame(frame)
            h.radio.device.injectIncomingPacket(portnum: .reticulumTunnelApp, payload: Data([1]), from: 0xB001, id: 5)
            let (seen, matched) = await collect(events) { $0.packetID == 5 }
            #expect(matched)
            #expect(!seen.contains(where: \.isConfigured))
        }

        @Test func routingAckEmitsRoutingOk() async throws {
            let h = await makeSessionHarness()
            await h.session.connect(radio: h.radio.id)
            let events = h.session.events()
            h.radio.device.injectFrame(try routingFrame(requestID: 77, reason: .none))
            let (seen, matched) = await collect(events) { $0.isRouting }
            #expect(matched)
            #expect(seen.last == .routing(packetID: 77, ok: true))
        }

        @Test func routingErrorEmitsRoutingNotOk() async throws {
            let h = await makeSessionHarness()
            await h.session.connect(radio: h.radio.id)
            let events = h.session.events()
            h.radio.device.injectFrame(try routingFrame(requestID: 78, reason: .noRoute))
            let (seen, _) = await collect(events) { $0.isRouting }
            #expect(seen.last == .routing(packetID: 78, ok: false))
        }

        @Test func encryptedPacketEmitsFrameButNoPacket() async {
            let h = await makeSessionHarness()
            await h.session.connect(radio: h.radio.id)
            let events = h.session.events()
            var encrypted = MeshPacket()
            encrypted.from = 0xB003
            encrypted.id = 0xE1
            encrypted.encrypted = Data([0xDE, 0xAD])
            var frame = FromRadio()
            frame.packet = encrypted
            h.radio.device.injectFrame(frame)
            h.radio.device.injectIncomingPacket(portnum: .reticulumTunnelApp, payload: Data([1]), from: 0xB001, id: 0xE2)
            let (seen, matched) = await collect(events) { $0.packetID == 0xE2 }
            #expect(matched)
            #expect(seen.compactMap(\.packetID) == [0xE2])
            #expect(seen.contains { event in
                if case .packet(let p)? = event.frameValue?.payloadVariant { return p.id == 0xE1 }
                return false
            })
        }

        @Test func negativePortnumIsDroppedAndTheDrainContinues() async {
            let h = await makeSessionHarness()
            await h.session.connect(radio: h.radio.id)
            let events = h.session.events()
            var data = DataMessage()
            data.portnum = .UNRECOGNIZED(-1)
            data.payload = Data([1])
            var bad = MeshPacket()
            bad.from = 0xB004
            bad.id = 0xBAD
            bad.decoded = data
            var frame = FromRadio()
            frame.packet = bad
            h.radio.device.injectFrame(frame)
            h.radio.device.injectIncomingPacket(portnum: .reticulumTunnelApp, payload: Data([2]), from: 0xB001, id: 0x600D)
            let (seen, matched) = await collect(events) { $0.packetID == 0x600D }
            #expect(matched)
            #expect(seen.compactMap(\.packetID) == [0x600D])
        }

        @Test func garbageFrameIsSkippedAndTheDrainContinues() async {
            let h = await makeSessionHarness()
            await h.session.connect(radio: h.radio.id)
            let events = h.session.events()
            // Truncated varint: not a FromRadio. Queued WITHOUT a FromNum so the good
            // packet's notify drains both in ONE drain — the garbage must not end it.
            h.radio.device.injectRawFrame(Data([0xFF, 0xFF, 0xFF]), notify: false)
            h.radio.device.injectIncomingPacket(portnum: .reticulumTunnelApp, payload: Data([3]), from: 0xB001, id: 0x600E)
            let (_, matched) = await collect(events) { $0.packetID == 0x600E }
            #expect(matched)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter SessionReceiveTests`
Expected: FAIL. No `.packet`/`.routing` is emitted yet, so `incomingPort76…`, `frameForAPacket…`, `steadyState…`, both routing tests, `encrypted…`, `negativePortnum…` and `garbage…` fail by bounded timeout. `nonPacketFrameIsEmittedAsFrame` already PASSES. That is expected: it pins Task 3's unfiltered `.frame`. It is still mutation-checked in Step 5.

- [ ] **Step 3: Implement.** In `MeshtasticSession.swift`, replace `process(_:)` with this and add `emitPacketEvents(_:)` below it:

```swift
    /// Every decoded frame goes out as `.frame` first; derived events follow.
    private func process(_ frame: FromRadio) {
        emit(.frame(frame))
        switch frame.payloadVariant {
        case .myInfo(let info)?:
            myNodeNum = info.myNodeNum
        case .config(let config)?:
            if case .lora(let lora)? = config.payloadVariant {
                modemPreset = lora.modemPreset.rawValue
            }
        case .packet(let packet)?:
            emitPacketEvents(packet)
        default:
            break
        }
    }

    /// `.packet` for any decoded port; encrypted packets (no `.decoded`) are not
    /// emitted. A negative wire portnum (`PortNum.UNRECOGNIZED(-1)`) is dropped —
    /// `UInt32(_:)` would trap on it. ROUTING_APP also yields `.routing`.
    private func emitPacketEvents(_ packet: MeshPacket) {
        guard case .decoded(let data)? = packet.payloadVariant,
              let portnum = UInt32(exactly: data.portnum.rawValue) else { return }
        emit(.packet(from: packet.from, to: packet.to, channel: packet.channel,
                     portnum: portnum, payload: data.payload, id: packet.id))
        if data.portnum == .routingApp, let routing = try? Routing(serializedBytes: data.payload) {
            emit(.routing(packetID: data.requestID, ok: routing.errorReason == .none))
        }
    }
```

- [ ] **Step 4: Run and verify all pass (step a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter SessionReceiveTests`
Expected: `Test run with 9 tests passed`.

- [ ] **Step 5: Mutate in one batch (step b)**, in `MeshtasticSession.swift`:
- In `emitPacketEvents`, swap the fields: `from: packet.to, to: packet.from` (breaks `incomingPort76…`).
- Change `let portnum = UInt32(exactly: data.portnum.rawValue)` to `let portnum = Optional(UInt32(truncatingIfNeeded: data.portnum.rawValue))`. The negative-port packet is then emitted with portnum 0xFFFFFFFF, which breaks `negativePortnum…`.
- Change `guard case .decoded(let data)? = packet.payloadVariant,` to `guard case let data = packet.decoded,`. The encrypted packet is then emitted with portnum 0, which breaks `encrypted…`.
- Change `ok: routing.errorReason == .none` to `ok: routing.errorReason != .none` (breaks both routing tests).
- In `process(_:)`, delete `emit(.frame(frame))`. This breaks `frameForAPacket…`, `nonPacketFrameIsEmittedAsFrame`, and the `.frame` clause of `encrypted…`.
- In `process(_:)`'s `.config` arm, add `emit(.configured(myNodeNum: myNodeNum ?? 0, modemPreset: modemPreset))` after the assignment (breaks `steadyState…`).
- In `drainSteady`, change the malformed-frame `continue` to `return` (breaks `garbage…`).

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter SessionReceiveTests`
Expected: all 9 tests FAIL.

- [ ] **Step 6: Revert every mutation and re-run (step c)**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter SessionReceiveTests`
Expected: `Test run with 9 tests passed`.
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit`
Expected: 31 tests passed.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/commit-msg.txt`:
```
feat: MeshtasticSession emits packet and routing events for every port

Negative portnums, encrypted packets and malformed frames are dropped without
ending the drain.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit add Sources/MeshtasticKit/MeshtasticSession.swift Tests/MeshtasticKitTests/SessionReceiveTests.swift`
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit commit -F /tmp/ReTiCA/commit-msg.txt`
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit log -1 --format='%(trailers:key=Claude-Session)'`
Expected: the session URL.

---

### Task 5: Send — any port, 233-byte limit, serialised writes

**Files:**
- Modify: `/Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshtasticKit/MeshtasticSession.swift` (add `send(_:)`, write slot, wrap `writeToRadio`)
- Test: `/Users/ell/development/ios/pods/MeshtasticKit/Tests/MeshtasticKitTests/SessionSendTests.swift`

**Interfaces:**
- Consumes: Task 3/4 session; Task 2 `receivedPackets`, `ackBehavior`.
- Produces: `public func send(_ p: MeshtasticOutbound) async throws -> UInt32`. It throws `MeshtasticSessionError.payloadTooLarge` (count > 233, nothing written) or `.notConnected` (state ≠ `.connected`). A generated id of 0 is remapped to 1. All ToRadio writes, including want_config, go through one FIFO slot.

- [ ] **Step 1: Write the failing tests** `Tests/MeshtasticKitTests/SessionSendTests.swift`

```swift
import ComposableArchitecture
@preconcurrency import CoreBluetoothMock
import FCBComposable
import Foundation
import MeshProto
import MeshtasticKit
import MeshtasticMock
import Testing

struct SessionSendPreconditionTests {
    @Test func sendBeforeConnectThrowsNotConnected() async {
        let session = MeshtasticSession(central: .testValue)
        await #expect(throws: MeshtasticSessionError.notConnected) {
            _ = try await session.send(MeshtasticOutbound(portnum: 76, payload: Data([1])))
        }
    }
}

extension CBMBackedTests {
    @Suite @MainActor
    struct SessionSendTests {
        @Test func sendEncodesEveryOutboundField() async throws {
            let h = await makeSessionHarness()
            await h.session.connect(radio: h.radio.id)
            let payload = Data(repeating: 0xAB, count: 233)
            let id = try await h.session.send(MeshtasticOutbound(portnum: 76, payload: payload, to: 0x1234_5678,
                                                                 channel: 2, wantAck: true, hopLimit: 3))
            let sent = try #require(h.radio.device.receivedPackets.last)
            #expect(sent.id == id)
            #expect(sent.to == 0x1234_5678)
            #expect(sent.channel == 2)
            #expect(sent.wantAck == true)
            #expect(sent.hopLimit == 3)
            #expect(sent.decoded.portnum == .reticulumTunnelApp)
            #expect(sent.decoded.payload == payload)
        }

        @Test func nilHopLimitLeavesTheFieldUnsetForTheFirmwareDefault() async throws {
            let h = await makeSessionHarness()
            await h.session.connect(radio: h.radio.id)
            _ = try await h.session.send(MeshtasticOutbound(portnum: 76, payload: Data([1])))
            let sent = try #require(h.radio.device.receivedPackets.last)
            #expect(sent.hopLimit == 0)
            #expect(sent.wantAck == false)
            #expect(sent.to == 0xFFFF_FFFF)
        }

        @Test func payloadOf234BytesThrowsAndWritesNothing() async {
            let h = await makeSessionHarness()
            await h.session.connect(radio: h.radio.id)
            await #expect(throws: MeshtasticSessionError.payloadTooLarge) {
                _ = try await h.session.send(MeshtasticOutbound(portnum: 76, payload: Data(count: 234)))
            }
            #expect(h.radio.device.receivedPackets.isEmpty)
        }

        @Test func sendAfterDisconnectThrowsNotConnected() async {
            let h = await makeSessionHarness()
            await h.session.connect(radio: h.radio.id)
            await h.session.disconnect()
            await #expect(throws: MeshtasticSessionError.notConnected) {
                _ = try await h.session.send(MeshtasticOutbound(portnum: 76, payload: Data([1])))
            }
        }

        @Test func generatedPacketIDZeroIsSentAsOne() async throws {
            let h = await makeSessionHarness(packetID: { 0 })
            await h.session.connect(radio: h.radio.id)
            let id = try await h.session.send(MeshtasticOutbound(portnum: 76, payload: Data([1])))
            #expect(id == 1)
            #expect(h.radio.device.receivedPackets.last?.id == 1)
        }

        @Test func port76SendIsAckedAsRoutingOk() async throws {
            let h = await makeSessionHarness()
            await h.session.connect(radio: h.radio.id)
            let events = h.session.events()
            let id = try await h.session.send(MeshtasticOutbound(portnum: 76, payload: Data([1])))
            let (seen, matched) = await collect(events) { $0.isRouting }
            #expect(matched)
            #expect(seen.last == .routing(packetID: id, ok: true))
        }

        @Test func nakedSendArrivesAsRoutingNotOk() async throws {
            let h = await makeSessionHarness()
            h.radio.device.ackBehavior = .nak(.noRoute)
            await h.session.connect(radio: h.radio.id)
            let events = h.session.events()
            let id = try await h.session.send(MeshtasticOutbound(portnum: 76, payload: Data([1])))
            let (seen, _) = await collect(events) { $0.isRouting }
            #expect(seen.last == .routing(packetID: id, ok: false))
        }

        /// FCB keeps ONE pending-write continuation per characteristic and
        /// overwrites it (BluetoothCentralClient+Live.swift:322-334): unserialised,
        /// concurrent sends leak all but the last. Unstructured tasks + polling so
        /// a hung send fails this test instead of hanging it.
        @Test func concurrentSendsAllCompleteWithDistinctIDs() async {
            let h = await makeSessionHarness()
            await h.session.connect(radio: h.radio.id)
            let results = LockIsolated<[UInt32]>([])
            for i in 0..<5 {
                Task { [session = h.session] in
                    if let id = try? await session.send(MeshtasticOutbound(portnum: 76, payload: Data([UInt8(i)]))) {
                        results.withValue { $0.append(id) }
                    }
                }
            }
            let allDone = await waitUntil(timeout: .seconds(5)) { results.value.count == 5 }
            #expect(allDone)
            #expect(Set(results.value).count == 5)
            #expect(h.radio.device.receivedPackets.count == 5)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter "SessionSendPreconditionTests|SessionSendTests"`
Expected: compile FAILURE `value of type 'MeshtasticSession' has no member 'send'`.

- [ ] **Step 3: Implement.** In `MeshtasticSession.swift`, add these stored properties under `fromNumTask`:

```swift
    /// FIFO slot for ToRadio writes: FCB holds one pending write per characteristic
    /// and overwrites it, so two in-flight writes would leak the first.
    private var writeInFlight = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
```

Replace `writeToRadio(_:radio:)` with:

```swift
    private func writeToRadio(_ bytes: Data, radio: UUID) async throws {
        await acquireWriteSlot()
        defer { releaseWriteSlot() }
        try await central.writeValue(bytes, radio, MeshGATT.toRadioUUID, .withResponse)
    }

    private func acquireWriteSlot() async {
        if writeInFlight {
            await withCheckedContinuation { writeWaiters.append($0) }
        } else {
            writeInFlight = true
        }
    }

    /// Hands the slot straight to the next waiter (it stays `writeInFlight`).
    private func releaseWriteSlot() {
        if writeWaiters.isEmpty {
            writeInFlight = false
        } else {
            writeWaiters.removeFirst().resume()
        }
    }
```

Add a new `// MARK: - Send` section after `disconnect()`:

```swift
    // MARK: - Send

    /// Writes one DataMessage on `p.portnum`. Returns the packet id whose routing
    /// result (if the radio sends one) arrives later as `.routing`.
    public func send(_ p: MeshtasticOutbound) async throws -> UInt32 {
        guard p.payload.count <= Self.maxPayloadLength else { throw MeshtasticSessionError.payloadTooLarge }
        guard connectionState == .connected, let radio = radioID else { throw MeshtasticSessionError.notConnected }
        var id = packetID()
        if id == 0 { id = 1 }
        var data = DataMessage()
        data.portnum = PortNum(rawValue: Int(p.portnum)) ?? .unknownApp
        data.payload = p.payload
        var packet = MeshPacket()
        packet.to = p.to
        packet.channel = p.channel
        packet.id = id
        packet.wantAck = p.wantAck
        if let hopLimit = p.hopLimit { packet.hopLimit = hopLimit }
        packet.decoded = data
        var toRadio = ToRadio()
        toRadio.packet = packet
        try await writeToRadio(try toRadio.serializedData(), radio: radio)
        return id
    }
```

- [ ] **Step 4: Run and verify all pass (step a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter "SessionSendPreconditionTests|SessionSendTests"`
Expected: `Test run with 9 tests passed`.

- [ ] **Step 5: Mutate in one batch (step b)**

In `MeshtasticSession.send`:
- change `<= Self.maxPayloadLength` to `<= Self.maxPayloadLength + 1` (breaks the 234-byte test)
- change `throw MeshtasticSessionError.notConnected` to `throw MeshtasticSessionError.payloadTooLarge` (breaks both notConnected tests)
- delete `if id == 0 { id = 1 }` (breaks the zero-id test)
- change `packet.wantAck = p.wantAck` to `packet.wantAck = false`, and `packet.channel = p.channel` to `packet.channel = 0`. This breaks `sendEncodesEveryOutboundField`.
- change `if let hopLimit = p.hopLimit { packet.hopLimit = hopLimit }` to `packet.hopLimit = p.hopLimit ?? 7`. This breaks `nilHopLimit…`.

In `writeToRadio`:
- delete the `await acquireWriteSlot()` and `defer { releaseWriteSlot() }` lines (breaks the concurrency test).

In `MeshtasticMock/MockMeshtasticDevice.swift`:
- in the `.packet` branch, change `guard case .decoded(let sentData)? = sent.payloadVariant else` to `guard case .decoded(let sentData)? = sent.payloadVariant, sentData.portnum == .textMessageApp else`. This restores the old text-only ACK and breaks both routing tests.

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter "SessionSendPreconditionTests|SessionSendTests"`
Expected: all 9 tests FAIL. If `concurrentSendsAllCompleteWithDistinctIDs` still passes, CBM completed each write before the next was issued. STOP and diagnose: log the FCB `pendingWrites` overwrite, and do not weaken the test.

- [ ] **Step 6: Revert every mutation and re-run (step c)**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter "SessionSendPreconditionTests|SessionSendTests"`
Expected: `Test run with 9 tests passed`.
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit`
Expected: 40 tests passed.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/commit-msg.txt`:
```
feat: MeshtasticSession sends on any port with a 233-byte limit and serialised writes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit add Sources/MeshtasticKit/MeshtasticSession.swift Tests/MeshtasticKitTests/SessionSendTests.swift`
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit commit -F /tmp/ReTiCA/commit-msg.txt`
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit log -1 --format='%(trailers:key=Claude-Session)'`
Expected: the session URL.

---

### Task 6: Reconnect — per-peripheral watch, power-state watch, 1→30 s backoff, initial failure retries, epoch races, 30 s handshake timeout

**Files:**
- Modify: `/Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshtasticKit/MeshtasticSession.swift`
- Modify: `/Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshtasticMock/MockMeshtasticDevice.swift` (add `answersWantConfig`)
- Modify: `/Users/ell/development/ios/pods/MeshtasticKit/Tests/MeshtasticKitTests/Support/SessionSupport.swift` (add `SleepRecordingClock`, `AsyncGate`)
- Test: `/Users/ell/development/ios/pods/MeshtasticKit/Tests/MeshtasticKitTests/SessionReconnectTests.swift`

**Interfaces:**
- Consumes: Tasks 3–5.
- Produces:
  - After a completed handshake, the session watches FCB `events()` for `.didDisconnect` of ITS radio only, and for `.didUpdateState(≠ .poweredOn)`. Either triggers `.reconnecting(attempt: 1)`, then the backoff loop: sleep 1, 2, 4, 8, 16, 30, 30… s on the injected clock, then an attempt. A retryable failure emits `.reconnecting(attempt: n+1)`, a terminal one `.disconnected(reason:)`.
  - A non-terminal failure of `connect(radio:)`'s first attempt enters the same loop. `connect` returns after `.reconnecting(attempt: 1)` is emitted.
  - `.configured` is re-emitted after every reconnect handshake.
  - `MeshtasticSession.handshakeTimeout = .seconds(30)`. If `config_complete` has not arrived 30 s (injected clock) after `.configuring`, the session drops the BLE link. The handshake's pending read fails, the attempt fails retryable, and the caller enters backoff, exactly like a lost link.
  - `MockMeshtasticDevice.answersWantConfig: Bool` (default `true`). `false` ignores want_config, so the radio never sends `config_complete`.

- [ ] **Step 1: Add the test-support types** to the end of `Tests/MeshtasticKitTests/Support/SessionSupport.swift`

```swift
// MARK: Clocks and gates

/// Records every requested sleep and returns at once. `now` never advances, so a
/// `sleep(for: d)` arrives as a deadline offset of exactly `d`.
struct SleepRecordingClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    let sleeps = LockIsolated<[Duration]>([])
    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        sleeps.withValue { $0.append(deadline.offset) }
        await Task.yield()
    }
}

/// Suspends `wait()` callers until `open()`.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
```

- [ ] **Step 2: Write the failing tests** `Tests/MeshtasticKitTests/SessionReconnectTests.swift`

```swift
import ComposableArchitecture
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import FCBComposable
import Foundation
import MeshProto
import MeshtasticKit
import MeshtasticMock
import Testing

private func failingConnect(_ id: UUID) -> @Sendable () async throws -> Void {
    { throw BluetoothError.connectionFailed(peripheralID: id, underlying: nil) }
}

struct SessionBackoffTests {
    @Test func firstAttemptFailureEntersBackoffInsteadOfStopping() async {
        let id = UUID()
        let log = LockIsolated<[String]>([])
        let clock = TestClock()   // holds the loop in its first sleep
        let session = MeshtasticSession(central: fakeCentral(radio: id, log: log, connect: failingConnect(id)), clock: clock)
        let events = session.events()
        await session.connect(radio: id)
        let (seen, matched) = await collect(events, timeout: .seconds(2)) { $0.connectionState == .reconnecting(attempt: 1) }
        await session.disconnect()
        #expect(matched)
        #expect(seen.compactMap(\.connectionState) == [.disconnected(reason: nil), .connecting, .reconnecting(attempt: 1)])
    }

    @Test func backoffDoublesFromOneSecondAndCapsAtThirty() async {
        let id = UUID()
        let log = LockIsolated<[String]>([])
        let clock = SleepRecordingClock()
        let session = MeshtasticSession(central: fakeCentral(radio: id, log: log, connect: failingConnect(id)), clock: clock)
        await session.connect(radio: id)
        let reached = await waitUntil(timeout: .seconds(5)) { clock.sleeps.value.count >= 8 }
        await session.disconnect()
        #expect(reached)
        #expect(Array(clock.sleeps.value.prefix(8)) == [1, 2, 4, 8, 16, 30, 30, 30].map { Duration.seconds($0) })
    }

    @Test func reconnectingCountsAttemptsUpFromOne() async {
        let id = UUID()
        let log = LockIsolated<[String]>([])
        let session = MeshtasticSession(central: fakeCentral(radio: id, log: log, connect: failingConnect(id)),
                                        clock: SleepRecordingClock())
        let events = session.events()
        await session.connect(radio: id)
        let (seen, matched) = await collect(events) { $0.connectionState == .reconnecting(attempt: 3) }
        await session.disconnect()
        #expect(matched)
        let attempts = seen.compactMap { event -> Int? in
            if case .reconnecting(let n)? = event.connectionState { return n }
            return nil
        }
        #expect(attempts == [1, 2, 3])
    }

    @Test func attemptResolvingAfterDisconnectStaysDisconnected() async {
        let id = UUID()
        let log = LockIsolated<[String]>([])
        let gate = AsyncGate()
        let central = fakeCentral(radio: id, log: log, connect: {
            await gate.wait()
            throw BluetoothError.connectionFailed(peripheralID: id, underlying: nil)
        })
        let session = MeshtasticSession(central: central, clock: ImmediateClock())
        let connecting = Task { await session.connect(radio: id) }
        let started = await waitUntil { log.value.contains("connect") }
        #expect(started)
        await session.disconnect()
        let after = session.events()
        await gate.open()
        await connecting.value
        let (seen, _) = await collect(after, timeout: .milliseconds(500)) { _ in false }
        #expect(seen.compactMap(\.connectionState) == [.disconnected(reason: nil)])
    }
}

extension CBMBackedTests {
    @Suite @MainActor
    struct SessionReconnectTests {
        @Test func unexpectedDisconnectReconnectsViaRetrieveAndNeverScans() async {
            let h = await makeSessionHarness()
            await h.session.connect(radio: h.radio.id)
            h.log.setValue([])
            let events = h.session.events()
            h.radio.spec.simulateDisconnection()
            let (seen, matched) = await collect(events, timeout: .seconds(10)) { $0.isConfigured }
            #expect(matched)
            #expect(seen.contains { $0.connectionState == .reconnecting(attempt: 1) })
            #expect(h.log.value.contains("retrievePeripherals"))
            #expect(!h.log.value.contains("scan"))
        }

        @Test func reconnectReemitsConfiguredWithTheRadiosCurrentPreset() async {
            let h = await makeSessionHarness(modemPreset: .shortFast)
            await h.session.connect(radio: h.radio.id)
            h.radio.device.modemPreset = .longFast
            let events = h.session.events()
            h.radio.spec.simulateDisconnection()
            let (seen, _) = await collect(events, timeout: .seconds(10)) { $0.isConfigured }
            #expect(seen.last == .configured(myNodeNum: MockMeshtasticDevice.selfNodeNum,
                                                                   modemPreset: Config.LoRaConfig.ModemPreset.longFast.rawValue))
        }

        @Test func anotherPeripheralsDisconnectIsIgnored() async throws {
            let otherID = UUID()
            let otherSpec = MockMeshtasticDevice().makeSpec(identifier: otherID)
            let h = await makeSessionHarness(extra: [otherSpec])
            await h.session.connect(radio: h.radio.id)
            _ = await h.radio.central.retrievePeripherals([otherID])
            _ = try await h.radio.central.connect(otherID, ConnectOptions?.none)
            let quiet = h.session.events()
            otherSpec.simulateDisconnection()
            let (seen, _) = await collect(quiet, timeout: .seconds(1)) { _ in false }
            #expect(!seen.contains { event in
                if case .reconnecting? = event.connectionState { return true }
                return false
            })
            // The watch is alive: our own radio's drop IS seen.
            let loud = h.session.events()
            h.radio.spec.simulateDisconnection()
            let (_, sawReconnect) = await collect(loud) { $0.connectionState == .reconnecting(attempt: 1) }
            #expect(sawReconnect)
        }

        @Test func disconnectDuringBackoffStaysDisconnected() async {
            let clock = TestClock()
            let h = await makeSessionHarness(clock: clock)
            await h.session.connect(radio: h.radio.id)
            let watching = h.session.events()
            h.radio.spec.simulateDisconnection()
            let (_, sawReconnecting) = await collect(watching) { $0.connectionState == .reconnecting(attempt: 1) }
            #expect(sawReconnecting)
            await h.session.disconnect()
            let later = h.session.events()
            for _ in 0..<20 {
                await clock.advance(by: .seconds(30))
                try? await Task.sleep(for: .milliseconds(100))
            }
            let (seen, _) = await collect(later, timeout: .milliseconds(200)) { _ in false }
            #expect(seen.compactMap(\.connectionState) == [.disconnected(reason: nil)])
        }

        /// iOS (and CBM, CBMCentralManagerMock.swift:80-104) report a power-off as a
        /// state change only — no didDisconnect. If this fails inside FCB (e.g. a
        /// stale pending read/notify slot after power-off), STOP and report: do not
        /// patch FCB in this lane.
        @Test func powerCycleWhileConnectedReconnectsAndReportsAdapter() async {
            let h = await makeSessionHarness()
            await h.session.connect(radio: h.radio.id)
            let off = h.session.events()
            CBMCentralManagerMock.simulatePowerOff()
            let (seenOff, sawUnavailable) = await collect(off) { $0.isAdapterUnavailable }
            #expect(sawUnavailable)
            #expect(seenOff.contains { $0.connectionState == .reconnecting(attempt: 1) })
            #expect(seenOff.filter(\.isAdapterUnavailable) == [.adapterUnavailable(.poweredOff)])
            let on = h.session.events()
            CBMCentralManagerMock.simulatePowerOn()
            let (_, reconfigured) = await collect(on, timeout: .seconds(10)) { $0.isConfigured }
            #expect(reconfigured)
        }

        /// A radio that never sends config_complete: still `.configuring` at 29.9 s on
        /// the TestClock, backing off by 30.1 s.
        @Test func handshakeWithoutConfigCompleteTimesOutAtThirtySecondsIntoBackoff() async {
            let clock = TestClock()
            let h = await makeSessionHarness(clock: clock)
            h.radio.device.answersWantConfig = false
            let events = h.session.events()
            let connecting = Task { await h.session.connect(radio: h.radio.id) }
            let (_, configuring) = await collect(events) { $0 == .connection(.configuring) }
            #expect(configuring)
            try? await Task.sleep(for: .milliseconds(100))   // let the timeout's sleep register on the TestClock
            await clock.advance(by: .milliseconds(29_900))
            try? await Task.sleep(for: .milliseconds(100))
            let (atDeadline, _) = await collect(h.session.events(), timeout: .seconds(1)) { _ in true }
            #expect(atDeadline.first == .connection(.configuring))
            let after = h.session.events()
            await clock.advance(by: .milliseconds(200))
            let (_, backedOff) = await collect(after) { $0 == .connection(.reconnecting(attempt: 1)) }
            #expect(backedOff)
            await h.session.disconnect()   // first: also ends a handshake that never timed out
            await connecting.value
        }
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter "SessionBackoffTests|SessionReconnectTests"`
Expected: FAIL. Before the implementation:
- every test fails except `attemptResolvingAfterDisconnectStaysDisconnected`, which PASSES already because Task 3's epoch guards exist (it is still mutation-checked in Step 6);
- `handshakeWithoutConfigComplete…` needs `answersWantConfig` to compile, so do Step 4 (g), the mock property, before this run. It then fails at runtime: with no timeout it never leaves `.configuring`, and the bounded `backedOff` collect fails.

- [ ] **Step 4: Implement.** In `MeshtasticSession.swift`, make these edits.

(a) Add stored properties under `fromNumTask`:
```swift
    private var disconnectWatchTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    static let maxBackoff: Duration = .seconds(30)
```

(b) In `connect(radio:)`, replace the `switch outcome { … }` block with:
```swift
        switch outcome {
        case .connected, .superseded:
            return
        case .terminal(let reason):
            radioID = nil
            setState(.disconnected(reason: reason))
        case .retryable(let reason):
            logger.error("connect attempt failed: \(reason)")
            scheduleReconnect(radio: radio, epoch: myEpoch)
        }
```

(c) In `tearDownLink()`, insert at the top:
```swift
        reconnectTask?.cancel()
        reconnectTask = nil
        disconnectWatchTask?.cancel()
        disconnectWatchTask = nil
```

(d) In `attemptConnect`, change the `try await waitForPoweredOn(epoch: myEpoch)` line into:
```swift
        try await waitForPoweredOn(epoch: myEpoch)
        // Subscribe now, so FCB's (asynchronous) registration is done long before
        // the handshake ends; a later subscription could miss an immediate drop.
        let linkEvents = central.events()
```
and change the last line `emit(.configured(myNodeNum: myNodeNum ?? 0, modemPreset: modemPreset))` into:
```swift
        emit(.configured(myNodeNum: myNodeNum ?? 0, modemPreset: modemPreset))
        startDisconnectWatch(radio: radio, epoch: myEpoch, events: linkEvents)
```

(e) Add a `// MARK: - Reconnect` section at the end of the actor:
```swift
    // MARK: - Reconnect

    /// FCB's `events()` is process-global: only THIS radio's didDisconnect counts.
    /// A non-poweredOn state counts too — iOS sends no didDisconnect on power-off.
    private func startDisconnectWatch(radio: UUID, epoch myEpoch: UInt64, events: AsyncStream<CentralEvent>) {
        disconnectWatchTask?.cancel()
        disconnectWatchTask = Task { [weak self] in
            for await event in events {
                switch event {
                case .didDisconnect(let peripheral, _) where peripheral.id == radio:
                    await self?.handleLinkLost(radio: radio, epoch: myEpoch)
                    return
                case .didUpdateState(let state) where state != .poweredOn:
                    await self?.handleLinkLost(radio: radio, epoch: myEpoch)
                    return
                default:
                    continue
                }
            }
        }
    }

    private func handleLinkLost(radio: UUID, epoch myEpoch: UInt64) {
        guard myEpoch == epoch, connectionState == .connected else { return }
        disconnectWatchTask = nil
        fromNumTask?.cancel()
        fromNumTask = nil
        scheduleReconnect(radio: radio, epoch: myEpoch)
    }

    private func scheduleReconnect(radio: UUID, epoch myEpoch: UInt64) {
        setState(.reconnecting(attempt: 1))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop(radio: radio, epoch: myEpoch)
        }
    }

    /// Capped exponential backoff — 1 s, 2 s, 4 s, 8 s, 16 s, then 30 s forever —
    /// on the injected clock, until an attempt connects, a terminal cause appears,
    /// or connect/disconnect bumps the epoch. Never scans: attempts retrieve.
    private func reconnectLoop(radio: UUID, epoch myEpoch: UInt64) async {
        var delay: Duration = .seconds(1)
        var attempt = 1
        while myEpoch == epoch {
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard myEpoch == epoch else { return }
            switch await runAttempt(radio: radio, epoch: myEpoch) {
            case .connected, .superseded:
                return
            case .terminal(let reason):
                radioID = nil
                setState(.disconnected(reason: reason))
                return
            case .retryable(let reason):
                logger.error("reconnect attempt \(attempt) failed: \(reason)")
                delay = min(delay * 2, Self.maxBackoff)
                attempt += 1
                setState(.reconnecting(attempt: attempt))
            }
        }
    }
```

(f) Handshake timeout. Add under `maxBackoff`:
```swift
    static let handshakeTimeout: Duration = .seconds(30)
```
In `attemptConnect`, replace
```swift
        setState(.configuring)
        do {
```
with
```swift
        setState(.configuring)
        let timeout = startHandshakeTimeout(radio: radio, epoch: myEpoch, generation: claimed)
        defer { timeout.cancel() }
        do {
```
and add to the `// MARK: - Reconnect` section:
```swift
    /// No config_complete within `handshakeTimeout` on the injected clock → drop the
    /// BLE link. The handshake's pending read then fails (FCB fails pending ops on
    /// didDisconnect), the attempt fails retryable, and the caller enters backoff —
    /// the same path as a lost link. Cancelled by `attemptConnect`'s defer when the
    /// handshake ends either way.
    private func startHandshakeTimeout(radio: UUID, epoch myEpoch: UInt64, generation: UInt64) -> Task<Void, Never> {
        let clock = self.clock
        return Task { [weak self] in
            do {
                try await clock.sleep(for: Self.handshakeTimeout)
            } catch {
                return
            }
            await self?.handshakeTimedOut(radio: radio, epoch: myEpoch, generation: generation)
        }
    }

    private func handshakeTimedOut(radio: UUID, epoch myEpoch: UInt64, generation: UInt64) async {
        guard myEpoch == epoch, connectionState == .configuring, drainGeneration == generation else { return }
        logger.error("want_config handshake timed out")
        try? await central.disconnect(radio)
    }
```

(g) In `Sources/MeshtasticMock/MockMeshtasticDevice.swift`:
- add `var answersWantConfig = true` to `Delegate.MutableState`;
- add the public accessor next to `ackBehavior`:
```swift
    /// `false`: want_config is ignored, so the radio never sends config_complete
    /// (exercises the session's handshake timeout).
    public var answersWantConfig: Bool {
        get { delegate.withState { $0.answersWantConfig } }
        set { delegate.withState { $0.answersWantConfig = newValue } }
    }
```
- at the top of the `case .wantConfigID(let nonce)?:` branch, add `guard withState({ $0.answersWantConfig }) else { break }`.

- [ ] **Step 5: Run and verify all pass (step a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter "SessionBackoffTests|SessionReconnectTests"`
Expected: `Test run with 10 tests passed`. If the power-cycle test fails, follow its doc comment: stop and report, with the FCB evidence.

- [ ] **Step 6: Mutate in one batch (step b)**, in `MeshtasticSession.swift`:
- `connect(radio:)`: in `.retryable`, replace `scheduleReconnect(radio: radio, epoch: myEpoch)` with `radioID = nil; setState(.disconnected(reason: reason))` (breaks `firstAttemptFailure…`).
- `reconnectLoop`: change `delay = min(delay * 2, Self.maxBackoff)` to `delay = min(delay * 3, .seconds(60))` (breaks `backoff…`). Delete `attempt += 1` (breaks `reconnectingCounts…`).
- `startDisconnectWatch`: delete `where peripheral.id == radio` (breaks `anotherPeripheral…`). Delete the whole `.didUpdateState` case (breaks `powerCycle…`).
- `attemptConnect`: move `emit(.configured(...))` so it only fires the first time. Add `private var hasConfigured = false`, and change the line to `if !hasConfigured { hasConfigured = true; emit(.configured(myNodeNum: myNodeNum ?? 0, modemPreset: modemPreset)) }`. This breaks `reconnectReemits…` and `unexpectedDisconnectReconnects…` (both wait for a second `.configured`).
- Stale-attempt and stay-disconnected guards. These are defence in depth, so remove ALL of them:
  - in `runAttempt`'s failure branch, replace the `guard myEpoch == epoch, !(error is CancellationError) else { return .superseded }` with `guard !(error is CancellationError) else { return .superseded }`, and the final `return myEpoch == epoch ? … : .superseded` with `return .retryable(String(describing: error))`;
  - in `connect(radio:)`, delete the `guard myEpoch == epoch else { return }` after `runAttempt`;
  - in `reconnectLoop`, change `while myEpoch == epoch` to `while true` and delete the post-sleep `guard`;
  - make `check(_:)` a no-op (`private func check(_ myEpoch: UInt64) throws {}`);
  - in `tearDownLink()`, delete `reconnectTask?.cancel()`.
  
  This breaks `attemptResolvingAfterDisconnect…` and `disconnectDuringBackoff…`.
- Handshake timeout, its own mutation: change `static let handshakeTimeout: Duration = .seconds(30)` to `.seconds(20)`. The session is then already `.reconnecting` at 29.9 s, which breaks `handshakeWithoutConfigComplete…` at its `atDeadline` check.

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter "SessionBackoffTests|SessionReconnectTests"`
Expected: all 10 tests FAIL. Some fail by bounded timeout.

- [ ] **Step 7: Revert every mutation and re-run (step c)**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter "SessionBackoffTests|SessionReconnectTests"`
Expected: `Test run with 10 tests passed`.
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit`
Expected: 50 tests passed. This includes the Task 3 tests, which must still pass because the epoch guards and terminal paths are unchanged.

- [ ] **Step 8: Commit**

Write `/tmp/ReTiCA/commit-msg.txt`:
```
feat: MeshtasticSession reconnects with 1-30 s backoff, per-peripheral and power-state watch

Initial connect failures retry too; stale attempts after disconnect emit nothing;
a want_config handshake without config_complete times out after 30 s into backoff.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit add Sources/MeshtasticKit/MeshtasticSession.swift Sources/MeshtasticMock/MockMeshtasticDevice.swift Tests/MeshtasticKitTests/Support/SessionSupport.swift Tests/MeshtasticKitTests/SessionReconnectTests.swift`
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit commit -F /tmp/ReTiCA/commit-msg.txt`
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit log -1 --format='%(trailers:key=Claude-Session)'`
Expected: the session URL.

---

### Task 7: MeshtasticScanner

**Files:**
- Create: `/Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshtasticKit/MeshtasticScanner.swift`
- Test: `/Users/ell/development/ios/pods/MeshtasticKit/Tests/MeshtasticKitTests/ScannerTests.swift`

**Interfaces:**
- Consumes: `MeshGATT`, `DiscoveredRadio` (Task 1).
- Produces: `public enum MeshtasticScanner { public static func scan(central: BluetoothCentralClient) -> AsyncStream<DiscoveredRadio> }`. It waits for `.poweredOn`, scans `[MeshGATT.serviceUUID]`, takes the name from the advertised local name or else the peripheral name, and ends the FCB scan when the consumer stops. Lane E wraps this as ReTiCAMsgr's live `RadioScanner`. Meshtastified does NOT use it: `SharedScanner` must run one combined Meshtastic+MeshCore scan.

- [ ] **Step 1: Write the failing tests** `Tests/MeshtasticKitTests/ScannerTests.swift`

```swift
import ComposableArchitecture
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import FCBComposable
import Foundation
import MeshtasticKit
import MeshtasticMock
import Testing

private func firstRadio(_ stream: AsyncStream<DiscoveredRadio>, timeout: Duration = .seconds(5)) async -> DiscoveredRadio? {
    await withTaskGroup(of: DiscoveredRadio?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

struct ScannerFakeCentralTests {
    @Test func scanFiltersOnTheMeshtasticServiceUUID() async {
        let captured = LockIsolated<[String]?>(nil)
        var central = BluetoothCentralClient.testValue
        central.state = { AsyncStream { $0.yield(.poweredOn) } }
        central.scan = { services, _ in
            captured.setValue(services?.map(\.uuidString))
            return AsyncStream { _ in }
        }
        let consumer = Task { for await _ in MeshtasticScanner.scan(central: central) {} }
        let scanned = await waitUntil { captured.value != nil }
        consumer.cancel()
        #expect(scanned)
        #expect(captured.value == [MeshGATT.serviceUUID.uuidString])
    }

    @Test func nameFallsBackToThePeripheralNameWhenNotAdvertised() async {
        let id = UUID()
        var central = BluetoothCentralClient.testValue
        central.state = { AsyncStream { $0.yield(.poweredOn) } }
        central.scan = { _, _ in
            AsyncStream { continuation in
                continuation.yield(DiscoveredPeripheral(
                    peripheral: Peripheral(id: id, name: "PeripheralName", state: .disconnected),
                    advertisementData: AdvertisementData(localName: nil, serviceUUIDs: [MeshGATT.serviceUUID]),
                    rssi: -70))
            }
        }
        let radio = await firstRadio(MeshtasticScanner.scan(central: central))
        #expect(radio == DiscoveredRadio(id: id, name: "PeripheralName", rssi: -70))
    }

    @Test func cancellingTheConsumerEndsTheUnderlyingScan() async {
        let started = LockIsolated(false)
        let terminated = LockIsolated(false)
        var central = BluetoothCentralClient.testValue
        central.state = { AsyncStream { $0.yield(.poweredOn) } }
        central.scan = { _, _ in
            started.setValue(true)
            return AsyncStream { continuation in
                continuation.onTermination = { _ in terminated.setValue(true) }
            }
        }
        let consumer = Task { for await _ in MeshtasticScanner.scan(central: central) {} }
        let didStart = await waitUntil { started.value }
        #expect(didStart)
        consumer.cancel()
        let ended = await waitUntil(timeout: .seconds(2)) { terminated.value }
        #expect(ended)
    }
}

extension CBMBackedTests {
    @Suite @MainActor
    struct ScannerTests {
        /// Live FCB client against CBM: a scan issued while powered off must wait —
        /// CoreBluetooth silently drops a scan issued before .poweredOn.
        @Test func scanWaitsForPoweredOnThenYieldsTheMockRadio() async {
            let radio = await makeMockRadio(initialState: .poweredOff)
            let stream = MeshtasticScanner.scan(central: radio.central)
            let found = await withTaskGroup(of: DiscoveredRadio?.self) { group in
                group.addTask { await firstRadio(stream, timeout: .seconds(5)) }
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(50))
                    CBMCentralManagerMock.simulatePowerOn()
                    return nil
                }
                var result: DiscoveredRadio?
                for await value in group where value != nil { result = value }
                return result
            }
            #expect(found?.id == radio.id)
            #expect(found?.name == "Meshtastic_MOCK")
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter "ScannerFakeCentralTests|ScannerTests"`
Expected: compile FAILURE `cannot find 'MeshtasticScanner' in scope`.

- [ ] **Step 3: Write `Sources/MeshtasticKit/MeshtasticScanner.swift`**

```swift
@preconcurrency import CoreBluetooth
import FCBComposable
import Foundation

public enum MeshtasticScanner {
    /// The only scanning entry point. Supersedes any other FCB scan in the process while iterated.
    /// Waits for `.poweredOn` (CoreBluetooth silently drops an earlier scan), filters on the
    /// Meshtastic service UUID, and ends the FCB scan when the consumer stops iterating.
    public static func scan(central: BluetoothCentralClient) -> AsyncStream<DiscoveredRadio> {
        AsyncStream { continuation in
            let task = Task {
                for await state in central.state() {
                    if Task.isCancelled { continuation.finish(); return }
                    if state == .poweredOn { break }
                }
                if Task.isCancelled { continuation.finish(); return }
                for await found in central.scan([MeshGATT.serviceUUID], ScanOptions?.none) {
                    continuation.yield(DiscoveredRadio(
                        id: found.peripheral.id,
                        name: found.advertisementData.localName ?? found.peripheral.name,
                        rssi: found.rssi
                    ))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

- [ ] **Step 4: Run and verify all pass (step a)**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter "ScannerFakeCentralTests|ScannerTests"`
Expected: `Test run with 4 tests passed`.

- [ ] **Step 5: Mutate in one batch (step b)**, in `MeshtasticScanner.swift`:
- delete the whole `for await state in central.state() { … }` loop (breaks the CBM test: the scan is dropped while off)
- change `central.scan([MeshGATT.serviceUUID], …)` to `central.scan(nil, …)` (breaks the filter test)
- change `found.advertisementData.localName ?? found.peripheral.name` to `found.advertisementData.localName` (breaks the name fallback)
- delete `continuation.onTermination = { _ in task.cancel() }` (breaks the cancellation test)

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter "ScannerFakeCentralTests|ScannerTests"`
Expected: all 4 tests FAIL.

- [ ] **Step 6: Revert every mutation and re-run (step c)**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit --filter "ScannerFakeCentralTests|ScannerTests"`
Expected: `Test run with 4 tests passed`.

- [ ] **Step 7: Full package suite + iOS / Catalyst builds**

Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit`
Expected: 54 tests passed.
Run: `bash /tmp/ReTiCA/xcbuild-meshtastickit.sh "generic/platform=iOS"`
Expected: `** BUILD SUCCEEDED **`
Run: `bash /tmp/ReTiCA/xcbuild-meshtastickit.sh "generic/platform=macOS,variant=Mac Catalyst"`
Expected: `** BUILD SUCCEEDED **`
(The script was written in Task 1, Step 12. If `/tmp/ReTiCA` was cleared, rewrite it from there.)

- [ ] **Step 8: Commit**

Write `/tmp/ReTiCA/commit-msg.txt`:
```
feat: MeshtasticScanner, the one scanning entry point

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit add Sources/MeshtasticKit/MeshtasticScanner.swift Tests/MeshtasticKitTests/ScannerTests.swift`
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit commit -F /tmp/ReTiCA/commit-msg.txt`
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit log -1 --format='%(trailers:key=Claude-Session)'`
Expected: the session URL.

---

### Task 8: Meshtastified worktree; move MeshProto, MeshGATT and the mock onto MeshtasticKit (behaviour-preserving)

**Files (all under `/Users/ell/development/ios/apps/Meshtastified-meshtastickit`):**
- Modify: `MeshtastifiedKit/Package.swift`
- Delete: `MeshtastifiedKit/Sources/MeshProto/` (whole directory)
- Delete: `MeshtastifiedKit/Sources/MeshDeviceClient/MeshGATT.swift`
- Delete: `MeshtastifiedKit/Sources/MeshDeviceClient/Mock/MockMeshtasticDevice.swift`
- Delete: `scripts/generate-protos.sh`
- Create: `MeshtastifiedKit/Sources/MeshDeviceClient/Exports.swift`
- Modify: `MeshtastifiedKit/Sources/MeshDeviceClient/MeshSessionActor.swift` (import only)
- Modify: `MeshtastifiedKit/Sources/MeshDeviceClient/MeshDeviceClient+Live.swift` (import only)
- Modify (test, import only): `MeshtastifiedKit/Tests/MeshDeviceClientTests/RouterDispatchTests.swift`

**Interfaces:**
- Consumes: MeshtasticKit products `MeshProto`, `MeshtasticKit` (`MeshGATT`), `MeshtasticMock` (`MockMeshtasticDevice`, now ACKing any port and serving a LoRa config).
- Produces:
  - `MeshDeviceClient` re-exports `MeshtasticMock`, so `import MeshDeviceClient` still reaches `MockMeshtasticDevice`. The app's simulator bootstrap (`MeshtastifiedApp.swift:15,106`) and every test need this, because the app enables MemberImportVisibility.
  - The old `MeshSessionActor` logic is unchanged in this task.

- [ ] **Step 1: Create the worktree**

Run: `git -C /Users/ell/development/ios/apps/Meshtastified worktree add /Users/ell/development/ios/apps/Meshtastified-meshtastickit -b meshtastickit`
Expected: `Preparing worktree (new branch 'meshtastickit')` … `HEAD is now at e9163ef …`. The worktree is a sibling of the app dir, so `../../../pods/FCB` and `../../../pods/MeshtasticKit` resolve (spec §6).

- [ ] **Step 2: Record the baseline**

Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshtastickit/MeshtastifiedKit`
Expected: all green. Note the exact total from `Test run with N tests passed` as **BASELINE** (prior plans recorded 255+). If it is not green before any change, STOP and report.

- [ ] **Step 3: Replace `MeshtastifiedKit/Package.swift`**

```swift
// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "MeshtastifiedKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MeshModels", targets: ["MeshModels"]),
        .library(name: "MeshDeviceClient", targets: ["MeshDeviceClient"]),
        .library(name: "AppFeature", targets: ["AppFeature"]),
        .library(name: "MeshWidgetCore", targets: ["MeshWidgetCore"]),
    ],
    dependencies: [
        .package(path: "../../../pods/FCB"),
        .package(path: "../../../pods/MeshtasticKit"),
        .package(url: "https://github.com/pointfreeco/swift-identified-collections", from: "1.1.0"),
        .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.0.0"),
        .package(url: "https://github.com/NordicSemiconductor/IOS-CoreBluetooth-Mock.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "MeshModels",
            dependencies: [
                .product(name: "MeshProto", package: "MeshtasticKit"),
                .product(name: "IdentifiedCollections", package: "swift-identified-collections"),
                .product(name: "Sharing", package: "swift-sharing"),
            ]
        ),
        .target(
            name: "MeshDeviceClient",
            dependencies: [
                "MeshModels",
                .product(name: "MeshProto", package: "MeshtasticKit"),
                .product(name: "MeshtasticKit", package: "MeshtasticKit"),
                .product(name: "MeshtasticMock", package: "MeshtasticKit"),
                .product(name: "FCBComposable", package: "FCB"),
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "CoreBluetoothMock", package: "IOS-CoreBluetooth-Mock"),
            ]
        ),
        .target(
            name: "AppFeature",
            dependencies: [
                "MeshDeviceClient",
                "MeshModels",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FCBComposable", package: "FCB"),
            ]
        ),
        .target(
            name: "MeshWidgetCore",
            dependencies: ["MeshModels"]
        ),
        .testTarget(
            name: "MeshModelsTests",
            dependencies: ["MeshModels", .product(name: "MeshProto", package: "MeshtasticKit")]
        ),
        .testTarget(
            name: "MeshWidgetCoreTests",
            dependencies: ["MeshWidgetCore", "MeshModels"]
        ),
        .testTarget(
            name: "MeshDeviceClientTests",
            dependencies: [
                "MeshDeviceClient",
                .product(name: "MeshProto", package: "MeshtasticKit"),
                .product(name: "MeshtasticKit", package: "MeshtasticKit"),
                .product(name: "MeshtasticMock", package: "MeshtasticKit"),
                .product(name: "CoreBluetoothMock", package: "IOS-CoreBluetooth-Mock"),
            ]
        ),
        .testTarget(
            name: "AppFeatureTests",
            dependencies: [
                "AppFeature",
                "MeshModels",
                "MeshDeviceClient",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FCBComposable", package: "FCB"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```
(The direct swift-protobuf dependency is gone: no target imports `SwiftProtobuf`, and MeshProto brings it in.)

- [ ] **Step 4: Delete the moved files**

Run: `git -C /Users/ell/development/ios/apps/Meshtastified-meshtastickit rm -r -q MeshtastifiedKit/Sources/MeshProto`
Run: `git -C /Users/ell/development/ios/apps/Meshtastified-meshtastickit rm -q MeshtastifiedKit/Sources/MeshDeviceClient/MeshGATT.swift MeshtastifiedKit/Sources/MeshDeviceClient/Mock/MockMeshtasticDevice.swift scripts/generate-protos.sh`

- [ ] **Step 5: Re-export the mock** — create `MeshtastifiedKit/Sources/MeshDeviceClient/Exports.swift`

```swift
// MockMeshtasticDevice moved to MeshtasticKit's MeshtasticMock product. Re-exported
// so the app's simulator bootstrap (which builds with MemberImportVisibility) and
// this package's tests keep reaching it through `import MeshDeviceClient`, as before.
@_exported import MeshtasticMock
```

- [ ] **Step 6: Add the `MeshtasticKit` imports** (for `MeshGATT`)

In `MeshtastifiedKit/Sources/MeshDeviceClient/MeshSessionActor.swift`, after `import MeshProto` (line 6), add `import MeshtasticKit`.
In `MeshtastifiedKit/Sources/MeshDeviceClient/MeshDeviceClient+Live.swift`, after `import MeshModels` (line 5), add `import MeshtasticKit`.
In `MeshtastifiedKit/Tests/MeshDeviceClientTests/RouterDispatchTests.swift`, after `import MeshModels` (line 6), add `import MeshtasticKit`.

- [ ] **Step 7: Run the whole suite (step a)**

Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshtastickit/MeshtastifiedKit`
Expected: `Test run with BASELINE tests passed`, the same count as Step 2. The integration tests now run against MeshtasticMock: its extra LoRa config frame is ignored by `MeshEvent.from` (`MeshEvent.swift:35-37`), and ACK-any-port is a superset of the old text-only ACK.

- [ ] **Step 8: Mutate in one batch (step b)**. This checks that the re-pointed tests exercise the moved code:
- In the worktree's `MeshtastifiedKit/Sources/MeshDeviceClient/MeshDeviceClient+Live.swift`, in `SharedScanner.dispatch`, change `serviceUUIDs.contains(MeshGATT.serviceUUID)` to `serviceUUIDs.contains(MeshCoreGATT.serviceUUID)`.
- In `/Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshtasticMock/MockMeshtasticDevice.swift`, in `routingReply`, change `ackData.requestID = sent.id` to `ackData.requestID = sent.id &+ 1`. A routing event still arrives, so the existing unbounded collectors return instead of hanging, but its id no longer matches.

Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshtastickit/MeshtastifiedKit --filter "RouterDispatchTests|IntegrationTests"`
Expected: FAIL in `nusScanDropsDeviceWithoutMeshCoreNamePrefix`, `sendTextGetsMatchingRoutingAck` and `dmSendGetsRoutingAck`: `routedID == sentID` fails.

- [ ] **Step 9: Revert both mutations and re-run (step c)**

Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit checkout -- Sources/MeshtasticMock/MockMeshtasticDevice.swift`
Revert the `SharedScanner.dispatch` edit by hand.
Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshtastickit/MeshtastifiedKit`
Expected: `Test run with BASELINE tests passed`.
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit status --short`
Expected: no output, so MeshtasticKit is clean.

- [ ] **Step 10: Build the app**

Run: `xcodebuild -project /Users/ell/development/ios/apps/Meshtastified-meshtastickit/Meshtastified.xcodeproj -scheme Meshtastified -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`. This proves the simulator `import MeshDeviceClient` path still finds `MockMeshtasticDevice` under MemberImportVisibility.

- [ ] **Step 11: Commit on the worktree branch**

Write `/tmp/ReTiCA/commit-msg.txt`:
```
refactor: MeshProto, MeshGATT and the mock radio now come from MeshtasticKit

MeshtastifiedKit depends on ../../../pods/MeshtasticKit; MeshDeviceClient
re-exports MeshtasticMock so `import MeshDeviceClient` still reaches the mock.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run: `git -C /Users/ell/development/ios/apps/Meshtastified-meshtastickit add MeshtastifiedKit/Package.swift MeshtastifiedKit/Sources/MeshDeviceClient/Exports.swift MeshtastifiedKit/Sources/MeshDeviceClient/MeshSessionActor.swift MeshtastifiedKit/Sources/MeshDeviceClient/MeshDeviceClient+Live.swift MeshtastifiedKit/Tests/MeshDeviceClientTests/RouterDispatchTests.swift`
Run: `git -C /Users/ell/development/ios/apps/Meshtastified-meshtastickit status --short`
Expected: the deletions from Step 4 and the five paths above are staged. Only untracked build artefacts (`.build/`, `.swiftpm/`, `Package.resolved`, `xcshareddata/`) remain unstaged. Do not add them.
Run: `git -C /Users/ell/development/ios/apps/Meshtastified-meshtastickit commit -F /tmp/ReTiCA/commit-msg.txt`
Run: `git -C /Users/ell/development/ios/apps/Meshtastified-meshtastickit log -1 --format='%(trailers:key=Claude-Session)'`
Expected: the session URL.

---

### Task 9: MeshEventMapper and MeshEventRelay (pure, not wired yet)

**Files (under `/Users/ell/development/ios/apps/Meshtastified-meshtastickit/MeshtastifiedKit`):**
- Create: `Sources/MeshDeviceClient/MeshEventMapper.swift`
- Create: `Sources/MeshDeviceClient/MeshEventRelay.swift`
- Test: `Tests/MeshDeviceClientTests/MeshEventMapperTests.swift`
- Test: `Tests/MeshDeviceClientTests/MeshEventRelayTests.swift`

**Interfaces:**
- Consumes: `MeshtasticEvent`, `MeshtasticConnectionState` (MeshtasticKit); `MeshEvent`, `MeshEvent.from(fromRadio:receivedAt:myID:)`, `MeshModels.ConnectionState` (MeshModels).
- Produces:
  ```swift
  struct MeshEventMapper {                 // internal
      private(set) var myID: MeshIdentity  // starts .meshtastic(0); updated from .myIdentity
      mutating func map(_ event: MeshtasticEvent, receivedAt: Date) -> MeshEvent?
      static func connectionState(_ state: MeshtasticConnectionState) -> MeshModels.ConnectionState
  }
  final class MeshEventRelay: Sendable {   // internal
      func subscribe() -> AsyncStream<MeshEvent>   // synchronous registration + replays last .connectionState
      func emit(_ event: MeshEvent)
  }
  ```
  Design decision (keep it): only `.connection` and `.frame` are mapped. Every FromRadio frame, including the packets behind `.packet`/`.routing`, arrives as `.frame`. Mapping the derived events too would double-deliver messages and routing results, and `.frame` keeps what they drop: `rxTime` for message dates (`Message.swift:45`) and the NAK reason string (`MeshEvent.swift:48`).

- [ ] **Step 1: Write the failing tests** `Tests/MeshDeviceClientTests/MeshEventMapperTests.swift`

```swift
import Foundation
import MeshModels
import MeshProto
import MeshtasticKit
import Testing
@testable import MeshDeviceClient

private let epoch = Date(timeIntervalSince1970: 0)

private func textFrame(from: UInt32, to: UInt32, text: String = "hi", id: UInt32 = 3) -> FromRadio {
    var data = DataMessage()
    data.portnum = .textMessageApp
    data.payload = Data(text.utf8)
    var packet = MeshPacket()
    packet.from = from
    packet.to = to
    packet.id = id
    packet.decoded = data
    var frame = FromRadio()
    frame.packet = packet
    return frame
}

struct MeshEventMapperTests {
@Test func connectionStatesMapOneToOneDroppingReasonAndAttempt() {
    var mapper = MeshEventMapper()
    #expect(mapper.map(.connection(.disconnected(reason: "radio not found")), receivedAt: epoch) == .connectionState(.disconnected))
    #expect(mapper.map(.connection(.connecting), receivedAt: epoch) == .connectionState(.connecting))
    #expect(mapper.map(.connection(.configuring), receivedAt: epoch) == .connectionState(.configuring))
    #expect(mapper.map(.connection(.connected), receivedAt: epoch) == .connectionState(.connected))
    #expect(mapper.map(.connection(.reconnecting(attempt: 4)), receivedAt: epoch) == .connectionState(.reconnecting))
}

@Test func broadcastTextFrameBecomesAPublicChannelMessage() {
    var mapper = MeshEventMapper()
    guard case .message(let message)? = mapper.map(.frame(textFrame(from: 0xB001, to: 0xFFFF_FFFF)), receivedAt: epoch) else {
        Issue.record("expected .message")
        return
    }
    #expect(message.text == "hi")
    #expect(message.from == .meshtastic(0xB001))
    #expect(message.conversation == .publicChannel(.meshtastic))
}

@Test func myInfoFrameSetsTheIdentityUsedToResolveDMPartners() {
    var mapper = MeshEventMapper()
    var my = MyNodeInfo()
    my.myNodeNum = 0xA0A0
    var info = FromRadio()
    info.myInfo = my
    #expect(mapper.map(.frame(info), receivedAt: epoch) == .myIdentity(.meshtastic(0xA0A0)))
    // Our own text to 0xB001 echoed back: with myID known, the DM partner is the recipient.
    guard case .message(let message)? = mapper.map(.frame(textFrame(from: 0xA0A0, to: 0xB001)), receivedAt: epoch) else {
        Issue.record("expected .message")
        return
    }
    #expect(message.conversation == .direct(.meshtastic(0xB001)))
}

@Test func routingFrameKeepsTheNakReason() throws {
    var routing = Routing()
    routing.errorReason = .noRoute
    var data = DataMessage()
    data.portnum = .routingApp
    data.requestID = 77
    data.payload = try routing.serializedData()
    var packet = MeshPacket()
    packet.decoded = data
    var frame = FromRadio()
    frame.packet = packet
    var mapper = MeshEventMapper()
    #expect(mapper.map(.frame(frame), receivedAt: epoch) == .routing(packetID: 77, result: .nak("noRoute")))
}

@Test func derivedEventsAreDroppedSoNothingIsDeliveredTwice() {
    var mapper = MeshEventMapper()
    #expect(mapper.map(.packet(from: 1, to: 2, channel: 0, portnum: 1, payload: Data("hi".utf8), id: 3), receivedAt: epoch) == nil)
    #expect(mapper.map(.routing(packetID: 3, ok: true), receivedAt: epoch) == nil)
    #expect(mapper.map(.configured(myNodeNum: 0xA0A0, modemPreset: 0), receivedAt: epoch) == nil)
    #expect(mapper.map(.adapterUnavailable(.poweredOff), receivedAt: epoch) == nil)
}
}
```

`Tests/MeshDeviceClientTests/MeshEventRelayTests.swift`:

```swift
import Foundation
import MeshModels
import Testing
@testable import MeshDeviceClient

private func first(_ count: Int, of stream: AsyncStream<MeshEvent>) async -> [MeshEvent] {
    await withTaskGroup(of: [MeshEvent].self) { group in
        group.addTask {
            var out: [MeshEvent] = []
            for await event in stream {
                out.append(event)
                if out.count == count { break }
            }
            return out
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return []
        }
        let result = await group.next() ?? []
        group.cancelAll()
        return result
    }
}

struct MeshEventRelayTests {
@Test func relayReplaysDisconnectedBeforeAnyEvent() async {
    let relay = MeshEventRelay()
    #expect(await first(1, of: relay.subscribe()) == [.connectionState(.disconnected)])
}

@Test func relayReplaysTheLastConnectionStateToLateSubscribers() async {
    let relay = MeshEventRelay()
    relay.emit(.connectionState(.connected))
    relay.emit(.deviceMetadata(firmwareVersion: "x"))
    #expect(await first(1, of: relay.subscribe()) == [.connectionState(.connected)])
}

@Test func relayFansOutToEverySubscriber() async {
    let relay = MeshEventRelay()
    let a = relay.subscribe()
    let b = relay.subscribe()
    relay.emit(.deviceMetadata(firmwareVersion: "2.5"))
    let expected: [MeshEvent] = [.connectionState(.disconnected), .deviceMetadata(firmwareVersion: "2.5")]
    #expect(await first(2, of: a) == expected)
    #expect(await first(2, of: b) == expected)
}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshtastickit/MeshtastifiedKit --filter "MeshEventMapperTests|MeshEventRelayTests"`
Expected: compile FAILURE `cannot find 'MeshEventMapper' in scope`.

- [ ] **Step 3: Write `Sources/MeshDeviceClient/MeshEventMapper.swift`**

```swift
import Foundation
import MeshModels
import MeshProto
import MeshtasticKit

/// Rebuilds Meshtastified's MeshEvent stream from MeshtasticKit events. Only
/// `.connection` and `.frame` are consumed: every FromRadio frame — including the
/// packets behind `.packet` / `.routing` — also arrives as `.frame`, so mapping the
/// derived events too would double-deliver messages and routing results; and
/// `.frame` keeps what they drop (rxTime for message dates, the NAK reason).
struct MeshEventMapper {
    private(set) var myID: MeshIdentity = .meshtastic(0)

    mutating func map(_ event: MeshtasticEvent, receivedAt: Date) -> MeshEvent? {
        switch event {
        case .connection(let state):
            return .connectionState(Self.connectionState(state))
        case .frame(let frame):
            guard let mapped = MeshEvent.from(fromRadio: frame, receivedAt: receivedAt, myID: myID) else { return nil }
            if case .myIdentity(let identity) = mapped { myID = identity }
            return mapped
        case .configured, .packet, .routing, .adapterUnavailable:
            return nil
        }
    }

    static func connectionState(_ state: MeshtasticConnectionState) -> MeshModels.ConnectionState {
        switch state {
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .configuring: .configuring
        case .connected: .connected
        case .reconnecting: .reconnecting
        }
    }
}
```

- [ ] **Step 4: Write `Sources/MeshDeviceClient/MeshEventRelay.swift`**

```swift
import Foundation
import MeshModels
import os

/// Fan-out behind `MeshSessionActor.eventStream()`: synchronous registration plus
/// replay of the last connection state (the RadioSession contract), so a
/// subscriber created before connect sees the whole handshake.
final class MeshEventRelay: Sendable {
    private struct State: Sendable {
        var continuations: [UUID: AsyncStream<MeshEvent>.Continuation] = [:]
        var lastConnection: MeshModels.ConnectionState = .disconnected
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func subscribe() -> AsyncStream<MeshEvent> {
        let token = UUID()
        return AsyncStream { continuation in
            state.withLock { s in
                s.continuations[token] = continuation
                continuation.yield(.connectionState(s.lastConnection))
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.state.withLock { $0.continuations.removeValue(forKey: token) }
            }
        }
    }

    func emit(_ event: MeshEvent) {
        state.withLock { s in
            if case .connectionState(let connection) = event { s.lastConnection = connection }
            for continuation in s.continuations.values { continuation.yield(event) }
        }
    }
}
```

- [ ] **Step 5: Run and verify all pass (step a)**

Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshtastickit/MeshtastifiedKit --filter "MeshEventMapperTests|MeshEventRelayTests"`
Expected: 8 tests passed.

- [ ] **Step 6: Mutate in one batch (step b)**

In `MeshEventMapper`:
- change `case .connected: .connected` to `case .connected: .connecting` (breaks `connectionStatesMap…`).
- delete `if case .myIdentity(let identity) = mapped { myID = identity }`. This breaks `myInfoFrameSets…`: the partner becomes 0xA0A0.
- add `if case .packet? = frame.payloadVariant { return nil }` as the first line of the `.frame` arm (breaks `broadcastTextFrame…` and `routingFrameKeeps…`).
- split `.routing` out of the drop list as `case .routing: return .routing(packetID: 0, result: .ack)` (breaks `derivedEventsAreDropped…`).

In `MeshEventRelay`:
- change `continuation.yield(.connectionState(s.lastConnection))` to `continuation.yield(.connectionState(.connecting))` (breaks all three relay tests).

Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshtastickit/MeshtastifiedKit --filter "MeshEventMapperTests|MeshEventRelayTests"`
Expected: all 8 tests FAIL.

- [ ] **Step 7: Revert every mutation and re-run (step c)**

Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshtastickit/MeshtastifiedKit --filter "MeshEventMapperTests|MeshEventRelayTests"`
Expected: 8 tests passed.
Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshtastickit/MeshtastifiedKit`
Expected: BASELINE + 8 passed.

- [ ] **Step 8: Commit**

Write `/tmp/ReTiCA/commit-msg.txt`:
```
feat: MeshEventMapper and MeshEventRelay map MeshtasticKit events onto MeshEvent

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run: `git -C /Users/ell/development/ios/apps/Meshtastified-meshtastickit add MeshtastifiedKit/Sources/MeshDeviceClient/MeshEventMapper.swift MeshtastifiedKit/Sources/MeshDeviceClient/MeshEventRelay.swift MeshtastifiedKit/Tests/MeshDeviceClientTests/MeshEventMapperTests.swift MeshtastifiedKit/Tests/MeshDeviceClientTests/MeshEventRelayTests.swift`
Run: `git -C /Users/ell/development/ios/apps/Meshtastified-meshtastickit commit -F /tmp/ReTiCA/commit-msg.txt`
Run: `git -C /Users/ell/development/ios/apps/Meshtastified-meshtastickit log -1 --format='%(trailers:key=Claude-Session)'`
Expected: the session URL.

---

### Task 10: `MeshSessionActor` becomes an adapter over `MeshtasticSession`

**Files (under `/Users/ell/development/ios/apps/Meshtastified-meshtastickit/MeshtastifiedKit`):**
- Modify (full rewrite): `Sources/MeshDeviceClient/MeshSessionActor.swift`
- Modify (test setup only, clock argument): `Tests/MeshDeviceClientTests/TestSupport.swift:120`, `Tests/MeshDeviceClientTests/IntegrationTests.swift:34,38`, `Tests/MeshDeviceClientTests/MeshCoreRouterTests.swift:37`
- Test: `Tests/MeshDeviceClientTests/MeshtasticAdapterTests.swift`

**Interfaces:**
- Consumes:
  - `MeshtasticSession` (Tasks 3–6), whose 30 s want_config timeout sleeps on the injected clock. An `ImmediateClock` therefore kills every handshake, so every `MeshSessionActor` that connects in a test must get a real `ContinuousClock` or a `TestClock`. Every connect emits `.connecting` first; the first attempt resolves to `.connected`, `.reconnecting(attempt: 1)` (still retrying) or `.disconnected(reason:)`.
  - `MeshEventMapper` and `MeshEventRelay` (Task 9).
  - `MockMeshtasticDevice.receivedPackets` (Task 2).
- Produces: the unchanged internal surface that `RadioRouter`, `MeshDeviceClient.make` and every existing test use:
  - `init(bluetooth:clock:nextPacketID:)`, `eventStream()`, `connectedDevices()`
  - `connect(id:) async throws`, which throws `MeshConnectError(reason:)` when the first attempt does not connect
  - `disconnect()`, `sendText(_:conversation:) async throws -> PacketID`
  - the `RadioSession` conformance
  
  `MeshSessionError.notConnected` is still thrown for a send while not connected.

- [ ] **Step 1: Write the failing tests** `Tests/MeshDeviceClientTests/MeshtasticAdapterTests.swift`

```swift
import ComposableArchitecture
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import FCBComposable
import Foundation
import MeshModels
import MeshProto
import Testing
@testable import MeshDeviceClient

@MainActor
private func makeAdapterHarness(id: UUID = UUID()) async -> (MeshDeviceClient, MockMeshtasticDevice, UUID) {
    CBMCentralManagerMock.tearDownSimulation()
    CBMCentralManagerMock.simulateInitialState(.poweredOn)
    let device = MockMeshtasticDevice(now: { Date(timeIntervalSince1970: 2_000_000_000) })
    CBMCentralManagerMock.simulatePeripherals([device.makeSpec(identifier: id)])
    let bluetooth = BluetoothCentralClient.mocked()
    for _ in 0..<200 {
        var iterator = bluetooth.state().makeAsyncIterator()
        if await iterator.next() == .poweredOn { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    let rngBox = LockIsolated(LCRNG(seed: 11))
    // Real clock: an ImmediateClock would fire MeshtasticSession's 30 s handshake timeout at once.
    let client = withDependencies {
        $0.bluetoothCentralClient = bluetooth
        $0.continuousClock = ContinuousClock()
    } operation: {
        MeshDeviceClient.make(actor: MeshSessionActor(
            bluetooth: bluetooth, clock: ContinuousClock(),
            nextPacketID: { rngBox.withValue { UInt32($0.next() & 0xFFFF_FFFF) | 1 } }
        ))
    }
    return (client, device, id)
}

extension CBMBackedTests {
    @Suite @MainActor
    struct MeshtasticAdapterTests {
        @Test func sendTextWritesTheTextPortWithWantAckToBroadcast() async throws {
            let (client, device, id) = await makeAdapterHarness()
            try await client.connect(id, .meshtastic)
            let sentID = try await client.sendText(text: "ping", conversation: .publicChannel(.meshtastic))
            let sent = try #require(device.receivedPackets.last)
            #expect(sent.id == sentID)
            #expect(sent.decoded.portnum == .textMessageApp)
            #expect(sent.decoded.payload == Data("ping".utf8))
            #expect(sent.wantAck == true)
            #expect(sent.to == 0xFFFF_FFFF)
            #expect(sent.channel == 0)
        }

        @Test func directSendAddressesTheNode() async throws {
            let (client, device, id) = await makeAdapterHarness()
            try await client.connect(id, .meshtastic)
            _ = try await client.sendText(text: "dm", conversation: .direct(.meshtastic(0xB004)))
            #expect(device.receivedPackets.last?.to == 0xB004)
        }

        @Test func sendTextLongerThan233BytesThrowsWithoutWriting() async throws {
            let (client, device, id) = await makeAdapterHarness()
            try await client.connect(id, .meshtastic)
            await #expect(throws: (any Error).self) {
                _ = try await client.sendText(text: String(repeating: "a", count: 234), conversation: .publicChannel(.meshtastic))
            }
            #expect(device.receivedPackets.isEmpty)
        }

        @Test func connectToAnUnknownRadioThrows() async {
            let (client, _, _) = await makeAdapterHarness()
            await #expect(throws: MeshConnectError.self) {
                try await client.connect(UUID(), .meshtastic)
            }
        }

        /// The pump's mapper is shared: a subscriber that attaches AFTER the
        /// handshake still resolves DMs against the radio's identity.
        @Test func lateSubscriberResolvesEchoedDMAgainstMyIdentity() async throws {
            let (client, device, id) = await makeAdapterHarness()
            try await client.connect(id, .meshtastic)
            try? await Task.sleep(nanoseconds: 200_000_000)   // let the pump map the handshake
            let events = client.events()
            device.injectIncomingText("echo", from: MockMeshtasticDevice.selfNodeNum, to: 0xB001)
            let message = await withTaskGroup(of: Message?.self) { group in
                group.addTask {
                    for await event in events {
                        if case .message(let m) = event { return m }
                    }
                    return nil
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            #expect(message?.conversation == .direct(.meshtastic(0xB001)))
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshtastickit/MeshtastifiedKit --filter MeshtasticAdapterTests`
Expected: compile FAILURE `cannot find type 'MeshConnectError' in scope`.

- [ ] **Step 3: Rewrite `Sources/MeshDeviceClient/MeshSessionActor.swift`**

```swift
import FCBComposable
import Foundation
import MeshModels
import MeshProto
import MeshtasticKit

enum MeshSessionError: Error, Equatable {
    case notConnected
}

/// `connect(id:)`'s first attempt did not reach `.connected`. Unless `reason`
/// names a terminal cause ("radio not found", "unauthorized", "unsupported"),
/// the underlying MeshtasticSession keeps retrying in the background — which is
/// what DeviceFeature's "Retrying in the background…" copy already promises.
struct MeshConnectError: Error, Equatable {
    let reason: String?
}

/// Meshtastified's Meshtastic RadioSession: a thin adapter over MeshtasticKit's
/// MeshtasticSession (handshake, drain, send, reconnect all live there). One
/// shared pump maps MeshtasticEvent → MeshEvent (so DM resolution uses the
/// radio's identity for every subscriber, early or late) into a replaying relay.
final actor MeshSessionActor {
    private let bluetooth: BluetoothCentralClient
    private let session: MeshtasticSession
    private nonisolated let relay: MeshEventRelay
    private let pump: Task<Void, Never>

    init(
        bluetooth: BluetoothCentralClient,
        clock: any Clock<Duration>,
        nextPacketID: @escaping @Sendable () -> PacketID
    ) {
        self.bluetooth = bluetooth
        let session = MeshtasticSession(central: bluetooth, clock: clock, packetID: nextPacketID)
        let relay = MeshEventRelay()
        let upstream = session.events()
        self.session = session
        self.relay = relay
        self.pump = Task {
            var mapper = MeshEventMapper()
            for await event in upstream {
                if let mapped = mapper.map(event, receivedAt: Date()) { relay.emit(mapped) }
            }
        }
    }

    deinit {
        pump.cancel()
    }

    // MARK: - Event stream

    /// Replays the current connection state; data events are NOT buffered for
    /// late subscribers (the RadioSession contract).
    nonisolated func eventStream() -> AsyncStream<MeshEvent> { relay.subscribe() }

    // MARK: - Connected devices retrieval

    /// Peripherals already connected to the system that advertise the Meshtastic
    /// service. Connected peripherals don't advertise, so a scan never shows them.
    func connectedDevices() async -> [DiscoveredDevice] {
        let peripherals = await bluetooth.retrieveConnected([MeshGATT.serviceUUID])
        return peripherals.map { DiscoveredDevice(id: $0.id, name: $0.name, rssi: nil) }
    }

    // MARK: - Connect

    /// Throws `MeshConnectError` when the first attempt does not connect. Keyed on
    /// MeshtasticSession's contract: every connect emits `.connecting` first, and
    /// `connect(radio:)` returns only after the first attempt's outcome is emitted;
    /// `events()` registers synchronously, so subscribing first cannot miss it.
    func connect(id: UUID) async throws {
        let watch = session.events()
        let outcome = Task { () -> Result<Void, MeshConnectError> in
            var sawConnecting = false
            for await event in watch {
                guard case .connection(let state) = event else { continue }
                switch state {
                case .connecting:
                    sawConnecting = true
                case .connected where sawConnecting:
                    return .success(())
                case .reconnecting where sawConnecting:
                    return .failure(MeshConnectError(reason: nil))
                case .disconnected(let reason) where sawConnecting:
                    return .failure(MeshConnectError(reason: reason))
                default:
                    continue
                }
            }
            return .failure(MeshConnectError(reason: nil))
        }
        await session.connect(radio: id)
        try await outcome.value.get()
    }

    func disconnect() async {
        await session.disconnect()
    }

    // MARK: - Send

    /// `.publicChannel(.meshtastic)` → broadcast (0xFFFFFFFF) on channel 0;
    /// `.direct(.meshtastic(n))` → node `n` on channel 0. A `.meshcore`
    /// conversation throws RadioMismatchError. Text over 233 UTF-8 bytes throws
    /// `MeshtasticSessionError.payloadTooLarge` before anything is written.
    func sendText(_ text: String, conversation: ConversationID) async throws -> PacketID {
        guard conversation.radioType == .meshtastic else {
            throw RadioMismatchError(expected: .meshtastic, got: conversation.radioType)
        }
        let to: UInt32
        switch conversation {
        case .publicChannel: to = 0xFFFF_FFFF
        case .direct(.meshtastic(let n)): to = n
        case .direct(.meshcore): throw RadioMismatchError(expected: .meshtastic, got: .meshcore)
        }
        let outbound = MeshtasticOutbound(
            portnum: UInt32(PortNum.textMessageApp.rawValue),
            payload: Data(text.utf8),
            to: to,
            channel: 0,
            wantAck: true
        )
        do {
            return try await session.send(outbound)
        } catch MeshtasticSessionError.notConnected {
            throw MeshSessionError.notConnected
        }
    }
}

// MARK: - RadioSession conformance

extension MeshSessionActor: RadioSession {
    nonisolated var radioType: RadioType { .meshtastic }
    nonisolated func events() -> AsyncStream<MeshEvent> { eventStream() }
}
```

- [ ] **Step 3b: Give the existing session tests a real clock.** These are setup-only edits; no assertion changes. An `ImmediateClock` would fire the 30 s handshake timeout instantly.
- `Tests/MeshDeviceClientTests/TestSupport.swift:120`: change `clock: any Clock<Duration> = ImmediateClock()` to `clock: any Clock<Duration> = ContinuousClock()`. Update the doc comment at `:113-115` to "real ContinuousClock by default (an ImmediateClock would fire MeshtasticSession's 30 s handshake timeout at once); pass a TestClock to hold reconnect backoff". `ReconnectTests.disconnectDuringReconnectStaysDisconnected` already passes a `TestClock` and is unaffected.
- `Tests/MeshDeviceClientTests/IntegrationTests.swift:34`: change `$0.continuousClock = ImmediateClock()` to `$0.continuousClock = ContinuousClock()`. At `:38`, change `clock: ImmediateClock(),` to `clock: ContinuousClock(),`.
- `Tests/MeshDeviceClientTests/MeshCoreRouterTests.swift:37`: change `MeshSessionActor(bluetooth: bt, clock: ImmediateClock(), nextPacketID: { 1 })` to `MeshSessionActor(bluetooth: bt, clock: ContinuousClock(), nextPacketID: { 1 })`. The MeshCore actor keeps its ImmediateClock.
- `ScanPoweredOnTests` never connects, so leave it alone.

Reconnect tests now wait 1 s of real backoff, which is inside their 5 s and 10 s caps.

- [ ] **Step 4: Run the new tests, then the whole suite (step a)**

Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshtastickit/MeshtastifiedKit --filter MeshtasticAdapterTests`
Expected: 5 tests passed.
Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshtastickit/MeshtastifiedKit`
Expected: BASELINE + 8 + 5 passed. After Step 3b's clock-only setup edits, the pre-existing tests run through the adapter with **no assertion changed**: `HandshakeTests`, `ReconnectTests`, `SendTextTests`, `IntegrationTests`, `RadioSessionTests`, `ConnectedDevicesTests`, `MeshCoreRouterTests`, `ScanPoweredOnTests`. If one fails, diagnose the adapter; do not edit the old assertion.

- [ ] **Step 5: Mutate in one batch (step b)**, in `MeshSessionActor.swift`:
- `wantAck: true` → `wantAck: false` (breaks `sendTextWritesTheTextPort…`)
- `case .direct(.meshtastic(let n)): to = n` → `to = 0xFFFF_FFFF` (breaks `directSendAddressesTheNode`)
- `payload: Data(text.utf8)` → `payload: Data(text.utf8.prefix(233))`. The 234-byte text is then truncated and written, which breaks `sendTextLongerThan233…`.
- `try await outcome.value.get()` → `_ = await outcome.value` (breaks `connectToAnUnknownRadioThrows`)
- in the pump, move `var mapper = MeshEventMapper()` inside the `for await` loop body, so the identity is forgotten between events. This breaks `lateSubscriberResolvesEchoedDM…`.

The clock-edited tests also need a check that they still exercise the session, so add these mutations in `/Users/ell/development/ios/pods/MeshtasticKit/Sources/MeshtasticKit/MeshtasticSession.swift`:
- delete `setState(.configuring)` in `attemptConnect` (breaks `HandshakeTests.connectRunsHandshakeAndEmitsConfigEvents`)
- change `var delay: Duration = .seconds(1)` in `reconnectLoop` to `.seconds(60)` (breaks `ReconnectTests.unexpectedDisconnectEmitsReconnectingThenRecovers` and `IntegrationTests.simulatedDisconnectEmitsReconnectingAndRecovers` by their caps)

Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshtastickit/MeshtastifiedKit --filter "MeshtasticAdapterTests|HandshakeTests|ReconnectTests|IntegrationTests"`
Expected: all 5 adapter tests FAIL, plus the three named clock-edited tests.

- [ ] **Step 6: Revert every mutation and re-run (step c)**

Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit checkout -- Sources/MeshtasticKit/MeshtasticSession.swift`
Revert the `MeshSessionActor.swift` edits by hand.
Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit status --short`
Expected: no output.
Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified-meshtastickit/MeshtastifiedKit`
Expected: BASELINE + 13 passed.

- [ ] **Step 7: Build the app**

Run: `xcodebuild -project /Users/ell/development/ios/apps/Meshtastified-meshtastickit/Meshtastified.xcodeproj -scheme Meshtastified -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

Write `/tmp/ReTiCA/commit-msg.txt`:
```
refactor: MeshSessionActor is an adapter over MeshtasticKit's MeshtasticSession

sendText wraps session.send on TEXT_MESSAGE_APP with wantAck; MeshEvents come
from MeshtasticEvent.connection/.frame through one shared mapper. Initial
connect failures now retry in the background (matching DeviceFeature's copy);
texts over 233 UTF-8 bytes throw before writing.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run: `git -C /Users/ell/development/ios/apps/Meshtastified-meshtastickit add MeshtastifiedKit/Sources/MeshDeviceClient/MeshSessionActor.swift MeshtastifiedKit/Tests/MeshDeviceClientTests/MeshtasticAdapterTests.swift MeshtastifiedKit/Tests/MeshDeviceClientTests/TestSupport.swift MeshtastifiedKit/Tests/MeshDeviceClientTests/IntegrationTests.swift MeshtastifiedKit/Tests/MeshDeviceClientTests/MeshCoreRouterTests.swift`
Run: `git -C /Users/ell/development/ios/apps/Meshtastified-meshtastickit commit -F /tmp/ReTiCA/commit-msg.txt`
Run: `git -C /Users/ell/development/ios/apps/Meshtastified-meshtastickit log -1 --format='%(trailers:key=Claude-Session)'`
Expected: the session URL.

---

### Task 11: Fast-forward Meshtastified main and verify there

**Files:** none changed. This task only merges and verifies.

**Interfaces:**
- Consumes: branch `meshtastickit` (Tasks 8–10); MeshtasticKit `main` (Tasks 1–7).
- Produces: Meshtastified `main` running on MeshtasticKit, green; the worktree removed.

- [ ] **Step 1: Confirm both repos are clean**

Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit status --short`
Expected: no output.
Run: `git -C /Users/ell/development/ios/apps/Meshtastified-meshtastickit status --short`
Expected: only untracked build artefacts (`??` lines for `.build/`, `.swiftpm/`, `Package.resolved`, `xcshareddata/`).

- [ ] **Step 2: Fast-forward main**

Run: `git -C /Users/ell/development/ios/apps/Meshtastified merge --ff-only meshtastickit`
Expected: `Fast-forward`, listing the Task 8–10 files. The main checkout's pre-existing local edit to `xcuserdata/…/xcschememanagement.plist` is untouched. If the merge refuses (main moved), STOP and report. Do not rebase or merge-commit without the user.

- [ ] **Step 3: Verify in the main checkout**

Run: `swift test --package-path /Users/ell/development/ios/apps/Meshtastified/MeshtastifiedKit`
Expected: BASELINE + 13 passed.
Run: `xcodebuild -project /Users/ell/development/ios/apps/Meshtastified/Meshtastified.xcodeproj -scheme Meshtastified -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`
Run: `swift test --package-path /Users/ell/development/ios/pods/MeshtasticKit`
Expected: 54 tests passed.

- [ ] **Step 4: Remove the worktree and branch**

Run: `git -C /Users/ell/development/ios/apps/Meshtastified worktree remove --force /Users/ell/development/ios/apps/Meshtastified-meshtastickit`
(`--force` only discards the untracked build artefacts confirmed in Step 1.)
Run: `git -C /Users/ell/development/ios/apps/Meshtastified branch -d meshtastickit`
Expected: `Deleted branch meshtastickit`.

- [ ] **Step 5: Verify the trailers on every lane-A commit**

Run: `git -C /Users/ell/development/ios/pods/MeshtasticKit log --format='%h %(trailers:key=Claude-Session,valueonly)'`
Expected: 7 lines, each ending with the session URL.
Run: `git -C /Users/ell/development/ios/apps/Meshtastified log -3 --format='%h %(trailers:key=Claude-Session,valueonly)'`
Expected: 3 lines, each ending with the session URL.

---

## Self-review (done while writing; recorded for the executor)

**Spec coverage (lane A):**

| Requirement | Where |
|---|---|
| New repo `pods/MeshtasticKit`, `git init` | Task 1 |
| Products MeshProto / MeshtasticKit / MeshtasticMock; iOS 17 / macOS 13 / macCatalyst 17 | Tasks 1–2, with iOS and Catalyst builds in Tasks 1 and 7 |
| macOS-14 API (`NSLock.withLock`) handled | Task 2 |
| Contract 1 types | Task 1 |
| `MeshtasticSession` | Tasks 3–6 |
| `MeshtasticScanner` | Task 7 |
| Connect via `retrievePeripherals`, never scan (incl. reconnect) | Task 3 `connectRetrievesThePeripheralFirstAndNeverScans`; Task 6 `unexpectedDisconnectReconnectsViaRetrieveAndNeverScans` |
| Filters FCB's global `events()` to its peripheral | Task 6 `anotherPeripheralsDisconnectIsIgnored` |
| Payload > 233 throws `.payloadTooLarge` | Task 5 |
| `.configured(myNodeNum:modemPreset:)` after every want_config | Task 3 (preset, nil preset); Task 6 (re-emitted with new preset); Task 4 (not re-emitted on steady config) |
| Every decoded `.packet`, any port, encrypted excluded; `.routing`; `.frame` unfiltered | Task 4 |
| Mock ACKs any port | Tasks 2, 5 |
| Backoff 1→30 s preserved | Task 6 `backoffDoubles…` |
| 30 s want_config timeout → backoff | Task 6 `handshakeWithoutConfigCompleteTimesOutAtThirtySecondsIntoBackoff` (TestClock: `.configuring` at 29.9 s, `.reconnecting(attempt: 1)` by 30.1 s; own mutation 30→20 s) |
| typed `.adapterUnavailable(MeshtasticAdapterUnavailable)` + `isTerminal` | Task 1 (`isTerminal`); Task 3 (powered off, unauthorized); Task 6 (power cycle) |
| `MeshtasticEvent: Equatable` | Task 1; tests assert events with `==` |
| §8 A: arbitrary-port send/receive | Tasks 4–5 |
| §8 A: `.configured` carrying the preset | Task 3 |
| §8 A: payload > 233 | Task 5 |
| §8 A: connect without scan | Tasks 3, 6 |
| §8 A: existing session/mock tests move with the code | ported into MeshtasticKit tests: handshake, reconnect, disconnect-during-backoff, send/ACK, scan-powered-on; the originals stay in Meshtastified and now run through the adapter |
| Meshtastified migration in a sibling worktree | Task 8 |
| MeshEvent mapping rebuilt on MeshtasticKit events | Task 9, on `.frame` + `.connection`; see the design decision there |
| `sendText` as a wrapper over `send(…TEXT_MESSAGE_APP, wantAck: true)` | Task 10 |
| MeshCore + RadioRouter stay | untouched |
| Suite green | Tasks 8, 10, 11 |
| Live boundary | the session, mock and scanner tests and the Meshtastified adapter tests run on `BluetoothCentralClient.mocked()`; fakes appear only where noted in Global Constraints |

**Type consistency checked:**
- `MeshtasticOutbound.init(portnum:payload:to:channel:wantAck:hopLimit:)`, `DiscoveredRadio.init(id:name:rssi:)`
- `MeshtasticSessionError.{payloadTooLarge,notConnected}`, `MeshtasticAdapterUnavailable.{poweredOff,unauthorized,unsupported,other}` / `.isTerminal`, `.adapterUnavailable(_:)`
- `MeshtasticSession.handshakeTimeout`, `startHandshakeTimeout(radio:epoch:generation:)`, `MockMeshtasticDevice.answersWantConfig`
- test predicates `isConfigured`, `packetID`, `isRouting`, `frameValue`, `isAdapterUnavailable` (no leftover `*Fields` structs; verified by grep)
- `MockMeshtasticDevice.{modemPreset, ackBehavior, receivedPackets, injectIncomingPacket(portnum:payload:from:to:channel:id:), injectFrame, injectRawFrame(_:notify:)}`
- `runAttempt(radio:epoch:)`, `AttemptOutcome`, `scheduleReconnect(radio:epoch:)`, `startDisconnectWatch(radio:epoch:events:)`
- `MeshEventMapper.map(_:receivedAt:)`, `MeshEventRelay.subscribe()/emit(_:)`, `MeshConnectError(reason:)`

The same names are used in every task that touches them.

**Running totals:**
- MeshtasticKit: 6 → 14 → 22 → 31 → 40 → 50 → 54.
- Meshtastified: BASELINE → +8 → +13.
