# BLE Interface — Hardware Verification Checklist

Manual verification of the live CoreBluetoothDriver (no automated coverage — the
reducer owns all policy and is fully TestStore-tested; this checks the mechanism).
Needs two Apple devices (Mac ↔ iPhone, or two Macs) running a small harness app
that starts a `BLEInterface` store and logs delegate events.

## App prerequisites (consuming app, not this package)
- [ ] `NSBluetoothAlwaysUsageDescription` in Info.plist.
- [ ] (iOS, optional) Background modes `bluetooth-central` + `bluetooth-peripheral`
      if background operation is wanted. Note: a backgrounded iOS advertiser moves
      the service UUID to the overflow area — only iOS centrals scanning for that
      exact UUID will find it; foreground both apps for first bring-up.
- [ ] macOS: Bluetooth entitlement/TCC prompt accepted.

## Bring-up
- [ ] Both devices report `.ready` → status `.online` after `.start`.
- [ ] Each device discovers the other (`.peerDiscovered` within a few seconds).
- [ ] Directory read succeeds: version 2, plausible PSM (> 0).
- [ ] Exactly ONE established channel per pair after HELLO/dedup settles
      (both sides log the SAME surviving direction; the lower-token side's
      outbound channel is the survivor).
- [ ] `.peerOnline` fires with the same 16-byte token on both sides' logs.

## Data plane
- [ ] Small packet (1–100 B) round-trips both directions intact.
- [ ] Max-size packet (1196 B) round-trips intact.
- [ ] Burst of 100 packets arrives complete and in order.

## Churn / recovery
- [ ] Kill the app on device B: device A gets `.peerOffline` within the BLE
      supervision timeout; on relaunch of B the pair re-establishes without
      restarting A.
- [ ] Toggle Bluetooth off on A: A goes `.waitingForAdapter`, peers offline.
      Toggle on: A recovers (`.online`) within the backoff schedule and re-peers.
- [ ] Rapid kill/relaunch of B several times in <10 s windows: A greylists B
      (visible as delayed re-establishment), then recovers after backoff.

## Results
Record throughput/latency observations here for the spec's Reference Values
section once measured.
