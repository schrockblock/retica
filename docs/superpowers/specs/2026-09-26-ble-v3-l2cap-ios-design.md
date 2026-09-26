# Interfaces — BLE v3 L2CAP fast path (iOS/macOS) — Design

**Date:** 2026-09-26
**Status:** Approved design, pre-implementation
**Wire spec (binding):** `BLE_PROTOCOL_v3.md` in the ble-reticulum fork (branch `v3-l2cap-addendum`,
worktree `/Users/ell/development/python/ble-reticulum-v3`). This document only says how ReTiCA
implements it; where the two disagree, the wire spec wins.
**Builds on:** `2026-09-26-ble-v22-gatt-driver-design.md` (the v2.2 stack this extends).

## 1. Goal and scope

ReTiCA becomes the first v3 node: it publishes an L2CAP listener and the PSM characteristic
as a peripheral, and as a central it prefers the L2CAP channel when the peer publishes a PSM,
falling back to the v2.2 GATT path otherwise. iPhone ↔ iPhone gets the fast path immediately;
iPhone ↔ Pi and iPhone ↔ Columba keep working over GATT until those sides add v3.

Out of scope: raising `HW_MTU` above 500 for L2CAP peers (the wire spec allows it; ReTiCA keeps
one BLE profile until throughput is measured live), the Python listener/connector, Android.

## 2. What changes, by layer

### 2.1 Seam (`BLEDriver.swift`) — additive only

```swift
public enum BLEChannelTransport: Equatable, Sendable { case gatt, l2cap }

// identityRead gains the PSM (nil = absent, unreadable, short, or 0):
case identityRead(BLEPeerHandle, identity: Data, psm: UInt16? = nil)
// channelOpened says which transport the channel is; mtu is meaningful for .gatt only:
case channelOpened(BLEChannelID, BLEPeerHandle, direction: BLEChannelDirection, mtu: Int,
                   transport: BLEChannelTransport = .gatt)

// New verb, default no-op so existing mocks compile unchanged:
/// Open an L2CAP CoC to `psm` on the peer's existing ACL link (10 s limit), send the 16-byte
/// handshake frame, then emit channelOpened(.outbound, transport: .l2cap). Failure emits
/// channelFailed WITHOUT disconnecting: the reducer falls back to the GATT path on the same link.
public var openL2CAPChannel: @Sendable (BLEPeerHandle, UInt16) async -> Void = { _, _ in }
```

Default associated values keep every existing `.identityRead(h, identity:)` and
`.channelOpened(c, h, direction:, mtu:)` construction site compiling. `send(channel, [Data])`
is unchanged: on an L2CAP channel each element is one complete length-framed record, written
to the channel as-is. `openChannel(handle)` stays the GATT path.

### 2.2 Pure support (`BLESupport.swift`)

Restore the length framing removed in the v2.2 pivot, at the v3 ceiling:

```swift
public enum BLEFramingError: Error, Equatable { case invalidLength(Int) }
public enum BLEFraming {
    public static let maxFrameLength = 1196
    public static let headerLength = 2
    public static func frame(_ packet: Data) throws -> Data     // [len:2 BE][packet], 1…1196
    public static let keepaliveFrame = Data([0x00, 0x01, 0x00])  // len 1, payload 0x00
}
public struct BLEFrameBuffer: Equatable, Sendable {             // streaming deframer
    public init(maxFrameLength: Int = BLEFraming.maxFrameLength)
    public mutating func append(_ data: Data) throws -> [Data]  // throws on len 0 / > max: no recovery
}
```

The v2.2 fragmenter, reassembler, sanitizer and greylist are untouched.

### 2.3 Reducer (`BLEInterface.swift`)

State:
- `State.l2capEnabled: Bool` (init parameter, default `true`) — set `false` to force GATT for
  hardware bring-up or A/B tests.
- `ChannelState.transport: BLEChannelTransport`; `ChannelState.frameBuffer: BLEFrameBuffer`
  (used only on `.l2cap`).
- `State.pendingPaths: [BLEPeerHandle: BLEChannelTransport]` — which path the in-flight dial
  is trying, so a failure can fall back exactly once.

Path selection at `identityRead(h, identity, psm)`:
- existing guards and the duplicate pre-check unchanged;
- if `l2capEnabled && psm != nil` → `pendingPaths[h] = .l2cap`, `bleDriver.openL2CAPChannel(h, psm)`;
- else → `pendingPaths[h] = .gatt`, `bleDriver.openChannel(h)`.

Fallback at `channelFailed(h)`: if `pendingPaths[h] == .l2cap` and the handle is still pending,
set `pendingPaths[h] = .gatt`, re-arm the establish deadline (a fresh 15 s), call
`bleDriver.openChannel(h)`, no strike. A GATT failure behaves as today (strike, clear pending).
`pendingPaths` is cleared wherever `pendingIdentities` is.

Handshake and data on `.l2cap` channels:
- Outbound: the adapter already sent the handshake frame; `channelOpened(.outbound, .l2cap)`
  establishes exactly like the GATT outbound path (pending identity, duplicate rule, keepalive).
- Inbound: the first complete frame must be exactly 16 bytes and ≠ our identity → establish;
  any other first frame → tear down with a strike. The 10 s handshake deadline applies as on GATT.
- `channelData` on `.l2cap`: `frameBuffer.append(bytes)`; a framing error tears the channel down
  with a strike (wire spec: "close the channel immediately"); each complete frame is: keepalive
  (len 1, `0x00`) → ignored; the pre-handshake identity → establish; otherwise one packet →
  `packetReceived`. No reassembler on this path.
- `.send` on `.l2cap`: `BLEFraming.frame(packet)` → one driver send with `[frame]`; a throw →
  `sendFailed(.unframable)` (new reason). `.keepalive` on `.l2cap` sends `[BLEFraming.keepaliveFrame]`.
- Everything else (cap, greylist, churn, duplicate resolution, adapter loss, stop) is unchanged;
  the duplicate rule does not care which transport a channel uses.

### 2.4 Adapter (`FCBDriverAdapter.swift`)

Peripheral bring-up: after `removeAll`, `try await peripheral.publishL2CAPChannel(false)`; on
success the service gains the PSM characteristic (`…28e7`, read-only, 2 bytes little-endian);
on failure (platform cannot listen) the service is published without it and a log-equivalent
note is kept in the report — bring-up does not fail. `resetSession` unpublishes the PSM.
Inbound channels arrive on `peripheral.l2capConnections()`: each is registered as an inbound
channel (`l2cap[channelID] = conn`, `inboundL2CAP[channelID] = conn.peerID`), its `incoming()`
pumped to `channelData` (raw bytes; framing is the reducer's), stream end → `channelClosed`.
`channelOpened(.inbound, mtu: 0, transport: .l2cap)`.

Central: `readIdentity` also discovers `…28e7` and, if present, reads it (2 bytes LE; anything
else → `psm: nil`). `openL2CAPChannel(peer, psm)`: `central.openL2CAPChannel(peer.id, psm)`
raced against a 10 s clock; on success `conn.send(handshakeFrame)` where the frame is
`[0x00, 0x10] + localIdentity`, register (`l2cap`, `outboundByPeer`, pump), emit
`channelOpened(.outbound, mtu: 0, transport: .l2cap)`; on failure or timeout close any
half-open connection and emit `channelFailed(peer, reason:)` **without** `disconnect` or
`forget` (the reducer falls back on the same GATT link). Epoch guards after every await, as
in `openChannel`.

Send: `drain` gains an L2CAP branch: `try await conn.send(fragment)` per queued record; a throw
closes the channel (outbound: disconnect too). The FCB pump buffers internally, so no
readiness protocol is needed on this path.

Close: outbound L2CAP `closeChannel`/close paths cancel the pump, `conn.close()`, clear maps,
then `disconnect(peer)` (spec: closing an outbound channel drops the link, same as GATT);
inbound: `conn.close()`, clear maps, no event. `didDisconnect` closes that peer's L2CAP
channel with `disconnect: false`. `resetSession` closes every connection before finishing.

### 2.5 Node layer

No change. `bleInterfaceID` and `peerOnline`/`peerOffline` carry identities as before; every
BLE peer keeps `InterfaceProfile.ble` (HW_MTU 500). Raising L2CAP peers to 1196 is a later
slice that would need `peerOnline` to carry the transport.

## 3. Error handling

| Condition | Handling |
|---|---|
| PSM characteristic absent/short/0 | GATT path, no event |
| L2CAP open fails or exceeds 10 s | `channelFailed`, reducer falls back to GATT once, no strike |
| GATT fallback also fails | existing behaviour: strike, clear pending, disconnect |
| First L2CAP frame not a valid identity | tear down + strike |
| Framing error (len 0 or > 1196) | tear down + strike |
| Packet > 1196 on `.send` | `sendFailed(.unframable)` |
| L2CAP write throws | close channel (outbound: disconnect) |
| Channel lives < 10 s | churn strike, unchanged |
| Peripheral cannot publish a PSM | GATT-only peripheral, bring-up continues |

## 4. Testing

Pure: framing round trip and boundaries at 1196, keepalive frame, deframer split/coalesced
delivery, error cases. Reducer (mock driver): path selection with and without PSM and with
`l2capEnabled == false`; L2CAP outbound establishment; inbound L2CAP handshake (valid, invalid,
timeout); framed send and receive on L2CAP; framing error tears down; keepalive frame on
L2CAP; fallback after L2CAP failure (once) and strike after the GATT retry fails; the duplicate
rule across mixed transports. Adapter (stub `L2CAPConnection` built from FCB's public init):
PSM published and characteristic present with LE bytes; publish failure → no characteristic;
PSM read in `readIdentity`; open success with handshake frame first; open timeout;
inbound registration and pump; send via connection; close semantics; `didDisconnect` closes the
peer's L2CAP channel. CoreBluetoothMock: the real central against a mock peripheral that
exposes a PSM — CBM cannot open L2CAP, so the open fails and the adapter must fall back to
GATT end to end. Mutation discipline throughout. Live: iPhone ↔ iPhone over L2CAP (one channel,
both directions, resource transfer), iPhone ↔ Pi unchanged over GATT.

## 5. Out of scope / follow-ups

Per-peer HW_MTU 1196; the Python listener/connector; Android; L2CAP-level backpressure beyond
FCB's pump buffer; measuring throughput for the bitrate guess.
