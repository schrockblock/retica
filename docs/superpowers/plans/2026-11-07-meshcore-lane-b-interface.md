# MeshCore Interface (Lane B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give ReTiCA a Reticulum-over-MeshCore interface in ScotMesh's Raw format: a byte-exact codec, a bounded reassembler, an announce and path-request limiter, a paced sender, a `MeshCoreDriver` contract (mock-driven; the live adapter is lane D's) and a `TransportEndpoint.meshCore` slot. Probes deliver LXMF between two endpoints over an in-memory channel, and between MeshCore and TCP through a relay.

**Architecture:** Pure value types (`ScotMeshRawCodec`, `MeshCoreReassembler`, `MeshCoreAnnounceLimiter`, `MeshCoreLinkPacing`) sit under a `MeshCoreInterface` TCA reducer in `ReTiCAInterfaces/MeshCore/`, which reaches the radio only through the `MeshCoreDriver` closure struct. `MeshCoreEndpoint` in `ReTiCANode` wraps it. `TransportEndpoint` gives it one `InterfaceID` per radio with the TCP-client lifecycle, runs the limiter on the unmasked packet in `transmit`, masks with IFAC, and drives shared maintenance off the shared interface count.

**Tech Stack:** Swift 6 language mode, swift-composable-architecture ≥ 1.15 (TestStore, TestClock, ImmediateClock), Swift Testing, Python in conda env `rns` for fixtures.

**Spec:** `docs/superpowers/specs/2026-11-07-meshcore-interface-design.md`: Contracts 2 and 3, §5, and the lane-B row of §8. The Meshtastic spec it inherits from is `docs/superpowers/specs/2026-10-16-meshtastic-interface-design.md` (stop semantics in its Contract 3, touch points in its §5.4). Executors read both.

## Contract issues

Neither changes a contract's meaning or blocks the lane. Both are recorded for the executor; the spec carries both.

1. **The limiter has an inbound half Contract 3 doesn't place.** Contract 3 says the limiter runs in `transmit`, but "answering a path request heard in the last 15 s" needs inbound observation, and inbound bytes are masked too. This plan observes in `TransportEndpoint`'s `.packetReceived` arm after the same IFAC gate `Transport` uses (`Transport.swift:558-565`). This follows "do not classify from the masked bytes"; it is flagged only because the contract names one location.
2. **Transport's own pacing sits upstream of the limiter (observation).** `Transport.announcePacingWait` with cap 0.02 at 473 bps gives a 183 B relayed announce (HEADER_2, no app data) a 154.8 s wait, at most 4 per 600 s. So the 6-per-10-minute relayed cap can't trip through Transport at any §5.4 bitrate, and a hop-capped announce still spends a pacing slot before the limiter drops it. Path responses aren't paced (`Transport.swift:834, 860`), so their cap of 12 can trip. Everything is built as specified; the aggregate caps are tested at limiter and endpoint level, and the end-to-end probe uses the hop cap and per-destination interval. Lane E retunes.

## Global Constraints

- **Worktree:** `WT` = `/Users/ell/development/ios/pods/ReTiCA-worktrees/meshcore-interface`, branch `feat/meshcore-interface`, which already exists. Commands here write `WT` for brevity; substitute the absolute path. Do not `cd`: use `--package-path` and `git -C`. **Baseline:** the commit that holds the spec and all four lane plans (Task 1's prerequisite); commands write it as `BASE`, recorded at Task 1 Step 0. Citations were read on 2026-11-07 at `67bc23d`; the baseline adds only `docs/` on top of it. If a cited line doesn't say what the plan claims, stop and report.
- **Branch only.** Commit to `feat/meshcore-interface`. No pushing, no merging (spec §6).
- **One shell command per Bash call and per line:** no `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, and no inline scripts (`python -c`, `bash -c`, heredocs into an interpreter). Scripts go in files. Pass several test filters as repeated `--filter`, not a regex alternation.
- **Temp files** go under `/tmp/ReTiCaMsgr/`.
- **Test verification, mandatory for every task with tests:**
  - (a) Run the task's suites; every test passes.
  - (b) Apply the task's mutations to production code **in one batch**, run the same suites once, and confirm every new test fails on its targeted assertion. Mutations listed in a task are the ones that need thought; every other new test gets the obvious one (delete the guard or change the constant its assertion pins) in the same batch. If a new test survives, the test is wrong or the batch is missing a mutation. Fix that and restart at (a).
  - **Boundary swap:** tests on either side of one limit can't both fail under a shifted constant. Mutate so that `limit − 1 ≤ elapsed < limit` behaves as past the limit and `elapsed == limit` as under it. Behaviour elsewhere is unchanged, so both fail in the same run and other tests aren't disturbed.
  - (b′) Trap-class tests (non-zero-based `Data` slices, arithmetic overflow) get one mutation at a time, each run alone with `--filter <testName>`, because a trap aborts the whole process and would mask the batch.
  - (c) Revert with the Edit tool, undoing exactly those edits, and run again; all pass. Never use `git checkout`, `git restore` or `git stash` on uncommitted work.
  - Commit only after (c).
- **Commits:** write the message to `/tmp/ReTiCaMsgr/commit-laneb-N.txt` with the Write tool, then `git -C WT commit -F <file>`. End it with the attribution lines the executing session's system-reminder gives.
- **Tests:** `swift test --package-path WT --filter <SuiteName>`; every new test is in a `@Suite struct` with the listed name. First build: timeout 600000 ms. A signal 11 or stale-link failure after large changes: `swift package clean --package-path WT`, then rerun.
- **Known baseline failure:** `nonImprovingFreshAnnounceIsStillRebroadcast` (`Tests/ReTiCATransportTests/TransportTests.swift:1501`) hits TCA's 1 s receive timeout under parallel load and passes alone. Full-suite runs use `--skip nonImprovingFreshAnnounceIsStillRebroadcast`, then run it alone once (Task 12). Don't chase it. New cross-store tests never rely on the default 1 s: pass `timeout:` on every `receive`, or poll.
- **File ownership (spec §6):** lane B owns `Sources/ReTiCAInterfaces/MeshCore/*`, `Sources/ReTiCANode/MeshCoreEndpoint.swift`, `Sources/ReTiCANode/TransportEndpoint.swift`, new tests and fixtures, and the `ReTiCAInterfacesTests` `resources:` line of `Package.swift`. No other `Package.swift` change: `ReTiCAMeshCoreLive` and the MeshCoreKit dependency are lane D's. No file in this plan imports MeshCoreKit.
- **Do not refactor or edit Meshtastic code** (spec §3). Reusing the existing internal `DriverEpoch` as is, is fine. `InterfaceProfile.swift` and `Transport.swift` aren't modified.
- **GPL:** the fixture generator may import ScotMesh's module at dev time from a pinned clone outside this repo. Unlike the Meshtastic lane, **nothing from ScotMesh is copied into the repo**: no `Vectors/` copy of the interface file, no pasted functions. Generated fixtures hold bytes only. No GPL code is linked.
- **Wire constants (§5.1):** magic `0x52`; header 14 B big-endian; low nibble 0 RNS fragment, 1 `BIND_REQ`, 2 `BIND`; bit 4 can-route; `payload_size` 148; max datagram 162; `dst` always zero when sending; parse nil if length < 14, bad magic, `frag_total == 0` or `frag_idx >= frag_total`.
- **Receive rules (§5.2), in order:** parse (fail: `malformed`); drop `src == selfPrefix`; drop and count `notAddressed` unless `dst` is zero or `selfPrefix`; type 1 schedules `BIND`, type 2 and others ignored; type 0 reassembles.
- **Discovery (§5.3):** reply after random 3–15 s, coalesced, at most one per 60 s, `dst = 0`, body = the 32-byte public key. Never send `BIND_REQ`, heartbeat or path appendix.
- **Sender (§5.4):** FIFO cap 64 datagrams, all-or-nothing per packet; stop-and-wait; `fragmentDelay = max(2.5 s, 2 × airtime(181 B))`, nil or out-of-range 5 s; `send` false counts `sendFailed`, drops it, waits one extra delay; no retransmits; `.disconnected` clears the queue and buffers and cancels the timer.
- **Limiter (§5.5):** see Task 4. **Reassembler (§5.6):** see Task 3.
- **Endpoint (Contract 3):** interface id `"meshcore:<uuid>"` via `uuid.uuidString`; profile name `"meshcore"`, `hwMTU` 500, `.tcp`'s default mode (`.full`), IFAC size 8. Live value message exactly `"ReTiCAMeshCoreLive not installed"`.
- **TCA rules in this repo:** `Effect.cancel(id:)` cancels at construction, so build it only inside the `return` of the arm that means it. Use `exhaustivity = .off`. Transport and LXMF timers in tests use a `TestClock`, advanced only when the test is about them. `.cancellable` registers its id only when the task starts, which is why `DriverEpoch` exists.
- **Test names** state one claim, which is what the assertions and mutation target. No "X and Y" names.
- **Helper names:** both test targets already have top-level `mesh*`/`Mesh*` helpers (`MeshMockCall`, `meshData(hex:)`, `makeMeshInterface`). Every new top-level helper is `private` or prefixed `meshCore`/`MeshCore`.

## Review Focus

1. **The phone's wall clock jumps backwards** (network time, manual change). The limiter uses a `Date`. A window computed as negative elapsed time must count as expired, or path requests stay silenced until the clock catches up. Pinned by `backwardsClockExpiresALimiterWindow` (Task 4) and `backwardsClockExpiresADedupeKey` (Task 3).
2. **A radio reports nonsense LoRa params** (`bw 0`, `SF 0`, `CR 0`, or a legal extreme). No divide by zero, and no `InterfaceProfile` `bitrate > 0` precondition trap. Pinned by `outOfRangeParamsUseFiveSeconds`, `everyValidParamCombinationHasAPositiveBitrate` (Task 1) and `profileForOutOfRangeParamsDoesNotTrap` (Task 8).
3. **A stranger without the IFAC key sends a path request.** It must not open the 15 s bypass, since the limiter's inbound hook runs before Transport's own IFAC gate. Pinned by `pathRequestFailingIFACDoesNotOpenTheBypass` (Task 9).
4. **The user toggles Relay while the radio is connected.** The header's can-route bit follows from the next packet, with no driver restart and no rewriting of queued datagrams. Pinned by `setCanRouteAffectsTheNextPacket`, `setCanRouteDoesNotRestartTheDriver` and `setCanRouteLeavesQueuedDatagramsAlone` (Task 7).
5. **The feature is turned off and `.stop` lands while `removeChannel` is still running.** The removal must finish, the driver sees `removeChannel` then `stop`, and offline comes last, so the host can't nil the slot under a running effect or spin answering a non-idle offline. Pinned by `stopDuringARemovalWaitsForTheRemovalToFinish` and `channelRemovedPrecedesOfflineWhenStoppedDuringARemoval` (Task 6).

## Decisions the spec leaves open

- **Where limiter state lives:** `MeshCoreInterface.State.limiter` (`public var`). `MeshCoreInterface`'s reducer never touches it. `TransportEndpoint` mutates it in `transmit` and in the `.packetReceived` arm. `transmit` changes from `_ state: State` to `_ state: inout State` so the mutation survives the call; its callers at lines 402 and 431 are already in an `inout` context. It survives `.disconnected`, `.stop` and reconnect, so a flapping BLE link can't refill the budgets; it dies with the slot and the process. Time comes from `@Dependency(\.meshCoreDate)` on `TransportEndpoint`, read once per packet. Tests advance a `LockIsolated<Date>`, and `TestClock` covers only pacing and the `BIND` timer.
- **Classification:** `Packet(raw:)` on the unmasked bytes. Unparseable: allowed, nothing counted. `.announce`: announce rules. `.data` + `.plain`: path request, literally per §5.5, keyed on `payload.prefix(16)`; this needs no control hash and covers both request forms at `Transport.swift:803`. Everything else: allowed.
- **Order of checks, announce:** (1) `hops > 2` and context ≠ `.pathResponse`: drop. (2) If not answering a request heard under 15 s ago and last allowed for this destination under 600 s ago: drop. (3) If `hops ≥ 1`: the path-response pool (12) or the announce pool (6), by context; full: drop. (4) Allow: stamp the destination, consume the heard entry, add to the pool. A drop stamps and consumes nothing. Consuming one heard entry per announce follows ScotMesh's `pop` (line 1532).
- **The cap of 12 covers relayed path responses only.** A hop-0 path response is one of "our own announces", which are exempt.
- **Order of checks, path request:** (1) Per-destination timing, per the table in Task 4: within 60 s of `first` passes; otherwise under 1800 s since `last` drops; at or past 1800 s a new burst starts. (2) Aggregate pool (6) full: drop, without creating or stamping the entry, so a request squeezed out by the aggregate doesn't start its 60 s burst. (3) Allow: stamp, add to the pool.
- **Out of range** means outside what firmware accepts (`MyMesh.cpp:1441-1442`): SF 5–12, CR 5–8, bandwidth 7000–500000 Hz.
- **Airtime:** the Semtech formula with low-data-rate optimise on when the symbol time is ≥ 16 ms, as Semtech defines it. §5.4 doesn't mention it and no table row is affected. CR is the denominator (5–8), used as `cr` directly in place of Semtech's `CR + 4`. Delay rounds up to whole milliseconds for the `Duration`; the bitrate uses the unrounded seconds.
- **Packet ID:** `nextPacketID: UInt16?`, drawn from `\.meshCoreRandom` at the first `.connected`, then kept across reconnects and stop/start so a key isn't reused inside a peer's 30 s dedupe. `BIND` consumes an ID, as ScotMesh's does (line 1165).
- **`BIND`:** goes through the same FIFO and pacing. The 60 s limit is measured from enqueue using `\.meshCoreDate`, and `lastBindSent` survives a drop. A pending reply is cancelled by `.disconnected` and `.stop`. The `BIND_REQ` body isn't validated: the reply is bounded by the 60 s limit whatever it says.
- **Reassembler:** an empty completed packet counts `malformed`. An empty fragment inside a non-empty packet is fine. `reset()` keeps counters and dedupe keys.
- **Removal:** `.removeChannel` while not online answers `.channelRemoved(false)` without calling the driver. `.stop` during a removal is held until it finishes, then runs normally.
- **`\.meshCoreRandom`** is a small extra dependency beside Contract 2's driver, because `\.withRandomNumberGenerator`'s test value fails on use and two call sites need scripted values.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/ReTiCAInterfaces/MeshCore/MeshCoreDriver.swift` | Contract 2 types, DependencyKey, `\.meshCoreDriver`, `\.meshCoreDate`, `\.meshCoreClock`, `\.meshCoreRandom` |
| `Sources/ReTiCAInterfaces/MeshCore/MeshCoreLinkPacing.swift` | Airtime, `fragmentDelay`, bitrate: the one source for pacing and profile |
| `Sources/ReTiCAInterfaces/MeshCore/MeshCoreTunnelCodec.swift` | Codec seam, `MeshCoreDatagram`, `ScotMeshRawCodec`, `MeshCoreFraming` |
| `Sources/ReTiCAInterfaces/MeshCore/MeshCoreReassembler.swift` | Pure bounded reassembly keyed `(src, pktID)` with 30 s dedupe |
| `Sources/ReTiCAInterfaces/MeshCore/MeshCoreAnnounceLimiter.swift` | Pure §5.5 limiter |
| `Sources/ReTiCAInterfaces/MeshCore/MeshCoreInterface.swift` | Reducer: driver lifecycle, receive rules, sender, `BIND`, `MeshCoreCounters` |
| `Sources/ReTiCANode/MeshCoreEndpoint.swift` | Interface id, `InterfaceProfile.meshCore(params:)`, endpoint wrapper, IFAC-8 helper |
| `Sources/ReTiCANode/TransportEndpoint.swift` (modify) | Slot, action, lifecycle arms, limiter wiring, `.ifLet` |
| `Package.swift:68` (modify) | Add the two MeshCore fixture JSONs to `ReTiCAInterfacesTests` resources |
| `Tests/ReTiCAInterfacesTests/Vectors/generate_meshcore_fixtures.py` | Drives ScotMesh's code, loaded by path, both directions |
| `Tests/ReTiCAInterfacesTests/Vectors/meshcore_our_split.json` | Swift-generated input to the generator |
| `Tests/ReTiCAInterfacesTests/Vectors/meshcore_fixtures.json` | Generator output |
| `Tests/ReTiCAInterfacesTests/MeshCore*Tests.swift`, `MeshCoreFixtureSupport.swift`, `MeshCoreInterfaceTestSupport.swift` | Suites named in each task |
| `Tests/ReTiCANodeTests/MeshCoreEndpointTests.swift`, `TransportEndpointMeshCoreTests.swift`, `MeshCoreSlotReplacementTests.swift`, `MeshCoreWholeSliceTests.swift`, `MeshCoreRelayProbeTests.swift` | Suites named in each task |

---

### Task 1: Driver contract and pacing table

**Files:**
- Create: `Sources/ReTiCAInterfaces/MeshCore/MeshCoreDriver.swift`, `MeshCoreLinkPacing.swift`
- Test: `Tests/ReTiCAInterfacesTests/MeshCoreDriverTests.swift`

**Interfaces:**
- Consumes: `BLEAdapterUnavailable` (`Sources/ReTiCAInterfaces/BLEDriver.swift:30`).
- Produces:
  - Contract 2 verbatim: `MeshCoreDriverConfig`, `MeshCoreLinkParams`, `MeshCoreDriverEvent`, `MeshCoreDriver`, each with a public memberwise `init` using the contract's defaults; `MeshCoreDriver.liveAdapterMissing: String`.
  - `DependencyValues.meshCoreDriver`, `.meshCoreDate: DateGenerator` (test value date 0), `.meshCoreClock: any Clock<Duration>` (test value `UnimplementedClock`), `.meshCoreRandom: MeshCoreRandom`.
  - `public struct MeshCoreRandom: Sendable { var packetID: @Sendable () -> UInt16; var bindDelay: @Sendable () -> Duration }`: live is uniform over `UInt16` and 3000–15000 ms; test value is `0x1000` and 3 s.
  - ```swift
    public enum MeshCoreLinkPacing {
        public static func isInRange(_ params: MeshCoreLinkParams) -> Bool
        public static func airtimeMilliseconds(_ params: MeshCoreLinkParams, payloadBytes: Int = 181) -> Double
        public static func fragmentDelaySeconds(_ params: MeshCoreLinkParams?) -> Double
        public static func fragmentDelay(_ params: MeshCoreLinkParams?) -> Duration
        public static func bitrate(_ params: MeshCoreLinkParams?) -> Int   // Int(148 * 8 / seconds)
    }
    ```

- [ ] **Step 0: Prerequisite: spec and plans are committed.** A person commits the spec and all four lane plans on `feat/meshcore-interface` before this task; the executor doesn't. If any check below fails, stop and report.

Run: `git -C WT branch --show-current`. Expected: `feat/meshcore-interface`.
Run: `git -C WT status --short`. Expected: no output.
Run: `git -C WT ls-files docs/superpowers/plans/2026-11-07-meshcore-lane-b-interface.md`. Expected: that path.
Run: `git -C WT rev-parse --short HEAD`. This is `BASE`. Write it to `/tmp/ReTiCaMsgr/lane-b-base.txt` with the Write tool.

- [ ] **Step 1: Confirm the worktree builds.** Run (timeout 600000): `swift build --package-path WT`. Expected: `Build complete!`; `../FCB` and `../MeshtasticKit` resolve through the existing symlinks.

- [ ] **Step 2: Write the failing tests**, suites `MeshCoreDriverTests`, `MeshCorePacingTests`. Rows are `(SF, bandwidth Hz, CR)`.

| Test | Assertions |
|---|---|
| `liveValueReportsTheMissingLiveAdapter` | events == `[.unavailable(.other("ReTiCAMeshCoreLive not installed"))]`, stream finishes |
| `liveValueSendReportsFailure`, `liveValueRemoveChannelReportsFailure` | each returns false |
| `configDefaultsMatchTheContract` | `channelName == "RNSTunnel"`, `dataType == 0xFFFF`, `retiredChannelSecrets == []`, `canRoute == false` |
| `liveBindDelayStaysWithin3To15Seconds` | 1000 draws in `.seconds(3)...seconds(15)` |
| `airtimeMatchesTheSpecTable` | within 0.001 ms: (7, 62500, 5) 633.344; (7, 62500, 7) 850.432; (8, 62500, 8) 1688.576; (9, 125000, 5) 955.392; (10, 250000, 5) 873.472; (11, 250000, 5) 1583.104 |
| `fragmentDelayMatchesTheSpecTable` | those rows in order, ms: 2500, 2500, 3378, 2500, 2500, 3167; `nil` → `.seconds(5)` |
| `bitrateMatchesTheSpecTable` | those rows: 473, 473, 350, 473, 473, 373; `nil` → 236 |
| `lowDataRateOptimiseStartsAt16MillisecondSymbols` | (11, 125000, 5) 3821.568; (12, 125000, 5) 6987.776 |
| `outOfRangeParamsUseFiveSeconds` | SF 4, SF 13, CR 4, CR 9, bandwidth 0, 6999, 500001: delay `.seconds(5)`, bitrate 236 |
| `everyValidParamCombinationHasAPositiveBitrate` | SF 5...12 × CR 5...8 × bandwidth {7000, 62500, 500000}: `> 0`; (12, 7000, 8) == 3 |

- [ ] **Step 3: Run; the build fails.** `swift test --package-path WT --filter MeshCoreDriverTests --filter MeshCorePacingTests`

- [ ] **Step 4: Implement.** DependencyKey shape: `MeshtasticDriver.swift:48-106`. Airtime, with `tsym = 2^sf / bw` in ms: `(preamble + 4.25) * tsym + (8 + max(ceil((8·n − 4·sf + 44) / (4·(sf − 2·de))) · cr, 0)) * tsym`; `preamble = sf <= 8 ? 32 : 16` (`RadioLibWrappers.h:56`); `de = tsym >= 16 ? 1 : 0`. Every value above came from this formula via a throwaway script.

- [ ] **Step 5: Verify (a), (b), (c).** Mutations: preamble `sf <= 7 ? 32 : 16`; `Int(147 * 8 / seconds)`; `de` always 0; `isInRange` widened to SF 4...13, CR 4...9, bandwidth ≥ 1 (bandwidth 0 stays rejected, so nothing traps); `bitrate` divides its result by 10; live `bindDelay` 1000–15000 ms.

- [ ] **Step 6: Commit** `feat: MeshCore driver contract and pacing table`.

---

### Task 2: Tunnel codec

**Files:** Create `Sources/ReTiCAInterfaces/MeshCore/MeshCoreTunnelCodec.swift`. Test `Tests/ReTiCAInterfacesTests/MeshCoreCodecTests.swift`.

**Interfaces (produces):**
```swift
public enum MeshCoreFrameType: Equatable, Sendable { case rnsFragment, bindRequest, bind, other(UInt8) }
public struct MeshCoreDatagram: Equatable, Sendable {
    public var type: MeshCoreFrameType; public var canRoute: Bool
    public var src: Data; public var dst: Data          // 4 bytes each
    public var packetID: UInt16
    public var fragmentIndex: UInt8; public var fragmentTotal: UInt8
    public var body: Data
}
public protocol MeshCoreTunnelCodec: Sendable {
    func split(_ data: Data, type: MeshCoreFrameType, src: Data, dst: Data,
               packetID: UInt16, canRoute: Bool) -> [Data]   // empty = cannot be framed
    func parse(_ datagram: Data) -> MeshCoreDatagram?
}
public struct ScotMeshRawCodec: MeshCoreTunnelCodec, Equatable {
    public static let magic: UInt8, headerSize: Int, payloadSize: Int, maxFragments: Int, maxDatagram: Int
    public static let broadcast: Data                     // 4 zero bytes
    public init()
}
public enum MeshCoreFraming: Equatable, Sendable { case scotMeshRaw; public var codec: any MeshCoreTunnelCodec }
```

- [ ] **Step 1: Write the failing tests**, suite `MeshCoreCodecTests`. `src = 01 02 03 04`, `dst` zeros, `packetID = 0xBEEF`.

| Test | Assertions |
|---|---|
| `splitBodySizesAreChunksOf148` | 1 [1]; 147 [147]; 148 [148]; 149 [148, 1]; 296 [148, 148]; 500 [148, 148, 148, 56]; 508 [148, 148, 148, 64] |
| `splitBodiesConcatenateToThePacket` | each length above |
| `largestDatagramIs162Bytes` | length 508: all `<= 162`, first `== 162` |
| `headerIsByteExact` | 149 B, `canRoute: true`, prefix 14 == `52 10 01 02 03 04 00 00 00 00 BE EF 00 02` |
| `canRouteClearLeavesBit4Clear` | byte 1 == `0x00` |
| `fragmentIndexCountsFromZero` | last of 500 B: bytes 12, 13 == `03 04` |
| `bindFrameUsesTypeNibble2` | `.bind` byte 1 `0x02`; `.bindRequest` `0x01` |
| `splitOfEmptyDataIsEmpty`, `splitRefusesABadPrefixLength` | `[]`; 3-byte `src` or 5-byte `dst` → `[]` |
| `splitRefusesMoreThan255Fragments` | 148·255 B → 255; 148·255+1 B → `[]` |
| `parseReadsEveryField` | all fields of a hand-built datagram, big-endian `packetID` |
| `parseAcceptsAHeaderOnlyDatagram` | 14 B parses, empty body |
| `parseRejectsAShortDatagram`, `parseRejectsABadMagic`, `parseRejectsZeroTotal` | 13 B; byte 0 `0x58`; total 0: nil |
| `parseRejectsIndexAtOrPastTotal` | idx 5 total 5 nil; idx 4 total 5 parses |
| `parseMapsAnUnknownTypeToOther` | nibble 3 → `.other(3)` |
| `parseIgnoresTheHighFlagBits` | flags `0xE0` → `.rnsFragment`, `canRoute == false` |
| `parseHandlesANonZeroBasedSlice`, `splitHandlesANonZeroBasedSlice` (b′) | same as fresh `Data` |
| `scotMeshRawFramingVendsTheCodec` | same output as `ScotMeshRawCodec()` |

- [ ] **Step 2: Run; the build fails.** `swift test --package-path WT --filter MeshCoreCodecTests`

- [ ] **Step 3: Implement.** Normalise inputs with `Data(x)`. Chunks step from 0.

- [ ] **Step 4: Verify (a), (b), (c).** Mutations: `payloadSize = 147`; write `packetID` little-endian; can-route mask `0x20`, and set it unconditionally; `frag_idx` 1-based; `maxFragments = 254` (256 would trap in `UInt8(total)`); reject `count == 14` and accept `count == 13` as a one-fragment empty datagram; `idx > total`. (b′), one at a time: drop `Data(...)` in `parse`, then in `split`.

- [ ] **Step 5: Commit** `feat: ScotMesh Raw tunnel codec behind a swappable seam`.

---

### Task 3: Reassembler

**Files:** Create `Sources/ReTiCAInterfaces/MeshCore/MeshCoreReassembler.swift`. Test `Tests/ReTiCAInterfacesTests/MeshCoreReassemblerTests.swift`.

**Interfaces (produces):**
```swift
public struct MeshCoreReassembler: Equatable, Sendable {
    public static let inactivityTimeout: TimeInterval   // 60
    public static let dedupeWindow: TimeInterval        // 30
    public static let maxDedupeKeys: Int                // 256
    public static let maxBuffersPerSender: Int          // 8
    public static let maxBuffersTotal: Int              // 64
    public static let maxPacketLength: Int              // 508
    public struct Counters: Equatable, Sendable { malformed, evicted, timedOut, oversize, completed: Int }
    public private(set) var counters: Counters
    public var bufferCount: Int { get }
    public var dedupeKeyCount: Int { get }
    public init()
    @discardableResult
    public mutating func receive(src: Data, packetID: UInt16, index: UInt8, total: UInt8,
                                 body: Data, now: Date) -> Data?
    public mutating func recordMalformed()
    public mutating func reset()   // drops buffers; keeps counters and dedupe keys
}
```

- [ ] **Step 1: Write the failing tests**, suite `MeshCoreReassemblerTests`. Private `parts(_:packetID:)` splits with the codec and parses back. `t0` = date 1000.

| Test | Assertions |
|---|---|
| `inOrderFragmentsCompleteOnTheLast` | 500 B: nil, nil, nil, packet |
| `singleFragmentPacketCompletesAtOnce`, `reversedFragmentsComplete` | returns packet on the last call |
| `interleavedSendersReassembleIndependently` | two srcs, same ID, both correct |
| `interleavedPacketIDsFromOneSenderReassembleIndependently` | same src, two IDs, both correct |
| `duplicateFragmentDoesNotDisturbReassembly` | `completed == 1` |
| `conflictingBodyRestartsTheBufferWithOnlyThatFragment` | x0, x1, y0; then x2, x3 nil; `bufferCount == 1` |
| `conflictingTotalRestartsTheBufferWithOnlyThatFragment` | idx 0 total 4, idx 1 total 2, idx 0 total 2 → that 2-part packet |
| `bufferIdleUnder60SecondsStillCompletes`, `bufferIdle60SecondsIsPurged` | last at `t0 + 59.9` returns packet; at `t0 + 60` nil, `timedOut == 1` |
| `ninthBufferFromOneSenderEvictsItsOldest` | `bufferCount == 8`, `evicted == 1`, oldest can't complete, newest can |
| `sixtyFifthBufferEvictsTheOldestOverall` | 65 srcs: `bufferCount == 64`, `evicted == 1` |
| `packetOf508BytesCompletes`, `packetOver508BytesIsDroppedAsOversize` | returns; 509 B nil, `oversize == 1`, `bufferCount == 0` |
| `emptyPacketIsDropped` | total 1, empty: nil, `malformed == 1`, `completed == 0` |
| `emptyFragmentInANonEmptyPacketIsAccepted` | total 2, empty + 5 B: returns the 5 B |
| `fragmentsOfAnyChunkSizeReassemble` | 500 B at chunks of 140 |
| `largestTotalDoesNotTrap` (b′) | idx 254 total 255: nil, `bufferCount == 1` |
| `retransmitWithin30SecondsIsNotDeliveredTwice`, `retransmitAt30SecondsDeliversAgain` | whole packet at `t0 + 29.9`: all nil, `completed == 1`; at `t0 + 30`: returns |
| `dedupeRemembersAtMost256Keys` | 257 packets: `dedupeKeyCount == 256`; first's retransmit delivers, last's doesn't |
| `backwardsClockExpiresADedupeKey` | retransmit at `t0 − 100` returns |
| `resetDropsEveryBuffer`, `resetKeepsCounters`, `resetKeepsDedupeKeys` | `bufferCount == 0`; `malformed` kept; a completed packet's retransmit isn't delivered |

- [ ] **Step 2: Run; the build fails.** `swift test --package-path WT --filter MeshCoreReassemblerTests`

- [ ] **Step 3: Implement.** Buffer: `total`, `[UInt8: Data]`, `byteCount`, `lastActivity`, a touch counter for deterministic eviction. Purge on each `receive`. Negative elapsed counts as expired, through one helper shared by purge and dedupe. Check `byteCount > 508` on insert.

- [ ] **Step 4: Verify (a), (b), (c).** Mutations: return on `bodies.count == 1`; a constant buffer key (fails both interleave tests); conflict keeps the first body and ignores `total`; boundary swap on 60 s; boundary swap on 30 s; `maxBuffersPerSender = 9`, `maxBuffersTotal = 65`, `maxDedupeKeys = 257`, `maxPacketLength = 509`; `reset()` leaves buffers, zeroes counters, clears keys; negative elapsed unexpired. (b′): store fragments in `[Data?](repeating: nil, count: Int(total) - 1)`.

- [ ] **Step 5: Commit** `feat: bounded MeshCore reassembler with 30 s dedupe`.

---

### Task 4: Announce and path-request limiter

**Files:** Create `Sources/ReTiCAInterfaces/MeshCore/MeshCoreAnnounceLimiter.swift`. Test `Tests/ReTiCAInterfacesTests/MeshCoreAnnounceLimiterTests.swift`.

**Interfaces:**
- Consumes: `Packet`, `PacketContext.pathResponse`, `DestinationType.plain`, `PacketType`. `ReTiCAInterfaces` already depends on `ReTiCA`.
- Produces:
  ```swift
  public struct MeshCoreAnnounceLimiter: Equatable, Sendable {
      public static let maxAnnounceHops: UInt8                  // 2
      public static let announceInterval: TimeInterval          // 600
      public static let heardRequestBypass: TimeInterval        // 15
      public static let pathRequestBurst: TimeInterval          // 60
      public static let pathRequestInterval: TimeInterval       // 1800
      public static let aggregateWindow: TimeInterval           // 600
      public static let maxPathRequestsPerWindow: Int           // 6
      public static let maxRelayedAnnouncesPerWindow: Int       // 6
      public static let maxRelayedPathResponsesPerWindow: Int   // 12
      public static let maxEntries: Int                         // 512
      public struct Counters: Equatable, Sendable { announcesLimited, pathRequestsLimited: Int }
      public private(set) var counters: Counters
      public init()
      /// Outbound. true = put it on the radio. `unmasked` is never IFAC-masked.
      public mutating func admit(unmasked: Data, now: Date) -> Bool
      /// Inbound, already past the IFAC gate. Records a heard path request.
      public mutating func noteHeard(unmasked: Data, now: Date)
      var announceEntryCount: Int { get }; var pathRequestEntryCount: Int { get }; var heardEntryCount: Int { get }
  }
  ```

Path-request timing per requested destination:

| At `now` | Result | Entry after allow |
|---|---|---|
| no entry | allow if aggregate has room | `first = last = now` |
| `now − first < 60` | allow if aggregate has room | `last = now` |
| `now − last < 1800` | drop | unchanged |
| otherwise | allow if aggregate has room | `first = last = now` |

- [ ] **Step 1: Write the failing tests**, suite `MeshCoreAnnounceLimiterTests`. Private builders via `Packet(...).packed()`: `announce(dest:hops:pathResponse:header2:)`, `pathRequest(requested:payloadTail:)`, single data, link request, proof, link data. `t(s)` = date 1000 + s. Fresh destinations unless stated.

| Test | Assertions |
|---|---|
| `announceAtHops2Passes`, `announceAtHops3IsDropped` | true; false, `announcesLimited == 1` |
| `pathResponseAtHops3Passes`, `hopCapReadsHeader2Packets` | context `.pathResponse` true; HEADER_2 hops 3 false |
| `secondAnnounceWithin600SecondsIsDropped`, `announceAt600SecondsPasses` | same dest t(0), t(599.9): true, false; t(0), t(600): true, true |
| `differentDestinationIsNotHeldByTheFirst` | two dests at t(0): true, true |
| `announceWithin15SecondsOfAHeardRequestBypasses`, `heardRequestExpiresAt15Seconds` | stamped t(0), heard t(100); t(114.9) true; t(115) false |
| `bypassIsConsumedByOneAnnounce` | stamped, one heard, two announces inside 15 s: true, false |
| `requestHeardForAnotherDestinationDoesNotBypass` | heard X, stamped Y: false |
| `hopCapAppliesWhenAnsweringAHeardRequest` | heard, hops 3, not path response: false |
| `ownAnnouncesAreExemptFromTheRelayedCap` | 20 dests, hops 0: all true |
| `seventhRelayedAnnounceIn10MinutesIsDropped`, `relayedAnnounceCapReopensAt600Seconds` | 7 dests hops 1, t(0...6): true ×6, false; new dest at t(600): true |
| `thirteenthRelayedPathResponseIn10MinutesIsDropped`, `ownPathResponseIsExemptFromTheCap` | 13 at hops 1: true ×12, false; 13 at hops 0: all true |
| `relayedAnnounceAndPathResponseCapsAreCountedSeparately` | 6 then 12 at hops 1: all true |
| `droppedByTheCapDoesNotStartItsDestinationInterval` | 7th dest dropped t(6); same dest t(600): true |
| `pathRequestsAreKeyedOnTheRequestedDestination` | X t(0), Y t(61): true, true (outer hash identical) |
| `pathRequestPassesInsideTheBurstWindow`, `pathRequestIsDroppedAfterTheBurstWindow` | X t(0), t(59.9): true, true; t(0), t(60): true, false, `pathRequestsLimited == 1` |
| `pathRequestPassesAt1800SecondsAfterTheLast` | X t(0), t(59), t(1858.9) false, t(1859) true |
| `aNewBurstStartsAfterTheInterval` | X t(0), t(59), t(1859) true, t(1918) true |
| `seventhPathRequestIn10MinutesIsDropped`, `pathRequestAggregateReopensAt600Seconds` | 7 requested, t(0...6): true ×6, false; new X t(600): true |
| `droppedByTheAggregateDoesNotStartTheBurstWindow` | squeezed-out X; X t(600) true; X t(659) true |
| `relayedPathRequestIsKeyedLikeALocalOne` | 48 B and 32 B payloads for one dest share a key: t(0), t(1), then t(60): false |
| `shortPlainPayloadDoesNotTrap` (b′) | 3 B payload returns |
| `linkAndSingleTrafficIsNeverLimited` | 100 each of single data, link request, proof, link data: all true, counters zero |
| `unparseableBytesPassUncounted` | 1 B input; hops `0xFF`: true, counters zero |
| `nonZeroBasedSliceClassifiesTheSame` (b′) | `backing.dropFirst(2)`: same verdicts |
| `announceMapKeepsAtMost512Entries` | 513 own dests: count 512; first passes again, second doesn't |
| `pathRequestMapKeepsAtMost512Entries`, `heardMapKeepsAtMost512Entries` | 513 (requests spaced 100.1 s): count 512 |
| `heardIgnoresEverythingButPathRequests` | an announce: `heardEntryCount == 0` |
| `backwardsClockExpiresALimiterWindow` | X t(0), t(60) false, t(−1000) true; same for an announce |

- [ ] **Step 2: Run; the build fails.** `swift test --package-path WT --filter MeshCoreAnnounceLimiterTests`

- [ ] **Step 3: Implement** per Decisions. Three maps and three timestamp arrays pruned on use. Evict oldest by stamp, with a counter to break ties.

- [ ] **Step 4: Verify (a), (b), (c).** Mutations, one batch:

| Mutation | Breaks |
|---|---|
| hop rule becomes `hops == 2`, or `hops > 2` with context `.pathResponse` | the four hop tests and `hopCapAppliesWhenAnsweringAHeardRequest` |
| boundary swap on 600 s, 15 s, 60 s, 1800 s (one each) | the two tests either side of each limit |
| also drop when any other destination has a stamp at this exact `now` | `differentDestinationIsNotHeldByTheFirst` |
| don't consume the heard entry; heard check ignores destination | `bypassIsConsumedByOneAnnounce`; `requestHeardForAnotherDestinationDoesNotBypass` |
| stamp the destination before the pool check | `droppedByTheCapDoesNotStartItsDestinationInterval` |
| hops 0 count in both pools; one shared relayed pool | the two `own…Exempt` tests; `…CountedSeparately` |
| `first` not reset after the interval | `aNewBurstStartsAfterTheInterval` |
| create the entry before the aggregate check | `droppedByTheAggregateDoesNotStartTheBurstWindow` |
| key path requests on `destinationHash` | `pathRequestsAreKeyedOnTheRequestedDestination`, `relayedPathRequestIsKeyedLikeALocalOne` |
| apply announce rules to every type; false on `Packet(raw:)` nil | `linkAndSingleTrafficIsNeverLimited`; `unparseableBytesPassUncounted` |
| negative elapsed unexpired | `backwardsClockExpiresALimiterWindow` |

(b′), one at a time: read hops as `unmasked[1]` on the raw input; index the payload directly instead of `prefix(16)`.

- [ ] **Step 5: Commit** `feat: MeshCore announce and path-request limiter`.

---

### Task 5: Cross-validation against ScotMesh's code

**Files:**
- Create in `Tests/ReTiCAInterfacesTests/Vectors/`: `generate_meshcore_fixtures.py`, `meshcore_our_split.json`, `meshcore_fixtures.json`
- Create: `Tests/ReTiCAInterfacesTests/MeshCoreFixtureSupport.swift`, `MeshCoreCrossValidationTests.swift`
- Modify: `Package.swift:68`, adding `.process("Vectors/meshcore_fixtures.json"), .process("Vectors/meshcore_our_split.json")`

**Interfaces:** consumes the codec, reassembler and limiter. Produces `meshCorePattern(_:seed:)`, `meshCoreData(hex:)`, `MeshCoreFixtures`, `MeshCoreOurSplitFile` (`current()`, `load()`, `encoded()`). Precedent: `MeshtasticFixtureSupport.swift`, `MeshtasticCrossValidationTests.swift`, `Vectors/generate_meshtastic_fixtures.py`.

**How the generator gets the module:** a required path argument. It checks the file's sha256 against `d378b47ae59c2ce943bc813385cefff384fcb658f6984a1c7fd72e0c3e00624c` (`Interface/MeshCore_Raw_Interface.py` at `2167780f9b2754070ab944262c1a7831d28a72ce`) and loads it with `importlib.util.spec_from_file_location`, without touching `sys.path` or copying anything. The module's `except NameError` import fallback (lines 148–151) covers a direct load; `RNS` comes from the conda env. The header comment records the upstream URL, commit and re-clone commands, and states it imports GPL-3.0 code at dev time only. It contains none of that code.

- [ ] **Step 1: Confirm the pinned clone.** Run: `shasum -a 256 /tmp/ReTiCaMsgr/research/scotmesh/repo/Interface/MeshCore_Raw_Interface.py`. Expected: starts `d378b47a`. If it is gone, re-clone to a new empty directory and use that path below:

Run: `mkdir -p /tmp/ReTiCaMsgr/research/scotmesh-reclone`
Run: `git clone https://github.com/ScotMesh/RNS_Over_Meshcore /tmp/ReTiCaMsgr/research/scotmesh-reclone/repo`
Run: `git -C /tmp/ReTiCaMsgr/research/scotmesh-reclone/repo checkout 2167780f9b2754070ab944262c1a7831d28a72ce`

- [ ] **Step 2: Write the emitter and support.** `MeshCoreOurSplitEmitter.writeOurSplitForTheReferenceGenerator`, enabled only when `RETICA_EMIT_MESHCORE_SPLIT == "1"`, writes `Vectors/meshcore_our_split.json` via `#filePath`: our split for lengths 1, 147, 148, 149, 296, 500, 508, `src` `01020304`, `packetID` `0xBEEF`, `canRoute` false and true, plus our `BIND` for a fixed key whose first 4 bytes are `src`.

Run: `env RETICA_EMIT_MESHCORE_SPLIT=1 swift test --package-path WT --filter MeshCoreOurSplitEmitter`

- [ ] **Step 3: Write the generator**, driving only the reference's own code:
  - `_Frame.fragments` for those lengths × can-route at chunk 148, and 500 B at chunk 140 (`theirSplit`).
  - `_Frame.build` for `T_BIND_REQ`, `T_BIND` (`theirBind`).
  - `_Frame.parse` on short, bad-magic, zero-total, idx-past-total frames (`theirRejects`), and over our split (`ourSplitParsed`).
  - A radio-less `interface_class.__new__(interface_class)`, as the Meshtastic generator does, with the attributes `_on_frame` and `_handle_bind` touch: `_own_prefix` (≠ `src`), `_peers` (pre-filled so `src` is bound), `_peer_caps`, `_peer_last_seen`, `_rns_to_peer`, `_pending_tokens`, `_seen_pkts`, `_assembly`, `_assembly_meta`, `_path_response_pending`, `_path_response_bypass_s`, matching locks, `learn_path_from_rx = False`, `allow_direct = False`, `_pending_resp_task = None`, `_loop`, no-op `_log`/`_dbg`, and a capturing `process_incoming`. `AttributeError` on first run means add the attribute; never edit the reference. This path wasn't executed while writing the plan.
  - Through `_on_frame`: our split in order, reversed, and with the first fragment repeated (`ourSplitDelivered`); one packet twice (`retransmit`); a conflicting body at index 0, then the rest (`conflict`: the reference keeps the first body); our `BIND` (`ourBindAccepted`: `_peers[prefix] == key`).
  - `interface_class.announce_exceeds_hops(data, 2)` at hops 2 and 3, with and without `PATH_RESPONSE`, HEADER_1 and HEADER_2 (`hopCap`).

Run (timeout 300000): `conda run -n rns python -I -B WT/Tests/ReTiCAInterfacesTests/Vectors/generate_meshcore_fixtures.py /tmp/ReTiCaMsgr/research/scotmesh/repo/Interface/MeshCore_Raw_Interface.py`

- [ ] **Step 4: Add the resources line; write suite `MeshCoreCrossValidationTests`:**

| Test | Assertions |
|---|---|
| `ourSplitMatchesTheReferenceByteForByte` | 14 rows at chunk 148: `split(...) == fragments` |
| `ourParseReadsEveryReferenceFragment` | all rows including chunk 140: fields, body |
| `ourReassemblerRebuildsReferenceFragments` | all rows: last returns `packet`, earlier nil |
| `ourCodecFramesBindLikeTheReference` | `theirBind` == our `split(key, type: ...)` |
| `ourParseRejectsWhatTheReferenceRejects` | every `theirRejects` frame nil |
| `committedSplitIsWhatOurCodecEmitsToday` | `load() == current()`, message "regenerate: emitter, then generator" |
| `referenceParsesOurSplitBackToThePacket` | each `reassembled == packet`; packets equal the committed cases |
| `referenceDeliversOurSplitInAnyOrder` | each order delivered exactly `[packet]`; our reassembler agrees on those fragments |
| `referenceAcceptsOurBind` | `.frame == current().bind`, `.accepted == true` |
| `retransmitIsDeliveredOnceHereAsInTheReference` | reference count 1; ours 1 |
| `conflictingFragmentDeliversDifferentlyFromTheReferenceByDesign` | §5.6 deviation: reference returned the first body's packet; ours returns nil at that point |
| `hopCapMatchesTheReference` | every row: `admit(...) == !exceeds` on a fresh limiter |

- [ ] **Step 5: Verify (a), (b), (c).** Don't regenerate fixtures under mutation. Mutations: `payloadSize = 147`; parse `packetID` little-endian; reassembler concatenates in reverse at completion; `.bind` nibble 3; remove the magic guard; no dedupe remembering; conflict keeps the first body; `maxAnnounceHops = 3`.

- [ ] **Step 6: Check no GPL landed.** `git -C WT status --short` shows only the files above. `docs/` can't appear: Task 1's prerequisite committed it.

- [ ] **Step 7: Commit** `test: cross-validate the MeshCore codec against ScotMesh's own code`.

---

### Task 6: `MeshCoreInterface`: lifecycle, stop semantics, receive rules, lane D surfaces

**Files:** Create `Sources/ReTiCAInterfaces/MeshCore/MeshCoreInterface.swift`. Test in `Tests/ReTiCAInterfacesTests/`: `MeshCoreInterfaceTestSupport.swift`, `MeshCoreInterfaceLifecycleTests.swift`, `MeshCoreInterfaceStopTests.swift`, `MeshCoreInterfaceStartEpochTests.swift`.

**Interfaces:**
- Consumes: Tasks 1–4; internal `DriverEpoch`.
- Produces (Task 7 adds actions, sender state and `BIND`):
  ```swift
  public enum MeshCoreInterfaceStatus: Equatable, Sendable {
      case stopped, connecting
      case online(selfPrefix: Data, publicKey: Data, params: MeshCoreLinkParams?)
      case unavailable(BLEAdapterUnavailable)
  }
  public struct MeshCoreCounters: Equatable, Sendable {   // Contract 3
      public var malformed, notAddressed, evicted, timedOut, oversize, completed,
                 queueFull, sendFailed, announcesLimited, pathRequestsLimited: Int
      public init(malformed: Int = 0, notAddressed: Int = 0, evicted: Int = 0, timedOut: Int = 0,
                  oversize: Int = 0, completed: Int = 0, queueFull: Int = 0, sendFailed: Int = 0,
                  announcesLimited: Int = 0, pathRequestsLimited: Int = 0)
  }
  @Reducer public struct MeshCoreInterface {
      public static let queueCapacity = 64
      @ObservableState public struct State: Equatable {
          public internal(set) var config: MeshCoreDriverConfig
          public let framing: MeshCoreFraming
          public internal(set) var status: MeshCoreInterfaceStatus
          public internal(set) var reassembler: MeshCoreReassembler
          public var limiter: MeshCoreAnnounceLimiter
          var counters: Counters                           // internal: notAddressed, queueFull, sendFailed, all Int
          public init(config: MeshCoreDriverConfig, framing: MeshCoreFraming = .scotMeshRaw)
          public var isOnline: Bool { get }
          public var params: MeshCoreLinkParams? { get }
          public var isIdle: Bool { get }                  // .stopped and no driver.stop() in flight
          public var diagnostics: MeshCoreCounters { get }
      }
      public enum Action: Equatable {
          case start, stop, removeChannel
          case driverEvent(MeshCoreDriverEvent)
          case driverStopped, restartDeferred
          case channelRemovalFinished(Bool)
          case delegate(Delegate)
          public enum Delegate: Equatable {
              case online(selfPrefix: Data, publicKey: Data, params: MeshCoreLinkParams?)
              case offline(reason: String?)
              case packetReceived(Data)
              case adapterUnavailable(BLEAdapterUnavailable)
              case retiredChannelsCleared
              case channelRemoved(Bool)
          }
      }
  }
  ```
- Test support, shaped like `MeshtasticInterfaceTestSupport.swift`: `MeshCoreMockCall { start(MeshCoreDriverConfig), send(Data), removeChannel, stop }`, `meshCoreTestConfig`, `meshCoreOwnKey`, `meshCoreOwnPrefix`, `meshCorePeerPrefix`, `MeshCoreInterfaceHarness { store, radio, calls, clock, now }`, `makeMeshCoreInterface(initial:sendResults:removeResult:bindDelay:)`, `makeOnlineMeshCoreInterface(params:initial:sendResults:)`, `stopMeshCoreInterface(_:)`.

**Stop semantics, right from the start.** Port from `MeshtasticInterface.swift`, not from the Meshtastic lane B plan, which predates them: `stopping`, `restartPending`, `restartQueued`, `epoch`, and the arms at lines 179–240 including `.restartDeferred` and the hop through a task. `.stop` bumps the epoch at reduce time; `startDriver` uses `epoch.start(ifCurrent:)`; a stop's offline is emitted only from `.driverStopped`; `.stop` to an idle interface answers offline at once; `isIdle = status == .stopped && !stopping`. Copy the comments that say why.

**Removal:** `removingChannel`, `stopHeld`. `.removeChannel` online and not removing launches `driver.removeChannel()`, then `.channelRemovalFinished(ok)`. Not online: `.send(.delegate(.channelRemoved(false)))`. Already removing: `.none`. `.stop` while `removingChannel` sets `stopHeld`, returns `.none`. `.channelRemovalFinished` emits `.channelRemoved(ok)`, then `.stop` if held, in a `.concatenate`.

- [ ] **Step 1: Write the failing tests.** Suite `MeshCoreInterfaceLifecycleTests`:

These mirror the same-named tests in `MeshtasticInterfaceLifecycleTests.swift`, changing only the event types: `unavailableSurfacesTheCause`, `aReconnectAttemptAfterUnavailableIsConnectingAndBlocksStart`, `unavailableWhileOnlineReportsOffline`, `stopStopsTheDriver`, `stopWhileConnectingReportsOffline`, `startDuringASlowStopReachesTheDriverAfterTheStop`, `startDuringASlowStopBringsTheRadioOnline`, `stopCancelsAStartDeferredBehindASlowStop`, `disconnectReportsOfflineWithTheReason`, `disconnectDiscardsPartialReassembly`.

| New test | Assertions |
|---|---|
| `startHandsTheConfigToTheDriver` | `calls == [.start(meshCoreTestConfig)]`, with a non-default secret, retired list and `canRoute` |
| `connectedEventReportsOnlineWithItsParams`, `connectedEventWithNilParamsIsOnline` | delegate carries the values, `state.params` equal; `isOnline`, `params == nil` |
| `noFreeSlotMessageSurfacesVerbatim`, `firmwareTooOldMessageSurfacesVerbatim` | `.other("No free channel slot on this radio")`; `.other("This radio's firmware is too old; update to v1.15 or later")` |
| `eventsAfterStopAreIgnored` | `.connected` after `.stop`: stays `.stopped`, no `.online` |
| `datagramBeforeTheRadioIsOnlineIsDropped` | `completed == 0`, no packet |
| `peerDatagramsReassembleIntoOnePacket` | 500 B split → one `.packetReceived(packet)` |
| `malformedDatagramIncrementsMalformed` | 3 B: `malformed == 1` |
| `ownDatagramIsDropped` | `src == selfPrefix`: no packet, `notAddressed == 0` |
| `datagramForAnotherPrefixCountsNotAddressed` | `notAddressed == 1`, no packet |
| `datagramAddressedToOurPrefixIsDelivered`, `broadcastDatagramIsDelivered` | both deliver |
| `bindFrameIsIgnored`, `unknownTypeIsIgnored` | type 2, type 3: no packet, no send |
| `malformedComesBeforeTheAddressCheck` | bad magic, foreign `dst`: `malformed == 1`, `notAddressed == 0` |
| `addressCheckComesBeforeReassembly` | fragment for another prefix: `bufferCount == 0` |
| `diagnosticsCarryEveryCounter` | seeded state: all ten fields |
| `limiterSurvivesADisconnect` | `limiter` unchanged after `.disconnected` |
| `retiredChannelsClearedSurfacesWhileConnecting`, `retiredChannelsClearedIsIgnoredAfterStop` | delegate before `.connected`; none after `.stop` |
| `removeChannelCallsTheDriverOnce`, `channelRemovedReportsTheDriverResult` | one call; true and false each surface |
| `removeChannelWhileOfflineReportsFalseWithoutCallingTheDriver` | `.channelRemoved(false)`, no call |
| `secondRemoveChannelDuringARemovalDoesNotCallTheDriverAgain` | one call |
| `stopDuringARemovalWaitsForTheRemovalToFinish` | held: no `.stop` call yet; released: `[..., .removeChannel, .stop]`; `isIdle` false until `.driverStopped` |
| `channelRemovedPrecedesOfflineWhenStoppedDuringARemoval` | reduce-order log: `channelRemoved`, `offline` |

Suite `MeshCoreInterfaceStopTests`: the eight tests of `MeshtasticInterfaceStopTests.swift`, same names, same recorder and fresh-stream harness. Suite `MeshCoreInterfaceStartEpochTests`: both tests of `MeshtasticInterfaceStartEpochTests.swift`, same names and burst host, 5 runs each.

- [ ] **Step 2: Run; the build fails.** `swift test --package-path WT --filter MeshCoreInterfaceLifecycleTests --filter MeshCoreInterfaceStopTests --filter MeshCoreInterfaceStartEpochTests`

- [ ] **Step 3: Implement.** Receive arm in §5.2's order. `.retiredChannelsCleared` forwards in any status but `.stopped`, because the slot policy runs before `.connected`.

- [ ] **Step 4: Verify (a), (b), (c).** Mutations, one batch:

| Mutation | Breaks |
|---|---|
| `.unavailable` maps every cause to `.other(nil)` | `unavailableSurfacesTheCause`, both `Verbatim` tests |
| `.stop` never calls `driver.stop()` and emits offline at once | `stopStopsTheDriver`, `startDuringASlowStop…` (2), `stopCancelsAStartDeferredBehindASlowStop`, the ordering tests in `MeshCoreInterfaceStopTests` |
| `.stop` to a stopped interface, or from `.connecting`, returns `.none` | `stopOnANeverStartedInterfaceReportsOfflineAtOnce`, `stopAfterACompletedStopReportsOfflineAgain`, `stopWhileConnectingReportsOffline` |
| remove `state.epoch.invalidate()` | `aStopInTheStartsBurstFromStoppedKeepsTheStartOffTheDriver` |
| `.restartDeferred` ignores `restartQueued` | `aStopAnsweringTheRestartOfflineWinsOverTheDeferredStart`, `aStopInTheDeferredRestartsBurstKeepsTheRestartOffTheDriver` |
| remove the self-source drop and invert the address check | `ownDatagramIsDropped`, the three address tests, `addressCheckComesBeforeReassembly`, `peerDatagramsReassembleIntoOnePacket` |
| don't count a parse failure | `malformedDatagramIncrementsMalformed`, `malformedComesBeforeTheAddressCheck` |
| `.retiredChannelsCleared` forwarded only when `.stopped` | both `retiredChannelsCleared…` tests |
| `.stop` doesn't hold during a removal | `stopDuringARemovalWaitsForTheRemovalToFinish`, `channelRemovedPrecedesOfflineWhenStoppedDuringARemoval` |
| `clearTraffic` resets `limiter` | `limiterSurvivesADisconnect` |

- [ ] **Step 5: Commit** `feat: MeshCoreInterface lifecycle, stop semantics and receive rules`.

---

### Task 7: `MeshCoreInterface`: paced sender and `BIND`

**Files:** Modify `Sources/ReTiCAInterfaces/MeshCore/MeshCoreInterface.swift`. Test `Tests/ReTiCAInterfacesTests/MeshCoreInterfaceSenderTests.swift`, `MeshCoreInterfaceBindTests.swift`.

**Interfaces (produces):** actions `.send(Data)` (already IFAC-masked), `.setCanRoute(Bool)`, `.datagramSent(ok: Bool)`, `.pacingElapsed`, `.bindDelayElapsed`; `State.queuedDatagramCount: Int`; internal `queue`, `pacing`, `nextPacketID: UInt16?`, `bindReplyPending`, `lastBindSent: Date?`; `CancelID.pacing`, `.bindReply`. It increments `counters.queueFull` and `counters.sendFailed`, declared in Task 6.

The sender's effect is one `.run`, cancellable on `.pacing`: `driver.send`, `.datagramSent(ok:)`, sleep `ok ? delay : delay * 2`, `.pacingElapsed`. Mirror `pump` at `MeshtasticInterface.swift:332-344`.

- [ ] **Step 1: Write the failing tests.** `sf7` = (7, 62500, 5), delay 2.5 s; `sf8` = (8, 62500, 8), delay 3378 ms.

Suite `MeshCoreInterfaceSenderTests`:

| Test | Assertions |
|---|---|
| `sendFramesThePacketForBroadcastFromOurPrefix` | first sent == `split(raw, type: .rnsFragment, src: prefix, dst: .broadcast, packetID: 0x1000, canRoute: false)[0]` |
| `firstDatagramGoesOutWithoutWaiting` | one send, clock untouched |
| `nextDatagramWaitsTheFragmentDelay` | `sf7`: 2.499 s → 1 sent; +0.001 s → 2 |
| `delayFollowsTheRadiosParams`, `unknownParamsPaceAtFiveSeconds` | `sf8`: 3.377 s → 1, +0.001 s → 2; `nil`: 4.999 s → 1, +0.001 s → 2 |
| `nextDatagramWaitsForTheDriverToReturn` | `send` held: clock +60 s, one call; release, one delay → 2 |
| `sendFailureCountsSendFailed`, `sendFailureDropsTheDatagram` | `sendFailed == 1`; second call is fragment 1 |
| `sendFailureWaitsAnExtraFragmentDelay` | `sf7`, `[false]`: 4.999 s total → 1 call; 5 s → 2 |
| `everyFragmentGoesOutExactlyOnce` | after all delays, `sent == split` |
| `queueHoldsAtMost64Datagrams` | 66 one-fragment packets: `queuedDatagramCount == 64`, `queueFull == 1` |
| `aPacketThatDoesNotFitIsDroppedWhole` | 62 queued + a 4-fragment packet: stays 62, `queueFull == 1` |
| `disconnectClearsTheQueue`, `disconnectCancelsThePacingTimer` | count 0; after reconnect a new packet sends at once, no double send |
| `reconnectRecomputesTheDelay` | `sf7`, drop, `.connected` with `sf8`: paced at 3378 ms |
| `sendWhileOfflineIsDropped`, `shortPrefixSendsNothing` | no call, no `queueFull`; 3-byte `selfPrefix`: no call |
| `packetIDStartsAtTheInjectedRandomValue` | `0x1000` and `0x2222` from those test values |
| `fragmentsOfOnePacketShareAPacketID`, `packetIDAdvancesPerPacket` | all equal; `0x1000`, `0x1001` |
| `packetIDWrapsFrom65535To0` | start `0xFFFF`: `0xFFFF`, `0x0000` |
| `reconnectContinuesThePacketID`, `stopAndStartContinuesThePacketID` | next ID, no new draw |
| `canRouteFromTheConfigSetsTheHeaderBit` | byte 1 `0x10` |
| `setCanRouteAffectsTheNextPacket`, `setCanRouteDoesNotRestartTheDriver`, `setCanRouteLeavesQueuedDatagramsAlone` | next packet `0x10`; one `.start`, no `.stop`; queued keep it clear |

Suite `MeshCoreInterfaceBindTests`, scripted `bindDelay` 7 s:

| Test | Assertions |
|---|---|
| `bindRequestIsAnsweredAfterTheRandomDelay` | 6.999 s → none; +0.001 s → 1 |
| `bindReplyIsByteExact` | parse: `.bind`, `src` prefix, `dst` zeros, `body == publicKey`, index 0, total 1; `count == 46` |
| `bindReplyCarriesTheCanRouteBit` | byte 1 `0x12` |
| `bindRequestAddressedToUsIsAnswered`, `bindRequestForAnotherPrefixIsNotAnswered` | replied; `notAddressed == 1`, none |
| `furtherRequestsWhileAReplyIsPendingDoNothing` | 3 requests: 1 send |
| `requestWithin60SecondsOfABindDoesNothing`, `requestAt60SecondsIsAnswered` | `now` +59.9 s after enqueue: none; +60 s: second reply |
| `ourOwnBindRequestEchoIsNotAnswered`, `incomingBindIsNotAnswered` | none |
| `disconnectCancelsAPendingReply`, `stopCancelsAPendingReply` | none after the delay |
| `sixtySecondLimitSurvivesADisconnect` | sent, drop, reconnect, request at 30 s: none |
| `bindConsumesAPacketID` | next data ID is one past the bind's |
| `bindGoesThroughThePacedQueue` | queued data first; never two sends inside one delay |
| `neverSendsABindRequest` | after connect, send, receive and an answered request: no sent frame is `.bindRequest` |

- [ ] **Step 2: Run; the build fails.** `swift test --package-path WT --filter MeshCoreInterfaceSenderTests --filter MeshCoreInterfaceBindTests`

- [ ] **Step 3: Implement.** Draw `nextPacketID` at `.connected` only if nil. `.bindDelayElapsed` enqueues and stamps `lastBindSent = date()`. Extend `clearTraffic` and `.stop`: empty the queue, clear `pacing` and `bindReplyPending`; add both cancels inside the arms' `return`.

- [ ] **Step 4: Verify (a), (b), (c).** Also rerun Task 6's suites at (c). Mutations, one batch:

| Mutation | Breaks |
|---|---|
| sleep `fragmentDelay(params) + .milliseconds(1)` | the delay tests, `reconnectRecomputesTheDelay` |
| spawn `driver.send` in a detached task and sleep at once | `nextDatagramWaitsForTheDriverToReturn` |
| no extra delay on failure; requeue on failure | `sendFailureWaitsAnExtraFragmentDelay`; `sendFailureDropsTheDatagram`, `everyFragmentGoesOutExactlyOnce` |
| `queueCapacity = 65`; enqueue what fits | the two queue tests |
| `.send` not gated on online (zero prefix offline); split's prefix guard removed | `sendWhileOfflineIsDropped`, `shortPrefixSendsNothing` |
| new ID per fragment; never advance; re-draw at `.connected`; reset at `.stop` | the packet-ID tests |
| `.setCanRoute` restarts the driver and rewrites queued byte 1 | `setCanRouteDoesNotRestartTheDriver`, `setCanRouteLeavesQueuedDatagramsAlone` |
| `canRoute: false` hard-coded in split | `canRouteFromTheConfigSetsTheHeaderBit`, `setCanRouteAffectsTheNextPacket`, `bindReplyCarriesTheCanRouteBit` |
| reply at once; body `selfPrefix`; type `.bindRequest` | `bindRequestIsAnsweredAfterTheRandomDelay`, `bindReplyIsByteExact`, `neverSendsABindRequest` |
| `BIND_REQ` handled before the source and address checks; type 2 treated like type 1 | `bindRequestForAnotherPrefixIsNotAnswered`, `ourOwnBindRequestEchoIsNotAnswered`, `incomingBindIsNotAnswered` |
| no `bindReplyPending` guard; boundary swap on 60 s; `.disconnected` clears `lastBindSent` | `furtherRequests…`; the two 60 s tests; `sixtySecondLimitSurvivesADisconnect` |
| no `.bindReply` cancel | `disconnectCancelsAPendingReply`, `stopCancelsAPendingReply` |
| bind calls `driver.send` directly with a fixed ID | `bindGoesThroughThePacedQueue`, `bindConsumesAPacketID` |

- [ ] **Step 5: Commit** `feat: paced MeshCore sender and BIND replies`.

---

### Task 8: `MeshCoreEndpoint`, interface id, profile

**Files:** Create `Sources/ReTiCANode/MeshCoreEndpoint.swift`. Test `Tests/ReTiCANodeTests/MeshCoreEndpointTests.swift`.

**Interfaces (produces):**
```swift
public func meshCoreInterfaceID(radio: UUID) -> InterfaceID
extension InterfaceProfile { public static func meshCore(params: MeshCoreLinkParams?) -> InterfaceProfile }
@Reducer public struct MeshCoreEndpoint {
    public static let ifacSize = 8
    public static func ifac(networkName: String?, passphrase: String?) -> IFAC?
    @ObservableState public struct State: Equatable {
        public var interface: MeshCoreInterface.State
        public let profile: InterfaceProfile                // IFAC and mode only
        public var interfaceID: InterfaceID { get }
        public var counters: MeshCoreCounters { get }
        public init(config: MeshCoreDriverConfig, profile: InterfaceProfile = .meshCore(params: nil))
        public func registeredProfile(params: MeshCoreLinkParams?) -> InterfaceProfile
    }
    public enum Action: Equatable {
        case interface(MeshCoreInterface.Action)
        case start, stop, removeChannel
        case setCanRoute(Bool)
        case delegate(Delegate)
        @CasePathable public enum Delegate: Equatable {
            case radioOnline(publicKey: Data, params: MeshCoreLinkParams?)
            case radioOffline(reason: String?)
            case adapterUnavailable(BLEAdapterUnavailable)
            case retiredChannelsCleared
            case channelRemoved(Bool)
        }
    }
}
```
The extension lives here for the reason at `MeshtasticEndpoint.swift:19-20`. This reducer translates `.retiredChannelsCleared` and `.channelRemoved`; `TransportEndpoint` translates the three that touch the router.

- [ ] **Step 1: Write the failing tests**, suite `MeshCoreEndpointTests`:

| Test | Assertions |
|---|---|
| `profileBitrateMatchesTheSpecTable` | §5.4's six rows → 473, 473, 350, 473, 473, 373; `nil` → 236 |
| `profileIsNamedMeshCore`, `profileDeclaresAHardwareMTUOf500`, `profileModeIsTheTCPDefault` | `"meshcore"`; 500; `InterfaceProfile.tcp.mode` |
| `profileForOutOfRangeParamsDoesNotTrap` (b′) | bandwidth 0, SF 0: bitrate 236 |
| `registeredProfileTakesIFACFromTheEndpointProfile`, `…ModeFromTheEndpointProfile`, `…BitrateFromTheParams` | as named; `sf8` → 350 |
| `interfaceIDIsMeshCoreColonTheRadioUUID` | `InterfaceID("meshcore:" + uuid.uuidString)` |
| `ifacHelperUsesEightByteAccessCodes` | `protect(raw).count == raw.count + 8` |
| `endpointStartStartsTheDriver`, `endpointRemoveChannelReachesTheDriver` | one `.start`; one `.removeChannel`, `.channelRemoved(true)` |
| `retiredChannelsClearedSurfacesOnTheEndpoint`, `setCanRouteReachesTheInterface` | delegate; `interface.config.canRoute == true` |
| `countersShowAMalformedDatagram`, `countersShowAQueueFullDrop` | 1 each |

- [ ] **Step 2: Run; the build fails.** `swift test --package-path WT --filter MeshCoreEndpointTests`

- [ ] **Step 3: Implement.** Shape: `MeshtasticEndpoint.swift`.

- [ ] **Step 4: Verify (a), (b), (c).** Mutations: bitrate fixed at 473; name, `hwMTU`, mode changed; `registeredProfile` drops `ifac` and `mode`; id prefix `"meshcore-"`; `ifacSize = 16`; the three actions and the translation return `.none`; `counters` returns `.init()`. (b′): remove the range check in `MeshCoreLinkPacing`, which gives bitrate 0 and `InterfaceProfile`'s precondition.

- [ ] **Step 5: Commit** `feat: MeshCoreEndpoint, interface id and profile`.

---

### Task 9: `TransportEndpoint` slot and limiter wiring

**Files:** Modify `Sources/ReTiCANode/TransportEndpoint.swift`. Test `Tests/ReTiCANodeTests/TransportEndpointMeshCoreTests.swift`, `MeshCoreSlotReplacementTests.swift`.

**Interfaces:**
- Consumes: Tasks 4, 8; `Transport.pathRequestDestinationHash` in tests via `@testable`.
- Produces: `TransportEndpoint.State.meshCore: MeshCoreEndpoint.State?` (new last `init` parameter, default nil), `.meshCore(_:)` factory, `Action.meshCore(MeshCoreEndpoint.Action)`.

| Line | Change |
|---|---|
| 43, 82–88, 106–109, 121 | slot, `init`, factory, action |
| 191 | `@Dependency(\.meshCoreDate) var meshCoreDate` |
| 205, 210 | start and stop merges |
| after 392 | `.meshCore(.interface(.delegate(...)))`: `.online` registers `registeredProfile(params:)` with `maintenanceStartEffect`, then `.radioOnline`; `.offline` deregisters from Transport and LinkPlane with `maintenanceStopEffect` only if registered, then `.radioOffline`; `.adapterUnavailable` to the hatch; `.packetReceived` below |
| 402, 431 | `transmit(&state, ...)` |
| 477, 487 | catch-all; `.ifLet(\.meshCore, action: \.meshCore) { MeshCoreEndpoint() }` |
| 525–547 | `_ state: inout State`, branch below, `sendFailed` guard |

The limiter runs only for a packet that would really go out:

```swift
let coreOwnsID = state.meshCore?.interfaceID == txID
if coreOwnsID, state.meshCore?.interface.isOnline == true {
    guard state.meshCore?.interface.limiter.admit(unmasked: unmasked, now: meshCoreDate()) == true
    else { return .none }
    return .send(.meshCore(.interface(.send(masked))))
}
// existing guard becomes: state.ble != nil || meshOwnsID || coreOwnsID
```

`.packetReceived` arm: `ifac = state.transport.interfaces[id]?.ifac`. If set, `plain = ifac.unprotect(packet)`. If not, `plain = packet` only when bit 7 of byte 0 is clear (`Transport.swift:558-565`). When non-nil, call `limiter.noteHeard` synchronously, then return `.send(.transport(.received(id, packet)))` with the original bytes, so the note precedes any path response.

- [ ] **Step 1: Write the failing tests.** Harness: private `makeMeshCoreEndpoint(profile:withTCPClient:liveDriver:)` as `TransportEndpointMeshtasticTests.swift:46-80`, with one `LockIsolated<Date>` driving `\.transportDate` and `\.meshCoreDate`, `$0.meshCoreClock = ImmediateClock()`, and `onAirPackets` reassembling through the codec. Builders: `makeAnnounce(hops:pathResponse:)`, `pathRequestPacket(requested:)` (with tag, control hash).

Suite `TransportEndpointMeshCoreTests`, same claims as the Meshtastic suite: `radioOnlineRegistersItsInterfaceWithTheParamsProfile`, `newParamsWhileOnlineReRegistersWithTheirBitrate`, `radioOnlineSurfacesOnTheMeshCoreHatch`, `radioDropDeregistersItsInterface`, `radioDropSurfacesOnTheMeshCoreHatch`, `endpointStopDeregistersTheRadio`, `endpointStopBeforeTheRadioConnectsSurfacesRadioOffline`, `endpointStopAfterARadioDropDeregistersTheRadioOnce`, `inboundDatagramsReachTheRouterTaggedWithTheRadioID`, `transmitToTheRadioIDPutsThePacketOnTheAir`, `transmitOverAnIFACRadioMasksBeforeSplitting`, `transmitWhileTheRadioIsOfflineReportsInterfaceUnavailable`, `missingLiveAdapterSurfacesOnTheMeshCoreHatch`; new `aMeshtasticAndAMeshCoreSlotRegisterSeparateInterfaces` (spec §6).

Suite `TransportEndpointMeshCoreMaintenanceTests`: `radioDropKeepsSharedMaintenanceAliveForTheTCPClient`, `radioAsTheLastInterfaceToDropStopsSharedMaintenance`, `radioLifecycleWithALiveTCPClientArmsMaintenanceOnce`.

Suite `TransportEndpointMeshCoreLimiterTests`, through `.transport(.delegate(.transmit(radioID, raw)))` unless stated:

| Test | Assertions |
|---|---|
| `limiterStateSurvivesTheTransmitCall`, `countersReachTheEndpointState` | same announce twice: 1 packet; `state.meshCore?.counters.announcesLimited == 1` |
| `announceAt600SecondsReachesTheRadio` | `now` +600: 2 packets |
| `limiterClassifiesTheUnmaskedPacketWithIFACOn` | IFAC, same announce twice: 1 packet, `announcesLimited == 1` |
| `hopCapIsReadFromTheUnmaskedPacketWithIFACOn` | IFAC, hops 3: 0 packets, limited 1; hops 2 fresh dest: 1 packet |
| `seventhRelayedAnnounceDoesNotReachTheRadio`, `thirteenthRelayedPathResponseDoesNotReachTheRadio`, `seventhPathRequestDoesNotReachTheRadio` | at one `now`: 6, 12, 6 packets; `pathRequestsLimited == 1` |
| `aggregateCapsHoldWithIFACOn` | 7 path requests, IFAC: 6 packets |
| `pathRequestIsKeyedOnTheRequestedDestinationAtTheEndpoint` | X, Y at +200 s: 2 packets |
| `limiterStateSurvivesARadioDrop`, `limiterStateSurvivesStopAndStart` | announce, drop or stop/start, same announce at the same `now`: 1 packet |
| `limitedPacketDoesNotReportSendFailed` | hops 3: no `.delegate(.sendFailed)` |
| `transmitWhileOfflineConsumesNoLimiterBudget` | offline at t, online at t+1: the announce goes out |
| `limiterDoesNotApplyToTheTCPInterface` | same announce at t, t+1 to the TCP id: 2 socket sends |
| `linkPlaneTransmitReachesTheRadioUnlimited` | `.linkPlane(.delegate(.transmit(...)))` link data ×10: 10 packets |
| `heardPathRequestLetsThePathResponseThrough`, `…WithIFACOn` | local dest announced at t, framed request `.datagram` at t+10: path response on the air, context `.pathResponse` |
| `pathRequestFailingIFACDoesNotOpenTheBypass` | IFAC; stamped dest; a plain, unprotected request arrives (what a stranger without the key can send); `.transmit` of that announce at +1 s: no second packet |
| `plainInterfaceIgnoresAnIFACFlaggedRequest` | no IFAC; bit 7 set: `heardEntryCount == 0` |

Suite `MeshCoreSlotReplacementTests`, mirroring `MeshtasticSlotReplacementTests.swift` with `MeshCoreRadioSlotHost`: `aReplacedSlotStartsOnlyAfterTheOldDriverStopped` (`[start A, stop, start B]`), `stopToANeverStartedSlotReportsRadioOfflineAtOnce`, `aStartReachingTheOldSlotMidStopNeverOverlapsTheNewRadiosStart`; new `removeThenStopReachesTheDriverInOrderBeforeTheSlotIsReplaced` (`[start A, removeChannel, stop, start B]`).

- [ ] **Step 2: Run; the build fails.** `swift test --package-path WT --filter TransportEndpointMeshCoreTests --filter TransportEndpointMeshCoreMaintenanceTests --filter TransportEndpointMeshCoreLimiterTests --filter MeshCoreSlotReplacementTests`

- [ ] **Step 3: Implement** per the table. Don't edit Meshtastic arms beyond the `inout` signature and the shared guard. Afterwards, `--filter TransportEndpointMeshtastic --filter MeshtasticSlotReplacementTests` stays green.

- [ ] **Step 4: Verify (a), (b), (c).** Mutations, one batch:

| Mutation | Breaks |
|---|---|
| **`admit(unmasked: masked, ...)`** | the IFAC tests |
| in the limiter, treat `elapsed == 0` as expired (state appears lost between same-instant calls) | `limiterStateSurvives…` (3), the three cap tests, `countersReachTheEndpointState` |
| `transmit` passes `now` at half speed (`Date(timeIntervalSince1970: meshCoreDate().timeIntervalSince1970 / 2)`) | `announceAt600SecondsReachesTheRadio` |
| key path requests on `destinationHash` | `pathRequestIsKeyedOnTheRequestedDestinationAtTheEndpoint` |
| limiter drop returns `.sendFailed` | `limitedPacketDoesNotReportSendFailed` |
| limiter before the online check; before the TCP branch for every id | `transmitWhileOfflineConsumesNoLimiterBudget`; `limiterDoesNotApplyToTheTCPInterface` |
| `.linkPlane` arm drops instead of calling `transmit` | `linkPlaneTransmitReachesTheRadioUnlimited` |
| invert the inbound gate: note only when `unprotect` fails, or, without IFAC, only when bit 7 is set | both `heardPathRequest…`, `pathRequestFailingIFACDoesNotOpenTheBypass`, `plainInterfaceIgnoresAnIFACFlaggedRequest` |
| `.send(unmasked)` to the interface; `.online` passes `.meshCore(params: nil)`; `sendFailed` guard omits `coreOwnsID`; `interfaceID` returns Meshtastic's id | the matching tests in `TransportEndpointMeshCoreTests` |
| `maintenanceStopEffect` omitted; start always arms; a surviving TCP client stops it | the maintenance suite |
| `MeshCoreInterface.stop` emits offline before `driver.stop()` returns | the slot replacement suite |

The IFAC row is the one that matters most: it is the exact bug the spec warns about in ScotMesh. If `aggregateCapsHoldWithIFACOn` or `hopCapIsReadFromTheUnmaskedPacketWithIFACOn` survives it, stop: they aren't exercising the unmasked path.

- [ ] **Step 5: Commit** `feat: TransportEndpoint MeshCore slot with limiter on the unmasked packet`.

---

### Task 10: Whole-slice probe

**Files:** Test `Tests/ReTiCANodeTests/MeshCoreWholeSliceTests.swift`. Shape: `MeshtasticWholeSliceTests.swift`.

Two `LXMFNode`s; `A.send` yields `.datagram` on B's stream and vice versa. `$0.continuousClock = TestClock()` (never advanced), `$0.meshCoreClock = ImmediateClock()`, `$0.date`, `$0.meshCoreDate`, `$0.uuid = .incrementing`. Distinct `selfPrefix`es. Every `receive` passes `timeout: .seconds(5)`.

- [ ] **Step 1: Write the tests**, suite `MeshCoreWholeSliceTests`. `runMeshCoreProbe(ifac:)` returns `(content, aOnAir)`.

| Test | Assertions |
|---|---|
| `opportunisticMessageCrossesAnOpenMeshCoreChannel` | `content == Data("hello over meshcore".utf8)` |
| `opportunisticMessageCrossesAnIFACProtectedMeshCoreChannel` | same, with `MeshCoreEndpoint.ifac(...)` |
| `ifacProtectedChannelCarriesOnlyIFACFlaggedPackets` | reassembled air non-empty, each `first & 0x80 == 0x80` |
| `everyDatagramOnTheAirFitsTheLimit` | each `count <= 162`, parses, `dst` zero |
| `aWholeSliceNeverSendsABindRequest` | no datagram is `.bindRequest` |

- [ ] **Step 2: Verify (a), (b), (c)** with `swift test --package-path WT --filter MeshCoreWholeSliceTests`. The production code exists, so "fail first" happens at (b). If a probe fails at (a), debug it; don't relax it. Mutations: reassembler returns nil at completion when `total > 1`; `TransportEndpoint` sends `unmasked` to the interface; `payloadSize = 149`; on `.connected`, enqueue a `.bindRequest`.

- [ ] **Step 3: Commit** `test: LXMF whole-slice probe over an in-memory MeshCore channel`.

---

### Task 11: Relay probe

**Files:** Test `Tests/ReTiCANodeTests/MeshCoreRelayProbeTests.swift`.

```
A: LXMFNode, MeshCore slot  <-- datagrams -->  R: TransportEndpoint, MeshCore slot + TCP client, relay on  <-- HDLC bytes -->  B: LXMFNode, TCP client
```

- Radio: each side's `driver.send` yields `.datagram` on the other's stream.
- TCP: `$0.tcpConnection = TCPConnection(open: { _, _ in own.stream }, send: { peer.yield(.data($0)) }, close: { })`, `reconnectOnDrop: false`. Bytes pass through framed. An injected announce uses `.data(HDLC.frame(raw))` (`TCPEndpointTests.swift:1631`).
- R: `$0.continuousClock = rClock` (a `TestClock`), `\.transportDate` and `\.meshCoreDate` from one `LockIsolated<Date>`, `$0.meshCoreClock = ImmediateClock()`, `.enableRelay(rIdentity)` before the interfaces come up. A and B keep never-advanced `TestClock`s. Radio params `sf7`, so bitrate 473 and pacing are real.
- R rebroadcasts only after jitter (≤ 0.5 s, `Transport.swift:789-793, 1521`) on `rClock`: `await rClock.advance(by: .seconds(1))`. The retry follows 5.5 s later and is then paced by `announcePacingWait`, about 155 s at 473 bps; tests about it advance both `rClock` and the date by 200 s.
- Use `receive` across stores only with `timeout: .seconds(5)`. Otherwise poll a private `meshCoreWaitUntil(timeout: .seconds(10)) { ... }` on mock state, with `await Task.megaYield()` between clock moves (`slotWaitUntil`, `MeshtasticSlotReplacementTests.swift:157`).
- Private `radioPackets` reassembles what R put on the air.

- [ ] **Step 1: Write the tests**, suite `MeshCoreRelayProbeTests`:

| Test | Assertions |
|---|---|
| `messageFromMeshCoreReachesTCPThroughTheRelay` | both register delivery; `rClock` fires so each learns the other via R; A opportunistic to B: content equal |
| `messageFromTCPReachesMeshCoreThroughTheRelay` | same, B to A |
| `announceAtTheHopCapReachesTheRadio` | TCP announce arriving at hops 1: one announce on the air, `hops == 2` |
| `announcePastTheHopCapDoesNotReachTheRadio` | arriving at hops 2: after `rClock` +1 s, `radioPackets == []`, `announcesLimited >= 1` |
| `relayedAnnounceIsNotRepeatedOntoTheRadio` | arriving at hops 0; +1 s, +200 s: one copy on the air, `announcesLimited == 1` |
| `distantDestinationIsReachableOnDemandThroughAPathRequest` | arriving at hops 3 (nothing on the air); A `.requestPath(dest)`: R answers with a path response, A gets `.pathLearned` |

- [ ] **Step 2: Verify (a), (b), (c)** with `swift test --package-path WT --filter MeshCoreRelayProbeTests`. Before (b), check for flakes: `swift test --package-path WT --filter MeshCoreRelayProbeTests --maximum-repetitions 5 --repeat-until fail`; fix any flake at its cause by polling, never by a longer sleep. Mutations: `.meshCore(... .packetReceived)` arm returns `.none` (message and on-demand tests); limiter `hops > 2` → `hops == 2` (both hop-cap tests; check a packet with `hops == 3` is on the air); `announceInterval = 0` (`relayedAnnounceIsNotRepeatedOntoTheRadio`).

- [ ] **Step 3: Commit** `test: MeshCore to TCP relay probe, both directions and past the caps`.

---

### Task 12: Whole-lane verification

**Files:** none changed unless something below fails.

- [ ] **Step 1: Full suite.** Run (timeout 600000): `swift test --package-path WT --skip nonImprovingFreshAnnounceIsStillRebroadcast`. Expected: no failures. Run: `swift test --package-path WT --filter nonImprovingFreshAnnounceIsStillRebroadcast`. Expected: passes alone; if it fails alone, that's new, so stop and diagnose.

- [ ] **Step 2: Meshtastic is untouched.** Expected for each: empty.

Run: `git -C WT diff --stat BASE -- Sources/ReTiCAInterfaces/Meshtastic Sources/ReTiCANode/MeshtasticEndpoint.swift Sources/ReTiCAMeshtasticLive Sources/ReTiCATransport`
Run: `git -C WT diff --stat BASE -- Tests/ReTiCAInterfacesTests/MeshtasticCodecTests.swift Tests/ReTiCANodeTests/TransportEndpointMeshtasticTests.swift Tests/ReTiCANodeTests/MeshtasticWholeSliceTests.swift`

- [ ] **Step 3: No GPL and no live-layer leakage.**

Run: `git -C WT ls-files Tests/ReTiCAInterfacesTests/Vectors`. Expected: no ScotMesh file.
Run: `grep -rn "class _Frame" WT/Sources WT/Tests`. Expected: no output.
Run: `grep -rln "import MeshCoreKit" WT/Sources WT/Tests`. Expected: no output.

- [ ] **Step 4: Branch state.** Run: `git -C WT status --short --branch`. Expected: on `feat/meshcore-interface`, clean, which holds only because Task 1's prerequisite committed `docs/`. Don't push or merge.

---

## Lane D hand-off

**Lane B ships no slot policy.** Contract 2's policy lives in `MeshCoreDriver.live(session:)`. Lane B's tests only prove the interface passes the mock's events through.

**Contract 3 surface lane D consumes:**

| Kind | Name | Lane D's use |
|---|---|---|
| State | `TransportEndpoint.State.meshCore`, `MeshCoreEndpoint.State(config:profile:)` | Install the slot. Profile: `.meshCore(params: nil)` plus `MeshCoreEndpoint.ifac(...)`, `mode` as wanted. `config` holds `Data()` for `channelSecret` and carries `canRoute`; lane D's driver wrapper fills the secret and `retiredChannelSecrets` at `driver.start`. |
| Action | `.meshCore(.start)`, `.meshCore(.stop)` | Normal lifecycle. To drop a slot: `.stop`, wait for `.radioOffline`, check `interface.isIdle` (not idle: send `.stop` again and wait for the next `.radioOffline`), then nil it. |
| Action | `.meshCore(.removeChannel)` | Feature off while connected: send it, wait for `.channelRemoved`, then `.stop`. A `.stop` sent early is held, so the order is safe either way. |
| Action | `.meshCore(.setCanRoute(Bool))` | Mirror the Relay setting at runtime. |
| Delegate | `.radioOnline(publicKey:params:)` | Online state, params. |
| Delegate | `.radioOffline(reason:)` | Offline state; slot-removal gate. |
| Delegate | `.adapterUnavailable(_)` | Shows `.other` text verbatim, including the no-free-slot and firmware messages. `.other` is non-terminal. |
| Delegate | `.retiredChannelsCleared` | Not used by the reducer. Lane D's driver wrapper forgets the retired keys when it sees the driver event, because only it knows which keys that start carried. |
| Delegate | `.channelRemoved(Bool)` | false means the slot stayed; tell the user. |
| Read | `state.meshCore?.counters`, `.interface.status`, `.interface.params` | `MeshCoreStatus`. Radio name, firmware code and channel slot aren't here: they reach the app through the `details` sink on `.live(session:details:)` (spec Contract 3). |

**Replacing the slot resets what must survive reconnects.** A new `TransportEndpoint.State.meshCore` starts with fresh limiter budgets and 600 s stamps, a new `nextPacketID`, an empty reassembler dedupe list and no `lastBindSent`. All of these survive drops and stop/start only. The Meshtastic wiring swaps its slot whenever `current.interface.config != wanted` (`ReTiCAMsgrCore/AppFeature+MeshtasticRadio.swift:45-84`). Copied as-is, every Connect or settings change would reset the airtime caps, which §5.5 forbids. So:
- Replace the slot only for a different radio, or for an IFAC change (`profile` is a `let`).
- Apply a key change by `.stop`, waiting for `.radioOffline` (and `isIdle`), then `.start` on the same slot. The driver wrapper fills the secret at `driver.start`.
- Apply Relay with `.setCanRoute`, never by restarting or replacing.
- Keep `channelSecret: Data()` and `retiredChannelSecrets: []` in the state's `config`, so comparing configs stays stable whatever the key store holds.

**The live driver must:**
- Run the slot policy after `.configured` and before `.connected`, and emit `.retiredChannelsCleared` before `.connected`.
- Filter `.datagram` to our slot and `dataType` for `0x1B`, and pass `0x84` pushes through unfiltered (§5.2 expects unrelated raw frames at the parser).
- Give a 4-byte `selfPrefix` from a correct `SELF_INFO`.
- Always return from `send`, `removeChannel` and `stop`. A `removeChannel` that hangs also holds any `.stop` behind it.
- Tolerate a `send` called while an earlier one is still waiting on the radio. A drop cancels the pacing effect but not a `driver.send` already in flight, so after a reconnect the next pump can call `send` while the old call is still running. Return false for that leftover call.
- Make a `stop()` called after `start()` win over whatever `start` spawned (`DriverEpoch.swift:16-19`).
- Ignore `config.canRoute`: the header is built in `MeshCoreInterface`.

**Tests lane D must add**, per §8's D row; lane B doesn't own them:
- Existing match, empty slot, all full.
- Removal, retired keys cleared and event emitted, and a slot holding any other secret is never cleared.

**Lane D also adds:** the `ReTiCAMeshCoreLive` target, the MeshCoreKit dependency, and the `pods/ReTiCA-worktrees/MeshCoreKit` symlink.

---

## Self-Review (done while writing; recorded for the executor)

- **Spec coverage:** Contract 2 → Task 1. Contract 3 → Tasks 8, 9. §5.1 → Tasks 2, 5. §5.2 → Task 6; rule 4 → Task 7. §5.3 → Task 7. §5.4 → Tasks 1, 7, and every table row in Tasks 1 and 8. §5.5 → Tasks 4, 5, 9, 11. §5.6 → Tasks 3, 5. §8: split sizes → Task 2; cross-validation → Task 5; reassembler list → Task 3; sender on `TestClock` → Task 7; limiter thresholds, IFAC and aggregates → Tasks 4, 9; slot policy → lane D hand-off; whole-slice → Task 10; relay probe → Task 11.
- **Step scan:** signatures, test names, assertions and spec values; bodies only for the `transmit` placement and the airtime formula.
- **Type consistency:** `admit(unmasked:now:)`, `noteHeard(unmasked:now:)`, `MeshCoreCounters`, `registeredProfile(params:)`, `meshCoreInterfaceID(radio:)`, `.channelRemoved(Bool)`, `.retiredChannelsCleared`, `.setCanRoute(Bool)`, `.datagramSent(ok:)`, `queuedDatagramCount` are the same in each task that uses them.
- **Review Focus:** five items, each with named tests in its owning task.
