# BLEEndpoint — BLE Interface ↔ Transport Wiring — Design

**Date:** 2026-08-02
**Status:** Approved
**Depends on:** the FCB-backed BLE interface in `ReTiCAInterfaces` (`BLEInterface`,
`FCBDriverAdapter`, `BLEDriver`) — complete and merged.

## Context

ReTiCA has an FCB-backed `BLEInterface` reducer (RBTP v2: discovery, HELLO/dedup, a
data plane of framed Reticulum packets per peer) and a `Transport` reducer (path learning,
opportunistic delivery, announce/maintenance). They have never been composed: the only
production composition, `Endpoint` (in `ReTiCANode`), hardwires a single `TCPClientInterface`
and a single `InterfaceID`. This slice wires BLE into a runnable node.

The structural mismatch: `Transport` routes by one `InterfaceID`, but `BLEInterface`
manages *N* peers keyed by a 16-byte session token (`BLEPeerID`). The reference Python
resolves this by spawning one `BLEPeerInterface` per peer, each registered with Transport
separately. The Swift analogue: map each connected peer to its own `InterfaceID`.

**Scope (decided during brainstorming):** packet plane only — announces, path learning,
opportunistic send/receive. Links/resources/requests over BLE and threading BLE into
`LXMFNode` are clean follow-ons, explicitly out of scope here. The TCP `Endpoint` is not
modified.

## Architecture

A new `@Reducer public struct BLEEndpoint` in `Sources/ReTiCANode/BLEEndpoint.swift`,
parallel to `Endpoint`. It composes `BLEInterface` + `Transport` (no `LinkSession`), so it
is a small reducer that duplicates none of `Endpoint`'s link machinery.

```
BLEEndpoint
 ├─ Scope(\.ble,       action: \.ble)       { BLEInterface() }
 ├─ Scope(\.transport, action: \.transport) { Transport() }
 └─ Reduce { ... }   // the four wiring edges + lifecycle + public surface
```

### Per-peer InterfaceID mapping

- `InterfaceID` is derived deterministically from the peer token:
  `bleInterfaceID(_ token: BLEPeerID) -> InterfaceID` = `InterfaceID("ble:" + token.hexString)`
  (lowercase hex). Pure and total.
- State holds `peerInterfaces: [InterfaceID: BLEPeerID]` so the transmit path reverses the
  mapping without re-parsing hex. This map is the source of truth for "which peers are
  live"; its count drives the maintenance lifecycle.

Because `Transport` broadcasts announces and path-requests to its whole `interfaces` set,
registering each peer as an interface makes an announce flood to every connected BLE peer —
the mesh behavior the Python gets from per-peer `BLEPeerInterface`s.

### The four wiring edges

| `BLEInterface` delegate | `BLEEndpoint` action(s) |
|---|---|
| `.peerOnline(token)` | `peerInterfaces[id] = token`; `transport.interfaceConnected(id)`; if this is the 0→1 peer, `transport.startMaintenance`; surface `delegate.peerOnline(token)` |
| `.peerOffline(token)` | `transport.interfaceDisconnected(id)`; remove `peerInterfaces[id]`; if this was the last peer (1→0), `transport.stopMaintenance`; surface `delegate.peerOffline(token)` |
| `.packetReceived(peer: token, packet)` | `transport.received(id, packet)` |
| `transport.delegate(.transmit(txID, raw))` | `guard let token = peerInterfaces[txID]` (else drop) → `ble.send(peer: token, packet: raw)` |

`id` above = `bleInterfaceID(token)`.

## Public surface

```swift
@Reducer public struct BLEEndpoint {
    @ObservableState public struct State: Equatable {
        public var ble: BLEInterface.State
        public var transport: Transport.State
        var peerInterfaces: [InterfaceID: BLEPeerID] = [:]
        public init(maxPeers: Int = BLEInterface.defaultMaxPeers,
                    pairingMode: BLEPairingMode = .open)
    }

    public enum Action: Equatable {
        case ble(BLEInterface.Action)
        case transport(Transport.Action)

        case start
        case stop
        case registerLocalDestination(Destination)
        case announce(destinationHash: Data, appData: Data?)
        case send(destinationHash: Data, plaintext: Data)
        case enableRelay(Identity)

        case delegate(Delegate)
        @CasePathable public enum Delegate: Equatable {
            case messageReceived(destinationHash: Data, plaintext: Data)
            case pathLearned(destinationHash: Data, hops: UInt8)
            case sendFailed(destinationHash: Data, reason: Transport.SendFailure)
            case peerOnline(BLEPeerID)
            case peerOffline(BLEPeerID)
        }
    }
}
```

Action forwarding mirrors `Endpoint`:
- `.start` → `.ble(.start)`; `.stop` → `.ble(.stop)`.
- `.registerLocalDestination(d)` → `.transport(.registerLocalDestination(d))`.
- `.announce(h, a)` → `.transport(.announce(destinationHash: h, appData: a))`.
- `.send(h, p)` → `.transport(.send(destinationHash: h, plaintext: p))`.
- `.enableRelay(id)` → `.transport(.setTransportIdentity(id))`.
- `.transport(.delegate(.received(h, p)))` → `.delegate(.messageReceived(...))`.
- `.transport(.delegate(.pathLearned(h, hops)))` → `.delegate(.pathLearned(...))`.
- `.transport(.delegate(.sendFailed(h, r)))` → `.delegate(.sendFailed(...))`.

## Data flow

**Outbound announce:** app `.announce` → `transport.announce` → Transport emits
`.delegate(.transmit(id, raw))` once per interface in its set → each mapped back to a peer
token → `.ble(.send(peer: token, packet: raw))` → adapter frames + writes to that peer's
L2CAP channel.

**Inbound packet:** adapter `.channelData` → `BLEInterface` deframes → emits
`.delegate(.packetReceived(token, packet))` → `.transport(.received(id, packet))` → Transport
learns the path (announce) or delivers to a local destination → `.delegate(.received(...))`
→ `BLEEndpoint.delegate.messageReceived`.

## Maintenance lifecycle

Transport maintenance (announce retries, path-request GC) is node-wide. With no single BLE
connection to bind it to, maintenance runs whenever ≥1 peer is online:
- 0→1 peer (first `.peerOnline`): emit `transport.startMaintenance`.
- 1→0 peer (last `.peerOffline`): emit `transport.stopMaintenance`.
The `peerInterfaces` count (checked before the mutation) determines the transition.

## Error handling

No new failure modes. Peer loss already surfaces as `.peerOffline` →
`interfaceDisconnected`. A transmit routed to a peer that just dropped is a silent no-op in
the adapter (`FCBDriverAdapter.send` drops on an unknown/closed channel; the `BLEInterface`
reducer tears the peer down independently). A `.transmit` whose `txID` is not a BLE peer
(e.g. a stale ID) is dropped by the `guard` in the transmit edge. Transport surfaces
unroutable sends via `.sendFailed` as it does for any interface.

## Testing

Under the project's mutation-testing discipline (write → pass → mutate → fail → revert →
pass); `.off` TestStores asserting behavior.

1. **Reducer unit tests** (`BLEEndpointTests`, `TestStore` + mock `BLEDriver`): each wiring
   edge in isolation —
   - `.peerOnline(token)` → `peerInterfaces` gains the entry, `transport.interfaceConnected(id)`
     issued, and (first peer) `transport.startMaintenance`; `delegate.peerOnline` surfaced.
   - second `.peerOnline` (different token) → interfaceConnected, but NO second startMaintenance.
   - `.peerOffline` of one of two peers → interfaceDisconnected, entry removed, NO stopMaintenance;
     `.peerOffline` of the last peer → stopMaintenance.
   - `.packetReceived(token, packet)` → `transport.received(id, packet)`.
   - `transport.delegate(.transmit(id, raw))` for a live peer → `.ble(.send(peer: token, packet: raw))`;
     `.transmit` for an unknown `txID` → dropped (no `.ble(.send)`).
   - `.pathLearned` / `.messageReceived` / `.sendFailed` forwarding surfaces the right delegate.
2. **2-node in-memory integration test** (`BLEEndpointIntegrationTests`), following the
   `LXMFNodeOpportunisticTests` pattern: two `BLEEndpoint` `TestStore`s, each with a mock
   `BLEDriver` whose `send` records framed bytes into a `LockIsolated` buffer and whose
   `start` returns a controllable event stream. Drive both endpoints to `peerOnline` through
   the discovery→directoryRead→channelOpened→HELLO handshake (the adapter/interface machinery
   is already unit-tested; the integration test drives it through the driver events). Then
   MANUALLY BRIDGE: take the framed packet node A's adapter "sent" (from its buffer) and yield
   it as `.channelData` into node B's driver event stream, and vice-versa. Assert:
   - A registers + announces a destination; bridging A's announce to B makes B emit
     `.delegate(.pathLearned)` for A's destination.
   - A `.send`s an opportunistic packet to B's destination; bridging it to B surfaces
     `.delegate(.messageReceived)` at B with the exact plaintext.

   (Signature validation / identity nuances are the reducer's concern and already tested at
   the interface/transport layer; this test proves the composition routes packets end-to-end
   over the BLE seam.)

## Deliverables

- Create: `Sources/ReTiCANode/BLEEndpoint.swift`
- Create: `Tests/ReTiCANodeTests/BLEEndpointTests.swift`
- Create: `Tests/ReTiCANodeTests/BLEEndpointIntegrationTests.swift`

`ReTiCANode` already depends on `ReTiCAInterfaces` and `ReTiCATransport`, so no
`Package.swift` change is required.

## Out of scope (clean follow-ons)

- Links, resources, and request/response over BLE (structurally identical to `Endpoint`'s
  link wiring, but per-peer transmit routing; deferred).
- Threading BLE into `LXMFNode` (LXMF messaging over BLE) — `LXMFNode` currently hardwires
  the TCP `Endpoint` type; generalizing it is separate work.
- A node running TCP and BLE interfaces simultaneously (mixed-transport routing).
- Any change to the TCP `Endpoint`, `BLEInterface`, `Transport`, or `FCBDriverAdapter`.
