# Interfaces — BLE v2.2 GATT driver (ble-reticulum interop) — Design

**Date:** 2026-09-26
**Status:** Approved
**Supersedes:** the wire-protocol half of `2026-08-01-ble-interface-swift-design.md` (RBTP v2).
The reducer/driver/adapter *structure* from that spec is retained; the protocol it speaks
changes.
**Reference implementation:** [torlando-tech/ble-reticulum](https://github.com/torlando-tech/ble-reticulum)
v0.2.2 — `src/ble_reticulum/BLEInterface.py`, `BLEFragmentation.py`,
`linux_bluetooth_driver.py`, and `BLE_PROTOCOL_v2.2.md`. Where the markdown and the Python
disagree (the fragment header), **the Python is authoritative**.

## 1. Context and goal

ReTiCA's BLE stack implements RBTP v2, a Version/PSM GATT directory plus an L2CAP data
plane with a HELLO token exchange. RBTP has never run on a radio, and no non-Apple node
speaks it: the Python fork that defines RBTP v1 has also never run on hardware, and it is
incompatible with v2 anyway. Meanwhile ble-reticulum's protocol v2.2 is deployed on Linux
(Raspberry Pi, stock RNS plus a plugin) and Android (Columba, same Python interface with a
Kotlin driver).

**Goal:** ReTiCA speaks ble-reticulum protocol v2.2 so an iPhone interoperates with a Pi
running stock ble-reticulum, with other iPhones, and with Columba. This is sub-project 1 of
the agreed four-step plan; a later sub-project ("v3") adds an L2CAP fast path negotiated
through this same GATT service.

**Decision (approved):** replace the RBTP stack in place. `BLEInterface`, `BLEDriver`,
`FCBDriverAdapter` and `BLESupport` are reworked to v2.2. Git retains RBTP; v3 re-adds L2CAP
through the same reducer.

## 2. Wire protocol

### 2.1 Advertisement and GATT service

| Item | Value |
|---|---|
| Service UUID (advertised and primary) | `37145b00-442d-4a94-917f-8f42c5da28e3` |
| TX characteristic (peripheral → central) | `37145b00-442d-4a94-917f-8f42c5da28e4`, properties read + notify |
| RX characteristic (central → peripheral) | `37145b00-442d-4a94-917f-8f42c5da28e5`, properties write + write without response |
| Identity characteristic | `37145b00-442d-4a94-917f-8f42c5da28e6`, property read, value 16 bytes |

Discovery filters on the service UUID only. No device name is advertised (v2.2 default; the
31-byte advertisement budget is consumed by the 128-bit UUID). There is no version
characteristic in v2.2, so there is nothing to gate on; a peer whose service lacks the
Identity characteristic is refused and greylisted.

### 2.2 Local identity

The 16-byte value served on the Identity characteristic and sent in the handshake is the
node identity's hash (`Identity.hash`, the 16-byte truncated hash of the public key).
ble-reticulum uses `Transport.identity.hash`; both sides use the value only as a stable
per-node key, so any 16 bytes interoperate. It is supplied at endpoint construction, not
generated per session, so the same node keeps the same BLE identity across restarts.

### 2.3 Establishment — central role (we connect to them)

1. `connect`, discover the service, discover the three characteristics. Missing Identity
   characteristic → refuse (strike).
2. Read Identity → 16-byte peer identity.
3. Subscribe to TX notifications.
4. Write our 16-byte identity to RX **with response** (the handshake).
5. Established. Fragment payload size derives from the peripheral's maximum write length
   without response (CoreBluetooth `maximumWriteValueLength(for: .withoutResponse)`).

Steps 1–5 are time-boxed by the existing 15 s establishment deadline.

### 2.4 Establishment — peripheral role (they connect to us)

1. A central subscribing to TX opens an inbound channel. Its fragment size is that central's
   `maximumUpdateValueLength`.
2. The first RX write of **exactly 16 bytes** from a central with no known identity is its
   handshake. The reference's rule is broader than ours: ble-reticulum
   (`_handle_identity_handshake`) consumes ANY exactly-16-byte write or notification as a
   handshake even once the peer's identity is known, so a genuine 16-byte data fragment
   (5-byte header + 11-byte payload) would be silently dropped by every Pi and Columba. ReTiCA
   therefore never emits a 16-byte fragment (§2.5). On receipt ReTiCA treats a 16-byte write
   after the handshake as data.
3. Established on handshake. RX writes before the handshake are dropped.
4. No handshake within 10 s of the subscription → close + strike (replaces the HELLO
   deadline).

Both roles run simultaneously. iOS always initiates when it discovers a peer (it cannot
compute ble-reticulum's MAC-sorting rule; CoreBluetooth exposes no addresses). Peripheral
peers accept any central, so this is safe.

### 2.5 Data plane — fragmentation

Every packet, including one that fits in a single fragment, is sent through the fragmenter.
Fragment layout (network byte order, `struct.pack("!BHH")`):

```
[type: 1][sequence: uint16 BE][total: uint16 BE][payload: ≤ mtu − 5]
type = 0x01 START (sequence 0), 0x02 CONTINUE, 0x03 END (last); a single-fragment
packet is type START with total = 1.
```

- Payload size per fragment = `mtu − 5`, where `mtu` is the role-specific size from §2.3/§2.4,
  floored at 20 (so payload ≥ 15).
- No fragment on the wire is ever 16 bytes (§2.4). `BLEFragmentSanitizer` post-processes the
  pure fragmenter's output on send: an 11-byte packet is split 10 + 1 as START/END (total 2);
  otherwise one payload byte moves from the penultimate fragment onto the 16-byte END, making
  it 17. The reference reassembler concatenates payloads by sequence without checking their
  sizes, so the uneven last pair is wire-legal. `BLEFragmenter` itself stays byte-identical to
  the reference (the fixtures pin it).
- Centrals send fragments as RX writes **without response**. Peripherals send fragments as
  TX notifications targeted at the one subscribed central.
- Reassembly is per peer. A packet completes when all `total` sequences 0…total−1 are held.
  Sequence ≥ total, total = 0, unknown type, or a fragment shorter than 5 bytes is malformed.
- A malformed fragment, a total mismatch inside one packet, or a duplicate sequence with
  different bytes discards **that packet's buffer only**; the channel stays up. This matches
  ble-reticulum, which logs and continues. A duplicate sequence with identical bytes is
  ignored.
- Bounded reassembly: at most 8 in-flight packets per peer; a ninth evicts the oldest.
  Buffers older than 30 s are purged whenever a packet completes on that peer (the reference
  runs its stale sweep at the same moment). This bounds memory without a timer.

### 2.6 Keepalive

Outbound (central-role) channels send a single `0x00` byte as a raw RX write without
response every 15 s — Columba's convention for holding Android's supervision timer.
ble-reticulum peers filter any 1-byte `0x00` write before reassembly; our reassembler filters
the same on receipt. Configurable via `keepaliveInterval` on the interface state; `nil`
disables. Default 15 s.

### 2.7 Duplicate channels

Peers are keyed by identity. When a channel establishes for an identity that already has one:

- opposite directions (simultaneous cross-connect): keep the channel initiated by the owner
  of the **lower identity** (unsigned byte-wise comparison), close the other quietly;
- same direction (re-dial after a silent drop): close the old, keep the new, no
  offline/online blip.

This is the existing `bleResolveDuplicate` rule with the identity in place of the session
token. ble-reticulum's rule is "first established wins". The two rules can disagree only on
a genuine simultaneous cross-connect. With a Pi that cannot occur today (ble-reticulum dials
with a public address type and cannot reach an iPhone). With Columba it is a live-verify
item; the failure mode is one churn cycle plus a greylist strike, not a wedge.

### 2.8 Interface parameters

| Parameter | Value |
|---|---|
| `HW_MTU` | 500 (ble-reticulum's value; `InterfaceProfile.ble.hwMTU` changes from 1196) |
| bitrate guess | 80 000 bps, unchanged until measured (ble-reticulum's 700 kbps is not credible for GATT at iOS connection intervals) |
| max peers | 7, unchanged |
| greylist | unchanged (base 5 s, ×2, cap 300 s, forget 600 s, inclusive boundary) |
| churn threshold | 10 s, unchanged |
| establish deadline | 15 s |
| handshake deadline (inbound) | 10 s |
| reassembly stale age | 30 s; 8 in-flight packets per peer |
| keepalive | 15 s, outbound only |

### 2.9 Dropped from RBTP

- Version and PSM characteristics, L2CAP publish/open, 2-byte length framing, HELLO.
- `pairingMode`. v2.2 has no pairing concept; requiring encryption on our characteristics
  would force Just Works pairing on every peer and break Pi interop unless the Pi is
  configured for it. Removed from `BLEDriverConfig`, `BLEInterface.State` and
  `BLEEndpoint.State`.

## 3. Components

```
Sources/ReTiCAInterfaces/BLESupport.swift        pure: BLEFragmenter, BLEReassembler,
                                                 BLEPeerGreylist, bleResolveDuplicate
Sources/ReTiCAInterfaces/BLEDriver.swift         seam: verbs + events (reshaped)
Sources/ReTiCAInterfaces/BLEInterface.swift      reducer: lifecycle + policy (data plane reworked)
Sources/ReTiCAInterfaces/FCBDriverAdapter.swift  live CoreBluetooth mechanism (GATT data plane)
Sources/ReTiCANode/BLEEndpoint.swift             identity in, token → identity
Sources/ReTiCANode/TransportEndpoint.swift       no structural change
Sources/ReTiCANode/LXMFServiceNode.swift         passes identity.hash through
Sources/ReTiCATransport/InterfaceProfile.swift   .ble hwMTU 500
../FCB                                           updateValue must surface CoreBluetooth's Bool
```

### 3.1 BLESupport.swift (pure, dependency-free)

Removed: `BLEFraming`, `BLEFrameBuffer`, `BLEFramingError`, `BLEHello`.

```swift
public enum BLEFragmentType: UInt8 { case start = 1, cont = 2, end = 3 }

public struct BLEFragmenter: Equatable, Sendable {
    public static let headerLength = 5
    public static let minimumMTU = 20
    public let mtu: Int                       // floored at minimumMTU
    public var payloadSize: Int { mtu - Self.headerLength }
    public init(mtu: Int)
    /// Splits one packet. Throws on an empty packet or > 65 535 fragments.
    public func fragment(_ packet: Data) throws -> [Data]
}

public enum BLEReassemblyError: Error, Equatable {
    case tooShort(Int), badType(UInt8), badSequence(UInt16, total: UInt16), zeroTotal,
         totalMismatch(expected: UInt16, got: UInt16), conflictingDuplicate(UInt16)
}

/// Per-peer reassembler. Value type so the reducer owns it in channel state.
public struct BLEReassembler: Equatable, Sendable {
    public static let staleAge: TimeInterval = 30
    public static let maxInFlight = 8
    public init()
    /// Feeds one fragment. Returns a completed packet, or nil while waiting.
    /// Throws BLEReassemblyError; on throw the offending packet buffer has been discarded.
    /// `now` drives stale purge (run when a packet completes) and eviction ordering.
    public mutating func receive(_ fragment: Data, now: Date) throws -> Data?
    public var inFlightCount: Int { get }
}

public static func isKeepalive(_ data: Data) -> Bool   // exactly [0x00]
```

`BLEPeerGreylist` and `bleResolveDuplicate` are unchanged.

Sequence/total are `UInt16`; a fragment whose payload exceeds `payloadSize` is accepted (the
reference does not check it; the sender's MTU may differ from ours).

### 3.2 BLEDriver.swift (seam)

```swift
public struct BLEDriverConfig: Equatable, Sendable {
    public var localIdentity: Data            // 16 bytes; served on Identity, sent in handshake
}

public enum BLEDriverEvent: Equatable, Sendable {
    case ready
    case unavailable(BLEAdapterUnavailable)
    case peerDiscovered(BLEPeerHandle)
    case identityRead(BLEPeerHandle, identity: Data)              // central role, 16 bytes
    case identityFailed(BLEPeerHandle, reason: String?)           // missing char / short read / error
    case channelOpened(BLEChannelID, BLEPeerHandle,
                       direction: BLEChannelDirection, mtu: Int)  // outbound: after handshake write
                                                                  // inbound: on TX subscription
    case channelFailed(BLEPeerHandle, reason: String?)            // subscribe or handshake write failed
    case channelData(BLEChannelID, Data)                          // one write / one notification
    case channelClosed(BLEChannelID, reason: String?)
}

public struct BLEDriver: Sendable {
    public var start: @Sendable (BLEDriverConfig) -> AsyncStream<BLEDriverEvent>
    public var readIdentity: @Sendable (BLEPeerHandle) async -> Void
    /// Subscribe to TX and write the handshake. Result arrives as channelOpened/channelFailed.
    public var openChannel: @Sendable (BLEPeerHandle) async -> Void
    /// One packet's fragments — or a single keepalive — delivered in order and never interleaved
    /// with another call's fragments on the same channel. Central: sequential RX writes without
    /// response. Peripheral: TX notifies. (Changed from per-fragment during implementation: two
    /// concurrent per-fragment sends could interleave packets, which the total-keyed reassembler
    /// cannot survive.)
    public var send: @Sendable (BLEChannelID, [Data]) async -> Void
    public var closeChannel: @Sendable (BLEChannelID) async -> Void
    public var disconnect: @Sendable (BLEPeerHandle) async -> Void   // peer with no channel (S2)
    public var stop: @Sendable () async -> Void
}
```

`BLEPeerHandle`, `BLEChannelID`, `BLEChannelDirection`, `BLEAdapterUnavailable`, `\.bleDate`
are unchanged. `\.bleRandomBytes` is deleted (no session token).

### 3.3 BLEInterface.swift (reducer)

State changes:

```swift
public struct ChannelState {
    var peer: BLEPeerHandle
    var direction: BLEChannelDirection
    var fragmenter: BLEFragmenter
    var reassembler: BLEReassembler
    var peerIdentity: Data?      // outbound: set at channelOpened; inbound: set on handshake
    var openedAt: Date
}
public struct State {
    public var status, maxPeers                  // unchanged
    public let localIdentity: Data               // 16 bytes, from init
    public var keepaliveInterval: Duration?      // default .seconds(15)
    var channels, peers, pendingPeers, greylist, adapterRetryDelay   // unchanged shapes
    var pendingIdentities: [BLEPeerHandle: Data] // identity read, channel not yet opened
}
```

Actions: `helloDeadline` → `handshakeDeadline(BLEChannelID)`; new `keepalive(BLEChannelID)`.
`SendFailedReason.unframable` becomes `.unfragmentable` (empty packet, or > 65 535
fragments); still a programmer error.

Behaviour deltas from the current reducer:

- **`.start`:** no token generation; `BLEDriverConfig(localIdentity:)`.
- **`peerDiscovered`:** unchanged gating; calls `readIdentity`.
- **`identityRead(h, id)`:** requires `h` pending. `id.count == 16` and `id != localIdentity`
  else strike + `disconnect(h)`. If `peers[id]` is already an established channel, and the
  duplicate rule for (existing direction, `.outbound`) says keep-existing, abandon now: cancel
  establish, `disconnect(h)`, no strike (this is the cheap pre-check ble-reticulum also does
  before dialing). Otherwise record `pendingIdentities[h] = id` and `openChannel(h)`.
- **`identityFailed` / `channelFailed`:** strike, remove pending (unchanged shape).
- **`channelOpened(c, h, dir, mtu)`:** cap/greylist/online guards unchanged. Only an OUTBOUND
  open touches the pending bookkeeping (`pendingPeers`, `pendingIdentities`, the establish
  timer): `peerIdentity = pendingIdentities.removeValue(h)` (missing → close, no strike), run
  the duplicate rule against `peers[id]`, then establish (`peers[id] = c`, `peerOnline`) and
  arm the keepalive timer. Inbound: `peerIdentity = nil`, arm `handshakeDeadline(c)` at 10 s,
  and leave any in-flight outbound dial to the same handle alive so a simultaneous
  cross-connect resolves through the duplicate rule to exactly one surviving channel. A late
  `identityFailed`/`channelFailed`/`establishDeadline` for a handle that already has an
  established channel clears pending without a strike and without `disconnect`.
- **`channelData(c, bytes)`:** keepalive → ignore. If `peerIdentity == nil` (inbound,
  pre-handshake): exactly 16 bytes and ≠ `localIdentity` → handshake: cancel deadline, run
  the duplicate rule, establish, emit `peerOnline`. Any other pre-handshake write → drop
  (no strike; ble-reticulum drops too). Established: `reassembler.receive(bytes, now:)`;
  packet → `packetReceived`; throw → log-equivalent no-op (buffer already discarded), channel
  stays up.
- **`.send(peer, packet)`:** `fragmenter.fragment(packet)`; ONE `bleDriver.send(channelID,
  fragments)` per packet. Per-channel ordering and non-interleaving are the adapter's job.
- **`keepalive(c)`:** channel still established and outbound → `send(c, [0x00])`, re-arm.
- **`handshakeDeadline(c)`:** `peerIdentity == nil` → close + strike.
- **`channelClosed` / teardown / `unavailable` / `.stop`:** unchanged, plus cancel that
  channel's keepalive and handshake timers.

### 3.4 FCBDriverAdapter.swift (live mechanism)

Peripheral role, on `poweredOn`:

- `add` one primary service with TX (read + notify, no static value), RX (write +
  writeWithoutResponse), Identity (read, static value = `localIdentity`). All `.readable` /
  `.writeable` permissions (no encryption).
- `startAdvertising([serviceUUID])`.
- `subscriptions()` stream: `.subscribed(central, TX)` → mint `BLEChannelID`, record
  `central.id → channelID`, emit `channelOpened(.inbound, mtu: central.maximumUpdateValueLength)`.
  `.unsubscribed` → `channelClosed`.
- `writeRequests()` stream: for each request on RX, `respond(.success)` (write-with-response
  handshakes need it; without-response writes ignore it), then emit `channelData` on the
  channel for `request.central.id`. Writes from a central with no TX subscription are
  answered `.success` and dropped (ble-reticulum peripherals never see these; CoreBluetooth
  may deliver a handshake before the subscription event lands — see ordering note below).
- Notify path: `updateValue(data, TX, [centralID])`. **FCB gap (fixed in Task 1):** the live
  client discarded CoreBluetooth's `Bool`; a `false` means "queue full, wait for
  `isReadyToUpdateSubscribers`". FCB's `updateValue` now returns that `Bool`. The adapter
  keeps ONE per-channel FIFO for both roles (`sendQueues`, cap 256, drained by a single loop
  per channel so packets never interleave). For inbound channels a `false` parks the notify
  path until `.isReadyToUpdateSubscribers`; a ready event that lands while an attempt is still
  in flight bumps a generation counter so the attempt retries instead of parking forever.
  Overflow closes the channel (`channelClosed(reason: "notify backlog")`).
- Ordering note: iOS may deliver the RX handshake write before, or without, a TX
  subscription. To be robust, the adapter holds the **last** RX write per unsubscribed central
  for 2 s and replays it as `channelData` when the subscription arrives. If no subscription
  arrives, the write is dropped.

Central role:

- `readIdentity(h)`: `connect` → `discoverServices([service])` →
  `discoverCharacteristics(service, [TX, RX, Identity])` → `readValue(Identity)`. Any throw,
  or a missing characteristic, or value ≠ 16 bytes → `disconnect`, `forget`,
  `identityFailed`. Success → `identityRead`.
- `openChannel(h)`: create the `notifications(h, TX)` stream and its pump → `setNotify(true,
  TX)` → `mtu = maximumWriteValueLength(h, .withoutResponse)` → `writeValue(localIdentity,
  RX, .withResponse)` → register the channel and emit `channelOpened(.outbound, mtu)` with no
  suspension after the write returns. Notifications that arrive while the channel is still
  opening are buffered and flushed right after `channelOpened`. A `didDisconnect` during the
  window → `channelFailed`. Throw → `forget`, `channelFailed`. Notification stream elements
  → `channelData`; stream end or `didDisconnect` → `channelClosed`; the pump task is
  cancelled on every close. Every await in `readIdentity`/`openChannel` re-checks a session
  epoch that `stop()`/restart bumps, so a stale operation never emits into the next session.
- `send` on an outbound channel: `writeValue(data, h, RX, .withoutResponse)`. Throw →
  `channelClosed(reason:)` (the connection is gone).
- `closeChannel`: outbound → cancel the pump, clear the maps, `disconnect(h)`; every
  adapter-initiated outbound close (write failure, overflow, stream end) also disconnects,
  while the `didDisconnect` path does not (the link is already down). Inbound → there is no
  API to evict a central; the adapter drops its channel mapping and stops delivering data to
  the reducer (it still answers writes with `.success`, as CoreBluetooth requires) and lets the
  peer's own timers end the link. `disconnect(h)`, `stop`, discovery cooldown (S1), `forget`:
  unchanged.

Removed: L2CAP publish/open/unpublish, `L2CAPConnection` pump, `rbtpDirectoryService`, all
RBTP UUIDs.

### 3.5 Node layer

- `BLEEndpoint.State.init(localIdentity: Data, maxPeers:, profile:)`; `peerInterfaces` is
  `[InterfaceID: Data]` keyed by identity; `bleInterfaceID(identity)` — same function, new
  meaning of the argument. The `"ble:" + hex` scheme is retained.
- `TransportEndpoint`: the `.ble(.ble(.delegate(...)))` handlers are unchanged; the payload is
  now an identity. No new actions.
- `LXMFServiceNode.State.init(identity:, endpoint: BLEEndpoint.State, …)` callers pass
  `identity.hash` when they build the `BLEEndpoint.State`. Since the endpoint is built before
  the node, the convenience initialiser cannot inject it; callers construct
  `BLEEndpoint.State(localIdentity: identity.hash)` themselves. No production code
  constructs a `BLEEndpoint.State` today (the app is TCP-only, punch-list A1); only tests
  do, and they are updated.
- `InterfaceProfile.ble` → `hwMTU: 500`.

## 4. Error handling

| Condition | Handling |
|---|---|
| Adapter powered off / setup failure | unchanged: peers offline, backoff retry 5 s → 120 s |
| Adapter unauthorized / unsupported | unchanged: terminal, `adapterUnavailable` delegate |
| Identity characteristic missing, short, or read throws | `identityFailed` → strike, `disconnect` |
| Identity equals our own | strike, `disconnect` (self-connect or clone) |
| Subscribe or handshake write throws | `channelFailed` → strike |
| Inbound channel, no handshake in 10 s | close + strike |
| Pre-handshake non-handshake write | drop, no strike |
| Malformed fragment / total mismatch / conflicting duplicate | discard that packet's buffer; channel stays up |
| > 8 in-flight packets from one peer | evict oldest buffer |
| Notify FIFO > 256 fragments | close channel (`channelClosed`), churn rules apply |
| Central write throws | `channelClosed` |
| Channel lives < 10 s | strike (unchanged churn rule) |
| `.send` to unknown peer | drop (unchanged known gap, S5) |
| Empty packet or > 65 535 fragments | `sendFailed(.unfragmentable)` |

## 5. Testing

Under the repo's mutation discipline (write → pass → mutate → fail → revert → pass), `.off`
TestStores asserting outcomes.

1. **Pure (`BLESupportTests`)** — fragmenter: single-fragment packet is START/total 1;
   exact-multiple and remainder splits; header bytes; empty packet throws; MTU floor at 20.
   Reassembler: in-order, out-of-order, duplicate identical (ignored), duplicate conflicting
   (throws, buffer gone), total mismatch, bad type, sequence ≥ total, zero total, short
   fragment; two interleaved packets from one peer; stale purge at 30 s on completion; 9th
   in-flight evicts the oldest; keepalive predicate. Greylist and duplicate-rule tests are
   unchanged.
2. **Cross-validation fixtures** — `Tests/ReTiCAInterfacesTests/Vectors/generate_ble_fixtures.py`
   grows a `fragmentation` section produced by importing the **genuine**
   `ble_reticulum.BLEFragmentation` (vendored path or pip-installed checkout): for
   representative packet sizes × MTUs {20, 23, 185, 517}, the exact fragment bytes, plus a
   reassembly scenario (shuffled fragment order → expected packet, and an expected-throw
   case). Swift must match byte for byte and re-ingest. The existing framing/HELLO fixtures
   are removed; greylist fixtures stay.
3. **Reducer (`BLEInterfaceTests`, mock driver + test clock)** — outbound happy path
   (discover → identityRead → openChannel → channelOpened → peerOnline); inbound happy path
   (channelOpened inbound → 16-byte handshake → peerOnline); handshake deadline; pre-handshake
   junk dropped without strike; own-identity refused; identity pre-check abandons a redundant
   dial; duplicate resolution both directions from both endpoints' perspectives;
   multi-fragment send issues N ordered driver sends; multi-fragment receive emits one
   `packetReceived`; malformed fragment leaves the channel up; keepalive fires every 15 s on
   outbound only and stops on close; `keepaliveInterval = nil` disables; peer cap, greylist,
   churn, adapter loss/terminal, `.stop` — ported from the existing suite.
4. **Adapter (`FCBDriverAdapterTests`, CoreBluetoothMock)** — service shape; identity read
   path incl. missing characteristic; subscribe + handshake → `channelOpened` with the MTU;
   RX writes → `channelData` and are responded to; TX subscription → inbound channel;
   unsubscribe → `channelClosed`; notify FIFO parks on `false` and resumes on ready; FIFO
   overflow closes; held handshake replay on late subscription; discovery cooldown and
   `disconnect` — ported.
5. **FCB** — `updateValue` returns `Bool`; one test in FCB's suite pins it.
6. **Live** — a hardware checklist accompanies the plan: iPhone (foreground) as central to a
   Pi running stock RNS + ble-reticulum: discovery, identity read, handshake logged on the Pi
   (`received identity handshake from central`), `rnstatus` shows the peer, LXMF both ways,
   >391 B message (resource path), walk-away/return, kill/relaunch churn. Then iPhone ↔
   iPhone both directions with one surviving channel. Throughput/latency recorded for the
   bitrate guess.

## 6. Success criteria

- Fragment bytes and reassembly outcomes are identical to `BLEFragmentation.py` on the
  cross-validation fixtures.
- Reducer passes the full lifecycle deterministically with no hardware.
- A foreground iPhone exchanges LXMF messages with a Pi running unmodified ble-reticulum
  v0.2.2, and with a second iPhone, over BLE.
- `ReTiCA` core stays dependency-free; all changes are in `ReTiCAInterfaces`, `ReTiCANode`,
  one constant in `ReTiCATransport`, and one signature in FCB.

## 7. Out of scope

- L2CAP / "v3" (next sub-project; this design leaves the reducer's channel abstraction
  transport-agnostic so a channel can later be L2CAP-backed with the fragmenter bypassed).
- Pairing / encrypted characteristics.
- Backgrounding, state restoration, overflow-area advertising.
- RSSI scoring, power modes, connection rotation (ble-reticulum features we do not need).
- The ble-reticulum Pi-side fix for dialing random-address peers (separate upstream PR).
- App wiring (punch-list A1–A4) — unchanged in scope, still required before any live run.
- Greylist eviction and `.send`'s no-channel silent drop — known items S5/S7, unchanged.
