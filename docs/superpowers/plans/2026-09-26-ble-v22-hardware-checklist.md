# BLE v2.2 — Hardware Verification Checklist

Manual verification of the live FCB adapter against real radios (no automated coverage —
the reducer owns all policy and is TestStore-tested; this checks the mechanism and interop).
Spec: `docs/superpowers/specs/2026-09-26-ble-v22-gatt-driver-design.md`.

## Pi reference node (do this first)
- [ ] Raspberry Pi (Pi 4 / Zero 2 W preferred) with stock `rns` installed and ble-reticulum
      v0.2.2 installed per its README (`./install.sh`, experimental BlueZ, JustWorksRepairing).
- [ ] `rnsd -vvv` shows `BLEInterface` advertising and scanning; a second Pi (or Columba)
      connects and exchanges an LXMF message — proves the reference before touching iOS.

## App prerequisites (consuming app, not this package)
- [ ] `NSBluetoothAlwaysUsageDescription` in Info.plist (punch-list A2).
- [ ] BLE endpoint slot constructed with `BLEEndpoint.State(localIdentity: identity.hash)` (A1).
- [ ] Foreground both sides for bring-up; backgrounded iPhones are invisible to BlueZ.

## iPhone → Pi (iPhone as central)
- [ ] iPhone discovers the Pi (`peerDiscovered`) within a few seconds of both being up.
- [ ] `identityRead` carries the Pi's 16-byte identity; Pi log shows a central connect.
- [ ] `channelOpened(.outbound, mtu: …)` — record the MTU CoreBluetooth reports.
- [ ] Pi log: `received identity handshake from central …` and `created peer interface`.
- [ ] `rnstatus` on the Pi lists the iPhone peer interface.
- [ ] Small LXMF message Pi → iPhone and iPhone → Pi (single-fragment packets).
- [ ] > 391 B LXMF message both ways (resource transfer over fragmented packets).
- [ ] Keepalive: Pi log at EXTREME level shows `received keep-alive from central` every 15 s.
- [ ] Walk out of range and back: `peerOffline`, then re-establishment without restarting either side.
- [ ] Kill/relaunch the iOS app three times within 10 s windows: Pi greylists (`blacklisted`
      log lines) and recovers after backoff; iOS side strikes likewise.

## Pi → iPhone (Pi as central) — EXPECTED TO FAIL until the upstream fix
- [ ] Confirm the Pi never completes a connection to the iPhone (ble-reticulum dials with
      `AddressType: public`; iPhones use random addresses). Record the Pi's error text for the
      upstream PR. iPhone → Pi must keep working while the Pi retries.

## iPhone ↔ iPhone
- [ ] Both discover each other; exactly ONE surviving channel after duplicate resolution (the
      lower identity's outbound channel wins; both logs agree on the direction).
- [ ] Packets flow both ways; > 391 B message both ways.
- [ ] Toggle Bluetooth off on A: A `waitingForAdapter`, peers offline; toggle on: recovers.

## Columba (Android) — when available
- [ ] iPhone → Columba and Columba → iPhone establish; check for duplicate-rule disagreement
      on a simultaneous cross-connect (spec §2.7): at worst one churn cycle, never a wedge.

## Results
Record MTU, throughput and latency here for the spec's §2.8 bitrate revision.

## Added after the whole-branch review
- [ ] Packet sizes where length mod (mtu − 5) = 11 (e.g. 188 B at MTU 182) reach the Pi intact:
      no 16-byte fragment on the wire, and no `consuming as handshake` warning in the Pi log.
- [ ] A resource-transfer burst (> 391 B message) does not lose fragments (the outbound drain
      parks on `canSendWriteWithoutResponse`, spec §3.4).
- [ ] Bluetooth toggled off and on while `waitingForAdapter` recovers with exactly one service
      and one advertisement (no duplicate service, no alreadyAdvertising retry loop).
- [ ] Disconnect mid-`openChannel` on live hardware fails within a second (FCB fails pending
      operations).
- [ ] Two centrals subscribed to one Pi: the Pi's notifications are broadcast to all
      subscribers, so foreign fragments enter our reassembler. Confirm our packets still
      reassemble and nothing wedges.
- [ ] Closing an outbound channel while an inbound channel from the same device is live on the
      same ACL link: does the inbound channel survive?
- [ ] An idle GATT link left after a cross-connect deadline is released by the peer's
      supervision timeout.
