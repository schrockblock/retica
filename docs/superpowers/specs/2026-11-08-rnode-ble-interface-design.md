# Reticulum over an RNode (BLE) — design

**Date:** 2026-11-08
**Status:** written without a question round, at the user's request; every open question was decided by the
controller and is listed in §10 for the user to check
**Repos:** `pods/RNodeKit` (new), `pods/ReTiCA`, `apps/ReTiCAMsgr`
**Modelled on:** `2026-11-07-meshcore-interface-design.md` (this directory) and, through it,
`2026-10-16-meshtastic-interface-design.md`. Their contracts, stop semantics, FCB scan rules and slow-link timing (the
Meshtastic spec's Contract 4) apply here unless this document says otherwise.
**Research:** `/tmp/ReTiCaMsgr/rnode-research.md`, with source copies in `/tmp/ReTiCaMsgr/rnode-src/`. Both may not
survive; §2 lists what to re-fetch.

## 1. Goal

ReTiCAMsgr sends and receives LXMF through an RNode connected to the phone or Mac over Bluetooth LE, on stock RNode
firmware, and interoperates on the air with Python `rnsd` and Sideband nodes running an `RNodeInterface` on the same
LoRa parameters. With the app's Relay setting on, it bridges RNode and TCP exactly as Meshtastic does today (§5.8).

An RNode is a raw LoRa modem. The host sends whole native Reticulum packets of up to 508 bytes (500 plus an 8-byte
IFAC), KISS-framed. The firmware does CSMA, airtime accounting and the on-air split into at most two LoRa frames. There
is no channel, no header of ours, no fragmentation and no radio-side message queue. That makes this the simplest of the
three radio interfaces and the only one that is wire-compatible with reference Reticulum.

**Success criteria**

1. KISS escaping and every command frame the session writes are byte-identical to what RNS's own `RNodeInterface`
   writes for the same values, checked by a committed generator script that drives RNS, both directions where RNS has a
   parser.
2. A whole-slice probe: two `TransportEndpoint`s joined by an in-memory RNode channel deliver an LXMF message, with and
   without IFAC. A relay probe delivers RNode ↔ TCP through a relaying endpoint, both directions.
3. The live adapter passes a loopback against `MockRNodeDevice` (a CoreBluetoothMock radio rebuilt from firmware source),
   and an RNode session coexists with BLE, Meshtastic and MeshCore sessions on one FCB central.
4. On hardware (lane E): iPhone → RNode → air → RNode → Mac running `rnsd` with `RNodeInterface`, the reverse, and both
   with IFAC on.
5. All existing suites in all three repos stay green, and Meshtastic and MeshCore behaviour is unchanged.

**Non-goals (v1):**
- Classic-Bluetooth-only RNodes (original T-Beam, LoRa32 v1.0–v2.1, Heltec V2, RNode NG 2.0/2.1, Huzzah32, generic
  ESP32). iOS can't reach them without MFi. Settings and the picker say which boards work (§6).
- Serial/USB, TCP (`tcp://`, port 7633) and `RNodeMultiInterface` (serial only).
- Region presets. The user types raw parameters, as in Sideband.
- Airtime locks (`CMD_ST_ALOCK`, `CMD_LT_ALOCK`), the ID beacon (`id_callsign`/`id_interval`), battery and temperature
  polling, framebuffer and display commands, Bluetooth control and unpair commands.
- Host-side pacing, `CMD_READY` polling and flow control (§5.6).
- Any new IFAC UI (§5.8).
- More than one RNode at a time.
- Adopting whatever parameters the radio already holds (TNC mode, `rnodeconf`-configured radios).

**Anti-goals, failures even if everything technically works:**
- Transmitting on parameters the user didn't set. The app writes all five parameters at every connect and refuses to
  go online unless the radio echoes them (§5.2).
- Leaving a radio transmitting on parameters it rejected. A rejected configuration never turns the radio on (§5.2).
- A pairing prompt loop. Pairing-class failures get one automatic retry, then stop and tell the user what to do (§5.5).
- Copying GPL firmware code or Reticulum-licensed RNS code into any repo. The mock and the codec are written from this
  document; RNS runs only inside the dev-time fixture generator, and fixtures hold bytes only.
- Exposing this in a Release build before it has run on hardware (§7).

**Expectation setting:** the raw LoRa bitrate at Sideband's defaults (SF8, 62.5 kHz, CR6) is 1302 bps, before
preamble, CSMA and the two-frame split. That is several times Meshtastic's or MeshCore's effective rate, and links
should work, but plan on seconds per packet.

## 2. Background (read from source, 2026-11-08)

**Sources.** Fetched from `master` on 2026-11-08; SHAs weren't recorded because `gh` wasn't authenticated. **Lane A
Task 1 pins them:** it re-fetches both repos into new empty directories under `/tmp/ReTiCaMsgr/rnode-pins/`, records each
`HEAD` SHA in the kit's `scripts/SOURCES.md`, and stops if any line cited below no longer says what this spec claims.
- RNS: `markqvist/Reticulum`, `RNS/Interfaces/RNodeInterface.py` (cited as `PY`).
- Firmware: `markqvist/RNode_Firmware` v1.86 (`Config.h:22-23`), files `RNode_Firmware.ino`, `Utilities.h`,
  `Framing.h`, `Bluetooth.h`, `BLESerial.cpp`, `Boards.h`, `Config.h` (cited as `FW/<file>`).

**Protocol facts this design relies on:**
- KISS: FEND `0xC0`, FESC `0xDB`, TFEND `0xDC`, TFESC `0xDD`. Frame `C0 <cmd> <escaped payload> C0`. FESC is escaped
  before FEND (`PY:41-44, 102-106`). Any FEND starts a new frame; the first byte after it is the command
  (`PY:761-773`; firmware mirror `FW/RNode_Firmware.ino:765-792`).
- Several firmware replies write their single value byte **unescaped** (radio state, SF, CR, TX power, detect, version,
  platform, MCU: `FW/Utilities.h:844-849, 893-919, 1182-1216`). None of the values this design reads can be `0xC0` or
  `0xDB`, so unescaping every payload is safe.
- Commands used (`PY:47-99`): `DATA 0x00`, `FREQUENCY 0x01` (u32 BE Hz, escaped), `BANDWIDTH 0x02` (u32 BE Hz, escaped),
  `TXPOWER 0x03` (u8 dBm), `SF 0x04`, `CR 0x05`, `RADIO_STATE 0x06` (`00` off, `01` on), `DETECT 0x08` (request `0x73`,
  response `0x46`), `LEAVE 0x0A` (`FF`), `PLATFORM 0x48`, `MCU 0x49`, `FW_VERSION 0x50` (2 bytes, major then minor),
  `STAT_RSSI 0x23` (u8, value − 157 dBm), `STAT_SNR 0x24` (i8 × 0.25 dB), `STAT_CHTM 0x25` (11 bytes, `PY:927-974`,
  `FW/Utilities.h:959-983`), `RESET 0x55` (`F8`), `ERROR 0x90` (`01` INITRADIO, `02` TXFAILED, `03` EEPROM_LOCKED,
  `04` QUEUE_FULL, `05` MEMORY_LOW, `06` MODEM_TIMEOUT).
- Every parameter command is answered by an echo of the value the firmware actually set (`FW/RNode_Firmware.ino:811-905`).
  The firmware **clamps**: TX power to the board's maximum (22 dBm on an SX1262 without PA, `:857-880`), SF to 5–12,
  CR to 5–8. So a clamped value shows up as an echo mismatch.
- `RADIO_STATE 01` can be answered twice: `startRadio()` indicates the state itself and the command handler indicates
  it again (`:537, 554, 929-930`). A radio that can't start sends `ERROR 01` and reports state `00` (`:512-518`).
- RNS startup over BLE (`PY:429-496, 651-697`): open, `sleep(2)`, detect with the single write
  `C0 08 73 C0 50 00 C0 48 00 C0 49 00 C0`, wait up to 5 s for `DETECT_RESP`, require firmware ≥ 1.52 (`PY:119-120`),
  then frequency, bandwidth, TX power, SF, CR, airtime locks, radio on, `sleep(2)`, then validate: frequency within
  ±100 Hz, bandwidth, TX power, SF and radio state exact; CR not checked. On close, `leave()` writes `C0 0A FF C0`.
- Input ranges RNS enforces (`PY:112-113, 309-325`): frequency 137 MHz–3 GHz, TX power 0–37 dBm, bandwidth
  7.8–1625 kHz, SF 5–12, CR 5–8.
- Firmware errors (`PY:1077-1098`): INITRADIO and TXFAILED make RNS drop and reconnect. A `RESET F8` from an ESP32
  while online is treated as an error. Firmware hard-resets after MODEM_TIMEOUT/TXFAILED (`FW/RNode_Firmware.ino:729-749`).
- Received packets: the firmware sends `STAT_RSSI` and `STAT_SNR` frames, then the `DATA` frame (`:450-459`).
  `STAT_CHTM` arrives periodically on ESP32 and nRF52 (`:712`). RNS truncates a data frame at 508 bytes and delivers
  the truncated buffer (`PY:771`).
- Flow control is off by default in RNS (`PY:156`) and Sideband. Current firmware sends `CMD_READY` only when the host
  asks (`FW/RNode_Firmware.ino:1003-1008`). The firmware TX queue is 6144 bytes and 200 packets on ESP32 and nRF52
  (`FW/Boards.h:185-186` and siblings); **when it is full, incoming data bytes are dropped silently**, with no error to
  the host (`FW/RNode_Firmware.ino:769, 805`).
- On-air split: the firmware adds a 1-byte header and sends up to two LoRa frames for packets over 254 bytes
  (`:716-751`). The host sends whole 1–508-byte packets.
- Bitrate (`PY:699-705`): `SF · (4/CR) / (2^SF / (BW/1000)) · 1000` bps, computed from the values the radio reports.
- Single host: firmware 1.x allows one host connection at a time.

**BLE facts:**
- Nordic UART Service: service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`, RX (host→radio, write) `6E400002-…`, TX
  (radio→host, notify) `6E400003-…` (`PY:1259-1261`, `FW/BLESerial.h`). **These are MeshCore's UUIDs too**
  (`pods/MeshCoreKit/Sources/MeshCoreKit/MeshCoreGATT.swift`). The advertised name is `"RNode %02X%02X"`
  (`FW/Bluetooth.h:139, 339, 537`); MeshCore's is `"MeshCore-…"`.
- The link is a **byte stream**: KISS frames may be split or merged at any write or notification boundary.
- ESP32: RX has `PROPERTY_WRITE` only, no write-without-response, and both characteristics need an encrypted, MITM
  link (`FW/BLESerial.cpp:153-160`). nRF52: `BLEUart` with `SECMODE_ENC_WITH_MITM` (`FW/Bluetooth.h:561`).
- Pairing: a random 6-digit PIN shown on the RNode's display (`FW/Bluetooth.h:260, 482`). Security requests are refused
  unless the RNode is in pairing mode (`:274-281, 454-460`), entered by holding the button 5–10 s
  (`FW/RNode_Firmware.ino:1820-1823`), and it times out after 35 s (`FW/Bluetooth.h:44`). **The firmware disconnects
  after a successful pairing** (ESP32 after 2 s, `:288-290`; nRF52 `:435-446`). iOS has no pairing API: subscribing to
  TX triggers the system PIN prompt, as it does for Meshtastic (`MeshtasticSession.swift:304-307`).
- FCB surfaces the errors pairing produces: `setNotify` and `writeValue` throw `BluetoothError.att(code)` for the
  `CBATTErrorDomain` (`FCB/Sources/FCBComposable/Errors/BluetoothError.swift:32-36`); `CBErrorDomain` codes other than
  cancel arrive as `.underlying(NSError)` (`:26-31`); a disconnect carries `.disconnected(peripheralID:underlying:)`
  (`BluetoothCentralClient+Live.swift:662-676`). **No FCB change is needed.** CoreBluetoothMock's spec delegate returns
  `Result<Void, Error>` from set-notify and write requests, so the mock can inject them.

**ReTiCA and app facts:**
- No interface protocol: each interface is an optional slot on `TransportEndpoint.State`, and MeshCore's lane B added
  the fifth (`meshCore`) on branch `feat/meshcore-interface` (tip `b34d0cc`), not yet merged to `main`.
- `Packet.mtu` is 500 for the whole stack; 500 plus IFAC 8 is 508, RNode's `HW_MTU`. `InterfaceProfile.hwMTU` is never
  read.
- **IFAC in the app today:** neither radio slot is given an IFAC. `installMeshtasticSlot` builds
  `MeshtasticEndpoint.State(config:)` with its default profile (`AppFeature+MeshtasticRadio.swift:84`), whose `ifac` is
  nil, and MeshCore lane D does the same. ReTiCA offers an 8-byte IFAC helper on each endpoint
  (`MeshtasticEndpoint.ifac`, `MeshtasticEndpoint.swift:31-38`) that no app code calls.
- **Relay in the app today:** `.setRelayMode` sets or clears Transport's identity and recursive path requests at once
  (`AppFeature.swift:2501-2521`) and `interfaceConnected` re-applies it (`:1355-1357`). The Meshtastic profile keeps
  `InterfaceProfile`'s default mode `.full`, so with Relay on Transport forwards between the radio and every other
  interface. There is no per-radio relay switch.
- The app's picker is generic over `RadioKind { meshtastic, meshCore }` with one scan closure per kind
  (`RadioScanner.swift:36-66`); FCB allows one scan per process and the app pauses BLE while a picker is open
  (`AppFeature+Meshtastic.swift:37-49`).

## 3. Architecture

```
pods/RNodeKit                      NEW repo and package. deps: FCB, CoreBluetoothMock (mock only)
  RNodeKit                         KISS codec + streaming decoder, RNodeCommand, RNodeSession actor,
                                   RNodeScanner, RNodeGATT
  RNodeMock                        CoreBluetoothMock RNode, rebuilt from firmware source

pods/ReTiCA
  ReTiCAInterfaces/RNode/          RNodeDriver (closure struct; NO RNodeKit import), RNodeInterface
  ReTiCANode/RNodeEndpoint         endpoint wrapper, interface id, profile; TransportEndpoint slot
  ReTiCARNodeLive                  NEW target: RNodeDriver.live(session:). The ONLY ReTiCA code
                                   importing RNodeKit.

apps/ReTiCAMsgr                    Settings section, radio picker kind, diagnostics layer, wiring
```

RNode code goes in new files. Nothing is refactored out of the Meshtastic or MeshCore interfaces in v1 (MeshCore spec
§3's rule).

The KISS codec lives in the kit, not ReTiCA: it is the session's wire format, and the ReTiCA driver deals only in whole
packets. ReTiCA's interface is therefore a FIFO and a lifecycle, with no codec.

Data flow, outbound: LXMF → Transport → `TransportEndpoint` (IFAC mask, size 8) → `RNodeInterface` (FIFO, one packet
at a time) → `RNodeDriver.send` (one whole packet) → `RNodeSession.send` (KISS frame, chunked writes) → radio. Inbound:
TX notifications → `KISSDecoder` → `DATA` frame with the preceding RSSI/SNR → `.packet` → driver `.packet` →
`RNodeInterface` → `.transport(.received(id, packet))` (Transport unmasks IFAC).

## 4. Contracts

As in the MeshCore spec: contracts change only by amending this document, and a lane that finds one unworkable stops
and raises it.

### Contract 1 — RNodeKit public API

Names deliberately differ from ReTiCA's (Contract 2), because `ReTiCARNodeLive` imports both modules.

```swift
public enum RNodeGATT {
    public static let serviceUUID: CBUUID   // 6E400001-B5A3-F393-E0A9-E50E24DCCA9E
    public static let rxUUID: CBUUID        // 6E400002-…  host → radio
    public static let txUUID: CBUUID        // 6E400003-…  radio → host
    public static let namePrefix = "RNode "
}

public enum KISS {
    public static let fend: UInt8 = 0xC0, fesc: UInt8 = 0xDB, tfend: UInt8 = 0xDC, tfesc: UInt8 = 0xDD
    public static func escape(_ data: Data) -> Data
    public static func frame(command: UInt8, payload: Data) -> Data     // C0 cmd escape(payload) C0
}
public struct KISSFrame: Equatable, Sendable { public var command: UInt8; public var payload: Data }
public struct KISSDecoder: Sendable {
    public static let maxPayload = 508
    public init()
    /// Every frame closed by these bytes, unescaped, in order. Bytes may split or merge frames anywhere.
    public mutating func feed(_ bytes: Data) -> [KISSFrame]
    public var hasPartialFrame: Bool { get }
    public mutating func discardPartialFrame()
    public private(set) var oversizeDropped: Int
}

public enum RNodeCommand {   // byte constants for every command in §2, plus:
    public static let detectQuery: Data      // C0 08 73 C0 50 00 C0 48 00 C0 49 00 C0
    public static let leave: Data            // C0 0A FF C0
    public static func setFrequency(_ hz: UInt32) -> Data
    public static func setBandwidth(_ hz: UInt32) -> Data
    public static func setTXPower(_ dBm: UInt8) -> Data
    public static func setSpreadingFactor(_ sf: UInt8) -> Data
    public static func setCodingRate(_ cr: UInt8) -> Data
    public static func setRadioState(on: Bool) -> Data
    public static func data(_ packet: Data) -> Data
}

public struct RNodeRadioConfig: Equatable, Sendable {
    public var frequencyHz: UInt32, bandwidthHz: UInt32, txPowerDBm: UInt8, spreadingFactor: UInt8, codingRate: UInt8
}
public struct RNodeRadioInfo: Equatable, Sendable {
    public var name: String?                 // the peripheral's name, unauthenticated
    public var firmwareMajor: UInt8, firmwareMinor: UInt8
    public var platform: UInt8               // 0x80 ESP32, 0x70 nRF52
    public var mcu: UInt8?
    public var reported: RNodeRadioConfig    // the echoes
}
public struct RNodeChannelStats: Equatable, Sendable {
    public var airtimeShort: Double, airtimeLong: Double            // percent
    public var channelLoadShort: Double, channelLoadLong: Double    // percent
    public var currentRSSI: Int, noiseFloor: Int                    // dBm
    public var interferenceRSSI: Int?                               // nil when the radio reports 0xFF
}
public struct RNodeParameterMismatch: Equatable, Sendable {
    public enum Field: String, Sendable { case frequency, bandwidth, txPower, spreadingFactor, codingRate, radioState }
    public var field: Field
    public var requested: UInt32
    public var reported: UInt32?             // nil: the radio never echoed it
}

public enum RNodeConnectionState: Equatable, Sendable {
    case disconnected(reason: String?), connecting, configuring, connected, reconnecting(attempt: Int)
}
public enum RNodeAdapterUnavailable: Equatable, Sendable {
    case poweredOff, unauthorized, unsupported, other(String?)
    public var isTerminal: Bool              // unauthorized, unsupported
}
public enum RNodeSessionError: Error, Equatable, Sendable { case notConnected, packetTooLarge, emptyPacket }

public enum RNodeEvent: Equatable, Sendable {
    case connection(RNodeConnectionState)
    /// Once per completed handshake, so again after every reconnect.
    case configured(RNodeRadioInfo)
    /// A received packet with the RSSI/SNR frames that preceded it, if any.
    case packet(Data, rssi: Int?, snr: Double?)
    case channelStats(RNodeChannelStats)
    case radioError(code: UInt8)
    /// Emitted just before `.disconnected(reason: configurationRejectedReason)`.
    case configurationRejected([RNodeParameterMismatch])
    case adapterUnavailable(RNodeAdapterUnavailable)
}

public actor RNodeSession {
    public static let firmwareTooOldReason = "firmware too old"
    public static let pairingRequiredReason = "pairing required"
    public static let pairingRemovedReason = "pairing removed"
    public static let configurationRejectedReason = "configuration rejected"
    public init(central: BluetoothCentralClient, clock: any Clock<Duration> = ContinuousClock())
    /// Connects via retrievePeripherals. NEVER scans, including on reconnect. Writes `config` at every handshake.
    public func connect(radio: UUID, config: RNodeRadioConfig) async
    /// Writes LEAVE (best effort, ≤ 1 s), then drops the link.
    public func disconnect() async
    /// One whole packet, 1–508 bytes. Returns when every chunk's write has been acknowledged.
    public func send(_ packet: Data) async throws
    public nonisolated func events() -> AsyncStream<RNodeEvent>   // multi-subscriber, replays connection state
}

public struct DiscoveredRNode: Equatable, Sendable, Identifiable { public var id: UUID; public var name: String?; public var rssi: Int }
public enum RNodeScanner {
    /// Scans the NUS service UUID, keeps only names starting "RNode ". MeshCore radios share the UUID and are dropped.
    public static func scan(central: BluetoothCentralClient) -> AsyncStream<DiscoveredRNode>
}
```

Requirements:
- Platforms iOS 17, macOS 13, macCatalyst 17. No `NSLock.withLock`.
- Reliability parity with MeshCoreKit: epoch guard on every await, one write in flight, powered-on gate, retrieve-only
  reconnect, a 30 s handshake timeout on the injected clock starting after `setNotify` returns, power-cycle recovery,
  filtering FCB's global events to its own peripheral, an `EventHub` that registers synchronously and replays state.
- Handshake and validation exactly as §5.2; pairing and reconnect exactly as §5.5.
- `send` throws `.packetTooLarge` above 508 bytes and `.emptyPacket` for 0 bytes before touching BLE, and
  `.notConnected` unless connected.
- Reason strings: `nil` (after `disconnect()` or initially), `"radio not found"`, `"unauthorized"`, `"unsupported"`, and
  the four public constants, which consumers compare against rather than repeating.
- The kit doesn't range-check `RNodeRadioConfig`: the app validates input (§6) and the echo check catches the rest.

### Contract 2 — ReTiCA `RNodeDriver`

`Sources/ReTiCAInterfaces/RNode/RNodeDriver.swift`, the `MeshtasticDriver` pattern:

```swift
public struct RNodeLoRaParams: Equatable, Sendable {
    public var frequencyHz: UInt32, bandwidthHz: UInt32, txPowerDBm: UInt8, spreadingFactor: UInt8, codingRate: UInt8
    /// §5.7. Never below 1.
    public var bitrate: Int { get }
}
public struct RNodeDriverConfig: Equatable, Sendable { public var radio: UUID; public var params: RNodeLoRaParams }
public struct RNodeRadioReport: Equatable, Sendable {
    public var name: String?
    public var firmwareMajor: UInt8, firmwareMinor: UInt8
    public var platform: UInt8
    public var mcu: UInt8?
    public var params: RNodeLoRaParams       // what the radio echoed
}
public struct RNodeChannelLoad: Equatable, Sendable {
    public var airtimeShort: Double, airtimeLong: Double, channelLoadShort: Double, channelLoadLong: Double
    public var noiseFloor: Int
    public var interferenceRSSI: Int?
}
public enum RNodeDriverEvent: Equatable, Sendable {
    case connected(RNodeRadioReport)
    case disconnected(reason: String?)
    case packet(Data, rssi: Int?, snr: Double?)
    case channelLoad(RNodeChannelLoad)
    case hardwareError(UInt8)
    case unavailable(BLEAdapterUnavailable)
}
public struct RNodeDriver: Sendable {
    public var start: @Sendable (RNodeDriverConfig) -> AsyncStream<RNodeDriverEvent>
    /// One whole, already IFAC-masked packet, ≤ 508 B. False if not connected or the write failed.
    public var send: @Sendable (Data) async -> Bool
    public var stop: @Sendable () async -> Void
}
// liveValue emits one .unavailable(.other("ReTiCARNodeLive not installed")) and finishes.
// testValue: unimplemented. Key path \.rnodeDriver.
```

The live value maps the session's terminal reasons to these user-readable `.unavailable(.other(_))` messages, which
the app displays and must keep verbatim (`RNodeLiveMessage` in `ReTiCARNodeLive`):
- firmware too old → `This RNode's firmware is too old. Update it to 1.52 or later.`
- pairing required → `Pairing didn't finish. Hold the RNode's button for 5 to 10 seconds until it shows a PIN, then Connect and enter that PIN.`
- pairing removed → `This RNode no longer recognises this device. Forget the RNode in this device's Bluetooth settings, then pair again.`
- configuration rejected → `The radio didn't accept these settings: ` + one clause per mismatch joined by `, ` +
  `. Change them in Settings, then Connect.` Clauses: `frequency 868.125 MHz (asked for 868.1 MHz)`,
  `bandwidth 125 kHz (asked for 62.5 kHz)`, `TX power 22 dBm (asked for 30 dBm)`, `spreading factor 12 (asked for 13)`,
  `coding rate 8 (asked for 9)`, `the radio didn't turn on`; a missing echo reads `<field> no reply (asked for …)`.
  MHz and kHz print with trailing zeros dropped.
These four are the **user-action failures**: retrying can't fix them, so the app doesn't re-dial them on its own (§6).

### Contract 3 — ReTiCA endpoint surface

Meshtastic's Contract 3 shape, including the amended stop semantics and the rule that a slot is stopped and confirmed
offline before it is nil'd:
- `TransportEndpoint.State.rnode: RNodeEndpoint.State?`, action `.rnode(RNodeEndpoint.Action)`, started and stopped
  with the other slots, `.ifLet` composed.
- `rnodeInterfaceID(radio: UUID) -> InterfaceID` = `"rnode:<uuid>"`.
- Delegates: `.radioOnline(RNodeRadioReport)`, `.radioOffline(reason:)`, `.adapterUnavailable(_)`.
- `RNodeCounters`: `received, sent, oversize, queueFull, sendFailed, hardwareErrors`.
- `RNodeTelemetry` (read-only on the slot, for Diagnostics): `lastRSSI: Int?`, `lastSNR: Double?`,
  `channelLoad: RNodeChannelLoad?`, `lastHardwareError: UInt8?`. Nothing in it reaches Transport.
- `InterfaceProfile.rnode(params: RNodeLoRaParams?)`: name `"rnode"`, `hwMTU` 508, mode `.full` (the default), bitrate
  `params?.bitrate ?? 183`. `RNodeEndpoint.ifacSize = 8`, `RNodeEndpoint.ifac(networkName:passphrase:)`.
- The slot's `registeredProfile(params:)` takes IFAC and mode from the endpoint's profile and the bitrate from the
  radio's **reported** params.
- Touch points in `TransportEndpoint.swift` copy the Meshtastic arms (`.online` registers and arms maintenance,
  `.offline` deregisters from Transport and LinkPlane, `.packetReceived` hands to Transport, `.adapterUnavailable` to the
  hatch) and add one `transmit` branch with no limiter.

## 5. Internals

### 5.1 KISS codec and decoder

- `escape` replaces `DB` with `DB DD` first, then `C0` with `DB DC` (RNS order).
- `KISSDecoder` follows RNS's receive loop with two deliberate differences:
  1. **Every** command's payload is unescaped and returned as a `KISSFrame`, not just data and frequency, so the
     session can read any echo.
  2. A frame whose payload would exceed 508 bytes is **dropped whole** and counted in `oversizeDropped`. RNS delivers
     the first 508 bytes (`PY:771`); a truncated Reticulum packet can't authenticate, so delivering it only wastes work.
- A FEND with no command byte read (two FENDs in a row) yields nothing. A FESC followed by anything other than TFEND or
  TFESC yields that byte as is (RNS behaviour).
- A partial frame that receives no bytes for **1250 ms** is discarded (`PY:388`, BLE). The session owns the timer on its
  injected clock and calls `discardPartialFrame()`; the decoder itself has no clock.
- An empty `DATA` frame is dropped by the session, not delivered.

### 5.2 Handshake, configuration and validation

After `connect`, discover the service and both characteristics, take the notification stream, `setNotify(true)` on TX
(this is where iOS pairs; §5.5), then, on the 30 s handshake timer:

1. **Detect.** Write `RNodeCommand.detectQuery` as one frame. Within 5 s, require `DETECT 46`, `FW_VERSION` and
   `PLATFORM`. `MCU` is recorded if it arrives before step 4 ends. Missing any of the three: retryable failure.
2. **Firmware.** `(major, minor) < (1, 52)`: terminal, `firmwareTooOldReason`.
3. **Configure,** in RNS order: frequency, bandwidth, TX power, SF, CR. Each is its own frame, and the session waits up
   to 5 s for **that command's** echo before writing the next. A missing echo is recorded as `reported: nil`, not a
   failure, so the user sees it.
4. **Validate before turning the radio on.** Frequency within ±100 Hz; bandwidth, TX power, SF and CR exact. (RNS skips
   CR; the firmware echoes it, so checking it costs nothing.) Any mismatch: emit `.configurationRejected(list)`, write
   `setRadioState(on: false)` and `leave`, and end terminal with `configurationRejectedReason`. The radio was never
   turned on.
5. **Radio on.** Write `setRadioState(on: true)`; within 5 s the first `RADIO_STATE` echo must be `01`. Otherwise:
   `.configurationRejected([radioState: requested 1, reported 0 or nil])`, `leave`, terminal as above. A duplicate echo
   later is ignored.
6. `.connection(.connected)`, then `.configured(info)` with the echoed values.

The sequence is response-driven rather than RNS's fixed `sleep(2)` + `sleep(2)` + `sleep(1)`. Whether real firmware
needs a settle delay after subscribing is a lane E item.

Frames that aren't the awaited reply during the handshake (stats, a stray packet) go to events as usual and never fail
a step.

### 5.3 Sending

- `send(packet)` frames `RNodeCommand.data(packet)` and writes it in chunks of
  `min(maximumWriteValueLength(.withoutResponse), 512)` bytes (at least 20), in order, under the session's single write
  slot, so chunks of two frames never interleave and a handshake command never lands inside a data frame.
- **Write type:** `.withResponse` whenever the discovered RX characteristic's properties include `.write`;
  `.withoutResponse` only if they include `.writeWithoutResponse` and not `.write`. ESP32 builds advertise `.write`
  only, and CoreBluetooth drops a without-response write to such a characteristic. Chunks use the without-response
  length even for acknowledged writes, so no write needs a long (prepared) write.
- `send` returns when the last chunk's write returns. It means "handed to the radio", not "transmitted".

### 5.4 Receiving and telemetry

- `STAT_RSSI` and `STAT_SNR` are held and attached to the next `DATA` frame's `.packet`, then cleared. A packet with no
  preceding stats carries nil.
- `STAT_CHTM` (11 bytes) becomes `.channelStats`: u16 BE / 100 for the four percentages, RSSI bytes − 157, byte 10
  `0xFF` → `interferenceRSSI` nil. A wrong-length payload is ignored.
- `ERROR` frames become `.radioError(code:)`. Codes `01` and `02` also end the link as retryable (RNS reconnects on
  both). Others are events only.
- `RESET F8` while connected ends the link as retryable.
- Every other command is ignored.

### 5.5 Pairing, reconnect and the post-pairing drop

**Pairing-class failures** are: `BluetoothError.att(.insufficientAuthentication)`, `.att(.insufficientEncryption)`,
`.att(.insufficientEncryptionKeySize)`, a `CBErrorDomain` `encryptionTimedOut` (15), and `setNotify` not returning within
**60 s** (the user is given time to read and type the PIN). **Pairing-removed** is `CBErrorDomain`
`peerRemovedPairingInformation` (14) on connect, `setNotify`, a write or a disconnect.

- The **first retry** after any retryable failure of a `connect(radio:config:)` call waits **0 s**; later retries back
  off 1, 2, 4 … s, capped at 30 s, as MeshCoreKit does. This is what makes the firmware's post-pairing disconnect
  painless: whether it lands mid-handshake or just after `.connected`, the session reconnects at once, and the bond now
  exists.
- A pairing-class failure gets **one** automatic retry. A second consecutive one ends terminal with
  `pairingRequiredReason`, so the session never loops system prompts. The count resets when a handshake completes.
- Pairing-removed ends terminal at once with `pairingRemovedReason`: only the user can fix it, by forgetting the device.
- Backoff, power-cycle handling and the never-scan rule are MeshCoreKit's.
- The app shows short pairing guidance in Settings (§6) and the mapped messages (Contract 2) when these fire.

### 5.6 Interface FIFO, no host pacing

- `RNodeInterface` keeps a FIFO of whole packets, cap **64**, `queueFull` counted when full. Stop-and-wait on the
  driver: call `driver.send`, await its result, then send the next immediately. No delay, no airtime estimate, no
  `CMD_READY` polling. This is RNS's behaviour with flow control off.
- A packet over 508 bytes is dropped and counted `oversize`. `send` false counts `sendFailed`, drops that packet and
  continues. `.disconnected` clears the queue. Sends while not online are dropped silently.
- **Known risk, accepted:** the firmware's TX queue (6144 B / 200 packets) drops silently when full (§2). At 1302 bps
  that is minutes of traffic, and Transport already paces announces by bitrate, so it should not fill in practice.
  Lane E measures it.

### 5.7 Bitrate and profile

`bitrate = Int((SF · (4 / CR) / (2^SF / (BW / 1000)) · 1000).rounded())`, at least 1, from the radio's reported params.
It feeds Transport's slow-link timing unchanged (announce cap, link timeouts, LXMF retry).

| SF / BW / CR | bps |
|---|---|
| 7 / 125 kHz / 5 | 5469 |
| 8 / 125 / 5 | 3125 |
| 8 / 62.5 / 6 (Sideband default) | 1302 |
| 9 / 125 / 5 | 1758 |
| 10 / 250 / 5 | 1953 |
| 12 / 125 / 8 | 183 |
| 12 / 7.8 / 8 | 11 |
| 5 / 1625 / 5 | 203125 |

`params == nil` (only ever a placeholder profile before the radio reports) uses 183.

### 5.8 IFAC and relay

- **IFAC:** follows the other radios. The app passes no IFAC to the RNode slot, and there is no IFAC UI. ReTiCA's
  `RNodeEndpoint.ifac(...)` fixes size 8 (`PY:110`, and Sideband's default) for any host that sets one, and the whole-slice
  probe proves it works.
- **Relay:** exactly Meshtastic's. The profile's mode is `.full`; the app's Relay setting applies at once and is
  re-applied on interface up; RNode has no per-radio relay switch. A relaying phone forwards RNode ↔ TCP traffic, paced
  by Transport's bitrate-based announce cap. No MeshCore-style limiter: RNode traffic doesn't flood through repeaters.

## 6. Lanes

| Lane | Worktree, branch | Builds against | Starts |
|---|---|---|---|
| **A** RNodeKit | new repo `pods/RNodeKit`, branch `rnodekit` | FCB | now |
| **B** interface, endpoint, slot | `pods/ReTiCA-worktrees/rnode-interface`, `feat/rnode-interface`, from `feat/meshcore-interface` | Contract 2 (mock driver) | now |
| **C** ReTiCAMsgr UI | `apps/ReTiCAMsgr-rnode`, `feat/rnode-ui` | its own scanner stub | after MeshCore lane D Part 2 is merged |
| **D** live adapter, app wiring | `pods/ReTiCA-worktrees/rnode-live` + `apps/ReTiCAMsgr-rnode` | A, B, C merged | last |
| **E** hardware verification | — | D, plus an RNode | when hardware is available |

**Why B branches from `feat/meshcore-interface`:** it edits `TransportEndpoint.swift`, which MeshCore lane B rewrote on
that branch and which isn't on `main` yet. Building on it avoids a three-way merge later. **Why C and D wait:** they
edit the same slot sync, scanner, picker and `AppFeature` sites MeshCore lane D is changing.

**Merge order.** A person approves every merge; lanes commit to branches only, never push, never merge.
1. MeshCore lane B → `pods/ReTiCA` `main` (already planned; RNode B is based on it).
2. RNode lane A → `pods/RNodeKit` `main`.
3. RNode lane B → `pods/ReTiCA` `main`, rebased onto `main` first. Any time after 1.
4. MeshCore lane D Part 1 → ReTiCA `main`, then Part 2 → `apps/ReTiCAMsgr` `main` (already planned).
5. RNode lane C → `apps/ReTiCAMsgr` `main` (starts after 4).
6. RNode lane D Part 1 → ReTiCA `main` (needs 2, 3, 4).
7. RNode lane D Part 2 → `apps/ReTiCAMsgr` `main` (needs 5, 6).

- Lane D adds a `pods/ReTiCA-worktrees/RNodeKit` symlink next to the `FCB`, `MeshtasticKit` and `MeshCoreKit` ones.
  App worktrees must be siblings of the app directory.
- **File ownership:** lane B owns `ReTiCAInterfaces/RNode/*`, `ReTiCANode/RNodeEndpoint.swift` and the RNode arms of
  `TransportEndpoint.swift`. Lane D owns `ReTiCARNodeLive` and every `Package.swift` change. Nobody edits FCB,
  MeshtasticKit or MeshCoreKit; a defect there means stop and ask.

### App (lanes C and D)

- **Settings:** an "RNode" section after "MeshCore", under `#if DEBUG`: toggle, radio row, "Choose radio…", and five
  fields: frequency (MHz, empty by default), bandwidth (kHz, default 62.5), spreading factor (default 8), coding rate
  (default 6), TX power (dBm, default 0). These are Sideband's defaults, and like Sideband there is no default
  frequency.
- **Validation** (RNS's input ranges): frequency 137–3000 MHz, bandwidth 7.8–1625 kHz, SF 5–12, CR 5–8, TX power
  0–37 dBm, each with a plain message. The toggle can't be turned on until every field is valid, and nothing dials until
  then. The firmware may allow less TX power than 37 dBm; the echo check reports it (Contract 2 wording).
- Persisted with `@Shared(.appStorage)`: `rnodeEnabled` (false), `rnodeRadioID`, `rnodeRadioName`, `rnodeFrequencyHz`
  (nil), `rnodeBandwidthHz` (62500), `rnodeSpreadingFactor` (8), `rnodeCodingRate` (6), `rnodeTXPowerDBm` (0).
- **Copy states which boards work:** Bluetooth LE RNodes (Heltec V3 and V4, LilyGO T3S3, T-Deck, T-Beam Supreme, Seeed
  XIAO S3, RAK4631, LilyGO T-Echo, Heltec T114), and that Classic-Bluetooth-only RNodes can't connect.
- **Pairing guidance:** hold the button 5–10 s until a PIN shows, tap Connect, enter that PIN; the radio drops the
  connection once after pairing and the app reconnects by itself.
- Changes take effect on the next Connect, as for Meshtastic. The slot is replaced when the radio **or any parameter**
  changes (Meshtastic's rule: replacing an RNode slot loses nothing worth keeping).
- **User-action failures** (Contract 2's four) stop automatic re-dials on foreground and push wake. An explicit Connect
  retries, as does choosing a different radio or changing a parameter. Session-only, as MeshCore lane D's
  `meshCorePolicyFailed`.
- **Picker:** a third `RadioKind` case, `.rnode`, with its own scan closure and copy. RNode and MeshCore share the
  service UUID, so each kind's scanner filters by name. One scan per process, BLE paused while the picker is open. Rows
  keep the full-width tap rule.
- **Diagnostics:** an RNode layer: settings, radio, status, firmware, platform, reported params, bitrate, last RSSI and
  SNR, channel load, airtime, noise floor, offline reason and counters.
- **Coexistence:** Meshtastic, MeshCore and RNode slots may all be enabled at once on one FCB central. One RNode.
- **macOS:** the same core and FCB central; the system pairing prompt works there too. Copy says "this device".

## 7. Release gate

Until lane E passes, the RNode Settings section (with its "Choose radio…" button) and its copy are compiled out of
Release builds with `#if DEBUG`, and `chooseRNodeRadioTapped` does nothing while the gate is off, through an `RNodeReleaseGate.isCompiledIn` value logic reads as `AppFeature.State.rnodeAvailable`, the
pattern of `MeshCoreReleaseGate`. Stale defaults can't start a slot in Release, because `rnodeWillDial` requires
`rnodeAvailable`. Removing the gate is lane E's last commit.

## 8. Testing

- **A:** escape and every command builder against RNS-generated fixtures; decoder with every split and merge of a
  frame sequence, escapes at chunk edges, oversize, back-to-back FENDs, the 1250 ms discard; a mock rebuilt from firmware
  source, citing lines, with its replies checked by RNS's parser through the generator; the handshake on the mock,
  including clamped TX power, a missing echo, a double radio-state echo, old firmware, and a radio that won't start;
  write type and chunking; pairing-class retry and terminal; the post-pairing drop; power cycle; scanner name filtering
  with a MeshCore radio present.
- **B:** bitrate table; interface lifecycle and stop semantics ported from `MeshCoreInterface`'s suites; FIFO, oversize,
  `sendFailed`, telemetry; profile; `TransportEndpoint` arms incl. a 508-byte IFAC-masked packet; whole-slice probe with
  and without IFAC; relay probe RNode ↔ TCP. Meshtastic and MeshCore suites untouched.
- **C:** settings persistence and defaults, every validation boundary, the toggle gate, picker for the third kind, BLE
  pause and resume, diagnostics rows, copy, Release build has no RNode strings.
- **D:** live-adapter loopback against `MockRNodeDevice`; RNode beside BLE, Meshtastic and MeshCore on one FCB central,
  including each scanner finding only its own radios; slot swap, re-dial and the user-action gate; whole-slice in the app.
- **E (hardware checklist).** Record board, firmware version and parameters.
  1. The picker shows `RNode XXXX` before connecting (the name is in the advertisement or scan response).
  2. First connection pairs: the iOS prompt appears, the PIN on the radio works, the post-pairing drop reconnects on its
     own, and the 30 s handshake timer doesn't race the PIN entry.
  3. Not in pairing mode: the failure maps to the pairing message, and there's one retry, not a loop. Forget the device
     on the RNode only (`rnodeconf` unpair): the pairing-removed message appears.
  4. A 508-byte packet arrives intact in both directions on an ESP32-S3 and an nRF52 board (notification size against
     the negotiated MTU; no `setMTU` call was found in ESP32 firmware). Record whether the ESP32 RX accepts the
     acknowledged writes at the chosen chunk size.
  5. The response-driven handshake configures real firmware with no settle delay; if not, measure the delay needed.
  6. iPhone ↔ `rnsd` + `RNodeInterface`, both directions, then with IFAC on both sides.
  7. iPhone ↔ iPhone, and iPhone ↔ Mac.
  8. Bridge: `rnsd` —air— RNode —BLE— iPhone with Relay on —TCP— a TCP peer, both directions.
  9. Clamped TX power shows the Contract 2 message naming the radio's value.
  10. Burst test against the firmware queue: send until it fills, and record whether drops happen at real traffic levels.
  11. An RNode without a display: record how (or whether) a user can pair it from iOS.

## 9. Risks

- **Everything below `RNodeSession` is unverified on hardware**, in particular BLE notification sizes on ESP32, pairing
  timing and the post-pairing drop.
- **Silent firmware drops** when its queue is full (§5.6). Accepted for parity; lane E measures.
- **Boards without a display** can't show a PIN to an iPhone user (§8 E11).
- **Name visibility:** the scanner drops a radio whose name isn't visible before connecting.
- **Legal use:** the app writes whatever frequency and power the user enters within RNS's ranges. Copy says the user is
  responsible; no region checks.
- **Firmware drift:** the command set is stable since 1.52, but the handshake depends on echo behaviour read from 1.86.
  Lane A pins the commit; lane D re-checks it.
- **Licensing.** Not legal advice. We implement the protocol from this description; RNS (Reticulum License) runs only at
  dev time to generate byte fixtures; no firmware (GPL-3.0) or `reticulum-mobile-app` (AGPL) code is read into the repos.

## 10. Calls made without asking

The user asked to skip questions. Each line is a decision someone should check.

**Given by the controller:**
1. **Scope:** BLE RNodes only (ESP32-S3 and nRF52 builds). Classic-Bluetooth boards are a non-goal; copy names the
   boards that work.
2. **Pairing:** system pairing only. In-app guidance; the post-pairing drop reconnects automatically; pairing errors map
   to clear messages. FCB surfaces them already (§2), so no FCB change is planned; a lane that finds otherwise stops and
   asks.
3. **Radio parameters:** written at every connect and echo-checked. Free-form entry, Sideband defaults (62.5 kHz, SF8,
   CR6, 0 dBm), no default frequency, nothing dials until valid, RNS's input ranges. No region presets.
4. **Wire:** native Reticulum packets, no host fragmentation, HW MTU 508 including IFAC, interoperable with Python RNS.
   IFAC as the other radios in the app today: none set, no UI, size 8 available in ReTiCA.
5. **Flow control off,** no limiter or pacer, firmware handles channel access, interface FIFO as the other interfaces.
   The silent-drop risk is documented, not mitigated.
6. **Relay:** exactly Meshtastic's (`.full` mode, global Relay setting applied at once).
7. **One RNode slot,** coexisting with Meshtastic and MeshCore on one FCB central; scanners split by name.
8. **Packaging:** new `pods/RNodeKit`; `ReTiCAInterfaces/RNode` plus `ReTiCARNodeLive`; app Settings, picker kind,
   diagnostics and wiring; Debug-only gate.
9. **Sequencing:** A and B now; C and D after MeshCore lane D. Merge order in §6.
10. **Hardware-only risks** go to lane E's checklist, not tasks.

**Made while writing this spec:**
11. The KISS codec lives in RNodeKit, not ReTiCA; the ReTiCA driver deals in whole packets.
12. Kit and ReTiCA type names differ (`RNodeRadioConfig`/`RNodeLoRaParams`, `RNodeRadioInfo`/`RNodeRadioReport`,
    `RNodeChannelStats`/`RNodeChannelLoad`), because the live target imports both.
13. Lane B branches from `feat/meshcore-interface`, not `main`.
14. The handshake is response-driven (wait for each echo, 5 s each) instead of RNS's fixed sleeps; lane E checks it.
15. CR is validated too (RNS doesn't).
16. Parameters are validated **before** the radio is turned on, and a rejected configuration turns the radio off and
    leaves; RNS turns the radio on first.
17. A missing echo is reported as a mismatch with `reported: nil`, not as a retryable failure.
18. Configuration rejection, old firmware, pairing required and pairing removed are terminal and don't re-dial on
    foreground; only Connect or a settings change retries them.
19. The first retry of a connect waits 0 s; the rest back off 1→30 s.
20. A pairing-class failure gets exactly one automatic retry; pairing-removed gets none.
21. `setNotify` is bounded at 60 s, counted as a pairing-class failure.
22. Acknowledged writes whenever RX advertises `.write`; chunks sized to the without-response maximum, capped at 512.
23. An inbound frame over 508 bytes is dropped whole (RNS delivers it truncated).
24. FIFO cap 64 packets.
25. Bitrate rounds to the nearest bps (RNS keeps a float); unknown params use 183 bps.
26. `INITRADIO` and `TXFAILED` errors and a `RESET` while online reconnect, as in RNS. Other errors are counted only.
27. `disconnect()` writes LEAVE first, as RNS's `leave()` does. The radio isn't turned off on a normal disconnect.
28. No airtime locks, ID beacon, battery or temperature polling in v1.
29. Input ranges live in the app; the kit and ReTiCA don't range-check (the echo check is the last guard).
30. A parameter change replaces the slot at the next Connect (Meshtastic's rule), unlike MeshCore's keep-the-slot rule.
31. The Settings copy ships under the same `#if DEBUG` gate as the section. The picker's RNode footer strings live in
    `RadioPickerFeature` ungated, as MeshCore's do; Release can't open an RNode picker, so they never show.
32. Lane B adds a relay probe, which Meshtastic doesn't have, because it's cheap with MeshCore's harness.
33. macOS is in scope through the shared core; no Mac-specific work is planned.
