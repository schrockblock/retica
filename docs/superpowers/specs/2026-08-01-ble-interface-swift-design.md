# Interfaces — BLE (CoreBluetooth) — Design

**Date:** 2026-08-01
**Status:** Approved
**Reference:** the Reticulum fork at `../../python/Reticulum` — `RNS/Interfaces/BLEInterface.py`,
`RNS/Interfaces/util/ble_support.py`, `RNS/Interfaces/util/ble_driver.py`, and the normative
`docs/ble_interface_spec.md` (Reticulum BLE Transport Profile, RBTP v1).

## Context

The Python fork ships a spec-driven BLE transport: nodes advertise/scan on a fixed 128-bit
service UUID, expose a two-characteristic GATT "directory" (protocol Version, L2CAP PSM),
and move length-framed Reticulum packets over an L2CAP connection-oriented channel. The
BLE link is an untrusted pipe — all crypto is Reticulum end-to-end; there is no mesh logic
at this layer. Policy (peer cap, greylist backoff, churn handling) is normative in the spec.

This slice brings that transport to ReTiCA as a new interface in `ReTiCAInterfaces`,
following the repo's established three-layer style (pure logic / TCA reducer / driver
dependency with a live CoreBluetooth implementation).

**Interop goal: Apple ↔ Apple first.** Linux interop is a later phase (it requires the
Python fork to adopt the v2 changes below).

**Scope: full** — pure support logic, `BLEInterface` reducer, `BLEDriver` dependency seam,
AND the live CoreBluetooth driver. Automated tests mock the driver; the live driver is
verified manually on real devices. Endpoint/Transport wiring is deferred (Endpoint is
TCP-hardwired today; per-peer `InterfaceID` composition is a follow-up slice).

## The CoreBluetooth constraint, and RBTP v2

RBTP v1's §4.2 tie-break — "the node whose BD address sorts lexicographically lower MUST
initiate" — cannot be computed on Apple platforms: CoreBluetooth exposes no BD addresses
(not the local one, not peers'; remote devices appear as locally-scoped `CBPeer` UUIDs, and
a device cannot know its own peer-visible identifier). Direction-based dedup rules cannot
substitute (each side's "outbound" is the other's "inbound", so any symmetric "prefer X"
rule makes both sides keep — or drop — opposite channels). A shared comparable value must
cross the air.

**Decision (approved): both sides initiate; dedup after, via a HELLO token exchange.**
Because a mandatory first frame changes the data plane, this is an incompatible protocol
change: the Version characteristic serves **2**. A v1 Linux node is refused cleanly at the
version gate rather than choking on a mystery frame.

### RBTP v2 (Apple profile) — normative deltas from v1

Unchanged from v1: service UUID `99872ed7-eba8-4c07-bf35-ab464a957f80` (advertisement and
GATT), Version characteristic `50870e44-2fd6-4cbc-9f1f-11a0fcf85265` (uint8), PSM
characteristic `1cfe213f-4ea4-48f9-9344-dde18cc729ef` (uint16 LE), data-plane framing
`[len: 2 bytes BE][packet]` with `1 ≤ len ≤ 1196` and immediate drop on violation, no
custom fragmentation, `HW_MTU = 1196`, max peers default 7 (configurable), greylist
arithmetic (base 5 s, ×2 per strike, cap 300 s, strikes forget after 600 s, inclusive
blocking boundary), churn threshold 10 s, pairing modes `open`/`paired`, IFAC passthrough.

Changes:

1. **Version = 2.** Readers refuse any other major version (disconnect + brief greylist).
2. **No tie-break; both may initiate.** On discovery: GATT connect → read Version (gate) →
   read PSM → open L2CAP CoC to that PSM. Establishment is time-boxed client-side (15 s
   overall; directory read 10 s).
3. **HELLO first frame (mandatory, both directions).** Each node generates a random
   16-byte **session token** at interface start. The first frame on every channel must be:
   `"RBT"` (3 ASCII bytes) ‖ version byte (`0x02`) ‖ 16-byte token — 20 bytes inside the
   normal 2-byte-BE length framing. A first frame that is not a valid HELLO, a HELLO with
   the wrong version, a HELLO carrying our **own** token (self-connect), or no HELLO
   within 10 s → drop + greylist strike. After the exchange, the peer's identity **is**
   its token: it keys the peer map, max-peers count, and dedup.
4. **Dedup rule.** When a channel completes HELLO for a peer token that already has an
   established channel:
   - *Opposite directions* (simultaneous cross-connect): keep the channel initiated by the
     owner of the **lower token** (unsigned byte-wise lexicographic comparison); close the
     other. Both sides compute this identically from (initiator token, direction).
   - *Same direction* (re-dial after a silent drop): reconnect — close the old channel,
     keep the new.
   (Equal tokens cannot reach this rule: a HELLO echoing our own token is rejected above,
   and a duplicate of the peer's token is by definition the same peer.)
5. **Server-side camper timebox dropped.** `CBPeripheralManager` gives no visibility into
   bare GATT connections, so v1 §3.3's server-side MAY-disconnect is unenforceable here.
   Client-side establishment timeouts remain.
6. **MTU note.** Apple exposes no L2CAP MTU negotiation and `CBL2CAPChannel` is a byte
   stream; the length framing already tolerates arbitrary segmentation, so v1 §5.1's
   "requested MTU ≥ 1280" is moot on this platform.
7. **Address privacy** is automatic on Apple (always resolvable private addresses).
   Token = session identity, so address rotation within a session does not churn peers.

`paired` mode maps to `publishL2CAPChannel(withEncryption: true)` (CoreBluetooth then
enforces OS-level pairing for GATT reads and the channel); `open` maps to
`withEncryption: false`.

## Package structure

```
Sources/ReTiCAInterfaces/BLESupport.swift          // pure logic, no dependencies
Sources/ReTiCAInterfaces/BLEDriver.swift           // @Dependency seam: commands + event stream
Sources/ReTiCAInterfaces/BLEInterface.swift        // @Reducer (parent lifecycle + policy)
Sources/ReTiCAInterfaces/CoreBluetoothDriver.swift // live driver, #if canImport(CoreBluetooth)
Tests/ReTiCAInterfacesTests/BLESupportTests.swift
Tests/ReTiCAInterfacesTests/BLEInterfaceTests.swift
Tests/ReTiCAInterfacesTests/Vectors/ble_fixtures.json  // cross-validation fixtures
```

No `Package.swift` changes (targets already exist).

## Public API sketch

### Pure support logic (`BLESupport.swift`)

```swift
public enum BLEFramingError: Error, Equatable { case invalidLength(Int) }

public enum BLEFraming {
    public static let maxFrameLength = 1196
    public static let headerLength = 2
    public static func frame(_ packet: Data) throws -> Data      // [len:2 BE][packet]
}

/// Streaming deframer. Appends bytes, yields complete packets; throws on a
/// malformed length prefix (len == 0 or len > max) — no recovery, caller drops
/// the connection. Port of ble_support.FrameBuffer.
public struct BLEFrameBuffer: Equatable {
    public init(maxFrameLength: Int = BLEFraming.maxFrameLength)
    public mutating func append(_ data: Data) throws -> [Data]
}

public enum BLEHello {
    public static let length = 20                     // "RBT" + version + 16-byte token
    public static let tokenLength = 16
    public static func pack(version: UInt8, token: Data) -> Data
    public static func parse(_ frame: Data) -> (version: UInt8, token: Data)?
}

/// Port of ble_support.PeerGreylist, generic over the peer key (the reducer keys it by
/// BLEPeerHandle — the analogue of the Python's bdaddr, visible at every gate). Same
/// arithmetic: delay = min(base * 2^(strikes-1), max); strikes forgotten after
/// strikeForget; blocked while now <= unblockTime (inclusive).
public struct BLEPeerGreylist<Key: Hashable>: Equatable {
    public init(baseDelay: TimeInterval = 5, maxDelay: TimeInterval = 300,
                strikeForget: TimeInterval = 600)
    public mutating func recordFailure(_ peer: Key, now: Date)
    public func isBlocked(_ peer: Key, now: Date) -> Bool
    public mutating func clear(_ peer: Key)
}

public enum BLEChannelDirection: Equatable, Sendable { case outbound, inbound }

public enum BLEDuplicateResolution: Equatable { case keepExisting, keepNew }

/// Pure dedup decision for a new channel whose peer token matches an established
/// channel. Symmetric: both endpoints reach complementary conclusions.
public func bleResolveDuplicate(
    localToken: Data, peerToken: Data,
    existingDirection: BLEChannelDirection, newDirection: BLEChannelDirection
) -> BLEDuplicateResolution
```

### Driver seam (`BLEDriver.swift`)

```swift
/// Locally-scoped handle for a remote device (wraps the CBPeer UUID). Pre-HELLO identity.
public struct BLEPeerHandle: Hashable, Sendable { public let id: UUID }
/// Opaque per-channel handle.
public struct BLEChannelID: Hashable, Sendable { public let id: UUID }

public struct BLEDriverConfig: Equatable, Sendable {
    public var version: UInt8            // served by the Version characteristic
    public var pairingMode: BLEPairingMode  // .open / .paired
}

public enum BLEDriverEvent: Equatable, Sendable {
    case ready                                          // advert + GATT + listener + scan up
    case unavailable(reason: String?)                   // powered off / unauthorized / lost
    case peerDiscovered(BLEPeerHandle)                  // service-UUID-filtered
    case directoryRead(BLEPeerHandle, version: UInt8, psm: UInt16)
    case directoryFailed(BLEPeerHandle, reason: String?)
    case channelOpened(BLEChannelID, BLEPeerHandle, direction: BLEChannelDirection)
    case channelFailed(BLEPeerHandle, reason: String?)
    case channelData(BLEChannelID, Data)
    case channelClosed(BLEChannelID, reason: String?)
}

/// BLE driver dependency. Live value wraps CoreBluetooth; tests inject a mock.
/// The driver is mechanism only — no policy, no retries, no framing.
public struct BLEDriver: Sendable {
    public var start: @Sendable (BLEDriverConfig) -> AsyncStream<BLEDriverEvent>
    public var readDirectory: @Sendable (BLEPeerHandle) async -> Void  // result arrives as event
    public var openChannel: @Sendable (BLEPeerHandle, UInt16) async -> Void
    public var send: @Sendable (BLEChannelID, Data) async -> Void
    public var closeChannel: @Sendable (BLEChannelID) async -> Void
    public var stop: @Sendable () async -> Void
}
extension BLEDriver: DependencyKey {
    public static var liveValue: BLEDriver   // CoreBluetoothDriver-backed (or inert stub off-platform)
    public static let testValue: BLEDriver   // unimplemented
}
```

Splitting `readDirectory` from `openChannel` keeps the version gate in the reducer —
mirroring the Python `BLEDriver` contract (`read_directory` / `connect`).

Two small sibling dependencies (defined in `ReTiCAInterfaces`, which cannot see
`ReTiCATransport`'s equivalents):
- `\.bleRandomBytes` — session-token generation (live: `SystemRandomNumberGenerator`).
- `\.bleDate` — "now" for greylist arithmetic (live: `Date.init`; `\.date`'s testValue is
  unimplemented in this TCA version, hence the custom key — same pattern as
  `\.transportDate`).

### Reducer (`BLEInterface.swift`)

```swift
/// A connected BLE peer, identified by its 16-byte session token.
public typealias BLEPeerID = Data

@Reducer
public struct BLEInterface {
    public static let protocolVersion: UInt8 = 2
    public static let defaultMaxPeers = 7
    public static let establishTimeout: Duration = .seconds(15)
    public static let helloTimeout: Duration = .seconds(10)
    public static let churnMinLifetime: TimeInterval = 10
    public static let adapterRetryMin: Duration = .seconds(5)
    public static let adapterRetryMax: Duration = .seconds(120)

    @ObservableState
    public struct State: Equatable {
        public var status: Status                  // .stopped, .starting, .online, .waitingForAdapter
        public var maxPeers: Int
        public var pairingMode: BLEPairingMode
        var sessionToken: Data?                    // generated on .start
        var channels: [BLEChannelID: ChannelState] // direction, peer handle, FrameBuffer,
                                                   // hello phase, establishedAt
        var peers: [BLEPeerID: BLEChannelID]       // established peers by token
        var pendingPeers: Set<BLEPeerHandle>       // establishment in flight
        var greylist: BLEPeerGreylist<BLEPeerHandle>
        public init(maxPeers: Int = 7, pairingMode: BLEPairingMode = .open)
    }

    public enum Action: Equatable {
        case start
        case stop
        case driverEvent(BLEDriverEvent)
        case send(BLEPeerID, Data)                 // outbound raw packet bytes
        case helloDeadline(BLEChannelID)
        case establishDeadline(BLEPeerHandle)
        case adapterRetry
        case delegate(Delegate)
        public enum Delegate: Equatable {
            case peerOnline(BLEPeerID)
            case peerOffline(BLEPeerID)
            case packetReceived(BLEPeerID, Data)
        }
    }
}
```

`BLEPeerID` (the token) is the delegate-surface identity so a later composition slice can
mint one Transport `InterfaceID` per peer — matching how the Python registers each
`BLEPeerInterface` with `RNS.Transport` separately.

### Live driver (`CoreBluetoothDriver.swift`)

An actor, `#if canImport(CoreBluetooth)`-gated, owning:
- `CBPeripheralManager`: advertise service UUID; GATT service with Version + PSM
  characteristics (read-only; values from `BLEDriverConfig` and the published channel's
  PSM); `publishL2CAPChannel(withEncryption:)`; inbound channels via
  `didOpen channel` → `.channelOpened(..., .inbound)`.
- `CBCentralManager`: scan filtered on the service UUID (duplicates off);
  `peerDiscovered` per new peripheral; on `readDirectory` connect + discover the service +
  read both characteristics; on `openChannel` call `peripheral.openL2CAPChannel(psm)`.
- Open `CBL2CAPChannel`s: stream delegate on a dedicated queue/RunLoop; reads surface as
  `.channelData`; writes go through a per-channel buffer drained on
  `hasSpaceAvailable`; stream errors/EOF surface as `.channelClosed`.
- Manager state changes: `.poweredOn` (both managers) → `ready`; `poweredOff` /
  `unauthorized` / `unsupported` / `resetting` → `unavailable(reason:)`.

No policy: it never retries, never filters peers beyond the UUID scan filter, never parses
frames. All exceptions/errors are normalised into events.

## Behavior

- **`.start`:** generate `sessionToken` via `\.bleRandomBytes`; `status = .starting`;
  long-lived cancellable effect iterating `bleDriver.start(config)`, mapping events to
  `.driverEvent`.
- **`.driverEvent(.ready)`:** `status = .online`.
- **`.driverEvent(.peerDiscovered(h))`:** ignore unless online. Skip if `h` is pending, or
  established-peer count ≥ `maxPeers`, or `h` is strike-blocked. Otherwise add to
  `pendingPeers`, run `readDirectory(h)`, and arm `establishDeadline(h)` on the clock.
- **`.driverEvent(.directoryRead(h, version, psm))`:** if `version != 2` → strike, remove
  pending. Else `openChannel(h, psm)`.
- **`.driverEvent(.channelOpened(c, h, dir))`:** for inbound, early-refuse (close) if at
  cap or `h` strike-blocked. Record `ChannelState` (hello phase = awaiting), send our
  HELLO (`BLEFraming.frame(BLEHello.pack(...))`) on the channel, arm `helloDeadline(c)`.
- **`.driverEvent(.channelData(c, bytes))`:** `try channels[c].frameBuffer.append(bytes)`;
  on `FramingError` → close + strike + teardown. First completed frame on a channel must
  parse as a valid v2 HELLO whose token differs from our own (else close + strike). On
  HELLO: dedup via `bleResolveDuplicate` (close the loser), then mark established, map
  `peers[token] = c`, cancel the hello deadline, emit `.delegate(.peerOnline(token))`.
  Subsequent frames → `.delegate(.packetReceived(token, frame))`.
- **`.send(peerID, raw)`:** if `peers[peerID]` exists, `bleDriver.send(channel,
  BLEFraming.frame(raw))`; else drop silently.
- **`.driverEvent(.channelClosed(c, _))` / local teardown:** remove channel; if it was the
  established channel for a token → remove peer, emit `.peerOffline(token)`, and if
  lifetime < 10 s record a greylist strike against the channel's peer handle.
- **`.helloDeadline(c)` / `.establishDeadline(h)`:** if still incomplete → close/abandon +
  strike.
- **`.driverEvent(.directoryFailed)` / `.channelFailed`:** strike (by handle), remove
  pending.
- **`.driverEvent(.unavailable))`:** every established peer emits `.peerOffline`; state
  clears channels/peers/pending; `status = .waitingForAdapter`; retry loop: sleep
  backoff (5 s doubling to 120 s cap) on the clock → re-run `bleDriver.start` effect;
  `.ready` restores `.online` and resets the backoff.
- **`.stop`:** cancel all effects, `bleDriver.stop()`, emit `.peerOffline` for established
  peers, reset state to `.stopped`.

All greylist strikes are keyed by `BLEPeerHandle` — the identity every gate (discovery,
inbound accept) actually sees, playing the role the bdaddr plays in the Python. Tokens key
only the established-peer map and the dedup rule.

## Error handling

- **Adapter loss** never crashes and recovers without restart (backoff loop above).
- **Per-channel failures** touch only that channel/peer; other links are undisturbed
  (spec §6.2: churn never resets the adapter).
- **Malformed framing** is unrecoverable per spec: drop + strike.
- **`BLEFrameBuffer` throwing** is confined to the reducer's `channelData` handling; the
  reducer catches and converts to teardown — no throw escapes the reducer.
- The driver normalises every CoreBluetooth error into an event; no driver call throws.

## Verification strategy

Under the project's mutation-testing discipline (write → pass → mutate → fail → revert →
pass), with `.off` TestStores asserting outcomes per project preference.

1. **Pure unit tests** (`BLESupportTests`):
   - Framing: round-trip; empty/oversized packet rejection; deframer partial-delivery,
     multiple-frames-per-append, split header, `len == 0` and `len > 1196` throw.
   - HELLO: pack/parse round-trip; wrong magic/version/length rejected.
   - Greylist: strike growth 5→10→20…cap 300; inclusive boundary (blocked at exactly
     unblock time, free strictly after); strike-forget after 600 s; `clear`.
   - Dedup table: both token orders × both direction combinations × equal tokens; assert
     the two endpoints' complementary calls agree on the surviving channel.
2. **Cross-validation fixtures** driving the *genuine* Python `ble_support.py` (conda
   `rns` env, absolute-path `python`): framing bytes for representative packets
   (`frame()` output committed as fixtures; Swift must match byte-for-byte and re-ingest),
   and a greylist timing scenario (failure timestamps → blocked/unblocked expectations at
   probe times) asserting arithmetic identity. HELLO/dedup are v2-only (no Python
   counterpart yet) — spec-fixture only.
3. **Reducer tests** (`BLEInterfaceTests`, mock driver via `AsyncStream` continuation +
   recording actor, test clock):
   - Outbound happy path: discover → directory → open → HELLO exchange → `.peerOnline`;
     packets flow both ways framed/deframed.
   - Inbound happy path (channelOpened `.inbound` first).
   - Version-mismatch refusal; directory/channel failure → strike; greylisted peer skipped
     while blocked, allowed after expiry (clock-driven).
   - Max-peers: discovery skipped and inbound refused at cap; existing links untouched.
   - Cross-connect dedup: run the rule from both endpoints' perspectives; same survivor.
   - Reconnect (same direction) replaces the stale channel without a spurious
     `.peerOffline`/`.peerOnline` mismatch.
   - Malformed frame → channel drop + strike; HELLO timeout → drop + strike.
   - Churn: channel living < 10 s strikes; ≥ 10 s does not.
   - Adapter loss → all peers offline → backoff retry (test clock) → recovery re-onlines.
   - `.stop` cancels everything; no stray effects (teardown catches them).
4. **Live driver:** manual two-device verification (Mac ↔ iPhone or two Macs) — a
   hardware checklist accompanies the implementation plan, mirroring the Python fork's
   `2026-07-25-ble-hardware-checklist.md`. Not a CI gate. App-level requirements
   (`NSBluetoothAlwaysUsageDescription`, background modes, iOS background-advertising
   overflow-area caveat) are documented in the checklist.

## Success criteria

- Framing and greylist arithmetic are byte/number-identical to the Python fork's
  `ble_support.py` (cross-validated, not hand-rolled).
- The reducer passes deterministic TestStore tests for the full lifecycle — discovery,
  establishment, HELLO/dedup, data plane, policy (cap/greylist/churn), adapter loss and
  recovery — with no hardware.
- The live CoreBluetooth driver contains mechanism only, and two real Apple devices
  discover, connect, deduplicate to a single channel, and exchange framed packets.
- `ReTiCA` core remains dependency-free; all new code is confined to `ReTiCAInterfaces`.

## Out of scope (this slice)

- Endpoint/Transport composition (per-peer `InterfaceID` registration) — follow-up slice.
- Linux ↔ Apple interop (requires v2 adoption in the Python fork, including HELLO and the
  tie-break removal; the Python fork's spec doc gains a v2 section at that point).
- Updating `../../python/Reticulum/docs/ble_interface_spec.md` itself (different repo;
  noted as follow-up).
- Background-mode behavior tuning (overflow-area advertising between backgrounded iOS
  apps), state restoration, and app-level permission UX.
- `ifac_netname`/`ifac_netkey` derivation (ReTiCA's Transport does not implement IFAC yet;
  passthrough note retained in the spec deltas only).
- **Greylist/seen-peer map eviction:** `BLEPeerGreylist` entries and the `peers`/`channels`
  maps have no bounded-size eviction policy; very long sessions accumulate entries for every
  peer ever seen. Eviction is deferred to the Endpoint composition slice.
- **Outbound write-buffer cap:** when a peer's L2CAP channel stalls (stream
  `hasSpaceAvailable == false`), the CoreBluetooth driver queues writes without a size cap.
  This is a driver-level concern; the maximum practical backlog depends on hardware
  throughput and is flagged for verification during live-device testing.
