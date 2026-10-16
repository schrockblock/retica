# Reticulum over Meshtastic — design

**Date:** 2026-10-16
**Status:** design approved in conversation; awaiting written-spec review
**Repos:** `pods/MeshtasticKit` (new), `pods/ReTiCA`, `apps/Meshtastified`, `apps/ReTiCAMsgr`

## 1. Goal

ReTiCAMsgr sends and receives LXMF messages through a Meshtastic node connected to the phone over
BLE, interoperating on the air with existing Python Reticulum nodes running
[landandair/RNS_Over_Meshtastic](https://github.com/landandair/RNS_Over_Meshtastic) (the de-facto
deployed implementation), with the fragment codec swappable so a sturdier format can be added later.

**Success criteria**

1. Codec output and reassembly are cross-validated by driving landandair's *actual* `PacketHandler`
   (not a hand-rolled re-implementation) — fixtures both directions.
2. A whole-slice probe: two `TransportEndpoint`s joined by an in-memory radio deliver an LXMF message.
3. On hardware: iPhone → Meshtastic radio → air → radio → Mac running `rnsd` + landandair's interface
   (and the reverse); then iPhone ↔ iPhone.
4. All existing test suites in all four repos stay green. At TCP/BLE bitrates the LXMF retry wait
   and responder link-establishment timeout are unchanged, and the initiator's is unchanged for
   paths of ≤ 1 wire hop (see Contract 4 — longer paths gain the reference's 6 s/hop allowance, a
   deliberate change).

**Non-goals (v1):** serial/TCP connection to the radio; rewriting the radio's modem preset; emitting
REQ (NACK) frames; direct-to-node (unicast) Meshtastic addressing; the floscodes framing (the seam
exists, the codec does not); RNode/KISS firmware; using Meshtastic `QueueStatus` for back-pressure;
running Meshtastified and ReTiCAMsgr against the same radio simultaneously (a radio accepts one BLE
client).

**Expectation setting:** effective throughput is ~25–500 B/s depending on preset. Single-packet LXMF
(opportunistic, ≤ 391 B encrypted → ≤ 3 fragments) is the target. Link-based delivery must work or
fail cleanly; it will be slow.

## 2. Background (read from source, 2026-10-15)

- **landandair** (`Interface/Meshtastic_Interface.py`, 426 lines, last real development Jul 2025):
  port `RETICULUM_TUNNEL_APP = 76`; always broadcast (the DM path at L290 is dead code — `is
  PacketHandler` compares an instance to the class); `wantAck=False`; `hop_limit` default 1;
  `channelIndex=0`; `DEFAULT_IFAC_SIZE = 8`; one writer thread, one fragment per
  `speed_to_delay[modem_preset]` seconds (L31-39, L278-304); rewrites the radio's modem preset on
  connect (L173-184) — **we do not**.
- **Meshtastic:** `DATA_PAYLOAD_LEN = 233`; the Python library rejects larger payloads. Port 76 is
  in Meshtastified's generated protobufs (`MeshProto/Generated/portnums.pb.swift:233`).
- **Meshtastified** (`MeshtastifiedKit`): BLE-only; handshake/drain/reconnect in
  `MeshDeviceClient/MeshSessionActor.swift:116-385`; send is hardwired to `TEXT_MESSAGE_APP`
  (`:294-322`); receive drops every port except TEXT and ROUTING (`MeshModels/MeshEvent.swift:50`).
- **ReTiCA:** interfaces are slots on `TransportEndpoint.State` (no protocol, by design —
  `AUTOINTERFACE.md`); `Packet.mtu = 500` is fixed stack-wide; `InterfaceProfile.hwMTU` is declared
  but never read; link establishment timeout is a fixed 15 s (`LinkSession.swift:135, 164`).
- **FCB:** the live `BluetoothCentralClient` is one process-wide `CentralActor` with a single
  `scanContinuation` — a new `scan` supersedes the previous one, which then never yields again
  (`FCB/Sources/FCBComposable/BluetoothCentralClient+Live.swift:7-12, 466-467`). Central `events()`
  is multi-subscriber and global across peripherals.

## 3. Architecture

```
pods/MeshtasticKit                 NEW package. deps: SwiftProtobuf, FCB, CoreBluetoothMock (mock only)
  MeshProto                        generated protobufs (moved from MeshtastifiedKit)
  MeshtasticKit                    MeshtasticSession actor, MeshtasticScanner, MeshGATT
  MeshtasticMock                   CoreBluetoothMock radio; ACKs any port

pods/ReTiCA
  ReTiCAInterfaces/Meshtastic/     codec, reassembler, sender queue, MeshtasticInterface reducer,
                                   MeshtasticDriver (closure struct; NO protobuf, NO MeshtasticKit)
  ReTiCANode/MeshtasticEndpoint    endpoint wrapper + TransportEndpoint slot
  ReTiCAMeshtasticLive             NEW target: MeshtasticDriver.live(session:) over MeshtasticKit.
                                   The ONLY ReTiCA code importing MeshtasticKit.

apps/Meshtastified                 moves onto MeshtasticKit; text/node-DB/storage stay in the app
apps/ReTiCAMsgr                    Settings section, radio picker, diagnostics, endpoint wiring
```

Data flow, outbound: LXMF → Transport → `TransportEndpoint` IFAC-mask (size 8) →
`MeshtasticEndpoint` → `MeshtasticInterface` (codec splits, queue paces) → `MeshtasticDriver.send`
(one fragment) → `MeshtasticSession.send(portnum 76, broadcast, channel, hopLimit)` → ToRadio.
Inbound is the reverse: FromRadio → `.packet(portnum 76)` → driver `.fragment(from:, data)` →
reassembler (keyed by sender node) → `.transport(.received(id, packet))`.

## 4. Contracts (fixed; each lane builds against these with a mock)

Contracts may only change by amending this spec. A lane that finds a contract unworkable stops and
raises it rather than diverging.

### Contract 1 — MeshtasticKit public API (lane A provides; lanes D, E consume)

```swift
public struct MeshtasticOutbound: Equatable, Sendable {
    public var portnum: UInt32
    public var payload: Data            // ≤ 233 bytes; send throws .payloadTooLarge otherwise
    public var to: UInt32 = 0xFFFF_FFFF // broadcast
    public var channel: UInt32 = 0
    public var wantAck: Bool = false
    public var hopLimit: UInt32? = nil  // nil: firmware default
}

public enum MeshtasticConnectionState: Equatable, Sendable {
    case disconnected(reason: String?), connecting, configuring, connected, reconnecting(attempt: Int)
}

public enum MeshtasticSessionError: Error, Equatable, Sendable { case payloadTooLarge, notConnected }

public enum MeshtasticAdapterUnavailable: Equatable, Sendable {
    case poweredOff, unauthorized, unsupported, other(String?)
    public var isTerminal: Bool   // unauthorized, unsupported
}

public enum MeshtasticEvent: Equatable, Sendable {
    case connection(MeshtasticConnectionState)
    /// Emitted once per completed want_config handshake (so again after every reconnect).
    case configured(myNodeNum: UInt32, modemPreset: Int?)   // raw Config.LoRaConfig.ModemPreset value
    /// Every decoded MeshPacket, any port. Encrypted/undecodable packets are not emitted.
    case packet(from: UInt32, to: UInt32, channel: UInt32, portnum: UInt32, payload: Data, id: UInt32)
    case routing(packetID: UInt32, ok: Bool)
    /// Every decoded FromRadio frame, unfiltered — for Meshtastified's node DB / channels / text.
    case frame(FromRadio)
    case adapterUnavailable(MeshtasticAdapterUnavailable)
}

public actor MeshtasticSession {
    public init(central: BluetoothCentralClient,
                clock: any Clock<Duration> = ContinuousClock(),
                packetID: @Sendable @escaping () -> UInt32 = { UInt32.random(in: 1 ... .max) })
    /// Connects via retrievePeripherals — NEVER scans, including on reconnect.
    public func connect(radio: UUID) async
    public func disconnect() async
    public func send(_ p: MeshtasticOutbound) async throws -> UInt32   // packet id
    public nonisolated func events() -> AsyncStream<MeshtasticEvent>  // multi-subscriber
}

public struct DiscoveredRadio: Equatable, Sendable, Identifiable { id: UUID; name: String?; rssi: Int }
public enum MeshtasticScanner {
    /// The only scanning entry point. Supersedes any other FCB scan in the process while iterated.
    public static func scan(central: BluetoothCentralClient) -> AsyncStream<DiscoveredRadio>
}
```

Requirements: platforms **iOS 17, macOS 13, macCatalyst 17** (ReTiCA's floor; MeshtastifiedKit is
macOS 14 today — SPM rejects a dependency with a higher floor). The session filters FCB's global
`events()` to its own radio's peripheral id. Reconnect backoff (1→30 s capped) is preserved.
All public types get public memberwise-style inits. `connect(radio:)` emits `.connecting` first and
returns once the first attempt resolves; a non-terminal first-attempt failure enters the backoff;
CoreBluetooth connects never time out, so callers invoke it from a Task. The want_config handshake
has a **30 s timeout** (no `config_complete` → treat as a lost link → backoff). Every MeshPacket
also arrives as `.frame`; a consumer maps **either** `.frame` **or** `.packet`/`.routing`, never both
(Meshtastified maps `.frame`; ReTiCA's live adapter maps `.packet`). `myNodeNum` is 0 if the radio
sent no `myInfo`; `modemPreset` is the raw value even when `use_preset` is false.

### Contract 2 — ReTiCA `MeshtasticDriver` (lane B consumes via mock; lane E implements live)

`Sources/ReTiCAInterfaces/Meshtastic/MeshtasticDriver.swift`, same pattern as `BLEDriver`:

```swift
public struct MeshtasticDriverConfig: Equatable, Sendable {
    public var radio: UUID
    public var channel: UInt32 = 0
    public var hopLimit: UInt32 = 1
}

public enum MeshtasticDriverEvent: Equatable, Sendable {
    case connected(myNodeNum: UInt32, modemPreset: Int?)
    case disconnected(reason: String?)
    /// A port-76 payload from another node. The live adapter has already dropped from == myNodeNum.
    case fragment(from: UInt32, Data)
    case unavailable(BLEAdapterUnavailable)
}

public struct MeshtasticDriver: Sendable {
    public var start: @Sendable (MeshtasticDriverConfig) -> AsyncStream<MeshtasticDriverEvent>
    /// One already-framed fragment, sent on port 76 to broadcast with the config's channel/hopLimit,
    /// wantAck false. Returns false if the radio is not connected or the write failed.
    public var send: @Sendable (Data) async -> Bool
    public var stop: @Sendable () async -> Void
}
// DependencyKey: liveValue emits a single .unavailable(.other("ReTiCAMeshtasticLive not installed"))
// and finishes — loud, never a silent no-op. testValue: unimplemented. Key path \.meshtasticDriver.
```

The app installs the real driver with `$0.meshtasticDriver = .live(session:)` from
`ReTiCAMeshtasticLive`. Reconnect is MeshtasticKit's job; the interface just sees repeated
`connected`/`disconnected`.

### Contract 3 — ReTiCA endpoint surface (lane B provides; lane E consumes in the app)

- `TransportEndpoint.State.meshtastic: MeshtasticEndpoint.State?`; action
  `TransportEndpoint.Action.meshtastic(MeshtasticEndpoint.Action)` with `.start` / `.stop`.
- `MeshtasticEndpoint.State(config: MeshtasticDriverConfig, profile: InterfaceProfile)`.
- One interface id per radio: `meshtasticInterfaceID(radio: UUID) -> InterfaceID` = `"meshtastic:<uuid>"`.
  Registered with `.interfaceConnected(id, profile)` on driver `.connected`, `.interfaceDisconnected`
  on `.disconnected` — the TCP-client lifecycle, not BLE's per-peer one.
- Delegates: `.radioOnline(myNodeNum:, modemPreset:)`, `.radioOffline(reason:)`,
  `.adapterUnavailable(BLEAdapterUnavailable)`.
- `public struct MeshtasticCounters: Equatable, Sendable` with Int fields `malformed, evicted,
  timedOut, oversize, completed, queueFull, sendFailed`, readable as
  `MeshtasticEndpoint.State.counters` (no delegate; the app reads state).
- `InterfaceProfile.meshtastic(modemPreset: Int?) -> InterfaceProfile`: `name "meshtastic"`,
  `hwMTU 500`, IFAC size 8 when IFAC is configured, mode = same default as `.tcp`, and **bitrate =
  effective paced rate** `Int(202 * 8 / fragmentDelay(preset))`:

  | preset (raw) | delay s | bitrate |
  |---|---|---|
  | ShortTurbo (8) | 0.4 | 4040 |
  | ShortFast (6) | 1 | 1616 |
  | ShortSlow (5) | 3 | 538 |
  | MediumFast (4) | 4 | 404 |
  | MediumSlow (3) | 6 | 269 |
  | LongFast (0) | 8 | 202 |
  | LongModerate (7) | 12 | 134 |
  | LongSlow (1) | 15 | 107 |
  | anything else / nil | 7 | 230 |

  The delays are landandair's `speed_to_delay` verbatim, including its fallback of 7.
  Because the preset is only known after `.connected`, the profile is computed there; the endpoint
  state's `profile` supplies only IFAC and mode. The preset→delay table lives in
  `ReTiCAInterfaces/Meshtastic/MeshtasticModemPreset.swift` (the interface's pacer needs it) and the
  `InterfaceProfile.meshtastic(modemPreset:)` extension lives in `ReTiCANode/MeshtasticEndpoint.swift`
  — `ReTiCATransport` and `ReTiCAInterfaces` don't depend on each other, so `InterfaceProfile.swift`
  is not touched. IFAC for this interface is built with `MeshtasticEndpoint.ifac(networkName:passphrase:)`
  (fixed size 8; `IFAC.size` is private), so a network using a larger landandair `ifac_size` is not
  supported in v1 (and the 508 B reassembly bound follows from size 8).
- There is no slot-removal action: to drop the radio, lane E sends `.meshtastic(.stop)`, waits for
  `.radioOffline`, then sets the slot to nil — nil-ing an online slot leaves its interface
  registered in Transport.
- `.adapterUnavailable(.other(_))` is non-terminal by `BLEAdapterUnavailable.isTerminal`, including
  the uninstalled-live-driver message; the app must not read "non-terminal" as "installed".

### Contract 4 — slow-link timing (lane C provides; nothing in lane B depends on it)

Behavioural contract; lane C owns the mechanism. `b` = bitrate of the next-hop interface for the
destination (reference `Transport.next_hop_interface_bitrate`); `b_recv` = bitrate of the interface a
LINKREQUEST arrived on; `h = max(1, hops)` where `hops` is ReTiCA's stored **on-wire** count
(directly heard = 0; the reference increments on receipt, ReTiCA does not — `Transport.swift:1248-1250`).
This is the same `max(1, wire)` convention ReTiCA's other per-hop timers use (`Transport.swift:757,
1009`), so a relayed peer gets one hop less allowance than the reference would give it, consistently.

| value | today | new | at TCP/BLE |
|---|---|---|---|
| initiator link establishment | 15 s | `max(15, 500·8/b + 6 + 6·h)` (reference `Link.py:282-283` + floor) | 15 for wire hops ≤ 1; ≈18 / 24 / … for 2 / 3 / … |
| responder link establishment | 15 s | `max(15, 2 · 500·8/b_recv + 6)` — **no hop term** | 15 (unchanged) |
| relay link-table proof deadline | `6·h` | `6·h + 500·8/b_recv` — the interface the LINKREQUEST **arrived on** (reference `extra_link_proof_timeout(packet.receiving_interface)`, `Transport.py:1643-1644`) | +0.0004 s / +0.05 s |
| LXMF retry wait | 10 s | `max(10, 4 · 500·8/b)`, rounded up to whole seconds | 10 (unchanged) |
| local re-announce on interface-up | all interfaces | **only the interface that came up** | — |

The multi-hop initiator growth at fast bitrates is intended (the reference's per-hop allowance, which
the fixed 15 s lacks); lane C's tests must pin both the unchanged and the multi-hop values.

Deliberate deviations from the reference, recorded so they are not "fixed" later: the responder
timeout has **no hop term** and no KEEPALIVE (reference: `6·h + KEEPALIVE` ≈ 366 s) because a
LINKREQUEST's `hops` is unauthenticated — an attacker could set it to 255 and pin each of the 32
half-open responder slots (`LinkPlane.swift:73`) for minutes, defeating the 2026-08-13 lifecycle
slice's admission budget. It depends only on our own receiving interface's bitrate (two first-hop
packet times + 6 s); the LXMF retry wait scales (the reference's `DELIVERY_RETRY_WAIT` is a fixed 10 s), because
at ~200 bps a 391 B packet is ~24 s of airtime and a 10 s retry stacks duplicates. Local announces
and path requests are otherwise **not** paced — matching the reference (`Transport.py:1271-1274`:
locally originated announces bypass the cap; path requests are paced only when recursive).

Mechanism required: `Transport.Action.announce(destinationHash:appData:interface: InterfaceID? = nil)`
(nil = all interfaces, today's behaviour), and a query for the next-hop interface profile that
LinkPlane and the LXMF node can use.

## 5. Lane B internals — codec, reassembly, sender

### 5.1 Codec (`MeshtasticFragmentCodec` protocol; `LandandairCodec` is the v1 implementation)

```swift
public protocol MeshtasticFragmentCodec: Sendable {
    func split(_ packet: Data, index: UInt8) -> [Data]          // framed fragments, in order
    func parse(_ frame: Data) -> MeshtasticFrame?               // nil = malformed
}
public enum MeshtasticFrame: Equatable { case data(index: UInt8, pos: Int8, body: Data)
                                         case request(index: UInt8, pos: Int8) }
```

landandair format, byte-exact:
- Data frame: `[index: UInt8][pos: Int8][body]`. `pos` is 1-based; the **last** fragment's `pos` is
  negated; a single-fragment packet has `pos = -1`. `index` is a per-interface counter, `(i+1) % 256`.
- Split: `n = len / 200 + 1`; `size = len / n + 1`; body chunks are `data[i ..< i+size]` stepping by
  `size`. (500 B → 167/167/166; 199 B → one chunk; 508 B with IFAC-8 → 3 chunks.)
- REQ frame: ASCII `"REQ"` + `[index][pos]` (5 bytes). A data frame can only look like a REQ if
  `index = 0x52` and `pos = 0x45 = 69`, i.e. ≥ 69 fragments — impossible for packets ≤ 508 B, so
  `parse` treats a `"REQ"` prefix with total length exactly 5 as a request, everything else as data.
- `parse` returns nil for: length < 3 (data needs ≥ 1 body byte), `pos == 0`, length > 233.

### 5.2 Reassembler (`MeshtasticReassembler`, pure value type; NOT `BLEReassembler`)

`BLEReassembler` keys buffers by fragment count only, so two interleaved packets from one sender with
equal counts corrupt each other; it is not reused.

- Buffers keyed by `(from: UInt32, index: UInt8)`; each holds `[pos: body]` and `lastActivity`.
- Insert `pos` as `abs(pos)`. If a different body already exists at that position, restart the
  buffer with only the new fragment.
- A buffer completes when it holds a negative `pos` = `-n` and keys exactly `1...n`, checked on
  every insert; then emit concatenated bodies and drop the buffer. If incomplete, keep it until
  timeout, so a late middle fragment can still finish it. This is **stronger than landandair**, which
  only assembles when the arriving fragment is the negative one (`Meshtastic_Interface.py:380-387`);
  the cross-validation fixture pins the difference.
- Bounds: 30 s inactivity purge; ≤ 8 buffers per sender and ≤ 64 total, oldest-activity evicted;
  reassembled packet > 508 B dropped. Purge runs on each insert using the injected date
  (`\.bleDate` pattern — a `\.meshtasticDate` key).
- Counters (for diagnostics): `malformed`, `evicted`, `timedOut`, `oversize`, `completed`.

### 5.3 Sender (inside `MeshtasticInterface`)

- FIFO of framed fragments, cap **256** (landandair's cap). Packet enqueue is all-or-nothing: if
  its fragments don't fit, the whole packet is dropped and `queueFull` counted.
- One fragment per `fragmentDelay(preset)` on an injected clock: send immediately when idle, then
  wait the delay before the next (landandair sleeps after every send; we don't delay the first).
- REQ answering: retain the framed fragments of the last **16** packets sent, keyed by index. A REQ
  for a retained `(index, abs(pos))` that is **not already queued** puts it at the **front** of the
  queue (already-queued → ignored, which bounds REQ-driven growth by the cache size; not counted
  against the cap). Unknown index: ignore. We never emit REQ.
- `send` returning false: count `sendFailed`, drop that fragment, continue.
- `.disconnected`: clear the queue and all reassembly buffers; keep the REQ cache; cancel the
  pacing timer. `.connected` again: recompute profile from the new preset, re-register.

### 5.4 Endpoint wiring (`TransportEndpoint`)

Touch points (all within `TransportEndpoint.swift` unless noted): state slot + init/factory; action
case; `.start`/`.stop` merges; connected/disconnected/received arms; the catch-all `case
.tcpClients, .tcpServer, .ble` arm; `.ifLet`; `transmit(_:to:...)` routing to the meshtastic slot by
interface id; the `.sendFailed(.interfaceUnavailable)` guard (today `state.ble != nil` only) extended
to cover the meshtastic slot. Shared maintenance start/stop goes through the existing shared
interface count (see the multi-interface lesson: never per-driver).

## 6. Lanes and parallel execution

| Lane | Worktree (path depth matters — see below) | Builds against | Starts |
|---|---|---|---|
| **A** MeshtasticKit + Meshtastified migration | new repo `pods/MeshtasticKit`; Meshtastified worktree at `apps/Meshtastified-meshtastickit` | — | now |
| **B** codec, reassembler, interface, endpoint | `pods/ReTiCA-worktrees/meshtastic-interface` | Contract 2 (mock) | now |
| **C** slow-link timing | `pods/ReTiCA-worktrees/slow-link-timing` | existing `InterfaceProfile.bitrate` | now |
| **D** ReTiCAMsgr UI (no new ReTiCA symbols) | `apps/ReTiCAMsgr-meshtastic` | `RadioScanner` client (own stub) | now |
| **E** live adapter, app wiring, hardware | ReTiCA + ReTiCAMsgr | A, B, C, D merged | last |

**Worktree path depth:** relative package paths must still resolve from the worktree. ReTiCA uses
`../FCB` — `pods/ReTiCA-worktrees/FCB` is already a symlink to `pods/FCB`; lane E adds
`pods/ReTiCA-worktrees/MeshtasticKit → pods/MeshtasticKit` alongside it. ReTiCaMsgrCore uses
`../../../pods/ReTiCA` and MeshtastifiedKit uses `../../../pods/FCB`, so app worktrees must be
**siblings of the app directory** (`apps/<App>-<topic>`), not nested under a `-worktrees` folder.

**File ownership** (to keep merges mechanical):
- B owns: `ReTiCAInterfaces/Meshtastic/*` (new), `ReTiCANode/MeshtasticEndpoint.swift` (new),
  `ReTiCANode/TransportEndpoint.swift`, new test files and
  fixture resources, the `ReTiCAInterfacesTests` resources line in `Package.swift`.
- C owns: `LinkSession.swift`, `LinkPlane.swift`, `Transport.swift`, `LXMFRouter.swift`,
  `LXMFDelivery.swift`, `LXMFNode.swift`. In `TransportEndpoint.swift` C may touch only the
  `.openLink` and `.linkRequest` arms and add one new `announceOn` action case + arm (a new case, not
  a parameter on `.announce`, so the 12 existing `.endpoint(.announce(_, appData))` test matches stay
  intact); none of these overlap §5.4. C rebases onto main after B merges.
- D owns: ReTiCAMsgr files only; it must not reference `TransportEndpoint.State.meshtastic` or any
  other lane-B symbol.
- E owns: `Package.swift` dependency on `../MeshtasticKit` + the `ReTiCAMeshtasticLive` target;
  `syncEndpointNodes`/`redialDownNodes`/"will something dial" checks in the app; the app's
  `interfaceConnected` re-announce switching to Contract 4's targeted announce.

Merge order is free among A–D (each merges to main when green); E rebases onto all four.
Commits go straight to main in each repo (no feature-branch merge dance).

## 7. Lane D and E details

**Lane D (ReTiCAMsgr, independent of new ReTiCA symbols):**
- Settings: `@Shared(.appStorage)` `meshtasticEnabled: Bool = false`, `meshtasticRadioID: String?`
  (UUID string), next to `bleEnabled` (`AppFeature.swift:257`). New "Meshtastic" section in
  `SettingsView.swift` after the Bluetooth section: toggle, selected radio row, "Choose radio…".
  Channel 0 and hop limit 1 are fixed in v1 (landandair defaults).
- Radio picker sheet driven by a `RadioScanner` dependency client in ReTiCaMsgrCore
  (`scan() -> AsyncStream<RadioScanResult>`); D ships `testValue` + a preview value; E adds the live
  value over `MeshtasticScanner`. Rows tappable across the full width (`.frame(maxWidth: .infinity,
  alignment: .leading).contentShape(Rectangle())`).
- Also persists `meshtasticRadioName: String?` so the Settings row shows a name after relaunch.
- **Scan ownership:** while the picker is presented, if the BLE slot **exists and is running**
  (starting / online / waiting-for-adapter — *not* keyed on `bleEnabled`, which only takes effect at
  Connect, and never sending to an absent slot, which trips `.ifLet`), the app stops BLE and restarts
  it on every exit (swipe, cancel, pick); `redialDownNodes` gets one guard so a foreground/push wake
  doesn't restart BLE mid-picker (lane D adds that one guard in a lane-E-owned function; E merges
  around it). FCB has one scan per process (§2).
- Diagnostics: a Meshtastic layer modelled on `bleLayer` (`DiagnosticsSnapshot.swift:148-164`) fed
  from a plain app-side `MeshtasticStatus` (online, preset, node number, offline reason, adapter
  unavailable, and the seven counters) that E populates — counters from the public
  `MeshtasticEndpoint.State.counters: MeshtasticCounters` (Contract 3), the rest from its delegates.
- Merging D before E ships a toggle that only shows "radio not connected" in Diagnostics. Accepted.

**Lane E (integration):**
1. `ReTiCAMeshtasticLive`: `MeshtasticDriver.live(session:)` — maps `.configured` → `.connected`,
   connection loss → `.disconnected`, `.packet(portnum 76, from ≠ myNodeNum)` → `.fragment`,
   adapter → `.unavailable`; `send` → `session.send(MeshtasticOutbound(portnum: 76, …))`.
   Loopback test against `MeshtasticMock` (live value, not a mock of it — the mocked-boundary lesson).
2. **Coexistence probe** (first, before app wiring): RBTP `BLEDriver` and `MeshtasticSession`
   running on the one live FCB central — disconnect events filtered per peripheral, no scan
   interference after the picker closes. **Known race to fix:** BLE stop is fire-and-forget and the
   FCB driver adapter's stop always ends with `central.stopScan()` (`FCBDriverAdapter.swift:273-276`),
   which ends *whatever* scan is current (`BluetoothCentralClient+Live.swift:228-231`) — so a slow
   BLE stop (peers connected) can kill the picker's scan that just started. Fix in FCB by making
   `stopScan` token-scoped (stop only the caller's own scan), with a probe that reproduces the race
   first.
3. App wiring: slot in `syncEndpointNodes`, restart in `redialDownNodes`, "will something dial"
   checks, delegates → diagnostics state, live `RadioScanner`, targeted re-announce (the app's
   `interfaceConnected` handler sends lane C's `LXMFNode.Action.announceDeliveryOnInterface(id)`,
   which rides `TransportEndpoint.Action.announceOn(interface:destinationHash:appData:)`).
4. Hardware verification per §1 criterion 3, recorded with the radio model, firmware version and
   preset used.

## 8. Testing

- **A:** existing MeshtastifiedKit session/mock tests move with the code; new tests for arbitrary-port
  send/receive, `.configured` carrying the preset, payload > 233 rejected, connect-without-scan;
  Meshtastified's suite stays green after migration.
- **B:** codec unit tests (split sizes at 1, 199, 200, 201, 400, 500, 508 B; REQ parse; malformed);
  **cross-validation driving landandair's `PacketHandler`** in the conda `rns` env (`python`, not
  `python3`) — generator script committed under `Tests/…/Vectors/` alongside its fixture, both
  directions (their split → our reassemble; our split → their reassemble); reassembler property tests
  (interleaved senders, interleaved indices from one sender, reordering, duplicates, conflicting
  body, timeout, eviction); interface reducer with a mock driver (pacing on `TestClock`, REQ answer
  jumps queue, queue-full drop, disconnect clears); **whole-slice probe** — two `TransportEndpoint`s
  with mock drivers cross-wired as one broadcast medium deliver an LXMF opportunistic message.
- **C:** at `.tcp`/`.ble` profiles: LXMF retry = 10 s at every hop count, initiator establishment =
  15 s at wire hops 0 and 1, responder = 15 s at any `packet.hops` including 255, and the multi-hop
  initiator values in Contract 4's table; stretched values at 202 bps; relay proof deadline gains
  the arrival-interface term; targeted announce goes out only the named interface.
- **D:** TCA tests (non-exhaustive, outcome-asserting) for toggle persistence, picker selection,
  BLE pause/resume around the picker.
- **E:** live-adapter loopback, coexistence probe, hardware runs.

All lanes follow the user's test-verification rule: pass → mutate production code so the new tests
fail → revert → pass, before committing.

## 9. Risks

- **Real-world throughput** on LongFast may be too poor even for opportunistic delivery once
  rebroadcasts and channel utilisation are counted. Mitigation: recommend Short presets in the UI
  copy; measure in lane E.
- **landandair dormancy / format drift.** Mitigated by the codec seam.
- **iOS background BLE:** Meshtastic radio traffic while the app is backgrounded depends on
  bluetooth-central background mode (already declared) and state restoration; out of scope for v1
  beyond "doesn't crash" — measure in E.
- **Firmware duty-cycle limits** (e.g. EU 10%/hour) can silently refuse sends; surfaced only as
  `routing` NAKs we don't request. Accepted for v1.
