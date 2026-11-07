# Reticulum over MeshCore — design

**Date:** 2026-11-07
**Status:** direction approved in conversation; written spec awaiting review
**Repos:** `pods/MeshCoreKit` (new), `pods/ReTiCA`, `apps/Meshtastified`, `apps/ReTiCAMsgr`
**Modelled on:** `2026-10-16-meshtastic-interface-design.md`. Read it first: its contracts, stop
semantics, FCB scan rules and slow-link timing (its Contract 4) all apply here unless this document
says otherwise.

## 1. Goal

ReTiCAMsgr sends and receives LXMF messages through a MeshCore companion radio connected to the phone
over BLE, on stock firmware, and interoperates on the air with Reticulum nodes running ScotMesh's
`MeshCore_Raw_Interface`. With the app's Relay setting on, it bridges MeshCore and TCP, as Meshtastic does
today (decided by the user, conditional on that parity, which the code confirms: `MeshtasticEndpoint` registers
in `.full` mode, so the Relay setting already bridges it, and its hardware checklist has a gateway test (c)).

Why ScotMesh's format: about ten Reticulum-over-MeshCore projects exist, in at least five incompatible
formats, none dominant. ScotMesh Raw is the one built on MeshCore's binary primitives. It needs half
the fragments of the text formats, it solves the no-sender-identity problem, and it has tests and a real
deployment. Adding a second implementation also helps it become a standard rather than adding a seventh
format.

**Success criteria**

1. Codec output and reassembly are cross-validated by driving ScotMesh's actual `_Frame` class, both
   directions, with fixtures. Companion frames are cross-checked against `meshcore_py`'s parsers.
2. A whole-slice probe: two `TransportEndpoint`s joined by an in-memory channel deliver an LXMF message.
3. On hardware, when a radio is available: iPhone → radio → air → radio → Mac running `rnsd` with
   `MeshCore_Raw_Interface`, and the reverse; then iPhone ↔ iPhone through a repeater.
4. All existing suites in all four repos stay green, and Meshtastic behaviour is unchanged.

**Non-goals (v1):**
- Routed unicast raw sends, path discovery, path learning from push `0x88`, and adding MeshCore contacts.
- Sending by zero-hop raw. We receive raw but only send on the channel; see §8 for the follow-up.
- Flood scopes (`CMD_SET_FLOOD_SCOPE`).
- The text formats (Dynamic and the others). The codec seam leaves room for them.
- KISS modem firmware, which is serial-only and unusable from an iPhone.
- Serial or TCP connections to the radio.
- Changing the radio's LoRa settings.
- Polling `CMD_GET_STATS` for pacing.
- Running official MeshCore apps or Meshtastified against the same radio at once.

**Anti-goals, failures even if everything technically works:**
- Flooding a shared community mesh. ScotMesh recorded about 30 announce packets a minute on a real
  community channel from a transport node in the wrong mode, and MeshCore's maintainers say it "was not
  designed to transfer arbitrary network traffic".
- Overwriting a channel the user already configured on their radio.
- Shipping any GPL code in the app. `comms-engineer` and ScotMesh are GPL-3.0, and RetiOS keeps its
  MeshCore build outside the App Store for this reason. We implement the format from this document.
  GPL code may only run in the dev-time fixture generator, and is never linked or copied.
- Exposing this in a Release build before it has run on hardware (§7).

**Expectation setting:** one field report for a different format gives 391 bps at 0 hops and 143 bps at
2 hops. Plan for a few hundred bps, and for opportunistic LXMF as the target. Link delivery must work or
fail cleanly.

## 2. Background (read from source, 2026-11-07)

**Sources.** The research clones are in `/tmp/ReTiCaMsgr/research/` and may not survive; re-clone at
these commits.
- Firmware: `meshcore-dev/MeshCore` at `81dbae5` (`companion-v1.18.0`). `MyMesh.cpp` below means
  `examples/companion_radio/MyMesh.cpp`.
- ScotMesh: `ScotMesh/RNS_Over_Meshcore` at `2167780` (2026-09-19), `Interface/MeshCore_Raw_Interface.py`.

**Firmware facts this design relies on:**
- `CMD_SEND_CHANNEL_DATA` (62): `3E chan 0xFF type_lo type_hi payload`. Flood when path byte is `0xFF`.
  Payload limit 165 at ≥ v1.16, 163 at v1.15. Reply is `RESP_CODE_OK`, which means queued, not sent.
- Receive: `RESP_CODE_CHANNEL_DATA_RECV` (27), `1B snr 0 0 chan path_len type_lo type_hi len payload`.
  It is queued on the radio: the radio pushes `0x83`, then the app drains with `CMD_SYNC_NEXT_MESSAGE`.
  It carries no sender identity.
- `PUSH_CODE_RAW_DATA` (`0x84`): `84 snr rssi FF payload`, connected phones only, not queued, no sender
  identity, no contact check (`src/Mesh.cpp:292-298`).
- Channel hash is derived only from the secret (`BaseChatMesh.cpp:939`), so slot index and channel name
  are local to each radio. ScotMesh's README says all three must match; only the secret must.
- `RESP_CODE_SELF_INFO` (`MyMesh.cpp:1085-1116`): code(1) adv_type(1) tx(1) max_tx(1) **pubkey(32 at
  byte 4)** lat(4) lon(4) multi_acks(1) loc_policy(1) telemetry(1) manual_add(1) **freq_khz(4 at 48)
  bw_hz(4 at 52) sf(1 at 56) cr(1 at 57) name(from 58)**. All little-endian.
- BLE: Nordic UART service; one write or notification is one frame. Treat **173 B** as the frame limit
  (MTU 176, unverified above that on ESP32). Writes `.withResponse`. ESP32 queues only 4 frames each way
  and nRF52 can merge back-to-back writes, so: one command, wait for its reply.
- The radio's packet pool is 16, shared by TX and RX. When empty, sends return `ERR_CODE_TABLE_FULL` and
  received packets are dropped.
- Dedupe: a byte-identical resend is dropped by any radio that has seen it, until 160 newer packets
  pushed it out of the ring (`SimpleMeshTables.h:9`, `Packet.cpp:41-50`). So blind retransmits are mostly
  wasted airtime.
- Repeaters flood `GRP_DATA` without decrypting, but operators may deny unscoped floods, so reach is not
  guaranteed on every mesh.
- Service UUID is advertised on ESP32 and nRF52, so scanning by service works.
- Tunnel data, DMs and channel text share one offline queue (16 entries by default). Reading a message deletes
  it (`MyMesh.cpp:248-260`). When full, a new message evicts the oldest channel-class message, and `0x1B` counts as
  channel-class (`MyMesh.cpp:219-239`). So a client that drains the queue destroys text waiting for other apps, and
  any slot holding our key keeps feeding that queue. The user has accepted this, with a warning (§6).

**Meshtastified's existing client, which this design moves and fixes:**
- `MeshCoreFrame.swift:88-92` decodes `SELF_INFO` wrongly: key from bytes 1–32, everything after as name.
  On a real radio the identity and name are both wrong. Its mock and tests share that assumption, so they
  pass anyway.
- Per the audit, `syncDrain` waits only for `0x0A`, `0x10`, `0x11`, so a `0x1B` stalls it for 5 s. Any
  neighbour's channel datagram can then fail a connect attempt. This must be fixed for us to receive at all.
- Reconnect lacks what MeshtasticKit gained: first-connect retry, Bluetooth power-cycle handling, an
  epoch guard, a powered-on gate.
- `sendDirectText` sends the 32-byte key, but firmware reads a 6-byte prefix and takes the rest as text
  (`MyMesh.cpp:1139-1143`), so recipients get 26 key bytes before the message. Channel text is sent as `Name: text`,
  and firmware adds the name itself (`BaseChatMesh.cpp:523`), so it's doubled. Lane A fixes both; they're exceptions
  to its "keep current behaviour" rule.
- It has never run on a real radio, as far as the docs record. Its reference targets v1.16.0 and has known
  errors (it says Meshtastic uses the same UUIDs; it does not).

## 3. Architecture

```
pods/MeshCoreKit                   NEW repo and package. deps: FCB, CoreBluetoothMock (mock only)
  MeshCoreKit                      MeshCoreSession actor, MeshCoreScanner, MeshCoreGATT, MeshCoreFrame
  MeshCoreMock                     CoreBluetoothMock companion, rebuilt from firmware source

pods/ReTiCA
  ReTiCAInterfaces/MeshCore/       codec, reassembler, sender queue, announce limiter, MeshCoreInterface,
                                   MeshCoreDriver (closure struct; NO MeshCoreKit import)
  ReTiCANode/MeshCoreEndpoint      endpoint wrapper + TransportEndpoint slot
  ReTiCAMeshCoreLive               NEW target: MeshCoreDriver.live(session:). The ONLY ReTiCA code
                                   importing MeshCoreKit.

apps/Meshtastified                 moves onto MeshCoreKit; contacts, DM and text policy stay in the app
apps/ReTiCAMsgr                    Settings section, radio picker, channel key, diagnostics, wiring
```

MeshCore code goes in new files. Do not refactor `ReTiCAInterfaces/Meshtastic/` to share code with it in
v1; a mechanical duplicate is cheaper than risking a working interface. (My call.)

Data flow, outbound: LXMF → Transport → `TransportEndpoint` (limiter reads the unmasked packet, then IFAC
mask, size 8) → `MeshCoreInterface` (codec splits, queue paces) → `MeshCoreDriver.send` (one tunnel frame) →
`MeshCoreSession.sendChannelData` → radio. Inbound: `0x1B` via sync drain, or `0x84` push → driver
`.datagram` → codec parse and address filter → reassembler keyed by `(src, pktID)` →
`.transport(.received(id, packet))`.

## 4. Contracts

As in the Meshtastic spec: contracts change only by amending this document, and a lane that finds one
unworkable stops and raises it.

### Contract 1 — MeshCoreKit public API

```swift
public struct MeshCoreRadioInfo: Equatable, Sendable {
    public var publicKey: Data      // 32 bytes, SELF_INFO byte 4
    public var name: String         // from byte 58
    public var frequencyKHz: UInt32
    public var bandwidthHz: UInt32
    public var spreadingFactor: UInt8
    public var codingRate: UInt8
    public var firmwareCode: UInt8  // DEVICE_INFO byte 1
    public var maxChannels: UInt8   // DEVICE_INFO byte 3
}

public struct MeshCoreChannel: Equatable, Sendable { index: UInt8; name: String; secret: Data }

public enum MeshCoreConnectionState: Equatable, Sendable {
    case disconnected(reason: String?), connecting, configuring, connected, reconnecting(attempt: Int)
}

public enum MeshCoreSessionError: Error, Equatable, Sendable {
    case notConnected, frameTooLarge, firmwareTooOld, timedOut, radioError(code: UInt8?)
}

public enum MeshCoreEvent: Equatable, Sendable {
    case connection(MeshCoreConnectionState)
    /// Once per completed handshake, so again after every reconnect.
    case configured(MeshCoreRadioInfo)
    /// Every decoded frame, unfiltered. A consumer maps either this OR the typed cases, never both.
    case frame(MeshCoreFrame)
    case channelData(channelIndex: UInt8, dataType: UInt16, payload: Data)
    case rawData(payload: Data)
    case adapterUnavailable(MeshCoreAdapterUnavailable)   // same shape as MeshtasticAdapterUnavailable
}

public actor MeshCoreSession {
    public init(central: BluetoothCentralClient,
                clock: any Clock<Duration> = ContinuousClock(),
                appName: String)
    /// Connects via retrievePeripherals. NEVER scans, including on reconnect.
    public func connect(radio: UUID) async
    public func disconnect() async
    public func channels() async throws -> [MeshCoreChannel]
    public func setChannel(index: UInt8, name: String, secret: Data) async throws
    /// Returns when the radio replies OK (queued, not transmitted).
    public func sendChannelData(channelIndex: UInt8, dataType: UInt16, payload: Data) async throws
    /// Generic command primitive, for callers with their own message semantics (Meshtastified).
    /// Takes the session's command gate, so it can't interleave with the drain or another command.
    /// Writes `frame`, returns every reply whose code is in `collecting`, ending with the first whose
    /// code is in `until`. Message frames (`0x10`, `0x11`, `0x1B`) always go to events instead.
    public func request(_ frame: Data, collecting: Set<UInt8>, until: Set<UInt8>,
                        timeout: Duration) async throws -> [MeshCoreFrame]
    public nonisolated func events() -> AsyncStream<MeshCoreEvent>  // multi-subscriber
}

public enum MeshCoreScanner {
    /// Scans the service UUID, keeps only names starting "MeshCore".
    public static func scan(central: BluetoothCentralClient) -> AsyncStream<DiscoveredMeshCoreRadio>
}
```

Requirements:
- Platforms iOS 17, macOS 13, macCatalyst 17, matching ReTiCA's floor. `NSLock.withLock` in the old mock
  needs replacing, as lane A found.
- Reliability parity with MeshtasticKit: epoch guard on every await, serialised writes, powered-on gate,
  first-connect retry, backoff 1→30 s capped, a 30 s handshake timeout, power-cycle recovery, filtering
  FCB's global events to its own peripheral.
- Frames over 173 B throw `.frameTooLarge` before touching BLE.
- The session owns the sync drain: on `0x83` it drains until `0x0A`, routing `0x1B`, `0x10` and `0x11`
  frames to events. A received frame of any kind must never stall or fail a command.
- Handshake: `APP_START` → `DEVICE_QUERY` → set time (wait for any reply: firmware answers `01 06` when the
  radio's clock is ahead, and that must not stop it connecting) → drain queued messages → `.configured`. Contacts and channels are NOT fetched in the handshake; Meshtastified's adapter fetches
  contacts itself.
- `firmwareCode` below 11 (pre-v1.15, no channel data) makes `sendChannelData` throw `.firmwareTooOld`.
  The session still connects, because Meshtastified's text features work on older firmware.
- `firmwareCode` below 3 keeps today's behaviour: the connection fails and does not retry. `connect` returns
  `Void`, so this surfaces as `.disconnected(reason:)` with the public constant
  `MeshCoreSession.firmwareTooOldReason`, which consumers compare against rather than repeating the string.
- **The kit stays transport-only (my call).** Contacts (including the multi-frame burst), text sends with their
  `0x06` and ack tracking, and battery all live in Meshtastified's adapter, built on `request` and `.frame`.
  Typed methods would pull MeshCore messaging into the kit, which §3 says stays in the app. `retrieveConnected`
  stays with Meshtastified's use of the FCB central unless lane A finds it needs session state, in which case
  amend this contract.

### Contract 2 — ReTiCA `MeshCoreDriver`

`Sources/ReTiCAInterfaces/MeshCore/MeshCoreDriver.swift`, same pattern as `MeshtasticDriver`:

```swift
public struct MeshCoreDriverConfig: Equatable, Sendable {
    public var radio: UUID
    public var channelSecret: Data         // 16 bytes
    public var channelName: String = "RNSTunnel"
    public var dataType: UInt16 = 0xFFFF   // firmware's DATA_TYPE_DEV; also ScotMesh's default
    /// Keys this app used before a key change. Any slot holding one is ours to clear.
    public var retiredChannelSecrets: [Data] = []
    /// Mirrors the app's Relay setting; sets the header's can-route bit.
    public var canRoute: Bool = false
}

public struct MeshCoreLinkParams: Equatable, Sendable {
    public var spreadingFactor: UInt8, bandwidthHz: UInt32, codingRate: UInt8
}

public enum MeshCoreDriverEvent: Equatable, Sendable {
    /// `selfPrefix` is the first 4 bytes of the radio's public key.
    case connected(selfPrefix: Data, publicKey: Data, params: MeshCoreLinkParams?)
    case disconnected(reason: String?)
    /// A tunnel candidate from either carrier, already filtered to our channel slot and data type.
    case datagram(Data)
    case retiredChannelsCleared
    case unavailable(BLEAdapterUnavailable)
}

public struct MeshCoreDriver: Sendable {
    public var start: @Sendable (MeshCoreDriverConfig) -> AsyncStream<MeshCoreDriverEvent>
    /// One already-framed tunnel datagram, ≤ 162 B. False if not connected or the radio refused it.
    public var send: @Sendable (Data) async -> Bool
    /// Clears the slot holding the current key. False if not connected or the radio refused.
    public var removeChannel: @Sendable () async -> Bool
    public var stop: @Sendable () async -> Void
}
// liveValue emits one .unavailable(.other("ReTiCAMeshCoreLive not installed")) and finishes.
// testValue: unimplemented. Key path \.meshCoreDriver.
```

**Channel slot policy, owned by the live driver, run after `.configured` and before `.connected`:**
0. `session.channels()`. Clear any slot whose secret is in `retiredChannelSecrets`, and emit
   `.retiredChannelsCleared` so the app can forget those keys.
1. If a slot's secret equals `channelSecret`, use it.
2. Otherwise, use the first empty slot (all-zero secret and empty name) with `setChannel`.
3. Otherwise, emit `.unavailable(.other("No free channel slot on this radio"))`. **Never overwrite a
   configured slot.** This deliberately differs from ScotMesh, which writes slot 0 unconditionally.

**Removing our slot (decided by the user).** A leftover slot keeps feeding tunnel traffic into the radio's message
queue (§2), so we remove it. A slot is ours if its secret matches a key we hold; nothing else is ever cleared.
- Feature turned off while the radio is connected: `removeChannel`, then the normal stop protocol.
- Feature turned off while it isn't connected: there's no way to reach the radio, so the slot stays. Settings says
  so, and it can be removed from the MeshCore app.
- Key changed: the old key goes on a persisted retired list, passed in `retiredChannelSecrets`, and is cleared at the
  next connection.
- Clearing is `setChannel` with an empty name and an all-zero secret. Unverified on hardware (§8).
- Turning the feature off acts immediately, unlike other radio settings that wait for the next Connect. Otherwise
  toggle-off then Connect would never have the radio connected to remove the slot.
- **Known limit:** choosing a different radio leaves the old radio's slot on that radio, since it's no longer
  connected. Settings says so.
- A slot policy failure (no free slot, firmware too old, or a refused channel read or write) disconnects the radio,
  so the user can free a slot in the MeshCore app and we stop draining its queue. It also stops automatic restarts:
  foreground and push wakes don't retry it, only an explicit Connect does, which drains again and is covered by the
  Settings warning. This memory lasts for the session, so a fresh launch tries once.
- Settings words the leftover-slot notice as "may stay", since the app can't always know.

`firmwareCode < 11` maps to `.unavailable(.other("This radio's firmware is too old; update to v1.15 or
later"))`. Keep that message's wording user-readable: the app displays it.

### Contract 3 — ReTiCA endpoint surface

Same shape as Meshtastic's Contract 3, including the amended stop semantics, and with the same warning
that a slot must be stopped and confirmed offline before it is nil'd:
- `TransportEndpoint.State.meshCore: MeshCoreEndpoint.State?`, action `.meshCore(MeshCoreEndpoint.Action)`.
- `meshCoreInterfaceID(radio: UUID) -> InterfaceID` = `"meshcore:<uuid>"`.
- Delegates: `.radioOnline(publicKey:, params:)`, `.radioOffline(reason:)`, `.adapterUnavailable(_)`,
  `.channelRemoved(Bool)`, `.retiredChannelsCleared`.
- Actions beyond `.start`/`.stop`: `.removeChannel`, and `.setCanRoute(Bool)`, because the Relay setting applies
  immediately (`AppFeature.swift:2430-2450`). A `.stop` during a removal is held until `removeChannel` returns.
  (Amended 2026-11-07 from lane B planning.)
- **The channel key is never in reducer state or actions.** `config.channelSecret` holds `Data()` in state, so it
  can't reach state dumps or Diagnostics; an app driver wrapper fills the key and retired list at `driver.start`.
  Generating, pasting and sharing go through the key store, and actions carry only a signal. Lane B must not
  validate the secret. (Amended from lane D planning.)
- Radio name, firmware code and channel slot for Diagnostics reach the app through a defaulted `details` sink on
  `.live(session:details:)`, outside the driver struct. (Amended from lane D planning.)
- `MeshCoreCounters`: `malformed, notAddressed, evicted, timedOut, oversize, completed, queueFull,
  sendFailed, announcesLimited, pathRequestsLimited`.
- `InterfaceProfile.meshCore(params:)`: `name "meshcore"`, `hwMTU 500`, IFAC size 8 when configured (same
  as ScotMesh's `DEFAULT_IFAC_SIZE`), `.tcp`'s default mode, bitrate from §5.4.

Touch points in `TransportEndpoint.swift` mirror Meshtastic spec §5.4, with one addition: the limiter
(§5.5) runs in `transmit(_:to:masked:unmasked:)` because only that function sees the unmasked packet. Do
not classify from the masked bytes: IFAC masks the header flags. (ScotMesh reads the header at interface
level, which looks wrong when IFAC is on; don't copy that.)

## 5. Internals

### 5.1 Wire format (byte-exact, matches ScotMesh)

Every datagram, on either carrier, starts with a 14-byte big-endian header:

```
off size field
0   1    magic       0x52
1   1    type/flags  low nibble: 0 = RNS fragment, 1 = BIND_REQ, 2 = BIND; bit 4 = sender can route
2   4    src         first 4 bytes of the sender radio's public key
6   4    dst         first 4 bytes of the target's key; zeros = broadcast
10  2    pkt_id      per-sender rolling counter, random start
12  1    frag_idx    0-based
13  1    frag_total  ≥ 1
14  ...  payload
```

- Split: chunks of `payload_size` bytes stepping from 0; the last may be short. **`payload_size` = 148**,
  so a datagram is at most 162 B, within the 163 B limit that holds across firmware versions. A receiver
  must not assume this size; ScotMesh sends 140 B chunks on raw.
- Parse returns nil if: length < 14, magic ≠ `0x52`, `frag_total == 0`, or `frag_idx >= frag_total`.

We always send `dst = 0`. The can-route bit mirrors the app's Relay setting. ScotMesh records it but doesn't gate
per-packet routing on it. (My call.)

Codec seam: `MeshCoreTunnelCodec` protocol (`split`, `parse`), so a text format can be added later.
`ScotMeshRawCodec` is the v1 implementation.

### 5.2 Receive rules

In order, per datagram:
1. Parse; failure counts `malformed`. Raw pushes from unrelated apps land here, which is expected.
2. Drop if `src == selfPrefix`.
3. Drop and count `notAddressed` unless `dst` is zero or `selfPrefix`. **Peers address us by prefix even on
   the channel carrier**, when they know we answer for a destination but have no path to us
   (`_outgoing_worker`), so this needs a correct `SELF_INFO`.
4. Type 1 (`BIND_REQ`): schedule a `BIND` reply (§5.3). Type 2 (`BIND`): ignore; we keep no peer table.
   Other types: ignore.
5. Type 0: reassemble.

### 5.3 Discovery

ScotMesh delivers data from unbound senders, so nothing depends on binding for receive. It also sends
`BIND_REQ` when it hears an unbound sender, at most every 120 s per sender. We answer those but never
start them, which is the least airtime that keeps peers from re-asking. (My call.)

- On `BIND_REQ`: wait a random 3–15 s, then send one `BIND` with `dst = 0` and the radio's 32-byte public key
  as body. Coalesce: while a reply is pending, further requests do nothing. Also send at most one per 60 s.
- No `BIND_REQ`, no heartbeat, no path appendix (their parser accepts a bare 32-byte key).

### 5.4 Sender and pacing

- FIFO of framed datagrams, cap 64, all-or-nothing per packet, `queueFull` counted. (Smaller than
  Meshtastic's 256 because at these rates 64 is already minutes of air. My call.)
- Stop-and-wait: `driver.send`, await its return, then wait `fragmentDelay` on an injected clock before the
  next. Send immediately when idle.
- `fragmentDelay = max(2.5 s, 2 × airtime(181 B))`, using the Semtech formula with CRC on, explicit header,
  and preamble 32 at SF ≤ 8, otherwise 16 (`RadioLibWrappers.h:56`). 2.5 s is ScotMesh's default. The 2×
  allows for repeaters, which retransmit floods after a random 0–2.5× airtime. **This is a pre-hardware
  estimate; retune it on the first hardware run.**
- `nil` or out-of-range params: 5 s.
- `bitrate = Int(148 * 8 / fragmentDelay)`, which feeds the slow-link timing unchanged:

  | Preset | Airtime (181 B, calculated) | Delay | Bitrate |
  |---|---|---|---|
  | SF7 / 62.5 kHz / CR5 | 633 ms | 2.5 s | 473 |
  | SF7 / 62.5 / CR7 | 850 ms | 2.5 s | 473 |
  | SF8 / 62.5 / CR8 | 1689 ms | 3.38 s | 350 |
  | SF9 / 125 / CR5 | 955 ms | 2.5 s | 473 |
  | SF10 / 250 / CR5 (firmware default) | 873 ms | 2.5 s | 473 |
  | SF11 / 250 / CR5 | 1583 ms | 3.17 s | 373 |
  | unknown | — | 5 s | 236 |

- `send` false: count `sendFailed`, drop that fragment, continue. Wait an extra `fragmentDelay` first, since
  `TABLE_FULL` means the radio's pool is full.
- No retransmits. ScotMesh sends announces 2 extra times, but radios dedupe byte-identical resends and we
  have no way to make them differ without breaking its dedupe (below).
- `.disconnected`: clear the queue and reassembly buffers, cancel the timer. `.connected` again: recompute
  the profile and re-register.

### 5.5 Announce and path-request limiter

Defaults on, not user-configurable in v1. Uses ScotMesh's thresholds, with one deliberate difference in the keys.
Reads the unmasked packet; applies to locally originated and relayed packets alike.

**Keying (my call, departs from ScotMesh).** ScotMesh keys both limits on the packet's outer destination hash
(`data[2:12]`). For a path request that is the same fixed control hash every time, so after the first minute its
whole interface gets one path request per 1800 s, and its "answering a path request" bypass almost never fires. A
new contact could stay unreachable for 30 minutes. We key path requests on the **requested destination** in the
payload. The aggregate cap below replaces the airtime protection that ScotMesh's accidental global limit gave.
This affects only our sending, not the wire format.

- Announce with on-wire `hops > 2`: drop, unless it's a path response. This cap prevents the incident in §1.
- Announce: at most one per destination per 600 s, unless answering a path request heard for that destination
  in the last 15 s.
- Path request (DATA + PLAIN): after a 60 s burst window from the first, at most one per requested destination
  per 1800 s.
- Aggregate path requests: at most 6 per 10 minutes across all destinations.
- Aggregate relayed announces (on-wire `hops ≥ 1`), across all destinations: at most 6 per 10 minutes, and at most 12
  path responses per 10 minutes, counted separately. Our own announces are exempt.
- All aggregate caps are pre-hardware estimates; retune them in lane E.

**Why bridging needs caps Meshtastic doesn't have (my call).** Bridging uses the existing Relay setting and `.full`
mode, unchanged. But Meshtastic sends with hop limit 1, while a channel flood here crosses every repeater that allows
it, so a relaying phone could otherwise feed a TCP backbone's announces onto a shared mesh. With the `hops > 2` cap,
distant TCP destinations aren't advertised onto MeshCore; MeshCore users reach them on demand, through path requests.
Relayed data and link traffic isn't capped beyond the sender's queue and pacing.

Transport already paces relayed announces by bitrate before they reach the limiter (about 155 s for a 183 B announce at
473 bps), so at most about 4 go out per 10 minutes and the relayed cap can't trip through Transport at these rates. It
stays as the backstop, tested at limiter and endpoint level; lane E retunes it. A hop-capped announce still spends a
pacing slot before it's dropped. Limiter state lives in `MeshCoreInterface.State`, survives reconnects and dies with the
slot. Observing heard path requests needs inbound packets, so it runs in the `.packetReceived` arm behind Transport's IFAC
gate.
- All maps are bounded (512 entries, oldest evicted). Counts `announcesLimited`, `pathRequestsLimited`.

### 5.6 Reassembler

`MeshCoreReassembler`, a pure value type like `MeshtasticReassembler`. Header fields are unauthenticated, so
hostile input is assumed.

- Buffers keyed `(src, pktID)`, holding `total` and `[idx: body]`.
- A fragment whose `total` or body conflicts with the buffer restarts the buffer with only that fragment.
- Complete when all of `0..<total` are present. Emit, drop the buffer, and remember the key for 30 s (bounded
  to 256 keys) so ScotMesh's delayed retransmits of the same `pkt_id` don't deliver twice.
- Bounds: 60 s inactivity purge (ScotMesh uses 300 s; we choose lower to limit memory held by junk, my call);
  ≤ 8 buffers per `src`, ≤ 64 total, oldest evicted; reassembled size > 508 B dropped (`oversize`); empty
  packets dropped. Injected date, `\.meshCoreDate`.

## 6. Lanes

| Lane | Worktree | Builds against | Starts |
|---|---|---|---|
| **A** MeshCoreKit, `SELF_INFO` fix, Meshtastified migration | new repo `pods/MeshCoreKit`; `apps/Meshtastified-meshcorekit` | — | now |
| **B** codec, reassembler, limiter, interface, endpoint | `pods/ReTiCA-worktrees/meshcore-interface` (this worktree) | Contract 2 (mock) | now |
| **C** ReTiCAMsgr UI | `apps/ReTiCAMsgr-meshcore` | Own scanner stub | now |
| **D** live adapter, app wiring | ReTiCA + ReTiCAMsgr | A, B, C merged | last |
| **E** hardware verification | — | D, plus a radio | when a radio arrives |

- App worktrees must be siblings of the app directory, and lane D adds a `pods/ReTiCA-worktrees/MeshCoreKit`
  symlink next to the existing `FCB` and `MeshtasticKit` ones (Meshtastic spec §6).
- Each lane works on a branch and merges only when the user says so. This replaces the Meshtastic spec's
  commit-to-main rule.
- **Lane A** mirrors the Meshtastic lane A plan task for task. Reverses its "Meshtastified keeps MeshCore" line.
  Keep in Meshtastified, as a thin adapter over `.frame`: contact-to-`Node` mapping, unknown-DM dropping,
  `name: body` parsing, public-channel filtering, the 133-character limit. Keep `SharedScanner`, which must run
  its one combined scan. Fix `SELF_INFO` first, with a failing test taken from the firmware layout. The adapter
  must continue to deliver Meshtastified's current behaviour.
- **File ownership:** same as Meshtastic §6, with the new names. Lane B owns `TransportEndpoint.swift`.

### App (lanes C and D)

- Settings: a "MeshCore" section after "Meshtastic": toggle, radio row, "Choose radio…", and a channel key row.
  Both radio types may be enabled at once; they're separate slots and separate interfaces.
- Channel key: Generate (16 random bytes) or paste 32 hex characters, with copy/share. **No default key**, and no
  use of Public or of the secret hard-coded in other projects. The toggle can't take effect until a key is set.
  Stored in the Keychain, since it's a shared secret. (My call.) It uses the existing shared access group, so other team
  apps in that group could read it; that group already holds the identity private key. Paste refuses all zeros, MeshCore's
  Public key and ScotMesh's documented example.
- Copy states plainly that this adds traffic to a shared radio network and that everyone on the tunnel needs this
  key.
- **Message-loss warning, required (decided by the user).** The MeshCore section warns that text messages waiting on
  the radio are removed when ReTiCAMsgr connects and won't reach the MeshCore app. Don't try to save or show them.
- **Same warning for Meshtastic, required, in its existing Settings footer (`SettingsView.swift:398-403`).** The
  behaviour is the same: firmware removes a packet from its single to-phone queue when a client reads it, packets
  survive a disconnect until the next client reads them, and our driver keeps only port 76
  (`MeshtasticDriver+Live.swift:33-34`). The firmware's optional store-and-forward path on ESP32 is an exception that
  wasn't read, so word it as "may". This is a small, separate change that can land before the rest of lane C.
- Radio picker: generalise the existing `RadioPickerFeature`/`RadioScanner` to a radio kind rather than duplicating
  them. Scan ownership is unchanged: one scan per process, BLE paused while the picker is open. Rows follow the
  full-width tap rule (`.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())`).
- Diagnostics: a MeshCore layer from a plain `MeshCoreStatus` with online state, radio name, LoRa params, firmware
  code, channel slot, offline reason and the counters.
- Pairing: a radio with a BLE PIN triggers the iOS system pairing prompt. Nothing to build, but it's on the hardware
  checklist.

## 7. Release gate

Until lane E passes, the MeshCore section is compiled out of Release builds (`#if DEBUG` or a build flag).
(My call: nothing in this stack has run on a MeshCore radio, including the code being moved.) Removing the gate
is the last commit of lane E.

## 8. Testing

- **A:** existing MeshCore tests move with the code (56 `@Test`s; frame and mock-transport tests move cleanly,
  session tests split). New: `SELF_INFO` at the real layout, `0x1B` and `0x84` decode, `sendChannelData` bytes,
  frame-size rejection, a `0x1B` arriving during another command doesn't stall it. **Rebuild `MeshCoreMock` from the
  firmware source, citing lines**, and check its frames with `meshcore_py`'s parsers through a generator script.
  The old mock shared its assumptions with the decoder, so it couldn't catch decoder bugs.
- **B:** split at 1, 147, 148, 149, 296, 500, 508 B. Cross-validation drives ScotMesh's real `_Frame` from a committed
  generator script (conda `rns` env, pinned to `2167780`), both directions, as the Meshtastic lane did with landandair.
  Reassembler: interleaved senders, reordering, duplicates, conflicts, timeout, eviction, the 30 s dedupe. Sender on
  `TestClock`. Limiter at each threshold, including with IFAC on, and each aggregate cap. Whole-slice probe.
  A relay probe: MeshCore ↔ TCP endpoints through a relaying `TransportEndpoint` deliver in both directions, and an
  announce past the caps doesn't reach the radio. Meshtastic has no such automated test today, so this is new coverage.
- **C:** toggle and key persistence, no-key blocking, retired-key persistence, picker for both kinds, BLE pause and
  resume.
- **D:** live-adapter loopback against `MeshCoreMock`, including the slot policy (existing match, empty slot, all full),
  removal, retired keys, and proof that a slot with any other secret is never cleared;
  coexistence of a BLE driver, `MeshtasticSession` and `MeshCoreSession` on one FCB central.
- **E (hardware checklist).** Record radio model, firmware and preset.
  1. Radio is found, connects, shows correct name and LoRa params. A BLE PIN radio pairs.
  2. Existing channels are untouched; our slot is added once and reused after reconnect. Turning the feature off
     clears only our slot, and an old key's slot is cleared after a key change.
  3. Largest frames (171 B received, 167 B sent) survive BLE on iOS with both an ESP32 and an nRF52 radio if available.
  4. iPhone ↔ `rnsd` + ScotMesh interface, both directions, direct and through a repeater.
  5. iPhone ↔ iPhone.
  6. Retune `fragmentDelay`; measure real throughput.
  7. An official MeshCore app on a nearby radio is not disturbed by our traffic.
  8. Meshtastified's MeshCore flows work on real hardware, since lane A touches them.
  9. Bridge: `rnsd` + ScotMesh interface —air— radio —BLE— iPhone with Relay on —TCP— a TCP peer, both directions,
     following the Meshtastic checklist's test (c). Measure relayed announce traffic on the air against the caps.
  10. Confirm the warning's claim: a text queued on the radio before ReTiCAMsgr connects doesn't reach the MeshCore app.

**Follow-ups, not in v1:** zero-hop raw as a low-impact "local only" send mode (ScotMesh's receive path accepts it with
`dst = 0`, verified in source, and it needs no shared key or repeater traffic); flood scopes; routed unicast; the
Dynamic format as a second codec; registering a `data_type` in MeshCore's `docs/number_allocations.md` and asking
ScotMesh to do the same.

## 9. Risks

- **Everything below `MeshCoreSession` is unverified on hardware.** BLE frame limits and iOS MTU above 173 B, and
  real-network behaviour, come from reading code.
- **Community reception.** Flooded traffic may be unwelcome on shared meshes, and operators can block it. Mitigated by
  opt-in, the limiter and a dedicated key. Consider telling ScotMesh about a second implementer; the format has one
  deployment and could change.
- **Format drift.** Pinned commit, cross-validation fixtures, codec seam. Check the repo for changes before lane D.
- **Firmware drift.** The binary commands are partly undocumented (`CMD_SEND_RAW_DATA` and `PUSH_CODE_RAW_DATA` aren't
  in `companion_protocol.md`). v1 depends on channel data, which is documented, for sending.
- **4-byte prefix collisions** can misroute a `dst`-addressed fragment or merge reassembly keys. Reticulum's own
  authentication catches a bad packet; the result is loss, not forgery.
- **Licensing.** Not legal advice. We implement a wire format from this description; get a review if distribution
  depends on it.
