# Interfaces — BLE Driver on FCB — Design

**Date:** 2026-08-01
**Status:** Approved
**Supersedes:** the live-driver portion of `2026-08-01-ble-interface-swift-design.md`
(the RBTP v2 protocol, reducer, and `BLEDriver` contract sections stand unchanged).
**Depends on:** FCB L2CAP support — `../FCB/docs/superpowers/specs/2026-08-01-fcb-l2cap-design.md`
(sub-project 1, implemented first in the FCB repo).

## Context

The BLE interface shipped with a hand-rolled `CoreBluetoothDriver` (delegate wrappers,
stream pumping, ~470 lines, no automated coverage — mechanism verified on hardware only).
FCB (`../FCB`, local sibling) is the user's Bluetooth library: closure delegate wrappers
(Layer 1) and TCA `@DependencyClient` clients backed by actors (Layer 2,
`FCBComposable`), with the central role on Nordic CoreBluetoothMock so real client flows
are testable in-process via `BluetoothCentralClient.mocked()`.

This refactor replaces `CoreBluetoothDriver` with a thin adapter over FCB's two clients.
**Nothing above the `BLEDriver` seam changes**: the `BLEDriverEvent` contract, the
`BLEInterface` reducer, and all reducer tests stay byte-identical, and the wire protocol
remains RBTP v2 exactly.

Decisions made during brainstorming:
- **Keep the seam** (approach 1): the reducer never learns FCB exists; the swap is
  confined to `BLEDriver.liveValue`'s implementation.
- **FCB gains L2CAP** (sub-project 1) rather than moving the data plane to GATT.
- **Local path dependency** (`.package(path: "../FCB")`) — FCB has no remote.
- **Platforms:** ReTiCA declares iOS 17, macOS 13, macCatalyst 17; tvOS/watchOS
  declarations are dropped (FCB supports neither; they can return if FCB adds them).

## What changes

```
DELETE  Sources/ReTiCAInterfaces/CoreBluetoothDriver.swift
MODIFY  Sources/ReTiCAInterfaces/BLEDriver.swift          // liveValue rewired; contract untouched
CREATE  Sources/ReTiCAInterfaces/FCBDriverAdapter.swift    // the adapter actor + BLEDriver.fcb(...)
MODIFY  Package.swift                                      // FCB path dep; platform floors
CREATE  Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift
UNCHANGED  BLEInterface.swift, BLESupport.swift, all existing tests, hardware checklist
```

## Public surface

One addition, on `BLEDriver`:

```swift
extension BLEDriver {
    /// Composes the FCB clients into the BLEDriver contract.
    /// liveValue == .fcb(central: .liveValue, peripheral: .liveValue) (platform-gated);
    /// tests inject stubbed or CBM-mocked clients.
    public static func fcb(
        central: BluetoothCentralClient,
        peripheral: BluetoothPeripheralClient
    ) -> BLEDriver
}
```

`BLEDriver.liveValue` becomes `.fcb(central: .liveValue, peripheral: .liveValue)` under
`#if canImport(CoreBluetooth) && (os(iOS) || os(macOS))`, keeping the inert stub
otherwise. `testValue` unchanged.

## Adapter mapping (`FCBDriverAdapter`, internal actor)

Mechanism-only, like the driver it replaces: no retries, no greylist, no framing, no
version policy. Long-running work happens in Tasks owned by the actor, all cancelled on
`stop()`/restart.

- **start(config):**
  - Subscribe `peripheral.state()`: on `.poweredOn` →
    `publishL2CAPChannel(withEncryption: config.pairingMode == .paired)` → PSM →
    `add(MutableService(directory))` where the directory service is the RBTP v2 GATT
    directory: service UUID `99872ed7-eba8-4c07-bf35-ab464a957f80`, Version
    characteristic `50870e44-2fd6-4cbc-9f1f-11a0fcf85265` = `Data([config.version])`,
    PSM characteristic `1cfe213f-4ea4-48f9-9344-dde18cc729ef` = PSM little-endian; both
    `.read` properties with permissions `.readable` (`open`) or `.readEncryptionRequired`
    (`paired`) → `startAdvertising(serviceUUIDs: [service])`.
  - Subscribe `central.state()`: on `.poweredOn` → consume
    `scan([serviceUUID], ScanOptions(allowDuplicates: true))`; dedup via a `seenPeers`
    set → `.peerDiscovered(BLEPeerHandle(id:))`. `forget` (remove from seen) on
    directory failure, channel failure, channel close, and disconnect — so peers are
    re-discoverable, exactly as today.
  - `.ready` exactly once per start when BOTH advertising and scanning are up;
    `.unavailable(reason:)` once per start when either state stream reports
    `.poweredOff` / `.unauthorized` / `.unsupported`.
  - Subscribe `central.events()`: disconnect events fail any pending directory read for
    that peripheral and forget the peer.
- **readDirectory(peer):** `connect(peer.id, nil)` → `discoverServices([serviceUUID])`
  → `discoverCharacteristics(...)` → `readValue(version)` + `readValue(psm)` →
  `.directoryRead(peer, version:, psm:)` (PSM parsed little-endian). Any throw or
  missing piece → `.directoryFailed(peer, reason:)` + forget + best-effort
  `disconnect`. The peripheral stays connected on success (the L2CAP dial rides the
  same ACL link).
- **openChannel(peer, psm):** `central.openL2CAPChannel(peer.id, psm)` →
  `.channelOpened(id, peer, .outbound)`; throw → `.channelFailed(peer, reason:)` +
  forget. (`BluetoothError.l2capNotSupported` from a mocked central maps to
  `.channelFailed` like any other error — asserted in tests.)
- **Inbound:** consume `peripheral.l2capConnections()` → `.channelOpened(id,
  BLEPeerHandle(id: connection.peerID), .inbound)`.
- **Channel IO:** for every `L2CAPConnection` (both directions), mint a `BLEChannelID`,
  store the connection, and spawn a task consuming `incoming()` → `.channelData(id,
  chunk)`; when the stream finishes → drop the connection, forget the peer, and emit
  `.channelClosed(id, reason: nil)` unless the close was reducer-initiated.
- **send(channelID, data):** `connection.send(data)`; a throw means the channel is
  already dead — swallowed (the `incoming` finish delivers `.channelClosed`).
- **closeChannel(channelID):** `connection.close()` and mark reducer-initiated — silent,
  no `.channelClosed` echo (contract preserved).
- **stop():** cancel all tasks; `stopScan`, `stopAdvertising`, `removeAll`,
  `unpublishL2CAPChannel`, close all connections, finish the event stream. `start()`
  after `stop()` (adapter reuse across adapter-retry) begins from a clean slate.

## Package changes

```swift
platforms: [.iOS(.v17), .macOS(.v13), .macCatalyst(.v17)],   // tvOS/watchOS dropped
dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.15.0"),
    .package(path: "../FCB"),
],
// ReTiCAInterfaces target gains .product(name: "FCBComposable", package: "FCB")
```

The build requires the FCB checkout at `../FCB` (both live in `pods/`; FCB has no
remote). Core `ReTiCA` target remains dependency-free.

## Error handling

Unchanged at the contract level: every FCB-level throw or stream termination becomes a
`BLEDriverEvent`; nothing throws across the `BLEDriver` boundary; the reducer's policy
(strikes, retries, backoff) is untouched.

## Testing

1. **Adapter unit tests** (`FCBDriverAdapterTests`, new — coverage the deleted driver
   never had): hand-stubbed FCB clients (plain struct values whose closures record calls
   and yield scripted streams) drive `BLEDriver.fcb(...)` and assert event sequences:
   - startup: publish → add service (correct UUIDs, static values, PSM little-endian,
     permissions per pairing mode) → advertise → scan → single `.ready`;
   - discovery dedup + re-discovery after forget;
   - directory read happy path and each failure leg → `.directoryFailed`;
   - inbound connection → `.channelOpened(.inbound)`; incoming chunks →
     `.channelData`; stream finish → `.channelClosed`;
   - `closeChannel` silence (no echo);
   - `.unavailable` once on poweredOff; `stop()` cleans up (unpublish/stopAdvertising/
     stopScan recorded).
2. **CBM integration test**: `BLEDriver.fcb(central: .mocked(...), peripheral: stub)`
   against a `CBMPeripheralSpec` serving a genuine RBTP v2 directory (version 2, a
   known PSM little-endian): the REAL FCB central actor + adapter run scan → connect →
   GATT discovery → reads → `.directoryRead(version: 2, psm:)`, then `openChannel`
   asserts the graceful `.channelFailed` mapping (CBM cannot mock L2CAP). Respects
   FCB's serialized-CBM test convention within this package.
3. **Regression:** all existing `BLEInterfaceTests`/`BLESupportTests`/fixture tests
   unchanged and green; full `swift test` green.
4. **Hardware:** the existing checklist
   (`docs/superpowers/plans/2026-08-01-ble-hardware-checklist.md`) re-run on the FCB
   driver verifies the L2CAP hop; no checklist changes needed.

The user's global mutation-verification discipline applies to every test-bearing task.

## Out of scope

- Reducer, protocol, or `BLEDriverEvent` contract changes (none; RBTP v2 byte-identical).
- Endpoint/Transport wiring (unchanged follow-up).
- Write-buffer cap (tracked in both repos' specs as future work).
- tvOS/watchOS support (returns if/when FCB adds those platforms).
